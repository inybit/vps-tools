#!/usr/bin/env bash
# registry.sh — 协议注册表（可扩展）
#
# 新增协议步骤见 SKILL.md「新增协议 11 处触点」；注册表只是第 1 处。

# ============ 协议注册表（可扩展） ============
# 新增协议步骤:
#   1. PROTO_REGISTRY 加一行: name|显示名|服务二进制
#   2. 实现 gen_inbound_<name> / gen_client_mihomo_<name> / gen_client_singbox_<name>
#   3. 在 state.json 的 protocols[] 里存该协议参数
PROTO_REGISTRY=(
  "vless-reality|VLESS-TCP-XTLS-Vision-REALITY|xray"
  "vless-xhttp-reality|VLESS-XHTTP-REALITY (XHTTP+XMUX)|xray"
  "vless-xhttp|VLESS-XHTTP-H2-TLS|xray"
  "hysteria2|Hysteria2 (hy2)|xray"
  "ss2022|SS2022 (shadowsocks 2022)|xray"
)

proto_exists() {  # $1=name
  local line
  for line in "${PROTO_REGISTRY[@]}"; do
    [[ "${line%%|*}" == "$1" ]] && return 0
  done
  return 1
}

proto_display() {  # $1=type
  local line
  for line in "${PROTO_REGISTRY[@]}"; do
    [[ "${line%%|*}" == "$1" ]] && { echo "${line#*|}"; return 0; }
  done
  echo "$1"
}
