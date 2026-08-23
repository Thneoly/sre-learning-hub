# 01 · Flink 流处理模型：时间、水位线、窗口与状态

> 模块：12-data-streaming/flink ｜ 建议时长：3 小时 ｜ 关联认证：—（CKA/CKS/PCA 无直接考题，但它是 Kafka 消费端的核心引擎，也是实时链路排障的理论底座）

## 学习目标

- 能解释有界流与无界流的区别，以及 Flink"批是流的特例"这一立场与 Spark 的定位差异
- 能解释 event time / processing time / ingestion time 三种时间语义，并给指定业务（计费、告警、大盘）选出正确的一种
- 能推演 watermark 如何解决乱序：给定乱序容忍度和 allowedLateness，判断一条迟到数据会被计入、更新还是进 side output
- 能区分 operator state / keyed state / broadcast state，并判断一个作业该用 HashMap 还是 RocksDB StateBackend
- 能列出 savepoint 与 checkpoint 的至少 4 个本质区别，并说明升级作业时为什么必须用 savepoint

## 1. 有界流与无界流：一切模型的前提

数据只有两种形态：

| | 有界流（bounded） | 无界流（unbounded） |
|---|---|---|
| 数据量 | 固定，终会结束 | 无限，永远不结束 |
| 典型来源 | 文件、历史表、Kafka 指定 offset 段 | Kafka topic、socket、CDC |
| "结束"语义 | 有，可以等数据到齐再算 | 没有，必须边到边算 |
| Flink 处理方式 | 批模式（BATCH runtime mode） | 流模式（STREAMING） |

Flink 的核心立场是：**批是有界流的特例**。同一个 DataStream / SQL 程序，无界数据按流跑，有界数据切成阶段、用排序 shuffle 与阻塞式中间结果（blocking result partition）按批跑，这就是"流批一体"。对无界流的处理才是真正的难点——后面所有机制（时间、watermark、窗口、状态、checkpoint）都是为了让"永远算不完的数据"能算出**正确且及时**的结果。

```
无界数据处理的三难：
  正确性(等数据到齐) ←→ 及时性(尽快出结果) ←→ 成本(状态存得下)
        └── watermark / 窗口 / 状态后端 / checkpoint 全是围绕这三个的工程折中
```

## 2. 三种时间语义

流处理里"一个事件发生在什么时刻"有三种答案：

| 语义 | 时钟来源 | 特点 | 适用 |
|---|---|---|---|
| Event Time | 事件本身携带的时间戳（业务发生时刻） | 与到达顺序无关，结果确定性可重放；依赖 watermark 推进 | 计费、风控、对账、报表 |
| Processing Time | 算子所在机器的墙上时钟 | 延迟最低、无乱序问题；但结果受网络抖动/重启影响，不可重现 | 实时告警的粗过滤、监控大盘（可容忍误差） |
| Ingestion Time | 数据进入 Flink source 的时刻 | 折中方案，无法反映业务时间，实践中很少用 | 几乎不用 |

选择原则：**结果要进对账/钱的，必须 event time；只求"尽快看到个大概"的，processing time 可以接受。** 同一个需求里两种混用也很常见：告警用 processing time 先粗筛，落库统计用 event time。

自 Flink 1.12 起，`setStreamTimeCharacteristic` 已废弃，DataStream 统一按 event time 语义处理：时间语义实际由**算子消费的时间属性和 WatermarkStrategy** 决定——SQL 里 `PROCTIME()` 生成的列就是 processing time 属性，普通 `TIMESTAMP(3)` 列配合 `WATERMARK FOR` 就是 event time 属性（细节以官方文档为准）。

一个经典对比：机房 A 的日志因网络抖动晚到 2 分钟。processing time 语义下它会被算进"当前分钟"的窗口，凌晨重启后再跑一遍结果又不一样；event time 语义下它永远属于"事件发生的那一分钟"，重放多少遍结果都一样——这就是"可确定性重放"，也是 checkpoint 恢复后结果仍正确的前提。

## 3. Watermark：用"承诺"换取乱序容忍

无界流无法等所有数据到齐（永远等不齐），但窗口计算需要一个信号："事件时间 ≤ T 的数据**基本**到齐了"。这个信号就是 watermark：一个特殊记录，随数据流入，声明"事件时间时钟现在是 T"。

生成方式（最常用的是有界乱序）：

```java
// [开发机：DataStream API 代码，打包后提交到 Flink 集群]
WatermarkStrategy<Event> wm = WatermarkStrategy
    .<Event>forBoundedOutOfOrderness(Duration.ofSeconds(5))  // 乱序容忍 5s
    .withTimestampAssigner((evt, ts) -> evt.getEventTime()); // 从事件里取时间戳
stream.assignTimestampsAndWatermarks(wm);
```

规则：`watermark = 已见最大事件时间 maxTs - 乱序容忍度 delay`。watermark 是单调递增的。

```
到达顺序(括号内为事件时间)          maxTs   watermark = maxTs - 5s
  e(7)                              7       w=2
  e(3)   ← 乱序，但 3 > w=2         7       w=2   （正常计入，不算迟到）
  e(11)                            11       w=6
  e(9)   ← 乱序，9 > w=6           11       w=6   （正常计入）
  e(16)                            16       w=11
  e(9)   ← 9 < w=11                16       w=11  （迟到数据！）
窗口 [0,10) 在 w >= 10 时触发；e(9) 若在触发前到达就正常计入，触发后才到就是迟到数据
```

三个要点：

1. **乱序容忍度是"正确性与延迟的权衡"**：delay 调大，窗口触发更晚、结果更完整；调小，结果更快但更容易丢迟到数据。它应该等于业务观测到的实际乱序上限（P99 抖动），拍脑袋设 0 等于宣布"没有乱序"。
2. **多输入取最小**：一个算子有 N 个输入 channel（上游并行度），它的 watermark = 所有输入 watermark 的最小值——任何一个上游没推进，下游时钟就停着。所以某个 source 分区没数据（idle）会拖死全局时钟，需要 `withIdleness(Duration)` 让空闲 source 被跳过。
3. **迟到数据有三级处理**：

```java
// [开发机：DataStream API 代码]
DataStream<Event> late = stream
    .keyBy(e -> e.getKey())
    .window(TumblingEventTimeWindows.of(Time.seconds(10)))
    .allowedLateness(Time.seconds(30))          // 窗口触发后再宽限 30s
    .sideOutputLateData(new OutputTag<>("late", TypeInformation.of(Event.class)))
    .process(...);

// 超过宽限的数据从 side output 取走，落库/告警，而不是默默丢弃
DataStream<Event> lateEvents = late.getSideOutput(new OutputTag<>("late", TypeInformation.of(Event.class)));
```

- 到达时 `watermark < window_end`：正常计入（这是"乱序"，不是"迟到"）
- 窗口已触发但 `watermark < window_end + allowedLateness`：数据仍会计入该窗口并**再次触发输出**（下游要能处理修正，如 upsert）
- `watermark >= window_end + allowedLateness`：窗口状态被清理，数据进 side output

## 4. 窗口：把无界流切成有限的桶

窗口是把"无限数据"切给"有限计算"的手段。窗口生命周期：分配到桶 → 触发（fire，输出结果）→ 清理（purge，删状态）。event time 窗口的触发条件就是上一节的 `watermark >= window_end`。

| 窗口 | 语义 | 典型问题 |
|---|---|---|
| 滚动 Tumbling | 定长、不重叠：每条数据属于且只属于一个窗口 | "每 1 分钟的 UV" |
| 滑动 Sliding | 定长、步长滑动：一条数据可属于多个窗口 | "每 30s 统计过去 5 分钟的 QPS" |
| 会话 Session | 以活动间隙分割，窗口长度不定，必须 event time | "一次用户会话内的行为序列" |

```
滚动 tumbling（1 分钟）   [0,60)[60,120)[120,180)   数据只落一个桶
滑动 sliding（5min/1min）  [0,300)[60,360)[120,420)  同一条数据进 5 个桶 → 状态放大 5 倍
会话 session（gap=30s）    |--act--|   gap   |----act----|  每个 key 独立切分
```

SQL 写法（窗口 TVF，1.13+ 推荐语法）：

```sql
-- [sql-client（连接到 Flink 集群）]
-- 滚动窗口：每 10 秒每个词的计数
SELECT window_start, window_end, word, COUNT(*) AS cnt
FROM TABLE(
  TUMBLE(TABLE words, DESCRIPTOR(ts), INTERVAL '10' SECOND))
GROUP BY window_start, window_end, word;

-- 滑动窗口：窗口 5 分钟、步长 1 分钟
SELECT window_start, window_end, COUNT(*) AS cnt
FROM TABLE(
  HOP(TABLE events, DESCRIPTOR(ts), INTERVAL '1' MINUTE, INTERVAL '5' MINUTE))
GROUP BY window_start, window_end;

-- 会话窗口：静止 30 秒即切会话
SELECT window_start, window_end, user_id, COUNT(*) AS cnt
FROM TABLE(
  SESSION(TABLE clicks, DESCRIPTOR(ts), INTERVAL '30' SECOND))
GROUP BY window_start, window_end, user_id;
```

注意滑动窗口的状态放大：窗口长 5 分钟、步长 1 分钟意味着同一时刻要同时维护 5 个窗口的状态。会话窗口还要求窗口分配器保存"每个 key 的活动轨迹"，状态量与 key 数成正比——这两类窗口上线前先估状态大小，是 SRE 评审 Flink 作业的固定动作。

## 5. 状态：流计算的记忆

"每分钟每个词的计数"意味着算子必须记住"到目前为止数了多少"——这就是状态（state）。Flink 里状态分三类：

| 类型 | 归属 | 并行改动的重分配方式 | 典型用途 |
|---|---|---|---|
| Operator State | 算子实例（subtask） | 均匀 list 重分配，或 union（全量广播给各实例再自行取舍） | Kafka source 记录的 offset、BroadcastState |
| Keyed State | 每个 key 一份，跟着 key 所在的 subtask | 按 key group 哈希映射，并行度变化时 key group 整组迁移 | 窗口累积值、去重集合、累计计数 |
| Broadcast State | 广播到所有 subtask 的特殊 operator state | 全量下发 | 低维规则表/配置下发到所有数据分区 |

Keyed state 是绝对主力，接口有 `ValueState` / `ListState` / `MapState` / `ReducingState` / `AggregatingState`。它能随并行度变化而恢复的原因：Flink 把所有 key 预先划进固定数量的 **key group**（数量 = `maxParallelism`，默认 128），每个 subtask 负责一段连续 key group。改并行度只是把 key group 段重新切给不同 subtask，key 与 key group 的映射永远不变。

状态放哪由 StateBackend 决定（Flink 1.13 起的两类）：

| | HashMapStateBackend | EmbeddedRocksDBStateBackend |
|---|---|---|
| 存储 | JVM 堆内 HashMap | RocksDB（LSM 树，堆外内存 + 磁盘） |
| 读写 | 对象引用，最快 | 每次访问都要序列化/反序列化，慢一个量级 |
| 容量上限 | 受 TaskManager 堆限制，受 GC 拖累 | 可远超堆，只受磁盘限制，状态可达 TB 级 |
| 增量 checkpoint | 不支持 | 支持（只传新增 SST 文件） |
| 适用 | 状态小（百 MB 级）、追求低延迟 | 大状态、长窗口、大 key 基数 |

```yaml
# [flink-conf.yaml（JobManager 与 TaskManager 的配置文件）]
state.backend: rocksdb
state.backend.incremental: true
state.checkpoints.dir: file:///opt/flink/checkpoints
state.savepoints.dir: file:///opt/flink/savepoints
taskmanager.memory.jvm-overhead.factor: 0.1   # RocksDB 堆外内存要预算进去
```

长周期状态别忘了 TTL，否则 key 只增不减、状态无限膨胀直到 OOM：

```java
// [开发机：DataStream API 代码]
StateTtlConfig ttl = StateTtlConfig
    .newBuilder(Time.hours(24))            // 24 小时不访问即过期
    .setUpdateType(StateTtlConfig.UpdateType.OnCreateAndWrite)
    .cleanupInRocksdbCompactFilter(1000)   // RocksDB 下借 compaction 清理
    .build();
valueStateDescriptor.enableTimeToLive(ttl);
```

## 6. Savepoint 与 Checkpoint：长得像，用途完全不同

两者都是"全量状态快照 + 元数据"，底层机制相同（第 2 章的 barrier 快照），但设计目标不同：

| 维度 | Checkpoint | Savepoint |
|---|---|---|
| 触发 | 框架自动、周期性 | 人工触发（CLI / REST / Operator） |
| 目的 | 故障容错（自动从最近的恢复） | 升级、迁移、A/B、灰度 |
| 生成方式 | 可增量、可对齐优化，追求轻量 | 标准格式，可移植、跨版本 |
| 保留 | 保留最近 N 个（`state.checkpoints.num-retained`），新覆盖旧 | 永久保留，直到手动删除 |
| 目录 | `state.checkpoints.dir` | `state.savepoints.dir` 或命令行指定 |

```bash
# [flink 客户端机器（能连到 JobManager REST 的地方）]
./bin/flink savepoint <jobId> file:///opt/flink/savepoints
# 输出: Savepoint completed. Path: file:///opt/flink/savepoints/savepoint-1f2ab3-4e5f6a

./bin/flink run -s file:///opt/flink/savepoints/savepoint-1f2ab3-4e5f6a \
  -c org.example.Main ./myjob.jar
./bin/flink run -s <savepointPath> -n ...   # -n/--allowNonRestoredState：容忍删除了的算子状态
```

为什么升级不能用 checkpoint？一是它可能被新一轮自动覆盖甚至被清理策略删掉；二是它允许针对执行环境优化（增量、对齐裁剪），跨版本/跨拓扑兼容性没有承诺。savepoint 是"对外合约"，checkpoint 是"内部容错手段"。此外要让状态能对上号，代码里必须固定算子 ID（`uid("window-agg")`），否则改几行代码后 savepoint 里的状态找不到归属算子，恢复直接报 `could not map state`。

## 7. 流批一体：与 Spark 的定位对比

一句话定位：**Spark 以批为核心，流是微批模拟出来的；Flink 以流为核心，批是有界流的特例。** Spark（Structured Streaming）把无界流切成一个个小 batch，每个 batch 走一遍批引擎，延迟下限是 trigger interval（典型百毫秒到秒级）；Flink 逐条事件处理，延迟可以到毫秒级，事件时间和 watermark 是一等公民，状态本地驻留（RocksDB）而不必每个 interval 重算。

| | Spark Structured Streaming | Flink |
|---|---|---|
| 执行模型 | Micro-batch（可选 Continuous） | 逐事件（true streaming） |
| 端到端延迟 | 秒级为主 | 毫秒级 |
| 事件时间/水位线 | 支持（每个 batch 推进） | 原生，粒度更细 |
| 状态 | 批间状态 + WAL | 算子本地状态 + 增量 checkpoint |
| 批处理能力 | SQL 优化器与生态成熟，大规模批很强 | 批是有界流（BATCH 模式），够用但生态弱于 Spark |

选型口语版：重离线、SQL 生态深、延迟秒级可接受 → Spark；重实时、低延迟、大状态、复杂事件时间语义 → Flink。很多平台两者并存：Spark 做T+1 与大离线补数，Flink 做实时链路，同一套 Kafka 数据源供两边。

## 实战演练

目标：在一台 Ubuntu VM 上用 Docker 起一个本地 Flink 集群，跑一个 datagen → 滚动窗口聚合的 SQL 作业，亲眼看"窗口每 10 秒吐一次结果"。

### 步骤 1：起本地集群

```bash
# [任意节点]（Ubuntu VM，需已装 Docker 与 docker compose 插件）
mkdir -p ~/flink-demo && cd ~/flink-demo
cat > docker-compose.yml <<'EOF'
services:
  jobmanager:
    image: flink:1.19
    ports:
      - "8081:8081"
    command: jobmanager
    environment:
      - |
        FLINK_PROPERTIES=
        jobmanager.rpc.address: jobmanager
  taskmanager:
    image: flink:1.19
    depends_on:
      - jobmanager
    command: taskmanager
    environment:
      - |
        FLINK_PROPERTIES=
        jobmanager.rpc.address: jobmanager
        taskmanager.numberOfTaskSlots: 4
EOF
docker compose up -d
docker compose ps   # 预期 jobmanager 与 taskmanager 两个容器都是 running
```

### 步骤 2：进入 SQL Client 并建源表

```bash
# [任意节点]
docker compose exec jobmanager ./bin/sql-client.sh
```

```sql
-- [sql-client（上一步进入的交互终端）]
SET 'sql-client.execution.result-mode' = 'TABLEAU';

CREATE TABLE words (
  word STRING,
  ts  AS LOCALTIMESTAMP,
  WATERMARK FOR ts AS ts - INTERVAL '2' SECOND
) WITH (
  'connector' = 'datagen',
  'rows-per-second' = '5',
  'fields.word.kind' = 'random',
  'fields.word.length' = '3'
);
```

`ts AS LOCALTIMESTAMP` 是计算列，把"进入 Flink 的时刻"当作事件时间；`WATERMARK FOR ts AS ts - INTERVAL '2' SECOND` 即"乱序容忍 2 秒"的 watermark 策略——正是第 3 节 `forBoundedOutOfOrderness` 的 SQL 写法。

### 步骤 3：跑滚动窗口聚合并观察触发节奏

```sql
-- [sql-client]
SELECT window_start, window_end, word, COUNT(*) AS cnt
FROM TABLE(
  TUMBLE(TABLE words, DESCRIPTOR(ts), INTERVAL '10' SECOND))
GROUP BY window_start, window_end, word;
```

预期行为：前 10 秒没有任何输出（窗口没触发）；之后**每 10 秒集中吐出一批行**，`window_start`/`window_end` 恰好是 `[00秒,10秒)`、`[10秒,20秒)` 这样的左闭右开区间。这就是"watermark 越过 window_end 才触发"的直接体感。把 `INTERVAL '10' SECOND` 改成 `INTERVAL '30' SECOND` 重新执行，输出批次会变成每 30 秒一次。

### 步骤 4：看一眼运行中的作业

浏览器打开 `http://<VM的IP>:8081`（Windows 宿主机直接访问 VM IP），Running Jobs 里能看到刚才的 SELECT 作业；点进去的 DAG 是 `Source -> Window Aggregate -> Sink`，其中 watermark 的推进可以在作业 Metrics 页选 `currentWatermark` 观察。

```bash
# [任意节点]（退出 sql-client：按 Ctrl+C 终止查询后执行）
docker compose down
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 事件时间窗口永远不触发 | 没有生成 watermark，或某上游分区 idle 拖住全局最小值 | 给时间列定义 `WATERMARK FOR`；DataStream 上 `withIdleness()` |
| 统计结果总比"补数后"少一截 | 迟到数据超过容忍度被静默丢弃 | 调大乱序容忍度；加 `allowedLateness`；side output 收集迟到数据另处理 |
| TaskManager 堆内存持续增长 | keyed state 无 TTL，key 基数只增不减 | `StateTtlConfig`；或换 RocksDB 并开增量 checkpoint |
| 换了并行度后 savepoint 恢复失败 | 算子没固定 uid，状态映射不上 | 代码里给关键算子 `.uid("...")`；确有删除的算子时恢复加 `-n` |
| 会话/滑动窗口状态爆掉 | 窗口重叠导致状态放大，key 基数又大 | 估状态后改窗口设计或上 RocksDB |
| 重启后同一窗口结果变了 | 用了 processing time，窗口边界随墙上时钟漂移 | 要确定性结果就换 event time |

## 自测

<details><summary>1. 乱序容忍度 delay 从 5s 改成 60s，窗口输出的及时性和正确性各怎么变？什么时候必须调大？</summary>

及时性变差：watermark 推进变慢，每个窗口的触发最多延后 55s（近似 delay 的增量），下游看到结果的延迟直接增加。正确性变好：更多"事件时间早于 watermark"的迟到数据在窗口触发前就到达、被正常计入。当下游开始出现"side output 里迟到数据量明显增多"或对账差异集中在高峰时段（网络/上游抖动大的时段乱序也大），就必须调大 delay。delay 应对齐业务实际观测到的乱序分布（如 P99 抖动），而不是猜。
</details>

<details><summary>2. 为什么算子的有效 watermark 取所有输入 channel 的最小值？如果这个设计改成取最大值会怎样？</summary>

因为算子只有在"所有输入中事件时间 ≤ T 的数据都不会再来"时才能安全地认为时钟到了 T。取最小值是保守但正确的选择：任何一个上游还有更早的数据没发完，本地时钟就不能越过它。改成取最大值，快的那条输入会提前把时钟推过窗口边界，窗口提前触发，慢输入里属于该窗口的数据全部变成迟到数据——结果错误且不可恢复。
</details>

<details><summary>3. 一条数据的 event time 是 09:00:12，落在窗口 [09:00:10, 09:00:20)。它到达时 watermark 已经是 09:00:45，allowedLateness 是 30 秒。它的命运是什么？想救它有哪些手段？</summary>

窗口结束时间 09:00:20，加上 allowedLateness 30s，即状态保留到 watermark 09:00:50 才清理。当前 watermark 09:00:45 还没越过 09:00:50，所以这条数据仍会计入窗口并再次触发该窗口的输出（下游需支持 upsert/修正语义）。若 watermark 已过 09:00:50，它只能从 side output 取走。手段排序：加 allowedLateness（占用状态更久）、加大乱序容忍度 delay（让窗口晚触发）、修上游让数据别迟到（治本）。
</details>

<details><summary>4. keyed state 在并行度从 4 改到 8 后为什么还能恢复？operator state 与 broadcast state 在同样场景下行为有何不同？</summary>

key 与 key group 的映射由 hash(key) % maxParallelism 固定决定，与当前并行度无关；savepoint 里状态按 key group 存放，恢复时把 key group 段重新切给 8 个 subtask 即可，key 永远跟着自己的组走。operator state 恢复时按策略把 list 均匀重分配给新的并行度（或 union 模式下全量发给每个实例），语义由算子自己解释，比如 Kafka source 的 offset 分区要重新对上分区号。broadcast state 则是原样复制到每个 subtask，与并行度无关。
</details>

<details><summary>5. checkpoint 保留策略默认只留最近几个，为什么它不能当 savepoint 用？举一个会翻车的具体场景。</summary>

场景：准备升级作业版本，于是取消作业前记录了最近一次 checkpoint 路径；但在你操作之前作业还活着，又自动做了两次新的 checkpoint，旧的按 `state.checkpoints.num-retained` 被清理删除——等你拿路径去恢复时文件已经不存在。即使没被删，checkpoint 允许增量格式和版本相关的优化，跨 Flink 版本恢复没有兼容承诺。savepoint 由人显式触发、永久保留、标准格式，才是升级/迁移的合约。
</details>

<details><summary>6. 同样的"每 5 分钟窗口"需求，Spark Structured Streaming 和 Flink 在延迟形态上有什么肉眼可见的区别？为什么？</summary>

Spark 的输出按 trigger interval 整批推进：即使设置 trigger 间隔很小，也要等当前微批收集、计算、写完才有输出，延迟以秒为单位呈阶梯状，且窗口边界的对齐由微批时间决定。Flink 逐条处理，事件一到就更新内部状态，窗口在 watermark 越过边界的瞬间触发，端到端延迟可以压到毫秒级且不受批调度开销影响。根因是执行模型：微批本质是"用批引擎高频轮询模拟流"，而 Flink 是真正的持续执行模型。
</details>

## 延伸阅读

- Apache Flink 官方文档 — Working with Time：https://nightlies.apache.org/flink/flink-docs-stable/docs/concepts/time/
- Watermark 生成策略与迟到数据处理：https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/datastream/event-time/generating_watermarks/
- Stateful Stream Processing（状态分类与生命周期）：https://nightlies.apache.org/flink/flink-docs-stable/docs/concepts/stateful-stream-processing/
- State Backends（HashMap / RocksDB 取舍与配置）：https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/state/state_backends/
- Savepoints（与 checkpoint 的差异、状态映射）：https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/state/savepoints/
- Window TVF（SQL 窗口语法）：https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/table/sql/queries/window-tvf/
