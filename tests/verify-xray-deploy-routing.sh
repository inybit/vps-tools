#!/usr/bin/env bash
# 分流模式回归：chain mode 各预设 → routing 规则形态 + 真实 xray -test
#
# 验证要点：
#   [A] geosite 标签存在性（铁律：不手写 DOMAIN-SUFFIX，必须先查证）
#   [B] 各 mode 生成的规则形态（all / none / ai / google / youtube / 组合 / custom）
#   [C] 底线 block 规则在任何 mode 下都不丢（安全不变量）
#   [D] 真实 xray -test 接受各 mode 的配置
#   [E] 单机模式（无 chain）行为与拆分前一致（不追加 landing/direct catch-all）
#
# 用法: bash tests/verify-xray-deploy-routing.sh
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

echo "=== 分流模式回归 ==="
echo

XRAY_BIN="${XRAY_BIN:-}"
if [[ -z "$XRAY_BIN" ]]; then
  for cand in /tmp/hermes-ss2022-e2e/xray "$(command -v xray 2>/dev/null || true)"; do
    [[ -n "$cand" && -x "$cand" ]] && { XRAY_BIN="$cand"; break; }
  done
fi
GEO_ASSET="${GEO_ASSET:-/tmp/geodata}"
HAS_GEO=0
[[ -f "${GEO_ASSET}/geosite.dat" && -f "${GEO_ASSET}/geoip.dat" ]] && HAS_GEO=1

# ---------- A. geosite 标签存在性（铁律） ----------
echo "[A] geosite 标签查证（MetaCubeX 数据源）"
for tag in category-ai-!cn google youtube openai category-ads-all cn; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/${tag}.yaml" 2>/dev/null || echo 000)"
  ck "geosite:${tag} 存在（HTTP ${code}）" "$code" "200"
done
# geoip 标签
for tag in cn private; do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geoip/${tag}.yaml" 2>/dev/null || echo 000)"
  ck "geoip:${tag} 存在（HTTP ${code}）" "$code" "200"
done
echo

# ---------- 生成器 ----------
MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
printf '#!/usr/bin/env bash\n[[ "$1" == version ]] && echo "Xray 0.0.0-mock (mock)"; exit 0\n' > "$MOCKBIN/xray"
chmod +x "$MOCKBIN/xray"

GEN="$TMP/gen.sh"
cat > "$GEN" <<'GENPROBE'
set -uo pipefail
src="$1"; state="$2"; out="$3"
tmp="$(dirname "$src")/.nodisp.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"; rm -f "$tmp"
STATE_FILE="$state"; CONFIG_FILE="$out"; BIN_PATH="/bin/true"
service_restart() { :; }; need_root() { :; }
build_config
GENPROBE

# REALITY 密钥（真密钥，供 [D] 真二进制校验）
PRIV="sDRObqZ2Ez65fdupFcV95W8TMLcYItEXl-cUojlqzW0"
PUB="oXaK5pazZbzTPypmkGiEJBs4ofiHA-hncCU8wrmyhQQ"
if [[ -n "$XRAY_BIN" ]]; then
  _k="$("$XRAY_BIN" x25519 2>/dev/null)"
  PRIV="$(awk '/^PrivateKey:/{print $2} /^Private key:/{print $3}' <<<"$_k")"
  PUB="$(awk '/^Password \(PublicKey\):/{print $3} /^Password:/{print $2} /^Public key:/{print $3}' <<<"$_k")"
fi

STATE="$TMP/state.json"; CFG="$TMP/cfg.json"

mk_state() {  # $1=mode（空=不带 mode 字段）
  local mode="$1"
  if [[ -n "$mode" ]]; then
    cat > "$STATE" <<SJ
{
  "schema_version": 1, "server_ip": "203.0.113.10",
  "protocols": [
    { "name": "vless-reality-01", "type": "vless-reality", "port": 443,
      "uuid": "11111111-2222-3333-4444-555555555555",
      "private_key": "${PRIV}", "public_key": "${PUB}",
      "sni": "www.example.com", "short_id": "aabbccdd", "short_ids": ["aabbccdd"] }
  ],
  "chain": { "role": "relay", "mode": "${mode}", "upstream": {
      "type": "ss2022", "name": "landing", "address": "198.51.100.20",
      "port": 8443, "method": "2022-blake3-aes-256-gcm",
      "password": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" } }
}
SJ
  else
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
      "type": "ss2022", "name": "landing", "address": "198.51.100.20",
      "port": 8443, "method": "2022-blake3-aes-256-gcm",
      "password": "BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=" } }
}
SJ
  fi
}

gen() { bash "$GEN" "$MAIN" "$STATE" "$CFG" >/dev/null 2>&1; }

# 统计某 outboundTag 的规则数
n_rules() { jq --arg t "$1" '[.routing.rules[] | select(.outboundTag==$t)] | length' "$CFG" 2>/dev/null; }
# 取指定 tag 的域名列表（第一个命中）
domains_of() { jq -r --arg t "$1" '[.routing.rules[] | select(.outboundTag==$t and .domain != null)][0].domain // [] | join(",")' "$CFG" 2>/dev/null; }

# ---------- B. 各 mode 形态 ----------
echo "[B] 各模式生成的 routing 形态"

echo "  -- mode=all（默认，无 mode 字段）--"
mk_state ""; gen
ck "  默认 mode 视为 all" "$(jq -r '.routing.rules[-1].outboundTag' "$CFG")" "landing"
ck "  catch-all 覆盖 tcp,udp" "$(jq -r '.routing.rules[-1].network' "$CFG")" "tcp,udp"
ck "  block 底线 5 条" "$(n_rules block)" "5"
ck "  无 direct catch-all" "$(n_rules direct)" "0"

echo "  -- mode=all（显式）--"
mk_state all; gen
ck "  catch-all 走落地" "$(jq -r '.routing.rules[-1].outboundTag' "$CFG")" "landing"
ck "  规则总数 6" "$(jq '.routing.rules | length' "$CFG")" "6"

echo "  -- mode=none --"
mk_state none; gen
ck "  catch-all 直出" "$(jq -r '.routing.rules[-1].outboundTag' "$CFG")" "direct"
ck "  无 landing 规则" "$(n_rules landing)" "0"
ck "  block 底线仍在 5 条" "$(n_rules block)" "5"

echo "  -- mode=ai --"
mk_state ai; gen
ck "  落地白名单 = category-ai-!cn,openai" \
  "$(domains_of landing)" "geosite:category-ai-!cn,geosite:openai"
ck "  末尾 catch-all 直出" "$(jq -r '.routing.rules[-1].outboundTag' "$CFG")" "direct"
ck "  规则总数 7（5 block + 1 landing + 1 direct）" "$(jq '.routing.rules | length' "$CFG")" "7"

echo "  -- mode=google --"
mk_state google; gen
ck "  落地白名单 = google" "$(domains_of landing)" "geosite:google"
ck "  末尾 catch-all 直出" "$(jq -r '.routing.rules[-1].outboundTag' "$CFG")" "direct"

echo "  -- mode=youtube --"
mk_state youtube; gen
ck "  落地白名单 = youtube" "$(domains_of landing)" "geosite:youtube"

echo "  -- mode=ai-google-youtube --"
mk_state ai-google-youtube; gen
ck "  落地白名单 = ai+openai+google+youtube" \
  "$(domains_of landing)" "geosite:category-ai-!cn,geosite:openai,geosite:google,geosite:youtube"

echo "  -- mode=custom:geosite:netflix,geosite:spotify --"
mk_state "custom:geosite:netflix,geosite:spotify"; gen
ck "  落地白名单 = netflix,spotify" "$(domains_of landing)" "geosite:netflix,geosite:spotify"

echo "  -- mode=未知模式（应回退 all）--"
mk_state "bogus-mode"; gen
ck "  回退为 catch-all 走落地" "$(jq -r '.routing.rules[-1].outboundTag' "$CFG")" "landing"
echo

# ---------- C. 安全不变量 ----------
echo "[C] 安全不变量：任何 mode 下底线 block 都不丢"
for m in all none ai google youtube ai-google ai-google-youtube "custom:geosite:netflix"; do
  mk_state "$m"; gen
  n_ads="$(jq '[.routing.rules[] | select(.domain != null and (.domain | index("geosite:category-ads-all"))) ] | length' "$CFG" 2>/dev/null)"
  n_bt="$(jq '[.routing.rules[] | select(.protocol != null and (.protocol | index("bittorrent"))) ] | length' "$CFG" 2>/dev/null)"
  n_priv="$(jq '[.routing.rules[] | select(.ip != null and (.ip | index("geoip:private"))) ] | length' "$CFG" 2>/dev/null)"
  n_cn="$(jq '[.routing.rules[] | select(.domain != null and (.domain | index("geosite:cn"))) ] | length' "$CFG" 2>/dev/null)"
  n_cnip="$(jq '[.routing.rules[] | select(.ip != null and (.ip | index("geoip:cn"))) ] | length' "$CFG" 2>/dev/null)"
  tot=$((n_ads+n_bt+n_priv+n_cn+n_cnip))
  ck "  mode=${m}: 5 条底线齐全" "$tot" "5"
done
echo

# ---------- D. 真实 xray -test ----------
echo "[D] 真实 xray -test 校验各 mode 配置"
if [[ -z "$XRAY_BIN" || "$HAS_GEO" -eq 0 ]]; then
  echo "  [SKIP] 需 xray 二进制 + geo 数据"
else
  export XRAY_LOCATION_ASSET="$GEO_ASSET"
  for m in all none ai google youtube ai-google-youtube "custom:geosite:netflix"; do
    mk_state "$m"; gen
    if "$XRAY_BIN" run -test -format=json -config "$CFG" >"$TMP/t.log" 2>&1; then
      echo "  [PASS] xray -test 接受 mode=${m}"; PASS=$((PASS+1))
    else
      echo "  [FAIL] mode=${m} 被拒:"
      grep -viE 'deprecat|^A unified|Reading config' "$TMP/t.log" | head -4 | sed 's/^/         /'
      FAIL=$((FAIL+1))
    fi
  done
fi
echo

# ---------- E. 单机模式（无 chain）不受影响 ----------
echo "[E] 单机模式（无 chain）"
cat > "$STATE" <<SJ
{
  "schema_version": 1, "server_ip": "203.0.113.10",
  "protocols": [
    { "name": "vless-reality-01", "type": "vless-reality", "port": 443,
      "uuid": "11111111-2222-3333-4444-555555555555",
      "private_key": "${PRIV}", "public_key": "${PUB}",
      "sni": "www.example.com", "short_id": "aabbccdd", "short_ids": ["aabbccdd"] }
  ]
}
SJ
gen
ck "  无 landing 规则" "$(n_rules landing)" "0"
ck "  无 direct catch-all" "$(n_rules direct)" "0"
ck "  仅 5 条底线 block" "$(jq '.routing.rules | length' "$CFG")" "5"
echo

# ---------- F. CLI 行为 ----------
echo "[F] CLI 行为"
out="$(bash "$MAIN" chain mode list 2>&1 || true)"
# ⚠️ 逐模式精确断言（别用模糊计数）：每个预设都必须出现在列表里
for p in all none ai google youtube ai-google ai-google-youtube; do
  ck "  mode list 含 '${p}'" "$(grep -cE "^  ${p} " <<<"$out")" "1"
done
ck "  mode list 含 custom 说明" "$(grep -c 'custom:<标签' <<<"$out")" "1"
ck "  mode list 含底线 block 说明" "$(grep -c '底线 block 规则' <<<"$out")" "1"
# usage 里 'chain mode' 出现多行属正常 → 断言"至少出现"而非精确值
ck "  usage 含 chain mode（≥1 行）" \
  "$([[ "$(bash "$MAIN" -h 2>&1 | grep -c 'chain mode')" -ge 1 ]] && echo ok)" "ok"
ck "  usage 含 mode all" "$(bash "$MAIN" -h 2>&1 | grep -c 'chain mode all')" "1"
ck "  usage 含 category-ai-!cn" "$(bash "$MAIN" -h 2>&1 | grep -c 'category-ai-!cn')" "1"
echo

echo "==================================="
printf ' PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
