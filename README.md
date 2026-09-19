# vps-tools

个人 VPS 运维脚本集。全部工具通过 `install.sh` 一键安装/更新/卸载，脚本内敏感信息一律使用 `${PLACEHOLDER}` 占位符，真实密钥只存在于各机器 `/etc/*.env` 配置文件中，不入库。

> **本 README 只讲 vps-tools 自身**（安装器 / 仓库结构 / 开发约定）。
> 每个工具的用法、配置项、原理与已知坑，见各自目录下的 `README.md`（见下方[工具清单](#工具清单)）。

## 目录

- [快速开始](#快速开始)
- [工具清单](#工具清单)
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
sudo vnstat-monitor     # 直接调用工具（工具名即命令）
sudo xray-deploy        # 例如 Xray 部署/管理入口
```

### 方式二：命令行指定工具（脚本/CI 场景）

```bash
# 安装/更新指定工具（重复执行即覆盖更新，配置保留）
curl -sSL .../install.sh | sudo bash -s -- install vnstat-monitor

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
- **安装/更新后不自动执行任何工具命令**（2026-09-19 起）：安装器只负责放脚本 + 生成配置 + 生成命令入口。
  需要交互式配置或安装 systemd timer 的工具，安装完成后会打印**下一步指引**，由你显式执行：
  ```bash
  sudo nano /etc/<tool>.env      # 填配置
  sudo <tool> setup              # 交互式配置 + 安装 systemd timer（仅部分工具有 setup 子命令）
  ```
  注册表第 5 字段就是这里提示的子命令（`vnstat-monitor` → `setup`、`xray-deploy` → `install`、
  `vps-bench` → `nodequality`；`docker-install` / `nginx-install` / `vps-backup` / `vps-init`
  留空 = 无参运行工具本身进向导）。**该字段只用于打印提示，安装器绝不代为执行。**
- 定时调度统一用 **systemd timer**（工具 `setup` 子命令管理），不使用 crontab
- 重复 `install` = 覆盖更新，幂等

---

## 工具清单

7 个工具，按功能域分类。点击工具名进入各自的完整文档。

| 工具 | 域 | 用途 | 依赖 | 结构 |
|---|---|---|---|---|
| [vnstat-monitor](monitor/vnstat-monitor/README.md) | monitor | vnStat + Telegram 流量监控：进度条 / 偏移校准 / 熔断关机 / 无限流量模式；原地更新消息防刷屏 | vnstat, jq, curl, gawk, iproute2 | 单文件 |
| [xray-deploy](proxy/xray-deploy/README.md) | proxy | Xray 一键部署：5 协议注册表；回落域名双检（VPS 握手 + Globalping 中国方向）；中转+落地链式代理与分流；生成 mihomo/sing-box 客户端节点 | curl, unzip, jq, openssl | 多文件（25 lib） |
| [vps-init](utils/vps-init/README.md) | utils | 一键初始化 VPS：DD 重装（全自动续跑）/ 时区 / BBR / 用户 + sudo + SSH 公钥注入 / 禁密码 + 随机高位端口 / Fail2Ban / UFW | curl, openssh-server | 多文件（8 lib + 2 tpl） |
| [docker-install](utils/docker-install/README.md) | utils | Docker 官方源安装 + **Docker×UFW 共存加固**（委托 [chaifeng/ufw-docker](https://github.com/chaifeng/ufw-docker)，固定版本 + sha256 校验）+ 非暴露模式 + 非 root 管理 + 权限体检 | curl, iptables, ufw | 多文件（8 lib） |
| [nginx-install](web/nginx-install/README.md) | web | nginx 官方源安装（stable/mainline）+ **签名密钥 fail-closed 校验**（apt 指纹 / apk 摘要）+ apt Pin-Priority 900 + 体检 | curl, gnupg/openssl, apt/dnf/apk | 多文件（6 lib） |
| [vps-bench](bench/vps-bench/README.md) | bench | 节点测速：NodeQuality / TcpQuality 二选一（第三方脚本封装，执行前明示来源） | curl | 单文件 |
| [vps-backup](backup/vps-backup/README.md) | backup | **restic + rclone(GDrive) 备份与灾难恢复**：core/data 分层；保留策略 forget+prune；每周完整性抽查；**凭证不入包**；connect/init 严格分离；**repo 密码引导**；remote 名分态诊断；Telegram 失败告警；自动生成恢复 runbook | restic, rclone（自带 sha256 校验安装）, curl | 多文件（15 lib） |

**按域索引**：

- **monitor** — [vnstat-monitor](monitor/vnstat-monitor/README.md)
- **proxy** — [xray-deploy](proxy/xray-deploy/README.md)
- **web** — [nginx-install](web/nginx-install/README.md)
- **utils** — [vps-init](utils/vps-init/README.md) · [docker-install](utils/docker-install/README.md)
- **backup** — [vps-backup](backup/vps-backup/README.md)
- **bench** — [vps-bench](bench/vps-bench/README.md)

---

## 仓库结构

```
vps-tools/
├── install.sh              # 一键安装/更新/卸载器（工具注册表在文件头 TOOLS）
├── README.md               # 本文件：安装器 + 仓库结构 + 开发约定
├── monitor/                # 监控类（流量/资源/服务状态）
│   └── vnstat-monitor/
│       ├── README.md
│       ├── vnstat-monitor.sh
│       └── vnstat-monitor.env.example
├── proxy/                  # 代理类（xray/sing-box 等）
│   └── xray-deploy/
│       ├── README.md
│       ├── xray-deploy.sh          # 入口：菜单 + 子命令分发
│       └── lib/                    # 25 模块（common/service/fallback/keys/registry/
│                                   #   client-*/inbound/state/outbound/routing/chain/
│                                   #   proto-*/cmd-*/globalping/usage…）
├── web/                    # Web 服务类
│   └── nginx-install/
│       ├── README.md
│       ├── nginx-install.sh        # 入口：向导 + 子命令分发
│       ├── lib/                    # common/keys/repo/install/status/usage
│       └── nginx-install.env.example
├── utils/                  # 通用工具
│   ├── vps-init/
│   │   ├── README.md
│   │   ├── vps-init.sh             # 入口
│   │   ├── lib/                    # common/sshkey/dd/system/user/ssh/fail2ban/ufw
│   │   ├── templates/              # sshd drop-in / fail2ban jail.local
│   │   └── vps-init.env.example
│   └── docker-install/
│       ├── README.md
│       ├── docker-install.sh       # 入口
│       ├── lib/                    # common/install/firewall/firewall-rules/access/
│       │                           #   usage/lockdown/ufwdocker
│       └── docker-install.env.example
├── bench/                  # 测试类（测速/基准）
│   └── vps-bench/
│       ├── README.md
│       └── vps-bench.sh
├── backup/                 # 备份类
│   └── vps-backup/
│       ├── README.md
│       ├── vps-backup.sh           # 入口
│       ├── lib/                    # common/interact/pkg/restic/remote/exclude/paths/deps/
│       │                           #   repo/backup/retention/restore/timer/status/usage
│       └── templates/vps-backup.env.example
└── tests/                  # 回归测试（run-all.sh = 统一入口）
```

**文档索引约定**：仓库根 README 只讲安装器与仓库结构；每个工具的文档放在
`<域>/<tool>/README.md`，由根 README 的[工具清单](#工具清单)与上方结构树双向索引。

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
| `verify-docker-install.sh` | 59 | docker-install 回归（mock） |
| `verify-install-noexec.sh` | 65 | 安装器契约：**不自动执行工具命令** + 指引子命令真实性 + README 索引完整性（mock，离线可跑） |
| `verify-xray-deploy-routing.sh` | 56 | xray 分流规则 |
| `verify-xray-deploy-chain.sh` | 46 | xray 链式代理 |
| `verify-vps-backup-e2e.sh` | 48 | vps-backup 真机 E2E（需 restic+rclone，local backend 模拟 GDrive，零出境） |
| `verify-vps-init-user-sshkey.sh` | 34 | vps-init 建用户 + 注入公钥（mock） |
| `verify-xray-deploy-latest.sh` | 25 | xray 版本/升级 |
| `verify-xray-deploy-behavior.sh` | 24 | xray 行为契约 |
| `verify-install-selfupdate.sh` | 23 | install.sh 自更新（mock curl，离线可跑） |
| `verify-xray-deploy-e2e.sh` | 16 | xray 端到端（需真实环境） |
| `verify-xray-deploy-mode-e2e.sh` | 11 | xray 模式端到端 |
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

**新增工具**：

1. `mkdir <域>/<tool>/`，放入脚本 + `*.env.example`（密钥一律 `${PLACEHOLDER}`）
2. 写 `<域>/<tool>/README.md`（用途 / 依赖 / 子命令 / 配置 / 原理 / 已知坑）
3. `install.sh` 的 `TOOLS` 注册表追加一行（格式见文件头注释；多文件工具在第 6 字段 `extra_files` 列出**全部**附加文件）
4. 根 `README.md` 的[工具清单](#工具清单)表 + [仓库结构](#仓库结构)树各加一行，链到该工具 README

每个工具必须遵守：

- **版本号**：脚本头部定义 `VERSION="x.y.z"`，发布新功能时递增
- **`-v`/`--version`/`-V`**：输出 `<工具名> <版本号>`（如 `vnstat-monitor 1.1.2`）
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

**变更（v1.8.0）**：安装/更新后**不再自动执行工具命令**（原先首次安装会自动调 `setup`）。
安装器现在只打印下一步指引，配置与 systemd timer 由你显式运行 `sudo <tool> setup` 完成。
