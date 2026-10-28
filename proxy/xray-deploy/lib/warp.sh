#!/usr/bin/env bash
# warp.sh — WARP 回国出站（WireGuard）核心：profile 解析 / 校验 / 出站生成 / state 读写
#
# 命令族（setup/show/test/remove）在 lib/warp-cmd.sh —— 与 chain.sh / chain-info.sh 同一拆法。
#
# 背景：回国流量（geosite:cn + geoip:cn）原先一律 blackhole；导入 WARP 后改走 tag=warp 的出站。
#
# 字段依据（Xray 官方文档 config/outbounds/wireguard 实测核对，勿凭记忆改）：
#   settings: secretKey / address[] / peers[].{endpoint,publicKey,allowedIPs} /
#             mtu / remoteDNS[] / reserved[3] / noKernelTun
#   · 隧道内目标**必须是 IP** → 域名由 remoteDNS 在隧道内解析（即 profile 的 DNS 行）
#   · noKernelTun **省略** = Xray 自动检测（有 CAP_NET_ADMIN 用内核 TUN，否则 gVisor）。
#     本工具默认不写该字段（用户 2026-10-28 决定「内核默认就好」）；
#     文档明确警告自动检测在部分 LXC 上会误判 → 出站失败时用 `warp setup --no-tun` 强制 gVisor。
#   · 内核 TUN 占 IPv6 路由表 10230，同机第二个 wireguard 出站顺延 10231，第三个实例会撞车。
#
# 私钥只存在于 state.json（600）与内存；show / info / 日志一律打码（末 4 位）。

WARP_OUTBOUND_TAG="warp"

# WireGuard 密钥固定 32 字节 base64 = 44 字符、末位 '='
warp_key_valid() { [[ "${1:-}" =~ ^[A-Za-z0-9+/]{43}=$ ]]; }

warp_mask_key() { local k="${1:-}"; if [[ ${#k} -gt 4 ]]; then printf '…%s' "${k: -4}"; else printf '…'; fi; }

# 逗号分隔 → JSON 字符串数组（trim + 去空项）
warp_list_json() {
  tr ',' '\n' <<<"${1:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | sed '/^$/d' | jq -R . | jq -s -c .
}

# 解析 wgcf-profile.conf（INI）→ 单行 JSON；失败 return 1（错误走 stderr）
# 输出: {private_key, address[], dns[], mtu, public_key, allowed_ips[], endpoint}
warp_parse_profile() {
  local f="${1:-}" kv priv="" addr="" dns="" mtu="" pub="" ips="" ep="" npeer=0 k v line
  [[ -n "$f" && -r "$f" ]] || { log_err "无法读取 profile: ${f:-<空>}"; return 1; }
  # CRLF / 首尾空白 / 注释(# ;) / [段] 归一化；值按**首个** '=' 切分（base64 密钥末尾自带 '='）
  kv="$(awk '
    { sub(/\r$/,""); sub(/^[ \t]+/,""); sub(/[ \t]+$/,"") }
    /^$/ || /^[#;]/ { next }
    /^\[/ { s=tolower($0); gsub(/[\[\]]/,"",s); next }
    /=/ { k=tolower(substr($0,1,index($0,"=")-1)); gsub(/[ \t]/,"",k)
          v=substr($0,index($0,"=")+1); gsub(/^[ \t]+|[ \t]+$/,"",v)
          print s "." k "=" v }
  ' "$f")"
  # ⚠️ 不能用 `while IFS='=' read -r k v`：行尾的 '=' 会被当分隔符吃掉
  #    （base64 密钥末位正是 '='），实测导致 warp_key_valid 恒判非法。
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    k="${line%%=*}"
    v="${line#*=}"
    case "$k" in
      interface.privatekey) priv="$v" ;;
      interface.address)    addr="$v" ;;
      interface.dns)        dns="$v" ;;
      interface.mtu)        mtu="$v" ;;
      peer.publickey)       pub="$v"; npeer=$((npeer + 1)) ;;
      peer.allowedips)      ips="$v" ;;
      peer.endpoint)        ep="$v" ;;
    esac
  done <<<"$kv"

  [[ -n "$priv" ]] || { log_err "profile 缺 PrivateKey（[Interface] 段）"; return 1; }
  warp_key_valid "$priv" || { log_err "PrivateKey 非法：需 32 字节 base64（44 字符、末位 '='）"; return 1; }
  [[ -n "$pub" ]] || { log_err "profile 缺 PublicKey（[Peer] 段）"; return 1; }
  warp_key_valid "$pub" || { log_err "PublicKey 非法：需 32 字节 base64（44 字符、末位 '='）"; return 1; }
  [[ "$npeer" -le 1 ]] || { log_err "profile 含 ${npeer} 个 [Peer]，本工具只支持单对端"; return 1; }
  [[ -n "$ep" ]] || { log_err "profile 缺 Endpoint（[Peer] 段）"; return 1; }
  [[ "$ep" =~ ^(\[[0-9a-fA-F:]+\]|[^:]+):[0-9]+$ ]] \
    || { log_err "Endpoint 非法: ${ep}（应为 host:port）"; return 1; }
  [[ -n "${addr// /}" ]] || { log_err "profile 缺 Address（[Interface] 段）"; return 1; }
  mtu="${mtu:-1280}"
  if ! [[ "$mtu" =~ ^[0-9]+$ ]] || (( mtu < 576 || mtu > 1500 )); then
    log_err "MTU 非法: ${mtu}（应在 576-1500）"; return 1
  fi

  local ajson djson ijson
  # 缺前缀的地址补 /32（v4）或 /128（v6）；已有前缀原样保留
  ajson="$(warp_list_json "$addr" | jq -c 'map(if test("/") then . elif test(":") then . + "/128" else . + "/32" end)')"
  djson="$(warp_list_json "$dns")"
  ijson="$(warp_list_json "${ips:-0.0.0.0/0, ::/0}")"

  jq -nc --arg priv "$priv" --argjson addr "$ajson" --argjson dns "$djson" \
         --argjson mtu "$mtu" --arg pub "$pub" --argjson ips "$ijson" --arg ep "$ep" '
    { private_key: $priv, address: $addr, dns: $dns, mtu: $mtu,
      public_key: $pub, allowed_ips: $ips, endpoint: $ep }'
}

# ============ 本机 IPv6 能力与裁剪 ============
# 本机是否有公网 IPv6（2000::/3 全局单播）→ 0=有
# 数据源 /proc/net/if_inet6（首列 = 32 位十六进制地址，无冒号）：
#   ::1        → 0000…0001（首字符 0）
#   fe80::/10  → fe80…（首字符 f，链路本地）
#   fd00::/8   → fd…（首字符 f，ULA）
#   公网       → 2xxx / 3xxx（首字符 2 或 3）
# 不看 disable_ipv6 / v6 默认路由：内核 TUN 需要的是「能加 v6 地址」，有公网 v6 即成立。
#
# ⚠️ 必须排除 Xray 自己的内核 TUN 接口 wg0/wg1…（Xray proxy/wireguard/tun.go
#    CalculateInterfaceName("wg")）。否则换 key 时——旧实例还在跑、wg0 上挂着
#    **旧 key 的 WARP v6 地址**（2606:4700:… / 2a09:bac5:…，首字符都是 2）——
#    这个隧道地址会被当成「本机有公网 IPv6」→ 新出站保留 v6 → 没有原生 v6 的机器上
#    内核 TUN 加 v6 路由失败，整个 WARP 出站起不来（2026-10-28 报障的根因）。
# WARP_IF_INET6_FILE 仅供测试注入假数据，生产不设。
warp_local_has_public_ipv6() {
  local f="${WARP_IF_INET6_FILE:-/proc/net/if_inet6}"
  [[ -r "$f" ]] || return 1
  awk '$1 ~ /^[23]/ && $6 !~ /^wg[0-9]+$/ { f = 1 } END { exit(f ? 0 : 1) }' "$f" 2>/dev/null
}

# 剔除 v6 条目（address / dns / allowed_ips 里带 ':' 的项）→ 单行 JSON
# remoteDNS 也要剔：隧道内没有 v6 路由，留 v6 DNS 会让域名解析失败。
warp_strip_ipv6() {
  jq -c '.address |= map(select(test(":") | not))
         | .dns |= map(select(test(":") | not))
         | .allowed_ips |= map(select(test(":") | not))' <<<"${1:-{\}}"
}

# 出站是否配置 IPv6：state 显式 .warp.ipv6 优先；缺省（1.15.0 前的老 state）按本机实时探测
warp_ipv6_enabled() {
  local v="auto"
  if [[ -n "${STATE_FILE:-}" && -r "${STATE_FILE:-}" ]]; then
    # ⚠️ 不能用 `.warp.ipv6 // "auto"`：jq 的 // 把 false 也当空值 → false 会被替换成 auto
    v="$(jq -r 'if .warp.ipv6 == null then "auto" else (.warp.ipv6 | tostring) end' \
           "$STATE_FILE" 2>/dev/null || echo auto)"
  fi
  case "$v" in
    true)  return 0 ;;
    false) return 1 ;;
  esac
  warp_local_has_public_ipv6
}

# ============ 状态与出站 ============
warp_enabled() {
  [[ -f "${STATE_FILE:-}" ]] || return 1
  [[ "$(jq -r '.warp.enabled // false' "$STATE_FILE" 2>/dev/null || echo false)" == "true" ]]
}

# 从 state.json 的 .warp 生成 wireguard 出站（未启用则输出空）
gen_warp_outbound() {
  warp_enabled || return 0
  local w s
  w="$(jq -c '.warp' "$STATE_FILE" 2>/dev/null || true)"
  [[ -n "$w" && "$w" != "null" ]] || return 0
  # 本机无公网 IPv6 → 出站不配置 v6（老 state 无 .warp.ipv6 时按本机实时探测）
  if ! warp_ipv6_enabled; then
    if s="$(warp_strip_ipv6 "$w")" && [[ "$(jq -r '.address | length' <<<"$s")" -gt 0 ]]; then
      w="$s"
    fi
  fi
  gen_outbound_wireguard "$WARP_OUTBOUND_TAG" "$w"
}

# 写 state：保留导入来源与时间；no_kernel_tun 为 null 时不落字段（= Xray 自动检测）
warp_write_state() {  # $1=parse 输出 JSON $2=来源描述 $3=no_kernel_tun(true|false|null)
  local tmp
  tmp="$(mktemp)" || return 1
  jq --argjson w "$1" --arg src "${2:-}" --argjson tun "${3:-null}" \
     '.warp = ($w + { enabled: true, imported_at: (now | todate), source: $src }
              + (if $tun == null then {} else { no_kernel_tun: $tun } end))' \
     "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

# 从 stdin / tty 读至单独一行 EOF → 输出临时文件路径
# （INI 里空行合法，不能用空行当终止；临时文件 600，调用方解析后立即删除）
warp_read_pasted() {
  local t line
  t="$(mktemp "${TMPDIR:-/tmp}/wgcf-profile.XXXXXX")" || return 1
  chmod 600 "$t"
  log_info "粘贴 profile 全文，粘贴完成后单独一行输入 EOF 回车：" >&2
  while IFS= read -r line; do
    [[ "$line" == "EOF" ]] && break
    printf '%s\n' "$line" >> "$t"
  done
  printf '%s\n' "$t"
}
