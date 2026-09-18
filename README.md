# vps-tools

个人 VPS 运维脚本集。全部脚本通过 `install.sh` 一键安装/更新/卸载，脚本内敏感信息一律使用 `${PLACEHOLDER}` 占位符，真实密钥只存在于各机器 `/etc/*.env` 配置文件中，不入库。

## 目录

- [快速开始](#快速开始)
- [工具清单](#工具清单)
- [工具使用教程](#工具使用教程)
- [仓库结构](#仓库结构)
- [测试](#测试)
- [开发约定](#开发约定)
- [更新 vps-tools 自身](#更新-vps-tools-自身)

---

## 快速开始

### 方式一：一键安装 + 交互式管理（推荐）

SSH 登录 VPS 后直接运行，自动安装管理命令 `vps-tools` 并进入交互菜单：

```bash
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- 
```

```
===== vps-tools 管理 =====
  1) 安装工具（选择）
  2) 更新工具（选择）
  3) 卸载工具（选择）
  4) 查看工具
  5) 更新 vps-tools 自身
  0) 退出
请选择 [0-5]:
```

> 管道方式（`curl | sudo bash`）下 stdin 被 curl 占用，脚本会自动改从 `/dev/tty` 读取输入，**交互菜单依然可用**。

安装完成后，之后的管理直接运行：

```bash
sudo vps-tools          # 进入交互式管理菜单
sudo vnstat-monitor     # 直接调用工具（等价于 xray-deploy 等工具名）
sudo xray-deploy        # Xray 部署/管理入口
```

### 方式二：命令行指定工具（脚本/CI 场景）

```bash
# 安装/更新指定工具（重复执行即覆盖更新，配置保留）
curl -sSL .../install.sh | sudo bash -s -- install vnstat-monitor
curl -sSL .../install.sh | sudo bash -s -- install xray-deploy

# 卸载（脚本删除，配置保留防误删密钥）
curl -sSL .../install.sh | sudo bash -s -- uninstall vnstat-monitor

# 查看可用工具（list 不需要 root）
bash <(curl -sSL .../install.sh) list

# 本地已下载时
sudo bash install.sh install vnstat-monitor
```

> 上例 `.../install.sh` 完整地址：`https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh`

> **关于 root**：`install/update/uninstall` 必须 root。管道方式 `curl | sudo bash -s --` 自动以 root 运行（普通用户登录的 VPS 也能用）；非 root 直接运行会提示并给出完整 sudo 命令。
> **关于交互**：无参数运行进入交互管理菜单；纯 CI/无终端环境请用方式二指定工具，避免卡在输入等待。

### 安装器行为

- 脚本下载到 `/usr/local/lib/vps-tools/<tool>/`，与系统文件隔离，卸载即删目录
- 每个工具自动生成命令入口 `/usr/local/bin/<tool>`，**直接以工具名调用**
- 首次安装自动生成配置模板 `/etc/<tool>.env`（`chmod 600`，已存在不覆盖），**需手动填入真实密钥**
- 定时调度统一用 **systemd timer**（工具 `setup` 子命令管理，如 `vnstat-monitor setup`），不使用 crontab
- 重复 `install` = 覆盖更新，幂等

---

## 工具清单

7 个工具，按功能域分类。**多文件工具**（wrapper + `lib/`）在"结构"列标注。

| 工具 | 域 | 用途 | 依赖 | 结构 |
|---|---|---|---|---|
| [vnstat-monitor](monitor/vnstat-monitor/) | monitor | vnStat + Telegram 流量监控：进度条/偏移校准/熔断关机/无限流量模式；原地更新消息防刷屏 | vnstat, jq, curl, gawk, iproute2 | 单文件 |
| [xray-deploy](proxy/xray-deploy/) | proxy | Xray 一键部署：4 协议注册表；回落域名双检（VPS 握手 + Globalping 中国方向）；geosite/geoip 周更；生成 mihomo/sing-box 客户端节点 | curl, unzip, jq, openssl | 多文件（25 lib） |
| [vps-init](utils/vps-init/) | utils | 一键初始化 VPS：DD 重装（全自动续跑）/ 时区 / BBR / 用户+sudo+**SSH 公钥注入** / 禁密码+随机高位端口 / Fail2Ban / UFW | curl, openssh-server | 多文件（8 lib + 2 tpl） |
| [docker-install](utils/docker-install/) | utils | Docker 官方源安装 + **Docker×UFW 共存加固**（委托 [chaifeng/ufw-docker](https://github.com/chaifeng/ufw-docker)，固定版本 + sha256 校验）+ 非暴露模式 + 非 root 管理 + 权限体检 | curl, iptables, ufw | 多文件（8 lib） |
| [nginx-install](web/nginx-install/) | web | nginx 官方源安装（stable/mainline）+ **签名密钥 fail-closed 校验**（apt 指纹 / apk 摘要）+ apt Pin-Priority 900 + 体检 | curl, gnupg/openssl, apt/dnf/apk | 多文件（6 lib） |
| [vps-bench](bench/vps-bench/) | bench | 节点测速：NodeQuality / TcpQuality 二选一（第三方脚本封装，执行前明示来源） | curl | 单文件 |
| [vps-backup](backup/vps-backup/) | backup | **restic + rclone(GDrive) 备份与灾难恢复**：core/data 分层；保留策略 forget+prune；每周完整性抽查；**凭证不入包**；connect/init 严格分离；**repo 密码引导**；remote 名分态诊断；Telegram 失败告警；自动生成恢复 runbook | restic, rclone（自带 sha256 校验安装）, curl | 多文件（15 lib） |

---

## 工具使用教程

### vnstat-monitor — vnStat 流量监控（Telegram 推送）

```bash
sudo vnstat-monitor            # 手动跑一次（首次会初始化 vnstat 数据库）
```

1. 安装后编辑配置，填入 Telegram Bot Token 与 Chat ID：
   ```bash
   sudo nano /etc/vnstat-monitor.env
   ```
   `VPS_NAME`（显示名）、`TG_BOT_TOKEN`、`TG_CHAT_ID` 为必填；`LIMIT_GB`（流量上限，超过触发提醒）、`AUTO_SHUTDOWN`（超过上限是否关机）、`INTERVAL_MINUTES`（触发频率，分钟，默认 15）按需配置。
2. 手动验证：`sudo vnstat-monitor`，应收到一条 Telegram 流量卡片。
3. **设置定时（systemd timer，替代 crontab）**——安装时若交互安装会自动调用，也可手动：
   ```bash
   sudo vnstat-monitor setup              # 交互式：设置频率 + 安装 timer
   sudo vnstat-monitor install-timer 30   # 每 30 分钟
   ```
4. 修改触发频率（配置持久化 + timer 自动重载）：
   ```bash
   sudo vnstat-monitor set-interval 30    # 改为每 30 分钟
   sudo vnstat-monitor timer-status       # 查看 timer 状态
   sudo vnstat-monitor uninstall-timer    # 移除定时（保留配置与脚本）
   ```
   > 旧版本用 crontab（`*/15 * * * * /usr/local/bin/vnstat-monitor`）的机器，`uninstall-timer` 之外还需手动删除 crontab 中对应行。

### xray-deploy — Xray 代理服务部署

```bash
sudo xray-deploy               # 交互菜单（推荐，所有操作都从这进）
```

常用子命令（等价的非交互形式）：

```bash
sudo xray-deploy install       # 首次部署向导：选回落域名 → 生成密钥 → 装 systemd/OpenRC 服务
xray-deploy info               # 查看节点信息（明文 + mihomo/sing-box 片段，无需 root）
xray-deploy config show        # 查看服务端 config.json
sudo xray-deploy config edit   # 编辑 config.json（保存后自动 xray -test 校验并重载）
xray-deploy fallback-test      # 测试全部回落候选的握手延迟并排序（部署前选型/诊断用）
xray-deploy fallback-test www.example.com   # 测试指定域名是否可作回落
xray-deploy fallback-cn-test   # 回落域名**中国方向**可达性检测（Globalping 中国三网探针，需外网）
sudo xray-deploy update-geo    # 手动更新 geosite/geoip（如需自动更新，可自行配 systemd timer）
sudo xray-deploy upgrade       # 升级 Xray 二进制（失败自动回滚）
sudo xray-deploy protocol add/remove/edit/list   # 多协议管理（端口/SNI/UUID）
sudo xray-deploy status / restart / uninstall
```

协议支持（`protocol add` 可选类型）：

| 类型 | 说明 | 证书 | 备注 |
|---|---|---|---|
| `vless-reality`（默认） | VLESS-TCP-XTLS-Vision-REALITY | 无需 | 成熟稳定，TCP 性能好 |
| `vless-xhttp-reality` | VLESS-XHTTP-REALITY（含 XMUX） | 无需 | 抗封锁更强；**仅支持 mihomo 系客户端**（sing-box 上游无 XHTTP） |
| `vless-xhttp` | VLESS-XHTTP-H2-TLS | 需域名解析到本机 | 走真实证书，兼容性最广 |
| `hysteria2` | Hysteria2 (hy2, QUIC/UDP) | 需域名 | 弱网/高丢包环境优势 |

部署流程：
1. `sudo xray-deploy` → 选 1 安装：按提示选端口（默认 443）、回落域名（自动测试+排序，可输自有域名）。
2. `xray-deploy info` 查看生成结果，把 mihomo / sing-box 片段填入客户端。
3. 节点信息持久化在 `/etc/xray-deploy/state.json`（600 权限，含私钥，**勿外泄**）。

> 回落域名测试在 VPS 上实时进行（TLS1.3 + H2 + X25519 + 非跳转 + 非 Cloudflare）；若全部失败会干净退出，不会产生半成品。

> **回落域名两个方向都要测**：`fallback-test` 从 VPS 侧测握手延迟；`fallback-cn-test` 从中国三网探针侧测可达性。
> 二者互补——VPS 侧握手快但中国方向被 SNI 阻断的域名，国内用户照样连不上。

> **数据出境确认（`fallback-cn-test` 专属）**：Globalping 是第三方公共 API，待测域名会被提交出境并留存在其
> **公开测量记录**中（提交内容仅域名 + 请求类型，不含服务器 IP / 密钥 / 节点信息）。因此该命令**提交前强制确认，
> 默认拒绝**——无交互终端（无 TTY）时同样拒绝，不会静默发出任何数据。自动化场景用 `CN_TEST_ASSUME_YES=1` 显式放行：

```bash
sudo xray-deploy fallback-cn-test                      # 交互：先打印出境提示，输 y 才提交
CN_TEST_ASSUME_YES=1 sudo xray-deploy fallback-cn-test www.example.com   # 自动化显式放行
```

> **客户端兼容性硬约束（Xray ≥ 26.9.8）**：mihomo 默认从 ClientHello 剥离 X25519MLKEM768 扩展，而 Xray 26.9.8+
> 对不带该扩展的 REALITY 握手直接拒绝（症状：`REALITY authentication failed`、服务端 `accepted=0`）。
> 本工具生成的 mihomo 片段已自动包含 `support-x25519mlkem768: true`，**勿手工删除**。

### vps-init — 一键初始化 VPS

```bash
sudo vps-init               # 交互向导：system → user → ssh → ufw → fail2ban（每步确认，已完成自动跳过）
sudo vps-init dd            # 一键 DD 重装（全自动续跑，cloud-init 首启自动初始化）
vps-init status             # 查看已执行步骤 / SSH 端口 / 时区 / BBR / UFW
```

常用单步子命令（幂等，可单独执行）：

```bash
sudo vps-init system        # 时区 Asia/Shanghai + BBR
sudo vps-init user          # 创建普通用户 + sudo + 注入 SSH 公钥（VPS_INIT_SKIP_USER=1 跳过 = root-only）
sudo vps-init ssh           # SSH 密钥注入 + 随机高位端口 + 禁用密码登录
sudo vps-init ufw           # UFW：deny incoming，放行 SSH 端口 + 额外端口
sudo vps-init fail2ban      # Fail2Ban：backend/banaction 自动探测，端口注入
```

一键 DD（全自动续跑）：

```bash
sudo vps-init dd                        # 交互输入发行版/版本/端口/用户/密码/公钥
sudo vps-init dd --distro debian --version 13 --port 52322 --user admin --pubkey /path/id_ed25519.pub
```

- DD 原理：调用 [bin456789/reinstall](https://github.com/bin456789/reinstall)，`--ci + --cloud-data` 把自包含初始化脚本（时区/BBR/用户/SSH/UFW/Fail2Ban）打包进 cloud-init，**新系统首启自动完成全部初始化**；公钥经 `--ssh-key` 注入
- 密码以 sha-512 哈希注入（不落明文）；双重确认（输入 `YES`）才执行
- 限制：alpine/arch/gentoo 等不支持 cloud-init 的发行版自动降级为"注入密钥+端口，重启后手动 vps-init"
- 配置：`/etc/vps-init.env`（可缺省）——`VPS_INIT_USER/SSH_PUBKEY/SSH_PORT`、`SSH_PORT_MIN/MAX`、`VPS_INIT_EXTRA_PORTS`、`VPS_INIT_SKIP_USER`、`VPS_INIT_DISABLE_ROOT`、`VPS_INIT_YES`
- 防失联：禁密码登录前置校验 authorized_keys 非空；所有 sshd 变更先 `sshd -t`；改端口后保持当前会话、开新窗口验证

### docker-install — Docker 安装 + UFW 共存加固

Docker 发布端口（`-p 8080:80`）走 nat 表 DNAT，包在到达 ufw 的 INPUT/OUTPUT 之前就被转发 →
**ufw 的 allow 规则对容器端口完全无效**，端口直接暴露公网。加固入口是 `DOCKER-USER` 链。

**加固委托上游开源项目** [chaifeng/ufw-docker](https://github.com/chaifeng/ufw-docker)
（社区标准方案，固定 tag 版本 + 安装前 sha256 校验，防篡改/防 tag 漂移）。
本工具负责安装 Docker、状态判定（读内核）、非暴露模式、非 root 权限体检。

```bash
sudo docker-install                    # 向导：安装 → 检测 → 加固 → 暴露策略 → 用户组 → 权限检查
sudo docker-install firewall status    # 只读：是否绕过 + 列出已发布端口（含放行命令提示）
sudo docker-install firewall fix       # 加固（委托 ufw-docker install --docker-subnets，幂等）
sudo docker-install firewall lockdown  # 非暴露模式（推荐）：撤销全部转发放行，容器端口仅本机可达
sudo docker-install firewall allow <容器名> [端口]   # 放行该容器（按容器绑定 IP）
sudo docker-install firewall deny <容器名> [端口]    # 撤销放行
sudo docker-install firewall uninstall # 卸载加固（ufw-docker uninstall + 清内核残留）
```

**推荐姿势**：容器一律 `-p 127.0.0.1:8080:80` 只绑本机，对外统一走 Nginx 反代只开 443；
配合 `firewall lockdown` 确保零放行 —— 公网完全不可达容器端口。

注意：`allow` 的端口是**容器内部端口**（不是 `-p` 的宿主端口），且**按容器绑定**
（容器重建换 IP 后需重新 allow，这是上游语义）。

### nginx-install — nginx 官方源安装

发行版仓库的 nginx 版本普遍落后，本工具按 [nginx.org 官方文档](https://nginx.org/en/linux_packages.html)
配置官方仓库并安装，**签名密钥校验不过直接拒绝安装**（fail-closed，不落盘不装包）。

```bash
sudo nginx-install                      # 向导：检测 → 选通道 → 安装 → 启用 → 体检
sudo nginx-install install              # 安装/升级 stable
sudo nginx-install install mainline     # 安装/升级 mainline
nginx-install status                    # 体检（只读，无需 root）
```

**安全契约**（三条，均有真机/实测支撑）：

1. **签名密钥校验 fail-closed** —— apt 密钥环必须包含官方指纹
   `573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62`；apk 公钥 DER 摘要必须等于官方值。
   校验不通过 → 报错退出，**密钥不落盘、包不安装**。
2. **apt Pin-Priority 900** —— 不设的话发行版仓库的同名包优先级更高，官方源装了等于没装。
3. **幂等** —— 重复执行 = 覆盖更新；仓库文件内容不变则不重写（不制造无谓 mtime 变化）。

通道（stable / mainline）写入 `/etc/nginx-install.env` 的 `NI_CHANNEL`；留空则向导询问（回车默认 stable）。

**站点配置不在本工具范围**：安装后手工写 `/etc/nginx/conf.d/<站点>.conf`。
生产姿势与 docker-install 联动 —— 容器 `-p 127.0.0.1:8080:80` 只绑本机 + `docker-install firewall lockdown`，
对外统一由 nginx 反代只开 443。

### vps-bench — 节点测速

```bash
sudo vps-bench               # 交互选择测速脚本
sudo vps-bench nodequality   # NodeQuality 测速
sudo vps-bench tcpquality    # TcpQuality 测速
```

> 第三方脚本以管道方式执行（供应链风险），执行前显示来源 URL 并确认。

### vps-backup — restic + rclone(Google Drive) 备份与灾难恢复

每台 VPS 独立 repo（`rclone:gdrive:vps-backup/<hostname>`），客户端加密 + 全局去重，
**云端只见密文**；恢复路径专为「快速灾难恢复」设计。

```bash
sudo vps-backup deps                # 安装 restic + rclone（官方二进制 + sha256 校验，fail-closed）
sudo vps-backup                     # 向导：依赖 → 密码 → repo 连接 → 范围 → 通知 → timer → runbook
sudo vps-backup password            # 设定 repo 密码（仅首次；已存在则拒绝覆盖）
sudo vps-backup init                # 首次初始化 repo（已存在则拒绝）
sudo vps-backup backup core         # 立刻备一次 core
sudo vps-backup snapshots           # 看快照（只读）
sudo vps-backup restore latest --tag core --target /tmp/restore
sudo vps-backup status              # repo/依赖/remote/快照新鲜度/timer/凭证自检
sudo vps-backup runbook             # 生成灾难恢复文档（/root/VPS-RESTORE.md）
```

**repo 密码（首次部署必读）**：向导的 `[2/7]` 步骤会引导生成或录入密码并落盘
`/etc/restic-password`（600）。**该密码是唯一的钥匙（restic 无后门），丢失 = 备份永久不可读**，
落盘后必须立刻存入 Bitwarden。非交互场景用 `VP_PASSWORD=<密码> vps-backup password`
（不提供则拒绝，工具**绝不**凭空生成一把你不知道的密码）。已有密码时工具**永不覆盖**。

**rclone remote 名必须逐字符一致**：`VP_RCLONE_REMOTE` 只填**裸名**（如 `gdrive`），
不带冒号/路径，且必须等于 `rclone listremotes` 里的名字。名字不一致是最常见的故障，
症状是「明明配好了却报 remote 未配置」——v1.3.0 起工具会打印 rclone 实有 remote 名
与两条修正路径（改 env / 改 rclone），不再只给一句误导文案。

**备份路径完全可自定义**（分层只是默认建议，不是硬编码）：

```bash
sudo vps-backup paths show                       # 查看两层路径 + 体检（存在性/排除冲突）
sudo vps-backup paths edit                       # 交互逐层设置
sudo vps-backup paths set data /srv /opt/app     # 直接设置某层（空格分隔绝对路径）
sudo vps-backup exclude add /srv/scratch         # 排除表管理
sudo vps-backup exclude remove /mnt              # 移除排除项（凭证类模式受保护）
```

也可直接编辑 `/etc/vps-backup.env` 的 `VP_BACKUP_CORE_PATHS` / `VP_BACKUP_DATA_PATHS`，改完立即生效。

⚠️ **自定义路径的两个静默失败陷阱（已内置防护）**：
- 路径落在**排除表覆盖的位置**（`/tmp`、`/mnt`、`~/.cache`…）→ restic 会「成功退出但备份 0 文件」。
  工具现在会：设置时**拒绝**、备份时**跳过并告警**、备份后**复核快照文件数**（0 则报错）。
- 路径是**空目录** → 同上按 0 文件失败处理（不再是假成功）。

**分层备份（快速恢复的核心）**：

| 层 | 内容 | 频率 | 恢复 |
|---|---|---|---|
| `core` | `/etc`、`/root`、dotfiles、`/usr/local/lib/vps-tools`、wrapper | 每 6h | 秒~分钟（MB 级） |
| `data` | `/var/lib/docker/volumes`、`/srv`、`/opt` | 每日 03:30 | 按体量，可后台 |

先恢复 core → 服务立刻能起 → data 后台慢慢恢复。

**四条硬设计**：

1. **凭证不入包（防自噬）** —— `/etc/restic-password`、`/etc/vps-backup.env`、`rclone.conf`
   一律写进排除表。机器全毁时靠 Bitwarden 里的密码才读得回备份；备份包里**不含打开自己的钥匙**。
   `vps-backup status` 会做凭证排除自检。
2. **connect 与 init 严格分离** —— `connect` 只校验连通与密码，恢复场景**绝不执行 init**；
   `init` 对已存在 repo 直接拒绝。
3. **恢复必须显式 `--target`** —— 工具不做裸覆盖 `/`；恢复到 `/tmp/restore` 人工核对后再覆盖。
4. **失败告警单一出口** —— systemd 单元 `OnFailure=vps-backup-failnotify@.service`，
   脚本自身跑不起来（restic 缺失 / env 缺失 / token 过期）也能告警；成功才发完成通知，不刷双卡。

**repo 锁**：定时任务撞车/异常退出会留下锁，`--retry-lock`（默认 10m）自动等待；
真被锁住时报错会明确指向 `vps-backup unlock`（不误导去跑 `repair`）。
⚠️ restic 的 `unlock` **只清陈旧锁**（持锁进程已消失）；若进程仍在，工具会如实报「锁仍在」
并提示 `unlock --all`（`--remove-all`）——不会假报成功。

**Google Drive 配置要点（不做会静默失效）**：

- rclone 内置 shared client_id **已停用** → 必须自建 OAuth client_id（Desktop app）
- OAuth app 留在 **Testing** 状态 → 授权 **7 天过期**（每 7 天要重走浏览器授权）
  → 必须 **PUBLISH APP** 切 production（个人 <100 用户免审核）
- 上传限额 **750 GiB/日**（未公开）→ 工具默认设 `RCLONE_DRIVE_STOP_ON_UPLOAD_LIMIT=true`，
  命中即致命退出而非静默截断，次日增量续跑
- 回收站会占配额 → 排除表 + `--drive-use-trash=false` 语义（restic 需要真删）

**调度**：systemd timer（`vps-backup-backup@core.timer` / `@data.timer` / `vps-backup-maintain.timer`），
不用 cron。维护单元每周执行 `forget + prune + check --read-data-subset=5%`。

---

## 仓库结构

```
vps-tools/
├── install.sh              # 一键安装/更新/卸载器（工具注册表在文件头 TOOLS）
├── README.md
├── monitor/                # 监控类（流量/资源/服务状态）
│   └── vnstat-monitor/
│       ├── vnstat-monitor.sh
│       └── vnstat-monitor.env.example
├── proxy/                  # 代理类（xray/sing-box 等）
│   └── xray-deploy/
│       ├── xray-deploy.sh          # 入口：菜单 + 子命令分发
│       └── lib/                    # 25 模块（common/service/fallback/keys/registry/
│                                   #   client-*/inbound/state/outbound/routing/chain/
│                                   #   proto-*/cmd-*/globalping/usage…）
├── web/                    # Web 服务类
│   └── nginx-install/
│       ├── nginx-install.sh        # 入口：向导 + 子命令分发
│       ├── lib/                    # common/keys/repo/install/status/usage
│       └── nginx-install.env.example
├── utils/                  # 通用工具
│   ├── vps-init/
│   │   ├── vps-init.sh             # 入口
│   │   ├── lib/                    # common/sshkey/dd/system/user/ssh/fail2ban/ufw
│   │   ├── templates/              # sshd drop-in / fail2ban jail.local
│   │   └── vps-init.env.example
│   └── docker-install/
│       ├── docker-install.sh       # 入口
│       ├── lib/                    # common/install/firewall/firewall-rules/access/
│       │                           #   usage/lockdown/ufwdocker
│       └── docker-install.env.example
├── bench/                  # 测试类（测速/基准）
│   └── vps-bench/
│       └── vps-bench.sh
├── backup/                 # 备份类
│   └── vps-backup/
│       ├── vps-backup.sh           # 入口
│       ├── lib/                    # common/interact/pkg/restic/remote/exclude/paths/deps/
│       │                           #   repo/backup/retention/restore/timer/status/usage
│       └── templates/vps-backup.env.example
└── tests/                  # 回归测试（run-all.sh = 统一入口）
```

---

## 测试

**统一入口**（推荐）——自动发现全部套件，真机 E2E 缺依赖时自行 SKIP：

```bash
bash tests/run-all.sh              # 全量
bash tests/run-all.sh backup       # 只跑名字匹配 "backup" 的套件
```

各套件断言数（2026-09-19 实测）：

| 套件 | 断言 | 说明 |
|---|---|---|
| `verify-vps-backup.sh` | 175 | vps-backup 回归（mock，无需 root/网络） |
| `verify-nginx-install.sh` | 72 | nginx-install 回归（mock）⚠️ 1 既存 FAIL |
| `verify-xray-deploy-routing.sh` | 56 | xray 分流规则 |
| `verify-docker-install.sh` | 53 | docker-install 回归（mock） |
| `verify-xray-deploy-chain.sh` | 46 | xray 链式代理 |
| `verify-vps-init-user-sshkey.sh` | 34 | vps-init 建用户 + 注入公钥（mock） |
| `verify-xray-deploy-latest.sh` | 25 | xray 版本/升级 |
| `verify-xray-deploy-behavior.sh` | 24 | xray 行为契约 |
| `verify-install-selfupdate.sh` | 23 | install.sh 自更新（mock curl，离线可跑） |
| `verify-xray-deploy-e2e.sh` | 16 | xray 端到端（需真实环境） |
| `verify-xray-deploy-mode-e2e.sh` | 11 | xray 模式端到端 |
| `verify-vps-backup-e2e.sh` | 48 | vps-backup 真机 E2E（需 restic+rclone，local backend 模拟 GDrive，零出境） |
| `verify-xray-deploy-all.sh` | — | 端到端分流切换 ⚠️ 既存 FAIL |
| `verify-xray-deploy-split.sh` | — | 新增函数白名单 ⚠️ 既存 FAIL |

> **已知既存失败**（与当前改动无关，记录在 `run-all.sh` 的 `KNOWN_FAIL`）：
> `verify-nginx-install.sh`（1 断言：install_self 陈旧副本刷新）、
> `verify-xray-deploy-all.sh`、`verify-xray-deploy-split.sh`。

**约定**：每个套件必须**以 `[[ "$FAIL" -eq 0 ]]` 结尾**（或显式 `exit 1`），
让退出码反映结果。否则 `run-all.sh` 这类调用方会把带 FAIL 的套件误报为 PASS（假绿）。

回归脚本用 PATH stub 模拟 ufw/iptables/ip6tables/systemctl/docker 与上游 ufw-docker，
覆盖：委托上游的调用契约、sha256 校验 fail-closed、幂等、lockdown 持久化、
状态判定分支、架构规约（单文件 ≤200 行）、无死代码/无悬空函数。

改工具后**先跑 `run-all.sh`**；`FAIL=0` 才算过。真机验收另见各工具的端到端套件（需外部主机做视角）。

---

## 开发约定

**新增工具**：按功能域放入对应目录 + 在 `install.sh` 的 `TOOLS` 注册表加一行（格式见文件头注释）。
多文件工具在注册表第 6 字段 `extra_files` 列出全部附加文件。

每个工具必须遵守：

- **版本号**：脚本头部定义 `VERSION="x.y.z"`，发布新功能时递增
- **`-v`/`--version`/`-V`**：输出 `<工具名> <版本号>`（如 `vnstat-monitor 1.0.0`）
- **`-h`/`--help`**：输出用法说明（子命令清单 + 示例）
- **定时调度**：统一用 systemd timer（工具 `setup` 子命令管理），不使用 crontab
- **配置**：`/etc/<tool>.env`（600 权限，模板含 `${PLACEHOLDER}` 占位符，真实密钥本机填写）
- **架构规约**：单文件 ≤200 行；超出必须拆分（视图/逻辑解耦，工具函数入 `lib/`）
- **脱敏铁律**：任何密钥/令牌一律 `${PLACEHOLDER}`，真实值只在本机 `/etc/*.env`
- **环境变量导出**：从 env 文件读取的变量若需传给子进程，必须写
  `export VAR="$VAL"`；**裸 `export VAR` 只标记已存在的变量，不会赋值**
  （曾导致 `RCLONE_CONFIG` 静默失效，见 `tests/verify-vps-backup.sh` 的 `[O]` 组）

---

## 更新 vps-tools 自身

```bash
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash   # 推荐
sudo vps-tools self-update        # 或：管理菜单选 5
```

⚠️ **若你装的是 v1.7.0 或更早**，菜单选 5 / `self-update` 是坏的（见下），请用管道方式。

**已修 bug（v1.7.1）**：从已装副本 `/usr/local/bin/vps-tools` 运行时，`$VPS_TOOLS_VERSION`
与 `installed_self_version()` 读的是**同一个文件** → 版本恒等 → 恒报「已是最新」，
**永远不下载远端新版**（用户反馈「菜单选 5 无法更新自身」的根因）。
修复：比对基准改用 `remote_version()`（远端 install.sh 版本），并补三道防线——
临时文件落盘（防半截覆盖）、下载内容合法性校验（防错误页覆盖可用命令）、
防降级（本机高于远端不覆盖）+ 写后复核。回归见 `tests/verify-install-selfupdate.sh`。
