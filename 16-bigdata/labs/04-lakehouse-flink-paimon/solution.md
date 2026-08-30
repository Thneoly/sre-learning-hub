# Lab 04 · 解答与讲解

> 运行环境：Ubuntu 24.04 VM（`user@172.30.30.50`，docker-ce 含 compose 插件，内存 10G，磁盘余约 25G）。命令除特别标注外均在 `[任意节点]`（VM）执行。版本事实（2026-08-30 实查）：Docker Hub `apache/flink:1.19` 存在；Maven Central 上 `org.apache.paimon:paimon-flink-1.19` 已发布 0.8.0 ~ 2.0.0 全系列，`<latest>` 为 **2.0.0**，jar 约 55MB——**两者都以实查为准**（命令见第 2 步），本文不写死小版本号。另两个实测硬事实：该镜像跑 paimon 还需补一个 Hadoop shaded 包（第 2.5 步），且容器内 Flink 进程以 uid 9999 运行、sql-client 必须用 `-u flink` 调用（第 2.5 步拼图二）。

本 lab 的知识坐标：00 章 §2 的三巨头速览表说 Paimon 是"Flink 社区出品、流式湖存储"；07 章把这棵元数据树（snapshot → manifest → data file）画在纸上；05 章 §7 是下游视角（Doris/StarRocks 建个 catalog 直查湖表）。本 lab 补上上游视角和磁盘真相：**Flink 写进去的每一行，最终长成什么文件**。

## 第 1 步：compose 起 Flink 1.19 session 集群

```bash
# [任意节点]
mkdir -p ~/paimon-lab/warehouse && cd ~/paimon-lab

cat > docker-compose.yml <<'EOF'
services:
  jobmanager:
    image: apache/flink:1.19
    container_name: flink-jm
    hostname: jobmanager
    ports:
      - "8081:8081"          # JobManager Web UI（看作业与 checkpoint）
    mem_limit: 2g
    volumes:
      - ./warehouse:/opt/flink/warehouse   # 两容器共享同一份湖仓，见下方讲解
    command: jobmanager
    environment:
      - |
        FLINK_PROPERTIES=
        jobmanager.rpc.address: jobmanager
        jobmanager.memory.process.size: 1536m
        execution.checkpointing.interval: 5s
        state.checkpoints.dir: file:///tmp/flink-checkpoints
        parallelism.default: 2

  taskmanager:
    image: apache/flink:1.19
    container_name: flink-tm
    hostname: taskmanager
    depends_on:
      - jobmanager
    mem_limit: 2g
    volumes:
      - ./warehouse:/opt/flink/warehouse
    command: taskmanager
    environment:
      - |
        FLINK_PROPERTIES=
        jobmanager.rpc.address: jobmanager
        taskmanager.memory.process.size: 1728m
        taskmanager.numberOfTaskSlots: 4
        execution.checkpointing.interval: 5s
        state.checkpoints.dir: file:///tmp/flink-checkpoints
        parallelism.default: 2
EOF

docker compose up -d
docker compose ps
# 预期: flink-jm Up、flink-tm Up（TM 注册到 JM 约需 20~30s）
```

逐字段讲 SRE 视角的"为什么"：

- **`FLINK_PROPERTIES` 多行环境变量**：官方 flink-docker 镜像的入口脚本会把这些行追加进 `flink-conf.yaml`，等价于改配置文件重启——这是 session 集群级配置的标准注入方式，比 `docker cp` 进容器改文件可重现；
- **`execution.checkpointing.interval: 5s`（本 lab 的命门）**：Paimon sink 的提交动作挂在 checkpoint 上——数据先进 LSM 内存与临时文件，checkpoint 成功后才写 manifest、生成 snapshot，数据对查询可见。不开 checkpoint，写一万行也看不到 snapshot。这与 05 章 §5 的 sink 两阶段提交是同一条原则（`notifyCheckpointComplete` 之后才 commit），也是日后排障的映射：**湖表 snapshot 停止增长 = 上游作业 checkpoint 出问题**（12-data-streaming/flink 的 checkpoint 排障直接搬来用）；
- **`./warehouse` 以相同路径挂进两个容器**：Paimon 的 filesystem catalog 把表结构、snapshot、manifest 全放在 warehouse 路径下。sql-client 在 JM 上读 catalog 元数据，sink 算子在 TM 上写数据文件——两边的 `file:///opt/flink/warehouse` 若不是同一份磁盘，就会出现"表建了却查不到、snapshot 永不出现"的分裂。lab 用 bind mount，生产对应 HDFS/S3/OSS，共享与路径一致是天然成立的；
- **内存**：`process.size`（JVM 堆 + metaspace + 网络栈等总和）压在 `mem_limit` 之下，避免容器 OOMKilled；VM 共 10G，两个 2G 容器加页缓存余量充足；
- **8081 映射**：浏览器开 `http://172.30.30.50:8081` 能看到作业与 checkpoint 统计，等会儿验证写入要用。

## 第 2 步：下载 paimon-flink-1.19 并挂进集群

artifact 名里的 `flink-1.19` 必须与集群版本严格配对——挂错版本会在作业提交期报 `NoSuchMethodError`/`ClassNotFoundException` 类错误。

```bash
# [任意节点] 实查最新版本（这是权威入口，别信教程里写死的版本号）
curl -s https://repo1.maven.org/maven2/org/apache/paimon/paimon-flink-1.19/maven-metadata.xml \
  | grep -oE '<latest>[^<]+' | cut -d'>' -f2
# 2026-08-30 实查输出: 2.0.0（该 artifact 已发布 0.8.0~2.0.0；以实查为准，
# 若最新 major 与集群行为不匹配，退回最新 1.x，如 1.4.2）

cd ~/paimon-lab
PAIMON_VER=$(curl -s https://repo1.maven.org/maven2/org/apache/paimon/paimon-flink-1.19/maven-metadata.xml \
  | grep -oE '<latest>[^<]+' | cut -d'>' -f2)
curl -fLO "https://repo1.maven.org/maven2/org/apache/paimon/paimon-flink-1.19/${PAIMON_VER}/paimon-flink-1.19-${PAIMON_VER}.jar"
ls -lh paimon-flink-1.19-*.jar
# 预期: 约 55MB 的 bundle jar（含 paimon 核心 + flink connector 的 shaded 依赖）
# 直连超时就走 VM 已配的代理（与 docker.io 拉镜像同一条链路）：
#   export http_proxy=... https_proxy=... 后重试 curl

# 挂进【两个】容器（sql-client 在 JM 解析 'paimon'，sink 在 TM 执行），再重启加载
docker cp paimon-flink-1.19-${PAIMON_VER}.jar flink-jm:/opt/flink/lib/
docker cp paimon-flink-1.19-${PAIMON_VER}.jar flink-tm:/opt/flink/lib/
docker restart flink-jm flink-tm
sleep 30
docker exec flink-tm ls /opt/flink/lib | grep paimon
# 预期: paimon-flink-1.19-<版本>.jar
```

### 第 2.5 步：Hadoop 类 + 目录属主（2026-08-30 实测补的两块拼图，缺一不可）

**拼图一：paimon 需要 Hadoop 类。** 只装 paimon bundle 时，`CREATE CATALOG`/`INSERT` 会在
1.x 报 `ClassNotFoundException: org.apache.hadoop.conf.Configuration`（`CatalogContext`
直接引用该类），在 2.0.0 则拖到 INSERT 提交期才报同一个 CNF。apache/flink 镜像不带
Hadoop，补一个自带全部依赖的 shaded 包即可（Flink 官方为 Paimon/HDFS 场景推荐的老牌选择）：

```bash
# [任意节点] 约 42MB
cd ~/paimon-lab
curl -fLO "https://repo1.maven.org/maven2/org/apache/flink/flink-shaded-hadoop-2-uber/2.8.3-10.0/flink-shaded-hadoop-2-uber-2.8.3-10.0.jar"
docker cp flink-shaded-hadoop-2-uber-2.8.3-10.0.jar flink-jm:/opt/flink/lib/
docker cp flink-shaded-hadoop-2-uber-2.8.3-10.0.jar flink-tm:/opt/flink/lib/
docker restart flink-jm flink-tm && sleep 30
```

副作用要有数：这个 uber 包自带一份老 `commons-cli`，会让 `/opt/flink/bin/flink` CLI
（`flink list` 等）报 `NoSuchMethodError`。看作业状态改用 REST：宿主机
`curl -s http://localhost:8081/jobs/overview`，或浏览器开 8081 Web UI。

**拼图二：文件属主。** 两件事必须同时做对，否则 TM 写数据时报
`IOException: Mkdirs failed to create .../bucket-N`（很难一眼看出是权限）：

1. 宿主机 `./warehouse` 目录要让容器内运行 Flink 的 `flink` 用户（uid 9999）可写——
   用户家目录下默认 775（组外只读），先 `chmod 777 ~/paimon-lab/warehouse`；
2. 所有 sql-client 调用加 `-u flink`。`docker exec` 默认以 **root** 进容器，而镜像
   entrypoint 把 JM/TM 进程降权成了 uid 9999：root 建出来的 `sre_lab.db/`、
   `host_metrics/` 目录是 root:755，TM（9999）在里面 `mkdir bucket-*` 直接失败。
   sql-client 以 `-u flink` 跑，建表目录就是 flink 属主，TM 才写得进去。

另外记住：**容器在跑时不要 `rm -rf` 宿主机的 warehouse 目录**——bind mount 还指着旧
inode，容器里会变成"目录在、写入全 ENOENT"的诡异状态。要清空数据请
`docker compose down` 后再删再 `up`（lib 里的 jar 也要重装）。

```bash
chmod 777 ~/paimon-lab/warehouse          # 拼图二的第 1 件事
# 之后所有 sql-client 都用：docker exec -u flink flink-jm /opt/flink/bin/sql-client.sh ...
```

烟测：验证 bundle 真的被集群识别（能找到 `paimon` 这个 catalog 工厂）。

```bash
# [任意节点]
cat > smoke.sql <<'EOF'
CREATE CATALOG paimon WITH (
  'type' = 'paimon',
  'warehouse' = 'file:///opt/flink/warehouse'
);
SHOW CATALOGS;
EOF
docker cp smoke.sql flink-jm:/tmp/smoke.sql
docker exec -u flink flink-jm /opt/flink/bin/sql-client.sh -f /tmp/smoke.sql
# 预期输出含两行: default_catalog / paimon
# 若报 "Could not find any factory for identifier 'paimon'"：jar 没进 lib 或容器没重启
```

## 第 3 步：datagen → Paimon 主键表，持续写 10000 行

造数讲究**确定性**（判分要求 `COUNT(*)` 精确等于 40）：`seq` 是 sequence 列，host 与 metric 都是 `seq` 的纯函数，任何环境重跑结果一致。

```bash
# [任意节点]
cat > init.sql <<'EOF'
-- 源表：有界 datagen，恰好 10000 行；host/metric 是 seq 的确定性函数
--   seq/500（整数除法）=> host00..host19 各 500 行；seq 奇偶 => cpu/mem 交替
--   => 主键 (host, metric) 共 20*2 = 40 个，每个被写 250 次
--   host 的双层 CAST：无论 `/` 按整数还是浮点语义求值，结果都收敛到 0..19
-- 计算列语法是「列名 AS 表达式」——AS 前面不能再写类型，类型由表达式推断
--   （写 `host STRING AS ...` 会在解析期报 ParseException: Encountered "AS"）
CREATE TABLE default_catalog.default_database.src_metrics (
  seq    BIGINT,
  val    DOUBLE,
  host   AS CONCAT('host', LPAD(CAST(CAST(seq / 500 AS BIGINT) AS STRING), 2, '0')),
  metric AS IF(MOD(seq, 2) = 0, 'cpu', 'mem')
) WITH (
  'connector' = 'datagen',
  'number-of-rows' = '10000',
  'rows-per-second' = '500',
  'fields.seq.kind' = 'sequence',
  'fields.seq.start' = '0',
  'fields.seq.end' = '9999',
  'fields.val.kind' = 'random',
  'fields.val.min' = '0.0',
  'fields.val.max' = '1.0'
);

-- 湖表：filesystem catalog + 主键表（每次 sql-client 会话都要重新 CREATE CATALOG，
-- catalog 是会话对象，数据与表结构在 warehouse 目录里持久）
CREATE CATALOG paimon WITH (
  'type' = 'paimon',
  'warehouse' = 'file:///opt/flink/warehouse'
);

CREATE DATABASE IF NOT EXISTS paimon.sre_lab;

CREATE TABLE paimon.sre_lab.host_metrics (
  host       STRING,
  metric     STRING,
  val        DOUBLE,
  updated_at TIMESTAMP(3),
  PRIMARY KEY (host, metric) NOT ENFORCED
) WITH (
  'file.format' = 'parquet',   -- 默认值随版本可能是 orc，显式声明让 bucket 下文件名可预期
  'bucket' = '2'               -- 按主键 hash 分两个桶：bucket-0/ 与 bucket-1/
);

-- 持续写：作业提交进 session 集群，约 20s 跑完（500 行/秒 × 10000 行）
INSERT INTO paimon.sre_lab.host_metrics
SELECT host, metric, val, LOCALTIMESTAMP
FROM default_catalog.default_database.src_metrics;
EOF

docker cp init.sql flink-jm:/tmp/init.sql
docker exec -u flink flink-jm /opt/flink/bin/sql-client.sh -f /tmp/init.sql
# 预期: 日志出现 "SQL update statement has been successfully submitted to the cluster (JobID: ...)"
```

等写作业跑完并提交 snapshot（checkpoint 每 5s 一次）：

```bash
# [任意节点] 轮询 snapshot 目录，出现 snapshot-N 即说明首个 checkpoint 已提交
# （hadoop uber 包会弄坏 flink CLI，看作业状态用 REST：curl -s http://localhost:8081/jobs/overview）
for i in $(seq 1 24); do
  n=$(docker exec flink-tm sh -c \
    "ls /opt/flink/warehouse/sre_lab.db/host_metrics/snapshot 2>/dev/null | grep -c '^snapshot-[0-9]*$'")
  if [ "${n:-0}" -ge 1 ]; then echo "snapshot committed: ${n} (after ${i}x5s)"; break; fi
  sleep 5
done
# 预期约 20~30s 后输出 snapshot committed: 1..5（作业 20s + checkpoint 5s 间隔，
# 数量取决于作业时长与间隔，每次 checkpoint 提交一个 snapshot——这正是提交机制的直接证据）
```

Web UI 对照：`http://172.30.30.50:8081` → Running/Finished Jobs → 作业页 Checkpoints 标签，checkpoint 次数与 snapshot 数一一对应。

## 第 4 步：停写后批查询验证（40 行）

```bash
# [任意节点]
cat > verify.sql <<'EOF'
CREATE CATALOG paimon WITH (
  'type' = 'paimon',
  'warehouse' = 'file:///opt/flink/warehouse'
);
SET 'execution.runtime-mode' = 'batch';   -- 不设这句 SELECT 会变连续查询、永不返回
SET 'sql-client.execution.result-mode' = 'TABLEAU';   -- -f 非交互模式只接受 TABLEAU，不设直接报错

SELECT COUNT(*) FROM paimon.sre_lab.host_metrics;

SELECT host, metric, val FROM paimon.sre_lab.host_metrics
WHERE host = 'host07' ORDER BY metric;
EOF

docker cp verify.sql flink-jm:/tmp/verify.sql
docker exec -u flink flink-jm /opt/flink/bin/sql-client.sh -f /tmp/verify.sql
```

预期输出（TABLEAU 模式，批量结果没有 +I 的 op 列）：

```
SELECT COUNT(*)+--------+
| EXPR$0 |
+--------+
|     40 |                <- 10000 行按 (host, metric) 去重后剩 40
+--------+
1 row in set

+--------+--------+---------------------+
|   host | metric |                 val |
+--------+--------+---------------------+   <- host07 两行（cpu/mem 各一）
| host07 |    cpu | 0.10156948684428513 |   <- val 是 datagen 最后一次写入的随机值
| host07 |    mem |  0.4307832759697914 |
+--------+--------+---------------------+
2 rows in set
```

**10000 → 40 就是主键表的去重语义**：同一个主键写了 250 次，读出来只有一行、值是最后一次写入——Paimon 默认的 merge engine 是 deduplicate（同主键后写覆盖先写），这与 05 章 Doris Unique 模型的 MoR 读路径是同一个思想：写时不动旧文件，读时按主键合并（LSM merge）。

## 第 5 步（本 lab 的灵魂）：进 TM 看 warehouse 目录树

```bash
# [任意节点]
docker exec flink-tm ls -R /opt/flink/warehouse/sre_lab.db/host_metrics/
```

预期输出（文件名含随机 UUID，目录形态在 0.x 与 1.x 间略有差异——0.x 的表结构文件 `schema-0` 在根下，1.x 起收进 `schema/` 目录；以实际版本输出为准）：

```
/opt/flink/warehouse/sre_lab.db/host_metrics/:
bucket-0  bucket-1  manifest  schema  snapshot

/opt/flink/warehouse/sre_lab.db/host_metrics/bucket-0:
data-<uuid>-0.parquet      <- LSM 数据文件（bucket-1 下同理）

/opt/flink/warehouse/sre_lab.db/host_metrics/manifest:
manifest-<uuid>-0          <- 清单：列出本批提交新增/删除了哪些数据文件
manifest-list-<uuid>-0     <- 清单清单：一次提交引用的全部 manifest

/opt/flink/warehouse/sre_lab.db/host_metrics/schema:
schema-0                   <- 表结构（分区/列/主键/表选项），schema 演进就靠它版本化

/opt/flink/warehouse/sre_lab.db/host_metrics/snapshot:
EARLIEST  LATEST  snapshot-1  snapshot-2 ...   <- 每次提交一个；LATEST/EARLIEST 是指针
```

再 `cat` 一个 snapshot，看一次提交的"账本"：

```bash
# [任意节点] cat 最新的 snapshot（LATEST 文件里只存着编号，真正内容在 snapshot-N）
docker exec flink-tm sh -c \
  'cat /opt/flink/warehouse/sre_lab.db/host_metrics/snapshot/LATEST; echo; \
   ls /opt/flink/warehouse/sre_lab.db/host_metrics/snapshot/ | grep ^snapshot- | sort -V | tail -1'
docker exec flink-tm sh -c \
  'cat "$(ls -1 /opt/flink/warehouse/sre_lab.db/host_metrics/snapshot/snapshot-* | sort -V | tail -1)"'
```

预期输出（2.0.0 实测为 pretty-printed JSON；字段集随版本微调，语义以官方 Snapshot 规范文档为准）：

```json
{
  "version" : 3,
  "uuid" : "9bb5c1dd-2d47-4ec1-8bfe-fea820416f5f",
  "id" : 6,
  "schemaId" : 0,
  "baseManifestList" : "manifest-list-d621ccee-...-10",
  "baseManifestListSize" : 1136,
  "deltaManifestList" : "manifest-list-d621ccee-...-11",
  "deltaManifestListSize" : 1113,
  "commitUser" : "b50a9b7f-6748-49ad-a12e-a0c47c1ebea2",
  "commitIdentifier" : 9223372036854775807,
  "commitKind" : "COMPACT",
  "timeMillis" : 1788084647978,
  "totalRecordCount" : 40,
  "deltaRecordCount" : 0,
  "watermark" : -9223372036854775808,
  "nextRowId" : 0
}
```

字段名以官方 Snapshot 规范为准：记录数一族叫 `totalRecordCount` / `deltaRecordCount` / `changelogRecordCount`（1.x/2.x 均如此），不存在 `totalRecords` 这个拼写——网上旧教程常写错。

这棵树与 07 章讲的元数据树逐层对上，每层各管一件事：

```
读一张主键表的完整寻址链（自上而下）：
  catalog 元数据(schemas) ─► 指向当前 snapshot
    snapshot-N            ─► 本次提交引用哪些 manifest（base=历史累积, delta=本次新增）
      manifest / manifest-list ─► 列出属于本提交的数据文件（新增/删除的 bucket 文件）
        bucket-N/data-*.parquet ─► 真正的数据行，读时按主键做 LSM merge
```

- **snapshot 是"一次提交"**：写作业每个 checkpoint 生成一个，`LATEST`/`EARLIEST` 两个小文件是快进快倒指针——time travel（读历史版本）就是拿旧 snapshot-N 当入口；
- **manifest 是"增量账本"**：不重写整个文件清单，每次提交只追加一份 manifest 记录"这批新增了哪些 data file"。这是表格式解决"对象存储上没有原子 rename/事务"的关键设计（对照 00 章讲的"给文件堆加上表语义"）；
- **bucket 里是 LSM 数据文件**：主键表不原地更新，新值写新文件，靠 merge engine 在读时（或 compaction 后）合并——所以第 4 步你才能看到 10000 行收敛成 40 行。

## 第 6 步：更新语义验证（同主键写新值）

```bash
# [任意节点]
cat > update.sql <<'EOF'
CREATE CATALOG paimon WITH (
  'type' = 'paimon',
  'warehouse' = 'file:///opt/flink/warehouse'
);
SET 'execution.runtime-mode' = 'batch';
SET 'sql-client.execution.result-mode' = 'TABLEAU';

-- 与既有行同主键 ('host07','cpu')：deduplicate 语义下这是 UPDATE
INSERT INTO paimon.sre_lab.host_metrics
VALUES ('host07', 'cpu', 999.0, TIMESTAMP '2026-08-30 12:00:00');

SELECT val FROM paimon.sre_lab.host_metrics WHERE host = 'host07' AND metric = 'cpu';
SELECT COUNT(*) FROM paimon.sre_lab.host_metrics;
EOF

docker cp update.sql flink-jm:/tmp/update.sql
docker exec -u flink flink-jm /opt/flink/bin/sql-client.sh -f /tmp/update.sql
# 预期: 第一条查询返回 999.0；COUNT(*) 仍是 40（UPDATE 不增行）
```

回到磁盘看这次更新落成了什么：

```bash
# [任意节点] 更新前后的 snapshot 数量与 bucket 文件对比
docker exec flink-tm sh -c \
  'ls /opt/flink/warehouse/sre_lab.db/host_metrics/snapshot/ | grep -c ^snapshot-'
docker exec flink-tm sh -c \
  'ls -l /opt/flink/warehouse/sre_lab.db/host_metrics/bucket-0/ /opt/flink/warehouse/sre_lab.db/host_metrics/bucket-1/'
# 预期: snapshot 数 +1（一条新的 snapshot-N）；某个 bucket 下多出一个新的 data-*.parquet
#       （只含那一行新值）+ manifest 下多出一份新 manifest——没有任何旧文件被改写
```

这就是 UPDATE 的物理真相：**湖表没有原地更新，只有追加**。新值进新文件、新文件进新 manifest、新 manifest 进新 snapshot；查询时 merge engine 拿最新版本的主键值。旧版本数据要等 compaction（Paimon 的专职合并作业/存储过程，如 `CALL sys.compact(...)`，语法以官方文档为准）才物理消失——这正是 00 章 §2 点名的运维四件事之首：**compaction 调度、小文件治理、snapshot 过期（`snapshot.num-retained.*` 一族参数，过期策略是 time travel 能力与目录膨胀之间的权衡）、catalog 备份**。

## 第 7 步（SIMULATED 路径）：jar 拉不动时

真环境不可用时产出三份交付物到本 lab 目录（`16-bigdata/labs/04-lakehouse-flink-paimon/`）：

1. `docker-compose.yml`：把第 1 步的 compose 原样落盘；
2. `lakehouse-pipeline.sql`：把第 3/4/6 步的 `init.sql` + `verify.sql` + `update.sql` 合成一个可直接对真环境执行的脚本；
3. `warehouse-structure.md`：第 5 步那棵目录树的逐项注释文档，外加两段推演——"一次 checkpoint 如何变成一个新 snapshot"、"更新一条主键在树上落成哪些新文件"。

判分脚本对产物做内容校验（catalog 定义、PRIMARY KEY、datagen、INSERT INTO、batch 查询、snapshot/manifest/bucket 说明），检测不到 Running 容器时自动进入此模式。

## 清理（跑完 check.sh 之后）

```bash
# [任意节点]
cd ~/paimon-lab
docker compose down                # 删两个容器与网络
rm -rf ~/paimon-lab/warehouse      # 湖表数据在宿主机 bind mount 里，down 不会删
docker rmi apache/flink:1.19       # 可选：磁盘紧张时删镜像（下次实验要重拉）
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| sql-client 报 `Could not find any factory for identifier 'paimon'` | bundle jar 没进 `/opt/flink/lib` 或装完没重启容器 | jar 装进 JM 与 TM 两个容器后 `docker restart flink-jm flink-tm` |
| 写作业跑完了，snapshot 目录始终为空 | 没开 `execution.checkpointing.interval`，Paimon 提交挂在 checkpoint 上 | FLINK_PROPERTIES 加 5s interval 重建容器（本 lab compose 已含） |
| SELECT 卡住永不返回 | 默认 streaming 模式把湖表查询当连续查询 | `SET 'execution.runtime-mode' = 'batch';` |
| JM 上建了表、查询却看不到数据 | warehouse 没共享挂载，JM/TM 各看各的 `file://` 路径 | 同一路径 bind mount 进两个容器（生产用 HDFS/S3 天然共享） |
| 作业提交即报 NoSuchMethodError / ClassNotFound | jar 的 flink 版本与集群不配对（如 paimon-flink-1.20 挂 1.19） | artifact 名与集群版本严格一致，版本以 Maven Central 实查为准 |
| snapshot 数只涨不降、目录越堆越大 | snapshot 默认保留策略 + 无 compaction | 按业务调 `snapshot.num-retained.min/max`、调度 compaction（参数以官方文档为准） |
| `ParseException: Encountered "AS"` | 计算列写成了 `host STRING AS expr` | 计算列是「列名 AS 表达式」，AS 前不写类型，类型由表达式推断 |
| `ClassNotFoundException: org.apache.hadoop.conf.Configuration` | paimon 引用 Hadoop 类，apache/flink 镜像不带 | 两容器 lib 各装一份 flink-shaded-hadoop-2-uber（第 2.5 步） |
| `-f` 跑 SELECT 报 "it only supports to use TABLEAU as value of sql-client.execution.result-mode" | 非交互模式仅接受 TABLEAU | SQL 文件里加 `SET 'sql-client.execution.result-mode' = 'TABLEAU';`（TABLEAU 批量输出没有 +I 前缀） |
| TM 日志刷 `IOException: Mkdirs failed to create .../bucket-N`（root 明明能建目录） | sql-client 用默认 root 建了 root:755 的 catalog 目录，TM 进程是 uid 9999 写不进；或宿主 warehouse 顶层 775 | sql-client 全部加 `-u flink`；`chmod 777 ~/paimon-lab/warehouse`（见第 2.5 步拼图二） |
| `flink list` 报 `NoSuchMethodError: commons-cli` | hadoop uber 包自带老版 commons-cli 冲突 | 看作业状态用 `curl -s http://localhost:8081/jobs/overview` 或 Web UI |
| 容器里 warehouse 目录"看得见写不进"（mkdir 报 No such file or directory） | 容器运行中 `rm -rf` 了宿主机 bind mount 源目录，挂载还指着旧 inode | `docker compose down` 后再删/重建 warehouse，`up` 后重装 lib 里的 jar |
| 换了 sql-client 会话后 catalog 不见了 | filesystem catalog 的 catalog 定义是会话对象 | 每个脚本开头重新 `CREATE CATALOG`（本 lab 各 .sql 均如此）；数据本身在 warehouse 里持久 |

## check.sh 通过结果（full 模式实测形态）

```
== 模式: full（检测到 flink-jm / flink-tm 均 Running，按真实集群判分） ==

PASS: 容器 flink-jm 处于 Running
PASS: 容器 flink-tm 处于 Running
PASS: TM 的 /opt/flink/lib 下存在 paimon-flink jar
PASS: warehouse 下存在表目录 /opt/flink/warehouse/sre_lab.db/host_metrics
PASS: snapshot/ 目录非空（含 snapshot-N 与 LATEST，共 8 项）
PASS: manifest/ 目录非空（21 个清单文件）
PASS: 批查询 COUNT(*) = 40（10000 行按主键 (host, metric) 去重生效）
PASS: 主键更新语义生效：('host07','cpu') 的 val 为 999（LSM 同主键新值覆盖旧值）
PASS: snapshot 文件内容含 totalRecordCount 等字段（表格式元数据可 cat 直接阅读）

SCORE: 9/9
```

## 延伸阅读

- Apache Paimon 官方文档（Flink 快速开始 / 主键表 / Snapshot 规范 / compaction）：https://paimon.apache.org/docs/master/
- Paimon 的 Maven Central 版本列表（实查入口）：https://repo1.maven.org/maven2/org/apache/paimon/paimon-flink-1.19/
- Apache Flink Docker 官方部署文档（session 集群与 FLINK_PROPERTIES）：https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/deployment/resource-providers/docker/
- Flink SQL Client（`-f` 脚本执行与 `execution.runtime-mode`）：https://nightlies.apache.org/flink/flink-docs-release-1.19/docs/dev/table/sqlclient/
- 下游视角：Doris 多目录 / 湖分析（对照 05 章 §7）：https://doris.apache.org/docs/lakehouse/multi-catalog/
