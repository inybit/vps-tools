#!/usr/bin/env bash
# ============================================================
# 注册表完整性守卫：install.sh 的 TOOLS 注册表 ↔ 磁盘实际文件
#
# 背景（2026-09-19 anthony_fr 实测事故，见 verify-install-tools-version-bump.sh 头注释）：
#   给 xray-deploy 新增 lib/xhttp3.sh 但忘了写进 TOOLS 的 extra_files →
#   用户机装完后主脚本 source 缺文件 → 启动即崩，且症状极具迷惑性
#   （lib/ 下所有文件 mtime 一致，唯独缺新增那个）。
#   现有测试只守「改 TOOLS 必须升 VPS_TOOLS_VERSION」，不守「磁盘文件是否都登记了」。
#
# 本套件把注册表当契约检查（双向）：
#   R1 每行 6 字段（字段数错 = 后面所有解析全错位）
#   R2 script / env_template 路径存在，env_target 落在配置目录
#   R3 extra_files 登记的每个文件都必须存在（登记了不存在的文件 = 装完崩）
#   R4 磁盘上工具目录里的 .sh/.tpl 都必须登记（漏登记 = 装完缺文件）
#   R5 每个工具的版本号能被 install.sh 的 installed_tool_version() 正则读到
#      （该正则只认 `^[A-Za-z_]*VERSION="x.y.z"`；写成 readonly/带前导空格就读不到，
#        list 显示 v?、更新判定失效）
#   R6 每个工具都支持 -v/--version 与 -h/--help（仓库约定 2/3）
#   R7 README 工具表「结构」列的数字与实际文件数一致（手写数字会漂移）
#
# 用法: bash tests/verify-registry-completeness.sh
# 退出码: 0=全部通过
# ============================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO" || exit 1

python3 - "$REPO" <<'PY'
import os, re, sys

REPO = sys.argv[1]
PASS = 0
FAIL = 0

def ck(name, ok, detail=""):
    global PASS, FAIL
    if ok:
        print(f"  [PASS] {name}")
        PASS += 1
    else:
        print(f"  [FAIL] {name}")
        if detail:
            print(f"         {detail}")
        FAIL += 1

src = open(os.path.join(REPO, "install.sh"), encoding="utf-8").read()

# ---------- 解析 TOOLS ----------
m = re.search(r"^TOOLS=\((.*?)^\)", src, re.S | re.M)
if not m:
    print("  [FAIL] 找不到 TOOLS=( ... ) 块")
    print(" PASS=0 FAIL=1")
    sys.exit(1)

rows = []
for line in m.group(1).strip().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    if not (line.startswith('"') and line.endswith('"')):
        ck("注册表行格式", False, f"不是双引号包裹的行: {line[:60]}")
        continue
    rows.append(line.strip('"').split("|"))

print("=== 注册表完整性检查 ===")
print(f"  工具数: {len(rows)}")
print()

# R1: 字段数
print("[R1] 每行 6 字段")
bad = [r[0] for r in rows if len(r) != 6]
ck("全部注册行为 6 字段", not bad, f"字段数错误: {bad}")
print()

# R2: 主脚本 / 环境模板存在
print("[R2] script / env_template / env_target")
for r in rows:
    if len(r) != 6:
        continue
    name, script, env_tpl, env_tgt = r[0], r[1], r[2], r[3]
    ck(f"{name}: 主脚本存在", os.path.isfile(os.path.join(REPO, script)), script)
    if env_tpl:
        ck(f"{name}: 环境模板存在", os.path.isfile(os.path.join(REPO, env_tpl)), env_tpl)
        ck(f"{name}: 模板有 env_target",
           bool(env_tgt) and (env_tgt.startswith("/etc/") or "${CONFIG_DIR}" in env_tgt),
           f"env_target={env_tgt!r}")
    else:
        ck(f"{name}: 无模板则不配 env_target", not env_tgt, f"env_target={env_tgt!r}")
print()

# R3/R4: extra_files 双向
# 条目两种格式（与 install.sh 的 ef_src_dst 对齐）：
#   源路径               目标 = 源剥掉工具目录前缀（工具自己的文件）
#   源路径:目标相对路径   目标显式指定（跨目录共享文件，如 lib/core.sh:lib/core.sh）
print("[R3] extra_files 登记的文件都存在")
print("[R4] 磁盘上的 .sh/.tpl 都已登记")
for r in rows:
    if len(r) != 6:
        continue
    name, script, extra = r[0], r[1], r[5]
    entries = extra.split() if extra else []
    srcs = [e.split(":", 1)[0] for e in entries]
    missing = sorted(p for p in srcs if not os.path.isfile(os.path.join(REPO, p)))
    ck(f"{name}: 登记的文件都存在", not missing, f"登记但不存在: {missing}")

    if not entries:
        continue
    tool_dir = os.path.dirname(os.path.join(REPO, script))
    # 目标（相对工具目录）：有冒号取冒号后，否则 = 源相对工具目录
    dsts = set()
    for e in entries:
        if ":" in e:
            dsts.add(e.split(":", 1)[1])
        else:
            dsts.add(os.path.relpath(os.path.join(REPO, e), tool_dir))
    disk = set()
    for root, _dirs, files in os.walk(tool_dir):
        for fn in files:
            if not fn.endswith((".sh", ".tpl")):
                continue
            full = os.path.join(root, fn)
            if os.path.abspath(full) == os.path.abspath(os.path.join(REPO, script)):
                continue
            disk.add(os.path.relpath(full, tool_dir))
    unreg = sorted(disk - dsts)
    ck(f"{name}: 磁盘文件无漏登记", not unreg, f"未登记: {unreg}")
print()

# R5: 版本号可被 installed_tool_version() 的正则读到
print("[R5] 版本号可被 install.sh 正则读到")
VER_RE = re.compile(r'^[A-Za-z_]*VERSION="([0-9][0-9.]*)"', re.M)
for r in rows:
    if len(r) != 6:
        continue
    name, script = r[0], r[1]
    body = open(os.path.join(REPO, script), encoding="utf-8").read()
    ver = VER_RE.search(body)
    ck(f"{name}: 版本号可读", bool(ver),
       f"{script} 没有匹配 ^[A-Za-z_]*VERSION=\"x.y.z\" 的行（readonly/前导空格都会导致读不到）")
print()

# R6: -v / -h 约定
print("[R6] -v/--version 与 -h/--help")
for r in rows:
    if len(r) != 6:
        continue
    name, script = r[0], r[1]
    body = open(os.path.join(REPO, script), encoding="utf-8").read()
    ck(f"{name}: 支持 -v", bool(re.search(r"--version|-V\)|\"-v\"", body)))
    ck(f"{name}: 支持 -h", bool(re.search(r"--help|-h\)", body)))
print()

# R7: README 工具表「结构」列
print("[R7] README 工具表结构列与实际文件数一致")
readme = open(os.path.join(REPO, "README.md"), encoding="utf-8").read()
for r in rows:
    if len(r) != 6:
        continue
    name, script, extra = r[0], r[1], r[5]
    tool_dir = os.path.dirname(os.path.join(REPO, script))
    n_sh = sum(1 for root, _d, fs in os.walk(tool_dir) for f in fs
               if f.endswith(".sh") and os.path.abspath(os.path.join(root, f))
               != os.path.abspath(os.path.join(REPO, script)))
    n_tpl = sum(1 for root, _d, fs in os.walk(tool_dir) for f in fs if f.endswith(".tpl"))

    row_m = re.search(r"^\|\s*\[" + re.escape(name) + r"\]\([^)]*\)\s*\|.*\|\s*([^|]*?)\s*\|\s*$",
                      readme, re.M)
    if not row_m:
        ck(f"{name}: README 有工具行", False, "工具清单表里找不到该行")
        continue
    struct = row_m.group(1)
    if n_sh == 0 and n_tpl == 0:
        ck(f"{name}: README 标为单文件", struct == "单文件", f"README 写的是「{struct}」")
        continue
    mm = re.search(r"(\d+)\s*lib(?:\s*\+\s*(\d+)\s*tpl)?", struct)
    if not mm:
        ck(f"{name}: README 结构列可解析", False, f"结构列「{struct}」不含 N lib 写法")
        continue
    want_sh = int(mm.group(1))
    want_tpl = int(mm.group(2) or 0)
    ck(f"{name}: lib 数一致", n_sh == want_sh, f"实际 {n_sh} lib，README 写 {want_sh}")
    if want_tpl or n_tpl:
        ck(f"{name}: tpl 数一致", n_tpl == want_tpl, f"实际 {n_tpl} tpl，README 写 {want_tpl}")
print()

print("===================================")
print(f" PASS={PASS} FAIL={FAIL}")
print("===================================")
sys.exit(0 if FAIL == 0 else 1)
PY
