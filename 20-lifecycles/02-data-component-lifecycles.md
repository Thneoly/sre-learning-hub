# 02 · 数据组件生命周期图鉴：8 条状态机

> 模块：20-lifecycles ｜ 建议时长：2 小时 ｜ 关联认证：—（无直接考点；本章是横向参考图鉴——etcd、Kafka、Redis、MySQL、PostgreSQL、RabbitMQ、Flink 的原理你都已在对应模块学过，这里只做一件事：把每个组件压成一张 ASCII 状态图，排障时先问"现在卡在哪个状态、谁在推它走"）

## 本章怎么用

- 方框 = 状态，箭头 = 转移，箭头旁的字 = **触发条件**；每个状态和转移只讲"什么触发 / 什么后果"一句话。
- 每张图后面跟一张状态说明表（状态 | 含义 | 谁控制 | 常见卡住原因）、1~2 个最常见的卡住场景（引全站排障索引 [SCENARIOS.md](../SCENARIOS.md)）、以及深入章节链接——原理细节一律不在这里展开。
- 每张图配一行"从图中看出的 SRE 价值"：状态机的哪个参数直接决定 RTO / RPO。读完全章你应该形成一个条件反射：**调超时参数 = 在 RTO 和误判率之间搬家**。

---

## 1. etcd（Raft 角色 + 集群 quorum 两层状态机）

### 状态图

```
  ┌──────────┐ 选举超时：election-timeout（默认 1000ms）内     ┌────────────┐
  │ Follower │ 没收到 Leader 心跳 → 自己涨 term 发起拉票      │ Candidate  │
  └──────────┘ （已开 PreVote：先探测有无活 Leader 再拉票）    └────────────┘
       ▲  ▲                                                 │         │
       │  │收到合法 Leader 心跳/日志：重置选举计时器，           │拆票：没人  │获过半
       │  │安静追随（Follower 的常态是"只续命不做事"）           │过半 → 再  │成员投票
       │  │                                                 │等一轮超时 │
       │  │                                                 ▼         ▼
       │  │                                          发现更高 term ┌────────┐
       │  └───────────────── 立即退位 ◄───────────────── 立即退位 │ Leader │
       │                                                     └────────┘
       │                                                          │
       └────────── check-quorum：一个选举超时内联系不上多数派 ──────┘
                    → 主动降级回 Follower（etcd 3.4+ 默认开启）

  集群整体视角（N=3）：
  [有 quorum：读写正常] ──挂 2 个成员──► [失 quorum：写与 linearizable 读全超时]
        ▲                                   │ serializable 读仍可从单成员出
        │                                   │ （K8s apiserver 读走本地缓存 → 读通写挂）
        └──── 恢复第 2 个成员：quorum 回归，跑一轮选举，服务恢复 ────┘
```

### 状态说明

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
|---|---|---|---|
| Follower | 只接收 Leader 的日志与心跳，被动复制 | Leader 的心跳在替它"续命" | 心跳到不了：Leader 磁盘慢、网络分区 |
| Candidate | 拉票中，term 已自增 | 自己的选举计时器触发 | 反复拆票：多节点同时超时（随机化没起作用） |
| Leader | 唯一写入入口，广播日志与心跳 | 过半投票产生；check-quorum 可废黜 | WAL fsync 慢 → 心跳迟滞 → 脑旋（频繁切主） |
| 失 quorum | 集群级状态：能选出的成员 < N/2+1 | 成员存活数决定 | 磁盘满 NOSPACE、两台同时宕、证书过期 |

### 最常见卡住场景

- **kubectl get 正常但 create/apply 全超时**：etcd 失 quorum——读走 apiserver 本地 watch cache 所以还通；`etcdctl endpoint status` 数存活成员，先救一台，别急重建。（SCENARIOS.md §9 分布式与共识）
- **控制面频繁切主（脑旋）**：WAL fsync 慢 → 心跳/选举超时被反复触发——etcd 独占低延迟盘、调大 election-timeout，对 leader 变化告警。（同上）

### 从图中看出的 SRE 价值

选举超时 × 2 ≈ Leader 故障后写中断的上限——**调 election-timeout 就是在调控制面的 RTO 旋钮**：调小恢复快但磁盘一抖就误切，调大抗抖但 RTO 变长。

### 深入

[19-distributed/03 · 共识与复制](../19-distributed/03-consensus-and-replication.md)：§4 Raft 全流程（角色/任期/选举）、§5 映射 etcd 与 K8s 控制面、"常见坑"表。

---

## 2. Kafka Partition（副本侧）+ 消费组（消费侧）

### 状态图

```
  副本侧（每个 partition 的每个副本）：
  ┌─────────┐  broker 宕机/session 超时，controller 感知 ──► 从 ISR 里挑副本升为新 Leader
  │ Leader  │ （仅 unclean.leader.election.enable=true 才敢碰 OSR）
  └─────────┘
       ▲ │
       │ │ 所在 broker 挂/磁盘满/fetch 追不上：
       │ │ replica.lag.time.max.ms（默认 30s，旧版 10s）内没追齐
       │ │ Leader 的 LEO → 被 Leader 踢出 ISR
       │ ▼
  ┌─────────┐   持续 fetch，时间阈值内追齐 Leader LEO      ┌─────────┐
  │ OSR 副本 │ ─────────────────────────────────────────► │ ISR 副本 │
  └─────────┘   （重新入 ISR 前，先按 leader epoch 截齐）   └─────────┘

  消费组侧（与分区平行的一台状态机）：
  [Stable] ─成员入退/session 超时/max.poll.interval 超时─► [PreparingRebalance]
       ▲                                                    │ 拉齐成员名单
       │              [CompletingRebalance] ◄────────────────┘
       └───── 分配方案确认，按新分配继续消费 ─────────────────┘
```

### 状态说明

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
|---|---|---|---|
| Leader 副本 | 分区唯一读写入口，维护 ISR 名单 | controller 选出 | broker 宕机后选主慢、unclean 被禁时 ISR 已空 |
| ISR 副本 | 与 Leader 保持同步的副本集合成员 | Leader 按追赶度收放 | 磁盘 IO/网络慢，fetch 永远差一截 |
| OSR 副本 | 被踢出同步集合，继续慢慢追 | 同上 | 追平速率 < 写入速率（永久掉队） |
| PreparingRebalance | 消费组重平衡中，全组暂停消费 | group coordinator | 成员反复进出、poll 间隔超时，rebalance 雪崩 |

### 最常见卡住场景

- **大量 NotEnoughReplicasException 写入失败**：ISR 收缩到 min.insync.replicas 以下——先救 ISR（修 broker/磁盘），别调小 min.insync 换可用性。（SCENARIOS.md §4，详见 [kafka/02 常见坑](../14-data-streaming/kafka/02-replication-and-reliability.md)）
- **消费组频繁 rebalance / under-replicated 副本掉线**：按日志关键词对号入座（max.poll.interval 超时、fetch 追不上）。（SCENARIOS.md §4，详见 kafka/03 §5 排障表）

### 从图中看出的 SRE 价值

`replica.lag.time.max.ms` 决定副本从掉队到被踢的窗口，`min.insync.replicas` 决定 ISR 缩到多小开始拒写——**前者调的是"容错余量"，后者是可用性换一致性的闸门**；unclean 开关则直接是 RPO 开关（false = 拒服务保数据）。

### 深入

[kafka/02 · 副本与可靠性](../14-data-streaming/kafka/02-replication-and-reliability.md)：§3 ISR、§5 acks 与 min.insync.replicas 矩阵、§6 Unclean 选举、§8 位移提交语义。

---

## 3. Redis 主从复制

### 状态图

```
  ┌────────────┐ replicaof 指向主库，发 PSYNC ? -1      ┌────────────────┐
  │ 新 replica │ ────────────────────────────────────► │ 主库回 FULLRESYNC│
  └────────────┘                                       └────────────────┘
                                                             │ 主库 bgsave 出 RDB，
                                                             │ 传输期间新写入暂存在
                                                             ▼ replication buffer
                                                       ┌──────────┐
                              buffer 命令追发，进入常态 │  全量同步  │
                                                       └──────────┘
                                                             │
                                                             ▼
  ┌──────────────────┐   网络闪断/主库重启/连接被踢    ┌──────────────┐
  │ 在线增量复制（常态）│ ◄────────────────────────── │ 断线等待       │
  │ 主库把写命令流进   │                             │ （等待重连）    │
  │ repl_backlog 环   │                             └──────────────┘
  └──────────────────┘                                    │ 重连，发
       ▲                                                  │ PSYNC <replid> <offset>
       │ offset 仍在 repl_backlog 窗口内：只补差量          │
       └──────────────────────┐                           ▼
                               │               ┌─────────────────────┐
                               │ 命中 → 部分重同步│ offset 已被环覆盖 /   │
                               ◄─────────────── │ replid 对不上 → 回到  │
                                （几 KB~MB 级）  │ 全量同步（左上）       │
                                                 └─────────────────────┘
```

### 状态说明

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
|---|---|---|---|
| 全量同步 | 主库 fork 出 RDB 整份发给从库 | 从库发起，主库执行 | 主库内存大 → fork 慢；replication buffer 超 `client-output-buffer-limit replica`（默认 256MB）→ 被断开重来回 |
| 在线增量复制 | 主库把每条写命令持续流给从库 | 主库单线程顺手做 | 主库写流量大、从库应用慢 → output buffer 涨 |
| 断线等待 | 连接断开，从库带着 replid+offset 等重连 | 网络层 | 长断线期间主库 backlog 太小，把需要的差量覆盖掉 |
| 部分重同步 | 只传断线期间的差量命令 | 主库核对 offset 是否在 backlog 内 | backlog 越小命中率越低，退化为全量 |

### 最常见卡住场景

- **replica 闪断一次就全量同步**：repl-backlog-size（默认仅 1MB）太小——按"断线时长 × 写流量"调大，让部分重同步接得住闪断。（SCENARIOS.md §4，详见 [redis/02 常见坑](../13-middleware/redis/02-persistence-and-ha.md)）
- **磁盘满后主库所有写报错**：`stop-writes-on-bgsave-error` 保护——全量同步依赖 bgsave，磁盘不修同步也做不成。（同上）

### 从图中看出的 SRE 价值

全量同步的代价 = 主库 fork + 整份 RDB 网络传输——**repl-backlog-size 是"断线多久内不用付全量代价"的预算**：调它就是在给"闪断"和"灾难性回退到全量"之间画分界线，直接决定主库的 fork 压力频率。

### 深入

[redis/02 · 持久化与高可用](../13-middleware/redis/02-persistence-and-ha.md)：§5.1 全量同步流程、§5.2 部分重同步与 repl_backlog、"常见坑"表。

---

## 4. Redis Sentinel（对"主库"这台状态机的接管）

### 状态图

```
  ┌────────┐ 本哨兵对主库 ping 连续超时（> down-after-milliseconds：sentinel monitor 必填项，无内置默认，官方示例常取 30000）
  │ 正常    │ ─────────────────────────────────────────────┐
  └────────┘                                             ▼
      ▲  ▲                                        ┌────────┐
      │  │ ping 恢复：本哨兵自己摘除主观下线        │ SDOWN  │ 主观下线（只代表一个哨兵的意见）
      │  └────────────────────────────────────── │        │
      │                                          └────────┘
      │                                                │ 询问其他哨兵：≥ quorum 个
      │                                                │ 也标了 SDOWN？
      │                                                ▼
      │                                          ┌────────┐
      │                                          │ ODOWN  │ 客观下线（法定人数认定）
      │                                          └────────┘
      │                                                │ 先在哨兵内部选出执行者：
      │                                                │ Raft 风格选举，需哨兵总数过半
      │                                                ▼
      │                                          ┌──────────────┐
      │                                          │ Sentinel     │ leader 哨兵诞生
      │                                          │ leader 选举  │
      │                                          └──────────────┘
      │                                                │ 挑从库（replica-priority →
      │                                                │ offset → runid），SLAVEOF NO ONE
      │                                                ▼
      │  旧主回归后被改成新主的从库              ┌──────────────┐
      └──────────────────────────────────────── │  故障转移完成 │ 其余从库改指新主，
         （旧主降级，不是回到"正常"）            └──────────────┘ 客户端经发布订阅感知
```

### 状态说明

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
|---|---|---|---|
| SDOWN | 单个哨兵认为主库不可达 | 每个哨兵独立计时 | 网络单侧抖动、主库假死（fork/swap 卡顿） |
| ODOWN | quorum 个哨兵都报 SDOWN | quorum 配置 | quorum 设太高凑不齐 → 永远不认定 |
| leader 选举 | 选出一个哨兵执行转移 | 哨兵总数过半（≠ quorum） | 哨兵挂到不过半 → 谁也不敢动（这是防脑裂，不是故障） |
| 故障转移中 | 升从为主 + 改其余从库指向 | leader 哨兵（failover-timeout 默认 180s 内完成） | 从库都在全量同步中没一个就绪 |

### 最常见卡住场景

- **三哨兵挂俩不切换**：leader 选举需要哨兵总数过半——部署 ≥3 且奇数，把多数派凑出来是前置条件。（SCENARIOS.md §4，详见 [redis/02 常见坑](../13-middleware/redis/02-persistence-and-ha.md)）
- **replica 闪断全量同步**（承接上节）：failover 后其余从库改指新主，全都触发一次同步，backlog 小 → 集体全量。（同上）

### 从图中看出的 SRE 价值

down-after-milliseconds 是故障发现延迟的下限，加上选举与升从耗时 ≈ **Redis 侧的 failover RTO**；两个"多数"（quorum 管认定、majority 管执行）各挡一类误判——把 quorum 调成 1 省不了 RTO，只会换来单哨兵网络抖动就切主的误杀。

### 深入

[redis/02 · 持久化与高可用](../13-middleware/redis/02-persistence-and-ha.md)：§6.2 下线判定与 leader 选举、§6.3 故障转移全流程、§6.4 脑裂与防护。

---

## 5. MySQL 主从复制（从库两线程状态机）

### 状态图

```
  ┌────────┐ CHANGE REPLICATION SOURCE TO（给位点/GTID）
  │ 新从库  │ ─────────────────────────────────────────────┐
  └────────┘                                             ▼
                                                  ┌──────────────┐
                                                  │ IO 线程连主库 │ 报出位点头，拉 binlog
                                                  └──────────────┘
                                                          │ 收到的事件顺序写进
                                                          ▼ relay log
  ┌──────────────┐  SQL 线程读 relay log 逐条重放    ┌──────────────┐
  │  追平（常态）  │ ◄───────────────────────────── │ SQL 线程重放中 │
  │ 两端位点贴近， │                                │ Seconds_     │
  │ 延迟≈0       │ ────大事务/单线程重放慢/从库负载──▶│ Behind_Source│
  └──────────────┘         延迟拉大（回到左边）      │ 数字增长     │
        ▲                                            └──────────────┘
        │ 主库宕机，人工/编排工具执行 failover：            │ 复制报错 1062/1032
        │ 挑延迟最小的从库提升（STOP REPLICA; RESET       │ （主从数据已不一致）
        │ REPLICA ALL; READ_ONLY=OFF）                   ▼
        └──────────────────────────────────── 修复或重搭（GTID 空事务跳过）
```

### 状态说明

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
|---|---|---|---|
| IO 线程运行 | 持续拉 binlog 进 relay log，Read_Master_Log_Pos 前进 | IO 线程 | 主库 binlog 被清理（位点失效）、网络断 |
| SQL 线程重放 | 按序重放 relay log，Relay_Log_Pos 前进 | SQL 线程（单线程按序） | 大事务、从库写压力大、行锁冲突 |
| 延迟 | Seconds_Behind_Source > 0，RPO 窗口打开 | 两个线程的速度差 | 平稳增长=单线程重放慢；阶梯=大事务 |
| 追平 | 两端位点贴近，可安全提升 | 应用写入速率 vs 重放速率 | 主库写入洪峰时永远差一截 |

### 最常见卡住场景

- **主从延迟增长或复制中断 1062/1032**：延迟先判型（平稳=重放慢 / 阶梯=大事务）；1062/1032 用 GTID 空事务跳过，真正不一致就重搭。（SCENARIOS.md §4，详见 [mysql/02 常见坑](../13-middleware/mysql/02-backup-replication.md)）
- **半同步开着仍丢数据**：从库慢 → rpl_semi_sync_master_timeout（默认 10s）到期自动降级异步——降级状态量要告警，治从库延迟而不是调大超时。（引 [19-distributed/03 常见坑](../19-distributed/03-consensus-and-replication.md)）

### 从图中看出的 SRE 价值

**异步复制下 Seconds_Behind_Source 就是实时 RPO**：主库宕机那一刻从库没收到的事件全部丢失。半同步把 RPO 压到 0，代价是把这 10s 超时变成主库写入 RTO 的一部分——本质是拿 RTO 买 RPO。

### 深入

[mysql/02 · 备份恢复与主从复制](../13-middleware/mysql/02-backup-replication.md)：§3 主从复制全流程、"延迟成因与对策"、"半同步复制"。

---

## 6. PostgreSQL 流复制 + Patroni failover

### 状态图

```
  ┌─────────┐  walsender 持续把 WAL 段推给 standby   ┌─────────┐
  │ Primary │ ────────────────────────────────────► │ Standby │
  └─────────┘           walreceiver 收，持续 redo    └─────────┘
       ▲ │                                        │        │
       │ │ 复制槽 pin 住 WAL：standby 没收走的       │        │ pg_ctl promote /
       │ │ WAL 不许清理（pg_wal 暴涨的元凶）          │        │ Patroni 执行 failover
       │ │                                        ▼        ▼
       │ │  Patroni 视角（DCS=etcd，租约 TTL 默认 30s）：
       │ │  [primary 持锁 leader key，loop_wait=10s 续租]
       │ │        │ TTL 内没续租（主库/网络挂）→ 锁过期
       │ │        ▼
       │ │  [Patroni 竞选：拿 DCS 过半可用做前提]
       │ │        │ 选 delay 最小的 standby
       │ │        ▼
       │ ▼        ▼
       │ ┌──────────────┐  promotion 生成新时间线（timeline+1，写 .history）
       │ │ 新 Primary   │  旧时间线从此作废
       │ └──────────────┘
       │        │ 旧 Primary 回归：不能直接拉起重挂——它带着旧时间线上
       │        │ 已被废除的 WAL，直接接管会分裂
       │        ▼
       └─ pg_rewind 按新时间线回卷差异（或整库重搭）→ 降级为新主的 standby
```

### 状态说明

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
|---|---|---|---|
| Primary | 唯一写入端，walsender 推 WAL | Patroni 持有的 DCS leader 锁 | 锁续租失败即被废黜 |
| Standby | 持续 redo WAL，可只读服务 | walreceiver | 复制槽把主库 pg_wal 撑爆 |
| 同步提交等待 | synchronous_commit 级别下提交等 standby 回执 | synchronous_standby_names 名单 | 名单与 application_name 不匹配 → 提交无限等待 |
| promotion | standby 升为新主，时间线 +1 | 人工 promote 或 Patroni | 旧主未 rewind 就拉起 → 双主分裂 |
| rewind/重搭 | 旧主回卷或重建为 standby | 运维动作 | wal_log_hints/data checksums 没开 → pg_rewind 拒跑 |

### 最常见卡住场景

- **Patroni 集群"全只读不切换"**：etcd 失去多数派——DCS 是唯一真相源，修 DCS 是唯一正解。（SCENARIOS.md §4，详见 [postgresql/02 §3 Patroni + etcd](../13-middleware/postgresql/02-replication-and-ha.md)）
- **配了同步复制后写入全部挂起（卡死不是变慢）**：synchronous_standby_names 与备库 application_name 不一致 → 主库认为没有同步备库，所有提交无限等待。（同上，"常见坑"）

### 从图中看出的 SRE 价值

**Patroni 的 TTL（默认 30s）就是 PG 侧 failover 的检测时钟**：RTO ≈ TTL + 竞选 + promote 秒数；而时间线机制提醒你——**failover 不是把旧主拉起来就完事**，RPO 的最后一环在 rewind 是否成功。

### 深入

[postgresql/02 · 复制与高可用](../13-middleware/postgresql/02-replication-and-ha.md)：§1 物理流复制、"复制槽：防 WAL 清理的双刃剑"、§3 Patroni + etcd。

---

## 7. RabbitMQ 消息（从发布到死信的单条消息状态机）

### 状态图

```
  publisher ──► [已发未确认] ──broker 回 basic.ack──► [已路由到队列 Ready]
     │ 未开 publisher confirm：这一段没有回执，          │（durable 队列+persistent
     │ broker 落盘前挂 = 消息无声丢失                    │ 消息才扛得住重启）
     │                                                  │ 消费者收到
     │ mandatory=true 且路由不到任何队列：                ▼
     │ broker 发 basic.return 把消息退回 publisher  [Unacked]（占住 prefetch 配额）
     │ ——发布侧机制：消息从未入队，不走                  │
     │   broker 内的死信通道；publisher                 ├─ basic.ack ──► [终态：已消费]
     │   没接住 return（或没开 confirm）                ├─ nack/reject + requeue=true
     ▼   就在这里无声丢失                                │    ──► 退回 Ready 重投
  [丢失]                                                 └─ nack/reject + requeue=false
                                                              ──► 走下方死信通道
   队列配了 x-message-ttl，Ready 超时 ──────────────────────┐
   或消息带 TTL 过期 ────────────────────────────────────────┤
   或长度超限：默认 drop-head 丢弃的队头 ─────────────────────┤
                                                            │
   或 nack/reject 且 requeue=false（Unacked 而来）───────────┴──► [死信 DLX] ──► 投到
                                                                  死信交换机绑定的队列
                                                                 （没配 DLX ──► [丢弃]）
   注意：overflow=reject-publish 不在上面任何一条里——它把最新消息拒绝入队并 basic.nack
        退回 publisher（发布侧拒绝，与死信是两条路）；长度超限会死信的是 drop-head 丢掉的队头
```

### 状态说明

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
|---|---|---|---|
| 已发未确认 | publisher 已发出，等 broker confirm | channel 的 confirm 模式 | 没开 confirm → 丢了也不知道 |
| Ready | 在队列里等待投递 | broker | 消费者全挂 / 消费太慢 → 积压 |
| Unacked | 已推给消费者，等 ack | 消费者的代码逻辑 | 忘了 ack / 消费逻辑死循环 → prefetch 配额被占光，队列堵死 |
| 死信 | 经 DLX 转投死信队列 | TTL 到期、requeue=false、长度超限时 drop-head 丢弃的队头 | 没配 DLX → 直接丢弃；死信队列没人消费 |

### 最常见卡住场景

- **Celery worker 被 kill -9 后任务直接消失**：默认 early ack（收到即确认 = 至多一次）——关键任务换 acks_late（不丢但可能重），并按"会被执行两次"设计。（SCENARIOS.md §6，详见 [programming/06 §5 任务生命周期](../02-programming/06-celery-task-queue.md)）
- **任务偶发被执行两次**：消费超时触发重投——本质就是状态机从 Unacked 被拉回 Ready 重走一遍，业务侧必须幂等兜底。（同上）

### 从图中看出的 SRE 价值

图上每个箭头旁都有一条"丢失通道"：confirm 保发布段、持久化保 broker 段、ack 保消费段——**可靠性是三道闸的组合，少开任何一道，RPO 就漏在那一节**；而 ack 模式与 requeue 的选择，决定故障时消息落在"重投（可能重）"还是"丢弃（可能丢）"哪一边。

### 深入

[rabbitmq/01 · AMQP 模型](../13-middleware/rabbitmq/01-amqp-model.md)：§3 可靠性三道闸、§3.3 消费端 ack/nack/reject 与 prefetch、"常见坑"表。

---

## 8. Flink 作业

### 状态图

```
  提交 ──► [CREATED] ──JobManager 申请 slot、部署算子──► [RUNNING]
                                                        │    ▲
                              周期性（checkpoint 间隔）： │    │ 重启策略允许：
                              barrier 从 source 向 sink  │    │ 从 last checkpoint
                              传播，全算子快照状态        │    │ 恢复状态 + source
                                                        ▼    │ 回拨 offset 重放
                                                   [RESTARTING]
                                                        ▲    │ 重试次数耗尽
                                                        │    ▼
              任何阶段（CREATED/RUNNING/RESTARTING）  [FAILED]（终态：救不回来，只能
              用户 cancel：                              修好后从 checkpoint/
              │                                         savepoint 重跑新作业）
              │ RUNNING 下另一种停法：先触发 savepoint
              │ （只对运行中的作业有效——FAILED 的作业
              │  做不了 savepoint），状态落到稳定存储后
              ▼
        [CANCELED] ──从 savepoint 恢复：新作业带旧状态启动──► [CREATED→RUNNING]

        （没有任何边流入 FAILED；cancel 的终点永远是 CANCELED）
```

### 状态说明

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
|---|---|---|---|
| RUNNING | 正常消费，checkpoint 周期性推进 | JobManager 调度 | 反压：barrier 走不动 → checkpoint timeout |
| RESTARTING | 按重启策略等待重试，随后从 checkpoint 恢复 | 重启策略（fixed-delay / failure-rate / exponential） | 恢复点太旧 → 重放量大；算子没固定 .uid() → 状态对不上 |
| CANCELED | 用户主动停止；savepoint 版本留有状态 | 用户 / Operator | 状态目录指向容器内 file:///tmp → Pod 重建状态全丢 |
| FAILED | 重试耗尽或不可恢复错误 | 重启策略判死 | 代码 bug、状态损坏 |

### 最常见卡住场景

- **checkpoint 一直 timeout/failed，反压面板全红**：反压让 barrier 走不动——找第一个 busy 打满（新版 1.13+ 看 busyTimeMsPerSecond ≈1000ms/s；老版 UI 没有 busy 概念，只有 Backpressure 标签 ok/low/high）的算子（受害者不背锅），治它而不是调大 checkpoint 超时。（SCENARIOS.md §4，详见 [flink/02 §6 反压](../14-data-streaming/flink/02-deployment-and-exactly-once.md)）
- **Pod 重建后作业状态全丢；savepoint 恢复报 cannot map**：状态目录写进了容器内 file:///tmp；算子没固定 .uid() 导致状态映射失败。（同上，"常见坑"）

### 从图中看出的 SRE 价值

**checkpoint 间隔 = 故障时的重放窗口**（at-least-once 的那段重复数据量），**checkpoint 成功耗时 + 重放耗时 = 作业级 RTO**；savepoint 则是升级/迁移时唯一的手动锚点——间隔调小买 RTO 和小重放，付出的是常态带宽与状态后端压力。

### 深入

[flink/02 · 部署架构与 Exactly-once](../14-data-streaming/flink/02-deployment-and-exactly-once.md)：§2 JobManager HA、§3 Checkpoint 全流程、§4 重启策略、§8 作业升级与 savepoint 恢复。

---

## 收尾：8 条状态机的共同骨架

| 组件 | "Leader"状态 | 谁废黜它 | 检测时钟（≈RTO 下限） | 数据缺口（RPO 承载点） |
|---|---|---|---|---|
| etcd | Leader | quorum（check-quorum） | election-timeout | 已提交日志（quorum 保证不丢） |
| Kafka | 分区 Leader | controller | session/lag 超时 | ISR 之外的滞后（unclean 才丢） |
| Redis | 主库 | Sentinel leader | down-after-milliseconds | 断线期间写入（backlog 接住） |
| MySQL | Primary | 人工/编排 | 复制延迟即窗口 | 未传到的 binlog（半同步堵这个） |
| PostgreSQL | Primary | Patroni（DCS 租约） | DCS TTL | 复制槽 pin 住的 WAL |
| RabbitMQ | —（无主） | — | 消息级：TTL/ack 超时 | confirm+持久化+ack 三道闸 |
| Flink | —（作业级） | 重启策略 | checkpoint 间隔 | 上个 checkpoint 之后的事件 |

八张图共用三句话：**检测靠超时，恢复靠多数派或检查点，代价记在 RTO 或 RPO 的某一栏**。调任何一个参数（election-timeout、down-after、TTL、checkpoint 间隔），都是在把代价从一栏搬到另一栏——搬之前想清楚业务更能承受哪一栏。

## 自测

1. etcd 把 election-timeout 从 1000ms 调到 5000ms，脑旋消失但主库故障时写中断变长。为什么这笔账躲不掉——两头的代价分别记在 RTO 还是误判率上？
<details><summary>答案</summary>
调大超时 = 提高误判门槛（磁盘抖动不再触发切主），代价是真实故障的确认时间变长 → 写中断（RTO）拉长。反之调小 = RTO 短但误切频繁。两个代价不能同时消除，因为"慢"和"死"在超时模型里无法区分——这是故障检测的物理极限（详见 19-distributed/01 与 03）。</details>

2. Redis 从库断线 60s 后重连，主库写流量 20MB/s。要让这次重连走部分重同步，repl-backlog-size 至少要约多大？调到这个量级有什么代价？
<details><summary>答案</summary>
60s × 20MB/s ≈ 1.2GB，backlog 至少要 ≥1.2GB 才保证 offset 未被覆盖。代价是主库常驻多占这么多内存（每个主库一份环）。配不起就让全量同步接住：评估 fork 耗时与 RDB 传输带宽对主库的冲击。</details>

3. MySQL 半同步 rpl_semi_sync_master_timeout 到期自动降级异步。为什么说半同步是"半"而不是"全"？降级瞬间提交的事务 RPO 是多少？
<details><summary>答案</summary>
半同步只保证"至少一个从库**收到** binlog"（IO 层），不保证重放完成（SQL 层），更不保证多数派——所以叫半。降级瞬间起回到异步语义：主库宕机时未传出的 binlog 全丢，RPO = 从那一刻起的复制延迟窗口。</details>

4. PostgreSQL failover 后，旧主为什么不能直接拉起来重新当 standby，而要 pg_rewind？跳过这步会发生什么？
<details><summary>答案</summary>
promotion 产生新时间线，集群后续写入都在新时间线上；旧主本地还有旧时间线上"已作废但已提交"的 WAL。直接重挂，旧主会拒绝（时间线分叉），强行为之则可能出现两边各有一段对方没有的历史（分裂）。pg_rewind 按新主的检查点回卷差异，把旧主对齐到新时间线。</details>

5. Flink 从 last checkpoint 恢复时，checkpoint 之后到故障点之间的输入数据会怎样？端到端 exactly-once 靠什么把这段重放的副作用消掉？
<details><summary>答案</summary>
source（如 Kafka consumer）把 offset 回拨到 checkpoint 记录的位置，这段数据被**重放**——状态正确但下游会看到重复。exactly-once 靠 sink 侧两阶段提交（事务/幂等写入以 checkpointId 为锚）把重复吸收掉；sink 不配合就是 at-least-once，业务必须幂等。</details>

## 延伸阅读

- etcd 超时调优：https://etcd.io/docs/latest/tuning/
- Kafka 副本配置：https://kafka.apache.org/documentation/#replication
- Redis 复制：https://redis.io/docs/latest/operate/oss_and_stack/management/replication/
- Redis Sentinel：https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/
- MySQL 半同步复制：https://dev.mysql.com/doc/refman/8.0/en/replication-semisync.html
- PostgreSQL 温备与流复制：https://www.postgresql.org/docs/current/warm-standby.html
- Patroni：https://patroni.readthedocs.io/
- RabbitMQ 确认与死信：https://www.rabbitmq.com/docs/confirms 、https://www.rabbitmq.com/docs/dlx
- Flink checkpoint：https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/state/checkpoints/
