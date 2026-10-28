#!/usr/bin/env bash
# warp-tun.sh — 内核 TUN 相关：残留清理（IPv6 策略路由表 ≥10230）+ 出站自检（warp test）
#
# warp_test 放在本文件而不是 warp-cmd.sh：它验的正是「内核 TUN 能不能起来、出口是不是
# WARP」，与残留清理同一主题；warp-cmd.sh 只留命令族分发（也避免单文件超 200 行）。
#
# 背景（2026-10-28 在 bero_de 真机复现）：
#   Xray 的 wireguard 出站走内核 TUN 时，会在 IPv6 策略路由里加
#     · rule: from <隧道 v6 地址> lookup 10230
#     · rule: oif wg0 lookup 10230
#     · route: ::/0 dev wg0 table 10230
#   正常退出（SIGTERM → Close()）会删干净，但 **`xray run -test` 走 os.Exit、
#   不执行 Close()** —— 而 build_config 每次 rebuild 都要跑 -test 校验配置：
#   实测每跑一次就漏一对 rule，优先级递减、无限累积（本机 13 对，含历次测试残留）。
#
# 为什么是「bug 级」而不是洁癖：
#   换 key 后旧地址的 rule 仍在 → 旧 key 的 v6 痕迹留在内核里，
#   与 lib/warp.sh 的「本机是否有公网 IPv6」判定叠加，会把隧道 v6 当成原生能力
#   （新出站因此保留 v6，在没有原生 v6 的机器上内核 TUN 建不起来 → WARP 整个不工作）。
#
# 清理范围（严格）：只动表号 10230–10240 的 IPv6 rule/route。
#   10230 起是 Xray 内核 TUN 的专用表区间（proxy/wireguard/tun_linux.go: tableIndex=10230），
#   且它按 10230、10231… 连续分配（每个 v6 wireguard 出站 +1）。本工具只有 warp 一个
#   wireguard 出站，留 10 个余量足够；**再往上的表号一律不碰**——用户自定义策略表
#   （如 `ip rule add ... table 12345`）常见于 10000+ 区间，宁可漏清也不能误删。
#   local(0) / main(254) 永不涉及。
# 注：删除规则不需要知道接口是否存在；`oif wg0` 在设备消失后显示为 [detached]，同样可删。

XRAY_TUN_TABLE_BASE="${XRAY_TUN_TABLE_BASE:-10230}"
XRAY_TUN_TABLE_MAX="${XRAY_TUN_TABLE_MAX:-$((XRAY_TUN_TABLE_BASE + 10))}"

# 某表下的 IPv6 rule 条数（stdout；无 ip 命令时输出 0）
_warp_tun_rule_count() {  # $1=表号
  command -v ip >/dev/null 2>&1 || { echo 0; return 0; }
  ip -6 rule show 2>/dev/null | awk -v t="$1" '$NF == t' | wc -l
}

# 需要清理的表号（升序去重；stdout）
warp_stale_tun_tables() {
  command -v ip >/dev/null 2>&1 || return 0
  ip -6 rule show 2>/dev/null | awk -v base="${XRAY_TUN_TABLE_BASE}" -v top="${XRAY_TUN_TABLE_MAX}" '
    { for (i = 1; i < NF; i++) if ($i == "lookup") {
        t = $(i + 1) + 0
        if (t >= base && t <= top) print $(i + 1)
      } }' \
    | sort -un
}

# 清理内核 TUN 残留。返回 0（无残留、无 ip 命令都算成功——不该因此打断部署）
warp_cleanup_stale_tun() {  # [--dry-run] [--quiet]
  local dry=0 quiet=0 a t i cnt total=0 max=64
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --quiet)   quiet=1 ;;
    esac
  done
  if ! command -v ip >/dev/null 2>&1; then
    log_warn "未安装 iproute2（ip 命令），跳过内核 TUN 残留清理"
    return 0
  fi
  local -a tables=()
  while IFS= read -r t; do
    [[ -n "$t" ]] && tables+=("$t")
  done < <(warp_stale_tun_tables)
  [[ ${#tables[@]} -gt 0 ]] || return 0

  for t in "${tables[@]}"; do
    cnt="$(_warp_tun_rule_count "$t")"
    if [[ $dry -eq 1 ]]; then
      log_info "[dry-run] 表 ${t}: ${cnt} 条 IPv6 rule 待清理"
      continue
    fi
    # `ip -6 rule del table N` 一次只删一条 → 循环到删空（上限 max 防死循环）
    i=0
    while (( i < max )) && [[ "$(_warp_tun_rule_count "$t")" -gt 0 ]]; do
      ip -6 rule del table "$t" 2>/dev/null || break
      i=$((i + 1))
    done
    ip -6 route flush table "$t" 2>/dev/null || true
    total=$((total + i))
    [[ $quiet -eq 0 ]] && log_info "已清理内核 TUN 残留：表 ${t} 删除 ${i} 条 rule + 该表路由"
  done
  [[ $quiet -eq 0 ]] && log_info "内核 TUN 残留清理完成（共 ${total} 条 rule）"
  return 0
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

  local tcfg tdir tport=18080 pid out="" w i=0
  # ⚠️ 临时配置必须以 .json 结尾：xray 按扩展名判格式，且 **26.10.21 起 `-format=json`
  #    已被忽略**（实测无后缀时加它只是把 "Failed to get format" 换成 "failed to read config"）。
  #    `mktemp` 要求模板末尾就是 XXXXXX，不能写 `xxx.XXXXXX.json` → 先建临时目录，
  #    再在目录里写固定名 config.json。
  tdir="$(mktemp -d "${TMPDIR:-/tmp}/warp-test.XXXXXX")" || die "创建临时目录失败"
  tcfg="${tdir}/config.json"
  jq -n --argjson ob "$ob" --argjson p "$tport" '{
    log: { loglevel: "warning" },
    inbounds: [{ tag: "socks-in", listen: "127.0.0.1", port: $p, protocol: "socks",
                 settings: { udp: false }, sniffing: { enabled: true, destOverride: ["http", "tls"] } }],
    outbounds: [$ob, { protocol: "freedom", tag: "direct" }]
  }' > "$tcfg"
  if ! "${BIN_PATH}" run -test -config "$tcfg" >/dev/null 2>&1; then
    rm -rf "$tdir"
    die "配置校验失败（xray -test）—— 当前 Xray 版本可能不支持 wireguard 出站或 remoteDNS 字段；若 Xray ≥26.10.21 请确认临时配置以 .json 结尾"
  fi
  log_ok "配置校验通过（xray -test）"
  if [[ $net -eq 0 ]]; then rm -rf "$tdir"; return 0; fi

  "${BIN_PATH}" run -config "$tcfg" >/dev/null 2>&1 &
  pid=$!
  while (( i < 40 )); do
    # 临时实例已退出（配置/端口/TUN 问题）→ 立即停，别空转 20 秒再报“无响应”
    kill -0 "$pid" 2>/dev/null || break
    out="$(curl -s --max-time 5 -x "socks5h://127.0.0.1:${tport}" \
           https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)"
    grep -q '^warp=' <<<"$out" && break
    sleep 0.5; i=$((i + 1))
  done
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$tdir"
  w="$(grep -m1 '^warp=' <<<"$out" | cut -d= -f2 || true)"
  if [[ "$w" == "on" ]]; then
    log_ok "出口探测: WARP 生效（warp=on，出口 IP $(grep -m1 '^ip=' <<<"$out" | cut -d= -f2)）"
  else
    log_warn "出口探测失败（warp=${w:-无响应}）—— 查 endpoint 可达性/账号状态；配置本身已过 -test"
    return 1
  fi
}
