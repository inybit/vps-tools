#!/usr/bin/env bash
# ============================================================
# install.sh 自更新回归（mock curl，离线可跑，无需 root/网络）
#
# 覆盖用户反馈的 bug：「vps-tools 菜单选 5 无法更新自身」。
# 根因：从已装副本运行时，$VPS_TOOLS_VERSION 与 installed_self_version() 读同一个文件
#       → 版本恒等 → 报「已是最新」→ 从不下载远端。
#
# 用法: bash tests/verify-install-selfupdate.sh
# 期望: PASS=n FAIL=0
#
# ⚠️ 本机无 root → 必须把副本里三类 EUID 判定短路，否则测的是权限而非版本逻辑：
#    `[[ $EUID -eq 0 ]] || return 1` / `if [[ $EUID -eq 0 ]]; then` / `if [[ $EUID -ne 0 ]]; then`
# ============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_INSTALL="${REPO}/install.sh"
[[ -f "$SRC_INSTALL" ]] || { echo "SKIP: 找不到 install.sh"; exit 0; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
MOCK="$T/mock"; mkdir -p "$MOCK" "$T/usr/local/bin" "$T/etc"
LOG="$T/curl.log"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1  <<< $2"; }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

# ---------- mock curl（离线，可控失败/垃圾内容） ----------
cat > "$MOCK/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "${MOCK_CURL_LOG}"
out=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  prev="$a"
done
[[ "${MOCK_CURL_FAIL:-0}" == "1" ]] && { echo "curl: (7) Failed to connect" >&2; exit 7; }
if [[ "${MOCK_CURL_GARBAGE:-0}" == "1" ]]; then
  if [[ -n "$out" ]]; then echo "<html>404</html>" > "$out"; else echo "<html>404</html>"; fi
  exit 0
fi
if [[ -n "$out" ]]; then cp "${MOCK_REMOTE_INSTALL}" "$out"; else cat "${MOCK_REMOTE_INSTALL}"; fi
STUB
chmod +x "$MOCK/curl"
export MOCK_CURL_LOG="$LOG"
export PATH="$MOCK:$PATH"

# ---------- 生成「远端 install.sh」（版本可调） ----------
mk_remote() {  # $1=版本
  sed "s/^VPS_TOOLS_VERSION=\"[^\"]*\"/VPS_TOOLS_VERSION=\"$1\"/" "$SRC_INSTALL" > "$T/remote-install.sh"
  export MOCK_REMOTE_INSTALL="$T/remote-install.sh"
}

# ---------- 生成「本机已装副本」 ----------
mk_local_cmd() {  # $1=版本 $2=目标文件
  local f="$2"
  sed "s/^VPS_TOOLS_VERSION=\"[^\"]*\"/VPS_TOOLS_VERSION=\"$1\"/" "$SRC_INSTALL" > "$f"
  # 短路 root 判定（本机非 root）
  # shellcheck disable=SC2016  # 单引号是有意的：要匹配字面 $EUID，不是展开它
  sed -i -e 's|\[\[ \$EUID -eq 0 \]\] \|\| return 1|:|g' \
         -e 's|if \[\[ \$EUID -eq 0 \]\]; then|if true; then|g' \
         -e 's|if \[\[ \$EUID -ne 0 \]\]; then|if false; then|g' "$f"
  # 指向临时路径；BASE_URL 任意（mock curl 不看 URL）
  sed -i -e 's|^BASE_URL=.*|BASE_URL="http://mock.invalid"|' \
         -e "s|INSTALL_DIR=\"/usr/local/lib/vps-tools\"|INSTALL_DIR=\"$T/usr/local/lib/vps-tools\"|" \
         -e "s|CMD_DIR=\"/usr/local/bin\"|CMD_DIR=\"$T/usr/local/bin\"|" \
         -e "s|CONFIG_DIR=\"/etc\"|CONFIG_DIR=\"$T/etc\"|" "$f"
  chmod +x "$f"
}

vof(){ sed -n 's/^VPS_TOOLS_VERSION="\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1; }

echo "=== [A] 静态：修复要点存在 ==="
chk "install_self 不再拿本脚本版本当比对基准" \
    "! sed -n '/^install_self()/,/^}/p' '$SRC_INSTALL' | grep -q 'VPS_TOOLS_VERSION'"
chk "引入 remote_version()（远端版本查询）" "grep -q '^remote_version()' '$SRC_INSTALL'"
chk "install_self 用远端版本做基准" \
    "sed -n '/^install_self()/,/^}/p' '$SRC_INSTALL' | grep -qF 'remote=\"\$(remote_version)\"'"
chk "下载前先写临时文件（防半截覆盖）" \
    "sed -n '/^install_self()/,/^}/p' '$SRC_INSTALL' | grep -qF 'tmp=\"\${VPS_TOOLS_CMD}.tmp'"
chk "有下载内容合法性校验" \
    "sed -n '/^install_self()/,/^}/p' '$SRC_INSTALL' | grep -q '不是有效的 install.sh'"
chk "有写后复核" \
    "sed -n '/^install_self()/,/^}/p' '$SRC_INSTALL' | grep -q '更新后复核失败'"
chk "有防降级（本机高于远端不覆盖）" \
    "sed -n '/^install_self()/,/^}/p' '$SRC_INSTALL' | grep -q '高于远端'"

echo ""
echo "=== [B] 核心回归：旧副本 → 菜单选 5 ==="
mk_remote "1.7.0"
mk_local_cmd "1.3.0" "$T/usr/local/bin/vps-tools"
chk "前置：副本为旧版 1.3.0" "[[ \"\$(vof '$T/usr/local/bin/vps-tools')\" == '1.3.0' ]]"
printf '5\n0\n' | "$T/usr/local/bin/vps-tools" > "$T/out" 2>&1
chk "选 5 后副本刷到远端版本 1.7.0" "[[ \"\$(vof '$T/usr/local/bin/vps-tools')\" == '1.7.0' ]]"
chk "输出报告版本变化（v1.3.0 → v1.7.0）" "grep -q '已更新管理命令.*1.3.0 → v1.7.0' '$T/out'"
chk "不再出现「已是最新」误导信息" "! grep -q '管理命令已是最新' '$T/out'"

echo ""
echo "=== [C] self-update 子命令同样生效 ==="
mk_local_cmd "1.3.0" "$T/usr/local/bin/vps-tools"
"$T/usr/local/bin/vps-tools" self-update > "$T/out" 2>&1
chk "self-update 后刷到 1.7.0" "[[ \"\$(vof '$T/usr/local/bin/vps-tools')\" == '1.7.0' ]]"

echo ""
echo "=== [D] 幂等：已是最新则不重复下载 ==="
: > "$LOG"
"$T/usr/local/bin/vps-tools" self-update > "$T/out" 2>&1
chk "未发生文件下载（curl 无 -o 调用 = 未重复下载）" "! grep -q -- '-o ' '$LOG'"
chk "版本保持不变" "[[ \"\$(vof '$T/usr/local/bin/vps-tools')\" == '1.7.0' ]]"

echo ""
echo "=== [E] 防降级：本机版本高于远端 ==="
mk_local_cmd "2.0.0" "$T/usr/local/bin/vps-tools"
"$T/usr/local/bin/vps-tools" self-update > "$T/out" 2>&1
chk "不覆盖（仍为 2.0.0）" "[[ \"\$(vof '$T/usr/local/bin/vps-tools')\" == '2.0.0' ]]"
chk "给出跳过原因" "grep -q '高于远端' '$T/out'"

echo ""
echo "=== [F] 失败路径：远端不可达 ==="
mk_local_cmd "1.3.0" "$T/usr/local/bin/vps-tools"
MOCK_CURL_FAIL=1 "$T/usr/local/bin/vps-tools" self-update > "$T/out" 2>&1 || true
chk "原有命令未被破坏（仍为 1.3.0）" "[[ \"\$(vof '$T/usr/local/bin/vps-tools')\" == '1.3.0' ]]"
chk "命令仍可执行（语法完整）" "bash -n '$T/usr/local/bin/vps-tools'"
chk "给出离线提示（不静默）" "grep -qE '无法获取远端版本|下载失败' '$T/out'"

echo ""
echo "=== [G] 失败路径：远端返回非法内容（防错误页覆盖可用命令） ==="
mk_local_cmd "1.3.0" "$T/usr/local/bin/vps-tools"
# 远端「版本查询」返回正常，但下载正文无版本号（模拟半截文件 / 错误页）
cat > "$MOCK/curl" <<'STUB2'
#!/usr/bin/env bash
echo "curl $*" >> "${MOCK_CURL_LOG}"
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
if [[ -n "$out" ]]; then echo "#!/bin/bash (truncated)" > "$out"; else cat "${MOCK_REMOTE_INSTALL}"; fi
STUB2
chmod +x "$MOCK/curl"
"$T/usr/local/bin/vps-tools" self-update > "$T/out" 2>&1 || true
chk "拒绝覆盖（仍为 1.3.0）" "[[ \"\$(vof '$T/usr/local/bin/vps-tools')\" == '1.3.0' ]]"
chk "给出拒绝原因" "grep -q '不是有效的 install.sh' '$T/out'"
chk "不残留 .tmp 文件" "! ls '$T/usr/local/bin/' | grep -q '\\.tmp'"

echo ""
echo "=== [H] 安装工具时顺带刷新陈旧副本 ==="
# 恢复原始 mock curl（[G] 段替换过；不恢复会连带让工具下载也失败 → 假 FAIL）
cat > "$MOCK/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "${MOCK_CURL_LOG}"
out=""; prev=""
for a in "$@"; do [[ "$prev" == "-o" ]] && out="$a"; prev="$a"; done
if [[ -n "$out" ]]; then cp "${MOCK_REMOTE_INSTALL}" "$out"; else cat "${MOCK_REMOTE_INSTALL}"; fi
STUB
chmod +x "$MOCK/curl"
mk_remote "1.7.0"
mk_local_cmd "1.3.0" "$T/usr/local/bin/vps-tools"
# 造一个可安装的工具目标（用仓库里的真实工具，走 mock curl 下载）
"$T/usr/local/bin/vps-tools" install vps-bench > "$T/out" 2>&1 || true
chk "install 动作顺带把副本刷到 1.7.0" "[[ \"\$(vof '$T/usr/local/bin/vps-tools')\" == '1.7.0' ]]"

echo ""
echo "================================================"
echo "PASS=$PASS FAIL=$FAIL"
echo "================================================"
[[ "$FAIL" -eq 0 ]]
