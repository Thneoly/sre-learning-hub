# Lab 01 · Strimzi 起三 broker 集群：建 topic、验生产消费、看 lag 与扩容分布

> 难度：★★☆ ｜ 考点：CKA-CRD 与 Operator / 自建中间件运维 ｜ 前置：第 3 章 Strimzi 一节 ｜ 预计 45~60 分钟

## 前置条件与环境说明

- 一套可用的 kubeadm 练习集群（单 master + Calico 即可），节点能访问 `quay.io` 与 `github.com` 拉镜像/安装文件。
- 资源需求：Operator + 3~4 个 broker（lab 内堆压到 512m）+ Entity Operator + Cruise Control + kafka-exporter，节点建议 8 GB 以上内存、8 GB 以上空闲磁盘（ephemeral 存储走 emptyDir）。
- 用到的镜像：`quay.io/strimzi/operator:0.46.0`、`quay.io/strimzi/kafka:0.46.0-kafka-3.9.0` 及配套组件镜像。
- 环境不具备时（无集群但有 Docker 的 Ubuntu VM）：可用第 3 章 `docker compose` 三节点方式演练除 CR/Operator 外的步骤（topic、lag、分区分布命令完全一致）。

## 场景

团队决定把测试环境的 Kafka 迁到 Kubernetes 上，由 Strimzi 统一管理。领导给你的验收条件是：**三 broker 的集群 `my-cluster`（KRaft 模式）、业务 topic `orders`（6 分区 3 副本）、能证明消息真的生产消费过、能展示一个有积压的消费组（lag > 0）给监控接入手册当样例**。另外下季度要扩容到 4 台 broker，你顺手做一次扩容演练，并回答一个问题：新 broker 上线后，`orders` 的分区有没有自动搬过去？

内部网络还没有 TLS/认证改造计划，客户端统一走集群内 `PLAINTEXT` listener（`my-cluster-kafka-bootstrap:9092`）即可，但 lag 监控要能从 kafka-exporter 抓到指标。

## 任务清单

1. 创建 namespace `kafka-lab`，安装 Strimzi 0.46.0 Operator（watch 该 namespace），确认 `deployment/strimzi-cluster-operator` Ready。
2. 部署 `Kafka` CR `my-cluster` + `KafkaNodePool` `kafka`：3 副本（controller+broker 双角色）、KRaft（Kafka 3.9.0）、内部 `plain` listener 9092（不加密）、`min.insync.replicas=2`、`default.replication.factor=3`、开启 `entityOperator` 与 `kafkaExporter`、`cruiseControl`；存储用 `ephemeral`；JVM 堆 512m。注意：Kafka CR 上必须带 `strimzi.io/node-pools: enabled` 与 `strimzi.io/kraft: enabled` 两个注解（0.46 缺注解会直接报错拒绝调和）。
3. 创建 `KafkaTopic` CR `orders`：6 分区、3 副本、`retention.ms=604800000`、`min.insync.replicas=2`，确认 status 为 Ready。
4. 在 broker Pod 内验证生产消费：向 `orders` 生产 300 条带 key 的消息；用消费者组 `order-workers` 从头消费 100 条后退出（组位移已提交）。
5. 用 `kafka-consumer-groups.sh --describe` 展示 `order-workers` 的 lag（应约为 200）；再用 port-forward 访问 kafka-exporter 的 `/metrics`，grep 出该组的 `kafka_consumergroup_current_offset` / `kafka_consumergroup_log_offset`（exporter 没有 Service，port-forward 目标用 `deploy/my-cluster-kafka-exporter`）。
6. 把 `KafkaNodePool` 扩到 `replicas: 4`，等新 broker Ready；用 `kafka-topics.sh --describe --topic orders` 记录分区副本分布，回答"新 broker 是否分到了旧分区"。（可选加分）用 `KafkaRebalance`（mode: add-brokers）把分区搬过去。
7. 运行 `./check.sh`，输出 `SCORE: 9/9`。

## 验收标准

- `kubectl -n kafka-lab get kafka my-cluster` 的 READY 列为 `True`（或 condition Ready=True）；
- `my-cluster-kafka-0` ~ `my-cluster-kafka-3` 四个 Pod 全部 Running（扩容后）；
- `KafkaTopic/orders` READY=True、PARTITIONS=6、REPLICAS=3，且 `--describe` 显示每个分区 Isr 有 3 个 broker；
- `order-workers` 组存在，总 lag >= 1；
- kafka-exporter 的 metrics 里能查到 `order-workers` 的位移指标；
- `./check.sh` 输出 `SCORE: 9/9`。

## 提示（卡住再看）

<details><summary>提示 1：Operator 安装后不动，集群却起不来</summary>

看 Operator 日志：`kubectl -n kafka-lab logs deploy/strimzi-cluster-operator --tail=50`。常见原因是 CRD 未就绪就 apply 了 Kafka CR（等几十秒再 apply）、节点拉不动 quay.io 镜像（node 上 `crictl pull` 手工验证）、或内存不足导致 broker 反复 OOMKilled（`kubectl get pods` 看 RESTARTS，压小 -Xmx 或加节点内存）。
</details>

<details><summary>提示 2：Pod 名为什么不是 my-cluster-broker-0？</summary>

Strimzi 的节点池模式下，Pod 以 `<cluster>-<pool>` 命名。本 lab 池名叫 `kafka`，所以 Pod 是 `my-cluster-kafka-0/1/2/3`，bootstrap service 仍是 `my-cluster-kafka-bootstrap:9092`。注意：0.46 起 operator 直接管理这些 Pod（namespace 里查不到 StatefulSet），`rollout status sts/...` 会 NotFound；等扩容的新 broker 就绪用 `kubectl -n kafka-lab wait pod/my-cluster-kafka-3 --for=condition=Ready --timeout=600s`。
</details>

<details><summary>提示 3：容器里怎么快速生产 300 条带 key 的消息？</summary>

console-producer 支持 key 解析属性：`--property parse.key=true --property key.separator=:`，stdin 每行 `key:value`。用 `user$((i % 10)):order-$i` 生成 10 个 key，能散到多个分区（见第 1 章 murmur2 路由）。
</details>

<details><summary>提示 4：消费 100 条就退，组位移会不会没提交？</summary>

`--max-messages 100` 达到后 console-consumer 正常关闭，关闭时会提交位移（enable.auto.commit 默认 true，且 close 触发同步提交）。退出后再 `--describe` 就能看到 CURRENT-OFFSET 停在 100 附近、LAG 约 200。
</details>

<details><summary>提示 5：扩容后怎么"证明"分区没动？</summary>

对比扩容前后两次 `kafka-topics.sh --describe --topic orders` 输出的 Replicas/Isr 列：新 broker（节点 ID 最大的那个）不会出现在旧分区的副本列表里。想让分区搬过去，需要 KafkaRebalance（集群 CR 里先开 `cruiseControl: {}`）或 `kafka-reassign-partitions.sh`。
</details>
