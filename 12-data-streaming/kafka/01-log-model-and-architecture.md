# 01 · Kafka 日志模型与架构：分区、顺序 IO 与零拷贝

> 模块：12-data-streaming/kafka ｜ 建议时长：3 小时 ｜ 关联认证：—（CKA/CKS/PCA 无直接考点；本章是 Kafka 全部运维判断的地基，第 2 章副本机制、第 3 章容量与 lag 排障、Strimzi lab 都建立在这些概念上）

## 学习目标

- 能解释 topic / partition / offset 三层模型，说出"顺序性只在分区内成立"对业务设计的约束
- 能画出日志分段（segment）的文件布局，完整描述一次按 offset 查找的过程（文件名二分 → 稀疏索引二分 → 顺序扫描）
- 能说明顺序写、页缓存、sendfile 零拷贝三者如何共同支撑高吞吐，并回答"broker 为什么不自己在 JVM 里缓存数据"
- 能列出消费者组 rebalance 的触发条件与代价，拿到 rebalance 日志能判断是谁引起的
- 能根据吞吐与延迟目标选择生产者的 linger.ms / batch.size / compression.type 与幂等配置

版本约定：以 Apache Kafka 3.9（docker 镜像 `apache/kafka:3.9.0`，KRaft 模式）为准，涉及版本行为差异处单独标注，拿不准的以官方文档为准。

## 1. 三层模型：topic → partition → offset

Kafka 的存储单元不是"表"也不是"队列"，而是一组**只追加的日志文件**。三层模型：

```
topic orders（逻辑分类，运维建的对象）
 ├── partition 0   [0][1][2][3][4][5]…   ← append-only 日志，offset 单调递增
 ├── partition 1   [0][1][2][3][4][5]…
 ├── partition 2   [0][1][2][3][4][5]…
 └── partition 3   [0][1][2][3][4][5]…

一条消息（record）= (topic, partition, offset) 唯一定位
```

| 概念 | 是什么 | 运维关注点 |
|---|---|---|
| topic | 逻辑分类，跨 partition 不保序 | retention / 权限的管理单位 |
| partition | 最小存储与并行单元，一个有序日志 | 分区数 = 消费并行度上限；只能加不能减 |
| offset | 分区内消息的 64 位序号，broker 分配 | 消费位移、lag 监控的坐标系 |
| record | key + value + timestamp + headers | key 决定去哪个分区（murmur2 hash） |

分区路由规则：

- 有 key：`partition = murmur2(key) % 分区数`（带符号哈希值 & 0x7FFFFFFF 后取模），同 key 恒进同一分区——这是"业务实体内有序"的基础。
- 无 key：走 sticky 分区器（Kafka 2.4 起），先填满一个分区的 batch 再换下一个，比纯轮询减少请求次数；**代价是短时间内无 key 消息可能集中在一个分区**。

顺序性的边界：Kafka 只保证**单分区内**按写入顺序消费。需要全局有序的流（极少）只能单分区，等于放弃横向扩展；通常做法是"同一用户/同一订单的消息用同一个 key"，把顺序性收敛到实体级别。

另一个由模型决定的硬约束：**分区数只能加不能减**。减分区会让已有消息的 offset 无法定位（offset 是分区内坐标，删掉一个分区，剩余分区的 offset 语义就断了），Kafka 直接拒绝该操作。扩分区还会改变 key 的路由结果（取模的模数变了），扩之前要确认业务"同 key 必须同分区"的假设没有被打破。

## 2. 日志分段与顺序写

每个分区在磁盘上是一个目录（`<topic>-<partition>`），里面的日志被切成多个 **segment**：

```
orders-0/
├── 00000000000000000000.log        ← 消息本体；文件名 = 段内第一条消息的 offset（基准 offset）
├── 00000000000000000000.index      ← 相对 offset → 文件物理位置（稀疏索引）
├── 00000000000000000000.timeindex  ← timestamp → 相对 offset（按时间查找用）
├── 00000000000003500000.log        ← 基准 offset 为 3500000 的段（活跃段）
├── 00000000000003500000.index
├── 00000000000003500000.timeindex
└── leader-epoch-checkpoint         ← 每 32KB 记一次 (epoch, startOffset)，第 2 章的主角
```

滚动（rollover）条件，任一满足即开新段：

| 条件 | 默认值 | 说明 |
|---|---|---|
| 段大小达 `segment.bytes` | 1 GB | 吞吐大的 topic 主要靠它触发 |
| 段年龄达 `segment.ms`（`log.roll.ms`） | 7 天 | 低流量 topic 靠它，保证 retention 能删掉旧数据 |
| 索引写满 `segment.index.max.bytes` | 10 MB | 段没满但索引先满，也强制滚动 |

为什么追加写是 Kafka 吞吐的根基：机械盘顺序写与随机写差 2~3 个数量级，SSD 差距缩小但依然存在。数据库 B+ 树要为更新付出"原地改页 + 页分裂"的随机写代价；Kafka 的消息不可变，**写入永远是追加到活跃段尾部**，读旧数据与写新数据互不干扰。分区数多时，每个分区各自仍是顺序追加——把"大量随机写"变成"多路顺序写"。

运维上要理解 segment 是 **retention 删除的最小单位**：清理只删整个段文件，活跃段（正在写的那个）永远不能删。所以低流量 topic 若 7 天才滚一个段，retention=3 天实际上可能要 10 天后才开始释放磁盘——这也是"磁盘比预期满"的常见原因之一。

## 3. 稀疏索引：一条消息是怎么被找到的

`.index` 不是每条消息一条记录，而是**每写入 `index.interval.bytes`（默认 4096 字节）消息数据才追加一条**（稀疏索引），每条形如"相对 offset N → 文件物理位置 P"。查找 offset 3500233 的完整过程：

```
① 按文件名二分定位段：3500233 落在基准 3500000 的段（文件名本身是第一层索引）
② 在该段 .index 内二分，找 ≤ (3500233-3500000)=233 的最大条目
③ 从条目给的物理位置开始，在 .log 里顺序扫描，跳过 batch 头，直到目标 offset

.index 内容示意（每 4KB 消息记一条）：
  相对offset  物理位置
  0           0
  52          4096
  104         8192
  156         12288
        ▲ 二分命中 104 → 从 8192 处顺序扫描约 4KB 即可到目标
```

这个设计的取舍：

- 换来什么：索引体积极小（约为数据的 0.1% 量级），可以整块驻留内存；写入时索引维护成本几乎为零（4KB 才加一行）。
- 付出什么：定位不精确，最多多扫描 4KB——但这是**页缓存内的顺序扫描**，代价可忽略。
- 为什么不用 B+ 树（对比 MySQL InnoDB）：数据只追加、从不原地修改，不存在"改数据要同步改索引结构"的问题；且消费者几乎总是**顺序读**（追尾部），热点是活跃段尾部，天然在页缓存里。
- `.timeindex` 的用途：按 timestamp 查找（`kafka-get-offsets.sh --time <ts>`、消费者 `offsetsForTimes()`）以及按时间配置的 retention 判定，先在 timeindex 找到 timestamp 对应的 offset，再走上面流程。

## 4. 页缓存与零拷贝：broker 为什么不自己缓存

先看消费路径。**传统 read/write 方式**把文件发给网络要经历：

```
内核页缓存 → 拷贝到用户态(broker JVM) → 拷贝到内核 socket 缓冲 → NIC
            └──────── broker 只是把字节原样搬走，没做任何加工 ────────┘
4 次拷贝、4 次用户/内核态切换，数据还要在 JVM 堆里多放一份
```

Kafka 消费 Fetch 请求走 **sendfile（零拷贝）**：

```
磁盘 →(DMA)→ 页缓存 ──sendfile──→ NIC（NIC 支持 scatter/gather 时，页缓存数据不经过 CPU 拷贝）
2 次拷贝、2 次切换，broker 进程根本不碰消息内容
```

于是"broker 要不要在 JVM 里再做一层缓存"的答案就清楚了——**不要，OS 页缓存就是那层缓存**：

1. 页缓存按需驻留、按 LRU 淘汰：热分区数据自然留在内存，冷数据自然让给别的进程，不需要自己实现淘汰算法。
2. JVM 堆内缓存消息对象：要付出序列化/反序列化与 GC 代价，几十 GB 的缓存堆会让 GC 停顿放大 p99；缓存原始字节则失去对象语义，还不如页缓存。
3. broker 进程重启后页缓存依然有效（只有机器重启才丢），JVM 缓存则全部失效需要预热。
4. sendfile 的前提是"数据在页缓存里且用户态不需要加工"，自己缓存反而会破坏零拷贝路径。

运维推论（SRE 必须记住的三条）：

- 给页缓存留内存：`-Xmx` 惯例给 4~6 GB 即可，剩余物理内存全部留给页缓存；理想目标是**最近消费的热数据（约等于消费者追尾窗口）能整体装进缓存**。
- 禁 swap：`vm.swappiness=1`。页缓存被换出等于零拷贝路径失效、延迟毛刺。
- 监控 `/proc/meminfo` 的 `Cached` 与 broker 所在盘的读 IO：消费追尾型负载下磁盘读 IOPS 应接近 0，全靠缓存命中；如果读 IO 持续高，说明缓存不够或消费者在大量回溯读历史。

## 5. 消费者组与分区分配

消费者按 **consumer group** 组织：同组的消费者**分摊**一个（或一组）topic 的所有分区，一个分区在同一时刻只被组内一个消费者消费；不同组之间互不影响，各自维护自己的位移——这就是一条消息可以被多个下游系统独立消费的原因（广播给组、单播给成员）。

```
group: order-workers                     group: billing (互不影响)
  consumer A ── p0, p3                     consumer X ── p0..p5 (只有它一个)
  consumer B ── p1, p4
  consumer C ── p2, p5
若 consumer C 退出 → rebalance → A/B 各分走 p2、p5
若组内 7 个消费者、6 个分区 → 6 个干活，1 个纯备份（消费者数上限 = 分区数）
```

机制要点：

- **group coordinator**：每个组在某个 broker 上有一个协调者（按 group 哈希到 `__consumer_offsets` 的某分区，其 leader 所在 broker 即协调者），负责入组、分配触发、位移提交。
- **分配策略**由消费者侧配置 `partition.assignment.strategies` 决定：`RangeAssignor`（按 topic 逐个切区间，容易不均）、`RoundRobinAssignor`（全 topic 轮询）、`StickyAssignor`（尽量保持上次分配，减少迁移）、`CooperativeStickyAssignor`（增量协作式，KIP-429，rebalance 期间不停止全组消费）。新集群建议 cooperative-sticky。
- 位移存在内部 topic `__consumer_offsets`（默认 50 个分区、compact 清理），第 2 章展开提交语义。

## 6. Rebalance：触发条件与代价

rebalance 是"重新计算谁消费哪些分区"的过程，触发条件只有三类：

| 类别 | 具体事件 | 典型日志特征 |
|---|---|---|
| 组成员变化 | 新消费者加入；消费者优雅关闭；消费者 crash / 心跳超时（`session.timeout.ms` 内无 heartbeat）；处理超时（`max.poll.interval.ms` 内没有再 poll） | `Member ... left group` / `Attempt to heartbeat failed` |
| 订阅变化 | 正则订阅匹配到新建 topic；订阅 topic 集合变化 | `Subscribed topic ... changed` |
| 分区数变化 | 已订阅 topic 增加分区 | `... partition count changed` |

代价：eager 策略（range/roundrobin/sticky 的默认行为）下 rebalance 是 **stop-the-world**——所有成员停止消费、放弃已拉取未处理完的任务，等分配完成后重新 poll。大组一次 rebalance 数秒到数十秒，期间该组 lag 直线上扬。

运维要点是区分**正常与异常** rebalance：

- 正常：发布滚动更新（每个实例重启都触发一次）、扩缩容。
- 异常：消费者处理一批 `max.poll.records` 的耗时超过 `max.poll.interval.ms`（默认 5 分钟）→ 被协调者踢出 → rebalance → 其余实例分到更多分区 → 更容易再超时，形成"rebalance 风暴 + lag 雪崩"的正反馈。这是第 3 章排障表里的头号场景，解法是减小单批处理量（`max.poll.records`）、加大 `max.poll.interval.ms`，或用 `group.instance.id` 静态成员让滚动发布不触发 rebalance。

## 7. 生产者：批次、压缩、幂等

生产端把"每条消息一个请求"变成"一批消息一个请求"，这是吞吐的第一杠杆：

```
producer.send(record)
   │ ① 分区器：key 的 murmur2 hash 选分区（无 key → sticky 轮换）
   ▼
RecordAccumulator（每个分区一个待发队列）
   │ ② 攒批：batch.size(默认 16KB) 写满 或 linger.ms(默认 0ms) 到期，先到先发
   ▼
sender 线程 ──③ 压缩（producer 端做）──> 请求 ──④ 幂等(PID+seq)──> broker
```

- **linger.ms**：等待攒批的时间上限。默认 0（立即发，延迟最低、吞吐最差）；改成 5~20ms 通常能让吞吐明显上升而 p99 增量可控。**batch.size 不是"必须攒满才发"**，它只是上限，二者任一满足即发送。
- **压缩**在生产端完成，压缩后的 batch 原样落盘（broker 端 `compression.type` 与生产端一致时不重新编解码，还省网络与磁盘）。选型：

| 算法 | CPU | 压缩比 | 适用 |
|---|---|---|---|
| lz4 | 极低 | 中 | 通用推荐，CPU 紧张时的默认选择 |
| snappy | 低 | 中 | 老系统兼容 |
| zstd | 中 | 高 | 带宽/磁盘贵的场景，吞吐与压缩比兼顾 |
| gzip | 高 | 高 | 极端省带宽、不在意 CPU，一般不选 |

- **幂等**（`enable.idempotence=true`，3.0 起默认开启）：producer 启动时从 broker 领取 PID，给每个 `<PID, partition>` 维护递增 sequence number；broker 端对每个批次按 seq 去重窗口校验，重试导致的重复写入会被拒绝。约束：`max.in.flight.requests.per.connection <= 5` 且 `acks=all` 时，5 个以内的在途请求乱序也能靠 seq 重排，**跨会话（重启后 PID 变）与跨分区不保证**——那是事务（transactional producer）的职责。
- `retries`（3.0 起默认 Integer.MAX_VALUE）受 `delivery.timeout.ms`（默认 2 分钟）这个总预算封顶：超时就抛 `TimeoutException`。调优时改总预算，不要单独调 retries。

## 实战演练

环境：装有 Docker 的 Ubuntu VM（下同，命令统一标注 `[任意节点]`）。

```bash
# [任意节点] 起单节点 KRaft Kafka（官方镜像开箱即用，PLAINTEXT 9092）
docker run -d --name kafka-single -p 9092:9092 apache/kafka:3.9.0
```

```bash
# [任意节点] 建一个小分段的 topic，便于观察 segment 滚动（index.interval.bytes 调小让稀疏索引更快出现多条）
docker exec kafka-single /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic demo --partitions 1 --replication-factor 1 \
  --config segment.bytes=10240 --config index.interval.bytes=1024 --config retention.ms=3600000
```

```bash
# [任意节点] 灌入约 2000 行消息（每行约 40 字节，会滚出多个 10KB 的段）
docker exec kafka-single bash -c \
  'for i in $(seq 1 2000); do echo "message-number-$i-with-some-padding-padding"; done | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic demo'
```

```bash
# [任意节点] 观察 segment 布局（apache/kafka 镜像默认 log.dirs=/tmp/kraft-combined-logs，
# 可先 docker exec kafka-single grep '^log.dirs' /etc/kafka/server.properties 确认）
docker exec kafka-single ls -lh /tmp/kraft-combined-logs/demo-0/
# 预期：多组 20 位数字命名的 .log/.index/.timeindex；活跃段正在增长，旧段已封闭

# 看稀疏索引内容：每 1KB 消息才一条，offset 之间有跳变
docker exec kafka-single /opt/kafka/bin/kafka-dump-log.sh \
  --files /tmp/kraft-combined-logs/demo-0/00000000000000000000.index
# 预期形如：
#   Dumping /tmp/kraft-combined-logs/demo-0/00000000000000000000.index
#   offset: 0 position: 0
#   offset: 27 position: 1024
#   offset: 54 position: 2048

# 看消息本体：注意结构是 RecordBatch（批次）而非单条
docker exec kafka-single /opt/kafka/bin/kafka-dump-log.sh \
  --files /tmp/kraft-combined-logs/demo-0/00000000000000000000.log --print-data-log | head -20
# 预期：baseOffset/lastOffset/batchLength/compressor 等批次头部字段，再跟记录内容
```

```bash
# [任意节点] 消费者组与 lag 的原始形态：先消费 300 条，再看组状态
docker exec kafka-single /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic demo --group lab \
  --from-beginning --max-messages 300 > /dev/null

docker exec kafka-single /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --describe --group lab
# 预期：CURRENT-OFFSET=300（组位移，提交到了 __consumer_offsets）
#       LOG-END-OFFSET=2000（分区 LEO）  LAG=1700
```

```bash
# [任意节点] 验证页缓存吃下了全部数据：写入 80KB 后 Cached 常驻，broker 堆内存基本不动
docker exec kafka-single cat /proc/meminfo | grep -E '^Cached|^SwapCached|^SwapTotal'
# 预期：Cached 至少几十 MB（含镜像层与消息），SwapTotal/SwapFree 为 0（容器环境常见）
```

验证方法：`kafka-dump-log.sh` 的 index 输出能与第 3 节示意图对上；consumer-groups 的 LAG 列等于 `LOG-END-OFFSET - CURRENT-OFFSET`。做完清理：`docker rm -f kafka-single`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 业务说"消息乱序了" | 跨分区本来就不保序，key 不稳定或无 key | 同一实体用稳定 key；需要严格全局有序只能单分区 |
| topic 只有 1 个分区，消费者再怎么加实例也不快 | 分区数是并行度上限 | 扩分区（只能加不能减，历史消息不动） |
| producer 吞吐低、CPU 高、broker 端请求量大 | linger.ms=0 + 小消息，每个小批次一个请求 | linger.ms 5~20ms + lz4/zstd 压缩 |
| 新建消费组从头没读到数据 | `auto.offset.reset` 默认 latest，组无位移时从最新开始 | 需要回放时显式配 earliest |
| 无 key 消息短时间集中到个别分区 | sticky 分区器行为，batch 未满不切换 | 接受（吞吐优先）或显式指定 key/partition |
| `kafka-dump-log.sh` 报 file not found | 活跃段文件名随滚动变化，拷命令时用了旧文件名 | 先 ls 目录再取真实文件名 |

## 自测

1. 按 offset 查一条消息的完整路径是什么？如果把 `.index` 改成每条消息一条记录（稠密索引），会付出什么、换到什么？
<details><summary>答案</summary>

路径：按 segment 文件名二分定位段 → 在该段 .index 二分找到 ≤ 目标相对 offset 的最大条目 → 从物理位置在 .log 顺序扫描到目标。改成稠密索引换到"一次精确定位、无需扫描"，付出的是：索引体积放大约两个数量级（每条消息一行），无法整块驻留内存，写入时索引维护从"每 4KB 一行"变成"每条一行"，追加路径被拖慢；而省掉的只是页缓存内 4KB 顺序扫描，得不偿失。Kafka 的读以追尾为主，本来就不常做随机定位。
</details>

2. 为什么给 broker 配 31 GB 大堆反而可能更糟？正确的内存分配姿势是什么？
<details><summary>答案</summary>

大堆意味着 JVM 自己当缓存：GC 管理几十 GB 堆，停顿时间与频率上升，p99 毛刺；消息在堆内要以对象或字节形式存在，多一份序列化开销；重启后堆缓存全丢需要预热；最关键的是破坏 sendfile 零拷贝路径——数据必须进用户态才能"被缓存"，反而变慢。正确姿势：堆给 4~6 GB 存元数据与请求缓冲，其余物理内存留给页缓存，禁 swap，让 OS 替你缓存且不受 GC 影响。
</details>

3. 消费者单批处理要 8 分钟，`max.poll.interval.ms` 默认 5 分钟，会发生什么连锁反应？给出至少两种修法。
<details><summary>答案</summary>

poll 之后 8 分钟不调下一次 poll，超过 max.poll.interval.ms，协调者认为该成员死亡，把它踢出组并触发 rebalance；被踢的消费者处理完后提交位移被拒（IllegalGeneration），其余成员分走它的分区、负载更重、更容易超时，形成 rebalance 风暴与 lag 雪崩。修法：减小 max.poll.records 让单批处理回到 5 分钟内；或调大 max.poll.interval.ms；处理逻辑异步化，poll 循环只负责拉取与暂停分区；用 cooperative-sticky 缩小 rebalance 波及面。
</details>

4. linger.ms 从 0 调到 100，对吞吐、延迟、acks=all 的端到端时延分别有什么影响？
<details><summary>答案</summary>

吞吐：批次变大、请求变少，通常显著上升（CPU 每请求固定开销被摊薄）。延迟：最好情况下多等 100ms（linger 到期就发），但注意它是上限而非固定延迟——批次先满会提前发。acks=all 时端到端时延 = linger + 一整条 ISR 链路的落盘确认，min.insync.replicas 越大、跨机房 ISR 越多，链路越长，100ms 的攒批占比反而越小。对延迟极敏感（<50ms）的流用 0~5ms，普通管道 5~20ms 是常见起点。
</details>

5. 无 key 消息用 sticky 分区器，对消费端位移语义有什么潜在影响？
<details><summary>答案</summary>

无 key 时同一条业务记录没有"必去某个分区"的约束，重试/重发可能落到不同分区、不同 offset，消费者无法靠 (分区, offset) 或 key 做精确去重，只能靠消息内业务幂等键。另外短时间集中一个分区会让该分区 lag 突增、分区数据倾斜，监控上表现为个别分区 LOG-END-OFFSET 增速远高于其他分区。需要实体级有序或幂等语义时应显式给 key。
</details>

## 延伸阅读

- 官方设计文档（顺序 IO、页缓存、零拷贝的设计动机）：https://kafka.apache.org/documentation/#design
- 官方实现细节（日志格式、索引、sendfile）：https://kafka.apache.org/documentation/#impl
- 消费者配置（max.poll.interval.ms 等语义）：https://kafka.apache.org/documentation/#consumerconfigs
- 生产者配置（幂等、批次、delivery.timeout.ms）：https://kafka.apache.org/documentation/#producerconfigs
- KIP-429 增量协作式 rebalance：https://cwiki.apache.org/confluence/display/KAFKA/KIP-429%3A+Kafka+Consumer+Incremental+Rebalance+Protocol
