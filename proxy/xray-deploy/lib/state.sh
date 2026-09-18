#!/usr/bin/env bash
# state.sh — state.json 管理（schema_version / server_ip / protocols[] / chain）
#
# 权限 600（含密钥）；所有写操作走 state_set（jq + 临时文件 + mv 原子替换）

# ============ state.json 管理 ============
state_init() {  # 首次创建
  [[ -f "$STATE_FILE" ]] && return 0
  cat > "$STATE_FILE" <<EOF
{
  "schema_version": 1,
  "server_ip": "",
  "installed_at": "$(date -Is)",
  "protocols": []
}
EOF
  chmod 600 "$STATE_FILE"
}

state_get() { jq -r "$1" "$STATE_FILE"; }
state_set() {  # 传 jq 参数（含 filter），如: state_set --arg x v '.f = $x'
  local tmp
  tmp="$(mktemp)"
  jq "$@" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

detect_server_ip() {
  curl -s --max-time 10 https://ipinfo.io/ip 2>/dev/null || \
  curl -s --max-time 10 http://ip-api.com/line/?fields=query 2>/dev/null || \
  echo "127.0.0.1"
}
