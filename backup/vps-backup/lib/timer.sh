#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：systemd timer（core 6h / data 每日 / 维护每周）
#
# 用 timer 不用 cron（vps-tools 统一约定）。
# core 与 data 分不同 timer：core 高频小体量，data 低频大体量。
# ============================================================

vp_unit_path() { echo "${VP_UNIT_DIR}/$1"; }

# 三个 service（oneshot）+ 三个 timer
vp_write_units() {
  local d="${VP_UNIT_DIR}"
  mkdir -p "$d"

  # 备份单元（参数化：%i = core|data）
  cat > "${d}/vps-backup-backup@.service" <<'EOF'
[Unit]
Description=vps-backup %i layer (oneshot)
After=network-online.target
Wants=network-online.target
OnFailure=vps-backup-failnotify@%i.service

[Service]
Type=oneshot
EnvironmentFile=-/etc/vps-backup.env
ExecStart=/usr/local/bin/vps-backup backup %i
EOF

  cat > "${d}/vps-backup-backup@core.timer" <<EOF
[Unit]
Description=Run vps-backup core layer every ${VP_CORE_INTERVAL_HOURS} hours

[Timer]
OnCalendar=${VP_CORE_ONCALENDAR}
Persistent=true
RandomizedDelaySec=5m

[Install]
WantedBy=timers.target
EOF

  cat > "${d}/vps-backup-backup@data.timer" <<EOF
[Unit]
Description=Run vps-backup data layer daily

[Timer]
OnCalendar=${VP_DATA_ONCALENDAR}
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF

  # 维护单元（forget + prune + check）
  cat > "${d}/vps-backup-maintain.service" <<'EOF'
[Unit]
Description=vps-backup retention + integrity check (oneshot)
After=network-online.target
Wants=network-online.target
OnFailure=vps-backup-failnotify@maintain.service

[Service]
Type=oneshot
EnvironmentFile=-/etc/vps-backup.env
ExecStart=/usr/local/bin/vps-backup maintain
EOF

  cat > "${d}/vps-backup-maintain.timer" <<EOF
[Unit]
Description=Run vps-backup retention + check weekly

[Timer]
OnCalendar=${VP_MAINTAIN_ONCALENDAR}
Persistent=true
RandomizedDelaySec=30m

[Install]
WantedBy=timers.target
EOF

  # 失败兜底通知（脚本自身无法运行时的最后一道：如 restic 缺失/env 缺失）
  cat > "${d}/vps-backup-failnotify@.service" <<'EOF'
[Unit]
Description=vps-backup failure notification for %i

[Service]
Type=oneshot
EnvironmentFile=-/etc/vps-backup.env
ExecStart=/usr/local/bin/vps-backup notify-failure %i
EOF
}

vp_timer_install() {
  require_root
  load_env
  vp_write_units || { log_err "unit 写入失败"; return 1; }
  systemctl daemon-reload
  local u
  for u in vps-backup-backup@core.timer vps-backup-backup@data.timer vps-backup-maintain.timer; do
    systemctl enable --now "$u" >/dev/null 2>&1 || { log_err "启用失败: $u"; return 1; }
    # enable --now 对已运行的 timer 不重载新配置；restart 强制生效
    systemctl restart "$u" >/dev/null 2>&1 || true
  done
  log_ok "已安装 systemd timer:"
  log_info "  core     每 ${VP_CORE_INTERVAL_HOURS} 小时（${VP_CORE_ONCALENDAR}）"
  log_info "  data     每日（${VP_DATA_ONCALENDAR}）"
  log_info "  maintain 每周（${VP_MAINTAIN_ONCALENDAR}）"
  return 0
}

vp_timer_status() {
  local u
  for u in vps-backup-backup@core.timer vps-backup-backup@data.timer vps-backup-maintain.timer; do
    if systemctl list-timers --all 2>/dev/null | grep -q "${u%%:*}"; then
      echo "  ${u}:"
      systemctl list-timers --all "$u" --no-pager 2>/dev/null | sed -n '2p' | sed 's/^/    /'
    else
      echo "  ${u}: 未安装/未激活"
    fi
  done
  local svc
  for svc in vps-backup-backup@core vps-backup-backup@data vps-backup-maintain; do
    echo "  最近一次 ${svc}: $(systemctl show -p ExecMainStatus --value "$svc" 2>/dev/null || echo '?')"
  done
}

vp_timer_uninstall() {
  require_root
  local u
  for u in vps-backup-backup@core.timer vps-backup-backup@data.timer vps-backup-maintain.timer; do
    systemctl stop "$u" 2>/dev/null || true
    systemctl disable "$u" 2>/dev/null || true
  done
  rm -f "${VP_UNIT_DIR}"/vps-backup-backup@.service \
        "${VP_UNIT_DIR}"/vps-backup-backup@core.timer \
        "${VP_UNIT_DIR}"/vps-backup-backup@data.timer \
        "${VP_UNIT_DIR}"/vps-backup-maintain.service \
        "${VP_UNIT_DIR}"/vps-backup-maintain.timer \
        "${VP_UNIT_DIR}"/vps-backup-failnotify@.service
  systemctl daemon-reload
  log_ok "已移除 vps-backup timer 与 service（配置与 repo 保留）"
}
