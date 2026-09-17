#!/usr/bin/env bash
# ============================================================
# docker-install 公共函数库
# 被 docker-install.sh source；日志一律输出到 stderr（铁律：返回值靠 stdout 捕获时不污染）
# ============================================================

# 路径默认值（环境变量可覆盖——测试/非 root 场景；产品默认不变）
: "${DI_ENV_FILE:=/etc/docker-install.env}"      # 配置文件（可缺省）
: "${DI_UFW_AFTER:=/etc/ufw/after.rules}"        # ufw 规则文件（ufw 首次 enable 时生成）
: "${DI_UFW_AFTER6:=/etc/ufw/after6.rules}"
: "${DI_UFW_DEFAULT:=/etc/default/ufw}"
: "${DI_UFW_USER_RULES:=/etc/ufw/user.rules}"    # ufw route allow 落点（用于枚举已放行）
: "${DI_DOCKER_DIR:=/etc/docker}"                # daemon.json 所在
: "${DI_DAEMON_JSON:=/etc/docker/daemon.json}"
: "${DI_DOCKER_ROOT:=/var/lib/docker}"
: "${DI_SOCK:=/var/run/docker.sock}"
: "${DI_SCAN_DIRS:=/srv/docker /opt/docker}"     # perms check 扫描的 bind mount 约定目录

# 标记块（与 chaifeng/ufw-docker 完全一致——互认，可接管）
DI_BLOCK_BEGIN="# BEGIN UFW AND DOCKER"
DI_BLOCK_END="# END UFW AND DOCKER"
export DI_BLOCK_BEGIN DI_BLOCK_END

# ---------- 颜色日志（stderr） ----------
log_info() { echo -e "\033[0;32m[INFO]\033[0m $*" >&2; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $*" >&2; }
log_err()  { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
log_ok()   { echo -e "\033[0;32m[OK]\033[0m $*" >&2; }

# ---------- root 检测 ----------
require_root() {
  if [[ ${DI_EUID:-$EUID} -ne 0 ]]; then
    log_err "需要 root 权限（安装 Docker、写 /etc/ufw、管理 docker 组）。"
    log_err "请以 root 运行: sudo ${0##*/} $*"
    exit 1
  fi
}

# ---------- 配置加载（/etc/docker-install.env，可缺省） ----------
# shellcheck disable=SC1090
load_env() {
  local _ext_vars _line
  _ext_vars="$(env | grep -E '^DI_[A-Z0-9_]+=' 2>/dev/null || true)"
  if [[ -f "${DI_ENV_FILE}" ]]; then
    . "${DI_ENV_FILE}" 2>/dev/null || true
  fi
  while IFS= read -r _line; do
    # shellcheck disable=SC2163  # export "NAME=value" 动态导出（NAME=value 整行）
    [[ -n "$_line" ]] && export "$_line"
  done <<< "$_ext_vars"
  : "${DI_DOCKER_USER:=}"          # 加入 docker 组的用户（空=交互询问）
  : "${DI_DOCKER_CIDRS:=}"         # 允许互访的容器私网 CIDR（空=自动探测）
  : "${DI_ALLOW_PORTS:=}"          # 初始放行的容器端口（如 80,443）
  : "${DI_YES:=0}"
}

# ---------- 交互输入（stdin 被占用时从 /dev/tty 读；返回 1 = 无交互终端） ----------
read_input() {  # $1=提示 $2=变量名
  local _rc=0
  if [[ -t 0 ]]; then
    read -r -p "$1" "$2" || _rc=1
  elif [[ -r /dev/tty ]] 2>/dev/null; then
    read -r -p "$1" "$2" < /dev/tty || _rc=1
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
  [[ "${DI_YES}" == "1" ]] && return 0
  local ans=""
  read_input "$1 [y/N] " ans || return 1
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ---------- 包管理器探测 + 安装 ----------
DETECTED_PKG_MGR=""
detect_pkg_mgr() {
  if [[ -n "$DETECTED_PKG_MGR" ]]; then echo "$DETECTED_PKG_MGR"; return 0; fi
  # ⚠️ 必须用 if/elif：写成 `command -v apk && mgr=apk` 顺序赋值时**最后命中的赢**
  # （yum > dnf > apt-get > apk），与「Alpine 优先」的意图相反。
  # 2026-09-18 nginx-install harness 实测：PATH 里同时有 apk 与真实 apt-get 时返回 apt-get。
  local mgr=""
  if command -v apk >/dev/null 2>&1; then mgr="apk"
  elif command -v apt-get >/dev/null 2>&1; then mgr="apt-get"
  elif command -v dnf >/dev/null 2>&1; then mgr="dnf"
  elif command -v yum >/dev/null 2>&1; then mgr="yum"
  fi
  DETECTED_PKG_MGR="$mgr"
  echo "$mgr"
}

install_pkgs() {  # $1=包名 $2=复查命令名（默认=包名）
  local mgr
  mgr="$(detect_pkg_mgr)"
  [[ -z "$mgr" ]] && { log_err "未识别包管理器（apk/apt/dnf/yum），请手动安装: $1"; return 1; }
  local pkg="$1" check="${2:-$1}"
  local cmd
  case "$mgr" in
    apk)     cmd="apk add" ;;
    apt-get) apt-get update -qq >/dev/null 2>&1 || true; cmd="apt-get install -y -qq" ;;
    dnf)     cmd="dnf install -y" ;;
    yum)     cmd="yum install -y" ;;
  esac
  log_info "安装依赖: $pkg"
  $cmd "$pkg" >/dev/null 2>&1 || { log_err "安装失败: $cmd $pkg（请手动安装后重试）"; return 1; }
  command -v "$check" >/dev/null 2>&1 || { log_err "复查失败: $check 仍未安装"; return 1; }
  return 0
}

# ---------- 防火墙后端探测 ----------
# 输出: iptables | nftables | none
#
# ⚠️ Docker 29.x 的 FirewallBackend 是【结构体】不是字符串（2026-09-17 真机实测）：
#    `docker info --format '{{.FirewallBackend}}'`
#      → {iptables [[EnableUserlandProxy true] [UserlandProxyPath /usr/bin/docker-proxy]]}
#    `--format '{{json .FirewallBackend}}'` → {"Driver":"iptables","Info":[[...]]}
#    直接取字符串会拿到整段结构体 dump → 与 "nftables" 比较恒不等 → 漏判 nftables 后端。
detect_firewall_backend() {
  # 1) daemon.json 显式配置优先（最权威）
  local daemon_json="${DI_DAEMON_JSON}"
  if [[ -f "$daemon_json" ]]; then
    local be=""
    if command -v jq >/dev/null 2>&1; then
      be="$(jq -r '."firewall-backend" // empty' "$daemon_json" 2>/dev/null || true)"
    else
      be="$(sed -n 's/.*"firewall-backend"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$daemon_json" 2>/dev/null | head -1)"
    fi
    [[ -n "$be" ]] && { echo "$be"; return 0; }
  fi
  # 2) 运行时探测：只认 Driver 字段（结构体/字符串两种形态都兼容）
  if command -v docker >/dev/null 2>&1; then
    local raw=""
    raw="$(docker info --format '{{json .FirewallBackend}}' 2>/dev/null || true)"
    if [[ -n "$raw" && "$raw" != "null" ]]; then
      local drv=""
      if command -v jq >/dev/null 2>&1; then
        drv="$(printf '%s' "$raw" | jq -r '.Driver // empty' 2>/dev/null || true)"
      fi
      # 无 jq 时用 sed 从 JSON 取 Driver；若本就是裸字符串（旧版）直接采用
      [[ -z "$drv" ]] && drv="$(printf '%s' "$raw" | sed -n 's/.*"Driver"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      [[ -z "$drv" && "$raw" != \{* ]] && drv="$raw"
      case "$drv" in
        iptables|nftables) echo "$drv"; return 0 ;;
      esac
    fi
  fi
  echo "iptables"
}
