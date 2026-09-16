#!/usr/bin/env bash
# Lab 01（postgresql/01-streaming-replication）判分脚本
# 运行环境：装有 Docker 的 Ubuntu 22.04/24.04 VM，且已完成 task.md 的全部任务
# 终态假设：
#   - docker 网络 pg-lab-net 存在，pg-primary(主)/pg-replica(备) 运行中并接入该网络
#   - 备库由 pg_basebackup -R -X stream -C -S lab_slot 生成，当前 streaming
#   - app.events 主备各 6001 行（判分阈值 >=6000）；pgbench_accounts 主备各 100000 行
#   - ~/pg-lab/lag.log 有 >=5 行 "lag_bytes=<整数>" 样本（值域 [0, 256MB)）
#   - ~/pg-lab/catchup.log 至少一行 "catchup ok rows=<n>"（n >= 6000）
# 用法：chmod +x check.sh && ./check.sh
#       可用环境变量覆盖：PG_M / PG_R / LAG_LOG / CATCHUP_LOG
# 说明：只读检查。唯一的"写"是向备库发一条注定失败的 INSERT（恢复模式只读，
#       不产生任何数据变更），用于验证 read-only 语义。
set -u

PG_M="${PG_M:-pg-primary}"
PG_R="${PG_R:-pg-replica}"
LAG_LOG="${LAG_LOG:-$HOME/pg-lab/lag.log}"
CATCHUP_LOG="${CATCHUP_LOG:-$HOME/pg-lab/catchup.log}"
WAL_KEEP_LIMIT=268435456   # 256MB，与 wal_keep_size 对齐，作为 lag_bytes 的合理上界

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# 用法：check "描述" env SQL="..." bash -c '...引用 $SQL...' _ <容器>
# 把 SQL 经环境变量传进 bash -c，避免引号嵌套地狱
check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

q() { # q <容器> <SQL>：容器内经 unix socket 以 postgres 超级用户查询（本地 trust），输出已去空白
  docker exec "$1" psql -U postgres -Atc "$2" 2>/dev/null | tr -d '[:space:]'
}

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker 未安装或不在 PATH"; exit 1; }

echo "== Lab 01（postgresql 流复制）检查开始 =="

# 1/2 两个容器运行中
check "主库容器 $PG_M 运行中" bash -c \
  '[ "$(docker inspect -f "{{.State.Status}}" "$1" 2>/dev/null)" = "running" ]' _ "$PG_M"

check "备库容器 $PG_R 运行中" bash -c \
  '[ "$(docker inspect -f "{{.State.Status}}" "$1" 2>/dev/null)" = "running" ]' _ "$PG_R"

# 3 两容器均接入 pg-lab-net（网络名含连字符，Go 模板必须用 index 取值）
check "两容器均接入 pg-lab-net" bash -c '
  for c in "$1" "$2"; do
    [ -n "$(docker inspect -f "{{(index .NetworkSettings.Networks \"pg-lab-net\").IPAddress}}" "$c" 2>/dev/null)" ] || exit 1
  done' _ "$PG_M" "$PG_R"

# 4 主库不在恢复模式
check "主库 pg_is_in_recovery=f" \
  env C="$PG_M" bash -c '[ "$(docker exec "$C" psql -U postgres -Atc "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d "[:space:]")" = "f" ]'

# 5 备库处于恢复模式且 standby.signal 存在
check "备库 pg_is_in_recovery=t" \
  env C="$PG_R" bash -c '[ "$(docker exec "$C" psql -U postgres -Atc "SELECT pg_is_in_recovery();" 2>/dev/null | tr -d "[:space:]")" = "t" ]'

check "备库存在 standby.signal" \
  env C="$PG_R" bash -c 'docker exec "$C" sh -c "test -f \$PGDATA/standby.signal"'

# 6 主库 pg_stat_replication 有 streaming 行
check "主库 pg_stat_replication 出现 state=streaming" \
  env C="$PG_M" S="SELECT count(*) FROM pg_stat_replication WHERE state = 'streaming';" \
  bash -c '[ "$(docker exec "$C" psql -U postgres -Atc "$S" 2>/dev/null | tr -d "[:space:]")" -ge 1 ]'

# 7 物理复制槽 lab_slot 存在且当前 active
check "物理复制槽 lab_slot 存在且 active" \
  env C="$PG_M" S="SELECT active FROM pg_replication_slots WHERE slot_name = 'lab_slot' AND slot_type = 'physical';" \
  bash -c '[ "$(docker exec "$C" psql -U postgres -Atc "$S" 2>/dev/null | tr -d "[:space:]")" = "t" ]'

# 8 主备 app.events 行数一致且达到 6000
check "主备 app.events 行数一致（>=6000）" \
  env M="$PG_M" R="$PG_R" S="SELECT count(*) FROM app.events;" \
  bash -c '
    A=$(docker exec "$M" psql -U postgres -Atc "$S" 2>/dev/null | tr -d "[:space:]")
    B=$(docker exec "$R" psql -U postgres -Atc "$S" 2>/dev/null | tr -d "[:space:]")
    [ -n "$A" ] && [ "$A" = "$B" ] && [ "$A" -ge 6000 ]'

# 9 主备 pgbench_accounts 各 100000 行
check "主备 pgbench_accounts 各 100000 行" \
  env M="$PG_M" R="$PG_R" S="SELECT count(*) FROM pgbench_accounts;" \
  bash -c '
    for c in "$M" "$R"; do
      [ "$(docker exec "$c" psql -U postgres -Atc "$S" 2>/dev/null | tr -d "[:space:]")" = "100000" ] || exit 1
    done'

# 10 备库只读：INSERT 必须被拒绝且报 read-only（失败写不产生任何数据变更）
# 注意不能过管道取退出码（管道状态是最后一个命令的），直接捕获 psql 输出与 RC
RO_OUT="$(docker exec "$PG_R" psql -U postgres -Atc \
  "INSERT INTO app.events(payload) VALUES ('labcheck-ro');" 2>&1)"
RO_RC=$?
if [ "$RO_RC" -ne 0 ] && printf '%s' "$RO_OUT" | grep -qi 'read-only'; then
  pass "备库只读（INSERT 被拒绝且报 read-only）"
else
  fail "备库只读（INSERT 被拒绝且报 read-only）"
fi

# 11 延迟记录文件：存在、>=5 行有效 lag_bytes 样本、数值在 [0, 256MB) 内
LAG_STATE="missing_or_invalid"
if [ -f "$LAG_LOG" ]; then
  N_LINES=$(grep -cE 'lag_bytes=[0-9]+' "$LAG_LOG" 2>/dev/null || true)
  MAXV=$(grep -oE 'lag_bytes=[0-9]+' "$LAG_LOG" 2>/dev/null | cut -d= -f2 | sort -n | tail -1)
  if [ "${N_LINES:-0}" -ge 5 ] && [ -n "${MAXV:-}" ] && [ "$MAXV" -lt "$WAL_KEEP_LIMIT" ]; then
    LAG_STATE="ok"
  else
    LAG_STATE="bad(lines=${N_LINES:-0} max=${MAXV:-none})"
  fi
fi
if [ "$LAG_STATE" = "ok" ]; then
  pass "lag.log 存在且数值合理（>=5 行，lag_bytes 均在 [0,256MB)）"
else
  fail "lag.log 存在且数值合理（$LAG_STATE）"
fi

# 12 追平记录：catchup ok rows=<n> 且 n >= 6000
CU_ROWS="$(grep -oE 'catchup ok rows=[0-9]+' "$CATCHUP_LOG" 2>/dev/null | cut -d= -f2 | sort -n | tail -1)"
if [ -n "${CU_ROWS:-}" ] && [ "$CU_ROWS" -ge 6000 ]; then
  pass "catchup.log 存在且追平记录有效（rows=$CU_ROWS）"
else
  fail "catchup.log 存在且追平记录有效（got '${CU_ROWS:-none}'）"
fi

echo "== 结果 =="
TOTAL=$((PASS + FAIL))
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
