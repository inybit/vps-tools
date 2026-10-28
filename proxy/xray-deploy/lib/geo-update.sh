#!/usr/bin/env bash
# ============ geo 数据更新（MetaCubeX/meta-rules-dat） ============
# 用法: update_geo [--quiet] [--restart]
#   --quiet    只打错误（timer / 脚本内调用）
#   --restart  更新后先 `xray -test` 校验，通过才重启服务（Xray 只在启动时加载 geo）
# 兼容旧语义：任何非 flag 参数一律视为 --quiet（旧版 `update-geo <任意>` 即静默）。
#
# ⚠️ 原子替换 + 尺寸闸（2026-10-28 新增，配合定时任务）：
#   旧实现直接 `curl -o <线上文件>`，下载中断/代理返回错误页会**当场把线上 geo 数据
#   写坏**；以前只是手动更新时崩一次，现在每周自动跑 + 自动重启，写坏就等于每周
#   定时把服务打挂。故：先下到 `<f>.new` → 尺寸闸 → 备份 `.bak` → mv 生效；
#   -test 失败把 `.bak` 换回去，服务不重启。
update_geo() {
  local quiet=0 restart=0 a f url tmp size
  local -a staged=()
  for a in "$@"; do
    case "$a" in
      --quiet)   quiet=1 ;;
      --restart) restart=1 ;;
      "")        ;;
      *)         quiet=1 ;;   # 旧语义兼容
    esac
  done
  need_root
  mkdir -p "${INSTALL_DIR}"

  # 1) 全部先落暂存文件：任一失败 → 删暂存，线上文件一个字节都不动
  for f in geosite.dat geoip.dat; do
    url="${GEO_SOURCE}/${f}"
    [[ -n "${GH_PROXY:-}" ]] && url="${GH_PROXY}${url}"
    [[ $quiet -eq 0 ]] && log_info "更新 ${f}: ${url}"
    tmp="${INSTALL_DIR}/${f}.new"
    # --quiet 时给 curl 加 -s：否则进度条会刷进 journal（timer 触发时尤其吵）
    local -a copts=(-fL --max-time 180)
    [[ $quiet -eq 1 ]] && copts+=(-s)
    if ! curl "${copts[@]}" -o "$tmp" "$url"; then
      [[ ${#staged[@]} -gt 0 ]] && rm -f "${staged[@]}"
      rm -f "$tmp"
      log_err "${f} 下载失败（线上 geo 数据未改动）"
      return 1
    fi
    size="$(stat -c %s "$tmp" 2>/dev/null || echo 0)"
    # 2) 尺寸闸：geoip.dat ≈20MB / geosite.dat ≈5MB，< 1MB 基本是错误页或半截文件
    if [[ "${size:-0}" -lt 1048576 ]]; then
      [[ ${#staged[@]} -gt 0 ]] && rm -f "${staged[@]}"
      rm -f "$tmp"
      log_err "${f} 内容异常（${size} 字节 < 1MB，疑似错误页/半截文件），线上 geo 数据未改动"
      return 1
    fi
    staged+=("$tmp")
  done

  # 3) 生效：先备份旧文件再替换（-test 失败要能换回来）
  for f in geosite.dat geoip.dat; do
    [[ -f "${INSTALL_DIR}/${f}" ]] && cp -p "${INSTALL_DIR}/${f}" "${INSTALL_DIR}/${f}.bak"
    mv -f "${INSTALL_DIR}/${f}.new" "${INSTALL_DIR}/${f}"
  done

  # 4) --restart：校验通过才重启；失败回滚 geo 并保持服务运行旧数据
  if [[ $restart -eq 1 ]]; then
    if [[ -x "${BIN_PATH}" && -f "${CONFIG_FILE}" ]] \
       && ! XRAY_LOCATION_ASSET="${INSTALL_DIR}" "${BIN_PATH}" run -test -format=json \
            -config "${CONFIG_FILE}" >/dev/null 2>&1; then
      for f in geosite.dat geoip.dat; do
        [[ -f "${INSTALL_DIR}/${f}.bak" ]] && mv -f "${INSTALL_DIR}/${f}.bak" "${INSTALL_DIR}/${f}"
      done
      log_err "geo 数据校验失败（xray -test），已回滚旧数据；服务未重启"
      return 1
    fi
    service_restart
    [[ $quiet -eq 0 ]] && log_info "服务已重启（新 geo 数据生效）"
  fi

  rm -f "${INSTALL_DIR}"/*.dat.bak
  [[ $quiet -eq 0 ]] && log_info "geo 数据已更新（MetaCubeX/meta-rules-dat）"
  return 0
}
