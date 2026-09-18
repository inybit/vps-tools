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
  sudo xray-deploy install         首次部署向导（选协议 → 参数 → 服务；默认 VLESS-TCP-XTLS-Vision-REALITY）
  xray-deploy info                 查看节点信息（明文 + 客户端配置片段）
  xray-deploy config show|edit     查看/编辑服务端配置（edit 后自动 -test 校验并重载）
  xray-deploy fallback-test [域名] 测试回落域名握手延迟并排序（无参=全部候选）
  xray-deploy fallback-cn-test [域名] 回落域名中国方向可达性检测（Globalping 探针；无参=全部候选）
                                   需要外网访问 api.globalping.io；只读检测，不改部署状态
                                   **提交前需确认数据出境**（默认拒绝；自动化用 CN_TEST_ASSUME_YES=1）
  sudo xray-deploy update-geo      更新 geosite/geoip（或自行配 systemd timer）
  sudo xray-deploy upgrade         升级 Xray 二进制（失败自动回滚）
  sudo xray-deploy status|restart|uninstall
  sudo xray-deploy protocol add|remove|edit|list   多协议管理（vless-reality / vless-xhttp-reality / vless-xhttp / hysteria2）
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
  hysteria2      Hysteria2 (hy2)（QUIC/UDP，官方默认端口 443 模拟 HTTP/3；自签证书+客户端 insecure，无需 CF token）
                 TCP/UDP 端口独立：与 REALITY 的 TCP 443 可共存；UDP 端口被占时向导会提示是否卸载冲突协议

客户端兼容性:
  mihomo 连 Xray >= 26.9.8 的 REALITY 必须显式 support-x25519mlkem768: true
  （mihomo 默认剥离 X25519MLKEM768，Xray 对不带该扩展的握手直接拒绝；
    症状 REALITY authentication failed / 服务端 accepted=0。sing-box 不受影响）
EOF
}
