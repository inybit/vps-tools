#!/usr/bin/env bash
# ============================================================
# nginx-install 公共函数库
# 被 nginx-install.sh source；日志一律 stderr（返回值靠 stdout 捕获时不污染）
# ============================================================

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

# ---------- 颜色日志（stderr） ----------
log_info() { echo -e "\033[0;32m[INFO]\033[0m $*" >&2; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $*" >&2; }
log_err()  { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
log_ok()   { echo -e "\033[0;32m[OK]\033[0m $*" >&2; }

# ---------- root 检测 ----------
# 用户面向的命令名（wrapper 是 /usr/local/bin/nginx-install，$0 却是脚本库里的 *.sh）
NI_SELF="${NI_SELF:-$(basename "${0:-nginx-install}")}"
NI_SELF="${NI_SELF%.sh}"

require_root() {
  if [[ ${NI_EUID:-$EUID} -ne 0 ]]; then
    log_err "需要 root 权限（写 ${NI_KEYRING} / 仓库文件 / 安装软件包）。"
    log_err "请以 root 运行: sudo ${NI_SELF} $*"
    exit 1
  fi
}

# ---------- 配置加载（/etc/nginx-install.env，可缺省） ----------
# 外部环境变量优先（load_env 前已 export 的值不被文件覆盖）
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

# 是否真有控制终端可交互。⚠️ 不能用 [[ -r /dev/tty ]] —— 那是**权限位判定**，
# 无控制终端时同样返回真（root 下 /dev/tty 恒可读），直接 read 会报
# "/dev/tty: No such device or address"（2026-09-18 真机实测）。判据必须是「真打开一次」。
has_ctty() { { : < /dev/tty; } 2>/dev/null; }

# ---------- 交互输入（stdin 被占用时从 /dev/tty 读；返回 1 = 无交互终端） ----------
read_input() {  # $1=提示 $2=变量名
  local _rc=0
  if [[ -t 0 ]]; then
    read -r -p "$1" "$2" || _rc=1
  elif has_ctty; then
    # 提示单独打到 stderr（read -p 也写 stderr，但下面的 2>/dev/null 会连它一起吞掉）
    printf '%s' "$1" >&2
    # ⚠️ 重定向顺序不能反：2>/dev/null 必须在 < /dev/tty 之前，否则打开失败的报错先落到真实 stderr
    read -r "$2" 2>/dev/null < /dev/tty || _rc=1
  else
    _rc=1
  fi
  if [[ $_rc -ne 0 ]]; then
    printf -v "$2" ""    # set -u 兜底
    return 1
  fi
}

# 确认提示（默认 N）；返回 0 = 确认
confirm() {  # $1=提示文本
  [[ "${NI_YES}" == "1" ]] && return 0
  local ans=""
  read_input "$1 [y/N] " ans || return 1
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
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

# ---------- 包管理器探测 + 安装 ----------
NI_PKG_MGR=""
detect_pkg_mgr() {
  [[ -n "$NI_PKG_MGR" ]] && { echo "$NI_PKG_MGR"; return 0; }
  # ⚠️ 必须用 if/elif：写成 `command -v apk && mgr=apk` 顺序赋值时**最后命中的赢**
  # （yum > dnf > apt-get > apk），与「Alpine 优先」的意图相反。
  # 2026-09-18 harness 实测：PATH 里同时有 apk 与真实 apt-get 时，返回的是 apt-get。
  local mgr=""
  if command -v apk >/dev/null 2>&1; then mgr="apk"
  elif command -v apt-get >/dev/null 2>&1; then mgr="apt-get"
  elif command -v dnf >/dev/null 2>&1; then mgr="dnf"
  elif command -v yum >/dev/null 2>&1; then mgr="yum"
  fi
  NI_PKG_MGR="$mgr"
  echo "$mgr"
}

install_pkgs() {  # $1=包名 $2=复查命令名（默认=包名）
  local mgr
  mgr="$(detect_pkg_mgr)"
  [[ -z "$mgr" ]] && { log_err "未识别包管理器（apk/apt/dnf/yum），请手动安装: $1"; return 1; }
  local pkg="$1" check="${2:-$1}" cmd
  case "$mgr" in
    apk)     cmd="apk add" ;;
    apt-get) apt-get update -qq >/dev/null 2>&1 || true; cmd="apt-get install -y -qq" ;;
    dnf)     cmd="dnf install -y" ;;
    yum)     cmd="yum install -y" ;;
  esac
  log_info "安装依赖: $pkg"
  $cmd "$pkg" >/dev/null 2>&1 || { log_err "安装失败: $cmd $pkg（请手动安装后重试）"; return 1; }
  command -v "$check" >/dev/null 2>&1 || { log_err "复查失败: $check 仍未安装"; return 1; }
  return 0
}

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
