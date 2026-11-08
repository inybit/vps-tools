#!/usr/bin/env bash
# 复现 + 回归：install.sh 更新工具时漏装「新增的 lib 文件」
#
# 背景（2026-09-19 anthony_fr 实测）：
#   用户更新 xray-deploy 后运行报错
#     /usr/local/lib/vps-tools/xray-deploy/lib/xhttp3.sh: No such file or directory
#   现象：lib/ 下 25 个文件全是新版（mtime 一致），唯独缺本轮新增的 xhttp3.sh
#
# 两个独立缺陷：
#   【缺陷 1，anthony 实际命中】VPS_TOOLS_VERSION 未随 TOOLS 一起升版
#     → 已装副本 v1.8.0 == 远端 v1.8.0 → install_self 报「已是最新」→ 不下载
#     → 运行中的旧副本 TOOLS 清单永久陈旧
#   【缺陷 2，潜在】即使版本升了、install_self 把新 install.sh 落盘，
#     **当前进程的 TOOLS 数组不会重载**（bash 数组在启动时求值）
#     → 同一进程内接着 install_tool 仍用旧清单 → 依然漏装
#
# v1.20.0 起（整包快照是唯一安装路径）「漏装」的根已被拆掉：工具目录整拷，
# 新增 lib 不再需要登记注册表。本套件保留三个不变量：
#   [A] 版本相同但清单变了 → 必须继续更新（指纹兜底，别把用户钉死在旧清单）
#   [B] 自更新后同一进程内 TOOLS 必须重载（新清单立刻生效）
#   [C] 整包装出的 lib 与远端树一致（未登记的新增文件也到位）
#
# 用法: bash tests/verify-install-stale-tools-registry.sh
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO}/install.sh"
[[ -f "$SRC" ]] || { echo "SKIP: 找不到 install.sh"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
MOCK="$T/mock"; mkdir -p "$MOCK" "$T/usr/local/bin" "$T/root" "$T/etc"
LOG="$T/curl.log"
PASS=0; FAIL=0
ck(){ if [[ "$2" == "$3" ]]; then echo "  [PASS] $1"; PASS=$((PASS+1));
      else echo "  [FAIL] $1  期望=$3 实际=$2"; FAIL=$((FAIL+1)); fi; }

# ---------- 远端树：install.sh + xray-deploy（含一个「新增」lib）+ lib/core.sh + 新工具 ----------
REMOTE="$T/remote"; mkdir -p "$REMOTE/proxy" "$REMOTE/utils/newtool"
# ⚠️ 远端 install.sh 必须短路 EUID + 重定向路径：install_self 会把它下载覆盖到副本，
#    否则自更新后落盘的是「真 root 判定 + 真 /usr/local 路径」版本（本次踩过）
python3 - "$SRC" "$REMOTE/install.sh" "$T" <<'PYR'
import sys
src, dst, t = sys.argv[1:4]
s = open(src, encoding='utf-8').read()
s = s.replace('INSTALL_DIR="/usr/local/lib/vps-tools"', f'INSTALL_DIR="{t}/root"')
s = s.replace('CMD_DIR="/usr/local/bin"', f'CMD_DIR="{t}/usr/local/bin"')
s = s.replace('CONFIG_DIR="/etc"', f'CONFIG_DIR="{t}/etc"')
s = s.replace('BASE_URL="${RAW_BASE}/${DEFAULT_REF}"', 'BASE_URL="https://x/vps-tools/main"')
s = s.replace('[[ $EUID -eq 0 ]] || return 1', ':')
s = s.replace('if [[ $EUID -eq 0 ]]; then', 'if true; then')
s = s.replace('if [[ $EUID -ne 0 ]]; then', 'if false; then')
open(dst, 'w', encoding='utf-8').write(s)
PYR
cp -a "${REPO}/proxy/xray-deploy" "$REMOTE/proxy/"
# 共享核心（注册表用 lib/core.sh:lib/core.sh 从仓库根取）也要在「远端」里
cp -a "${REPO}/lib" "$REMOTE/lib"
# 远端新增的 lib：注册表里**不登记**（整包整拷会自动带上）
printf 'XLIB_NEW="zz-new"\n' > "$REMOTE/proxy/xray-deploy/lib/zz-new.sh"
# 远端新增的工具（测「重载后新清单立刻生效」）
printf '#!/usr/bin/env bash\necho "newtool $*"\n' > "$REMOTE/utils/newtool/newtool.sh"
python3 - "$REMOTE/install.sh" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
line = '  "newtool|utils/newtool/newtool.sh|||install|"\n'
assert 'TOOLS=(' in s
s = s.replace(')\n', line + ')\n', 1)
open(p, 'w', encoding='utf-8').write(s)
PY
# 期望落盘 lib 数 = 工具目录内 lib 数 + 跨目录共享的 lib/core.sh（装进 <工具>/lib/）
XLIB_N="$(ls "$REMOTE/proxy/xray-deploy/lib"/*.sh | wc -l | tr -d ' ')"
grep -q 'lib/core.sh:lib/core.sh' "$REMOTE/install.sh" && XLIB_N=$((XLIB_N + 1))

# 整包 tgz（顶层 vps-tools-main/，必须含 install.sh 才被认作合法整包）
TG="$T/src.tgz"
mkdir -p "$T/tgx/vps-tools-main"; cp -a "$REMOTE/." "$T/tgx/vps-tools-main/"
tar -czf "$TG" -C "$T/tgx" vps-tools-main

# ---------- mock curl：整包走 tgz，其余只允许 install.sh ----------
cat > "$MOCK/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$MOCK_LOG"
out=""; url=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
if [[ "$url" == *"/tar.gz/"* ]]; then
  if [[ -n "$out" ]]; then cp "$MOCK_TG" "$out"; else cat "$MOCK_TG"; fi
  exit 0
fi
[[ "$url" == */install.sh ]] || { echo "curl: (22) 404 $url" >&2; exit 22; }
if [[ -n "$out" ]]; then cp "$MOCK_REMOTE/install.sh" "$out"; else cat "$MOCK_REMOTE/install.sh"; fi
STUB
chmod +x "$MOCK/curl"
export MOCK_LOG="$LOG" MOCK_TG="$TG" MOCK_REMOTE="$REMOTE"
export PATH="$MOCK:$PATH"

# ---------- 已装副本：可指定版本 / 是否含新工具（制造清单差异） ----------
mk_copy() {  # $1=版本 $2=目标 $3=含newtool(yes/no)
  python3 - "$REMOTE/install.sh" "$2" "$1" "$3" <<'PY'
import re, sys
src, dst, ver, has = sys.argv[1:5]
s = open(src, encoding='utf-8').read()
if has == 'no':
    s2 = '\n'.join(l for l in s.split('\n') if not l.strip().startswith('"newtool|'))
    assert s2 != s, "未能移除 newtool 注册行"
    s = s2
s = re.sub(r'^VPS_TOOLS_VERSION="[^"]*"', f'VPS_TOOLS_VERSION="{ver}"', s, count=1, flags=re.M)
open(dst, 'w', encoding='utf-8').write(s)
PY
  chmod +x "$2"
}
vof(){ grep -m1 '^VPS_TOOLS_VERSION=' "$1" | cut -d'"' -f2; }
has_tool(){ grep -c '^  "newtool|' "$1"; }

echo "=== 前置：远端清单比本地副本多一个工具（版本号先保持一致）==="
mk_copy "1.8.0" "$T/usr/local/bin/vps-tools" "no"
ck "副本清单无 newtool" "$(has_tool "$T/usr/local/bin/vps-tools")" "0"
ck "远端清单有 newtool" "$(has_tool "$REMOTE/install.sh")" "1"
sed -i 's/^VPS_TOOLS_VERSION="[^"]*"/VPS_TOOLS_VERSION="1.8.0"/' "$REMOTE/install.sh"

echo
echo "=== [A] 缺陷 1 回归：版本相同但清单变了 → 必须继续更新 ==="
: > "$LOG"
"$T/usr/local/bin/vps-tools" install xray-deploy > "$T/o1" 2>&1 || true
echo "  输出:"; grep -E "已是最新|已更新|已安装|清单已变更" "$T/o1" | head -4 | sed 's/^/    /'
ck "检测到清单变更并给出提示" "$(grep -c '远端工具清单已变更' "$T/o1")" "1"
ck "确实拉取了远端 install.sh" "$([[ $(grep -c 'install.sh' "$LOG") -ge 1 ]] && echo yes)" "yes"
ck "副本清单已刷到远端（含 newtool）" "$(has_tool "$T/usr/local/bin/vps-tools")" "1"

echo
echo "=== [B] 缺陷 2 回归：自更新后同一进程内 TOOLS 必须重载 ==="
mk_copy "1.7.0" "$T/usr/local/bin/vps-tools" "no"
sed -i 's/^VPS_TOOLS_VERSION="[^"]*"/VPS_TOOLS_VERSION="1.9.0"/' "$REMOTE/install.sh"
: > "$LOG"
# 菜单：5=自更新，2=更新工具，2=xray-deploy（同一进程内！）
printf '5\n2\n2\n0\n' | "$T/usr/local/bin/vps-tools" > "$T/o2" 2>&1 || true
echo "  输出:"; grep -E "已更新管理命令|已安装|未知工具" "$T/o2" | head -4 | sed 's/^/    /'
ck "自更新确实落盘到新版本" "$(vof "$T/usr/local/bin/vps-tools")" "1.9.0"
ck "磁盘副本清单已含 newtool" "$(has_tool "$T/usr/local/bin/vps-tools")" "1"
ck "重载后新清单生效（未报未知工具）" "$(grep -c '未知工具' "$T/o2")" "0"

echo
echo "=== [C] 整包整拷：远端新增 lib（注册表未登记）也必须到位 ==="
LIBD="$T/root/xray-deploy/lib"
ck "主脚本已装" "$([[ -f "$T/root/xray-deploy/xray-deploy.sh" ]] && echo yes || echo no)" "yes"
ck "lib 文件数与远端树一致（$XLIB_N）" "$(ls "$LIBD"/*.sh 2>/dev/null | wc -l | tr -d ' ')" "$XLIB_N"
ck "未登记的新增 lib 也在（zz-new.sh）" "$([[ -f "$LIBD/zz-new.sh" ]] && echo present || echo missing)" "present"
crash="$(bash "$T/root/xray-deploy/xray-deploy.sh" -v 2>&1)"
echo "  运行 -v 的实际输出: $(head -1 <<<"$crash")"
ck "工具可正常启动" "$(grep -c '^xray-deploy 1' <<<"$crash")" "1"

echo
echo "==================================="
echo " PASS=$PASS FAIL=$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
