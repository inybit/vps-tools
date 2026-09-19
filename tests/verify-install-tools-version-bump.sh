#!/usr/bin/env bash
# ============================================================
# 回归守卫：改了 TOOLS 清单就必须同步递增 VPS_TOOLS_VERSION
#
# 背景（2026-09-19 anthony_fr 实测事故）：
#   给 xray-deploy 新增 lib/xhttp3.sh 并写进 TOOLS 的 extra_files，但**忘了升
#   VPS_TOOLS_VERSION**（仍是 1.8.0）。后果链：
#     ① 用户机已装副本 v1.8.0 == 远端 v1.8.0 → install_self 报「已是最新」→ 不拉远端
#     ② 运行中的旧副本 TOOLS 清单陈旧 → install_tool 只装旧的 25 个 lib
#     ③ 主脚本是新的（入口已 source xhttp3.sh）→ 启动即崩：
#        /usr/local/lib/vps-tools/xray-deploy/lib/xhttp3.sh: No such file or directory
#   症状极具迷惑性：lib/ 下所有文件 mtime 一致（都刚更新过），唯独缺新增那个。
#
# 本测试用「TOOLS 清单指纹 + 版本号」的配对基线把这类遗漏变成红灯。
#
# 用法: bash tests/verify-install-tools-version-bump.sh
#       改了 TOOLS 且**确实**升了版本后，用下面命令刷新基线：
#         UPDATE_BASELINE=1 bash tests/verify-install-tools-version-bump.sh
# ============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${REPO}/install.sh"
BASE="${REPO}/tests/.install-tools-baseline.txt"
[[ -f "$SRC" ]] || { echo "SKIP: 找不到 install.sh"; exit 0; }

PASS=0; FAIL=0
ck(){ if [[ "$2" == "$3" ]]; then echo "  [PASS] $1"; PASS=$((PASS+1));
      else echo "  [FAIL] $1"; echo "         期望: $3"; echo "         实际: $2"; FAIL=$((FAIL+1)); fi; }

ver_of(){ sed -n 's/^VPS_TOOLS_VERSION="\([^"]*\)".*/\1/p' "$1" | head -1; }

# TOOLS 清单指纹：抽取 TOOLS=( ... ) 整块，去空白后哈希（增删/改序都会变）
tools_fp(){ sed -n '/^TOOLS=(/,/^)/p' "$1" | tr -d ' \t\n' | sha256sum | cut -c1-16; }

CUR_VER="$(ver_of "$SRC")"
CUR_FP="$(tools_fp "$SRC")"

echo "=== install.sh TOOLS/版本 配对检查 ==="
echo "  当前版本: ${CUR_VER}"
echo "  TOOLS 指纹: ${CUR_FP}"
echo "  注册工具数: $(sed -n '/^TOOLS=(/,/^)/p' "$SRC" | grep -c '^  "')"
echo "  基线文件: ${BASE}"
echo

[[ -n "$CUR_VER" ]] || { echo "  [FAIL] 读不到 VPS_TOOLS_VERSION"; exit 1; }
[[ -n "$CUR_FP" ]]  || { echo "  [FAIL] 读不到 TOOLS 数组"; exit 1; }

if [[ "${UPDATE_BASELINE:-0}" == "1" ]]; then
  printf '%s %s\n' "$CUR_VER" "$CUR_FP" > "$BASE"
  echo "  已刷新基线: $(cat "$BASE")"
  exit 0
fi

if [[ ! -f "$BASE" ]]; then
  printf '%s %s\n' "$CUR_VER" "$CUR_FP" > "$BASE"
  echo "  [INFO] 首次运行，已建立基线: $(cat "$BASE")"
  echo
  echo "==================================="
  echo " PASS=${PASS} FAIL=${FAIL}"
  echo "==================================="
  exit 0
fi

BASE_VER="$(cut -d' ' -f1 "$BASE")"
BASE_FP="$(cut -d' ' -f2 "$BASE")"
echo "  基线版本: ${BASE_VER}   基线指纹: ${BASE_FP}"
echo

VER_CHANGED=no; [[ "$CUR_VER" != "$BASE_VER" ]] && VER_CHANGED=yes
FP_CHANGED=no;  [[ "$CUR_FP"  != "$BASE_FP"  ]] && FP_CHANGED=yes

if [[ "$FP_CHANGED" == "yes" && "$VER_CHANGED" == "no" ]]; then
  echo "  [FAIL] TOOLS 清单变了，但 VPS_TOOLS_VERSION 仍是 ${CUR_VER}（未升版）"
  echo
  echo "  为什么必须升版：install_self 用版本比对决定是否拉取远端 install.sh。"
  echo "  版本没变 → 已装副本报「已是最新」→ 运行中的旧 TOOLS 清单陈旧 →"
  echo "  新增的 lib/templates 文件永远装不上，而主脚本已 source 它们 → 工具启动即崩。"
  echo
  echo "  修复：把 install.sh 里的 VPS_TOOLS_VERSION 递增，然后刷新基线："
  echo "    UPDATE_BASELINE=1 bash tests/verify-install-tools-version-bump.sh"
  echo
  echo "  本次 TOOLS 差异（基线 → 当前）："
  diff <(sed -n '/^TOOLS=(/,/^)/p' "$SRC" | tr ' ' '\n' | grep -v '^$' | sort) \
       <(echo "$BASE_FP" >/dev/null; sed -n '/^TOOLS=(/,/^)/p' "$SRC" | tr ' ' '\n' | grep -v '^$' | sort) \
       >/dev/null 2>&1 || true
  FAIL=$((FAIL+1))
else
  ck "TOOLS 清单与版本号配对一致" "ok" "ok"
  if [[ "$FP_CHANGED" == "yes" && "$VER_CHANGED" == "yes" ]]; then
    echo "  [INFO] TOOLS 与版本都已变（${BASE_VER} → ${CUR_VER}）——配对正确"
    echo "  [INFO] 刷新基线: UPDATE_BASELINE=1 bash tests/verify-install-tools-version-bump.sh"
  fi
fi

echo
echo "=== 附加断言：新增的 extra_files 必须真实存在 ==="
missing=0
while IFS= read -r line; do
  # 剥掉行首缩进与包裹的双引号（grep '^  "' 会把首个引号带进 $line）
  line="${line#"${line%%[![:space:]]*}"}"   # 去行首空白
  line="${line#\"}"; line="${line%\"}"      # 去首尾双引号
  [[ -n "$line" ]] || continue
  name="$(cut -d'|' -f1 <<<"$line")"
  ef="$(cut -d'|' -f6 <<<"$line")"
  for f in $ef; do
    if [[ ! -f "${REPO}/${f}" ]]; then
      echo "  [FAIL] ${name} 的 extra_files 指向不存在的文件: ${f}"
      missing=$((missing+1))
    fi
  done
done < <(sed -n '/^TOOLS=(/,/^)/p' "$SRC" | grep '^  "')
if [[ "$missing" -eq 0 ]]; then
  echo "  [PASS] 所有 extra_files 均真实存在"
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+missing))
fi

echo
echo "=== 附加断言：主脚本 source 的 lib 必须都在 extra_files 里 ==="
# 这是本次事故的直接防线：入口 source 了 xhttp3.sh，但 extra_files 若漏写它，
# 全新安装也会缺文件（与自更新缺陷叠加）。反向也要查。
miss_src=0
for main in $(sed -n '/^TOOLS=(/,/^)/p' "$SRC" | grep '^  "' | cut -d'|' -f2); do
  [[ -f "${REPO}/${main}" ]] || continue
  mdir="$(dirname "$main")"
  ef="$(sed -n '/^TOOLS=(/,/^)/p' "$SRC" | grep -F "\"${main}|" | cut -d'|' -f6)"
  [[ -n "$ef" ]] || continue
  while read -r rel; do
    [[ -n "$rel" ]] || continue
    # 归一化：extra_files 是「仓库根相对路径」，source 的是「脚本内相对路径」
    case " ${ef} " in
      *" ${rel} "*) : ;;
      *) echo "  [FAIL] ${main} source 了 ${rel}，但 extra_files 未列出"; miss_src=$((miss_src+1)) ;;
    esac
  done < <(grep -oP '^\.\s+"\$\{LIB_DIR\}/\K[^"]+' "${REPO}/${main}" 2>/dev/null | sed "s|^|${mdir}/lib/|")
done
if [[ "$miss_src" -eq 0 ]]; then
  echo "  [PASS] 主脚本 source 的 lib 均已在 extra_files 中登记"
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+miss_src))
fi

echo
echo "==================================="
echo " PASS=${PASS} FAIL=${FAIL}"
echo "==================================="
[[ "$FAIL" -eq 0 ]]
