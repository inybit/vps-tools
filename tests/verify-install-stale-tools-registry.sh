#!/usr/bin/env bash
# 复现 + 回归：install.sh 更新工具时漏装「新增的 lib 文件」
#
# 背景（2026-09-19 anthony_fr 实测）：
#   用户更新 xray-deploy 后运行报错
#     /usr/local/lib/vps-tools/xray-deploy/lib/xhttp3.sh: No such file or directory
#   现象：lib/ 下 25 个文件全是新版（mtime 一致），唯独缺本轮新增的 xhttp3.sh
#        （新协议注册了、VERSION=1.9.0、入口也 source 了它 → 必然启动即崩）
#
# 两个独立缺陷：
#   【缺陷 1，anthony 实际命中】VPS_TOOLS_VERSION 未随 TOOLS 一起升版
#     → 已装副本 v1.8.0 == 远端 v1.8.0 → install_self 报「已是最新」→ 不下载
#     → 运行中的旧副本 TOOLS 清单永久陈旧
#   【缺陷 2，潜在】即使版本升了、install_self 把新 install.sh 落盘，
#     **当前进程的 TOOLS 数组不会重载**（bash 数组在启动时求值）
#     → 同一进程内接着 install_tool 仍用旧清单 → 依然漏装
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

# ---------- mock curl：从「远端目录」按 URL 路径取文件 ----------
cat > "$MOCK/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$MOCK_LOG"
url=""; out=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
rel="${url#*vps-tools/main/}"
src="${REMOTE_DIR}/${rel}"
[[ -f "$src" ]] || { echo "curl: (22) 404 $rel" >&2; exit 22; }
if [[ -n "$out" ]]; then cp "$src" "$out"; else cat "$src"; fi
STUB
chmod +x "$MOCK/curl"
export MOCK_LOG="$LOG" PATH="$MOCK:$PATH"

# ---------- 「远端」= 当前工作区快照（含 xhttp3.sh）----------
REMOTE="$T/remote"; mkdir -p "$REMOTE/proxy"
# ⚠️ 远端 install.sh 也要短路 EUID + 重定向路径：install_self 会把它下载覆盖到副本，
#    若不自此处理，自更新后落盘的是「真 root 判定 + 真 /usr/local 路径」版本，
#    后续 update 会因非 root 直接退出（本次踩过）
python3 - "$SRC" "$REMOTE/install.sh" "$T" <<'PYR'
import sys
src,dst,t=sys.argv[1:4]
s=open(src,encoding='utf-8').read()
s=s.replace('INSTALL_DIR="/usr/local/lib/vps-tools"', f'INSTALL_DIR="{t}/root"')
s=s.replace('CMD_DIR="/usr/local/bin"', f'CMD_DIR="{t}/usr/local/bin"')
s=s.replace('CONFIG_DIR="/etc"', f'CONFIG_DIR="{t}/etc"')
s=s.replace('BASE_URL="https://raw.githubusercontent.com/inybit/vps-tools/main"', 'BASE_URL="https://x/vps-tools/main"')
s=s.replace('[[ $EUID -eq 0 ]] || return 1', ':')
s=s.replace('if [[ $EUID -eq 0 ]]; then', 'if true; then')
s=s.replace('if [[ $EUID -ne 0 ]]; then', 'if false; then')
open(dst,'w',encoding='utf-8').write(s)
PYR
cp -r "${REPO}/proxy/xray-deploy" "$REMOTE/proxy/"
export REMOTE_DIR="$REMOTE"

# ---------- 生成一个「已装副本」：可指定版本 / 是否含新文件 ----------
mk_copy() {  # $1=版本 $2=目标 $3=含xhttp3(yes/no)
  python3 - "$SRC" "$2" "$1" "$3" <<'PY'
import sys
src,dst,ver,has=sys.argv[1:5]
s=open(src,encoding='utf-8').read()
if has=='no':
    s2=s.replace(" proxy/xray-deploy/lib/xhttp3.sh","")
    assert s2!=s, "未能移除 xhttp3.sh"
    s=s2
import re
s=re.sub(r'^VPS_TOOLS_VERSION="[^"]*"', f'VPS_TOOLS_VERSION="{ver}"', s, count=1, flags=re.M)
# 重定向到临时路径（不改被测逻辑）
s=s.replace('INSTALL_DIR="/usr/local/lib/vps-tools"', 'INSTALL_DIR="__T__/root"')
s=s.replace('CMD_DIR="/usr/local/bin"', 'CMD_DIR="__T__/usr/local/bin"')
s=s.replace('CONFIG_DIR="/etc"', 'CONFIG_DIR="__T__/etc"')
s=s.replace('BASE_URL="https://raw.githubusercontent.com/inybit/vps-tools/main"', 'BASE_URL="https://x/vps-tools/main"')
# ⚠️ 必须短路 EUID 判定：本机非 root，否则测的是权限而非版本/清单逻辑
s=s.replace('[[ $EUID -eq 0 ]] || return 1', ':')
s=s.replace('if [[ $EUID -eq 0 ]]; then', 'if true; then')
s=s.replace('if [[ $EUID -ne 0 ]]; then', 'if false; then')
open(dst,'w',encoding='utf-8').write(s)
PY
  sed -i "s|__T__|$T|g" "$2"
  chmod +x "$2"
  # mock curl 必须优先于真 curl：把 MOCK 目录前置（子进程也生效）
  sed -i "s|^export PATH=.*||" "$2" 2>/dev/null || true
}
vof(){ grep -m1 '^VPS_TOOLS_VERSION=' "$1" | cut -d'"' -f2; }
# 抽取副本里 xray-deploy 注册行的 extra_files（第 6 字段）——只数这一行，
# 避免 grep -c 数到注释里提到的同名文件（本次踩过）
ef_of(){ grep -m1 '^  "xray-deploy|' "$1" | cut -d'|' -f6; }

echo "=== 前置：远端清单 vs 旧清单 ==="
rem_ef="$(grep -m1 '^  "xray-deploy|' "$REMOTE/install.sh" | sed 's/^  "//; s/"$//' | cut -d'|' -f6)"
echo "  远端清单文件数: $(wc -w <<<"$rem_ef")  含 xhttp3: $(grep -c xhttp3.sh <<<"$rem_ef")"
ck "远端清单含 xhttp3.sh" "$(grep -c 'xhttp3.sh' <<<"$rem_ef")" "1"

echo
echo "=== 缺陷 1：版本未升版 → 报「已是最新」→ 不下载（anthony 实际命中）==="
mk_copy "1.8.0" "$T/usr/local/bin/vps-tools" "no"
ck "副本为旧清单（无 xhttp3）" "$(ef_of "$T/usr/local/bin/vps-tools" | grep -c 'xhttp3.sh')" "0"
# 远端版本也改成 1.8.0（模拟「改了 TOOLS 但忘了升版」）
sed -i 's/^VPS_TOOLS_VERSION="[^"]*"/VPS_TOOLS_VERSION="1.8.0"/' "$REMOTE/install.sh"
: > "$LOG"
printf '5\n0\n' | "$T/usr/local/bin/vps-tools" > "$T/o1" 2>&1 || true
echo "  输出:"; grep -E "已是最新|已更新|已安装" "$T/o1" | sed 's/^/    /'
# 修复后行为：版本相同但 TOOLS 指纹不同 → 必须继续更新（旧逻辑在此报「已是最新」→ 永不更新）
ck "检测到清单变更并给出提示" "$(grep -c '远端工具清单已变更' "$T/o1")" "1"
ck "确实拉取了远端 install.sh" "$([[ $(grep -c 'install.sh' "$LOG") -ge 1 ]] && echo yes)" "yes"
ck "副本清单已刷到新清单（含 xhttp3）" "$(ef_of "$T/usr/local/bin/vps-tools" | grep -c 'xhttp3.sh')" "1"

echo
echo "=== 缺陷 1 后果：用陈旧清单更新 xray-deploy → 漏装 xhttp3.sh ==="
printf '2\n%s\n0\n' "$(grep -n 'xray-deploy' "$T/o1" | head -1 >/dev/null; echo 1)" > /dev/null
# 直接走子命令路径：vps-tools update xray-deploy
: > "$LOG"
"$T/usr/local/bin/vps-tools" update xray-deploy > "$T/o2" 2>&1 || true
LIBD="$T/root/xray-deploy/lib"
ck "主脚本已装" "$([[ -f "$T/root/xray-deploy/xray-deploy.sh" ]] && echo yes || echo no)" "yes"
ck "lib 文件已装（新清单 26 个）" "$(ls "$LIBD" 2>/dev/null | wc -l)" "26"
ck "xhttp3.sh 已装上（修复生效）" "$([[ -f "$LIBD/xhttp3.sh" ]] && echo present || echo missing)" "present"
ck "入口 source 了它 → 必然启动即崩" "$(grep -c 'LIB_DIR}/xhttp3.sh' "$T/root/xray-deploy/xray-deploy.sh")" "1"
# 实测崩
crash="$(bash "$T/root/xray-deploy/xray-deploy.sh" -v 2>&1)"
echo "  运行 -v 的实际输出: $(head -1 <<<"$crash")"
ck "工具可正常启动（不再报缺文件）" "$(grep -c '^xray-deploy 1' <<<"$crash")" "1"

echo
echo "=== 缺陷 2（潜在）：升版后自更新落盘，但进程内 TOOLS 不重载 ==="
mk_copy "1.7.0" "$T/usr/local/bin/vps-tools" "no"
sed -i 's/^VPS_TOOLS_VERSION="[^"]*"/VPS_TOOLS_VERSION="1.9.0"/' "$REMOTE/install.sh"
: > "$LOG"
# 菜单：选 5 自更新，再选 2 更新 xray-deploy（同一进程内！）
printf '5\n2\n2\n0\n' | "$T/usr/local/bin/vps-tools" > "$T/o3" 2>&1 || true   # 5=自更新 2=更新工具 2=xray-deploy
echo "  输出:"; grep -E "已更新管理命令|已安装|已是最新" "$T/o3" | head -4 | sed 's/^/    /'
ck "自更新确实落盘到新版本" "$(vof "$T/usr/local/bin/vps-tools")" "1.9.0"
ck "磁盘新副本清单已含 xhttp3" "$(ef_of "$T/usr/local/bin/vps-tools" | grep -c 'xhttp3.sh')" "1"
# 同进程内接着装工具，用的还是启动时加载的旧 TOOLS
ck "同进程内安装已完整（reload 生效）" "$([[ -f "$LIBD/xhttp3.sh" ]] && echo present || echo missing)" "present"

echo
echo "=== 对照：直接用新副本更新 → 正常装上 ==="
rm -rf "$T/root/xray-deploy"
: > "$LOG"
"$T/usr/local/bin/vps-tools" update xray-deploy > "$T/o4" 2>&1 || true
echo "  --- o4 输出 ---"; sed 's/^/    /' "$T/o4" | head -8
echo "  --- curl 调用 ---"; sed 's/^/    /' "$LOG" | head -5
ck "新副本安装含 xhttp3.sh" "$([[ -f "$LIBD/xhttp3.sh" ]] && echo present || echo missing)" "present"
ck "文件数 = 26" "$(ls "$LIBD" | wc -l)" "26"
ck "可正常启动" "$(bash "$T/root/xray-deploy/xray-deploy.sh" -v 2>&1 | grep -c '^xray-deploy ')" "1"

echo
echo "==================================="
echo " PASS=$PASS FAIL=$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
