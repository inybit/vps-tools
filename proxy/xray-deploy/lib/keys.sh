#!/usr/bin/env bash
# keys.sh — 密钥与证书：UUID / REALITY 密钥对 / shortId / 带宽归一化 / TLS 证书获取
#
# ⚠️ gen_reality_keys 必须兼容 xray 三种输出格式（缺一种会伪造出「版本不兼容」假结论）：
#   旧版 `Private key:` / `Public key:`
#   中间版 v25.8.31~v25.12.8 `Password: xxx`（无 (PublicKey) 后缀）
#   新版 26.x `PrivateKey:` / `Password (PublicKey):`

# ============ 密钥生成 ============
gen_uuid() { "${BIN_PATH}" uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid; }
gen_short_id() { openssl rand -hex 8; }
gen_reality_keys() {  # 输出 "private_key public_key"
  # 兼容新旧格式：旧版 "Private key: xxx" / "Public key: xxx"；新版(26.x) "PrivateKey: xxx" / "Password (PublicKey): xxx"
  "${BIN_PATH}" x25519 2>/dev/null | awk '
    /PrivateKey:/{p=$2}
    /Private key:/{p=$3}
    /Password \(PublicKey\):/{q=$3}
    /Public key:/{q=$3}
    END{print p, q}'
}

# BRUTAL 带宽归一化：纯数字自动补 mbps 单位（xray 无单位时按 B/s 解析，60 → 60B/s < 64KB/s 校验失败）
# 例：60 → "60 mbps"；"60 mbps"/"100Mbps" → 原样保留（交给 xray 校验）
normalize_bandwidth() {
  local v="$1"
  [[ -z "$v" ]] && { echo ""; return; }
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "$v mbps"
  else
    echo "$v"
  fi
}

# ============ 证书指纹（pin）：自签证书的客户端校验 ============
#
# 为什么需要（2026-10-12）：自签证书下客户端原本只能 insecure/skip-cert-verify
#   = 「不验证服务器证书」→ 任何持有伪造证书的人都能冒充服务端。正确做法是
#   **证书固定（pinning）**：客户端只认这张证书的指纹，对不上直接拒连。
#
# ⚠️ 三家的字段名与哈希对象都不同，不能互抄（逐个源码核实）：
#   客户端            字段                              哈希对象         编码
#   mihomo          fingerprint                        整张叶子证书 DER  hex
#   sing-box        certificate_public_key_sha256      公钥 SPKI         base64
#   hysteria(原生)   pinSHA256                          整张叶子证书 DER  hex
#   依据：mihomo component/ca/fingerprint.go（sha256(cert.Raw)，hex，可带冒号）；
#        sing-box common/tls/std_client.go VerifyPublicKeySHA256
#          （sha256(x509.MarshalPKIXPublicKey(pub))，base64）；
#        hysteria app/cmd/client.go fillTLSConfig（sha256(rawCerts[0])，hex）。
#   三个客户端在设置 pin 时都会**自动关闭**链校验（mihomo InsecureSkipVerify=true、
#   sing-box 同理、hysteria 覆写 VerifyPeerCertificate）→ 因此 pin 与 insecure
#   语义互斥：同时写等于 pin 白写。

# 解析守卫：先证明「这是一张能解析的证书」，再算哈希。
# ⚠️ 少了这一步会出【假阳性指纹】：对垃圾输入，openssl 管道后半段会把空输入
#    哈希掉，返回「空串的 sha256」（实测 notacert.pem → 47DEQpj8HBSa+/TImW+5JC…），
#    看起来像一枚合法指纹，写进客户端后永远连不上且原因难查。
cert_parses() {  # $1=证书文件；0=可解析的证书
  [[ -f "$1" ]] || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  openssl x509 -in "$1" -noout -subject >/dev/null 2>&1
}

# 整张叶子证书 DER 的 sha256 → 小写 hex（无冒号）
# 用途：mihomo fingerprint / hysteria pinSHA256
cert_sha256_hex() {
  cert_parses "$1" || return 1
  local out
  out="$(openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null || true)"
  out="${out##*=}"                                  # 取 "=" 后的十六进制串
  out="$(printf '%s' "$out" | tr -d ':' | tr 'A-F' 'a-f')"
  [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1        # 严格 64 位校验，防截断/空值
  printf '%s' "$out"
}

# 公钥 SPKI 的 sha256 → base64
# 用途：sing-box certificate_public_key_sha256（1.13.0+；1.15.0 才有整证书版 certificate_sha256）
cert_pubkey_sha256_b64() {
  cert_parses "$1" || return 1
  local out
  out="$(openssl x509 -in "$1" -pubkey -noout 2>/dev/null \
         | openssl pkey -pubin -outform der 2>/dev/null \
         | openssl dgst -sha256 -binary 2>/dev/null \
         | openssl enc -base64 2>/dev/null | tr -d '\n' || true)"
  [[ -n "$out" ]] || return 1
  printf '%s' "$out"
}

# 是否自签证书（issuer == subject）。决定客户端片段用 pin 还是走链校验。
# 用 issuer/subject 字符串比较而非 `openssl verify -CAfile self`：
#   后者对「同 subject 的中间 CA 签发」会误判，且不同 openssl 版本退出码不一致。
cert_is_self_signed() {
  cert_parses "$1" || return 1
  local iss sub
  iss="$(openssl x509 -in "$1" -noout -issuer 2>/dev/null || true)"
  sub="$(openssl x509 -in "$1" -noout -subject 2>/dev/null || true)"
  [[ -n "$iss" && -n "$sub" ]] || return 1
  [[ "${iss#*=}" == "${sub#*=}" ]]
}

# 从证书路径取两枚 pin，输出 "sha256_hex pubkey_sha256_b64"（失败则空串）
# 调用点统一用它，避免在每个协议分支重复拼 openssl 管道。
cert_pin_fields() {  # $1=证书文件
  local hex b64
  hex="$(cert_sha256_hex "$1" 2>/dev/null || true)"
  b64="$(cert_pubkey_sha256_b64 "$1" 2>/dev/null || true)"
  printf '%s %s' "$hex" "$b64"
}

# ============ TLS 证书（h2 等标准 TLS 协议用） ============
CERT_DIR="${CONFIG_DIR}/certs"

# 输出 "cert_file key_file"；$1=域名
# 三种来源：已有证书路径 / acme.sh 自动签发（HTTP-01，需 80 空闲）/ 自签（测试用）
obtain_cert() {
  local domain="$1" mode cert_file key_file
  log_info "TLS 证书来源（${domain}）:"
  log_info "  1) 已有证书文件路径"
  log_info "  2) acme.sh 自动签发 Let's Encrypt（HTTP-01 验证，需 80 端口空闲）"
  log_info "  3) 自签证书（客户端片段自动带证书指纹 pin，无需 insecure）"
  read_input "选择 [1-3，默认 1]: " mode
  mode="${mode:-1}"
  case "$mode" in
    1)
      read_input "证书文件 fullchain.pem 路径: " cert_file
      read_input "私钥 privkey.pem 路径: " key_file
      [[ -n "$cert_file" ]] && [[ -f "$cert_file" ]] || die "证书文件不存在: ${cert_file}"
      [[ -n "$key_file" ]] && [[ -f "$key_file" ]] || die "私钥文件不存在: ${key_file}"
      echo "$cert_file $key_file"
      ;;
    2)
      obtain_cert_acme "$domain"
      ;;
    3)
      obtain_cert_selfsigned "$domain"
      ;;
    *) die "无效选择" ;;
  esac
}

obtain_cert_selfsigned() {  # $1=domain；输出 "cert_file key_file"（存 CERT_DIR/<domain>/）
  local domain="$1" dir="${CERT_DIR}/${domain}"
  mkdir -p "$dir"
  log_info "生成自签证书: ${domain}（有效期 365 天）"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout "${dir}/privkey.pem" -out "${dir}/fullchain.pem" -days 365 \
    -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1 \
    || openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "${dir}/privkey.pem" -out "${dir}/fullchain.pem" -days 365 \
      -subj "/CN=${domain}" -addext "subjectAltName=DNS:${domain}" >/dev/null 2>&1 \
    || die "自签证书生成失败"
  echo "${dir}/fullchain.pem ${dir}/privkey.pem"
}

obtain_cert_acme() {  # $1=domain；输出 "cert_file key_file"
  local domain="$1" dir="${CERT_DIR}/${domain}" acme_cmd
  mkdir -p "$dir"
  if ! command -v acme.sh >/dev/null 2>&1 && [[ ! -x /root/.acme.sh/acme.sh ]]; then
    log_info "安装 acme.sh ..."
    curl -fsSL --max-time 60 https://get.acme.sh | sh -s -- --no-profile >/dev/null 2>&1 \
      || die "acme.sh 安装失败（手动安装: curl https://get.acme.sh | sh）"
  fi
  acme_cmd="acme.sh"; command -v acme.sh >/dev/null 2>&1 || acme_cmd="/root/.acme.sh/acme.sh"
  # 先尝试 standalone（HTTP-01，80 端口）；失败回退自签并提示（不阻断部署）
  if port_in_use 80; then
    log_warn "80 端口被占用，无法 HTTP-01 验证——将改用自签证书（客户端片段将带证书指纹 pin）"
    obtain_cert_selfsigned "$domain"
    return 0
  fi
  log_info "签发 Let's Encrypt 证书（HTTP-01）: ${domain}"
  if "$acme_cmd" --issue --standalone -d "$domain" --httpport 80 --server letsencrypt >/dev/null 2>&1 \
     && "$acme_cmd" --install-cert -d "$domain" \
        --fullchain-file "${dir}/fullchain.pem" --key-file "${dir}/privkey.pem" >/dev/null 2>&1; then
    echo "${dir}/fullchain.pem ${dir}/privkey.pem"
  else
    log_warn "Let's Encrypt 签发失败（域名未解析到本机？80 不可达？）——改用自签证书（客户端片段将带证书指纹 pin）"
    obtain_cert_selfsigned "$domain"
  fi
}
