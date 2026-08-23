#!/usr/bin/env bash
# Lab 01 检查脚本：Strimzi 三/四 broker 集群 + topic + 消费 lag
# 用法：chmod +x check.sh && ./check.sh
# 运行位置：任何已配置集群 kubeconfig 的机器（如 master 节点）。
# 假设：按 solution.md 在 namespace kafka-lab 完成部署：
#   - deployment/strimzi-cluster-operator 就绪
#   - Kafka/my-cluster（含 KafkaNodePool kafka，最终 replicas=4）
#   - KafkaTopic/orders（6 分区 3 副本，Ready）
#   - 消费组 order-workers 存在未消费完的 lag
# 本脚本只做只读检查（kubectl get/exec 查询比对），不修改集群。
set -u

NS=kafka-lab
CLUSTER=my-cluster
TOPIC=orders
GROUP=order-workers
POD=my-cluster-kafka-0
BOOTSTRAP=my-cluster-kafka-bootstrap:9092
PASS=0; FAIL=0; TOTAL=0

report() { # $1 为上一命令退出码(0=通过), $2 为用例描述
  TOTAL=$((TOTAL+1))
  if [ "$1" -eq 0 ]; then
    PASS=$((PASS+1)); echo "PASS: $2"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $2"
  fi
}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "错误：未找到 kubectl，请在有集群 kubeconfig 的机器上运行"
  exit 1
fi

# 1. namespace 存在
[ -n "$(kubectl get ns "$NS" -o name 2>/dev/null)" ]
report $? "namespace $NS 存在"

# 2. Strimzi Operator Deployment Ready
op_ready=$(kubectl -n "$NS" get deploy strimzi-cluster-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${op_ready:-0}" -ge 1 ]
report $? "deployment/strimzi-cluster-operator Ready 副本 >= 1（当前 ${op_ready:-0}）"

# 3. Kafka CR Ready condition
kafka_cond=$(kubectl -n "$NS" get kafka "$CLUSTER" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
[ "$kafka_cond" = "True" ]
report $? "Kafka/$CLUSTER condition Ready=True（当前 ${kafka_cond:-无}）"

# 4. KafkaNodePool 扩容到 4 副本且 Pod 全部 Running
pool_replicas=$(kubectl -n "$NS" get kafkanodepool kafka -o jsonpath='{.spec.replicas}' 2>/dev/null)
kafka_running=$(kubectl -n "$NS" get pods --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -Ec "^${CLUSTER}-kafka-[0-9]+$")
[ "${pool_replicas:-0}" -eq 4 ] && [ "${kafka_running:-0}" -ge 4 ]
report $? "KafkaNodePool replicas=4 且 Running broker Pod >= 4（spec=${pool_replicas:-无}, running=${kafka_running:-0}）"

# 5. KafkaTopic CR：Ready、6 分区、3 副本
topic_cond=$(kubectl -n "$NS" get kafkatopic "$TOPIC" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
topic_parts=$(kubectl -n "$NS" get kafkatopic "$TOPIC" -o jsonpath='{.spec.partitions}' 2>/dev/null)
topic_repl=$(kubectl -n "$NS" get kafkatopic "$TOPIC" -o jsonpath='{.spec.replicas}' 2>/dev/null)
[ "$topic_cond" = "True" ] && [ "${topic_parts:-0}" -eq 6 ] && [ "${topic_repl:-0}" -eq 3 ]
report $? "KafkaTopic/$TOPIC Ready=True, partitions=6, replicas=3（Ready=${topic_cond:-无}, p=${topic_parts:-无}, r=${topic_repl:-无}）"

# 6. 集群内实测：6 个分区，每个分区 Replicas/Isr 都是 3 个 broker
describe_out=$(kubectl -n "$NS" exec "pod/$POD" -c kafka -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server "$BOOTSTRAP" --describe --topic "$TOPIC" 2>/dev/null)
part_lines=$(printf '%s\n' "$describe_out" | grep -c 'Partition:')
iso_ok=$(printf '%s\n' "$describe_out" | awk '/Partition:/ {
  if (match($0, /Replicas: [0-9,]+/)) { n = split(substr($0, RSTART + 10, RLENGTH - 10), a, ",") } else { n = 0 }
  if (match($0, /Isr: [0-9,]+/)) { m = split(substr($0, RSTART + 5, RLENGTH - 5), b, ",") } else { m = 0 }
  if (n == 3 && m == 3) ok++
} END {print ok+0}')
[ "${part_lines:-0}" -eq 6 ] && [ "${iso_ok:-0}" -eq 6 ]
report $? "topic $TOPIC 实测 6 个分区且每分区 Replicas/Isr 均为 3（分区=${part_lines:-0}, 达标=${iso_ok:-0}）"

# 7. topic 里确实有数据：各分区 latest offset 之和 >= 200
offsets_sum=$(kubectl -n "$NS" exec "pod/$POD" -c kafka -- \
  /opt/kafka/bin/kafka-get-offsets.sh --bootstrap-server "$BOOTSTRAP" --topic "$TOPIC" 2>/dev/null \
  | awk -F: '{s+=$3} END {print s+0}')
[ "${offsets_sum:-0}" -ge 200 ]
report $? "topic $TOPIC 已生产消息（分区 offset 之和 ${offsets_sum:-0} >= 200）"

# 8. 消费组 order-workers 存在且有 lag
lag_sum=$(kubectl -n "$NS" exec "pod/$POD" -c kafka -- \
  /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server "$BOOTSTRAP" --describe --group "$GROUP" 2>/dev/null \
  | awk '$6 ~ /^[0-9]+$/ {s+=$6} END {print s+0}')
[ "${lag_sum:-0}" -ge 1 ]
report $? "消费组 $GROUP 存在且总 lag ${lag_sum:-0} >= 1"

# 9. kafka-exporter 已随集群部署
exp_ready=$(kubectl -n "$NS" get deploy "$CLUSTER-kafka-exporter" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${exp_ready:-0}" -ge 1 ]
report $? "deployment/$CLUSTER-kafka-exporter Ready 副本 >= 1（当前 ${exp_ready:-0}）"

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
