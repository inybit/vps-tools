#!/usr/bin/env bash
# ============================================================
# vps-tools 一键发版：读版本号 → 校验 → 打 tag → 建 GitHub Release
#
# 用法:
#   scripts/release.sh <target> [--dry-run] [--all]
#
#   target    installer           → tag v<VPS_TOOLS_VERSION>（读 install.sh）
#             <tool>              → tag <tool>-v<版本>（读该工具主脚本的版本变量）
#             all                 → 安装器 + 全部工具（基线首发用）
#   --dry-run 只打印将要做的事，不写任何东西
#
# 版本语义（双轴，互不影响）:
#   安装器版本 = install.sh 的 VPS_TOOLS_VERSION，改了安装器行为才递增
#   工具版本   = 各工具主脚本里的 VERSION 变量，改了该工具才递增
#   发布哪个轴就打哪个轴的 tag，另一个轴不动。
#
# 退出码: 0 = 全部成功；1 = 有失败（脚本会明确说是哪一步）
# ============================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

INSTALLER_SCRIPT="install.sh"
# 安装器 release 只看 install.sh 的变更：README 常随工具改动一起更新，
# 把它算进来会把工具改动混进安装器的 notes（基线首发时尤其明显）
INSTALLER_PATHS=("install.sh")

DRY_RUN=0
TARGETS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --all)     TARGETS+=("all"); shift ;;
    -h|--help) sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        echo "未知参数: $1" >&2; exit 2 ;;
    *)         TARGETS+=("$1"); shift ;;
  esac
done
[[ ${#TARGETS[@]} -gt 0 ]] || { echo "用法: scripts/release.sh <installer|工具名|all> [--dry-run]" >&2; exit 2; }

die() { echo "[ERROR] $*" >&2; exit 1; }
info() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*"; }

# ---------- 前置检查 ----------
command -v gh >/dev/null || die "缺少 gh CLI"
command -v git >/dev/null || die "缺少 git"
# dry-run 允许脏工作区（预览用）；真发版必须干净，否则 tag 指向的树与工作区不一致
[[ $DRY_RUN -eq 1 || -z "$(git status --porcelain)" ]] || die "工作区不干净，先提交（git status 有输出）"
git rev-parse --verify HEAD >/dev/null 2>&1 || die "没有任何 commit"

# ---------- 工具注册表解析（只读文本，不执行 install.sh） ----------
# 输出: <tool>\t<主脚本相对路径>
tool_rows() {
  sed -n '/^TOOLS=(/,/^)/p' "$INSTALLER_SCRIPT" \
    | grep -oP '^\s*"[^"]+"' \
    | tr -d ' "' \
    | awk -F'|' '{print $1 "\t" $2}'
}

# 版本号：主脚本里第一个 <NAME>_VERSION="x.y.z" 或 VERSION="x.y.z"
script_version() {  # $1=脚本路径
  [[ -r "$1" ]] || return 0
  sed -n 's/^[A-Za-z_]*VERSION="\([0-9][0-9.]*\)".*/\1/p' "$1" | head -1
}

# 该 target 的上一个 tag（没有则空 = 全历史）
last_tag() {  # $1=target
  if [[ "$1" == "installer" ]]; then
    # v<数字> 才算安装器 tag；工具 tag 形如 vps-backup-v1.4.0，不会被 v[0-9]* 命中
    git tag -l 'v[0-9]*' --sort=-v:refname | head -1
  else
    git tag -l "$1-v[0-9]*" --sort=-v:refname | head -1
  fi
}

# ---------- 生成 release notes ----------
notes_for() {  # $1=target $2=tag $3...=路径
  local target="$1" tag="$2"; shift 2
  local prev range commits
  prev="$(last_tag "$target")"
  if [[ -n "$prev" ]]; then
    range="${prev}..HEAD"
    echo "## ${tag}"
    echo
    echo "变更范围: \`${prev}..HEAD\`（仅本${target}相关路径）"
  else
    range="HEAD"
    echo "## ${tag}"
    echo
    echo "基线首发：本仓库第一个 \`${target}\` 版本标签。变更范围为**全历史**中与"
    echo "\`${target}\` 相关的提交（此前无版本坐标，故无法做增量对比）。"
  fi
  echo
  commits="$(git log --oneline --no-merges "$range" -- "$@" || true)"
  if [[ -n "$commits" ]]; then
    echo '```'
    echo "$commits"
    echo '```'
  else
    echo "_（该范围内无涉及此路径的提交）_"
  fi
  echo
  echo "安装/回滚: \`vps-tools install <tool> --ref ${tag}\`"
}

# ---------- 发一个 target ----------
release_one() {  # $1=target
  local target="$1" tag ver paths=() script dir
  if [[ "$target" == "installer" ]]; then
    ver="$(script_version "$INSTALLER_SCRIPT")"
    [[ -n "$ver" ]] || die "读不到 VPS_TOOLS_VERSION（$INSTALLER_SCRIPT）"
    tag="v${ver}"
    paths=("${INSTALLER_PATHS[@]}")
  else
    local row
    row="$(tool_rows | awk -F'\t' -v t="$target" '$1==t{print $2}')"
    [[ -n "$row" ]] || die "未知工具: ${target}（不在 install.sh 的 TOOLS 注册表里）"
    script="$row"
    ver="$(script_version "$script")"
    [[ -n "$ver" ]] || die "读不到版本号（$script）"
    tag="${target}-v${ver}"
    dir="$(dirname "$script")"
    paths=("$dir")
  fi

  info "target=${target}  版本=${ver}  tag=${tag}"

  if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null; then
    warn "tag ${tag} 已存在，跳过（如需重发：git tag -d ${tag} && git push origin :refs/tags/${tag}）"
    return 0
  fi
  if gh release view "$tag" >/dev/null 2>&1; then
    warn "Release ${tag} 已存在，跳过"
    return 0
  fi

  local notes; notes="$(mktemp "${TMPDIR:-/tmp}/vps-tools-notes.XXXXXX")"
  notes_for "$target" "$tag" "${paths[@]}" > "$notes"

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "----- [dry-run] ${tag} notes -----"
    cat "$notes"
    echo "----- [dry-run] 将执行: git tag -a ${tag} / git push origin ${tag} / gh release create -----"
    rm -f "$notes"
    return 0
  fi

  git tag -a "$tag" -m "${target} ${ver}"
  info "已创建 tag: ${tag}"
  git push origin "refs/tags/${tag}" >/dev/null 2>&1 || die "推送 tag 失败: ${tag}（权限/网络）"
  info "已推送 tag: ${tag}"

  if ! gh release create "$tag" --title "${tag}" --notes-file "$notes" --verify-tag >/dev/null 2>&1; then
    rm -f "$notes"
    die "创建 Release 失败: ${tag}"
  fi
  rm -f "$notes"

  # 事务一致性：以服务端实际状态为准，不信 gh 的自报成功
  local seen
  seen="$(gh release view "$tag" --json tagName --jq .tagName 2>/dev/null || true)"
  [[ "$seen" == "$tag" ]] || die "服务端复核失败: 期望 ${tag}，实际 ${seen:-空}"
  info "已发布并复核: ${tag}  ($(gh release view "$tag" --json url --jq .url))"
}

# ---------- 主流程 ----------
expand_targets() {
  local t
  for t in "${TARGETS[@]}"; do
    if [[ "$t" == "all" ]]; then
      echo "installer"
      tool_rows | cut -f1
    else
      echo "$t"
    fi
  done
}

mapfile -t LIST < <(expand_targets | awk '!seen[$0]++')
[[ ${#LIST[@]} -gt 0 ]] || die "没有可发布的 target"

info "分支: $(git rev-parse --abbrev-ref HEAD)  HEAD: $(git rev-parse --short HEAD)  dry-run=${DRY_RUN}"
fail=0
for t in "${LIST[@]}"; do
  echo
  echo "===== ${t} ====="
  release_one "$t" || fail=1
done

echo
if [[ $fail -ne 0 ]]; then
  echo "[FAIL] 有 target 发布失败，见上方日志" >&2
  exit 1
fi
[[ $DRY_RUN -eq 1 ]] && info "dry-run 结束，未写入任何东西" || info "全部完成"
