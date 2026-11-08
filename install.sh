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
# 版本策略（v1.20.0 起，2026-11-08 用户决定「彻底解耦」）:
#   安装器与所有工具**始终跟 main**，只有整包快照一条安装路径。
#   已移除：--ref / VPS_TOOLS_REF / .ref 版本固定 / self-update 回滚 / 逐文件回退下载。
#   tag 仍随发版打（v<ver> / <tool>-v<ver>），只作发布里程碑与 notes 锚点，不再有
#   「装某个 tag」的语义；要装历史版本请 git checkout 该 tag 后手工跑 install.sh。
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

# ============ 版本号（改本文件时递增，供启动检查与 tag 命名用） ============
# 版本号现在的用途：① 启动检查更新（比对远端 install.sh 的版本）② release tag 命名。
#   改 install.sh（安装器逻辑 / TOOLS 元数据）仍需递增：tag 名唯一，同版本号对应
#   两份内容会让 release 打 tag 失败（隐式守卫）。
# ⚠️ 但**新增/删除工具目录内的文件（lib/、templates/）不再需要升版**：整包快照按目录
#    整拷，TOOLS 第 6 字段只剩跨目录共享文件（2026-11-08 解耦，见上方注释）。
#    回归守卫 tests/verify-install-tools-version-bump.sh 仍盯「TOOLS 块变了必须升版」。
VPS_TOOLS_VERSION="1.20.0"

# ============ 配置 ============
GH_USER="inybit"
GH_REPO="vps-tools"
GH_BRANCH="main"                  # 唯一坐标：安装器与所有工具始终跟 main
GH_ORIGIN="https://raw.githubusercontent.com"
RAW_BASE="${GH_ORIGIN}/${GH_USER}/${GH_REPO}"
DEFAULT_REF="$GH_BRANCH"               # 保留别名（多处拼接 URL 用；值恒为 main）
BASE_URL="${RAW_BASE}/${DEFAULT_REF}"  # 保持变量名，兼容既有测试的 sed 重写

INSTALL_DIR="/usr/local/lib/vps-tools"   # 脚本库根目录（与命令入口分离）
CONFIG_DIR="/etc"                        # 配置目标目录
CMD_DIR="/usr/local/bin"                 # 命令入口目录
VPS_TOOLS_CMD="${CMD_DIR}/vps-tools"     # 管理命令入口

# ============ 下载基址（v1.20.0 起只有 main 一个坐标）============
# 2026-11-08 用户决定「彻底解耦」：移除 --ref / VPS_TOOLS_REF / .ref 版本固定 /
# self-update 回滚 / 逐文件回退下载。理由：安装器与工具的版本坐标一旦存在，
# 就要维护「版本号 ↔ 内容」一一对应（否则 --ref 回滚拿到的东西不确定），
# 结果每次改 install.sh 都被迫升版；而真正需要的只是「装最新的」。
# 代价（用户明确接受）：线上被 main 改坏时无法一键回到上个版本，只能等修。
# tag 仍随发版打，只作发布里程碑；要装历史版本：git checkout <tag> 后手工跑 install.sh。

base_url_for() {  # [ref] 省略 = 默认分支（参数仅为兼容旧调用点保留）
  printf '%s/%s\n' "$RAW_BASE" "${1:-$DEFAULT_REF}"
}

# ============ 整包快照（tarball）下载（v1.20.0 起是唯一安装路径）============
# 逐文件下载的瓶颈是**请求数 × RTT**，不是字节数：每个 curl 都是独立连接，
# TCP+TLS 握手 ≈ 3 RTT。xray-deploy 要 28 次（主脚本 1 + lib 27），
# 200ms RTT 的 VPS 上光握手就 ~17s；而整仓 tar.gz 只有 ~280KB。
# 故一次拉整包、本地解包、按目录整拷工具目录（cp -a）→ 工具目录内的新文件自动带上。
# ⚠️ 逐文件回退路径已移除（v1.20.0，2026-11-08 用户决定）：整包拿不到就报错，
#    逃生办法是手动注入已解包的树：VPS_TOOLS_TARBALL_ROOT=<含 install.sh 的目录>。
SRC_OVERRIDE="${VPS_TOOLS_TARBALL_ROOT:-}"         # 手动注入的已解包仓库根（codeload 不可达时）
TARBALL_ROOT="${VPS_TOOLS_TARBALL_CACHE:-}"        # 本次运行的整包缓存根（mktemp -d）
TARBALL_SRC=""                                    # 最近一次 ensure_tarball 成功的仓库根

# 确保整包已解包。成功 return 0 并设置全局 TARBALL_SRC；失败 return 1（调用方负责报错）。
# ⚠️ 必须**直接调用**，不能写 `src="$(ensure_tarball)"`：命令替换会开子 shell，
#    TARBALL_ROOT / .ok 缓存 / EXIT trap 全落在子 shell 里 —— 子 shell 一退出就触发
#    trap 删掉刚解包的树，父进程拿到的是**已消失的路径** → 整包会被下载两次
#    （2026-10-17 实测踩到）。
ensure_tarball() {
  TARBALL_SRC=""
  # 手动注入优先：VPS_TOOLS_TARBALL_ROOT 指向已解包的仓库根（必须含 install.sh）
  if [[ -n "$SRC_OVERRIDE" && -f "${SRC_OVERRIDE}/install.sh" ]]; then
    TARBALL_SRC="$SRC_OVERRIDE"
    return 0
  fi
  command -v tar >/dev/null 2>&1 || return 1
  local dir root tgz d
  if [[ -z "$TARBALL_ROOT" ]]; then
    TARBALL_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vps-tools-src.XXXXXX")" || return 1
    # 只清理自己创建的临时目录（不碰任何系统目录）
    trap '[[ -n "${TARBALL_ROOT:-}" && -d "${TARBALL_ROOT}" ]] && rm -rf "${TARBALL_ROOT}" || true' EXIT
  fi
  dir="${TARBALL_ROOT}/src"
  if [[ -f "${dir}/.ok" ]]; then
    TARBALL_SRC="$(cat "${dir}/.ok")"
    return 0
  fi
  # 同一运行内已失败过 → 直接失败，避免每个工具都等一次超时
  if [[ -f "${dir}/.failed" ]]; then return 1; fi

  mkdir -p "$dir"
  tgz="${dir}/src.tgz"
  if ! curl -fsSL --max-time 120 \
        "https://codeload.github.com/${GH_USER}/${GH_REPO}/tar.gz/${GH_BRANCH}" \
        -o "$tgz" 2>/dev/null; then
    : > "${dir}/.failed"; rm -f "$tgz"; return 1
  fi
  if ! tar -xzf "$tgz" -C "$dir" 2>/dev/null; then
    : > "${dir}/.failed"; rm -f "$tgz"; return 1
  fi
  rm -f "$tgz"

  # 包内顶层是唯一的 <repo>-<ref>/ 目录；不用 --strip-components（busybox tar 兼容性）
  root=""
  for d in "$dir"/*/; do
    [[ -d "$d" ]] && { root="${d%/}"; break; }
  done
  if [[ -z "$root" || ! -f "${root}/install.sh" ]]; then
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
#   extra_files **只写跨目录共享文件**（`源路径:工具内目标路径`，如 lib/core.sh:lib/core.sh）。
#               工具目录内的 lib/、templates/ 等文件**不再登记**：整包快照按目录整拷
#               （cp -a <工具目录>），新增文件自动带上 → 新增 lib 不必改本文件、
#               不必升 VPS_TOOLS_VERSION（2026-11-08 用户要求「彻底解耦」）。
#               可为空 = 无共享文件。
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
  "xray-deploy|proxy/xray-deploy/xray-deploy.sh|||install|lib/core.sh:lib/core.sh"
  "vps-init|utils/vps-init/vps-init.sh|utils/vps-init/vps-init.env.example|${CONFIG_DIR}/vps-init.env||lib/core.sh:lib/core.sh"
  "vps-bench|bench/vps-bench/vps-bench.sh|||nodequality|"
  "docker-install|utils/docker-install/docker-install.sh|utils/docker-install/docker-install.env.example|${CONFIG_DIR}/docker-install.env||lib/core.sh:lib/core.sh"
  "nginx-install|web/nginx-install/nginx-install.sh|web/nginx-install/nginx-install.env.example|${CONFIG_DIR}/nginx-install.env||lib/core.sh:lib/core.sh"
  "vps-backup|backup/vps-backup/vps-backup.sh|backup/vps-backup/templates/vps-backup.env.example|${CONFIG_DIR}/vps-backup.env||lib/core.sh:lib/core.sh"
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

list_tools() {
  log_info "可用工具:"
  local line name ver
  for line in "${TOOLS[@]}"; do
    name=$(tool_field "$line" 1)
    if [[ -d "${INSTALL_DIR}/${name}" ]]; then
      ver="$(installed_tool_version "$line")"
      echo "  - ${name}  ($(tool_field "$line" 2))  已装 v${ver:-?}"
    else
      echo "  - ${name}  ($(tool_field "$line" 2))"
    fi
  done
}

# ============ 核心操作 ============
install_tool() {  # $1=tool line
  local line="$1" name script env_tpl env_tgt post_install extra_files
  name=$(tool_field "$line" 1)
  script=$(tool_field "$line" 2)
  env_tpl=$(tool_field "$line" 3)
  env_tgt=$(tool_field "$line" 4)
  post_install=$(tool_field "$line" 5)
  extra_files=$(tool_field "$line" 6)

  local dest="${INSTALL_DIR}/${name}"
  local script_dir
  script_dir="$(dirname "$script")"
  # 替换失败回滚：备份/临时目录都由 $dest 派生（防 INSTALL_DIR 误展开）
  local dest_bak="${dest}.bak.$$"
  local dest_new="${dest}.new"

  mkdir -p "$dest"

  # ---- 整包快照：v1.20.0 起是**唯一**安装路径（逐文件回退已移除）----
  local src_root="" ef _src _dst _ok=1
  if ! ensure_tarball || [[ -z "$TARBALL_SRC" || ! -d "${TARBALL_SRC}/${script_dir}" ]]; then
    log_err "整包下载/解包失败（codeload 不可达 / 无 tar / 仓库结构异常）—— 现有安装未改动: ${dest}"
    log_err "  v1.20.0 起已移除逐文件回退。逃生办法：手动下载并解包仓库，然后"
    log_err "  VPS_TOOLS_TARBALL_ROOT=<解包后的仓库根> ${0##*/} install ${name}"
    return 1
  fi
  src_root="$TARBALL_SRC"
  log_info "下载 ${name}: 整包快照"
  # 拷到 .new 并在【替换之前】补齐共享文件：任何一步失败都不动现有安装
  # （旧实现先 rm -rf 旧树再 mv，共享文件失败时既无回滚又留下坏安装）
  if ! cp -a "${src_root}/${script_dir}" "$dest_new" 2>/dev/null; then
    rm -rf "$dest_new" 2>/dev/null || true
    log_err "整包拷贝失败（${src_root}/${script_dir}）—— 现有安装未改动: ${dest}"
    return 1
  fi
  # 跨目录共享文件（如 lib/core.sh:lib/core.sh）：整包拷贝只覆盖工具目录，
  # 源在工具目录之外的文件必须单独拷进来，否则装完 source 缺文件 → 启动即崩
  for ef in $extra_files; do
    IFS=$'\t' read -r _src _dst < <(ef_src_dst "$ef" "$script_dir")
    [[ "$_src" == "$script_dir"/* ]] && continue
    mkdir -p "$(dirname "${dest_new}/${_dst}")"
    if ! cp -a "${src_root}/${_src}" "${dest_new}/${_dst}" 2>/dev/null; then
      log_err "整包缺共享文件: ${_src}（安装不完整；现有安装未改动）"
      _ok=0; break
    fi
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
  chmod +x "${dest}/$(basename "$script")" 2>/dev/null || true
  find "$dest" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true
  log_info "已安装脚本: ${dest}/$(basename "$script")（共 $(find "$dest" -type f | wc -l) 个文件）"

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
      if [[ -f "${src_root}/${env_tpl}" ]] && cp "${src_root}/${env_tpl}" "$env_tgt" 2>/dev/null; then
        chmod 600 "$env_tgt"
        log_info "已生成配置模板: ${env_tgt} —— 请编辑填入真实密钥!"
      else
        log_warn "配置模板缺失: ${env_tpl}（整包内不存在，配置需手工创建: ${env_tgt}）"
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

# 远端 install.sh 的版本号（读不到则空 = 离线/被墙）。坐标恒为 main（v1.20.0）
remote_version() {
  curl -fsSL --max-time 10 "${BASE_URL}/install.sh" 2>/dev/null \
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
  local t
  t="$(mktemp "${TMPDIR:-/tmp}/vps-tools-remote.XXXXXX")" || return 1
  if curl -fsSL --max-time 30 "${BASE_URL}/install.sh" -o "$t" 2>/dev/null && [[ -s "$t" ]]; then
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
  # 整包缓存也带过去：新进程能命中 .ok 缓存，不必再拉一次 tarball
  if [[ -n "${TARBALL_ROOT:-}" ]]; then
    export VPS_TOOLS_TARBALL_CACHE="$TARBALL_ROOT"
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
      return 0
    fi
    log_warn "版本同为 v${cur}，但远端工具清单已变更（${cur_fp} → ${remote_fp}）——继续更新"
  fi

  # 本机正在运行的 install.sh 比远端还新 → 不用远端覆盖自己（防降级）
  # v1.20.0 起没有「按版本回滚」通道，这条只剩「本地开发版别被 main 覆盖」的意义
  if ver_gt "$running" "$remote"; then
    log_warn "本机版本 v${running} 高于远端 v${remote}，不覆盖（跳过）"
    return 0
  fi

  mkdir -p "$(dirname "${VPS_TOOLS_CMD}")"   # curl 写文件前先建目录（防 curl 23）
  local tmp="${VPS_TOOLS_CMD}.tmp.$$"
  # 优先复用整包快照（本次运行已拉过则 0 次请求；未拉过则 1 次请求拿整包）
  # 安装器自身**始终**从 BASE_URL 拉：不复用整包快照 —— 快照可能来自
  # VPS_TOOLS_TARBALL_ROOT 手动注入（本地开发树），用它自更新会把注入的旧副本
  # 当成远端最新，self-update 永远「已是最新」。
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
  # 原始参数：自更新后 re-exec 要原样重放（见 reexec_after_self_update）
  ORIG_ARGS=("$@")
  local -a pos=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      # v1.20.0 移除：显式拒绝而不是当未知参数静默忽略 —— 老脚本/老习惯带 --ref 时
      # 必须立刻看到「这个能力没了」，否则会以为成功钉到了某个版本
      --ref|--ref=*)
        log_err "--ref 已于 v1.20.0 移除：安装器与所有工具始终跟 main（不再支持按版本安装/回滚）。"
        log_err "  如需装历史版本：git checkout <tag> 后手工运行 install.sh"
        return 1
        ;;
      *)       pos+=("$1"); shift ;;
    esac
  done
  local action="${pos[0]:-menu}"
  local tool="${pos[1]:-}"
  # v1.20.0 起 VPS_TOOLS_REF 无效：明确告警而不是静默忽略（否则用户以为钉住了版本）
  if [[ -n "${VPS_TOOLS_REF:-}" ]]; then
    log_warn "VPS_TOOLS_REF=${VPS_TOOLS_REF} 已于 v1.20.0 失效（安装器与工具始终跟 main），已忽略"
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
  vps-tools list               查看已安装/可用的工具（含已装版本）
  vps-tools self-update        更新 vps-tools 自身
  vps-tools -v, --version      显示版本号
  vps-tools -h, --help         显示本帮助

版本策略（v1.20.0 起）:
  安装器与所有工具**始终跟 main**，整包快照是唯一安装路径。
  --ref / VPS_TOOLS_REF / 逐文件回退下载已移除；tag 只作发布里程碑。
  整包下载失败时的逃生: VPS_TOOLS_TARBALL_ROOT=<已解包的仓库根> sudo -E bash install.sh install <tool>

可用工具: ${TOOLS[*]//|*|*|*|*/}
EOF
      ;;
    install|update)
      # root 检测：非 root 明确提示（管道方式无法自动 sudo 重执行，统一引导）
      if [[ $EUID -ne 0 ]]; then
        log_err "需要 root 权限（安装目标 ${INSTALL_DIR} 和 ${CONFIG_DIR} 需 root 写入）。"
        log_err "推荐管道方式（自动以 root 运行）："
        echo "    curl -sSL ${BASE_URL}/install.sh | sudo bash -s -- ${action}${tool:+ ${tool}}"
        log_err "或本地执行：sudo bash install.sh ${action}${tool:+ ${tool}}"
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
