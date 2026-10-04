---
title_juejin: 'Kafka 4.0 踢走 ZooKeeper：元数据换了物种'
title_zhihu: 'Kafka 自废 ZooKeeper 不是为了省事：元数据管理的终局是日志，不是注册表'
description: 'Kafka 的控制面曾寄存在 ZooKeeper：watch 风暴、分钟级切换、双份运维成本。KRaft 把元数据变成 Raft 日志，broker 按 offset 增量同步，切换降到秒级。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686341072617242662"
---

# Kafka 4.0 踢走 ZooKeeper：元数据换了物种

起一个 Kafka 集群要几个容器？旧答案是两个：Kafka 一个、ZooKeeper 一个。现在的答案是一个——官方镜像 `apache/kafka:3.9.0` 单容器直起，9092 开箱即用，全程没有 ZK 什么事。

这不是镜像的封装魔术：4.0 起，ZK 模式的代码从 Kafka 里整个移除【官方，Kafka 版本演进】。流行的解释是"少养一个组件，省钱"——这把事情说小了。

真正的原因是：数据面靠日志横扫业界的 Kafka，控制面却寄存在别人的注册表里——**KRaft 让元数据从"别人的树"变回"自己的日志"**。

## 一、ZK 时代的大脑：长在别人院子里的控制面

先明确 controller 是什么：集群的大脑，任意时刻只有一个 active，负责分区 leader 选举、broker 上下线处置、副本分配、配置变更下发、preferred leader 均衡。

broker 掉线时，它逐个把该 broker 上的 leader 分区切给 ISR 内其他副本——`kafka-topics.sh --describe` 里 Leader 换人，幕后就是它。

问题出在元数据的存放：全在 ZK 里。每个 broker 启动都要连 ZK、全量拉取一遍元数据、再注册一批 watch 等变更通知。

**数据面是日志，控制面是注册表——旧 Kafka 的分裂人格。**ZK 时代的一切痛点，都从这道裂缝里长出来。

## 二、三个结构性痛点：修不好，只能换

**痛点一，全量拉取与 watch 风暴。** controller 切换时，新 controller 要重新注册 watch、做全量对比，分区数上万时要分钟级。

更糟的是故障自我放大：broker 下线触发大量 watch 回调，回调又去创建、删除节点触发更多 watch，一次故障滚成一场雪崩【从业者判断】。

**痛点二，切换慢且不可控。** controller 故障转移状态不透明，恢复时长不可控。对值班的人这最要命：最需要控制面的时刻（故障进行中），恰恰是控制面最不可靠的时刻。

**痛点三，双份成本。** Kafka + ZK 是两套有状态系统：证书、快照、扩缩容、备份，全部双份。

这三条没有一条是 bug，全是架构使然。**结构性问题的正确解法不是修补，是换结构。**

## 三、KRaft：元数据即消息

KRaft（KIP-500）的方案一句话讲完：**把元数据本身变成一条 Raft 复制的日志**——内部 topic `__cluster_metadata`，由 3~5 个 controller 节点组成多数派仲裁，顺序追加、多数派提交。

这条日志直接带来三个质变：

- **有序、可回放**：元数据变更是一条按 offset 排好的记录流，集群只有一个事实来源，不再靠 watch 对齐。
- **切换秒级**：新 controller 从已提交日志继续工作，重注册 watch 与全量对比这两个动作根本不存在了。
- **事件内聚**：ISR 收缩扩张这类集群事件，本身就是元数据日志里的记录，排障时可查可回放。

这个思路 Kafka 早用过一次：消费位移。`__consumer_offsets` 把"每个组读到哪"做成消息——key 是 groupId+topic+partition，value 是 offset，默认 50 分区、compact 清理。位移可以是消息，集群元数据为什么不可以？

**KRaft 不是减法，是回归：用日志管理 Kafka 自己。**

## 四、broker 变成元数据的"消费者"

ZK 时代 broker 启动要全量拉取；KRaft 时代 broker 像消费者一样工作：记住自己同步到的 offset，从元数据日志拉快照加增量，重启只补差量，不再依赖任何外部系统。

同一套"pull + offset"协议，Kafka 已经用了两处：消费者拉消息、follower 拉副本。现在是第三处：broker 拉元数据。**凡是能表示成追加日志的状态，同步就天然是增量的**——不需要第二套通知机制。

对照第二节的三个痛点：全量拉取变成补差量，watch 机制整个消失，两套系统并成一套——三个痛点对三刀。

## 五、仲裁组：一条数学铁律换掉一套外部系统

controller 侧的组织方式：3~5 个节点组成多数派仲裁，写入过半提交才生效。生产配置一眼就懂：

```bash
# 三节点 KRaft 的两个关键配置（docker 环境变量形态）
KAFKA_PROCESS_ROLES: broker,controller          # 混合模式：一个进程两个角色
KAFKA_CONTROLLER_QUORUM_VOTERS: 1@kafka1:9093,2@kafka2:9093,3@kafka3:9093
```

部署两种形态：混合部署，broker 与 controller 同进程，小集群常用，官方单容器镜像就是这么跑的；分离部署，controller 独立成组，大集群用。

本专栏讲协调服务那篇说过：ZAB 和 Raft 是同一条定理的两种拼写——过半提交，同一任期至多一个 leader。KRaft 是这条定理在工业界最大规模的落地之一【从业者判断】：**少数派永远凑不够过半，分叉的元数据在数学上就提交不进去**，脑裂防护是内建的。

代价也要认：仲裁组失去多数派，元数据日志停止提交。新集群起不来、日志报 quorum 相关错误，第一反应是核对 `KAFKA_CONTROLLER_QUORUM_VOTERS` 与节点 ID 是否一一对应——KRaft 集群排名第一的"起不来"原因【从业者判断】。

## 六、演进线：从 preview 到移除

时间线【官方，Kafka 版本演进】：2.8 引入（preview）→ 3.3 生产可用 → 3.5 弃用 ZK 模式 → 4.0 移除 ZK。

**"移除"才是灵魂：两条代码路径都活着，痛点就永远修不完。**四步走完，等于替所有人做了决定。

操作口径两条：新集群直接 KRaft（3.9 官方镜像默认就是）；老 ZK 集群不能原地跳 4.0，要按官方路径先升级、再转 KRaft。

## 七、运维口径：从 zkCli 换到 kafka-metadata-quorum

ZK 时代查"controller 是谁"，动作是 zkCli 连上去看 /controller。KRaft 时代换成一个自带工具，三节点起一套当场看完：

```bash
# [任意节点] 三节点 KRaft（apache/kafka:3.9.0）
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
# [任意节点] 新口径：看元数据仲裁状态，替代 zkCli 看 /controller
docker exec kafka1 /opt/kafka/bin/kafka-metadata-quorum.sh \
  --bootstrap-server kafka1:9092 describe --status
# 预期：ClusterId / LeaderId / HighWatermark 等字段，3 个 voter
```

LeaderId 换人就是 controller 切换发生——ZK 时代分钟级、现在秒级的那个动作【从业者判断】。当场验证：

```bash
# [任意节点] pause 掉 leader 所在节点，看仲裁组几秒换主
docker pause kafka1 && sleep 10
docker exec kafka2 /opt/kafka/bin/kafka-metadata-quorum.sh \
  --bootstrap-server kafka2:9092 describe --status
# 预期：LeaderId 变为 2 或 3，多数派仍在，集群照常响应
#【从业者判断：若 pause 前 LeaderId 不是 1，改 pause 那台再试】
docker unpause kafka1 && docker compose -f ~/kafka-lab/kafka3.yaml down
```

ZK 时代的同场景：重注册 watch、全量对比、状态不透明，只能盯着日志猜。**现在一条命令看到新 leader，透明度是换架构换来的。**

## 八、别高兴太早：KRaft 的账单

故障域没有消失，只是换了形态：以前是"ZK 集群挂了控制面瘫"，现在是"仲裁组失去多数派控制面瘫"。另有两笔新账【从业者判断】：voter 表写在配置里，调整仲裁组成员是一次变更操作；仲裁组状态与元数据日志水位，该进值班手册的巡检项。

**协调问题没消失，只是变成了 Kafka 自己的 SLO。**

## 九、一张表带走

| 维度 | ZK 时代 | KRaft |
| --- | --- | --- |
| 元数据存放 | ZK 的 znode 树 | `__cluster_metadata` Raft 日志 |
| broker 启动 | 连 ZK 全量拉取 + 注册 watch | 按上次的 offset 补增量 |
| controller 切换 | 分钟级，重注册 watch + 全量对比 | 秒级，从已提交日志继续 |
| 有状态系统数 | 2 套（Kafka + ZK） | 1 套 |
| 查控制面状态 | zkCli 看 /controller | kafka-metadata-quorum describe --status |

面试一句话：ZK 被 KRaft 替代，不是因为 ZK 不好，而是 Kafka 的元数据需要日志的性质——有序、可回放、增量同步、多数派提交；把这些性质装进 Kafka 自己，ZK 就没有存在的理由。

## 现在就能做的事

跑第七节的三节点：describe --status 记住 LeaderId，pause 掉那台，亲眼看它几秒换主。

顺手自检三问：生产还在养几套 ZK、除了 Kafka 还喂着谁？故障预案里 controller 切换的预期时长，写的是分钟还是秒？新集群的部署文档里，还有 zookeeper.connect 这一行吗？

三节点 compose、元数据仲裁实验与升级路径，收在我维护的 SRE 学习仓库：GitHub 搜 sre-learning-hub——Kafka 章在数据流模块，日志模型与副本可靠性两篇是本文的地基。

最后聊个实的：你们生产还有几套 ZK 在跑？已经迁完 KRaft 的，切换窗口里最悬的一步是什么——评论区聊聊，迁移踩过的坑，往往比官方文档诚实。
