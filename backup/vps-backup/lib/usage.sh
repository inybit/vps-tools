#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：帮助文本（usage）
# ============================================================

usage() {
  cat <<EOF
vps-backup ${VP_VERSION} — restic + rclone(Google Drive) VPS 备份与灾难恢复

用法:
  vps-backup                         向导: 依赖 → repo 连接 → 备份范围 → 通知 → timer → runbook
  vps-backup deps                    安装/更新 restic + rclone（官方二进制 + sha256 校验）
  vps-backup connect                 只连接 repo 校验（**不 init**，恢复场景用）
  vps-backup init                    初始化 repo（仅首次；已存在则拒绝，不覆盖）
  vps-backup backup [core|data|all]  执行备份（默认 all）
  vps-backup snapshots [过滤参数]    列出快照（只读，无需 root）
  vps-backup ls <快照|latest> [路径] 列出快照内文件（恢复前侦察）
  vps-backup dump <快照|latest> <文件>  输出单个文件内容到 stdout
  vps-backup restore <快照|latest> --target <目录> [--tag core|data] [--include <路径>]
                                     恢复（**必须显式 --target**，工具不做裸覆盖 /）
  vps-backup forget                  仅应用保留策略
  vps-backup prune                   回收未引用数据
  vps-backup maintain                forget + prune + 完整性校验（每周 timer 调用）
  vps-backup check                   完整性校验（数据块抽查 ${VP_CHECK_SUBSET:-5%}）
  vps-backup unlock [--dry-run|--all]  查看/清理 repo 锁（--all 强制清除他人锁）
  vps-backup paths                   查看备份路径（core/data）+ 存在性/排除冲突体检
  vps-backup paths edit              交互设置各层备份路径
  vps-backup paths set core <路径...>  直接设置某层路径（绝对路径，空格分隔）
  vps-backup exclude list            查看排除表
  vps-backup exclude add <模式>      追加排除项
  vps-backup exclude remove <模式>   移除排除项（凭证类模式受保护，不可移除）
  vps-backup status                  汇总: repo/密码文件/依赖/remote/最近快照/timer/凭证自检
  vps-backup runbook [--stdout]      生成灾难恢复 runbook（默认写 /root/VPS-RESTORE.md）
  vps-backup install-timer           安装/更新 systemd timer
  vps-backup timer-status            查看 timer 状态
  vps-backup uninstall-timer         移除 timer（配置与 repo 保留）
  vps-backup -v, --version           显示版本号
  vps-backup -h, --help              显示本帮助

设计要点:
  * 分层备份: core（/etc、dotfiles、vps-tools，每 6h，恢复秒~分钟）
              data（docker volumes、站点，每日，可后台恢复）
    **路径完全可自定义**（env 键或 vps-backup paths set）；自定义后会体检
    「是否存在 / 是否被排除表挡掉」——被挡掉的路径会让备份「成功但 0 文件」。
  * 凭证不入包: repo 密码 / rclone 配置 / 本工具 env 一律排除
    （机器全毁时靠 Bitwarden 里的密码才读得回备份 —— 见 runbook）
  * connect 与 init 严格分离: 恢复场景绝不执行 init
  * 失败告警走 Telegram（timer 单元 OnFailure 兜底）

配置（/etc/vps-backup.env，600）:
  VP_RCLONE_REMOTE=gdrive            rclone remote 名
  VP_REPO_BASE=vps-backup            remote 内 repo 根目录
  VP_HOST=<hostname>                 repo 子目录名 / 快照 host 标签
  VP_BACKUP_CORE_PATHS="/etc /root ..."   core 层路径（空格分隔，绝对路径）
  VP_BACKUP_DATA_PATHS="/var/lib/docker/volumes /srv"  data 层路径
                                          （或用 vps-backup paths set 修改）
  VP_RETENTION_ARGS="--keep-daily 7 --keep-weekly 5 --keep-monthly 6 --keep-yearly 2"
  VP_CHECK_SUBSET=5%                 每周抽查比例
  VP_CORE_INTERVAL_HOURS=6           core 备份间隔
  VP_DATA_ONCALENDAR=*-*-* 03:30:00  data 备份时刻
  VP_TG_BOT_TOKEN / VP_TG_CHAT_ID    Telegram 失败告警
  VP_NOTIFY=1                        1=开启通知
  VP_PRE_HOOK=""                     备份前钩子（如数据库 dump）
  VP_RCLONE_CONFIG=""                非默认 rclone 配置路径

示例:
  sudo vps-backup deps                       # 先装依赖
  sudo vps-backup init                       # 首次初始化 repo
  sudo vps-backup backup core                # 立刻备一次 core
  sudo vps-backup snapshots                  # 看快照
  sudo vps-backup restore latest --tag core --target /tmp/restore
  sudo vps-backup runbook                    # 生成灾难恢复文档
EOF
}
