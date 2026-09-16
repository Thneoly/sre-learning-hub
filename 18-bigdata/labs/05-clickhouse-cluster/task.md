# Lab 05 · ClickHouse 双分片集群：ReplicatedMergeTree、Distributed 与 parts 观察

> 难度：★★★ ｜ 考点：18-bigdata/08（MergeTree 家族 / 主键非索引 / 双表架构 / too many parts） ｜ 前置：18-bigdata/06（ZooKeeper，本 lab 的协调后端）、18-bigdata/08 章（表引擎与 Distributed 的机制都在那章）；03-docker 的 compose 与 `mem_limit` 资源限制（labs/06-resource-limits） ｜ 预计 60~90 分钟（含拉镜像）

## 场景

平台组要给监控团队上一套 ClickHouse 存主机指标（选型理由见 05 章第 4 节：单表海量日志聚合、追求极限吞吐）。你是负责落地的 SRE：05 章只给了对比表，08 章给了机制——**"复制是表引擎前缀、分片是建表决策、ZK/Keeper 在中间协调"**这些结论，这次要亲手验证一遍。生产拓扑是 2 分片 ×2 副本（4 台 CH + 3 台 Keeper），lab 里用 2 台 CH + 1 台 ZK 做两个缩小版：`sre_lab`（2 分片 × 各 1 副本，验证数据分布与 parts）与 `sre_lab_ha`（1 分片 ×2 副本，验证 ZK 协调的真复制与停节点冗余）。

```
                    zookeeper（512M，06 章的那套）
                    /clickhouse/tables/{01,02}/metrics_local   ← 两个分片各自的复制协调子树
                    /clickhouse/tables/ha/ha_local             ← 双副本共享子树（同路径不同 replica 名）
                              ▲
        ┌─────────────────────┴──────────────────────┐
        │ ch1（2G）                                    │ ch2（2G）
        │  shard 01 本地表 metrics_local（r1）          │  shard 02 本地表 metrics_local（r2）
        │  ha_local 副本 r1 ◄──── ZK 复制日志 ────►    │  ha_local 副本 r2
        │  metrics_all = Distributed(路由视图，不存数据) │
        └──────────────────────────────────────────────┘
   写入：INSERT INTO metrics_all（连 ch1）→ sipHash64(host) 劈开 → 两分片本地表
   100000 行 = 10 批 × 10000；每批 INSERT = 每节点至多 1 个新 part → 写完看 parts、OPTIMIZE 后再看
```

环境：装有 Docker 与 compose 插件的 Ubuntu VM（内存 6G 以上），三容器同属独立网络 `ch-lab-net`。

## 任务清单

1. 在 `~/ch-lab/` 编写 `docker-compose.yml`：三个服务同网络 `ch-lab-net`——`zookeeper`（镜像 `zookeeper:3.9`，`mem_limit` 512m，堆 256m）；`ch1`、`ch2`（镜像用环境变量 `CH_IMAGE` 可覆盖，默认 `clickhouse/clickhouse-server:25.3`，tag 以 Docker Hub 官方页面当前 LTS 为准；`mem_limit` 各 2g；`ulimits.nofile` 262144；**环境变量 `CLICKHOUSE_SKIP_USER_SETUP=1`**——不设的话 25.x 镜像会把 `default` 用户限制为仅本机访问，Distributed 表的跨节点读写会报 `AUTHENTICATION_FAILED`；ch1 映射 8123/9000，ch2 映射 8124/9001）。两个 CH 容器挂载**相同**的 `conf/cluster.xml`（ZK 地址 + `sre_lab`/`sre_lab_ha` 两个集群拓扑）和**各自不同**的 `conf/macros-ch*.xml`（ch1: shard=01/replica=r1；ch2: shard=02/replica=r2）到 `/etc/clickhouse-server/config.d/`。
2. `docker compose up -d` 后轮询等待两节点 `clickhouse-client --query 'SELECT 1'` 均通，并用 `SELECT count() FROM system.zookeeper WHERE path = '/'` 确认 ZK 协调通道在位。
3. 在 ch1 上用 `ON CLUSTER sre_lab` 建库表：`sre_lab.metrics_local`（`ReplicatedMergeTree('/clickhouse/tables/{shard}/metrics_local','{replica}')`，`ORDER BY (host, ts)`，按天分区）；`sre_lab.metrics_all`（`Distributed('sre_lab','sre_lab','metrics_local', sipHash64(host))`）；`sre_lab.host_agg`（SummingMergeTree）+ `sre_lab.metrics_mv`（物化视图写入 host_agg，**必须在写入数据之前创建**）+ `sre_lab.host_agg_all`（host_agg 的 Distributed 外表）。再在 `ON CLUSTER sre_lab_ha` 上建 `sre_lab.ha_local`（`ReplicatedMergeTree('/clickhouse/tables/ha/ha_local','{replica}')`——注意 zk 路径**不带 {shard}**，两副本同路径）。
4. 批量写入：10 个批次 × 每批 10000 行（`INSERT INTO sre_lab.metrics_all SELECT ... FROM numbers()` 服务端造数）：`ts = toDateTime(today()) + b*3600 + (n % 3600)`（**批次 b 错开 1 小时**——四个字段的取值周期都整除 3600，若不加批次偏移，batch b 与 b+9 的块完全相同，会被 ReplicatedMergeTree 按块哈希去重，总量只有 90000），`host = host00..host19`（`leftPad`），`metric` 按 n 奇偶取 `cpu`/`mem`，`val = toFloat64(n % 100)`，批次 b 的 n 范围 `b*10000 .. b*10000+9999`。
5. 验证数据分布：`metrics_all` 的 `count()` 精确等于 **100000**、`toUInt64(sum(val))` 精确等于 **4950000**；ch1 与 ch2 各自 `metrics_local` 的 `count()` 都 > 0，且**两者之和 = 100000**（各分片具体数字不固定——sipHash 分片）。
6. 观察 parts 与 merge：写入完成后立刻记录两节点 `system.parts WHERE table='metrics_local' AND active` 的 count；可选地在另一终端 `SELECT * FROM system.merges` 看一次进行中的 merge；对两节点执行 `OPTIMIZE TABLE sre_lab.metrics_local FINAL` 后再记录一次。把前后数值写入 `parts-observation.txt`，每行格式固定为：`ch1 parts_before=10 parts_after=1` / `ch2 parts_before=10 parts_after=1`（数值以实测为准）。
7. 验证物化视图：`host_agg_all` 的 `sum(cnt)` = 100000；`host='host07'` 的 `sum(cnt)` = 5000、`toUInt64(sum(vsum))` = 235000（造数公式的确定性结果）。
8. 副本演练：向 ch1 的 `ha_local` 插 3 行，到 ch2 上 `SELECT count()`——**没在 ch2 插过却能看到 3 行**（ZK 复制日志同步的副本）；`docker stop ch2` 后在 ch1 上：`ha_local` 仍可查（副本冗余）、`metrics_all` 报错（2 分片 ×1 副本，坏一个分片就缺一块数据——这就是生产要 2×2 的原因）；`docker start ch2`，等它恢复 Running 且 `SELECT 1` 通。
9. 回到本 lab 目录运行 `check.sh` 判分；之后清理：`cd ~/ch-lab && docker compose down`（网络随 compose 删除），磁盘紧张再 `docker rmi` 两个镜像。

## 验收标准

- `docker ps` 中 `ch1`、`ch2`、`zookeeper` 三容器均 Running；
- `metrics_all` count() 精确 100000，`sum(val)` 精确 4950000；ch1+ch2 本地 count 之和 = 100000 且各自 > 0；
- `SHOW CREATE TABLE sre_lab.metrics_local` 含 `ReplicatedMergeTree`、`metrics_all` 含 `Distributed`；
- `parts-observation.txt` 存在（check.sh 所在目录、`~/ch-lab/`、运行 check.sh 的当前目录三处任一），含 ch1/ch2 两行 `parts_before=N parts_after=M`；
- `host_agg_all` sum(cnt) = 100000、host07 的 cnt=5000 与 vsum=235000；
- `system.zookeeper` 可查、`system.replicas` 中 is_readonly 的表数为 0。

运行判分脚本：

```bash
# [任意节点]
cd 18-bigdata/labs/05-clickhouse-cluster
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：镜像 tag、内存与 ulimit</summary>

`clickhouse/clickhouse-server` 的 tag 一年多更（形如 24.8、25.3、25.8），以 Docker Hub 官方页面的当前 LTS 为准，本 lab 用 `CH_IMAGE` 环境变量默认 25.3，拉不到就 `CH_IMAGE=clickhouse/clickhouse-server:<现行LTS> docker compose up -d` 覆盖。`mem_limit 2g` 下 ClickHouse 会按 cgroup 自动限制 server 内存（现代版本可识别容器限额，若仍被 OOMKill，参考官方 docker 文档显式配置 `max_server_memory_usage`）。`ulimits.nofile` 不给足时高并发写入会报 too many open files。zookeeper 容器限 512m 的同时把 `ZK_SERVER_HEAP` 设 256（MB）：镜像默认堆可能超过容器限额，OOMKill 反复重启（06 章第 6.3 节"脑旋"的容器版先兆）。

</details>

<details><summary>提示 2：cluster.xml 挂载与 ON CLUSTER 的关系</summary>

CH 节点对"集群"的全部认知来自 `/etc/clickhouse-server/config.d/` 里的 `<remote_servers>`（谁在哪个分片、哪个端口）与 `<zookeeper>`（协调后端地址）——两个 CH 容器挂同一份 cluster.xml、各自挂不同的 macros.xml（`{shard}`/`{replica}` 宏替换发生在建表时）。`ON CLUSTER` 的 DDL 经 ZK 的分布式 DDL 队列广播到各节点（所以第 2 步必须先确认 ZK 通）；`Distributed` 表的读写路由也按 remote_servers 找节点。内部端口一律用容器网络里的 `ch1:9000`/`ch2:9000`（native 协议），宿主机映射的 9001 只给你从外面连。

</details>

<details><summary>提示 3：zk_path 写错的三种结局</summary>

`ReplicatedMergeTree('/clickhouse/tables/{shard}/metrics_local','{replica}')` 里路径相同+replica 名不同=一组副本。metrics_local 用 `{shard}` 区分两个分片（01/02 各自成组，每组恰好一个副本）；ha_local 故意写死 `/clickhouse/tables/ha/ha_local` 不带 `{shard}`，两节点的 `{replica}` 是 r1/r2 → 同一组两个副本，插入 ch1 自动经复制日志同步到 ch2。写错的两类事故：两副本路径不同 → 各写各的"假复制"；两副本 replica 名相同 → 互相认领踢对方（08 章第 4 节）。

</details>

<details><summary>提示 4：为什么物化视图必须先建</summary>

MV 只处理创建**之后**落入基表的数据（08 章第 7 节）。本 lab 的顺序是"建表 → 建 MV → 10 批写入"，所以 host_agg 覆盖全部 100000 行。如果你先写了数据再补 MV，sum(cnt) 只会算到补建之后的部分——那不是 bug，是语义；给存量数据补聚合要走手动回填，不要赌 `POPULATE`（并发窗口会漏数据）。

</details>

<details><summary>提示 5：停 ch2 时两个查询为什么一好一坏</summary>

`ha_local` 的两个副本分别在 ch1/ch2 上，ch2 停了 ch1 上还有完整一份 → 查询照常（这就是副本冗余）。`metrics_all` 的两个分片各只有 1 个副本，ch2 停了 = shard 02 的数据连不上 → Distributed 查询直接报错（默认 `skip_unavailable_shards=0`）。生产把两个维度乘起来（2 分片 ×2 副本 = 4 节点），坏任意单节点既不丢分片也不丢副本。恢复后 ch2 会自动追平复制日志，`docker start` 之后等 `SELECT 1` 通再继续。

</details>

<details><summary>提示 6：parts 数字不匹配怎么办</summary>

10 批 INSERT 之后每节点的 active parts 通常是 10 上下，但**后台 merge 随时在跑**，你记录 before 的时机不同、数字就可能小于 10——这不影响判分（判分只看记录格式与 after ≥ 1）。要点是"每批 INSERT 至少一个新 part、OPTIMIZE 后合并成每分区 1 个"这个对比关系成立。如果 before=1，说明 merge 已经追完了，同样算观察成功。

</details>
