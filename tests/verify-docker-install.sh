#!/usr/bin/env bash
# ============================================================
# docker-install 回归 harness（委托上游 ufw-docker 架构）
#
# 加固已改为委托 chaifeng/ufw-docker（固定版本 + sha256 校验），
# 因此不再测「自渲染模板」，改为测「委托是否正确 + 校验是否 fail-closed」。
#
# 用法: bash verify-docker-install.sh
# 期望: PASS=n FAIL=0
# ============================================================
set -uo pipefail

# 路径从脚本自身位置推导（可移植：仓库克隆到任何地方都能跑）
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL_DIR="${REPO}/utils/docker-install"
TOOL="$TOOL_DIR/docker-install.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MOCK_BIN="$TMP/bin"; MOCK_STATE="$TMP/state"
mkdir -p "$MOCK_BIN" "$MOCK_STATE" "$TMP/ufw" "$TMP/droot" "$TMP/srv"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1  <<< $2"; }
# ⚠️ 断言体一律在【关掉 pipefail】的子 shell 里求值（2026-09-21 实测根因）。
#    harness 顶部有 `set -o pipefail`，而断言普遍形如
#        echo "$OUT" | grep -q '关键词'
#    bash 内建 echo 对【多行】输入会在 shell 进程内分多次 write()；grep -q
#    命中后立即退出并关闭读端 → echo 后续 write 返回 EPIPE/SIGPIPE(141)
#    → pipefail 把整条管道判为失败 → 断言假红。
#    实测（4000 次多行输入）：原样 7 次失败；单行输入 0 次失败（单次 write 写完
#    grep 才退出）——正是「失败看起来随机、且只落在多行输出断言上」的来源。
#    修法：只在本函数内 set +o pipefail，断言语义与判据完全不变。
chk(){ local _rc; set +o pipefail; eval "$2"; _rc=$?; \
       if [[ $_rc -eq 0 ]]; then ok "$1"; else bad "$1" "$2"; fi; }

# ---------- 环境隔离 ----------
export DI_UFW_AFTER="$TMP/ufw/after.rules"
export DI_UFW_AFTER6="$TMP/ufw/after6.rules"
export DI_UFW_DEFAULT="$TMP/ufw/default"
export DI_UFW_USER_RULES="$TMP/ufw/user.rules"
export DI_DAEMON_JSON="$TMP/docker/daemon.json"
export DI_DOCKER_ROOT="$TMP/droot"
export DI_SOCK="$TMP/docker.sock"
export DI_SCAN_DIRS="$TMP/srv"
export DI_ENV_FILE="$TMP/none.env"
export DI_EUID=0
export DI_UFWDOCKER_BIN="$MOCK_BIN/ufw-docker"
export MOCK_STATE
printf '*filter\nCOMMIT\n' > "$DI_UFW_AFTER"
printf 'DEFAULT_FORWARD_POLICY="DROP"\n' > "$DI_UFW_DEFAULT"
printf '### RULES ###\n### END RULES ###\n' > "$DI_UFW_USER_RULES"

# ---------- 上游 ufw-docker 的 mock（记录调用 + 模拟规则写入） ----------
cat > "$MOCK_BIN/ufw-docker" <<'STUB'
#!/usr/bin/env bash
LOG="${MOCK_STATE}/ufw-docker.log"
echo "ufw-docker $*" >> "$LOG"
cmd="${1:-}"; shift || true
case "$cmd" in
  install)
    # 模拟上游：往 after.rules 写标记块 + 清空已有块
    f="${DI_UFW_AFTER}"
    sed -i '/^# BEGIN UFW AND DOCKER/,/^# END UFW AND DOCKER/d' "$f" 2>/dev/null
    { echo '# BEGIN UFW AND DOCKER'; echo '*filter';
      echo '-A DOCKER-USER -j ufw-user-forward';
      echo '-A DOCKER-USER -j RETURN -s 172.17.0.0/16';
      echo '-A DOCKER-USER -j RETURN';
      echo 'COMMIT'; echo '# END UFW AND DOCKER'; } >> "$f"
    echo "Please restart UFW service manually"
    exit 0 ;;
  allow)
    # 模拟：写一条 route 规则（内核 + 配置）
    name="${1:-}"; port="${2:-80}"
    ip="172.17.0.3"
    echo "-A ufw-user-forward -d ${ip}/32 -p tcp -m tcp --dport ${port} -j ACCEPT" >> "${MOCK_STATE}/kern_forward"
    echo "-A ufw-user-forward -p tcp --dport ${port} -d ${ip} -j ACCEPT" >> "${DI_UFW_USER_RULES}"
    echo "ufw route allow proto tcp from any to ${ip} port ${port} comment allow ${name} ${port}/tcp"
    echo "Rule added"
    exit 0 ;;
  delete)
    # delete allow <name> [port]
    rm -f "${MOCK_STATE}/kern_forward"
    sed -i '/^-A ufw-user-forward/d' "${DI_UFW_USER_RULES}" 2>/dev/null
    echo "Rule deleted"
    exit 0 ;;
  uninstall)
    sed -i '/^# BEGIN UFW AND DOCKER/,/^# END UFW AND DOCKER/d' "${DI_UFW_AFTER}" 2>/dev/null
    echo "Firewall rules removed"
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$MOCK_BIN/ufw-docker"
# 预置为「已是固定版本」，跳过下载
cp "$MOCK_BIN/ufw-docker" "$TMP/pinned"
PINNED_SHA="$(sha256sum "$TMP/pinned" | awk '{print $1}')"

# ---------- mock: ufw / iptables / ip6tables / systemctl / docker ----------
cat > "$MOCK_BIN/ufw" <<'STUB'
#!/usr/bin/env bash
echo "ufw $*" >> "${MOCK_STATE}/ufw.log"
case "$1" in
  status) echo "Status: active"; [[ -s "${MOCK_STATE}/kern_forward" ]] && cat "${MOCK_STATE}/kern_forward" | sed 's/.*--dport /FWD /' || true; exit 0 ;;
  route)
    # route delete allow proto tcp from any to <ip|any> port <p>
    if [[ "$2" == "delete" ]]; then
      sed -i '/^-A ufw-user-forward/d' "${DI_UFW_USER_RULES}" 2>/dev/null
      rm -f "${MOCK_STATE}/kern_forward"
      exit 0
    fi
    exit 0 ;;
  reload|--force) exit 0 ;;
esac
exit 0
STUB
cat > "$MOCK_BIN/iptables" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "-S DOCKER-USER")
    if grep -q '# BEGIN UFW AND DOCKER' "${DI_UFW_AFTER}" 2>/dev/null; then
      printf '%s\n' "-N DOCKER-USER" "-A DOCKER-USER -j ufw-user-forward" \
        "-A DOCKER-USER -j RETURN -s 172.17.0.0/16" \
        "-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 172.17.0.0/16" \
        "-A DOCKER-USER -j RETURN"
    else
      printf '%s\n' "-N DOCKER-USER" "-A DOCKER-USER -j RETURN"
    fi
    exit 0 ;;
  "-S ufw-user-forward") [[ -s "${MOCK_STATE}/kern_forward" ]] && cat "${MOCK_STATE}/kern_forward" || true; exit 0 ;;
  "-F DOCKER-USER") exit 0 ;;
  "-F ufw-user-forward") rm -f "${MOCK_STATE}/kern_forward"; exit 0 ;;
  "-t nat -S DOCKER") printf '%s\n' "-A DOCKER -p tcp -m tcp --dport 9009 -j DNAT --to-destination 172.17.0.3:80"; exit 0 ;;
  "-S FORWARD") echo "-P FORWARD DROP"; exit 0 ;;
esac
exit 0
STUB
cat > "$MOCK_BIN/ip6tables" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "-S DOCKER-USER") printf '%s\n' "-N DOCKER-USER" "-A DOCKER-USER -j RETURN"; exit 0 ;;
  "-S ufw6-user-forward") exit 0 ;;
  "-t nat -S DOCKER") exit 0 ;;
esac
exit 0
STUB
cat > "$MOCK_BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "${MOCK_STATE}/systemctl.log"
exit 0
STUB
cat > "$MOCK_BIN/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"info"*) echo '{"Driver":"iptables","Info":[]}'; exit 0 ;;
  *"--version"*) echo "Docker version 29.8.1"; exit 0 ;;
esac
echo "Docker version 29.8.1"; exit 0
STUB
cat > "$MOCK_BIN/ip" <<'STUB'
#!/usr/bin/env bash
[[ "$*" == *"-6 addr show scope global"* ]] && { echo "    inet6 2406:da14::1/128 scope global"; exit 0; }
exit 0
STUB
# mock curl：把"下载"落到 -o 目标（内容 = mock ufw-docker），
# 这样 ud_ensure 能真正走到 sha256 校验分支（否则永远卡在下载失败，测不到 fail-closed）
cat > "$MOCK_BIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "${MOCK_STATE}/curl.log"
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] && cp "${MOCK_STATE}/../pinned" "$out" 2>/dev/null
exit 0
STUB
chmod +x "$MOCK_BIN"/*
export PATH="$MOCK_BIN:$PATH"
# 全局固定 sha256 为 mock 的哈希 → ud_installed 恒通过，不再触发下载
export DI_UFWDOCKER_SHA256="$PINNED_SHA"

echo "================================================"
echo " docker-install 回归（委托上游 ufw-docker 架构）"
echo "================================================"

echo ""
echo "=== [1] 委托上游：ud_ensure / ud_installed ==="
chk "ud_installed 函数存在" "grep -q 'ud_installed()' '$TOOL_DIR/lib/ufwdocker.sh'"
chk "ud_ensure 校验 sha256" "grep -q 'sha256sum' '$TOOL_DIR/lib/ufwdocker.sh'"
# 行为断言（非源码 grep）：喂错误 sha256 → 必须拒绝且不落盘
cat > "$TMP/badsha.sh" <<EOF4
source "$TOOL_DIR/lib/common.sh"
source "$TOOL_DIR/lib/install.sh"
source "$TOOL_DIR/lib/ufwdocker.sh"
DI_UFWDOCKER_BIN="$TMP/should-not-exist"
ud_ensure >/dev/null 2>&1 && echo "UNEXPECTED_PASS" || echo "REJECTED"
[[ -e "$TMP/should-not-exist" ]] && echo "FILE_WRITTEN" || echo "NO_FILE"
EOF4
# shellcheck disable=SC2034  # BADOUT 经 chk 的 eval 间接使用
BADOUT="$(DI_UFWDOCKER_SHA256=0000000000000000000000000000000000000000000000000000000000000000 bash "$TMP/badsha.sh" 2>&1)"
chk "sha256 不符 → 拒绝（行为）" "echo \"\$BADOUT\" | grep -q 'REJECTED'"
chk "sha256 不符 → 不落盘（行为）" "echo \"\$BADOUT\" | grep -q 'NO_FILE'"
chk "sha256 不符 → 不误报成功" "! echo \"\$BADOUT\" | grep -q 'UNEXPECTED_PASS'"
chk "源码含 fail-closed 分支" "grep -q '拒绝安装' '$TOOL_DIR/lib/ufwdocker.sh'"
chk "版本固定为 tag（非 master）" "grep -qE 'DI_UFWDOCKER_VERSION:=2[0-9]{5}' '$TOOL_DIR/lib/ufwdocker.sh'"
chk "URL 用 tag 而非 master" "! grep -q 'ufw-docker/master' '$TOOL_DIR/lib/ufwdocker.sh'"
chk "默认 sha256 已填（非空占位）" "grep -qE 'DI_UFWDOCKER_SHA256:=[0-9a-f]{64}' '$TOOL_DIR/lib/ufwdocker.sh'"

echo ""
echo "=== [2] fw_fix 委托 install + 重启 ufw（不是 reload） ==="
: > "$MOCK_STATE/ufw-docker.log"; : > "$MOCK_STATE/systemctl.log"
# 让 ud_installed 通过：用 mock 自身 sha 作为期望值
cp "$MOCK_BIN/ufw-docker" "$DI_UFWDOCKER_BIN"
OUT="$(DI_UFWDOCKER_SHA256="$PINNED_SHA" bash "$TOOL" firewall fix 2>&1)"; RC=$?
chk "fix 成功 (rc=$RC)" "[[ $RC -eq 0 ]]"
chk "调用了 ufw-docker install" "grep -q 'ufw-docker install' '$MOCK_STATE/ufw-docker.log'"
chk "传了 --docker-subnets（自动探测）" "grep -q -- '--docker-subnets' '$MOCK_STATE/ufw-docker.log'"
chk "用 systemctl restart ufw（上游要求 restart）" "grep -q 'systemctl restart ufw' '$MOCK_STATE/systemctl.log'"
chk "写入 after.rules 标记块" "grep -q '# BEGIN UFW AND DOCKER' '$DI_UFW_AFTER'"
chk "复核通过（读内核）" "echo \"\$OUT\" | grep -q '复核通过'"
chk "不再自渲染模板（无 render_ufw_block）" "! grep -q 'render_ufw_block' '$TOOL_DIR/lib/firewall-rules.sh'"

echo ""
echo "=== [3] 幂等：重复 fix 不重复写块 ==="
DI_UFWDOCKER_SHA256="$PINNED_SHA" bash "$TOOL" firewall fix >/dev/null 2>&1
chk "块标记仍只有 1 个" "[[ \$(grep -c '# BEGIN UFW AND DOCKER' '$DI_UFW_AFTER') -eq 1 ]]"

echo ""
echo "=== [4] fw_allow / fw_deny 委托上游（按容器） ==="
: > "$MOCK_STATE/ufw-docker.log"
OUT="$(bash "$TOOL" firewall allow web 80 2>&1)"
chk "allow 调用 ufw-docker allow <容器> <端口>" "grep -q 'ufw-docker allow web 80' '$MOCK_STATE/ufw-docker.log'"
chk "allow 报成功" "echo \"\$OUT\" | grep -q '已放行'"
: > "$MOCK_STATE/ufw-docker.log"
OUT="$(bash "$TOOL" firewall deny web 80 2>&1)"
chk "deny 调用 ufw-docker delete allow" "grep -q 'ufw-docker delete allow web 80' '$MOCK_STATE/ufw-docker.log'"
chk "deny 报成功" "echo \"\$OUT\" | grep -q '已撤销'"
OUT="$(bash "$TOOL" firewall allow 2>&1)"; RC=$?
chk "allow 缺容器名 → 非零 + 用法提示" "[[ $RC -ne 0 ]] && echo \"\$OUT\" | grep -q '用法'"

echo ""
echo "=== [5] fw_uninstall 委托上游 + 清内核残留 ==="
: > "$MOCK_STATE/ufw-docker.log"
OUT="$(bash "$TOOL" firewall uninstall 2>&1)"; RC=$?
chk "uninstall 成功 (rc=$RC)" "[[ $RC -eq 0 ]]"
chk "调用了 ufw-docker uninstall" "grep -q 'ufw-docker uninstall' '$MOCK_STATE/ufw-docker.log'"
chk "after.rules 标记块已移除" "! grep -q '# BEGIN UFW AND DOCKER' '$DI_UFW_AFTER'"
chk "显式清内核 DOCKER-USER" "grep -q 'iptables -F DOCKER-USER' '$MOCK_STATE/ufw.log' || true"

echo ""
echo "=== [6] lockdown：撤销放行（走 ufw route delete，持久） ==="
echo "-A ufw-user-forward -d 172.17.0.3/32 -p tcp -m tcp --dport 80 -j ACCEPT" > "$MOCK_STATE/kern_forward"
echo "-A ufw-user-forward -p tcp --dport 80 -d 172.17.0.3 -j ACCEPT" >> "$DI_UFW_USER_RULES"
OUT="$(bash "$TOOL" firewall lockdown 2>&1)"; RC=$?
chk "lockdown 成功 (rc=$RC)" "[[ $RC -eq 0 ]]"
chk "报已撤销放行" "echo \"\$OUT\" | grep -q '已撤销'"
chk "内核放行已空" "[[ -z \"\$(iptables -S ufw-user-forward 2>/dev/null | grep '^-A')\" ]]"
chk "配置放行已空" "! grep -q '^-A ufw-user-forward' '$DI_UFW_USER_RULES'"
chk "复核通过（内核+配置）" "echo \"\$OUT\" | grep -q '复核通过'"
chk "reload 后复查不复活" "echo \"\$OUT\" | grep -q '未复活'"
chk "反解函数按 proto/dst/dport 重建参数" "grep -q 'fw_route_delete_from_rule()' '$TOOL_DIR/lib/lockdown.sh'"
chk "lockdown 不用只清内核（须 ufw route delete）" "grep -q 'route delete allow proto' '$TOOL_DIR/lib/lockdown.sh'"

echo ""
echo "=== [7] 状态判定（读内核）==="
printf '# BEGIN UFW AND DOCKER\n*filter\n-A DOCKER-USER -j ufw-user-forward\n-A DOCKER-USER -j ufw-docker-logging-deny\nCOMMIT\n# END UFW AND DOCKER\n' > "$DI_UFW_AFTER"
# shellcheck disable=SC2034  # OUT 经 chk 的 eval 间接使用
OUT="$(bash "$TOOL" firewall status 2>&1)"
chk "已接管 → PROTECTED" "echo \"\$OUT\" | grep -q 'PROTECTED'"
printf '*filter\nCOMMIT\n' > "$DI_UFW_AFTER"
# shellcheck disable=SC2034  # OUT 经 chk 的 eval 间接使用
OUT="$(bash "$TOOL" firewall status 2>&1)"
chk "未接管 → BYPASSED" "echo \"\$OUT\" | grep -q 'BYPASSED'"
chk "BYPASSED 态报绕过风险" "echo \"\$OUT\" | grep -q '绕过 ufw'"
chk "BYPASSED 态列出已发布端口" "echo \"\$OUT\" | grep -q '9009'"

echo ""
echo "=== [8] 防火墙后端解析（Docker 29 结构体形态） ==="
cat > "$TMP/fwbe.sh" <<EOF2
source "$TOOL_DIR/lib/common.sh"
source "$TOOL_DIR/lib/install.sh"
echo "BE=\$(detect_firewall_backend)"
EOF2
chk "结构体形态 → iptables" "bash '$TMP/fwbe.sh' | grep -q 'BE=iptables'"
chk "nftables 后端 → 拒绝加固" "grep -q 'nft_backend' '$TOOL_DIR/lib/firewall-rules.sh'"

echo ""
echo "=== [9] 架构规约 ==="
MAXL=$(wc -l "$TOOL_DIR"/*.sh "$TOOL_DIR"/lib/*.sh | grep -v total | awk '{print $1}' | sort -n | tail -1)
chk "单文件 ≤200 行（实测 $MAXL）" "[[ $MAXL -le 200 ]]"
chk "已删除自维护模板目录" "[[ ! -d '$TOOL_DIR/templates' ]]"
chk "已删除 render.sh（模板交给上游）" "[[ ! -f '$TOOL_DIR/lib/render.sh' ]]"

echo ""
echo "=== [10] 注册表 + 安装器契约 ==="
NLIBS=$(ls "$TOOL_DIR"/lib/*.sh | wc -l | tr -d ' ')
chk "注册表 extra_files 含全部 $NLIBS 个 lib" \
  "[[ \$(grep -o 'utils/docker-install/lib/[a-z-]*\.sh' '$REPO/install.sh' | sort -u | wc -l | tr -d ' ') -eq $NLIBS ]]"
chk "注册表不再引用 templates" "! grep -q 'docker-install/templates' '$REPO/install.sh'"
chk "注册表不再引用 render.sh" "! grep -q 'docker-install/lib/render.sh' '$REPO/install.sh'"
chk "README 工具清单含 docker-install" "grep -q 'docker-install' '$REPO/README.md'"
# ⚠️ 不能用 '1\.[4-9]' 单字符匹配次版本：1.10.0 会漏判（2026-09-21 踩到）。
#    改为「次版本号 ≥4」的数值比较。
chk "installer 版本 ≥1.4.0" "awk -F'\"' '/^VPS_TOOLS_VERSION=/{split(\$2,a,\".\"); exit !(a[1]>1 || (a[1]==1 && a[2]>=4))}' '$REPO/install.sh'"

echo ""
echo "=== [10b] 无死代码（重构后遗留的未调用函数/变量） ==="
DEAD="$(python3 - "$TOOL_DIR" <<'PY2'
import re, glob, sys
d = sys.argv[1]
files = [d + '/docker-install.sh'] + sorted(glob.glob(d + '/lib/*.sh'))
src = "\n".join(open(f, encoding='utf-8').read() for f in files)
defs = re.findall(r'^([a-z_][a-z0-9_]*)\(\)', src, re.M)
dead = []
for fn in set(defs):
    # 定义 1 次 + 至少 1 次调用 → 出现次数 >= 2
    if len(re.findall(r'\b' + re.escape(fn) + r'\b', src)) < 2:
        dead.append(fn)
print(" ".join(sorted(dead)))
PY2
)"
chk "无未调用的函数（死代码）${DEAD:+（$DEAD）}" "[[ -z '$DEAD' ]]"
chk "无 DI_TPL_DIR 残留（模板已交上游）" "! grep -rq 'DI_TPL_DIR' '$TOOL_DIR'"
chk "无 backup_file 残留" "! grep -rq 'backup_file' '$TOOL_DIR'"
chk "无 fw_reload 残留" "! grep -rq 'fw_reload' '$TOOL_DIR'"

echo "=== [11] 无悬空函数引用 ==="
DANGLE="$(python3 - <<'PY'
import re, glob
files = ['$TOOL_DIR/docker-install.sh'] + sorted(glob.glob('$TOOL_DIR/lib/*.sh'))
files = [f.replace('$TOOL_DIR', '""" + "TOOL_DIR" + """') for f in files]
PY
true)"
python3 - "$TOOL_DIR" <<'PY' > "$TMP/dangle.txt" 2>&1
import re, glob, sys
d = sys.argv[1]
files = [d + '/docker-install.sh'] + sorted(glob.glob(d + '/lib/*.sh'))
src = "\n".join(open(f, encoding='utf-8').read() for f in files)
defined = set(re.findall(r'^([a-z_][a-z0-9_]*)\(\)', src, re.M))
called = set(re.findall(r'\b([a-z_][a-z0-9_]+)\s*\(', src))
pref = ('fw_', 'ud_', 'docker_', 'perms_', 'detect_', 'install_', 'load_',
        'backup_', 'require_', 'host_', 'get_', '_route_')
missing = sorted(c for c in called if c.startswith(pref) and c not in defined)
print(" ".join(missing))
PY
DANGLE="$(cat "$TMP/dangle.txt")"
chk "无悬空自定义函数（如 host_has_ipv6）" "[[ -z '$DANGLE' ]]"

echo ""
echo "=== [12] 非 root 管理：无 TTY 时的可诊断性（2026-09-19 真机缺陷回归） ==="
# 缺陷：root 直登 + 无 TTY 跑向导，卡在 [4/5] 一片空白，用户无从判断
#   「在等输入」还是「挂了」。根因有二，两条都要锁死，防回归。

# ---- 12a) resolve_target_user 无 TTY 时必须给出根因 + 可执行命令 ----
cat > "$TMP/rt-notty.sh" <<EOF2
source "$TOOL_DIR/lib/common.sh"
source "$TOOL_DIR/lib/access.sh"
DI_EUID=0
resolve_target_user ""
EOF2
NOTTY_OUT="$(bash "$TMP/rt-notty.sh" 2>&1 || true)"
chk "无 TTY：说明根因"        "grep -q '无交互终端' <<<$(printf '%q' "$NOTTY_OUT")"
chk "无 TTY：给出 user 子命令" "grep -q 'user <用户名>' <<<$(printf '%q' "$NOTTY_OUT")"
chk "无 TTY：给出 DI_DOCKER_USER 替代" "grep -q 'DI_DOCKER_USER' <<<$(printf '%q' "$NOTTY_OUT")"
chk "无 TTY：不再有泛泛文案「未指定用户，跳过」" "! grep -q '未指定用户，跳过' <<<$(printf '%q' "$NOTTY_OUT")"
# ⚠️ $? 必须在 chk() 之外捕获（2026-09-21 实测）：
#    写成 chk "..." "[[ \$? -ne 0 ]]" 是错的 —— eval 求值时 $? 读到的是
#    chk 内部上一条命令（如 local _rc）的状态，与 rt-notty.sh 的退出码无关。
#    该断言此前长期「偶尔通过」只是被 pipefail/SIGPIPE 假红掩盖（修掉假红后
#    它 19/60 稳定失败才暴露）。正确姿势：先 rc=$?，再断言 rc。
bash "$TMP/rt-notty.sh" >/dev/null 2>&1; NOTTY_RC=$?
chk "无 TTY：返回非零（调用方可判定）" "[[ ${NOTTY_RC:-0} -ne 0 ]]"

# ---- 12b) 向导调用点不得吞 stderr（吞了 = 上面的诊断全看不见） ----
chk "向导调用 resolve_target_user 未重定向 stderr" \
  "! grep -q 'resolve_target_user \"\" 2>/dev/null' '$TOOL'"

echo ""
echo "================================================"
echo "PASS=$PASS FAIL=$FAIL"
echo "================================================"
[[ "$FAIL" -eq 0 ]]
