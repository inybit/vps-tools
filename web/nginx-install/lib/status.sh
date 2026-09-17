#!/usr/bin/env bash
# ============================================================
# nginx-install 模块：状态体检（只读，尽量不需 root）
# 判据来源：读实际配置/进程/内核监听，不看「脚本自报」
# ============================================================

# 官方源是否配置到位（apt: 密钥环+list+pin；dnf: repo 文件；apk: 仓库行+密钥）
ni_status_repo() {
  local mgr; mgr="$(detect_pkg_mgr)"
  case "$mgr" in
    apt-get)
      local missing=""
      [[ -s "$NI_KEYRING" ]] || missing+=" 密钥环"
      [[ -s "$NI_APT_LIST" ]] || missing+=" 仓库文件"
      [[ -s "$NI_APT_PREF" ]] || missing+=" 优先级pin"
      if [[ -n "$missing" ]]; then
        log_warn "官方源未配置完整，缺少:${missing}"
        return 1
      fi
      local chan="stable"
      grep -q '/packages/mainline/' "$NI_APT_LIST" && chan="mainline"
      log_ok "官方源已配置（通道: ${chan}，pin: $(sed -n 's/^Pin-Priority:[[:space:]]*//p' "$NI_APT_PREF" | head -1)）"
      # 实际安装来源（apt-cache policy 的 Installed 行对应候选源）
      if command -v apt-cache >/dev/null 2>&1; then
        local origin
        origin="$(apt-cache policy nginx 2>/dev/null | sed -n '/Installed:/{n;s/^ *//;p}' | head -1)"
        [[ -n "$origin" ]] && log_info "安装来源: ${origin}"
      fi
      ;;
    dnf|yum)
      if [[ -s "$NI_YUM_REPO" ]]; then
        # 通道 = 哪一段 enabled=1（用 awk 分段判定，不依赖 sed 区间细节）
        local chan
        chan="$(awk '/^\[nginx-stable\]/{s=1} /^\[nginx-mainline\]/{s=2}
                     /^enabled=1/{if(s==2) print "mainline"; else if(s==1) print "stable"}' \
                "$NI_YUM_REPO" 2>/dev/null | head -1)"
        log_ok "官方源已配置（通道: ${chan:-unknown}）"
      else
        log_warn "官方源未配置: ${NI_YUM_REPO} 不存在"
        return 1
      fi
      ;;
    apk)
      if grep -q '^@nginx ' "$NI_APK_REPOS" 2>/dev/null && [[ -s "${NI_APK_KEYS}/nginx_signing.rsa.pub" ]]; then
        log_ok "官方源已配置: $(grep -m1 '^@nginx ' "$NI_APK_REPOS")"
      else
        log_warn "官方源未配置（缺 @nginx 仓库行或签名公钥）"
        return 1
      fi
      ;;
    *) log_warn "未识别包管理器，跳过源检查" ; return 1 ;;
  esac
  return 0
}

ni_status_service() {
  if command -v systemctl >/dev/null 2>&1; then
    local st; st="$(systemctl is-active nginx 2>/dev/null || echo unknown)"
    local en; en="$(systemctl is-enabled nginx 2>/dev/null || echo unknown)"
    case "$st" in
      active) log_ok "服务: active（开机自启: ${en}）" ;;
      *)      log_warn "服务: ${st}（开机自启: ${en}）" ;;
    esac
    return 0
  fi
  if command -v rc-service >/dev/null 2>&1; then
    if rc-service nginx status >/dev/null 2>&1; then log_ok "服务: running（openrc）"
    else log_warn "服务: not running（openrc）"; fi
    return 0
  fi
  log_warn "未识别 init 系统"
}

ni_status_config_test() {
  nginx -t 2>&1 | sed 's/^/  /' >&2
  if nginx -t >/dev/null 2>&1; then
    log_ok "配置语法检查通过"
    return 0
  fi
  log_err "配置语法检查失败（见上）"
  return 1
}

# 实际监听端口（读内核，不看配置文件）
ni_status_listen() {
  local out=""
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -n -u | tr '\n' ' ')"
  elif command -v netstat >/dev/null 2>&1; then
    out="$(netstat -ltn 2>/dev/null | awk '/^tcp/{print $4}' | sed 's/.*://' | sort -n -u | tr '\n' ' ')"
  fi
  out="${out% }"
  if [[ -n "$out" ]]; then
    log_info "监听中的 TCP 端口: ${out}"
  else
    log_warn "未读取到监听端口（ss/netstat 不可用或无监听）"
  fi
}

# Docker 联动提示：容器端口若对公网暴露，与「nginx 统一网关」姿势冲突
ni_status_docker_hint() {
  command -v docker >/dev/null 2>&1 || return 0
  local n
  n="$(docker ps --format '{{.Ports}}' 2>/dev/null | grep -c '0\.0\.0\.0' || true)"
  n="${n:-0}"
  if [[ "$n" -gt 0 ]]; then
    log_warn "有 ${n} 个容器端口绑在 0.0.0.0（公网可达）—— 推荐改为 -p 127.0.0.1:<端口>，"
    log_warn "对外统一由 nginx 反代；容器侧执行: sudo docker-install firewall lockdown"
  else
    log_info "Docker: 未发现绑 0.0.0.0 的容器端口（符合统一网关姿势）"
  fi
}

status_main() {
  log_info "nginx-install ${NI_VERSION}"
  if nginx_installed; then
    log_info "nginx: $(nginx_version)（$(command -v nginx)）"
  else
    log_warn "nginx 未安装（sudo ${NI_SELF} install 安装）"
  fi
  echo "" >&2
  ni_status_repo || true
  echo "" >&2
  if nginx_installed; then
    ni_status_service || true
    ni_status_config_test || true
    ni_status_listen || true
  fi
  echo "" >&2
  ni_status_docker_hint || true
}
