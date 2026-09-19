# vps-init

[← 返回仓库根](../../README.md)

新购 VPS 一键初始化：DD 重装 / 时区 / BBR / 普通用户 / SSH 加固 / UFW / Fail2Ban。
每一步幂等、可单独执行；向导模式逐项确认，已完成的步骤自动跳过。

| | |
|---|---|
| 域 | `utils/` |
| 版本 | `1.1.0` |
| 结构 | 多文件（入口 + 8 lib + 2 tpl） |
| 依赖 | curl, openssh-server |
| 配置 | `/etc/vps-init.env`（600，可缺省） |

## 安装

```bash
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- install vps-init
```

> 新机器上通常**不需要**走安装器——直接把 `vps-init.sh` 拷上去跑，或先 DD 重装再初始化。
> 安装器的价值在于：生成命令入口 `/usr/local/bin/vps-init`，并把脚本纳入 vps-backup 的 core 层备份。

## 用法

```bash
vps-init                    交互向导（system → user → ssh → ufw → fail2ban）
vps-init dd                 一键 DD 重装（全自动续跑，cloud-init 首启自动初始化）
vps-init system             单步: 时区 Asia/Shanghai + BBR
vps-init user               单步: 创建普通用户 + sudo + 注入 SSH 公钥
vps-init ssh                单步: SSH 密钥/随机高位端口/禁密码登录
vps-init ufw                单步: UFW（deny incoming，放行必要端口）
vps-init fail2ban           单步: Fail2Ban（SSH 防暴力破解）
vps-init status             查看已执行步骤/SSH端口/时区/BBR/UFW
vps-init -v, --version      显示版本号
vps-init -h, --help         显示本帮助
```

## DD 重装（全自动续跑）

```bash
sudo vps-init dd                        # 交互输入发行版/版本/端口/用户/密码/公钥
sudo vps-init dd --distro debian --version 13 --port 52322 --user admin --pubkey /path/id_ed25519.pub
```

原理：调用 [bin456789/reinstall](https://github.com/bin456789/reinstall)，
用 `--ci --cloud-data` 把自包含初始化脚本（时区/BBR/用户/SSH/UFW/Fail2Ban）打包进 cloud-init，
**新系统首启自动完成全部初始化**；公钥经 `--ssh-key` 注入。

- 密码以 sha-512 哈希注入（不落明文）；需输入 `YES` 双重确认才执行
- ⚠️ **镜像层支持 ≠ user-data 消费方支持**：reinstall 对 Debian 用 `nocloud` 镜像，
  而 Debian nocloud 镜像**不含 cloud-init 包** → `--cloud-data` 的 user-data 无人消费，
  自动续跑失效（新系统缺 BBR/UFW/Fail2Ban/普通用户，但 SSH 密钥/端口/禁密码仍由 preseed 配好）。
  **Ubuntu cloud image 强制带 cloud-init（可靠）**。工具已按「镜像层支持」与「user-data 消费方」
  分三态提示；alpine/arch/gentoo 等不支持 `--ci` 的发行版降级为「注入密钥 + 端口，重启后手动 `vps-init`」
- ⚠️ **reinstall 不自动 reboot**（只写 `grub-reboot` 一次性引导项）。工具会显式触发重启
  （退出码检查 → 倒数 5 秒可 Ctrl+C 取消 → `reboot`）
- 安装期间查看进度：HTTP `<IP>:80`（默认 web port）/ `ssh -p <ssh_port> root@<IP>`（临时密码）/ VNC 串口
- 取消：`sh reinstall.sh reset`

## 配置（`/etc/vps-init.env`，可缺省）

| 键 | 说明 |
|---|---|
| `VPS_INIT_USER` | 要创建的普通用户（空 = 向导询问；确认跳过 = root-only） |
| `VPS_INIT_USER_PASS` | 普通用户密码（sudo 提权用） |
| `VPS_INIT_SSH_PUBKEY` | SSH 公钥内容**或文件路径**（user 步骤与 ssh 步骤都用） |
| `VPS_INIT_PUBKEY_FILE` | 公钥文件路径（等价于把路径填到 `VPS_INIT_SSH_PUBKEY`） |
| `VPS_INIT_SSH_PORT` | SSH 端口（空 = 在 `SSH_PORT_MIN~MAX` 内随机生成） |
| `SSH_PORT_MIN` / `SSH_PORT_MAX` | 随机端口范围，默认 `20000` / `60000` |
| `VPS_INIT_EXTRA_PORTS` | UFW 额外放行端口，逗号分隔（如 `80,443` 或 `53/udp`） |
| `VPS_INIT_SKIP_USER` | `1` = 跳过创建普通用户（root-only） |
| `VPS_INIT_DISABLE_ROOT` | `1` = 禁用 root 登录（仅密钥；须先确认普通用户密钥可登录） |
| `VPS_INIT_YES` | `1` = 向导不逐项确认（CI/无人值守） |

## 设计要点

- **模板渲染**：`templates/*.tpl` 用 `__X__` 占位符，heredoc 捕获到变量后再 `sed` 替换
- **跨步骤状态传递**：user 步骤创建的用户名持久化到 `${STATE_DIR}/user`，ssh 步骤读取——
  否则向导场景下普通用户没注入密钥而密码被禁 = 半失联
- **幂等**：ssh 端口生成前先读已有 drop-in，重跑不换端口
- **可测试性**：`VPS_INIT_STATE_DIR` / `CONF_D` / `F2B_JAIL` / `BBR_CONF` 等路径可用环境变量覆盖

## ⚠️ 防失联（最致命）

- **改 SSH 认证的 drop-in 必须三行齐全**：`Port <新端口>` + `PasswordAuthentication no` +
  **`PubkeyAuthentication yes`**。若服务器主配置原本是 `PubkeyAuthentication no`，
  只写「禁密码」会让 sshd 允许的认证类型为空 → **SSH 完全失联**
  （症状 `Bad authentication type; allowed types: ['']`），只能走面板 VNC 恢复。
- **改 SSH 前先侦察**：
  ```bash
  grep -rE '^(Port|PasswordAuthentication|PubkeyAuthentication|PermitRootLogin)' \
    /etc/ssh/sshd_config /etc/ssh/sshd_config.d/
  ```
- **验证顺序铁律**：先注入密钥 → 确认密钥可登录 → 再禁密码。
- 禁密码登录前置校验 `authorized_keys` 非空；所有 sshd 变更先 `sshd -t`；
  改端口后保持当前会话、开新窗口验证。
