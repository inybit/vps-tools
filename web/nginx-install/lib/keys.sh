#!/usr/bin/env bash
# ============================================================
# nginx-install 模块：官方签名密钥获取与校验
#
# 安全契约（fail-closed）：下载 → 校验 → 通过才落盘；校验不过**什么都不写**。
# 调用方不得绕过本模块直接安装包。
# ============================================================

ni_fetch() {  # $1=url $2=目标文件
  mkdir -p "$(dirname "$2")"
  curl -fsSL --max-time 60 "$1" -o "$2" || { log_err "下载失败: $1（网络？）"; return 1; }
  [[ -s "$2" ]] || { log_err "下载内容为空: $1"; return 1; }
}

# apt/rpm：密钥文件必须包含官方指纹（文件内含多把密钥 → 用「包含」判定）
ni_verify_apt_key() {  # $1=key 文件
  local fps
  fps="$(gpg --with-colons --import-options show-only --import "$1" 2>/dev/null \
        | awk -F: '/^fpr:/{print $10}')"
  [[ -n "$fps" ]] || { log_err "无法解析签名密钥（gnupg 缺失或文件损坏）"; return 1; }
  if ! grep -qx "$NI_FINGERPRINT" <<< "$fps"; then
    log_err "签名密钥指纹不匹配，拒绝安装！"
    log_err "  期望包含: $NI_FINGERPRINT"
    log_err "  实际指纹: $(tr '\n' ' ' <<< "$fps")"
    return 1
  fi
  log_ok "签名密钥指纹校验通过: $NI_FINGERPRINT"
}

# alpine：apk 公钥用 DER 编码的 sha256 校验（官方文档给 modulus，此处用更严格的摘要）
ni_verify_apk_key() {  # $1=key 文件
  local got
  got="$(openssl rsa -pubin -in "$1" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  [[ -n "$got" ]] || { log_err "无法解析 apk 公钥（openssl 缺失或文件损坏）"; return 1; }
  if [[ "$got" != "$NI_ALPINE_KEY_DER_SHA256" ]]; then
    log_err "apk 公钥摘要不匹配，拒绝安装！"
    log_err "  期望: $NI_ALPINE_KEY_DER_SHA256"
    log_err "  实际: $got"
    return 1
  fi
  log_ok "apk 公钥摘要校验通过"
}

# 下载 + 校验 apt/rpm 密钥并按形态落盘（dearmor=gpg 密钥环；raw=原始 key 文件）
ni_get_apt_key() {  # $1=目标路径 $2=dearmor|raw
  local dest="$1" mode="${2:-dearmor}" tmp
  tmp="$(mktemp)" || return 1
  if ! ni_fetch "$NI_APT_KEY_URL" "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! ni_verify_apt_key "$tmp"; then rm -f "$tmp"; return 1; fi   # ← 校验不过不落盘
  mkdir -p "$(dirname "$dest")"
  if [[ "$mode" == "dearmor" ]]; then
    if ! gpg --dearmor < "$tmp" > "${dest}.tmp" 2>/dev/null; then
      rm -f "$tmp" "${dest}.tmp"; log_err "密钥环转换失败"; return 1
    fi
    chmod a+r "${dest}.tmp"
    mv "${dest}.tmp" "$dest"
  else
    install -m 0644 "$tmp" "$dest" 2>/dev/null || cp "$tmp" "$dest" 2>/dev/null || true
  fi
  rm -f "$tmp"
  # 写后复查：落盘失败必须报错退出（否则后续 gpgcheck 全挂，且用户看不到原因）
  if [[ ! -s "$dest" ]]; then
    log_err "签名密钥写入失败: $dest（目录权限？）"
    return 1
  fi
  log_ok "已安装签名密钥: $dest"
}

ni_get_apk_key() {  # $1=目标路径
  local dest="$1" tmp
  tmp="$(mktemp)" || return 1
  if ! ni_fetch "$NI_ALPINE_KEY_URL" "$tmp"; then rm -f "$tmp"; return 1; fi
  if ! ni_verify_apk_key "$tmp"; then rm -f "$tmp"; return 1; fi   # ← 校验不过不落盘
  mkdir -p "$(dirname "$dest")"
  install -m 0644 "$tmp" "$dest" 2>/dev/null || cp "$tmp" "$dest" 2>/dev/null || true
  rm -f "$tmp"
  if [[ ! -s "$dest" ]]; then
    log_err "apk 公钥写入失败: $dest（目录权限？）"
    return 1
  fi
  log_ok "已安装 apk 公钥: $dest"
}
