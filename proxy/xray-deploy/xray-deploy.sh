#!/usr/bin/env bash
# ============================================================
# xray-deploy.sh — Xray 一键部署/管理（vps-tools 生态）· 入口脚本
#
# 本文件只负责：路径常量 → source lib/ → 子命令分发 → 交互菜单。
# 业务逻辑全部在 lib/ 下按模块拆分（每文件 ≤200 行）。
#
# 用法:  xray-deploy.sh [install|info|config|fallback-test|fallback-cn-test|
#                        update-geo|upgrade|status|restart|uninstall|protocol|chain]
#        无参 = 交互菜单
# 帮助:  xray-deploy.sh -h
# 环境变量: GH_PROXY  GitHub 下载镜像前缀（可选，如 https://ghproxy.com/）
#
# 安装路径:
#   二进制   /usr/local/lib/xray-deploy/（含 xray + geo 数据）
#   配置     /etc/xray-deploy/config.json + state.json（600）
#   服务     systemd: /etc/systemd/system/xray-deploy.service
#             OpenRC: /etc/init.d/xray-deploy
# ============================================================

set -euo pipefail

VERSION="1.15.0"   # 发布新功能时递增（配合 vps-tools 工具约定：新增工具必须支持 -v/-h）

# ============ 路径常量 ============
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 注意：/usr/local/bin/xray-deploy 是 vps-tools 生成的命令入口（wrapper），
# 二进制/geo 数据放 /usr/local/lib/xray-deploy/，避免与命令冲突
INSTALL_DIR="${XRAY_INSTALL_DIR:-/usr/local/lib/xray-deploy}"
CONFIG_DIR="/etc/xray-deploy"
BIN_PATH="${INSTALL_DIR}/xray"
STATE_FILE="${CONFIG_DIR}/state.json"
CONFIG_FILE="${CONFIG_DIR}/config.json"
SERVICE_NAME="xray-deploy"
GEO_SOURCE="https://github.com/MetaCubeX/meta-rules-dat/releases/latest/download"
# ⚠️ 不能用 /releases/latest：该端点【只返回非 prerelease 的最新版】，
#    而 Xray 从 v26.3.23 起所有 release 都标 prerelease:true
#    → 实测它恒返回 v26.3.27（2026-03-27），实际最新是 v26.9.9。
#    改用 releases 列表取首个（按发布时间倒序，draft 已由 GitHub 排除）。
# per_page=30：安装向导的「版本选择」菜单要列最近 10 个版本（见 xray-bin.sh）
GITHUB_API="https://api.github.com/repos/XTLS/Xray-core/releases?per_page=30"
# ⚠️ API 兜底通道（2026-09-21 用户真机 403 报障后新增）：
#    未认证 API 配额仅 60 次/时/IP，超限返回 HTTP 403 → 安装向导第一步就卡死。
#    releases.atom 无配额/无需 token，实测 tag 序列与 API 完全一致（条数 10 vs 30）。
XRAY_ATOM="https://github.com/XTLS/Xray-core/releases.atom"

# lib/ 模块加载（顺序无关：函数在分发时才解析；顶层常量均在运行时使用）
LIB_DIR="${SCRIPT_DIR}/lib"
. "${LIB_DIR}/common.sh"
. "${LIB_DIR}/service.sh"
. "${LIB_DIR}/fallback-data.sh"
. "${LIB_DIR}/fallback.sh"
. "${LIB_DIR}/keys.sh"
. "${LIB_DIR}/xray-bin.sh"
. "${LIB_DIR}/registry.sh"
. "${LIB_DIR}/client-mihomo.sh"
. "${LIB_DIR}/client-singbox.sh"
. "${LIB_DIR}/client-ss2022.sh"
. "${LIB_DIR}/inbound.sh"
. "${LIB_DIR}/state.sh"
. "${LIB_DIR}/ss2022.sh"
. "${LIB_DIR}/outbound.sh"
. "${LIB_DIR}/warp.sh"
. "${LIB_DIR}/warp-cmd.sh"
. "${LIB_DIR}/menu.sh"
. "${LIB_DIR}/routing.sh"
. "${LIB_DIR}/chain.sh"
. "${LIB_DIR}/chain-info.sh"
. "${LIB_DIR}/proto-wizard.sh"
. "${LIB_DIR}/xhttp3.sh"
. "${LIB_DIR}/proto-crud.sh"
. "${LIB_DIR}/proto-edit.sh"
. "${LIB_DIR}/cmd-lifecycle.sh"
. "${LIB_DIR}/cmd-upgrade.sh"
. "${LIB_DIR}/cmd-info.sh"
. "${LIB_DIR}/cmd-fallback.sh"
. "${LIB_DIR}/globalping.sh"
. "${LIB_DIR}/usage.sh"

# ============ 子命令分发 ============
CMD="${1:-menu}"
case "$CMD" in
  -v|--version|-V)  echo "xray-deploy ${VERSION}"; exit 0 ;;
  -h|--help)        usage
      exit 0 ;;
  install)       cmd_install ;;
  info)          cmd_info ;;
  config)        cmd_config "${2:-show}" ;;
  fallback-test) cmd_fallback_test "${2:-}" ;;
  fallback-cn-test) cmd_fallback_cn_test "${2:-}" ;;
  update-geo)    update_geo "${2:-}" ;;
  upgrade)       cmd_upgrade "${2:-}" ;;
  status)        need_root; service_status ;;
  restart)       need_root; service_restart ;;
  uninstall)     cmd_uninstall ;;
  protocol)
    case "${2:-list}" in
      add)    proto_add ;;
      remove) proto_remove ;;
      edit)   proto_edit ;;
      list)   [[ -f "$STATE_FILE" ]] && proto_list_names || die "尚未安装" ;;
      *)      die "protocol 用法: add|remove|edit|list" ;;
    esac
    ;;
  chain)
    case "${2:-show}" in
      setup)  chain_setup ;;
      show)   chain_show ;;
      export) chain_export ;;
      import) chain_import "${3:-}" ;;
      test)   chain_test ;;
      mode)   chain_mode "${3:-show}" ;;
      remove) chain_remove ;;
      *)      die "chain 用法: setup|show|export|import|test|mode|remove" ;;
    esac
    ;;
  warp)
    shift || true
    warp_dispatch "$@"
    ;;
  menu) : ;;  # 走交互菜单
  *) die "未知命令: $CMD（支持 install/info/config/fallback-test/fallback-cn-test/update-geo/upgrade/status/restart/uninstall/protocol/chain/warp）" ;;
esac

# ============ 交互菜单 ============
# 菜单正文在 lib/menu.sh（入口文件保持 ≤200 行）
if [[ "$CMD" == "menu" ]]; then
  main_menu
fi

exit 0
