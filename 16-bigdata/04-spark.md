# 04 · Spark 架构与调优：内存、shuffle 与数据倾斜

> 模块：16-bigdata ｜ 建议时长：4.5 小时 ｜ 关联认证：—（无直接考点；Spark on K8s 与 History Server 复用 03-docker / 04-k8s-fundamentals 的知识，Flink 对照见 12-data-streaming/flink）

前置：本章假设你已读完 `16-bigdata/02-yarn.md`（容器、队列）与 `16-bigdata/03-hive-warehouse.md`（metastore、ORC、倾斜基本概念）。动手部分对应 `16-bigdata/labs/02-spark-local`。

## 学习目标

- 能画出 Driver / ClusterManager / Executor 三者关系，并对比 local、standalone、YARN、K8s 四种部署形态
- 能算出一个 executor 的容器内存构成（堆内统一内存 + memoryOverhead），并解释"为什么 OOM 常发生在堆外"
- 能用宽窄依赖解释 stage 划分，顺着 sort-based shuffle 的溢写文件定位 slow task
- 能用 explain 读执行计划（Exchange、Broadcast、partial 聚合），并实施数据倾斜三板斧
- 能配置动态资源分配与 external shuffle service，部署 History Server，按高频故障表排障 executor lost / OOM / GC

## 1. 架构：Driver、ClusterManager、Executor

```
        ┌──────────── Driver（用户 main 所在 JVM）────────────────┐
        │ SparkContext：DAG→stage→taskset 调度、追踪 shuffle 输出   │
        │ 汇总 task 结果/指标、Web UI 4040、SparkSession/SQL        │
        └───────▲──────────────────────────▲──────────────────────┘
                │ 注册/申请资源/心跳         │ task 下发、结果与 metrics 回传
        ┌───────┴──── ClusterManager（只做资源中介）───────────────┐
        │ local:线程池  standalone:Master  YARN:ResourceManager    │
        │ K8s:API Server（executor 就是 Pod）                       │
        └───────┬──────────────────┬──────────────────┬───────────┘
                ▼                  ▼                  ▼
          ┌──────────┐       ┌──────────┐       ┌──────────┐
          │ Executor │       │ Executor │       │ Executor │  常驻 JVM
          │ task 线程│       │ task 线程│       │ task 线程│  BlockManager：
          └──────────┘       └──────────┘       └──────────┘  缓存 + shuffle 读写
```

- **Driver 是大脑不是干活的**：把用户代码反向解析成 DAG、切 stage、生成 taskset 发给 executor；`collect()`/`take()` 会把数据拉回 Driver——所以 Driver OOM 常常是业务代码往 driver 收集了太多数据。
- **ClusterManager 只回答两个问题**："还有资源吗"和"容器挂了通知你"。它不理解 RDD/SQL，换 master 只是换资源中介，作业逻辑不变——这是同一份代码能跑 local/YARN/K8s 的原因。
- **Executor 是常驻 JVM**：`--executor-cores` 决定同时跑几个 task 线程，task 复用 JVM 避免了 MR 每任务起 JVM 的开销（对照 `03-hive-warehouse.md` 第 3 节）。

| 维度 | local | standalone | YARN | K8s |
|---|---|---|---|---|
| 定位 | 开发/单机验证 | 自带极简集群 | Hadoop 生态生产主流 | 云原生方向 |
| 资源申请对象 | 无（本机线程） | Master | ResourceManager | API Server（Pod） |
| 隔离粒度 | 无 | JVM 级 | cgroup 容器 | Pod + namespace + ResourceQuota/RBAC |
| 多租户/队列 | 无 | 简单 | 强（Capacity/Fair 队列） | namespace/Quota |
| 动态资源分配 | 无意义 | 支持 | 最成熟（NM 带 ESS） | 用 shuffleTracking（第 6 节） |
| 依赖分发 | 无需 | 各节点预装 | 各节点预装/JAR 上传 | 打进镜像，层复用（见 03-docker） |
| master 写法 | `local[2]` | `spark://m:7077` | `yarn` | `k8s://https://api:6443` |

## 2. 内存管理：统一内存模型与"OOM 常在堆外"

YARN/K8s 分给一个 executor 的**容器内存**由两部分组成：

```
容器总内存 = spark.executor.memory（JVM 堆，-Xmx）
           + memoryOverhead（堆外，默认 max(executor.memory×0.10, 384MB)）
           [+ spark.memory.offHeap.size（开启 offHeap 时）]
           [+ spark.executor.pyspark.memory（Python 进程）]

┌───────────────────── JVM 堆内（executor.memory）─────────────────────┐
│ Reserved 300MB（固定）                                               │
│ User Memory = 可用×(1-0.6)      ← 用户对象/UDF/框架不管理区          │
│ Unified Memory = 可用×spark.memory.fraction(0.6)                    │
│   ├─ Execution：shuffle 读写缓冲、排序、聚合的执行内存                │
│   └─ Storage：cache/persist 的缓存块                                 │
└──────────────────────────────────────────────────────────────────────┘
┌────── 堆外 memoryOverhead ──────────────────────────────────────────┐
│ netty DirectByteBuffer（shuffle 拉取缓冲）、线程栈、JVM 自身、unsafe │
└──────────────────────────────────────────────────────────────────────┘
```

**动态借用规则**（这是"统一"二字的含义）：

- Execution 缺内存时可以**抢占** Storage 借走的部分——被借走的缓存块强制落盘/逐出，task 不能等；
- 反方向 Storage 只能借用 Execution **当时空闲**的部分，Execution 一需要就必须立刻归还；
- User Memory 完全不参与借用，Spark 不管它——UDF 里塞了个大 dict，堆内 OOM 就出在这里。

**为什么 OOM 常在堆外**：YARN/K8s 杀容器看的是进程 RSS，不是 `-Xmx`。RSS = 堆 + metaspace + 线程栈 + netty 直接内存 + malloc 碎片。shuffle 拉取量大时 netty DirectByteBuffer 先膨胀，堆明明还有富余，RSS 已顶到容器上限——YARN 报 `Container killed by YARN for exceeding memory limits ... Consider boosting spark.executor.memoryOverhead`；K8s 表现为 `OOMKilled, Exit 137`。**调 `spark.executor.memoryOverhead` 而不是盲目加大 `-Xmx`**，否则堆变大反而挤压堆外空间。

```bash
# [任意节点] 生产常见的内存三件套
--executor-memory 8g --executor-cores 4 \
--conf spark.executor.memoryOverhead=2g \
--conf spark.executor.defaultJavaOptions=-XX:+UseG1GC
```

GC 侧的看板：Web UI Executors 页的 GC Time 列，GC 时间占比持续 >10% 或出现长时间 Full GC，先怀疑缓存过多/堆偏小/倾斜（第 5 节）。

## 3. shuffle 与 stage 划分：slow root cause 的基本功

**窄依赖**：分区一对一（map、filter），可以 pipeline 在同一个 task 里连续执行。**宽依赖**（shuffle）：分区一对多（groupByKey、join、distinct、窗口），下游分区要"凑齐"上游所有分区里属于自己的那部分，因此必须切 stage 边界。

```
Action 触发 Job
└─ Job → 按宽依赖边界反向切 stage
   ├─ Stage 0 (ShuffleMapStage)  task 数 = 上游分区数（读 HDFS 就是个 split 数）
   ├─ Stage 1 (ShuffleMapStage)  ← 每个宽依赖一条边界
   └─ Stage 2 (ResultStage)      task 数 = 最终 RDD 分区数
```

sort-based shuffle 的完整数据流：

```
map 端（每个 map task）：
  记录按分区号写入内存缓冲 → 缓冲满 → 按分区排序后溢写为一个 spill 文件
  （写 spark.local.dir，磁盘！）→ task 结束时 merge 所有 spill
  产出：每个 map task 两个文件 —— 数据文件 + index（各 reduce 分区的偏移）

reduce 端（每个 reduce task）：
  按 index 精确拉取所有 map 输出中自己分区的那段 → 边拉边聚合/排序
```

排障时的三个落点：

1. **Web UI Stage 页看 Spill (memory/disk) 列**：大量 spill = 执行内存不够，task 在反复"排序-写盘-再读盘"。单 task spill 到 GB 级，慢 10 倍很正常。
2. **分区数不对**：SQL 的 shuffle 并行度由 `spark.sql.shuffle.partitions`（默认 200）决定。100GB 的 shuffle 只给 200 分区，单 task 500MB+ 必然溢写；反过来小数据给 2000 分区则是任务调度开销浪费。开 AQE 后会自动合并小分区（第 4 节）。
3. **FetchFailed / Map output lost**：reduce 端连不上 map 输出所在的 executor（节点挂/盘满/executor 被回收），默认重试 3 次（`spark.shuffle.io.maxRetries`）后整个 stage 重算。频繁出现指向节点磁盘或动态分配没配 ESS（第 6 节）。

判断宽窄依赖的心法：问一句"这个算子需要别的分区的数据流进来吗"。需要（按 key 重新分布）就是宽依赖，计划里必有 Exchange，stage 就在这里切一刀。

## 4. lazy 求值与 explain：先看计划再动手

transformation（map/filter/groupBy）只累积 DAG 不执行，action（count、write、collect）才触发计算。lazy 不是偷懒，是为了**全局优化**：Catalyst 看到整条 SQL 才能做谓词下推、列裁剪、join 策略选择、whole-stage codegen。

```python
# [任意节点（容器内 pyspark）] 学会读三行：Exchange、Broadcast、partial
spark.sql("""
  SELECT city_id, sum(amount) FROM orders WHERE dt='2026-08-29' GROUP BY city_id
""").explain("formatted")
```

```
== Physical Plan ==
* HashAggregate(keys=[city_id], functions=[sum(amount)])          ← 最终聚合
+- Exchange hashpartitioning(city_id, 200)                        ← shuffle 边界=stage 边界
   +- * HashAggregate(keys=[city_id], functions=[partial_sum(amount)])  ← map 端预聚合
      +- * Project [city_id, amount]
         +- * Filter (dt = 2026-08-29)
            +- * Scan ORC ... PushedFilters: [EqualTo(dt,...)]    ← 谓词下推到读取器
```

读法：`Exchange` 出现一次就是一次 shuffle（对应 03 章"分区裁剪 + 列存跳块"之后的第二大成本）；join 前出现 `BroadcastExchange` 说明小表将被广播（绕过 shuffle，第 5 节板斧三）；`partial_` 前缀说明发生了 map 端预聚合（两阶段聚合的自动版）；`PushedFilters` 是谓词下推是否生效的直接证据。Spark 3.x 的 AQE 默认开启（`spark.sql.adaptive.enabled`），会按运行时统计动态合并 shuffle 分区、切换 join 策略、拆分倾斜分区——**先把 AQE 用起来，再考虑手工三板斧**。

## 5. 数据倾斜三板斧

定位优先：Web UI 里某个 stage 绝大多数 task 秒级完成、少数 task 跑几十分钟，Spill/GC 同时飙高，即可判定倾斜。先 `EXPLAIN` 确认倾斜发生在哪个 Exchange，再动手。

```python
# [任意节点（容器内 pyspark）] 构造可复现的倾斜案例：city_id=0 占 10% 流量
from pyspark.sql import functions as F

orders = (spark.range(0, 10_000_000)
    .withColumn("city_id", F.when(F.col("id") % 10 == 0, F.lit(0))
                          .otherwise(F.col("id") % 2000))
    .withColumn("amount", (F.rand() * 100)))

# 观察 4040 的 Jobs → 最新 Stage：0 号 key 所在 task 明显长尾
orders.groupBy("city_id").agg(F.sum("amount").alias("total")).count()
```

### 板斧一：加盐打散（join 倾斜）

热点 key 所在大表每行加随机前缀 `r∈[0,N)`，小表按 N 份复制补齐所有前缀，join 后去掉前缀。热点数据被均分到 N 个 task，代价是小表膨胀 N 倍（所以只对小表用）。

```python
# [任意节点（容器内 pyspark）]
N = 16
big   = orders.withColumn("salt", (F.rand() * N).cast("int"))
small = (spark.createDataFrame([(i, f"city-{i}") for i in range(2000)], ["city_id", "name"])
         .withColumn("salt", F.explode(F.sequence(F.lit(0), F.lit(N - 1)))))
big.join(small, ["city_id", "salt"]).count()
```

### 板斧二：两阶段聚合（聚合倾斜）

先按 `(key, salt)` 局部聚合把数据量压扁，再去掉 salt 全局聚合。注意 `partial_sum` 只能压缩行数，压不了单 key 的原始体积，所以单 key 特别大时仍需先加盐。

```python
# [任意节点（容器内 pyspark）]
N = 16
(orders.withColumn("salt", (F.rand() * N).cast("int"))
       .groupBy("city_id", "salt")
       .agg(F.sum("amount").alias("s1"))       # 第一阶段：局部聚合
       .groupBy("city_id")
       .agg(F.sum("s1").alias("total"))        # 第二阶段：全局聚合
       .count())
```

### 板斧三：broadcast 小表绕过 shuffle

小维表（默认 < `spark.sql.autoBroadcastJoinThreshold` = 10MB）广播到所有 executor，大表**完全不动**，BroadcastHashJoin 没有任何 Exchange。反噬场景要记住：所谓"小表"其实有 300MB 时，广播会同时顶爆 Driver 和每个 Executor 的内存——比 shuffle 更危险。

```python
# [任意节点（容器内 pyspark）]
cities = spark.createDataFrame([(i, f"city-{i}") for i in range(2000)], ["city_id", "name"])
orders.join(F.broadcast(cities), "city_id").count()
```

选型口诀：小表能装下 → broadcast；聚合倾斜 → 两阶段；join 倾斜且小表可膨胀 → 加盐；Spark 3.5 先让 AQE（`spark.sql.adaptive.skewJoin.enabled`）试。另有一类"假倾斜"：null/空串 key 堆积，`WHERE key IS NOT NULL` 拆出去单独处理即可，别上三板斧。

## 6. 动态资源分配与 external shuffle service

批作业的资源需求随 stage 波动：shuffle 前要 50 个 executor，最后写结果只要 5 个。动态资源分配（DRA）按 backlog 动态伸缩：

```bash
# [任意节点] spark-submit 生产常见组合
--conf spark.dynamicAllocation.enabled=true \
--conf spark.dynamicAllocation.minExecutors=5 \
--conf spark.dynamicAllocation.maxExecutors=50 \
--conf spark.dynamicAllocation.executorIdleTimeout=120s \
--conf spark.shuffle.service.enabled=true \
--conf spark.shuffle.service.port=7337
```

DRA 有个先天矛盾：**executor 被回收后，它的 shuffle 输出文件还在被后续 stage 拉取**。两种解法：

```
YARN：NodeManager 常驻 External Shuffle Service（aux-service=spark_shuffle, 7337）
      └─ 托管本节点所有 executor 的 shuffle 文件，executor 死活不影响拉取 ← 生产首选
K8s： 没有常驻 NM ── 用 shuffle tracking（3.0+）
      --conf spark.shuffle.service.enabled=false \
      --conf spark.dynamicAllocation.shuffleTracking.enabled=true
      └─ Spark 自己记录 shuffle 块引用，持有 shuffle 数据的 executor 暂不回收
```

与 Flink 的本质差别（交叉引用 `12-data-streaming/flink/02`）：Flink 作业常驻且状态持续增长，资源通常**固定**，弹性是例外；Spark 批作业无状态、分区幂等，DRA 是常态。这就是同一台集群上 Flink 任务"钉死 slot"、Spark 任务"潮汐伸缩"的根因。

## 7. 运维手册

### 7.1 spark-submit 参数速查表

| 参数 | 作用 | 示例/常见值 |
|---|---|---|
| `--master` | 集群管理器 | `local[2]`、`yarn`、`spark://m:7077`、`k8s://https://api:6443` |
| `--deploy-mode` | Driver 位置 | `client`（调试）/ `cluster`（生产，Driver 随集群） |
| `--executor-memory` / `--executor-cores` | 单 executor 规格 | 8g / 4（每核 2~4GB 起步） |
| `--num-executors` | 固定 executor 数 | 未开 DRA 时 = ceil(总核/cores)；开了给 max |
| `--conf spark.executor.memoryOverhead` | 堆外 | 2g~4g，netty/Python 大时调高 |
| `--conf spark.sql.shuffle.partitions` | SQL shuffle 并行度 | 默认 200；开 AQE 可自适应 |
| `--conf spark.dynamicAllocation.*` | 弹性 | 见第 6 节 |
| `--conf spark.eventLog.enabled` / `.dir` | 事后分析 | `true` + `hdfs:///spark-logs` |
| `--py-files` / `--jars` / `--files` | 依赖分发 | zip/whl；jar；配置文件 |
| `--queue` / `--principal --keytab` | YARN 队列 / Kerberos | `--queue etl` |
| `--conf spark.kubernetes.container.image` 等 | K8s 专用 | 见第 7.4 节 |

### 7.2 History Server 部署

生产 Driver 一闪而过，Web UI 4040 随之消失。事件日志（eventLog）是作业全量指标序列化，History Server（SHS）解析后离线回放整个 UI。

```bash
# [任意节点] 1. 让作业把事件日志写到共享目录
mkdir -p /tmp/spark-events
docker run --rm -v /tmp/spark-events:/tmp/spark-events apache/spark-py:3.5.1 \
  /opt/spark/bin/spark-submit --master "local[2]" \
  --conf spark.eventLog.enabled=true \
  --conf spark.eventLog.dir=file:///tmp/spark-events \
  /opt/spark/examples/src/main/python/pi.py 10
# 预期输出末行: Pi is roughly 3.14...

# [任意节点] 2. 起 History Server 回放
docker run -d --name spark-history -p 18080:18080 \
  -v /tmp/spark-events:/tmp/spark-events \
  -e SPARK_HISTORY_OPTS="-Dspark.history.fs.logDirectory=file:///tmp/spark-events" \
  apache/spark:3.5.1 /opt/spark/sbin/start-history-server.sh

# [任意节点] 3. 验证（返回 JSON，含 "name":"PythonPi"）
curl -s http://localhost:18080/api/v1/applications | head
```

浏览器打开 `http://<VM-IP>:18080`，能看到该作业的 stages/executors 全量页面。镜像 tag（3.5.x）以 Docker Hub 官方仓库为准；生产把 `eventLog.dir` 放 HDFS，SHS 起成常驻服务并用 Prometheus 抓取其指标（接入方式同 `08-pca`）。

### 7.3 高频故障表

| 症状/日志 | 根因 | 解法 |
|---|---|---|
| `Container killed by YARN ... exceeding memory limits ... physical memory` | RSS（堆+堆外）超容器预算 | 调大 memoryOverhead；减 executor-cores 降并发 |
| K8s 上 `OOMKilled, Exit 137` | pod request 低于实际 RSS | 同上；确认 request = memory + overhead |
| `ExecutorLostFailure ... Slave lost` / `Executor heartbeat timed out` | 节点重启、磁盘满、GC 停顿超时 | 看 NM/dmesg/盘；调 `spark.network.timeout`（默认 120s） |
| `FetchFailed` / `Map output lost` 反复出现 | map 输出所在 executor 已死或盘满 | ESS/shuffleTracking；修盘；调大 `spark.shuffle.io.maxRetries` |
| GC Time 占比 >10%，task 周期性停顿 | 堆偏小、缓存过多、倾斜 | G1GC；降 cache 级别；三板斧 |
| `Total size of serialized results > spark.driver.maxResultSize` | collect 回 Driver 数据过大 | 改为 write 落盘，不往 Driver 拉 |
| `No space left on device`（spark.local.dir） | 溢写盘满 | 多盘多目录、扩容、减 shuffle 量 |
| 99% task 秒级、个别 task 几十分钟 | 数据倾斜 | 第 5 节三板斧 + AQE |

### 7.4 Spark on K8s 与 Flink on K8s 对比

原生方式是 spark-submit 直连 API Server：`--master k8s://https://api:6443 --conf spark.kubernetes.container.image=... --conf spark.kubernetes.namespace=etl --conf spark.kubernetes.authenticate.driver.serviceAccountName=spark`，Driver/Executor 全部是 Pod。进阶用 **Spark Operator**（CRD `SparkApplication`），GitOps 友好：

```yaml
# [master] 示例：SparkApplication（operator 安装以 kubeflow/spark-operator 文档为准）
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: daily-agg
  namespace: etl
spec:
  sparkVersion: "3.5"
  mode: cluster
  image: "registry.local/spark-etl:3.5.1"
  driver:
    cores: 2
    memory: "2g"
    serviceAccount: spark
  executor:
    instances: 4
    cores: 4
    memory: "8g"
    memoryOverhead: "2g"
```

与 Flink on K8s（`12-data-streaming/flink/02` 第 7 节的 FlinkDeployment）的对照：

| 维度 | Spark（SparkApplication） | Flink（FlinkDeployment） |
|---|---|---|
| 作业形态 | 批为主，跑完即释放 | 常驻流，7×24 |
| 状态 | 无 checkpoint 概念，失败重跑分区（幂等） | checkpoint/savepoint 是生命线 |
| 升级 | 重跑最新数据覆盖写 | 必须 savepoint → 换镜像 → 恢复 |
| 高可用 | Driver 单点，cluster 模式失败重提交 | JM 用 K8s ConfigMap lease 选主 |
| 弹性 | DRA + shuffleTracking 是常态 | 固定 slot 为主 |
| 事后分析 | History Server 解析 eventLog | JM Web UI + JobHistory |

排障分工也和 Flink 一样按"控制面/数据面"切：Pod 事件与调度问题查 operator 与 API Server（kubectl，见 04-k8s-fundamentals），作业内部慢查 SHS 的 stage/task 指标，两边别混。

## 实战演练

环境：任意一台装好 Docker 的 Ubuntu VM（[任意节点]）。镜像以 `apache/spark:3.5.1` / `apache/spark-py:3.5.1` 演示，tag 以官方仓库为准。完整单机安装版练习见 `16-bigdata/labs/02-spark-local`。

### 步骤 1：local 模式跑通第一个作业

```bash
# [任意节点]
docker run --rm -p 4040:4040 apache/spark-py:3.5.1 \
  /opt/spark/bin/spark-submit --master "local[2]" \
  /opt/spark/examples/src/main/python/pi.py 10
# 预期末行: Pi is roughly 3.1...
```

### 步骤 2：亲手算一次 executor 内存

```bash
# [任意节点] local 模式 executor 就在 Driver JVM 里，两处都设 2g
docker run -it -p 4040:4040 apache/spark-py:3.5.1 \
  /opt/spark/bin/pyspark --master "local[2]" \
  --driver-memory 2g --conf spark.executor.memory=2g
```

```python
# [任意节点（容器内 pyspark）]
mm = spark.sparkContext._jvm.SparkEnv.get().memoryManager()
print("maxHeapMemory      (MB):", mm.maxHeapMemory() / 1024 / 1024)
print("maxOnHeapStorage   (MB):", mm.maxOnHeapStorageMemory() / 1024 / 1024)
# 预期: 两者均约 1000~1050MB 且空载时相等 —— 不是做错了：
#   maxHeapMemory 已经乘过 spark.memory.fraction，即 (Runtime.maxMemory-300MB)*0.6 ≈ 1048.8MB
#   （-Xmx2g 下 Runtime.maxMemory 略小于 2048，实测值会略低）；
#   maxOnHeapStorageMemory = maxHeapMemory - 已用 on-heap execution 内存，空载时与之相等，
#   不会再乘 storageFraction 的 0.5。524.4MB 那个静态 storage 区域（onHeapStorageRegionSize）
#   没有公开访问器，到 http://<VM-IP>:4040 的 Executors 页核对。
```

公式推导对照：usable = 2048−300 = 1748MB；unified（`maxHeapMemory`）= 1748×0.6 ≈ 1048.8MB；静态 storage 区域（`onHeapStorageRegionSize`，私有字段）= 1048.8×0.5 ≈ 524.4MB——这个值用 `http://<VM-IP>:4040` 的 Executors 页验证；`maxOnHeapStorageMemory()` 则是 unified 减去已用 execution 内存，空载时与 `maxHeapMemory` 同值。

### 步骤 3：复现倾斜并上三板斧

```python
# [任意节点（容器内 pyspark）] 沿用第 5 节代码块
# 1) 先跑 agg.count()，在 4040 的 Jobs → 最新 Stage 看
#    Summary Metrics: median 与 max 的差距（0 号 key 约慢一个数量级）
# 2) 依次执行两阶段聚合 / broadcast join 版本，观察同一指标收敛
# 3) explain 对比：agg 的计划里有 Exchange hashpartitioning(city_id, 200)
#    broadcast join 的计划里没有 Exchange，只有 BroadcastHashJoin
spark.sql("SET spark.sql.adaptive.enabled=true")
```

验收：三段代码都能输出 count（等于 2000 或 10000000 相关的确定值）；`explain("formatted")` 里能指出哪一行是 shuffle 边界、哪一行是广播。

### 步骤 4：History Server 留档

执行第 7.2 节的三条命令：`/tmp/spark-events` 下应出现 `local-<timestamp>`（作业结束后去掉 `.inprogress` 后缀），`curl -s http://localhost:18080/api/v1/applications | head` 返回含 PythonPi 的 JSON，UI 上能看到与 4040 相同的 stages 页面。这一步的意义：生产上你没有 4040，只有 18080。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 调大 executor-memory 后 OOM 反而更频繁 | 容器预算没同步加，堆挤压堆外 | memoryOverhead 一起调；容器上限 = memory + overhead |
| client 模式在跳板机提交后关终端作业就死 | Driver 跑在提交机 | 生产用 cluster 模式或 nohup/tmux |
| AQE 开了倾斜没好转 | 倾斜在聚合而非 join，或单 key 占比过大 | join 倾斜 AQE 自动处理；聚合倾斜手工两阶段聚合 |
| broadcast join 把 Driver 打挂 | "小表"实际几百 MB | 调低 autoBroadcastJoinThreshold 或去掉 broadcast 提示 |
| `spark.sql.shuffle.partitions` 一把调到几千 | 小任务调度开销暴涨 | 开 AQE 让分区自动合并，别静态拍大数 |
| DRA 一开就 FetchFailed | executor 被回收后 shuffle 输出丢失 | YARN 配 ESS；K8s 开 shuffleTracking |
| K8s 提交卡在 driver 待调度 | namespace ResourceQuota/SA 权限 | kubectl describe quota；serviceAccount 走 RBAC |

## 自测

<details><summary>1. 为什么 Execution 内存可以抢占 Storage，反向却不行？这个不对称保护的是什么？</summary>

保护"正在运行的 task 不能被中断"：Execution 内存不够时 task 无法让步（算到一半的数据不能扔），只能通过挤掉可重建的缓存块腾地方——缓存丢了可以重算或重读，task 失败则整个 stage 重来。反向 Storage 若能抢占 Execution，缓存的写入会随时杀掉正在执行的 task，作业正确性与进度都不可控。一句话：可重算的资源永远让位于不可中断的计算。
</details>

<details><summary>2. YARN 报 "8GB of 8GB physical memory used" 但 executor 堆只配了 6g、才用到一半，哪里吃掉了内存？</summary>

RSS ≠ 堆。容器 8GB 里堆 6g，剩余 2g 给堆外：netty DirectByteBuffer（shuffle 拉取缓冲）、数百个 task/JVM 线程栈、metaspace/code cache、glibc malloc 碎片。shuffle 量大时直接内存膨胀最快，堆一半没用完 RSS 已到 8GB 被 YARN 杀。处置是加 memoryOverhead（或减 executor-cores 降并发），而不是加 -Xmx——后者会让堆外空间更小。
</details>

<details><summary>3. 一个 stage 的 199 个 task 都是 3 秒，1 个 task 跑了 25 分钟且 Spill (disk) 达到十几 GB。说出你的完整处置顺序。</summary>

① 确认倾斜而非环境问题：该 task 的 Input Size 是否远大于其他 task（若数据量相同才怀疑节点/盘）；② 看 EXPLAIN 定位该 Exchange 前后的算子，找出分组/join key；③ 用 `df.groupBy(key).count().orderBy(desc)` 采样验证 key 分布（或直接查 null 占比）；④ 选武器：null/空值先拆、小表 broadcast、聚合两阶段、join 加盐；⑤ Spark 3.5 先确认 AQE skewJoin 已生效（它只自动处理排序 join 的倾斜）；⑥ 修复后在同一数据集对比 stage 的 max/median task 时长。Spill 十几 GB 说明执行内存也被这批数据压垮了，倾斜解决后 spill 自然消失。
</details>

<details><summary>4. 开了 dynamicAllocation，为什么 YARN 必须配 external shuffle service，而 K8s 上却用 shuffleTracking？本质矛盾是什么？</summary>

矛盾是"executor 的生命周期由资源策略决定，shuffle 文件的生命周期由作业数据流决定"，两者天然不同步：map 阶段结束后 executor 空闲被回收，但它的输出文件还要被下一个 stage 拉取几十分钟。YARN 有常驻的 NodeManager，把文件托管职责挪给 NM 里的 ESS，executor 随便死；K8s 上没有等价的常驻节点代理（ESS 只能 DaemonSet 变种，维护成本高），所以 3.0 改为 shuffleTracking：Spark 自己记录哪些块还被引用，持有数据的 executor 暂不回收——用保守回收换正确性。
</details>

<details><summary>5. 同一个 ETL 逻辑，该用 Spark on K8s 还是 Flink on K8s？给出判断依据，并说明两者失败恢复语义的差别。</summary>

按数据的时间形态定：有界、按批重算幂等（覆盖写）→ Spark；无界、要求事件内持续聚合与状态 → Flink。恢复语义差别：Spark 无持久状态，失败从上游 stage 或重跑分区恢复，幂等输出保证最终一致；Flink 的进度存在于算子状态里，必须依赖 checkpoint/savepoint，恢复是从最近快照重放（exactly-once 需 sink 两阶段提交配合，见 12-data-streaming/flink/02）。因此 Spark 的升级是"重跑"，Flink 的升级是"savepoint 迁移"，运维流程完全不同。
</details>

## 延伸阅读

- Cluster Overview / 提交与部署：https://spark.apache.org/docs/latest/cluster-overview.html
- Tuning（内存与 GC 官方建议）：https://spark.apache.org/docs/latest/tuning.html
- Running on YARN（含 ESS 配置）：https://spark.apache.org/docs/latest/running-on-yarn.html
- Running on Kubernetes：https://spark.apache.org/docs/latest/running-on-kubernetes.html
- Monitoring（History Server 与指标）：https://spark.apache.org/docs/latest/monitoring.html
- SQL Performance Tuning（AQE）：https://spark.apache.org/docs/latest/sql-performance-tuning.html
- Spark Operator（CRD 与安装）：https://github.com/kubeflow/spark-operator
- apache/spark 官方镜像：https://hub.docker.com/r/apache/spark
