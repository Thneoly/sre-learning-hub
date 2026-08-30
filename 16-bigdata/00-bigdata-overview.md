# 00 · 大数据全景：生态地图、三代架构与岗位画像

> 模块：16-bigdata ｜ 建议时长：1.5 小时 ｜ 关联认证：—（无直接考点；本章是本模块 7 章的坐标系，也是把已学的 K8s/Kafka/Flink 知识接入数据平台的第一步）

## 学习目标

- 能画出大数据生态的分层地图，说清存储 / 资源 / 批 / 流 / OLAP / 协调六层各自的代表组件与依赖方向
- 能解释三代架构（Hadoop 独立集群 → 存算分离上 K8s → 湖仓一体）各自的驱动力，以及每一代"运维对象"的变化
- 能把一条真实大数据运维 JD（百度 20-30K·16 薪）的每一句要求映射到学习中心的对应模块
- 能说清本模块与 `11-middleware`、`12-data-streaming` 的边界：什么时候是"又一个中间件"，什么时候是"一套新架构"

版本约定：本模块统一按 Hadoop 3.3.x、Spark 3.5.x、Doris 2.x、StarRocks 3.x、ZooKeeper 3.8/3.9 讲解。默认值与配置名随小版本可能调整，凡涉及具体默认值处以官方文档为准，不写死小版本号。

## 1. 生态地图：一条数据的六层流水线

大数据不是一个软件，是一**摞**互相依赖的子系统。先看地图（▲ 是已学内容，■ 是本模块要补的）：

```
┌─────────────────────────── 应用 / 查询层 ────────────────────────────┐
│      BI 报表(Superset/QuickBI)     数据服务 API     Ad-hoc 即席查询   │
└──────────────▲───────────────────────────▲──────────────────▲───────┘
       批处理计算                     流计算(▲已学)          OLAP 分析(■)
┌──────────────┴────────────┐  ┌───────────┴─────────┐  ┌─────┴─────────┐
│ MapReduce / Hive(03章■)   │  │ Kafka + Flink       │  │ Doris 2.x     │
│ Spark 3.5(04章■)          │  │ (12-data-streaming) │  │ StarRocks 3.x │
│                           │  │                     │  │ (05章■)       │
└──────────────▲────────────┘  └───────────▲─────────┘  └─────▲─────────┘
               │                           │                  │
┌──────────────┴───────────────────────────┴──────────────────┴─────────┐
│ 资源调度层：YARN(02章■, Hadoop 生态)  vs  Kubernetes(▲04-k8s/05-cka)   │
│    "计算要多少 CPU/内存"由这一层统一分配，上面的引擎都只是它的租户        │
└──────────────▲───────────────────────────▲────────────────────────────┘
┌──────────────┴───────────┐  ┌────────────┴────────┐  ┌────────────────┐
│ 存储层                    │  │ 消息队列(▲已学)      │  │ 湖表格式(三代)  │
│ HDFS(01章■) / 对象存储    │  │ Kafka               │  │ Iceberg/Hudi/  │
│ S3/OSS/Ozone             │  │                     │  │ Paimon         │
└──────────────────────────┘  └─────────────────────┘  └────────────────┘
               ▲                                          ▲
┌──────────────┴──────────────────────────────────────────┴─────────────┐
│ 协调层：ZooKeeper 3.8/3.9(06章■)                                       │
│   HDFS NameNode HA 选主 / YARN RM HA 选主 / 旧版 Kafka 依赖             │
└───────────────────────────────────────────────────────────────────────┘
```

分层读法（自下而上）：

| 层 | 代表组件 | 解决什么问题 | 谁来讲 |
|---|---|---|---|
| 协调 | ZooKeeper | 分布式选主、配置/锁的多数派仲裁 | 本模块 06 章 |
| 存储 | HDFS、对象存储（S3/OSS/Ozone） | 把几百台机器的本地盘拼成一个命名空间 | 本模块 01 章 |
| 资源 | YARN、K8s | 把几百台机器的 CPU/内存切成配额分给作业 | 本模块 02 章 + 已学 04-k8s/05-cka |
| 批处理 | MapReduce、Hive、Spark | T+1 / 小时级的离线加工 | 本模块 03/04 章 |
| 流处理 | Kafka、Flink | 秒级实时加工 | 已学 12-data-streaming |
| OLAP | Doris、StarRocks、ClickHouse | 亿行数据上的亚秒多维分析 | 本模块 05 章 |

两条阅读这张图的原则：

1. **每一层只对相邻层负责**。Spark 不关心数据在哪个 DataNode，HDFS 不关心跑作业的是谁——中间的解耦点就是"文件路径 + 资源申请"。排障时按层切边界：读慢先看存储层（HDFS），跑不动先看资源层（YARN），结果错才看引擎层。
2. **越往上越容易换，越往下越难换**。换报表工具是一周的事，把 HDFS 换成对象存储是年度项目。这也是 JD 里"大规模 Hadoop 集群"值钱的原因：存储层动一次，全公司跟着抖。

## 2. 三条典型数据链路

把地图竖起来看，真实公司里同时跑着这三条链路：

```
离线批链路（T+1，延迟分钟~小时级）
  业务 MySQL ──DataX/CDC──► HDFS(Hive 表/湖表) ──Spark/Hive──► 汇总层 ──► 报表

实时链路（秒级，12 模块已学）
  业务 MySQL ──CDC──► Kafka ──Flink──► Doris/StarRocks ──► 实时大盘

湖仓链路（三代架构，本模块 05 章展开）
  Kafka ──Flink──► Paimon/Iceberg 湖表(HDFS/对象存储)
                                    ├──Spark 离线回刷/修正
                                    └──Doris/StarRocks 直查湖表
```

同一个业务口径通常**同时**落在批和流两条链路上（实时看数、离线对账），这就是经典 Lambda 架构；湖仓一体的卖点之一就是用一份表格式（Iceberg/Paimon）把两边的口径收敛掉。

湖仓表格式三巨头（运维视角速览，05 章湖查询一节会再遇到它们）：

| | Iceberg | Hudi | Paimon（另有 Databricks 系 Delta Lake） |
|---|---|---|---|
| 出身 | Netflix 2018 | Uber 2016（2019 入 Apache） | Flink 社区出品，2023 成为 Apache 顶级项目 |
| 强项 | 引擎中立、隐藏分区、元数据独立可扩展 | **原生 upsert/CDC 增量入湖**、MoR/MaR 双写模式 | 流式湖存储，Flink 原生一体化 |
| 国内现状 | 大厂湖仓选型主流 | Flink 实时入湖场景强势（阿里 Flink 团队重仓贡献） | 中国社区最活跃的后起之秀 |

它们不是存储也不是计算引擎，而是**给对象存储/HDFS 上的文件堆加上"表语义"**（ACID 事务、增量读取、time travel、schema 演进）。运维要盯的四件事：**compaction/cluster 任务的调度**、**小文件与文件清单膨胀**、**schema 演进兼容策略**、**metastore/catalog 的备份**（它就是 11-middleware 里那台 MySQL 的又一化身）。

## 3. 三代架构演进：从"一锅端"到"各管一段"

```
第一代 2008~                    第二代 2016~                  第三代 2021~
Hadoop 独立集群                  存算分离 + 计算上 K8s          湖仓一体

┌────────────────┐            计算层(容器化、弹性)      ┌──────────────────┐
│ HDFS + YARN    │            ┌────────────────┐      │ 表格式 Iceberg/   │
│ 同一批节点耦合  │            │ Spark/Flink    │      │ Hudi/Paimon       │
│ 上跑 MR/Hive   │    ──►     │ on K8s(Operator)│ ──►  │ ACID 事务/模式演化 │
│ 存储和计算     │            └───────▲────────┘      │ 流批一体          │
│ 一起扩一起缩   │                    │ 读写            └────────▲─────────┘
└────────────────┘            ┌───────┴────────┐      ┌─────────┴────────┐
                              │ 独立 HDFS 集群  │      │ HDFS/对象存储 +    │
                              │ 或对象存储 S3   │      │ 多引擎共享一份表    │
                              └────────────────┘      └──────────────────┘
```

| 维度 | 一代：独立集群 | 二代：存算分离/上 K8s | 三代：湖仓一体 |
|---|---|---|---|
| 存储与计算 | 耦合在同一批节点 | 拆开：计算弹性伸缩，存储独立扩 | 拆开 + 表格式做事务层 |
| 扩容 | 加机器必须同时加存储和算力 | 计算按作业潮汐伸缩（Operator/HPA） | 计算无状态化，表即接口 |
| 升级 | Hadoop 整栈滚动升级，风险大 | 只滚动计算镜像 | 引擎逐个换，表不动 |
| 多引擎 | 基本只有 MR/Hive | Spark/Flink/Trino 各取所需 | Doris/StarRocks/Spark/Trino 共读一张表 |
| 运维对象 | 物理机 + 全栈 Hadoop 服务 | K8s 集群 + 独立存储集群 | 表、元数据、数据质量（越来越像平台工程） |
| 典型痛点 | 资源隔离弱、弹性差 | 跨 K8s 访存储的带宽、本地性丢失 | 小文件、compaction、元数据膨胀 |

SRE 视角的关键结论：**每一代演进都在把"状态"从计算层剥离**。一代里计算和存储绑死，一个失控作业能把 DataNode 拖垮；二代以后计算可以随便重启扩缩，状态留在 HDFS/对象存储；三代再把"表的事务语义"从引擎剥离到表格式。学本模块时始终带着这个问题：这一层的状态放在哪、谁来保证它不丢。

## 4. 大数据运维岗 JD 解构：市场要什么

数据来自 `_meta/research-2026-08-jd-platforms.md`（23 组关键词搜索 + JD 聚合页抓取的调研存档），不是编的：

**证据一（技能频次）**：硬技能频次排名第 12 位——"大数据运维（Hadoop/Spark/Flink/Kafka；Doris/StarRocks 加分）｜ 中频（特定行业）"。中频的意思是：不是所有运维岗都要，但互联网/金融/运营商的数据团队普遍要，而且**供给端会的人少**。

**证据二（薪资锚点）**：调研薪资表里可直接查到的三行：

| 岗位 | 薪资 | 来源 |
|---|---|---|
| 百度 大数据运维（大规模 Hadoop/Spark/Flink，Doris/StarRocks 优先） | 20-30K·16 薪 | BOSS 直聘 |
| 北京 SRE（整体分布） | 86.8% 落在 20-50K | 职友集 |
| AI Infra SRE（高级，万卡集群 + SLO 体系） | 40-70K·15 薪 | 猎聘 |

也就是说：大数据运维的薪资带与一线 SRE 重叠，却额外要求分布式存储/调度栈——对已具备 K8s 与可观测栈基础的运维工程师，这是一条竞争密度相对更低的路线。调研同时把 Doris/StarRocks 列入"高频加分项"名单。

把那条百度 JD 拆开，每一句都能落到具体章节：

| JD 措辞 | 背后实际考什么 | 学习中心位置 |
|---|---|---|
| 大规模 Hadoop 集群运维 | HDFS 元数据/HA/容量、YARN 队列/多租户，规模带来的排障套路 | 本模块 01/02 章 |
| Spark/Flink 作业支撑 | 资源模型、内存调优、作业级排障、on K8s 部署 | 本模块 04 章 + `12-data-streaming/flink` |
| Kafka 高可用 | 已完成 | `12-data-streaming/kafka` |
| Doris/StarRocks 优先 | OLAP 存算架构、导入链路、compaction 治理 | 本模块 05 章 |
| 监控告警体系建设 | JMX exporter + PromQL + 大盘 | `08-pca/04-instrumentation-exporters.md` |
| Shell/Python 自动化 | 巡检/发布/自愈脚本 | `02-programming` |
| K8s 容器化改造 | 计算层上 K8s（Operator 形态） | `04-k8s-fundamentals`、`05-cka` |
| 沟通/抗压/值班 | 跨团队推动（调研指出的中级→高级分水岭） | `13-sre-methodology` |

注意 JD 里**没有**出现的东西：不要求写 MapReduce/SQL 业务代码。大数据**运维**岗的考题全部落在架构原理、部署容量、监控排障上——这正是本模块的写法。

## 5. 本模块与 11/12 的关系

`11-middleware` 教的是"单组件的通用运维套路"：部署、主从切换、备份、监控。`12-data-streaming` 教的是"流式管道"。本模块引入的是**真正的分布式架构**——形态变了，套路要升级：

| 维度 | 11 中间件（MySQL/Redis） | 12 流栈（Kafka/Flink） | 16 大数据（本模块） |
|---|---|---|---|
| 典型节点数 | 3~6 | 3~10 broker/TM | 10~数千节点 |
| 复制模型 | 主从/哨兵 | ISR 多数派 | 3 副本/纠删码 |
| 元数据 | 单机盘上 | KRaft Controller | 集中于 NameNode/RM，全内存 |
| 扩容 | 加从库 | 加分区/加 broker | 加 DataNode + Balancer 跑数天 |
| 单点故障半径 | 单实例 | 单 broker | 单 DN 掉线触发副本补齐风暴 |
| 网络背景的杠杆 | TCP/背压 | 带宽与时延敏感 | 机架拓扑、10G+ 网络、长连接 RPC |

三者的知识是**叠加**关系：Kafka 的副本与 ISR（`12-data-streaming/kafka/02-replication-and-reliability.md`）让你能秒懂 HDFS 三副本；Redis 的 RDB 快照与 AOF 重写（`11-middleware/redis/02-persistence-and-ha.md`）让你能秒懂 NameNode 的 fsimage + edits。反过来，"Kafka 为什么去 ZK 化（KRaft）"这个问题，要学完本模块 06 章 ZooKeeper 后才有完整答案。

模块内学习路径：

```
00 全景(本章) ─► 01 HDFS ─► 02 YARN ─► 03 Hive ─► 04 Spark ─► 05 Doris/StarRocks ─► 06 ZooKeeper
      │            │           │                                      ▲
      └── 已学 K8s 提供"资源层"的对照组 ─────────────────────────────────┘
          已学 Kafka/Flink 提供"流侧"与"上 K8s"的对照组
```

01/02 是地基：后面每一章的故障，追到底不是落在 HDFS 就是落在 YARN。

## 实战演练

本章只做一件事：把生态地图的抽象概念落到一个能敲的容器上。这个 `hadoop-lab` 容器后续两章会继续用（第 1 章起 HDFS，第 2 章起 YARN），**做完不要删**。

```bash
# [任意节点] 拉起本模块全程使用的 Hadoop 容器（Apache 官方镜像，3.3.x 系列）
docker run -d --name hadoop-lab -h hadoop-lab -p 9870:9870 -p 8088:8088 \
  --entrypoint bash apache/hadoop:3.3.6 -c 'sleep infinity'
# 9870 是第 1 章 NameNode Web UI，8088 是第 2 章 ResourceManager Web UI
# 镜像 tag 以 Docker Hub apache/hadoop 官方页面为准，取 3.3.x 最新即可
```

```bash
# [任意节点] 确认版本与 HADOOP_HOME（后续所有 docker exec 命令都沿用这个值）
docker exec hadoop-lab bash -c 'echo HADOOP_HOME=$HADOOP_HOME && hadoop version'
# 预期输出：
#   HADOOP_HOME=/opt/hadoop
#   Hadoop 3.3.6
#   Source code repository ... -r xxx
# 若 HADOOP_HOME 不是 /opt/hadoop，后续把命令里的路径换成实际值
```

```bash
# [任意节点] 生态地图的物理形态：一个发行包里装着各层子项目
docker exec hadoop-lab bash -c 'ls $HADOOP_HOME/share/hadoop'
# 预期输出：common  hdfs  mapreduce  yarn  tools ...
# common=基础库, hdfs=存储层, yarn=资源层, mapreduce=批计算——
# 地图上的三层在磁盘上就是几个目录，"Hadoop 生态"本来就是从一个包拆出来的家族

# 每个 tar 包自带的默认配置（生产会被完全覆盖重写）
docker exec hadoop-lab bash -c 'ls $HADOOP_HOME/etc/hadoop/ | grep -E "site.xml$|scheduler.xml$"'
# 预期输出：capacity-scheduler.xml  core-site.xml  hdfs-site.xml
#           httpfs-site.xml  kms-site.xml  mapred-site.xml  yarn-site.xml
```

```bash
# [任意节点] 本模块前两章的两类入口命令，先眼熟
docker exec hadoop-lab bash -c 'ls $HADOOP_HOME/bin | grep -E "^(hdfs|yarn)$"'
# 预期输出：hdfs  yarn（第 1 章用 hdfs，第 2 章用 yarn）
```

验证方法：`hadoop version` 正常返回、`share/hadoop` 下 common/hdfs/mapreduce/yarn 四个目录齐全即通过。

最后一项是纸面作业：把第 4 节的 JD 映射表抄一遍，在每个格子后写下你当前的水平（已学 / 本模块会学 / 还需自学），这份清单就是接下来三个季度的学习路线。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 把大数据当"十几个新中间件"逐个背 | 组件是分层依赖关系，不是并列清单 | 按地图自下而上学：01/02 地基不牢，后面全靠死记 |
| 拿 2.x 时代教程学 | Hadoop 2.x 与 3.x 差异大（2NN vs HA 常态、纠删码、Web 端口 50070→9870） | 统一看 3.3.x 官方文档 |
| 跳过 HDFS/YARN 直接学 Spark | 作业故障 80% 落在存储与资源层 | 先 01/02，04 章会轻松一倍 |
| 默认大数据系统都跑在 K8s 上 | 存算分离趋势下计算在 K8s，存储常留在独立集群甚至物理机 | 见第 1 章结尾的现状分析 |
| 分不清 Hive/Doris/Spark 的分工 | 三者都能跑 SQL | 批加工用 Spark/Hive，交互分析用 Doris/StarRocks（05 章） |

## 自测

1. 为什么 Spark 既能跑在 YARN 上又能跑在 K8s 上？这说明六层地图里哪一层是"可替换"的，替换时引擎要适配什么？
<details><summary>答案</summary>

资源调度层可替换。Spark 只需要一个"给我 N 份 CPU/内存，再把我的 executor 进程拉起来"的接口：YARN 的 Container 和 K8s 的 Pod 都能满足，差别在提交协议（YARN 的 ApplicationMaster 协议 vs K8s 的 Pod/Operator）与资源描述方式（静态申请 vs requests/limits）。存储层同理可替换（HDFS/对象存储），但计算引擎要适配各自的文件系统客户端。这正是第二代架构"存算分离"能成立的原因：各层之间靠窄接口解耦。
</details>

2. 三代架构里"运维对象"分别是什么？为什么说湖仓一体让大数据运维更接近平台工程？
<details><summary>答案</summary>

一代：物理机 + 全栈 Hadoop 服务，运维盯进程和磁盘。二代：K8s 集群与独立存储集群两套对象，运维开始写 Operator/Helm 而不是改配置推机器。三代：核心对象变成"表"——表格式元数据、小文件、compaction、数据质量；用户按表自助使用，运维提供平台与规范。这与"平台工程=自助式基础设施+规范制定"的定义重合，也解释了为什么大数据运维 JD 越来越多要求 K8s 与自动化开发能力。
</details>

3. Kafka 已经用 KRaft 去掉了 ZooKeeper，为什么 HDFS NameNode HA 和 YARN RM HA 至今仍常用 ZooKeeper？
<details><summary>答案</summary>

Kafka 的元数据（分区副本状态）本身就需要一条多数派日志，KRaft 把"选主"与"日志复制"合并进 broker，去 ZK 是合并不是消灭。HDFS 的元数据是全内存命名空间（fsimage + edits），JournalNode 已承担多数派日志，ZK 只负责"谁是 Active"这一个选举问题，替换收益小、迁移风险大。YARN 同理，且 RM 的调度状态可由 NM 汇报重建。结论：去不去 ZK 取决于元数据的形态与重建成本，不是潮流（详见 01/02/06 章）。
</details>

4. JD 里"大规模"三个字，具体改变了哪些运维手段？给出至少三个例子。
<details><summary>答案</summary>

例：NameNode 堆容量与小文件治理（元数据对象数以亿计，堆 50GB 起步）；Balancer 一次跑数天，必须与业务错峰并限速；全量块报告与重启 edits 回放时间不可忽略，发布要算窗口；队列与租户数暴涨，需要标签调度隔离；监控从"单实例 up/down"变成"集群水位+长尾"（副本补齐队列、RPC p99）。小集群靠人肉的场景，大规模全要制度化、工具化。
</details>

5. Doris/StarRocks 和 Hive on MR 的根本差异是什么？为什么 JD 把前者列为"优先"？
<details><summary>答案</summary>

Hive/MR 是"批处理引擎 + 扫文件"，延迟分钟级，面向 T+1 加工；Doris/StarRocks 是 MPP 架构的 OLAP 数据库：列式存储 + 预聚合（Rollup/物化视图）+ 向量化执行，面向亿行亚秒交互查询。业务实时看数的诉求增长，使"会维护 OLAP 集群（导入链路、compaction、副本）"成为稀缺加分项，故 JD 标注优先（05 章展开）。
</details>

## 延伸阅读

- Hadoop 官方文档入口（各子项目文档索引）：https://hadoop.apache.org/docs/stable/
- HDFS Architecture（分层地图中存储层的官方描述）：https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HdfsDesign.html
- Apache Spark 官方文档：https://spark.apache.org/docs/latest/
- Apache Iceberg 表格式文档：https://iceberg.apache.org/docs/latest/
- Apache Paimon（流湖一体）：https://paimon.apache.org/docs/master/
- Apache Hudi 文档：https://hudi.apache.org/docs/overview/
- Apache Doris 文档：https://doris.apache.org/
- StarRocks 官方文档：https://docs.starrocks.io/
