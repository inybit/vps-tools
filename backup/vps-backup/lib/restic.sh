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
    # ⚠️ 两条路径都要给：只给「从 Bitwarden 取回」会把**首次部署**的人引到死路
    #    （此时还没有 repo，Bitwarden 里自然也没有密码 —— 2026-09-19 真机实测）。
    log_err "  ① 首次部署: sudo $(vp_self) setup     （向导会引导生成并落盘）"
    log_err "  ② 恢复场景: 从 Bitwarden 取回密码后写入该文件（chmod 600）"
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

# ---------- repo 密码引导（首次部署用；绝不覆盖已有密码） ----------
# 为什么需要它：restic 密码是**用户唯一的数据钥匙**，丢了备份永久不可读。
# 但工具原先只读取、从不创建 → 首次部署被 fail-closed 拦下却无出路
# （2026-09-19 真机实测：向导全程无密码步骤）。
# 契约：
#   * 文件已存在 → 直接返回 0，**绝不触碰**（恢复场景 + 幂等）
#   * 生成模式 → `openssl rand -base64 24`，落盘 chmod 600
#   * 手工模式 → 双次输入比对；不一致/为空 → 重试，超次放弃
#   * 落盘后强制提示存入 Bitwarden（异地留存是灾难恢复前提）
vp_password_setup() {
  if [[ -f "${VP_PASSWORD_FILE}" ]]; then
    return 0
  fi
  log_info "repo 密码: ${VP_PASSWORD_FILE} 不存在 —— 首次部署需先设定"
  log_info "  ⚠️ 此密码是唯一的钥匙（restic 无后门），丢失=备份永久不可读"

  # 非交互路径（自动化/CI）：显式提供 VP_PASSWORD 才写入，缺省则**不猜不造**
  # （fail-closed：绝不为用户凭空生成一把他不知道的密码）
  if [[ -n "${VP_PASSWORD:-}" ]]; then
    local t0; t0="$(mktemp "${VP_PASSWORD_FILE}.XXXXXX")" || return 1
    printf '%s\n' "${VP_PASSWORD}" > "$t0"; chmod 600 "$t0"
    mv -f "$t0" "${VP_PASSWORD_FILE}" || { rm -f "$t0"; return 1; }
    log_ok "已按 VP_PASSWORD 落盘: ${VP_PASSWORD_FILE}（600）"
    _vp_password_remind
    return 0
  fi

  local gen="" pw1="" pw2="" tmp
  if read_input "自动生成强密码? [Y/n] " gen; then
    [[ "${gen,,}" == "n" || "${gen,,}" == "no" ]] || {
      command -v openssl >/dev/null 2>&1 || install_pkgs openssl openssl || return 1
      tmp="$(mktemp "${VP_PASSWORD_FILE}.XXXXXX")" || return 1
      openssl rand -base64 24 > "$tmp" || { rm -f "$tmp"; log_err "生成失败"; return 1; }
      chmod 600 "$tmp"
      mv -f "$tmp" "${VP_PASSWORD_FILE}" || { rm -f "$tmp"; return 1; }
      log_ok "已生成并落盘: ${VP_PASSWORD_FILE}（600）"
      _vp_password_remind
      return 0
    }
  fi

  # 手工输入（允许 3 次）
  local i
  for i in 1 2 3; do
    read_input "输入 repo 密码（不回显）: " pw1 || { log_err "无交互终端 —— 请手工创建: umask 077; printf '%s' '<密码>' > ${VP_PASSWORD_FILE}"; return 1; }
    read_input "再输一次确认: " pw2 || return 1
    if [[ -z "$pw1" ]]; then
      log_warn "密码不能为空（第 ${i}/3 次）"
    elif [[ "$pw1" != "$pw2" ]]; then
      log_warn "两次输入不一致（第 ${i}/3 次）"
    else
      tmp="$(mktemp "${VP_PASSWORD_FILE}.XXXXXX")" || return 1
      printf '%s\n' "$pw1" > "$tmp"
      chmod 600 "$tmp"
      mv -f "$tmp" "${VP_PASSWORD_FILE}" || { rm -f "$tmp"; return 1; }
      log_ok "已落盘: ${VP_PASSWORD_FILE}（600）"
      _vp_password_remind
      return 0
    fi
  done
  log_err "密码设定失败（3 次未通过）"
  return 1
}

# 落盘后的强制提醒（异地留存 —— 灾难恢复的唯一出路）
_vp_password_remind() {
  log_warn "━━━ 立即把该密码存入 Bitwarden ━━━"
  log_warn "  密码不在任何备份包里（故意排除，防自噬）。"
  log_warn "  机器全毁时没有它 = 备份永久不可读，无法补救。"
  log_warn "  查看: sudo cat ${VP_PASSWORD_FILE}    （用完即从终端历史清除）"
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

# ⚠️ 解析规则必须与调用点一致（否则"体检通过、调用失败"这类矛盾永远存在）：
#    调用点全部用 `"${VP_RESTIC_BIN}"`（绝对路径变量），因此解析也必须按**同一规则**取：
#      1) $VP_RESTIC_BIN 指向的路径可执行 → 用它
#      2) 否则退回 PATH 上的 restic，**并把变量改写成解析到的绝对路径**
#    （`-o rclone.program=` 与 restic 二进制都用绝对路径 —— 官方要求，防相对路径执行）
#    反例（2026-09-19 自伤一次）：写成「路径可执行 || PATH 有 restic」但调用仍用原变量
#    → 变量指向不存在路径时体检通过、一调用就报"存在但无法执行"。
vp_resolve_bin() {  # $1=变量名 $2=命令名
  local var="$1" name="$2" cur="${!1}" found
  if [[ -n "$cur" && -x "$cur" ]]; then return 0; fi
  found="$(command -v "$name" 2>/dev/null || true)"
  if [[ -n "$found" ]]; then printf -v "$var" '%s' "$found"; return 0; fi
  return 1
}

vp_have_restic() { vp_resolve_bin VP_RESTIC_BIN restic; }
vp_have_rclone() { vp_resolve_bin VP_RCLONE_BIN rclone; }

# 二段式体检：存在 ≠ 可执行。
# ⚠️ 只判「存在」会掩盖两类真实故障（都是同一类误导）：
#    * 二进制架构不符 / 动态库缺失 → `command -v` 通过但一跑就 "cannot execute"
#    * PATH 里有 mock/stub 残留 → 误判「已安装」，实际不可用
#   （docker-install 已踩过同款：`command -v docker` 单独判定不可靠）
# 契约：返回 0 = 两个二进制都能打印版本号；否则打印**可执行**的修复指引。
vp_tools_check() {
  local missing=0
  if ! vp_have_restic; then
    log_err "restic 未安装（运行: sudo $(vp_self) deps）"; missing=1
  elif ! "${VP_RESTIC_BIN}" version >/dev/null 2>&1; then
    log_err "restic 存在但无法执行: ${VP_RESTIC_BIN}"
    log_err "  （架构不符 / 依赖缺失 / 文件损坏）重装: sudo $(vp_self) deps"; missing=1
  fi
  if ! vp_have_rclone; then
    log_err "rclone 未安装（运行: sudo $(vp_self) deps）"; missing=1
  elif ! "${VP_RCLONE_BIN}" version >/dev/null 2>&1; then
    log_err "rclone 存在但无法执行: ${VP_RCLONE_BIN}"
    log_err "  （架构不符 / 依赖缺失 / 文件损坏）重装: sudo $(vp_self) deps"; missing=1
  fi
  [[ $missing -eq 0 ]] || return 1
  command -v curl >/dev/null 2>&1 || install_pkgs curl curl || return 1
  return 0
}

# 依赖体检（子命令路径也要调用 —— 分发会绕过主流程前置检查）
vp_require_tools() { vp_tools_check; }
