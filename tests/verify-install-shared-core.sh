#!/usr/bin/env bash
# ============================================================
# 共享核心 lib/core.sh 的跨目录安装回归（mock curl，离线可跑，无需 root/网络）
#
# 背景（2026-10-19）：安装器 1.16.0 的注册表用 `源路径:目标相对路径` 把仓库根
#   lib/core.sh 装进每个工具目录。由此产生两个必须守住的行为：
#     ① 旧 ref（v1.15.0 及更早）根本没有 lib/ 目录，其 common.sh 也不 source
#        core —— 「按版本安装 / 回滚」到旧 tag 时必须跳过该文件，不能失败
#     ② 任何一步失败都不得破坏现有安装（旧实现先 rm -rf 旧树再 mv，
#        共享文件失败时既无回滚又留下缺文件的坏安装）
#
# 覆盖：整包快照路径 + 逐文件回退路径 × {新 ref, 旧 ref, 坏 ref}
#
# 用法: bash tests/verify-install-shared-core.sh
# 退出码: 0=全部通过
# ============================================================
set -uo pipefail
export LC_ALL=C

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_INSTALL="${REPO}/install.sh"
[[ -f "$SRC_INSTALL" ]] || { echo "SKIP: 找不到 install.sh"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
MOCK="$T/mock"; RT="$T/remote"; TG="$T/tgz"; SANDBOX="$T/sandbox"
mkdir -p "$MOCK" "$RT" "$TG" "$SANDBOX/bin" "$SANDBOX/etc" "$SANDBOX/lib"
LOG="$T/curl.log"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1  <<< $2"; }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

# ---------- mock curl：/tar.gz/<ref> → 本地 tarball；其余 → 远端文件树 ----------
cat > "$MOCK/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$MOCK_CURL_LOG"
url=""; out=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
if [[ "$url" == *"/tar.gz/"* ]]; then
  src="$MOCK_TG/${url##*/}.tgz"
else
  rel="${url#*inybit/vps-tools/}"
  ref="${rel%%/*}"; path="${rel#*/}"
  src="$MOCK_RT/$ref/$path"
fi
[[ -f "$src" ]] || { echo "curl: (22) 404 $url" >&2; exit 22; }
if [[ -n "$out" ]]; then cp "$src" "$out"; else cat "$src"; fi
STUB
chmod +x "$MOCK/curl"
export MOCK_CURL_LOG="$LOG" MOCK_RT="$RT" MOCK_TG="$TG"
export PATH="$MOCK:$PATH"

# ---------- 沙箱 install.sh：改路径 + 短路 root 判定 + 换成一个合成工具 ----------
python3 - "$SRC_INSTALL" "$T/install.sh" "$SANDBOX" <<'PY'
import re, sys
src, dst, sandbox = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(src, encoding="utf-8").read()
s = s.replace('INSTALL_DIR="/usr/local/lib/vps-tools"', f'INSTALL_DIR="{sandbox}/lib"')
s = s.replace('CMD_DIR="/usr/local/bin"', f'CMD_DIR="{sandbox}/bin"')
s = s.replace('CONFIG_DIR="/etc"', f'CONFIG_DIR="{sandbox}/etc"')
s = s.replace('[[ $EUID -eq 0 ]] || return 1', ':')
s = s.replace('if [[ $EUID -eq 0 ]]; then', 'if true; then')
s = s.replace('if [[ $EUID -ne 0 ]]; then', 'if false; then')
reg = ('TOOLS=(\n'
       '  "mocktool|utils/mocktool/mocktool.sh|||install|'
       'utils/mocktool/lib/common.sh utils/mocktool/lib/helper.sh lib/core.sh:lib/core.sh"\n'
       ')\n')
s, n = re.subn(r'^TOOLS=\(.*?^\)\n', reg, s, flags=re.S | re.M)
assert n == 1, "TOOLS 块替换失败"
open(dst, "w", encoding="utf-8").write(s)
PY
chmod +x "$T/install.sh"

# ---------- 远端树：old（无 core）/ new（有 core）/ broken（引用 core 但缺文件） ----------
mkref() {  # $1=ref $2=old|new|broken
  local ref="$1" mode="$2" d="$RT/$1"
  mkdir -p "$d/utils/mocktool/lib" "$d/lib"
  printf '#!/usr/bin/env bash\necho "mocktool %s $*"\n' "$ref" > "$d/utils/mocktool/mocktool.sh"
  printf 'MOCK_COMMON_VERSION="%s"\n' "$ref" > "$d/utils/mocktool/lib/common.sh"
  printf 'MOCK_HELPER="%s"\n' "$ref" > "$d/utils/mocktool/lib/helper.sh"
  if [[ "$mode" == old ]]; then
    echo '# 旧 ref：不 source core' >> "$d/utils/mocktool/lib/common.sh"
  else
    echo '. "${BASH_SOURCE[0]%/*}/core.sh"' >> "$d/utils/mocktool/lib/common.sh"
  fi
  if [[ "$mode" == new ]]; then
    printf '# 共享核心（新 ref 才有）\ncore_marker="%s"\n' "$ref" > "$d/lib/core.sh"
  fi
  # 对应 tarball（顶层目录 <repo>-<ref>/，必须含 install.sh 才被认作合法整包）
  local tx="$T/tgx-$ref"
  rm -rf "$tx"; mkdir -p "$tx/vps-tools-$ref"
  cp -a "$d/." "$tx/vps-tools-$ref/"
  cp "$T/install.sh" "$tx/vps-tools-$ref/install.sh"
  tar -czf "$TG/$ref.tgz" -C "$tx" "vps-tools-$ref"
}
mkref v-new new
mkref v-old old
mkref v-broken broken

DEST="$SANDBOX/lib/mocktool"
run(){ bash "$T/install.sh" "$@" > "$T/out" 2>&1; echo $?; }
nfiles(){ find "$DEST" -type f 2>/dev/null | wc -l | tr -d ' '; }

echo "=== [A] 整包路径 · 新 ref：共享 core 必须装进工具目录 ==="
: > "$LOG"
rc="$(run install mocktool --ref v-new)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "core.sh 已装到 <工具>/lib/" "[[ -f '$DEST/lib/core.sh' ]]"
chk "common.sh / helper.sh 都在" "[[ -f '$DEST/lib/common.sh' && -f '$DEST/lib/helper.sh' ]]"
chk "无 .new/.bak 残留" "[[ -z \"\$(ls -d '$DEST'.new '$DEST'.bak.* 2>/dev/null)\" ]]"

echo
echo "=== [B] 整包路径 · 旧 ref（无 lib/core.sh）：跳过而不是失败 ==="
: > "$LOG"
rc="$(run install mocktool --ref v-old)"
chk "退出码 0（旧 tag 仍可安装/回滚）" "[[ '$rc' == '0' ]]"
chk "不装 core.sh" "[[ ! -e '$DEST/lib/core.sh' ]]"
chk "旧版文件已就位" "grep -q 'MOCK_COMMON_VERSION=\"v-old\"' '$DEST/lib/common.sh'"
chk "日志说明跳过原因" "grep -q '跳过共享文件' '$T/out'"

echo
echo "=== [C] 整包路径 · 坏 ref（引用 core 但整包缺文件）：失败且不动现有安装 ==="
# shellcheck disable=SC2034  # before/nbefore 在 chk 的 eval 字符串里使用
before="$(cat "$DEST/lib/common.sh")"; nbefore="$(nfiles)"
rc="$(run install mocktool --ref v-broken)"
chk "退出码非 0" "[[ '$rc' != '0' ]]"
chk "现有安装未被破坏" "[[ \"\$(cat '$DEST/lib/common.sh')\" == \"\$before\" ]]"
chk "文件数未变" "[[ \"\$(find '$DEST' -type f | wc -l | tr -d ' ')\" == '$nbefore' ]]"
chk "无 .new/.bak 残留" "[[ -z \"\$(ls -d '$DEST'.new '$DEST'.bak.* 2>/dev/null)\" ]]"

echo
echo "=== [D] 逐文件回退路径 · 旧 ref：跳过共享文件 ==="
: > "$LOG"
rc="$(VPS_TOOLS_NO_TARBALL=1 bash "$T/install.sh" install mocktool --ref v-old > "$T/out" 2>&1; echo $?)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "不装 core.sh" "[[ ! -e '$DEST/lib/core.sh' ]]"
chk "日志说明跳过原因" "grep -q '跳过共享文件' '$T/out'"
chk "确实走了逐文件路径（无 codeload 请求）" "! grep -q 'codeload' '$LOG'"

echo
echo "=== [E] 逐文件回退路径 · 坏 ref：失败且不动现有安装 ==="
# shellcheck disable=SC2034  # before/nbefore 在 chk 的 eval 字符串里使用
before="$(cat "$DEST/lib/common.sh")"; nbefore="$(nfiles)"
rc="$(VPS_TOOLS_NO_TARBALL=1 bash "$T/install.sh" install mocktool --ref v-broken > "$T/out" 2>&1; echo $?)"
chk "退出码非 0" "[[ '$rc' != '0' ]]"
chk "现有安装未被破坏" "[[ \"\$(cat '$DEST/lib/common.sh')\" == \"\$before\" ]]"
chk "文件数未变" "[[ \"\$(find '$DEST' -type f | wc -l | tr -d ' ')\" == '$nbefore' ]]"
chk "无 .new/.bak 残留" "[[ -z \"\$(ls -d '$DEST'.new '$DEST'.bak.* 2>/dev/null)\" ]]"

echo
echo "==================================="
echo " PASS=${PASS} FAIL=${FAIL}"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
