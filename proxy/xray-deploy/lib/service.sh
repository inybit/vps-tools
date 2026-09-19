#!/usr/bin/env bash
# service.sh — 服务控制（systemd/OpenRC）/ unit 文件写入 / 端口与防火墙检查

# ============ 服务控制 ============
service_start() {
  local init
  init="$(detect_init)"
  case "$init" in
    systemd) systemctl daemon-reload && systemctl enable --now "${SERVICE_NAME}" ;;
    openrc)  rc-update add "${SERVICE_NAME}" default && rc-service "${SERVICE_NAME}" start ;;
    *) die "不支持的 init 系统（仅 systemd/OpenRC）" ;;
  esac
}

service_restart() {
  local init
  init="$(detect_init)"
  case "$init" in
    systemd) systemctl restart "${SERVICE_NAME}" ;;
    openrc)  rc-service "${SERVICE_NAME}" restart ;;
    *) die "不支持的 init 系统" ;;
  esac
}

service_stop() {
  local init
  init="$(detect_init)"
  case "$init" in
    systemd) systemctl stop "${SERVICE_NAME}" 2>/dev/null || true ;;
    openrc)  rc-service "${SERVICE_NAME}" stop 2>/dev/null || true ;;
  esac
}

service_status() {
  local init
  init="$(detect_init)"
  case "$init" in
    systemd) systemctl status "${SERVICE_NAME}" --no-pager || true ;;
    openrc)  rc-service "${SERVICE_NAME}" status || true ;;
  esac
}

# ============ 服务文件安装 ============
install_service_file() {
  local init
  init="$(detect_init)"
  case "$init" in
    systemd)
      cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Xray (xray-deploy)
After=network.target

[Service]
Type=simple
# RuntimeDirectory：systemd 建/清 ${UDS_BASE_DIR}（Xray 不自动建 socket 目录；
# 且 SIGKILL 后残留 socket 会导致重启 bind: address already in use）
RuntimeDirectory=$(basename "$UDS_BASE_DIR")
RuntimeDirectoryMode=0755
ExecStart=${BIN_PATH} run -config ${CONFIG_FILE}
Environment=XRAY_LOCATION_ASSET=${INSTALL_DIR}
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
      ;;
    openrc)
      # OpenRC 无 RuntimeDirectory 等价物 → 显式建目录（start_pre）/ 清理（stop_post）
      cat > "/etc/init.d/${SERVICE_NAME}" <<EOF
#!/sbin/openrc-run
name="${SERVICE_NAME}"
command="${BIN_PATH}"
command_args="run -config ${CONFIG_FILE}"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
export XRAY_LOCATION_ASSET="${INSTALL_DIR}"
depend() {
  need net
}
start_pre() {
  mkdir -p "${UDS_BASE_DIR}" && chmod 0755 "${UDS_BASE_DIR}"
}
stop_post() {
  rm -rf "${UDS_BASE_DIR}"
}
EOF
      chmod +x "/etc/init.d/${SERVICE_NAME}"
      ;;
    *) die "不支持的 init 系统（仅 systemd/OpenRC）" ;;
  esac
  log_info "已写入自启服务（${init}）"
}

# ============ 端口检查 ============
# $1=port $2=proto（tcp|udp，默认 tcp）
# TCP/UDP 端口独立：reality(TCP 443) 与 hy2(UDP 443) 可共存，互不冲突
port_in_use() {
  local port="$1" proto="${2:-tcp}" out
  if [[ "$proto" == "udp" ]]; then
    out="$(ss -uln 2>/dev/null | awk '{print $4}' | grep -E ":${port}$" || true)"
  else
    out="$(ss -ltn 2>/dev/null | awk '{print $4}' | grep -E ":${port}$" || true)"
  fi
  [[ -n "$out" ]]
}

# ufw 放行检查/添加：$1=port $2=proto（tcp|udp）
# ufw 规则无协议后缀（如 "443"）时 TCP+UDP 均放行，无需重复添加
ensure_firewall() {
  local port="$1" proto="${2:-tcp}" rule
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -qi "Status: active" || return 0
  rule="$(ufw status 2>/dev/null | grep -E "^${port}(/|  )" || true)"
  if [[ -n "$rule" ]]; then
    # 已有规则（无协议后缀=双栈放行；或已含目标协议）
    log_info "防火墙已放行 ${port}（${proto}）"
  else
    log_info "防火墙放行 ${port}/${proto} ..."
    ufw allow "${port}/${proto}" >/dev/null 2>&1 || log_warn "ufw allow ${port}/${proto} 失败（可能已由其他规则覆盖）"
  fi
}
