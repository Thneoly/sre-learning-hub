# 03 · 缓存模式与线上排障：穿透击穿雪崩、一致性、阻塞点与监控告警

> 模块：11-middleware/redis ｜ 建议时长：4 小时 ｜ 关联认证：PCA-监控与告警（PromQL/告警规则直接复用）；CKA-工作负载（Redis Operator 部署）

## 学习目标

- 能区分缓存穿透/击穿/雪崩的现象与根因，为每个场景选出合适的方案并说明代价
- 能解释"先更新库再删缓存"的取舍、延迟双删的适用边界，以及 binlog 订阅方案的链路
- 能按固定路径排查 Redis 阻塞：慢命令、fork、swap、AOF fsync 四类元凶逐一定位
- 能对比 8 种 maxmemory 淘汰策略并为缓存/存储两类场景给出选型
- 能部署 redis_exporter，编写命中率/内存/淘汰/连接数告警，并给出阈值依据

## 1. 三大经典故障：穿透、击穿、雪崩

```
                 正常：请求 → 命中缓存返回（DB 无感）
穿透（查不存在的数据）      击穿（单个热点 key 过期）       雪崩（大面积失效/实例宕机）
 req ──► 缓存 MISS          req ──► 缓存 MISS              req req req req ──► 全部 MISS
        │                          │（唯一的热点 key 刚过期）        │（大量 key 同时到期 或 Redis 挂了）
        ▼                          ▼                              ▼
       DB 也没有                  DB（被打挂）                    DB（被打挂）
        │                          │
        ▼                          ▼
 返回空但不缓存 →      并发回源压垮 DB            恶意流量/爬虫扫库   热点 key 天然集中   key 集中过期/实例故障
 下一个请求继续打 DB
```

### 1.1 方案对比表

| 故障 | 根因 | 方案 | 优点 | 代价/注意 |
|---|---|---|---|---|
| 穿透 | 数据在缓存和 DB 都不存在 | 缓存空值（短 TTL 30~300s） | 实现最简单 | 空值 key 会占内存；DB 新增该数据后要能被查到（TTL 要短） |
| 穿透 | 同上 | Bloom filter 前置过滤 | 内存省、判定快 | 存在误判率（宁可放行不可错杀）；新增数据要重建过滤器 |
| 穿透 | 恶意请求 | 入口参数校验 + 限流/风控 | 从源头省流量 | 治本但跨团队 |
| 击穿 | 热点 key 过期瞬间并发回源 | 互斥锁回源（`SET lock:key 1 NX EX 10`，拿到锁的线程查库回填，其余短暂等待或返回旧值） | 只放一个请求去 DB | 等待增加延迟；锁超时要兜底防死锁 |
| 击穿 | 同上 | 逻辑过期（value 里带过期时间字段，物理不设 TTL；发现过期后异步刷新，先返回旧值） | 永不阻塞 | 牺牲短暂一致性；代码复杂 |
| 雪崩 | 大量 key 同时过期 | TTL 加随机抖动（`expire = base + rand(0,300)`） | 一行代码 | 无 |
| 雪崩 | 实例宕机/网络故障 | 哨兵/Cluster 高可用 + 客户端快速重连 | 自动恢复 | 第 2 章整章内容 |
| 雪崩 | 回源洪峰超出 DB 容量 | 多级缓存（进程内 cache + Redis）+ 熔断降级限流 | 保住 DB | 有陈旧窗口；需要熔断组件 |

判断口诀：**个别 key 不存在是穿透，唯一热点 key 过期是击穿，成片同时失效或实例挂掉是雪崩**。三者常叠加出现，先止损（限流降级）再修因。

## 2. 缓存一致性：Cache Aside 及其变种

### 2.1 基本模式与"删缓存"的理由

```
读：cache ──MISS──► DB ──► 回填 cache（带 TTL 兜底）
写：先更新 DB ──► 再删除 cache（下次读自然回源加载新值）
```

为什么是删而不是更新缓存：并发写时两次更新的乱序会把旧值留在缓存；计算缓存值可能昂贵而该 key 未必再被读（懒加载更划算）。

### 2.2 先删缓存 vs 先更库，以及天然的脏数据窗口

```
先删缓存再更库（不推荐）：           先更库再删缓存（推荐，窗口更小）：
T1 写: DEL cache                    T1 写: UPDATE db
T2 读: MISS → 读 db（旧值）          T2 读: MISS → 读 db（新值）→ 回填 cache（新值）
T1 写: UPDATE db（新值）             T1 写: DEL cache（把可能的旧回填清掉）
T2 读: 回填 cache = 旧值             剩余竞态：T2 的"读 db"发生在 T1 UPDATE 之前、
→ 脏数据将存活到 TTL 或下次删除        回填发生在 T1 DEL 之后 → 旧值入库
                                     （概率低：要求读比写慢且交错刚好，TTL 兜底）
```

### 2.3 延迟双删与 binlog 订阅

延迟双删（对付主从延迟下读旧库的场景）：

```
写线程: DEL cache → UPDATE db（主库）
        → sleep(读业务耗时 + 主从延迟，通常几百毫秒~1s）
        → 再次 DEL cache（清掉读线程从"还没同步完的从库"读到的旧值回填）
```

缺陷：sleep 时长靠估，延迟抖动就失效；写路径被拉长。它依然只是缩小窗口。

binlog 订阅（大厂标准做法）：

```
业务只写 DB ──► canal/debezium 伪装从库订阅 binlog ──► 投递 MQ
        ──► 删缓存消费者（失败重试 + 幂等，兜底 TTL）
```

写路径完全不含缓存操作；DB 与缓存通过 binlog 解耦，保证"DB 变更必然触发一次删除"。代价：多一条链路要运维，消费滞后期间仍有窗口。**结论：没有强一致的便宜方案**，除非把读写都上分布式锁串行化（性能不可接受）。工程上选"最终一致 + TTL 兜底 + 监控命中率"，一致窗口可估算（binlog 消费延迟）就够了。

## 3. 阻塞点排查：单线程模型下的四类元凶

Redis 主线程串行执行命令，任何一步慢都会让所有请求排队。排查按固定顺序过筛：

```
P99 延迟高 / 超时报警
   │
   ├─① 慢命令？ ──► SLOWLOG GET / INFO commandstats 的 usec_per_call
   │     KEYS *、大集合 HGETALL/SMEMBERS/LRANGE、SORT、DEL 大 key、FLUSHALL
   │     → 换 SCAN/HSCAN/UNLINK/分批；FLUSHALL/FLUSHDB 用 ASYNC 选项
   │
   ├─② fork 卡顿？ ──► INFO stats 的 latest_fork_usec（微秒）
   │     RDB/AOF 重写触发 fork，与内存成正比；THP 让 COW 变 2MB 粒度
   │     → 关 THP、控制实例大小、错峰；见第 2 章
   │
   ├─③ swap？ ──► INFO memory 的 mem_fragmentation_ratio < 1
   │     RSS < used_memory 说明页被换出，每次访问都是磁盘 IO
   │     → 查宿主机/cgroup 内存压力；vm.swappiness 调 1；扩容或迁移
   │
   └─④ AOF fsync 慢？ ──► INFO stats 的 aof_delayed_fsync 增长
         磁盘 IO 打满（同盘还有 RDB/日志/其他实例）→ everysec 被迫跳刷
         → AOF 挪到独立盘；评估 no-appendfsync-on-rewrite；换更快的盘
```

配套工具：

```bash
# [任意节点] 慢查询：记录执行超过阈值的命令（默认 10ms = 10000 微秒）
redis-cli CONFIG SET slowlog-log-slower-than 10000
redis-cli SLOWLOG GET 5

# [任意节点] 延迟监控（阈值毫秒）：按事件名记录延迟尖刺（command/fork/aof-fsync-always...）
redis-cli CONFIG SET latency-monitor-threshold 50
redis-cli LATENCY LATEST
redis-cli LATENCY DOCTOR        # 直接给出诊断建议

# [任意节点] 从客户端侧测真实 RTT，区分 Redis 慢还是网络慢
redis-cli --latency -h <redis-host>
redis-cli --intrinsic-latency 30   # 在 Redis 宿主机上跑，测系统本身（调度/虚拟化）的延迟底线

# [任意节点] 每条命令的平均耗时：找 usec_per_call 大的非 O(1) 命令
redis-cli INFO commandstats | grep -E 'cmdstat_(keys|hgetall|smembers|del)'
```

## 4. 八种淘汰策略

`maxmemory` 打满后，写入前按 `maxmemory-policy` 决定行为（读命令不受影响）。`volatile-*` 只考虑**带 TTL 的 key**，`allkeys-*` 考虑全部 key：

| 策略 | 候选范围 | 算法 | 适用 | 风险 |
|---|---|---|---|---|
| noeviction（默认） | — | 拒绝写，报 `OOM command not allowed...` | 把 Redis 当存储而非缓存 | 打满即写故障，必须配容量告警 |
| volatile-ttl | 有 TTL 的 key | 剩余存活时间越短越先淘汰 | TTL 本身表达了优先级 | 全库没 TTL 时等同 noeviction |
| volatile-lru | 有 TTL 的 key | 近似 LRU | 混用（一部分 key 是缓存、一部分不能动） | 淘汰范围受限，可能淘汰不掉 |
| volatile-lfu | 有 TTL 的 key | 近似 LFU（4.0+） | 同上且访问频率比新旧更重要 | 同上 |
| volatile-random | 有 TTL 的 key | 随机 | 极少用 | 不可预期 |
| allkeys-lru | 全部 key | 近似 LRU | **纯缓存场景默认推荐** | 冷数据会被换出（本来就是缓存的语义） |
| allkeys-lfu | 全部 key | 近似 LFU | 有明显热点频率差异的缓存 | 偶发批量扫描会虚增频率（有衰减机制缓解） |
| allkeys-random | 全部 key | 随机 | 全等价 key 的临时数据 | 基本不用 |

实现细节（决定"为什么便宜"）：LRU/LFU 不是精确全局排序，而是随机采样 `maxmemory-samples 5` 个 key 里挑最该淘汰的（调大更准更慢）；LFU 用对数计数器（`lfu-log-factor 10`）+ 时间衰减（`lfu-decay-time 1` 分钟），255 的计数值够表达百万级访问频率。淘汰默认同步释放内存，配 `lazyfree-lazy-eviction yes` 可异步化。7.x 里 replica 默认不淘汰（`replica-ignore-maxmemory yes`），避免从库数据被掏空。

选型一句话：**纯缓存 allkeys-lru（热点明显用 allkeys-lfu）；Redis 里有不可重建数据就 noeviction + 严格容量告警 + 提前扩容**。最容易踩的坑：配了 `volatile-lru` 但业务 key 全没设 TTL——一个都淘汰不掉，写入照样报 OOM。

## 5. redis_exporter：必看指标与告警

oliver006/redis_exporter 是事实标准（GitHub 官方仓库）。部署（Docker 单机演示）：

```bash
# [任意节点] 被监控实例假设已发布在宿主机 6403 端口
docker run -d --name redis-exporter -p 9121:9121 \
  --add-host=host.docker.internal:host-gateway \
  -e REDIS_ADDR=redis://host.docker.internal:6403 \
  oliver006/redis_exporter:latest
curl -s http://localhost:9121/metrics | grep -E '^redis_(up|memory_used_bytes|evicted_keys_total)'
# 预期: redis_up 1、redis_memory_used_bytes <字节数>、redis_evicted_keys_total <次数>
```

（生产建议固定镜像版本，以 GitHub Releases 为准；K8s 里用 Deployment + Service 暴露 9121，挂到 Prometheus 的 ServiceMonitor 或 static_configs。）

| 指标 | 含义 | 告警建议阈值 | 依据 |
|---|---|---|---|
| `redis_up` | 抓取/连接是否成功 | `== 0` 持续 1m | 实例不可用 |
| `redis_memory_used_bytes / redis_memory_max_bytes` | 内存使用率 | `> 0.9` 持续 5m（无 maxmemory 时分母为 0，先看 `redis_memory_max_bytes > 0`） | 到 100% 开始拒绝写或淘汰 |
| `redis_evicted_keys_total` | 已淘汰 key 数（counter） | `rate(...[5m]) > 0` | 缓存开始丢数据/穿透前兆 |
| `redis_keyspace_hits_total / misses_total` | 命中/未命中（counter） | 命中率 `< 0.9` 持续 10m | 回源压力与缓存价值 |
| `redis_connected_clients` | 当前连接数 | `> 500` 或接近 maxclients（默认 10000） | 连接泄漏/打满拒绝新连接 |
| `redis_rejected_connections_total` | 因超 maxclients 被拒的连接 | `increase(...[5m]) > 0` | 已经影响到业务 |
| `redis_blocked_clients` | 阻塞在 BLPOP/BRPOP 等的客户端 | `> 0` 持续 5m | 未必故障，但要看是否预期内使用 |
| `redis_replication_offset` / `redis_connected_slaves` | 复制进度 / 在线从库数 | `redis_connected_slaves < 1`（哨兵/主从组） | 高可用降级 |
| `redis_rdb_last_bgsave_status` / `redis_aof_last_write_status` | 持久化健康（exporter 把 ok 映射为 1，不同版本可能差异，落地前先在 /metrics 里核对取值） | `!= 1` 持续 5m | 备份/持久化静默失败 |
| `redis_slowlog_length` | 慢查询队列长度 | 突增结合 `SLOWLOG GET` 人工看 | 阻塞排查入口 |
| `redis_commands_duration_seconds_total` | 各命令累计耗时（counter，除以 calls 得均值） | 无固定阈值，看趋势 | 替代无法远程取的 usec_per_call |

告警规则示例（Prometheus 规则文件，语法可直接加载）：

```yaml
# [任意节点] /etc/prometheus/rules/redis.yml（Prometheus --config.file 指向的主配置里 rule_files 引入）
groups:
- name: redis-alerts
  rules:
  - alert: RedisDown
    expr: redis_up == 0
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: 'Redis 实例 {{ $labels.instance }} 不可达'
  - alert: RedisMemoryHigh
    expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.9
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: 'Redis {{ $labels.instance }} 内存使用率超 90%'
  - alert: RedisEvicting
    expr: rate(redis_evicted_keys_total[5m]) > 0
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: 'Redis {{ $labels.instance }} 正在发生 key 淘汰'
  - alert: RedisLowHitRatio
    expr: sum(rate(redis_keyspace_hits_total[5m]))
      / (sum(rate(redis_keyspace_hits_total[5m])) + sum(rate(redis_keyspace_misses_total[5m]))) < 0.9
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: 'Redis 命中率低于 90%（聚合口径，按需加 by (instance)）'
  - alert: RedisRejectedConnections
    expr: increase(redis_rejected_connections_total[5m]) > 0
    labels:
      severity: critical
    annotations:
      summary: 'Redis {{ $labels.instance }} 拒绝了新连接（超 maxclients）'
  - alert: RedisNoReplica
    expr: redis_connected_slaves < 1
    for: 1m
    labels:
      severity: critical
    annotations:
      summary: 'Redis {{ $labels.instance }} 没有在线从库'
```

## 6. K8s 上的 Redis：Operator

StatefulSet 手搭 Redis + Sentinel 的痛点：Pod 重建 IP 变化、Sentinel 回写的配置与声明式配置打架、failover 后 StatefulSet 仍想"修回"旧主。Operator 用 CRD + 控制器把这些流程代码化。常见选择：

- **Spotahome/redis-operator**：专做主从 + 哨兵，CR 极简，社区广泛使用；
- **OT-CONTAINER-KIT/redis-operator**：支持 standalone/replication/cluster 三种模式与 exporter 侧车；
- **Redis Enterprise Operator**（Redis 官方商业版）/ 各云厂商托管（AWS ElastiCache、阿里云 Tair 等）。

Spotahome 的 RedisFailover 示例（字段以所用版本 README 为准）：

```yaml
# [master] redis-failover.yaml（先按 operator 文档安装 CRD 与控制器）
apiVersion: databases.spotahome.com/v1
kind: RedisFailover
metadata:
  name: cache-redis
  namespace: middleware
spec:
  redis:
    replicas: 3            # 1 主 2 从
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        memory: 1Gi
  sentinel:
    replicas: 3            # 三哨兵
```

```bash
# [master] 部署并验证：operator 会创建 redis 与 sentinel 两组 StatefulSet/Service
kubectl apply -f redis-failover.yaml
kubectl get redisfailover cache-redis -n middleware
kubectl get pods -n middleware -l app=cache-redis
# 客户端连哨兵 Service 查 master 地址（sentinel 端口 26379），SDK 走 sentinel 协议
```

容量要点（把第 1/2 章落进来）：容器 memory limit 要给 RDB fork COW 与复制缓冲留余量（limit ≈ maxmemory 的 1.5 倍以上）；持久化用 PVC（StatefulSet volumeClaimTemplates 或 CR 的 storage 字段）；大实例建议 maxmemory 与 limit 同时配置并按第 5 节做内存告警。

## 实战演练

环境：装有 Docker 的 Ubuntu VM。

```bash
# [任意节点] 慢命令定位全流程
docker run -d --name redis-trouble -p 6403:6379 redis:7.2
docker exec -i redis-trouble sh -c 'seq 1 50000 | sed "s/^/SET k:/" | sed "s/$/ v/" | redis-cli --pipe'
time docker exec redis-trouble redis-cli KEYS '*' > /dev/null
# 预期: real 约 0.2~0.5s——这 0.5s 内实例上的所有请求都在排队（生产上 KEYS 是禁用命令）
docker exec redis-trouble redis-cli SLOWLOG GET 3
# 预期: 第一条就是 keys *，含微秒耗时
docker exec redis-trouble redis-cli --scan --count 1000 | head -3
# 预期: 游标分批返回，替代方案不阻塞
docker exec redis-trouble redis-cli CONFIG SET latency-monitor-threshold 50
docker exec redis-trouble redis-cli LATENCY LATEST
# 预期: 出现 command 事件的尖刺记录
```

```bash
# [任意节点] 淘汰行为与 OOM 报错
docker run -d --name redis-evict -p 6404:6379 redis:7.2 --maxmemory 16mb --maxmemory-policy allkeys-lru
docker exec -i redis-evict sh -c 'V=$(printf "x%.0s" $(seq 1 300)); seq 1 50000 | sed "s/^/SET e:/" | sed "s/$/ $V/" | redis-cli --pipe'
docker exec redis-evict redis-cli INFO memory | grep -E 'used_memory_human|maxmemory_human'
# 预期: used_memory 停在 16M 左右（写入被限制住了）
docker exec redis-evict redis-cli INFO stats | grep evicted_keys
# 预期: evicted_keys:数万——LRU 在持续淘汰
docker exec redis-evict redis-cli DBSIZE
# 预期: 远小于 50000（老 key 被换出）
docker exec redis-evict redis-cli CONFIG SET maxmemory-policy noeviction
docker exec redis-evict redis-cli SET extra:1 v
# 预期: (error) OOM command not allowed when used memory > 'maxmemory'
docker exec redis-evict redis-cli CONFIG SET maxmemory-policy volatile-lru
docker exec redis-evict redis-cli SET extra:2 v
# 预期: 仍然 OOM——没有任何 key 带 TTL，volatile-lru 无候选可淘汰（最常见误配）
docker exec redis-evict redis-cli TTL e:1
# 预期: -1（无过期时间），坐实原因
```

```bash
# [任意节点] exporter 指标验证（复用 6403 的 redis-trouble）
docker run -d --name redis-exporter -p 9121:9121 \
  --add-host=host.docker.internal:host-gateway \
  -e REDIS_ADDR=redis://host.docker.internal:6403 \
  oliver006/redis_exporter:latest
sleep 2
curl -s http://localhost:9121/metrics | grep -E '^redis_(up|connected_clients|keyspace_hits_total|commands_processed_total)'
# 预期: redis_up 1 以及若干指标行；把这些指标对照第 5 节阈值表逐个认一遍
```

验证方法：`SLOWLOG GET` 的耗时与 `time` 测得的 KEYS 耗时对得上；淘汰实验里 `evicted_keys` 增长与 `DBSIZE` 不变相互印证；三次策略切换的报错差异就是排查 OOM 问题的肌肉记忆。清理：`docker rm -f redis-trouble redis-evict redis-exporter`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 配了 volatile-lru 仍报 OOM | 没有 key 带 TTL，volatile 系无候选 | 要么 allkeys-*，要么给 key 补 TTL |
| 缓存命中率掉到 60% 但内存没涨 | maxmemory 太小，热点 key 被 LRU 频繁换出 | 扩 maxmemory；或热点数据本地缓存 |
| 突发超时但 SLOWLOG 是空的 | 阻塞不在命令层：fork 延迟/swap/AOF fsync | 看 `latest_fork_usec`、碎片率是否 <1、`aof_delayed_fsync` |
| 空值缓存把穿透治好后内存暴涨 | 空值 key 无 TTL 常驻 | 空值必须带短 TTL 且控制 key 空间 |
| 双删后偶发旧值 | sleep 时长小于主从延迟 | 延迟对齐监控（复制延迟指标）后再定值；上 binlog 方案 |
| failover 后客户端还在写旧主报错/丢写 | 客户端没走 sentinel 感知 | SDK 启用 sentinel 模式；订阅 +switch-master |
| K8s 容器频繁被 OOMKilled | limit 没给 fork COW 留余量 | limit ≥ 1.5×maxmemory；关 THP；错峰 BGSAVE |
| 告警 `redis_rdb_last_bgsave_status` 误报 | exporter 版本对 ok/err 的取值映射不同 | 落地前 curl /metrics 核对实际取值再定表达式 |

## 自测

1. 穿透和击穿都会导致"缓存查不到、请求打到 DB"，一线值班时你靠什么区分？
<details><summary>答案</summary>

看监控的形态与 key 维度：击穿集中在**单个热点 key 刚过期**的瞬间，DB 上是同一条 SQL 的高频重复查询，缓存里该 key 存在但 age 刚到 TTL；穿透是**大量不存在于 DB 的 key**（错误 id、恶意扫描），DB 查询结果为空且缓存里从未有这些 key，通常还伴随异常的 key 模式（随机数、负数 id、超长字符串）。处置也不同：击穿上互斥锁/逻辑过期，穿透上空值缓存或 Bloom filter + 入口限流。
</details>

2. 为什么"先更新 DB 再删缓存"仍然可能留下脏数据？这条路径的触发条件是什么？
<details><summary>答案</summary>

竞态：读请求 MISS 后从 DB 读值，随后写请求完成 UPDATE 并 DEL，最后读请求才把**旧值**回填进缓存。触发条件是"读 DB 发生在写提交前，而回填发生在 DEL 之后"——即一个更慢的读和一个更快的写交错。概率低（读通常快于写），但高 QPS 下必然发生，所以要有 TTL 兜底，或用延迟双删/binlog 订阅把删除再做一次。
</details>

3. Redis 实例 P99 从 2ms 涨到 80ms，SLOWLOG 为空，`INFO clients` 正常。你的排查顺序？
<details><summary>答案</summary>

命令层没证据，转向另外三类：① `INFO stats` 看 `latest_fork_usec` 是否异常大（RDB/AOF 重写触发 fork，先关 THP 再评估实例大小）；② `INFO memory` 看 `mem_fragmentation_ratio` 是否 < 1（swap，查宿主机内存与 cgroup OOM）；③ `INFO stats` 看 `aof_delayed_fsync` 是否增长（磁盘 IO 饱和导致 everysec 跳刷，盘上是否还有 RDB/日志抢 IO）；④ 同时 `redis-cli --intrinsic-latency` 在宿主机上排除虚拟化/调度噪声，`--latency` 从客户端侧确认网络 RTT 是否变化。四步定位完基本必然命中其一。
</details>

4. 同样 8GB maxmemory 的两个实例：A 用 allkeys-lru，B 用 noeviction。业务写入速率相同时，哪个先出问题？出什么问题？
<details><summary>答案</summary>

B 先出问题：写满后所有写命令报 OOM，等于写故障（若业务当它是缓存，会直接报错风暴）。A 会"安静地"淘汰冷 key，写入继续成功，代价是命中率下降、回源 DB 的读增多——所以 A 的故障形态是**下游 DB 变慢**而非 Redis 报错，需要在告警里同时盯 `redis_evicted_keys_total` 的 rate 和命中率，否则会漏报。结论：淘汰策略把故障从"显式拒绝写"转移到"隐式穿透"，监控必须跟着策略走。
</details>

5. 为什么 `volatile-lfu` 配置下 TTL 到期的 key 和被淘汰的 key 是两回事？分别看哪个指标？
<details><summary>答案</summary>

到期是**被动/主动过期机制**（访问时惰性删除 + 后台周期采样删除，`active-expire-effort` 控制力度），计入 `expired_keys`；淘汰是**内存不够时主动腾地方**（按 maxmemory-policy 采样挑选），计入 `evicted_keys`。两者都会让 key 消失，但前者是业务设定的生命周期、后者是容量压力信号。`evicted_keys` 增长 = 容量规划失败，应当告警；`expired_keys` 增长通常只是正常业务节奏。
</details>

## 延伸阅读

- 官方延迟问题排查文档：https://redis.io/docs/latest/develop/use/latency/
- 官方 key 淘汰策略（LRU/LFU 近似实现）：https://redis.io/docs/latest/develop/use/lru-cache/
- redis_exporter 指标与部署：https://github.com/oliver006/redis_exporter
- Spotahome Redis Operator：https://github.com/spotahome/redis-operator
- OT-CONTAINER-KIT Redis Operator：https://github.com/OT-CONTAINER-KIT/redis-operator
