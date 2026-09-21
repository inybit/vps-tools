#!/usr/bin/env bash
# xray-deploy 全量回归入口（一次跑完所有 harness）
#
# 用法: bash tests/verify-xray-deploy-all.sh
# 退出码: 0=全部通过
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

TOTAL_PASS=0; TOTAL_FAIL=0; SUITES=0; FAILED_SUITES=""

run() {  # $1=名称 $2=脚本 $3...=环境变量
  local name="$1"; shift
  local script="$1"; shift
  echo "───────────────────────────────────────────────"
  echo "▶ ${name}"
  echo "───────────────────────────────────────────────"
  SUITES=$((SUITES+1))
  if env "$@" bash "$script" > "/tmp/xd-${SUITES}.log" 2>&1; then
    local p
    p="$(grep -oP 'PASS=\K[0-9]+' "/tmp/xd-${SUITES}.log" | tail -1)"
    echo "  ✓ PASS (${p:-?} 断言)"
    TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
  else
    local p f
    p="$(grep -oP 'PASS=\K[0-9]+' "/tmp/xd-${SUITES}.log" | tail -1)"
    f="$(grep -oP 'FAIL=\K[0-9]+' "/tmp/xd-${SUITES}.log" | tail -1)"
    echo "  ✗ FAIL (PASS=${p:-?} FAIL=${f:-?})  日志: /tmp/xd-${SUITES}.log"
    grep -E '\[FAIL\]' "/tmp/xd-${SUITES}.log" | head -5 | sed 's/^/      /'
    TOTAL_PASS=$((TOTAL_PASS + ${p:-0}))
    TOTAL_FAIL=$((TOTAL_FAIL + ${f:-1}))
    FAILED_SUITES="${FAILED_SUITES} ${name}"
  fi
  echo
}

# ⚠️ 白名单的【单一权威源】= tests/lib/xray-deploy-allow.txt（2026-09-21 改）
#    原先只在 verify-xray-deploy-all.sh 里维护一份，而 run-all.sh 裸跑 split 套件
#    不传这两个变量 → 45 个已声明新增的函数全被判「未预期新增」→ 该套件在
#    canonical 入口下【必然 FAIL】→ run-all.sh 恒退非零 →
#    「非零 = 有回归」这个信号彻底失效（真回归会被淹没在既存红里）。
#    现在两个入口都从同一文件读，不再各维护一份。
ALLOW_FILE="${REPO}/tests/lib/xray-deploy-allow.txt"
_allowed_new() {
  awk '/^# === ALLOW_NEW/{f=1;next} /^# === ALLOW_CHANGED/{f=0} f && !/^#/ && NF {print}' "$ALLOW_FILE" | tr '\n' ' '
}
_allowed_changed() {
  awk '/^--- CHANGED ---/{f=1;next} f && !/^#/ && NF {print}' "$ALLOW_FILE" | tr '\n' ' '
}

run "拆分等价性（73 原函数体逐字相同）" tests/verify-xray-deploy-split.sh \
    ALLOW_NEW_FNS="$(_allowed_new)" ALLOW_CHANGED_FNS="$(_allowed_changed)"
run "行为等价（入口/错误路径/真实函数）" tests/verify-xray-deploy-behavior.sh
run "latest 修复 + 防降级" tests/verify-xray-deploy-latest.sh
run "ss2022 + chain 配置生成（含真实 xray -test）" tests/verify-xray-deploy-chain.sh
run "分流模式（各 mode 规则形态 + 真实 xray -test）" tests/verify-xray-deploy-routing.sh
run "xhttp3-nginx 协议（触点/nginx 门/冲突/unit/info）" tests/verify-xray-deploy-xhttp3-nginx.sh
run "安装版本选择（分界判定/菜单/警示）" tests/verify-xray-deploy-version-select.sh
run "端到端链路（真实三方 xray 进程，loopback）" tests/verify-xray-deploy-e2e.sh
run "端到端分流切换（真实 xray 决策日志验证）" tests/verify-xray-deploy-mode-e2e.sh

echo "═══════════════════════════════════════════════"
printf ' 套件: %d   断言通过: %d   失败: %d\n' "$SUITES" "$TOTAL_PASS" "$TOTAL_FAIL"
[[ -n "$FAILED_SUITES" ]] && echo " 失败套件:${FAILED_SUITES}"
echo "═══════════════════════════════════════════════"
[[ "$TOTAL_FAIL" -eq 0 ]]
