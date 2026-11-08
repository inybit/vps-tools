#!/usr/bin/env bash
# ============================================================
# 共享核心 lib/core.sh 的跨目录安装回归（mock curl，离线可跑，无需 root/网络）
#
# 背景（2026-10-19）：安装器 1.16.0 的注册表用 `源路径:目标相对路径` 把仓库根
#   lib/core.sh 装进每个工具目录。v1.20.0 起（整包快照唯一路径 + 移除 --ref）
#   只剩两个必须守住的行为：
#     ① 共享文件必须装进 <工具>/lib/，否则装完 source 缺文件 → 启动即崩
#     ② 任何一步失败都不得破坏现有安装（旧实现先 rm -rf 旧树再 mv，
#        共享文件失败时既无回滚又留下缺文件的坏安装）
#
# 覆盖：整包路径 × {完整树, 缺共享文件, 无共享条目}
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

# ---------- mock curl：只服务整包 tarball（v1.20.0 起没有逐文件路径） ----------
cat > "$MOCK/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$MOCK_CURL_LOG"
url=""; out=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
[[ "$url" == *"/tar.gz/"* ]] || { echo "curl: (22) 404 $url" >&2; exit 22; }
src="$MOCK_TG/$(basename "${url##*/}").tgz"
[[ -f "$src" ]] || { echo "curl: (22) 404 $url" >&2; exit 22; }
if [[ -n "$out" ]]; then cp "$src" "$out"; else cat "$src"; fi
STUB
chmod +x "$MOCK/curl"
export MOCK_CURL_LOG="$LOG" MOCK_TG="$TG"
export PATH="$MOCK:$PATH"

# ---------- 沙箱 install.sh：改路径 + 短路 root 判定 + 换成一个合成工具 ----------
# v1.20.0 解耦后，第 6 字段只写跨目录共享文件（工具目录内 lib 靠整包整拷）
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
       '  "mocktool|utils/mocktool/mocktool.sh|||install|lib/core.sh:lib/core.sh"\n'
       '  "noshare|utils/noshare/noshare.sh|||install|"\n'
       ')\n')
s, n = re.subn(r'^TOOLS=\(.*?^\)\n', reg, s, flags=re.S | re.M)
assert n == 1, "TOOLS 块替换失败"
open(dst, "w", encoding="utf-8").write(s)
PY
chmod +x "$T/install.sh"

# ---------- 整包树：full（有 core）/ broken（引用 core 但缺文件） ----------
mktree() {  # $1=名字 $2=full|broken
  local name="$1" mode="$2" d="$RT/$1"
  mkdir -p "$d/utils/mocktool/lib" "$d/utils/noshare" "$d/lib"
  printf '#!/usr/bin/env bash\necho "mocktool %s $*"\n' "$name" > "$d/utils/mocktool/mocktool.sh"
  printf 'MOCK_COMMON_VERSION="%s"\n' "$name" > "$d/utils/mocktool/lib/common.sh"
  printf 'MOCK_HELPER="%s"\n' "$name" > "$d/utils/mocktool/lib/helper.sh"
  echo '. "${BASH_SOURCE[0]%/*}/core.sh"' >> "$d/utils/mocktool/lib/common.sh"
  printf '#!/usr/bin/env bash\necho "noshare %s $*"\n' "$name" > "$d/utils/noshare/noshare.sh"
  if [[ "$mode" == full ]]; then
    printf '# 共享核心\ncore_marker="%s"\n' "$name" > "$d/lib/core.sh"
  fi
  # 对应 tarball（顶层目录 vps-tools-main/，必须含 install.sh 才被认作合法整包）
  local tx="$T/tgx-$name"
  rm -rf "$tx"; mkdir -p "$tx/vps-tools-main"
  cp -a "$d/." "$tx/vps-tools-main/"
  cp "$T/install.sh" "$tx/vps-tools-main/install.sh"
  tar -czf "$TG/$name.tgz" -C "$tx" vps-tools-main
}
mktree full full
mktree broken broken
# 让 mock curl 按 tarball 文件名取包：安装器请求的是 .../tar.gz/main
cp "$TG/full.tgz" "$TG/main.tgz"

DEST="$SANDBOX/lib/mocktool"
run(){ bash "$T/install.sh" "$@" > "$T/out" 2>&1; echo $?; }
nfiles(){ find "$DEST" -type f 2>/dev/null | wc -l | tr -d ' '; }

echo "=== [A] 整包路径 · 完整树：共享 core 必须装进工具目录 ==="
: > "$LOG"
rc="$(run install mocktool)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "core.sh 已装到 <工具>/lib/" "[[ -f '$DEST/lib/core.sh' ]]"
chk "common.sh / helper.sh 都在" "[[ -f '$DEST/lib/common.sh' && -f '$DEST/lib/helper.sh' ]]"
chk "无 .new/.bak 残留" "[[ -z \"\$(ls -d '$DEST'.new '$DEST'.bak.* 2>/dev/null)\" ]]"
chk "整包只请求 1 次（无逐文件请求）" "[[ \$(grep -c 'codeload' '$LOG') -eq 1 ]]"

echo
echo "=== [B] 无共享条目的工具：正常安装，不多拷 core.sh ==="
rc="$(run install noshare)"
chk "退出码 0" "[[ '$rc' == '0' ]]"
chk "主脚本已装" "[[ -f '$SANDBOX/lib/noshare/noshare.sh' ]]"
chk "未塞入 core.sh" "[[ ! -e '$SANDBOX/lib/noshare/lib/core.sh' ]]"

echo
echo "=== [C] 整包缺共享文件：失败且不动现有安装 ==="
# shellcheck disable=SC2034  # before/nbefore 在 chk 的 eval 字符串里使用
before="$(cat "$DEST/lib/common.sh")"; nbefore="$(nfiles)"
cp "$TG/broken.tgz" "$TG/main.tgz"
rc="$(run install mocktool)"
chk "退出码非 0" "[[ '$rc' != '0' ]]"
chk "错误信息点名缺的共享文件" "grep -q '整包缺共享文件' '$T/out'"
chk "现有安装未被破坏" "[[ \"\$(cat '$DEST/lib/common.sh')\" == \"\$before\" ]]"
chk "文件数未变" "[[ \"\$(find '$DEST' -type f | wc -l | tr -d ' ')\" == '$nbefore' ]]"
chk "无 .new/.bak 残留" "[[ -z \"\$(ls -d '$DEST'.new '$DEST'.bak.* 2>/dev/null)\" ]]"

echo
echo "==================================="
echo " PASS=${PASS} FAIL=${FAIL}"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
