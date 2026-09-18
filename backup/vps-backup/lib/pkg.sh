#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：包管理器探测与安装 / 配置写入
# 被 vps-backup.sh source（由 lib/common.sh 拆分而来，2026-09-19）
# ============================================================

# ---------- 包管理器探测 + 安装 ----------
VP_DETECTED_PKG_MGR=""
detect_pkg_mgr() {
  [[ -n "$VP_DETECTED_PKG_MGR" ]] && { echo "$VP_DETECTED_PKG_MGR"; return 0; }
  # ⚠️ 必须用 if/elif：写成 `command -v apk && mgr=apk` 顺序赋值时**最后命中的赢**
  local mgr=""
  if command -v apk >/dev/null 2>&1; then mgr="apk"
  elif command -v apt-get >/dev/null 2>&1; then mgr="apt-get"
  elif command -v dnf >/dev/null 2>&1; then mgr="dnf"
  elif command -v yum >/dev/null 2>&1; then mgr="yum"
  fi
  VP_DETECTED_PKG_MGR="$mgr"
  echo "$mgr"
}

install_pkgs() {  # $1=包名 $2=复查命令名（默认=包名）
  local mgr pkg check cmd
  mgr="$(detect_pkg_mgr)"
  [[ -z "$mgr" ]] && { log_err "未识别包管理器（apk/apt/dnf/yum），请手动安装: $1"; return 1; }
  pkg="$1"; check="${2:-$1}"
  case "$mgr" in
    apk)     cmd="apk add" ;;
    apt-get) apt-get update -qq >/dev/null 2>&1 || true; cmd="apt-get install -y -qq" ;;
    dnf)     cmd="dnf install -y" ;;
    yum)     cmd="yum install -y" ;;
  esac
  log_info "安装依赖: $pkg"
  $cmd "$pkg" >/dev/null 2>&1 || { log_err "安装失败: $cmd $pkg（请手动安装后重试）"; return 1; }
  command -v "$check" >/dev/null 2>&1 || { log_err "复查失败: $check 仍未安装"; return 1; }
}

# ---------- 配置写入（原子 tmp+mv；key 已存在则替换，否则追加） ----------
vp_env_set() {  # $1=key $2=value
  local key="$1" val="$2" f="${VP_ENV_FILE}" tmp
  [[ -f "$f" ]] || { log_err "配置不存在: $f"; return 1; }
  tmp="${f}.tmp"
  if grep -qE "^${key}=" "$f"; then
    # 用 | 作分隔符，值里的 / 不转义；值内 | 罕见（token 不含）
    sed "s|^${key}=.*|${key}=\"${val}\"|" "$f" > "$tmp"
  else
    cp "$f" "$tmp"
    printf '%s="%s"\n' "$key" "$val" >> "$tmp"
  fi
  mv "$tmp" "$f"
  chmod 600 "$f"
  log_ok "已更新配置: ${key}=${val}"
}
