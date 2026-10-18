#!/usr/bin/env bash
# ============================================================
# 元测试：回归套件必须遵守「三态协议」
#
# 背景（2026-10-19 实测）：main 上 `bash tests/run-all.sh` 有 5 个红，逐个定位
# 后发现【零个产品 bug】——全是协议违规：
#   · e2e 套件缺 xray 二进制 → exit 1（应 SKIP）→ 每个没装 xray 的机器恒红
#   · hy2-pin 缺 PyYAML → 断言拿到空值 → FAIL（应 SKIP）
#   · split 套件没有 PASS=/FAIL= 汇总行 → run-all 打印 'PASS ' 带空统计
#   · selfupdate 断言停留在旧语义 → FAIL
# 后果不只是「多几条红」：run-all 的语义是「非零退出 = 有回归」，
# 一旦常红，真回归就会被淹没在既存红里 —— 这个信号一旦失真，整仓就没有门禁。
#
# 本套件把「协议」变成可执行断言，防止再退化：
#   P1 每个套件都输出 `PASS=n FAIL=m` 汇总行（run-all 的判据）
#   P2 缺依赖必须 SKIP + exit 0，不得 `需要...; exit 1`
#   P3 run-all.sh 的 KNOWN_FAIL 必须为空（非空 = 已有既存红）
#   P4 每个套件都 `set -uo pipefail`（否则管道错误被吞）
#   P5 聚合 runner 必须登记在 run-all 的 AGGREGATORS 里（否则重复执行）
#
# 用法: bash tests/verify-suite-protocol.sh
# 退出码: 0=全部通过
# ============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

PASS=0; FAIL=0
ck(){ if [[ "$2" == "$3" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
      else printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi; }
ckz(){ if [[ -z "$2" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
      else printf '  [FAIL] %s\n         违规文件: %s\n' "$1" "$2"; FAIL=$((FAIL+1)); fi; }

echo "=== 回归套件三态协议检查 ==="
echo

# 聚合 runner 不是套件（它串行跑别的套件），不要求汇总行
AGG='tests/verify-xray-deploy-all.sh'

# ---------- P1: 汇总行 ----------
echo "[P1] 每个套件输出 PASS=n FAIL=m 汇总行"
missing=""
for t in tests/verify-*.sh; do
  [[ -f "$t" ]] || continue
  [[ "$t" == "$AGG" ]] && continue
  # 汇总行可以是字面 echo " PASS=${PASS} FAIL=${FAIL}" 或 printf 形式
  if ! grep -qE 'PASS=\$\{?PASS|PASS=%|" ?PASS=' "$t"; then
    missing="${missing} ${t#tests/}"
  fi
done
ckz "无缺失汇总行的套件" "$missing"
echo

# ---------- P2: 缺依赖 → SKIP，不是 exit 1 ----------
echo "[P2] 缺依赖走 SKIP（exit 0），不得判 FAIL"
# 匹配「提示缺依赖」紧接 exit 1 的写法：需要...; exit 1 / 未找到...; exit 1
bad_skip=""
for t in tests/verify-*.sh; do
  [[ -f "$t" ]] || continue
  [[ "$t" == "$AGG" || "$t" == "tests/verify-suite-protocol.sh" ]] && continue
  # 只看非注释行（注释里会引用反面写法）
  hit="$(grep -vE '^[[:space:]]*#' "$t" \
         | grep -cE '(需要|未找到|找不到|missing)[^;]*;[[:space:]]*exit 1')"
  [[ "${hit:-0}" -gt 0 ]] && bad_skip="${bad_skip} ${t#tests/}"
done
ckz "无「缺依赖即 exit 1」写法" "$bad_skip"
# SKIP 必须是独立第三态：输出含 SKIP 且退出 0（静态检查脚本里有 SKIP 字样）
skip_literal="$(grep -lE 'echo "SKIP' tests/verify-*.sh 2>/dev/null | wc -l)"
if [[ "$skip_literal" -ge 1 ]]; then
  printf '  [PASS] 至少一个套件实现了 SKIP 第三态（%s 个）\n' "$skip_literal"; PASS=$((PASS+1))
else
  printf '  [FAIL] 没有任何套件实现 SKIP 第三态\n'; FAIL=$((FAIL+1))
fi
echo

# ---------- P3: KNOWN_FAIL 为空 ----------
echo "[P3] run-all.sh 的 KNOWN_FAIL 必须为空"
kf="$(sed -n "s/^KNOWN_FAIL='\(.*\)'$/\1/p" tests/run-all.sh | head -1)"
ckz "KNOWN_FAIL 为空（非空说明已有既存红）" "$kf"
echo

# ---------- P4: set -uo pipefail ----------
echo "[P4] 每个套件声明 set -uo pipefail"
noset=""
for t in tests/verify-*.sh; do
  [[ -f "$t" ]] || continue
  grep -q '^set -uo pipefail' "$t" || noset="${noset} ${t#tests/}"
done
ckz "无缺失 set -uo pipefail 的套件" "$noset"
echo

# ---------- P5: 聚合 runner 已登记 ----------
echo "[P5] 聚合 runner 登记在 run-all 的 AGGREGATORS"
agg_line="$(sed -n "s/^AGGREGATORS='\(.*\)'$/\1/p" tests/run-all.sh | head -1)"
ck "verify-xray-deploy-all.sh 已登记" \
   "$(grep -c 'verify-xray-deploy-all.sh' <<<"$agg_line")" "1"
echo

echo "==================================="
echo " PASS=${PASS} FAIL=${FAIL}"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
