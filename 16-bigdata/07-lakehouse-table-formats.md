# 07 · 湖仓表格式深讲：Iceberg、Hudi、Paimon 与湖上运维

> 模块：16-bigdata ｜ 建议时长：4 小时 ｜ 关联认证：—（CKA/CKS/PCA 无直接考点；本章是 00 章第 2 节三巨头速览表的展开，也是 05 章第 7 节湖查询的上游视角；动手部署在 labs/04-lakehouse-flink-paimon）

## 学习目标

- 能说出对象存储裸文件堆的四个缺陷，解释"表格式"这层加了什么语义、把状态放到了哪里
- 能画出 Iceberg 的 metadata 四层树（metadata.json → manifest list → manifest → data file），并沿树解释一次 snapshot commit 的原子性来自哪里
- 能用写放大/读放大的语言对比 Hudi 的 COW 与 MOR，说清 Paimon 主键表 LSM 与 changelog 三种产生方式的取舍，并按更新频率/查询延迟/入湖引擎/生态完成选型
- 能落地湖上运维四件事：小文件治理、snapshot/manifest 膨胀监控、schema 演进兼容规则、catalog 与权限体系

版本约定：Iceberg 1.x、Hudi 0.14.x / 1.x、Paimon 1.x。三者迭代都快（Hudi 1.x 重构了 timeline 与文件布局，Paimon 配置名随版本微调），凡涉及具体配置名与默认值处以官方文档为准。

## 1. 为什么需要表格式：对象存储裸文件的四个缺陷

01 章讲过 HDFS 是"一个命名空间"，05 章讲过 Doris 直查湖上文件，但存储本身只给了你**一堆不可变文件 + 目录前缀**——直接把 Parquet 堆上去当表用，会撞上四件事：

| # | 缺陷 | 具体表现 |
|---|---|---|
| 1 | 无事务 | 两个作业同时写一张表，读者可能看到"写了一半"的文件集合，没有原子提交点 |
| 2 | 不能 upsert | 对象存储没有原地修改；改一行只能整文件重写，或自己维护"新版本文件 + 合并逻辑" |
| 3 | 无 schema 保护 | 文件里的列结构没人管：上游改列，下游读到一半才炸；新旧文件混读全靠自觉对齐 |
| 4 | 改数据 = 覆盖 | 回刷/修数要么 mv 目录（对象存储没有原子 rename），要么整目录覆盖，出错即事故 |

Hive 时代用"metastore 管元数据 + 目录约定"（`16-bigdata/03-hive-warehouse.md` 第 2/5 节）回答这四个问题，Hive ACID（03 章第 7 节）试图补事务但绑死引擎。表格式（table format）把这层语义**标准化、引擎无关化**：

```
     Spark          Flink          Trino          Doris/StarRocks
       │              │              │                  │
       └──────────────┴──────┬───────┴──────────────────┘
                            ▼
        ┌──────────────────────────────────────────┐
        │ 表语义层（本章主角，三个实现：Iceberg/Hudi/Paimon）│
        │  ACID 事务 / snapshot 隔离 / schema 演进      │
        │  增量读取 / time travel / 不可变小文件元数据    │
        └─────────────────────┬────────────────────┘
                              ▼
                 HDFS / 对象存储（S3/OSS/Ozone）
                 只负责"存住字节"，不懂表为何物
```

对 SRE 的关键认知：这一层**没有常驻进程**——状态全部落在存储上的元数据文件与 catalog 里，运维对象是**文件（元数据膨胀）+ 作业（compaction 类后台任务）+ catalog（提交与寻址的原子性）**。这是 00 章第 3 节"每一代演进都在把状态从计算层剥离"的延续。

## 2. Iceberg：把表变成一棵元数据树

### 2.1 四层元数据树

Iceberg 的设计核心：**数据文件不可变，一切变更都体现为元数据文件的新版本**。四层自上而下读：

```
catalog（HMS / REST catalog / Nessie）
   │ 指针原子交换 ◄── 提交的原子性在"指向哪个 metadata.json"这一跳完成（见 2.4）
   ▼
metadata/00000-<uuid>.metadata.json   ① 元数据根：schema、分区规格、
metadata/00001-<uuid>.metadata.json      snapshot 列表、current-snapshot-id
   │ 按 current-snapshot-id 找到
   ▼
metadata/snap-<txid>-<uuid>.avro     ② manifest list（每个 snapshot 一份）：
   │ 列出本快照的全部 manifest，附每个 manifest 的分区范围摘要
   ▼
metadata/<idx>-<uuid>-m0.avro        ③ manifest（数据文件清单）：分区值、行数、
   │ 字节数、每列 min/max/null 计数
   ▼
data/dt=2026-08-30/00001-0-<uuid>.parquet   ④ 数据文件本体（Parquet/ORC/Avro）
```

查询计划就是沿树剪枝：① 取当前快照 → ② 用 manifest list 的分区范围摘要跳过无关 manifest → ③ 用列统计（min/max）跳过无关文件 → ④ 只扫命中文件。**过滤条件下推到了文件枚举层**——这就是分区裁剪 + 数据裁剪的来源，也是"文件越多计划越慢"的元数据成本。

### 2.2 snapshot 与 time travel

每次写产生一个新 snapshot，父指向前一个，链成提交历史；读永远是"某个 snapshot 的一致视图"——写了一半的文件对读者不存在，缺陷 1 就此补上。time travel 是同一机制的外推：读历史 snapshot 即回到任意提交时刻（Spark 的 `VERSION AS OF` / `TIMESTAMP AS OF`，或查元数据表）。**snapshot 不免费**：每个 snapshot 钉住它引用的数据文件，expire 之前不能删——这是 6.2 膨胀监控的根源。

### 2.3 隐藏分区

Hive 分区要求分区列是物理列、值复制进目录名（03 章第 5 节）。Iceberg 把分区变成元数据里的**派生函数**：`days(ts)`、`hours(ts)`、`bucket(64, user_id)`、`truncate(10, phone)`；查询写 `WHERE ts = ...`，引擎自动改写成分区谓词。业务表不必冗余 `dt` 列，也不会出现"分区目录与数据不一致"的脏数据。代价是排障直觉要换：**看 manifest 里的分区值，别信目录名**。

### 2.4 引擎中立的设计代价

Iceberg 不绑定任何引擎（Spark/Flink/Trino/Doris/StarRocks 都有实现），代价有二：

1. **提交原子性外包给 catalog**。对象存储没有"原子交换指针"（S3 连 rename 都没有），metadata.json 的新版本生效必须由 catalog 完成——HMS 表级锁、REST catalog 的 CAS、Glue/S3 Tables 的条件写。catalog 挂 = 写全部阻塞，湖链路的新单点（6.4 展开）。
2. **更新要走 delete 文件**。v2 用 position/equality delete 实现 upsert：写路径轻（追加 delete 文件），读路径要现场合并，equality delete 的读放大尤其大。**Iceberg 的 upsert 是"能做"，Hudi/Paimon 是"为它而生"**——选型矩阵里最硬的分界线。

### 2.5 运维关注：过期、manifest 压缩、小文件合并

三个动作全是提交侧作业，Iceberg 自己不跑后台服务，靠 procedure + 定时调度执行：

```sql
-- [Spark SQL 客户端（spark-sql 连到湖 catalog）] 运维四连
CALL lake.system.expire_snapshots(table => 'db.events', older_than => TIMESTAMP '2026-08-23 00:00:00', retain_last => 10);
CALL lake.system.rewrite_data_files(table => 'db.events', where => 'dt = ''2026-08-30''');
CALL lake.system.rewrite_manifests(table => 'db.events');
CALL lake.system.remove_orphan_files(table => 'db.events');
-- 过程名与参数随版本演进（早期 expire_snapshots 是 4 个位置参数），以官方文档为准
```

```sql
-- [Spark SQL 客户端] 在表属性里把元数据膨胀压在源头
ALTER TABLE lake.db.events SET TBLPROPERTIES (
  'write.target-file-size-bytes' = '134217728',          -- 128MB 目标文件，治小文件
  'write.metadata.previous-versions-max' = '100',         -- 保留的 metadata.json 份数
  'write.metadata.delete-after-commit.enabled' = 'true',  -- 提交后删旧 metadata.json（默认 false）
  'history.expire.max-snapshot-age-ms' = '432000000',    -- 快照最长保留 5 天
  'history.expire.min-snapshots-to-keep' = '10');
```

因果链：高频 checkpoint 写入 → snapshot 与小文件暴涨 → manifest 碎片化 → 计划变慢。`rewrite_data_files` 治小文件、`rewrite_manifests` 治清单碎片、`expire_snapshots` 释放被历史快照钉住的空间（只解除引用，孤儿文件靠 `remove_orphan_files` 兜底）。易混淆的 WAP（Write-Audit-Publish）：在 Spark 会话里设 `spark.wap.id`（旧版拼写是表属性 `write.wap.id`）后，写入只生成一个 staged snapshot、不推进 current snapshot；审计通过后**必须显式发布**——`CALL lake.system.publish_changes(table => 'db.events', wap_id => '...')`，或 `cherrypick_snapshot` / 分支模式 `fast_forward`。UNSET 属性只是停止暂存新写入，本身不发布、不推进 current snapshot。它与过期清理无关，别当清理参数配（发布过程语义以官方文档为准）。

## 3. Hudi：以 timeline 为中心的入湖格式

### 3.1 timeline / instant 模型

Hudi 把表上的所有事件——不只是数据写入，还包括后台服务——都记在 `.hoodie` 目录的一条**时间线**上。每个事件是一个 instant（`yyyyMMddHHmmss` 时间戳），状态机 requested → inflight → completed：

```
.hoodie/
  20260830101500.deltacommit.requested    ┐
  20260830101500.deltacommit.inflight     ├ MOR 一次增量写（只追加 log 文件）
  20260830101500.deltacommit.completed    ┘
  20260830100000.compaction.requested       10 点调度的合并计划（可能 18 点才执行）
  20260830100000.clean.completed            清理被取代的旧版本文件
  20260830090000.rollback.completed         失败写的回滚
```

timeline 是 Hudi 的单一事实源：增量消费按 instant 拉取、并发控制按 instant 排序、一致性视图由"已 completed 的最大 instant"决定——把 Kafka"日志即状态"的思路搬到了表的元数据上。

### 3.2 COW vs MOR：写路径决定一切

| | COW（copy on write） | MOR（merge on read） |
|---|---|---|
| 写入动作 | 每次更新**重写**受影响文件组的整个 base file（列存） | 更新追加到 log 文件 |
| 写放大 | 高（改 1 行重写整个文件组） | 低（append-only） |
| 读放大 | 无（只读列存 base） | 高（读时合并 base + log） |
| 查询延迟 | 低且稳定 | snapshot 查询要现场合并；read_optimized 只读 base（快但旧） |
| 数据新鲜度 | 受微批间隔限制 | 秒级可见 |
| 后台依赖 | 轻 | 依赖 compaction 压 log，否则读路径持续恶化 |
| 典型场景 | 读多写少、批式回刷、宽表加工 | CDC 高频 upsert、分钟级新鲜度 |

选择逻辑与 Doris Unique 模型的 MoW/MoR（05 章第 3 节）同构：**合并成本放写路径还是读路径**。写入 QPS 高、更新占比大 → MOR + 认真调 compaction；一天几批、读很重 → COW。

### 3.3 record-level index

upsert 的第一步是"这行主键在哪个文件"。Hudi 传统上靠 bloom filter（文件页脚，可能假阳性需回读）或 bucket index（按桶路由免索引）。record index（0.14 引入、1.x 主推）把**主键 → 文件位置**映射持久化在元数据表里，定位从"扫描 + 过滤"变成一次查表，写路径几乎不受表体积影响；代价是元数据表多维护一份全量主键索引、首次 bootstrap 要扫全表。配置在 0.14 与 1.x 间差异大，以官方文档为准。

### 3.4 运维关注：三个后台作业的调度

| 作业 | 干什么 | 不跑的后果 |
|---|---|---|
| compaction | 把 MOR 的 log 合并回 base file | 查询越来越慢（读放大失控） |
| cleaning | 清理被新版本取代的旧 file slice | 空间无限膨胀；反向配太狠会截断增量消费回溯窗口 |
| clustering | 按排序键重排小文件 | 小文件堆积，扫描计划变慢 |

```sql
-- [Flink SQL WITH 子句 / Spark DataFrameWriter.option 通用] 三个作业的典型开关
'hoodie.compact.inline' = 'false',                -- 流式写入几乎总是关 inline 走异步
'hoodie.clean.automatic' = 'true',
'hoodie.cleaner.commits.retained' = '24',         -- 保留多少个提交的旧文件 = 增量回溯窗口
'hoodie.clustering.inline' = 'false', 'hoodie.clustering.plan.strategy.small.file.limit' = '629145600'
```

调度形态按引擎二选一：Flink 走 sink 异步 compaction（`hoodie.compact.inline=false` 时启用，`compaction.tasks` 扩并发）；Spark 用独立 spark-submit 分 schedule/run 两步跑。参数名随版本变化频繁，落地前逐项对官方文档。**排障口诀：MOR 查询变慢先看 compaction 积压，增量断流先看 cleaning 是否清掉了窗口。**

## 4. Paimon：为流而生的湖存储

### 4.1 主键表的 LSM 结构

Paimon 主键表的 bucket 内部是一棵 LSM 树，与 RocksDB/ClickHouse MergeTree 同族：

```
warehouse/db.db/orders/
├── schema/
│   └── schema-0                          表结构（JSON 文本，可直接 cat）
├── snapshot/
│   ├── EARLIEST / LATEST                 hint 文件：可消费区间边界
│   └── snapshot-1 .. snapshot-N          每次提交一个
├── manifest/
│   └── manifest-<uuid>-0                 每次变更的增量清单（Avro，二进制）
└── bucket-0/                             一个 bucket = 一棵 LSM
    ├── data-<uuid>-0.orc                 SST 文件（按主键有序）
    ├── changelog-<uuid>-0.orc            changelog 文件（-U/+U/+I/-D）
    └── ...
```

写路径：写缓冲 → flush 成层 0 SST → 后台 compaction 逐层合并（同 key 去重，按 sequence field 定新旧）；读路径是各层 SST 归并读。**每次 checkpoint 提交一个 snapshot，snapshot 引用 manifest、manifest 指向 SST**——与 Iceberg 的 ②③ 层同构，6.2 的监控思路原样适用。snapshot 过期是写路径内置的（`snapshot.num-retained.max` 自动裁剪），比 Iceberg 的手动 procedure 省事。

### 4.2 append 表

不带主键的 append 表没有 LSM 与合并语义，就是把文件按 bucket 追加，面向批处理明细与日志留存（定位对应 Doris 的 Duplicate 模型，05 章第 3 节）。流式读靠 `scan.mode` 增量拉新文件；小文件问题比主键表更尖锐（没有 compaction 顺手治），要显式配 `compaction.min.file-num` 控制文件级合并的触发阈值（注意：旧版成对出现的 `compaction.max.file-num` 在 1.4 起已移除，防 OOM 的单次扫描上限现在由 `compaction.file-num-limit` 控制、不是合并触发参数，配置以官方文档为准）。

### 4.3 changelog 的三种产生方式

下游要"像消费 Kafka 一样消费表的变更流"，就必须有完整的更新前像/后像。`changelog-producer` 决定在哪里生成：

| 方式 | 原理 | 代价/前提 | 适用 |
|---|---|---|---|
| `input` | 认为输入本身就是完整 CDC 流（含 -U/+U），原样透传 | 上游必须是 Debezium/Flink CDC 这类完整流，否则丢前像 | 有可靠 CDC 源时最便宜 |
| `lookup` | 写入时回查存量数据补出前像 | 写路径多一次查找（状态/回表），吞吐下降 | 上游只有 upsert 流 |
| `full_compaction` | 全量合并时对比新旧版本生成完整 changelog | 延迟 = 全量合并周期（触发频率由 full-compaction 相关参数控制） | 正确性优先、可接受分钟级以上延迟 |

`none`（不设置）表示不产生 changelog，下游只能当 append 流消费。选择顺序：**能 input 不 lookup，能 lookup 不 full_compaction**——每往右一步都是用延迟或吞吐换正确性。

### 4.4 为什么与 Flink 绑定最深

1. **提交由 checkpoint 驱动**：snapshot 与 checkpoint 一一对应，exactly-once 是结构内生的（第 7 节展开），其他引擎没有等价的全局快照机制。
2. **流式语义的一等公民**：changelog 消费、增量读、lookup 依赖的有状态查找，都是 Flink 运行时的能力。
3. 社区由 Flink 阵营主导（阿里实时计算团队发起，00 章速览表"国内现状"一行的由来），Spark/Trino/Doris/StarRocks 读写没问题（批视角），但"增量消费 + changelog 下游"这条主航道基本只有 Flink。生产建表样例（实战与 lab 04 都围绕它）：

```sql
-- [Flink SQL 客户端（连接方式同 12-data-streaming/flink/01 的 sql-client）]
CREATE CATALOG paimon WITH (
  'type' = 'paimon',
  'warehouse' = 'file:///opt/paimon/warehouse'    -- 生产换 s3:// 或 hdfs:// 路径
);
CREATE TABLE paimon.demo.orders (
  order_id BIGINT, user_id BIGINT, amount DECIMAL(18,2), dt STRING,
  PRIMARY KEY (order_id, dt) NOT ENFORCED
) PARTITIONED BY (dt) WITH (
  'bucket' = '4', 'bucket-key' = 'order_id', 'changelog-producer' = 'lookup',
  'snapshot.num-retained.max' = '60'
);
```

## 5. 三者选型矩阵与"湖存储 + Doris 直查"组合

00 章第 2 节的三行速览表是入口，这里按运维维度拉满（常见形态是"实时链路 Paimon/Hudi + 批与查询层 Iceberg"并存，SRE 把共同运维面抽象成统一巡检而不是学三遍）：

| 维度 | Iceberg | Hudi | Paimon |
|---|---|---|---|
| 更新频率 | 低~中（v2 delete 文件可用但读放大大） | 高（MOR 为 upsert 而生） | 高（LSM 主键表） |
| 查询延迟 | 最稳（读路径无合并，计划剪枝强） | MOR 依赖 compaction 节奏 | 依赖 compaction 节奏 |
| 入湖引擎 | 全中立（各引擎自己实现规范） | Spark 最成熟，Flink 可用 | Flink 一家独大 |
| 流式消费 | 增量读可用，changelog 弱 | 增量读 + CDC 生态成熟 | changelog 一等公民 |
| 生态/国内现状 | 最广（主流云与数仓均原生支持） | 存量大、Uber 系 | 国内 Flink 栈最活跃 |
| 后台作业形态 | 无服务，procedure 手动 + 定时调度 | 三个 table services 要调度 | 写路径内置，可剥离独立 compaction |

与 05 章第 7 节的湖查询拼起来才是完整链路：

```
Kafka ──Flink──► Paimon/Iceberg 湖表 ──catalog(HMS/REST)──► Doris Multi-Catalog 直查
                     │                                        （05 章 §7：外表下推扫描湖上文件）
                     ├─ Flink 流式消费 changelog（增量）       近 N 天热数据 → Doris 内表（本地列存）
                     └─ Spark 批回刷/修数（time travel 对账）  历史明细 → 留湖（廉价存储 + 按需扫描）
```

容量分工与 05 章第 7 节第 4 点一致：**热在内表换延迟，冷在湖里换成本**，"删热保冷"靠分区滚动。排障边界：入湖慢看 Flink 写路径与湖 commit（第 7 节），查得慢看引擎与对象存储（05 章已给），元数据坏了看 catalog（6.4）。

## 6. 湖仓运维专题

### 6.1 小文件治理

成因三个：checkpoint 间隔太小（每次提交一批文件）、分区过细（每分区攒不了几行）、失败重试残留。三层治理，从源头到兜底：

| 层 | 动作 | 关键参数/命令 |
|---|---|---|
| 写入侧 | 攒批：拉大 checkpoint/提交间隔；设目标文件大小 | Iceberg `write.target-file-size-bytes`；Paimon `compaction.min.file-num` |
| 表内合并 | 定时重写数据文件 | Iceberg `rewrite_data_files`；Paimon 独立 compaction 作业（写端 `'write-only'='true'` 剥离）；Hudi clustering |
| 生命周期 | 删旧分区而不是删行 | 各格式均支持分区过期/`DROP PARTITION` 语义，名称以文档为准 |

### 6.2 snapshot / manifest 膨胀监控（指标与告警思路）

表格式无常驻进程、没有现成的 `/metrics` 端点，指标要自己造，三个来源：

```sql
-- [Spark SQL 客户端] 用 Iceberg 只读元数据表做巡检（cron 跑，结果推 Pushgateway）
SELECT count(*) AS snapshot_cnt, max(committed_at) AS last_commit FROM lake.db.events.snapshots;
SELECT count(*) AS file_cnt, avg(file_size_in_bytes) AS avg_bytes FROM lake.db.events.files;  -- 小文件程度
SELECT count(*) AS manifest_cnt FROM lake.db.events.manifests;          -- 计划成本
SELECT count(*) AS metadata_cnt FROM lake.db.events.metadata_log_entries; -- metadata.json 堆积
```

| 指标 | 含义 | 告警/动作思路 |
|---|---|---|
| snapshot_cnt | 保留的快照数 | 持续上涨 = expire 没在跑；突降 = 刚清完（对照变更单再告警） |
| file_cnt / avg_bytes | 小文件程度 | 平均 < 64MB 且文件数周环比上涨 → 触发 `rewrite_data_files` |
| manifest_cnt | 计划成本 | 超阈值触发 `rewrite_manifests` |
| metadata_cnt | metadata.json 堆积 | 检查 `write.metadata.delete-after-commit.enabled` 是否生效 |
| Flink checkpoint 时长 | 湖 commit 是否拖累提交 | 超阈值联动查 catalog 与对象存储（12 模块的 checkpoint 监控直接复用） |

巡检结果推 Pushgateway 变成 gauge（标签 `table=...`），接进 08 模块已建的告警体系——难点不在指标，在"没有进程可挂 exporter"这个前提要先想通。

### 6.3 schema 演进兼容规则

表格式把 schema 变更变成元数据操作（Iceberg 按 field id 而非列名追踪字段），但**兼容性要自己守规则**：

| 变更 | 安全性 | 说明 |
|---|---|---|
| ADD 列 | 安全 | 旧读者忽略新列；默认值要显式给 |
| DROP 列 | 半安全 | 元数据层安全；还在写旧 schema 的作业会失败或写 null——先停下线写方再删 |
| RENAME / int→long 宽化 | 安全（Iceberg 按 field id 追踪） | 按列名拼 SQL 的下游要同步改；反向窄化、string→数字这类语义变更**禁止** |
| 分区/桶数变更 | 要迁移作业 | Paimon 改 bucket 数需 rescale；Iceberg 分区规格可演进但新旧文件读代价不同 |

铁律：**演进只做加法，破坏性变更走"新列 + 双写 + 切读 + 删旧"四步**。CDC 的 schema 自动同步（各格式 evolution 能力成熟度差异大，以官方文档为准）只解决"能同步"，不解决"下游作业兼容"。

### 6.4 catalog 选型：HMS、REST catalog、Nessie

catalog 回答两个问题：**表在哪里（寻址）+ 谁来原子提交（并发控制）**。

| | Hive metastore | Iceberg REST catalog | Nessie |
|---|---|---|---|
| 形态 | 关系库 + Thrift 服务（03 章第 2 节） | 一套 HTTP 规范，实现可托管 | 独立服务，git 风格分支 |
| 原子提交 | 表级锁 | 服务端 CAS | 服务端分支合并 |
| 优势 | 存量最大，Doris/Spark/Trino 全通 | 认证/多租户集中，云上免运维（AWS Glue、S3 Tables、Apache Polaris 等实现） | 数据分支环境：WAP、隔离回刷 |
| 运维代价 | 就是 03 章第 8.1 节那个 MySQL，备份/HA 全套 | 多一个 HTTP 服务及其可用性 | 又一个有状态服务 + 分支治理规范 |

SRE 要点：**catalog 是湖表的 NameNode**——挂了写全阻塞，读看引擎元数据缓存能撑多久。HMS 路线的备份纪律直接复用 `11-middleware/mysql/02-backup-replication.md`（mysqldump + 一致性演练），即 03 章第 8.1 节结论的湖仓版：那台 MySQL 的等级应与 etcd 相当。

### 6.5 权限：Ranger 一句话定位

**Apache Ranger 是集中式授权策略引擎**：把 HDFS/HMS/Trino/Flink SQL 的访问控制统一成一份策略库。湖仓里它的定位是**权限必须落在 catalog/引擎接入层**——数据文件躺在对象存储上没有可用的 ACL 面（桶策略做不了列级/行级），"谁能查哪张表哪列"只能在 catalog 与查询引擎这一跳收口。

## 7. 与 12-data-streaming 的衔接：exactly-once 落到湖写入路径

12 模块的三前提框架（`12-data-streaming/flink/02-deployment-and-exactly-once.md` 第 5 节"端到端 exactly-once：三个前提缺一不可"）：source 可重放 + 状态在 checkpoint + sink 两阶段提交。湖表 sink 的"两阶段"形态：

```
checkpoint N 触发 ──► 写阶段：数据文件已落存储，但未提交（对读者不可见）
        │
notifyCheckpointComplete(N)
        ▼
     提交阶段：生成新 snapshot 并原子交换指针（catalog CAS）
        ├─ Iceberg：FilesCommitter 算子在 checkpoint 完成后 commit 本次 manifest list
        └─ Paimon：snapshot-N 与 checkpoint 对应，恢复时回滚到上一个 snapshot
```

恢复语义与 Doris Stream Load 2PC（05 章第 5 节）同构：checkpoint N 未完成就崩溃 → source 重放 → 重写文件 → 重新提交。幂等键从 Doris 的 label 变成**文件不可变 + 指针原子交换**：重复落盘的 data file 没被任何 snapshot 引用，成为孤儿，由 `remove_orphan_files`（Iceberg）或 Paimon 的过期机制清掉。

两个运维落点：**checkpoint 超时的第一嫌疑人常常是湖 commit**（对象存储慢、catalog 锁竞争），用 12 模块的反压定位法追到本节、再到 6.4 的 catalog；以及**别关 checkpoint**——三个格式的 sink exactly-once 全绑在 checkpoint 上，为省开销关掉或拉到过长，换来的是重复数据。

## 实战演练

本章不部署（Flink 写入 Paimon 的完整部署在 `labs/04-lakehouse-flink-paimon`），只做**读法演示**：学会用文件/对象存储的视角看穿一张湖表。以下命令在 lab 04 的环境里执行，路径取该 lab 的实际配置（warehouse=`/opt/flink/warehouse`，表=`sre_lab.host_metrics`——即 4.4 建表例在 lab 里的落地形态）。

```bash
# [任意节点]（lab 04 的 VM）第一层：Paimon warehouse 的整体骨架
find /opt/flink/warehouse -maxdepth 3 | sort
# 预期骨架（对照 4.1 的图；lab 04 建表 bucket=2，所以有 bucket-0/bucket-1 两个桶目录）：
#   /opt/flink/warehouse/sre_lab.db/host_metrics/{schema,snapshot,manifest,bucket-0,bucket-1}
```

```bash
# [任意节点] 第二层：读文本层——snapshot hint 与 schema 是能直接 cat 的
cat /opt/flink/warehouse/sre_lab.db/host_metrics/snapshot/LATEST
# 预期：一个数字，如 17 —— 当前最新 snapshot 号（EARLIEST 是可消费起点；
#      下面的 snapshot-17 请替换成你读到的这个号）
cat /opt/flink/warehouse/sre_lab.db/host_metrics/snapshot/snapshot-17
# 预期：JSON，含本次提交引用的 manifest 清单、commit identifier、记录数等字段
#      （新版本可能把 snapshot 文件二进制化，看不了就只读 hint 文件，以官方文档为准）
cat /opt/flink/warehouse/sre_lab.db/host_metrics/schema/schema-0
# 预期：JSON：字段名/类型/主键。"表结构就是个文件"——6.3 的 schema 演进=元数据操作，实体长这样
```

```bash
# [任意节点] 第三层：数文件，把 6.2 的巡检指标手工算一遍
ls /opt/flink/warehouse/sre_lab.db/host_metrics/snapshot | grep -c '^snapshot-'
# 预期：snapshot 总数（对照 snapshot.num-retained.max，验证过期在跑）
ls -l /opt/flink/warehouse/sre_lab.db/host_metrics/bucket-0 | head -6
# 预期：SST 文件清单（data-*/changelog-*）——单文件几十 KB、数量上百 = 典型小文件病，该触发 compaction 了
```

```bash
# [任意节点] 对象存储视角（可选延伸，lab 04 之外另搭环境：lab 04 的 warehouse 是 file:// 本地
# 路径，不含 MinIO。想动手本块，需自行起 MinIO 并把 warehouse 配成 s3:// 后重建表；
# 桶需允许匿名 list，仅演示环境）
curl -s "http://127.0.0.1:9000/lakehouse/?list-type=2&prefix=warehouse/sre_lab.db/host_metrics/snapshot/" \
  | sed 's/></>\n</g' | grep -A1 '<Key>' | head -12
# 预期：ListObjectsV2 列出 snapshot-1..N 的 key。湖表在对象存储上没有"目录"，只有公共前缀——
#      这就是小文件一多 listing 就慢的根因（05 章第 7 节第 3 点），也是 curl 看湖表"目录结构"的姿势
```

验证方法：不看正文能说出"LATEST 指向的 snapshot → manifest 清单 → SST 文件"这条引用链，并分清哪些是文本、哪些是二进制，即通过；数到的 snapshot/manifest/SST 数量记下来，作为 6.2 巡检脚本的第一份基线。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 湖表越写越慢、计划阶段就耗时长 / Iceberg 并发写报 commit 冲突 | 小文件 + manifest 碎片化；多 writer 争同一表的 catalog 锁 | `rewrite_data_files` + `rewrite_manifests` 定时跑、设 `write.target-file-size-bytes`；减少并发 writer、按分区隔离写（并发写语义以官方文档为准） |
| time travel 报 snapshot 不存在 | 被 expire 清掉了 | 回溯前先查 `table.snapshots` 元数据表确认保留窗口；要长回溯就调大 `history.expire.max-snapshot-age-ms` |
| Hudi MOR 查询越来越慢 | compaction 积压 | 看 timeline 上 compaction requested 是否长期未执行；调度独立 compaction；临时用 read_optimized 查询 |
| Hudi 增量消费突然断流/丢数据 | cleaning 把保留窗口清得太狠 | 调大 `hoodie.cleaner.commits.retained`，按下游重放需求定 |
| Paimon lookup changelog 作业吞吐低、反压 | 写路径回查前像开销大 | 评估换 `input`（上游是完整 CDC 时）或 `full_compaction`（可接受延迟时） |
| Flink 写湖恢复后疑似重复数据 / 湖上无主文件增多 | checkpoint 被关或间隔过长，sink 提交与 checkpoint 脱钩；失败重试残留孤儿文件 | 恢复 checkpoint 配置、确认 connector 支持 exactly-once；孤儿文件用 `remove_orphan_files` 清（先核对无长事务） |
| Doris 直查湖表偶发超时 | 对象存储限流、file cache 冷、小文件多 | 05 章第 7 节第 2/3 点：加分区条件、预热缓存、源头治小文件 |
| 改了 schema 后部分下游作业报列不存在 / 只配桶策略管不住湖表 | 破坏性变更没走四步迁移；对象存储 ACL 做不了列级权限 | 按 6.3 铁律：新列 + 双写 + 切读 + 删旧；权限落 catalog/引擎接入层（Ranger，6.4） |

## 自测

1. Iceberg 为什么必须把"提交的原子性"交给 catalog？对象存储缺了什么原语？如果 catalog 宕机 5 分钟，读写分别会怎样？
<details><summary>答案</summary>

对象存储只保证单个对象的原子 PUT，没有"原子交换指针/条件更新"原语（S3 连 rename 都没有），而一次 Iceberg 提交的本质是"把表的 current 指针从 metadata.json vN 换到 vN+1"，这个状态变更需要外部仲裁：HMS 用表级锁、REST catalog 用服务端 CAS。catalog 宕机时：写全部阻塞（新 snapshot 无法生效，Flink 表现为 checkpoint 超时、反压）；读大多还能进行（引擎已缓存的元数据可继续解析文件路径），但拿不到新快照、也建不了新表——catalog 是湖链路里等级等同 NameNode 的单点，必须 HA + 备份。
</details>

2. 同一张订单表从 COW 换成 MOR，写放大与读放大各怎么变？出现什么业务信号时你才做这个切换？
<details><summary>答案</summary>

写放大下降（upsert 从"重写整个 base file"变成"追加 log 文件"），读放大上升（snapshot 查询要归并 base + log，且依赖 compaction 节奏）。切换信号：写入侧——CDC 流量上来后写入延迟/资源占用持续超限、更新行占比高（大部分文件组都被打中，重写不划算）；读取侧——若下游以批报表为主且能接受 read_optimized 的旧数据，MOR 几乎无代价。反例：一天几批、读很重的宽表加工，COW 的稳定读延迟更值钱。
</details>

3. Paimon 的 changelog-producer 三种方式各自依赖什么正确性假设？代价落在哪里？上游换成"只有 insert 的日志流"时该选哪个？
<details><summary>答案</summary>

input 假设输入已含完整前像/后像（Debezium/Flink CDC 流），代价最低但源不对就丢更新语义；lookup 假设可以用存储里的存量状态补出前像，代价是写路径多一次查找（吞吐下降、依赖状态）；full_compaction 假设可以等全量合并时再生成 changelog，正确性最强但延迟等于合并周期。上游只有 insert 时：根本不存在更新，选 none（不产生 changelog），下游当 append 流消费即可——为不存在的更新付 lookup/full_compaction 成本是纯浪费。
</details>

4. snapshot 过期策略配得太激进和太保守，分别伤到谁？time travel 与 Flink 增量消费分别受哪个约束？
<details><summary>答案</summary>

太保守（保留过多）：存储与元数据持续膨胀、查询计划变慢、对象存储 listing 变贵——伤读和成本。太激进（清太快）：time travel 回溯窗口变短、长时间离线的增量消费者追不上起点（EARLIEST 已推进过它的位点）导致必须全量重灌——伤回溯与容灾。time travel 受 `history.expire.max-snapshot-age-ms` / `min-snapshots-to-keep`（Iceberg）或 `snapshot.num-retained.max`（Paimon）约束；增量消费还额外受 Hudi 的 `hoodie.cleaner.commits.retained` 约束（旧文件 slice 被清掉就断了增量链）。定策略的依据是"最慢的消费者需要回看多远"，不是存储成本单变量。
</details>

5. 表格式没有常驻进程，这如何改变监控体系的设计？给出指标采集的三个来源和两条告警。
<details><summary>答案</summary>

无进程意味着没有现成的 exporter/端口可抓，指标必须来自外部巡检与上下游，且"主动作业"本身就是运维对象。三来源：① 元数据巡检作业（读 `table.snapshots`/`files`/`manifests` 等元数据表，Pushgateway 推 gauge）；② 写路径引擎指标（Flink checkpoint 时长/失败率、反压——12 模块已建的监控面）；③ 存储与 catalog（对象存储 429/503、listing 延迟、HMS/REST catalog 可用性与连接数）。两条告警：snapshot 保留数持续上涨（expire 没跑或写频率突变）；文件平均大小低于阈值且数量周环比上涨（小文件恶化，触发 rewrite_data_files）。
</details>

## 延伸阅读

- Apache Iceberg 官方文档（表格式规范、元数据结构与 maintenance 过程）：https://iceberg.apache.org/docs/latest/
- Apache Hudi 官方文档（写入路径与 table services 配置）：https://hudi.apache.org/docs/overview/
- Apache Paimon 官方文档（主键表、append 表、changelog producer）：https://paimon.apache.org/docs/master/
- Project Nessie（git 风格 catalog）：https://projectnessie.org/
- Apache Ranger（集中式授权）：https://ranger.apache.org/
