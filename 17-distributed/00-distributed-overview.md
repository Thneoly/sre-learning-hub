# 00 · 分布式全景：三座大山、学习地图与 CAP 的正确打开方式

> 模块：17-distributed ｜ 建议时长：2 小时 ｜ 关联认证：—（无直接考点；本章是本模块 8 章的坐标系，把已学的 etcd/Kafka/Redis/ZooKeeper/Flink 经验正式"理论化"）

## 学习目标

- 能说清网络不可靠、时钟不同步、部分故障各自摧毁了单机世界的哪条隐含假设，并各举一个已学组件的对应机制
- 能解释"超时之后不知道对方做没做"这第三种状态为什么逼出幂等重试，并举出 kubectl / Kafka 里的现成例子
- 能画出本模块 8 章的学习地图，说清 etcd / Kafka / Redis / ZooKeeper / Flink 五处已学素材分别被哪一章收拢深化
- 能纠正"CAP 三选二"的流行误读：分区是前提不是选项，取舍发生在分区期间，且同一系统里不同操作的取舍可以不同
- 能用"分区发生时谁停摆"一句话，给 etcd / ZK / Kafka(acks=all) / Redis 主从在 CAP 谱系上定位

前置约定：本模块全程不推导证明，只讲语义、代价、运维后果与面试答法。所有理论概念都先指回你在 04/08/11/12/16 模块里已经敲过的命令，交叉引用一律给相对路径。

## 1. 分布式为什么难：三座大山

单机程序的所有直觉都建立在三条隐含假设上：调用是可靠的、时钟是唯一的、故障是整体的。分布式把这三条逐条打断。

### 1.1 网络不可靠：超时不是失败，是"不知道"

单机函数调用只有两种结局：返回结果，或抛异常。跨网络的请求有**第三种状态**：客户端超时了，但服务端**可能已经执行完**——你只是没等到应答。

```
单机:   f() ──► 结果 / 异常               （二值）
分布式: f() ──► 结果 / 异常 / ??? 超时     （三值）
                        │
                        ├─ 请求没到达      → 没执行
                        ├─ 到达但没做完    → 执行了一半？
                        └─ 做完但应答丢了  → 已执行！
```

这第三种状态是半个本模块的源头：

- **它逼出重试**：超时只能重试；重试就可能重复执行 → **必须幂等**（lab 02 的主题：幂等键 / 去重表 / Flink 幂等 sink）。
- **它逼出多数派**：你永远无法区分"对方挂了"和"网络断了"，故障检测只能靠超时**猜**。既然会猜错，就不能让"一个节点的判断"决定全局——于是有了 quorum（03 章）。
- **已学证据**：`kubectl` 内部对 API 请求自带超时重试；Kafka 生产者 `acks=1` 超时重试同一批次可能写入两次，这是 `enable.idempotence` 存在的理由（`../12-data-streaming/kafka/02-replication-and-reliability.md`）。

运维后果：**一切"对下游有副作用的脚本"都必须按"可能被执行多次"来写**。你在 13-sre-methodology 学的 runbook 原则"先想回滚再敲回车"，在分布式语境里加一条"先想重放是否安全"。

### 1.2 时钟不同步：两台机器没有"同时"

单机一个时钟，事件顺序天然唯一。分布式里每个节点一块石英表，各自漂移，"谁先谁后"在物理层面就没有答案（01 章展开）：

- 跨节点 grep 日志按时间戳排序，可能出现"应答排在请求前面"；
- `Jenkins agent 时间漂移`会直接导致握手失败、agent 掉线（`../06-cicd-iac-gitops/03-jenkins-and-github-actions.md` 常见坑表）；
- Flink 干脆放弃用墙钟定义时间，改用**事件自带的时间戳 + watermark**（`../12-data-streaming/flink/01-stream-processing-model.md` 第 2/3 节）——这是"不信任物理钟"最彻底的工程化。

运维后果：**跨机时间线永远只能当参考**。排障对时间线时，先 `ssh` 各节点 `date` 对表（01 章 5 节有 SOP）。

### 1.3 部分故障：集群健康不是 0/1

单机挂了就是全挂，重启即恢复。分布式里故障是**部分的**：3 个 etcd 挂 1 个，集群照常读写；挂 2 个，写不行，串行读（`--consistency=s`，读本成员 KV）仍可应答——lab 01 第 7 步实测的正是这个行为。对照 ZooKeeper 版的曲线：

```
ZK 3 节点（../16-bigdata/06-zookeeper.md 第 3 节）
挂 0 台:  读写正常
挂 1 台:  过半(2/3)仍在，读写正常，可用性以少数派退出为代价
挂 2 台:  只剩 1 台不足过半 —— 进入 LOOKING 持续选举，不再服务任何
          客户端请求（读写都停，除非显式开 readonlyModeEnabled，默认关）
```

部分故障的三个推论：

1. **"服务是否可用"变成程度问题**：要问"几个 9 的什么操作"？写入可用还是读取可用？（etcd 挂 2 台时写被拒、串行读仍能从本地应答；ZK 同样失 quorum 后则读写都停。）
2. **故障与性能不可分**：一个 GC 停顿 30 秒的 follower，在别人眼里和死机无法区分——性能毛刺会升级成故障误判，ZK"脑旋"的第一元凶就是 JVM 长 GC（同上 06 章 4 节）。
3. **恢复不是"重启就好"**：崩溃恢复型系统（etcd/ZK/Kafka/MySQL）重启后要重放日志追进度，落后太多会被 TRUNC 截掉未提交事务（ZK）或被移出 ISR（Kafka）。数据目录是它们的命根子。

### 1.4 对照表：单机世界不存在的问题

| 单机的隐含假设 | 分布式的现实 | 已学组件的应对 | 本模块哪章展开 |
|---|---|---|---|
| 调用要么成功要么失败 | 超时后"做没做成不知道"（第三种状态） | Kafka `enable.idempotence`；etcd 客户端重试 | 04 / 07 章 + lab 02 |
| 全局唯一时钟，顺序天然存在 | 各节点时钟各走各的，日志顺序不可比 | Flink event time + watermark；OTel 单调钟算 span 耗时 | 01 章 |
| 故障是整体的，重启即恢复 | 一半活一半死，"健康"是程度问题 | etcd 多数派，挂 2/3 停写但串行读仍可应答 | 01 / 03 章 |
| 状态由 OS 的 fsync 保证即可 | 状态复制到多机，副本可能落后、可能脑裂 | Kafka ISR + HW；Redis `min-replicas-to-write` 脑裂防护 | 02 / 03 章 |
| 进程间通信近零延迟 | 网络延迟/带宽是第一约束，跨机房放大百倍 | list-watch 增量代替轮询；etcd 建议同机房 | 06 章 |
| 加锁 = 内核互斥量，锁了就安全 | 锁的持有者可能"死后复活"（zombie writer） | ZK fencing token（czxid/version 当令牌） | 06 章 + lab 02 |

### 1.5 为什么工程上都是"超时 + 多数派"：FLP 一句话

理论里有个著名结论（FLP 不可能定理）：**异步网络 + 哪怕只有一个崩溃故障，就不存在"保证在有限时间内出结果"的确定性共识算法**。不推导，记它的工程后果就够了——正因为"完美地分清死活"不可能，所有真实系统都在做三件妥协：

1. **放弃完美故障检测**：用超时判死活，接受误判；
2. **放弃全员共识**：只要求多数派（quorum）同意，少数派的意见直接作废——这也是 3/5/7 奇数部署的根本原因（`../16-bigdata/06-zookeeper.md`："3 → 4 反而降低可用性"）；
3. **用随机化/任期号打破僵局**：Raft 的随机选举超时、ZAB 的 epoch、哨兵的 epoch，都是"让僵局必然自解"的手段。

## 2. 学习地图：把五处已学素材收拢成理论

### 2.1 八章地图

```
理论地基本章+01+02                    理论主体03~06                       落地
┌────────────────────────┐   ┌───────────────────────────────┐   ┌─────────────┐
│ 00 全景/CAP(本章)      │   │ 03 共识与复制: Raft/ZAB/ISR    │   │ 07 排障方法论 │
│ 01 故障模型与时钟       │ ─►│ 04 分布式事务: 2PC/快照/幂等   │ ─►│    (lab 01/02 │
│ 02 一致性模型阶梯       │   │ 05 分片与再平衡: 槽/哈希/范围  │   │     贯穿全程) │
└────────────────────────┘   │ 06 Gossip/成员关系/围栏        │   └─────────────┘
        ▲                    └───────────────────────────────┘
        │ 全部概念先有实现样本再给名字
┌───────┴─────────────────────────────────────────────────────────────┐
│ 已学素材: etcd(04章) Kafka(12模块) Redis(11模块) ZK(16模块) Flink(12模块)│
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 收拢表：每个组件贡献了什么分布式机制

| 组件 | 已讲的机制（出处） | 对应的理论名字 | 本模块哪章深化 |
|---|---|---|---|
| **etcd**（K8s 控制面） | Raft 写路径、多数派提交、串行读/线性读、WAL 与 fsync（`../04-k8s-fundamentals/13-cluster-admin-and-etcd.md` 第 2 节） | 共识协议 / 线性一致 / 崩溃恢复 | 02 / 03 章 + lab 01（kill leader 亲测选举） |
| **Kafka** | ISR 动态收缩、HW/LEO、`min.insync.replicas`、KRaft、murmur2 分区（`../12-data-streaming/kafka/02-replication-and-reliability.md` 第 3 节） | 主备复制 / 顺序一致 / 分片路由 | 02 / 03 / 05 章 |
| **Redis** | 哨兵 quorum 与 majority 两阶段判定（SDOWN/ODOWN）、16384 槽、gossip cluster bus（`../11-middleware/redis/02-persistence-and-ha.md` 第 6 节起） | 故障检测 / 一致性哈希之辩 / gossip 成员关系 | 05 / 06 章 |
| **ZooKeeper** | ZAB 的 epoch>zxid>myid 选举、过半提交、脑裂防护、fencing token（`../16-bigdata/06-zookeeper.md` 第 3 节） | 共识 / 全序广播 / 租约与围栏 | 03 / 06 章 |
| **Flink** | barrier 对齐的分布式快照（Chandy-Lamport）、KafkaSink 两阶段提交（`../12-data-streaming/flink/02-deployment-and-exactly-once.md` 第 3/5 节） | 分布式快照 / 2PC / exactly-once 语义 | 04 章 |

三个"配角"也各有贡献：**MySQL 半同步**（`../11-middleware/mysql/02-backup-replication.md` 半同步复制一节）是"弱化版 2PC 单方面确认"；**MongoDB 副本集**（`../11-middleware/mongodb/02-replicaset-and-sharding.md` 第 4 节）给了 writeConcern/readConcern 这套"按请求选一致性"的最好样本；**双实例 Alertmanager**（`../08-pca/05-alerting-alertmanager.md` 6.2 节）是最终一致 + gossip 反熵的活标本。

### 2.3 三个反复出现的"同一个定理"

学本模块时留意，很多"不同组件的知识"其实是同一条定理换衣服：

1. **多数派互斥**：ZK 的"过半 ACK 才提交"、etcd Raft 的多数派确认、哨兵的 majority 授权、MongoDB 的多数派当选——同一个定理的四个化身（ZK 章 3 节原话："同一 epoch 内过半互斥 = 数学上保证至多一个能提交的 Leader"）。03 章统一直观。
2. **单领导者日志**：Kafka 每分区一个 leader、ZK 写全走 Leader、etcd 写转发 leader——"先让所有人同意顺序，再谈别的"。03 章的全序广播。
3. **显式元数据优于隐式哈希**：Redis Cluster 用 16384 槽而不用一致性哈希、Kafka 用显式分区副本分配而不用一致性哈希——都是"把数据归属变成可枚举、可迁移、可对账的元数据"。05 章展开。

## 3. CAP 的正确打开方式

### 3.1 三个字母到底各指什么

| 字母 | 严格含义 | 一句话翻译 |
|---|---|---|
| C（Consistency） | 线性一致（linearizability，02 章精确定义） | 写成功应答之后，**任何人**从**任何节点**读，都必须看到这次写（或更晚的写） |
| A（Availability） | 每个发到**非故障**节点的请求，最终都要得到非错误应答 | 节点活着就得回话，不许"拒接" |
| P（Partition tolerance） | 网络可以丢消息、无限延迟 | 节点间消息可达性没有保证 |

注意 C 的定义极窄：它**不是** ACID 里的 C（那是一致性约束），**不是**"数据不丢"（那是持久性），也**不是**"多副本内容一样"（那是收敛/复制完整）。

### 3.2 分区不是选项

"三选二"的第一处错误：P 不是你可以不选的。只要数据分布在多台用网络连接的机器上，**分区就必然可能发生**——交换机故障、网卡 flap、跨 AZ 光纤被挖断、甚至一次长 GC 让心跳全部超时。放弃 P 的唯一方法是回到单机，而单机不构成分布式系统。

所以真正的问题永远是：**分区发生的那一刻，C 和 A 你保哪个？**

```
                     分区发生(P 是前提, 不是选项)
                              │
              ┌───────────────┴───────────────┐
        保 C（拒绝服务）                保 A（继续应答）
              │                               │
   少数派一侧停写停读,               两半各自用本地旧数据应答,
   宁可不可用不可两说               分区愈合后再互相收敛(反熵)
              │                               │
   etcd/ZK 少数派拒绝写              Redis 主从、DNS、
   (ZK 章 3 节的"宁可停写")          双实例 Alertmanager、MongoDB w:1
```

### 3.3 取舍只发生在分区期间——且同一系统内可以不同

- **没有分区时，C 和 A 可以兼得**：3 个 etcd 成员网络健康时，既线性一致又全部应答。此时的代价换成了**延迟**（线性读要多数派确认一次）——这正是 PACELC 的洞见：**P 时选 A 或 C；无 P 时（Else）选延迟（L）或一致性（C）**。etcd 的串行读/线性读开关，就是一次明码标价的 ELC 交易（`../04-k8s-fundamentals/13-cluster-admin-and-etcd.md` 2.1 节：串行读快但可能旧值）。
- **同一系统不同操作取舍不同**：etcd 默认线性读，但客户端可显式 `--consistency=s` 降级；MongoDB 按 readConcern/writeConcern 逐请求选择；Kafka `acks=0/1/all` 逐生产者选择。**"系统 X 是 CP"这类整体标签，粒度粗到只能当聊天的开场白**。

### 3.4 常见误读表

| 误读 | 为什么错 | 正确说法 |
|---|---|---|
| "CAP 是三选二的选择题" | P 不是选项，是前提；单机"CA"不属于分布式 | 分区期间的 C/A 取舍，且通常按操作粒度逐个做 |
| "MySQL 单机是 CA" | 单机没有分区问题，谈不上在 CAP 里注册 | CAP 只描述多副本网络系统的分区行为；主从异步复制的 MySQL 在分区期间保 A 丢新写入 |
| "Cassandra/AP、etcd/CP，标签即真相" | 同一系统不同操作可不同；无分区时兼得 | 标签只描述"分区时默认倾向"，要落到具体操作的配置项 |
| "CP 就一定慢，AP 就一定快" | 无分区时 CP 系统的代价是每次多一轮往返，不是不可用 | 代价是可量化的延迟（线性读 vs 串行读），可按请求付钱 |
| "最终一致在 CAP 之外" | 最终一致就是分区/延迟期间选 A 的自然产物 | "最终"是可监控的工程参数（02 章 4 节：收敛与反熵） |
| "强一致 = 数据绝对不丢" | 线性一致讲"读到什么顺序"，不讲盘上留不留 | 持久性由 fsync/副本数/acks 决定，两者正交 |

### 3.5 面试怎么答

四句话框架，比背标签高一个层次：

1. 先纠偏："CAP 不是三选二，分区是分布式的前提，取舍只在分区期间发生。"
2. 给定义："C 是线性一致——写应答后任何节点都必须读到；A 是非故障节点必须应答。"
3. 落组件："etcd/ZK 是分区时保 C 的代表：少数派拒绝写，宁可不可用不可双写（ZK 挂 2/3 停写就是现场）。Redis 主从异步是保 A 的代表：分区两侧都能应答，愈合后收敛，代价是旧主上未复制的写入丢失。"
4. 加分项：补 PACELC——"无分区时的常态权衡其实是延迟 vs 一致性，etcd 的串行读/线性读就是明码标价的开关"，再补一句"Kafka 的 acks/min.insync.replicas 是把这笔账交给业务逐主题配置"。

## 实战演练

本章不做破坏性操作，只在练习集群上找三座大山的证据。

**演练一：亲眼看一次"第三种状态"**

```bash
# [master] 把客户端超时压到 5ms：客户端报错，但 apiserver 侧请求多半已被处理
kubectl get namespaces --request-timeout=5ms 2>&1 | head -2
# 预期输出类似：Error from server (Timeout): ...（措辞随版本略有差异）
# 若居然成功了，把 5ms 改成 1ms 再试——本地回环上偶尔能抢出来

# [master] 对照：正常请求的真实耗时（-v=6 会打印每个 HTTP 请求的往返毫秒数）
kubectl -v=6 get namespaces 2>&1 | grep -E "round_trippers.*(GET|OK in)" | head -3
# 预期输出（节选）：GET https://172.30.30.21:6443/api/v1/namespaces?limit=500 200 OK in N milliseconds
```

读请求超时无所谓；**把第一个命令想象成 `kubectl apply`**——报错之后你并不知道对象建没建成，只能 `get` 回查。这就是重试必须幂等的全部原因。

**演练二：量化两台节点的墙钟差**

```bash
# [master] 三行连着跑：本地时刻 → worker 时刻 → 本地时刻
date +%s.%N
ssh cka000002 'date +%s.%N'
date +%s.%N
# 解读：worker 的值应落在两次本地采样之间；差值 ≈ 时钟偏差 + ssh 单程耗时
# 健康标准：同机房 NTP 管理下的节点差值在几十毫秒以内

# [master] 确认 NTP 同步状态（Ubuntu 默认 systemd-timesyncd；装了 chrony 则用 chronyc tracking）
timedatectl | grep -E "synchronized|NTP|Time zone"
# 预期：System clock synchronized: yes / NTP service: active
#（旧版 systemd 的字段名是 "NTP synchronized"，以实际输出为准）
```

**演练三：看部分故障的"程度"——各成员进度的差异**

```bash
# [master] 复用 13 章的 ectl 包装（../04-k8s-fundamentals/13-cluster-admin-and-etcd.md 2.2 节）
ectl() {
  kubectl -n kube-system exec etcd-"$(hostname)" -- sh -c \
    "ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
--endpoints=https://127.0.0.1:2379 $*"
}
ectl endpoint status --cluster -w table
# 预期：每个成员一行，看 RAFT INDEX 列——leader 最大，follower 通常略小
# 这就是"部分故障/部分落后"的常态：集群健康，但各成员进度不同
# 单 master 练习集群只有一行，3 成员视角留给 lab 01（kill leader 实测）
```

验证方法：三个演练分别拿到"超时报错 + 正常耗时行"、"毫秒级时钟差"、"成员间 RAFT INDEX 差异"即通过。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 脚本超时重试后数据重复 | 把超时当失败，重试不带幂等键 | 下游按业务键去重；写路径设计成幂等（lab 02） |
| 跨节点日志时间线"因果倒置" | 各节点墙钟有偏差，按时间戳归并 | 先对表确认偏差量；关键链路用 trace_id 串联（01 章 5 节） |
| "集群健康"却报错 | 只看 pod 数/进程数，没看 quorum | 健康检查要区分"进程在"与"过半在"（ZK 的 Mode、etcd endpoint health） |
| 面试答"我们系统是 CP"被追问卡壳 | 标签粒度太粗 | 换成"分区时哪个操作停、哪个继续"的具体描述（3.5 节框架） |
| 拿 CAP 的 C 解释事务回滚 | C 是线性一致，不是 ACID 的 C | 两套词汇分开：一致性模型管读写顺序，隔离级别管事务交错（02 章 2 节） |
| 以为加了副本就不丢数据 | 副本可能是异步的、落后的 | 问两个数：确认条件（quorum/acks/WAIT）与当下复制延迟（02 章 4 节） |

## 自测

1. 为什么"超时"和"失败"在分布式里是两回事？举一个你已经配置过的、专门为这件事设计的参数。
<details><summary>答案</summary>

超时只说明"客户端在期限内没等到应答"，服务端可能：没收到、正在做、已做完但应答丢失。三者后续动作完全不同。专为此设计的参数例：Kafka `enable.idempotence=true`（broker 按 PID+序号去重，让生产者敢于重试）；etcd/Redis 客户端的重试上限；MySQL 半同步的 `rpl_semi_sync_master_timeout`（超时降级，明确"不等了"）。核心是：凡是会重试的路径，执行方必须幂等。
</details>

2. etcd 3 成员挂 2 台后"串行读还行、写不行"（lab 01 第 7 步实测），这在 CAP 框架里怎么描述？为什么说它同时证明了"部分故障让可用性变成程度问题"？同场景下 ZK 的表现有什么不同？
<details><summary>答案</summary>

分区/失去 quorum 期间，etcd 的写路径选择保 C：写必须过半提交，剩余单成员无法满足，于是停写——这是"拒绝服务保一致"。但客户端把读显式降级为串行读（`--consistency=s`，读本成员 KV）时，读仍能应答，只是数据可能陈旧——同一系统里写操作保 C、（弱保证的）读操作近似保 A。这正是"可用性是程度问题"的实例：不是简单的 up/down，而是"哪类操作、在什么一致性级别下可用"。追问读己之写，则连读也不可用，需要 quorum 恢复。对照：ZK 失去 quorum 后剩余成员（无论原 Leader 还是 follower）进入 LOOKING 持续选举，默认不服务任何客户端请求——读写都停（除非显式开启 readonlyModeEnabled，默认关闭）；"失 quorum 后本地读仍可用"不是 ZK 的行为，是 etcd 串行读的行为。
</details>

3. 有人说"我们的系统是 CA，因为从来没用过分区功能"。这句话错在哪两层？
<details><summary>答案</summary>

第一层：P 不是功能开关，是多机+网络的固有属性——只要副本间靠网络同步，分区就可能发生（交换机、网卡、跨机房链路、长 GC 都能造出"逻辑分区"）。第二层："CA"若指无分区时 C 与 A 兼得，这描述的是常态而不是分区时的取舍；一旦真分区，系统必然表现出保 C 或保 A 之一，只是当事人没观察到分区而已。正确表述应指出分区时的行为。
</details>

4. PACELC 说"无分区时是延迟与一致性的取舍"。用 etcd 的两个读模式和一个你已经配过的 Kafka 参数各举一例。
<details><summary>答案</summary>

etcd：串行读（`--consistency=s`）直接读本成员 KV，省掉 ReadIndex 的多数派往返，快但可能旧值；线性读（默认）多一次确认，慢但强一致——同一集群按请求付钱。Kafka：`acks=1` 只等 leader 本地落盘（低延迟、leader 宕机有丢失窗口），`acks=all`+`min.insync.replicas=2` 等 ISR 确认（高延迟、已确认消息不丢）。两者都是"用延迟买一致性/持久性"的明码标价。
</details>

5. FLP 说共识不可能完美终止，但 etcd 天天在终止。工程上做破了 FLP 的哪条前提？
<details><summary>答案</summary>

FLP 的前提是"异步网络 + 至多一个崩溃故障 + 确定性算法 + 必须无条件有限时间终止"。工程系统逐条妥协：用超时把"异步"部分变成"有界的部分同步"；用随机化选举超时（Raft）打破确定性要求的对称僵局；用多数派允许少数派节点永久故障仍出结果；并接受极端场景下不可用（ZK 失去 quorum 时停写）而不是给出错误结果——放弃的是"始终可用"这个 FLP 意义上的终止保证，换取"可用时必正确"。
</details>

## 延伸阅读

- Brewer 的 PODC 主旨报告（CAP 提出的原始场合）：https://people.eecs.berkeley.edu/~brewer/cs262b-2004/PODC-keynote.pdf
- Gilbert/Lynch 对 CAP 猜想的证明（Brewer's Conjecture, SIGACT News 2002）：https://groups.csail.mit.edu/tds/papers/Gilbert/Brewer2.pdf
- Kleppmann《Please Stop Calling Databases CP or AP》：https://martin.kleppmann.com/2015/05/11/please-stop-calling-databases-cp-or-ap.html
- Jepsen 一致性模型图鉴（各一致性级别的严格定义与违反示例）：https://jepsen.io/consistency
- FLP 不可能定理原文（Impossibility of Distributed Consensus with One Faulty Process, JACM 1985）：https://groups.csail.mit.edu/tds/papers/Lynch/jacm85.pdf
- DDIA 第 5/8/9 章（复制、一致性、分布式系统问题）：https://dataintensive.net/
