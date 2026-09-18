#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：排除表（凭证排除 + 自定义路径 + 冲突检测）
#
# 凭证类模式**不得移除**（防自噬：机器全毁时靠 Bitwarden 里的密码才读得回备份）。
# 其余为默认排除项，用户可按需增删（vps-backup exclude add/remove）。
# ============================================================

# /etc/restic-password、/etc/vps-backup.env、rclone.conf 必须异地留存（Bitwarden）。
vp_credential_patterns() {
  cat <<'EOF'
/etc/restic-password
/etc/vps-backup.env
/etc/vps-backup.exclude
/root/.config/rclone/rclone.conf
EOF
}

# 确保排除表存在（首次自动生成；已存在不覆盖 —— 用户可能自定义过）
vp_ensure_exclude_file() {
  [[ -f "${VP_EXCLUDE_FILE}" ]] && return 0
  mkdir -p "$(dirname "${VP_EXCLUDE_FILE}")"
  {
    echo "# vps-backup 排除表（restic --exclude-file）"
    echo "# 凭证类：绝不入备份包（自噬陷阱 —— 机器全毁时凭这些文件才读得回备份）"
    vp_credential_patterns
    echo "# 运行时/临时"
    echo "/proc"
    echo "/sys"
    echo "/dev"
    echo "/run"
    echo "/tmp"
    echo "/var/tmp"
    echo "/var/cache"
    echo "/var/log"
    echo "/var/lib/vps-backup"
    echo "/var/lib/restic"
    echo "/lost+found"
    echo "# 包管理与缓存（可重装，不必备）"
    echo "/var/lib/apt/lists"
    echo "/var/lib/dpkg/info"
    echo "/usr/share/doc"
    echo "/root/.cache"
    echo "/home/*/.cache"
    echo "# 挂载点（外部存储/网络盘）"
    echo "/mnt"
    echo "/media"
  } > "${VP_EXCLUDE_FILE}"
  chmod 600 "${VP_EXCLUDE_FILE}"
  log_ok "已生成排除表: ${VP_EXCLUDE_FILE}"
}

# 自检：凭证必须真的被排除（防「以为排除了其实没有」）
vp_verify_exclusions() {
  vp_ensure_exclude_file
  local p missing=0
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    grep -qxF "$p" "${VP_EXCLUDE_FILE}" || { log_err "排除表缺少凭证路径: $p"; missing=1; }
  done < <(vp_credential_patterns)
  [[ $missing -eq 0 ]] || return 1
  return 0
}

# ---------- 排除表冲突检测（防止「自定义路径被静默挡掉」） ----------
# ⚠️ restic 排除表语义：模式命中该路径**或其下所有内容**；glob（如 /home/*/.cache）亦生效。
#    用户把备份路径自定义到被排除的位置（/mnt、/tmp、~/.cache…）时，restic 会
#    「处理 0 文件但成功退出」→ 工具若只看退出码就会假报成功（实测踩过）。
# VP_EXCLUDE_HIT: 命中模式（由调用方 backup.sh/paths.sh 读取展示）；export 表明跨文件使用
export VP_EXCLUDE_HIT=""
vp_path_in_excludes() {  # $1=绝对路径 → 命中返回 0，命中模式写入 VP_EXCLUDE_HIT
  local path="$1" pat cur
  VP_EXCLUDE_HIT=""
  [[ -f "${VP_EXCLUDE_FILE}" ]] || return 1
  while IFS= read -r pat; do
    [[ -z "$pat" || "$pat" == \#* ]] && continue
    # 路径自身命中模式，或其任一祖先目录命中（祖先被排除 → 其下全部排除）
    cur="$path"
    while : ; do
      # shellcheck disable=SC2053  # 有意 glob 匹配：排除表支持通配
      if [[ "$cur" == $pat ]]; then
        VP_EXCLUDE_HIT="$pat"
        if [[ "$cur" != "$path" ]]; then
          VP_EXCLUDE_HIT="${pat}（祖先目录，其下全部排除）"
        fi
        return 0
      fi
      [[ "$cur" == "/" || "$cur" == "." ]] && break
      cur="$(dirname "$cur")"
    done
  done < "${VP_EXCLUDE_FILE}"
  return 1
}

# 备份某层
