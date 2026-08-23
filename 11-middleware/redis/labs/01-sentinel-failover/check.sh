#!/usr/bin/env bash
# Lab 01（redis/01-sentinel-failover）判分脚本
# 运行环境：装有 Docker 的 Ubuntu 22.04/24.04 VM，且已完成 task.md 的全部任务
# 终态假设：
#   - docker 网络 redis-ha-net（172.28.0.0/24）存在
#   - redis-master(172.28.0.11)/redis-replica1(.12)/redis-replica2(.13) 运行中；
#     当前 master 是两个 replica 之一；redis-master 已重启并以从库身份在线
#   - sentinel1/2/3 运行中，监控 mymaster（quorum 2），状态正常
#   - session:1 ~ session:100 已写入（值为 v1 ~ v100）
#   - redis-mem：maxmemory 16777216、allkeys-lru、已发生淘汰
#   - redis-mem2：maxmemory 8388608、noeviction、内存已打满
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查；唯一写操作是向当前 master 写入并随即删除一个 labcheck: 键，用于验证可写
set -u

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

command -v docker >/dev/null 2>&1 || { echo "ERROR: docker 未安装或不在 PATH"; exit 1; }

# ---- 定位当前 master 容器：哨兵报告的 IP 对应哪个 redis 容器 ----
S1_IP=$(docker exec sentinel1 redis-cli -p 26379 --raw SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
S2_IP=$(docker exec sentinel2 redis-cli -p 26379 --raw SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)
S3_IP=$(docker exec sentinel3 redis-cli -p 26379 --raw SENTINEL get-master-addr-by-name mymaster 2>/dev/null | head -1)

MASTER_C=""
for c in redis-master redis-replica1 redis-replica2; do
  # 注意：网络名 redis-ha-net 含连字符，Go 模板里不能写成 .NetworkSettings.redis-ha-net.IPAddress，
  # 必须用 index 取值再取字段，否则恒报 "bad character U+002D" 导致 MASTER_C 解析失败
  ip=$(docker inspect -f '{{(index .NetworkSettings.Networks "redis-ha-net").IPAddress}}' "$c" 2>/dev/null)
  [ "$ip" = "$S1_IP" ] && MASTER_C="$c"
done

# 1. 三个哨兵容器运行中
check "sentinel1/2/3 均在运行" bash -c '
  for c in sentinel1 sentinel2 sentinel3; do
    [ "$(docker inspect -f "{{.State.Running}}" "$c" 2>/dev/null)" = "true" ] || exit 1
  done'

# 2. 三个 redis 容器运行中
check "redis-master/replica1/replica2 均在运行" bash -c '
  for c in redis-master redis-replica1 redis-replica2; do
    [ "$(docker inspect -f "{{.State.Running}}" "$c" 2>/dev/null)" = "true" ] || exit 1
  done'

# 3. 三个哨兵对 master 地址的判断一致
check "三个哨兵对 master 地址判断一致" bash -c '
  [ -n "$1" ] && [ "$1" = "$2" ] && [ "$2" = "$3" ]' _ "$S1_IP" "$S2_IP" "$S3_IP"

# 4. 哨兵认定的 master 能对应到某个 redis 容器
check "哨兵认定的 master 是三个 redis 容器之一" bash -c '[ -n "$1" ]' _ "$MASTER_C"

# 5. failover 确实发生过：master 已不是原主库 172.28.0.11
check "failover 已发生（master 不再是 172.28.0.11）" bash -c '
  [ -n "$1" ] && [ "$1" != "172.28.0.11" ]' _ "$S1_IP"

# 6. 当前 master 的 role 为 master
check "当前 master 容器 role:master" bash -c '
  [ "$(docker exec "$1" redis-cli INFO replication 2>/dev/null | tr -d "\r" | grep "^role:" | cut -d: -f2)" = "master" ]' _ "$MASTER_C"

# 7. 其余两个实例（含重启回来的旧主）role:slave 且复制链路 up
check "其余两个实例 role:slave 且 master_link_status:up" bash -c '
  for c in redis-master redis-replica1 redis-replica2; do
    [ "$c" = "$1" ] && continue
    R=$(docker exec "$c" redis-cli INFO replication 2>/dev/null | tr -d "\r")
    echo "$R" | grep -q "^role:slave" || exit 1
    echo "$R" | grep -q "^master_link_status:up" || exit 1
  done' _ "$MASTER_C"

# 8. mymaster 的 flags 中没有任何下线标记
FLAGS=$(docker exec sentinel1 redis-cli -p 26379 --raw SENTINEL master mymaster 2>/dev/null | tr -d '\r' | grep -A1 '^flags$' | tail -1)
check "mymaster 状态正常（flags 无 s_down/o_down）" bash -c '
  [ -n "$1" ] && case "$1" in *s_down*|*o_down*) exit 1;; esac' _ "$FLAGS"

# 9. 哨兵互相发现
NOS=$(docker exec sentinel1 redis-cli -p 26379 --raw SENTINEL master mymaster 2>/dev/null | tr -d '\r' | grep -A1 '^num-other-sentinels$' | tail -1)
check "哨兵互相发现（num-other-sentinels = 2）" bash -c '[ "$1" = "2" ]' _ "$NOS"

# 10. 数据保留：session:1 值为 v1，且 key 总数不少于 100
check "数据保留（session:1 = v1 且 key 总数 >= 100）" bash -c '
  [ "$(docker exec "$1" redis-cli GET session:1 2>/dev/null | tr -d "\r\n")" = "v1" ] || exit 1
  N=$(docker exec "$1" redis-cli DBSIZE 2>/dev/null | tr -d "\r\n")
  [ -n "$N" ] && [ "$N" -ge 100 ]' _ "$MASTER_C"

# 11. 当前 master 可写（写入并删除 labcheck 键）
check "当前 master 可写入（labcheck 键 SET/GET/DEL）" bash -c '
  K="labcheck:$$"
  docker exec "$1" redis-cli SET "$K" ok >/dev/null 2>&1 || exit 1
  [ "$(docker exec "$1" redis-cli GET "$K" 2>/dev/null | tr -d "\r\n")" = "ok" ] || exit 1
  docker exec "$1" redis-cli DEL "$K" >/dev/null 2>&1' _ "$MASTER_C"

# 12. redis-mem：16MB 上限 + 已发生 LRU 淘汰
check "redis-mem maxmemory=16MB 且已发生淘汰" bash -c '
  M=$(docker exec redis-mem redis-cli CONFIG GET maxmemory 2>/dev/null | tr -d "\r" | grep -v "^maxmemory$" | tail -1)
  [ "$M" = "16777216" ] || exit 1
  E=$(docker exec redis-mem redis-cli INFO stats 2>/dev/null | tr -d "\r" | grep "^evicted_keys:" | cut -d: -f2)
  [ -n "$E" ] && [ "$E" -gt 0 ]'

# 13. redis-mem2：noeviction 且内存已打满
check "redis-mem2 noeviction 且内存已打满" bash -c '
  P=$(docker exec redis-mem2 redis-cli CONFIG GET maxmemory-policy 2>/dev/null | tr -d "\r" | grep -v "^maxmemory-policy$" | tail -1)
  [ "$P" = "noeviction" ] || exit 1
  U=$(docker exec redis-mem2 redis-cli INFO memory 2>/dev/null | tr -d "\r" | grep "^used_memory:" | cut -d: -f2)
  [ -n "$U" ] && [ "$U" -gt 7000000 ]'

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
