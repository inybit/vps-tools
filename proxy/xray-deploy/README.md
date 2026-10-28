# xray-deploy

[← 返回仓库根](../../README.md)

Xray 一键部署 / 管理：多协议注册表、回落域名双方向检测、中转+落地链式代理与分流、
生成 mihomo / sing-box 客户端节点片段。

| | |
|---|---|
| 域 | `proxy/` |
| 版本 | `1.16.0` |
| 结构 | 多文件（入口 + 33 lib） |
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
sudo xray-deploy install         首次部署向导（选 Xray 版本 → 选协议 → 参数 → 服务；
                                   版本默认最新，可选最近 10 个版本之一）
xray-deploy info                 查看节点信息（明文 + 客户端配置片段，无需 root）
xray-deploy config show|edit     查看/编辑服务端配置（edit 后自动 xray -test 校验并重载）
xray-deploy fallback-test [域名]      测试回落域名握手延迟并排序（无参=全部候选）
xray-deploy fallback-cn-test [域名]   回落域名中国方向可达性检测（Globalping 探针）
sudo xray-deploy update-geo [--restart]  更新 geosite/geoip（原子替换，下载异常不覆盖线上文件）
sudo xray-deploy geo-timer install|status|remove   geo 数据每周自动更新（systemd timer）
sudo xray-deploy upgrade [版本]  不带参数=升级到最新（失败自动回滚，含防降级）；
                                   带版本=切换/回退到指定内核版本（允许降级）
                                   例: sudo xray-deploy upgrade v26.7.28
sudo xray-deploy status|restart|uninstall
sudo xray-deploy protocol add|remove|edit|list   多协议管理
xray-deploy chain show|setup|import|export|test|remove   中转 + 落地（链式代理）管理
xray-deploy -v, --version        显示版本号
xray-deploy -h, --help           显示本帮助
```

## Xray 版本选择（安装时）

安装向导第一步会列出**最近 10 个 Xray 版本**，回车 = 最新版（默认行为与旧版一致）：

```
可选 Xray 版本（新 → 旧）:
   1) v26.9.9 最新
   2) v26.9.8
   3) v26.7.28
   ...
  ⚠️ v26.9.8 起，REALITY 服务端要求客户端支持 X25519MLKEM768：
     · mihomo 1.19.30+  → 可用（片段已含 support-x25519mlkem768: true）
     · sing-box（含最新稳定版 1.14.1）→ ❌ 连不上，上游 issue #4520 未修
     → 客户端用 sing-box 请选 v26.7.28 或更早
选择版本 [1-10，回车默认 1（最新 v26.9.9）]:
```

- **为什么需要**：Xray `v26.9.8`（2026-09-08）起，REALITY 服务端要求客户端 ClientHello
  携带 `X25519MLKEM768`，否则静默回落。mihomo 已适配，**sing-box 截至 1.14.1 未适配**。
- **默认最新**：直接回车即可，不改变原有行为。
- **已装版本记录**在 `/etc/xray-deploy/state.json` 的 `xray_version` 字段，
  `xray-deploy info` 会显示（≥ v26.9.8 时带 ⚠️ 提示）。

## Xray 版本回退 / 切换（安装后）

装好之后想换内核版本，用 `upgrade` 的**显式版本参数**（2026-09-21 新增）：

```bash
sudo xray-deploy upgrade v26.7.28   # 切换到指定版本（允许降级）
sudo xray-deploy upgrade            # 不带参数 = 升到最新（原行为，含防降级）
```

- **两条路径语义不同，别混**：不带参数 = 「升级」，本地比远端新时仍会**跳过并告警**（防降级）；
  带参数 = 「切换/回退」，**不做防降级判断**——降级正是它的用途。
- **防打错字**：显式指定的版本必须在 GitHub 发布列表里，否则**拒绝下载**（避免手滑装了个
  不存在的 tag）；发布列表拿不到（离线/配额）时降级为提示，不阻断。
- **安全网照旧**：切换前备份旧二进制到 `xray.bak`，下载失败自动回滚；成功后同步
  `state.json.xray_version`，并按目标版本触发 MLKEM 客户端兼容告警。
- **典型场景**：客户端用 sing-box → 被 `upgrade` 拽到 ≥ v26.9.8 后客户端静默连不上，
  用 `sudo xray-deploy upgrade v26.7.28` 退回即可。

## 协议支持

| 类型 | 说明 | 证书 | 备注 |
|---|---|---|---|
| `vless-reality`（默认） | VLESS-TCP-XTLS-Vision-REALITY | 无需 | 成熟稳定，TCP 性能好 |
| `vless-xhttp-reality` | VLESS-XHTTP-REALITY（含 XMUX） | 无需 | 抗封锁更强；**仅 mihomo 系客户端**（sing-box 上游无 XHTTP） |
| `vless-xhttp` | VLESS-XHTTP-H2-TLS | 需域名解析到本机 | 真实证书，兼容性最广（旧名 `vless-h2` 兼容） |
| `vless-xhttp3-nginx` | VLESS-XHTTP3-NGINX（HTTP/3 QUIC → nginx → UDS → xray） | **由 nginx 持有** | 需先装 nginx ≥1.25.0（含 `--with-http_v3_module`）；xray 只监听 Unix socket |
| `hysteria2` | Hysteria2（QUIC/UDP） | 需域名（自签亦可） | 弱网/高丢包环境优势；自签证书用**指纹固定（pin）**，非 insecure |
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

### 候选范围：默认只测**本机所在地区**

回落域只需**贴近本机**（越近握手越快）；跨洲候选天然高延迟，没有选型价值。
候选表按地区维护（每地区 ≥10 条），因此 `fallback-test` **无参 = 本机所在国家（`ipinfo`/`ip-api` 自动识别）的全部候选**，
与部署向导 `select_fallback_domain` 同口径（共用 `fallback_region_candidates`，防止两处漂移）。

```bash
xray-deploy fallback-test              # 本地区全部候选（DE 机 = 12 条，约 6 分钟）
xray-deploy fallback-test --region JP  # 指定地区（跨地区排查/复核他机部署用）
xray-deploy fallback-test --all        # 全部 121 条 / 10 个地区（约半小时，谨慎）
xray-deploy fallback-test www.example.com   # 单个域名
```

> 候选表共 **121 条**（AU/CH/DE/FR/GB/HK/JP/SG/TH/US），单条实测约 30s（TLS 检测 + 3 次延迟采样）。
> 旧版无参即整表遍历（≈1 小时，其中 90% 是跨洲白等）——**已修正为默认本地区**。

部署向导侧的选型机制：**tier 升序排序 → 逐个实测 → 只收前 6 个**，展示与默认选择按握手延迟升序。

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

## WARP 回国出站（WireGuard，1.15.0+）

默认回国流量（`geosite:cn` + `geoip:cn`）走 `blackhole`。导入
[wgcf](https://github.com/ViRb3/wgcf) 生成的 `wgcf-profile.conf` 后，这两条规则的目标出站改为
`wireguard` 出站（tag `warp`）；广告 / BT / 私网三条 block 不动。

```bash
wgcf register && wgcf generate                 # 任意机器，得到 wgcf-profile.conf
sudo xray-deploy warp setup                    # 交互：读文件 或 直接粘贴（单独一行 EOF 结束）
sudo xray-deploy warp setup /root/wgcf-profile.conf
cat wgcf-profile.conf | sudo xray-deploy warp setup -
sudo xray-deploy warp setup /root/wgcf-profile.conf --ipv6 on   # 强制保留 IPv6
sudo xray-deploy warp show                     # 私钥打码（只露末 4 位）
sudo xray-deploy warp test [--net]             # 配置层自检；--net 临时探测真实出口
sudo xray-deploy warp remove                   # 回到 blackhole
sudo xray-deploy warp cleanup [--dry-run]      # 清理内核 TUN 残留（换 key 后用；见下）
```

profile → 出站字段映射：

| profile 行 | Xray settings | 说明 |
|---|---|---|
| `PrivateKey` | `secretKey` | 只存 `state.json`（600）；任何输出只露末 4 位 |
| `Address` | `address[]` | 缺 `/32`、`/128` 自动补 |
| `DNS` | `remoteDNS[]` | 隧道内目标**必须是 IP**，域名靠它解析 |
| `MTU` | `mtu` | 缺省 1280，限 576–1500 |
| `PublicKey` | `peers[0].publicKey` | |
| `AllowedIPs` | `peers[0].allowedIPs` | |
| `Endpoint` | `peers[0].endpoint` | |

- **内核 TUN 不写进配置**：省略 `noKernelTun` = Xray 自动检测（有 `CAP_NET_ADMIN` 用内核 TUN，
  否则进程内 gVisor）。Xray 文档明确警告自动检测在部分 LXC 上会误判（有权限却用不了 TUN，
  出站静默失败）→ 那时加 `--no-tun` 重新导入即可强制 gVisor。
  内核 TUN 占 IPv6 路由表 10230，同机第二个 wireguard 出站顺延 10231。
- `reserved`（部分 WARP 账号需要由 client_id 派生的 3 字节）不在 profile 里，
  需要时 `warp setup ... --reserved 1,2,3`。
- **IPv6 按本机能力自动裁剪（1.15.0+）**：`warp setup` 检测本机是否有公网 IPv6
  （`/proc/net/if_inet6` 里存在 `2000::/3` 全局单播地址）。**没有就剔除** `address` 的 v6 项、
  `allowedIPs` 的 `::/0`、`remoteDNS` 的 v6 DNS，并把结果记进 `state.json` 的 `.warp.ipv6`。
  原因：无 v6 的机器上内核 TUN 加 v6 地址/路由会失败，整个 wireguard 出站起不来。
  逃生门 `--ipv6 on`（强制保留，本机无 v6 时告警）/ `--ipv6 off`（强制剔除）；默认 `auto`。
  旧 state 无 `.warp.ipv6` 字段时按本机实时探测（自愈），`warp show` 会标「自动（老配置）」。
- **换 key 后必须清旧 key 的 v6 残留（1.16.0+ 自动做）**：Xray 内核 TUN 会在 IPv6 策略路由里
  加 `from <隧道 v6> lookup 10230` / `oif wg0 lookup 10230` 两条 rule + `::/0` 路由。正常退出会删，
  但 **`xray run -test` 走 `os.Exit` 不执行 `Close()`** —— 而每次 rebuild 都要跑 `-test`，
  于是每 rebuild 漏一对 rule，无限累积。后果：① 旧 key 的 v6 地址痕迹留在内核里；
  ② 换 key 时旧实例的 `wg0` 上还挂着旧 key 的 WARP v6（`2606:4700:…`），若按
  `/proc/net/if_inet6` 判「本机有公网 IPv6」就会误判 → 新出站保留 v6 → 无原生 v6 的机器上
  TUN 建不起来。现在：判定排除 `wg0/wg1…`；`rebuild_and_reload` / `warp remove` 自动清表
  10230–10240 的残留（更往上/`main`/`local`/自定义表一律不碰，宁可漏清不误删）。
- 多 `[Peer]` 直接报错，不猜。
- `warp` 与 `chain` 正交：分流模式照旧，回国流量始终先命中 warp 规则。

## geo 数据自动更新（每周，1.16.0+）

路由分流靠 `geosite:` / `geoip:` 标签，MetaCubeX 规则库每周更新；Xray **只在启动时**加载
geo 数据，所以「更新完必须重启」才生效。

```bash
sudo xray-deploy geo-timer install [OnCalendar]   # 默认 Mon *-*-* 01:00:00 + 随机抖动 ≤6h
sudo xray-deploy geo-timer status                 # is-active + 下次触发 + 上次运行结果
sudo xray-deploy geo-timer remove                 # 只删 timer，不动 geo 数据与服务
sudo xray-deploy update-geo [--restart]           # 手动更新；--restart = 校验通过才重启
```

- **首次部署自动装**（`install` 末尾），卸载时一并删除；unit 名是
  `xray-deploy-geo-update.service/.timer` —— **不能**叫 `xray-deploy.service`（那是主服务的）。
- **为什么 `OnCalendar` 还要随机抖动**：一批机器同一时刻打 GitHub 会撞限流，`RandomizedDelaySec=6h`
  把实际触发摊到 01:00–07:00；`Persistent=true` 保证关机错过会补跑。
- **原子替换 + 尺寸闸**：先下到 `<f>.new` → 校验 >1MB（挡错误页/半截文件）→ 备份 `.bak` → `mv`。
  下载失败或内容异常时**线上文件一个字节都不动**，命令非 0 退出（systemd 记 failed）。
- **`--restart` 的校验闸**：重启前跑 `xray -test`（带 `XRAY_LOCATION_ASSET`），失败就把 `.bak`
  换回去且**不重启** —— 否则每周定时任务会把坏 geo 数据变成「每周定时打挂服务」。
- OpenRC 机器只提示不支持（仓库约定：定时统一 systemd timer，不写 crontab/cron.weekly）。

## 客户端兼容性硬约束

- **Xray ≥ v26.9.8 的 REALITY 服务端要求客户端 ClientHello 携带 X25519MLKEM768**
  （`XTLS/REALITY` 提交 `8cdf7bf9c7f0`，实测落在 v26.9.8）。客户端兼容矩阵：

  | 客户端 | 结果 | 处置 |
  |---|---|---|
  | mihomo 1.19.30+ | ✅ 可用 | 需显式 `support-x25519mlkem768: true`（本工具生成的片段已含，**勿删**）。缺该字段症状：`REALITY authentication failed`、服务端 `accepted=0` |
  | sing-box（含最新稳定版 1.14.1） | ❌ **连不上** | **无任何客户端侧开关可解**；上游 [SagerNet/sing-box#4520](https://github.com/SagerNet/sing-box/issues/4520) 未修。症状 `reality verification failed`，服务端日志只有 `forwarded SNI:` 而无鉴权阶段 |

  → **客户端用 sing-box 的，安装时请选 `v26.7.28` 或更早版本**（向导会提示）。
- **sing-box 上游不支持 XHTTP**（需 extended / lx fork）；`vless-xhttp-reality` 只支持 mihomo 系。
- `vless-xhttp` 的 mihomo 客户端需 v1.19.23+。

## 已知坑（部署前必读）

- **`xray run -test` 会真建内核 TUN 却不清理**：它走 `os.Exit`，不执行 `kernelTun.Close()`，
  于是每次 `-test`（= 每次 rebuild）在 IPv6 策略路由里漏一对 rule，优先级递减、无限累积
  （实测单机 13 对）。本工具已在 `rebuild_and_reload` 里清理表 10230–10240；手工排查用
  `ip -6 rule show | grep -E 'lookup 1023[0-9]|lookup 10240'`，或 `xray-deploy warp cleanup --dry-run`。

- **整机只留一个 REALITY inbound 占 443**。两个 REALITY inbound 监听同端口时内核按
  `SO_REUSEPORT` 随机分发、SNI 不参与分流 → 实测 30% 串台
  （`REALITY: received real certificate (potential MITM or redirection)`）。
  且 `xray -test` 不绑定端口，**同端口冲突在 `-test` 阶段静默通过**，只有 `run` 才暴露。
- **hy2 的 auth 位置与 outbound 相反**：inbound 在 `settings.clients[].auth`，
  outbound 在 `hysteriaSettings.auth`（写错 `xray -test` 通过但 QUIC 握手失败）。
- **hy2 自签证书：客户端用证书指纹 pin，不要用 insecure**。自签时 `insecure` /
  `skip-cert-verify` 等于**不验证服务器证书**（任何伪造证书都能冒充）。本工具在自签证书下
  自动算指纹写进 `state.json`，生成的客户端片段只认该指纹。
  ⚠️ **pin 与 insecure 语义互斥**——三家客户端一旦设置 pin 就会自动关闭链校验，
  同时写 `insecure` 等于让 pin 白写（本工具生成的片段已保证二选一）：

  | 客户端 | 字段 | 哈希对象 | 编码 |
  |---|---|---|---|
  | mihomo | `fingerprint` | 整张叶子证书 DER | hex |
  | sing-box | `certificate_public_key_sha256` | 公钥 SPKI | base64（1.13.0+） |
  | hysteria 原生 | `pinSHA256` | 整张叶子证书 DER | hex |

  → 三家**哈希对象不同，不能互抄**。`xray-deploy info` 会同时打印两枚指纹。
  **重签证书后指纹必变**（pin 会拒连，这是 pin 的应有行为）→ 重跑
  `protocol edit` 选 2 会重算指纹，客户端片段需重新复制。
  升级前部署的旧 state 没有指纹字段 → 片段暂回退 `insecure` 并打印提示，
  重跑一次 `protocol edit` 选 2 即可切到 pin。
- **BRUTAL 带宽必须带单位**：`brutalUp: "60"` 被按 B/s 解析 → 低于 64KB/s 下限报错。
  向导对纯数字自动补 ` mbps`。
- **验证连通性必须分层**：回环（127.0.0.1）通 ≠ 外部通（ufw 默认 deny incoming），
  必须从外部主机起客户端连公网 IP 实测。
- **链式功能的验证判据比单机多一条**：客户端 HTTP 200 **不足以**证明走了两跳，
  必须同时看**落地机服务端 `accepted` 计数 > 0** 并做反事实对照（摘掉 landing 后必须失败）。
- **升级/版本查询**：`api.github.com/.../releases/latest` 会漏掉 prerelease，
  而 Xray 从 v26.3.23 起所有 release 都标 prerelease → 该端点恒返回旧版。
  工具已改用 `/releases?per_page=5` + 语义化版本比较（含防降级）。
- **配置原子替换**：`config.tmp.json` + `xray -test` 校验通过才 `mv` 生效，校验失败保留线上配置。
  ⚠️ 临时文件**必须保留 `.json` 扩展名**：Xray v26.10.21 起配置加载器只按扩展名判格式，
  `-format=json` 不再覆盖它 → 旧的 `config.json.tmp` 写法在该版本报
  `unsupported config file extension`，导致**任何 rebuild 都校验失败**
  （`protocol add/edit`、`chain mode`、`warp setup` 全部卡住）。
  实测：v26.9.9 通过、v26.10.21 失败（1.14.0 起已改为 `config.tmp.json`）。

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
└── lib/                    # 33 模块
    ├── common.sh service.sh state.sh xray-bin.sh keys.sh registry.sh
    ├── fallback-data.sh fallback.sh globalping.sh
    ├── inbound.sh outbound.sh routing.sh chain.sh chain-info.sh ss2022.sh
    ├── proto-wizard.sh xhttp3.sh proto-crud.sh proto-edit.sh
    ├── client-mihomo.sh client-singbox.sh client-ss2022.sh
    ├── geo-update.sh geo-timer.sh warp.sh warp-tun.sh warp-cmd.sh
    └── cmd-lifecycle.sh cmd-upgrade.sh cmd-info.sh cmd-fallback.sh usage.sh menu.sh
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
| `verify-xray-deploy-latest.sh` | 版本查询 / 升级防降级 / 显式版本回退（58 断言） |
| `verify-xray-deploy-behavior.sh` | 行为契约 |
| `verify-xray-deploy-e2e.sh` | 端到端（需真实环境） |
| `verify-xray-deploy-mode-e2e.sh` | 分流模式端到端（真实 xray 决策日志） |
| `verify-xray-deploy-split.sh` | 拆分等价性（函数体逐字对比基线） |
| `verify-xray-deploy-geo-timer.sh` | geo 每周自动更新（timer unit / systemctl 序列 / 原子替换与回滚，55 断言） |
