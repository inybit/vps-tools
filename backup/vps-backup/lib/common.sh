#!/usr/bin/env bash
# ============================================================
# vps-backup 公共函数库
# 被 vps-backup.sh source；日志一律输出到 stderr（铁律：返回值靠 stdout 捕获时不污染）
# ============================================================

# 路径默认值（环境变量可覆盖——测试/非 root 场景；产品默认不变）
: "${VP_ENV_FILE:=/etc/vps-backup.env}"
: "${VP_PASSWORD_FILE:=/etc/restic-password}"
: "${VP_EXCLUDE_FILE:=/etc/vps-backup.exclude}"
: "${VP_STATE_DIR:=/var/lib/vps-backup}"
: "${VP_LOG_FILE:=/var/log/vps-backup.log}"
: "${VP_RUNBOOK_FILE:=/root/VPS-RESTORE.md}"
: "${VP_CMD:=/usr/local/bin/vps-backup}"
: "${VP_RESTIC_BIN:=/usr/local/bin/restic}"
: "${VP_RCLONE_BIN:=/usr/local/bin/rclone}"
: "${VP_UNIT_DIR:=/etc/systemd/system}"

# ---------- 颜色日志（stderr） ----------
log_info() { echo -e "\033[0;32m[INFO]\033[0m $*" >&2; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $*" >&2; }
log_err()  { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
log_ok()   { echo -e "\033[0;32m[OK]\033[0m $*" >&2; }

# ---------- root 检测 ----------
require_root() {
  if [[ ${VP_EUID:-$EUID} -ne 0 ]]; then
    log_err "需要 root 权限（读写 /etc、安装 systemd timer）。"
    log_err "请以 root 运行: sudo ${0##*/} $*"
    exit 1
  fi
}

# ---------- 配置加载（/etc/vps-backup.env，可缺省） ----------
# 外部环境变量优先：env 文件不得覆盖外部传入值（与 vps-init 同约定）
# shellcheck disable=SC1090
load_env() {
  local _ext_vars _line
  _ext_vars="$(env | grep -E '^(VP_[A-Z0-9_]+|RESTIC_[A-Z0-9_]+|RCLONE_[A-Z0-9_]+)=' 2>/dev/null || true)"
  if [[ -f "${VP_ENV_FILE}" ]]; then
    . "${VP_ENV_FILE}" 2>/dev/null || true
  fi
  while IFS= read -r _line; do
    # shellcheck disable=SC2163  # export "NAME=value" 动态导出（NAME=value 整行）
    [[ -n "$_line" ]] && export "$_line"
  done <<< "$_ext_vars"

  : "${VP_RCLONE_REMOTE:=gdrive}"                    # rclone remote 名（rclone config 里的名字）
  : "${VP_REPO_BASE:=vps-backup}"                    # remote 内的 repo 根目录
  : "${VP_HOST:=$(hostname -s 2>/dev/null || hostname)}"   # 快照 host 标签 / repo 子目录名
  : "${VP_BACKUP_CORE_PATHS:=/etc /root /home /usr/local/lib/vps-tools /usr/local/lib/vps-backup /usr/local/bin}"
  : "${VP_BACKUP_DATA_PATHS:=/var/lib/docker/volumes /srv /opt}"
  : "${VP_RETENTION_ARGS:=--keep-daily 7 --keep-weekly 5 --keep-monthly 6 --keep-yearly 2}"
  : "${VP_CHECK_SUBSET:=5%}"                         # 每周抽查比例（restic check --read-data-subset）
  : "${VP_CORE_INTERVAL_HOURS:=6}"
  : "${VP_CORE_ONCALENDAR:=*-*-* 00/${VP_CORE_INTERVAL_HOURS}:20:00}"
  : "${VP_DATA_ONCALENDAR:=*-*-* 03:30:00}"
  : "${VP_MAINTAIN_ONCALENDAR:=Sun *-*-* 04:30:00}"
  : "${VP_PRE_HOOK:=}"
  : "${VP_RETRY_LOCK:=10m}"                          # repo 被占用时重试时长（官方 --retry-lock）
  : "${VP_NOTIFY:=1}"
  : "${VP_TG_BOT_TOKEN:=}"
  : "${VP_TG_CHAT_ID:=}"
  : "${VP_YES:=0}"
  : "${VP_RCLONE_CONFIG:=}"                          # 非空则导出 RCLONE_CONFIG
  [[ -n "${VP_RCLONE_CONFIG}" ]] && export RCLONE_CONFIG
  # GDrive 每日上传限额（750GiB，未公开）命中时让 rclone 致命退出而非静默截断
  # （放在 load_env 而非 backup 内部：restic 拉起的 rclone 子进程继承本变量）
  export RCLONE_DRIVE_STOP_ON_UPLOAD_LIMIT="${RCLONE_DRIVE_STOP_ON_UPLOAD_LIMIT:-true}"
  export RESTIC_PASSWORD_FILE="${VP_PASSWORD_FILE}"
}

# 是否真有控制终端可交互。⚠️ 不能用 [[ -r /dev/tty ]] —— 那是**权限位判定**，
# 无控制终端时同样返回真，直接 read 会报 "/dev/tty: No such device or address"
# （2026-09-18 真机实测）。判据必须是「真打开一次」。
has_ctty() { { : < /dev/tty; } 2>/dev/null; }

# ---------- 交互输入（stdin 被占用时从 /dev/tty 读；返回 1 = 无交互终端） ----------
read_input() {  # $1=提示 $2=变量名
  local _rc=0
  if [[ -t 0 ]]; then
    read -r -p "$1" "$2" || _rc=1
  elif has_ctty; then
    printf '%s' "$1" >&2
    # ⚠️ 2>/dev/null 必须在 < /dev/tty 之前（顺序反了报错会漏到 stderr）
    read -r "$2" 2>/dev/null < /dev/tty || _rc=1
  else
    _rc=1
  fi
  if [[ $_rc -ne 0 ]]; then
    printf -v "$2" ""    # set -u 兜底
    return 1
  fi
}

# 确认提示（默认 N）；返回 0 = 确认
confirm() {  # $1=提示文本
  [[ "${VP_YES}" == "1" ]] && return 0
  local ans=""
  read_input "$1 [y/N] " ans || return 1
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ---------- 包管理器探测 + 安装 ----------
VP_DETECTED_PKG_MGR=""
detect_pkg_mgr() {
  [[ -n "$VP_DETECTED_PKG_MGR" ]] && { echo "$VP_DETECTED_PKG_MGR"; return 0; }
  # ⚠️ 必须用 if/elif：写成 `command -v apk && mgr=apk` 顺序赋值时**最后命中的赢**
  local mgr=""
  if command -v apk >/dev/null 2>&1; then mgr="apk"
  elif command -v apt-get >/dev/null 2>&1; then mgr="apt-get"
  elif command -v dnf >/dev/null 2>&1; then mgr="dnf"
  elif command -v yum >/dev/null 2>&1; then mgr="yum"
  fi
  VP_DETECTED_PKG_MGR="$mgr"
  echo "$mgr"
}

install_pkgs() {  # $1=包名 $2=复查命令名（默认=包名）
  local mgr pkg check cmd
  mgr="$(detect_pkg_mgr)"
  [[ -z "$mgr" ]] && { log_err "未识别包管理器（apk/apt/dnf/yum），请手动安装: $1"; return 1; }
  pkg="$1"; check="${2:-$1}"
  case "$mgr" in
    apk)     cmd="apk add" ;;
    apt-get) apt-get update -qq >/dev/null 2>&1 || true; cmd="apt-get install -y -qq" ;;
    dnf)     cmd="dnf install -y" ;;
    yum)     cmd="yum install -y" ;;
  esac
  log_info "安装依赖: $pkg"
  $cmd "$pkg" >/dev/null 2>&1 || { log_err "安装失败: $cmd $pkg（请手动安装后重试）"; return 1; }
  command -v "$check" >/dev/null 2>&1 || { log_err "复查失败: $check 仍未安装"; return 1; }
}

# ---------- 配置写入（原子 tmp+mv；key 已存在则替换，否则追加） ----------
vp_env_set() {  # $1=key $2=value
  local key="$1" val="$2" f="${VP_ENV_FILE}" tmp
  [[ -f "$f" ]] || { log_err "配置不存在: $f"; return 1; }
  tmp="${f}.tmp"
  if grep -qE "^${key}=" "$f"; then
    # 用 | 作分隔符，值里的 / 不转义；值内 | 罕见（token 不含）
    sed "s|^${key}=.*|${key}=\"${val}\"|" "$f" > "$tmp"
  else
    cp "$f" "$tmp"
    printf '%s="%s"\n' "$key" "$val" >> "$tmp"
  fi
  mv "$tmp" "$f"
  chmod 600 "$f"
  log_ok "已更新配置: ${key}=${val}"
}

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
