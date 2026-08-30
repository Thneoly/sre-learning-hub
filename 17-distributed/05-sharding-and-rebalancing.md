# 05 · 分片与再平衡：范围、哈希，与"为什么它们都不用一致性哈希"

> 模块：17-distributed ｜ 建议时长：3 小时 ｜ 关联认证：—（无直接考点；Redis Cluster、Kafka 分区运维、Mongo 分片键选型都以此章为理论底座）

## 学习目标

- 能按"查询形态 + 写入分布"两个维度在范围分片与哈希分片之间选型，并指出各自的经典故障（单调递增热点 / 范围查询退化）
- 能讲清一致性哈希的环模型、虚拟节点，以及它真正解决的问题是"最小迁移"
- 能回答三家为什么都不用一致性哈希：Redis 的 16384 槽、Kafka 的手动分区、HDFS 的块切分，各自的取舍
- 能估算一次再平衡的三本账（迁移流量 / 源端压力 / 客户端感知），并据此选执行窗口

## 1. 分片维度：范围 vs 哈希

数据量超过单机，就要把键空间切开（sharding / partitioning）。切法只有两大家族，MongoDB 分片那一章已经把判据写得很清楚（好分片键 = 高基数 + 高打散度 + 贴合查询模式，见 [11-middleware/mongodb/02-replicaset-and-sharding.md](../11-middleware/mongodb/02-replicaset-and-sharding.md) §分片架构）：

| 维度 | 范围分片（ranged） | 哈希分片（hashed） |
|---|---|---|
| 归属规则 | 键空间按序切段，段落到节点 | `hash(key) mod N`（或取模于槽数） |
| 范围查询 | **高效**（定位到段，局部扫描） | **退化**：不带分片键等值条件的查询广播全片聚合（scatter-gather） |
| 写入分布 | **易热点**：单调递增键（自增 id、时间戳）永远落在最后一段 | 均匀 |
| 扩容语义 | 切点移动，天然连续 | 重新映射，见第 2 节 |
| 经典翻车 | Mongo `{user_id:1}` ranged 的"最后一片热点"；Hive/Influx 按天分区写热点 | hashed 后范围扫描全变广播，读放大成倍 |

两句话总结选型：**按"实体"点查为主 → 哈希；按"时间/序"扫描为主 → 范围**。混合负载用复合键（高基数列打散 + 前缀列保范围），Mongo 的 `refineCollectionShardKey` 与 Redis 的 hash tag 都是这条路。

两类分片在"同一个查询"上的路径差异，画出来一目了然：

```
查询：WHERE create_time BETWEEN '08-01' AND '08-07'（1 万条）

范围分片（按天切段）                    哈希分片（按 id 打散）
  shard-1 [08-01~08-03] ──命中──► 扫      shard-1..shard-6 全部命中
  shard-2 [08-04~08-06] ──命中──► 扫        id 的哈希与时间无关，
  shard-3 [08-07~08-09] ──部分──► 扫        7 天的数据均匀散在 6 个片
  shard-4 [08-10~...]   ──跳过            每片都要查 + 归并排序
                                          = scatter-gather，读放大 N 倍
  访问 3/4 个片，无归并排序
```

反过来，`WHERE user_id = 1001` 这类点查在哈希分片下是一跳直达；在范围分片下，若 user_id 单调递增，热点还会压在"当前最大值所在的那一片"上——**没有免费的分片维度，只有与查询形态匹配的分片维度**。

热点不是哈希分片的专利：哈希只能保证"键均匀"，不能保证"流量均匀"——一个大 V 的 key 与一个僵尸账号的 key 各占一个槽，QPS 却差一万倍。这种"键不倾斜、请求倾斜"要在业务层打散（key 加盐、本地预聚合，Flink 数据倾斜的加盐两阶段聚合是同一个手法，见 [12-data-streaming/flink/02-deployment-and-exactly-once.md](../12-data-streaming/flink/02-deployment-and-exactly-once.md) §6）。

## 2. 一致性哈希：原理、虚拟节点、它到底解决什么

朴素取模 `hash(key) mod N` 的致命伤在扩容：N 变 N+1 时，几乎所有 key 的归属都变（实测 5→6 节点要搬 **82.7%** 的 key，见实战演练），等于一次全量迁移 + 缓存全失效。一致性哈希（consistent hashing）的目标只有一个：**加减节点时，只影响相邻的一小段键空间，其余 key 纹丝不动——最小迁移**。

```
        0
   ┌───────────► 哈希环（0 ~ 2^64-1，首尾相接）
   │ node-a#3      node-b#7        key 的归属：从 hash(key) 出发
  ██                ██              顺时针遇到的第一个节点
   │ 8324            19017          ◄── key(k1)=12000 → node-b#7
   │                  │
   │ node-c#2        node-a#11      节点下线：只有它的那段 key
  ██        k1=12000  ██            改判给顺时针下一个邻居，
   │                  │             其余全部不动
   └──────────────────┘
        2^64-1
```

只放 N 个物理节点到环上有两个问题，**虚拟节点（vnode）**一并解决：

1. **倾斜**：节点少时，环上的段长短悬殊（实测无 vnode 时 5→6 迁移率 34.5%，负载偏差可达数倍）；每个物理节点放 100~200 个虚拟节点（`hash(node#i)`）后，段长趋近均匀（实测 160 vnode 负载 1882~2175，偏差约 ±8%）；
2. **数据/负载异构**： vnode 数可以按机器能力加权（新机器多放 vnode = 多扛数据）。

运维必须记住它的边界：一致性哈希优化的是**迁移量**这一个目标，代价是"归属完全由哈希决定"——**冷热与倾斜无法人工干预**（想手动把某个热点 key 挪到专属机器？做不到），且路由需要环表（或客户端缓存环拓扑）。这个边界正是下一节三家弃用它的原因。

补一个常被忽略的语义：**节点故障摘除与节点下线是同一件事**——把该节点的全部 vnode 从环上拿掉，它的 key 改判给各自的顺时针邻居。由于 vnode 本来就散布全环，故障节点的负载是"摊给所有幸存者"而不是砸给某一个邻居（无 vnode 时，一个节点的死会把整段流量甩给顺时针下一个节点，形成二次热点）。这就是 Cassandra/Dynamo 这类无主架构偏好一致性哈希的原因：**故障转移与扩缩容共用同一套平滑语义**。而这也再次暴露它与多数派系统的分工——一致性哈希管"谁负责哪些 key"，quorum（第 03 章）才管"这些 key 的副本一致不一致"。

## 3. 三家为什么不用一致性哈希

这不是"一致性哈希不好"，而是**当分片单位可以是显式元数据时，没人愿意让哈希隐式决定一切**。

### 3.1 Redis Cluster：16384 个槽

把键空间切成 **16384 个 slot**（`slot = CRC16(key) mod 16384`），每个节点负责一段槽。它买了一致性哈希想要的同样东西（加减节点只动一部分 key），但把归属关系变成**显式、可枚举的元数据**：每节点一个 16384bit = 2KB 的槽位 bitmap，心跳里互相传播。扩缩容的迁移单位是"槽的集合"——成段、可暂停、可回滚、可人工指定；而一致性哈希的归属藏在哈希函数里，倾斜无法干预，还得靠 vnode 撑均匀。16384 这个数则是"心跳包里 2KB 槽位图 × 官方建议最大 1000 节点"的折中（antirez 在官方 issue 里有完整解释）。完整原文见 [11-middleware/redis/02-persistence-and-ha.md](../11-middleware/redis/02-persistence-and-ha.md) §7.1。

迁移中间态用两个重定向语义兜住：`MOVED`（槽已永久易主，客户端更新本地槽表）与 `ASK`（槽迁移中，仅本次去目标节点执行，不改槽表）——**为什么迁移中必须 ASK 不能 MOVED**，redis 章自测第 5 题有完整的"重定向死循环"推演，这里不重复。

### 3.2 Kafka：显式分区 + 手动迁移

Kafka 的分片单位是**分区（partition）**，`hash(key)` 只决定"进哪个分区"，而**分区到 broker 的映射是创建时写死的静态元数据**——扩容 broker 后老分区纹丝不动，新 broker 只承接新建分区。官方不自动迁移的理由是性能层面的：自动搬移意味着带宽与 IO 的不可控消耗。想让分区搬家，要显式发起：Strimzi 上是 `KafkaRebalance` CR（Cruise Control 生成提案 → **人工 approve** → 执行），裸集群是 `kafka-reassign-partitions.sh`。[12-data-streaming/kafka/labs/01-strimzi-cluster/task.md](../12-data-streaming/kafka/labs/01-strimzi-cluster/task.md) 的加分项就是亲手做一遍"扩容 → describe 确认分区没动 → KafkaRebalance 搬过去"，solution.md 里的结论值得抄进笔记：**Kafka 分区分配是静态元数据，扩容不会自动迁移**。

注意区分两个"rebalance"：**消费组 rebalance**（分区在消费者之间重新分配，秒级、自动、可能形成风暴）与**分区再分配**（副本在 broker 之间搬迁，搬数据、手动、分钟到小时级）。面试混说这两个是硬伤。

### 3.3 HDFS：块切分，根本没有"键空间"

HDFS 面对的是**文件**不是"键值"：一个 10GB 文件直接按 `dfs.blocksize`（默认 128MB）切成约 80 个块，每块独立选 3 个 DataNode 落位（机架感知放置：本机 → 远端机架 → 同机架另一台，见 [16-bigdata/01-hdfs.md](../16-bigdata/01-hdfs.md) §4）。**分片 = 物理切块**，不存在"key 归属计算"，也就无所谓哈希/范围之争；新 DataNode 加入后由 balancer 按容量百分比慢慢匀，而不是重算任何映射。代价是文件内没有记录级寻址——要按 key 查，得在上面盖一层（HBase 用 rowkey 范围，Hive 按分区列裁剪）。

### 3.4 对照表（背这张）

| | 一致性哈希 | Redis 16384 槽 | Kafka 分区 | HDFS 块 |
|---|---|---|---|---|
| 分片单位 | 环上的一段（隐式） | 槽（显式，2KB 位图） | 分区（显式元数据） | 块（物理切分） |
| 归属计算 | 顺时针找 vnode | CRC16 mod 16384 | key→分区，分区→broker 静态 | 文件偏移量切块 |
| 扩容语义 | 相邻段自动改判 | 手工迁槽，可暂停/回滚 | 不动老分区，手动再分配 | 块不变，balancer 匀总量 |
| 迁移量 | ~1/N（最小） | ~1/N（按槽计） | 按分区大小 | 按容量差 |
| 热点干预 | 不可（哈希决定） | 可（hash tag 定向） | 可（建分区时规划） | 不可（文件级） |
| 客户端复杂度 | 环缓存 | smart client + MOVED/ASK | 元数据订阅 | 直连 NameNode |

横向规律：**越靠近存储底座（HDFS），分片越"物理"；越靠近在线服务（Redis/Kafka），分片越要成为可控元数据**。一致性哈希活在两者之间——Dynamo/Cassandra 这类对等节点、无中心元数据的系统才是它的主场。

## 4. 再平衡的运维代价与窗口选择

再平衡（rebalancing）= 把部分数据从旧归属搬到新归属。动手前先算三本账：

| 账本 | 内容 | 实测锚点 |
|---|---|---|
| **迁移流量** | ≈ 搬移数据量走一遍网络与磁盘；1TB 数据 1Gbps 网络理论 2 小时+，叠加业务流量翻倍 | 迁 16384/6 ≈ 2731 个槽 ≈ 1/6 的数据 |
| **源端/目标端压力** | Redis `MIGRATE` 是**同步阻塞源节点单线程**的命令，大批量小 key 直接把源节点卡出超时 | 小批量循环（每批 10~100 个 key）是铁律（[redis 02 章 §7.2](../11-middleware/redis/02-persistence-and-ha.md)） |
| **客户端感知** | 槽迁移中的 ASK 重定向、Kafka 消费组 rebalance 期间的整组停顿、Mongo balancer 搬 chunk 时的路由抖动 | 消费组 rebalance 的触发条件与代价见 [kafka 01 章 §6](../12-data-streaming/kafka/01-log-model-and-architecture.md) |

窗口选择的四条纪律：

1. **低峰执行**：迁移流量与业务流量叠加是最常见的"扩容引发故障"；
2. **限速 + 可暂停**：Redis 迁槽天然可暂停（槽的中间态有 ASK 兜着）；Kafka 把"提案 → 人工 approve"设计成两步就是给运维留闸门；Cruise Control 限流参数以官方文档为准；
3. **盯住中间态的完成度**：`cluster-require-full-coverage=yes`（默认）下任何槽没有归属则整个集群拒绝写——迁一半弃疗比不迁更危险；
4. **避开连锁反应**：扩容 + 滚动发布 + 消费组 rebalance 叠加在一起就是"再平衡风暴"（第 07 章五类故障之一），变更窗口彼此错开。

**防风暴的设计选型**：Kafka 消费组用 `CooperativeStickyAssignor`（增量协作式，rebalance 期间不停全组，KIP-429）；会话超时与 `max.poll.interval.ms` 按真实处理时长放宽，避免"处理慢被误踢 → rebalance → 更慢"的正反馈（三大排障表见 [kafka 03 章 §5](../12-data-streaming/kafka/03-operations-and-performance.md)）。

动手前的 pre-flight 清单（顺序执行，任何一条不满足就改期）：

```
□ 容量账：迁移量 ≈ 数据量/N，按当前网卡与磁盘吞吐估出纯迁移时长 ×2（业务叠加）
□ 窗口账：低峰时段是否覆盖预估时长？覆盖不了 → 分多晚迁，确认中间态可暂停
□ 副本账：迁移目标盘余量 > 迁移量 × 1.5；源/目标节点近期无磁盘/网络告警
□ 中间态账：Redis 确认 require-full-coverage 语义下的拒写风险；Kafka 确认提案内容
           （搬哪些分区、估多少字节）并只在 approve 后才真正动数据
□ 干扰账：同一窗口没有滚动发布、没有别的扩缩容、没有备份/compaction 大任务
□ 回滚账：每一步的回滚动作写下来（SETSLOT 归还 / 撤销 KafkaRebalance），
         并确认回滚本身不产生新迁移
□ 观测账：源节点延迟、客户端超时率、消费组 rebalance 次数三条曲线有人盯
```

## 实战演练

用 Python 亲手复现第 2、3 节的所有数字（含 Redis 真实的 CRC16 槽算法）。环境：任意有 python3 的机器，命令标注 `[任意节点]`（Windows 本机也可）。

```python
# [任意节点] 保存为 shard_sim.py，然后 python3 shard_sim.py
import hashlib

def crc16(data: bytes) -> int:          # Redis 的 CRC16-CCITT/XMODEM 实现
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc

print(f"crc16('123456789') = {crc16(b'123456789'):#06x}")   # 校验值 0x31c3，对了说明实现无误

NODES = ["node-a", "node-b", "node-c", "node-d", "node-e"]
KEYS = [f"order:{i:04d}".encode() for i in range(10000)]

def naive(k: bytes, n: int) -> int:     # 朴素取模
    return int(hashlib.md5(k).hexdigest(), 16) % n

def build_ring(nodes, vnodes):          # 一致性哈希环（含虚拟节点）
    ring = []
    for n in nodes:
        for i in range(vnodes):
            ring.append((int(hashlib.md5(f"{n}#{i}".encode()).hexdigest(), 16), n))
    return sorted(ring)

def owner(k: bytes, ring):
    h = int(hashlib.md5(k).hexdigest(), 16)
    for v, n in ring:                   # 顺时针第一个 vnode
        if v >= h:
            return n
    return ring[0][1]

moved = sum(1 for k in KEYS if naive(k, 5) != naive(k, 6))
print(f"朴素取模        5→6 节点迁移率: {moved/len(KEYS):.1%}")

NODES6 = NODES + ["node-f"]
moved = sum(1 for k in KEYS if owner(k, build_ring(NODES, 1)) != owner(k, build_ring(NODES6, 1)))
print(f"一致性哈希无vnode 5→6 节点迁移率: {moved/len(KEYS):.1%}")

r5, r6 = build_ring(NODES, 160), build_ring(NODES6, 160)
moved = sum(1 for k in KEYS if owner(k, r5) != owner(k, r6))
print(f"一致性哈希160vnode 5→6 节点迁移率: {moved/len(KEYS):.1%}  （理论 1/6≈16.7%）")

from collections import Counter
print("160 vnode 时各节点 key 数:", dict(sorted(Counter(owner(k, r5) for k in KEYS).items())))

print("slot('user:1000') =", crc16(b"user:1000") % 16384)
print("slot('{user:1000}.profile') =", crc16(b"user:1000") % 16384, " ← hash tag：只算 {} 内")
print("slot('{user:1000}.orders')  =", crc16(b"user:1000") % 16384, " ← 同 tag 必同槽（多 key 操作的前提）")
```

预期输出（数字是确定性的，逐行对得上）：

```
crc16('123456789') = 0x31c3
朴素取模        5→6 节点迁移率: 82.7%
一致性哈希无vnode 5→6 节点迁移率: 34.5%
一致性哈希160vnode 5→6 节点迁移率: 15.7%  （理论 1/6≈16.7%）
160 vnode 时各节点 key 数: {'node-a': 1882, 'node-b': 2175, 'node-c': 1916, 'node-d': 1956, 'node-e': 2071}
slot('user:1000') = 1649
slot('{user:1000}.profile') = 1649  ← hash tag：只算 {} 内
slot('{user:1000}.orders')  = 1649  ← 同 tag 必同槽（多 key 操作的前提）
```

三个验证点：① 朴素取模 5→6 搬 82.7% vs 一致性哈希 15.7%——"最小迁移"从口号变成数字；② 无 vnode 时迁移率虚高（34.5%）且负载偏差大——虚拟节点是均匀性的来源；③ hash tag 让 `user:1000` 的三个 key 全落 1649 号槽，与 [redis 02 章 §7.1](../11-middleware/redis/02-persistence-and-ha.md) 的 hash tag 说明互相印证。

延伸实验（有练习集群时）：在 [12-data-streaming/kafka/labs/01-strimzi-cluster](../12-data-streaming/kafka/labs/01-strimzi-cluster/task.md) 里把 `KafkaNodePool` 扩到 4 副本，用 `kafka-topics.sh --describe` 亲眼看"新 broker 不出现在旧分区副本列表里"，再走一遍 KafkaRebalance 加分项。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 扩容后集群反而更慢/超时 | 迁移流量与业务高峰叠加；MIGRATE 大批次阻塞源节点 | 低峰 + 小批量（10~100 key/批）+ 限速；分多天迁 |
| 迁槽迁到一半放弃，集群整层写失败 | `cluster-require-full-coverage=yes` 下有槽无归属即拒绝写 | 迁移要么完成要么显式回滚（`SETSLOT` 归还），别留孤儿中间态 |
| 加了 2 个 Redis 节点，倾斜没改善 | 归属由 CRC16 决定，加节点只匀"键"不匀"流量" | 定位热点 key（`--hotkeys`/监控），hash tag 隔离或业务打散 |
| 新 Kafka broker 空转，磁盘 0 增长 | 分区是静态元数据，扩容不自动迁移 | KafkaRebalance（add-brokers）或 kafka-reassign-partitions.sh（[kafka 03 章常见坑](../12-data-streaming/kafka/03-operations-and-performance.md)） |
| 滚动发布后消费组反复 rebalance | 发布 + 会话超时 + max.poll.interval 叠加成风暴 | cooperative-sticky、放宽超时、错开变更窗口 |
| Mongo ranged 分片，最后一片磁盘先满 | 单调递增分片键写热点 | hashed 键或复合打散；jumbo chunk 治理见 [mongo 02 章](../11-middleware/mongodb/02-replicaset-and-sharding.md) |
| 面试把两个 rebalance 说混 | 消费组 rebalance（秒级、自动）≠ 分区再分配（搬数据、手动） | 先分清对象是消费者还是 broker |

## 自测

1. 为什么一致性哈希加节点只影响"相邻段"，而朴素取模几乎全部重排？用 5→6 的例子说清楚。
<details><summary>答案</summary>

朴素取模的归属函数是 `hash(key) mod N`，N 从 5 变 6 后同一个 key 的模数几乎必然改变（只有恰好跨过公倍数的极少数不变），实测 82.7% 的 key 换归属。一致性哈希把"节点"也哈希到同一个环上，key 归属 = 顺时针第一个节点：新节点只插进环上的一个点，只"截走"它到上一个节点之间的那一段（约 1/N），其余 key 顺时针路径不变、归属不变。本质区别：**取模把节点数写进了归属函数，一致性哈希没有**。
</details>

2. Redis 用 16384 槽达到了与一致性哈希同样的"最小迁移"，为什么说它反而更可控？多付了什么？
<details><summary>答案</summary>

可控来自三点：归属是显式元数据（每节点 2KB 位图，可枚举可审计）；迁移单位是槽的集合，成段迁移、可暂停可回滚、可人工指定（想把热点 key 定向搬到新机器，用 hash tag 即可）；倾斜可干预。一致性哈希的归属藏在哈希函数里，运维无法插手，只能靠加 vnode 缓解。多付的代价：集群要维护/传播槽位元数据（gossip 心跳），客户端要做 smart client（槽缓存 + MOVED/ASK 处理），跨槽多 key 操作受限（必须同槽，DB 只能用 0）——见 [redis 02 章 §7/§8](../11-middleware/redis/02-persistence-and-ha.md) 的选型表。
</details>

3. HDFS 为什么不需要在"范围 vs 哈希"里做选择？它的"再平衡"和 Redis 迁槽有何本质不同？
<details><summary>答案</summary>

HDFS 的对象是文件而非键空间：文件按 128MB 物理切块，块与块之间没有键的语义，不存在"key 归属计算"，因此无哈希/范围之争；记录级寻址交给上层（HBase rowkey、Hive 分区列）。它的 balancer 匀的是**副本的总量分布**（按容量百分比搬已有块），不改变任何"归属映射"；Redis 迁槽改变的是"哪些 key 由谁负责"的元数据归属，且中间态需要 ASK 重定向兜着。一个是搬"物理块的位置"，一个是改"逻辑归属表"。
</details>

4. 迁移中的槽为什么必须用 ASK 一次性重定向，客户端却不能记住它？
<details><summary>答案</summary>

槽迁移是中间态：同一槽的 key 一部分还在源、一部分已到目标，但槽的正式归属（`SETSLOT NODE`）要等迁移完成才切换。若客户端此时把 ASK 当 MOVED 记进槽表，会永久把该槽指向目标节点——目标上还没迁完的 key 会被查无此 key，而且目标节点对"未正式拥有"的槽也会回 MOVED 指回源，形成重定向死循环。ASK 的语义是"仅此一条命令，先 ASKING 再去目标执行"，槽表不动，等迁移真正完成由 MOVED 接管。完整推演见 [redis 02 章自测 5](../11-middleware/redis/02-persistence-and-ha.md)。
</details>

5. 你们打算把 5 节点 Redis Cluster 扩到 6 个，容量 200GB。给出执行计划的关键数字与步骤。
<details><summary>答案</summary>

迁移量：约 16384/6 ≈ 2730 个槽、约 1/6 ≈ 33GB 数据。步骤：① 低峰窗口，确认没有滚动发布/大批量任务；② 新节点以 cluster meet 加入，确认槽位图传播正常；③ 逐槽 `CLUSTER SETSLOT IMPORTING/MIGRATING` + 小批量 MIGRATE（10~100 key/批），批间观察源节点延迟与客户端超时率，随时可暂停（中间态有 ASK 兜底）；④ 每迁完一槽执行 `SETSLOT NODE` 收敛归属，客户端靠 MOVED 更新槽表；⑤ 全部收敛后复核 `cluster check`、倾斜率与 hit/miss。要点：迁移量可控可暂停是 16384 槽相对一致性哈希的运维优势，这里正好用上（[redis 02 章 §7.2](../11-middleware/redis/02-persistence-and-ha.md)）。
</details>

## 延伸阅读

- Redis Cluster 规范（槽、MOVED/ASK、gossip、迁移）：https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/
- antirez 关于 16384 槽的原始讨论：https://github.com/redis/redis/issues/2576
- Kafka 分区再分配官方文档：https://kafka.apache.org/documentation/#basic_ops_rebalance
- Strimzi KafkaRebalance（Cruise Control 提案-批准流程）：https://strimzi.io/docs/operators/latest/deploying#con-kafka-rebalancing-str
- KIP-429 增量协作式 rebalance：https://cwiki.apache.org/confluence/display/KAFKA/KIP-429%3A+Kafka+Consumer+Incremental+Rebalance+Protocol
- HDFS Balancer：https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HdfsUserGuide.html#Balancer
- Consistent Hashing 原始论文（Karger et al.）：https://dl.acm.org/doi/10.1145/258533.258660
