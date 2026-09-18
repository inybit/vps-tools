#!/usr/bin/env bash
# chain.sh — 中转 + 落地（链式代理）配置命令族
#
# 架构（方案 A 协议级链式，2026-09-18 用户确认）：
#   客户端 ──[REALITY，抗探测]──→ 中转机 ──[SS2022，境外↔境外]──→ 落地机 ──→ 目标
#
#   中转机：跑 Xray 服务端（REALITY inbound）+ landing outbound 指向落地机
#   落地机：跑 Xray 服务端（SS2022 inbound），普通 install 即可，零特殊改动
#   客户端：**零改动**，仍用中转机的 REALITY 参数
#
# ⚠️ 出境段必须 REALITY（2026-09-18 用户明确）：SS2022 无 TLS 外观、
#    主动探测特征明显，跨境会被风控 → 故不实现 relay 模式
#    （relay 要求客户端直连中转走 SS 双密钥 = 出境段走 SS，已被排除）。
#
# 拓扑展示与自检见 chain-info.sh。

# ---------- 在【落地机】生成可粘贴的上游参数 ----------
chain_export() {
  [[ -f "$STATE_FILE" ]] || die "尚未安装（state.json 不存在）"
  local n
  n="$(jq '[.protocols[] | select(.type=="ss2022")] | length' "$STATE_FILE" 2>/dev/null || echo 0)"
  [[ "$n" -gt 0 ]] || die "本机没有 ss2022 协议——请先 'protocol add' 添加 ss2022（作为落地协议）"

  local ip name port method password
  ip="$(state_get '.server_ip')"
  name="$(jq -r '[.protocols[] | select(.type=="ss2022")][0].name' "$STATE_FILE")"
  port="$(jq -r '[.protocols[] | select(.type=="ss2022")][0].port' "$STATE_FILE")"
  method="$(jq -r '[.protocols[] | select(.type=="ss2022")][0].method' "$STATE_FILE")"
  password="$(jq -r '[.protocols[] | select(.type=="ss2022")][0].password' "$STATE_FILE")"

  # 纯 JSON 到 stdout（可直接复制粘贴到中转机 chain import）
  jq -nc --arg addr "$ip" --argjson port "$port" \
         --arg method "$method" --arg password "$password" --arg name "$name" '
    { type: "ss2022", name: $name, address: $addr, port: $port,
      method: $method, password: $password }'
  log_info "（以上 JSON 复制到中转机执行: xray-deploy chain import）"
}

# ---------- 校验上游参数（import / 向导共用） ----------
chain_validate_upstream() {  # $1=上游 JSON；返回 0=合法
  local up="$1" type
  jq -e . >/dev/null 2>&1 <<<"$up" || { log_err "不是合法 JSON"; return 1; }
  type="$(jq -r '.type // empty' <<<"$up")"
  case "$type" in
    ss2022)
      for f in address port method password; do
        [[ -n "$(jq -r --arg f "$f" '.[$f] // empty' <<<"$up")" ]] \
          || { log_err "缺少 ${f}"; return 1; }
      done
      validate_ss2022_key "$(jq -r '.password' <<<"$up")" \
        || { log_err "password 非法：必须 32 字节 base64（落地机 protocol add ss2022 生成）"; return 1; }
      ;;
    vless-reality)
      for f in address port uuid public_key sni; do
        [[ -n "$(jq -r --arg f "$f" '.[$f] // empty' <<<"$up")" ]] \
          || { log_err "缺少 ${f}"; return 1; }
      done
      ;;
    *) log_err "不支持的 type: ${type}（支持 ss2022 / vless-reality）"; return 1 ;;
  esac
  return 0
}

chain_set_upstream() {  # $1=上游 JSON
  local up="$1"
  chain_validate_upstream "$up" || die "上游参数校验失败"
  state_set --argjson up "$up" '.chain = {role: "relay", upstream: $up}'
  log_info "已写入链路配置（role=relay）"
}

# ---------- import：粘贴落地机 export 的 JSON ----------
chain_import() {
  need_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装，先运行: xray-deploy install"
  local json
  if [[ -n "${1:-}" ]]; then
    json="$1"
  else
    log_info "请粘贴落地机 'chain export' 输出的 JSON（单行），然后回车:"
    read_input "> " json
  fi
  [[ -n "$json" ]] || die "未输入内容"
  chain_set_upstream "$json"
  rebuild_and_reload
  log_info "链路已生效。运行 'xray-deploy chain show' 查看拓扑"
}

# ---------- setup：向导式手工输入 ----------
chain_setup() {
  need_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装，先运行: xray-deploy install"
  log_info "中转 + 落地 链路配置向导"
  log_info "  本机 = 中转机（客户端连它）；落地机 = 实际出口"
  log_info "  推荐流程：落地机 'protocol add'（选 ss2022）→ 落地机 'chain export'"
  log_info "            → 把 JSON 粘贴到本机 'chain import'"
  echo >&2
  log_info "可选类型: 1) ss2022（推荐，境外↔境外）  2) vless-reality"
  local t
  read_input "选择 [1-2，回车默认 1]: " t
  t="${t:-1}"

  local up
  case "$t" in
    1)
      local addr port method password
      read_input "落地机 IP: " addr
      [[ -n "$addr" ]] || die "IP 不能为空"
      read_input "落地机 ss2022 端口: " port
      [[ "$port" =~ ^[0-9]+$ ]] || die "端口非法"
      log_info "加密方法:"
      method="$(select_ss2022_method)" || die "方法选择失败"
      read_input "落地机 ss2022 密钥（落地机添加协议时生成/填入的那个）: " password
      validate_ss2022_key "$password" || die "密钥非法：必须 32 字节 base64"
      up="$(jq -nc --arg addr "$addr" --argjson port "$port" \
                    --arg method "$method" --arg password "$password" \
        '{type:"ss2022", name:"landing", address:$addr, port:$port,
          method:$method, password:$password}')"
      ;;
    2)
      local addr port uuid pubkey sni sid
      read_input "落地机 IP: " addr
      read_input "落地机端口: " port
      [[ "$port" =~ ^[0-9]+$ ]] || die "端口非法"
      read_input "落地机 UUID: " uuid
      read_input "落地机 REALITY public_key: " pubkey
      read_input "落地机 SNI: " sni
      read_input "落地机 short_id（可空）: " sid
      up="$(jq -nc --arg addr "$addr" --argjson port "$port" --arg uuid "$uuid" \
                    --arg pub "$pubkey" --arg sni "$sni" --arg sid "$sid" \
        '{type:"vless-reality", name:"landing", address:$addr, port:$port,
          uuid:$uuid, public_key:$pub, sni:$sni, short_id:$sid, fingerprint:"chrome"}')"
      ;;
    *) die "无效选择" ;;
  esac

  chain_set_upstream "$up"
  rebuild_and_reload
  log_info "链路已生效。运行 'xray-deploy chain show' 查看拓扑"
}

# ---------- remove：拆链路 ----------
chain_remove() {
  need_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装"
  local role
  role="$(jq -r '.chain.role // "none"' "$STATE_FILE" 2>/dev/null || echo none)"
  [[ "$role" != "none" ]] || { log_info "本机未配置链路"; return 0; }
  read -r -p "确认拆除链路（回到单机模式）？[y/N]: " yn
  [[ "${yn,,}" == "y" ]] || { log_info "已取消"; return 0; }
  state_set 'del(.chain)'
  rebuild_and_reload
  log_info "链路已拆除，回到单机模式"
}
