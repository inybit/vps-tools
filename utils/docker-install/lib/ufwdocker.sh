#!/usr/bin/env bash
# ============================================================
# docker-install 模块：委托 chaifeng/ufw-docker 做加固
#
# 加固（写 /etc/ufw/after.rules 的 DOCKER-USER 规则块）不再自维护，
# 改为【固定版本】拉取上游开源脚本执行 —— 上游是该问题的社区标准方案，
# 规则块演进（如 nftables 后端）由上游跟进，本地只做封装与验证。
#
# 版本固定 + sha256 校验：raw.githubusercontent 的 tag 内容理论上不可变，
# 但为防止上游改 tag / 传输被篡改，下载后必须比对 sha256，不符即拒绝（fail-closed）。
# ============================================================

: "${DI_UFWDOCKER_VERSION:=251123}"
: "${DI_UFWDOCKER_SHA256:=c3e5f0bf6061a3a2e7d7ac06abc80665707d2f4c91e90d76f22e4168863fb472}"
: "${DI_UFWDOCKER_BIN:=/usr/local/bin/ufw-docker}"
: "${DI_UFWDOCKER_URL:=https://raw.githubusercontent.com/chaifeng/ufw-docker/${DI_UFWDOCKER_VERSION}/ufw-docker}"
export DI_UFWDOCKER_VERSION DI_UFWDOCKER_SHA256 DI_UFWDOCKER_BIN DI_UFWDOCKER_URL

# ---------- 已装的上游脚本是否为本项目固定版本 ----------
ud_installed() {
  [[ -x "${DI_UFWDOCKER_BIN}" ]] || return 1
  local got
  got="$(sha256sum "${DI_UFWDOCKER_BIN}" 2>/dev/null | awk '{print $1}')"
  [[ "$got" == "${DI_UFWDOCKER_SHA256}" ]]
}

# ---------- 确保上游脚本就位（固定版本 + 校验） ----------
ud_ensure() {
  require_root
  if ud_installed; then
    log_info "ufw-docker ${DI_UFWDOCKER_VERSION} 已就位（sha256 校验通过）"
    return 0
  fi

  command -v sha256sum >/dev/null 2>&1 || install_pkgs coreutils sha256sum || return 1
  command -v curl >/dev/null 2>&1 || install_pkgs curl curl || return 1

  local tmp; tmp="$(mktemp)"
  log_info "下载 ufw-docker ${DI_UFWDOCKER_VERSION}（上游 chaifeng/ufw-docker）..."
  if ! curl -fsSL --max-time 60 "${DI_UFWDOCKER_URL}" -o "$tmp"; then
    log_err "下载失败: ${DI_UFWDOCKER_URL}"
    rm -f "$tmp"
    return 1
  fi

  local got
  got="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$got" != "${DI_UFWDOCKER_SHA256}" ]]; then
    log_err "sha256 校验失败 —— 拒绝安装（防篡改/防上游 tag 漂移）"
    log_err "  期望: ${DI_UFWDOCKER_SHA256}"
    log_err "  实得: ${got}"
    log_err "  如确认上游合法更新，请同步更新本工具的 DI_UFWDOCKER_SHA256"
    rm -f "$tmp"
    return 1
  fi
  log_ok "sha256 校验通过"

  install -m 0755 "$tmp" "${DI_UFWDOCKER_BIN}"
  rm -f "$tmp"
  log_ok "已安装: ${DI_UFWDOCKER_BIN}（版本 ${DI_UFWDOCKER_VERSION}）"
}

# ---------- 调用上游脚本（stdout 透传，stderr 归并到 stderr） ----------
ud_run() {
  [[ -x "${DI_UFWDOCKER_BIN}" ]] || { log_err "ufw-docker 未安装"; return 1; }
  "${DI_UFWDOCKER_BIN}" "$@"
}

# ---------- 加固：委托上游 install + 重启 ufw + 内核复核 ----------
ud_install_rules() {
  require_root
  ud_ensure || return 1

  # --docker-subnets（空参）= 自动探测 docker 实际使用的网段；
  # 比上游默认的「固定私网段」更准确（避免放行与本机无关的 10/8）。
  log_info "执行: ufw-docker install --docker-subnets（自动探测容器网段）"
  if ! ud_run install --docker-subnets 2>&1 | sed 's/^/    /' >&2; then
    log_err "ufw-docker install 失败"
    return 1
  fi

  # 上游明确要求 restart（不是 reload）才装载 after.rules
  log_info "重启 UFW 以装载规则..."
  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ufw >/dev/null 2>&1 || { log_err "systemctl restart ufw 失败"; return 1; }
  else
    ufw reload >/dev/null 2>&1 || true
  fi
  return 0
}

# ---------- 卸载加固：委托上游 uninstall + 清内核残留 ----------
ud_remove_rules() {
  require_root
  if [[ -x "${DI_UFWDOCKER_BIN}" ]]; then
    log_info "执行: ufw-docker uninstall"
    ud_run uninstall 2>&1 | sed 's/^/    /' >&2 || log_warn "ufw-docker uninstall 返回非零"
  else
    # 脚本不在（被手工删了）→ 退化为直接删标记块
    log_warn "未找到 ${DI_UFWDOCKER_BIN}，改为直接清理 after.rules/after6.rules 标记块"
    remove_block "${DI_UFW_AFTER}" || true
    remove_block "${DI_UFW_AFTER6}" || true
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl restart ufw >/dev/null 2>&1 || ufw reload >/dev/null 2>&1 || true
  fi

  # ⚠️ ufw restart 不清空 DOCKER-USER 链（真机实测）→ 显式 flush，否则状态不一致
  local fam
  for fam in iptables ip6tables; do
    command -v "$fam" >/dev/null 2>&1 || continue
    "$fam" -S DOCKER-USER >/dev/null 2>&1 || continue
    local before
    before="$("$fam" -S DOCKER-USER 2>/dev/null | grep -c '^-A' || true)"
    [[ "${before:-0}" -gt 0 ]] || continue
    "$fam" -F DOCKER-USER 2>/dev/null || true
    local after
    after="$("$fam" -S DOCKER-USER 2>/dev/null | grep -c '^-A' || true)"
    [[ "${after:-0}" -eq 0 ]] && log_ok "已清空内核 DOCKER-USER 链（${fam}: ${before} → 0）"
  done
  return 0
}
