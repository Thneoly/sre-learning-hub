#!/usr/bin/env bash
# [任意节点] Lab 03 判分脚本
# 运行前提:
#   - Ubuntu 22.04/24.04, docker 可用, redis 容器 celery-redis 仍在运行
#   - 实验产物都在本脚本所在目录: tasks.py, results/, acks/,
#     backlog-peak.txt, backlog-drained.txt, dup-task-id.txt
# 说明: 只读检查(docker ps / redis-cli LLEN / 文件内容), 不启动/停止任何服务,
#       不写入 Redis, 不修改实验数据
# 用法: cd 到本目录 && bash check.sh
set -u

LAB_DIR=$(cd "$(dirname "$0")" && pwd)
RESULTS="$LAB_DIR/results"
ACKS="$LAB_DIR/acks"

PASS=0
FAILN=0
TOTAL=0
pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
fail() { TOTAL=$((TOTAL+1)); FAILN=$((FAILN+1)); printf 'FAIL: %s\n' "$1"; }

# T1: redis 容器 Running
if docker ps --filter name=celery-redis --filter status=running --format '{{.Names}}' 2>/dev/null \
   | grep -q '^celery-redis$'; then
  pass "redis 容器 celery-redis 处于 Running"
else
  fail "redis 容器 celery-redis 未在运行 (docker start celery-redis 后重试)"
fi

# T2: broker 可达 (PING), 顺便确认队列已清空
pong=$(docker exec celery-redis redis-cli PING 2>/dev/null | tr -d '[:space:]')
llen=$(docker exec celery-redis redis-cli -n 1 LLEN celery 2>/dev/null | tr -d '[:space:]')
if [ "$pong" = "PONG" ]; then
  pass "broker 可达: redis-cli PING -> PONG (当前 LLEN celery=${llen:-?})"
else
  fail "broker 不可达: PING 未返回 PONG"
fi

# T3: tasks.py 定义了四类任务 + 关键配置
T="$LAB_DIR/tasks.py"
if [ -f "$T" ]; then
  missing=""
  for token in fast_task flaky_task slow_task fragile_task acks_late=True visibility_timeout; do
    grep -q -- "$token" "$T" || missing="$missing $token"
  done
  if [ -z "$missing" ]; then
    pass "tasks.py 定义了快/失败重试/长/acks_late 四类任务及 visibility_timeout"
  else
    fail "tasks.py 缺少:$missing"
  fi
else
  fail "tasks.py 不存在于 lab 目录"
fi

# T4: 结果文件 >= 6 个, 且 flaky 结果记录了重试
if [ -d "$RESULTS" ]; then
  n=$(find "$RESULTS" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)
  if [ "$n" -ge 6 ]; then
    pass "results/ 下有 $n 个结果文件 (>= 6)"
  else
    fail "results/ 下结果文件仅 $n 个 (< 6)"
  fi
  # flaky 的 retries >= 1: JSON 里形如 "retries": 1
  if grep -rEq '"retries":[[:space:]]*[1-9]' "$RESULTS"/flaky-*.json 2>/dev/null; then
    pass "flaky 任务结果记录了 retries >= 1 (重试链路生效)"
  else
    fail "未找到 retries >= 1 的 flaky 结果 (重试未发生或字段缺失)"
  fi
else
  fail "results/ 目录不存在"
fi

# T5: 积压峰值记录, 数值 >= 100
if [ -f "$LAB_DIR/backlog-peak.txt" ]; then
  peak=$(tr -cd '0-9' < "$LAB_DIR/backlog-peak.txt" | head -c 12)
  if [ -n "$peak" ] && [ "$peak" -ge 100 ] 2>/dev/null; then
    pass "积压峰值已记录: LLEN 峰值 = $peak (>= 100)"
  else
    fail "backlog-peak.txt 内容不是 >= 100 的数值 (读到: '$peak')"
  fi
else
  fail "backlog-peak.txt 不存在 (backlog_recorder.sh 未记录峰值)"
fi

# T6: 消化后清零记录 (含时间戳与数值 0)
if [ -f "$LAB_DIR/backlog-drained.txt" ]; then
  if grep -Eq '(^|[^0-9])0([^0-9]|$)' "$LAB_DIR/backlog-drained.txt"; then
    pass "消化清零已记录: $(head -c 80 "$LAB_DIR/backlog-drained.txt")"
  else
    fail "backlog-drained.txt 未包含归零数值 0"
  fi
else
  fail "backlog-drained.txt 不存在 (未观察到 LLEN 归零)"
fi

# T7: 重复执行证据 —— 同一 task_id 的 attempt1/attempt2 两个文件
if [ -f "$LAB_DIR/dup-task-id.txt" ] && [ -d "$ACKS" ]; then
  tid=$(grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
        "$LAB_DIR/dup-task-id.txt" | head -1)
  if [ -n "$tid" ]; then
    a1="$ACKS/$tid.attempt1.txt"
    a2="$ACKS/$tid.attempt2.txt"
    if [ -f "$a1" ] && [ -f "$a2" ]; then
      pass "重复执行证据成立: task_id=$tid 存在 attempt1/attempt2 两份文件"
    elif [ "$(find "$ACKS" -maxdepth 1 -name "$tid.attempt*" | wc -l)" -ge 2 ]; then
      pass "重复执行证据成立: task_id=$tid 存在两份 attempt 文件"
    else
      cnt=$(find "$ACKS" -maxdepth 1 -name "$tid.attempt*" 2>/dev/null | wc -l)
      fail "acks/ 下 task_id=$tid 的 attempt 文件只有 $cnt 份 (< 2, 重投未发生或证据未落盘)"
    fi
  else
    fail "dup-task-id.txt 里未找到合法 task_id (uuid)"
  fi
else
  fail "dup-task-id.txt 或 acks/ 目录不存在"
fi

echo "----------------------------------------"
echo "SCORE: $PASS/$TOTAL"
[ "$PASS" -eq "$TOTAL" ] && exit 0
exit 1
