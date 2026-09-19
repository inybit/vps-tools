#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：restic 缓存目录（systemd 环境下 restic 的硬前提）
#
# 为什么单独成模块：restic 在**没有** RESTIC_CACHE_DIR / XDG_CACHE_HOME / HOME 时
# 直接拒绝工作（`unable to open cache: unable to locate cache directory`，退出非零）。
# systemd 单元不设置 HOME → 定时任务必挂，而交互式跑一切正常。
# 导出落在 lib/common.sh 的 load_env（环境契约）；本模块负责**可写性体检**。
# 与 lib/restic.sh 分开是为了各自守住 ≤200 行（架构规约）。
# ============================================================

# 缓存目录体检：不存在则创建，不可用则给出**可执行**的修复指引（fail-closed）。
# 契约：返回 0 = 目录存在且可写；否则打印原因 + 两条出路（改路径 / 修权限）。
vp_ensure_cache_dir() {
  local d="${RESTIC_CACHE_DIR:-}"
  if [[ -z "$d" ]]; then
    # 理论上不可达：load_env 必定导出。留此分支防「load_env 未调用」的调用路径静默继续。
    log_err "RESTIC_CACHE_DIR 未设置（load_env 未执行？）—— restic 在无 HOME 环境下无法工作"
    log_err "  修正: 确保入口脚本先调用 load_env，或显式 export RESTIC_CACHE_DIR=/var/cache/vps-backup"
    return 1
  fi
  if [[ ! -d "$d" ]]; then
    if ! mkdir -p "$d" 2>/dev/null; then
      log_err "restic 缓存目录无法创建: $d"
      log_err "  ① 改到可写路径: 在 ${VP_ENV_FILE} 设 RESTIC_CACHE_DIR=\"/可写/路径\""
      log_err "  ② 或手工建好: sudo mkdir -p $d && sudo chmod 700 $d"
      return 1
    fi
    chmod 700 "$d" 2>/dev/null || true   # 缓存内含 repo 元数据，勿对他人开放
  fi
  if [[ ! -w "$d" ]]; then
    log_err "restic 缓存目录不可写: $d（当前 uid=${EUID}）"
    log_err "  修正: sudo chown -R \$(id -un) $d  或改 RESTIC_CACHE_DIR"
    return 1
  fi
  return 0
}
