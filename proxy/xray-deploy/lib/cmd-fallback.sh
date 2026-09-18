#!/usr/bin/env bash
# cmd-fallback.sh — fallback-test：回落域名握手延迟测试（独立子命令，不影响部署状态）

# ============ 回落域名测试（独立功能） ============
# 测试候选回落域名的握手延迟并排序，供部署前选型/诊断用（不影响部署状态）
cmd_fallback_test() {  # $1=可选域名（测单个）；无参 = 测全部候选
  local target="${1:-}" dom c t note i result delay
  local -a pass_list=() fail_list=()

  log_info "回落域名握手延迟测试（TLS1.3+H2+X25519+非跳转+非Cloudflare）..."

  if [[ -n "$target" ]]; then
    # 单域名模式：直接测试指定域名
    # || true：函数失败(return 1)时命令替换会触发 set -e，必须显式吞掉
    result="$(test_fallback_domain "$target")" || true
    if [[ "$result" == "ok" ]]; then
      delay="$(measure_handshake_ms "$target")" || true
      pass_list+=("$target|自定义|$delay")
      log_info "  ✓ ${target} — ${delay}ms"
    else
      fail_list+=("$target")
      log_warn "  ✗ ${target} — ${result}"
    fi
  else
    # 全部候选模式：逐个测试并立即显示结果（避免长耗时无反馈）
    for line in "${FALLBACK_CANDIDATES[@]}"; do
      IFS='|' read -r dom c t note <<<"$line"
      log_info "  → ${dom}  (${note}) 测试中..."
      result="$(test_fallback_domain "$dom")" || true
      if [[ "$result" == "ok" ]]; then
        delay="$(measure_handshake_ms "$dom")" || true
        pass_list+=("$dom|$note|$delay")
        log_info "  ✓ ${dom}  (${note}) — ${delay}ms"
      else
        fail_list+=("$dom")
        log_warn "  ✗ ${dom} — ${result}"
      fi
    done
  fi

  # 按延迟排序展示通过的
  if [[ ${#pass_list[@]} -gt 0 ]]; then
    IFS=$'\n' pass_list=($(printf '%s\n' "${pass_list[@]}" | sort -t'|' -k3,3n)); unset IFS
    log_info "通过候选按握手延迟排序（最低在前）:"
    for ((i=0; i<${#pass_list[@]}; i++)); do
      IFS='|' read -r dom note delay <<<"${pass_list[$i]}"
      log_info "  [$((i+1))] ${dom}  (${note}) ✓ ${delay}ms"
    done
  else
    log_err "无候选通过测试"
  fi

  [[ ${#pass_list[@]} -gt 0 ]]
}
