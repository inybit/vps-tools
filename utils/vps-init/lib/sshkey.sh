#!/usr/bin/env bash
# ============================================================
# vps-init 模块：SSH 公钥（读取 / 校验 / 注入）
# 被 common.sh 之外独立 source；user.sh 与 ssh.sh 共用，避免两处实现漂移
# ============================================================

# ============================================================
# SSH 公钥：读取 / 校验 / 注入（user.sh 与 ssh.sh 共用，避免两处实现漂移）
# ============================================================

# 公钥格式校验（以 ssh- 开头 + 密钥体；允许尾部注释）
valid_pubkey() {  # $1=公钥内容
  [[ "${1:-}" =~ ^ssh-(ed25519|rsa|ecdsa|dss)[[:space:]]+[A-Za-z0-9+/=]+ ]]
}

# 读取公钥内容 → stdout（空 = 未提供）
# 优先级：VPS_INIT_SSH_PUBKEY（内容或文件路径）> $1 文件路径 > 交互粘贴
# 返回 0=拿到内容；1=未提供（非错误，调用方决定是否降级）
read_pubkey() {  # $1=命令行传入的公钥文件路径（可空）
  local src="${1:-}" raw=""
  if [[ -n "${VPS_INIT_SSH_PUBKEY:-}" ]]; then
    if [[ -f "${VPS_INIT_SSH_PUBKEY}" ]]; then
      raw="$(tr -d '\r\n' < "${VPS_INIT_SSH_PUBKEY}" 2>/dev/null)"
    else
      raw="${VPS_INIT_SSH_PUBKEY}"
    fi
    printf '%s' "$raw"
    [[ -n "$raw" ]]
    return
  fi
  if [[ -n "$src" && -f "$src" ]]; then
    raw="$(tr -d '\r\n' < "$src" 2>/dev/null)"
    printf '%s' "$raw"
    [[ -n "$raw" ]]
    return
  fi
  read_input "粘贴 SSH 公钥（ssh-ed25519 AAAA...；回车跳过）: " raw || raw=""
  printf '%s' "$raw"
  [[ -n "$raw" ]]
}

# 把公钥写入某用户的 authorized_keys（幂等 + 实测复核）
# 复核铁律：写完必须回读确认密钥真的在文件里，且属主/权限正确
inject_pubkey() {  # $1=用户名 $2=公钥内容
  local user="$1" pubkey="$2"
  local homedir sshdir authorized group
  homedir="$(getent passwd "$user" | cut -d: -f6)"
  if [[ -z "$homedir" || ! -d "$homedir" ]]; then
    log_err "${user}: 取不到家目录（用户不存在？）—— 公钥未注入"
    return 1
  fi
  group="$(id -gn "$user" 2>/dev/null)"
  sshdir="${homedir}/.ssh"
  authorized="${sshdir}/authorized_keys"

  mkdir -p "$sshdir" || { log_err "${user}: 无法创建 ${sshdir}"; return 1; }
  chmod 700 "$sshdir"
  touch "$authorized" || { log_err "${user}: 无法创建 ${authorized}"; return 1; }
  chmod 600 "$authorized"

  if grep -qF "$pubkey" "$authorized" 2>/dev/null; then
    log_info "${user}: 公钥已存在，跳过"
  else
    printf '%s\n' "$pubkey" >> "$authorized" || { log_err "${user}: 写入失败"; return 1; }
  fi
  # 只 chown 本工具触碰的两个路径（不用 -R：避免误改用户已有内容的属主）
  chown "$user":"$group" "$sshdir" "$authorized" 2>/dev/null || true

  # ---------- 实测复核（不信自报） ----------
  if ! grep -qF "$pubkey" "$authorized" 2>/dev/null; then
    log_err "${user}: 复核失败——公钥不在 ${authorized}"
    return 1
  fi
  local mode
  mode="$(stat -c '%a' "$authorized" 2>/dev/null)"
  if [[ "$mode" != "600" ]]; then
    log_err "${user}: 复核失败——authorized_keys 权限为 ${mode:-?}（应为 600，sshd 会拒绝）"
    return 1
  fi
  local owner
  owner="$(stat -c '%U' "$authorized" 2>/dev/null)"
  if [[ "$owner" != "$user" ]]; then
    log_err "${user}: 复核失败——authorized_keys 属主为 ${owner:-?}（应为 ${user}）"
    return 1
  fi
  log_info "${user}: 公钥已就绪 → ${authorized}（权限 600，属主 ${owner}）"
  return 0
}
