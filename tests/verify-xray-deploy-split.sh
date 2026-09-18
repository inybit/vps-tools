#!/usr/bin/env bash
# xray-deploy 拆分等价性验证（阶段 0）
#
# 原理：`declare -f` 输出函数的规范化定义（缩进/空行已归一），
#   把「拆分前单文件」与「拆分后主脚本+lib」的函数集合 dump 出来 diff。
#   diff 为空 = 函数体逐字相同 = 纯搬运、零逻辑变更。
#
# 用法:
#   bash tests/verify-xray-deploy-split.sh                       # 与基线对比
#   bash tests/verify-xray-deploy-split.sh --baseline <原始脚本>  # 用【拆分前】脚本重建基线
#
# ⚠️ 基线必须用【同一个 dump_fns 方法】从【拆分前的单文件】生成，
#    否则比较的是「方法差异」而非「拆分差异」（本次踩过：函数数 0 的假 FAIL）。
#
# 退出码: 0=等价, 1=有差异/错误
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL_DIR="${REPO}/proxy/xray-deploy"
MAIN="${TOOL_DIR}/xray-deploy.sh"
BASE="${TOOL_DIR}/tests/.fn-baseline.txt"
CUR="/tmp/xray-deploy-fn-current.txt"

MODE="${1:-}"
BASELINE_SRC="${2:-}"

# 截掉子命令分发段（从分发注释到文件尾），否则 source 会真的执行命令
strip_dispatch() {
  sed '/^# ============ 子命令分发 ============/,$d' "$1"
}

dump_fns() {
  # $1=要 dump 的入口脚本
  # ⚠️ 必须把截断后的内容写到【与被测脚本同目录】的临时文件再 source：
  #    用 `source <(sed ...)` 时 BASH_SOURCE[0] 变成 /dev/fd/63，
  #    SCRIPT_DIR 解析错 → lib/ 路径失败 → 函数数为 0（假 FAIL）。
  # ⚠️ 按【函数块】输出（`=== name ===` + declare -f name），不是 `declare -f | sort`：
  #    行排序会丢掉函数边界，导致「有意的函数新增」与「意外的函数体改动」无法区分。
  local entry="$1" dir tmp
  dir="$(cd "$(dirname "$entry")" && pwd)"
  tmp="${dir}/.dump-fns.$$.sh"
  strip_dispatch "$entry" > "$tmp"
  bash -c '
    set -uo pipefail
    source "$1"
    for f in $(declare -F | awk "{print \$3}" | sort); do
      echo "=== ${f} ==="
      declare -f "$f"
    done
  ' _ "$tmp" 2>/dev/null
  rm -f "$tmp"
}

# 从 dump 中提取函数名列表
fn_names() { grep -oE '^=== [a-zA-Z_][a-zA-Z0-9_]* ===$' "$1" | sed 's/^=== //; s/ ===$//'; }

# 提取单个函数的块（含 declare -f 体）
fn_block() {  # $1=dump文件 $2=函数名
  awk -v n="$2" '
    $0 == "=== " n " ===" {p=1; next}
    /^=== [a-zA-Z_][a-zA-Z0-9_]* ===$/ {p=0}
    p {print}
  ' "$1"
}

echo "=== xray-deploy 拆分等价性验证 ==="
echo "入口: ${MAIN}"
echo

if [[ ! -f "$MAIN" ]]; then
  echo "[FAIL] 主脚本不存在: ${MAIN}" >&2
  exit 1
fi

# ---- 语法检查 ----
echo "[1] 语法检查"
for f in "${MAIN}" "${TOOL_DIR}"/lib/*.sh; do
  [[ -f "$f" ]] || continue
  if bash -n "$f" 2>/dev/null; then
    printf '    ok   %s\n' "${f#"${REPO}"/}"
  else
    printf '    FAIL %s\n' "${f#"${REPO}"/}"
    bash -n "$f" 2>&1 | head -5 | sed 's/^/         /'
    echo "[FAIL] 语法错误" >&2
    exit 1
  fi
done
echo

# ---- 行数规约 ----
echo "[2] 行数规约（≤200 行）"
over=0
for f in "${MAIN}" "${TOOL_DIR}"/lib/*.sh; do
  [[ -f "$f" ]] || continue
  n="$(wc -l < "$f")"
  if [[ "$n" -le 200 ]]; then
    printf '    ok   %3d  %s\n' "$n" "${f#"${REPO}"/}"
  else
    printf '    OVER %3d  %s\n' "$n" "${f#"${REPO}"/}"
    over=$((over + 1))
  fi
done
[[ "$over" -eq 0 ]] && echo "    全部合规" || echo "    ⚠ ${over} 个文件超 200 行"
echo

# ---- 函数等价性 ----
echo "[3] 函数集合等价性（declare -f diff）"
if [[ "$MODE" == "--baseline" ]]; then
  [[ -n "$BASELINE_SRC" && -f "$BASELINE_SRC" ]] || {
    echo "    用法: $0 --baseline <拆分前的原始脚本路径>" >&2; exit 1; }
  mkdir -p "$(dirname "$BASE")"
  dump_fns "$BASELINE_SRC" > "$BASE"
  echo "    已从 ${BASELINE_SRC} 重建基线: ${BASE}"
  echo "    ($(grep -c '^[a-zA-Z_][a-zA-Z0-9_]* ()' "$BASE" || echo 0) 个函数)"
  exit 0
fi

if [[ ! -f "$BASE" ]]; then
  echo "    [SKIP] 无基线文件（首次运行请先 --baseline）"
  echo "    提示：基线应在【拆分前】生成，之后 diff 才有意义"
  exit 0
fi

dump_fns "$MAIN" > "$CUR"
n_base="$(fn_names "$BASE" | wc -l)"
n_cur="$(fn_names "$CUR" | wc -l)"
echo "    基线函数数: ${n_base}"
echo "    当前函数数: ${n_cur}"
echo

# ---- 3a) 函数名集合差异 ----
added="$(comm -13 <(fn_names "$BASE") <(fn_names "$CUR"))"
removed="$(comm -23 <(fn_names "$BASE") <(fn_names "$CUR"))"
common="$(comm -12 <(fn_names "$BASE") <(fn_names "$CUR"))"

if [[ -n "$added" ]]; then
  echo "    新增函数（预期只有 usage）:"
  echo "$added" | sed 's/^/      + /'
fi
if [[ -n "$removed" ]]; then
  echo "    ✗ 丢失函数（拆分必须零丢失）:"
  echo "$removed" | sed 's/^/      - /'
fi
[[ -z "$added" && -z "$removed" ]] && echo "    函数名集合：完全一致"
echo

# ---- 3b) 共有函数的函数体逐字比对（这是「纯搬运」的硬证据）----
# ALLOW_CHANGED_FNS：空格分隔的「预期改动函数」白名单。
#   阶段 1（纯拆分）应为空；阶段 2/3 有意改动某函数时填入 → 其余函数仍受强保证。
echo "    共有函数体逐字比对（${n_cur} 个中的共有部分）..."
body_diff=0
changed_fns=""
while IFS= read -r fn; do
  [[ -n "$fn" ]] || continue
  if ! diff -q <(fn_block "$BASE" "$fn") <(fn_block "$CUR" "$fn") >/dev/null 2>&1; then
    if grep -qw "$fn" <<<"${ALLOW_CHANGED_FNS:-}"; then
      echo "      ~ ${fn} 已改动（ALLOW_CHANGED_FNS 已声明）"
      changed_fns="${changed_fns}${fn} "
    else
      echo "      ✗ ${fn} 函数体有改动（未声明）"
      diff -u <(fn_block "$BASE" "$fn") <(fn_block "$CUR" "$fn") | head -20 | sed 's/^/          /'
      body_diff=$((body_diff + 1))
    fi
  fi
done <<< "$common"

echo
if [[ "$body_diff" -eq 0 ]]; then
  echo "    ✓ 未声明改动的函数体逐字相同（共 ${n_base} 个原函数）"
  [[ -n "$changed_fns" ]] && echo "    已声明改动: ${changed_fns}"
else
  echo "    ✗ ${body_diff} 个函数体被改动（未声明）"
fi

# ---- 3c) 判定 ----
# ALLOW_NEW_FNS：空格分隔的「预期新增函数」白名单。
#   阶段 1（纯拆分）应为空（只有 usage 恒允许）；
#   阶段 3（加新功能）填入新函数名 → 仍守住「原函数体零改动」这个强保证。
EXPECTED_ADDED="usage ${ALLOW_NEW_FNS:-}"
unexpected_added=""
if [[ -n "$added" ]]; then
  while IFS= read -r fn; do
    [[ -n "$fn" ]] || continue
    if ! grep -qw "$fn" <<<"$EXPECTED_ADDED"; then
      unexpected_added="${unexpected_added}${fn}"$'\n'
    fi
  done <<< "$added"
fi

if [[ -n "$unexpected_added" ]]; then
  echo "    ✗ 未预期的函数新增（若非有意，请检查是否误引入）:"
  echo "$unexpected_added" | grep -v '^$' | sed 's/^/      ? /'
  echo "      （如属有意新增，用 ALLOW_NEW_FNS=\"<名字>\" 显式声明）"
fi

if [[ "$body_diff" -eq 0 && -z "$removed" && -z "$unexpected_added" ]]; then
  echo
  echo "=== 结果: PASS ==="
  echo "    原函数体零改动；新增函数: ${added:-无}"
  exit 0
else
  echo
  echo "=== 结果: FAIL ==="
  exit 1
fi
