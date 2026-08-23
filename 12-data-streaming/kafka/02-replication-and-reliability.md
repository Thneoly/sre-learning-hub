# 02 · Kafka 副本与可靠性：ISR、HW/LEO 与 leader epoch

> 模块：12-data-streaming/kafka ｜ 建议时长：3 小时 ｜ 关联认证：—（无直接考点；本章回答"Kafka 什么情况下丢数据"，是 acks/min.insync.replicas 参数评审与故障复盘的依据）

## 学习目标

- 能画出 leader/follower/ISR 的关系图，解释 LEO 与 HW 的差别，以及"消费者只能读到 HW 之前的消息"的原因
- 能复述 leader epoch 机制要解决的两个问题：旧协议按高水位截断导致的数据丢失与日志不一致
- 能给出 acks 0/1/all × min.insync.replicas 的组合矩阵，按业务容忍度选择可靠性方案
- 能解释 unclean leader election 的数据丢失窗口与开启它的前提
- 能说明 Controller 的职责、KRaft 替代 ZooKeeper 的动机，以及位移提交的三种方式与重复消费窗口

## 1. 复制模型：每个分区一个 leader

可靠性来自多副本：每个分区有 1 个 **leader** 副本和 N-1 个 **follower** 副本。生产写与元数据请求始终走 leader；消费读默认也走 leader，但 Kafka 2.4+（KIP-392）起，配置了 `client.rack` 的消费者可以直接从最近的 follower 副本 fetch 数据（只影响消费读路径，不改变写路径）。follower 的本职工作则是不停地向 leader 发 Fetch 请求，把数据抄回来。

```
             ┌──── 写（读默认亦走 leader）────┐
producer ───►│ partition-0 leader(A) │◄─── consumer
             └──────┬──────┬─────────┘
        Fetch(pull) │      │ Fetch(pull)
             ┌──────▼─┐ ┌──▼───────┐
             │foll(B) │ │ foll(C)  │   follower 落后则被移出 ISR
             └────────┘ └──────────┘
```

为什么是 follower pull 而不是 leader push：follower 自己控制追赶节奏（重启后从上次位置继续）；Fetch 请求本身就是"我还活着"的心跳与位移汇报，不需要第二套保活协议；push 模型还要处理 follower 满载时的反压。这个设计与第 1 章"消费者也是 pull"一脉相承——**背压天然存在，不需要显式流控**。

## 2. LEO 与 HW：消费者能读到哪

两个关键水位，每个副本上各自维护：

- **LEO（Log End Offset）**：本副本日志的下一条待写 offset，即"日志长到了哪"。
- **HW（High Watermark / 高水位）**：所有 ISR 副本都已完成复制的位置（取 ISR 各副本 LEO 的最小值）。**消费者只能读到 HW 之前的消息**。

```
leader A:      [0][1][2][3]  LEO=4
follower B:    [0][1][2][3]  LEO=4（已追平）
follower C:    [0][1]        LEO=2（落后）
ISR = {A,B,C}（C 还没超时被踢）
HW = min(LEO of ISR) = 2      ← 消费者最多读到 offset 1

C 追平后：HW 推进到 4，offset 2、3 对消费者可见
```

为什么消费者不能越过 HW：如果允许读 leader 上尚未复制的消息，随后 leader 宕机、新 leader 没有这段数据，消息会被截断——消费者就"读到了一条未来会消失的消息"，下游处理（写库、发通知）已经发生，无法撤回。HW 是"至少已被 ISR 集体确认"的承诺边界。

推论（运维要能秒答的两条）：

- **消费延迟的组成里有一段是复制延迟**：acks=all 的场景下，消息从生产到可见 = 生产 + ISR 全部落盘 + HW 推进（HW 靠下一轮 Fetch 才能推进，存在一个 RPC 周期的滞后）。跨机房 ISR 会让这段明显放大。
- broker 端日志里 `shrink ISR` / `expand ISR` 伴随的 offset 就是 HW 变动的现场，排障时先把这条时间线拉出来。

## 3. ISR：动态同步副本集

**ISR（In-Sync Replicas）** = leader + 所有"跟得上"的 follower。判定标准只有一个：`replica.lag.time.max.ms`（默认 30 秒）内有没有追上 leader 的日志末端（即 Fetch 是否持续到达）。注意判定的是**时间**而不是落后条数——落后 1 亿条但仍在持续 Fetch 的 GC 停顿恢复期副本，30 秒内追平就留在 ISR；彻底断连的立刻出局。

- 收缩：follower 超时 → leader 把它移出 ISR，写一段特殊的 ISR 变更记录到日志（KRaft 下进元数据日志），HW 重新按剩余 ISR 计算。
- 扩张：follower 追上 leader LEO → leader 把它加回 ISR。
- 与同步复制的关系：**ISR 是"候选确认集"**，acks=all 只等 ISR 成员，不是等所有副本。这使 Kafka 的持久化语义是"ISR 多数可用即不丢已确认消息"（配合下面 min.insync.replicas 使用），而不是固定多数派（quorum）：ISR 可能收缩到 1，此时 acks=all 退化成 acks=1——这正是 min.insync.replicas 存在的原因。
- 分区维度的 `replicas / isr` 状态用 `kafka-topics.sh --describe` 直接可见，`UnderReplicatedPartitions` 计数（第 3 章告警）统计的是 isr 数 < 副本数的分区。

## 4. leader epoch：数据丢失与不一致的演进故事

这是 Kafka 复制协议最重要的演进（KIP-101，Kafka 0.11 引入），也是理解"为什么旧版本会悄悄丢数据"的关键。

**0.11 之前的问题：副本恢复时按"自己的 HW"截断日志。** 看一个时间线（A=leader，B=follower，两者 LEO=4，但 HW 还停在 2——HW 靠下一轮 Fetch 才推进，天然滞后）：

```
场景一：数据丢失（旧协议）
t0  A:[0..3] HW=2   B:[0..3] HW=2     B 已抄完数据，只是 HW 尚未推进
t1  B 重启 → 按本地 HW=2 截断，删掉 offset 2、3
t2  A 宕机；B 是 ISR 中唯一存活者 → B 当选新 leader
t3  生产者写入新消息，B 从 offset 2 开始分配（内容已不是原来的 2、3）
t4  A 恢复成为 follower → 也按旧 HW 截断对齐
结果：offset 2、3 上"已复制到 A、B 两副本（acks=all 下甚至可能已向生产者返回
      成功）"的数据被新数据静默覆盖 —— 数据丢失。注意此刻 HW=2，消费者还读不到
      2、3：丢的是"已确认写入"的数据，不是"已被消费"的数据
```

```
场景二：日志不一致 / 分叉（旧协议）
t1' B 重启截断到 HW=2；A 仍存活继续当 leader
t2' A 后来宕机，B 当选，接受新写入 offset 2 起
t3' A 恢复后向 B 发 Fetch：A 的 LEO=4 与 B 的 LEO 对不上，
    旧协议没有一个权威依据判断"从哪截断"，两个副本可能在同一 offset
    上长期持有不同内容 → 消费者换副本读，可能读到另一份历史
```

**0.11+ 的修复：每个副本维护 leader epoch 历史**（每次 leader 变更 epoch+1，并记录该 epoch 的起始 offset），follower 重启/恢复时不再看本地 HW，而是先问 leader：

```
follower B（epoch=1, LEO=4）重启
  │ OffsetsForLeaderEpoch 请求：epoch=1 我抄到 4，你那边 epoch=1 到哪？
  ▼
leader（epoch=2）应答：epoch=1 已结束，其 endOffset=4（与 B 一致，无需截断）
  │ 若应答 endOffset=2（说明 B 手里的 epoch=1 数据是分叉的）
  ▼
B 只截断到 2（divergence point），再从新 epoch 拉取
```

截断点由**当前 leader 依据元数据日志给出**，而不是 follower 拿着一份可能过期的本地水位自作主张——这就是两个问题同时被解决的原因：不会多删（丢数据场景），也不会少删（分叉场景）。HW 依旧承担"消费者可见性"职责，但**不再承担"副本对齐"职责**。

## 5. acks 与 min.insync.replicas：可靠性组合矩阵

生产者 `acks` 决定 broker 什么时候回 ACK；topic 级 `min.insync.replicas` 决定 ISR 至少要有几个副本才允许写入。设 replication.factor=3（下表"挂 N 台"指同时不可用）：

| 组合 | 语义 | 挂 1 台 | 挂 2 台 | 适用 |
|---|---|---|---|---|
| acks=0 | 发出去就算成功，不等 broker | 可能丢 | 可能丢 | 采样/指标类，丢了无所谓 |
| acks=1 | leader 落盘即 ACK | leader 挂且未同步 → 丢 | 丢 | 日志、可容忍少量丢失 |
| acks=all, min.insync.replicas=1 | ISR 可收缩到 1 后退化为 acks=1 | 可能丢 | 可能丢 | 名义上是 all，实际不可靠 |
| **acks=all, min.insync.replicas=2** | ISR<2 时 broker 拒绝写入（`NotEnoughReplicasException`） | 不丢已确认数据，可写 | **不可写**（可用性换一致性），恢复后自动可写 | 计费、订单、大多数业务管道 |
| acks=all, min.insync.replicas=3 | 任何一台挂都无法写入 | 不可写 | 不可写 | 几乎不用：RF=3 时把可用性降为 0 |

三个必须记住的细节：

1. **min.insync.replicas 只约束 acks=all 的写入**；acks=0/1 的生产者完全不受它影响。
2. "挂 2 台不可写"的表现是生产端持续抛 `NotEnoughReplicasException`，消费者不受影响（HW 之前的消息照常可读）——这是**用可用性换不丢数据**的显式权衡，值班时要能向业务解释。
3. 推荐基线：`RF=3 + min.insync.replicas=2 + acks=all + enable.idempotence=true + unclean.leader.election.enable=false`，即"容忍任意单机故障，不丢已确认消息，不静默降级"。

## 6. Unclean 选举：把丢失从"拒绝"变成"接受"

默认 `unclean.leader.election.enable=false`：当 ISR 里没有存活副本时，Kafka **宁可分区不可用**（leader=-1，无 leader 状态），也不让落后的副本（不在 ISR 内）当选——因为落后副本一旦当选，它没有的那段消息会被截断丢弃。

开启 true 则相反：从非 ISR 副本里选一个当 leader，分区尽快恢复读写，代价是**上一次 HW 之后、旧 leader 上已确认的数据直接丢失**，且丢多少不可预知。什么时候有人开：纯日志/行为埋点流，业务明确"可用性 > 完整性"；或者三副本全宕、等着数据从 ISR 恢复遥遥无期的极端救援。改这个参数等于改产品语义，必须业务方签字，不能运维单方面拍板。

## 7. Controller 与 KRaft：替代 ZooKeeper 的演进

**Controller** 是集群的大脑（任意时刻只有一个 active）：负责分区 leader 选举、broker 上下线处置、分区副本分配、topic/配置等元数据变更下发、preferred leader 均衡。broker 掉线时，controller 逐个把该 broker 上的 leader 分区切给 ISR 内其他副本——这就是"broker 挂了，`kafka-topics --describe` 里 Leader 换人"的幕后动作。

ZooKeeper 时代的痛点：

- 元数据存在 ZK 里，broker 启动要全量拉取并 watch；分区数上万时 controller 切换（重新注册 watch、全量对比）要分钟级，且容易 watch 风暴。
- 运维要同时养两套有状态系统（Kafka + ZK），证书、快照、扩缩容、备份都是双份成本。
- controller 故障转移状态不透明，恢复时长不可控。

**KRaft（KIP-500）**：把元数据本身变成一条 raft 复制的日志（`__cluster_metadata`），由 3~5 个 controller 节点组成多数派仲裁：

```
KRaft 模式
┌──────────────── controller 仲裁组（raft majority）────────────────┐
│  controller-1   controller-2   controller-3                        │
│      └──────────── __cluster_metadata 日志（顺序追加、多数派提交）──┘
└────────────┬───────────────────────┬───────────────────────┬──────┘
        broker-1                broker-2                broker-3
        （从元数据日志增量快照同步，不再依赖外部系统）
```

收益：元数据变更有序、可回放，集群只有一个事实来源；broker 重启只拉增量；controller 切换秒级。演进时间线：2.8 引入（preview）→ 3.3 生产可用 → 3.5 弃用 ZK 模式 → **4.0 移除 ZK**。运维差异：查仲裁状态用 `kafka-metadata-quorum.sh --describe --status`（替代"看 ZK 里 /controller"），安装部署少一个组件（本文所有 docker 实验都是 KRaft 单容器/多容器直起）。节点可以混合部署（broker+controller 同进程，小集群常用）或分离（大集群）。

## 8. 位移提交语义

消费位移（"我读到哪了"）本身也是消息：key = `groupId+topic+partition`，value = offset，写入内部 topic **`__consumer_offsets`**（默认 50 分区、`cleanup.policy=compact`——只需要每个 key 的最新值，绝不能按时间删，否则位移丢失会触发整 topic 重放）。协调者按 key 哈希决定写哪个分区。

三种提交方式与重复窗口：

| 方式 | 行为 | 风险 |
|---|---|---|
| 自动提交 `enable.auto.commit=true`（默认，间隔 5s） | poll 时后台提交"上一批 poll 返回的位移" | 消息还没处理完就可能已提交 → 崩溃后这批**丢失**（at-most-once 倾向）；反过来处理完但未到提交点就崩溃 → **重复** |
| `commitSync()` | 阻塞、失败自动重试 | 停顿消费循环；关停前最后一笔用 |
| `commitAsync()` | 非阻塞，可带回调 | 失败可能被后续成功覆盖（乱序确认），不能无回调裸用 |

语义取决于"处理"与"提交"的先后：**先处理后提交 = at-least-once**（崩溃时重复消费，配合业务幂等键）；先提交后处理 = at-most-once（崩溃时丢）。Kafka 客户端默认配置是"自动提交 + 先处理后提交"的近似 at-least-once。跨读处理写 Kafka 的端到端 exactly-once 需要事务 producer（`transactional.id`），Flink 章节会用到这个能力。

## 实战演练

环境：装有 Docker 与 docker compose 插件的 Ubuntu VM（下同）。单 broker 看不出 ISR 行为，这次起 3 节点 KRaft 集群，用 `docker pause` 模拟"活着但不干活"的半死状态（比 stop 更接近真实故障——进程还在，只是网络/IO 断了）。

```bash
# [任意节点] 写 compose 文件 kafka3.yaml（三节点 KRaft；replica.lag.time.max.ms 调小让 ISR 收缩在 10 秒内可见）
mkdir -p ~/kafka-lab && cat > ~/kafka-lab/kafka3.yaml <<'EOF'
x-kafka-common: &kafka-common
  image: apache/kafka:3.9.0
  environment: &kafka-env
    KAFKA_PROCESS_ROLES: broker,controller
    KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka1:9093,2@kafka2:9093,3@kafka3:9093
    KAFKA_LISTENERS: PLAINTEXT://:9092,CONTROLLER://:9093
    KAFKA_LISTENER_SECURITY_PROTOCOL_MAP: CONTROLLER:PLAINTEXT,PLAINTEXT:PLAINTEXT
    KAFKA_CONTROLLER_LISTENER_NAMES: CONTROLLER
    KAFKA_INTER_BROKER_LISTENER_NAME: PLAINTEXT
    KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR: 3
    KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR: 3
    KAFKA_TRANSACTION_STATE_LOG_MIN_ISR: 2
    KAFKA_DEFAULT_REPLICATION_FACTOR: 3
    KAFKA_MIN_INSYNC_REPLICAS: 2
    KAFKA_REPLICA_LAG_TIME_MAX_MS: 10000
    CLUSTER_ID: MkU3OEVBNTcwNTJENDM2Qg
services:
  kafka1:
    <<: *kafka-common
    hostname: kafka1
    environment:
      <<: *kafka-env
      KAFKA_NODE_ID: 1
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka1:9092
  kafka2:
    <<: *kafka-common
    hostname: kafka2
    environment:
      <<: *kafka-env
      KAFKA_NODE_ID: 2
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka2:9092
  kafka3:
    <<: *kafka-common
    hostname: kafka3
    environment:
      <<: *kafka-env
      KAFKA_NODE_ID: 3
      KAFKA_ADVERTISED_LISTENERS: PLAINTEXT://kafka3:9092
EOF
docker compose -f ~/kafka-lab/kafka3.yaml up -d
```

```bash
# [任意节点] 建 1 分区 3 副本的 topic，观察 Leader / Replicas / Isr
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka1:9092 \
  --create --topic pay --partitions 1 --replication-factor 3 --config min.insync.replicas=2

docker exec kafka1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka1:9092 --describe --topic pay
# 预期：Partition: 0  Leader: 1  Replicas: 1,2,3  Isr: 1,2,3
```

```bash
# [任意节点] acks=all 写入并确认，然后 pause kafka3（模拟副本半死）
docker exec kafka1 bash -c \
  'for i in $(seq 1 100); do echo "pay-$i"; done | /opt/kafka/bin/kafka-console-producer.sh \
   --bootstrap-server kafka1:9092 --topic pay --producer-property acks=all'

docker pause kafka3 && sleep 15

docker exec kafka1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka1:9092 --describe --topic pay
# 预期：Isr: 1,2      ← kafka3 被移出 ISR（10 秒没追上）
# acks=all + min.insync.replicas=2 仍然可写：
docker exec kafka1 bash -c \
  'echo "still-ok" | /opt/kafka/bin/kafka-console-producer.sh \
   --bootstrap-server kafka1:9092 --topic pay --producer-property acks=all'
```

```bash
# [任意节点] 再 pause 一台，ISR=1 < min.insync.replicas=2，写入被拒绝
docker pause kafka2 && sleep 15

docker exec kafka1 bash -c \
  'echo "should-fail" | /opt/kafka/bin/kafka-console-producer.sh \
   --bootstrap-server kafka1:9092 --topic pay --producer-property acks=all 2>&1 | tail -5'
# 预期：org.apache.kafka.common.errors.NotEnoughReplicasException:
#       The number of insync replicas for [pay,0] is [1], short of required [2]
# 这就是第 5 节矩阵里"挂 2 台不可写"的现场：拒绝写入，不丢已确认数据
```

```bash
# [任意节点] 恢复并观察 ISR 扩张；顺便看 KRaft 仲裁与 __consumer_offsets
docker unpause kafka2 kafka3 && sleep 20
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka1:9092 --describe --topic pay
# 预期：Isr 回到 1,2,3

# KRaft 元数据仲裁状态（替代 ZK 时代看 /controller）
docker exec kafka1 /opt/kafka/bin/kafka-metadata-quorum.sh \
  --bootstrap-server kafka1:9092 describe --status
# 预期：ClusterId / LeaderId / HighWatermark 等字段，3 个 voter

# 位移 topic：50 分区、compact 清理策略
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka1:9092 \
  --describe --topic __consumer_offsets | head -2
# 预期：Topic: __consumer_offsets ... Cleanup policy: compaction，PartitionCount: 50

# 确认 unclean 选举默认关闭
docker exec kafka1 /opt/kafka/bin/kafka-configs.sh --bootstrap-server kafka1:9092 \
  --entity-type brokers --entity-name 1 --all 2>/dev/null | grep unclean
# 预期：unclean.leader.election.enable=false
```

验证方法：三步 describe 的 Isr 变化（3 → 2 → 回 3）与 NotEnoughReplicasException 的出现/消失一一对应。做完清理：`docker compose -f ~/kafka-lab/kafka3.yaml down`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 生产端大量 `NotEnoughReplicasException` | ISR 收缩到 min.insync.replicas 以下（多为某 broker 掉线/慢盘） | 先救 ISR（第 3 章排障表）；不要为此调小 min.insync.replicas |
| 消费 lag 稳定但"新消息要几秒才能读到" | 消费可见性受 HW 推进影响：跨机房 ISR 复制 + HW 滞后一个 Fetch 周期 | 同机房/同 AZ 放 ISR；接受该延迟，它是不丢语义的代价 |
| 两个副本日志大小对不上、消费者换组重放结果不同 | 极旧的 0.11 前版本分叉问题 | 升级；用 leader epoch 机制下的新版本，不再出现 |
| RF=3 但 `Isr` 长期只有 1 | follower 磁盘慢/网络丢包，一直追不上 | 查 `replica.lag.time.max.ms` 窗口内的 fetch 延迟、磁盘 util、`num.replica.fetchers` |
| 认为"acks=all 就绝对不丢" | ISR 可收缩；unclean 选举开启时仍可能丢 | acks=all 必须搭配 min.insync.replicas>=2 且 unclean=false |
| 重启消费者后整 topic 被重放 | `__consumer_offsets` 位移丢失（误删/compact 误配/组换了名字） | 不要动内部 topic；排查 `auto.offset.reset` 与 groupId 拼写 |
| 新集群起不来，日志报 quorum 相关错误 | KRaft controller 多数派不可用（voter 配置错/起得不够） | 核对 `KAFKA_CONTROLLER_QUORUM_VOTERS` 与节点 ID 一一对应 |

## 自测

1. 为什么消费者不能读到 HW 及之后的消息？如果放开这个限制，最坏会造成什么？
<details><summary>答案</summary>

HW 表示"ISR 全体已复制"。越过 HW 意味着可能读到只存在于当前 leader 上的消息；一旦 leader 宕机、新 leader（不含这段数据）当选并截断日志，消费者已经读到的消息就"未来消失"。下游若已据此触发写库、扣款、发通知，影响无法回收。HW 是把"可能被回滚的写入"与"对消费者的承诺"隔离的水位线。
</details>

2. RF=3、min.insync.replicas=1、acks=all：两台 follower 长时间掉线，生产者会看到什么？数据可靠性实际如何？
<details><summary>答案</summary>

两台 follower 被移出 ISR 后 ISR 只剩 leader 一个，min.insync.replicas=1 允许继续写入，acks=all 等价于只等 leader 落盘——生产者一切正常、毫无告警。此时 leader 再挂，未同步数据全部丢失，且 unclean=false 时分区直接无 leader（不可用），unclean=true 时丢数据换可用。这就是"名义 all、实际 acks=1"的配置陷阱，评审参数时必须把三个参数一起看。
</details>

3. leader epoch 机制为什么必须由 leader 回答截断点，而不能让 follower 用自己的水位判断？
<details><summary>答案</summary>

follower 本地的信息（HW、LEO、epoch 历史）在宕机/重启后就是过期快照，它无法知道"当前权威日志长什么样"。场景一里 follower 按过期的本地 HW 截断，多删了已确认数据（丢失）；场景二里它不肯截断，与 leader 分叉（不一致）。leader epoch 方案让 follower 带着自己的 epoch 去问 leader："我这个 epoch 你那边到哪了？"由 leader 根据最新元数据给出精确分歧点，follower 只截到该点。判定权从"过期的本地视角"移交给"当前权威视角"。
</details>

4. KRaft 之后，broker 重启加载集群状态的方式与 ZK 时代有什么本质区别？带来了哪些运维变化？
<details><summary>答案</summary>

ZK 时代：元数据在 ZK 里，broker 启动要连 ZK、全量拉取、注册 watch，分区多时慢且 watch 风暴放大故障。KRaft：元数据是 `__cluster_metadata` raft 日志，broker 像消费一样按 offset 增量同步快照+日志，重启只补差量。运维变化：不用再装/养 ZK（省一套有状态系统的证书、备份、扩容）；controller 切换从分钟级到秒级；查仲裁用 `kafka-metadata-quorum.sh`；4.0 起 ZK 模式彻底移除，老集群迁移要按官方路径先升级再转 KRaft。
</details>

5. 自动提交（5 秒间隔）+ "先处理后提交"的代码，还会出现重复消费吗？描述一个具体场景。
<details><summary>答案</summary>

会。消费者 poll 到 500 条，处理到第 300 条时后台自动提交把上一批的位移（或本批开头的位移，取决于客户端时序）提交了，随后进程被 OOMKill；重启后从已提交位移继续，第 1~300 条被重复处理。另一个场景：rebalance 时分区被转给别的实例，本实例处理完但 commitSync 被拒（generation 已变），新实例从旧位移开始同样重复。at-least-once 语义下重复不可彻底消除，业务侧必须用幂等键（订单号、消息 UUID）兜底。
</details>

## 延伸阅读

- 官方复制与 ISR 机制文档：https://kafka.apache.org/documentation/#replication
- 官方可靠性配置指引（acks/min.insync.replicas 组合建议）：https://kafka.apache.org/documentation/#semantics
- KIP-101（leader epoch 替代 HW 截断）：https://cwiki.apache.org/confluence/display/KAFKA/KIP-101%3A+Alter+Replication+Protocol+to+use+Leader+Epoch+rather+than+High+Watermark+for+Truncation
- KIP-500（KRaft）：https://cwiki.apache.org/confluence/display/KAFKA/KIP-500%3A+Next+Generation+of+the+Kafka+Protocol
- KRaft 模式运维文档：https://kafka.apache.org/documentation/#kraft

