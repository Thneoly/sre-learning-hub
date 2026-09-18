# 08 · ClickHouse：列存、MergeTree 家族与分布式表运维

> 模块：18-bigdata ｜ 建议时长：4 小时 ｜ 关联认证：—（CKA/CKS/PCA 无直接考点；监控接入复用 10-pca 的 exporter/PromQL 体系，docker 部署复用 03 模块；本章是 labs/05-clickhouse-cluster 的理论底座）

## 学习目标

- 能用"少读列 + 压缩率 + 向量化"三件套解释列存对分析查询的数量级加速，并说出它为什么做不了 OLTP
- 能区分 MergeTree / Replacing / Summing / Aggregating 四种引擎的合并语义，按场景选型并与 Doris 三模型对照
- 能解释"主键不是索引"：排序键 + 每 8192 行一个条目的稀疏索引 + 跳数索引各自负责什么
- 能画出"本地表 + Distributed 双表"的写入路径，说清 ReplicatedMergeTree 依赖 ZK/Keeper 协调什么
- 能排查 "too many parts"：从 parts 数、merge 速度追到写入批次，并给出预防参数思路

版本约定：ClickHouse 25.x（docker 镜像 `clickhouse/clickhouse-server`）。它一年多个大版本，参数默认值（粒度、限流阈值、实验特性开关）随版本漂移极快，凡涉及具体默认值处以官方文档为准，本文只写机制不写死数值。

## 1. 列存为什么快

03 章从 Hive 视角讲过 ORC/Parquet（`18-bigdata/03-hive-warehouse.md` 第 4 节），ClickHouse 把同一思想做进了"实时数据库"：数据按列组织在不可变的 **part** 文件里，而不是按行组织在 B+ 树页里。

```
行存（InnoDB / TextFile 的逻辑视图）            列存（MergeTree part 的物理布局）
┌──────────────────────────────────┐          ts     │12:00:01│12:00:02│12:00:05│12:01:00│…
│ 12:00:01 │ click │ 1001 │ 3      │          event  │click   │click   │view    │click   │…
│ 12:00:02 │ click │ 1002 │ 1      │ ──重排──► user   │1001    │1002    │1001    │1003    │…
│ 12:00:05 │ view  │ 1001 │ 0      │          cost   │3       │1       │0       │2       │…
│ 12:01:00 │ click │ 1003 │ 2      │          （每列独立文件：.bin 压缩块 + .mrk2 偏移）
└──────────────────────────────────┘
SELECT event, count() FROM t                只碰 event 一列：4 列的表 IO 直接变 1/4；
                                            列内"同类型、重复度高"，压缩编码才能发力
```

三个乘法因子，缺一不可：

1. **只读用到的列**。分析查询往往只用 5~10 列，宽表上百列时 IO 差一个数量级以上——这是 05 章第 1 节"报表为什么不放 MySQL 上跑"的物理根源。
2. **压缩率**。同列数据类型相同、取值重复度高；MergeTree 又按 ORDER BY 键物理排序，排序后的列用 RLE/字典/Delta 编码几乎"白送"（用户 ID 单调递增时 DoubleDelta 能把 8 字节压到不到 1 字节）。经验量级：行存文本 1x 的数据，列存 LZ4/ZSTD 后 5~10x 起步，按排序键聚簇后更高（量级随数据形态浮动，对照 03 章 ORC 4~10x / Parquet 3~8x 的表，原理同源）。
3. **向量化执行**。列式内存布局让"一次处理一批同类型值"（SIMD）成为默认执行方式，而不是逐行解释。05 章称 ClickHouse 为"向量化鼻祖"，Doris/StarRocks 的向量化引擎（2.x）都是向它看齐的。

反过来它就做不了 OLTP（对照 `13-middleware/mysql/01-innodb-fundamentals.md` 第 2 节的 B+ 树）：按主键取一行要把所有列的 part 文件拼回来、点查走的是"定位粒度再扫描"而不是 3 层 B+ 树的 2 次页 IO；数据不可变（immutable part）意味着没有原地更新，改一行等于重写整个列块。**列存用"单行昂贵"换"一批极快"**。

## 2. MergeTree 引擎族：合并语义决定表的行为

ClickHouse 每张表要显式选引擎，90% 的表落在 MergeTree 家族。共同底座：**写入只生成不可变 part，后台 merge 把小 part 周期性合并成大 part**——这正是 07 章第 4.1 节说 Paimon 主键表"与 RocksDB/ClickHouse MergeTree 同族"的那棵 LSM 血统。家族成员的差别只在"合并时对同键行做什么"：

| 引擎 | 合并时做什么 | 对应 Doris 模型（05 章第 3 节） | 典型场景 |
|---|---|---|---|
| MergeTree | 什么都不做，行永不合并 | Duplicate | 原始日志/明细留存，读时聚合 |
| ReplacingMergeTree(ver) | 同排序键保留 version 最大的一行 | Unique（但语义弱得多，见下） | upsert 画像/订单状态 |
| SummingMergeTree | 同排序键的数值列求和 | Aggregate（SUM 子集） | 预聚合指标表 |
| AggregatingMergeTree | 同排序键按 AggregateFunction 状态合并 | Aggregate（含 count distinct） | 精确/近似去重、复杂聚合 |
| （前缀）Replicated* | 上述任意一种 + 副本复制 | —（Doris 副本是集群级能力） | 所有生产表 |

两个必须建立的认知：

- **ReplacingMergeTree 不是"实时 upsert"**。去重发生在后台 merge 碰巧把新旧版本合进同一个 part 时——异步、不保证时机；没合并前旧行还在，查询要 `FINAL` 或 `GROUP BY` 现场收敛。Doris Unique + merge-on-write 是写时打掉旧版本（05 章第 3 节），ClickHouse 没有等价的零代价路径，mutation（`ALTER TABLE ... UPDATE/DELETE`）是整 part 重写的重操作。这就是 05 章对比表里"实时更新"一行 ClickHouse 偏弱的具体机制。
- **排序键（ORDER BY）是表定义里最重要的字段**。它同时决定：数据在 part 内的物理顺序（压缩率与扫描裁剪都吃它）、稀疏索引的内容（第 3 节）、Replacing/Summing 的合并键。选错排序键 = 压缩差 + 查询全扫，属于"建表时一秒钟、运维时一整年"的决策。

## 3. 主键非索引的真相：排序键 + 稀疏索引 + 跳数索引

从 MySQL 过来最容易带的错误预期：`PRIMARY KEY` 能"按 key 定位一行"。ClickHouse 的主键（其实是 ORDER BY 的前缀）**不是行级索引，是排序描述**：

```
一个 part 的内部（ORDER BY (event, user, ts)）：
 ┌─granule 0─── 8192 行 ───┐  ┌─granule 1── 8192 行 ─┐  ┌─granule 2 ─┐  ……
 │ click,1000,…  click,1004,…│ │ click,1088,…           │ │ view,1002,…  │
 └────────▲─────────────────┘ └────────▲───────────────┘ └────────▲─────┘
          │ primary.idx 只存每个 granule 的首键：                 │
          │ (click,1000,12:00:01) (click,1088,…) (view,1002,…)   │
          │ 二分定位 → 只把命中粒度的列块解压读出                  │
          └─ marks(.mrk2) 记录"每个 granule 在各列文件里的偏移"
```

- **稀疏索引**：主键索引每 8192 行（`index_granularity`，自适应粒度默认开启）记一个条目，整个索引常驻内存、体积是行数的 1/8192——所以它能描述海量数据，但只能回答"哪些**区间**可能命中"，命中后要扫整个 granule（最多 8192 行）。按主键前缀做范围聚合极快；按主键**点查单行**则要为这一行解压上万个邻居，比 B+ 树差几个数量级。
- **每列每粒度的 min/max 统计**让非主键列也能跳过整个 granule（ WHERE ts > X 而 ts 恰好是排序键后缀时收益最大）。
- **跳数索引（data skipping index）**：对**不在排序键里**的列，手工补 `minmax` / `set` / `bloom_filter`（`ngrambf_v1`/`tokenbf_v1` 用于字符串 LIKE/等值）二级索引，粒度按 `GRANULARITY N` 个数据粒度取块。它同样是"跳过不相关粒度"，不是定位行。

运维推论：点查明细请走 MySQL/Redis 这类系统（13 模块），ClickHouse 的主键设计面向"前缀过滤 + 大扫描收敛"。另外跳数索引只对**建索引之后写入**的数据生效，存量数据要 `MATERIALIZE INDEX`（整 part 重写，代价同级 mutation，具体语法以官方文档为准）。

## 4. 分片与副本：ReplicatedMergeTree 与 ZK/Keeper

ClickHouse 的复制有一个非常反直觉的设计：**复制不是集群级功能，是表引擎前缀**。同一张"逻辑表"在每个分片的每个副本上都要显式建本地表，引擎写成 `ReplicatedMergeTree(zk_path, replica_name)`，副本间靠 ZK/Keeper 协调——这正是 06 章第 1 节租户表里那行 "ClickHouse ReplicatedMergeTree 副本合并协调" 的含义：

```
                    ZooKeeper / ClickHouse Keeper（06 章第 5 节：Raft 实现、协议兼容 ZK）
                    /clickhouse/tables/01/events/leader_election   ← merge 领选：同一时刻一个副本执行
                    /clickhouse/tables/01/events/replicas/r1/log   ← 复制日志：part 变更序列
                    /clickhouse/tables/01/events/blocks/N          ← 写入块哈希（去重，见第 6 节）
                              ▲ 认领/心跳/排队                        ▲ 追日志拉数据
        ┌─────────────────────┴────────┐              ┌─────────────┴──────────┐
        │ ch-1: ReplicatedMergeTree     │  ← part 文件级同步 → │ ch-2: ReplicatedMergeTree   │
        │ /tables/{shard}/events, r1    │              │ /tables/{shard}/events, r2 │
        └───────────────────────────────┘              └───────────────────────────┘
             shard 01 的两个副本（zk_path 相同，replica 名不同）
```

协调三件事：**merge 领选**（所有副本执行相同 merge 序列，保证 part 集合一致）、**复制日志**（离线副本回来后追 log 补 part）、**写入去重**（同 block 哈希的重发默认丢弃，`insert_deduplicate`，窗口大小 `replicated_dedup_window`）。`{shard}`/`{replica}` 来自每节点 macros 配置，zk_path 相同 + replica 名不同 = 一组副本——**建表时写错路径，要么不复制（路径不同），要么互删（同 replica 名）**，这是新集群第一周的经典事故。

Keeper 与 ZK 二选一：新部署直接用 **ClickHouse Keeper**（内置二进制、去 JVM、Raft 实现，06 章第 3 节的 ZAB/Raft 对照表直接适用），存量 ZK 也仍被支持；两者对 ClickHouse 是等价后端，下文统称 ZK/Keeper。SRE 心法沿用 06 章结论：ZK/Keeper 挂掉不碰已落盘的数据，但**副本表会降级只读（is_readonly）、写入被拒、merge 停摆**——小而致命，告警优先级与 etcd 同级，四字命令/mntr 指标体系照搬 06 章第 6 节。

可用性数学与 Doris 对比：分片数 × 副本数张成可用性网格（2 分片 ×2 副本容忍任意单节点故障）。Doris 的副本由 FE 的副本调度器自动 clone 补齐（05 章第 2 节 tablet），ClickHouse 没有这个"自动维修工"——副本掉了要自己看 `system.replicas` 的队列、必要时 fetch 补数。换来的是每张表可以独立决定分片副本形态（明细表 2 副本、报表表 1 副本各取所需）。

## 5. 本地表 vs Distributed：双表架构与写入路径

ClickHouse 没有"一张表自动分布在所有节点"的形态。标准做法是**双表**：每个节点建本地表（真正存数据），再在每个节点建一张同名的 Distributed 表当"路由视图"（不存数据，只记 cluster 名、目标本地表、分片键）：

```
                    INSERT INTO metrics_all（连任意节点，ch-1）
                              │
                              ▼
              Distributed 表：按分片键 sipHash64(host) 把 block 劈开
                              │ 默认异步（insert_distributed_sync=0）
              ┌───────────────┴───────────────┐
              ▼                               ▼
   shard 01 本地 metrics_local        shard 02 本地 metrics_local
   （ch-1、ch-2 各一副本，ZK 协调）    （ch-3、ch-4 各一副本）
              │                               │
              └───── 后台 merge（第 6 节）─────┘

   SELECT FROM metrics_all：发起节点把查询 fan-out 到各分片本地表，
   各自扫完回发起节点汇聚（对应 Doris 的 FE 规划 + BE 扫描，但无 CBO）
```

写入路径的运维要点：

- **默认异步**：INSERT 先落在发起节点的本地缓冲目录，后台线程再发往各分片——发起节点在"落盘缓冲与送达之间"崩溃，这批数据可能丢。要求不丢的链路设 `insert_distributed_sync=1`（同步等各分片确认），或接受 at-least-once 由上游重放。
- **重放幂等**：上游（Flink checkpoint 恢复，14 模块的 exactly-once 框架）重发同一 block，副本表按 block 哈希去重——效果与 Doris 的 label 幂等（05 章第 5 节）同构，只是幂等键从显式 label 换成隐式数据哈希，窗口有限。业务级幂等仍要靠 ReplacingMergeTree(version) 兜底。
- **扩容是手工活**：新增分片后，历史数据不会自动搬迁（Distributed 只影响新写入的路由），要么重灌、要么按 19-distributed/05-sharding-and-rebalancing.md 第 4 节的再平衡窗口方法论手工迁移；可用 `weight` 调新旈权重渐进导流。这是对比 Doris "BE 加入即自动均衡 tablet"最疼的运维差异。

## 6. 后台 merge 与 parts："too many parts" 的因果链

parts 是 MergeTree 的物理单元：每次 INSERT 至少产生一个 part，后台 merge 按"少而大"的方向持续合并（小 part 优先、防写放大）。稳态下每分区 parts 数应是个位数；**一旦写入产生 parts 的速度持续超过 merge 消化速度，就进入死亡螺旋**：

```
高频小 INSERT（每秒 N 次 × 几百行）
   → 每分区的 parts 数上涨（system.parts active 计数、MaxPartCountForPartition）
   → 超过软阈值：写入被故意 delay（parts_to_delay_insert）
   → 超过硬阈值：INSERT 直接报错 "Too many parts (N). Merges are processing
     significantly slower than inserts."（parts_to_throw_insert，默认 300，以文档为准）
   → 上游 Flink sink 反压 → checkpoint 超时 → Kafka 消费 lag（14 模块的排障链原样适用）
```

这与 Doris 的 "too many versions"（05 章第 6.2 节）是同一个病在不同引擎的名字：**微批太碎，版本/部件数超过后台合并能力**。治理同源：攒批（单次 INSERT 至少万行或 MB 级，官方调优文档建议每表每秒不超过约一次 INSERT，具体数值以文档为准）；小写入方太多时开 `async_insert`（服务端替你攒批）；merge 跟不上时评估 `background_pool_size` 与磁盘 IO，而不是一味重试。预防性指标：`MaxPartCountForPartition`（system.asynchronous_metrics）持续上涨即预警，社区常用告警线在几百到一千，按官方调优文档定。

另外两类"看起来像故障"的 merge 行为：`OPTIMIZE TABLE ... FINAL` 是手工强制合并（重写全部数据，别当日常操作跑）；mutation（`ALTER ... DELETE/UPDATE`）同样走 part 重写队列，在 `system.mutations` 里能看到进度——大表 mutation 是小时级任务，变更管理要当批处理作业对待。

## 7. 物化视图：写入路径上的预聚合

```sql
-- [任意节点] 典型两级结构：目标表 + 触发它的 MV（两表都要在，MV 本身不存数据）
CREATE TABLE sre_lab.host_agg (host String, cnt UInt64, vsum Float64)
  ENGINE = SummingMergeTree ORDER BY host;
CREATE MATERIALIZED VIEW sre_lab.metrics_mv TO sre_lab.host_agg AS
  SELECT host, count() AS cnt, sum(val) AS vsum FROM sre_lab.metrics_local GROUP BY host;
```

MV 挂在**本地表**的写入路径上：每个 insert block 进来，先过 MV 的 SELECT 算出聚合行、写入目标表，再落基表——与 Doris 的 Aggregate 模型"写时预聚合"（05 章第 3 节）语义相同，区别是 Doris 是表内建模型、ClickHouse 是"基表 + MV + 目标表"三件套自由拼装（也就多了"目标表引擎选错/两套 schema 漂移"这类自找的运维面）。三个工程要点：

1. **顺序**：先建 MV 再写入。MV 只处理创建之后的数据；给已有数据的表补 MV 要用 `POPULATE`（建表瞬间有并发写入时会漏/重，生产别赌）或"新建 MV + 手动回填目标表 + 双写切换"。
2. **状态聚合**：count distinct 这类不可加聚合用 AggregatingMergeTree + `AggregateFunction` 类型（写入 `uniqState()`、查询 `uniqMerge()`），普通 SummingMergeTree 存不了中间态。
3. **链式可以但别失控**：MV 触发 MV 形成 pipeline，一层慢整条慢，排障时沿 `system.query_log` 的 insert 链逐段看。

## 8. 与 Doris/StarRocks 对比（补强 05 章：存储引擎与 merge 的内部维度）

05 章第 4 节的对比表覆盖了架构/join/生态/选型结论（单表极限聚合选 CH，多表 join 与低运维成本选 Doris/StarRocks），不重复。这里换到**引擎内部与日常运维实操**的维度——选型评审答完"性能"后，这两张表决定的是"夜里被告警吵醒的频率"：

| 维度 | Doris / StarRocks | ClickHouse |
|---|---|---|
| 存储引擎形态 | 一套统一列存 segment，表语义靠三模型切换 | 每表显式选 MergeTree 族引擎；Replicated 前缀与家族正交组合，表多后"引擎组合治理"是独有运维面 |
| merge 模型 | 版本合并：每次导入 = tablet 一个版本，cumulative/base 两级 compaction 把版本压回去，Aggregate 语义在合并时收敛 | part 合并：按大小与秩挑选 part 重写，Replacing/Summing 语义在合并时收敛。同属 LSM 后代（07 章第 4.1 节），CH 的合并单位更大、更"攒" |
| 数据修正 | Unique MoW 写时收敛，读路径干净 | Replacing 异步收敛 + FINAL 读放大；mutation 整 part 重写（第 2/6 节） |
| 副本与修复 | FE 副本调度器自动 clone 补齐（05 章第 2 节） | 表级 ReplicatedMergeTree 自协商，修复要盯 system.replicas 队列，无自动均衡 |
| 扩容与再均衡 | BE 上线即自动均衡 tablet | 加分片后历史数据手工迁移（第 5 节），规划期就要把分片数留足 |
| 元数据与协调 | FE 内嵌元数据（bdb 过半复制），无外部依赖 | 无中心元数据：每节点全量 DDL（ON CLUSTER 走 ZK 队列）；复制协调依赖外部 ZK/Keeper |

一句话总结运维复杂度的形状差异：**Doris 的复杂度在"组件"（FE/BE 两类角色要理解），ClickHouse 的复杂度在"每张表自带架构"**——分片数、副本路径、排序键、引擎族、merge 参数全是表级决策，错误会在几百张表里各自复发。人手少的团队这是比 join 能力更硬的取舍依据。

## 9. 运维：system 表、exporter、备份

ClickHouse 的可观测性入口是 `system` 库（只读系统表，本身就是 ClickHouse 表，可以直接 SQL 分析）：

| 表 | 看什么 | 典型问题 |
|---|---|---|
| system.parts | active parts 数、rows/bytes、分区分布 | 第 6 节 too many parts 的第一现场 |
| system.merges / system.mutations | 进行中的合并与重写、进度 | merge 积压、大 mutation 卡队列 |
| system.metrics / system.events | 即时 gauge（Query/Merge/PartsActive/MemoryTracking）与累计计数器 | 当前负载、错误计数 |
| system.asynchronous_metrics | 周期采集值（MaxPartCountForPartition、文件句柄等） | parts 趋势预警 |
| system.replicas | is_readonly、复制队列深度、延迟 | ZK/Keeper 断连、副本掉队 |
| system.query_log | 每条查询的耗时/内存/扫描行数 | 慢查询归因（对应 05 章慢查询三板斧） |
| system.zookeeper / system.distributed | ZK 内容视图、Distributed 发送队列 | 异步写入堆积在发起节点 |

监控接入两条路：**内置 Prometheus 端点**（server 的 HTTP 端口暴露 `/metrics`，prometheus 配置节可调，以官方文档为准，指标名以端点实际输出为准）开箱即用；需要更丰富语义（按库表的 parts/查询维度）时补 **clickhouse-exporter**（社区 exporter，连上 server 查 system 表翻译成指标——与 10-pca/04-instrumentation-exporters.md 第 3.3 节 mysqld exporter 同一个"问询式翻译"模式）。告警最低配三条：parts 数（MaxPartCountForPartition 或 system.parts 计数）持续上涨、system.replicas 出现 is_readonly、ZK/Keeper 侧沿用 06 章第 6.4 节的 outstanding/latency 告警。

备份思路（副本不是备份，删库指令在副本上同样复制——纪律等同 `13-middleware/mysql/02-backup-replication.md`）：

- **原生 FREEZE**：`ALTER TABLE ... FREEZE [PARTITION ...]` 在本地 `shadow/` 目录对 part 打硬链接快照（不复制数据、秒级、省空间），再把 shadow 归档到对象存储；恢复靠 `ATTACH` 从备份目录挂回（语法与限制以官方 backup/restore 文档为准）。新版另有原生 `BACKUP/RESTORE` 语句走向成熟，能力矩阵随版本变，落地前对文档。
- **clickhouse-backup 工具**（社区事实标准）：封装 FREEZE + S3/GCS 上传 + 定期轮转，配合 cron 即成备份流水线。
- **别忘了表结构**：ZK/Keeper 里只有协调状态没有 DDL，建表语句要从 `system.tables`/`SHOW CREATE TABLE` 定期导出——否则数据 part 都在、却没人记得这张表怎么建。

## 实战演练

单节点 docker 快速体验（集群版完整演练在 `labs/05-clickhouse-cluster`）。镜像 tag 以 Docker Hub `clickhouse/clickhouse-server` 官方页面为准，取当前 LTS（下文以 25.3 为例）：

```bash
# [任意节点] 起 server（镜像内置 clickhouse-client；nofile 上限参照官方 docker 文档）
docker run -d --name ch-solo -p 8123:8123 -p 9000:9000 \
  --ulimit nofile=262144:262144 clickhouse/clickhouse-server:25.3
until docker exec ch-solo clickhouse-client --query 'SELECT 1' >/dev/null 2>&1; do sleep 2; done
curl -sS http://127.0.0.1:8123/ --data-binary 'SELECT version()'   # HTTP 接口，预期打印版本号
curl -sS http://127.0.0.1:8123/metrics | head -5                   # 内置 Prometheus 端点（指标名以输出为准）
```

```sql
-- [任意节点] 建表、批量写入、观察 parts 与 merge（clickhouse-client 经 docker exec 执行）
CREATE DATABASE IF NOT EXISTS demo;
CREATE TABLE demo.events (ts DateTime, event String, user_id UInt32, cost UInt32)
  ENGINE = MergeTree PARTITION BY toDate(ts) ORDER BY (event, user_id, ts);

-- 三次 INSERT = 三个 part（每次 INSERT 一个 part 是铁律，与行数无关）
INSERT INTO demo.events SELECT now() - (n % 7200), if(n%3=0,'click',if(n%3=1,'view','buy')),
  toUInt32(n % 500), toUInt32(n % 50) FROM (SELECT number AS n FROM numbers(100000));
INSERT INTO demo.events SELECT now() - (n % 7200) - 7200, if(n%3=0,'click',if(n%3=1,'view','buy')),
  toUInt32(n % 500), toUInt32(n % 50) FROM (SELECT number + 100000 AS n FROM numbers(100000));
INSERT INTO demo.events SELECT now() - (n % 7200) - 14400, if(n%3=0,'click',if(n%3=1,'view','buy')),
  toUInt32(n % 500), toUInt32(n % 50) FROM (SELECT number + 200000 AS n FROM numbers(100000));

SELECT partition, name, rows, bytes_on_disk FROM system.parts
  WHERE database='demo' AND table='events' AND active ORDER BY partition;
-- 预期：3 个 part（跨了今天/昨天两个分区时更多），bytes_on_disk 远小于行数×列宽（压缩生效）

OPTIMIZE TABLE demo.events FINAL;      -- 手工强制合并（演示用，生产别日常跑）
SELECT count() FROM system.parts WHERE database='demo' AND table='events' AND active;
-- 预期：每个分区合并成 1 个 part

SELECT metric, value FROM system.metrics WHERE metric IN ('Query','Merge','PartsActive','MemoryTracking');
SELECT name, value FROM system.asynchronous_metrics WHERE name = 'MaxPartCountForPartition';
```

```sql
-- [任意节点] ReplacingMergeTree：异步去重与 FINAL 的代价
CREATE TABLE demo.user_state (user_id UInt32, balance UInt32, ver UInt32)
  ENGINE = ReplacingMergeTree(ver) ORDER BY user_id;
INSERT INTO demo.user_state VALUES (1,100,1),(2,50,1);
INSERT INTO demo.user_state VALUES (1,80,2);                 -- 同主键新版本
SELECT count() FROM demo.user_state;                          -- 3（还没合并，旧行仍在）
SELECT user_id, argMax(balance, ver) FROM demo.user_state GROUP BY user_id;  -- 1→80, 2→50（读时收敛的推荐姿势）
SELECT count() FROM demo.user_state FINAL;                    -- 2（FINAL 收敛，大表上代价高）
OPTIMIZE TABLE demo.user_state FINAL;  SELECT count() FROM demo.user_state; -- 2（合并后落定）
```

```sql
-- [任意节点] 稀疏索引的体感：主键裁剪的是粒度，不是行
EXPLAIN indexes = 1 SELECT count() FROM demo.events WHERE event = 'click' AND user_id = 7;
-- 预期：计划里 PrimaryKey 部分显示按 granule 裁剪（Selected xxx of N granules），
--      点查一个 user 实际扫的是它所在的整个 8192 行粒度——"主键非行索引"的直观证据
```

```sql
-- [任意节点] 跳数索引：给不在排序键里的列补"跳过粒度"的二级索引
CREATE TABLE demo.events2 (ts DateTime, event String, user_id UInt32)
  ENGINE = MergeTree ORDER BY (event, ts);      -- user_id 不在排序键里，主键帮不上它
INSERT INTO demo.events2 SELECT now() - (n % 7200), if(n%3=0,'click','view'),
  toUInt32(intDiv(n, 200)) FROM (SELECT number AS n FROM numbers(100000));
ALTER TABLE demo.events2 ADD INDEX idx_user minmax(user_id) GRANULARITY 2;
INSERT INTO demo.events2 SELECT now() - (n % 7200) - 7200, if(n%3=0,'click','view'),
  toUInt32(intDiv(n, 200)) FROM (SELECT number AS n FROM numbers(100000));  -- 建索引后写入的批次才生效
EXPLAIN indexes = 1 SELECT count() FROM demo.events2 WHERE user_id = 300;
-- 预期：计划出现 Skip Index: idx_user，命中粒度远小于全表（输出格式随版本略有差异）
```

验证方法：不看正文能说清"3 次 INSERT 为什么是 3 个 part、OPTIMIZE 后为什么变 1、ReplacingMergeTree 为什么查出来先是 3 行"。清理：`docker rm -f ch-solo`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| "Too many parts / Merges are processing significantly slower than inserts" | 高频小 INSERT，parts 超过 `parts_to_throw_insert` | 攒大批次；小写入方开 `async_insert`；评估 `background_pool_size`（第 6 节） |
| ReplacingMergeTree "去重没生效"，查出新旧两行 | 去重只在后台 merge 碰巧合并时发生，异步且不保证 | 查询侧 `argMax`/`FINAL` 收敛，或接受最终一致；要写时收敛就别选 CH（对照 Doris MoW） |
| 副本表突然全部 is_readonly、INSERT 被拒 | ZK/Keeper 不可用（会话断），副本表降级只读保一致 | 修 ZK/Keeper（06 章运维手册）；期间本地查询不受影响，恢复后自动追平 |
| 两节点数据"没复制"或互相丢 part | ReplicatedMergeTree 的 zk_path 或 replica 名写错（路径不同=不复制，同名=互踢） | 核对 macros 与建表参数；zk_path 按 `/clickhouse/tables/{shard}/表名` 规范写 |
| Distributed 表写入后马上查不到 | 默认异步：先落发起节点缓冲，后台再发分片 | 等秒级/查 `system.distributed` 队列；要同步设 `insert_distributed_sync=1` |
| 加了节点数据不均衡 | 新分片只接新写入，历史数据不自动迁移 | 规划期留足分片；迁移按 19-distributed/05 第 4 节窗口方法论手工做，`weight` 渐进导流 |
| 给存量大表补 MV 后数据少了 | MV 只处理建表后的写入，`POPULATE` 有并发竞态 | 先建 MV 再写入是正道；存量用"新 MV + 手动回填 + 双写切换" |
| UPDATE/DELETE 一条提交后几小时没生效 | mutation 是整 part 重写的异步队列任务 | 看 `system.mutations` 进度；大表变更当批处理作业排窗口 |
| 把高并发点查接到 CH 上，p99 惨不忍睹 | 稀疏索引定位的是 8192 行粒度，不是行 | 点查明细走 MySQL/Redis（13 模块）；CH 只服务分析型扫描 |
| skip 索引建了没用 | 只对建索引之后写入的数据生效 | 存量数据 `MATERIALIZE INDEX`（重写 parts，择窗口执行） |

## 自测

1. 同一个"按 user_id 查一行"的请求，MySQL 3 层 B+ 树 2 次页 IO 返回，ClickHouse 要做什么、代价差在哪？什么查询会让这个对比反转？
<details><summary>答案</summary>

MySQL：聚簇索引按主键组织，根节点常驻内存，2 次页 IO 精确到行（13-middleware/mysql/01 第 2 节）。ClickHouse：主键是稀疏索引，二分只能定位到 8192 行的 granule，然后要解压该 granule 各列的压缩块、扫过最多 8192 行才找到目标——单行点查的解压与扫描成本高几个数量级。反转场景：按主键前缀做大范围扫描并聚合（"某类事件全天的 count/sum"），列存只读 2~3 列 + 压缩块顺序读 + 向量化，B+ 树要把整行读进来且随机 IO，CH 快 1~2 个数量级。本质：行存优化"到一行的路径"，列存优化"过一批列的吞吐"。
</details>

2. 描述 "too many parts" 从 ClickHouse 一路传导到 Kafka lag 的完整因果链，并给出四层各自的治理动作。
<details><summary>答案</summary>

链：小 INSERT 频率 > merge 消化速度 → 分区 parts 数上涨 → 超软阈值写入被 delay、超硬阈值（parts_to_throw_insert）INSERT 报 Too many parts → 写入端阻塞 → Flink sink 反压 → 算子吞吐下降、checkpoint 超时变慢 → source 不再推进 offset → Kafka 消费组 lag 上涨。四层治理：CH 层攒批（万行/MB 级一次写入）、开 async_insert 收编小写入方、必要时扩 background_pool/磁盘能力；Flink 层检查 sink 攒批参数与 checkpoint 间隔的配合；Kafka 层确认 lag 是消费停滞而非分区不均；架构层明确"明细批量导入 + 报表预聚合"分层，不在热点表上做高频小写。与 Doris too many versions（05 章第 6.2 节）逐层同构。
</details>

3. ClickHouse 把复制做成表引擎级（ReplicatedMergeTree），Doris 做成集群级（FE 调度 tablet 副本）。各自的运维推论是什么？
<details><summary>答案</summary>

表引擎级：灵活性高——每张表独立选分片数/副本数/引擎组合，明细表 2 副本、中间表 1 副本各取所需；代价是元信息分散在建表 DDL 里，"集群长什么样"要靠配置与 macros 重建心智，副本故障修复要运维盯 system.replicas 队列，无自动均衡与自动 clone。集群级：FE 统一持有 tablet 副本位置，BE 掉线自动 clone 补齐、扩容自动均衡，运维面集中；代价是所有表共享同一套副本策略空间，且 FE 元数据层成为需要 HA 与备份纪律的组件（对照 etcd）。一句话：CH 把架构决策下放给每张表，Doris 把它上收到集群——前者要更强的表设计纪律，后者要更认真的控制面运维。
</details>

4. Flink 作业恢复后重发了一批刚写过的数据，ClickHouse 和 Doris 各靠什么机制避免重复？两个机制的"窗口"分别指什么？
<details><summary>答案</summary>

Doris：label 幂等（05 章第 5 节）——导入显式带 label，重复 label 在保留期内（默认约 3 天）被拒，At-Most-Once 防重，正确姿势是恢复后用新 label 重发、靠 Unique 模型 REPLACE 收敛数据。ClickHouse：副本表的 block 哈希去重——完全相同的 block（相同行、相同顺序）在 replicated_dedup_window 记录的近 N 个块内被丢弃，无需业务显式声明；窗口指只记最近 N 个块哈希（默认千级，以文档为准），窗口外或 block 内容有微小差异（重放时行序变化）就不去重。工程结论：两者都只覆盖"快速重发同批数据"，跨窗口/变序的业务级幂等都要靠键模型（Unique/Replacing+version）兜底——这是 14 模块"端到端 exactly-once 三前提"里 sink 侧的两种实现形态。
</details>

5. ZooKeeper/Keeper 集群整体宕机 10 分钟：副本表的写入、查询、后台 merge 分别发生什么？已有数据会丢吗？恢复后呢？
<details><summary>答案</summary>

写入：副本表失去复制协调，降级只读（system.replicas 的 is_readonly=1），INSERT 报错——但普通（非 Replicated）本地表不受影响，这正是"复制是表级属性"的直接体现。查询：本地扫描查询完全不受影响（数据在本地 part 里），跨 Distributed 的查询也只在涉及只读副本时受路由影响。merge：merge 领选与复制日志都走 ZK，全部停摆，parts 会因持续写入而堆积（若写入端还有非 Replicated 路径或上游重试）。数据不丢：业务数据在 part 文件里，ZK/Keeper 只存协调状态（06 章第 1 节"协调服务，不是存储服务"）。恢复后：副本重连、is_readonly 解除，离线期间的写入由复制日志/队列追平，merge 领选恢复、parts 回落。运维动作：这 10 分钟内别动表结构、别手动删 part，恢复后盯 system.replicas 队列深度与 MaxPartCountForPartition。
</details>

## 延伸阅读

- ClickHouse 官方文档（MergeTree 引擎族与表引擎总览）：https://clickhouse.com/docs/engines/table-engines/mergetree-family
- 官方文档（Replication 与 Sharding：zk_path/macros/Distributed 语义）：https://clickhouse.com/docs/architecture/horizontal-scaling
- 官方文档（主键/稀疏索引与跳数索引）：https://clickhouse.com/docs/best-practices/sparse-primary-indexes
- 官方文档（INSERT 批量与 too many parts 调优）：https://clickhouse.com/docs/optimize/asynchronous-inserts
- 官方文档（system 表与监控/Prometheus 端点）：https://clickhouse.com/docs/operations/monitoring
- 官方文档（Backup and Restore：FREEZE 与 BACKUP/RESTORE）：https://clickhouse.com/docs/operations/backup
- ClickHouse Keeper（替代 ZK 的内置协调组件，06 章第 5 节的展开）：https://clickhouse.com/docs/guides/sre/keeper/clickhouse-keeper
- clickhouse-backup（社区备份工具官方仓库）：https://github.com/Altinity/clickhouse-backup
