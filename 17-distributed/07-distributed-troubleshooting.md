# 07 · 分布式排障：读路径 / 写路径分解法与五类经典故障

> 模块：17-distributed ｜ 建议时长：3 小时 ｜ 关联认证：—（无直接考点；本章是 03~06 章的运维出口，也是把全站 SCENARIOS.md 里"分布式类"现象串起来的收口章）

## 学习目标

- 能把任何一次"写失败"拆到写路径的六跳上（协调者→quorum 确认链），每跳说出失败指纹与第一跳命令
- 能解释读路径为什么由一致性级别决定走哪条路，"读到旧数据"时先查级别再怀疑故障
- 能默写 quorum 计算速查表，并对"失 quorum 现场"给出正确的第一反应（救一台，不是重组）
- 能把现场故障对号入座到五类经典模式：脑裂 / 双主 / 日志空洞 / 时钟漂移条件竞争 / 再平衡风暴
- 能说出分布式机制故障在全站 191 条场景索引里的分布位置，并从"现象"快速跳回本章

## 1. 总方法：两条路径分解法

分布式故障的现象千奇百怪（超时、变慢、丢数据、双写），但底座只有两条路径。排障第一步永远是问自己：**这次是写路径还是读路径的问题？**——写路径看协调链，读路径看一致性级别。

### 1.1 写路径 = 协调者 → quorum 确认链

以 K8s 为例（etcd 版本的逐箭头图在 [04-k8s-fundamentals/13-cluster-admin-and-etcd.md](../04-k8s-fundamentals/13-cluster-admin-and-etcd.md) §2.1）：

```
kubectl create
   │ ① 认证/鉴权（证书、RBAC）
   ▼
kube-apiserver：② 准入（webhook/默认值）→ ③ 验证 → 序列化
   │
   ▼ ④ 写 etcd（唯一持久层）
etcd follower 收到 → 转发给 leader
   │ ⑤ leader 追加 WAL 并 fsync（磁盘！）
   │ ⑥ 并行 AppendEntries → follower 落盘
   ▼ ⑦ 过半确认（含 leader 自身）→ commit → apply → 返回 201
```

每一跳的失败指纹（背这张表，排障时从现象反查跳）：

| 跳 | 挂了什么样 | 第一跳命令 |
|---|---|---|
| ① 认证 | 401/403、证书过期 `x509` | `curl 127.0.0.1:6443/healthz`、`kubeadm certs check-expiration` |
| ② 准入 | fail-closed 的 webhook 不可达 → **全集群**建不了对象 | `kubectl get validatingwebhookconfigurations`（SCENARIOS §8） |
| ④ apiserver↔etcd | apiserver 反复重启/crash loop，kubectl 全 refused | `crictl logs` 看连不上的 etcd 地址（【靶场】break-etcd-endpoint） |
| ⑤ WAL fsync | 写延迟尖刺、无故障但频繁选举（脑旋） | 磁盘 util/await；etcd wal fsync 指标（实战演练 3） |
| ⑥⑦ quorum | 写全超时；**读多半还通**（watch cache） | `etcdctl endpoint status` 数存活成员 vs quorum（第 2 节） |
| etcd 空间 | 集群只读 + `alarm NOSPACE` | `etcdctl alarm list`（[13 章常见坑](../04-k8s-fundamentals/13-cluster-admin-and-etcd.md)） |

两个高频误判要内化：**kubectl get 正常不代表 etcd 健康**（读走 watch cache）；**apiserver 无状态**，它的 crash loop 十有八九是"背后那跳"（etcd/证书）的问题。

### 1.2 读路径 = 一致性级别决定走哪

写完要看读。同一份数据，级别不同走完全不同的路（级别阶梯的完整语义在 [02-consistency-models.md](./02-consistency-models.md)）：

```
线性读（linearizable，etcd 默认）：
 client → 成员 → ReadIndex 先与多数派确认"我还是 leader" → 本地读 → 返回
          （多一次往返，换来"绝不返回已被覆盖的旧值"）

串行读（serializable，--consistency=s）：
 client → 成员 → 直接读本地 KV → 返回
          （省一次往返，可能读到旧值——但不是错，是合同不同）

K8s 的现实：kubectl get 大部分根本不到 etcd——
 apiserver 的 watch cache 应答（[04-k8s/02 章 §2](../04-k8s-fundamentals/02-architecture-and-control-loop.md)）
 所以"etcd 慢"≠"kubectl get 慢"，两者要分开测
```

由此得出"读到旧数据"类工单的处置顺序（[02 章 §5](./02-consistency-models.md) 的运维含义展开过）：**先查一致性级别与读的是哪个副本，再怀疑故障**。Mongo readConcern、etcd consistency、读从库（MySQL/Redis replica），三件事的"旧"都是合同内的旧。第 03 章讲过 quorum 与 NWR 的 R+W>N 在这里兑现：把 R 或 W 调到不满足交集，读旧就从"可能"变成"必然"。

## 2. quorum 计算速查表

| N | quorum | 停 f 台时 | 状态 | 第一反应 |
|---|---|---|---|---|
| 1 | 1 | 0 | 可用 | 单点，勤 snapshot |
| 2 | 2 | 0 | 一台都不能停 | 错误配置，改成 1 或 3 |
| 3 | 2 | 1 | 读写正常（自愈/切主） | 无需动作，盯切主完成 |
| 3 | 2 | 2 | **不可写**，数据仍在 | 恢复任一台即救回 |
| 4 | 3 | 1 | 可用（容错与 3 相同） | 计划改成 5 |
| 5 | 3 | 2 | 可用（滚动维护的标准余量） | 无需动作 |
| 5 | 3 | 3 | 不可写，已提交数据大概率在 | 抢修一台 > 一切 |
| 7 | 4 | 3 | 可用 | 无需动作 |

三条口诀（每条都对应一个真实事故模式）：

1. **先救一台，别急着重组**：失 quorum 不等于丢数据，已提交条目在过半成员上（第 03 章 2.2 节持久性账）。把剩下成员组成"新集群"等于人为制造双写史。
2. **扩容跳过偶数**：3→5 直达，4 不增加容错只增加确认数（[04-k8s/02 章 §3](../04-k8s-fundamentals/02-architecture-and-control-loop.md)、[16-bigdata/06 章 §6.5](../16-bigdata/06-zookeeper.md)）。
3. **一次只动一台**：滚动维护窗口内"在重启的成员"按已停算，两台同停就可能击穿 quorum（第 06 章第 5 节）。

## 3. 五类经典故障模式对号入座

### 3.1 脑裂（分区两侧各自主）

分区把集群切成两半，各自觉得自己是合法主侧。共识系统里少数派侧**写卡死**（凑不齐 ACK），多数派侧选出新主、term/epoch 跳变——协议层防住了双提交（推导见 [16-bigdata/06 章 §3](../16-bigdata/06-zookeeper.md)）。Redis 是特例：数据面主从没有 quorum，防双主靠外挂哨兵 majority，分区期间旧主还可能吞写（[redis 02 章 §6.4](../11-middleware/redis/02-persistence-and-ha.md)）。

- **现象指纹**：一半成员互相失联但各自"活着"；写超时集中在部分客户端；`endpoint status`/`srvr` 的 leader 视图不一致；Mongo 报"not primary"、ZK 两半都 LOOKING。
- **先查**：从一台机器分别 ping/telnet 全部成员（分区证据）；各成员的 term/epoch 与 leader 认知；`rs.status()`（Mongo）/`endpoint status`（etcd）/`srvr`（ZK）。
- **运维红线**：不要人为制造双集群（DNS 切流到两个"孤儿半区"、脑后双活）；分区愈合后旧侧自动向新主同步，未提交事务被丢弃是**预期行为**不是数据事故。

### 3.2 双主 / 僵尸主（旧 Leader 复活）

不需要分区，一次长 GC / VM 挂起就够：旧主醒来不知道自己已被替换，继续写下游。共识协议会立刻把它降级（term 更高），但它**对下游的写不经过共识**——quorum 管不到（第 06 章 4.2 的时序图）。

- **现象指纹**：下游出现重复扣款/重复发货/数据被旧值覆盖；时间点与某节点 GC 停顿、重启、网络抖动高度对齐；两个实例都自认持有锁/leader。
- **先查**：下游写入记录里的令牌/版本/时间戳排序；锁与 lease 的 TTL vs 业务最长暂停（GC 日志、慢查询日志）；谁的写入赢了。
- **根治**：fencing token + 下游原子校验（第 06 章实战演练 3 的 Lua 模式）；HDFS 用 JournalNode 拒旧 epoch、Kafka 用 transactional.id 的 epoch，都是现成样板。

### 3.3 日志空洞（副本缺中段）

旧主崩溃时日志没复制完，或 follower 断线太久、重放追不上。各系统的名字不同，形状相同：

| 系统 | 空洞的叫法 | 表现 | 自愈机制 | 需要人工的边界 |
|---|---|---|---|---|
| etcd/ZK | 未提交/未同步日志 | follower 落后，applied index 差距 | Raft nextIndex 回退补发 / ZK 快照+diff | 落后超日志保留 → 走 InstallSnapshot/全量 |
| MySQL | binlog 位点断裂 | 主从延迟增长、1062/1032 报错 | IO/SQL 线程重放 | 单线程重放慢（平稳型延迟）要并行复制；位点断只能 GTID 跳过或重搭（[11-middleware/mysql/03 章](../11-middleware/mysql/03-tuning-troubleshooting.md)） |
| Redis | repl backlog 被冲掉 | 闪断一次就全量同步（sync_full 涨） | 部分重同步，backlog 不够则全量 | backlog 按"断线时长×写流量"调（[redis 02 章 §5.2](../11-middleware/redis/02-persistence-and-ha.md)） |
| Kafka | ISR 掉队 / under-replicated | 副本追不上 leader，ISR 收缩 | follower 拉取追赶 | 追不上持续存在 → 看 `replica.lag.time.max.ms` 与磁盘/网络（[12-kafka/03 章](../12-data-streaming/kafka/03-operations-and-performance.md)） |

- **现象指纹**：复制延迟指标单调增长；断连后"全量同步风暴"（带宽打满又拖慢别人）；SQL 线程报错停摆。
- **先查**：位点差（RAFT INDEX / Seconds_Behind_Source / LEO 差）；断线时长 vs backlog/保留窗口；是"追不上"（资源瓶颈）还是"接不上"（空洞超出保留）。
- **根治方向**：把"可追回窗口"（backlog、日志保留、compaction 周期）调到覆盖最长预期断线；重放瓶颈上并行度；空洞超窗的老老实实全量重建，别硬跳位点。

### 3.4 时钟漂移引发的条件竞争

租约/超时/证书/乐观锁全都踩着时间，时钟一漂，"谁先谁后"就不可信（时钟为什么不可靠、漂移与跳变的区别见 [01-failure-models-and-time.md](./01-failure-models-and-time.md) §2）：

- **现象指纹**：lease 提前过期（业务莫名被踢）或该过期不过期（双持有窗口）；证书报 not-yet-valid；两台机器日志时间戳倒挂，事件顺序拼不出来；用时间戳做版本号的乐观锁偶发失效。
- **先查**：`chronyc tracking`（偏差与同步状态）、node_exporter 的 timex 指标（**看斜率不是绝对差**，[01 章 §2.2](./01-failure-models-and-time.md)）；NTP 是否发生过步进（step）而非缓慢修正（slew）——步进才是跳变元凶。
- **根治**：关键判定不依赖墙钟——lease 用服务端统一计时或单调钟；版本号用单调递增整数（第 04 章自测 5 的翻车时序）；日志排序用逻辑序（trace/RV），时间戳只做展示。

### 3.5 再平衡风暴

再平衡本身是维护动作，做成故障靠"叠加"：迁移流量撞业务高峰、消费组 rebalance 叠加滚动发布、一批慢消费者触发连环 rebalance（代价与触发条件见 [12-kafka/01 章 §6](../12-data-streaming/kafka/01-log-model-and-architecture.md)）。

- **现象指纹**：周期性/发布后的整组停顿；`Rebalance`、`Attempt to heartbeat failed`、`IllegalGeneration` 日志刷屏；MIGRATE 期间源节点延迟尖刺；迁槽迁到一半整层拒写（有槽无归属）。
- **先查**：rebalance 的触发源（心跳超时 vs `max.poll.interval` 超时，两者处理方向相反）；迁移进度与限速；是否与其他变更窗口重叠。
- **根治**：cooperative-sticky 分配策略；超时按真实处理时长放宽；迁移走"低峰+限速+小批量+可暂停"四纪律（第 05 章第 4 节的 pre-flight 清单）。

### 汇总表（现象进门 → 类别 → 章）

| 现象关键词 | 类别 | 深读 |
|---|---|---|
| 两半集群、写卡死、切主后旧侧自动同步 | 脑裂 | 第 06 章 §4.1 |
| 重复扣款、GC 后旧主写下游 | 双主/僵尸主 | 第 06 章 §4.2~4.4 |
| 复制延迟、全量同步、ISR 收缩、位点断裂 | 日志空洞 | 第 07 章 §3.3 |
| lease 异常、时间戳倒挂、证书 not-yet-valid | 时钟条件竞争 | [01 章 §2](./01-failure-models-and-time.md) |
| rebalance 刷屏、迁移期超时、整组停顿 | 再平衡风暴 | 第 05 章 §4 |

## 4. 与 SCENARIOS.md 的衔接：191 条场景里的分布式故障

[SCENARIOS.md](../SCENARIOS.md) 是全站"现象进门"索引（191 条）。分布式机制类故障集中在三个类目：

| 类目 | 条数 | 直接命中分布式机制的 | 对应本章类别 |
|---|---|---|---|
| §1 集群与控制面 | 16 | 3 条：apiserver crash loop 连不上 etcd（【靶场】break-etcd-endpoint）；etcd `alarm NOSPACE` 只读；etcdctl snapshot 报错 | 写路径 ④⑦ 跳；etcd 运维 |
| §4 存储与中间件 | 58 | 原 8 条 + 16-bigdata 41 条：HDFS safemode 卡住 / 丢失块 runbook / 副本挤同机架；YARN 假 OOM 与 RM recovery；Spark OOM 在堆外 / 倾斜三板斧 / FetchFailed；Doris FE 选举阻塞、compaction 版本堆积、label 幂等；湖仓 commit 冲突、Hudi 积压、孤儿文件 | 日志空洞、quorum、脑旋、再平衡风暴、快照链路五类全部命中 |
| §9 分布式与共识 | 29 | 本模块与 ZK 章：ZK 4lw 白名单 / 脑旋 / 扩容写不进 / 会话漂移锁丢 / watch 一次性；etcd 失 quorum 拒写 / 频繁切主 / 奇数原则；时钟跳变假尖刺 / 日志倒挂；锁误删 / zombie writer / lease 时钟；脑裂取证 / 失 quorum 先救一台 | 五类经典故障 + 共识、一致性、时钟、fencing 全套 |
| §2/§3/§5/§6/§7/§8 | 88 | 间接相关若干（如 webhook fail-closed 属写路径②跳、证书过期是时间敏感故障） | 写路径①②跳 |

用法（值班时的三步）：从 SCENARIOS 的"现象"进门执行"先查"那条命令 → 命中后若根因在分布式机制，回到本章第 3 节对号入座 → 需要讲清"为什么"时再进对应理论章（03 共识 / 04 事务 / 05 分片 / 06 gossip 与 fencing）。反向也要做：每次处理完真实故障，回 SCENARIOS 确认覆盖面（该文件"日常使用姿势"一节的纪律）。

## 实战演练

在 kubeadm 练习集群上把写路径逐跳观测一遍。`ectl` 包装函数沿用 [04-k8s-fundamentals/13 章](../04-k8s-fundamentals/13-cluster-admin-and-etcd.md) §2.2 的定义。

```bash
# [master] 演练 1：写路径的两次计时——apiserver 全链 vs 纯 etcd
ectl() {
  kubectl -n kube-system exec etcd-"$(hostname)" -- sh -c \
    "ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
--endpoints=https://127.0.0.1:2379 $*"
}

time kubectl -n default create configmap probe-$RANDOM --from-literal=k=v
# 预期：几十~几百 ms。这一跳含 ①认证 ②准入 ③验证 ④写 etcd ⑦quorum 确认

time ectl put /probe/key v
# 预期：几~几十 ms（单成员 etcd）。差值 ≈ apiserver 处理链的开销；
#       多成员集群上这里还包含 ⑥⑦ 的并行确认往返
```

```bash
# [master] 演练 2：健康三查（任何"集群怪"工单的前两分钟）
ectl endpoint status -w table
# 看：成员数 vs quorum（第 2 节速查表）；DB SIZE 是否逼近配额；
#     多成员时 RAFT INDEX 是否一致（差距大 = 日志空洞的雏形）
ectl endpoint health
# 预期：... is healthy: successfully committed proposal
#       注意 health 每次都要走一次"提交提案"——本身就是写路径探针
ectl alarm list
# 预期：空。有 NOSPACE = 集群只读保护已触发（SCENARIOS §1 对应条目）

# [master] 顺带验证"读路径分家"：一致性级别的两种读
ectl get /probe/key --consistency=s   # 串行读：本地直接读
ectl get /probe/key                    # 线性读（默认）：多一次确认
# 单成员集群两者差异极小（ReadIndex 只需问自己）——多成员的差异实测
# 见 02 章 §实战演练（本模块），不重复做
```

```bash
# [master] 演练 3：把 quorum 指标摘出来（写路径⑤⑥⑦跳的健康度）
curl -s --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key \
  https://127.0.0.1:2379/metrics | grep -E '^etcd_server_proposals_(committed|applied|failed)_total'
# 预期：committed 与 applied 持续增长（写路径在走）；failed_total 为 0 或稳定不变
#       failed 持续上涨 = quorum 交互在失败（磁盘慢/网络/失多数派的前兆）
#       指标名以集群 etcd 版本实际输出为准；若该证书缺少 clientAuth
#       扩展被拒，改在 Pod 内 exec etcdctl 方式观测（13 章用法）

curl -s --cacert /etc/kubernetes/pki/etcd/ca.crt \
  --cert /etc/kubernetes/pki/etcd/server.crt \
  --key /etc/kubernetes/pki/etcd/server.key \
  https://127.0.0.1:2379/metrics | grep -c '^etcd_disk_wal_fsync_duration_seconds_bucket'
# 预期：一串 bucket 直方图。fsync 的 p99 持续抬高 = 第⑤跳（WAL 落盘）
#       正在变慢，下一步查磁盘（iostat await/util），与 13 章的
#       "etcd 独占一块低延迟磁盘"建议对照
```

```bash
# [master] 演练 4：五类故障的"纸面演习"——把本章表格变成口头答题
# 逐条回答（不给答案，答案都在第 3 节）：
#   a. kubectl get 正常、create 全超时 —— 哪一跳？第一命令？
#   b. MySQL Seconds_Behind_Source 阶梯式增长且 1062 报错 —— 哪一类？
#   c. 凌晨发布后消费组每 5 分钟 rebalance 一次 —— 哪一类？先查什么？
#   d. 两台机器日志时间戳倒挂、lease 双持有 —— 先跑哪条命令？
#   e. 5 成员挂 3 台，值班同事提议"把剩下 2 台重组新集群" —— 怎么拦？
# 每题 30 秒内说出"类别 + 第一跳命令"，就是本章的达标线
```

验证方法：演练 1 的两次 `time` 差值解释得出来；演练 2 三条命令各输出一行结论；演练 3 的 failed_total 与 fsync 直方图能指认到具体跳；演练 4 五题全对。配合第 03 章实战演练（pause 两台看 quorum 拒写、pause leader 看选举计时）与 02 章演练（一致性级别实测），本模块的动手闭环就齐了。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 失 quorum 后把剩余成员重组"新集群"继续服务 | 把不可用当成数据丢失 | 已提交数据在过半成员上；先抢修一台（第 2 节口诀 1），重组需按 snapshot 灾备路径 |
| "etcd 慢"直接下结论，没分开测读写 | kubectl get 走 watch cache，读快≠etcd 健康 | 写探针用 `endpoint health`/create；读慢另查（第 1.2 节） |
| 读到旧值就报"P0 数据故障" | 一致性级别/读的副本在合同内允许旧 | 先查 consistency/readConcern/是否读从库（[02 章 §5](./02-consistency-models.md)） |
| 主从延迟一律归咎"网络" | 多数是单线程重放慢（平稳型）或大事务（阶梯型） | 按斜率分型再处置（[11-middleware/mysql/03 章](../11-middleware/mysql/03-tuning-troubleshooting.md)） |
| 断连后 replica 全量同步反复发生 | backlog 覆盖不了断线窗口 | 按"断线时长×写流量"调 repl-backlog-size（[redis 02 章常见坑](../11-middleware/redis/02-persistence-and-ha.md)） |
| rebalance 风暴时调大心跳超时就收工 | 触发源可能相反（max.poll 超时 vs 心跳） | 先读日志关键词再选方向（[12-kafka/03 章三大排障表](../12-data-streaming/kafka/03-operations-and-performance.md)） |
| 双主事故后只修了锁超时 | 根因是下游没有 fencing，超时调多少都留窗口 | 下游令牌校验（第 06 章 §4.4），超时只是缓解 |
| 滚动维护一次停两台共识成员 | "过半"按成员总数算，不是按"平时"算 | 一次一台、确认同步再下一台（第 06 章 §5） |

## 自测

1. kubectl get pods 正常，kubectl apply 全部超时，apiserver 本身 Running。给出你的前三条命令与判断顺序。
<details><summary>答案</summary>

① `kubectl -n kube-system exec etcd-$(hostname) -- etcdctl ... endpoint status -w table`（或 13 章 ectl）——数存活成员 vs quorum、看 DB SIZE/alarm；② `etcdctl alarm list`——排除 NOSPACE 只读；③ `crictl logs` 看 apiserver 最近日志里的 etcd 错误（连接拒绝/超时/证书）。判断：读正常是 watch cache 应答（第 1.1 节"两个高频误判"），写失败说明问题在写路径④~⑦跳——etcd 失 quorum、空间满或证书问题是三个最常见根因。单成员集群还要看磁盘是否写满（WAL 落不了盘同样拒写）。
</details>

2. 为什么 `etcdctl endpoint health` 本身就是一次"写路径探针"？它和 `endpoint status` 的信息互补在哪？
<details><summary>答案</summary>

health 的实现是发起并提交一次提案（输出原文就是 "successfully committed proposal"），等于把写路径⑤⑥⑦跳完整走一遍——WAL fsync、（多成员时）AppendEntries、过半确认。status 是读元数据（term/index/DB SIZE/leader），不产生提案但给出"为什么失败"的细节。所以 health 回答"能不能写"，status 回答"卡在哪"：health 失败 + status 显示成员齐全 → 查磁盘/网络；status 显示成员不够 → quorum 问题；DB SIZE 逼近配额 → 空间问题。
</details>

3. MySQL 主从延迟、Redis 断线全量同步、Kafka under-replicated，这三个现象在"日志空洞"框架下有什么共同结构？各自的"可追回窗口"参数是什么？
<details><summary>答案</summary>

共同结构：从副本断线/落后 → 依赖一份有界的历史（binlog / repl backlog / leader 保留的数据）补差 → 历史窗口覆盖得住就增量追赶，覆盖不住就只能更贵的路径（全量同步/重搭/等追赶）。可追回窗口参数分别是：MySQL 的 binlog 保留（`binlog_expire_logs_seconds`）与重放并行度；Redis 的 `repl-backlog-size`（按断线时长×写流量估）；Kafka follower 的追赶能力（`replica.lag.time.max.ms` 与磁盘/网络带宽决定 ISR 是否收缩）。治理思路同构：把窗口调到覆盖最长预期断线，追不上的认全量重建。
</details>

4. 凌晨滚动发布后，Kafka 消费组每几分钟 rebalance 一次，白天恢复正常。归到哪一类？给出排查顺序。
<details><summary>答案</summary>

再平衡风暴（发布叠加触发）。顺序：① 日志先分型——`Attempt to heartbeat failed` 还是 `max.poll.interval` 相关（前者会话/网络问题，后者单批处理太慢被踢，处理方向相反）；② 对齐时间线——rebalance 时刻是否与 Pod 重启/发布批次吻合（group.instance.id 缺失时每次发布都触发全组重分配）；③ 查是否叠加了迁移/扩容（第 05 章 §4 的干扰账）；④ 根治：cooperative-sticky 策略 + 放宽超时 + 发布与迁移错峰（[12-kafka/03 章三大排障表](../12-data-streaming/kafka/03-operations-and-performance.md)）。
</details>

5. 一个 5 节点共识集群挂了 3 台。数据丢了多少？现在还能做什么、绝不能做什么？
<details><summary>答案</summary>

已提交数据**大概率一条没丢**：每个已提交条目在过半（≥3）成员上，挂 3 台后通常仍有存活副本（除非恰好挂掉的是持有某条目的全部 3 台——概率存在但低）。能做：抢修任一台（恢复 quorum=3 → 恢复读写）；期间读若走本地/缓存副本仍可服务但要标注一致性级别。绝不能：把剩 2 台改成 2 成员"新集群"继续写（双写史，愈合后必丢一边）；也不必急着从 snapshot 重建——先试救活成员，救不回来再走 [05-cka/04-etcd-backup-restore.md](../05-cka/04-etcd-backup-restore.md) 的灾备路径。这正是第 2 节口诀 1 的由来。
</details>

## 延伸阅读

- etcd 监控与告警（proposals/wal fsync 指标官方说明）：https://etcd.io/docs/latest/op-guide/monitoring/
- Kubernetes API 概念（resourceVersion、watch、410 语义）：https://kubernetes.io/docs/reference/kubernetes-api/api-concepts/
- Kafka 运维之 rebalance 与副本（官方 operations 指南）：https://kafka.apache.org/documentation/#basic_ops
- MySQL 复制故障处置（GTID 跳过与重搭路径）：https://dev.mysql.com/doc/refman/8.0/en/replication-administration-status.html
- Redis 复制与部分重同步（repl backlog）：https://redis.io/docs/latest/operate/oss_and_stack/management/replication/
- MongoDB 副本集排障（选举与多数派视图）：https://www.mongodb.com/docs/manual/tutorial/troubleshoot-replica-sets/
- chrony 常用命令（漂移与步进判定）：https://chrony-project.org/docs/chronyc.html
