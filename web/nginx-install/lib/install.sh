#!/usr/bin/env bash
# ============================================================
# nginx-install 模块：安装编排（apt / dnf / apk）
# 仓库配置在 repo.sh，密钥校验在 keys.sh；本模块只做流程编排。
# ============================================================

# ---------- 状态查询 ----------
nginx_installed() {
  # 双条件：仅有残留 stub 时 command -v 会误判「已安装」
  command -v nginx >/dev/null 2>&1 && nginx -v >/dev/null 2>&1
}

nginx_version() {
  nginx -v 2>&1 | sed 's/^nginx version: //' || echo "未安装"
}

# ---------- 各发行版安装 ----------
ni_install_apt() {
  install_pkgs ca-certificates update-ca-certificates || return 1
  install_pkgs curl || return 1
  install_pkgs gnupg2 gpg || return 1
  local id distro
  id="$(ni_os_id)"
  case "$id" in
    ubuntu) distro="ubuntu" ;;
    debian) distro="debian" ;;
    *)
      case "$(ni_os_like)" in
        *ubuntu*) distro="ubuntu" ;;
        *debian*) distro="debian" ;;
        *) log_err "不支持的 apt 发行版: ID=${id} ID_LIKE=$(ni_os_like)"; return 1 ;;
      esac ;;
  esac
  ni_setup_repo_apt "$distro" || return 1

  apt-get update -qq >/dev/null 2>&1 || log_warn "apt update 有警告（继续）"
  log_info "安装 nginx（官方源，${NI_CHANNEL}）..."
  apt-get install -y -qq nginx >/dev/null 2>&1 \
    || { log_err "安装失败，请手动检查: apt-get install nginx"; return 1; }
  return 0
}

ni_install_dnf() {
  local mgr id pkgpath base mainline
  mgr="$(detect_pkg_mgr)"
  install_pkgs curl || return 1
  install_pkgs gnupg2 gpg || return 1
  id="$(ni_os_id)"
  case "$id" in
    fedora)  pkgpath="fedora/\$releasever/\$basearch" ;;
    amzn)    pkgpath="amzn/2023/\$basearch" ;;
    rhel|centos|rocky|almalinux|ol)
             pkgpath="centos/\$releasever/\$basearch" ;;
    *)       pkgpath="centos/\$releasever/\$basearch"
             log_warn "未知 RHEL 系发行版 ID=${id}，按 centos 路径处理" ;;
  esac
  # 注意：\$releasever/\$basearch 必须是字面量（由 yum 展开），不能让 shell 展开
  base="https://nginx.org/packages/${pkgpath}/"
  mainline="https://nginx.org/packages/mainline/${pkgpath}/"
  ni_setup_repo_dnf "$base" "$mainline" || return 1
  log_info "安装 nginx（官方源，${NI_CHANNEL}）..."
  $mgr install -y nginx >/dev/null 2>&1 || { log_err "安装失败（$mgr install nginx）"; return 1; }
  return 0
}

ni_install_apk() {
  install_pkgs openssl || return 1
  install_pkgs curl || return 1
  ni_setup_repo_apk || return 1
  log_info "安装 nginx@nginx（官方源，${NI_CHANNEL}）..."
  apk add --no-cache 'nginx@nginx' >/dev/null 2>&1 \
    || { log_err "安装失败: apk add nginx@nginx"; return 1; }
  return 0
}

# ---------- 服务启用 + 开机自启 ----------
nginx_enable_start() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now nginx >/dev/null 2>&1 || true
    if systemctl is-active --quiet nginx; then
      log_ok "nginx.service 运行中（已开机自启）"
    else
      log_warn "nginx.service 未运行，检查: systemctl status nginx"
    fi
    return 0
  fi
  if command -v rc-service >/dev/null 2>&1; then
    rc-update add nginx default >/dev/null 2>&1 || true
    rc-service nginx start >/dev/null 2>&1 || true
    log_ok "nginx 已启动（openrc）"
    return 0
  fi
  log_warn "未识别 init 系统，请手动启动 nginx"
  return 0
}

# ---------- 主流程 ----------
nginx_install_main() {
  require_root
  local mgr; mgr="$(detect_pkg_mgr)"
  [[ -n "$mgr" ]] || { log_err "未识别包管理器"; return 1; }

  if nginx_installed; then
    log_info "nginx 已安装: $(nginx_version)"
    if ! confirm "是否升级/重装 nginx（走官方源）?"; then
      nginx_enable_start
      return 0
    fi
  fi

  case "$mgr" in
    apt-get) ni_install_apt || return 1 ;;
    dnf|yum) ni_install_dnf || return 1 ;;
    apk)     ni_install_apk || return 1 ;;
    *)       log_err "不支持的包管理器: $mgr"; return 1 ;;
  esac

  nginx_enable_start
  nginx_installed || { log_err "安装后复查失败: nginx 命令不可用"; return 1; }
  log_ok "nginx 安装完成: $(nginx_version)"

  # 与 docker-install 的生产姿势联动提示
  if command -v docker >/dev/null 2>&1; then
    echo "" >&2
    log_info "检测到 Docker：推荐容器一律 -p 127.0.0.1:<端口> 只绑本机，"
    log_info "对外统一由 nginx 反代并只开 443；容器侧用 docker-install firewall lockdown。"
  fi
  return 0
}
