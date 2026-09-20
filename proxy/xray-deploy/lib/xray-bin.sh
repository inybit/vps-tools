#!/usr/bin/env bash
# xray-bin.sh — Xray 二进制：版本查询 / 版本选择 / 下载安装 / geo 数据更新

# ============ Xray 版本查询 ============
# ⚠️ 必须用 releases 列表而非 /releases/latest —— 见主脚本 GITHUB_API 注释：
#    Xray 全部 release 都标 prerelease:true，/releases/latest 会漏掉它们
#    （实测恒返回 v26.3.27，实际最新 v26.9.9，导致永远装旧版）。
#    列表按 published_at 倒序，取首个非 draft 的 tag_name。
#
# ⚠️⚠️ 切片必须用【纯 bash】，不能用 `... | head -N`：
#    调用方（install_xray 等）在 `set -euo pipefail` 下取值，head 读够就关管道 →
#    上游 printf 收 SIGPIPE → 管道整体返回非 0 → pipefail 判失败 →
#    `tags="$(recent_xray_tags)" || return 0` 静默提前返回，菜单一行都不打印
#    （2026-09-21 实测踩到：菜单空白、版本选择形同虚设）。
_xray_tags_all() {  # 全部 tag（新 → 旧）；失败 return 1
  local out
  # curl | jq：jq 读满全部输入，不会提前关管道（无 SIGPIPE 风险）
  out="$(curl -fsSL --max-time 20 "${GITHUB_API}" \
    | jq -r '.[] | select(.draft == false) | .tag_name')" || return 1
  [[ -n "$out" ]] || return 1
  printf '%s\n' "$out"
}

_xray_tag_at() {  # $1=N（1 起）；越界/失败 return 1
  local n="${1:-1}" all i=0 line
  all="$(_xray_tags_all)" || return 1
  while IFS= read -r line; do
    i=$((i + 1))
    if [[ "$i" -eq "$n" ]]; then printf '%s\n' "$line"; return 0; fi
  done <<<"$all"
  return 1
}

latest_xray_tag() { _xray_tag_at 1; }

# 最近 N 个版本（安装向导 / 版本选择菜单用）
recent_xray_tags() {  # $1=N（默认 10）
  local n="${1:-10}" all i=0 line
  all="$(_xray_tags_all)" || return 1
  while IFS= read -r line; do
    i=$((i + 1))
    [[ "$i" -gt "$n" ]] && break
    printf '%s\n' "$line"
  done <<<"$all"
}

# 分界版本：>= 此版本的 Xray 服务端要求客户端 ClientHello 携带 X25519MLKEM768，
# 否则 REALITY 握手被静默回落（客户端报 reality verification failed）。
#   来源：XTLS/REALITY 提交 8cdf7bf9c7f0，实测落在 Xray v26.9.8（2026-09-08）。
#   mihomo 1.19.30+ 已适配；sing-box 截至 1.14.1 未适配（上游 issue #4520 open）。
MLKEM_MIN_VERSION="26.9.8"

# 该 tag 是否 >= 分界版本（$1 可带或不带 v 前缀）
xray_tag_needs_mlkem() {
  ! ver_gt "${MLKEM_MIN_VERSION}" "${1#v}"
}

# ============ Xray 下载/安装 ============
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

# 版本选择菜单。stdout = 选中的 tag（空 = 无法选择，调用方回退最新版）。
# 日志/菜单一律走 stderr，避免污染命令替换的返回值。
prompt_xray_version() {
  local tags latest cur i ans mark
  tags="$(recent_xray_tags 10)" || return 0
  [[ -n "$tags" ]] || return 0
  latest="$(head -1 <<<"$tags")"
  # ⚠️⚠️ 必须用 `|| true` 包住：首次安装时 ${BIN_PATH} 还不存在，
  #    命令替换里的管道会失败 → `set -e` 让【整个脚本静默退出】（实测 rc=127、
  #    无任何报错、菜单一行都不打印）。而「首次安装」正是本菜单的主场景！
  #    同类写法（cmd-info.sh 的版本回退）已一并加固。
  cur=""
  if [[ -x "${BIN_PATH}" ]]; then
    cur="$("${BIN_PATH}" version 2>/dev/null | head -1 | awk '{print $2}' || true)"
  fi
  cur="v${cur#v}"
  [[ "$cur" == "v" ]] && cur=""

  {
    echo "可选 Xray 版本（新 → 旧）:"
    i=0
    while IFS= read -r t; do
      i=$((i+1))
      mark=""
      [[ "$t" == "$latest" ]] && mark="${mark} 最新"
      [[ -n "$cur" && "$t" == "$cur" ]] && mark="${mark} ← 当前"
      printf '  %2d) %s%s\n' "$i" "$t" "$mark"
    done <<<"$tags"
    echo "  ⚠️ v${MLKEM_MIN_VERSION} 起，REALITY 服务端要求客户端支持 X25519MLKEM768："
    echo "     · mihomo 1.19.30+  → 可用（片段已含 support-x25519mlkem768: true）"
    echo "     · sing-box（含最新稳定版 1.14.1）→ ❌ 连不上，上游 issue #4520 未修"
    echo "     → 客户端用 sing-box 请选 v26.7.28 或更早"
  } >&2

  read_input "选择版本 [1-${i}，回车默认 1（最新 ${latest}）]: " ans || return 0
  [[ -z "${ans:-}" ]] && { echo "$latest"; return 0; }
  [[ "$ans" =~ ^[0-9]+$ ]] && [[ "$ans" -ge 1 ]] && [[ "$ans" -le "$i" ]] || {
    log_warn "无效选择，使用最新版 ${latest}"; echo "$latest"; return 0; }
  sed -n "${ans}p" <<<"$tags"
}

# 目标版本 >= 分界且部署中存在 REALITY 类协议 → 提示 sing-box 客户端不可用
warn_mlkem_if_needed() {  # $1=tag
  xray_tag_needs_mlkem "$1" || return 0
  [[ -f "$STATE_FILE" ]] || return 0
  jq -e '.protocols[] | select(.type=="vless-reality" or .type=="vless-xhttp-reality")' \
    "$STATE_FILE" >/dev/null 2>&1 || return 0
  log_warn "$1 >= v${MLKEM_MIN_VERSION}：REALITY 服务端要求客户端支持 X25519MLKEM768"
  log_warn "  · mihomo 1.19.30+ → 可用（片段已含 support-x25519mlkem768: true）"
  log_warn "  · sing-box（含最新稳定版 1.14.1）→ ❌ 连不上（上游 issue #4520 未修）"
  log_warn "  → 客户端是 sing-box 的话，请改用 v26.7.28 或更早"
}

install_xray() {
  need_root
  mkdir -p "${INSTALL_DIR}" "${CONFIG_DIR}"
  install_deps
  # 版本选择（无 TTY / 拉不到列表 → 空 → 回退最新版，行为与旧版一致）
  local tag
  tag="$(prompt_xray_version || true)"
  if [[ -z "$tag" ]]; then
    tag="$(latest_xray_tag)" || die "无法获取 Xray 最新版本（检查网络）"
  fi
  [[ -n "$tag" ]] || die "无法解析 Xray 版本号（GitHub API 返回异常）"
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
