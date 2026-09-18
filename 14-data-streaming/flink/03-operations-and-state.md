# 03 · Flink 运维与状态：算子 UID、rescale、内存模型、checkpoint 排障与 CDC 入湖

> 模块：14-data-streaming/flink ｜ 建议时长：4 小时 ｜ 关联认证：—（无直接考题；TM 内存预算与容器 OOMKilled 是 CKA 资源模型的流处理版，CDC 入湖衔接 ../../18-bigdata/07 的 Paimon lab）

## 学习目标

- 能解释算子 uid 如何决定 savepoint 能否恢复，按"改动清单"判断改拓扑/改并行度后恢复会不会失败
- 能执行 stop-with-savepoint → 改并行度 → 恢复的 rescale 全流程，说清 keyed state 与 operator state 在并行度变化时的重分配差异
- 能画出 TaskManager 内存模型的分块，按 OOM / OOMKilled 的报错形态判断该调哪块预算
- 能按命中率排序的排查清单定位 checkpoint 失败/超时（反压、倾斜、状态上传、sink 事务、湖 commit）
- 能搭起 Flink CDC → Paimon 的入湖链路，并说明它与 Debezium+Kafka Connect 路线、changelog-producer 的取舍衔接

## 1. 算子 UID 与 savepoint 兼容：状态怎么被"认领"

01 章第 6 节讲了 savepoint 与 checkpoint 的分工，02 章第 8 节走了升级流程，但都绕开了一个问题：**恢复时，快照里的状态怎么知道该还给哪个算子？** savepoint 的元数据（`_metadata`）本质是一张"算子 ID → 状态句柄"的映射表；恢复时新作业拿自己的算子 ID 去这张表里认领，认不上的状态恢复直接失败。算子 ID 来自两处：

- **显式 uid**：DataStream 代码里 `.uid("window-agg")` 给算子起的稳定名字，ID 就是它；
- **自动生成**：没写 uid 的算子按**拓扑位置**生成 ID——这就埋了雷：改几行代码加一个算子、调整算子顺序，后面算子的位置全变，ID 全变。

```java
// [开发机：DataStream API 代码] uid 要在作业第一天、有状态算子上就固定
stream.keyBy(e -> e.getKey())
    .window(TumblingEventTimeWindows.of(Time.seconds(10)))
    .aggregate(new OrderAgg()).uid("order-window-agg")   // 状态真正存放的算子
    .addSink(new JdbcSink()).uid("orders-jdbc-sink");
// 命名用业务语义而不是 a/b/c：一年后没人记得 uid42 是谁
```

判断"改完之后还能不能恢复"，对照下表（以 keyed/有状态算子为准）：

| 改动 | 恢复结果 | 说明 |
|---|---|---|
| 只改业务逻辑（不动拓扑与状态结构） | 成功 | uid 没变即可 |
| 新增算子 | 成功 | 新算子无状态可领，空手上路 |
| 删除算子 | 需 `-n` | `--allowNonRestoredState` 容忍"快照里多出来的状态" |
| uid 变化/丢失（含位置 ID 漂移） | 失败 | 报 could not map state / no state found |
| 状态类型或序列化器变了 | 失败 | `-n` 只容忍多余状态，**不容忍类型不兼容** |
| key 的类型/字段变了 | 失败 | key→key group 映射的输入变了 |
| 并行度变化 | 成功（有上限） | 见第 2 节，不得超过 maxParallelism |
| maxParallelism 变化 | keyed state 失败 | key→key group 映射本身依赖它 |

SQL 作业没有等价的显式 uid：算子 ID 由查询计划推导（以官方文档为准），加 WHERE、改 JOIN 顺序、重命名字段都可能改变 ID。工程对策：**每次改 SQL，发布前先在测试环境从生产 savepoint 试恢复一次**，把"能不能恢复"变成演练结论而不是上线赌注；核心状态重的作业倾向 DataStream + 显式 uid。

**maxParallelism 是第二个隐形合约。** 不显式设置时，默认值 = `max(并行度, 128)`，上限 32768（推导规则以官方文档为准）。两推论：并行度 64 的作业能直接扩到 128 以内；并行度 200 的作业默认 maxParallelism=200，**一行都扩不上去**。纪律：预估峰值的 2 倍设 `env.setMaxParallelism()`（SQL 作业 `SET 'pipeline.max-parallelism' = '...'`），且一旦带状态运行就不再改它——key 与 key group 的映射（01 章第 5 节）依赖这个数字，改它等于换映射表，keyed state 恢复必失败。

## 2. Rescale 与重启拓扑：三种"再来一次"不要混

作业出问题后的三种恢复动作，层次完全不同：

| 动作 | 谁触发 | 并行度 | 状态来源 | 场景 |
|---|---|---|---|---|
| 作业内重启 | restart-strategy（02 章第 4 节） | 不变 | 最近 completed checkpoint | 故障自愈 |
| rescale | 人工 | 变 | savepoint（或 last-state） | 扩缩容、错峰调度 |
| 无状态重启 | 人工 | 任意 | 无 | 状态结构彻底变了/新作业 |

rescale 的标准流程是 **stop-with-savepoint**：先让 source 停止拉数、做一次 savepoint、sink 事务随 `notifyCheckpointComplete` 提交，然后作业体面退出——比 `flink cancel` 裸杀干净得多：

```bash
# [flink 客户端机器] 常规 rescale：优雅停 + 带状态起新并行度
./bin/flink stop --savepointPath file:///tmp/state/savepoints $JOB_ID
./bin/flink run -s file:///tmp/state/savepoints/savepoint-xxxx-xxxx \
  -p 8 -c org.example.Main ./myjob.jar

# 注意：stop 不要随手加 --drain——它会把 watermark 推到 MAX_VALUE、触发全部
# 窗口再快照，只适用于"确定不再恢复"的终态停机；常规升级加了它，
# 恢复后的事件时间语义可能不正确（以官方文档为准）
```

新并行度下状态怎么分家（01 章第 5 节的推论落地）：

- **keyed state 按 key group 整组迁移**：key 与 key group 的映射由 hash 决定，与并行度无关；并行度 4→8 只是把 128 个 key group 重新切成 8 段，key 永远跟着自己的组走，一个 key 的状态不会拆开。
- **operator state 由算子自己解释**：Kafka source 的 offset 存成 union list——恢复时全量 offset 清单发给每个 source subtask，各自认领分区号对得上的那部分；所以 Kafka source 的分区数变多也能恢复（新分区从 latest/earliest 开始）。
- **sink 事务在 stop 时收口**：exactly-once sink 的事务随最后一次 checkpoint 提交，消费者无感。

K8s Operator 部署时这套流程收敛为 patch：改 `spec.job.parallelism` + `fromSavepoint`（或 `upgradeMode: savepoint`），命令见 02 章第 8 节，不重复。**扩容判据用 02 章第 6 节的指标**：所有 subtask busy 顶满才值得扩并行度；同一算子 subtask 两极分化（一个 busy 一个 idle）是热点 key，扩并行度只会多造几个 idle subtask，先加盐打散。

## 3. JobManager / TaskManager 内存模型与调优

Flink 1.10 起内存模型按"进程总预算切块"，配错了不是性能差而是直接 OOM/Killed。TaskManager 的分层：

```
TaskManager Total Process Memory（taskmanager.memory.process.size）
├── Total Flink Memory
│   ├── JVM Heap
│   │   ├── Framework Heap     框架自身（默认 128MB）
│   │   └── Task Heap          算子与用户对象；HashMap 状态也在这 ← slot 只切这块+managed
│   ├── Off-heap Direct
│   │   ├── Framework Off-Heap 框架 direct（默认 128MB）
│   │   ├── Task Off-Heap      用户 direct（默认 0）
│   │   └── Network            netty 收发缓冲（默认占 Total Flink 的 10%）
│   └── Managed                RocksDB/排序/shuffle（默认 40%，Flink 统一治理，堆外）
├── JVM Metaspace              类元数据（默认 256MB）
└── JVM Overhead               GC/线程栈等 native 开销（默认 10%）
```

三个关键认知：

1. **RocksDB 不吃 Task Heap，吃 Managed**。选了 RocksDB 状态后端（01 章第 5 节），状态落在堆外，堆压力消失、managed 需求上升——`state.backend.rocksdb.memory.managed` 默认开启时，RocksDB 的 block cache 与 write buffer 共享 managed 预算（write buffer 占比默认 0.5，以文档为准）；把它关掉等于让 RocksDB 无上限地吃进程内存，是 native OOM 的头号来源。
2. **Network 是独立 direct 预算**。反压时数据堆在 network buffer 里；`OutOfMemoryError: Direct buffer memory` 几乎总是这一块或 framework off-heap 不够。
3. **K8s 下 process.size 必须 ≤ 容器 limit**。Flink 的进程总预算与容器 limit 对不齐，多出来的 native 开销会把 Pod 推过阈值，表现为 exit 137（OOMKilled）——这正是 CKA 里 requests/limits 与 JVM 进程开销的经典错位。

调优按报错形态对号入座：

| 症状 | 缺口在哪 | 动作 |
|---|---|---|
| TM 日志 `OutOfMemoryError: Java heap space` | Task Heap | 调大 `taskmanager.memory.task.heap.size`（同步抬 process.size）；查状态是否该上 RocksDB/TTL |
| `OutOfMemoryError: Direct buffer memory` | Network / Off-heap | 调大 `taskmanager.memory.network.min/max` |
| Pod 反复 OOMKilled（exit 137） | 进程总预算 > 容器 limit | 对齐 `taskmanager.memory.process.size` 与 K8s limit（operator 部署时即 `resource.memory`） |
| RocksDB malloc 失败 / std::bad_alloc | Managed 不足或未纳管 | 开 managed（默认开）、评估 `managed.fraction`（默认 0.4） |
| Metaspace 溢出 | UDF/connector 类多 | 调大 `taskmanager.memory.jvm-metaspace.size` |
| 长 GC 停顿、延迟毛刺 | 堆太大或 HashMap 大状态 | 换 RocksDB 把状态挪出堆 |

JobManager 侧一把抓：`jobmanager.memory.process.size`（堆默认 512MB 量级，作业数多/大图调度要抬）。JM 内存影响的不是单作业而是**整个集群的所有作业**——JM OOM 时全部作业一起没，生产上 JM 的内存余量按"最大作业的调度复杂度 × 并发作业数"评估，别用默认值硬扛。

## 4. Checkpoint 失败排查清单

checkpoint 失败的表象都一样（Web UI 一片红），根因至少有六种。排查材料两处：作业页 Checkpoints 标签，或 REST `/jobs/<jobId>/checkpoints`——每个快照条目看四个字段：`state_size`（状态多大）、`end_to_end_duration`（端到端多久）、`alignment_buffered`（对齐期间缓存了多少数据）、`num_acknowledged_subtasks`（谁没交卷）。

按命中率排序过清单：

1. **找"谁拒绝的"**：失败条目/日志里的 `checkpoint declined by task <X>` 直接点名算子与 subtask，先缩小范围再往下走。
2. **反压**（最高频）：barrier 随数据流动，堵在哪 barrier 就卡在哪——02 章第 6 节的 busy/backPressured 指标定位瓶颈算子；治反压是根治，临时开 `execution.checkpointing.unaligned: true` 让 barrier 插队是止痛。
3. **数据倾斜**：`num_acknowledged_subtasks < num_subtasks` 长期卡住，缺的总是同一 subtask——它的 sync/async duration 一枝独秀。解法是第 2 节结尾的打散 key，不是调 checkpoint 参数。
4. **状态上传慢**：`state_size` 曲线持续上涨 + async duration 长。确认增量 checkpoint 已开（RocksDB）、存储端（HDFS/S3）带宽与限流；大状态作业把 interval 拉长换单次成功率。
5. **配置性连环超时**：interval 小于实际完成时长、又没配 `min-pause`，上一轮没完成下一轮已触发，雪崩式失败。interval / min-pause / timeout 三件套一起调，timeout 调大永远是最后手段。
6. **sink 侧拖累**：exactly-once KafkaSink 的事务超时（02 章第 5 节硬约束）；写湖作业的第一嫌疑人常常是**湖 commit**——对象存储慢、catalog 锁竞争都会让 sink 算子在 notifyCheckpointComplete 里卡住（`../../18-bigdata/07-lakehouse-table-formats.md` 第 7 节）。

日志关键词对照：

| 现象/日志 | 根因 | 处置 |
|---|---|---|
| `Checkpoint ... expired before completing` | barrier 被反压拖住，超 timeout | 第 2 条；临时 unaligned |
| declined by task + sink 事务报错 | 事务超时 / 湖 commit 卡住 | 核对 transaction.timeout.ms 与 interval；查对象存储与 catalog |
| sync duration 大 | 状态序列化/本地快照慢（HashMap 尤甚） | 换 RocksDB + 增量；查状态 TTL |
| async duration 大 | 上传存储慢 | 存储带宽/限流；增量 checkpoint |
| start_delay 持续增大 | 上一轮还没完成，新一轮排队 | 拉大 interval 与 min-pause |
| unaligned 后快照变大 | in-flight 数据一并入快照 | 预期行为，不是故障；治好反压可关 |

## 5. Flink CDC 入湖：衔接到 Paimon lab

CDC（变更数据捕获）在本书出现过两条路线，先分清：

| 维度 | Debezium + Kafka Connect（重装） | Flink CDC 直连（轻装） |
|---|---|---|
| 链路 | 源库 → Connect → Kafka → Flink | 源库 → Flink（内嵌 Debezium Engine） |
| CDC 流落地 | 落 Kafka，多下游复用、可回放 | 不落地，直接进作业 |
| 组件面 | Connect 集群 + 三个内部 topic | 无额外常驻组件 |
| 语义 | 至少一次进 Kafka（下游自行对齐） | exactly-once：**源端位点存进 checkpoint** |
| 适用 | 平台化、跨团队共享 CDC 流 | 单一下游的入湖/入仓管道 |

重装路线的运维细节在 `../kafka/03-operations-and-performance.md` 第 7 节；本节走轻装路线——Flink CDC connector 把 Debezium 嵌进 source 算子：全量阶段按主键切 chunk 多并行快照，增量阶段读 binlog/WAL 单流消费；**消费位点随算子状态进 checkpoint**，恢复后从位点续读，配合 sink 的两阶段提交形成端到端 exactly-once（02 章第 5 节的三前提在 source 侧补齐）。

```
PG 主库(wal_level=logical) ── replication slot(pgoutput) ──► Flink CDC source(内嵌 Debezium)
   │ 全量 snapshot(chunk 并行) + 增量(单流)                     位点存进算子状态/checkpoint
   ▼                                                            │ checkpoint N 完成
Paimon 表(LSM 主键表) ◄── sink(两阶段提交) ◄────────────────────┴── snapshot-N 原子提交
   changelog-producer=input：上游已是完整 CDC 流（含前像后像）
```

以 PG 订单表入 Paimon 为例（完整动手在 `../../18-bigdata/labs/04-lakehouse-flink-paimon`）：

```sql
-- [sql-client（连接到 Flink 集群，需已放 flink-connector-postgres-cdc 与 paimon 的 jar）]
CREATE TABLE orders_pg (
  order_id BIGINT,
  user_id  BIGINT,
  amount   DECIMAL(18,2),
  dt       STRING,
  PRIMARY KEY (order_id) NOT ENFORCED
) WITH (
  'connector' = 'postgres-cdc',
  'hostname' = 'pg-m', 'port' = '5432',
  'username' = 'flink_cdc', 'password' = '******',
  'database-name' = 'appdb',
  'schema-name' = 'public',
  'table-name' = 'orders',
  'slot.name' = 'flink_orders',            -- 每个作业独占一个槽，名字不许复用
  'decoding.plugin.name' = 'pgoutput',
  'heartbeat.interval.ms' = '10000'        -- 低流量时保活，防槽位点长期不动
);

INSERT INTO paimon.demo.orders    -- 目标表建法见 18-bigdata/07 第 4.4 节
SELECT order_id, user_id, amount, dt FROM orders_pg;
```

与 18-bigdata/07 的三个衔接点：

- **changelog-producer 选 input**：Paimon 表的 `changelog-producer='input'` 要求上游是完整 CDC 流（含前像后像），Flink CDC 正是合格源头——这比 lookup（回查补前像）便宜、比 full_compaction 快，是该链路上的默认选型（`../../18-bigdata/07-lakehouse-table-formats.md` 第 4.3 节）。
- **snapshot 与 checkpoint 一一对应**：Paimon 每次提交一个 snapshot，恢复时回滚到上一个——所以这条链上的 checkpoint 又超时，排查清单第 6 条（湖 commit）优先。
- **schema 演进接力**：源端加列经 CDC 事件传到 Paimon，落到 18-bigdata/07 第 6.3 节的表格式演进规则（加列安全、破坏性走四步），传输层契约则在 Kafka 侧由 Schema Registry 管（`../kafka/03-operations-and-performance.md` 第 8 节）。

运维红线集中在**源端**：PG 必须 `wal_level=logical` 且表有主键/REPLICA IDENTITY（否则 UPDATE/DELETE 定位不了行，同款坑见 `../../13-middleware/postgresql/02-replication-and-ha.md`）；作业停摆期间槽位点不推进，主库 WAL 堆积——监控 `pg_replication_slots` 的 retained、主库配 `max_slot_wal_keep_size` 兜底，两条纪律全部来自该章。另有两个高频坑：**起了新作业（无状态恢复）会触发全量重扫**，大表上等于对源库发起一次扫表攻击，必须走 savepoint 恢复；**增量阶段吞吐上不去是结构性的**（binlog/WAL 单流），加 source 并行度无效，瓶颈要么在单流解码要么在下游。

## 实战演练

目标：在一台 Ubuntu VM 的 Docker Flink 上，把本章第 1、2 节的知识走一遍——带状态的 SQL 作业做 stop-with-savepoint，尝试"超限扩容"亲眼看失败，再按合法并行度恢复成功。

### 步骤 1：起带共享状态卷的集群

```bash
# [任意节点]（Ubuntu VM）复用 02 章实战演练的环境：flink:1.19 的 jobmanager + taskmanager
# （4 slot），共享卷 flink-state 挂到 /tmp/state，savepoint 目录指向卷内
mkdir -p ~/flink-rescale && cd ~/flink-rescale
cp ~/flink-ckpt/docker-compose.yml .    # 02 章步骤 1 生成的那份；已删就照那一节原样重建
docker compose up -d && docker compose ps
# 预期：jobmanager 与 taskmanager 两个容器 running（JM 的 8081 已映射到本机）
```

### 步骤 2：提交带 max-parallelism 的窗口作业

```bash
# [任意节点] 故意把 max-parallelism 压到 2：为下一步的"超限扩容"制造现场
cat > job.sql <<'EOF'
SET 'execution.checkpointing.interval' = '5s';
SET 'parallelism.default' = '2';
SET 'pipeline.max-parallelism' = '2';

CREATE TABLE nums (
  n INT,
  ts AS LOCALTIMESTAMP,
  WATERMARK FOR ts AS ts - INTERVAL '2' SECOND
) WITH (
  'connector' = 'datagen', 'rows-per-second' = '10',
  'fields.n.kind' = 'random', 'fields.n.min' = '0', 'fields.n.max' = '999'
);

CREATE TABLE sink_t (window_start TIMESTAMP(3), window_end TIMESTAMP(3), cnt BIGINT, sum_n BIGINT)
WITH ('connector' = 'print');

INSERT INTO sink_t
SELECT window_start, window_end, COUNT(*), SUM(n)
FROM TABLE(TUMBLE(TABLE nums, DESCRIPTOR(ts), INTERVAL '10' SECOND))
GROUP BY window_start, window_end;
EOF
docker compose cp job.sql jobmanager:/tmp/job.sql
docker compose exec jobmanager ./bin/sql-client.sh -f /tmp/job.sql
# 预期：Table change response: OK，作业常驻
```

### 步骤 3：观察 checkpoint 统计字段

```bash
# [任意节点] 对照第 4 节的四个字段（浏览器开 http://<VM-IP>:8081 同样可看）
JOB_ID=$(curl -s http://localhost:8081/jobs/overview | grep -o '"jid":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
curl -s http://localhost:8081/jobs/$JOB_ID/checkpoints | grep -o '"counts":{[^}]*}'
# 预期：completed 随时间增长；单个条目里 state_size / end_to_end_duration 很小（datagen 作业）
```

### 步骤 4：stop-with-savepoint

```bash
# [任意节点] 注意用的是 stop（优雅停）而不是 cancel；不加 --drain
docker compose exec jobmanager ./bin/flink stop --savepointPath file:///tmp/state/savepoints $JOB_ID
# 预期：Savepoint completed. Path: file:///tmp/state/savepoints/savepoint-xxxx-xxxx
#       且作业自行退出（stop 的语义就是"快照后停机"）
```

### 步骤 5：先看超限扩容失败，再合法恢复

```bash
# [任意节点] 尝试以并行度 4 恢复（超过 max-parallelism=2，预期失败）
{ echo "SET 'execution.savepoint.path' = 'file:///tmp/state/savepoints/savepoint-xxxx-xxxx'; \
SET 'parallelism.default' = '4';"; cat job.sql | grep -v "parallelism.default"; } > fail.sql
docker compose cp fail.sql jobmanager:/tmp/fail.sql
docker compose exec jobmanager ./bin/sql-client.sh -f /tmp/fail.sql
# 预期：恢复报错（并行度超过最大并行度的语义，报错文案以当前版本为准）——
#       这就是第 1 节"maxParallelism 是隐形合约"的现场

# 换并行度 1（≤2），合法 rescale
{ echo "SET 'execution.savepoint.path' = 'file:///tmp/state/savepoints/savepoint-xxxx-xxxx'; \
SET 'parallelism.default' = '1';"; cat job.sql | grep -v "parallelism.default"; } > ok.sql
docker compose cp ok.sql jobmanager:/tmp/ok.sql
docker compose exec jobmanager ./bin/sql-client.sh -f /tmp/ok.sql

NEW_ID=$(curl -s http://localhost:8081/jobs/overview | grep -o '"jid":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
curl -s http://localhost:8081/jobs/$NEW_ID/checkpoints | grep -o '"counts":{[^}]*}'
# 预期："restored":1 —— 新并行度下成功认领状态
docker compose down   # 清理
```

验证方法：能复述"为什么第一次恢复失败、第二次成功"（keyed state 按 key group 重分配，subtask 数不得超过 key group 数）；`restored:1` 且窗口输出连续，即通过。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| savepoint 恢复报 could not map state | uid 变了（或 SQL 改动导致算子 ID 漂移） | 有状态算子固定 `.uid()`；改 SQL 先试恢复；确有删减加 `-n` |
| 并行度调大后恢复失败 | 新并行度 > maxParallelism（默认 `max(并行度,128)`） | 上线前显式设 `pipeline.max-parallelism`/`setMaxParallelism()` 预留余量 |
| stop 加了 `--drain` 后恢复的作业窗口结果异常 | drain 把 watermark 推到 MAX，事件时间状态被清 | 常规 rescale 一律不加；仅终态停机用 |
| TM Pod 反复 OOMKilled（exit 137） | `process.size` 超过容器 limit | 两边对齐；operator 部署即对齐 `resource.memory` |
| `OutOfMemoryError: Direct buffer memory` | network 预算不足 | 调大 `taskmanager.memory.network.min/max` |
| RocksDB native 内存持续上涨 | RocksDB 脱离 managed 纳管 | 保持 `state.backend.rocksdb.memory.managed=true`（默认）；按需调 managed.fraction |
| checkpoint 持续 expired/declined | 反压 / 倾斜 / 上传慢 / sink 事务 / 湖 commit | 按第 4 节清单顺序排查，别先调 timeout |
| unaligned 打开后 state_size 变大 | in-flight 数据一并入快照 | 预期行为；反压治好后可关 |
| CDC 作业重启后源库被全量重扫 | 新作业无状态恢复，或槽/位点丢失 | 必须 savepoint 恢复；重扫要错峰并评估源库 IO |
| CDC 增量阶段加并行度无效 | binlog/WAL 增量是单流 | 瓶颈在单流解码或下游；全量阶段的并行只加速快照 |
| PG 主库 pg_wal 暴涨 | CDC 槽位点长期不推进 | 监控 retained、配 `max_slot_wal_keep_size`、开心跳（13-middleware/postgresql/02 同款纪律） |

## 自测

1. 为什么 savepoint 靠算子 uid 认领状态，而不是靠算子名或拓扑位置？如果按位置认领会怎样？
<details><summary>答案</summary>

状态归属必须是跨版本稳定的合约：升级作业时业务逻辑、算子数量、代码结构都会变，位置和自动生成的名字随之漂移，"改一行代码就丢全部状态"不可接受。uid 是开发者显式承诺的稳定标识，与拓扑演进解耦——代价是必须从第一天就写，后补时老 savepoint 里的自动 ID 已经对不上，只能无状态重跑。
</details>

2. 并行度 64 的作业从未显式设置 maxParallelism，直接 rescale 到 200 会发生什么？应该提前怎么防？
<details><summary>答案</summary>

默认 maxParallelism = max(64,128) = 128，200 超限：keyed 状态的 key group 只有 128 组，无法切给 200 个 subtask，恢复失败（报错以版本为准）。预防：上线前按峰值预估的 2 倍显式设置，且之后不再改——maxParallelism 变了 key→group 映射就变，等于主动作废快照兼容性。
</details>

3. `flink stop`（stop-with-savepoint）和 `flink cancel` 抓一份 savepoint 再杀，差别在哪？`--drain` 为什么危险？
<details><summary>答案</summary>

stop 是协商式优雅停：先触发 savepoint，source 停止拉数，exactly-once sink 的事务随 notifyCheckpointComplete 提交，作业干净退出，恢复后不丢不重。cancel 是强杀（配 savepoint 只是临走抢一份快照），in-flight 数据与未提交事务按故障路径处理（abort 后靠重放）。--drain 会把 watermark 推到 MAX_VALUE 触发全部窗口再快照，适用于确定不再恢复的终态；常规升级用它，恢复后的事件时间语义可能错乱（细节以官方文档为准）。
</details>

4. TM 报 `Java heap space` 与报 `Direct buffer memory`，分别动哪块预算？为什么状态很大的 RocksDB 作业通常不加剧前一种？
<details><summary>答案</summary>

heap space 缺 Task Heap（`taskmanager.memory.task.heap.size`），direct buffer 缺 Network/framework off-heap（`taskmanager.memory.network.*` 等）。RocksDB 的状态放在堆外 managed memory（block cache + write buffer 共享预算），不占 Task Heap——这正是 01 章选它的理由：大状态不挤压算子对象与 GC。若 RocksDB 脱离 managed 纳管，则会变成无上限的 native 内存，最终以进程被 OOMKilled 收场。
</details>

5. checkpoint 的 `start_delay` 持续增大、失败连环出现，说明什么？与 interval、min-pause 的关系？
<details><summary>答案</summary>

说明上一轮 checkpoint 还没完成，新一轮在排队：实际完成时长已超过 interval。若不加 min-pause，触发会连续追赶，快照互相踩踏形成失败风暴。处置是先按清单找单轮变慢的根因（反压/倾斜/上传/sink），同时把 interval 拉到大于 P99 完成时长、配 min-pause 留缓冲；只调大 timeout 是把雪崩延后，不是消除。
</details>

6. 什么情况下必须放弃 Flink CDC 直连、回到 Debezium + Kafka 的重装路线？两条路线的 exactly-once 分别由什么保证？
<details><summary>答案</summary>

多个下游（入湖、缓存刷新、风控、搜索索引）都要同一份 CDC 流，或 CDC 流要作为可回放资产沉淀给其他团队——直连路线里 CDC 流不落地，其他系统想吃就得 Flink 再写一份出去，复制成本高。直连的 exactly-once：源端位点存进 checkpoint，配 sink 两阶段提交；重装的 exactly-once 边界止于 Kafka（至少一次进 topic，靠 keyed upsert/幂等消费对齐），多一跳但换来解耦与回放。
</details>

## 延伸阅读

- Savepoints（状态映射与算子 ID）：https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/state/savepoints/
- Stateful Stream Processing（key group 与 max parallelism）：https://nightlies.apache.org/flink/flink-docs-stable/docs/concepts/stateful-stream-processing/
- Task Manager 内存模型与配置：https://nightlies.apache.org/flink/flink-docs-stable/docs/deployment/memory/mem_setup_tm/
- RocksDB State Backend 调优：https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/state/state_backends_tuning/
- Checkpoint 监控与排障：https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/monitoring/checkpoint_monitoring/
- 大状态作业通用调优：https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/state/large_state_tuning/
- Flink CDC connectors 文档：https://nightlies.apache.org/flink/flink-cdc-docs-stable/
- Apache Paimon（主键表/changelog/入湖）：https://paimon.apache.org/docs/master/
