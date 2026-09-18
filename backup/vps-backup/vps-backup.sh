#!/usr/bin/env bash
#
# vps-backup — restic + rclone(Google Drive) VPS 备份与灾难恢复
#
# 用法:
#   vps-backup                    向导: 依赖 → repo 连接 → 备份范围 → 通知 → timer → runbook
#   vps-backup deps               安装/更新 restic + rclone（官方二进制 + sha256 校验）
#   vps-backup connect            只连接 repo（不 init —— 恢复场景用）
#   vps-backup init               初始化 repo（仅首次）
#   vps-backup backup [层]        备份 core / data / all
#   vps-backup snapshots|ls|dump  只读侦察
#   vps-backup restore <快照> --target <目录>   恢复（必须显式 target）
#   vps-backup forget|prune|maintain|check      保留策略与完整性校验
#   vps-backup status             状态汇总
#   vps-backup runbook            生成灾难恢复 runbook
#   vps-backup install-timer|timer-status|uninstall-timer
#   vps-backup -v / -h            版本 / 帮助
#
# 配置: /etc/vps-backup.env（600）；密码: /etc/restic-password（600）
# 铁律: 凭证不入备份包；connect 与 init 严格分离；报成功前实测服务端状态

VP_VERSION="1.1.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/deps.sh
. "${SCRIPT_DIR}/lib/deps.sh"
# shellcheck source=lib/repo.sh
. "${SCRIPT_DIR}/lib/repo.sh"
# shellcheck source=lib/backup.sh
. "${SCRIPT_DIR}/lib/backup.sh"
# shellcheck source=lib/retention.sh
. "${SCRIPT_DIR}/lib/retention.sh"
# shellcheck source=lib/restore.sh
. "${SCRIPT_DIR}/lib/restore.sh"
# shellcheck source=lib/timer.sh
. "${SCRIPT_DIR}/lib/timer.sh"
# shellcheck source=lib/status.sh
. "${SCRIPT_DIR}/lib/status.sh"
# shellcheck source=lib/usage.sh
. "${SCRIPT_DIR}/lib/usage.sh"

# ============ 向导（无参默认） ============
wizard() {
  require_root
  load_env
  log_info "vps-backup ${VP_VERSION} — restic + rclone(Google Drive) 备份"
  echo "" >&2

  # 1) 依赖
  log_info "[1/6] 依赖（restic + rclone，官方二进制 + sha256 校验）"
  vp_deps_main || { log_err "依赖安装失败，终止向导"; return 1; }
  echo "" >&2

  # 2) repo 连接（不 init）
  log_info "[2/6] repo 连接"
  log_info "  目标 repo: $(vp_repo_url)"
  if vp_remote_check; then
    if vp_repo_connect; then
      log_ok "repo 已存在且可读 —— 跳过初始化"
    elif confirm "repo 不可读，是否初始化新 repo？（已有数据请选 N）"; then
      vp_repo_init || { log_err "初始化失败，终止向导"; return 1; }
    else
      log_err "repo 不可用，终止向导（排查后重跑: vps-backup connect）"
      return 1
    fi
  else
    log_warn "rclone remote 未就绪 —— 请先配置: rclone config"
    log_warn "（Google Drive 须自建 OAuth client_id；app 需 PUBLISH 否则授权 7 天过期）"
    return 1
  fi
  echo "" >&2

  # 3) 备份范围确认
  log_info "[3/6] 备份范围"
  log_info "  core（每 ${VP_CORE_INTERVAL_HOURS}h）: ${VP_BACKUP_CORE_PATHS}"
  log_info "  data（每日 ${VP_DATA_ONCALENDAR}）: ${VP_BACKUP_DATA_PATHS}"
  if confirm "是否修改备份范围（改 ${VP_ENV_FILE}）?"; then
    log_info "请编辑 ${VP_ENV_FILE} 后重跑向导"
    return 1
  fi
  vp_ensure_exclude_file
  vp_verify_exclusions || { log_err "凭证排除自检失败，终止向导"; return 1; }
  echo "" >&2

  # 4) 通知
  log_info "[4/6] 失败告警（Telegram）"
  if [[ -z "${VP_TG_BOT_TOKEN}" || -z "${VP_TG_CHAT_ID}" ]]; then
    local tok="" chat=""
    if read_input "Telegram bot token（留空跳过）: " tok && [[ -n "$tok" ]]; then
      read_input "Telegram chat id: " chat || chat=""
      [[ -n "$chat" ]] && { vp_env_set VP_TG_BOT_TOKEN "$tok"; vp_env_set VP_TG_CHAT_ID "$chat"
                            VP_TG_BOT_TOKEN="$tok"; VP_TG_CHAT_ID="$chat"; }
    else
      log_warn "未配置通知 —— 备份失败只能从 journalctl 发现"
    fi
  fi
  vp_notify_test || true
  echo "" >&2

  # 5) timer
  log_info "[5/6] systemd timer"
  vp_timer_install || { log_err "timer 安装失败"; return 1; }
  echo "" >&2

  # 6) 首次 core 备份 + runbook
  log_info "[6/6] 首次 core 备份 + 灾难恢复 runbook"
  if confirm "现在执行一次 core 层备份？"; then
    vp_backup_layer core || log_warn "首次备份未成功（排查后: sudo vps-backup backup core）"
  fi
  vp_runbook_main
  echo "" >&2
  log_ok "向导完成 —— 灾难恢复文档: ${VP_RUNBOOK_FILE}"
}

# ============ 主流程（分发必须在函数定义之后） ============
main() {
  local action="${1:-wizard}"
  case "$action" in
    wizard|setup) wizard ;;

    deps)     require_root; load_env; vp_deps_main ;;

    connect)  load_env; vp_repo_connect ;;
    init)     require_root; load_env; vp_repo_init ;;

    backup)   require_root; load_env; vp_backup_main "${2:-all}" "${@:3}" ;;
    snapshots) load_env; vp_snapshots "${@:2}" ;;
    ls)       load_env; vp_ls "${2:-latest}" "${@:3}" ;;
    dump)     load_env; vp_dump "${2:-latest}" "${3:-}" "${@:4}" ;;

    restore)  require_root; load_env; vp_restore_main "${@:2}" ;;

    forget)   require_root; load_env; vp_retention_main forget ;;
    prune)    require_root; load_env; vp_retention_main prune ;;
    maintain) require_root; load_env; vp_retention_main maintain ;;
    check)    require_root; load_env; vp_repo_check ;;
    unlock)   require_root; load_env; vp_unlock "${2:-}" ;;

    status)   load_env; vp_status_main ;;
    runbook)  load_env; vp_runbook_main "${2:-}" ;;
    notify-failure) load_env; vp_fail_notify_main "${2:-unknown}" ;;

    install-timer)   load_env; vp_timer_install ;;
    timer-status)    load_env; vp_timer_status ;;
    uninstall-timer) load_env; vp_timer_uninstall ;;

    -v|--version|-V) echo "vps-backup ${VP_VERSION}" ;;
    -h|--help) usage ;;
    *) usage; return 1 ;;
  esac
}

main "$@"
