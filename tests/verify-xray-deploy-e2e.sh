#!/usr/bin/env bash
# 阶段 3 端到端：用【真实 xray 进程】验证链路真能通（全程 loopback，不产生跨境流量）
#
# 拓扑（与生产同构，只是地址换成回环）：
#   客户端(xray) ──REALITY──→ 中转机(xray，生成的 config) ──SS2022──→ 落地机(xray) ──→ 目标
#
# ⚠️ 用户安全约束：SS 不得做跨境连通性测试 → 全程 127.0.0.1，目标是本地 http.server。
# ⚠️ 假阳性陷阱（本技能已记录，必须全部规避）：
#   1. curl 测显式代理时**不能加 --noproxy '*'**（会连带禁用 --socks5 → 直连 200）
#   2. 必须做反事实：杀掉落地机后必须失败
#   3. 必须看落地机 access log（证明流量真过了两跳）
#
# 用法: bash tests/verify-xray-deploy-e2e.sh
# 环境变量: XRAY_BIN（默认 /tmp/hermes-ss2022-e2e/xray）
# 退出码: 0=全部通过
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${REPO}/proxy/xray-deploy"
MAIN="${TOOL}/xray-deploy.sh"
TMP="$(mktemp -d)"
PASS=0; FAIL=0
ck() {
  if [[ "$2" == "$3" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

XRAY_BIN="${XRAY_BIN:-/tmp/hermes-ss2022-e2e/xray}"
[[ -x "$XRAY_BIN" ]] || { echo "需要真实 xray 二进制: $XRAY_BIN" >&2; exit 1; }
GEO_ASSET="${GEO_ASSET:-/tmp/geodata}"
[[ -f "${GEO_ASSET}/geosite.dat" ]] || { echo "需要 geo 数据: ${GEO_ASSET}" >&2; exit 1; }

# 端口（高位随机，避免与本机 mihomo 冲突）
P_LANDING=28601; P_RELAY=28602; P_SOCKS=28603; P_WEB=28604

# 记录本脚本启动的进程 PID，退出时精确清理。
# ⚠️ 不要用 `pgrep -f "<脚本名>"` 做清理：会匹配到【自身】以及调用链上的父 shell
#    （父 shell 的 cmdline 里含脚本名）→ 自杀 → 退出码变 143(SIGTERM)，
#    harness 明明 PASS=0 FAIL 却报非零，无法当 CI 门禁。
TRACKED_PIDS=()
spawn() {  # $@=命令；记录 PID
  "$@" & TRACKED_PIDS+=("$!")
}

cleanup() {
  for p in "${TRACKED_PIDS[@]:-}"; do
    [[ -n "$p" ]] && kill "$p" 2>/dev/null
  done
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "=== 阶段 3 端到端：链路真能通（loopback）==="
echo "xray: $("$XRAY_BIN" version | head -1 | awk '{print $2}')"
echo "端口: landing=${P_LANDING} relay=${P_RELAY} socks=${P_SOCKS} web=${P_WEB}"
echo

# ---------- 生成密钥 ----------
REALITY_KEYS="$("$XRAY_BIN" x25519 2>/dev/null)"
RELAY_PRIV="$(awk '/^PrivateKey:/{print $2} /^Private key:/{print $3}' <<<"$REALITY_KEYS")"
RELAY_PUB="$(awk '/^Password \(PublicKey\):/{print $3} /^Password:/{print $2} /^Public key:/{print $3}' <<<"$REALITY_KEYS")"
RELAY_UUID="$("$XRAY_BIN" uuid)"
SS_KEY="$(openssl rand -base64 32)"
SHORT_ID="aabbccdd"
SNI="www.example.com"

# ---------- 落地机：由本工具生成 inbound（SS2022） ----------
LANDING_STATE="$TMP/landing-state.json"
LANDING_CFG="$TMP/landing-cfg.json"
cat > "$LANDING_STATE" <<SJ
{
  "schema_version": 1, "server_ip": "127.0.0.1",
  "protocols": [
    { "name": "ss2022-01", "type": "ss2022", "port": ${P_LANDING},
      "method": "2022-blake3-aes-256-gcm", "password": "${SS_KEY}" }
  ]
}
SJ

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

echo "[1] 生成落地机配置（本工具 protocol_to_inbound → ss2022 inbound）"
bash "$GEN" "$MAIN" "$LANDING_STATE" "$LANDING_CFG" >/dev/null 2>&1
ck "  落地配置已生成" "$([[ -s "$LANDING_CFG" ]] && echo yes || echo no)" "yes"
ck "  inbound 协议=shadowsocks" "$(jq -r '.inbounds[0].protocol' "$LANDING_CFG")" "shadowsocks"
# ⚠️ test-only 调整（与中转侧同理）：生成的 routing 含 `block: geoip:private`，
#    回环目标属私网 → 落地机自己的该规则会把请求转到 block
#    （access log 显示 `[ss2022-01 -> block]`）。生产目标是公网域名不触发。
jq '.inbounds[0].listen="127.0.0.1"
    | .routing.rules |= map(select((.ip // []) | index("geoip:private") | not))
    | .outbounds[0].settings={finalRules:[{action:"allow",ip:["127.0.0.0/8"]}]}' \
   "$LANDING_CFG" > "$TMP/landing-run.json"
echo

# ---------- 中转机：由本工具生成 config（REALITY inbound + SS2022 landing outbound） ----------
echo "[2] 生成中转机配置（本工具 build_config → REALITY inbound + landing outbound）"
RELAY_STATE="$TMP/relay-state.json"
RELAY_CFG="$TMP/relay-cfg.json"
cat > "$RELAY_STATE" <<SJ
{
  "schema_version": 1, "server_ip": "127.0.0.1",
  "protocols": [
    { "name": "vless-reality-01", "type": "vless-reality", "port": ${P_RELAY},
      "uuid": "${RELAY_UUID}", "private_key": "${RELAY_PRIV}", "public_key": "${RELAY_PUB}",
      "sni": "${SNI}", "short_id": "${SHORT_ID}", "short_ids": ["${SHORT_ID}"] }
  ],
  "chain": { "role": "relay", "upstream": {
      "type": "ss2022", "name": "landing", "address": "127.0.0.1",
      "port": ${P_LANDING}, "method": "2022-blake3-aes-256-gcm",
      "password": "${SS_KEY}" } }
}
SJ
bash "$GEN" "$MAIN" "$RELAY_STATE" "$RELAY_CFG" >/dev/null 2>&1
ck "  中转配置已生成" "$([[ -s "$RELAY_CFG" ]] && echo yes || echo no)" "yes"
ck "  landing outbound 存在" "$(jq '[.outbounds[] | select(.tag=="landing")] | length' "$RELAY_CFG")" "1"
ck "  catch-all 指向 landing" "$(jq -r '.routing.rules[-1].outboundTag' "$RELAY_CFG")" "landing"
# ⚠️ test-only 调整：生成的 routing 含 `block: geoip:private`，而回环目标 127.0.0.1 属私网
#    → 请求会被该规则先拦掉（日志 `taking detour [block]`），链路"看似不通"。
#    **这是测试环境假象**：生产目标是公网域名，永不命中该规则。
#    故仅对【运行副本】去掉该规则；结构断言仍基于未修改的 $RELAY_CFG。
#    （同类坑：freedom 出站默认阻断私网，见 vps-script-distribution 技能）
jq '.inbounds[0].listen="127.0.0.1"
    | .routing.rules |= map(select((.ip // []) | index("geoip:private") | not))
    | .outbounds |= map(if .tag=="direct" then .settings={finalRules:[{action:"allow",ip:["127.0.0.0/8"]}]} else . end)' \
   "$RELAY_CFG" > "$TMP/relay-run.json"
echo

# ---------- 客户端（模拟真实客户端连中转机的 REALITY） ----------
cat > "$TMP/client.json" <<SJ
{
  "log": {"loglevel": "warning", "error": "$TMP/client.err.log"},
  "inbounds": [{"tag":"socks","listen":"127.0.0.1","port":${P_SOCKS},
                "protocol":"socks","settings":{"udp":true,"auth":"noauth"}}],
  "outbounds": [{
    "tag":"relay","protocol":"vless",
    "settings":{"address":"127.0.0.1","port":${P_RELAY},
                "id":"${RELAY_UUID}","encryption":"none","flow":"xtls-rprx-vision"},
    "streamSettings":{"network":"tcp","security":"reality",
      "realitySettings":{"serverName":"${SNI}","publicKey":"${RELAY_PUB}",
                         "shortId":"${SHORT_ID}","fingerprint":"chrome","spiderX":""}}
  }],
  "routing":{"rules":[{"type":"field","network":"tcp,udp","outboundTag":"relay"}]}
}
SJ

# ---------- 目标服务 ----------
mkdir -p "$TMP/web"
echo "LANDING-MARKER-OK" > "$TMP/web/marker.txt"

echo "[3] 启动三方进程"
(cd "$TMP/web" && exec python3 -m http.server "$P_WEB" --bind 127.0.0.1) >"$TMP/web.log" 2>&1 &
TRACKED_PIDS+=("$!")
sleep 1.2
ck "  目标 web 自检" "$(curl -s --max-time 5 --noproxy '*' "http://127.0.0.1:${P_WEB}/marker.txt")" "LANDING-MARKER-OK"

# 落地机（带 access log，用于证明流量真到落地）
jq --arg a "$TMP/landing.access.log" --arg e "$TMP/landing.err.log" \
   '.log={loglevel:"debug",access:$a,error:$e}' "$TMP/landing-run.json" > "$TMP/landing-final.json"
XRAY_LOCATION_ASSET="$GEO_ASSET" "$XRAY_BIN" run -format=json -config "$TMP/landing-final.json" >"$TMP/landing.out" 2>&1 &
TRACKED_PIDS+=("$!")
sleep 2
ck "  落地机监听 ${P_LANDING}" "$(ss -ltn 2>/dev/null | grep -c ":${P_LANDING}")" "1"

# 中转机（带 access log）
jq --arg a "$TMP/relay.access.log" --arg e "$TMP/relay.err.log" \
   '.log={loglevel:"debug",access:$a,error:$e}' "$TMP/relay-run.json" > "$TMP/relay-final.json"
XRAY_LOCATION_ASSET="$GEO_ASSET" "$XRAY_BIN" run -format=json -config "$TMP/relay-final.json" >"$TMP/relay.out" 2>&1 &
TRACKED_PIDS+=("$!")
sleep 2
ck "  中转机监听 ${P_RELAY}" "$(ss -ltn 2>/dev/null | grep -c ":${P_RELAY}")" "1"
if ! ss -ltn 2>/dev/null | grep -q ":${P_RELAY}"; then
  echo "      -- 中转机启动输出 --"
  tail -15 "$TMP/relay.out" | sed 's/^/      /'
  echo "      -- 中转机 err.log --"
  tail -15 "$TMP/relay.err.log" 2>/dev/null | sed 's/^/      /'
fi

# 客户端
XRAY_LOCATION_ASSET="$GEO_ASSET" "$XRAY_BIN" run -format=json -config "$TMP/client.json" >"$TMP/client.out" 2>&1 &
TRACKED_PIDS+=("$!")
sleep 2
ck "  客户端 SOCKS 监听 ${P_SOCKS}" "$(ss -ltn 2>/dev/null | grep -c ":${P_SOCKS}")" "1"
echo

echo "[4] 正向：客户端 → 中转机(REALITY) → 落地机(SS2022) → 目标"
# ⚠️ 不加 --noproxy（会连带禁用 --socks5 造成直连假阳性）
RES="$(curl -s --max-time 15 --socks5-hostname "127.0.0.1:${P_SOCKS}" \
        "http://127.0.0.1:${P_WEB}/marker.txt" 2>&1)"
ck "  端到端取到内容" "$RES" "LANDING-MARKER-OK"
sleep 1.5
if [[ "$RES" != "LANDING-MARKER-OK" ]]; then
  echo "      -- 中转机 err.log（查阻断原因）--"
  grep -iE 'block|reject|routing|detour|error' "$TMP/relay.err.log" 2>/dev/null | tail -8 | sed 's/^/      /'
fi

echo
echo "[5] 关键证据：落地机 access log（证明流量真过了两跳）"
N="$(grep -c "accepted" "$TMP/landing.access.log" 2>/dev/null | head -1 || true)"; N="${N:-0}"
if [[ "${N:-0}" -ge 1 ]]; then
  echo "  [PASS] 落地机有 ${N} 条 accepted 记录"; PASS=$((PASS+1))
  grep "accepted" "$TMP/landing.access.log" | tail -2 | sed 's/^/         /'
else
  echo "  [FAIL] 落地机无 accepted 记录（流量没走落地！）"; FAIL=$((FAIL+1))
fi
# 中转机应只见转发到落地，不见明文目标
if grep -q "tunneling request" "$TMP/relay.err.log" 2>/dev/null; then
  echo "  [PASS] 中转机有 SS2022 tunneling 记录"
  grep "tunneling request" "$TMP/relay.err.log" | tail -1 | sed 's/^/         /'
  PASS=$((PASS+1))
else
  echo "  [FAIL] 中转机无 tunneling 记录"; FAIL=$((FAIL+1))
fi
echo

echo "[6] 反事实 A：杀掉落地机 → 必须失败"
for p in $(pgrep -f "landing-final.json" 2>/dev/null); do kill "$p" 2>/dev/null; done
sleep 1.5
ck "  落地机已停" "$(ss -ltn 2>/dev/null | grep -c ":${P_LANDING}")" "0"
R2="$(curl -s --max-time 8 --socks5-hostname "127.0.0.1:${P_SOCKS}" \
       "http://127.0.0.1:${P_WEB}/marker.txt" 2>&1)"
if [[ "$R2" == "LANDING-MARKER-OK" ]]; then
  echo "  [FAIL] 落地停机后仍成功 → 假阳性（流量没走链路）"; FAIL=$((FAIL+1))
else
  echo "  [PASS] 落地停机后失败 → 链路真实（流量确实经过落地）"; PASS=$((PASS+1))
fi
echo

echo "[7] 反事实 B：链路配置移除后（单机模式）不应再有 landing"
jq 'del(.chain)' "$RELAY_STATE" > "$TMP/noland-state.json"
bash "$GEN" "$MAIN" "$TMP/noland-state.json" "$TMP/noland-cfg.json" >/dev/null 2>&1
ck "  无 chain 时无 landing outbound" \
  "$(jq '[.outbounds[] | select(.tag=="landing")] | length' "$TMP/noland-cfg.json")" "0"
ck "  无 chain 时无 catch-all" \
  "$(jq '[.routing.rules[] | select(.outboundTag=="landing")] | length' "$TMP/noland-cfg.json")" "0"
echo

echo "==================================="
printf ' PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
