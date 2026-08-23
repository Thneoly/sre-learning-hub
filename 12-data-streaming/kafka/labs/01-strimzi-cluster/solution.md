# Lab 01 · 解答：Strimzi 三 broker 集群、lag 观察与扩容分布

目标拓扑：

```
kafka-lab 命名空间
├── deployment/strimzi-cluster-operator        ← Strimzi 0.46.0，watch 本 ns
├── Kafka/my-cluster                           ← KRaft, Kafka 3.9.0, plain 9092
│     └── KafkaNodePool/kafka                  ← controller+broker 双角色
│           ├── my-cluster-kafka-0/1/2         ← StatefulSet（最终扩到 -3）
├── deployment/my-cluster-entity-operator      ← Topic/User Operator
├── deployment/my-cluster-cruise-control       ← 再均衡（加分项用）
├── deployment/my-cluster-kafka-exporter       ← lag 指标 :9404
├── KafkaTopic/orders                          ← 6 分区 3 副本
└── 消费组 order-workers                        ← 消费 100/300，lag≈200
```

## 步骤 1：namespace 与 Operator

为什么先装 Operator：CRD 必须先注册，`Kafka` 等 CR 才能被 API Server 接受。Strimzi 官方安装文件默认 watch 部署它的 namespace，用 sed 把所有 `namespace:` 改成 `kafka-lab`（这是官方快速上手的推荐做法，只影响 ServiceAccount 引用与部署位置，不动镜像）。

```bash
# [master]
kubectl create namespace kafka-lab

curl -Lsf https://github.com/strimzi/strimzi-kafka-operator/releases/download/0.46.0/strimzi-cluster-operator-0.46.0.yaml \
  | sed 's/namespace: .*/namespace: kafka-lab/' \
  | kubectl -n kafka-lab apply -f -

kubectl -n kafka-lab rollout status deploy/strimzi-cluster-operator --timeout=300s
```

预期输出最后一句：`deployment "strimzi-cluster-operator" successfully rolled out`。

## 步骤 2：Kafka CR + KafkaNodePool

为什么用 KafkaNodePool：0.46 是 KRaft-only 版本，`replicas` 与 `storage` 定义在节点池上，集群 CR 只负责版本、listener、配置。双角色（controller+broker）节点适合练习集群，生产上大集群会分离。`cruiseControl: {}` 现在就打开，是为了加分项的 KafkaRebalance 能直接用。

坑位提醒：0.46 里这两个注解**必填**——缺了 operator 会直接抛 `InvalidConfigurationException: Strimzi 0.46.0 supports only KRaft-based Apache Kafka clusters`，Kafka CR 永远起不来（这是从旧版 YAML 迁移过来最常见的翻车点）。

```bash
# [master]
kubectl -n kafka-lab apply -f - <<'EOF'
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
    type: ephemeral
  resources:
    requests:
      memory: 1Gi
      cpu: 300m
    limits:
      memory: 1Gi
      cpu: "1"
---
apiVersion: kafka.strimzi.io/v1beta2
kind: Kafka
metadata:
  name: my-cluster
  namespace: kafka-lab
  annotations:
    strimzi.io/node-pools: enabled
    strimzi.io/kraft: enabled
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
      "-Xmx": "512m"
    resources:
      requests:
        memory: 1Gi
        cpu: 300m
      limits:
        memory: 1Gi
        cpu: "1"
  entityOperator:
    topicOperator: {}
    userOperator: {}
  cruiseControl: {}
  kafkaExporter: {}
EOF
```

验证：CR Ready 且三个 broker Pod 全部 Running（首次拉镜像可能要几分钟）。

```bash
# [master]
kubectl -n kafka-lab get kafka my-cluster -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
# 预期：True

kubectl -n kafka-lab get pods -l strimzi.io/name=my-cluster-kafka
# 预期：my-cluster-kafka-0/1/2 均 1/1 Running
```

坑位提醒：Ready 迟迟不来，先看 `kubectl -n kafka-lab describe kafka my-cluster` 顶部的 conditions（会写明缺什么），再看 operator 日志。单 master 小内存机器上，把 `-Xmx` 与 requests 再压小一档是活路。

## 步骤 3：KafkaTopic CR

为什么用 CR 而不是命令行建 topic：TopicOperator 会把 spec 持续调和回真实集群，`kubectl get kafkatopic` 即资产台账；直接命令行建的 topic 不在管理面内，下次调和可能被改回。

```bash
# [master]
kubectl -n kafka-lab apply -f - <<'EOF'
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
EOF

kubectl -n kafka-lab wait kafkatopic/orders --for=condition=Ready --timeout=120s
# 预期：kafkatopic.kafka.strimzi.io/orders condition met
```

## 步骤 4：生产 300 条、消费 100 条

为什么带 key：无 key 消息走 sticky 分区器，300 条小消息可能挤在一个分区里；带 10 个 key（murmur2 hash）能散到多个分区，后面看 lag 和分区分布才有内容。命令都通过 `kubectl exec` 在 broker Pod 内跑，用 Strimzi 自带的 Kafka 镜像工具，不依赖外部镜像。

```bash
# [master] 生产 300 条 key:value 消息
kubectl -n kafka-lab exec -i pod/my-cluster-kafka-0 -c kafka -- bash -c \
  'for i in $(seq 1 300); do echo "user$((i % 10)):order-$i"; done | \
   /opt/kafka/bin/kafka-console-producer.sh \
   --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic orders \
   --property parse.key=true --property key.separator=:'
# 预期：无输出（非交互模式下静默发送完成）

# [master] 消费组 order-workers 从头消费 100 条后退出
kubectl -n kafka-lab exec -i pod/my-cluster-kafka-0 -c kafka -- bash -c \
  '/opt/kafka/bin/kafka-console-consumer.sh \
   --bootstrap-server my-cluster-kafka-bootstrap:9092 --topic orders \
   --group order-workers --from-beginning --max-messages 100 > /dev/null'
# 预期：输出 100 条后自动退出并提交位移
```

如果想在集群外（跳板机装了 kcat）验证，等价命令：

```bash
# [任意有 kcat 的机器] 先 port-forward，再生产消费
kubectl -n kafka-lab port-forward svc/my-cluster-kafka-bootstrap 9092:9092 &
echo "user9:order-x" | kcat -b localhost:9092 -t orders -P -K:
kcat -b localhost:9092 -t orders -C -o beginning -c 5 -u -q
```

## 步骤 5：观察 lag（两条路径）

```bash
# [master] 路径 1：broker 端管理 API，LAG 列即积压
kubectl -n kafka-lab exec pod/my-cluster-kafka-0 -c kafka -- \
  /opt/kafka/bin/kafka-consumer-groups.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 --describe --group order-workers
# 预期（示意，分区分布随 key hash 变化）：
# GROUP          TOPIC  PARTITION  CURRENT-OFFSET  LOG-END-OFFSET  LAG  ...
# order-workers  orders 0          17              50              33
# order-workers  orders 1          16              51              35
# ...（LAG 合计约 200；组无活跃成员时另起一行提示，属正常）
```

```bash
# [master] 路径 2：kafka-exporter 指标（生产上接 Prometheus 的那条路）
# 注意：Strimzi 不会为 kafka-exporter 创建 Service（监控栈是靠 PodMonitor 直接抓 Pod），
# port-forward 要指到 deployment 上而不是 svc。
kubectl -n kafka-lab port-forward deploy/my-cluster-kafka-exporter 9404:9404 &
sleep 3
curl -s http://localhost:9404/metrics | grep 'kafka_consumergroup_.*orders'
# 预期形如：
# kafka_consumergroup_current_offset{consumergroup="order-workers",topic="orders",partition="0"} 17
# kafka_consumergroup_log_offset{consumergroup="order-workers",topic="orders",partition="0"} 50
# 告警用的 lag 即两者相减（第 3 章 PromQL）
kill %1
```

## 步骤 6：扩容到 4 broker，看分区分布

```bash
# [master] 扩节点池副本数
kubectl -n kafka-lab scale kafkanodepool/kafka --replicas=4
kubectl -n kafka-lab wait pod/my-cluster-kafka-3 --for=condition=Ready --timeout=600s
# 预期：my-cluster-kafka-3 起来，输出 pod/my-cluster-kafka-3 condition met
```

坑位提醒：0.46 里 operator **直接管理 Pod**（经它内部的 PodSet 控制器），`kubectl -n kafka-lab get sts` 是空的，`rollout status sts/my-cluster-kafka` 会直接 NotFound——等新 broker 就绪请用上面的 `kubectl wait pod/...`。另外扩容会触发 operator 重新渲染 Pod spec（证书 SAN、配置 revision 变化），旧 Pod 可能被顺带滚动（事件里写 `Rolling Pod ... due to [Pod has old revision]`），滚动期间 ISR 会短暂缩到 2，等它滚完自然回满，不用手动干预。

```bash
# [master] 确认分区没动
kubectl -n kafka-lab exec pod/my-cluster-kafka-0 -c kafka -- \
  /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server my-cluster-kafka-bootstrap:9092 --describe --topic orders
# 预期：6 个分区的 Leader/Replicas/Isr 全部只含节点 0/1/2 ——
#       新 broker（节点 3）一个旧分区都没分到
```

这一步要写进演练报告的结论：**Kafka 分区分配是静态元数据，扩容不会自动迁移**（第 3 章第 6 节）。新 broker 只会承接新建分区，忙闲不均要靠再均衡解决。

可选加分项——用 KafkaRebalance 把分区搬上节点 3（集群 CR 已开 cruiseControl）：

```bash
# [master]
kubectl -n kafka-lab apply -f - <<'EOF'
apiVersion: kafka.strimzi.io/v1beta2
kind: KafkaRebalance
metadata:
  name: orders-add-broker
  namespace: kafka-lab
  labels:
    strimzi.io/cluster: my-cluster
spec:
  mode: add-brokers
  brokers: [3]
EOF

kubectl -n kafka-lab get kafkarebalance orders-add-broker -w
# 预期状态流转：NotReady → PendingProposal → ProposalReady
# （ProposalReady 后按 Ctrl+C 退出 watch）

kubectl -n kafka-lab annotate kafkarebalance orders-add-broker strimzi.io/rebalance=approve
kubectl -n kafka-lab get kafkarebalance orders-add-broker -w
# 预期：Rebalancing → Ready；随后再 describe orders，节点 3 已出现在部分分区的 Replicas/Isr
```

加分项收尾：再均衡完成后删掉这个 CR 不会影响已完成的迁移（`kubectl -n kafka-lab delete kafkarebalance orders-add-broker`），Cruise Control 资源也能留着给下次用。

## 步骤 7：跑 check.sh

```bash
# [master]
cd 12-data-streaming/kafka/labs/01-strimzi-cluster
chmod +x check.sh
./check.sh
```

通过输出（9/9）：

```
PASS: namespace kafka-lab 存在
PASS: deployment/strimzi-cluster-operator Ready 副本 >= 1（当前 1）
PASS: Kafka/my-cluster condition Ready=True（当前 True）
PASS: KafkaNodePool replicas=4 且 Running broker Pod >= 4（spec=4, running=4）
PASS: KafkaTopic/orders Ready=True, partitions=6, replicas=3（Ready=True, p=6, r=3）
PASS: topic orders 实测 6 个分区且每分区 Replicas/Isr 均为 3（分区=6, 达标=6）
PASS: topic orders 已生产消息（分区 offset 之和 300 >= 200）
PASS: 消费组 order-workers 存在且总 lag 200 >= 1
PASS: deployment/my-cluster-kafka-exporter Ready 副本 >= 1（当前 1）

SCORE: 9/9
```

## 复盘清单

- 三 broker 的可靠性基线是什么参数撑起来的：`replicas: 3`（KafkaTopic）+ `min.insync.replicas: 2`（config）+ 客户端 `acks=all`，缺一个都退化（第 2 章矩阵）。
- lag 的两个口径：管理 API 的 LAG 列（人看）与 exporter 的两指标相减（告警用），数值必须对得上。
- 扩容四步节奏：scale → 等 Ready → describe 确认分区没动 → KafkaRebalance/approve 搬分区。
- 收尾清理（可选）：`kubectl delete ns kafka-lab` 会级联删除全部 CR 与工作负载；Operator 想留就只删 Kafka CR。
