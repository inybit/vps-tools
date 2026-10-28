#!/usr/bin/env bash
# ============================================================
# 自更新后 re-exec 回归（mock curl，离线可跑，无需 root/网络）
#
# 覆盖 2026-10-28 生产事故：Ubuntu 机跑 vps-tools 更新 xray-deploy，
#   一长串「已安装附加文件」后突然 `curl: (22) ... 404`，
#   报错条目是 `lib/core.sh:lib/core.sh`，随后整个 xray-deploy 目录消失。
#
# 根因：install_self 落盘新副本后只调 reload_tools_registry()（重载 TOOLS **数据**），
#   不重载**函数体**。旧副本（v1.14.0 时期，无 ef_src_dst）拿到 v1.17.0 新清单后，
#   把 v1.16.0 才引入的 `源:目标` 条目整串拼进 URL → 404；
#   旧版失败分支还是 `rm -rf $dest`（无 .new 暂存）→ 把已装好的目录一起删了。
#
# 修复：落盘后 exec 自身，数据与代码永远同源。
# 断言口径：远端 install.sh 注入 BODY_MARKER_V2 —— 它只存在于**新函数体**里，
#   出现即证明「跑的是新代码」；旧行为下永远不出现。
#
# 用法: bash tests/verify-install-self-reexec.sh
# 期望: PASS=n FAIL=0
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
# 断言里大量 `sed|grep -q`：grep -q 命中即退 → 上游收 SIGPIPE(141) → pipefail 误判
chk(){ if ( set +o pipefail; eval "$2" ); then ok "$1"; else bad "$1" "$2"; fi; }

# ---------- mock curl（离线，可控失败） ----------
cat > "$MOCK/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "${MOCK_CURL_LOG}"
out=""; prev=""
for a in "$@"; do
  [[ "$prev" == "-o" ]] && out="$a"
  prev="$a"
done
[[ "${MOCK_CURL_FAIL:-0}" == "1" ]] && { echo "curl: (7) Failed to connect" >&2; exit 7; }
if [[ -n "$out" ]]; then cp "${MOCK_REMOTE_INSTALL}" "$out"; else cat "${MOCK_REMOTE_INSTALL}"; fi
STUB
chmod +x "$MOCK/curl"
export MOCK_CURL_LOG="$LOG"
export PATH="$MOCK:$PATH"

# ---------- 生成可非 root 运行的副本（版本可调） ----------
mk_local_cmd() {  # $1=版本 $2=目标文件
  local f="$2"
  sed "s/^VPS_TOOLS_VERSION=\"[^\"]*\"/VPS_TOOLS_VERSION=\"$1\"/" "$SRC_INSTALL" > "$f"
  # 短路 root 判定（测试机可能非 root；判定为假会让所有用例恒红）
  # shellcheck disable=SC2016
  sed -i -e 's|\[\[ \$EUID -eq 0 \]\] \|\| return 1|:|g' \
         -e 's|if \[\[ \$EUID -eq 0 \]\]; then|if true; then|g' \
         -e 's|if \[\[ \$EUID -ne 0 \]\]; then|if false; then|g' "$f"
  sed -i -e 's|^BASE_URL=.*|BASE_URL="http://mock.invalid"|' \
         -e "s|INSTALL_DIR=\"/usr/local/lib/vps-tools\"|INSTALL_DIR=\"$T/usr/local/lib/vps-tools\"|" \
         -e "s|CMD_DIR=\"/usr/local/bin\"|CMD_DIR=\"$T/usr/local/bin\"|" \
         -e "s|CONFIG_DIR=\"/etc\"|CONFIG_DIR=\"$T/etc\"|" "$f"
  chmod +x "$f"
}

mk_remote() {  # $1=版本
  mk_local_cmd "$1" "$T/remote-install.sh"
  # 只在**新函数体**里存在的可观测标记：出现在输出 = 进程确实换了代码
  sed -i '/^install_tool() {/a\  log_info "BODY_MARKER_V2"' "$T/remote-install.sh"
  export MOCK_REMOTE_INSTALL="$T/remote-install.sh"
}

vof(){ sed -n 's/^VPS_TOOLS_VERSION="\([^"]*\)".*/\1/p' "$1" 2>/dev/null | head -1; }

echo "=== [A] 静态：机制存在 ==="
chk "引入 reexec_after_self_update()" "grep -q '^reexec_after_self_update()' '$SRC_INSTALL'"
chk "exec 的是管理命令自身" \
    "sed -n '/^reexec_after_self_update()/,/^}/p' '$SRC_INSTALL' | grep -qF 'exec \"\${VPS_TOOLS_CMD}\"'"
chk "exec 前注入防循环标记 VPS_TOOLS_REEXEC" \
    "sed -n '/^reexec_after_self_update()/,/^}/p' '$SRC_INSTALL' | grep -qF 'export VPS_TOOLS_REEXEC=1'"
chk "exec 前注入 VPS_TOOLS_SKIP_SELF_UPDATE（免二次探测）" \
    "sed -n '/^reexec_after_self_update()/,/^}/p' '$SRC_INSTALL' | grep -qF 'export VPS_TOOLS_SKIP_SELF_UPDATE=1'"
chk "install_self 复核通过后置 SELF_UPDATED=1" \
    "sed -n '/^install_self()/,/^}/p' '$SRC_INSTALL' | grep -q '^  SELF_UPDATED=1$'"
chk "install_self 开头响应 SKIP 标记" \
    "sed -n '/^install_self()/,/^}/p' '$SRC_INSTALL' | grep -q 'VPS_TOOLS_SKIP_SELF_UPDATE'"
chk "main 保存原始参数供重放" "grep -qF 'ORIG_ARGS=(\"\$@\")' '$SRC_INSTALL'"
chk "三个调用点都接了 reexec" \
    "[[ \$(grep -E '^ *reexec_after_self_update' '$SRC_INSTALL' | grep -vc '()') -eq 3 ]]"

echo ""
echo "=== [B] 核心：旧副本自更新后，函数体确实换新 ==="
mk_remote "1.7.0"
mk_local_cmd "1.3.0" "$T/usr/local/bin/vps-tools"
: > "$LOG"
"$T/usr/local/bin/vps-tools" install xray-deploy > "$T/o1" 2>&1 || true
chk "副本已刷到远端版本 1.7.0" "[[ \"\$(vof '$T/usr/local/bin/vps-tools')\" == '1.7.0' ]]"
chk "输出报告「重新载入新版本」" "grep -q '重新载入新版本' '$T/o1'"
chk "跑的是新函数体（BODY_MARKER_V2 出现）" "grep -q 'BODY_MARKER_V2' '$T/o1'"
chk "re-exec 后不再重复探测（无「已是最新」）" "! grep -q '管理命令已是最新' '$T/o1'"
chk "工具确实装上（主脚本存在）" "[[ -f '$T/usr/local/lib/vps-tools/xray-deploy/xray-deploy.sh' ]]"

echo ""
echo "=== [C] 防循环：已在 re-exec 中则不再 exec ==="
mk_remote "1.8.0"
mk_local_cmd "1.3.0" "$T/usr/local/bin/vps-tools"
VPS_TOOLS_REEXEC=1 "$T/usr/local/bin/vps-tools" install xray-deploy > "$T/o2" 2>&1 || true
chk "仍完成落盘（1.8.0）" "[[ \"\$(vof '$T/usr/local/bin/vps-tools')\" == '1.8.0' ]]"
chk "提示跳过防循环" "grep -q '跳过（防循环）' '$T/o2'"
chk "未换进程（无 BODY_MARKER_V2）" "! grep -q 'BODY_MARKER_V2' '$T/o2'"

echo ""
echo "=== [D] 无更新不 exec（幂等） ==="
mk_remote "1.8.0"
mk_local_cmd "1.8.0" "$T/usr/local/bin/vps-tools"
"$T/usr/local/bin/vps-tools" self-update > "$T/o3" 2>&1 || true
chk "不出现「重新载入新版本」" "! grep -q '重新载入新版本' '$T/o3'"
chk "报告「已是最新」" "grep -q '管理命令已是最新' '$T/o3'"
chk "版本不变" "[[ \"\$(vof '$T/usr/local/bin/vps-tools')\" == '1.8.0' ]]"

echo ""
echo "=== [E] 更新失败不 exec（原有安装不受损） ==="
mk_local_cmd "1.3.0" "$T/usr/local/bin/vps-tools"
MOCK_CURL_FAIL=1 "$T/usr/local/bin/vps-tools" self-update > "$T/o4" 2>&1 || true
chk "不出现「重新载入新版本」" "! grep -q '重新载入新版本' '$T/o4'"
chk "命令未被破坏（仍 1.3.0）" "[[ \"\$(vof '$T/usr/local/bin/vps-tools')\" == '1.3.0' ]]"
chk "命令语法完整" "bash -n '$T/usr/local/bin/vps-tools'"
chk "给出失败原因" "grep -qE '无法获取远端版本|下载失败' '$T/o4'"

echo ""
echo "=== [F] 菜单管道：exec 后不死循环 ==="
mk_remote "1.9.0"
mk_local_cmd "1.3.0" "$T/usr/local/bin/vps-tools"
# stdin 被管道占用时 exec 会丢掉已缓冲的剩余行 → 允许菜单提前退出，
# 但**必须**只重载一次（不出现连环 exec）
printf '5\n2\n2\n0\n' | timeout 60 "$T/usr/local/bin/vps-tools" > "$T/o5" 2>&1 || true
chk "「重新载入新版本」只出现 1 次（无 exec 循环）" \
    "[[ \$(grep -c '重新载入新版本' '$T/o5') -eq 1 ]]"
chk "副本已刷到 1.9.0" "[[ \"\$(vof '$T/usr/local/bin/vps-tools')\" == '1.9.0' ]]"

echo ""
echo "=================================================="
echo "PASS=$PASS FAIL=$FAIL"
echo "=================================================="
[[ "$FAIL" -eq 0 ]]
