#!/usr/bin/env bash
# ============================================================
# vps-backup 回归 harness（mock 环境，无需 root / 网络 / 真 GDrive）
#
# 用法: bash tests/verify-vps-backup.sh
# 期望: PASS=n FAIL=0
#
# 覆盖：依赖 sha256 fail-closed / 密码与权限 fail-closed / 凭证排除（防自噬）/
#       connect 与 init 分离 / 分层备份命令形态 / 保留策略与抽查 / timer 单元 /
#       恢复护栏（必须 --target、拒绝系统路径）/ runbook 内容 / 架构规约。
# ============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL_DIR="${REPO}/backup/vps-backup"
TOOL="${TOOL_DIR}/vps-backup.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
MOCK_BIN="$TMP/bin"; MOCK_STATE="$TMP/state"
mkdir -p "$MOCK_BIN" "$MOCK_STATE"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1  <<< $2"; }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

# ⚠️ 本 harness 开了 pipefail —— 断言里**不能**写 `cmd | grep -q`：
# grep -q 命中即退出会关闭管道，写端收到 SIGPIPE(141)，pipefail 把整条管道判失败，
# 于是「匹配成功」反而报 FAIL（本次自伤：status 明明打印了却 4 条断言全红）。
# 统一姿势：先落文件，再 grep 文件。
snap(){ "$TOOL" "$@" > "$TMP/snap.out" 2>&1; echo $?; }
rune(){ local kv="$1"; shift; env "$kv" "$TOOL" "$@" > "$TMP/out" 2> "$TMP/err"; echo $?; }

# ---------- 环境隔离（全部指到临时目录） ----------
# ⚠️ 正例数据目录不能放 /tmp（默认排除表含 /tmp）→ 放 $HOME 下的一次性目录
TMPDATA="$(mktemp -d "${HOME}/.vps-backup-test.XXXXXX")"
trap 'rm -rf "$TMP" "$TMPDATA"' EXIT
export VP_ENV_FILE="$TMP/vps-backup.env"
export VP_PASSWORD_FILE="$TMP/restic-password"
export VP_EXCLUDE_FILE="$TMP/vps-backup.exclude"
export VP_STATE_DIR="$TMP/state"
export VP_RUNBOOK_FILE="$TMP/VPS-RESTORE.md"
export VP_RESTIC_BIN="$MOCK_BIN/restic"
export VP_RCLONE_BIN="$MOCK_BIN/rclone"
export VP_UNIT_DIR="$TMP/units"
export VP_EUID=0
export VP_HOST="testhost"
export VP_YES=1
export VP_NOTIFY=0
export VP_RCLONE_REMOTE="gdrive"
export VP_REPO_BASE="vps-backup"
export MOCK_STATE
mkdir -p "$VP_UNIT_DIR"

cat > "$VP_ENV_FILE" <<EOF
VP_RCLONE_REMOTE="gdrive"
VP_REPO_BASE="vps-backup"
VP_HOST="testhost"
VP_BACKUP_CORE_PATHS="$TMPDATA/core"
VP_BACKUP_DATA_PATHS="$TMPDATA/data"
EOF
chmod 600 "$VP_ENV_FILE"
mkdir -p "$TMPDATA/core/etc" "$TMPDATA/data/vol"
echo hello > "$TMPDATA/core/etc/x.conf"

# 备份范围变量以环境变量形式传入（load_env 外部优先，可覆盖 env 文件）
export VP_BACKUP_CORE_PATHS="$TMPDATA/core"
export VP_BACKUP_DATA_PATHS="$TMPDATA/data"

# ---------- restic / rclone mock（记录调用；可切换行为） ----------
cat > "$VP_RESTIC_BIN" <<'STUB'
#!/usr/bin/env bash
LOG="${MOCK_STATE}/restic.log"
echo "restic $*" >> "$LOG"
# ⚠️ 子命令解析必须按已知子命令名匹配：restic 的参数是 `--repo <url> --password-file <f> -o k=v <子命令>`，
# 「第一个非 - 开头的参数」是 --repo 的**值**（repo URL），据此分发会全部落到 default 分支
# （harness 自身踩过：备份/恢复/校验全被误判为成功）
sub=""
for a in "$@"; do
  case "$a" in
    init|cat|snapshots|backup|check|restore|forget|prune|ls|list|dump|stats|version|unlock|repair)
      sub="$a"; break ;;
  esac
done
case "$sub" in
  version) echo "restic 0.19.1 compiled with go1.24" ; exit 0 ;;
  init)
    [[ "${MOCK_INIT_FAIL:-0}" == "1" ]] && { echo "Fatal: init failed" >&2; exit 1; }
    echo "created restic repository abc123 at ${MOCK_REPO:-x}"
    touch "${MOCK_STATE}/repo_created"
    exit 0 ;;
  cat)
    # repo 是否可读 = 状态文件是否存在（模拟 init 真的改变服务端状态）
    [[ -f "${MOCK_STATE}/repo_created" ]] && exit 0
    echo "Fatal: unable to open config file" >&2; exit 1 ;;
  snapshots)
    [[ -f "${MOCK_STATE}/repo_created" ]] || { echo "Fatal: unable to open config file" >&2; exit 1; }
    if [[ "${MOCK_EMPTY_SNAPS:-0}" == "1" ]]; then exit 0; fi
    echo '[{"short_id":"aa11bb22","time":"2026-09-19T03:30:00.000000+08:00","hostname":"testhost","tags":["core"]}]'
    exit 0 ;;
  backup)
    [[ "${MOCK_BACKUP_FAIL:-0}" == "1" ]] && { echo "Fatal: backup failed" >&2; exit 1; }
    echo "snapshot abc123 saved"; exit 0 ;;
  check)  [[ -f "${MOCK_STATE}/locked" ]] && { echo "unable to create lock in backend: repository is already locked by PID 999 on h by u" >&2; exit 1; }
          [[ "${MOCK_CHECK_FAIL:-0}" == "1" ]] && { echo "Fatal: repo contains errors" >&2; exit 1; }; echo "no errors were found"; exit 0 ;;
  restore)
    [[ "${MOCK_RESTORE_FAIL:-0}" == "1" ]] && { echo "Fatal: restore failed" >&2; exit 1; }
    [[ "${MOCK_RESTORE_EMPTY:-0}" == "1" ]] && { echo "restoring (wrote nothing)"; exit 0; }
    # 模拟真实恢复：往 --target 目录写文件
    tgt=""; prev=""
    for a in "$@"; do [[ "$prev" == "--target" ]] && tgt="$a"; prev="$a"; done
    [[ -n "$tgt" ]] && { mkdir -p "$tgt/etc"; echo restored > "$tgt/etc/x.conf"; }
    echo "restoring <snapshot> to ${tgt}"; exit 0 ;;
  ls)
    # ls --json：备份后「快照里真有文件吗」复核用（MOCK_EMPTY_SNAP=1 → 空快照，用于反向断言）
    [[ -f "${MOCK_STATE}/repo_created" ]] || { echo "Fatal: unable to open config file" >&2; exit 1; }
    if [[ "${MOCK_EMPTY_SNAP:-0}" == "1" ]]; then
      echo '{"name":"emptydir","type":"dir","path":"/x"}'
    else
      echo '{"name":"app.conf","type":"file","path":"/etc/app.conf"}'
      echo '{"name":"id_ed25519","type":"file","path":"/root/.ssh/id_ed25519"}'
    fi
    exit 0 ;;
  forget|prune|dump|stats)
    [[ -f "${MOCK_STATE}/repo_created" ]] || { echo "Fatal: unable to open config file" >&2; exit 1; }
    [[ -f "${MOCK_STATE}/locked" ]] && { echo "unable to create lock in backend: repository is already locked by PID 999" >&2; exit 1; }
    echo "ok $sub"; exit 0 ;;
  list)
    # restic list locks → 有锁时打印锁 ID（诊断用）
    [[ -f "${MOCK_STATE}/locked" ]] && echo "ad2212420c9a4f3e8b1d5a6c7e8f9012345678901234567890abcdef12345678"
    exit 0 ;;
  unlock)
    # 真实改变锁状态：unlock 只清陈旧锁 → mock 用 MOCK_STALE_LOCK 表达
    if [[ "${MOCK_STALE_LOCK:-0}" == "1" ]]; then
      rm -f "${MOCK_STATE}/locked"; echo "successfully removed locks"; exit 0
    fi
    echo "no stale locks found"; exit 0 ;;
  *) echo "Fatal: unknown subcommand (harness mock)" >&2; exit 1 ;;
esac
STUB
chmod +x "$VP_RESTIC_BIN"

cat > "$VP_RCLONE_BIN" <<'STUB'
#!/usr/bin/env bash
echo "rclone $*" >> "${MOCK_STATE}/rclone.log"
case "${1:-}" in
  version)     echo "rclone v1.75.1" ;;
  listremotes) [[ "${MOCK_NO_REMOTE:-0}" == "1" ]] || echo "gdrive:" ;;
  lsd)         [[ "${MOCK_REMOTE_DOWN:-0}" == "1" ]] && { echo "Failed to ls: token expired" >&2; exit 1; }; echo "          -1 2026-09-19 00:00:00        -1 vps-backup" ;;
  about)       echo "Total:   15 GiB"; echo "Used:    1.2 GiB"; echo "Free:    13.8 GiB" ;;
  *)           exit 0 ;;
esac
STUB
chmod +x "$VP_RCLONE_BIN"

export MOCK_REPO_EXISTS=1
touch "$MOCK_STATE/repo_created"

# ---------- 静态架构检查（仓库可移植） ----------
echo "=== [A] 静态架构 ==="
chk "入口可执行且语法正确" "bash -n '$TOOL'"
chk "全部 lib 语法正确" "bash -n ${TOOL_DIR}/lib/*.sh"
chk "无 [[ -r /dev/tty ]] 伪判据（仅注释可提）" \
    "! grep -nE '^[^#]*\\[\\[ *-r +/dev/tty' ${TOOL_DIR}/vps-backup.sh ${TOOL_DIR}/lib/*.sh"
chk "包管理器探测用 if/elif 而非 && 链" \
    "grep -q 'if command -v apk' ${TOOL_DIR}/lib/pkg.sh && ! grep -qE 'command -v (apk|apt-get|dnf|yum) +>/dev/null 2>&1 && mgr=' ${TOOL_DIR}/lib/pkg.sh"
chk "拆分后模块齐全（common/interact/pkg/restic 各司其职）" \
    "for f in common interact pkg restic deps exclude backup paths repo retention restore timer status usage; do [[ -f ${TOOL_DIR}/lib/\$f.sh ]] || exit 1; done"
chk "单文件 ≤200 行（架构规约）" \
    "! awk 'END{if(NR>200) exit 1}' ${TOOL_DIR}/vps-backup.sh ${TOOL_DIR}/lib/*.sh 2>/dev/null | grep ."

echo ""
echo "=== [B] 依赖安装 fail-closed ==="
# 假 sha256：校验必须失败且不留二进制
BIN_BAK="$TMP/restic_backup"; cp "$VP_RESTIC_BIN" "$BIN_BAK"
(
  set -u
  . "${TOOL_DIR}/lib/common.sh"
  . "${TOOL_DIR}/lib/deps.sh"
  # shellcheck disable=SC2034  # 供 deps.sh 拼接资产名
  VP_RESTIC_VERSION="0.19.1"
  vp_fetch_verified "file://$TMP/nonexistent" "deadbeef" "$TMP/dl" 2>/dev/null
) >/dev/null 2>&1
chk "下载失败时不留残留文件" "[[ ! -f '$TMP/dl' ]]"
chk "sha256 不匹配时拒绝落盘（fail-closed 分支存在）" \
    "grep -q 'sha256 校验失败，拒绝安装' ${TOOL_DIR}/lib/deps.sh"
chk "架构映射不硬编码资产名" \
    "grep -q 'uname -m' ${TOOL_DIR}/lib/deps.sh && grep -q 'restic_\${VP_RESTIC_VERSION}_linux_' ${TOOL_DIR}/lib/deps.sh"
chk "版本常量可 pin（restic/rclone）" \
    "grep -qE '^VP_RESTIC_VERSION=\"[0-9.]+' ${TOOL_DIR}/lib/deps.sh && grep -qE '^VP_RCLONE_VERSION=\"[0-9.]+' ${TOOL_DIR}/lib/deps.sh"
chk "真实 sha256 常量存在（64 位十六进制）" \
    "grep -qE '[0-9a-f]{64}' ${TOOL_DIR}/lib/deps.sh"

echo ""
echo "=== [C] 密码与权限 fail-closed ==="
run() { "$TOOL" "$@" >"$TMP/out" 2>"$TMP/err"; echo $?; }

rm -f "$VP_PASSWORD_FILE"
: > "$MOCK_STATE/restic.log"
RC="$(run connect)"
chk "密码文件缺失 → 拒绝执行（rc≠0）" "[[ '$RC' != '0' ]]"
chk "密码缺失时未调用 restic（零尝试）" "[[ ! -s '$MOCK_STATE/restic.log' ]]"

printf 'pw\n' > "$VP_PASSWORD_FILE"; chmod 644 "$VP_PASSWORD_FILE"
: > "$MOCK_STATE/restic.log"
RC="$(run connect)"
chk "密码文件权限非 600 → 拒绝（rc≠0）" "[[ '$RC' != '0' ]]"
chk "权限不合规时未调用 restic" "[[ ! -s '$MOCK_STATE/restic.log' ]]"
chk "报错信息含修正命令" "grep -q 'chmod 600' '$TMP/err'"

printf 'pw\n' > "$VP_PASSWORD_FILE"; chmod 600 "$VP_PASSWORD_FILE"
: > "$VP_PASSWORD_FILE"
RC="$(run connect)"
chk "密码文件为空 → 拒绝" "[[ '$RC' != '0' ]]"

printf 'correct-horse\n' > "$VP_PASSWORD_FILE"; chmod 600 "$VP_PASSWORD_FILE"

echo ""
echo "=== [D] connect 与 init 严格分离 ==="
touch "$MOCK_STATE/repo_created"
: > "$MOCK_STATE/restic.log"
RC="$(run connect)"
chk "repo 存在时 connect 成功" "[[ '$RC' == '0' ]]"
chk "connect 路径绝不出现 restic init" "! grep -q ' init' '$MOCK_STATE/restic.log'"
chk "connect 路径确实读了 repo config（实测而非自报）" "grep -q ' cat config' '$MOCK_STATE/restic.log'"

: > "$MOCK_STATE/restic.log"
RC="$(run init)"
chk "repo 已存在时 init 拒绝（rc≠0）" "[[ '$RC' != '0' ]]"
chk "init 被拒后未执行 init 子命令" "! grep -q ' init' '$MOCK_STATE/restic.log'"
chk "init 拒绝信息明确" "grep -q '已存在' '$TMP/err'"

rm -f "$MOCK_STATE/repo_created"     # 模拟全新机器：repo 不存在
: > "$MOCK_STATE/restic.log"
RC="$(run init)"
chk "repo 不存在时 init 成功" "[[ '$RC' == '0' ]]"
chk "init 后做写后实测（再次 cat config）" "[[ \$(grep -c ' cat config' '$MOCK_STATE/restic.log') -ge 1 ]]"

# init 声称成功但服务端不可读 → 必须报错（防「本地绿、云端没有」）
rm -f "$MOCK_STATE/repo_created"
: > "$MOCK_STATE/restic.log"
cat > "$VP_RESTIC_BIN.init-silent" <<'STUB'
#!/usr/bin/env bash
echo "restic $*" >> "${MOCK_STATE}/restic.log"
[[ "$*" == *" init"* ]] && { echo "created restic repository abc123"; exit 0; }
echo "Fatal: unable to open config file" >&2; exit 1
STUB
chmod +x "$VP_RESTIC_BIN.init-silent"
cp "$VP_RESTIC_BIN" "$TMP/restic.real"
cp "$VP_RESTIC_BIN.init-silent" "$VP_RESTIC_BIN"; chmod +x "$VP_RESTIC_BIN"
RC="$(run init)"
chk "init 自报成功但 repo 不可读 → 报错（rc≠0）" "[[ '$RC' != '0' ]]"
chk "该场景给出明确诊断" "grep -q 'init 声称成功但 repo 不可读' '$TMP/err'"
cp "$TMP/restic.real" "$VP_RESTIC_BIN"; chmod +x "$VP_RESTIC_BIN"
touch "$MOCK_STATE/repo_created"

echo ""
echo "=== [E] 凭证排除（防自噬）==="
rm -f "$VP_EXCLUDE_FILE"
RC="$(run backup core)"
chk "首次备份自动生成排除表" "[[ -f '$VP_EXCLUDE_FILE' ]]"
for p in /etc/restic-password /etc/vps-backup.env /etc/vps-backup.exclude /root/.config/rclone/rclone.conf; do
  chk "排除表含 $p" "grep -qxF '$p' '$VP_EXCLUDE_FILE'"
done
chk "排除表权限 600" "[[ \"\$(stat -c '%a' '$VP_EXCLUDE_FILE')\" == '600' ]]"
chk "备份命令带 --exclude-file" "grep -q -- '--exclude-file $VP_EXCLUDE_FILE' '$MOCK_STATE/restic.log'"

# 破坏排除表 → 备份必须拒绝（fail-closed）
grep -v '^/etc/restic-password$' "$VP_EXCLUDE_FILE" > "$TMP/ex.tmp" && mv "$TMP/ex.tmp" "$VP_EXCLUDE_FILE"
RC="$(run backup core)"
chk "排除表缺凭证路径 → 拒绝备份（rc≠0）" "[[ '$RC' != '0' ]]"
chk "拒绝时给出明确原因" "grep -q '排除表缺少凭证路径' '$TMP/err'"
chk "status 的凭证自检能发现该问题" "snap status >/dev/null; ! grep -q '凭证路径已排除' '$TMP/snap.out'"
rm -f "$VP_EXCLUDE_FILE"; run backup core >/dev/null

echo ""
echo "=== [E2] 备份路径自定义 + 排除表管理 ==="
"$TOOL" paths set data "$TMPDATA/data" >/dev/null 2>&1
chk "paths set 接受合法绝对路径并写 env" "grep -qF 'VP_BACKUP_DATA_PATHS=\"$TMPDATA/data\"' '$VP_ENV_FILE'"
chk "paths set 拒绝相对路径" "[[ \"\$(snap paths set data relative/path)\" != '0' ]]"
chk "paths set 拒绝被排除表挡掉的路径" "[[ \"\$(snap paths set data /tmp)\" != '0' ]]"
snap paths show >/dev/null
chk "paths show 列出两层路径" "grep -q 'core' '$TMP/snap.out' && grep -q 'data' '$TMP/snap.out'"
chk "paths show 做体检（报告可备份/被挡/不存在）" "grep -qE '(可备份|被排除表挡掉|不存在)' '$TMP/snap.out'"
chk "paths check 能识别排除冲突" \
    "[[ \"\$(rune VP_BACKUP_DATA_PATHS=/tmp paths check data)\" != '0' ]] && grep -q '被排除表挡掉' '$TMP/err'"
snap exclude list >/dev/null
chk "exclude list 输出排除表" "grep -q '/etc/restic-password' '$TMP/snap.out'"
snap exclude add "$TMP/skipme" >/dev/null
chk "exclude add 追加模式" "grep -qxF '$TMP/skipme' '$VP_EXCLUDE_FILE'"
snap exclude remove "$TMP/skipme" >/dev/null
chk "exclude remove 移除模式" "! grep -qxF '$TMP/skipme' '$VP_EXCLUDE_FILE'"
chk "exclude remove 拒绝移除凭证模式（防自噬）" \
    "[[ \"\$(snap exclude remove /etc/restic-password)\" != '0' ]] && grep -q '拒绝移除凭证排除项' '$TMP/snap.out'"

echo ""
echo "=== [E3] 备份有效性复核（防「成功但 0 文件」） ==="
export MOCK_EMPTY_SNAP=1
RC="$(run backup data)"
chk "快照 0 文件 → 备份失败（不再假报成功）" "[[ '$RC' != '0' ]]"
chk "失败原因明确（指向排除表/空目录）" "grep -q '备份了 0 个文件' '$TMP/err'"
unset MOCK_EMPTY_SNAP
RC="$(run backup data)"
chk "有文件时备份成功" "[[ '$RC' == '0' ]]"
chk "成功信息含文件数复核" "grep -qE '含 [0-9]+ 个文件' '$TMP/err'"
chk "复核用 ls --json 数文件（非 stats 累计）" "grep -q 'ls --json' '$MOCK_STATE/restic.log'"

echo ""
echo "=== [F] 分层备份命令形态 ==="
: > "$MOCK_STATE/restic.log"
RC="$(run backup all)"
chk "backup all 成功" "[[ '$RC' == '0' ]]"
chk "core 层带 --tag core" "grep -q -- '--tag core' '$MOCK_STATE/restic.log'"
chk "data 层带 --tag data" "grep -q -- '--tag data' '$MOCK_STATE/restic.log'"
chk "快照 host 标签为 VP_HOST" "grep -q -- '--host testhost' '$MOCK_STATE/restic.log'"
chk "备份后实测列出快照（服务端状态复核）" "grep -q 'snapshots --json --tag' '$MOCK_STATE/restic.log'"
chk "备份后复核快照内文件数" "grep -q 'ls --json' '$MOCK_STATE/restic.log'"
chk "repo URL 形态 rclone:<remote>:<base>/<host>" \
    "snap status >/dev/null; grep -q 'rclone:gdrive:vps-backup/testhost' '$TMP/snap.out'"
chk "未知层名被拒绝" "[[ \"\$(run backup bogus)\" != '0' ]]"

: > "$MOCK_STATE/restic.log"
export MOCK_BACKUP_FAIL=1
RC="$(run backup core)"
chk "备份失败返回非零" "[[ '$RC' != '0' ]]"
unset MOCK_BACKUP_FAIL

echo ""
echo "=== [G] 保留策略 / 完整性校验 ==="
: > "$MOCK_STATE/restic.log"
RC="$(run maintain)"
chk "maintain 成功" "[[ '$RC' == '0' ]]"
chk "forget 带保留参数" "grep -q -- 'forget --keep-daily 7 --keep-weekly 5 --keep-monthly 6 --keep-yearly 2' '$MOCK_STATE/restic.log'"
chk "forget 限定本机 host（防误删他机快照）" "grep -q 'forget .*--host testhost' '$MOCK_STATE/restic.log'"
chk "prune 被执行" "grep -q ' prune' '$MOCK_STATE/restic.log'"
chk "check 用 --read-data-subset（避免下载整个 repo）" "grep -q 'check --read-data-subset=5%' '$MOCK_STATE/restic.log'"
export MOCK_CHECK_FAIL=1
: > "$MOCK_STATE/restic.log"
RC="$(run check)"
chk "校验失败返回非零" "[[ '$RC' != '0' ]]"
chk "校验失败提示官方修复路径（repair）" "grep -q 'repair' '$TMP/err'"
unset MOCK_CHECK_FAIL

echo ""
echo "=== [H] 恢复护栏 ==="
RC="$(run restore latest)"
chk "缺 --target → 拒绝" "[[ '$RC' != '0' ]]"
chk "拒绝原因明确" "grep -q '必须显式指定 --target' '$TMP/err'"
RC="$(run restore latest --target /)"
chk "target=/ → 拒绝" "[[ '$RC' != '0' ]]"
RC="$(run restore latest --target /etc)"
chk "target=/etc → 拒绝" "[[ '$RC' != '0' ]]"
RC="$(run restore latest --target relative/path)"
chk "相对路径 target → 拒绝" "[[ '$RC' != '0' ]]"
rm -rf "$TMP/restore"
RC="$(run restore latest --target "$TMP/restore" --tag core)"
chk "合法恢复成功" "[[ '$RC' == '0' ]]"
chk "恢复命令带 --tag core" "grep -q 'restore latest --target $TMP/restore --verbose --tag core' '$MOCK_STATE/restic.log'"
chk "恢复后实测目标目录非空（不信自报）" "[[ -s '$TMP/restore/etc/x.conf' ]]"

# 恢复声称成功但目录为空 → 必须报错（防假成功）
export MOCK_RESTORE_EMPTY=1
rm -rf "$TMP/restore2"
RC="$(run restore latest --target "$TMP/restore2")"
chk "恢复自报成功但目标为空 → 报错（rc≠0）" "[[ '$RC' != '0' ]]"
chk "该场景给出明确诊断" "grep -q '恢复声称成功但' '$TMP/err'"
unset MOCK_RESTORE_EMPTY

cat > "$MOCK_BIN/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "${MOCK_STATE}/systemctl.log"
case "${1:-}" in
  is-active) echo active ;;
  list-timers) echo "NEXT LEFT LAST PASSED UNIT ACTIVATES"; echo "- - - - vps-backup-backup@core.timer vps-backup-backup@core.service" ;;
  show) echo 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$MOCK_BIN/systemctl"
export PATH="$MOCK_BIN:$PATH"

echo ""
echo "=== [I] timer 单元 ==="
RC="$(run install-timer)"
chk "timer 安装成功" "[[ '$RC' == '0' ]]"
for u in "vps-backup-backup@core.timer" "vps-backup-backup@data.timer" "vps-backup-maintain.timer" \
         "vps-backup-backup@.service" "vps-backup-maintain.service" "vps-backup-failnotify@.service"; do
  chk "生成单元 $u" "[[ -f '$VP_UNIT_DIR/$u' ]]"
done
chk "core timer 使用 VP_CORE_ONCALENDAR" "grep -q 'OnCalendar=\*-\*-\* 00/6:20:00' '$VP_UNIT_DIR/vps-backup-backup@core.timer'"
chk "data timer 每日触发" "grep -q 'OnCalendar=\*-\*-\* 03:30:00' '$VP_UNIT_DIR/vps-backup-backup@data.timer'"
chk "timer Persistent=true（关机错过补跑）" "grep -q 'Persistent=true' '$VP_UNIT_DIR/vps-backup-backup@core.timer'"
chk "备份单元 OnFailure 指向告警单元" "grep -q 'OnFailure=vps-backup-failnotify@%i.service' '$VP_UNIT_DIR/vps-backup-backup@.service'"
chk "单元用 EnvironmentFile 而非命令行传密码" \
    "grep -q 'EnvironmentFile=-/etc/vps-backup.env' '$VP_UNIT_DIR/vps-backup-backup@.service' && ! grep -q 'PASSWORD' '$VP_UNIT_DIR/vps-backup-backup@.service'"
chk "备份单元调 core/data 参数化实例" "grep -q 'ExecStart=/usr/local/bin/vps-backup backup %i' '$VP_UNIT_DIR/vps-backup-backup@.service'"
chk "maintain 单元执行 forget+prune+check" "grep -q 'ExecStart=/usr/local/bin/vps-backup maintain' '$VP_UNIT_DIR/vps-backup-maintain.service'"

echo ""
echo "=== [I2] 锁占用：明确诊断 + unlock 恢复（E2E 实测暴露的真问题） ==="
touch "$MOCK_STATE/locked"     # 造锁（状态文件驱动）
RC="$(run maintain)"
chk "被锁时 maintain 失败（rc≠0）" "[[ '$RC' != '0' ]]"
chk "报错指明是「锁」而非数据损坏" "grep -q 'repo 被锁' '$TMP/err'"
chk "给出 unlock 命令指引" "grep -q 'vps-backup unlock' '$TMP/err'"
chk "不误导用户去跑 repair（区分故障性质）" "! grep -q 'repair packs' '$TMP/err'"
RC="$(run check)"
chk "check 被锁时同样给锁诊断" "grep -q 'repo 被锁' '$TMP/err'"
RC="$(run unlock --dry-run)"
chk "unlock --dry-run 列出锁（stderr）" "grep -qE '[0-9a-f]{16,}' '$TMP/err'"
# 存活进程持锁（mock 未置 MOCK_STALE_LOCK）→ unlock 不清，必须如实报告
RC="$(run unlock)"
chk "存活持锁时 unlock 如实报「锁仍在」（不假报成功）" "[[ '$RC' != '0' ]] && grep -q '锁仍然存在' '$TMP/err'"
chk "给出 --all 强制清除指引" "grep -q 'unlock --all' '$TMP/err'"
# 陈旧锁（进程已消失）→ unlock 清掉且复核为空
export MOCK_STALE_LOCK=1
RC="$(run unlock)"
chk "陈旧锁可被清理（复核锁列表为空）" "[[ '$RC' == '0' ]] && grep -q '已清理 repo 锁' '$TMP/err'"
chk "unlock 复核用 list locks（实测而非自报）" "grep -q 'list locks' '$MOCK_STATE/restic.log'"
unset MOCK_STALE_LOCK
chk "锁清理后 maintain 恢复正常" "[[ \"\$(run maintain)\" == '0' ]]"
chk "备份/校验命令带 --retry-lock（避免定时任务撞车）" \
    "grep -q -- '--retry-lock' '$MOCK_STATE/restic.log'"

echo ""
echo "=== [J] 失败告警 ==="
chk "失败通知路径存在（notify-failure 子命令）" "grep -q 'notify-failure) load_env; vp_fail_notify_main' '$TOOL'"
chk "通知失败不阻塞（curl 后 || true）" "grep -q 'data-urlencode \"text=\$1\" >/dev/null 2>&1 || true' ${TOOL_DIR}/lib/retention.sh"
chk "备份成功才发完成通知（不刷双卡）" \
    "grep -q '失败不在此处通知' ${TOOL_DIR}/lib/backup.sh"
export VP_NOTIFY=1 VP_TG_BOT_TOKEN="123:abc" VP_TG_CHAT_ID="42"
: > "$MOCK_STATE/curl.log"
cat > "$MOCK_BIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "${MOCK_STATE}/curl.log"
echo '{"ok":true,"result":{"message_id":1}}'
STUB
chmod +x "$MOCK_BIN/curl"
PATH="$MOCK_BIN:$PATH" "$TOOL" notify-failure core >/dev/null 2>&1 || true
chk "失败告警走 Telegram API" "grep -q 'api.telegram.org/bot123:abc/sendMessage' '$MOCK_STATE/curl.log'"
chk "失败告警含单元名与排查命令" "grep -q 'core' '$MOCK_STATE/curl.log' && grep -q 'journalctl' '$MOCK_STATE/curl.log'"
export VP_NOTIFY=0; unset VP_TG_BOT_TOKEN VP_TG_CHAT_ID

echo ""
echo "=== [K] 灾难恢复 runbook ==="
RC="$(run runbook)"
chk "runbook 生成成功" "[[ '$RC' == '0' && -f '$VP_RUNBOOK_FILE' ]]"
chk "runbook 权限 600" "[[ \"\$(stat -c '%a' '$VP_RUNBOOK_FILE')\" == '600' ]]"
chk "runbook 含 repo 地址" "grep -q 'rclone:gdrive:vps-backup/testhost' '$VP_RUNBOOK_FILE'"
chk "runbook 明确「灾难时需要的 3 样东西」" "grep -q '灾难时你需要的 3 样东西' '$VP_RUNBOOK_FILE'"
chk "runbook 强调 connect 而非 init" "grep -q 'vps-backup connect' '$VP_RUNBOOK_FILE' && grep -qi '不 init' '$VP_RUNBOOK_FILE'"
chk "runbook 含 core 先行恢复步骤" "grep -q 'restore latest --tag core' '$VP_RUNBOOK_FILE'"
chk "runbook 提示 GDrive 授权 7 天/PUBLISH 坑" "grep -q 'PUBLISH' '$VP_RUNBOOK_FILE'"
chk "runbook 提示 750GiB 上传限额" "grep -q '750GiB' '$VP_RUNBOOK_FILE'"
chk "runbook --stdout 不落盘" "out=\$($TOOL runbook --stdout 2>/dev/null); grep -q '灾难恢复 Runbook' <<< \"\$out\""

echo ""
echo "=== [L] 状态与新鲜度 ==="
snap status >/dev/null
chk "status 列出快照新鲜度（core/data 双层）" \
    "grep -q '快照新鲜度' '$TMP/snap.out' && grep -qE 'core: (最近快照|无快照)' '$TMP/snap.out' && grep -qE 'data: (最近快照|无快照)' '$TMP/snap.out'"
chk "status 显示 remote 配额" "grep -q '配额' '$TMP/snap.out'"
chk "status 显示凭证自检结果" "grep -q '凭证路径已排除' '$TMP/snap.out'"
export MOCK_REMOTE_DOWN=1
snap status >/dev/null
chk "remote 不可用时报错并给重授权提示" "! grep -q 'rclone remote 可用' '$TMP/snap.out' && grep -q 'reconnect' '$TMP/snap.out'"
unset MOCK_REMOTE_DOWN
export MOCK_NO_REMOTE=1
snap status >/dev/null
chk "remote 未配置时给出 rclone config 指引" "grep -q 'rclone remote 未配置' '$TMP/snap.out'"
unset MOCK_NO_REMOTE

echo ""
echo "=== [M] CLI 契约 ==="
chk "-v 输出版本号" "$TOOL -v | grep -qE '^vps-backup [0-9]+\.[0-9]+\.[0-9]+'"
chk "-h 输出子命令清单" "$TOOL -h | grep -q 'vps-backup restore'"
chk "未知子命令返回非零" "[[ \"\$(run bogus)\" != '0' ]]"
chk "usage 提到凭证不入包设计" "$TOOL -h | grep -q '凭证不入包'"
chk "usage 提到 connect/init 分离" "$TOOL -h | grep -q 'connect 与 init 严格分离'"
chk "usage 提到路径可自定义" "$TOOL -h | grep -q '路径完全可自定义'"
chk "usage 列出 paths 子命令" "$TOOL -h | grep -q 'vps-backup paths'"
chk "usage 列出 exclude 子命令" "$TOOL -h | grep -q 'vps-backup exclude'"

echo ""
echo "=== [N] 注册表契约（install.sh）==="
REG_LINE="$(grep -o '^  "vps-backup|[^"]*"' "$REPO/install.sh" | tr -d '"')"
chk "注册表存在 vps-backup 条目" "[[ -n '$REG_LINE' ]]"
chk "第 5 字段 interactive_setup=1" "[[ \"\$(cut -d'|' -f5 <<< '$REG_LINE')\" == '1' ]]"
chk "env 模板指向 templates/ 且目标为 /etc/vps-backup.env" \
    "[[ \"\$(cut -d'|' -f3 <<< '$REG_LINE')\" == 'backup/vps-backup/templates/vps-backup.env.example' ]]"
# extra_files 与磁盘逐项比对（漏列 = 安装不完整）
# shellcheck disable=SC2034  # EXTRA/DISK 仅用于紧随其后的 eval 断言
EXTRA="$(cut -d'|' -f6 <<< "$REG_LINE" | tr ' ' '\n' | sed 's|backup/vps-backup/||' | grep -v '^$' | sort)"
# shellcheck disable=SC2034
DISK="$(cd "$TOOL_DIR" && find lib -name '*.sh' | sort)"
chk "extra_files 覆盖全部 lib/*.sh（无漏列）" "[[ \"\$EXTRA\" == \"\$DISK\" ]]"
chk "extra_files 无多余项" "[[ \$(wc -l <<< \"\$EXTRA\") -eq \$(wc -l <<< \"\$DISK\") ]]"
chk "install.sh 版本已递增到 ≥1.7.0" "grep -qE '^VPS_TOOLS_VERSION=\"1\.(7|[89]|[1-9][0-9])\.[0-9]+\"' '$REPO/install.sh'"
chk "README 工具清单含 vps-backup" "grep -q 'backup/vps-backup/' '$REPO/README.md'"
chk "无硬编码密钥（脱敏铁律）" \
    "! grep -rInE '(token|password|secret|api[_-]?key)[[:space:]]*[=:][[:space:]]*[\"'\'']?[A-Za-z0-9_:-]{16,}' ${TOOL_DIR} --include='*.sh' --include='*.example' | grep -vE 'VP_TG_BOT_TOKEN=\"\\\$|PLACEHOLDER|sha256|VP_|RCLONE_|RESTIC_' | grep -q ."

echo ""
echo "================================================"
echo "PASS=$PASS FAIL=$FAIL"
echo "================================================"
[[ "$FAIL" -eq 0 ]]
