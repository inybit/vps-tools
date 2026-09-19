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

# ============ 升级 ============
cmd_upgrade() {
  need_root
  [[ -x "$BIN_PATH" ]] || die "Xray 未安装，先运行 install"
  local cur latest
  cur="$("${BIN_PATH}" version | head -1 | awk '{print $2}')"
  latest="$(latest_xray_tag)" || die "无法获取最新版本"
  [[ -n "$latest" ]] || die "无法解析最新版本号（GitHub API 返回异常）"
  # xray version 输出无 v 前缀，tag 带 v 前缀
  cur="${cur#v}"; latest="${latest#v}"
  if [[ "$cur" == "$latest" ]]; then
    log_info "已是最新版本 ${cur}"; return 0
  fi
  # ⚠️ 必须做语义化比较，不能用「不相等就升级」：
  #    已装版本比远端新时（远端 API 异常/回退、或手动装了更新的版本）
  #    字符串比较会判定「需要升级」并执行【降级】，把新二进制换回旧版。
  if ver_gt "$cur" "$latest"; then
    log_warn "本地 ${cur} 比远端最新 ${latest} 更新，跳过（避免降级）"
    log_warn "  如需强制降级：手动下载 ${latest} 替换 ${BIN_PATH}"
    return 0
  fi
  log_info "升级 ${cur} → ${latest}"
  # 备份旧二进制，失败回滚
  cp "${BIN_PATH}" "${BIN_PATH}.bak"
  if download_xray "v${latest}"; then
    service_restart
    rm -f "${BIN_PATH}.bak"
    log_info "升级完成: ${latest}"
  else
    mv "${BIN_PATH}.bak" "${BIN_PATH}"
    die "升级失败，已回滚到 ${cur}"
  fi
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
