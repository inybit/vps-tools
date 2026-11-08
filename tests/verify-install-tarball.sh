#!/usr/bin/env bash
# ============================================================
# install.sh 整包快照（tarball）安装回归 —— mock curl，离线可跑，无需 root/网络
#
# 背景：逐文件下载的瓶颈是请求数 × RTT（每个 curl = 独立 TCP+TLS 连接）。
#       xray-deploy 要 28 次，200ms RTT 上光握手 ~17s。
#       改为一次拉 codeload 整包（~280KB）本地解包。
# v1.20.0 起整包是**唯一**安装路径：逐文件回退 / --ref 全部移除（2026-11-08）。
#
# 覆盖：
#   1) 装多文件工具 = 1 次 codeload 请求，工具目录整拷（lib 全在）
#   2) 一次运行内缓存：装第二个工具仍只 1 次 codeload
#   3) codeload 失败 → 非 0 + 明确逃生提示 + 现有安装未改动 + 不逐文件拉 raw
#   4) VPS_TOOLS_TARBALL_ROOT 手动注入 → 0 次网络请求也能装
#   5) 装完的树 == 整包的树（旧版本残留文件被清掉）
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
SRC_TREE="$T/src/vps-tools-main"
TGZ="$T/repo.tgz"
tar -czf "$TGZ" -C "$T/src" vps-tools-main

# ---------- mock curl：只服务 codeload 整包；任何 raw 请求都记日志并 404 ----------
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
echo "curl: (22) 404 $url" >&2; exit 22
STUB
chmod +x "$MOCK/curl"
export MOCK_CURL_LOG="$LOG" MOCK_TGZ="$TGZ"
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

# ⚠️ 整包里也要换成沙箱版 install.sh：install_self 会把它落成管理命令并 re-exec，
#    若整包里仍是原始版（真 /usr/local 路径），exec 出来的进程会写真实系统目录。
cp "$T/install.sh" "$SRC_TREE/install.sh"
tar -czf "$TGZ" -C "$T/src" vps-tools-main

run(){ bash "$T/install.sh" "$@" > "$T/out" 2>&1; echo $?; }
n_tgz(){ grep -c 'codeload.github.com' "$LOG" 2>/dev/null || true; }
n_raw(){ grep -c 'mock.invalid.*raw\|mock.invalid/vps-tools' "$LOG" 2>/dev/null || true; }
libn(){ ls "$SANDBOX/lib/$1/lib" 2>/dev/null | wc -l | tr -d ' '; }
# 期望 lib 数由**磁盘**推导（注册表已不再登记工具目录内文件）：
# 工具目录内 lib 数 + 跨目录共享的 lib/core.sh（装进 <工具>/lib/）
lib_expected(){  # $1=工具目录名（仓库内相对路径）
  local n core=0
  n="$(ls "$REPO/$1/lib"/*.sh 2>/dev/null | wc -l | tr -d ' ')"
  grep -q 'lib/core.sh:lib/core.sh' "$SRC_INSTALL" && core=1
  echo $((n + core))
}
XLIB="$(lib_expected proxy/xray-deploy)"
BLIB="$(lib_expected backup/vps-backup)"

echo "=== [1] 多文件工具：1 次整包请求，工具目录整拷 ==="
: > "$LOG"
rc="$(run install xray-deploy)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "整包请求恰好 1 次" "[[ \"\$(n_tgz)\" == '1' ]]"
chk "无 raw 逐文件请求" "[[ \"\$(n_raw)\" == '0' ]]"
chk "$XLIB 个 lib 全部落盘" "[[ \"\$(libn xray-deploy)\" == '$XLIB' ]]"
chk "主脚本可执行" "[[ -x '$SANDBOX/lib/xray-deploy/xray-deploy.sh' ]]"
chk "日志说明走的是整包" "grep -q '整包快照' '$T/out'"

echo
echo "=== [2] 装第二个工具：仍是 1 次整包请求（缓存命中）==="
: > "$LOG"
rc="$(run install vps-backup)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "整包请求 1 次" "[[ \"\$(n_tgz)\" == '1' ]]"
chk "无 raw 逐文件请求" "[[ \"\$(n_raw)\" == '0' ]]"
chk "vps-backup lib 全部落盘（$BLIB 个）" "[[ \"\$(libn vps-backup)\" == '$BLIB' ]]"

echo
echo "=== [3] codeload 失败 → 非 0 + 逃生提示 + 不动现有安装 ==="
before="$(find "$SANDBOX/lib/xray-deploy" -type f | wc -l | tr -d ' ')"
: > "$LOG"
rc="$(MOCK_TARBALL_FAIL=1 bash "$T/install.sh" update xray-deploy > "$T/out" 2>&1; echo $?)"
chk "退出码非 0" "[[ '$rc' != '0' ]]"
chk "整包尝试过 1 次" "[[ \"\$(n_tgz)\" == '1' ]]"
chk "不再回退逐文件（0 次 raw）" "[[ \"\$(n_raw)\" == '0' ]]"
chk "提示 VPS_TOOLS_TARBALL_ROOT 逃生" "grep -q 'VPS_TOOLS_TARBALL_ROOT' '$T/out'"
chk "现有安装未改动" "[[ \"\$(find '$SANDBOX/lib/xray-deploy' -type f | wc -l | tr -d ' ')\" == '$before' ]]"

echo
echo "=== [4] VPS_TOOLS_TARBALL_ROOT 手动注入 → 0 次网络请求也能装 ==="
rm -rf "$SANDBOX/lib/xray-deploy"
: > "$LOG"
rc="$(VPS_TOOLS_TARBALL_ROOT="$SRC_TREE" bash "$T/install.sh" install xray-deploy > "$T/out" 2>&1; echo $?)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "0 次 codeload 请求" "[[ \"\$(n_tgz)\" == '0' ]]"
chk "lib 全部落盘（$XLIB）" "[[ \"\$(libn xray-deploy)\" == '$XLIB' ]]"
chk "主脚本可执行" "[[ -x '$SANDBOX/lib/xray-deploy/xray-deploy.sh' ]]"

echo
echo "=== [5] 装完的树 == 整包的树（旧版本残留文件被清掉）==="
printf '#!/usr/bin/env bash\n# 旧版本遗留，应被清理\n' > "$SANDBOX/lib/xray-deploy/lib/stale-removed.sh"
: > "$LOG"
rc="$(run update xray-deploy)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "残留文件已清除" "[[ ! -f '$SANDBOX/lib/xray-deploy/lib/stale-removed.sh' ]]"
chk "lib 数仍为 $XLIB（未多也未少）" "[[ \"\$(libn xray-deploy)\" == '$XLIB' ]]"

echo
echo "=================================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[[ "$FAIL" -eq 0 ]]
