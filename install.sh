#!/usr/bin/env bash
#
# vps-tools 一键安装/更新/卸载器
#
# 用法:
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh)            # 交互式管理菜单（安装/更新/卸载/查看）
#   vps-tools                                                                                       # 安装后同一入口（管理命令）
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) install    # 交互式选择安装（有终端）
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) install vnstat-monitor   # 安装指定工具
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) update vnstat-monitor    # 更新指定工具
#   bash <(curl -sSL https://raw.githubusercontent.com/inybit/vps-tools/main/install.sh) uninstall vnstat-monitor # 卸载指定工具
#
# 版本坐标（ref = 分支名或 tag 名；安装器与每个工具各有独立版本号）:
#   install vps-backup --ref vps-backup-v1.4.0     # 装/回滚到指定工具版本
#   update  vps-backup --ref main                  # 回到最新
#   self-update --ref v1.13.0                      # 安装器回滚到指定版本
#   VPS_TOOLS_REF=v1.14.0 bash install.sh install x   # 全局覆盖（工具与安装器同一 ref）
#
# 特性:
#   - 脚本下载到 /usr/local/lib/vps-tools/<tool>/ 下，与系统文件隔离，卸载干净
#   - 每个工具自动生成命令入口 /usr/local/bin/<tool>，直接以工具名调用
#   - 配置模板首次安装时复制到 /etc/<tool>.env（已存在则不覆盖），真实密钥由用户填写
#   - 定时调度统一用 systemd timer（工具 setup 子命令管理），不使用 crontab
#   - **安装/更新后不自动执行任何工具命令**：只放脚本 + 生成配置，交互式配置由用户显式执行
#   - 幂等：重复 install = 覆盖更新
#   - 首次交互运行自动安装管理命令 /usr/local/bin/vps-tools，之后直接 vps-tools 进入菜单
#   - 管道方式（curl | sudo bash）也能交互：stdin 被占用时从 /dev/tty 读取输入
#   - 启动检查更新：交互菜单进入时比对远端版本，有新版本提示（离线静默）

set -euo pipefail

# ============ 版本号（发布新功能时递增，供启动检查用） ============
# ⚠️ 改了 TOOLS 清单（增删 lib/templates 附加文件）**必须同步递增本版本号**：
#    install_self 依赖版本比对决定是否拉取远端 install.sh；版本没变 →
#    已装副本报「已是最新」→ 运行中的旧 TOOLS 清单永久陈旧 → 新增文件永远装不上。
#    2026-09-19 anthony_fr 实测：新增 lib/xhttp3.sh 但未升版，用户更新后
#    xray-deploy 启动即崩（入口 source 缺文件）。回归守卫见
#    tests/verify-install-tools-version-bump.sh（TOOLS 变更而版本未变 → FAIL）。
VPS_TOOLS_VERSION="1.19.3"

# ============ 配置 ============
GH_USER="inybit"
GH_REPO="vps-tools"
GH_BRANCH="main"                  # 默认跟踪分支（未指定 ref 时）
GH_ORIGIN="https://raw.githubusercontent.com"
RAW_BASE="${GH_ORIGIN}/${GH_USER}/${GH_REPO}"
DEFAULT_REF="$GH_BRANCH"
BASE_URL="${RAW_BASE}/${DEFAULT_REF}"   # 默认 ref 的基址（保持变量名，兼容既有测试的 sed 重写）

INSTALL_DIR="/usr/local/lib/vps-tools"   # 脚本库根目录（与命令入口分离）
CONFIG_DIR="/etc"                        # 配置目标目录
CMD_DIR="/usr/local/bin"                 # 命令入口目录
VPS_TOOLS_CMD="${CMD_DIR}/vps-tools"     # 管理命令入口

# ============ 版本坐标（ref）============
# 发布模型：安装器与每个工具各有独立版本号（见 README「版本与发布」）。
#   - 安装器版本 = VPS_TOOLS_VERSION → git tag  v<ver>
#   - 工具版本   = 各脚本内 VERSION 变量 → git tag  <tool>-v<ver>
# 装哪个版本由 ref 决定（ref = 分支名或 tag 名，两者在 raw URL 里同形）：
#   --ref <tag>            本次操作从该 ref 取文件。工具操作只影响该工具；
#                          只有 `self-update --ref <tag>` 才影响安装器自身。
#   VPS_TOOLS_REF=<tag>    全局覆盖（工具与安装器都从该 ref 取）。
# 已装 ref 记录在 ${INSTALL_DIR}/<tool>/.ref 与 ${INSTALL_DIR}/.installer-ref，
# 后续 update 沿用记录值 = **版本固定**；要回到最新须显式 `--ref main`。
CLI_REF=""                    # 本次运行 --ref（main() 解析后赋值）
ENV_REF="${VPS_TOOLS_REF:-}"  # 全局覆盖（环境变量）
ACTION=""                     # 本次运行动作（main() 赋值，installer_ref 用）

# ref 合法性：禁止空格/引号/路径穿越，避免拼出意外 URL
ref_valid() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]
}

base_url_for() {
  printf '%s/%s\n' "$RAW_BASE" "$1"
}

# 某工具本次使用的 ref（优先级：--ref > VPS_TOOLS_REF > 已装记录 > 默认分支）
tool_ref() {  # $1=工具名
  local name="$1" f="${INSTALL_DIR}/${name}/.ref" r=""
  if [[ -n "$CLI_REF" ]]; then echo "$CLI_REF"; return 0; fi
  if [[ -n "$ENV_REF" ]]; then echo "$ENV_REF"; return 0; fi
  [[ -r "$f" ]] && r="$(head -1 "$f" 2>/dev/null || true)"
  [[ -n "$r" ]] || r="$DEFAULT_REF"
  echo "$r"
}

# 安装器自身使用的 ref
# ⚠️ CLI_REF 只对 `self-update` 生效：`install vps-backup --ref vps-backup-v1.4.0`
#    若连带把安装器也降到那个 tag 的 install.sh，等于悄悄降级安装器。
installer_ref() {
  if [[ -n "$ENV_REF" ]]; then echo "$ENV_REF"; return 0; fi
  if [[ "$ACTION" == "self-update" && -n "$CLI_REF" ]]; then echo "$CLI_REF"; return 0; fi
  local f="${INSTALL_DIR}/.installer-ref" r=""
  [[ -r "$f" ]] && r="$(head -1 "$f" 2>/dev/null || true)"
  [[ -n "$r" ]] || r="$DEFAULT_REF"
  echo "$r"
}

# 记录某工具实际安装的 ref（供后续 update 沿用；失败不阻塞安装）
record_tool_ref() {  # $1=工具名 $2=ref
  printf '%s\n' "$2" > "${INSTALL_DIR}/${1}/.ref" 2>/dev/null || true
}

# 记录安装器自身跟的 ref（被 pin 到 tag 后，后续自更新只跟该 tag，不会被拉回 main）
record_installer_ref() {  # $1=ref
  mkdir -p "${INSTALL_DIR}" 2>/dev/null || true
  printf '%s\n' "$1" > "${INSTALL_DIR}/.installer-ref" 2>/dev/null || true
}

# ============ 整包快照（tarball）下载 ============
# 逐文件下载的瓶颈是**请求数 × RTT**，不是字节数：每个 curl 都是独立连接，
# TCP+TLS 握手 ≈ 3 RTT。xray-deploy 要 28 次（主脚本 1 + lib 27），
# 200ms RTT 的 VPS 上光握手就 ~17s；而整仓 tar.gz 只有 ~280KB。
# 故改为一次拉整包、本地解包、拷工具目录；一次运行内按 ref 缓存复用。
# 失败（codeload 被墙 / 无 tar / 解包异常）自动回退逐文件下载，行为与旧版一致。
# VPS_TOOLS_NO_TARBALL=1 强制关闭（出问题时的逃生开关）。
TARBALL_ROOT="${VPS_TOOLS_TARBALL_ROOT:-}"         # 本次运行的缓存根（mktemp -d）
TARBALL_SRC=""                                    # 最近一次 ensure_tarball 成功的仓库根
TARBALL_DISABLED="${VPS_TOOLS_NO_TARBALL:-0}"     # 1 = 永不用整包

# 确保某 ref 的整包已解包。成功 return 0 并设置全局 TARBALL_SRC。
# ⚠️ 必须**直接调用**，不能写 `src="$(ensure_tarball ...)"`：命令替换会开子 shell，
#    TARBALL_ROOT / .ok 缓存 / EXIT trap 全落在子 shell 里 —— 子 shell 一退出就触发
#    trap 删掉刚解包的树，父进程拿到的是**已消失的路径** → 每次都静默回退逐文件，
#    而且整包会被下载两次（2026-10-17 实测踩到）。
ensure_tarball() {  # $1=ref
  TARBALL_SRC=""
  [[ "$TARBALL_DISABLED" != "1" ]] || return 1
  command -v tar >/dev/null 2>&1 || return 1
  local ref="$1" dir root tgz d
  if [[ -z "$TARBALL_ROOT" ]]; then
    TARBALL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vps-tools-src.XXXXXX")" || {
      TARBALL_DISABLED=1; return 1
    }
    # 只清理自己创建的临时目录（不碰任何系统目录）
    trap '[[ -n "${TARBALL_ROOT:-}" && -d "${TARBALL_ROOT}" ]] && rm -rf "${TARBALL_ROOT}" || true' EXIT
  fi
  dir="${TARBALL_ROOT}/$(printf '%s' "$ref" | tr '/ ' '__')"
  if [[ -f "${dir}/.ok" ]]; then
    TARBALL_SRC="$(cat "${dir}/.ok")"
    return 0
  fi
  # 同一 ref 已失败过 → 直接回退，避免每个工具都等一次超时
  if [[ -f "${dir}/.failed" ]]; then return 1; fi

  mkdir -p "$dir"
  tgz="${dir}/src.tgz"
  if ! curl -fsSL --max-time 120 \
        "https://codeload.github.com/${GH_USER}/${GH_REPO}/tar.gz/${ref}" \
        -o "$tgz" 2>/dev/null; then
    log_warn "整包下载失败（ref: ${ref}），回退逐文件下载"
    : > "${dir}/.failed"; rm -f "$tgz"; return 1
  fi
  if ! tar -xzf "$tgz" -C "$dir" 2>/dev/null; then
    log_warn "整包解压失败（ref: ${ref}），回退逐文件下载"
    : > "${dir}/.failed"; rm -f "$tgz"; return 1
  fi
  rm -f "$tgz"

  # 包内顶层是唯一的 <repo>-<ref>/ 目录；不用 --strip-components（busybox tar 兼容性）
  root=""
  for d in "$dir"/*/; do
    [[ -d "$d" ]] && { root="${d%/}"; break; }
  done
  if [[ -z "$root" || ! -f "${root}/install.sh" ]]; then
    log_warn "整包结构异常（ref: ${ref}），回退逐文件下载"
    : > "${dir}/.failed"; return 1
  fi
  printf '%s\n' "$root" > "${dir}/.ok"
  TARBALL_SRC="$root"
  return 0
}

# ============ 工具注册表 ============
# 每行一个工具: name|script|env_template|env_target|interactive_setup|extra_files
#   name        工具名（install/update/uninstall 参数）
#   script      install.sh 里要下载的主脚本文件名（相对仓库根，按分类目录组织）
#   env_template 配置模板文件名（相对仓库根，可为空 = 无配置）
#   env_target  配置安装目标路径（env_template 为空时忽略）
#   post_install 安装后**建议用户手工执行**的子命令（空 = 无参运行工具本身，进交互向导/菜单）。
#               **仅用于打印下一步指引，安装器绝不代为执行任何工具命令**
#               （2026-09-19 用户明确要求：安装/更新后不自动执行工具命令）。
#               ⚠️ 值必须真实存在于该工具的 `-h` 输出里——本字段曾被当作布尔值用，
#                  导致 docker-install / vps-backup 被提示跑并不存在的 `setup` 子命令。
#               ⚠️ 一旦安装就自动跑工具会「在安装流程里插入交互提问 + 改变机器状态」，
#                  且旧实现只对首次安装（env 新生成）触发，行为不一致难以预期。
#   extra_files 主脚本之外的附加文件（空格分隔的相对路径清单；多文件工具如
#               vps-init 的 lib/*.sh 和 templates/*.tpl 必须在此列出，否则安装不完整；
#               可为空 = 单文件工具）
# 注：定时调度统一用 systemd timer（工具脚本 setup 子命令管理），不使用 crontab。
#
# 分类目录约定（新增脚本按功能域归类）:
#   monitor/   监控类（流量/资源/服务状态）
#   network/   网络类（路由/隧道/分流）
#   proxy/     代理类（xray/sing-box 等辅助脚本）
#   web/       Web 服务类（nginx 等站点网关）
#   utils/     通用工具（DDNS/证书/初始化等）
#   backup/    备份类
#   bench/     测试类（测速/基准）
TOOLS=(
  "vnstat-monitor|monitor/vnstat-monitor/vnstat-monitor.sh|monitor/vnstat-monitor/vnstat-monitor.env.example|${CONFIG_DIR}/vnstat-monitor.env|setup|"
  "xray-deploy|proxy/xray-deploy/xray-deploy.sh|||install|proxy/xray-deploy/lib/common.sh proxy/xray-deploy/lib/service.sh proxy/xray-deploy/lib/cdn-detect.sh proxy/xray-deploy/lib/fallback-data.sh proxy/xray-deploy/lib/fallback.sh proxy/xray-deploy/lib/sni-check.sh proxy/xray-deploy/lib/keys.sh proxy/xray-deploy/lib/xray-bin.sh proxy/xray-deploy/lib/registry.sh proxy/xray-deploy/lib/client-mihomo.sh proxy/xray-deploy/lib/client-singbox.sh proxy/xray-deploy/lib/client-ss2022.sh proxy/xray-deploy/lib/inbound.sh proxy/xray-deploy/lib/state.sh proxy/xray-deploy/lib/ss2022.sh proxy/xray-deploy/lib/outbound.sh proxy/xray-deploy/lib/warp.sh proxy/xray-deploy/lib/warp-tun.sh proxy/xray-deploy/lib/warp-cmd.sh proxy/xray-deploy/lib/menu.sh proxy/xray-deploy/lib/routing.sh proxy/xray-deploy/lib/chain.sh proxy/xray-deploy/lib/chain-info.sh proxy/xray-deploy/lib/proto-wizard.sh proxy/xray-deploy/lib/xhttp3.sh proxy/xray-deploy/lib/proto-crud.sh proxy/xray-deploy/lib/proto-edit.sh proxy/xray-deploy/lib/cmd-lifecycle.sh proxy/xray-deploy/lib/cmd-upgrade.sh proxy/xray-deploy/lib/cmd-info.sh proxy/xray-deploy/lib/cmd-fallback.sh proxy/xray-deploy/lib/globalping.sh proxy/xray-deploy/lib/geo-update.sh proxy/xray-deploy/lib/geo-timer.sh proxy/xray-deploy/lib/usage.sh lib/core.sh:lib/core.sh"
  "vps-init|utils/vps-init/vps-init.sh|utils/vps-init/vps-init.env.example|${CONFIG_DIR}/vps-init.env||utils/vps-init/lib/common.sh utils/vps-init/lib/sshkey.sh utils/vps-init/lib/dd.sh utils/vps-init/lib/system.sh utils/vps-init/lib/user.sh utils/vps-init/lib/ssh.sh utils/vps-init/lib/fail2ban.sh utils/vps-init/lib/ufw.sh utils/vps-init/templates/sshd-dropin.conf.tpl utils/vps-init/templates/jail.local.tpl lib/core.sh:lib/core.sh"
  "vps-bench|bench/vps-bench/vps-bench.sh|||nodequality|"
  "docker-install|utils/docker-install/docker-install.sh|utils/docker-install/docker-install.env.example|${CONFIG_DIR}/docker-install.env||utils/docker-install/lib/common.sh utils/docker-install/lib/install.sh utils/docker-install/lib/firewall.sh utils/docker-install/lib/firewall-rules.sh utils/docker-install/lib/access.sh utils/docker-install/lib/usage.sh utils/docker-install/lib/lockdown.sh utils/docker-install/lib/ufwdocker.sh lib/core.sh:lib/core.sh"
  "nginx-install|web/nginx-install/nginx-install.sh|web/nginx-install/nginx-install.env.example|${CONFIG_DIR}/nginx-install.env||web/nginx-install/lib/common.sh web/nginx-install/lib/keys.sh web/nginx-install/lib/repo.sh web/nginx-install/lib/install.sh web/nginx-install/lib/status.sh web/nginx-install/lib/usage.sh lib/core.sh:lib/core.sh"
  "vps-backup|backup/vps-backup/vps-backup.sh|backup/vps-backup/templates/vps-backup.env.example|${CONFIG_DIR}/vps-backup.env||backup/vps-backup/lib/common.sh backup/vps-backup/lib/pkg.sh backup/vps-backup/lib/restic.sh backup/vps-backup/lib/cache.sh backup/vps-backup/lib/exclude.sh backup/vps-backup/lib/paths.sh backup/vps-backup/lib/deps.sh backup/vps-backup/lib/repo.sh backup/vps-backup/lib/backup.sh backup/vps-backup/lib/retention.sh backup/vps-backup/lib/restore.sh backup/vps-backup/lib/remote.sh backup/vps-backup/lib/timer.sh backup/vps-backup/lib/status.sh backup/vps-backup/lib/usage.sh lib/core.sh:lib/core.sh"
)

# ============ 辅助函数 ============
log_info()  { echo -e "\033[0;32m[INFO]\033[0m $*"; }
log_warn()  { echo -e "\033[0;33m[WARN]\033[0m $*"; }
log_err()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

# 语义化版本比较（x.y.z，纯 bash 兼容 Alpine busybox，不用 sort -V）
ver_gt() {  # $1 > $2 返回 0
  local IFS=. a b i
  read -ra a <<<"$1"
  read -ra b <<<"$2"
  for i in 0 1 2; do
    [[ "${a[$i]:-0}" -gt "${b[$i]:-0}" ]] && return 0
    [[ "${a[$i]:-0}" -lt "${b[$i]:-0}" ]] && return 1
  done
  return 1
}

# 启动检查更新：比对远端 install.sh 版本号，有新版返回 0 并提示；离线/同版本返回 1（静默）
check_update() {
  local remote ref
  ref="$(installer_ref)"
  remote="$(remote_version)"
  [[ -n "$remote" ]] || return 1
  if ver_gt "$remote" "$VPS_TOOLS_VERSION"; then
    log_warn "检测到新版本 vps-tools ${remote}（当前 ${VPS_TOOLS_VERSION}，ref: ${ref}）"
    # ⚠️ 提示顺序很重要：**先给管道方式**。旧副本（< 1.7.1）的「菜单选 5」自身有 bug
    #    （拿副本自己跟自己比版本 → 恒报已最新，永远拉不到新版），
    #    所以对尚未修复的机器，选 5 是无效指引。
    log_warn "更新方式: curl -sSL $(base_url_for "$ref")/install.sh | sudo bash"
    log_warn "  （已装 v1.7.1+ 的机器也可用「菜单选 5 / vps-tools self-update」）"
    return 0
  fi
  return 1
}

# 解析工具注册表行
tool_field() {  # $1=行 $2=字段号(1-6)
  echo "$1" | cut -d'|' -f"$2"
}

# 解析 extra_files 里的单个条目 → 输出 "源路径<TAB>工具目录内相对路径"
#   两种格式：
#     lib/foo.sh                 源=目标，目标 = 源剥掉分类前缀（工具自己的文件）
#     lib/core.sh:lib/core.sh    源在工具目录之外，目标显式指定（多工具共享文件）
#   为什么需要第二种：整包快照只拷贝 <工具目录>，共享文件（仓库根 lib/core.sh）
#   不在该目录内；逐文件回退路径也需要知道「从哪取、装到哪」两个不同的路径。
ef_src_dst() {  # $1=条目 $2=工具目录（script_dir）
  local ef="$1" sd="$2"
  if [[ "$ef" == *:* ]]; then
    printf '%s\t%s\n' "${ef%%:*}" "${ef#*:}"
  else
    printf '%s\t%s\n' "$ef" "${ef#"$sd"/}"
  fi
}

find_tool() {  # $1=tool name → 输出注册表行
  local line
  for line in "${TOOLS[@]}"; do
    [[ "$(tool_field "$line" 1)" == "$1" ]] && { echo "$line"; return 0; }
  done
  return 1
}

# 已装工具的版本号（读工具主脚本里的版本变量；读不到则空）
# 各工具版本变量名不同（VERSION / VP_VERSION / DI_VERSION / NI_VERSION /
# VPS_INIT_VERSION / VPS_BENCH_VERSION），故按「首个 *_VERSION="x.y.z"」取。
installed_tool_version() {  # $1=注册表行
  local name script f
  name=$(tool_field "$1" 1)
  script=$(tool_field "$1" 2)
  f="${INSTALL_DIR}/${name}/$(basename "$script")"
  [[ -r "$f" ]] || return 0
  sed -n 's/^[A-Za-z_]*VERSION="\([0-9][0-9.]*\)".*/\1/p' "$f" | head -1
}

# 已装工具的 ref 记录（空 = 未记录，视为默认分支）
installed_tool_ref() {  # $1=工具名
  local f="${INSTALL_DIR}/${1}/.ref"
  [[ -r "$f" ]] || return 0
  head -1 "$f" 2>/dev/null || true
}

list_tools() {
  log_info "可用工具:"
  local line name ver ref
  for line in "${TOOLS[@]}"; do
    name=$(tool_field "$line" 1)
    if [[ -d "${INSTALL_DIR}/${name}" ]]; then
      ver="$(installed_tool_version "$line")"
      ref="$(installed_tool_ref "$name")"
      echo "  - ${name}  ($(tool_field "$line" 2))  已装 v${ver:-?}${ref:+ @${ref}}"
    else
      echo "  - ${name}  ($(tool_field "$line" 2))"
    fi
  done
}

# ============ 核心操作 ============
install_tool() {  # $1=tool line
  local line="$1" name script env_tpl env_tgt post_install extra_files ref base
  name=$(tool_field "$line" 1)
  script=$(tool_field "$line" 2)
  env_tpl=$(tool_field "$line" 3)
  env_tgt=$(tool_field "$line" 4)
  post_install=$(tool_field "$line" 5)
  extra_files=$(tool_field "$line" 6)

  # 版本坐标：本次从哪个 ref 取文件（--ref > VPS_TOOLS_REF > 已装记录 > main）
  ref="$(tool_ref "$name")"
  base="$(base_url_for "$ref")"

  local dest="${INSTALL_DIR}/${name}"
  local script_dir
  script_dir="$(dirname "$script")"
  # 替换失败回滚：备份/临时目录都由 $dest 派生（防 INSTALL_DIR 误展开）
  local dest_bak="${dest}.bak.$$"
  local dest_new="${dest}.new"

  mkdir -p "$dest"

  # ---- 优先整包快照：1 次请求代替 (主脚本 + N 个附加文件) 次 ----
  local src_root="" used_tarball=0 ef ef_src ef_rel ef_dest
  if ensure_tarball "$ref" && [[ -n "$TARBALL_SRC" && -d "${TARBALL_SRC}/${script_dir}" ]]; then
    src_root="$TARBALL_SRC"
    log_info "下载 ${name} (ref: ${ref}): 整包快照"
    # 拷到 .new 并在【替换之前】补齐共享文件：任何一步失败都不动现有安装
    # （旧实现先 rm -rf 旧树再 mv，共享文件失败时既无回滚又留下坏安装）
    if cp -a "${src_root}/${script_dir}" "$dest_new" 2>/dev/null; then
      # 跨目录共享文件（如 lib/core.sh:lib/core.sh）：整包拷贝只覆盖了工具目录，
      # 源在工具目录之外的文件必须单独拷进来，否则装完 source 缺文件 → 启动即崩
      local _ef _src _dst _ok=1
      for _ef in $extra_files; do
        IFS=$'\t' read -r _src _dst < <(ef_src_dst "$_ef" "$script_dir")
        [[ "$_src" == "$script_dir"/* ]] && continue
        mkdir -p "$(dirname "${dest_new}/${_dst}")"
        cp -a "${src_root}/${_src}" "${dest_new}/${_dst}" 2>/dev/null && continue
        # 该 ref 的工具是否真的依赖共享核心：旧 tag（v1.15.0 及更早）根本没有
        # lib/core.sh，其 common.sh 也不 source core —— 缺这个文件是正常状态，
        # 报错会让「按版本安装/回滚」对旧 tag 全部失效。
        if grep -q 'core\.sh' "${dest_new}/lib/common.sh" 2>/dev/null; then
          log_err "整包缺共享文件: ${_src}（该 ref 的工具依赖共享核心，安装不完整；现有安装未改动）"
          _ok=0
          break
        fi
        log_warn "跳过共享文件 ${_src}：该 ref（${ref}）的工具尚未使用共享核心"
      done
      if [[ $_ok -eq 0 ]]; then
        rm -rf "$dest_new"
        return 1
      fi
      # 原子替换：旧树先备份，替换成功才删备份；替换失败恢复旧树
      if [[ -d "$dest" ]]; then
        mv "$dest" "$dest_bak"
      fi
      if mv "$dest_new" "$dest" 2>/dev/null; then
        rm -rf "$dest_bak"
      else
        rm -rf "$dest"
        if [[ -d "$dest_bak" ]]; then
          mv "$dest_bak" "$dest"
        fi
        log_err "替换安装目录失败，已恢复原安装: ${dest}"
        return 1
      fi
      used_tarball=1
      chmod +x "${dest}/$(basename "$script")" 2>/dev/null || true
      find "$dest" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
      log_info "已安装脚本: ${dest}/$(basename "$script")（共 $(find "$dest" -type f | wc -l) 个文件）"
    else
      rm -rf "$dest_new" 2>/dev/null || true
      log_warn "整包拷贝失败，回退逐文件下载"
    fi
  fi

  # ---- 回退路径：逐文件下载（codeload 不可达 / 无 tar / 整包异常时）----
  if [[ $used_tarball -eq 0 ]]; then
    # 同样先装到 .new，全部成功才替换：中途失败不得破坏现有安装
    rm -rf "$dest_new"
    mkdir -p "$dest_new"
    log_info "下载 ${name} (ref: ${ref}): ${base}/${script}"
    if ! curl -fsSL --max-time 60 "${base}/${script}" -o "${dest_new}/$(basename "$script")"; then
      log_err "下载失败: ${script}（ref: ${ref}；检查网络、仓库路径或该 ref 是否含此文件；现有安装未改动）"
      rm -rf "$dest_new"
      return 1
    fi
    chmod +x "${dest_new}/$(basename "$script")"
    log_info "已安装脚本: ${dest}/$(basename "$script")"

    # 附加文件（多文件工具：lib/*.sh、templates/*.tpl 等，主脚本 source 依赖它们）
    # 条目可为 `源路径:目标相对路径`（共享文件），见 ef_src_dst
    for ef in $extra_files; do
      IFS=$'\t' read -r ef_src ef_rel < <(ef_src_dst "$ef" "$script_dir")
      ef_dest="${dest_new}/${ef_rel}"
      mkdir -p "$(dirname "$ef_dest")"  # lib/、templates/ 子目录可能不存在（防 curl 23）
      if ! curl -fsSL --max-time 60 "${base}/${ef_src}" -o "$ef_dest"; then
        # 共享文件在旧 tag 上不存在是正常状态（该 ref 的工具还没用共享核心）
        if [[ "$ef" == *:* ]] && ! grep -q 'core\.sh' "${dest_new}/lib/common.sh" 2>/dev/null; then
          log_warn "跳过共享文件 ${ef_src}：该 ref（${ref}）的工具尚未使用共享核心"
          continue
        fi
        log_err "下载失败: ${ef_src}（附加文件，ref: ${ref}，安装不完整；现有安装未改动）"
        rm -rf "$dest_new"
        return 1
      fi
      case "$ef_rel" in
        *.sh) chmod +x "$ef_dest" ;;
      esac
      log_info "已安装附加文件: ${dest}/${ef_rel}"
    done

    # 原子替换（同整包路径）
    if [[ -d "$dest" ]]; then
      mv "$dest" "$dest_bak"
    fi
    if mv "$dest_new" "$dest" 2>/dev/null; then
      rm -rf "$dest_bak"
    else
      rm -rf "$dest"
      if [[ -d "$dest_bak" ]]; then
        mv "$dest_bak" "$dest"
      fi
      log_err "替换安装目录失败，已恢复原安装: ${dest}"
      return 1
    fi
  fi

  # 记录本次安装的 ref：后续 update 不指定 --ref 时沿用（= 版本固定/回滚语义）
  record_tool_ref "$name" "$ref"

  # 命令入口（工具名直接调用）：wrapper → 脚本库
  mkdir -p "${CMD_DIR}"   # 命令目录可能不存在（干净系统 /usr/local/bin 也需确保）
  cat > "${CMD_DIR}/${name}" <<EOF
#!/usr/bin/env bash
exec "${dest}/$(basename "$script")" "\$@"
EOF
  chmod +x "${CMD_DIR}/${name}"
  log_info "已生成命令: ${CMD_DIR}/${name}（直接运行 ${name} 调用）"

  # 配置模板
  local env_was_created=0
  if [[ -n "$env_tpl" && -n "$env_tgt" ]]; then
    if [[ -f "$env_tgt" ]]; then
      log_warn "配置已存在，跳过: ${env_tgt}（如需重配请手动删除后重装）"
    else
      env_was_created=1
      mkdir -p "$(dirname "$env_tgt")"
      if [[ $used_tarball -eq 1 && -f "${src_root}/${env_tpl}" ]] \
         && cp "${src_root}/${env_tpl}" "$env_tgt" 2>/dev/null; then
        chmod 600 "$env_tgt"
        log_info "已生成配置模板: ${env_tgt} —— 请编辑填入真实密钥!"
      elif curl -fsSL --max-time 60 "${base}/${env_tpl}" -o "$env_tgt"; then
        chmod 600 "$env_tgt"
        log_info "已生成配置模板: ${env_tgt} —— 请编辑填入真实密钥!"
      else
        log_warn "配置模板下载失败: ${env_tpl}"
      fi
    fi
  fi

  # 安装/更新后**不自动执行任何工具命令**（2026-09-19 用户明确要求）：
  # 安装器只负责「放脚本 + 生成配置模板 + 生成命令入口」，是否跑工具、何时配置由用户决定。
  # 第 5 字段 = 建议用户手工执行的子命令（空 = 无参运行工具本身，进交互向导/菜单）。
  # ⚠️ 绝不代为执行：自动跑会在安装流程里插入交互提问、改变机器状态，
  #    且旧实现只对「首次安装」触发，行为不一致难以预期。
  local next_cmd="${name}"
  [[ -n "$post_install" ]] && next_cmd="${name} ${post_install}"
  # 无配置文件工具（env_tpl 为空）不能报「配置已存在」——它压根没有配置模板
  if [[ -z "$env_tpl" ]]; then
    log_info "下一步（请手动执行）: sudo ${next_cmd}"
  elif [[ "$env_was_created" == "1" ]]; then
    log_info "${name} 首次安装完成，配置模板已生成。"
    log_info "下一步（请手动执行）: 编辑 ${env_tgt} 后运行 sudo ${next_cmd}"
  else
    log_info "${name} 配置已存在（更新），保留原配置。如需重新配置: sudo ${next_cmd}"
  fi

  log_info "${name} 安装完成（ref: ${ref}）。"
}

uninstall_tool() {  # $1=tool line
  local line="$1" name env_tgt
  name=$(tool_field "$line" 1)
  env_tgt=$(tool_field "$line" 4)

  if [[ -d "${INSTALL_DIR}/${name}" ]]; then
    rm -rf "${INSTALL_DIR:?}/${name}"
    log_info "已删除脚本目录: ${INSTALL_DIR}/${name}"
  else
    log_warn "未找到脚本目录: ${INSTALL_DIR}/${name}"
  fi
  # 命令入口
  if [[ -f "${CMD_DIR}/${name}" ]]; then
    rm -f "${CMD_DIR}/${name}"
    log_info "已删除命令: ${CMD_DIR}/${name}"
  fi

  if [[ -f "$env_tgt" ]]; then
    log_warn "配置文件保留: ${env_tgt}（如需删除: rm $env_tgt）"
  fi

  log_info "如需移除定时，运行: sudo ${name} uninstall-timer（systemd timer）"
}

# ============ 交互输入 ============
# 管道方式（curl | sudo bash -s --）下 stdin 被 curl 占用，改从 /dev/tty 读取。
# 返回 1 = 无交互终端（纯 CI/脚本场景）。
# 是否真有控制终端可交互。⚠️ 不能用 [[ -r /dev/tty ]] —— 那是**权限位判定**，
# 无控制终端时同样返回真，直接 read 会报 "/dev/tty: No such device or address"
# （2026-09-18 真机实测）。判据必须是「真打开一次」。
has_ctty() { { : < /dev/tty; } 2>/dev/null; }

read_input() {  # $1=提示 $2=变量名；返回 1 = 无交互终端
  local _rc=0
  if [[ -t 0 ]]; then
    read -r -p "$1" "$2" || _rc=1
  elif has_ctty; then
    printf '%s' "$1" >&2
    # ⚠️ 2>/dev/null 必须在 < /dev/tty 之前（顺序反了报错会漏到 stderr）
    read -r "$2" 2>/dev/null < /dev/tty || _rc=1
  else
    _rc=1
  fi
  if [[ $_rc -ne 0 ]]; then
    printf -v "$2" ""    # set -u 下确保变量已定义，不崩溃
    return 1
  fi
}

# 安装/更新 vps-tools 管理命令（自身）
# ⚠️ 不能只在「文件不存在」时装：管理命令是 install.sh 的旧副本，本机曾长期停在 1.3.0，
#    而其中的交互判据修复（has_ctty）永远到不了用户机器上（2026-09-18 真机实测：
#    旧副本在无 TTY 下报 "line 238: /dev/tty: No such device or address"）。
#    故「版本不一致」同样刷新（同版本不重写，避免每次无谓下载）。
# 已装管理命令的版本号（读不到则空）
installed_self_version() {  # $1=文件（默认 ${VPS_TOOLS_CMD}）
  local f="${1:-${VPS_TOOLS_CMD}}"
  [[ -r "$f" ]] || return 0
  sed -n 's/^VPS_TOOLS_VERSION="\([^"]*\)".*/\1/p' "$f" 2>/dev/null | head -1
}

# 远端 install.sh 的版本号（读不到则空 = 离线/被墙）
# ref 取 installer_ref()：被 pin 到 tag 的机器只跟该 tag 比对，不会被「最新版」打扰
remote_version() {
  local base; base="$(base_url_for "$(installer_ref)")"
  curl -fsSL --max-time 10 "${base}/install.sh" 2>/dev/null \
    | grep -m1 '^VPS_TOOLS_VERSION=' | cut -d= -f2 | tr -d '"' | tr -d ' '
}

# 文件的 TOOLS 清单指纹（16 位）——用于判断「远端清单是否已变更」
# 比对指纹而非版本号：版本号可能忘记随清单递增（2026-09-19 事故根因）
tools_fp_of() {  # $1=文件
  [[ -r "$1" ]] || return 1
  sed -n '/^TOOLS=(/,/^)/p' "$1" | tr -d ' \t\n' | sha256sum | cut -c1-16
}

# 下载远端 install.sh 到临时文件（成功则输出路径）
fetch_remote_install() {
  local t base
  base="$(base_url_for "$(installer_ref)")"
  t="$(mktemp "${TMPDIR:-/tmp}/vps-tools-remote.XXXXXX")" || return 1
  if curl -fsSL --max-time 30 "${base}/install.sh" -o "$t" 2>/dev/null && [[ -s "$t" ]]; then
    printf '%s\n' "$t"
  else
    rm -f "$t"; return 1
  fi
}

# 本脚本自身的版本（install.sh 直跑时 = 本机要装的版本；副本运行时 = 副本版本）
self_running_version() { installed_self_version "${BASH_SOURCE[0]}"; }

# ============ 自更新后重载 TOOLS 清单（防「进程内数组陈旧」漏装新增文件） ============
# 背景（2026-09-19 anthony_fr 实测事故，与「版本未升版」是两个独立缺陷）：
#   bash 数组在**进程启动时**求值。install_self 把新 install.sh 覆盖到 ${VPS_TOOLS_CMD}
#   并不会让**当前进程**的 TOOLS 重载 → 同进程内接着 install_tool 仍用旧清单 →
#   本轮新增的 lib 文件永远装不上。症状：lib/ 下旧文件全是新版 mtime，唯独缺新增那个，
#   而主脚本已 source 它 → 工具启动即崩：
#     /usr/local/lib/vps-tools/xray-deploy/lib/xhttp3.sh: No such file or directory
# 解法：自更新成功后，从**刚落盘的新副本**里重新抽取 TOOLS 块并 eval 回内存。
#   比 re-exec 更稳（不重启进程、不丢用户当前选择、无循环风险），且覆盖所有调用路径
#   （菜单选 5、install/update 子命令、self-update），无需在每个入口加钩子。
# ⚠️ 但它只重载**数据**，不重载**函数体**——清单引入新语法（如 `源:目标`）后，
#    旧函数体会把新条目读错（2026-10-28 生产事故，详见 reexec_after_self_update 的注释）。
#    故自更新后必须再 exec 自身：本函数保留为「exec 不可用」时的降级路径。
reload_tools_registry() {
  local f="${VPS_TOOLS_CMD}" block
  [[ -r "$f" ]] || return 1
  block="$(sed -n '/^TOOLS=(/,/^)/p' "$f")"
  [[ -n "$block" ]] || return 1
  eval "$block" || return 1          # 内容来自本仓库自身，与 exec 它同等可信
  local nv
  nv="$(installed_self_version "$f")"
  [[ -n "$nv" ]] && VPS_TOOLS_VERSION="$nv"
  return 0
}

# ============ 自更新落盘后 re-exec：函数体必须与 TOOLS 清单同源 ============
# 背景（2026-10-28 Ubuntu 生产机实测，reload_tools_registry 的第二次同类事故）：
#   reload_tools_registry() 只重载**数据**（TOOLS 数组），不重载**代码**（函数体）。
#   旧副本（v1.14.0 时期）自更新到 v1.17.0 后拿到新清单，但函数体还是旧的 →
#   清单末尾的共享文件条目 `lib/core.sh:lib/core.sh`（v1.16.0 才引入的「源:目标」语法）
#   被旧代码整串拼进 URL → raw.githubusercontent.com/.../lib/core.sh:lib/core.sh → 404。
#   更糟：旧版失败分支是 `rm -rf $dest`（没有 .new 暂存、没有备份），
#   把**已装好的**工具目录一起删了，而文案写的是「已回滚」。
#   症状：一长串「已安装附加文件」之后突然 404，随后工具命令消失。
# 解法：落盘成功后 exec 自身，数据与代码永远同源，新语法不会再被旧函数体误读。
#   防循环：exec 时注入 VPS_TOOLS_REEXEC=1；新进程靠 VPS_TOOLS_SKIP_SELF_UPDATE=1
#   跳过自更新检查（省一次远端探测，也不会误报「已是最新」）。
#   可观测：打印「重新载入新版本」——出现这行就说明函数体已经换新。
reexec_after_self_update() {
  if [[ "${SELF_UPDATED:-0}" != "1" ]]; then
    return 0
  fi
  if [[ -n "${VPS_TOOLS_REEXEC:-}" ]]; then
    log_warn "已 re-exec 过仍检测到更新，跳过（防循环）；如异常请手动重跑 ${VPS_TOOLS_CMD##*/}"
    return 0
  fi
  if [[ ! -x "${VPS_TOOLS_CMD}" ]]; then
    log_warn "新副本不可执行（${VPS_TOOLS_CMD}），本次继续用当前代码；建议手动重跑"
    return 0
  fi
  log_info "管理命令已更新，重新载入新版本后继续（函数体与工具清单同源）"
  export VPS_TOOLS_REEXEC=1
  export VPS_TOOLS_SKIP_SELF_UPDATE=1
  # 整包缓存也带过去：新进程能命中 .ok 缓存，不必为同一 ref 再拉一次 tarball
  if [[ -n "${TARBALL_ROOT:-}" ]]; then
    export VPS_TOOLS_TARBALL_ROOT="$TARBALL_ROOT"
  fi
  exec "${VPS_TOOLS_CMD}" "${ORIG_ARGS[@]}"
}

# 安装/更新 vps-tools 管理命令（自身）
#
# ⚠️⚠️ 版本比对必须用【远端版本】做基准，不能用「本脚本的版本常量」——
#   从已装副本 /usr/local/bin/vps-tools 运行时，$VPS_TOOLS_VERSION 与
#   installed_self_version() 读的是同一个文件 → 恒等 → 报「已是最新」，
#   **永远不会下载远端新版**（用户反馈「菜单选 5 无法更新自身」的真根因，
#   复现见 verify-install-selfupdate.sh：副本 1.3.0 恒报已最新，远端 1.7.0 拉不下来）。
install_self() {
  # re-exec 后的新进程已被上一代确认过「已是最新」，跳过检查：
  # 省掉一次多余的远端探测，也不会再打印「已是最新」误导调用方
  if [[ -n "${VPS_TOOLS_SKIP_SELF_UPDATE:-}" ]]; then
    return 0
  fi
  [[ $EUID -eq 0 ]] || return 1
  local cur remote running cur_fp remote_fp
  local ref base explicit=0
  ref="$(installer_ref)"
  base="$(base_url_for "$ref")"
  # 用户显式指定 ref（--ref 仅 self-update 生效 / VPS_TOOLS_REF 全局）→ 允许降级（回滚语义）
  if [[ -n "$ENV_REF" || ( "$ACTION" == "self-update" && -n "$CLI_REF" ) ]]; then
    explicit=1
  fi
  cur="$(installed_self_version)"
  running="$(self_running_version)"
  remote="$(remote_version)"
  cur_fp="$(tools_fp_of "${VPS_TOOLS_CMD}" 2>/dev/null || true)"

  # 远端版本不可得（离线/被墙）→ 无法判断，不盲目下载；由调用方决定是否继续
  if [[ -z "$remote" ]]; then
    log_warn "无法获取远端版本（离线或网络受限），跳过管理命令更新检查"
    return 2
  fi

  # 「已装副本 == 远端」的判定不能只看版本号：
  # ⚠️ 2026-09-19 事故——远端改了 TOOLS（新增 lib/xhttp3.sh）但**忘了升版本号**，
  #    已装副本 v1.8.0 == 远端 v1.8.0 → 旧逻辑报「已是最新」→ 永不下载 →
  #    运行中的旧清单陈旧 → 新增文件永远装不上，而主脚本已 source 它 → 启动即崩。
  # 故必须**同时比对 TOOLS 清单指纹**：版本相同但清单变了，照样要拉取。
  if [[ -n "$cur" && "$cur" == "$remote" ]]; then
    # ⚠️ 不能用 `fetch_remote_install | xargs tools_fp_of`：xargs 无法调用 shell 函数
    #    （会 exec 失败 → remote_fp 空 → 误判「已是最新」，本次踩过）
    local rf=""
    rf="$(fetch_remote_install 2>/dev/null || true)"
    [[ -n "$rf" ]] && remote_fp="$(tools_fp_of "$rf" 2>/dev/null || true)"
    [[ -n "$rf" ]] && rm -f "$rf"
    if [[ -z "$remote_fp" || -z "$cur_fp" || "$remote_fp" == "$cur_fp" ]]; then
      log_info "管理命令已是最新（v${cur}）: ${VPS_TOOLS_CMD}"
      record_installer_ref "$ref"
      return 0
    fi
    log_warn "版本同为 v${cur}，但远端工具清单已变更（${cur_fp} → ${remote_fp}）——继续更新"
  fi

  # 本机正在运行的 install.sh 比远端还新 → 不用远端覆盖自己（防降级）
  # 例外：用户显式 --ref 指定版本时允许降级（回滚到旧版本是合法诉求）
  if [[ $explicit -eq 0 ]] && ver_gt "$running" "$remote"; then
    log_warn "本机版本 v${running} 高于远端 v${remote}，不覆盖（跳过）"
    log_warn "  如需回滚到指定版本: sudo vps-tools self-update --ref <tag>"
    return 0
  fi

  mkdir -p "$(dirname "${VPS_TOOLS_CMD}")"   # curl 写文件前先建目录（防 curl 23）
  local tmp="${VPS_TOOLS_CMD}.tmp.$$"
  # 优先复用整包快照（本次运行已拉过则 0 次请求；未拉过则 1 次请求拿整包）
  local got_ok=0
  if ensure_tarball "$ref" && [[ -n "$TARBALL_SRC" && -f "${TARBALL_SRC}/install.sh" ]]; then
    cp "${TARBALL_SRC}/install.sh" "$tmp" 2>/dev/null && got_ok=1
  fi
  if [[ $got_ok -eq 0 ]] && ! curl -fsSL --max-time 60 "${base}/install.sh" -o "$tmp"; then
    rm -f "$tmp"
    log_warn "下载失败，管理命令保持原样: ${VPS_TOOLS_CMD}"
    return 1
  fi
  # 落盘前校验：下载内容必须是合法的 install.sh（防半截文件/错误页面覆盖可用命令）
  local got
  got="$(installed_self_version "$tmp")"
  if [[ -z "$got" ]]; then
    rm -f "$tmp"
    log_err "下载内容不是有效的 install.sh（无版本号），拒绝覆盖 ${VPS_TOOLS_CMD}"
    return 1
  fi
  chmod +x "$tmp"
  mv -f "$tmp" "${VPS_TOOLS_CMD}"
  record_installer_ref "$ref"
  # 立刻重载 TOOLS 清单：本进程后续的 install_tool 必须用新清单，
  # 否则本轮新增的 lib 文件会被漏装（2026-09-19 事故）
  reload_tools_registry || log_warn "重载工具清单失败，本次安装可能漏装新增文件"
  if [[ -n "$cur" ]]; then
    log_info "已更新管理命令: ${VPS_TOOLS_CMD}（v${cur} → v${got}）"
  else
    log_info "已安装管理命令: ${VPS_TOOLS_CMD}（v${got}，直接运行 vps-tools 进入管理）"
  fi
  # 写后复核（不信自报）
  local after; after="$(installed_self_version)"
  if [[ "$after" != "$got" ]]; then
    log_err "更新后复核失败：磁盘版本为 ${after:-空}（期望 ${got}）"
    return 1
  fi
  # 只有复核通过才置位：调用方据此决定是否 re-exec（见 reexec_after_self_update）
  SELF_UPDATED=1
  return 0
}

# ============ 交互式工具选择 ============
pick_tools_menu() {  # $1=动作 install|update|uninstall
  local action="$1" i=1 line sel mark
  echo "可用工具（输入编号多选，逗号分隔；0=全部；q=返回；* = 已安装）:"
  for line in "${TOOLS[@]}"; do
    mark=" "
    [[ -d "${INSTALL_DIR}/$(tool_field "$line" 1)" ]] && mark="*"
    echo "  $i) $(tool_field "$line" 1)  ($(tool_field "$line" 2)) ${mark}"
    i=$((i+1))
  done
  read_input "选择: " sel || { log_warn "无交互终端，已取消"; return 1; }
  local -a picks=() p
  case "${sel,,}" in
    ""|q) return 0 ;;
    0)
      for line in "${TOOLS[@]}"; do
        case "$action" in
          install|update) install_tool "$line" ;;
          uninstall)      uninstall_tool "$line" ;;
        esac
      done
      ;;
    *)
      IFS=', ' read -r -a picks <<<"$sel"
      for p in "${picks[@]}"; do
        if [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= ${#TOOLS[@]} )); then
          line="${TOOLS[$((p-1))]}"
          case "$action" in
            install|update) install_tool "$line" ;;
            uninstall)      uninstall_tool "$line" ;;
          esac
        else
          log_err "无效选择: $p"
        fi
      done
      ;;
  esac
}

interactive_menu() {
  # root 时确保 vps-tools 管理命令就位且为当前版本（管道方式首次运行也生效；
  # 旧版本副本会在无 TTY 下报 /dev/tty 错，故版本不一致也要刷新）
  if [[ $EUID -eq 0 ]]; then
    install_self || true   # 非 root / 下载失败不阻塞菜单
    reexec_after_self_update   # 有更新则换新进程（函数体与清单同源），不返回
  fi
  # 启动检查更新（离线/同版本静默，不阻塞菜单）
  check_update || true
  while true; do
    echo
    local iref pin=""
    iref="$(installer_ref)"
    [[ "$iref" != "$DEFAULT_REF" ]] && pin="，ref: ${iref}"
    echo "===== vps-tools 管理（v${VPS_TOOLS_VERSION}${pin}）====="
    echo "  1) 安装工具（选择）"
    echo "  2) 更新工具（选择）"
    echo "  3) 卸载工具（选择）"
    echo "  4) 查看工具"
    echo "  5) 更新 vps-tools 自身"
    echo "  0) 退出"
    read_input "请选择 [0-5]: " choice || { log_warn "无交互终端，已退出"; break; }
    case "${choice:-0}" in
      1) pick_tools_menu install ;;
      2) pick_tools_menu update ;;
      3) pick_tools_menu uninstall ;;
      4) list_tools ;;
      5)
        if ! install_self; then
          log_warn "自更新未完成，可用管道方式强制刷新:"
          log_warn "  curl -sSL ${BASE_URL}/install.sh | sudo bash"
        fi
        ;;
      0) break ;;
      *) log_warn "无效选择" ;;
    esac
  done
}

# ============ 主流程 ============
main() {
  # 原始参数：自更新后 re-exec 要原样重放（见 reexec_after_self_update）
  ORIG_ARGS=("$@")
  # 参数解析：支持 --ref <tag> / --ref=<tag>（可出现在任意位置，其余按位置参数）
  local -a pos=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ref)   CLI_REF="${2:-}"; shift; [[ $# -gt 0 ]] && shift ;;
      --ref=*) CLI_REF="${1#*=}"; shift ;;
      *)       pos+=("$1"); shift ;;
    esac
  done
  local action="${pos[0]:-menu}"
  local tool="${pos[1]:-}"
  ACTION="$action"

  # ref 校验：防止拼出意外 URL（空格/引号/路径穿越）
  if [[ -n "$CLI_REF" ]] && ! ref_valid "$CLI_REF"; then
    log_err "非法 ref: ${CLI_REF}（只允许字母数字与 . _ / -，如 v1.14.0、vps-backup-v1.4.0、main）"
    return 1
  fi
  if [[ -n "$ENV_REF" ]] && ! ref_valid "$ENV_REF"; then
    log_err "非法 VPS_TOOLS_REF: ${ENV_REF}"
    return 1
  fi

  case "$action" in
    menu)
      interactive_menu
      ;;
    -v|--version|-V)
      echo "vps-tools ${VPS_TOOLS_VERSION}"
      ;;
    -h|--help)
      cat <<EOF
vps-tools ${VPS_TOOLS_VERSION} — vps-tools 管理工具

用法:
  vps-tools                    进入交互式管理菜单
  vps-tools install [工具]     安装工具（无参 = 交互式选择）
  vps-tools update  [工具]     更新工具
  vps-tools uninstall [工具]   卸载工具
  vps-tools list               查看已安装/可用的工具（含已装版本与 ref）
  vps-tools self-update        更新 vps-tools 自身
  vps-tools -v, --version      显示版本号
  vps-tools -h, --help         显示本帮助

版本坐标（ref = 分支名或 tag 名）:
  --ref <tag>                  本次操作从该 ref 取文件（工具操作只影响该工具）
  self-update --ref <tag>      把安装器自身切到指定版本（回滚）
  环境变量 VPS_TOOLS_REF=<tag> 全局覆盖（工具与安装器都从该 ref 取）
  示例:
    vps-tools install vps-backup --ref vps-backup-v1.4.0   # 装/回滚到 1.4.0
    vps-tools update vps-backup --ref main                 # 回到最新
    vps-tools self-update --ref v1.13.0                    # 安装器回滚

可用工具: ${TOOLS[*]//|*|*|*|*/}
EOF
      ;;
    install|update)
      # root 检测：非 root 明确提示（管道方式无法自动 sudo 重执行，统一引导）
      if [[ $EUID -ne 0 ]]; then
        local hint_ref="$DEFAULT_REF"
        [[ -n "$tool" ]] && hint_ref="$(tool_ref "$tool")"
        log_err "需要 root 权限（安装目标 ${INSTALL_DIR} 和 ${CONFIG_DIR} 需 root 写入）。"
        log_err "推荐管道方式（自动以 root 运行）："
        echo "    curl -sSL $(base_url_for "$hint_ref")/install.sh | sudo bash -s -- ${action}${tool:+ ${tool}}${CLI_REF:+ --ref ${CLI_REF}}"
        log_err "或本地执行：sudo bash install.sh ${action}${tool:+ ${tool}}${CLI_REF:+ --ref ${CLI_REF}}"
        exit 1
      fi
      install_self || true   # 管理命令与工具一起保持最新
      reexec_after_self_update   # 有更新则用新代码重跑本命令，不返回
      if [[ -n "$tool" ]]; then
        local line
        if line=$(find_tool "$tool"); then
          install_tool "$line"
        else
          log_err "未知工具: ${tool}"; list_tools; return 1
        fi
      elif [[ "$action" == "install" ]] && ( [[ -t 0 ]] || has_ctty ); then
        # 无参 + 可交互 → 交互式选择（不静默装全部）
        pick_tools_menu install
      else
        log_err "未指定工具且无交互终端。用法: ${0##*/} ${action} <tool>"
        list_tools
        return 1
      fi
      ;;
    uninstall)
      if [[ -z "$tool" ]]; then
        log_err "用法: $0 uninstall <tool>"; list_tools; return 1
      fi
      local line
      if line=$(find_tool "$tool"); then
        uninstall_tool "$line"
      else
        log_err "未知工具: ${tool}"; list_tools; return 1
      fi
      ;;
    list)
      list_tools
      ;;
    self-update)
      # 帮助里已列出的子命令，此前未实现（2026-09-18 补）
      if [[ $EUID -ne 0 ]]; then
        log_err "需要 root 权限。请用: sudo ${0##*/} self-update"
        exit 1
      fi
      install_self || { log_err "self-update 失败"; return 1; }
      reexec_after_self_update   # 更新成功则重跑 self-update（新进程报「已是最新」）
      ;;
    *)
      log_err "未知动作: ${action}（install / update / uninstall / list / self-update）"
      list_tools
      return 1
      ;;
  esac
}

main "$@"
