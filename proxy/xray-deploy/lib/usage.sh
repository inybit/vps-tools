#!/usr/bin/env bash
# usage.sh — 帮助文本（usage() 函数）
#
# 帮助正文放函数里而非外部 .txt：正文含 ${VERSION}，需 heredoc 运行时展开，
# 直接 cat 文件会把 ${VERSION} 当字面量输出。
usage() {
  cat <<EOF
xray-deploy ${VERSION} — Xray 一键部署/管理（vps-tools 生态）

用法:
  xray-deploy                      交互式管理菜单
  sudo xray-deploy install         首次部署向导（选 Xray 版本 → 选协议 → 参数 → 服务；
                                   版本默认最新，可选最近 10 个版本之一）
  xray-deploy info                 查看节点信息（明文 + 客户端配置片段）
  xray-deploy config show|edit     查看/编辑服务端配置（edit 后自动 -test 校验并重载）
  xray-deploy fallback-test [域名] 测试回落域名握手延迟并排序（无参=全部候选）
  xray-deploy fallback-cn-test [域名] 回落域名中国方向可达性检测（Globalping 探针；无参=全部候选）
                                   需要外网访问 api.globalping.io；只读检测，不改部署状态
                                   **提交前需确认数据出境**（默认拒绝；自动化用 CN_TEST_ASSUME_YES=1）
  sudo xray-deploy update-geo      更新 geosite/geoip（或自行配 systemd timer）
  sudo xray-deploy upgrade [版本]   不带参数=升级到最新（失败自动回滚，含防降级）；
                                   带版本=切换/回退到指定内核版本，允许降级
                                   例: sudo xray-deploy upgrade v26.7.28
  sudo xray-deploy status|restart|uninstall
  sudo xray-deploy protocol add|remove|edit|list   多协议管理（vless-reality / vless-xhttp-reality / vless-xhttp / vless-xhttp3-nginx / hysteria2 / ss2022）
  xray-deploy chain show|setup|import|export|test|remove
                                   中转 + 落地（链式代理）管理
  xray-deploy -v, --version        显示版本号
  xray-deploy -h, --help           显示本帮助

协议说明:
  vless-reality  VLESS-TCP-XTLS-Vision-REALITY（默认，无需证书，回落伪装）
  vless-xhttp-reality
                 VLESS-XHTTP-REALITY（XHTTP + REALITY + XMUX；无需证书，回落伪装）
                 相对 vless-reality 的优势：XHTTP 走 HTTP 语义（REALITY 下 mode=auto → stream-one），
                 配合 XMUX 多路复用降低连接数；适合 REALITY 下需要更好抗封锁/复用场景
                 约束：① 同端口不可再放第二个 REALITY inbound（SO_REUSEPORT 随机分发，实测 30% 串台）
                       ② mihomo 客户端必须带 support-x25519mlkem768: true（脚本生成的片段已含）
  vless-xhttp    VLESS-XHTTP-H2-TLS（真实证书落地，域名需解析到本机；证书可已有路径/acme.sh 自动签发/自签）
                 Xray 26.x 起 h2 transport 迁移至 XHTTP stream-up（HTTP/2）；mihomo 需 v1.19.23+，sing-box 需 extended/lx fork
                 （旧名 vless-h2 兼容，1.3.0 起统一为 vless-xhttp）
  vless-xhttp3-nginx
                 VLESS-XHTTP3-NGINX（HTTP/3 QUIC → nginx → h2c/gRPC over UDS → xray）
                 ⚠️ 需【先装好 nginx】≥1.25.0 且含 --with-http_v3_module（未装则向导直接退出，不代为安装）
                 xray 只监听 Unix socket（/run/xray-deploy/<name>.socket），不监听任何端口
                 TLS/QUIC 与证书全部由 nginx 终结（本工具不管理证书）；端口由 nginx 独占
                 nginx 配置由用户自行编写 —— `info` 会打印一份只读参考（含可粘贴的 grpc_pass 行）
                 客户端：mihomo 需 v1.19.23+（alpn: [h3]）；sing-box 上游不支持 XHTTP
  hysteria2      Hysteria2 (hy2)（QUIC/UDP，官方默认端口 443 模拟 HTTP/3；自签证书+客户端 insecure，无需 CF token）
                 TCP/UDP 端口独立：与 REALITY 的 TCP 443 可共存；UDP 端口被占时向导会提示是否卸载冲突协议
  ss2022         SS2022 (shadowsocks 2022)（TCP+UDP，2022-blake3-aes-256-gcm 等）
                 ⚠️ 定位=【中转机 → 落地机】一跳（境外↔境外）。**不要用于出境段**
                    （SS2022 无 TLS 外观，主动探测特征明显，跨境会被风控；出境请用 REALITY）
                 用于 xray-deploy chain 链路；密钥 32 字节 base64（openssl rand -base64 32）

中转 + 落地（链式代理）:
  架构:  客户端 ──[REALITY]──→ 中转机 ──[SS2022]──→ 落地机 ──→ 目标
  落地机: sudo xray-deploy protocol add（选 ss2022）→ xray-deploy chain export
  中转机: xray-deploy chain import   （粘贴落地机 export 的 JSON）
          xray-deploy chain setup    （或手工输入落地参数）
          xray-deploy chain show     （查看拓扑与出口路径）
          xray-deploy chain test     （配置层自检，不发起跨境连接）
          xray-deploy chain remove   （拆链路回单机）
  客户端: 零改动 —— 仍使用中转机的 REALITY 参数

分流模式（哪些流量走落地机；安全底线 block 规则不受影响）:
  sudo xray-deploy chain mode list              查看全部模式
  sudo xray-deploy chain mode all               全部走落地（默认）
  sudo xray-deploy chain mode ai                AI 类走落地（category-ai-!cn + openai）
  sudo xray-deploy chain mode google            Google 走落地
  sudo xray-deploy chain mode youtube           YouTube 走落地
  sudo xray-deploy chain mode ai-google-youtube AI + Google + YouTube 走落地
  sudo xray-deploy chain mode none              全部直出（不用落地）
  sudo xray-deploy chain mode custom:geosite:netflix,geosite:spotify
  xray-deploy chain mode                        查看当前模式
  ⚠️ 底线 block 永远保留：广告 / BT / 私网 / 国内站点（cn）
  ⚠️ 新增 geosite 标签前须 curl 验证存在（MetaCubeX geo/geosite/<tag>.yaml）

客户端兼容性:
  Xray >= v26.9.8 的 REALITY 服务端要求客户端 ClientHello 携带 X25519MLKEM768：
  · mihomo 1.19.30+  → 可用（脚本生成的片段已含 support-x25519mlkem768: true，勿删）
    症状（缺该字段时）：REALITY authentication failed / 服务端 accepted=0
  · sing-box（含最新稳定版 1.14.1）→ ❌ 连不上，且无任何客户端侧开关可解
    症状：reality verification failed（服务端日志只有 forwarded SNI，无鉴权阶段）
    上游 SagerNet/sing-box#4520 未修 → 客户端用 sing-box 请安装时选 v26.7.28 或更早
EOF
}
