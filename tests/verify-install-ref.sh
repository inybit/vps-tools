#!/usr/bin/env bash
# ============================================================
# install.sh 版本坐标（--ref）回归 —— mock curl，离线可跑，无需 root/网络
#
# 覆盖：发布模型落地后「按 tag 安装 / 版本固定 / 回滚 / 非法 ref 拒绝」。
#   1) install <tool> --ref <tag>  → 从该 tag 下载，并记录 .ref
#   2) update <tool>（不带 --ref） → 沿用记录的 tag（版本固定，不会被悄悄拉回 main）
#   3) update <tool> --ref main    → 回到最新，记录同步更新
#   4) VPS_TOOLS_REF=<tag>         → 优先级高于已装记录（全局覆盖）
#   5) 非法 ref                    → 拒绝且不发起任何下载
#   6) install --ref <tag>         → 不得连带改动安装器自身的 ref
#   7) self-update --ref <旧 tag>  → 允许降级（显式回滚）；普通 self-update 仍防降级
#
# 用法: bash tests/verify-install-ref.sh
# 期望: PASS=n FAIL=0
# ============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_INSTALL="${REPO}/install.sh"
[[ -f "$SRC_INSTALL" ]] || { echo "SKIP: 找不到 install.sh"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
MOCK="$T/mock"; RT="$T/remote"; LOG="$T/curl.log"
mkdir -p "$MOCK" "$RT"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1  <<< $2"; }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

# ---------- mock curl：按 URL 里的 <ref>/<path> 从「远端树」取文件 ----------
cat > "$MOCK/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$MOCK_CURL_LOG"
url=""; out=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
rel="${url#${MOCK_RAW_BASE}/}"
[[ "$rel" == "$url" ]] && { echo "curl: (3) bad url: $url" >&2; exit 3; }
ref="${rel%%/*}"; path="${rel#*/}"
src="$MOCK_RT/$ref/$path"
[[ -f "$src" ]] || { echo "curl: (22) 404 $ref/$path" >&2; exit 22; }
if [[ -n "$out" ]]; then cp "$src" "$out"; else cat "$src"; fi
STUB
chmod +x "$MOCK/curl"
export MOCK_CURL_LOG="$LOG" MOCK_RT="$RT" MOCK_RAW_BASE="http://mock.invalid/inybit/vps-tools"
export PATH="$MOCK:$PATH"

# ---------- 沙箱 install.sh（远端树里的 install.sh 也必须沙箱化： ----------
# ---------- install_self 会把它下载覆盖到已装副本，未沙箱化会写出真路径/真 root 判定） ----------
SANDBOX="$T/sandbox"; mkdir -p "$SANDBOX/bin" "$SANDBOX/etc" "$SANDBOX/lib"
sandboxize() {  # $1=源 $2=目标
  sed -e 's|^GH_ORIGIN=.*|GH_ORIGIN="http://mock.invalid"|' \
      -e "s|INSTALL_DIR=\"/usr/local/lib/vps-tools\"|INSTALL_DIR=\"$SANDBOX/lib\"|" \
      -e "s|CMD_DIR=\"/usr/local/bin\"|CMD_DIR=\"$SANDBOX/bin\"|" \
      -e "s|CONFIG_DIR=\"/etc\"|CONFIG_DIR=\"$SANDBOX/etc\"|" "$1" > "$2"
  # EUID 是 bash 只读变量，只能改判定表达式（本机非 root）
  sed -i -e 's|\[\[ \$EUID -eq 0 \]\] \|\| return 1|:|g' \
         -e 's|if \[\[ \$EUID -eq 0 \]\]; then|if true; then|g' \
         -e 's|if \[\[ \$EUID -ne 0 \]\]; then|if false; then|g' "$2"
  chmod +x "$2"
}

# ---------- 远端树：每个 ref 一棵 ----------
mkremote() {  # $1=ref $2=installer 版本
  local r="$RT/$1"
  mkdir -p "$r/monitor/vnstat-monitor"
  sed "s/^VPS_TOOLS_VERSION=\"[^\"]*\"/VPS_TOOLS_VERSION=\"$2\"/" "$SRC_INSTALL" > "$T/.ri.tmp"
  sandboxize "$T/.ri.tmp" "$r/install.sh"
  printf '#!/usr/bin/env bash\nVERSION="1.1.2"\necho vnstat-monitor "$*"\n' \
    > "$r/monitor/vnstat-monitor/vnstat-monitor.sh"
  printf 'MOCK_KEY="${PLACEHOLDER}"\n' > "$r/monitor/vnstat-monitor/vnstat-monitor.env.example"
}
mkremote main 9.9.9
mkremote vnstat-monitor-v1.1.2 9.9.9
mkremote v1.0.0 1.0.0

sandboxize "$SRC_INSTALL" "$T/install.sh"

run(){ bash "$T/install.sh" "$@" > "$T/out" 2>&1; echo $?; }
refof(){ head -1 "$SANDBOX/lib/$1/.ref" 2>/dev/null || true; }
iref(){ head -1 "$SANDBOX/lib/.installer-ref" 2>/dev/null || true; }
vof(){ sed -n 's/^VPS_TOOLS_VERSION="\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1; }

echo "=== [1] install --ref <tag>：从 tag 下载并记录 ==="
: > "$LOG"
rc="$(run install vnstat-monitor --ref vnstat-monitor-v1.1.2)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "主脚本 URL 指向该 tag" "grep -q 'vps-tools/vnstat-monitor-v1.1.2/monitor/vnstat-monitor/vnstat-monitor.sh' '$LOG'"
chk "配置模板同样走该 tag" "grep -q 'vps-tools/vnstat-monitor-v1.1.2/monitor/vnstat-monitor/vnstat-monitor.env.example' '$LOG'"
chk ".ref 记录该 tag" "[[ \"\$(refof vnstat-monitor)\" == 'vnstat-monitor-v1.1.2' ]]"
chk "脚本已落盘" "[[ -x '$SANDBOX/lib/vnstat-monitor/vnstat-monitor.sh' ]]"

echo
echo "=== [2] update（不带 --ref）沿用记录 = 版本固定 ==="
: > "$LOG"
rc="$(run update vnstat-monitor)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "仍从记录的 tag 下载（未被拉回 main）" "grep -q 'vnstat-monitor-v1.1.2/monitor' '$LOG' && ! grep -q 'vps-tools/main/monitor' '$LOG'"
chk ".ref 未被改写" "[[ \"\$(refof vnstat-monitor)\" == 'vnstat-monitor-v1.1.2' ]]"

echo
echo "=== [3] update --ref main：回到最新 ==="
: > "$LOG"
rc="$(run update vnstat-monitor --ref main)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "URL 指向 main" "grep -q 'vps-tools/main/monitor/vnstat-monitor/vnstat-monitor.sh' '$LOG'"
chk ".ref 更新为 main" "[[ \"\$(refof vnstat-monitor)\" == 'main' ]]"

echo
echo "=== [4] VPS_TOOLS_REF 优先级高于已装记录 ==="
: > "$LOG"
rc="$(VPS_TOOLS_REF=vnstat-monitor-v1.1.2 bash "$T/install.sh" install vnstat-monitor > "$T/out" 2>&1; echo $?)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "环境变量覆盖了记录的 main" "grep -q 'vnstat-monitor-v1.1.2/monitor' '$LOG'"

echo
echo "=== [5] 非法 ref：拒绝且不下载 ==="
: > "$LOG"
rc="$(run install vnstat-monitor --ref 'bad ref;rm -rf /')"
chk "非 0 退出" "[[ '$rc' != '0' ]]"
chk "给出非法 ref 提示" "grep -q '非法 ref' '$T/out'"
chk "未发起任何下载" "[[ ! -s '$LOG' ]]"

echo
echo "=== [6] install --ref 不得改动安装器自身 ref ==="
# [4] 用 VPS_TOOLS_REF 全局覆盖过，会把 .installer-ref 一起带走（符合设计），故先复位
printf 'main\n' > "$SANDBOX/lib/.installer-ref"
: > "$LOG"
rc="$(run install vnstat-monitor --ref vnstat-monitor-v1.1.2)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "安装器 ref 仍为 main（未被工具 tag 连带降级）" "[[ \"\$(iref)\" == 'main' ]]"
chk "install.sh 未被从工具 tag 拉取" "! grep -q 'vnstat-monitor-v1.1.2/install.sh' '$LOG'"

echo
echo "=== [7] self-update --ref <旧 tag>：显式允许降级 ==="
chk "前置：已装安装器为 9.9.9" "[[ \"\$(vof '$SANDBOX/bin/vps-tools')\" == '9.9.9' ]]"
: > "$LOG"
rc="$(run self-update --ref v1.0.0)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "确实降级到 1.0.0" "[[ \"\$(vof '$SANDBOX/bin/vps-tools')\" == '1.0.0' ]]"
chk "安装器 ref 记录为 v1.0.0（pin 生效）" "[[ \"\$(iref)\" == 'v1.0.0' ]]"
chk "URL 指向该 tag" "grep -q 'vps-tools/v1.0.0/install.sh' '$LOG'"

echo
echo "=== [8] 普通 self-update 仍防降级（未被 [7] 破坏） ==="
# ⚠️ 必须运行「已装副本」而非沙箱源：防降级比的是**正在运行的脚本**版本
#    （self_running_version），跑源文件测的是源版本，与已装版本无关。
# 已装副本必须是完整的沙箱 install.sh（只有版本号不同的两行脚本不会执行 main）。
sed 's/^VPS_TOOLS_VERSION="[^"]*"/VPS_TOOLS_VERSION="99.0.0"/' "$T/install.sh" > "$SANDBOX/bin/vps-tools"
chmod +x "$SANDBOX/bin/vps-tools"
printf 'main\n' > "$SANDBOX/lib/.installer-ref"
: > "$LOG"
"$SANDBOX/bin/vps-tools" self-update > "$T/out" 2>&1 || true
chk "未覆盖本机更高版本" "[[ \"\$(vof '$SANDBOX/bin/vps-tools')\" == '99.0.0' ]]"
chk "给出跳过原因" "grep -q '高于远端' '$T/out'"

echo
echo "=== [9] list 展示已装版本与 ref ==="
printf '#!/usr/bin/env bash\nVERSION="1.1.2"\n' > "$SANDBOX/lib/vnstat-monitor/vnstat-monitor.sh"
printf 'vnstat-monitor-v1.1.2\n' > "$SANDBOX/lib/vnstat-monitor/.ref"
bash "$T/install.sh" list > "$T/out" 2>&1
chk "显示已装版本" "grep -q 'vnstat-monitor.*已装 v1.1.2' '$T/out'"
chk "显示 ref" "grep -q '@vnstat-monitor-v1.1.2' '$T/out'"

echo
echo "=================================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[[ "$FAIL" -eq 0 ]]
