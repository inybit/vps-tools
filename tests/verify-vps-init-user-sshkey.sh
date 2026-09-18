#!/usr/bin/env bash
# ============================================================
# vps-init 回归 harness（mock 环境，无需 root / 真机 / 网络）
#
# 覆盖本次改动：**创建普通用户时为其注入 SSH 公钥**
#   - user 步骤注入公钥（此前只有 ssh 步骤注入 → 用户建好却没钥匙）
#   - 注入后实测复核：内容在不在 / 权限 600 / 属主正确（不信自报）
#   - 无公钥 / 非法公钥 / 复核失败 的降级与报错行为
#   - ssh 步骤复用同一 helper（两处行为不漂移）
#
# 用法: bash tests/verify-vps-init-user-sshkey.sh
# 期望: PASS=n FAIL=0
#
# 设计要点（照 bash-script-testing 技能）：
#   - 断言「喂坏输入 → 看可观测结果」，不 grep 源码字符串冒充行为断言
#   - mock 必须能把代码送到目标分支：useradd 真的建 home、chown 真的记属主，
#     否则 inject_pubkey 的复核分支走不到
#   - stat -c %U 必须 mock：本机非 root，真实 chown 改不了属主，
#     不 mock 会让「属主复核」恒失败（假 FAIL）
# ============================================================
# shellcheck disable=SC2034  # 断言变量经 chk() 的 eval 间接使用
# shellcheck disable=SC2016  # 变异测试的 sed 表达式有意用单引号（匹配字面 $pubkey 等）
set -uo pipefail

REPO="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TOOL_DIR="${REPO}/utils/vps-init"
[[ -f "${TOOL_DIR}/vps-init.sh" ]] || { echo "SKIP: 找不到 vps-init.sh"; exit 0; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MOCK_BIN="${TMP}/bin"; MOCK_STATE="${TMP}/state"; MOCK_ROOT="${TMP}/root"
mkdir -p "$MOCK_BIN" "$MOCK_STATE" "$MOCK_ROOT"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1  <<< $2"; }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

GOOD_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJl3dIeUdNq0mFQqUZ7dQ0mZ0mZ0mZ0mZ0mZ0mZ0mZ0m test@host"
GOOD_KEY2="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQDZ0mZ0mZ0mZ0mZ0mZ0mZ0mZ second@host"

# ---------- mock: 用户数据库 + 属主记录 ----------
# 用户库：一行 = name:uid:gid:homedir
USERDB="${MOCK_STATE}/passwd"
# 预置 root：ssh 步骤的目标用户清单含 root，缺它 getent 取不到家目录 → 误判失败
printf 'root:0:0:%s/root\n' "$MOCK_ROOT" > "$USERDB"
mkdir -p "${MOCK_ROOT}/root"   # root 家目录必须真实存在（inject_pubkey 会 -d 校验）
# 属主库：一行 = path:owner（本机非 root，chown 无法真改 → 用记录模拟）
OWNERDB="${MOCK_STATE}/owners"
: > "$OWNERDB"

cat > "$MOCK_BIN/id" <<'STUB'
#!/usr/bin/env bash
db="${MOCK_STATE}/passwd"
case "${1:-}" in
  -gn) u="$2"; grep -q "^${u}:" "$db" && { echo "$u"; exit 0; }; exit 1 ;;
  -u)  [[ "$1" == "-u" && "${2:-}" == "" ]] && { echo 0; exit 0; } ;;
  "")  echo 0; exit 0 ;;
esac
# id <user>
u="${1:-}"
grep -q "^${u}:" "$db" && exit 0
exit 1
STUB
chmod +x "$MOCK_BIN/id"

cat > "$MOCK_BIN/getent" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "passwd" ]] || exit 2
u="${2:-}"
line="$(grep "^${u}:" "${MOCK_STATE}/passwd" || true)"
[[ -n "$line" ]] || exit 2
IFS=: read -r name uid gid home _ <<< "$line"
echo "${name}:x:${uid}:${gid}::${home}:/bin/bash"
STUB
chmod +x "$MOCK_BIN/getent"

cat > "$MOCK_BIN/useradd" <<'STUB'
#!/usr/bin/env bash
# useradd -m -s /bin/bash <user>
u="${!#}"
echo "${u}:1000:1000:${MOCK_ROOT}/home/${u}" >> "${MOCK_STATE}/passwd"
mkdir -p "${MOCK_ROOT}/home/${u}"
echo "$u" >> "${MOCK_STATE}/useradd.calls"
exit 0
STUB
chmod +x "$MOCK_BIN/useradd"

cat > "$MOCK_BIN/usermod" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${MOCK_STATE}/usermod.calls"
exit 0
STUB
chmod +x "$MOCK_BIN/usermod"

cat > "$MOCK_BIN/chpasswd" <<'STUB'
#!/usr/bin/env bash
cat >> "${MOCK_STATE}/chpasswd.calls"
exit 0
STUB
chmod +x "$MOCK_BIN/chpasswd"

cat > "$MOCK_BIN/chown" <<'STUB'
#!/usr/bin/env bash
# chown user:group path... → 记录属主（本机非 root 无法真改）
spec="${1:-}"; shift || true
owner="${spec%%:*}"
for p in "$@"; do
  printf '%s:%s\n' "$p" "$owner" >> "${MOCK_STATE}/owners"
done
exit 0
STUB
chmod +x "$MOCK_BIN/chown"

cat > "$MOCK_BIN/stat" <<'STUB'
#!/usr/bin/env bash
# 只 mock -c %U（属主）；%a 走真实 stat（chmod 对本机用户有效）
if [[ "${1:-}" == "-c" && "${2:-}" == "%U" ]]; then
  p="${3:-}"
  own="$(grep -F "${p}:" "${MOCK_STATE}/owners" | tail -1 | cut -d: -f2)"
  echo "${own:-${USER}}"
  exit 0
fi
exec /usr/bin/stat "$@"
STUB
chmod +x "$MOCK_BIN/stat"

cat > "$MOCK_BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${MOCK_STATE}/systemctl.calls"
exit 0
STUB
chmod +x "$MOCK_BIN/systemctl"

# sshd：真实 sshd -t 会读 /etc/ssh/sshd_config.d/*（本机权限拒绝）→ 与本次改动无关的假失败。
# 本 harness 只验证「公钥注入」路径，sshd 配置校验不在范围内 → 固定返回成功
cat > "$MOCK_BIN/sshd" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "${MOCK_STATE}/sshd.calls"
exit 0
STUB
chmod +x "$MOCK_BIN/sshd"

export MOCK_STATE MOCK_ROOT
export PATH="${MOCK_BIN}:${PATH}"

# ---------- 载入被测代码（不经 main()，直接调 user_main/ssh_main） ----------
# shellcheck disable=SC1090,SC1091
load_libs() {
  SCRIPT_DIR="$TOOL_DIR"
  export VPS_INIT_STATE_DIR="${TMP}/state-vpsinit"
  export VPS_INIT_ENV_FILE="${TMP}/nonexistent.env"
  export VPS_INIT_CONF_D="${TMP}/sshd_config.d"
  export VPS_INIT_F2B_JAIL="${TMP}/jail.local"
  export VPS_INIT_DROPIN="${VPS_INIT_CONF_D}/50-vps-init.conf"
  # shellcheck source=/dev/null
  . "${TOOL_DIR}/lib/common.sh"
  # shellcheck source=/dev/null
  . "${TOOL_DIR}/lib/sshkey.sh"
  # shellcheck source=/dev/null
  . "${TOOL_DIR}/lib/user.sh"
  # shellcheck source=/dev/null
  . "${TOOL_DIR}/lib/ssh.sh"
}
load_libs

# 重置为「干净机器」
reset_env() {
  # ⚠️ 必须保留 root 条目：ssh 步骤目标用户含 root（清空会让 getent 取不到家目录）
  printf 'root:0:0:%s/root\n' "$MOCK_ROOT" > "$USERDB"
mkdir -p "${MOCK_ROOT}/root"   # root 家目录必须真实存在（inject_pubkey 会 -d 校验）
  : > "$OWNERDB"
  : > "${MOCK_STATE}/useradd.calls" 2>/dev/null || true
  : > "${MOCK_STATE}/usermod.calls" 2>/dev/null || true
  : > "${MOCK_STATE}/chpasswd.calls" 2>/dev/null || true
  rm -rf "${VPS_INIT_STATE_DIR:?}" "${MOCK_ROOT:?}/home" "${MOCK_ROOT:?}/root/.ssh"
  mkdir -p "${MOCK_ROOT}/home" "${MOCK_ROOT}/root"
  unset VPS_INIT_USER VPS_INIT_USER_PASS VPS_INIT_SSH_PUBKEY VPS_INIT_PUBKEY_FILE
  unset VPS_INIT_SKIP_USER VPS_INIT_DISABLE_ROOT
}

# 跑 user_main（stdout→out，stderr→err）
run_user(){ VPS_INIT_YES=1 user_main > "${TMP}/out" 2> "${TMP}/err"; echo $?; }
# shellcheck disable=SC2120  # $1 = 可选 --pubkey 文件路径（本 harness 未用到，保留接口）
run_ssh(){ VPS_INIT_YES=1 ssh_main "${1:-}" > "${TMP}/out" 2> "${TMP}/err"; echo $?; }

echo "=== [A] 核心：创建用户时注入公钥 ==="
reset_env
export VPS_INIT_USER="alice" VPS_INIT_USER_PASS="pw123" VPS_INIT_SSH_PUBKEY="$GOOD_KEY"
RC="$(run_user)"
chk "user 步骤成功退出" "[[ '$RC' == '0' ]]"
chk "用户已创建（useradd 被调用）" "grep -qx 'alice' '${MOCK_STATE}/useradd.calls'"
chk "公钥已写入 authorized_keys" \
    "grep -qF '$GOOD_KEY' '${MOCK_ROOT}/home/alice/.ssh/authorized_keys'"
chk "authorized_keys 权限为 600" \
    "[[ \"\$(/usr/bin/stat -c '%a' '${MOCK_ROOT}/home/alice/.ssh/authorized_keys')\" == '600' ]]"
chk ".ssh 目录权限为 700" \
    "[[ \"\$(/usr/bin/stat -c '%a' '${MOCK_ROOT}/home/alice/.ssh')\" == '700' ]]"
chk "输出报告公钥就绪" "grep -q '公钥已就绪' '${TMP}/err'"

echo ""
echo "=== [B] 幂等：重复执行不产生重复行 ==="
RC="$(run_user)"
chk "第二次执行仍成功" "[[ '$RC' == '0' ]]"
chk "authorized_keys 只有 1 行（未重复追加）" \
    "[[ \$(grep -cF '$GOOD_KEY' '${MOCK_ROOT}/home/alice/.ssh/authorized_keys') -eq 1 ]]"
chk "输出提示已存在" "grep -q '公钥已存在' '${TMP}/err'"

echo ""
echo "=== [C] 追加第二把钥匙（不同公钥 → 保留原有） ==="
export VPS_INIT_SSH_PUBKEY="$GOOD_KEY2"
RC="$(run_user)"
chk "第二次公钥也成功注入" "[[ '$RC' == '0' ]]"
chk "两把钥匙都在（未覆盖）" \
    "grep -qF '$GOOD_KEY' '${MOCK_ROOT}/home/alice/.ssh/authorized_keys' && grep -qF '$GOOD_KEY2' '${MOCK_ROOT}/home/alice/.ssh/authorized_keys'"

echo ""
echo "=== [D] 无公钥：警告但不失败（用户仍创建） ==="
reset_env
export VPS_INIT_USER="bob" VPS_INIT_USER_PASS="pw123"
unset VPS_INIT_SSH_PUBKEY
RC="$(run_user)"
chk "user 步骤仍成功（不因缺公钥而失败）" "[[ '$RC' == '0' ]]"
chk "用户已创建" "grep -qx 'bob' '${MOCK_STATE}/useradd.calls'"
chk "无 authorized_keys（未伪造空文件）" \
    "[[ ! -s '${MOCK_ROOT}/home/bob/.ssh/authorized_keys' ]]"
chk "明确警告只能用密码登录" "grep -q '未提供 SSH 公钥' '${TMP}/err'"
chk "给出补救指引" "grep -q 'vps-init ssh' '${TMP}/err'"

echo ""
echo "=== [E] 非法公钥：报错且不写入 ==="
reset_env
export VPS_INIT_USER="carol" VPS_INIT_USER_PASS="pw123" VPS_INIT_SSH_PUBKEY="not-a-key"
RC="$(run_user)"
chk "报错指出格式不合法" "grep -q '公钥格式不合法' '${TMP}/err'"
chk "未写入任何公钥文件" \
    "[[ ! -s '${MOCK_ROOT}/home/carol/.ssh/authorized_keys' ]]"
chk "用户仍已创建（不回滚用户）" "grep -qx 'carol' '${MOCK_STATE}/useradd.calls'"

echo ""
echo "=== [F] 公钥来源：文件路径（VPS_INIT_SSH_PUBKEY 指向文件） ==="
reset_env
KEYFILE="${TMP}/id_ed25519.pub"
printf '%s\n' "$GOOD_KEY" > "$KEYFILE"
export VPS_INIT_USER="dave" VPS_INIT_USER_PASS="pw123" VPS_INIT_SSH_PUBKEY="$KEYFILE"
RC="$(run_user)"
chk "从文件读取公钥并注入" "[[ '$RC' == '0' ]] && grep -qF '$GOOD_KEY' '${MOCK_ROOT}/home/dave/.ssh/authorized_keys'"

echo ""
echo "=== [G] 公钥来源：VPS_INIT_PUBKEY_FILE ==="
reset_env
export VPS_INIT_USER="erin" VPS_INIT_USER_PASS="pw123"
unset VPS_INIT_SSH_PUBKEY
export VPS_INIT_PUBKEY_FILE="$KEYFILE"
RC="$(run_user)"
chk "VPS_INIT_PUBKEY_FILE 生效" "[[ '$RC' == '0' ]] && grep -qF '$GOOD_KEY' '${MOCK_ROOT}/home/erin/.ssh/authorized_keys'"

echo ""
echo "=== [H] 复核生效：权限被改成 644 → 必须报复核失败 ==="
reset_env
export VPS_INIT_USER="frank" VPS_INIT_USER_PASS="pw123" VPS_INIT_SSH_PUBKEY="$GOOD_KEY"
# 让 inject_pubkey 内部 chmod 600 之后被外部改回 644（模拟 umask/外部干预）
# 手法：把 chmod 包一层，仅在 authorized_keys 上强制 644
cat > "$MOCK_BIN/chmod" <<'STUB'
#!/usr/bin/env bash
if [[ "${2:-}" == *authorized_keys ]]; then
  exec /usr/bin/chmod 644 "$2"
fi
exec /usr/bin/chmod "$@"
STUB
chmod +x "$MOCK_BIN/chmod"
# ⚠️ hash -r 必须调用：bash 会把已执行命令的路径缓存，新加的 mock 文件同名前不被识别
hash -r
RC="$(run_user)"
chk "复核失败 → 明确报错" "grep -q '复核失败.*权限' '${TMP}/err'"
chk "报错含实际权限值" "grep -qE '权限为 644' '${TMP}/err'"
rm -f "$MOCK_BIN/chmod"; hash -r

echo ""
echo "=== [H2] 复核生效：写入后文件被清空 → 必须报内容复核失败 ==="
reset_env
export VPS_INIT_USER="judy" VPS_INIT_USER_PASS="pw123" VPS_INIT_SSH_PUBKEY="$GOOD_KEY"
# chown 在写入之后、复核之前被调用 → 用它模拟「写入后文件被外部清空/覆盖」
cat > "$MOCK_BIN/chown" <<'STUB'
#!/usr/bin/env bash
spec="${1:-}"; shift || true
owner="${spec%%:*}"
for p in "$@"; do
  printf '%s:%s\n' "$p" "$owner" >> "${MOCK_STATE}/owners"
  [[ "$p" == *authorized_keys ]] && : > "$p"   # 清空内容，模拟写入未生效
done
exit 0
STUB
chmod +x "$MOCK_BIN/chown"; hash -r
RC="$(run_user)"
chk "内容复核失败 → 明确报错" "grep -q '复核失败——公钥不在' '${TMP}/err'"
# 恢复正确 mock
cat > "$MOCK_BIN/chown" <<'STUB'
#!/usr/bin/env bash
spec="${1:-}"; shift || true
owner="${spec%%:*}"
for p in "$@"; do printf '%s:%s\n' "$p" "$owner" >> "${MOCK_STATE}/owners"; done
exit 0
STUB
chmod +x "$MOCK_BIN/chown"; hash -r

echo ""
echo "=== [I] 复核生效：属主错误 → 必须报复核失败 ==="
reset_env
export VPS_INIT_USER="grace" VPS_INIT_USER_PASS="pw123" VPS_INIT_SSH_PUBKEY="$GOOD_KEY"
# 让 chown 记录成错误的属主
cat > "$MOCK_BIN/chown" <<'STUB'
#!/usr/bin/env bash
spec="${1:-}"; shift || true
for p in "$@"; do printf '%s:someoneelse\n' "$p" >> "${MOCK_STATE}/owners"; done
exit 0
STUB
chmod +x "$MOCK_BIN/chown"; hash -r
RC="$(run_user)"
chk "复核失败 → 报属主错误" "grep -q '复核失败.*属主' '${TMP}/err'"
chk "报错含实际属主" "grep -qE '属主为 someoneelse' '${TMP}/err'"
# 恢复正确 mock
cat > "$MOCK_BIN/chown" <<'STUB'
#!/usr/bin/env bash
spec="${1:-}"; shift || true
owner="${spec%%:*}"
for p in "$@"; do printf '%s:%s\n' "$p" "$owner" >> "${MOCK_STATE}/owners"; done
exit 0
STUB
chmod +x "$MOCK_BIN/chown"

echo ""
echo "=== [J] ssh 步骤复用同一 helper（行为一致） ==="
reset_env
export VPS_INIT_USER="heidi" VPS_INIT_USER_PASS="pw123"
# 造用户（走 user 步骤，不给公钥）
unset VPS_INIT_SSH_PUBKEY
run_user >/dev/null
chk "前置：用户已建但无 authorized_keys" \
    "[[ ! -s '${MOCK_ROOT}/home/heidi/.ssh/authorized_keys' ]]"
export VPS_INIT_SSH_PUBKEY="$GOOD_KEY" VPS_INIT_SSH_PORT="52322"
# shellcheck disable=SC2119
RC="$(run_ssh)"
chk "root 与 heidi 都注入公钥（ssh 步骤覆盖两个用户）" \
    "grep -qF '$GOOD_KEY' '${MOCK_ROOT}/home/heidi/.ssh/authorized_keys'"
chk "ssh 步骤用同一 helper（复核通过）" "grep -q '公钥已就绪' '${TMP}/err'"

echo ""
echo "=== [K] 空 authorized_keys 不误判为「已有配置」 ==="
reset_env
export VPS_INIT_USER="ivan" VPS_INIT_USER_PASS="pw123"
unset VPS_INIT_SSH_PUBKEY
run_user >/dev/null
# 造一个 0 字节的 authorized_keys（曾有 bug：-e 判定误通过）
mkdir -p "${MOCK_ROOT}/home/ivan/.ssh"; : > "${MOCK_ROOT}/home/ivan/.ssh/authorized_keys"
# shellcheck disable=SC2119
RC="$(run_ssh)"
chk "ssh 步骤拒绝（空文件不算已配置）" "[[ '$RC' != '0' ]]"
chk "报错指明无可用密钥" "grep -q '未提供公钥且无已有的 authorized_keys' '${TMP}/err'"

echo ""
echo "=== [L] 变异测试：每条注入都应让 FAIL>0 ==="
# ⚠️⚠️ 铁律：变异**绝不原地改产品源码**。
#    初版用 `cp 备份 → sed 改真源 → 跑 → cp 还原`，harness 被 Ctrl-C / 超时中断时
#    还原语句没执行，把 `if false; then` 留在了 lib/sshkey.sh（真实发生过，
#    且下一轮跑出的「成功」是假绿——复核被短路了却报通过）。
#    正确做法：把仓库复制到临时目录，只改副本，用 REPO_ROOT 让子进程指向副本。
MUT_ROOT="${TMP}/mut-repo"
mkdir -p "$MUT_ROOT"
cp -a "${REPO}/utils" "${MUT_ROOT}/utils"
cp -a "${REPO}/tests" "${MUT_ROOT}/tests"
MUT_TOOL="${MUT_ROOT}/utils/vps-init"

# shellcheck disable=SC2016  # 下面 sed 表达式有意用单引号：要匹配字面 $pubkey/$mode/$username
mutate_and_expect_fail() {  # $1=描述 $2=sed 表达式 $3=副本内目标文件
  local desc="$1" expr="$2" file="$3"
  cp -a "$file" "${file}.orig"
  sed -i "$expr" "$file"
  # 子进程：REPO_ROOT 指向副本 → 被测代码是变异版，产品源码零接触
  local mout
  mout="$(VPS_INIT_MUTATION_RUN=1 REPO_ROOT="$MUT_ROOT" bash "${MUT_ROOT}/tests/$(basename "$0")" 2>&1 \
          | grep -c '\[FAIL\]' || true)"
  mv -f "${file}.orig" "$file"      # 副本内还原（即使失败也只影响副本）
  if [[ "${mout:-0}" -gt 0 ]]; then
    ok "变异被检出: ${desc}（FAIL=${mout}）"
  else
    bad "变异未被检出: ${desc}" "注入后 FAIL=0"
  fi
}
if [[ "${VPS_INIT_MUTATION_RUN:-0}" != "1" ]]; then
  # shellcheck disable=SC2016  # 单引号有意：sed 表达式里要字面 $pubkey/$mode/$username
  mutate_and_expect_fail "去掉公钥内容复核" \
      's|if ! grep -qF "\$pubkey" "\$authorized" 2>/dev/null; then|if false; then|' \
      "${MUT_TOOL}/lib/sshkey.sh"
  mutate_and_expect_fail "去掉权限复核" \
      's|if \[\[ "\$mode" != "600" \]\]; then|if false; then|' \
      "${MUT_TOOL}/lib/sshkey.sh"
  mutate_and_expect_fail "user 步骤不再注入公钥" \
      's|inject_pubkey "\$username" "\$pubkey"|true|' \
      "${MUT_TOOL}/lib/user.sh"
fi

echo ""
echo "================================================"
echo "PASS=$PASS FAIL=$FAIL"
echo "================================================"
[[ "$FAIL" -eq 0 ]]
