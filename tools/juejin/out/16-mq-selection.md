---
title_juejin: 消息队列选型决策树：RabbitMQ vs Kafka vs Redis Streams
title_zhihu: 消息队列选型决策树：RabbitMQ vs Kafka vs Redis Streams
description: 四维对比（消息语义/吞吐/高可用/运维复杂度）：微服务用RabbitMQ、数据管道用Kafka、轻量任务用Redis Streams。附完整决策树。
category_id: "6809637769959178254"
tags: "后端,架构"
---

# 凌晨两点、八百万条积压：消息队列选型决策树（RabbitMQ vs Kafka vs Redis Streams）

凌晨两点，订单系统堆积了八百万条消息，群里吵起来：加节点还是换队列？
吵了一个小时才发现，病根是三年前选型那天埋下的：不是工具不行，是用错了地方。
这篇文章不回答"哪个更好"，只回答"你的场景该用哪个"——读完拿着决策树直接对号入座。

## 一、先搞清楚三个东西的根本差异

先回答一个必然被问的问题：为什么只比 RabbitMQ、Kafka、Redis Streams，而不谈 RocketMQ 和 Pulsar？因为这三者覆盖了绝大多数公司实际会部署的形态，且分别代表三种典型抽象，判断逻辑可以平移。

RocketMQ 可以按"带事务消息和延迟消息的 Kafka 近亲"理解；Pulsar 则是"计算存储分离的 Kafka 加 RabbitMQ 合体"。把它们的特性套进本文的决策框架，结论同样成立。

很多选型争论的根源，是拿三个不同物种在比。它们的核心抽象完全不一样，先把这个掰开。

**RabbitMQ 是"智能路由、简单存储"**。它围绕 AMQP 0-9-1 协议构建，核心是交换机（Exchange）模型：生产者把消息发给交换机，交换机按绑定规则路由到队列，消费者拿走后消息即可删除。

```text
Producer -> Exchange(direct/fanout/topic/headers) -> Binding -> Queue -> Consumer
```

topic 交换机支持通配符匹配，比如 `order.*.paid` 能把订单事件按模式分发到十几个队列。这种"一条消息按规则扇出到多个目的地"的能力，是它和 Kafka 最本质的分界线。

**Kafka 是"简单路由、智能存储"**。消息按 key 哈希进分区（Partition），每个分区是一段只追加的磁盘日志，消费者自己拉取、自己提交 offset。消息不因消费而删除，只按时间或大小过期。

这意味着两件事：数据天然可回放（把 offset 拨回去重读一遍），以及消费逻辑写错了可以改完代码重新跑——要把它当"提交日志"用，而不是"信箱"。

**Redis Streams 是"住在 Redis 里的迷你 Kafka"**。Redis 5.0 引入的 append-only 日志结构：XADD 写入、XREAD 读取，消费者组（XREADGROUP）提供负载均衡和待确认列表。

```bash
XADD orders * status paid amount 99
XGROUP CREATE orders order-group 0
XREADGROUP GROUP order-group consumer-1 COUNT 10 STREAMS orders >
```

它没有交换机路由，也没有服务端分区（分片要靠客户端按 key 拆多个 stream 自己做），能力上是三者的子集——但部署成本也最低。

## 二、维度一：消息语义，先把丑话说完

三种语义先对齐：at-most-once（最多一次，可能丢）、at-least-once（至少一次，可能重）、exactly-once（恰好一次）。

RabbitMQ 默认配置是"可能丢"的：生产者开 confirm 模式、消费者手动 ack 之后，达到 at-least-once。但 ack 在网络传输中丢失、消费进程中途挂掉，都会造成重投，消费端必须做幂等。

Kafka 的默认配置丢、重皆有可能：生产端幂等（`enable.idempotence`）新版本默认已开，但消费端默认自动提交 offset——每 5 秒随 poll 提交一次，崩溃时可能"先提交、后处理"，重启后这批消息被跳过；关闭自动提交、处理完再手动提交，才是严格的 at-least-once。在此之上，它的杀手锏是幂等生产者加事务，能在"消费-处理-再生产"的流式链路里做到端到端 exactly-once。

但注意边界：这个 exactly-once 只在 Kafka 内部闭环。一旦下游是 MySQL 或 Elasticsearch，还是 at-least-once，还是要你自己写幂等。

Redis Streams 同样是 at-least-once：XACK 确认，没确认的消息留在 PEL（pending 列表）里，用 XPENDING 查看、XCLAIM/XAUTOCLAIM 转移给其他消费者，天然适合做死信转移。

消费者进程崩了，它没 ack 的消息别人可以接手，这套机制比很多人想的健壮。三家的共同点：重试和转移都意味着可能重复，幂等键（比如业务唯一 ID 加版本号）要在设计期就定好。

SRE 的实战结论：任何队列，业务侧都按"at-least-once + 幂等消费"设计。把 exactly-once 当营销话术看待，架构上才不会翻车。

还有一个容易被忽略的点：顺序性。Kafka 只保证分区内有序，同一个 key 进同一个分区才有顺序，跨分区全局无序。RabbitMQ 单队列基本有序，但消息被 basic.nack 重回队列后就乱序了。

Redis Streams 单 stream 有序，拆多个 stream 后和 Kafka 一样要靠 key 归类。凡是依赖"同一订单的事件必须按序处理"的业务，先想清楚 key 怎么设计，再谈选型。

## 三、维度二：吞吐量和延迟，鱼和熊掌

先给量级概念（单机普通硬件下的数量级，具体数字看硬件和参数，以官方基准文档为准）：

RabbitMQ 万级到十万级每秒，推送模式延迟在毫秒以内。开启仲裁队列后写入要过 Raft 多数派，延迟上涨、吞吐打折——这是为一致性交的税。

Kafka 单集群百万级每秒，靠批量攒批和顺序 IO 换来，端到端延迟通常在几十毫秒量级。想压延迟就得调小批次，吞吐跟着掉，两头不可兼得。

Redis Streams 十万级每秒问题不大，纯内存操作延迟亚毫秒。但 stream 活在内存里，必须配 MAXLEN 或 MINID 截断，否则内存就是它的天花板。

再算一笔资源账：Kafka 消息落盘，磁盘要按"日均流量 × 保留天数 × 副本数 ÷ broker 数"来规划——副本因子最常被漏算，三副本会把落盘量放大三倍，再留 20%~30% 余量给日志压缩和分区迁移的水位；换来的是内存要求低。RabbitMQ 和 Redis 都吃内存，积压一上来资源压力立竿见影——还记得开头那八百万条积压吗？那就是内存型队列的软肋被踩中的现场，案情结尾复盘。预算紧张的团队，这一条往往比功能对比更早做出决定。

一句话：要吞吐选 Kafka，要低延迟推送选 RabbitMQ，要"顺手、够用"选 Redis Streams。

## 四、维度三：高可用，三家玩法完全不同

**RabbitMQ**：老玩家熟悉的经典镜像队列（ha-mode）已经走到尽头——4.0 起被移除，新部署一律用仲裁队列（Quorum Queue，3.8 引入）。仲裁队列基于 Raft，多数派确认才算写入成功（版本时间线以官方文档为准）。

运维要点：队列在创建时固定归属节点，扩容新节点不会自动搬队列，要定期执行 rebalance。跨机房用 shovel 或 federation 插件做异步复制。

新队列的声明方式也要改习惯：仲裁队列用 `x-queue-type: quorum` 参数创建，旧镜像队列的 policy 写法已经没有意义，存量集群升级前先把队列类型迁移做完（迁移路径以官方文档为准）。

```bash
# 查看队列类型与副本分布（4.x）；policy 列可揪出还挂着 ha-mode 策略的存量镜像队列
rabbitmqctl list_queues name type policy leader online_members
# 看单个仲裁队列的 leader 与副本详情
rabbitmq-queues quorum_status <队列名>
# 手动平衡队列分布（滚动执行）
rabbitmq-queues rebalance quorum
```

**Kafka**：分区多副本加 ISR（In-Sync Replicas）是它的灵魂。leader 挂掉从 ISR 里选新 leader，落后太多的副本被踢出 ISR。安全配置是 `acks=all` 加 `min.insync.replicas=2`，缺一个，要么丢数据要么不可用。

KRaft 模式用 Raft 管理元数据，取代 ZooKeeper：3.3 起生产可用，4.0 彻底移除 ZK。新集群别再搭 ZooKeeper 了（同样以官方文档为准）。

**Redis Streams**：HA 就是 Redis 的 HA——主从加 Sentinel 自动切换，或 Cluster 分片。但有个坑必须知道：Redis 复制是异步的，Sentinel 切换瞬间，"已确认"的写入可能随旧主一起丢。

对缓存无所谓，对消息队列就是事故。缓解手段是 WAIT 命令强制等同步副本，但会明显拉高延迟。能接受少量丢失的日志、行为埋点场景才适合它。

## 五、维度四：运维复杂度，SRE 最痛的部分

**RabbitMQ**：中等。有状态集群，K8s 上用官方 Cluster Operator 加 StatefulSet。要盯队列长度、内存水位、磁盘告警、连接数。管理 UI 和 Prometheus 插件开箱即用，排障体验三者里最好。

坑在容量：队列和消息默认在内存里，积压千万条容易触发内存告警把节点流量掐了（blocking），然后连环雪崩。

**Kafka**：最高。组件和概念最多：分区、副本、ISR、controller、消费者组 rebalance。存储规划直接影响成本；分区迁移和消费者组 rebalance 都可能造成消费停顿。

K8s 上强烈建议用 Strimzi Operator，把扩缩容和配置变更变成 CRD 声明式操作，否则手工运维一个三 broker 集群就能吃掉你半天。

**Redis Streams**：最低——前提是你已经有成熟的 Redis 体系。但务必把"队列 Redis"和"缓存 Redis"物理隔离，并把 `maxmemory-policy` 改成 `noeviction`，否则内存一紧消息先被 LRU 淘汰——这是最经典的翻车现场。

## 六、生态适配：别让队列孤立存在

微服务异步解耦、复杂事件路由、延迟消息、优先级队列——RabbitMQ 最顺手。延迟消息常见做法是 TTL 加死信，但逐条设 TTL 有队首阻塞问题：队首消息未到期，后面更短的消息全被压着投不出去；等差延迟要么按 TTL 拆队列，要么用社区的 delayed-message 插件。AMQP 是跨语言标准，Spring 生态一等公民。

日志采集、埋点上报、对接 Flink/Spark 流计算、事件溯源、历史回放——Kafka 没有对手。Connect 生态几百个连接器，加 Debezium 做 CDC 已经是数据管道的事实标准。

小团队的异步任务、已有 Redis 且 QPS 不高、不想多养一套中间件——Redis Streams 刚好。消费者组的 pending 机制够撑很久。

顺带一提，招聘 JD 和数据管道项目里 Kafka 的出现频率持续走高，值得吃透——我把分区日志、ISR、KRaft 的深入拆解放在文末的开源仓库里。

## 七、选型速查表

| 维度 | RabbitMQ | Kafka | Redis Streams |
|---|---|---|---|
| 消息语义 | at-least-once + 幂等 | at-least-once（流内可 exactly-once） | at-least-once |
| 吞吐量 | 万 ~ 10 万 QPS | 10 万 ~ 百万 QPS | ~ 10 万 QPS |
| 延迟 | 亚毫秒 ~ 毫秒 | 几十毫秒 | 亚毫秒 |
| 高可用 | Quorum Queue（Raft） | 多副本 + ISR + KRaft | 主从 + Sentinel / Cluster |
| 运维复杂度 | 中 | 高 | 低 |
| 生态定位 | 微服务消息 | 数据管道 / 流计算 | 轻量任务 |

## 八、选型决策树

把四个维度收进一棵树，按顺序问自己：

```text
开始
 ├─ 需要消息回放 / 对接流计算（Flink 等）/ 吞吐 > 10 万 QPS？
 │   └─ 是 → Kafka（acks=all + min.insync.replicas=2 + KRaft）
 │      （同时需要交换机式复杂路由？→ 别停在这支，看组合拳）
 │
 ├─ 需要复杂路由（topic 交换机）/ 毫秒级推送 / 延迟消息 / 多语言 AMQP？
 │   └─ 是 → RabbitMQ（Quorum Queue + 官方 Cluster Operator）
 │
 ├─ 已有 Redis / QPS < 数万 / 团队很小 / 能容忍极小概率丢消息？
 │   └─ 是 → Redis Streams（独立实例 + noeviction + MAXLEN）
 │
 ├─ 以上都要？
 │   └─ 组合拳：业务消息走 RabbitMQ，数据管道走 Kafka，
 │      别让一个集群同时干两份活
 │
 └─ 吞吐 > 百万 QPS 且要流内 exactly-once？
     └─ Kafka + 事务 API，并接受它的运维成本
```

决策顺序有讲究：先问数据管道属性（回放、吞吐），再问业务消息属性（路由、延迟），最后才轮到成本。反过来选，十有八九返工。这棵树按"命中即走"读，但命中后要回头自查是否同时命中了别的分支——既要回放又要交换机式路由的场景，第一分支会把你送进 Kafka，而 Kafka 没有交换机，这种单子属于组合拳分支。所有分支落到 K8s 里都是同一句：用 Operator 部署，让声明式配置进 Git，别靠人手记。

## 九、落地前三件事

第一，K8s 上用 Operator 部署：RabbitMQ 用官方 Cluster Operator，Kafka 用 Strimzi，Redis 用 Redis Operator 或 StatefulSet。别手搓裸 Pod。

```yaml
# Strimzi：3 节点 KRaft 集群骨架（示意，参数以官方文档为准）
# 新版 Strimzi 要求 Kafka + KafkaNodePool 组合部署
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: orders
  annotations:
    strimzi.io/node-pools: enabled  # 新版默认启用，可省略
spec:
  kafka:
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
    config:
      min.insync.replicas: 2
      default.replication.factor: 3
  entityOperator:
    topicOperator: {}
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: mixed
  labels:
    strimzi.io/cluster: orders
spec:
  replicas: 3
  roles:
    - controller
    - broker
  storage:
    type: jbod
    volumes:
      - id: 0
        type: persistent-claim
        size: 500Gi
```

第二，上线前做一次混沌演练：杀 leader、杀 broker、断网半小时，验证消费者自动重连和消息不丢。没演练过的 HA 配置等于没有。

第三，把四类告警配齐：RabbitMQ 队列长度和内存水位、Kafka 消费延迟（Lag，用 Burrow 或 kafka-exporter）、Redis 内存使用率和 stream 长度、三者共同的"堆积增长率"告警。

堆积增长率比堆积绝对值更重要——绝对值高但增速为零，说明只是没人消费；增速陡增，才是事故前兆。

顺带说一个通用救火姿势：消息大量积压时，先看是生产突增还是消费变慢。消费变慢就扩消费者（Kafka 注意消费者数不能超过分区数，多了只会空转），生产突增就限流上游，别一上来就重启集群，那只会把缓存和连接全部打断。

## 写在最后

回到开头那个凌晨——那是一起把 RabbitMQ 当 Kafka 用的典型事故：业务要的是回放，它给的只有信箱，消息消费即删，团队为了"以后能重跑"不敢放开消费，八百万条积压就这么滚出来了。按这棵决策树走，第一问"要不要回放"三年前就会落进 Kafka 分支，那晚的群架根本打不起来。

最后补一组"该换队列了"的迁移信号，比选型本身更有用：

RabbitMQ 出现这些情况，考虑往 Kafka 迁：队列消息被当成业务数据反复回放；单集群吞吐逼近十万每秒还在压榨；业务方开始问"能不能把上周的消息重跑一遍"。

Redis Streams 出现这些情况，考虑往 RabbitMQ 或 Kafka 迁：消息量涨到内存预算的六成以上；开始需要死信、延迟、优先级这类高级语义；有第二个团队要消费同一批数据。

反过来，Kafka 集群里如果只跑着一万每秒的业务消息、团队没人懂 rebalance 排障，那它是负资产——降级到 RabbitMQ 反而省心。选型不是一次性的，每个季度拿真实流量重新问一遍决策树。

选型的本质是承认没有银弹：RabbitMQ 拿运维复杂度换路由灵活，Kafka 拿它换吞吐和回放，Redis Streams 拿能力上限换部署简单——你选的不是工具，是未来三年里半夜几点会被叫醒。

## 明天就能做的三件事

三件都是当天能完成的小事：

1. 把你负责的消息场景按决策树走一遍，标注每条的语义要求和吞吐量级；
2. 检查现有集群的 `acks` 和 `min.insync.replicas` 是否安全；
3. 给 Lag 和队列长度配上告警。

这棵决策树的可复制版、Kafka ISR/KRaft/rebalance 的深入拆解，都放在开源仓库 [sre-learning-hub](https://github.com/Thneoly/sre-learning-hub)，持续更新，欢迎 star、提 issue 交流——下一篇拆消费者组 rebalance。怕找不到就先收藏。
