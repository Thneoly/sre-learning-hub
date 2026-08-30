# 06 · Gossip、成员管理与脑裂防护：fencing 为什么不可省

> 模块：17-distributed ｜ 建议时长：3.5 小时 ｜ 关联认证：—（无直接考点；但"为什么 K8s 用 list-watch 不用 gossip""分布式锁为什么要 fencing token"是终面高频题，答案都在本章）

## 学习目标

- 能描述 Gossip 的传播模型（周期、两两、收敛于 O(log n) 轮）与它的成员管理/故障检测一体化设计
- 能回答"K8s 为什么选 list-watch 而不是 gossip"：从一致性要求、唯一写入口、事件可靠性三个角度
- 能对照固定超时与 φ-accrual 两种故障检测的取舍，说出 etcd / Kafka / Cassandra 各自的选择
- 能用时序图讲清"旧 Leader 复活"问题，解释为什么 quorum 防不住它、fencing token 为什么必须存在
- 能说明共识集群扩容为什么要逐台/一次一个（ZK 与 etcd 两条路径）

## 1. Gossip 传播模型

Gossip（epidemic protocol / SWIM 家族）像传谣言：每个节点周期性地（如 1 秒）挑一个**随机**邻居交换消息（PING/PONG），消息里捎带自己已知的成员表与状态变更。一轮里知道消息的节点下一轮各自再去传染别人：

```
轮次      已知节点数（每轮每人传染 1 个邻居）
  0            1
  1            2        ← 收敛速度是指数的：
  2            4          O(log n) 轮后全集群得知
  3            8
  ...        ...
  k          2^k       1000 节点 ≈ 10 轮（秒级）

特点：无中心、无单点、对丢包容忍（下一轮总会再传）；
     代价：概率性、最终一致、无全序——"最终大家都会知道"，但
          谁先谁后、多久到达，都没有保证。
```

它天然把两件事合在一起做：**成员管理**（谁在集群里）与**故障检测**（谁失联了）。已学系统里的活例子是 Redis Cluster：节点间走专用 cluster bus（端口 = 服务端口 + 10000），用 gossip 交换节点与槽视图——MEET 加入、PING/PONG 每秒向随机节点探活、FAIL 判定需要**半数以上 master** 认为某节点失联（避免个别节点的误判扩散），原文见 [11-middleware/redis/02-persistence-and-ha.md](../11-middleware/redis/02-persistence-and-ha.md) §7.1。注意这个精妙的双层结构：**传播用概率性的 gossip，决策用过半票**——gossip 负责"知情"，quorum 负责"定罪"。

SRE 视角的三条运维推论：

| 特性 | 好处 | 坏处 |
|---|---|---|
| 无中心 | 加节点即扩展，没有元数据瓶颈 | 集群视图各节点**短暂不一致是常态**，排障时问不同节点可能得到不同答案 |
| 概率传播 | 丢包不致命，下一轮补 | 状态变更到达时间不可预测，不能用来做"必须马上全集群生效"的事 |
| 两两心跳 | 故障检测内建 | 心跳本身成为负载；节点数大时要控制 fanout 与消息大小 |

## 2. 为什么 K8s 选 list-watch 而不是 gossip

同一台机器上，Redis Cluster 用 gossip 管元数据，K8s 坚决不用。这是"一致性要求决定技术选型"的最佳教材：

| 维度 | K8s（etcd + list-watch） | Gossip 集群（如 Redis Cluster） |
|---|---|---|
| 一致性模型 | etcd 是**线性一致**的唯一天真相；resourceVersion 给全局全序 | 概率性最终一致，集群视图秒级窗口内各节点不同 |
| 写入口 | **只有 kube-apiserver 能写**，顺序由 etcd 唯一决定（[04-k8s/02 章 §2](../04-k8s-fundamentals/02-architecture-and-control-loop.md)） | 任一节点都可接受本节点负责的写，无全局序 |
| 事件可靠性 | watch 事件带 RV，断线重连从上次 RV 继续；RV 被压缩则 410 Gone，客户端**重新 list 全量**再续（[02 章 §6.2](../04-k8s-fundamentals/02-architecture-and-control-loop.md)） | 消息可能未达，靠下一轮重传，无"恰好一次"事件语义 |
| 适用负载 | 控制面：低频写、强一致、事件不能丢 | 数据面：高频状态交换、容忍短暂不一致 |

关键在**控制回路对输入的要求**：scheduler 和 controller 的每一步决策都依赖"当前集群状态"，如果这个状态是通过 gossip 概率收敛来的，两次读可能看到不同世界，调度决策就不可复现、不可审计。所以 K8s 的做法是：状态唯一真相放进共识存储（etcd，第 03 章），变更以**可靠事件流**（watch + RV + 410 重 list）推给消费者；Informer 的本地缓存虽然是"最终一致的副本"，但它的**序**来自全局 resourceVersion——这与 gossip 的"无序收敛"有本质区别。list-watch 与 Informer 的完整机制（不轮询的理由、事件流、RV 重连）在 [04-k8s-fundamentals/02 章 §6](../04-k8s-fundamentals/02-architecture-and-control-loop.md)，本章不重复展开。

一句话面试答案：**gossip 用概率换去中心化，适合"最终都一致就行"的数据面元数据；K8s 控制面的每一步决策都要求确定性输入与可审计顺序，所以把状态放进共识存储、用可靠事件流推送——一致性要求不同，不是谁更先进**。

## 3. 故障检测：从固定超时到 φ-accrual

"节点挂了"永远只能靠**超时推断**（第 01 章故障模型的结论：你不能区分"慢"与"死"）。工程上有两档：

**固定超时**：心跳间隔 T，超过阈值判死。etcd（`--election-timeout=1s`，心跳 100ms）、Kafka（`session.timeout.ms`）、ZK（tickTime 派生）全是这派。优点：判定时延可预测、实现简单；缺点：阈值是拍出来的——设短了网络一抖就误杀（引发不必要的选举/切换），设长了真故障要干等。

**φ-accrual（增量式怀疑度）**：不给二元判决，给一个连续的"怀疑度" φ。做法是为每个节点维护历史心跳间隔的分布（均值+方差，Hayashibara 2004 论文用正态近似），当前等待时长代入分布算出"这次间隔这么长有多反常"：

```
φ = -log10( P(下一次心跳还要等更久) )

φ = 1   ⇒ 10% 可能是"正常波动"（网络例行抖动）
φ = 3   ⇒ 0.1% 可能是波动 —— 基本可以定罪
φ = 8   ⇒ 10^-8 —— 铁证如山
```

阈值 Φ 定多少，运维按"能容忍多久检测延迟"来选。**它自适应**：某节点网络方差大，它的分布被"撑宽"，同样 3 秒没心跳算出的 φ 更低，不会轻易被误杀。代表实现是 Cassandra 的 PhiConvictor 与 Akka；etcd/Kafka 这类**小仲裁集群（3~7 成员）**反而选固定超时，因为成员少、路径短，超时可以标定得很准，而 φ-accrual 的"判定时刻不可预测"在共识选举里是缺点（选举时延要可预期）。

两条已学的极端对照，夹出这条谱系：

- **HDFS DataNode 判死约 10.5 分钟**（2×300s recheck + 10×3s 心跳，[16-bigdata/01-hdfs.md](../16-bigdata/01-hdfs.md) §3）——几千台机器、副本已有 3 份，误杀的代价（无意义补副本风暴）远大于晚判；
- **etcd 1 秒**——3~5 个成员、磁盘级心跳，晚判的代价（控制面无主）大于误杀。

**面试答法**：故障检测的本质是"误杀率 vs 检测延迟"的取舍，参与者越多、副本越冗余，越该往保守调；φ-accrual 只是把这份取舍从"拍一个全局阈值"改成"按每个节点的历史分布自适应"。

## 4. 脑裂的防护术

### 4.1 脑裂与 quorum 前提

脑裂（split-brain）指一个集群分成两半，**各自都认为自己是合法的"主侧"**。共识系统的防法在 [16-bigdata/06-zookeeper.md](../16-bigdata/06-zookeeper.md) §3 有完整推导（"同一 epoch 内过半互斥 = 数学上保证至多一个能提交的 Leader"）：少数派永远凑不齐过半 ACK，写卡死不提交；分区恢复后旧侧以更高 epoch 为准同步，未提交事务被 TRUNC。**宁可停写，不可双写**——这是 quorum 系统的立场。Mongo 副本集两节点挂一个不能写，就是这条立场的日常表现（[11-middleware/mongodb/02-replicaset-and-sharding.md](../11-middleware/mongodb/02-replicaset-and-sharding.md) 常见坑）。

但要注意 Redis 的特殊性：**数据面（主从复制）本身没有 quorum**，防脑裂靠外挂的哨兵多数派（failover 授权要 majority，[redis 02 章 §6.2](../11-middleware/redis/02-persistence-and-ha.md)）。所以旧 master 在分区期间仍可能继续吞写，愈合后这些数据全部丢失——防护参数 `min-replicas-to-write 1` + `min-replicas-max-lag 10` 的作用是"旧主侧没有同步正常的 replica 时拒绝写"，官方语义也明确：**缩小损失窗口，不是消除脑裂**（[redis 02 章 §6.4](../11-middleware/redis/02-persistence-and-ha.md)）。

### 4.2 旧 Leader 复活：quorum 防不住的那一类

脑裂的孪生兄弟不需要网络分区，一次长 GC 就够了：

```
t0  L1 是 leader，持有"我可以写下游"的心理授权
t1  L1 发生长 GC（或 VM 挂起、或短暂分区），心跳停了
t2  集群其余成员超时 → 选出 L2（term 更高）→ 业务切到 L2
t3  L2 写下游：扣款、发货、更新状态
t4  L1 从 GC 中醒来 —— 它不知道 t2/t3 发生过，
    认为自己还是 leader，把手里的旧请求继续写下游！
    （它写的是基于旧状态的决策：重复扣款 / 覆盖新数据）
```

quorum 在 t2 已经尽职了：L1 醒来后**永远不可能再提交任何共识日志**（term 太旧，被立即降级）。但注意 t4——L1 对**下游系统**（数据库、消息队列、第三方接口）的写不经过共识协议，quorum 管不到它。这就是 zombie writer（僵尸写者）问题，也是"分布式锁拿到就万事大吉"这一错觉的粉碎点（[16-bigdata/06-zookeeper.md](../16-bigdata/06-zookeeper.md) §2 的运维警示原文）。

### 4.3 租约 lease：有时限的授权

租约把"权威"变成带 TTL 的凭证：leader 从共识集群领取 lease，续租靠心跳，lease 到期即失去授权。已学例子：etcd 的 Lease（TTL 秒级，服务端统一计时；K8s 的 node heartbeat 用的是 K8s API 层的 Lease 对象、Event 靠 apiserver 的 `--event-ttl` 清理——同为租约思想，但不在 etcd 服务端 Lease 之上）、Kafka 的 `session.timeout.ms`（消费者不心跳就被踢出组）、Flink JobManager HA 的 lease（[flink 02 章 §2](../12-data-streaming/flink/02-deployment-and-exactly-once.md)）。它把 t4 的裸奔窗口从"永远"压缩到"一个 TTL"，但有两个残余问题：

1. **时钟依赖**：如果租约的判断依赖本地时钟（到期时间到了没？），时钟跳变会造成两侧同时认为自己持有（或都认为没有；漂移与跳变的机理见 [01-failure-models-and-time.md](./01-failure-models-and-time.md) §2）——所以生产实现要么用心跳往返（etcd lease 由服务端统一计时），要么要求单调时钟；
2. **边界窗口仍在**：TTL 之内的旧持有者依然可能正在写（它还没到期）。把 TTL 缩到毫秒？心跳与网络的抖动立刻变成频繁误切换。**租约只能把僵尸窗口变窄，不能清零**——清零要靠下一小节。

### 4.4 Fencing token：让旧主"写不进去"

终极手段不在持有者一侧，而在**下游一侧**：每次授权附一个**单调递增的令牌**（term、epoch、zxid 高位、事务号），下游存储记住"我见过的最大令牌"，收到旧令牌的写**直接拒绝**：

```
t2  L2 获授权，令牌 = 7（etcd 里就是更高的 term）
t3  L2 写下游（带 token=7）→ 下游记录 last_token=7，接受
t4  L1 醒来，写下游（带 token=6）→ 下游比对 6 < 7 → 拒绝！
    旧 Leader 复活，但它的笔已经没水了。
```

令牌的单调性由共识协议免费提供（term/epoch 本来就单调），所以 fencing 的成本几乎全在**下游肯校验**这一件事上。已学的三处化身：

| 系统 | 令牌 | 下游校验 |
|---|---|---|
| HDFS NameNode HA | ZKFC 抢锁带 epoch，JournalNode 拒绝旧 epoch 的写 | 共享 edits 的 JournalNode（[16-bigdata/06 章 §2](../16-bigdata/06-zookeeper.md)） |
| Kafka 事务 | `transactional.id` 的递增 epoch | broker 的 transaction coordinator（第 04 章防僵尸 producer） |
| ZK 分布式锁 | znode 的 version / czxid | 需要业务下游自己实现（把令牌随写请求带上） |

三件套的分工总结（面试可以直接背）：**quorum 保证"至多一个现任"（防分区双主）；lease 保证"过期即失效"（压缩僵尸窗口）；fencing 保证"前任写不进去"（下游强制单写）**。只有第一件是协议自带的，后两件要设计者显式去做——见过太多系统做了 quorum 就宣布"不会脑裂"，死在 t4。

## 5. 成员变更与弹性

共识集群的扩容比数据系统麻烦，因为**"过半"的定义本身变了**。两条已验证的路径：

**ZooKeeper：静态配置，逐台重启**。[16-bigdata/06 章 §6.5](../16-bigdata/06-zookeeper.md) 给了五条完整原因，骨架是：① 成员表写在每台 zoo.cfg 里，改了要重启才生效；② 3→4 节点多数派从 2 变 3，滚动窗口内若两台同时在"新配置重启中"，可能凑不齐任何一侧多数派 → 集群不可写；③ 3→4 容错不变（还是 1），扩容应直接 3→5；④ 新节点 dataDir 必须为空（旧 epoch 数据会让它拒绝加入）；⑤ 动态 reconfig 免手工，但"一次一台、确认同步"原则不变。

**etcd：在线成员 API，一次一个**。注意 `etcdctl member add` 默认直接添加**投票成员**——新成员一上线就立刻改变过半算术，这正是扩容窗口的风险所在。更安全的路径是显式 `--learner`：新成员先以 learner（学习者，不投票）身份加入，追平数据后再用 `etcdctl member promote` 提升为投票成员，把"扩容窗口内 quorum 被稀释"的风险降到最低。同样只做单成员变更（第 03 章自测 2 的双多数派反例），同样遵守 3→5 跳过 4。

对照出弹性差异：**共识成员（etcd/ZK）扩容是"外科手术"，数据分片成员（Redis/Kafka/HDFS 节点）扩容是"搬砖"**——前者要保证任意时刻在线成员凑得齐两侧的过半，后者只需操心数据迁移量（第 05 章）。这也是为什么 K8s 控制面扩容（加 master）要做"先加入 etcd、再起 apiserver、最后 LB 切流"的分步滚动。

## 实战演练

两个演练：在 K8s 上亲眼看到 list-watch 的可靠事件流；用 Redis 把"误删锁"与"fencing 拒绝旧主"完整演一遍。

```bash
# [master] 演练 1：看见 list-watch（而不是轮询）
kubectl get pods -n kube-system -v=6 2>&1 | grep -oE 'GET https://[^ ]+' | head -3
# 预期：形如 GET https://172.30.30.21:6443/api/v1/namespaces/kube-system/pods?limit=500
#       —— 这是一次 list（拿全量+当前 resourceVersion）

# 终端 A：持续 watch（事件对象是新增出来的，表格持续追加行）
kubectl get events -A -w
# 终端 B：制造一批变更
kubectl -n default run netcheck --image=busybox:1.36 --restart=Never -- sleep 60
# 回终端 A：netcheck 的 Pulled/Created/Started 等事件逐行推送——
# 没有"每秒轮询"，只有一次 list + 一条长连接 watch

# [master] 断线语义：Ctrl+C 断开再续上，从上次 RV 之后的事件开始；
# 若间隔太久 RV 被压缩，客户端会收到 410 Gone 并自动重新 list（机制见 04-k8s/02 章 §6.2）
```

```bash
# [任意节点] 演练 2：锁的误删与 fencing（docker 起 Redis）
docker run -d --name fence-redis -p 63902:6379 redis:7-alpine
R() { docker exec fence-redis redis-cli "$@"; }

# 场景 A：旧持有者醒来，误删了别人的锁
R SET lock:job1 token-T1 NX PX 5000     # 预期：OK（T1 拿到锁，5s 过期）
sleep 6                                  # T1 假装长 GC；锁已到期
R SET lock:job1 token-T2 NX PX 5000     # 预期：OK（T2 已合法接管）
R DEL lock:job1                          # T1 醒来直接 DEL —— 预期：(integer) 1
                                         # 删掉的是 T2 的锁！T3 现在也能拿到锁，双主开端

# 场景 B：正确解锁 = 比对令牌再删（Lua 保证原子）
R SET lock:job1 token-T2b NX PX 5000
R EVAL "if redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end" 1 lock:job1 token-T1
# 预期：(integer) 0 —— T1 的旧令牌删不动别人的锁
R EVAL "if redis.call('get',KEYS[1])==ARGV[1] then return redis.call('del',KEYS[1]) else return 0 end" 1 lock:job1 token-T2b
# 预期：(integer) 1 —— 持有者本人才能解锁
```

```bash
# [任意节点] 演练 3：fencing token 拒绝旧主（下游校验的现场证明）
# 令牌发生器：每次授权递增（真实系统里由共识 term/epoch 免费提供）
R INCR fencing:job1    # 预期：(integer) 1  ← T1 被授予令牌 1
sleep 1
R INCR fencing:job1    # 预期：(integer) 2  ← T1 超时，T2 被授予令牌 2

# 下游存储的校验逻辑（Lua 原子执行）：令牌必须严格大于已见过的最大值
R EVAL "local c=redis.call('get',KEYS[1]) or 0; \
if tonumber(ARGV[1])>tonumber(c) then redis.call('set',KEYS[1],ARGV[1]); return 1 \
else return 0 end" 1 downstream:job1 2
# 预期：(integer) 1   ← T2（令牌 2）的写被接受，last_token=2
R EVAL "local c=redis.call('get',KEYS[1]) or 0; \
if tonumber(ARGV[1])>tonumber(c) then redis.call('set',KEYS[1],ARGV[1]); return 1 \
else return 0 end" 1 downstream:job1 1
# 预期：(integer) 0   ← T1 复活，带着旧令牌 1 重放写入 —— 被下游拒绝！

# [任意节点] 清理
docker rm -f fence-redis
```

验证方法：演练 1 的 `-v=6` 输出证明"一次 list + 一条 watch 长连接"；演练 2 场景 A 删掉别人的锁、场景 B 删不动，两行输出对照；演练 3 的最后一次返回 0 就是 fencing 的全部意义——**旧 Leader 复活，写不进下游**。与第 03 章演练 3（pause 旧 leader、unpause 后自动降级）连起来看：协议层的 term 压制 + 应用层的令牌校验，才是完整的双主防线。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| "拿了 Redis/ZK 锁就认为绝对安全"，偶发重复扣款 | 锁只解决"互相知情"，旧持有者 GC 后继续写下游（zombie writer） | 下游加 fencing token 校验；锁超时 > 最长业务暂停（[16-bigdata/06 章 §2](../16-bigdata/06-zookeeper.md)） |
| 用 SETNX 拿锁，释放时直接 DEL | 误删他人锁（自己已超时，锁已被接手） | SET 带 token + Lua 比对再删（演练 2 场景 B） |
| 分布式锁的超时按"平均耗时"设 | 长尾（GC/慢查询）必然超时，锁易主后双写 | 按最坏情况设 + 看门狗续期；根治靠 fencing |
| lease 判断写在客户端本地时钟上 | NTP 步进/时钟回拨，两侧同时认为持有 | 服务端统一计时（etcd lease 模式）或单调时钟；时钟问题见第 04 章自测 5 |
| 观察到各节点元数据短暂不一致，判定为故障 | gossip 的集群视图本来就是概率收敛 | 以多数派/leader 视图为准；确认 FAIL 判定要过半（redis §7.1） |
| 共识集群加节点后写不进 | 滚动窗口凑不齐新配置的过半 | 一次加一台、确认同步再下一台；3→5 不走 4（[16-bigdata/06 章 §6.5](../16-bigdata/06-zookeeper.md)） |
| 心跳超时照抄别的系统（如把 1s 用到几千节点集群） | 误杀率与集群规模/网络方差强相关 | 按第 3 节谱系取舍：节点多副本多往保守调（HDFS 10 分钟），小仲裁往灵敏调（etcd 1s） |

## 自测

1. Redis Cluster 已经用 gossip 同步节点与槽视图了，为什么 FAIL 判定还要"半数以上 master 同意"？
<details><summary>答案</summary>

gossip 负责"知情"，不负责"定罪"。单个节点的失联判断可能来自它自己的网络问题（它能连别人，却连不上目标节点，或相反），如果任何一个节点都能单方面标 FAIL，一次网络抖动就会误杀健康节点并触发不必要的故障转移。过半票把"我认为它挂了"升级为"多数节点都观察到它挂了"，把局部视角合成集体判断——这和哨兵的 ODOWN 要 quorum、授权要 majority 是同一个模式（[redis 02 章 §6.2](../11-middleware/redis/02-persistence-and-ha.md)）。
</details>

2. 如果 K8s 改用 gossip 分发 Pod 事件，最先出问题的会是什么场景？
<details><summary>答案</summary>

依赖"顺序与完整"的控制回路先坏：例如 controller 依据事件维护期望副本数——gossip 消息乱序到达或延迟，两个 controller 实例可能基于不同版本的世界做决策，出现重复创建/漏删；watch 断线后没有"从某个全序位点继续"的机制（410 → 重新 list），事件缺口无法可靠补齐，Informer 的"本地缓存 = 集群状态副本"这一前提不成立。本质是控制面要线性一致+可靠事件流，而 gossip 只承诺概率性最终一致（第 2 节对照表）。
</details>

3. 为什么 etcd 选固定超时而 Cassandra 选 φ-accrual？互换会怎样？
<details><summary>答案</summary>

etcd 是 3~7 成员的小仲裁：心跳路径短、延迟可标定，固定超时的"检测延迟可预测"对选举至关重要（脑裂窗口 = 超时上限，必须确定）；φ-accrual 的自适应在这里收益小、还让选举时延不可预期。Cassandra 是成百上千对等节点、跨机房网络方差大：固定阈值要么误杀高方差节点、要么对低方差节点反应迟钝，φ-accrual 按每节点历史分布自适应，正好对症。互换：etcd 用 φ 会让选举时间抖动不可控；Cassandra 用小集群式固定 1s 超时会在跨机房抖动下频繁误判节点下线，触发不必要的数据修复流量。
</details>

4. min-replicas-to-write 已经防了 Redis 脑裂，为什么还必须说它是"缩小窗口"？
<details><summary>答案</summary>

它的判定条件是"至少 min 个 replica 的 lag ≤ max-lag"。反例：分区时恰好有一个 lag 很小的 replica 留在旧主侧，条件满足，旧主照常吞写，分区期间的数据在愈合后仍会全丢（旧主被降级、全量同步覆盖）。另一个边界是 lag 上报本身依赖旧主的视图。所以它防的是"旧主在完全无 replica 确认时继续写"这一最大头的情况，是概率与窗口的收缩，不是一致性保证——官方语义与 [redis 02 章 §6.4](../11-middleware/redis/02-persistence-and-ha.md) 的边界说明一致。
</details>

5. 你的服务用 etcd 选主（Lease + 乐观锁），Leader 每次写 MySQL 时带上 etcd 的 revision 当 fencing token。这有什么问题？提示：revision 单调吗？与"读到的时刻"有什么竞争？
<details><summary>答案</summary>

两个坑。① revision 的取得与使用之间有竞争：Leader A 拿到 revision=100，随后失主，B 拿到 101——但 A 手里还是 100，用它写 MySQL 会被拒，这没问题；可如果 A 是"读"了一个旧 revision 而非"随授权获得"的，令牌与授权就不绑定，校验形同虚设。令牌必须来自"授权动作本身"（竞选成功那次事务的 term/revision），不能是随手读的状态。② MySQL 侧必须有"只接受更大令牌"的原子校验（一列存 last_token + 条件更新），只把 token 写进日志不算 fencing。正确做法正是演练 3 的 Lua/条件更新模式：令牌来自授权、下游原子比对、拒绝不大于当前值的写。
</details>

## 延伸阅读

- SWIM 论文（gossip 故障检测与成员管理的源头）：https://www.cs.cornell.edu/~asdas/research/dsn02-SWIM.pdf
- φ-accrual 故障检测论文（Hayashibara et al., SSN 2004）：https://link.springer.com/chapter/10.1007/978-3-540-27836-3_23
- Cassandra Phi Convictor 配置：https://cassandra.apache.org/doc/latest/cassandra/configuration/cass_yaml_file.html
- etcd Lease API（服务端计时的租约）：https://etcd.io/docs/latest/dev-guide/api_reference_v3/
- etcd member 管理（learner 与在线变更）：https://etcd.io/docs/latest/op-guide/runtime-configuration/
- Kubernetes API 概念（resourceVersion 与 watch 语义的官方定义）：https://kubernetes.io/docs/reference/kubernetes-api/api-concepts/
- Kleppmann《How to do distributed locking》（fencing token 的经典论述）：https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html
