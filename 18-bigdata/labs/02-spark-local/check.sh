#!/usr/bin/env bash
# Lab 02 判分脚本 —— Spark local 词频统计与倾斜实验产物验证（只读）
# 运行位置：任意装 docker 的 Ubuntu VM（[任意节点]，docker-ce 即可）
# 前提：已按 task.md 完成任务 1~4 —— 容器 spark-lab 正在运行，
#       words.txt（100 万行）与 /opt/spark/work-dir/output/ 下的产物已生成。
#       任务 6（删容器）必须在跑完本脚本之后做。
# 全部检查通过 docker exec 只读命令完成，不启动新作业、不写文件。
# 用法：chmod +x check.sh && ./check.sh
set -u

PASS=0
FAIL=0
TOTAL=0

pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $*"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $*"; }

C=spark-lab
W=/opt/spark/work-dir

# 1. 容器 Running（后续检查全部依赖它，失败则提前收尾）
if docker ps --format '{{.Names}}' | grep -qx "$C"; then
  pass "容器 $C 处于 Running"
else
  fail "容器 $C 未运行（docker ps 看不到；先 docker start $C 或按 solution 重做）"
  echo
  echo "SCORE: $PASS/$TOTAL"
  exit 1
fi

# 2. 输入数据存在且恰好 100 万行
LINES="$(docker exec "$C" wc -l "$W/words.txt" 2>/dev/null | awk '{print $1}')"
if [ "${LINES:-0}" -eq 1000000 ]; then
  pass "words.txt 存在且为 1000000 行"
else
  fail "words.txt 行数为 ${LINES:-<不存在>}，应为 1000000"
fi

# 3. top10 结果文件存在
if docker exec "$C" test -f "$W/output/top10.txt"; then
  pass "output/top10.txt 存在"
else
  fail "output/top10.txt 不存在（spark-submit lab.py 是否成功？）"
fi

# 4. top1 为 hotkey 900000（确定性数据构造下必须精确命中）
TOP1="$(docker exec "$C" head -1 "$W/output/top10.txt" 2>/dev/null | tr -d '\r' | awk '{print $1" "$2}')"
if [ "$TOP1" = "hotkey 900000" ]; then
  pass "top1 为 hotkey 900000"
else
  fail "top1 为 '${TOP1:-<空>}'，应为 'hotkey 900000'"
fi

# 5. 倾斜实验计时文件存在且含两个整数毫秒值
if docker exec "$C" test -f "$W/output/timing.txt"; then
  pass "output/timing.txt 存在"
else
  fail "output/timing.txt 不存在"
fi
if docker exec "$C" grep -Eq '^naive_ms=[0-9]+$' "$W/output/timing.txt" 2>/dev/null; then
  pass "timing.txt 含 naive_ms=<整数>"
else
  fail "timing.txt 缺少 naive_ms=<整数> 行"
fi
if docker exec "$C" grep -Eq '^salted_ms=[0-9]+$' "$W/output/timing.txt" 2>/dev/null; then
  pass "timing.txt 含 salted_ms=<整数>"
else
  fail "timing.txt 缺少 salted_ms=<整数> 行"
fi

# 6. 完整词频结果已落盘（write.csv 成功的标志文件）
if docker exec "$C" test -f "$W/output/wordcount-full/_SUCCESS"; then
  pass "output/wordcount-full/_SUCCESS 存在（完整词频已落盘）"
else
  fail "output/wordcount-full/_SUCCESS 不存在"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
