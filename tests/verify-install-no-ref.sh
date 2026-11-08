#!/usr/bin/env bash
# ============================================================
# 回归：--ref / VPS_TOOLS_REF 已在 v1.20.0 移除（2026-11-08「彻底解耦」）
#
# 背景：安装器与工具各有版本号 + --ref 版本固定，导致「版本号 ↔ 内容」必须
#   一一对应（否则回滚拿到的东西不确定）→ 每次改 install.sh 都被迫升版。
#   用户决定：不需要按版本安装/回滚，只跟 main。本套件守住移除后的契约：
#     ① 带 --ref 必须**立刻失败**并说清原因（不能静默忽略 → 用户以为钉住了版本）
#     ② 失败发生在任何网络/文件操作之前（0 次 curl，安装目录不动）
#     ③ VPS_TOOLS_REF 环境变量只告警，不改变安装结果
#     ④ 帮助文本与 list 输出不再宣传 --ref / @ref
#
# 用法: bash tests/verify-install-no-ref.sh
# 退出码: 0=全部通过
# ============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_INSTALL="${REPO}/install.sh"
[[ -f "$SRC_INSTALL" ]] || { echo "SKIP: 找不到 install.sh"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
MOCK="$T/mock"; LOG="$T/curl.log"
SANDBOX="$T/sandbox"; mkdir -p "$MOCK" "$SANDBOX/bin" "$SANDBOX/etc" "$SANDBOX/lib"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1  <<< $2"; }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

# mock curl：任何请求都记日志并失败（[A][B] 断言 0 次请求，[C] 走本地注入树）
cat > "$MOCK/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$MOCK_CURL_LOG"
echo "curl: (22) 404 (mock)" >&2
exit 22
STUB
chmod +x "$MOCK/curl"
export MOCK_CURL_LOG="$LOG"
export PATH="$MOCK:$PATH"

# ---------- 沙箱 install.sh（真路径/真 root 判定都要短路） ----------
sed -e "s|INSTALL_DIR=\"/usr/local/lib/vps-tools\"|INSTALL_DIR=\"$SANDBOX/lib\"|" \
    -e "s|CMD_DIR=\"/usr/local/bin\"|CMD_DIR=\"$SANDBOX/bin\"|" \
    -e "s|CONFIG_DIR=\"/etc\"|CONFIG_DIR=\"$SANDBOX/etc\"|" \
    "$SRC_INSTALL" > "$T/install.sh"
sed -i -e 's|\[\[ \$EUID -eq 0 \]\] \|\| return 1|:|g' \
       -e 's|if \[\[ \$EUID -eq 0 \]\]; then|if true; then|g' \
       -e 's|if \[\[ \$EUID -ne 0 \]\]; then|if false; then|g' "$T/install.sh"
chmod +x "$T/install.sh"

echo "=== [A] --ref <tag>：立刻失败，且在任何网络请求之前 ==="
: > "$LOG"
rc="$(bash "$T/install.sh" install xray-deploy --ref v1.19.5 > "$T/out" 2>&1; echo $?)"
chk "退出码非 0" "[[ '$rc' != '0' ]]"
chk "说明已于 v1.20.0 移除" "grep -q '已于 v1.20.0 移除' '$T/out'"
chk "给出替代办法（git checkout）" "grep -q 'git checkout' '$T/out'"
chk "0 次网络请求" "[[ ! -s '$LOG' ]]"
chk "未装任何东西" "[[ ! -d '$SANDBOX/lib/xray-deploy' ]]"

echo
echo "=== [B] --ref=<tag> 形式同样被拒 ==="
: > "$LOG"
rc="$(bash "$T/install.sh" update xray-deploy --ref=main > "$T/out" 2>&1; echo $?)"
chk "退出码非 0" "[[ '$rc' != '0' ]]"
chk "说明已于 v1.20.0 移除" "grep -q '已于 v1.20.0 移除' '$T/out'"
chk "0 次网络请求" "[[ ! -s '$LOG' ]]"

echo
echo "=== [C] VPS_TOOLS_REF 环境变量：告警但不改变安装结果 ==="
: > "$LOG"
rc="$(VPS_TOOLS_REF=v1.19.5 VPS_TOOLS_TARBALL_ROOT="$REPO" bash "$T/install.sh" install xray-deploy > "$T/out" 2>&1; echo $?)"
chk "退出码 0（安装照常）" "[[ '$rc' == '0' ]]"
chk "告警变量已失效" "grep -q 'VPS_TOOLS_REF=.*已于 v1.20.0 失效' '$T/out'"
chk "工具确实装上" "[[ -x '$SANDBOX/lib/xray-deploy/xray-deploy.sh' ]]"
chk "工具文件未走网络（无 proxy/xray-deploy 请求）" \
    "! grep -q 'proxy/xray-deploy' '$LOG'"

echo
echo "=== [D] 帮助文本 / list 不再宣传 --ref ==="
bash "$T/install.sh" -h > "$T/help" 2>&1
chk "帮助里无 --ref <tag> 用法" "! grep -q -- '--ref <tag>' '$T/help'"
chk "帮助说明版本策略（始终跟 main）" "grep -q '始终跟 main' '$T/help'"
bash "$T/install.sh" list > "$T/list" 2>&1
chk "list 不再输出 @ref" "! grep -q '@' '$T/list'"

echo
echo "=== [E] 静态：版本固定 / 逐文件回退的实现已彻底移除 ==="
chk "无 installer_ref() 定义" "! grep -q '^installer_ref()' '$SRC_INSTALL'"
chk "无 tool_ref() 定义" "! grep -q '^tool_ref()' '$SRC_INSTALL'"
chk "无 record_tool_ref / record_installer_ref" \
    "! grep -qE '^record_(tool|installer)_ref\\(\\)' '$SRC_INSTALL'"
chk "无 ref_valid()" "! grep -q '^ref_valid()' '$SRC_INSTALL'"
chk "无 CLI_REF / ENV_REF 变量" "! grep -qE '^(CLI_REF|ENV_REF)=' '$SRC_INSTALL'"
chk "无 .installer-ref / .ref 写入" \
    "! grep -vE '^[[:space:]]*#' '$SRC_INSTALL' | grep -qE 'installer-ref|\\.ref\\b'"
chk "无 VPS_TOOLS_NO_TARBALL 开关" "! grep -q 'VPS_TOOLS_NO_TARBALL' '$SRC_INSTALL'"
chk "install_tool 无 curl 逐文件下载" \
    "! sed -n '/^install_tool()/,/^}/p' '$SRC_INSTALL' | grep -vE '^[[:space:]]*#' | grep -q 'curl '"
chk "版本已升到 ≥1.20.0" \
    "grep -qE '^VPS_TOOLS_VERSION=\"1\\.(2[0-9]|[3-9][0-9])\\.[0-9]+\"' '$SRC_INSTALL'"

echo
echo "==================================="
echo " PASS=$PASS FAIL=$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
