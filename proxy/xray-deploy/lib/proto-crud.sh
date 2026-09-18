#!/usr/bin/env bash
# proto-crud.sh — 协议增删 / 列表 / 名称解析 / 重建重载

proto_add() {
  need_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装，先运行: xray-deploy.sh install"
  local name type
  echo "可选协议类型:"
  local i=1 line disp
  for line in "${PROTO_REGISTRY[@]}"; do
    IFS='|' read -r _ disp _ <<<"$line"
    echo "  $i) $disp"
    i=$((i+1))
  done
  read -r -p "选择协议类型 [1-$((i-1))]: " t
  t="${t:-1}"
  [[ "$t" =~ ^[0-9]+$ ]] && [[ "$t" -ge 1 ]] && [[ "$t" -le "$((i-1))" ]] || die "无效选择"
  type="${PROTO_REGISTRY[$((t-1))]%%|*}"

  read -r -p "协议名称 [默认 ${type}-01]: " name
  name="${name:-${type}-01}"
  [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]] || die "名称只允许字母数字_-"

  local params
  case "$type" in
    vless-reality) params="$(proto_wizard_vless_reality "$name")" || die "协议参数生成失败" ;;
    vless-xhttp-reality) params="$(proto_wizard_vless_xhttp_reality "$name")" || die "协议参数生成失败" ;;
    vless-xhttp|vless-h2) params="$(proto_wizard_vless_xhttp "$name")" || die "协议参数生成失败" ;;
    hysteria2) params="$(proto_wizard_hysteria2 "$name")" || die "协议参数生成失败" ;;
    *) die "未实现的协议向导: ${type}" ;;
  esac

  # 追加到 state（参数对象），inbound 由 build_config 推导
  state_set --argjson p "$params" '.protocols += [$p]'
  rebuild_and_reload
  log_info "协议 ${name}（${type}）已添加"
}

proto_remove() {
  need_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装"
  local name
  proto_list_names
  read -r -p "输入要删除的协议名称或序号: " name
  name="$(resolve_proto_name "$name")" || return 1
  read -r -p "确认删除协议 ${name}？[y/N]: " yn
  [[ "${yn,,}" == "y" ]] || { log_info "已取消"; return 0; }
  state_set --arg n "$name" '.protocols = [.protocols[] | select(.name != $n)]'
  rebuild_and_reload
  log_info "协议 ${name} 已删除"
}

proto_list_names() {
  log_info "现有协议:"
  jq -r '.protocols | to_entries[] | "  [\(.key+1)] \(.value.name)  (\(.value.type))  端口 \(.value.port)\(if .value.type == "hysteria2" then "/UDP" else "" end)  \(if (.value.type == "vless-xhttp" or .value.type == "vless-h2") then "域名 " + .value.domain elif .value.type == "hysteria2" then "SNI " + (.value.domain // "-") elif .value.type == "vless-xhttp-reality" then "SNI " + .value.sni + "  path " + .value.path else "SNI " + .value.sni end)"' "$STATE_FILE"
}

# 解析协议选择：支持序号（[1]）或名称；输出协议 name；找不到 die
resolve_proto_name() {  # $1=输入
  local input="$1" name
  if [[ "$input" =~ ^[0-9]+$ ]]; then
    name="$(jq -r --argjson i "$((input-1))" '.protocols[$i].name // ""' "$STATE_FILE")"
    [[ -n "$name" ]] || die "序号 ${input} 无效"
    echo "$name"
  else
    [[ -n "$input" ]] || die "名称不能为空"
    local count
    count="$(jq --arg n "$input" '[.protocols[] | select(.name==$n)] | length' "$STATE_FILE")"
    [[ "$count" -eq 1 ]] || die "协议 ${input} 不存在"
    echo "$input"
  fi
}

# 重建配置并重载服务（增删改后调用）
rebuild_and_reload() {
  build_config
  service_restart
}
