#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：状态汇总 + 失败兜底通知
# ============================================================

# 快照新鲜度：超过阈值视为「备份静默停摆」（授权过期等最常见的静默失败）
# 阈值 = 间隔的 3 倍（core 默认 6h → 18h）
vp_staleness_check() {  # $1=core|data
  local tag="$1" epoch now limit
  epoch="$(vp_last_snapshot_epoch "$tag")"
  if [[ -z "$epoch" ]]; then
    log_warn "${tag}: 无快照记录（尚未备份过？）"
    return 1
  fi
  now="$(date +%s)"
  case "$tag" in
    core) limit=$(( ${VP_CORE_INTERVAL_HOURS:-6} * 3600 * 3 )) ;;
    data) limit=$(( 48 * 3600 )) ;;
    *)    limit=$(( 48 * 3600 )) ;;
  esac
  if (( now - epoch > limit )); then
    log_err "${tag}: 最近快照过旧（$(date -d "@$epoch" '+%F %T' 2>/dev/null || echo "$epoch")，超阈值 $((limit/3600))h）—— 检查 timer / rclone 授权"
    return 1
  fi
  log_ok "${tag}: 最近快照 $(date -d "@$epoch" '+%F %T' 2>/dev/null || echo "$epoch")（新鲜）"
  return 0
}

vp_status_main() {
  log_info "vps-backup ${VP_VERSION}"
  log_info "repo: $(vp_repo_url)"
  log_info "密码文件: ${VP_PASSWORD_FILE} ($(stat -c '%a' "${VP_PASSWORD_FILE}" 2>/dev/null || echo '不存在'))"

  if vp_have_restic; then
    log_info "restic: $("${VP_RESTIC_BIN}" version 2>/dev/null | head -1)"
  else
    log_warn "restic 未安装"
  fi
  if vp_have_rclone; then
    log_info "rclone: $("${VP_RCLONE_BIN}" version 2>/dev/null | head -1)"
  else
    log_warn "rclone 未安装"
  fi

  vp_remote_check || true

  # 缓存目录：status 的「快照新鲜度」要真调 restic，缺它同样会失败（且是 systemd 下的默认状态）
  vp_ensure_cache_dir || true

  echo "" >&2
  log_info "快照新鲜度:"
  vp_staleness_check core || true
  vp_staleness_check data || true

  echo "" >&2
  log_info "timer 状态:"
  vp_timer_status

  echo "" >&2
  log_info "排除表凭证自检:"
  if vp_verify_exclusions; then
    log_ok "凭证路径已排除（备份包不含 repo 密码/rclone 配置）"
  else
    log_err "排除表不完整 —— 备份包可能包含打开自己的钥匙！"
  fi
}

# systemd OnFailure 钩子：单元失败时的唯一告警出口
# （脚本自身跑不起来也能发：restic 缺失 / env 缺失 / remote 不可用）
vp_fail_notify_main() {  # $1=实例名（core|data|maintain）
  local inst="${1:-unknown}" detail=""
  if ! vp_have_restic; then detail="restic 未安装";
  elif [[ ! -f "${VP_PASSWORD_FILE}" ]]; then detail="repo 密码文件缺失: ${VP_PASSWORD_FILE}";
  elif ! vp_remote_check >/dev/null 2>&1; then detail="rclone remote 不可用（token 过期？）";
  fi
  vp_notify "🚨 vps-backup[${VP_HOST}] ${inst} 单元执行失败${detail:+（${detail}）}
详见: journalctl -u vps-backup-*${inst}* -n 50"
  log_err "已发送失败告警（${inst}）${detail:+：${detail}}"
  return 0
}
