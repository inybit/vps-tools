#!/usr/bin/env bash
# xray-deploy 新增协议 vless-xhttp3-nginx 回归验证（阶段 4）
#
# 覆盖：
#   A. 触点完整性（14 处，对照 references 的触点点清单）
#   B. nginx 检测门（要求 1：未装则退出且零副作用）
#   C. inbound 生成 + 真实 xray -test
#   D. 冲突检查（UDS 路径 / TCP / UDP 端口）
#   E. service unit（RuntimeDirectory / OpenRC start_pre+stop_post）
#   F. info 输出（客户端片段 + nginx 只读参考）
#
# 用法: bash tests/verify-xray-deploy-xhttp3-nginx.sh
# 退出码: 0=全部通过
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${REPO}/proxy/xray-deploy"
MAIN="${TOOL}/xray-deploy.sh"
XRAY_BIN="${XRAY_BIN:-$(command -v xray 2>/dev/null || true)}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ck() {  # $1=名称 $2=实际 $3=期望
  if [[ "$2" == "$3" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

echo "=== vless-xhttp3-nginx 回归验证 ==="
echo "工具: ${TOOL}"
echo

# ---------- A. 触点完整性 ----------
echo "[A] 触点完整性（14 处）"
ck "1) PROTO_REGISTRY 含 vless-xhttp3-nginx" \
  "$(grep -c '"vless-xhttp3-nginx|' "${TOOL}/lib/registry.sh")" "1"
ck "2) protocol_to_inbound 有分支" \
  "$(grep -c '^    vless-xhttp3-nginx)' "${TOOL}/lib/inbound.sh")" "1"
ck "3) proto_wizard_vless_xhttp3_nginx 已定义" \
  "$(grep -c '^proto_wizard_vless_xhttp3_nginx()' "${TOOL}/lib/xhttp3.sh")" "1"
ck "4) gen_client_mihomo_vless_xhttp3_nginx 已定义" \
  "$(grep -c '^gen_client_mihomo_vless_xhttp3_nginx()' "${TOOL}/lib/client-mihomo.sh")" "1"
ck "5) gen_client_singbox_vless_xhttp3_nginx 已定义" \
  "$(grep -c '^gen_client_singbox_vless_xhttp3_nginx()' "${TOOL}/lib/client-singbox.sh")" "1"
ck "6a) mihomo 分发含该类型" \
  "$(grep -c 'vless-xhttp3-nginx) gen_client_mihomo_vless_xhttp3_nginx' "${TOOL}/lib/client-mihomo.sh")" "1"
ck "6b) singbox 分发含该类型" \
  "$(grep -c 'vless-xhttp3-nginx) gen_client_singbox_vless_xhttp3_nginx' "${TOOL}/lib/client-singbox.sh")" "1"
ck "7) cmd_install 含该类型" \
  "$(grep -c 'vless-xhttp3-nginx) params="\$(proto_wizard_vless_xhttp3_nginx' "${TOOL}/lib/cmd-lifecycle.sh")" "1"
ck "8) proto_add 含该类型" \
  "$(grep -c 'vless-xhttp3-nginx) params="\$(proto_wizard_vless_xhttp3_nginx' "${TOOL}/lib/proto-crud.sh")" "1"
ck "9) proto_edit 支持该类型" \
  "$(grep -c 'vless-xhttp3-nginx' "${TOOL}/lib/proto-edit.sh")" "6"
ck "10) proto_list_names 显示 socket_path" \
  "$(grep -c 'socket \" + .value.socket_path' "${TOOL}/lib/proto-crud.sh")" "1"
ck "11a) cmd_info 含该类型 3 个分支（地址行 + 显示 + nginx 参考）" \
  "$(grep -c 'if \[\[ "\$type" == "vless-xhttp3-nginx" \]\]\|elif \[\[ "\$type" == "vless-xhttp3-nginx" \]\]' "${TOOL}/lib/cmd-info.sh")" "3"
ck "11b) usage 含该协议说明" \
  "$(grep -c '^  vless-xhttp3-nginx$' "${TOOL}/lib/usage.sh")" "1"
ck "12) UDS 冲突检查已定义" \
  "$(grep -c '^xhttp3_check_socket_conflict()' "${TOOL}/lib/xhttp3.sh")" "1"
ck "13) 端口冲突检查已定义" \
  "$(grep -c '^xhttp3_check_port_conflict()' "${TOOL}/lib/xhttp3.sh")" "1"
ck "14) unit 含 RuntimeDirectory" \
  "$(grep -c '^RuntimeDirectory=' "${TOOL}/lib/service.sh")" "1"
ck "入口 source 了新模块" \
  "$(grep -c 'LIB_DIR}/xhttp3.sh' "${MAIN}")" "1"
ck "install.sh extra_files 含新模块" \
  "$(grep -c 'proxy/xray-deploy/lib/xhttp3.sh' "${REPO}/install.sh")" "1"
echo

# ---------- 生成器探针 ----------
PROBE="${TMP}/probe.sh"
cat > "$PROBE" <<'PROBE'
set -uo pipefail
src="$1"
t="$(dirname "$src")/.nodisp.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$t"
source "$t"; rm -f "$t"
STATE_FILE="$2"; CONFIG_FILE="$3"; UDS_BASE_DIR="$4"
BIN_PATH="${XRAY_BIN:-/bin/true}"
service_restart() { :; }; need_root() { :; }
# MOCK_NO_NGINX=1：确定性遮蔽 nginx（不依赖宿主机是否真装了 nginx）
# ⚠️ 必须在 source 之后定义：否则会被 lib 内的定义覆盖，且 command -v 走的还是真 PATH
if [[ "${MOCK_NO_NGINX:-0}" == "1" ]]; then
  command() { [[ "$1" == "-v" && "$2" == "nginx" ]] && return 1; builtin command "$@"; }
fi
"${@:5}"
PROBE

STATE="${TMP}/state.json"; CFG="${TMP}/config.json"; RUN="${TMP}/run"
mkdir -p "$RUN"

# ---------- B. nginx 检测门（要求 1） ----------
echo "[B] nginx 检测门（未安装 → 提示退出，零副作用）"
echo '{"schema_version":1,"server_ip":"","installed_at":"x","protocols":[]}' > "$STATE"
BEFORE="$(md5sum "$STATE" | awk '{print $1}')"
# 用 MOCK_NO_NGINX=1 确定性遮蔽 nginx（宿主机的 nginx 存在与否不影响本断言）
out="$(MOCK_NO_NGINX=1 bash "$PROBE" "$MAIN" "$STATE" "$CFG" "$RUN" \
  proto_wizard_vless_xhttp3_nginx probe 2>&1)"
ck "未装 nginx 时提示" "$(grep -c '未检测到 nginx' <<<"$out")" "1"
ck "提示 vps-tools 自带安装器" "$(grep -c 'nginx-install' <<<"$out")" "1"
ck "未装 nginx 时向导失败（非 0）" "$(grep -c '已退出，未做任何修改' <<<"$out")" "1"
ck "state.json 未被写入（零副作用）" "$(md5sum "$STATE" | awk '{print $1}')" "$BEFORE"

# mock 一个已安装的 nginx
MB="${TMP}/bin"; mkdir -p "$MB"
cat > "$MB/nginx" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -v) echo "nginx version: nginx/1.27.4" ;;
  -V) echo "configure arguments: --with-http_v3_module" ;;
esac
EOF
chmod +x "$MB/nginx"
wiz="$(printf '\n203.0.113.9.example.com\n\n' | PATH="$MB:/usr/bin:/bin" bash "$PROBE" "$MAIN" "$STATE" "$CFG" "$RUN" proto_wizard_vless_xhttp3_nginx "vless-xhttp3-nginx-01" 2>"${TMP}/w.err")"
ck "向导输出可被 jq 解析" "$(jq -r '.type' <<<"$wiz" 2>/dev/null)" "vless-xhttp3-nginx"
ck "向导 port 默认 443" "$(jq -r '.port' <<<"$wiz" 2>/dev/null)" "443"
ck "向导 path 默认 /xray" "$(jq -r '.path' <<<"$wiz" 2>/dev/null)" "/xray"
ck "向导 socket_path 落 UDS_BASE_DIR" "$(jq -r '.socket_path' <<<"$wiz" 2>/dev/null)" "${RUN}/vless-xhttp3-nginx-01.socket"
ck "向导 domain 取自输入" "$(jq -r '.domain' <<<"$wiz" 2>/dev/null)" "203.0.113.9.example.com"
# 低版本警告
sed -i 's|nginx/1.27.4|nginx/1.20.0|' "$MB/nginx"
printf '\n203.0.113.9.example.com\n\n' | PATH="$MB:/usr/bin:/bin" bash "$PROBE" "$MAIN" "$STATE" "$CFG" "$RUN" proto_wizard_vless_xhttp3_nginx "x" >/dev/null 2>"${TMP}/w2.err"
ck "低版本给出警告" "$(grep -c '1.20.0 < 1.25.0' "${TMP}/w2.err")" "1"
echo

# ---------- C. inbound 生成 + 真实 xray -test ----------
echo "[C] inbound 生成"
cat > "$STATE" <<EOF
{"schema_version":1,"server_ip":"203.0.113.7","installed_at":"x",
 "protocols":[{"name":"vless-xhttp3-nginx-01","type":"vless-xhttp3-nginx","port":443,
  "uuid":"11111111-1111-1111-1111-111111111111","domain":"example.com","path":"/xray",
  "socket_path":"${RUN}/vless-xhttp3-nginx-01.socket"}]}
EOF
inbound="$(bash "$PROBE" "$MAIN" "$STATE" "$CFG" "$RUN" \
  protocol_to_inbound "$(jq -c '.protocols[0]' "$STATE")" 2>/dev/null)"
ck "listen 为 UDS 路径+0666" "$(jq -r '.listen' <<<"$inbound" 2>/dev/null)" "${RUN}/vless-xhttp3-nginx-01.socket,0666"
ck "network=xhttp" "$(jq -r '.streamSettings.network' <<<"$inbound" 2>/dev/null)" "xhttp"
ck "mode=stream-one" "$(jq -r '.streamSettings.xhttpSettings.mode' <<<"$inbound" 2>/dev/null)" "stream-one"
ck "无 security（明文交 nginx）" "$(jq -r '.streamSettings.security // "none"' <<<"$inbound" 2>/dev/null)" "none"
ck "无 tlsSettings" "$(jq -r '.streamSettings.tlsSettings // "none"' <<<"$inbound" 2>/dev/null)" "none"
ck "无 realitySettings" "$(jq -r '.streamSettings.realitySettings // "none"' <<<"$inbound" 2>/dev/null)" "none"
ck "无 port 字段（UDS 必须省略 port）" "$(jq -r '.port // "none"' <<<"$inbound" 2>/dev/null)" "none"
ck "clients[0].id 正确" "$(jq -r '.settings.clients[0].id' <<<"$inbound" 2>/dev/null)" "11111111-1111-1111-1111-111111111111"

if [[ -n "$XRAY_BIN" ]]; then
  jq -n --argjson ib "$inbound" '{log:{loglevel:"warning"},inbounds:[$ib],
    outbounds:[{protocol:"freedom",tag:"direct"},{protocol:"blackhole",tag:"block"}]}' > "$CFG"
  if "$XRAY_BIN" run -test -format=json -config "$CFG" >/dev/null 2>&1; then
    printf '  [PASS] 真实 xray -test 校验通过\n'; PASS=$((PASS+1))
  else
    printf '  [FAIL] 真实 xray -test 失败\n'; "$XRAY_BIN" run -test -format=json -config "$CFG" 2>&1 | tail -3 | sed 's/^/         /'; FAIL=$((FAIL+1))
  fi
else
  echo "  [SKIP] 未找到 xray 二进制（设 XRAY_BIN 启用真实校验）"
fi
echo

# ---------- D. 冲突检查 ----------
echo "[D] 冲突检查（xray -test 的盲区）"
cat > "$STATE" <<EOF
{"schema_version":1,"server_ip":"203.0.113.7","installed_at":"x","protocols":[
 {"name":"existing-xhttp3","type":"vless-xhttp3-nginx","port":2053,"uuid":"u","domain":"a.com","path":"/x","socket_path":"${RUN}/dup.socket"}]}
EOF
o="$(bash "$PROBE" "$MAIN" "$STATE" "$CFG" "$RUN" xhttp3_check_socket_conflict "${RUN}/dup.socket" new 2>&1)"; rc=$?
ck "UDS 路径撞车 → 非 0 退出" "$([[ $rc -ne 0 ]] && echo yes || echo no)" "yes"
ck "报出冲突协议名" "$(grep -c '已被协议 existing-xhttp3 占用' <<<"$o")" "1"
bash "$PROBE" "$MAIN" "$STATE" "$CFG" "$RUN" xhttp3_check_socket_conflict "${RUN}/free.socket" new >/dev/null 2>&1
ck "UDS 路径空闲 → 通过" "$?" "0"
bash "$PROBE" "$MAIN" "$STATE" "$CFG" "$RUN" xhttp3_check_socket_conflict "${RUN}/dup.socket" existing-xhttp3 >/dev/null 2>&1
ck "编辑自身排除自己 → 通过" "$?" "0"

cat > "$STATE" <<EOF
{"schema_version":1,"server_ip":"203.0.113.7","installed_at":"x","protocols":[
 {"name":"vless-reality-01","type":"vless-reality","port":443,"uuid":"u","private_key":"x","public_key":"y","sni":"a.com","short_id":"aa","short_ids":["aa"]}]}
EOF
o="$(bash "$PROBE" "$MAIN" "$STATE" "$CFG" "$RUN" xhttp3_check_port_conflict 443 new 2>&1)"; rc=$?
ck "TCP 443 撞 reality → 非 0" "$([[ $rc -ne 0 ]] && echo yes || echo no)" "yes"
ck "报出 TCP 占用" "$(grep -c 'TCP 端口 443 已被协议 vless-reality-01 占用' <<<"$o")" "1"
cat > "$STATE" <<EOF
{"schema_version":1,"server_ip":"203.0.113.7","installed_at":"x","protocols":[
 {"name":"hysteria2-01","type":"hysteria2","port":443,"password":"p","domain":"a.com","cert_file":"c","key_file":"k"}]}
EOF
o="$(bash "$PROBE" "$MAIN" "$STATE" "$CFG" "$RUN" xhttp3_check_port_conflict 443 new 2>&1)"
ck "UDP 443 撞 hy2 → 非 0" "$([[ $? -ne 0 ]] && echo yes || echo no)" "yes"
ck "报出 UDP 占用" "$(grep -c 'UDP 端口 443 已被协议 hysteria2-01 占用' <<<"$o")" "1"
bash "$PROBE" "$MAIN" "$STATE" "$CFG" "$RUN" xhttp3_check_port_conflict 2053 new >/dev/null 2>&1
ck "端口空闲 → 通过" "$?" "0"
echo

# ---------- E. service unit ----------
echo "[E] service unit（方案 B：RuntimeDirectory）"
ck "systemd 含 RuntimeDirectory" "$(grep -c '^RuntimeDirectory=\$(basename "\$UDS_BASE_DIR")$' "${TOOL}/lib/service.sh")" "1"
ck "systemd 含 RuntimeDirectoryMode=0755" "$(grep -c '^RuntimeDirectoryMode=0755$' "${TOOL}/lib/service.sh")" "1"
ck "systemd 保留 ExecStart" "$(grep -c '^ExecStart=\${BIN_PATH} run -config \${CONFIG_FILE}$' "${TOOL}/lib/service.sh")" "1"
ck "OpenRC 含 start_pre 建目录" "$(grep -c 'mkdir -p "\${UDS_BASE_DIR}" && chmod 0755 "\${UDS_BASE_DIR}"' "${TOOL}/lib/service.sh")" "1"
ck "OpenRC 含 stop_post 清理" "$(grep -c 'rm -rf "\${UDS_BASE_DIR}"' "${TOOL}/lib/service.sh")" "1"
ck "proto_add 对新类型重写 unit" "$(grep -c 'vless-xhttp3-nginx" \]\] && xhttp3_ensure_service_unit' "${TOOL}/lib/proto-crud.sh")" "1"
ck "cmd_install 对新类型用 ensure_service_unit" "$(grep -c 'xhttp3_ensure_service_unit' "${TOOL}/lib/cmd-lifecycle.sh")" "1"
echo

# ---------- F. info 输出 ----------
echo "[F] info 输出（客户端片段 + nginx 只读参考）"
cat > "$STATE" <<EOF
{"schema_version":1,"server_ip":"203.0.113.7","installed_at":"x","protocols":[
 {"name":"vless-xhttp3-nginx-01","type":"vless-xhttp3-nginx","port":443,
  "uuid":"11111111-1111-1111-1111-111111111111","domain":"203.0.113.9.example.com",
  "path":"/xray","socket_path":"${RUN}/vless-xhttp3-nginx-01.socket"}]}
EOF
info="$(bash "$PROBE" "$MAIN" "$STATE" "$CFG" "$RUN" cmd_info 2>&1)"
ck "打印传输链路" "$(grep -c 'HTTP/3 (QUIC/UDP) → nginx → h2c/gRPC over UDS → xray' <<<"$info")" "1"
ck "说明端口由 nginx 监听" "$(grep -c '端口 443 由 nginx 监听' <<<"$info")" "1"
ck "说明证书由 nginx 持有" "$(grep -c 'TLS 证书由 nginx 持有' <<<"$info")" "1"
ck "含可粘贴 grpc_pass 行" "$(grep -c "grpc_pass unix:${RUN}/vless-xhttp3-nginx-01.socket;" <<<"$info")" "1"
ck "location 带尾斜杠（stream-one 实际路径）" "$(grep -c 'location /xray/' <<<"$info")" "1"
ck "含 quic listen 行" "$(grep -c 'listen 443 quic reuseport;' <<<"$info")" "1"
ck "证书路径为占位符（不代管证书）" "$(grep -c 'ssl_certificate     /path/to/fullchain.pem;' <<<"$info")" "1"
ck "含 UDP 放行提示" "$(grep -c 'ufw allow 443/udp' <<<"$info")" "1"
ck "mihomo 片段含 alpn h3" "$(grep -c '^      - h3$' <<<"$info")" "1"
ck "mihomo 片段含 mode stream-one" "$(grep -c '^      mode: stream-one$' <<<"$info")" "1"
ck "按 D3 决策不生成 XMUX" "$(grep -c 'reuse-settings' <<<"$info")" "0"
ck "sing-box 段提示不支持 XHTTP" "$(grep -c 'sing-box 上游不支持 XHTTP' <<<"$info")" "1"
ck "无 REALITY → 不误报 mlkem768 警告" "$(grep -c 'support-x25519mlkem768' <<<"$info")" "0"
ck "nginx 参考注明只读" "$(grep -c 'nginx 配置参考（只读' <<<"$info")" "1"
# --- CF SaaS 回归（2026-09-19 真机事故）---
# 事故：客户端 server 填了本机 IP → 绕过 CF 直连源站，SNI=域名但源站证书是
#       CF Origin CA *.007233.xyz → x509 校验失败（mihomo CRYPTO_ERROR 0x12a）。
# fixture 里 IP=203.0.113.7、domain=203.0.113.9.example.com 互不相同，可精确区分。
ck "mihomo server 填【域名】而非源站 IP" \
  "$(sed -n '/mihomo (Clash Meta) proxies 片段/,/sing-box outbounds/p' <<<"$info" \
     | grep -c '^    server: 203.0.113.9.example.com$')" "1"
ck "mihomo 片段【不】出现源站 IP 作 server" \
  "$(sed -n '/mihomo (Clash Meta) proxies 片段/,/sing-box outbounds/p' <<<"$info" \
     | grep -c '^    server: 203.0.113.7$')" "0"
ck "sing-box server 填【域名】而非源站 IP" \
  "$(grep -c '"server": "203.0.113.9.example.com"' <<<"$info")" "1"
ck "sing-box 片段【不】出现源站 IP 作 server" \
  "$(grep -c '"server": "203.0.113.7"' <<<"$info")" "0"
ck "info 地址行提示填域名（非 IP:port）" \
  "$(grep -c '客户端填域名；本机 IP 203.0.113.7 仅源站，勿直连' <<<"$info")" "1"
ck "nginx 参考含 CF SaaS 证书/SNI 铁律" \
  "$(grep -c 'CF SaaS（橙云）场景的证书与 SNI 铁律' <<<"$info")" "1"
ck "nginx 参考点明绕过 CF 直连源站会失败" \
  "$(grep -c '填 IP 会绕过 CF 直连源站' <<<"$info")" "1"
echo

echo "==================================="
echo " PASS=${PASS} FAIL=${FAIL}"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
