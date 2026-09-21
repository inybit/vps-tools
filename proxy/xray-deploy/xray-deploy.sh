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

VERSION="1.11.0"   # 发布新功能时递增（配合 vps-tools 工具约定：新增工具必须支持 -v/-h）

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
  menu) : ;;  # 走交互菜单
  *) die "未知命令: $CMD（支持 install/info/config/fallback-test/fallback-cn-test/update-geo/upgrade/status/restart/uninstall/protocol/chain）" ;;
esac

# ============ 交互菜单 ============
if [[ "$CMD" == "menu" ]]; then
  while true; do
    echo
    echo "===== Xray 部署管理 ====="
    echo "  1) 安装/更新 Xray（首次部署向导）"
    echo "  2) 协议管理（新增/删除/修改）"
    echo "  3) 查看节点信息 (info)"
    echo "  4) 回落域名测试 (fallback-test)"
    echo "  5) 更新 geo 数据 (geosite/geoip)"
    echo "  6) 升级 Xray 版本（带版本号=回退，如: xray-deploy upgrade v26.7.28）"
    echo "  7) 查看/编辑配置 (config)"
    echo "  8) 服务状态"
    echo "  9) 重启服务"
    echo "  10) 中转 + 落地（链路）"
    echo "  11) 卸载"
    echo "  0) 退出"
    read_input "请选择 [0-11]: " choice || { log_warn "无交互终端，已退出"; break; }
    case "${choice:-0}" in
      1) cmd_install ;;
      2)
        echo "  1) 新增协议  2) 删除协议  3) 修改协议  4) 列表"
        read_input "选择 [1-4]: " pc || { log_warn "无交互终端"; continue; }
        case "${pc:-4}" in
          1) proto_add ;;
          2) proto_remove ;;
          3) proto_edit ;;
          *) [[ -f "$STATE_FILE" ]] && proto_list_names || echo "尚未安装" ;;
        esac
        ;;
      3) cmd_info ;;
      4)
        echo "  1) 测试全部候选  2) 测试指定域名  3) 中国方向检测(Globalping，需确认数据出境)"
        read_input "选择 [1-3]: " fc || { log_warn "无交互终端"; continue; }
        case "${fc:-1}" in
          1) cmd_fallback_test ;;
          2)
            read_input "输入要测试的域名: " fdom || { log_warn "无交互终端"; continue; }
            cmd_fallback_test "$fdom"
            ;;
          3)
            read_input "输入要检测的域名（回车=全部 tier4 候选）: " fdom || { log_warn "无交互终端"; continue; }
            cmd_fallback_cn_test "$fdom"
            ;;
          *) log_warn "无效选择" ;;
        esac
        ;;
      5) update_geo ;;
      6) cmd_upgrade ;;
      7)
        echo "  1) 查看配置  2) 编辑配置"
        read_input "选择 [1-2]: " cc || { log_warn "无交互终端"; continue; }
        case "${cc:-1}" in
          1) cmd_config show ;;
          2) cmd_config edit ;;
          *) log_warn "无效选择" ;;
        esac
        ;;
      8) need_root; service_status ;;
      9) need_root; service_restart ;;
      10)
        echo "  1) 查看链路拓扑  2) 配置链路(向导)  3) 导入落地参数  4) 自检"
        echo "  5) 切换分流模式  6) 拆除链路  7) 在【落地机】导出上游参数"
        read_input "选择 [1-7]: " chc || { log_warn "无交互终端"; continue; }
        case "${chc:-1}" in
          1) chain_show ;;
          2) chain_setup ;;
          3) chain_import ;;
          4) chain_test ;;
          5)
            routing_preset_list
            read_input "输入模式名（回车取消）: " cm || { continue; }
            [[ -n "${cm:-}" ]] && chain_mode "$cm" || log_info "已取消"
            ;;
          6) chain_remove ;;
          7) chain_export ;;
          *) log_warn "无效选择" ;;
        esac
        ;;
      11) cmd_uninstall ;;
      0) break ;;
      *) log_warn "无效选择" ;;
    esac
  done
fi

exit 0
