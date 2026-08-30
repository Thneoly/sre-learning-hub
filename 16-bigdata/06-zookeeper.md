# 06 · ZooKeeper：分布式协调服务的原理与运维（以及它的退场）

> 模块：16-bigdata ｜ 建议时长：3 小时 ｜ 关联认证：—（CKA/CKS/PCA 无直接考点；但 HDFS HA、YARN RM HA、HBase、旧版 Kafka 的故障排查都绕不开它；与 etcd/Raft 的概念对照是理解 K8s 控制面的一面镜子）

## 学习目标

- 能解释 ZooKeeper 的定位——分布式协调/共识服务而非存储服务，说出"小数据、全内存、强一致"的取舍
- 能描述 ZAB 的选举规则（epoch > zxid > myid）与过半提交流程，解释为什么同一时刻不可能有两个能提交的 Leader
- 能用 znode / 临时节点 / 顺序节点设计分布式锁与选主，并指出会话过期导致的"僵尸持有者"问题
- 能解释 watch 一次性触发语义与由此带来的重注册问题
- 能操作四字命令（srvr/mntr/stat）与 4lw 白名单，识别 jute.maxbuffer 大 znode 坑，说清扩容必须逐台重启的原因

版本约定：Apache ZooKeeper 3.8/3.9（docker 镜像 `zookeeper:3.9`）。四字命令白名单、admin server、动态重配置等行为在 3.4 → 3.5 → 3.9 间多次调整，涉及开关默认值处以官方文档为准。

## 1. 定位：协调服务，不是存储服务

ZooKeeper 解决的问题是：**一组对等的分布式进程，如何对"谁活着、谁是主、配置是什么"达成一致**。它故意把自己限制得又小又慢（相对存储系统而言）来换强一致：

| 设计选择 | 含义 | 运维推论 |
|---|---|---|
| 数据全内存 | 整棵 znode 树常驻堆内 | 数据量必须小（惯例：总数据 + watch + 连接数 MB 级）；`zk_approximate_data_size` 要监控 |
| 写走 ZAB 过半提交 | 每次写都要多数派确认落事务日志 | 写吞吐低（单机万级/秒）、延迟毫秒级；不适合当业务存储 |
| 顺序一致 | 所有客户端看到相同的写顺序 | 适合做"队列/锁/选主"的基石 |
| 本地读（非线性一致） | 读通常走本地内存，可能是旧数据 | 读多写少的元数据查询场景刚好；要读己之写需 `sync` |
| 数据树 + 会话 | 状态依附于连接会话 | 临时节点、watch 都与会话生命周期绑定 |

谁在用它（这决定了你要会它到什么程度）：

| 租户 | 用它做什么 | 版本背景 |
|---|---|---|
| HDFS NameNode HA | ZKFC 抢占 `/hadoop-ha/ns1/ActiveStandbyElectorLock`，保证只有一个 Active（本模块 01-hdfs 章） | Hadoop 3.3.x 标配 |
| YARN ResourceManager HA | embedded elector 选主 Active RM（本模块 02-yarn 章） | Hadoop 3.3.x 标配 |
| HBase | meta 表位置、Region 分配状态、.master 地址 | 强依赖，ZK 抖动 = HBase 抖动 |
| Kafka（旧版） | broker 注册、controller 选举、**0.9 之前消费者位移也存 ZK** | 已被 KRaft 取代，见第 5 节 |
| ClickHouse ReplicatedMergeTree | 副本合并协调（新版本可用 ClickHouse Keeper 替代，见第 5 节） | 上一章对比表里提过 |
| K8s | **不用 ZK**，用 etcd（Raft） | 概念同源，实现不同（第 3 节对照表） |

SRE 的核心心法：ZK 挂了不影响已有数据管道的"数据面"，但所有依赖它的"控制面"（HA 切换、选主、元数据寻址）会瘫痪——所以它是最典型的"小而致命"组件，监控告警优先级应与 etcd 同级。

## 2. 数据模型：znode、临时节点、顺序节点

命名空间是一棵树，每个节点（znode）可存 ≤1MB 的数据（见第 6 节 jute.maxbuffer 的坑）并有状态元数据（version、czxid、mtime、子节点数……）：

```
/
├── zookeeper/                  ← 保留节点（config 等）
├── hadoop-ha/                  ← HDFS HA 的锁与状态
│   └── ns1/
│       ├── ActiveStandbyElectorLock   ← 临时节点：谁创建谁 Active
│       └── ActiveBreadCrumb           ← 持久节点：记录当前 Active 标记（配合 fencing）
├── brokers/                    ← 旧版 Kafka 的 broker 注册表
│   ├── ids/0   (临时：host/port)
│   └── topics/orders/partitions/0/state
├── myapp/
│   ├── config  (v2)            ← 持久节点：配置下发
│   ├── lock/                   ← 分布式锁目录
│   │   ├── node-0000000001     ← 临时+顺序节点
│   │   └── node-0000000002
│   └── leaders/worker-1        ← 临时节点：实例存活注册
```

两类特殊节点是分布式锁与选主的基石：

- **临时节点（ephemeral）**：与创建它的**会话**绑定，会话结束（客户端quit/崩溃/超时）节点自动删除。天然表达"活着"：实例注册 `/leaders/worker-1`，进程挂了注册自动消失，无需人工清理。这也让"锁持有者崩溃后锁自动释放"成为可能——但带来新问题，见第 4 节会话漂移。
- **顺序节点（sequential）**：创建时自动追加单调递增的 10 位序号（`node-0000000003`），且序号由 ZK 保证分布式单调。排队、选主全靠它。

经典分布式锁（羊群效应规避版）：

```
① 想拿锁：create -e -s /myapp/lock/node-      → 得到 node-0000000007
② ls /myapp/lock：自己是序号最小的？→ 是，拿到锁
③ 不是：对"恰好比自己小一号"的节点设 watch（不是 watch 整个目录！）
④ 收到删除事件（前驱释放/崩溃）→ 重新判断自己是否最小
   只通知一个人 = 避免羊群效应（N 个等待者同时被唤醒冲击 ZK）
```

选主（主备切换）是同一模式的最小化：`create -e /myapp/leader`，创建成功者为主，失败者 watch 这个节点，节点消失（主挂）即重新竞争——HDFS 的 ZKFC 就是这个逻辑加了一层 fencing。

运维警示：ZK 锁解决的是"互相知情"，不解决"进程暂停后旧持有者继续写下游"（zombie writer）。治本靠 fencing token（把 znode 的 version/czxid 当令牌随每次下游写入一起携带，下游拒绝旧令牌）。Kleppmann 在《DDIA》里对此有经典论述——见到"用 ZK 锁就认为绝对安全"的设计要立刻警惕。

## 3. ZAB：选举、过半提交、只准一个 Leader

每个写请求分配全局单调的 **zxid = (epoch 高 32 位, counter 低 32 位)**：epoch 是"朝代"（每换一届 Leader 加一），counter 是朝内序号。zxid 的大小比较就是 (epoch, counter) 的字典序——这是理解选举与脑裂防护的钥匙。

**选举（FastLeader Election，启动或 Leader 失联时）**。每个节点广播自己的选票 (proposedLeader, proposedZxid, proposedEpoch)，收到别人选票后按下面优先级比较，劣者改投优者：

| 优先级 | 比什么 | 为什么 |
|---|---|---|
| 1 | epoch 大者胜 | 选票来自更新的"朝代"，直接作废旧朝事务 |
| 2 | zxid 大者胜（数据最全者） | 让最新数据的节点当 Leader，减少回滚 |
| 3 | myid 大者胜 | 前两者相同时的确定性 tie-breaker（配置文件 `server.N` 的 N，写在 dataDir/myid） |

某节点的票获得**过半**（3 节点中 2 票）即当选 Leader，其余变 follower 连上它同步数据（快照 + 增量 diff，落后太多会被 TRUNC 截掉未提交事务），随后进入正常服务。

**写路径（过半提交）**：所有写请求无论连到谁，都转发给 Leader。

```
client ──写 /app/config──► follower-2
                            │ 转发
                            ▼
                        ┌─ Leader ──────────────────┐
   ① 生成 PROPOSAL(zxid=0x5000000A) 写本地事务日志      │
   ② 广播给所有 follower                                │
   ③ follower 写事务日志并 ACK ────► 过半 ACK（含自身）    │
   ④ 广播 COMMIT，各节点应用到内存树                      │
                        └────────────────────────────┘
```

**脑裂防护（为什么不会双主）**：把 5 节点切成 {1,2} 和 {3,4,5} 两半。旧 Leader 在少数派那侧：它的 PROPOSAL 永远收不到过半 ACK，事务卡死不提交；它自己也因失去 quorum（`syncLimit` 内收不到确认）进入 LOOKING 重新选举。多数派那侧选出新 Leader、epoch+1。分区恢复后，旧侧节点以更高 epoch 为准向新 Leader 同步，本地未提交事务被 TRUNC 掉。**同一 epoch 内过半互斥 = 数学上保证至多一个能提交的 Leader**。这条约束与 Kafka ISR 的 `min.insync.replicas`（12-data-streaming/kafka/02-replication-and-reliability.md）、MongoDB 副本集多数派（11-middleware/mongodb）是同一个定理的三个化身。

与 Raft（etcd/K8s、ClickHouse Keeper、KRaft 用）对照着记，学会一个就懂另一个：

| 概念 | ZAB（ZooKeeper） | Raft（etcd/K8s） |
|---|---|---|
| 任期 | epoch（zxid 高位） | term |
| 日志 | 事务日志 + 快照 | log + snapshot |
| 提交序号 | zxid | log index |
| 提交条件 | 过半 ACK 后广播 COMMIT | 过半复制即提交（随心跳/AppendEntries 确认） |
| 读旧数据 | 本地读可能旧，需 `sync` | LinearizableRead 走 ReadIndex/LeaseRead |
| 成员变更 | 3.5+ 动态 reconfig（默认关） | etcd 原生成员 API |

## 4. watch 一次性触发与会话：最容易踩语义坑的地方

**watch 是一次性的**。在 `exists/getData/getChildren`（新客户端 `get -w /path`、`ls -w /path`）上注册后：

- 事件触发**一次**即失效，客户端必须重新注册才能继续监听；
- 事件保证先于新数据送达（不会"先看到 v3 再收到 v2 的事件"），但在"收到事件"与"重新注册"之间存在**丢失窗口**；
- 会话断连（Disconnected）期间事件不发；**会话过期后所有 watch 与临时节点全部作废**——这是大量"监听莫名失效"问题的根因。

正确姿势是收到事件后立刻"重注册 + 全量读一次"（以防丢失窗口内状态又变了），或者干脆用 Curator 的 Cache 系列（NodeCache/TreeCache/新 API CuratorCache），它把"重注册 + 本地缓存"封装掉了。Kafka 旧版 controller 的"watch 风暴"就是反面教材：一个 broker 下线触发大量 watch 回调，回调又去创建/删除节点触发更多 watch，放大了故障（这也是 KRaft 要消灭 ZK 依赖的动机之一，见第 5 节）。

**会话超时与会话漂移**。超时值是客户端请求值被服务端 `[minSessionTimeout, maxSessionTimeout]`（默认 2×~20× tickTime，即 4s~40s）夹逼后的协商值；客户端库周期性发 ping 维持，**判死权在服务端**：

```
客户端视角：我一直在发 ping / 我刚做完一次长 GC
服务端视角：sessionTimeout 内没收到该会话请求 → 判死 → 删除其全部临时节点 + watch
                      │
                      ▼
      GC/长网络分区恢复后的客户端自认为会话还在、锁还握着
      = 僵尸持有者（zombie holder），另一个实例可能已被选为新主
```

这就是"会话漂移"：客户端持有的会话视图与服务端真实状态发生分叉。防护三件套：给依赖方做**会话事件监听**（收到 Expired 立刻自降级/释放资源）；锁/选主配合 **fencing token**（第 2 节）；不要把会话超时设得比业务最长暂停（GC/重试）还短，也不要盲目调大到分钟级（主切换变慢，HBase/HDFS 切换延迟直接受它影响）。

## 5. KRaft 之后：协调服务正在退出历史舞台

Kafka 是 ZK 最大的"前租户"，它的离去是趋势的缩影。旧架构的痛点：元数据存 ZK，broker 启动全量拉取 + 注册 watch，分区多时启动慢、watch 风暴放大故障；controller 切换要靠 ZK 选举 + 重新加载，分钟级；两套系统（Kafka + ZK）的证书/备份/扩容都要维护。**KRaft（KIP-500）把元数据本身变成一条 Raft 复制的日志**（`__cluster_metadata`），controller 自己形成仲裁，Kafka 从"依赖外部协调服务"变成"共识内嵌"：

```
2.8 引入 KRaft（preview）→ 3.3 生产可用 → 3.5 弃用 ZK 模式 → 4.0 移除 ZK 模式
```

完整时间线与运维差异见 12-data-streaming/kafka/02-replication-and-reliability.md#7. Controller 与 KRaft：替代 ZooKeeper 的演进。

同一方向的动作还有：ClickHouse 用自研 **ClickHouse Keeper**（Raft 实现，协议兼容 ZK 客户端、去 JVM）替代 ZK；K8s 一开始就选 etcd；服务发现/配置场景被 Nacos/Consul 分流。趋势判断：**独立的协调服务正在退出新建系统的架构图，共识协议被内嵌进各产品自身**。但要区分"新建"与"存量"：Hadoop 生态（HDFS HA/YARN/HBase）在 3.3.x 时代仍深度绑定 ZK，存量集群的 ZK 运维技能在 未来 3~5 年仍是刚需；只是不该再为任何新项目引入 ZK——选型评审时这是可以直接写进结论的一条。

## 6. 运维手册

### 6.1 四字命令与 admin server

四字命令（4lw）是往 2181 端口裸发 4 个字母的 TCP 报文。**3.5 起默认只放行 `srvr`**，其余必须在 `zoo.cfg` 配置 `4lw.commands.whitelist=*` 或列表（docker 官方镜像用 `ZOO_4LW_COMMANDS_WHITELIST` 环境变量）。另外 3.5+ 内置 Jetty **admin server**（默认 8080），`/commands/<cmd>` 返回同样信息的 JSON——容器里没有 nc 时用 HTTP 更顺手。

| 命令 | 内容 | 用途 |
|---|---|---|
| `srvr` | 版本/Mode/latency/zxid、是否只读 | 最轻量的角色与状态检查（默认唯一放行） |
| `mntr` | 全量 `zk_*` 键值（监控数据源，见 6.4） | exporter 与巡检脚本 |
| `stat` | srvr + 每连接明细 | 排查"谁连着我、谁发慢请求" |
| `conf` | 生效配置 | 确认 tickTime/成员列表改动是否生效 |
| `ruok` | imok / 无响应 | 存活探测（HAProxy/keepalived 健康检查） |
| `isro` | rw / ro | 只读模式判定（需开启 readonlymode） |
| `cons`/`dump`/`wchs`/`wchc` | 连接/会话与临时节点/watch 统计 | 排查连接泄漏、watch 洪水（`wchc` 有安全风险，按需放行） |

### 6.2 jute.maxbuffer：大 znode 的坑

默认上限约 1MB（`jute.maxbuffer`，0xfffff 字节），同时约束单个 znode 数据、children 列表与整个请求。坑在于它是**客户端 + 全部服务端同时校验**的：

- 客户端写入 >1MB 报 `IOException: len is ...` 之类错误，业务常误判为"ZK 不稳定"；
- 想调大必须**所有服务端节点与所有客户端 JVM** 同时设 `-Djute.maxbuffer=4194304`——只改服务端不改客户端（或反之）照样失败；**集群内不一致**则可能在提案复制路径上出现诡异拒绝；
- 正确姿势：ZK 里永远只放指针（配置版本号、路径、地址），大内容放对象存储/数据库。

### 6.3 脑旋与脑裂防护

- **脑裂**（split-brain）：第 3 节的过半机制已在协议层防住——少数派永远无法提交、旧 epoch 自动作废。运维要做的是**不要人为制造双集群**：脑后双活、DNS 切流到两个"孤儿半区"、或把 5 节点当两个 2+3 用。
- **脑旋**（选举震荡，频繁切主）：Leader 反复失去 quorum 又回来。元凶按概率排序：JVM 长 GC（堆太大或分配不当）、事务日志盘 fsync 慢（`dataLogDir` 与快照/snapshot 盘混用且繁忙）、网络抖动、tickTime 配得太激进。表现为依赖方反复重新选主（HBase master 反复切换、旧版 Kafka controller 频繁变更），`stat`/`srvr` 的 Mode 频繁变化、latency 尖刺。防护：3 或 5 节点（奇数）、`dataLogDir` 独立低延迟盘、堆给 3~4GB 而不是越大越好（缩短 GC）、对 Mode 变化做告警（见 6.4）。

### 6.4 zk exporter 必看指标与告警

接入方式二选一：mntr 系 exporter（指标名 `zookeeper_*`，与 4lw 一一对应）或 JMX exporter（走 JVM MBean，指标名带包路径）。以下按 mntr 系命名给出，具体以所用 exporter 文档为准，PromQL 写法沿用 08-pca/03-promql-guide.md 的规则：

| 指标（mntr → exporter） | 含义 | 告警/关注 |
|---|---|---|
| zk_server_state → `zookeeper_server_state` | leader/follower/standalone | 全集群此值恒为 leader 的实例数 ≠ 1 = 无主或双主视图，最优先告警 |
| zk_outstanding_requests → `zookeeper_outstanding_requests` | 已收未处理完的请求数（Outstanding） | 常态 ≈ 0；持续 >100 且上涨 = 饱和/磁盘慢（头号信号） |
| zk_avg_latency → `zookeeper_avg_latency` | 平均请求延迟 ms（zavg delay） | >100ms 持续即异常，配合 max_latency 看尖刺 |
| zk_max_latency | 观察窗口最大延迟 | 尖刺排查 GC/磁盘 |
| zk_packets_received/sent | 请求/响应包速率 | 突增 = watch 风暴或客户端重连风暴前兆 |
| zk_znode_count / zk_ephemerals_count / zk_watch_count | 树规模/临时节点/注册数 | 容量趋势；ephemerals/watch 突增指向客户端泄漏 |
| zk_approximate_data_size | 全树数据量 | 逼近 MB 级要清理（见 6.2） |
| zk_synced_followers / zk_pending_syncs | （Leader）已同步/待同步 follower 数 | 5 节点时 synced_followers < 2、pending_syncs > 0 持续 = 跟随者掉队 |
| zk_open_file_descriptor_count | 打开的 fd | 逼近 `zk_max_file_descriptor_count`（连接泄漏） |

```promql
# [master] Prometheus 规则示例（经 PrometheusRule 或规则文件下发；送达与分组沿用 08-pca 第 5 章）
- alert: ZooKeeperNoLeader
  expr: count(zookeeper_server_state == 1) == 0        # server_state 枚举映射因 exporter 而异
  for: 1m
- alert: ZooKeeperSaturated
  expr: max by (instance) (zookeeper_outstanding_requests) > 100
  for: 5m
- alert: ZooKeeperSlow
  expr: max by (instance) (zookeeper_avg_latency) > 100
  for: 5m
```

### 6.5 扩容为什么必须逐台重启

ZK 的成员表（`server.N=host:quorumPort:electionPort`）写在每个节点的 `zoo.cfg` 里，是**静态配置**（3.5+ 有动态 reconfig，默认关闭且需 `reconfigEnabled=true`）。加一个节点的完整约束链：

1. **所有现有节点都要知道新成员** → 每台都得改 `zoo.cfg` → 每台都要重启才生效；
2. **过半数会变**：3 节点多数派是 2，4 节点是 3。滚动过程中若同时有两台处于"新配置重启中"，剩余节点可能凑不够任何一侧的多数派 → 集群整体不可写。所以必须**一次只动一台，等它重新加入并完成同步后再动下一台**；
3. **3 → 4 反而降低可用性**：容错仍是 1 台（过半 = 3），但需要的确认更多。扩容跳过 4 直接到 5（容错 2）——这也是"ZK 部署奇数台"的根本原因，与 Kafka ISR、etcd 的奇数建议同源；
4. **新节点的 dataDir 必须是空的**：残留旧集群数据（旧 epoch）会导致它拒绝加入或同步异常；新节点启动后从 Leader 拉快照 + diff 追平；
5. 动态 reconfig（`reconfig -add server.4=...`）省去手工改配置与重启，但同样要一次加一台、先确认仲裁权重，操作路径以官方文档为准。

缩容同理且更危险：移出的是 Leader 时先逐台摘除 follower、最后处理 Leader，且从多数派降为对半分（4→2）前必须想清楚容错归零的窗口。

## 实战演练

环境：装有 Docker 与 compose 插件的 Ubuntu VM。三个节点同一台 VM 上模拟（端口错开），命令标注 `[任意节点]`。

```bash
# [任意节点] 写 compose 文件 zoo.yaml（3 节点；ZOO_4LW_COMMANDS_WHITELIST 打开常用 4lw）
mkdir -p ~/zklab && cd ~/zklab
cat > zoo.yaml <<'EOF'
services:
  zk1:
    image: zookeeper:3.9
    hostname: zk1
    environment:
      ZOO_MY_ID: 1
      ZOO_SERVERS: "server.1=zk1:2888:3888;2181 server.2=zk2:2888:3888;2181 server.3=zk3:2888:3888;2181"
      ZOO_4LW_COMMANDS_WHITELIST: "srvr,mntr,stat,conf,ruok,isro"
    ports: ["21811:2181", "8081:8080"]
  zk2:
    image: zookeeper:3.9
    hostname: zk2
    environment:
      ZOO_MY_ID: 2
      ZOO_SERVERS: "server.1=zk1:2888:3888;2181 server.2=zk2:2888:3888;2181 server.3=zk3:2888:3888;2181"
      ZOO_4LW_COMMANDS_WHITELIST: "srvr,mntr,stat,conf,ruok,isro"
    ports: ["21812:2181", "8082:8080"]
  zk3:
    image: zookeeper:3.9
    hostname: zk3
    environment:
      ZOO_MY_ID: 3
      ZOO_SERVERS: "server.1=zk1:2888:3888;2181 server.2=zk2:2888:3888;2181 server.3=zk3:2888:3888;2181"
      ZOO_4LW_COMMANDS_WHITELIST: "srvr,mntr,stat,conf,ruok,isro"
    ports: ["21813:2181", "8083:8080"]
EOF
docker compose -f zoo.yaml up -d
# 预期：三容器 Up；启动日志里 zk 之间完成 FLE，选出 1 个 leader
```

```bash
# [任意节点] 定义 4lw 助手（容器里没有 nc，用 bash 的 /dev/tcp 直发 4 字母）
zk4lw() { timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1; printf '%s' '$2' >&3; cat <&3"; }

zk4lw 21811 srvr | grep -E 'Mode|Zxid'    # 三台中恰好一台 Mode: leader，其余 follower
zk4lw 21812 srvr | grep Mode
zk4lw 21813 srvr | grep Mode

zk4lw 21811 ruok                          # 预期：imok
zk4lw 21811 mntr | grep -E 'zk_server_state|zk_outstanding_requests|zk_avg_latency|zk_znode_count'
# Leader 上额外可见 zk_followers / zk_synced_followers

# admin server 的 HTTP 版本（JSON，无需 4lw 白名单）
curl -s http://127.0.0.1:8081/commands/srvr | head -20
# 验证白名单确实写进了 zoo.cfg：
docker compose -f zoo.yaml exec zk1 grep 4lw /conf/zoo.cfg
```

```bash
# [任意节点] 数据模型与锁语义：开两个终端，分别进 zk1、zk2 的客户端
# 终端 A：
docker compose -f zoo.yaml exec zk1 zkCli.sh
# 终端 B：
docker compose -f zoo.yaml exec zk2 zkCli.sh
```

在终端 A（观察者）与 B（操作者）按顺序执行：

```
# 终端 A（zk1）：
create /myapp ""
create /myapp/config v1
get -w /myapp/config            # 注册一次性 watch

# 终端 B（zk2）：
set /myapp/config v2            # A 立即打印 WATCHED EVENT ... NodeDataChanged
set /myapp/config v3            # A 毫无反应 —— watch 只触发一次，需重新 get -w

# 临时节点：与"进程"共存亡
# 终端 A：create -e /myapp/leader me
# 终端 B：ls /myapp            → [config, leader]
# 终端 A：quit                  # 会话结束
# 终端 B：稍等 1~2 秒再 ls /myapp → leader 消失（服务端判死并清理）

# 顺序节点：锁排队的雏形
# 终端 B 连续两次：create -s -e /myapp/lock- ""
#   → created /myapp/lock-0000000000 与 /myapp/lock-0000000001（序号单调，最小者持锁）
```

```bash
# [任意节点] 选举演练：暂停 Leader，看另外两台重新选主、旧 Leader 回来自动降级
# 先确认谁是 leader（假设 21812 显示 Mode: leader）
docker compose -f zoo.yaml pause zk2
zk4lw 21811 srvr | grep Mode      # 先 LOOKING 再稳定为 follower
zk4lw 21813 srvr | grep Mode      # 变成 leader（约 10~20 秒，initLimit/syncLimit 决定）
docker compose -f zoo.yaml unpause zk2
zk4lw 21812 srvr | grep Mode      # 预期：follower —— 旧 epoch 作废，绝不可能再抢回
```

```bash
# [任意节点] jute.maxbuffer 观察：写入一个 ~120KB 的 znode（默认 1MB 内）
docker compose -f zoo.yaml exec zk1 zkCli.sh \
  create /big "$(head -c 120000 /dev/zero | tr '\0' 'x')"
zk4lw 21811 mntr | grep -E 'zk_approximate_data_size|zk_znode_count'
# 预期：数据量上涨约 120KB。换算：超过 1MB 的单节点写入会直接被拒（6.2 节）
```

验证方法：`srvr` 三个端口恰有一个 leader；watch 只触发一次；临时节点随 quit 消失；暂停 Leader 后 20 秒内出现新 Leader 且旧 Leader 恢复后为 follower。清理：`docker compose -f zoo.yaml down`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `mntr/stat` 发过去没反应 | 3.5+ 默认 4lw 白名单只有 `srvr` | 配 `4lw.commands.whitelist`（或镜像环境变量 `ZOO_4LW_COMMANDS_WHITELIST`） |
| 客户端写 >1MB 数据报错 | `jute.maxbuffer` 默认 ~1MB | 客户端与服务端全体同步调大 `-Djute.maxbuffer`；更好的做法是把大内容挪出 ZK |
| 集群起不来，日志报无法过半 | myid 与 zoo.cfg 不一致 / 起的节点不够 / 端口不通 | 核对 `dataDir/myid` 与 `server.N` 一一对应；至少起过半数节点 |
| 业务"锁丢了"但进程还活着 | 会话被服务端判死（GC 停顿/网络分区），临时节点已删 | 会话超时按业务最长暂停调；加会话事件监听自降级；下游用 fencing token 拒绝旧持有者 |
| watch 时灵时不灵 | 一次性语义 + 过期作废，客户端没重注册 | 收到事件立即"重注册+全量读"；或用 Curator Cache 类封装 |
| HBase/HDFS 频繁重新选主 | ZK 脑旋：GC、事务日志盘慢、网络抖动 | 独立 dataLogDir、控堆防长 GC、对 Mode 变化告警（6.3/6.4） |
| 加了一台节点，集群反而写不进 | 多数派从 2 变 3，滚动重启窗口凑不齐过半 | 一次加一台、等同步完成再下一台；扩容走 3→5 不走 4 |
| 大 znode/海量 watch 拖慢一切 | 把 ZK 当存储用 | 指针化设计；监控 znode_count/watch_count/ephemerals_count 趋势 |

## 自测

1. 3 节点 ZK 挂 1 台，读写分别受什么影响？挂 2 台呢？如果这时还剩一个"曾经是 Leader 的节点"，它还能对外提供写服务吗？
<details><summary>答案</summary>

挂 1 台：过半（2/3）仍在，读写正常（可用性以少数派节点退出为代价）。挂 2 台：只剩 1 台不足过半—— Leader 因收不到过半 ACK 不再提交任何写，集群不可写；读默认仍可（本地内存数据）但不再有新数据，因此整体上应视为不可用。剩下的单节点即使是旧 Leader 也不能接受写：ZAB 的提交条件是过半 ACK，单节点无法满足，它会进入 LOOKING 等待仲裁恢复。这正是过半机制防脑裂的体现——宁可停写，不可双主。
</details>

2. 选举时"zxid 大者优先"解决什么问题？如果改成"myid 大者优先"，会在什么场景出什么事故？
<details><summary>答案</summary>

zxid 大 = 事务日志最全，让数据最新的节点当选，避免已提交事务丢失（其余节点向它同步）。若只按 myid：数据落后的高 id 节点当选 Leader，其他节点要向它同步时发现本地有 Leader 没有的已提交事务——这些事务必须被 TRUNC 回滚，等于已提交的写被"撤销"，违反持久化承诺； Worse 的情况下每次选主都可能在不同数据版本间回滚，产生抖动性丢写。epoch 优先级最高的原因同理：新朝代必须否定旧朝代的半成品事务。
</details>

3. 为什么 HDFS 的 ActiveStandbyElectorLock 用临时节点而不是持久节点 + 手动删除？如果两个 NameNode 都自认 Active，除了 ZK 还缺哪一层防护？
<details><summary>答案</summary>

临时节点把"持有权"与"进程会话"绑定：NameNode 崩溃/断连的瞬间锁自动释放，Standby 立刻可见并抢主，不需要人工或脚本清理（人工清理必有延迟和误删风险）。双 Active 的残余场景：旧 Active 长暂停后恢复，自认为仍持有锁（会话漂移，第 4 节）。ZK 只解决"互相知情"，防双写还差 **fencing**：HDFS 用 fencing 机制隔离旧 Active（如让 JournalNode/共享存储拒绝旧 epoch 的写），存储层强制单写才是最后防线。这与"ZK 锁要配 fencing token"是同一个结论。
</details>

4. watch 改成"永久触发"（注册一次一直有效）听起来更好，为什么 ZK 不这么做？这个决定把复杂度推给了谁？
<details><summary>答案</summary>

一次性 watch 让服务端实现简单且状态可预期：触发即清除，Leader 故障切换时无需在节点间迁移海量 watch 状态（永久 watch 意味着服务端要为每个客户端维护长期监听表并在会话漂移/FLE 后精确恢复，故障窗口的丢失或重复都很难定义）。代价是把复杂度推给客户端：必须"事件后重注册 + 全量读"处理丢失窗口，还要处理会话过期后全部作废。框架（Curator Cache 等）和后续系统（etcd 的 watcher 语义虽是持续推送，但同样要求消费方幂等）都在不同层面替业务承担了这部分。
</details>

5. 把 5 节点 ZK 扩到 7 节点，写出操作顺序，并解释为什么不能把 5 台的新配置一次性全部重启？
<details><summary>答案</summary>

顺序：① 在 5 台存量节点的 zoo.cfg 里同时加上 server.6、server.7，**一台一台改并重启**，每台回来并完成同步再动下一台；② 成员表统一后，用空 dataDir 启动第 6 台，等它从 Leader 同步完成；③ 再启动第 7 台。若把 5 台一次性全部按"7 成员"配置重启：重启窗口内在线节点可能只剩 2~3 台，而 7 成员的过半是 4——集群立刻失去仲裁、整体不可写；滚动期间各台成员表不一致，每台对"过半"的算法也不同，必须靠"一次一台"保证任意时刻在线节点数 ≥ 当前最大配置的过半数。用动态 reconfig 可免手工滚动，但"一次一台、确认同步"的原则不变。
</details>

## 延伸阅读

- ZooKeeper Administrator's Guide（四字命令、配置、动态 reconfig）：https://zookeeper.apache.org/doc/current/zookeeperAdmin.html
- ZooKeeper Programmer's Guide（数据模型、watch、会话语义）：https://zookeeper.apache.org/doc/current/zookeeperProgrammers.html
- Recipes（锁与选主的官方实现模式）：https://zookeeper.apache.org/doc/current/zookeeperRecipes.html
- ZooKeeper Metrics（JMX/Prometheus 指标）：https://zookeeper.apache.org/doc/current/zookeeperMetrics.html
- 动态重配置文档：https://zookeeper.apache.org/doc/current/zookeeperReconfig.html
- KIP-500（KRaft，消灭 Kafka 对 ZK 的依赖）：https://cwiki.apache.org/confluence/display/KAFKA/KIP-500%3A+Next+Generation+of+Kafka+Protocol
- ClickHouse Keeper（ZK 的 Raft 化替身）：https://clickhouse.com/docs/guides/sre/keeper/clickhouse-keeper
- etcd（K8s 控制面的共识层，Raft 对照）：https://etcd.io/
