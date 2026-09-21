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
#   （当前为空 —— 2026-09-21 起 verify-xray-deploy-split.sh 已修好，见下）
# 注：上述套件必须在真的 FAIL 时退出非 0，否则 run-all 会误报 PASS（假绿）。
#     verify-nginx-install.sh 曾缺尾部 `[[ $FAIL -eq 0 ]]`，2026-09-19 修复。
#     2026-09-19 同时修复其 mock curl 缺 stdout 分支导致 install_self 断言恒 FAIL，
#     以及 install_self 依赖的新函数未纳入提取列表 → 该套件已 72/0 全绿，移出本列表。
#     2026-09-21：verify-xray-deploy-split.sh 的白名单改由
#     tests/lib/xray-deploy-allow.txt 单一权威源提供、套件自身也会自动读取
#     → canonical 入口下不再必然 FAIL，移出本列表。
#     **保持本列表为空**：留着任何一项都会让 run-all 的非零退出码失去「有回归」含义。
KNOWN_FAIL=''

# ⚠️ 聚合 runner 必须排除，否则其内部套件会被跑两遍（2026-09-21 实测）：
#   verify-xray-deploy-all.sh 是「xray 全部套件的串行 runner」，本身不是套件。
#   glob `tests/verify-*.sh` 会命中它 → behavior/chain/e2e/latest/mode-e2e/routing/
#   split/version-select/xhttp3-nginx 每个执行两次，其中 ~183s 是纯重复
#   （全量 8m47s → 去掉后约 2m）。
#   该 runner 仍可用 `bash tests/verify-xray-deploy-all.sh` 单独跑（只跑 xray 域）。
AGGREGATORS='verify-xray-deploy-all.sh'

npass=0; nfail=0; nskip=0; failed=""; skipped=""
for t in tests/verify-*.sh; do
  [[ -f "$t" ]] || continue
  name="$(basename "$t")"
  # 聚合 runner 跳过（其内容已由各自套件覆盖，跑它 = 重复执行）
  [[ " $AGGREGATORS " == *" $name "* ]] && continue
  [[ -n "$FILTER" && "$name" != *"$FILTER"* ]] && continue
  printf '%-42s ' "$name"
  # ⚠️ SKIP 是【第三态】，不能当 PASS（2026-09-21 实测）：
  #    套件缺依赖时 `echo SKIP; exit 0` → 退出码 0 → 旧实现打印 PASS，
  #    但实际【一条断言都没跑】（本机无 restic/rclone 时 vps-backup-e2e 的
  #    48 条真机断言长期静默未执行，报表却全绿）。看退出码分不出「跑了且过」
  #    与「根本没跑」。判据：输出里有 `SKIP` 且无 `PASS=` 汇总行。
  if ! bash "$t" > "/tmp/run-all.$$.out" 2>&1; then
    if [[ " $KNOWN_FAIL " == *" $name "* ]]; then
      printf 'KNOWN-FAIL（既存，非本轮）\n'
    else
      printf 'FAIL  ← 回归！%s\n' "$(grep -E '\[FAIL\]' "/tmp/run-all.$$.out" | head -1)"
    fi
    nfail=$((nfail+1)); failed="$failed $name"
  elif grep -qE '^SKIP|SKIP:' "/tmp/run-all.$$.out" \
       && ! grep -qE 'PASS=[0-9]+ FAIL=[0-9]+' "/tmp/run-all.$$.out"; then
    printf 'SKIP  ← 未执行（%s）\n' \
      "$(grep -oE 'SKIP[: ].*' "/tmp/run-all.$$.out" | head -1 | cut -c1-60)"
    nskip=$((nskip+1)); skipped="$skipped $name"
  else
    printf 'PASS  %s\n' "$(grep -oE 'PASS=[0-9]+ FAIL=[0-9]+' "/tmp/run-all.$$.out" | tail -1)"
    npass=$((npass+1))
  fi
done
rm -f "/tmp/run-all.$$.out"

echo "------------------------------------------------"
echo "套件: 通过 $npass / 失败 $nfail / 跳过 $nskip"
[[ -n "$failed" ]] && echo "失败:$failed"
[[ -n "$skipped" ]] && echo "跳过（未跑任何断言，不计入通过）:$skipped"
exit $(( nfail > 0 ? 1 : 0 ))
