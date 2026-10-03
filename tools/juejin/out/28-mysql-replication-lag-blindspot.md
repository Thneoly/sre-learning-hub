---
title_juejin: 主从延迟 0 秒的谎言：SBM 的三个盲区
title_zhihu: 主从延迟显示 0 不等于没延迟：Seconds_Behind_Master 骗人的三个场景
description: SBM 只量重放差、不量传输差：断连假 0、大事务跳变、并行复制读数偏小，三个盲区。附读写分离读旧数据事故链、GTID 断点定位、semi-sync 降级与关键读强制走主。
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686472562230312970"
---

# 主从延迟 0 秒的谎言：SBM 的三个盲区

（构造典型案例，细节已脱敏）周一早高峰，运营在群里 @DBA：后台改完商品价格，小程序还是旧价，刷新十次，第十一次才对。DBA 打开监控大盘——主从延迟 0 秒，曲线平得像停机。

两边都没说谎：用户确实读到了旧数据，SBM（Seconds_Behind_Master，监控里的主从延迟秒数）也确实是 0。这篇讲清楚这个 0 是怎么算出来的、它在哪三种场景里系统性失真，以及"写完读不到"这条事故链怎么断。

## 一、先搞清它在量什么：一把只量半程的尺子

复制的本质是"主库把 binlog 发给从库重放"，三线程各司其职：

```text
主库：客户端写入 → binlog 顺序追加
      → Binlog Dump 线程按从库要的位点推送
从库：IO 线程收日志 → 写入 relay log（从库本地收件箱）
      SQL 线程读 relay log 重放 → 记录已执行位点
```

两个要点：dump 线程跑在主库，IO/SQL 线程都跑在从库；relay log 是收件箱，IO 写、SQL 读，两边速率可以不同——延迟就诞生在这个剪刀差里。

SBM（8.0 输出行改叫 Seconds_Behind_Source，旧名沿用至今）的语义一句话：**最新收到的事件时间戳 − 正在重放的事件时间戳**。看出问题了吗——被减数和减数都是从库已经到手的日志。

它量的是"收到的日志重放掉多少"，没收到的部分一个字都不提。

```sql
-- [从库] 状态体检，只看五条关键行（8.0 语法，旧版 SHOW SLAVE STATUS）
SHOW REPLICA STATUS\G
-- Replica_IO_Running: Yes      ← IO 线程活着，在收日志
-- Replica_SQL_Running: Yes     ← SQL 线程活着，在重放
-- Seconds_Behind_Source: 0     ← 延迟秒数，本文主角
-- Last_SQL_Errno: 0            ← 重放报错就停在这
-- Retrieved_Gtid_Set / Executed_Gtid_Set   ← 收了哪些 / 放完哪些
```

## 二、三个盲区：它什么时候在撒谎

### 盲区一：传输断了，它照样显示 0

SBM 的两个时间戳都取自已收到的日志。主从之间网络断了、且未触发重连检测，从库手里没有新日志，"最新收到"追平"正在重放"，SBM=0——此刻它实际落后主库多少，这个字段永远不打算告诉你。IO 线程真正断开被检测到时它变 NULL；重连恢复、追平之后又回到 0——断连期间实际落后了多少，这个字段从头到尾没记过账。

还有一种更常见的错位：SBM 没撒谎，撒谎的是大盘。读写分离下，客户端读的可能是另一台延迟更大的从库，或者命中了应用层/ProxySQL 缓存——监控里那台 0 延迟从库，和你实际读的那台，不是同一台。

### 盲区二：大事务期间的跳变

延迟成因里最经典的一条：一条跑 30 分钟的大 UPDATE。机制（【从业者判断】，素材只记录了现象）：binlog 顺序追加，大事务执行期间把后面所有事务压在主库；从库这段时间"无新账可收"，SBM 不涨；等事务提交、日志一泻而下，SBM 一步跳上千秒——阶梯式跳变，告警永远在事后才响。

对策只有一个字：防。主库拆事务，别让单事务跑几十分钟；重放端在不动 innodb_flush_log_at_trx_commit 的情况下无解。

### 盲区三：并行复制与时钟，读数先天不准

并行复制（LOGICAL_CLOCK）把事务分发给多个 worker 重放。【从业者判断】事件分发进 worker 队列后、执行完前，SBM 读数比真实积压偏小，高并行度下还会在 0 与大值之间震荡——把它当精确值看，本身就是误用。

时钟同理。【从业者判断】时间戳全部来自主库时钟，算法在 IO 空闲时还会拿从库当前时间参与计算，主从时钟一漂移，差值直接被污染——跨机器的时间戳减法，不配被信任到秒级。

一句话收束三个盲区：**SBM=0 是"收到的都放完了"，不是"和主库一致"**。

## 三、事故链：写完立刻读，读到旧值

异步复制下这条链是必然，不是概率：

```text
客户端在主库 commit 成功 → 立刻读从库
→ SQL 线程还没重放这个事务 → 读到旧值
→ 用户视角："我明明保存了，列表里没有"
```

对策按代价排序，四选一（或组合）：

| 手段 | 做法 | 代价 |
| --- | --- | --- |
| 关键读强制走主 | 写后 N 秒内同用户请求路由到主库（应用/代理层打标） | 主库读压力上升 |
| GTID 等待 | 拿 commit 返回的 GTID，读从库前等它重放完 | 每次读多一次等待 |
| 因果会话 | ProxySQL transaction_persistent / 驱动层 session 粘性 | 路由复杂度 |
| 只读主 | 账户类强一致操作干脆不读从 | 这类读全压主库，从库帮不上忙 |

最工程化的是第二招，语义精确：

```sql
-- [从库] 等指定事务重放完，最多等 1 秒
SELECT WAIT_FOR_EXECUTED_GTID_SET('3E11FA47-71CA-11E1-9E33-C80AA9429562:23', 1);
-- 返回 0 = 已重放完，可以放心读
-- 非 0 = 超时未到，此时读仍可能拿到旧数据
```

**读旧数据不是故障，是异步复制的出厂设定**；四招全是在用延迟或压力买一致性。

## 四、断点定位：位点 vs GTID

复制断了要接回去。传统位点复制用 (binlog_file, position) 对齐主从——手动找位点、切换主库极易出错。GTID 给每个事务全局唯一编号 server_uuid:seq，从库用 Executed_Gtid_Set 自动告诉主库"我缺哪些"：

```sql
-- [从库] GTID 挂载（前提：主从都开 gtid_mode=ON、enforce_gtid_consistency=ON）
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='172.30.30.10',
  SOURCE_USER='repl',
  SOURCE_PASSWORD='repl123',
  SOURCE_AUTO_POSITION=1;   -- 核心一行：自动对齐 GTID
START REPLICA;
```

运维质变在 failover：新主库的 Executed_Gtid_set 并集就是真相，Orchestrator/MHA 类工具全靠它选主补账。

重放报错（Last_SQL_Errno 1062/1032）时，SET GTID_NEXT 手工补一个空事务可跳过这类报错（1062 为重复键、1032 为记录缺失）；但数据真不一致时，重搭从库是唯一正解。GTID 的代价也要认：一个事务只允许在一个库上执行一次，"从库手工改数据"的野路子会直接报错——这是保护，不是缺陷。

**位点是"在第几页第几行"，GTID 是"缺哪几笔账"**——前者人肉对齐，后者从库自己报账。

## 五、修复：三个药治三种病，别互相替代

先对成因再下药，速查表：

| 成因 | 特征 | 对策 |
| --- | --- | --- |
| 单线程重放跟不上 | 延迟平稳增长，主库写入高峰陡增 | 开并行复制 |
| 大事务 | 阶梯式跳变 | 主库拆事务，只能防 |
| 从库机器差/IO 慢 | 换台机器就好 | 对等硬件；从库 flush 参数设 2 |
| 从库被重查询抢资源 | 延迟与慢查询时段吻合 | 分析查询挪走、读压力隔离 |
| 网络带宽不足 | IO 线程频繁重连，relay 增长慢 | binlog 压缩或升带宽 |
| 表缺主键（ROW 格式） | SQL 线程逐行更新做全表扫 | 所有表必建主键 |

注：flush 参数设 2 指从库 innodb_flush_log_at_trx_commit=2，用安全性换重放吞吐。

### 药一：并行复制，治"重放慢"

```ini
# [从库] my.cnf 或 SET GLOBAL，8.0 推荐组合
replica_parallel_type = LOGICAL_CLOCK     # 按事务组并行（默认）
replica_parallel_workers = 8              # SQL 线程的并行 worker 数
# [主库] 标记事务依赖：无行冲突的事务，从库才能拆给多个 worker 并行
binlog_transaction_dependency_tracking = WRITESET
```

顺带说透"无主键表拖垮从库"：ROW 格式重放按主键定位逐行更新，无主键表上每行事件都退化为全表扫描定位——主库一条没索引的 UPDATE 改 1000 行也只扫一次，从库重放是 1000 次 × 全表扫。数量级差距就是这么来的。注意：这病并行复制治不了，根治只有补主键（见上表末行）。

### 药二：semi-sync，治"宕机丢数据"

异步复制主库提交后不等从库，主库宕机时未发送的 binlog 事务永久丢失（RPO>0）。半同步让主库至少等一个从库 ACK 收到 binlog（rpl_semi_sync_master_wait_for_slave_count=1）才向客户端返回成功：

```sql
-- [主库] 启用 after_sync（8.0 默认 lossless）
INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';
SET GLOBAL rpl_semi_sync_master_enabled = 1;
SET GLOBAL rpl_semi_sync_master_timeout = 3000;   -- ms，超时降级异步
-- [从库] 装 rpl_semi_sync_slave 并 SET GLOBAL rpl_semi_sync_slave_enabled=1，
--        再重启 IO 线程才生效
```

两条边界必须知道。其一，超时自动降级回异步保可用性（timeout 默认 10s，上面示例改成了 3s）——半同步"时好时坏"多半是从库慢导致反复降级，先监控 Rpl_semi_sync_master_status，调 timeout 前先治从库延迟。

其二，半同步保证"binlog 已到达从库磁盘"，不保证"已重放完成"——主库宕机切换时，新主可能带着已收未放的事务，要靠 Orchestrator 类工具补齐。

所以半同步是"尽力而为的 RPO=0"，把丢失概率压到极低，不是绝对保证；要绝对不丢，得上 Group Replication 的多数派确认那类同步方案。

**并行复制治重放慢，semi-sync 治丢数据，走主治读旧值**——三个药治三种病，互不替代；semi-sync 开满也救不了"写完立刻读从库"。

## 六、监控：盯队列与前进性，别赌一个标量

四件事补齐，比一个 SBM 靠谱得多：

其一，逐台从库独立采集。你读的那台和大盘上那台，常常不是同一台。【从业者判断】大盘还常把多台从库聚合成一条平均或最大曲线，而读路径挑的是负载均衡里最快的那台——聚合口径和读路径口径对不上，是监控之外的第二层错位。

其二，看 Retrieved_Gtid_Set 是否还在前进，判 IO 链路死活：

```sql
-- [从库] 采样集合前进性
SHOW REPLICA STATUS\G      -- 记下 Retrieved_Gtid_Set 尾部序号
SELECT SLEEP(10);
SHOW REPLICA STATUS\G      -- 尾部没涨 = 日志没收进来，SBM 再绿也白搭
```

其三，盯收件箱剪刀差。"已收"与"已执行"两个位点的差值（队列深度）比单一秒数诚实——SBM 看不见的积压，全堆在这里。

其四，【从业者判断】要量端到端真延迟，用主库写心跳表、从库读的外部探针（pt-heartbeat 思路），量出来的才是"用户视角落后多久"。

**延迟监控的正解是队列深度加集合前进性**，SBM 只配当参考线，不配当唯一告警源。

## 七、预答两个反方

"开了半同步，读写分离是不是就稳了？"不是。semi-sync 的确认点到"落从库磁盘"为止，你的读要的是"已重放"，中间还隔着整个收件箱。该等的照等，该走主的照走。

"SBM 一无是处，直接下掉？"不必。趋势对照、复盘佐证它仍有用；错的是拿它当"主从一致"的同义词、当唯一告警源。降级成参考线，配上队列深度，它就老实了。判断一个延迟指标好不好，只看一件事：它量的那段路，是不是用户请求真走过的那段。

## 八、教训与三件现在就能做的事

| 要点 | 一句话 |
| --- | --- |
| 指标语义 | SBM 只量重放差，传输差根本没量 |
| 三个盲区 | 断连假 0、大事务跳变、并行与时钟先天不准 |
| 读旧数据 | 出厂设定而非故障，四招按代价选 |
| 断点 | GTID 让从库自己报缺账，failover 靠集合并集 |
| 用药 | 并行复制/semi-sync/强制走主，不可互替 |

第一件，在从库跑第一节那五行体检，顺手采两次 Retrieved_Gtid_Set。

第二件，扫无主键表（ROW 复制的隐形炸弹）：

```sql
SELECT t.table_schema, t.table_name
FROM information_schema.tables t
WHERE t.table_type = 'BASE TABLE'
  AND t.table_schema NOT IN ('mysql','sys','information_schema','performance_schema')
  AND NOT EXISTS (
    SELECT 1 FROM information_schema.table_constraints c
    WHERE c.table_schema = t.table_schema AND c.table_name = t.table_name
      AND c.constraint_type = 'PRIMARY KEY');
-- 有结果 = 每行重放都在全表扫，先补主键再谈延迟治理
```

第三件，测试环境亲手复现一次盲区二——先灌一张几十万行的测试表，然后：

```sql
-- [主库·测试环境] 造一条大事务（行数按表调）
UPDATE big_table SET pad = pad WHERE id <= 500000;
-- 执行期间盯一次从库，提交后再盯一次：
SHOW REPLICA STATUS\G
-- 预期：执行期间 SBM 几乎不动（主库尚未写 binlog）；
--       提交后 ROW 事件成片涌向从库，SBM 阶梯式跳升
```

亲眼看过一次"不动到跳升"，你对这个指标的所有侥幸就都没了。

## 写在最后

比"SBM 会骗人"更普适的一条：主从之间隔着传输、落盘、重放三段路，任何只盯一段的指标都撑不起"一致性"三个字。**一个标量概括不了一段分布式链路**——把监控补成逐台采集加队列深度，把关键读放在确定性上，0 秒延迟的谎言就没有生存空间。

复制链路图、跳错恢复与 lab 脚本整理自我维护的开源学习库——GitHub 搜 sre-learning-hub，MySQL 复制实验经真机验证。你见过最离谱的"延迟 0 秒"现场长什么样？评论区对个暗号。
