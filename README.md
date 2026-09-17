# vps-tools

个人 VPS 运维脚本集。全部脚本通过 `install.sh` 一键安装/更新/卸载，脚本内敏感信息一律使用 `${PLACEHOLDER}` 占位符，真实密钥只存在于各机器 `/etc/*.env` 配置文件中，不入库。

## 快速开始

### 方式一：一键安装 + 交互式管理（推荐）

SSH 登录 VPS 后直接运行，自动安装管理命令 `vps-tools` 并进入交互菜单（安装/更新/卸载/查看工具均可选择）：

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

> 管道方式（curl | sudo bash）下 stdin 被 curl 占用，脚本会自动改从 `/dev/tty` 读取输入，**交互菜单依然可用**。

安装完成后，之后的管理直接运行：

```bash
sudo vps-tools          # 进入交互式管理菜单
sudo vnstat-monitor     # 直接调用工具（等价于 xray-deploy 等工具名）
sudo xray-deploy        # Xray 部署/管理入口
```

### 方式二：命令行指定工具（脚本/CI 场景）

```bash
# 安装/更新指定工具（重复执行即覆盖更新，配置保留）
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- install vnstat-monitor
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- install xray-deploy

# 卸载（脚本删除，配置保留防误删密钥）
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- uninstall vnstat-monitor

# 查看可用工具（list 不需要 root）
bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) list

# 本地已下载时
sudo bash install.sh install vnstat-monitor
```

> **关于 root**：`install/update/uninstall` 必须 root。管道方式 `curl | sudo bash -s --` 自动以 root 运行（普通用户登录的 VPS 也能用）；非 root 直接运行会提示并给出完整 sudo 命令。
> **关于交互**：无参数运行进入交互管理菜单；纯 CI/无终端环境请用方式二指定工具，避免卡在输入等待。

## 安装器行为

- 脚本下载到 `/usr/local/lib/vps-tools/<tool>/`，与系统文件隔离，卸载即删目录
- 每个工具自动生成命令入口 `/usr/local/bin/<tool>`，**直接以工具名调用**（如 `vnstat-monitor`、`xray-deploy`、`vps-tools`）
- 首次安装自动生成配置模板 `/etc/<tool>.env`（`chmod 600`，已存在不覆盖），**需手动填入真实密钥**
- 定时调度统一用 **systemd timer**（工具 `setup` 子命令管理，如 `vnstat-monitor setup`），不使用 crontab
- 重复 `install` = 覆盖更新，幂等

## 仓库结构（按功能域分类）

### 工具开发约定（新增工具必须遵守）

- **版本号**：脚本头部定义 `VERSION="x.y.z"`，发布新功能时递增
- **`-v`/`--version`/`-V`**：输出 `<工具名> <版本号>`（如 `vnstat-monitor 1.0.0`）
- **`-h`/`--help`**：输出用法说明（子命令清单 + 示例）
- **定时调度**：统一用 systemd timer（工具 `setup` 子命令管理），不使用 crontab
- **配置**：`/etc/<tool>.env`（600 权限，模板含 `${PLACEHOLDER}` 占位符，真实密钥本机填写）

```
vps-tools/
├── install.sh          # 一键安装/更新/卸载器（工具注册表在文件头 TOOLS）
├── README.md
├── monitor/            # 监控类（流量/资源/服务状态）
│   └── vnstat-monitor/
│       ├── vnstat-monitor.sh
│       └── vnstat-monitor.env.example
├── network/            # 网络类（路由/隧道/分流）
├── proxy/              # 代理类（xray/sing-box 等辅助脚本）
│   └── xray-deploy/
│       └── xray-deploy.sh
├── utils/              # 通用工具（DDNS/证书/初始化/容器运行时等）
│   ├── vps-init/
│   │   ├── vps-init.sh              # 一键初始化 VPS（入口）
│   │   ├── lib/                     # 模块拆分（common/dd/system/user/ssh/ufw/fail2ban）
│   │   ├── templates/               # sshd drop-in / fail2ban jail.local 模板
│   │   └── vps-init.env.example
│   └── docker-install/              # Docker 安装 + UFW 共存加固 + 非 root 管理（2026-09-17）
│       ├── docker-install.sh        # 入口：向导 + 子命令分发
│       ├── lib/                     # common/render/install/firewall/firewall-rules/access/usage
│       ├── templates/               # ufw-docker-block.rules.tpl（DOCKER-USER 规则块）
│       └── docker-install.env.example
├── bench/              # 测试类（测速/基准）
│   └── vps-bench/
│       └── vps-bench.sh
└── backup/             # 备份类
```

新增脚本：按功能域放入对应目录 + 在 `install.sh` 的 `TOOLS` 注册表加一行（格式见文件头注释）。
多文件工具（如 vps-init 的 lib/、templates/）在注册表第 6 字段 `extra_files` 列出全部附加文件。

## 工具清单

| 工具 | 分类 | 用途 | 依赖 |
|---|---|---|---|
| [vnstat-monitor](monitor/vnstat-monitor/) | monitor | vnStat + Telegram 流量监控：进度条/偏移校准/熔断关机/无限流量模式；原地更新消息防刷屏（2026-08-08 修复孤儿卡片：错误分类+原子写状态） | vnstat, jq, curl, gawk, iproute2 |
| [xray-deploy](proxy/xray-deploy/) | proxy | Xray 一键部署：交互菜单/子命令双模式；协议注册表可扩展（VLESS-TCP-XTLS-Vision-REALITY 默认 / VLESS-XHTTP-REALITY 含 XMUX / VLESS-XHTTP-H2-TLS / Hysteria2 hy2）；回落域名半自动筛选（VPS 侧握手 + Globalping 中国方向可达性双检）；MetaCubeX geosite/geoip 每周自动更新；生成 mihomo/sing-box 客户端节点；服务端 routing 防国内访问 | curl, unzip, jq, openssl |
| [vps-init](utils/vps-init/) | utils | 一键初始化 VPS：DD 重装（全自动续跑）/ 时区 / BBR / 普通用户+sudo / SSH 密钥+随机高位端口+禁密码 / Fail2Ban / UFW；模块化 lib/ + 模板渲染 | curl, openssh-server |
| [vps-bench](bench/vps-bench/) | bench | 节点测速：NodeQuality / TcpQuality 二选一（第三方脚本封装，执行前明示来源） | curl |
| [docker-install](utils/docker-install/) | utils | Docker 安装（官方源）+ **Docker×UFW 共存加固**（DOCKER-USER 接管，防发布端口绕过防火墙）+ 非 root 管理（docker 组/rootless 提示）+ 权限体检（socket/`~/.docker`/bind mount 属主漂移） | curl, iptables, ufw |

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
   # 或直接指定频率：
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
xray-deploy info               # 查看节点信息（明文 + mihomo/sing-box 客户端配置片段，无需 root）
xray-deploy config show        # 查看服务端 config.json
sudo xray-deploy config edit   # 编辑 config.json（保存后自动 xray -test 校验并重载）
xray-deploy fallback-test      # 测试全部回落候选的握手延迟并排序（部署前选型/诊断用）
xray-deploy fallback-test www.example.com   # 测试指定域名是否可作回落
xray-deploy fallback-cn-test   # 回落域名**中国方向**可达性检测（Globalping 中国三网探针，需外网）
xray-deploy fallback-cn-test www.example.com   # 检测单个域名的中国方向 ICMP/HTTPS 通过率
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
> 二者互补——VPS 侧握手快但中国方向被 SNI 阻断的域名，国内用户照样连不上。`fallback-cn-test` 需访问
> `api.globalping.io`（速率限制 250 次/时，每域名消耗 2 次），故不并入 install 默认流程，按需手动执行。

> **数据出境确认（`fallback-cn-test` 专属）**：Globalping 是第三方公共 API，待测域名会被提交出境并留存在其
> **公开测量记录**中（提交内容仅域名 + 请求类型，不含服务器 IP / 密钥 / 节点信息）。因此该命令**提交前强制确认，
> 默认拒绝**——无交互终端（无 TTY）时同样拒绝，不会静默发出任何数据。自动化场景用 `CN_TEST_ASSUME_YES=1` 显式放行：

```bash
# 交互：会先打印出境提示，输 y 才提交
sudo xray-deploy fallback-cn-test

# 自动化/CI：显式放行（仅限你确认可出境的域名）
CN_TEST_ASSUME_YES=1 sudo xray-deploy fallback-cn-test www.example.com
```

> **客户端兼容性硬约束（Xray ≥ 26.9.8）**：mihomo 默认从 ClientHello 剥离 X25519MLKEM768 扩展，而 Xray 26.9.8+
> 对不带该扩展的 REALITY 握手直接拒绝（症状：`REALITY authentication failed`、服务端 `accepted=0`）。
> 本工具生成的 mihomo 片段已自动包含 `support-x25519mlkem768: true`，**勿手工删除**。
> 反事实实测：带该字段 HTTP 200，删除后连接失败。

### vps-init — 一键初始化 VPS

```bash
sudo vps-init               # 交互向导：system → user → ssh → ufw → fail2ban（每步确认，已完成自动跳过）
sudo vps-init dd            # 一键 DD 重装（全自动续跑，cloud-init 首启自动初始化）
vps-init status             # 查看已执行步骤 / SSH 端口 / 时区 / BBR / UFW
```

常用单步子命令（幂等，可单独执行）：

```bash
sudo vps-init system        # 时区 Asia/Shanghai + BBR
sudo vps-init user          # 创建普通用户 + sudo（VPS_INIT_SKIP_USER=1 跳过 = root-only）
sudo vps-init ssh           # SSH 密钥注入 + 随机高位端口 + 禁用密码登录
sudo vps-init ufw           # UFW：deny incoming，放行 SSH 端口 + 额外端口
sudo vps-init fail2ban      # Fail2Ban：backend/banaction 自动探测，端口注入
```

一键 DD（全自动续跑）：

```bash
sudo vps-init dd                        # 交互输入发行版/版本/端口/用户/密码/公钥
sudo vps-init dd --distro debian --version 13 --port 52322 --user admin --pubkey /path/id_ed25519.pub
```

- DD 原理：调用 [bin456789/reinstall](https://github.com/bin456789/reinstall)，`--ci + --cloud-data` 把自包含初始化脚本（时区/BBR/用户/SSH/UFW/Fail2Ban）打包进 cloud-init，**新系统首启自动完成全部初始化**；公钥经 `--ssh-key` 注入，重启后直接密钥登录
- 密码以 sha-512 哈希注入（不落明文）；双重确认（输入 `YES`）才执行
- 限制：alpine/arch/gentoo 等不支持 cloud-init 的发行版自动降级为"注入密钥+端口，重启后手动 vps-init"
- 配置：`/etc/vps-init.env`（可缺省）——`VPS_INIT_USER/SSH_PUBKEY/SSH_PORT`、`SSH_PORT_MIN/MAX`（随机端口范围）、`VPS_INIT_EXTRA_PORTS`（UFW 额外端口）、`VPS_INIT_SKIP_USER`、`VPS_INIT_DISABLE_ROOT`、`VPS_INIT_YES`
- 防失联：禁密码登录前置校验 authorized_keys 非空；所有 sshd 变更先 `sshd -t`；改端口后保持当前会话、开新窗口验证

### vps-bench — 节点测速

```bash
sudo vps-bench               # 交互选择测速脚本
sudo vps-bench nodequality   # NodeQuality 测速
sudo vps-bench tcpquality    # TcpQuality 测速
```

> 第三方脚本以管道方式执行（供应链风险），执行前显示来源 URL 并确认。

### docker-install — Docker 安装 + UFW 共存加固

**为什么需要它**：Docker 通过 `nat` 表 DNAT 转发已发布端口，数据包在到达 ufw 的
`INPUT/OUTPUT` 链**之前**就被处理 —— 所以 `ufw allow 8080` 对 `-p 8080:80` 的容器
**完全无效**，端口照样暴露公网。唯一官方入口是 `DOCKER-USER` 链（在 Docker 自身规则前执行）。

```bash
sudo docker-install                  # 向导：安装 → 检测 → 加固 → 放行 → 用户组 → 权限检查
sudo docker-install firewall status  # 只读检测：是否绕过 + 列出当前公网可达端口
sudo docker-install firewall fix     # 加固（幂等，可重复执行）
sudo docker-install firewall allow 80  # 放行公网访问容器端口 80
sudo docker-install firewall deny 80   # 撤销
sudo docker-install firewall uninstall # 还原（移除规则块）

sudo docker-install user admin       # admin 加入 docker 组（非 root 管理 docker）
sudo docker-install perms check      # 检查 socket / 配置目录 / bind mount 属主
sudo docker-install perms fix /srv/docker/app   # 修正指定路径属主（必须显式指定）
sudo docker-install status           # 汇总状态
```

关键点：

- **放行匹配的是容器内部端口**，不是 `-p` 的宿主映射端口（`ufw route allow ... port 80`）
- 加固后判定状态**读内核实际规则**（`iptables -S DOCKER-USER`）复核，不读文件、不信命令回显
- 规则块沿用 `# BEGIN UFW AND DOCKER` 标记 → 与 [chaifeng/ufw-docker](https://github.com/chaifeng/ufw-docker) **互认**，已装该工具的机器可直接接管（幂等：先删旧块再追加）
- 检测到 **Docker nftables 后端**（实验性，无 `DOCKER-USER` 链）时**拒绝自动加固**，只给手工路径
- `docker` 组成员**等价于 root**（可 `-v /:/host`），工具会显式告警；多人机器建议 rootless
- `perms` 默认只 check；`fix` 必须显式指定路径，**不做全盘 chown**

## 安全约定

- 仓库内禁止提交任何真实 Token / 密钥 / Cookie，一律 `${PLACEHOLDER}`
- 配置模板（`.env.example`）可入库；实际配置 `/etc/<tool>.env` 绝不入库
- 如需在 CI 等场景使用密钥，走 GitHub Actions Secrets，禁止写死进脚本

## 开发

新增工具三步：

1. 建目录 `mkdir <分类>/<tool>/`（分类见上方结构图），放脚本 + `*.env.example`
2. 在 `install.sh` 的 `TOOLS` 注册表追加一行（格式见文件头注释，路径带分类前缀）
3. 更新本 README 工具清单
