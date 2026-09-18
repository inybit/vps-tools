#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：备份执行（core / data 分层）
#
# 分层语义（「快速灾难恢复」的核心设计）：
#   core — /etc、dotfiles、vps-tools 脚本与 wrapper：体量小、频率高、恢复秒~分钟级
#   data — docker volumes、站点内容：体量大、频率低、可后台恢复
# 先恢复 core 服务即可启动，不必等 data 全量下载完。
#
# 备份路径**可自定义**：改 /etc/vps-backup.env 的 VP_BACKUP_CORE_PATHS /
# VP_BACKUP_DATA_PATHS，或用 `vps-backup paths` 交互设置（见 lib/paths.sh）。
# ============================================================

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
    if [[ ! -e "$p" ]]; then
      log_info "跳过不存在的路径: $p"
      continue
    fi
    # 与排除表冲突 → 明确告警（否则会「备份成功但什么都没备」）
    if vp_path_in_excludes "$p"; then
      log_warn "路径被排除表挡掉，不会进入备份: $p（命中 ${VP_EXCLUDE_HIT}）"
      log_warn "  如需备份它: $(vp_self) exclude remove ${VP_EXCLUDE_HIT%%（*}（或编辑 ${VP_EXCLUDE_FILE}）"
      continue
    fi
    existing+=("$p")
  done
  if [[ ${#existing[@]} -eq 0 ]]; then
    log_err "${layer} 层没有可备份的路径（全部不存在或被排除表挡掉）"
    log_err "  检查 ${VP_ENV_FILE} 的 VP_BACKUP_${layer^^}_PATHS 与 ${VP_EXCLUDE_FILE}"
    return 1
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

  # 实测复核（不信命令自报）：① 快照确实存在 ② 快照里真有文件
  # ⚠️ ② 必须做 —— restic 处理 0 文件时同样「成功退出」，只看退出码会假报成功。
  #    判定用 `ls --json <快照ID>` 数 type=file 的条目：
  #    ✗ `stats --tag/--host` 会**累计该层所有快照**的文件数（永远 >0，测不出空备份）
  #    ✗ `stats <快照ID>` 的 total_file_count 把**目录条目**也算进去（空目录快照报 4）
  local sid nfiles
  sid="$(vp_last_snapshot_id "$tag")"
  if [[ -z "$sid" ]]; then
    log_err "${layer} 层备份后无法列出快照（服务端状态异常）"
    return 1
  fi
  # ⚠️ 不能用 `timeout N vp_restic ...`：vp_restic 是 shell 函数，timeout 只认可执行文件，
  #    找不到命令 → 输出为空 → grep -c 得 0 → 假报「备份了 0 个文件」（实测踩过）
  nfiles="$(vp_restic ls --json "$sid" 2>/dev/null | grep -c '"type":"file"' || true)"
  nfiles="${nfiles:-0}"
  if [[ "$nfiles" -eq 0 ]]; then
    log_err "${layer} 层备份了 0 个文件 —— 备份无效！"
    log_err "  常见原因: 备份路径被排除表挡掉（$(vp_self) exclude list）或路径是空目录"
    log_err "  复核: $(vp_self) ls ${sid}"
    return 1
  fi
  log_ok "${layer} 层备份完成（复核: 快照 ${sid} 含 ${nfiles} 个文件）"
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

# 最新快照 ID（供备份后复核；snapshots --json 按时间升序 → 取最后一条）
vp_last_snapshot_id() {  # $1=core|data
  local tag="${1:-core}"
  vp_restic snapshots --json --tag "$tag" --host "${VP_HOST}" 2>/dev/null \
    | grep -o '"short_id":"[^"]*"' | tail -1 | cut -d'"' -f4
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
