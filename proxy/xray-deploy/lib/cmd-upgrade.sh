#!/usr/bin/env bash
# cmd-upgrade.sh — 升级 / 回退（切换）Xray 内核版本
#
# 从 cmd-lifecycle.sh 拆出（2026-09-21）：加入「显式指定版本」后 cmd_upgrade 增长到 90 行，
# 原文件达 201 行触及单文件上限。拆分仅移动函数，函数体逐字不变（split 套件可证）。

# ============ 升级 / 切换版本 ============
# $1 = 目标 tag（可带或不带 v 前缀）；省略 = 升到最新（原行为）
#
# 为什么需要指定版本（2026-09-21 用户报障「xray-deploy 无法回退 xray 内核到指定版本」）：
#   此前「能选版本」的只有【首次安装向导】一条路 —— 装好之后 upgrade 恒定升到 GitHub
#   最新版，且本地比远端新时主动跳过（防降级）→ 一旦被升到 >= v26.9.8，sing-box
#   客户端静默不可用（上游 #4520），而【没有任何命令能退回去】。
#   故 upgrade 接受显式 tag：显式指定 = 用户意图明确，允许降级。
#
# ⚠️ 语义边界（勿混）：无参数路径 = 「升级」，仍走 ver_gt 防降级；
#    带参数路径 = 「切换/回退」，不做 ver_gt 判断（降级正是其用途）。
#    两者共用同一套「备份 → 下载 → 失败回滚 → 同步 state」逻辑，不复制代码。
cmd_upgrade() {
  need_root
  [[ -x "$BIN_PATH" ]] || die "Xray 未安装，先运行 install"
  # 依赖自检（2026-09-21 补）：install_xray 有 install_deps，而 upgrade 此前没有 ——
  #   缺 unzip 时解压报「zip 损坏?」，把「依赖缺失」误报成「包损坏」，
  #   在最小化镜像上表现为「升级/回退永远失败且原因看不出」。
  #   install_deps 幂等：依赖齐全时首个循环即 return 0，无包管理操作。
  install_deps
  local cur latest target explicit=0
  # ⚠️ sed -n 1p 而非 `| head -1`（SIGPIPE 竞态见 Pitfall 31 / xray-bin.sh 文件头）
  cur="$("${BIN_PATH}" version 2>/dev/null | sed -n 1p | awk '{print $2}' || true)"
  [[ -n "$cur" ]] || die "无法读取当前 Xray 版本（${BIN_PATH} version 无输出）"
  cur="${cur#v}"

  target="${1:-}"
  if [[ -n "$target" ]]; then
    explicit=1
    target="$(normalize_xray_tag "$target")" || die "版本号格式非法: $1（示例: v26.7.28 或 26.7.28）"
    [[ "$target" == "v${cur}" ]] && { log_info "已是 ${target}，无需切换"; return 0; }
  else
    latest="$(latest_xray_tag)" || die "无法获取最新版本"
    [[ -n "$latest" ]] || die "无法解析最新版本号（GitHub API 返回异常）"
    target="v${latest#v}"
    if [[ "v${cur}" == "$target" ]]; then
      log_info "已是最新版本 ${cur}"; return 0
    fi
    # ⚠️ 必须做语义化比较，不能用「不相等就升级」：
    #    已装版本比远端新时（远端 API 异常/回退、或手动装了更新的版本）
    #    字符串比较会判定「需要升级」并执行【降级】，把新二进制换回旧版。
    if ver_gt "$cur" "${target#v}"; then
      log_warn "本地 ${cur} 比远端最新 ${target#v} 更新，跳过（避免降级）"
      log_warn "  如需回退到指定版本：sudo xray-deploy upgrade v26.7.28"
      return 0
    fi
  fi

  # 显式指定的 tag 必须在发布列表里 —— 防手滑打错字装了个不存在的版本。
  # 列表拿不到（离线/配额）时降级为「无法校验」提示，不阻断（用户可能确有需要）。
  if [[ "$explicit" -eq 1 ]]; then
    local all rc=0
    all="$(_xray_tags_all)" || rc=$?
    if [[ $rc -ne 0 ]]; then
      log_warn "无法获取发布列表（网络/配额），跳过 tag 校验，直接尝试下载 ${target}"
    elif ! grep -qxF "$target" <<<"$all"; then
      log_err "发布列表中不存在 ${target} —— 可能版本号打错（最近 10 个）:"
      sed -n '1,10p' <<<"$all" | sed 's/^/    /' >&2
      die "拒绝下载不存在的版本: ${target}"
    fi
  fi

  if [[ "$explicit" -eq 1 ]]; then
    if ver_gt "$cur" "${target#v}"; then
      log_info "回退/切换 Xray 版本 ${cur} → ${target#v}（显式指定，允许降级）"
    else
      log_info "切换 Xray 版本 ${cur} → ${target#v}（显式指定）"
    fi
  else
    log_info "升级 ${cur} → ${target#v}"
  fi
  warn_mlkem_if_needed "$target"

  # 备份旧二进制，失败回滚
  cp "$BIN_PATH" "${BIN_PATH}.bak"
  if download_xray "$target"; then
    # ⚠️ 必须校验下载后的实际版本：失败会静默回滚成【升级前】的版本，
    #    此前是空操作（进程内变量未更新）—— 现在显式回写，防 state 与磁盘不一致。
    local got
    got="$("${BIN_PATH}" version 2>/dev/null | sed -n 1p | awk '{print $2}' || true)"
    if [[ -n "$got" ]] && ver_gt "$got" "${target#v}"; then
      log_err "下载后二进制版本为 ${got}，高于目标 ${target#v}（下载内容异常）"
    elif [[ -n "$got" && "$got" != "${target#v}" ]]; then
      log_warn "下载后二进制版本为 ${got}，与目标 ${target#v} 不一致（请核对发布资产）"
    fi
    service_restart
    rm -f "${BIN_PATH}.bak"
    # 同步记录已装版本（info 展示用）；以磁盘实际版本为准，读不到才回退目标值
    [[ -f "$STATE_FILE" ]] && state_set --arg v "${got:-${target#v}}" '.xray_version = $v'
    log_info "升级完成: ${target}"
  else
    mv "${BIN_PATH}.bak" "$BIN_PATH"
    die "升级失败，已回滚到 ${cur}"
  fi
}
