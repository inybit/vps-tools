#!/usr/bin/env bash
# inbound.sh — 服务端配置聚合：state.json 协议参数 → inbound JSON → config.json
#
# 配置原子替换：写 .tmp → xray -test 校验 → 通过才 mv 生效（失败保留线上配置）
# ⚠️ xray 26.x 按扩展名判格式，.tmp 后缀必须显式 -format=json

# ============ 服务端配置聚合 ============
# state.json 的 protocols[] 存参数对象；这里按协议类型推导 inbound
# 新增协议时在此加一个分支（与 PROTO_REGISTRY 对应）
protocol_to_inbound() {  # $1=协议参数 JSON → 输出 inbound JSON（数组元素）
  local json="$1" type
  type="$(jq -r '.type' <<<"$json")"
  case "$type" in
    vless-reality)
      jq '{
        tag: .name, listen: "0.0.0.0", port: .port, protocol: "vless",
        settings: { clients: [{ id: .uuid, flow: "xtls-rprx-vision" }], decryption: "none" },
        streamSettings: {
          network: "tcp", security: "reality",
          realitySettings: {
            show: false, dest: (.sni + ":443"), xver: 0,
            serverNames: [.sni], privateKey: .private_key, shortIds: (.short_ids // [.short_id])
          }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
      }' <<<"$json"
      ;;
    vless-xhttp-reality)
      # VLESS + XHTTP + REALITY + XMUX：无需证书，回落伪装；REALITY 官方支持 RAW/XHTTP/gRPC
      # mode: auto → 客户端 REALITY 走 stream-one（实测日志确认），服务端 auto 接受三种模式
      # XMUX 仅客户端生效（服务端写 xmux 无害但无效）→ 服务端不生成 xmux
      jq '{
        tag: .name, listen: "0.0.0.0", port: .port, protocol: "vless",
        settings: { clients: [{ id: .uuid }], decryption: "none" },
        streamSettings: {
          network: "xhttp", security: "reality",
          realitySettings: {
            show: false, dest: (.sni + ":443"), xver: 0,
            serverNames: [.sni], privateKey: .private_key, shortIds: (.short_ids // [.short_id])
          },
          xhttpSettings: { mode: "auto", path: .path }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
      }' <<<"$json"
      ;;
    vless-xhttp|vless-h2)
      # VLESS + HTTP/2 (h2) + TLS：真实证书落地（域名需解析到本机）
      # Xray 26.x 起 h2 transport 已迁移至 XHTTP（method=xhttp），stream-up 模式即 HTTP/2 传输
      jq '{
        tag: .name, listen: "0.0.0.0", port: .port, protocol: "vless",
        settings: { clients: [{ id: .uuid }], decryption: "none" },
        streamSettings: {
          method: "xhttp", security: "tls",
          tlsSettings: {
            serverName: .domain,
            certificates: [{ certificateFile: .cert_file, keyFile: .key_file }]
          },
          xhttpSettings: { mode: "stream-up", path: .path, host: .domain }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
      }' <<<"$json"
      ;;
    vless-xhttp3-nginx)
      # VLESS + XHTTP + UDS：TLS/QUIC 由 nginx 终结，xray 只监听 Unix Domain Socket
      # 无 tlsSettings / 无 REALITY（明文 h2c，nginx 用 grpc_pass unix: 转发）
      # 依据：XTLS/Xray-examples/VLESS-XHTTP3-Nginx/server.jsonc
      #   - listen 支持 "<路径>,<八进制权限>"（transport/internet/system_listener.go）
      #   - 绝对路径判为 UDS，port 必须省略（infra/conf/xray.go）
      #   - 明文服务端同时支持 HTTP/1.1 与 h2c（splithttp/hub.go）
      jq '{
        tag: .name, listen: (.socket_path + ",0666"), protocol: "vless",
        settings: { clients: [{ id: .uuid }], decryption: "none" },
        streamSettings: {
          network: "xhttp",
          xhttpSettings: { mode: "stream-one", path: .path }
        },
        sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
      }' <<<"$json"
      ;;
    hysteria2)
      # Hysteria 2：QUIC/UDP，官方默认端口 443（模拟 HTTP/3 流量）
      # Xray 协议名 hysteria + version 2
      # 坑（2026-08-16 真机实测）：inbound auth 必须在 settings.clients[].auth，
      # hysteriaSettings.auth 仅 outbound 有效（写那里 xray -test 通过但握手失败）
      # Xray 26.x 客户端已移除 allowInsecure → 自签证书用 pinnedPeerCertSha256（xray 系）
      # mihomo/sing-box 侧对应 fingerprint / certificate_public_key_sha256（见 keys.sh 的 cert_* 函数）
      # BRUTAL 拥塞控制（可选）：finalmask.quicParams.congestion=force-brutal + brutalUp/Down；
      # 服务端启用后客户端必须配套设置带宽（mihomo up/down、sing-box up_mbps/down_mbps），否则连接失败
      jq '{
        tag: .name, listen: "0.0.0.0", port: .port, protocol: "hysteria",
        settings: { version: 2, clients: [{ auth: .password }] },
        streamSettings: (
          {
            network: "hysteria", security: "tls",
            tlsSettings: {
              serverName: (.domain // ""), alpn: ["h3"],
              certificates: [{ certificateFile: .cert_file, keyFile: .key_file }]
            },
            hysteriaSettings: ({ version: 2 }
              + (if .masquerade then { masquerade: { type: "proxy", url: .masquerade } } else {} end))
          }
          + (if (.brutal_up != null and .brutal_down != null) then
              { finalmask: { quicParams: {
                  congestion: "force-brutal",
                  brutalUp: .brutal_up,
                  brutalDown: .brutal_down
                } } }
            else {} end)
        )
      }' <<<"$json"
      ;;
    ss2022)
      # SS2022（shadowsocks 2022）：用于【中转机 → 落地机】这一跳（境外↔境外）。
      # method 必须是 2022-blake3-*（32 字节 key）；network tcp,udp 同时监听两种协议。
      # ⚠️ Xray 会打印 deprecated 软警告（PrintNonRemovalDeprecatedFeatureWarning，
      #    源码注释明确 "won't be removed in the near future"）—— 属正常，非即将移除。
      jq '{
        tag: .name, listen: "0.0.0.0", port: .port, protocol: "shadowsocks",
        settings: {
          method: .method,
          password: .password,
          network: "tcp,udp"
        }
      }' <<<"$json"
      ;;
    *) die "未实现的 inbound 生成: ${type}" ;;
  esac
}

# 组装 outbounds：默认 freedom(direct) + blackhole(block)；配了链路则追加 landing；
# 启用 WARP 则追加 wireguard(warp)（回国流量出站，与 chain 正交）
build_outbounds_json() {
  local base='[
    { "protocol": "freedom", "tag": "direct" },
    { "protocol": "blackhole", "tag": "block" }
  ]'
  local landing warp
  landing="$(gen_landing_outbound 2>/dev/null || true)"
  warp="$(gen_warp_outbound 2>/dev/null || true)"
  if [[ -n "$landing" ]]; then
    base="$(jq -c --argjson l "$landing" '. + [$l]' <<<"$base")"
  fi
  if [[ -n "$warp" ]]; then
    base="$(jq -c --argjson w "$warp" '. + [$w]' <<<"$base")"
  fi
  printf '%s' "$base"
}

build_config() {  # 从 state.json 聚合 inbounds + outbounds + routing
  # routing 规则生成见 lib/routing.sh（build_routing_rules_json）
  local inbounds p outbounds rules tmp_cfg
  # ⚠️ 临时文件必须保留 .json 扩展名：Xray 26.10.21 起配置加载器**只按扩展名判格式**，
  #    `-format=json` 不再能覆盖它 → 用 `config.json.tmp` 会直接报
  #    "unsupported config file extension"，任何 rebuild 都会校验失败。
  #    实测：26.9.9 可用、26.10.21 失效（详见 README「已知坑」）。
  tmp_cfg="${CONFIG_FILE%.json}.tmp.json"
  inbounds="$(jq -c '.protocols[]' "$STATE_FILE" | while read -r p; do
    protocol_to_inbound "$p"
  done | jq -s -c .)"
  [[ -n "$inbounds" ]] || die "state.json 无任何协议"

  outbounds="$(build_outbounds_json)"
  rules="$(build_routing_rules_json)"

  jq -n \
    --argjson inbounds "$inbounds" \
    --argjson outbounds "$outbounds" \
    --argjson rules "$rules" '
    {
      log: { loglevel: "warning" },
      routing: { domainStrategy: "IPIfNonMatch", rules: $rules },
      outbounds: $outbounds,
      inbounds: $inbounds
    }' > "$tmp_cfg"

  # 校验通过才生效（原子替换）
  if "${BIN_PATH}" run -test -format=json -config "$tmp_cfg" >/dev/null 2>&1; then
    mv "$tmp_cfg" "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
    log_info "配置生成并校验通过: ${CONFIG_FILE}"
  else
    rm -f "$tmp_cfg"
    die "配置校验失败（xray -test），已保留线上配置不变"
  fi
}
