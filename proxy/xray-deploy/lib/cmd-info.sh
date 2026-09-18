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
    echo "地址: ${ip}:${port}"
    if [[ "$type" == "hysteria2" ]]; then
      echo "传输: UDP/QUIC (Hysteria2)"
      echo "密码: ${password}"
      [[ -n "$domain" ]] && echo "SNI: ${domain}"
      echo "证书: ${cert_file}"
      [[ -n "$brutal_up" && -n "$brutal_down" ]] && echo "BRUTAL: up=${brutal_up} down=${brutal_down}"
    else
      echo "UUID: ${uuid}"
    fi
    if [[ "$type" == "vless-reality" ]]; then
      echo "SNI: ${sni}"
    elif [[ "$type" == "vless-xhttp-reality" ]]; then
      echo "SNI: ${sni}  path: ${path}"
      echo "传输: XHTTP + REALITY + XMUX（无需证书，回落伪装）"
    elif [[ "$type" == "vless-xhttp" || "$type" == "vless-h2" ]]; then
      echo "域名: ${domain}  path: ${path}"
      echo "证书: ${cert_file}"
    fi
    echo
    echo "--- mihomo (Clash Meta) proxies 片段 ---"
    if [[ "$type" == "hysteria2" ]]; then
      gen_client_mihomo_hysteria2 "$name" "$ip" "$port" "$password" "$domain" "$brutal_up" "$brutal_down"
    else
      gen_client_mihomo "$type" "$name" "$ip" "$port" "$uuid" "$pub" "$sni" "$sid" "$domain" "$path"
    fi
    echo
    echo "--- sing-box outbounds 片段 ---"
    if [[ "$type" == "hysteria2" ]]; then
      gen_client_singbox_hysteria2 "$name" "$ip" "$port" "$password" "$domain" "$brutal_up" "$brutal_down"
    else
      gen_client_singbox "$type" "$name" "$ip" "$port" "$uuid" "$pub" "$sni" "$sid" "$domain" "$path"
    fi
    echo
  done
  echo "----------------------------------------------"
  echo "服务端 routing（优先级从高到低）:"
  echo "  block: geosite:category-ads-all"
  echo "  block: bittorrent"
  echo "  block: geoip:private"
  echo "  direct: geosite:google"
  echo "  block: geosite:cn"
  echo "  block: geoip:cn"
  # 版本兼容警告：mihomo 连 Xray >= 26.9.8 的 REALITY 必须显式开 X25519MLKEM768
  if jq -e '.protocols[] | select(.type=="vless-reality" or .type=="vless-xhttp-reality")' "$STATE_FILE" >/dev/null 2>&1; then
    echo "----------------------------------------------"
    echo "⚠ mihomo 客户端：REALITY 节点必须带 support-x25519mlkem768: true"
    echo "  （上面片段已含；Xray >= 26.9.8 对不带该扩展的握手直接拒绝，症状："
    echo "   REALITY authentication failed / 服务端 accepted=0。sing-box 不受影响）"
  fi
  echo "=============================================="
}
