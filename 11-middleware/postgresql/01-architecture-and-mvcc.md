# 01 · PostgreSQL 架构与 MVCC：进程模型、WAL 与事务 ID

> 模块：中间件-PostgreSQL ｜ 建议时长：3 小时 ｜ 关联认证：—（CKA/CKS/PCA 无直接考点，但为 SRE 面试与线上排障核心知识；对比参照 11-middleware/mysql/01）

## 学习目标

- 能解释 PostgreSQL 每连接一进程的模型与 MySQL 每连接一线程的差异，以及它带来的连接成本与运维后果
- 能操作：用 `ps`、`pg_stat_activity`、元组头字段（xmin/xmax）直接"看到"进程模型与多版本数据
- 能对比 PG 的 WAL 与 InnoDB 的 redo/undo，说清"PG 没有 undo 回滚段"意味着什么
- 能解释 PG 与 InnoDB 两种 MVCC 实现的读写代价差异，以及各自"长事务拖垮系统"的机理为什么不同
- 能排查：根据事务 ID 回卷（wraparound）原理判断"age 指标为什么必须监控、vacuum 为什么必须活着"

## 1. 进程模型：每连接一个进程

PG 的服务端是一组协作的操作系统**进程**，不是线程池。守护进程 postmaster 监听 5432，每来一个 TCP 连接就 fork 一个 backend 进程，该连接的解析、优化、执行全部在这一个进程里完成；后台另有一组常驻进程各管一摊：

```
                        ┌──────────────────────────────────────┐
  客户端 ──TCP:5432──►  │ postmaster（守护进程，接客+fork）        │
                        └──┬──────────┬──────────┬─────────────┘
                           │fork      │fork      │fork
                    ┌──────▼──┐ ┌────▼─────┐ ┌──▼────────┐
                    │ backend │ │ backend  │ │ backend   │  每连接一个进程
                    │(会话1)  │ │(会话2)   │ │(会话3)    │  崩了只死自己
                    └─────────┘ └──────────┘ └───────────┘
   ┌────────────── 常驻后台进程（与连接数无关）──────────────┐
   │ checkpointer  bgwriter  walwriter  autovacuum launcher │
   │ logical replication launcher  walsender(每个备库一个)    │
   │ 统计信息：PG15 起放共享内存（不再有独立 stats collector） │
   └────────────────────────────────────────────────────────┘
```

与 MySQL 的"每连接一个线程"（见 11-middleware/mysql/01-innodb-fundamentals.md#1. Server 层与引擎层分层 的连接与线程模型一节）逐项对比：

| 维度 | PostgreSQL（进程） | MySQL（线程） |
|---|---|---|
| 新连接成本 | fork 一个进程，毫秒级 + 每进程数 MB 起步 | 建线程，便宜得多 |
| 连接内存 | 每进程独立地址空间，catalog 缓存等各自一份 | 线程共享地址空间，per-thread buffer 按需分配 |
| 稳定性 | backend 崩溃 postmaster 可隔离（杀掉全部连接重启） | 线程崩溃往往整个 mysqld 挂 |
| 上限体验 | 几千连接后调度/内存开销显著退化 | 几千连接可忍（配合 ProxySQL 更好） |
| 兜底手段 | pgbouncer（第 2 章专讲） | ProxySQL / MySQL Router |

运维后果很直接：**PG 对"直连数"远比 MySQL 敏感**。默认 `max_connections=100` 是个诚实的默认值；把应用几百个直连怼上来，最先死的是内存和上下文切换，而不是锁。这也是为什么 pgbouncer 在 PG 生态是准标配，而 MySQL 场景 ProxySQL 更多是为了路由与治理——原因在第 2 章展开。

另一个内存陷阱：PG 的 `work_mem` 不是"每连接一份"，而是**每个排序/哈希节点一份**（还要乘并行 worker 数）。一条查询三个排序节点就是 3×work_mem，`work_mem=64MB` 在 200 并发下就是潜在 38GB——盲目调大它和 MySQL 盲目调大 `sort_buffer_size` 是同款 OOM 元凶（见 mysql/03 的常见坑表）。

```sql
-- [任意节点] 观察连接与后台进程（对应 MySQL 的 SHOW PROCESSLIST）
SELECT pid, usename, application_name, backend_type, state,
       xact_start, query_start, wait_event_type, wait_event, left(query,60)
FROM pg_stat_activity
WHERE pid <> pg_backend_pid();
-- backend_type 区分 client backend / autovacuum worker / walsender 等
-- state: active / idle / idle in transaction（第 3 章排障的核心分型）
```

## 2. WAL：先写日志再写数据

PG 同样遵循 Write-Ahead Logging：事务提交时把变更先追加写进 WAL（`pg_wal/` 目录下按序号命名的 segment 文件，默认 16MB 一个），数据文件（`base/` 下的堆表/索引页）由后台进程之后慢慢刷。两者职责同 InnoDB 的 redo log（对照 mysql/01#3），但细节差异是排障时区分两套系统的关键：

| 维度 | PostgreSQL WAL | InnoDB redo log | InnoDB undo log | PG 的对应物 |
|---|---|---|---|---|
| 本质 | 顺序追加的变更日志 | 顺序追加的页级变更 | 反向操作，用于回滚与旧版本 | **没有** |
| 回滚怎么做 | 只在 clog（pg_xact）把本事务标记 aborted，垃圾留给 vacuum | 顺 undo 链反向执行，代价与事务大小成正比 | 同左 | PG 回滚近似 O(1)，但脏数据留在表里 |
| 旧版本放哪 | **就留在表里**（dead tuple） | 当前行 + undo 链拼出历史 | undo 表空间 | 表与索引膨胀的根源（第 3 章 vacuum） |
| 断页防护 | `full_page_writes=on`：checkpoint 后首次改某页时整页镜像记进 WAL | doublewrite buffer 先整页落盘 | — | 两种流派，同一个问题：半页写 |
| 文件形态 | `pg_wal/` 段文件循环复用（可归档） | 固定环形文件组（`innodb_redo_log_capacity`） | undo 表空间 | — |
| checkpoint | 周期触发，刷脏摊平（`checkpoint_completion_target=0.9`） | 同思路（redo 写满强制推进） | — | WAL 堆积报警时先想到它 |

"PG 无 undo 回滚段"是本模块最重要的一句话，推论链如下：

1. 回滚/旧版本**不搬走，就地标记**：UPDATE 永远是"写一个新版本 + 给旧版本盖 xmax 戳"，旧版本直到没有快照可能再看到它之前，必须原地保留；
2. 这些死元组（dead tuple）混在数据页里，把表和索引越撑越大；
3. 清理死元组靠 VACUUM，而 VACUUM 只能把空间**标记为可复用**，基本不还给操作系统；
4. 于是有了 PG 特有的病：**表膨胀（bloat）**、**事务 ID 回卷**、**长事务 + 复制槽拖死 vacuum** ——第 3 章整章建立在这句话上。

```
  事务提交路径（与 InnoDB 对照）
     │
     ▼
  WAL 先落盘（synchronous_commit=on 时每次提交 fsync，等价 MySQL 双 1 的 redo 半边）
     │
     ▼
  脏页由 bgwriter/checkpointer 之后刷回 base/
     │
     ▼
  崩溃恢复：从最近 checkpoint 起重放 WAL —— 所以 WAL 必须比数据先持久化
```

PG 没有 binlog 的对应物——复制、备份、PITR 全部直接消费 WAL（第 2 章）。MySQL 里"redo 与 binlog 两阶段提交"的复杂度（mysql/01#4. 三大日志职责对比与两阶段提交），PG 天生不存在：一份日志说了算。

## 3. MVCC 双实现：就地多版本 vs undo 链

每个元组（tuple）头部带四个系统字段，运维最常看的是前三个：`xmin`（创建它的事务 ID）、`xmax`（删除/更新它的事务 ID，0 表示还活着）、`ctid`（物理位置；被更新时指向新版本）。事务提交状态记在 clog 里，可见性判断 = snapshot + clog 联合查表。

同一个 `UPDATE t SET v='C' WHERE id=1`，两边各发生什么：

```
  PostgreSQL：就地多版本（旧版本不挪窝）
     页面内（同一张表文件里）:
     ┌──────────────────────────────┐   ┌──────────────────────────────┐
     │ id=1 v='A' xmin=100 xmax=103 │──►│ id=1 v='C' xmin=103 xmax=0   │
     │ (dead，等 vacuum 收)          │ctid│ (live)                      │
     └──────────────────────────────┘   └──────────────────────────────┘

  InnoDB：当前行 + undo 链（旧版本在 undo 表空间）
     表里: id=1 v='C' trx_id=103 roll_ptr ──► undo: v='B' trx_id=101
                                             roll_ptr ──► undo: v='A' …
```

| 维度 | PG（就地多版本） | InnoDB（undo 链） |
|---|---|---|
| 读旧版本 | 按可见性规则直接挑页面里的某个版本，无需回溯 | 从当前行沿 roll_ptr 回溯拼装 |
| 写入放大 | 每次更新写一个完整新元组；索引若非 HOT 也要追加新项 | 只写 undo 记录，主记录就地改 |
| 回滚 | clog 标记 abort，瞬时完成 | 反向执行 undo，大事务回滚很慢 |
| 旧版本的清理 | VACUUM 扫表收 dead tuple（第 3 章） | purge 线程清 undo 链 |
| 长事务的代价 | 阻碍 vacuum → 表膨胀 + xid 无法冻结（见下节） | 阻碍 purge → undo 膨胀 |
| 空间归还 | vacuum 只标记复用，想缩文件要 VACUUM FULL（锁全表） | undo 表空间可自动收缩（8.0 truncate） |

隔离级别上的差异也值得记：PG 默认 **READ COMMITTED**（每条语句取新 snapshot），REPEATABLE READ 是快照隔离且**天然无幻读**；SERIALIZABLE 是基于 SSI 的真串行化（冲突直接 abort 重试），而 MySQL 的 SERIALIZABLE 退化为"全部加锁"。MySQL 默认 RR 的历史原因与两者差异在 mysql/01#MVCC 读视图（Read View） 一节有展开，此处不重复。

一个 PG 特有的优化顺带记住：**HOT 更新**——若更新的列没有任何索引引用、且新版本能塞进同一页，就只动堆不动索引，索引仍指向旧位置再跳转。高频 UPDATE 的表，索引列设计（别把常改的列建进索引）直接决定膨胀速度，第 3 章 bloat 治理会用到。

```sql
-- [任意节点] 亲眼看 xmin/xmax
-- 会话 A:
CREATE TABLE demo (id int PRIMARY KEY, v text);
INSERT INTO demo VALUES (1,'a');
SELECT xmin::text::bigint, xmax::text::bigint, ctid, * FROM demo;
UPDATE demo SET v='b' WHERE id=1;
SELECT xmin::text::bigint, xmax::text::bigint, ctid, * FROM demo;
-- xmax=0 的是新版本；旧版本(xmin=上一次的)还躺在旧 ctid，肉眼看不见但占着空间
```

（xmin 是 xid 类型，直接 select 在旧客户端可能显示为十六进制，转 bigint 看着舒服。）

## 4. 事务 ID 回卷（wraparound）

xid 是 32 位无符号整数，约 42 亿个，比较采用模运算：任何一个 xid 都把环切成"过去 21 亿 / 未来 21 亿"。这意味着**xid 空间不是无限的，而是循环使用的**——一旦一直往前分配，早年的事务会从"过去"绕成"未来"，老数据突然对未来事务"不可见"，即数据静默丢失。

解法是**冻结（freeze）**：VACUUM 把足够老的元组 xmin 改写成 FrozenXID（语义：比一切事务都老、永远可见），这行从此不再依赖那个旧 xid，环就可以安全地转过去。三级防线（默认值，具体以官方文档为准）：

| 防线 | 默认阈值 | 动作 |
|---|---|---|
| 1. 常规防线 | `autovacuum_freeze_max_age=2亿` | autovacuum 主动发起 anti-wraparound vacuum 冻结老元组 |
| 2. 兜底防线 | 约 16 亿（`vacuum_failsafe_age`，PG14+） | 即使 autovacuum 被关掉/卡住也强制执行，跳过部分惰性步骤抢时间 |
| 3. 最后防线 | 距半周期剩约 300 万 | 拒绝分配 xid 的写事务，系统只读报错，需人工介入 |

量级感受：写入 1 万 xid/s 的库，约 2.5 天就烧完半个周期；所以防线 1 的 2 亿在实际写入压力下可能几天就到——**这不是低概率事件，是每张高频写入表的日常**。而卡住防线的元凶几乎总是那几个：长事务（持有老 snapshot）、废弃的复制槽（pin 住老 LSN，第 2 章）、age 逼近 `autovacuum_freeze_max_age` 的表太多而 autovacuum worker（默认 3 个）不够。

```sql
-- [任意节点] 监控两张口径
SELECT datname, age(datfrozenxid) FROM pg_database
ORDER BY 2 DESC;                 -- 库级：最老的未冻结 xid 距今多少
SELECT relname, age(relfrozenxid), n_live_tup, n_dead_tup
FROM pg_stat_user_tables
ORDER BY 2 DESC LIMIT 10;        -- 表级：age 超过 1.5 亿就该警惕
-- age() 返回的就是"距离回卷还剩多少"的消耗量，是 exporter 必配指标（第 3 章）
```

MySQL 没有这个维度（trx_id 也会回卷但只影响复制与 purge 的窗口，不威胁数据可见性），这是从 MySQL 转 PG 的运维最容易漏建的一条告警。

## 5. shared_buffers 与 double cache

PG 的数据页缓存 `shared_buffers` 是一块共享内存，所有 backend 进程共享（默认仅 128MB）。与 InnoDB buffer pool 的关键区别在**它不是唯一缓存**：

```
                      读一个页的路径
  backend ──► shared_buffers 命中？── 是 ──► 返回
                  │否
                  ▼
             OS page cache（read() 系统调用）── 命中（不产生磁盘 IO，但有内核拷贝）
                  │未命中
                  ▼
                磁盘
```

同一份数据在内核页缓存与 shared_buffers 里各存一份（double buffering），这是 PG 历史设计的代价：换来了 crash 后 OS cache 仍可信任（WAL 与刷页顺序保证）、以及直接依赖 `read()`/`write()` 的简单性。运维推论：

- 经验值给物理内存的 **25%**（官方 Wiki 的常用建议，机械盘时代经典值；NVMe/大内存下有争议，以压测为准），盲目给到 70% 反而挤占 OS cache，双份缓存得不偿失——与 MySQL"buffer pool 直接 50%~70%"的直觉相反；
- `effective_cache_size`（默认 4GB）**不分配任何内存**，只是告诉优化器"OS cache 大概多大"，影响执行计划选 index scan 还是 seq scan 的倾向，通常设为内存的 50%~70%；
- 命中率要两层一起看：`pg_statio_user_tables` 的堆读命中率，加上 OS 层的 cache 命中（node_exporter 视角）。

```sql
-- [任意节点] 缓存命中率（对应 mysql/03 的 buffer pool 命中率）
SELECT sum(blks_hit)*100.0/nullif(sum(blks_hit)+sum(blks_read),0) AS hit_pct
FROM pg_stat_database;
-- 99%+ 为健康；注意它只算 shared_buffers 这一层
```

## 实战演练

环境：装有 Docker 的 Ubuntu VM（candidate），统一用 `postgres:16`。本章目标：把进程模型、多版本与回卷三件事"看到"。

```bash
# [Ubuntu VM] 起实例，压低 shared_buffers 模拟小机器
docker run -d --name pg-learn -e POSTGRES_PASSWORD=pg123 \
  -p 5432:5432 -m 2g postgres:16 -c shared_buffers=256MB
docker exec -it pg-learn psql -U postgres
```

```bash
# [Ubuntu VM] 另开终端：进程模型 1——常驻后台进程
docker exec pg-learn ps -eo pid,ppid,cmd | grep -E 'postgres|PID' | grep -v grep
# 预期：1 个主进程 + checkpointer / background writer / walwriter /
#       autovacuum launcher / logical replication launcher 各一个
```

```sql
-- [容器内] 进程模型 2——每连接一个进程
-- 保持当前 psql 不退，另开一个终端:
-- docker exec pg-learn ps -eo pid,ppid,cmd | grep idle
# 预期（另一终端）：出现 "postgres: postgres postgres [local] idle" 进程，
# 再开一个 psql 就再 多一个——连接与进程一一对应

-- MVCC：死元组占空间的可视化
CREATE TABLE bloat AS SELECT g AS id, 'v1' AS v FROM generate_series(1,100000) g;
SELECT pg_size_pretty(pg_total_relation_size('bloat'));   -- 约 4~5MB
UPDATE bloat SET v='v2';                                   -- 全表更新
SELECT pg_size_pretty(pg_total_relation_size('bloat'));   -- 接近翻倍:旧版本全留在表里
VACUUM bloat;                                              -- 手动清死元组
SELECT pg_size_pretty(pg_total_relation_size('bloat'));   -- 几乎不变:只标记可复用
-- (VACUUM FULL 才真正缩文件,锁代价第 3 章讲;此处别在生产模仿)

-- 快照隔离:旧版本为什么必须保留
-- 会话 A(当前 psql):
BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM bloat WHERE v='v1';    -- 取 snapshot:10万
-- 会话 B(另一终端 psql):
--   UPDATE bloat SET v='v3' WHERE v='v2'; COMMIT;
-- 回到会话 A:
SELECT count(*) FROM bloat WHERE v='v1';    -- 仍是 10万:snapshot 冻结在事务开始
COMMIT;
SELECT count(*) FROM bloat WHERE v='v1';    -- 0:新 snapshot 下旧版本"消失"

-- 回卷:表的老化程度
SELECT txid_current();                      -- 看当前 xid(pg_current_xact_id() 亦可)
SELECT relname, age(relfrozenxid) FROM pg_class WHERE relname='bloat';
-- age 就是"这表的元组还 pin 着多老的 xid",vacuum 冻结后才会下降
```

验证方法：进程实验里每多开一个 psql 就多一个 backend 进程；`bloat` 表在 UPDATE 后体积接近翻倍、VACUUM 后不回落；RR 会话前后两次 count 不一致而 COMMIT 后立刻一致——三条分别对应本章三、三、四节。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 连接数一上 500 整机 CPU sys 占比飙升 | 每连接一进程，调度开销陡增 | pgbouncer（第 2 章）；应用侧收连接池上限 |
| 表体积只增不减，DELETE 千万行后磁盘没变 | 死元组原地保留，vacuum 只标记复用 | 第 3 章 bloat 治理；高频删改表调低 autovacuum 阈值 |
| `work_mem` 调到 64MB 后偶发 OOM | work_mem 按排序/哈希节点×并行 worker 计费 | 保持默认 4MB，靠索引消排序 |
| 把 MySQL 习惯带过来，shared_buffers 设 70% | double cache 下挤占 OS cache | 25% 起步，压测定夺 |
| 误以为 ROLLBACK 会立刻释放空间 | PG 回滚只改 clog 标记，垃圾仍在表里 | 回滚后照样等 vacuum；大事务拆小才是正解 |
| 监控脚本里直接比较裸 xmin/xid 判断新旧 | xid 是 32 位环形模比较，绝对值大小无意义 | 一律用 `age()` / 差值；回卷水位告警用 `age(datfrozenxid)` |

## 自测

1. 同样是"长事务拖垮存储"，PG 与 MySQL（InnoDB）各自的机理和受害者有什么不同？

<details><summary>答案</summary>

MySQL：长事务的 Read View 让 purge 线程不能清理 undo 链，undo 表空间/ibtmp 持续膨胀，受害的是独立于数据的 undo 存储。PG：长事务持有的 snapshot 让 vacuum 无法回收 dead tuple，受害的是**表和索引本身**（bloat），同时旧 xid 无法冻结，还叠加事务 ID 回卷风险。处置也相反：MySQL 杀事务后 purge 会慢慢消化；PG 杀事务后 vacuum 能标记复用，但已膨胀的空间要 VACUUM FULL/pg_repack 才能还给操作系统。
</details>

2. PG 回滚一个跑了 2 小时的大事务几乎是瞬间的，为什么？这个优点换来了什么代价？

<details><summary>答案</summary>

回滚只是在 clog（pg_xact）里把该事务标记为 aborted，所有它写入的元组立刻变成"对所有人不可见"，无需反向执行。代价是这些死元组还躺在数据页里占着空间，必须等 VACUUM 扫描回收；期间表膨胀、扫描变慢、索引变大。InnoDB 正好相反：回滚慢（顺 undo 链反向执行），但回滚完空间随 purge 归还，表本身不因回滚膨胀。
</details>

3. 如果把 `full_page_writes` 关掉换性能，断电后可能发生什么？InnoDB 用什么机制解决同一问题？

<details><summary>答案</summary>

一个 8KB 数据页可能被部分写入（torn page：前 4KB 是新数据后 4KB 是旧数据），WAL 里记录的页级变更重放到一个"半新半旧"的页上会把页损坏，且这种损坏会随 checkpoint 固化。full_page_writes 在 checkpoint 后首次修改某页时把整页镜像写进 WAL，恢复时先整页覆盖再重放增量，牺牲 WAL 体积换安全。InnoDB 用 doublewrite buffer：脏页刷盘前先顺序写一份到共享表空间的 doublewrite 区， torn 时从那里拷回完整页。两种方案、同一问题。
</details>

4. xid 明明还有 20 亿没用完，为什么 age 到 2 亿（默认值）就要开始 anti-wraparound vacuum？

<details><summary>答案</summary>

xid 比较是模运算的环形语义，只有前后各半（约 21 亿）的窗口有意义：超过 21 亿的旧事务会被当成"未来"，其数据对新事务不可见——静默丢数据。所以"安全余量"不是 42 亿而是 21 亿，再扣除 vacuum 扫描大表本身需要的时间（可能数小时），必须在还有充足余量时启动冻结。2 亿是"提前量"的默认折中：给防线 2（16 亿 failsafe）和防线 3（拒绝写入）留出足够的处理窗口。
</details>

5. 为什么 MySQL 的 buffer pool 建议给到内存的 50%~70%，而 PG 的 shared_buffers 通常只给 25%？

<details><summary>答案</summary>

MySQL 自己管理全部页缓存，buffer pool 之外 OS cache 对 InnoDB 用处有限（O_DIRECT 类读写绕过 OS cache），内存不给 buffer pool 就浪费。PG 的读走 read()/write()，同一份数据天然存在 OS page cache 与 shared_buffers 两份（double cache）：shared_buffers 偏大只是把"命中地点"从内核搬到用户态，挤掉的 OS cache 同时还被其他读者（如 pg_dump 顺序扫）与文件系统使用，边际收益递减。所以 PG 的内存观是"shared_buffers 一份 + 相信 OS cache"，并用 effective_cache_size 把这个事实告诉优化器。
</details>

## 延伸阅读

- 官方手册 Internal Overview（进程结构）：https://www.postgresql.org/docs/current/tutorial-arch.html
- 官方手册 Reliability and the Write-Ahead Log（full_page_writes/checkpoint）：https://www.postgresql.org/docs/current/wal-reliability.html
- 官方手册 Multi-Version Concurrency Control（xmin/xmax 与可见性规则）：https://www.postgresql.org/docs/current/mvcc.html
- 官方手册 Routine Vacuuming（冻结与回卷细节）：https://www.postgresql.org/docs/current/routine-vacuuming.html
- 官方 Wiki Tuning Your PostgreSQL Server（shared_buffers 25% 的出处与争议）：https://wiki.postgresql.org/wiki/Tuning_Your_PostgreSQL_Server
