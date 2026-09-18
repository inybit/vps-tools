#!/usr/bin/env bash
# outbound.sh — 中转机侧的「落地机 outbound」生成
#
# 用途：中转机用 routing outboundTag 把流量交给该 outbound，由它拨号到落地机。
#
# ⚠️ 两个必须遵守的语义（源码核实，见 vps-script-distribution 技能）：
#   1. **不要用 freedom + sockopt.dialerProxy** —— 官方 freedom 文档明写：
#      「若此出站配置了 sockopt.dialerProxy，Freedom 就不再是最终出站，
#        因此不会执行 finalRules 或默认安全策略」→ 链式落地直接用本 outbound。
#   2. **出站链式的官方入口是 `streamSettings.sockopt.dialerProxy`**，
#      旧的 `outbound.proxySettings` 已废弃（infra/conf/xray.go 直接报
#      PrintRemovedFeatureError，报错文案指向 dialerProxy）。

# 生成落地 outbound（SS2022）
# $1=tag $2=落地ip $3=落地port $4=method $5=password
gen_outbound_ss2022() {
  jq -n --arg tag "$1" --arg addr "$2" --argjson port "$3" \
        --arg method "$4" --arg password "$5" '
    {
      tag: $tag, protocol: "shadowsocks",
      settings: {
        address: $addr, port: $port,
        method: $method, password: $password
      }
    }'
}

# 落地 outbound 的 tag 命名（固定值，便于 routing 引用与 info 展示）
LANDING_OUTBOUND_TAG="landing"

# 从 state.json 的 chain.upstream 生成落地 outbound
# 读全局 $STATE_FILE；无 chain 配置时输出空
gen_landing_outbound() {
  local up type
  up="$(jq -c '.chain.upstream // empty' "$STATE_FILE" 2>/dev/null || true)"
  [[ -n "$up" ]] || return 0
  type="$(jq -r '.type' <<<"$up")"
  case "$type" in
    ss2022)
      gen_outbound_ss2022 "$LANDING_OUTBOUND_TAG" \
        "$(jq -r '.address' <<<"$up")" \
        "$(jq -r '.port' <<<"$up")" \
        "$(jq -r '.method' <<<"$up")" \
        "$(jq -r '.password' <<<"$up")"
      ;;
    vless-reality)
      gen_outbound_vless_reality "$LANDING_OUTBOUND_TAG" "$up"
      ;;
    *) die "不支持的落地协议类型: ${type}（支持 ss2022 / vless-reality）" ;;
  esac
}

# 生成落地 outbound（VLESS-REALITY）
# ⚠️ VLESS outbound 是 **flat 形态**（settings.address/port/id/encryption/flow），
#    不是 inbound 的 clients[]；vnext+users 是等价写法，二选一不可混。
# ⚠️ validateOutboundTransportSecurity 拒绝「非私网 + 无 TLS/加密」的 VLESS outbound
#    → 落地机是公网 IP，必须带 REALITY/TLS（下面已带）。
# $1=tag $2=upstream JSON
gen_outbound_vless_reality() {
  local tag="$1" up="$2"
  jq -n --arg tag "$tag" --argjson up "$up" '
    {
      tag: $tag, protocol: "vless",
      settings: {
        address: $up.address, port: $up.port,
        id: $up.uuid, encryption: "none",
        flow: ($up.flow // "xtls-rprx-vision")
      },
      streamSettings: {
        network: "tcp", security: "reality",
        realitySettings: {
          serverName: $up.sni,
          publicKey: $up.public_key,
          shortId: ($up.short_id // ""),
          fingerprint: ($up.fingerprint // "chrome"),
          spiderX: ($up.spider_x // "")
        }
      }
    }'
}
