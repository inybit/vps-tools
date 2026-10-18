#!/usr/bin/env bash
# ============================================================
# docker-install 公共函数库
# 被 docker-install.sh source；日志一律输出到 stderr（铁律：返回值靠 stdout 捕获时不污染）
#
# 基础函数（日志 / 交互终端 / read_input / confirm / 包管理器）在仓库根
# lib/core.sh —— 多工具共用一份实现，不要在本文件重复定义。
# 本文件只留 docker-install 特有的东西：路径默认值、root 检查、环境加载、防火墙后端探测。
# ============================================================

# ---------- 共享核心（仓库内 ../../../lib，安装后与本文件同目录） ----------
if [[ -r "${BASH_SOURCE[0]%/*}/core.sh" ]]; then
  # shellcheck disable=SC1091
  . "${BASH_SOURCE[0]%/*}/core.sh"
elif [[ -r "${BASH_SOURCE[0]%/*}/../../../lib/core.sh" ]]; then
  # shellcheck disable=SC1091
  . "${BASH_SOURCE[0]%/*}/../../../lib/core.sh"
else
  echo "[ERROR] 找不到共享核心 lib/core.sh（安装不完整，请重跑安装器）" >&2
  exit 1
fi

# confirm 的免交互开关变量名（core 里用间接展开 ${!CORE_YES_VAR} 读取）
export CORE_YES_VAR="DI_YES"   # 供 core.sh 的 confirm 用间接展开读取

# 路径默认值（环境变量可覆盖——测试/非 root 场景；产品默认不变）
: "${DI_ENV_FILE:=/etc/docker-install.env}"      # 配置文件（可缺省）
: "${DI_UFW_AFTER:=/etc/ufw/after.rules}"        # ufw 规则文件（ufw 首次 enable 时生成）
: "${DI_UFW_AFTER6:=/etc/ufw/after6.rules}"
: "${DI_UFW_DEFAULT:=/etc/default/ufw}"
: "${DI_UFW_USER_RULES:=/etc/ufw/user.rules}"    # ufw route allow 落点（用于枚举已放行）
: "${DI_DOCKER_DIR:=/etc/docker}"                # daemon.json 所在
: "${DI_DAEMON_JSON:=/etc/docker/daemon.json}"
: "${DI_DOCKER_ROOT:=/var/lib/docker}"
: "${DI_SOCK:=/var/run/docker.sock}"
: "${DI_SCAN_DIRS:=/srv/docker /opt/docker}"     # perms check 扫描的 bind mount 约定目录

# 标记块（与 chaifeng/ufw-docker 完全一致——互认，可接管）
DI_BLOCK_BEGIN="# BEGIN UFW AND DOCKER"
DI_BLOCK_END="# END UFW AND DOCKER"
export DI_BLOCK_BEGIN DI_BLOCK_END

# ---------- root 检测 ----------
# 留在本文件：${DI_EUID} 覆盖钩子（测试 mock root）+ 工具特有报错文案
require_root() {
  if [[ ${DI_EUID:-$EUID} -ne 0 ]]; then
    log_err "需要 root 权限（安装 Docker、写 /etc/ufw、管理 docker 组）。"
    log_err "请以 root 运行: sudo ${0##*/} $*"
    exit 1
  fi
}

# ---------- 配置加载（/etc/docker-install.env，可缺省） ----------
# 留在本文件：DI_ 前缀与默认值是工具特有的
# shellcheck disable=SC1090
load_env() {
  local _ext_vars _line
  _ext_vars="$(env | grep -E '^DI_[A-Z0-9_]+=' 2>/dev/null || true)"
  if [[ -f "${DI_ENV_FILE}" ]]; then
    . "${DI_ENV_FILE}" 2>/dev/null || true
  fi
  while IFS= read -r _line; do
    # shellcheck disable=SC2163  # export "NAME=value" 动态导出（NAME=value 整行）
    [[ -n "$_line" ]] && export "$_line"
  done <<< "$_ext_vars"
  : "${DI_DOCKER_USER:=}"          # 加入 docker 组的用户（空=交互询问）
  : "${DI_DOCKER_CIDRS:=}"         # 允许互访的容器私网 CIDR（空=自动探测）
  : "${DI_ALLOW_PORTS:=}"          # 初始放行的容器端口（如 80,443）
  : "${DI_YES:=0}"
}

# ---------- 防火墙后端探测 ----------
# 输出: iptables | nftables | none
#
# ⚠️ Docker 29.x 的 FirewallBackend 是【结构体】不是字符串（2026-09-17 真机实测）：
#    `docker info --format '{{.FirewallBackend}}'`
#      → {iptables [[EnableUserlandProxy true] [UserlandProxyPath /usr/bin/docker-proxy]]}
#    `--format '{{json .FirewallBackend}}'` → {"Driver":"iptables","Info":[[...]]}
#    直接取字符串会拿到整段结构体 dump → 与 "nftables" 比较恒不等 → 漏判 nftables 后端。
detect_firewall_backend() {
  # 1) daemon.json 显式配置优先（最权威）
  local daemon_json="${DI_DAEMON_JSON}"
  if [[ -f "$daemon_json" ]]; then
    local be=""
    if command -v jq >/dev/null 2>&1; then
      be="$(jq -r '."firewall-backend" // empty' "$daemon_json" 2>/dev/null || true)"
    else
      be="$(sed -n 's/.*"firewall-backend"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$daemon_json" 2>/dev/null | head -1)"
    fi
    [[ -n "$be" ]] && { echo "$be"; return 0; }
  fi
  # 2) 运行时探测：只认 Driver 字段（结构体/字符串两种形态都兼容）
  if command -v docker >/dev/null 2>&1; then
    local raw=""
    raw="$(docker info --format '{{json .FirewallBackend}}' 2>/dev/null || true)"
    if [[ -n "$raw" && "$raw" != "null" ]]; then
      local drv=""
      if command -v jq >/dev/null 2>&1; then
        drv="$(printf '%s' "$raw" | jq -r '.Driver // empty' 2>/dev/null || true)"
      fi
      # 无 jq 时用 sed 从 JSON 取 Driver；若本就是裸字符串（旧版）直接采用
      [[ -z "$drv" ]] && drv="$(printf '%s' "$raw" | sed -n 's/.*"Driver"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
      [[ -z "$drv" && "$raw" != \{* ]] && drv="$raw"
      case "$drv" in
        iptables|nftables) echo "$drv"; return 0 ;;
      esac
    fi
  fi
  echo "iptables"
}
