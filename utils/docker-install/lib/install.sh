#!/usr/bin/env bash
# ============================================================
# docker-install 模块：Docker Engine 安装
# 官方源（apt/dnf）+ Alpine（apk）；幂等：已装则跳过或升级
# 参考: https://docs.docker.com/engine/install/  （Ubuntu/Debian/RHEL/Alpine）
# ============================================================

# 冲突包（发行版自带非官方 docker 包，必须移除）
DI_CONFLICT_PKGS="docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc"

docker_installed() {
  command -v docker >/dev/null 2>&1 && docker --version >/dev/null 2>&1
}

docker_version() {
  docker --version 2>/dev/null | sed 's/^Docker version //; s/,.*//' || echo "未安装"
}

# ---------- 发行版信息 ----------
di_os_id()   { sed -n 's/^ID=//p' /etc/os-release 2>/dev/null | tr -d '"'; }
di_os_like() { sed -n 's/^ID_LIKE=//p' /etc/os-release 2>/dev/null | tr -d '"'; }
di_codename() {
  local c
  c="$(sed -n 's/^UBUNTU_CODENAME=//p' /etc/os-release 2>/dev/null | tr -d '"')"
  [[ -z "$c" ]] && c="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release 2>/dev/null | tr -d '"')"
  echo "$c"
}

# ---------- apt 系：官方仓库 ----------
install_docker_apt() {
  local id codename distro
  id="$(di_os_id)"; codename="$(di_codename)"
  case "$id" in
    ubuntu) distro="ubuntu" ;;
    debian) distro="debian" ;;
    *)
      case "$(di_os_like)" in
        *ubuntu*) distro="ubuntu" ;;
        *debian*) distro="debian" ;;
        *) log_err "不支持的 apt 发行版: ID=${id} ID_LIKE=$(di_os_like)"; return 1 ;;
      esac ;;
  esac
  [[ -n "$codename" ]] || { log_err "无法确定发行版代号（VERSION_CODENAME）"; return 1; }
  log_info "发行版: ${distro} (${codename})"

  install_pkgs ca-certificates update-ca-certificates || return 1
  install_pkgs curl || return 1

  # 1. 移除冲突包（未安装则 apt 报 none，忽略）
  local present="" p
  for p in $DI_CONFLICT_PKGS; do
    if dpkg -s "$p" >/dev/null 2>&1; then present+=" $p"; fi
  done
  if [[ -n "$present" ]]; then
    log_warn "移除冲突包:${present}"
    # shellcheck disable=SC2086
    apt-get remove -y -qq $present >/dev/null 2>&1 || log_warn "部分冲突包移除失败（继续）"
  fi

  # 2. GPG key
  mkdir -p /etc/apt/keyrings
  if ! curl -fsSL --max-time 60 "https://download.docker.com/linux/${distro}/gpg" -o /etc/apt/keyrings/docker.asc; then
    log_err "下载 Docker GPG key 失败（网络？）"; return 1
  fi
  chmod a+r /etc/apt/keyrings/docker.asc

  # 3. 仓库（用经典 .list 格式，兼容老 apt；deb822 需 apt>=2.2）
  local arch repo_line
  arch="$(dpkg --print-architecture)"
  repo_line="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${distro} ${codename} stable"
  echo "$repo_line" > /etc/apt/sources.list.d/docker.list
  log_info "已配置仓库: /etc/apt/sources.list.d/docker.list"

  # 4. 安装
  apt-get update -qq >/dev/null 2>&1 || log_warn "apt update 有警告（继续）"
  log_info "安装 Docker Engine（docker-ce / cli / containerd / buildx / compose）..."
  if ! apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1; then
    log_err "Docker 安装失败，请手动检查: apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
    return 1
  fi
  return 0
}

# ---------- dnf/yum 系 ----------
install_docker_dnf() {
  local mgr; mgr="$(detect_pkg_mgr)"
  install_pkgs curl || return 1
  local repo_url="https://download.docker.com/linux/centos/docker-ce.repo"
  local id; id="$(di_os_id)"
  case "$id" in
    fedora) repo_url="https://download.docker.com/linux/fedora/docker-ce.repo" ;;
    rhel|centos|rocky|almalinux) repo_url="https://download.docker.com/linux/centos/docker-ce.repo" ;;
  esac
  log_info "添加仓库: ${repo_url}"
  $mgr config-manager --add-repo "$repo_url" >/dev/null 2>&1 || {
    log_err "添加仓库失败（$mgr config-manager 不可用？）"; return 1; }
  local present="" p
  for p in $DI_CONFLICT_PKGS; do
    rpm -q "$p" >/dev/null 2>&1 && present+=" $p"
  done
  [[ -n "$present" ]] && { log_warn "移除冲突包:${present}"; $mgr remove -y $present >/dev/null 2>&1 || true; }
  log_info "安装 Docker Engine..."
  $mgr install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 \
    || { log_err "Docker 安装失败"; return 1; }
  return 0
}

# ---------- Alpine ----------
install_docker_apk() {
  log_info "安装 Docker（apk: docker docker-cli docker-compose）..."
  apk add docker docker-cli docker-compose >/dev/null 2>&1 \
    || { log_err "apk add docker 失败（community 仓库是否启用？）"; return 1; }
  rc-update add docker default >/dev/null 2>&1 || true
  return 0
}

# ---------- daemon 启动 + 开机自启 ----------
docker_enable_start() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now containerd.service >/dev/null 2>&1 || log_warn "containerd 自启设置失败（继续）"
    systemctl enable --now docker.service >/dev/null 2>&1 || log_warn "docker 自启设置失败（继续）"
    if systemctl is-active --quiet docker.service; then
      log_ok "docker.service 运行中（已开机自启）"
      return 0
    fi
    log_err "docker.service 未运行，检查: systemctl status docker"
    return 1
  fi
  if command -v rc-service >/dev/null 2>&1; then
    rc-service docker start >/dev/null 2>&1 || { log_err "rc-service docker start 失败"; return 1; }
    log_ok "docker 服务已启动（openrc）"
    return 0
  fi
  log_warn "未识别 init 系统，请手动启动 docker"
  return 0
}

# ---------- 主流程 ----------
docker_install_main() {
  require_root
  local mgr; mgr="$(detect_pkg_mgr)"
  [[ -z "$mgr" ]] && { log_err "未识别包管理器"; return 1; }

  if docker_installed; then
    log_info "Docker 已安装: $(docker_version)"
    if confirm "是否升级/重装 Docker Engine?"; then
      log_info "重新执行安装流程（幂等覆盖）..."
    else
      docker_enable_start || true
      log_info "跳过安装。如需加固 UFW: ${0##*/} firewall fix"
      return 0
    fi
  fi

  case "$mgr" in
    apt-get) install_docker_apt || return 1 ;;
    dnf|yum) install_docker_dnf || return 1 ;;
    apk)     install_docker_apk || return 1 ;;
  esac

  docker_enable_start || return 1
  docker_installed || { log_err "安装后复查失败: docker 命令不可用"; return 1; }
  log_ok "Docker 安装完成: $(docker_version)"

  # 安装完立即提示加固（不自动改防火墙）
  echo "" >&2
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q 'Status: active'; then
    log_warn "检测到 UFW 已启用 —— Docker 发布端口会绕过 ufw！"
    log_warn "请执行加固: sudo ${0##*/} firewall fix"
  fi
  return 0
}
