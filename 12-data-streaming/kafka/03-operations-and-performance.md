# 03 · Kafka 运维与性能：容量规划、retention、lag 监控与 Strimzi

> 模块：12-data-streaming/kafka ｜ 建议时长：4 小时 ｜ 关联认证：CKA-工作负载/CRD（Strimzi 是 Operator + CRD 的完整范例）｜ PCA-指标与告警（kafka_exporter + PromQL 告警思路）

## 学习目标

- 能按"吞吐 → 分区数 → 磁盘 → 网络 → 页缓存"五步完成一套集群的容量估算
- 能解释 retention（delete）与 compact 两种清理策略的机制，说明 `__consumer_offsets` 为什么必须是 compact
- 能背出生产端（retries/enable.idempotence/linger.ms）与消费端（max.poll.interval.ms/max.poll.records）关键配置的默认值与调整方向，并按排障表处置频繁 rebalance、磁盘满、broker 掉线三大高频故障
- 能用 kafka_exporter 的指标写 lag 绝对值、消费停滞、under-replicated 三类告警的 PromQL
- 能用 Strimzi Operator 完成 Kafka / KafkaTopic / KafkaUser 三种 CR 的部署与验证

## 1. 容量规划：五步估算法

容量规划不需要精确，需要的是**留对余量**。以目标"峰值写入 50 MB/s（压缩后）、retention 7 天、RF=3"为例：

**第一步：定分区数。** 单分区的顺序写吞吐通常在几十 MB/s 量级（受 batch、压缩、页缓存影响很大），但**单分区同时是消费并行度上限**。经验公式：`分区数 = max(目标吞吐 / 单分区预期吞吐, 目标消费并行度) × 2~3 倍余量`。分区只能加不能减，扩容前必须先想清楚。按本例：50 / 20 ≈ 3，消费者需要 12 路并行 → 取 12，加余量建 18~24 个分区。

**第二步：算磁盘。**

```
日写入量   = 50 MB/s × 86400 s          ≈ 4.3 TB/天
retention  = 4.3 × 7                    ≈ 30 TB（单副本）
副本放大   = 30 × 3(RF)                 =  91 TB
索引+余量  = 91 × 1.2                   ≈ 109 TB（集群总量）
```

再按 broker 数摊分：6 台 broker → 每台约 20 TB（含 `__consumer_offsets` 等内部 topic，通常另留 5%）。磁盘类型：Kafka 顺序写为主，大容量 SSD 与 HDD 都能跑，但 **follower 追赶（回放历史）与消费者回溯读**是随机读大户，对延迟敏感或分区数极大的集群选 SSD。

**第三步：算网络。** 每 broker 承载的流量 = 写入入流量 + **复制出流量（×(RF-1)/broker 数）** + 消费出流量（消费者也在读 RF 中的 leader 副本）。50 MB/s 写入、6 台、RF=3：每台入 ≈ 8.3 MB/s，复制出 ≈ 16.6 MB/s，消费侧若有两个独立组各读全量，再各加 8.3 MB/s——单 broker 出口可到 40+ MB/s，早已超出 1 Gbps 网卡舒适区，**生产集群标配 10 GbE**。跨机房/跨 AZ 的 ISR 复制流量要单独向网络组申报。

**第四步：给页缓存留内存。** 目标是"消费者追尾窗口内的热数据整体在缓存"。7 天 retention、50 MB/s 的集群全量放缓存不现实，但最近几小时（≈ 数百 GB）常驻是合理目标；broker 堆统一 4~6 GB，剩余内存全部留给 OS。6 台 × 64 GB 起步是常见规格。

**第五步：留扩容路径。** 分区数、磁盘（JBOD 能加盘）、broker 数都要能独立扩。分区数一开始就按 2~3 倍余量建；broker 扩容后老分区不会自动迁移（lab 里会亲眼看到），需要 KafkaRebalance/Cruise Control 或 `kafka-reassign-partitions.sh` 再均衡。

## 2. Retention 与 compact：磁盘的两种回收方式

**delete（默认）**：按时间或大小删除**整个 segment 文件**——`retention.ms`（默认 7 天，全局 `log.retention.hours`）、`retention.bytes`（默认 -1 不限）、检查周期 `log.retention.check.interval.ms`（默认 5 分钟）。注意第 1 章的结论：活跃段不删，低流量 topic 实际释放时间 = retention + 一个 segment 滚动周期。按 topic 覆盖：

```bash
# [任意节点] 动态调整（不需要重启 broker，立即生效）
/opt/kafka/bin/kafka-configs.sh --bootstrap-server localhost:9092 \
  --alter --entity-type topics --entity-name orders --add-config retention.ms=86400000
```

**compact**：为每个 key 保留**最新**一条 value，旧值在后台清理时物理删除。适用于"以 key 为实体的状态表"：配置快照、`__consumer_offsets`、changelog。要点：

- 只有 key 为 null 的消息才参与 compact；删除一个 key 用 **tombstone**（value 为 null 的记录），在 `delete.retention.ms`（默认 24 小时）后连墓碑也删掉。
- 清理仍以 segment 为单位，活跃段不参与；`min.cleanable.dirty.ratio`（默认 0.5）控制"脏数据占比"达标才清。
- compact 不是删除手段而是"收敛到最新"的手段，**不设上限地更新同一批 key，日志仍可能一直增长**（受 `segment.ms` 与清理节奏约束）。

**`__consumer_offsets` 为什么必须 compact**：位移记录的 key 是 `groupId+topic+partition`，消费正确性只依赖每个 key 的**最新** offset。若按时间 delete，历史位移被删后，该组一旦需要恢复（重平衡/位移过期 `offsets.retention.minutes`），找不到位移就只能走 `auto.offset.reset` 整 topic 重放或跳到 latest——要么重复消费海量数据，要么丢数据。所以它建表就是 50 分区 + `cleanup.policy=compact`，运维**永远不要**改内部 topic 的清理策略。

两类策略可以组合（`cleanup.policy=delete,compact`：先保最新值，再整体过期），Kafka Streams 的 changelog 常用。

## 3. 关键配置清单

生产端（评审 producer 参数时对着看）：

| 配置 | 默认(3.x) | 建议与说明 |
|---|---|---|
| `acks` | all | 丢数据评审的第一项；日志类可降到 1，绝不能无脑 0 |
| `enable.idempotence` | true | 3.0 起默认开；要求 `max.in.flight<=5`、`retries>0`，防重试重复 |
| `retries` / `delivery.timeout.ms` | MAX / 120s | 不要单独调 retries，改总预算 delivery.timeout.ms（含 linger+重试） |
| `linger.ms` / `batch.size` | 0 / 16KB | 吞吐不足先加 linger（5~20ms），再考虑加大 batch |
| `compression.type` | none | lz4（CPU 紧张）或 zstd（带宽/磁盘紧张） |
| `max.in.flight.requests.per.connection` | 5 | 幂等开启下 ≤5 仍保序，不要为了吞吐调大 |

消费端（rebalance 风暴、lag 雪崩多半栽在这几行）：

| 配置 | 默认(3.x) | 建议与说明 |
|---|---|---|
| `max.poll.records` | 500 | 单批处理耗时 = 条数 × 单条耗时，必须 < max.poll.interval.ms，否则被踢出组 |
| `max.poll.interval.ms` | 300000 | 处理慢的作业把它调大 + max.poll.records 调小，两者配合 |
| `session.timeout.ms` / `heartbeat.interval.ms` | 45000 / 3000 | 心跳后台线程负责，GC 停顿超 session 即被判死 |
| `auto.offset.reset` | latest | 新组/位移过期时的行为；需要回放的场景配 earliest |
| `enable.auto.commit` | true | 追求精确语义改 false，处理完手动 commitSync |
| `partition.assignment.strategies` | [RangeAssignor, CooperativeStickyAssignor] | 新组用 cooperative-sticky，rebalance 不再全组停摆 |
| `group.instance.id` | 无 | 静态成员：滚动发布不触发 rebalance（配 `session.timeout.ms` 内的重启窗口） |

broker 端高频项：`num.network.threads=3`、`num.io.threads=8`（请求处理线程组，CPU 核数与压测定）；`num.replica.fetchers=1`（副本拉取线程数，ISR 频繁收缩时适当调大）；`replica.lag.time.max.ms=30s`；`auto.leader.rebalance.enable=true`（preferred leader 自动回归）；`unclean.leader.election.enable=false`；`log.segment.bytes=1GB`。改动原则：一次只改一项、压测对比、记录在容量规划文档里。

## 4. Lag 监控：kafka_exporter 指标与告警

lag 是 Kafka 侧最核心的业务健康指标（比 CPU/内存更早暴露问题）。Prometheus 生态标准采集器是 kafka_exporter（Strimzi 内置同款，`spec.kafkaExporter` 一行开启），关键指标：

| 指标 | 含义 | 用途 |
|---|---|---|
| `kafka_consumergroup_current_offset` | 组当前提交位移（按 consumergroup/topic/partition 标签） | 消费速率、停滞检测 |
| `kafka_consumergroup_log_offset` | 分区日志末端位移（LEO） | 生产速率、lag 计算的减数 |
| `kafka_topic_partition_current_offset` | topic 分区 LEO（不带组维度） | 写入速率 |
| `kafka_topic_partition_under_replicated_partition` | 分区是否 under-replicated（1/0） | 副本健康，**值班第一优先级** |
| `kafka_topic_partition_leader_is_preferred` | leader 是否 preferred | 均衡性 |
| `kafka_brokers` | exporter 看到的 broker 数 | broker 掉线告警 |

lag 本身 exporter 不直接给值，用两条同标签指标相减（标签完全一致，PromQL 直接匹配）：

```promql
# lag 绝对值
kafka_consumergroup_log_offset - kafka_consumergroup_current_offset

# 全组每秒消费条数（下降趋势常是消费停滞前兆）
sum by (consumergroup) (rate(kafka_consumergroup_current_offset[5m]))

# 写入速率（按 topic）
sum by (topic) (rate(kafka_topic_partition_current_offset[5m]))
```

告警分三层，从"已经出事"到"正在出事"再到"要出事"：

```yaml
# [master] PrometheusRule（kube-prometheus-stack 已装的集群直接 apply）
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kafka-lag-rules
  namespace: monitoring
  labels:
    release: prometheus
spec:
  groups:
    - name: kafka-lag
      rules:
        # 1. lag 绝对值：业务能容忍的积压量（条数，需按业务 SLA 定，例如 15 分钟可消化完的量）
        - alert: KafkaConsumerLagHigh
          expr: kafka_consumergroup_log_offset - kafka_consumergroup_current_offset > 100000
          for: 10m
          labels:
            severity: warning
          annotations:
            summary: "组 {{ $labels.consumergroup }} 在 {{ $labels.topic }} p{{ $labels.partition }} lag 超 10 万"
        # 2. 消费停滞：LEO 在涨、位移不动——比 lag 绝对值更早发现问题（rebalance 死锁/下游卡死）
        - alert: KafkaConsumerStalled
          expr: >
            (increase(kafka_consumergroup_log_offset[15m]) > 100)
            unless
            (increase(kafka_consumergroup_current_offset[15m]) > 0)
          for: 15m
          labels:
            severity: critical
          annotations:
            summary: "组 {{ $labels.consumergroup }} 15 分钟未消费（LEO 在涨）"
        # 3. 副本健康：under-replicated 分区（同时常意味着有 broker 异常）
        - alert: KafkaUnderReplicatedPartitions
          expr: sum(kafka_topic_partition_under_replicated_partition) > 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "存在 under-replicated 分区，先查 broker 与磁盘"
        # 4. broker 规模变化
        - alert: KafkaBrokersChanged
          expr: kafka_brokers < 3
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "exporter 可见的 broker 数小于 3"
```

思路比模板重要：**lag 绝对值阈值必须按业务消化速度定**（"10 万条对 5 万条/秒的组是 2 秒的事，对 10 条/秒的组是灾难"）；消费停滞告警（速率差）比绝对值更普适；under-replicated 是与 lag 并行的第二条告警线——前者保数据可靠，后者保业务时效。

## 5. 三大高频故障排障表

**频繁 rebalance**（日志关键词：`Rebalance`、`Attempt to heartbeat failed`、`left group`、`IllegalGeneration`）：

| 症状 | 原因 | 解法 |
|---|---|---|
| 周期性整组 rebalance，日志见 "max.poll.interval.ms 超时被踢" | 单批处理超过 max.poll.interval.ms（默认 5 分钟） | 调小 max.poll.records / 调大 max.poll.interval.ms / 处理异步化 |
| "Attempt to heartbeat failed" 后成员离组 | GC 长停顿或网络抖动超过 session.timeout.ms | 修 GC（堆/算法）、查网络重传；必要时微调 session.timeout |
| 每次发布必现 rebalance | 滚动重启成员变化属正常 | 配 group.instance.id 静态成员 + cooperative-sticky |
| 某一台实例反复进出组 | 宿主机负载/DNS 慢/容器 CPU limit 打满 | 看 pod 重启次数、CPU 节流、connect 时间 |
| 多组同时 rebalance | 协调者所在 broker 抖动（coordinator 切换） | 先修 broker，再看组是否都哈希到同一分区 |

**磁盘满**（broker 日志：`No space left on device`，写入全面失败）：

| 症状 | 原因 | 解法 |
|---|---|---|
| 磁盘使用率陡增 | 某业务 topic 猛写或 retention 被调大 | `kafka-log-dirs.sh --describe` 按 topic 看占用；动态调小 retention.ms |
| `df` 满、`du` 找不到对应文件 | 有人手动 `rm` 了 segment，进程仍持有 fd | 永远不要手动删 segment；用 `lsof | grep deleted` 定位，重启该 broker 回收 |
| 删除迟迟不生效 | 活跃段不可删 / 检查周期未到 | 确认 segment 是否滚动（低流量 topic 缩 segment.ms）；等检查周期 |
| 反复逼近水位 | 容量规划余量不足 | 扩盘（JBOD 加卷）、按第 1 节重算，设 80% 告警 |

**broker 掉线 / under-replicated**：

| 症状 | 原因 | 解法 |
|---|---|---|
| 大量分区 leader=-1 | controller 未完成选举或 ISR 空 | 查 controller 日志与 `kafka-metadata-quorum.sh describe --status`；极端情况评估 unclean 风险后人工决策 |
| 某副本长期 out-of-ISR | 所在盘慢 / fetch 线程不足 / 网络差 | 看该 broker 磁盘 util、调 `num.replica.fetchers`、查网卡重传 |
| 重启后长时间恢复 | 页缓存冷 + 全量追赶 | 预期行为；控制单 broker 分区数，滚动重启避开高峰 |
| 文件句柄不足（`Too many open files`） | 分区/segment 数超过 nofile | 调大 `ulimit -n`（systemd LimitNOFILE）并写入基线配置 |

定位磁盘占用的标准命令（只读，可放心在生产跑）：

```bash
# [任意节点] 按 broker+topic 汇报日志目录占用
/opt/kafka/bin/kafka-log-dirs.sh --bootstrap-server localhost:9092 \
  --describe --topic-list orders,pay | head -5
```

## 6. Strimzi Operator：Kafka 的 Kubernetes 化

Strimzi 把整套 Kafka 生命周期收敛为 CR + Operator：`Kafka`（集群：broker/controller、listener、配置）、`KafkaNodePool`（节点池：副本数、角色、存储）、`KafkaTopic`（自动建 topic）、`KafkaUser`（客户端账号与 ACL）、`KafkaRebalance`（Cruise Control 再均衡）。运维视角看它就是 CKA 里学过的 CRD + 控制循环模式应用到有状态中间件——`kubectl get kafka` 的 Ready condition 就是健康检查入口。

完整部署流程（lab 会逐条做，这里给全貌）：

```bash
# [master] 1) 装 Operator（0.46.x，KRaft-only 版本；watch 本 namespace）
kubectl create namespace kafka-lab
curl -Lsf https://github.com/strimzi/strimzi-kafka-operator/releases/download/0.46.0/strimzi-cluster-operator-0.46.0.yaml \
  | sed 's/namespace: .*/namespace: kafka-lab/' \
  | kubectl -n kafka-lab apply -f -

# [master] 2) 等 Operator 就绪
kubectl -n kafka-lab rollout status deploy/strimzi-cluster-operator --timeout=300s
```

```yaml
# [master] 3) 集群 CR：三节点（broker+controller 混合）、内部 PLAINTEXT 监听、内置 exporter
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaNodePool
metadata:
  name: kafka
  namespace: kafka-lab
  labels:
    strimzi.io/cluster: my-cluster
spec:
  replicas: 3
  roles:
    - controller
    - broker
  storage:
    type: ephemeral        # 练习用；生产必须 persistent-claim
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
  namespace: kafka-lab
spec:
  kafka:
    version: 3.9.0
    metadataVersion: 3.9-IV0
    listeners:
      - name: plain
        port: 9092
        type: internal
        tls: false
      - name: tls
        port: 9093
        type: internal
        tls: true
    config:
      offsets.topic.replication.factor: 3
      transaction.state.log.replication.factor: 3
      transaction.state.log.min.isr: 2
      default.replication.factor: 3
      min.insync.replicas: 2
    jvmOptions:
      "-Xmx": "512m"       # 练习集群压小堆；生产按容量规划章节给
  entityOperator:
    topicOperator: {}
    userOperator: {}
  kafkaExporter: {}        # 自动部署 lag exporter（:9404）
```

```yaml
# [master] 4) topic 与用户 CR（apply 后由 TopicOperator/UserOperator 同步到集群）
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaTopic
metadata:
  name: orders
  namespace: kafka-lab
  labels:
    strimzi.io/cluster: my-cluster
spec:
  partitions: 6
  replicas: 3
  config:
    retention.ms: 604800000
    min.insync.replicas: 2
---
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaUser
metadata:
  name: order-app
  namespace: kafka-lab
  labels:
    strimzi.io/cluster: my-cluster
spec:
  authentication:
    type: tls            # 账号走 9093 TLS listener；plain listener 不鉴权（lab 里只用作内部验证）
  authorization:
    type: simple
    acls:
      - resource:
          type: topic
          name: orders
          patternType: literal
        operations: [Read, Write, Describe]
        host: "*"
      - resource:
          type: group
          name: order-
          patternType: prefix
        operations: [Read, Describe]
        host: "*"
```

要点：`KafkaTopic` 的 `spec` 变更里**分区数只能增不能减**（和原生 Kafka 一致，Operator 会拒绝并报错）；`KafkaUser` 的 Secret（证书）由 Operator 生成在同名 Secret 里；broker 扩容只是改 `KafkaNodePool.replicas`，但**已有分区不会自动迁移**，要 `KafkaRebalance`（Cruise Control）或手工 reassignment。版本组合（Strimzi 版本 × Kafka 版本）以 https://strimzi.io/docs/quickstart/latest 的说明为准。

## 实战演练

环境：装有 Docker 的 Ubuntu VM。目标：把 retention、compact、lag 三件事亲手各做一遍。

```bash
# [任意节点] 起单节点，把 retention 检查周期调小（默认 5 分钟太慢）
docker run -d --name kafka-ops -p 9092:9092 \
  -e KAFKA_LOG_RETENTION_CHECK_INTERVAL_MS=15000 apache/kafka:3.9.0
```

```bash
# [任意节点] 实验 1：retention 按段删除。60 秒 retention + 10KB 段
docker exec kafka-ops /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic shortlived --partitions 1 --replication-factor 1 \
  --config retention.ms=60000 --config segment.bytes=10240

docker exec kafka-ops bash -c \
  'for i in $(seq 1 2000); do echo "x-$i-padding-padding-padding"; done | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic shortlived'

docker exec kafka-ops ls /tmp/kraft-combined-logs/shortlived-0/
sleep 90
docker exec kafka-ops ls /tmp/kraft-combined-logs/shortlived-0/
# 预期：第一次看到多个段，第二次只剩活跃段——旧段整文件被删
```

```bash
# [任意节点] 实验 2：compact。key 每次覆盖，最后只剩每个 key 的最新值
docker exec kafka-ops /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic cfg-snap --partitions 1 --replication-factor 1 \
  --config cleanup.policy=compact --config min.cleanable.dirty.ratio=0.01 \
  --config segment.ms=10000 --config delete.retention.ms=10000

docker exec kafka-ops bash -c \
  'printf "user:1:alice\nuser:2:bob\nuser:1:alice-new\nuser:2:bob-new\n" | \
   /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 \
   --topic cfg-snap --property parse.key=true --property key.separator=:'
# 注意：key.separator=: 时消息格式为 "key:value"，value 里再有冒号会被截断，故用 - 连接

sleep 60
docker exec kafka-ops /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic cfg-snap --from-beginning \
  --property print.key=true --timeout-ms 5000
# 预期：只剩 user:1 的 alice-new 与 user:2 的 bob-new（compaction 已物理删除旧值）
```

```bash
# [任意节点] 实验 3：制造并观察 lag（第 4 节监控的手工版）
docker exec kafka-ops /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 \
  --create --topic lag-demo --partitions 4 --replication-factor 1

docker exec kafka-ops bash -c \
  'for i in $(seq 1 4000); do echo "u$((i % 8)):$i"; done | /opt/kafka/bin/kafka-console-producer.sh \
   --bootstrap-server localhost:9092 --topic lag-demo --property parse.key=true --property key.separator=:'

docker exec kafka-ops /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic lag-demo --group lag-group \
  --from-beginning --max-messages 500 > /dev/null

docker exec kafka-ops /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 --describe --group lag-group
# 预期：4 个分区，LAG 合计 3500 —— 换成 kafka_exporter 就是 kafka_consumergroup_log_offset - kafka_consumergroup_current_offset
```

验证方法：实验 1 用前后两次 `ls` 对比段数；实验 2 消费输出只有最新值；实验 3 的 LAG 列求和等于 4000-500。做完清理：`docker rm -f kafka-ops`。Strimzi 的完整动手在 lab 01（`labs/01-strimzi-cluster/`）。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| lag 告警阈值定 10 万，天天误报 | 阈值没按组的消费速率归一 | 按业务消化时间定阈值，或改用消费停滞（速率差）告警 |
| `kafka-log-dirs.sh` 输出空 | 需要指定 broker 列表或 jmxdump 权限 | 加 `--bootstrap-server` 与 `--topic-list`；旧版本要 JMX 端口，以当前版本文档为准 |
| 手动 rm segment 后磁盘没释放 | fd 仍被 broker 进程持有 | 永远通过 retention/工具删；`lsof | grep deleted` 确认后重启 broker |
| compact topic 磁盘一直涨 | 同 key 高频更新 + 段不滚动 | 缩 `segment.ms` 让更多段可清理；评估 `min.cleanable.dirty.ratio` |
| Strimzi 里改 KafkaTopic 分区数被拒 | 分区缩减在 Kafka 本身就不允许 | 只能增；建 topic 前按容量规划留余量 |
| 扩容 KafkaNodePool 后新 broker 空转 | 分区不会自动迁移 | KafkaRebalance（add-brokers 模式）或 kafka-reassign-partitions.sh |
| exporter 指标里找不到某组 | 组内无活跃成员且位移过期被清理 | 正常现象；需要长期跟踪静止组就记录在 dashboards 上而不是告警里 |

## 自测

1. 规划一个 100 MB/s（压缩后）、retention 3 天、RF=3、6 broker 的集群：磁盘总量大约多少？每台网卡至少什么规格？
<details><summary>答案</summary>

磁盘：100 × 86400 ≈ 8.6 TB/天 × 3 天 × 3 副本 ≈ 78 TB，×1.2 余量 ≈ 93 TB，每台约 16 TB。网络：每台写入入 ≈ 17 MB/s，复制出 ≈ 33 MB/s，再叠加消费读（至少与写入同量级），单台出口 60+ MB/s，1 Gbps（约 125 MB/s 线速，实用 80~90）已贴近极限，配 10 GbE 才有余量。
</details>

2. 低流量 topic 配了 retention=1 天，为什么 8 天前的消息还在磁盘上？
<details><summary>答案</summary>

retention 删除的最小单位是 segment，且活跃段不可删。该 topic 流量低，7 天（segment.ms 默认）才滚动一个段：那些消息都在活跃段里，要等段滚动后才开始计时删除，实际保留 ≈ segment.ms + retention + 检查周期。解法是把 segment.ms/segment.bytes 调小，让段滚得更勤。
</details>

3. 一个消费组 lag 常年在 5 万但不涨，另一个组 lag 只有 200 但每分钟涨 5 万。哪个更该告警？为什么？
<details><summary>答案</summary>

后者。lag 绝对值要结合消化速率解读：前者是"已知积压且收支平衡"（可能业务本来落后一个批处理周期），后者是消费停滞或消费速度远低于生产速度（10 分钟内不可恢复）。告警设计应同时看绝对值与速率差（increase(current_offset) 为 0 而 increase(log_offset) > 0），后者往往用 critical。
</details>

4. 消费者日志出现 `IllegalGeneration` 且组在不停 rebalance，给出排查顺序。
<details><summary>答案</summary>

先看是哪种离组：日志里找 "max.poll.interval.ms" 与 "heartbeat failed"。若前者：单批处理超时被踢，缩小 max.poll.records 或加大 max.poll.interval.ms；被踢后提交位移就会抛 IllegalGeneration。若后者：GC/网络问题，看容器 CPU 节流与 GC 日志。再查是否滚动发布叠加了风暴——上 cooperative-sticky 与 group.instance.id。最后确认不是协调者 broker 抖动导致全组迁移（时间点与 broker 事件对齐）。
</details>

5. 为什么 Strimzi 扩容 KafkaNodePool 后必须再执行再均衡？这与 Kafka 的哪个设计决定直接相关？
<details><summary>答案</summary>

Kafka 的分区分配在创建时确定，之后不会自动迁移（副本位置是元数据里的静态映射，性能考虑：自动迁移会造成带宽与 IO 的不可控搬移）。所以新 broker 只会承接**新创建**的分区，老分区仍留在旧 broker 上，集群忙闲不均。KRaft 时代迁移要写元数据日志、搬数据、更新 ISR，Strimzi 把它封装成 KafkaRebalance（Cruise Control 生成提案，人工 approve 后执行），底层等价于 kafka-reassign-partitions.sh。
</details>

## 延伸阅读

- 官方配置清单（broker/producer/consumer 全量默认值）：https://kafka.apache.org/documentation/#configuration
- 官方 log compaction 文档：https://kafka.apache.org/documentation/#compaction
- kafka_exporter 指标与部署：https://github.com/danielqsj/kafka_exporter
- Strimzi 快速上手（版本组合以官方为准）：https://strimzi.io/docs/quickstart/latest/
- Strimzi Kafka CR 文档：https://strimzi.io/docs/operators/latest/configuring
- Cruise Control 与 KafkaRebalance：https://strimzi.io/docs/operators/latest/deploying#con-kafka-rebalancing-str

