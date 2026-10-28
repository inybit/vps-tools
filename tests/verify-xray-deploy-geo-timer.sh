#!/usr/bin/env bash
# geo 数据自动更新回归：timer unit 生成 / systemctl 调用序列 / status / remove /
# update_geo 的原子替换与失败回滚（mock curl + mock xray，不联网、不动本机 geo）
#
# 验证要点：
#   [A] unit 内容：OnCalendar=Mon 01:00 / RandomizedDelaySec=6h / Persistent / oneshot
#       / ExecStart 带 `update-geo --quiet --restart` / 不占用主服务 unit 名
#   [B] systemctl 调用序列：daemon-reload → enable --now <timer> → restart <timer>
#   [C] OnCalendar 可自定义；非法表达式拒绝且不写坏已有 unit
#   [D] 非 systemd（OpenRC）明确拒绝，不写任何 unit
#   [E] status：未安装 / 已安装 两种输出
#   [F] remove：stop + disable + 删文件 + daemon-reload
#   [G] update_geo：正常替换 / --restart 成功才重启 / -test 失败回滚且不重启
#       / 下载失败或内容过小 → 线上文件一个字节都不动 / 旧版静默语义兼容
#
# 用法: bash tests/verify-xray-deploy-geo-timer.sh
# 退出码: 0=全部通过
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL="${REPO}/proxy/xray-deploy"
MAIN="${TOOL}/xray-deploy.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
ck() {
  if [[ "$2" == "$3" ]]; then printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  else printf '  [FAIL] %s\n         期望: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1)); fi
}
cknz() {  # 断言「非空 / 含子串」
  if [[ -n "$2" && "$2" != *"$3"* ]]; then
    printf '  [FAIL] %s\n         期望包含: %s\n         实际: %s\n' "$1" "$3" "$2"; FAIL=$((FAIL+1))
  else
    printf '  [PASS] %s\n' "$1"; PASS=$((PASS+1))
  fi
}

echo "=== geo 定时更新回归 ==="
echo

# ---------- mock 环境 ----------
MOCKBIN="$TMP/bin"; mkdir -p "$MOCKBIN"
SYSLOG="$TMP/systemctl.log"
cat > "$MOCKBIN/systemctl" <<EOS
#!/usr/bin/env bash
echo "systemctl \$*" >> "${SYSLOG}"
case "\$1" in
  is-active) echo active ;;
  show) printf 'NextElapseUSecRealtime=Mon 2026-11-02 01:00:00 CST\nLastTriggerUSec=\nResult=success\n' ;;
esac
exit 0
EOS
# mock curl：只实现 update_geo 用到的形态（-fL --max-time N -o <file> <url>）
cat > "$MOCKBIN/curl" <<'EOS'
#!/usr/bin/env bash
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --max-time) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
base="${url##*/}"
[[ -n "${CURL_FAIL_ON:-}"  && "$base" == "$CURL_FAIL_ON"  ]] && exit 22
if [[ -n "${CURL_SMALL_ON:-}" && "$base" == "$CURL_SMALL_ON" ]]; then printf 'oops' > "$out"; exit 0; fi
{ printf '%s\n' "$base"; head -c 1200000 /dev/zero | tr '\0' 'x'; } > "$out"
EOS
cat > "$MOCKBIN/xray" <<'EOS'
#!/usr/bin/env bash
exit "${XRAY_TEST_RC:-0}"
EOS
chmod +x "$MOCKBIN/systemctl" "$MOCKBIN/curl" "$MOCKBIN/xray"

# ---------- 探针：source 主脚本（截断分发段），副作用全部换成可观测 mock ----------
GEN="$TMP/gen.sh"
cat > "$GEN" <<'GENPROBE'
set -uo pipefail
src="$1"; shift
tmp="$(dirname "$src")/.nodisp.$$.sh"
sed '/^# ============ 子命令分发/,$d' "$src" > "$tmp"
source "$tmp"; rm -f "$tmp"
need_root() { :; }
detect_init() { echo "${MOCK_INIT:-systemd}"; }
service_restart() { echo "restart" >> "${MOCKLOG:-/dev/null}"; }
[[ -n "${GEO_TEST_DIR:-}" ]] && { INSTALL_DIR="$GEO_TEST_DIR"; BIN_PATH="$GEO_TEST_DIR/xray"; }
[[ -n "${GEO_TEST_CFG:-}" ]] && CONFIG_FILE="$GEO_TEST_CFG"
"$@"
GENPROBE

UNITS="$TMP/units"
FAKECMD="$TMP/fake-xray-deploy"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKECMD"; chmod +x "$FAKECMD"
RESTARTLOG="$TMP/restart.log"; : > "$RESTARTLOG"

run() {  # $1...=要调用的函数及其参数
  env GEO_UNIT_DIR="${GEO_UNIT_DIR_OVERRIDE:-$UNITS}" GEO_CMD_PATH="$FAKECMD" \
      MOCKLOG="$RESTARTLOG" PATH="$MOCKBIN:$PATH" bash "$GEN" "$MAIN" "$@"
}
SERVICE_F="${UNITS}/xray-deploy-geo-update.service"
TIMER_F="${UNITS}/xray-deploy-geo-update.timer"

# ---------- A. unit 内容 ----------
echo "[A] timer/service unit 内容"
out="$(run geo_timer_install 2>&1)"; rc=$?
ck "install 返回 0" "$rc" "0"
ck "写了 .service"  "$([[ -f "$SERVICE_F" ]] && echo yes)" "yes"
ck "写了 .timer"    "$([[ -f "$TIMER_F" ]] && echo yes)" "yes"
ck "OnCalendar = 每周一 01:00" "$(grep -c '^OnCalendar=Mon \*-\*-\* 01:00:00$' "$TIMER_F")" "1"
ck "RandomizedDelaySec=6h"    "$(grep -c '^RandomizedDelaySec=6h$' "$TIMER_F")" "1"
ck "Persistent=true"          "$(grep -c '^Persistent=true$' "$TIMER_F")" "1"
ck "WantedBy=timers.target"   "$(grep -c '^WantedBy=timers.target$' "$TIMER_F")" "1"
ck "Unit= 指向 oneshot service" "$(grep -c '^Unit=xray-deploy-geo-update.service$' "$TIMER_F")" "1"
ck "service 是 oneshot"       "$(grep -c '^Type=oneshot$' "$SERVICE_F")" "1"
ck "ExecStart = update-geo --quiet --restart" \
  "$(grep -c "^ExecStart=${FAKECMD} update-geo --quiet --restart$" "$SERVICE_F")" "1"
ck "等 network-online.target" "$(grep -c '^Wants=network-online.target$' "$SERVICE_F")" "1"
ck "不占用主服务 unit 名（无 xray-deploy.service）" \
  "$([[ -f "${UNITS}/xray-deploy.service" ]] && echo exists || echo none)" "none"
cknz "install 回显含表达式" "$out" "Mon *-*-* 01:00:00"
echo

# ---------- B. systemctl 调用序列 ----------
echo "[B] systemctl 调用序列"
ck "daemon-reload"        "$(grep -c 'systemctl daemon-reload' "$SYSLOG")" "1"
ck "enable --now timer"   "$(grep -c 'systemctl enable --now xray-deploy-geo-update.timer' "$SYSLOG")" "1"
ck "restart timer（enable --now 不重载已运行 timer）" \
  "$(grep -c 'systemctl restart xray-deploy-geo-update.timer' "$SYSLOG")" "1"
ck "reload 在 enable 之前" \
  "$(awk '/daemon-reload/{d=NR} /enable --now/{e=NR} END{print (d<e)?"yes":"no"}' "$SYSLOG")" "yes"
echo

# ---------- C. 自定义 / 非法表达式 ----------
echo "[C] OnCalendar 自定义与校验"
run geo_timer_install "Sun *-*-* 04:30:00" >/dev/null 2>&1
ck "自定义表达式生效" "$(grep -c '^OnCalendar=Sun \*-\*-\* 04:30:00$' "$TIMER_F")" "1"
run geo_timer_install "Mon; rm -rf /" >/dev/null 2>&1; rc=$?
ck "含 shell 元字符 → 拒绝（非 0）" "$([[ $rc -ne 0 ]] && echo rejected)" "rejected"
ck "拒绝后不写坏已有 unit" "$(grep -c '^OnCalendar=Sun \*-\*-\* 04:30:00$' "$TIMER_F")" "1"
ck "非法表达式未落盘" "$(grep -c 'rm -rf' "$TIMER_F")" "0"
if command -v systemd-analyze >/dev/null 2>&1; then
  run geo_timer_install "Mon 99:99" >/dev/null 2>&1; rc=$?
  ck "systemd-analyze 判非法（Mon 99:99）→ 拒绝" "$([[ $rc -ne 0 ]] && echo rejected)" "rejected"
else
  echo "  [SKIP] 无 systemd-analyze，跳过语义校验断言"; SKIP=$((SKIP+1))
fi
echo

# ---------- D. 非 systemd ----------
echo "[D] 非 systemd（OpenRC）"
EMPTY="$TMP/units-openrc"
out="$(MOCK_INIT=openrc GEO_UNIT_DIR_OVERRIDE="$EMPTY" run geo_timer_install 2>&1)"; rc=$?
ck "OpenRC → 返回非 0" "$([[ $rc -ne 0 ]] && echo rejected)" "rejected"
ck "OpenRC → 不写 unit" "$(ls -A "$EMPTY" 2>/dev/null | wc -l)" "0"
cknz "提示只支持 systemd" "$out" "systemd"
echo

# ---------- E. status ----------
echo "[E] status"
out="$(GEO_UNIT_DIR_OVERRIDE="$TMP/units-none" run geo_timer_status 2>&1)"
cknz "未安装时提示安装" "$out" "未安装"
out="$(run geo_timer_status 2>&1)"
cknz "已安装显示 active" "$out" "active"
cknz "显示下次触发时间"  "$out" "NextElapseUSecRealtime"
echo

# ---------- F. remove ----------
echo "[F] remove"
: > "$SYSLOG"
run geo_timer_remove >/dev/null 2>&1
ck "stop timer"    "$(grep -c 'systemctl stop xray-deploy-geo-update.timer' "$SYSLOG")" "1"
ck "disable timer" "$(grep -c 'systemctl disable xray-deploy-geo-update.timer' "$SYSLOG")" "1"
ck "删 .service"   "$([[ -f "$SERVICE_F" ]] && echo exists || echo gone)" "gone"
ck "删 .timer"     "$([[ -f "$TIMER_F" ]] && echo exists || echo gone)" "gone"
ck "remove 后 daemon-reload" "$(grep -c 'systemctl daemon-reload' "$SYSLOG")" "1"
echo

# ---------- G. update_geo 原子替换 / 回滚 ----------
echo "[G] update_geo：原子替换与失败回滚"
GDIR="$TMP/geodir"; mkdir -p "$GDIR"
GCFG="$GDIR/config.json"; printf '{}\n' > "$GCFG"
OLD_GEOIP="OLD-geoip"; OLD_GEOSITE="OLD-geosite"
geo_reset() {
  printf '%s' "$OLD_GEOIP"   > "$GDIR/geoip.dat"
  printf '%s' "$OLD_GEOSITE" > "$GDIR/geosite.dat"
  printf '#!/usr/bin/env bash\nexit "${XRAY_TEST_RC:-0}"\n' > "$GDIR/xray"
  chmod +x "$GDIR/xray"
  : > "$RESTARTLOG"
}
ugeo() {  # $1...=update_geo 参数（额外 env 通过调用方前置赋值）
  env GEO_TEST_DIR="$GDIR" GEO_TEST_CFG="$GCFG" MOCKLOG="$RESTARTLOG" \
      PATH="$MOCKBIN:$PATH" bash "$GEN" "$MAIN" update_geo "$@"
}
size_of() { stat -c %s "$1" 2>/dev/null || echo 0; }
count_glob() {  # $1=目录 $2=后缀；输出匹配文件数（不用 ls|grep，避免文件名含特殊字符）
  local n=0 f
  for f in "$1"/*"$2"; do [[ -e "$f" ]] && n=$((n + 1)); done
  echo "$n"
}

geo_reset; out="$(ugeo --quiet 2>&1)"; rc=$?
ck "正常更新返回 0" "$rc" "0"
ck "geoip.dat 已替换（>1MB）"   "$([[ "$(size_of "$GDIR/geoip.dat")" -gt 1048576 ]] && echo big)" "big"
ck "geosite.dat 已替换（>1MB）" "$([[ "$(size_of "$GDIR/geosite.dat")" -gt 1048576 ]] && echo big)" "big"
ck "geoip.dat 内容来自新下载"   "$(grep -c '^geoip.dat$' "$GDIR/geoip.dat")" "1"
ck "无 --restart → 不重启服务"  "$(wc -l < "$RESTARTLOG")" "0"
ck "无 .new 残留"               "$(count_glob "$GDIR" .new)" "0"
ck "无 .bak 残留"               "$(count_glob "$GDIR" .bak)" "0"

geo_reset; out="$(XRAY_TEST_RC=0 ugeo --quiet --restart 2>&1)"; rc=$?
ck "--restart 校验通过 → 返回 0" "$rc" "0"
ck "--restart 校验通过 → 重启 1 次" "$(wc -l < "$RESTARTLOG")" "1"

geo_reset; out="$(XRAY_TEST_RC=1 ugeo --quiet --restart 2>&1)"; rc=$?
ck "-test 失败 → 返回非 0" "$([[ $rc -ne 0 ]] && echo failed)" "failed"
ck "-test 失败 → 不重启服务" "$(wc -l < "$RESTARTLOG")" "0"
ck "-test 失败 → geoip.dat 回滚"   "$(cat "$GDIR/geoip.dat")" "$OLD_GEOIP"
ck "-test 失败 → geosite.dat 回滚" "$(cat "$GDIR/geosite.dat")" "$OLD_GEOSITE"
cknz "-test 失败 → 明确报「已回滚」" "$out" "回滚"

geo_reset; out="$(CURL_FAIL_ON=geoip.dat ugeo --quiet 2>&1)"; rc=$?
ck "下载失败 → 返回非 0" "$([[ $rc -ne 0 ]] && echo failed)" "failed"
ck "下载失败 → geoip.dat 未动"   "$(cat "$GDIR/geoip.dat")" "$OLD_GEOIP"
ck "下载失败 → geosite.dat 未动" "$(cat "$GDIR/geosite.dat")" "$OLD_GEOSITE"
ck "下载失败 → 清掉已暂存的 .new" "$(count_glob "$GDIR" .new)" "0"

geo_reset; out="$(CURL_SMALL_ON=geosite.dat ugeo --quiet 2>&1)"; rc=$?
ck "内容 <1MB（错误页）→ 返回非 0" "$([[ $rc -ne 0 ]] && echo failed)" "failed"
ck "内容异常 → geosite.dat 未动" "$(cat "$GDIR/geosite.dat")" "$OLD_GEOSITE"
cknz "内容异常 → 提示疑似错误页" "$out" "错误页"

geo_reset; out="$(ugeo anything 2>&1)"
ck "旧语义兼容：任意参数 = 静默" "$(grep -c '更新 geosite.dat' <<<"$out")" "0"
echo

echo "----------------------------------------------"
echo " PASS=${PASS} FAIL=${FAIL} SKIP=${SKIP}"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
