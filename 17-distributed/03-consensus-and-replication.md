# 03 · 共识与复制：Quorum、主从复制与 Raft 全流程

> 模块：17-distributed ｜ 建议时长：4 小时 ｜ 关联认证：—（无直接考点；但 etcd 与 K8s 控制面的每一次写都在跑本章内容，是 CKA 集群面排障与终面深水区的理论底座）

## 学习目标

- 能推导 Quorum 数学：为什么 N=3 容 1、N=5 容 2，R+W>N 保证了什么
- 能按 RPO / 写延迟 / 可用性三个维度对比主从复制的同步、异步、半同步三种模式
- 能白板讲清 Raft 选举（任期 / 随机超时 / 拆票）与日志复制（匹配性质 / 提交规则）的全流程
- 能把 Raft 的每个环节映射到 etcd 与 K8s 控制面的具体运维现象（失 quorum 会怎样、慢盘会怎样）
- 能用三句话讲完 Paxos→Raft 的历史，并说出 ZAB 与 Raft 的异同

本章不推导任何证明。每个结论都配两样东西：**语义**（承诺了什么）与**运维后果**（坏了是什么现象、面试该怎么答）。

## 1. 复制是手段，共识是契约

单机数据靠 fsync 挡断电；跨机就必须**复制**——把一份数据放在 N 台机器上。但复制立刻引入新问题：三台机器上的副本什么时候算"一样"？某台机器死了，另外两台谁说了算？**共识协议就是这份契约**：它让 N 台机器对"日志的第 i 条是什么"达成唯一意见，从而对"谁是主、哪些数据已提交"达成唯一意见。

已经学过的系统全是这一个问题的化身：

| 系统 | 共识/复制机制 | 在哪章学的 |
|---|---|---|
| etcd（K8s 控制面） | Raft，多数派提交 | [04-k8s-fundamentals/02-architecture-and-control-loop.md](../04-k8s-fundamentals/02-architecture-and-control-loop.md) §3、[13 章](../04-k8s-fundamentals/13-cluster-admin-and-etcd.md) §2 |
| ZooKeeper | ZAB，过半提交 | [16-bigdata/06-zookeeper.md](../16-bigdata/06-zookeeper.md) §3 |
| Redis 哨兵 | 哨兵间 Raft 思想选举（majority），数据面主从是异步复制 | [11-middleware/redis/02-persistence-and-ha.md](../11-middleware/redis/02-persistence-and-ha.md) §6 |
| MySQL 主从 | 异步复制，半同步是运维折中 | [11-middleware/mysql/02-backup-replication.md](../11-middleware/mysql/02-backup-replication.md) §半同步 |
| Kafka | 分区 leader + ISR（不是共识协议，是"受控的多数派"） | [12-data-streaming/kafka/02-replication-and-reliability.md](../12-data-streaming/kafka/02-replication-and-reliability.md) §3 |
| MongoDB 副本集 | Raft 变种选举 + 多数派写 | [11-middleware/mongodb/02-replicaset-and-sharding.md](../11-middleware/mongodb/02-replicaset-and-sharding.md) |

SRE 视角的一句话总纲：**共识协议用"少数派必须闭嘴"换取"至多一个主"**。它所有的运维代价——奇数成员、写放大、fsync 延迟敏感、失 quorum 宁可不可用——都源自这一条。

## 2. Quorum 与 NWR：一切多数派系统的数学底座

### 2.1 R + W > N

设数据有 N 个副本。一次写要求 W 个副本确认，一次读要求 R 个副本应答。若：

```
R + W > N   ⇒   任何一次读的副本集合，与任何一次写的副本集合，必有交集
          ⇒   读至少能碰到一个"拿到过最新值"的副本（配合版本号取最新）
```

这就是 Dynamo 论文里的 NWR 模型，也是理解所有可调一致性系统的钥匙：

| 组合 | 语义 | 代价 | 已学系统对应 |
|---|---|---|---|
| W=1, R=1 | 写快读快，可能读到旧值 | 故障即丢数据 | MySQL 异步主从（旧值=延迟）、Redis 主从 |
| W=N, R=1 | 读不碰旧值 | 一次全慢、一台故障即写失败 | "全同步复制"，工程上几乎没人用 |
| W=quorum, R=quorum | 强一致读写，容少数派故障 | 每次读写都要过半往返 | etcd / ZK / Mongo 多数派写 |
| W=quorum, R=1 | 写强、读可能旧（最终一致读） | 换读延迟 | Mongo readConcern local 的取舍方向 |

**面试答法**：被问"为什么 etcd 读也要过半确认"时，答案不是 R+W>N 本身，而是它的推论——线性读必须先确认"我还是当前任期 leader"（ReadIndex），否则可能把已卸任的旧主上的旧值当最新值返回。见第 5 节；一致性级别的完整阶梯（线性一致到最终一致）在 [02-consistency-models.md](./02-consistency-models.md)。

### 2.2 N=3 容 1、N=5 容 2：两张账要分开算

多数派 quorum = ⌊N/2⌋ + 1。这里有两件常被混为一谈的事：

```
可用性账：能继续服务的条件 = 存活副本 ≥ quorum
           停掉的副本数 f ≤ N - quorum
持久性账：已提交数据落在 ≥ quorum 个副本上
           全部副本同时损毁才会丢 → 停掉数 ≥ quorum 才可能丢
```

| N | quorum | 可用性容错（N−quorum） | 丢已提交数据需要挂掉 | 运维结论 |
|---|---|---|---|---|
| 1 | 1 | 0 | 1 台 | kubeadm 单 master 默认，勤做 snapshot |
| 2 | 2 | 0 | 2 台 | **最差配置**：容错为 0 还多付一份写延迟 |
| 3 | 2 | **1** | ≥2 台 | 标准起步配置（etcd/ZK/哨兵/Mongo） |
| 4 | 3 | 1 | ≥3 台 | 容错与 3 相同，确认数更多 → 不要用 |
| 5 | 3 | **2** | ≥3 台 | 生产推荐：可停 2 台做滚动维护 |
| 7 | 4 | 3 | ≥4 台 | 大集群，写延迟与网络要求随之上升 |

所以"N=5 容 2"要答成两句：**停 2 台仍可读写（可用性）；要丢已提交数据得同时坏 3 台（持久性）**。另一条必背推论：挂掉台数 = quorum 时（如 5 挂 3），集群**不可写但已提交数据大概率仍在**——恢复任意一台即可救回，这就是"失 quorum 先抢修一台、别急着重建"的理论依据（对应 [05-cka/04-etcd-backup-restore.md](../05-cka/04-etcd-backup-restore.md) 的灾备路径）。

**奇数原则的真正原因**：偶数不增加容错只增加确认成本（4 与 3 容错都是 1），见 [04-k8s-fundamentals/02 章](../04-k8s-fundamentals/02-architecture-and-control-loop.md) §3 的多数派表与 [16-bigdata/06-zookeeper.md](../16-bigdata/06-zookeeper.md) §6.5 的扩容推演。

### 2.3 把已学系统的参数对回 NWR

- **MySQL 半同步** = 把 W 从 1 调到 2（至少 1 个从库 ACK），且超时自动降回 W=1——"尽力而为的 RPO=0"，见 [11-middleware/mysql/02-backup-replication.md](../11-middleware/mysql/02-backup-replication.md) 半同步一节的自测答案。
- **Redis 哨兵** = 数据面 W=1（异步），控制面把"能否切主"交给哨兵 majority（3 哨兵需 2 票），quorum 参数只管客观下线判定——两个概念在 [redis 02 章 §6.2](../11-middleware/redis/02-persistence-and-ha.md) 有原文辨析。
- **Kafka** = `acks=all + min.insync.replicas=2` 手工拼一个"准 quorum"：ISR 收缩到阈值以下直接拒绝写（NotEnoughReplicasException），见 [kafka 02 章](../12-data-streaming/kafka/02-replication-and-reliability.md) §5 的组合矩阵。它没有选主共识，靠 controller/KRaft 补这一块。

## 3. 主从复制的三种模式

共识协议内部也是主从复制，只是把"确认几个副本才算成"写死了。三种模式按 W 排开：

```
同步 (W=N)：    c → L 持久化 ──► 等全部 F 确认 ─────────────► 应答 c
半同步 (W=2)：  c → L 持久化 ──► 等 ≥1 个 F 确认(超时降级) ──► 应答 c
异步 (W=1)：    c → L 持久化 ──────────────────────────────► 应答 c
                                          （binlog 事后发给 F）
```

| 维度 | 同步 | 半同步 | 异步 |
|---|---|---|---|
| RPO（丢多少） | 0 | ≈0（超时降级窗口内可丢） | 主库未发出的 binlog 全丢 |
| 写延迟 | 最高（木桶效应，最慢从库拖垮一切） | 中（等一个最快的 ACK） | 最低 |
| 可用性 | 任意一台故障即不可写 | 从库全挂时降级保可用 | 主库挂之前都可用 |
| 运维特征 | 几乎无生产部署 | MySQL 线上常见 | Redis / MySQL 默认 |

**半同步为什么是运维甜点位**：它承认"绝对不丢"与"绝对可用"不可兼得，把降级做成显式参数（`rpl_semi_sync_master_timeout` 默认 10s，超时自动退回异步——先可用后一致，且降级要被监控到）。排障时盯 `Rpl_semi_sync_master_status` 突变为 OFF，就是"从库慢到降级"的信号，完整参数与降级语义见 [mysql 02 章](../11-middleware/mysql/02-backup-replication.md) 半同步复制一节。

同步复制在生产罕见的原因值得会讲：W=N 时最慢的从库决定整体写延迟（长尾放大），且任何一台从库故障都让主库不可写——为了 RPO=0 把可用性赔进去，通常不划算。要真·RPO=0 且容错，走的是多数派共识（MySQL Group Replication / etcd），那是第 4 节的事。

## 4. Raft 全流程

Raft 把共识拆成三个相对独立的子问题：**_leader 选举、日志复制、安全性_**。前两个决定"怎么运转"，第三个是一组不变量（选举安全、leader 只追加、日志匹配、leader 完整性、状态机安全），运维只需要记住不变量的表现，不需要证明。

### 4.1 角色、任期与心跳

```
           心跳/AppendEntries                 超时未收到心跳
 Follower ────────────维持──────────► Follower ────────────► 变 Candidate，发起选举
    ▲                                                   │
    │              发现更高任期，立即退位回 Follower          │ 赢得过半选票
    └───────────────────────────────────────────────────▼
                                                      Leader
```

**任期（term）是逻辑时钟**：单调递增的整数，每次选举 +1。每条日志都盖着"写入它时的 term"。比较任何两份状态，先比任期再比别的——这一个字段同时实现了"朝代更替"与"旧主作废"。etcdctl 里看到的 `RAFT TERM` 列就是它，选举发生 = term 跳变。

### 4.2 选举：随机超时与拆票

每个 follower 有一个**随机化**的选举超时（etcd 默认 `--election-timeout=1s`，心跳间隔 `--heartbeat-interval=100ms`）。"超时"在这里的语义是"不知道对方死活"而不是"对方死了"（[00-distributed-overview.md](./00-distributed-overview.md) §1.1 的超时三态），选举超时就是这个"不知道"的量化刻度。流程：

1. follower 在 election timeout 内没收到 leader 心跳 → 自增 term、投自己、发 RequestVote 给所有节点；
2. 收到过半选票 → 当选 leader，立刻广播心跳抑制新的选举；
3. 任一节点看到更高 term 的消息 → 无条件退位为 follower。

**投票规则是安全性的关键**：每个节点在任一任期内只能投一票（vote 持久化在 WAL），且候选人日志必须"至少和我一样新"才投——保证当选者拥有全部已提交日志（leader 完整性），数据落后的节点永远选不上。这与 ZAB 的 `epoch > zxid > myid` 优先级同构：zxid 大者优先就是"数据最全者优先"，[16-bigdata/06-zookeeper.md](../16-bigdata/06-zookeeper.md) §3 有对照表。

**拆票（split vote）**：两个 follower 同时超时、同时竞选，选票互相瓜分，谁都拿不到过半 → 本任期无主 → 各自等下一个随机超时重来。随机化超时就是为了让"下次别再撞车"。运维含义：选举耗时本身有抖动，一次切换 1~3 秒正常；但如果**反复**出现拆票/切换，说明超时基数配得太小或磁盘 fsync 慢（心跳写 WAL 都来不及），对应 ZK 章讲的"脑旋"治理（独立低延迟盘、控 GC、对 Mode 变化告警）。

**两个必考推论**：
- 3 成员挂 1 台，剩余 2 台凑成 quorum，1~3 秒内自动选出新主（见上节"一次切换 1~3 秒正常"，lab 01 实测同量级）——这是"自愈"；5 成员挂 3 台，谁也凑不够 3 票，集群**宁可无主不可双主**。
- 旧 leader 从长 GC / 分区中恢复后，收到新 leader 的更高 term 心跳，立即降级为 follower——它"复活抢位"在协议层被 term 直接否决。

### 4.3 日志复制：匹配性质与提交规则

```
client ──PUT──► Leader: 追加日志条目 (term=5, index=12)，先 fsync WAL（未提交）
                   │  并行 AppendEntries{ term=5, prevLogIndex=11, prevLogTerm=4, entry }
                   ├──────────────► F1: 查 11 号条目 term 是否 =4
                   └──────────────► F2: 匹配 → 追加 + 落盘 → ACK
                过半持久化（含 leader 自身）→ 标记 index=12 已提交 → apply 到状态机
                → 应答客户端；后续心跳捎带 commitIndex，follower 随后 apply
```

两条性质，不证明只讲后果：

- **日志匹配**：AppendEntries 携带前一条的 (prevLogIndex, prevLogTerm)，follower 校验不一致就拒绝。归纳起来就是"若两份日志在某 index 的 term 相同，则该 index 之前全部相同"。**运维后果**：follower 中间缺一段（日志空洞，典型于旧 leader 崩溃时未复制完）不需要特殊修复——leader 为每个 follower 维护 nextIndex，被拒绝就回退一格重试，直到找到分界点，把缺失段落整段补发。这就是"follower 落后太多会自动追"的机制本尊。
- **提交规则（图 8 的坑）**：leader 只能通过"复制过半"直接提交**当前任期**的条目；**旧任期的条目不能靠数副本数提交**，只能随新任期条目一起被间接提交。因此 Raft 论文规定新 leader 上任先追加一条**空操作（no-op）条目**并尽快提交它——把前任期遗留的所有条目一次性"带过线"。etcd 新 leader 上任后的首次写延迟略高，原因之一就在这。

**提交 ≠ 应答**：客户端拿到成功 = 该条目已持久化在过半成员且已 apply。这也是 [04-k8s-fundamentals/13 章](../04-k8s-fundamentals/13-cluster-admin-and-etcd.md) §2.1 写路径图的第 ④⑤ 步，那里有逐箭头注释，本章不复述。

**成员变更与快照各一句话**：成员变更一次只加/删一个成员（etcd `member add/remove`，通用解法 joint consensus 被工业实现普遍简化为单成员变更），否则可能同时出现两个互不相交的多数派；快照 = 把 lastApplied 之前的日志压缩成一个状态文件，落后太多的 follower 改用 InstallSnapshot 整体追赶（etcd 的 compact/defrag 是运维侧的对应动作，见 [13 章常用坑](../04-k8s-fundamentals/13-cluster-admin-and-etcd.md)）。

## 5. 映射 etcd 与 K8s 控制面

把第 4 节逐条钉到 K8s：

| Raft 环节 | etcd/K8s 表现 | 运维现象 |
|---|---|---|
| 只有 leader 接受写 | **kube-apiserver 的每次写都要过半 etcd**：认证→准入→验证后，apiserver 把对象写入 etcd，等 RAFT 提交成功才返回 201（处理链见 [02 章 §2](../04-k8s-fundamentals/02-architecture-and-control-loop.md) 的架构图与请求处理链） | kubectl create 的尾延迟里有 etcd quorum 往返 |
| 失 quorum 拒写 | etcd 不可用后 apiserver 无法持久化任何变更，**写全挂；读大部分仍通**（apiserver 有 watch cache） | "kubectl get 正常、apply 超时"是典型指纹 |
| WAL fsync 决定心跳 | etcd 与日志盘共享磁盘时 fsync 抖 → 心跳超时 → 选举 | 控制面无故障但 component 状态反复跳变，先看盘 |
| term / revision | term 见 `endpoint status`；对象版本是 MVCC revision（= resourceVersion） | 排障时分清这两个"版本号" |
| 线性读走 ReadIndex | etcd 默认 linearizable 读要先确认 leadership | 串行读（`--consistency=s`）省一次往返，可能读到旧值 |

写路径完整图（apiserver→etcd leader→WAL→并行 AppendEntries→过半→commit→apply→应答）在 [04-k8s-fundamentals/13-cluster-admin-and-etcd.md](../04-k8s-fundamentals/13-cluster-admin-and-etcd.md) §2.1 已画过，本章第 07 章排障时直接引用它当"地图"。

两条容易被问的边界：

- **单成员 etcd（kubeadm 默认）里 Raft 还有意义吗？** 有：WAL 先落盘、quorum=1 自己确认即提交、全局单调 revision 照常。失去的是容错而非一致性保证——所以单 master 更要勤 snapshot（[13 章自测](../04-k8s-fundamentals/13-cluster-admin-and-etcd.md) 有原文）。
- **为什么 K8s 不把 Pod 数据也放 etcd？** 共识协议的每次写都有过半 fsync + 网络往返，适合"低频、小对象、强一致"的元数据，不适合大体量数据面。同一逻辑在 [16-bigdata/06-zookeeper.md](../16-bigdata/06-zookeeper.md) §1 的"协调服务不是存储服务"表里讲得更透。

## 6. Paxos 一句话史与"为什么大家都用 Raft"

Paxos（Lamport，1990 年报告、1998 年正式发表）证明了共识可解，但论文以故事体写就、极难读懂，2001 年作者自己补了《Paxos Made Simple》；工业界真正能跑的多是工程魔改版的 MultiPaxos（Google Chubby，2006）——**正确性靠论文、工程细节各自补**，每个实现都对协议做了未成文的改动。2014 年 Ongaro 的 Raft 论文标题就是答案：《In Search of an Understandable Consensus Algorithm》——**把可理解性当一等设计目标**：强 leader、任期、日志连续、子问题正交分解，正确性论证普通人能看懂，实现不容易跑偏。etcd 是它最早的工业级采纳者之一，此后 Consul（内嵌 Raft）、CockroachDB/TiKV（Raft 复制）、ClickHouse Keeper、Kafka KRaft（元数据本身就是一条 Raft 日志，见 [16-bigdata/06-zookeeper.md](../16-bigdata/06-zookeeper.md) §5）接连跟进。

**面试答法**：不是"Raft 比 Paxos 更优"（两者容错与性能同量级），而是"Raft 用可理解性换了工程正确率——协议易懂，实现就少踩坑，才有了生态"。

## 7. ZAB 与 Raft：异同

ZAB（ZooKeeper Atomic Broadcast）与 Raft 是同一思想的两个方言：leader 把写请求排成全序日志，过半持久化才提交，任期（epoch / term）单调递增否定旧朝。[16-bigdata/06-zookeeper.md](../16-bigdata/06-zookeeper.md) §3 末尾有逐行对照表（任期、日志、提交序号、提交条件、读旧数据、成员变更六行），值得对着背。本模块补三条**运维差异**：

| 维度 | ZAB（ZK） | Raft（etcd） |
|---|---|---|
| 提交的显式性 | leader 显式广播 COMMIT 消息，follower 收到才 apply | 过半复制即提交，commitIndex 随心跳捎带（隐式） |
| 成员变更 | 静态 zoo.cfg，扩容逐台重启（[06 章 §6.5](../16-bigdata/06-zookeeper.md) 五条原因） | 在线 member add/remove，新成员可先以 learner 加入 |
| 日志回收 | 快照 + 事务日志，运维手动/半自动管理 | compact + defrag，有 backend 配额与 NOSPACE 告警 |

一句话总结：**学会 Raft 的 mental model，ZAB、Mongo 选举、KRaft 都是换词汇表**；反过来，ZK 章的脑裂防护推导（"同一 epoch 内过半互斥 ⇒ 至多一个能提交的 Leader"）同样适用于 etcd。

## 实战演练

环境：装有 Docker 的 Ubuntu VM。用三个容器搭一个真 Raft 集群，把选举、quorum 丢失、日志复制全部亲测一遍。命令标注 `[任意节点]`。

```bash
# [任意节点] 起 3 成员 etcd（同一 docker 网络，版本以官方发布为准）
docker network create etcdnet
for i in 1 2 3; do
  docker run -d --name etcd$i --network etcdnet \
    gcr.io/etcd-development/etcd:v3.5.16 \
    etcd --name etcd$i --data-dir /etcd-data \
    --listen-client-urls http://0.0.0.0:2379 --advertise-client-urls http://etcd$i:2379 \
    --listen-peer-urls http://0.0.0.0:2380 --initial-advertise-peer-urls http://etcd$i:2380 \
    --initial-cluster etcd1=http://etcd1:2380,etcd2=http://etcd2:2380,etcd3=http://etcd3:2380 \
    --initial-cluster-token demo-raft --initial-cluster-state new
done
sleep 5
# 预期：三容器 Up；日志里完成选举，恰好一个 leader

# [任意节点] 定义助手：三成员状态表（ENDPOINT/IS LEADER/RAFT TERM 三列最有信息量）
E3="etcdctl --endpoints=http://etcd1:2379,http://etcd2:2379,http://etcd3:2379"
docker exec etcd1 $E3 endpoint status -w table
# 预期：三行；IS LEADER 只有一个 true；RAFT TERM 三行相同（这是"朝代一致"的直观证据）
```

```bash
# [任意节点] 演练 1：日志复制与提交号前进
docker exec etcd1 $E3 put /svc/owner "pod-1"
docker exec etcd1 $E3 put /svc/owner "pod-2"
docker exec etcd1 $E3 endpoint status -w table | awk 'NR>1{print $1, "leader="$5, "term="$7, "idx="$8}'
# 预期：RAFT INDEX 同步 +2——一次 put = 一条日志，三成员最终一致
docker exec etcd1 $E3 get /svc/owner
# 预期：pod-2（写己之写成立：过半提交后立即可读）

# [任意节点] 演练 2：quorum 丢失——停 2 台，写直接被拒
docker pause etcd2 etcd3
time docker exec etcd1 etcdctl --endpoints=http://etcd1:2379 put /svc/owner "pod-3"
# 预期：约 5s 后报错 context deadline exceeded（etcdctl 默认 --command-timeout=5s）——1/3 凑不齐 quorum=2，
#       宁可拒写不可双写（对照第 2.2 节持久性账：已提交数据没丢，恢复即可救回）
docker exec etcd1 etcdctl --endpoints=http://etcd1:2379 get /svc/owner --consistency=s
# 预期：仍能读到 pod-2（串行读走本成员 KV 不经 quorum——etcd 单成员读旧值风险的雏形；
#       去掉 --consistency=s 用默认线性读则同样约 5s 超时，对照 lab 01 第 7 步）
docker unpause etcd2 etcd3
```

```bash
# [任意节点] 演练 3：选举计时与旧 Leader 复活
# 先从状态表确认谁是 leader（假设 etcd2），用 pause 模拟"心跳停止但进程还在"
date +%T.%3N; docker pause etcd2
# 每 0.5s 打一次存活成员的 leader/term（exec 只能进未暂停的容器！）
for i in $(seq 12); do
  date +%T.%3N
  docker exec etcd1 etcdctl \
    --endpoints=http://etcd1:2379,http://etcd3:2379 \
    endpoint status -w table --command-timeout=1s 2>/dev/null | awk 'NR>1{print $1,"leader="$5,"term="$7}'
  sleep 0.5
done
# 预期：term 从 T 跳到 T+1（选举发生的铁证），约 1~2s 后 etcd1/etcd3 之一成为新 leader

docker unpause etcd2
docker exec etcd1 $E3 endpoint status -w table
# 预期：etcd2 回来后是 follower 且 term 与大家一致——旧 Leader 复活被更高任期压制，
#       这就是第 4.2 节"无条件退位"的现场版

# [任意节点] 清理
docker rm -f etcd1 etcd2 etcd3 && docker network rm etcdnet
```

验证方法：三个演练分别对应"提交号前进""quorum 拒写""term 跳变 + 旧主降级"。把演练 2、3 的耗时记下来，就是 ROADMAP 里"etcd kill-leader 亲测选举耗时"的作业成果。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| kubectl get 正常但 create/apply 全超时 | etcd 失 quorum（apiserver watch cache 还能应答读） | 先救 quorum（恢复任一成员），别急重建；数据大概率还在（第 2.2 节持久性账） |
| 控制面频繁切主、component 状态反复跳变 | 磁盘慢 → WAL fsync 超时 → 心跳/选举超时（脑旋） | etcd 独占低延迟盘；调大 election-timeout；对 leader 变化告警 |
| 5 成员挂 3 台后有人想"把剩下 2 台组成新集群继续写" | 多数派两侧各自重组 = 人为制造双写 | 拒绝；按 snapshot + 现存成员恢复原拓扑（[05-cka/04-etcd-backup-restore.md](../05-cka/04-etcd-backup-restore.md)） |
| 面试答"5 节点容 2 台所以挂 2 台也没风险" | 混淆可用性容错与持久性边界 | 分两句话答：挂 2 可用；挂 3 不可写但数据未必丢 |
| 加了第 4 个成员觉得"更稳" | N=4 容错与 N=3 相同，确认成本反而更高 | 奇数原则：扩容走 3→5，跳过 4（同 [16-bigdata/06 章 §6.5](../16-bigdata/06-zookeeper.md)） |
| 半同步开着仍丢数据 | 从库慢 → timeout 到期自动降级异步 | 监控降级状态量，降级即告警；治从库延迟而不是调大超时（[mysql 02 章常见坑](../11-middleware/mysql/02-backup-replication.md)） |

## 自测

1. Redis 哨兵的 quorum 和 majority 为什么是两回事？把 5 个哨兵配 quorum=2 会出现什么怪事？
<details><summary>答案</summary>

quorum 只用于"客观下线"判定（多少哨兵认为主挂了），而 leader 选举与 failover 授权需要的是 majority（哨兵总数的过半）。5 哨兵 quorum=2 时：2 个哨兵就能宣布 ODOWN，但要动手切换仍需 3 票授权——quorum 调低只是让"判定"更敏感，"行动"的门槛没变。反过来 2 个哨兵挂 1 个，永远凑不出 majority，failover 永远不会发生，所以哨兵必须 ≥3 且奇数。数据结构上这就是"检测阈值"与"决策 quorum"分离的设计，见 [redis 02 章 §6.2](../11-middleware/redis/02-persistence-and-ha.md)。
</details>

2. 为什么 Raft 不允许"一次同时加两个成员"？（提示：把 3 成员扩到 5 成员的中间态画出来）
<details><summary>答案</summary>

若旧配置 3 成员（quorum=2）与新配置 5 成员（quorum=3）同时生效且各节点视图不一致，可能出现两个互不相交的多数派：旧配置侧 2 台自己凑成 quorum 选出一个 leader，新配置侧 3 台也凑成 quorum 选出另一个——两个任期内各有一个"合法" leader，双主。单成员变更保证任意时刻"旧多数派"与"新多数派"必然相交（3 的过半 2 与 4 的过半 3 交集至少 1），交集中的节点不可能投两次票。ZK 用"逐台重启 + 一次一台"在运维层面达成同样约束（[16-bigdata/06 章 §6.5](../16-bigdata/06-zookeeper.md)）。
</details>

3. follower 上出现日志空洞（中间缺 3 条），需要人工修复吗？机制是什么？
<details><summary>答案</summary>

不需要。日志匹配性质保证：leader 发 AppendEntries 时带 (prevLogIndex, prevLogTerm)，follower 校验不匹配就拒绝，leader 的 nextIndex 回退，直到找到双方一致的分界点，然后把分界点之后的整段日志重发覆盖。整个补洞由协议自驱，运维要做的只是保证网络与磁盘别再添乱（以及别让 follower 落后到超出日志保留范围——那会走 InstallSnapshot 整体追赶，对应 etcd 的 compact 之后"旧 revision 不可再读"的运维约束）。
</details>

4. 为什么 Raft 新 leader 上任后要先提交一条 no-op 空条目？不提交会怎样？
<details><summary>答案</summary>

提交规则只允许"当前任期的条目靠过半复制直接提交"，前任期的条目即使已复制到过半也不能据此推进 commitIndex（Raft 论文图 8 的反例：旧任期条目在后续选举中可能被覆盖）。新 leader 若不写新条目，前任期那些"实际已安全"的日志就迟迟无法提交、状态机无法 apply。追加一条 no-op 并提交它，能把前任期全部条目"带过线"，缩短切换后的不可见窗口。运维表现：刚切完主的 etcd，第一笔写延迟略高是正常的。
</details>

5. Kafka 的 `acks=all + min.insync.replicas=2` 和 etcd 的多数派提交，差在哪一层？
<details><summary>答案</summary>

数据层相似（都要求写进 ≥quorum 个副本才算成功，掉到阈值以下都拒绝写），差在**控制层**：etcd 用 Raft 在副本间做真正的共识——选主、日志全序、任期否决旧主，一套协议包办；Kafka 的分区副本没有共识，leader 由外部 controller/KRaft 指定，副本间是异步追赶 + ISR 动态收缩，"过半"是运维手工拼出来的准入条件。所以 Kafka 允许 unclean leader election 这类配置存在（会主动破坏已提交语义），etcd 不存在等价开关。完整对比见 [kafka 02 章](../12-data-streaming/kafka/02-replication-and-reliability.md) §5/§6。
</details>

## 延伸阅读

- Raft 论文（含图 8 提交规则反例）:https://raft.github.io/raft.pdf
- Raft 可视化（选举/复制动画，配合本章演练看）:https://raft.github.io/
- etcd tuning 指南（heartbeat/election-timeout 建议值）:https://etcd.io/docs/latest/tuning/
- etcd disaster recovery（失 quorum 后的恢复路径）:https://etcd.io/docs/latest/op-guide/recovery/
- Lamport《Paxos Made Simple》（Paxos 史的第一手材料）:https://lamport.azurewebsites.net/pubs/paxos-simple.pdf
- ZAB 论文（ZooKeeper 官方对协议与 Paxos 差异的说明）:https://marcoserafini.github.io/papers/zab.pdf
