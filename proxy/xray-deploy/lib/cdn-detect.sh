#!/usr/bin/env bash
# cdn-detect.sh — Cloudflare 前置判定（回落域名 / REALITY dest 的盗刷闸门）
#
# 为什么需要（2026-10-29）：
#   旧实现只在 openssl s_client 输出里 grep "cloudflare"，实际命中【证书签发者】。
#   CF 早已大量改用 GTS（WE1/YE1）、InCommon、Sectigo、Amazon 签证书 →
#   实测候选表 121 条里 13 条是 CF 前置，旧检测命中 0 条
#   （含标「实测可用」的 waseda.jp / ntu.edu.sg）。
#
# 为什么「解析 IP 落在 CF 段」是决定性信号：
#   REALITY 对未鉴权流量无脑转发到 dest（本工具 dest = sni:443）。dest 若是 CF 域名，
#   解析结果就是 CF 边缘 IP（共享 anycast 池）→ 本机变成 CF 免费端口转发器，
#   出站流量被扫全网的人白嫖；GFW 还能「回源取证」拿到本机充当节点的实锤。
#   上游依据：XTLS/Xray-core#2360（建议加默认 SNI 校验）、#5807（回源取证）。
#
# 三路取并集，任一命中即判 CF 前置：
#   ① cf-ray / server: cloudflare 响应头 —— CF 边缘注入，与 CA 轮换无关，最权威
#   ② A/AAAA 解析结果落在 CF 官方段 —— 盗刷通道本体
#   ③ 证书签发者含 cloudflare —— 历史信号，单独使用会漏判（保留做补充）
#
# 数据来源：https://www.cloudflare.com/ips-v4 、 /ips-v6（2026-10-29 抓取）
#   段变更不频繁；变更时手动同步下方两个数组（不联网拉取：保证可测、无网络依赖）。
#
# 局限（有意）：
#   - 只判 CF，不判 Fastly/Akamai/CloudFront（用户口径：只排除套 CF 的）
#   - getent 缺失（如未装 musl-utils 的 Alpine）时 IP 信号不可用 → 仍有 ①② 兜底
#   - v6 只做前 32 位匹配：CF 的 v6 段全部 ≤ /32，/29 那条按 /32 超集处理（偏保守）

CF_V4_RANGES=(
  173.245.48.0/20   103.21.244.0/22   103.22.200.0/22   103.31.4.0/22
  141.101.64.0/18   108.162.192.0/18  190.93.240.0/20   188.114.96.0/20
  197.234.240.0/22  198.41.128.0/17   162.158.0.0/15    104.16.0.0/13
  104.24.0.0/14     172.64.0.0/13     131.0.72.0/22
)

CF_V6_RANGES=(
  2400:cb00::/32  2606:4700::/32  2803:f800::/32
  2405:b500::/32  2405:8100::/32  2a06:98c0::/29  2c0f:f248::/32
)

# ---------- IP 运算（纯 bash，不依赖 awk/ipcalc） ----------
_ipv4_to_int() {  # $1=点分十进制 → 输出 32 位整数；非法 rc=1
  local a b c d
  IFS=. read -r a b c d <<<"$1"
  [[ "$a$b$c$d" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$d" ]] || return 1
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1
  echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

ip_in_cidr4() {  # $1=IPv4  $2=CIDR（如 104.16.0.0/13）
  local ip net pfx
  ip="$(_ipv4_to_int "$1")" || return 1
  net="$(_ipv4_to_int "${2%%/*}")" || return 1
  pfx="${2##*/}"
  [[ "$pfx" =~ ^[0-9]+$ ]] && (( pfx >= 0 && pfx <= 32 )) || return 1
  (( pfx == 0 )) && return 0
  (( (ip >> (32 - pfx)) == (net >> (32 - pfx)) ))
}

_ipv6_prefix32() {  # $1=IPv6 地址 → 输出前 32 位（8 位小写十六进制，如 26064700）；非法 rc=1
  local a="${1,,}" left right i n g
  [[ "$a" == *:* ]] || return 1
  a="${a%%\%*}"                       # 去 zone id（fe80::1%eth0）
  local -a lg=() rg=() groups=()
  if [[ "$a" == *::* ]]; then
    left="${a%%::*}"; right="${a#*::}"
    [[ -n "$left"  ]] && IFS=: read -ra lg <<<"$left"
    [[ -n "$right" ]] && IFS=: read -ra rg <<<"$right"
    n=$(( 8 - ${#lg[@]} - ${#rg[@]} ))
    (( n < 0 )) && return 1
    groups=("${lg[@]}")
    for ((i=0; i<n; i++)); do groups+=("0"); done
    groups+=("${rg[@]}")
  else
    IFS=: read -ra groups <<<"$a"
  fi
  [[ ${#groups[@]} -eq 8 ]] || return 1
  for g in "${groups[@]}"; do [[ "$g" =~ ^[0-9a-f]{1,4}$ ]] || return 1; done
  printf '%04x%04x\n' "$((16#${groups[0]}))" "$((16#${groups[1]}))"
}

ip_in_cf_v4() {  # $1=IPv4 → 落在任一 CF v4 段返回 0
  local r
  for r in "${CF_V4_RANGES[@]}"; do
    ip_in_cidr4 "$1" "$r" && return 0
  done
  return 1
}

ip_in_cf_v6() {  # $1=IPv6 → 前 32 位落在任一 CF v6 段返回 0
  local ip r net pfx mask
  ip="$(_ipv6_prefix32 "$1")" || return 1
  for r in "${CF_V6_RANGES[@]}"; do
    net="$(_ipv6_prefix32 "${r%%/*}")" || continue
    pfx="${r##*/}"
    (( pfx <= 32 )) || continue
    mask=$(( (0xffffffff << (32 - pfx)) & 0xffffffff ))
    (( (16#$ip & mask) == (16#$net & mask) )) && return 0
  done
  return 1
}

# ---------- CF 前置判定 ----------
# $1=域名  [$2=已抓到的 openssl s_client 输出（省一次握手）]
# 命中 → 输出原因（、分隔），rc=0；未命中 → 无输出，rc=1
cf_front_reason() {
  local d="$1" out="${2:-}" hdr ip reasons=()
  [[ -n "$d" ]] || return 1
  # ① CF 边缘响应头（HEAD 即可，403 挑战页同样带 cf-ray）
  hdr="$(curl -sI --max-time 8 -A 'Mozilla/5.0' "https://${d}/" 2>/dev/null || true)"
  grep -qi '^cf-ray:' <<<"$hdr" && reasons+=("cf-ray 响应头")
  grep -qiE '^server: *cloudflare' <<<"$hdr" && reasons+=("server: cloudflare")
  # ② 解析 IP ∈ CF 段（盗刷通道本体；REALITY 连接的就是这些 IP）
  if command -v getent >/dev/null 2>&1; then
    for ip in $(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u); do
      ip_in_cf_v4 "$ip" && { reasons+=("A ${ip} ∈ CF 段"); break; }
    done
    for ip in $(getent ahostsv6 "$d" 2>/dev/null | awk '{print $1}' | sort -u); do
      ip_in_cf_v6 "$ip" && { reasons+=("AAAA ${ip} ∈ CF 段"); break; }
    done
  fi
  # ③ 证书签发者（历史信号）
  [[ -n "$out" ]] && grep -qi 'cloudflare' <<<"$out" && reasons+=("证书签发者 Cloudflare")
  (( ${#reasons[@]} > 0 )) || return 1
  local IFS='、'
  printf '%s' "${reasons[*]}"
}
