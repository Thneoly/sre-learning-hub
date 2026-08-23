#!/usr/bin/env bash
# [任意节点] Lab 02 判分脚本
# 运行前提:
#   - Ubuntu 22.04/24.04，python3 (>=3.8) 与 curl 可用，内核有 /proc（Linux 原生）
#   - 9877 端口未被占用（exporter 监听 9877；如被占用请先停掉占用进程）
#   - prometheus_client 缺失时会尝试 pip3 install --user prometheus_client
#     （Ubuntu 24.04 的 pip 受 PEP 668 限制时自动追加 --break-system-packages，仍失败则判 FAIL）
# 说明: 只在本机启动/停止学习者的 ops_exporter.py 并检查 /metrics 输出，不改集群
# 用法: chmod +x check.sh && ./check.sh   （或 bash check.sh）
set -u

LAB_DIR=$(cd "$(dirname "$0")" && pwd)
EXPORTER="$LAB_DIR/ops_exporter.py"
PORT=9877
BASE="http://127.0.0.1:$PORT/metrics"
TMP=$(mktemp -d)
EXPORTER_PID=""

cleanup() {
  if [ -n "$EXPORTER_PID" ]; then
    kill "$EXPORTER_PID" 2>/dev/null
    wait "$EXPORTER_PID" 2>/dev/null
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

PASS=0
FAILN=0
TOTAL=0
pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
fail() { TOTAL=$((TOTAL+1)); FAILN=$((FAILN+1)); printf 'FAIL: %s\n' "$1"; }

METRICS="host_cpu_load1 host_mem_available_bytes host_disk_free_bytes app_requests_total app_queue_depth app_request_duration_seconds"

# T1: 脚本存在
if [ -f "$EXPORTER" ]; then
  pass "ops_exporter.py 存在于 lab 目录"
else
  fail "ops_exporter.py 不存在于 lab 目录"
fi

# T2: python3 与 prometheus_client 可用（必要时自动安装）
if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 不可用"
elif python3 -c "import prometheus_client" 2>/dev/null; then
  pass "python3 与 prometheus_client 可用"
else
  echo "INFO: prometheus_client 缺失，尝试安装"
  if pip3 install --user --quiet prometheus_client 2>/dev/null \
     || pip3 install --user --break-system-packages --quiet prometheus_client 2>/dev/null; then :; fi
  if python3 -c "import prometheus_client" 2>/dev/null; then
    pass "python3 与 prometheus_client 可用（已自动安装）"
  else
    fail "prometheus_client 不可用（手动执行: pip3 install --user prometheus_client）"
  fi
fi

# T3: 静态检查 6 个指标名都已定义
if [ -f "$EXPORTER" ]; then
  missing=""
  for m in $METRICS; do
    grep -q -- "$m" "$EXPORTER" 2>/dev/null || missing="$missing $m"
  done
  if [ -z "$missing" ]; then
    pass "脚本中定义了全部 6 个要求的指标名"
  else
    fail "脚本缺少指标定义:$missing"
  fi
else
  fail "跳过静态指标检查（ops_exporter.py 不存在）"
fi

# T4: 启动 exporter 并等待 /metrics 就绪
UP=0
if [ -f "$EXPORTER" ]; then
  ( cd "$LAB_DIR" && python3 "$EXPORTER" ) >"$TMP/exporter.log" 2>&1 &
  EXPORTER_PID=$!
  for _ in $(seq 1 20); do
    if curl -sf "$BASE" -o "$TMP/m1.txt" 2>/dev/null; then
      UP=1
      break
    fi
    kill -0 "$EXPORTER_PID" 2>/dev/null || break
    sleep 0.5
  done
fi
if [ "$UP" = 1 ]; then
  pass "exporter 启动成功且 $BASE 返回 HTTP 200"
else
  fail "exporter 未能在 10 秒内在 $PORT 提供 /metrics（日志: $(tail -n1 "$TMP/exporter.log" 2>/dev/null)）"
fi

# T5: /metrics 输出包含全部 6 个指标名
if [ "$UP" = 1 ]; then
  missing=""
  for m in $METRICS; do
    grep -qE "^$m" "$TMP/m1.txt" || missing="$missing $m"
  done
  if [ -z "$missing" ]; then
    pass "/metrics 输出包含全部 6 个要求的指标名"
  else
    fail "/metrics 缺少指标:$missing"
  fi
else
  fail "跳过指标输出检查（exporter 未启动）"
fi

# T6: exposition 格式（Content-Type + HELP/TYPE 元信息）
if [ "$UP" = 1 ]; then
  # 注意: prometheus_client 的 /metrics 只接受 GET(HEAD 返回 405), 用 GET + -D 抓响应头
  ctype=$(curl -s -D - -o /dev/null "$BASE" | tr -d '\r' | awk 'tolower($1)=="content-type:"{print $0}')
  if echo "$ctype" | grep -qi "text/plain" \
     && grep -q "^# HELP " "$TMP/m1.txt" \
     && grep -q "^# TYPE " "$TMP/m1.txt"; then
    pass "exposition 格式正确（Content-Type: text/plain，含 # HELP 与 # TYPE 行）"
  else
    fail "exposition 格式不符（Content-Type=$ctype，或缺少 # HELP / # TYPE 元信息行）"
  fi
else
  fail "跳过格式检查（exporter 未启动）"
fi

# T7: 间隔 2 秒两次抓取，app_requests_total 之和严格递增
if [ "$UP" = 1 ]; then
  first=$(awk '$1 ~ /^app_requests_total/ {s+=$NF} END{printf "%d", s+0}' "$TMP/m1.txt")
  sleep 2
  if curl -sf "$BASE" -o "$TMP/m2.txt" 2>/dev/null; then
    second=$(awk '$1 ~ /^app_requests_total/ {s+=$NF} END{printf "%d", s+0}' "$TMP/m2.txt")
    if awk -v a="$first" -v b="$second" 'BEGIN{exit !(b>a)}'; then
      pass "app_requests_total 随时间递增（$first -> $second）"
    else
      fail "app_requests_total 未递增（$first -> $second），模拟流量线程可能没在跑"
    fi
  else
    fail "第二次抓取 /metrics 失败"
  fi
else
  fail "跳过递增检查（exporter 未启动）"
fi

echo "----------------------------------------"
echo "SCORE: $PASS/$TOTAL"
[ "$PASS" -eq "$TOTAL" ] && exit 0
exit 1
