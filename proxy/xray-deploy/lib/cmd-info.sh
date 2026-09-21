#!/usr/bin/env bash
# cmd-info.sh — info：节点信息 + 客户端片段 + routing 说明 + 版本兼容警告

# ============ info ============
cmd_info() {
  [[ -f "$STATE_FILE" ]] || die "尚未安装（state.json 不存在）"
  local ip
  ip="$(state_get '.server_ip')"
  echo "=============================================="
  echo " Xray 节点信息（$(state_get '.installed_at')）"
  echo "=============================================="
  echo "服务器 IP: ${ip}"
  # 已装 Xray 版本（旧 state 无该字段 → 退回读二进制）
  local xver
  xver="$(state_get '.xray_version // ""')"
  # ⚠️ `|| true` 必需：二进制缺失时命令替换内的管道失败 → set -e 静默杀脚本
  if [[ -z "$xver" && -x "${BIN_PATH}" ]]; then
    xver="$("${BIN_PATH}" version 2>/dev/null | sed -n 1p | awk '{print $2}' || true)"
  fi
  if [[ -n "$xver" ]]; then
    if xray_tag_needs_mlkem "$xver"; then
      echo "Xray 版本: ${xver}  ⚠️ ≥ v${MLKEM_MIN_VERSION}（REALITY 要求客户端支持 X25519MLKEM768）"
    else
      echo "Xray 版本: ${xver}"
    fi
  fi
  echo
  local i name type port uuid pub sni sid domain path cert_file password brutal_up brutal_down
  for i in $(jq -r '.protocols | keys[]' "$STATE_FILE"); do
    name="$(jq -r ".protocols[$i].name" "$STATE_FILE")"
    type="$(jq -r ".protocols[$i].type" "$STATE_FILE")"
    port="$(jq -r ".protocols[$i].port" "$STATE_FILE")"
    uuid="$(jq -r ".protocols[$i].uuid // \"\"" "$STATE_FILE")"
    pub="$(jq -r ".protocols[$i].public_key // \"\"" "$STATE_FILE")"
    sni="$(jq -r ".protocols[$i].sni // \"\"" "$STATE_FILE")"
    sid="$(jq -r ".protocols[$i].short_id // \"\"" "$STATE_FILE")"
    domain="$(jq -r ".protocols[$i].domain // \"\"" "$STATE_FILE")"
    path="$(jq -r ".protocols[$i].path // \"\"" "$STATE_FILE")"
    cert_file="$(jq -r ".protocols[$i].cert_file // \"\"" "$STATE_FILE")"
    password="$(jq -r ".protocols[$i].password // \"\"" "$STATE_FILE")"
    brutal_up="$(jq -r ".protocols[$i].brutal_up // \"\"" "$STATE_FILE")"
    brutal_down="$(jq -r ".protocols[$i].brutal_down // \"\"" "$STATE_FILE")"
    echo "----------------------------------------------"
    echo "协议: ${name}  (${type})"
    # vless-xhttp3-nginx 的「地址」不是 xray 的监听地址（xray 只监听 UDS），
    # 而是客户端入口 —— 通常是域名（CF SaaS）。打 IP:port 会误导用户拿它当 server 填。
    if [[ "$type" == "vless-xhttp3-nginx" ]]; then
      echo "地址: ${domain}:${port}  （客户端填域名；本机 IP ${ip} 仅源站，勿直连）"
    else
      echo "地址: ${ip}:${port}"
    fi
    if [[ "$type" == "hysteria2" ]]; then
      echo "传输: UDP/QUIC (Hysteria2)"
      echo "密码: ${password}"
      [[ -n "$domain" ]] && echo "SNI: ${domain}"
      echo "证书: ${cert_file}"
      [[ -n "$brutal_up" && -n "$brutal_down" ]] && echo "BRUTAL: up=${brutal_up} down=${brutal_down}"
    elif [[ "$type" == "ss2022" ]]; then
      echo "传输: TCP+UDP (shadowsocks 2022)"
      echo "方法: $(jq -r ".protocols[$i].method" "$STATE_FILE")"
      echo "密钥: ${password}"
      echo "⚠️ 本协议定位=【中转机→落地机】一跳（境外↔境外）；"
      echo "   出境段（客户端↔中转）请用 REALITY（SS2022 无 TLS 外观，跨境会被风控）"
    else
      echo "UUID: ${uuid}"
    fi
    if [[ "$type" == "vless-reality" ]]; then
      echo "SNI: ${sni}"
    elif [[ "$type" == "vless-xhttp-reality" ]]; then
      echo "SNI: ${sni}  path: ${path}"
      echo "传输: XHTTP + REALITY + XMUX（无需证书，回落伪装）"
    elif [[ "$type" == "vless-xhttp3-nginx" ]]; then
      echo "域名: ${domain}  path: ${path}"
      echo "传输: HTTP/3 (QUIC/UDP) → nginx → h2c/gRPC over UDS → xray"
      echo "⚠️ 端口 ${port} 由 nginx 监听，xray 不监听端口（仅 socket）"
      echo "⚠️ TLS 证书由 nginx 持有 —— 本工具不管理该证书"
    elif [[ "$type" == "vless-xhttp" || "$type" == "vless-h2" ]]; then
      echo "域名: ${domain}  path: ${path}"
      echo "证书: ${cert_file}"
    fi
    echo
    echo "--- mihomo (Clash Meta) proxies 片段 ---"
    if [[ "$type" == "hysteria2" ]]; then
      gen_client_mihomo_hysteria2 "$name" "$ip" "$port" "$password" "$domain" "$brutal_up" "$brutal_down"
    elif [[ "$type" == "ss2022" ]]; then
      gen_client_mihomo_ss2022 "$name" "$ip" "$port" "$(jq -r ".protocols[$i].method" "$STATE_FILE")" "$password"
    else
      gen_client_mihomo "$type" "$name" "$ip" "$port" "$uuid" "$pub" "$sni" "$sid" "$domain" "$path"
    fi
    echo
    echo "--- sing-box outbounds 片段 ---"
    if [[ "$type" == "hysteria2" ]]; then
      gen_client_singbox_hysteria2 "$name" "$ip" "$port" "$password" "$domain" "$brutal_up" "$brutal_down"
    elif [[ "$type" == "ss2022" ]]; then
      gen_client_singbox_ss2022 "$name" "$ip" "$port" "$(jq -r ".protocols[$i].method" "$STATE_FILE")" "$password"
    else
      gen_client_singbox "$type" "$name" "$ip" "$port" "$uuid" "$pub" "$sni" "$sid" "$domain" "$path"
    fi
    # XHTTP3-NGINX：附 nginx 配置只读参考（D2-b：只打印，不写文件、不 reload nginx）
    if [[ "$type" == "vless-xhttp3-nginx" ]]; then
      local sp
      sp="$(jq -r ".protocols[$i].socket_path // \"\"" "$STATE_FILE")"
      if [[ -n "$sp" ]]; then
        xhttp3_print_nginx_reference "$domain" "$port" "$path" "$sp"
      else
        log_warn "state 中缺 socket_path 字段——无法生成 nginx 参考（该协议由更早版本添加？）"
      fi
    fi
    echo
  done
  echo "----------------------------------------------"
  echo "服务端 routing（优先级从高到低）:"
  echo "  block: geosite:category-ads-all"
  echo "  block: bittorrent"
  echo "  block: geoip:private"
  echo "  block: geosite:cn"
  echo "  block: geoip:cn"
  # 链路提示：配了 chain 则按分流模式追加落地/直出规则
  if jq -e '.chain.upstream' "$STATE_FILE" >/dev/null 2>&1; then
    local _m _d
    _m="$(routing_current_mode)"
    _d="$(routing_preset_domains "$_m" 2>/dev/null || echo '?')"
    if [[ "$_d" == "*" ]]; then
      echo "  landing: tcp,udp（catch-all，全部走落地）"
    elif [[ -z "${_d// /}" ]]; then
      echo "  direct: tcp,udp（catch-all，当前 mode=none 全部直出）"
    else
      echo "  landing: $(tr ' ' ',' <<<"$_d")（白名单走落地）"
      echo "  direct: tcp,udp（catch-all，其余直出）"
    fi
    echo "  分流模式: ${_m}（切换: xray-deploy chain mode <模式>）"
  fi
  # 版本兼容警告：REALITY 客户端对 Xray >= 26.9.8 的兼容矩阵
  if jq -e '.protocols[] | select(.type=="vless-reality" or .type=="vless-xhttp-reality")' "$STATE_FILE" >/dev/null 2>&1; then
    echo "----------------------------------------------"
    echo "⚠ REALITY 客户端兼容性（Xray ≥ v${MLKEM_MIN_VERSION} 起服务端要求 X25519MLKEM768）"
    echo "  · mihomo 1.19.30+ → 可用（上面片段已含 support-x25519mlkem768: true）"
    echo "  · sing-box（含最新稳定版 1.14.1）→ ❌ 连不上，无客户端侧开关可解"
    echo "    （上游 SagerNet/sing-box#4520 未修；症状 reality verification failed）"
    if [[ -n "$xver" ]] && xray_tag_needs_mlkem "$xver"; then
      echo "  → 当前服务端 ${xver} 会拒绝 sing-box；需 sing-box 请降到 v26.7.28 或更早"
    fi
  fi
  echo "=============================================="
}
