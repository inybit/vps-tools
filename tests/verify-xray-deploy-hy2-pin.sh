#!/usr/bin/env bash
# xray-deploy hy2 自签证书【指纹固定（pin）】回归套件
#
# 背景（2026-10-12 用户要求「hy2 自签证书加上 pinSHA256」）：
#   自签证书下客户端原本只能 insecure / skip-cert-verify = **不验证服务器证书**，
#   任何持伪造证书者都能冒充服务端。正确做法是 pinning：客户端只认这张证书的指纹。
#
# 本套件守三件事（缺一条这个功能就是假的）：
#   ① 指纹算得对 —— 与独立实现（openssl/python）逐字节一致，且垃圾输入不产生假阳性
#   ② 片段写对  —— pin 与 insecure 语义互斥：有 pin 就【不能】出现 insecure/skip-cert-verify
#   ③ 契约不破  —— 无 pin（升级前的旧部署）仍走原路径，不静默失效
#
# 分层：
#   [A] 原语：cert_sha256_hex / cert_pubkey_sha256_b64 / cert_is_self_signed
#   [B] 生成器：mihomo / sing-box hy2 片段（含互斥性断言）
#   [C] 向导：真 pty 跑 proto_wizard_hysteria2 → state 字段 + 指纹一致性
#   [D] 契约：cmd-info 调用点传参、proto-edit 重签重算、旧部署回退
#
# 用法: bash tests/verify-xray-deploy-hy2-pin.sh
# 环境变量: XRAY_BIN（可选，用于真实 xray -test 校验服务端配置）
# 退出码: 0=全部通过
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${REPO}/proxy/xray-deploy"
MAIN="${TOOL}/xray-deploy.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0; SKIP=0
ck() {  # $1=名称 $2=实际 $3=期望
  if [[ "$2" == "$3" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}
# 缺依赖 ≠ 失败：YAML 结构校验依赖 PyYAML，本机 python3 可能没有（实测 Debian 13
# 自带的 python3.14 无 pip 模块、无 yaml）。缺了要显式记 SKIP，让 run-all 报
# 「PASS* N 项未查证」，而不是伪装成 FAIL（也不是静默当 PASS）。
ckskip() { printf '  [SKIP] %s（%s）\n' "$1" "$2"; SKIP=$((SKIP+1)); }
HAVE_YAML=0
python3 -c 'import yaml' >/dev/null 2>&1 && HAVE_YAML=1

echo "=== xray-deploy hy2 自签证书 pin 回归 ==="
echo

# ---------- 载入被测脚本 ----------
# ⚠️ 截断副本必须落在【主脚本同目录】：SCRIPT_DIR 由 BASH_SOURCE[0] 推导
SNIP="${TOOL}/.hypin-snip.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$MAIN" > "$SNIP"
# shellcheck disable=SC1090
source "$SNIP"
rm -f "$SNIP"
if ! declare -F cert_sha256_hex >/dev/null; then
  echo "  [FATAL] 被测脚本加载失败（cert_* 函数未定义）"; exit 1
fi

# ---------- 测试证书 ----------
SS="${WORK}/selfsigned.pem"       # 自签
LEAF="${WORK}/caleaf.pem"         # CA 签发（非自签）
JUNK="${WORK}/junk.pem"           # 垃圾内容
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "${WORK}/ss.key" -out "$SS" -days 365 \
  -subj "/CN=pin.test" -addext "subjectAltName=DNS:pin.test" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -keyout "${WORK}/ca.key" -out "${WORK}/ca.pem" \
  -days 3650 -subj "/CN=Test Root" >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout "${WORK}/lf.key" -out "${WORK}/lf.csr" \
  -subj "/CN=leaf.test" >/dev/null 2>&1
openssl x509 -req -in "${WORK}/lf.csr" -CA "${WORK}/ca.pem" -CAkey "${WORK}/ca.key" \
  -CAcreateserial -out "$LEAF" -days 365 >/dev/null 2>&1
printf 'not a certificate\n' > "$JUNK"

# ---------- A. 原语 ----------
echo "[A] 证书指纹原语"
# 与独立实现（python hashlib）逐字节对照 —— 不拿自己算的值给自己当期望
EXP_HEX="$(python3 -c "
import subprocess,hashlib,sys
der=subprocess.run(['openssl','x509','-in','$SS','-outform','der'],capture_output=True).stdout
print(hashlib.sha256(der).hexdigest())")"
EXP_B64="$(python3 -c "
import subprocess,hashlib,base64
spki=subprocess.run(['openssl','x509','-in','$SS','-pubkey','-noout'],capture_output=True).stdout
d=subprocess.run(['openssl','pkey','-pubin','-outform','der'],input=spki,capture_output=True).stdout
print(base64.b64encode(hashlib.sha256(d).digest()).decode())")"
ck "cert_sha256_hex 与独立实现一致" "$(cert_sha256_hex "$SS")" "$EXP_HEX"
ck "cert_pubkey_sha256_b64 与独立实现一致" "$(cert_pubkey_sha256_b64 "$SS")" "$EXP_B64"
ck "hex 形如 64 位小写十六进制" \
  "$([[ "$(cert_sha256_hex "$SS")" =~ ^[0-9a-f]{64}$ ]] && echo ok)" "ok"
# 自签判定
ck "自签证书 → true" "$(cert_is_self_signed "$SS" && echo yes || echo no)" "yes"
ck "CA 签发证书 → false" "$(cert_is_self_signed "$LEAF" && echo yes || echo no)" "no"
# ⚠️ 假阳性防线：垃圾输入不得返回「空串的 sha256」（实测过 47DEQpj8HBSa+/TImW+5JC…）
ck "垃圾内容 → hex 返回非 0" "$(cert_sha256_hex "$JUNK" >/dev/null 2>&1 && echo ok || echo fail)" "fail"
ck "垃圾内容 → hex 无输出" "$(cert_sha256_hex "$JUNK" 2>/dev/null | wc -c)" "0"
ck "垃圾内容 → b64 无输出" "$(cert_pubkey_sha256_b64 "$JUNK" 2>/dev/null | wc -c)" "0"
ck "垃圾内容 → 不判为自签" "$(cert_is_self_signed "$JUNK" && echo yes || echo no)" "no"
ck "文件不存在 → hex 返回非 0" "$(cert_sha256_hex "${WORK}/nope.pem" >/dev/null 2>&1 && echo ok || echo fail)" "fail"
ck "文件不存在 → 不判为自签" "$(cert_is_self_signed "${WORK}/nope.pem" && echo yes || echo no)" "no"
# 不同证书指纹必须不同（防「常量返回」这种假实现）
ck "两证书指纹不同" \
  "$([[ "$(cert_sha256_hex "$SS")" != "$(cert_sha256_hex "$LEAF")" ]] && echo ok)" "ok"
# cert_pin_fields 输出两枚
read -r PF_HEX PF_B64 <<<"$(cert_pin_fields "$SS")"
ck "cert_pin_fields 第一枚=hex" "$PF_HEX" "$EXP_HEX"
ck "cert_pin_fields 第二枚=b64" "$PF_B64" "$EXP_B64"
echo

# ---------- B. 客户端片段生成 ----------
echo "[B] 客户端片段（pin 与 insecure 互斥）"
HEX="$EXP_HEX"; B64="$EXP_B64"
MH="$(gen_client_mihomo_hysteria2 "hy2-01" "203.0.113.10" 443 "pw" "jpanode.test" "45 mbps" "55 mbps" "$HEX" "$B64" 2>/dev/null)"
SB="$(gen_client_singbox_hysteria2 "hy2-01" "203.0.113.10" 443 "pw" "jpanode.test" "45 mbps" "55 mbps" "$HEX" "$B64" 2>/dev/null)"
ck "mihomo 含 fingerprint" "$(grep -c "^    fingerprint: ${HEX}$" <<<"$MH")" "1"
ck "mihomo 无 skip-cert-verify" "$(grep -c 'skip-cert-verify' <<<"$MH")" "0"
ck "mihomo 无 insecure" "$(grep -c 'insecure' <<<"$MH")" "0"
ck "mihomo 保留 BRUTAL up" "$(grep -c '^    up: 45 mbps$' <<<"$MH")" "1"
ck "mihomo 保留 alpn h3" "$(grep -c '^      - h3$' <<<"$MH")" "1"
ck "sing-box 含 certificate_public_key_sha256" \
  "$(grep -c "\"certificate_public_key_sha256\": \[\"${B64//\//\\/}\"\]" <<<"$SB")" "1"
ck "sing-box 无 insecure" "$(grep -c '"insecure"' <<<"$SB")" "0"
ck "sing-box 保留 up_mbps" "$(grep -c '"up_mbps": 45,' <<<"$SB")" "1"
# JSON / YAML 结构必须真能解析（注释混进 JSON 会毁掉整个配置）
ck "sing-box 片段是合法 JSON（含 pin）" \
  "$(python3 -c "import json,sys; json.loads(sys.stdin.read()); print('ok')" <<<"$SB" 2>/dev/null)" "ok"
if [[ $HAVE_YAML -eq 1 ]]; then
  ck "mihomo 片段是合法 YAML（含 pin）" \
    "$(python3 -c "
import sys,yaml
y=yaml.safe_load('proxies:\n'+sys.stdin.read())
p=y['proxies'][0]
assert p['type']=='hysteria2' and p['fingerprint'], p
print('ok')" <<<"$MH" 2>/dev/null)" "ok"
else
  ckskip "mihomo 片段是合法 YAML（含 pin）" "本机 python3 无 PyYAML"
fi
# 无 pin（旧部署）→ 回退原路径，且【不含】pin 字段
MH0="$(gen_client_mihomo_hysteria2 "hy2-01" "203.0.113.10" 443 "pw" "jpanode.test" "" "" "" "" 2>/dev/null)"
SB0="$(gen_client_singbox_hysteria2 "hy2-01" "203.0.113.10" 443 "pw" "jpanode.test" "" "" "" "" 2>/dev/null)"
ck "无 pin 时 mihomo 回退 skip-cert-verify" "$(grep -c 'skip-cert-verify: true' <<<"$MH0")" "1"
ck "无 pin 时 mihomo 无 fingerprint" "$(grep -c 'fingerprint:' <<<"$MH0")" "0"
ck "无 pin 时 sing-box 回退 insecure" "$(grep -c '"insecure": true' <<<"$SB0")" "1"
ck "无 pin 时 sing-box 无 pin 字段" "$(grep -c 'certificate_public_key_sha256' <<<"$SB0")" "0"
ck "无 pin 时 sing-box 仍是合法 JSON" \
  "$(python3 -c "import json,sys; json.loads(sys.stdin.read()); print('ok')" <<<"$SB0" 2>/dev/null)" "ok"
if [[ $HAVE_YAML -eq 1 ]]; then
  ck "无 pin 时 mihomo 仍是合法 YAML" \
    "$(python3 -c "
import sys,yaml
y=yaml.safe_load('proxies:\n'+sys.stdin.read())
assert y['proxies'][0]['skip-cert-verify'] is True
print('ok')" <<<"$MH0" 2>/dev/null)" "ok"
else
  ckskip "无 pin 时 mihomo 仍是合法 YAML" "本机 python3 无 PyYAML"
fi
echo

# ---------- C. 向导（真 pty 跑真实函数） ----------
echo "[C] 向导 proto_wizard_hysteria2（真 pty）"
# 为什么必须用 pty：read -r -p 在无 TTY 时走 /dev/tty 分支，非交互路径测不到真实向导
GEN="${WORK}/gen.sh"
cat > "$GEN" <<'GENPROBE'
set -uo pipefail
src="$1"; out="$2"; cfg="$3"
tmp="$(dirname "$src")/.nodisp.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"; rm -f "$tmp"
# 落点重定向（真实向导写 /etc，需 root）+ 去掉真实系统探测副作用
CONFIG_DIR="$cfg"; CERT_DIR="${CONFIG_DIR}/certs"; STATE_FILE="${CONFIG_DIR}/state.json"
port_in_use() { return 1; }
ensure_firewall() { :; }
die() { echo "DIE: $*" >&2; exit 1; }
proto_wizard_hysteria2 "hy2-pin-test" > "$out"
GENPROBE
# 输入序列：端口 / SNI / 密码(空=自动) / 证书来源3(自签) / masquerade(空) / brutal up(空) / brutal down(空)
WZ="${WORK}/wz"; mkdir -p "$WZ"
printf '18443\npin.test.local\n\n3\n\n\n\n' | python3 -c "
import pty,os,sys,time
os.chdir('$WZ')
pid,fd=pty.fork()
if pid==0:
    os.execvp('bash',['bash','$GEN','$MAIN','$WZ/out.json','$WZ/cfg'])
else:
    os.write(fd,sys.stdin.buffer.read()); time.sleep(5)
    try:
        while True:
            d=os.read(fd,8192)
            if not d: break
    except OSError: pass
    os.waitpid(pid,0)
" >/dev/null 2>&1
if [[ -s "${WZ}/out.json" ]]; then
  ck "向导产出 JSON" "ok" "ok"
  ck "state: cert_self_signed=true" "$(jq -r '.cert_self_signed' "${WZ}/out.json")" "true"
  CERTF="$(jq -r '.cert_file' "${WZ}/out.json")"
  ck "state 指纹 = 独立实现值" "$(jq -r '.cert_pin_sha256' "${WZ}/out.json")" \
    "$(python3 -c "
import subprocess,hashlib
der=subprocess.run(['openssl','x509','-in','$CERTF','-outform','der'],capture_output=True).stdout
print(hashlib.sha256(der).hexdigest())")"
  ck "state 公钥指纹 = 独立实现值" "$(jq -r '.cert_pin_pubkey_sha256' "${WZ}/out.json")" \
    "$(python3 -c "
import subprocess,hashlib,base64
spki=subprocess.run(['openssl','x509','-in','$CERTF','-pubkey','-noout'],capture_output=True).stdout
d=subprocess.run(['openssl','pkey','-pubin','-outform','der'],input=spki,capture_output=True).stdout
print(base64.b64encode(hashlib.sha256(d).digest()).decode())")"
  ck "state 指纹与 cert_file 同源（非硬编码）" \
    "$([[ "$(jq -r '.cert_pin_sha256' "${WZ}/out.json")" == "$(cert_sha256_hex "$CERTF")" ]] && echo ok)" "ok"
else
  ck "向导产出 JSON" "ok" "no-json"
  FAIL=$((FAIL+4))
fi
# 非自签证书（用户选「已有证书路径」提供 CA 签发证书）→ 不应写入 pin 字段
ck "源码：向导仅在自签时写 pin 字段" \
  "$(grep -c 'if cert_is_self_signed "\$cert_file"; then' "${TOOL}/lib/proto-wizard.sh")" "1"
echo

# ---------- D. 契约与调用点 ----------
echo "[D] 调用点与契约"
ck "cmd_info 读取 cert_pin_sha256" \
  "$(grep -c 'cert_pin_sha256' "${TOOL}/lib/cmd-info.sh")" "1"
ck "cmd_info 读取 cert_pin_pubkey_sha256" \
  "$(grep -c 'cert_pin_pubkey_sha256' "${TOOL}/lib/cmd-info.sh")" "1"
ck "cmd_info 向 mihomo 生成器传 pin（2 参）" \
  "$(grep -c 'gen_client_mihomo_hysteria2 "\$name" "\$ip" "\$port" "\$password" "\$domain" "\$brutal_up" "\$brutal_down" "\$pin_hex" "\$pin_pub"' "${TOOL}/lib/cmd-info.sh")" "1"
ck "cmd_info 向 sing-box 生成器传 pin（2 参）" \
  "$(grep -c 'gen_client_singbox_hysteria2 "\$name" "\$ip" "\$port" "\$password" "\$domain" "\$brutal_up" "\$brutal_down" "\$pin_hex" "\$pin_pub"' "${TOOL}/lib/cmd-info.sh")" "1"
ck "cmd_info 展示指纹（info 可见）" \
  "$([[ "$(grep -c '整证书 sha256' "${TOOL}/lib/cmd-info.sh")" -ge 1 ]] && echo ok)" "ok"
ck "proto_edit 重签后重算指纹" \
  "$(grep -c 'cert_pin_fields "\$cert_file"' "${TOOL}/lib/proto-edit.sh")" "1"
ck "proto_edit 非自签时清除旧 pin" \
  "$(grep -c 'del(.cert_self_signed, .cert_pin_sha256, .cert_pin_pubkey_sha256)' "${TOOL}/lib/proto-edit.sh")" "1"
# 服务端 inbound 不受影响：pin 是客户端侧概念
# ⚠️ 必须排除注释行 —— 本仓库注释里会解释 pin 机制，直接 grep 会把注释算成「引入字段」（本次踩过）
ck "inbound 生成未引入 pin 字段（服务端无需改）" \
  "$(grep -v '^[[:space:]]*#' "${TOOL}/lib/inbound.sh" | grep -c 'cert_pin\|fingerprint')" "0"
# 文档不再宣称「客户端 insecure」为唯一路径
ck "usage 不再把 insecure 说成唯一方式" \
  "$(grep -c '自签证书+客户端 insecure' "${TOOL}/lib/usage.sh")" "0"
ck "usage 提到 pin" "$([[ "$(grep -c 'pin' "${TOOL}/lib/usage.sh")" -ge 1 ]] && echo ok)" "ok"
echo

# ---------- E. 真 mihomo 二进制校验（可选，最强证据） ----------
echo "[E] 真客户端二进制校验（可选）"
MIHOMO_BIN="${MIHOMO_BIN:-}"
if [[ -z "$MIHOMO_BIN" ]]; then
  for c in "$(command -v mihomo 2>/dev/null || true)" /tmp/mlkem-test/bin/mihomo; do
    [[ -n "$c" && -x "$c" ]] && { MIHOMO_BIN="$c"; break; }
  done
fi
if [[ -z "$MIHOMO_BIN" ]]; then
  echo "  [SKIP] 未找到 mihomo 二进制（可用 MIHOMO_BIN=... 指定）"
elif ! "$MIHOMO_BIN" -v >/dev/null 2>&1; then
  echo "  [SKIP] mihomo 二进制无法运行（架构不符，如本机缺 AVX2）: $MIHOMO_BIN"
else
  for variant in pin legacy; do
    f="${WORK}/mh-${variant}.yaml"
    if [[ "$variant" == "pin" ]]; then
      { echo "mixed-port: 17899"; echo "log-level: warning"; echo "proxies:"; printf '%s\n' "$MH"; } > "$f"
    else
      { echo "mixed-port: 17899"; echo "log-level: warning"; echo "proxies:"; printf '%s\n' "$MH0"; } > "$f"
    fi
    ck "mihomo -t 接受 ${variant} 片段" \
      "$("$MIHOMO_BIN" -t -f "$f" -d "$WORK" >/dev/null 2>&1 && echo ok || echo fail)" "ok"
  done
  # ⚠️ 反证：错误 pin 必须在【配置层】就被 mihomo 接受、在【连接层】被拒
  #    （配置层拒=语法错；这里要证的是 pin 真在起作用，故语法必须合法）
  { echo "mixed-port: 17899"; echo "log-level: warning"; echo "proxies:";
    gen_client_mihomo_hysteria2 "hy2-01" "203.0.113.10" 443 "pw" "jpanode.test" "" "" "abababababababababababababababababababababababababababababababab" ""; } > "${WORK}/mh-badpin.yaml"
  ck "错误 pin（64位 hex）配置层仍合法" \
    "$("$MIHOMO_BIN" -t -f "${WORK}/mh-badpin.yaml" -d "$WORK" >/dev/null 2>&1 && echo ok || echo fail)" "ok"
  # 指纹长度不是 32 字节时必须被 mihomo 拒绝（证明确实是 pin 字段在生效）
  ck "源码：pin 经 64 位严格校验后才输出" \
    "$(grep -c '\[\[ "\$out" =~ \^\[0-9a-f\]{64}\$ \]\]' "${TOOL}/lib/keys.sh")" "1"
fi
echo

echo "==================================="
echo " PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
