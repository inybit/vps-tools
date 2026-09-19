# vps-backup

[← 返回仓库根](../../README.md)

restic + rclone(Google Drive) 备份与灾难恢复。每台 VPS 独立 repo
（`rclone:<remote>:<base>/<host>`），客户端加密 + 全局去重，**云端只见密文**；
恢复路径专为「快速灾难恢复」设计。

| | |
|---|---|
| 域 | `backup/` |
| 版本 | `1.3.0` |
| 结构 | 多文件（入口 + 15 lib） |
| 依赖 | restic, rclone（`vps-backup deps` 自带 sha256 校验安装）, curl |
| 配置 | `/etc/vps-backup.env`（600） |
| 密码 | `/etc/restic-password`（600，**丢失 = 备份永久不可读**） |
| 排除表 | `/etc/vps-backup.exclude` |
| runbook | `/root/VPS-RESTORE.md` |

## 安装

```bash
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- install vps-backup
```

安装器只放脚本 + 生成配置模板，**不会自动执行工具命令**。首次部署：

```bash
sudo vps-backup          # 向导: 依赖 → 密码 → repo 连接 → 范围 → 通知 → timer → runbook
```

## 用法

```bash
vps-backup                         向导（同上）
vps-backup deps                    安装/更新 restic + rclone（官方二进制 + sha256 校验，fail-closed）
vps-backup password                设定 repo 密码（仅首次；已存在则拒绝覆盖）
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
vps-backup check                   完整性校验（数据块抽查 5%）
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
```

## repo 密码（首次部署必读）

向导的 `[2/7]` 步骤引导生成或录入密码并落盘 `/etc/restic-password`（600）。
**该密码是唯一的钥匙（restic 无后门），丢失 = 备份永久不可读**，落盘后必须立刻存入 Bitwarden。

- 非交互场景：`VP_PASSWORD=<密码> vps-backup password`（不提供则拒绝，
  工具**绝不**凭空生成一把你不知道的密码）
- 已有密码时工具**永不覆盖**（恢复场景 + 幂等）
- 恢复场景（新机器）：从 Bitwarden 取回密码 → `vps-backup password` 录入

## rclone remote 名必须逐字符一致

`VP_RCLONE_REMOTE` 只填**裸名**（如 `gdrive`），不带冒号/路径，
且必须等于 `rclone listremotes` 里的名字。名字不一致是最常见的故障，
症状是「明明配好了却报 remote 未配置」——v1.3.0 起工具会打印 rclone 实有 remote 名
与两条修正路径（改 env / 改 rclone），不再只给一句误导文案。

```bash
# 查实际 remote 名（只读，不泄露 token）
rclone listremotes --long
# 修正方式 A：改 env（推荐，单向、不动 rclone、不需重授权）
sudo sed -i 's|^VP_RCLONE_REMOTE=.*|VP_RCLONE_REMOTE="<实际名>"|' /etc/vps-backup.env
# 修正方式 B：改 rclone 节头名（token 在节内，改名不丢授权）
rclone config     # → e 重命名
```

## 备份路径完全可自定义

分层只是默认建议，不是硬编码：

```bash
sudo vps-backup paths show                       # 查看两层路径 + 体检（存在性/排除冲突）
sudo vps-backup paths edit                       # 交互逐层设置
sudo vps-backup paths set data /srv /opt/app     # 直接设置某层（空格分隔绝对路径）
sudo vps-backup exclude add /srv/scratch         # 排除表管理
sudo vps-backup exclude remove /mnt              # 移除排除项（凭证类模式受保护）
```

也可直接编辑 `/etc/vps-backup.env` 的 `VP_BACKUP_CORE_PATHS` / `VP_BACKUP_DATA_PATHS`，改完立即生效。

> ⚠️ **自定义路径的两个静默失败陷阱（已内置防护）**：
> - 路径落在**排除表覆盖的位置**（`/tmp`、`/mnt`、`~/.cache`…）→ restic 会「成功退出但备份 0 文件」。
>   工具现在会：设置时**拒绝**（含祖先目录命中）、备份时**跳过并告警**、备份后**复核快照文件数**（0 则报错）。
> - 路径是**空目录** → 同上按 0 文件失败处理（不再是假成功）。

## 分层设计

| 层 | 内容 | 频率 | 恢复 |
|---|---|---|---|
| `core` | `/etc`、`/root`、dotfiles、`/usr/local/lib/vps-tools`、wrapper | 每 6h（00/06/12/18 点 20 分） | 秒~分钟（MB 级） |
| `data` | `/var/lib/docker/volumes`、`/srv`、`/opt` | 每日 03:30 | 按体量，可后台 |

先恢复 core → 服务立刻能起 → data 后台慢慢恢复。
**「快速灾难恢复」的判据是「干净机器上按 runbook 跑通并计时」**，不是工具特性。

## 四条硬设计

1. **凭证不入包（防自噬）** —— `/etc/restic-password`、`/etc/vps-backup.env`、`rclone.conf`
   一律写进排除表。机器全毁时靠 Bitwarden 里的密码才读得回备份；备份包里**不含打开自己的钥匙**。
   `vps-backup status` 会做凭证排除自检。
2. **connect 与 init 严格分离** —— `connect` 只校验连通与密码，恢复场景**绝不执行 init**；
   `init` 对已存在 repo 直接拒绝。
3. **恢复必须显式 `--target`** —— 工具不做裸覆盖 `/`；恢复到 `/tmp/restore` 人工核对后再覆盖。
4. **失败告警单一出口** —— systemd 单元 `OnFailure=vps-backup-failnotify@.service`，
   脚本自身跑不起来（restic 缺失 / env 缺失 / token 过期）也能告警；成功才发完成通知，不刷双卡。

## repo 锁

定时任务撞车/异常退出会留下锁，`--retry-lock`（默认 10m）自动等待；
真被锁住时报错会明确指向 `vps-backup unlock`（**不误导去跑 `repair`**）。

⚠️ restic 的 `unlock` **只清陈旧锁**（持锁进程已消失）；若进程仍在，工具会如实报「锁仍在」
并提示 `unlock --all`（`--remove-all`）——不会假报成功。

## Google Drive 配置要点（不做会静默失效）

| 事实 | 对策 |
|---|---|
| rclone 内置 shared client_id **已停用** | 必须自建 OAuth client_id（Desktop app） |
| OAuth app 留 **Testing** 状态 → 授权 **7 天过期** | 必须 **PUBLISH APP** 切 production（个人 <100 用户免审核） |
| 上传限额 **750 GiB/日**（未公开） | 工具默认设 `RCLONE_DRIVE_STOP_ON_UPLOAD_LIMIT=true`，命中即致命退出而非静默截断，次日增量续跑 |
| 删除默认进回收站（仍占配额） | 排除表 + `--drive-use-trash=false` 语义（restic 需要真删） |
| 文件 revision 保留 30 天/100 版且不计配额 | 意外覆盖有后悔期，无需额外处理 |

> **「7 天过期」的正确理解**：不是每 7 天要更新 token，而是每 7 天要重走一次浏览器授权。
> `access_token` 1 小时过期（rclone 自动刷新）；`refresh_token` 正常永不过期——
> 根因是 consent screen 的 publishing status = **Testing**（新建 project 的默认状态）。
> 没有配置项能让它不过期，只能 **PUBLISH APP**。
>
> **PUBLISH APP 按钮可能是灰的**：Google 现在即使个人单用户应用也要求 homepage + privacy policy URL，
> 先去左侧 **Branding** 填（免费 GitHub Pages 即可）+ Authorized domains。

restic 走 `rclone:` 后端**不需要云端支持 hash**（只用文件读写）；restic 自己 spawn
`rclone serve restic --stdio`，**rclone 拒绝隐式运行当前目录下的相对路径 rclone**
→ 工具固定用 `-o rclone.program=/usr/local/bin/rclone`（绝对路径）。

## ⚠️ 主机名会改变数据归属（部署前必看）

`VP_HOST` 默认空 → 回退 `hostname -s`。它**一个变量管三件事**：
① repo 云端子目录名 ② 快照 `--host` 标签 ③ `forget --host` 保留策略分组键。

**改主机名 = 工具静默指向另一个 repo**，旧 repo 连同历史快照被彻底孤立
（密码还在、数据还在，但工具再也不看它），而已装的 timer 会持续失败。

- **部署前先问「主机名会变吗」**；要变就在 env 里显式钉死：`VP_HOST="<固定名>"`（零迁移）
- ⚠️ 更隐蔽的一层：`--host` 标签**不跟目录名走** —— 历史快照里仍是旧名，
  而 `forget --host <新名>` 只看新标签 → 旧快照**永不被保留策略清理（无限堆积）**
- 迁移 8 步（含每步复核）：
  ```bash
  systemctl stop vps-backup-*.timer                    # 复核 is-active
  hostnamectl set-hostname <新名>                      # ⚠️ 唯一正确入口
  printf '127.0.1.1\t<新名>\n' >> /etc/hosts           # 防 sudo/解析变慢
  rclone moveto <remote>:<base>/<旧名> <remote>:<base>/<新名>
  restic snapshots                                     # 不带 --host，确认历史还在
  IDS=$(… snapshots --json 取 id …); restic forget $IDS   # --keep-last 0 不可用
  restic prune                                         # 复核云端体积下降
  vps-backup backup core                               # 复核新快照 host 标签 == 新名 ← 这步才算成功
  systemctl start vps-backup-*.timer + 副作用核查
  ```

## 调度

systemd timer：`vps-backup-backup@core.timer` / `@data.timer` / `vps-backup-maintain.timer`，
不使用 cron。维护单元每周执行 `forget + prune + check --read-data-subset=5%`
（**用 subset 不用 `--read-data`**，后者下载整个 repo）。

## 配置（`/etc/vps-backup.env`，600）

| 键 | 说明 |
|---|---|
| `VP_RCLONE_REMOTE` | rclone remote **裸名**（不带冒号/路径） |
| `VP_REPO_BASE` | remote 内 repo 根目录 |
| `VP_HOST` | repo 子目录名 / 快照 host 标签；留空 = `hostname -s`（见上方警告） |
| `VP_BACKUP_CORE_PATHS` | core 层路径（空格分隔绝对路径） |
| `VP_BACKUP_DATA_PATHS` | data 层路径 |
| `VP_RETENTION_ARGS` | 保留策略，默认 `--keep-daily 7 --keep-weekly 5 --keep-monthly 6 --keep-yearly 2` |
| `VP_CHECK_SUBSET` | 每周抽查比例，默认 `5%` |
| `VP_CORE_INTERVAL_HOURS` / `VP_CORE_ONCALENDAR` | core 频率/时刻 |
| `VP_DATA_ONCALENDAR` / `VP_MAINTAIN_ONCALENDAR` | data / maintain 时刻 |
| `VP_TG_BOT_TOKEN` / `VP_TG_CHAT_ID` / `VP_NOTIFY` | Telegram 失败告警 |
| `VP_PRE_HOOK` | 备份前钩子（如数据库 dump；失败不阻塞但会告警） |
| `VP_RCLONE_CONFIG` | 非默认位置的 rclone 配置文件 |
| `VP_PASSWORD_FILE` / `VP_EXCLUDE_FILE` / `VP_RUNBOOK_FILE` | 路径覆盖（一般不改） |

## 已知坑（实现与运维）

- **`restic forget --keep-last 0` 不能清空快照**（`Fatal: no policy was specified`）。
  清空必须 `snapshots --json` 取 ID 再 `forget <ID...>`，之后 `prune` 回收空间。
- **`restic unlock` 只清陈旧锁**，被存活进程持有的锁它不动却「成功返回」→ 工具必须
  `list locks` 实测复核（这是事务一致性铁律的直接应用）。
- **裸 `export RCLONE_CONFIG` 只标记已存在的变量、不会赋值** → 必须写
  `export RCLONE_CONFIG="$VP_RCLONE_CONFIG"`。否则 restic 拉起的 rclone 子进程读不到自定义配置，
  静默退回 `~/.config/rclone/rclone.conf`，repo 甚至落到进程 cwd，而工具仍报「备份完成」。
- **体检的解析规则必须与调用规则一致**：`vp_resolve_bin` 取到 PATH 上的命令后要**改写变量**，
  否则「体检通过、一调用就炸」；且「存在 ≠ 可执行」，须「存在 + `version` 能跑」二段式判定。
- **`2>/dev/null` 会吞掉 rclone 的 CRITICAL**：remote 名写错 / 配置语法损坏 /
  `VP_RCLONE_CONFIG` 指向不存在的文件，三种完全不同的故障会输出同一句误导文案。
  v1.3.0 起分四态诊断（`nocfg` / `notfound` / `down` / `ok`）。
- **备份后必须复核本次快照的真实文件数**：`stats <快照ID>` 的 `total_file_count` 把目录条目也算进去
  （空目录快照报 4）；`stats --tag X --host Y` 是累计所有快照（恒 >0）。
  正解：`snapshots --json` 取末条 `short_id` → `ls --json <id> | grep -c '"type":"file"'`。
- **`--password-command` 可替代密码落盘**（上游支持，全链路已实测），但**先算收益**：
  备份以 root 跑，拿到 root 的人本来就能读密码文件和备份数据本身；真正致命的是**凭证自噬**。
  VPS 上 `/dev/tpm*` 通常不存在 → `systemd-creds` 的密钥就是同盘文件，**不是加密替代品**。
