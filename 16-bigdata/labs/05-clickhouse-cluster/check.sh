#!/usr/bin/env bash
# Lab 05 判分脚本 —— ClickHouse 双分片 + ZooKeeper（只读判分）
# 运行位置：任意装 docker 的 Ubuntu VM（[任意节点]，docker-ce 含 compose 插件）
# 前提：ch1 / ch2 / zookeeper 三容器 Running，已按 task.md 完成建表（含 MV）、
#   10 批共 100000 行写入、parts 观察记录（parts-observation.txt 放在 check.sh 所在
#   目录、~/ch-lab/ 或运行 check.sh 的当前目录任一处）。
# 全部检查只读：docker ps / docker exec clickhouse-client 的 SELECT 与 SHOW、
#   文本 grep——不写入、不建表、不 OPTIMIZE、不停起容器。
# 用法：chmod +x check.sh && ./check.sh
set -u

PASS=0
FAIL=0
TOTAL=0

pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $*"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $*"; }

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# 即时查询（不重试）。timeout 兜底：ZK 不可达时 system.zookeeper 可能挂到默认超时
chq_now() { timeout 15 docker exec "$1" clickhouse-client --query "$2" 2>/dev/null; }

# 带重试查询：分布式异步落库、容器刚 restart 时给数据/会话留时间
chq_try() {
  local i out
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    out="$(chq_now "$1" "$2")" && [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    sleep 2
  done
  return 1
}

running() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

# ---------- 1~3. 三容器 Running ----------
for c in ch1 ch2 zookeeper; do
  if running "$c"; then
    pass "容器 $c 处于 Running"
  else
    fail "容器 $c 未运行（cd ~/ch-lab && docker compose up -d）"
  fi
done

# ---------- SQL 通道 ----------
SQL_OK=0
if [ "$(chq_now ch1 'SELECT 1')" = "1" ]; then
  SQL_OK=1
fi

if [ "$SQL_OK" -eq 1 ]; then
  # 4. 分布式表总量（异步写入给重试窗口）
  CNT="$(chq_try ch1 'SELECT count() FROM sre_lab.metrics_all' | tr -d '\r')"
  if [ "${CNT:-x}" = "100000" ]; then
    pass "分布式表 metrics_all count() = 100000"
  else
    fail "metrics_all count() = '${CNT:-<查询失败>}'，应为 100000（批次没跑完/异步未到齐）"
  fi

  # 5. 两分片都有数据（各自数字不固定——sipHash 分片）
  N1="$(chq_try ch1 'SELECT count() FROM sre_lab.metrics_local' | tr -d '\r')"
  N2="$(chq_try ch2 'SELECT count() FROM sre_lab.metrics_local' | tr -d '\r')"
  if [ -n "${N1:-}" ] && [ -n "${N2:-}" ] && [ "$N1" -gt 0 ] 2>/dev/null && [ "$N2" -gt 0 ] 2>/dev/null; then
    pass "两个分片都有数据（ch1=$N1，ch2=$N2）"
  else
    fail "分片分布异常（ch1='${N1:-?}' ch2='${N2:-?}'，均应 > 0）"
  fi

  # 6. 两节点本地 count 之和 = 总量
  SUMLOC=$(( ${N1:-0} + ${N2:-0} ))
  if [ "$SUMLOC" -eq 100000 ] 2>/dev/null; then
    pass "两节点本地 count 之和 = 100000（$N1 + $N2）"
  else
    fail "两节点本地 count 之和 = $SUMLOC，应为 100000"
  fi

  # 7. 数值正确性（造数公式 val = n % 100 的全量和）
  VSUM="$(chq_try ch1 'SELECT toUInt64(sum(val)) FROM sre_lab.metrics_all' | tr -d '\r')"
  if [ "${VSUM:-x}" = "4950000" ]; then
    pass "SUM(val) = 4950000（与造数公式一致）"
  else
    fail "SUM(val) = '${VSUM:-<查询失败>}'，应为 4950000"
  fi

  # 8. 双表架构：本地表 Replicated、外表 Distributed
  if chq_now ch1 'SHOW CREATE TABLE sre_lab.metrics_local' | grep -q 'ReplicatedMergeTree'; then
    pass "metrics_local 为 ReplicatedMergeTree（ZK 副本协调的本地表）"
  else
    fail "metrics_local 不是 ReplicatedMergeTree（SHOW CREATE TABLE 核对 zk_path/宏）"
  fi
  if chq_now ch1 'SHOW CREATE TABLE sre_lab.metrics_all' | grep -q 'Distributed'; then
    pass "metrics_all 为 Distributed 分布式表"
  else
    fail "metrics_all 不是 Distributed 引擎"
  fi

  # 9. ZK 协调在位 + 副本未降级只读
  ZKC="$(chq_now ch1 "SELECT count() FROM system.zookeeper WHERE path = '/'" | tr -d '\r')"
  if [ -n "${ZKC:-}" ] && [ "$ZKC" -ge 1 ] 2>/dev/null; then
    pass "system.zookeeper 可查（ZK 协调通道在位，根下 ${ZKC} 个 znode）"
  else
    fail "system.zookeeper 不可查（ZK 地址/连通问题，见 task 提示 2）"
  fi
  RO="$(chq_now ch1 'SELECT count() FROM system.replicas WHERE is_readonly = 1' | tr -d '\r')"
  if [ "${RO:-x}" = "0" ]; then
    pass "system.replicas 无 is_readonly 副本（副本表健康）"
  else
    fail "存在 is_readonly=1 的副本表（ZK 会话断连未恢复？）"
  fi

  # 10~11. 物化视图结果
  MVC="$(chq_try ch1 'SELECT sum(cnt) FROM sre_lab.host_agg_all' | tr -d '\r')"
  if [ "${MVC:-x}" = "100000" ]; then
    pass "物化视图聚合总量 sum(cnt) = 100000"
  else
    fail "host_agg_all sum(cnt) = '${MVC:-<查询失败>}'，应为 100000（MV 建晚了？见 task 提示 4）"
  fi
  H07C="$(chq_try ch1 "SELECT sum(cnt) FROM sre_lab.host_agg_all WHERE host = 'host07'" | tr -d '\r')"
  H07V="$(chq_try ch1 "SELECT toUInt64(sum(vsum)) FROM sre_lab.host_agg_all WHERE host = 'host07'" | tr -d '\r')"
  if [ "${H07C:-x}" = "5000" ] && [ "${H07V:-x}" = "235000" ]; then
    pass "host07 聚合正确（cnt=5000，vsum=235000）"
  else
    fail "host07 cnt='${H07C:-?}' vsum='${H07V:-?}'，应为 5000 / 235000"
  fi
else
  fail "无法连接 ch1 的 clickhouse-client（容器没起/镜像没拉到）"
  fail "跳过：metrics_all count=100000 检查（依赖 SQL 通道）"
  fail "跳过：两分片分布检查（依赖 SQL 通道）"
  fail "跳过：本地 count 之和检查（依赖 SQL 通道）"
  fail "跳过：SUM(val)=4950000 检查（依赖 SQL 通道）"
  fail "跳过：ReplicatedMergeTree 引擎检查（依赖 SQL 通道）"
  fail "跳过：Distributed 引擎检查（依赖 SQL 通道）"
  fail "跳过：system.zookeeper 检查（依赖 SQL 通道）"
  fail "跳过：is_readonly 检查（依赖 SQL 通道）"
  fail "跳过：物化视图总量检查（依赖 SQL 通道）"
  fail "跳过：host07 聚合检查（依赖 SQL 通道）"
fi

# ---------- 12. parts 观察记录（写入后 parts 数变化落盘） ----------
OBS=""
for d in "$SELF_DIR" "$HOME/ch-lab" "$PWD"; do
  if [ -f "$d/parts-observation.txt" ]; then OBS="$d/parts-observation.txt"; break; fi
done
if [ -n "$OBS" ]; then
  if grep -Eq '^ch1[[:space:]]+parts_before=[0-9]+[[:space:]]+parts_after=[0-9]+' "$OBS" && \
     grep -Eq '^ch2[[:space:]]+parts_before=[0-9]+[[:space:]]+parts_after=[0-9]+' "$OBS"; then
    pass "parts 观察记录存在且格式正确（$OBS）"
  else
    fail "parts-observation.txt 存在但缺 ch1/ch2 的 'parts_before=N parts_after=M' 行（$OBS）"
  fi
else
  fail "未找到 parts-observation.txt（搜索了 check.sh 目录、~/ch-lab、当前目录）"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
