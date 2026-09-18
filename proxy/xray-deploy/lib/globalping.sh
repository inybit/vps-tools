#!/usr/bin/env bash
# globalping.sh — 回落域名中国方向可达性检测（Globalping 公共探针 API）
#
# 为什么需要：test_fallback_domain / measure_handshake_ms 都从 VPS 视角探测，
#   测不到中国方向。回落域若被 GFW 在 SNI/TLS 层阻断，国内用户首连必失败，
#   而 ICMP 通不代表 HTTPS 通 → 必须发真实 HTTPS 请求才能暴露。
#
# ⚠️ 数据出境：提交前必须经 gp_confirm_egress 显式确认（默认拒绝，无 TTY 亦拒绝；
#    自动化用 CN_TEST_ASSUME_YES=1 放行）。域名会出境并留存于 Globalping 公开记录。

# ============ 回落域名中国方向可达性检测（Globalping） ============
# 为什么需要：test_fallback_domain / measure_handshake_ms 都从本机（VPS）视角探测，
#   测不到中国方向。回落域若被 GFW 阻断（SNI/TLS 层），国内用户首连必失败——
#   ICMP 通不代表 HTTPS 通，必须发真实 HTTPS 请求才能暴露。
# 实现：Globalping 公共探针 API（中国三网 eyeball 探针），只读检测，不改部署状态。
# 注意：外部 API，需公网可达；速率限制 250 次/小时，每域名消耗 2 次测量（ping + http）。
#   故本命令不并入 install/proto_* 默认流程，且无参时只测 tier4（已实测可用）候选。
# 数据出境：提交前必须经 gp_confirm_egress 显式确认（默认拒绝，无 TTY 亦拒绝；
#   自动化用 CN_TEST_ASSUME_YES=1 放行）。域名会出境并留存于 Globalping 公开记录。
GP_API="https://api.globalping.io/v1"
GP_PROBES="${CN_PROBES:-8}"      # 探针数（中国区上限约 62）
GP_TIMEOUT="${CN_WAIT:-40}"      # 单次测量最长等待秒数

gp_submit() {  # $1=ping|http $2=target → 输出 measurement id（失败输出空串）
  local type="$1" target="$2" body
  if [[ "$type" == "http" ]]; then
    body="$(jq -nc --arg t "$target" --argjson n "$GP_PROBES" \
      '{type:"http",target:$t,locations:[{country:"CN",limit:$n}],measurementOptions:{protocol:"HTTPS",request:{path:"/"}}}')"
  else
    body="$(jq -nc --arg t "$target" --argjson n "$GP_PROBES" \
      '{type:"ping",target:$t,locations:[{country:"CN",limit:$n}],measurementOptions:{packets:3}}')"
  fi
  curl -sS --max-time 25 -X POST "${GP_API}/measurements" \
    -H 'Content-Type: application/json' -d "$body" 2>/dev/null \
    | jq -r '.id // empty' 2>/dev/null || true
}

gp_wait() {  # $1=id → 输出结果 JSON（轮询至 finished 或超时）
  local id="$1" elapsed=0 body=""
  while [[ $elapsed -lt $GP_TIMEOUT ]]; do
    body="$(curl -sS --max-time 25 "${GP_API}/measurements/${id}" 2>/dev/null || true)"
    [[ -n "$body" ]] || break
    [[ "$(jq -r '.status // ""' <<<"$body" 2>/dev/null || true)" == "finished" ]] && break
    sleep 3
    elapsed=$((elapsed + 3))
  done
  printf '%s' "$body"
}

gp_report() {  # $1=json $2=ping|http → stdout: "通过数/总数 [详情]"；返回 1 = 无数据
  local json="$1" kind="$2" tot ok detail=""
  tot="$(jq -r '(.results // []) | length' <<<"$json" 2>/dev/null || echo 0)"
  if [[ "${tot:-0}" -eq 0 ]]; then
    printf '无探针返回（提交失败/超限/未完成）'
    return 1
  fi
  if [[ "$kind" == "ping" ]]; then
    ok="$(jq -r '[.results[] | select((.result.status // "") == "finished" and (.result.stats.avg // null) != null)] | length' <<<"$json" 2>/dev/null || echo 0)"
    detail="$(jq -r '[.results[] | select((.result.status // "") == "finished") | (.result.stats.avg // empty)] | if length > 0 then "平均 RTT " + (((add / length) * 10 | floor) / 10 | tostring) + "ms" else "" end' <<<"$json" 2>/dev/null || true)"
  else
    ok="$(jq -r '[.results[] | select((.result.status // "") == "finished" and (.result.headers // null) != null)] | length' <<<"$json" 2>/dev/null || echo 0)"
    detail="$(jq -r '[.results[].result.statusCode // empty] | unique | map(tostring) | if length > 0 then "HTTP " + join("/") else "" end' <<<"$json" 2>/dev/null || true)"
  fi
  printf '%s/%s 通过' "$ok" "$tot"
  [[ -n "$detail" ]] && printf '（%s）' "$detail"
  return 0
}

gp_confirm_egress() {  # $@=待提交域名；返回 0=同意，1=取消
  # 数据出境显式确认（2026-09-17 用户要求）：Globalping 是第三方公共 API，
  #   域名会被提交出境并留存在其公开测量记录里，必须让用户明确知情后再发。
  # 默认拒绝（fail-closed）：无 TTY、回车、非 y 一律取消，不提交任何数据。
  # 自动化场景用 CN_TEST_ASSUME_YES=1 显式放行。
  local yn
  log_warn "数据出境提示：本命令将把下列域名提交给第三方服务 Globalping（api.globalping.io）"
  log_warn "  · 提交内容：域名 + 请求类型（ping / HTTPS GET /），不含服务器 IP、密钥、节点信息"
  log_warn "  · 执行位置：Globalping 中国三网 eyeball 探针；结果会留存在其公开测量记录中"
  log_warn "  · 性质：只读检测，不修改本机部署状态"
  log_warn "  · 待提交域名（${#} 个）：$*"
  if [[ "${CN_TEST_ASSUME_YES:-0}" == "1" ]]; then
    log_info "已通过 CN_TEST_ASSUME_YES=1 跳过确认（自动化场景）"
    return 0
  fi
  read_input "确认将上述域名提交至 Globalping 检测？[y/N]: " yn || return 1
  [[ "${yn,,}" == "y" ]] || return 1
  return 0
}

cmd_fallback_cn_test() {  # $1=可选域名（测单个）；无参 = 测 tier4 候选
  local target="${1:-}" dom c t note
  command -v curl >/dev/null 2>&1 || die "需要 curl"
  command -v jq   >/dev/null 2>&1 || die "需要 jq"

  local -a domains=()
  if [[ -n "$target" ]]; then
    domains=("$target")
  else
    for line in "${FALLBACK_CANDIDATES[@]}"; do
      IFS='|' read -r dom c t note <<<"$line"
      [[ "$t" == "4" ]] && domains+=("$dom")
    done
    [[ ${#domains[@]} -gt 0 ]] || die "候选表中无 tier4 域名"
  fi
  # 去重（候选表可能跨地区重复同一域名）
  local -a uniq_domains=()
  while IFS= read -r dom; do uniq_domains+=("$dom"); done < <(printf '%s\n' "${domains[@]}" | awk '!seen[$0]++')

  gp_confirm_egress "${uniq_domains[@]}" || { log_warn "已取消，未提交任何数据（同意请输 y）"; return 1; }
  echo >&2

  log_info "回落域名中国方向可达性检测（Globalping 中国三网探针）"
  log_info "探针数 ${GP_PROBES}，超时 ${GP_TIMEOUT}s；每域名消耗 2 次测量（限 250/时，本次约 $(( ${#uniq_domains[@]} * 2 )) 次）"
  log_info "判据：HTTPS 通过率高 = 可作 REALITY 回落；HTTPS 低而 ICMP 高 = 存在 SNI/TLS 阻断"
  echo >&2

  local -a rows=()
  local ok_http=0
  for dom in "${uniq_domains[@]}"; do
    local id_icmp id_http icmp_res http_res
    log_info "→ ${dom} 探测中..."
    id_icmp="$(gp_submit ping "$dom")"
    if [[ -z "$id_icmp" ]]; then
      icmp_res="提交失败（网络/限流）"
    else
      icmp_res="$(gp_report "$(gp_wait "$id_icmp")" ping || true)"
    fi
    id_http="$(gp_submit http "$dom")"
    if [[ -z "$id_http" ]]; then
      http_res="提交失败（网络/限流）"
    else
      http_res="$(gp_report "$(gp_wait "$id_http")" http || true)"
    fi
    log_info "  ICMP: ${icmp_res}"
    log_info "  HTTPS: ${http_res}"
    rows+=("${dom}|${icmp_res}|${http_res}")
    [[ "$http_res" =~ ^([0-9]+)/([0-9]+) ]] && [[ "${BASH_REMATCH[2]}" -gt 0 ]] && \
      [[ $(( BASH_REMATCH[1] * 100 / BASH_REMATCH[2] )) -ge 80 ]] && ok_http=$((ok_http + 1))
    echo >&2
  done

  log_info "汇总（HTTPS ≥80% 视为中国方向可用）:"
  local row rdom ricmp rhttp
  for row in "${rows[@]}"; do
    IFS='|' read -r rdom ricmp rhttp <<<"$row"
    log_info "  ${rdom}  ICMP: ${ricmp}  HTTPS: ${rhttp}"
  done
  log_info "结论：${ok_http}/${#uniq_domains[@]} 个域名 HTTPS 通过率 ≥80%"
  log_info "提示：结果仅代表本次探针采样；入库前仍应在 VPS 上 fallback-test 复核握手延迟"
  [[ "$ok_http" -gt 0 ]]
}
