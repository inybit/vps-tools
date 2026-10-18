#!/usr/bin/env bash
# ============================================================
# nginx-install 公共函数库
# 被 nginx-install.sh source；日志一律 stderr（返回值靠 stdout 捕获时不污染）
#
# 基础函数（日志 / 交互终端 / read_input / confirm / 包管理器）在仓库根
# lib/core.sh —— 多工具共用一份实现，不要在本文件重复定义。
# 本文件只留 nginx-install 特有的东西：路径/签名材料、root 检查、环境加载、发行版探测。
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
export CORE_YES_VAR="NI_YES"   # 供 core.sh 的 confirm 用间接展开读取

# ---------- 路径与常量（环境变量可覆盖——测试/非 root 场景；产品默认不变） ----------
: "${NI_ENV_FILE:=/etc/nginx-install.env}"                  # 配置文件（可缺省）
: "${NI_OS_RELEASE:=/etc/os-release}"
: "${NI_ALPINE_RELEASE:=/etc/alpine-release}"
: "${NI_KEYRING:=/usr/share/keyrings/nginx-archive-keyring.gpg}"   # apt 签名密钥
: "${NI_APT_LIST:=/etc/apt/sources.list.d/nginx.list}"             # apt 仓库
: "${NI_APT_PREF:=/etc/apt/preferences.d/99nginx}"                 # apt 优先级 pin
: "${NI_YUM_REPO:=/etc/yum.repos.d/nginx.repo}"                    # dnf/yum 仓库
: "${NI_APK_REPOS:=/etc/apk/repositories}"                         # apk 仓库清单
: "${NI_APK_KEYS:=/etc/apk/keys}"                                  # apk 信任密钥目录

# 官方签名材料（2026-09-18 实测：apt 用指纹、apk 用 DER sha256）
export NI_APT_KEY_URL="https://nginx.org/keys/nginx_signing.key"
export NI_ALPINE_KEY_URL="https://nginx.org/keys/nginx_signing.rsa.pub"
# apt 密钥环必须包含该指纹（官方文档给定，密钥环内含多把密钥，故用「包含」判定）
export NI_FINGERPRINT="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62"
# apk 公钥 DER 编码的 sha256（本机 openssl 实测，稳定可复现）
export NI_ALPINE_KEY_DER_SHA256="03833138bf6288dcb545f7a154af24f5c63b94931fef6b078cd8061204a44327"
export NI_PIN_PRIORITY="900"

# 官方支持矩阵（nginx.org/en/linux_packages.html，2026-09-18 核对）
export NI_SUPPORTED_DEBIAN="bullseye bookworm trixie"
export NI_SUPPORTED_UBUNTU="jammy noble resolute"

# ---------- root 检测 ----------
# 用户面向的命令名（wrapper 是 /usr/local/bin/nginx-install，$0 却是脚本库里的 *.sh）
NI_SELF="${NI_SELF:-$(basename "${0:-nginx-install}")}"
NI_SELF="${NI_SELF%.sh}"

# 留在本文件：${NI_EUID} 覆盖钩子（测试 mock root）+ 工具特有报错文案
require_root() {
  if [[ ${NI_EUID:-$EUID} -ne 0 ]]; then
    log_err "需要 root 权限（写 ${NI_KEYRING} / 仓库文件 / 安装软件包）。"
    log_err "请以 root 运行: sudo ${NI_SELF} $*"
    exit 1
  fi
}

# ---------- 配置加载（/etc/nginx-install.env，可缺省） ----------
# 外部环境变量优先（load_env 前已 export 的值不被文件覆盖）
# 留在本文件：NI_ 前缀与默认值是工具特有的
load_env() {
  local _ext_vars _line
  _ext_vars="$(env | grep -E '^NI_[A-Z0-9_]+=' 2>/dev/null || true)"
  if [[ -f "${NI_ENV_FILE}" ]]; then
    # shellcheck disable=SC1090
    . "${NI_ENV_FILE}" 2>/dev/null || true
  fi
  while IFS= read -r _line; do
    # shellcheck disable=SC2163
    [[ -n "$_line" ]] && export "$_line"
  done <<< "$_ext_vars"
  # NI_CHANNEL 留空 = 未指定（向导会询问，命令行 install 走 stable 默认）
  # 不用 : "${NI_CHANNEL:=stable}" —— 那会抹掉「用户没指定」这个信息，向导无法判断是否该问
  : "${NI_CHANNEL:=}"
  : "${NI_YES:=0}"
}

# ---------- 发行版信息 ----------
ni_os_id()   { sed -n 's/^ID=//p'     "${NI_OS_RELEASE}" 2>/dev/null | tr -d '"'; }
ni_os_like() { sed -n 's/^ID_LIKE=//p' "${NI_OS_RELEASE}" 2>/dev/null | tr -d '"'; }
ni_codename() {
  local c
  c="$(sed -n 's/^UBUNTU_CODENAME=//p' "${NI_OS_RELEASE}" 2>/dev/null | tr -d '"')"
  [[ -z "$c" ]] && c="$(sed -n 's/^VERSION_CODENAME=//p' "${NI_OS_RELEASE}" 2>/dev/null | tr -d '"')"
  echo "$c"
}
ni_alpine_ver() { sed -n 's/^\([0-9]*\.[0-9]*\).*/\1/p' "${NI_ALPINE_RELEASE}" 2>/dev/null | head -1; }

# 写文件（内容相同则跳过，保证幂等且不制造无谓 mtime 变化）
ni_write_if_changed() {  # $1=路径 $2=内容
  local f="$1" want="$2"
  if [[ -f "$f" ]] && [[ "$(cat "$f" 2>/dev/null)" == "$want" ]]; then
    log_info "已是最新，跳过: $f"
    return 0
  fi
  mkdir -p "$(dirname "$f")"
  printf '%s\n' "$want" > "$f"
  log_info "已写入: $f"
}
