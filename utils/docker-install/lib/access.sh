#!/usr/bin/env bash
# ============================================================
# docker-install 模块：非 root 管理 Docker（docker 组）+ 文件读写权限
# 需求：① 非 root 管理 docker（含组≈root 等价告警）② 非 root 运行 docker 的文件读写权限
# perms 默认只 check（只读）；fix 必须显式指定路径，不做全盘 chown。
# ============================================================

# ---------- 解析目标用户 ----------
# $1=显式用户名（可空）→ 输出用户名；失败返回 1
resolve_target_user() {
  local u="${1:-${DI_DOCKER_USER:-}}"
  if [[ -z "$u" ]]; then
    if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
      u="$SUDO_USER"
      log_info "检测到 sudo 调用者: ${u}" >&2
    else
      # 无 SUDO_USER（root 直登）→ 询问。无 TTY 时必须给出可执行命令，
      # 否则用户只见 "[4/5]" 后一片空白，无从判断在等输入还是挂了（2026-09-19 真机踩坑）。
      if ! read_input "要加入 docker 组的用户名: " u; then
        u=""
        log_warn "无交互终端，跳过 docker 组配置。非交互: ${0##*/} user <用户名>" >&2
      fi
    fi
  fi
  if [[ -z "$u" ]]; then
    log_err "未指定用户名（用: ${0##*/} user <用户名> 或 DI_DOCKER_USER=<用户名>）" >&2
    return 1
  fi
  if ! id "$u" >/dev/null 2>&1; then
    log_err "用户不存在: ${u}" >&2
    return 1
  fi
  echo "$u"
}

# ---------- 加入 docker 组（幂等） ----------
user_main() {
  require_root
  local user; user="$(resolve_target_user "$1")" || return 1

  # 组不存在则创建（docker 安装器通常已建）
  if ! getent group docker >/dev/null 2>&1; then
    log_info "创建 docker 组..."
    groupadd docker 2>/dev/null || { log_err "groupadd docker 失败"; return 1; }
  fi
  local gid; gid="$(getent group docker | cut -d: -f3)"

  if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    log_info "${user} 已在 docker 组（GID ${gid}），无需变更"
  else
    log_info "将 ${user} 加入 docker 组..."
    usermod -aG docker "$user" || { log_err "usermod 失败"; return 1; }
    log_ok "已加入 docker 组（GID ${gid}）"
  fi

  # 安全告警（必读）
  echo "" >&2
  log_warn "⚠️ 安全告警: docker 组成员等价于 root 权限"
  log_warn "   组内用户可挂载宿主根目录、读写任意文件（docker run -v /:/host）。"
  log_warn "   仅在单用户/可信机器上使用；多人机器请改用 rootless 模式。"

  # 生效方式提示
  local cur="${USER:-}"
  if [[ "$cur" == "$user" ]]; then
    log_info "当前 shell 生效: newgrp docker   （或重新登录）"
  else
    log_info "${user} 需重新登录（或执行 newgrp docker）后生效"
  fi

  echo "" >&2
  log_info "验证（以 ${user} 身份）: docker ps"
  log_info "  失败且报 permission denied → 未重新登录，或 ${DI_SOCK} 权限异常"
}

# ---------- socket 权限修复（组路径下的兜底） ----------
sock_fix() {
  require_root
  [[ -S "${DI_SOCK}" ]] || { log_warn "socket 不存在: ${DI_SOCK}（docker 未运行？）"; return 1; }
  local before; before="$(stat -c '%U:%G %a' "${DI_SOCK}" 2>/dev/null)"
  chown root:docker "${DI_SOCK}" 2>/dev/null || true
  chmod 660 "${DI_SOCK}" 2>/dev/null || true
  local after; after="$(stat -c '%U:%G %a' "${DI_SOCK}" 2>/dev/null)"
  if [[ "$before" == "$after" ]]; then
    log_info "socket 权限已正确: ${after}"
  else
    log_ok "socket 权限修正: ${before} → ${after}"
  fi
  log_warn "注意: /etc/init.d/docker 或 systemd socket 激活可能重置为 666，"
  log_warn "      推荐用 docker 组而非放宽 socket 权限。"
}

# ---------- 权限检查（只读） ----------
# 逐项输出 [OK]/[WARN]/[FAIL]，返回 1 表示存在需处理项
perms_check() {
  local issues=0

  # 1. socket 属主/权限
  if [[ -S "${DI_SOCK}" ]]; then
    local sc; sc="$(stat -c '%U:%G %a' "${DI_SOCK}")"
    if [[ "$sc" == "root:docker 660" ]]; then
      log_ok "socket: ${DI_SOCK} ${sc}"
    elif [[ "$sc" == *" 666" ]]; then
      log_warn "socket 权限过宽: ${DI_SOCK} ${sc}（建议 root:docker 660 + docker 组）"
      issues=$((issues+1))
    else
      log_warn "socket 权限非常规: ${DI_SOCK} ${sc}（期望 root:docker 660）"
      issues=$((issues+1))
    fi
  else
    log_warn "socket 不存在: ${DI_SOCK}（docker 未运行？）"
    issues=$((issues+1))
  fi

  # 2. /var/lib/docker 必须 root 属主 + 0710（Docker 官方权限，moby daemon_unix.go:1400）
  if [[ -d "${DI_DOCKER_ROOT}" ]]; then
    local dr downer dmode
    dr="$(stat -c '%U:%G %a' "${DI_DOCKER_ROOT}")"
    downer="${dr% *}"; dmode="${dr##* }"
    if [[ "$downer" != "root:root" ]]; then
      log_err "docker root 属主异常: ${DI_DOCKER_ROOT} ${dr}（期望 root:root）"
      log_err "  非 root 用户不应拥有此目录；如需 rootless 请用独立 daemon"
      issues=$((issues+1))
    elif [[ "$dmode" != "710" && "$dmode" != "700" ]]; then
      # Docker 官方用 0710（root 可读写执行，group 仅执行）；0711/0755 等才是过宽
      log_warn "docker root 权限非常规: ${DI_DOCKER_ROOT} ${dr}（Docker 官方为 root:root 0710）"
      issues=$((issues+1))
    else
      log_ok "docker root: ${DI_DOCKER_ROOT} ${dr}"
    fi
  fi

  # 3. 每个 docker 组成员的家目录 ~/.docker 属主
  local members
  members="$(getent group docker 2>/dev/null | cut -d: -f4 | tr ',' ' ')"
  if [[ -z "${members// /}" ]]; then
    log_warn "docker 组无成员（非 root 管理未配置）—— 执行: ${0##*/} user <用户名>"
    issues=$((issues+1))
  else
    local m home ddir
    for m in $members; do
      home="$(getent passwd "$m" | cut -d: -f6)"
      [[ -z "$home" || ! -d "$home" ]] && continue
      ddir="${home}/.docker"
      if [[ -e "$ddir" ]]; then
        local own; own="$(stat -c '%U' "$ddir")"
        if [[ "$own" == "$m" ]]; then
          log_ok "docker CLI 配置目录: ${ddir} 属主 ${own}"
        else
          log_err "docker CLI 配置目录属主错误: ${ddir} 属主 ${own}（应为 ${m}）—— CLI 将报权限错误"
          issues=$((issues+1))
        fi
      else
        log_info "配置目录尚未创建: ${ddir}（${m} 首次运行 docker 时自动创建，属主将正确）"
      fi
    done
  fi

  # 4. bind mount 目录属主漂移（容器以 root 写入 → 宿主目录变 root-owned）
  local scan d found_root=0
  for scan in ${DI_SCAN_DIRS}; do
    [[ -d "$scan" ]] || continue
    while IFS= read -r d; do
      [[ -z "$d" ]] && continue
      found_root=1
      log_warn "bind mount 目录属主为 root: ${d}（非 root 用户无法写入）"
      log_warn "  修正: ${0##*/} perms fix ${d}"
      issues=$((issues+1))
    done < <(find "$scan" -maxdepth 2 -uid 0 -type d 2>/dev/null | head -20)
  done
  [[ "$found_root" == "0" ]] && log_info "未发现 root-owned 的 bind mount 目录（扫描: ${DI_SCAN_DIRS}）"

  echo "" >&2
  if [[ "$issues" == "0" ]]; then
    log_ok "权限检查通过，无非 root 读写障碍"
    return 0
  fi
  log_warn "权限检查发现 ${issues} 项待处理（fix 需显式指定路径，不做全盘 chown）"
  return 1
}

# ---------- 权限修复（显式路径） $1=路径 $2=目标属主（默认 docker 组第一个成员） ----------
perms_fix() {
  require_root
  local path="$1"
  [[ -n "$path" ]] || { log_err "用法: perms fix <路径>（必须显式指定，防误 chown 全盘）"; return 1; }
  [[ -e "$path" ]] || { log_err "路径不存在: ${path}"; return 1; }

  local owner="${2:-}"
  if [[ -z "$owner" ]]; then
    owner="$(getent group docker 2>/dev/null | cut -d: -f4 | tr ',' ' ' | awk '{print $1}')"
  fi
  [[ -n "$owner" ]] || { log_err "无法确定目标属主，请显式指定: perms fix <路径> <用户>"; return 1; }
  id "$owner" >/dev/null 2>&1 || { log_err "用户不存在: ${owner}"; return 1; }

  local before; before="$(stat -c '%U:%G' "$path")"
  chown -R "${owner}:${owner}" "$path" || { log_err "chown 失败"; return 1; }
  local after; after="$(stat -c '%U:%G' "$path")"
  log_ok "属主修正: ${path} ${before} → ${after}"
  log_info "复核（以 ${owner} 身份）: test -w ${path} && echo writable"
}
