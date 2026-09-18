#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：保留策略 / 清理 / 通知
# ============================================================

# 保留策略（forget）+ 空间回收（prune）
# forget 的 --keep-* 之间是 OR（命中任一即保留），默认按 host,paths 分组 —— 同机同路径互相淘汰，安全。
vp_retention_main() {  # $1=forget|prune|maintain（默认 maintain = forget+prune+check）
  local action="${1:-maintain}"
  vp_require_password || return 1
  vp_require_tools || return 1

  case "$action" in
    forget)
      log_info "应用保留策略: ${VP_RETENTION_ARGS}"
      # shellcheck disable=SC2086  # 有意分词（策略参数串）
      vp_restic_diag forget ${VP_RETENTION_ARGS} --host "${VP_HOST}" || { log_err "forget 失败"; return 1; }
      log_ok "保留策略已应用"
      ;;
    prune)
      log_info "回收未引用数据（prune）"
      vp_restic_diag prune || { log_err "prune 失败"; return 1; }
      log_ok "prune 完成"
      ;;
    maintain)
      vp_retention_main forget || return 1
      vp_retention_main prune || return 1
      vp_repo_check || return 1
      local freed
      freed="$(vp_restic stats --mode raw-data 2>/dev/null | grep -i 'Total Size' || true)"
      [[ -n "$freed" ]] && log_info "repo 用量: ${freed}"
      ;;
    *) log_err "未知动作: $action（forget|prune|maintain）"; return 1 ;;
  esac
  return 0
}

# ---------- 通知（Telegram；沿用 vnstat-monitor 的 API 形态） ----------
vp_notify() {  # $1=文本
  [[ "${VP_NOTIFY}" == "1" ]] || return 0
  [[ -n "${VP_TG_BOT_TOKEN}" && -n "${VP_TG_CHAT_ID}" ]] || return 0
  # ⚠️ 通知失败绝不阻塞备份（备份成功与否由 restic 退出码决定）
  curl -s --max-time 20 -X POST "https://api.telegram.org/bot${VP_TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${VP_TG_CHAT_ID}" -d "parse_mode=HTML" \
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
  return 0
}

# 通知自检（setup 时用，失败要显式告知而非静默）
vp_notify_test() {
  if [[ "${VP_NOTIFY}" != "1" ]]; then
    log_info "通知已关闭（VP_NOTIFY=0）"
    return 0
  fi
  if [[ -z "${VP_TG_BOT_TOKEN}" || -z "${VP_TG_CHAT_ID}" ]]; then
    log_warn "未配置 Telegram token/chat_id —— 失败告警不会送达"
    return 1
  fi
  local resp
  resp="$(curl -s --max-time 20 -X POST "https://api.telegram.org/bot${VP_TG_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${VP_TG_CHAT_ID}" -d "parse_mode=HTML" \
    --data-urlencode "text=🔔 vps-backup[${VP_HOST}] 通知自检" 2>/dev/null || true)"
  if grep -q '"ok":true' <<< "$resp"; then
    log_ok "Telegram 通知自检成功"
    return 0
  fi
  log_err "Telegram 通知自检失败: ${resp:0:200}"
  return 1
}
