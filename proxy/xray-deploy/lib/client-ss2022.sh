#!/usr/bin/env bash
# client-ss2022.sh — SS2022 (shadowsocks 2022) 客户端片段生成
#
# 定位：**中转机 → 落地机** 这一段（境外↔境外）的落地协议。
#
# ⚠️ 架构约束（2026-09-18 用户明确）：
#   出境段（客户端↔中转）必须用 REALITY —— SS2022 无 TLS 外观、主动探测特征明显，
#   跨境使用会被风控。故本协议只用于境外↔境外一跳，**不实现 relay 模式**
#   （relay 模式要求客户端用双密钥直连中转机 = 出境段走 SS，已被排除）。
#
# 加密方法：2022-blake3-aes-256-gcm（32 字节 key）

# SS2022 密钥（32 字节 → base64；aes-256-gcm 与 chacha20-poly1305 均 32 字节）
gen_ss2022_key() {
  openssl rand -base64 32
}

# 支持的加密方法（只列 Xray 支持且 key 长度一致的）
SS2022_METHODS=(
  "2022-blake3-aes-256-gcm|AES-256-GCM（推荐，有 AES 硬件加速时最快）"
  "2022-blake3-chacha20-poly1305|ChaCha20-Poly1305（无 AES 加速的 ARM 上更快）"
)

# mihomo 客户端片段（直连落地机）
# $1=name $2=ip $3=port $4=method $5=password
gen_client_mihomo_ss2022() {
  cat <<EOF
  - name: "xray-${1}"
    type: ss
    server: ${2}
    port: ${3}
    cipher: ${4}
    password: "${5}"
    udp: true
EOF
}

# sing-box 客户端片段（直连落地机）
# $1=name $2=ip $3=port $4=method $5=password
gen_client_singbox_ss2022() {
  cat <<EOF
{
  "type": "shadowsocks",
  "tag": "xray-${1}",
  "server": "${2}",
  "server_port": ${3},
  "method": "${4}",
  "password": "${5}"
}
EOF
}
