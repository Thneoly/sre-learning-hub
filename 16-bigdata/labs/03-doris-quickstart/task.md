# Lab 03 · Doris 快速起步：Unique 模型、Stream Load 与幂等重放

> 难度：★★★ ｜ 考点：16-bigdata/05-olap（Unique 模型 / Stream Load / 分区分桶） ｜ 前置：03-docker 的 compose 与资源限制；11-middleware/mysql（Doris 使用 MySQL 协议） ｜ 预计 60~90 分钟（含拉镜像）

## 场景

监控团队要一张"主机指标明细表"做即席聚合查询，选型 Doris（MPP 架构 OLAP，FE 存元数据/解析 SQL，BE 存列存数据/执行，对外暴露 MySQL 协议——客户端生态与 `11-middleware/mysql` 完全互通）。你要在 docker compose 里起一套 FE+BE（各限 2G 内存），建 Unique 模型表，用 Stream Load 灌 1 万行 CSV，再验证一次**重放导入**：上游重发同一批数据（`12-data-streaming/kafka` 里 consumer rebalance 的经典场景），表里不能多出一行。

**环境跑不动时的 SIMULATED 模式**：VM 内存不足（FE+BE 共 4G 挤爆 10G 内存的机器）、镜像拉不动时，不部署真集群，改为产出三份交付物——建表 SQL、Stream Load 导入脚本、导入计划文档。判分脚本自动识别 full / simulated 两种模式给分（先例：`07-cks/labs/05-runtimeclass`）。

```
   curl -- Stream Load (HTTP 8030) --> FE ----307 重定向----> BE (HTTP 8040, 真正写入)
   mysql client (9030) -------------> FE ----SQL 解析/计划--> BE(执行, 列存 segment)
                                          │
                                          └ Unique 模型: 按 Key 去重, 重放同批数据行数不变
```

## 任务清单

1. 在 `~/doris-lab/` 编写 `docker-compose.yml`：FE（`apache/doris` 2.x fe 镜像）与 BE（同版本 be 镜像）两个服务，`mem_limit` 各 2g，固定子网 IP（FE 172.31.80.2 / BE 172.31.80.3），FE 映射 8030/9030，BE 映射 8040；镜像 tag 用环境变量 `DORIS_FE_IMAGE` / `DORIS_BE_IMAGE` 可覆盖，默认值 `fe-2.1.9` / `be-2.1.9`（2026-08 实测可用；旧 `X-fe-x86_64` 形态 tag 已下架，tag 命名以 Docker Hub `apache/doris` 页面为准）。
2. `docker compose up -d`，轮询等待 FE 就绪（MySQL 协议 `SELECT 1` 通），然后 `SHOW FRONTENDS;` / `SHOW BACKENDS;` 确认 Alive——BE 由 `BE_ADDR` 环境变量自动注册，不需要手工 `ADD BACKEND`。
3. 建库 `sre_lab`、建 Unique 模型表 `events`：`UNIQUE KEY(event_day, event_time, host, metric)`，按天 RANGE 分区、`HASH(host) BUCKETS 4`、`replication_num=1`，value 列默认 REPLACE 语义（注意 2.x 的 Unique 模型 DDL 里**不写** `REPLACE` 关键字，写了建表报错——覆盖语义是模型自带的）。
4. 用 python3 生成确定性 `events.csv`：恰好 10000 行（host00..host19 各 500 行，value 满足可验证的求和公式）。
5. 写 `stream-load.sh`（label 参数化），第一次导入 10000 行并检查返回 JSON 的 `Status`/`NumberLoadedRows`；**换一个新 label 重放同一文件**，验证 `COUNT(*)` 仍是 10000（Unique 模型幂等），并跑两条聚合查询核对预计算结果。
6. （SIMULATED 模式）真环境不可用时，在本 lab 目录下产出：`doris-schema.sql`（建库建表 DDL）、`stream-load.sh`（可直接对宿主机 8030 端口执行的导入脚本）、`import-plan.md`（导入计划：数据量、批次大小、label 命名规则、失败重试与校验查询）。
7. 清理（跑完 check.sh 之后）：`docker compose down -v` 并删除宿主机数据文件。

## 验收标准

- full 模式：`docker ps` 中 `doris-fe`、`doris-be` 均 Running；`SHOW BACKENDS` 中 BE 的 Alive 为 1/true；`SELECT COUNT(*) FROM sre_lab.events` 精确等于 10000（重放之后仍是 10000）；`SELECT ROUND(SUM(value),2) FROM sre_lab.events` 为 7492500.0；`SELECT COUNT(*) FROM sre_lab.events WHERE host='host07'` 为 500；`SHOW CREATE TABLE` 显示 `UNIQUE KEY`。
- simulated 模式：本目录下存在 `doris-schema.sql`（含 UNIQUE KEY / BUCKETS / replication_num）、`stream-load.sh`（含 `_stream_load` 与 label 变量）、`import-plan.md`（含 label 规则与失败重试小节）；check.sh 输出 `SIMULATED` 提示。

运行判分脚本：

```bash
# [任意节点]
cd 16-bigdata/labs/03-doris-quickstart
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：镜像 tag 与固定 IP 为什么要这么写</summary>

Doris 官方镜像 tag 命名随版本变过：旧的 `2.0.3-fe-x86_64` 形态已从 Docker Hub 下架（pull 报 not found），现行是 `fe-2.1.x` / `be-2.1.x` 形态，具体可用 tag 以 Docker Hub `apache/doris` 页面为准，所以 compose 里用 `${DORIS_FE_IMAGE:-默认tag}` 方便一键覆盖。FE/BE 的元数据里会持久化 IP，容器重启换 IP 就"分裂"成假集群——compose 里给两容器固定 `ipv4_address` 是官方 docker 部署文档的标准做法。

</details>

<details><summary>提示 2：FE 怎么知道 BE、BE 怎么注册</summary>

镜像支持环境变量声明式组网：FE 用 `FE_SERVERS`（自己是谁）+ `FE_ID`；BE 用 `FE_SERVERS`（去找哪个 FE）+ `BE_ADDR`（向 FE 上报自己的地址）+ `PRIORITY_NETWORKS`（在内网多网卡时锁定选哪个网段）。这套变量与官方 docker 部署文档一致，字段语义以该文档为准。

</details>

<details><summary>提示 3：Stream Load 第一次 curl 返回 307 或报错</summary>

Stream Load 是"发到 FE、FE 回 307 重定向到 BE、真正写入在 BE"的三段式。curl 默认不跟随 307，需加 `--location-trusted`（跟随重定向并把 `-u` 的 Authorization 头透传给 BE），或者绕开 FE 直发 BE 的 8040 端口；若返回 `Fail to connect to BE` 类错误，多半是 BE 的 8040 没映射到宿主机或 BE 没注册（回第 2 步看 SHOW BACKENDS）。注意 Stream Load 的数据流必须**一次性**发给 BE，不能分次续传。

</details>

<details><summary>提示 4：重放为什么必须换 label</summary>

Doris 的 label 是导入幂等键：同一 label 在保留期内（默认 3 天）第二次提交会被直接拒绝（At-Most-Once 语义，防重复消费）。所以"重放同一批数据"要带**新 label**——重复防护靠 label，数据不涨靠 Unique 模型的 REPLACE，两层机制各管一件事。这正是 Kafka 重放场景的标准配套：label 可以用 `topic-partition-offset` 命名（见 import-plan.md 的规则）。

</details>

<details><summary>提示 5：FE/BE 起不来或反复重启</summary>

看 `docker logs doris-fe` / `docker logs doris-be`：FE 报 OOM 是 JVM 堆超过 2g 容器限额，进容器把 `conf/fe.conf` 的 `-Xmx` 调小（如 1g）再重启容器；BE 被 OOMKilled 是其 `mem_limit` 配置（be.conf，默认按机器内存百分比）超过容器限额，改成一个小于 2g 的绝对值（如 1600000000）重启。两者都以官方 docker 部署文档的推荐值为准。

</details>
