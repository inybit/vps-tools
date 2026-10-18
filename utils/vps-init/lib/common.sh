#!/usr/bin/env bash
# ============================================================
# vps-init 公共函数库
# 被 vps-init.sh source；日志一律输出到 stderr（铁律：返回值靠 stdout 捕获时不污染）
#
# 基础函数（日志 / 交互终端 / read_input / confirm / 包管理器）在仓库根
# lib/core.sh —— 多工具共用一份实现，不要在本文件重复定义。
# 本文件只留 vps-init 特有的东西：路径默认值、root 检查、环境加载、端口/状态函数。
# ============================================================

# ---------- 共享核心（仓库内 ../../../lib，安装后与本文件同目录） ----------
if [[ -r "${BASH_SOURCE[0]%/*}/core.sh" ]]; then
  # shellcheck disable=SC1091
  . "${BASH_SOURCE[0]%/*}/core.sh"
elif [[ -r "${BASH_SOURCE[0]%/*}/../../../lib/core.sh" ]]; then
  # shellcheck disable=SC1091
  . "${BASH_SOURCE[0]%/*}/../../../lib/core.sh"
else
  echo "[ERROR] 找不到共享核心 lib/core.sh（安装不完整，请重跑安装器）" >&2
  exit 1
fi

# confirm 的免交互开关变量名（core 里用间接展开 ${!CORE_YES_VAR} 读取）
export CORE_YES_VAR="VPS_INIT_YES"   # 供 core.sh 的 confirm 用间接展开读取

# 路径默认值（环境变量可覆盖——测试/非 root 场景；产品默认不变）
: "${VPS_INIT_ENV_FILE:=/etc/vps-init.env}"        # 配置文件（可缺省）
: "${VPS_INIT_STATE_DIR:=/etc/vps-init}"          # 步骤状态标记目录
: "${VPS_INIT_CONF_D:=/etc/ssh/sshd_config.d}"    # sshd drop-in 目录
VPS_INIT_DROPIN="${VPS_INIT_CONF_D}/50-vps-init.conf"
: "${VPS_INIT_F2B_JAIL:=/etc/fail2ban/jail.local}"  # fail2ban jail.local 路径

# ---------- root 检测 ----------
# 留在本文件（不进 core）：报错文案是工具特有的，且 core 不该知道 /etc/ssh 之类路径
require_root() {
  if [[ $EUID -ne 0 ]]; then
    log_err "需要 root 权限（写入 /etc/ssh、/etc/fail2ban、/etc/ufw 等）。"
    log_err "请以 root 运行: sudo ${0##*/} $*"
    exit 1
  fi
}

# ---------- 配置加载（/etc/vps-init.env，可缺省） ----------
# 留在本文件：环境变量前缀（VPS_INIT_/SSH_PORT_）与默认值是工具特有的
# shellcheck disable=SC1090
load_env() {
  # 外部环境变量优先：env 文件（含模板空值）不得覆盖外部传入值（2026-08-16 真机）
  local _ext_vars _line
  _ext_vars="$(env | grep -E '^(VPS_INIT_[A-Z_]+|SSH_PORT_[A-Z]+)=' 2>/dev/null || true)"
  if [[ -f "${VPS_INIT_ENV_FILE}" ]]; then
    . "${VPS_INIT_ENV_FILE}" 2>/dev/null || true
  fi
  while IFS= read -r _line; do
    # shellcheck disable=SC2163  # export "NAME=value" 动态导出（NAME=value 整行）
    [[ -n "$_line" ]] && export "$_line"
  done <<< "$_ext_vars"
  : "${SSH_PORT_MIN:=20000}"
  : "${SSH_PORT_MAX:=60000}"
  : "${VPS_INIT_EXTRA_PORTS:=}"
  : "${VPS_INIT_SKIP_USER:=0}"
  : "${VPS_INIT_DISABLE_ROOT:=0}"
  : "${VPS_INIT_YES:=0}"
}

# ---------- 随机高位端口（SSH_PORT_MIN~SSH_PORT_MAX） ----------
random_port() {
  local min="${SSH_PORT_MIN:-20000}" max="${SSH_PORT_MAX:-60000}"
  if (( min < 1024 )); then min=1024; fi
  if (( max > 65535 )); then max=65535; fi
  if (( min > max )); then min=20000; max=60000; fi
  echo $(( RANDOM % (max - min + 1) + min ))
}

# ---------- 实际 SSH 端口（drop-in 优先，fallback 22） ----------
get_ssh_port() {
  local port=""
  if [[ -f "${VPS_INIT_DROPIN}" ]]; then
    port="$(sed -n 's/^[[:space:]]*Port[[:space:]]\+\([0-9]\+\).*/\1/p' "${VPS_INIT_DROPIN}" | tail -1)"
  fi
  if [[ -z "$port" ]] && command -v sshd >/dev/null 2>&1; then
    port="$(sshd -T 2>/dev/null | sed -n 's/^port \([0-9]\+\)$/\1/p' | head -1)"
  fi
  echo "${port:-22}"
}

# ---------- sudo 组探测（Debian 系 sudo；RHEL 系 wheel） ----------
sudo_group() {
  if grep -q '^sudo:' /etc/group 2>/dev/null; then echo "sudo"; return 0; fi
  if grep -q '^wheel:' /etc/group 2>/dev/null; then echo "wheel"; return 0; fi
  echo ""
}

# ---------- 步骤状态（/etc/vps-init/done.<step>） ----------
state_dir() { mkdir -p "${VPS_INIT_STATE_DIR}"; }
state_done() { state_dir; touch "${VPS_INIT_STATE_DIR}/done.$1"; }
state_is_done() { [[ -f "${VPS_INIT_STATE_DIR}/done.$1" ]]; }
state_list_done() {
  local f
  [[ -d "${VPS_INIT_STATE_DIR}" ]] || return 0
  for f in "${VPS_INIT_STATE_DIR}"/done.*; do
    [[ -e "$f" ]] && echo "${f##*/done.}"
  done
}

# ---------- 备份文件（cp -a 加 .bak，同目录） ----------
backup_file() {  # $1=文件路径
  [[ -f "$1" ]] || return 0
  cp -a "$1" "$1.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null && log_info "已备份: $1"
}
