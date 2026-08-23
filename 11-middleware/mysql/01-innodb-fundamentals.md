# 01 · MySQL 架构与 InnoDB 核心机制

> 模块：中间件-MySQL ｜ 建议时长：3 小时 ｜ 关联认证：—（CKA/CKS/PCA 无直接考点，但为 SRE 面试与线上排障核心知识）

## 学习目标

- 能解释 MySQL Server 层与存储引擎层的职责边界，以及一条 SQL 语句在两层之间如何流转
- 能操作：用 `SHOW ENGINE INNODB STATUS` 与 `information_schema` 观察 buffer pool、锁与线程状态
- 能解释聚簇索引与二级索引的关系，以及"回表"什么时候发生
- 能解释 redo log / undo log / binlog 三者的职责差异，以及两阶段提交为什么必须有
- 能排查：根据 MVCC 读视图原理判断"长事务为什么不删空间"一类问题

## 1. Server 层与引擎层分层

MySQL 采用典型的分层架构：Server 层负责"连接、解析、优化、执行调度"，存储引擎层负责"数据怎么存、怎么读、怎么锁"。这是它区别于多数一体式数据库的最大的架构特征。

```
                    ┌─────────────────────────────────────────┐
   客户端 ──TCP──▶  │              Server 层                   │
                    │  ┌──────────┐  ┌──────────┐  ┌────────┐ │
                    │  │ 连接器/   │ │ 解析器/   │ │ 优化器  │ │
                    │  │ 线程模型  │─▶│ 预处理器  │─▶│(选索引) │ │
                    │  └──────────┘  └──────────┘  └───┬────┘ │
                    │  ┌──────────┐  ┌──────────┐      │      │
                    │  │ 查询缓存  │  │ 执行器    │◀─────┘      │
                    │  │(8.0 已删) │  │(调用引擎) │────────┐    │
                    │  └──────────┘  └──────────┘        │    │
                    └────────────────────────────────────┼────┘
                                                         │  handler 接口
                    ┌────────────────────────────────────▼────┐
                    │            存储引擎层                    │
                    │  ┌────────┐ ┌────────┐ ┌──────────────┐ │
                    │  │ InnoDB │ │ MyISAM │ │ Memory/其他   │ │
                    │  └────────┘ └────────┘ └──────────────┘ │
                    └──────────────────────────────────────────┘
```

各层职责速记：

| 层 | 组件 | 干什么 | SRE 关注点 |
|---|---|---|---|
| Server | 连接器 | 鉴权、建连接、维护连接状态 | `max_connections`、`wait_timeout` |
| Server | 解析器/预处理器 | 词法语法分析、列权限校验 | 报错 `Unknown column` 在这一层 |
| Server | 优化器 | 决定用哪个索引、join 顺序 | `EXPLAIN` 的执行计划就是它的产物 |
| Server | 执行器 | 先鉴权表权限，再循环调用引擎接口 | `rows_examined` 统计在这里 |
| Server | binlog | Server 层日志，所有引擎共用 | 备份恢复、复制的基石 |
| 引擎 | InnoDB | 事务、行锁、崩溃恢复、MVCC | 本章主角，redo/undo 都在引擎层 |

关键认知：**binlog 是 Server 层的，redo/undo log 是 InnoDB 的**。这直接解释了后面"两阶段提交为什么需要"——两个独立的日志系统必须协调，否则主备数据会不一致。

### 连接与线程模型

MySQL 是**每连接一个线程**（thread-per-connection）模型，不是 Nginx 那种 event-driven 多路复用。这对运维的影响是直接而深刻的：

- 每个连接占用内存（sort buffer、join buffer、read buffer 按需分配，每个线程独立）
- 连接数高不等于压力大，但连接数高一定吃内存
- `max_connections` 打满时新连接报 `ERROR 1040 (HY000): Too many connections`
- 生产上通常前置 ProxySQL/MySQL Router 或应用侧连接池，把"并发连接"与"并发执行"解耦

```sql
-- [任意节点] 观察连接与线程
SHOW VARIABLES LIKE 'max_connections';
SHOW STATUS LIKE 'Threads_%';
-- Threads_connected：当前连接数
-- Threads_running：正在执行 SQL 的连接数（真正消耗 CPU 的部分）
-- Threads_created：历史创建过的线程数，若持续增长说明没有复用线程

SELECT id, user, host, db, command, time, state, info
FROM information_schema.processlist
WHERE command != 'Sleep'
ORDER BY time DESC;
-- time 单位是秒；一个 Query 挂 300 秒以上就要警惕
```

线程缓存（`thread_cache_size`）可以让断开后的线程复用，减少线程创建开销；但 8.0 默认配置在大多数场景已够用，不必手工调。

## 2. InnoDB 存储结构：页与 B+ 树

### 页（page）是一切的基本单位

InnoDB 所有的数据操作都以页为单位，默认 16KB（`innodb_page_size`，建库后不可改）。磁盘上的 `.ibd` 文件在逻辑上就是一棵棵按页组织的 B+ 树。

为什么是 16KB：一页能放下一棵 3 层 B+ 树的完整中间结构，使"一次页 IO 拿到一批有序数据"成为可能。树高 3 层通常能索引千万行（根节点常驻内存 → 2 次页 IO 命中任意一行）。

```
                ┌───────────────┐
                │  根页(常驻内存) │          1 次 IO 都不用
                └──────┬────────┘
              ┌────────┴────────┐
        ┌─────▼─────┐     ┌─────▼─────┐
        │ 中间节点页  │     │ 中间节点页  │        最多 1 次 IO
        └─────┬─────┘     └─────┬─────┘
     ┌────────┼───────┐       ┌─┴─────────┐
 ┌───▼───┐┌───▼───┐┌──▼────┐┌─▼────┐┌─────▼───┐
 │ 叶子页 ││ 叶子页 ││ 叶子页 ││叶子页 ││ 叶子页   │   最多再 1 次 IO
 │(数据行)││       ││       ││      ││         │
 └───┬───┘└───┬───┘└──┬────┘└─┬────┘└────┬────┘
     └────双向链表连接，范围扫描顺序读───────┘
```

叶子节点之间是**双向链表**，所以 `WHERE id BETWEEN 100 AND 200` 这类范围查询只需要定位到 100 所在页，然后沿链表顺序扫，不必再从根走一遍。

### 聚簇索引与二级索引

InnoDB 的表本身就是一棵按主键组织的 B+ 树（聚簇索引，clustered index），叶子页存的是**完整的行数据**。二级索引（secondary index）是另一棵树，叶子页只存"索引列 + 主键值"。

```
   聚簇索引(主键 id)                二级索引 idx_name(name)
        ┌─────┐                          ┌─────┐
        │  50 │                          │  Li  │
        └──┬──┘                          └──┬──┘
   ┌───────┴───────┐                ┌───────┴───────┐
 ┌─▼────┐       ┌──▼─────┐       ┌──▼────┐      ┌───▼────┐
 │id=1..│ ...   │id=51.. │       │Chen→3 │      │Wang→99 │
 │整行数据│       │整行数据 │       │Zhang→7│      │Li→50   │
 └──────┘       └────────┘       └───────┘      └────────┘
   叶子=完整行                       叶子=索引列+主键值
```

由此推出几个运维必知结论：

1. **回表（lookup）**：`SELECT * FROM t WHERE name='Li'` 走 idx_name 只能拿到主键值 50，必须再回聚簇索引树查一次完整行。两次树查找，代价翻倍。
2. **覆盖索引**：如果查询的列全在二级索引里（如 `SELECT id, name FROM t WHERE name='Li'`），就不用回表，`EXPLAIN` 的 Extra 会显示 `Using index`。高频查询优先做覆盖索引，是排障时最常给出的优化手段。
3. **主键要短且有序**：每个二级索引的叶子都存一份主键值，主键越长所有索引都越胖；主键乱序（如 UUID v4）会导致聚簇索引频繁页分裂，写放大严重。推荐自增 ID 或有序 UUID。
4. **没有主键也会有一棵**：InnoDB 会用第一个非空唯一索引代替；实在没有就生成隐藏的 `ROW_ID`（全局共享，竞争大），生产表必须显式建主键。

## 3. redo log、undo log 与 WAL

### WAL：先写日志再写数据

InnoDB 遵循 Write-Ahead Logging：事务提交时**只把修改顺序追加（append）到 redo log 并 fsync**，被修改的数据页（脏页）可以之后再慢慢刷回磁盘。redo log 是物理日志（"某页某偏移改成了什么"），体积小、顺序写，把随机写转化成了顺序写——这是 InnoDB 高吞吐的根本。

```
   事务提交
      │
      ▼
  ┌────────┐  顺序追加,快   ┌──────────┐
  │ redo log│─────────────▶│ 磁盘文件   │   提交即持久化(crash-safe)
  │ buffer  │  (innodb_flush_log_at_trx_commit=1 时每次提交 fsync)
  └────────┘
      │ 之后某时刻
      ▼ 异步/达到阈值时
  ┌────────┐   随机写,慢    ┌──────────┐
  │ 脏页     │─────────────▶│ 表空间 .ibd│
  │(buffer  │
  │  pool)  │
  └────────┘
```

redo log 是固定大小的环形文件组（如 4 个 1GB 的 `ib_logfile0..3`，8.0.30 起由 `innodb_redo_log_capacity` 控制），写满一圈必须推进 checkpoint 强制刷脏——这就是著名的"红色水位"：**redo 空间不足时写入会被卡住**，表现为吞吐骤降。

### undo log：回滚与 MVCC 的基石

undo log 是逻辑日志（"插入的反向是删除"），两个用途：

1. **事务回滚**：rollback 时按 undo 反向执行，恢复到事务前状态
2. **MVCC**：旧版本数据不靠复制多份存储，而是"当前行 + undo 链"拼出来的历史版本

```
  UPDATE t SET name='Wang' WHERE id=50;  -- 提交后原始行并未消失

  最新行: id=50, name='Wang', trx_id=120, roll_ptr ──┐
                                                    ▼
                              undo 记录: name='Li', trx_id=95, roll_ptr ──┐
                                                                        ▼
                                      undo 记录: name='Zhang', trx_id=80, roll_ptr=NULL
```

读旧数据时沿 `roll_ptr`（回滚指针）在 undo 链上往回走。**只要还有事务可能要读这些旧版本，undo 就不能删**——这就是"长事务拖垮磁盘"的原理：一个跑了几小时的只读事务会让 purge 线程无法清理 undo，`ibtmp`/undo 表空间持续膨胀。

### MVCC 读视图（Read View）

RC（Read Committed）与 RR（Repeatable Read，默认）在 InnoDB 里都靠 MVCC 实现快照读，区别只在于 **Read View 的生成时机**：

| 隔离级别 | Read View 生成时机 | 效果 |
|---|---|---|
| RC | **每条语句**开始时生成 | 同事务内两次 SELECT 可能看到不同数据（不可重复读） |
| RR | **事务第一条快照读**时生成，之后复用 | 整个事务看到同一个快照，可重复读 |

Read View 记录生成时刻的活跃（未提交）事务列表，判断 undo 链上某个版本对当前事务是否可见的规则：版本的 `trx_id` 小于最小活跃事务 → 可见；大于下一个事务 id → 不可见；在活跃列表里 → 不可见，继续沿 roll_ptr 回溯。普通 SELECT 是快照读不加锁；`SELECT ... FOR UPDATE` / `LOCK IN SHARE MODE` 是当前读，直接读最新版本并加锁。

### change buffer

对**非唯一二级索引**的 INSERT/UPDATE，如果目标页不在 buffer pool 里，InnoDB 可以不立刻读盘，先把变更缓存在 change buffer 里，等该页后来被读到时再合并（merge）。好处是减少随机读 IO；代价是该页读取时要做 merge。写多读少场景收益大；`innodb_change_buffer_max_size` 控制其在 buffer pool 中占比（默认 25%）。唯一索引不适用——必须读页判断唯一性，change buffer 无从谈起。

## 4. 三大日志职责对比与两阶段提交

| 维度 | redo log | undo log | binlog |
|---|---|---|---|
| 所属层 | InnoDB 引擎层 | InnoDB 引擎层 | Server 层 |
| 逻辑/物理 | 物理（页级变更） | 逻辑（反向操作） | 逻辑（SQL/行变更） |
| 主要用途 | 崩溃恢复、WAL | 回滚、MVCC | 备份恢复、复制 |
| 写入方式 | 固定文件环形追加 | undo 表空间 | 文件序号递增，可设置过期 |
| 谁消费它 | 崩溃后的 crash recovery | purge 线程、回滚 | 备从库 IO 线程、恢复工具 |
| 是否所有引擎共享 | 否 | 否 | 是 |

### 两阶段提交为什么必须有

考虑 UPDATE 提交时 redo 和 binlog 各自落盘。若两者无协调顺序，就可能出现：

- **先写 redo 后 crash、binlog 没写**：主库恢复后事务存在，但从库没收到 binlog——主多数据
- **先写 binlog 后 crash、redo 没写**：主库恢复后回滚了事务，但 binlog 已发到从库——从多数据

InnoDB 的解法是**内部 XA / 两阶段提交**，以 binlog 写入成功作为事务提交的"外部坐标"：

```
  1. redo log 写入并标记 prepare     ── 阶段一
  2. 写 binlog 并 fsync
  3. redo log 标记 commit            ── 阶段二(可延迟组提交)

  崩溃恢复规则:
    redo 处于 commit         → 事务提交,无歧义
    redo 处于 prepare        → 去 binlog 找该事务的 XID
        binlog 完整存在      → 提交(以 binlog 为准)
        binlog 不存在/不完整 → 回滚
```

正因为以 binlog 为最终裁决，**"binlog 落盘了的事务才算提交"** 才成立，主备才能用 binlog 达成一致。`sync_binlog=1` + `innodb_flush_log_at_trx_commit=1`（俗称"双 1"）保证任一宕机都不丢已提交事务，是金融级标配。

## 5. buffer pool 与刷脏

buffer pool 是 InnoDB 在内存中的页缓存，读命中免 IO，写先改内存页（变脏页）再异步刷。`innodb_buffer_pool_size` 是 MySQL 头号参数，通常给到专机内存的 50%~70%。

```sql
-- [任意节点] 观察 buffer pool 命中率与脏页
SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read%';
-- Innodb_buffer_pool_reads      : 物理读次数(未命中)
-- Innodb_buffer_pool_read_requests: 逻辑读次数
-- 命中率 = 1 - reads/read_requests,健康实例应 > 99%

SELECT POOL_ID, PAGES_DATA, PAGES_DIRTY, PAGES_FREE,
       ROUND(PAGES_DATA*16/1024) AS data_mb
FROM information_schema.INNODB_BUFFER_POOL_STATS;
```

改进的 LRU（young/old 两区，约 5/95 分割）防止全表扫描或 mysqldump 一次性访问把热数据全冲掉：新读入的页先进 old 区头部，在 `innodb_old_blocks_time`（默认 1 秒）内再次被访问才升入 young 区。

刷脏（把脏页写回 `.ibd`）由后台线程负责，触发条件四条：redo 快写满（checkpoint 推进）、脏页占比超过 `innodb_max_dirty_pages_pct`、buffer pool 不足要淘汰脏页、正常空闲时顺手刷。刷脏速度跟不上写入速度时，用户线程会被拉去帮忙刷脏（`innodb_page_cleaners`、`innodb_io_capacity` 相关），表现为 UPDATE 突然集体变慢——磁盘 IO 能力不足的经典信号。

```sql
-- [任意节点] 一眼看脏页压力
SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_wait_free';
-- 非 0 且增长 = 有线程在等刷脏腾页,IO 已成瓶颈
```

## 实战演练

环境：装有 Docker 的 Ubuntu VM。目标：把本章的概念在实例里"看到"。

```bash
# [Ubuntu VM] 起一个 8.0 实例,限制内存模拟真实配置
docker run -d --name mysql-learn -e MYSQL_ROOT_PASSWORD=root123 \
  -p 3306:3306 -m 2g mysql:8.0 \
  --innodb-buffer-pool-size=512M --innodb-redo-log-capacity=256M
```

```bash
# [Ubuntu VM] 进入容器
docker exec -it mysql-learn mysql -uroot -proot123
```

```sql
-- [容器内] 建表造数据,观察索引行为
CREATE DATABASE shop;
USE shop;
CREATE TABLE orders (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  user_id BIGINT NOT NULL,
  status TINYINT NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  created_at DATETIME NOT NULL,
  KEY idx_user (user_id),
  KEY idx_user_status (user_id, status)
) ENGINE=InnoDB;

-- 用存储过程灌 10 万行
DELIMITER $$
CREATE PROCEDURE seed()
BEGIN
  DECLARE i INT DEFAULT 1;
  WHILE i <= 100000 DO
    INSERT INTO orders(user_id, status, amount, created_at)
    VALUES (FLOOR(RAND()*10000)+1, FLOOR(RAND()*4),
            ROUND(RAND()*500,2), NOW() - INTERVAL FLOOR(RAND()*720) HOUR);
    SET i = i + 1;
  END WHILE;
END$$
DELIMITER ;
CALL seed();
```

```sql
-- [容器内] 实验 1:回表 vs 覆盖索引
EXPLAIN SELECT * FROM orders WHERE user_id = 42;
-- Extra 无 Using index → 需要回表

EXPLAIN SELECT id, status FROM orders WHERE user_id = 42;
-- Extra 显示 Using index → idx_user_status 覆盖了 id+user_id+status,免回表

-- 实验 2:最左前缀
EXPLAIN SELECT * FROM orders WHERE status = 2;
-- type=ALL 全表扫描:idx_user_status 缺少左列 user_id,用不上
```

```sql
-- [容器内] 实验 3:长事务阻塞 purge 的可视化
BEGIN;
SELECT * FROM orders WHERE id = 1;          -- 开启 Read View
-- 另开会话大量 UPDATE 后观察
SELECT trx_id, trx_started, trx_mysql_thread_id
FROM information_schema.innodb_trx
ORDER BY trx_started;
-- 长时间不提交的事务会一直挂在这里

COMMIT;  -- 记得提交,否则 undo 持续堆积
```

验证方法：实验 1 的两个 `EXPLAIN` 输出中，第二个 Extra 列出现 `Using index` 即覆盖索引生效；实验 3 提交后 `innodb_trx` 表清空。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| UUID 做主键写入越来越慢 | 乱序主键导致聚簇索引页分裂 | 换自增 ID 或有序 UUID（如 UUIDv7） |
| 磁盘占用只增不减 | 长事务阻碍 purge，undo 无法回收 | `KILL` 长事务；应用侧设置 `max_execution_time` |
| `SELECT COUNT(*)` 全表扫描慢 | COUNT 需要遍历可见行，没有捷径计数 | 接受它或用近似值（`information_schema.TABLES` 的 `TABLE_ROWS`） |
| 半夜批量 UPDATE 后白天查询变慢 | 脏页集中刷盘挤占 IO | 拆小批次；调 `innodb_io_capacity` 匹配磁盘真实能力 |
| 二级索引列选择性差但建了索引 | 优化器算出走索引不如全表扫 | 索引设计看区分度与查询模式，不是越多越好 |
| 误以为 `innodb_flush_log_at_trx_commit=2` 数据更安全 | 2 只写 OS 缓存，os crash 丢 1 秒事务 | 只在可容忍丢失时用 2，重要库坚持双 1 |

## 自测

1. 为什么 `SELECT * FROM t WHERE name=?` 比 `SELECT id FROM t WHERE name=?` 慢得多，即使走的同一个索引？

<details><summary>答案</summary>

前者二级索引命中后只能拿到主键值，必须回到聚簇索引再查一次完整行（回表），两次树查找；后者的所有请求列都在二级索引里，直接返回（覆盖索引），一次树查找，且索引比整行窄得多、单页能放更多条目，IO 效率更高。
</details>

2. 如果没有两阶段提交，先写 binlog 后写 redo，一次 crash 会造成什么具体后果？

<details><summary>答案</summary>

binlog 已落盘但 redo 未写，恢复时主库回滚该事务；而 binlog 已被发往从库（或备份已包含它），从库执行了这条变更。结果是主库少、从库/备份多，且这种不一致不会报错，直到某天读从库发现"主库上查无的数据"才暴露。
</details>

3. RR 隔离级别下，事务 A 开启后先 SELECT 一次，之后别的会话 COMMIT 了大量改动，A 再次 SELECT 看到的是新数据还是旧数据？为什么？

<details><summary>答案</summary>

旧数据。RR 下 Read View 在事务第一条快照读时生成并一直复用，后续读都用这个视图判断可见性；别的事务后来提交的版本 trx_id 大于视图的高水位，判定不可见，A 沿 undo 链回溯到自己开视图前的版本。这也是长事务占用 undo 的根源。
</details>

4. buffer pool 命中率 99.9%，但 `Innodb_buffer_pool_wait_free` 持续增长，瓶颈在哪？加内存有用吗？

<details><summary>答案</summary>

瓶颈在写路径而非读路径：脏页产生速度超过后台刷脏速度，淘汰脏页前必须先刷盘，线程开始等待。加内存只能延缓脏页积累，治标；要么提升磁盘 IO 能力（SSD/更高 IOPS），要么调大 `innodb_io_capacity` 系列参数匹配硬件，要么降低写入速率（如拆分批量任务）。
</details>

5. 为什么 mysqldump 全库导出时，如果不用 `--single-transaction`，线上一张热表会被长时间锁住或数据不一致？

<details><summary>答案</summary>

默认情况下 mysqldump 对每张表加读锁保证一致性快照，热表写入被阻塞；而 `--single-transaction` 利用 InnoDB MVCC，在 RR 下开启一个事务拿 Read View 后全库读旧版本，不加锁又逻辑一致。前提是全部表为 InnoDB——MyISAM 表不适用 MVCC，仍需锁表。
</details>

## 延伸阅读

- MySQL 8.0 官方手册 InnoDB Architecture：https://dev.mysql.com/doc/refman/8.0/en/innodb-architecture.html
- 官方手册 Buffer Pool：https://dev.mysql.com/doc/refman/8.0/en/innodb-buffer-pool.html
- 官方手册 Redo Log：https://dev.mysql.com/doc/refman/8.0/en/innodb-redo-log.html
- 官方手册 The Change Buffer：https://dev.mysql.com/doc/refman/8.0/en/innodb-change-buffer.html
