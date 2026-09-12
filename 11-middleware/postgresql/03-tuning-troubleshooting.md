# 03 · PostgreSQL 调优与排障手册：EXPLAIN、vacuum、备份与监控

> 模块：中间件-PostgreSQL ｜ 建议时长：3 小时 ｜ 关联认证：PCA-指标（监控节直接复用 PromQL 与自定义 exporter 查询能力）；对照参照 11-middleware/mysql/03

## 学习目标

- 能操作：用 `EXPLAIN (ANALYZE, BUFFERS)` 定位坏 SQL，并翻译成 MySQL EXPLAIN 的既有心智（type/Extra 对照）
- 能操作：开启 pg_stat_statements 建 top 榜，按"总耗时/均值/调用数"三条线分型慢查询
- 能排查：连接打满按 state 分型处置；锁等待用 `pg_blocking_pids` 找源头并解释 DDL 链式阻塞
- 能解释 vacuum 触发公式、表为什么膨胀、VACUUM FULL 的锁代价与 pg_repack 的替代原理
- 能选型：pg_dump 逻辑备份与 pgBackRest 物理增量按 RTO/RPO 组合，并配齐 postgres_exporter 核心告警

## 1. EXPLAIN (ANALYZE, BUFFERS)：读法与 MySQL 对照

MySQL 看三列 type/Extra/rows（mysql/03#1. 慢查询与 EXPLAIN），PG 的输出是一棵**计划树**：每个节点是一个算子，缩进表示父子关系，自底向上执行。先给对照表再讲 PG 特有读法：

| MySQL 里的说法 | PG 计划节点 | 备注 |
|---|---|---|
| type=ALL 全表扫描 | **Seq Scan** | 顺序扫整张堆表 |
| type=ref / eq_ref | Index Scan | 走 B 树，边扫边回堆 |
| type=range | Index Scan(带条件) 或 Bitmap Index Scan | 位图先攒后批量取堆，随机 IO 变顺序 |
| Extra: Using index 覆盖索引 | **Index Only Scan** | 见下方 visibility map 坑 |
| Using filesort | Sort 节点 | 内存不够溢盘（work_mem） |
| Block Nested Loop(8.0.18 前) | **Hash Join / Merge Join** | PG 的老牌强项 |
| type=ref rows=N | 同名 rows 字段 | PG 是估算，actual 是实测 |
| EXPLAIN ANALYZE(8.0.18+) | **EXPLAIN (ANALYZE, BUFFERS)** | PG 早就有且更细 |

```sql
-- [任意节点] 三步读法示例
EXPLAIN (ANALYZE, BUFFERS) SELECT id, status FROM orders WHERE user_id = 42;
-- 坏计划:
-- Seq Scan on orders  (cost=0.00..1887.00 rows=100 width=8)
--                     (actual time=0.041..14.8 rows=98 loops=1)
--   Filter: (user_id = 42)  Rows Removed by Filter: 99902
--   Buffers: shared hit=157 read=21
```

读法两条：

1. **cost=startup..total** 是优化器估算（以 seq_page_cost 等为基准的虚拟单位），**rows 也是估算**；`(actual time=启动..结束 rows=实际 loops=次数)` 才是实测。rows 估算与 actual 差一个数量级 = 统计信息过期，`ANALYZE orders;` 重新采样（对应 MySQL 的 `ANALYZE TABLE`）。
2. **loops 要乘**：actual time 与 rows 是"每个 loop 的平均"，外层节点看到的行数 = rows × loops，新手最常见的误读就是忘了乘法；**Buffers 看 IO**：`shared hit`（shared_buffers 命中）/`read`（穿过缓存读了多少页），优化前后对比 read 的下降比对比时间更抗噪音。

Index Only Scan 的 PG 特色坑：即使索引覆盖了所有列，PG 仍可能回堆检查元组可见性（第 1 章 MVCC 的死元组问题在这里再次收账）——只有页在 **visibility map** 里标记为 all-visible（由 vacuum 维护）才真正免回堆。高频更新表上 vacuum 落后，Index Only Scan 会悄悄退化成 Index Scan：`EXPLAIN` 显示 `Heap Fetches` 很大就是它。这是"vacuum 不只是清理，还维护访问路径"的直接证据（实战演练 1 给出建索引前后的完整对比）。

## 2. pg_stat_statements：慢查询 top 榜

PG 没有独立的慢日志产物（`log_min_duration_statement` 可记慢 SQL，但聚合分析靠扩展）。pg_stat_statements 在共享内存里按"参数化后的查询指纹"累计耗时，代价是要写进 `shared_preload_libraries` 并重启实例（实战演练的启动命令带了这一参数）：

```sql
-- [容器内] 启用(每库一次) + top 榜
CREATE EXTENSION pg_stat_statements;
SELECT calls, round(total_exec_time::numeric,0) AS total_ms,
       round(mean_exec_time::numeric,1) AS mean_ms,
       round(100.0*shared_blks_read/nullif(shared_blks_hit+shared_blks_read,0),1) AS read_pct,
       left(query, 60) AS query
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 10;
-- 字段名以官方文档为准(PG13 起 total_exec_time,旧版本叫 total_time)
```

三条线分型（与 mysqldumpslow 的 -s c/-s t 用法同构）：按 `total_exec_time` 排 = 先治最吃资源的；按 `mean_exec_time` 排 = 单次最慢、用户感知最强；`calls` 巨大 + mean 小 = 该上缓存或合并调用了。`read_pct` 高说明这条 SQL 在硬啃磁盘。注意 query 已指纹化（常量变 `$1`），拿去复现 EXPLAIN 时要自己代入真实参数。

## 3. 连接打满排障

PG 报错文案是 `sorry, too many clients already`（对照 MySQL 的 1040）。进程模型（第 1 章）决定了它的处置优先级：**先看 state 分型，再决定杀谁**：

```sql
-- [任意节点] 第一步:分型统计
SELECT state, wait_event_type, count(*) FROM pg_stat_activity
WHERE pid <> pg_backend_pid() GROUP BY 1,2 ORDER BY 3 DESC;
```

| state | 含义 | 处置 |
|---|---|---|
| active | 真在执行 | 看 wait_event 与 EXPLAIN，别盲杀 |
| idle | 空闲等客户端 | 数量逼近 max_connections = 连接池泄漏，上 pgbouncer（第 2 章） |
| **idle in transaction** | 开了事务没提交干等 | 头号罪犯：阻碍 vacuum + 持锁，先杀后查应用 |
| idle in transaction (aborted) | 事务里报错后也没回滚 | 同上，多半是异常处理缺失 |

```sql
-- [任意节点] 定杀 idle in transaction 超 5 分钟的连接(留证据再杀)
SELECT pid, usename, now()-xact_start AS xact_age, left(query,50)
FROM pg_stat_activity
WHERE state LIKE 'idle in transaction%' AND now()-xact_start > interval '5 min';
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE state LIKE 'idle in transaction%' AND now()-xact_start > interval '5 min';
-- pg_cancel_backend 只杀当前查询不断连接;terminate 直接断连接

-- 兜底参数(对应 mysql/03 的 wait_timeout 思路,但只杀"事务中"的空闲):
ALTER SYSTEM SET idle_in_transaction_session_timeout = '300s';
SELECT pg_reload_conf();
```

与 mysql/03#4. 高频故障排障手册（连接打满）互相印证：MySQL 侧凶手常是 Sleep 泄漏与 DNS 反解析；PG 侧因为进程更贵，答案几乎总是同一个——**应用直连改 pgbouncer transaction 池**（第 2 章），把进程数与业务并发解耦。

## 4. 锁等待：pg_locks 与 lock_timeout

PG 的锁信息全在系统视图里，比 MySQL 好查。最常用的两条：

```sql
-- [任意节点] 1.谁在等谁(pg_blocking_pids 直接给出阻塞源头,9.6+)
SELECT pid, wait_event_type, wait_event, state,
       pg_blocking_pids(pid) AS blocked_by, left(query,50)
FROM pg_stat_activity
WHERE pid <> pg_backend_pid() AND cardinality(pg_blocking_pids(pid)) > 0;

-- [任意节点] 2.锁的明细(行列锁在 pg_locks 里体现为 tuple 锁/xid 锁)
SELECT relation::regclass, mode, granted, pid
FROM pg_locks WHERE NOT granted;
-- 查到 mode = ACCESS EXCLUSIVE = 连 SELECT 都挡,
-- ALTER TABLE/DROP/TRUNCATE/VACUUM FULL 都要拿它
```

DDL 链式阻塞（与 MySQL 的 metadata lock 队列同型，mysql/03 常见坑表里 `Waiting for table metadata lock` 一条）：一条跑了 10 分钟的报表 SELECT 挡住了 `ALTER TABLE`（要 ACCESS EXCLUSIVE），而 ALTER 在队列里又**挡住了它身后所有想读这张表的会话**（PG 的锁队列不分读写公平排队）。于是"加个列"演变成全站超时。纪律：

```sql
-- [任意节点] DDL 会话务必先设超时,拿不到锁就退避重试,别在队列里当路障
SET lock_timeout = '5s';
ALTER TABLE orders ADD COLUMN remark text;
SET lock_timeout = 0;   -- 恢复默认(无限等)
```

死锁两个库都自动检测（PG `deadlock_timeout` 默认 1s，杀小方报 `deadlock detected`；对应 MySQL 的 `innodb_print_all_deadlocks`）。重量级冲突记住两对：`VACUUM FULL` vs 一切、`ALTER TABLE` vs 一切。

## 5. vacuum 与 bloat 深讲

第 1 章的伏笔全部在这里兑现：旧版本留在表里 → 需要 vacuum 回收；vacuum 慢/被卡 → 死元组堆积 → **表膨胀（bloat）**。

### 5.1 autovacuum 什么时候触发

每张表独立判断（PG13+ 对 update/delete 与 insert 分开计量，公式以官方文档为准）：

```
  vacuum 触发阈值 = autovacuum_vacuum_threshold(默认 50)
                  + autovacuum_vacuum_scale_factor(默认 0.2) × n_live_tup
  n_dead_tup 超过阈值 → 排队(autovacuum_naptime=60s 轮询, max_workers=3 分活)
```

0.2 这个默认值对大表是灾难：1 亿行的表要攒 2000 万死元组才触发，期间扫描越来越慢、IO 越来越浪费。按表调是标准动作：

```sql
-- [任意节点] 高频更新表单独收紧(不用动全局)
ALTER TABLE orders SET (
  autovacuum_vacuum_scale_factor = 0.02,   -- 200万死元组即触发
  autovacuum_vacuum_threshold = 1000
);
-- insert 型大表另配 autovacuum_vacuum_insert_*:偏 freeze 与 all-visible 维护
```

### 5.2 表为什么会膨胀

四个原因按出现频率排：

1. **更新/删除产生死元组是常态，vacuum 只是追**。追不上就堆积：死元组散布在页内（页内空洞）、索引项指向它们（索引膨胀，索引比表更容易膨胀两三倍，因为一次 UPDATE 若非 HOT 要动每个索引）。
2. **有"阻碍者"时 vacuum 根本不能收**：长事务持有的 xmin horizon 之后的死元组全保留（第 1 章）；复制槽 pin 住老 LSN（第 2 章 CDC 槽是重灾区）；它们和 `idle in transaction` 一起构成"vacuum 报告跑了但 dead tuples 不降"的三大主因。
3. **vacuum 不还空间给 OS**：它只把空闲空间登记进 FSM 供后续插入复用，只有**文件末尾**的整页空缺能直接截断。中间的空洞想消除必须重建整张表。
4. **HOT 失效**：被更新的列出现在任一索引里（新版本放不进原页同理），所有索引都要追加指针。常改的列建索引 = 膨胀加速器。

```sql
-- [任意节点] bloat 体检:死活元组比 + 体积
SELECT relname, n_live_tup, n_dead_tup,
       round(100.0*n_dead_tup/nullif(n_live_tup,0),1) AS dead_pct,
       last_autovacuum, pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 10;
-- dead_pct 持续 >20% 且 last_autovacuum 很久没动 = 有阻碍者或 worker 不够
-- 精确测量(含页内空洞)用 pgstattuple 扩展
```

### 5.3 收缩手段：VACUUM FULL 的锁代价与 pg_repack

| 手段 | 锁级别 | 空间 | 时间 |
|---|---|---|---|
| VACUUM | SHARE UPDATE EXCLUSIVE（不挡读写） | 只标记复用 | 快 |
| **VACUUM FULL** | **ACCESS EXCLUSIVE（全表读写全停）** | 重建文件，真正缩小 | 表越大越久 |
| **pg_repack** | 仅起止瞬间短暂锁 | 在线重建，等效收缩 | 约为 VACUUM FULL 数倍 |

VACUUM FULL 的实现是"整表拷进新文件再改名"：全程 ACCESS EXCLUSIVE（连 SELECT 都进不来）、需要等量的额外磁盘、索引全部重建——在生产的白天执行等于制造一次人为停机。pg_repack 的思路是在线完成同一件事：建影子表 + 触发器记录增量 → 拷贝存量 → 回放增量 → 短锁切换（对照 MySQL 生态 gh-ost/pt-osc 的"影子表+binlog 追增量"，完全同构，只是增量来源换成了逻辑复制/触发器）：

```bash
# [Ubuntu VM] pg_repack 在线收缩(库内先 CREATE EXTENSION pg_repack;
# 客户端工具单独装:PGDG 源 postgresql-16-repack,包名随大版本变,以官方仓库为准)
docker exec pg-learn psql -U postgres -c "CREATE EXTENSION pg_repack;"
pg_repack -h 127.0.0.1 -p 5432 -U postgres -d postgres -t orders
```

预防永远优于收缩：第 1 节的 per-table 阈值收紧 + 监控 dead_pct + 杀长事务/清废槽，让 autovacuum 追得上，多数表一辈子不需要 repack。别忘了 wraparound 这条独立战线：`age(datfrozenxid)` 靠的就是 vacuum 的 freeze 动作（第 1 章第 4 节），anti-wraparound vacuum 被阻碍的后果比 bloat 严重——是系统只读。

## 6. 备份：pg_dump 逻辑 vs pgBackRest 物理增量

选型框架与 mysql/02#1. 备份体系：逻辑 vs 物理 一致（先问 RTO/RPO），但 PG 的实现有几个自己的答案：

| 维度 | pg_dump / pg_restore | pg_basebackup + WAL 归档 | pgBackRest |
|---|---|---|---|
| 产物 | SQL/自定义格式 | 数据目录 + WAL | 数据目录 + WAL（全量/差异/增量） |
| 一致性 | 单事务 RR 快照导出（同 mysqldump --single-transaction 的原理） | 流式拉 WAL 天然对齐（无 XtraBackup 的 prepare 步骤） | 同左 |
| 恢复速度 | 重放 SQL，慢 | 拷回即起 | 并行恢复，最快 |
| PITR | 不行 | 行（恢复到任意 LSN/时刻） | 行，且增量粒度可自选 |
| 单库/单表恢复 | **强项**（pg_restore -t） | 要整实例 + 手工捞 | 较繁琐 |
| 跨大版本 | 行（文本导出） | 不行（物理绑定版本） | 不行 |
| 规模建议 | <50GB、迁移导结构 | 中小库够用 | 大库/多实例标准答案 |

```bash
# [Ubuntu VM] 逻辑备份标准姿势(-Fc 压缩格式,支持 -j 并行恢复与 -t 单表抽取)
docker exec pg-learn pg_dump -U postgres -Fc -f /tmp/shop.dump shop
docker exec pg-learn pg_restore -U postgres -j 4 -d shop_new /tmp/shop.dump
```

物理这条线的完整闭环（第 2 章 pg_basebackup + 归档 + PITR）：

```ini
# [任意节点] 主库 postgresql.conf 开归档
archive_mode = on
archive_command = 'test ! -f /archive/%f && cp %p /archive/%f'   # WAL 段离开 pg_wal 前归档
```

```bash
# [Ubuntu VM] PITR 演练骨架(误删库后恢复到误删前一刻)
# 1. 备份数据目录(或 pg_basebackup 产物)放到新实例位置,放 recovery.signal(PG12+)
# 2. postgresql.auto.conf 写三行:
#    restore_command = 'cp /archive/%f %p'
#    recovery_target_time = '2026-09-12 10:00:00+08'
#    recovery_target_action = 'promote'      # 到点自动提升(默认 pause 等人工)
# 3. 启动实例 → 重放 WAL 到目标时刻 → promote 成新主
```

pgBackRest 把"全量+差异/增量+归档+保留策略+并行压缩"打包成一套命令（`--stanza` 是备份单元，`pgbackrest --stanza=pg --type=diff backup`），角色定位与 XtraBackup + cron 相同但增量是内建的；S3 等仓库支持以官方文档为准。没恢复过的备份等于没有备份——这条纪律在 mysql/02 说过，PG 侧不豁免。

## 7. postgres_exporter 必看指标

prometheus-community/postgres_exporter 部署方式与 mysqld_exporter 同构（连接串 `DATA_SOURCE_NAME`，端口 9187）。内置指标覆盖多数场景；复制延迟与 wraparound 这两个 PG 特命脉，官方建议用自定义查询补齐（`--extend.query-path`，写法与 02-programming/04 的自定义 exporter 思路一致）：

```yaml
# [任意节点] queries.yaml:补两个保命指标(格式以 exporter 官方文档为准)
pg_wraparound:
  query: "SELECT datname, age(datfrozenxid)::double AS xid_age FROM pg_database"
  metrics:
    - datname: {usage: "LABEL", description: "database"}
    - xid_age: {usage: "GAUGE", description: "oldest unfrozen xid age"}
pg_repl_lag:
  query: "SELECT application_name, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)::double AS lag_bytes FROM pg_stat_replication"
  metrics:
    - application_name: {usage: "LABEL", description: "standby"}
    - lag_bytes: {usage: "GAUGE", description: "replay lag in bytes"}
```

| 优先级 | 指标 | 看什么/告警 |
|---|---|---|
| P0 存活 | `pg_up` | !=1 直接告警（同 mysql_up） |
| P0 连接 | `pg_stat_database_numbackends / pg_settings_max_connections` | >0.85 预警打满（第 3 节） |
| P0 回卷 | 自定义 `xid_age` | >1.5 亿 warning、>16 亿 critical（第 1 章第 4 节三级防线） |
| P1 复制 | 自定义 `lag_bytes`（新版本 exporter 亦内置同义指标，以官方仓库为准） | >100MB 或无样本（备库断开）单独告警 |
| P1 死元组 | `pg_stat_user_tables_n_dead_tup`（按库聚合） | 持续上涨不回落 = vacuum 有阻碍者 |
| P1 事务悬挂 | `pg_stat_activity_count{state="idle in transaction"}` | 出现即查 pg_stat_activity 源头 |
| P2 缓存命中 | `pg_stat_database_blks_hit / (blks_hit+blks_read)` | <99% 且 read 速率升 = 数据量超内存 |
| P2 死锁 | `pg_stat_database_deadlocks`（rate） | 持续 >0 抓日志（deadlock_timeout 1s 检测） |

```promql
# [任意节点] 两条现成告警
pg_stat_database_numbackends{datname="shop"}
  / pg_settings_max_connections > 0.85      # for: 5m 连接使用率
pg_wraparound_xid_age{datname="shop"} > 1.5e8  # for: 10m 回卷水位
```

排障闭环与 mysql/03 同款：`pg_up` 掉 → 看容器/进程与日志 → 连接或 wait_event 异常 → `pg_stat_activity` 抓源头 → EXPLAIN/vacuum 状态定性 → 处置后指标回落。

## 实战演练

```bash
# [Ubuntu VM] 环境沿用第 1 章思路;重建实例(pg_stat_statements 需重启,压低连接上限)
docker rm -f pg-learn
docker run -d --name pg-learn -e POSTGRES_PASSWORD=pg123 -p 5432:5432 \
  postgres:16 -c shared_preload_libraries=pg_stat_statements -c max_connections=15
```

```sql
-- [容器内] 造数据
CREATE EXTENSION pg_stat_statements;
CREATE TABLE orders AS
SELECT g AS id, (random()*10000)::int AS user_id, 0 AS status
FROM generate_series(1,200000) g;
```

```sql
-- [容器内] 1.EXPLAIN:Seq Scan → Bitmap 优化前后
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM orders WHERE user_id = 42;
-- 记下 Buffers read(~900)与 Rows Removed by Filter
CREATE INDEX idx_user ON orders (user_id);
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM orders WHERE user_id = 42;
-- 变为 Bitmap Index Scan + Bitmap Heap Scan,read 降到个位数

-- 2.top 榜:跑几遍重复查询再聚合(能看到指纹化查询与真实耗时)
SELECT count(*) FROM orders WHERE user_id BETWEEN 1 AND 100;
SELECT calls, round(total_exec_time::numeric) AS total_ms, left(query,50)
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 5;
```

```bash
# [Ubuntu VM] 3.连接打满复现(max_connections=15 已压低;PG 改它要重启实例,
# 不像 MySQL 能 SET GLOBAL 救急——"腾位"只有 pg_terminate_backend,事前防超卖更重要)
for i in $(seq 1 10); do
  docker exec -d pg-learn psql -U postgres -c "SELECT pg_sleep(120);"
done
docker exec pg-learn psql -U postgres -c \
  "SELECT state, count(*) FROM pg_stat_activity WHERE pid <> pg_backend_pid() GROUP BY 1;"
# 预期: active 10
# 逼近上限:再逐个申请,直到出现报错
for i in $(seq 1 6); do
  docker exec pg-learn psql -U postgres -c "SELECT pg_backend_pid();" || break
done
# 预期最后一轮打印: psql: error: ... sorry, too many clients already
# (对照 MySQL 的 ERROR 1040;占满后连超级用户也进不来——reserved 槽也用光了)
# 释放:睡 120 秒自动退,或直接重启实例(演练环境最快)
docker restart pg-learn
```

```sql
-- [容器内] 4.锁等待:两个 psql 会话(A/B)配合
-- 会话 A:
BEGIN;
UPDATE orders SET status=1 WHERE id=1;
-- 会话 B(另一终端):
UPDATE orders SET status=2 WHERE id=1;      -- 卡住
-- 会话 C(第三个连接):
SELECT pid, wait_event_type, wait_event,
       pg_blocking_pids(pid) AS blocked_by, left(query,40)
FROM pg_stat_activity
WHERE cardinality(pg_blocking_pids(pid)) > 0;
-- 预期: B 的行出现,blocked_by 里是 A 的 pid;回会话 A COMMIT 后 B 立刻完成

-- 5.bloat 全流程(接第 1 章的 bloat 实验,这次走完整版)
SELECT pg_size_pretty(pg_total_relation_size('orders')) AS before_full;
UPDATE orders SET status = status + 1;       -- 全表更新,死元组翻倍
VACUUM orders;                                -- 只标记复用
SELECT pg_size_pretty(pg_total_relation_size('orders')) AS after_vacuum;
VACUUM FULL orders;                           -- 注意:此刻全表 ACCESS EXCLUSIVE 锁死!
SELECT pg_size_pretty(pg_total_relation_size('orders')) AS after_full;
-- 预期: before < after_vacuum ≈ 2×before; after_full 回到 before 附近
-- (VACUUM FULL 期间另开会话跑第 4 节的锁查询,可看到 ACCESS EXCLUSIVE)
```

验证方法：演练 1 两次 EXPLAIN 的 read 数量级差；演练 3 的报错复现与重启后恢复；演练 4 的 blocked_by 指向 A；演练 5 的体积三段变化。生产对应动作分别是：补索引、上 pgbouncer、杀 idle in transaction、pg_repack。复制链路侧的综合排障在 `labs/01-streaming-replication` 演练。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 表查询越来越慢但行数没涨 | 死元组/索引膨胀，vacuum 追不上 | per-table 收紧 autovacuum 阈值；查长事务与废槽；重灾区 pg_repack |
| `pg_wal` 目录暴涨磁盘告警 | 复制槽 pin WAL（CDC/备库断连） | `max_slot_wal_keep_size` 兜底；监控槽 retained（第 2 章） |
| 白天 ALTER TABLE 后全站超时 | 慢查询挡 DDL，DDL 又挡所有读 | DDL 会话 `SET lock_timeout`；低峰执行；大表用重建式在线改表 |
| autovacuum 显示在跑但 dead_tup 不降 | 长事务 xmin horizon / 槽 pin 住 | 杀 idle in transaction；清废槽；看 `pg_stat_activity` 最老 xact |
| Index Only Scan 反而回堆 | visibility map 未置 all-visible | 让 vacuum 正常跑；insert 型表配 insert 阈值参数 |
| VACUUM FULL 执行中业务全停 | ACCESS EXCLUSIVE 全表锁 | 生产改用 pg_repack；提前公告；小表才可 FULL |
| 误删库后 pg_dump 也有，但恢复要 8 小时 | 逻辑备份重放慢且无中间态 | 物理备份 + WAL 归档做 PITR；pgBackRest 并行恢复 |

## 自测

1. `EXPLAIN` 估算 rows=100，actual rows=50000，会发生什么连锁反应？怎么修？

<details><summary>答案</summary>

优化器基于错误统计选错了计划：它以为只有 100 行输出，于是选了嵌套循环或按行逐条处理的计划，实际 5 万行被逐个处理，代价放大 500 倍——估算错误本身不慢，"按小数据量选的计划跑大数据量"才慢。修：`ANALYZE 表名` 重新采样统计信息；若列分布倾斜导致常规统计仍误判，考虑提高统计目标 `ALTER TABLE ... ALTER COLUMN ... SET STATISTICS 500` 或改写查询让估算更确定。
</details>

2. 为什么 PG 的索引比表更容易膨胀？HOT 在其中扮演什么角色？

<details><summary>答案</summary>

一次 UPDATE 产生一个新元组版本：如果更新涉及任何索引列（或新版本放不进原页），**每个索引**都要追加一个指向新位置的索引项——表膨胀 1 倍、全部索引各膨胀 1 倍，索引总膨胀通常大于表。HOT 更新能在"更新的列不被任何索引引用且新版本同页放下"时跳过索引写入（索引仍指向旧位置，靠页内跳转找新版本），把索引膨胀压下来。设计推论：别把高频更新的列建进索引。
</details>

3. `VACUUM` 跑完 `n_dead_tup` 降了，但表文件大小一点没变，这正常吗？什么时候才必须处理？

<details><summary>答案</summary>

正常。vacuum 只把死元组空间登记进 FSM 供未来插入复用，文件只会在"末尾整页为空"时截断，中间的空洞不消除。必须处理的判据是业务症状而非文件大小：表扫描/索引效率因空洞下降（同量数据 IO 变多）、磁盘容量告警、或 dead_pct 长期高位。手段按代价升序：先确认 vacuum 跟得上（参数与阻碍者），确需收缩时用 pg_repack 在线重建，VACUUM FULL 只留给维护窗口。
</details>

4. 备库 failover 后新主对外服务，几分钟后你发现旧主上有一批"新主上查不到"的订单——复制明明是 synchronous_commit=on，为什么？

<details><summary>答案</summary>

要先核对这批订单的提交是否真的走完了同步确认。三种常见缺口：这批事务提交时同步备库并不是后来提升的那台（FIRST/ANY 名单语义，异步备库被提升）；提交发生在旧主 demote 的瞬间，WAL 尚未送达任何备库（同步确认还没返回，客户端却已在旧主本地看到——PG 提交可见性与同步确认的时序边界）；或这些写入落在旧主分叉后的窗口里。`synchronous_commit=on` 保证的是"向客户端返回成功的事务已在同步备库落盘"，不保证"旧主上出现过的数据都在新主上"——后者正是 Patroni 在 failover 前比较 optime、旧主回归要走 pg_rewind/重搭的原因。
</details>

5. 连接数刚到 max_connections 的 60%，但延迟已经全面劣化、CPU 大量花在 sys——为什么 60% 就痛？下一步查什么、长期方案是什么？

<details><summary>答案</summary>

PG 每连接一个进程（第 1 章）：几千连接的调度开销、每进程内存、fork 风暴都会在 60% 水位就放大尾延迟，不像 MySQL 线程模型能扛到 80%+。下一步：`pg_stat_activity` 分型确认是否大量 active（真并发高，看 EXPLAIN/top 榜）还是 idle in transaction（杀事务治本）。长期方案是 pgbouncer transaction 池，把服务端进程数压到几十，同时注意客户端两层池的分工与 session 状态限制（第 2 章第 4 节）。
</details>

## 延伸阅读

- 官方手册 Using EXPLAIN（计划节点与 BUFFERS 输出）：https://www.postgresql.org/docs/current/using-explain.html
- 官方手册 Routine Vacuuming（autovacuum 公式/参数表）：https://www.postgresql.org/docs/current/routine-vacuuming.html
- 官方手册 Monitoring Database Activity（pg_stat_activity/pg_locks）：https://www.postgresql.org/docs/current/monitoring-stats.html
- 官方手册 Backup and Restore（pg_dump/PITR/归档）：https://www.postgresql.org/docs/current/backup.html
- pgBackRest 官方文档（全量/差异/增量与保留策略）：https://pgbackrest.org/user-guide.html
- postgres_exporter 官方仓库（内置指标与自定义 queries.yaml 格式）：https://github.com/prometheus-community/postgres_exporter
- pg_repack 官方仓库（在线收缩原理与用法）：https://github.com/reorg/pg_repack
