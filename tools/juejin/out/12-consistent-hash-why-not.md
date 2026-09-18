---
title_juejin: 一致性哈希那么好，为什么 Redis 和 Kafka 都不用
title_zhihu: 一致性哈希那么好，为什么 Redis 和 Kafka 都不用
description: 一致性哈希的虚拟节点解决什么问题，Redis用16384槽、Kafka用静态分区各自的设计取舍，以及真正的运维差异。
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686341072617242662"
---

# 一致性哈希那么好，为什么 Redis 宁可管 16384 个槽、Kafka 宁可手动搬分区也不用？

面试时你能把一致性哈希讲得头头是道：哈希环、虚拟节点、只动相邻一段。

面试官补一刀："那 Redis Cluster 为什么用 16384 个槽？"——十个能背哈希环的，九个答不上这一问。

更扎心的是：Kafka 不用，HDFS 也不用。面试必背神器，被主流中间件三巨头集体绕开——答案不是性能问题，而是一个教科书永远不会告诉你的取舍，一个让 Redis、Kafka 各自花了十几年时间绕开它的取舍。今天把这事儿聊透。

## 1. 先看朴素取模有多惨

所有分片的起点都是 `hash(key) mod N`：简单、均匀、O(1) 定位。它的致命伤在扩容。

N 从 5 变 6，模数变了，几乎所有 key 的归属都跟着变。同样一次 5 扩 6：

**朴素取模要搬 82.7% 的 key，一致性哈希只搬 15.7%。**

对缓存集群，前一个数字等于一次全量迁移加缓存集体失效，后端 DB 瞬间被打爆——这就是"扩容引发故障"的经典剧本。

不用背结论，这组数字可以亲手跑出来——跑完你会看到三个数字，第一个就能吓到你。40 行脚本，只用标准库，存成 `shard_sim.py`：

```python
# 存为 shard_sim.py，任何有 python3 的机器都能跑
import hashlib
from collections import Counter

def naive(k, n):
    return int(hashlib.md5(k).hexdigest(), 16) % n

def build_ring(nodes, vnodes):
    ring = []
    for n in nodes:
        for i in range(vnodes):
            ring.append((int(hashlib.md5(f"{n}#{i}".encode()).hexdigest(), 16), n))
    return sorted(ring)

def owner(k, ring):
    h = int(hashlib.md5(k).hexdigest(), 16)
    for v, n in ring:
        if v >= h:
            return n
    return ring[0][1]

NODES = ["node-a", "node-b", "node-c", "node-d", "node-e"]
NODES6 = NODES + ["node-f"]
KEYS = [f"order:{i:04d}".encode() for i in range(10000)]

moved = sum(1 for k in KEYS if naive(k, 5) != naive(k, 6))
print(f"朴素取模             5->6 迁移率: {moved/len(KEYS):.1%}")

moved = sum(1 for k in KEYS if owner(k, build_ring(NODES, 1)) != owner(k, build_ring(NODES6, 1)))
print(f"一致性哈希 无vnode    5->6 迁移率: {moved/len(KEYS):.1%}")

r5, r6 = build_ring(NODES, 160), build_ring(NODES6, 160)
moved = sum(1 for k in KEYS if owner(k, r5) != owner(k, r6))
print(f"一致性哈希 160vnode  5->6 迁移率: {moved/len(KEYS):.1%} (理论 1/6=16.7%)")

print("160vnode 各节点key数:", dict(sorted(Counter(owner(k, r5) for k in KEYS).items())))
```

```bash
python3 shard_sim.py
```

预期输出（数字是确定性的，逐行对得上）：

```text
朴素取模             5->6 迁移率: 82.7%
一致性哈希 无vnode    5->6 迁移率: 34.5%
一致性哈希 160vnode  5->6 迁移率: 15.7% (理论 1/6=16.7%)
160vnode 各节点key数: {'node-a': 1882, 'node-b': 2175, 'node-c': 1916, 'node-d': 1956, 'node-e': 2071}
```

第三个数字 15.7% 是后文的主角；中间那个 34.5% 先按下不表，第 3 节它会变成虚拟节点的出场理由。

## 2. 一致性哈希解决的就是这一件事

一致性哈希的目标只有一个：**加减节点时，只影响相邻的一小段 key 空间，其余纹丝不动**——最小迁移。

做法：把 key 和节点都哈希到同一个环上，首尾相接（本文脚本用 MD5 的全部 128 位，环空间是 0 ~ 2^128-1；生产实现常用 2^64 宽度的环，比如 Cassandra 的 Murmur3），key 的归属 = 从自己的哈希值出发，顺时针遇到的第一个节点。

把环从 0 处剪开拉直看（哈希值往右增大，最右端绕回最左端）：

```text
 0 ──────────────●──────────────●──────────────●──────────► 2^128-1
              node-b          node-c          node-d
                └──────────────┘
        归 node-c 的段：从上一个节点的位置，到它自己的位置

 key 的哈希落在这段里 → 顺时针第一个遇到的是 node-c → 归 node-c
 新节点 X 插进 node-b 和 node-c 之间 → 只截走「上一个节点 → X」这一小段
 其余 key 的归属，一个都不变
```

新节点加入，只是往环上插了一个点，只"截走"它到上一个节点之间的那一段——大小约为扩容后节点总数的倒数（5→6 时即 1/6，正是上面 15.7% 的来源）。

节点下线和故障摘除是同一件事：把它的全部 vnode 从环上拿掉，它那段 key 改判给顺时针邻居，其余 key 的路径完全不变。

本质区别一句话：**朴素取模把节点数 N 写进了归属函数，一致性哈希没有**。这就是为什么一个全重排、一个只动相邻段。

## 3. 虚拟节点到底解决什么

上面的输出还藏着一个尴尬数字：无 vnode 时迁移率 34.5%。先把话说准：期望仍然是 1/6，但只往环上扔 5 个点，段长的方差极大——这一次就扔出了 34.5%，两倍于理论值；而 160 个 vnode 把这个方差压没了。方差，正是虚拟节点要解决的第一个问题。

**问题一：倾斜。** 只放 5 个物理节点到环上，段长短得离谱——谁的段长，谁扛的 key 就多，负载偏差能到数倍。

每个物理节点放 160 个虚拟节点（`hash(node#i)`）后，段长趋近均匀。看输出最后一行：1882~2175，偏差约 ±8%。

**问题二：异构加权。** vnode 数量可以按机器能力分配：32C 的机器放 200 个，16C 的放 100 个，新机器自然多扛数据，不用改任何算法。

**附带收益：故障摊薄。** 无 vnode 时一个节点挂了，整段流量砸给顺时针下一个邻居，形成二次热点；vnode 本来就散布全环，负载是"摊给所有幸存者"。

这也是 Cassandra、Dynamo 这类无主架构偏爱一致性哈希的原因：故障转移和扩缩容共用同一套平滑语义，还不需要中心元数据。

## 4. 但它有个死穴：哈希说了算，运维插不上手

开头欠的答案在这里兑付：一致性哈希不是不好，是它解决的问题太窄——只优化"迁移量"这一个目标，代价是**归属完全由哈希函数决定**：

- 热点 key 想手动挪到专属机器？做不到，哈希说了算
- 想审计"哪些 key 归哪台机器"？ring 查单个 key 的归属是 O(log V)（V 为 vnode 总数，二分定位），但没有 16384 槽那种固定、可枚举的运维单元——想盘清全量归属，仍要对所有 key 重放一遍哈希（第 1 节的脚本就是这么算的），也拿不到槽位图那样 O(1) 可查的放置关系
- 路由要么查环表，要么客户端缓存环拓扑，环变更还得通知大家

还有个更隐蔽的坑：哈希只能保证"键均匀"，不能保证"流量均匀"。

一个大 V 的 key 和一个僵尸号的 key 各占一个槽，QPS 差一万倍——加节点只匀键，不匀流量。这种"键不倾斜、请求倾斜"只能在业务层打散（key 加盐、预聚合）。

这一节就是三家弃用它的根因：**当分片单位可以做成显式元数据时，没人愿意让哈希隐式决定一切**。

顺便也能看出一个规律：凡是把"运维可控"看得比"全自动"更重的系统，都在想办法把归属关系从哈希函数里捞出来，变成一张看得见、摸得着、能人为修改的表。

## 5. Redis Cluster：16384 个槽

Redis 把键空间切成 16384 个槽，`slot = CRC16(key) mod 16384`，每个节点负责一段槽。

它买到一致性哈希的同款收益（加减节点只动一部分 key），但归属变成了**显式、可枚举的元数据**：

- 每节点一张 16384 bit 的槽位 bitmap，只有 2KB，塞在 gossip 心跳里传播
- 迁移单位是"槽的集合"：成段迁移、可暂停、可回滚、可人工指定
- 倾斜可干预：hash tag 能把一组 key 定向锁到同一个槽

先主动立个靶子，评论区一定有人提："16384 个槽，本质就是一致性哈希的工程变体，标题碰瓷。"不对。区别不在迁移量——两者扩容都只动约 1/N；区别在于归属是从哈希函数里"算出来"的，还是变成一张"查得到、改得动"的表。前者是自然规律，只能靠重放哈希反推；后者是运维资产：能随心跳传播、能成段迁移、能用 hash tag 干预。第 4 节的死穴，槽全都治了。

为什么偏偏是 16384？心跳包里 2KB 槽位图 × 官方建议最大 1000 节点的折中，antirez 在 redis 的 [issue #2576](https://github.com/redis/redis/issues/2576) 里有完整解释，值得翻一下原帖。

本地起个 Redis 亲手算槽位，有 docker 就行：

```bash
# 注意 --cluster-enabled yes 不能省：默认 standalone 模式下 cluster keyslot 会直接报错
docker run -d --name redis-slot-test redis:7 \
  --cluster-enabled yes --cluster-config-file nodes.conf

# 三条命令返回同一个槽号：1649
docker exec redis-slot-test redis-cli cluster keyslot "user:1000"
docker exec redis-slot-test redis-cli cluster keyslot "{user:1000}.profile"
docker exec redis-slot-test redis-cli cluster keyslot "{user:1000}.orders"

# 用完删掉
docker rm -f redis-slot-test
```

`{user:1000}` 就是 hash tag：CRC16 只算大括号里的内容。同一个用户的 profile、orders 强制同槽，MSET、事务、Lua 这类多 key 操作才玩得起来——这也是"热点干预"的入口。

当然可控性也不是白拿的，Redis 多付了三笔：

- **元数据开销**：维护并传播槽位表，gossip 心跳里常年背着 2KB/节点
- **客户端门槛**：必须是 smart client（本地槽缓存 + MOVED/ASK 处理一样不能少）
- **多 key 受限**：跨槽操作不被支持，想一起操作，客户端得自己拆

### 迁移中间态：MOVED 和 ASK

（下面是面试支线，只关心选型的读者可以直接跳到第 6 节。）

迁槽不是原子操作，中间态靠两个重定向语义兜住，这也是面试高频：

| | MOVED | ASK |
|---|---|---|
| 含义 | 槽已永久易主 | 槽迁移中，仅本次去目标执行 |
| 客户端动作 | 更新本地槽表 | 只重试这一条，不改槽表 |
| 出现阶段 | 迁移完成后 | 迁移进行中 |

ASK 的正常走法，一次迁移中的读：

```text
客户端                源节点（旧槽主）         目标节点（新槽主）
  │──── GET k ─────►│                        │
  │                 │ k 还没迁过来           │
  │◄──── ASK 重定向 │                        │
  │──── ASKING + GET k ─────────────────────►│  只此一条走目标
  │◄──── 值 ─────────────────────────────────│  本地槽表不改
```

为什么 ASK 不能当 MOVED 记住？迁移中同一槽的 key 一半在源、一半在目标。

客户端若提前把槽表指向目标，未迁完的 key 会被查无此 key；目标节点对"未正式拥有"的槽还会回 MOVED 指回源——重定向死循环，请求在两台节点间打乒乓球。

顺带一句运维警告：`cluster-require-full-coverage yes`（默认开启）下，任何槽失去归属——负责它的节点宕机且无副本，或修复烂尾把槽弄成无主——整个集群会对**所有命令（含读）**回 CLUSTERDOWN，不止是拒写。迁槽迁到一半烂尾是另一种坏法：槽仍有主，不会 CLUSTERDOWN，但两端的 MIGRATING/IMPORTING 标记会残留，绊住后续迁移——要么迁完，要么 `SETSLOT STABLE` 清干净。

## 6. Kafka：分区是静态元数据，迁分区太痛

Kafka 的分片单位是分区（partition）。`hash(key)` 只决定"进哪个分区"，**分区到 broker 的映射是创建时写死的静态元数据**。

扩容 broker 之后：老分区纹丝不动，新 broker 只承接新建分区。新机器磁盘 0 增长不是故障，是设计如此——多少人在这一步怀疑人生。

官方不自动迁移的理由很直接：自动搬分区意味着带宽和 IO 的不可控消耗，对在线消息队列不可接受。

为什么说迁分区痛？一个分区动辄几十 GB，搬的是实打实的网络和磁盘吞吐；分区又是消费并行度的单位，搬一步要过 Leader 切换、副本追平，每一步都可能触发告警。所以 Kafka 宁可让新 broker 空跑，也不自动动它。

想搬，必须显式发起：

```bash
# 扩容前后各看一眼副本分布，亲眼看"新 broker 不在老分区副本列表里"
kafka-topics.sh --bootstrap-server localhost:9092 \
  --describe --topic orders
```

K8s 上用 Strimzi 的话，走 KafkaRebalance 两步流程（字段细节以[官方文档](https://strimzi.io/docs/)为准。apiVersion 注意：Strimzi 1.x 起是 `v1`，`v1beta2` 只适用于 0.22–0.4x 的老版本）：

```yaml
apiVersion: kafka.strimzi.io/v1
kind: KafkaRebalance
metadata:
  name: add-broker-3
spec:
  mode: add-brokers
  brokers: [3]
```

```bash
# 提案就绪后，人工 approve 才真正动数据
kubectl get kafkarebalance add-broker-3 -o wide
kubectl annotate kafkarebalance add-broker-3 strimzi.io/rebalance=approve
```

"提案 → 人工 approve"这个两步设计，就是官方给运维留的闸门：先看搬哪些分区、估多少字节，再决定动不动手。

顺带辟个谣，面试把这两个混说是硬伤：

- **消费组 rebalance**：分区在消费者之间重新分配，秒级、自动、可能形成风暴
- **分区再分配**：副本在 broker 之间搬迁，搬数据、手动、分钟到小时级

## 7. HDFS：块切分，压根没有"键空间"

HDFS 面对的是文件，不是 key-value。一个 10GB 文件直接按 `dfs.blocksize`（默认 128MB）切成约 80 个块。

每块独立选 3 个 DataNode 落位（机架感知放置：本机 → 远端机架 → 同机架另一台）。**分片 = 物理切块**，不存在"key 归属计算"，哈希和范围之争无从谈起。

新 DataNode 加入后也不重算任何映射，由 balancer 按容量百分比慢慢匀：

```bash
# 节点间磁盘利用率差距超过 10% 就搬块
hdfs balancer -threshold 10
```

代价是文件内没有记录级寻址——想按 key 查，得在上面盖一层：HBase 用 rowkey 范围，Hive 按分区列裁剪。

对比一下很直观：Redis 迁槽改的是"逻辑归属表"，需要客户端配合重定向；HDFS balancer 搬的是"物理块位置"，对客户端完全透明，读写照走 NameNode。

## 8. 一张表背下来

| | 一致性哈希 | Redis 16384 槽 | Kafka 分区 | HDFS 块 |
|---|---|---|---|---|
| 分片单位 | 环上的一段（隐式） | 槽（显式，2KB 位图） | 分区（显式元数据） | 块（物理切分） |
| 归属计算 | 顺时针找 vnode | CRC16 mod 16384 | key→分区，分区→broker 静态 | 文件偏移量切块 |
| 扩容语义 | 相邻段自动改判 | 手工迁槽，可暂停/回滚 | 不动老分区，手动再分配 | 块不变，balancer 匀总量 |
| 迁移量 | ~1/N（最小） | ~1/N（按槽计） | 按分区大小 | 按容量差 |
| 热点干预 | 不可（哈希决定） | 可（hash tag 定向） | 可（建分区时规划） | 不可（文件级） |
| 客户端复杂度 | 环缓存 | smart client + MOVED/ASK | 元数据订阅 | 直连 NameNode |

横向规律一句话：**越靠近存储底座（HDFS），分片越"物理"；越靠近在线服务（Redis/Kafka），分片越要成为可控的元数据**。

一致性哈希活在两者之间。Dynamo、Cassandra 这种对等节点、没有中心元数据服务的系统才是它的主场——归属表没有集中的存放处，也不像 Kafka 有中心 broker 存分区映射，环是唯一的选择。

## 9. 真到迁数据那天：先算三本账

选型聊完，补一段实战向的。再平衡 = 把数据从旧归属搬到新归属，动手前先算三本账，算不平就改期：

| 账本 | 算什么 | 锚点 |
|---|---|---|
| 迁移流量 | 搬移量走一遍网络和磁盘 | 1TB 走 1Gbps 理论 2 小时起步，叠加业务流量直接翻倍 |
| 源端压力 | Redis MIGRATE 是同步阻塞源节点单线程的命令 | 大批量小 key 能把源节点卡出超时 |
| 客户端感知 | ASK 重定向、消费组整组停顿、路由抖动 | 窗口期内的超时率要先有基线 |

迁移量怎么估？Redis 5 节点扩到 6 个，就是 16384/6 ≈ 2730 个槽、约 1/6 的数据。200GB 的集群约搬 33GB，再按网卡吞吐算时长，乘 2 留余量。

四条纪律，违反任何一条都是在赌：

1. **低峰执行**：迁移流量和业务高峰叠加，是最常见的"扩容引发故障"
2. **限速 + 可暂停**：Redis 迁槽天然可暂停（中间态有 ASK 兜着）；Cruise Control 的限流参数以[官方文档](https://linkedin.github.io/cruise-control/)为准
3. **盯住中间态完成度**：迁一半中途撂挑子比不迁更麻烦，前面说过标记残留绊住后续迁移、槽失去归属整集群回 CLUSTERDOWN 的下场
4. **避开连锁反应**：扩容、滚动发布、消费组 rebalance 别叠在同一个窗口，叠了就是"再平衡风暴"

MIGRATE 小批量是铁律：每批 10~100 个 key，批间盯源节点延迟和客户端超时率，随时可以停下来喘口气。

最后送一张踩坑速查表，都是真实事故里长出来的：

| 症状 | 根因 | 解法 |
|---|---|---|
| 扩容后集群反而更慢、超时 | 迁移流量撞上业务高峰；MIGRATE 大批次阻塞源端 | 低峰 + 小批量 + 限速，分多天迁 |
| 新 Kafka broker 磁盘 0 增长 | 分区是静态元数据，扩容不自动迁移 | KafkaRebalance 或 kafka-reassign-partitions.sh |
| 加了 2 个 Redis 节点，倾斜没改善 | CRC16 只匀键不匀流量 | 定位热点 key（`--hotkeys` 需先把 maxmemory-policy 临时设为 allkeys-lfu，它依赖 LFU 计数，默认 noeviction 下会直接报错；或改用 monitor / 客户端采样），hash tag 隔离或业务打散 |
| 整集群 CLUSTERDOWN，读写全停 | 槽失去归属：负责节点宕机且无副本，或修复烂尾把槽弄成无主；cluster-require-full-coverage 默认开启 | 让槽重新有主（恢复副本或 `SETSLOT NODE` 指定新主），应急可 `CONFIG SET cluster-require-full-coverage no` |
| 迁槽迁一半弃疗，后续迁移行为诡异 | 槽仍有主、不会 CLUSTERDOWN，但两端的 MIGRATING/IMPORTING 标记残留 | 要么迁完，要么两端 `SETSLOT STABLE` 清掉残留标记 |
| 滚动发布后消费组反复 rebalance | 发布 + 会话超时 + max.poll.interval 叠加成风暴 | cooperative-sticky、放宽超时、错开变更窗口 |

## 10. 现在就能做的一件事

把第 1 节的脚本跑一遍，亲眼看到 82.7% 对 15.7% 这两个数字，"最小迁移"从口号变成体感。82.7 和 15.7 之间的差距，就是一致性哈希存在的全部理由；而 Redis 用 16384 个槽拿到同样的数字，还额外拿到了可控性——这句话就是本文想让你带走的。

再进阶一步，用第 5 节的 docker 命令验证 hash tag，三条 `cluster keyslot` 返回同一个槽号，CRC16 只算大括号里的部分。

走之前聊个实的：你们公司扩 Redis 集群，走的是平滑迁槽，还是干脆双写重建切流？迁槽迁一半被叫停的，评论区说出你的故事。

这篇文章整理自我持续维护的 SRE 学习仓库 [sre-learning-hub](https://github.com/Thneoly/sre-learning-hub)。分片与再平衡那一章还有迁移窗口的三本账（迁移流量、源端压力、客户端感知）和防 rebalance 风暴的实操清单，感兴趣的可以翻翻。有帮助的话点个收藏，后续更新不迷路。
