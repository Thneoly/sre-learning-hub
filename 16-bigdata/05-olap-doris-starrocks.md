# 05 · OLAP 实时分析：Doris 与 StarRocks 的架构、模型与运维

> 模块：16-bigdata ｜ 建议时长：4 小时 ｜ 关联认证：—（CKA/CKS/PCA 无直接考点；PCA 的 exporter/PromQL 方法直接复用于 FE/BE 监控，Docker 部署复用 03 模块网络知识；本章是 labs/03-doris-quickstart 的理论底座）

## 学习目标

- 能解释 OLAP 与 OLTP、流处理的负载差异，回答"报表为什么不放在 MySQL 上跑、也不放进 Flink 里算"
- 能画出 FE/BE 分工图并跟踪一条 SQL 的执行路径（解析 → CBO 规划 → tablet 路由 → MPP 扫描 → 汇聚）
- 能区分 Duplicate/Aggregate/Unique 三种模型的语义与读写代价，说出 rollup 的加速原理与代价
- 能从 SRE 视角讲清四件事：FE 元数据与 Leader 选举、BE 磁盘与 compaction、查询排队与资源隔离、监控指标
- 能对比 Doris / StarRocks / ClickHouse 的选型差异，并按 12 模块的 exactly-once 框架布置 Flink → Doris 导入链路

版本约定：Apache Doris 2.x、StarRocks 3.x。两个项目小版本迭代快（向量化、存算分离、merge-on-write 默认值都随版本变），凡涉及"默认值/是否默认开启"的细节以官方文档为准，本文不写死小版本号。

## 1. 为什么 OLAP 单独一列：负载形态决定架构

前面几章已经覆盖了"存"（HDFS）与"批算"（Hive/Spark），12 模块覆盖了"流算"（Kafka/Flink）。还缺最后一环：**人要看的报表与多维分析**。它和前几种负载的形状完全不同：

| 维度 | OLTP（MySQL，11 模块） | 流处理（Flink，12 模块） | OLAP（Doris/StarRocks） |
|---|---|---|---|
| 典型请求 | 按 key 点查、小事务 | 预定义逻辑的持续计算 | 任意 SQL：大扫描 + 多维聚合 + 多表 join |
| 延迟目标 | 个位毫秒 | 事件时延毫秒~秒 | 百毫秒~几十秒（人可接受） |
| 扫描量 | 几行~几页 | 增量窗口 | GB~TB 级全量/分区裁剪扫描 |
| 读模式 | B+ 树随机读 | 不支持即席查询 | 列式扫描（只读用到的列） |
| 写模式 | 随机写、原地更新 | 追加（Kafka 日志） | 微批追加 + 后台合并（compaction） |
| 并发模型 | 高并发低代价查询 | 固定拓扑并行 | 每条查询临时组一个 MPP 并行计划 |

为什么不能拿交易库直接跑报表（排障视角，见 11-middleware/mysql/03-tuning-troubleshooting.md 的慢查询分型）：

1. **存储结构反着来**：InnoDB 是行存 B+ 树，为点查设计；`SELECT 城市, SUM(金额) FROM 订单 WHERE dt='2026-08-30' GROUP BY 城市` 要扫全表大部分行，而行存会把用不到的列也读进来。分析查询往往只用 5~10 列，列存能少读一个数量级的数据。
2. **互相伤害**：一次大扫描把 buffer pool 里的热点交易页全部挤出去，交易查询延迟抖动；反过来长报表又占用行锁和 undo 链路，拖垮主从复制。
3. **没有"预聚合"这一层**：OLAP 引擎可以用 Aggregate 模型/物化视图把"亿级明细"在写入时收敛成"百万级聚合行"，MySQL 没有等价机制。

为什么也不该把报表塞进 Flink（见 12-data-streaming/flink/01-stream-processing-model.md）：

1. Flink 的算子拓扑是**预先定义**的，改口径 = 改代码 + 重启作业 + 状态迁移；报表要的是"任意维度、随时可查"的即席（ad-hoc）能力。
2. Flink 状态按 key 分片存放、保留有限，**明细回溯**（"把三个月前的数据按新口径重新切一遍"）不是它擅长的。
3. 多表关联分析需要 CBO（基于代价的优化器）在 join 顺序/broadcast/shuffle 之间现场决策，流引擎的优化目标是持续吞吐，不是交互式查询延迟。

所以业界标准链路是"**流处理负责实时加工，OLAP 负责可查**"：

```
业务库(MySQL) ──CDC──┐
                    ├──► Kafka ──► Flink(清洗/维度补齐) ──► Doris/StarRocks ◄── BI 报表/即席查询
日志/埋点 ───────────┘                                        ▲
Spark/Hive 批加工 ──► HDFS / Iceberg 湖 ────────────────────────┘（外表湖查询，见第 7 节）
```

## 2. MPP 架构：FE 管元数据与规划，BE 管存储与执行

Doris 与 StarRocks 的集群形态同源，都是 **FE（Frontend）+ BE（Backend）** 两类进程：

```
                     ┌─────────────────────────────────────┐
  mysql client ────► │ FE leader   解析/优化/规划/元数据写入   │ ◄── 元数据：库表定义、tablet 位置、
   (9030, MySQL 协议) │ FE follower × n（偶数不行，过半写）     │     导入事务、账号权限
                     │ FE observer（只读副本，扩展查询接入）    │
                     └──────────────┬──────────────────────┘
                                    │ 执行计划下推：scan/agg 分发到数据所在 BE
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
        ┌───────────┐         ┌───────────┐         ┌───────────┐
        │ BE-1      │  副本   │ BE-2      │  副本   │ BE-3      │   列存本地盘、compaction、
        │ tablet×N  │◄──────►│ tablet×N  │◄──────►│ tablet×N  │   副本自修复、Stream Load 接收
        └───────────┘         └───────────┘         └───────────┘
              8040(HTTP/导入)   9050(心跳)   9060(Thrift)  8060(bRPC)
```

一条 SQL 的完整路径，以及每一步出问题时的排障入口：

```
① 客户端经 9030 连任一 FE（MySQL 协议）          → 连不上：查 FE 存活/连接数
② FE 解析 SQL → 语法/语义分析                    → 报错：表不存在/列歧义
③ FE 查元数据做 CBO：join 顺序、分区裁剪、        → 慢查询：EXPLAIN 看 plan 是否裁剪了分区、
   rollup/MV 命中、colocate join                   是否走了不该有的 shuffle join
④ FE 把计划切成 fragment，按 tablet 位置下发 BE    → BE 挂了：FE 心跳 9050 失联，查询改路由
⑤ 各 BE 本地列存扫描 + 局部聚合，MPP shuffle      → 数据倾斜：某 BE 扫描量远超同侪
⑥ 结果汇聚回 FE 返回                             → 大结果集：FE 内存压力
```

**tablet 是整个架构的"细胞"**。表 → 分区（partition）→ 分桶（bucket）→ tablet，tablet 再多副本：

```
table events
 ├─ partition p20260830            ← 分区：管理/裁剪单位，删旧分区 = 秒级释放空间
 │   ├─ bucket 0 → tablet 10010   （3 副本：BE1 / BE2 / BE3）
 │   ├─ bucket 1 → tablet 10011   （3 副本：BE2 / BE3 / BE1）   ← 副本错开落盘
 │   └─ bucket 2 → tablet 10012
 └─ partition p20260831 ...
```

- **分区**按时间切（Range/List），查询带分区条件时直接跳过整个分区；数据生命周期管理靠"删分区"而不是"删行"。
- **分桶**按 hash(桶键) 把数据打散，桶数 = 单分区内查询并行度上限；桶键选高频过滤/ join 键可减少 shuffle。
- **副本**默认 3 份落在不同 BE（本质是不同机器），BE 掉线后 FE 的副本调度器自动从健康副本 clone 补齐——这一套和 Kafka 的 ISR 思路一致但粒度不同：Kafka 副本单位是分区，Doris 是 tablet，粒度细得多，所以均衡与修复也快得多（对照 12-data-streaming/kafka/02-replication-and-reliability.md）。
- **colocate group**：把一组表的相同序号 bucket 固定落在同一批 BE 上，两表 join 时同序号 tablet 数据物理同机，join 免 shuffle（colocate join）。代价是这组表的扩容/均衡被锁死在一起，属于"用运维灵活性换查询性能"的显式权衡。

和 K8s 对照着记：FE 元数据层 ≈ etcd（过半写、单 Leader）；BE ≈ 带本地盘的 worker 节点。区别是 FE 不直接管调度，BE 的数据是持久的本地状态，不能像 Pod 一样随意漂移。

## 3. 三种数据模型与 rollup：同一份存储，三种语义

Doris 建表必须选一种数据模型，它决定了"同一批数据落盘后算什么"：

| 模型 | 语义 | key 列作用 | 读/写代价 | 典型场景 |
|---|---|---|---|---|
| Duplicate（明细） | 一行就是一行，永不合并 | 仅决定排序（前缀过滤友好） | 写最便宜，读时聚合最贵 | 原始日志/明细留存、审计 |
| Aggregate（预聚合） | 同 key 行按聚合函数合并 | 聚合维度 | 写时预聚合（写放大），读便宜 | PV/UV、指标报表 |
| Unique（主键） | 同 key 后写覆盖先写 | 主键 | merge-on-write 写放大明显 | 实时 upsert 的画像/订单状态表 |

Aggregate 模型的 value 列必须声明聚合方式（SUM/MAX/MIN/REPLACE/BITMAP_UNION/HLL_UNION），合并发生在三个时机——导入 ETL 阶段先做一次局部聚合（写路径）、BE compaction 阶段把跨批次/跨版本的中间结果后台合并（见 6.2 节，compaction 不只压版本，也在合并 Aggregate 行）、查询阶段把剩余各版本/各 bucket 的中间结果再合并一次（读路径），即"多阶段聚合"。BITMAP_UNION/HLL_UNION 分别支撑精确/近似去重（count distinct），这是 MySQL 做不了的量级。

Unique 模型在 2.x 有两种实现，选型直接决定写入吞吐和点查延迟：

- **merge-on-read（MoR，旧默认）**：所有版本都落盘，查询时按主键合并。写便宜，读贵——主键点查也要现场合并多版本。
- **merge-on-write（MoW）**：写入时用 delete bitmap 直接标记打掉旧版本，读路径接近纯明细表。实时画像、按主键 upsert 的场景基本必选；代价是写放大与导入压力更敏感。配合 sequence 列可以声明"乱序到达时按谁的新旧为准"（版本/时间戳），避免晚到的旧数据把新状态盖回去。

**rollup 是挂在基表上的"预计算副本"**：以基表 key 的前缀列建一张更粗粒度的二级表，导入时同步写入（写放大换读加速），查询时优化器自动判断能否命中、对业务完全透明。例：基表 `AGGREGATE KEY(dt, city, user_id)` 加 rollup `(dt, city)`，按天按城市的报表直接扫小几个数量级的 rollup。2.x 之后又逐步补了同步物化视图、异步物化视图（定时刷新、可 join 多表），能力与 StarRocks 对齐，具体语法与限制以官方文档为准。

容量规划口诀：**明细层用 Duplicate + 按天分区（可删分区回收），报表层用 Aggregate/Unique + rollup**，两层各司其职，不要指望一张表既存全量明细又扛所有报表。

## 4. 同源分家史：Doris、StarRocks 与 ClickHouse 的三角

这段历史决定了三者"像在哪、不像在哪"：

```
Google Mesa 论文
      │  启发
      ▼
百度 Palo（报表 OLAP，大规模生产验证）
      │ 2018 进入 Apache 孵化器（项目名 Apache Doris）
      ▼
Apache Doris（社区版）──────────────► 2020 年核心团队出走创立镜舟科技，
2022 年毕业成 Apache 顶级项目          从 Doris fork 出 StarRocks（2021 开源），
向量化/CBO/湖仓能力在 1.2~2.x 补齐     版本号直接从 2.x 起跳，主打向量化执行 +
                                      CBO + 存算分离（3.x shared-data）
```

同源的后果：FE/BE 架构、MySQL 协议（9030）、三种数据模型、Stream Load 接口几乎同构，学会一个，另一个的上手成本主要是参数名差异。StarRocks 3.x 的差异点在 shared-data 存算分离（BE 之上加 CN 计算节点、数据下沉对象存储 + 本地缓存）与更成熟的资源隔离（resource group）；Doris 也在跟进存算分离与 workload group，成熟度以各自官方文档为准。

与 ClickHouse 的对比（选型高频题，也是"为什么大数据平台二选一"的答案）：

| 维度 | Doris / StarRocks | ClickHouse |
|---|---|---|
| 架构 | MPP，FE/BE 两类角色，元数据内嵌复制（无外部依赖） | 分片+副本对等架构，Replicated 表需要 ZooKeeper/Keeper 协调 |
| join | 强项：CBO + broadcast/shuffle/colocate 多表 join | 单表扫描极快，多表 join 历史短板（分布式 join 调优门槛高） |
| 实时更新 | Unique 模型真 upsert（MoW 秒级可见） | ReplacingMergeTree 后台异步合并去重，读时仍需处理；mutation 重写代价大 |
| 预聚合 | Aggregate 模型/rollup/MV 内建 | 物化视图可用，聚合引擎族丰富但组合调优偏专家向 |
| 运维复杂度 | 一套 FE/BE，扩容后自动均衡，MySQL 协议接入成本低 | 分片规划、distributed 表映射、ZK/Keeper 依赖、merge 调优，运维项更多 |
| 单表极限扫描 | 强 | 更强（向量化鼻祖，压缩比高，单表聚合性能标杆） |
| 生态 | 与国产 BI/数据平台集成多，湖查询（Iceberg/Hudi）一等公民 | 引擎/函数/表函数极其丰富，全球社区大 |

一句话选型：**单表海量日志聚合、追求极限吞吐选 ClickHouse；多表 join 的实时报表、湖仓一体、运维人手少选 Doris/StarRocks**。运维视角还要加一条：Doris/StarRocks 没有外部协调依赖（这正好呼应下一章 ZooKeeper 的退场趋势——ClickHouse 自己也用 Keeper 替代了 ZK）。

## 5. 导入通道：Stream Load 与 Flink Connector（串回 exactly-once）

Doris 的写入口是一组 HTTP 接口，最常用的是 **Stream Load**（本地文件/程序直推）与基于它的 Flink Connector：

```
curl ──HTTP PUT /api/{db}/{table}/_stream_load──► FE:8030 ──307 重定向──► BE:8040
                                                      │
                                                      ▼
                                   BE 接收数据 → 按 tablet 分桶 → 写本地列存 → 上报 FE
                                   FE 事务提交（label 记账）→ 返回 JSON（Status/Rows）
```

两个运维要点：

1. **label 是导入的幂等键**。每个导入必须带唯一 label（如 `flink_job_chk_42`），BE/FE 会记录已成功的 label；重复提交同一 label 直接返回 `Label Already Exists` 而不会写两遍。at-least-once 的上游（Flink checkpoint 恢复、Kafka 重放）全靠这层去重达到端到端 exactly-once。
2. **认证与重定向**。经 FE 8030 发起时 FE 会 307 重定向到某个 BE，curl 默认不透传 Authorization 头，要么加 `--location-trusted`，要么像下文实验一样直发 BE 8040。

**Flink Doris Connector** 的 exactly-once 与 12 模块 KafkaSink 两阶段提交同构（对照 12-data-streaming/flink/02-deployment-and-exactly-once.md#5. 端到端 exactly-once：三个前提缺一不可）：

```sql
-- [Flink SQL 客户端（连接方式同 12 模块 sql-client）]
CREATE TABLE doris_events (
  event_time TIMESTAMP,
  event_type STRING,
  user_id BIGINT,
  cost BIGINT
) WITH (
  'connector' = 'doris',
  'fenodes' = 'doris-fe:8030',
  'table.identifier' = 'demo.events',
  'username' = 'flink_writer',
  'password' = '******',
  'sink.enable-2pc' = 'true',          -- Stream Load 两阶段提交：先 precommit，checkpoint 完成后再 commit
  'sink.label-prefix' = 'flink-evt-'   -- label = 前缀 + subtask + checkpointId，天然幂等
);
```

三段缺一不可：**source 可重放**（Kafka offset 在 checkpoint 里）、**算子状态在 checkpoint**、**sink 两阶段提交**（数据先写进未提交事务，`notifyCheckpointComplete` 后才对查询可见）。这与 KafkaSink 的事务型 producer 是同一个模式，只是"事务"从 Kafka 的事务日志换成了 Doris 的 label precommit/commit。运维排障时的对应关系也一致：作业恢复后看到 `Label Already Exists` 是**正常的幂等表现**，不要去删 label"解决"它；真正要警惕的是 2PC 长时间不 commit 导致的导入事务堆积。

其它通道一句话带过：Routine Load 订阅 Kafka（省掉 Flink 的轻量管道）、Broker Load/Insert Into Select 拉外部存储、S3/OSS 导入、以及 2.x 的 Arrow Flight 高速通道——选型看上游在哪，运维看 label 与事务数。

## 6. 运维四件事：元数据、compaction、排队、监控

### 6.1 FE 元数据与 Leader 选举

FE 的元数据（库表定义、tablet 副本位置、账号、导入事务）存放在 `meta_dir`，结构与 MySQL 的"检查点 + 增量日志"一个思路：

```
doris-meta/
├── image/    ← 全量检查点（定期由 edits 生成，加速重启回放）
└── bdb/      ← 增量 edit log（BDBJE 组复制，写需 follower 过半确认）
```

- 角色：**FOLLOWER** 参与选主与过半写（部署 1/3/5 个，奇数）；**OBSERVER** 只回放元数据、可服务查询，用于扩展读与跨机房接入，不增加写 quorum。
- Leader（旧称 Master）挂掉：follower 多数派重新选主，期间**新建表/导入提交等元数据写操作阻塞**，已提交数据的查询会因路由缓存短暂报错后恢复——所以 FE 也要至少 3 节点，别省。
- 扩 FE：`ALTER SYSTEM ADD FOLLOWER "fe2:9010"` / `ADD OBSERVER`；`SHOW FRONTENDS` 看 `Role/IsMaster/Alive/ReplayedJournalId`。
- 备份：`image` 目录 + 定期 `BACKUP` 元数据是重建集群的底线，bdb 目录损坏等于元数据丢失，必须当有状态系统对待（同 etcd 的备份纪律）。

### 6.2 BE 磁盘与 compaction

- 每个 BE 用 `storage_root_path` 挂多块盘（可带 `medium:ssd/hdd` 介质标签，冷热分层靠它），tablet 副本在盘间均衡；磁盘满的表现是导入报错而查询继续，所以容量告警要打到"分区级增长速率"而不只是盘使用率。
- 写入是"追加 rowset 版本"：每次导入给 tablet 增加一个版本，后台 **cumulative compaction**（小版本逐级合并）与 **base compaction**（全量重写、处理 delete 条件）把版本压回去——对 Aggregate 模型，这一步也是第 3 节三阶段聚合里的"compaction 阶段"：跨批次的中间聚合结果在这里被合并掉，查询要合并的版本因此变少。compaction 跟不上的连锁反应：版本数堆积 → 写入被拒（too many versions）→ 上游 Flink 反压 → Kafka lag（一路串回 12 模块的排障链）。高频小批量导入是头号元凶，治本是攒批。
- 副本自修复：BE 心跳失联后 FE 从健康副本 clone 补齐，`SHOW PROC '/cluster_health/tablet_health'` 与 `SHOW PROC '/cluster_balance'` 是健康度入口（具体 PROC 路径以版本文档为准）。

### 6.3 查询排队与资源隔离

- 导入侧：FE 对每个库的**并发导入事务数**有上限（label 提交排队），大批量回刷前要评估；`SHOW TRANSACTION`/`SHOW PROCESSLIST` 是排障入口。
- 查询侧：大报表会吃满 BE CPU/内存，把线上小查询拖死。手段按版本递进：**资源标签**（给 BE 打 `tag.location`，把报表表固定到独立机器组，物理隔离最彻底）→ **workload group**（2.1+，按查询来源限 CPU/内存/并发，语法以官方文档为准）→ StarRocks 的 **resource group**（classifier 匹配查询分流）。选型逻辑与 Nginx/K8s 的 resource quota 一致：先物理隔离租户，再做软限流。
- 慢查询三板斧：`EXPLAIN`（分区裁剪/rollup 命中/shuffle join）→ 查询 profile（各 fragment 耗时）→ `SHOW PROCESSLIST` + FE 日志（是否排队）。

### 6.4 监控：FE/BE 都自带 Prometheus 端点

FE `http://fe:8030/metrics`、BE `http://be:8040/metrics`，直接接入 08 模块的抓取体系（08-pca/04-instrumentation-exporters.md 的接入方式原样适用）。指标名随版本微调，以端点实际输出为准：

| 关注点 | 指标（示例） | 告警思路 |
|---|---|---|
| 查询延迟 | `doris_fe_query_latency_ms`（直方图） | `histogram_quantile(0.95, sum by (le) (rate(doris_fe_query_latency_ms_bucket[5m])))` |
| 查询吞吐/错误 | `doris_fe_query_qps`、查询错误计数 | 错误率突增 + FE 日志 |
| BE 内存 | `doris_be_memory_allocated` 等 | 逼近 mem_limit 需扩容或降并发 |
| compaction 压力 | `doris_be_compaction_cumulative_compaction_score`、`..._base_compaction_score` | 持续上升 = 合并跟不上导入（见 6.2） |
| tablet 健康 | unhealthy tablet 数（PROC/metrics） | > 0 立即介入 |
| 导入事务 | running txn 数 | 接近上限 → 查 label 堆积/2PC 未提交 |

## 7. 湖查询与湖仓一体的运维视角

第 3 章的 Hive 数仓查询慢，2.x 起的解法是**多目录（Multi-Catalog）**：Doris/StarRocks 作为统一查询入口，内表（热数据在本地列存）+ 外表（Iceberg/Hudi/Hive/JDBC catalog）一套 SQL 混查：

```sql
-- [Doris MySQL 协议入口：mysql -h<fe地址> -P9030 -uroot]
CREATE CATALOG iceberg PROPERTIES (
  "type" = "iceberg",
  "iceberg.catalog.type" = "hive",
  "hive.metastore.uris" = "thrift://172.30.30.21:9083"
);
SET catalog iceberg;
SELECT ... FROM iceberg_db.events WHERE dt = '2026-08-29';   -- 引擎下推扫描湖上文件
```

湖仓一体对 SRE 的含义是把故障域拉长了，排障要沿链路看：

1. **metastore 成了新依赖**：HMS 挂了 catalog 全部不可用——它本身就是下一章 ZooKeeper 的典型租户，监控要连坐。
2. **对象存储的脾气**：S3/OSS 的限流（SlowDown/503）与首包延迟直接进查询 p99；本地 file cache 命中率是核心指标，冷数据首次扫描必然慢。
3. **小文件与分区裁剪**：Spark 写湖产生的小文件让扫描请求数爆炸（又是 compaction 故事的重演，只是发生在湖上，要靠 Spark 侧合并）；查询没带分区条件 = 全湖扫描，要在 BI 层加约束。
4. **热冷分层策略**：近 N 天热数据在 Doris 内表（本地列存 + rollup），历史明细留在湖（廉价存储 + 按需扫描），"删热保冷"靠分区自动滚动——这是容量成本的主要优化杠杆。

## 实战演练

环境：装有 Docker 的 Ubuntu VM。镜像 tag 说明：Docker Hub `apache/doris` 上 2.x 时代 tag 形如 `2.1.x-fe-x86_64` / `2.1.x-be-x86_64`，新版本改为 `fe-<版本>` / `be-<版本>` 多架构 tag，以 tag 列表为准（ARM 机器选 aarch64/多架构 tag）。

```bash
# [任意节点] BE 需要的内核参数（宿主机执行；容器共享内核 sysctl，对照 01-linux 模块）
sudo sysctl -w vm.max_map_count=2000000
```

```bash
# [任意节点] 建 docker 网络并起 FE（容器名即集群内主机名，见 03-docker/03-container-networking.md）
docker network create doris-net
docker run -itd --name doris-fe --network doris-net \
  -p 8030:8030 -p 9030:9030 \
  -e FE_SERVERS="fe1:doris-fe:9010" -e FE_ID=1 \
  apache/doris:2.1.0-fe-x86_64

# [任意节点] 约 30 秒后起 BE（镜像入口脚本会按 BE_ADDR 自动向 FE 注册）
docker run -itd --name doris-be --network doris-net \
  -p 8040:8040 --ulimit nofile=1000000:1000000 \
  -e FE_SERVERS="fe1:doris-fe:9010" -e BE_ADDR="doris-be:9050" \
  apache/doris:2.1.0-be-x86_64
```

```bash
# [任意节点] 用一次性 mysql 容器连 FE 的 9030（MySQL 协议），核对 FE/BE 状态
docker run --rm --network host mysql:8 \
  mysql -h127.0.0.1 -P9030 -uroot -e "SHOW FRONTENDS\G"
# 预期：Role=FOLLOWER、IsMaster=true、Alive=true

docker run --rm --network host mysql:8 \
  mysql -h127.0.0.1 -P9030 -uroot -e "SHOW BACKENDS\G"
# 预期：Alive=true。若一直 false：docker logs doris-be；必要时手动
# ALTER SYSTEM ADD BACKEND "doris-be:9050"（已自动注册时会报已存在，属预期）
```

```bash
# [任意节点] 建三种模型的表（单 BE 演示环境必须 replication_num=1，生产禁用）
docker run --rm -i --network host mysql:8 \
  mysql -h127.0.0.1 -P9030 -uroot <<'SQL'
CREATE DATABASE IF NOT EXISTS demo;
USE demo;

CREATE TABLE events (                        -- Duplicate：明细
  event_time DATETIME NOT NULL,
  event_type VARCHAR(32) NOT NULL,
  user_id BIGINT NOT NULL,
  cost INT DEFAULT '0'
) DUPLICATE KEY(event_time, event_type)
PARTITION BY RANGE(event_time) (
  PARTITION p0829 VALUES LESS THAN ("2026-08-30 00:00:00"),
  PARTITION p0830 VALUES LESS THAN ("2026-09-01 00:00:00")
) DISTRIBUTED BY HASH(user_id) BUCKETS 4
PROPERTIES ("replication_num" = "1");

CREATE TABLE agg_user_cost (                 -- Aggregate：预聚合
  stat_date DATE NOT NULL,
  event_type VARCHAR(32) NOT NULL,
  user_id BIGINT NOT NULL,
  pv BIGINT SUM DEFAULT '0',
  cost BIGINT SUM DEFAULT '0'
) AGGREGATE KEY(stat_date, event_type, user_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 4
PROPERTIES ("replication_num" = "1");

CREATE TABLE user_profile (                  -- Unique：主键 upsert（merge-on-write）
  user_id BIGINT NOT NULL,
  user_name VARCHAR(64),
  balance DECIMAL(18,2) DEFAULT '0',
  updated_at DATETIME
) UNIQUE KEY(user_id)
DISTRIBUTED BY HASH(user_id) BUCKETS 4
PROPERTIES ("replication_num" = "1",
            "enable_unique_key_merge_on_write" = "true");
SQL
```

```bash
# [任意节点] 验证三种模型的语义差异
docker run --rm -i --network host mysql:8 \
  mysql -h127.0.0.1 -P9030 -uroot <<'SQL'
USE demo;
INSERT INTO agg_user_cost VALUES
 ('2026-08-30','click',1001,3,30),
 ('2026-08-30','click',1001,2,20),   -- 同 key：合并成 pv=5,cost=50
 ('2026-08-30','click',1002,1,10);
SELECT * FROM agg_user_cost ORDER BY user_id;

INSERT INTO user_profile VALUES (1001,'alice',100.00,'2026-08-30 10:00:00');
INSERT INTO user_profile VALUES (1001,'alice', 80.00,'2026-08-30 10:05:00');
SELECT * FROM user_profile;          -- 只有一行，balance=80（后写覆盖）

ALTER TABLE agg_user_cost ADD ROLLUP r_date_type(stat_date, event_type, pv, cost);
SHOW ALTER TABLE ROLLUP;             -- 等 state 变 FINISHED
EXPLAIN SELECT stat_date, SUM(pv) FROM agg_user_cost GROUP BY stat_date;
-- 预期：EXPLAIN 的 rollup 行显示 r_date_type（查询自动命中预聚合副本）

SHOW PARTITIONS FROM events;
ADMIN SHOW REPLICA DISTRIBUTION FROM events;   -- 4 个 bucket 的副本分布
SHOW DATA FROM events;
SQL
```

```bash
# [任意节点] Stream Load：写入明细表并验证 label 幂等（直发 BE 8040，避开 307 重定向）
cat > /tmp/events.csv <<'EOF'
2026-08-30 10:00:01,click,1001,3
2026-08-30 10:00:02,click,1002,1
2026-08-30 10:00:05,view,1001,0
2026-08-30 10:01:00,click,1003,2
2026-08-30 10:02:00,view,1002,0
2026-08-30 10:03:00,buy,1001,50
2026-08-30 11:00:00,view,1003,0
2026-08-30 11:05:00,buy,1002,30
EOF
curl -u root: -X PUT -T /tmp/events.csv \
  -H "Expect:100-continue" -H "label:lab_evt_001" -H "column_separator:," \
  http://127.0.0.1:8040/api/demo/events/_stream_load
# 预期 JSON：Status=Success、NumberLoadedRows=8

# 用同一个 label 重放（模拟 Flink 恢复重发）：
curl -u root: -X PUT -T /tmp/events.csv \
  -H "Expect:100-continue" -H "label:lab_evt_001" -H "column_separator:," \
  http://127.0.0.1:8040/api/demo/events/_stream_load
# 预期：Status=Label Already Exists —— exactly-once 的落点，表里仍是 8 行
```

```bash
# [任意节点] compaction：每次导入 = tablet 一个新版本，连续导入后看合并压力
for i in 2 3 4 5 6; do
  curl -s -o /dev/null -u root: -X PUT -T /tmp/events.csv \
    -H "Expect:100-continue" -H "label:lab_evt_00$i" -H "column_separator:," \
    http://127.0.0.1:8040/api/demo/events/_stream_load
done
curl -s http://127.0.0.1:8040/metrics | grep -E 'compaction.*score' | head -4
# 预期：cumulative/base compaction score 两个 gauge（指标名随版本略有差异，以输出为准）

# FE 元数据布局：image(检查点) + bdb(增量日志)
docker exec doris-fe ls /opt/apache-doris/fe/doris-meta
docker exec doris-fe ls /opt/apache-doris/fe/doris-meta/image
# 预期：目录 bdb/ 与 image/，image 内有 image.ckpt 等文件
```

验证方法：三种模型的 SELECT 输出与注释一致；重复 label 后 `SELECT COUNT(*) FROM demo.events` 仍为 8；`SHOW FRONTENDS` 中 IsMaster=true。做完清理：`docker rm -f doris-fe doris-be && docker network rm doris-net`。多节点部署与监控接入的完整版见 labs/03-doris-quickstart。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 建表报 not enough backends / 副本不足 | 默认 `replication_num=3`，实验环境 BE 数不够 | 实验表显式 `"replication_num"="1"`；生产扩 BE 而不是降副本 |
| BE 注册后 Alive=false | 宿主机 `vm.max_map_count` 太低、ulimit 不够、FE/BE 网络不通 | `docker logs doris-be`；宿主机调 `vm.max_map_count=2000000`；核对 FE_SERVERS/BE_ADDR |
| Stream Load 经 8030 报 307 或 401 | FE 重定向到 BE，curl 不透传认证 | 直发 BE 8040，或 `curl --location-trusted` |
| 恢复重放时大量 Label Already Exists | 2PC/label 幂等的**正常表现** | 确认 label 前缀 + checkpointId 生成规则即可，不要删 label |
| 导入报 too many versions / compaction score 持续高 | 高频小批量导入，版本数超过合并能力 | 攒大批次、降导入频率；评估 compaction 线程（以文档为准） |
| 报表把线上查询拖死 | 大查询与线上查询共享 BE，无隔离 | 资源标签分组 / workload group 限流；大回刷错峰 |
| 湖外表查询偶发超时 | 对象存储限流或 file cache 冷 | 看 scan 指标与对象存储 5xx/429；预热缓存或加分区条件 |
| FE 全部重启后起不来 | bdb 元数据损坏/过半丢失 | 从 image 检查点 + 备份恢复；FE 也要当有状态系统做备份 |

## 自测

1. 同一份订单数据，"审计明细留存"和"实时余额查询"分别该用哪种模型？如果把实时余额表从 MoW 换成 MoR，写入吞吐和点查延迟各怎么变？
<details><summary>答案</summary>

明细留存用 Duplicate（写最便宜、永不合并、可随时按新口径重算）；实时余额用 Unique + merge-on-write（主键 upsert，读路径无合并、点查快）。MoW→MoR：写入变便宜（不用写时打 delete bitmap，写放大下降，吞吐上升），但每次查询都要现场按主键合并多版本，点查与范围查都显著变慢——本质是把合并成本从写路径挪到读路径，按"写多读少还是读多写少"选。
</details>

2. compaction 长期跟不上，会在 Doris、Flink、Kafka 三层分别看到什么现象？治理动作是什么？
<details><summary>答案</summary>

Doris 层：compaction score 持续升高，tablet 版本数堆积，最终写入被拒（too many versions）；导入事务排队、label 提交变慢。Flink 层：sink 写入变慢 → 算子反压 → checkpoint 变慢/超时（backPressured 指标顶满，见 12 模块反压定位法）。Kafka 层：source 消费停滞，消费组 lag 直线上扬。治理：降低导入频次、攒大批次（减少版本产生速度）；清理不必要的小表导入任务；评估调大 compaction 线程/磁盘能力；根治是"明细 Duplicate + 报表 Aggregate"分层，避免高频小导入。
</details>

3. FE Leader 宕机的 30 秒里，哪些操作失败、哪些照常？为什么生产要求至少 3 个 FOLLOWER 而 OBSERVER 不能算数？
<details><summary>答案</summary>

失败：所有需要写元数据的操作——建表/删表、导入事务提交（新数据不可见）、权限变更。照常：已提交数据的查询（follower/observer 可规划只读查询），但有短暂路由抖动。FOLLOWER 构成元数据写的过半多数派，1 个 FOLLOWER 挂了剩 2/3 仍过半；OBSERVER 不参与选举与 quorum，挂再多也不提升可用性——这与 Kafka ISR 的多数派、K8s etcd 的 quorum 是同一条数学约束：过半机制容忍 (n-1)/2 个故障，偶数节点不增加容错只增加写延迟。
</details>

4. Flink→Doris 与 Flink→KafkaSink 的 exactly-once 机制有何同构性？"事务"分别由什么实现？
<details><summary>答案</summary>

同构：都依赖三前提——source 可重放（Kafka offset 在 checkpoint）、算子状态随 checkpoint 持久化、sink 两阶段提交（先写不可见数据，checkpoint 完成 notifyCheckpointComplete 后统一 commit）。差异在"事务"载体：KafkaSink 用 broker 的事务日志（transactional.id + PID），读端要 `isolation.level=read_committed`；Doris Connector 用 Stream Load 2PC（label 的 precommit/commit），未 commit 的导入对外不可见。两者的幂等键分别是 (PID, epoch) 与 label（前缀+subtask+checkpointId）。
</details>

5. 业务要"按城市+日期的秒级报表"，明细每天 10 亿行。只建一张 Duplicate 明细表直接 GROUP BY 会发生什么？给出分层建表方案。
<details><summary>答案</summary>

每次查询全量扫描 10 亿行明细做聚合，秒级响应无从谈起，且并发几个报表就把 BE CPU/IO 打满、拖垮其他查询。分层方案：Duplicate 明细表按天分区（留存与回算用）；Aggregate 表 AGGREGATE KEY(dt, city) 带 pv/cost SUM（写入时预聚合，行数从 10 亿降到百万级）；再按查询热度加 rollup（如 (dt, city, channel)）；高频口径用异步物化视图。查询走 rollup/MV 命中，历史分区直接删除释放空间。
</details>

## 延伸阅读

- Apache Doris 官方文档（数据模型/导入/监控各章）：https://doris.apache.org/docs/
- StarRocks 官方文档（存算分离、resource group、湖分析）：https://starrocks.io/docs/
- Doris Flink Connector（2PC 与 label 参数）：https://github.com/apache/doris-flink-connector
- ClickHouse 官方文档（对照 MergeTree 家族与 Keeper）：https://clickhouse.com/docs/
- Apache Iceberg 文档（表格式与 metastore 依赖）：https://iceberg.apache.org/docs/latest/
- Apache Hudi 文档：https://hudi.apache.org/docs/overview/
