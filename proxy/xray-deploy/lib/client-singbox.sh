#!/usr/bin/env bash
# client-singbox.sh — sing-box 客户端片段生成
#
# ⚠️ sing-box 上游不支持 XHTTP（stream-up / auto），需 sing-box-extended 或 sing-box-lx fork

gen_client_singbox_vless_reality() {  # 同 mihomo 参数顺序
  cat <<EOF
{
  "type": "vless",
  "tag": "xray-${1}",
  "server": "${2}",
  "server_port": ${3},
  "uuid": "${4}",
  "flow": "xtls-rprx-vision",
  "tls": {
    "enabled": true,
    "server_name": "${6}",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": { "enabled": true, "public_key": "${5}", "short_id": "${7}" }
  }
}
EOF
}

gen_client_singbox_vless_xhttp() {  # $1=name $2=ip $3=port $4=uuid $5=pubkey(忽略) $6=sni(忽略) $7=shortid(忽略) $8=domain $9=path
  # 注意：sing-box 上游不支持 XHTTP（Xray 26.x h2 迁移后的形态），需 sing-box-extended/lx fork
  cat <<EOF
# sing-box 上游不支持 XHTTP（stream-up），请使用 sing-box-extended 或 sing-box-lx：
{
  "type": "vless",
  "tag": "xray-${1}",
  "server": "${2}",
  "server_port": ${3},
  "uuid": "${4}",
  "tls": {
    "enabled": true,
    "server_name": "${8}"
  },
  "transport": {
    "type": "xhttp",
    "host": "${8}",
    "path": "${9}",
    "mode": "stream-up"
  }
}
EOF
}

gen_client_singbox_hysteria2() {  # $1=name $2=ip $3=port $4=password $5=domain $6=brutal_up $7=brutal_down
  # BRUTAL 带宽字符串（如 "100 mbps"）→ sing-box 需数字（up_mbps/down_mbps）
  local up_num down_num
  up_num="$(echo "${6:-}" | grep -oE '^[0-9]+' || true)"
  down_num="$(echo "${7:-}" | grep -oE '^[0-9]+' || true)"
  cat <<EOF
{
  "type": "hysteria2",
  "tag": "xray-${1}",
  "server": "${2}",
  "server_port": ${3},
  "password": "${4}",
  "tls": {
    "enabled": true,
    "server_name": "${5:-${2}}",
    "insecure": true,
    "alpn": ["h3"]
  }
EOF
  if [[ -n "$up_num" && -n "$down_num" ]]; then
    cat <<EOF
  ,"up_mbps": ${up_num},
  "down_mbps": ${down_num}
EOF
  fi
  cat <<EOF
}
EOF
}

gen_client_singbox_vless_xhttp_reality() {  # 同 mihomo 参数顺序
  # 注意：sing-box 上游不支持 XHTTP，需 sing-box-extended/lx fork（同 vless-xhttp）
  cat <<EOF
# sing-box 上游不支持 XHTTP，请使用 sing-box-extended 或 sing-box-lx：
{
  "type": "vless",
  "tag": "xray-${1}",
  "server": "${2}",
  "server_port": ${3},
  "uuid": "${4}",
  "tls": {
    "enabled": true,
    "server_name": "${6}",
    "utls": { "enabled": true, "fingerprint": "chrome" },
    "reality": { "enabled": true, "public_key": "${5}", "short_id": "${7}" }
  },
  "transport": {
    "type": "xhttp",
    "host": "${6}",
    "path": "${9}",
    "mode": "auto"
  }
}
EOF
}

gen_client_singbox() {  # $1=type 其余参数透传
  local type="$1"; shift
  case "$type" in
    vless-reality) gen_client_singbox_vless_reality "$@" ;;
    vless-xhttp-reality) gen_client_singbox_vless_xhttp_reality "$@" ;;
    vless-xhttp|vless-h2) gen_client_singbox_vless_xhttp "$@" ;;
    hysteria2) gen_client_singbox_hysteria2 "$@" ;;
    ss2022) gen_client_singbox_ss2022 "$@" ;;
    *) die "未实现的客户端生成: ${type}" ;;
  esac
}
