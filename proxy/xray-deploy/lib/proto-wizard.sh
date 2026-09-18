#!/usr/bin/env bash
# proto-wizard.sh — 各协议的交互向导（输出协议参数 JSON 对象）

# ============ 协议向导 ============
proto_wizard_vless_reality() {  # $1=name → 输出 JSON 参数对象
  local name="$1" port uuid keys priv pub sni sid
  read -r -p "端口 [默认 443]: " port
  port="${port:-443}"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] || die "无效端口"
  port_in_use "$port" && die "端口 ${port} 已被占用"
  sni="$(select_fallback_domain)" || die "回落域名选择失败"
  uuid="$(gen_uuid)"
  keys="$(gen_reality_keys)"
  priv="${keys%% *}"; pub="${keys##* }"
  sid="$(gen_short_id)"
  jq -n --arg name "$name" --argjson port "$port" --arg uuid "$uuid" \
    --arg priv "$priv" --arg pub "$pub" --arg sni "$sni" --arg sid "$sid" '
    {
      name: $name, type: "vless-reality",
      port: $port, uuid: $uuid,
      private_key: $priv, public_key: $pub,
      sni: $sni, short_id: $sid, short_ids: [$sid]
    }'
}

proto_wizard_vless_xhttp_reality() {  # $1=name → 输出 JSON 参数对象
  local name="$1" port path uuid keys priv pub sni sid conflict
  read -r -p "端口 [默认 443]（REALITY 建议 443，非 443 会提高被 GFW 封锁概率）: " port
  port="${port:-443}"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] || die "无效端口"
  # 硬约束（2026-09-17 实测）：同端口绑两个 REALITY inbound 时内核按 SO_REUSEPORT 随机分发、
  # SNI 不参与分流 → 客户端约 30% 概率拿到错误 REALITY 配置，报 "received real certificate"。
  # 故同端口已有 REALITY 类协议时必须拒绝，而不是靠端口占用检测（xray -test 不绑定端口，测不出）。
  conflict="$(jq -r --argjson p "$port" \
    '.protocols[] | select(.port==$p and (.type=="vless-reality" or .type=="vless-xhttp-reality")) | .name' \
    "$STATE_FILE" 2>/dev/null | head -1 || true)"
  if [[ -n "$conflict" ]]; then
    die "端口 ${port} 已被 REALITY 协议 ${conflict} 占用——同端口多 REALITY 会因 SO_REUSEPORT 随机分发导致约 30% 连接串台（实测），请改用其他端口或先删除 ${conflict}"
  fi
  port_in_use "$port" && die "端口 ${port} 已被占用"
  ensure_firewall "$port" tcp
  path=""
  read -r -p "XHTTP path [默认 /xray]: " path
  path="${path:-/xray}"
  [[ "$path" == /* ]] || die "path 必须以 / 开头"
  sni="$(select_fallback_domain)" || die "回落域名选择失败"
  uuid="$(gen_uuid)"
  keys="$(gen_reality_keys)"
  priv="${keys%% *}"; pub="${keys##* }"
  [[ -n "$priv" && -n "$pub" ]] || die "REALITY 密钥生成失败（xray x25519 输出解析异常）"
  sid="$(gen_short_id)"
  jq -n --arg name "$name" --argjson port "$port" --arg uuid "$uuid" \
    --arg priv "$priv" --arg pub "$pub" --arg sni "$sni" --arg sid "$sid" --arg path "$path" '
    {
      name: $name, type: "vless-xhttp-reality",
      port: $port, uuid: $uuid,
      private_key: $priv, public_key: $pub,
      sni: $sni, short_id: $sid, short_ids: [$sid], path: $path
    }'
}

proto_wizard_vless_xhttp() {  # $1=name → 输出 JSON 参数对象
  local name="$1" port domain path uuid certs cert_file key_file
  read -r -p "端口 [默认 8443]（443 被 REALITY 占用时用独立端口）: " port
  port="${port:-8443}"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] || die "无效端口"
  port_in_use "$port" && die "端口 ${port} 已被占用"
  read -r -p "域名（必须已解析到本机）: " domain
  [[ -n "$domain" ]] || die "域名不能为空"
  read -r -p "HTTP/2 path [默认 /xray]: " path
  path="${path:-/xray}"
  [[ "$path" == /* ]] || die "path 必须以 / 开头"
  certs="$(obtain_cert "$domain")" || die "证书获取失败"
  cert_file="${certs%% *}"; key_file="${certs##* }"
  uuid="$(gen_uuid)"
  jq -n --arg name "$name" --argjson port "$port" --arg uuid "$uuid" \
    --arg domain "$domain" --arg path "$path" \
    --arg cert_file "$cert_file" --arg key_file "$key_file" '
    {
      name: $name, type: "vless-xhttp",
      port: $port, uuid: $uuid,
      domain: $domain, path: $path,
      cert_file: $cert_file, key_file: $key_file
    }'
}

proto_wizard_hysteria2() {  # $1=name → 输出 JSON 参数对象
  local name="$1" port domain password certs cert_file key_file masq yn conflict brutal_up brutal_down
  # 端口冲突处理：hy2 走 UDP，TCP 同端口被占（如 reality 443）不冲突可共存；
  # UDP 端口真被占（其他 hy2/服务）才提示卸载或取消
  read -r -p "端口 [默认 443/UDP]（hy2 官方建议 443，模拟 HTTP/3；TCP 同端口被 REALITY 占用可共存）: " port
  port="${port:-443}"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] || die "无效端口"
  if port_in_use "$port" udp; then
    conflict="$(jq -r --argjson p "$port" '.protocols[] | select(.port==$p) | .name' "$STATE_FILE" 2>/dev/null | head -1 || true)"
    if [[ -n "$conflict" ]]; then
      log_warn "端口 ${port}/UDP 已被协议 ${conflict} 占用"
      read_input "是否卸载协议 ${conflict} 后继续？[y/N]: " yn
      if [[ "${yn,,}" == "y" ]]; then
        state_set --arg n "$conflict" '.protocols = [.protocols[] | select(.name != $n)]'
        rebuild_and_reload
        log_info "已卸载 ${conflict}"
      else
        die "端口 ${port} 冲突，安装取消（可换端口重试）"
      fi
    else
      log_warn "端口 ${port}/UDP 被非 xray-deploy 服务占用"
      read_input "是否继续？[y/N]: " yn
      [[ "${yn,,}" == "y" ]] || die "安装取消"
    fi
  else
    log_info "UDP ${port} 空闲（TCP 同端口占用不影响，TCP/UDP 独立）"
  fi
  ensure_firewall "$port" udp
  read -r -p "SNI/域名（自签证书时客户端 insecure，可填域名或回车用 IP）: " domain
  domain="${domain:-}"
  read -r -p "密码 [回车自动生成]: " password
  if [[ -z "$password" ]]; then
    password="$(openssl rand -base64 18 | tr -d '=+/' | head -c 24)"
  fi
  certs="$(obtain_cert "${domain:-localhost}")" || die "证书获取失败"
  cert_file="${certs%% *}"; key_file="${certs##* }"
  read -r -p "masquerade 伪装 URL（可选，如 https://www.bing.com，回车跳过）: " masq
  masq="${masq:-}"
  # BRUTAL 拥塞控制：服务端 + 客户端必须配套设置 up/down（客户端不设会连接失败）
  read -r -p "BRUTAL 上行带宽（如 100 mbps，回车不启用）: " brutal_up
  brutal_up="$(normalize_bandwidth "${brutal_up:-}")"
  read -r -p "BRUTAL 下行带宽（如 100 mbps，回车不启用）: " brutal_down
  brutal_down="$(normalize_bandwidth "${brutal_down:-}")"
  if [[ -n "$brutal_up" || -n "$brutal_down" ]]; then
    [[ -n "$brutal_up" && -n "$brutal_down" ]] || die "BRUTAL 需同时设置上行与下行带宽"
    log_warn "BRUTAL 启用：客户端（mihomo up/down、sing-box up_mbps/down_mbps）必须同步设置，否则连接失败"
  fi
  jq -n --arg name "$name" --argjson port "$port" --arg password "$password" \
    --arg domain "$domain" --arg cert_file "$cert_file" --arg key_file "$key_file" \
    --arg masq "$masq" --arg brutal_up "$brutal_up" --arg brutal_down "$brutal_down" '
    {
      name: $name, type: "hysteria2",
      port: $port, password: $password,
      domain: $domain,
      cert_file: $cert_file, key_file: $key_file
    }
    + (if ($masq != "") then { masquerade: $masq } else {} end)
    + (if ($brutal_up != "" and $brutal_down != "") then { brutal_up: $brutal_up, brutal_down: $brutal_down } else {} end)'
}
