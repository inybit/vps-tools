#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：备份执行（core / data 分层 + 凭证排除）
#
# 分层语义（「快速灾难恢复」的核心设计）：
#   core — /etc、dotfiles、vps-tools 脚本与 wrapper：体量小、频率高、恢复秒~分钟级
#   data — docker volumes、站点内容：体量大、频率低、可后台恢复
# 先恢复 core 服务即可启动，不必等 data 全量下载完。
# ============================================================

# 凭证排除表：备份包里**不得包含打开自己的钥匙**（自噬陷阱）
# /etc/restic-password、/etc/vps-backup.env、rclone.conf 必须异地留存（Bitwarden）。
vp_credential_patterns() {
  cat <<'EOF'
/etc/restic-password
/etc/vps-backup.env
/etc/vps-backup.exclude
/root/.config/rclone/rclone.conf
EOF
}

# 确保排除表存在（首次自动生成；已存在不覆盖 —— 用户可能自定义过）
vp_ensure_exclude_file() {
  [[ -f "${VP_EXCLUDE_FILE}" ]] && return 0
  mkdir -p "$(dirname "${VP_EXCLUDE_FILE}")"
  {
    echo "# vps-backup 排除表（restic --exclude-file）"
    echo "# 凭证类：绝不入备份包（自噬陷阱 —— 机器全毁时凭这些文件才读得回备份）"
    vp_credential_patterns
    echo "# 运行时/临时"
    echo "/proc"
    echo "/sys"
    echo "/dev"
    echo "/run"
    echo "/tmp"
    echo "/var/tmp"
    echo "/var/cache"
    echo "/var/log"
    echo "/var/lib/vps-backup"
    echo "/var/lib/restic"
    echo "/lost+found"
    echo "# 包管理与缓存（可重装，不必备）"
    echo "/var/lib/apt/lists"
    echo "/var/lib/dpkg/info"
    echo "/usr/share/doc"
    echo "/root/.cache"
    echo "/home/*/.cache"
    echo "# 挂载点（外部存储/网络盘）"
    echo "/mnt"
    echo "/media"
  } > "${VP_EXCLUDE_FILE}"
  chmod 600 "${VP_EXCLUDE_FILE}"
  log_ok "已生成排除表: ${VP_EXCLUDE_FILE}"
}

# 自检：凭证必须真的被排除（防「以为排除了其实没有」）
vp_verify_exclusions() {
  vp_ensure_exclude_file
  local p missing=0
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    grep -qxF "$p" "${VP_EXCLUDE_FILE}" || { log_err "排除表缺少凭证路径: $p"; missing=1; }
  done < <(vp_credential_patterns)
  [[ $missing -eq 0 ]] || return 1
  return 0
}

# 备份某层
vp_backup_layer() {  # $1=core|data $2...=额外 restic 参数
  local layer="$1"; shift
  local paths tag
  case "$layer" in
    core) paths="${VP_BACKUP_CORE_PATHS}"; tag="core" ;;
    data) paths="${VP_BACKUP_DATA_PATHS}"; tag="data" ;;
    *) log_err "未知备份层: $layer（core|data）"; return 1 ;;
  esac

  vp_require_password || return 1
  vp_require_tools || return 1
  vp_verify_exclusions || { log_err "排除表校验失败，拒绝备份"; return 1; }

  # 只保留实际存在的路径（缺失路径会让 restic 报错中断）
  local -a existing=()
  local p
  for p in $paths; do
    [[ -e "$p" ]] && existing+=("$p")
  done
  if [[ ${#existing[@]} -eq 0 ]]; then
    log_warn "${layer} 层无可备份路径（检查 ${VP_ENV_FILE} 的 VP_BACKUP_${layer^^}_PATHS）"
    return 0
  fi

  # pre-hook（数据库 dump 等；失败不阻塞备份，但会告警）
  if [[ -n "${VP_PRE_HOOK}" ]]; then
    log_info "执行 pre-hook: ${VP_PRE_HOOK}"
    bash -c "${VP_PRE_HOOK}" || log_warn "pre-hook 失败（继续备份，数据可能不含最新 dump）"
  fi

  log_info "备份 ${layer} 层: ${existing[*]}"
  local -a args=(backup --tag "$tag" --host "${VP_HOST}" --exclude-file "${VP_EXCLUDE_FILE}" --verbose)
  args+=("$@")
  args+=("${existing[@]}")
  if ! vp_restic_diag "${args[@]}"; then
    log_err "${layer} 层备份失败"
    return 1
  fi

  # 实测复核：最新快照确实存在且 tag 正确（不信命令自报）
  local line
  line="$(vp_restic snapshots --json --tag "$tag" --host "${VP_HOST}" 2>/dev/null | tail -c 400)"
  [[ -n "$line" ]] || { log_err "${layer} 层备份后无法列出快照（服务端状态异常）"; return 1; }
  log_ok "${layer} 层备份完成"
  return 0
}

# 备份入口：core / data / all（含超时保护与通知）
vp_backup_main() {  # $1=core|data|all（默认 all）$2...=额外参数
  local layer="${1:-all}"; [[ $# -gt 0 ]] && shift
  local rc=0
  case "$layer" in
    core|data) vp_backup_layer "$layer" "$@" || rc=1 ;;
    all)
      vp_backup_layer core "$@" || rc=1
      vp_backup_layer data "$@" || rc=1
      ;;
    *) log_err "未知备份层: $layer（core|data|all）"; return 1 ;;
  esac
  if [[ $rc -eq 0 ]]; then
    vp_notify "✅ vps-backup[${VP_HOST}] ${layer} 层备份完成"
  fi
  # 失败不在此处通知 —— 统一由 systemd 单元 OnFailure=vps-backup-failnotify@ 兜底，
  # 避免「脚本失败」与「单元失败」双份卡片（同一路径只发一次）
  return $rc
}

# 最近一次备份状态（供 status / notify 使用）
vp_last_snapshot_line() {  # $1=core|data
  local tag="${1:-core}"
  vp_restic snapshots --json --tag "$tag" --host "${VP_HOST}" 2>/dev/null \
    | grep -o '"time":"[^"]*"' | tail -1 | cut -d'"' -f4
}

# 最新快照是否新鲜（供 status 判断「备份是否静默停摆」）
# 输出: <epoch秒> <human>；无法判定时输出空
vp_last_snapshot_epoch() {  # $1=core|data
  local t; t="$(vp_last_snapshot_line "${1:-core}")"
  [[ -n "$t" ]] || return 0
  date -d "$t" +%s 2>/dev/null || true
}
