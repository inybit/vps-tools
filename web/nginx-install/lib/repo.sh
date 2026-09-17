#!/usr/bin/env bash
# ============================================================
# nginx-install 模块：仓库配置（apt / dnf / apk）
# 依据: https://nginx.org/en/linux_packages.html （2026-09-18 核对）
#
# 全部走 keys.sh 的校验后落盘路径；本模块只负责「写仓库文件」。
# ============================================================

# 通道 → apt 套件基路径
ni_apt_suite() {  # $1=distro(ubuntu|debian)
  local base="https://nginx.org/packages"
  [[ "$NI_CHANNEL" == "mainline" ]] && base="${base}/mainline"
  echo "${base}/$1"
}

# 官方支持矩阵校验（不在列表内 → 需用户确认）
ni_check_codename_supported() {  # $1=distro $2=codename
  local supported="$NI_SUPPORTED_DEBIAN"
  [[ "$1" == "ubuntu" ]] && supported="$NI_SUPPORTED_UBUNTU"
  grep -qw "$2" <<< "$supported" && return 0
  log_warn "发行版代号 ${2} 不在官方支持列表（${supported// /, }）"
  confirm "仍要继续安装?" || { log_err "已取消"; return 1; }
  return 0
}

# ---------- apt（Debian / Ubuntu） ----------
ni_setup_repo_apt() {  # $1=distro(ubuntu|debian)
  local distro="$1" codename arch suite
  codename="$(ni_codename)"
  [[ -n "$codename" ]] || { log_err "无法确定发行版代号（VERSION_CODENAME）"; return 1; }
  ni_check_codename_supported "$distro" "$codename" || return 1

  ni_get_apt_key "$NI_KEYRING" dearmor || return 1

  suite="$(ni_apt_suite "$distro")"
  arch="$(dpkg --print-architecture 2>/dev/null || echo amd64)"
  ni_write_if_changed "$NI_APT_LIST" \
    "deb [arch=${arch} signed-by=${NI_KEYRING}] ${suite} ${codename} nginx"
  # Pin 900：否则发行版仓库的同名包优先级更高，装了等于没装
  ni_write_if_changed "$NI_APT_PREF" \
    "Package: *
Pin: origin nginx.org
Pin: release o=nginx
Pin-Priority: ${NI_PIN_PRIORITY}"
  log_info "仓库: ${suite} ${codename} nginx（通道: ${NI_CHANNEL}）"
}

# ---------- dnf / yum（RHEL 系 / Fedora / Amazon Linux） ----------
ni_rpm_keyfile() { echo "${NI_RPM_KEYFILE:-/etc/pki/rpm-gpg/nginx_signing.key}"; }

ni_setup_repo_dnf() {  # $1=stable 基路径 $2=mainline 基路径
  local base="$1" mainline="$2" keyfile
  keyfile="$(ni_rpm_keyfile)"
  ni_get_apt_key "$keyfile" raw || return 1

  # 通道选择 = 谁 enabled=1（整文件重写，幂等，无重复条目累积）
  local en_stable=1 en_main=0
  [[ "$NI_CHANNEL" == "mainline" ]] && { en_stable=0; en_main=1; }
  ni_write_if_changed "$NI_YUM_REPO" \
    "[nginx-stable]
name=nginx stable repo
baseurl=${base}
gpgcheck=1
enabled=${en_stable}
gpgkey=file://${keyfile}
module_hotfixes=true

[nginx-mainline]
name=nginx mainline repo
baseurl=${mainline}
gpgcheck=1
enabled=${en_main}
gpgkey=file://${keyfile}
module_hotfixes=true"
  log_info "仓库: ${NI_YUM_REPO}（通道: ${NI_CHANNEL}）"
}

# ---------- apk（Alpine） ----------
ni_setup_repo_apk() {
  local ver; ver="$(ni_alpine_ver)"
  [[ -n "$ver" ]] || { log_err "无法确定 Alpine 版本（${NI_ALPINE_RELEASE}）"; return 1; }
  ni_get_apk_key "${NI_APK_KEYS}/nginx_signing.rsa.pub" || return 1

  local repo="https://nginx.org/packages/alpine/v${ver}/main"
  [[ "$NI_CHANNEL" == "mainline" ]] && repo="https://nginx.org/packages/mainline/alpine/v${ver}/main"
  # 幂等：先删本工具写过的 @nginx 行，再追加当前通道（不累积重复行）
  if [[ -f "$NI_APK_REPOS" ]]; then
    grep -v '^@nginx ' "$NI_APK_REPOS" > "${NI_APK_REPOS}.tmp" 2>/dev/null || : > "${NI_APK_REPOS}.tmp"
    mv "${NI_APK_REPOS}.tmp" "$NI_APK_REPOS"
  fi
  printf '@nginx %s\n' "$repo" >> "$NI_APK_REPOS"
  log_info "仓库: @nginx ${repo}（通道: ${NI_CHANNEL}）"
}
