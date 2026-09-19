#!/usr/bin/env bash
# client-mihomo.sh — mihomo(Clash Meta) 客户端片段生成
#
# ⚠️ REALITY 片段必须带 support-x25519mlkem768: true
#    （mihomo 默认剥离 X25519MLKEM768，Xray >= 26.9.8 对不带该扩展的握手直接拒绝；
#      症状 REALITY authentication failed / 服务端 accepted=0。sing-box 不受影响）

# ============ 客户端配置生成 ============
gen_client_mihomo_vless_reality() {  # $1=name $2=ip $3=port $4=uuid $5=pubkey $6=sni $7=shortid
  cat <<EOF
  - name: "xray-${1}"
    type: vless
    server: ${2}
    port: ${3}
    uuid: ${4}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${6}
    client-fingerprint: chrome
    reality-opts:
      public-key: ${5}
      short-id: ${7}
      # 必需：mihomo 默认剥离 X25519MLKEM768，Xray >= 26.9.8 对不带该扩展的握手直接拒绝
      # （症状：REALITY authentication failed / 服务端 accepted=0）
      support-x25519mlkem768: true
EOF
}

gen_client_mihomo_vless_xhttp() {  # $1=name $2=ip $3=port $4=uuid $5=pubkey(忽略) $6=sni(忽略) $7=shortid(忽略) $8=domain $9=path
  cat <<EOF
  - name: "xray-${1}"
    type: vless
    server: ${2}
    port: ${3}
    uuid: ${4}
    network: xhttp
    udp: true
    tls: true
    servername: ${8}
    xhttp-opts:
      path: ${9}
      mode: stream-up
EOF
}

gen_client_mihomo_hysteria2() {  # $1=name $2=ip $3=port $4=password $5=domain $6=brutal_up $7=brutal_down
  cat <<EOF
  - name: "xray-${1}"
    type: hysteria2
    server: ${2}
    port: ${3}
    password: ${4}
    sni: ${5:-${2}}
    skip-cert-verify: true
    alpn:
      - h3
EOF
  if [[ -n "${6:-}" && -n "${7:-}" ]]; then
    cat <<EOF
    up: ${6}
    down: ${7}
EOF
  fi
}

gen_client_mihomo_vless_xhttp_reality() {  # $1=name $2=ip $3=port $4=uuid $5=pubkey $6=sni $7=shortid $8=domain(忽略) $9=path
  cat <<EOF
  - name: "xray-${1}"
    type: vless
    server: ${2}
    port: ${3}
    uuid: ${4}
    network: xhttp
    udp: true
    tls: true
    servername: ${6}
    client-fingerprint: chrome
    xhttp-opts:
      path: ${9}
      mode: auto
      reuse-settings:          # = XMUX（仅客户端生效）
        max-concurrency: "16-32"
        c-max-reuse-times: "64-128"
        h-max-request-times: "600-900"
        h-max-reusable-secs: "1800-3000"
    reality-opts:
      public-key: ${5}
      short-id: ${7}
      # 必需：mihomo 默认剥离 X25519MLKEM768，Xray >= 26.9.8 对不带该扩展的握手直接拒绝
      # （症状：REALITY authentication failed / 服务端 accepted=0）
      support-x25519mlkem768: true
EOF
}

gen_client_mihomo_vless_xhttp3_nginx() {  # $1=name $2=ip $3=port $4=uuid $5=pubkey(忽略) $6=sni(忽略) $7=shortid(忽略) $8=domain $9=path
  # HTTP/3 (QUIC) 传输：alpn: [h3] 触发 mihomo 走 http3.Transport
  #   依据 mihomo transport/xhttp/client.go:159 `if len(alpn)==1 && alpn[0]=="h3"`
  # 无 REALITY → 不需要 support-x25519mlkem768
  # 不生成 reuse-settings(XMUX)：填了须对齐用户 nginx 上限（默认 128/1000/3600），
  #   留空则取 mihomo 保守默认（16-32 / 600-900 / 1800-3000）
  cat <<EOF
  - name: "xray-${1}"
    type: vless
    server: ${2}
    port: ${3}
    uuid: ${4}
    network: xhttp
    udp: true
    tls: true
    servername: ${8}
    alpn:
      - h3
    client-fingerprint: chrome
    xhttp-opts:
      path: ${9}
      mode: stream-one
EOF
}

# 生成某协议的客户端片段（按类型分发）
gen_client_mihomo() {  # $1=type 其余参数透传
  local type="$1"; shift
  case "$type" in
    vless-reality) gen_client_mihomo_vless_reality "$@" ;;
    vless-xhttp-reality) gen_client_mihomo_vless_xhttp_reality "$@" ;;
    vless-xhttp|vless-h2) gen_client_mihomo_vless_xhttp "$@" ;;
    vless-xhttp3-nginx) gen_client_mihomo_vless_xhttp3_nginx "$@" ;;
    hysteria2) gen_client_mihomo_hysteria2 "$@" ;;
    ss2022) gen_client_mihomo_ss2022 "$@" ;;
    *) die "未实现的客户端生成: ${type}" ;;
  esac
}
