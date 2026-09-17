#!/usr/bin/env bash
# ============================================================
# docker-install 模块：Docker × UFW —— 状态探测与报告
#
# 原理（Docker 官方文档 packet-filtering-firewalls.md）：
#   Docker 走 nat 表 DNAT，包在到达 ufw 的 INPUT/OUTPUT 链之前就被转发，
#   因此 ufw 的 allow 规则对「已发布端口」无效 → 必须把策略加到 DOCKER-USER 链
#   （DOCKER-USER 是官方给用户预留、且在 Docker 自身规则之前处理的唯一入口）。
#
# 铁律：判定状态读内核实际规则（iptables -S DOCKER-USER），不读文件、不信回显。
# ============================================================

# ---------- 状态探测：读内核 ----------
# 输出: no_ufw | ufw_inactive | nft_backend | no_docker | protected | bypassed
fw_state() {
  command -v ufw >/dev/null 2>&1 || { echo "no_ufw"; return 0; }
  if [[ "$(detect_firewall_backend)" == "nftables" ]]; then echo "nft_backend"; return 0; fi
  if ! ufw status 2>/dev/null | grep -q 'Status: active'; then echo "ufw_inactive"; return 0; fi
  # Docker 未安装时 DOCKER-USER 不存在是正常的（链由 Docker 创建），不是「绕过」
  if ! docker_installed; then echo "no_docker"; return 0; fi
  local rules
  rules="$(iptables -S DOCKER-USER 2>/dev/null || true)"
  if [[ -z "$rules" ]]; then echo "bypassed"; return 0; fi
  if echo "$rules" | grep -q 'ufw-user-forward' && echo "$rules" | grep -q 'ufw-docker-logging-deny'; then
    echo "protected"
  else
    echo "bypassed"
  fi
}

# ---------- 枚举实际暴露的公网可达端口（DNAT 规则） ----------
# 输出每行: <proto> <host_port> -> <container_ip>:<container_port>
fw_exposed_ports() {
  iptables -t nat -S DOCKER 2>/dev/null | awk '
    /DNAT/ {
      proto=""; dport=""; dest=""
      for (i = 1; i <= NF; i++) {
        if ($i == "-p") proto = $(i+1)
        if ($i == "--dport") dport = $(i+1)
        if ($i == "--to-destination") dest = $(i+1)
      }
      if (dport != "" && dest != "") print proto, dport, "->", dest
    }'
}

# ---------- 报告 ----------
fw_status() {
  local st; st="$(fw_state)"
  local forward_policy=""
  [[ -f "${DI_UFW_DEFAULT}" ]] && forward_policy="$(sed -n 's/^DEFAULT_FORWARD_POLICY="\(.*\)"$/\1/p' "${DI_UFW_DEFAULT}")"

  log_info "防火墙后端: $(detect_firewall_backend)"
  log_info "UFW 默认 FORWARD 策略: ${forward_policy:-未知}"
  echo "" >&2

  case "$st" in
    no_ufw)
      log_warn "未安装 UFW —— 不存在『Docker 绕过 UFW』问题（无需加固）"
      return 0 ;;
    ufw_inactive)
      log_warn "UFW 已安装但未启用 —— 当前无保护，也无绕过问题"
      log_warn "启用前必须先放行 SSH 端口，否则失联（可用 vps-init 的 ufw 步骤）"
      return 0 ;;
    nft_backend)
      log_warn "Docker 使用 nftables 后端（实验性）—— 没有 DOCKER-USER 链，本工具不加固"
      log_warn "需自行建独立 nft 表，base chain priority 低于 Docker 的 filter-FORWARD"
      return 0 ;;
    no_docker)
      log_info "Docker 未安装 —— 不存在绕过问题（DOCKER-USER 链由 Docker 创建）"
      log_info "安装 Docker 后重跑: ${0##*/} firewall status"
      return 0 ;;
    protected)
      log_ok "状态: PROTECTED —— DOCKER-USER 已由 ufw 接管，已发布端口受 ufw 管控"
      ;;
    bypassed)
      log_err "状态: BYPASSED —— UFW 无法管控 Docker 已发布端口（绕过）"
      ;;
  esac

  if [[ -n "$forward_policy" && "$forward_policy" != "DROP" ]]; then
    log_warn "DEFAULT_FORWARD_POLICY=${forward_policy}（非 DROP）—— 规则块仍生效，但建议改 DROP"
  fi

  local exposed
  exposed="$(fw_exposed_ports)"
  if [[ -z "$exposed" ]]; then
    log_info "当前无已发布端口（DNAT 规则为空）"
  else
    echo "" >&2
    if [[ "$st" == "protected" ]]; then
      log_info "已发布端口（受 ufw 管控，需 firewall allow 才公网可达）:"
    else
      log_err "已发布端口（当前公网可直接访问，绕过 ufw）:"
    fi
    while read -r line; do
      [[ -n "$line" ]] && echo "    $line" >&2
    done <<< "$exposed"
  fi
  return 0
}

# ---------- 重载 ufw ----------
fw_reload() {
  log_info "重载 UFW 规则..."
  ufw reload >/dev/null 2>&1 || { log_err "ufw reload 失败"; return 1; }
  return 0
}

# ---------- 复核：读内核实际规则（不信文件、不信命令回显） ----------
fw_verify() {
  local st; st="$(fw_state)"
  if [[ "$st" == "protected" ]]; then
    log_ok "复核通过: iptables -S DOCKER-USER 已含 ufw 接管规则"
    return 0
  fi
  log_err "复核失败: 内核规则未生效（状态=${st}）—— 建议 reboot 后重试"
  return 1
}
