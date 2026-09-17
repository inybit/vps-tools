#!/usr/bin/env bash
#
# docker-install — Docker 安装 + Docker×UFW 共存加固 + 非 root 管理/权限
#
# 用法:
#   docker-install                    向导：检测 → 安装 → 加固 → 用户组 → 权限检查
#   docker-install install            仅安装/升级 Docker Engine
#   docker-install firewall status    检测 Docker 是否绕过 UFW（只读）
#   docker-install firewall fix       加固：DOCKER-USER 交给 ufw 管控
#   docker-install firewall allow 80  放行公网访问容器端口 80
#   docker-install firewall deny 80   撤销放行
#   docker-install firewall uninstall 还原（移除规则块）
#   docker-install user [用户名]      加入 docker 组（非 root 管理）
#   docker-install perms check        检查非 root 读写权限（只读）
#   docker-install perms fix <路径>   修正指定路径属主（需显式指定）
#   docker-install status             汇总状态
#   docker-install -v / -h            版本 / 帮助
#
# 配置: /etc/docker-install.env（可缺省）
# 铁律: 报成功前必须读内核实际规则复核（iptables -S DOCKER-USER），不看文件

DI_VERSION="1.1.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${DI_TPL_DIR:=${SCRIPT_DIR}/templates}"
export DI_TPL_DIR

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/ufwdocker.sh
. "${SCRIPT_DIR}/lib/ufwdocker.sh"
# shellcheck source=lib/lockdown.sh
. "${SCRIPT_DIR}/lib/lockdown.sh"
# shellcheck source=lib/install.sh
. "${SCRIPT_DIR}/lib/install.sh"
# shellcheck source=lib/firewall.sh
. "${SCRIPT_DIR}/lib/firewall.sh"
# shellcheck source=lib/firewall-rules.sh
. "${SCRIPT_DIR}/lib/firewall-rules.sh"
# shellcheck source=lib/access.sh
. "${SCRIPT_DIR}/lib/access.sh"
# shellcheck source=lib/usage.sh
. "${SCRIPT_DIR}/lib/usage.sh"

# ============ 向导（无参默认） ============
wizard() {
  require_root
  load_env
  log_info "docker-install ${DI_VERSION} — Docker 安装与 UFW 共存加固"
  echo "" >&2

  # 1) 安装
  log_info "[1/5] Docker Engine"
  docker_install_main || { log_err "安装失败，终止向导"; return 1; }
  echo "" >&2

  # 2) 防火墙检测
  log_info "[2/5] Docker × UFW 检测"
  local st; st="$(fw_state)"
  fw_status
  echo "" >&2

  if [[ "$st" == "bypassed" ]]; then
    if confirm "是否立即加固（DOCKER-USER 交给 ufw 管控）?"; then
      fw_fix || log_warn "加固未完成"
    else
      log_warn "跳过加固 —— 已发布端口当前公网可直接访问"
    fi
  fi
  echo "" >&2

  # 3) 暴露策略
  log_info "[3/5] 容器端口暴露策略"
  echo "  1) 不暴露（推荐）—— 容器端口仅服务器本地可访问，对外走 Nginx 统一网关" >&2
  echo "  2) 放行指定端口 —— 直接对公网开放容器端口" >&2
  local choice=""
  read_input "选择 [1/2]（默认 1）: " choice || choice=""
  if [[ "$choice" == "2" ]]; then
    local ports="${DI_ALLOW_PORTS:-}"
    if [[ -z "$ports" ]]; then
      read_input "要放行的容器端口（逗号分隔，如 80,443）: " ports || ports=""
    fi
    if [[ -n "$ports" ]]; then
      # 上游 ufw-docker 按【容器】放行（绑定容器 IP，跟随容器变化）
      local cname=""
      read_input "容器名（放行按容器绑定，需先 docker run）: " cname || cname=""
      if [[ -n "$cname" ]]; then
        local p
        IFS=',' read -r -a _ports <<< "$ports"
        for p in "${_ports[@]}"; do
          p="$(echo "$p" | tr -d ' ')"
          [[ -n "$p" ]] && fw_allow "$cname" "$p" || true
        done
      else
        log_warn "未指定容器名 —— 跳过放行（可稍后: firewall allow <容器名> <端口>）"
      fi
    fi
  else
    fw_lockdown
  fi
  echo "" >&2

  # 4) 非 root 管理
  log_info "[4/5] 非 root 管理（docker 组）"
  local user; user="$(resolve_target_user "" 2>/dev/null)" || user=""
  if [[ -n "$user" ]]; then
    user_main "$user" || log_warn "用户组配置未完成"
  else
    log_warn "未指定用户，跳过。稍后执行: sudo ${0##*/} user <用户名>"
  fi
  echo "" >&2

  # 5) 权限检查
  log_info "[5/5] 非 root 读写权限检查"
  perms_check || true
  echo "" >&2
  log_ok "向导完成"
}

# ============ 状态汇总 ============
status_main() {
  log_info "docker-install ${DI_VERSION}"
  if docker_installed; then
    log_info "Docker: $(docker_version)"
    log_info "服务: $(systemctl is-active docker 2>/dev/null || echo '未知')"
  else
    log_warn "Docker 未安装"
  fi
  log_info "防火墙后端: $(detect_firewall_backend)"
  local st; st="$(fw_state)"
  case "$st" in
    protected)    log_ok  "Docker×UFW: PROTECTED（已加固）" ;;
    bypassed)     log_err "Docker×UFW: BYPASSED（端口绕过 ufw）" ;;
    ufw_inactive) log_warn "Docker×UFW: UFW 未启用" ;;
    no_ufw)       log_info "Docker×UFW: 未安装 UFW（不适用）" ;;
    no_docker)    log_info "Docker×UFW: Docker 未安装（不适用）" ;;
    nft_backend)  log_warn "Docker×UFW: nftables 后端（不支持自动加固）" ;;
  esac
  local members; members="$(getent group docker 2>/dev/null | cut -d: -f4)"
  log_info "docker 组成员: ${members:-（无）}"
  echo "" >&2
  perms_check || true
}

# ============ 主流程（分发必须在函数定义之后） ============
main() {
  local action="${1:-wizard}"
  case "$action" in
    wizard|setup) wizard ;;
    install)  require_root; load_env; docker_install_main ;;
    firewall)
      load_env
      local sub="${2:-status}"
      case "$sub" in
        status)    fw_status ;;
        fix)       fw_fix ;;
        allow)     fw_allow "${3:-}" "${4:-}" ;;
        deny)      fw_deny "${3:-}" "${4:-}" ;;
        uninstall) fw_uninstall ;;
        lockdown)  fw_lockdown ;;
        *) log_err "未知子命令: firewall $sub"; usage; return 1 ;;
      esac ;;
    user)     require_root; load_env; user_main "${2:-}" ;;
    perms)
      load_env
      local psub="${2:-check}"
      case "$psub" in
        check) perms_check ;;
        fix)   perms_fix "${3:-}" "${4:-}" ;;
        sock)  sock_fix ;;
        *) log_err "未知子命令: perms $psub（check|fix|sock）"; return 1 ;;
      esac ;;
    status)   load_env; status_main ;;
    -v|--version|-V) echo "docker-install ${DI_VERSION}" ;;
    -h|--help) usage ;;
    *) usage; return 1 ;;
  esac
}

main "$@"
