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
# 特性:
#   - 脚本下载到 /usr/local/lib/vps-tools/<tool>/ 下，与系统文件隔离，卸载干净
#   - 每个工具自动生成命令入口 /usr/local/bin/<tool>，直接以工具名调用
#   - 配置模板首次安装时复制到 /etc/<tool>.env（已存在则不覆盖），真实密钥由用户填写
#   - 定时调度统一用 systemd timer（工具 setup 子命令管理），不使用 crontab
#   - 幂等：重复 install = 覆盖更新
#   - 首次交互运行自动安装管理命令 /usr/local/bin/vps-tools，之后直接 vps-tools 进入菜单
#   - 管道方式（curl | sudo bash）也能交互：stdin 被占用时从 /dev/tty 读取输入
#   - 启动检查更新：交互菜单进入时比对远端版本，有新版本提示（离线静默）

set -euo pipefail

# ============ 版本号（发布新功能时递增，供启动检查用） ============
VPS_TOOLS_VERSION="1.7.2"

# ============ 配置 ============
GH_USER="inybit"
GH_REPO="vps-tools"
GH_BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}"

INSTALL_DIR="/usr/local/lib/vps-tools"   # 脚本库根目录（与命令入口分离）
CONFIG_DIR="/etc"                        # 配置目标目录
CMD_DIR="/usr/local/bin"                 # 命令入口目录
VPS_TOOLS_CMD="${CMD_DIR}/vps-tools"     # 管理命令入口

# ============ 工具注册表 ============
# 每行一个工具: name|script|env_template|env_target|interactive_setup|extra_files
#   name        工具名（install/update/uninstall 参数）
#   script      install.sh 里要下载的主脚本文件名（相对仓库根，按分类目录组织）
#   env_template 配置模板文件名（相对仓库根，可为空 = 无配置）
#   env_target  配置安装目标路径（env_template 为空时忽略）
#   interactive_setup 安装后是否调用交互式 setup（1=是，工具脚本需支持 setup 子命令；
#                     配合 systemd timer 管理定时；无 TTY 时跳过并提示手动运行）
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
  "vnstat-monitor|monitor/vnstat-monitor/vnstat-monitor.sh|monitor/vnstat-monitor/vnstat-monitor.env.example|${CONFIG_DIR}/vnstat-monitor.env|1|"
  "xray-deploy|proxy/xray-deploy/xray-deploy.sh|||0|proxy/xray-deploy/lib/common.sh proxy/xray-deploy/lib/service.sh proxy/xray-deploy/lib/fallback-data.sh proxy/xray-deploy/lib/fallback.sh proxy/xray-deploy/lib/keys.sh proxy/xray-deploy/lib/xray-bin.sh proxy/xray-deploy/lib/registry.sh proxy/xray-deploy/lib/client-mihomo.sh proxy/xray-deploy/lib/client-singbox.sh proxy/xray-deploy/lib/client-ss2022.sh proxy/xray-deploy/lib/inbound.sh proxy/xray-deploy/lib/state.sh proxy/xray-deploy/lib/ss2022.sh proxy/xray-deploy/lib/outbound.sh proxy/xray-deploy/lib/routing.sh proxy/xray-deploy/lib/chain.sh proxy/xray-deploy/lib/chain-info.sh proxy/xray-deploy/lib/proto-wizard.sh proxy/xray-deploy/lib/proto-crud.sh proxy/xray-deploy/lib/proto-edit.sh proxy/xray-deploy/lib/cmd-lifecycle.sh proxy/xray-deploy/lib/cmd-info.sh proxy/xray-deploy/lib/cmd-fallback.sh proxy/xray-deploy/lib/globalping.sh proxy/xray-deploy/lib/usage.sh"
  "vps-init|utils/vps-init/vps-init.sh|utils/vps-init/vps-init.env.example|${CONFIG_DIR}/vps-init.env|0|utils/vps-init/lib/common.sh utils/vps-init/lib/sshkey.sh utils/vps-init/lib/dd.sh utils/vps-init/lib/system.sh utils/vps-init/lib/user.sh utils/vps-init/lib/ssh.sh utils/vps-init/lib/fail2ban.sh utils/vps-init/lib/ufw.sh utils/vps-init/templates/sshd-dropin.conf.tpl utils/vps-init/templates/jail.local.tpl"
  "vps-bench|bench/vps-bench/vps-bench.sh|||0|"
  "docker-install|utils/docker-install/docker-install.sh|utils/docker-install/docker-install.env.example|${CONFIG_DIR}/docker-install.env|1|utils/docker-install/lib/common.sh utils/docker-install/lib/install.sh utils/docker-install/lib/firewall.sh utils/docker-install/lib/firewall-rules.sh utils/docker-install/lib/access.sh utils/docker-install/lib/usage.sh utils/docker-install/lib/lockdown.sh utils/docker-install/lib/ufwdocker.sh"
  "nginx-install|web/nginx-install/nginx-install.sh|web/nginx-install/nginx-install.env.example|${CONFIG_DIR}/nginx-install.env|0|web/nginx-install/lib/common.sh web/nginx-install/lib/keys.sh web/nginx-install/lib/repo.sh web/nginx-install/lib/install.sh web/nginx-install/lib/status.sh web/nginx-install/lib/usage.sh"
  "vps-backup|backup/vps-backup/vps-backup.sh|backup/vps-backup/templates/vps-backup.env.example|${CONFIG_DIR}/vps-backup.env|1|backup/vps-backup/lib/common.sh backup/vps-backup/lib/interact.sh backup/vps-backup/lib/pkg.sh backup/vps-backup/lib/restic.sh backup/vps-backup/lib/exclude.sh backup/vps-backup/lib/paths.sh backup/vps-backup/lib/deps.sh backup/vps-backup/lib/repo.sh backup/vps-backup/lib/backup.sh backup/vps-backup/lib/retention.sh backup/vps-backup/lib/restore.sh backup/vps-backup/lib/remote.sh backup/vps-backup/lib/timer.sh backup/vps-backup/lib/status.sh backup/vps-backup/lib/usage.sh"
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
  local remote
  remote="$(remote_version)"
  [[ -n "$remote" ]] || return 1
  if ver_gt "$remote" "$VPS_TOOLS_VERSION"; then
    log_warn "检测到新版本 vps-tools ${remote}（当前 ${VPS_TOOLS_VERSION}）"
    # ⚠️ 提示顺序很重要：**先给管道方式**。旧副本（< 1.7.1）的「菜单选 5」自身有 bug
    #    （拿副本自己跟自己比版本 → 恒报已最新，永远拉不到新版），
    #    所以对尚未修复的机器，选 5 是无效指引。
    log_warn "更新方式: curl -sSL ${BASE_URL}/install.sh | sudo bash"
    log_warn "  （已装 v1.7.1+ 的机器也可用「菜单选 5 / vps-tools self-update」）"
    return 0
  fi
  return 1
}

# 解析工具注册表行
tool_field() {  # $1=行 $2=字段号(1-5)
  echo "$1" | cut -d'|' -f"$2"
}

find_tool() {  # $1=tool name → 输出注册表行
  local line
  for line in "${TOOLS[@]}"; do
    [[ "$(tool_field "$line" 1)" == "$1" ]] && { echo "$line"; return 0; }
  done
  return 1
}

list_tools() {
  log_info "可用工具:"
  local line
  for line in "${TOOLS[@]}"; do
    echo "  - $(tool_field "$line" 1)  ($(tool_field "$line" 2))"
  done
}

# ============ 核心操作 ============
install_tool() {  # $1=tool line
  local line="$1" name script env_tpl env_tgt setup_flag extra_files
  name=$(tool_field "$line" 1)
  script=$(tool_field "$line" 2)
  env_tpl=$(tool_field "$line" 3)
  env_tgt=$(tool_field "$line" 4)
  setup_flag=$(tool_field "$line" 5)
  extra_files=$(tool_field "$line" 6)

  local dest="${INSTALL_DIR}/${name}"
  local script_dir
  script_dir="$(dirname "$script")"
  # 下载失败回滚：rm -rf 目标必须非空（防 INSTALL_DIR 误展开）
  local dest_rm="${dest:?}"

  mkdir -p "$dest"

  log_info "下载 ${name}: ${BASE_URL}/${script}"
  if ! curl -fsSL --max-time 60 "${BASE_URL}/${script}" -o "${dest}/$(basename "$script")"; then
    log_err "下载失败: ${script}（检查网络或仓库路径）"
    # 清理失败产生的残留目录，避免半成品坏状态
    rm -rf "$dest_rm"
    return 1
  fi
  chmod +x "${dest}/$(basename "$script")"
  log_info "已安装脚本: ${dest}/$(basename "$script")"

  # 附加文件（多文件工具：lib/*.sh、templates/*.tpl 等，主脚本 source 依赖它们）
  local ef ef_rel ef_dest
  for ef in $extra_files; do
    ef_rel="${ef#"$script_dir"/}"     # 剥掉分类前缀，保留工具目录内相对路径
    ef_dest="${dest}/${ef_rel}"
    mkdir -p "$(dirname "$ef_dest")"  # lib/、templates/ 子目录可能不存在（防 curl 23）
    if ! curl -fsSL --max-time 60 "${BASE_URL}/${ef}" -o "$ef_dest"; then
      log_err "下载失败: ${ef}（附加文件，安装不完整，已回滚）"
      rm -rf "$dest"
      return 1
    fi
    case "$ef_rel" in
      *.sh) chmod +x "$ef_dest" ;;
    esac
    log_info "已安装附加文件: ${ef_dest}"
  done

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
      if curl -fsSL --max-time 60 "${BASE_URL}/${env_tpl}" -o "$env_tgt"; then
        chmod 600 "$env_tgt"
        log_info "已生成配置模板: ${env_tgt} —— 请编辑填入真实密钥!"
      else
        log_warn "配置模板下载失败: ${env_tpl}"
      fi
    fi
  fi

  # 交互式 setup：工具自带 setup 子命令（systemd timer 管理等）
  # 仅初次安装 / 卸载重装（env 新生成）触发交互；更新（env 已存在）保留原配置
  if [[ "$setup_flag" == "1" ]]; then
    if [[ "$env_was_created" == "1" ]]; then
      if has_ctty; then
        log_info "${name} 首次安装，进入交互式配置（触发频率等）"
        "${CMD_DIR}/${name}" setup
      else
        log_warn "无交互终端，跳过交互式配置。稍后手动运行: sudo ${name} setup"
      fi
    else
      log_info "${name} 配置已存在（更新），保留原配置。如需修改: sudo ${name} setup"
    fi
  fi

  log_info "${name} 安装完成。"
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
remote_version() {
  curl -fsSL --max-time 10 "${BASE_URL}/install.sh" 2>/dev/null \
    | grep -m1 '^VPS_TOOLS_VERSION=' | cut -d= -f2 | tr -d '"' | tr -d ' '
}

# 本脚本自身的版本（install.sh 直跑时 = 本机要装的版本；副本运行时 = 副本版本）
self_running_version() { installed_self_version "${BASH_SOURCE[0]}"; }

# 安装/更新 vps-tools 管理命令（自身）
#
# ⚠️⚠️ 版本比对必须用【远端版本】做基准，不能用「本脚本的版本常量」——
#   从已装副本 /usr/local/bin/vps-tools 运行时，$VPS_TOOLS_VERSION 与
#   installed_self_version() 读的是同一个文件 → 恒等 → 报「已是最新」，
#   **永远不会下载远端新版**（用户反馈「菜单选 5 无法更新自身」的真根因，
#   复现见 repro-selfupdate.sh：副本 1.3.0 恒报已最新，远端 1.7.0 拉不下来）。
install_self() {
  [[ $EUID -eq 0 ]] || return 1
  local cur remote running
  cur="$(installed_self_version)"
  running="$(self_running_version)"
  remote="$(remote_version)"

  # 远端版本不可得（离线/被墙）→ 无法判断，不盲目下载；由调用方决定是否继续
  if [[ -z "$remote" ]]; then
    log_warn "无法获取远端版本（离线或网络受限），跳过管理命令更新检查"
    return 2
  fi

  # 已装副本 == 远端最新 → 无需动作
  if [[ -n "$cur" && "$cur" == "$remote" ]]; then
    log_info "管理命令已是最新（v${cur}）: ${VPS_TOOLS_CMD}"
    return 0
  fi

  # 本机正在运行的 install.sh 比远端还新 → 不用远端覆盖自己（防降级）
  if ver_gt "$running" "$remote"; then
    log_warn "本机版本 v${running} 高于远端 v${remote}，不覆盖（跳过）"
    return 0
  fi

  mkdir -p "$(dirname "${VPS_TOOLS_CMD}")"   # curl 写文件前先建目录（防 curl 23）
  local tmp="${VPS_TOOLS_CMD}.tmp.$$"
  if ! curl -fsSL --max-time 60 "${BASE_URL}/install.sh" -o "$tmp"; then
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
  fi
  # 启动检查更新（离线/同版本静默，不阻塞菜单）
  check_update || true
  while true; do
    echo
    echo "===== vps-tools 管理（v${VPS_TOOLS_VERSION}）====="
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
  local action="${1:-menu}"
  local tool="${2:-}"

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
  vps-tools list               查看已安装/可用的工具
  vps-tools self-update        更新 vps-tools 自身
  vps-tools -v, --version      显示版本号
  vps-tools -h, --help         显示本帮助

可用工具: ${TOOLS[*]//|*|*|*|*/}
EOF
      ;;
    install|update)
      # root 检测：非 root 明确提示（管道方式无法自动 sudo 重执行，统一引导）
      if [[ $EUID -ne 0 ]]; then
        log_err "需要 root 权限（安装目标 ${INSTALL_DIR} 和 ${CONFIG_DIR} 需 root 写入）。"
        log_err "推荐管道方式（自动以 root 运行）："
        echo "    curl -sSL https://raw.githubusercontent.com/${GH_USER}/${GH_REPO}/${GH_BRANCH}/install.sh | sudo bash -s -- ${action}${tool:+ ${tool}}"
        log_err "或本地执行：sudo bash install.sh ${action}${tool:+ ${tool}}"
        exit 1
      fi
      install_self || true   # 管理命令与工具一起保持最新（旧副本有 /dev/tty 报错缺陷）
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
      ;;
    *)
      log_err "未知动作: ${action}（install / update / uninstall / list / self-update）"
      list_tools
      return 1
      ;;
  esac
}

main "$@"
