#!/usr/bin/env bash
# fallback.sh — 回落域名筛选：服务器国家检测 / TLS 合规测试 / 握手延迟 / 交互筛选向导

# 检测服务器国家（用于候选排序）
detect_server_country() {
  local c
  c="$(curl -s --max-time 10 https://ipinfo.io/country 2>/dev/null || true)"
  if [[ "$c" =~ ^[A-Z]{2}$ ]]; then echo "$c"; return 0; fi
  c="$(curl -s --max-time 10 "http://ip-api.com/line/?fields=countryCode" 2>/dev/null || true)"
  if [[ "$c" =~ ^[A-Z]{2}$ ]]; then echo "$c"; return 0; fi
  # 两个数据源都失败时静默按 US 处理会让「本地区候选」范围失真
  # （测错地区、白等半小时）→ 必须出声，并提示可用 --region 显式指定
  log_warn "无法识别本机所在国家（ipinfo/ip-api 均失败），暂按 US 处理；可用 --region <国家码> 显式指定"
  echo "US"
}

# 列出某地区的回落候选：每行 "域名|备注"（tier 升序，tier5 大厂排除）
# 为什么抽成函数（2026-10-15）：地区过滤口径原先只写在 select_fallback_domain 里，
#   cmd_fallback_test 完全不过滤（无参 = 候选表全部 121 条 / 10 个地区）→ 两处漂移。
#   现由部署向导与 fallback-test 共用，单一权威源。
fallback_region_candidates() {  # $1=国家码（如 DE）；无该地区候选时返回 1（不输出）
  local want="${1^^}" dom c t note line
  local -a rows=()
  for line in "${FALLBACK_CANDIDATES[@]}"; do
    IFS='|' read -r dom c t note <<<"$line"
    [[ "$t" == "5" ]] && continue
    [[ "$c" == "$want" ]] || continue
    rows+=("${t}|${dom}|${note}")
  done
  [[ ${#rows[@]} -gt 0 ]] || return 1
  IFS=$'\n' rows=($(sort -t'|' -k1,1 <<<"${rows[*]}")); unset IFS
  for line in "${rows[@]}"; do
    IFS='|' read -r _ dom note <<<"$line"
    printf '%s|%s\n' "$dom" "$note"
  done
}

# 测试回落域名: 返回 0=通过；输出原因到 stdout
# 兼容 OpenSSL 1.1.1/3.x/3.5：3.x+ 的 s_client 输出 "New, TLSv1.3, Cipher is ..."，
# 3.5 输出 "Protocol: TLSv1.3"（单冒号）。X25519 不单独 grep——-groups X25519 参数
# 已限定客户端仅提供 X25519，TLSv1.3 握手成功即证明服务端支持（TLS1.3 无 Server Temp Key 行）。
# HTTP 检查放宽：REALITY 回落只需 TLS 层正常；301/302 同站跳转、403 WAF 均可用，
# 仅拒绝 4xx/5xx 服务错误与 000 连接失败（加 UA 降低 WAF 误杀）。
test_fallback_domain() {
  local domain="$1" out code
  # TLS1.3 + H2 + X25519(隐含) + 非 Cloudflare + 证书有效
  out="$(echo | timeout 12 openssl s_client -connect "${domain}:443" -tls1_3 -alpn h2 -groups X25519 -servername "$domain" 2>&1 || true)"
  grep -qE "New, TLSv1\.3|Protocol: TLSv1\.3|Protocol  : TLSv1\.3" <<<"$out" || { echo "TLSv1.3 不支持"; return 1; }
  grep -qE "ALPN protocol: h2" <<<"$out" || { echo "不支持 H2"; return 1; }
  grep -qi "cloudflare" <<<"$out" && { echo "Cloudflare CDN（不推荐）"; return 1; }
  grep -q "Verify return code: 0" <<<"$out" || { echo "证书校验失败"; return 1; }
  # 非跳转/非错误：接受 2xx/3xx；拒绝 000（连接失败）、4xx/5xx（服务错误）
  code="$(curl -sI --max-time 10 -o /dev/null -w '%{http_code}' -A 'Mozilla/5.0' "https://${domain}/" 2>/dev/null || echo 000)"
  if [[ "$code" =~ ^[23] ]]; then
    :
  elif [[ "$code" == "000" ]]; then
    echo "连接失败（HTTP 000）"; return 1
  elif [[ "$code" =~ ^[45] ]]; then
    echo "HTTP ${code}（服务错误）"; return 1
  fi
  echo "ok"
  return 0
}

# 测量 TLS 握手延迟（ms）：3 次采样取中位数，抗单次抖动
measure_handshake_ms() {
  local domain="$1" i t0 t1
  local -a samples=()
  for i in 1 2 3; do
    t0="$(date +%s%N)"
    # || true：openssl 超时/失败不影响采样（set -e 下命令替换失败会杀死脚本）
    echo | timeout 6 openssl s_client -connect "${domain}:443" -tls1_3 -servername "$domain" >/dev/null 2>&1 || true
    t1="$(date +%s%N)"
    samples+=("$(( (t1 - t0) / 1000000 ))")
  done
  # 中位数（排序取中间）
  local sorted
  IFS=$'\n' sorted=($(printf '%s\n' "${samples[@]}" | sort -n)); unset IFS
  echo "${sorted[1]}"
}

# 回落域名筛选向导（半自动：测试+排序+确认）
select_fallback_domain() {
  local country server_domain line dom c t note i result candidates=() sorted=()
  country="$(detect_server_country)"
  log_info "服务器国家: ${country}"

  # 1) 优先询问自有域名（偷自己，推荐度最高）
  read_input "如有自有域名可作回落（直接回车跳过）: " server_domain
  if [[ -n "$server_domain" ]]; then
    echo "$server_domain"
    return 0
  fi

  # 2) 候选过滤：只取服务器所在地（country）的域名（tier5 大厂排除）
  # 2026-08-12 用户要求：候选表只取该地区的域名（不再混入他国备选）
  # 过滤口径统一走 fallback_region_candidates（与 fallback-test 共用，防两处漂移）
  local -a sorted_lines=()
  while IFS= read -r line; do
    IFS='|' read -r dom note <<<"$line"
    sorted_lines+=("${dom}|${note}")
  done < <(fallback_region_candidates "$country" || true)
  if [[ ${#sorted_lines[@]} -eq 0 ]]; then
    die "候选表中无 ${country} 地区域名，请使用自有域名回落（或补充 FALLBACK_CANDIDATES）"
  fi

  # 3) 逐个测试，通过即测握手延迟；最多收 6 个
  log_info "正在测试回落候选（TLS1.3+H2+X25519+非跳转+非Cloudflare）..."
  local tested=0 shown=0 delay
  for line in "${sorted_lines[@]}"; do
    [[ "$shown" -ge 6 ]] && break
    IFS='|' read -r dom note <<<"$line"
    result="$(test_fallback_domain "$dom")" || true   # 防 set -e：失败(return 1)会终止脚本
    tested=$((tested+1))
    if [[ "$result" == "ok" ]]; then
      delay="$(measure_handshake_ms "$dom")" || true
      shown=$((shown+1))
      candidates+=("$dom|$note|$delay")
    else
      log_warn "  ✗ ${dom} — ${result}"
    fi
  done

  [[ ${#candidates[@]} -eq 0 ]] && die "所有候选均未通过测试，请检查服务器网络或换用自有域名"

  # 4) 按握手延迟升序排序（默认选最低延迟），并列时保持原顺序
  IFS=$'\n' candidates=($(printf '%s\n' "${candidates[@]}" | sort -t'|' -k3,3n)); unset IFS

  # 5) 展示排序结果
  log_info "候选按握手延迟排序（默认选最低）:"
  for ((i=0; i<${#candidates[@]}; i++)); do
    IFS='|' read -r dom note delay <<<"${candidates[$i]}"
    log_info "  [$((i+1))] ${dom}  (${note}) ✓ ${delay}ms"
  done

  # 6) 用户确认（默认第一个 = 延迟最低）；注意此处输出到 stderr 的空行分隔符不可用 echo（会被 $(...) 捕获污染返回值）
  read_input "选择回落域名 [1-${#candidates[@]}，回车默认 1（最低延迟）]: " i
  i="${i:-1}"
  [[ "$i" =~ ^[0-9]+$ ]] && [[ "$i" -ge 1 ]] && [[ "$i" -le "${#candidates[@]}" ]] || die "无效选择"
  IFS='|' read -r dom note delay <<<"${candidates[$((i-1))]}"
  echo "$dom"
}
