#!/usr/bin/env bash
# ============================================================
# docker-install 模块：Docker × UFW —— 规则操作
#
# 加固与放行【全部委托上游 chaifeng/ufw-docker】（见 lib/ufwdocker.sh）：
#   加固   = ufw-docker install --docker-subnets
#   放行   = ufw-docker allow <容器名> [端口]   ← 绑定容器 IP，跟随容器
#   撤销   = ufw-docker delete allow ...
#   卸载   = ufw-docker uninstall
# 规则块标记沿用 `# BEGIN UFW AND DOCKER`，与上游/ufw-docker 生态互认。
#
# 本文件只负责：状态前置检查、调用封装、内核复核、以及【非暴露模式】的兜底清理。
# ============================================================

# ---------- 加固：委托上游 ----------
fw_fix() {
  require_root
  local st; st="$(fw_state)"
  case "$st" in
    no_ufw)
      log_warn "未安装 UFW，无需加固。如需: apt install ufw && ufw enable"
      return 0 ;;
    nft_backend)
      log_err "Docker 使用 nftables 后端（实验性）—— 上游 ufw-docker 的 DOCKER-USER 方案不适用"
      log_err "请参考上游 README 的 nf_tables 说明或改用 iptables 后端"
      return 1 ;;
    ufw_inactive)
      log_warn "UFW 未启用。请先放行 SSH 端口再 ufw enable，然后重跑本命令"
      return 1 ;;
    no_docker)
      log_warn "Docker 未安装 —— 无需加固（DOCKER-USER 链由 Docker 创建）"
      log_warn "请先安装: ${0##*/} install"
      return 1 ;;
  esac

  [[ -f "${DI_UFW_AFTER}" ]] || { log_err "缺少 ${DI_UFW_AFTER}（ufw 未初始化？）"; return 1; }
  command -v iptables >/dev/null 2>&1 || install_pkgs iptables iptables || return 1

  ud_install_rules || return 1
  fw_verify
}

# ---------- 放行容器端口（委托上游，按容器绑定 IP） ----------
# $1=容器名/ID（必填，上游按容器查 IP）  $2=端口[/proto]（可省=全部已发布端口）  $3=网络（可省）
fw_allow() {
  require_root
  local name="$1" spec="${2:-}" net="${3:-}"
  [[ -z "$name" ]] && {
    log_err "用法: firewall allow <容器名> [端口[/tcp|udp]] [网络]"
    log_err "  例: firewall allow web 80        # 放行 web 容器的 80"
    log_err "      firewall allow web           # 放行 web 全部已发布端口"
    return 1
  }
  ud_ensure || return 1

  local -a args=(allow "$name")
  [[ -n "$spec" ]] && args+=("$spec")
  [[ -n "$net" ]] && args+=("$net")

  if ud_run "${args[@]}" 2>&1 | sed 's/^/    /' >&2; then
    log_ok "已放行: ${name} ${spec:-（全部已发布端口）}"
  else
    log_err "放行失败: ufw-docker allow ${args[*]}"
    return 1
  fi
  log_info "提示: 需先执行 firewall fix（DOCKER-USER 被接管后）此规则才生效"
}

# ---------- 撤销放行（委托上游） ----------
fw_deny() {
  require_root
  local name="$1" spec="${2:-}" net="${3:-}"
  [[ -z "$name" ]] && {
    log_err "用法: firewall deny <容器名> [端口[/tcp|udp]] [网络]"
    return 1
  }
  ud_ensure || return 1

  local -a args=(delete allow "$name")
  [[ -n "$spec" ]] && args+=("$spec")
  [[ -n "$net" ]] && args+=("$net")

  if ud_run "${args[@]}" 2>&1 | sed 's/^/    /' >&2; then
    log_ok "已撤销放行: ${name} ${spec:-（全部）}"
  else
    log_warn "撤销失败（规则可能本就不存在）: ufw-docker ${args[*]}"
    return 1
  fi
}

# ---------- 卸载加固（委托上游 + 清内核残留） ----------
fw_uninstall() {
  require_root
  ud_remove_rules || return 1
  log_ok "加固已卸载（Docker 端口恢复为绕过 ufw 状态）"
  fw_status
}
