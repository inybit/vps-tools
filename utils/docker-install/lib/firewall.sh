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
    # 主机有全局 IPv6 且容器在 v6 上发布时，v6 链也必须接管，否则仍是绕过
    if host_has_ipv6 && fw_exposed_ports6 | grep -q .; then
      local rules6
      rules6="$(ip6tables -S DOCKER-USER 2>/dev/null || true)"
      if [[ -z "$rules6" ]] || ! echo "$rules6" | grep -q 'ufw6-user-forward'; then
        echo "bypassed6"
        return 0
      fi
    fi
    echo "protected"
  else
    echo "bypassed"
  fi
}
# ---------- 主机是否有全局 IPv6（决定是否需要 v6 链判定） ----------
host_has_ipv6() {
  [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)" == "0" ]] || return 1
  command -v ip >/dev/null 2>&1 || return 1
  ip -6 addr show scope global 2>/dev/null | grep -q 'inet6' || return 1
  return 0
}

# ---------- 枚举 IPv6 已发布端口（DNAT6 规则） ----------
fw_exposed_ports6() {
  ip6tables -t nat -S DOCKER 2>/dev/null | awk '
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

# ---------- 枚举已发布端口（DNAT 规则） ----------
# 输出每行: <proto> <宿主端口> -> <容器IP>:<容器端口>
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

# ---------- 容器内部端口去重列表（供 allow/deny 提示） ----------
# ⚠️ allow/deny 的语义是【容器内部端口】，与宿主映射端口无关。
#    直接展示宿主端口会误导用户输入 `allow 8080`（实为容器端口 80）→ 静默无效。
fw_container_ports() {
  fw_exposed_ports | awk '{ n = split($NF, a, ":"); if (n == 2) print a[2] }' | sort -un | tr '\n' ' '
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
    bypassed6)
      log_err "状态: BYPASSED(IPv6) —— IPv4 已接管，但 IPv6 未接管"
      log_warn "容器以 [::]:port 发布时，IPv6 流量仍可绕过 ufw"
      log_warn "修复: ${0##*/} firewall fix（会同时写 after6.rules）"
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
    # 放行按【容器】进行（上游 ufw-docker 绑定容器 IP）→ 给出可直接复制的命令，
    # 并点明「端口是容器内部端口，不是上面的宿主端口」（真机踩坑，照抄宿主端口会静默无效）。
    if [[ "$st" == "protected" ]]; then
      local cports; cports="$(fw_container_ports)"
      if [[ -n "${cports// /}" ]]; then
        log_info "放行请用【容器名 + 容器内部端口】（不是上面的宿主端口）:"
        local p
        for p in $cports; do
          echo "    ${0##*/} firewall allow <容器名> ${p}" >&2
        done
      fi
      log_info "不想暴露任何端口？执行: ${0##*/} firewall lockdown"
    fi
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
# $1=1 表示同时校验了 IPv6（v6 链未接管则失败）
fw_verify() {
  local need6="${1:-0}"
  local st; st="$(fw_state)"
  if [[ "$st" == "protected" ]]; then
    log_ok "复核通过: iptables -S DOCKER-USER 已含 ufw 接管规则"
    [[ "$need6" == "1" ]] && log_ok "复核通过: ip6tables -S DOCKER-USER 已含 ufw6 接管规则"
    return 0
  fi
  if [[ "$st" == "bypassed6" ]]; then
    log_err "复核失败: IPv4 已接管但 IPv6 未生效 —— 检查 ${DI_UFW_AFTER6} 与 ip6tables"
    return 1
  fi
  log_err "复核失败: 内核规则未生效（状态=${st}）—— 建议 reboot 后重试"
  return 1
}
