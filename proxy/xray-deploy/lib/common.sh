#!/usr/bin/env bash
# common.sh — 公共基础设施：日志 / 交互输入 / 依赖安装 / 架构与 init 检测
#
# 约定（勿破坏）：
#   - 日志函数必须输出到 stderr：交互函数的返回值靠 stdout 被 $(...) 捕获，
#     日志混入 stdout 会污染返回值（历史 bug：SNI 字段存了整段日志）
#   - has_ctty 是「真打开一次 /dev/tty」判定，不能用 [[ -r /dev/tty ]]（权限位判定，恒真）

# ============ 日志 ============
# 注意：log_info/log_warn 必须输出到 stderr！
# 否则会被 $(select_fallback_domain) 等命令替换捕获，污染返回值（实测 bug：SNI 字段存了多行日志）
log_info() { echo -e "\033[0;32m[INFO]\033[0m $*" >&2; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $*" >&2; }
log_err()  { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

die() { log_err "$*"; exit 1; }

# ============ 交互输入 ============
# 管道方式（curl | sudo bash -s --）下 stdin 被 curl 占用，改从 /dev/tty 读取。
# 返回 1 = 无交互终端（纯 CI/脚本场景）。
# 是否真有控制终端可交互。⚠️ 不能用 [[ -r /dev/tty ]] —— 那是**权限位判定**，
# 无控制终端时同样返回真，直接 read 会报 "/dev/tty: No such device or address"
# （2026-09-18 真机实测）。判据必须是「真打开一次」。
has_ctty() { { : < /dev/tty; } 2>/dev/null; }

read_input() {  # $1=提示 $2=变量名；返回 1 = 无交互终端
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
    printf -v "$2" ""    # set -u 下确保变量已定义，不崩溃
    return 1
  fi
}

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "需要 root 权限，请用: sudo $0 $*"
}

# ============ 依赖安装 ============
detect_pkg_mgr() {
  if command -v apk >/dev/null 2>&1; then echo "apk"
  elif command -v apt-get >/dev/null 2>&1; then echo "apt-get"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  else echo "none"; fi
}

install_deps() {
  local missing=() pkg
  for c in curl unzip jq openssl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  local mgr
  mgr="$(detect_pkg_mgr)"
  [[ "$mgr" == "none" ]] && die "未找到包管理器（需要 apk/apt-get/dnf/yum 之一）"

  log_info "缺少依赖: ${missing[*]}，使用 ${mgr} 自动安装..."
  local sudo_cmd=""
  [[ "$(id -u)" -ne 0 ]] && command -v sudo >/dev/null 2>&1 && sudo_cmd="sudo"

  case "$mgr" in
    apk)
      $sudo_cmd apk add --no-cache curl unzip jq openssl ca-certificates
      ;;
    apt-get)
      $sudo_cmd apt-get update -y
      $sudo_cmd apt-get install -y curl unzip jq openssl ca-certificates
      ;;
    dnf|yum)
      $sudo_cmd "$mgr" install -y curl unzip jq openssl ca-certificates
      ;;
  esac

  # 装后复查
  local still_missing=()
  for c in "${missing[@]}"; do
    command -v "$c" >/dev/null 2>&1 || still_missing+=("$c")
  done
  [[ ${#still_missing[@]} -gt 0 ]] && die "依赖安装后仍缺失: ${still_missing[*]}，请手动安装"
  log_info "依赖就绪。"
}

# ============ 架构检测 ============
detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armhf)  echo "armv7l" ;;
    *) die "不支持的架构: $m（仅支持 amd64/arm64/armv7l）" ;;
  esac
}

# Xray 发布资产名 → 架构
xray_asset_suffix() {
  case "$(detect_arch)" in
    amd64)  echo "linux-64.zip" ;;
    arm64)  echo "linux-arm64-v8a.zip" ;;
    armv7l) echo "linux-arm32-v7a.zip" ;;
  esac
}

# ============ init 检测 ============
detect_init() {
  if [[ -d /run/systemd/system ]] || command -v systemctl >/dev/null 2>&1; then
    echo "systemd"
  elif command -v rc-update >/dev/null 2>&1 || [[ -d /etc/init.d ]]; then
    echo "openrc"
  else
    echo "unknown"
  fi
}
