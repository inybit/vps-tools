#!/usr/bin/env bash
# ============================================================
# docker-install 模块：模板渲染与 Docker 网络探测
# （从 common.sh 拆出，保持单文件 ≤200 行——架构规约）
# ============================================================

# ---------- 容器私网 CIDR 探测（用于允许容器间互访） ----------
# 无 docker 运行时回退到 RFC1918 默认集合
detect_docker_cidrs() {
  local cidrs=""
  if command -v docker >/dev/null 2>&1; then
    cidrs="$(docker network ls --format '{{.Name}}' 2>/dev/null \
      | while read -r n; do
          [[ -z "$n" ]] && continue
          docker network inspect "$n" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null
        done | tr ' ' '\n' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' | sort -u | tr '\n' ' ' || true)"
  fi
  if [[ -z "${cidrs// /}" ]]; then
    cidrs="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
  fi
  echo "$cidrs"
}

# ---------- 渲染规则块（stdout；逐行替换占位符；不落盘） ----------
# ⚠️ 占位符替换值是【多行】内容，不能用 sed（s 命令不支持多行替换，
#    报 `unterminated 's' command`）→ 用纯 bash 逐行扫描模板。
# $1=docker CIDR 列表（空格分隔）
render_ufw_block() {
  local cidrs="${1:-10.0.0.0/8 172.16.0.0/12 192.168.0.0/16}"
  local tpl="${DI_TPL_DIR}/ufw-docker-block.rules.tpl"
  if [[ ! -f "$tpl" ]]; then
    log_err "模板缺失: $tpl"
    return 1
  fi
  local line cidr
  while IFS= read -r line; do
    case "$line" in
      *__CIDR_RETURN__*)
        for cidr in $cidrs; do
          printf -- '-A DOCKER-USER -j RETURN -s %s\n' "$cidr"
        done
        ;;
      *__CIDR_DROP__*)
        for cidr in $cidrs; do
          printf -- '-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d %s\n' "$cidr"
        done
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$tpl"
}
