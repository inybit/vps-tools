#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：repo URL / restic 调用封装 / 依赖体检
# 被 vps-backup.sh source（由 lib/common.sh 拆分而来，2026-09-19）
# ============================================================

# ---------- repo URL 与 restic 调用封装 ----------
vp_repo_url() { echo "rclone:${VP_RCLONE_REMOTE}:${VP_REPO_BASE}/${VP_HOST}"; }

# ⚠️ 凭证 fail-closed：密码文件缺失/权限过宽/内容为空 → 拒绝执行，绝不尝试空密码
vp_require_password() {
  if [[ ! -f "${VP_PASSWORD_FILE}" ]]; then
    log_err "repo 密码文件不存在: ${VP_PASSWORD_FILE}"
    log_err "  恢复场景请从 Bitwarden 取回密码后写入该文件（chmod 600）。"
    return 1
  fi
  local mode
  mode="$(stat -c '%a' "${VP_PASSWORD_FILE}" 2>/dev/null || echo '?')"
  if [[ "$mode" != "600" ]]; then
    log_err "repo 密码文件权限过宽: ${VP_PASSWORD_FILE} = ${mode}（应为 600）"
    log_err "  修正: chmod 600 ${VP_PASSWORD_FILE}"
    return 1
  fi
  if [[ ! -s "${VP_PASSWORD_FILE}" ]]; then
    log_err "repo 密码文件为空: ${VP_PASSWORD_FILE}"
    return 1
  fi
  return 0
}

# restic 调用封装：repo + 密码文件；rclone: 后端额外指定 rclone 可执行文件绝对路径
# （restic 拒绝隐式运行当前目录下的相对路径 rclone —— 官方安全限制）
# --retry-lock：repo 被占用时等待而非直接失败（官方机制，解决「定时任务撞车」最常见的失败）
vp_restic() {
  local args=(--repo "$(vp_repo_url)" --password-file "${VP_PASSWORD_FILE}")
  case "$(vp_repo_url)" in
    rclone:*) args+=(-o "rclone.program=${VP_RCLONE_BIN}") ;;
  esac
  [[ -n "${VP_RETRY_LOCK:-}" ]] && args+=(--retry-lock "${VP_RETRY_LOCK}")
  "$VP_RESTIC_BIN" "${args[@]}" "$@"
}

# 命令自名（去掉 .sh 与路径：直接跑脚本时也能给出正确的自调用命令）
vp_self() { local n="${0##*/}"; echo "${n%.sh}"; }

# 上次 vp_restic_diag 的故障性质：lock | ""（供调用方区分「被锁」与「真损坏」）
# shellcheck disable=SC2034  # 由 repo.sh 的 vp_repo_check 读取
VP_LAST_DIAG=""

# 执行 restic，失败时追加「锁占用」诊断（保持实时输出，不做输出捕获）
# ⚠️ 不用 `2> >(tee file)` 抓输出：进程替换的写入与 `wait` 有竞态（读到空文件），
#    且 stderr 重定向到文件会让 restic 自动关闭进度输出（长备份失去进度）。
#    改为失败后**主动查锁**：`restic list locks` 非空即说明 repo 被占用。
vp_restic_diag() {
  local rc=0
  VP_LAST_DIAG=""
  vp_restic "$@" || rc=$?
  if [[ $rc -ne 0 ]]; then
    local locks=""
    locks="$(vp_restic list locks 2>/dev/null || true)"
    if [[ -n "$locks" ]]; then
      # shellcheck disable=SC2034  # 由 repo.sh 的 vp_repo_check 读取
      VP_LAST_DIAG="lock"
      log_err "原因: repo 被锁（另一实例正在跑，或上次异常退出留下陈旧锁）"
      log_err "  查看: sudo $(vp_self) unlock --dry-run    清理: sudo $(vp_self) unlock"
    fi
  fi
  return $rc
}

vp_have_restic() { [[ -x "${VP_RESTIC_BIN}" ]] || command -v restic >/dev/null 2>&1; }
vp_have_rclone() { [[ -x "${VP_RCLONE_BIN}" ]] || command -v rclone >/dev/null 2>&1; }

# 依赖体检（子命令路径也要调用 —— 分发会绕过主流程前置检查）
vp_require_tools() {
  local missing=0
  vp_have_restic || { log_err "restic 未安装（运行: sudo ${0##*/} deps）"; missing=1; }
  vp_have_rclone || { log_err "rclone 未安装（运行: sudo ${0##*/} deps）"; missing=1; }
  [[ $missing -eq 0 ]] || return 1
  command -v curl >/dev/null 2>&1 || install_pkgs curl curl || return 1
  return 0
}
