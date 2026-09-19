# docker-install

[← 返回仓库根](../../README.md)

Docker Engine 官方源安装 + **Docker × UFW 共存加固** + 非暴露模式 + 非 root 管理 + 权限体检。

| | |
|---|---|
| 域 | `utils/` |
| 版本 | `1.1.1` |
| 结构 | 多文件（入口 + 8 lib） |
| 依赖 | curl, iptables, ufw |
| 配置 | `/etc/docker-install.env`（600，可缺省） |

## 安装

```bash
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- install docker-install
```

安装器只放脚本 + 生成配置模板，**不会自动执行工具命令**。首次使用：

```bash
sudo nano /etc/docker-install.env    # 按需填 DI_DOCKER_USER / DI_ALLOW_PORTS 等
sudo docker-install                  # 向导：安装 → 检测 → 加固 → 暴露策略 → 用户组 → 权限检查
```

## 为什么需要加固

Docker 发布端口（`-p 8080:80`）走 nat 表 DNAT，包在到达 ufw 的 INPUT/OUTPUT 之前就被转发
→ **ufw 的 allow 规则对容器端口完全无效**，端口直接暴露公网。唯一官方入口是
`DOCKER-USER` 链（Docker 规则之前执行）。

**加固委托上游开源项目** [chaifeng/ufw-docker](https://github.com/chaifeng/ufw-docker)
（社区标准方案，固定 tag 版本 + 安装前 sha256 校验，防篡改/防 tag 漂移）。
本工具只负责：安装 Docker / 状态判定（读内核）/ 非暴露模式 / 非 root 权限体检。

## 用法

```bash
docker-install                       向导（安装→加固→暴露策略→用户组→权限检查）
docker-install install               安装/升级 Docker Engine（apt 官方源/dnf/apk）
docker-install firewall status       检测是否绕过 UFW + 列出公网可达端口（只读）
docker-install firewall fix          加固: ufw-docker install 接管 DOCKER-USER（幂等）
docker-install firewall lockdown     非暴露模式（推荐）: 撤销所有转发放行，
                                     容器端口仅服务器本地可访问（内核+配置双复核）
docker-install firewall allow <容器名> [端口[/tcp|udp]] [网络]
                                     放行公网访问该容器端口（按容器绑定 IP）
docker-install firewall deny <容器名> [端口[/tcp|udp]] [网络]
                                     撤销放行（ufw-docker delete allow）
docker-install firewall uninstall    移除规则块（ufw-docker uninstall + 清内核残留）
docker-install user [用户名]         将用户加入 docker 组（默认取 sudo 调用者）
docker-install perms check           检查非 root 读写权限（只读，默认动作）
docker-install perms fix <路径> [用户]  修正指定路径属主（必须显式指定路径）
docker-install status                汇总: 版本/服务/后端/加固状态/组成员/权限
docker-install -v, --version         显示版本号
docker-install -h, --help            显示本帮助
```

## 推荐姿势（生产实践）

容器一律 `-p 127.0.0.1:8080:80` 只绑本机，对外统一走 Nginx 反代只开 443；
配合 `firewall lockdown` 确保**零放行** —— 公网完全不可达容器端口。

```bash
sudo docker-install firewall status     # 先看是否绕过
sudo docker-install firewall fix        # 加固
sudo docker-install firewall lockdown   # 非暴露模式（推荐）
```

此时**不要**用 `firewall allow`。`allow` 的端口是**容器内部端口**（不是 `-p` 的宿主端口），
且**按容器绑定**——容器重建换 IP 后需重新 allow（上游语义，不是 bug）。

## 配置（`/etc/docker-install.env`）

| 键 | 说明 |
|---|---|
| `DI_DOCKER_USER` | 加入 docker 组的用户（留空 = 向导询问 / 取 sudo 调用者） |
| `DI_ALLOW_PORTS` | 向导中自动放行的容器端口（逗号分隔，**容器内部端口**） |
| `DI_DOCKER_CIDRS` | 允许互访的容器私网 CIDR（空格分隔）；留空 = 自动探测 |
| `DI_SCAN_DIRS` | `perms check` 扫描属主漂移的 bind mount 目录，默认 `/srv/docker /opt/docker` |
| `DI_YES` | `1` = 跳过所有确认（自动化） |
| `DI_UFWDOCKER_VERSION` / `DI_UFWDOCKER_SHA256` | 上游固定版本与校验值（默认即可，一般无需改） |

## 安全告警：docker 组 = root

docker 组成员等价于 root 权限（可 `docker run -v /:/host` 读写宿主任意文件）。
仅用于单用户/可信机器；多人机器建议 rootless 模式。

## 已知坑

- **上游要求 `systemctl restart ufw`（不是 reload）** 才装载 after.rules ——
  install 后若 `DOCKER-USER` 链为空，先 restart 再复查
- **`firewall lockdown` 必须改 `/etc/ufw/user.rules`（走 `ufw route delete`）**，
  只 `iptables -F` 清内核链的话，下次 `ufw reload`/重启放行会**原地复活**
- **加固与 lockdown 都存活重启**（`after.rules` 是磁盘持久配置），但 `allow` 放行
  **会「规则存活却静默失效」**：上游按容器 IP 绑定，容器重建/IP 漂移后规则还在但端口不通。
  对 lockdown 无害（放行失效 = 更安全），对 allow 是坑
- **root 直接登录（非 sudo）跑向导时第 4 步会等待输入**：`SUDO_USER` 为空时落到 `read_input`。
  显式指定即可：`sudo docker-install user admin`，或设 `DI_DOCKER_USER=admin`
- **验证「端口是否对公网开放」不能从目标机自身发起**：本机 curl 自己的公网 IP 走 `lo`/`OUTPUT`，
  不经过 FORWARD（DOCKER-USER 挂在那里）→ 加固前后都 200，假阳性。必须从独立外部主机测
- `/var/lib/docker` 官方权限是 `0710` 不是 `0700`（检查脚本写死 0700 会误报）
