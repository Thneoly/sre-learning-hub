---
title_juejin: 'ClickHouse UPDATE：一秒返回，三小时才生效'
title_zhihu: 'ClickHouse 没有「改一行」这回事：都是 merge 还没干完活'
description: '主键是排序描述不是行索引；mutation 排队重写 part；Replacing 去重不保证时机；too many parts 从写入碎追到 Kafka lag；双表架构与 MV 预聚合。'
category_id: "6809637769959178254"
tags: "后端,数据库"
column_id: "7686472562230312970"
---

# ClickHouse UPDATE 一秒返回，三小时后才生效：merge 的脾气

> （构造典型案例，细节已脱敏）周五下午，风控要给一批用户补打灰名单标记。DBA 在 ClickHouse 上跑 ALTER TABLE ... UPDATE flag = 1 WHERE ...，命令一秒返回，他合上电脑下班。
>
> 晚上十一点风控在群里@他：名单跑出来还是旧值。任务日志全绿，重试记录也全绿——数据确实变了，只是晚了三个小时。

监控没坏，任务也没错。在 ClickHouse 里，ALTER UPDATE 不是「改数据」的命令，它是往重写队列里塞的一张工单。

这篇把工单背后的 MergeTree 脾气讲透：主键为什么不是索引、去重为什么「没生效」、写入为什么被拒——它们是同一个机制的四张面孔。

## 一、先复现：一秒返回的 UPDATE

```bash
# 起单节点演示环境（镜像 tag 以官方页面为准，下例 25.3）
docker run -d --name ch-solo -p 8123:8123 -p 9000:9000 \
  --ulimit nofile=262144:262144 clickhouse/clickhouse-server:25.3
until docker exec ch-solo clickhouse-client --query 'SELECT 1' >/dev/null 2>&1; do sleep 2; done
```

```sql
-- 后续 SQL 均经 docker exec ch-solo clickhouse-client 执行
CREATE DATABASE IF NOT EXISTS demo;
CREATE TABLE demo.events (ts DateTime, event String, user_id UInt32, cost UInt32)
  ENGINE = MergeTree PARTITION BY toDate(ts) ORDER BY (event, user_id, ts);

INSERT INTO demo.events SELECT now() - (n % 7200), if(n%3=0,'click',if(n%3=1,'view','buy')),
  toUInt32(n % 500), toUInt32(n % 50) FROM (SELECT number AS n FROM numbers(100000));
INSERT INTO demo.events SELECT now() - (n % 7200) - 7200, if(n%3=0,'click',if(n%3=1,'view','buy')),
  toUInt32(n % 500), toUInt32(n % 50) FROM (SELECT number AS n FROM numbers(100000));

SELECT partition, name, rows FROM system.parts
  WHERE database='demo' AND table='events' AND active ORDER BY partition;
-- 预期：两次 INSERT = 两个 part，与行数无关；跨自然日分区时更多

ALTER TABLE demo.events UPDATE cost = 0 WHERE user_id = 7;
-- 预期：几乎立即返回——它没改任何数据，只登记了一条重写指令

SELECT database, table, command, is_done
  FROM system.mutations WHERE database='demo' AND table='events';
-- 预期：is_done=0 → 重写还在排队/进行；小表几秒翻 1，生产大表是小时级
-- is_done=1 之后，SELECT sum(cost) FROM demo.events WHERE user_id=7 才是 0
```

开头那三小时的谜底，就藏在最后两条命令之间：工单挂着，查询读到的还是旧 part。**ALTER UPDATE 改的不是数据，是重写队列里的一张工单。**

## 二、快是表象，不可变才是本性

列存为什么快，三件套一段带过：只读用到的列（分析查询常用 5~10 列，宽表上百列时 IO 差一个数量级）；同列类型相同、又按排序键物理排序，压缩编码近乎白送（行存 1x 的文本，列存 LZ4/ZSTD 后 5~10x 起步）；向量化执行一次算一批同类型的值。

这篇的重心在那句常被省略的前提：**数据按列装在不可变的 part 文件里**。不可变，就没有原地更新——改一行等于重写整个列块，取一行要把各列文件拼回来，点查比 3 层 B+ 树的 2 次页 IO 差几个数量级。

列存用「单行昂贵」换「一批极快」，而单行昂贵的一切账单，最后都由 merge 买单。

## 三、引擎族的差别：合并时对同键行做什么

MergeTree 底座一句话：写入只生成不可变 part，后台 merge 周期性把小 part 合成大 part（与 RocksDB/Paimon 同一棵 LSM 血统）。家族成员的差别只有一个维度——合并时对同排序键的行做什么：

| 引擎 | 合并时做什么 | 典型场景 |
| --- | --- | --- |
| MergeTree | 什么都不做，行永不合并 | 明细留存，读时聚合 |
| ReplacingMergeTree(ver) | 同排序键保留 version 最大一行 | 画像、订单状态 |
| SummingMergeTree | 同排序键数值列求和 | 预聚合指标 |
| AggregatingMergeTree | 按 AggregateFunction 状态合并 | 去重、复杂聚合 |

（前缀 Replicated* = 任一成员 + 副本复制，生产表都带，第七节一句带过。）

最常被误解的是 ReplacingMergeTree，三行数据就能看到脾气：

```sql
CREATE TABLE demo.user_state (user_id UInt32, balance UInt32, ver UInt32)
  ENGINE = ReplacingMergeTree(ver) ORDER BY user_id;
INSERT INTO demo.user_state VALUES (1,100,1),(2,50,1);
INSERT INTO demo.user_state VALUES (1,80,2);              -- 同主键新版本
SELECT count() FROM demo.user_state;                      -- 3：旧行还躺在 part 里
SELECT user_id, argMax(balance, ver) FROM demo.user_state
  GROUP BY user_id;                                       -- 1→80, 2→50：读时收敛的推荐姿势
SELECT count() FROM demo.user_state FINAL;                -- 2：FINAL 收敛，大表代价高
```

去重只发生在后台 merge 碰巧把新旧版本合进同一个 part 时——异步、不保证时机。**去重是 merge 的副产品，不是写入的承诺。**

「那查询全加 FINAL 不就完了？」——小表可以，大表 FINAL 是把收敛塞进每条查询的读路径，读放大直接写进 p99。生产姿势是查询侧 argMax/GROUP BY 现场收敛；非要写时收敛，第九节见分晓。

另一个表级决策：排序键（ORDER BY）是表定义里最重要的字段。它同时决定 part 内物理顺序（压缩率与扫描裁剪都吃它）、稀疏索引的内容、Replacing/Summing 的合并键。选错排序键 = 压缩差 + 查询全扫，属于「建表一秒钟、运维一整年」的决策。

## 四、主键不是索引：MySQL 直觉在这里全错

从 MySQL 过来最顽固的预期：PRIMARY KEY 能按 key 定位一行。ClickHouse 的主键（其实是 ORDER BY 的前缀）不是行级索引，是排序描述。

数据每 8192 行（index_granularity，自适应粒度默认开）划成一个 granule，主键索引只存每个 granule 的首键，体积是行数的 1/8192、常驻内存。

查询二分只能定位「哪些区间可能命中」，命中后解压整个 granule、扫过最多 8192 行；marks 文件（.mrk2）记每个 granule 在各列文件里的偏移。

```sql
EXPLAIN indexes = 1 SELECT count() FROM demo.events WHERE event = 'click' AND user_id = 7;
-- 预期：计划里 PrimaryKey 一栏显示 Selected M of N granules（M 远小于 N）
-- 裁剪的是粒度不是行：点查一个 user，要连带解压它的上万个邻居
```

按主键前缀做范围聚合极快，按主键点查单行比 B+ 树差几个数量级——点查明细请走 MySQL/Redis，别来碰运气。

不在排序键里的列，靠手工补 minmax / set / bloom_filter 跳数索引（按 GRANULARITY N 个数据粒度一块），它同样是「跳过不相关粒度」，不是定位行。且跳数索引只对建索引之后写入的数据生效，存量要 MATERIALIZE INDEX——整 part 重写，代价同级 mutation。

**主键裁剪的是粒度，不是行。**这一句能解释 ClickHouse 一半的性能玄学。

## 五、mutation 的账单：没有「改一行」，只有「重写一批」

第一节的工单这时能读全了。mutation（ALTER ... UPDATE/DELETE）走 part 重写队列：后台按 part 逐个重写，命中条件的行改掉、其余原样拷贝——WHERE 只圈中 1% 的行，也要重写整个 part。

所以大表 mutation 是小时级任务，变更管理要当批处理作业对待：排窗口、盯 system.mutations 的 is_done、留回滚预案。

三条纪律：

- 别用 mutation 做高频小修正：反复触发整 part 重写，【从业者判断】多数「补数据」场景换成重写一批新数据、或 ReplacingMergeTree 版本收敛更便宜。
- OPTIMIZE TABLE ... FINAL 是手工强制合并，同样重写全部数据——演示和急救用，别当日常操作跑。
- mutation 与 OPTIMIZE 都在抢后台 merge 的 IO 与线程，【从业者判断】高峰期发起等于给下一节的死亡螺旋加油。

**在 ClickHouse 里没有「改一行」，只有「重写一批」。**

## 六、too many parts：写入太碎的死亡螺旋

merge 的脾气最凶的一次外显，是直接拒写。每次 INSERT 至少产生一个 part，稳态下每分区 parts 数应是个位数；一旦写入产生 parts 的速度持续超过 merge 消化速度：

```text
高频小 INSERT（每秒 N 次 × 几百行）
   → 每分区 parts 数上涨（system.parts active、MaxPartCountForPartition）
   → 超软阈值：写入被故意 delay（parts_to_delay_insert）
   → 超硬阈值：INSERT 报错 "Too many parts (N). Merges are processing
     significantly slower than inserts."（parts_to_throw_insert，默认 300，以文档为准）
   → 上游 Flink sink 反压 → checkpoint 超时 → Kafka 消费 lag
```

治理四层：

- 攒批：单次 INSERT 至少万行或 MB 级，官方调优建议每表每秒不超过约一次 INSERT。
- 小写入方太多就开 async_insert，让服务端替你攒批。
- merge 跟不上时评估 background_pool_size 与磁盘 IO，而不是一味重试。
- 监控 MaxPartCountForPartition，持续上涨即预警，社区常用告警线在几百到一千。

Doris 的「too many versions」是同一个病在另一个引擎的名字：**微批太碎，部件数超过后台合并能力。**

## 七、双表架构：写入路径与一句带过的复制

ClickHouse 没有「一张表自动分布到所有节点」的形态，标准做法是双表：每个节点建本地表（真正存数据），再在每个节点建同名 Distributed 表当路由视图（不存数据，只记 cluster 名、目标本地表、分片键）。

INSERT 进 Distributed 表，它按分片键哈希把 block 劈开发往各分片本地表；SELECT 则 fan-out 到各分片、回发起节点汇聚。

写入路径三个要点：

- 默认异步：INSERT 先落发起节点的本地缓冲目录，后台再发各分片——发起节点在「落盘与送达之间」崩溃，这批数据可能丢。要不丢设 insert_distributed_sync=1，或接受 at-least-once 由上游重放。
- 重放幂等：副本表按 block 哈希去重（insert_deduplicate，窗口 replicated_dedup_window 有限），与 Doris 的 label 幂等同构；业务级幂等仍要 ReplacingMergeTree(version) 兜底。
- 扩容是手工活：新增分片只影响新写入的路由，历史数据不自动搬迁，规划期就要把分片数留足。

复制一句话带过：**复制不是集群级功能，是表引擎前缀。**ReplicatedMergeTree(zk_path, replica_name) 靠 ZK/Keeper 协调 merge 领选、复制日志与写入去重；Keeper 挂了副本表降级只读、merge 停摆，告警优先级与 etcd 同级。

zk_path 或 replica 名写错，轻则不复制（路径不同）、重则互删（同名副本互踢）——新集群第一周的经典事故。

## 八、物化视图：在写入路径上把聚合提前算掉

报表的正确姿势不是让明细表硬扛，而是 MV 预聚合。MV 挂在本地表的写入路径上：每个 insert block 进来，先过 MV 的 SELECT 算出聚合行、写入目标表，再落基表——语义与 Doris Aggregate 模型的「写时预聚合」相同。

区别是 CH 拆成「基表 + MV + 目标表」三件套自由拼装，也多了目标表引擎选错、两套 schema 漂移这类自找的运维面。

```sql
CREATE TABLE demo.event_agg (event String, cnt UInt64, cost_sum UInt64)
  ENGINE = SummingMergeTree ORDER BY event;
CREATE MATERIALIZED VIEW demo.events_mv TO demo.event_agg AS
  SELECT event, count() AS cnt, sum(cost) AS cost_sum FROM demo.events GROUP BY event;
-- 建完再 INSERT 一批，demo.event_agg 里出现按 event 的聚合行
```

三个工程要点：

1. 先建 MV 再写入。MV 只处理创建之后的数据；给存量表补 MV 用 POPULATE 在并发写入时会漏/重，生产别赌，走「新 MV + 手动回填 + 双写切换」。
2. count distinct 这类不可加聚合用 AggregatingMergeTree + AggregateFunction（写 uniqState()、查 uniqMerge()），SummingMergeTree 存不了中间态。
3. MV 触发 MV 可以成 pipeline，一层慢整条慢。

**MV 是拿写入路径的一点税，换 merge 与查询的整本账。**

## 九、与 Doris/StarRocks 的边界

选型答完性能，这张表决定的是夜里被告警吵醒的频率：

| 维度 | Doris / StarRocks | ClickHouse |
| --- | --- | --- |
| 数据修正 | Unique MoW 写时收敛，读路径干净 | Replacing 异步收敛 + FINAL 读放大；mutation 整 part 重写 |
| 副本修复 | FE 调度器自动 clone 补齐 | 表级自协商，盯 system.replicas 队列，无自动均衡 |
| 扩容 | BE 上线自动均衡 tablet | 历史数据手工迁移 |
| 元数据 | FE 内嵌，无外部依赖 | 无中心元数据，复制协调依赖外部 ZK/Keeper |

一句话：**Doris 的复杂度在组件，CH 的复杂度在每张表**——分片数、副本路径、排序键、引擎族、merge 参数全是表级决策，错误会在几百张表里各自复发。

单表极限聚合选 CH，多表 join、低运维成本选 Doris/StarRocks。人手少的团队，这是比 join 能力更硬的取舍依据。

## 十、现在就能做的三件事

第一，parts 体检，两条 SQL 看离螺旋多远：

```sql
SELECT name, value FROM system.asynchronous_metrics
  WHERE name = 'MaxPartCountForPartition';
-- 预期：持续上涨不回落 = 攒批纪律已经失守

SELECT database, table, command, is_done FROM system.mutations WHERE is_done = 0;
-- 预期：空。长期挂 0 的，就是你那张「改了没生效」的表
```

第二，审计写入批次：清点每张热点表的 INSERT 频次与单批行数，高于「每表每秒一次」的，攒批或开 async_insert。

第三，把 ReplacingMergeTree 表的查询过一遍 argMax/FINAL——还在裸 SELECT 的，迟早给你查出新旧两行。

（演示完清理：docker rm -f ch-solo。）

这套机制的底稿——MergeTree 家族对照、稀疏索引图解、too many parts 排障链、Replicated 双副本 lab——整理在我维护的开源学习库，GitHub 搜 sre-learning-hub，ClickHouse 章节附可复跑的 docker 演练。

评论区报个数：你见过跑得最久的 mutation 是多久？翻出 system.mutations 里 create_time 到 finish_time 的差值晒一晒，看看谁家的工单最史诗。
