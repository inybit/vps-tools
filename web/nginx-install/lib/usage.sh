#!/usr/bin/env bash
# ============================================================
# nginx-install 模块：帮助文本（usage）
# ============================================================

usage() {
  cat <<EOF
nginx-install ${NI_VERSION} — nginx 官方源安装（stable / mainline）

用法:
  nginx-install                     向导: 检测 → 选通道 → 安装 → 启用 → 体检
  nginx-install install [通道]      安装/升级 nginx（通道: stable | mainline，默认 stable）
  nginx-install status              体检（只读）: 版本/官方源/服务/配置语法/监听端口/Docker 联动
  nginx-install -v, --version       显示版本号
  nginx-install -h, --help          显示本帮助

为什么用官方源而不是发行版仓库:
  发行版仓库的 nginx 版本普遍落后且不含官方模块包。本工具按 nginx.org 官方文档
  配置仓库，并强制校验签名密钥 —— 校验不过直接拒绝安装，不落盘、不装包。

安全契约:
  1. 签名密钥校验（fail-closed）
     - apt : 密钥环必须包含指纹 ${NI_FINGERPRINT}
     - apk : 公钥 DER 摘要必须等于 ${NI_ALPINE_KEY_DER_SHA256}
  2. apt 写入 Pin-Priority ${NI_PIN_PRIORITY}（否则发行版包优先级压过官方源）
  3. 幂等: 重复执行 = 覆盖更新；仓库文件内容不变则不重写

配置（/etc/nginx-install.env，可缺省）:
  NI_CHANNEL=stable    仓库通道（stable | mainline）
  NI_YES=0             1=跳过所有确认提示（自动化）

站点配置不在此工具范围:
  安装后手工编写 /etc/nginx/conf.d/<站点>.conf（官方源包的 conf.d 已被 http 块 include）。
  常用模板与要点见知识库:
    - 反代 + TLS + Cloudflare 源站证书 + 真实 IP 恢复
    - WebSocket 反代（Upgrade/Connection 头透传）
  生产姿势: 容器一律 -p 127.0.0.1:<端口> 只绑本机，对外统一由 nginx 反代只开 443。

示例:
  sudo nginx-install                      # 向导（交互）
  sudo nginx-install install              # 安装 stable
  sudo nginx-install install mainline     # 安装 mainline
  nginx-install status                    # 体检（无需 root）
EOF
}
