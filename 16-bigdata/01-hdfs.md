# 01 · HDFS：NameNode、块模型与丢失块排障

> 模块：16-bigdata ｜ 建议时长：4 小时 ｜ 关联认证：—（无直接考点；NameNode HA 的选主/仲裁与 K8s 控制面同构，JMX 监控接入复用 PCA 的 exporter 知识）

## 学习目标

- 能解释 NameNode 元数据"全内存 + edits + fsimage + checkpoint"的设计取舍，并量化"NN 堆要配多大"
- 能画出 NN HA（JournalNode + ZKFC）的故障切换过程，说清 fencing 为什么必须存在
- 能写出一个文件的 3 副本在机架感知下的放置位置，并对比 3 副本与纠删码的成本模型
- 能完整描述写 pipeline 与读就近原则的路径，定位"写慢/读慢"分别该查哪一段
- 能按 runbook 处理 safemode 卡住、丢失块/损坏块、数据倾斜、小文件这四类高频故障

版本约定：以 Hadoop 3.3.x 行为为准，docker 演练用镜像 `apache/hadoop:3.3.6`；具体默认值随小版本可能变化，以官方文档为准。

## 1. NameNode：把整个文件系统的元数据放进一块内存

HDFS 是主从架构：NameNode（NN，一主）管元数据，DataNode（DN，成百上千）管数据块。NN 内存里放三样东西：

```
NN 内存命名空间（重启即失，靠 fsimage+edits 恢复）
 ├── inode 树：每个文件/目录一个对象（路径、权限、时间戳）
 ├── 文件 → 块列表：/dw/ods/orders/part-0 → [blk_1, blk_2, ...]
 └── 块 → DN 映射：blk_1 → [dnA, dnF, dnK]   ← 由 DN 的块报告构建，不落盘
```

持久化机制是一套标准的 **WAL + 快照**（与 `11-middleware/redis/02-persistence-and-ha.md` 的 AOF + RDB 完全同构，可对照记忆）：

| 机制 | 是什么 | 关键点 |
|---|---|---|
| edits | 变更日志（WAL），所有 mkdir/put/rename/setReplication 先写它 | 重启时回放；只追加，顺序写 |
| fsimage | 命名空间完整快照 | 体积大，不能频繁生成 |
| checkpoint | 把 fsimage + 之后的 edits 合并成新 fsimage | HA 集群由 Standby NN 完成；非 HA 由 2NN 完成 |

```
客户端 put/mkdir/rename ──①先追加──► edits_inprogress_00000123（保证可回放）
                                      │
        ②Standby NN 定期拉取全部 edits │（HA：checkpoint 的执行者）
                                      ▼
        fsimage_00000120 + edits(121..123) ──合并──► fsimage_00000123 回传 Active
```

checkpoint 触发条件默认是"每 1 小时或累计 100 万事务"（`dfs.namenode.checkpoint.period` / `dfs.namenode.checkpoint.txns`，以官方文档为准）。运维上必须盯住一件事：**checkpoint 失效会让 edits 无限增长**——NN 重启时要先回放几千万条 edits，集群在 safemode 里卡几十分钟。这是"重启窗口比预期长一倍"的头号原因。

为什么必须全内存：每次写操作要逐级解析父目录路径并加锁，每次读要按块查位置，这些是**高频随机访问**，放磁盘（B+ 树/LSM）意味着每个操作多几次磁盘随机 IO，延迟从微秒级掉到毫秒级。代价是：**元数据规模 = 堆规模**，且重启要重新构建"块 → DN"映射（依赖块报告），这两条是 HDFS 所有大集群运维问题的源头。

## 2. NameNode HA：JournalNode 仲裁 + ZKFC 自动切换

单点 NN 一重启全公司停摆，所以生产一律 HA：

```
                        ZooKeeper（/hadoop-ha/${ns} 临时锁节点）
                     ┌─────────┴──────────┐
                ZKFC(NN1)            ZKFC(NN2)     ← 独立健康监控进程
                     │                     │
              ┌──────▼──────┐      ┌──────▼──────┐
              │  Active NN  │      │ Standby NN  │ ← 持续 tail edits，
              └──────┬──────┘      │             │   内存态与 Active 一致，
                     │ 写 edits    │ 定期做 checkpoint
                     ▼             └─────────────┘
        ┌──────────┬──────────┬──────────┐
        │  JN 1    │   JN 2   │   JN 3   │  JournalNode：edits 的多数派日志
        └──────────┴──────────┴──────────┘  （写成功 2/3 才向客户端确认）
```

故障切换的完整过程（NN1 宕机）：ZKFC1 失去 ZK 会话 → 锁节点释放 → ZKFC2 抢到锁 → **先对旧 Active 做 fencing**（默认 sshfence：ssh 上去 kill 进程，防脑裂双写）→ NN2 升为 Active，开始对外服务。

运维要点：

- JournalNode 部署 3 或 5 台（允许各坏 1 或 2 台），通常复用在 NN/ZK 所在机器。
- **fencing 必须配且必须验证**：两个 Active 同时接受写入会撕裂命名空间。sshfence 要求两台 NN 互相免密 ssh；切换演练时故意拔网线验证。
- 手动切换与状态查看：`hdfs haadmin -ns mycluster -getAllServiceState`、`hdfs haadmin -failover nn1 nn2`。自动切换发生后要人工确认根因，不能放着不管。
- 与 12 模块对照：这套"多数派日志 + 选主"和 Kafka KRaft/ISR 的思想一致（`12-data-streaming/kafka/02-replication-and-reliability.md`），差别是 Kafka 把日志和副本数据合在一起，HDFS 把"元数据日志"（JN）与"数据副本"（DN）拆成两套。

## 3. DataNode：心跳、块报告与"死"的判定

| 机制 | 默认 | 说明 |
|---|---|---|
| 心跳 | 每 3 秒（`dfs.heartbeat.interval`） | 向 NN 报告存活；NN 借心跳下发指令（复制/删除/均衡） |
| 全量块报告 | 每 6 小时（`dfs.blockreport.intervalSec`） | DN 把本地所有块清单报给 NN，重建/校验"块 → DN"映射 |
| 增量块报告 | 写入/删除后立即 | 收到新块、删除坏块时即时上报 |
| 判死 | 约 10.5 分钟（2×300s recheck + 10×3s 心跳 = 630s，以官方文档为准） | 超时未心跳 → 标记 Dead → 其上的块进入 under-replicated → 调度其他 DN 补副本 |

三个运维推论：

1. **DN 短暂离线不是故障**（机器重启、网络抖动）。判死要 10 分钟，就是为了避免"抖一下就全集群补副本"的风暴。看到 under-replicated 暴涨先等 DN 回来，多数会自己落回去。
2. **NN 重启后最慢的是等块报告**，而不是回放 edits——"块 → DN"映射只在内存、只靠 DN 报告重建。几千台 DN 的集群要主动分批触发。
3. **下线节点必须走 decommission**（把节点加入 `dfs.hosts.exclude` 后 `hdfs dfsadmin -refreshNodes`）：NN 会先把其上的副本补到别处，完成后才允许它退出。直接关机等于制造一波丢失块风险。

## 4. 块模型：128MB 块、3 副本放置与纠删码

### 4.1 块与副本放置

文件被切成 128MB 的块（`dfs.blocksize`），每块默认 3 副本（`dfs.replication`）。机架感知下的放置策略（`BlockPlacementPolicyDefault`）：

```
写入方是集群节点（Hive/Spark task 所在 DN）   写入方是集群外客户端
  1st 副本：本机                                1st：随机选一个 DN
  2nd 副本：远端机架的随机 DN
  3rd 副本：与 2nd 同机架的另一个 DN
```

三条设计动机：1st 本机省一次网络传输（写吞吐）；2nd 跨机架保证机架级容灾；3rd 回到 2nd 的机架——既不碰第三个机架（省核心交换机带宽），又不在同一台机器上。

**机架感知没配 = 全部节点都在 /default-rack**：放置策略退化为随机，3 副本可能全落在同一机架，单机架断电即丢数据，而且 NN 日志会持续告警拓扑不可用。生产必须配 `net.topology.script.file.name`（一个把 IP 映射成 `/rack1` 的脚本——网络背景的你写这个是降维打击）。已有副本不会因后配脚本自动搬家，需要 `hadoop fs -setrep` 触发重复制或重写数据。

### 4.2 纠删码（EC）与 3 副本的成本对比

Hadoop 3.0 起支持对目录设置 EC 策略，最常用 RS-6-3-1024k：6 个数据单元 + 3 个校验单元，任丢 3 个可重建。

| 维度 | 3 副本 | RS(6,3) 纠删码 |
|---|---|---|
| 存储开销 | 3.0x | 1.5x |
| 丢 1 个块的恢复成本 | 从另一副本复制 1 份（1 倍流量） | 读其余 6 个单元重建（6 倍读流量 + CPU 解码） |
| CPU | 无 | 写入时编码、恢复时解码 |
| 写路径 | 流水线 + hflush 可见 | 不支持 hflush/hsync，追加受限（以官方文档为准） |
| 最少节点数 | 1 台也能写 | 一个块组要摊到 9 台 DN 上 |
| 适用 | 热数据、通用表 | 温冷大文件、归档、日志池 |

算一笔账（100TB 原始数据）：3 副本占 300TB，RS(6,3) 占 150TB——**一半的存储成本**，代价是恢复时的网络与 CPU 放大、以及对实时写路径的限制。所以标准做法是分池：热表走 3 副本，冷目录 `hdfs ec -setPolicy -path /warehouse/cold -policy RS-6-3-1024k`（`hdfs ec -listPolicies` 查看全部策略，参数名以官方文档为准）。

## 5. 读写全路径

### 5.1 写：三台 DN 组成的流水线

```
client ──create()──► NN：登记租约(lease)，文件进入"正在写"，对其他读者不可见
client 把数据切成 packet（每 512B chunk + 4B CRC 校验和）
   └──► DN1 ──► DN2 ──► DN3    流水线逐级转发，client 只发一份
        （ack 沿 DN3 ──► DN2 ──► DN1 原路返回，client 收齐才把 packet 出队）
DN2 掉线：client 从 ack 队列重发，NN 更新副本集，重建新流水线继续写
块写满/close：client 报 NN finalize → 文件对其他客户端可见
```

写路径的运维含义：**带宽消耗在 DN 之间的复制链上，而不只是 client → 集群**；一个客户端写坏网络会表现为整条 pipeline 重试；writer 崩溃后文件的租约要等 NN 回收（软限约 60 秒、硬限约 1 小时，以官方文档为准），期间别的进程无法写这个文件——"文件一直处于 `.tmp`/打不开"先查 lease。

### 5.2 读：就近原则 + 校验和

NN 的 `getBlockLocations` 返回每块的副本列表，client 按距离挑一个：

```
副本选择顺序：① 本机（同节点 DN） ② 同机架 ③ 其他机架随机
每个 512B chunk 读出后校验 CRC：
  校验失败 → 标记坏块上报 NN → 自动换一个副本重读（用户无感）
```

这就是"数据本地性"的来源：YARN 调度（02 章）会把任务尽量派到数据所在节点，读路径退化为本地盘读。排障时"读慢"先分层：是 client 跨机房拉数据（网络），还是副本全在远机架（拓扑脚本错），还是磁盘本身慢（iostat）。

与 Kafka 对照：两者都靠"大块/顺序"摊薄寻址成本（`12-data-streaming/kafka/01-log-model-and-architecture.md` 第 2 节），HDFS 用 128MB 块换元数据规模，Kafka 用 1GB segment 换索引规模。

## 6. 运维核心一：safemode 的语义与进出条件

safemode 是 NN 的只读保护态：接受读请求，**拒绝一切修改**（写、删除、重命名、副本调整）。

| 问题 | 答案 |
|---|---|
| 什么时候进入 | NN 启动加载完 fsimage + 回放 edits 后；或管理员手动 enter |
| 退出条件 | DN 块报告覆盖的块比例 ≥ `dfs.namenode.safemode.threshold-pct`（默认 0.999）并保持 extension 时间（默认 30 秒） |
| 为什么存在 | 元数据里"应有"的块还没被 DN 报告确认，此时若允许写/删/调度复制，会做出错误决策（最典型：误判大量 under-replicated 触发复制风暴） |
| 卡住的典型原因 | DN 没起来/没注册（比例永远到不了）；确实丢了块（分母里的块永远报不上来）；大集群块报告还在路上 |

```bash
# [任意节点] safemode 四连（演练章节会实际执行）
hdfs dfsadmin -safemode get     # 查询：Safe mode is OFF / ON
hdfs dfsadmin -safemode enter   # 手动进入：维护前冻结写入常用
hdfs dfsadmin -safemode leave   # 手动退出：确认 DN 都健康后
hdfs dfsadmin -safemode wait    # 阻塞到退出，发布脚本常用
```

排障顺序：`hdfs dfsadmin -report` 看 Live Nodes 与块报告进度 → NN UI 首页会显示类似 "The reported blocks 0.9950 has reached the threshold 0.999" 的进度 → DN 都在而比例不动，才考虑丢块（下一节）。**手动 leave 的前提是你已确认 DN 全部在线**：强行退出只是让 NN 开始服务，missing blocks 该有还是会有，而且写流量会立刻压上来。

## 7. 运维核心二：丢失块 / 损坏块的处理流程

两类问题的定义：**missing** = 元数据里有这个块、所有副本所在 DN 都不在线（数据可能真没了）；**corrupt** = 副本在但校验和不对（数据坏了）。发现入口有三个：NN UI 首页的 Missing/Corrupt Blocks 计数、Prometheus 告警（第 11 节）、用户报"读文件报 Could not obtain block"。

```bash
# [任意节点] fsck 是唯一的权威诊断入口
hdfs fsck /dw -files -blocks -locations        # 逐文件列块与所在 DN（只读，别怕）
hdfs fsck / -list-corruptfileblocks            # 只列损坏/丢失的文件清单
hdfs dfsadmin -metasave meta.txt               # dump 块队列到 NN 日志目录
#   （pending replication / under-replicated 队列长度都在里面）
```

missing 块的处置 runbook（顺序不能乱）：

```
missing > 0
 ├─ ① 先问"DN 是不是暂时离线"：机器在重启？磁盘被 umount？网络在抖？
 │      → 恢复 DN，块自己回来。绝大多数 missing 属于这类，等 10~30 分钟
 ├─ ② 有没有节点在 decommission / 磁盘在更换？→ 等流程走完
 ├─ ③ 真丢了（fsck -locations 显示所有副本 DN 都已不在线）
 │      ├─ 能重导：从源系统（Kafka 回放 / 业务库 / 备份）重新写入
 │      └─ 接受丢失：先让业务确认这些文件可弃，再二选一：
 │           hdfs fsck /path -delete   删除损坏文件（粒度是整个文件）
 │           hdfs fsck /path -move     挪进 /lost+found 保留现场
 └─ ④ 禁止动作：一见 missing 就 -delete；在 safemode 里做删除决定；
        只贴一张截图进群不放 fsck 清单（无法复盘）
```

corrupt 块通常是**自愈**的：DN 的 VolumeScanner 定期后台扫描（默认周期很长）或读路径校验失败上报 → NN 把该副本标记无效 → 从健康副本重新复制。运维要做的是确认 under-replicated 曲线在回落；持续不落再查那台 DN 的盘（smartctl/dmesg）。

## 8. 运维核心三：Balancer 与数据再平衡

倾斜的三个来源：新节点上线（空的）、节点退役、业务写倾斜（某分区永远写同一批盘）。`hdfs balancer` 的语义：把 DN 利用率与集群均值的差收敛到 threshold 以内。

```bash
# [任意节点] 标准用法：阈值 15%，带宽由 dfs.datanode.balance.bandwidthPerSec 限制
hdfs balancer -threshold 15
# balancer 是 NN 出搬迁建议、DN 之间直传数据；默认每 DN 限速 1MB/s，
# 大集群要一次调到位：临时调大限速（每 DN，运维窗口内）：
hdfs dfsadmin -setBalancerBandwidth 104857600   # 100MB/s，持续生效直到再次调整或 DN 重启，跑完记得调回
```

注意：`-setBalancerBandwidth` 改的是 DN 的搬迁带宽上限，不影响正常读写。balancer 的运维纪律：**错峰跑**（搬迁流量会和业务读抢占磁盘与网卡）、**分批跑**（一次迁移量别超过单日窗口）、跑不完可以断点续跑。节点内部不同磁盘之间的倾斜用另一套工具：`hdfs diskbalancer -plan/-execute`（节点级，不占网络）。EC 数据的搬迁用 `hdfs mover`。

## 9. 小文件：量化危害与治理

**量化**。官方口径：NN 内存里每个文件/目录/块对象约占 150 字节。一个 10KB 的小文件在 NN 里至少是 2 个对象（1 个 inode + 1 个块）+ 3 份副本映射，约 300~500B——元数据是数据本身的 30 倍以上。放大到真实规模：

```
300 张表 × 每天 24 个小时分区文件 × 365 天 ≈ 263 万文件/年（很普通的数仓）
1 亿对象 × 150B ≈ 15GB 纯元数据 → 留堆开销与 GC 余量，NN 堆要 50GB 起步
同样的 1PB 数据：
  用 1GB 的列式大文件 = 100 万个块对象 → 轻松
  用 1MB 小文件      = 10 亿个块对象 → 任何 NN 都撑不住
```

堆只是显性成本，隐性成本更疼：NN GC 停顿（RPC p99 抖动）、DN 全量块报告变慢（6 小时跑不完一轮）、重启重建映射变慢、fsck 跑几小时、MR/Spark 每个 task 打开文件有固定开销（128 个 1MB 文件 = 128 个 task，绝大部分时间在读元数据）。

**治理**（按优先级）：

| 手段 | 做法 | 优点 | 局限 |
|---|---|---|---|
| 入口合并（治本） | 上游按 128MB~1GB 滚动输出：Flink FileSink 的滚动策略、Spark 写前 repartition/coalesce | 不产生小文件 | 要改上游作业（`12-data-streaming/flink` 的 sink 配置） |
| 存量归并 | 对小文件分区 `INSERT OVERWRITE` 重写聚合；ORC 表可用 `ALTER TABLE ... CONCATENATE` | 存量可治 | 占计算资源；Parquet 不支持 concatenate（以 Hive 官方文档为准） |
| HAR 归档 | `hadoop archive -archiveName x.har -p /src /dst`，读路径 har:// 透明 | 冷数据打包，NN 对象数骤降 | 只读、不可追加、对引擎仍有读放大 |
| 容器/列式格式 | 小文件装进 SequenceFile/Avro/Parquet 大容器 | 通用 | 需要下游读代码配合 |

关于 Arrow 的定位要澄清：它不是 HDFS 的功能，而是**内存列式/IPC 标准**——Spark 与 Python 间零序列化传输、Doris/StarRocks 高速导入通道（05 章）。小文件治理的终点是"列式大文件（Parquet）+ 高效内存表示（Arrow）"这条完整链路，而不是单点工具。

## 10. 命令速查表

| 命令 | 用途 | 高频用法 |
|---|---|---|
| `hdfs dfsadmin -report` | 集群容量/节点/块总览 | 巡检第一跳；`-report -live` 只看活节点 |
| `hdfs dfsadmin -safemode` | safemode 管理 | get / enter / leave / wait |
| `hdfs dfsadmin -refreshNodes` | 重载 include/exclude 节点列表 | decommission / 重新上线必用 |
| `hdfs dfsadmin -metasave` | dump 块与队列到 NN 日志目录 | 查 under-replicated/pending 队列 |
| `hdfs dfsadmin -setBalancerBandwidth` | 临时调大搬迁带宽 | balancer 窗口期 |
| `hdfs dfsadmin -finalizeUpgrade` / `-rollingUpgrade` | 升级相关 | 见官方升级文档 |
| `hdfs fsck` | 一致性检查（只读为主） | `-files -blocks -locations`、`-list-corruptfileblocks`、`-delete`、`-move` |
| `hdfs haadmin` | NN HA 管理 | `-getAllServiceState`、`-failover nn1 nn2` |
| `hdfs ec` | EC 策略管理 | `-listPolicies`、`-setPolicy`、`-getPolicy` |
| `hdfs balancer` / `hdfs diskbalancer` / `hdfs mover` | 各级再平衡 | 集群级 / 节点内 / EC |
| `hdfs oev` / `hdfs oiv` | 离线解析 edits / fsimage | 排查"谁在什么时候删了文件"的取证利器 |
| `hadoop fs -setrep` | 改副本数 | 也可以用来触发重复制搬副本 |

## 11. 监控接入口（复用 08-pca 的链路）

Hadoop 各守护进程自带 JMX endpoint：`http://<host>:9870/jmx`（NN）、`http://<host>:9864/jmx`（DN）。用 jmx_exporter（`08-pca/04-instrumentation-exporters.md`）接 Prometheus 后，最小告警集：

| 指标（NN JMX） | 含义 | 告警思路 |
|---|---|---|
| MissingBlocks / CorruptBlocks | 丢失/损坏块数 | > 0 立即 page（先按第 7 节 runbook 判断是否误报） |
| UnderReplicatedBlocks | 副本不足的块 | 持续上涨且不回落 → DN 批量故障/退役 |
| BlocksTotal / FilesTotal | 元数据规模 | 趋势线，做小文件治理的依据 |
| CapacityUsedGB / CapacityTotalGB | 容量水位 | > 80% 触发扩容/清理流程 |
| RpcQueueTimeAvgTime / CallQueueLength | NN RPC 延迟与积压 | NN 过载的最早信号，常先于业务感知 |

## 12. 大数据上 K8s 的现状：HDFS Operator 为什么不是主流

结尾回答一个真实架构问题："我们 K8s 都落地了，HDFS 要不要也 Operator 化？"当前的行业现状是**计算层上 K8s、存储层独立部署**：

- **计算上 K8s 已经成熟**：Spark on K8s、Flink Kubernetes Operator（`12-data-streaming/flink/02-deployment-and-exactly-once.md`），计算无状态，Pod 随便漂。
- **HDFS 上 K8s 没有成为主流**。原因在架构而不在工程：① DataNode 是**带本地盘的有状态服务**，对应 local PV，节点绑定极强（参考 `03-docker/04-storage-volumes.md` 的卷类型对比），K8s 的弹性和调度优势用不上；② 机架拓扑（第 4 节的放置策略依赖）在 K8s 里没有原生对应物，要靠 topology 类标签硬模拟；③ 扩缩容不等于数据可迁移，一个 DN 缩下去背后是数天的 Balancer；④ 社区没有像 Strimzi 那样事实标准的 HDFS Operator。
- **趋势是绕开而不是解决**：存算分离（二代/三代架构）把 HDFS/对象存储留在专用集群或直接用云上 S3/OSS/Ozone，K8s 集群只跑计算。对象存储天然解耦了容量与节点。

SRE 的判断题答案：新建设计选"K8s 计算池 + 独立 HDFS/对象存储"；存量 HDFS 迁移要按"先迁计算、后迁存储、表格式做中间层"三步走。你的 K8s 技能全部有效，但落点在计算层与平台层，不是把 HDFS 装进 Pod。

## 实战演练

环境：00 章创建的 `hadoop-lab` 容器（`docker ps | grep hadoop-lab` 确认在跑；没有就回去执行 00 章第一条命令）。容器里用 `--daemon start` 单进程拉起，等价于生产上 systemd 托管的服务。

```bash
# [任意节点] 1. 写最小可用配置：伪分布（NN+DN 同机），副本数 1（单 DN 只能 1）
docker exec -i hadoop-lab bash -s <<'EOS'
cat > $HADOOP_HOME/etc/hadoop/core-site.xml <<'XML'
<configuration>
  <property><name>fs.defaultFS</name><value>hdfs://localhost:9000</value></property>
</configuration>
XML
cat > $HADOOP_HOME/etc/hadoop/hdfs-site.xml <<'XML'
<configuration>
  <property><name>dfs.replication</name><value>1</value></property>
  <property><name>dfs.namenode.name.dir</name><value>/tmp/hdfs/name</value></property>
  <property><name>dfs.datanode.data.dir</name><value>/tmp/hdfs/data</value></property>
</configuration>
XML
echo done
EOS
# 预期输出：done
```

```bash
# [任意节点] 2. 格式化并启动 NN/DN（只格式化一次！重复格式化会让 DN 报 clusterID 不一致）
docker exec hadoop-lab bash -c \
  'hdfs namenode -format -force -nonInteractive 2>&1 | tail -2 && \
   hdfs --daemon start namenode && hdfs --daemon start datanode && sleep 3 && jps'
# 预期输出：... has been successfully formatted.
#           jps 列表含 NameNode、DataNode（还有 jps 自身）
```

```bash
# [任意节点] 3. 集群视角第一跳：dfsadmin -report
docker exec hadoop-lab hdfs dfsadmin -report
# 预期输出：Configured Capacity 约等于容器可用磁盘；Live datanodes (1)；
#           名字是容器 IP:9866。浏览器开 http://<VM IP>:9870 能看到同款信息
```

```bash
# [任意节点] 4. 看见"块"：写入 300MB，用 fsck 数块与副本位置
docker exec hadoop-lab bash -c \
  'dd if=/dev/zero of=/tmp/big.bin bs=1M count=300 2>/dev/null && \
   hdfs dfs -mkdir -p /user/root && hdfs dfs -put /tmp/big.bin /user/root/'
docker exec hadoop-lab hdfs fsck /user/root/big.bin -files -blocks -locations
# 预期输出（形如）：
#   /user/root/big.bin 314572800 bytes, 3 block(s):  OK
#   0. blk_1073741825 len=134217728 repl=1 [172.17.0.2:9866]
#   1. blk_1073741826 len=134217728 repl=1 [172.17.0.2:9866]
#   2. blk_1073741827 len=46137344  repl=1 [172.17.0.2:9866]
# 300MB ÷ 128MB = 3 块（128+128+44），单 DN 所以 repl=1 且位置都一样
# Status: HEALTHY —— 生产上 repl=3、三个位置分属不同机架，就是第 4 节的放置策略
```

```bash
# [任意节点] 5. 制造小文件灾害现场：200 个小文件 + metasave 看元数据规模
docker exec hadoop-lab bash -c \
  'hdfs dfs -mkdir -p /tmp/small && \
   for i in $(seq 1 200); do echo "payload-$i" | hdfs dfs -put - /tmp/small/f$i.txt; done'
# 约需 1~2 分钟（每个文件一次 RPC 建块），这本身就是小文件代价的现场演示
docker exec hadoop-lab bash -c \
  'hdfs dfsadmin -metasave meta.txt >/dev/null 2>&1; \
   hdfs fsck /tmp/small 2>/dev/null | grep -E "files and|Total files"; \
   grep -c "^blk" $HADOOP_HOME/logs/meta.txt'
# 预期输出：/tmp/small 状态 HEALTHY，200 个文件；meta.txt 中 200+ 个 blk 行
#   200 个 1KB 文件 = 200 个 inode + 200 个块对象 ≈ 6 万字节元数据（第 9 节的量化）
```

```bash
# [任意节点] 6. 治理演示：HAR 把 200 个对象打包成 3~4 个
docker exec hadoop-lab bash -c \
  'hadoop archive -archiveName small.har -p /tmp/small /tmp 2>&1 | tail -1; \
   hdfs dfs -ls /tmp/small.har'
# 预期输出：Found 3~4 items（_index、_masterindex、part-0[、_SUCCESS]）
#   对 NN 而言目录 /tmp/small.har 从 200 个对象变成个位数
docker exec hadoop-lab hdfs dfs -ls 'har:///tmp/small.har/'
# 预期输出：仍能列出 200 个文件——har:// 透明读，下游不用改代码（代价见第 9 节表）
```

```bash
# [任意节点] 7. safemode 手感：冻结写入长什么样
docker exec hadoop-lab bash -c \
  'hdfs dfsadmin -safemode enter && hdfs dfs -touchz /user/root/blocked.txt; \
   hdfs dfsadmin -safemode get; hdfs dfsadmin -safemode leave && \
   hdfs dfs -touchz /user/root/ok.txt && hdfs dfs -ls /user/root'
# 预期输出：touchz 报错 mkdir: Name node is in safe mode（第一条失败、第二条成功）
#           Safe mode is ON → OFF → 目录里出现 big.bin 和 ok.txt
```

验证方法汇总：`fsck` 输出 3 块且 HEALTHY、HAR 目录 items 数为个位数、safemode ON 时写入被拒。容器保留给 02 章用（进程随容器停止而消失，但 `/tmp/hdfs` 里的数据在容器销毁前都在；下次 `docker start hadoop-lab` 后重新执行第 2 步的启动即可，**不要再 format**）。完整练习（判分脚本 + 详解）见 `16-bigdata/labs/01-hdfs-pseudo`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 重启后 NN 卡在 safemode 十几分钟 | edits 太大（checkpoint 失效）或块报告未到 99.9% | 先看 UI 进度条；治理 checkpoint；大集群预留发布窗口 |
| DN 起不来报 Incompatible clusterIDs | NN 重新 format 过，DN 数据目录还带旧 clusterID | 开发环境清空 `/tmp/hdfs/data`；生产禁止随手 format |
| fsck 一片黄，全是 under-replicated | 单/少 DN 环境 replication 仍为 3，或节点刚下线 | 单机实验设 `dfs.replication=1`；生产等 DN 回归或补副本 |
| NN 频繁 Full GC、RPC p99 抖动 | 小文件把堆吃满 | 第 9 节治理；短期加堆只是买时间 |
| 误判"丢数据了"直接 fsck -delete | missing 大概率是 DN 暂时离线 | 严格走第 7 节 runbook，先查 DN 再谈删除 |
| 新加的 DN 上没有数据，磁盘利用率长期 5% | 新节点空盘，没人触发均衡 | 上线即排 Balancer 计划，`-setBalancerBandwidth` 错峰跑 |
| 副本分布全挤在一个机架 | 没配机架感知，全体 /default-rack | 配 `net.topology.script.file.name`；存量数据 setrep 触发重复制 |
| 文件一直写不进去 /lease 相关报错 | writer 崩溃后租约未回收 | 等硬限自动回收，或 `hdfs debug recoverLease -path <file>` |
| `hadoop archive` 卡住不动 | mapreduce 框架配成 yarn 而 RM 没起 | 实验环境保持默认 local，或先起 02 章的 YARN |

## 自测

1. 如果把 NN 元数据改成 RocksDB 落盘而不是全内存，会换到什么、付出什么？为什么社区选择"全内存 + Federation 水平拆分"而不是"落盘"？
<details><summary>答案</summary>

换到"单点内存上限消失"。付出的是：每次写要逐级解析父目录并加锁、每次读要查块位置，这些高频随机访问落到磁盘后延迟从微秒升到毫秒，吞吐随并发锁竞争急剧下降；checkpoint 的"全量快照"结构也不再简单。HDFS 的选择是保住元数据操作的微秒级延迟，容量不够就按路径拆多个 namespace（Federation），让每个 NN 只管一部分目录树。对比：Kafka 的元数据本来就小（分区级），才能整体塞进 KRaft 日志。
</details>

2. 什么情况下 3 副本会全部落在同一机架？如何发现、如何补救？为什么后配机架感知脚本不会自动搬旧副本？
<details><summary>答案</summary>

机架感知脚本未配置或写错（全部返回 /default-rack）时，放置策略退化为随机。发现：`hdfs fsck /path -blocks -locations -racks` 看每块的 rack 分布，NN 日志也有拓扑告警。补救：配好脚本后，对存量数据 `hadoop fs -setrep` 触发重复制（或 distcp 重写），Balancer 只搬数据量不纠正拓扑。不自动搬是因为放置策略只在**写入那一刻**生效，NN 没有"副本位置不合规就迁移"的后台任务——迁移代价（全量数据重写一遍网络）太高。
</details>

3. edits 无限增长会发生什么？针对它的告警应该怎么设计？
<details><summary>答案</summary>

NN 重启时回放时间线性变长，集群长时间停在 safemode；同时磁盘上 edits 文件占用变大。告警设计：监控 `dfs.namenode` JMX 里的事务数/edits 大小与最近一次 checkpoint 距今的事务数差值（如 LastWrittenTxId - MostRecentCheckpointTxId 超阈值告警），以及 Standby NN 存活（HA 下 checkpoint 靠它做，Standby 挂了 edits 就开始堆积）。这也解释了为什么 HA 集群的 Standby 不能当摆设。
</details>

4. 一块物理盘坏了但 DN 进程还活着，HDFS 如何知道？哪些情况会演变成丢失块？
<details><summary>答案</summary>

路径一：DN 检测到卷失败（可容忍 `dfs.datanode.failed.volumes.tolerated` 个），立即用增量块报告把该盘的块标记为失效，NN 调度补副本。路径二：VolumeScanner 后台扫描发现校验和错误。路径三：读请求校验失败上报。演变成丢失块的条件：某块的全部 3 副本所在 DN/盘同时不可用（如同机架故障 + 巧合的另一副本盘坏），或副本数被错误设为 1 再遇 DN 下线——这正是"副本数严禁为 1"和"decommission 必须走完"的原因。
</details>

5. Balancer 默认把每 DN 搬迁带宽限制在 1MB/s 量级，为什么？把它调到 200MB/s 可能引发什么？
<details><summary>答案</summary>

搬迁流量与业务读写共享同一块盘和同一张网卡，限速是为了让均衡对业务"无害"。调到 200MB/s 可能引发：磁盘 util 打满导致业务读延迟飙升、上联/核心交换机带宽被打穿（跨机架搬迁）、NN 侧搬迁指令处理压力增大。正确做法是错峰 + 分批 + 按集群实测带宽阶梯上调，并盯业务的读 P99 是否恶化。这与 Kafka 迁移分区要限流（`12-data-streaming/kafka`）是同一个问题：**数据搬迁永远和可用性抢资源**。
</details>

## 延伸阅读

- HDFS Architecture（官方架构文档，第 1/4/5 节的出处）：https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HdfsDesign.html
- HDFS User Guide（含 fsck/dfsadmin/balancer 命令细节）：https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HdfsUserGuide.html
- NameNode HA with QJM（JournalNode/ZKFC/fencing 官方说明）：https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HDFSHighAvailabilityWithQJM.html
- Erasure Coding（EC 策略与限制）：https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HDFSErasureCoding.html
- HDFS Commands Reference（dfsadmin/fsck/balancer 官方命令页）：https://hadoop.apache.org/docs/stable/hadoop-project-dist/hadoop-hdfs/HDFSCommands.html
