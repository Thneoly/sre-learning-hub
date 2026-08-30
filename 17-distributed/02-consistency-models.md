# 02 · 一致性模型阶梯：从线性一致到最终一致

> 模块：17-distributed ｜ 建议时长：3.5 小时 ｜ 关联认证：—（无直接考点；本章给出"这个系统承诺读到什么"的判读框架，是参数评审与"读到旧数据"类工单定性的一锤定音依据）

## 学习目标

- 能按阶梯说出线性一致 > 顺序一致 > 因果一致 > 最终一致的语义，并对每一级说出**"读到什么才算违反"**
- 能把脏读 / 不可重复读 / 幻读翻译到分布式语境，并与单机隔离级别划清界限（一致性模型管读写顺序，隔离级别管事务交错）
- 能给 etcd / ZK / Kafka 分区 / Redis 主从 / DNS / MongoDB 逐个做一致性落位，说清每家的"降级开关"在哪
- 能解释"最终一致的最终是多久"：反熵机制如何收敛、收敛距离在每个已学系统里对应哪个监控指标
- 能按五步排查法处理"读到了旧数据"的工单：先定性一致性级别，再怀疑故障

## 1. 一致性模型阶梯

### 1.1 为什么需要"模型"这个词

副本一多，"读到的值新不新"就没有唯一答案——同一个集群，读主库和读从库是两回事，不同客户端同一秒读也可能不同。**一致性模型就是系统与客户端之间的合同：我保证你不会观察到哪些现象**。合同越强，代价越大；运维的日常就是把每张合同贴到正确的组件上，以及在有人投诉"数据不对"时判断——这是**违约**，还是**你签的就是这种合同**。

### 1.2 四级阶梯：语义与"读到什么才算违反"

| 模型 | 一句话合同 | **读到什么才算违反** | 代价 | 已学系统落位 |
|---|---|---|---|---|
| 线性一致（linearizable） | 每个操作看起来都在"调用与应答之间的某一瞬间"原子生效，且尊重真实时间先后 | **写已应答成功**之后，任何客户端从任何副本读，仍返回旧值（且期间没有更新写覆盖它）——"写完读不到"即违约 | 每次读写都可能要跨多数派确认一轮（延迟、跨机房放大） | etcd 默认线性读；ZK 写路径 |
| 顺序一致（sequential） | 存在一个全体认同的操作全序，且不违背各客户端自己的程序序；**不尊重真实时间** | 不同客户端对同一组写的先后陈述互相矛盾（找不到一个同时满足双方程序序的全序）。**注意**："实时上后开始的读看不到先完成的写"在这里**不违约** | 比线性一致省掉实时性确认 | ZK 默认本地读；Kafka 单分区内读写 |
| 因果一致（causal） | 有因果关系的操作，所有人看到的顺序一致；并发写可以各有所见 | 读到**比已知因果更旧**的值：A 写完 x 后在消息里告诉 B"我写完了"，B 去读却读不到 | 消息要携带因果上下文（向量钟/会话令牌） | MongoDB 因果一致会话 |
| 最终一致（eventual） | 停止写入后，经过有限时间所有副本收敛到同一值 | **不是"读到旧值"**——那是本合同的正常履约。违约是：停写后副本**永不收敛**（永久分歧）、或反熵修复不了冲突需要人工裁决 | 最便宜：异步复制即可 | Redis 主从、DNS、双实例 Alertmanager |

阶梯是**包含式**的：线性一致 ⊃ 顺序一致 ⊃ 因果一致 ⊃ 最终一致。越往上承诺越硬、可优化的空间越小。

```
[图] 线性一致 vs 顺序一致的判例（关键差异只在"实时序"）

线性一致（必须尊重实时序）:
  C1 ──PUT x=1──► 应答 OK ─────────────┐
                                       │ 实时上, C2 的读在 C1 的写完成之后才开始
  C2 ──────────────────────────GET x ──┴─► 必须返回 1

顺序一致（只认程序序, 可无视实时序）:
  C1 ──PUT x=1──► 应答 OK      全序 = [C2 的 GET, C1 的 PUT] 是合法排列
  C2 ──────────────────GET x ──────► 允许返回旧值 0
                                （读"看不到实时在先的写"不算违约）
```

### 1.3 两个必须划清的界限

- **一致性模型 ≠ 隔离级别**：一致性模型讲"读操作能看到哪些写"（对象是**副本间的顺序**）；隔离级别讲"多个事务交错执行时的现象"（对象是**并发事务**）。MySQL 的 RC/RR 靠 MVCC 的 Read View 在**单机**上解决不可重复读（`../11-middleware/mysql/01-innodb-fundamentals.md`，RC 每条语句建视图、RR 首条快照读建视图），与主从复制后的读一致性是两个维度。
- **CAP 的 C ≠ ACID 的 C**：CAP 的 C 就是本表的线性一致（00 章 3.1 节）；ACID 的 C 是业务约束不被破坏。面试把两者混用是硬伤。

## 2. 读写组合与异常：分布式语境下的老朋友

### 2.1 会话保证：同一客户端自己视角的合同

比"全体观察者"更贴近业务投诉的，是**同一个客户端**先后操作的保证（因果一致性的实用子集）：

| 保证 | 内容 | 违反时的业务表现 | 已学出处 |
|---|---|---|---|
| 读己之写（read-your-writes） | 我写完的值，我立刻能读到 | "我改完头像刷新还是旧的" | ZK 要 `sync()` 后本地读才保证（`../16-bigdata/06-zookeeper.md`：本地读可能旧） |
| 单调读（monotonic reads） | 我重复读同一数据，不会越读越旧 | 刷新一次内容"倒回去"了 | Redis 客户端从一个从库切到更落后的从库/新主 |
| 单调写（monotonic writes） | 我的多次写不被乱序观察到 | 消息顺序颠倒 | Kafka 同 key 恒进同一分区就是为此（`../12-data-streaming/kafka/01-log-model-and-architecture.md`） |

### 2.2 脏读 / 不可重复读 / 幻读的分布式化身

| 单机隔离异常 | 分布式化身 | 已学现场的机制 |
|---|---|---|
| 脏读（读到未提交） | 读到**未来会消失的数据**：主库宕机切换后，新主没有这段数据，消息被截断 | Kafka 的 HW 正是为此存在："消费者只能读到 HW 之前的消息"，否则会读到一条随截断消失的消息（`../12-data-streaming/kafka/02-replication-and-reliability.md` 第 2 节）；MongoDB `readConcern: local` 可能读到最终被回滚的写（`../11-middleware/mongodb/02-replicaset-and-sharding.md` 第 4 节）；Flink 下游不开 `isolation.level=read_committed` 会读到未提交事务 |
| 不可重复读（两次读不一致） | **时间倒流**：failover 切到更落后的新主，或客户端换到落后副本，第二次读比第一次还旧 | Redis 哨兵切换后新主落后于旧主的窗口（`../11-middleware/redis/02-persistence-and-ha.md`）；MySQL 从库重放进度不同，两次读打到不同从库 |
| 幻读（范围内集合变化） | 分片/副本各进度不同，**范围查询拼出不一致的集合**：列表忽长忽短 | 跨分片查询无全局快照（05 章）；DNS 两次解析返回不同 endpoints 集合 |

一句总纲：**单机靠锁和 MVCC 挡住的现象，在分布式里全部换了一身衣服重新出场**——但判断标准没变：读到没提交的（脏）、两次不一致（不可重复）、集合漂移（幻）。

## 3. 现实系统落位表

背下这张表，"XX 系统什么一致性"类面试与工单直接查表：

| 系统/组件 | 一致性落位 | 谁保证 / 开关在哪 | 降级路径 | 已学出处 |
|---|---|---|---|---|
| etcd | **线性一致**（默认） | 写走 Raft 多数派；读默认线性（ReadIndex 与多数派确认"我还是 leader"） | 客户端 `--consistency=s` 降串行读：快、可能旧值 | `../04-k8s-fundamentals/13-cluster-admin-and-etcd.md` 2.1 节 |
| ZooKeeper | **写线性一致**；**默认读=顺序一致**（本地内存，可能旧） | ZAB 过半提交保证写全序 | 读要"读己之写"级别就先 `sync()`；leader 挂 2/3 时停写保 C | `../16-bigdata/06-zookeeper.md` 第 3 节 |
| Kafka（单分区） | **顺序一致**（单领导者 + 分区内 FIFO） | 每分区一个 leader，读写都走它；HW 是可见性边界 | `unclean.leader.election` 允许落后副本上位=用丢数据换可用（00 章 CAP 的 A 侧） | `../12-data-streaming/kafka/02-replication-and-reliability.md` |
| Kafka（跨分区/topic） | 无全局序（只有分区内序） | — | 要全局序只能单分区或按 key 分区（牺牲并行度） | 同上 01 章 |
| Redis 主从 | **最终一致** | 异步复制；`WAIT n timeout` 可对单次写等待副本确认 | failover 丢旧主最后一段写入；`min-replicas-to-write` 缩小脑裂窗口 | `../11-middleware/redis/02-persistence-and-ha.md` 6.4 节 |
| MongoDB | 按请求选：`readConcern local`（默认，可能旧/被回滚）→ `majority`（线性基线） | writeConcern `w:majority` 配 readConcern majority 是强一致基线 | 因果一致要 causally consistent session 配合 | `../11-middleware/mongodb/02-replicaset-and-sharding.md` 第 4 节 |
| MySQL 半同步 | 仍是**最终一致**（从库重放异步）；半同步改的是 RPO 不是读语义 | `rpl_semi_sync_master_*`，超时自动降级异步 | 降级后回到纯异步（RPO>0） | `../11-middleware/mysql/02-backup-replication.md` 半同步一节 |
| DNS / CoreDNS | **最终一致** + 客户端 TTL 缓存 | 记录 TTL；K8s 里 Endpoints/EndpointSlice 经 watch 传播 | 收敛被两层缓存放大：server 端 + 客户端 stub resolver | `../04-k8s-fundamentals/05-service-and-dns.md` |
| K8s 控制器视图 | **最终一致**（Informer 本地缓存） | list-watch + resourceVersion，410 Gone 兜底重 list | "对象建好了但控制器没反应"是常态，不是故障 | `../04-k8s-fundamentals/02-architecture-and-control-loop.md` 第 6 节 |
| 双实例 Alertmanager | 最终一致（gossip） | gossip 复制 silences/nflog，分区瞬间可能双发通知 | 已知权衡，收敛后去重 | `../08-pca/05-alerting-alertmanager.md` 6.2 节 |

读表三个要点：**强一致都不是白来的**——etcd 每次写要多数派 fsync，ZK 每次写要过半 ACK，这正是两家"不适合当业务存储、只放元数据"的根源；**落位是按操作粒度的**——ZK 同一系统读一套写一套；**降级开关是运维参数评审的实弹靶场**——评审 K8s 业务上 Kafka，就是评审 acks/min.insync.replicas 这几个"一致性/持久性"定价参数（`../12-data-streaming/kafka/02-replication-and-reliability.md` 第 4 节组合矩阵）。

## 4. "最终一致的最终是多久"：收敛与反熵

### 4.1 收敛靠什么：反熵机制

"最终"能成立，是因为副本间有**持续对账**机制（术语叫反熵，anti-entropy）——哪怕没人写数据，成员也在定期互相校对状态，把分歧磨平：

| 系统 | 反熵方式 | 典型收敛量级 |
|---|---|---|
| Alertmanager 集群 | gossip 传播 silences/nflog，分区恢复后继续磨平 | 秒级（分区期间的双发窗口即未收敛窗口） |
| Redis Cluster | cluster bus 上 PING/PONG 交换节点与槽视图，SETSLOT 终态靠 gossip 收敛 | 秒级 |
| ZK | follower 与 Leader 同步（快照+增量 diff），未提交事务 TRUNC 掉 | 选举后秒级 |
| Redis 主从 | 断线重连优先部分重同步（repl-backlog），对不上才全量 | 全量取决于数据量，分钟级 |
| MySQL 主从 | IO 线程拉 binlog 进 relay log，SQL 线程重放；断点续传 | 取决于写压与大事务 |
| Kafka | follower 持续 Fetch 追 leader LEO，落后超 `replica.lag.time.max.ms` 出 ISR | 持续进行，落后可监控 |
| DNS | 记录 TTL 到期后重新解析/区传送 | TTL 量级（分钟到小时） |

### 4.2 "最终"是可监控的工程参数

把"最终"翻译成每个系统的**当下收敛距离**，它就从玄学变成指标：

| 系统 | 看哪个数 | 语义边界（容易踩的坑） |
|---|---|---|
| MySQL | `Seconds_Behind_Source` | 只衡量**重放**落后；IO 线程断开期间显示 NULL/0 但实际在掉队（`../11-middleware/mysql/02-backup-replication.md`） |
| Redis | `INFO replication` 的 master/slave `*_repl_offset` 差 | offset 差=字节数，不是时间；结合写压换算 |
| Kafka | 分区 `isr` 数、`UnderReplicatedPartitions`、follower lag | lag 为条数；ISR 判定按时间不按条数 |
| ZK | `zk_synced_followers` / `zk_pending_syncs` | 5 节点时 synced < 2、pending > 0 持续即落后 |
| K8s 控制器 | Informer 的 cache sync 状态、事件滞后 | 控制器重启后要重新 list 全量，期间视图是旧的 |

两个工程结论：**收敛窗口 ≈ 故障时的丢失窗口**——从库落后 30 秒，主库坏掉就丢 30 秒（最终一致的"旧"，在故障瞬间变成 RPO）；**客户端缓存会把窗口二次放大**——DNS 的 TTL、SDK 的槽表缓存、Informer 的本地缓存，都在"副本已收敛"之后还在发旧值，排查时两层都要算。

### 4.3 面试一句话

"最终一致不是不保证一致，是**不保证何时**一致；何时的上界由反熵周期、写压和客户端缓存 TTL 三者决定，这三个数都可以监控和调优。真正不可接受的场景（扣款、扣库存）不是换更强模型，而是把关键操作改成对账+幂等重试。"

## 5. 运维含义："读到了旧数据"先查一致性级别，再怀疑故障

这类工单九成不是故障。五步排查，按序执行：

```
"读到了旧数据"
  │
  ① 读路径连的是谁: 主库? 从库? 本地缓存? DNS? 换个直连主的客户端复现一下
  │     └─ 换直连就正常 → 问题在读路径的"合同"上, 不是集群坏了
  ② 什么一致性级别: readConcern? etcd --consistency? isolation.level?
  │     └─ 串行读/本地读/读从库, 读到旧值是"按合同履约"
  ③ 当下收敛距离: Seconds_Behind / offset 差 / replica lag 多少
  │     └─ 延迟大 → 治延迟(大事务/GC/网络), 不是一致性"坏了"
  ④ 最近是否发生过 failover: 新主是否落后于旧主、有无事务回滚
  │     └─ MongoDB 回滚目录的 BSON、Kafka unclean election 截断都是现场证据
  ⑤ 客户端侧缓存: TTL / SDK 槽表 / Informer 缓存
        └─ 服务端早已收敛, 客户端还在发旧值 → 清缓存/等 TTL
```

配套三条纪律：**先用"写后立读主库"做金标准对照**（能读到=数据在，剩下全是路径问题）；**别急着重启**——重启会冲掉第④步要的证据；**给"读旧值"配阈值告警而不是布尔告警**（收敛距离是连续量）。

## 实战演练

**演练一：etcd 线性读与串行读的定价对比**

```bash
# [master] 循环放在 Pod 内跑，避免 kubectl exec 开销淹没差异
kubectl -n kube-system exec etcd-"$(hostname)" -- bash -c '
  export ETCDCTL_API=3
  C="--cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key --endpoints=https://127.0.0.1:2379"
  etcdctl $C put /sre-lab/consistency v1 >/dev/null
  echo "--- 50 次线性读(默认, ReadIndex 多一轮确认):"
  time (i=0; while [ $i -lt 50 ]; do etcdctl $C get /sre-lab/consistency --consistency=l >/dev/null; i=$((i+1)); done)
  echo "--- 50 次串行读(读本成员 KV, 无多数派确认):"
  time (i=0; while [ $i -lt 50 ]; do etcdctl $C get /sre-lab/consistency --consistency=s >/dev/null; i=$((i+1)); done)
  etcdctl $C del /sre-lab/consistency >/dev/null
'
# 预期：串行读更快。单成员集群上差距小（ReadIndex 只需问自己）；
# 3 成员集群上差距才是"每读省一次多数派往返"的全价（lab 01 复测）
```

验证方法：两组 `real` 时间串行读 ≤ 线性读即符合预期；把差距理解为"一致性按次付费"。

**演练二：Redis 最终一致的窗口与"可等待的确认"**

```bash
# [任意节点] 起一主一从（仿 ../11-middleware/redis/02-persistence-and-ha.md 的实验形态）
docker network create cons-lab-net 2>/dev/null
docker run -d --name cons-master --network cons-lab-net redis:7.2
docker run -d --name cons-replica --network cons-lab-net redis:7.2 --replicaof cons-master 6379
sleep 3
docker exec cons-replica redis-cli INFO replication | grep -E "^role|master_link_status"
# 预期：role:slave / master_link_status:up

# [任意节点] 突发写入 5 万个 key，立刻看两端的 offset 差（当下收敛距离）
printf 'SET bk:%d v\r\n' $(seq 1 50000) | docker exec -i cons-master redis-cli --pipe | tail -1
docker exec cons-master redis-cli INFO replication | grep -E "master_repl_offset|slave0="
docker exec cons-replica redis-cli INFO replication | grep slave_repl_offset
# 预期：主从 offset 存在差值；几秒后重跑两条命令，差值归零——这就是"最终"的实测长度

# [任意节点] WAIT：把这一次写的"最终"变成可等待的确认
docker exec cons-master sh -c 'redis-cli SET sync:test v; redis-cli WAIT 1 3000'
# 预期：1) OK  2) (integer) 1   （确认的副本数；从库断开则 0，写不阻塞但退回最终一致）
```

**演练三：纸面判例——这算不算违约（把第 1.2 节的表用起来）**

对每个判例回答两问：(a) 违反了哪一级的一致性（或根本没违反）？(b) 运维上第一动作是什么？

- 判例 A：etcd `put` 应答成功后，客户端立刻从另一成员 `--consistency=s` 读到旧值。
- 判例 B：业务两次 `GET` 同一 key，中间哨兵完成一次 failover，第二次读到更旧的值。
- 判例 C：Kafka 消费者读到 offset X 的消息，随后 leader 切换，该消息被截断消失。
- 判例 D：A 在 MongoDB 里写完 x，在聊天里告诉 B"我写完了"，B 立刻查询读不到。

<details><summary>判例参考答案</summary>

A：没违约——串行读的合同就允许旧值；把客户端改回默认线性读（或接受旧值）即可，集群无故障。
B：违反**单调读**（时间倒流），根因是 failover 后新主落后于旧主——这在最终一致的合同内，是可用性换来的已知代价；运维动作是评估丢失窗口、必要时用 `WAIT`/换强一致组件，而不是"修 Redis"。
C：违反 Kafka 自己的可见性承诺——HW 之前才可读，读到会消失的消息说明发生了 unclean leader election（落后副本上位）。这是**真故障**：查 `unclean.leader.election.enable` 与 ISR 收缩记录（kafka 02 章）。
D：违反**因果一致**（读比已知因果更旧）；若业务需要，开启 causally consistent session + readConcern majority（MongoDB 04 章）。
</details>

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| "写完立刻读不到"工单升级成集群故障 | 读路径是串行读/本地读/从库，级别本来就低 | 先用五步排查法定性（5 节），再谈修 |
| 把 ZK 当强一致读用，偶发读到旧配置 | ZK 默认本地读是顺序一致，非线性 | 读前 `sync()`，或改走带版本号的 watch 通知 |
| Kafka 消费端读到"先多后少"的抖动数据 | 没开 `isolation.level=read_committed`，读到未提交事务 | 消费端开 read_committed（flink 02 章常见坑原条目） |
| 以为半同步=从库不落后 | 半同步只保证 binlog 到达从库磁盘，不保证重放完成 | 切换仍需补齐工具；监控重放延迟（mysql 02 章） |
| 控制器"没反应"，被当成 API 故障 | Informer 本地缓存是最终一致副本，list/watch 在路上 | 看 cache sync 与事件滞后指标，等收敛或查 watch 断连 |
| "最终一致"被理解成"总会一致的，不用管" | 收敛窗口=故障丢失窗口，还叠加客户端 TTL | 监控收敛距离并设阈值；关键路径用对账+幂等 |
| 面试答"我们全是强一致" | 系统落位是分操作粒度的 | 用第 3 节落位表逐组件陈述 |

## 自测

1. 顺序一致允许"实时上后开始的读看不到先完成的写"，线性一致不允许。用一个已学组件的行为分别说明这两句话。
<details><summary>答案</summary>

顺序一致例：ZK 默认本地读——follower 的内存可能落后，客户端 A 写入并收到成功应答后，客户端 B 立刻在某个 follower 上读仍可能是旧值；只要所有观察者对"谁先谁后"的全序陈述一致，就不违约。线性一致例：etcd 默认线性读——写应答成功意味着已过多数派提交，任何成员在读前先经 ReadIndex 与多数派确认自己视图不落后，因此实时在后的读必见新值（代价是每读多一轮往返，正是演练一实测的价格）。
</details>

2. Kafka 说"分区内 FIFO"，为什么它落位是顺序一致而不是线性一致？HW 又在其中扮演什么角色？
<details><summary>答案</summary>

单分区只有一个 leader，读写都走它，分区内消息顺序唯一——这给出的是"全体认同一个全序"（顺序一致的核心）。但 Kafka 不承诺跨分区/跨消费者的实时序，消费位置由客户端推进，也不提供"写应答后任何读必见"的全局仲裁。HW 补的是可见性边界：消费者只能读 ISR 集体确认过的位置，防止读到"随 leader 切换被截断而消失"的消息——这是把脏读挡在合同外，与线性一致是两件事。
</details>

3. "最终一致的最终是多久？"——给出三个决定这个长度的变量，并各配一个可监控指标。
<details><summary>答案</summary>

① 服务端反熵/复制追赶周期：MySQL `Seconds_Behind_Source`（注意只测重放）、Redis offset 差、Kafka follower lag；② 故障切换的接管窗口：failover 后新主相对旧主的落后量（MongoDB 回滚文件、哨兵切换日志）；③ 客户端缓存 TTL：DNS TTL、SDK 槽表缓存、Informer 的 resync。总窗口≈三者之和，且只有在停写的前提下才单调收敛到零。
</details>

4. 同一个 Redis 上，`WAIT 1 3000` 返回 1 和返回 0 分别意味着什么？它把一致性档位改变了吗？
<details><summary>答案</summary>

返回 1：这一条写已被 1 个副本确认到达，丢失窗口显著收窄；返回 0：超时内没有副本确认（副本断开/落后），写仍留在主库，退回纯异步。注意 WAIT 改善的是**持久性/RPO**（这条写复制到了几个节点），不提供线性一致的读语义，也不是事务边界——它是"按次付费的持久性增强"，与一致性档位是正交的两个轴。
</details>

5. 工单："应用刚创建完对象，控制器十秒后才建 Pod。"用本模块的框架定性，并给出验证命令方向。
<details><summary>答案</summary>

这不是违约而是最终一致视图的正常表现：apiserver 写 etcd 是同步的（对象一定在），但控制器依赖 Informer 的本地缓存副本，事件要经 list-watch 传播、缓存同步、reconcile 队列才落到动作。验证方向：watch 事件到达时间（`kubectl get events --sort-by=.lastTimestamp`）、控制器 Informer 的 cache sync 指标、kube-controller-manager 日志里该对象的 reconcile 时间戳；若间歇性超过分钟级，查 watch 断连与 410 Gone 重 list（04-k8s 02 章第 6 节），而不是重启 apiserver。
</details>

## 延伸阅读

- Jepsen 一致性模型（各级别严格定义与违反示例，权威图鉴）：https://jepsen.io/consistency
- etcd 官方 API 保证（线性一致/串行读的官方措辞）：https://etcd.io/docs/v3.5/learning/api_guarantees/
- ZooKeeper 官方文档（顺序保证与 sync 的语义）：https://zookeeper.apache.org/doc/current/zookeeperProgrammers.html
- MongoDB readConcern / 因果一致会话：https://www.mongodb.com/docs/manual/reference/read-concern/
- Redis 复制与 WAIT：https://redis.io/docs/latest/operate/oss_and_stack/management/replication/
- Kafka 语义（交付保证与 consumer 隔离级别）：https://kafka.apache.org/documentation/#semantics
- Kleppmann《Please Stop Calling Databases CP or AP》：https://martin.kleppmann.com/2015/05/11/please-stop-calling-databases-cp-or-ap.html
