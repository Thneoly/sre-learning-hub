# 09 · Paxos 深潜：两阶段、活锁、Multi-Paxos 与 Raft 的对照

> 模块：17-distributed ｜ 建议时长：3.5 小时 ｜ 关联认证：—（无直接考点；把 [03 章 §6](./03-consensus-and-replication.md) 的一句话史展开成协议本体，回答"Raft 诞生前的二十多年里工业界靠什么撑着、Paxos 家族又为何服役至今三十余年"）

## 学习目标

- 能讲出 Paxos 从 1990 到 Raft 诞生的工业时间线，说出 Chubby/Spanner 选它而 Paxos Made Live 又抱怨它的原因
- 能白板走完 Basic Paxos 两阶段（prepare/promise、accept/accepted），解释提案编号与多数派分别买到了什么
- 能用时序图推演两个 proposer 交替抬编号的活锁，说明它为什么是活性问题不是安全问题，以及领导者选举为何是必需品
- 能说清 Multi-Paxos"跳过 prepare"的准确语义（leader 任期内才跳过）与日志空洞的合法性
- 能从协议本质（出生问题、日志形态、换主恢复、论文完整度）对比 Multi-Paxos / Raft / ZAB，回答"为什么教科书都用 Raft"

[03 章 §6](./03-consensus-and-replication.md) 的结论是"Raft 用可理解性换了工程正确率"；本章展开它的前提——Paxos 到底长什么样、难在哪、为什么又没被淘汰。继续本模块纪律：不推导证明，只讲语义、代价、运维后果与面试答法。

## 1. 为什么 Raft 诞生前的二十多年里工业界只用 Paxos

| 年份 | 事件 | 运维视角的读法 |
|---|---|---|
| 1989/1990 | Lamport 写出 The Part-Time Parliament（故事体） | 几乎没人读懂，沉睡十年 |
| 1998 | 论文正式发表（TOCS） | 还是难读 |
| 2001 | 作者自己补白话版 Paxos Made Simple | 核心其实一句话：编号 + 两阶段 + 多数派 |
| 2006 | Google Chubby 论文披露生产级 Multi-Paxos | 第一次证明"论文算法扛得住生产" |
| 2012 | Spanner：每个分片一个 Paxos group | Paxos 进数据库内核，服役至今 |
| 2014 | Raft 论文（Ongaro）发表 | 可理解性成为一等设计目标 |

"三十年"这么算：从 1990 年算起，Paxos 家族在工业界服役至今超过三十年——Spanner 没换过协议；而 Raft 诞生前的二十多年里，**"共识"的同义词就是 Paxos**。它撑得住的理由：

1. **正确性证明硬**：安全性押在一条不变量上（见 §2.3），数学上无懈可击——Google 敢把锁服务押上去，看中的就是这个。
2. **核心足够简单**：剥掉故事体的外衣，Basic Paxos 只有两条消息、一条规则。
3. **Multi-Paxos 留白多**：论文不规定选主、日志、恢复的细节，实现者按负载自由裁剪（乱序确认、流水线、批处理都能塞进去）——对 Google 这种把共识嵌进数据库内核的公司是优点。
4. **没有替代品**：Raft 之前，别无选择。

代价同样著名。Google 团队把 Chubby 落地后写了《Paxos Made Live》，核心抱怨：**论文与生产之间隔着一整层未成文的工程**——磁盘损坏与数据腐化、成员变更、快照与日志压缩、leader 租约、测试怎么证明正确，全都要自己发明；他们的结论大意是"算法简单，实现却极具挑战"。[03 章 §6](./03-consensus-and-replication.md) 说的"正确性靠论文、工程细节各自补"，出处就是这篇。

## 2. Basic Paxos：prepare/promise 与 accept/accepted

### 2.1 三个角色与提案编号

| 角色 | 职责 | Raft 里的对应（03 章 §4） |
|---|---|---|
| proposer | 发起提案、推动两阶段 | candidate + leader 的合体 |
| acceptor | 投票并持久化"已接受的提案" | 全体成员 |
| learner | 学习已被 chosen 的值 | 全体成员与上层状态机 |

**提案编号（ballot）**：通常是 `(轮次, proposer 唯一 id)` 的字典序——全序可比、无需中心分配（每台自己递增轮次）。你早就见过它的化身：Raft 的 term、ZK 的 epoch（zxid 高位）、哨兵的 epoch——**[03 章 §4.1](./03-consensus-and-replication.md) "任期是逻辑时钟"，原型就是 Paxos 的提案编号**。

### 2.2 两阶段：消息语义

| 阶段 | 消息 | acceptor 的动作 | 买到了什么 |
|---|---|---|---|
| Phase 1 | prepare(n) → promise | 承诺**不再接受编号 < n 的提案**；同时**交出自己已接受的最高编号提案**（若有） | 编号互斥 + 历史上缴 |
| Phase 2 | accept(n, v) → accepted | 若 n ≥ 自己的承诺，接受并持久化 (n, v) | 过半接受 ⇒ 值 v 被 chosen |

**v 的选择规则是安全性的全部秘密**：promise 带回的已接受值里取编号最大的那个沿用；一个都没有，才用 proposer 自己想提的值。

```
Proposer                        Acceptor×3（过半 = 2，含 proposer 视角下的多数派）
   │  prepare(n)  ─────────────►   "更小编号的提案我一律拒收"
   │  ◄─────────────────────────   promise + 我已接受的最高编号提案（若有）
   │        —— 以上过半，Phase 1 完成 ——
   │  accept(n, v)  ───────────►   v = 带回的最高编号已接受值（无则自选）
   │  ◄─────────────────────────   ACCEPTED
   │        —— 以上过半 ⇒ v 被 chosen，此后永不再变 ——
```

**为什么必须是两阶段**：一阶段做不到"既锁住编号、又探明历史"。没有锁（promise），两个 proposer 可以各自让过半接受不同的值；没有历史（promise 附带的已接受值），后来者会用自己的值覆盖已被 chosen 的值。两条消息各扛一半安全性。

### 2.3 多数派的双重作用与唯一不变量

多数派在 Paxos 里干两件事，对照 [03 章 §2](./03-consensus-and-replication.md) 的 quorum 数学：

1. **互斥**：任意两个多数派必相交。交点上的 acceptor 受编号承诺约束，不可能让"两个不同的值各得过半"同时成立。
2. **传递**：交点 acceptor 把自己已接受的值通过 promise 带给后来的 proposer——后来者被迫沿用（实战演练 1 场景 2 的"值接管"）。

由此得到 Paxos 的唯一不变量：**一旦某个值被过半接受（chosen），之后任何成功提案的值都与它相同**。正确性证明全部押在这一条上；运维记住它的外显就够：**共识集群里"已经确认过的决定"不需要也不敢改**——03 章失 quorum 时"先救一台、别重组"的纪律，理论出处在此。

**面试答法**："Basic Paxos 两阶段各买一半安全性——prepare 的 promise 锁编号防并发提案打架，promise 附带的已接受值防后来者覆盖已选定的值；过半接受即 chosen，且永不再变。Raft 的 RequestVote/AppendEntries 就是这两条消息换了马甲。"

## 3. 活锁：安全但可能永远选不出

两台 proposer 同时活动、轮流抬高编号，就出现**决斗活锁**：

```
S1（想提 A）                          S5（想提 B）
  prepare(1) ──► 过半 promise(1)
               prepare(5) ──► 过半 promise(5)     ← 1 的承诺作废
  accept(1,A) ──► 全拒（承诺已 ≥5）
  prepare(9) ──► 过半 promise(9)
               accept(5,B) ──► 全拒（承诺已 ≥9）
               prepare(13) ──► ……
  accept(9,A) ──► 全拒 ……
编号无限上抬：没有任何节点失败，也没有任何值被选中
```

三个观察：

1. **安全性全程无损**：活锁期间从未出现"两个不同值同时过半"。这是**活性**病，不是**安全**病——[08 章 §3](./08-classic-problems.md) FLP"死的是活性"在 Paxos 上的具体形态就是它。
2. **解药是选一个 distinguished proposer（领导者）**：全部提案经它发起，唯一提案者天然无竞争、无活锁。Paxos 论文只说"应该有一个"，**没说怎么选、怎么换**——这正是各实现自由发挥、也最容易出错的留白（Chubby 的 master 选举、租约，都是自己补的）。
3. **领导者失联怎么办**：回到超时竞选——也就是 03 章 Raft 选举 + 08 章 FLP 妥协那一套。所以"没有 leader 的 Paxos"只在论文里存在，**一切生产实现都是" Paxos 内核 + 一套自制的选主外壳"**；Raft/ZAB 干脆把外壳写进协议本体。

## 4. Multi-Paxos：选主之后跳过 prepare

**动机**：Basic Paxos 一次只定**一个值**；复制状态机需要的是值的**序列**（日志）。朴素做法是每个日志槽位（slot）跑一个独立的 Basic Paxos——每条命令两轮 RTT，还随时可能活锁，太贵。

**优化：稳定 leader 之后，prepare 只做一次**：

1. leader 当选时，用一个足够大的编号对**所有 slot** 做一次 prepare，把各 acceptor 对各 slot 的承诺与已接受值一次拿全；
2. 此后每条新命令只发 accept——**一轮 RTT**，唯一提案者无活锁（实战演练 1 场景 3 演的就是这个形态）。

**"跳过 prepare"的准确语义：只在 leader 任期内跳过；换主必须重新 prepare**——新 leader 靠这一步探明每个 slot 上别人已接受的值。把它理解成"一劳永逸"是面试硬伤。

**空洞是合法状态**：slot 之间独立推进，"slot 5 已 chosen、slot 3 还空着"完全合法（乱序、并发、旧 leader 崩溃都会造洞）。代价有两笔：执行层 apply 前要自己处理连续性；换主时新 leader 要对全量 slot 重新 prepare 探测、对空洞补 no-op——**日志越长，换主越贵**。对照 Raft：换主只需比较最后一条日志（投票时"日志至少和我一样新"的限制保证了最新者包含全部已提交条目，[03 章 §4.2](./03-consensus-and-replication.md)）+ 一条 no-op 把前任期条目带过提交线（[03 章自测 4](./03-consensus-and-replication.md)）。

## 5. Multi-Paxos 与 Raft：语义级对比

| 维度 | Multi-Paxos | Raft |
|---|---|---|
| 日志连续性 | slot 相互独立，**允许空洞与乱序 chosen** | index 严格连续，AppendEntries 的匹配性质强制对齐（[03 章 §4.3](./03-consensus-and-replication.md)） |
| 提交语义 | 每个 slot 独立 chosen，"哪些已提交"要执行层自己拼 | commitIndex 单一水位单调推进，心跳捎带（隐式提交） |
| 换主成本 | 全量 slot 重新 prepare 探测 + 逐个补 no-op | 比较最后一条日志 + 一条 no-op |
| 心跳/续权 | 论文不管：accept 本身即隐式续权，细节各家自定 | AppendEntries 同时承担复制、心跳、commit 捎带三职 |
| 协议完整度 | 论文只写共识核心；选主/成员变更/快照/恢复全是留白 | 论文全流程成文，附正确性论证与可理解性实验 |
| 实现自由度 | 高（乱序、流水线、批处理随便塞）——也是分歧与 bug 之源 | 低：照论文写就能对——这正是设计目标 |
| 代表系统 | Chubby、Spanner | etcd、Consul、CockroachDB/TiKV、KRaft（[03 章 §6](./03-consensus-and-replication.md) 已列） |

**为什么教科书都用 Raft**：不是性能或安全性的差距——Howard 在《Paxos vs Raft》（2020）里的结论是两者路线高度相似，主要差异在 leader 选举的表达方式。差别在**把复杂性搬给了谁**：Raft 用日志连续性约束换来了换主的简单（§4 末的对比），用可理解性换来了实现的正确率，用完整论文与参考实现换来了生态。教科书与新项目选 Raft，是在为"实现不出错"付溢价。

**两句公道话**：Spanner 至今用 Paxos——乱序确认与流水线的余量对超大规模数据库内核仍有真实价值；"教科书都用 Raft"是教学与工程成功率的选择，不是定理高下。面试把"Raft 更优"说死，反而暴露没读过 Paxos。

## 6. ZAB 收束：三种协议的本质对照

[03 章 §7](./03-consensus-and-replication.md) 已给过 ZAB/Raft 的三条运维差异，[16-bigdata/06 §3](../16-bigdata/06-zookeeper.md) §3 末有六行词汇对照表；本节从**协议出生地**再收一次束：

| | Basic/Multi-Paxos | ZAB | Raft |
|---|---|---|---|
| 出生问题 | 对**单个值**达成共识（数学问题） | 把写请求**原子广播**成全序日志（ZK 的工程需求） | 让普通人实现正确的复制状态机（可理解性一等目标） |
| 日志形态 | slot 可空洞、可乱序 | 连续（广播序即提交序） | 连续（日志匹配性质） |
| 换主恢复 | 全量 slot 重新 prepare 探测补洞 | **显式 sync 阶段**：follower 先与 leader 对齐、未提交事务 TRUNC，完成才进 broadcast | nextIndex 回退补发 + 一条 no-op |
| 编号化身 | ballot | epoch（zxid 高位） | term |
| 论文形态 | 核心证明，工程留白 | 论文完整（discovery/sync/broadcast 三阶段） | 论文完整 + 可理解性实验 |

两点深化：

- **ZAB 自称 atomic broadcast 而非共识，为什么 ZK 仍写出线性一致的写**：全序广播与共识可互相归约——"日志第 i 条是什么"本身就是一次共识。ZAB 把顺序直接交给 leader（primary order），过半 ACK 保证提交唯一，等价于 Multi-Paxos 的语义而实现路径不同（[02 章](./02-consistency-models.md) 落位表：ZK 写线性一致、默认读顺序一致）。
- **复杂性不会消失，只会转移**：Paxos 把实现复杂性转给写代码的人（论文只管共识核心）；ZAB 转给协议的显式阶段（换主必须先 sync 完才服务，恢复路径清晰但阶段多）；Raft 转给日志连续性约束（换主极简，代价是放弃乱序/流水线的自由）。运维看到的全部差异——ZK 扩容逐台重启 vs etcd 在线 member add、显式 COMMIT vs 隐式 commitIndex——都是这三条路线的外显。

一句话收束本模块的共识部分：**ballot/epoch/term 是同一个"朝代"，promise/投票是同一把"锁"，多数派是同一条"互斥定理"——三份协议是同一具骨架的三身皮**。学透任何一具，另两具只是换词汇表（03 章 §7 的结论在这里兑现）。

## 实战演练

```bash
# [任意节点] 演练 1：Basic Paxos 模拟器——正常流、值接管、活锁、leader 模式
cat > /tmp/paxos_demo.py <<'EOF'
class Acceptor:
    def __init__(self, name):
        self.name, self.promised, self.accepted = name, 0, None   # accepted = (n, v)
    def prepare(self, n):
        if n > self.promised:
            self.promised = n
            return ("promise", self.accepted)
        return ("reject", self.promised)
    def accept(self, n, v):
        if n >= self.promised:
            self.promised, self.accepted = n, (n, v)
            return "accepted"
        return "rejected"

def phase(pid, n, v, accs):
    """一个 proposer 完整的两阶段；3 台 acceptor，过半 = 2"""
    print(f"[{pid}] prepare({n})")
    res = {a.name: a.prepare(n) for a in accs}
    for k, r in res.items():
        if r[0] == "promise":
            print(f"    {k}: promise" + ("（无历史）" if not r[1] else f"（带回已接受 {r[1]}）"))
        else:
            print(f"    {k}: reject（已承诺 ≥ {r[1]}）")
    if sum(r[0] == "promise" for r in res.values()) < 2:
        print("    未过半 promise，放弃本轮")
        return None
    seen = [r[1] for r in res.values() if r[0] == "promise" and r[1]]
    use = max(seen)[1] if seen else v          # 关键规则：有已接受值就必须沿用
    if use != v:
        print(f"    !! promise 带回了编号更高的已接受值，改提 {use}（chosen 值接管）")
    print(f"[{pid}] accept({n}, {use})")
    res2 = {a.name: a.accept(n, use) for a in accs}
    for k, r in res2.items():
        print(f"    {k}: {r}")
    if sum(r == "accepted" for r in res2.values()) >= 2:
        print(f"    过半 accepted —— 值 {use} 被 CHOSEN")
        return use
    print("    未过半 accept，本轮失败")
    return None

A = lambda: [Acceptor(s) for s in ("A1", "A2", "A3")]

print("=== 场景 1/2：无竞争提案 + 后来者的'值接管' ===")
accs = A()
phase("S1", 1, "v=A", accs)
phase("S5", 7, "v=B", accs)      # S5 想提 B

print("\n=== 场景 3：活锁（两台轮流抬编号，谁也过不了半）===")
L = A()
for who, ph, n in [("S1", "p", 1), ("S5", "p", 5), ("S1", "a", 1), ("S1", "p", 9),
                   ("S5", "a", 5), ("S5", "p", 13), ("S1", "a", 9)]:
    if ph == "p":
        r = {a.name: a.prepare(n)[0] for a in L}
        print(f"  {who}: prepare({n})  ->  " + "  ".join(f"{k}:{v}" for k, v in r.items()))
    else:
        r = {a.name: a.accept(n, f"v-{who}") for a in L}
        c = sum(x == "accepted" for x in r.values())
        print(f"  {who}: accept({n}, v-{who})  ->  accepted {c}/3"
              + ("   ← 全被拒：编号已被对方抬高" if c < 2 else "   CHOSEN"))
print("没有任何值被 chosen——但也从未有两个不同的值同时过半：安全性无损，活性饿死")

print("\n=== 场景 4：leader 模式（Multi-Paxos：prepare 一次，之后只跑 accept）===")
M = A()
r = {a.name: a.prepare(100)[0] for a in M}
print("  leader S5: prepare(100)  ->  " + "  ".join(f"{k}:{v}" for k, v in r.items()))
for i, cmd in enumerate(("cmd-1", "cmd-2", "cmd-3")):
    r = {a.name: a.accept(100, cmd) for a in M}
    print(f"  slot {i+1}: accept(100, {cmd})  ->  "
          + "  ".join(f"{k}:{v}" for k, v in r.items()) + "  CHOSEN")
EOF
python3 /tmp/paxos_demo.py
```

预期输出（节选关键行，`...` 处为逐 acceptor 的同类应答）：

```
=== 场景 1/2：无竞争提案 + 后来者的'值接管' ===
[S1] prepare(1)
    A1: promise（无历史） ...
[S1] accept(1, v=A)
    A1: accepted ...
    过半 accepted —— 值 v=A 被 CHOSEN
[S5] prepare(7)
    A1: promise（带回已接受 (1, 'v=A')） ...
    !! promise 带回了编号更高的已接受值，改提 v=A（chosen 值接管）
[S5] accept(7, v=A)
    过半 accepted —— 值 v=A 被 CHOSEN          ← S5 想提 B，B 没有机会出现
=== 场景 3：活锁（两台轮流抬编号，谁也过不了半）===
  S1: prepare(1)  ->  A1:promise  A2:promise  A3:promise
  S5: prepare(5)  ->  A1:promise  A2:promise  A3:promise
  S1: accept(1, v-S1)  ->  accepted 0/3   ← 全被拒：编号已被对方抬高
  S1: prepare(9)  ->  A1:promise  A2:promise  A3:promise
  S5: accept(5, v-S5)  ->  accepted 0/3   ← 全被拒：编号已被对方抬高
  S5: prepare(13)  ->  A1:promise  A2:promise  A3:promise
  S1: accept(9, v-S1)  ->  accepted 0/3   ← 全被拒：编号已被对方抬高
没有任何值被 chosen——但也从未有两个不同的值同时过半：安全性无损，活性饿死
=== 场景 4：leader 模式（Multi-Paxos：prepare 一次，之后只跑 accept）===
  leader S5: prepare(100)  ->  A1:promise  A2:promise  A3:promise
  slot 1: accept(100, cmd-1)  ->  A1:accepted  A2:accepted  A3:accepted  CHOSEN
  slot 2: accept(100, cmd-2)  ->  A1:accepted  A2:accepted  A3:accepted  CHOSEN
  slot 3: accept(100, cmd-3)  ->  A1:accepted  A2:accepted  A3:accepted  CHOSEN
```

解读三点：场景 2 是安全性的现场证明（chosen 过的值接管一切后来者）；场景 3 是活锁——注意每一步都"合法"，只是永远到不了终点；场景 4 里 prepare 只出现一次、三条命令各一轮——把它和场景 1 对比，"Multi-Paxos 省 RTT"就从口号变成了行数。改 `phase("S5", 7, "v=B", accs)` 的编号为 1（不大于已承诺的）可看 promise 被拒的分支。

```bash
# [master] 演练 2：把"提案编号"钉到真实系统（ectl 沿用 04-k8s-fundamentals/13 章 §2.2 的定义）
ectl endpoint status -w table
# 看 RAFT TERM 列：term 就是 ballot 的"朝代"部分——03 章实战演练 3 里
# pause 旧 leader 后 term 跳 T→T+1，等价新 proposer 用更大编号对全体做了一次 prepare。
# ZK 侧的化身是 zxid 高 32 位的 epoch（16-bigdata/06 演练 srvr 可见），此处不重跑。
```

验证方法：演练 1 的四组输出逐行对上，重点是场景 2 的"值接管"与场景 3 的三连拒；演练 2 能指着 RAFT TERM 说出它在本章的学名。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 面试说"Paxos 已被 Raft 淘汰" | Spanner 等内核至今 Paxos | 说"新项目默认 Raft，存量内核 Paxos 仍在服役" |
| 把 Basic Paxos 的两阶段当成 2PC | 2PC 是协调者单点 + 全体投票 + 阻塞（[04 章 §2](./04-distributed-transactions.md)）；Paxos 是多数派、无单点 | 两者只是"都分两步"，语义完全不同 |
| 以为"跳过 prepare"是一劳永逸 | 只在 leader 任期内有效 | 换主必须重新 prepare 探历史（§4） |
| 把 Multi-Paxos 的日志空洞当 bug | slot 独立是协议允许的合法状态 | 补 no-op 是协议动作，不是修复 |
| 分不清 term/epoch/ballot | 同一概念的三地方言 | 背 §6 表"编号化身"行 |
| 在 Raft 里找 promise 消息 | 对应物是 RequestVote 的投票承诺（每任期一票、WAL 持久化） | [03 章 §4.2](./03-consensus-and-replication.md) 投票规则 |

## 自测

1. promise 里"交出已接受的最高编号提案"这半条信息保住了什么性质？如果 promise 只承诺、不交历史，构造一个丢一致性的时序。
<details><summary>答案</summary>

保住的是"chosen 之后不再变"。没有历史字段的时序：S1 用编号 1 提 A，过半接受——A 已 chosen；S5 不知道，用编号 7 发起 prepare，acceptor 只承诺"不再接受 <7"，S5 接着 accept(7, B)——编号 7 满足承诺，过半接受，B 也 chosen。两个不同值先后被过半接受，一致性丢失。历史字段让 S5 的 prepare 必然从多数派交集中撞见 (1, A)，被迫沿用 A——这就是"值接管"，也是唯一不变量的实现机制。
</details>

2. 活锁推演的整个过程中，有没有任何一个时刻"两个不同的值同时被过半接受"？由此说明 safety 与 liveness 的分离在 Paxos 里意味着什么。
<details><summary>答案</summary>

没有。任何一次 accept 被拒的原因都是"承诺已被更大的编号占据"，编号的全序性保证同一时刻至多一个编号"有效"，因此至多一个值能凑齐过半。活锁杀掉的只是终止性（liveness），安全性（safety）毫发无损——这正是 FLP"死的是活性"的 Paxos 实例（[08 章 §3](./08-classic-problems.md)）。工程含义：共识协议可以"慢到没有终点"，但绝不会"快到给出两个答案"；运维遇到共识类故障，第一怀疑永远是卡住（活性），而不是错值（安全性）。
</details>

3. Multi-Paxos 的日志空洞在什么工作负载下反而是优势？Raft 为了日志连续性放弃了什么？
<details><summary>答案</summary>

高并发写入 + 网络乱序的场景：不同 slot 的 accept 可以并行发出、乱序确认，一个 slot 慢不阻塞其他 slot 的 chosen，旧 leader 崩溃时已确认的 slot 不受未确认的拖累——天然适合流水线与批处理。Raft 的连续性让日志匹配、提交水位、换主都极简（§5 表前三行），但代价是一条慢日志会压住其后所有 index 的推进，也没有乱序确认的自由——用吞吐上限的弹性换了实现与恢复的简单。
</details>

4. 新 leader 上任：Raft 只比较最后一条日志就能确定"数据最全的人"，Multi-Paxos 却要重新探测所有 slot。这个差别源自哪条协议设计？
<details><summary>答案</summary>

源自 Raft 的连续性 + 投票限制的合力：日志按 index 严格连续，且投票时要求候选人日志"至少和我一样新"（[03 章 §4.2](./03-consensus-and-replication.md)），于是"最后一条 (index, term) 最大"者必然包含全部已提交条目——最后一条就是全貌的指纹。Multi-Paxos 的 slot 相互独立，"最后一条"没有含义（可能中间还有空洞），新 leader 只能对全量 slot 重新 prepare，把每个 slot 上各 acceptor 已接受的值探出来再补 no-op。一句话：Raft 用"日志必须连续"这条约束，把恢复成本从 O(日志长) 压到 O(1)。
</details>

5. ZAB 论文把自己的定位写成 atomic broadcast 而不是共识，但 ZooKeeper 用它实现了线性一致的写路径。两者是什么关系？
<details><summary>答案</summary>

全序广播与共识可互相归约：决定"全序日志的第 i 条是什么"，就是做了一次共识；反过来，对每个值跑一次共识再按序编号，就得到全序广播。ZAB 走的是后一条路的工程变体——顺序由 leader 直接给定（primary order），过半 ACK 保证每条提议提交唯一、epoch 否决旧朝，语义上等价于"每 slot 一次的 Paxos"，但把"排序"这件事从协议层挪给了 leader。所以 ZK 的写路径线性一致（[02 章](./02-consistency-models.md) 落位表）不奇怪——它是共识的另一种实现路径，而不是"比共识弱的东西"。
</details>

## 延伸阅读

- The Part-Time Parliament（Paxos 原始论文）：https://lamport.azurewebsites.net/pubs/lamport-paxos.pdf
- Paxos Made Simple（两阶段规则的第一手表述）：https://lamport.azurewebsites.net/pubs/paxos-simple.pdf
- Paxos Made Live（Chubby 团队的工程血泪，本章 §1 的出处）：https://static.googleusercontent.com/media/research.google.com/en//archive/paxos_made_live.pdf
- The Chubby Lock Service（OSDI 2006，生产级 Multi-Paxos 的首次披露）：https://research.google/pubs/the-chubby-lock-service-for-loosely-coupled-distributed-systems/
- Spanner（Paxos group + TrueTime，01 章 TrueTime 的出处）：https://research.google/pubs/pub39966/
- Paxos vs Raft: Have we reached consensus on distributed consensus?（Howard, 2020，本章 §5 对比的依据）：https://arxiv.org/abs/2004.05074
- ZAB 论文（discovery/sync/broadcast 三阶段的原始定义）：https://marcoserafini.github.io/papers/zab.pdf
