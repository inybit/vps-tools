#!/usr/bin/env bash
# xray-deploy 安装版本选择 —— 回归套件
#
# 背景（2026-09-21）：Xray v26.9.8 起 REALITY 服务端要求客户端 ClientHello 携带
#   X25519MLKEM768（XTLS/REALITY 提交 8cdf7bf9c7f0），否则握手被静默回落。
#   mihomo 已适配；sing-box 截至 1.14.1 未适配（上游 issue #4520 open）。
#   → 安装向导需让用户能把服务端钉在 v26.7.28 等旧版本。
#
# 用法: bash tests/verify-xray-deploy-version-select.sh
# 退出码: 0=全部通过
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="${REPO}/proxy/xray-deploy/xray-deploy.sh"
LIB="${REPO}/proxy/xray-deploy/lib/xray-bin.sh"
TOOL_DIR="${REPO}/proxy/xray-deploy"
WORK="$(mktemp -d)"

PASS=0; FAIL=0
ck() {  # $1=名称 $2=实际 $3=期望
  if [[ "$2" == "$3" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

echo "=== xray-deploy 安装版本选择 回归 ==="
echo

# ---------- A. 静态断言 ----------
echo "[A] 静态断言"
ck "MLKEM_MIN_VERSION = 26.9.8" "$(grep -oP '^MLKEM_MIN_VERSION="\K[^"]+' "$LIB")" "26.9.8"
ck "定义 xray_tag_needs_mlkem" "$(grep -c '^xray_tag_needs_mlkem()' "$LIB")" "1"
ck "定义 recent_xray_tags" "$(grep -c '^recent_xray_tags()' "$LIB")" "1"
ck "定义 prompt_xray_version" "$(grep -c '^prompt_xray_version()' "$LIB")" "1"
ck "定义 warn_mlkem_if_needed" "$(grep -c '^warn_mlkem_if_needed()' "$LIB")" "1"
ck "install_xray 调用版本选择（定义+调用=2）" "$(grep -c 'prompt_xray_version' "$LIB")" "2"
ck "cmd_upgrade 调用 warn_mlkem_if_needed（定义调用=2）" \
  "$(grep -c 'warn_mlkem_if_needed' "${TOOL_DIR}/lib/cmd-lifecycle.sh")" "2"
ck "cmd_install 调用 warn_mlkem_if_needed" \
  "$(grep -c 'warn_mlkem_if_needed' "${TOOL_DIR}/lib/cmd-lifecycle.sh")" "2"
ck "state_init 含 xray_version 字段" \
  "$(grep -c '"xray_version"' "${TOOL_DIR}/lib/state.sh")" "1"
ck "GITHUB_API 已扩容 per_page=30" "$(grep -c '^GITHUB_API=.*per_page=30' "$MAIN")" "1"

# ⚠️ SIGPIPE 回归守卫（2026-09-21 实测踩到的真 bug）：
#    切片若写成 `... | head -N`，在 set -o pipefail 下 head 读够即关管道 →
#    上游收 SIGPIPE → 管道返回非 0 → 调用方 `|| return 0` 静默早退 → 菜单空白。
ck "切片不用 head -N 管道" \
  "$(grep -cE '(_xray_tags_all|_xray_release_tags|_xray_tags_from_atom|_xray_tags_from_api) \| head' "$LIB")" "0"
ck "纯 bash 切片实现存在（while read ×2）" "$(grep -c 'while IFS= read -r line; do' "$LIB")" "2"

# ⚠️ SIGPIPE 守卫（2026-09-21 本轮实测踩到）：`... | head -1` 在 set -o pipefail 下
#    是否触发 SIGPIPE(141) 取决于输出大小与管道缓冲的竞态 —— 小输出常常侥幸通过，
#    表现为「套件间歇性 rc=141、无汇总行」，极难复现。**一律用 sed -n Np 代替 head -N**。
ck "库内无 version | head 用法" \
  "$(grep -cE '"\$\{BIN_PATH\}" version.*\| head' "$LIB")" "0"
# 说明：不检查本套件自身（断言行会自我匹配，用 awk 排除也命中——本仓库
#       「注释污染断言计数」坑的又一例）。守生产代码即达到目的。
ck "库内全部函数无 | head 用法" \
  "$(grep -v '^[[:space:]]*#' "$LIB" | grep -c '| head')" "0"

# 旧错误说法必须已修正（本轮实测证伪「sing-box 不受影响」）
ck "usage.sh 不再称「sing-box 不受影响」" \
  "$(grep -c 'sing-box 不受影响' "${TOOL_DIR}/lib/usage.sh" || true)" "0"
ck "cmd-info.sh 不再称「sing-box 不受影响」" \
  "$(grep -c 'sing-box 不受影响' "${TOOL_DIR}/lib/cmd-info.sh" || true)" "0"
ck "README 不再称「sing-box 不受影响」" \
  "$(grep -c 'sing-box 不受影响' "${TOOL_DIR}/README.md" || true)" "0"
ck "usage.sh 提到 sing-box 受影响" \
  "$([[ "$(grep -c 'sing-box' "${TOOL_DIR}/lib/usage.sh")" -ge 1 ]] && echo ok)" "ok"
echo

# ---------- 载入被测脚本（截掉子命令分发段）----------
# ⚠️ 截断副本必须落在【主脚本同目录】：SCRIPT_DIR 由 BASH_SOURCE[0] 推导，
#    放别处会让 LIB_DIR 指错 → 函数全缺失（假 FAIL）。
SNIP="${TOOL_DIR}/.vsel-snip.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$MAIN" > "$SNIP"
# shellcheck disable=SC1090
source "$SNIP"
rm -f "$SNIP"
if ! declare -F xray_tag_needs_mlkem >/dev/null; then
  echo "  [FATAL] 被测脚本加载失败（函数未定义）"; exit 1
fi

# ---------- B. 分界版本判定 ----------
echo "[B] 分界版本判定 xray_tag_needs_mlkem"
ck "26.9.9 → 需 MLKEM" "$(xray_tag_needs_mlkem 26.9.9 && echo y || echo n)" "y"
ck "26.9.8 → 需 MLKEM（分界含自身）" "$(xray_tag_needs_mlkem 26.9.8 && echo y || echo n)" "y"
ck "26.9.7 → 不需" "$(xray_tag_needs_mlkem 26.9.7 && echo y || echo n)" "n"
ck "26.7.28 → 不需（sing-box 可用版本）" "$(xray_tag_needs_mlkem 26.7.28 && echo y || echo n)" "n"
ck "25.12.8 → 不需" "$(xray_tag_needs_mlkem 25.12.8 && echo y || echo n)" "n"
ck "26.10.1 → 需（跨位比较）" "$(xray_tag_needs_mlkem 26.10.1 && echo y || echo n)" "y"
ck "带 v 前缀 v26.9.9 → 需" "$(xray_tag_needs_mlkem v26.9.9 && echo y || echo n)" "y"
ck "带 v 前缀 v26.7.28 → 不需" "$(xray_tag_needs_mlkem v26.7.28 && echo y || echo n)" "n"
echo

# ---------- C. mock API：版本列表 / 菜单各输入路径 / 警示分支 ----------
# mock curl（忽略参数，吐 30 条假 tag）→ 确定性、不依赖外网、不消耗 GitHub 配额。
# ⚠️ 必须在本进程内 mock（早期版本放子进程里 source，静默失败导致全部假红）。
echo "[C] mock API 下的版本列表与菜单"
MOCKTAGS="$WORK/tags.txt"
{
  printf 'v26.9.9\nv26.9.8\nv26.7.28\nv26.7.11\nv26.6.27\nv26.6.22\nv26.6.1\n'
  printf 'v26.5.9\nv26.5.3\nv26.4.25\nv26.4.17\nv26.4.15\n'
  for i in $(seq 1 18); do printf 'v26.3.%d\n' "$i"; done
} > "$MOCKTAGS"
ck "mock 数据 30 条" "$(wc -l < "$MOCKTAGS")" "30"

curl() { jq -R -s 'split("\n") | map(select(length>0)) | map({tag_name: ., draft: false})' < "$MOCKTAGS"; }

ck "recent_xray_tags 100 → 全部 30 条" "$(recent_xray_tags 100 | wc -l)" "30"
recent_xray_tags 10 >/dev/null; ck "recent_xray_tags 10 返回码 0（SIGPIPE 守卫）" "$?" "0"
ck "recent_xray_tags 10 → 恰好 10 条" "$(recent_xray_tags 10 | wc -l)" "10"
ck "recent_xray_tags 10 首条=最新" "$(recent_xray_tags 10 | sed -n 1p)" "v26.9.9"
ck "recent_xray_tags 10 末条=第 10 个" "$(recent_xray_tags 10 | tail -1)" "v26.4.25"
ck "latest_xray_tag = v26.9.9" "$(latest_xray_tag)" "v26.9.9"
latest_xray_tag >/dev/null; ck "latest_xray_tag 返回码 0" "$?" "0"
ck "_xray_tag_at 3 = v26.7.28" "$(_xray_tag_at 3)" "v26.7.28"
ck "_xray_tag_at 30 = 第 30 个" "$(_xray_tag_at 30)" "v26.3.18"
# ⚠️ 越界路径不用 `cmd >/dev/null 2>&1; ck "$?"` 这种裸 $? 捕获——
#    2026-09-21 实测该写法会让套件在此处静默终止（后续断言全不执行、无报错）。
#    改用显式 rc 变量。
rc_at31=0; _xray_tag_at 31 >/dev/null 2>&1 || rc_at31=$?
ck "_xray_tag_at 31 越界返回非 0" "$rc_at31" "1"

# 菜单交互路径
ck "无 TTY → 空（调用方回退最新版）" "$(prompt_xray_version 2>/dev/null)" ""
read_input() { printf -v "$2" '%s' "3"; return 0; }
ck "选 3 → 第 3 个" "$(prompt_xray_version 2>/dev/null)" "v26.7.28"
read_input() { printf -v "$2" '%s' "10"; return 0; }
ck "选 10 → 第 10 个" "$(prompt_xray_version 2>/dev/null)" "v26.4.25"
read_input() { printf -v "$2" '%s' ""; return 0; }
ck "回车 → 最新" "$(prompt_xray_version 2>/dev/null)" "v26.9.9"
read_input() { printf -v "$2" '%s' "abc"; return 0; }
ck "非法输入 → 回退最新" "$(prompt_xray_version 2>/dev/null)" "v26.9.9"
read_input() { printf -v "$2" '%s' "99"; return 0; }
ck "越界 99 → 回退最新" "$(prompt_xray_version 2>/dev/null)" "v26.9.9"
read_input() { printf -v "$2" '%s' "0"; return 0; }
ck "输入 0 → 回退最新" "$(prompt_xray_version 2>/dev/null)" "v26.9.9"

# 菜单内容（stderr）与返回值纯净度（stdout）
read_input() { printf -v "$2" '%s' ""; return 0; }
prompt_xray_version > "$WORK/menu.out" 2> "$WORK/menu.err"
ck "菜单 stdout 仅 tag（不污染返回值）" "$(cat "$WORK/menu.out")" "v26.9.9"
ck "菜单打印 ≥12 行到 stderr" "$([[ "$(wc -l < "$WORK/menu.err")" -ge 12 ]] && echo ok)" "ok"
ck "菜单含 sing-box 警示" "$([[ "$(grep -c 'sing-box' "$WORK/menu.err")" -ge 1 ]] && echo ok)" "ok"
ck "菜单含 mihomo 说明" "$([[ "$(grep -c 'mihomo' "$WORK/menu.err")" -ge 1 ]] && echo ok)" "ok"
ck "菜单含分界说明（26.9.8 起）" "$([[ "$(grep -c '26.9.8 起' "$WORK/menu.err")" -ge 1 ]] && echo ok)" "ok"
ck "菜单标注「最新」" "$([[ "$(grep -c '最新' "$WORK/menu.err")" -ge 1 ]] && echo ok)" "ok"

# warn_mlkem_if_needed 条件分支
STATE_FILE="$WORK/state.json"
printf '{"protocols":[{"type":"vless-reality"}]}' > "$STATE_FILE"
ck "REALITY + v26.9.9 → 有警示" \
  "$([[ "$(warn_mlkem_if_needed v26.9.9 2>&1 | grep -c 'sing-box')" -ge 1 ]] && echo ok)" "ok"
ck "REALITY + v26.7.28 → 无警示" "$(warn_mlkem_if_needed v26.7.28 2>&1 | wc -l)" "0"
ck "REALITY(xhttp) + v26.9.9 → 有警示" \
  "$(printf '{"protocols":[{"type":"vless-xhttp-reality"}]}' > "$STATE_FILE"; \
     [[ "$(warn_mlkem_if_needed v26.9.9 2>&1 | grep -c 'sing-box')" -ge 1 ]] && echo ok)" "ok"
printf '{"protocols":[{"type":"hysteria2"}]}' > "$STATE_FILE"
ck "仅 hy2 + v26.9.9 → 无警示" "$(warn_mlkem_if_needed v26.9.9 2>&1 | wc -l)" "0"
rm -f "$STATE_FILE"
ck "无 state 文件 → 无警示" "$(warn_mlkem_if_needed v26.9.9 2>&1 | wc -l)" "0"
echo

# ---------- D. 真实 GitHub API ----------
# 配额受限（403）时 SKIP，避免假红；能连通时必须通过。
echo "[D] 真实 GitHub API（配额受限则 SKIP）"
unset -f curl   # 恢复真实 curl

# ---------- C2. 403 配额兜底（2026-09-21 用户真机报障）----------
# 未认证 GitHub API 配额 60 次/时，超限 403 → 原实现直接 die，安装向导第一步卡死。
# 本组断言：API 失败必须回退 releases.atom，且两者都失败时报错非 0。
# ⚠️ 本组必须在 `unset -f curl` 之后（否则用到的是上面 C 段的 mock curl，
#    假 API 根本不会生效 → 断言恒过 = 假绿）。
echo "[C2] 403 配额兜底（API 失败 → 回退 releases.atom）"
ck "XRAY_ATOM 常量存在" \
  "$([[ -n "$(grep -oP '^XRAY_ATOM="\K[^"]+' "$MAIN")" ]] && echo ok)" "ok"
ck "atom 端点指向 releases.atom" \
  "$(grep -oP '^XRAY_ATOM="\K[^"]+' "$MAIN" | grep -c 'releases\.atom')" "1"

# 真实 API 最新版（供下面的对照断言用；配额受限时为空 → 跳过对照）
live_latest="$(latest_xray_tag 2>/dev/null || true)"

# 用「连不上的端口」等价模拟 API 失败（curl 会返回 7/22，走同一失败分支）
_fake_api="http://127.0.0.1:9/nope"
_rc_atom=0
_out_atom="$(GITHUB_API="$_fake_api" recent_xray_tags 10 2>/dev/null)" || _rc_atom=$?
ck "API 不可用 → 仍返回版本列表（rc=0）" "$_rc_atom" "0"
ck "API 不可用 → 回退后拿到 10 条" "$(wc -l <<<"$_out_atom")" "10"
ck "API 不可用 → 首条形如 v26.x" \
  "$([[ "$(head -1 <<<"$_out_atom")" =~ ^v26\. ]] && echo ok)" "ok"

# 兜底提示必须出现（不能被静默吞掉）
_err_out="$(GITHUB_API="$_fake_api" recent_xray_tags 10 2>&1 >/dev/null || true)"
ck "回退时打印 WARN（提示 releases.atom）" \
  "$([[ "$(grep -c 'releases.atom' <<<"$_err_out")" -ge 1 ]] && echo ok)" "ok"

# 两者都失败 → 明确报错 + 非 0（不能让调用方拿到空值继续跑）
_rc_both=0
XRAY_ATOM="http://127.0.0.1:9/nope" GITHUB_API="$_fake_api" recent_xray_tags 10 >/dev/null 2>&1 || _rc_both=$?
ck "API+atom 均失败 → 返回非 0" "$_rc_both" "1"

# 关键：atom 解析出的 tag 必须与 API 一致（防「回退到错版本」）
if [[ -n "$live_latest" ]]; then
  _atom_first="$(_xray_tags_from_atom 2>/dev/null | sed -n 1p)"
  ck "atom 首条 == API 最新（${_atom_first} vs ${live_latest}）" "$_atom_first" "$live_latest"
else
  echo "  [SKIP] API 配额受限，跳过 atom/API 一致性对照"
fi
echo

ck "GITHUB_API 用 releases 列表 per_page=30" \
  "$(grep -oP '^GITHUB_API=.*per_page=\K[0-9]+' "$MAIN")" "30"
if [[ -z "$live_latest" ]]; then
  echo "  [SKIP] GitHub API 不可达/配额受限（403）—— 联网且有余量时请重跑"
elif [[ "$live_latest" =~ ^v26\. ]]; then
  ck "真实 API latest 形如 v26.x（实得 ${live_latest}）" "ok" "ok"
  ck "真实 API recent 10 返回 10 条" "$(recent_xray_tags 10 2>/dev/null | wc -l)" "10"
  ck "真实 API _xray_tag_at 3 形如 v26.x" \
    "$([[ "$(_xray_tag_at 3 2>/dev/null)" =~ ^v26\. ]] && echo ok)" "ok"
else
  ck "真实 API latest 形如 v26.x（实得 ${live_latest}）" "bad" "ok"
fi
echo

echo "==================================="
printf ' PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
echo "==================================="
rm -rf "$WORK"
[[ "$FAIL" -eq 0 ]]
