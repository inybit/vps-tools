#!/usr/bin/env bash
# ============================================================
# docker-install 模块：帮助文本（usage）
# ============================================================

usage() {
  cat <<EOF
docker-install ${DI_VERSION} — Docker 安装 + Docker×UFW 共存加固 + 非 root 管理

用法:
  docker-install                     向导（安装→加固→放行→用户组→权限检查）
  docker-install install             安装/升级 Docker Engine（apt 官方源/dnf/apk）
  docker-install firewall status     检测是否绕过 UFW + 列出公网可达端口（只读）
  docker-install firewall fix        加固: 把 DOCKER-USER 交给 ufw 管控（幂等）
  docker-install firewall allow <端口>[/tcp|udp] [容器IP]
                                     放行公网访问容器端口（封装 ufw route allow）
  docker-install firewall deny <端口>[/tcp|udp] [容器IP]
                                     撤销放行
  docker-install firewall uninstall  移除规则块（还原为 Docker 直连状态）
  docker-install user [用户名]       将用户加入 docker 组（默认取 sudo 调用者）
  docker-install perms check         检查非 root 读写权限（只读，默认动作）
  docker-install perms fix <路径> [用户]
                                     修正指定路径属主（必须显式指定路径）
  docker-install status              汇总: 版本/服务/后端/加固状态/组成员/权限
  docker-install -v, --version       显示版本号
  docker-install -h, --help          显示本帮助

为什么需要加固:
  Docker 通过 nat 表 DNAT 转发已发布端口，包在到达 ufw 的 INPUT/OUTPUT 链
  之前就被处理 → ufw 的 allow 规则对容器端口无效，端口直接暴露公网。
  唯一官方入口是 DOCKER-USER 链（Docker 规则之前执行）。

非 root 管理（docker 组）安全告警:
  docker 组成员等价于 root 权限（可 docker run -v /:/host 读写宿主任意文件）。
  仅用于单用户/可信机器；多人机器建议 rootless 模式。

加固后如何放行:
  ufw route allow proto tcp from any to any port <容器端口>   ← firewall allow 的封装
  注意: 匹配的是【容器内部端口】，不是 -p 的宿主映射端口。

配置（/etc/docker-install.env，可缺省）:
  DI_DOCKER_USER=admin            加入 docker 组的用户
  DI_ALLOW_PORTS=80,443           初始放行的容器端口
  DI_DOCKER_CIDRS=172.17.0.0/16   允许互访的容器私网（空=自动探测）
  DI_SCAN_DIRS=/srv/docker        权限检查扫描的 bind mount 目录
  DI_YES=1                        跳过所有确认（自动化）

示例:
  sudo docker-install                      # 新机器一键（交互）
  sudo docker-install firewall status      # 先看是否绕过
  sudo docker-install firewall fix         # 加固
  sudo docker-install firewall allow 8080  # 放行容器 8080
  sudo docker-install user admin           # admin 可用 docker
  sudo docker-install perms check          # 检查读写权限
EOF
}
