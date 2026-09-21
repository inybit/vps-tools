#!/usr/bin/env bash
# 阶段 2 回归：latest 版本查询修复 + 防降级
#
# 背景（2026-09-18 实测根因）：
#   Xray 从 v26.3.23 起所有 release 都标 prerelease:true，
#   GitHub `/releases/latest` 【只返回非 prerelease 的最新版】
#   → 恒返回 v26.3.27，实际最新 v26.9.9 → 永远装旧版。
#   叠加 cmd_upgrade 用字符串相等比较 → 已装新版会被【降级】。
#
# 用法: bash tests/verify-xray-deploy-latest.sh
# 退出码: 0=全部通过
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="${REPO}/proxy/xray-deploy/xray-deploy.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ck() {
  if [[ "$2" == "$3" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

echo "=== 阶段 2 回归：latest 查询 + 防降级 ==="
echo

# ---------- A. 静态：不再用 /releases/latest ----------
# ⚠️ 断言必须精确到 GITHUB_API 那一行，不能全文件 grep：
#    - 注释里会引用旧端点名（修复说明）
#    - GEO_SOURCE（MetaCubeX geo 数据）合法使用 /releases/latest，不受影响
echo "[A] 静态断言"
ck "GITHUB_API 行不再用 /releases/latest" \
  "$(grep -c '^GITHUB_API=.*releases/latest' "$MAIN" || true)" "0"
ck "GITHUB_API 行用 releases 列表" \
  "$(grep -c '^GITHUB_API=.*releases?per_page=' "$MAIN" || true)" "1"
ck "GEO_SOURCE 仍可用 /releases/latest（不受影响）" \
  "$(grep -c '^GEO_SOURCE=.*releases/latest' "$MAIN" || true)" "1"
ck "latest_xray_tag 过滤 draft" \
  "$(grep -c 'select(.draft == false)' "${REPO}/proxy/xray-deploy/lib/xray-bin.sh" || true)" "1"
ck "ver_gt 已定义" \
  "$(grep -c '^ver_gt()' "${REPO}/proxy/xray-deploy/lib/common.sh" || true)" "1"
ck "cmd_upgrade 调用 ver_gt 防降级" \
  "$(grep -c 'ver_gt "\$cur" "\${target#v}"' "${REPO}/proxy/xray-deploy/lib/cmd-upgrade.sh" || true)" "2"
# 期望 2 的理由（2026-09-21 cmd_upgrade 支持显式版本后）：①无参路径的防降级判断
#   ②显式路径下「回退/切换」文案的分支判断。两处都拿 $cur 与目标比较。
# ⚠️ 函数已从 cmd-lifecycle.sh 拆到 cmd-upgrade.sh（单文件行数上限），断言路径同步。
echo

# ---------- B. 真实 API 调用 ----------
echo "[B] 真实 GitHub API（需外网）"
probe="$TMP/probe.sh"
cat > "$probe" <<'PROBE'
set -uo pipefail
src="$1"
tmp="$(dirname "$src")/.nodisp.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"; rm -f "$tmp"
echo "api_url=${GITHUB_API}"
echo "tag=$(latest_xray_tag)"
PROBE
out="$(bash "$probe" "$MAIN" 2>/dev/null)"
tag="$(grep -oP '^tag=\K.*' <<<"$out")"
api="$(grep -oP '^api_url=\K.*' <<<"$out")"
echo "    GITHUB_API = ${api}"
echo "    解析出的 tag = ${tag}"
ck "API 端点含 releases 列表" "$(grep -c 'releases?per_page=' <<<"$api")" "1"
# ⚠️ 下面 3 条依赖真实 GitHub API。未认证时配额仅 60 次/时，
#    被限流（403）会拿到空 tag → 会误报「回归」（2026-09-21 实测踩到）。
#    配额受限时 SKIP，不污染全量回归结果。
if [[ -z "$tag" ]]; then
  echo "    [SKIP] GitHub API 不可达/配额受限（403）—— 联网且有余量时请重跑本套件"
else
  ck "tag 非空" "$([[ -n "$tag" ]] && echo yes)" "yes"
  ck "tag 形如 v<数字>" "$([[ "$tag" =~ ^v[0-9] ]] && echo yes)" "yes"
  # 关键：必须比 v26.3.27 新（旧 bug 恒返回它）
  newer="$([[ "$tag" =~ ^v26\.(9|[1-9][0-9]) ]] && echo yes || echo no)"
  ck "tag 比 v26.3.27 新（旧 bug 会返回 v26.3.27）" "$newer" "yes"
  # 与实际最新对比
  # ⚠️ 这条对照必须走 atom 兜底，不能用裸 curl 打 API：未认证配额 60 次/时，
  #    配额耗尽时裸 curl 拿空 → 误报「回归」（2026-09-21 实测）。
  #    atom 无配额，与 API 的 tag 序列实测一致。
  real="$(_xray_tags_from_atom 2>/dev/null | sed -n 1p || true)"
  if [[ -n "$real" ]]; then
    ck "tag == 实际最新 release（${real}）" "$tag" "$real"
  else
    echo "    [SKIP] 无法取到对照版本（API 与 atom 均不可达）"
  fi
fi
echo

# ---------- C. ver_gt 语义 ----------
echo "[C] ver_gt 语义化比较"
vt="$TMP/vt.sh"
cat > "$vt" <<'VT'
set -uo pipefail
src="$1"
tmp="$(dirname "$src")/.nodisp.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"; rm -f "$tmp"
t() { ver_gt "$1" "$2" && echo "gt" || echo "le"; }
echo "26.9.9 vs 26.3.27 = $(t 26.9.9 26.3.27)"
echo "26.3.27 vs 26.9.9 = $(t 26.3.27 26.9.9)"
echo "26.9.9 vs 26.9.9  = $(t 26.9.9 26.9.9)"
echo "26.10.1 vs 26.9.9 = $(t 26.10.1 26.9.9)"
echo "25.12.8 vs 26.1.1 = $(t 25.12.8 26.1.1)"
echo "26.9.10 vs 26.9.9 = $(t 26.9.10 26.9.9)"
echo "26.1 vs 26.1.0    = $(t 26.1 26.1.0)"
VT
vo="$(bash "$vt" "$MAIN" 2>/dev/null)"
ck "26.9.9 > 26.3.27（降级场景）" "$(grep -oP '26\.9\.9 vs 26\.3\.27 = \K.*' <<<"$vo")" "gt"
ck "26.3.27 < 26.9.9（正常升级）" "$(grep -oP '26\.3\.27 vs 26\.9\.9 = \K.*' <<<"$vo")" "le"
ck "26.9.9 == 26.9.9（已最新）" "$(grep -oP '26\.9\.9 vs 26\.9\.9  = \K.*' <<<"$vo")" "le"
ck "26.10.1 > 26.9.9（跨位比较）" "$(grep -oP '26\.10\.1 vs 26\.9\.9 = \K.*' <<<"$vo")" "gt"
ck "25.12.8 < 26.1.1（跨年）" "$(grep -oP '25\.12\.8 vs 26\.1\.1 = \K.*' <<<"$vo")" "le"
ck "26.9.10 > 26.9.9" "$(grep -oP '26\.9\.10 vs 26\.9\.9 = \K.*' <<<"$vo")" "gt"
ck "26.1 == 26.1.0（缺位补零）" "$(grep -oP '26\.1 vs 26\.1\.0    = \K.*' <<<"$vo")" "le"
echo

# ---------- D. cmd_upgrade：无参数 = 升级（防降级回归） ----------
echo "[D] cmd_upgrade 无参路径（升级 + 防降级，mock）"
UP="$TMP/up.sh"
cat > "$UP" <<'UPROBE'
set -uo pipefail
src="$1"; tmpdir="$2"; local_ver="$3"; remote_ver="$4"
shift 4            # 余下参数原样透传给 cmd_upgrade（无 = 无参路径）
tmp="$(dirname "$src")/.nodisp.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"; rm -f "$tmp"

# mock：BIN_PATH 指向假 xray（报告已装版本）；need_root/service_restart/state_set 可观测
BIN_PATH="${tmpdir}/xray"
write_bin() {  # $1=版本
  printf '#!/usr/bin/env bash\n[[ "$1" == version ]] && echo "Xray %s (fake)"\n' "$1" > "$BIN_PATH"
  chmod +x "$BIN_PATH"
}
write_bin "$local_ver"
STATE_FILE="${tmpdir}/state.json"
# ⚠️ 不能用 ${STATE_JSON:-{...}}：默认值里的花括号会被 bash 提前闭合，末尾多出字面 '}' → JSON 损坏
state_json="${STATE_JSON:-}"
[[ -n "$state_json" ]] || state_json='{"xray_version":"x"}'
printf '%s' "$state_json" > "$STATE_FILE"
need_root() { :; }
# ⚠️ 必须 mock install_deps：cmd_upgrade 现在会先做依赖自检，
#    真跑会去调包管理器（本机缺 unzip → 尝试 apt-get → 权限失败 → die），
#    导致【全部】断言假红（2026-09-21 实测踩到）。凡被测函数新增的外部调用点都要 mock。
install_deps() { echo "DEPS_CHECKED"; }
service_restart() { echo "RESTART_CALLED"; }
state_set() { echo "STATE_SET:$*"; }
# 下载成功时把假二进制替换成【目标版本】，模拟真实安装后的磁盘状态
download_xray() {
  echo "DOWNLOAD_CALLED:$1"
  [[ -n "${DOWNLOAD_FAIL:-}" ]] && return 1
  write_bin "${1#v}"
  return 0
}
# ⚠️ 函数内 $1..$n 是【函数自己的】位置参数，不是脚本的 → 必须先用变量捕获再闭包引用
latest_xray_tag() { echo "$remote_ver"; }
_xray_tags_all() {
  [[ -n "${TAGS_UNAVAILABLE:-}" ]] && return 1
  printf '%s\n' v26.9.9 v26.9.8 v26.7.28 v26.6.27
}
# ⚠️ 两个必须：①不能接管道（die 的 exit 会终止整个探针，后续行不打印）；
#    ②必须用【子 shell】包裹 —— 否则 die 的 exit 同样杀掉探针本身
#    （Pitfall 14：函数内 exit 是全局退出，测试须用 ( ... ) 捕获）。
#    症状统一为：退出码/磁盘版本断言恒空。
#    ⚠️③还要 `set +e`：被测主脚本顶部有 `set -euo pipefail`，source 后会传染给探针，
#    子 shell 返回非 0 时探针立即退出（症状：die 路径连 RC 行都不打印）。
outf="${tmpdir}/up.out"
set +e
( cmd_upgrade "$@" ) > "$outf" 2>&1
rc=$?
set -e
sed 's/^/    /' "$outf"
echo "RC=${rc}"
echo "DISK_VER=$("$BIN_PATH" version 2>/dev/null | awk '{print $2}')"
UPROBE

run_up() {  # $1=本地版本 $2=远端最新 $3...=cmd_upgrade 参数
  local lv="$1" rv="$2"; shift 2
  bash "$UP" "$MAIN" "$TMP" "$lv" "$rv" "$@" 2>&1
}
rc_of()   { grep -oP '^RC=\K\d+' <<<"$1"; }
disk_of() { grep -oP '^DISK_VER=\K.*' <<<"$1"; }

echo "  -- 场景 1：本地 26.9.9 / 远端 26.3.27（旧 bug 会降级）--"
o1="$(run_up 26.9.9 v26.3.27)"
ck "  先做依赖自检" "$(grep -c 'DEPS_CHECKED' <<<"$o1")" "1"
ck "  提示避免降级" "$(grep -c '避免降级' <<<"$o1")" "1"
ck "  未调用 download_xray" "$(grep -c 'DOWNLOAD_CALLED' <<<"$o1")" "0"
ck "  未重启服务" "$(grep -c 'RESTART_CALLED' <<<"$o1")" "0"
ck "  提示了回退用法" "$(grep -c 'upgrade v26.7.28' <<<"$o1")" "1"

echo "  -- 场景 2：本地 26.3.27 / 远端 26.9.9（正常升级）--"
o2="$(run_up 26.3.27 v26.9.9)"
ck "  触发下载" "$(grep -c 'DOWNLOAD_CALLED:v26.9.9' <<<"$o2")" "1"
ck "  重启服务" "$(grep -c 'RESTART_CALLED' <<<"$o2")" "1"
ck "  state 记录实际版本" "$(grep -c 'STATE_SET:--arg v 26.9.9 ' <<<"$o2")" "1"

echo "  -- 场景 3：本地 == 远端（已最新）--"
o3="$(run_up 26.9.9 v26.9.9)"
ck "  提示已最新" "$(grep -c '已是最新' <<<"$o3")" "1"
ck "  未下载" "$(grep -c 'DOWNLOAD_CALLED' <<<"$o3")" "0"
echo

# ---------- E. cmd_upgrade 显式版本 = 回退/切换（2026-09-21 新增） ----------
# 用户报障：「xray-deploy 无法回退 xray 内核到指定版本」。
# 此前只有【首次安装向导】能选版本，装好后 upgrade 恒升最新 + 防降级跳过 → 退不回去。
echo "[E] cmd_upgrade 显式版本路径（回退/切换）"

echo "  -- 场景 4：本地 26.9.9 → upgrade v26.7.28（核心修复：允许降级）--"
o4="$(run_up 26.9.9 v26.9.9 v26.7.28)"
ck "  提示回退/切换" "$(grep -c '回退/切换 Xray 版本 26.9.9 → 26.7.28' <<<"$o4")" "1"
ck "  未被防降级拦截" "$(grep -c '避免降级' <<<"$o4")" "0"
ck "  下载目标版本" "$(grep -c 'DOWNLOAD_CALLED:v26.7.28' <<<"$o4")" "1"
ck "  重启服务" "$(grep -c 'RESTART_CALLED' <<<"$o4")" "1"
ck "  state 同步为实际版本" "$(grep -c 'STATE_SET:--arg v 26.7.28 ' <<<"$o4")" "1"
ck "  退出码 0" "$(rc_of "$o4")" "0"
ck "  磁盘版本已切换" "$(disk_of "$o4")" "26.7.28"

echo "  -- 场景 5：不带 v 前缀（upgrade 26.7.28）--"
o5="$(run_up 26.9.9 v26.9.9 26.7.28)"
ck "  归一化为 v26.7.28" "$(grep -c 'DOWNLOAD_CALLED:v26.7.28' <<<"$o5")" "1"
ck "  退出码 0" "$(rc_of "$o5")" "0"

echo "  -- 场景 6：目标 == 当前（upgrade v26.9.9）--"
o6="$(run_up 26.9.9 v26.9.9 v26.9.9)"
ck "  提示无需切换" "$(grep -c '无需切换' <<<"$o6")" "1"
ck "  未下载" "$(grep -c 'DOWNLOAD_CALLED' <<<"$o6")" "0"

echo "  -- 场景 7：发布列表中不存在的 tag（防打错字）--"
o7="$(run_up 26.9.9 v26.9.9 v99.99.99)"
ck "  拒绝并报错" "$([[ "$(grep -c '不存在' <<<"$o7")" -ge 1 ]] && echo ok)" "ok"
ck "  未下载" "$(grep -c 'DOWNLOAD_CALLED' <<<"$o7")" "0"
ck "  退出码非 0" "$(rc_of "$o7")" "1"
ck "  列出最近版本供核对" "$(grep -c 'v26.7.28' <<<"$o7")" "1"

echo "  -- 场景 8：非法版本号格式（防路径注入）--"
for bad in abc v26.7 v26.7.28-x 'v26.7.28;rm -rf /'; do
  ob="$(run_up 26.9.9 v26.9.9 "$bad")"
  ck "  '$bad' 被拒绝" "$(grep -c '格式非法' <<<"$ob")" "1"
  ck "  '$bad' 未下载" "$(grep -c 'DOWNLOAD_CALLED' <<<"$ob")" "0"
done

echo "  -- 场景 9：发布列表不可用（离线/配额）→ 不阻断 --"
o9="$(TAGS_UNAVAILABLE=1 run_up 26.9.9 v26.9.9 v26.7.28)"
ck "  提示跳过校验" "$(grep -c '跳过 tag 校验' <<<"$o9")" "1"
ck "  仍执行下载" "$(grep -c 'DOWNLOAD_CALLED:v26.7.28' <<<"$o9")" "1"

echo "  -- 场景 10：下载失败 → 回滚旧版本 --"
o10="$(DOWNLOAD_FAIL=1 run_up 26.9.9 v26.9.9 v26.7.28)"
ck "  提示已回滚" "$(grep -c '已回滚到 26.9.9' <<<"$o10")" "1"
ck "  退出码非 0" "$(rc_of "$o10")" "1"
ck "  磁盘仍是旧版本" "$(disk_of "$o10")" "26.9.9"
ck "  未重启服务" "$(grep -c 'RESTART_CALLED' <<<"$o10")" "0"

echo "  -- 场景 11：显式路径同样触发 MLKEM 兼容告警 --"
o11="$(STATE_JSON='{"protocols":[{"type":"vless-reality"}]}' run_up 26.7.28 v26.7.28 v26.9.9)"
ck "  告警 sing-box 不可用" "$([[ "$(grep -c 'sing-box' <<<"$o11")" -ge 1 ]] && echo ok)" "ok"
ck "  仍执行下载" "$(grep -c 'DOWNLOAD_CALLED:v26.9.9' <<<"$o11")" "1"
echo

echo "==================================="
printf ' PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
