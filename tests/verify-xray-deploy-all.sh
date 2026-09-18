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

# ⚠️ build_routing_rules_json 在【拆分前基线】里不存在（阶段 3 新增）→ 必须放 ALLOW_NEW。
#    放 ALLOW_CHANGED 会被判定为"未预期新增"而 FAIL（本次踩过）。
ALLOW_NEW="ver_gt gen_ss2022_key select_ss2022_method proto_wizard_ss2022 validate_ss2022_key gen_client_mihomo_ss2022 gen_client_singbox_ss2022 gen_outbound_ss2022 gen_landing_outbound gen_outbound_vless_reality chain_export chain_validate_upstream chain_set_upstream chain_import chain_setup chain_remove chain_show chain_test build_outbounds_json build_routing_rules_json routing_preset_domains routing_preset_list routing_current_mode chain_mode_show chain_mode"
ALLOW_CHANGED="latest_xray_tag cmd_upgrade build_config proto_add proto_list_names cmd_install cmd_info gen_client_mihomo gen_client_singbox protocol_to_inbound"

run "拆分等价性（73 原函数体逐字相同）" tests/verify-xray-deploy-split.sh \
    ALLOW_NEW_FNS="$ALLOW_NEW" ALLOW_CHANGED_FNS="$ALLOW_CHANGED"
run "行为等价（入口/错误路径/真实函数）" tests/verify-xray-deploy-behavior.sh
run "latest 修复 + 防降级" tests/verify-xray-deploy-latest.sh
run "ss2022 + chain 配置生成（含真实 xray -test）" tests/verify-xray-deploy-chain.sh
run "分流模式（各 mode 规则形态 + 真实 xray -test）" tests/verify-xray-deploy-routing.sh
run "端到端链路（真实三方 xray 进程，loopback）" tests/verify-xray-deploy-e2e.sh
run "端到端分流切换（真实 xray 决策日志验证）" tests/verify-xray-deploy-mode-e2e.sh

echo "═══════════════════════════════════════════════"
printf ' 套件: %d   断言通过: %d   失败: %d\n' "$SUITES" "$TOTAL_PASS" "$TOTAL_FAIL"
[[ -n "$FAILED_SUITES" ]] && echo " 失败套件:${FAILED_SUITES}"
echo "═══════════════════════════════════════════════"
[[ "$TOTAL_FAIL" -eq 0 ]]
