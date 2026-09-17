#!/usr/bin/env bash
# ============================================================
# docker-install 模块：Docker × UFW —— 规则写入与放行
#
# 规则块沿用 chaifeng/ufw-docker 的 `# BEGIN UFW AND DOCKER` 标记 →
# 与已装 ufw-docker 的机器互认、可接管（幂等：先删旧块再追加）。
#
# 放行语义：ufw route allow 匹配【容器内部端口】，不是 -p 的宿主映射端口。
# ============================================================

# ---------- 加固：写入规则块 ----------
fw_fix() {
  require_root
  local st; st="$(fw_state)"
  case "$st" in
    no_ufw)
      log_warn "未安装 UFW，无需加固。如需: apt install ufw && ufw enable"
      return 0 ;;
    nft_backend)
      log_err "nftables 后端不支持自动加固，请手工建 nft 表（见 firewall status 提示）"
      return 1 ;;
    ufw_inactive)
      log_warn "UFW 未启用。规则块需写入已存在的 ${DI_UFW_AFTER}（ufw 首次 enable 时生成）"
      log_warn "请先放行 SSH 端口再 ufw enable，然后重跑本命令"
      return 1 ;;
    no_docker)
      log_warn "Docker 未安装 —— 无需加固（DOCKER-USER 链由 Docker 创建）"
      log_warn "请先安装: ${0##*/} install"
      return 1 ;;
  esac

  [[ -f "${DI_UFW_AFTER}" ]] || { log_err "缺少 ${DI_UFW_AFTER}（ufw 未初始化？）"; return 1; }
  command -v iptables >/dev/null 2>&1 || install_pkgs iptables || return 1

  local cidrs="${DI_DOCKER_CIDRS:-}"
  [[ -z "${cidrs// /}" ]] && cidrs="$(detect_docker_cidrs)"
  log_info "容器私网 CIDR: ${cidrs}"

  local block; block="$(render_ufw_block "$cidrs")" || return 1
  [[ -n "$block" ]] || { log_err "规则块渲染为空"; return 1; }

  backup_file "${DI_UFW_AFTER}"
  local tmp; tmp="$(mktemp)"
  sed "/^[[:space:]]*${DI_BLOCK_BEGIN}/,/^[[:space:]]*${DI_BLOCK_END}/d" "${DI_UFW_AFTER}" > "$tmp"
  printf '%s\n' "$block" >> "$tmp"
  cat "$tmp" > "${DI_UFW_AFTER}"
  rm -f "$tmp"
  log_info "已写入规则块 → ${DI_UFW_AFTER}"

  fw_reload || return 1
  fw_verify
}

# ---------- 放行容器端口（封装 ufw route allow） ----------
# $1=端口或端口/协议  $2=可选容器IP
fw_allow() {
  require_root
  local spec="$1" target="${2:-}"
  [[ -z "$spec" ]] && { log_err "用法: firewall allow <端口>[/tcp|udp] [容器IP]"; return 1; }

  local port="$spec" proto=""
  if [[ "$spec" == */* ]]; then port="${spec%%/*}"; proto="${spec##*/}"; fi
  [[ "$port" =~ ^[0-9]+$ ]] || { log_err "端口非法: ${port}"; return 1; }
  if [[ -n "$proto" && "$proto" != "tcp" && "$proto" != "udp" ]]; then
    log_err "协议非法: ${proto}（仅 tcp/udp）"; return 1
  fi

  local args=(route allow proto "${proto:-tcp}" from any)
  if [[ -n "$target" ]]; then
    [[ "$target" =~ ^[0-9.]+$ ]] || { log_err "容器 IP 非法: ${target}"; return 1; }
    args+=(to "$target")
  else
    args+=(to any)
  fi
  args+=(port "$port")

  if ufw "${args[@]}" >/dev/null 2>&1; then
    log_ok "已放行公网 → 容器端口 ${port}${proto:+/$proto}${target:+ (仅 $target)}"
  else
    log_err "ufw route allow 失败: ${args[*]}"
    return 1
  fi
  # 复核：规则必须真的落到 user.rules
  if [[ -f "${DI_UFW_USER_RULES}" ]] && ! grep -q "port ${port}" "${DI_UFW_USER_RULES}" 2>/dev/null; then
    log_warn "复核存疑: ${DI_UFW_USER_RULES} 未见 port ${port} 规则"
  fi
  log_info "提示: 仅当 DOCKER-USER 已被接管（firewall fix）后此规则才生效"
}

# ---------- 撤销放行 ----------
fw_deny() {
  require_root
  local spec="$1" target="${2:-}"
  [[ -z "$spec" ]] && { log_err "用法: firewall deny <端口>[/tcp|udp] [容器IP]"; return 1; }
  local port="$spec" proto=""
  if [[ "$spec" == */* ]]; then port="${spec%%/*}"; proto="${spec##*/}"; fi
  [[ "$port" =~ ^[0-9]+$ ]] || { log_err "端口非法: ${port}"; return 1; }

  local args=(route delete allow proto "${proto:-tcp}" from any)
  if [[ -n "$target" ]]; then args+=(to "$target"); else args+=(to any); fi
  args+=(port "$port")

  if ufw "${args[@]}" >/dev/null 2>&1; then
    log_ok "已撤销放行: 容器端口 ${port}${proto:+/$proto}"
  else
    log_warn "撤销失败（规则可能本就不存在）: ${args[*]}"
    return 1
  fi
}

# ---------- 卸载加固（还原 after.rules + 清内核残留） ----------
fw_uninstall() {
  require_root
  [[ -f "${DI_UFW_AFTER}" ]] || { log_warn "无 ${DI_UFW_AFTER}"; return 0; }
  local had_block=0
  grep -q "${DI_BLOCK_BEGIN}" "${DI_UFW_AFTER}" 2>/dev/null && had_block=1

  if [[ "$had_block" == "0" ]]; then
    log_info "after.rules 中无规则块"
  else
    backup_file "${DI_UFW_AFTER}"
    local tmp; tmp="$(mktemp)"
    sed "/^[[:space:]]*${DI_BLOCK_BEGIN}/,/^[[:space:]]*${DI_BLOCK_END}/d" "${DI_UFW_AFTER}" > "$tmp"
    cat "$tmp" > "${DI_UFW_AFTER}"
    rm -f "$tmp"
    fw_reload || return 1
    log_ok "已从 ${DI_UFW_AFTER} 移除规则块"
  fi

  # ⚠️ ufw reload 不会清空 DOCKER-USER 链（2026-09-17 真机实测）：
  #    after.rules 里的块没了，但内核里 DOCKER-USER 规则仍在 → 状态不一致
  #    （下次 ufw reload 才会消失，行为静默改变）。必须显式 flush。
  if command -v iptables >/dev/null 2>&1 && iptables -S DOCKER-USER >/dev/null 2>&1; then
    local before
    before="$(iptables -S DOCKER-USER 2>/dev/null | grep -c '^-A' || true)"
    if [[ "${before:-0}" -gt 0 ]]; then
      iptables -F DOCKER-USER 2>/dev/null || true
      local after
      after="$(iptables -S DOCKER-USER 2>/dev/null | grep -c '^-A' || true)"
      if [[ "${after:-0}" -eq 0 ]]; then
        log_ok "已清空内核 DOCKER-USER 链（${before} → 0 条规则）"
      else
        log_warn "DOCKER-USER 仍有 ${after} 条规则残留，请手工检查: iptables -S DOCKER-USER"
      fi
    fi
  fi

  log_ok "加固已卸载（Docker 端口恢复为绕过 ufw 状态）"
  fw_status
}
