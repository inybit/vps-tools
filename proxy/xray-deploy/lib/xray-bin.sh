#!/usr/bin/env bash
# xray-bin.sh — Xray 二进制：版本查询 / 下载安装 / geo 数据更新

# ============ Xray 下载/安装 ============
# 取最新 release tag。
# ⚠️ 必须用 releases 列表而非 /releases/latest —— 见主脚本 GITHUB_API 注释：
#    Xray 全部 release 都标 prerelease:true，/releases/latest 会漏掉它们
#    （实测恒返回 v26.3.27，实际最新 v26.9.9，导致永远装旧版）。
#    列表按 published_at 倒序，取首个非 draft 的 tag_name。
latest_xray_tag() {
  curl -fsSL --max-time 20 "${GITHUB_API}" \
    | jq -r '[.[] | select(.draft == false)][0].tag_name // empty'
}

download_xray() {  # $1=tag；失败 return 1（由调用方决定回滚）
  local tag="$1" arch asset url
  arch="$(detect_arch)"
  asset="Xray-$(xray_asset_suffix)"
  url="https://github.com/XTLS/Xray-core/releases/download/${tag}/${asset}"
  [[ -n "${GH_PROXY:-}" ]] && url="${GH_PROXY}${url}"

  log_info "下载 Xray ${tag} (${arch}): ${url}"
  local tmp
  tmp="$(mktemp -d)"
  if ! curl -fL --max-time 300 -o "${tmp}/xray.zip" "$url"; then
    rm -rf "$tmp"; log_err "Xray 下载失败: ${url}"; return 1
  fi
  if ! unzip -o -j "${tmp}/xray.zip" "xray" -d "${INSTALL_DIR}" >/dev/null; then
    rm -rf "$tmp"; log_err "解压失败（zip 损坏?）"; return 1
  fi
  chmod +x "${BIN_PATH}"
  rm -rf "$tmp"
  log_info "Xray 已安装: ${BIN_PATH} ($("${BIN_PATH}" version | head -1))"
}

install_xray() {
  need_root
  mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}"
  install_deps
  local tag
  tag="$(latest_xray_tag)" || die "无法获取 Xray 最新版本（检查网络）"
  download_xray "$tag" || die "Xray 安装失败"
  [[ -x "${BIN_PATH}" ]] || die "Xray 二进制缺失"
}

# ============ geo 数据更新（MetaCubeX/meta-rules-dat） ============
update_geo() {
  local quiet="${1:-}"
  need_root
  mkdir -p "${INSTALL_DIR}"
  for f in geosite.dat geoip.dat; do
    local url="${GEO_SOURCE}/${f}"
    [[ -n "${GH_PROXY:-}" ]] && url="${GH_PROXY}${url}"
    [[ -z "$quiet" ]] && log_info "更新 ${f}: ${url}"
    curl -fL --max-time 120 -o "${INSTALL_DIR}/${f}" "$url" || die "${f} 下载失败"
  done
  [[ -z "$quiet" ]] && log_info "geo 数据已更新（MetaCubeX/meta-rules-dat）"
}
