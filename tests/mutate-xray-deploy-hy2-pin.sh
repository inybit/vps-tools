#!/usr/bin/env bash
# 变异测试：把产品代码逐条改坏，套件必须判红。漏检 = 套件对该缺陷无感知。
#
# ⚠️⚠️ 血泪教训（本脚本踩过两次，都是"测试基建自己造成的破坏"）：
#   第 1 版：用 `cp file /tmp/orig` 备份、`cp` 还原 → 还原静默失效，变异【累积】，
#            后续判定全部不可信（还误报两条「漏检」）。
#   第 2 版：改用 `git checkout -- <file>` 还原 → 它把**未提交的产品改动**一起
#            抹回 HEAD，一次运行销毁了 6 个文件的本轮工作（靠运行前的副本救回）。
#
#   ⇒ 铁律：变异测试的还原动作【绝不能碰工作区里未提交的改动】。
#     正解：先把待测状态提交成临时 commit，再在干净 HEAD 上做变异 + `git checkout`，
#           跑完 `git reset --soft` 回到原状态。这样还原目标恒等于"提交过的基线"。
#
# 用法: bash tests/mutate-xray-deploy-hy2-pin.sh
# 环境变量: MIHOMO_BIN（可选，透传给套件的真二进制校验段）
set -uo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TOOL="proxy/xray-deploy"
SUITE="tests/verify-xray-deploy-hy2-pin.sh"

if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "⚠️ 工作区有未提交改动。本脚本会建临时 commit 做基线，跑完用 reset --soft 还原。"
  echo "   现有改动会被一并纳入临时 commit（内容不变，只是 git 索引状态变化）。"
fi

# ---- 建临时基线 commit（不推送，跑完 soft reset 撤销）----
git add -A
BASELINE_MSG="tmp: hy2-pin mutation baseline"
git -c user.name=mutate -c user.email=mutate@local commit -q -m "$BASELINE_MSG" || true
BASE_SHA="$(git rev-parse HEAD)"
restore_all() { git checkout -- . 2>/dev/null || true; git reset -q --soft "$BASE_SHA" 2>/dev/null || true; }
trap 'git reset -q --soft "$BASE_SHA" 2>/dev/null || true' EXIT

# 变异只能在【已提交内容】上做，故还原 = `git checkout -- .`（回到 BASE_SHA 的树）
run_mut() {  # $1=名称 $2=文件 $3=old $4=new
  local name="$1" f="$2" old="$3" new="$4" out rc p fl

  git checkout -q -- . 2>/dev/null || true   # 先回到基线树（此处无未提交改动，安全）
  if ! python3 - "$f" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding='utf-8').read()
if old not in s:
    sys.exit(1)
open(p, 'w', encoding='utf-8').write(s.replace(old, new, 1))
PY
  then
    echo "  ⚠️ 变异未生效（模式未匹配）: ${name}"; return 2
  fi

  out="$(bash "$SUITE" 2>&1)"; rc=$?
  p="$(grep -oP 'PASS=\K[0-9]+' <<<"$out" | tail -1)"
  fl="$(grep -oP 'FAIL=\K[0-9]+' <<<"$out" | tail -1)"

  git checkout -q -- . 2>/dev/null || true   # 精确还原（目标 = BASE_SHA 的树）
  if ! git diff --quiet -- "$f"; then
    echo "  ⚠️ 还原失败，中止: ${name}"; return 3
  fi

  if [[ $rc -ne 0 ]]; then
    echo "  ✅ 检出  ${name}  (PASS=${p:-?} FAIL=${fl:-?})"; return 0
  else
    echo "  ❌ 漏检  ${name}  (套件仍全绿 PASS=${p:-?})"; return 1
  fi
}

echo "=== 基线（提交 ${BASE_SHA:0:8}）==="
if ! bash "$SUITE" >/dev/null 2>&1; then echo "  ❌ 基线不绿，变异测试无意义"; exit 1; fi
echo "  基线全绿 ✅"
echo

echo "=== 变异（每条都必须被判红）==="
miss=0; total=0
m() { total=$((total+1)); run_mut "$@" || miss=$((miss+1)); }

# ⚠️ 变异写法本身要有效：曾在函数中部注入 iss/sub 赋值，结果被下方 openssl 赋值
#    覆盖 → 行为不变 → 套件正确地保持绿，却被误记为「漏检」。变异必须改变【有效行为】。
m "自签判定永远返回真（真证书也当自签）" "$TOOL/lib/keys.sh" \
  '  [[ "${iss#*=}" == "${sub#*=}" ]]' \
  '  return 0'

m "hex 长度校验放宽（防截断/空值防线失效）" "$TOOL/lib/keys.sh" \
  '^[0-9a-f]{64}$' '^[0-9a-f]+$'

m "去掉解析守卫（垃圾输入产出假指纹）" "$TOOL/lib/keys.sh" \
  'cert_parses "$1" || return 1
  local out
  out="$(openssl x509 -in "$1" -pubkey' \
  'local out
  out="$(openssl x509 -in "$1" -pubkey'

m "mihomo 片段 pin 与 insecure 并存（pin 白写）" "$TOOL/lib/client-mihomo.sh" \
  '    fingerprint: ${pin}' \
  '    fingerprint: ${pin}
    skip-cert-verify: true'

# ⚠️ 同上：`${pin:-$pubpin}` 是空操作（本函数无 $pin 变量）→ 套件保持绿是【正确】的。
#    真缺陷是「哈希对象用错」：把整证书 hex（$8）当公钥 base64 写进字段。
m "sing-box 用整证书 hex 冒充公钥 pin（哈希对象错）" "$TOOL/lib/client-singbox.sh" \
  '"certificate_public_key_sha256": ["${pubpin}"],' \
  '"certificate_public_key_sha256": ["${8}"],'

m "向导不把 pin 写进 state" "$TOOL/lib/proto-wizard.sh" \
  '{ cert_self_signed: true, cert_pin_sha256: $pin_hex, cert_pin_pubkey_sha256: $pin_b64 }' \
  '{}'

m "cmd_info 不传 pin（静默退回 insecure）" "$TOOL/lib/cmd-info.sh" \
  '"$brutal_up" "$brutal_down" "$pin_hex" "$pin_pub"
    elif [[ "$type" == "ss2022" ]]' \
  '"$brutal_up" "$brutal_down" "" ""
    elif [[ "$type" == "ss2022" ]]'

m "proto_edit 重签后不重算公钥指纹" "$TOOL/lib/proto-edit.sh" \
  'cert_pin_fields "$cert_file"' 'cert_sha256_hex "$cert_file"'

echo
echo "=== 收尾 ==="
git checkout -q -- . 2>/dev/null || true
if [[ "$(git rev-parse HEAD)" != "$BASE_SHA" ]]; then
  echo "  ⚠️ HEAD 意外变动，需人工检查"
else
  echo "  工作区已回到基线（git reset --soft ${BASE_SHA:0:8} 后改动仍在）"
fi
bash "$SUITE" >/dev/null 2>&1 && echo "  基线套件仍全绿 ✅" || echo "  ⚠️ 基线套件非绿"
echo
echo "变异检出: $((total-miss))/$total   漏检: $miss"
[[ "$miss" -eq 0 ]]
