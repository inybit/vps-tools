#!/usr/bin/env bash
# proto-edit.sh — 协议参数修改（端口 / SNI / 域名 / UUID / 密码 / path / BRUTAL / masquerade）

proto_edit() {
  need_root
  [[ -f "$STATE_FILE" ]] || die "尚未安装"
  local name
  proto_list_names
  read -r -p "输入要修改的协议名称或序号: " name
  name="$(resolve_proto_name "$name")" || return 1
  local idx type
  idx="$(jq --arg n "$name" '[.protocols[] | select(.name==$n)] | length' "$STATE_FILE")"
  [[ "$idx" -eq 1 ]] || die "协议 ${name} 不存在"
  type="$(jq -r --arg n "$name" '.protocols[] | select(.name==$n) | .type' "$STATE_FILE")"
  echo "修改 ${name}（${type}）:"
  echo "  1) 端口"
  if [[ "$type" == "vless-xhttp" || "$type" == "vless-h2" ]]; then
    echo "  2) 域名（需同步更新证书/客户端）"
  elif [[ "$type" == "hysteria2" ]]; then
    echo "  2) SNI/域名（重签证书）"
  else
    echo "  2) 回落域名(SNI)"
  fi
  if [[ "$type" == "hysteria2" ]]; then
    echo "  3) 重新生成密码"
    echo "  4) BRUTAL 带宽（回车清空禁用）"
    echo "  5) masquerade 伪装 URL（回车清空禁用）"
  else
    echo "  3) 重新生成 UUID"
    [[ "$type" == "vless-xhttp-reality" ]] && echo "  4) XHTTP path"
  fi
  read -r -p "选择 [1-5]: " sel
  case "${sel:-1}" in
    1)
      local port
      read -r -p "新端口: " port
      [[ "$port" =~ ^[0-9]+$ ]] && [[ "$port" -ge 1 ]] && [[ "$port" -le 65535 ]] || die "无效端口"
      if [[ "$type" == "hysteria2" ]]; then
        port_in_use "$port" udp && die "端口 ${port}/UDP 已被占用"
        ensure_firewall "$port" udp
      else
        if [[ "$type" == "vless-reality" || "$type" == "vless-xhttp-reality" ]]; then
          local pconflict
          pconflict="$(jq -r --arg n "$name" --argjson p "$port" \
            '.protocols[] | select(.name!=$n and .port==$p and (.type=="vless-reality" or .type=="vless-xhttp-reality")) | .name' \
            "$STATE_FILE" 2>/dev/null | head -1 || true)"
          [[ -z "$pconflict" ]] || die "端口 ${port} 已被 REALITY 协议 ${pconflict} 占用——同端口多 REALITY 会串台（实测 30% 失败率），请换端口"
        fi
        port_in_use "$port" && die "端口 ${port} 已被占用"
        ensure_firewall "$port" tcp
      fi
      state_set --arg n "$name" --argjson port "$port" \
        '.protocols = [.protocols[] | if .name==$n then .port=$port else . end]'
      ;;
    2)
      if [[ "$type" == "vless-xhttp" || "$type" == "vless-h2" ]]; then
        local domain certs cert_file key_file
        read -r -p "新域名: " domain
        [[ -n "$domain" ]] || die "域名不能为空"
        certs="$(obtain_cert "$domain")" || die "证书获取失败"
        cert_file="${certs%% *}"; key_file="${certs##* }"
        state_set --arg n "$name" --arg domain "$domain" --arg cert_file "$cert_file" --arg key_file "$key_file" \
          '.protocols = [.protocols[] | if .name==$n then (.domain=$domain | .cert_file=$cert_file | .key_file=$key_file) else . end]'
      elif [[ "$type" == "hysteria2" ]]; then
        local domain certs cert_file key_file
        read -r -p "新 SNI/域名: " domain
        certs="$(obtain_cert "${domain:-localhost}")" || die "证书获取失败"
        cert_file="${certs%% *}"; key_file="${certs##* }"
        state_set --arg n "$name" --arg domain "$domain" --arg cert_file "$cert_file" --arg key_file "$key_file" \
          '.protocols = [.protocols[] | if .name==$n then (.domain=$domain | .cert_file=$cert_file | .key_file=$key_file) else . end]'
      else
        local sni
        sni="$(select_fallback_domain)" || die "回落域名选择失败"
        state_set --arg n "$name" --arg sni "$sni" \
          '.protocols = [.protocols[] | if .name==$n then .sni=$sni else . end]'
      fi
      ;;
    3)
      if [[ "$type" == "hysteria2" ]]; then
        local password
        password="$(openssl rand -base64 18 | tr -d '=+/' | head -c 24)"
        state_set --arg n "$name" --arg password "$password" \
          '.protocols = [.protocols[] | if .name==$n then .password=$password else . end]'
      else
        local uuid
        uuid="$(gen_uuid)"
        state_set --arg n "$name" --arg uuid "$uuid" \
          '.protocols = [.protocols[] | if .name==$n then .uuid=$uuid else . end]'
      fi
      ;;
    4)
      if [[ "$type" == "vless-xhttp-reality" ]]; then
        local path
        read -r -p "新 XHTTP path [当前 $(jq -r --arg n "$name" '.protocols[] | select(.name==$n) | .path' "$STATE_FILE")]: " path
        [[ "$path" == /* ]] || die "path 必须以 / 开头"
        state_set --arg n "$name" --arg path "$path" \
          '.protocols = [.protocols[] | if .name==$n then .path=$path else . end]'
        log_info "path 已更新为 ${path}（客户端需同步修改 xhttp-opts.path）"
        rebuild_and_reload
        return 0
      fi
      [[ "$type" == "hysteria2" ]] || die "无效选择"
      local brutal_up brutal_down
      read -r -p "BRUTAL 上行带宽（如 100 mbps，回车禁用 BRUTAL）: " brutal_up
      brutal_up="$(normalize_bandwidth "${brutal_up:-}")"
      read -r -p "BRUTAL 下行带宽（如 100 mbps，回车禁用 BRUTAL）: " brutal_down
      brutal_down="$(normalize_bandwidth "${brutal_down:-}")"
      if [[ -n "$brutal_up" || -n "$brutal_down" ]]; then
        [[ -n "$brutal_up" && -n "$brutal_down" ]] || die "BRUTAL 需同时设置上行与下行带宽"
        log_warn "BRUTAL 启用：客户端（mihomo up/down、sing-box up_mbps/down_mbps）必须同步设置，否则连接失败"
        state_set --arg n "$name" --arg brutal_up "$brutal_up" --arg brutal_down "$brutal_down" \
          '.protocols = [.protocols[] | if .name==$n then (.brutal_up=$brutal_up | .brutal_down=$brutal_down) else . end]'
      else
        state_set --arg n "$name" \
          '.protocols = [.protocols[] | if .name==$n then del(.brutal_up, .brutal_down) else . end]'
        log_info "BRUTAL 已禁用（客户端需移除 up/down 或 up_mbps/down_mbps）"
      fi
      ;;
    5)
      [[ "$type" == "hysteria2" ]] || die "无效选择"
      local masq
      read -r -p "masquerade 伪装 URL（如 https://www.bing.com，回车清空禁用）: " masq
      masq="${masq:-}"
      if [[ -n "$masq" ]]; then
        state_set --arg n "$name" --arg masq "$masq" \
          '.protocols = [.protocols[] | if .name==$n then .masquerade=$masq else . end]'
        log_info "masquerade 已设置: ${masq}"
      else
        state_set --arg n "$name" \
          '.protocols = [.protocols[] | if .name==$n then del(.masquerade) else . end]'
        log_info "masquerade 已清空"
      fi
      ;;
    *) die "无效选择" ;;
  esac
  rebuild_and_reload
  log_info "协议 ${name} 已更新"
}
