---
title_juejin: '数据湖裸奔了十年，直到有人给它加了一张「表」'
title_zhihu: '湖仓三巨头不是新数据库，是给裸文件补的一层表语义'
description: '对象存储只管存字节，不懂表为何物：裸文件四坑、Iceberg元数据树、Hudi timeline、Paimon changelog取舍、选型只看更新频率，湖上巡检与exactly-once落湖。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686341072617242662"
---

# 数据湖裸奔了十年，直到有人给它加了一张「表」

凌晨修数，同事把订单表的整个分区目录覆盖上去，网络断在第 700 个文件。第二天报表读到半新半旧的订单——全程没有报错，因为没有一层有资格报错：对象存储只管存住字节，不懂这张表为何物。（构造典型案例）

数据湖裸奔十年，缺的不是存储，是一张「表」。表格式（table format）补的就是这层：不是新数据库，没有服务进程，却把事务、schema 管理、时间旅行还给文件堆。

## 一、裸文件的四个坑

把 Parquet 直接堆上对象存储当表用，会撞四件事：

无事务——两个作业同写一张表，读者可能拿到"写了一半"的文件集合，没有原子提交点。

不能 upsert——对象存储没有原地修改，改一行等于重写整个文件，人人自写"新文件 + 合并逻辑"，每份都有 bug。

无 schema 保护——列结构没人管，上游改列，下游读到一半才炸，混读全靠自觉。

改数据等于覆盖——回刷要么 mv 目录（对象存储连原子 rename 都没有），要么整目录覆盖，出错即事故。

四个坑一个根因：**存储只给你不可变文件加目录前缀，"表"是你脑补的**。Hive 用 metastore 加目录约定回答过一次，Hive ACID 想补事务但绑死引擎——表格式把这层语义标准化、引擎无关化。

SRE 最要紧的认知：**这层没有常驻进程，状态全落在元数据文件与 catalog 里**，运维对象是文件（元数据膨胀）、作业（compaction 类后台任务）、catalog（提交与寻址的原子性）三样。

## 二、Iceberg：把表变成一棵元数据树

设计核心一句话：**数据文件不可变，一切变更都是元数据的新版本**。四层自上而下：

```text
catalog（HMS / REST / Nessie）—— 指针原子交换，原子性就在这一跳
  ▼ ① metadata.json：schema、分区规格、snapshot 列表
  ▼ ② manifest list：本快照全部 manifest，附分区范围摘要
  ▼ ③ manifest：文件清单，含每列 min/max/null 统计
  ▼ ④ data/ 的 Parquet/ORC 文件本体
```

查询计划沿树剪枝——分区摘要跳过无关 manifest、列统计跳过无关文件，**过滤条件下推到了文件枚举层**，这也是"文件越多计划越慢"的来源。

快照隔离从哪来？每次写产生一个新 snapshot，父指向前一个；读永远是某个 snapshot 的一致视图，写了一半的文件对读者不存在。time travel 就是读历史 snapshot。但 snapshot 不免费——它钉住引用的数据文件，过期前不能删。

提交的原子性不在树里，在树顶一跳：**catalog 指针的原子交换**。对象存储没有"原子换指针"原语，新 metadata.json 生效必须由 catalog 仲裁（HMS 表级锁、REST catalog 的 CAS）。catalog 挂了写全阻塞，**它就是湖表的 NameNode**。

一条选型分界线：Iceberg 表格式 v2 靠 delete 文件实现 upsert，写路径轻、读路径现场合并——Iceberg 是"能做"，Hudi 和 Paimon 是"为它而生"。

运维是提交侧作业，Iceberg 自己不跑后台服务，靠 procedure 加定时调度：

```sql
-- [Spark SQL 客户端] 快照过期与小文件合并（rewrite_manifests、remove_orphan_files 同族）
CALL lake.system.expire_snapshots(table => 'db.events', older_than => TIMESTAMP '2026-08-23 00:00:00', retain_last => 10);
CALL lake.system.rewrite_data_files(table => 'db.events', where => 'dt = ''2026-08-30''');
-- 参数随版本演进，以官方文档为准
```

## 三、Hudi：把 Kafka 的日志思维搬进表元数据

Hudi 把表上的所有事件——数据写入加 compaction、clean 这些后台服务——都记在 `.hoodie` 目录一条时间线上。每个事件是一个 instant，状态机 requested → inflight → completed：

```text
.hoodie/
  20260830101500.deltacommit.{requested,inflight,completed}  MOR 增量写
  20260830100000.compaction.requested    10 点排的计划，可能 18 点才执行
  20260830100000.clean.completed         清掉被取代的旧版本文件
```

timeline 是 Hudi 的单一事实源：增量消费按 instant 拉取，并发控制按 instant 排序，一致性视图由"已 completed 的最大 instant"决定——**Hudi 把 Kafka"日志即状态"搬到了表的元数据上**。

COW 还是 MOR，本质是合并成本放写路径还是读路径。COW 改 1 行重写整个文件组的 base file：写放大高、延迟稳，适合读多写少、批式回刷。

MOR 只追加 log 文件、读时合并 base + log：写放大低、秒级可见，代价是读放大高、依赖 compaction——CDC 高频 upsert 的正解。

三个后台作业是运维主战场：compaction 不跑，MOR 查询渐慢；cleaning 不跑空间膨胀，配太狠又截断增量回溯窗口；clustering 不跑，小文件堆积。口诀：**MOR变慢查compaction积压，断流查cleaning**。

## 四、Paimon：先想清楚流，再想清楚表

Paimon 主键表的 bucket 是一棵 LSM 树，与 RocksDB、ClickHouse MergeTree 同族：写缓冲 flush 成第 0 层 SST，后台逐层合并、同 key 去重，读是归并读。

每次 checkpoint 提交一个 snapshot，snapshot 引用 manifest、manifest 指向 SST——中间两层与 Iceberg 同构。

snapshot 过期还内置在写路径（`snapshot.num-retained.max` 自动裁剪），比 Iceberg 的手动 procedure 省事。

让 Paimon 立住的是 changelog：下游要像消费 Kafka 一样消费表的变更流，就得有完整的更新前像/后像，`changelog-producer` 决定在哪生成：

```text
input           上游已是完整 CDC 流（Debezium/Flink CDC），透传，最便宜
lookup          写入时回查存量补前像，吞吐下降
full_compaction 全量合并时对比生成，正确性最强，延迟 = 合并周期
```

选择顺序：能 input 不 lookup，能 lookup 不 full_compaction——**每往右一步，都是拿延迟或吞吐换正确性**。上游只有 insert 流时设 none。

为什么与 Flink 绑最深？提交由 checkpoint 驱动，snapshot 与 checkpoint 一一对应，exactly-once 结构内生；增量读、changelog 消费、有状态查找都是 Flink 运行时能力——这条主航道基本只有 Flink。

```sql
-- [Flink SQL 客户端] 建表核心参数（catalog 需先配 type/warehouse）
CREATE TABLE paimon.demo.orders (order_id BIGINT, dt STRING,
  PRIMARY KEY (order_id, dt) NOT ENFORCED) PARTITIONED BY (dt) WITH (
  'bucket' = '4', 'bucket-key' = 'order_id', 'changelog-producer' = 'lookup');
```

## 五、选型只看一条分界线

唯一的对比表：

| 维度 | Iceberg | Hudi | Paimon |
|---|---|---|---|
| 更新频率 | 低~中（delete 读放大大） | 高（MOR 为 upsert 而生） | 高（LSM 主键表） |
| 查询延迟 | 最稳（读路径无合并） | MOR 依赖 compaction 节奏 | 依赖 compaction 节奏 |
| 入湖引擎 | 全中立 | Spark 最成熟，Flink 可用 | Flink 一家独大 |
| 流式消费 | 增量读可用，changelog 弱 | 增量读 + CDC 生态成熟 | changelog 一等公民 |
| 生态 | 最广（云与数仓原生支持） | 存量大、Uber 系 | 国内 Flink 栈最活跃 |

最硬的分界线只有一条：更新频率。高频 upsert 别硬上 Iceberg，delete 文件的读放大会教做人；批为主、查询要稳，Iceberg 读路径无合并、剪枝最强。

【从业者判断】落到生产，三家常在同一个机房各管一段："实时链路 Paimon/Hudi + 批与查询层 Iceberg"。SRE 别学三遍运维，把共同运维面（小文件、快照过期、catalog）抽象成一套统一巡检即可。

【从业者判断】很多团队的选型早被存量引擎栈决定：Spark 重仓，Iceberg/Hudi 都顺；Flink 重仓，基本直通 Paimon——已有的引擎比特性矩阵更早替你投票。

表格式只管把表存明白，查得快靠查询引擎，完整链路：

```text
Kafka ─Flink→ Paimon/Iceberg 湖表 ─catalog→ Doris Multi-Catalog 直查
近 N 天热数据 → Doris 内表换延迟；历史明细 → 留湖换成本
Spark 回刷修数用 time travel 对账
```

**热数据放内表换延迟，冷数据留湖里换成本**，"删热保冷"靠分区滚动。

## 六、湖上运维：对象是文件和作业

表格式没有常驻进程，也就没有 `/metrics` 端点，指标自己造——先用 Iceberg 只读元数据表做巡检：

```sql
-- [Spark SQL 客户端] 巡检（cron 跑，结果推 Pushgateway）
SELECT count(*) AS snapshot_cnt, max(committed_at) FROM lake.db.events.snapshots;
-- files、manifests 等元数据表同理：算文件平均大小与清单数
```

两条最值钱的告警：snapshot 保留数持续上涨，说明 expire 没在跑；文件平均小于 64MB 且数量周环比上涨，触发 `rewrite_data_files`。

小文件治理三层：写入侧攒批（拉大 checkpoint 间隔、设目标文件大小），表内定时合并（rewrite_data_files / 独立 compaction / clustering），生命周期删旧分区而不是删行。

因果链记熟：高频 checkpoint → snapshot 与小文件暴涨 → manifest 碎片化 → 计划变慢。

schema 铁律：**演进只做加法**，破坏性变更走"新列 + 双写 + 切读 + 删旧"四步。表格式把 schema 变更变成元数据操作（Iceberg 按 field id 而非列名追踪字段），但兼容性自己守——DROP 列前先停掉还在写旧 schema 的作业。

## 七、exactly-once 落湖：幂等键是「不可变文件 + 原子指针」

三前提：source 可重放、状态在 checkpoint、sink 两阶段提交。湖表 sink 的"两阶段"：写阶段数据文件已落存储但未提交（对读者不可见）；`notifyCheckpointComplete` 后进入提交阶段，生成新 snapshot，catalog CAS 原子交换指针。

恢复语义：checkpoint N 未完成就崩溃 → source 重放 → 重写文件 → 重新提交。

幂等键从数据库主键约束换成**文件不可变 + 指针原子交换**——重复落盘的 data file 没被任何 snapshot 引用，成为孤儿，交给 `remove_orphan_files` 或 Paimon 的过期机制清掉。

两个运维落点：**checkpoint 超时的第一嫌疑人常常是湖 commit**（对象存储慢、catalog 锁竞争）；以及**别关 checkpoint**——三家格式的 sink exactly-once 全绑在 checkpoint 上，为省开销关掉，换来的是重复数据。

## 现在就能做的三件事

第一，把巡检 SQL 对你最重的湖表跑一遍，记下快照数与文件平均大小——第一份基线。

第二，确认快照过期在跑：Iceberg 确认 `expire_snapshots` 有定时调度——`history.expire.max-snapshot-age-ms` 等属性只定保留窗口，光配属性不会自动过期；Paimon 对照 `snapshot.num-retained.max` 数 snapshot 目录。

第三，检查所有写湖作业的 checkpoint 配置——有没有人为了"省开销"把它关了。

元数据树拆解、三大格式配置清单、巡检脚本与踩坑解法，都在我的学习仓库：GitHub 搜 sre-learning-hub。

评论区聊聊：你们湖上跑的是哪家表格式？有没有被小文件或 snapshot 膨胀咬过一口？
