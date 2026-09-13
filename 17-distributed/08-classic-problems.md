# 08 · 经典不可能性与算法：两将军、拜占庭、FLP 与分布式快照

> 模块：17-distributed ｜ 建议时长：3.5 小时 ｜ 关联认证：—（无直接考点；四个经典结果是 00~07 章一切工程妥协的理论出处，也是分布式终面区分度最大的一块）

## 学习目标

- 能讲出两将军问题"确认永远差一轮"的归纳论证，并说出它在 TCP 三次握手、TIME_WAIT、幂等重试、至少一次语义里的化身
- 能描述拜占庭口头算法的思想（转述 + 多数），用"过半集合的交集必须多于叛徒数"推出 3f+1，并回答"互联网公司为什么默认 CFT、区块链为什么必须 BFT"
- 能准确陈述 FLP 的前提与结论，讲清 Raft 随机超时、ZAB epoch 为什么是"把永不终止的概率压到可忽略"而不是"推翻定理"
- 能解释一致割（consistent cut）与 Chandy-Lamport 的 marker 规则，并把 Flink 的 barrier 对齐与 unaligned checkpoint 逐条映射回算法
- 能用"毁掉哪条假设 → 工程怎么妥协"的框架，给四个结果各配一个已学系统的现场

本章延续本模块的纪律：不推导证明，只讲语义、代价、运维后果与面试答法。四个结果的共同姿势是——**理论先证明"完美解不存在"，工程再花小钱把不可能绕过去**；绕的路径，你在 03/04/12 模块早就敲过命令了。

## 1. 两将军问题：为什么 ACK 永远差一轮

### 1.1 问题与归纳

两支军队分驻山谷两侧，只能派信使穿越敌占山谷；信使可能被俘（消息丢失）。约定"同时进攻才赢，单独进攻必败"。试着设计协议：

```
A 将军 ──"8 点进攻"──（信使可能被俘）──► B 将军
   ▲                                      │
   └───────────── ACK ────────────────────┘
B 想：ACK 到了吗？         → A 回 ACK 的 ACK
A 想：ACK 的 ACK 到了吗？  → B 再回一层 ACK
……
第 k 轮确认的存在，本身就制造第 k+1 轮的不确定：
无论协议跑多少轮，"最后一条消息的发送方"永远悬着——
不存在让双方同时进入"我确定你确定"状态的有限协议。
```

三点展开：

1. **难点不是"消息会丢"**（可以无限重传），而是**确认链的传递闭包闭不上**：任何一条确认自身也需要被确认，无穷递归。要的那个"都知道对方知道"的东西术语叫共同知识（common knowledge），在不可靠信道上不可达。
2. **结论的形式**：不存在保证双方一致行动的确定性协议；能做的是把"不一致的概率"压到任意小（多派几个信使），永远压不到零。
3. **与 [00 章 §1.1](./00-distributed-overview.md) 的关系**：00 章说"超时是第三种状态——不知道对方做没做"，那是两将军的**现象**；本节是它的**理论根**——不是实现不够努力，是逻辑上无解。

### 1.2 工程后果：TCP、TIME_WAIT、幂等、至少一次

| 工程物 | 它对两将军做了什么 | 一句话 |
|---|---|---|
| TCP 三次握手 | 不解决，只**收笔** | 收在"双向通路可用 + 序号同步"，不收在"对方确定知道" |
| TIME_WAIT 等 2MSL | 用**等待**把不可能变成概率足够小 | 最后的 ACK 丢了就等对端重传 FIN，等 2MSL 让旧报文自然死亡 |
| 幂等重试 | 承认重复，**消灭重复的代价** | 与其消灭不确定性，不如让重放无害（[04 章 §6](./04-distributed-transactions.md) 模式表） |
| at-least-once 语义 | 给这条妥协**正名** | "恰好一次交付"不存在，能兑现的是 exactly-once effect（[04 章 §5](./04-distributed-transactions.md)） |

TCP 的细节值得说透，因为面试最常考它：

- **为什么三次、不是两次**：两次时服务端无法确认"客户端能收到我的应答"，一个迟到的历史重复 SYN 还会让服务端单方面建起半开连接白占资源。**为什么三次就"够"**：TCP 的工程目标只是同步初始序号 + 确认双向通路可用，从来不是达成共同知识——第三包丢了靠 SYN+ACK 重传兜底，重传又造出重复，TCP 用序号在建连层把重复**消化**掉。注意这个姿势：**消化重复比消灭重复便宜**，这正是幂等重试的原理。
- **TCP 承诺的边界**：它保证"连接存活期间字节流可靠、不重不乱"。连接被 RST 掉时，内核里未 ACK 的数据直接丢弃；优雅关闭也只保证字节送到**对端内核**——对端应用处理到一半崩溃，你不知道。应用语义的确认（"这笔支付入账了吗"）必须应用层自己做，一做就回到两将军。把"TCP 可靠所以我不用管重复"说出口，就是没读懂三次握手承诺了什么。

**面试答法**："两将军说明在会丢消息的信道上，'双方都确定对方收到'需要无穷确认轮——所以恰好一次交付不存在，TCP 三次握手只是在'双向可用'这个工程目标上收笔。工程系统的正确姿势是至少一次交付 + 幂等吸收：Kafka 幂等生产者、Flink checkpoint 重放、去重表，全是这条路线。"（交付语义三档见 [04 章 §5.3](./04-distributed-transactions.md)。）

## 2. 拜占庭将军问题：从"会坏"到"会骗"

[01 章 §1](./01-failure-models-and-time.md) 的故障谱系里，拜占庭是最后一格：节点不再只是宕机或丢消息，而是**发送错误、矛盾、伪造的数据**。将军问题的设定：一个司令、若干副官，信使可靠但**成员里最多 f 个叛徒**；目标两条——IC1（所有忠诚副官执行同一命令）、IC2（若司令忠诚，忠诚副官执行他的命令）。

### 2.1 三将军一叛徒：无解的构造

3 个将军、1 个叛徒，无论叛徒是谁都无解（口头消息、不可签名）：

```
司令是叛徒：给 L1 发"攻"、给 L2 发"守"，互相转述后
  每个 L 的信息集都是 {一攻一守}，无法裁决
副官是叛徒：司令忠诚发"攻"，叛徒向 L1 转述"守"
  → L1 的信息集仍是 {一攻一守}，与"司令是叛徒"情形不可区分
平票默认设"守" → 被"忠诚司令发攻 + 叛徒转述守"击穿；
平票默认设"攻" → 被"忠诚司令发守 + 叛徒转述攻"击穿。
```

这个反例是下界的种子：**N = 3f 时无解，所以 N ≥ 3f+1 才有戏**（实战演练一会把两种平票默认都亲手跑违约一遍）。

### 2.2 口头算法 OM 与 3f+1 的直觉

**口头算法（Oral Messages）三句话**：① 司令把命令发给每个副官；② 每个副官把"我听到的"转述给其余所有副官，转述再被转述，递归 f+1 轮；③ 每个忠诚副官对最终信息集**取多数**。叛徒可以发矛盾消息、可以翻供，但 f+1 轮转述让"忠诚渠道的多数"盖过谎言。条件：**将军数 ≥ 3f+1；消息递归 f+1 轮，每轮全对全 O(N²) 条，f+1 轮总计 O(N^(f+1))（f=1 时即 O(N²)）**。

**3f+1 的两种数法**：

1. **下界来自反例**：3 将军 1 叛徒已无解；通用下界 N ≥ 3f+1。
2. **多数派数法（更有面试价值）**：N = 3f+1 时忠诚者 2f+1 个，任意两个"过半集合"（各 2f+1）交集 ≥ 2×(2f+1)−(3f+1) = f+1——**交集必然多于叛徒数**，任何两个多数派报告里都至少含一个忠诚节点，作恶无法同时骗过两边。对照 CFT（[03 章 §2](./03-consensus-and-replication.md)）：N = 2f+1、过半 f+1、交集 ≥ 1 就够——因为没人撒谎，一个诚实的交集节点就能传递真相。**BFT 比 CFT 多垫的那 f+1 个节点，买的就是"交集里保证有忠诚者"**。

### 2.3 工程后果：为什么默认 CFT、区块链为什么必须 BFT

**互联网基础设施默认 CFT 的四条理由**：

1. **故障模型现实**：机房内的敌人是"宕机 + 静默损坏"，不是"作恶"。静默损坏已有廉价防御（CRC、校验和、ECC——[01 章 §1](./01-failure-models-and-time.md) 拜占庭行），比共识协议便宜几个数量级。
2. **节点与消息成本**：容 1 故障 CFT 3 台（挂 1 可用）、BFT 4 台；容 2 故障 CFT 5 台、BFT 7 台；再叠加全对全消息与签名验证的 CPU，吞吐直接打折。
3. **拜占庭容错防不住"一致的 bug"**：同一版本代码在所有副本上**同样地**错误执行，多数派对"一致的错"无能为力——共识只会把错误一致化。真正的对策是版本多样性与灰度发布，那是发布策略不是共识协议。**BFT 防的是"分裂的谎言"，不是"一致的错误"**——评审时最值钱的一句。
4. **适用面**：需要 BFT 的场景特征是"参与方互不信任"（跨机构联盟链）或"开放准入"（公链）；信任边界内的内部系统没有它的生态位。

**区块链为什么必须 BFT**：公链里"节点身份"本身不可信——一人能伪造千个节点（女巫攻击），节点数多数派失去意义。两条出路：**PoW** 把"一节点一票"换成"一算力一票"，伪造多数的成本变成全网 51% 算力，终态是概率性的（链越深越难翻转，"6 个确认"是行业惯例非协议规定）；**PoS** 把票数换成质押额。联盟链（成员已知）用 PBFT 一类（Castro & Liskov, OSDI'99）：封闭成员、3f+1、全对全投票、秒级终态。数字签名让"翻供与伪造转述"可证伪，是把口头算法条件放宽的关键——区块链交易必须签名正源于此（细节以各链官方文档为准）。

**面试答法**："我们的故障模型是崩溃恢复 + 遗漏，用校验和兜静默损坏，所以选 CFT（Raft/ZAB），3 台容 1。BFT 的 3f+1 与全对全开销只为'成员会主动作恶'的场景付费——公链因为匿名开放必须上，内部系统上它是负资产；而且 BFT 防不住全体一致的 bug，那要靠灰度与多版本。"

## 3. FLP：异步 + 一个故障 = 没有必然终止的共识

### 3.1 定理说了什么、没说什么

[00 章 §1.5](./00-distributed-overview.md) 给过一句话版，这里把边界说准。**前提三条**：① 异步系统——消息延迟**没有上限**（但最终会送达，信道可靠）；② 哪怕只有一个节点可能崩溃；③ 算法是确定性的。**结论**：不存在同时保证安全性（一致）与活性（有限时间出结果）的共识算法。

两个常被忽略的要点：

- **敌人换了**：两将军的敌人是"会丢消息的信道"；FLP 把信道修好（消息必达），敌人换成**调度**——谁的消息先到、停多久由不得你。延迟可以无限，等于可以永远压住那条决定性的消息。
- **死的是活性，不是安全性**：证明直觉（不推导）——存在"歧义状态"（往下走既可能决定 0 也可能决定 1），调度者总能让系统停在歧义里打转。所以"可能不终止"是定理，"可能不一致"从来不是——这正是"宁可停写不可双写"的理论出处（[03 章 §2.2](./03-consensus-and-replication.md) 失 quorum 行为）。它也是 [01 章](./01-failure-models-and-time.md)"宕机判定永远是在猜"的形式化：猜不准"死了还是慢了"，就不敢贸然终止。

### 3.2 工程妥协：把"永不终止"的概率压到可忽略

00 章 §1.5 列了三句话，这里讲清**为什么有效**：

1. **注入同步性（超时 = 赌一次）**：Raft 的 election timeout 本质是给异步系统临时贴一条同步假设——"过了 1 秒没心跳，我赌它不会到了"。赌错（对方只是慢）的代价是一次无谓选举。学术版叫 failure detector（Chandra-Toueg）：把"猜死活"做成显式模块，只要"最终大致准确"，多数派共识就可解——工程实现里这个模块就是超时 + 心跳。
2. **随机化（绕过而非推翻）**：FLP 打击的是**确定性**算法——调度者能预判你的每一步，就能构造永久歧义。Raft 把选举超时随机化后，"两个 candidate 恰好同时超时"的概率逐轮指数衰减，终止概率趋于 1——定理没有被推翻（病态调度仍存在），只是被踩成概率上的尘埃。ZAB 用 `epoch > zxid > myid` 的确定性规则打破对称（[16-bigdata/06 §3](../16-bigdata/06-zookeeper.md)），拆票率靠配置不对称压低，理论上仍可能撞，实际靠错峰的启动与超时自然错开；Raft 把随机化写进协议，更稳。
3. **保 safety、舍 liveness**：失 quorum 宁可停（[03 章 §2.2](./03-consensus-and-replication.md)）——"可能暂时不可用，但可用时必正确"。FLP 没禁止共识，只禁止"永远又快又对"，真实系统选择了"对"。

### 3.3 运维后果

- **选举抖动是定理的影子，不是 bug**：一次切换 1~3 秒、偶发拆票再来一轮，正常（[03 章 §4.2](./03-consensus-and-replication.md)）。**反复**发生才是病——超时基数太小，或真实延迟分布越过了超时假设（盘慢、长 GC、网络抖动），治理对象是延迟本身（03 章"脑旋"：独立低延迟盘、控 GC、对 leader 变化告警）。
- **调超时的本质**：不是"让协议更聪明"，是让超时假设重新覆盖真实延迟分布——所以排障顺序永远是先量 fsync/GC/网络尾延迟，再谈参数。

## 4. 分布式快照：不停机拿到"一致的全局状态"

前三节都是"不可能"，本节是一个"可能且优雅"的经典算法——Flink checkpoint 的直系祖先。

### 4.1 为什么"所有节点 12:00 同时快照"不成立

两个死因：① **没有"同时"**——各节点时钟各走各的（[01 章 §2](./01-failure-models-and-time.md)）；② **拼出的状态可能不可达**：P 的快照记着"已发出 m"，Q 的快照却记着"还没收到 m"——m 凭空消失，用它做恢复或死锁检测，结论必然错。正确的约束叫**一致割（consistent cut）**：每个进程的历史切一刀，**割若包含 m 的接收，就必须包含 m 的发送**（因果闭合——[01 章 §3](./01-failure-models-and-time.md) happens-before 的应用）。一致的**全局快照 = 各进程割点状态 + 所有"跨越割的消息"**（channel 状态）。

### 4.2 Chandy-Lamport：marker 传播

算法（1985）假设 channel FIFO（marker 不会越过它之前的数据），规则三条，全程不停机：

```
P ──m1──m2──► [MARKER] ──m3──► Q      快照从 P 发起：
 1. P 记录自己的状态，随即向所有出边发 MARKER，然后照常干活（发 m3）
 2. Q 收 MARKER 之前照常收消息；收到第一个 MARKER 时记录自己的状态，
    并向自己的出边转发 MARKER
 3. Q 已快照之后、某入边 MARKER 到达之前，在该入边上收到的消息
    —— 记入这条 channel 的状态；MARKER 到齐，快照完成
```

两条关键洞见：

- **快照不对应任何真实物理时刻**：P 割在 t1、Q 割在 t2——但两刀拼出一个**"可能发生过"的全局状态**（可达状态），从它恢复继续跑，结果依然正确。这份"理论牌照"正是 Flink 从 checkpoint 回放而不心虚的底气。
- **channel 状态是算法的灵魂**：只有"发端割前发出、收端割后才收到"的消息会跨割，被 channel 状态接住，恒等式（发送侧割内 ⇔ 接收侧割内或在 channel 状态）才闭合。

### 4.3 工程化身：Flink 的 barrier（串 [12-flink/02](../12-data-streaming/flink/02-deployment-and-exactly-once.md)）

[flink 02 章 §3](../12-data-streaming/flink/02-deployment-and-exactly-once.md) 已把 checkpoint 全流程（JM 触发、source 注入 barrier、算子对齐、ACK、completed）讲完，本节只做理论对账：

| Chandy-Lamport | Flink checkpoint | 备注 |
|---|---|---|
| marker | barrier n | 同一个东西随数据流动 |
| 进程割点状态 | 算子状态快照（source 存 Kafka offset） | offset 就是"割点" |
| channel 状态记录 | **对齐下恒为空；unaligned 显式记录 in-flight 数据** | 见下 |
| 发起方任意 | CheckpointCoordinator 周期触发 | 集中点火，传播仍是去中心的 |
| 恢复 = 回到"可能的世界" | 从快照恢复 + source 重放 | 重放前提与 2PC 提交侧见 [04 章 §5.1](./04-distributed-transactions.md) 与 [flink 02 章 §5](../12-data-streaming/flink/02-deployment-and-exactly-once.md) |

**为什么对齐模式下 channel 状态恒为空**：Flink 的 channel 保序（FIFO），算子等**所有**输入的 barrier 到齐才快照——每个输入上 barrier 之前的数据此刻都已处理进状态，没有消息跨割。**unaligned checkpoint 恰恰是把 channel 状态记录复活**：barrier 一到就快照，来不及处理的 in-flight 数据（= 跨割消息）直接写进快照，恢复时先重放。所以两种模式的取舍（对齐：快照小但反压时对齐缓冲堆积；unaligned：快照大但 barrier 不被堵——[flink 02 章 §3](../12-data-streaming/flink/02-deployment-and-exactly-once.md) 原文）在算法层面就是"要不要动用 channel 状态记录"——**unaligned 反而更忠实于 1985 年的原算法**。

## 5. 收束：四个结果一张表

| 结果 | 毁掉的假设 | 理论结论 | 工程回应 | 已学现场 |
|---|---|---|---|---|
| 两将军 | 确认消息自身可靠可达 | 恰好一次交付不存在 | 至少一次 + 幂等；TCP 用序号消化重复 | Kafka `enable.idempotence`；[04 章 §6](./04-distributed-transactions.md) 模式表 |
| 拜占庭 | 节点诚实（不主动骗） | 口头消息下 N < 3f+1 无解 | 内部系统 CFT + 校验和；互不信任才 BFT | [01 章 §1](./01-failure-models-and-time.md) 故障谱系；CRC/ECC |
| FLP | 同步性（延迟有上界） | 安全与活性不可兼得 | 超时赌一次 + 随机化 + 宁停不错 | Raft 随机选举超时；失 quorum 停写（[03 章](./03-consensus-and-replication.md)） |
| 分布式快照（唯一"可能"的） | 全局时钟存在 | 一致割可纯异步构造 | marker 传播 + channel 状态 | Flink barrier 对齐 / unaligned |

读法：前三个把"你想要的保证"逐条没收，第四个示范"换一个正确的要法"。**面试的高分姿势不是背定理，而是每个定理都能指到自己在生产里维护的那个系统上**。

## 实战演练

两将军一节的"第三种状态"与幂等吸收，[00 章演练一](./00-distributed-overview.md)（`kubectl --request-timeout=5ms` 亲测超时后结果未知）与 [04 章演练](./04-distributed-transactions.md)（SQL 版幂等模式逐个执行）已经动手过，本章不重复；两个演练聚焦新算法：拜占庭的 3/4 将军分界、Chandy-Lamport 的一致割校验。环境：任意有 python3 的机器，命令标注 `[任意节点]`（本地 Windows 亦可）。

```bash
# [任意节点] 演练 1：拜占庭——3 将军必输、4 将军必稳（OM(1) 口头算法）
cat > /tmp/byzantine_demo.py <<'EOF'
def majority(votes, tie):
    a, r = votes.count("attack"), votes.count("retreat")
    return "attack" if a > r else ("retreat" if r > a else tie)

def om1(n, traitor, order, lies, tie="abstain"):
    """0=司令，1..n-1=副官。lies: ("C",j)=司令骗 j，(i,j)=副官 i 骗 j"""
    heard = {j: (lies.get(("C", j), order) if traitor == 0 else order)
             for j in range(1, n)}                      # 第一轮：司令 → 各副官
    relay = {}
    for i in range(1, n):                               # 第二轮：副官 i 把听到的转述给 j
        for j in range(1, n):
            if i == j: continue
            v = heard[i]
            if traitor == i: v = lies.get((i, j), v)
            relay[(j, i)] = v
    dec = {}
    for j in range(1, n):
        if j == traitor: continue
        votes = [heard[j]] + [relay[(j, i)] for i in range(1, n) if i != j]
        dec[j] = majority(votes, tie)
        print(f"  L{j} 信息集 {votes} -> 决定 {dec[j]}")
    ic1 = len(set(dec.values())) == 1
    ic2 = traitor == 0 or set(dec.values()) == {order}
    print(f"  IC1(忠诚者一致): {'成立' if ic1 else '违约'}  "
          f"IC2(执行忠诚司令命令): {'成立' if ic2 else '违约'}")

print("n=4, 副官2是叛徒（司令令 attack，叛徒向 L1 转述 retreat）:")
om1(4, 2, "attack", {(2, 1): "retreat"})
print("n=3, 副官2是叛徒，平票默认 attack（忠诚司令令 retreat，叛徒转述 attack）:")
om1(3, 2, "retreat", {(2, 1): "attack"}, tie="attack")
print("n=3, 副官2是叛徒，平票默认 retreat（忠诚司令令 attack，叛徒转述 retreat）:")
om1(3, 2, "attack", {(2, 1): "retreat"}, tie="retreat")
EOF
python3 /tmp/byzantine_demo.py
```

预期输出：

```
n=4, 副官2是叛徒（司令令 attack，叛徒向 L1 转述 retreat）:
  L1 信息集 ['attack', 'retreat', 'attack'] -> 决定 attack
  L3 信息集 ['attack', 'attack', 'attack'] -> 决定 attack
  IC1(忠诚者一致): 成立  IC2(执行忠诚司令命令): 成立
n=3, 副官2是叛徒，平票默认 attack（忠诚司令令 retreat，叛徒转述 attack）:
  L1 信息集 ['retreat', 'attack'] -> 决定 attack
  IC1(忠诚者一致): 成立  IC2(执行忠诚司令命令): 违约
n=3, 副官2是叛徒，平票默认 retreat（忠诚司令令 attack，叛徒转述 retreat）:
  L1 信息集 ['attack', 'retreat'] -> 决定 retreat
  IC1(忠诚者一致): 成立  IC2(执行忠诚司令命令): 违约
```

解读：n=4 时每个忠诚副官 3 票、至多 1 票被污染，多数永远成立，tie 设什么都不影响（把叛徒换成司令再试——`om1(4, 0, ...)` 发矛盾命令，仍成立）；n=3 只有 2 票，1 票被污染就是平票，**无论平票默认取攻还是守，总有一个"忠诚司令 + 叛徒副官"的世界违约**——这就是 3 将军 1 叛徒无解的构造性证明。

```bash
# [任意节点] 演练 2：Chandy-Lamport 快照推演与一致割校验
cat > /tmp/snapshot_demo.py <<'EOF'
queues = {"p2q": [], "q2p": []}       # FIFO 队列：("data", m) 或 ("marker", None)
state, snap, chan = {"P": [], "Q": []}, {}, {"p2q": [], "q2p": []}
recorded, cut, t, log = set(), {}, 0, []

def send(who, ch, m):
    global t; t += 1
    queues[ch].append(("data", m)); log.append((t, "send", who, ch, m))

def recv(who, ch):
    global t; t += 1
    kind, m = queues[ch].pop(0)
    pre = any(k == "marker" for k, _ in queues[ch])  # marker 还在后面 → 本消息发于 marker 前
    if kind == "data":
        if who not in recorded:
            state[who].append(m)
        elif pre:
            chan[ch].append(m)                       # 已快照 + 发送侧割前 → channel 状态
        log.append((t, "recv", who, ch, m))
    else:
        if who not in recorded:
            snapshot(who)                            # marker 先到：先快照，本 channel 记空

def snapshot(who):
    global t; t += 1
    recorded.add(who); snap[who] = list(state[who]); cut[who] = t
    queues["p2q" if who == "P" else "q2p"].append(("marker", None))

send("Q", "q2p", "n1")   # 1
send("P", "p2q", "m1")   # 2
recv("P", "q2p")         # 3  n1 割内（P 尚未快照）
snapshot("P")            # 4  P 的割；marker 入 p2q
send("P", "p2q", "m2")   # 5  P 割后发送
send("Q", "q2p", "n2")   # 6  Q 割前发送
recv("Q", "p2q")         # 7  m1 割内
recv("Q", "p2q")         # 8  marker → Q 快照；marker 入 q2p
recv("P", "q2p")         # 9  n2：P 已快照且 n2 发于 marker 前 → channel 状态
recv("Q", "p2q")         # 10 m2：割后数据，两边都不记
recv("P", "q2p")         # 11 marker → 快照完成

print("快照结果:")
for w in "PQ":
    print(f"  {w} 状态 = {snap[w]}   (割在事件 {cut[w]})")
print(f"  channel p2q = {chan['p2q']}   channel q2p = {chan['q2p']}")
sends = {m: tt for tt, ev, w, ch, m in log if ev == "send"}
recvs = {m: tt for tt, ev, w, ch, m in log if ev == "recv"}
snd  = {"n1": "Q", "m1": "P", "m2": "P", "n2": "Q"}   # 各消息的发送/接收方
rcv  = {"n1": "P", "m1": "Q", "m2": "Q", "n2": "P"}
chof = {"n1": "q2p", "m1": "p2q", "m2": "p2q", "n2": "q2p"}
print("\n一致割校验（发送侧割前 ⇒ 接收侧割前 或 在 channel 状态）:")
ok = True
for m in ("n1", "m1", "n2", "m2"):
    pre_s, pre_r = sends[m] < cut[snd[m]], recvs[m] < cut[rcv[m]]
    where = ("割内→计入接收方快照" if pre_s and pre_r else
             ("跨割→在 channel 状态" if pre_s else "割外→不进快照"))
    good = (not pre_s) or pre_r or (m in chan[chof[m]])
    ok = ok and good
    print(f"  {m}: 发@{sends[m]}({'割前' if pre_s else '割后'}) "
          f"收@{recvs[m]}({'割前' if pre_r else '割后'})  {where}  {'OK' if good else 'X'}")
print("校验通过" if ok else "校验失败")
EOF
python3 /tmp/snapshot_demo.py
```

预期输出（事件号由脚本内的全局时钟计数，逐行对得上）：

```
快照结果:
  P 状态 = ['n1']   (割在事件 4)
  Q 状态 = ['m1']   (割在事件 9)
  channel p2q = []   channel q2p = ['n2']

一致割校验（发送侧割前 ⇒ 接收侧割前 或 在 channel 状态）:
  n1: 发@1(割前) 收@3(割前)  割内→计入接收方快照  OK
  m1: 发@2(割前) 收@7(割前)  割内→计入接收方快照  OK
  n2: 发@6(割前) 收@10(割后)  跨割→在 channel 状态  OK
  m2: 发@5(割后) 收@11(割后)  割外→不进快照  OK
校验通过
```

验证方法：两组输出各对一遍——① n=4 全成立、n=3 两种平票默认各违约一次；② 四条消息的分类与恒等式成立。再把演练 2 的 `snapshot("P")` 挪到 `send("P","p2q","m2")` 之后重跑，观察 m2 从"割外"变"割内"、n2 仍在 channel——亲手造一个不同的合法快照。Windows 本机若中文乱码，用 `python -X utf8 /tmp/xxx.py`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 方案评审写着"本链路保证恰好一次投递" | 两将军 + 网络重试注定重复或丢失 | 改口"至少一次 + 幂等吸收"，模式表见 [04 章 §6](./04-distributed-transactions.md) |
| 重试脚本不带幂等键，下游重复扣款 | 超时后的第三种状态没有兜底 | 键随请求下发，下游唯一键/去重表兜底 |
| "TCP 可靠，应用消息不会重不会丢" | TCP 只承诺连接存活期间字节流可靠；断连丢、重试重 | 应用层确认 + 幂等；[00 章演练一](./00-distributed-overview.md) 就是反例现场 |
| 上了 PBFT 就宣称"任何故障都不怕" | BFT 容分裂的谎言，不容一致的 bug | 一致的错靠灰度/多版本；BFT 不是质量替代品 |
| 4 节点 BFT 挂 2 台，期望还能服务 | f=1 的预算下 quorum=3 凑不齐 | 扩到 7 台容 2；或接受停摆保安全 |
| 选举偶发拆票/切换 1~3 秒就当故障处理 | FLP 的影子，随机化后自然收敛 | 盯"是否反复"：反复才查盘/GC/超时基数（[03 章 §4.2](./03-consensus-and-replication.md)） |
| 想让各节点"同一时刻"打全局快照 | 没有"同时"，拼出的状态不可达 | marker/barrier 的一致割思路（Flink 已内建） |

## 自测

1. TCP 三次握手不是"解决"了两将军吗？它到底解决了什么、没解决什么？断连瞬间内核里未 ACK 的数据去哪了？
<details><summary>答案</summary>

三次握手解决的是工程目标：同步初始序号 + 确认双向通路可用。它没解决共同知识——第三次 ACK 仍可能丢，TCP 靠 SYN+ACK 重传兜底，重传造出的重复由序号消化（"消化重复比消灭重复便宜"）。断连时：RST 直接丢弃内核里未 ACK 的数据；优雅关闭也只保证字节送到对端内核，不保证对端应用处理成功——应用语义的确认必须应用层自己做，一做就回到两将军。TIME_WAIT 等 2MSL 同理：最后的 ACK 无法被确认，就等重传窗口与旧报文都过期，把不可能变成"概率足够小"。
</details>

2. 同样容 1 个故障，CFT 要 3 台、BFT 要 4 台——多出来的节点买的是什么？用"两个过半集合的交集"推一遍。
<details><summary>答案</summary>

CFT（N=2f+1，quorum=f+1）：任意两个过半集合交集 ≥ 1，节点不撒谎，一个诚实的交集节点足以传递最新已提交值。BFT（N=3f+1，报告集 2f+1）：交集 ≥ 2×(2f+1)−(3f+1) = f+1——交集本身可能被叛徒占 f 个，必须**多于 f** 才保证至少一个忠诚者，矛盾报告才无法同时骗过两边。多出的节点买的正是"任何两个多数派的交集必含忠诚者"。这也是 BFT 消息要膨胀成"全对全 + 多轮转述"的原因：单靠集合大小不够，还要信息冗余稀释谎言。
</details>

3. FLP 说没有"始终终止"的共识，但 etcd 天天在终止——被打破的是哪条前提？如果两个 candidate 用了同一个随机种子，会发生什么？
<details><summary>答案</summary>

etcd 打破的是"确定性 + 无同步假设"：随机选举超时让调度者无法预判行为（病态调度被踩成概率 0）；超时是注入的临时同步假设（赌 1 秒没到就是不会到）；失 quorum 时宁可停写（舍 liveness 保 safety）。若两个 candidate 种子相同，行为完全同步：同时超时、同时拆票、下一轮再同时来——系统退化为确定性算法，FLP 的病态调度重新适用，理论上可无限不终止。工程上随机源来自 OS 熵池、超时区间有宽度，就是为了让这种"共振"概率趋零。
</details>

4. Chandy-Lamport 为什么必须假设 FIFO 信道？如果 marker 能越过数据（非 FIFO），快照会坏成什么样？Flink 的 unaligned checkpoint 为什么不怕？
<details><summary>答案</summary>

FIFO 保证"marker 之前发出的数据都在 marker 之前到达"——接收端看到 marker 就知道割的因果边界已齐。非 FIFO 时 marker 插队：割前发出的数据可能还没到，接收端要么把它当割后数据（快照缺一块，恢复后少算），要么已把割后数据算进状态（快照多一块，恢复后重算）——因果闭合被破坏。unaligned 不依赖"等齐"：barrier 一到就快照，不确定的部分（in-flight 数据）不猜测、直接显式存进快照，恢复时先重放——把"边界不可判定"变成"边界随快照固化"，语义仍一致，代价是快照更大。
</details>

5. 4 节点 PBFT 联盟链挂掉 2 个节点会怎样？对照 etcd 5 节点挂 2 台的表现，说明 BFT 的可用性代价。
<details><summary>答案</summary>

PBFT（N=4, f=1）quorum=3，挂 2 台只剩 2——停摆：不会输出错误值（safety 保持），但没有输出（liveness 没了）。etcd 5 节点挂 2 台仍有 3 台存活，读写照常。同样 4~5 台规模、同样挂 2 台：CFT 照常服务、BFT 停摆——BFT 的容错预算里"崩溃"与"作恶"吃同一份 f，节点数还要多垫 50%。推论：BFT 不是"更高级的共识"，是为互不信任场景单独付费的另一个档位；内部系统用它，白白把可用性打了折。
</details>

## 延伸阅读

- The Byzantine Generals Problem（Lamport/Shostak/Pease, 1983）：https://lamport.azurewebsites.net/pubs/byz.pdf
- FLP 不可能定理原文（Fischer/Lynch/Paterson, JACM 1985）：https://groups.csail.mit.edu/tds/papers/Lynch/jacm85.pdf
- Distributed Snapshots: Determining Global States（Chandy & Lamport, 1985）：https://dl.acm.org/doi/10.1145/214451.214456
- Flink Checkpointing 官方文档（barrier 对齐与 unaligned 的配置语义）：https://nightlies.apache.org/flink/flink-docs-stable/docs/ops/state/checkpoints/
- Bitcoin 白皮书（开放网络上的拜占庭容错设计）：https://bitcoin.org/bitcoin.pdf
- DDIA 第 8 章（两将军与"恰好一次"的工程论述）：https://dataintensive.net/
