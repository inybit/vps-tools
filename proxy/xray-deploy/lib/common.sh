#!/usr/bin/env bash
# common.sh — xray-deploy 特有的基础设施：root 检查 / 版本比较 / 依赖安装 / 架构与 init 检测
#
# 基础函数（日志 / die / 交互终端 / read_input / 包管理器探测）在仓库根
# lib/core.sh —— 多工具共用一份实现，不要在本文件重复定义。
#
# 约定（勿破坏）：
#   - 日志函数必须输出到 stderr：交互函数的返回值靠 stdout 被 $(...) 捕获，
#     日志混入 stdout 会污染返回值（历史 bug：SNI 字段存了整段日志）
#   - has_ctty 是「真打开一次 /dev/tty」判定，不能用 [[ -r /dev/tty ]]（权限位判定，恒真）
#     —— 实现已移到 core.sh，本文件直接使用

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

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "需要 root 权限，请用: sudo $0 $*"
}

# ============ 版本比较 ============
# 语义化版本比较（x.y.z，纯 bash 兼容 Alpine busybox，不用 sort -V）。
# 用于 upgrade 判定：字符串相等比较会把「已装新版」误判为「需要升级」并降级。
ver_gt() {  # $1 > $2 返回 0
  local IFS=. a b i
  read -ra a <<<"$1"
  read -ra b <<<"$2"
  for i in 0 1 2; do
    [[ "${a[$i]:-0}" -gt "${b[$i]:-0}" ]] && return 0
    [[ "${a[$i]:-0}" -lt "${b[$i]:-0}" ]] && return 1
  done
  return 1
}

# ============ 依赖安装 ============
install_deps() {
  local missing=()
  for c in curl unzip jq openssl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [[ ${#missing[@]} -eq 0 ]] && return 0

  local mgr
  mgr="$(detect_pkg_mgr)"
  # core 的 detect_pkg_mgr 用空串表示「都没找到」（旧版此处返回 "none"）
  [[ -z "$mgr" ]] && die "未找到包管理器（需要 apk/apt-get/dnf/yum 之一）"

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
