#!/usr/bin/env bash
# ============================================================
# nginx-install 回归 harness（mock 环境，无需 root / 真机 / 网络）
#
# 用法: bash tests/verify-nginx-install.sh
# 期望: PASS=n FAIL=0
#
# 设计要点（照 bash-script-testing 技能）：
#   - 断言「喂坏输入 → 看可观测结果」，不 grep 源码字符串冒充行为断言
#   - mock 必须能把代码送到目标分支（curl stub 真的投递内容到 -o 目标；
#     apt-get stub 真的产出可用的 nginx 命令，否则「安装后复查」走不到）
#   - 案例脚本用 <<'EOF' 字面 heredoc 生成（防外层展开 —— 曾因 printf 转义
#     把 ${CH:-stable} 原样写入，导致「通道切换」断言测的是字符串而非行为）
#   - 变异测试见文件末尾：每条注入都应让 FAIL>0
# ============================================================
# SC2034：本 harness 的断言变量都通过 chk() 的 eval 字符串间接使用，shellcheck 看不到。
# 文件级指令必须在第一条命令之前才作用于全文件。
# shellcheck disable=SC2034
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOL_DIR="${REPO}/web/nginx-install"
TOOL="${TOOL_DIR}/nginx-install.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MOCK_BIN="${TMP}/bin"; MOCK_STATE="${TMP}/state"
mkdir -p "$MOCK_BIN" "${MOCK_STATE}/bin"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  [PASS] $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1  <<< $2"; }
chk(){ if eval "$2"; then ok "$1"; else bad "$1" "$2"; fi; }

# ---------- 真实官方密钥材料（好输入的来源） ----------
GOOD_KEY="${TMP}/nginx_signing.key"
GOOD_PUB="${TMP}/nginx_signing.rsa.pub"
curl -fsSL --noproxy '*' --max-time 30 "https://nginx.org/keys/nginx_signing.key" -o "$GOOD_KEY" 2>/dev/null || true
curl -fsSL --noproxy '*' --max-time 30 "https://nginx.org/keys/nginx_signing.rsa.pub" -o "$GOOD_PUB" 2>/dev/null || true
if [[ ! -s "$GOOD_KEY" || ! -s "$GOOD_PUB" ]]; then
  echo "!! 无法获取官方密钥材料（离线？）—— 校验类断言不可信，终止"
  exit 2
fi

# ---------- 「坏密钥」夹具：必须是**可解析但指纹不同**的真 PGP 密钥 ----------
# 若用随便一段文本冒充，代码会在「无法解析」分支就拒绝 → 指纹比较分支从未执行，
# 断言「因指纹不匹配而拒绝」就变成假测试（2026-09-18 踩过）。
BAD_KEY="${TMP}/bad_signing.key"
BAD_GNUPGHOME="${TMP}/gnupg-bad"; mkdir -p "$BAD_GNUPGHOME"; chmod 700 "$BAD_GNUPGHOME"
if ! GNUPGHOME="$BAD_GNUPGHOME" gpg --batch --quiet --pinentry-mode loopback \
      --passphrase '' --quick-gen-key "not-nginx <fake@example.invalid>" rsa2048 sign 0 >/dev/null 2>&1; then
  echo "!! 无法生成坏密钥夹具（gpg 不可用？）—— fail-closed 断言不可信，终止"
  exit 2
fi
GNUPGHOME="$BAD_GNUPGHOME" gpg --batch --quiet --export > "$BAD_KEY" 2>/dev/null || true
if [[ ! -s "$BAD_KEY" ]]; then
  echo "!! 坏密钥夹具导出失败，终止"; exit 2
fi
# 自证：坏密钥可解析、且不含官方指纹
if ! gpg --with-colons --import-options show-only --import "$BAD_KEY" 2>/dev/null | grep -q '^fpr:'; then
  echo "!! 坏密钥夹具不可解析，终止"; exit 2
fi
if gpg --with-colons --import-options show-only --import "$BAD_KEY" 2>/dev/null | grep -q '573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62'; then
  echo "!! 坏密钥夹具竟含官方指纹，终止"; exit 2
fi

# ---------- 环境隔离（所有路径指到 TMP） ----------
export NI_ENV_FILE="${TMP}/none.env"
export NI_OS_RELEASE="${TMP}/os-release"
export NI_ALPINE_RELEASE="${TMP}/alpine-release"
export NI_KEYRING="${TMP}/etc/keyrings/nginx.gpg"
export NI_APT_LIST="${TMP}/etc/apt/sources.list.d/nginx.list"
export NI_APT_PREF="${TMP}/etc/apt/preferences.d/99nginx"
export NI_YUM_REPO="${TMP}/etc/yum.repos.d/nginx.repo"
export NI_RPM_KEYFILE="${TMP}/etc/pki/rpm-gpg/nginx_signing.key"
export NI_APK_REPOS="${TMP}/etc/apk/repositories"
export NI_APK_KEYS="${TMP}/etc/apk/keys"
export NI_EUID=0
export MOCK_STATE GOOD_KEY_SRC="$GOOD_KEY" GOOD_PUB_SRC="$GOOD_PUB" BAD_KEY_SRC="$BAD_KEY"

printf 'ID=debian\nVERSION_CODENAME=bookworm\n' > "$NI_OS_RELEASE"
printf '3.21.0\n' > "$NI_ALPINE_RELEASE"
: > "$NI_APK_REPOS"

# ============================================================
# mock: curl —— 必须真的投递到 -o 目标，否则代码走不到校验分支
#   CURL_MODE=good|bad|empty ；调用记录写 $CURL_LOG
# ============================================================
cat > "${MOCK_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "${CURL_LOG:-/dev/null}"
mode="${CURL_MODE:-good}"
out=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -fsSL|-sSL|-sS|-fsS|-f|-s) shift ;;
    --max-time|--noproxy) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "$out" ]] || exit 0
case "$mode" in
  empty) : > "$out" ;;
  bad)
    # 伪造输入：用「可解析但指纹不同」的真 PGP 密钥 / 真 RSA 公钥
    # （若投递垃圾文本，代码会在解析分支就拒绝，指纹比较分支根本走不到 → 假测试）
    if [[ "$url" == *rsa.pub ]]; then
      openssl genrsa 2048 2>/dev/null | openssl rsa -pubout 2>/dev/null > "$out"
    else
      cp "$BAD_KEY_SRC" "$out"
    fi ;;
  *)
    if [[ "$url" == *rsa.pub ]]; then cp "$GOOD_PUB_SRC" "$out"
    else cp "$GOOD_KEY_SRC" "$out"; fi ;;
esac
exit 0
STUB
chmod +x "${MOCK_BIN}/curl"

# ---------- mock: 包管理器（apt-get 真的产出可用 nginx 命令） ----------
# ⚠️ 关键：detect_pkg_mgr 是 Alpine 优先（apk → apt-get → dnf → yum）。
# 因此各发行版分支必须用**独立 PATH 目录**：测 apt 路径时目录里不能有 apk/dnf/yum stub，
# 否则 apk stub 先命中 → 走错分支（曾因此让 [6] 整段测了 apk 路径）。
mkdir -p "${TMP}/pm-apt" "${TMP}/pm-apk" "${TMP}/pm-dnf"
cat > "${TMP}/pm-apt/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "${MOCK_STATE}/pkg.log"
case "$*" in
  *install*nginx*)
    [[ "${PKG_FAIL:-0}" == "1" ]] && exit 100
    mkdir -p "${MOCK_STATE}/bin"
    cat > "${MOCK_STATE}/bin/nginx" <<'N'
#!/usr/bin/env bash
case "${1:-}" in
  -v) echo "nginx version: nginx/1.31.6" >&2 ;;
  -t) echo "nginx: configuration file test is successful" >&2 ;;
esac
exit 0
N
    chmod +x "${MOCK_STATE}/bin/nginx" ;;
esac
exit 0
STUB
cat > "${TMP}/pm-apt/dpkg" <<'STUB'
#!/usr/bin/env bash
echo "dpkg $*" >> "${MOCK_STATE}/pkg.log"
[[ "${1:-}" == "--print-architecture" ]] && echo "amd64"
exit 0
STUB
cat > "${TMP}/pm-apk/apk" <<'STUB'
#!/usr/bin/env bash
echo "apk $*" >> "${MOCK_STATE}/pkg.log"
case "$*" in
  *nginx*)
    [[ "${PKG_FAIL:-0}" == "1" ]] && exit 100
    mkdir -p "${MOCK_STATE}/bin"
    printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  -v) echo "nginx version: nginx/1.31.6" >&2 ;;\n  -t) echo "ok" >&2 ;;\nesac\nexit 0\n' > "${MOCK_STATE}/bin/nginx"
    chmod +x "${MOCK_STATE}/bin/nginx" ;;
esac
exit 0
STUB
cat > "${TMP}/pm-dnf/dnf" <<'STUB'
#!/usr/bin/env bash
echo "dnf $*" >> "${MOCK_STATE}/pkg.log"
case "$*" in
  *install*nginx*)
    [[ "${PKG_FAIL:-0}" == "1" ]] && exit 100
    mkdir -p "${MOCK_STATE}/bin"
    printf '#!/usr/bin/env bash\ncase "${1:-}" in\n  -v) echo "nginx version: nginx/1.31.6" >&2 ;;\n  -t) echo "ok" >&2 ;;\nesac\nexit 0\n' > "${MOCK_STATE}/bin/nginx"
    chmod +x "${MOCK_STATE}/bin/nginx" ;;
esac
exit 0
STUB
chmod +x "${TMP}/pm-apt"/* "${TMP}/pm-apk"/* "${TMP}/pm-dnf"/*
# 共享 mock 目录：只有「不参与包管理器探测」的命令（含 gpg 转发器，密钥校验需真解析）
cat > "${MOCK_BIN}/gpg" <<'STUB'
#!/usr/bin/env bash
exec /usr/bin/gpg "$@"
STUB
chmod +x "${MOCK_BIN}/gpg"
for c in systemctl rc-service; do
  cat > "${MOCK_BIN}/${c}" <<STUB
#!/usr/bin/env bash
echo "${c} \$*" >> "\${MOCK_STATE}/svc.log"
case "\$*" in
  *is-active*)  echo "\${SVC_ACTIVE:-active}"; exit 0 ;;
  *is-enabled*) echo "enabled"; exit 0 ;;
esac
exit 0
STUB
  chmod +x "${MOCK_BIN}/${c}"
done
cat > "${MOCK_BIN}/ss" <<'STUB'
#!/usr/bin/env bash
printf 'LISTEN 0 511 0.0.0.0:443 0.0.0.0:*\nLISTEN 0 511 127.0.0.1:8080 0.0.0.0:*\n'
exit 0
STUB
chmod +x "${MOCK_BIN}/ss"

# 两条 PATH：PM_PATH=<指定包管理器目录>:<共享目录>:<系统>（保留系统路径给 shebang）
BASE_PATH="${MOCK_BIN}:${MOCK_STATE}/bin:${PATH}"
APT_PATH="${TMP}/pm-apt:${BASE_PATH}"
APK_PATH="${TMP}/pm-apk:${BASE_PATH}"

# dnf 分支需要「宿主上没有 apk/apt-get」才能命中 —— 本机真实 /usr/bin/apt-get 会让
# 探测永远返回 apt-get。做法：建一个只含白名单系统命令的受限 PATH 目录（无 apt-get/apk），
# 再把 pm-dnf 与共享 mock 前置（同 docker-install harness 的「无 ufw/docker 分支」手法）。
RESTRICT="${TMP}/restrict"; mkdir -p "$RESTRICT"
for b in bash env sed grep awk cat mkdir rmdir rm cp mv chmod chown touch mktemp \
         sha256sum openssl gpg gpg2 install dirname basename tr sort head tail cut \
         uname id date printf ls find xargs tee sleep systemctl ss sh dpkg-deb; do
  for d in /usr/bin /bin /usr/sbin /sbin; do
    [[ -x "$d/$b" ]] && { ln -sf "$d/$b" "$RESTRICT/$b"; break; }
  done
done
DNF_PATH="${TMP}/pm-dnf:${MOCK_BIN}:${MOCK_STATE}/bin:${RESTRICT}"

# 默认 PATH 用 BASE_PATH（含 curl/gpg/systemctl/ss 等共享 stub，但**不含**任何包管理器 stub，
# 故不会干扰宿主真实包管理器）。[6] 各分支再按需前置 pm-* 目录。
export PATH="$BASE_PATH"

# 生成案例脚本（字面 heredoc，防外层展开）
case_file() {  # $1=文件名 → 输出路径
  cat > "${TMP}/$1"
  echo "${TMP}/$1"
}

echo "=== nginx-install 回归（mock 环境） ==="
echo ""

# ------------------------------------------------------------
echo "[1] apt 密钥校验 fail-closed（喂坏密钥 → 拒绝且不落盘）"
# ------------------------------------------------------------
CASE_BAD="$(case_file case-badkey.sh <<EOF
source '${TOOL_DIR}/lib/common.sh'
source '${TOOL_DIR}/lib/keys.sh'
NI_KEYRING='${TMP}/out/bad.gpg'
ni_get_apt_key "\$NI_KEYRING" dearmor && echo 'RESULT=ACCEPTED' || echo 'RESULT=REJECTED'
[[ -e "\$NI_KEYRING" ]] && echo 'FILE=WRITTEN' || echo 'FILE=NONE'
EOF
)"
BADKEY_OUT="$(CURL_MODE=bad CURL_LOG="${MOCK_STATE}/curl-bad.log" bash "$CASE_BAD" 2>&1)"
chk "坏密钥被拒绝"       "echo \"\$BADKEY_OUT\" | grep -q 'RESULT=REJECTED'"
chk "坏密钥不落盘"       "echo \"\$BADKEY_OUT\" | grep -q 'FILE=NONE'"
# 断言「指纹校验」而非「其他原因拒绝」：必须出现指纹不匹配专属文案
# （只 grep 指纹会假通过 —— 成功文案里也有指纹）
chk "因指纹不匹配而拒绝" "echo \"\$BADKEY_OUT\" | grep -q '指纹不匹配'"
chk "确实发生了下载"     "[[ -s ${MOCK_STATE}/curl-bad.log ]]"
# 反面对照：好密钥必须被接受并落盘（证明上面的拒绝不是因为流程根本走不通）
CASE_GOOD="$(case_file case-goodkey.sh <<EOF
source '${TOOL_DIR}/lib/common.sh'
source '${TOOL_DIR}/lib/keys.sh'
NI_KEYRING='${TMP}/out/good.gpg'
ni_get_apt_key "\$NI_KEYRING" dearmor && echo 'RESULT=ACCEPTED' || echo 'RESULT=REJECTED'
[[ -s "\$NI_KEYRING" ]] && echo 'FILE=WRITTEN' || echo 'FILE=NONE'
EOF
)"
GOODKEY_OUT="$(CURL_MODE=good bash "$CASE_GOOD" 2>&1)"
chk "好密钥被接受（对照）" "echo \"\$GOODKEY_OUT\" | grep -q 'RESULT=ACCEPTED'"
chk "好密钥落盘（对照）"   "echo \"\$GOODKEY_OUT\" | grep -q 'FILE=WRITTEN'"
# 空下载也必须拒绝（防「下载失败但继续」）
EMPTY_OUT="$(CURL_MODE=empty bash "$CASE_GOOD" 2>&1)"
chk "空下载被拒绝"         "echo \"\$EMPTY_OUT\" | grep -q 'RESULT=REJECTED'"
echo ""

# ------------------------------------------------------------
echo "[2] apk 公钥摘要校验（DER sha256）"
# ------------------------------------------------------------
CASE_APK="$(case_file case-apk.sh <<EOF
source '${TOOL_DIR}/lib/common.sh'
source '${TOOL_DIR}/lib/keys.sh'
ni_get_apk_key '${TMP}/out/apk.pub' && echo 'RESULT=ACCEPTED' || echo 'RESULT=REJECTED'
EOF
)"
APK_BAD="$(CURL_MODE=bad bash "$CASE_APK" 2>&1)"
APK_GOOD="$(CURL_MODE=good bash "$CASE_APK" 2>&1)"
chk "伪造 apk 公钥被拒绝" "echo \"\$APK_BAD\" | grep -q 'RESULT=REJECTED'"
chk "因摘要不匹配而拒绝"   "echo \"\$APK_BAD\" | grep -q '摘要不匹配'"
chk "真实 apk 公钥被接受" "echo \"\$APK_GOOD\" | grep -q 'RESULT=ACCEPTED'"
echo ""

# ------------------------------------------------------------
echo "[3] apt 仓库（官方源 + pin 900 + 通道切换 + 幂等）"
# ------------------------------------------------------------
CASE_REPO="$(case_file case-repo.sh <<EOF
source '${TOOL_DIR}/lib/common.sh'
source '${TOOL_DIR}/lib/keys.sh'
source '${TOOL_DIR}/lib/repo.sh'
NI_CHANNEL="\${CH:-stable}"
ni_setup_repo_apt debian
EOF
)"
rm -f "$NI_APT_LIST" "$NI_APT_PREF"
CH=stable bash "$CASE_REPO" >/dev/null 2>&1
chk "apt list 指向官方源"  "grep -q 'nginx.org/packages/debian' '$NI_APT_LIST'"
chk "apt list 用签名密钥"  "grep -q 'signed-by=${NI_KEYRING}' '$NI_APT_LIST'"
chk "apt list 用正确代号"  "grep -q 'bookworm nginx' '$NI_APT_LIST'"
chk "pin 优先级 900"       "grep -q 'Pin-Priority: 900' '$NI_APT_PREF'"
chk "pin 限定 nginx.org"   "grep -q 'Pin: origin nginx.org' '$NI_APT_PREF'"
BEFORE="$(md5sum "$NI_APT_LIST" | awk '{print $1}')"
IDEM_OUT="$(CH=stable bash "$CASE_REPO" 2>&1)"
AFTER="$(md5sum "$NI_APT_LIST" | awk '{print $1}')"
chk "幂等：重复执行内容不变" "[[ '$BEFORE' == '$AFTER' ]]"
# 仅比内容哈希抓不到「无脑重写同样内容」（md5 相同 → 恒绿）。必须断言**未重写**：
# ni_write_if_changed 命中相同内容时会打印「已是最新，跳过」。
chk "幂等：未发生重写"       "echo \"\$IDEM_OUT\" | grep -q '已是最新，跳过'"
chk "幂等：无重复行"        "[[ \$(grep -c 'nginx.org/packages' '$NI_APT_LIST') -eq 1 ]]"
CH=mainline bash "$CASE_REPO" >/dev/null 2>&1
chk "mainline 通道切换"      "grep -q 'packages/mainline/debian' '$NI_APT_LIST'"
chk "切通道后仍无重复行"     "[[ \$(grep -c 'nginx.org/packages' '$NI_APT_LIST') -eq 1 ]]"
echo ""

# ------------------------------------------------------------
echo "[4] dnf 仓库（通道用 enabled 表达）"
# ------------------------------------------------------------
CASE_DNF="$(case_file case-dnf.sh <<EOF
source '${TOOL_DIR}/lib/common.sh'
source '${TOOL_DIR}/lib/keys.sh'
source '${TOOL_DIR}/lib/repo.sh'
NI_CHANNEL="\${CH:-stable}"
ni_setup_repo_dnf 'https://nginx.org/packages/centos/\$releasever/\$basearch/' 'https://nginx.org/packages/mainline/centos/\$releasever/\$basearch/'
EOF
)"
CH=stable bash "$CASE_DNF" >/dev/null 2>&1
chk "dnf 仓库两段齐全"    "[[ \$(grep -c '^\[nginx-' '$NI_YUM_REPO') -eq 2 ]]"
chk "stable 通道 enabled" "awk '/^\[nginx-stable\]/{s=1;next} /^\[/{s=0} s&&/^enabled=1/{f=1} END{exit !f}' '$NI_YUM_REPO'"
chk "releasever 是字面量" "grep -q 'releasever' '$NI_YUM_REPO'"
chk "rpm 密钥文件落盘"    "[[ -s '$NI_RPM_KEYFILE' ]]"
chk "rpm 仓库引用密钥路径" "grep -q 'gpgkey=file://${NI_RPM_KEYFILE}' '$NI_YUM_REPO'"
CH=mainline bash "$CASE_DNF" >/dev/null 2>&1
chk "mainline 通道 enabled" "awk '/^\[nginx-mainline\]/{s=1;next} /^\[/{s=0} s&&/^enabled=1/{f=1} END{exit !f}' '$NI_YUM_REPO'"
chk "切通道后仍只有 2 段"   "[[ \$(grep -c '^\[nginx-' '$NI_YUM_REPO') -eq 2 ]]"
echo ""

# ------------------------------------------------------------
echo "[5] apk 仓库（幂等：不累积重复 @nginx 行）"
# ------------------------------------------------------------
CASE_APKREPO="$(case_file case-apkrepo.sh <<EOF
source '${TOOL_DIR}/lib/common.sh'
source '${TOOL_DIR}/lib/keys.sh'
source '${TOOL_DIR}/lib/repo.sh'
NI_CHANNEL="\${CH:-stable}"
ni_setup_repo_apk
EOF
)"
CH=stable bash "$CASE_APKREPO" >/dev/null 2>&1
CH=stable bash "$CASE_APKREPO" >/dev/null 2>&1
chk "apk 重复执行行唯一"  "[[ \$(grep -c '^@nginx ' '$NI_APK_REPOS') -eq 1 ]]"
CH=mainline bash "$CASE_APKREPO" >/dev/null 2>&1
chk "apk 切通道仍唯一"    "[[ \$(grep -c '^@nginx ' '$NI_APK_REPOS') -eq 1 ]]"
chk "apk 指向 mainline"   "grep -q 'mainline/alpine/v3.21/main' '$NI_APK_REPOS'"
chk "apk 公钥已安装"      "[[ -s '${NI_APK_KEYS}/nginx_signing.rsa.pub' ]]"
echo ""
rm -f "${MOCK_STATE}/pkg.log" "${MOCK_STATE}/svc.log"
PATH="$APT_PATH" NI_YES=1 bash "$TOOL" install stable >"${TMP}/e2e.log" 2>&1; E2E_RC=$?
chk "install 退出码 0"      "[[ $E2E_RC -eq 0 ]]"
chk "确实调用 apt-get 装包" "grep -q 'install.*nginx' '${MOCK_STATE}/pkg.log'"
chk "安装后复查通过"        "grep -q '安装完成' '${TMP}/e2e.log'"
chk "启用服务"              "grep -q 'enable' '${MOCK_STATE}/svc.log'"
chk "apt list 落到官方源"   "grep -q 'nginx.org/packages/debian' '$NI_APT_LIST'"
chk "apt 未误走 apk 分支"   "! grep -q '^apk ' '${MOCK_STATE}/pkg.log'"
# 安装失败必须报错（不能假成功）
PATH="$APT_PATH" PKG_FAIL=1 NI_YES=1 bash "$TOOL" install stable >"${TMP}/fail.log" 2>&1; FAIL_RC=$?
chk "装包失败 → 非零退出"   "[[ $FAIL_RC -ne 0 ]]"
chk "装包失败 → 不报成功"   "! grep -q '安装完成' '${TMP}/fail.log'"
# 非法通道必须拒绝
PATH="$APT_PATH" bash "$TOOL" install bogus >/dev/null 2>&1; BOGUS_RC=$?
chk "非法通道被拒绝"        "[[ $BOGUS_RC -ne 0 ]]"
# Alpine 路径（独立 PATH：只有 apk stub）
rm -f "${MOCK_STATE}/pkg.log"
PATH="$APK_PATH" NI_YES=1 bash "$TOOL" install stable >"${TMP}/apk.log" 2>&1; APK_RC=$?
chk "alpine 路径退出码 0"   "[[ $APK_RC -eq 0 ]]"
chk "alpine 走 apk 装包"    "grep -q '^apk .*nginx@nginx' '${MOCK_STATE}/pkg.log'"
chk "alpine 未走 apt"       "! grep -q '^apt-get ' '${MOCK_STATE}/pkg.log'"
# RHEL 路径
rm -f "${MOCK_STATE}/pkg.log"
PATH="$DNF_PATH" NI_YES=1 bash "$TOOL" install stable >"${TMP}/dnf.log" 2>&1; DNF_RC=$?
chk "rhel 路径退出码 0"     "[[ $DNF_RC -eq 0 ]]"
chk "rhel 走 dnf 装包"      "grep -q '^dnf .*install' '${MOCK_STATE}/pkg.log'"
echo ""

# ------------------------------------------------------------
echo "[7] 状态体检（只读）"
# ------------------------------------------------------------
ST_OUT="$(PATH="$APT_PATH" bash "$TOOL" status 2>&1)"
chk "status 报官方源状态"  "echo \"\$ST_OUT\" | grep -qE '官方源已配置|官方源未配置'"
chk "status 报 nginx 版本" "echo \"\$ST_OUT\" | grep -q '1.31.6'"
chk "status 读监听端口"    "echo \"\$ST_OUT\" | grep -q '443'"
chk "status 跑配置语法"    "echo \"\$ST_OUT\" | grep -q '配置语法检查通过'"
chk "status 退出码 0"      "PATH='$APT_PATH' bash '$TOOL' status >/dev/null 2>&1"
V_OUT="$(PATH="$APT_PATH" bash "$TOOL" -v 2>&1)"
SRC_VER="$(sed -n 's/^NI_VERSION="\(.*\)"/\1/p' "$TOOL")"
chk "-v 与源码版本一致"    "[[ \"\$V_OUT\" == \"nginx-install \$SRC_VER\" ]]"
# wrapper 场景：$0 是脚本库里的 *.sh，但输出必须是面向用户的命令名
WRAP_OUT="$(NI_SELF=nginx-install PATH="$APT_PATH" bash "$TOOL" -v 2>&1)"
chk "命令名可覆盖（wrapper）" "[[ \"\$WRAP_OUT\" == \"nginx-install \$SRC_VER\" ]]"
H_OUT="$(PATH="$APT_PATH" bash "$TOOL" -h 2>&1)"
chk "帮助列出 install"     "echo \"\$H_OUT\" | grep -q 'install'"
chk "帮助列出 status"      "echo \"\$H_OUT\" | grep -q 'status'"
# 未配置官方源时 status 必须如实报「未配置」（不能假报已配置）
SAVED_LIST="$NI_APT_LIST"; mv "$NI_APT_LIST" "${TMP}/list.bak"
ST2="$(PATH="$APT_PATH" bash "$TOOL" status 2>&1)"
chk "未配置源时如实报告"   "echo \"\$ST2\" | grep -q '官方源未配置'"
mv "${TMP}/list.bak" "$SAVED_LIST"
echo ""

# ------------------------------------------------------------
echo "[8] 架构规约与注册表契约"
# ------------------------------------------------------------
OVER="$(python3 - "$TOOL_DIR" <<'PY'
import glob, sys, os
d = sys.argv[1]
bad = [f"{os.path.basename(f)}:{sum(1 for _ in open(f, encoding='utf-8', errors='replace'))}"
       for f in glob.glob(os.path.join(d, '**', '*.sh'), recursive=True)
       if sum(1 for _ in open(f, encoding='utf-8', errors='replace')) > 200]
print(" ".join(bad))
PY
)"
chk "无文件超过 200 行"    "[[ -z \"\$OVER\" ]]"
chk "注册表含 nginx-install" "grep -q 'nginx-install|web/nginx-install' '${REPO}/install.sh'"
MISSING=""
for f in "$TOOL_DIR"/lib/*.sh; do
  rel="web/nginx-install/lib/$(basename "$f")"
  grep -q "$rel" "${REPO}/install.sh" || MISSING+=" $rel"
done
chk "extra_files 列全 lib/" "[[ -z \"\$MISSING\" ]]"
chk "env 模板已注册"        "grep -q 'nginx-install.env.example' '${REPO}/install.sh'"
DEAD="$(python3 - "$TOOL_DIR" <<'PY'
import re, glob, sys, os
d = sys.argv[1]
files = [os.path.join(d, 'nginx-install.sh')] + sorted(glob.glob(os.path.join(d, 'lib', '*.sh')))
src = "\n".join(open(f, encoding='utf-8').read() for f in files)
dead = [fn for fn in set(re.findall(r'^([a-z_][a-z0-9_]*)\(\)', src, re.M))
        if len(re.findall(r'\b' + re.escape(fn) + r'\b', src)) < 2]
print(" ".join(sorted(dead)))
PY
)"
chk "无死代码"              "[[ -z \"\$DEAD\" ]]"
DANGLING="$(python3 - "$TOOL_DIR" <<'PY'
import re, glob, sys, os
d = sys.argv[1]
files = [os.path.join(d, 'nginx-install.sh')] + sorted(glob.glob(os.path.join(d, 'lib', '*.sh')))
src = "\n".join(open(f, encoding='utf-8').read() for f in files)
defined = set(re.findall(r'^([a-z_][a-z0-9_]*)\(\)', src, re.M))
called = set(re.findall(r'^\s*(ni_[a-z_][a-z0-9_]*)', src, re.M))
print(" ".join(sorted(called - defined)))
PY
)"
chk "无悬空调用"            "[[ -z \"\$DANGLING\" ]]"
# 包管理器探测优先级（Alpine 优先）：PATH 里同时有 apk 与真实 apt-get 时必须选 apk。
# 这是真实回归项 —— `command -v X && mgr=X` 顺序赋值是「最后命中赢」，与意图相反。
PRIO="$(PATH="${TMP}/pm-apk:${TMP}/pm-apt:${BASE_PATH}" bash -c "
source '${TOOL_DIR}/lib/common.sh'
detect_pkg_mgr
" 2>/dev/null)"
chk "Alpine 优先（apk 胜过 apt）" "[[ \"\$PRIO\" == 'apk' ]]"
PRIO2="$(PATH="${TMP}/pm-apt:${BASE_PATH}" bash -c "
source '${TOOL_DIR}/lib/common.sh'
detect_pkg_mgr
" 2>/dev/null)"
chk "无 apk 时选 apt-get"         "[[ \"\$PRIO2\" == 'apt-get' ]]"
# 同类缺陷不得在其他工具里复发（docker-install / vps-init）
BADMGR="$(grep -lE 'command -v (apk|apt-get|dnf|yum) +>/dev/null 2>&1 && mgr=' \
          "${REPO}"/utils/*/lib/common.sh "${REPO}"/web/*/lib/common.sh 2>/dev/null | tr '\n' ' ')"
chk "全仓库无「最后命中赢」写法"  "[[ -z \"\$BADMGR\" ]]"
# 交互终端判据：`[[ -r /dev/tty ]]` 是**权限位判定**，无控制终端时同样为真 →
# 直接 read 报 "/dev/tty: No such device or address"（2026-09-18 真机实测）。
# 全仓库必须统一用 has_ctty()（真打开一次）。只扫非注释行（说明文字里会引用旧写法）。
TTYGUARD="$(grep -rlE '^[[:space:]]*[^#[:space:]].*\[\[ *-r +/dev/tty *\]\]' \
            "${REPO}"/utils/*/lib/common.sh "${REPO}"/web/*/lib/common.sh \
            "${REPO}"/bench/*/*.sh "${REPO}"/monitor/*/*.sh \
            "${REPO}"/proxy/*/*.sh "${REPO}"/install.sh 2>/dev/null | tr '\n' ' ')"
chk "全仓库无「-r /dev/tty」伪判据" "[[ -z \"\$TTYGUARD\" ]]"
# 行为断言：无控制终端（setsid 脱离 ctty）时 has_ctty 必须为假、read_input 不得有 stderr 噪音。
# ⚠️ 必须用脚本文件而非嵌套 bash -c：嵌套引号下 source 路径会被吃掉，
#    函数找不到 → has_ctty 失败同样输出 0，断言假 PASS（本次自伤一次）。
cat > "${TMP}/ttyprobe.sh" <<'PROBE'
source "$1/lib/common.sh" 2>/dev/null
declare -F read_input >/dev/null 2>&1 && printf 'src=ok ' || printf 'src=BROKEN '
printf 'has_ctty=%s ' "$(has_ctty && echo 1 || echo 0)"
err="$( { read_input "p> " _a; } 2>&1 >/dev/null )"
printf 'stderr=[%s]' "$err"
PROBE
TTYPROBE="$(NI_ENV_FILE="${TMP}/none.env" setsid bash "${TMP}/ttyprobe.sh" "$TOOL_DIR" </dev/null 2>/dev/null)"
chk "探测脚本真的 source 到了库" "echo \"\$TTYPROBE\" | grep -q 'src=ok'"
chk "无终端时 has_ctty=0"        "echo \"\$TTYPROBE\" | grep -q 'has_ctty=0'"
chk "无终端时 read_input 无噪音"  "echo \"\$TTYPROBE\" | grep -q 'stderr=\[\]'"
# install_self 必须能刷新「已存在但版本旧」的管理命令副本 —— 否则交互判据修复
# 永远到不了用户机器（2026-09-18 真机实测：/usr/local/bin/vps-tools 停在 1.3.0，
# 无 TTY 下报 line 238: /dev/tty: No such device or address）。
SELF_T="${TMP}/selfupd"; mkdir -p "$SELF_T/bin" "$SELF_T/fake"
python3 - "${REPO}/install.sh" > "$SELF_T/fns.sh" <<'PY'
import re, sys
src = open(sys.argv[1], encoding='utf-8').read()
out = []
for fn in ('installed_self_version', 'install_self'):
    m = re.search(r'^' + fn + r'\(\) \{.*?^\}', src, re.M | re.S)
    # EUID 是 bash 只读变量，替换成可 mock 的名字才能测非 root 分支
    out.append(m.group(0).replace('$EUID', '$FAKE_EUID'))
print("\n".join(out))
PY
cat > "$SELF_T/fake/curl" <<'STUB'
#!/usr/bin/env bash
out=""; while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
[[ -n "$out" ]] || exit 0
printf 'VPS_TOOLS_VERSION="9.9.9"\n# fake\n' > "$out"
STUB
chmod +x "$SELF_T/fake/curl"
cat > "$SELF_T/run.sh" <<'RUN'
set -u
SELF_T="$3"
source "$SELF_T/fns.sh"
log_info(){ :; }
log_warn(){ :; }
FAKE_EUID="$2"
VPS_TOOLS_VERSION="9.9.9"
BASE_URL="http://fake"
VPS_TOOLS_CMD="$1"
PATH="$SELF_T/fake:$PATH"
install_self
RUN
printf 'VPS_TOOLS_VERSION="1.3.0"\nold\n' > "$SELF_T/bin/vps-tools"
# ⚠️ 夹具必须显式 chmod +x：printf 覆写会保留上一次 chmod 的模式，
#    若夹具不可执行，「只看文件是否存在」的旧逻辑同样会去下载 → 变异测试假 PASS（本次踩过）。
chmod +x "$SELF_T/bin/vps-tools"
bash "$SELF_T/run.sh" "$SELF_T/bin/vps-tools" 0 "$SELF_T" 2>/dev/null || true
chk "install_self 能刷新旧版本副本" \
  "grep -q 'VPS_TOOLS_VERSION=\"9.9.9\"' '$SELF_T/bin/vps-tools'"
printf 'VPS_TOOLS_VERSION="9.9.9"\nkeep-me\n' > "$SELF_T/bin/vps-tools"
chmod +x "$SELF_T/bin/vps-tools"
bash "$SELF_T/run.sh" "$SELF_T/bin/vps-tools" 0 "$SELF_T" 2>/dev/null || true
chk "install_self 同版本不重写"      "grep -q 'keep-me' '$SELF_T/bin/vps-tools'"
printf 'VPS_TOOLS_VERSION="1.3.0"\nold\n' > "$SELF_T/bin/vps-tools"
chmod +x "$SELF_T/bin/vps-tools"
bash "$SELF_T/run.sh" "$SELF_T/bin/vps-tools" 1 "$SELF_T" 2>/dev/null || true
chk "install_self 非 root 不下载"    "grep -q 'VPS_TOOLS_VERSION=\"1.3.0\"' '$SELF_T/bin/vps-tools'"
chk "帮助里的 self-update 已实现"    "grep -q '^    self-update)' '${REPO}/install.sh'"
echo ""

echo "============================================================"
echo "PASS=$PASS FAIL=$FAIL"
echo "============================================================"

# ============================================================
# 变异测试（证明 harness 有效 —— 手动跑，每条应 FAIL>0）
# 改完先 grep 确认注入生效，跑完 git checkout 还原。
#
# 1) 密钥校验恒通过（fail-open）
#    sed -i 's|if ! grep -qx "$NI_FINGERPRINT"|if false \&\& ! grep -qx "$NI_FINGERPRINT"|' lib/keys.sh
# 2) 校验失败仍继续（去掉 fail-closed）
#    sed -i 's|if ! ni_verify_apt_key "$tmp"; then rm -f "$tmp"; return 1; fi|: \&\& ni_verify_apt_key "$tmp"|' lib/keys.sh
# 3) apt 不写 pin
#    sed -i 's|ni_write_if_changed "$NI_APT_PREF"|true \&\& ni_write_if_changed "$NI_APT_PREF"|' lib/repo.sh
# 4) apk 仓库行改为纯追加（不幂等）
#    sed -i "s|grep -v '\^@nginx ' \"\$NI_APK_REPOS\"|cat \"\$NI_APK_REPOS\"|" lib/repo.sh
# 5) 注入未调用的死函数
#    printf 'dead_fn(){ :; }\n' >> lib/common.sh
# ============================================================
