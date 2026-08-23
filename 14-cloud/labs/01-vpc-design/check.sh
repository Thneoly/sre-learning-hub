#!/usr/bin/env bash
# check.sh —— Lab 01 三层 VPC 设计评分（纯纸面检查，不访问云资源、不依赖 k8s 集群）
# 用法：
#   chmod +x check.sh && ./check.sh                 # 检查同目录下的 design.md
#   bash check.sh /path/to/design.md                # 或显式指定文件路径
# 依赖：bash、grep、awk、wc、python3 或 python（Ubuntu 22.04/24.04 自带；只做只读解析）
# 约定：design.md 需满足 task.md 规定的章节标题与表格格式；本脚本只读，不修改任何文件
# 输出：逐项 PASS/FAIL，末尾 SCORE: X/Y；全部通过 exit 0，否则 exit 1
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
DESIGN="${1:-$SCRIPT_DIR/design.md}"

TOTAL=0
PASSED=0
pass() { TOTAL=$((TOTAL + 1)); PASSED=$((PASSED + 1)); printf 'PASS: %s\n' "$1"; }
fail() { TOTAL=$((TOTAL + 1)); printf 'FAIL: %s\n' "$1"; }

# design.md 不存在时直接 0 分退出，避免后续命令对空文件误报
if [ ! -r "$DESIGN" ]; then
  echo "FAIL: 找不到可读的 design.md（期望路径：$DESIGN）"
  echo "SCORE: 0/12"
  exit 1
fi

# 取出 design.md 某章节正文：从 "## N." 起到下一个 "## " 前
section() {
  awk -v n="$1" 'index($0, "## " n ".") == 1 { f = 1; next } /^## / { f = 0 } f' "$DESIGN"
}

echo "== design.md: $DESIGN =="

# ---- 检查 1：文件规模 ----
LINES=$(wc -l < "$DESIGN")
if [ "$LINES" -ge 30 ]; then
  pass "design.md 存在且不少于 30 行（当前 ${LINES} 行）"
else
  fail "design.md 仅 ${LINES} 行，不足 30 行（设计说明写得太薄）"
fi

# ---- 检查 2：五个必需章节标题（逐字精确匹配）----
MISSING=""
for i in 1 2 3 4 5; do
  case $i in
    1) T="拓扑图" ;;
    2) T="子网规划" ;;
    3) T="安全组矩阵" ;;
    4) T="SLB 拓扑" ;;
    5) T="实施与验证" ;;
  esac
  grep -q "^## ${i}\. ${T}" "$DESIGN" || MISSING="${MISSING} ##${i}.${T}"
done
if [ -z "$MISSING" ]; then
  pass "五个必需章节标题齐全（拓扑图/子网规划/安全组矩阵/SLB 拓扑/实施与验证）"
else
  fail "缺少章节或标题不精确：${MISSING}"
fi

# ---- 检查 3：拓扑图是真正的 ASCII 图 ----
DIAG=$(section 1 | grep -c '[-+|]')
if [ "$DIAG" -ge 6 ]; then
  pass "拓扑图章节含 ${DIAG} 行框线（≥6，是 ASCII 图而非纯文字）"
else
  fail "拓扑图框线行仅 ${DIAG}（<6），需要用 + - | 画出三层双 AZ 拓扑"
fi

# ---- 检查 4~7：CIDR 数学（python 解析表格第 4 列）----
# 选一个可用的解释器：优先 python3（Ubuntu 自带），退回 python（Git Bash 等）；
# 用 -c 探测真实可用性，避开 Windows 商店的 python3 假快捷方式
PY=""
for c in python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import ipaddress' >/dev/null 2>&1; then
    PY="$c"
    break
  fi
done
SUB=0
VPC_CIDR="NOT_FOUND"
OVL="SKIP"
OUT="SKIP"
if [ -n "$PY" ]; then
  CIDR_OUT=$("$PY" - "$DESIGN" <<'PYEOF'
import ipaddress
import re
import sys

text = open(sys.argv[1], encoding="utf-8").read()
sec = re.search(r"^## 2\..*?(?=^## |\Z)", text, re.M | re.S)
body = sec.group(0) if sec else ""

vpc = None
raw = []
# 只解析表格行（以 | 开头），CIDR 固定取第 4 列，避免把说明文字里的网段误算进来
for line in body.splitlines():
    if not line.lstrip().startswith("|"):
        continue
    cells = [c.strip() for c in line.strip().strip("|").split("|")]
    if len(cells) < 4:
        continue
    m = re.search(r"\b(?:\d{1,3}\.){3}\d{1,3}/\d{1,2}\b", cells[3])
    if not m:
        continue
    try:
        net = ipaddress.ip_network(m.group(0), strict=False)
    except ValueError:
        continue
    if cells[0].upper().startswith("VPC"):
        vpc = net
    else:
        raw.append(net)

subnets = []
dup = []
for n in raw:
    if n in subnets:
        dup.append(str(n))
    else:
        subnets.append(n)

print("SUBNET_COUNT=%d" % len(subnets))
print("VPC_CIDR=%s" % (vpc if vpc is not None else "NOT_FOUND"))

conflict = ["重复子网:%s" % d for d in dup]
for i in range(len(subnets)):
    for j in range(i + 1, len(subnets)):
        if subnets[i].overlaps(subnets[j]):
            conflict.append("%s<->%s" % (subnets[i], subnets[j]))
print("OVERLAP=%s" % (",".join(conflict) if conflict else "NONE"))

if vpc is None:
    print("OUTSIDE_VPC=VPC_ROW_NOT_FOUND")
else:
    outside = [str(s) for s in subnets
               if s.network_address not in vpc or s.broadcast_address not in vpc]
    print("OUTSIDE_VPC=%s" % (",".join(outside) if outside else "NONE"))
PYEOF
)
  SUB=$(printf '%s\n' "$CIDR_OUT" | awk -F= '$1 == "SUBNET_COUNT" { print $2; exit }')
  VPC_CIDR=$(printf '%s\n' "$CIDR_OUT" | awk -F= '$1 == "VPC_CIDR" { print $2; exit }')
  OVL=$(printf '%s\n' "$CIDR_OUT" | awk -F= '$1 == "OVERLAP" { print $2; exit }')
  OUT=$(printf '%s\n' "$CIDR_OUT" | awk -F= '$1 == "OUTSIDE_VPC" { print $2; exit }')
fi

if [ "${SUB:-0}" -ge 6 ] 2>/dev/null; then
  pass "子网（vSwitch）数量 ${SUB} 个（≥6：三层 × 双 AZ）"
else
  fail "识别到 ${SUB:-0} 个子网（<6；确认子网表每行以 | 开头且 CIDR 在第 4 列）"
fi

if [ -n "${VPC_CIDR:-}" ] && [ "$VPC_CIDR" != "NOT_FOUND" ] && [ "$VPC_CIDR" != "SKIP" ]; then
  pass "找到 VPC 网段行（${VPC_CIDR}）"
else
  fail "未识别到 VPC 网段行（需有以 | VPC 开头、第 4 列为 CIDR 的表格行）"
fi

if [ "$OVL" = "NONE" ]; then
  pass "子网 CIDR 两两无重叠（程序化验证）"
elif [ "$OVL" = "SKIP" ]; then
  fail "CIDR 校验未执行（需要 python3）"
else
  fail "存在重叠子网：${OVL:-未知}"
fi

if [ "$OUT" = "NONE" ]; then
  pass "所有子网都在 VPC 网段内（程序化验证）"
elif [ "$OUT" = "SKIP" ]; then
  fail "CIDR 归属校验未执行（需要 python3）"
else
  fail "有子网超出 VPC 网段或未找到 VPC 行：${OUT:-未知}"
fi

# ---- 检查 8：每个子网行带冲突检查标记 ----
MARKED=$(section 2 | awk '/^\|/ && /无冲突/' | wc -l | tr -d ' ')
if [ "${MARKED:-0}" -ge 6 ]; then
  pass "子网表含 ${MARKED} 行“无冲突”标记（≥6）"
else
  fail "带“无冲突”标记的表格行仅 ${MARKED:-0}（<6；每行末列写明冲突检查结论）"
fi

# ---- 检查 9：安全组规则条数 ----
SGROWS=$(section 3 | grep -c '^| sg-')
if [ "${SGROWS:-0}" -ge 8 ]; then
  pass "安全组矩阵 ${SGROWS} 条规则（≥8）"
else
  fail "安全组规则仅 ${SGROWS:-0} 条（<8；行需以 | sg- 开头，覆盖各层入/出方向）"
fi

# ---- 检查 10：关键端口覆盖（入口 443/80、数据库 3306、运维 22）----
SEC3=$(section 3)
if printf '%s\n' "$SEC3" | grep -Eq '\b(443|80)\b' \
  && printf '%s\n' "$SEC3" | grep -q '3306' \
  && printf '%s\n' "$SEC3" | grep -q '\b22\b'; then
  pass "安全组覆盖关键端口：入口(80/443)、数据库(3306)、运维(22)"
else
  fail "安全组矩阵缺少关键端口（需同时出现 80 或 443、3306、22）"
fi

# ---- 检查 11：SLB 拓扑要素 ----
SEC4=$(section 4)
if printf '%s\n' "$SEC4" | grep -Eq 'SLB|ALB|NLB|CLB' \
  && printf '%s\n' "$SEC4" | grep -q '健康检查' \
  && printf '%s\n' "$SEC4" | grep -q '监听' \
  && printf '%s\n' "$SEC4" | grep -Eq '\b(443|80|8080)\b'; then
  pass "SLB 拓扑写明产品类型、监听端口、健康检查"
else
  fail "SLB 拓扑缺要素（需含产品名 SLB/ALB/NLB/CLB、“监听”与“健康检查”字样和端口）"
fi

# ---- 检查 12：实施步骤数量 ----
STEPS=$(section 5 | grep -cE '^[0-9]+\.')
if [ "${STEPS:-0}" -ge 4 ]; then
  pass "实施与验证含 ${STEPS} 个编号步骤（≥4）"
else
  fail "实施步骤仅 ${STEPS:-0} 个（<4；每行以“数字.”开头）"
fi

echo "----------------------------------------"
echo "SCORE: ${PASSED}/${TOTAL}"
if [ "$PASSED" -eq "$TOTAL" ]; then
  exit 0
fi
exit 1
