#!/usr/bin/env bash
# menu.sh — 交互式管理菜单（纯视图层，业务逻辑全在各 lib 的命令函数里）
#
# 从 xray-deploy.sh 抽出（2026-10-28）：入口文件原本 205 行，新增 WARP 菜单项后 224 行，
# 超「单文件 ≤200 行」仓库约定。菜单是纯分发视图，天然适合独立成文件。

main_menu() {
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
    echo "  11) WARP 回国出站（WireGuard）"
    echo "  12) 卸载"
    echo "  0) 退出"
    read_input "请选择 [0-12]: " choice || { log_warn "无交互终端，已退出"; break; }
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
        echo "  1) 测试本地区候选  2) 测试指定域名  3) 测试全部候选(--all，跨地区)  4) 中国方向检测(Globalping，需确认数据出境)"
        read_input "选择 [1-4]: " fc || { log_warn "无交互终端"; continue; }
        case "${fc:-1}" in
          1) cmd_fallback_test ;;
          2)
            read_input "输入要测试的域名: " fdom || { log_warn "无交互终端"; continue; }
            cmd_fallback_test "$fdom"
            ;;
          3) cmd_fallback_test --all ;;
          4)
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
      11)
        echo "  1) 导入 wgcf-profile.conf（启用 WARP 回国出站）  2) 查看状态"
        echo "  3) 自检  4) 移除"
        read_input "选择 [1-4]: " wc || { log_warn "无交互终端"; continue; }
        case "${wc:-1}" in
          1) warp_setup ;;
          2) warp_show ;;
          3) warp_test ;;
          4) warp_remove ;;
          *) log_warn "无效选择" ;;
        esac
        ;;
      12) cmd_uninstall ;;
      0) break ;;
      *) log_warn "无效选择" ;;
    esac
  done
}
