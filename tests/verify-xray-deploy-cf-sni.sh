#!/usr/bin/env bash
# CF 前置判定 + REALITY SNI 闸门回归（2026-10-29）
#
# 背景（用户需求）：
#   ① 回落域名必须排除套了 CF 的；② REALITY 必须检查 SNI，防止流量被盗刷。
#   旧实现只在 openssl 输出里 grep "cloudflare"（实际命中证书签发者），而 CF 已大量改用
#   GTS(WE1/YE1)/InCommon/Sectigo 签证书 → 实测候选表 121 条里 13 条 CF 前置全漏判
#   （含标「实测可用」的 waseda.jp / ntu.edu.sg）。dest 套 CF → REALITY 把未鉴权流量
#   转发到 CF 边缘 IP，本机变成 CF 免费转发器（XTLS/Xray-core#2360、#5807）。
#
# 本套件零真实网络（PATH stub 伪造 curl/openssl/getent），验证：
#   [A] 静态：三路判定落地、旧 grep 已移除、新 lib 已 source、子命令已分发
#   [B] IP 运算：v4 CIDR / CF v4 段 / CF v6 段（含 2a06:98c0::/29 的掩码边界）
#   [C] cf_front_reason：三个信号各自单独命中 + 非 CF 返回空
#   [D] test_fallback_domain：CF 三路均拒；TLS/H2/证书/可达性各自报对原因
#   [E] check_reality_sni：CF / IP 形态 / 空 / 证书 SAN 不覆盖 / 通过
#   [F] 逃逸阀：XRAY_DEPLOY_ALLOW_CDN_SNI=1 放行但打警告
#   [G] cmd_reality_check：存量体检（有坏 → rc1 + 修复指引；全好 → rc0；无 REALITY → rc0）
#   [H] 帮助文本声明 reality-check
#
# 用法: bash tests/verify-xray-deploy-cf-sni.sh
# 退出码: 0=全部通过
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="${REPO}/proxy/xray-deploy/xray-deploy.sh"
LIB="${REPO}/proxy/xray-deploy/lib"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ck() {  # $1=名称 $2=实际 $3=期望
  if [[ "$2" == "$3" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}
has() { [[ "$(grep -c -- "$2" <<<"$1")" -ge 1 ]] && echo ok || echo no; }

echo "=== CF 前置判定 + REALITY SNI 闸门回归 ==="
echo

# ---------- 网络 stub（零真实网络；域名决定行为） ----------
STUB="$TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/curl" <<'STUBEOF'
#!/usr/bin/env bash
dom=""; want_code=0
for a in "$@"; do
  case "$a" in
    https://*|http://*) d="${a#*://}"; dom="${d%%/*}" ;;
    *'%{http_code}'*)   want_code=1 ;;
  esac
done
if (( want_code )); then
  case "$dom" in www.dead.example) printf '000' ;; *) printf '200' ;; esac
  exit 0
fi
case "$dom" in
  www.cf-front.example) printf 'HTTP/1.1 200 OK\r\ncf-ray: 8a1b2c3d4e5f-SIN\r\nserver: cloudflare\r\n\r\n' ;;
  www.cf-hdr.example)   printf 'HTTP/1.1 200 OK\r\nserver: cloudflare\r\n\r\n' ;;
  *)                    printf 'HTTP/1.1 200 OK\r\nserver: nginx\r\n\r\n' ;;
esac
exit 0
STUBEOF
cat > "$STUB/getent" <<'STUBEOF'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in
  ahostsv4:www.cf-front.example) echo "104.18.31.156      STREAM www.cf-front.example" ;;
  ahostsv6:www.cf-front.example) echo "2606:4700::6812:1f9c STREAM www.cf-front.example" ;;
  ahostsv4:www.cf-ip.example)    echo "104.20.1.2         STREAM www.cf-ip.example" ;;
  ahostsv4:www.ok.example)       echo "80.1.2.3           STREAM www.ok.example" ;;
esac
exit 0
STUBEOF
cat > "$STUB/id" <<'STUBEOF'
#!/usr/bin/env bash
# 短路 root 判定：need_root 用 $(id -u)，GitHub Actions runner 是普通用户（非 root），
# 不打桩则 cmd_reality_check 直接 die「需要 root」，[G] 段断言全错（2026-10-29 CI 实测）。
[[ "${1:-}" == "-u" ]] && { echo 0; exit 0; }
if [[ -x /usr/bin/id ]]; then exec /usr/bin/id "$@"; fi
if [[ -x /bin/id ]]; then exec /bin/id "$@"; fi
exit 0
STUBEOF
cat > "$STUB/openssl" <<'STUBEOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "x509" ]]; then
  dom=""; prev=""
  for a in "$@"; do [[ "$prev" == "-checkhost" ]] && dom="$a"; prev="$a"; done
  case "$dom" in
    www.bad-san.example) echo "Hostname $dom does NOT match certificate"; exit 1 ;;
    *)                   echo "Hostname $dom does match certificate"; exit 0 ;;
  esac
fi
conn=""; prev=""
for a in "$@"; do [[ "$prev" == "-connect" ]] && conn="${a%%:*}"; prev="$a"; done
case "$conn" in
  www.tls12.example) printf 'CONNECTED(00000003)\nNew, TLSv1.2, Cipher is ECDHE-RSA-AES256-GCM-SHA384\nALPN protocol: h2\nVerify return code: 0 (ok)\n'; exit 0 ;;
  www.no-h2.example) printf 'CONNECTED(00000003)\nNew, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384\nALPN protocol: http/1.1\nVerify return code: 0 (ok)\n'; exit 0 ;;
  www.bad-cert.example) printf 'CONNECTED(00000003)\nNew, TLSv1.3, Cipher is X\nALPN protocol: h2\nVerify return code: 20 (unable to get local issuer certificate)\n'; exit 0 ;;
esac
issuer="CN = R11"
[[ "$conn" == "www.cf-issuer.example" ]] && issuer="CN = Cloudflare Inc ECC CA-3"
printf 'CONNECTED(00000003)\n---\nissuer=%s\nNew, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384\nALPN protocol: h2\nVerify return code: 0 (ok)\n-----BEGIN CERTIFICATE-----\nMIIBfake\n-----END CERTIFICATE-----\n' "$issuer"
exit 0
STUBEOF
chmod +x "$STUB/curl" "$STUB/getent" "$STUB/openssl" "$STUB/id"

# 探针：source 截断后的主脚本（不触发子命令分发），PATH 前置 stub
PROBE="$TMP/probe.sh"
cat > "$PROBE" <<'PROBEEOF'
set -uo pipefail
src="$1"; shift
tmp="$(dirname "$src")/.nodisp-cfsni.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"; rm -f "$tmp"
# ⚠️ 主脚本顶部 set -euo pipefail 会传染给探针：被测函数 return 1 正是本套件的断言对象，
#    必须关掉 -e，否则第一处失败路径直接杀掉探针（后续断言连 RC 行都不打印）。
set +e
outf="$(mktemp)"
for expr in "$@"; do
  printf '>>> %s\n' "$expr"
  ( eval "$expr" ) > "$outf" 2>&1
  rc=$?
  sed 's/^/    /' "$outf"
  # ⚠️ 被测函数可能用 printf '%s'（无尾换行）输出原因，直接打 rc 标记会粘在同一行
  #    → `^<<< rc=` 匹配不到，后续断言索引整体错位（本套件踩过）
  [[ -s "$outf" && -n "$(tail -c1 "$outf")" ]] && echo
  printf '<<< rc=%s\n' "$rc"
done
rm -f "$outf"
PROBEEOF

run_probe() { PATH="$STUB:$PATH" bash "$PROBE" "$MAIN" "$@" 2>&1; }
rc_of()  { grep -oP '^<<< rc=\K\d+' <<<"$1" | sed -n "${2:-1}p"; }
body_of() { awk -v n="${2:-1}" '/^>>>/{c++} c==n && !/^>>>|^<</{print}' <<<"$1" | sed 's/\x1b\[[0-9;]*m//g'; }

# ---------- A. 静态 ----------
echo "[A] 静态断言"
ck "cdn-detect.sh 定义 CF_V4_RANGES" "$(grep -c '^CF_V4_RANGES=(' "$LIB/cdn-detect.sh")" "1"
ck "cdn-detect.sh 定义 CF_V6_RANGES" "$(grep -c '^CF_V6_RANGES=(' "$LIB/cdn-detect.sh")" "1"
ck "旧「证书签发者单路」grep 已从 fallback.sh 移除" "$(grep -c 'grep -qi "cloudflare"' "$LIB/fallback.sh")" "0"
ck "fallback.sh 调用 cf_front_reason" "$([[ "$(grep -c 'cf_front_reason' "$LIB/fallback.sh")" -ge 1 ]] && echo ok)" "ok"
ck "select_fallback_domain 自有域名分支过 check_reality_sni" \
  "$([[ "$(grep -c 'check_reality_sni "$server_domain"' "$LIB/fallback.sh")" -ge 1 ]] && echo ok)" "ok"
ck "proto_add 有 REALITY 兜底闸门" "$([[ "$(grep -c 'cf_sni_gate' "$LIB/proto-crud.sh")" -ge 1 ]] && echo ok)" "ok"
ck "主脚本 source cdn-detect.sh" "$(grep -c 'cdn-detect.sh' "$MAIN")" "1"
ck "主脚本 source sni-check.sh" "$(grep -c 'sni-check.sh' "$MAIN")" "1"
ck "主脚本分发 reality-check" "$(grep -c 'reality-check) cmd_reality_check' "$MAIN")" "1"
echo

# ---------- B. IP 运算 ----------
echo "[B] IP 运算（纯 bash，无 awk/ipcalc）"
o="$(run_probe \
  'ip_in_cidr4 104.18.31.156 104.16.0.0/13' \
  'ip_in_cidr4 8.8.8.8 104.16.0.0/13' \
  'ip_in_cidr4 104.18.31.156 104.24.0.0/14' \
  'ip_in_cf_v4 172.66.135.198' \
  'ip_in_cf_v4 1.1.1.1' \
  'ip_in_cf_v6 2606:4700::6812:1f9c' \
  'ip_in_cf_v6 2a06:98c7::1' \
  'ip_in_cf_v6 2001:4860:4860::8888')"
ck "104.18.31.156 ∈ 104.16.0.0/13" "$(rc_of "$o" 1)" "0"
ck "8.8.8.8 ∉ 104.16.0.0/13" "$(rc_of "$o" 2)" "1"
ck "104.18.31.156 ∉ 104.24.0.0/14" "$(rc_of "$o" 3)" "1"
ck "172.66.135.198 ∈ CF v4 段" "$(rc_of "$o" 4)" "0"
ck "1.1.1.1 ∉ CF 服务段（DNS 段不在 ips-v4 列表）" "$(rc_of "$o" 5)" "1"
ck "2606:4700::/32 命中" "$(rc_of "$o" 6)" "0"
ck "2a06:98c7::1 命中（/29 掩码边界，非 /32 精确匹配）" "$(rc_of "$o" 7)" "0"
ck "Google v6 不命中" "$(rc_of "$o" 8)" "1"
echo

# ---------- C. cf_front_reason 三路 ----------
echo "[C] cf_front_reason（三路取并集）"
o="$(run_probe \
  'cf_front_reason www.cf-front.example' \
  'cf_front_reason www.cf-ip.example' \
  'cf_front_reason www.cf-issuer.example "issuer=CN = Cloudflare Inc ECC CA-3"' \
  'cf_front_reason www.cf-hdr.example' \
  'cf_front_reason www.ok.example')"
ck "信号①cf-ray + ②IP 段 均命中" \
  "$([[ "$(has "$(body_of "$o" 1)" 'cf-ray')" == ok && "$(has "$(body_of "$o" 1)" '∈ CF 段')" == ok ]] && echo ok)" "ok"
ck "信号②单独命中（仅 A 记录在 CF 段）" "$(has "$(body_of "$o" 2)" 'A 104.20.1.2 ∈ CF 段')" "ok"
ck "信号③单独命中（仅证书签发者）" "$(has "$(body_of "$o" 3)" '证书签发者 Cloudflare')" "ok"
ck "仅 server: cloudflare 头也命中" "$(has "$(body_of "$o" 4)" 'server: cloudflare')" "ok"
ck "非 CF 域名 → rc=1 且无输出" "$(rc_of "$o" 5)" "1"
ck "非 CF 域名输出为空" "$(tr -d ' \n' <<<"$(body_of "$o" 5)")" ""
echo

# ---------- D. test_fallback_domain ----------
echo "[D] test_fallback_domain（候选/fallback-test 共用）"
o="$(run_probe \
  'test_fallback_domain www.cf-front.example' \
  'test_fallback_domain www.cf-ip.example' \
  'test_fallback_domain www.cf-issuer.example' \
  'test_fallback_domain www.ok.example' \
  'test_fallback_domain www.tls12.example' \
  'test_fallback_domain www.no-h2.example' \
  'test_fallback_domain www.bad-cert.example' \
  'test_fallback_domain www.dead.example')"
ck "CF（响应头+IP）被拒" "$(has "$(body_of "$o" 1)" 'Cloudflare 前置')" "ok"
ck "CF（仅 IP 段）被拒" "$(has "$(body_of "$o" 2)" 'Cloudflare 前置')" "ok"
ck "CF（仅签发者）被拒" "$(has "$(body_of "$o" 3)" 'Cloudflare 前置')" "ok"
ck "正常域名通过" "$(tr -d ' \n' <<<"$(body_of "$o" 4)")" "ok"
ck "TLS1.2 被拒" "$(has "$(body_of "$o" 5)" 'TLSv1.3 不支持')" "ok"
ck "无 H2 被拒" "$(has "$(body_of "$o" 6)" '不支持 H2')" "ok"
ck "证书链无效被拒" "$(has "$(body_of "$o" 7)" '证书校验失败')" "ok"
ck "HTTP 000 被拒" "$(has "$(body_of "$o" 8)" '连接失败（HTTP 000）')" "ok"
echo

# ---------- E. check_reality_sni ----------
echo "[E] check_reality_sni（REALITY 闸门）"
o="$(run_probe \
  'check_reality_sni www.ok.example' \
  'check_reality_sni www.cf-front.example' \
  'check_reality_sni 1.2.3.4' \
  'check_reality_sni ""' \
  'check_reality_sni www.bad-san.example')"
ck "合格域名 → ok" "$(tr -d ' \n' <<<"$(body_of "$o" 1)")" "ok"
ck "CF 前置被拒（说明盗刷机制）" "$(has "$(body_of "$o" 2)" '流量被盗刷')" "ok"
ck "IP 形态被拒" "$(has "$(body_of "$o" 3)" '不能是 IP')" "ok"
ck "空 SNI 被拒" "$(has "$(body_of "$o" 4)" 'SNI 为空')" "ok"
ck "证书 SAN 不覆盖被拒" "$(has "$(body_of "$o" 5)" 'SAN 不覆盖')" "ok"
echo

# ---------- F. 逃逸阀 ----------
echo "[F] 逃逸阀 XRAY_DEPLOY_ALLOW_CDN_SNI=1"
o="$(run_probe '(export XRAY_DEPLOY_ALLOW_CDN_SNI=1; cf_sni_gate www.cf-front.example)')"
ck "显式放行 → rc=0" "$(rc_of "$o" 1)" "0"
ck "放行时打出警告" "$(has "$(body_of "$o" 1)" '流量可能被盗刷')" "ok"
echo

# ---------- G. cmd_reality_check ----------
echo "[G] cmd_reality_check（存量只读体检）"
cat > "$TMP/s-mixed.json" <<'EOF'
{"protocols":[{"name":"r-bad","type":"vless-reality","port":443,"sni":"www.cf-front.example"},
              {"name":"r-ok","type":"vless-reality","port":8443,"sni":"www.ok.example"}]}
EOF
cat > "$TMP/s-good.json" <<'EOF'
{"protocols":[{"name":"r-ok","type":"vless-reality","port":443,"sni":"www.ok.example"}]}
EOF
cat > "$TMP/s-none.json" <<'EOF'
{"protocols":[{"name":"hy","type":"hysteria2","port":443,"domain":"www.ok.example"}]}
EOF
o="$(run_probe \
  "STATE_FILE=$TMP/s-mixed.json cmd_reality_check" \
  "STATE_FILE=$TMP/s-good.json cmd_reality_check" \
  "STATE_FILE=$TMP/s-none.json cmd_reality_check")"
ck "有坏 SNI → rc=1" "$(rc_of "$o" 1)" "1"
ck "指出具体协议与原因" "$(has "$(body_of "$o" 1)" 'r-bad')" "ok"
ck "给出修复命令" "$(has "$(body_of "$o" 1)" 'protocol edit r-bad')" "ok"
ck "汇总 1/2 不合格" "$(has "$(body_of "$o" 1)" '1/2')" "ok"
ck "全部合格 → rc=0" "$(rc_of "$o" 2)" "0"
ck "全部合格打 OK" "$(has "$(body_of "$o" 2)" '全部 1 个 REALITY 协议 SNI 合格')" "ok"
ck "无 REALITY 协议 → rc=0 且提示" \
  "$([[ "$(rc_of "$o" 3)" == 0 && "$(has "$(body_of "$o" 3)" '无 REALITY 协议')" == ok ]] && echo ok)" "ok"
echo

# ---------- H. 帮助文本 ----------
echo "[H] 帮助文本同步"
h="$(PATH="$STUB:$PATH" bash "$MAIN" -h 2>&1 || true)"
ck "usage 声明 reality-check" "$(has "$h" 'reality-check')" "ok"
ck "usage 说明 CF 三路判定" "$(has "$h" '三路判')" "ok"
ck "-h 无 stderr 噪声（反引号未展开成命令）" "$(PATH="$STUB:$PATH" bash "$MAIN" -h 2>&1 >/dev/null | grep -c 'command not found')" "0"
echo

echo "==================================="
printf ' PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
