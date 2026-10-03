---
title_juejin: '节点挂了，集群怎么知道：超时两难与 SWIM 两路打听'
title_zhihu: '心跳超时没有正确答案：SWIM 把拍脑袋的死刑判决，改成了可撤销的死缓'
description: '心跳超时两难、SWIM 两路打听、gossip 捎带传播、suspect 两阶段可撤销、Raft 选举超时分工、fencing token 兜底、etcd 与 K8s Lease 对照。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686341072617242662"
---

# 节点挂了，集群怎么知道：心跳超时的两难与 SWIM 的两路打听

半夜告警群里最贵的一句话是："这台节点应该挂了，重启吧。"——"应该"两个字，值一次事故复盘。分布式系统里没有任何人能直接看见对面那台机器的死活，能做的只有一件事：等一个超时。

而超时设多短，是一道怎么答都错的选择题。设短了，一次网络抖动就是一场误杀：健康节点被踢出去，触发一轮毫无必要的选举。设长了，真死的节点要干等几分钟才被发现，恢复窗口被活活拉长。

这篇把这条线索一次讲全：超时判定的根本两难、SWIM 的两路打听、membership 靠 gossip 捎带传播、suspect 到 down 的两阶段撤销、它与 Raft 选举超时的分工，最后落到 fencing 为什么必须存在。

## 1. 超时永远是在猜：完美故障检测不存在

故障模型里这叫遗漏故障：消息会丢、心跳会断。超时只能证明"期限内没收到应答"，它区分不了三种情况——对方进程挂了、网络断了、对方在长 GC。

所以宕机判定永远是在猜，猜错只有两个方向：把活人判死（引发一次没必要的 failover），或者把死人判活（拉长脑裂窗口）。不存在同时消灭两个错误的阈值。

**完美故障检测不存在，超时是在误杀率和检测延迟之间选边站**。

两个极端对照，夹出整条谱系。HDFS 判死一个 DataNode 要约 10.5 分钟（2×300 秒 recheck 加 10×3 秒心跳没收到）——几千台机器、副本已有 3 份，误杀引发补副本风暴的代价远大于晚判。

etcd 只要 1 秒（`--election-timeout=1s`）——3~5 成员的小仲裁，晚判的代价是控制面无主，大于误杀。

还有一类最阴险的伪装者：时序故障。JVM 一次长 GC 让节点 30 秒没发心跳，别人以为它挂了，它醒来还以为自己是 Leader——ZooKeeper 把"脑旋"第一元凶排在 JVM 长 GC，就是这个机理。慢，是所有故障检测的天敌。

工程界对这个两难有三层回应：不动阈值动证据（SWIM 两路打听）、不给二元判决给怀疑度（φ-accrual）、把误判变可撤销（suspect 两阶段）。挨个看。

## 2. SWIM 的两路打听：一个人说它死了，不算数

SWIM 是 gossip 成员管理协议的源头（Cornell，DSN 2002）。它的故障检测拆成两问。

第一路，直接 ping：每个协议周期，节点挑一个成员发 PING，对方回 ACK。收到了，活着，下一轮。

第二路才是精髓：直接 ping 没回，先别定罪，发起 ping-req——请另外 k 个成员也去 ping 它。k 份间接探查都失败，才记一次失联【第三方转引，SWIM 论文 DSN，2002】。

这一步为什么值钱？"我连不上你"有相当一部分概率是"我和你之间"的问题：一条烂网线、一次拥塞、一段抖动的链路。而 k 个不同位置的成员都连不上你，指向的就只能是你自己。

**两路打听不动阈值，动的是证据数量**——把一个人的证词，升级成多个证人的交叉证词。

这是你早就见过的模式：哨兵先 SDOWN（主观下线，一个哨兵的猜测）再问一圈凑够 quorum 才 ODOWN（客观下线）。分布式里降低猜错代价的思路永远是一个：多节点交叉验证，过半才动手。

## 3. membership 靠 gossip 捎带：讣告不另派邮差

判定了"它挂了"，下一个问题是：怎么让全集群知道。SWIM 的答案是不专门发消息——成员状态变更直接 piggyback（捎带）在每个协议周期的 PING 与 ACK 里，跟探活流量同车出行。

传播是指数级的：每一轮，知情者各自再传染一个新节点，O(log n) 轮后全集群得知，1000 个节点约 10 轮，秒级。好处是无中心、无单点、对丢包容忍（这轮丢了下轮补）；代价是概率性、最终一致、无全序——谁先知道、多久知道，都没有保证。

活例子是 Redis Cluster：节点间走专用的 cluster bus（端口 = 服务端口 + 10000），MEET 加入，每秒向随机节点 PING/PONG 顺带交换节点与槽视图；而 FAIL 判定要半数以上 master 都认为某节点失联。

注意这个双层结构：**gossip 负责「知情」，quorum 负责「定罪」**。任何一个节点都能单方面标 FAIL 的话，一次网络抖动就会顺着 gossip 把误判扩散到全集群。

用 docker 三分钟亲眼看一遍"知情"和"定罪"（bash 整段粘贴）：

```bash
docker network create fd-net 2>/dev/null
for i in 1 2 3; do
  docker run -d --name fd-rc$i --network fd-net redis:7-alpine \
    redis-server --cluster-enabled yes --cluster-announce-ip fd-rc$i \
    --cluster-announce-port 6379 --cluster-announce-bus-port 16379
done
docker exec fd-rc1 redis-cli --cluster create \
  fd-rc1:6379 fd-rc2:6379 fd-rc3:6379 --cluster-replicas 0 --cluster-yes
# 预期：[OK] All 16384 slots covered.

docker exec fd-rc1 redis-cli cluster nodes
# 预期：三行，flags 均为 master，槽区间 0-5460 / 5461-10922 / 10923-16383
```

模拟一次"长 GC"：pause 住 fd-rc2（进程冻结、心跳断流），等默认 cluster-node-timeout（约 15 秒【从业者判断，以官方文档为准】）走完：

```bash
docker pause fd-rc2 && sleep 25
docker exec fd-rc1 redis-cli cluster nodes | grep -c ',fail'
# 预期：1 —— fd-rc2 被标 fail，这就是"半数以上 master 认定"的定罪时刻
docker exec fd-rc3 redis-cli cluster nodes | grep ',fail' | awk '{print $3}'
# 预期：master,fail —— 另一个幸存者视图一致（gossip 已收敛）
docker unpause fd-rc2 && sleep 8
docker exec fd-rc1 redis-cli cluster nodes | grep -c ',fail'
# 预期：0 —— 它活着回来了，全程没有触发任何不可逆动作
for i in 1 2 3; do docker rm -f fd-rc$i; done; docker network rm fd-net
```

这一分钟里，本篇的主角全部出场：单节点失联只是私下怀疑，过半 master 都探不到才升级 FAIL（两路打听的集群版）；被误判的节点回来后自动恢复，因为定罪前的每一步都可逆。

运维推论照抄：gossip 集群的视图短暂不一致是常态，排障时问不同节点可能得到不同答案——以多数派视图为准，别看到两个节点答案不同就判定集群坏了。

## 4. suspect 到 down：把死刑改成死缓

单阶段判死的真正问题不是快，是不可逆：死亡宣告一旦经 gossip 扩散出去，撤销的成本极高——所有收到讣告的节点，都要再收一次"复活声明"。

SWIM 的解法是两阶段【第三方转引，SWIM 论文 DSN，2002】：探查失败先标 suspect（可疑），带上一个超时时钟；怀疑状态本身靠 gossip 捎带扩散。如果嫌疑人其实活着——它会在捎带消息里看到自己被点名——它可以申辩，撤销怀疑。超时走完仍无音讯，才宣告 down。

**两阶段不是拖时间，是把误判从「事故」降级为「虚惊」。**

同方向的另一个解法是 φ-accrual：不给二元判决，给连续怀疑度。为每个节点维护历史心跳间隔的分布（均值加方差），当前等待时长代入分布，算出"这么久没心跳有多反常"：φ=3 意味着只有 0.1% 可能是正常波动，基本可以定罪。

它自适应——网络方差大的节点，分布被撑宽，同样 3 秒没心跳算出的 φ 更低，不会被轻易误杀。代表是 Cassandra 的 PhiConvictor 和 Akka。

那 etcd 为什么反着来，用固定超时？因为它拿到的牌不一样：3~7 成员的小仲裁，心跳路径短、延迟可以标定得很准；而选举要的是"判定时刻可预期"——脑裂窗口等于超时上限。φ-accrual 判定时刻不可预测，在共识选举里恰恰是缺点。

固定超时这一派（etcd 1 秒、Kafka 的 `session.timeout.ms`、ZK 由 tickTime 派生）赢在简单和可预期。

## 5. 与 Raft 选举超时的分工：检测层与恢复层

把 SWIM 和 Raft 摆在一起，最容易混的是"超时"这个词。gossip 系统里检测和恢复是两层：SWIM 只回答"谁失联了"（membership 层）；失联之后谁接班、数据怎么办，是另一套机制的事。

Raft 把两层焊死在一个参数上：follower 等不到 leader 心跳、超过 election timeout，这个超时既是对"leader 可能挂了"的检测推断，也是"我来竞选"的发令枪。心跳 100ms、选举超时 1 秒，一个数字同时驱动两层【从业者判断】。

这个焊死的结构有条工程推论：任何让心跳发不出去的因素，都等价于变相缩短超时。磁盘慢拖垮日志落盘、GC 停顿、CPU 饥饿——所以共识集群调优的方向从来不是把超时改小，而是治慢。

K8s 是第三种答案：干脆不搞节点间两两打听。kubelet 周期性向 apiserver 续一个 Lease 对象（node heartbeat 就是续租），到期由控制面统一裁决；Event 靠 apiserver 的 `--event-ttl` 清理，同为租约思想【从业者判断，控制器细节以官方文档为准】。

为什么 K8s 不用 gossip 干这件事？控制面的每一步决策（调度、扩缩容）都依赖"当前集群状态"的确定性与可审计顺序；gossip 只承诺概率性最终一致，两次读可能看到两个世界。一句话：gossip 适合「最终一致就行」的数据面元数据，**控制面要的是共识存储加可靠事件流**。

## 6. 检测永远有漏网之鱼：fencing 为什么必须存在

前五节再精巧，也只解决"集群知道"。有一类问题任何检测都兜不住——检测层的判决，管不到节点对集群之外的写。看最经典的时间线，一次长 GC 就能造出来：

```text
t0  L1 是 leader，持有写下游的授权
t1  L1 发生长 GC，心跳停了
t2  其余成员超时 → 选出 L2 → 业务切到 L2
t3  L2 写下游：扣款、发货
t4  L1 从 GC 中醒来——它不知道 t2/t3 发生过，
    认为自己还是 leader，把旧请求继续写下游
```

quorum 在 t2 已经尽职：L1 醒来后永远不可能再提交任何共识日志（term 太旧，立即降级）。但 t4 那一笔对下游（数据库、消息队列、第三方接口）的写不经过共识协议，quorum 管不到。这就是 zombie writer。

三件套的分工背下来：quorum 保证"至多一个现任"；lease 保证"过期即失效"（etcd Lease 服务端统一计时，TTL 秒级）——但它只能把僵尸窗口压到一个 TTL，不能清零。

fencing 保证"前任写不进去"：每次授权带一个单调递增令牌（term/epoch 天然就是），下游记住见过的最大令牌，旧令牌的写直接拒绝。

**令牌单调性由共识协议免费提供，成本全在下游肯校验。**

一个构造典型案例（时序是真实模式）：结算服务用 etcd Lease 选主，写 MySQL 带 revision 做 fencing token。一次 60 秒长 GC 后，新主持令牌 89 上位；旧主醒来，MySQL 写被拒（88 < 89）——fencing 生效了。

但代码把"被拒"当成可重试错误，退避重试继续跑；而异步通知路径根本没挂校验，旧主的"扣款成功"通知继续外发。结果双发通知 37 笔，9 笔被下游幂等键挡住，28 笔进人工对账。

两条教训，各值一次复盘（分布式锁那篇的坑四清单里是同两条，这里从检测侧再钉一遍）：**fencing 的强度等于最弱一条写路径的强度**；下游"拒绝旧令牌"与旧主"被拒后死心"必须成对出现——只做前一半，旧主就换个姿势继续写。

实验沿用分布式锁那篇的同一台 fence-redis 与同一对键名——那边看锁视角，这边看检测视角。八条命令，亲手看一次"前任写不进去"：

```bash
docker run -d --name fence-redis -p 63902:6379 redis:7-alpine
R() { docker exec fence-redis redis-cli "$@"; }

R INCR fencing:job1    # 预期：(integer) 1  ← 旧主拿到令牌 1
sleep 1
R INCR fencing:job1    # 预期：(integer) 2  ← 旧主超时，新主拿到令牌 2

# 下游存储的原子校验：令牌必须严格大于已见过的最大值
R EVAL "local c=redis.call('get',KEYS[1]) or 0; if tonumber(ARGV[1])>tonumber(c) then redis.call('set',KEYS[1],ARGV[1]); return 1 else return 0 end" 1 downstream:job1 2
# 预期：(integer) 1  ← 新主（令牌 2）的写被接受
R EVAL "local c=redis.call('get',KEYS[1]) or 0; if tonumber(ARGV[1])>tonumber(c) then redis.call('set',KEYS[1],ARGV[1]); return 1 else return 0 end" 1 downstream:job1 1
# 预期：(integer) 0  ← 旧主复活带着令牌 1 重放——被下游拒绝
docker rm -f fence-redis
```

最后那个 0，就是 fencing 的全部意义：检测可以误、可以慢，下游的闸门不能开。

## 7. 一张对照表带走

| 系统 | 检测方式 | 阈值风格 | 判死机制 |
|---|---|---|---|
| etcd | 心跳 100ms | 固定 `--election-timeout=1s` | 超时即选举，检测恢复合一 |
| Kafka | session / replica lag 超时 | 固定 `session.timeout.ms`、`replica.lag.time.max.ms` | 判时间不判条数 |
| HDFS | 心跳 + recheck | 固定，合计约 10.5 分钟 | 极保守：误杀比晚判贵 |
| Cassandra | φ-accrual | 按每节点历史分布自适应 | φ 过阈值定罪 |
| Redis Cluster | 每秒 gossip PING/PONG | 固定 cluster-node-timeout | 半数以上 master 才标 FAIL |
| SWIM 原型 | 直接 ping + ping-req | 协议周期 | suspect 超时转 down，可撤销 |

面试一句话答法：故障检测的本质是"误杀率 vs 检测延迟"的取舍，参与者越多、副本越冗余，越往保守调；SWIM 用两路打听和两阶段把误判变成虚惊；而检测永远兜不住旧主对下游的写，最后一米要靠 fencing token。

## 现在就能做的事

五分钟路径：跑第 6 节那八条命令，亲眼看返回 0 的那一下。半小时路径：起第 3 节的三节点 Redis Cluster，pause、看 fail、unpause、看它复活——把两难、两路打听、两阶段全部踩一遍。

顺手自检三问：你们的心跳超时（`session.timeout.ms` / election timeout / cluster-node-timeout）是拍的还是按网络方差标定的？选主服务的全部出站写路径，fencing 校验一处不漏吗？校验被拒之后，是熔断下线还是当可重试错误继续跑？

这套对照表和两个实验收在我维护的 SRE 学习仓库：GitHub 搜 sre-learning-hub，分布式模块——同一章还有 φ-accrual 论文导读，以及 K8s 为什么选 list-watch 不选 gossip 的完整推导。

最后聊个实的：你们生产被"网络抖动误杀"过最贵的一次是什么？评论区讲讲时序，我挑一个画成时间线复盘。
