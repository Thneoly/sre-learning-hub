#!/usr/bin/env bash
# Lab 03 判分脚本 —— Doris quickstart（full / simulated 双模式自动识别，只读）
# 运行位置：任意装 docker 的 Ubuntu VM（[任意节点]，docker-ce 含 compose 插件）
# full 模式前提：doris-fe / doris-be 容器 Running，sre_lab.events 已建表、
#   已按 task.md 完成两次导入（10000 行 + 新 label 重放同一文件）。
# simulated 模式前提：真环境跑不动，已在本脚本所在目录产出三份交付物
#   （doris-schema.sql / stream-load.sh / import-plan.md）。
# 全部检查只读：docker ps / docker exec mysql SELECT / 文件 grep，不导入、不建表。
# 用法：chmod +x check.sh && ./check.sh
set -u

PASS=0
FAIL=0
TOTAL=0

pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $*"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $*"; }

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- 模式识别：容器 Running => full；否则本目录有交付物 => simulated ----------
MODE="unknown"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx 'doris-fe'; then
  MODE="full"
elif [ -f "$SELF_DIR/doris-schema.sql" ] || [ -f "$SELF_DIR/stream-load.sh" ] || [ -f "$SELF_DIR/import-plan.md" ]; then
  MODE="simulated"
fi

if [ "$MODE" = "full" ]; then
  echo "== 模式: full（检测到 doris-fe 容器 Running，按真实集群判分） =="
  echo

  # 1/2. 两个容器 Running
  if docker ps --format '{{.Names}}' | grep -qx 'doris-fe'; then
    pass "容器 doris-fe 处于 Running"
  else
    fail "容器 doris-fe 未运行"
  fi
  if docker ps --format '{{.Names}}' | grep -qx 'doris-be'; then
    pass "容器 doris-be 处于 Running"
  else
    fail "容器 doris-be 未运行"
  fi

  # SQL 执行通道：优先 fe 容器内 mysql 客户端，回退宿主机 mysql（都不通则逐项 FAIL）
  SQL_OK=0
  if docker exec doris-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SELECT 1' >/dev/null 2>&1; then
    SQL_OK=1
    sql() { docker exec doris-fe mysql -h127.0.0.1 -P9030 -uroot -N -e "$1" 2>/dev/null; }
  elif command -v mysql >/dev/null 2>&1 && mysql -h127.0.0.1 -P9030 -uroot -e 'SELECT 1' >/dev/null 2>&1; then
    SQL_OK=1
    sql() { mysql -h127.0.0.1 -P9030 -uroot -N -e "$1" 2>/dev/null; }
  fi

  # 3. BE 已注册且 Alive
  # 注意：不能复用 sql()——它带 -N（去列名），会把 \G 竖排输出的字段名一起剥掉，
  # 剩下裸值导致 "Alive:" 永远匹配不到。这里必须用保留列名的原始调用。
  if [ "$SQL_OK" -eq 1 ]; then
    if docker exec doris-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SHOW BACKENDS\G' 2>/dev/null | grep -Eq 'Alive:[[:space:]]*(1|true|Yes)'; then
      pass "SHOW BACKENDS 中 BE 的 Alive 为真（已注册且存活）"
    else
      fail "SHOW BACKENDS 中看不到 Alive 的 BE（BE_ADDR/注册问题，见 task 提示 2）"
    fi

    # 4. 重放后总行数仍为 10000（Duplicate 模型会变成 20000）
    CNT="$(sql 'SELECT COUNT(*) FROM sre_lab.events')"
    if [ "${CNT:-x}" = "10000" ]; then
      pass "重放后 COUNT(*) 仍为 10000（Unique 模型幂等生效）"
    else
      fail "COUNT(*) 为 '${CNT:-<查询失败>}'，应为 10000（重放重复入库？表模型不对？）"
    fi

    # 5. 聚合正确性：SUM(value) 精确等于预计算值
    SUM="$(sql 'SELECT ROUND(SUM(value),2) FROM sre_lab.events')"
    if echo "${SUM:-}" | grep -q '7492500'; then
      pass "SUM(value) 为 7492500.0（与造数公式一致）"
    else
      fail "SUM(value) 为 '${SUM:-<查询失败>}'，应为 7492500.0"
    fi

    # 6. 维度核对：host07 恰好 500 行
    H07="$(sql "SELECT COUNT(*) FROM sre_lab.events WHERE host='host07'")"
    if [ "${H07:-x}" = "500" ]; then
      pass "host07 行数为 500"
    else
      fail "host07 行数为 '${H07:-<查询失败>}'，应为 500"
    fi

    # 7. 表确为 Unique 模型（SHOW CREATE TABLE 实际输出形如 UNIQUE KEY(`event_day`, ...)）
    if sql 'SHOW CREATE TABLE sre_lab.events' | grep -Eq 'UNIQUE[[:space:]]+KEY'; then
      pass "events 表为 UNIQUE KEY 模型"
    else
      fail "events 表不是 UNIQUE KEY 模型（SHOW CREATE TABLE 核对）"
    fi
  else
    fail "无法连接 FE 的 MySQL 协议端口（fe 容器与宿主机均无可用 mysql 客户端，apt install mysql-client 后重试）"
    fail "跳过：BE Alive 检查（依赖 SQL 通道）"
    fail "跳过：COUNT(*)=10000 检查（依赖 SQL 通道）"
    fail "跳过：SUM(value)=7492500 检查（依赖 SQL 通道）"
    fail "跳过：host07=500 检查（依赖 SQL 通道）"
    fail "跳过：UNIQUE KEY 模型检查（依赖 SQL 通道）"
  fi

elif [ "$MODE" = "simulated" ]; then
  echo "== 模式: SIMULATED（未检测到 Running 的 doris-fe，按三份交付物判分） =="
  echo

  # 1. 建表 SQL：Unique 模型 + 分桶 + 副本数三要素
  if [ -f "$SELF_DIR/doris-schema.sql" ]; then
    if grep -Eq 'UNIQUE[[:space:]]+KEY' "$SELF_DIR/doris-schema.sql"; then
      pass "doris-schema.sql 存在且声明 UNIQUE KEY"
    else
      fail "doris-schema.sql 存在但缺 UNIQUE KEY 声明"
    fi
    if grep -Eq 'BUCKETS' "$SELF_DIR/doris-schema.sql" && grep -Eq 'replication_num' "$SELF_DIR/doris-schema.sql"; then
      pass "doris-schema.sql 含 BUCKETS 与 replication_num"
    else
      fail "doris-schema.sql 缺 BUCKETS 或 replication_num"
    fi
  else
    fail "doris-schema.sql 不存在"
    fail "doris-schema.sql 缺 BUCKETS 或 replication_num（文件缺失）"
  fi

  # 2. 导入脚本：Stream Load 端点与 label 变量化
  if [ -f "$SELF_DIR/stream-load.sh" ]; then
    if grep -q '_stream_load' "$SELF_DIR/stream-load.sh" && grep -Eq 'label' "$SELF_DIR/stream-load.sh"; then
      pass "stream-load.sh 存在且含 _stream_load 端点与 label"
    else
      fail "stream-load.sh 存在但缺 _stream_load 端点或 label 参数化"
    fi
  else
    fail "stream-load.sh 不存在"
  fi

  # 3. 导入计划：label 规则 + 失败重试两个关键小节
  if [ -f "$SELF_DIR/import-plan.md" ]; then
    if grep -Eq 'label' "$SELF_DIR/import-plan.md" && grep -Eq '重试|retry' "$SELF_DIR/import-plan.md"; then
      pass "import-plan.md 存在且含 label 规则与失败重试"
    else
      fail "import-plan.md 存在但缺 label 规则或失败重试小节"
    fi
  else
    fail "import-plan.md 不存在"
  fi
else
  echo "未检测到 Running 的 doris-fe，也未找到 SIMULATED 交付物——请先完成 task.md 的 full 或 simulated 路径"
  echo
  fail "full 或 simulated 任一路径均未完成"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
