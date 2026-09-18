#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：交互输入（TTY 检测 / 读取 / 确认）
# 被 vps-backup.sh source（由 lib/common.sh 拆分而来，2026-09-19）
# ============================================================

# 是否真有控制终端可交互。⚠️ 不能用 [[ -r /dev/tty ]] —— 那是**权限位判定**，
# 无控制终端时同样返回真，直接 read 会报 "/dev/tty: No such device or address"
# （2026-09-18 真机实测）。判据必须是「真打开一次」。
has_ctty() { { : < /dev/tty; } 2>/dev/null; }

# ---------- 交互输入（stdin 被占用时从 /dev/tty 读；返回 1 = 无交互终端） ----------
read_input() {  # $1=提示 $2=变量名
  local _rc=0
  if [[ -t 0 ]]; then
    read -r -p "$1" "$2" || _rc=1
  elif has_ctty; then
    printf '%s' "$1" >&2
    # ⚠️ 2>/dev/null 必须在 < /dev/tty 之前（顺序反了报错会漏到 stderr）
    read -r "$2" 2>/dev/null < /dev/tty || _rc=1
  else
    _rc=1
  fi
  if [[ $_rc -ne 0 ]]; then
    printf -v "$2" ""    # set -u 兜底
    return 1
  fi
}

# 确认提示（默认 N）；返回 0 = 确认
confirm() {  # $1=提示文本
  [[ "${VP_YES}" == "1" ]] && return 0
  local ans=""
  read_input "$1 [y/N] " ans || return 1
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}
