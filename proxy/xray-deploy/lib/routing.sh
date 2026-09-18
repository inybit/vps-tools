#!/usr/bin/env bash
# routing.sh — 分流模式（哪些流量走落地机）定义 + routing 规则生成
#
# 设计：mode 只控制【走落地 vs 中转直出】；安全底线 block 规则永远保留、不参与分流。
#   这样切换 mode 不会削弱安全策略，语义单一、可验证。
#
# ⚠️ geosite 标签全部按铁律查证存在（2026-09-18 实测 MetaCubeX geo/geosite/*.yaml）：
#    category-ai-!cn(179 条) google(1071) youtube(178) openai(22)
#    **新增标签前必须先 curl 验证**，能覆盖就不手写 DOMAIN-SUFFIX。

# 底线 block 规则（永远保留，与 mode 无关）
#   ads-all        广告
#   bittorrent     BT（防滥用）
#   geoip:private  私网（防内网探测）
#   geosite:cn / geoip:cn  国内站点黑洞
ROUTING_BASE_RULES='[
  { "type": "field", "outboundTag": "block", "domain": ["geosite:category-ads-all"] },
  { "type": "field", "outboundTag": "block", "protocol": ["bittorrent"] },
  { "type": "field", "outboundTag": "block", "ip": ["geoip:private"] },
  { "type": "field", "outboundTag": "block", "domain": ["geosite:cn"] },
  { "type": "field", "outboundTag": "block", "ip": ["geoip:cn"] }
]'

# 预设模式 → 落地域名标签（空格分隔；"*" = 全部）。返回 1 = 未知模式
routing_preset_domains() {
  case "$1" in
    all)               echo "*" ;;
    none)              echo "" ;;
    ai)                echo "geosite:category-ai-!cn geosite:openai" ;;
    google)            echo "geosite:google" ;;
    youtube)           echo "geosite:youtube" ;;
    ai-google)         echo "geosite:category-ai-!cn geosite:openai geosite:google" ;;
    ai-google-youtube) echo "geosite:category-ai-!cn geosite:openai geosite:google geosite:youtube" ;;
    custom:*)          tr ',' ' ' <<<"${1#custom:}" ;;
    *) return 1 ;;
  esac
}

routing_preset_list() {
  cat <<'EOF'
可用分流模式（mode = 哪些流量走落地机）:
  all                全部流量走落地（除下方底线 block）
  none               全部直出（保留链路配置但不用落地）
  ai                 AI 类走落地：geosite:category-ai-!cn + geosite:openai
  google             Google 走落地：geosite:google
  youtube            YouTube 走落地：geosite:youtube
  ai-google          AI + Google 走落地
  ai-google-youtube  AI + Google + YouTube 走落地
  custom:<标签,...>  自定义，如 custom:geosite:netflix,geosite:spotify

底线 block 规则（永远保留，与 mode 无关）:
  广告 geosite:category-ads-all / BT / 私网 geoip:private / 国内 geosite:cn + geoip:cn
EOF
}

# 当前模式（无 chain 或未设置时默认 all）
routing_current_mode() {
  local m
  m="$(jq -r '.chain.mode // "all"' "$STATE_FILE" 2>/dev/null || true)"
  echo "${m:-all}"
}

# 生成 routing rules：底线 block + 按 mode 决定「落地 / 直出」
# ⚠️ 顺序即优先级（Xray 首次匹配生效）：block 底线在前，落地白名单居中，catch-all 最后。
# ⚠️ 无 chain 时不追加任何 landing 规则（单机模式行为与拆分前一致）。
build_routing_rules_json() {
  if ! jq -e '.chain.upstream' "$STATE_FILE" >/dev/null 2>&1; then
    printf '%s' "$ROUTING_BASE_RULES"; return 0
  fi
  local mode domains rules
  mode="$(routing_current_mode)"
  if ! domains="$(routing_preset_domains "$mode")"; then
    log_warn "未知分流模式 '${mode}'，回退 all"
    mode=all; domains="*"
  fi
  rules="$ROUTING_BASE_RULES"
  if [[ "$domains" == "*" ]]; then
    # all：catch-all 走落地
    jq -c --arg tag "$LANDING_OUTBOUND_TAG" \
      '. + [{ "type": "field", "network": "tcp,udp", "outboundTag": $tag }]' <<<"$rules"
  elif [[ -z "${domains// /}" ]]; then
    # none：catch-all 直出
    jq -c '[.[], { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }]' <<<"$rules"
  else
    # 白名单 → 落地；其余直出
    local djson
    djson="$(tr ' ' '\n' <<<"$domains" | sed '/^$/d' | jq -R . | jq -s -c .)"
    jq -c --arg tag "$LANDING_OUTBOUND_TAG" --argjson d "$djson" \
      '. + [{ "type": "field", "domain": $d, "outboundTag": $tag },
            { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }]' <<<"$rules"
  fi
}

# ---------- chain mode 子命令 ----------
chain_mode_show() {
  local mode domains
  mode="$(routing_current_mode)"
  domains="$(routing_preset_domains "$mode" 2>/dev/null || echo "?")"
  echo "当前分流模式: ${mode}"
  if [[ "$domains" == "*" ]]; then
    echo "  落地: 全部流量（除底线 block）"
  elif [[ -z "${domains// /}" ]]; then
    echo "  落地: 无（全部直出）"
  else
    echo "  落地: $(tr ' ' ',' <<<"$domains")"
    echo "  其余: 中转机直出"
  fi
}

chain_mode() {  # $1=模式（空/show=显示，list=列出）
  local m="${1:-}"
  # ⚠️ list 是纯帮助文本，不需要 state、不需要 root（未安装也能查有哪些模式）
  if [[ "$m" == "list" ]]; then routing_preset_list; return 0; fi
  [[ -f "$STATE_FILE" ]] || die "尚未安装（state.json 不存在）"
  # ⚠️ show 是只读操作，不需要 root
  if [[ -z "$m" || "$m" == "show" ]]; then chain_mode_show; return 0; fi

  # 以下为写操作（改 state + 重启服务）→ 需要 root
  need_root
  jq -e '.chain.upstream' "$STATE_FILE" >/dev/null 2>&1 \
    || die "未配置链路——分流模式仅对链路生效（先 chain setup/import）"
  routing_preset_domains "$m" >/dev/null 2>&1 \
    || die "未知分流模式: ${m}（运行 'chain mode list' 查看可用模式）"

  state_set --arg m "$m" '.chain.mode = $m'
  rebuild_and_reload
  log_info "分流模式已切换"
  chain_mode_show
}
