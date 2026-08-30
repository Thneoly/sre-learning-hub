# 03 · Hive 与数仓分层：metastore、ORC 与 ODS→ADS

> 模块：16-bigdata ｜ 建议时长：4 小时 ｜ 关联认证：—（无直接考点；metastore 底层的 MySQL 备份、HS2 连接排障大量复用 11-middleware/mysql 与 08-pca 的知识）

前置：本章假设你已读完 `16-bigdata/01-hdfs.md`（NameNode、小文件问题）与 `16-bigdata/02-yarn.md`（容器与队列）。

## 学习目标

- 能画出 Hive 三大件（HiveServer2、metastore、HDFS 数据）的关系图，并解释 metastore 三种部署形态为什么生产只选独立（remote）模式
- 能对比 TextFile/ORC/Parquet 的压缩率、谓词下推与生态差异，说清"生产 ORC 居多"的原因
- 能用分区裁剪与分桶解释一条慢查询的物理原因，说明分桶何时缓解倾斜、何时不缓解
- 能说出 ODS/DWD/DWS/ADS 各层职责，并解释分层对任务依赖定位、告警归层、存储治理的实际收益
- 能完成 metastore 后备 MySQL 的备份策略、HS2 连接打满的排障流程、小文件合并例行任务

## 1. 架构总览：SQL 如何变成 HDFS 上的作业

Hive 的本质是两样东西的组合：一个**把 SQL 编译成分布式作业的编译器**，加一个**存在关系库里的元数据中心（metastore）**。数据本体永远是 HDFS 上的文件，Hive 只负责"表结构 → 目录/文件路径"的映射。

```
 beeline/JDBC ──► HiveServer2 (Thrift 10000)
                     │ ① parse → semantic analyze → 逻辑/物理计划
                     │ ② 查元数据：表在哪、分区在哪、什么格式
                     ▼
                 metastore (Thrift 9083) ──► MySQL/PostgreSQL（元数据）
                     │ ③ 返回表→HDFS路径映射、分区列表
                     ▼
                 执行引擎（可插拔）──► YARN 容器（见 02-yarn.md）
                     │ ④ 作业读写 HDFS
                     ▼
        /warehouse/dwd_order/dt=2026-08-29/*.orc   ← 数据本体
```

对 SRE 的含义：**排障先分清是哪一半坏了**。SQL 报"表不存在/分区不存在"是 metastore（元数据）侧；作业跑得慢、文件读不出来是 HDFS/引擎侧；连接挂起是 HS2 侧。三者是独立进程，独立重启，独立看日志。

## 2. metastore 三种部署形态：为什么生产只认独立模式

| 形态 | metastore 进程位置 | 元数据库 | 生产可用性 |
|---|---|---|---|
| embedded | 与 HS2 同 JVM | 内嵌 Derby | 仅实验：Derby 一次只允许一个连接，库文件级锁 |
| local | 与 HS2 同 JVM | 外部 MySQL | 小规模可用：HS2 挂 metastore 跟着挂；每个 HS2 各自建 JDBC 连接，连接数随 HS2 扩容线性涨 |
| remote（独立） | 独立进程，Thrift 9083 | 外部 MySQL | **生产标准**：JDBC 连接收敛到 metastore 一处；故障域隔离；Spark/Trino/Presto 等多引擎共享同一套元数据 |

```
embedded/local:   [HS2 JVM：编译 + metastore 服务] ──JDBC──► MySQL
                            ▲ 一荣俱荣一损俱损

remote（生产）:   [HS2]──thrift──► [metastore] ──JDBC(连接池)──► MySQL
                  [Spark Thrift Server]──thrift──┘      └──► HDFS 文件
                  [Trino/Presto]─────────┘
                  metastore 可起多个实例挂负载均衡实现 HA
```

remote 模式的三个真实收益：

1. **连接收敛**：MySQL 侧只看到 metastore 进程的连接池，而不是"HS2 数 × 每实例连接数"。MySQL 连接数打满的排障思路见 `11-middleware/mysql/03-tuning-troubleshooting.md`。
2. **故障隔离**：HS2 被 BI 大查询拖死时，metastore 仍能服务 Spark 提交（元数据操作不等 SQL）。
3. **多引擎共享**：Spark SQL/Trino/Doris 外表都可以直连同一 metastore，表目录全公司唯一——这也是 Hive 在很多公司"只剩 metastore"还拆不掉的原因（第 8.4 节）。

配置上就是一行（HS2 与其他引擎侧）：

```xml
<!-- [hive-site.xml（HS2 / Spark / Trino 侧）] -->
<property>
  <name>hive.metastore.uris</name>
  <value>thrift://metastore-1:9083,thrift://metastore-2:9083</value>
</property>
```

## 3. HiveServer2 与执行引擎演进 MR→Tez→Spark

HiveServer2（HS2）是 JDBC/ODBC 的接入层：每个连接对应一个 session（占 HS2 JVM 堆内存），并发连接数直接决定 HS2 的内存压力（第 8.2 节排障）。多实例用 ZooKeeper 服务发现，JDBC URL 写成 `jdbc:hive2://zk1:2181,zk2:2181/db;serviceDiscoveryMode=zooKeeper;zooKeeperNamespace=hiveserver2`。

执行引擎是可插拔的（`hive.execution.engine`），三代演进的分水岭是**中间结果怎么落地**：

```
MapReduce：  SQL → 多个 MR 作业串行 ──► 每个 MR 中间结果写 HDFS ──► 慢但极稳
Tez：        SQL → 一个 DAG ──► 中间结果留内存/本地盘、容器复用 ──► 少 3~10 次 HDFS 往返
Spark：      SQL → RDD DAG ──► 内存管道 + whole-stage codegen ──► 见 04-spark.md
```

| 引擎 | 中间结果 | 相对速度 | 生产现状 |
|---|---|---|---|
| MR | 全部落 HDFS | 基准 1x | 遗留任务、对稳定性要求极高的批量 |
| Tez | 内存/本地盘 | 2~5x | Hive on Tez 是 Hive 3.x 生态（CDP/HDP）的默认 |
| Spark | 内存为主 | 3~10x | 多数新平台直接用 Spark SQL 读 Hive 表 |

Apache 发行版与各商业发行版的默认引擎不同，**以你所用版本的 hive-default.xml 为准**。

## 4. 存储格式：为什么生产用 ORC 居多

| 维度 | TextFile | ORC | Parquet |
|---|---|---|---|
| 存储形态 | 行存文本 | 列存 + stripe/row group 索引 | 列存 + row group/page 索引 |
| 压缩率（同数据，zstd 级，经验量级） | 基准 1x | 4~10x | 3~8x |
| 谓词下推 | 无 | stripe 与 row group 级 min/max + bloom filter | row group/page 级 min-max |
| 可分裂性 | 需 lzo/bzip2 索引 | 天然按 stripe 切 | 天然按 row group 切 |
| 行级 ACID | 否 | 是（Hive 唯一原生支持） | 否（Hive 内） |
| 向量化执行 | 否 | 最早支持 | 支持 |
| 生态默认 | 导入导出/外部交换 | Hive 系 | Spark/Impala/Trino 系 |

列存压缩率高的原因很朴素：**同列数据类型相同、重复度高**，排序后 RLE/字典编码效果远好于行存的混合类型字节流。

```
行存(TextFile)： [1,张三,沪,29.9][2,李四,沪,9.9]...   ← 类型混杂，只能 gzip 整体压
列存(ORC)：      id:[1,2,...] city:[沪,沪,...]          ← 同列同类型，字典+RLE 后 city 列几乎为 0
                └─ stripe（默认数十~256MB，以版本默认值为准）
                    ├─ Index Data：每 10000 行一组的 min/max（谓词下推的依据）
                    ├─ Row Data：列式数据
                    └─ Stripe Footer / File Footer：统计信息
```

谓词下推（PPD）的物理含义：`WHERE dt='2026-08-29' AND amount > 100` 时，reader 先读 footer 的 min/max（可选 bloom filter），**整块跳过**不可能命中的 stripe/row group，不反序列化。生产用 ORC 居多的原因排序：① Hive 原生优化（向量化、ACID）都先落在 ORC；② 压缩与统计信息最全；③ Hive 系工具链（compaction、CONCATENATE）只对 ORC 完整支持。若你的平台主引擎是 Spark/Trino，Parquet 同样合理——**跟着平台默认走，别混用**。

## 5. 分区与分桶：两个不同粒度的物理拆分

**分区 = 目录**。`PARTITIONED BY (dt STRING)` 让每个日期一个子目录：

```
/warehouse/dwd_order/
├── dt=2026-08-28/
│   └── 000000_0
└── dt=2026-08-29/          ← WHERE dt='2026-08-29' 时编译期只 listStatus 这一个目录
    ├── 000000_0
    └── 000001_0
```

分区裁剪（partition pruning）发生在**编译期**：优化器把分区列上的过滤条件变成目录列表，未命中的目录物理上不被打开。这就是"查询必须带分区列过滤"的物理原因——不带 dt 的全表查询会扫描所有目录。

**分桶 = 文件**。`CLUSTERED BY (user_id) INTO 64 BUCKETS` 让每个分区内数据按 `pmod(hash(user_id), 64)` 拆到 64 个文件：

- 两张表按 **join key 分桶且桶数成倍数**时，可以做 bucket map join / SMB join：每对桶文件本地 join，**省掉整表 shuffle**；
- 分桶让文件数可控、大小更均匀，缓解"多个 key 分布不均"造成的任务长尾；
- 但分桶救不了"单个热点 key"：`user_id=0` 占 90% 数据时，不管分多少桶，这些行仍落在同一个桶文件——那是加盐的活（见 `04-spark.md` 第 5 节数据倾斜三板斧）。

分区的坑是**过度分区**：分钟级分区 + 流式入仓 = 每天上千个小目录，直接冲击 NameNode（回顾 `01-hdfs.md` 的小文件一节）。

## 6. 数仓分层：ODS/DWD/DWS/ADS

分层是**团队规范**，不是 Hive 的功能——但对运维的影响是实打实的：

```
业务库 binlog / Kafka / 埋点日志
        │  Flink/DataX 同步（见 12-data-streaming/flink）
        ▼
┌────────────────────────────────────────────────────────────┐
│ ADS  应用层   报表/大屏/API 指标          小、离线调度末端   │
├────────────────────────────────────────────────────────────┤
│ DWS  汇总层   "谁+天"粒度的主题宽表        中、可由下层重算  │
├────────────────────────────────────────────────────────────┤
│ DWD  明细层   清洗/去重/维度补齐的事实明细  大、长期保留     │
├────────────────────────────────────────────────────────────┤
│ ODS  贴源层   原样入仓 + dt 分区，TTL 短    最大、可回源重灌 │
└────────────────────────────────────────────────────────────┘
```

| 层 | 职责 | 典型操作 | 运维视角 |
|---|---|---|---|
| ODS | 贴源保真 | 加 etl_time、按 dt 分区，不改业务字段 | 挂了影响下游**全部**，告警最高级；TTL 最短（如 90 天），可用更高压缩 |
| DWD | 明细事实 | 去重、类型规范化、维度补齐、行转列 | 数据质量问题大多在这一层暴露 |
| DWS | 轻度汇总 | 按"用户+天"等粒度预聚合 | 重算代价中等 |
| ADS | 面向应用 | 指标拼装，直接喂 BI/API | 失败只影响某张报表，优先级按业务定 |

**运维为什么要懂数仓分层**，三个日常场景：

1. **任务依赖定位**：凌晨值班收到"ads_sales_city 日报表数据不对"，第一步不是看 ADS 任务，而是沿血缘向下游→上游走：`ADS 指标错 → DWS 某分区空 → DWD 上游 Kafka 那小时缺数 → ODS 分区缺失`。分层让"沿血缘回溯"有明确的站牌，5 分钟定位是哪个环节的锅。
2. **告警归层**：ODS 任务 00:30 没跑成功，意味着后面整条链路全部顺延，应触发最高级告警（电话）；ADS 单任务失败只影响一张报表（工单）。没有分层语义的告警系统只能"谁失败叫谁"，噪声大。
3. **存储治理**：治理的前提是知道各层预期增长率与生命周期：ODS 短 TTL + ORC zstd + 可降副本，DWD 长期保留 3 副本，ADS 小体量随查随删。分层是配额（quota）和生命周期策略的作用域。

## 7. ACID 事务表的演进

Hive 文件不可修改，所以"行级 update/delete"是**用目录约定模拟**出来的：

| 版本 | 能力 | 底层形态 |
|---|---|---|
| 0.13 | 完整行级 CRUD（仅 ORC） | base_x_y + delta_x_y 目录，读时合并，需 compactor |
| 0.14 | INSERT ... VALUES / UPDATE / DELETE 语法 + `transactional=true` 表属性 | SQL 即可直写事务表 |
| 0.13/0.14 | HCatalog Streaming API | 流式/微批入仓的接口基础；2.0 增补 Streaming Mutation API（可流式 UPDATE/DELETE），Hive 3 重写为新的 Hive Streaming API |
| 3.x | ACID v2：insert-only 事务表、managed 表默认事务化、向量化读 | insert-only（`'transactional_properties'='insert_only'`）只追加 delta、不需合并清理，面向小批流入；delta 合并读优化（CDP 生态的形态） |
| 4.x | 默认全面事务，external 表也可事务 | 行为开关有调整，**以官方文档为准** |

```
表目录/
├── base_0000002/                 ← 上次 major compaction 的基线
├── delta_0000003_0000003_0000/   ← 一次 INSERT 就是一个 delta 目录
├── delta_0000004_0000004_0000/
└── delete_delta_.../             ← 删除标记
读：base + 全部 delta 按事务 ID 合并视图；写：新事务追加新 delta
```

运维要点：**delta 堆积会拖垮读性能**（读时要合并的目录越来越多）。compaction 分两种：minor（delta 合并成更大的 delta）与 major（base + delta 重写成新 base）。它是 metastore 的后台任务（`hive.compactor.worker.threads` 等，默认值随版本，以官方文档为准），生产必须确认 worker 在跑、`SHOW COMPACTIONS` 有记录。

## 8. 运维要点

### 8.1 metastore 本质是一个 MySQL 库

表结构、分区、统计信息全在那个库里，而数据在 HDFS——**两者必须当成一个整体备份**。MySQL 侧直接套用 `11-middleware/mysql/02-backup-replication.md` 的方案：

```bash
# [任意节点] metastore 库的每日逻辑备份（完整恢复流程见 11-middleware/mysql/02）
mysqldump --single-transaction --routines --triggers -B hive \
  | gzip > /backup/hive_meta_$(date +%F).sql.gz
```

注意 mysqldump 只保证单库一致性，不保证"元数据与 HDFS 文件同一时刻一致"——恢复演练时要同时核对 HDFS 上的表目录。误删表后"MySQL 里有记录但 HDFS 文件没了"（或反之）是经典撕裂状态，恢复时以哪边为准要提前写进 runbook。

### 8.2 HS2 连接打满排障

症状：beeline 卡在 `Connecting to jdbc:hive2://...` 数分钟，已建立的查询不受影响或一起变慢。按顺序排查：

1. 确认连接数：`ss -tn state established '( sport = :10000 )' | wc -l`，对比 `hive.server2.thrift.max.worker.threads`（Thrift 工作线程上限）；
2. 打开 HS2 Web UI（`http://hs2-host:10002`）看 Sessions 页：是否有大量来自已下线机器/僵尸客户端的 session；idle 超时被禁用（`hive.server2.idle.session.timeout` 默认 7 天，设为 0/负值才禁用；发行版常改得更短或禁用，以 hive-default 为准）时，BI 工具连接泄漏会把 session 池占满；
3. 看 HS2 GC 日志：连接堆积常伴随 session 持有的内存无法释放，表现为老年代锯齿消失、Full GC 频繁；
4. 缓解：设置 idle session timeout + check interval、客户端侧连接池上限、用 ZK 服务发现横向扩 HS2；
5. 监控：HS2/metastore 暴露 JMX 给 Prometheus（做法同 `08-pca` 的 exporter 接入），对活跃 session 数、打开连接数、正在执行的查询数配告警，别等用户报障才发现。

### 8.3 小文件合并例行任务

来源：动态分区插入、Flink 分钟级流式入仓（见 `12-data-streaming/flink`）、Sqoop 按切分导入。危害在 NameNode：每个文件/目录/块对象都要吃 NN 堆内存，且作业规划阶段的 listStatus 变慢。

```bash
#!/usr/bin/env bash
# [任意节点] 每日小文件巡检 + 合并（crontab: 15 4 * * *）
set -u
DT=$(date -d "1 day ago" +%Y-%m-%d)
DIR="/opt/hive/data/warehouse/ods_event/dt=${DT}"   # 练习环境本地 FS；生产为 hdfs://nn/warehouse/...
THRESHOLD=10

FILES=$(find "${DIR}" -type f -name "*.orc" 2>/dev/null | wc -l)
echo "dt=${DT} orc files: ${FILES}"
if [ "${FILES}" -gt "${THRESHOLD}" ]; then
  beeline -u "jdbc:hive2://localhost:10000" \
    -e "ALTER TABLE ods.ods_event PARTITION (dt='${DT}') CONCATENATE;"
fi
```

要点：`CONCATENATE` 只适用于**非事务 ORC/RC 表**（不重写数据，只合并文件）；ACID 事务表的合并交给 compaction（第 7 节），例行脚本里改成 `ALTER TABLE ... COMPACT 'major'` 并盯 `SHOW COMPACTIONS`。写入时止血的参数是 `hive.merge.mapfiles`/`hive.merge.mapredfiles`（作业尾合并小文件，阈值 `hive.merge.smallfiles.avgsize`）。

### 8.4 Hive on Spark 与 Spark SQL 的当代关系

- **Hive on Spark**：还是 Hive 的编译器和语法（ACID、权限、UDF 都是 Hive 的），只是把执行引擎换成 Spark（`hive.execution.engine=spark`）。集成版本强耦合，社区使用面窄。
- **Spark SQL**：Spark 自己的 Catalyst 计划器跑作业，**只借 Hive 的 metastore 当表目录**（`spark.sql.catalogImplementation=hive`，详见 `04-spark.md`）。没有 Hive 运行时，HS2/metastore 里没有它的连接。

当代格局：越来越多平台里 Hive 只剩 metastore + 入仓规范，计算由 Spark/Flink/Doris 承担（`16-bigdata/05-olap-doris-starrocks.md` 的 ADS 场景）。对运维的启示：metastore 的 MySQL 是**全公司共享的单点资产**，其备份与高优等级应与 etcd 相当。

## 实战演练

环境：任意一台装好 Docker 的 Ubuntu VM（[任意节点]）。镜像 tag 以 Docker Hub 官方仓库为准，本文用 `apache/hive:4.0.0`。

### 步骤 1：体验 embedded metastore 的单连接限制

```bash
# [任意节点] 起一个内嵌 Derby metastore 的 HiveServer2
docker run -d --name hive-embedded -p 10000:10000 -p 10002:10002 apache/hive:4.0.0

# [任意节点] 用容器内 beeline 连接并验证
docker exec -it hive-embedded /opt/hive/bin/beeline -u jdbc:hive2://localhost:10000
```

```sql
-- [beeline] 预期返回三行：default / information_schema / sys
SHOW DATABASES;
```

保持这个 beeline 不断开，另开一个终端再 `docker exec -it hive-embedded /opt/hive/bin/beeline -u jdbc:hive2://localhost:10000` 执行一条 DDL——Derby 元数据库被第一个进程锁住，第二个会话操作会长时间阻塞或报错。这就是 embedded 形态只配做实验的原因。

### 步骤 2：改造成 remote（独立 metastore）模式

```bash
# [任意节点] 专用网络 + 独立 metastore（生产时 SERVICE_OPTS 再加 -Djavax.jdo.option.ConnectionURL=jdbc:mysql://... 指向 MySQL）
docker network create hive-net
docker rm -f hive-embedded
docker run -d --name hive-metastore --network hive-net -p 9083:9083 \
  -e SERVICE_NAME=metastore \
  -e SERVICE_OPTS="-Dhive.compactor.worker.threads=1" \
  apache/hive:4.0.0

# [任意节点] HS2 指向独立 metastore
docker run -d --name hive-hs2 --network hive-net -p 10000:10000 -p 10002:10002 \
  -e SERVICE_NAME=hiveserver2 \
  -e SERVICE_OPTS="-Dhive.metastore.uris=thrift://hive-metastore:9083" \
  apache/hive:4.0.0

# [任意节点] 验证 metastore 端口与 HS2 就绪（各 1 行 LISTEN）
ss -tln | grep -E ':(9083|10000)'
```

```bash
# [任意节点] 非交互执行 SQL 验证链路
docker exec hive-hs2 /opt/hive/bin/beeline -u jdbc:hive2://localhost:10000 -e "SHOW DATABASES;"
```

### 步骤 3：ORC 分区表、分区裁剪与动态分区

```sql
-- [beeline：jdbc:hive2://localhost:10000]
CREATE TABLE ods_order (
  order_id BIGINT,
  user_id  BIGINT,
  amount   DOUBLE
) PARTITIONED BY (dt STRING) STORED AS ORC;

INSERT INTO ods_order PARTITION (dt='2026-08-29') VALUES (1,100,29.9),(2,101,9.9);
INSERT INTO ods_order PARTITION (dt='2026-08-28') VALUES (3,102,59.0);

-- 动态分区：默认 strict 要求至少一个静态分区列，先放开
SET hive.exec.dynamic.partition.mode=nonstrict;
FROM (
  SELECT 4 AS order_id, 103 AS user_id, 19.9 AS amount, '2026-08-27' AS dt
  UNION ALL
  SELECT 5, 104, 39.0, '2026-08-26'
) t
INSERT INTO ods_order PARTITION (dt)
SELECT order_id, user_id, amount, dt;

SHOW PARTITIONS ods_order;

-- 分区裁剪：对比两条 EXPLAIN 里 Table Scan 的 Statistics: Num rows
EXPLAIN SELECT count(*) FROM ods_order WHERE dt='2026-08-29';
EXPLAIN SELECT count(*) FROM ods_order;
```

预期：`SHOW PARTITIONS` 列出 4 个分区；带 dt 过滤的 EXPLAIN 里 Num rows 只统计命中分区（远小于全表那条）。

```bash
# [任意节点] 看分区目录与 ACID delta 目录（真实路径以 SHOW CREATE TABLE 的 LOCATION 为准）
docker exec hive-hs2 find /opt/hive/data/warehouse/ods_order -maxdepth 2 | sort
```

预期看到 `dt=2026-08-26`...`dt=2026-08-29` 目录，每个目录下是 `delta_000000N_000000N_0000/` 子目录——第 7 节的物理形态。

### 步骤 4：ACID compaction 例行操作

```sql
-- [beeline] 再插入两次制造 delta，然后触发合并
INSERT INTO ods_order PARTITION (dt='2026-08-29') VALUES (6,105,10.0);
INSERT INTO ods_order PARTITION (dt='2026-08-29') VALUES (7,106,20.0);

ALTER TABLE ods_order PARTITION (dt='2026-08-29') COMPACT 'minor';
SHOW COMPACTIONS;
-- 稍等片刻再查，State 从 working 变为 succeeded / ready to clean
```

验证：`docker exec hive-hs2 find /opt/hive/data/warehouse/ods_order/dt=2026-08-29 -maxdepth 1` 中多个 delta 目录被合并成更少的大 delta；查询结果不变（`SELECT count(*) FROM ods_order WHERE dt='2026-08-29'` 应为 5）。浏览器打开 `http://<VM-IP>:10002` 看 HS2 Web UI 的 session 与查询统计。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| beeline 连 HS2 长时间无响应 | Thrift 工作线程/僵尸 session 打满 | 第 8.2 节排障流程；设 idle timeout，扩 HS2 |
| 首次起 metastore 报 schema 版本不匹配 | 元数据库未初始化或版本不配 | `schematool -dbType mysql -initSchema`（升级用 `-upgradeSchema`），版本要求以官方文档为准 |
| 动态分区插入报 Dynamic partition strict mode | 默认 strict 要求至少一个静态分区列 | 临时 `SET hive.exec.dynamic.partition.mode=nonstrict;`，长期在入仓脚本固定保留一级静态分区 |
| ORC 表 `LOAD DATA` 文本文件后查询乱码/失败 | LOAD 只搬文件不转换格式 | 文本入仓先建 TextFile 外表，再 `INSERT INTO ... SELECT` 转成 ORC |
| 事务表被非 ACID 会话/引擎写入报错 | ACID 需要 DbTxnManager 与合法事务 | 引擎侧保持 ACID 语义；跨引擎写入走外表或 Iceberg 类表格式 |
| 明明带 dt 过滤却全表扫 | 过滤列写成了别名/函数包裹（如 `where dt=to_date(x)`） | 分区列上的谓词必须能被编译期常量折叠，`EXPLAIN` 看 Num rows 验证 |
| 分区数暴涨、NameNode 内存告警 | 分钟级分区 + 流式小批写入 | 提升分区粒度到天/小时；例行合并（第 8.3 节）；流式改写 Iceberg |

## 自测

<details><summary>1. 为什么 local 模式（metastore 与 HS2 同 JVM、后端 MySQL）在生产几乎绝迹，尽管它比 remote 少一个进程？</summary>

三个原因：① 故障域不隔离——HS2 被 OOM/重启，metastore 服务跟着消失，所有依赖元数据的引擎（含正在提交的 Spark 作业）同时受影响；② 连接数不收敛——每个 HS2 实例独立维护 JDBC 连接，HS2 横向扩容时 MySQL 连接线性增长，最终打满 MySQL；③ 无法独立扩容/升级 metastore。remote 模式多花一个进程换来了"元数据面"与"查询接入面"解耦，这和把 etcd 从 apiserver 进程里拆出来是同一类架构决策。
</details>

<details><summary>2. 同一条 `SELECT city, sum(amount) FROM t WHERE dt='2026-08-29' AND amount>100 GROUP BY city`，TextFile 和 ORC 的物理执行差在哪一步？差距是 SQL 引擎造成的吗？</summary>

差距主要不在引擎而在文件读取层。ORC reader 先读 footer 统计：dt 靠分区裁剪跳过目录，amount>100 靠 row group/stripe 的 min-max（可加 bloom filter）整块跳过，且只反序列化 city、amount 两列。TextFile 必须把命中分区的所有行完整读入并解析全部字段。引擎完全相同的情况下，IO 量与反序列化 CPU 差一个数量级很常见。
</details>

<details><summary>3. 分桶能让 join 不 shuffle，那把热点大表按 join key 分 64 桶，能解决"某单个 key 占 40% 数据"的倾斜吗？</summary>

不能。分桶的拆分函数是 hash(key) mod N，同一个 key 的所有行必然落到同一个桶文件——单个热点 key 的数据仍然整体在一个 task 里。分桶解决的是"key 很多但分布不均"的长尾，让文件大小均匀、并支持 bucket map join 省掉 shuffle；单 key 倾斜必须打散 key 本身（加盐、null 值单独处理），见 04-spark.md 第 5 节。
</details>

<details><summary>4. ODS 层任务失败为什么要配最高级告警，而 ADS 层常常只开工单？</summary>

依赖传播范围不同：ODS 是全链路的数据源头，它晚到或失败意味着 DWD/DWS/ADS 全部顺延，报表截止时间（SLA）整体风险，且重跑要回源（重拉 binlog/日志，代价最大、窗口最长）；ADS 失败影响面通常只有一张报表/一个 API，且数据仍在下层，重跑是廉价的本地重算。告警分级本质上是对"影响面 × 恢复成本"排序。
</details>

<details><summary>5. 恢复 metastore 的 MySQL 备份后，业务一定正常吗？列出至少两类不一致。</summary>

不一定，元数据与 HDFS 文件可能撕裂：① MySQL 备份时间点之后新建的表/分区，MySQL 里没有记录但 HDFS 目录存在（孤儿数据）；② 备份之后 drop 掉的表，恢复后 MySQL 又"复活"了表定义，但 HDFS 文件若已被清掉则查询直接报错；③ ACID 表的事务 ID 与 delta 目录状态不一致，可能需要 `MSCK REPAIR` 与 compaction 清理。所以 runbook 必须写清恢复后的一致性核对步骤（SHOW TABLES 抽查 + 关键分区 count 比对），并明确"以哪边为准"。
</details>

## 延伸阅读

- Hive 官方 wiki（语言手册/配置总入口）：https://cwiki.apache.org/confluence/display/Hive/Home
- Hive Transactions（ACID 与 compaction 设计）：https://cwiki.apache.org/confluence/display/Hive/Hive+Transactions
- ORC 官方文档（文件结构、索引、压缩）：https://orc.apache.org/docs/index.html
- Parquet 格式文档：https://parquet.apache.org/docs/
- Apache Tez（DAG 执行引擎）：https://tez.apache.org/
- apache/hive 官方 Docker 镜像：https://hub.docker.com/r/apache/hive
