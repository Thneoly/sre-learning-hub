#!/usr/bin/env bash
# Lab 04 判分脚本 —— Flink SQL 写 Paimon 湖表（full / simulated 双模式自动识别，只读）
# 运行位置：任意装 docker 的 Ubuntu VM（[任意节点]，docker-ce 含 compose 插件）
# full 模式前提：flink-jm / flink-tm 容器 Running，paimon jar 已装入两容器 /opt/flink/lib，
#   sre_lab.host_metrics 已按 task.md 写入 10000 行（主键去重后 40 行）并完成
#   ('host07','cpu') val=999 的主键更新。
#   本脚本仅在 flink-jm 容器 /tmp 下写一个一次性判分 SQL 文件（查询用），不改集群与湖表状态。
# simulated 模式前提：真环境跑不动，已在本脚本所在目录产出三份交付物
#   （docker-compose.yml / lakehouse-pipeline.sql / warehouse-structure.md）。
# 用法：chmod +x check.sh && ./check.sh
set -u

PASS=0
FAIL=0
TOTAL=0

pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $*"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $*"; }

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"

JM=flink-jm
TM=flink-tm
WH=/opt/flink/warehouse
TBL="$WH/sre_lab.db/host_metrics"

# ---------- 模式识别：两个容器 Running => full；否则本目录有交付物 => simulated ----------
MODE="unknown"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$JM" && \
   docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$TM"; then
  MODE="full"
elif [ -f "$SELF_DIR/docker-compose.yml" ] || [ -f "$SELF_DIR/lakehouse-pipeline.sql" ] || [ -f "$SELF_DIR/warehouse-structure.md" ]; then
  MODE="simulated"
fi

if [ "$MODE" = "full" ]; then
  echo "== 模式: full（检测到 flink-jm / flink-tm 均 Running，按真实集群判分） =="
  echo

  # 1/2. 两个容器 Running（模式识别已确认，这里逐项记账）
  if docker ps --format '{{.Names}}' | grep -qx "$JM"; then
    pass "容器 $JM 处于 Running"
  else
    fail "容器 $JM 未运行"
  fi
  if docker ps --format '{{.Names}}' | grep -qx "$TM"; then
    pass "容器 $TM 处于 Running"
  else
    fail "容器 $TM 未运行"
  fi

  # 3. Paimon bundle 已装入 TM（sink 在 TM 上执行，jar 必不可少）
  if docker exec "$TM" ls /opt/flink/lib 2>/dev/null | grep -q 'paimon-flink'; then
    pass "TM 的 /opt/flink/lib 下存在 paimon-flink jar"
  else
    fail "TM 的 /opt/flink/lib 下没有 paimon-flink jar（作业不可能写入成功）"
  fi

  # 4. 湖表目录存在（表格式元数据的物理落点）
  if docker exec "$TM" test -d "$TBL"; then
    pass "warehouse 下存在表目录 $TBL"
  else
    fail "warehouse 下不存在 $TBL（catalog 未建表或 warehouse 挂载路径不对，见 task 提示 1）"
  fi

  # 5. snapshot 目录存在且含 snapshot-N（每次 checkpoint 提交一个）
  SNAP_N="$(docker exec "$TM" sh -c "ls $TBL/snapshot 2>/dev/null | grep -cE '^(snapshot|LATEST)'" 2>/dev/null)"
  if [ "${SNAP_N:-0}" -ge 2 ]; then
    pass "snapshot/ 目录非空（含 snapshot-N 与 LATEST，共 ${SNAP_N} 项）"
  else
    fail "snapshot/ 目录缺失或为空（checkpoint 没开？写作业没跑？见 task 提示 2）"
  fi

  # 6. manifest 目录存在且非空（snapshot 指向 manifest-list，manifest 列数据文件）
  MANI_N="$(docker exec "$TM" sh -c "ls $TBL/manifest 2>/dev/null | grep -c manifest" 2>/dev/null)"
  if [ "${MANI_N:-0}" -ge 1 ]; then
    pass "manifest/ 目录非空（${MANI_N} 个清单文件）"
  else
    fail "manifest/ 目录缺失或为空"
  fi

  # 7/8. 批查询：去重行数 + 主键更新语义（一次 sql-client 调用完成两项）
  docker exec -i "$JM" sh -c "cat > /tmp/paimon-check.sql" <<'SQL'
CREATE CATALOG paimon WITH (
  'type' = 'paimon',
  'warehouse' = 'file:///opt/flink/warehouse'
);
SET 'execution.runtime-mode' = 'batch';
SET 'sql-client.execution.result-mode' = 'TABLEAU';
SELECT COUNT(*) FROM paimon.sre_lab.host_metrics;
SELECT val FROM paimon.sre_lab.host_metrics WHERE host = 'host07' AND metric = 'cpu';
SQL
  OUT="$(docker exec "$JM" /opt/flink/bin/sql-client.sh -f /tmp/paimon-check.sql 2>/dev/null)"
  # TABLEAU 是 -f 非交互模式唯一可用的 result-mode（Flink 1.19 实测），其批量结果行
  # 形如 "|     40 |"，没有 changelog 模式的 +I 前缀，故这里抓所有表格行（含分隔线）
  ROWS="$(printf '%s\n' "$OUT" | grep -E '^[|+]' || true)"

  if printf '%s\n' "$ROWS" | grep -Eq '(^|[^0-9])40([^0-9]|$)'; then
    pass "批查询 COUNT(*) = 40（10000 行按主键 (host, metric) 去重生效）"
  else
    fail "批查询 COUNT(*) 不为 40（查不到结果行：runtime-mode/表/数据有其一不对；输出见下）"
    printf '%s\n' "$OUT" | tail -5
  fi

  if printf '%s\n' "$ROWS" | grep -q '999'; then
    pass "主键更新语义生效：('host07','cpu') 的 val 为 999（LSM 同主键新值覆盖旧值）"
  else
    fail "('host07','cpu') 的 val 不为 999（未执行 update.sql 的同主键写入？）"
  fi

  # 9. snapshot 元数据文件肉眼可读（含 totalRecordCount 等字段）
  # Paimon Snapshot JSON 的字段名是 totalRecordCount / deltaRecordCount /
  # changelogRecordCount（官方 Snapshot 规范与 release-1.0/1.4/2.0 源码一致，
  # 任何 1.x/2.x 版本都不存在 'totalRecords'），三者共有的 "RecordCount" 后缀做稳健匹配
  if docker exec "$TM" sh -c "cat $TBL/snapshot/snapshot-* 2>/dev/null" | grep -Eq '(total|delta|changelog)RecordCount'; then
    pass "snapshot 文件内容含 totalRecordCount 等字段（表格式元数据可 cat 直接阅读）"
  else
    fail "snapshot 文件内容不含 totalRecordCount/deltaRecordCount（版本字段差异请 cat 实看，以官方 Snapshot 规范为准）"
  fi

elif [ "$MODE" = "simulated" ]; then
  echo "== 模式: SIMULATED（未检测到 Running 的 flink-jm/flink-tm，按三份交付物判分） =="
  echo

  # 1. compose：1.19 镜像 + 双服务 + 共享 warehouse
  if [ -f "$SELF_DIR/docker-compose.yml" ]; then
    if grep -Eq 'flink:1.19' "$SELF_DIR/docker-compose.yml"; then
      pass "docker-compose.yml 使用 apache/flink:1.19 镜像"
    else
      fail "docker-compose.yml 未使用 flink:1.19 镜像"
    fi
    if grep -q 'jobmanager' "$SELF_DIR/docker-compose.yml" && grep -q 'taskmanager' "$SELF_DIR/docker-compose.yml"; then
      pass "docker-compose.yml 含 jobmanager 与 taskmanager 两个服务"
    else
      fail "docker-compose.yml 缺 jobmanager 或 taskmanager 服务"
    fi
    if grep -q '/opt/flink/warehouse' "$SELF_DIR/docker-compose.yml" && grep -Eq 'checkpointing.interval' "$SELF_DIR/docker-compose.yml"; then
      pass "docker-compose.yml 含 warehouse 共享挂载与 checkpoint interval"
    else
      fail "docker-compose.yml 缺 warehouse 挂载或 execution.checkpointing.interval"
    fi
  else
    fail "docker-compose.yml 不存在"
    fail "docker-compose.yml 缺 jobmanager 或 taskmanager 服务（文件缺失）"
    fail "docker-compose.yml 缺 warehouse 挂载或 checkpoint interval（文件缺失）"
  fi

  # 2. SQL 脚本：paimon catalog / 主键表 / datagen / 持续写 / 批查询 / 主键更新
  if [ -f "$SELF_DIR/lakehouse-pipeline.sql" ]; then
    if grep -Eq "'type'[[:space:]]*=[[:space:]]*'paimon'" "$SELF_DIR/lakehouse-pipeline.sql"; then
      pass "lakehouse-pipeline.sql 声明 paimon catalog"
    else
      fail "lakehouse-pipeline.sql 缺 paimon catalog 定义"
    fi
    if grep -Eq 'PRIMARY KEY' "$SELF_DIR/lakehouse-pipeline.sql" && grep -Eq 'NOT ENFORCED' "$SELF_DIR/lakehouse-pipeline.sql"; then
      pass "lakehouse-pipeline.sql 的湖表带 PRIMARY KEY ... NOT ENFORCED"
    else
      fail "lakehouse-pipeline.sql 的湖表缺 PRIMARY KEY ... NOT ENFORCED"
    fi
    if grep -q 'datagen' "$SELF_DIR/lakehouse-pipeline.sql" && grep -Eq 'INSERT INTO' "$SELF_DIR/lakehouse-pipeline.sql"; then
      pass "lakehouse-pipeline.sql 含 datagen 源与 INSERT INTO 持续写"
    else
      fail "lakehouse-pipeline.sql 缺 datagen 源或 INSERT INTO"
    fi
    if grep -Eq "execution.runtime-mode" "$SELF_DIR/lakehouse-pipeline.sql" && grep -Eq "'batch'" "$SELF_DIR/lakehouse-pipeline.sql"; then
      pass "lakehouse-pipeline.sql 含 batch 模式的验证查询"
    else
      fail "lakehouse-pipeline.sql 缺 SET execution.runtime-mode = 'batch' 验证查询"
    fi
  else
    fail "lakehouse-pipeline.sql 不存在"
    fail "lakehouse-pipeline.sql 缺 PRIMARY KEY（文件缺失）"
    fail "lakehouse-pipeline.sql 缺 datagen/INSERT（文件缺失）"
    fail "lakehouse-pipeline.sql 缺 batch 验证查询（文件缺失）"
  fi

  # 3. 目录结构说明：三层职责 + 提交机制
  if [ -f "$SELF_DIR/warehouse-structure.md" ]; then
    if grep -Eq 'snapshot' "$SELF_DIR/warehouse-structure.md" && grep -Eq 'manifest' "$SELF_DIR/warehouse-structure.md"; then
      pass "warehouse-structure.md 说明 snapshot 与 manifest 层"
    else
      fail "warehouse-structure.md 缺 snapshot 或 manifest 的说明"
    fi
    if grep -Eq 'bucket' "$SELF_DIR/warehouse-structure.md" && grep -Eq 'checkpoint' "$SELF_DIR/warehouse-structure.md"; then
      pass "warehouse-structure.md 说明 bucket 数据层与 checkpoint 提交机制"
    else
      fail "warehouse-structure.md 缺 bucket 数据层或 checkpoint 提交机制说明"
    fi
  else
    fail "warehouse-structure.md 不存在"
    fail "warehouse-structure.md 缺 bucket/checkpoint 说明（文件缺失）"
  fi
else
  echo "未检测到 Running 的 flink-jm/flink-tm，也未找到 SIMULATED 交付物——请先完成 task.md 的 full 或 simulated 路径"
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
