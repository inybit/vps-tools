#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：恢复（侦察 → 恢复）与灾难恢复 runbook 生成
#
# 铁律：恢复默认只写到 --target 目录，**绝不裸覆盖 /**；
#       覆盖生产路径必须由人工核对后显式执行（工具不代劳）。
# ============================================================

# ---------- 只读侦察（无需 root） ----------
vp_snapshots() {  # $1...=额外过滤参数
  vp_require_password || return 1
  vp_require_tools || return 1
  local -a args=(snapshots --host "${VP_HOST}")
  [[ $# -gt 0 ]] && args+=("$@")
  vp_restic "${args[@]}"
}

vp_ls() {  # $1=快照ID|latest $2...=路径
  vp_require_password || return 1
  vp_require_tools || return 1
  vp_restic ls "${1:-latest}" "${@:2}"
}

vp_dump() {  # $1=快照ID|latest $2=文件路径（原样输出到 stdout）$3...=额外 restic 参数
  vp_require_password || return 1
  vp_require_tools || return 1
  local snap="${1:-latest}" file="${2:?需要文件路径}"
  [[ -n "$file" ]] || { log_err "需要文件路径"; return 1; }
  vp_restic dump "$snap" "$file" "${@:3}"
}

# ---------- 恢复 ----------
vp_restore_main() {  # $1=快照ID|latest 其余: --target / --tag / --include
  local snap="${1:-latest}"; shift || true
  local target="" tag="" includes=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target)  target="${2:-}"; shift 2 ;;
      --tag)     tag="${2:-}"; shift 2 ;;
      --include) includes+=("--include" "${2:-}"); shift 2 ;;
      *) log_err "未知参数: $1"; return 1 ;;
    esac
  done
  [[ -n "$target" ]] || { log_err "必须显式指定 --target <目录>（工具不做裸覆盖 /）"; return 1; }
  vp_require_password || return 1
  vp_require_tools || return 1

  # 安全护栏：target 不允许是 / 或过短路径
  if [[ "$target" == "/" || "$target" == "/etc" || "$target" == "/usr" || "$target" == "/var" ]]; then
    log_err "拒绝恢复到系统路径: ${target}（先恢复到 /tmp/restore 人工核对）"
    return 1
  fi
  if [[ "$target" != /* ]]; then
    log_err "--target 必须是绝对路径"
    return 1
  fi

  mkdir -p "$target" || return 1
  local -a args=(restore "$snap" --target "$target" --verbose)
  [[ -n "$tag" ]] && args+=(--tag "$tag")
  [[ ${#includes[@]} -gt 0 ]] && args+=("${includes[@]}")
  log_info "恢复快照 ${snap}${tag:+（tag=${tag}）} → ${target}"
  vp_restic "${args[@]}" || { log_err "恢复失败"; return 1; }

  # 实测复核：目标目录真的落了文件（不信命令自报）
  if [[ -z "$(find "$target" -mindepth 1 -maxdepth 2 -print -quit 2>/dev/null)" ]]; then
    log_err "恢复声称成功但 ${target} 为空 —— 请检查快照内容（vps-backup ls ${snap}）"
    return 1
  fi
  log_ok "恢复完成: ${target}"
  return 0
}

# ---------- 灾难恢复 runbook ----------
vp_runbook_main() {  # $1=--stdout 只打印不落盘
  local to_stdout=0
  [[ "${1:-}" == "--stdout" ]] && to_stdout=1
  local repo; repo="$(vp_repo_url)"
  local body
  body="$(cat <<EOF
# VPS 灾难恢复 Runbook（自动生成 $(date -F '%F %T' 2>/dev/null || date '+%F %T')）

主机: ${VP_HOST}
repo: ${repo}
工具: vps-backup（vps-tools 仓库 backup/vps-backup/）

## ⚠️ 灾难时你需要的 3 样东西（必须在机器之外留存：Bitwarden）

1. **repo 密码** —— 写入新机 /etc/restic-password（chmod 600）
   密码不在任何备份包里（故意排除，防自噬）。
2. **rclone 凭据** —— Google Drive OAuth（client_id/client_secret/token）或 Service Account JSON
   注意: rclone 内置 shared client_id 已停用，须自建；app 留在 Testing 会 7 天过期，须 PUBLISH。
   落盘: rclone config（或 export RCLONE_CONFIG=/path/rclone.conf）
3. **本 runbook** —— 新机上没有它时，从仓库 README 复现等价步骤。

## 恢复步骤（新机 / 干净容器）

\`\`\`bash
# 1. 基础加固（可选，推荐先做）
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- install vps-init
sudo vps-init

# 2. 装备份工具
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- install vps-backup

# 3. 落盘凭证（从 Bitwarden 取）
sudo install -m 600 /dev/stdin /etc/restic-password <<< '<REPO_PASSWORD>'
# rclone 凭据：
sudo rclone config          # 或 sudo cp <rclone.conf> /root/.config/rclone/rclone.conf

# 4. 只连接、不 init（repo 已存在！）
sudo vps-backup connect

# 5. 侦察
sudo vps-backup snapshots
sudo vps-backup ls latest /etc

# 6. 先恢复 core 层（分钟级，服务立刻能起）
sudo vps-backup restore latest --tag core --target /tmp/restore
#    人工核对后再覆盖生产路径（工具不代劳）：
#    sudo cp -a /tmp/restore/etc/. /etc/

# 7. 重装服务（配置已随 core 恢复）
sudo bash install.sh install xray-deploy && sudo xray-deploy info
sudo bash install.sh install nginx-install

# 8. data 层后台恢复
sudo vps-backup restore latest --tag data --target /var/lib/docker/volumes
\`\`\`

## 恢复时间预期

| 层 | 内容 | 预期 |
|---|---|---|
| core | /etc + dotfiles + vps-tools | 秒~分钟（MB 级） |
| data | docker volumes / 站点 | 按体量，可后台 |

## 常见故障

- \`Fatal: wrong password\` → repo 密码错（不是备份坏了）
- \`cannot find remote\` / \`token expired\` → rclone remote 未配 / 授权过期（reconnect）
- \`remote 名不匹配\` → ${VP_ENV_FILE} 的 VP_RCLONE_REMOTE 与 \`rclone listremotes\` 的名字不一致
  （只填裸名，不带冒号/路径；工具会打印实有名字）
- \`无法读取配置文件\` → rclone 配置语法错或路径不存在（工具会透出 rclone 原始报错）
- \`failed to open repository\` → 网络不可达或 repo 路径写错（VP_REPO_BASE/VP_HOST）
- 上传中断于 ~750GiB → GDrive 每日上传限额，次日增量续跑即可
EOF
)"
  if [[ $to_stdout -eq 1 ]]; then
    printf '%s\n' "$body"
    return 0
  fi
  mkdir -p "$(dirname "${VP_RUNBOOK_FILE}")"
  printf '%s\n' "$body" > "${VP_RUNBOOK_FILE}"
  chmod 600 "${VP_RUNBOOK_FILE}"
  log_ok "已生成 runbook: ${VP_RUNBOOK_FILE}"
  return 0
}
