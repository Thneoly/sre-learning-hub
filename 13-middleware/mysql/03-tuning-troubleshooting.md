# 03 · MySQL 调优与排障手册

> 模块：中间件-MySQL ｜ 建议时长：3 小时 ｜ 关联认证：PCA-指标（本章监控节直接复用 PromQL 能力）；CKA-有状态应用运维

## 学习目标

- 能操作：开启慢查询日志并用 `EXPLAIN` 定位坏 SQL 的坏法（type / rows / Extra 三列）
- 能解释：最左前缀与覆盖索引的设计原则，能对给定查询给出索引方案
- 能解释：SRE 必调参数清单中每一项的取舍依据（双 1、buffer pool、连接数）
- 能排查：按手册表处置连接打满、磁盘满、主从延迟三类高频故障
- 能操作：在 K8s 上用 Operator 跑 MySQL，并用 mysqld_exporter 建立核心指标告警

## 1. 慢查询与 EXPLAIN

### 慢查询日志

一切 SQL 优化的入口。三个参数决定"什么算慢"：

```ini
# [任意节点] my.cnf 或 SET GLOBAL(动态生效)
slow_query_log = ON
long_query_time = 0.5        # 超过 0.5 秒记一条;排障期可临时降到 0.1
log_queries_not_using_indexes = ON   # 全表扫描的查询也记录(噪音大,按需开)
```

```bash
# [任意节点] 分析慢日志 top 榜
mysqldumpslow -s t -t 10 /var/lib/mysql/slow.log   # 按总耗时排序前 10
# -s c 按次数  -s r 按返回行数  -s t 按总时间(默认推荐)
```

### EXPLAIN 三列定生死

`EXPLAIN SELECT ...` 的输出十几列，SRE 排障重点盯三列，优先级从高到低：**type → Extra → rows**。

**type（访问方式，越好越靠上）**：

| type | 含义 | 判定 |
|---|---|---|
| system / const | 主键或唯一索引等值，最多一行 | 最优 |
| eq_ref | join 时按主键/唯一索引匹配，每次一行 | 优 |
| ref | 普通二级索引等值 | 良，多数业务查询的正常形态 |
| range | 索引范围扫描（BETWEEN、>、IN） | 可接受 |
| index | 扫整棵索引树（覆盖索引下的全扫） | 及格，免回表但仍是全扫 |
| ALL | 全表扫描 | 红灯：大表上必出慢查询 |

**Extra（关键动作提示）**：

| Extra | 含义 | 动作 |
|---|---|---|
| Using index | 覆盖索引，免回表 | 理想 |
| Using where | 服务层再过滤 | 配合 type 看，ALL+此值=纯全表扫 |
| Using filesort | 内存/磁盘排序，没走索引序 | 排序列加索引或改写 |
| Using temporary | 建临时表（GROUP BY/ DISTINCT 常见） | 聚合列建索引 |
| Using index condition | ICP，索引条件下推，好事 | 无需动作 |
| Using join buffer (Block Nested Loop) | join 无索引走缓冲暴扫 | join 列补索引 |

**rows（预估扫描行数）**：优化器基于统计信息的估算。`rows=1` 与 `rows=2000000` 的差距就是优化的全部空间。统计信息过期会导致误判，`ANALYZE TABLE t;` 重新采样。

```sql
-- [任意节点] 典型排查:一条慢 SQL 三步看
EXPLAIN SELECT * FROM orders WHERE user_id=42 AND status=2 ORDER BY created_at;
-- 坏结果示例:
-- type=ref, key=idx_user, rows=8900, Extra=Using where; Using filesort
-- 解读:索引只吃到 user_id,过滤 status 要回表逐行判断;排序没走索引

-- 方案:扩联合索引吃掉过滤+排序
ALTER TABLE orders ADD INDEX idx_u_s_c (user_id, status, created_at);
-- 复查:
-- type=ref, key=idx_u_s_c, rows=120, Extra=Using index condition
-- rows 从 8900 降到 120,filesort 消失
```

8.0.18+ 可用 `EXPLAIN ANALYZE` 看真实执行（含实际行数与耗时），比估算更可信。

## 2. 索引设计原则

### 最左前缀

联合索引 `(a, b, c)` 在逻辑上是先按 a 排序、a 相同按 b、b 相同按 c 的有序结构。因此：

```
索引 (a,b,c) 等价于建了 (a) (a,b) (a,b,c) 三套索引能力

 WHERE a=1 AND b=2 AND c=3   → 全吃          ✓
 WHERE a=1 AND b=2           → 吃 a,b        ✓
 WHERE b=2 AND c=3           → 一列都吃不上  ✗ (缺最左列 a)
 WHERE a=1 AND c=3           → 只吃 a        △ (c 靠索引下推缓解)
 WHERE a=1 AND b>2 AND c=3   → a,b 范围后 c 断 ✓/✗ (范围列之后失效)
 ORDER BY a, b               → 走索引序免排序 ✓
 ORDER BY b                  → 不走           ✗
```

设计顺序口诀：**等值列在前，范围列在后；排序列衔接等值列**。索引不是越多越好——每个索引拖慢写入、占用空间，且优化器选择成本上升。

### 覆盖索引

把 `SELECT` 需要的列全部纳入索引，消灭回表。高频的"列表页"查询收益最大：

```sql
-- [任意节点] 列表页只取 4 列,干脆建成一个覆盖索引
SELECT user_id, status, amount, created_at FROM orders
WHERE user_id = 42 ORDER BY created_at DESC LIMIT 20;

ALTER TABLE orders ADD INDEX idx_cover (user_id, created_at, status, amount);
-- EXPLAIN Extra: Using index(全覆盖,零回表)
-- 注意顺序:user_id 等值在前,created_at 排序次之,其余列纯搭车
```

其他铁律：列上套函数或隐式类型转换会让索引失效（`WHERE YEAR(created_at)=2025` 改成范围写法；字符串列与数字比较发生隐式转换直接 ALL）；前缀索引 `col(N)` 无法覆盖也无法用于 ORDER BY，只救等值查询的索引体积。

## 3. SRE 必调参数清单

新实例上线基线（假设 16GB 内存、SSD、8 核的专用实例）：

| 参数 | 推荐值 | 理由与风险 |
|---|---|---|
| `innodb_buffer_pool_size` | 内存的 50%~70%（如 10G） | 头号参数；过大挤占连接内存与 OS 页缓存 |
| `innodb_flush_log_at_trx_commit` | 1 | 每提交 fsync redo；=2 快但 os crash 丢 1 秒 |
| `sync_binlog` | 1 | 每提交 fsync binlog；与上者合称"双 1"，RPO=0 必需 |
| `innodb_redo_log_capacity` | 1G~8G（8.0.30+） | 过小写入高峰会被 checkpoint 卡住 |
| `innodb_io_capacity` / `_max` | SSD: 2000/4000 | 刷脏速率上限，机械盘 200/400 |
| `max_connections` | 500~2000 按连接池规划 | 打满报 1040；每连接内存独立分配 |
| `interactive_timeout` / `wait_timeout` | 600 | 空闲连接 10 分钟踢掉，防连接泄漏 |
| `max_execution_time` | 30000 | SELECT 超 30 秒自动杀，防慢查询拖死从库 |
| `binlog_format` | ROW | 复制安全基线 |
| `binlog_expire_logs_seconds` | 604800（7 天） | 比备份周期长，磁盘又不至于被 binlog 涨满 |
| `innodb_print_all_deadlocks` | ON | 死锁全记入 error log，排障刚需 |
| `slow_query_log` / `long_query_time` | ON / 0.5 | 见第 1 节 |

```sql
-- [任意节点] 动态确认当前生效值
SELECT @@innodb_buffer_pool_size/1024/1024/1024 AS bp_gb,
       @@innodb_flush_log_at_trx_commit, @@sync_binlog,
       @@max_connections, @@binlog_format;
```

参数不是越小越稳也不是越大越快：`sort_buffer_size` 之类 per-connection 内存盲目调大，连接数一高就是 OOM 元凶，保持默认即可。

## 4. 高频故障排障手册

### 连接打满

```sql
-- [任意节点] 第一步:看清谁占着
SHOW PROCESSLIST;    -- 或 information_schema.processlist 可 WHERE 过滤
SELECT state, COUNT(*) FROM information_schema.processlist
GROUP BY state ORDER BY 2 DESC;

-- 紧急腾位:杀掉 Sleep 最久的一批(先留证据再杀)
SELECT CONCAT('KILL ', id, ';') FROM information_schema.processlist
WHERE command='Sleep' AND time > 600;
```

| 症状 | 原因 | 解法 |
|---|---|---|
| 报 1040 Too many connections，进程列表大量 Sleep | 应用连接池泄漏/未复用 | 应用侧修池；临时 `SET GLOBAL max_connections=...` 救急；上 ProxySQL 中间层 |
| 大量 `Waiting for connection` / 认证慢 | DNS 反解析卡（`skip_name_resolve` 未开） | my.cnf 加 `skip_name_resolve`，授权改用 IP 段 |
| Threads_running 飙高、CPU 100% | 某条慢 SQL 全表扫被并发调用 | PROCESSLIST 抓 SQL → EXPLAIN → 加索引；必要时 `max_execution_time` 兜底 |
| 大量 `Waiting for table metadata lock` | DDL 被未提交事务/长查询阻塞，后续全排队 | `SELECT * FROM sys.schema_table_lock_waits` 找源头 kill；DDL 用 gh-ost/pt-osc 低峰执行 |

### 磁盘满

| 症状 | 原因 | 解法 |
|---|---|---|
| `No space left on device`，写入全停 | binlog 堆积 / 大事务 undo / 误留的备份与临时文件 | 见下方操作序 |
| error log 几十 GB | `log_error_verbosity` 高 + 反复重启循环 | logrotate 轮转 |
| `/tmp` 涨满 | 大结果集临时表落盘 | 调 `tmp_table_size`；改写 SQL 减临时表 |

```bash
# [任意节点] 磁盘满标准处置序(先救命再清理)
df -h                                          # 1. 确认哪块盘满
du -sh /var/lib/mysql/* | sort -h | tail -5    # 2. 找大头:binlog/undo/数据/临时

# 3. binlog 是首要嫌疑:确认备份已含最新位点后收老文件
mysql -e "SHOW BINARY LOGS;" | tail -3
mysql -e "PURGE BINARY LOGS BEFORE NOW() - INTERVAL 1 DAY;"

# 4. 千万不要 rm 物理文件!ibdata/ib_logfile/undo 删了实例即毁
# 5. 临时表文件(/var/lib/mysql/#sql*)归属运行中的会话,先 kill 会话再观察
```

### 主从延迟

| 症状 | 原因 | 解法 |
|---|---|---|
| 延迟平稳增长 | 单线程重放能力 < 主库写入 | `replica_parallel_workers` 提到 8~16；主库 `binlog_transaction_dependency_tracking=WRITESET` |
| 延迟阶梯跳变 | 大事务（批量 UPDATE/DELETE 千万行） | 拆成每批几千行；监控 `Seconds_Behind_Source` 跳变即对 binlog 时间点 |
| IO 线程 Yes 但 relay 不长 | 主库 dump 慢或网络窄 | 主库看 Binlog Dump 线程；网络测速；开 binlog 压缩 `binlog_compress` 评估 |
| SQL 线程 No，Last_SQL_Errno 非 0 | 从库数据不一致/无主键表 | GTID 跳过空事务；无主键表补主键；不一致严重直接重搭 |
| 延迟只在备份时段 | 备份 IO 抢占（尤其 mysqldump 大查询） | 备份挪专用延迟从库；XtraBackup 替代 mysqldump |

```sql
-- [任意节点] 延迟到"要不要摘流量"的判断
SHOW REPLICA STATUS\G
-- Seconds_Behind_Source > 60 且 Retrieved_Gtid_set 持续前进 → 重放慢,可摘读流量
-- Retrieved_Gtid_set 不前进 → 收日志就断了,查网络与主库 dump 线程
```

## 5. K8s 上跑 MySQL

单机 MySQL 换到 K8s，本质变化是：**本地盘换成了 PV，主从换成了 Operator 管理的 StatefulSet + 自动 failover**。核心组件是本地存储（local PV / OpenEBS）而非网络盘——MySQL 对 fsync 延迟极敏感，普通网络存储可能让"双 1"配置的延迟放大十倍。

选型两条路：

| 方案 | 形态 | 适用 |
|---|---|---|
| 自建 StatefulSet + Service | 手工管理，配置全在自己手里 | 学习/极端定制；failover 全手工 |
| Percona Distribution for MySQL Operator（PXC/PS） | Operator + CR，自动 provisioning/failover/备份 | 生产推荐，开源 |
| Oracle MySQL Operator (InnoDB Cluster) | 官方，MySQL Shell + Group Replication | 已购 Oracle 支持 |

```yaml
# [任意节点] Percona Operator 快速起步(以官方 Helm 仓库为准)
# helm repo add percona https://percona.github.io/percona-helm-charts/
# helm install mysql-operator percona/pxc-operator --namespace mysql-operator --create-namespace
---
apiVersion: pxc.percona.com/v1
kind: PerconaXtraDBCluster
metadata:
  name: pxc
  finalizers: []
spec:
  crVersion: 1.15.0
  secretsName: pxc-secrets
  pxc:
    size: 3
    image: percona/percona-xtradb-cluster:8.0
    resources:
      requests:
        memory: 2G
        cpu: 500m
      limits:
        memory: 3G
    volumeSpec:
      persistentVolumeClaim:
        resources:
          requests:
            storage: 20Gi
    affinity:
      antiAffinityTopologyKey: kubernetes.io/hostname   # 三副本强制分节点
  proxysql:
    enabled: true
    size: 2
  backup:
    image: percona/percona-xtradb-cluster-operator:1.15.0-backup
    scheduledBackups: []          # 生产必配 XtraBackup 定时任务到 S3
```

版本字段 `crVersion` 与镜像 tag 以官方发布为准（https://docs.percona.com/percona-operator-for-mysql/pxc/index.html）。运维要点：Pod 反亲和保证三副本不共节点；PodDisruptionBudget 保证滚动维护时 quorum 不丢；PVC 生命周期独立于 Pod，**删 StatefulSet 不删 PVC**——这也是恢复数据和误删数据的同一把双刃剑；副本数保持奇数（Group Replication quorum）。

## 6. mysqld_exporter 必看指标

```yaml
# [任意节点] 部署(容器或裸机均可)
# docker run -d -p 9104:9104 -e DATA_SOURCE_NAME="exporter:pass@tcp(127.0.0.1:3306)/" prom/mysqld-exporter
```

监控金字塔——从"有没有事"到"哪里的事"，逐层下钻：

| 优先级 | 指标（PromQL） | 看什么 |
|---|---|---|
| P0 存活 | `mysql_up` | !=1 一切免谈，直接告警 |
| P0 可用 | `mysql_global_status_threads_connected / mysql_global_variables_max_connections` | >0.8 预警连接打满 |
| P0 活跃 | `mysql_global_status_threads_running` | 突增 = 慢 SQL 或锁，配合 CPU 看 |
| P1 复制 | `mysql_slave_status_master_server_id` 存在且 `mysql_slave_status_slave_sql_running == 1` 与 `mysql_slave_status_slave_io_running == 1` | 线程挂了立即告警 |
| P1 延迟 | `mysql_slave_status_seconds_behind_master` | >60s 预警；值为无数据(NULL)也要告警（IO 断开时） |
| P1 慢查询速率 | `rate(mysql_global_status_slow_queries[5m])` | 突增对齐发布时间轴 |
| P2 缓存命中 | `rate(mysql_global_status_innodb_buffer_pool_reads[5m]) / rate(mysql_global_status_innodb_buffer_pool_read_requests[5m])` | 物理 IO 占比 >1% 考虑加内存 |
| P2 死锁 | `rate(mysql_global_status_innodb_deadlocks[5m])` | 持续 >0 查 `innodb_print_all_deadlocks` 日志 |
| P2 连接错误 | `rate(mysql_global_status_aborted_connects[5m])` | 突增查认证/网络（结合 CKS 审计） |

```promql
# [任意节点] 现成告警规则片段(PrometheusRule YAML 内容同构)
(
  mysql_global_status_threads_connected
  / mysql_global_variables_max_connections
) > 0.85
# for: 5m → 触发"连接使用率 85%"告警

mysql_slave_status_seconds_behind_master > 120
# for: 3m → 主从延迟 2 分钟告警(注意对 NULL 单独配 absent/对比告警)
```

排障闭环示意：`mysql_up` 掉 → 看 Pod/容器与 error log → `threads_running` 高 → PROCESSLIST 抓 SQL → EXPLAIN 定位 → 加索引/改参数 → 慢查询速率回落。指标不直接给答案，但给对的路标。

## 实战演练

在 docker 环境复现三类故障并处置（lab 环境可复用）。

```bash
# [Ubuntu VM] 压测制造慢查询与连接压力
docker exec -it mysql-learn mysql -uroot -proot123 -e "USE shop; \
  SELECT COUNT(*) FROM orders a JOIN orders b ON a.user_id=b.user_id;" &
```

```sql
-- [任意节点] 1.慢查询三步法
SET GLOBAL slow_query_log=ON; SET GLOBAL long_query_time=0.5;
-- 触发上面的 join 后:
EXPLAIN SELECT COUNT(*) FROM orders a JOIN orders b ON a.user_id=b.user_id\G
-- 预期看到 join buffer/大 rows → 解读 → 给 user_id 建索引后对比
```

```sql
-- [任意节点] 2.连接打满演练
SET GLOBAL max_connections=30;
-- 另开 35 个连接循环:
-- for i in $(seq 1 35); do docker exec -d mysql-learn \
--   mysql -uroot -proot123 -e "SELECT SLEEP(120);"; done
SHOW PROCESSLIST;
-- 观察到 1040 报错后,恢复 max_connections 并 kill Sleep 会话
SET GLOBAL max_connections=500;
```

```bash
# [Ubuntu VM] 3.mysqld_exporter 抓指标验证
docker run -d --name mysqld-exporter --net mysqlnet \
  -e DATA_SOURCE_NAME="root:root123@(mysql-m:3306)/" \
  -p 9104:9104 prom/mysqld-exporter:v0.15.1
curl -s localhost:9104/metrics | grep -E '^mysql_(up|global_status_threads_running)'
# mysql_up 1 即采集正常
```

验证方法：演练 1 中加索引前后 EXPLAIN 的 rows 数量级下降；演练 2 中 1040 报错复现与恢复；演练 3 中 `mysql_up 1` 与 threads 指标随压测波动。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| EXPLAIN 显示不错但还是慢 | 优化器估算与实际不符 / 锁等待 / IO 排队 | `EXPLAIN ANALYZE` 看真实耗时；看 `sys.session` 的状态列 |
| 加了索引不走 | 统计信息过期、隐式类型转换、列上用函数 | `ANALYZE TABLE`；改写 SQL；核对列类型 |
| K8s 上 MySQL 周期性慢 | PV 网络存储 fsync 延迟高 | local PV / 本地 SSD；或网络盘开高 IOPS |
| Operator failover 后应用连旧主 | 连接串直指 Pod IP | 一律走 ProxySQL/haproxy Service，禁止直连 Pod |
| exporter 起来但 mysql_up 0 | 账号权限/密码错、hostname 解析 | 账号需 PROCESS/REPLICATION CLIENT/SELECT；容器网络互通 |
| 调大 sort_buffer 后 OOM | per-connection 内存 × 高连接数 | 此类 per-thread 缓冲保持默认，靠索引消排序 |

## 自测

1. `EXPLAIN` 里 type=ref、rows=50、Extra 是 `Using filesort`，和 type=ALL、rows=800 万、Extra 为空，哪个更急？为什么？

<details><summary>答案</summary>

后者更急。ALL 是全表扫描，800 万行的物理读与 CPU 在并发下会直接拖垮实例（还会把 buffer pool 热页冲掉，殃及其他查询）；前者已走索引且扫描量小，filesort 只是对 50 行排序，代价可忽略。排障顺序永远是"先灭全表扫，再抠 filesort"。
</details>

2. 联合索引 `(a,b)` 下 `WHERE a>1 AND b=2` 为什么 b 用不上？怎么改？

<details><summary>答案</summary>

a 是范围条件，B+ 树定位到 a>1 后叶子上 a 是无序区间，b 在区间内无序，无法二分。改法：若 b 等值选择性高，建 `(b,a)` 让 b 等值在前、a 范围在后；或改写查询（如 a 拆成 IN 等值列表，让 b 继续生效，8.0 有 range 优化）。
</details>

3. "双 1" 配置下 K8s 网络盘部署，`sync_binlog=1` 但写入延迟忽高忽低，根因方向在哪？

<details><summary>答案</summary>

双 1 意味着每次提交都要 fsync binlog 与 redo，延迟由存储的 fsync 能力决定。网络 PV（NFS/云盘）的 fsync 延迟受网络与多租户影响抖动大。方向：换 local PV/本地 SSD，或存储层保证 IOPS 与延迟下限，或业务容忍后改 2/N（放弃 RPO=0）。
</details>

4. 主从延迟告警里为什么必须单独处理 NULL（无数据）的情况？

<details><summary>答案</summary>

`Seconds_Behind_Source` 在 IO 线程断开时为 NULL（8.0.22+）或无样本，PromQL 的大于比较对缺失样本直接不成立——延迟最严重的场景（复制断了）反而一条告警都不发。必须配 `absent()` 或 `mysql_slave_status_slave_io_running==0` 的独立规则，否则监控在最需要它时沉默。
</details>

5. 为什么 K8s 上删掉 MySQL 的 StatefulSet 后重新创建，数据"还在"甚至被误当 bug？

<details><summary>答案</summary>

StatefulSet 的 PVC 生命周期独立于控制器，默认删除策略（Retain，Operator 场景常见）不删 PVC。重建后同名 Pod 重新挂回原 PVC，旧数据全部回归。这既是"误删 StatefulSet 可恢复"的保险，也是"想重置数据却拿到旧库"的坑——彻底重置必须显式删除 PVC（以及配置里的备份与 binlog 语义）。
</details>

## 延伸阅读

- EXPLAIN 输出解读官方文档：https://dev.mysql.com/doc/refman/8.0/en/explain-output.html
- InnoDB 启动参数与系统变量：https://dev.mysql.com/doc/refman/8.0/en/innodb-parameters.html
- Percona Operator for MySQL：https://docs.percona.com/percona-operator-for-mysql/pxc/index.html
- mysqld_exporter 仓库：https://github.com/prometheus/mysqld_exporter
- MySQL sys schema（排障视图库）：https://dev.mysql.com/doc/refman/8.0/en/sys-schema.html
