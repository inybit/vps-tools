#!/usr/bin/env bash
# ============================================================
# vps-tools 共享核心：多工具共用的基础函数（单一实现）
#
# 为什么有这个文件（2026-10-19）：
#   抽取前 6 个工具各自维护一份 lib/common.sh（vps-backup 还有第 6 份在 pkg.sh），
#   10 个基础函数重复 3~6 份。不是「看起来重复」，是**行为已分叉**：
#     · log_ok 只有 3 份有
#     · detect_pkg_mgr 有 3 种实现：两份带缓存（缓存变量名还不同）、一份无缓存且
#       返回 "none"、一份在 pkg.sh 里
#     · die（xray）vs log_err（其余）命名不统一
#   历史上 `command -v X && mgr=X`（最后命中赢）那个坑就是全仓库级 bug，
#   修的时候要改多处 —— 这正是「复制粘贴式共享」的代价。
#
# 边界（重要）：**只收「逐字相同」的函数**。
#   require_root / load_env 故意留在各工具的 lib/common.sh：
#     · require_root 带工具特有的 EUID 覆盖钩子（DI_EUID/NI_EUID/VP_EUID，测试用来 mock root）
#       + 工具特有的报错文案
#     · load_env 带工具特有的环境变量前缀（DI_/NI_/VP_/VPS_INIT_）和默认值
#   把它们硬抽成通用函数只会换来一层间接 + 更难读的间接展开，不叫复用。
#
# 定位方式（两种布局都要能跑）：
#   仓库内 : <repo>/<域>/<工具>/lib/common.sh → <repo>/lib/core.sh（上三级）
#   安装后 : <INSTALL_DIR>/<工具>/lib/common.sh → 同目录 core.sh
#            （注册表 extra_files 用 `lib/core.sh:lib/core.sh` 把本文件装到该处）
# ============================================================

# ---------- 日志（一律 stderr：返回值靠 stdout $(...) 捕获时不被污染） ----------
log_info() { echo -e "\033[0;32m[INFO]\033[0m $*" >&2; }
log_warn() { echo -e "\033[0;33m[WARN]\033[0m $*" >&2; }
log_err()  { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
log_ok()   { echo -e "\033[0;32m[OK]\033[0m $*" >&2; }
die()      { log_err "$*"; exit 1; }

# ---------- 交互终端判定 ----------
# ⚠️ 不要写成 `[[ -r /dev/tty ]]`：那是**权限位判定**，没有控制终端时同样为真，
#    随后 read 会报 "/dev/tty: No such device or address"（2026-09-18 真机实测）。
#    必须真打开一次。
has_ctty() { { : < /dev/tty; } 2>/dev/null; }

# ---------- 交互输入（stdin 被占用时从 /dev/tty 读；返回 1 = 无交互终端） ----------
read_input() {  # $1=提示 $2=变量名
  local _rc=0
  if [[ -t 0 ]]; then
    read -r -p "$1" "$2" || _rc=1
  elif has_ctty; then
    # 提示单独打到 stderr（read -p 也写 stderr，但下面的 2>/dev/null 会连它一起吞掉）
    printf '%s' "$1" >&2
    # ⚠️ 重定向顺序不能反：2>/dev/null 必须在 < /dev/tty 之前，
    #    否则打开失败的报错先落到真实 stderr
    read -r "$2" 2>/dev/null < /dev/tty || _rc=1
  else
    _rc=1
  fi
  if [[ $_rc -ne 0 ]]; then
    printf -v "$2" ""    # set -u 下确保变量已定义，不崩溃
    return 1
  fi
}

# ---------- 确认（CORE_YES_VAR 指定「免交互」开关变量名，如 VP_YES） ----------
confirm() {  # $1=提示文本
  local _y="${CORE_YES_VAR:-}"
  if [[ -n "$_y" && "${!_y:-0}" == "1" ]]; then return 0; fi
  local ans=""
  read_input "$1 [y/N] " ans || return 1
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# ---------- 包管理器探测 ----------
# 返回 apk / apt-get / dnf / yum；都不存在时返回空串（调用方用 -z 判断）。
# ⚠️ 必须用 if/elif：写成 `command -v apk && mgr=apk` 顺序赋值时**最后命中的赢**
#    （yum > dnf > apt-get > apk），与「Alpine 优先」的意图相反。
#    2026-09-18 nginx-install harness 实测：PATH 里同时有 apk 与真实 apt-get 时返回 apt-get。
# 不做缓存：`command -v` 本身极廉价，而缓存会引入「改了 PATH 仍返回旧值」的隐性 bug
#    （抽取前的 3 份实现有 2 份带缓存，正是分叉来源之一）。
detect_pkg_mgr() {
  if command -v apk >/dev/null 2>&1; then echo "apk"
  elif command -v apt-get >/dev/null 2>&1; then echo "apt-get"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  else echo ""
  fi
}

# ---------- 安装软件包 ----------
install_pkgs() {  # $1=包名 $2=复查命令名（默认=包名；如 fail2ban 包无同名命令）
  local mgr
  mgr="$(detect_pkg_mgr)"
  [[ -z "$mgr" ]] && { log_err "未识别包管理器（apk/apt/dnf/yum），请手动安装: $1"; return 1; }
  local pkg="$1" check="${2:-$1}"
  local cmd
  case "$mgr" in
    apk)     cmd="apk add" ;;
    apt-get) apt-get update -qq >/dev/null 2>&1 || true; cmd="apt-get install -y -qq" ;;
    dnf)     cmd="dnf install -y" ;;
    yum)     cmd="yum install -y" ;;
  esac
  log_info "安装依赖: $pkg"
  $cmd "$pkg" >/dev/null 2>&1 || { log_err "安装失败: $cmd $pkg（请手动安装后重试）"; return 1; }
  # 装后复查（用命令名，包名可能无同名命令）
  command -v "$check" >/dev/null 2>&1 || { log_err "复查失败: $check 仍未安装"; return 1; }
  return 0
}
