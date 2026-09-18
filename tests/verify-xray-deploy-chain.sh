#!/usr/bin/env bash
# 阶段 3 回归：ss2022 协议 + chain（中转+落地）链路
#
# 分层验证（缺一层结论都不可靠）：
#   [A] 静态：触点齐全（对照「新增协议 11 处触点」清单）
#   [B] 配置生成：mock xray（只校验语法占位）→ 断言 inbound/outbound/routing 形态
#   [C] 真实 xray -test：用真二进制 + geo 数据校验生成的 config（最强证据）
#   [D] 语义：catch-all routing 必须存在（否则链路形同虚设）
#
# 用法: bash tests/verify-xray-deploy-chain.sh
# 环境变量:
#   XRAY_BIN     真实 xray 路径（默认探测）
#   GEO_ASSET    geo 数据目录（含 geosite.dat/geoip.dat；默认探测 /tmp/geodata）
# 退出码: 0=全部通过
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${REPO}/proxy/xray-deploy"
MAIN="${TOOL}/xray-deploy.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ck() {
  if [[ "$2" == "$3" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

echo "=== 阶段 3 回归：ss2022 + chain 链路 ==="
echo

# ---------- A. 触点清单 ----------
echo "[A] 触点完整性（对照「新增协议 11 处触点」）"
ck "1) PROTO_REGISTRY 含 ss2022" \
  "$(grep -c '"ss2022|' "${TOOL}/lib/registry.sh")" "1"
ck "2) protocol_to_inbound 有 ss2022 分支" \
  "$(grep -c '^    ss2022)' "${TOOL}/lib/inbound.sh")" "1"
ck "3) proto_wizard_ss2022 已定义" \
  "$(grep -c '^proto_wizard_ss2022()' "${TOOL}/lib/ss2022.sh")" "1"
ck "4) gen_client_mihomo_ss2022 已定义" \
  "$(grep -c '^gen_client_mihomo_ss2022()' "${TOOL}/lib/client-ss2022.sh")" "1"
ck "5) gen_client_singbox_ss2022 已定义" \
  "$(grep -c '^gen_client_singbox_ss2022()' "${TOOL}/lib/client-ss2022.sh")" "1"
ck "6a) mihomo 分发含 ss2022" \
  "$(grep -c 'ss2022) gen_client_mihomo_ss2022' "${TOOL}/lib/client-mihomo.sh")" "1"
ck "6b) singbox 分发含 ss2022" \
  "$(grep -c 'ss2022) gen_client_singbox_ss2022' "${TOOL}/lib/client-singbox.sh")" "1"
ck "7) cmd_install 协议选择含 ss2022" \
  "$(grep -c 'ss2022)        params=' "${TOOL}/lib/cmd-lifecycle.sh")" "1"
ck "8) proto_add 含 ss2022" \
  "$(grep -c 'ss2022) params=' "${TOOL}/lib/proto-crud.sh")" "1"
ck "9) proto_list_names 显示 ss2022" \
  "$(grep -c 'value.type == "ss2022"' "${TOOL}/lib/proto-crud.sh")" "1"
ck "10) cmd_info 显示 ss2022（显示+mihomo+singbox 三处分支）" \
  "$(grep -c 'type" == "ss2022"' "${TOOL}/lib/cmd-info.sh")" "3"
ck "11) usage 帮助含 ss2022" \
  "$(grep -c '^  ss2022 ' "${TOOL}/lib/usage.sh")" "1"
echo "  -- chain 触点 --"
ck "chain 子命令分发已接" \
  "$(grep -c '^  chain)' "$MAIN")" "1"
ck "chain 6 个子命令" \
  "$(sed -n '/^  chain)/,/^    ;;/p' "$MAIN" | grep -cE '^      (setup|show|export|import|test|remove)\)')" "6"
ck "build_config 注入 landing outbound" \
  "$(grep -c 'gen_landing_outbound' "${TOOL}/lib/inbound.sh")" "1"
# ⚠️ routing 生成已抽到 routing.sh（2026-09-18 拆分：mode 切换需要）
#    LANDING_OUTBOUND_TAG 在该文件出现 2 次（all 分支 + 白名单分支）
ck "routing 生成在 routing.sh（含 catch-all）" \
  "$(grep -c 'LANDING_OUTBOUND_TAG' "${TOOL}/lib/routing.sh")" "2"
ck "inbound.sh 不再硬编码 routing" \
  "$(grep -c 'geosite:category-ads-all' "${TOOL}/lib/inbound.sh")" "0"
ck "菜单含链路入口" \
  "$(grep -c '中转 + 落地（链路）' "$MAIN")" "1"
echo

# ---------- 准备：mock xray（生成阶段用）+ 真 xray（校验阶段用） ----------
MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
# mock xray：run -test 恒成功（生成阶段只关心 JSON 形态，校验交给 [C] 段真二进制）
printf '#!/usr/bin/env bash\n[[ "$1" == version ]] && echo "Xray 0.0.0-mock (mock)"; exit 0\n' > "$MOCKBIN/xray"
chmod +x "$MOCKBIN/xray"

XRAY_BIN="${XRAY_BIN:-}"
if [[ -z "$XRAY_BIN" ]]; then
  for cand in /tmp/hermes-ss2022-e2e/xray "$(command -v xray 2>/dev/null || true)"; do
    [[ -n "$cand" && -x "$cand" ]] && { XRAY_BIN="$cand"; break; }
  done
fi
GEO_ASSET="${GEO_ASSET:-/tmp/geodata}"
HAS_GEO=0
[[ -f "${GEO_ASSET}/geosite.dat" && -f "${GEO_ASSET}/geoip.dat" ]] && HAS_GEO=1

# ---------- 生成器（source 主脚本，调用真实 build_config） ----------
GEN="$TMP/gen.sh"
cat > "$GEN" <<'GENPROBE'
set -uo pipefail
src="$1"; state="$2"; out="$3"; xray="$4"
# ⚠️ 截断文件必须落在主脚本同目录（SCRIPT_DIR 由 BASH_SOURCE 推导，否则 lib 加载失败）
tmp="$(dirname "$src")/.nodisp.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"; rm -f "$tmp"
STATE_FILE="$state"; CONFIG_FILE="$out"; BIN_PATH="$xray"
service_restart() { :; }
need_root() { :; }
build_config
GENPROBE

gen() {  # $1=state文件 $2=输出cfg
  bash "$GEN" "$MAIN" "$1" "$2" "$MOCKBIN/xray" >/dev/null 2>&1
}

STATE="$TMP/state.json"; CFG="$TMP/cfg.json"

# ⚠️ REALITY 密钥必须是【真密钥】：xray -test 会校验 privateKey 合法性，
#    用 "PRIVKEY" 这类占位符会被真二进制拒绝（infra/conf: invalid "privateKey"）
#    → 校验段会假 FAIL。故用真 xray 现生成一对。
if [[ -n "$XRAY_BIN" ]]; then
  _keys="$("$XRAY_BIN" x25519 2>/dev/null)"
  PRIV="$(awk '/^PrivateKey:/{print $2} /^Private key:/{print $3}' <<<"$_keys")"
  PUB="$(awk '/^Password \(PublicKey\):/{print $3} /^Password:/{print $2} /^Public key:/{print $3}' <<<"$_keys")"
fi
: "${PRIV:=sDRObqZ2Ez65fdupFcV95W8TMLcYItEXl-cUojlqzW0}"
: "${PUB:=oXaK5pazZbzTPypmkGiEJBs4ofiHA-hncCU8wrmyhQQ}"
echo "    REALITY 测试密钥: priv=${PRIV:0:12}... pub=${PUB:0:12}..."
echo

# ---------- B. 场景 1：单机（无 chain） ----------
echo "[B] 配置生成 — 场景 1：单机（无 chain）"
cat > "$STATE" <<SJ
{
  "schema_version": 1,
  "server_ip": "203.0.113.10",
  "protocols": [
    { "name": "vless-reality-01", "type": "vless-reality", "port": 443,
      "uuid": "11111111-2222-3333-4444-555555555555",
      "private_key": "${PRIV}", "public_key": "${PUB}",
      "sni": "www.example.com", "short_id": "aabbccdd", "short_ids": ["aabbccdd"] },
    { "name": "ss2022-01", "type": "ss2022", "port": 8443,
      "method": "2022-blake3-aes-256-gcm",
      "password": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" }
  ]
}
SJ
gen "$STATE" "$CFG"
ck "  cfg 已生成" "$([[ -s "$CFG" ]] && echo yes || echo no)" "yes"
ck "  ss2022 inbound method" \
  "$(jq -r '[.inbounds[] | select(.protocol=="shadowsocks")][0].settings.method' "$CFG" 2>/dev/null)" "2022-blake3-aes-256-gcm"
ck "  ss2022 network=tcp,udp" \
  "$(jq -r '[.inbounds[] | select(.protocol=="shadowsocks")][0].settings.network' "$CFG" 2>/dev/null)" "tcp,udp"
ck "  无 landing outbound" "$(jq '[.outbounds[] | select(.tag=="landing")] | length' "$CFG" 2>/dev/null)" "0"
ck "  无 catch-all 规则（单机不该有）" "$(jq '[.routing.rules[] | select(.outboundTag=="landing")] | length' "$CFG" 2>/dev/null)" "0"
# 底线 block 5 条（2026-09-18 起 google 直连不再硬编码，改为 mode 驱动）
ck "  底线 block 5 条" "$(jq '[.routing.rules[] | select(.outboundTag=="block")] | length' "$CFG" 2>/dev/null)" "5"
ck "  规则总数 5" "$(jq '.routing.rules | length' "$CFG" 2>/dev/null)" "5"
ck "  无硬编码 google 直连（改由 chain mode 控制）" \
  "$(jq '[.routing.rules[] | select(.domain != null and (.domain | index("geosite:google")))] | length' "$CFG" 2>/dev/null)" "0"
echo

# ---------- B. 场景 2：中转机（chain=ss2022） ----------
echo "[B] 配置生成 — 场景 2：中转机（chain=ss2022）"
cat > "$STATE" <<SJ
{
  "schema_version": 1,
  "server_ip": "203.0.113.10",
  "protocols": [
    { "name": "vless-reality-01", "type": "vless-reality", "port": 443,
      "uuid": "11111111-2222-3333-4444-555555555555",
      "private_key": "${PRIV}", "public_key": "${PUB}",
      "sni": "www.example.com", "short_id": "aabbccdd", "short_ids": ["aabbccdd"] }
  ],
  "chain": {
    "role": "relay",
    "upstream": { "type": "ss2022", "name": "landing",
      "address": "198.51.100.20", "port": 8443,
      "method": "2022-blake3-aes-256-gcm",
      "password": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" }
  }
}
SJ
gen "$STATE" "$CFG"
ck "  landing outbound 存在" "$(jq '[.outbounds[] | select(.tag=="landing")] | length' "$CFG" 2>/dev/null)" "1"
ck "  landing 协议=shadowsocks" "$(jq -r '.outbounds[] | select(.tag=="landing") | .protocol' "$CFG" 2>/dev/null)" "shadowsocks"
ck "  landing 地址正确" "$(jq -r '.outbounds[] | select(.tag=="landing") | .settings.address' "$CFG" 2>/dev/null)" "198.51.100.20"
ck "  landing 端口正确" "$(jq -r '.outbounds[] | select(.tag=="landing") | .settings.port' "$CFG" 2>/dev/null)" "8443"
ck "  landing 密钥正确" "$(jq -r '.outbounds[] | select(.tag=="landing") | .settings.password' "$CFG" 2>/dev/null)" "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB="
ck "  landing 有 udp（SS2022 双栈）" \
  "$(jq -r '.outbounds[] | select(.tag=="landing") | has("streamSettings") | not' "$CFG" 2>/dev/null)" "true"
echo

# ---------- D. catch-all 语义 ----------
echo "[D] catch-all 语义（链路是否真生效）"
# 默认 mode=all → 5 底线 block + 1 catch-all landing = 6
ck "  routing 6 条（5 底线 + 1 catch-all）" "$(jq '.routing.rules | length' "$CFG" 2>/dev/null)" "6"
ck "  catch-all 指向 landing" "$(jq -r '.routing.rules[-1].outboundTag' "$CFG" 2>/dev/null)" "landing"
ck "  catch-all 覆盖 tcp,udp" "$(jq -r '.routing.rules[-1].network' "$CFG" 2>/dev/null)" "tcp,udp"
ck "  catch-all 在最后（优先级最低）" "$(jq -r '.routing.rules[-1].outboundTag' "$CFG" 2>/dev/null)" "landing"
ck "  默认 mode=all → 无 direct catch-all" \
  "$(jq '[.routing.rules[] | select(.outboundTag=="direct")] | length' "$CFG" 2>/dev/null)" "0"
ck "  block 底线仍在（ads/bt/private/cn×2）" \
  "$(jq '[.routing.rules[] | select(.outboundTag=="block")] | length' "$CFG" 2>/dev/null)" "5"
# 分流模式细节见 tests/verify-xray-deploy-routing.sh
echo

# ---------- C. 真实 xray -test ----------
echo "[C] 真实 xray -test 校验生成的配置"
if [[ -z "$XRAY_BIN" ]]; then
  echo "  [SKIP] 未找到 xray 二进制（可用 XRAY_BIN=... 指定）"
elif [[ "$HAS_GEO" -eq 0 ]]; then
  echo "  [SKIP] 缺 geo 数据（${GEO_ASSET} 下需 geosite.dat + geoip.dat）"
else
  echo "    使用: ${XRAY_BIN} ($("$XRAY_BIN" version 2>/dev/null | head -1 | awk '{print $2}'))"
  echo "    geo:  ${GEO_ASSET}"
  export XRAY_LOCATION_ASSET="$GEO_ASSET"
  if "$XRAY_BIN" run -test -format=json -config "$CFG" >"$TMP/t1.log" 2>&1; then
    echo "  [PASS] xray -test 接受链路配置（ss2022 落地）"; PASS=$((PASS+1))
  else
    echo "  [FAIL] xray -test 拒绝配置:"
    grep -viE 'deprecat|^A unified|Reading config' "$TMP/t1.log" | head -6 | sed 's/^/         /'
    FAIL=$((FAIL+1))
  fi
  # 确认 SS2022 只触发软警告（不是 error）
  ck "  SS2022 仅软 deprecated 警告（非 error）" \
    "$(grep -ciE 'deprecated' "$TMP/t1.log" | head -1)" "1"
  ck "  校验输出无 'Failed to start'" \
    "$(grep -c 'Failed to start' "$TMP/t1.log" || true)" "0"

  # 变体：VLESS-REALITY 落地
  cat > "$STATE" <<SJ
{
  "schema_version": 1, "server_ip": "203.0.113.10",
  "protocols": [
    { "name": "vless-reality-01", "type": "vless-reality", "port": 443,
      "uuid": "11111111-2222-3333-4444-555555555555",
      "private_key": "${PRIV}", "public_key": "${PUB}",
      "sni": "www.example.com", "short_id": "aabbccdd", "short_ids": ["aabbccdd"] }
  ],
  "chain": { "role": "relay", "upstream": {
      "type": "vless-reality", "name": "landing", "address": "198.51.100.20",
      "port": 443, "uuid": "99999999-8888-7777-6666-555555555555",
      "public_key": "${PUB}", "sni": "landing.example.com",
      "short_id": "11223344", "fingerprint": "chrome" } }
}
SJ
  gen "$STATE" "$CFG"
  ck "  vless-reality 落地：flat settings.address" \
    "$(jq -r '.outbounds[] | select(.tag=="landing") | .settings.address' "$CFG" 2>/dev/null)" "198.51.100.20"
  ck "  vless-reality 落地：realitySettings.publicKey" \
    "$(jq -r '.outbounds[] | select(.tag=="landing") | .streamSettings.realitySettings.publicKey' "$CFG" 2>/dev/null)" "$PUB"
  ck "  vless-reality 落地：realitySettings.serverName" \
    "$(jq -r '.outbounds[] | select(.tag=="landing") | .streamSettings.realitySettings.serverName' "$CFG" 2>/dev/null)" "landing.example.com"
  ck "  vless-reality 落地：flow=xtls-rprx-vision" \
    "$(jq -r '.outbounds[] | select(.tag=="landing") | .settings.flow' "$CFG" 2>/dev/null)" "xtls-rprx-vision"
  if "$XRAY_BIN" run -test -format=json -config "$CFG" >"$TMP/t2.log" 2>&1; then
    echo "  [PASS] xray -test 接受 VLESS-REALITY 落地链路"; PASS=$((PASS+1))
  else
    echo "  [FAIL] VLESS-REALITY 落地链路被拒:"
    grep -viE 'deprecat|^A unified|Reading config' "$TMP/t2.log" | head -6 | sed 's/^/         /'
    FAIL=$((FAIL+1))
  fi
fi
echo

echo "==================================="
printf ' PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
