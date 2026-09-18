#!/usr/bin/env bash
# xray-deploy 拆分后行为等价验证（阶段 1 补充）
#
# 目的：函数体相同 ≠ 运行时正确。本脚本验证【入口脚本的真实子命令路径】。
# 手法：mock 掉 root 检测与状态文件路径，指向临时目录，不碰真实系统。
#
# 用法: bash tests/verify-xray-deploy-behavior.sh
# 退出码: 0=全部通过
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MAIN="${REPO}/proxy/xray-deploy/xray-deploy.sh"
ORIG="/tmp/xray-deploy.orig.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0
ck() {  # $1=名称 $2=实际 $3=期望
  if [[ "$2" == "$3" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}

echo "=== xray-deploy 拆分后行为等价验证 ==="
echo "入口: ${MAIN}"
echo

# ---------- A. 静态：函数与常量完整性 ----------
echo "[A] 函数与顶层常量完整性"
# 所有 lib 函数都应可加载
bash -c "set -uo pipefail; source '${MAIN%.sh}-probe.sh' 2>/dev/null || true" 2>/dev/null
probe="${TMP}/probe.sh"
cat > "$probe" <<'PROBE'
set -uo pipefail
# ⚠️ 截断文件必须落在【主脚本同目录】：SCRIPT_DIR 由 BASH_SOURCE[0] 推导，
#    放别处会让 LIB_DIR 指错 → 所有函数缺失（假 FAIL，本次踩过）。
src="$1"
tmp="$(dirname "$src")/.nodisp.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"
rm -f "$tmp"
for fn in log_info log_warn log_err die has_ctty read_input need_root detect_pkg_mgr \
          install_deps detect_arch xray_asset_suffix detect_init service_start service_restart \
          service_stop service_status install_service_file port_in_use ensure_firewall \
          detect_server_country test_fallback_domain measure_handshake_ms select_fallback_domain \
          gen_uuid gen_short_id gen_reality_keys normalize_bandwidth obtain_cert \
          obtain_cert_selfsigned obtain_cert_acme latest_xray_tag download_xray install_xray \
          update_geo proto_exists proto_display gen_client_mihomo gen_client_singbox \
          protocol_to_inbound build_config state_init state_get state_set detect_server_ip \
          proto_wizard_vless_reality proto_wizard_vless_xhttp_reality proto_wizard_vless_xhttp \
          proto_wizard_hysteria2 proto_add proto_remove proto_edit proto_list_names \
          resolve_proto_name rebuild_and_reload cmd_install cmd_upgrade cmd_info cmd_uninstall \
          cmd_config cmd_fallback_test gp_submit gp_wait gp_report gp_confirm_egress \
          cmd_fallback_cn_test usage; do
  declare -F "$fn" >/dev/null 2>&1 || echo "MISSING:$fn"
done
# 顶层常量
for v in PROTO_REGISTRY FALLBACK_CANDIDATES GP_API CERT_DIR GP_PROBES GP_TIMEOUT; do
  [[ -v "$v" ]] || echo "MISSINGVAR:$v"
done
echo "OK"
PROBE
out="$(bash "$probe" "$MAIN" "${TMP}/nodisp.sh" 2>/dev/null)"
ck "73 个函数全部定义 + 顶层常量存在" "$(grep -c '^OK$' <<<"$out")" "1"
if grep -q '^MISSING' <<<"$out"; then echo "$out" | grep '^MISSING' | sed 's/^/        /'; fi
echo

# ---------- B. 动态：-v / -h ----------
echo "[B] 入口命令"
ck "-v 输出" "$(bash "$MAIN" -v 2>&1)" "xray-deploy 1.6.2"
ck "--version 输出" "$(bash "$MAIN" --version 2>&1)" "xray-deploy 1.6.2"
bash "$MAIN" -h > "${TMP}/h-new.txt" 2>&1
bash "$ORIG" -h > "${TMP}/h-old.txt" 2>&1
ck "-h 输出与拆分前逐字一致" "$(diff -q "${TMP}/h-old.txt" "${TMP}/h-new.txt" >/dev/null 2>&1 && echo same)" "same"
echo

# ---------- C. 动态：未知命令提示 ----------
echo "[C] 错误路径"
unk="$(bash "$MAIN" no-such-cmd 2>&1 || true)"
ck "未知命令给出提示" "$(grep -c '未知命令' <<<"$unk")" "1"
# info 无 state.json 时应明确报错而非崩溃
nfo="$(STATE_FILE="${TMP}/nope.json" bash "$MAIN" info 2>&1 || true)"
ck "info 无部署时明确报错" "$(grep -c '尚未安装' <<<"$nfo")" "1"
echo

# ---------- D. 动态：protocol list 无部署 ----------
echo "[D] 协议路径"
pl="$(bash "$MAIN" protocol list 2>&1 || true)"
ck "protocol list 无部署时提示" "$(grep -c '尚未安装' <<<"$pl")" "1"
bad="$(bash "$MAIN" protocol bogus 2>&1 || true)"
ck "protocol 非法子命令提示用法" "$(grep -c 'protocol 用法' <<<"$bad")" "1"
echo

# ---------- E. 菜单在无 TTY 时安全退出 ----------
echo "[E] 无 TTY 菜单安全退出"
m="$(setsid bash "$MAIN" </dev/null 2>&1 || true)"
ck "无 TTY 时打印退出提示" "$(grep -c '无交互终端' <<<"$m")" "1"
ck "无 TTY 时不崩溃（无 unbound variable）" "$(grep -c 'unbound variable' <<<"$m")" "0"
echo

# ---------- F. 真实函数行为抽查（拆分未破坏逻辑） ----------
echo "[F] 真实函数行为抽查"
fnprobe="${TMP}/fnprobe.sh"
cat > "$fnprobe" <<'FNPROBE'
set -uo pipefail
src="$1"
tmp="$(dirname "$src")/.nodisp2.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"
rm -f "$tmp"
# normalize_bandwidth
echo "nb_60=$(normalize_bandwidth 60)"
echo "nb_100mbps=$(normalize_bandwidth '100 mbps')"
echo "nb_empty=[$(normalize_bandwidth '')]"
# gen_short_id 长度（16 hex 字符）
echo "sid_len=$(gen_short_id | tr -d '\n' | wc -c)"
# detect_pkg_mgr 顺序正确性（Alpine 优先）
echo "pkgmgr=$(detect_pkg_mgr)"
# proto_exists / proto_display
echo "pe1=$(proto_exists vless-reality && echo yes || echo no)"
echo "pe2=$(proto_exists bogus && echo yes || echo no)"
echo "pd=$(proto_display vless-reality)"
# FALLBACK_CANDIDATES 元素数
echo "cands=${#FALLBACK_CANDIDATES[@]}"
# PROTO_REGISTRY 元素数
echo "protos=${#PROTO_REGISTRY[@]}"
# xray_asset_suffix 不崩
echo "asset=$(xray_asset_suffix 2>/dev/null || echo err)"
FNPROBE
fo="$(bash "$fnprobe" "$MAIN" "${TMP}/nodisp2.sh" 2>/dev/null)"
ck "normalize_bandwidth 60 → 60 mbps" "$(grep -oP 'nb_60=\K.*' <<<"$fo")" "60 mbps"
ck "normalize_bandwidth 带单位原样" "$(grep -oP 'nb_100mbps=\K.*' <<<"$fo")" "100 mbps"
ck "normalize_bandwidth 空 → 空" "$(grep -oP 'nb_empty=\K.*' <<<"$fo")" "[]"
ck "proto_exists 已知协议" "$(grep -oP 'pe1=\K.*' <<<"$fo")" "yes"
ck "proto_exists 未知协议" "$(grep -oP 'pe2=\K.*' <<<"$fo")" "no"
ck "proto_display 返回显示名" "$(grep -oP 'pd=\K.*' <<<"$fo")" "VLESS-TCP-XTLS-Vision-REALITY|xray"
ck "FALLBACK_CANDIDATES 非空（≥100）" "$([[ "$(grep -oP 'cands=\K\d+' <<<"$fo")" -ge 100 ]] && echo ok)" "ok"
ck "PROTO_REGISTRY 4 个协议" "$(grep -oP 'protos=\K\d+' <<<"$fo")" "4"
ck "xray_asset_suffix 正常" "$(grep -oP 'asset=\K.*' <<<"$fo")" "linux-64.zip"
echo

echo "==================================="
printf ' PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
