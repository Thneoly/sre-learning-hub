---
title_juejin: 'DELETE 一百万行，表反而更大了：PG 的膨胀账'
title_zhihu: '删掉的数据不会消失，只会变成死元组：PostgreSQL 为什么越删越大'
description: 'PG 没有 undo：DELETE 只给行盖 xmax 戳，旧版本躺成死元组。附 autovacuum 触发公式、xmin 水位三大元凶、dead_pct 监控口径与 pg_repack 在线收缩。'
category_id: "6809637769959178254"
tags: "后端,数据库"
column_id: "7686472562230312970"
---

# DELETE 一百万行，表反而更大了：PG 的膨胀账

> （构造典型案例，细节已脱敏）周四凌晨，数据治理任务删掉了 180 万行过期订单，任务日志一片绿色。周一早上磁盘水位告警：那张表比删除前还大了 3GB。值班同学的第一反应是监控坏了——DELETE 还能把表删大？

监控没坏。在 PostgreSQL 里这不难解释，甚至是设计使然：删掉的数据没有离开表，它们只是变成了肉眼看不见的死元组。这篇把这笔"膨胀账"从头算到尾：MVCC 的实现选择、autovacuum 的触发公式、xmin 水位的三大元凶、监控口径，与收缩手段的锁代价。

## 一、先复现：几条命令看见"删了不变小"

不用等事故，五分钟就能在任意实例上复现：

```sql
-- [任意节点] 10 万行小表
CREATE TABLE bloat AS SELECT g AS id, 'v1' AS v FROM generate_series(1,100000) g;
SELECT pg_size_pretty(pg_total_relation_size('bloat'));   -- 约 4~5MB
UPDATE bloat SET v='v2';                                   -- 全表更新
SELECT pg_size_pretty(pg_total_relation_size('bloat'));   -- 接近翻倍：旧版本全留在表里
VACUUM bloat;                                              -- 手动清死元组
SELECT pg_size_pretty(pg_total_relation_size('bloat'));   -- 几乎不变：只标记可复用
VACUUM FULL bloat;                                         -- 生产勿模仿，原因见第五节
SELECT pg_size_pretty(pg_total_relation_size('bloat'));   -- 回落：整表被重建了
```

更新后翻倍、VACUUM 后不动、FULL 后回落——三个读数是三个机制的预告片。把 UPDATE 换成"删掉部分行"的 DELETE，后两个照样成立：被删的行同样只变成死元组，空间照旧等 vacuum 处理（例外：被删空的页若恰在文件末尾，普通 vacuum 能直接截断，整表 DELETE 就是这种特例）。

开头那个"删完反而更大"的案子也落在这条机制上：被删行的空间要等 vacuum 扫过、登记进 FSM（空闲空间映射）之后，才能被新的插入复用；在那之前，新写入用尽既有空闲空间后只能追加新页——删除刚跑完、vacuum 还没轮到的窗口里，表的体积确实会继续涨。

**"删了"到"小了"，隔着一整个 vacuum 的调度周期。**

## 二、根因：MVCC 选了"旧版本留在表里"

一切源于 PG 的一句架构宣言：**PG 没有 undo 回滚段**。

每个元组头部有四个系统字段，运维最常看前三个：xmin（创建它的事务 ID）、xmax（删除或更新它的事务 ID，0 表示还活着）、ctid（物理位置，被更新时指向新版本）。

所谓 UPDATE，实际是"写一个完整的新元组，再给旧元组盖一个 xmax 戳"；所谓 DELETE，只是盖章，行一个字节都不挪。旧版本必须原地保留，直到没有任何快照可能再看到它为止。

拿第一节的表验证：UPDATE 后查出 xmin 已换成新事务 ID；旧版本在结果集里永远查不出来，但磁盘知道它在。

这个设计的红利是回滚：ROLLBACK 只在 clog 里把事务标记为 aborted，跑了两小时的大事务回滚也近乎瞬时，不像 InnoDB 要顺 undo 链反向执行。代价是：**回滚和删除一样，垃圾全留在表里**，清理被整体外包给 vacuum。

顺带破一个误会：回滚"秒完成"不代表空间回来了——回滚产物照样是死元组，照样等 vacuum。

"删了就该小"的直觉来自 InnoDB：旧版本放在独立的 undo 表空间，由 purge 线程清走，undo 表空间还能收缩，表的主体不含历史版本。PG 把历史版本混在数据页里，想缩文件就得整表重建。**InnoDB 搬走旧版本，PG 就地改个标记**——空间还占着，空洞原地趴着。

## 三、死元组的账单：表付一遍，索引付 N 遍

伤害分两层。堆表层：死元组散布页内形成空洞，同样一百万行活数据要读更多页；且文件只在末尾整页为空时截断，页中间的空洞连 vacuum 也不消除。

索引层账更狠。一次 UPDATE 产生一个新元组版本：只要更新涉及任何索引列、或新版本塞不进原页，**每个索引都要追加一个指向新位置的索引项**——表膨胀一倍，全部索引各膨胀一倍，索引总膨胀通常大于表。"索引比表先撑爆"是常态。

有个绕行机制叫 HOT 更新：更新的列不被任何索引引用、且新版本能塞进同一页时，只动堆不动索引。工程推论很直接：**别把高频更新的列建进索引**，那等于给膨胀加速器加油。

还有一笔隐性税：Index Only Scan。即使索引覆盖全部所需列，PG 仍可能回堆检查可见性——只有页被 vacuum 在 visibility map 里标记 all-visible，才真正免回堆。

vacuum 一落后，覆盖索引查询悄悄退化成回堆扫描，Heap Fetches 飙升——你以为是索引建错了，其实是 vacuum 欠的账。**vacuum 不只是扫地，它还在维护访问路径**。

## 四、autovacuum 的触发公式：大表总排不上队

日常清理由 autovacuum 后台代劳，每张表独立判断（PG13+ 对 insert 型另有阈值）：

```text
vacuum 触发阈值 = autovacuum_vacuum_threshold(默认 50)
                + autovacuum_vacuum_scale_factor(默认 0.2) × n_live_tup
n_dead_tup 超过阈值 → 排队（naptime=60s 轮询，max_workers=3 分活）
```

替 1 亿行的表算算：要攒够 2000 万死元组才触发；期间每次扫描都在白读死元组。触发了也未必马上干——全场默认 3 个 worker，表多的实例里大表还要排队等轮询。

标准动作是按表收紧，不动全局：

```sql
-- [任意节点] 高频更新大表单独收紧
ALTER TABLE orders SET (
  autovacuum_vacuum_scale_factor = 0.02,   -- 200 万死元组即触发
  autovacuum_vacuum_threshold = 1000
);
-- insert 型大表另配 autovacuum_vacuum_insert_*，偏 freeze 与 all-visible 维护
```

**scale_factor 是比例税：表越大，起征点越高**，死元组的绝对积压就越大。默认 0.2 是给中小表的，大表必须单独谈。

## 五、收缩的代价分层：三种手段，三档锁

已经膨胀的表想真正缩回去，先把这张表背下来：

| 手段 | 锁级别 | 空间 | 时间 |
| --- | --- | --- | --- |
| VACUUM | SHARE UPDATE EXCLUSIVE（不挡读写） | 只标记复用 | 快 |
| VACUUM FULL | ACCESS EXCLUSIVE（读写全停） | 重建文件，真正缩小 | 表越大越久 |
| pg_repack | 仅起止瞬间短暂锁 | 在线重建，等效收缩 | 约为 VACUUM FULL 数倍 |

普通 VACUUM 拿的 SHARE UPDATE EXCLUSIVE 只与表级 DDL 冲突，读写照常——所以它可以也应该频繁跑。但它只把空闲空间登记进 FSM 供后续插入复用；文件只在末尾整页为空时截断，中间的空洞不消除。

VACUUM FULL 是另一个物种：把整表拷进新文件再改名，全程 ACCESS EXCLUSIVE——**连 SELECT 都进不来**（与 ALTER TABLE、DROP、TRUNCATE 同一档锁，pg_locks 里查 mode 能看到）。它还需要等量的额外磁盘，索引全部重建，表越大跑得越久。

白天对生产大表执行它，等于主动制造一次人为停机，锁队列里身后所有想读这张表的会话一起被挡。

pg_repack 用"影子表 + 触发器记增量，拷贝存量，回放增量，短锁切换"在线完成同一件事，思路与 MySQL 生态的 gh-ost/pt-osc 完全同构，只是增量来源换成触发器或逻辑复制，耗时约为 VACUUM FULL 的数倍：

```bash
# [任意节点] 库内先建扩展；客户端工具从 PGDG 源装（包名随大版本变）
psql -h 127.0.0.1 -U postgres -d app -c "CREATE EXTENSION pg_repack;"
pg_repack -h 127.0.0.1 -p 5432 -U postgres -d app -t orders
```

顺序永远是：先让 vacuum 追得上、清掉阻碍者，收缩留给病入膏肓的表——参数与监控做在前面，多数表一辈子不需要 repack。

## 六、xmin 水位被谁压住：膨胀失控的三大元凶

排障里最常见的迷案：autovacuum 明明显示在跑，n_dead_tup 却不降。机理一句话：**vacuum 只能回收比最老活跃快照更老的死元组**。某个连接持着两小时前的快照，那之后产生的死元组一个都动不了——这个下界就是 xmin horizon。压住它的元凶，按出场频率排三个。

元凶一：长事务与 idle in transaction。开了事务不提交的连接是头号罪犯，既阻碍 vacuum 又持锁。定位与处置：

```sql
-- [任意节点] 杀事务年龄超 5 分钟的空闲事务（先跑同款 SELECT 留证据再杀）
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE state LIKE 'idle in transaction%' AND now()-xact_start > interval '5 min';
-- 兜底参数：只杀"事务中"的空闲（对应 MySQL 的 wait_timeout 思路）
ALTER SYSTEM SET idle_in_transaction_session_timeout = '300s';
SELECT pg_reload_conf();
```

元凶二：废弃复制槽。CDC 或备库断连后忘删的槽 pin 住一个老 LSN，vacuum 同样不能越过——WAL 目录随之暴涨，"pg_wal 磁盘告警"和"死元组不降"常是同一个病。

查法：【从业者判断】跑 `SELECT slot_name, active FROM pg_replication_slots;`，inactive 且不再使用的槽就是遗留。

删法：用 `SELECT pg_drop_replication_slot('槽名');` 删掉，并给 `max_slot_wal_keep_size` 设个兜底上限。

元凶三：收敛参数太保守、worker 不够。即使没有阻碍者，0.2 的默认阈值也让大表攒两千万死元组才动手；表一多、worker 只有 3 个，回收速度天然追不上写入。这不是故障，是配置没跟着数据规模走。

顺带一条同源战线：xid 回卷。vacuum 的 freeze 动作负责把老元组标记为"永远可见"，三级防线的第一级在 age 2 亿触发；这条线被阻碍的后果比 bloat 更重——系统直接只读。**长事务压住的不只是磁盘，还有事务 ID 的寿命。**

## 七、监控口径：dead_pct、n_dead_tup 与 age

膨胀监控，两条口径就够用。

第一条，死元组占比，看 `pg_stat_user_tables`：

```sql
-- [任意节点] bloat 体检：死活元组比 + 体积
SELECT relname, n_live_tup, n_dead_tup,
       round(100.0*n_dead_tup/nullif(n_live_tup,0),1) AS dead_pct,
       last_autovacuum, pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10;
-- dead_pct 持续 >20% 不回落 = 有阻碍者压着水位，或 worker 追不上
```

两个读数要联动看，最阴的一种是：last_autovacuum 一直在刷新，n_dead_tup 却纹丝不动——vacuum 在白跑，有阻碍者压着水位，回第六节抓人；若 last_autovacuum 很久没动，则是压根没触发或排不上队，去查阈值与 worker 数。

要精确到页内空洞，上 pgstattuple 扩展。exporter 对应指标 `pg_stat_user_tables_n_dead_tup`（按库聚合），判据同一句：**持续上涨不回落，就是 vacuum 有阻碍者**——单点数值没意义，趋势才有。

第二条，老化程度。这是 MySQL 转 PG 的运维最容易漏建的告警：

```sql
-- [任意节点] 库级与表级两张口径
SELECT datname, age(datfrozenxid) FROM pg_database ORDER BY 2 DESC;
-- 库级：exporter 回卷告警线 >1.5 亿 warning、>16 亿 critical
SELECT c.relname, age(c.relfrozenxid) AS xid_age,
       s.n_live_tup, s.n_dead_tup
FROM pg_class c
JOIN pg_stat_user_tables s ON s.relid = c.oid
WHERE c.relkind IN ('r','t','m')
ORDER BY 2 DESC LIMIT 10;
-- 表级：age 超过 1.5 亿就该警惕
```

最后一个纪律：别在监控脚本里比较裸 xmin——xid 是 32 位环形模比较，绝对值大小无意义，一律用 age()。

## 八、预答两个反方

"既然只有 VACUUM FULL 能真缩，膨胀了直接 FULL 一把梭？"三个字拦住你：锁、盘、时——ACCESS EXCLUSIVE 读写停摆、等量额外磁盘、索引全重建。白天对生产大表跑它就是人为停机；它留给维护窗口的小表，大表在线收缩交给 pg_repack。

"那把 scale_factor 全局调成 0.001，让 vacuum 疯狂跑？"【从业者判断】过头了：vacuum 扫表本身吃 IO 与 CPU，触发过密等于拿写放大换洁癖，高峰期还与业务抢缓存。按表分级才是正解——重灾区收紧到 0.02 一档，安静的维表不动。

另外，整表过期的清理任务，【从业者判断】能用 TRUNCATE 就别 DELETE——它同样要拿 ACCESS EXCLUSIVE，放低峰执行。

## 九、教训与三件现在就能做的事

| 要点 | 一句话 |
| --- | --- |
| 根因 | PG 无 undo，删除只是盖 xmax 戳，旧版本原地躺平 |
| 触发 | 阈值 = 50 + 0.2 × n_live_tup，大表天然被歧视 |
| 阻碍 | 长事务、废复制槽压住 xmin horizon，vacuum 白跑 |
| 收缩 | VACUUM 不还空间，FULL 锁全表，在线收缩用 pg_repack |
| 监控 | dead_pct 持续 >20% 不回落；表级 age >1.5 亿警惕 |

第一件，对核心库跑第七节的体检 SQL，dead_pct 与 last_autovacuum 联动着看，五分钟定位你在哪个象限。

第二件，扫阻碍者：用 pg_stat_activity 抓最老的事务与 idle in transaction，再查一遍复制槽里有没有 inactive 的遗留。

第三件，给写入量 top 的表收紧 autovacuum 阈值，顺手确认 idle_in_transaction_session_timeout 已设——今天就能做完。

## 写在最后

这篇真正想留下的只有一句：**DELETE 删的是可见性，不是空间**。在 PG 的账本上，一次删除只是把行记成"待回收"；能不能收、何时收，取决于 vacuum 的排期、xmin 的水位和你的参数——任何一个掉链子，磁盘就只朝一个方向走。

把 vacuum 当一等公民监控和调参，而非黑盒默认值，"越删越大"就轮不到你的值班表。

实验、命令与告警规则整理自我维护的开源学习库——GitHub 搜 sre-learning-hub，PostgreSQL 章节附可复跑的 VM lab。你库里 dead_pct 最高的一张表现在多少？评论区晒个数，看看谁的家底最厚。
