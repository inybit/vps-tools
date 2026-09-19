# nginx-install

[← 返回仓库根](../../README.md)

按 [nginx.org 官方文档](https://nginx.org/en/linux_packages.html) 配置官方仓库并安装 nginx
（stable / mainline）。**签名密钥校验不过直接拒绝安装**（fail-closed，不落盘、不装包）。

| | |
|---|---|
| 域 | `web/` |
| 版本 | `1.0.1` |
| 结构 | 多文件（入口 + 6 lib） |
| 依赖 | curl, gnupg/openssl, apt/dnf/apk |
| 配置 | `/etc/nginx-install.env`（600，可缺省） |

## 安装

```bash
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- install nginx-install
```

## 用法

```bash
sudo nginx-install                  向导: 检测 → 选通道 → 安装 → 启用 → 体检
sudo nginx-install install          安装/升级 stable
sudo nginx-install install mainline 安装/升级 mainline
nginx-install status                体检（只读，无需 root）: 版本/官方源/服务/配置语法/监听端口/Docker 联动
nginx-install -v, --version         显示版本号
nginx-install -h, --help            显示本帮助
```

## 为什么用官方源

发行版仓库的 nginx 版本普遍落后，且不含官方模块包。本工具按 nginx.org 官方文档配置仓库，
并把「装的是官方包」做成可验证的契约（见下）。

## 安全契约（三条）

1. **签名密钥校验 fail-closed**
   - apt：密钥环必须**包含**官方指纹 `573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62`
     （官方密钥文件含多把密钥，故用「包含」而非「等于」）
   - apk：公钥 DER 摘要必须等于 `03833138bf6288dcb545f7a154af24f5c63b94931fef6b078cd8061204a44327`
   - 校验不通过 → 报错退出，**密钥不落盘、包不安装**
2. **apt 写入 `Pin-Priority: 900`**（`/etc/apt/preferences.d/99nginx`）——
   不设的话发行版仓库的同名包优先级更高，官方源装了等于没装
3. **幂等** —— 重复执行 = 覆盖更新；仓库文件内容不变则不重写（不制造无谓 mtime 变化）

## 仓库路径（按发行版拼）

| 包管理器 | 路径 |
|---|---|
| apt | `https://nginx.org/packages[/mainline]/<ubuntu\|debian> <codename> nginx` |
| dnf/yum | `packages[/mainline]/<centos\|fedora\|amzn>/$releasever/$basearch/` |
| apk | `packages[/mainline]/alpine/v<X.Y>/main`，装包用 `apk add nginx@nginx` |

通道切换：apt 改仓库文件；dnf 用 `enabled=1/0` 表达（**不用** `config-manager --enable`）；
apk 换 URL。通道写入 `/etc/nginx-install.env` 的 `NI_CHANNEL`（留空 = 向导询问，回车默认 stable）。

官方支持矩阵（Debian 11/12/13、Ubuntu 22.04/24.04/26.04、Alpine 3.21-3.24、RHEL 8/9/10）
写入常量；不在列表内 → 警告 + 用户确认（不静默继续）。

## 配置（`/etc/nginx-install.env`）

| 键 | 说明 |
|---|---|
| `NI_CHANNEL` | 仓库通道：`stable`（默认，生产推荐）/ `mainline`（最新特性） |
| `NI_YES` | `1` = 跳过所有确认提示（CI 场景） |

## 站点配置不在本工具范围

安装后手工编写 `/etc/nginx/conf.d/<站点>.conf`（官方源包的 `conf.d` 已被 http 块 include）。
生产姿势与 docker-install 联动：容器一律 `-p 127.0.0.1:8080:80` 只绑本机 +
`docker-install firewall lockdown`，对外统一由 nginx 反代只开 443。
