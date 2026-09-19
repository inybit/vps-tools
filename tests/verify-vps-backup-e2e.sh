#!/usr/bin/env bash
# ============================================================
# vps-backup 真机 E2E（真实 restic + 真实 rclone，local backend 模拟 Google Drive）
#
# 为什么用 local backend 而不是真 GDrive：
#   ① GDrive 需用户 OAuth 凭据，CI/回归无法自动化；
#   ② local backend 走的是**同一套 restic ↔ rclone serve restic 协议路径**
#      （restic 自己 spawn `rclone serve restic --stdio`），能真实证明
#      init / backup / restore / check / prune / unlock 全链路；
#   ③ 零数据出境（把域名/数据提交给外部服务需显式确认 —— 用户铁律）。
#   真 GDrive 的差异只在 remote 类型（配置层），不影响被测逻辑。
#
# 用法:
#   RESTIC_BIN=/path/to/restic RCLONE_BIN=/path/to/rclone bash tests/verify-vps-backup-e2e.sh
#   或先确保 PATH 里有 restic / rclone
# 期望: E2E PASS=n FAIL=0
#
# 与 mock harness 的分工：tests/verify-vps-backup.sh 证明「命令拼对了」，
# 本脚本证明「数据真的能备进去、真的能取回来」——两者都要跑。
# ============================================================
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL_DIR="${REPO_ROOT}/backup/vps-backup"
TOOL="${TOOL_DIR}/vps-backup.sh"

RESTIC_BIN="${RESTIC_BIN:-$(command -v restic || true)}"
RCLONE_BIN="${RCLONE_BIN:-$(command -v rclone || true)}"
if [[ -z "$RESTIC_BIN" || -z "$RCLONE_BIN" ]]; then
  echo "SKIP: 需要真实 restic 与 rclone（可用 RESTIC_BIN=/path RCLONE_BIN=/path 指定）"
  exit 0
fi

# 工作目录放 $HOME 下（**不能**放 /tmp、/var/tmp、~/.cache —— 这些都在工具默认排除表里，
# 备份源会被整目录排除 → 快照 0 B、恢复比对全挂。实测踩过两次，勿再改回）
BASE="$(mktemp -d "${HOME}/vps-backup-e2e.XXXXXX")"
trap 'rm -rf "$BASE"' EXIT

CLOUD="$BASE/drive"          # 模拟云端（rclone local remote 的根）
SRC="$BASE/src"              # 备份源
mkdir -p "$CLOUD" "$SRC/etc/xray-deploy" "$SRC/home/user/.ssh" "$SRC/data"
head -c 20000000 /dev/urandom > "$SRC/data/blob.bin"   # 20MB：让内容定义分块可观测
echo "v1 config" > "$SRC/etc/app.conf"
echo "sshkey" > "$SRC/home/user/.ssh/id_ed25519"
echo '{"inbound":"reality"}' > "$SRC/etc/xray-deploy/config.json"

export RCLONE_CONFIG="$BASE/rclone.conf"
export VP_RESTIC_BIN="$RESTIC_BIN"
export VP_RCLONE_BIN="$RCLONE_BIN"
export VP_RCLONE_REMOTE="localtest"
export VP_REPO_BASE="$CLOUD/vps-backup"
export VP_HOST="testhost"
export VP_ENV_FILE="$BASE/vps-backup.env"
export VP_PASSWORD_FILE="$BASE/restic-password"
export VP_EXCLUDE_FILE="$BASE/exclude"
export VP_RUNBOOK_FILE="$BASE/VPS-RESTORE.md"
export VP_UNIT_DIR="$BASE/units"
# 缓存目录也必须隔离：默认 /var/cache/vps-backup 在非 root 下建不出来，
# 而它现在是 restic 的硬前提（fail-closed）→ 不隔离则 E2E 从 [1] 起全线失败（2026-09-19 踩过）
export VP_CACHE_DIR="$BASE/cache"
export VP_BACKUP_CORE_PATHS="$SRC/etc $SRC/home"
export VP_BACKUP_DATA_PATHS="$SRC/data"
export VP_NOTIFY=0
export VP_EUID=0
export VP_YES=1
export VP_RETRY_LOCK=5s    # E2E 里缩短等待（默认 10m 会把失败用例拖成超时）
mkdir -p "$VP_UNIT_DIR"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1  <<< $2"; }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

# ⚠️ 本脚本开了 pipefail —— 断言里**不能**写 `cmd | grep -q`：
# grep -q 命中即退出关闭管道，写端收 SIGPIPE(141) → 管道判失败 → 匹配成功也报 FAIL；
# 更糟的是写端若是 restic，被 SIGPIPE 杀死会**留下陈旧锁**，后续 check/prune 全挂。
# 统一姿势：先落文件，再 grep 文件。
rs(){ "$VP_RESTIC_BIN" --repo "rclone:localtest:$VP_REPO_BASE/testhost" \
        --password-file "$VP_PASSWORD_FILE" -o "rclone.program=$VP_RCLONE_BIN" "$@"; }
cloud_ls(){ "$VP_RCLONE_BIN" lsf --recursive "localtest:$VP_REPO_BASE" 2>/dev/null > "$BASE/cloud.txt"; }
run(){ "$TOOL" "$@" > "$BASE/out" 2> "$BASE/err"; echo $?; }

echo "=== [0] 准备（remote 显式固定；备份源不放在被排除的 /tmp 下） ==="
"$VP_RCLONE_BIN" config create localtest local nounc=true >/dev/null 2>&1
printf 'e2e-test-password\n' > "$VP_PASSWORD_FILE"; chmod 600 "$VP_PASSWORD_FILE"
cat > "$VP_ENV_FILE" <<EOF
VP_RCLONE_REMOTE="localtest"
VP_REPO_BASE="$VP_REPO_BASE"
VP_HOST="testhost"
EOF
chmod 600 "$VP_ENV_FILE"
chk "remote 根目录可列（独立视角）" "\"$VP_RCLONE_BIN\" lsd localtest: >/dev/null 2>&1"

echo ""
echo "=== [1] repo init（真实 rclone serve restic 链路） ==="
"$TOOL" init > "$BASE/out" 2> "$BASE/err"
chk "init 成功并实测可读" "grep -q 'repo 初始化完成并已实测可读' '$BASE/err'"
cloud_ls
chk "云端出现 repo config（独立视角枚举）" "grep -q '^testhost/config$' '$BASE/cloud.txt'"
chk "云端出现 keys/（repo 已加密初始化）" "grep -q '^testhost/keys/' '$BASE/cloud.txt'"
chk "云端出现 snapshots/ 与 index/" \
    "grep -q '^testhost/snapshots/' '$BASE/cloud.txt' && grep -q '^testhost/index/' '$BASE/cloud.txt'"
chk "connect 只读校验成功" "\"$TOOL\" connect > '$BASE/out' 2>&1; grep -q 'repo 连接成功' '$BASE/out'"

echo ""
echo "=== [2] 重复 init 必须被拒绝（connect/init 严格分离） ==="
"$TOOL" init > "$BASE/out" 2> "$BASE/err"
chk "repo 已存在时 init 拒绝" "grep -q '已存在' '$BASE/err'"
cloud_ls
chk "拒绝时未破坏 repo（config 仍在）" "grep -q '^testhost/config$' '$BASE/cloud.txt'"

echo ""
echo "=== [3] 首次 core 备份（工具自动生成排除表） ==="
"$TOOL" backup core > "$BASE/out" 2> "$BASE/err"
chk "core 备份成功" "grep -q 'core 层备份完成' '$BASE/err'"
chk "排除表由工具生成且含默认凭证路径" \
    "grep -qxF '/etc/restic-password' '$VP_EXCLUDE_FILE' && grep -qxF '/root/.config/rclone/rclone.conf' '$VP_EXCLUDE_FILE'"
rs snapshots --json > "$BASE/snaps.json" 2>&1
chk "快照已落盘（restic 独立查询，非客户端自报）" "grep -q '\"core\"' '$BASE/snaps.json'"
rs ls --long latest > "$BASE/ls.txt" 2>&1
chk "快照内含普通配置" "grep -q 'etc/app.conf' '$BASE/ls.txt'"
chk "快照内含 SSH 私钥" "grep -q 'id_ed25519' '$BASE/ls.txt'"

echo ""
echo "=== [4] 凭证排除真实生效（真实 restic 验证，非 mock） ==="
mkdir -p "$SRC/etc/creds"
printf 'SECRET-DO-NOT-BACKUP\n' > "$SRC/etc/creds/restic-password"
printf 'RCLONE-TOKEN-DO-NOT-BACKUP\n' > "$SRC/etc/creds/rclone.conf"
printf '%s\n' "$SRC/etc/creds/restic-password" "$SRC/etc/creds/rclone.conf" >> "$VP_EXCLUDE_FILE"
"$TOOL" backup core > "$BASE/out" 2> "$BASE/err"
chk "追加排除项后备份仍成功" "grep -q 'core 层备份完成' '$BASE/err'"
rs ls --long latest > "$BASE/ls.txt" 2>&1
chk "快照内**不含**凭证文件（防自噬，真实 restic 验证）" "! grep -q 'creds/restic-password' '$BASE/ls.txt'"
chk "快照内不含 rclone 配置" "! grep -q 'creds/rclone.conf' '$BASE/ls.txt'"
printf 'keepme\n' > "$SRC/etc/creds/keepme.txt"
"$TOOL" backup core > "$BASE/out" 2> "$BASE/err"
rs ls --long latest > "$BASE/ls2.txt" 2>&1
chk "同目录其它文件仍在（排除精确生效，非整目录跳过）" "grep -q 'creds/keepme.txt' '$BASE/ls2.txt'"

echo ""
echo "=== [5] data 层 + 增量去重 ==="
"$TOOL" backup data > "$BASE/out" 2> "$BASE/err"
chk "data 层备份成功" "grep -q 'data 层备份完成' '$BASE/err'"
rs snapshots --json > "$BASE/snaps.json" 2>&1
chk "快照含 core 与 data 两个 tag" \
    "grep -q '\"core\"' '$BASE/snaps.json' && grep -q '\"data\"' '$BASE/snaps.json'"
SIZE1=$(du -sk "$CLOUD" | awk '{print $1}')
"$TOOL" backup data > "$BASE/out" 2> "$BASE/err"
SIZE_NC=$(du -sk "$CLOUD" | awk '{print $1}')
DELTA_NC=$((SIZE_NC - SIZE1))
echo "  (无改动重备：${SIZE1}KB → ${SIZE_NC}KB，增量 ${DELTA_NC}KB)"
chk "无改动重备增量 < 100KB（去重生效，不重复上传）" "[[ $DELTA_NC -lt 100 ]]"
printf 'X' | dd of="$SRC/data/blob.bin" bs=1 seek=1500000 conv=notrunc status=none
"$TOOL" backup data > "$BASE/out" 2> "$BASE/err"
SIZE2=$(du -sk "$CLOUD" | awk '{print $1}')
DELTA=$((SIZE2 - SIZE_NC))
echo "  (改 1 字节后：${SIZE_NC}KB → ${SIZE2}KB，增量 ${DELTA}KB；源文件 20000KB)"
# 内容定义分块：改 1 字节只应重传 1~2 个块（restic 平均块 ~1MB，最大 8MB）
chk "改 1 字节后增量 < 源文件的 50%（分块生效，非全量重传）" "[[ $DELTA -lt 10000 ]]"

echo ""
echo "=== [6] 恢复（真实内容逐字节比对） ==="
rm -rf "$BASE/restore"
"$TOOL" restore latest --tag core --target "$BASE/restore" > "$BASE/out" 2> "$BASE/err"
chk "恢复返回成功" "grep -q '恢复完成' '$BASE/err'"
chk "恢复出的配置与源逐字节一致" "cmp -s '$SRC/etc/app.conf' '$BASE/restore$SRC/etc/app.conf'"
chk "恢复出的 xray 配置与源一致" \
    "cmp -s '$SRC/etc/xray-deploy/config.json' '$BASE/restore$SRC/etc/xray-deploy/config.json'"
chk "恢复出的 SSH 私钥与源一致" \
    "cmp -s '$SRC/home/user/.ssh/id_ed25519' '$BASE/restore$SRC/home/user/.ssh/id_ed25519'"
chk "恢复目标不含凭证文件" "! find '$BASE/restore' -name 'restic-password' | grep -q ."
rm -rf "$BASE/restore_data"
"$TOOL" restore latest --tag data --target "$BASE/restore_data" > "$BASE/out" 2> "$BASE/err"
chk "data 层恢复后 20MB blob sha256 一致（含改动后的最新版本）" \
    "[[ \$(sha256sum < '$SRC/data/blob.bin' | cut -d' ' -f1) == \$(sha256sum < '$BASE/restore_data$SRC/data/blob.bin' | cut -d' ' -f1) ]]"

echo ""
echo "=== [7] 单文件恢复（dump，灾难场景取单个配置） ==="
"$TOOL" dump latest "$SRC/etc/app.conf" --tag core > "$BASE/dumped" 2> "$BASE/err"
chk "dump 输出单文件与源一致（--tag 指定层）" "cmp -s '$SRC/etc/app.conf' '$BASE/dumped'"
chk "dump 产物非空（非静默空文件）" "[[ -s '$BASE/dumped' ]]"

echo ""
echo "=== [8] 完整性校验 ==="
"$TOOL" check > "$BASE/out" 2> "$BASE/err"
chk "restic check 通过" "grep -q '校验通过' '$BASE/err'"

echo ""
echo "=== [9] 保留策略（真实 forget/prune） ==="
"$TOOL" maintain > "$BASE/out" 2> "$BASE/err"
chk "maintain 成功（forget+prune+check）" "grep -q 'prune 完成' '$BASE/err'"
"$TOOL" snapshots > "$BASE/out" 2>&1
chk "prune 后快照仍可列出（未误删）" "grep -q 'core' '$BASE/out'"
rm -rf "$BASE/recheck"
"$TOOL" restore latest --tag data --target "$BASE/recheck" >/dev/null 2>&1
chk "prune 后数据仍可恢复（sha256 复核）" \
    "[[ \$(sha256sum < '$SRC/data/blob.bin' | cut -d' ' -f1) == \$(sha256sum < '$BASE/recheck$SRC/data/blob.bin' | cut -d' ' -f1) ]]"

echo ""
echo "=== [10] 服务端实测（不信客户端自报） ==="
cloud_ls
chk "云端 repo 结构完整（config/keys/data/index/snapshots）" \
    "for d in config keys data index snapshots; do grep -q \"^testhost/\$d\" '$BASE/cloud.txt' || exit 1; done"
chk "云端 repo 有真实体积" "[[ \$(du -sk '$CLOUD' | awk '{print \$1}') -gt 100 ]]"

echo ""
echo "=== [11] 陈旧锁：诊断 + unlock 恢复（真实 restic 锁语义） ==="
# 造陈旧锁：持锁进程 SIGSTOP 冻结（模拟崩溃残留），restic 视其为有效锁。
# ⚠️ 必须**轮询等锁出现**而不是固定 sleep —— restic 去重后备份可能几百毫秒就结束，
#    固定 sleep 会错过窗口（首版即因此 0 命中）。
head -c 200000000 /dev/urandom > "$SRC/data/big.bin" 2>/dev/null || true
"$VP_RESTIC_BIN" --repo "rclone:localtest:$VP_REPO_BASE/testhost" --password-file "$VP_PASSWORD_FILE" \
  -o "rclone.program=$VP_RCLONE_BIN" backup --tag data --host testhost "$SRC/data" >/dev/null 2>&1 &
BGPID=$!
LOCKED=0
for _ in $(seq 1 60); do
  if rs list locks 2>/dev/null | grep -qE '[0-9a-f]{32,}'; then LOCKED=1; break; fi
  sleep 0.2
done
if [[ $LOCKED -eq 1 ]]; then
  kill -STOP "$BGPID" 2>/dev/null || true      # 冻结持锁进程 = 陈旧锁
  sleep 0.3
  ok "已造出陈旧锁（restic 视角可见）"
  "$TOOL" check > "$BASE/out" 2> "$BASE/err"
  chk "被锁时 check 失败并给锁诊断" "grep -q 'repo 被锁' '$BASE/err'"
  chk "给出 unlock 命令指引" "grep -q 'unlock' '$BASE/err'"
  chk "不误导用户去跑 repair" "! grep -q 'repair packs' '$BASE/err'"
  # 场景 A：锁被**存活**进程持有（SIGSTOP 冻结）→ restic unlock 不清它，
  #         工具必须如实报告「锁仍在」并指向 --all（不能假报已清理）
  "$TOOL" unlock > "$BASE/out" 2> "$BASE/err"
  chk "存活进程持锁时 unlock 如实报「锁仍在」（不假报成功）" \
      "grep -q '锁仍然存在' '$BASE/err'"
  chk "指向 --all 强制清除路径" "grep -q 'unlock --all' '$BASE/err'"
  chk "复核后 check 仍被锁阻塞（状态与实情一致）" \
      "\"$TOOL\" check > '$BASE/out' 2> '$BASE/err'; grep -q 'repo 被锁' '$BASE/err'"
  # 场景 B：持锁进程消失（真·陈旧锁）→ unlock 应清掉且复核为空
  kill -KILL "$BGPID" 2>/dev/null || true; wait "$BGPID" 2>/dev/null || true
  sleep 0.5
  "$TOOL" unlock > "$BASE/out" 2> "$BASE/err"
  chk "持锁进程消失后 unlock 清理成功（复核锁列表为空）" \
      "grep -q '已清理 repo 锁' '$BASE/err'"
  "$TOOL" check > "$BASE/out" 2> "$BASE/err"
  chk "清理后 check 恢复正常" "grep -q '校验通过' '$BASE/err'"
else
  bad "陈旧锁场景未命中（轮询 12s 仍无锁）" "restic 备份太快或后台进程异常"
fi
kill -CONT "$BGPID" 2>/dev/null || true; kill -KILL "$BGPID" 2>/dev/null || true; wait "$BGPID" 2>/dev/null || true
rm -f "$SRC/data/big.bin"

echo ""
echo "=== [12] runbook 生成 ==="
"$TOOL" runbook > /dev/null 2>&1
chk "runbook 落盘且含真实 repo 地址" "grep -q 'rclone:localtest:$VP_REPO_BASE/testhost' '$VP_RUNBOOK_FILE'"
chk "runbook 权限 600" "[[ \"\$(stat -c '%a' '$VP_RUNBOOK_FILE')\" == '600' ]]"

echo ""
echo "=== [13] 错误密码必须失败（凭证校验真实性） ==="
printf 'wrong-password\n' > "$BASE/wrongpw"; chmod 600 "$BASE/wrongpw"
chk "错误密码 → 拒绝（rc≠0）" \
    "! VP_PASSWORD_FILE='$BASE/wrongpw' \"$TOOL\" snapshots > '$BASE/out' 2>'$BASE/err'"
"$TOOL" snapshots > "$BASE/snaps2.out" 2>&1
chk "正确密码仍可用（证明是密码问题而非 repo 损坏）" "grep -qE 'core|data' '$BASE/snaps2.out'"

echo ""
echo "================================================"
echo "E2E PASS=$PASS FAIL=$FAIL"
echo "================================================"
[[ "$FAIL" -eq 0 ]]
