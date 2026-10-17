#!/usr/bin/env bash
# ============================================================
# install.sh 整包快照（tarball）下载回归 —— mock curl，离线可跑，无需 root/网络
#
# 背景：逐文件下载的瓶颈是请求数 × RTT（每个 curl = 独立 TCP+TLS 连接）。
#       xray-deploy 要 28 次，200ms RTT 上光握手 ~17s。
#       改为一次拉 codeload 整包（~280KB）本地解包。
#
# 覆盖：
#   1) 装多文件工具 = 1 次 codeload 请求，且不再逐文件拉 raw
#   2) 一次运行内按 ref 缓存：装第二个工具仍是 1 次（install_self 也复用）
#   3) VPS_TOOLS_NO_TARBALL=1 → 0 次 codeload，走逐文件
#   4) codeload 失败 → 自动回退逐文件，安装结果仍完整
#   5) 装完的树 == 该 ref 的树（旧版本残留文件被清掉）
#
# 用法: bash tests/verify-install-tarball.sh
# 期望: PASS=n FAIL=0
# ============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_INSTALL="${REPO}/install.sh"
[[ -f "$SRC_INSTALL" ]] || { echo "SKIP: 找不到 install.sh"; exit 0; }
command -v tar >/dev/null 2>&1 || { echo "SKIP: 无 tar"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
MOCK="$T/mock"; LOG="$T/curl.log"
SANDBOX="$T/sandbox"; mkdir -p "$MOCK" "$SANDBOX/bin" "$SANDBOX/etc" "$SANDBOX/lib"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1  <<< $2"; }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

# ---------- 构造「远端整包」：仓库快照，顶层单目录 vps-tools-main/ ----------
mkdir -p "$T/src"
cp -a "$REPO" "$T/src/vps-tools-main"
rm -rf "$T/src/vps-tools-main/.git"
TGZ="$T/repo.tgz"
tar -czf "$TGZ" -C "$T/src" vps-tools-main
SRC_TREE="$T/src/vps-tools-main"

# ---------- mock curl ----------
cat > "$MOCK/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$MOCK_CURL_LOG"
url=""; out=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
if [[ "$url" == *codeload.github.com* ]]; then
  [[ "${MOCK_TARBALL_FAIL:-0}" == "1" ]] && { echo "curl: (22) 404" >&2; exit 22; }
  cp "$MOCK_TGZ" "$out"; exit 0
fi
rel="${url#${MOCK_RAW_BASE}/}"
[[ "$rel" == "$url" ]] && { echo "curl: (3) bad url: $url" >&2; exit 3; }
path="${rel#*/}"
src="$MOCK_SRC/$path"
[[ -f "$src" ]] || { echo "curl: (22) 404 $path" >&2; exit 22; }
if [[ -n "$out" ]]; then cp "$src" "$out"; else cat "$src"; fi
STUB
chmod +x "$MOCK/curl"
export MOCK_CURL_LOG="$LOG" MOCK_TGZ="$TGZ" MOCK_SRC="$SRC_TREE" \
       MOCK_RAW_BASE="http://mock.invalid/inybit/vps-tools"
export PATH="$MOCK:$PATH"

# ---------- 沙箱 install.sh（真路径/真 root 判定都要短路） ----------
sed -e 's|^GH_ORIGIN=.*|GH_ORIGIN="http://mock.invalid"|' \
    -e "s|INSTALL_DIR=\"/usr/local/lib/vps-tools\"|INSTALL_DIR=\"$SANDBOX/lib\"|" \
    -e "s|CMD_DIR=\"/usr/local/bin\"|CMD_DIR=\"$SANDBOX/bin\"|" \
    -e "s|CONFIG_DIR=\"/etc\"|CONFIG_DIR=\"$SANDBOX/etc\"|" \
    "$SRC_INSTALL" > "$T/install.sh"
sed -i -e 's|\[\[ \$EUID -eq 0 \]\] \|\| return 1|:|g' \
       -e 's|if \[\[ \$EUID -eq 0 \]\]; then|if true; then|g' \
       -e 's|if \[\[ \$EUID -ne 0 \]\]; then|if false; then|g' "$T/install.sh"
chmod +x "$T/install.sh"

run(){ bash "$T/install.sh" "$@" > "$T/out" 2>&1; echo $?; }
n_tgz(){ grep -c 'codeload.github.com' "$LOG" 2>/dev/null || true; }
# 逐文件 raw 请求：测试里 GH_ORIGIN 被改成 mock.invalid，故按它计数
n_raw(){ grep -c 'mock.invalid' "$LOG" 2>/dev/null || true; }
libn(){ ls "$SANDBOX/lib/$1/lib" 2>/dev/null | wc -l; }

echo "=== [1] 多文件工具：1 次整包请求，不再逐文件拉 raw ==="
: > "$LOG"
rc="$(run install xray-deploy)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "整包请求恰好 1 次" "[[ \"\$(n_tgz)\" == '1' ]]"
chk "未逐文件拉 xray-deploy 的 raw 文件" "[[ \"\$(grep -c 'mock.invalid.*proxy/xray-deploy' '$LOG')\" == '0' ]]"
chk "27 个 lib 全部落盘" "[[ \"\$(libn xray-deploy)\" == '27' ]]"
chk "主脚本可执行" "[[ -x '$SANDBOX/lib/xray-deploy/xray-deploy.sh' ]]"
chk "日志说明走的是整包" "grep -q '整包快照' '$T/out'"

echo
echo "=== [2] 装第二个工具：仍是 1 次整包请求（没有退回逐文件）==="
: > "$LOG"
rc="$(run install vps-backup)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "整包请求 1 次" "[[ \"\$(n_tgz)\" == '1' ]]"
chk "未逐文件拉 vps-backup 的 raw 文件" "[[ \"\$(grep -c 'mock.invalid.*backup/vps-backup' '$LOG')\" == '0' ]]"
chk "vps-backup lib 全部落盘（16 个）" "[[ \"\$(libn vps-backup)\" == '16' ]]"
# 关键：install 动作里 install_self 与 install_tool 共用同一份整包 → 合计只能 1 次。
# 若缓存失效，这里会是 2 次（install_self 一次 + install_tool 一次）。

echo
echo "=== [3] VPS_TOOLS_NO_TARBALL=1 → 完全不碰 codeload ==="
: > "$LOG"
rc="$(VPS_TOOLS_NO_TARBALL=1 bash "$T/install.sh" update xray-deploy > "$T/out" 2>&1; echo $?)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "0 次整包请求" "[[ \"\$(n_tgz)\" == '0' ]]"
chk "改为逐文件拉 raw（27+1 次）" "[[ \"\$(n_raw)\" -ge 27 ]]"
chk "lib 仍完整" "[[ \"\$(libn xray-deploy)\" == '27' ]]"

echo
echo "=== [4] codeload 失败 → 自动回退逐文件，结果仍完整 ==="
: > "$LOG"
rc="$(MOCK_TARBALL_FAIL=1 bash "$T/install.sh" update xray-deploy > "$T/out" 2>&1; echo $?)"
chk "退出码 0（回退成功）" "[[ '$rc' == '0' ]]"
chk "整包尝试过 1 次" "[[ \"\$(n_tgz)\" == '1' ]]"
chk "给出回退告警" "grep -q '回退逐文件下载' '$T/out'"
chk "lib 仍完整（27）" "[[ \"\$(libn xray-deploy)\" == '27' ]]"
chk "主脚本可执行" "[[ -x '$SANDBOX/lib/xray-deploy/xray-deploy.sh' ]]"

echo
echo "=== [5] 装完的树 == 该 ref 的树（旧版本残留文件被清掉）==="
printf '#!/usr/bin/env bash\n# 旧版本遗留，应被清理\n' > "$SANDBOX/lib/xray-deploy/lib/stale-removed.sh"
: > "$LOG"
rc="$(run update xray-deploy)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "残留文件已清除" "[[ ! -f '$SANDBOX/lib/xray-deploy/lib/stale-removed.sh' ]]"
chk "lib 数仍为 27（未多也未少）" "[[ \"\$(libn xray-deploy)\" == '27' ]]"

echo
echo "=================================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[[ "$FAIL" -eq 0 ]]
