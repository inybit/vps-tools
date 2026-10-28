#!/usr/bin/env bash
# warp-cmd.sh — WARP 命令族：setup（导入 wgcf-profile.conf）/ show / test / remove
#
# 核心（解析、校验、出站生成、state 写入）在 lib/warp.sh。
# 私钥永不打印：setup 回显与 show 均只给末 4 位。

# ============ 导入 ============
warp_setup() {  # [profile路径|-] [--no-tun] [--reserved a,b,c] [--ipv6 auto|on|off]
  local src="" tun="null" reserved="" ipv6="auto" a t json yn
  need_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装，先运行: xray-deploy install"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-tun)   tun="true" ;;
      --reserved) reserved="${2:-}"; shift || true ;;
      --ipv6)     ipv6="${2:-auto}"; shift || true ;;
      -)          src="-" ;;
      *)          src="$1" ;;
    esac
    shift || true
  done

  if [[ -z "$src" ]]; then
    log_info "WARP 回国出站配置（导入 wgcf-profile.conf）"
    log_info "  生成方式: wgcf register && wgcf generate → wgcf-profile.conf"
    echo "  1) 读取文件（默认 /root/wgcf-profile.conf）" >&2
    echo "  2) 直接粘贴内容" >&2
    local c
    read_input "选择 [1-2，回车默认 1]: " c || die "无交互终端（也可直接: xray-deploy warp setup <路径>）"
    case "${c:-1}" in
      2) src="-" ;;
      *)
        read_input "profile 路径 [/root/wgcf-profile.conf]: " a || die "无交互终端"
        src="${a:-/root/wgcf-profile.conf}"
        ;;
    esac
  fi

  if [[ "$src" == "-" ]]; then
    if [[ -t 0 ]]; then
      t="$(warp_read_pasted)" || die "读取粘贴内容失败"
    else
      t="$(mktemp "${TMPDIR:-/tmp}/wgcf-profile.XXXXXX")" || die "创建临时文件失败"
      chmod 600 "$t"
      cat > "$t"
    fi
  else
    [[ -r "$src" ]] || die "无法读取 profile: ${src}"
    t="$src"
  fi

  json="$(warp_parse_profile "$t")" || { [[ "$t" != "$src" ]] && rm -f "$t"; die "profile 解析失败，未做任何改动"; }
  [[ "$t" != "$src" ]] && rm -f "$t"

  # ---- IPv6 决策：本机没有公网 IPv6 → 出站不配置 v6 ----
  # 无 v6 的机器上内核 TUN 加 v6 地址/路由会失败 → 整个 WARP 出站起不来。
  # 故按本机能力剔除 address / allowedIPs / remoteDNS 里的 v6 项，并把决策写进 state
  # （.warp.ipv6），保证之后 rebuild 生成的出站可复现、不随环境漂移。
  case "$ipv6" in
    auto) if warp_local_has_public_ipv6; then ipv6="true"; else ipv6="false"; fi ;;
    on)   ipv6="true" ;;
    off)  ipv6="false" ;;
    *)    die "--ipv6 取值非法: ${ipv6}（auto|on|off）" ;;
  esac
  if [[ "$ipv6" == "true" ]] && ! warp_local_has_public_ipv6; then
    log_warn "本机未检测到公网 IPv6，但按 --ipv6 on 保留 v6 配置（内核 TUN 可能失败 → 失败时加 --no-tun 走 gVisor）"
  fi
  if [[ "$ipv6" == "false" ]]; then
    local stripped
    stripped="$(warp_strip_ipv6 "$json")" || die "剔除 IPv6 条目失败，未做任何改动"
    [[ "$(jq -r '.address | length' <<<"$stripped")" -gt 0 ]] \
      || die "profile 只有 IPv6 隧道地址，本机也没有公网 IPv6 —— 无法配置（可加 --ipv6 on 强制）"
    json="$stripped"
  fi
  json="$(jq -c --argjson v "$ipv6" '. + {ipv6: $v}' <<<"$json")"

  # 回显摘要（私钥全程不出现），确认后才写 state
  echo >&2
  log_info "解析结果（私钥已隐藏）:"
  jq -r --arg tun "$tun" '
    "  接口地址 : " + (.address | join(", "))
    + "\n  IPv6     : " + (if .ipv6 then "已配置" else "未配置（本机无公网 IPv6 → 已剔除 v6 地址/路由/DNS）" end)
    + "\n  MTU      : " + (.mtu | tostring)
    + "\n  DNS      : " + (if (.dns | length) == 0 then "（未指定，用 Xray 默认）" else (.dns | join(", ")) end)
    + "\n  对端     : " + .endpoint
    + "\n  对端公钥 : …" + (.public_key[-4:])
    + "\n  允许路由 : " + (.allowed_ips | join(", "))
    + "\n  内核 TUN : " + (if $tun == "null" then "自动（Xray 自行检测）" else "已禁用（gVisor 用户态）" end)' \
    <<<"$json" >&2
  read_input "确认写入并启用（回国流量改走 WARP，不再 block）？[Y/n]: " yn || yn=""
  [[ "${yn,,}" == "n" ]] && { log_info "已取消"; return 0; }

  warp_write_state "$json" "$src" "$tun" || die "写入 state.json 失败"
  # reserved（部分 WARP 账号需要 client_id 派生的 3 字节；wgcf-profile.conf 里没有）
  if [[ -n "$reserved" ]]; then
    local -a rb=()
    IFS=',' read -ra rb <<<"$reserved"
    [[ ${#rb[@]} -eq 3 ]] || die "reserved 需要 3 个字节，如 --reserved 1,2,3（其余配置已写入）"
    state_set --argjson r "$(printf '%s\n' "${rb[@]}" | jq -R 'tonumber' | jq -s -c .)" '.warp.reserved = $r'
  fi
  rebuild_and_reload
  log_info "WARP 回国出站已启用。查看: xray-deploy warp show ｜ 自检: sudo xray-deploy warp test"
}

# ============ 查看（只读，不需 root） ============
warp_show() {
  [[ -f "$STATE_FILE" ]] || die "尚未安装（state.json 不存在）"
  if ! warp_enabled; then
    echo "WARP 回国出站: 未启用（回国流量当前走 blackhole）"
    echo "  启用: sudo xray-deploy warp setup /root/wgcf-profile.conf"
    return 0
  fi
  echo "WARP 回国出站: 已启用（geosite:cn / geoip:cn → wireguard 出站 ${WARP_OUTBOUND_TAG}）"
  jq -r '
    .warp as $w
    | "  接口地址 : " + ($w.address | join(", "))
    + "\n  IPv6     : " + (if $w.ipv6 == null then "自动（老配置，按本机探测）"
                         elif $w.ipv6 then "已配置" else "未配置（本机无公网 IPv6）" end)
    + "\n  MTU      : " + ($w.mtu | tostring)
    + "\n  DNS      : " + (if ($w.dns | length) == 0 then "（未指定，Xray 默认）" else ($w.dns | join(", ")) end)
    + "\n  对端     : " + $w.endpoint
    + "\n  对端公钥 : …" + ($w.public_key[-4:])
    + "\n  私钥     : …" + ($w.private_key[-4:])
    + "\n  允许路由 : " + ($w.allowed_ips | join(", "))
    + "\n  内核 TUN : " + (if ($w.no_kernel_tun // null) == null then "自动（Xray 检测）" else "已禁用（gVisor）" end)
    + "\n  导入来源 : " + ($w.source // "?") + "  @ " + ($w.imported_at // "?")
    + (if ($w.reserved // null) == null then "" else "\n  reserved : " + ($w.reserved | tostring) end)' "$STATE_FILE"
  echo "  自检: sudo xray-deploy warp test [--net] ｜ 移除: sudo xray-deploy warp remove"
}

# ============ 自检 ============
# 默认只做配置层（生成出站 + xray -test）；--net 额外临时起 loopback socks 探测真实出口
warp_test() {  # [--net]
  local net=0; [[ "${1:-}" == "--net" ]] && net=1
  [[ -f "$STATE_FILE" ]] || die "尚未安装（state.json 不存在）"
  warp_enabled || die "WARP 未启用（先: sudo xray-deploy warp setup /root/wgcf-profile.conf）"
  local ob
  ob="$(gen_warp_outbound)"
  [[ -n "$ob" ]] || die "生成 WARP 出站失败（state.json 的 .warp 不完整）"
  log_ok "出站字段: $(jq -r 'keys | join(",")' <<<"$ob")"
  [[ -x "$BIN_PATH" ]] || { log_warn "xray 二进制缺失（${BIN_PATH}），跳过 -test"; return 0; }

  local tcfg tport=18080 pid out="" w i=0
  tcfg="$(mktemp "${TMPDIR:-/tmp}/warp-test.XXXXXX")" || die "创建临时配置失败"
  jq -n --argjson ob "$ob" --argjson p "$tport" '{
    log: { loglevel: "warning" },
    inbounds: [{ tag: "socks-in", listen: "127.0.0.1", port: $p, protocol: "socks",
                 settings: { udp: false }, sniffing: { enabled: true, destOverride: ["http", "tls"] } }],
    outbounds: [$ob, { protocol: "freedom", tag: "direct" }]
  }' > "$tcfg"
  if ! "${BIN_PATH}" run -test -format=json -config "$tcfg" >/dev/null 2>&1; then
    rm -f "$tcfg"
    die "配置校验失败（xray -test）—— 当前 Xray 版本可能不支持 wireguard 出站或 remoteDNS 字段"
  fi
  log_ok "配置校验通过（xray -test）"
  if [[ $net -eq 0 ]]; then rm -f "$tcfg"; return 0; fi

  "${BIN_PATH}" run -config "$tcfg" >/dev/null 2>&1 &
  pid=$!
  while (( i < 40 )); do
    out="$(curl -s --max-time 5 -x "socks5h://127.0.0.1:${tport}" \
           https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    grep -q '^warp=' <<<"$out" && break
    sleep 0.5; i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$tcfg"
  w="$(grep -m1 '^warp=' <<<"$out" | cut -d= -f2 || true)"
  if [[ "$w" == "on" ]]; then
    log_ok "出口探测: WARP 生效（warp=on，出口 IP $(grep -m1 '^ip=' <<<"$out" | cut -d= -f2)）"
  else
    log_warn "出口探测失败（warp=${w:-无响应}）—— 查 endpoint 可达性/账号状态；配置本身已过 -test"
    return 1
  fi
}

# ============ 移除 ============
warp_remove() {
  need_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装"
  warp_enabled || { log_info "WARP 未启用"; return 0; }
  confirm "确认移除 WARP 出站（回国流量回到 blackhole）？" || { log_info "已取消"; return 0; }
  state_set 'del(.warp)'
  rebuild_and_reload
  log_info "WARP 出站已移除，回国流量恢复 blackhole"
}

# ============ 子命令分发 ============
warp_dispatch() {
  local sub="${1:-show}"
  shift || true
  case "$sub" in
    setup)  warp_setup "$@" ;;
    show)   warp_show ;;
    test)   warp_test "$@" ;;
    remove) warp_remove ;;
    *)      die "warp 用法: setup [profile路径|-] [--no-tun] [--reserved a,b,c] [--ipv6 auto|on|off] | show | test [--net] | remove" ;;
  esac
}
