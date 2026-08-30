# Lab 04 · Flink SQL 写 Paimon 湖表：把表格式元数据变成肉眼可见

> 难度：★★★ ｜ 考点：16-bigdata/07-lakehouse（snapshot/manifest 元数据树 / 主键表 upsert / Flink 入湖链路） ｜ 前置：16-bigdata/00 §2 三巨头速览表、05 §7 湖查询；03-docker 的容器资源限制（labs/06-resource-limits，compose 里写成 `mem_limit`）；12-data-streaming/flink 的 checkpoint（本 lab 的提交语义直接依赖它） ｜ 预计 60~90 分钟

## 场景

你是数据平台组的 SRE，值班时收到需求：上游 Flink 作业要把主机指标写入湖表，替代"先落 HDFS 再补 Hive 表"的旧链路。00 章的三巨头速览表告诉你 Paimon 是"Flink 原生一体化"的那一个，05 章 §7 讲过下游 Doris/StarRocks 怎么直查湖表——但**表格式到底在磁盘上写了什么**，你还一次没亲眼看过。第 07 章画过那棵元数据树（snapshot → manifest → data file），本 lab 就是在 VM 上把它 `ls` 出来。

环境：Ubuntu VM（`candidate@172.30.30.50`，docker 可用，内存 10G、磁盘余 25G+；docker.io 走已配代理，Maven Central 直连或代理）。要做的闭环：docker compose 起 Flink 1.19 session 集群 → 挂载 Paimon 的 Flink bundle jar → sql-client 里 datagen 源表持续写 Paimon 主键表 → 停写后批查询验证去重 → 进 taskmanager 容器看 warehouse 目录 → 同主键写新值验证 UPDATE 语义。

```
Flink session 集群 (docker compose, 各限 2G)          file:///opt/flink/warehouse（两容器共享挂载）
┌─────────────────────────────┐
│ flink-jm (JobManager+sql客户端) │  CREATE CATALOG / INSERT / SELECT 在这里提交
│ flink-tm (TaskManager,sink)   │──数据文件+manifest 直接写共享卷；每次 checkpoint 提交一个 snapshot
└─────────────────────────────┘
  datagen(有界,恰好 10000 行,20 host × 2 metric)
        │ INSERT INTO（持续写，checkpoint 每 5s 提交）
        ▼
  warehouse/sre_lab.db/host_metrics/          ← 本 lab 的灵魂：这棵树要 ls 给自己看
  ├── snapshot/   LATEST / EARLIEST / snapshot-N   （快照 = 一次提交的账本）
  ├── manifest/   manifest-list-* → manifest-*      （清单 = 哪些数据文件属于本次提交）
  ├── schema/     表结构版本（0.x 版本在根下 schema-0，以实际版本为准）
  └── bucket-0/ bucket-1/  data-*.parquet           （LSM 数据文件，按主键 hash 分桶）

  10000 行写入 → 主键去重后 40 行；同主键再写 999 → 查询返回 999（UPDATE 语义，读时 LSM merge）
```

**jar 拉不动 / 环境跑不动时的 SIMULATED 模式**：不部署真集群，改为产出三份交付物——完整 compose 文件、可对真环境直接执行的完整 SQL 脚本、warehouse 目录结构说明文档。判分脚本自动识别 full / simulated 两种模式给分（先例：`07-cks/labs/05-runtimeclass`）。

## 任务清单

1. 在 `~/paimon-lab/` 编写 `docker-compose.yml`：`apache/flink:1.19` 的 session 集群，`jobmanager` + `taskmanager` 两个服务，`mem_limit` 各 2g，8081 映射到宿主机，`./warehouse` 以相同路径 `/opt/flink/warehouse` 挂进**两个**容器；`FLINK_PROPERTIES` 里设置 `execution.checkpointing.interval: 5s`（Paimon 的提交发生在 checkpoint，不开它写入永远不落 snapshot）。
2. 从 Maven Central 实查 `org.apache.paimon:paimon-flink-1.19` 的最新版本（用 `maven-metadata.xml`，**以实查为准**，2026-08 实查 latest 为 2.0.0），下载 jar 后 `docker cp` 进**两个**容器的 `/opt/flink/lib/` 并重启容器（实测还需补一个 Hadoop shaded 包并用 `-u flink` 跑 sql-client，见提示 6）；在 sql-client 里 `CREATE CATALOG paimon ...` 验证 bundle 已被加载。
3. 写 `init.sql` 并经 `docker cp` 送入 jobmanager 执行：有界 datagen 源表（`number-of-rows=10000`，`seq` 为 sequence 列，用计算列得到**确定性**主键——`host00..host19` 各 500 行、`metric` 按 seq 奇偶取 `cpu`/`mem`）→ 建 Paimon 主键表 `sre_lab.host_metrics`（`PRIMARY KEY (host, metric) NOT ENFORCED`，`file.format=parquet`，`bucket=2`）→ `INSERT INTO ... SELECT` 持续写。
4. 写 `verify.sql`（`SET 'execution.runtime-mode' = 'batch'` 后批查询）：`COUNT(*)` 精确等于 **40**（10000 行按主键去重），`host07` 恰好 2 行（cpu/mem 各一）。
5. 进 taskmanager 容器 `ls -R /opt/flink/warehouse/sre_lab.db/host_metrics/`：确认 `snapshot/`（含 `LATEST` 与至少一个 `snapshot-N`）、`manifest/`（非空）、`bucket-0/` 或 `bucket-1/`（含 parquet 数据文件）三层齐全，并 `cat` 一个 snapshot 文件看它的字段。
6. 写 `update.sql`：批模式向**同一主键** `('host07','cpu')` 再写一行 `val=999.0`；随后查询确认该行 `val` 为 999、`COUNT(*)` 仍为 40，并观察 snapshot 目录里出现了新的 `snapshot-N`（一次新的提交）。
7. （SIMULATED 模式）真环境不可用时，在本 lab 目录（`16-bigdata/labs/04-lakehouse-flink-paimon/`）下产出三份交付物：`docker-compose.yml`（同第 1 步要求）、`lakehouse-pipeline.sql`（第 3/4/6 步全部 SQL 合一的完整可执行脚本）、`warehouse-structure.md`（目录树逐项注释文档：snapshot/manifest/bucket 各管什么、一次 checkpoint 如何产生新 snapshot、更新一条主键在树上落成哪些新文件）。
8. 清理（跑完 check.sh 之后）：`docker compose down`、删除 `~/paimon-lab/warehouse/`；磁盘紧张时再 `docker rmi apache/flink:1.19`。

## 验收标准

- full 模式：`docker ps` 中 `flink-jm`、`flink-tm` 均 Running；TM 的 `/opt/flink/lib/` 下有 `paimon-flink-1.19-*.jar`；批查询 `COUNT(*) FROM sre_lab.host_metrics` 精确等于 40；`('host07','cpu')` 的 `val` 为 999；warehouse 表目录下 `snapshot/` 非空且 `manifest/` 非空，snapshot 文件内容含 `totalRecordCount` 等可读字段。
- simulated 模式：本目录下存在 `docker-compose.yml`（flink:1.19 双容器 + warehouse 共享挂载）、`lakehouse-pipeline.sql`（含 paimon catalog、PRIMARY KEY、datagen、INSERT INTO、batch 查询与主键更新）、`warehouse-structure.md`（含 snapshot/manifest/bucket 的职责说明）；check.sh 输出 `SIMULATED` 提示。

运行判分脚本：

```bash
# [任意节点]
cd 16-bigdata/labs/04-lakehouse-flink-paimon
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：为什么 warehouse 必须以相同路径挂进两个容器</summary>

Paimon 的 filesystem catalog 把表结构、snapshot、manifest 全部放在 warehouse 路径下：jobmanager 上的 sql-client 要读 catalog 元数据，taskmanager 上的 sink 算子要写数据文件与 manifest。两边看到的 `file:///opt/flink/warehouse` 若不是同一份磁盘（默认容器隔离，各自一份 `/opt/flink`），就会出现"表建了却查不到数据 / snapshot 永远不出现"的分裂现象。共享 bind mount（或命名卷）是 lab 环境的标准做法；生产对应的是 HDFS/S3/OSS 这类共享存储，路径两边天然一致。

</details>

<details><summary>提示 2：为什么必须开 execution.checkpointing.interval</summary>

Paimon sink 的提交（写 manifest + 生成 snapshot）挂在 Flink checkpoint 上：数据先写进 LSM 的内存/临时文件，checkpoint 成功后才对外可见。这是 05 章 §5 讲 sink 两阶段提交时同一条原则的又一化身——`notifyCheckpointComplete` 之后提交才生效。不开 checkpoint，写作业跑完也看不到 snapshot。反过来这也是运维信号：**snapshot 数异常增长/停滞，第一个该看的就是上游作业的 checkpoint 是否正常**（串回 12-data-streaming/flink 的 checkpoint 排障）。

</details>

<details><summary>提示 3：jar 与 Flink 版本必须严格配对</summary>

artifact 名字里的 `flink-1.19` 不是装饰：`paimon-flink-1.20` 挂到 1.19 集群会在作业提交期报 `NoSuchMethodError`/`ClassNotFoundException` 一类错误。版本列表以 `https://repo1.maven.org/maven2/org/apache/paimon/paimon-flink-1.19/maven-metadata.xml` 实查为准；若最新 major 与集群行为不匹配，退回该 artifact 的最新 1.x（如 1.4.2）。官方下载文档（paimon.apache.org 的 Flink 快速开始页）永远优先。

</details>

<details><summary>提示 4：SELECT 挂住不动，是查询模式错了</summary>

sql-client 默认 `execution.runtime-mode` 是 streaming：对湖表的 SELECT 会被当成连续查询，永远不结束。停写后做验证查询前必须 `SET 'execution.runtime-mode' = 'batch';`，让这次查询只扫当前 snapshot 后返回。"同一张表、两种运行模式"正是湖表流批一体的卖点（对照 07 章的 incremental consume 一节）。

</details>

<details><summary>提示 5：怎么确认写作业真的在跑</summary>

两个入口：浏览器开 `http://172.30.30.50:8081`（JobManager Web UI）看 Running Jobs 与 checkpoint 统计；命令行 `curl -s http://172.30.30.50:8081/jobs/overview` 看 JSON 里的 state。作业是有界源（10000 行，约 500 行/秒），20 秒左右进入 FINISHED——此时 `snapshot/` 目录里应有多个 `snapshot-N`，每个对应一次 checkpoint 提交。（`/opt/flink/bin/flink list` 这条 CLI 在装了 Hadoop shaded 包后会被老 commons-cli 弄坏，别依赖它。）

</details>

<details><summary>提示 6：jar 之外还有两块容易踩的拼图（2026-08 实测）</summary>

1. **Hadoop 类**：apache/flink 镜像不带 Hadoop，而 paimon 的 catalog 代码引用了
   `org.apache.hadoop.conf.Configuration`——不补包，1.x 在 `CREATE CATALOG`、2.0.0 在
   INSERT 提交期报 `ClassNotFoundException`。补法：把
   `flink-shaded-hadoop-2-uber-2.8.3-10.0.jar`（Maven Central 有）同样 `docker cp` 进
   **两个**容器的 `/opt/flink/lib/` 再重启。
2. **用户与目录属主**：容器里 JM/TM 进程以 `flink`（uid 9999）运行，而 `docker exec`
   默认是 root。sql-client 不加 `-u flink` 时，建出来的 `sre_lab.db/` 等目录是
   root:755，TM 写 bucket 时报 `Mkdirs failed to create .../bucket-N`；宿主
   `./warehouse` 目录（candidate:775）也要先 `chmod 777` 让 9999 可写。所以本 lab 所有
   sql-client 调用统一写 `docker exec -u flink flink-jm /opt/flink/bin/sql-client.sh ...`。

</details>
