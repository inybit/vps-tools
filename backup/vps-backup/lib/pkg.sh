#!/usr/bin/env bash
# ============================================================
# vps-backup 模块：包管理器探测与安装 / 配置写入
# 被 vps-backup.sh source（由 lib/common.sh 拆分而来，2026-09-19）
# ============================================================

# ---------- 包管理器探测与安装 ----------
# detect_pkg_mgr / install_pkgs 已统一到仓库根 lib/core.sh（本文件由 common.sh source）。
# 原先这里有第 6 份实现（VP_DETECTED_PKG_MGR 缓存），2026-10-19 抽取时删除：
# 缓存会引入「改了 PATH 仍返回旧值」的隐性 bug，而 command -v 本身极廉价。

# ---------- 配置写入（原子 tmp+mv；key 已存在则替换，否则追加） ----------
vp_env_set() {  # $1=key $2=value
  local key="$1" val="$2" f="${VP_ENV_FILE}" tmp
  [[ -f "$f" ]] || { log_err "配置不存在: $f"; return 1; }
  tmp="${f}.tmp"
  if grep -qE "^${key}=" "$f"; then
    # 用 | 作分隔符，值里的 / 不转义；值内 | 罕见（token 不含）
    sed "s|^${key}=.*|${key}=\"${val}\"|" "$f" > "$tmp"
  else
    cp "$f" "$tmp"
    printf '%s="%s"\n' "$key" "$val" >> "$tmp"
  fi
  mv "$tmp" "$f"
  chmod 600 "$f"
  log_ok "已更新配置: ${key}=${val}"
}
