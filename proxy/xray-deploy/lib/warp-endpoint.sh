#!/usr/bin/env bash
# warp-endpoint.sh — WARP endpoint 的 IPv4 收敛（本机无公网 IPv6 时必须用 IPv4 字面量）
#
# 根因（2026-11-08 源码核对 + 真机 DNS 实测，勿凭记忆改）：
#   Xray 的 wireguard 出站**不把** peers[].endpoint 当静态地址用：
#     proxy/wireguard/client.go  bind.resolveFunc = MakeResolveLocal(d, streamSettings)
#     MakeResolveLocal           LookupIP 同时开 IPv4Enable / IPv6Enable，末行
#                                  return got[dice.Roll(len(got))], nil
#                                —— 在 A + AAAA 结果里**随机挑一个**
#     bind.ParseEndpoint         把这个随机结果固定成对端地址
#     bind.listenFunc            另跑一次 net.ParseDestination("udp:"+endpoint) 走系统解析
#   实测 engage.cloudflareclient.com：ahosts 里 AAAA（2606:4700:d0::a29f:c001）在前，
#   A = 162.159.192.1。**没有公网 IPv6 的机器**上，随机挑到 AAAA 的那次握手必然发不出去
#   → WARP 出站间歇失败 / 起不来（症状是「有时通有时不通」，极易误判成 CF 抽风）。
#   写成 IPv4 字面量后 MakeResolveLocal 首行 net.ParseIP(host) != nil 直接返回 →
#   不解析、不随机，行为确定。
#
# 决策面：与 IPv6 裁剪共用同一个开关（state 的 .warp.ipv6 = false）——
#   warp setup 在 ipv6=false 时改写 endpoint；gen_warp_outbound 对老 state 兜底解析。
#
# 解析器优先级：getent（libc-bin，基础包，遵守 /etc/hosts + nsswitch）
#              → host -t A（bind9-host）→ dig +short A（dnsutils，非基础包）。
#   全部套 timeout 5：rebuild 路径也会调用，解析器卡住会拖死线上重建。
#
# warp_endpoint_prefer_ipv4 返回码：
#   0 = stdout 是可用 endpoint（可能原样返回）
#   1 = 域名解析不出 IPv4 / endpoint 格式非法
#   2 = endpoint 是 IPv6 字面量（无 v6 的机器上用不了，由调用方决定报错方式）

# 点分四段 IPv4（不做数值范围校验：输出来自 getent/dig，只防脏行）
warp_is_ipv4() { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

# endpoint 的 host 部分（IPv6 去方括号）；格式非法 return 1
warp_endpoint_host() {
  [[ "${1:-}" =~ ^(\[[0-9a-fA-F:]+\]|[^:]+):[0-9]+$ ]] || return 1
  local h="${BASH_REMATCH[1]}"
  [[ "$h" == \[*\] ]] && h="${h:1:${#h}-2}"
  printf '%s\n' "$h"
}

# 域名 → 首个 A 记录（stdout）；解析不出 IPv4 return 1
warp_resolve_ipv4() {
  local host="${1:-}" out="" a=()
  [[ -n "$host" ]] || return 1
  if command -v timeout >/dev/null 2>&1; then a=(timeout 5); fi
  if command -v getent >/dev/null 2>&1; then
    out="$("${a[@]}" getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 { print $1 }')" || out=""
  fi
  if ! warp_is_ipv4 "$out" && command -v host >/dev/null 2>&1; then
    out="$("${a[@]}" host -t A "$host" 2>/dev/null | awk '/has address/ { print $NF; exit }')" || out=""
  fi
  if ! warp_is_ipv4 "$out" && command -v dig >/dev/null 2>&1; then
    out="$("${a[@]}" dig +short +time=3 +tries=1 A "$host" 2>/dev/null | awk 'NR==1 { print $1 }')" || out=""
  fi
  warp_is_ipv4 "$out" || return 1
  printf '%s\n' "$out"
}

# endpoint（host:port）→ IPv4 字面量（stdout）；返回码见文件头
warp_endpoint_prefer_ipv4() {
  local ep="${1:-}" host v4
  host="$(warp_endpoint_host "$ep")" || return 1
  [[ "$host" == *:* ]] && return 2          # IPv6 字面量：不做 CF 内嵌 v4 反解，交调用方报错
  if warp_is_ipv4 "$host"; then printf '%s\n' "$ep"; return 0; fi
  v4="$(warp_resolve_ipv4 "$host")" || return 1
  printf '%s:%s\n' "$v4" "${ep##*:}"
}
