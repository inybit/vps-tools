#!/usr/bin/env bash
# cmd-fallback.sh — fallback-test：回落域名握手延迟测试（独立子命令，不影响部署状态）
#
# 范围口径（2026-10-15 用户要求）：
#   回落域只需「贴近本机（VPS 所在地）」——测别的地区候选毫无意义（跨洲握手延迟天然高、
#   且真正要规避的 SNI 阻断是国内方向，见 fallback-cn-test）。
#   故无参默认 = **本机所在地区的全部候选**，与部署向导 select_fallback_domain 同口径。
#   候选表 121 条 / 10 个地区，全测约需半小时；跨地区要显式 --all。

# 解析参数：--region <CC> / --all / <域名>
# 输出到 stdout: "region|CC" / "all|" / "domain|<域名>"；非法输入 → return 1
_fallback_test_target() {
  local arg1="${1:-}" arg2="${2:-}"
  case "$arg1" in
    "")            echo "region|$(detect_server_country)" ; return 0 ;;
    --all)         echo "all|" ; return 0 ;;
    --region|-r)
      if [[ ! "${arg2^^}" =~ ^[A-Z]{2}$ ]]; then
        log_err "--region 需要两位国家码（如 --region DE），收到: ${arg2:-<空>}"
        return 1
      fi
      echo "region|${arg2^^}" ; return 0 ;;
    -*)            log_err "未知选项: ${arg1}（支持 --region <CC> / --all / <域名>）" ; return 1 ;;
    *)             echo "domain|${arg1}" ; return 0 ;;
  esac
}

# 测试一个域名并登记结果（$1=域名 $2=备注；通过则追加到 pass_list，否则追加 fail_list）
_fallback_test_one() {
  local dom="$1" note="$2" result delay
  log_info "  → ${dom}  (${note}) 测试中..."
  result="$(test_fallback_domain "$dom")" || true   # 防 set -e：失败(return 1)会终止脚本
  if [[ "$result" == "ok" ]]; then
    delay="$(measure_handshake_ms "$dom")" || true
    pass_list+=("$dom|$note|$delay")
    log_info "  ✓ ${dom}  (${note}) — ${delay}ms"
  else
    fail_list+=("$dom")
    log_warn "  ✗ ${dom} — ${result}"
  fi
}

cmd_fallback_test() {  # $1=可选（域名 / --region <CC> / --all）；无参 = 本地区全部候选
  local target plan kind value dom note i result delay line
  local -a pass_list=() fail_list=() domains=() notes=()

  plan="$(_fallback_test_target "${1:-}" "${2:-}")" || return 1
  kind="${plan%%|*}"; value="${plan#*|}"

  case "$kind" in
    domain)
      log_info "回落域名握手延迟测试（TLS1.3+H2+X25519+非跳转+非Cloudflare）..."
      _fallback_test_one "$value" "自定义"
      ;;
    region)
      log_info "回落域名握手延迟测试（TLS1.3+H2+X25519+非跳转+非Cloudflare）..."
      log_info "地区: ${value}（本机所在地；跨地区请用 --all）"
      # 逐行读入，避免把多行输出拆成数组元素时丢备注
      while IFS='|' read -r dom note; do
        [[ -n "$dom" ]] || continue
        domains+=("$dom"); notes+=("$note")
      done < <(fallback_region_candidates "$value" || true)
      if [[ ${#domains[@]} -eq 0 ]]; then
        log_err "候选表中无 ${value} 地区域名；可用 --region <CC> 指定其他地区，或 --all 测全部候选"
        return 1
      fi
      log_info "本地区候选 ${#domains[@]} 个（tier5 大厂已排除）"
      for ((i=0; i<${#domains[@]}; i++)); do
        _fallback_test_one "${domains[$i]}" "${notes[$i]}"
      done
      ;;
    all)
      log_info "回落域名握手延迟测试（TLS1.3+H2+X25519+非跳转+非Cloudflare）..."
      log_warn "跨地区全量模式：候选表 ${#FALLBACK_CANDIDATES[@]} 条（含 10 个地区），耗时较长"
      for line in "${FALLBACK_CANDIDATES[@]}"; do
        IFS='|' read -r dom _ _ note <<<"$line"
        _fallback_test_one "$dom" "$note"
      done
      ;;
  esac

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
