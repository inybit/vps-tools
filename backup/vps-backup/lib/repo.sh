#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：repo 连接 / 初始化 / 完整性校验
#
# ⚠️ 本模块最重要的设计约束：**connect 与 init 严格分离**。
#   恢复场景下 repo 已存在，任何「顺手 init」都会误导排障甚至破坏 repo。
#   - vp_repo_connect: 只做连通性 + 密码校验（restic cat config / snapshots）
#   - vp_repo_init   : 显式子命令；repo 已存在时报错退出，绝不覆盖
# ============================================================

# repo 是否已存在（能读出 config 即存在；密码错/网络错都算不可用 → 返回非 0）
vp_repo_exists() {
  vp_restic cat config >/dev/null 2>&1
}

# 只连接、不写入：校验密码 + 打印 repo 概况
vp_repo_connect() {
  vp_require_password || return 1
  vp_require_tools || return 1
  log_info "repo: $(vp_repo_url)"
  if ! vp_restic cat config >/dev/null 2>&1; then
    log_err "无法连接 repo（密码错 / rclone remote 未配置 / 网络不可达）"
    log_err "  排查: rclone lsd ${VP_RCLONE_REMOTE}: ; rclone config show ${VP_RCLONE_REMOTE}"
    return 1
  fi
  log_ok "repo 连接成功（密码有效）"
  local n
  n="$(vp_restic snapshots --json 2>/dev/null | grep -c '"short_id"' || true)"
  log_info "快照数: ${n:-0}"
  return 0
}

# 显式初始化（仅首次）
vp_repo_init() {
  vp_require_password || return 1
  vp_require_tools || return 1
  if vp_repo_exists; then
    log_err "repo 已存在，拒绝重复初始化: $(vp_repo_url)"
    log_err "  如需查看: vps-backup snapshots    如需换 repo: 改 ${VP_ENV_FILE} 的 VP_REPO_BASE"
    return 1
  fi
  log_info "初始化 repo: $(vp_repo_url)"
  if ! vp_restic init; then
    log_err "初始化失败（remote 未配置 / 权限不足 / 网络不可达）"
    return 1
  fi
  # 写后实测：服务端真的建起来了吗（不信命令自报）
  if vp_repo_exists; then
    log_ok "repo 初始化完成并已实测可读"
  else
    log_err "init 声称成功但 repo 不可读 —— 请检查 rclone remote 配置"
    return 1
  fi
  return 0
}

# 完整性校验：元数据全检 + 数据块抽查（--read-data-subset 避免下载整个 repo）
vp_repo_check() {
  vp_require_password || return 1
  vp_require_tools || return 1
  log_info "完整性校验（数据块抽查 ${VP_CHECK_SUBSET}）"
  if ! vp_restic_diag check --read-data-subset="${VP_CHECK_SUBSET}"; then
    # ⚠️ 修复指引必须区分故障性质：锁问题给 unlock，只有确认是数据损坏才提 repair。
    #    「被锁」误报成「数据损坏」会诱导用户去跑破坏性的 repair 命令。
    if [[ "${VP_LAST_DIAG:-}" == "lock" ]]; then
      log_err "校验未执行完成：repo 被锁（并发/陈旧锁），见上方指引"
    else
      log_err "校验失败：repo 可能损坏"
      log_err "  官方修复: restic repair packs / repair snapshots（勿手工改 index）"
    fi
    return 1
  fi
  log_ok "校验通过"
}

# 查看/清理 repo 锁
# ⚠️ restic 语义：`unlock` **只清「陈旧」锁**（持锁进程已消失 / 超过陈旧阈值）；
#    若锁仍被存活进程持有（含被 SIGSTOP 冻结的），unlock 会「成功返回但一个都没删」。
#    因此**必须实测复核**，不能报「已清理」了事（事务一致性铁律）。
vp_unlock() {  # $1=--dry-run|--all（空=清陈旧锁）
  vp_require_password || return 1
  vp_require_tools || return 1
  local mode="${1:-}"
  local before; before="$(vp_restic list locks 2>/dev/null || true)"
  if [[ "$mode" == "--dry-run" ]]; then
    if [[ -z "$before" ]]; then
      log_ok "当前无锁"
    else
      log_warn "当前锁（$(grep -c . <<< "$before") 个）:"
      # shellcheck disable=SC2086  # 有意分词：每个锁 ID 一行
      printf '  %s\n' $before >&2
      log_info "说明: restic unlock 只清「陈旧锁」（持锁进程已消失/超时）；"
      log_info "      若持锁进程仍在，需先停掉它，或用 unlock --all 强制清除。"
    fi
    return 0
  fi

  if [[ "$mode" == "--all" ]]; then
    vp_restic unlock --remove-all >/dev/null 2>&1 || { log_err "unlock --all 失败"; return 1; }
  else
    vp_restic unlock >/dev/null 2>&1 || { log_err "unlock 失败"; return 1; }
  fi

  # 实测复核（不信命令自报）
  local after; after="$(vp_restic list locks 2>/dev/null || true)"
  if [[ -z "$after" ]]; then
    if [[ -n "$before" ]]; then
      log_ok "已清理 repo 锁（复核: 锁列表为空）"
    else
      log_ok "repo 无锁（无需清理）"
    fi
    return 0
  fi
  log_err "锁仍然存在（restic unlock 只清陈旧锁，该锁被存活进程持有）:"
  # shellcheck disable=SC2086  # 有意分词：每个锁 ID 一行
  printf '  %s\n' $after >&2
  log_err "  ① 确认无备份任务在跑: ps aux | grep restic"
  log_err "  ② 确需强制清除: $(vp_self) unlock --all（--remove-all，会连带清掉他人锁）"
  return 1
}

