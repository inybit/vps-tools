#!/usr/bin/env bash
#
# nginx-install — nginx 官方源安装（stable / mainline）+ 状态体检
#
# 用法:
#   nginx-install                     向导: 检测 → 选通道 → 安装 → 启用 → 体检
#   nginx-install install [通道]      安装/升级 nginx（stable | mainline，默认 stable）
#   nginx-install status              体检（只读）
#   nginx-install -v / -h             版本 / 帮助
#
# 配置: /etc/nginx-install.env（可缺省）
# 依据: https://nginx.org/en/linux_packages.html
# 铁律: 签名密钥校验不过 → 拒绝安装（fail-closed，不落盘不装包）

NI_VERSION="1.0.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/keys.sh
. "${SCRIPT_DIR}/lib/keys.sh"
# shellcheck source=lib/repo.sh
. "${SCRIPT_DIR}/lib/repo.sh"
# shellcheck source=lib/install.sh
. "${SCRIPT_DIR}/lib/install.sh"
# shellcheck source=lib/status.sh
. "${SCRIPT_DIR}/lib/status.sh"
# shellcheck source=lib/usage.sh
. "${SCRIPT_DIR}/lib/usage.sh"

# ============ 向导（无参默认） ============
wizard() {
  require_root
  load_env
  log_info "nginx-install ${NI_VERSION} — nginx 官方源安装"
  echo "" >&2

  # 1) 环境检测
  log_info "[1/4] 环境检测"
  local mgr; mgr="$(detect_pkg_mgr)"
  if [[ -z "$mgr" ]]; then
    log_err "未识别包管理器（apk/apt/dnf/yum），无法自动安装"
    return 1
  fi
  log_info "包管理器: ${mgr}  |  发行版: $(ni_os_id) $(ni_codename)$(ni_alpine_ver)"
  if nginx_installed; then
    log_info "当前 nginx: $(nginx_version)"
  else
    log_info "当前未安装 nginx"
  fi
  echo "" >&2

  # 2) 通道选择（配置已指定则不打扰；否则回车默认 stable，与官方默认一致）
  log_info "[2/4] 仓库通道"
  local ch="${NI_CHANNEL:-}"
  if [[ -n "$ch" ]]; then
    log_info "通道: ${ch}（来自 ${NI_ENV_FILE}）"
  else
    echo "  1) stable    （默认，生产推荐）" >&2
    echo "  2) mainline  （最新特性，风险略高）" >&2
    local sel=""
    read_input "选择 [1/2]（默认 1）: " sel || sel=""
    case "$sel" in
      2|mainline) ch="mainline" ;;
      *)          ch="stable" ;;
    esac
    log_info "通道: ${ch}"
  fi
  NI_CHANNEL="$ch"
  echo "" >&2

  # 3) 安装
  log_info "[3/4] 安装"
  nginx_install_main || { log_err "安装失败，终止向导"; return 1; }
  echo "" >&2

  # 4) 体检
  log_info "[4/4] 体检"
  status_main
  echo "" >&2
  log_ok "向导完成"
}

# ============ 主流程（分发必须在函数定义之后） ============
main() {
  local action="${1:-wizard}"
  case "$action" in
    wizard|setup) wizard ;;
    install)
      require_root
      load_env
      # 命令行显式指定通道（覆盖配置）；未指定且配置为空 → stable（官方默认）
      case "${2:-}" in
        stable|mainline) NI_CHANNEL="$2" ;;
        "") : ;;
        *) log_err "未知通道: $2（stable | mainline）"; return 1 ;;
      esac
      : "${NI_CHANNEL:=stable}"
      nginx_install_main ;;
    status)  load_env; status_main ;;
    -v|--version|-V) echo "${NI_SELF} ${NI_VERSION}" ;;
    -h|--help) usage ;;
    *) usage; return 1 ;;
  esac
}

main "$@"
