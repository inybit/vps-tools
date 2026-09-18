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

# ============ TLS 证书（h2 等标准 TLS 协议用） ============
CERT_DIR="${CONFIG_DIR}/certs"

# 输出 "cert_file key_file"；$1=域名
# 三种来源：已有证书路径 / acme.sh 自动签发（HTTP-01，需 80 空闲）/ 自签（测试用）
obtain_cert() {
  local domain="$1" mode cert_file key_file
  log_info "TLS 证书来源（${domain}）:"
  log_info "  1) 已有证书文件路径"
  log_info "  2) acme.sh 自动签发 Let's Encrypt（HTTP-01 验证，需 80 端口空闲）"
  log_info "  3) 自签证书（测试用，客户端需 skip-cert-verify）"
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
    log_warn "80 端口被占用，无法 HTTP-01 验证——将改用自签证书（客户端需 skip-cert-verify）"
    obtain_cert_selfsigned "$domain"
    return 0
  fi
  log_info "签发 Let's Encrypt 证书（HTTP-01）: ${domain}"
  if "$acme_cmd" --issue --standalone -d "$domain" --httpport 80 --server letsencrypt >/dev/null 2>&1 \
     && "$acme_cmd" --install-cert -d "$domain" \
        --fullchain-file "${dir}/fullchain.pem" --key-file "${dir}/privkey.pem" >/dev/null 2>&1; then
    echo "${dir}/fullchain.pem ${dir}/privkey.pem"
  else
    log_warn "Let's Encrypt 签发失败（域名未解析到本机？80 不可达？）——改用自签证书（客户端需 skip-cert-verify）"
    obtain_cert_selfsigned "$domain"
  fi
}
