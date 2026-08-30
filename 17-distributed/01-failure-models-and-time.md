# 01 · 故障模型与时钟：谱系、物理钟的坑与因果序

> 模块：17-distributed ｜ 建议时长：3 小时 ｜ 关联认证：—（无直接考点；本章回答"系统到底假设了什么会坏"与"为什么两台机器没有同时"，是 02/03 章的前置）

## 学习目标

- 能按谱系说出崩溃停止 / 崩溃恢复 / 遗漏 / 拜占庭四类故障模型的假设，并各举一个已学系统例
- 能解释为什么"宕机判定永远是在猜"，以及 GC 停顿如何把性能问题伪装成宕机（ZK 脑旋元凶）
- 能说清 NTP 的漂移与跳变对监控、证书、定时任务、日志排序各自的杀伤方式，并给出"看斜率不看绝对差"的理由
- 能手推 Lamport 时钟与向量时钟的事件编号，判断两个事件是否并发，说出它们在 etcd revision / ZK zxid / Flink watermark 里的化身
- 能用三步对表法排查"跨节点日志时间线对不上"的问题

## 1. 故障模型谱系：系统假设什么会坏

分布式理论的第一件事不是算法，是把"会坏"说清楚。坏法分四级，一级比一级凶：

```
友好 ◄──────────────────────────────────────────────────► 凶险
 崩溃停止 ──► 崩溃恢复 ──► 遗漏故障 ──► 时序故障 ──► 拜占庭故障
 "挂了就没了"  "挂了会回来"  "消息会丢"   "就是慢"     "节点会撒谎"
```

| 模型 | 假设的坏事 | 系统例（已学） | 运维后果 |
|---|---|---|---|
| 崩溃停止（crash-stop） | 进程一挂永不回来 | 教科书理想化模型，真实系统不适用 | 只用于推导；现实机器会修好重启 |
| 崩溃恢复（crash-recovery） | 进程会带着磁盘状态回来 | etcd（WAL+snapshot）、ZK（事务日志+快照）、Kafka（日志段）、MySQL（redo/binlog） | 恢复=重放日志；**数据目录就是命根子**，丢目录=丢成员身份 |
| 遗漏故障（omission） | 消息丢失 / 心跳断续；网络分区=持续的遗漏 | 任何超时判定都按此建模 | "宕机判定永远在猜"：超时只说明"期限内没收到" |
| 时序故障（timing） | 消息延迟超上限 | 长 GC、swap、盘慢 | 性能毛刺升级成误判主挂，触发无谓 failover |
| 拜占庭（byzantine） | 节点发送错误/矛盾数据 | 磁盘静默损坏、内存位翻转、时钟跳变 | 常规系统只兜一小部分：CRC/校验和+ECC，不做人品担保 |

三点展开：

**崩溃恢复是存储系统的默认假设**。etcd/ZK/Kafka/MySQL 重启后都靠"重放持久化日志"回到崩溃前进度——所以 13 章才反复强调 etcd 数据目录、快照备份（`../04-k8s-fundamentals/13-cluster-admin-and-etcd.md`）；ZK 才有"落后太多的 follower 被 TRUNC 截掉未提交事务"（`../16-bigdata/06-zookeeper.md` 第 3 节）。运维视角的两条推论：恢复时长与日志量成正比（重启不是零成本，发布窗口要算）；重启会掩盖根因，postmortem 必须先抢救崩溃前的日志再动手（`../13-sre-methodology/04-postmortem-runbook.md` 的证据保全思想）。

**遗漏故障是运维每天打交道的那一级**。你看到的所有"down-after-milliseconds / cluster-node-timeout / replica.lag.time.max.ms"超时参数，都是在对遗漏故障建模。既然是猜，就一定有两类错误：把活人判死（误 failover）和把死人判活（脑裂窗口）。治理思路永远是"多节点交叉验证 + 过半才动手"：哨兵先 SDOWN 再问一圈凑 quorum 才 ODOWN（`../11-middleware/redis/02-persistence-and-ha.md` 第 6 节）；Redis Cluster 要"半数以上 master 认为失联"才标 FAIL（同章 Cluster 一节）。

**时序故障最阴险**：JVM 长 GC 让 ZK 节点 30 秒没发心跳，别人以为它挂了，它醒来还以为自己是 Leader——ZK 把"脑旋"第一元凶排在 JVM 长 GC 就是这个原因（`../16-bigdata/06-zookeeper.md`：堆给 3~4GB 而不是越大越好，正是为了缩短 GC）。同一个机制在 Kafka 里叫"落后出 ISR"：判定标准是 `replica.lag.time.max.ms` 内有没有持续 Fetch，**判时间不判条数**（`../12-data-streaming/kafka/02-replication-and-reliability.md` 第 3 节）。

**拜占庭在常规基础设施里只做有限防御**：Kafka 消息带 CRC、HDFS 块带校验和、内存上 ECC，防的是"磁盘静默损坏"这类无主观恶意的撒谎。真拜占庭容错（少数节点恶意构造矛盾消息仍能共识）成本极高，只出现在区块链/航空航天——面试提一句"我们系统的故障模型是崩溃恢复+遗漏，用校验和兜静默损坏"就足够专业了。

## 2. 物理钟为什么不可靠

### 2.1 漂移与跳变：两种坏法

每台机器一块石英表，频率有误差（几十 ppm 量级），**没人校准的话每天能漂几秒**。NTP 的修正分两种，杀伤完全不同：

| 修正方式 | 机制 | 危害 |
|---|---|---|
| 漂移（drift/slew） | 钟快了就调慢点走，慢了调快点，时间轴连续 | 温和，几乎无害；但**累积偏差**本身要监控 |
| 跳变（step） | 差距太大直接一次性拨过去 | 时间轴不连续：定时任务重复执行/整体跳过；TLS/证书校验瞬间失败；依赖墙钟差算耗时的逻辑出现负数或尖刺 |

真实事故模板（Cloudflare 2017 闰秒事件）：Go 1.9 之前的标准库在闰秒回拨时算出负的运行时长，RRDNS 服务大量 panic——一台机器的钟"往回走了 1 秒"，Cloudflare 自家 RRDNS 所服务的客户域名解析大面积失败约一小时。教训不是"别用 Go"，而是：**墙钟可以被拨回去，代码里算耗时绝不能用墙钟相减**（要用单调钟，见 2.3）。

### 2.2 为什么监控看斜率、不看绝对差

三个理由，一个比一个实操：

1. **绝对差有"正常的大"**：不同机型/温度/不同 NTP 源，稳态偏差就是几十毫秒量级，阈值设紧了天天误报、设松了失去意义。危险的不是偏差大，是**偏差在变大**（NTP 失联、钟开始自由漂移）——这是斜率信号。
2. **counter 类指标全靠时间戳算速率**：`rate(node_network_receive_bytes_total[5m])` 的分母就是样本时间戳之差。目标端时钟一跳变，样本时间戳回退/跳跃，速率立刻出现假尖刺或空洞——你会在网络大盘上看到一个不存在的流量突增。08 模块讲过 counter 回绕要用 `increase` 的补偿逻辑（`../08-pca/labs/promql-exercises.md`），时钟跳变是同一家族的坑。
3. **告警要可归因**：`deriv()` 出来的"偏差增长率"突增，指向的就是"这台机器的 NTP 刚断"，一眼可归因；绝对差告警触发了你还得先查半天是不是一直如此。

```promql
# [本地Windows·浏览器] 在 Prometheus 上看时钟：先看偏差（绝对差），再看偏差的变化率（斜率）
max by (instance) (node_timex_offset_seconds)      # 当前与 NTP 源的偏差秒数
deriv(node_timex_offset_seconds[30m])              # 偏差的增长速度：正/负持续增长 = 正在失联漂移
max by (instance) (node_timex_sync_status)         # 0 = 已失联，最直接的硬告警
# 指标来自 node_exporter 的 timex 采集器，指标名以官方 README 为准：
# https://github.com/prometheus/node_exporter
```

运维底线：集群所有节点统一 NTP 源；对 `sync_status=0` 与 `offset` 斜率持续非零做告警；**跳变操作（chrony 的 `makestep`）尽量限定在启动时**，运行中的节点要拨钟先摘流量。

### 2.3 墙钟与单调钟：代码里的选择

| 时钟 | 例 | 特点 | 该用来干什么 |
|---|---|---|---|
| 墙钟（wall clock） | `CLOCK_REALTIME` / `date` | 绝对时间，**可被 NTP 拨动**（可回退） | 展示、对账、证书有效期 |
| 单调钟（monotonic clock） | `CLOCK_MONOTONIC` / Go 的 `time.Since` | 只向前走，与外界无关 | **一切耗时/超时/重试间隔计算** |

这解释了两个已学事实：OTel SDK 的 span duration 用单调钟测，所以**单条 span 的耗时可信，而跨服务的瀑布图边界依赖各节点墙钟**（`../09-otel/02-instrumentation.md` 的埋点语义）；kubeadm 证书一年有效期（`../04-k8s-fundamentals/13-cluster-admin-and-etcd.md` 证书表）怕的正是节点钟被拨到过期之外。Jenkins agent 掉线的常见根因表里直接写着"agent 机器时间漂移，检查 NTP"（`../06-cicd-iac-gitops/03-jenkins-and-github-actions.md`）。

## 3. Lamport 逻辑钟与向量钟：因果序

### 3.1 物理钟给不了的东西：happens-before

"先于"（→）在分布式里有严格定义，且**不依赖任何时钟**：

1. 同一进程内，事件 a 在 b 之前：a → b；
2. a 是发送消息的事件，b 是接收同一消息的事件：a → b；
3. 传递：a → b 且 b → c，则 a → c。

**并发**：既不 a → b 也不 b → a。注意"并发"不等于"同时"——它只说明两者之间没有因果链，墙钟上可能差了半小时。

### 3.2 两种逻辑钟

**Lamport 时钟**：每个进程一个计数器。本地事件 +1；发消息把自己的计数带上，接收方取 `max(自己, 收到的)` 再 +1。保证：a → b ⇒ C(a) < C(b)。**但逆命题不成立**——编号小不等于发生在前，编号相等的两个事件可能毫无关系。

**向量钟**：每个进程维护"我看到的全体进程各自到几号了"的向量。更新规则同上但按分量取 max。它比 Lamport 强在**能判定并发**：比较两向量，若互不小于等于，则两事件并发。代价：消息要带 O(N) 大小的向量，成员多了就贵。

```
[图] 三进程因果链（■=本地事件，─►=消息）

P1  a■────────────►┐          a→b→c→d 是因果链（同一个请求的接力）
                   ▼          y 与 a/b/c 并发（无任何消息连接）
P2        b■──c────────►┐     y→d（d 在 P3 上排在 y 之后）
                       ▼     墙钟顺序（伪造）：y < d < a < b < c
P3     y■            d■      ──"P3 先记账，P2 才收到请求"的假象
```

### 3.3 用途与真实系统里的化身

用途排第一的是**排障**：跨机日志没法用墙钟排因果（见 2.1），只能靠"消息里带的序号"重建因果链——实战演练二的脚本就演示这件事。排第二的是**冲突检测**：Dynamo/Riak 用向量钟变体判断两个写是否并发，并发才要求应用层合并。

你已经在用的三个"逻辑钟化身"：

| 已学机制 | 本质 | 出处 |
|---|---|---|
| etcd 全局单调 revision | 把所有写排进一条全序日志，比向量钟更强（全序广播，03 章） | `../04-k8s-fundamentals/02-architecture-and-control-loop.md`（resourceVersion 的来源） |
| ZK 的 zxid=(epoch,counter) | "朝代+朝内序号"，字典序即全局序 | `../16-bigdata/06-zookeeper.md` 第 3 节 |
| Flink watermark | 事件时间维度的时钟推进承诺："事件时间 ≤ T 的数据基本到齐了" | `../12-data-streaming/flink/01-stream-processing-model.md` 第 3 节 |

Flink 那条尤其值得回味：watermark 取**所有输入的最小值**——任何一个上游没推进，下游时钟就停着。这和向量钟"按全体进程看进度"是同一个思想：**自己的进度不算数，全体都知道的进度才算数**。

## 4. Google TrueTime：用硬件换"时间戳本身可信"

一段讲完。Spanner 不用逻辑钟，而是让每个数据中心装 GPS 天线+原子钟，TrueTime API 返回的不是时刻而是一个**区间** `TT.now() ∈ [earliest, latest]`，典型宽度几毫秒。事务提交时要等这个区间"过去"（commit wait）才对外可见，于是换来**外部一致性**：事务的时间戳与真实时间的先后关系严格成立——比线性一致更强（线性一致+事务序+真实时间序，02 章对照）。

代价明码标价：专有硬件、GPS 天线与原子钟的运维、每次提交多等一个区间宽度。对照结论：**线性一致不需要真时钟**——etcd/ZK 用 Raft/ZAB 的日志序（纯逻辑钟）就达成了线性一致；TrueTime 买的是"时间戳可跨系统比较"这件事本身（快照读、跨库对账）。面试一句话："TrueTime 是把 NTP 的不确定度从秒级压到毫秒级并写进 API 语义，etcd 则干脆不依赖物理时间。"

## 5. 运维含义：日志时间戳对齐的坑

跨节点排查时最常见的幻觉："应答的日志时间比请求还早 / 两边各说各话"。四条纪律：

1. **先对表再读时间线**（三步，见实战演练三）：量出偏差量，带着偏差读日志；
2. **单 span 耗时可信，跨节点边界 ± 时钟偏差**：瀑布图上服务 A→B 的"网络段"若与两节点钟差同量级，结论就是"测不准"，别硬归因；
3. **跨机日志要靠 ID 串联而不是时间**：trace_id、request_id、Kafka 消息 key/offset、etcd revision——它们是因果序的载体，墙钟只是展示格式；
4. **消息自带时间戳要分清语义**：Kafka record 的 timestamp 是 CreateTime（生产端钟）还是 LogAppendTime（broker 钟），含义完全不同（`../12-data-streaming/kafka/01-log-model-and-architecture.md`，以官方文档为准）。

## 实战演练

**演练一：量化集群时钟偏差**

```bash
# [master] 三行连跑：本地时刻 → worker 时刻 → 本地时刻
date +%s.%N
ssh cka000002 'date +%s.%N'
date +%s.%N
# 解读：worker 值应落在两次本地采样之间；差值 ≈ 真实钟差 + ssh 单程耗时
# 若差值超过 0.1s，这台机器的 NTP 大概率出问题了

# [master] 确认 NTP 状态（Ubuntu 默认 systemd-timesyncd；装了 chrony 用 chronyc tracking）
timedatectl | grep -E "synchronized|NTP|Time zone"
# 预期：System clock synchronized: yes / NTP service: active
```

**演练二：亲手跑一次因果排序（Lamport + 向量钟）**

```bash
# [任意节点] 写出演示脚本并运行（纯离线计算，不依赖集群；本地 Windows 有 Python 亦可直接 python lamport_demo.py）
cat > /tmp/lamport_demo.py <<'EOF'
N = 3  # 进程 P1/P2/P3

class P:
    def __init__(self, pid):
        self.pid, self.l, self.v = pid, 0, [0] * N

events = []  # (名字, 进程, 伪造墙钟, Lamport, 向量钟)

def local(p, name, wall):
    p.l += 1; p.v[p.pid] += 1
    events.append((name, p.pid + 1, wall, p.l, tuple(p.v)))

def send(pf, pt, sname, swall, rname, rwall):
    local(pf, sname, swall)
    ml, mv = pf.l, tuple(pf.v)                      # 消息携带发送方时钟
    pt.l = max(pt.l, ml) + 1
    pt.v = [max(x, y) for x, y in zip(pt.v, mv)]
    pt.v[pt.pid] += 1
    events.append((rname, pt.pid + 1, rwall, pt.l, tuple(pt.v)))

def precedes(a, b):
    return all(x <= y for x, y in zip(a, b)) and a != b

p1, p2, p3 = P(0), P(1), P(2)
# 墙钟是伪造的：P3 的钟慢了约 1 秒，制造"因果倒置"假象
send(p1, p2, "a P1发下单请求", 1.210, "b P2收到并扣库存", 1.215)
local(p3,   "y P3无关的本地写", 0.090)
send(p2, p3, "c P2转发扣减结果", 1.220, "d P3记账", 0.100)

print(f"{'事件':<18}{'进程':<4}{'墙钟':>7}{'Lamport':>9}{'向量钟':>14}")
for n, p, w, l, v in events:
    print(f"{n:<18}P{p:<3}{w:>7.3f}{l:>9}{str(v):>14}")

print("\n按墙钟排序（跨机 grep 日志的默认视角）:")
for e in sorted(events, key=lambda e: e[2]):
    print("  ", e[0])

pairs = [("b P2收到并扣库存", "y P3无关的本地写"), ("a P1发下单请求", "d P3记账")]
idx = {e[0]: e for e in events}
print("\n因果判定（向量钟）:")
for an, bn in pairs:
    a, b = idx[an], idx[bn]
    if precedes(a[4], b[4]):
        print(f"  {an}  -->  {bn}")
    elif precedes(b[4], a[4]):
        print(f"  {bn}  -->  {an}")
    else:
        print(f"  {an}  ||  {bn}   <- 并发（无因果链）")
EOF
python3 /tmp/lamport_demo.py
```

预期输出（节选，向量钟列为逐事件实算值）：

```
事件                进程  墙钟  Lamport  向量钟
a P1发下单请求      P1    1.210        1     (1, 0, 0)
b P2收到并扣库存    P2    1.215        2     (1, 1, 0)
y P3无关的本地写    P3    0.090        1     (0, 0, 1)
c P2转发扣减结果    P2    1.220        3     (1, 2, 0)
d P3记账            P3    0.100        4     (1, 2, 2)

按墙钟排序: y → d → a → b → c
  ↑ 假象：P3"先记账"，P2"后收到请求"——纯粹是 P3 的钟慢了
因果判定: b || y（并发）；a --> d（同一请求链的起点与终点）
```

验证方法：改伪造墙钟（比如把 d 改成 5.0）再看墙钟排序变化，而向量钟判定纹丝不动——**因果与钟无关**。Windows 本机跑若中文乱码，用 `python -X utf8 /tmp/lamport_demo.py`。

**演练三：三步对表法（跨节点日志排查的固定开场）**

```bash
# [master] 第一步：量偏差（同演练一），记下毫秒数 D
date +%s.%N && ssh cka000002 'date +%s.%N' && date +%s.%N

# [master] 第二步：取同一条链路两端的日志时刻（示例：apiserver 侧 Pod 日志 vs 节点墙钟）
kubectl -n kube-system logs etcd-"$(hostname)" --timestamps 2>/dev/null | tail -2
date -u +"%Y-%m-%dT%H:%M:%SZ"

# [master] 第三步：读时间线时刻意把另一端的时刻补上 D 毫秒再比较，仍对不上才谈下一步
#（--timestamps 打的是日志被采集侧的时刻，与本节点墙钟本就有微小出入）
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 跨机日志"应答早于请求" | 节点钟差大于请求耗时 | 三步对表法；关键链路用 trace_id 串联而非时间排序 |
| 网络流量大盘突然出现尖刺，设备侧无感知 | 目标端时钟跳变，rate() 分母错位 | 查 `node_timex_sync_status` 与 offset 斜率；排除后再谈容量 |
| 节点反复"被判定宕机又回来" | 长 GC/盘慢造出时序故障（ZK 脑旋元凶） | 缩 GC 停顿、事务日志独立盘、调超时前先治慢 |
| cron 任务跨节点重复/漏跑 | NTP 跳变让墙钟回退或前跳 | 跳变限制在启动时；关键任务加分布式锁+幂等 |
| 新节点加入集群被拒（证书/授权失败） | 该机时钟偏离导致证书校验不过 | 先修 NTP 再排证书链（../05-cka/05-secrets-and-cert-troubleshooting.md） |
| "重启就好了"的故障反复出现 | 崩溃恢复掩盖根因，日志没保全 | 重启前先抓现场（journal/日志/heap dump），见 13-sre-methodology/04 |
| span 瀑布图里服务间耗期为负数 | 两端墙钟相减 | 单段耗时看 span 内部（单调钟）；跨段结论只说"±钟差" |

## 自测

1. 为什么说"所有宕机判定都是在猜"？哨兵的 SDOWN/ODOWN 两步设计如何降低猜错的代价？
<details><summary>答案</summary>

超时只能证明"期限内没收到应答"，无法区分对方挂了、网络断了、对方在长 GC。猜错的两类代价：误判活人→无谓 failover；误判死人→脑裂窗口。哨兵用"主观下线（一个哨兵的猜测）+ 客观下线（问一圈，够 quorum 才算数）"把单个节点的猜测升级为多数派的交叉验证；真正执行 failover 还要再过 majority 授权一层（quorum 与 majority 是两回事）。本质是用空间（多哨兵）换判断可靠性。
</details>

2. ZK 把"堆给 3~4GB 而不是越大越好"写进运维建议，这背后是哪一类故障模型问题？
<details><summary>答案</summary>

时序故障：堆越大，Full GC 停顿越长，节点在停顿期间"表现成"遗漏心跳→被猜死→触发重新选举；醒来后角色已变，又可能再震荡（脑旋）。这是"性能参数（GC 停顿）改变故障表现（心跳超时）"的典型案例——故障模型不是玄学，它落在每个 JVM/超时参数上。
</details>

3. Lamport 时钟满足 a → b ⇒ C(a) < C(b)，为什么还说它"不能排因果"？向量钟补上了什么？
<details><summary>答案</summary>

因为逆命题不成立：C(a) < C(b) 时 a、b 可能只是并发（各自 +1 得到的编号没有可比性），用 Lamport 编号排序会把并发事件硬排成先后，结论无意义。向量钟按分量比较双方"看到的全体进度"，能严格判定并发（互不小于等于）；代价是消息携带 O(N) 向量。所以重建因果链要么向量钟，要么像 etcd 那样直接上全序日志（revision）。
</details>

4. Flink 的 watermark 取所有输入 channel 的最小值，这与向量钟"看全体进度"的思想如何对应？
<details><summary>答案</summary>

算子只有确信"所有上游里事件时间 ≤ T 的数据都不会再来"才能安全推进自己的事件时间钟；取最小值正是"全体都知道的进度才算数"。改成取最大值，快的那条输入会提前越过窗口边界，慢输入的数据全部沦为迟到——结果错误且不可恢复。这与向量钟"按全体分量取 max 合并、任何一个落后都能被看出"共享同一个底层直觉：分布式里没有"我的进度"，只有"大家眼中的进度"。
</details>

5. 为什么 TrueTime 要返回区间而不是时刻？etcd 不用任何特殊硬件也做到了线性一致，Spanner 到底多买了什么？
<details><summary>答案</summary>

物理钟有不确定度，TrueTime 诚实地把它暴露成 [earliest, latest]：只要等这个区间"过去"（commit wait），就能保证事务的真实发生时间严格早于时间戳，从而时间戳可跨事务/跨系统比较（外部一致性）。etcd 用 Raft 日志序达成线性一致，不需要真时钟；Spanner 多买的是"时间戳本身携带真实时间语义"——全球快照读、跨库对账、与外部系统的先后仲裁。一句话：一致性可以从日志序来，但"几点发生的"只能从钟来。
</details>

## 延伸阅读

- Lamport《Time, Clocks, and the Ordering of Events in a Distributed System》（1978，分布式开山之作）：https://lamport.azurewebsites.net/pubs/time-clocks.pdf
- Spanner 论文（TrueTime 与外部一致性的原始定义）：https://research.google/pubs/pub39966/
- NTP 公共池（NTP 服务与文档入口）：https://www.ntppool.org/
- chrony 文档（漂移/跳变/makestep 语义）：https://chrony-project.org/docs/
- node_exporter（timex 采集器与时钟指标）：https://github.com/prometheus/node_exporter
- FLP 不可能定理原文：https://groups.csail.mit.edu/tds/papers/Lynch/jacm85.pdf
