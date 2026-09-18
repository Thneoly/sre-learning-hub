# 01 · 经典故障复盘故事集：四次学费昂贵的课

> 模块：22-incident-stories ｜ 建议时长：3 小时 ｜ 关联认证：—（无直接考点，串联 CKA-排障、13-middleware、15-sre-methodology 复盘模板）

## 学习目标

- 能顺着时间线读出"故障的因果链"：触发 → 促发因素 → 放大器 → 兜底缺失，而不是只记最后那个"背锅的"动作
- 能识别四个高频故障族的早期信号：级联驱逐、缓存雪崩、控制面存储打满、慢查询拖垮连接池
- 能从每个故事的"误判"里提炼探测顺序——先看什么、什么证据能一票否决一个假设
- 能把故事里的短期止血与长期修复区分开，并说出每条长期修复"防的是哪一环"
- 能对照 ../15-sre-methodology/04-postmortem-runbook.md 的复盘模板，独立复述每篇的时间线与根因

## 0. 怎么读这些故事

四个故事改编自真实的故障模式（人物、公司与数字均为虚构，机制与探测手段均可对照本学习中心的章节验证）。每篇固定七段：**背景 → 时间线 → 探测与误判 → 根因 → 短期修复 → 长期修复 → 教训**，与 ../15-sre-methodology/04-postmortem-runbook.md 第 2 节的无责复盘模板一一对应（时间线只记事实、根因与促发因素分开列、行动项可跟踪）。读法建议：先只看"背景 + 时间线"，自己推一遍"下一步查什么"，再对照"探测与误判"——误判段比根因段更值钱，因为考试和面试考的是排查路径，复盘里最贵的也是走弯路的那二十分钟。

叙事视角提醒：故事里"某人误判了"指的都是**当时信息下的合理决策**，事后看才错——这正是无责复盘的前提。如果你的第一反应也是"重启一下试试"，说明这个故事就是为你写的；读的时候把自己代入值班席，而不是法官席。

## 故事 1：一次 PDB 缺失引发的级联驱逐

### 背景

支付网关 `pay-gw`，3 副本 Deployment，跑在 6 节点的生产集群。周四晚集群例行升级内核，运维按维护手册对节点逐台 `drain`。手册写于半年前，那时 `pay-gw` 还是 1 副本的小服务；如今它是交易主链路，但没人把这件事跟"维护操作"联系起来——也没配 PodDisruptionBudget。

```
 6 节点集群（pay-gw 3 副本，无反亲和约束，调度随机落位）
 node1★(维护中)  node2  node3   node4   node5   node6
 [pay-gw-2]     [pay-gw-1]    [pay-gw-0]
                [svc-b ×4]    [svc-b ×6]         [大数据任务×N]
 ★ drain 顺序第一台 → 驱逐 pay-gw-2 → 新副本只能调度进"别人家"的余量
```

### 时间线

| 时间 | 事件（事实） | 当时的判断 |
| --- | --- | --- |
| 01:55 | cordon node1，开始 drain | "例行操作，手册步骤 3" |
| 02:01 | node1 上 Pod 被逐批驱逐，`pay-gw-2` 在列 | 无告警关联——服务级告警基于"存活副本数 ≥ 2"，此时仍满足 |
| 02:04 | `pay-gw` 新副本 Pending：`Insufficient cpu`（大数据任务占满其余节点 requests） | 值班看到交易 p99 开始抬升，怀疑"晚上跑的批处理抢资源" |
| 02:07 | 剩余 2 副本扛全量流量，p99 从 80ms 涨到 2.4s | 误判一：以为是单笔慢查询污染统计 |
| 02:12 | 错误率突破 SLO，支付成功率跌破 99.9% | 误判二：怀疑 02:00 发布的版本，开始翻 commit |
| 02:21 | 有人翻 Events：`Evicting pod pay-gw-2`，对上时间 | 定位：驱逐 + 调度失败级联 |
| 02:26 | 暂停维护（停止 drain 后续节点），手动清出资源 | 恢复动作开始 |
| 02:41 | `pay-gw` 恢复 3 副本，指标回落 | — |

### 探测与误判

走的最长的弯路是"翻发布记录"：02:12 到 02:21 共 9 分钟花在 diff 一个与故障无关的版本上。回头看，一票否决的证据早就摆在 Events 里——驱逐事件的时间戳与 p99 抬升精确对齐；而"发布导致"的假设解释不了"为什么恰好从 drain 第一台节点开始"。两条本可更早触发的信号：`kubectl get events --sort-by=.lastTimestamp` 里成串的 `Evicting`；以及"存活副本数 ≥ 2"这种**静态阈值告警**对"容量正在被吃掉"完全不敏感——副本活着，但余量没了（容量视角见 ../21-perf-testing/02-capacity-planning.md 第 1 节的 N-1 原则）。

```bash
# [master] 事后复盘补做的两条"当时就该跑"的查询
kubectl get events --sort-by=.lastTimestamp | grep -Ei 'evicting|failedscheduling'
kubectl get pdb -A        # 输出为空——全集群一个 PDB 都没有，这条空输出本身就是根因的一半
```

如果有 PDB（`minAvailable: 2`），同一晚的时间线会是这样：

```
 drain node1 → eviction API 检查 PDB：3-1=2 ≥ minAvailable=2 → 放行驱逐
   → 副本重建落在其他节点（调度账有余量时）→ pay-gw 始终 ≥ 2 → 指标无感
 drain node2 → 2-1=1 < 2 → PDB 挡下，drain 卡住重试 → 维护被迫等待/协调
   （代价：drain 会"卡住"——这不是故障，是保护在起作用；运维改用先扩容再 drain 的顺序）
```

### 根因

根因：`pay-gw` 无 PodDisruptionBudget，drain 的驱逐不被任何"服务可用副本下限"约束；同时无反亲和/拓扑打散约束，3 副本的实际落位与维护顺序没有参与方知道。促发因素：其余节点 requests 被大数据任务占满，被驱逐副本**调度失败**而非仅仅是"换台机器"；维护手册与服务的成长脱节（半年前 1 副本，如今主链路 3 副本）。放大器：服务告警只盯"副本数"，不盯"驱逐事件 + 调度水位"。

### 短期修复

当晚：停止后续 drain，腾出 node6 的 requests 余量（暂停一个可重跑的大数据任务），让 Pending 副本落地；确认指标回落后维护改期。

### 长期修复

- 所有 multi-replica 生产服务强制配 PDB（`minAvailable` 或 `maxUnavailable`），drain 会被 PDB 挡住重试而不是硬闯——这正是 05-cka/06-node-maintenance-troubleshooting.md 第 1 节讲的 evict 与 delete 的差别
- 副本加 `topologySpreadConstraints`/反亲和，把"3 副本落 3 台节点"变成调度器的硬约束，而不是运气
- 维护 runbook 增加前置检查：`kubectl get pdb -A` 核对目标服务、`kubectl describe node` 核对余量；逐台 drain、每台之间观察服务指标
- 告警补"驱逐 + Pending"维度：Events 里的 `Evicting` 与 `FailedScheduling` 进监控，而不只看副本数

### 教训

1. drain 不是无害操作：它是"计划内的小规模故障"，PDB 是服务方与运维之间的契约，缺了它，维护动作就变成了一次没有爆炸半径控制的混沌实验。
2. 故障排查第一步永远是对时间轴：把"变更（含维护）时间"与"指标拐点"画在同一张图上，误判二那 9 分钟本可省掉。
3. "副本活着"不等于"容量够"：调度账（requests）被占满时，故障恢复路径本身会被堵死——容量与可用性是同一件事（../21-perf-testing/02-capacity-planning.md 第 3 节）。

**关联阅读**：04-k8s-fundamentals/08-scheduling.md 第 6 节（调度失败 vs 驱逐）；05-cka/06-node-maintenance-troubleshooting.md 第 1 节（drain/evict/PDB）；场景索引见 [SCENARIOS.md](../SCENARIOS.md) §3 工作负载（"分不清调度失败还是被驱逐"、"drain 卡住"两条）。

## 故事 2：缓存雪崩打穿数据库

### 背景

电商详情页：nginx → `detail-api`（20 副本）→ Redis（1 主 2 从 + 哨兵）→ MySQL（16C64G，`max_connections` 800，应用侧每副本连接池上限 30）。商品数据缓存 TTL 30 分钟。大促晚八点，运营提前把**整点开抢的一万个商品 key 在 19:31 同时写入**并设置同样的 30 分钟 TTL。

```
 20:01:31（19:31 + 30min）一万个 key 同刻过期
 ┌────────┐ miss ┌────────┐ 穿透 ┌────────┐
 │ Redis  │ ───→ │ detail │ ───→ │ MySQL  │ ← 20 副本 × 池 30 = 600 并发上限
 │ 命中 0%│      │ -api   │      │ 800 连接│    等待队列溢出 → 全站超时
 └────────┘      └────────┘      └────────┘
```

### 时间线

| 时间 | 事件 | 当时的判断 |
| --- | --- | --- |
| 20:00 | 活动开始，Redis 命中率 98%，一切正常 | — |
| 20:01 | 命中率掉到 11%，MySQL `Threads_connected` 从 90 爬向 800 | 以为是活动流量大，"扛一下就过去了" |
| 20:03 | MySQL `Threads_running` 300+，CPU 100%，慢查询堆积；应用连接池等待计数暴涨 | 误判一："数据库挂了"，有人提议重启 MySQL |
| 20:05 | 重启提案被否（主库重启=故障升级），改查 PROCESSLIST：大量同一张表的回源查询 | 定性：缓存大面积失效后的穿透 |
| 20:07 | 哨兵因高负载误判主库主观下线，触发一次 failover，雪上加霜（约 12 秒不可用） | — |
| 20:12 | 打开降级开关：回源查询熔断 + 本地缓存兜底 + 非核心接口直接返回默认数据 | 恢复动作开始 |
| 20:25 | MySQL 连接回落，p99 恢复 | — |

### 探测与误判

关键分流点在 20:03 到 20:05 的两分钟：**"数据库挂了"与"数据库被打穿了"是两个相反方向的假设**——前者该看 `mysql_up`、进程、错误日志；后者该看 `Threads_running` 与 PROCESSLIST 里"查询是否都是同一模式"。一票证据是 `SHOW PROCESSLIST`：几百条同样的 `SELECT ... FROM goods WHERE id = ?`，全是缓存回源路径。另一个本可更早的信号：`redis_keyspace_hits_total / misses_total` 的断崖（13-middleware/redis/03-caching-patterns-troubleshooting.md 第 5 节的命中率告警），它的拐点比 MySQL CPU 早 90 秒。提议重启 MySQL 是最危险的一念：连接打满时重启，等于把"慢"升级成"不可用"（判断依据见 13-middleware/mysql/03-tuning-troubleshooting.md 第 4 节"先留证据再 KILL"）。

```bash
# [任意节点] 当时现场的三条证据采集（数值为示意）
redis-cli -h <redis-host> INFO stats | grep -E 'keyspace_hits|keyspace_misses'
#   keyspace_hits:1024  keyspace_misses:8291   ← 命中率从 98% 掉到 11% 的实锤
```

```sql
-- [任意节点] DB 侧分型三板斧
SHOW GLOBAL STATUS LIKE 'Threads_connected';   -- 798 / 800，水位贴顶
SHOW GLOBAL STATUS LIKE 'Threads_running';     -- 310，不是闲置连接，是真忙不过来
SELECT state, COUNT(*) FROM information_schema.processlist
  GROUP BY state ORDER BY 2 DESC;              -- 大头是 executing/Sending data 的同模式查询
```

20:07 哨兵的那次 failover 值得单独记：高负载下主库响应 PING 超时，哨兵按规则判定"主观下线"并完成切换——**机制本身没错，错在让系统忙到逼近哨兵的超时线**。恢复期约 12 秒不可用，叠加在穿透之上，这提示容量规划要给"哨兵判定余量"留出空间（判定参数与负载的关系见 13-middleware/redis/02-persistence-and-ha.md 常见坑）。

### 根因

根因：同刻批量过期的 TTL 设计 + 缓存 miss 后无并发控制（同一商品的上百个请求各自回源，没有 singleflight/互斥重建）。促发因素：DB 连接容量按"日常命中率 98%"估算，从未按"缓存 0 命中"场景压测过；哨兵在高负载下的 failover 又叠加了一层抖动（负载与误判的关系见 13-middleware/redis/02-persistence-and-ha.md 常见坑）。放大器：无熔断降级预案，穿透一路传导到底层。

顺带把三个近义故障分清（详解见 13-middleware/redis/03-caching-patterns-troubleshooting.md 第 1 节）：

| 名词 | 一句话 | 本故事命中 |
| --- | --- | --- |
| 穿透 | 查"根本不存在的数据"，缓存永远无法命中，每次都打 DB | 否 |
| 击穿 | 单个热点 key 失效瞬间，并发全部涌向 DB | 部分（叠加项） |
| 雪崩 | **大批 key 同刻失效**，回源洪峰整体超过 DB 容量 | 是 |

### 短期修复

当晚：开启回源熔断（每秒放行少量重建请求）+ 本地缓存承接热点 + 关闭非核心接口；对已过期的热点 key 用脚本分批预热回填。

### 长期修复

- TTL 加随机抖动（基础值 ± 20%），批量写入的 key 分散过期——一条配置改动，消灭整类事故
- 回源路径加并发合并（互斥锁/singleflight）：同一 key 并发 miss 只放一个请求穿透
- 容量按最坏情况核算：压测"缓存全失效"场景下的 DB 拐点（方法用 ../21-perf-testing/01-load-testing-tools.md 的开环阶梯），据此定熔断阈值与 DB 规格
- 命中率、eviction、连接水位进告警（基线表见 ../21-perf-testing/02-capacity-planning.md 第 4 节）
- 降级开关做成常备预案并纳入演练，而不是"当晚现想"

### 教训

1. 缓存层的容量假设（"命中率 98%"）是整个系统的容量假设的一部分——它失效的那 90 秒，DB 的容量规划瞬间变成错的。
2. "重启数据库"在连接打满场景是反向操作：先分型（慢/挂/被穿透），再动手；PROCESSLIST 是分型入口。
3. 每层都要有"我自己挡不住时保护下游"的机制：熔断、限流、本地兜底——雪崩的本质是**没有一层肯牺牲自己**。

**关联阅读**：13-middleware/redis/03-caching-patterns-troubleshooting.md 第 1 节（穿透/击穿/雪崩）与第 3 节（阻塞点四类元凶）；13-middleware/mysql/03-tuning-troubleshooting.md 第 4 节（连接打满分型）；场景索引见 [SCENARIOS.md](../SCENARIOS.md) §4 存储与中间件（"Redis 突发超时但 SLOWLOG 是空的"、"MySQL 1040 Too many connections"两条）。

## 故事 3：etcd 磁盘满导致控制面瘫痪

### 背景

3 master 的 kubeadm 集群，etcd 数据盘 50GB（默认 backend 配额 2GB）。某周起，一个新上线的故障自愈 Agent 开始把每次探活失败的大段报文（含堆栈与上下文）写进 CRD 的 status，每分钟数百次；同时审计日志与容器日志在同一块盘上增长。周五 16:52，etcd 触发 NOSPACE 告警并进入只读保护。

### 时间线

| 时间 | 事件 | 当时的判断 |
| --- | --- | --- |
| 16:52 | etcd 日志：`raising NOSPACE alarms`，拒绝写入 | 无人在看 etcd 日志——告警打的是"kube-apiserver 超时" |
| 16:54 | `kubectl get` 变慢，`create/apply` 大面积超时；CI 部署全部卡死 | 误判一："API server 挂了"，提议重启 apiserver |
| 16:58 | 重启 apiserver 无效（问题不在它）；业务侧确认：**已有 Pod 继续正常服务**，但无法扩缩容、无法新建 Pod | 误判二："网络问题"，去查 LB 与防火墙 |
| 17:10 | 值班按"五层定位法"上到控制面存储层：`etcdctl alarm list` 返回 `NOSPACE`；`df -h /var/lib/etcd` 91% | 定位：etcd 后端配额 + 磁盘双重打满 |
| 17:18 | 找到写入大户：CRD `selfhealreports`，对象平均 1.8MB、revision 每分钟 +400 | 根因落点 |
| 17:25 | compact → 逐成员 defrag → `alarm disarm` | 恢复动作开始 |
| 17:40 | apiserver 写入恢复，CI 队列排空 | — |

### 探测与误判

两个误判的共性：**在"控制面故障"里先怀疑组件与网络，最后才怀疑存储**。纠偏的关键证据链只有三步：已有 Pod 不受影响（数据面活着，问题圈定在控制面）；`kubectl -v=8` 显示请求卡在 apiserver 到 etcd 的调用上；`etcdctl alarm list` 一锤定音。事后的"本可更早"：磁盘水位告警阈值为 90%——配额 2GB 在 50GB 的盘上**永远先于磁盘告警触发**，监控没盯 `etcdctl endpoint status` 的 `DB SIZE`，等于给最重要的组件留了盲区（etcd 的读写路径与配额机制见 04-k8s-fundamentals/13-cluster-admin-and-etcd.md 第 2 节）。

```bash
# [master] 定位链三步（kubeadm 集群 etcd 证书在 /etc/kubernetes/pki/etcd/ 下）
ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://127.0.0.1:2379 endpoint status -w table   # DB SIZE 一列贴着 2.0GB 配额
ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
  --endpoints=https://127.0.0.1:2379 alarm list                  # alarm:NOSPACE
df -h /var/lib/etcd                                              # 91%，两把尺子都满了
```

### 根因

根因：把大对象高频写进 etcd（CRD status 平均 1.8MB，revision 高速膨胀），配额打满触发 NOSpace 只读保护。促发因素：同盘混放审计日志/容器日志，磁盘水位与 etcd 配额两把尺子没人分别盯；defrag/compact 从未纳入例行运维，历史 revision 无限累积。放大器：etcd 是控制面的唯一真相源，它只读后调度、扩缩容、自愈全部停摆——连"自愈 Agent"都在往害它的方向写。

### 短期修复

```bash
# [master] 恢复三步：压缩 → 逐成员碎片整理 → 解除告警（顺序不能乱：先 compact 再 defrag）
# 三条命令的证书参数同上一代码块，为省篇幅用变量代换
export ETCDCTL_API=3
E="--cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key --endpoints=https://127.0.0.1:2379"
rev=$(etcdctl $E endpoint status -w json | grep -o '"revision":[0-9]*' | head -1 | cut -d: -f2)
etcdctl $E compact "$rev"        # 压缩历史 revision
etcdctl $E defrag                # 逐成员串行做：换下一个 --endpoints 再跑，别三台同时
etcdctl $E alarm disarm          # 解除 NOSPACE（本身要走一次 Raft 写，确认多数派健康后再做）
```

同时下线自愈 Agent 的大对象写入（改投 Kafka），清理同盘日志。三步的原理与风险展开见 19-distributed/11-coordination-tools.md 第 6.1 节；备份与证书三件套的常见坑见 05-cka/04-etcd-backup-restore.md。

### 长期修复

- 监控两把尺子分开盯：`etcdctl endpoint status` 的 DB SIZE 对 backend 配额、`df` 对磁盘水位（各自告警阈值 = 各自上限的 70%）
- etcd 不存大对象：CRD 设计评审加单对象大小与更新频率红线；大报文走消息系统，etcd 只留索引
- 例行 compact（低峰定时）+ defrag（逐成员、避开高峰），纳入 runbook（完整空间治理见 19-distributed/11-coordination-tools.md 第 6.1 节）
- 审计日志、容器日志与 etcd 数据分盘；控制面组件的磁盘单独做容量基线

### 教训

1. 数据面无恙 + kubectl 卡死 = 控制面问题，etcd 是第一嫌疑人——这条指纹能省掉 16:54 到 17:10 的两次误判。
2. 告警阈值要贴着**真实上限**配：2GB 配额在 50GB 磁盘上，磁盘告警永远不会先响。
3. etcd 的容量纪律与备份纪律同级（05-cka/04 已把备份当考点），它是集群的"单点真相"，对它的每一次写都该问一句"这东西配进 etcd 吗"。

**关联阅读**：04-k8s-fundamentals/13-cluster-admin-and-etcd.md 第 2 节与常见坑（NOSPACE 条目）；19-distributed/11-coordination-tools.md 第 6.1 节（备份恢复与空间治理）；05-cka/04-etcd-backup-restore.md；场景索引见 [SCENARIOS.md](../SCENARIOS.md) §1 集群与控制面（"集群只读、大面积超时 alarm NOSPACE"、"compact+defrag 后仍拒绝写"、"defrag 后集群抖动"三条）。

## 故事 4：一条慢查询拖垮整个连接池

### 背景

订单服务 `order-api`（8 副本，每副本 MySQL 连接池上限 25）挂在 16C 的 MySQL 前。周二 14:00 新版本上线，其中一处列表查询新增了 `ORDER BY created_at` 排序——该列没有索引，且 `WHERE` 里的等值条件发生了隐式类型转换（varchar 列用了数字比较），两条加起来，单条查询从 15ms 变成 4.2s。

```
 单请求占连接 4.2s，每秒 60 次 → 稳态需要并发连接 ≈ 60 × 4.2 ≈ 252
 可用上限 = 8 副本 × 池 25 = 200 < 252 → 池耗尽，请求在应用侧排队
 （Little 定律：需要的并发 = 到达率 × 占用时长，见 ../21-perf-testing/01 第 6 节）
```

### 时间线

| 时间 | 事件 | 当时的判断 |
| --- | --- | --- |
| 14:00 | 版本上线，灰度 10% 无异常（灰度流量小，池未耗尽） | "灰度通过" |
| 14:20 | 全量放开，订单列表接口 p99 从 120ms 爬到 8s | 误判一："又刷不出页面是前端问题" |
| 14:24 | 上游 nginx 出现 499（客户端等不及主动断开）；依赖订单服务的两个服务开始超时 | 误判二："网络抖动"，查了 10 分钟交换机 |
| 14:31 | 有人注意到只有订单相关接口慢——按"接口分型"缩小范围；`SHOW PROCESSLIST` 大量 `Sending data` 的同模式查询 | 定位方向转向 DB |
| 14:36 | `EXPLAIN` 新查询：`type=ALL` 全表扫 + `rows` 估算巨大；发现隐式类型转换让本可用的索引也失效 | 根因落点 |
| 14:40 | 功能开关回退该查询，KILL 积压的同模式会话 | 恢复动作开始 |
| 14:48 | 池释放，p99 回落，上游 499 清零 | — |

### 探测与误判

这次误判的教训是**范围分型晚于资源分型**：值班先按"资源"查（前端、网络），而最快的分流问题其实是"哪些接口慢、哪些不慢"——慢的接口全走同一条新查询，答案在分型里就写好了。DB 侧的快速证据：`Threads_running` 高但 CPU 不满（低效查询在等 IO 与锁，CPU 未必高——"CPU 不高所以 DB 没问题"是反例推理）；`SHOW PROCESSLIST` 同模式查询成片；`EXPLAIN` 的 `type=ALL` 是实锤（判读见 13-middleware/mysql/03-tuning-troubleshooting.md 第 1 节）：

```sql
-- [任意节点] 当时的 EXPLAIN（示意输出，表 480 万行）
EXPLAIN SELECT * FROM orders WHERE user_id = 20260901 ORDER BY created_at DESC LIMIT 20;
-- id: 1  type: ALL  possible_keys: idx_user  key: NULL
-- rows: 4820133  Extra: Using where; Using filesort
-- 两处红灯：idx_user 没被用（user_id 是 varchar，等值给了数字 → 隐式转换弃索引）；
--          Using filesort（created_at 无索引，结果集全量排序）
```

应用侧的第三条证据是连接池的等待计数（如 HikariCP 的 pending/get 等指标）早在 14:22 就翻红——如果这个指标进了告警，14:24 的"网络误判"根本不会发生。灰度为什么没拦住：灰度验证的是"功能对不对"，10% 流量下需要的并发连接 ≈ 25，池还有余量——**性能退化的灰度需要带着压测的容量视角看**（../21-perf-testing/02-capacity-planning.md 第 4 节的池容量核算）。

### 根因

根因：新增排序未走索引 + 隐式类型转换使索引失效，单查询 4.2s。促发因素：发布流程里 SQL 变更不过 EXPLAIN 评审；连接池 wait 指标未暴露，池耗尽只能靠用户报障发现。放大器：池是共享资源——没走慢查询的接口也在同一个池里排队，于是"一条查询慢"升级为"整个服务慢"，再向上游传导成 499 与级联超时。

### 短期修复

功能开关回退该查询；`KILL` 清理积压会话（先 `SHOW PROCESSLIST` 留证再动手，纪律见 13-middleware/mysql/03 第 4 节）；观察池释放与上游恢复。

### 长期修复

- SQL 变更评审加 EXPLAIN 门禁：`type=ALL` 且大表的排序/过滤不许上线；高危查询配 `max_execution_time` 兜底
- 连接池指标进监控：active/idle/wait 三个数 + wait 突增告警——池耗尽要在用户之前看见
- 隐式类型转换列入编码规范（varchar 列必须字符串比较），lint 层拦截
- 灰度阶段加一轮小流量压测：把"灰度通过"从功能判断升级为容量判断

### 教训

1. 池、线程、连接这类**排队型资源**的故障特征是"全慢"而不是"错"——出现"接口全慢但错误率不高"，先查共享资源的排队，再查网络。
2. 慢查询不等于高 CPU：等 IO、等锁的查询 CPU 很低，别用 CPU 当 DB 健康的唯一代言。
3. 灰度发布保护的是正确性，保护不了容量：10% 流量下池刚好够用，全量必然越界——Little 定律提前算得出来（案例里的 252 > 200）。
4. 与故事 2 对照着读：一个是"缓存层失效把洪峰推给 DB"，一个是"单点慢把池占满"——**下游视角的故障，上游的共享资源先疼**，两案的最早信号都在共享资源（连接数/池 wait）上，而不是在"坏掉的那个功能"上。

**关联阅读**：13-middleware/mysql/03-tuning-troubleshooting.md 第 1 节（慢查询与 EXPLAIN）与第 4 节（连接打满分型）；../21-perf-testing/02-capacity-planning.md 第 4 节（连接池容量核算）；场景索引见 [SCENARIOS.md](../SCENARIOS.md) §4 存储与中间件（"1040 Too many connections"、"EXPLAIN 看着没问题但就是慢"两条）与 §5 性能与资源。

## 把故事搬进靶场：四条 60 分钟演练路径

读故事会"我懂了"，动手才会"我会了"。四条路径都可以在练习集群/虚拟机上完成（**只在练习环境做**，故事 3 的配额打满尤其不能碰生产）：

| # | 演练 | 步骤骨架 | 验收 |
| --- | --- | --- | --- |
| 1 | PDB 保护实验 | 部署 3 副本无 PDB 服务 → drain 一台节点，亲眼看驱逐与重建；再补 PDB 复测 drain | 第二轮 drain 被挡住重试（`kubectl get pdb` 看 DISRUPTIONS 列） |
| 2 | 缓存穿透实验 | 复用 13-middleware/redis lab 环境：写入同 TTL 的批量 key → 到期瞬间压测回源（./观察 miss 与后端压力）→ TTL 加抖动复测对比 | 两轮的 DB 连接峰值差一个量级 |
| 3 | etcd 配额治理 | 练习集群上 `etcdctl put` 循环写入逼近 backend 配额（或灌大 CRD）→ `alarm list` → compact/defrag/disarm 全流程 | NOSPACE 出现、恢复、`endpoint status` 的 DB SIZE 回落 |
| 4 | 慢查询与池耗尽 | MySQL 造一张无索引排序的大表查询，并发打到应用 → 观察 `Threads_running`、池 wait、接口 p99 三条曲线 → 加索引复测 | 加索引后同样流量下池 wait 归零 |

每条演练结束，用 ../15-sre-methodology/04-postmortem-runbook.md 第 2 节的模板写一份 20 行迷你复盘——这套"读故事 → 亲手复现 → 写复盘"的循环，就是本模块存在的意义。

## 四个故事的公共模式

| 模式 | 故事 1 | 故事 2 | 故事 3 | 故事 4 |
| --- | --- | --- | --- | --- |
| 触发都是"计划内变更" | 维护 drain | 批量 TTL 到期 | Agent 上线 | 版本发布 |
| 兜底机制缺失 | 无 PDB | 无熔断/并发合并 | 无配额监控 | 无 SQL 门禁 |
| 最快证据被迟到发现 | Events 驱逐记录 | 命中率断崖 | `etcdctl alarm list` | 接口分型 + PROCESSLIST |
| 误判方向 | 翻发布记录 | 提议重启 DB | 重启组件/查网络 | 查前端与网络 |
| 容量视角缺位 | 调度余量 | 最坏情况容量 | 配额阈值 | 池的 Little 定律 |

把五横行连起来读：**变更触发 + 兜底缺失 + 容量视角缺位 = 故障**；而"最快证据"一行的共性是——它们都是现成的、低成本的查询，缺的只是"第一时间想到去看"。这四个故事的排查顺序，请对照 SCENARIOS.md 的"先查"字段反复演练（配合 `scripts/faults` 靶场做限时版本）。复盘文化本身（无责、行动项跟踪、知识沉淀）见 ../15-sre-methodology/04-postmortem-runbook.md——本篇每篇的结构就是那份模板的实战样张。

## 自测

<details><summary>1. 故事 1 里，为什么"存活副本数 ≥ 2"的告警在整个故障期间都没响？该换成什么告警？</summary>

因为驱逐 + 调度失败后剩余副本数恰好还是 2（≥ 阈值），静态副本数告警量的是"活着的"，不是"够不够用"——2 副本扛 3 副本的流量，容量已经越界但告警无感。应换成：驱逐/FailedScheduling 事件告警 + 容量水位告警（usage 对拐点的比例），以及 PDB 违例告警——它们分别覆盖"谁被赶走了"、"新家进没进得去"、"剩余容量还撑不撑得住"三个环节。
</details>

<details><summary>2. 故事 2 中"重启 MySQL"提案为什么被否？什么情况下重启才是对的？</summary>

连接打满 + 慢查询堆积时重启，是把"慢"升级成"完全不可用"：重启期间所有已建立连接断开、buffer pool 冷启动，恢复后穿透流量原样涌回，可能再打满。重启是"实例损坏"（进程崩溃、数据页损坏、无法恢复的死锁）场景的手段；本例实例健康、病在流量侧，正解是掐断穿透（熔断/预热/并发合并）而不是杀数据库。
</details>

<details><summary>3. 故事 3 里"已有 Pod 继续正常服务"这条信息为什么值十分钟？它如何改写排查路径？</summary>

它把问题从"整个集群"圈到"控制面"：数据面 Pod 的转发、Service 的 iptables 规则、已运行容器都不依赖 apiserver 实时可写，所以它们活着说明 kube-proxy/容器运行时/CNI 正常；而 kubectl 卡、CI 卡、扩缩容失灵全是"经 apiserver 的写路径"。由此五层定位法直接跳到控制面存储层，跳过网络与节点层的两次误判——先定性影响面，再选层下钻。
</details>

<details><summary>4. 用 Little 定律算一遍故事 4：如果那条查询是 400ms（而非 4.2s）、流量不变，池够不够？这说明池告警该怎么做？</summary>

需要并发 ≈ 60 × 0.4 = 24 < 上限 200，绰绰有余——同一流量下"查询慢不慢"直接决定池够不够，池的容量不是静态数字而是"到达率 × 单次占用时长"的函数。所以池告警不该只盯"用了多少连接"，更要盯 **wait 排队数与获取耗时**：占用时长恶化时，即使连接数没满，wait 已经先涨了；同时把"单查询 SLA（如 p99 < 200ms）"纳入发布门禁，从源头掐住占用时长。
</details>

<details><summary>5. 四个故事里各有一处"容量视角缺位"，请任选两个说明容量规划（../21-perf-testing/02）里对应的工具或原则。</summary>

故事 1：调度账（Σrequests/allocatable）没人看——对应第 3 节"四本账"，维护前必须核对目标节点组的调度余量，且 N-1 原则保证单节点下线仍在安全水位。故事 2：DB 容量按日常命中率估算——对应第 1 节"外推的适用边界"：容量假设里依赖的缓存命中率失效时，最坏情况容量要单独压测（开环阶梯打"缓存全失效"场景）。故事 4：池上限 200 是拍的——对应第 4 节连接池公式与压测扫池，及 Little 定律核"到达率 × 占用时长"是否越界。
</details>

## 延伸阅读

- Google SRE Book 第 15 章 Postmortem Culture（无责复盘的工业实践）：<https://sre.google/sre-book/postmortem-culture/>
- Google SRE Workbook 有效的故障排查（系统化定位方法）：<https://sre.google/workbook/effective-troubleshooting/>
- Kubernetes 驹逐 API 与 PodDisruptionBudget：<https://kubernetes.io/docs/concepts/workloads/pods/disruptions/>
- etcd 空间治理（compact/defrag/配额）：<https://etcd.io/docs/latest/op-guide/maintenance/>
- MySQL EXPLAIN 输出判读（官方 8.0）：<https://dev.mysql.com/doc/refman/8.0/en/explain-output.html>
