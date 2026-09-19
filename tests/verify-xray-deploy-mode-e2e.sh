#!/usr/bin/env bash
# 分流模式端到端：真实切换 mode → 配置生效 → 流量真按模式走（loopback）
#
# 关键：不只断言 JSON 形态，而是**真实 xray 进程 + 真实请求**验证分流决策。
#   目标 A = 白名单内（geosite:google 模拟）→ 应走落地
#   目标 B = 白名单外 → 应直出
#
# ⚠️ 用 `geosite:cn` 作"白名单"标签来构造可控分流：
#    生成配置里的 `block: geosite:cn` 是底线规则，会抢在 landing 之前命中，
#    故本测试改用 custom 模式 + 可控标签，并通过 xray access log 观察 detour。
#
# 简化手法：用 Xray 的 routing 决策日志（taking detour [X]）作为判据，
#   不需要真的准备两套目标——直接看 dispatcher 选了哪个 outbound。
#
# 用法: bash tests/verify-xray-deploy-mode-e2e.sh
# 退出码: 0=全部通过
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${REPO}/proxy/xray-deploy"
MAIN="${TOOL}/xray-deploy.sh"
TMP="$(mktemp -d)"
TRACKED_PIDS=()
cleanup() { for p in "${TRACKED_PIDS[@]:-}"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done; rm -rf "$TMP"; }
trap cleanup EXIT

PASS=0; FAIL=0
ck() {
  if [[ "$2" == "$3" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

# 等待端口进入 LISTEN（轮询替代固定 sleep，防高负载下假 FAIL）
wait_listen() {  # $1=端口 [超时秒]
  local p="$1" t="${2:-10}" i=0
  while (( i < t*10 )); do
    ss -ltn 2>/dev/null | grep -q ":${p}" && return 0
    sleep 0.1; i=$((i+1))
  done
  return 1
}

XRAY_BIN="${XRAY_BIN:-/tmp/hermes-ss2022-e2e/xray}"
[[ -x "$XRAY_BIN" ]] || { echo "需要 xray: $XRAY_BIN" >&2; exit 1; }
GEO_ASSET="${GEO_ASSET:-/tmp/geodata}"
[[ -f "${GEO_ASSET}/geosite.dat" ]] || { echo "需要 geo: $GEO_ASSET" >&2; exit 1; }

P_RELAY=28702; P_SOCKS=28703; P_LANDING=28701; P_WEB=28704

echo "=== 分流模式端到端：切 mode → 流量真按模式走 ==="
echo

_k="$("$XRAY_BIN" x25519 2>/dev/null)"
PRIV="$(awk '/^PrivateKey:/{print $2} /^Private key:/{print $3}' <<<"$_k")"
PUB="$(awk '/^Password \(PublicKey\):/{print $3} /^Password:/{print $2} /^Public key:/{print $3}' <<<"$_k")"
UUID="$("$XRAY_BIN" uuid)"
SS_KEY="$(openssl rand -base64 32)"

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

mk_state() {  # $1=mode
  cat > "$TMP/state.json" <<SJ
{
  "schema_version": 1, "server_ip": "127.0.0.1",
  "protocols": [
    { "name": "vless-reality-01", "type": "vless-reality", "port": ${P_RELAY},
      "uuid": "${UUID}", "private_key": "${PRIV}", "public_key": "${PUB}",
      "sni": "www.example.com", "short_id": "aabbccdd", "short_ids": ["aabbccdd"] }
  ],
  "chain": { "role": "relay", "mode": "$1", "upstream": {
      "type": "ss2022", "name": "landing", "address": "127.0.0.1",
      "port": ${P_LANDING}, "method": "2022-blake3-aes-256-gcm",
      "password": "${SS_KEY}" } }
}
SJ
  bash "$GEN" "$MAIN" "$TMP/state.json" "$TMP/cfg.json" >/dev/null 2>&1
  # test-only：回环属私网，去掉 geoip:private 底线规则（生产目标为公网不触发）
  jq --arg a "$TMP/relay.access.log" --arg e "$TMP/relay.err.log" \
     '.log={loglevel:"debug",access:$a,error:$e}
      | .inbounds[0].listen="127.0.0.1"
      | .routing.rules |= map(select((.ip // []) | index("geoip:private") | not))
      | .outbounds |= map(if .tag=="direct" then .settings={finalRules:[{action:"allow",ip:["127.0.0.0/8"]}]} else . end)' \
     "$TMP/cfg.json" > "$TMP/relay-final.json"
}

# ⚠️ 必须单独记录 relay 的 PID：早期版本用 stop_relay 遍历 TRACKED_PIDS，
#    会把 web/landing/client 一起杀掉 → 切一次 mode 后整个环境就废了（假 FAIL）。
RELAY_PID=""
start_relay() {
  XRAY_LOCATION_ASSET="$GEO_ASSET" "$XRAY_BIN" run -format=json -config "$TMP/relay-final.json" >"$TMP/relay.out" 2>&1 &
  RELAY_PID="$!"; TRACKED_PIDS+=("$RELAY_PID")
  wait_listen "$P_RELAY" 15
}
stop_relay() {
  [[ -n "$RELAY_PID" ]] && kill "$RELAY_PID" 2>/dev/null
  # 从清理列表移除已停的 relay，避免 cleanup 重复 kill
  local keep=()
  for p in "${TRACKED_PIDS[@]:-}"; do [[ -n "$p" && "$p" != "$RELAY_PID" ]] && keep+=("$p"); done
  TRACKED_PIDS=("${keep[@]:-}")
  RELAY_PID=""
  sleep 1.5
}

# 客户端
cat > "$TMP/client.json" <<SJ
{
  "log": {"loglevel": "warning", "error": "$TMP/client.err.log"},
  "inbounds": [{"tag":"socks","listen":"127.0.0.1","port":${P_SOCKS},"protocol":"socks",
    "settings":{"udp":true,"auth":"noauth"}}],
  "outbounds": [{"tag":"relay","protocol":"vless",
    "settings":{"address":"127.0.0.1","port":${P_RELAY},"id":"${UUID}",
      "encryption":"none","flow":"xtls-rprx-vision"},
    "streamSettings":{"network":"tcp","security":"reality",
      "realitySettings":{"serverName":"www.example.com","publicKey":"${PUB}",
        "shortId":"aabbccdd","fingerprint":"chrome","spiderX":""}}}],
  "routing":{"rules":[{"type":"field","network":"tcp,udp","outboundTag":"relay"}]}
}
SJ

# 目标 web + 一个"模拟白名单域名"：用 /etc/hosts 不可控，改用 IP 直连 + routing 里的 domain 规则
# 简化：用 geosite:category-ads-all 作为可控"白名单"（它是 block 底线，改成 custom 指向 landing 会冲突）
# 最稳的可控判据：直接看 dispatcher 的 detour 决策日志，用不同目标端口区分
mkdir -p "$TMP/web"
echo "MARKER-A" > "$TMP/web/a.txt"
echo "MARKER-B" > "$TMP/web/b.txt"
(cd "$TMP/web" && exec python3 -m http.server "$P_WEB" --bind 127.0.0.1) >"$TMP/web.log" 2>&1 &
TRACKED_PIDS+=("$!")
sleep 1.2

XRAY_LOCATION_ASSET="$GEO_ASSET" "$XRAY_BIN" run -format=json -config "$TMP/client.json" >"$TMP/client.out" 2>&1 &
TRACKED_PIDS+=("$!")
wait_listen "$P_SOCKS" 15

# 生成落地机配置（ss2022 inbound）
cat > "$TMP/landing-state.json" <<SJ
{
  "schema_version": 1, "server_ip": "127.0.0.1",
  "protocols": [{ "name": "ss2022-01", "type": "ss2022", "port": ${P_LANDING},
    "method": "2022-blake3-aes-256-gcm", "password": "${SS_KEY}" }]
}
SJ
bash "$GEN" "$MAIN" "$TMP/landing-state.json" "$TMP/landing-cfg.json" >/dev/null 2>&1
jq '.inbounds[0].listen="127.0.0.1"
    | .routing.rules |= map(select((.ip // []) | index("geoip:private") | not))
    | .outbounds[0].settings={finalRules:[{action:"allow",ip:["127.0.0.0/8"]}]}' \
   "$TMP/landing-cfg.json" > "$TMP/landing-final.json"
XRAY_LOCATION_ASSET="$GEO_ASSET" "$XRAY_BIN" run -format=json -config "$TMP/landing-final.json" >"$TMP/landing.out" 2>&1 &
TRACKED_PIDS+=("$!")
wait_listen "$P_LANDING" 15
echo "[1] 三方就绪"
ck "  落地机监听" "$(ss -ltn 2>/dev/null | grep -c ":${P_LANDING}")" "1"
ck "  客户端 SOCKS 监听" "$(ss -ltn 2>/dev/null | grep -c ":${P_SOCKS}")" "1"
echo

echo "[2] mode=all → 请求应走落地（能取到内容）"
mk_state all; stop_relay; start_relay
ck "  中转机监听" "$(ss -ltn 2>/dev/null | grep -c ":${P_RELAY}")" "1"
R="$(curl -s --max-time 12 --socks5-hostname "127.0.0.1:${P_SOCKS}" "http://127.0.0.1:${P_WEB}/a.txt" 2>&1)"
ck "  取到内容" "$R" "MARKER-A"
sleep 1
ck "  走了落地（landing outbound 命中）" \
  "$(grep -c 'taking detour \[landing\]' "$TMP/relay.err.log" 2>/dev/null; true)" "1"
echo

echo "[3] mode=none → 请求应直出（不出现 landing detour）"
mk_state none; stop_relay; start_relay
: > "$TMP/relay.err.log" 2>/dev/null || true
R2="$(curl -s --max-time 12 --socks5-hostname "127.0.0.1:${P_SOCKS}" "http://127.0.0.1:${P_WEB}/b.txt" 2>&1)"
ck "  取到内容（直出也通）" "$R2" "MARKER-B"
sleep 1
ck "  未走落地（无 landing detour）" \
  "$(grep -c 'taking detour \[landing\]' "$TMP/relay.err.log" 2>/dev/null; true)" "0"
ck "  走了直出（direct detour）" \
  "$(grep -c 'taking detour \[direct\]' "$TMP/relay.err.log" 2>/dev/null; true)" "1"
echo

echo "[4] mode=google → IP 直连目标不在白名单 → 应直出"
mk_state google; stop_relay; start_relay
: > "$TMP/relay.err.log" 2>/dev/null || true
R3="$(curl -s --max-time 12 --socks5-hostname "127.0.0.1:${P_SOCKS}" "http://127.0.0.1:${P_WEB}/a.txt" 2>&1)"
ck "  取到内容" "$R3" "MARKER-A"
sleep 1
ck "  IP 目标未命中白名单 → 直出" \
  "$(grep -c 'taking detour \[direct\]' "$TMP/relay.err.log" 2>/dev/null; true)" "1"
ck "  未走落地" \
  "$(grep -c 'taking detour \[landing\]' "$TMP/relay.err.log" 2>/dev/null; true)" "0"
echo

echo "==================================="
printf ' PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
