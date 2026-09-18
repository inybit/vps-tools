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
  "$(grep -c 'ver_gt "\$cur" "\$latest"' "${REPO}/proxy/xray-deploy/lib/cmd-lifecycle.sh" || true)" "1"
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
ck "tag 非空" "$([[ -n "$tag" ]] && echo yes)" "yes"
ck "tag 形如 v<数字>" "$([[ "$tag" =~ ^v[0-9] ]] && echo yes)" "yes"
# 关键：必须比 v26.3.27 新（旧 bug 恒返回它）
newer="$([[ "$tag" =~ ^v26\.(9|[1-9][0-9]) ]] && echo yes || echo no)"
ck "tag 比 v26.3.27 新（旧 bug 会返回 v26.3.27）" "$newer" "yes"
# 与实际最新对比
real="$(curl -fsSL --max-time 20 'https://api.github.com/repos/XTLS/Xray-core/releases?per_page=1' | jq -r '.[0].tag_name')"
ck "tag == 实际最新 release（${real}）" "$tag" "$real"
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

# ---------- D. cmd_upgrade 防降级（mock 二进制） ----------
echo "[D] cmd_upgrade 防降级行为（mock）"
UP="$TMP/up.sh"
cat > "$UP" <<'UPROBE'
set -uo pipefail
src="$1"; tmpdir="$2"; local_ver="$3"; remote_ver="$4"
tmp="$(dirname "$src")/.nodisp.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"; rm -f "$tmp"

# mock：BIN_PATH 指向假 xray（报告已装版本）；need_root/service_restart 空实现
BIN_PATH="${tmpdir}/xray"
printf '#!/usr/bin/env bash\n[[ "$1" == version ]] && echo "Xray %s (fake)"\n' "$local_ver" > "$BIN_PATH"
chmod +x "$BIN_PATH"
need_root() { :; }
service_restart() { echo "RESTART_CALLED"; }
download_xray() { echo "DOWNLOAD_CALLED:$1"; return 0; }
# ⚠️ 函数内 $1..$n 是【函数自己的】位置参数，不是脚本的 → 必须先用变量捕获再闭包引用
latest_xray_tag() { echo "$remote_ver"; }

cmd_upgrade 2>&1 | sed 's/^/    /'
UPROBE

echo "  -- 场景 1：本地 26.9.9 / 远端 26.3.27（旧 bug 会降级）--"
o1="$(bash "$UP" "$MAIN" "$TMP" "26.9.9" "v26.3.27" 2>&1)"
ck "  提示避免降级" "$(grep -c '避免降级' <<<"$o1")" "1"
ck "  未调用 download_xray" "$(grep -c 'DOWNLOAD_CALLED' <<<"$o1")" "0"
ck "  未重启服务" "$(grep -c 'RESTART_CALLED' <<<"$o1")" "0"

echo "  -- 场景 2：本地 26.3.27 / 远端 26.9.9（正常升级）--"
o2="$(bash "$UP" "$MAIN" "$TMP" "26.3.27" "v26.9.9" 2>&1)"
ck "  触发下载" "$(grep -c 'DOWNLOAD_CALLED:v26.9.9' <<<"$o2")" "1"
ck "  重启服务" "$(grep -c 'RESTART_CALLED' <<<"$o2")" "1"

echo "  -- 场景 3：本地 == 远端（已最新）--"
o3="$(bash "$UP" "$MAIN" "$TMP" "26.9.9" "v26.9.9" 2>&1)"
ck "  提示已最新" "$(grep -c '已是最新' <<<"$o3")" "1"
ck "  未下载" "$(grep -c 'DOWNLOAD_CALLED' <<<"$o3")" "0"
echo

echo "==================================="
printf ' PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
