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
  # ⚠️ 必须写成 export RCLONE_CONFIG="$VP_RCLONE_CONFIG"。
  #    写成裸 `export RCLONE_CONFIG` 只会把**已存在的** RCLONE_CONFIG 标为导出
  #    （值不变，通常为空）→ restic 拉起的 rclone 子进程读不到自定义配置而静默退回
  #    默认 ~/.config/rclone/rclone.conf。症状：非默认配置路径下 init/snapshots 看似正常，
  #    实际 repo 落在默认 remote 或 rclone 的 cwd（2026-09-19 真机 E2E 实测）。
  [[ -n "${VP_RCLONE_CONFIG}" ]] && export RCLONE_CONFIG="${VP_RCLONE_CONFIG}"
  # GDrive 每日上传限额（750GiB，未公开）命中时让 rclone 致命退出而非静默截断
  # （放在 load_env 而非 backup 内部：restic 拉起的 rclone 子进程继承本变量）
  export RCLONE_DRIVE_STOP_ON_UPLOAD_LIMIT="${RCLONE_DRIVE_STOP_ON_UPLOAD_LIMIT:-true}"
  export RESTIC_PASSWORD_FILE="${VP_PASSWORD_FILE}"

  # ---------- restic 缓存目录（systemd 环境下必给，否则 restic 直接拒绝工作） ----------
  # ⚠️ 根因（2026-09-19 anthony 真机实测）：systemd 单元**不设置 HOME**（也设不了，
  #    `User=` 为空 = 系统 manager 环境，`HOME`/`XDG_CACHE_HOME` 全未定义）。
  #    restic 无 --cache-dir / 无 RESTIC_CACHE_DIR 时按 $XDG_CACHE_HOME 或 $HOME 推导，
  #    两者都没有 → `unable to open cache: unable to locate cache directory` 且**退出非零**。
  #    症状极具迷惑性：**交互式（有 HOME）一切正常，只有 timer 跑必挂**——
  #    「我手动跑得好好的，为什么定时备份失败」就是这个。
  # ⚠️ 为什么不是「无 HOME 时回退 $HOME」之类的小修：那等于把持久行为绑在环境推导上。
  #    这里**显式声明**缓存落点（与 VP_HOST 必须钉死同一个道理），
  #    交互式与 systemd 两条路径行为完全一致，且 `/var/cache` 本就在排除表内（缓存不入备份包）。
  # 外部环境变量优先：已设的 RESTIC_CACHE_DIR 不覆盖（与上面 VP_RCLONE_CONFIG 同约定）。
  : "${VP_CACHE_DIR:=/var/cache/vps-backup}"
  export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-${VP_CACHE_DIR}}"
}
