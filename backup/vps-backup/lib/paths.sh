#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：备份路径自定义（core / data 分层可配置）
#
# 三层可自定义入口（都写同一个 env 键，改完立即生效，无需重装）：
#   ① 交互:  vps-backup paths set core /etc /root /opt/app
#   ② 交互:  vps-backup paths edit      （逐层向导）
#   ③ 直接:  编辑 /etc/vps-backup.env 的 VP_BACKUP_CORE_PATHS / VP_BACKUP_DATA_PATHS
#
# 自定义后自动体检：路径是否存在、是否被排除表挡掉（挡住会「备份成功但 0 文件」）。
# ============================================================

vp_paths_show() {
  log_info "当前备份路径（来源: ${VP_ENV_FILE}）"
  log_info "  core（每 ${VP_CORE_INTERVAL_HOURS}h）: ${VP_BACKUP_CORE_PATHS}"
  log_info "  data（${VP_DATA_ONCALENDAR}）: ${VP_BACKUP_DATA_PATHS}"
  echo "" >&2
  vp_paths_check core || true
  vp_paths_check data || true
}

# 单层体检：存在性 + 排除表冲突
vp_paths_check() {  # $1=core|data
  local layer="$1" paths p rc=0
  case "$layer" in
    core) paths="${VP_BACKUP_CORE_PATHS}" ;;
    data) paths="${VP_BACKUP_DATA_PATHS}" ;;
    *) return 1 ;;
  esac
  [[ -n "$paths" ]] || { log_err "${layer} 层路径为空"; return 1; }
  for p in $paths; do
    if [[ "$p" != /* ]]; then
      log_err "${layer}: 必须是绝对路径: ${p}"
      rc=1
      continue
    fi
    if [[ ! -e "$p" ]]; then
      log_warn "${layer}: 路径不存在（备份时会跳过）: ${p}"
      continue
    fi
    if vp_path_in_excludes "$p"; then
      log_err "${layer}: 被排除表挡掉（备份时会跳过）: ${p} ← 命中 ${VP_EXCLUDE_HIT}"
      rc=1
      continue
    fi
    log_ok "${layer}: ${p}（可备份）"
  done
  return $rc
}

# 设置某层路径（校验后写 env）
vp_paths_set() {  # $1=core|data $2...=路径列表
  local layer="$1"; shift
  case "$layer" in
    core|data) : ;;
    *) log_err "未知层: ${layer}（core|data）"; return 1 ;;
  esac
  [[ $# -gt 0 ]] || { log_err "至少给一个路径（如: $(vp_self) paths set ${layer} /etc /root）"; return 1; }

  local p rc=0
  for p in "$@"; do
    if [[ "$p" != /* ]]; then
      log_err "必须是绝对路径: ${p}"
      rc=1
      continue
    fi
    if [[ ! -e "$p" ]]; then
      log_warn "路径当前不存在（备份时会跳过，稍后创建即可）: ${p}"
    fi
    if vp_path_in_excludes "$p"; then
      log_err "该路径被排除表挡掉，设了也不会被备份: ${p}（命中 ${VP_EXCLUDE_HIT}）"
      log_err "  先解除排除: $(vp_self) exclude remove ${VP_EXCLUDE_HIT%%（*}"
      rc=1
    fi
  done
  [[ $rc -eq 0 ]] || { log_err "校验未通过，未修改配置"; return 1; }

  local key val
  key="VP_BACKUP_$(tr '[:lower:]' '[:upper:]' <<< "$layer")_PATHS"
  val="$*"
  vp_env_set "$key" "$val" || return 1
  log_ok "${layer} 层备份路径已更新: ${val}"
  log_info "立即生效（下次备份使用）；可先干跑确认: $(vp_self) backup ${layer} --dry-run"
}

# 逐层交互设置
vp_paths_edit() {
  require_root
  load_env
  vp_paths_show
  echo "" >&2
  local layer input
  for layer in core data; do
    local cur
    case "$layer" in
      core) cur="${VP_BACKUP_CORE_PATHS}" ;;
      data) cur="${VP_BACKUP_DATA_PATHS}" ;;
    esac
    log_info "设置 ${layer} 层（当前: ${cur}）"
    log_info "  空格分隔多个绝对路径；留空=保持不变"
    read_input "${layer} 路径: " input || input=""
    if [[ -n "$input" ]]; then
      # shellcheck disable=SC2086  # 有意分词：输入即空格分隔的路径列表
      vp_paths_set "$layer" $input || log_warn "${layer} 未更新"
    else
      log_info "${layer} 保持不变"
    fi
    echo "" >&2
  done
  log_ok "备份路径设置完成"
  vp_paths_show
}

# ---------- 排除表管理（自定义路径时配套使用） ----------
vp_exclude_main() {  # $1=list|add|remove $2=模式
  local action="${1:-list}" pat="${2:-}"
  vp_ensure_exclude_file
  case "$action" in
    list)
      log_info "排除表: ${VP_EXCLUDE_FILE}"
      cat "${VP_EXCLUDE_FILE}" >&2
      ;;
    add)
      [[ -n "$pat" ]] || { log_err "用法: $(vp_self) exclude add <绝对路径或模式>"; return 1; }
      if grep -qxF "$pat" "${VP_EXCLUDE_FILE}"; then
        log_info "已存在，无需添加: ${pat}"
        return 0
      fi
      printf '%s\n' "$pat" >> "${VP_EXCLUDE_FILE}"
      log_ok "已加入排除表: ${pat}"
      ;;
    remove)
      [[ -n "$pat" ]] || { log_err "用法: $(vp_self) exclude remove <模式>"; return 1; }
      # 凭证类模式不可移除（防自噬：备份包不得包含打开自己的钥匙）
      if vp_credential_patterns | grep -qxF "$pat"; then
        log_err "拒绝移除凭证排除项: ${pat}（备份包不得包含打开自己的钥匙）"
        return 1
      fi
      if ! grep -qxF "$pat" "${VP_EXCLUDE_FILE}"; then
        log_warn "排除表中没有该模式: ${pat}"
        return 1
      fi
      grep -vxF "$pat" "${VP_EXCLUDE_FILE}" > "${VP_EXCLUDE_FILE}.tmp" || return 1
      mv "${VP_EXCLUDE_FILE}.tmp" "${VP_EXCLUDE_FILE}"
      chmod 600 "${VP_EXCLUDE_FILE}"
      log_ok "已从排除表移除: ${pat}"
      log_info "注意: 若该模式覆盖凭证路径，请复查 $(vp_self) status 的凭证自检"
      ;;
    *) log_err "未知动作: ${action}（list|add|remove）"; return 1 ;;
  esac
}
