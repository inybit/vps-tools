#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：restic / rclone 安装
#
# 安全契约（fail-closed）：下载 → 校验 sha256 → 通过才落盘；不过即拒绝且不安装。
# 版本固定为常量（不用发行版仓库：Debian/Ubuntu 的 restic 偏旧，缺 repair 等子命令）。
# 升级上游 = 改版本常量 + 对应 sha256（来源：官方 SHA256SUMS，2026-09-19 实拉核对）。
# ============================================================

VP_RESTIC_VERSION="0.19.1"
VP_RCLONE_VERSION="1.75.1"

# ---------- 架构映射（不硬编码资产名） ----------
vp_arch() {  # 输出 amd64 | arm64 | arm | arm-v7 | arm-v6（未知 → 返回 1）
  case "$(uname -m)" in
    x86_64|amd64)   echo "amd64" ;;
    aarch64|arm64)  echo "arm64" ;;
    armv7l|armv7)   echo "arm-v7" ;;
    armv6l|armv6)   echo "arm-v6" ;;
    *) return 1 ;;
  esac
}

# ---------- 资产 sha256（官方 SHA256SUMS，2026-09-19 实拉核对） ----------
vp_restic_sha() {  # $1=amd64|arm64|arm
  case "$1" in
    amd64) echo "f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c" ;;
    arm64) echo "a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465" ;;
    arm)   echo "1edc5f67b0dd0d028586ab28c34b4da7522eabce933b3f6cd04f9ea184c2a502" ;;
    *) return 1 ;;
  esac
}

vp_rclone_sha() {  # $1=amd64|arm64|arm-v7|arm-v6
  case "$1" in
    amd64)  echo "982b5aa772841168f8e380f139e9e787b2a105403e32b94da8676a0e1c0a13ab" ;;
    arm64)  echo "03f2504174034b6d004152ed7369251c9a9ec1f7e0836eda420f5c7a5ec0dff9" ;;
    arm-v7) echo "33c683053b677d9a89d4a985e8a25cfed7c8a95dd8379e367a5c73d8745356c3" ;;
    *) return 1 ;;
  esac
}

vp_restic_asset() {  # 输出: url sha 文件名
  local arch; arch="$(vp_arch)" || return 1
  case "$arch" in amd64|arm64) : ;; arm-v7|arm-v6) arch="arm" ;; esac
  local f="restic_${VP_RESTIC_VERSION}_linux_${arch}.bz2"
  echo "https://github.com/restic/restic/releases/download/v${VP_RESTIC_VERSION}/${f} $(vp_restic_sha "$arch") ${f}"
}

vp_rclone_asset() {  # 输出: url sha 文件名
  local arch; arch="$(vp_arch)" || return 1
  case "$arch" in
    amd64|arm64) : ;;
    arm-v7) : ;;
    arm-v6) arch="arm-v6" ;;
  esac
  local f="rclone-v${VP_RCLONE_VERSION}-linux-${arch}.zip"
  local sha; sha="$(vp_rclone_sha "$arch")" || return 1
  echo "https://github.com/rclone/rclone/releases/download/v${VP_RCLONE_VERSION}/${f} ${sha} ${f}"
}

# ---------- 下载 + 校验（校验不过什么都不写） ----------
vp_fetch_verified() {  # $1=url $2=期望sha256 $3=目标文件
  local url="$1" want="$2" dest="$3" got
  mkdir -p "$(dirname "$dest")"
  curl -fsSL --max-time 180 "$url" -o "$dest" || { log_err "下载失败: $url（网络？）"; rm -f "$dest"; return 1; }
  [[ -s "$dest" ]] || { log_err "下载内容为空: $url"; rm -f "$dest"; return 1; }
  got="$(sha256sum "$dest" | awk '{print $1}')"
  if [[ "$got" != "$want" ]]; then
    log_err "sha256 校验失败，拒绝安装！"
    log_err "  期望: $want"
    log_err "  实际: $got"
    rm -f "$dest"
    return 1
  fi
  log_ok "sha256 校验通过: $(basename "$dest")"
}

# ---------- restic ----------
vp_install_restic() {
  local asset url sha fname tmpdir
  asset="$(vp_restic_asset)" || { log_err "不支持的架构: $(uname -m)"; return 1; }
  read -r url sha fname <<< "$asset"
  command -v bzip2 >/dev/null 2>&1 || install_pkgs bzip2 bzip2 || return 1
  tmpdir="$(mktemp -d)" || return 1
  vp_fetch_verified "$url" "$sha" "${tmpdir}/${fname}" || { rm -rf "$tmpdir"; return 1; }
  bunzip2 "${tmpdir}/${fname}" || { log_err "解压失败（bz2 损坏？）"; rm -rf "$tmpdir"; return 1; }
  local bin="${tmpdir}/${fname%.bz2}"
  [[ -f "$bin" ]] || { log_err "解压产物缺失"; rm -rf "$tmpdir"; return 1; }
  install -m 0755 "$bin" "${VP_RESTIC_BIN}" || { rm -rf "$tmpdir"; return 1; }
  rm -rf "$tmpdir"
  log_ok "restic ${VP_RESTIC_VERSION} → ${VP_RESTIC_BIN}"
}

# ---------- rclone ----------
vp_install_rclone() {
  local asset url sha fname tmpdir
  asset="$(vp_rclone_asset)" || { log_err "不支持的架构: $(uname -m)"; return 1; }
  read -r url sha fname <<< "$asset"
  command -v unzip >/dev/null 2>&1 || install_pkgs unzip unzip || return 1
  tmpdir="$(mktemp -d)" || return 1
  vp_fetch_verified "$url" "$sha" "${tmpdir}/${fname}" || { rm -rf "$tmpdir"; return 1; }
  unzip -q "${tmpdir}/${fname}" -d "$tmpdir" || { log_err "解压失败（zip 损坏？）"; rm -rf "$tmpdir"; return 1; }
  local bin="${tmpdir}/${fname%.zip}/rclone"
  [[ -f "$bin" ]] || { log_err "解压产物缺失"; rm -rf "$tmpdir"; return 1; }
  install -m 0755 "$bin" "${VP_RCLONE_BIN}" || { rm -rf "$tmpdir"; return 1; }
  rm -rf "$tmpdir"
  log_ok "rclone ${VP_RCLONE_VERSION} → ${VP_RCLONE_BIN}"
}

# ---------- 依赖安装入口（幂等：已装且能跑就跳过） ----------
vp_deps_main() {
  local rc=0
  if vp_have_restic && "${VP_RESTIC_BIN}" version >/dev/null 2>&1; then
    log_info "restic 已安装: $("${VP_RESTIC_BIN}" version 2>/dev/null | head -1)"
  else
    vp_install_restic || rc=1
  fi
  if vp_have_rclone && "${VP_RCLONE_BIN}" version >/dev/null 2>&1; then
    log_info "rclone 已安装: $("${VP_RCLONE_BIN}" version 2>/dev/null | head -1)"
  else
    vp_install_rclone || rc=1
  fi
  return $rc
}
