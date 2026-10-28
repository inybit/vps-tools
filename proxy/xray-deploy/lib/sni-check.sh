#!/usr/bin/env bash
# sni-check.sh — REALITY 的 SNI（= dest）校验：防盗刷闸门 + 可用性检查 + 存量只读体检
#
# 背景：本工具 REALITY inbound 的 dest 恒为 "<sni>:443"、serverNames 恒为 [sni]。
#   ① 安全：dest 若是 CF 域名 → 未鉴权流量被转发到 CF 边缘 IP，本机变成免费转发器
#      （流量被盗刷 + GFW 回源取证，见 lib/cdn-detect.sh 顶部注释与上游 #2360/#5807）
#   ② 功能：REALITY 硬要求 TLS1.3 + H2 + X25519；证书必须覆盖该 SNI，否则回落外观异常
# 两者合成一个闸门：所有 SNI 来源（候选表 / 自有域名 / protocol edit）都过它。
#
# 为什么不实现运行时防盗刷（2026-10-29 用户口径）：
#   官方 dokodemo-door + sniffing 那套是把未鉴权流量收进本地假站点（零出站），
#   与「SNI 层排除 CF」互补。SNI 闸门落地后 dest 必然是非 CDN 源站，
#   转发一次只产生一次正常出站，不存在「被当 CF 转发器白嫖」的通道 → 本轮不做。

# 防盗刷闸门（只判 CF，不做握手；用于写 state 前的兜底）
# $1=域名 → 0=通过；命中 CF 且未显式放行 → stdout 输出原因，rc=1
cf_sni_gate() {
  local d="$1" reason
  reason="$(cf_front_reason "$d")" || return 0
  if [[ "${XRAY_DEPLOY_ALLOW_CDN_SNI:-0}" == "1" ]]; then
    log_warn "SNI ${d} 命中 CF 前置（${reason}）——已按 XRAY_DEPLOY_ALLOW_CDN_SNI=1 显式放行"
    log_warn "  该配置会让本机成为 CF 端口转发器，出站流量可能被盗刷；仅在明确知情时使用"
    return 0
  fi
  printf 'Cloudflare 前置（%s）：REALITY 会把未鉴权流量转发到 CF 边缘 IP，本机变成 CF 免费转发器 → 流量被盗刷、GFW 可回源取证。请换非 CF 域名（确需强制放行用 XRAY_DEPLOY_ALLOW_CDN_SNI=1）' "$reason"
  return 1
}

# REALITY SNI 完整校验
# $1=SNI（=dest 域名）→ 0=通过（stdout "ok"）；失败 stdout 给原因（与 test_fallback_domain 同风格）
check_reality_sni() {
  local d="$1" out code reason pem
  [[ -n "$d" ]] || { echo "SNI 为空"; return 1; }
  # 形态：必须是域名。IP 做 dest 时证书与 SNI 不符，主动探测一击即中
  if [[ "$d" =~ ^[0-9.]+$ || "$d" == *:* ]]; then
    echo "SNI 必须是域名，不能是 IP（${d}）——IP 做 dest 会导致证书与 SNI 不符，易被主动探测识别"
    return 1
  fi
  if [[ ! "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; then
    echo "SNI 不是合法域名: ${d}"
    return 1
  fi

  # ① 防盗刷闸门（最优先：命中 CF 直接拒，不必再握手）
  reason="$(cf_sni_gate "$d")" || { printf '%s' "$reason"; return 1; }

  # ② 协议栈：REALITY 硬要求 TLS1.3 + H2（-groups X25519 已限定客户端只提供 X25519，
  #    握手成功即证明服务端支持；TLS1.3 无 Server Temp Key 行，不单独 grep）
  out="$(echo | timeout 12 openssl s_client -connect "${d}:443" -tls1_3 -alpn h2 -groups X25519 -servername "$d" 2>&1 || true)"
  grep -qE "New, TLSv1\.3|Protocol: TLSv1\.3|Protocol  : TLSv1\.3" <<<"$out" || { echo "不支持 TLSv1.3"; return 1; }
  grep -qE "ALPN protocol: h2" <<<"$out" || { echo "不支持 H2"; return 1; }

  # ③ 证书：链必须有效，且 SAN 必须覆盖该 SNI（不覆盖 = 回落外观异常，DPI 直接判定）
  grep -q "Verify return code: 0" <<<"$out" || { echo "证书校验失败（链不完整/自签/过期）"; return 1; }
  pem="$(sed -n '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/p' <<<"$out")"
  [[ -n "$pem" ]] || { echo "未取到服务器证书"; return 1; }
  openssl x509 -noout -checkhost "$d" <<<"$pem" >/dev/null 2>&1 || { echo "证书 SAN 不覆盖 ${d}"; return 1; }

  # ④ dest 必须活着：REALITY 会把未鉴权流量转发过去，目标挂掉 = 回落行为异常
  code="$(curl -sI --max-time 10 -o /dev/null -w '%{http_code}' -A 'Mozilla/5.0' "https://${d}/" 2>/dev/null || echo 000)"
  [[ "$code" == "000" ]] && { echo "HTTP 不可达（000）"; return 1; }

  echo "ok"
}

# 存量体检（只读）：扫 state.json 里全部 REALITY 协议，逐个校验 SNI
# 不改任何配置 —— 修复动作交用户手动执行（protocol edit → 改 SNI）
cmd_reality_check() {
  need_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装，先运行: xray-deploy install"
  local row name port sni res n=0 bad=0
  local -a rows=()
  while IFS= read -r row; do
    [[ -n "$row" ]] && rows+=("$row")
  done < <(jq -r '.protocols[] | select(.type=="vless-reality" or .type=="vless-xhttp-reality")
                  | "\(.name)|\(.port)|\(.sni // "")"' "$STATE_FILE" 2>/dev/null || true)

  if [[ ${#rows[@]} -eq 0 ]]; then
    log_info "state.json 无 REALITY 协议（vless-reality / vless-xhttp-reality），无需检查"
    return 0
  fi

  log_info "REALITY SNI 体检（${#rows[@]} 个协议，只读不改配置）"
  for row in "${rows[@]}"; do
    IFS='|' read -r name port sni <<<"$row"
    n=$((n+1))
    log_info "[${n}] ${name}  ${port}/TCP  sni=${sni:-<空>}"
    if res="$(check_reality_sni "$sni")"; then
      log_ok "    ✅ 合格（非 CF 前置 / TLS1.3+H2 / 证书覆盖 / dest 可达）"
    else
      bad=$((bad+1))
      log_err "    ❌ ${res}"
      log_info "    修复: sudo xray-deploy protocol edit ${name} → 选「改 SNI」重选回落域名"
    fi
  done

  if [[ $bad -gt 0 ]]; then
    log_err "${bad}/${#rows[@]} 个 REALITY 协议 SNI 不合格（dest 套 CF 会被盗刷流量）"
    return 1
  fi
  log_ok "全部 ${#rows[@]} 个 REALITY 协议 SNI 合格"
  return 0
}
