#!/usr/bin/env bash
# chain-info.sh — 链路拓扑展示与配置自检
#
# 与 chain.sh 的分工：chain.sh 负责配置（export/import/setup/remove），
# 本文件只读（show/test），不修改 state。

# ---------- show：链路拓扑 ----------
chain_show() {
  [[ -f "$STATE_FILE" ]] || die "尚未安装（state.json 不存在）"
  local role up
  role="$(jq -r '.chain.role // "none"' "$STATE_FILE" 2>/dev/null || echo none)"
  echo "=============================================="
  echo " 链路拓扑"
  echo "=============================================="
  if [[ "$role" == "none" ]]; then
    echo "未配置链路（单机模式）"
    echo
    echo "本机协议:"
    proto_list_names
    echo "=============================================="
    return 0
  fi
  up="$(jq -c '.chain.upstream' "$STATE_FILE")"
  echo "角色: 中转机（relay）"
  echo "本机 IP: $(state_get '.server_ip')"
  echo
  echo "出口路径:"
  echo "  客户端 ──[REALITY]──→ 本机（中转）──[$(jq -r '.type' <<<"$up")]──→ 落地机 ──→ 目标"
  echo
  echo "落地机（upstream）:"
  jq -r '"  类型:   " + .type,
         "  地址:   " + .address + ":" + (.port|tostring),
         (if .type == "ss2022" then
            "  方法:   " + .method + "\n  密钥:   " + .password
          else
            "  UUID:   " + .uuid + "\n  SNI:    " + .sni + "\n  pubkey: " + .public_key
          end)' <<<"$up"
  echo
  echo "本机服务端协议（客户端连这些）:"
  proto_list_names
  echo "----------------------------------------------"
  chain_mode_show
  echo "  切换: xray-deploy chain mode <模式>（'chain mode list' 查看可选）"
  echo "=============================================="
}

# ---------- test：链路配置自检（不发起任何跨境连接） ----------
# ⚠️ 只做配置层校验，不产生跨境 SS 握手（用户安全约束：SS 不得本地测跨境连通性）。
#    真实连通性由部署后的客户端实测。
chain_test() {
  [[ -f "$STATE_FILE" ]] || die "尚未安装"
  local role
  role="$(jq -r '.chain.role // "none"' "$STATE_FILE" 2>/dev/null || echo none)"
  [[ "$role" != "none" ]] || die "未配置链路（先 chain setup 或 chain import）"

  [[ -x "$BIN_PATH" ]] || die "xray 二进制缺失: ${BIN_PATH}"
  log_info "链路配置自检（仅配置层，不发起跨境连接）..."
  log_info "  1) 生成含落地 outbound 的配置并做 xray -test 语法校验"
  build_config
  log_info "  2) 落地 outbound 是否进入配置"
  if jq -e '.outbounds[] | select(.tag=="landing")' "$CONFIG_FILE" >/dev/null 2>&1; then
    log_info "     ✓ landing outbound 存在"
  else
    log_warn "     ✗ landing outbound 缺失（chain 配置未生效）"
    return 1
  fi
  log_info "  3) routing 是否指向落地"
  if jq -e '.routing.rules[] | select(.outboundTag=="landing")' "$CONFIG_FILE" >/dev/null 2>&1; then
    log_info "     ✓ routing 有指向 landing 的规则"
  else
    log_warn "     ✗ routing 未指向 landing —— 流量不会走落地机"
    return 1
  fi
  log_info "配置层自检通过。"
}
