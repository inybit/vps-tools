#!/usr/bin/env bash
# ss2022.sh — SS2022 (shadowsocks 2022) 协议向导与密钥校验
#
# 定位：**中转机 → 落地机** 这一跳（境外↔境外）的落地协议。
# ⚠️ 不用于出境段（客户端↔中转）—— SS2022 无 TLS 外观，跨境会被风控；
#    出境段必须 REALITY（2026-09-18 用户明确）。故本协议不实现 relay 模式。
#
# 加密方法 2022-blake3-*：key 必须是 32 字节的 base64（44 字符，以 = 结尾）。

# 校验 SS2022 密钥：base64 解码后必须恰好 32 字节
# 用法: validate_ss2022_key "<key>" → 0=合法
validate_ss2022_key() {
  local key="$1" bytes
  [[ -n "$key" ]] || return 1
  bytes="$(printf '%s' "$key" | base64 -d 2>/dev/null | wc -c)" || return 1
  [[ "$bytes" -eq 32 ]]
}

# 选择加密方法（输出方法名到 stdout；提示走 stderr 避免污染返回值）
select_ss2022_method() {
  local i=1 line m disp choice
  for line in "${SS2022_METHODS[@]}"; do
    IFS='|' read -r m disp <<<"$line"
    printf '  %d) %s — %s\n' "$i" "$m" "$disp" >&2
    i=$((i+1))
  done
  read_input "选择加密方法 [1-$((i-1))，回车默认 1]: " choice
  choice="${choice:-1}"
  [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le "$((i-1))" ]] || die "无效选择"
  IFS='|' read -r m _ <<<"${SS2022_METHODS[$((choice-1))]}"
  echo "$m"
}

proto_wizard_ss2022() {  # $1=name → 输出 JSON 参数对象
  local name="$1" port method password

  read -r -p "端口 [默认 8443]（TCP+UDP；SS2022 无 TLS 外观，端口选择无伪装意义）: " port
  port="${port:-8443}"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] || die "无效端口"
  # SS2022 同时监听 TCP 与 UDP，两侧都要检查
  port_in_use "$port" tcp && die "端口 ${port}/TCP 已被占用"
  port_in_use "$port" udp && die "端口 ${port}/UDP 已被占用"
  ensure_firewall "$port" tcp
  ensure_firewall "$port" udp

  log_info "加密方法（2022-blake3-*，均为 32 字节 key）:"
  method="$(select_ss2022_method)" || die "加密方法选择失败"

  read -r -p "密码 [回车自动生成 32 字节]（中转机需填同一个值）: " password
  if [[ -z "$password" ]]; then
    password="$(gen_ss2022_key)"
    log_info "已生成密钥: ${password}"
    log_warn "⚠️ 请立即记录该密钥——中转机 chain setup 需要填入同一值"
  fi
  validate_ss2022_key "$password" || die "密钥非法：必须是 32 字节的 base64（可用 'openssl rand -base64 32' 生成）"

  jq -n --arg name "$name" --argjson port "$port" \
    --arg method "$method" --arg password "$password" '
    {
      name: $name, type: "ss2022",
      port: $port, method: $method, password: $password
    }'
}
