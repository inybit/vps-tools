#!/usr/bin/env bash
# fallback-test 候选范围回归（2026-10-15）
#
# 背景（用户报障）：
#   `xray-deploy fallback-test` 无参时遍历 **候选表全部 121 条 / 10 个地区**，
#   而部署向导 select_fallback_domain 只取【服务器所在地区】。两处口径漂移：
#     · 回落域只需贴近本机 —— 跨洲候选握手延迟天然高，测了也没有选型价值；
#     · 全量 ≈ 30s/条 × 121 ≈ 1 小时，其中 90% 是白等（用户：「应该是测试该地区的全部候选」）。
#   修法：抽出 fallback_region_candidates（地区过滤单一权威源），
#         向导与 fallback-test 共用；无参 = 本地区，跨地区显式 --all。
#
# 本套件用 PATH stub 伪造 curl/openssl（零真实网络），验证：
#   [A] 静态：过滤口径单一权威源（cmd-fallback.sh 不再自行遍历候选表）
#   [B] 参数解析：无参/--region/--all/域名/非法输入的归一与拒绝
#   [C] 地区过滤：只出本地区域、tier5 排除、无该地区时候选为空
#   [D] cmd_fallback_test 行为：无参 = 本地区（不出现他国域）/ --all 才跨地区 / 单域名
#
# 用法: bash tests/verify-xray-deploy-fallback-scope.sh
# 退出码: 0=全部通过
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="${REPO}/proxy/xray-deploy/xray-deploy.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ck() {  # $1=名称 $2=实际 $3=期望
  if [[ "$2" == "$3" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

echo "=== fallback-test 候选范围回归 ==="
echo

# ---------- 网络 stub（零真实网络；地区固定 DE） ----------
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/curl" <<'STUBEOF'
#!/usr/bin/env bash
# ipinfo/ip-api → 固定国家码；-w '%{http_code}' → 200；其余（下载等）→ 失败
for a in "$@"; do
  case "$a" in
    *ipinfo.io*) printf 'DE'; exit 0 ;;
    *ip-api.com*) printf 'DE'; exit 0 ;;
  esac
done
for a in "$@"; do
  [[ "$a" == *'%{http_code}'* ]] && { printf '200'; exit 0; }
done
exit 1
STUBEOF
cat > "$STUB/openssl" <<'STUBEOF'
#!/usr/bin/env bash
# 伪装 TLS1.3 + ALPN h2 + 证书校验通过的 s_client 输出（三种格式里的 3.x 形态）
cat <<'EOS'
CONNECTED(00000003)
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
ALPN protocol: h2
Verify return code: 0 (ok)
EOS
exit 0
STUBEOF
cat > "$STUB/getent" <<'STUBEOF'
#!/usr/bin/env bash
# 零 DNS：一律返回非 CF 地址。2026-10-29 起 test_fallback_domain 会用 getent 判
# 「解析 IP ∈ CF 段」（盗刷通道本体），不打桩就会真解析真实域名 → 套件依赖外网 DNS。
echo "80.1.2.3 STREAM ${2:-stub}"
exit 0
STUBEOF
chmod +x "$STUB/curl" "$STUB/openssl" "$STUB/getent"

# 探针：source 截断后的主脚本（不触发子命令分发），PATH 前置 stub
PROBE="$TMP/probe.sh"
cat > "$PROBE" <<'PROBEEOF'
set -uo pipefail
src="$1"; shift
tmp="$(dirname "$src")/.nodisp-fbs.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"; rm -f "$tmp"
# ⚠️ 主脚本顶部有 set -euo pipefail，source 后会传染给探针：
#    ① 被测函数 return 1（正是本套件要断言的失败路径）会立刻杀掉探针；
#    ② 即使包在子 shell 里，pipefail 下 `( ... ) | sed` 整条管道也返回非 0 → 同样触发退出。
#    症状 = 后续表达式连 RC 行都不打印（verify-xray-deploy-latest.sh 同款坑）。
set +e
# 逐个求值参数（$@ 透传），每个都输出一行结果，避免一处失败杀掉后续断言
outf="$(mktemp)"
for expr in "$@"; do
  printf '>>> %s\n' "$expr"
  ( eval "$expr" ) > "$outf" 2>&1
  rc=$?
  sed 's/^/    /' "$outf"
  printf '<<< rc=%s\n' "$rc"
done
rm -f "$outf"
PROBEEOF

run_probe() { PATH="$STUB:$PATH" bash "$PROBE" "$MAIN" "$@" 2>&1; }
rc_of()  { grep -oP '^<<< rc=\K\d+' <<<"$1" | sed -n "${2:-1}p"; }
# body_of：取第 N 个表达式的输出（剥掉 >>>/<<< 标记行与 ANSI 颜色码）
body_of() { awk -v n="${2:-1}" '/^>>>/{c++} c==n && !/^>>>|^<</{print}' <<<"$1" | sed 's/\x1b\[[0-9;]*m//g'; }
# 排序结果行（"  [1] dom  (note) ✓ 20ms"）计数
ranked() { grep -cE '\[[0-9]+\] [^ ]+ +\(.*\) ✓ [0-9]+ms' <<<"$1"; }

# ---------- A. 静态：过滤口径单一权威源 ----------
echo "[A] 静态断言"
ck "fallback_region_candidates 定义在 fallback.sh" \
  "$(grep -c '^fallback_region_candidates()' "${REPO}/proxy/xray-deploy/lib/fallback.sh")" "1"
ck "部署向导复用 fallback_region_candidates" \
  "$([[ "$(grep -c 'fallback_region_candidates' "${REPO}/proxy/xray-deploy/lib/fallback.sh")" -ge 2 ]] && echo ok)" "ok"
ck "fallback-test 复用 fallback_region_candidates" \
  "$([[ "$(grep -c 'fallback_region_candidates' "${REPO}/proxy/xray-deploy/lib/cmd-fallback.sh")" -ge 1 ]] && echo ok)" "ok"
# 默认路径（无参）不得再整表遍历：FALLBACK_CANDIDATES 只允许出现在 --all 分支
ck "cmd-fallback.sh 引用 FALLBACK_CANDIDATES 仅 --all 分支（≤1 处）" \
  "$(grep -c 'for line in "\${FALLBACK_CANDIDATES\[@\]}"' "${REPO}/proxy/xray-deploy/lib/cmd-fallback.sh")" "1"
ck "菜单/帮助声明本地区默认口径（usage）" \
  "$(grep -c '回落域名握手延迟并排序（无参=本地区候选）' "${REPO}/proxy/xray-deploy/lib/usage.sh")" "1"
echo

# ---------- B. 参数解析 ----------
echo "[B] 参数解析（_fallback_test_target）"
o="$(run_probe \
  '_fallback_test_target' \
  '_fallback_test_target --all' \
  '_fallback_test_target --region de' \
  '_fallback_test_target -r jp' \
  '_fallback_test_target www.example.com' \
  '_fallback_test_target --region DEU' \
  '_fallback_test_target --bogus')"
ck "无参 → 本机地区" "$(body_of "$o" 1 | tr -d ' ')" "region|DE"
ck "无参 rc=0" "$(rc_of "$o" 1)" "0"
ck "--all → 全量" "$(body_of "$o" 2 | tr -d ' ')" "all|"
ck "--region de → 归一为大写" "$(body_of "$o" 3 | tr -d ' ')" "region|DE"
ck "-r jp → 别名可用" "$(body_of "$o" 4 | tr -d ' ')" "region|JP"
ck "裸域名 → domain 模式" "$(body_of "$o" 5 | tr -d ' ')" "domain|www.example.com"
ck "非法国家码 DEU 被拒 rc=1" "$(rc_of "$o" 6)" "1"
ck "非法国家码给出提示" "$([[ "$(body_of "$o" 6 | grep -c '两位国家码')" -ge 1 ]] && echo ok)" "ok"
ck "未知选项被拒 rc=1" "$(rc_of "$o" 7)" "1"
ck "未知选项给出用法" "$([[ "$(body_of "$o" 7 | grep -c '未知选项')" -ge 1 ]] && echo ok)" "ok"
echo

# ---------- C. 地区过滤 ----------
echo "[C] 地区过滤（fallback_region_candidates）"
o="$(run_probe \
  'fallback_region_candidates DE' \
  'fallback_region_candidates ZZ' \
  'fallback_region_candidates JP | wc -l' \
  'fallback_region_candidates DE | awk -F"|" "{print \$1}" | grep -cE "harvard|waseda|gov.hk"')"
ck "DE 候选数 = 12" "$(body_of "$o" 1 | grep -c '|')" "12"
ck "JP 候选数 = 14" "$(body_of "$o" 3 | tr -d ' ')" "14"
ck "无该地区候选 → rc=1（不 die）" "$(rc_of "$o" 2)" "1"
ck "DE 结果不含他国域" "$(body_of "$o" 4 | tr -d ' ')" "0"
echo

# ---------- D. cmd_fallback_test 行为 ----------
echo "[D] cmd_fallback_test 范围（mock 网络，DE 地区）"
o="$(run_probe 'cmd_fallback_test' 'cmd_fallback_test --all' 'cmd_fallback_test www.harvard.edu')"
# D1 无参 = 本地区
d1="$(body_of "$o" 1)"
ck "无参：声明本地区候选 12 个" "$([[ "$(grep -c '本地区候选 12 个' <<<"$d1")" -ge 1 ]] && echo ok)" "ok"
ck "无参：出现本地区域" "$([[ "$(grep -c 'www.tu-berlin.de' <<<"$d1")" -ge 1 ]] && echo ok)" "ok"
# ⚠️ 关键断言：他国候选一条都不能出现（旧 bug 会全测 121 条）
ck "无参：不出现他国候选（harvard/cam.ac.uk/nhk）" \
  "$(grep -cE 'harvard\.edu|cam\.ac\.uk|nhk\.or\.jp|ntu\.edu\.sg|gov\.hk' <<<"$d1")" "0"
ck "无参：通过候选恰好 12 条" "$(ranked "$d1")" "12"
ck "无参 rc=0（有通过候选）" "$(rc_of "$o" 1)" "0"
# D2 --all = 跨地区
d2="$(body_of "$o" 2)"
ck "--all：出现他国候选" "$([[ "$(grep -c 'www.harvard.edu' <<<"$d2")" -ge 1 ]] && echo ok)" "ok"
ck "--all：跨地区告警可见" "$([[ "$(grep -c '跨地区全量模式' <<<"$d2")" -ge 1 ]] && echo ok)" "ok"
ck "--all：通过候选数 > 本地区 12" \
  "$([[ "$(ranked "$d2")" -gt 12 ]] && echo ok)" "ok"
# D3 单域名模式
d3="$(body_of "$o" 3)"
ck "单域名：只测该域" "$(ranked "$d3")" "1"
ck "单域名：标注为自定义" "$([[ "$(grep -c '自定义' <<<"$d3")" -ge 1 ]] && echo ok)" "ok"
echo

# ---------- E. 帮助文本 ----------
echo "[E] 帮助文本同步"
h="$(PATH="$STUB:$PATH" bash "$MAIN" -h 2>&1 || true)"
ck "usage 声明无参=本地区候选" "$([[ "$(grep -c '无参=本地区候选' <<<"$h")" -ge 1 ]] && echo ok)" "ok"
ck "usage 声明 --all" "$([[ "$(grep -c -- '--all' <<<"$h")" -ge 1 ]] && echo ok)" "ok"
echo

echo "==================================="
printf ' PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
