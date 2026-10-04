---
title_juejin: 'Kafka 都把 ZooKeeper 删了，它为什么还死不掉'
title_zhihu: 'ZooKeeper 死不掉不是因为技术强，是因为存量重'
description: 'Kafka 4.0 删光 ZK 模式，HBase 与 HDFS HA 却还压在它身上：协调不是存储、watch 一次性触发、session 超时级联蒸发、羊群效应——讲透它为什么死不掉。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686341072617242662"
---

# Kafka 都把 ZooKeeper 删了，它为什么还死不掉

Kafka 4.0 已经把 ZooKeeper 模式的代码整个移除，时间线干净利落：2.8 引入 KRaft 预览、3.3 生产可用、3.5 弃用、4.0 移除【官方，Kafka 版本演进】。死亡证明开出来了，讣告也写好了：ZK 是上个时代的东西。

可你回头看自己的生产：HBase 还趴在它身上，HDFS 的 Active 切换还要靠它抢锁，还有一套谁都不敢动的老 Kafka 连着它。**讣告写好了，遗产还在发工资。**

这篇讲两件事：ZK 到底卖给你了什么（很多人用了三年也没答对），以及它为什么退不了场。

## 一、先纠偏：协调服务，不是存储服务

ZK 解决的问题是：一组对等的分布式进程，如何对"谁活着、谁是主、配置是什么"达成一致。这个问题里，没有"存数据"三个字。

它故意把自己限制得又小又慢（相对存储系统而言）来换强一致：

| 设计选择 | 含义 | 运维推论 |
| --- | --- | --- |
| 数据全内存 | znode 树常驻堆内 | 总数据 + watch + 连接数必须 MB 级 |
| 写走 ZAB 过半提交 | 每次写多数派确认落日志 | 单机写吞吐万级/秒、延迟毫秒级 |
| 本地读，非线性一致 | 读到的可能是旧数据 | 读己之写要显式 sync |
| 状态绑定会话 | 临时节点、watch 跟会话走 | 会话一死，这些全没了（第四节） |

**把它当数据库用的人，都付过同一笔学费。**单个 znode 上限约 1MB（jute.maxbuffer），写超了直接报 IOException，业务第一反应往往是"ZK 不稳定"——其实是拿它存配置正文、当队列使。调大要服务端与全部客户端 JVM 同时设 -Djute.maxbuffer，只改一边照样失败。

**ZK 里只放指针，不放内容**：版本号、路径、地址放这，正文放对象存储或数据库。

SRE 心法：ZK 挂了不影响数据面，但依赖它的控制面（HA 切换、选主、元数据寻址）会瘫痪。**小而致命，监控优先级与 etcd 同级。**

## 二、数据模型三板斧：每样各买到什么

命名空间是一棵树，节点叫 znode，可存不超过 1MB 的数据，带 version、czxid 等元数据。三板斧买的东西各不相同：

- **znode 本体**：买到"可比较的版本"。每次变更有全局序号，乐观并发控制、fencing token 全靠它。
- **临时节点**：买到"活着的证明"。节点与创建它的会话绑定，会话结束（quit、崩溃、超时）自动删除——实例注册即上线，进程死即摘除。
- **顺序节点**：买到"全序排队"。创建时自动追加 ZK 保证分布式单调的 10 位序号（node-0000000007），抢锁不用靠撞。

选主最小化：`create -e /myapp/leader`，成功者为主，失败者 watch 它，节点消失即重选——HDFS 的 ZKFC 就是这套加一层 fencing。

运维警示贴在工位上：**ZK 锁解决"互相知情"，不解决"暂停后旧持有者继续写下游"**（zombie writer）。治本靠 fencing token：把 znode 的 version/czxid 当令牌随每次下游写入携带，下游拒绝旧令牌。Kleppmann《DDIA》里有经典论述：见"用了 ZK 锁就当绝对安全"的设计，立刻警惕。

## 三、watch 只触发一次：最容易踩的语义坑

watch 是一次性的：`get -w`、`ls -w` 注册后，触发一次即失效，继续监听必须重新注册。两条衍生规则更毒：

- "收到事件"与"重新注册"之间存在**丢失窗口**，窗口内的变更不会补通知；
- 会话过期后，所有 watch 与临时节点**全部作废**——大量"监听莫名失效"问题的根因。

正确姿势：收到事件立刻"重注册 + 全量读一次"，或用 Curator 的 Cache 系列把重注册封装掉。起一台做实验：

```bash
docker run -d --name zk-lab \
  -e ZOO_4LW_COMMANDS_WHITELIST="srvr,mntr,ruok" \
  -p 2181:2181 -p 8081:8080 zookeeper:3.9
docker exec -it zk-lab zkCli.sh    # 终端 A
docker exec -it zk-lab zkCli.sh    # 终端 B
```

```text
# 终端 A：
create /myapp ""
create /myapp/config v1
get -w /myapp/config        # 注册一次性 watch

# 终端 B：
set /myapp/config v2        # A 立即打印 WATCHED EVENT ... NodeDataChanged
set /myapp/config v3        # A 毫无反应——watch 只触发一次，需重新 get -w
```

**这不是 bug，是明码标价的语义。**一次性让服务端状态简单可预期，代价是把重注册推给客户端。旧版 Kafka controller 的 watch 风暴是反面教材：broker 下线触发大量回调，回调又去增删节点触发更多 watch，把故障滚成雪崩——这是 KRaft 要消灭 ZK 依赖的动机之一，本专栏讲 Kafka 4.0 那篇已拆过，不重复。

## 四、session 超时：locks/members 集体蒸发的链路

会话超时是客户端请求值被服务端 [minSessionTimeout, maxSessionTimeout]（默认 4s~40s，由 tickTime 派生）夹逼后的协商值；客户端周期性发 ping 维持，**判死权在服务端**。

客户端假死时，级联链路逐帧看：

```text
客户端：一次长 GC 暂停 25s，自认为一直在发 ping
  服务端：sessionTimeout 内没收到该会话请求 → 判死
    → 删除该会话全部临时节点 + 全部 watch
      → /myapp/lock/node-0000000001 消失（锁被释放）
      → /members/worker-1 消失（成员被摘除）
      → /myapp/leader 消失（触发重选，新主可能已上任）
GC 醒来的旧客户端：以为会话还在、锁还握着
  = 僵尸持有者（zombie holder），另一实例可能已是新主
```

这就是"会话漂移"：客户端的会话视图与服务端真实状态分叉。防护三件套，一件不能省：

- 依赖方做**会话事件监听**，收到 Expired 立刻自降级、释放资源；
- 锁与选主配 **fencing token**（第二节），下游拒绝旧令牌；
- 超时按业务最长暂停（长 GC、重试窗口）标定。**设短了误杀，设长了主切换变慢**——HBase、HDFS 的切换延迟直接受它影响。

## 五、羊群效应：watch 整个目录是最贵的偷懒

拿锁时自己序号不是最小，最省事的写法是 watch 整个 /myapp/lock 目录：任何风吹草动全员惊醒。这就是羊群效应——锁一释放，N 个等待者同时被唤醒冲击 ZK，集群越大抖得越狠。

正确写法是分散注册：

```text
① create -e -s /myapp/lock/node-     → 得到 node-0000000007
② ls /myapp/lock：自己是最小序号？→ 是，拿到锁
③ 不是：只对"序号紧排在自己前面的那个现存节点"的节点设 watch（不是 watch 目录！）
④ 前驱删除事件到达 → 回到 ② 重新判断
每个释放时刻只通知一个人 = 羊群效应消失
```

**watch 前驱一个节点，不是技巧，是规模保险。**换个名字就是选主：备机只 watch leader 那个临时节点——HDFS 的 ActiveStandbyElectorLock 正是这套路数。

## 六、ZAB 三句话，推导去翻老文章

共识不展开——本专栏 ZK、etcd、Consul 对比那篇已把 ZAB 与 Raft 摊在同一页纸上，三句话记住：

1. 每个写分配全局单调的 zxid =（epoch 高 32 位 + counter 低 32 位），epoch 是"朝代"，每换一届 Leader 加一；
2. 选举按 epoch > zxid > myid 逐级比较，劣者改投优者，过半票当选；
3. 过半 ACK 才广播 COMMIT——**同一 epoch 过半互斥，至多一个能提交的 Leader**，脑裂防在协议层。

epoch 对 Raft 的 term，zxid 对 log index，一条定理两种拼写。**学会一个，就懂了另一个。**

## 七、退场叙事：风头被抢走，座位没让出

趋势是真的：**独立的协调服务正在退出新建系统的架构图**，共识协议被内嵌进产品自身【从业者判断】。四个动作摆在一起看：

- Kafka：KRaft 把元数据变成 Raft 复制的日志，最大租户搬走（细节看本专栏 Kafka 4.0 那篇）；
- ClickHouse：自研 Keeper 替代——Raft 实现、协议兼容 ZK 客户端、去 JVM，是个近亲；
- K8s：第一天就选 etcd，从没用过 ZK；
- 服务发现与配置：被 Nacos、Consul 分流，那些平台上长出来的集群如今也是另一批要养的协调设施【从业者判断】。

但"新建"与"存量"是两回事。让 ZK 死不掉的租户名单：

| 存量租户 | 绑定深度 |
| --- | --- |
| HBase | 强依赖：meta 表位置、Region 分配、.master 地址；ZK 抖 = HBase 抖 |
| HDFS HA / YARN RM HA | Hadoop 3.3.x 标配；HDFS 由 ZKFC 抢 /hadoop-ha/ns1/ActiveStandbyElectorLock，YARN 走 embedded elector 同套路 |
| 老 Kafka 集群 | 0.9 之前连消费位移都存 ZK；迁 KRaft 要先升级再按官方路径转换 |
| ClickHouse ReplicatedMergeTree | 副本合并协调；新版可换 Keeper，但那是近亲，运维手感没变 |

选型结论可以直接写进评审纪要：**不为任何新项目引入 ZK**；同时，**存量的 ZK 运维技能未来 3~5 年仍是刚需**。它不是没死透，是死得起的团队还没攒够迁移预算【从业者判断】。

## 八、运维手册精选：4lw 与 follower 判读

四字命令（4lw）是往 2181 端口裸发 4 个字母的 TCP 报文。**3.5 起默认只放行 srvr**，其余要配 `4lw.commands.whitelist`（docker 镜像用 ZOO_4LW_COMMANDS_WHITELIST 环境变量）。3.5+ 还有内置 admin server（8080 端口）返回 JSON 版，容器没有 nc 时更顺手。

接着用第三节的 zk-lab 判读（用 bash 的 /dev/tcp 直发）：

```bash
zk4lw() { timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1; printf '%s' '$2' >&3; cat <&3"; }
zk4lw 2181 srvr | grep Mode    # 单机模式：Mode: standalone
zk4lw 2181 ruok                # imok
zk4lw 2181 mntr | grep -E 'zk_server_state|zk_outstanding_requests|zk_avg_latency|zk_znode_count'
# 预期：standalone / 0 / 个位数毫秒 / 个位数的 znode 数
curl -s http://127.0.0.1:8081/commands/srvr | head -5    # admin server 的 JSON 版
docker rm -f zk-lab            # 清理
```

zk_followers / zk_synced_followers 只在多节点集群的 leader 上可见。判读口径四条，够值班用：

| 指标（mntr） | 健康态 | 异常判读 |
| --- | --- | --- |
| zk_server_state | 全集群恰 1 台 leader | Mode: leader 实例数 ≠ 1 = 无主或双主，最优先告警 |
| zk_followers / zk_synced_followers | 仅 leader 可见；3 节点应恒为 2 | 5 节点 synced < 2、pending_syncs > 0 持续 = 跟随者掉队 |
| zk_outstanding_requests | 常态 ≈ 0 | 持续 >100 且上涨 = 饱和或磁盘慢，头号信号 |
| zk_avg_latency | 毫秒级 | >100ms 持续即异常，配合 max_latency 尖刺查 GC/磁盘 |

**Mode 不对，看什么都是白看。**先数 leader，再看 outstanding，最后才轮到延迟——这条判读顺序写进值班 runbook，比任何单点阈值都值钱。

## 现在就能做的事

跑第三节那台容器，mntr 盯一分钟：outstanding 恒 0、延迟个位数毫秒——这就是健康 ZK 的样子。顺手自检三问：你们 ZK 上还挂着谁？session timeout 是拍的，还是按最长 GC 标定的？锁方案带 fencing token 吗？

三节点 compose、锁演练、完整的 mntr 指标表，收在我维护的 SRE 学习仓库：GitHub 搜 sre-learning-hub——ZK 章在大数据模块，KRaft 那篇在数据流模块，两篇对着读正好凑成一套。

最后聊个实的：你们存量里最难迁的那套 ZK，挂的租户是谁——HBase、HDFS，还是某个没人敢动的大爷？评论区报一下租户名单，我挑最典型的画一张依赖图。
