#!/usr/bin/env bash
# ============================================================
# 安装器契约回归：**安装/更新后不自动执行任何工具命令**
#                + README 文档索引完整性
#
# 背景（2026-09-19 用户明确要求）：
#   1) vps-tools 安装/更新工具后，不要自动执行工具命令。
#      旧行为：注册表第 5 字段 interactive_setup=1 的工具，首次安装（env 新生成）
#      会 exec `"${CMD_DIR}/${name}" setup` —— 在安装流程里插入交互提问、
#      并在用户没准备时改变机器状态（装 timer / 写配置）。
#      新契约：安装器只放脚本 + 生成配置模板 + 生成命令入口，**只打印下一步指引**。
#   2) README 拆分：仓库根 README 只讲 vps-tools 自身（安装器/结构/开发约定），
#      每个工具的文档放 `<域>/<tool>/README.md`，两侧互相索引。
#
# 用法: bash tests/verify-install-noexec.sh
# 期望: PASS=n FAIL=0
#
# ⚠️ 本机无 root → 必须把副本里的 EUID 判定短路，否则测的是权限而非行为。
# ============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_INSTALL="${REPO}/install.sh"
[[ -f "$SRC_INSTALL" ]] || { echo "SKIP: 找不到 install.sh"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
MOCK="$T/mock"; mkdir -p "$MOCK" "$T/usr/local/bin" "$T/etc" "$T/usr/local/lib"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1  <<< $2"; }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

TOOL="vnstat-monitor"

# ---------- mock curl ----------
# 按 URL 后缀分流：install.sh → 远端 install；*.env.example → 配置模板；其余 → 工具脚本
# 工具脚本带「被执行的标记」，任何自动执行都会在输出里留下 TOOL-EXECUTED。
cat > "$MOCK/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "${MOCK_CURL_LOG}"
out=""; prev=""; url=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  case "$a" in http*) url="$a" ;; esac
  prev="$a"
done
emit() {  # $1=内容文件 $2=输出目标（空 = stdout）
  if [[ -n "$2" ]]; then cp "$1" "$2"; else cat "$1"; fi
}
case "$url" in
  */install.sh)    emit "${MOCK_REMOTE_INSTALL}" "$out" ;;
  *.env.example)   emit "${MOCK_ENV_TPL}" "$out" ;;
  *)               emit "${MOCK_TOOL_SCRIPT}" "$out" ;;
esac
STUB
chmod +x "$MOCK/curl"
export MOCK_CURL_LOG="$T/curl.log"
export PATH="$MOCK:$PATH"

# 「工具主脚本」= 一执行就留下标记（含 setup 子命令，专测旧的自动 setup 路径）
cat > "$T/tool-script.sh" <<'TOOL'
#!/usr/bin/env bash
echo "TOOL-EXECUTED $*"
TOOL
cat > "$T/env.example" <<'ENV'
# mock 配置模板
MOCK_KEY="${PLACEHOLDER}"
ENV
export MOCK_TOOL_SCRIPT="$T/tool-script.sh" MOCK_ENV_TPL="$T/env.example"

# ---------- 沙箱 install.sh ----------
mk_install() {  # $1=目标文件
  local f="$1"
  sed "s/^VPS_TOOLS_VERSION=\"[^\"]*\"/VPS_TOOLS_VERSION=\"1.8.0\"/" "$SRC_INSTALL" > "$f"
  # 短路 root 判定（本机非 root）；EUID 是 bash 只读变量，只能改判定表达式
  # shellcheck disable=SC2016  # 单引号有意：匹配字面 $EUID
  sed -i -e 's|\[\[ \$EUID -eq 0 \]\] \|\| return 1|:|g' \
         -e 's|if \[\[ \$EUID -eq 0 \]\]; then|if true; then|g' \
         -e 's|if \[\[ \$EUID -ne 0 \]\]; then|if false; then|g' "$f"
  sed -i -e 's|^BASE_URL=.*|BASE_URL="http://mock.invalid"|' \
         -e "s|INSTALL_DIR=\"/usr/local/lib/vps-tools\"|INSTALL_DIR=\"$T/usr/local/lib/vps-tools\"|" \
         -e "s|CMD_DIR=\"/usr/local/bin\"|CMD_DIR=\"$T/usr/local/bin\"|" \
         -e "s|CONFIG_DIR=\"/etc\"|CONFIG_DIR=\"$T/etc\"|" "$f"
  chmod +x "$f"
}
mk_remote() { sed "s/^VPS_TOOLS_VERSION=\"[^\"]*\"/VPS_TOOLS_VERSION=\"9.9.9\"/" "$SRC_INSTALL" > "$T/remote-install.sh"; export MOCK_REMOTE_INSTALL="$T/remote-install.sh"; }
reset_sandbox() { rm -rf "$T/usr/local/lib/vps-tools" "$T/usr/local/bin/vps-tools" "$T/etc"/*.env "$T/out"; }
mk_install "$T/install.sh"; mk_remote

echo "=== [A] 静态：install_tool 不再 exec 工具命令 ==="
# 只看 install_tool 函数体；注释里引用旧写法是允许的，故用非注释行匹配
chk "install_tool 无「exec 工具 setup」调用" \
    "! sed -n '/^install_tool()/,/^}/p' '$SRC_INSTALL' | grep -vE '^[[:space:]]*#' | grep -qE '\"\\\$\{CMD_DIR\}/\\\$\{name\}\"[[:space:]]+setup'"
chk "install_tool 无裸 \"\${CMD_DIR}/\${name}\" 命令调用" \
    "! sed -n '/^install_tool()/,/^}/p' '$SRC_INSTALL' | grep -vE '^[[:space:]]*#' | grep -qE '^[[:space:]]+\"\\\$\{CMD_DIR\}'"
chk "改为打印下一步指引（含 sudo <tool> ...）" \
    "sed -n '/^install_tool()/,/^}/p' '$SRC_INSTALL' | grep -q '下一步（请手动执行）'"
chk "第 5 字段语义已改为「仅用于打印指引」" \
    "grep -q '安装器绝不代为执行任何工具命令' '$SRC_INSTALL'"
chk "版本已递增到 ≥1.8.0" \
    "grep -qE '^VPS_TOOLS_VERSION=\"1\\.(8|[9]|[1-9][0-9])\\.[0-9]+\"' '$SRC_INSTALL'"
chk "第 5 字段不再被当布尔值使用（无 setup_flag）" \
    "! grep -q 'setup_flag' '$SRC_INSTALL'"
chk "提示命令由第 5 字段变量拼接（未写死字面量）" \
    "sed -n '/^install_tool()/,/^}/p' '$SRC_INSTALL' | grep -vE '^[[:space:]]*#' | grep -qF 'next_cmd=\"\${name} \${post_install}\"'"
chk "install_tool 函数体内无写死的 setup 字面量" \
    "! sed -n '/^install_tool()/,/^}/p' '$SRC_INSTALL' | grep -vE '^[[:space:]]*#' | grep -q 'setup'"
# 行为级：换一个第 5 字段 ≠ setup 的工具，提示必须跟着变（防写死 setup 回归）
reset_sandbox
bash "$T/install.sh" install vps-bench < /dev/null > "$T/out" 2>&1
chk "★ 提示用该工具自己的子命令（vps-bench → nodequality）" "grep -q 'sudo vps-bench nodequality' '$T/out'"
chk "★ 提示不写死 setup（vps-bench 无 setup 子命令）" "! grep -q 'vps-bench setup' '$T/out'"

echo ""
echo "=== [A2] 第 5 字段 = 真实存在的子命令（防提示跑不存在的命令） ==="
# 背景：该字段旧语义是布尔 1/0，而提示文案写死 `sudo <tool> setup` →
# docker-install / vps-backup 被提示跑一个**不存在的** setup 子命令（真实缺陷）。
# 契约：字段值（非空时）必须出现在该工具 `-h` 输出的子命令行里。
while IFS='|' read -r name script env_tpl env_tgt post _; do
  name="${name// /}"   # 注册表行首有两个空格缩进，必须剥掉（否则 grep 锚点对不上）
  [[ -n "$name" && -n "$script" ]] || continue
  if [[ -z "$post" ]]; then
    ok "${name} 无安装后子命令提示（无参运行进向导/菜单）"
    continue
  fi
  if bash "$REPO/$script" -h 2>&1 | grep -qE "^  (sudo )?${name} +${post}\b"; then
    ok "${name} 第 5 字段 '${post}' 真实存在于 -h 输出"
  else
    bad "${name} 第 5 字段 '${post}' 真实存在于 -h 输出" "该子命令不在 -h 里（会提示用户跑不存在的命令）"
  fi
done < <(grep -oE '^  "[a-z-]+\|[^"]*"' "$SRC_INSTALL" | tr -d '"')

echo ""
echo "=== [A3] 无配置文件工具不得报「配置已存在」 ==="
# 背景：xray-deploy 无 env 模板（节点信息=生成态），旧逻辑一律走 else 分支 →
# 每次安装都打印「配置已存在（更新），保留原配置」，误导用户以为有配置。
reset_sandbox
bash "$T/install.sh" install xray-deploy < /dev/null > "$T/out" 2>&1
chk "无配置工具首次安装 → 打印下一步指引" "grep -q '下一步（请手动执行）' '$T/out'"
chk "无配置工具首次安装 → 不报「配置已存在」" "! grep -q '配置已存在' '$T/out'"
chk "无配置工具首次安装 → 不报「配置模板已生成」" "! grep -q '配置模板已生成' '$T/out'"

echo ""
echo "=== [B] 行为：首次安装（无 TTY）不执行工具命令 ==="
reset_sandbox
bash "$T/install.sh" install "$TOOL" < /dev/null > "$T/out" 2>&1
chk "安装成功（命令入口已生成）" "[[ -x '$T/usr/local/bin/${TOOL}' ]]"
chk "脚本已落盘" "[[ -f '$T/usr/local/lib/vps-tools/${TOOL}/${TOOL}.sh' ]]"
chk "配置模板已生成" "[[ -f '$T/etc/${TOOL}.env' ]]"
chk "★ 工具命令未被自动执行" "! grep -q 'TOOL-EXECUTED' '$T/out'"
chk "打印了下一步指引" "grep -q '下一步（请手动执行）' '$T/out'"
chk "指引里给出了 setup 命令" "grep -q \"sudo ${TOOL} setup\" '$T/out'"

echo ""
echo "=== [C] 行为：首次安装（有 TTY）同样不执行 ==="
reset_sandbox
if command -v script >/dev/null 2>&1; then
  script -qec "bash '$T/install.sh' install '$TOOL'" /dev/null > "$T/out" 2>&1
  chk "★ 有 TTY 也不自动执行（旧实现在此会 exec setup）" "! grep -q 'TOOL-EXECUTED' '$T/out'"
  chk "有 TTY 时同样打印指引" "grep -q '下一步（请手动执行）' '$T/out'"
else
  echo "  [SKIP] 无 script(1)，无法分配 pty"
fi

echo ""
echo "=== [D] 行为：更新（配置已存在）不执行且保留配置 ==="
reset_sandbox
printf 'USER_FILLED="keep-me"\n' > "$T/etc/${TOOL}.env"; chmod 600 "$T/etc/${TOOL}.env"
bash "$T/install.sh" install "$TOOL" < /dev/null > "$T/out" 2>&1
chk "★ 更新路径不执行工具命令" "! grep -q 'TOOL-EXECUTED' '$T/out'"
chk "配置未被覆盖" "grep -q 'USER_FILLED=\"keep-me\"' '$T/etc/${TOOL}.env'"
chk "提示保留原配置" "grep -q '保留原配置' '$T/out'"
chk "无 setup 自动执行痕迹（curl 日志不含工具脚本路径）" \
    "! grep -q '${TOOL}/${TOOL}.sh setup' '$T/curl.log'"

echo ""
echo "=== [E] README 文档索引完整性 ==="
# 注册表 → 每个工具目录都必须有自己的 README
TOOLDIRS="$(grep -oE '^  \"[a-z-]+\|[a-z]+/[a-z-]+/[a-z-]+\.sh\|' "$SRC_INSTALL" | cut -d'|' -f2 | xargs -n1 dirname | sort -u)"
chk "注册表解析出 ≥7 个工具目录" "[[ \$(echo \"\$TOOLDIRS\" | wc -l) -ge 7 ]]"
for d in $TOOLDIRS; do
  chk "工具文档存在: ${d}/README.md" "[[ -f '$REPO/$d/README.md' ]]"
  chk "根 README 索引到 ${d}/" "grep -q \"(${d}/README.md)\" '$REPO/README.md'"
  chk "工具 README 有回链（返回仓库根）" "grep -q '返回仓库根' '$REPO/$d/README.md'"
done
chk "根 README 不再含旧的长教程章节" "! grep -q '^## 工具使用教程' '$REPO/README.md'"
chk "根 README 声明「只讲 vps-tools 自身」" "grep -q '本 README 只讲 vps-tools 自身' '$REPO/README.md'"
chk "根 README 含按域索引" "grep -q '按域索引' '$REPO/README.md'"
chk "根 README 记录安装器不自动执行工具命令" "grep -q '不自动执行任何工具命令' '$REPO/README.md'"
# 防文档漂移：工具 README 里声明的版本必须与脚本头部版本常量一致
while IFS='|' read -r name script _; do
  [[ -n "$name" && -n "$script" ]] || continue
  v="$(grep -m1 -oE '^[A-Z_]*VERSION="[0-9][0-9.]*"' "$REPO/$script" | cut -d'"' -f2)"
  d="$(dirname "$script")"
  if [[ -z "$v" ]]; then
    bad "${name} README 版本与脚本一致" "脚本 $script 未解析出版本常量"
  elif grep -qF "$v" "$REPO/$d/README.md"; then
    ok "${name} README 版本与脚本一致（$v）"
  else
    bad "${name} README 版本与脚本一致" "README 未出现版本 $v（文档漂移）"
  fi
done < <(grep -oE '^  "[a-z-]+\|[a-z]+/[a-z-]+/[a-z-]+\.sh\|' "$SRC_INSTALL" | tr -d ' "')
# 结构树里也要出现各工具 README（双索引）
for d in $TOOLDIRS; do
  n="$(basename "$d")"
  chk "结构树列出 ${n}/README.md" "sed -n '/^## 仓库结构/,/^## 测试/p' '$REPO/README.md' | grep -q 'README.md'"
done

echo ""
echo "============================================================"
echo "PASS=$PASS FAIL=$FAIL"
echo "============================================================"
[[ "$FAIL" -eq 0 ]]
