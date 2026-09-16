# 02 · MySQL 备份恢复与主从复制

> 模块：中间件-MySQL ｜ 建议时长：3.5 小时 ｜ 关联认证：—（CKA 备份思想可迁移：etcd snapshot 与本节"物理备份+binlog 点恢复"同构）

## 学习目标

- 能解释逻辑备份与物理备份的原理差异，并给出 mysqldump 与 XtraBackup 的选型依据
- 能操作：完成一次 XtraBackup 全量备份 + binlog 增量恢复到任意时间点
- 能解释主从复制的完整链路（dump / IO / SQL 三线程）与 binlog 三种格式的取舍
- 能排查：给出主从延迟成因与对应治理手段，判断何时用 GTID、何时上半同步
- 能解释读写分离架构下"刚写完读不到"的一致性陷阱及解法

## 1. 备份体系：逻辑 vs 物理

| 维度 | 逻辑备份 | 物理备份 |
|---|---|---|
| 产物 | SQL 语句文本（INSERT/DDL） | 数据文件副本（.ibd 页拷贝） |
| 代表工具 | mysqldump / mysqlpump / mydumper | XtraBackup / Clone Plugin |
| 速度 | 慢（导出慢、恢复要重放 SQL 更慢） | 快（文件级拷贝，恢复即拷回） |
| 跨版本/跨平台 | 好（文本通用） | 差（页格式绑定版本） |
| 备份期间影响 | `--single-transaction` 下不锁 InnoDB | 需要 FLUSH TABLES/备份锁，IO 有压力 |
| 典型大小 | 小（可压缩、可 grep） | 与数据目录等大 |
| 适用 | 小库（<50GB）、单表恢复、迁移导结构 | 大库、快速重建从库 |

经验法则：数据量小用 mysqldump 就够；TB 级或要求 RTO 短，一律 XtraBackup。选型先问两个问题——能容忍多久恢复（RTO）、能容忍丢多少数据（RPO）。**任何备份必须配合 binlog 才能恢复到"任意时间点"**，只恢复备份文件最多回到备份那一刻。

### mysqldump 关键参数

```bash
# [任意节点] 逻辑备份标准姿势
mysqldump -h127.0.0.1 -uroot -p'xxx' \
  --single-transaction \   # InnoDB 一致性快照,不锁表(依赖 MVCC)
  --source-data=2 \        # 备份文件里记录 binlog 位点,注释形式(8.0 参数,旧版 --master-data)
  --triggers --routines --events \  # 别漏掉触发器/存储过程/事件
  --set-gtid-purged=OFF \  # 重建非复制实例时避免 GTID 干扰
  --all-databases > full_$(date +%F).sql
```

单表恢复是逻辑备份的杀手锏：从几百 GB 的文本里 `sed -n '/CREATE TABLE `orders`/,/UNLOCK TABLES/p'` 抽出一段即可执行。

### XtraBackup 原理

XtraBackup 之所以能"在线"物理备份，靠的是**借用 redo log 做一致性对齐**：

```
  1. 启动,拷贝 .ibd 文件        ── 拷贝期间数据还在变,此刻是"碎的"
  2. 同时持续收集新增 redo log   ── 记住拷贝期间发生的变更
  3. 执行 LOCK INSTANCE FOR BACKUP(短暂),记录 binlog 位点后解锁
  4. apply-log:把收集的 redo 重放到备份副本上
       → 得到一个"相当于某时刻 innodb_flush_log_at_trx_commit=1
         停机后"的自洽数据目录
  5. prepare 完成后即可拷到新机器 --copy-back 启动
```

```bash
# [Ubuntu VM] 全量备份一个 docker 实例(8.0 用 xtrabackup 8.x)
docker exec mysql-learn apt-get update -qq && \
  docker exec mysql-learn apt-get install -y -qq percona-xtrabackup-80 2>/dev/null || \
  echo "改用在宿主机装 xtrabackup"

# [Ubuntu VM] 宿主机方式(推荐,容器内装包仅练习用)
sudo apt-get update && sudo apt-get install -y percona-xtrabackup-80
mkdir -p /data/backup/full
xtrabackup --backup --target-dir=/data/backup/full \
  --user=root --password=root123 -H127.0.0.1 -P3306

# [Ubuntu VM] 恢复前必须 prepare
xtrabackup --prepare --target-dir=/data/backup/full
# prepare 完成的目录才可用于启动;输出最后应出现 "completed OK!"

cat /data/backup/full/xtrabackup_binlog_info
# 形如 ./binlog.000003 1570    ← 这就是恢复的起点位点
```

恢复演练流程（生产必做，没恢复过的备份等于没有备份）：

```bash
# [Ubuntu VM] 拷回数据并拉起
docker stop mysql-learn
docker run -d --name mysql-restored -v /data/backup/full:/var/lib/mysql \
  -e MYSQL_ROOT_PASSWORD=root123 -p 3307:3306 mysql:8.0
docker logs mysql-restored 2>&1 | grep -i "ready for connections"
```

### 时间点恢复（PITR）

备份只能回到"昨晚 2 点"，误删发生在"上午 10 点"——中间的差距由 binlog 补齐：

```bash
# [Ubuntu VM] 从备份位点重放到误操作前一刻
mysqlbinlog --start-position=1570 --stop-position=52311 \
  /var/lib/mysql/binlog.000003 | mysql -h127.0.0.1 -P3307 -uroot -proot123
# stop-position 即误删语句所在事件的 End_log_pos,查法见第 4 节
```

## 2. binlog：格式与用途

binlog 记录所有**已提交**的数据变更与 DDL，Server 层产出，是复制与备份的共同基石。三种格式：

| 格式 | 记录内容 | 优点 | 缺点 |
|---|---|---|---|
| STATEMENT | SQL 原文 | 日志量小 | 非确定函数（NOW/UUID/limit）主从不一致，8.0 默认已弃用 |
| ROW | 每行变更前后镜像 | 绝对一致，复制最安全 | 日志量大（一条 UPDATE 1 万行 = 1 万条记录） |
| MIXED | 默认 STATEMENT，风险语句切 ROW | 折中 | 行为不直观，排障要自己判断实际格式 |

生产统一 ROW。代价用 `binlog_row_image=minimal`（只记录变更列）缓解。注意 `binlog_format` 与 `binlog_row_image` 都是**会话级可改**参数，全局改完要确认没有存量连接。

```sql
-- [任意节点] binlog 巡检三连
SHOW VARIABLES LIKE 'log_bin%';          -- ON 才开启了
SHOW VARIABLES LIKE 'binlog_format%';    -- ROW
SHOW VARIABLES LIKE 'binlog_expire_logs_seconds';  -- 8.0 用秒,默认 2592000=30 天
SHOW BINARY LOGS;                        -- 各文件大小
```

binlog 还有审计用途：谁在什么时间改了哪行，`mysqlbinlog --base64-output=decode-rows -vv` 解出来就是完整变更流。

## 3. 主从复制全流程

复制本质是"主库把 binlog 发给从库重放"。三个线程各司其职：

```
   ┌───────── 主库 master ─────────┐      ┌──────── 从库 replica ────────┐
   │                               │      │                              │
   │ 客户端写入 → binlog(顺序追加)   │      │  IO 线程( replica 上)         │
   │                               │      │    ▲ 1. START REPLICA        │
   │  Binlog Dump 线程             │      │    │ 2. 请求指定位点之后日志    │
   │    ▲ 3. 推送 binlog 事件       │──────┼────┘                         │
   │    │                          │ TCP  │    │ 4. 写入 relay log落盘     │
   │    └─ 主库按从库要的位点读取     │      │    ▼                         │
   │                               │      │  SQL 线程( replica 上)        │
   │                               │      │    5. 读 relay log 重放 SQL    │
   │                               │      │    6. 记录已执行位点           │
   └───────────────────────────────┘      └──────────────────────────────┘
```

要点：**dump 线程跑在主库上，IO/SQL 线程都跑在从库上**；relay log 是从库本地的"收件箱"，IO 写、SQL 读，两者可以速率不同——这正是延迟产生的地方。

```sql
-- [任意节点] 从库状态体检(8.0 语法,旧版 SHOW SLAVE STATUS)
SHOW REPLICA STATUS\G
-- 只看五条关键行:
-- Replica_IO_Running: Yes      ← IO 线程活着,在收日志
-- Replica_SQL_Running: Yes     ← SQL 线程活着,在重放
-- Seconds_Behind_Source: 0     ← 延迟秒数
-- Last_SQL_Errno: 0            ← 重放报错就停在这
-- Retrieved_Gtid_Set / Executed_Gtid_Set
```

### 延迟成因与对策

`Seconds_Behind_Source` 的语义是"IO 线程最新收到的日志时间戳减去 SQL 线程当前重放日志时间戳"。它只衡量**重放落后**，主库写 binlog 慢或网络断开期间它可能显示 0 但实际落后（IO 断开时为 NULL）。

| 成因 | 特征 | 对策 |
|---|---|---|
| 从库单线程重放跟不上 | 延迟平稳增长，主库写入高峰时陡增 | 开并行复制（下述 MTIA/LOGICAL_CLOCK） |
| 大事务 | 延迟阶梯式跳变（一条 30 分钟的大 UPDATE） | 主库拆事务；`innodb_flush_log_at_trx_commit` 不动的情况下无解，只能防 |
| 从库机器差/IO 慢 | 换机器就好 | 对等硬件；从库 `innodb_flush_log_at_trx_commit=2` |
| 从库上跑重查询抢资源 | 延迟与慢查询时间吻合 | 分析查询挪走；加读压力隔离 |
| 网络带宽不足 | IO 线程频繁重连，relay 增长慢 | 压缩 `binlog_transaction_dependency_tracking` 时代用 binlog 压缩/升带宽 |
| 表缺少主键（ROW 格式） | SQL 线程对每行更新做全表扫 | 所有表必建主键，这是 ROW 复制的硬要求 |

并行复制关键参数（从库）：

```ini
# [任意节点] my.cnf 或 SET GLOBAL,8.0 推荐组合
replica_parallel_type = LOGICAL_CLOCK     # 按事务组并行(默认)
replica_parallel_workers = 8              # SQL 线程的并行 worker 数
replica_parallel_scheduler = ...          # 8.0 默认即可,不必手写
# 8.0.27+ 用 replica replicaset applier 的 MTIA writeset 更优:
binlog_transaction_dependency_tracking = WRITESET   # 主库上,提高并行度信息密度
```

### GTID

传统位点复制用 `(binlog_file, position)` 对齐主从，手动找位点、切换主库极易出错。GTID（Global Transaction Identifier）给每个事务全局唯一编号 `server_uuid:seq`，从库用 `Executed_Gtid_Set` 自动告诉主库"我缺哪些"。

```sql
-- [任意节点] GTID 一键搭从库(前提:主从都开 gtid_mode=ON,enforce_gtid_consistency=ON)
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='172.30.30.10',
  SOURCE_USER='repl',
  SOURCE_PASSWORD='repl123',
  SOURCE_AUTO_POSITION=1;   -- 核心一行:自动对齐 GTID
START REPLICA;
```

GTID 带来的运维质变：failover 时新主库的 `Executed_Gtid_set` 并集就是真相， Orchestrator/MHA 类工具全靠它；`SET GTID_NEXT` 手工补一个空事务可以跳过重复错误。代价：一个事务只能在一个库上执行一次（不允许在 A 库执行后又导入 B 库），某些"从库上手工改数据"的野路子会直接报错——这是保护不是缺陷。

### 半同步复制

异步复制的主库提交后不等从库，主库宕机时未发送的 binlog 事务就永久丢失（RPO>0）。半同步（semisync）让主库提交后**至少等一个从库 ACK 收到 binlog** 才向客户端返回成功：

```
 异步:  client → master commit → 立即返回 OK        (宕机丢数据)
 半同步: client → master commit → 等 replica ACK ──→ 返回 OK
         rpl_semi_sync_master_wait_for_slave_count=1 (至少 1 个从库确认)
         超时(默认 10s)自动降级回异步,保障可用性
```

```sql
-- [任意节点] 主库安装并启用 after_sync(8.0 默认 lossless)
INSTALL PLUGIN rpl_semi_sync_master SONAME 'semisync_master.so';
SET GLOBAL rpl_semi_sync_master_enabled = 1;
SET GLOBAL rpl_semi_sync_master_timeout = 3000;   -- ms,超时降级异步
-- 从库对应装 rpl_semi_sync_slave 并 SET GLOBAL rpl_semi_sync_slave_enabled=1 后重启 IO 线程
```

注意半同步保证的是"binlog 已到达从库磁盘"，不保证"已重放完成"——主库宕机切换时新主可能有已收未放的事务，需要 Orchestrator 类工具做补齐。这也是 CKS/CKA 里"故障转移不等于高可用"的同款思想。

### 读写分离一致性陷阱

读写分离后"写主读从"立即引入一个窗口：客户端在主库 commit 成功 → 立刻去从库读 → SQL 线程还没重放 → 读到旧值。用户视角就是"我明明保存了，列表里没有"。对策按代价排序：

1. **关键路径强制读主**：写后 N 秒内的同用户请求路由到主库（应用/代理层打标）
2. **GTID 等待**：拿到 commit 返回的 GTID，读从库前 `SELECT WAIT_FOR_EXECUTED_GTID_SET('<gtid>', 1)`，确保该事务已重放
3. **因果会话**：ProxySQL 的 `transaction_persistent`、Java 驱动 `replication:loadBalance` 场景下的 session 粘性
4. **降级为同步读**：对一致性强的账户类操作干脆只读主

```sql
-- [任意节点] 从库上等指定事务重放完(最多等 1 秒)
SELECT WAIT_FOR_EXECUTED_GTID_SET('3E11FA47-71CA-11E1-9E33-C80AA9429562:23', 1);
-- 返回 0=已重放完; 非 0=超时未到,此时读仍可能拿到旧数据
```

## 实战演练

在上一章的 docker 环境上扩展：搭一主一从，亲手摸一遍全流程（lab 里有完整脚本版，这里是讲解版）。

```bash
# [Ubuntu VM] 起主从两个实例
docker network create mysqlnet
docker run -d --name mysql-m --net mysqlnet -e MYSQL_ROOT_PASSWORD=root123 \
  -p 3306:3306 mysql:8.0 --server-id=1 --log-bin=binlog \
  --gtid-mode=ON --enforce-gtid-consistency=ON
docker run -d --name mysql-s --net mysqlnet -e MYSQL_ROOT_PASSWORD=root123 \
  -p 3307:3306 mysql:8.0 --server-id=2 --gtid-mode=ON \
  --enforce-gtid-consistency=ON --read-only=ON
```

```sql
-- [主库容器] 建复制账号
CREATE USER 'repl'@'%' IDENTIFIED WITH mysql_native_password BY 'repl123';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
```

```sql
-- [从库容器] 挂上主库
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-m', SOURCE_PORT=3306,
  SOURCE_USER='repl', SOURCE_PASSWORD='repl123',
  SOURCE_AUTO_POSITION=1;
START REPLICA;
SHOW REPLICA STATUS\G   -- 确认两个线程都是 Yes
```

```sql
-- [主库容器] 造数据验证
CREATE DATABASE shop; USE shop;
CREATE TABLE t1 (id INT PRIMARY KEY, v VARCHAR(50)) ENGINE=InnoDB;
INSERT INTO t1 VALUES (1,'hello'),(2,'world');
```

```sql
-- [从库容器] 验证 + 看延迟
SELECT * FROM shop.t1;
SHOW REPLICA STATUS\G   -- Seconds_Behind_Source 应为 0
```

```sql
-- [从库容器] 模拟重放报错(制造主键冲突)再恢复
STOP REPLICA SQL_THREAD;
INSERT INTO shop.t1 VALUES (3,'local');      -- 从库手工写入
START REPLICA SQL_THREAD;
SHOW REPLICA STATUS\G   -- Last_SQL_Errno=1062,SQL 线程停了
STOP REPLICA; SET GTID_NEXT='主库报错事务的GTID'; BEGIN; COMMIT;
SET GTID_NEXT='AUTOMATIC'; START REPLICA;    -- 注:实操需替换真实 GTID,lab 详述
```

验证方法：主库插入后从库立即可查；制造冲突后 `SHOW REPLICA STATUS` 的 `Last_SQL_Error` 出现 duplicate key，跳过后两个线程恢复 Yes。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `Server has obsolete binaries` 建立复制失败 | 主从 binlog 格式/版本不匹配 | 从库版本 >= 主库；统一 ROW |
| 复制中断 1062/1032 | 从库被手工写入或数据不一致 | GTID 空事务跳过；或重搭从库（数据不一致时唯一正解） |
| mysqldump 恢复后主从断了 | dump 时没带 `--source-data`，从库位点错乱 | 用 GTID + `--source-data` 重做 |
| 半同步时好时坏 | 从库慢导致超时自动降级异步 | 监控 `Rpl_semi_sync_master_status`；调 timeout 前先治从库延迟 |
| XtraBackup 恢复后起不来 | 没有 prepare，或 prepare 后又动了文件 | 流程固定 backup → prepare → copy-back，中间不改动 |
| 备份能恢复但 PITR 差一截 | binlog 保留时间短于备份周期 | `binlog_expire_logs_seconds` > 备份间隔 + 排障窗口 |

## 自测

1. 为什么 mysqldump 加 `--single-transaction` 就能不锁表拿到一致快照，而 MyISAM 表做不到？

<details><summary>答案</summary>

它利用 InnoDB MVCC：在 RR 隔离级别开一个事务，第一条 SELECT 建 Read View，此后导出期间读的都是同一逻辑时刻的旧版本，写入方继续提交互不干扰。MyISAM 不支持事务与 MVCC，没有版本链可依赖，只能靠锁表保证导出期间文件不变。
</details>

2. 从库 `Seconds_Behind_Source=0`，但用户反馈读到旧数据，可能有哪些原因？

<details><summary>答案</summary>

该指标只比较 IO 线程收到的最新日志与 SQL 线程重放位置的差。主库到从库的网络断了且未触发重连检测时从库显示 0（或 NULL 恢复后仍瞬时 0）；更常见的：读写分离下客户端读的是另一台延迟更大的从库；或该查询命中了应用层/ProxySQL 缓存。排查要看各从库独立状态与 `Retrieved_Gtid_Set` 是否还在前进。
</details>

3. ROW 格式下从库重放一条 `UPDATE ... WHERE non_index_col=1` 影响 1000 行，为什么可能比主库执行慢几个数量级？

<details><summary>答案</summary>

ROW 格式重放按主键定位逐行更新；但主库执行时若没有索引，优化器全表扫一次批量更新 1000 行。重放时每行都要按主键查一次并写 redo/binlog，而主库那条语句本身可能没有索引可用时，从库重放的每一行事件在无主键表上会退化为全表扫描定位——1000 次 × 全表扫。这就是"无主键表拖垮从库"的机理。
</details>

4. 半同步 `rpl_semi_sync_master_timeout` 到期降级异步后，主库宕机是否仍可能丢数据？这说明什么？

<details><summary>答案</summary>

会丢。降级后主库不再等从库 ACK，未发送的 binlog 事务随主库消失。说明半同步是"尽力而为的 RPO=0"：它把丢失概率压到极低（需要"从库恰好也同时不可用"），不是绝对保证。要绝对不丢得用同步复制（如 MySQL Group Replication 的多数派确认）或分布式共识存储。
</details>

5. GTID 模式下，误操作 `DROP TABLE` 已在主库执行并被从库重放，如何让集群恢复且 GTID 集合保持连续？

<details><summary>答案</summary>

流程：立即停写入 → 用备份 + binlog PITR 在新实例恢复到 DROP 前一刻 → 由于原主库 Executed_Gtid_Set 已包含 DROP 事务，新实例要与原 GTID 集合"对齐"，把误操作事务用等量空事务填充（或以新实例为源头重新发起复制，放弃旧集合）。核心认知：GTID 不可回滚，恢复目标必须是"重放除误操作外的一切"，这要求 binlog 与备份齐备。
</details>

## 延伸阅读

- MySQL 8.0 Replication 官方文档：https://dev.mysql.com/doc/refman/8.0/en/replication.html
- GTID 官方文档：https://dev.mysql.com/doc/refman/8.0/en/replication-gtids.html
- Semi-Synchronous Replication：https://dev.mysql.com/doc/refman/8.0/en/replication-semisync.html
- Percona XtraBackup：https://docs.percona.com/percona-xtrabackup/8.0/
- mysqlbinlog 官方文档：https://dev.mysql.com/doc/refman/8.0/en/mysqlbinlog.html
