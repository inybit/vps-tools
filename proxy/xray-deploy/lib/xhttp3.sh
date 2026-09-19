#!/usr/bin/env bash
# xhttp3.sh — VLESS-XHTTP3-NGINX：向导 / nginx 检测 / UDS 与端口冲突检查 / nginx 只读参考
#
# 形态：客户端 --[HTTP/3 QUIC/UDP + TLS]--> nginx --[h2c gRPC over UDS]--> xray --> 目标
#   - TLS/QUIC 由 nginx 终结（证书用户自理）→ xray 侧无 tlsSettings、无 REALITY
#   - xray 只监听 Unix Domain Socket，不监听任何 TCP/UDP 端口
#
# UDS 落点 = ${UDS_BASE_DIR}/<name>.socket（方案 B：systemd RuntimeDirectory 自动建/清）
#   ⚠️ Xray 不自动创建 socket 所在目录（实测 -test 静默通过、运行时 failed to listen）
#   ⚠️ SIGKILL（崩溃/OOM）残留 socket → 重启 bind: address already in use（实测 3/3）
#      故目录生命周期交给 systemd RuntimeDirectory / OpenRC start_pre+stop_post

UDS_BASE_DIR="${UDS_BASE_DIR:-/run/xray-deploy}"
NGINX_MIN_VERSION="1.25.0"   # QUIC/HTTP3 官方二进制包内置起始版本

xhttp3_socket_path() { echo "${UDS_BASE_DIR}/$1.socket"; }

# ---------- nginx 检测（要求 1：未安装则提示并退出，不代为安装） ----------
require_nginx() {
  if ! command -v nginx >/dev/null 2>&1; then
    log_err "未检测到 nginx —— 本协议需 nginx 终结 TLS/QUIC，xray 只监听 Unix socket"
    log_err "请先安装 nginx（≥ ${NGINX_MIN_VERSION}，需含 --with-http_v3_module）"
    log_err "  vps-tools 自带安装器: sudo nginx-install"
    log_err "  或官方源: https://nginx.org/en/linux_packages.html"
    log_err "已退出，未做任何修改。"
    exit 1
  fi
  local v
  v="$(nginx -v 2>&1 | sed -n 's|.*nginx/\([0-9.]*\).*|\1|p')"
  log_info "检测到 nginx ${v:-未知版本}"
  if [[ -n "$v" ]] && ver_gt "$NGINX_MIN_VERSION" "$v"; then
    log_warn "nginx ${v} < ${NGINX_MIN_VERSION}：QUIC/HTTP3 需 ≥ ${NGINX_MIN_VERSION} 且含 --with-http_v3_module"
  fi
  if nginx -V 2>&1 | grep -q -- '--with-http_v3_module'; then
    log_info "nginx 已编译 --with-http_v3_module ✓"
  else
    log_warn "nginx 未检测到 --with-http_v3_module —— HTTP/3 不可用（官方源包 ≥${NGINX_MIN_VERSION} 默认含）"
  fi
}

# ---------- 冲突检查（xray -test 的两个盲区，必须自己拦） ----------
# 1) UDS 路径唯一性：同路径两个 inbound 时 -test 静默通过，运行时第二个被吞（实测）
xhttp3_check_socket_conflict() {  # $1=socket_path $2=自身 name（新建时传 name，编辑时传自身）
  local sp="$1" self="${2:-}" conflict
  conflict="$(jq -r --arg sp "$sp" --arg self "$self" \
    '.protocols[] | select(.socket_path==$sp and .name!=$self) | .name' \
    "$STATE_FILE" 2>/dev/null | head -1 || true)"
  [[ -z "$conflict" ]] || die "socket 路径 ${sp} 已被协议 ${conflict} 占用（同路径会导致其中一个静默失效）"
}

# 2) 端口互斥：nginx 需独占 TCP（TLS/H2）与 UDP（QUIC）两侧
xhttp3_check_port_conflict() {  # $1=port $2=自身 name
  local port="$1" self="${2:-}" c
  c="$(jq -r --argjson p "$port" --arg self "$self" \
    '.protocols[] | select(.name!=$self and .port==$p and .type!="hysteria2") | .name' \
    "$STATE_FILE" 2>/dev/null | head -1 || true)"
  [[ -z "$c" ]] || die "TCP 端口 ${port} 已被协议 ${c} 占用（nginx 需独占该端口）"
  c="$(jq -r --argjson p "$port" --arg self "$self" \
    '.protocols[] | select(.name!=$self and .port==$p and (.type=="hysteria2" or .type=="ss2022")) | .name' \
    "$STATE_FILE" 2>/dev/null | head -1 || true)"
  [[ -z "$c" ]] || die "UDP 端口 ${port} 已被协议 ${c} 占用（nginx QUIC 需 UDP ${port}）"
}

# ---------- 方案 B：unit 补 RuntimeDirectory 并 daemon-reload ----------
# install_service_file 只写文件；systemd 需 daemon-reload 才会启用新定义（否则仍用旧 unit → 目录不建）
xhttp3_ensure_service_unit() {
  install_service_file
  [[ "$(detect_init)" == "systemd" ]] && systemctl daemon-reload
  mkdir -p "$UDS_BASE_DIR" && chmod 0755 "$UDS_BASE_DIR" \
    || die "无法创建 socket 目录 ${UDS_BASE_DIR}"
}

# ---------- 向导 ----------
proto_wizard_vless_xhttp3_nginx() {  # $1=name → 输出 JSON 参数对象
  local name="$1" port domain path uuid sp lockpath

  require_nginx

  read -r -p "端口 [默认 443]（nginx 对外端口，TCP(ssl)+UDP(quic) 双栈）: " port
  port="${port:-443}"
  [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] || die "无效端口"
  # 不查 port_in_use：443 本就该由 nginx 监听；只查本工具协议是否已占用该端口
  xhttp3_check_port_conflict "$port" "$name"
  ensure_firewall "$port" tcp
  ensure_firewall "$port" udp

  # ⚠️ 提示措辞必须兼容 CF SaaS：域名通常解析到 CF 边缘（非本机），
  #    由 CF 回源到本机；说「须已解析到本机」会误导用户以为要 A 记录指源站
  read -r -p "域名（客户端 SNI / nginx server_name；CF SaaS 下解析到 CF 边缘即可，无需指向本机）: " domain
  [[ -n "$domain" ]] || die "域名不能为空（HTTP/3 客户端必须校验 SNI）"

  read -r -p "XHTTP path [默认 /xray]: " path
  path="${path:-/xray}"
  [[ "$path" == /* ]] || die "path 必须以 / 开头"

  sp="$(xhttp3_socket_path "$name")"
  xhttp3_check_socket_conflict "$sp" "$name"
  lockpath="${sp}.lock"   # Xray 会额外建 <socket>.lock（实测）
  [[ "${#lockpath}" -lt 108 ]] || die "socket 路径过长（Linux sun_path 上限 108 字节）: ${lockpath}"

  uuid="$(gen_uuid)"

  jq -n --arg name "$name" --argjson port "$port" --arg uuid "$uuid" \
    --arg domain "$domain" --arg path "$path" --arg sp "$sp" '
    {
      name: $name, type: "vless-xhttp3-nginx",
      port: $port, uuid: $uuid,
      domain: $domain, path: $path, socket_path: $sp
    }'
}

# ---------- nginx 配置只读参考（D2-b：只打印，不写任何文件、不改 nginx） ----------
xhttp3_print_nginx_reference() {  # $1=domain $2=port $3=path $4=socket_path
  local domain="$1" port="$2" path="$3" sp="$4" loc
  loc="${path%/}/"   # 客户端 stream-one 实际请求 <path>/（带尾斜杠）
  cat <<EOF

--- nginx 配置参考（只读；本工具不写任何 nginx 文件、不 reload nginx）---
# 前提：nginx >= ${NGINX_MIN_VERSION} 且编译含 --with-http_v3_module
# 证书请自行签发/配置（下面两行是占位符，必须替换）
#
# ⚠️ CF SaaS（橙云）场景的证书与 SNI 铁律 —— 配错必报证书不匹配：
#   链路：客户端 --QUIC/TLS(SNI=你的域名)--> CF 边缘(证书=你的域名) --回源--> 本机 nginx
#   ① 本机 nginx 的证书应是 **CF Origin CA 签发**的（覆盖回源 SNI，如 *.007233.xyz），
#      不是公网证书；CF 回源默认用「源站域名」当 SNI，故该域名必须在证书 SAN 内。
#   ② 客户端 server 必须填【域名】而非本机 IP —— 填 IP 会绕过 CF 直连源站，
#      SNI=你的域名 但源站证书是 *.007233.xyz → x509 校验失败
#      （mihomo: CRYPTO_ERROR 0x12a / certificate is valid for *.007233.xyz, not <你的域名>）。
#   ③ CF 侧 SSL/TLS 模式须为 Full (strict)，且该域名已配 SaaS 回源（CNAME 到 origin）。
server {
  listen ${port} ssl;
  listen [::]:${port} ssl;
  listen ${port} quic reuseport;
  listen [::]:${port} quic reuseport;
  server_name ${domain};

  http2 on;
  ssl_certificate     /path/to/fullchain.pem;    # ← 换成你的证书
  ssl_certificate_key /path/to/privkey.pem;      # ← 换成你的私钥
  ssl_protocols TLSv1.2 TLSv1.3;

  client_header_timeout 5m;
  keepalive_timeout 5m;

  location ${loc} {
    client_max_body_size 0;
    grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    client_body_timeout 5m;
    grpc_read_timeout 315;
    grpc_send_timeout 5m;
    grpc_pass unix:${sp};    # ← 本工具生成的 socket 路径（勿照抄上游模板的 /dev/shm 路径）
  }
}
# 放行 QUIC(UDP)：ufw allow ${port}/udp
# 改完执行：nginx -t && systemctl reload nginx
EOF
}
