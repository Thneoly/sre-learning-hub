---
title_juejin: 'HDFS 挂十台没事，NameNode 卡一秒全公司停摆'
title_zhihu: '挂十台 DataNode 集群没事，NameNode 卡一秒全公司停摆：HDFS 的元数据账'
description: 'NameNode全内存的快与险：edits+fsimage、JournalNode仲裁与ZKFC切换、心跳判死10.5分钟、3副本放置、纠删码省一半、safemode、fsck、Balancer。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686341072617242662"
---

# HDFS 挂十台没事，NameNode 卡一秒全公司停摆

> （构造典型案例，细节已脱敏虚构）周四下午，一台机架交换机抖了十来分钟，10 台 DataNode 掉线——刚好够到判死线。告警群里只有一条 under-replicated 上涨的曲线，机器自己回来后曲线落回去，业务全程无感。
>
> 两周后的凌晨，同一套集群，NameNode 一次几秒的 GC 停顿：所有写入作业卡在建文件那一步，Hive 任务排队超时，值班被电话叫醒。

挂 10 台没事，卡几秒全公司停摆。原因一句话：HDFS 把整个文件系统的元数据，放在一个进程的一块内存里。

**数据面挂十台是少副本，元数据面停一秒是没文件系统。**这篇把这笔账拆开算：全内存的快与险、HA 的分工、DataNode 的生死判定、块与副本的经济学、读写全路径，最后是 safemode / fsck / Balancer 运维三大件。

行为以 Hadoop 3.3.x 为准，默认值随小版本可能变化，以官方文档为准。

## 一、NameNode：把整个文件系统塞进一块内存

HDFS 是主从架构：NameNode（NN）一主管元数据，DataNode（DN）成百上千管数据块。NN 的内存里有三样东西：

```text
NN 内存命名空间（重启即失，靠 fsimage + edits 恢复）
 ├── inode 树：每个文件/目录一个对象（路径、权限、时间戳）
 ├── 文件 → 块列表：/dw/ods/orders/part-0 → [blk_1, blk_2, ...]
 └── 块 → DN 映射：blk_1 → [dnA, dnF, dnK]   ← 由 DN 块报告构建，不落盘
```

为什么必须全内存：每次写要逐级解析父目录路径并加锁，每次读要按块查位置，全是高频随机访问；放磁盘（B+ 树/LSM）意味着每个操作多几次磁盘随机 IO，延迟从微秒级掉到毫秒级。

持久化是一套标准的 WAL + 快照，与 Redis 的 AOF + RDB 完全同构：

| 机制 | 是什么 | 关键点 |
| --- | --- | --- |
| edits | 变更日志（WAL），mkdir/put/rename 先写它 | 只追加、顺序写，重启回放 |
| fsimage | 命名空间完整快照 | 体积大，不能频繁生成 |
| checkpoint | fsimage + 之后的 edits 合并成新 fsimage | HA 下由 Standby 做；非 HA 由 2NN 做 |

```text
客户端 put/mkdir/rename ──①先追加──► edits_inprogress（保证可回放）
                                        │
        ②Standby NN 定期拉取全部 edits   │（HA：checkpoint 的执行者）
                                        ▼
        fsimage_120 + edits(121..123) ──合并──► fsimage_123 回传 Active
```

checkpoint 默认每 1 小时或累计 100 万事务触发一次（dfs.namenode.checkpoint.period / dfs.namenode.checkpoint.txns）。

运维必须盯住一件事：checkpoint 失效会让 edits 无限增长，NN 重启要先回放几千万条 edits，集群在 safemode 里卡几十分钟——这是「重启窗口比预期长一倍」的头号原因。

全内存换来微秒级的快，也留下两条命门，大集群的运维问题多半源头在这：

1. **元数据规模 = 堆规模**。官方口径每个文件/目录/块对象约占 150 字节：1 亿对象约 15GB 纯元数据，留堆开销与 GC 余量，NN 堆要 50GB 起步；1PB 用 1MB 小文件存是 10 亿个块对象，任何 NN 都撑不住。
2. **重启要重建「块 → DN」映射**。它只在内存、只靠 DN 块报告重建——几千台 DN 的集群，NN 重启最慢的不是回放 edits，是等块报告。

那内存撑到头怎么办？社区的答案不是把元数据落盘，是 Federation：按路径把目录树拆给多个 NN，每个只管一部分——微秒级的元数据操作延迟，就是靠这套水平拆分保住的。

**元数据全内存，整条可用性曲线都拴在这块堆上。**

## 二、HA：JournalNode 管仲裁，ZKFC 管切换

单点 NN 一重启全公司停摆，所以生产一律 HA：

```text
                ZooKeeper（/hadoop-ha/${ns} 临时锁节点）
                 ┌────────┴────────┐
             ZKFC(NN1)         ZKFC(NN2)    ← 独立健康监控进程
                 │                 │
          ┌──────▼──────┐   ┌──────▼──────┐
          │  Active NN  │   │ Standby NN  │ ← 持续 tail edits，定期 checkpoint
          └──────┬──────┘   └─────────────┘
                 │ 写 edits
                 ▼
        ┌────────┬────────┬────────┐
        │  JN 1  │  JN 2  │  JN 3  │   写成功 2/3 才向客户端确认
        └────────┴────────┴────────┘
```

分工其实很清楚：

- JournalNode 是 edits 的多数派日志。部署 3 或 5 台（各允许坏 1 或 2 台，通常复用 NN/ZK 所在机器），Active 写 edits 要 2/3 确认才算成功——保的是「已确认的写不丢」。
- ZKFC 是独立的健康监控进程，靠 ZooKeeper 临时锁节点选主。NN1 宕机的完整切换：ZKFC1 失去 ZK 会话 → 锁节点释放 → ZKFC2 抢到锁 → **先对旧 Active 做 fencing** → NN2 升为 Active 对外服务。

**fencing 必须配且必须验证**：两个 Active 同时接受写入，会把命名空间撕成两半。通行的选择是 sshfence（ssh 上去 kill 进程）——它不是开箱默认，要在 dfs.ha.fencing.methods 里显式配置，且要求两台 NN 互相免密 ssh；切换演练时要故意拔一次网线验证它真的拦得住。

```bash
hdfs haadmin -ns mycluster -getAllServiceState   # 查两台 NN 的 active/standby 状态
hdfs haadmin -failover nn1 nn2                   # 手动切换；自动切换后要人工确认根因
```

一个容易被当摆设的角色：Standby。HA 下 checkpoint 靠它做，它挂了 edits 就开始堆积——所以告警要盯 NN JMX 里 LastWrittenTxId 与 MostRecentCheckpointTxId 的差值，而不是只盯 Active。

顺带一句：这套「多数派日志 + 租约选主」和 etcd 撑起 K8s 控制面是同一道数学题，Raft 的账此前那篇《etcd 不只是数据库：K8s 控制面的命脉》拆过，这里不重算。

和 Kafka KRaft 的差别也一句话说清：Kafka 把元数据日志和副本数据合在一起，HDFS 把「元数据日志」（JN）与「数据副本」（DN）拆成两套。

**JN 保不丢、ZKFC 保快切、fencing 保不脑裂**——三缺一，HA 就是摆设。

## 三、DataNode：3 秒心跳，10.5 分钟判死

| 机制 | 默认 | 说明 |
| --- | --- | --- |
| 心跳 | 每 3 秒（dfs.heartbeat.interval） | 报存活；NN 借心跳下发复制/删除/均衡指令 |
| 全量块报告 | 每 6 小时（dfs.blockreport.intervalSec） | DN 报本地全部块清单，重建/校验「块 → DN」映射 |
| 增量块报告 | 写删后立即 | 收到新块、删除坏块时即时上报 |
| 判死 | 约 10.5 分钟 | 2×300s recheck + 10×3s 心跳 = 630s |

判死之后：标记 Dead → 其上的块进 under-replicated 队列 → 调度其他 DN 补副本。

判死要 10 分钟不是迟钝，是防「网络抖一下就全集群补副本」的风暴。由此三个推论：

1. DN 短暂离线不是故障。看到 under-replicated 暴涨先等 10~30 分钟，多数会自己落回去。
2. NN 重启后最慢的是等块报告，不是回放 edits；几千台 DN 的集群要主动分批触发。
3. 下线节点必须走 decommission：加入 dfs.hosts.exclude 后执行 hdfs dfsadmin -refreshNodes，NN 先把副本补到别处才放它走。直接关机等于自己制造一波丢失块风险。

**挂十台 DN 集群没事**，靠的是 3 副本摊薄加 10 分钟判死的缓冲。

## 四、块模型：128MB、3 副本放哪、纠删码省一半

文件被切成 128MB 的块（dfs.blocksize），每块默认 3 副本（dfs.replication）。块为什么这么大：和 Kafka 用 1GB segment 是同一个动机——用大块/顺序摊薄寻址成本，HDFS 用 128MB 换元数据规模。机架感知下的放置策略：

| 副本 | 写入方是集群节点 | 写入方是集群外客户端 |
| --- | --- | --- |
| 1st | 本机 | 随机选一个 DN |
| 2nd | 远端机架的随机 DN | 同左 |
| 3rd | 与 2nd 同机架的另一个 DN | 同左 |

三条设计动机：1st 本机省一次网络传输（写吞吐）；2nd 跨机架保证机架级容灾；3rd 回到 2nd 的机架——不碰第三个机架（省核心交换机带宽），又不在同一台机器上。

**机架感知没配 = 全部节点都在 /default-rack**：放置退化为随机，3 副本可能全落同一机架，单机架断电即丢数据。

生产必须配 net.topology.script.file.name（把 IP 映射成 /rack1 的脚本）；注意存量副本不会因后配脚本自动搬家，要 hadoop fs -setrep 触发重复制。

纠删码（EC）是另一半账。最常用 RS-6-3-1024k：6 个数据单元 + 3 个校验单元，任丢 3 个可重建。

| 维度 | 3 副本 | RS(6,3) 纠删码 |
| --- | --- | --- |
| 存储开销 | 3.0x | 1.5x |
| 丢 1 块的恢复 | 从另一副本复制，1 倍流量 | 读其余 6 单元重建，6 倍读 + CPU 解码 |
| 实时写 | 流水线 + hflush 可见 | 不支持 hflush/hsync，追加受限 |
| 最少节点 | 1 台也能写 | 一个块组要摊 9 台 DN |

算一笔账：100TB 原始数据，3 副本占 300TB，RS(6,3) 占 150TB——一半的存储成本。标准做法是分池：热表走 3 副本，冷目录、归档、日志池上 EC。

```bash
hdfs ec -setPolicy -path /warehouse/cold -policy RS-6-3-1024k   # 冷目录省一半盘
hdfs ec -listPolicies                                           # 查看全部可用策略
```

**EC 省的一半存储，是用 6 倍流量和 CPU 换的。**

## 五、读写全路径：一张图

```text
写路径
client ──create()──► NN：登记租约(lease)，文件进入"正在写"，对其他读者不可见
client 把数据切成 packet（每 512B chunk + 4B CRC 校验和）
   └──► DN1 ──► DN2 ──► DN3    流水线逐级转发，client 只发一份
        ack 沿 DN3 ──► DN2 ──► DN1 原路返回，收齐才把 packet 出队
DN 掉线：client 从 ack 队列重发，NN 更新副本集，重建新流水线继续写
块写满 / close：报 NN finalize → 文件对其他客户端可见

读路径
client ──► NN.getBlockLocations 拿到每块副本列表，按距离挑一个：
   ① 本机（同节点 DN） ② 同机架 ③ 其他机架随机
   每个 512B chunk 读出后校验 CRC：失败 → 标坏块上报 NN → 换副本重读（用户无感）
```

三个排障含义：

- 写的带宽消耗在 DN 之间的复制链上，不只是 client → 集群；一个客户端网络差，表现为整条 pipeline 重试。
- writer 崩溃后租约要等 NN 回收（软限约 60 秒、硬限约 1 小时），期间别的进程写不了这个文件。「文件一直 .tmp / 打不开」先查 lease，可手动 `hdfs debug recoverLease -path <文件>`。
- 读慢先分层：client 跨机房拉数据是网络问题，副本全在远机架是拓扑脚本错了，单盘慢看 iostat。数据本地性也来自这条路径——YARN 把任务尽量派到数据所在节点，读退化成本地盘读。

**写不动查租约，读得慢先分层。**这张图还有一个推论值得记住：NN 只管目录和位置，数据从不经过它。

## 六、运维三大件之一：safemode 的语义与进出

safemode 是 NN 的只读保护态：接受读请求，拒绝一切修改（写、删除、重命名、副本调整）。

进：NN 启动加载完 fsimage、回放完 edits 之后；或管理员手动 enter。出：DN 块报告覆盖的块比例 ≥ 0.999（dfs.namenode.safemode.threshold-pct），并保持 30 秒。

它为什么存在：元数据里「应有」的块还没被 DN 报告确认，此时允许写删和调度复制，NN 会做出错误决策——最典型是误判大量 under-replicated，触发复制风暴。

卡住的典型原因：DN 没起来/没注册，比例永远到不了；确实丢了块，分母里的块永远报不上来；大集群块报告还在路上。

```bash
hdfs dfsadmin -safemode get     # Safe mode is OFF（或 ON）
hdfs dfsadmin -safemode enter   # 维护前冻结写入，常用
hdfs dfsadmin -safemode leave   # 手动退出的前提：已确认 DN 全部在线
hdfs dfsadmin -safemode wait    # 阻塞到退出，发布脚本常用
```

排障顺序：hdfs dfsadmin -report 看 Live Nodes 与块报告进度 → NN UI 首页有类似 "The reported blocks 0.9950 has reached the threshold 0.999" 的进度提示 → DN 都在而比例不动，才考虑丢块。

**safemode 不是故障，是 NN 在对账。**强行 leave 只是让 NN 开始服务：missing blocks 该有还是会有，写流量还立刻压上来。

## 七、运维三大件之二：fsck 处理丢失块 / 损坏块

先分清定义：missing = 元数据里有这个块、所有副本所在 DN 都不在线（数据可能真没了）；corrupt = 副本在但校验和不对（数据坏了）。发现入口三个：NN UI 的 Missing/Corrupt 计数、监控告警、用户报「Could not obtain block」。

```bash
hdfs fsck /dw -files -blocks -locations   # 逐文件列块与所在 DN（只读，别怕）
hdfs fsck / -list-corruptfileblocks       # 只列损坏/丢失文件清单
hdfs dfsadmin -metasave meta.txt          # 块队列 dump 到 NN 日志目录
```

missing 的处置顺序不能乱：

```text
① 先问「DN 是不是暂时离线」：机器重启？盘被 umount？网络抖？
   → 恢复 DN，块自己回来。绝大多数 missing 属于这类，等 10~30 分钟
② 有没有节点在 decommission / 换盘？→ 等流程走完
③ fsck -locations 确认所有副本 DN 都已不在线 = 真丢了：
     能重导：从源系统（Kafka 回放 / 业务库 / 备份）重新写入
     业务确认可弃后二选一：
       hdfs fsck /path -delete   # 删除损坏文件（粒度是整个文件）
       hdfs fsck /path -move     # 挪进 /lost+found 保留现场
④ 禁止动作：一见 missing 就 -delete；在 safemode 里做删除决定
```

corrupt 通常自愈：VolumeScanner 后台扫描或读校验失败上报 → NN 把该副本标记无效 → 从健康副本重新复制。运维要做的是确认 under-replicated 曲线在回落；持续不落再查那台 DN 的盘（smartctl/dmesg）。

监控侧给一组最小告警集（NN 自带 JMX，接 Prometheus 即可）：MissingBlocks / CorruptBlocks 大于 0 立即 page，先按上面的 runbook 判断是否误报；UnderReplicatedBlocks 持续上涨且不回落，指向 DN 批量故障或退役。

RpcQueueTimeAvgTime 与 CallQueueLength 是 NN 过载的最早信号，常先于业务感知。

**missing 的第一反应是「DN 掉线」**，不是「数据没了」。

## 八、运维三大件之三：Balancer 的阈值与带宽

倾斜的三个来源：新节点上线（空盘）、节点退役、业务写倾斜。Balancer 的语义：把各 DN 利用率与集群均值的差，收敛到 threshold 以内。

```bash
hdfs balancer -threshold 15
hdfs dfsadmin -setBalancerBandwidth 104857600   # 窗口期调到 100MB/s，跑完记得调回
```

balancer 是 NN 出搬迁建议、DN 之间直传数据，默认每 DN 限速 1MB/s；setBalancerBandwidth 改的只是搬迁带宽上限，不影响正常读写。

**搬迁流量和业务流量走同一块盘，限速 1MB/s 是刻意的温柔**——要调大，先确认业务读 P99 扛得住。

纪律三条：错峰跑（搬迁会和业务读抢磁盘网卡）、分批跑（一次迁移量别超单日窗口）、跑不完断点续跑。节点内盘间倾斜用 hdfs diskbalancer，EC 数据搬迁用 hdfs mover。

## 九、30 秒自检

| 问题 | 一句话答案 |
| --- | --- |
| NN 为什么全内存 | 高频随机访问，落盘延迟从微秒变毫秒 |
| 判死要多久 | 约 10.5 分钟（630s），防补副本风暴 |
| safemode 退出条件 | 块报告比例 ≥99.9% 并保持 30 秒 |
| JN 写成功条件 | 3 台里 2 台确认（多数派） |
| 3 副本放置 | 本机 / 远端机架 / 与 2nd 同机架另一台 |
| RS(6,3) 的账 | 1.5x 存储，任丢 3 可重建，恢复 6 倍读流量 |
| missing 第一步 | 先查 DN 是否暂时离线，等 10~30 分钟 |
| Balancer 默认限速 | 每 DN 1MB/s，错峰分批，跑完调回 |

答不出可以补课；**一见 missing 就删的，先收回 fsck 权限。**

## 写在最后

这篇只想留下一句：**全公司的文件系统，押在 NameNode 的一块堆上。**所以 HA 三件套要配齐并演练过，checkpoint 的堆积要有人盯，safemode 卡住时先对账再动手，missing 出现时先怀疑 DN 而不是删数据。

DataNode 给你的是容量和吞吐，NameNode 给你的才是「文件系统还在」。

## 现在就能做的事

- 跑一次 hdfs dfsadmin -report 和 hdfs dfsadmin -safemode get，确认集群此刻不在对账状态
- 查 NN JMX 的 LastWrittenTxId 与 MostRecentCheckpointTxId 差值：持续变大，说明 checkpoint 已经欠账
- 翻出最近一次 HA 切换演练记录——没演练过的 fencing，出事前都是薛定谔的可靠

评论区报三个数：集群多少台 DN、NN 堆多大、最近一次重启在 safemode 里卡了几分钟？卡最久那次，最后查明是 edits 太长，还是块报告没到齐？

这套账的完整版——命令速查表、伪分布动手演练（fsck 数块、safemode 冻结写入、HAR 打包小文件），收在我的学习仓库：GitHub 搜 sre-learning-hub，大数据模块第一章就是。
