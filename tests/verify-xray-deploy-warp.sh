#!/usr/bin/env bash
# WARP 回国出站回归：wgcf-profile.conf 解析 / 出站形态 / 路由三态 / 真实 xray -test / 私钥不外泄
#
# 验证要点：
#   [A] profile 解析：v4+v6 CIDR、DNS、MTU、Endpoint、AllowedIPs；无前缀地址自动补 /32 //128
#   [B] 校验拒绝：缺字段 / 非法 base64 / 多 [Peer] / Endpoint 无端口 / MTU 越界 —— 一律非 0 退出
#   [C] 出站形态：protocol=wireguard、tag=warp、secretKey/address/peers/mtu/remoteDNS；
#       **noKernelTun 默认不出现**（= Xray 自动检测，2026-10-28 用户决定）
#   [D] 路由三态：warp 关 → cn 两条 block（历史行为）；warp 开 → cn 两条 warp、其余 block；
#       warp 开 + chain → cn 仍 warp 且 catch-all 走落地
#   [E] 真实 xray -test 接受该配置（无二进制时 SKIP，不计 FAIL）
#   [F] 私钥不外泄：warp show / info 输出里私钥出现 0 次，且只露末 4 位
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

GEN="$TMP/gen.sh"
cat > "$GEN" <<'GENPROBE'
set -uo pipefail
src="$1"; state="$2"; out="$3"; bin="$4"; shift 4
tmp="$(dirname "$src")/.nodisp.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"; rm -f "$tmp"
STATE_FILE="$state"; CONFIG_FILE="$out"; BIN_PATH="$bin"
service_restart() { :; }; need_root() { :; }
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
    + (if $warp == "on" then { warp: ($w + { enabled: true, imported_at: "2026-10-28T00:00:00Z", source: "test" } + $extra) } else {} end)
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
ck "noKernelTun 默认不出现（= Xray 自动检测）" \
  "$(jq -r '.outbounds[] | select(.tag=="warp") | .settings | has("noKernelTun")' "$CFG")" "false"

mk_state on off '{"no_kernel_tun":true}'; gen
ck "--no-tun 时才写 noKernelTun=true" \
  "$(jq -r '.outbounds[] | select(.tag=="warp") | .settings.noKernelTun' "$CFG")" "true"

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
INFO="$(bash "$GEN" "$MAIN" "$STATE" "$CFG" "$MOCKBIN/xray" cmd_info 2>&1)"
ck "info 中私钥出现次数 = 0" "$(grep -cF "$PRIV" <<<"$INFO" || true)" "0"
ck "info 显示 warp 规则"     "$(grep -c 'warp: geosite:cn' <<<"$INFO" || true)" "1"
mk_state off off
INFO2="$(bash "$GEN" "$MAIN" "$STATE" "$CFG" "$MOCKBIN/xray" cmd_info 2>&1)"
ck "warp 关时 info 仍显示 block: geosite:cn" "$(grep -c 'block: geosite:cn' <<<"$INFO2" || true)" "1"
echo

echo "----------------------------------------------"
echo " PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
