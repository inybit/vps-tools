# xray-deploy

[← 返回仓库根](../../README.md)

Xray 一键部署 / 管理：多协议注册表、回落域名双方向检测、中转+落地链式代理与分流、
生成 mihomo / sing-box 客户端节点片段。

| | |
|---|---|
| 域 | `proxy/` |
| 版本 | `1.9.1` |
| 结构 | 多文件（入口 + 26 lib） |
| 依赖 | curl, unzip, jq, openssl |
| 配置 | `/etc/xray-deploy/state.json`（600，**含私钥**） |
| 服务 | systemd / OpenRC |

## 安装

```bash
curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh | sudo bash -s -- install xray-deploy
```

> **安装器不会自动执行任何工具命令**（不自动跑 `install` 向导）。安装完成后自行：

```bash
sudo xray-deploy          # 交互菜单 → 选 1 首次部署
xray-deploy info          # 查看节点信息与客户端片段
```

## 用法

```bash
xray-deploy                      交互式管理菜单
sudo xray-deploy install         首次部署向导（选协议 → 参数 → 服务；默认 VLESS-TCP-XTLS-Vision-REALITY）
xray-deploy info                 查看节点信息（明文 + 客户端配置片段，无需 root）
xray-deploy config show|edit     查看/编辑服务端配置（edit 后自动 xray -test 校验并重载）
xray-deploy fallback-test [域名]      测试回落域名握手延迟并排序（无参=全部候选）
xray-deploy fallback-cn-test [域名]   回落域名中国方向可达性检测（Globalping 探针）
sudo xray-deploy update-geo      更新 geosite/geoip（或自行配 systemd timer）
sudo xray-deploy upgrade         升级 Xray 二进制（失败自动回滚）
sudo xray-deploy status|restart|uninstall
sudo xray-deploy protocol add|remove|edit|list   多协议管理
xray-deploy chain show|setup|import|export|test|remove   中转 + 落地（链式代理）管理
xray-deploy -v, --version        显示版本号
xray-deploy -h, --help           显示本帮助
```

## 协议支持

| 类型 | 说明 | 证书 | 备注 |
|---|---|---|---|
| `vless-reality`（默认） | VLESS-TCP-XTLS-Vision-REALITY | 无需 | 成熟稳定，TCP 性能好 |
| `vless-xhttp-reality` | VLESS-XHTTP-REALITY（含 XMUX） | 无需 | 抗封锁更强；**仅 mihomo 系客户端**（sing-box 上游无 XHTTP） |
| `vless-xhttp` | VLESS-XHTTP-H2-TLS | 需域名解析到本机 | 真实证书，兼容性最广（旧名 `vless-h2` 兼容） |
| `vless-xhttp3-nginx` | VLESS-XHTTP3-NGINX（HTTP/3 QUIC → nginx → UDS → xray） | **由 nginx 持有** | 需先装 nginx ≥1.25.0（含 `--with-http_v3_module`）；xray 只监听 Unix socket |
| `hysteria2` | Hysteria2（QUIC/UDP） | 需域名（自签亦可） | 弱网/高丢包环境优势 |
| `ss2022` | Shadowsocks 2022 | 无需 | ⚠️ **仅用于中转→落地一跳**，不要用于出境段 |

> **命名提醒**：`h2` 有歧义（HTTP/2？Hysteria2？），故统一为 `vless-xhttp`；Hysteria2 简称 `hy2`。

## 部署流程

1. `sudo xray-deploy` → 选 1 安装：选协议 → 端口（默认 443）→ 回落域名
   （自动测试 + 按握手延迟排序，也可输自有域名）
2. `xray-deploy info` 查看生成结果，把 mihomo / sing-box 片段填入客户端
3. 节点信息持久化在 `/etc/xray-deploy/state.json`（600，含私钥，**勿外泄**）

## 回落域名：两个方向都要测

| 命令 | 视角 | 测什么 |
|---|---|---|
| `fallback-test` | VPS 本地 | TLS1.3 + H2 + X25519 + 非跳转 + 非 Cloudflare，并测握手延迟排序 |
| `fallback-cn-test` | Globalping 中国三网探针 | **中国方向可达性**（SNI/TLS 层阻断，ICMP 通不代表 HTTPS 通） |

二者互补——VPS 侧握手快但中国方向被 SNI 阻断的域名，国内用户照样连不上。
回落候选表按地区维护（每地区 ≥10 条），选型机制：**tier 升序排序 → 逐个实测 → 只收前 6 个**，
展示与默认选择按握手延迟升序。

> **数据出境确认（`fallback-cn-test` 专属）**：Globalping 是第三方公共 API，待测域名会被提交出境
> 并留存在其**公开测量记录**中（提交内容仅域名 + 请求类型，不含服务器 IP / 密钥 / 节点信息）。
> 因此该命令**提交前强制确认，默认拒绝**——无交互终端时同样拒绝，不会静默发出任何数据。
> 自动化场景用 `CN_TEST_ASSUME_YES=1` 显式放行：
> ```bash
> sudo xray-deploy fallback-cn-test                      # 交互：先打印出境提示，输 y 才提交
> CN_TEST_ASSUME_YES=1 sudo xray-deploy fallback-cn-test www.example.com   # 自动化显式放行
> ```

## 中转 + 落地（链式代理）

架构：`客户端 ──[REALITY]──→ 中转机 ──[SS2022]──→ 落地机 ──→ 目标`

```bash
# 落地机
sudo xray-deploy protocol add          # 选 ss2022
xray-deploy chain export               # 导出落地参数 JSON

# 中转机
xray-deploy chain import               # 粘贴落地机 export 的 JSON
xray-deploy chain setup                # 或手工输入落地参数
xray-deploy chain show                 # 查看拓扑与出口路径
xray-deploy chain test                 # 配置层自检，不发起跨境连接
xray-deploy chain remove               # 拆链路回单机
```

**客户端零改动** —— 仍使用中转机的 REALITY 参数。

> 出境段必须 REALITY（SS2022 无 TLS 外观，跨境会被风控）；SS2022 只承担「境外↔境外」一跳。

### 分流模式（哪些流量走落地机）

```bash
sudo xray-deploy chain mode list              查看全部模式
sudo xray-deploy chain mode all               全部走落地（默认）
sudo xray-deploy chain mode ai                AI 类走落地（category-ai-!cn + openai）
sudo xray-deploy chain mode google            Google 走落地
sudo xray-deploy chain mode youtube           YouTube 走落地
sudo xray-deploy chain mode ai-google-youtube AI + Google + YouTube 走落地
sudo xray-deploy chain mode none              全部直出（不用落地）
sudo xray-deploy chain mode custom:geosite:netflix,geosite:spotify
xray-deploy chain mode                        查看当前模式（只读，无需 root）
```

- **mode 只控制「走落地 vs 中转直出」**；安全底线 block 规则（广告 / BT / 私网 / 国内 cn）
  **永远保留**，任何 mode 下都不丢
- mode 存在 `state.json`（声明式）——切换 = `state_set` + rebuild。
  ⚠️ **不要手工编辑 `config.json` 的规则**，下次 rebuild 会覆盖
- 未知 mode 回退 `all` 并告警（fail-safe 到「走落地」而非静默直出）
- ⚠️ 新增 geosite 标签前须验证存在：`curl raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/<tag>.yaml`

## 客户端兼容性硬约束

- **mihomo 连 Xray ≥ 26.9.8 的 REALITY 必须显式 `support-x25519mlkem768: true`**：
  mihomo 默认从 ClientHello 剥离 X25519MLKEM768，Xray 对不带该扩展的握手直接拒绝
  （症状：`REALITY authentication failed`、服务端 `accepted=0`）。本工具生成的 mihomo 片段
  已自动包含该字段，**勿手工删除**。sing-box 不受影响。
- **sing-box 上游不支持 XHTTP**（需 extended / lx fork）；`vless-xhttp-reality` 只支持 mihomo 系。
- `vless-xhttp` 的 mihomo 客户端需 v1.19.23+。

## 已知坑（部署前必读）

- **整机只留一个 REALITY inbound 占 443**。两个 REALITY inbound 监听同端口时内核按
  `SO_REUSEPORT` 随机分发、SNI 不参与分流 → 实测 30% 串台
  （`REALITY: received real certificate (potential MITM or redirection)`）。
  且 `xray -test` 不绑定端口，**同端口冲突在 `-test` 阶段静默通过**，只有 `run` 才暴露。
- **hy2 的 auth 位置与 outbound 相反**：inbound 在 `settings.clients[].auth`，
  outbound 在 `hysteriaSettings.auth`（写错 `xray -test` 通过但 QUIC 握手失败）。
- **BRUTAL 带宽必须带单位**：`brutalUp: "60"` 被按 B/s 解析 → 低于 64KB/s 下限报错。
  向导对纯数字自动补 ` mbps`。
- **验证连通性必须分层**：回环（127.0.0.1）通 ≠ 外部通（ufw 默认 deny incoming），
  必须从外部主机起客户端连公网 IP 实测。
- **链式功能的验证判据比单机多一条**：客户端 HTTP 200 **不足以**证明走了两跳，
  必须同时看**落地机服务端 `accepted` 计数 > 0** 并做反事实对照（摘掉 landing 后必须失败）。
- **升级/版本查询**：`api.github.com/.../releases/latest` 会漏掉 prerelease，
  而 Xray 从 v26.3.23 起所有 release 都标 prerelease → 该端点恒返回旧版。
  工具已改用 `/releases?per_page=5` + 语义化版本比较（含防降级）。
- **配置原子替换**：`config.json.tmp` + `xray -test` 校验通过才 `mv` 生效，
  校验失败保留线上配置。

### vless-xhttp3-nginx 专属

- **必须先装 nginx（≥1.25.0 且含 `--with-http_v3_module`）**：向导首步检测，
  未安装则直接退出且**不写 state.json**（零副作用），不代为安装。
- **xray 不监听任何端口**，只监听 `/run/xray-deploy/<name>.socket`（0666）。
  `port` 字段语义是 **nginx 的对外端口**，不是 xray 监听端口。
- **Xray 不自动创建 socket 所在目录**：`-test` 会静默通过，运行时才报
  `failed to listen Unix Domain Socket`。目录由 systemd `RuntimeDirectory`
  （systemd）或 `start_pre`（OpenRC）预建。
- **SIGKILL 残留 socket 会导致重启必失败**（`bind: address already in use`，
  实测 3/3）。SIGTERM 会自动清理。故 socket 落 `/run/xray-deploy/` +
  `RuntimeDirectory`（systemd 在进程被 SIGKILL 后仍会清理该目录）。
- **两个 inbound 用同一 UDS 路径时 `xray -test` 静默通过**，运行时第二个被吞
  （实测 `/p1` 可达、`/p2` 404）→ 向导主动检查路径唯一性。
- **端口与既有协议互斥**：nginx 需独占 TCP（TLS/H2）与 UDP（QUIC）两侧，
  向导会检查既有 reality / xhttp / ss2022 / hy2 是否占用。
- **`location` 必须带尾斜杠**：`mode: stream-one` 下客户端请求的是 `<path>/`
  （`splithttp/config.go` 的 `GetNormalizedPath()`），`info` 打印的参考已按此生成。
- **TLS 证书由 nginx 持有**，本工具不管理证书；`info` 打印的证书路径是占位符。

## 文件结构

```
proxy/xray-deploy/
├── xray-deploy.sh          # 入口：菜单 + 子命令分发
└── lib/                    # 26 模块
    ├── common.sh service.sh state.sh xray-bin.sh keys.sh registry.sh
    ├── fallback-data.sh fallback.sh globalping.sh
    ├── inbound.sh outbound.sh routing.sh chain.sh chain-info.sh ss2022.sh
    ├── proto-wizard.sh xhttp3.sh proto-crud.sh proto-edit.sh
    ├── client-mihomo.sh client-singbox.sh client-ss2022.sh
    └── cmd-lifecycle.sh cmd-info.sh cmd-fallback.sh usage.sh
```

## 回归测试

```bash
bash tests/run-all.sh xray      # 全部 xray 相关套件
```

| 套件 | 说明 |
|---|---|
| `verify-xray-deploy-routing.sh` | 分流规则（56 断言，含 geosite 标签实测） |
| `verify-xray-deploy-xhttp3-nginx.sh` | vless-xhttp3-nginx（67 断言：触点/nginx 门/冲突/unit/info，含真实 xray -test） |
| `verify-xray-deploy-chain.sh` | 链式代理（46 断言） |
| `verify-xray-deploy-latest.sh` | 版本查询 / 升级防降级 |
| `verify-xray-deploy-behavior.sh` | 行为契约 |
| `verify-xray-deploy-e2e.sh` | 端到端（需真实环境） |
| `verify-xray-deploy-mode-e2e.sh` | 分流模式端到端（真实 xray 决策日志） |
| `verify-xray-deploy-split.sh` | 拆分等价性（函数体逐字对比基线） |
