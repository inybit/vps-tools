#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：rclone remote 体检（分态诊断）
# 被 vps-backup.sh source（由 lib/repo.sh 拆出，2026-09-19）
# ============================================================

# ---------- rclone remote 体检 ----------
# ⚠️ 为什么必须分态诊断（2026-09-19 真机实测 + 本地对照复现）：
#   原实现只做 `listremotes | grep -qx "<remote>:"`，且把 rclone 的 stderr 全部 `2>/dev/null` 吞掉。
#   于是**四种完全不同的故障**输出同一句误导文案「remote 未配置」，用户被指向错误方向：
#     A) remote 名不匹配（机器上是 gdrive-remote，env 写 gdrive）  ← 本次用户实际踩的
#     B) 配置文件语法损坏（rclone CRITICAL: could not parse line）
#     C) VP_RCLONE_CONFIG 指向不存在的文件（rclone NOTICE 后按空配置继续）
#     D) 真的没配任何 remote
#   契约：**吞掉 stderr 可以，但必须自己复现原因**——把 rclone 真实输出呈现给用户。
vp_rclone_cfg_path() {
  "${VP_RCLONE_BIN}" config file 2>/dev/null | tail -1
}

# 探测 remote 状态。输出一行：<状态>|<实有 remote 列表>
#   ok | notfound | down | nocfg
vp_remote_probe() {
  local want="${VP_RCLONE_REMOTE}:" out
  # ⚠️ 不接 stderr：此处失败 = 配置文件读不了（语法错/权限/路径不存在），
  #    与「没配 remote」是两种故障，必须区分（见上方注释）。
  if ! out="$("${VP_RCLONE_BIN}" listremotes 2>&1)"; then
    printf 'nocfg|%s\n' "$(tr '\n' ' ' <<< "$out")"
    return 0
  fi
  local names; names="$(tr '\n' ' ' <<< "$out")"
  if ! grep -qxF "$want" <<< "$out"; then
    printf 'notfound|%s\n' "$names"
    return 0
  fi
  if "${VP_RCLONE_BIN}" lsd "$want" >/dev/null 2>&1; then
    printf 'ok|%s\n' "$names"
  else
    printf 'down|%s\n' "$names"
  fi
}

vp_remote_check() {
  vp_have_rclone || { log_err "rclone 未安装"; return 1; }

  local probe state names
  probe="$(vp_remote_probe)"
  state="${probe%%|*}"
  names="${probe#*|}"

  case "$state" in
    ok)
      log_ok "rclone remote 可用: ${VP_RCLONE_REMOTE}:"
      local about
      about="$("${VP_RCLONE_BIN}" about "${VP_RCLONE_REMOTE}:" 2>/dev/null | tr '\n' ' ')"
      [[ -n "$about" ]] && log_info "配额: ${about}"
      return 0
      ;;
    notfound)
      # 名字不匹配是最常见的一种（本次用户实际踩的），必须把实有名字摆出来
      log_err "rclone remote 名不匹配: 配置里写的是 '${VP_RCLONE_REMOTE}'，但 rclone 里没有这个 remote"
      if [[ -n "${names// /}" ]]; then
        log_err "  rclone 实有 remote: ${names}"
        log_err "  修正（二选一）:"
        log_err "    ① 改工具配置: 把 ${VP_ENV_FILE} 的 VP_RCLONE_REMOTE 改成上面某个名字"
        log_err "    ② 改 rclone: rclone config → 重命名该 remote 为 '${VP_RCLONE_REMOTE}'"
        log_err "  ⚠️ VP_RCLONE_REMOTE 只填【裸名】，不要带冒号或路径"
      else
        log_err "  rclone 里一个 remote 都没有 —— 请先配置: rclone config"
        log_err "  （Google Drive 须自建 OAuth client_id，见 runbook）"
      fi
      return 1
      ;;
    nocfg)
      log_err "rclone 无法读取配置文件（语法错误 / 权限 / 路径不存在）"
      log_err "  rclone 原始输出: ${names}"
      log_err "  配置文件位置: $(vp_rclone_cfg_path)"
      log_err "  排查: rclone config file ; rclone listremotes"
      [[ -n "${VP_RCLONE_CONFIG}" ]] && \
        log_err "  当前 VP_RCLONE_CONFIG=${VP_RCLONE_CONFIG}（确认该文件存在且格式正确）"
      return 1
      ;;
    down)
      log_err "rclone remote 存在但无法访问（token 过期？授权 7 天到期？）"
      log_err "  重授权: rclone config reconnect ${VP_RCLONE_REMOTE}:"
      log_err "  自检: rclone lsd ${VP_RCLONE_REMOTE}:"
      return 1
      ;;
  esac
  log_err "rclone remote 状态未知: ${state}"
  return 1
}
