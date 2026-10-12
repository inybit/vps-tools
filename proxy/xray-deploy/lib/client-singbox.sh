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

# hy2 客户端片段：自签证书用【证书指纹 pin】，不再用 insecure
# $1=name $2=ip $3=port $4=password $5=domain $6=brutal_up $7=brutal_down $8=pin_hex(忽略) $9=pin_pubkey_b64
#
# ⚠️ sing-box 的 pin 是【公钥 SPKI 的 sha256】（base64），不是整证书哈希
#    （common/tls/std_client.go VerifyPublicKeySHA256：sha256(MarshalPKIXPublicKey)）；
#    字段 certificate_public_key_sha256 自 1.13.0 起可用（整证书版 certificate_sha256 要 1.15.0）。
# ⚠️ 与 mihomo 同理：设置该字段后 sing-box 会 InsecureSkipVerify=true
#    → 不能再写 insecure: true，否则 pin 白写。
gen_client_singbox_hysteria2() {
  # BRUTAL 带宽字符串（如 "100 mbps"）→ sing-box 需数字（up_mbps/down_mbps）
  local name="$1" ip="$2" port="$3" password="$4" domain="$5" bup="$6" bdown="$7" pubpin="$9"
  local up_num down_num
  up_num="$(echo "${bup:-}" | grep -oE '^[0-9]+' || true)"
  down_num="$(echo "${bdown:-}" | grep -oE '^[0-9]+' || true)"
  cat <<EOF
{
  "type": "hysteria2",
  "tag": "xray-${name}",
  "server": "${ip}",
  "server_port": ${port},
  "password": "${password}",
  "tls": {
    "enabled": true,
    "server_name": "${domain:-${ip}}",
EOF
  if [[ -n "${pubpin:-}" ]]; then
    cat <<EOF
    "certificate_public_key_sha256": ["${pubpin}"],
EOF
  else
    cat <<'EOF'
    "insecure": true,
EOF
    printf '%s\n' "    // 无 pin 数据（state 里没有 cert_pin_pubkey_sha256，通常是本次升级前部署的）" \
                  "    // 暂退回跳过校验；重跑 protocol edit 选 2（重签证书）即可自动带上指纹。" >&2
  fi
  cat <<EOF
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

gen_client_singbox_vless_xhttp3_nginx() {  # $1=name $2=ip $3=port $4=uuid $5=pubkey(忽略) $6=sni(忽略) $7=shortid(忽略) $8=domain $9=path
  # sing-box 上游不支持 XHTTP（含 h3 形态），需 sing-box-extended / lx fork
  # ⚠️ server 填【域名】而非本机 IP：本协议几乎都配 CF SaaS，填 IP 会绕过 CF
  #    直连源站，SNI=用户域名但源站证书是 CF Origin CA *.007233.xyz → 校验失败
  #    （与 mihomo 片段同一根因，2026-09-19 事故）
  cat <<EOF
# sing-box 上游不支持 XHTTP，请使用 sing-box-extended 或 sing-box-lx：
{
  "type": "vless",
  "tag": "xray-${1}",
  "server": "${8}",
  "server_port": ${3},
  "uuid": "${4}",
  "tls": {
    "enabled": true,
    "server_name": "${8}",
    "alpn": ["h3"]
  },
  "transport": {
    "type": "xhttp",
    "host": "${8}",
    "path": "${9}",
    "mode": "stream-one"
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
    vless-xhttp3-nginx) gen_client_singbox_vless_xhttp3_nginx "$@" ;;
    hysteria2) gen_client_singbox_hysteria2 "$@" ;;
    ss2022) gen_client_singbox_ss2022 "$@" ;;
    *) die "未实现的客户端生成: ${type}" ;;
  esac
}
