---
title_juejin: 'YARN 作业排队三小时零告警：五个静默排队黑洞与排查路径'
title_zhihu: 'YARN 作业排队三小时不是资源不够，是队列配置在静默吞作业'
description: '作业 ACCEPTED 三小时、监控全绿——排队不算故障，所以没人告诉你。五个黑洞藏在 AM 配额、单容器上限、min/max、节点标签与热更新里，附排查命令。'
category_id: "6809637769959178254"
tags: "后端,运维"
column_id: "7686472562230312970"
---

# 作业排了三小时队，YARN 安静得像没事发生

周五晚上，报表组在群里@你：昨晚的 ETL 到现在没出数。你打开 RM UI 找到那个应用——状态 ACCEPTED，提交时间 21:14，此刻凌晨 0:40，container 数 0。

更憋气的是集群：内存剩三成，CPU 曲线平得像下班了。监控全绿，告警全静，没有任何东西告诉你为什么。（构造典型案例，但每个环节都来自真实默认行为。）

因为对 YARN 来说，ACCEPTED 不是异常，排队是调度器的正常工作流。**排队不算故障所以没有告警，原因全在账本里，得自己会查。**

这篇把"作业从提交到拿到第一个 container"的链路拆开：三层角色怎么分工、资源怎么记账、队列怎么配错才会静默吞作业。读完你能带走五个排队黑洞与验证命令，和一条从应用状态到全量日志的排查路径。

## 一、三层角色：排队发生在哪一层

YARN（Yet Another Resource Negotiator）是为了救 MRv1 的 JobTracker 而生：JobTracker 既管资源又管作业，任何一个作业的 bug 都可能拖垮整个集群调度。

拆法是一分为二——资源交给 ResourceManager，应用管理下放给每个应用自己的 ApplicationMaster。三层分工一张表看清：

| 角色 | 部署 | 职责 | 类比 K8s |
|---|---|---|---|
| RM | 主节点（HA） | 全局资源视图 + 调度决策；应用生命周期登记 | apiserver + scheduler |
| NM | 每台 worker | 本机资源账本、启动/杀掉 container、聚合日志 | kubelet |
| AM | 以 container 运行 | 每应用一个：向 RM 要资源、向 NM 发启动、失败重试 | 应用自己的 controller |

时序一句话版：client 向 RM 提交 → RM 分出第一个 container 0 专跑 AM → AM 注册并以心跳（Allocate）申请 task container → 分配结果随 NM 心跳下发 → AM 直连各 NM 拉起任务容器。

看清这是**双层调度**：AM 按自己的节奏细粒度申请，RM 只做全局仲裁。K8s 反过来是单层中央调度——应用只声明"我要 N 个副本"，落点全由 kube-scheduler 包办；YARN 里"要多少、什么时候要"是应用自己的事，AM 的申请策略本身就可能让作业一直留在队里【从业者判断】。

两个容易忽略、但直接决定排队行为的设计。

其一，**RM 只做分配，不做启动**。真正拉起进程的是 NM，AM 与 NM 直连 RPC。推论：NM 全挂但 RM 活着时，RM UI 依然看得到应用（全部 FAILED 或卡住）——排障别只盯 RM。

其二，**AM 自己也是队列里的容器**，受 `yarn.scheduler.capacity.maximum-am-resource-percent` 约束，默认 0.1——队列最多拿 10% 资源养 AM。这是防死锁的护栏：AM 是管理开销，必须给 task container 留主体资源。

**黑洞一：AM 配额被吃光，全队卡在 ACCEPTED。** 大队列跑几百个"永远只要 1 个 container"的长驻应用（Spark Thrift Server、Hive LLAP 这类），AM 加起来轻松吃满这 10% 配额，后续应用的 AM 拿不到容器——队列明明还有内存，却没有一个应用能干活。

处置：调大 am-percent，或把长驻应用挪去独立队列。

## 二、资源模型：vcores 是账本，不是 CPU 水位

Container 是调度单位，只有两个维度：memory（MB）与 vcores。每台 NM 声明本机可分配多少（`yarn.nodemanager.resource.memory-mb` 与 `cpu-vcores`），这个数**不含** OS、DataNode、NM 自身，要手工扣掉。

调度器再按单容器上下限（minimum/maximum-allocation）切分——这条上限正是黑洞二的案发现场。

隔离靠 cgroup，两个维度行为完全不对称：

- **内存是硬限制**：物理内存超限，NM 先 SIGTERM 后 SIGKILL，退出码 143 或 137。
- **vcores 默认只是记账单位**：不开 CPU cgroup 隔离，它是配额账本不是硬限。**别把 vcore 使用率当真实 CPU 水位**，看宿主机的 top/mpstat。

顺带一个高频误杀：JVM 应用报 `running beyond virtual memory limits`，是 vmem-pmem-ratio 默认 2.1 对堆外内存过紧的"假 OOM"。

通行处置 `yarn.nodemanager.vmem-check-enabled=false`、保留物理内存检查——等于放弃 vmem 这层保险，换 JVM 应用不被误杀，这是社区通行做法【从业者判断】。

这解释了监控上最常见的错位：面板 vcore 满 100%、宿主机 CPU 大量空闲，或反过来。看到这种图，**第一反应不该是扩容，而是"这两个数不在一个体系里"**。

vcores 失真还有系统性来源：配比。业界常见的 vcore:memory = 1:4 不是玄学：64C/256GB 机型扣掉 OS、DataNode、NM 保留后剩 60C/240GB，还是 4:1。

而负载侧更偏内存：Spark executor 典型 4C/16G、Hive/Tez 常见 2GB/1C，堆外再吃一截——申请的内存配比普遍高于整机。

于是**"内存打满、vcores 剩一大截"是集群常态**。你以为 CPU 有余量能塞作业，调度器说内存没了。规划记一条：**队列配额按 memory-mb 做主轴**，vcores 只当粗约束。

**黑洞二：单容器上限配错，大 executor 永不分配。** 两种形态：申请超过 `maximum-allocation-mb` 会被明确拒绝，算好排查的。

更阴的是 maximum-allocation 配得比 NM 可分配值还大——申请合法、日志无错、container 永远 PENDING。给 executor 配大内存前，先核这条上限。

## 三、调度器选型与抢占：两个都默认不抢

选型直接给结论：**新装机默认 Capacity**【从业者判断】。发行版默认、热更新与 ACL 生态最成熟；除非明确要 Fair"同时跑就平分"的动态份额，否则不用纠结。

| 维度 | Capacity | Fair |
|---|---|---|
| 资源模型 | 队列树，guaranteed + maximum 双值 | 队列带权重，活跃队列间公平分享 |
| 空闲资源 | 队列闲时可被借用，maximum 封顶 | 份额随活跃度浮动，天然行为 |
| 抢占 | 默认关，要开 monitor 一族配置 | 默认关，preemption=true 外还得配 timeout |

最贵的认知坑：**两个调度器的抢占都默认关闭。** 以为切到 Fair 就有抢占救场的会被现实教育——不配 fairShare/minShare PreemptionTimeout，永不抢占。

Capacity 同样要显式开 `yarn.resourcemanager.scheduler.monitor.enable` 一族配置，没有开箱即用的抢占。

开了也别掉以轻心：Capacity 的语义是"超过 guaranteed 的借用部分可被回收"，误开抢占，别人长跑的 Spark 作业会被杀掉一半，退出码 143。开之前两件事：测试队列演练；确认业务对 143 有重试。

队列树骨架（生产照此扩）：

```xml
<!-- [任意节点] capacity-scheduler.xml 骨架：dw 保底 50%、上限 100% -->
<property><name>yarn.scheduler.capacity.root.dw.capacity</name><value>50</value></property>
<property><name>yarn.scheduler.capacity.root.dw.maximum-capacity</name><value>100</value></property>
<!-- 单用户最多吃队列保底的 1.5 倍，防单人打满 -->
<property><name>yarn.scheduler.capacity.root.dw.user-limit-factor</name><value>1.5</value></property>
```

**黑洞三：上限配死、单人不设限，两头都是排队。** maximum-capacity 配成等于 capacity，闲时一分资源借不到——半夜集群空着，作业照样排队。

反过来上限放开却没配 user-limit-factor，一个跑批脚本的几百个小作业能把保底吃光，同队列其他人排到天亮。这两个参数是一对，只配一个是半成品。

## 四、标签调度：队列分比例，标签分机器

队列只能按比例分资源，解决不了"这几台机器只给某业务用"。Node Label 补的是机器这层：

```bash
# [任意节点] 标签三连（rmadmin 改 RM 内存/ZK 状态，即时生效）
yarn rmadmin -addToClusterNodeLabels "GPU(exclusive=true),HIGHMEM(exclusive=false)"
# exclusive=true：打了该标签的节点只服务能访问该标签的队列，硬隔离
yarn cluster --list-node-labels
# 预期输出：Node Labels 行中出现刚添加的 GPU 与 HIGHMEM
```

队列侧再声明谁能用哪个标签：

```xml
<!-- root.ml 队列独占 GPU 标签节点 -->
<property><name>yarn.scheduler.capacity.root.ml.accessible-node-labels</name><value>GPU</value></property>
<property><name>yarn.scheduler.capacity.root.ml.default-node-label-expression</name><value>GPU</value></property>
```

分工一句话：**标签划机器，队列划额度 + ACL。** 实践三条：exclusive 标签的节点必须有队列认领，否则闲置；NM 侧要在本机 yarn-site.xml 配标签；打完逐台核对。

**黑洞四：GPU 机器全闲置，作业在普通分区排队。** 机器打了 exclusive 标签，却没队列声明 accessible-node-labels——这些节点一个 container 都分不出去，普通分区照样排长队。资源躺在集群里，看总量永远看不出来：

```bash
# [任意节点] 逐台核对标签落位
yarn node -list -showDetails
# 预期输出：节点明细含 Node-Labels 字段，GPU 机器显示 GPU
```

多租户完整拼图，每层防不同的人祸：队列容量 + ACL（谁能提交）+ user-limit-factor（单人上限）+ node label（机器级硬隔离）+ cgroup（进程级硬限）+ 日志目录权限。

## 五、排查路径：从应用状态到全量日志

回到凌晨 0:40 的现场。YARN 不会主动解释，但账本都在，按固定路径问它：

```bash
# [任意节点] 1. 应用级：状态、队列、最终状态、诊断信息
yarn application -list -appStates ALL
yarn application -status application_1769000000000_0001
# 2. 一把拉全应用所有 container 日志（先查 HDFS 聚合，再回退本地）
yarn logs -applicationId application_1769000000000_0001 | less
# 只看 AM 日志：调度、OOM、重试原因都在这
yarn logs -applicationId application_1769000000000_0001 -am 1
# 3. 队列水位 + 聚合产物落点
yarn queue -status root.dw
hdfs dfs -ls /tmp/logs/root/logs
```

四条经验：

- `-appStates ALL` 比默认的 RUNNING 有用得多——出问题时应用早就不在跑了。
- **先看 AM 日志再看 task 日志**，AM 知道"为什么重试"。
- ACCEPTED 要配合 `yarn queue -status` 看水位：队列满、超上限、am-percent 卡住，三种原因在这里分流。
- 日志聚合 `yarn.log-aggregation-enable=true` 生产必开——上千台 NM 的日志靠登机器看是不可能的；retain-seconds 给 7~30 天防 HDFS 膨胀。

UI 路径：RM UI（8088）看应用与队列 → 点 attempt 跳 NM UI（8042）→ container 页直接看 stdout/stderr。UI 定位"哪台机器哪个 container"，`yarn logs` 拿全文。

## 六、改队列不用重启，但要确认真的生效

Capacity 队列配置支持热更新（Fair 也支持），多租户日常操作：

```bash
# [任意节点] 改 capacity-scheduler.xml（所有 RM 节点同步！）之后：
yarn rmadmin -refreshQueues && yarn queue -status root.dw
# 预期输出：dw 队列 Capacity : 50.0%，运行中应用不受影响
```

硬约束三条，不满足会刷新失败：不能删还有运行中应用的队列；root 直接子队列 capacity 总和恒等于 100；改名等于删加建，先清空应用。好消息：**刷新失败只报错，不会弄挂 RM**，放心操作。

**黑洞五：改了配置，没确认生效。** XML 改完、refreshQueues 的报错没人看，或忘了同步另一台 RM——队列还是旧配额，作业继续排队，你以为修好了。纪律两条：队列改动进 Git 留痕；刷新后 `yarn queue -status` 核对生效值。

## 写在最后

五个黑洞收成一张速查表：

| 症状 | 黑洞 | 验证动作 |
|---|---|---|
| 一直 ACCEPTED，队列有内存 | am-percent 被 AM 吃光 | application -status 看诊断 |
| 大 executor 永不分配 | maximum-allocation 失配 | 对比申请值与上限值 |
| 集群闲着仍排队 | maximum-capacity 等于 capacity | queue -status 看上限 |
| 同队列他人排到天亮 | user-limit-factor 缺失 | 核对配置里的 user-limit-factor（queue -status 不显示此项） |
| 标签机器全闲 | exclusive 标签无队列认领 | node -list -showDetails |
| "修了"仍排队 | refreshQueues 报错没人看/漏同步 RM | queue -status 核对生效值 |

YARN 不告警不是它冷漠，是它真心认为排队是调度的正常部分。想让"排了三小时"被人知道，得自己把告警建在队列水位和 ACCEPTED 时长上【从业者判断】。

最后说回 K8s：队列、公平、抢占的语义在容器世界没有消失，YuniKorn、Volcano、Kueue 都是把 YARN 多租户调度语义带回 K8s 的项目。学会 Capacity 队列与抢占，等于提前学会 K8s 批调度平台的运营模型。

现在就能做的事：回去查三个数字——am-percent 还挂着默认 0.1 吗？有没有队列 maximum-capacity 等于 capacity？vmem-check 还开着吗？评论区聊聊：你见过最久的排队排了多久，最后定位是五个黑洞里的哪一个？

这些内容整理自我在维护的学习仓库，GitHub 搜 sre-learning-hub，18-bigdata 模块的 YARN 章是本文底稿：队列骨架、标签、日志排查与热更新的完整演练命令都在里面。觉得有用点个 star。
