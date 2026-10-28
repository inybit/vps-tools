#!/usr/bin/env bash
# geo-timer.sh — geo 数据（geosite/geoip）每周自动更新：systemd oneshot + timer 的安装/查看/移除
#
# 为什么需要：分流规则靠 geosite:/geoip: 标签，MetaCubeX 规则库每周更新；
#   不更新 → 国内域名/IP 库漂移，分流逐渐失准。
#   而 Xray **只在启动时**加载 geo 数据 → 更新后必须重启才生效，
#   所以定时任务跑的是 `update-geo --quiet --restart`（内含 xray -test 校验与失败回滚）。
#
# ⚠️ unit 名不能叫 xray-deploy.service/.timer —— 那是常驻 daemon 的主服务 unit，
#    同名会把主服务覆盖掉（vnstat-monitor 那种「脚本即 oneshot」的命名法在这里是陷阱）。
# ⚠️ 调度统一 systemd timer（仓库约定 #4），不写 crontab / cron.weekly；
#    OpenRC 机器直接报不支持，不做半吊子替代。
# ⚠️ 安装器绝不代为执行工具命令 —— timer 由本工具自己的 install / geo-timer 子命令装。

GEO_SERVICE_NAME="xray-deploy-geo-update"
GEO_UNIT_DIR="${GEO_UNIT_DIR:-/etc/systemd/system}"          # 测试注入用
GEO_CMD_PATH="${GEO_CMD_PATH:-/usr/local/bin/xray-deploy}"   # install.sh 生成的 wrapper（透传参数）
GEO_CALENDAR_DEFAULT="Mon *-*-* 01:00:00"                    # 每周一 01:00
GEO_RANDOM_DELAY="6h"                                        # 随机抖动：避免一批机器整点同打 GitHub

# OnCalendar 校验：有 systemd-analyze 就真验一遍，没有则只做字符白名单
geo_timer_calendar_ok() {  # $1=表达式
  local c="${1:-}"
  [[ -n "$c" ]] || return 1
  [[ "$c" =~ ^[A-Za-z0-9*:.,/[:space:]-]+$ ]] || return 1
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar "$c" >/dev/null 2>&1 || return 1
  fi
  return 0
}

geo_timer_write_units() {  # $1=OnCalendar（空=默认）
  local cal="${1:-$GEO_CALENDAR_DEFAULT}"
  mkdir -p "$GEO_UNIT_DIR" || return 1
  cat > "${GEO_UNIT_DIR}/${GEO_SERVICE_NAME}.service" <<EOF
[Unit]
Description=xray-deploy geo 数据更新（geosite/geoip → 校验 → 重启服务）
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
# 失败（下载异常 / 尺寸闸 / xray -test 失败）→ 非 0 退出，systemd 记 failed；
# 线上 geo 数据与服务保持原状（update_geo 内部回滚）
# 显式把输出导到 journal：默认虽为 journal，但一旦发行版改 DefaultStandardOutput，
# 定时任务失败时就会只剩 "Result=failed" 而无任何原因可查。
StandardOutput=journal
StandardError=journal
SyslogIdentifier=xray-deploy-geo
ExecStart=${GEO_CMD_PATH} update-geo --quiet --restart
EOF
  cat > "${GEO_UNIT_DIR}/${GEO_SERVICE_NAME}.timer" <<EOF
[Unit]
Description=每周更新 xray-deploy geo 数据（geosite/geoip）

[Timer]
OnCalendar=${cal}
RandomizedDelaySec=${GEO_RANDOM_DELAY}
# 关机/停机错过触发点 → 下次开机补跑
Persistent=true
Unit=${GEO_SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF
  return 0
}

geo_timer_install() {  # [OnCalendar 表达式]
  local cal="${1:-$GEO_CALENDAR_DEFAULT}"
  need_root
  if [[ "$(detect_init)" != "systemd" ]]; then
    log_err "当前 init 不是 systemd（$(detect_init)）—— geo 定时更新只提供 systemd timer"
    log_err "  手动更新: sudo xray-deploy update-geo --restart"
    return 1
  fi
  geo_timer_calendar_ok "$cal" || die "OnCalendar 表达式非法: ${cal}（例: 'Mon *-*-* 01:00:00'）"
  [[ -x "$GEO_CMD_PATH" ]] || log_warn "找不到 ${GEO_CMD_PATH}（unit 照写，命令装好后 systemctl start 即可）"
  geo_timer_write_units "$cal" || die "写入 unit 失败: ${GEO_UNIT_DIR}"
  systemctl daemon-reload
  systemctl enable --now "${GEO_SERVICE_NAME}.timer" >/dev/null 2>&1 \
    || die "启用 timer 失败: ${GEO_SERVICE_NAME}.timer"
  # enable --now 对【已运行】的 timer 不重载新配置 → restart 强制生效（未运行=启动）
  systemctl restart "${GEO_SERVICE_NAME}.timer" >/dev/null 2>&1 || true
  log_info "已安装 geo 更新定时任务: ${cal}（随机抖动 ≤${GEO_RANDOM_DELAY}）"
  log_info "  ${GEO_UNIT_DIR}/${GEO_SERVICE_NAME}.timer"
  geo_timer_status
}

geo_timer_status() {
  local init state last
  init="$(detect_init)"
  if [[ "$init" != "systemd" ]]; then
    echo "geo 更新定时任务: 不支持（init=${init}，仅 systemd）"
    return 0
  fi
  if [[ ! -f "${GEO_UNIT_DIR}/${GEO_SERVICE_NAME}.timer" ]]; then
    echo "geo 更新定时任务: 未安装（安装: sudo xray-deploy geo-timer install）"
    return 0
  fi
  state="$(systemctl is-active "${GEO_SERVICE_NAME}.timer" 2>/dev/null || true)"
  echo "geo 更新定时任务: ${state:-unknown}"
  systemctl show "${GEO_SERVICE_NAME}.timer" \
    -p NextElapseUSecRealtime -p LastTriggerUSec 2>/dev/null | sed 's/^/  /' || true
  last="$(systemctl show "${GEO_SERVICE_NAME}.service" -p Result -p ExecMainStatus 2>/dev/null \
          | tr '\n' ' ' || true)"
  [[ -n "${last// /}" ]] && echo "  上次运行: ${last}"
  return 0
}

geo_timer_remove() {
  need_root
  if [[ "$(detect_init)" == "systemd" ]]; then
    systemctl stop "${GEO_SERVICE_NAME}.timer" 2>/dev/null || true
    systemctl disable "${GEO_SERVICE_NAME}.timer" 2>/dev/null || true
  fi
  rm -f "${GEO_UNIT_DIR}/${GEO_SERVICE_NAME}.service" "${GEO_UNIT_DIR}/${GEO_SERVICE_NAME}.timer"
  if command -v systemctl >/dev/null 2>&1; then systemctl daemon-reload || true; fi
  log_info "已移除 geo 更新定时任务（geo 数据与主服务保留）"
}

geo_timer_dispatch() {
  local sub="${1:-status}"
  shift || true
  case "$sub" in
    install) geo_timer_install "${1:-}" ;;
    status)  geo_timer_status ;;
    remove)  geo_timer_remove ;;
    *)       die "geo-timer 用法: install [OnCalendar 表达式] | status | remove" ;;
  esac
}
