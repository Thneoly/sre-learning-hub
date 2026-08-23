# 02 · Flink 部署架构与 Exactly-once：从 slot 到两阶段提交

> 模块：12-data-streaming/flink ｜ 建议时长：3.5 小时 ｜ 关联认证：—（无直接考题；JobManager HA、slot 调度、K8s Operator 部署大量复用 CKA 的 Deployment/Service/PVC 知识）

## 学习目标

- 能画出 JobManager（Dispatcher/JobMaster/ResourceManager）、TaskManager、slot 三层关系，并算出"并行度 N 的作业需要多少 slot"
- 能讲清一次 checkpoint 的完整流程：barrier 注入、对齐、状态快照、确认，及其与 Chandy-Lamport 分布式快照的对应关系
- 能配置三种重启策略，并解释"作业内重启"与"K8s 层 Pod 重启"的分工
- 能解释端到端 exactly-once 的三个前提，写出 KafkaSink 两阶段提交的关键参数及其约束
- 能用 Web UI 与 backPressuredTimeMsPerSecond 指标定位反压瓶颈，并用 Flink Kubernetes Operator 完成 Application 模式部署与 savepoint 升级

## 1. 运行时架构：JobManager、TaskManager、slot 与并行度

```
                ┌──────────────── JobManager（控制面，一个 JVM）────────────────┐
 REST 8081 ───► │  Dispatcher        JobMaster              ResourceManager     │
 CLI 提交  ───► │  (REST/提交入口)    (每个作业一个,        (slot 的分配/回收,   │
                │                     触发 checkpoint)       K8s 下向 API Server │
                └─────────▲───────────────▲────────────────── 请求 TM Pod) ─────┘
                          │ slot 请求/授予 │ 心跳、状态汇报、checkpoint ACK
                ┌─────────┴────┐   ┌──────┴───────┐   ┌──────────────┐
                │ TaskManager  │   │ TaskManager  │   │ TaskManager  │  数据面，一 JVM
                │ [slot][slot] │   │ [slot][slot] │   │ [slot][slot] │  算子链(chain)
                └──────────────┘   └──────────────┘   └──────────────┘  在 slot 内执行
                       TaskManager 之间: netty 网络 shuffle(credit-based 流控)
```

- **JobManager 不是单点职责**：Dispatcher 负责 REST/CLI 接活；JobMaster 拿到 JobGraph 后向 ResourceManager 要 slot、部署任务、触发 checkpoint；ResourceManager 只管 slot 池（standalone 集群向本地 TM 要，K8s 上直接创建 TM Pod）。HA 模式下这三者会整体做 leader election。
- **slot 是 TM 内的资源分片**：数量由 `taskmanager.numberOfTaskSlots` 决定，只隔离内存（各 slot 平分 managed memory），不隔离 CPU。同一个作业的算子链（chained operators）默认共享 slot，所以"并行度 P 的作业默认只占 P 个 slot"，而不是所有算子并行度之和。
- **并行度是 subtask 数**：`env.setParallelism()`（或 SQL 的 `parallelism.default`）是默认值，单个算子可用 `setParallelism()` 覆盖；作业能跑起来的条件是所有 slot sharing group 中最高并行度 ≤ 集群总 slot 数。排查"作业卡 DEPLOYING"第一步就是数 slot。对照 K8s 心智模型：JobManager 像控制面组件，TaskManager 像节点上的工作进程，slot 是它的最小资源分片，job 像一个有生命周期的应用实例。

## 2. JobManager HA

JM 挂了所有作业全停，所以生产必须 HA。leader election 后端有三类：`none`（单点）、`zookeeper`、`kubernetes`（用 ConfigMap 里的 lease 选主，K8s 上首选）。

```yaml
# [flink-conf.yaml（K8s 部署时的 JM 配置）]
high-availability.type: kubernetes
high-availability.kubernetes.cluster-id: wordcount-ha     # Operator 部署时默认取资源名
high-availability.storageDir: file:///opt/flink/ha        # job 元数据与恢复指针, 必须持久卷
kubernetes.cluster-id: wordcount-ha
```

故障切换流程：standby JM 抢到 lease → 从 `storageDir` 读到 job 元数据与最近 completed checkpoint 指针 → TM 重新连接新 leader → 从 checkpoint 恢复状态继续跑。要点是 `storageDir` 必须落在**持久卷**上（PVC/hostPath），否则"JM Pod 换了个节点，恢复指针就没了"，HA 形同虚设——和 etcd 数据目录必须持久化是同一个道理。

## 3. Checkpoint 全流程：barrier 对齐与分布式快照

Flink 的容错基于 Chandy-Lamport 分布式快照思想：往数据流里注入一个**特殊标记（barrier n）**，它随数据一起流动，把流切成"属于第 n 次快照之前"和"之后"两段；每个算子看到 barrier 就把自己"此刻之前"的状态存下来，全员存完，全局快照即一致。

一次 checkpoint 的完整流程：

1. JM 的 CheckpointCoordinator 到达间隔（`execution.checkpointing.interval`），向所有 source subtask 触发 checkpoint n；
2. source 把 barrier n 广播给所有下游 channel，然后快照自身状态（Kafka source 把**当前消费 offset** 存进去，这就是恢复后重放的依据）；
3. 中间算子从某个输入 channel 收到 barrier n 后**阻塞该 channel**（数据进缓冲区），等**所有**输入 channel 的 barrier n 都到齐（对齐），期间先到的 barrier 所在 channel 的数据被缓存；
4. 对齐完成后快照自身状态，把 barrier n 继续广播给下游，再回头处理缓冲的数据；
5. sink 汇齐 barrier、状态持久化成功后向 JM 确认；JM 收齐所有 ACK 且状态落盘后，checkpoint n 标记 completed，通知各算子（sink 收到 `notifyCheckpointComplete`，第 5 节两阶段提交在此提交事务）。

```
Source-1 ──data──data──[B]──data────►  Window-0
Source-2 ──data──[B]──data──data────►  Window-0
                        └─ 后到的 barrier: 先到 B 的那个 channel 数据被缓冲(blocking),
                           直到两个 B 都到 → 状态快照 → 广播 B → 放行缓冲数据
```

**对齐的代价**：反压严重时 barrier 走得慢，缓冲区堆积，checkpoint 可能超时失败。两条出路：

```yaml
# [flink-conf.yaml]
execution.checkpointing.interval: 30 s            # 触发间隔
execution.checkpointing.mode: exactly-once        # barrier 对齐; at-least-once 则跳过对齐
execution.checkpointing.timeout: 10 min           # 单次超时
execution.checkpointing.min-pause: 5 s            # 两次之间的最小间隔, 防止连环做快照
execution.checkpointing.unaligned: true           # 反压场景: barrier 直接越过大缓冲, 把 in-flight 数据一起存
state.backend: rocksdb
state.backend.incremental: true                   # 增量: 只上传新增 SST, 大状态必备
state.checkpoints.dir: file:///opt/flink/checkpoints
state.checkpoints.num-retained: 3
execution.checkpointing.externalized-checkpoint-retention: RETAIN_ON_CANCELLATION
```

unaligned checkpoint 用"把未处理数据也存进快照"换"barrier 不用等对齐"，代价是快照更大、恢复时要重放 in-flight 数据，适合反压重的作业；对齐式（exactly-once mode）快照更小，适合常态作业。

## 4. 重启策略：作业内的故障恢复

checkpoint 解决"状态从哪恢复"，重启策略决定"失败后要不要恢、恢几次"。这是**作业内重启**（JM 还活着，TaskThread 抛异常），与 K8s 把 crash 的 Pod 拉起来是两个层次：Pod 重启丢的是进程，作业内重启丢的是一次执行，两者都依赖持久化的 checkpoint。

```yaml
# [flink-conf.yaml] 三选一（注释掉未选的两个）
# A 固定延迟——简单可控，最常用
restart-strategy: fixed-delay
restart-strategy.fixed-delay.attempts: 5
restart-strategy.fixed-delay.delay: 10 s
# B 失败率——单位时间错太多就放弃，防止雪崩式无效重试
#restart-strategy: failure-rate
#restart-strategy.failure-rate.max-failures-per-interval: 3
#restart-strategy.failure-rate.failure-rate-interval: 5 min
#restart-strategy.failure-rate.delay: 10 s
# C 指数退避——外部依赖抖动场景，越挫退避越长
#restart-strategy: exponential-delay
#restart-strategy.exponential-delay.initial-backoff: 1 s
#restart-strategy.exponential-delay.max-backoff: 1 min
#restart-strategy.exponential-delay.backoff-multiplier: 2.0
```

重启动作 = 从最近一次 completed checkpoint 恢复状态 + source 重置到快照里的 offset 重新消费。重试耗尽后作业进入 FAILED（K8s Operator 部署时表现为 CR 状态 RESTARTING/DEPLOY_FAILED，由 operator 决定是否重建）。未显式配置时，开启 checkpoint 会启用一个尝试次数极大的 fixed-delay 默认值，生产上务必显式声明（以官方文档为准）。

## 5. 端到端 exactly-once：三个前提缺一不可

"作业内部状态精确一次"只覆盖算子之间。数据从 source 进到 sink 出，全程 exactly-once 需要三段各自成立：

1. **内部**：barrier 对齐的 checkpoint（第 3 节），保证算子状态不多不少；
2. **source 可重放**：Kafka source 把 offset 存进 checkpoint，恢复后从该 offset 重新读（Kafka 的可重放性是整套机制的地基，见本模块 Kafka 章）；
3. **sink 事务性**：输出要么可见要么不可见，不能"半可见"。Flink 用**两阶段提交（2PC）**实现：数据先写进一个未提交事务（对外不可见），checkpoint 全部完成后再统一 commit。

```
sink 算子        JM(CheckpointCoordinator)         Kafka broker
  │ beginTransaction: 开事务, 数据写入但对 read_committed 消费者不可见 ─►│
  │◄─ barrier n 到达 ────────────────────────────────────────────────────│
  │ preCommit: flush 并把事务句柄写进 checkpoint 状态 ─────────────────► │
  │ 快照完成 ACK（所有算子 ACK 且状态持久化完成后）                       │
  │◄─ notifyCheckpointComplete(n) ────────────────────────────────────── │
  │ commit(n): 提交事务, 数据此刻才对消费者可见 ────────────────────────►│
  失败路径: 没等到 complete → abort, 消费者从未见过这批数据 → 恢复后重放
```

KafkaSink 关键参数：

```java
// [开发机：DataStream API 代码]
KafkaSink<String> sink = KafkaSink.<String>builder()
    .setBootstrapServers("kafka-1:9092")
    .setRecordSerializer(KafkaRecordSerializationSchema.builder()
        .setTopic("flink-out")
        .setValueSerializationSchema(new SimpleStringSchema())
        .build())
    .setDeliveryGuarantee(DeliveryGuarantee.EXACTLY_ONCE)
    .setTransactionalIdPrefix("flink-wc-")            // 跨重启延续同一事务序列
    .setProperty("transaction.timeout.ms", "600000")  // 必须 > checkpoint 间隔 + 预期恢复时长
    .build();
```

```sql
-- [sql-client（连接到 Flink 集群）]
CREATE TABLE kafka_sink (
  window_start TIMESTAMP(3), window_end TIMESTAMP(3), cnt BIGINT
) WITH (
  'connector' = 'kafka',
  'topic' = 'flink-out',
  'properties.bootstrap.servers' = 'kafka-1:9092',
  'format' = 'json',
  'sink.delivery-guarantee' = 'exactly-once',
  'sink.transactional-id-prefix' = 'flink-wc-',
  'properties.transaction.timeout.ms' = '600000'
);
```

三条硬约束，违反任何一条 exactly-once 都会破功：

- `transaction.timeout.ms` 必须**大于** checkpoint 间隔加上预期的故障恢复时长（事务要一直活到 commit），且**不能超过** broker 端 `transaction.max.timeout.ms`（默认 15 分钟）——所以 checkpoint 间隔不能拉太长；
- 下游消费者必须 `isolation.level=read_committed`（`kafka-console-consumer --isolation-level read_committed`），否则照样读到未提交数据，exactly-once 变自欺；
- 如果只能做到幂等写入（如按主键 upsert 的库），可以退而求其次 at-least-once + 幂等，延迟与吞吐都更好。

## 6. 反压：原理与定位

**原理**：Flink 的 TaskManager 之间用 netty 的 credit-based 流控——接收方通告可用 buffer 数（credit），发送方按 credit 发。下游某算子处理不过来 → 输入 buffer 满 → 停止接收 → 上游的输出 buffer 发不出去 → 上游 subtask 阻塞在发送上，腾不出手处理自己的输入 → 逐级回传到 source（Kafka source 停止 fetch）。反压本身是**保护机制**（不丢数据不爆内存），病根是链路上最慢的那个算子。

```
Source ──► Parse ──► WindowAgg(慢/倾斜) ──► Sink
  ▲          ▲            │ 处理不过来
  └──────────┴────────────┘ buffer 满, credit=0, 逐级向上堵
```

**定位**分两步：

1. **Web UI**：作业页点开 Operators，Backpressure 标签按采样给出 ok/high/low（红色即被反压）。被标红的算子是"受害者"，不是"凶手"。
2. **指标**（1.13+ 每个子任务每秒三类时间，加起来约 1000ms）：

| 指标 | 含义 |
|---|---|
| `busyTimeMsPerSecond` | 这一秒里真正在干活的时间 |
| `backPressuredTimeMsPerSecond` | 这一秒里被下游卡住的时间 |
| `idleTimeMsPerSecond` | 这一秒里没数据可处理的时间 |

```bash
# [任意节点]（REST 查询, vertexId 从 /jobs/<jobId> 的 vertices 里取）
curl -s "http://<jobmanager>:8081/jobs/<jobId>/vertices/<vertexId>/subtasks/0/metrics?get=busyTimeMsPerSecond,backPressuredTimeMsPerSecond,idleTimeMsPerSecond"
# 预期: {"id":0,"metrics":[{"id":"busyTimeMsPerSecond","value":"990"},...]}
```

判读口诀：**沿着数据流方向找第一个 backPressured=0 且 busy≈1000 的算子，它就是瓶颈**；它上游全员 backpressured 高。数据倾斜的典型指纹是同一算子的各 subtask 两极分化：一个 busy 顶满、其余 idle——先看是不是热点 key，再看 GC（`garbageCollector` 指标）与外部 IO。扩并行度对热点 key 无效（数据还是哈希到同一个 subtask），治法是打散 key（加盐两阶段聚合）或本地预聚合。

## 7. Flink Kubernetes Operator：把作业变成 CR

Operator 把"Flink 集群 + 作业生命周期"收敛为一个 CRD：`FlinkDeployment`。安装（写作时最新 1.13.0，版本以官方文档为准）：

```bash
# [master]
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
helm repo add flink-operator-repo https://downloads.apache.org/flink/flink-kubernetes-operator-1.13.0/
helm install flink-kubernetes-operator flink-operator-repo/flink-kubernetes-operator \
  --namespace flink-operator --create-namespace
kubectl get pods -n flink-operator -w
# 预期约 1~2 分钟后 flink-kubernetes-operator-xxx 为 1/1 Running
```

| 模式 | CR | 作业怎么进 | 适用 |
|---|---|---|---|
| Application | `FlinkDeployment`（带 `spec.job`） | 集群随作业拉起，main() 在集群里跑 | 生产单作业，资源隔离清晰 |
| Session | `FlinkSessionCluster`（不带 job） | 常驻集群，CLI/SQL Client 提交 | 多个小作业共享集群、探索调试 |

Application 模式的典型 CR（HA + checkpoint + 持久状态目录，可直接 `kubectl apply`）：

```yaml
# [master] flinkdeployment-wordcount.yaml
apiVersion: flink.apache.org/v1beta1
kind: FlinkDeployment
metadata:
  name: wordcount
  namespace: flink-lab
spec:
  image: flink:1.19
  flinkVersion: v1_19
  flinkConfiguration:
    execution.checkpointing.interval: 10 s
    execution.checkpointing.externalized-checkpoint-retention: RETAIN_ON_CANCELLATION
    state.checkpoints.dir: file:///opt/flink/state/checkpoints
    state.savepoints.dir: file:///opt/flink/state/savepoints
    restart-strategy: fixed-delay
    restart-strategy.fixed-delay.attempts: "10"
    restart-strategy.fixed-delay.delay: 5 s
    high-availability.type: kubernetes            # K8s ConfigMap 选主
    high-availability.storageDir: file:///opt/flink/state/ha
    taskmanager.numberOfTaskSlots: "2"
  volumes:                                       # 状态必须落持久卷, 否则重启即丢
    - name: flink-state
      hostPath:
        path: /var/flink-state
        type: Directory
  jobManager:
    resource:
      memory: 1024m
      cpu: 0.5
    volumeMounts:
      - name: flink-state
        mountPath: /opt/flink/state
  taskManager:
    resource:
      memory: 1024m
      cpu: 1
    volumeMounts:
      - name: flink-state
        mountPath: /opt/flink/state
  job:
    jarURI: local:///opt/flink/examples/streaming/SocketWindowWordCount.jar
    entryClass: org.apache.flink.streaming.examples.socket.SocketWindowWordCount
    args: ["--hostname", "wordsrv", "--port", "9000", "--window", "10", "--slide", "10"]
    parallelism: 2
    upgradeMode: savepoint
```

operator 负责：建 `<name>`/`<name>-rest` 两个 Service、JM/TM Deployment、按 `flinkConfiguration` 生成配置、状态写回 CR（`kubectl get flinkdeployment` 直接看 RUNNING/RESTARTING）。生产上把 hostPath 换成 PVC（`storage` 语义与 CKA 存储章一致）；hostPath 只适合单节点练习集群。

## 8. 作业升级与 savepoint 恢复

升级 = "停旧版本（带走状态）+ 起新版本（接上状态）"。operator 的三种升级策略：

| `spec.job.upgradeMode` | 停止时做什么 | 适用 |
|---|---|---|
| `savepoint` | 先做 savepoint 再取消 | 常规发布，最稳 |
| `last-state` | 尽量复用最近一次 state（含 checkpoint） | 紧急回滚/临时扩缩容，最快 |
| `stateless` | 不带状态，全新启动 | 状态结构已变或不需要状态 |

```bash
# [master] 手动触发一次 savepoint（nonce 值变化即触发）
kubectl -n flink-lab patch flinkdeployment wordcount --type merge \
  -p '{"spec":{"job":{"savepointTriggerNonce":1}}}'
kubectl -n flink-lab get flinkdeployment wordcount \
  -o jsonpath='{.status.jobStatus.savepointPath}'; echo
# 预期输出 file:///opt/flink/state/savepoints/savepoint-<hex>-<hex>

# [master] 修改并行度并从指定 savepoint 恢复
kubectl -n flink-lab patch flinkdeployment wordcount --type merge \
  -p '{"spec":{"job":{"parallelism":1,"fromSavepoint":"file:///opt/flink/state/savepoints/savepoint-xxxx"}}}'
```

非 K8s 环境的等价 CLI 流程：`flink savepoint <jobId>` → `flink cancel <jobId>` → `flink run -s <savepointPath> [ -n ]`。无论哪种方式，前提都一样：算子 uid 稳定、savepoint 目录持久化、代码里的状态结构没发生不兼容变更（`-n`/`allowNonRestoredState` 只容忍"少了算子"，不容忍"状态类型变了"）。

## 实战演练

目标：在 Ubuntu VM 的 Docker Flink 上，跑一个带 checkpoint 的常驻 SQL 作业，用 REST 观察 checkpoint，再走一遍"savepoint → 取消 → 从 savepoint 恢复"闭环。

### 步骤 1：起带共享状态卷的集群

```bash
# [任意节点]（Ubuntu VM，已装 Docker 与 compose 插件）
mkdir -p ~/flink-ckpt && cd ~/flink-ckpt
cat > docker-compose.yml <<'EOF'
services:
  jobmanager:
    image: flink:1.19
    ports:
      - "8081:8081"
    volumes:
      - flink-state:/tmp/state
    environment:
      - |
        FLINK_PROPERTIES=
        jobmanager.rpc.address: jobmanager
        state.savepoints.dir: file:///tmp/state/savepoints
  taskmanager:
    image: flink:1.19
    depends_on:
      - jobmanager
    command: taskmanager
    volumes:
      - flink-state:/tmp/state
    environment:
      - |
        FLINK_PROPERTIES=
        jobmanager.rpc.address: jobmanager
        taskmanager.numberOfTaskSlots: 4
volumes:
  flink-state:
EOF
docker compose up -d
```

### 步骤 2：提交带 checkpoint 的常驻作业

```bash
# [任意节点]
cat > job.sql <<'EOF'
SET 'execution.checkpointing.interval' = '5s';

CREATE TABLE nums (
  n INT,
  ts AS LOCALTIMESTAMP,
  WATERMARK FOR ts AS ts - INTERVAL '2' SECOND
) WITH (
  'connector' = 'datagen',
  'rows-per-second' = '10',
  'fields.n.kind' = 'random',
  'fields.n.min' = '0',
  'fields.n.max' = '999'
);

CREATE TABLE sink_t (
  window_start TIMESTAMP(3), window_end TIMESTAMP(3), cnt BIGINT, sum_n BIGINT
) WITH ('connector' = 'print');

INSERT INTO sink_t
SELECT window_start, window_end, COUNT(*), SUM(n)
FROM TABLE(TUMBLE(TABLE nums, DESCRIPTOR(ts), INTERVAL '10' SECOND))
GROUP BY window_start, window_end;
EOF
docker compose cp job.sql jobmanager:/tmp/job.sql
docker compose exec jobmanager ./bin/sql-client.sh -f /tmp/job.sql
# 预期最后输出: [INFO] Submitting SQL update statement to the cluster...
#               Table change response: OK （作业已在集群上常驻, 客户端已退出）
```

### 步骤 3：观察作业与 checkpoint

```bash
# [任意节点] 浏览器打开 http://<VM-IP>:8081 也能看到同样信息
JOB_ID=$(curl -s http://localhost:8081/jobs/overview | grep -o '"jid":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
echo "JOB_ID=$JOB_ID"
curl -s http://localhost:8081/jobs/$JOB_ID/checkpoints | grep -o '"counts":{[^}]*}'
# 预期随时间增长: "counts":{"restored":0,"completed":9,"total":0,"failed":0}

# 窗口结果在 TaskManager 日志里(print sink 即 stdout)
docker compose logs taskmanager 2>&1 | tail -n 5
# 预期形如 +I[2026-08-22T14:00:10, 2026-08-22T14:00:20, 100, 49873]
```

### 步骤 4：savepoint → 取消

```bash
# [任意节点]
docker compose exec jobmanager ./bin/flink list
# 预期: ... : RUNNING (job.sql 内的 INSERT 作业)

docker compose exec jobmanager ./bin/flink savepoint $JOB_ID
# 预期: Savepoint completed. Path: file:///tmp/state/savepoints/savepoint-xxxx-xxxx
# （savepoint 由 TaskManager 执行, 落在共享卷 flink-state 里, 两个容器都看得见）
docker compose exec jobmanager ./bin/flink cancel $JOB_ID
curl -s http://localhost:8081/jobs/overview    # 预期该作业 state 变为 CANCELED/FINISHED
```

### 步骤 5：从 savepoint 恢复并验证

```bash
# [任意节点] 在原脚本最前面加一行 savepoint 路径（路径换成步骤 4 的实际输出）
{ echo "SET 'execution.savepoint.path' = 'file:///tmp/state/savepoints/savepoint-xxxx-xxxx';"; cat job.sql; } > restore.sql
docker compose cp restore.sql jobmanager:/tmp/restore.sql
docker compose exec jobmanager ./bin/sql-client.sh -f /tmp/restore.sql

NEW_ID=$(curl -s http://localhost:8081/jobs/overview | grep -o '"jid":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
curl -s http://localhost:8081/jobs/$NEW_ID/checkpoints | grep -o '"counts":{[^}]*}'
# 预期: "restored":1 —— 新作业成功从 savepoint 恢复了状态
docker compose down   # 清理
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| checkpoint 一直 timeout/failed | 反压让 barrier 走不动，或对齐缓冲堆积 | 治反压（第 6 节）；临时开 `execution.checkpointing.unaligned: true`；调大 timeout |
| Pod 重建后作业状态全丢 | `state.checkpoints.dir` 指向容器内 `file:///tmp`，无持久卷 | 状态目录挂 PVC/hostPath（单节点练习集群） |
| savepoint 恢复报 cannot map / could not restore | 算子 uid 变了或拓扑不兼容 | 代码固定 `.uid()`；确有删减时恢复加 `-n`；改了状态结构只能重跑 |
| KafkaSink exactly-once 频繁 abort/commit 超时 | `transaction.timeout.ms` ≤ checkpoint 间隔+恢复时长，或超过 broker 上限 | 事务超时调到两者之间；缩短 checkpoint 间隔 |
| 下游消费到"先多后少"的抖动数据 | 消费端没开 read_committed，读到未提交事务 | `isolation.level=read_committed` |
| operator 部署一直 RESTARTING | `flinkVersion` 与镜像版本不匹配、状态目录不可写（hostPath 属主不对） | 对齐版本字段；hostPath 目录预建并 chown 给容器内用户（flink 镜像 uid 9999） |
| 反压面板全红却找不到瓶颈 | 只看了被反压的算子（受害者） | 沿数据流找第一个 `backPressured=0, busy≈1000` 的算子；检查同一算子各 subtask 是否倾斜 |

## 自测

<details><summary>1. barrier 为什么要"等所有输入 channel 对齐"？把 mode 改成 at-least-once（跳过对齐）会怎样？</summary>

对齐保证快照边界一致：算子状态里恰好是"所有输入中 barrier n 之前的数据"的处理结果。跳过对齐（at-least-once），后到 channel 里属于 barrier 之前的数据会被处理两次——恢复后从 checkpoint 重放时它们已经计入状态一次、重放又计一次，所以是 at least once。注意这与 unaligned checkpoint 不同：unaligned 是把"未对齐期间的 in-flight 数据"一并存进快照，快照语义仍一致，只是恢复时要先重放这批数据。
</details>

<details><summary>2. 反压严重的作业为什么经常表现为"checkpoint 超时"？unaligned checkpoint 为什么能缓解，代价是什么？</summary>

barrier 随数据流动，反压意味着数据（和 barrier）都被堵在 netty 缓冲队列里，barrier 迟迟到不了算子，对齐也完不成，于是超时。unaligned 让 barrier 可以"插队"越过堆积的缓冲直接推进，快照照常完成；代价是把 in-flight 数据一并写入快照（快照变大），且恢复后要先重放这批数据，属于"用空间换 checkpoint 存活"。
</details>

<details><summary>3. KafkaSink exactly-once、checkpoint 间隔设 20 分钟，会出什么问题？</summary>

两难：事务从 beginTransaction 到 commit 要横跨整个 checkpoint 周期加上恢复时长，`transaction.timeout.ms` 必须大于这个总和；但它又不能超过 broker `transaction.max.timeout.ms` 的默认 15 分钟——20 分钟间隔意味着事务必然超时被 abort，数据被丢弃、作业报错。exactly-once 的 checkpoint 间隔必须控制在"事务超时上限减去恢复时长"以内（典型分钟级）。
</details>

<details><summary>4. `upgradeMode: last-state` 和 `savepoint` 都能升级，什么时候必须用 savepoint？</summary>

last-state 复用最近一次 state（可能是 checkpoint，且算子 ID 按 Flink 内部规划对齐），速度快但格式与拓扑绑定，适合回滚同版本或临时扩缩容。跨 Flink 版本升级、改了并行度且要求状态完整、需要一份可长期保留/可迁移的镜像时，必须用 savepoint——它是标准可移植格式，也是唯一有跨版本兼容承诺的。
</details>

<details><summary>5. 某作业 source 算子 backPressuredTimeMsPerSecond=950，WindowAgg 两个 subtask 分别是 busy=1000 和 idle=1000。瓶颈在哪？为什么扩 WindowAgg 并行度可能没用？</summary>

瓶颈是 WindowAgg 的第 0 个 subtask：它 busy 顶满、完全没被反压（说明它是链路最慢点），另一个 subtask 无事可做，source 被卡住。这是典型热点 key：数据按 key 哈希分布，某个 key 的量占绝对大头且都落在同一个 subtask，单纯加并行度只会增加 idle 的 subtask。治法是打散 key（加盐 + 两阶段聚合）或先本地预聚合降低 shuffle 量。
</details>

## 延伸阅读

- Checkpoints（barrier 对齐、unaligned、配置项）：https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/state/checkpoints/
- Restart Strategies（三种策略与配置）：https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/state/task_failure_recovery/
- Kafka Connector（exactly-once 与事务参数）：https://nightlies.apache.org/flink/flink-docs-stable/docs/connectors/datastream/kafka/
- Flink Kubernetes Operator（部署与升级模式）：https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-stable/docs/custom-resource/job-management/
- High Availability（K8s 模式配置）：https://nightlies.apache.org/flink/flink-docs-stable/docs/deployment/ha/kubernetes_ha/
