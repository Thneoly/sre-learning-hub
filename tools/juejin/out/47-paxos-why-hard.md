---
title_juejin: 'Raft 都有了为什么还啃 Paxos：难在论文没写的那一半'
title_zhihu: 'Paxos 难的不是共识内核，是论文与生产之间没写出来的那一层'
description: 'Paxos 剥掉故事体只剩两条消息一条规则；难在单值到日志的鸿沟、leader 是后补补丁、留白逼每个实现重新设计。Raft 把这些补丁写进协议本体。附两阶段直觉、活锁推演与可跑模拟器。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686341072617242662"
---

# Raft 都有了为什么还啃 Paxos：难的从来不是算法，是论文没写的那一半

面试里有道看着送分、实则送命的题：「Paxos 是不是被 Raft 淘汰了？」答「是」的人，多半接不住下一问——那 Spanner 里跑的是什么？卡住的这一秒，暴露的正是没翻过 Paxos。

我的判断先放在这，整篇都在论证它：**Raft 是 Paxos 补丁集的官方整理版，不是替代品。** 读懂 Paxos，才知道 Raft 的每个部件在补什么；跳过它直接背 Raft，那些规则就只剩死记。

先把目标说诚实：学 Paxos 是为了读懂，不是为了在生产手写。反方意见放第八节单独讲，这里先把正方理由讲透。本专栏前面拿 etcd 实测过 Raft 选举和丢 quorum，这篇往回挖一层——Raft 脚下的地基长什么样。

## 一、时间线摆正：Raft 之前，「共识」的同义词就是 Paxos

| 年份 | 事件 | 一句话读法 |
|---|---|---|
| 1989/1990 | Lamport 写出 The Part-Time Parliament，故事体 | 几乎没人读懂，沉睡十年 |
| 1998 | 论文正式发表 | 还是难读 |
| 2001 | 作者自己补白话版 Paxos Made Simple | 核心一句话：编号 + 两阶段 + 多数派 |
| 2006 | Google Chubby 论文披露生产级 Multi-Paxos | 第一次证明论文算法扛得住生产 |
| 2012 | Spanner：每个分片一个 Paxos group | Paxos 进数据库内核，服役至今 |
| 2014 | Raft 论文发表 | 可理解性成为一等设计目标 |

注意 2001 那行——**原论文难读到作者自己出来写白话版**，行文的晦涩是传说也是事实。但把账全算在行文头上也不公平，真正的难点在后面两节：一个值变一条日志的鸿沟，和一个论文没写的 leader。

从 1990 年算起，Paxos 家族在工业界服役超过三十年，Spanner 至今没换过协议。它撑住的理由按权重排四条：正确性证明硬，安全性全押在一条不变量上，Google 敢把锁服务押上去看中的就是这个。

其余三条：核心足够简单，剥掉故事体只剩两条消息一条规则；Multi-Paxos 留白多，实现者按负载自由裁剪；最朴素的一条——Raft 之前，没有替代品。

代价同样著名。Google 把 Chubby 落地后写了《Paxos Made Live》，核心抱怨是：**论文与生产之间，隔着一整层未成文的工程**——磁盘损坏与数据腐化、成员变更、快照与日志压缩、leader 租约、怎么测试证明正确，全都要自己发明。

他们的结论大意是：算法简单，实现却极具挑战【第三方转引，Google 论文《Paxos Made Live》】。

本节收一句：**Paxos 撑到 Raft 诞生，靠的不是易用，是没有对手。** 下一节先把那两条消息讲穿。

## 二、prepare 到底在问什么：一句话讲穿两阶段

剥掉故事体，Basic Paxos 三个角色：proposer 发起提案，对应 Raft 里 candidate 加 leader 的合体；acceptor 投票并持久化，对应全体成员；learner 学习结果。

提案编号（ballot）通常是「轮次 + proposer 唯一 id」的字典序——全序可比、无需中心分配，每台自己递增轮次就行。

你其实天天见它：Raft 的 term、ZooKeeper 的 epoch、Redis 哨兵的 epoch，全是 ballot 的化身。

两阶段的消息语义，一张表讲完：

| 阶段 | 消息 | acceptor 做什么 | 买到了什么 |
|---|---|---|---|
| Phase 1 | prepare(n) → promise | 承诺不再接受编号小于 n 的提案，并交出自己已接受的最高编号提案 | 锁编号 + 上缴历史 |
| Phase 2 | accept(n, v) → accepted | 若 n 不低于自己的承诺，接受并持久化 | 过半接受，值 v 被 chosen |

直觉版一句话：**prepare 问的是「有没有人见过比我更高的编号」**——问的同时顺手锁门（承诺），把历史带回来（已接受值）。确认没人拦路，第二阶段才提交值。

而安全性的全部秘密，藏在 v 的选择规则这一条上：promise 带回的已接受值里，取编号最大的那个沿用；一个都没有，才轮到 proposer 自己想提的值。S5 想提 B，但更高编号的历史里已经有 A，S5 就只能提 A——这就是「值接管」。

这个历史字段不是装饰，砍掉它协议就漏。

反例时序：S1 用编号 1 提 A，过半接受，A 已 chosen；S5 不知道，用编号 7 发起 prepare——若 promise 只承诺、不交历史，acceptor 只需拒收小编号，S5 接着 accept(7, B)，B 也 chosen。两个不同值先后过半，一致性丢失。

历史字段让 S5 的 prepare 必然从多数派交集中撞见 A，被迫沿用——**值接管不是优化，是安全性的实现机制。**

为什么必须是两阶段？一阶段做不到「既锁住编号、又探明历史」。没有锁，两个 proposer 可以各自让过半接受不同的值；没有历史，后来者会用自己的值覆盖已被 chosen 的值。**两条消息各扛一半安全性，谁也不能省。**

多数派在这里干两件事：任意两个多数派必相交，交点上的 acceptor 受编号承诺约束，这是互斥；交点又把已接受值带给后来者，迫使沿用，这是传递。由此得到 Paxos 的唯一不变量：**一旦某个值被过半接受，之后任何成功提案的值都与它相同。** 正确性证明全押这一条。

运维记住它的外显就够：**共识集群里已经确认过的决定，不需要也不敢改。** 三节点 etcd 失 quorum 时「先救一台、别急着重组」的纪律，理论出处就在这条不变量。

面试标准答法顺带收下：Basic Paxos 两阶段各买一半安全性——prepare 的 promise 锁编号，防并发提案打架；附带的已接受值，防后来者覆盖已选定的值；过半接受即 chosen，且永不再变。

Raft 的 RequestVote 和 AppendEntries，就是这两条消息换了马甲。

## 三、活锁：每一步都合法，只是永远到不了终点

两个 proposer 同时活动、轮流抬编号，就出现决斗活锁。三台 acceptor 的推演：

```text
S1（想提 A）                  S5（想提 B）
  prepare(1) ──► 过半 promise(1)
             prepare(5) ──► 过半 promise(5)   ← 1 的承诺作废
  accept(1,A) ──► 全拒（承诺已 ≥5）
  prepare(9) ──► 过半 promise(9)
             accept(5,B) ──► 全拒（承诺已 ≥9）
             prepare(13) ──► ……
编号无限上抬：没有任何节点失败，也没有任何值被选中
```

三个观察，每个都值得单独背。

其一，活锁全程从未出现「两个不同值同时过半」。这是活性病，不是安全病——FLP 说死的是活性，在 Paxos 上的具体形态就是它。工程含义很冷静：**共识协议可以慢到没有终点，但绝不会快到给出两个答案。** 运维遇到共识类故障，第一怀疑永远是卡住，而不是错值。

其二，解药是选一个 distinguished proposer：全部提案经它发起，唯一提案者天然无竞争。但论文只说应该有一个，没说怎么选、怎么换。

其三，所以「没有 leader 的 Paxos」只在论文里存在。**一切生产实现，都是 Paxos 内核加一套自制的选主外壳**；Chubby 的 master 选举和租约是自己补的，Raft 和 ZAB 干脆把外壳写进协议本体。

leader 是后补的补丁，不是协议的天生部件——这就是「Paxos 难在哪」的第二层。

leader 失联怎么办？回到超时竞选——心跳超时、抬编号、重新拉票，也就是你在 etcd 里看到的那套。所以「带 leader 的 Paxos」永远有清晰的分界：论文给你内核，外壳各家自造，而外壳恰恰是最容易出 bug 的那截。

顺手排掉一个面试坑：这两阶段不是 2PC。2PC 是协调者单点加全体投票加阻塞，Paxos 是多数派、无单点——只是恰好都分两步，语义完全不同。

## 四、Multi-Paxos：难的不是算法，是单值到日志那道鸿沟

Basic Paxos 一次只定一个值，而复制状态机要的是值的序列。第一道鸿沟在这：**论文给的是定一个值的答案，生产要的是定一条日志的答案。**

朴素做法是每个日志槽位（slot）跑一个独立的 Basic Paxos——每条命令两轮 RTT，还随时可能活锁，太贵。

优化是稳定 leader 之后 prepare 只做一次：当选时用一个足够大的编号对所有 slot 一次 prepare，把各 acceptor 的承诺与已接受值一次拿全；此后每条新命令只发 accept，一轮 RTT，唯一提案者无活锁。

两个最容易答错的细节，都是面试硬伤：

- **「跳过 prepare」只在 leader 任期内有效。** 换主必须重新 prepare——新 leader 靠这一步探明每个 slot 上别人已接受的值，把它理解成一劳永逸直接扣分。
- **日志空洞是合法状态。** slot 5 已 chosen、slot 3 还空着完全合法。代价有两笔：执行层 apply 前自己处理连续性；换主时新 leader 要对全量 slot 重新探测、逐洞补 no-op——**日志越长，换主越贵。**

再深一层：为什么 Raft 比较最后一条日志就能确定数据最全的人？连续性与投票限制的合力——日志按 index 严格连续，投票又要求候选人的日志至少和我一样新（先比最后一条的 term，term 相同再比 index），于是最后一条日志最新者必然包含全部已提交条目，最后一条就是全貌的指纹。

Multi-Paxos 的 slot 相互独立，中间可能有洞，最后一条没有含义，只能全量重探。**Raft 用连续性约束，把换主成本压到 O(1)。**

那为什么每个 Multi-Paxos 实现都不一样？因为论文只写共识核心，选主、日志、恢复、成员变更全是留白。Chubby 自己补 master 选举和租约，Spanner 把共识和 TrueTime、流水线揉进数据库内核——**工程化即重新设计，每家都在答自己的卷子。**

对 Google 这种把共识嵌进内核的公司，留白是自由度，乱序确认、流水线、批处理随便塞；对普通团队，同一片留白就是 bug 之源【从业者判断】。

## 五、Raft 的可理解性，本质是把补丁写进了协议本体

Raft 论文的方法论是分解：共识问题拆成 leader 选举、日志复制、成员变更等子问题逐个讲。逐块看它吸收了 Paxos 的哪些补丁：

| Raft 部件 | 吸收的 Paxos 补丁 |
|---|---|
| leader 选举 | distinguished proposer——活锁的解药，从论文一句话升格为协议内置流程 |
| 日志复制 | slot 可空洞改为 index 严格连续加日志匹配性质；换主从全量重新 prepare 探测补洞，变成比较最后一条日志加一条 no-op |
| 提交语义 | 每个 slot 独立 chosen，改为 commitIndex 单一水位单调推进，心跳捎带 |
| 成员变更 | Paxos 论文里的留白、Chubby 团队被迫自己发明的部分，Raft 论文成文 |

这笔账一句话：复杂性没有消失，只是从写代码的人搬到了协议的约束上。**教科书选 Raft，是在为「实现不出错」付溢价。** 照论文写就能对，这正是 Raft 的设计目标。

两句公道话必须说。Howard 在《Paxos vs Raft》里的结论是两者路线高度相似，主要差异在 leader 选举的表达方式【第三方转引，Howard，2020】——性能和安全性不是分水岭。

而 Spanner 至今用 Paxos：乱序确认与流水线的余量，对超大规模数据库内核仍有真实价值。面试把「Raft 更优」说死，反而暴露没读过 Paxos。

把视角放宽到三份协议，复杂性转移看得更清楚：Paxos 转给写代码的人，论文只管共识核心；ZAB 转给协议的显式阶段，换主必须先 sync 完才服务；Raft 转给日志连续性约束，换主极简，代价是放弃乱序与流水线的自由。

运维看到的差异——ZK 扩容要逐台重启、etcd 能在线加成员——都是这三条路线的外显。所以「为什么教科书都用 Raft」的准确答案不是性能差距，而是**把复杂性搬给谁的选择**——这个答法，比「Raft 更优」高一个段位。

## 六、学了 Paxos 才答得出的四道题

这是「为什么值得啃」的直接回报清单——Raft 的文档只给规则，不给这些规则的出处。

**题一：term 为什么存在？** Raft 告诉你任期是逻辑时钟，Paxos 给出机制解释：ballot 要全序可比、无需中心分配，「轮次加 id」是最便宜的拿法。看你环境里的化身：

```bash
# 任一装了 etcdctl 的环境；盯 RAFT TERM 列
etcdctl endpoint status -w table
# term 就是 ballot 的「朝代」部分：旧 leader 失联后 term 跳 T→T+1，
# 等价新 proposer 用更大编号对全体做了一次 prepare
```

顺带排个坑：在 Raft 里找不到 promise 消息，它的对应物是 RequestVote 的投票承诺——每任期一票、WAL 持久化，语义就是 promise。

**题二：为什么「已确认的决定不敢改」？** Raft 把它当规则让你背，Paxos 给你不变量：chosen 之后任何成功提案的值都与它相同。失 quorum 先救成员、别重组数据的纪律，出处在理论不在经验。

**题三：ZAB 自称原子广播，为什么 ZK 的写仍线性一致？** 因为全序广播与共识可互相归约：决定全序日志第 i 条是什么，本身就是一次共识。ZAB 把顺序直接交给 leader，过半 ACK 保证提交唯一，语义等价于 Multi-Paxos 而实现路径不同。

ballot、epoch、term 是同一个「朝代」，promise 和投票是同一把「锁」，多数派是同一条互斥定理——**三份协议是同一具骨架的三身皮。** 学透任何一具，另两具只是换词汇表。

**题四：新 leader 上任为什么常先补一条空操作？** Raft 当选后的一条 no-op，是把前任任期的条目带过提交线；Multi-Paxos 换主后对空洞补 no-op，是给每个 slot 一个确定的结局。

补 no-op 是协议动作，不是修复 bug——把它当故障处理，说明还没看懂恢复语义。

## 七、动手跑：三十行代码看「值接管」

纸面推演容易自欺，跑一遍最诚实：

```bash
cat > /tmp/paxos.py <<'EOF'
class Acceptor:
    def __init__(s, name): s.name, s.promised, s.accepted = name, 0, None
    def prepare(s, n):
        if n > s.promised: s.promised = n; return ("promise", s.accepted)
        return ("reject", s.promised)
    def accept(s, n, v):
        if n >= s.promised: s.promised, s.accepted = n, (n, v); return "accepted"
        return "rejected"

def phase(pid, n, v, accs):                  # 3 台 acceptor，过半 = 2
    r = [a.prepare(n) for a in accs]
    if sum(x[0] == "promise" for x in r) < 2:
        print(f"[{pid}] prepare({n}) 未过半"); return
    seen = [x[1] for x in r if x[0] == "promise" and x[1]]
    use = max(seen)[1] if seen else v        # 关键规则：有已接受值就必须沿用
    if use != v: print(f"[{pid}] 想提 {v}，promise 带回更高编号的已接受值，改提 {use}")
    ok = sum(a.accept(n, use) == "accepted" for a in accs)
    print(f"[{pid}] accept({n}, {use}) -> {ok}/3" + ("  CHOSEN" if ok >= 2 else "  失败"))

accs = [Acceptor(x) for x in ("A1", "A2", "A3")]
phase("S1", 1, "v=A", accs)
phase("S5", 7, "v=B", accs)                  # S5 想提 B：看 B 有没有机会出现
print("--- leader 模式：prepare 一次，之后每条命令只跑 accept ---")
M = [Acceptor(x) for x in ("A1", "A2", "A3")]
[a.prepare(100) for a in M]
for i, c in enumerate(("cmd-1", "cmd-2", "cmd-3")):
    print(f"slot {i+1}: accept(100, {c}) -> " + " ".join(a.accept(100, c) for a in M))
EOF
python3 /tmp/paxos.py
```

预期输出（全量，箭头为笔者注）：

```text
[S1] accept(1, v=A) -> 3/3  CHOSEN
[S5] 想提 v=B，promise 带回更高编号的已接受值，改提 v=A
[S5] accept(7, v=A) -> 3/3  CHOSEN      ← S5 想提 B，B 没有机会出现
--- leader 模式：prepare 一次，之后每条命令只跑 accept ---
slot 1: accept(100, cmd-1) -> accepted accepted accepted
slot 2: accept(100, cmd-2) -> accepted accepted accepted
slot 3: accept(100, cmd-3) -> accepted accepted accepted
```

盯两处：第二行是安全性的现场证明——S5 想提 B 而 B 没有机会出现，**这一行输出比十篇教程都直观**。leader 模式里 prepare 只出现一次、三条命令各走一轮，「Multi-Paxos 省 RTT」从口号变成行数。

把 S5 的编号改成 1（不大于已承诺的），还能看到 promise 被拒的分支。

## 八、反方也要听完：目标是读懂，不是手写

正方讲完，把反方说全，免得这篇变成劝人跳坑。

生产选型一句话：**新项目默认 Raft 系**——etcd、Consul、CockroachDB、TiKV、KRaft 都是；存量内核里的 Paxos（Chubby、Spanner）仍在服役，用户不需要懂内部也能用好。

手写 Multi-Paxos，等于把 Chubby 团队踩过的坑重踩一遍：他们背后有论文级的测试基建，普通团队大概率没有【从业者判断】。

阅读路径也给一条【从业者判断】：别从 The Part-Time Parliament 入手，那是沉睡十年的故事体；从 Paxos Made Simple 开始，那是作者自己补的白话版；再读 Paxos Made Live 看工程血泪；最后跑一遍第七节的模拟器收尾。

检验啃没啃透，标准只有一条：**能不能白板走完两阶段，并说清每个字段保住了什么。** 能，Raft 的每条规则在你眼里就都有了出处；不能，Paxos 就白读了。

## 现在就能做的事

只有五分钟：跑第七节的模拟器，盯「值接管」那两行输出。有一小时：把活锁场景自己补进脚本——两台 proposer 轮流抬编号，亲眼看 accepted 0/3 一路刷屏。

自测两问带走：你生产 etcd 的 RAFT TERM 现在是多少？如果它比你的重启次数大得多，中间发生过什么？Multi-Paxos 的日志空洞，在什么负载下反而是优势？

这套推演和可跑的 lab，收在我维护的 SRE 学习仓库：GitHub 搜 sre-learning-hub，分布式模块第 09 章——同模块还有 Raft 理论篇和 etcd 杀 leader 实测，正好当本文的对照组。

最后留个站队题：如果明天要为你们团队选元数据存储，你是无脑 etcd，还是敢评估一遍 Paxos 系再下结论？评论区说说理由。
