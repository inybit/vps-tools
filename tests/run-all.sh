#!/usr/bin/env bash
# ============================================================
# vps-tools 全量回归入口（canonical test runner）
#
# 用法:  bash tests/run-all.sh            # 全量
#        bash tests/run-all.sh backup     # 只跑匹配 "backup" 的套件
# 退出码: 0 = 全部通过；1 = 有套件失败
#
# 为什么需要它：各 verify-*.sh 分散，改动后容易漏跑；
# 且「哪些失败是本轮引入的」需要改动前后的对照基线。
# ============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1
FILTER="${1:-}"

# 真机 E2E 需要真实 restic/rclone；缺失时该套件自行 SKIP（exit 0）
RESTIC_BIN="${RESTIC_BIN:-$(command -v restic 2>/dev/null || true)}"
RCLONE_BIN="${RCLONE_BIN:-$(command -v rclone 2>/dev/null || true)}"
[[ -n "$RESTIC_BIN" ]] && export RESTIC_BIN
[[ -n "$RCLONE_BIN" ]] && export RCLONE_BIN

# 已知既存失败（与本轮改动无关，勿当成回归）：
#   verify-xray-deploy-split.sh  — 新增函数白名单（拆分等价性基线，历史遗留）
# 注：上述套件必须在真的 FAIL 时退出非 0，否则 run-all 会误报 PASS（假绿）。
#     verify-nginx-install.sh 曾缺尾部 `[[ $FAIL -eq 0 ]]`，2026-09-19 修复。
#     2026-09-19 同时修复其 mock curl 缺 stdout 分支导致 install_self 断言恒 FAIL，
#     以及 install_self 依赖的新函数未纳入提取列表 → 该套件已 72/0 全绿，移出本列表。
KNOWN_FAIL='verify-xray-deploy-split.sh'

# ⚠️ 聚合 runner 必须排除，否则其内部套件会被跑两遍（2026-09-21 实测）：
#   verify-xray-deploy-all.sh 是「xray 全部套件的串行 runner」，本身不是套件。
#   glob `tests/verify-*.sh` 会命中它 → behavior/chain/e2e/latest/mode-e2e/routing/
#   split/version-select/xhttp3-nginx 每个执行两次，其中 ~183s 是纯重复
#   （全量 8m47s → 去掉后约 2m）。
#   该 runner 仍可用 `bash tests/verify-xray-deploy-all.sh` 单独跑（只跑 xray 域）。
AGGREGATORS='verify-xray-deploy-all.sh'

npass=0; nfail=0; failed=""
for t in tests/verify-*.sh; do
  [[ -f "$t" ]] || continue
  name="$(basename "$t")"
  # 聚合 runner 跳过（其内容已由各自套件覆盖，跑它 = 重复执行）
  [[ " $AGGREGATORS " == *" $name "* ]] && continue
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  printf '%-42s ' "$name"
  if bash "$t" > "/tmp/run-all.$$.out" 2>&1; then
    printf 'PASS  %s\n' "$(grep -oE 'PASS=[0-9]+ FAIL=[0-9]+' "/tmp/run-all.$$.out" | tail -1)"
    npass=$((npass+1))
  else
    if [[ " $KNOWN_FAIL " == *" $name "* ]]; then
      printf 'KNOWN-FAIL（既存，非本轮）\n'
    else
      printf 'FAIL  ← 回归！%s\n' "$(grep -E '\[FAIL\]' "/tmp/run-all.$$.out" | head -1)"
    fi
    nfail=$((nfail+1)); failed="$failed $name"
  fi
done
rm -f "/tmp/run-all.$$.out"

echo "------------------------------------------------"
echo "套件: 通过 $npass / 失败 $nfail"
[[ -n "$failed" ]] && echo "失败:$failed"
exit $(( nfail > 0 ? 1 : 0 ))
