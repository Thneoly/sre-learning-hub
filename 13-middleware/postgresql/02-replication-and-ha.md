# 02 · PostgreSQL 复制与高可用：流复制、逻辑复制、Patroni 与 pgbouncer

> 模块：13-middleware/postgresql ｜ 建议时长：3.5 小时 ｜ 关联认证：—（CKA 备份思想可迁移：etcd 多数派与 Patroni 的脑裂防护同构）；对照参照 13-middleware/mysql/02、13-middleware/redis/02

## 学习目标

- 能画出物理流复制的 walsender/walreceiver 架构，并用 `pg_basebackup` 从零搭一主一从（lab 的理论底座）
- 能解释 `synchronous_commit` 五档语义与 `synchronous_standby_names` 的 FIRST/ANY 语法，按业务选 RPO
- 能解释复制槽如何防 WAL 被清理、又会如何把主库磁盘拖满，以及 `max_slot_wal_keep_size` 的兜底
- 能解释逻辑复制（发布/订阅）与物理复制的适用边界，并把 PG 的 CDC 能力接进 18-bigdata 的同步链路
- 能画出 Patroni + etcd 的 HA 架构，说清 DCS 里存什么、failover 每一步发生什么、脑裂是怎么防的；解释 pgbouncer 为什么是 PG 准标配

## 1. 物理流复制：WAL 的搬运

第 1 章说过：PG 没有 binlog，复制直接消费 WAL。备库起一个 walreceiver 进程，主库每个备库对应一个 walsender 进程，流式推送 WAL 段；备库进入**持续恢复**模式重放——本质是"永远追着做的崩溃恢复"：

```
   ┌──────────── 主库 primary ────────────┐        ┌──────── 备库 standby ────────┐
   │ 客户端写入 → WAL buffer               │        │  walreceiver                  │
   │              │ commit 时 fsync         │        │    ▲ 请求按 LSN 之后的 WAL     │
   │              ▼                        │  TCP   │    │ 写入备库 pg_wal/          │
   │           pg_wal/ (段文件)             │◄──────┼────┘ 启动流: primary_conninfo  │
   │  walsender × N（每个备库一个）          │        │  startup 进程                │
   │  同时推进: 每个段写满后按策略保留/归档    │        │    └ 持续重放 WAL(只读对外服务) │
   └──────────────────────────────────────┘        └──────────────────────────────┘
   级联复制: 备库可以再开 walsender 给下游备库，卸掉主库的发送压力
```

与 MySQL 主从（13-middleware/mysql/02-backup-replication.md#3. 主从复制全流程）的直觉差异：

| 维度 | PG 流复制 | MySQL 主从 |
|---|---|---|
| 复制载体 | WAL（物理页级变更） | binlog（逻辑行变更） |
| 备库执行方式 | **单一 startup 进程按序重放**，物理应用 | SQL 线程重放逻辑事件（可多线程并行） |
| 备库可读 | 天生 hot standby，可加 `hot_standby=on` 查询 | 需专门设计，通常就当只读从库用 |
| 复制进度标识 | LSN（WAL 上的字节位置，单调） | GTID / (file, position) |
| 延迟的本质 | 重放是单线程的，大事务/DDL 重放期间全排队 | 同款问题（Seconds_Behind_Source 的坑两边都有） |

### pg_basebackup 全流程

搭一个备库 = "某个一致时刻的完整数据目录 + 之后的所有 WAL"。`pg_basebackup` 把这两件事一次做完：

```
  1. 连上主库(复制账号,需要 REPLICATION 权限)
  2. 主库发起 checkpoint,取得一致起始点
  3. 拷贝整个数据目录(基础备份;期间数据在变,靠同时流式拉取的 WAL 保证末端一致)
  4. -X stream: 拷贝期间产生的 WAL 也一并拉回来
  5. -R: 在备份目录写 standby.signal + primary_conninfo(postgresql.auto.conf)
  6. 备库启动 → walreceiver 上线 → 追平 → streaming
```

前提参数（主库）：`wal_level=replica`（默认）、`max_wal_senders`（默认 10）、复制账号 `GRANT REPLICATION`。与 XtraBackup"拷贝后还要 apply-log 对齐 redo"（mysql/02#XtraBackup 原理）相比，PG 走的是更彻底的路线：备库**始终**在做恢复，基础备份只是恢复的起点，不存在"prepare"环节。

### 同步级别：synchronous_commit 与 standby 名单

异步（默认）下主库提交不等备库，主机宕机时未送达的 WAL 事务丢失（RPO>0）。PG 的同步控制粒度到**每个事务的提交点**，比 MySQL 半同步（mysql/02#半同步复制，整库开关）细：

| synchronous_commit | 提交返回前等到什么 | 丢什么 | 典型用途 |
|---|---|---|---|
| off | WAL 落 OS cache 即可（延迟 fsync） | 宕机最多丢 `wal_writer_delay`×3（默认 200ms，即约 0.6 秒） | 日志类，可丢 |
| local | 本地 fsync，**完全不管备库** | 主机宕丢未发 WAL | 单机等价 MySQL 双 1 |
| remote_write | 备库**收到**（写入其 OS cache，未 fsync） | 备库主机也同时断电才丢 | 折中，延迟最低的"同步" |
| on | 备库已 fsync 到磁盘 | 主备同时毁才丢（标配"同步复制"） | 金融 |
| remote_apply | 备库已**重放**并可查询 | 同上，且读备库一定读到 | 读写分离要强一致 |

`on/remote_apply` 生效还需要主库配置同步备库名单（`postgresql.conf`）：

```ini
# [任意节点] 主库 postgresql.conf，FIRST/ANY 两族语法
synchronous_standby_names = 'FIRST 1 (s1, s2)'   # 优先级列表里任意 1 个确认即可
# synchronous_standby_names = 'ANY 2 (s1, s2, s3)'  # 仲裁组(quorum)任意 2 个
```

排障要点：名单里的名字必须与备库 `primary_conninfo` 里的 `application_name` 完全一致——**名字对不上时主库会认为没有同步备库，所有提交直接挂起**，表现为写入全部卡死（不是变慢），`pg_stat_replication` 里看不到匹配名。这是同步复制第一大坑。

### 复制槽：防 WAL 清理的双刃剑

默认情况下主库按 `wal_keep_size`（PG13+，旧版 `wal_keep_segments`）多留一些 WAL，够"最近断线"的备库追上；但断线太久、WAL 被复用，备库就只能重新 pg_basebackup。**物理复制槽**让备库向主库"预订"WAL：

```sql
-- [任意节点] 主库建槽(备库 primary_conninfo 里同名引用)
SELECT pg_create_physical_replication_slot('s1');
-- 有槽之后: 主库不回收 s1 还没确认收到的 WAL 段
```

代价立竿见影：备库挂 48 小时，主库 WAL 就堆 48 小时，磁盘满、`pg_wal` 目录暴涨、写入全停。这是 PG 事故榜前排的场景（第 3 章坑表再收）。兜底参数：

```ini
# [任意节点] 主库 postgresql.conf，防废弃槽拖死磁盘
max_slot_wal_keep_size = 100GB   # PG13+，单个槽最多 pin 住 100GB，
                                 # 超过则槽进入 lost 状态(备库需重建)，磁盘保住
```

```sql
-- [任意节点] 主库巡检三连
SELECT application_name, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS replay_lag_bytes,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;        -- 每行一个备库;sync_state=sync 才是同步备库
SELECT slot_name, slot_type, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;       -- retained 持续增长 = 下游没人消费,查槽!
```

## 2. 逻辑复制：发布/订阅与 CDC

物理复制传的是"页级变更"，备库必须与主库**同一大版本、同一物理布局**，且整个实例一起复制。逻辑复制把 WAL 解码（logical decoding）成**行级变更流**再投递，主备解耦：

```
   发布端(publisher)                        订阅端(subscriber)
   wal_level=logical                        CREATE SUBSCRIPTION sub
   CREATE PUBLICATION pub FOR TABLE ...       CONNECTION '...' PUBLICATION pub
        │                                        │
        ▼                                        ▼
   pgoutput 解码 WAL ──► walsender ──TCP──► 应用端(apply worker)
   (表级/库级筛选,只发订阅的表)              初始COPY同步 + 增量应用
```

与物理复制的关键差异和限制：

| 维度 | 物理流复制 | 逻辑复制 |
|---|---|---|
| 单位 | 整个实例 | **表级**（发布里选） |
| 版本/平台 | 必须同大版本 | 跨大版本、跨平台均可 |
| DDL | 随 WAL 复制 | **不复制**，两边手工同步 |
| 序列状态 | 复制 | 不复制（切换后要 reset） |
| 订阅端 | 只读 | 可写（多源汇聚） |
| 要求 | wal_level=replica | 发布端 wal_level=logical |

运维上两个硬点：一是 UPDATE/DELETE 要能复制，表必须有主键（或 REPLICA IDENTITY），否则订阅端报错应用停摆；二是大版本升级（PG14→16）的经典姿势就是"逻辑订阅新库 + 追平 + 切流"，避开了 pg_upgrade 的原地风险。

### 逻辑复制与 CDC：接进大数据链路

18-bigdata 讲过两条同步链路：离线批链路 `业务 MySQL ──DataX/CDC──► HDFS(Hive 表/湖表)`、实时链路 `业务库 ──CDC──► Kafka ──Flink──► Doris/StarRocks`（见 18-bigdata/00-bigdata-overview.md#2. 三条典型数据链路）。PG 在这些链路里扮演**源端**时，靠的就是同一套 logical decoding 机制：

```
  全量+增量(DataX 路线):  DataX/同步工具 ──SELECT 全量──► 湖表          (T+1)
  增量流(CDC 路线):       PG ──逻辑解码(pgoutput/wal2json)──► Debezium ──► Kafka ──Flink──► Doris/湖
                          复制槽 pin 住 WAL(消费位点在 Kafka/Connect 侧)
```

也就是说：`CREATE PUBLICATION` 手工配发布/订阅是"PG 对 PG"的用法；把解码结果交给 Debezium/Flink CDC 进 Kafka，是"PG 对数据平台"的用法——两者底层都是 replication slot + logical decoding。SRE 关注点随之统一：**消费端（订阅 worker 或 Kafka Connect）停摆，槽的 restart_lsn 就停在原地，主库 WAL 堆积**——上一节的坑在 CDC 链路同样成立，且更常见（Flink 作业挂一晚，PG 磁盘告警）。湖表格式对 CDC 流的取舍见 18-bigdata/07-lakehouse-table-formats.md，此处不展开。

## 3. Patroni + etcd：高可用架构

流复制本身只解决"有备库"，**谁判断主库死了、怎么切、怎么防脑裂**要靠外部组件。Patroni 是事实标准：每个 PG 节点跑一个 Patroni 进程，全部依赖一个分布式配置存储（DCS，通常 etcd，也可 ZooKeeper/Consul——正好复用 18-bigdata/06-zookeeper 的多数派心智）：

```
                        ┌──────────────── etcd 集群(3/5 节点,多数派) ─────────────┐
                        │  /service/pg/initialize   集群初始化信息                  │
                        │  /service/pg/leader       {hostname, pid} + TTL 锁       │
                        │  /service/pg/optime/leader 最后确认的主库 LSN(failover 依据)│
                        │  /service/pg/members/xx   各成员状态/连接串/角色           │
                        │  /service/pg/config      集群级 postgresql 参数           │
                        └───────▲──────────────▲──────────────▲───────────────────┘
                                │ watch/续约    │              │
                     ┌──────────┴───┐  ┌───────┴────┐  ┌──────┴─────┐
                     │ patroni       │  │ patroni     │  │ patroni    │
                     │ ┌──────────┐ │  │ ┌────────┐  │  │ ┌────────┐ │
                     │ │ PG 主库   │ │  │ │ PG 副本 │  │  │ │ PG 副本 │ │
                     │ └──────────┘ │  │ └────────┘  │  │ └────────┘ │
                     └──────────────┘  └─────────────┘  └────────────┘
   客户端 ──► HAProxy/DNS/VIP(探活每个节点 patroni REST :8008 的 /master /replica)
```

**DCS 存的是"真相源"而不是数据**：leader key 是一把带 TTL 的原子锁——谁持有它谁才是主库，PG 的身份由外部仲裁而非自己声称，这是与"哨兵观察主库"（13-middleware/redis/02-persistence-and-ha.md#6. 哨兵 Sentinel，观察者视角）最本质的不同。

failover 全流程（自动，`ttl=30s`、`loop_wait=10s` 一档默认值，可调）：

```
  t0   主库 Patroni 续约失败(主库挂/网络分区/etcd 抖动)
  t0+  其余成员 watch 到 leader key 过期消失
  t0+  候选副本们竞选: 通过 DCS 的一次 CAS 写抢 leader key
        ── 先比 optime/leader 的 LSN(数据最全者优先),落后太多的连竞选资格都没有
  t1   赢家调用 pg_ctl promote 提升本地 PG 成新主,更新 optime
  t1+  其余副本自动改 primary_conninfo 指向新主(pg_rewind 拉回分叉的 WAL)
  t2   HAProxy 探到新主的 /master 返回 200,读写流量切过去
  t3   旧主恢复 ── Patroni 发现 DCS 里 leader 是别人 ── 自降为副本(或先 rewind 再跟)
```

脑裂防护是这套设计的核心卖点，两层：**leader 续约失败后 Patroni 会主动 demote 自己**（`pg_ctl stop -m fast` 杀掉本地 PG），宁可停写也不允许"没有 DCS 授权仍然自称主库"；而 etcd 本身多数派存活才能写（同 Redis 哨兵的 majority、MongoDB 副本集多数派——18-bigdata/06 与 13-middleware/mongodb/02 反复出现的同一条定理），网络分区时少数派侧谁也抢不到锁，旧主又被 demote，双主无从发生。边界同样要认清：若 DCS 整体不可用，集群会收敛到"无人是主、全部只读"——**可用性让位于一致性**，业务必须有降级预案；Patroni 2.x 的 `failsafe_mode` 可以在 etcd 整体故障但副本可达时保守地维持主库，语义细节以官方文档为准。

K8s 上的部署形态是 Operator（如 CrunchData postgres-operator、Zalando postgres-operator/Spilo 内建 Patroni）或直接 StatefulSet + 专属 etcd，把上面的流程封装成 CR；本地/虚机环境用 pip 装 patroni + etcd 单实例即可体验（lab 环境为了判分简单走的是手工流复制，Patroni 流程按本节对照理解）。

## 4. pgbouncer：进程模型的账单

第 1 章的伏笔在此收口：每连接一个进程，意味着"1000 个客户端连接 = 1000 个进程"，fork 风暴、内存、调度开销全都上线。pgbouncer 用一个事件驱动的单线程进程（同 nginx 的模型，见 13-middleware/nginx）把这 1000 个客户端连接复用到几十个服务端连接上：

```
  客户端 ×1000 ──► pgbouncer(单进程,每连接仅一个 fd + ~2KB) ──► PG 服务端连接 ×50
                   池化模式决定"一个服务端连接被谁用多久"
```

三种 pool_mode：

| 模式 | 服务端连接绑定到 | 优缺点 |
|---|---|---|
| session | 客户端断开才归还 | 最透明，但客户端连着不放就没池化效果——应用连接池泄漏时等于白装 |
| **transaction（推荐）** | 事务结束即归还 | 复用率最高，一个客户端空闲时不占服务端进程 |
| statement | 每条语句后归还 | 不允许多语句事务（强制 autocommit），极少用 |

transaction 模式的边界必须背下来：跨事务的会话状态会被别人"踩"——`SET`/`RESET`、会话级 advisory lock、`LISTEN/NOTIFY`、带状态临时表都不可用或需改造；预编译语句在新版 pgbouncer 已支持协议级 named prepared statements（1.21+，历史版本是重灾区，以 pgbouncer 官方 release notes 为准）。Java/Go 客户端侧连接池 + 服务端 pgbouncer 的两层池如何分工（客户端管事务边界、pgbouncer 管进程数）是容量设计的常规题。

对照 MySQL：mysqld 线程模型下几百直连并不致命，ProxySQL 更多承担路由/防火墙/查询改写；PG 场景 pgbouncer 解决的是**生存问题**（进程数），功能上反而简单。选型记忆点：**MySQL 的池是治理，PG 的池是刚需**。

## 5. 完整对照：PG 流复制+Patroni vs MySQL 主从+哨兵

把两套已学方案放进一张表（PG 列默认指流复制+Patroni+pgbouncer 标配组合；MySQL 列指 binlog 主从+半同步+哨兵类工具，见 mysql/02 与 redis/02#6）：

| 维度 | PostgreSQL | MySQL（对照） |
|---|---|---|
| 复制载体 | WAL 物理流，备库单进程重放 | binlog 逻辑事件，SQL 线程可并行（MTIA） |
| 大事务重放 | 全队排队，单事务重放期间延迟陡增 | 同样排队，但并行复制可缓解 |
| 一致性位点 | LSN（单调字节位） | GTID 集合（有"空事务补齐"类技巧，mysql/02#GTID） |
| RPO 分档 | synchronous_commit 五档 × FIRST/ANY 名单，逐事务可选 | 异步/半同步（超时降级）两档 |
| 备库读 | hot standby 天生可读（可配递增恢复延迟） | 只读从库，replica 照常 |
| 故障仲裁 | etcd 多数派 + leader TTL 锁（真相在 DCS） | 哨兵 quorum 观察多数派 + majority 选 leader 执行 |
| 旧主回归 | Patroni 检测无授权即 demote，pg_rewind 拉回 | 哨兵 convert-to-slave，全量重同步（replid2 可免） |
| 脑裂防护 | demote 优先 + DCS 写多数派 | min-replicas-to-write 缩小损失窗口（redis/02#6.4 同款） |
| 主库身份暴露 | REST /master 探活 + HAProxy/VIP | 哨兵查询 get-master-addr-by-name |
| 连接池 | pgbouncer 刚需 | ProxySQL 治理 |
| 特有事故 | 复制槽堆积 WAL 拖满磁盘、wraparound | 无主键表拖垮 SQL 线程、GTID 野路子报错 |

## 实战演练

环境：装有 Docker 的 Ubuntu VM。目标：搭一主一从流复制并观察同步/槽/延迟三件事。**完整可判分版在 `labs/01-streaming-replication`（task.md + check.sh + solution.md），本章是讲解版**，命令与 lab 保持同构便于对照。

```bash
# [Ubuntu VM] 起主库:开复制参数,建复制账号
docker network create pgnet
docker run -d --name pg-m --net pgnet -e POSTGRES_PASSWORD=pg123 \
  -p 5432:5432 postgres:16 \
  -c wal_level=replica -c max_wal_senders=10 -c hot_standby=on
docker exec pg-m psql -U postgres -c \
  "CREATE ROLE repl REPLICATION LOGIN PASSWORD 'repl123';"
# pg_hba 放行复制连接:复制的目标不是普通库而是伪数据库 replication,
# 镜像默认只追加 host all all all scram-sha-256,all 不匹配 replication,
# 漏掉这条 pg_basebackup/walreceiver 都会被拒(no pg_hba.conf entry for replication)
docker exec pg-m bash -c 'echo "host replication repl all scram-sha-256" >> $PGDATA/pg_hba.conf'
docker exec pg-m psql -U postgres -c "SELECT pg_reload_conf();"
docker exec pg-m psql -U postgres -c \
  "SELECT pg_create_physical_replication_slot('s1');"   # 先建槽,备库稍后引用
```

```bash
# [Ubuntu VM] 用 pg_basebackup 直接产出备库数据目录
mkdir -p /root/pg-standby && chmod 777 /root/pg-standby
docker run --rm --net pgnet -v /root/pg-standby:/data \
  -e PGPASSWORD=repl123 postgres:16 \
  pg_basebackup -h pg-m -U repl -D /data -X stream -R
# -X stream: 拷贝期间 WAL 一并流式拉取; -R: 自动写 standby.signal + primary_conninfo
ls /root/pg-standby/standby.signal && echo "备库目录就绪"
```

```bash
# [Ubuntu VM] 起备库:application_name 供同步名单引用,primary_slot_name 挂上槽
docker run -d --name pg-s --net pgnet -v /root/pg-standby:/var/lib/postgresql/data \
  -p 5433:5432 postgres:16 \
  -c primary_conninfo='host=pg-m port=5432 user=repl password=repl123 application_name=s1' \
  -c primary_slot_name=s1
```

```sql
-- [主库容器] 验证与观测
SELECT application_name, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
-- 预期: s1 | streaming | async | 0 或很小的字节数

CREATE TABLE repl_demo (id int primary key, v text);
INSERT INTO repl_demo VALUES (1,'hello');
```

```sql
-- [备库容器] 复制生效 + 只读
SELECT * FROM repl_demo;            -- 能查到 hello
INSERT INTO repl_demo VALUES (2,'x');
-- 预期报错: cannot execute INSERT in a read-only transaction
```

```sql
-- [主库容器] 实验:槽保 WAL + 同步名单的"卡死"风险
-- 先停掉备库(另一终端): docker stop pg-s
-- 主库制造一批 WAL(约 30MB,足够填满两个段):
CREATE TABLE junk AS SELECT g, repeat('x',100) FROM generate_series(1,200000) g;
SELECT slot_name, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained
FROM pg_replication_slots;
-- 预期: active=false, retained 几十 MB——主库在为死掉的备库囤 WAL
-- 另一终端: docker start pg-s,稍等后重查,retained 回落(active=t)

-- 再试同步复制(注意 s1 必须与 application_name 完全一致):
ALTER SYSTEM SET synchronous_standby_names = 'FIRST 1 (s1)';
SELECT pg_reload_conf();
INSERT INTO repl_demo VALUES (3,'sync');   -- 此刻提交要等备库 fsync(慢一点点)
ALTER SYSTEM SET synchronous_standby_names = '';
SELECT pg_reload_conf();
-- 若把名字写成 (sX): 所有写入立即挂起,Ctrl-C 后改回名单即恢复——亲手踩一次最有效
```

验证方法：`pg_stat_replication` 出现 `s1 | streaming`；备库可读不可写；停备库后槽的 retained 增长、重启后回落。清理：`docker rm -f pg-m pg-s; docker network rm pgnet; rm -rf /root/pg-standby`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 主库磁盘被 `pg_wal` 涨满 | 复制槽（含 CDC 槽）把 WAL pin 住，下游挂了 | `max_slot_wal_keep_size` 兜底；监控槽 retained；废弃槽 `pg_drop_replication_slot` |
| 配了同步复制后写入全部挂起 | `synchronous_standby_names` 与备库 `application_name` 不匹配 | 两处名字严格一致；先配名单外再配事务再验证 |
| pg_basebackup 报权限/连不上 | 复制账号没有 REPLICATION、pg_hba 没放行复制连接 | 账号授权 + `pg_hba.conf` 加 `host replication repl ...`（重载） |
| 备库重启后变慢甚至触发重新备份 | 断线太久，所需 WAL 已被复用 | 加复制槽（配合兜底参数）；或调大 `wal_keep_size` |
| 逻辑复制应用停摆报 no replica identity | 订阅的表没主键，UPDATE/DELETE 无法定位行 | 表补主键/REPLICA IDENTITY FULL（代价：全行日志） |
| 逻辑订阅端表结构不一致后中断 | DDL 不复制，两边 schema 漂移 | DDL 变更流程里把两端一起改；升级窗口做校验 |
| Patroni 集群"全只读不切换" | etcd 失去多数派（挂 2/3） | 修 DCS 是唯一正解；容量规划保证 etcd 奇数多机房分布 |
| 应用连 pgbouncer 报 prepared statement 错误 | transaction 池 + 旧版 pgbouncer 不支持 named statements | 升级 pgbouncer（1.21+）或客户端禁用 server-side prepare |

## 自测

1. 为什么说"Patroni 的主库身份在 DCS 里，哨兵的主库身份在主库自己身上"？这个差异对脑裂防护意味着什么？

<details><summary>答案</summary>

哨兵体系里，主库自己并不知道被换了，它凭本地状态继续接受写，防护靠"观察者多数派判定 + min-replicas-to-write 缩小窗口"，本质是事后纠正。Patroni 体系里 leader key 是 etcd 中带 TTL 的原子锁，主库的写权限由"我能否持续续约"决定；续约失败 Patroni 主动 demote（停掉本地 PG），旧主在分区期间物理上停止服务。前者是"允许发生再纠正"，后者是"发生前就没收权柄"——代价是 Patroni 主库对 DCS 有硬依赖，etcd 整体不可用时宁可全只读。
</details>

2. 备库挂了 24 小时后恢复，分别在"没用槽"和"用了槽"两种部署下会发生什么？

<details><summary>答案</summary>

没用槽：主库只保留 `wal_keep_size` 窗口内的 WAL，24 小时的增量大概率超过窗口，备库所需的 WAL 已被复用，只能重新 pg_basebackup（大库可能是小时级重建）。用了槽：主库一直为该槽保留未确认的 WAL，备库重启后从 restart_lsn 继续追平，无需重建；但主库这 24 小时磁盘持续增长，若无 `max_slot_wal_keep_size` 兜底可能先把自己写挂。槽把"备库断线的代价"从重建转嫁成了主库磁盘压力——必须配套监控。
</details>

3. `synchronous_commit=remote_write` 与 `on` 的丢失窗口差在哪？什么业务应该选哪个？

<details><summary>答案</summary>

remote_write：备库 walreceiver 已把 WAL write 到它的 OS page cache 并确认，但未 fsync——主备同时宕机（备库也断电）时这批 WAL 丢失。on：备库已 fsync 到磁盘，只有存储物理损坏才丢，等价 MySQL after_sync 半同步的强度。remote_write 少一次备库 fsync 往返，延迟更低。选型：能容忍"主备同时断电级事故丢少量事务"的（大部分互联网业务日志/计数）选 remote_write 换性能；资金、订单核心选 on；要求"提交即可读备库"的读写分离再上 remote_apply。
</details>

4. 为什么逻辑复制不能复制 DDL，而物理复制天然可以？

<details><summary>答案</summary>

物理复制搬运的是 WAL 里"哪个页怎么变"的物理记录，DDL 改的 catalog 页也是页，重放后结构自然一致——备库根本不知道发生过 DDL。逻辑复制要先经 logical decoding 把 WAL 解码成行级变更语义流，解码依赖 schema（列名/类型）；DDL 本身没有对应的行事件可表达，且发布端改了列、订阅端没改，解码出的行事件立刻无法应用。所以逻辑复制的运维纪律是"DDL 两端手工同步、先订后发"。
</details>

5. Flink CDC 作业挂了一晚上，为什么 PG 主库磁盘告警的元凶常常是复制槽？该怎么防？

<details><summary>答案</summary>

Debezium/Flink CDC 靠逻辑复制槽消费 WAL：槽的 confirmed_flush_lsn 由消费端推进，作业停摆期间位点不动，主库必须为该槽保留从 restart_lsn 起的所有 WAL——一晚上的写入量全部堆在 pg_wal。防：主库设 `max_slot_wal_keep_size`（PG13+）给每个槽设上限，超过后槽失效（宁可重建同步也不写死主库）；监控 `pg_replication_slots` 的 retained 字节与 wal_status；CDC 作业自身配 checkpoint 让重启后能续传而非从头全量。
</details>

## 延伸阅读

- 官方手册 High Availability, Load Balancing, and Replication：https://www.postgresql.org/docs/current/high-availability.html
- 官方手册 Streaming Replication Protocol / pg_basebackup：https://www.postgresql.org/docs/current/app-pgbasebackup.html
- 官方手册 Logical Replication（发布/订阅/限制清单）：https://www.postgresql.org/docs/current/logical-replication.html
- 官方手册 Replication Solutions（含同步复制与槽）：https://www.postgresql.org/docs/current/warm-standby.html
- Patroni 官方仓库（DCS key 布局与 failsafe_mode 文档）：https://github.com/patroni/patroni
- pgbouncer 官方特性文档（pool_mode/prepared statements 支持版本）：https://www.pgbouncer.org/features.html
