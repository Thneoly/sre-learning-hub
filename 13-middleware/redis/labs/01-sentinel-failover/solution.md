# Lab 01 · 解答：哨兵故障转移全流程与 maxmemory 排障

环境：装有 Docker 的 Ubuntu 22.04/24.04 VM。所有命令标注 `[任意节点]`。

## 步骤 1：网络与一主二从

做什么：先建专用 bridge 网络并给 Redis 容器**静态 IP**。

为什么：哨兵内部记录的是 **IP 而不是容器名**（它会把自己发现的拓扑回写进配置文件），如果 IP 漂移，failover 后旧主可能再也找不回来。生产上这对应"哨兵监控的地址必须是稳定地址"——K8s 里要用稳定的 Service/Pod 地址或 `announce-ip`。

```bash
# [任意节点] 建网 + 一主二从（从库用 --replicaof 指向容器名，docker 内置 DNS 可解析）
docker network create --subnet 172.28.0.0/24 redis-ha-net
docker run -d --name redis-master  --network redis-ha-net --ip 172.28.0.11 redis:7.2
docker run -d --name redis-replica1 --network redis-ha-net --ip 172.28.0.12 redis:7.2 --replicaof redis-master 6379
docker run -d --name redis-replica2 --network redis-ha-net --ip 172.28.0.13 redis:7.2 --replicaof redis-master 6379
sleep 3
```

验证输出：

```text
# docker exec redis-master redis-cli INFO replication | grep -E '^role|connected_slaves'
role:master
connected_slaves:2
# docker exec redis-replica1 redis-cli INFO replication | grep -E '^role|master_link_status'
role:slave
master_link_status:up
```

## 步骤 2：三哨兵

做什么：为每个哨兵准备独立目录里的 `sentinel.conf`，挂载**目录**（不是单文件）后启动。

为什么：哨兵会把 myid、发现的从库与其他哨兵回写进配置文件，Redis 的回写是"临时文件 + rename 覆盖"，对单文件 bind mount 会报 `Device or resource busy`。`down-after-milliseconds 5000` 让演练不用等 30 秒默认值；`parallel-syncs 1` 让两个从库逐个切主，减少切换瞬间的同步压力。

```bash
# [任意节点] 生成三份哨兵配置并启动
for i in 1 2 3; do
  mkdir -p ~/redis-ha/s$i
  cat > ~/redis-ha/s$i/sentinel.conf <<EOF
port 26379
sentinel monitor mymaster 172.28.0.11 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 30000
sentinel parallel-syncs mymaster 1
EOF
  docker run -d --name sentinel$i --network redis-ha-net --ip 172.28.0.2$i \
    -v ~/redis-ha/s$i:/conf \
    redis:7.2 redis-sentinel /conf/sentinel.conf
done
sleep 5
```

验证输出：

```text
# docker exec sentinel1 redis-cli -p 26379 SENTINEL ckquorum mymaster
OK 3 usable Sentinels. Quorum and failover authorization can be reached
# docker exec sentinel1 redis-cli -p 26379 --raw SENTINEL get-master-addr-by-name mymaster
172.28.0.11
6379
# grep num-other-sentinels 会看到 2（hello 频道互发现需要几秒）
```

## 步骤 3：初始状态全面确认

```bash
# [任意节点] 哨兵视角：flags 应只有 master，replicas 应有两个
docker exec sentinel1 redis-cli -p 26379 --raw SENTINEL master mymaster | tr -d '\r' | grep -A1 -E '^(flags|num-slaves|num-other-sentinels)$'
docker exec sentinel1 redis-cli -p 26379 SENTINEL replicas mymaster | grep -c 'ip'
```

## 步骤 4：写入初始数据

```bash
# [任意节点] 100 个会话 key（逐条 exec 简单直接，量小无所谓）
for i in $(seq 1 100); do docker exec redis-master redis-cli SET session:$i v$i >/dev/null; done
docker exec redis-master redis-cli MGET session:1 session:50 session:100
docker exec redis-replica2 redis-cli GET session:100
```

验证输出：`MGET` 返回 `v1 v50 v100`；从库 `GET` 返回 `v100`（复制已生效）。

## 步骤 5：kill 主库并计时

做什么：`docker kill`（SIGKILL，模拟宕机；`docker stop` 会走优雅退出还可能触发保存，拖慢且不真实）。从 kill 开始每秒问一次哨兵要 master 地址，直到它不再是 172.28.0.11。

```bash
# [任意节点] 杀主库 + 轮询计时
docker kill redis-master
START=$(date +%s)
while :; do
  IP=$(docker exec sentinel1 redis-cli -p 26379 --raw SENTINEL get-master-addr-by-name mymaster | head -1)
  [ "$IP" != "172.28.0.11" ] && break
  sleep 1
done
END=$(date +%s)
echo "kill -> 哨兵切换视图耗时: $((END - START)) 秒（当前 master: $IP）"
```

验证输出（典型值，与机器性能有关）：

```text
kill -> 哨兵切换视图耗时: 9 秒（当前 master: 172.28.0.12）
```

拆解这 9 秒（对照第 2 章的事件流）：

```bash
# [任意节点] 看哨兵日志里的关键事件
docker logs sentinel1 2>&1 | grep -oE '\+(sdown|odown|new-epoch|try-failover|elected-leader|selected-slave|failover-state-send-slaveof-noone|promoted-slave|failover-state-reconf-slaves|switch-master)[^ ]*.*' | tail -15
```

```text
+sdown master mymaster 172.28.0.11 6379        ← kill 后 ~5s（down-after-milliseconds）
+odown master mymaster 172.28.0.11 6379        ← 第 2 个哨兵确认，quorum=2 达成
+new-epoch 1
+try-failover master mymaster ...               ← 选出 leader，开始转移
+selected-slave slave 172.28.0.12:6379          ← 挑中 replica1（数据最完整）
+promoted-slave slave 172.28.0.12:6379          ← SLAVEOF NO ONE 完成，升主
+failover-state-reconf-slaves ...               ← replica2 改指向新主
+switch-master mymaster 172.28.0.11 6379 172.28.0.12 6379   ← 完成
```

为什么是这个量级：5s 判定窗口是配置值，剩下 ~4s 是 quorum 确认 + leader 选举 + 提升新主 + 重指从库。生产上把 `down-after-milliseconds` 调小可以压缩总耗时，但太小会把网络抖动也当成宕机，反而制造无谓切换。

## 步骤 6：验证切换结果

```bash
# [任意节点] 新主身份、从库指向、数据保留、可写
docker exec redis-replica1 redis-cli INFO replication | grep -E '^role|connected_slaves'
docker exec redis-replica2 redis-cli INFO replication | grep -E '^role|master_host|master_link_status'
docker exec redis-replica1 redis-cli GET session:100
docker exec redis-replica1 redis-cli SET probe:manual ok
```

验证输出：

```text
role:master
connected_slaves:1
role:slave
master_host:172.28.0.12
master_link_status:up
"v100"
OK
```

## 步骤 7：旧主回归自动降级

```bash
# [任意节点] 拉回旧主，等哨兵处置
docker start redis-master
sleep 10
docker exec redis-master redis-cli INFO replication | grep -E '^role|master_host|master_link_status'
docker logs sentinel1 2>&1 | grep convert-to-slave | tail -1
```

验证输出：

```text
role:slave
master_host:172.28.0.12
master_link_status:up
... +convert-to-slave slave 172.28.0.11:6379 @ mymaster 172.28.0.12 6379
```

为什么重要：旧主回来时以独立 master 身份启动（启动命令里没有 replicaof），是**哨兵**发现它并对它下发 `SLAVEOF` 拉回新主麾下。这正是脑裂防护的反面教材——如果分区期间旧主还在接受写，这些写会在它降级做全量同步时全部丢掉，所以生产 master 上要配 `min-replicas-to-write 1` + `min-replicas-max-lag 10`。

## 步骤 8：模拟客户端重连，量化不可用窗口

做什么：每秒一次"问哨兵要地址 → SET"的循环（在 sentinel1 容器内执行，天然可达 docker 网络），全程带时间戳。

为什么：这是 smart client 的最小模型——真实 SDK（redis-py/Lettuce 等）的 sentinel 模式就是"订阅 +switch-master 或定期刷新 master 地址"。

```bash
# [任意节点] 60 秒观察窗口（在另一个终端跑，然后另开终端 kill 主库更直观；本 lab 顺序执行则看到的是切换后的持续可用）
for i in $(seq 1 60); do
  OUT=$(docker exec sentinel1 sh -c '
    IP=$(redis-cli -p 26379 --raw SENTINEL get-master-addr-by-name mymaster | head -1)
    redis-cli -h "$IP" SET probe:$(date +%s) ok 2>&1')
  printf '%s %s\n' "$(date +%T)" "$OUT"
  sleep 1
done
```

若把 kill 放在循环中段，典型输出：

```text
21:14:02 OK
21:14:03 OK
21:14:04 Could not connect to Redis at 172.28.0.11:6379: Connection refused   ← kill
21:14:05 Could not connect to Redis at 172.28.0.11:6379: Connection refused
21:14:06 Could not connect to Redis at 172.28.0.11:6379: Connection refused
21:14:07 Could not connect to Redis at 172.28.0.11:6379: Connection refused   ← sdown 判定窗口
21:14:08 Could not connect to Redis at 172.28.0.11:6379: Connection refused
21:14:09 Could not connect to Redis at 172.28.0.11:6379: Connection refused
21:14:10 Could not connect to Redis at 172.28.0.11:6379: Connection refused   ← 选举+提升中
21:14:11 Could not connect to Redis at 172.28.0.11:6379: Connection refused
21:14:12 OK                                                                  ← 哨兵已切换视图，客户端跟上新主
```

结论：不可用窗口 ≈ kill 到 switch-master 的秒数（本例约 8~9 秒）。注意报错期间连的还是**旧主地址**——只有客户端"每秒都问哨兵"才恢复得这么快，写死 IP 的客户端永远不会恢复。

## 步骤 9：redis-mem——LRU 淘汰行为

```bash
# [任意节点] 16MB 上限 + allkeys-lru
docker run -d --name redis-mem --network redis-ha-net --ip 172.28.0.31 -p 6406:6379 \
  redis:7.2 --maxmemory 16mb --maxmemory-policy allkeys-lru
# 灌 5 万个 ~300B 的 key（pipe 一次灌入）
docker exec -i redis-mem sh -c 'V=$(printf "x%.0s" $(seq 1 300)); seq 1 50000 | sed "s/^/SET m1:/" | sed "s/$/ $V/" | redis-cli --pipe'
docker exec redis-mem redis-cli INFO memory | grep -E 'used_memory_human|maxmemory_human'
docker exec redis-mem redis-cli INFO stats | grep evicted_keys
docker exec redis-mem redis-cli DBSIZE
```

验证输出：

```text
used_memory_human:16.0M左右
maxmemory_human:16.00M
evicted_keys:19xxx        ← LRU 持续在淘汰（写一个、挤掉一个）
50000 键并未存下：DBSIZE 约 3 万
```

解读：`allkeys-lru` 下写入**不报错**，代价是老 key 被静默换出——线上对应的现象是"命中率下降、DB 回源变多"，而不是 Redis 报错。监控要看 `redis_evicted_keys_total` 的增长速率，而不是等业务喊慢。

## 步骤 10：redis-mem2——noeviction 报错与排障推演

```bash
# [任意节点] 8MB 上限 + noeviction（Redis 默认策略）
docker run -d --name redis-mem2 --network redis-ha-net --ip 172.28.0.32 -p 6407:6379 \
  redis:7.2 --maxmemory 8mb --maxmemory-policy noeviction
docker exec -i redis-mem2 sh -c 'V=$(printf "y%.0s" $(seq 1 300)); seq 1 30000 | sed "s/^/SET m2:/" | sed "s/$/ $V/" | redis-cli --pipe'
docker exec redis-mem2 redis-cli SET any:key v
docker exec redis-mem2 redis-cli CONFIG GET maxmemory maxmemory-policy
docker exec redis-mem2 redis-cli INFO memory | grep -E 'used_memory_human|maxmemory_human'
docker exec redis-mem2 redis-cli DBSIZE
```

验证输出：

```text
# pipe 输出的尾部会滚动出现：
error: OOM command not allowed when used memory > 'maxmemory'
# 单条 SET：
(error) OOM command not allowed when used memory > 'maxmemory'
# CONFIG GET：
maxmemory 8388608
maxmemory-policy noeviction
# INFO memory：
used_memory_human:8.0M左右   maxmemory_human:8.00M
# DBSIZE 停在 2 万左右——写满即止
```

排障推演（接到 OOM 报错后的 5 分钟）：

1. 报错原文已经说明语义：`used memory > maxmemory`——不是磁盘满，是 Redis 内存上限；
2. `CONFIG GET maxmemory-policy` 确认策略：noeviction（默认值！实例没做缓存化配置）；
3. `DBSIZE` 与 `used_memory` 对比估算单 key 均值，判断是正常增长还是 bigkey/泄漏；
4. 处置选项：扩 `maxmemory`（先确认机器/容器还有余量，别把 OOM 转嫁给内核）、改缓存场景该用的 `allkeys-lru`（接受淘汰）、给 key 补 TTL 让过期机制接管；
5. 长期：上 `redis_memory_used_bytes / redis_memory_max_bytes > 0.9` 的提前告警，别等写入报错才发现（第 3 章第 5 节）。

## 运行 check.sh

```bash
# [任意节点]（在 lab 目录内）
chmod +x check.sh && ./check.sh
```

预期全部通过：

```text
PASS: sentinel1/2/3 均在运行
PASS: redis-master/replica1/replica2 均在运行
PASS: 三个哨兵对 master 地址判断一致
PASS: 哨兵认定的 master 是三个 redis 容器之一
PASS: failover 已发生（master 不再是 172.28.0.11）
PASS: 当前 master 容器 role:master
PASS: 其余两个实例 role:slave 且 master_link_status:up
PASS: mymaster 状态正常（flags 无 s_down/o_down）
PASS: 哨兵互相发现（num-other-sentinels = 2）
PASS: 数据保留（session:1 = v1 且 key 总数 >= 100）
PASS: 当前 master 可写入（labcheck 键 SET/GET/DEL）
PASS: redis-mem maxmemory=16MB 且已发生淘汰
PASS: redis-mem2 noeviction 且内存已打满

SCORE: 13/13
```

## 清理

```bash
# [任意节点] check 通过后再清理
docker rm -f redis-master redis-replica1 redis-replica2 sentinel1 sentinel2 sentinel3 redis-mem redis-mem2
docker network rm redis-ha-net
rm -rf ~/redis-ha
```

## 复盘要点

- 切换总耗时 = `down-after-milliseconds`（本例 5s）+ quorum 确认 + leader 选举 + 提升新主（合计约 4s）。要快就调小判定窗口，要稳就保持默认 30s——这是"误切换风险"与"不可用时长"的权衡；
- 客户端必须走 sentinel 协议动态拿地址，写死 IP 的客户端在 failover 后永久写失败；
- 旧主回归被自动降级，但如果分区期间它还在接受写，那部分数据必丢——生产上配 `min-replicas-to-write 1` + `min-replicas-max-lag 10`；
- noeviction 的故障形态是"显式写报错"，allkeys-lru 的故障形态是"隐性丢缓存 + 回源压力"：策略选型决定你的监控盯哪个指标（`rejected`/写错误 vs `evicted_keys` 与命中率）。
