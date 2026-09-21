#!/usr/bin/env bash
# cmd-lifecycle.sh — 生命周期命令：install / upgrade / uninstall / config

# ============ 安装向导 ============
cmd_install() {
  need_root
  if [[ -f "$STATE_FILE" ]] && [[ "$(jq '.protocols | length' "$STATE_FILE")" -gt 0 ]]; then
    log_warn "检测到已有部署，将仅升级二进制并重载配置（如需重新部署请先 uninstall）"
    cmd_upgrade
    return 0
  fi

  install_xray
  update_geo
  state_init
  state_set --arg ip "$(detect_server_ip)" '.server_ip = $ip'
  # 记录本次实际安装的 Xray 版本（info 展示 + 供排障对照）
  local xver
  # ⚠️ sed -n 1p 而非 `| head -1`：head 读够即关管道 → 上游收 SIGPIPE(141) →
  #    在 set -o pipefail 下整条管道返回非 0（间歇性，取决于输出量与缓冲的竞态）
  xver="$("${BIN_PATH}" version 2>/dev/null | sed -n 1p | awk '{print $2}' || true)"
  [[ -n "$xver" ]] && state_set --arg v "$xver" '.xray_version = $v'

  # 选择部署协议（回车默认 1 = VLESS-TCP-XTLS-Vision-REALITY）
  echo "可选部署协议:"
  local i=1 line disp
  for line in "${PROTO_REGISTRY[@]}"; do
    IFS='|' read -r _ disp _ <<<"$line"
    echo "  $i) $disp"
    i=$((i+1))
  done
  read -r -p "选择部署协议 [1-$((i-1))，回车默认 1（VLESS-TCP-XTLS-Vision-REALITY）]: " t
  t="${t:-1}"
  [[ "$t" =~ ^[0-9]+$ ]] && [[ "$t" -ge 1 ]] && [[ "$t" -le "$((i-1))" ]] || die "无效选择"
  local type="${PROTO_REGISTRY[$((t-1))]%%|*}"

  local name="${type}-01"
  local params
  case "$type" in
    vless-reality) params="$(proto_wizard_vless_reality "$name")" || die "协议参数生成失败" ;;
    vless-xhttp-reality) params="$(proto_wizard_vless_xhttp_reality "$name")" || die "协议参数生成失败" ;;
    vless-xhttp)   params="$(proto_wizard_vless_xhttp "$name")" || die "协议参数生成失败" ;;
    vless-xhttp3-nginx) params="$(proto_wizard_vless_xhttp3_nginx "$name")" || die "协议参数生成失败" ;;
    hysteria2)     params="$(proto_wizard_hysteria2 "$name")" || die "协议参数生成失败" ;;
    ss2022)        params="$(proto_wizard_ss2022 "$name")" || die "协议参数生成失败" ;;
    *) die "未知协议类型: $type" ;;
  esac
  state_set --argjson p "$params" '.protocols = [$p]'
  # 该协议是 REALITY 类 且 装的 Xray >= 分界版本 → 提示 sing-box 客户端不可用
  case "$type" in
    vless-reality|vless-xhttp-reality)
      [[ -n "$xver" ]] && warn_mlkem_if_needed "v${xver}" ;;
  esac

  # XHTTP3-NGINX 需要 unit 里的 RuntimeDirectory 预建 socket 目录（Xray 不自动建目录）
  if [[ "$type" == "vless-xhttp3-nginx" ]]; then
    xhttp3_ensure_service_unit
  else
    install_service_file
  fi
  rebuild_and_reload
  service_start
  log_info "安装完成！运行 'xray-deploy.sh info' 查看节点信息"
  log_info "geo 数据更新: 运行 'xray-deploy update-geo'（手动，或自行配 systemd timer）"
}

# ============ 卸载 ============
cmd_uninstall() {
  need_root
  read -r -p "确认卸载 Xray 部署（删除二进制/配置/服务/定时）？[y/N]: " yn
  [[ "${yn,,}" == "y" ]] || { log_info "已取消"; return 0; }
  service_stop
  rm -f "/etc/systemd/system/${SERVICE_NAME}.service" "/etc/init.d/${SERVICE_NAME}"
  rm -f "/etc/cron.weekly/xray-geo-update"
  rm -rf "${INSTALL_DIR}" "${CONFIG_DIR}"
  if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload; fi
  log_info "已卸载（state.json 一并删除，包含密钥）"
}

# ============ 配置查看/编辑 ============
cmd_config() {  # $1=show|edit
  local action="${1:-show}"
  case "$action" in
    show)
      [[ -f "$CONFIG_FILE" ]] || die "尚未生成配置（先 install）"
      echo "=== ${CONFIG_FILE} ==="
      cat "$CONFIG_FILE"
      ;;
    edit)
      need_root
      [[ -f "$CONFIG_FILE" ]] || die "尚未生成配置（先 install）"
      if command -v nano >/dev/null 2>&1; then
        nano "$CONFIG_FILE"
      elif command -v vim >/dev/null 2>&1; then
        vim "$CONFIG_FILE"
      else
        vi "$CONFIG_FILE"
      fi
      # 编辑后校验 + 重载
      if "${BIN_PATH}" run -test -format=json -config "$CONFIG_FILE" >/dev/null 2>&1; then
        service_restart
        log_info "配置校验通过并已重载服务"
      else
        log_err "配置校验失败——请手动修正（服务仍运行旧配置）"
        return 1
      fi
      ;;
    *) die "config 用法: show|edit" ;;
  esac
}
