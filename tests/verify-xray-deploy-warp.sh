#!/usr/bin/env bash
# WARP 回国出站回归：wgcf-profile.conf 解析 / 出站形态 / 路由三态 / 真实 xray -test / 私钥不外泄
#
# 验证要点：
#   [A] profile 解析：v4+v6 CIDR、DNS、MTU、Endpoint、AllowedIPs；无前缀地址自动补 /32 //128
#   [B] 校验拒绝：缺字段 / 非法 base64 / 多 [Peer] / Endpoint 无端口 / MTU 越界 —— 一律非 0 退出
#   [C] 出站形态：protocol=wireguard、tag=warp、secretKey/address/peers/mtu/remoteDNS；
#       **noKernelTun 恒写出，缺省 = true（gVisor 用户态，1.18.0+）**；no_kernel_tun:false → 内核 TUN
#   [D] 路由三态：warp 关 → cn 两条 block（历史行为）；warp 开 → cn 两条 warp、其余 block；
#       warp 开 + chain → cn 仍 warp 且 catch-all 走落地
#   [E] 真实 xray -test 接受该配置（无二进制时 SKIP，不计 FAIL）
#   [F] 私钥不外泄：warp show / info 输出里私钥出现 0 次，且只露末 4 位
#   [H] 内核 TUN 残留（换 key 场景）：v6 判定排除 wg0/wg1；策略路由清理只动表 10230-10240
#       （mock ip 断言调用面 + 真内核 netns 实测，无权限时 SKIP）
#   [I] warp test 的临时配置必须以 .json 结尾（26.10.21 起 -format=json 已被忽略）：
#       mock 断言 -config 指向 .json 且不再传该 flag + 真 xray 在 netns 里跑通自检
#   [J] endpoint 收敛成 IPv4（1.19.0+）：无公网 IPv6 时域名 endpoint 必须解析成 IPv4 字面量
#       —— Xray 的 MakeResolveLocal 在 A/AAAA 里 dice.Roll **随机挑一个**，无 v6 的机器上
#       约一半握手发不出去；setup 写死 IPv4，老 state 在 gen 时自愈
#
# 用法: bash tests/verify-xray-deploy-warp.sh
# 退出码: 0=全部通过
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${REPO}/proxy/xray-deploy"
MAIN="${TOOL}/xray-deploy.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
ck() {
  if [[ "$2" == "$3" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

echo "=== WARP 回国出站回归 ==="
echo

# ---------- 生成器探针（source 主脚本但截断分发段，避免真的执行命令） ----------
MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$MOCKBIN/xray"; chmod +x "$MOCKBIN/xray"

# 解析器打桩（[J] 用）：本机无公网 IPv6 的分支会解析 endpoint 域名，真解析在 CI 里
# 既依赖外网又会随 CF 的 A 记录漂移 → 默认返回 203.0.113.9。
# $TMP/mock-a 存在且非空 → 返回其内容；存在但为空 → 模拟解析失败。
# host / dig 一律 exit 1：逼解析走 getent 桩，失败用例才不会被真 DNS 兜回来。
REAL_GETENT="$(command -v getent || true)"
RESOLVEBIN="$TMP/resolvebin"; mkdir -p "$RESOLVEBIN"
cat > "$RESOLVEBIN/getent" <<EOS
#!/usr/bin/env bash
if [[ "\${1:-}" == "ahostsv4" ]]; then
  if [[ -f "${TMP}/mock-a" ]]; then
    [[ -s "${TMP}/mock-a" ]] || exit 1
    printf '%s   STREAM %s\n' "\$(cat "${TMP}/mock-a")" "\${2:-}"
    exit 0
  fi
  printf '203.0.113.9   STREAM %s\n203.0.113.9   DGRAM\n' "\${2:-}"
  exit 0
fi
exec "${REAL_GETENT:-/bin/false}" "\$@"
EOS
printf '#!/usr/bin/env bash\nexit 1\n' > "$RESOLVEBIN/host"
printf '#!/usr/bin/env bash\nexit 1\n' > "$RESOLVEBIN/dig"
chmod +x "$RESOLVEBIN/getent" "$RESOLVEBIN/host" "$RESOLVEBIN/dig"
export PATH="$RESOLVEBIN:$PATH"

GEN="$TMP/gen.sh"
cat > "$GEN" <<'GENPROBE'
set -uo pipefail
src="$1"; state="$2"; out="$3"; bin="$4"; shift 4
tmp="$(dirname "$src")/.nodisp.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"; rm -f "$tmp"
STATE_FILE="$state"; CONFIG_FILE="$out"; BIN_PATH="$bin"
service_restart() { :; }; need_root() { :; }; rebuild_and_reload() { :; }
# warp setup 的确认交互：测试里恒答 y（不能靠 stdin，read_input 在有 tty 时读 /dev/tty）
read_input() { printf -v "$2" "y"; return 0; }
"$@"
GENPROBE

# 真 xray（有则做 [E]；仓库测试约定：没有就 SKIP，不当 FAIL）
# 候选与 verify-xray-deploy-routing.sh 保持一致，不写死本机专属路径
XRAY_BIN="${XRAY_BIN:-}"
if [[ -z "$XRAY_BIN" ]]; then
  for cand in /tmp/hermes-ss2022-e2e/xray "$(command -v xray 2>/dev/null || true)"; do
    [[ -n "$cand" && -x "$cand" ]] && { XRAY_BIN="$cand"; break; }
  done
fi

# 假但格式合法的密钥（32 字节 base64 = 44 字符，末位 '='）
PRIV="$(printf 'A%.0s' {1..43})="
PUB="$(printf 'B%.0s' {1..43})="

PROFILE="$TMP/wgcf-profile.conf"
cat > "$PROFILE" <<PROF
[Interface]
PrivateKey = ${PRIV}
Address = 172.16.0.2/32, 2606:4700:110:8f1a:9b2c:3d4e:5f60:9c3d/128
DNS = 1.1.1.1, 1.0.0.1, 2606:4700:4700::1111, 2606:4700:4700::1001
MTU = 1280

[Peer]
PublicKey = ${PUB}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = engage.cloudflareclient.com:2408
PROF

parse() { bash "$GEN" "$MAIN" "$TMP/none.json" "$TMP/none.cfg" "$MOCKBIN/xray" warp_parse_profile "$1" 2>/dev/null; }

# ---------- A. 解析 ----------
echo "[A] profile 解析"
J="$(parse "$PROFILE")"
ck "PrivateKey"        "$(jq -r '.private_key' <<<"$J")" "$PRIV"
ck "PublicKey"         "$(jq -r '.public_key' <<<"$J")" "$PUB"
ck "Address 两条"      "$(jq -r '.address | length' <<<"$J")" "2"
ck "IPv4 原样保留"     "$(jq -r '.address[0]' <<<"$J")" "172.16.0.2/32"
ck "IPv6 原样保留"     "$(jq -r '.address[1]' <<<"$J")" "2606:4700:110:8f1a:9b2c:3d4e:5f60:9c3d/128"
ck "DNS 四条"          "$(jq -r '.dns | length' <<<"$J")" "4"
ck "DNS 首条"          "$(jq -r '.dns[0]' <<<"$J")" "1.1.1.1"
ck "MTU"               "$(jq -r '.mtu' <<<"$J")" "1280"
ck "Endpoint"          "$(jq -r '.endpoint' <<<"$J")" "engage.cloudflareclient.com:2408"
ck "AllowedIPs"        "$(jq -r '.allowed_ips | join(",")' <<<"$J")" "0.0.0.0/0,::/0"

# 无 CIDR 前缀 → 自动补
sed 's|Address = .*|Address = 172.16.0.2, 2606:4700:110::2|' "$PROFILE" > "$TMP/nocidr.conf"
J2="$(parse "$TMP/nocidr.conf")"
ck "v4 自动补 /32"     "$(jq -r '.address[0]' <<<"$J2")" "172.16.0.2/32"
ck "v6 自动补 /128"    "$(jq -r '.address[1]' <<<"$J2")" "2606:4700:110::2/128"

# CRLF（从 Windows 侧复制过来）
sed 's/$/\r/' "$PROFILE" > "$TMP/crlf.conf"
J3="$(parse "$TMP/crlf.conf")"
ck "CRLF: Endpoint 无 \\r" "$(jq -r '.endpoint' <<<"$J3")" "engage.cloudflareclient.com:2408"
ck "CRLF: MTU 可解析"      "$(jq -r '.mtu' <<<"$J3")" "1280"

# 无 DNS / 无 MTU → 用默认（不写 remoteDNS / mtu=1280）
grep -v -e '^DNS' -e '^MTU' "$PROFILE" > "$TMP/nodns.conf"
J4="$(parse "$TMP/nodns.conf")"
ck "无 DNS → 空数组"   "$(jq -r '.dns | length' <<<"$J4")" "0"
ck "无 MTU → 1280"     "$(jq -r '.mtu' <<<"$J4")" "1280"
echo

# ---------- B. 校验拒绝 ----------
echo "[B] 非法 profile 必须拒绝（且不产生 JSON）"
bad() {  # $1=说明 $2=文件
  local out rc
  out="$(bash "$GEN" "$MAIN" "$TMP/none.json" "$TMP/none.cfg" "$MOCKBIN/xray" \
         warp_parse_profile "$2" 2>/dev/null)"; rc=$?
  if [[ $rc -ne 0 && -z "$out" ]]; then
    printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else
    printf '  [FAIL] %s（rc=%s, 输出=%s）\n' "$1" "$rc" "${out:0:60}"; FAIL=$((FAIL+1))
  fi
}
grep -v '^PrivateKey' "$PROFILE" > "$TMP/b1.conf"; bad "缺 PrivateKey" "$TMP/b1.conf"
grep -v '^PublicKey'  "$PROFILE" > "$TMP/b2.conf"; bad "缺 PublicKey" "$TMP/b2.conf"
grep -v '^Endpoint'   "$PROFILE" > "$TMP/b3.conf"; bad "缺 Endpoint" "$TMP/b3.conf"
grep -v '^Address'    "$PROFILE" > "$TMP/b4.conf"; bad "缺 Address" "$TMP/b4.conf"
sed "s|^PrivateKey = .*|PrivateKey = tooshort|" "$PROFILE" > "$TMP/b5.conf"; bad "PrivateKey 非 44 字符 base64" "$TMP/b5.conf"
sed 's|^Endpoint = .*|Endpoint = engage.cloudflareclient.com|' "$PROFILE" > "$TMP/b6.conf"; bad "Endpoint 缺端口" "$TMP/b6.conf"
sed 's|^MTU = .*|MTU = 9999|' "$PROFILE" > "$TMP/b7.conf"; bad "MTU 越界" "$TMP/b7.conf"
cat "$PROFILE" > "$TMP/b8.conf"
printf '\n[Peer]\nPublicKey = %s\nEndpoint = 162.159.192.1:2408\n' "$PUB" >> "$TMP/b8.conf"
bad "多个 [Peer]" "$TMP/b8.conf"
bad "文件不存在" "$TMP/does-not-exist.conf"
echo

# ---------- C. 出站形态 ----------
echo "[C] wireguard 出站形态"
mk_state() {  # $1=warp 开关(on|off) $2=chain(on|off) $3=额外 warp 字段（JSON 片段，可空）
  local warp="$1" chain="$2" extra="${3:-}"
  jq -n --argjson w "$(parse "$PROFILE")" --arg warp "$warp" --arg chain "$chain" \
        --argjson extra "${extra:-{\}}" '
    {
      schema_version: 1, server_ip: "203.0.113.10",
      protocols: [{ name: "vless-reality-01", type: "vless-reality", port: 443,
                    uuid: "11111111-2222-3333-4444-555555555555",
                    private_key: "sDRObqZ2Ez65fdupFcV95W8TMLcYItEXl-cUojlqzW0",
                    public_key: "oXaK5pazZbzTPypmkGiEJBs4ofiHA-hncCU8wrmyhQQ",
                    sni: "www.example.com", short_id: "aabbccdd", short_ids: ["aabbccdd"] }]
    }
    + (if $warp == "on" then { warp: ($w + { enabled: true, imported_at: "2026-10-28T00:00:00Z", source: "test", ipv6: true } + $extra) } else {} end)
    + (if $chain == "on" then { chain: { role: "relay", mode: "ai", upstream: {
          type: "ss2022", name: "landing", address: "198.51.100.20", port: 8443,
          method: "2022-blake3-aes-256-gcm",
          password: "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" } } } else {} end)' \
    > "$TMP/state.json"
}

STATE="$TMP/state.json"; CFG="$TMP/cfg.json"
gen() { bash "$GEN" "$MAIN" "$STATE" "$CFG" "$MOCKBIN/xray" build_config >/dev/null 2>&1; }

mk_state on off; gen
ck "outbound 数 = 3（direct/block/warp）" "$(jq '.outbounds | length' "$CFG")" "3"
ck "protocol = wireguard"   "$(jq -r '.outbounds[] | select(.tag=="warp") | .protocol' "$CFG")" "wireguard"
ck "secretKey 已写入"       "$(jq -r '.outbounds[] | select(.tag=="warp") | .settings.secretKey' "$CFG")" "$PRIV"
ck "address 两条"           "$(jq '.outbounds[] | select(.tag=="warp") | .settings.address | length' "$CFG")" "2"
ck "peers[0].endpoint"      "$(jq -r '.outbounds[] | select(.tag=="warp") | .settings.peers[0].endpoint' "$CFG")" "engage.cloudflareclient.com:2408"
ck "peers[0].publicKey"     "$(jq -r '.outbounds[] | select(.tag=="warp") | .settings.peers[0].publicKey' "$CFG")" "$PUB"
ck "peers[0].allowedIPs"    "$(jq -r '.outbounds[] | select(.tag=="warp") | .settings.peers[0].allowedIPs | join(",")' "$CFG")" "0.0.0.0/0,::/0"
ck "mtu = 1280"             "$(jq '.outbounds[] | select(.tag=="warp") | .settings.mtu' "$CFG")" "1280"
ck "remoteDNS 四条（= profile DNS）" "$(jq '.outbounds[] | select(.tag=="warp") | .settings.remoteDNS | length' "$CFG")" "4"
ck "noKernelTun 缺省 = true（gVisor 用户态，1.18.0+）" \
  "$(jq -r '.outbounds[] | select(.tag=="warp") | .settings.noKernelTun' "$CFG")" "true"

mk_state on off '{"no_kernel_tun":false}'; gen
ck "no_kernel_tun:false → noKernelTun=false（内核 TUN）" \
  "$(jq -r '.outbounds[] | select(.tag=="warp") | .settings.noKernelTun' "$CFG")" "false"

mk_state on off '{"no_kernel_tun":true}'; gen
ck "no_kernel_tun:true → noKernelTun=true" \
  "$(jq -r '.outbounds[] | select(.tag=="warp") | .settings.noKernelTun' "$CFG")" "true"

# setup 端到端：默认 gVisor / --kernel-tun 切内核 TUN / --no-tun 兼容别名
setup_tun() {  # $@=额外参数 → 输出 .warp.no_kernel_tun
  cp "$STATE" "$TMP/setup-tun.json"
  WARP_IF_INET6_FILE=/dev/null bash "$GEN" "$MAIN" "$TMP/setup-tun.json" "$TMP/setup.cfg" \
    "$MOCKBIN/xray" warp_setup "$PROFILE" "$@" >/dev/null 2>&1
  jq -r '.warp.no_kernel_tun' "$TMP/setup-tun.json"
}
ck "setup 默认写 no_kernel_tun=true（gVisor）" "$(setup_tun)" "true"
ck "setup --kernel-tun 写 false（内核 TUN）"   "$(setup_tun --kernel-tun)" "false"
ck "setup --no-tun 仍写 true（兼容别名）"      "$(setup_tun --no-tun)" "true"

mk_state on off '{"reserved":[1,2,3]}'; gen
ck "reserved 显式给出才写" \
  "$(jq -r '.outbounds[] | select(.tag=="warp") | .settings.reserved | join(",")' "$CFG")" "1,2,3"

mk_state off off; gen
ck "warp 关：无 warp 出站" "$(jq '[.outbounds[] | select(.tag=="warp")] | length' "$CFG")" "0"
ck "warp 关：outbound 数 = 2" "$(jq '.outbounds | length' "$CFG")" "2"
echo

# ---------- D. 路由三态 ----------
echo "[D] 路由：回国流量目标 outbound"
cn_tags() { jq -r '[.routing.rules[] | select((.domain // []) | index("geosite:cn")) | .outboundTag] | join(",")' "$CFG"; }
n_tag()   { jq --arg t "$1" '[.routing.rules[] | select(.outboundTag==$t)] | length' "$CFG"; }

mk_state off off; gen
ck "warp 关：cn 两条 → block（历史行为）" "$(cn_tags)" "block"
ck "warp 关：block 共 5 条"                "$(n_tag block)" "5"
ck "warp 关：无 warp 规则"                 "$(n_tag warp)" "0"

mk_state on off; gen
ck "warp 开：cn 两条 → warp"   "$(cn_tags)" "warp"
ck "warp 开：block 降到 3 条（ads/BT/private）" "$(n_tag block)" "3"
ck "warp 开：warp 规则 2 条"   "$(n_tag warp)" "2"
ck "warp 开：规则总数仍 5"     "$(jq '.routing.rules | length' "$CFG")" "5"

mk_state on on; gen
ck "warp 开 + chain：cn 仍 → warp" "$(cn_tags)" "warp"
ck "warp 开 + chain：白名单走落地 1 条" \
  "$(jq '[.routing.rules[] | select(.outboundTag=="landing")] | length' "$CFG")" "1"
ck "warp 开 + chain：catch-all 直出（mode=ai）" "$(jq -r '.routing.rules[-1].outboundTag' "$CFG")" "direct"
ck "warp 开 + chain：规则总数 7（3 block + 2 warp + 1 landing + 1 direct）" \
  "$(jq '.routing.rules | length' "$CFG")" "7"
ck "warp 开 + chain：block 仍 3 条"    "$(n_tag block)" "3"

mk_state off on; gen
ck "warp 关 + chain：cn 回到 block" "$(cn_tags)" "block"
ck "warp 关 + chain：block 仍 5 条" "$(n_tag block)" "5"
echo

# ---------- E. 真实 xray -test ----------
echo "[E] 真实 xray -test"
if [[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]]; then
  echo "    使用: ${XRAY_BIN}（$("$XRAY_BIN" version 2>/dev/null | sed -n 1p)）"
  mk_state on off
  out="$(bash "$GEN" "$MAIN" "$STATE" "$CFG" "$XRAY_BIN" build_config 2>&1)"; rc=$?
  ck "xray -test 接受 warp 配置" "$rc" "0"
  if [[ $rc -ne 0 ]]; then printf '        %s\n' "$(tail -4 <<<"$out" | tr '\n' ' ')"; fi
  ck "生成配置含 wireguard outbound" \
    "$(jq -r '.outbounds[] | select(.tag=="warp") | .protocol' "$CFG" 2>/dev/null)" "wireguard"
else
  echo "  [SKIP] 无 xray 二进制（设 XRAY_BIN=/path/to/xray 可启用真实校验）"
  SKIP=$((SKIP+1))
fi
echo

# ---------- F. 私钥不外泄 ----------
echo "[F] 私钥不外泄（show / info 只露末 4 位）"
mk_state on off
SHOW="$(bash "$GEN" "$MAIN" "$STATE" "$CFG" "$MOCKBIN/xray" warp_show 2>&1)"
ck "warp show 中私钥出现次数 = 0" "$(grep -cF "$PRIV" <<<"$SHOW" || true)" "0"
ck "warp show 露末 4 位"          "$(grep -cF "…${PRIV: -4}" <<<"$SHOW" || true)" "1"
ck "warp show 网络栈 = gVisor（缺省按新默认）" \
  "$(grep -cF '网络栈   : gVisor 用户态（默认' <<<"$SHOW" || true)" "1"
INFO="$(bash "$GEN" "$MAIN" "$STATE" "$CFG" "$MOCKBIN/xray" cmd_info 2>&1)"
ck "info 中私钥出现次数 = 0" "$(grep -cF "$PRIV" <<<"$INFO" || true)" "0"
ck "info 显示 warp 规则"     "$(grep -c 'warp: geosite:cn' <<<"$INFO" || true)" "1"
mk_state off off
INFO2="$(bash "$GEN" "$MAIN" "$STATE" "$CFG" "$MOCKBIN/xray" cmd_info 2>&1)"
ck "warp 关时 info 仍显示 block: geosite:cn" "$(grep -c 'block: geosite:cn' <<<"$INFO2" || true)" "1"
mk_state on off '{"no_kernel_tun":false}'
SHOW_TUN="$(bash "$GEN" "$MAIN" "$STATE" "$CFG" "$MOCKBIN/xray" warp_show 2>&1)"
ck "warp show 显式内核 TUN（no_kernel_tun:false）" \
  "$(grep -cF '网络栈   : 内核 TUN（显式启用）' <<<"$SHOW_TUN" || true)" "1"
echo

# ---------- G. IPv6：本机无公网 IPv6 → 出站不配置 v6 ----------
echo "[G] IPv6 裁剪（本机无公网 IPv6 → 出站不配置 v6）"
IF6_NONE="$TMP/if_inet6.none"; IF6_PUB="$TMP/if_inet6.pub"
printf '00000000000000000000000000000001 01 80 10 80       lo\nfe800000000000000000000000000001 02 40 20 80     eth0\nfd000000000000000000000000000001 03 40 00 80     eth0\n' > "$IF6_NONE"
printf '2a0104f8000000000000000000000001 02 40 00 80     eth0\nfe800000000000000000000000000001 02 40 20 80     eth0\n' > "$IF6_PUB"

has6() { WARP_IF_INET6_FILE="$1" bash "$GEN" "$MAIN" "$TMP/none.json" "$TMP/none.cfg" "$MOCKBIN/xray" \
           warp_local_has_public_ipv6 >/dev/null 2>&1; echo $?; }
ck "仅 lo + fe80 + ULA → 判定无公网 v6" "$(has6 "$IF6_NONE")" "1"
ck "有 2a01: 全局地址 → 判定有"        "$(has6 "$IF6_PUB")" "0"
ck "文件不存在 → 判定无"               "$(has6 "$TMP/not-here")" "1"

# 本机探测结果注入（build_config 走 gen_warp_outbound）
gen6() { WARP_IF_INET6_FILE="$1" bash "$GEN" "$MAIN" "$STATE" "$CFG" "$MOCKBIN/xray" build_config >/dev/null 2>&1; }
w6() { jq -r ".outbounds[] | select(.tag==\"warp\") | $1" "$CFG"; }

mk_state on off '{"ipv6":false}'; gen6 "$IF6_PUB"
ck "ipv6=false：address 只剩 v4"        "$(w6 '.settings.address | join(",")')" "172.16.0.2/32"
ck "ipv6=false：allowedIPs 只剩 v4"     "$(w6 '.settings.peers[0].allowedIPs | join(",")')" "0.0.0.0/0"
ck "ipv6=false：remoteDNS 只剩 v4 两条" "$(w6 '.settings.remoteDNS | length')" "2"
ck "ipv6=false：整份配置无 ::/0"        "$(grep -c '::/0' "$CFG" || true)" "0"

mk_state on off '{"ipv6":true}'; gen6 "$IF6_NONE"
ck "ipv6=true：address 两条（本机无 v6 也不裁剪）" "$(w6 '.settings.address | length')" "2"
ck "ipv6=true：allowedIPs 含 ::/0"                 "$(w6 '.settings.peers[0].allowedIPs | join(",")')" "0.0.0.0/0,::/0"
ck "ipv6=true：remoteDNS 四条"                     "$(w6 '.settings.remoteDNS | length')" "4"

# 老 state（无 .warp.ipv6）：按本机实时探测 → 无 v6 时自愈裁剪
mk_state on off
jq 'del(.warp.ipv6)' "$STATE" > "$TMP/old.json" && mv "$TMP/old.json" "$STATE"
gen6 "$IF6_NONE"
ck "老 state + 本机无 v6 → 自动裁剪" "$(w6 '.settings.address | length')" "1"
gen6 "$IF6_PUB"
ck "老 state + 本机有 v6 → 不裁剪"   "$(w6 '.settings.address | length')" "2"

# setup 端到端：auto 探测无公网 v6 → state 记 ipv6=false 且已剔除 v6
cp "$STATE" "$TMP/setup-state.json"
WARP_IF_INET6_FILE="$IF6_NONE" bash "$GEN" "$MAIN" "$TMP/setup-state.json" "$TMP/setup.cfg" \
  "$MOCKBIN/xray" warp_setup "$PROFILE" >/dev/null 2>&1
ck "setup(auto,无 v6)：.warp.ipv6=false" "$(jq -r '.warp.ipv6' "$TMP/setup-state.json")" "false"
ck "setup：address 无 v6"               "$(jq '[.warp.address[] | select(test(":"))] | length' "$TMP/setup-state.json")" "0"
ck "setup：dns 无 v6"                   "$(jq '[.warp.dns[] | select(test(":"))] | length' "$TMP/setup-state.json")" "0"
ck "setup：allowed_ips 无 v6"           "$(jq '[.warp.allowed_ips[] | select(test(":"))] | length' "$TMP/setup-state.json")" "0"
ck "setup：show 标出「未配置」"         "$(WARP_IF_INET6_FILE="$IF6_NONE" bash "$GEN" "$MAIN" "$TMP/setup-state.json" "$TMP/setup.cfg" "$MOCKBIN/xray" warp_show 2>&1 | grep -c 'IPv6.*未配置' || true)" "1"

# --ipv6 on 逃生门：本机无 v6 也强制保留
cp "$STATE" "$TMP/setup-on.json"
WARP_IF_INET6_FILE="$IF6_NONE" bash "$GEN" "$MAIN" "$TMP/setup-on.json" "$TMP/setup.cfg" \
  "$MOCKBIN/xray" warp_setup "$PROFILE" --ipv6 on >/dev/null 2>&1
ck "setup(--ipv6 on)：.warp.ipv6=true" "$(jq -r '.warp.ipv6' "$TMP/setup-on.json")" "true"
ck "setup(--ipv6 on)：保留 v6 地址"    "$(jq '[.warp.address[] | select(test(":"))] | length' "$TMP/setup-on.json")" "1"

# 有真 xray 时：裁剪后的配置也必须被 xray -test 接受（gen6 内部跑 build_config → -test）
if [[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]]; then
  mk_state on off '{"ipv6":false}'
  gen6 "$IF6_PUB"
  ck "ipv6=false：真 xray -test 接受裁剪后的配置" "$?" "0"
fi
echo

# ---------- H. 换 key 后的旧 key 残留（内核 TUN） ----------
echo "[H] 内核 TUN 残留：v6 判定排除 TUN + 策略路由清理"
# H1) 判定必须排除 Xray 自己的 wg0/wg1：换 key 时旧实例的 wg0 上挂着**旧 key 的
#     WARP v6 地址**（2606:4700:…），不排除就会把隧道 v6 当成「本机有公网 IPv6」，
#     新出站因此保留 v6 → 没有原生 v6 的机器上内核 TUN 建不起来。
printf '2606:4700:110:8f1a:9b2c:3d4e:5f60:9c3d 03 40 00 80 wg0\nfe800000000000000000000000000001 02 40 20 80 eth0\n' > "$TMP/if6.wg"
ck "只有 wg0 的 WARP v6 → 判定无公网 v6（修复前误判为有）" "$(has6 "$TMP/if6.wg")" "1"
printf '2a0104f8000000000000000000000001 02 40 00 80 eth0\n2606:4700:110:8f1a::1 03 40 00 80 wg0\n' > "$TMP/if6.both"
ck "原生 v6 + wg0 → 仍判定有" "$(has6 "$TMP/if6.both")" "0"
printf '2606:4700:110::1 03 40 00 80 wg1\n' > "$TMP/if6.wg1"
ck "wg1 也排除（不只 wg0）" "$(has6 "$TMP/if6.wg1")" "1"

# H2) 清理范围：只动表号 >=10230（Xray 内核 TUN 专用区间），main/local/自定义表不碰
IPMOCK="$TMP/mockip"; mkdir -p "$IPMOCK"
RULES="$TMP/rules.txt"; IPLOG="$TMP/ip.log"
cat > "$IPMOCK/ip" <<EOS
#!/usr/bin/env bash
echo "ip \$*" >> "${IPLOG}"
if [[ "\$1 \$2 \$3" == "-6 rule show" ]]; then cat "${RULES}"; exit 0; fi
if [[ "\$1 \$2 \$3 \$4" == "-6 rule del table" ]]; then
  t="\$5"
  awk -v t="\$t" '!((\$NF == t) && !done) { print } (\$NF == t && !done) { done = 1 }' "${RULES}" > "${RULES}.tmp"
  mv "${RULES}.tmp" "${RULES}"; exit 0
fi
exit 0
EOS
chmod +x "$IPMOCK/ip"
reset_rules() {
  printf '0:\tfrom all lookup local\n32762:\tfrom 2606:4700:110::7 lookup 10241\n32763:\tfrom 2606:4700:110::9 lookup 10231\n32764:\tfrom all oif wg0 [detached] lookup 10230\n32765:\tfrom 2606:4700:110:8f1a::1 lookup 10230\n32766:\tfrom all lookup main\n32767:\tfrom 2001:db8::/32 lookup 12345\n' > "$RULES"
  : > "$IPLOG"
}
ipclean() { env PATH="$IPMOCK:$PATH" bash "$GEN" "$MAIN" "$TMP/none.json" "$TMP/none.cfg" "$MOCKBIN/xray" warp_cleanup_stale_tun "$@" >/dev/null 2>&1; }

reset_rules; ipclean --quiet
ck "表 10230 的 rule 已清空"        "$(grep -c 'lookup 10230' "$RULES")" "0"
ck "表 10231 的 rule 也已清空"      "$(grep -c 'lookup 10231' "$RULES")" "0"
ck "main 规则保留"                  "$(grep -c 'from all lookup main' "$RULES")" "1"
ck "local 规则保留"                 "$(grep -c 'from all lookup local' "$RULES")" "1"
ck "自定义表 12345 不碰"            "$(grep -c 'lookup 12345' "$RULES")" "1"
ck "超出 10240 的表不碰（宁可漏清不误删）" "$(grep -c 'lookup 10241' "$RULES")" "1"
ck "flush 了 10230 的路由"          "$(grep -c -- '-6 route flush table 10230' "$IPLOG")" "1"
ck "flush 了 10231 的路由"          "$(grep -c -- '-6 route flush table 10231' "$IPLOG")" "1"
ck "没 flush 自定义表"              "$(grep -c -- 'route flush table 12345' "$IPLOG")" "0"
ck "没 flush 10241"                 "$(grep -c -- 'route flush table 10241' "$IPLOG")" "0"
ck "没动 main(254)"                 "$(grep -c -- 'table 254' "$IPLOG")" "0"

reset_rules; ipclean --dry-run
ck "--dry-run 不删 rule"            "$(grep -c 'lookup 10230' "$RULES")" "2"
ck "--dry-run 不调 del"             "$(grep -c 'rule del' "$IPLOG")" "0"

reset_rules
# PATH 里去掉 /usr/sbin（ip 在那里）；若系统把 ip 也装在 /usr/bin 则跳过该断言
NOIP_PATH="/usr/bin:/bin"
if env PATH="$NOIP_PATH" command -v ip >/dev/null 2>&1; then
  echo "  [SKIP] PATH 里无法排除 ip，跳过「无 ip 命令」断言"; SKIP=$((SKIP+1))
else
  ck "无 ip 命令 → 返回 0（不打断部署）" \
    "$(env PATH="$NOIP_PATH" bash "$GEN" "$MAIN" "$TMP/none.json" "$TMP/none.cfg" "$MOCKBIN/xray" warp_cleanup_stale_tun --quiet >/dev/null 2>&1; echo $?)" "0"
fi

# H3) 真内核：在独立 netns 里注入残留 → 清理（无 CAP_NET_ADMIN / unshare 时 SKIP）
if [[ "$(id -u)" -eq 0 ]] && command -v unshare >/dev/null 2>&1 && unshare -n -- ip -6 rule show >/dev/null 2>&1; then
  cat > "$TMP/netns.sh" <<EONS
#!/usr/bin/env bash
ip -6 rule add from 2606:4700:110::1 table 10230
ip -6 rule add oif wg0 table 10230
ip -6 rule add from 2606:4700:110::9 table 10231
bash "${GEN}" "${MAIN}" "${TMP}/none.json" "${TMP}/none.cfg" "${MOCKBIN}/xray" \
     warp_cleanup_stale_tun --quiet >/dev/null 2>&1
ip -6 rule show
EONS
  out="$(unshare -n -- bash "$TMP/netns.sh" 2>&1)"
  ck "真内核：残留 rule 清零（10230）" "$(grep -c 'lookup 10230' <<<"$out")" "0"
  ck "真内核：残留 rule 清零（10231）" "$(grep -c 'lookup 10231' <<<"$out")" "0"
  ck "真内核：main 规则仍在"           "$(grep -c 'from all lookup main' <<<"$out")" "1"
else
  echo "  [SKIP] 无 root 或 unshare -n 不可用，跳过真内核清理验证"; SKIP=$((SKIP+1))
fi
echo

# ---------- I. warp test 的临时配置必须以 .json 结尾 ----------
echo "[I] warp test 临时配置后缀（26.10.21 起 -format=json 已失效）"
# I1) mock xray 记录收到的参数：断言 -config 指向 .json、且不再依赖 -format=json。
#     回归背景：临时配置曾用 `mktemp .../warp-test.XXXXXX`（无后缀）+ `-format=json`，
#     26.10.21 上该 flag 被忽略 → `-test` 与 `run` 双双失败 → 自检报「可能不支持
#     wireguard 出站」（指向错误方向），--net 则误报「warp=无响应」。
mk_state on off
LOGBIN="$TMP/logbin"; mkdir -p "$LOGBIN"
cat > "$LOGBIN/xray" <<EOS
#!/usr/bin/env bash
echo "\$*" >> "${TMP}/xray-args.log"
exit 0
EOS
chmod +x "$LOGBIN/xray"
: > "$TMP/xray-args.log"
dirs_before="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'warp-test.*' 2>/dev/null | wc -l)"
out="$(bash "$GEN" "$MAIN" "$STATE" "$CFG" "$LOGBIN/xray" warp_test 2>&1)"; rc=$?
ck "mock：warp test 退出码 0"                 "$rc" "0"
ck "mock：-config 指向 .json 结尾"            "$(grep -o -- '-config [^ ]*' "$TMP/xray-args.log" | tail -1 | grep -c '\.json$' || true)" "1"
ck "mock：不再传 -format=json"                "$(grep -c -- '-format=json' "$TMP/xray-args.log" || true)" "0"
ck "mock：临时目录已清理"                     "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'warp-test.*' 2>/dev/null | wc -l)" "$dirs_before"

# I2) 真二进制跑一次：mock 返 0 掩盖不了格式问题，必须真 xray 才暴露。
#     放 netns 里跑——`-test` 会真建内核 TUN 并漏一对 rule（os.Exit 不走 Close），
#     隔离在 netns 里就不污染宿主机；netns 里 lo 默认 down，先拉起来。
if [[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]] && [[ "$(id -u)" -eq 0 ]] && command -v unshare >/dev/null 2>&1; then
  out="$(unshare -n -- bash -c 'ip link set lo up 2>/dev/null; bash "$1" "$2" "$3" "$4" "$5" warp_test' _ \
        "$GEN" "$MAIN" "$STATE" "$CFG" "$XRAY_BIN" 2>&1)"; rc=$?
  ck "真 xray：warp test 通过（修复前 26.10.21 必失败）" "$rc" "0"
else
  echo "  [SKIP] 无真 xray / 非 root / 无 unshare，跳过真二进制 warp test"; SKIP=$((SKIP+1))
fi
echo

# ---------- J. endpoint 收敛成 IPv4（本机无公网 IPv6） ----------
# 根因：Xray 的 MakeResolveLocal 在 A+AAAA 里 dice.Roll 随机挑一个 → 无 v6 的机器上
# 约一半握手发往 AAAA，必然发不出去。所以 ipv6=false 时 endpoint 必须是 IPv4 字面量。
echo "[J] endpoint：无公网 IPv6 时必须收敛成 IPv4 字面量"
epout() { bash "$GEN" "$MAIN" "$TMP/none.json" "$TMP/none.cfg" "$MOCKBIN/xray" warp_endpoint_prefer_ipv4 "$1" 2>/dev/null; }
eprc()  { bash "$GEN" "$MAIN" "$TMP/none.json" "$TMP/none.cfg" "$MOCKBIN/xray" warp_endpoint_prefer_ipv4 "$1" >/dev/null 2>&1; echo $?; }

ck "域名 → IPv4:port（保留端口）"         "$(epout engage.cloudflareclient.com:2408)" "203.0.113.9:2408"
ck "已是 IPv4 → 原样返回"                 "$(epout 162.159.192.1:2408)" "162.159.192.1:2408"
ck "IPv6 字面量 → 返回 2（不做内嵌反解）"  "$(eprc '[2606:4700:d0::a29f:c001]:2408')" "2"
ck "格式非法 → 返回 1"                    "$(eprc 'no-port-here')" "1"
: > "$TMP/mock-a"
ck "解析失败 → 返回 1"                    "$(eprc engage.cloudflareclient.com:2408)" "1"
printf '198.51.100.7\n' > "$TMP/mock-a"
ck "解析结果跟随 DNS（198.51.100.7）"     "$(epout engage.cloudflareclient.com:2408)" "198.51.100.7:2408"
rm -f "$TMP/mock-a"

# setup：无公网 v6 → endpoint 写死 IPv4，原域名留档 .warp.endpoint_host
mk_state on off
cp "$STATE" "$TMP/j-none.json"
WARP_IF_INET6_FILE="$IF6_NONE" bash "$GEN" "$MAIN" "$TMP/j-none.json" "$TMP/j.cfg" "$MOCKBIN/xray" \
  warp_setup "$PROFILE" >/dev/null 2>&1
ck "setup(无 v6)：.warp.endpoint = IPv4"  "$(jq -r '.warp.endpoint' "$TMP/j-none.json")" "203.0.113.9:2408"
ck "setup(无 v6)：记下原域名"             "$(jq -r '.warp.endpoint_host' "$TMP/j-none.json")" "engage.cloudflareclient.com"
ck "setup(无 v6)：show 标出原域名" \
  "$(bash "$GEN" "$MAIN" "$TMP/j-none.json" "$TMP/j.cfg" "$MOCKBIN/xray" warp_show 2>&1 | grep -c '原域名 engage.cloudflareclient.com' || true)" "1"

# setup：有公网 v6 → endpoint 保持域名（v6 机器上 A/AAAA 都能用，不做改写）
mk_state on off; cp "$STATE" "$TMP/j-pub.json"
WARP_IF_INET6_FILE="$IF6_PUB" bash "$GEN" "$MAIN" "$TMP/j-pub.json" "$TMP/j.cfg" "$MOCKBIN/xray" \
  warp_setup "$PROFILE" >/dev/null 2>&1
ck "setup(有 v6)：endpoint 保持域名"      "$(jq -r '.warp.endpoint' "$TMP/j-pub.json")" "engage.cloudflareclient.com:2408"
ck "setup(有 v6)：不写 endpoint_host"     "$(jq -r '.warp.endpoint_host // "absent"' "$TMP/j-pub.json")" "absent"

# setup：endpoint 是 IPv6 字面量 + 本机无 v6 → 必须报错（不静默部署一个连不通的出站）
sed 's|^Endpoint = .*|Endpoint = [2606:4700:d0::a29f:c001]:2408|' "$PROFILE" > "$TMP/ep6.conf"
mk_state on off; cp "$STATE" "$TMP/j-ep6.json"
jq -c '.warp' "$TMP/j-ep6.json" > "$TMP/j-ep6.before"
rc=0
WARP_IF_INET6_FILE="$IF6_NONE" bash "$GEN" "$MAIN" "$TMP/j-ep6.json" "$TMP/j.cfg" "$MOCKBIN/xray" \
  warp_setup "$TMP/ep6.conf" >/dev/null 2>&1 || rc=$?
ck "endpoint 是 IPv6 字面量 + 无 v6 → 报错退出" "$rc" "1"
ck "… 且 state 未改动"                    "$(jq -c '.warp' "$TMP/j-ep6.json")" "$(cat "$TMP/j-ep6.before")"

# setup：解析不出 IPv4 → 报错退出（人在现场，重跑即可；不许写一个坏出站）
: > "$TMP/mock-a"
mk_state on off; cp "$STATE" "$TMP/j-fail.json"
jq -c '.warp' "$TMP/j-fail.json" > "$TMP/j-fail.before"
rc=0
WARP_IF_INET6_FILE="$IF6_NONE" bash "$GEN" "$MAIN" "$TMP/j-fail.json" "$TMP/j.cfg" "$MOCKBIN/xray" \
  warp_setup "$PROFILE" >/dev/null 2>&1 || rc=$?
ck "解析失败 → setup 报错退出"            "$rc" "1"
ck "… 且 state 未改动"                    "$(jq -c '.warp' "$TMP/j-fail.json")" "$(cat "$TMP/j-fail.before")"
rm -f "$TMP/mock-a"

# gen 兜底：本改动前导入的老 state 仍是域名 + 无 v6 → rebuild 时自愈
mk_state on off '{"ipv6":false}'
jq 'del(.warp.endpoint_host)' "$STATE" > "$TMP/j-old.json" && mv "$TMP/j-old.json" "$STATE"
gen6 "$IF6_NONE"
ck "老 state（域名 + 无 v6）→ gen 自愈成 IPv4" "$(w6 '.settings.peers[0].endpoint')" "203.0.113.9:2408"
ck "… 且 endpoint_host 不泄漏进出站"      "$(jq '.outbounds[] | select(.tag=="warp") | .settings.peers[0] | has("endpoint_host")' "$CFG")" "false"

mk_state on off '{"ipv6":true}'; gen6 "$IF6_NONE"
ck "ipv6=true → endpoint 保持域名"        "$(w6 '.settings.peers[0].endpoint')" "engage.cloudflareclient.com:2408"

# 解析失败时 gen 只告警，不打断 rebuild（DNS 抖动不能把线上代理弄挂）
mk_state on off '{"ipv6":false}'
: > "$TMP/mock-a"
out="$(bash "$GEN" "$MAIN" "$STATE" "$CFG" "$MOCKBIN/xray" build_config 2>&1)"; rc=$?
ck "解析失败 → rebuild 仍成功"            "$rc" "0"
ck "解析失败 → 保留域名（不静默丢配置）"  "$(w6 '.settings.peers[0].endpoint')" "engage.cloudflareclient.com:2408"
ck "解析失败 → 有告警"                    "$(grep -c '无法收敛成 IPv4' <<<"$out" || true)" "1"
rm -f "$TMP/mock-a"
echo

echo "----------------------------------------------"
echo " PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
