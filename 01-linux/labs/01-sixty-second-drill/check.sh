#!/usr/bin/env bash
# Lab 01 判分脚本 —— CPU / 内存 / 磁盘 60 秒演练
# 用法: bash check.sh [answers.txt 路径]    默认 ./answers.txt
# 建议: chmod +x check.sh && ./check.sh
# 说明: 只读检查(读 answers.txt、pgrep/df 查询),不修改系统状态,可独立拷贝运行。
# 环境假设:已在本机(Ubuntu 22.04/24.04)完成三个场景的演练并已还原现场。
set -u

ANS=${1:-./answers.txt}
PASS=0
TOTAL=0

pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; return 0; }
fail() { TOTAL=$((TOTAL+1)); echo "FAIL: $1"; return 0; }

# answers.txt 内关键字检查(文件不存在时恒为假,不报错中断)
has() { [ -f "$ANS" ] && grep -qiE -- "$1" "$ANS"; }

# ---- 1. answers.txt 存在且三个场景标题齐全 ----
if [ -f "$ANS" ] && grep -q '场景 1' "$ANS" && grep -q '场景 2' "$ANS" && grep -q '场景 3' "$ANS"; then
  pass "answers.txt 存在且包含场景 1/2/3"
else
  fail "answers.txt 存在且包含场景 1/2/3"
fi

# ---- 2. 场景 1:定位到 stress / stress-ng ----
if has 'stress'; then
  pass "场景 1 根因指向 stress/stress-ng"
else
  fail "场景 1 根因指向 stress/stress-ng"
fi

# ---- 3. 场景 1:记录了至少两种排查工具 ----
tools=0
for t in 'top' 'htop' 'pidstat' 'mpstat' 'ps '; do
  if has "$t"; then tools=$((tools+1)); fi
done
if [ "$tools" -ge 2 ]; then
  pass "场景 1 记录了 >=2 种排查工具"
else
  fail "场景 1 记录了 >=2 种排查工具"
fi

# ---- 4. 场景 2:定位到 python 泄漏进程 ----
if has 'python'; then
  pass "场景 2 根因指向 python 泄漏进程"
else
  fail "场景 2 根因指向 python 泄漏进程"
fi

# ---- 5. 场景 2:记录了 RSS/内存数值作为依据 ----
if has '(rss|vmrss|内存).{0,24}[0-9]{2,}'; then
  pass "场景 2 记录了内存占用数值"
else
  fail "场景 2 记录了内存占用数值"
fi

# ---- 6. 场景 3:定位到 /var/log 下的大文件 ----
if has '(diag-big|/var/log)'; then
  pass "场景 3 根因指向 /var/log 大文件"
else
  fail "场景 3 根因指向 /var/log 大文件"
fi

# ---- 7. 三个场景的还原命令均已记录(kill 与 rm) ----
if has 'kill' && has 'rm '; then
  pass "还原命令已记录(kill + rm)"
else
  fail "还原命令已记录(kill + rm)"
fi

# ---- 8. 清理:stress/stress-ng 进程已退出(只读 pgrep 检查) ----
if [ -z "$(pgrep -x stress-ng 2>/dev/null)" ] && [ -z "$(pgrep -x stress 2>/dev/null)" ]; then
  pass "现场已清理:无 stress/stress-ng 进程"
else
  fail "现场已清理:无 stress/stress-ng 进程"
fi

# ---- 9. 清理:memleak.py 泄漏进程已退出 ----
if [ -z "$(pgrep -f 'memleak\.py' 2>/dev/null)" ]; then
  pass "现场已清理:无 memleak.py 进程"
else
  fail "现场已清理:无 memleak.py 进程"
fi

# ---- 10. 清理:大文件已删除且 / 使用率 < 90% ----
usage=$(df --output=pcent / 2>/dev/null | awk 'NR==2{gsub(/%/,"");print $1}')
if [ ! -e /var/log/diag-big.bin ] && [ "${usage:-100}" -lt 90 ]; then
  pass "现场已清理:/var/log/diag-big.bin 已删,/ 使用率 ${usage:-?}% < 90%"
else
  fail "现场未清理:/var/log/diag-big.bin 存在,或 / 使用率 ${usage:-?}% >= 90%"
fi

echo "SCORE: $PASS/$TOTAL"
if [ "$PASS" -eq "$TOTAL" ]; then
  exit 0
else
  exit 1
fi
