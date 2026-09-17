#!/usr/bin/env bash
# ============================================================
# docker-install 模块：非暴露模式（lockdown）
#
# 语义：容器端口仅服务器本地可访问，公网完全不可达。
#       对应生产实践「-p 127.0.0.1:8080:80 + Nginx 统一网关，对外只开 443」。
#
# 实现：逐条撤销 ufw 转发放行（含历史手工/上一轮遗留的），确保零放行。
#   ⚠️ 必须走 `ufw route delete`（改 /etc/ufw/user.rules 配置），
#      不能只 `iptables -F`：内核链只是 ufw 配置的渲染产物，
#      只清内核不改配置 → 下次 ufw reload/重启时放行规则【原地复活】
#      （真机实测：reload 后放行数从 0 回到 1）。
# ============================================================

# ---------- 枚举 ufw 转发放行（读内核） ----------
# 输出每行: <family> <规则文本>
fw_route_allows() {
  local fam
  for fam in iptables ip6tables; do
    command -v "$fam" >/dev/null 2>&1 || continue
    local chain=ufw-user-forward
    [[ "$fam" == "ip6tables" ]] && chain=ufw6-user-forward
    "$fam" -S "$chain" 2>/dev/null | grep '^-A' | while read -r line; do
      printf '%s %s\n' "$fam" "$line"
    done
  done
}

# ---------- 从内核规则文本反解 ufw route delete 参数并删除 ----------
# 输入行例: -A ufw-user-forward -p tcp -d 172.17.0.3 --dport 80 -j ACCEPT
#           -A ufw-user-forward -p udp --dport 53 -j ACCEPT
fw_route_delete_from_rule() {
  local rule="$1"
  local proto="" dst="" dport=""
  local -a tok=()
  read -r -a tok <<< "$rule"
  local i
  for ((i = 0; i < ${#tok[@]}; i++)); do
    case "${tok[i]}" in
      -p)      proto="${tok[i+1]}" ;;
      -d)      dst="${tok[i+1]}" ;;
      --dport) dport="${tok[i+1]}" ;;
    esac
  done
  [[ -n "$dport" ]] || return 1

  local -a args=(route delete allow proto "${proto:-tcp}" from any)
  if [[ -n "$dst" ]]; then args+=(to "$dst"); else args+=(to any); fi
  args+=(port "$dport")

  ufw "${args[@]}" >/dev/null 2>&1 && return 0
  # 回退：按端口 + 任意目标再试（目标格式差异时）
  ufw route delete allow proto "${proto:-tcp}" from any to any port "$dport" >/dev/null 2>&1
}

# ---------- 计数辅助（grep -c 无匹配时退出 1，需只取首行防 "0\n0"） ----------
_route_conf_count() {
  local f="$1"
  [[ -f "$f" ]] || { echo 0; return 0; }
  local n; n="$(grep -c '^-A ufw-user-forward' "$f" 2>/dev/null | head -1)"
  echo "${n:-0}"
}

# ---------- 非暴露模式 ----------
fw_lockdown() {
  require_root
  local st; st="$(fw_state)"
  case "$st" in
    protected) ;;
    bypassed|bypassed6)
      log_warn "尚未加固 —— 先执行 firewall fix"
      fw_fix || return 1
      ;;
    *)
      log_err "当前状态不支持 lockdown（状态=${st}）"
      log_err "请先确保 UFW 已启用且 Docker 已安装，再重跑"
      return 1
      ;;
  esac

  # 1) 逐条撤销转发放行（改配置，持久）
  local total=0 failed=0 fam rule
  while read -r fam rule; do
    [[ -n "$rule" ]] || continue
    total=$((total + 1))
    if fw_route_delete_from_rule "$rule"; then
      log_info "已撤销放行: ${rule#-A }"
    else
      failed=$((failed + 1))
      log_warn "撤销失败: ${rule#-A }"
    fi
  done < <(fw_route_allows)

  if [[ "$total" -eq 0 ]]; then
    log_info "无转发放行规则（本就未暴露任何容器端口）"
  elif [[ "$failed" -eq 0 ]]; then
    log_ok "已撤销 ${total} 条转发放行（容器端口不再对公网开放）"
  fi

  # 2) 复核：内核 + 配置双查
  local kern conf
  kern="$(fw_route_allows | wc -l | tr -d ' ')"
  conf="$(_route_conf_count "${DI_UFW_USER_RULES}")"
  if [[ "${kern:-0}" -eq 0 && "${conf:-0}" -eq 0 ]]; then
    log_ok "复核通过: 内核与配置均无转发放行（持久生效）"
  else
    log_err "复核失败: 内核 ${kern} 条 / 配置 ${conf} 条残留"
    return 1
  fi

  # 3) reload 后再查（防「只清内核、配置未改」的假成功）
  if ufw reload >/dev/null 2>&1; then
    local after
    after="$(fw_route_allows | wc -l | tr -d ' ')"
    if [[ "${after:-0}" -eq 0 ]]; then
      log_ok "reload 复核通过: 放行规则未复活"
    else
      log_err "reload 后放行规则复活（${after} 条）—— 配置未清干净"
      return 1
    fi
  fi

  log_info "已发布端口当前仅服务器本地可访问（如 127.0.0.1:8080）"
  log_info "对外暴露请走统一网关（Nginx 反代 → 只开 443），不要直接放行容器端口"
  return 0
}
