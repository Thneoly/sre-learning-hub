# 02 · YARN：容器、队列与多租户调度

> 模块：16-bigdata ｜ 建议时长：4 小时 ｜ 关联认证：—（无直接考点；Container/资源配额/cgroup 与 K8s 的 Pod/requests/limits 一一对应，学完本章你会更懂 K8s 调度在解决什么）

## 学习目标

- 能画出 RM / NM / ApplicationMaster 三者的分工与一次作业提交的完整时序
- 能解释 Container 的资源模型与 cgroup 隔离，读懂"running beyond physical/virtual memory limits"并给出处置
- 能对比 Capacity 与 Fair 调度器的队列层级、ACL、抢占语义并给出选型建议
- 能用 node label 做多租户/异构资源隔离，并用 `rmadmin -refreshQueues` 热更新队列
- 能解释 RM HA 与重启恢复的机制，并按 1:4 的内存配比完成一套集群的容量规划
- 能说清 YARN 与 K8s 这两代资源调度的对应关系与历史走向

版本约定：以 Hadoop 3.3.x 行为为准，演练复用 `apache/hadoop:3.3.6` 容器；配置名与默认值以官方文档为准。

## 1. 三个角色：RM 全局调度、NM 本地执行、每应用一个 AM

YARN（Yet Another Resource Negotiator）把 MRv1 时代"既管资源又管作业"的 JobTracker 拆成两半：资源交给 ResourceManager（RM），应用管理下放给每个应用自己的 ApplicationMaster（AM）。这是理解一切 YARN 行为的钥匙。

```
client                RM（全局调度，一集群一对，HA）         NM（每台机器一个，本地执行）
  │ submitApplication    │                                   │
  │─────────────────────►│ 首次分配 container 0（AM 专用）    │
  │                      │──────────────────────────────────►│ 拉起 ApplicationMaster 进程
  │                      │                                   │ （MR 作业就是 MRAppMaster）
  │                      │◄────────register / 心跳(Allocate)──│
  │                      │ 后续分配 N 个 task container       │
  │                      │   （分配结果随 NM 心跳下发）         │
  │                      │                                   │
  │                      │     AM 直接请求各 NM 启动任务容器    │
  │                      │     AM────────────────────────────►│ task container
```

| 角色 | 部署 | 职责 | 类比 K8s |
|---|---|---|---|
| RM | 主节点（HA 双活 standby） | 全局资源视图 + 调度决策（把 container 分给谁）；应用生命周期登记 | apiserver + scheduler |
| NM | 每台 worker | 管本机资源账本、启动/监控/杀掉 container、聚合日志 | kubelet |
| AM | 以 container 形式运行 | 每应用一个：向 RM 要资源、向 NM 发启动、监控任务、失败重试 | 应用自己的 controller |

两个容易忽略但决定行为的设计：

1. **RM 只做分配，不做启动**。真正把进程拉起来的是 NM（本地执行），AM 与 NM 之间是直连 RPC。所以 NM 全挂但 RM 活着时，RM UI 还能看到应用（全部变 FAILED/卡住）——排障别只看 RM。
2. **AM 本身也是队列里的一个容器**，受"队列最多百分之多少资源能给 AM"（`yarn.scheduler.capacity.maximum-am-resource-percent`，默认 0.1）约束。这个限制防死锁：如果队列资源全被 AM 占了，谁也拿不到 task container，整个队列僵住。大队列跑大量小作业（Spark Thrift Server / Hive LLAP 类长驻应用）时要有意识调大它。

## 2. 资源模型：Container = memory + vcores

Container 是 YARN 的调度单位，两个维度：memory（MB）与 vcores。所有配置围绕"每台 NM 可分配多少"和"每个 container 允许多大"：

| 配置 | 作用 | 说明 |
|---|---|---|
| `yarn.nodemanager.resource.memory-mb` | 本机可分配总内存 | **不含** OS/DN/NM 自身，要手工扣掉（见第 8 节） |
| `yarn.nodemanager.resource.cpu-vcores` | 本机可分配总核数 | 同上，超售有前提 |
| `yarn.scheduler.capacity.minimum-allocation-mb/vcores` | 单容器下限 | 小于下限的申请按容器粒度向上取整 |
| `yarn.scheduler.capacity.maximum-allocation-mb/vcores` | 单容器上限 | Spark executor 申请超上限直接被拒（排障高频） |
| `yarn.nodemanager.vmem-pmem-ratio` | 虚拟内存/物理内存比 | 默认 2.1，见下文误杀 |

隔离靠 **cgroup**（正是 `03-docker/01-container-fundamentals.md` 讲的那套内核机制，YARN 的 linux-container-executor 就是 cgroup 的另一个使用者）：

- **内存是硬限制**：container 进程树物理内存超限，NM 先 SIGTERM 后 SIGKILL。日志特征 `Container ... is running 1.5GB of 1GB physical memory used; killing container`，container 退出码 143（SIGTERM）或 137（SIGKILL）。
- **vcores 默认只是记账单位**：不开 CPU cgroup 隔离时，vcores 是配额账本不是硬限——**别把 vcore 使用率当真实 CPU 水位**，看宿主机的 mpstat/top。
- **虚拟内存误杀**：JVM 应用（堆外内存、线程栈、NIO direct buffer）虚拟地址空间大，2.1 倍比例经常被触发，报 `running beyond virtual memory limits`。这是全世界 Hadoop 运维最经典的"假 OOM"，处置就是 `yarn.nodemanager.vmem-check-enabled=false`（社区通行做法，物理内存检查保留）。

排障速查（container 退出码）：

| 退出码 | 信号 | 最常见含义 |
|---|---|---|
| 0 | — | 正常结束 |
| 1 | — | 应用异常（看 stderr，找第一个 Caused by） |
| 137 | SIGKILL | 物理内存超限被 NM 强杀 / 宿主 OOM killer |
| 143 | SIGTERM | 被抢占、超限先杀、或管理员 kill |

## 3. 调度器：Capacity vs Fair

RM 的调度器决定"队列里的下一个应用什么时候拿到 container"。

| 维度 | Capacity Scheduler | Fair Scheduler |
|---|---|---|
| 资源模型 | 队列树，每队列 guaranteed capacity + maximum-capacity | 队列带权重，活跃队列间公平分享 |
| 队列层级 | root.prod.etl 这种树，子队列容量按父队列百分比 | 同样支持层级（父/子队列） |
| 空闲资源 | 队列闲时可被其他队列借用（maximum-capacity 封顶） | 天然行为：份额随活跃度浮动 |
| ACL | `acl_submit_applications` / `acl_administer_queue`，可精确到用户/组 | 同样支持 ACL |
| 抢占 | 默认关闭，要开 `yarn.resourcemanager.scheduler.monitor.enable` 一族配置 | 同样默认关闭：需 `yarn.scheduler.fair.preemption=true` 且配置 fairShare/minShare PreemptionTimeout（不配 timeout 就永不抢占） |
| 配置文件 | capacity-scheduler.xml（支持 rmadmin 热更新） | fair-scheduler.xml（支持热更新） |
| 适用 | 绝大多数公司：边界清晰的多租户、要保底容量 | 多团队共享、要求"同时跑就平分"的场景 |

选型建议：**新装机默认 Capacity**（发行版默认，热更新与 ACL 生态最成熟），除非你明确需要 Fair 的动态份额——注意两者的抢占都是默认关闭、需显式开启，别把它当开箱即用的差异。抢占语义要吃透再开：Capacity 的抢占是"超过 guaranteed 的借用部分可被回收"，误开抢占会把别人的长跑 Spark 作业杀掉一半——开之前先在测试队列演练，并确认业务对 143 退出码有重试。

一份最小可用的队列树（生产照这个骨架扩）：

```xml
<!-- [任意节点] capacity-scheduler.xml 的核心骨架（演练章节会实际加载它） -->
<configuration>
  <property><name>yarn.scheduler.capacity.root.queues</name><value>default,dw</value></property>
  <!-- dw 队列保底 50%，闲时最多可借到 100% -->
  <property><name>yarn.scheduler.capacity.root.dw.capacity</name><value>50</value></property>
  <property><name>yarn.scheduler.capacity.root.dw.maximum-capacity</name><value>100</value></property>
  <!-- 提交与管理的 ACL：dw 组可提交，ops 组可管理；* 表示所有人 -->
  <property><name>yarn.scheduler.capacity.root.dw.acl_submit_applications</name><value>etl,ops</value></property>
  <property><name>yarn.scheduler.capacity.root.dw.acl_administer_queue</name><value>ops</value></property>
  <!-- 单用户最多吃掉队列的 1.5 倍保底容量，防单人打满 -->
  <property><name>yarn.scheduler.capacity.root.dw.user-limit-factor</name><value>1.5</value></property>
</configuration>
```

## 4. 标签调度与多租户隔离实践

队列只能按比例分资源，解决不了"这几台机器只给某业务用"。Node Label（节点分区）补上这一层：

```bash
# [任意节点] 标签管理三连（rmadmin 操作的是 RM 内存/ZK 状态，即时生效）
yarn rmadmin -addToClusterNodeLabels "GPU(exclusive=true),HIGHMEM(exclusive=false)"
# exclusive=true：打了该标签的节点只服务能访问该标签的队列（硬隔离）
yarn cluster --list-node-labels        # 查看标签
# NM 侧配置节点自身标签（每台机器的 yarn-site.xml）
#   yarn.nodemanager.node-labels.provider=config
#   yarn.nodemanager.node-labels.provider.configured-node-labels=GPU
```

队列侧再声明可访问的标签与默认标签（capacity-scheduler.xml）：

```xml
<!-- [任意节点] root.ml 队列独占 GPU 标签节点 -->
<property><name>yarn.scheduler.capacity.root.ml.accessible-node-labels</name><value>GPU</value></property>
<property><name>yarn.scheduler.capacity.root.ml.default-node-label-expression</name><value>GPU</value></property>
<property><name>yarn.scheduler.capacity.root.ml.label.GPU.capacity</name><value>100</value></property>
```

三个实践要点：标签与队列是配合关系（标签划机器，队列划额度+ACL）；exclusive 标签的节点**必须**有队列认领，否则白白闲置；打标签后用 `yarn node -list -showDetails` 核对每台的标签。多租户隔离的完整拼图 = 队列容量 + ACL（谁能提交）+ user-limit-factor（单人上限）+ node label（机器级硬隔离）+ cgroup（进程级资源硬限）+ 日志目录权限。每一层防的是不同的人祸。

## 5. 日志聚合与排查入口

作业日志分散在上千台 NM 上，靠人登机器看是不可能的。**日志聚合**把完成的 container 日志上传到 HDFS：

| 配置 | 建议值 | 说明 |
|---|---|---|
| `yarn.log-aggregation-enable` | true | 生产必开 |
| `yarn.nodemanager.remote-app-log-dir` | /tmp/logs | HDFS 聚合根目录 |
| `yarn.log-aggregation.retain-seconds` | 7~30 天 | 到期自动清理，防 HDFS 膨胀 |
| `yarn.nodemanager.local-dirs` | 多块盘 | container 运行中的本地日志与中间文件 |

排障入口按顺序走：

```bash
# [任意节点] 1. 应用级：状态、队列、最终状态、错误简述
yarn application -list -appStates ALL
yarn application -status application_1769000000000_0001
# 2. 一把拉取整个应用所有 container 日志（先查 HDFS 聚合，再回退本地）
yarn logs -applicationId application_1769000000000_0001 | less
# 只看 AM 日志（调度/OOM/重试信息都在这里）
yarn logs -applicationId application_1769000000000_0001 -am 1
# 3. 节点级：某个 NM 上在跑什么
yarn node -list -showDetails
# 4. 聚合产物在 HDFS 的落点（审计/兜底）
hdfs dfs -ls /tmp/logs/root/logs
```

Web UI 入口：RM UI（8088）看应用与队列 → 点进 attempt 跳转 NM UI（8042）看 container → container 页面直接看 stdout/stderr。UI 能定位到"哪台机器哪个 container"，`yarn logs` 拿全文。两条经验：先看 AM 日志再看 task 日志（AM 知道"为什么重试"）；`-appStates ALL` 比默认的 RUNNING 有用得多，因为出问题时应用早就不在跑了。

## 6. 运维：队列配置热更新

Capacity Scheduler 的配置可以不重启 RM 生效（Fair 也支持），这是多租户日常操作：

```
改 capacity-scheduler.xml（所有 RM 节点同步！） ──► yarn rmadmin -refreshQueues ──► 生效
```

热更新的硬约束（不满足会刷新失败并报错，**不会**弄挂 RM，放心操作）：不允许删除还有运行中应用的队列；root 直接子队列的 capacity 总和必须恒等于 100（增减都允许，但几个队列要联动改）；改名队列等于删+建，必须先清空应用。改动要用 Git 管理（跨团队变更留痕），刷新后 `yarn queue -status root.dw` 核对生效值。演练章节第 6 步会完整走一遍。

## 7. RM HA 与重启恢复

RM 是单点（对），所以 HA 是生产必配。机制与 HDFS NN HA 同源（都靠 ZooKeeper 选举）但形态不同：

```
      ZooKeeper：选举锁 + ZKRMStateStore（保存运行中应用/队列/凭据等恢复状态）
   ┌─────────┴─────────┐
   │  RM1 (Active)     │   无 JournalNode！Standby 不需要同步日志：
   │  RM2 (Standby)    │   调度状态可由 NM 心跳汇报 + AM 重新注册 重建
   └───────────────────┘   选举器内嵌在 RM 进程里（Curator elector），
                           不像 HDFS 需要独立的 ZKFC 进程
```

与 HDFS NN HA 的对照（两章连起来记）：

| 维度 | HDFS NN HA | YARN RM HA |
|---|---|---|
| 共享存储 | JournalNode 多数派 edits 日志 | 无；ZK StateStore 只存恢复所需的元数据 |
| 选主 | ZKFC（独立进程）+ ZK | 内嵌 elector + ZK |
| Standby 的准备 | 持续 tail edits，内存态实时一致 | 不维护实时状态，切换后现场重建 |
| 切换后 | 立即可服务 | 依赖 work-preserving restart：NM 重报容器、AM 重注册，作业不重启 |
| 手动切换 | `hdfs haadmin -failover` | `yarn rmadmin -transitionToActive rm1`（自动切换开启时要带 `-forcemanual`） |

前提配置：`yarn.resourcemanager.recovery.enabled=true` + `store.class` 指向 ZK 实现 + `yarn.resourcemanager.ha.enabled=true` + `rm-ids`。运维纪律与 HDFS 一致：自动切换要演练（拔 ZK 会话、kill Active），切完必须人工复盘；**没有开启 recovery 的 RM HA 只能保"RM 这个进程"的高可用，保不住作业**——切换瞬间所有运行中应用全部丢失，这是配置审计的必查项。

## 8. 容量规划案例：vcore:memory = 1:4 是怎么来的

这个业界常见配比不是玄学，是**机型规格与负载形态共同决定的**。推导一遍：

```
机型：64 vcore / 256GB 内存（当前主流 2U 通用机型，内存核数比恰好 4:1）
扣保留：OS+监控 agent 4GB、HDFS DataNode 8GB（堆+直接内存）、NM 自身 4GB
        → 每台可分配：240GB / 60 vcore，还是 4:1
配置：yarn.nodemanager.resource.memory-mb = 245760   (240GB)
      yarn.nodemanager.resource.cpu-vcores = 60
容器：最小 2GB/1C，最大 40GB/8C
```

再看负载侧：Spark executor 典型 4C/16G（1:4）、Hive/Tez container 常见 2GB/1C（1:2）、JVM 堆外再吃一截——**申请的内存配比普遍高于整机的 1:4**。于是集群常态是：内存打满、vcores 还剩一大截。规划结论三条：

1. **队列配额按 memory-mb 为主轴**，vcores 作粗约束（它本来就不是硬限）。
2. 容量演算示例：12 台 × 240GB = 2880GB、720C。队列 root.dw 保底 40% = 1152GB，可同时容纳 72 个 16GB executor；maximum-capacity 80% 让它夜里能借到 2304GB。
3. **maximum-allocation 必须小于等于 NM 可分配值**（跨节点聚合分配的场景以官方文档为准），否则大 executor 申请永远处于 PENDING。

## 9. YARN 与 K8s：两代资源调度的历史走向

你已经深度用过 K8s，把 YARN 映射过去就通了：

| 维度 | YARN（2012~） | Kubernetes（2014~） |
|---|---|---|
| 调度单位 | Container（进程组） | Pod |
| 资源描述 | 提交时静态申请（必须预估） | requests/limits 分离，超售有章法 |
| 调度器 | RM 内单一调度器集中决策 | kube-scheduler + SchedulerFramework 可扩展 |
| 节点代理 | NodeManager | kubelet |
| 隔离 | cgroups（需配 linux-container-executor） | cgroup v2 + namespace + 容器运行时（`03-docker/01-container-fundamentals.md`） |
| 多租户 | 队列 + ACL | Namespace + RBAC + ResourceQuota |
| 日志 | NM 聚合上 HDFS，`yarn logs` | 节点 stdout/stderr + Loki/ELK 采集（`10-logging/04-k8s-logging.md`） |
| 弹性 | 申请即固定，无自动伸缩 | HPA/调度层 Bin-Packing，生态完整 |
| 负载形态 | 大数据批作业（分钟~小时级） | 长驻服务为主，批作业靠 Operator 补齐 |

历史走向的三句话：

1. YARN 诞生是为了救 MRv1 的 JobTracker 单点，本质是"把资源调度从应用框架里抽出来"；K8s 把这个思想推到全公司所有负载，用声明式 API + 控制循环取代"提交-等待"式 API。
2. 今天两者共存：**存量 Hadoop 集群 YARN 仍是主干**（JD 里"大规模 Hadoop"的真实含义），新湖仓/云原生栈的计算层直接落 K8s（Spark on K8s、Flink Operator，见 `12-data-streaming/flink/02-deployment-and-exactly-once.md` 与 01 章结尾）。
3. K8s 世界里"队列/公平/抢占"并没有消失：Apache YuniKorn、Volcano、Kueue 都是把 YARN 的多租户调度语义带回 K8s 的项目——学会 Capacity 队列与抢占，等于提前学会了 K8s 批调度平台的运营模型。

## 实战演练

环境：复用 `hadoop-lab` 容器。第 1 章若已 format 过 HDFS，本步直接续用（不要再次 format）；容器被删掉时请先回去做 00 章与 01 章的准备步骤。

```bash
# [任意节点] 0. 确认 HDFS 在跑（YARN 的日志聚合、作业 jar 分发都依赖它）
docker exec hadoop-lab bash -c \
  'jps | grep -E "NameNode|DataNode" || \
   (hdfs --daemon start namenode && hdfs --daemon start datanode && sleep 3 && jps)'
# 预期输出：NameNode 与 DataNode 各一行
```

```bash
# [任意节点] 1. 写 YARN 与 MapReduce 配置（聚合日志开、虚拟内存检查关，路径以实际 HADOOP_HOME 为准）
docker exec -i hadoop-lab bash -s <<'EOS'
cat > $HADOOP_HOME/etc/hadoop/yarn-site.xml <<'XML'
<configuration>
  <property><name>yarn.nodemanager.aux-services</name><value>mapreduce_shuffle</value></property>
  <property><name>yarn.nodemanager.vmem-check-enabled</name><value>false</value></property>
  <property><name>yarn.log-aggregation-enable</name><value>true</value></property>
  <property><name>yarn.nodemanager.remote-app-log-dir</name><value>/tmp/logs</value></property>
</configuration>
XML
cat > $HADOOP_HOME/etc/hadoop/mapred-site.xml <<'XML'
<configuration>
  <property><name>mapreduce.framework.name</name><value>yarn</value></property>
  <!-- 容器内进程要能找到 MR 类路径：三行 env 是 docker 单机跑 MR 的标准补丁 -->
  <property><name>yarn.app.mapreduce.am.env</name><value>HADOOP_MAPRED_HOME=/opt/hadoop</value></property>
  <property><name>mapreduce.map.env</name><value>HADOOP_MAPRED_HOME=/opt/hadoop</value></property>
  <property><name>mapreduce.reduce.env</name><value>HADOOP_MAPRED_HOME=/opt/hadoop</value></property>
</configuration>
XML
echo done
EOS
# 预期输出：done
```

```bash
# [任意节点] 2. 启动 RM 与 NM，验证 node 注册
docker exec hadoop-lab bash -c \
  'yarn --daemon start resourcemanager && yarn --daemon start nodemanager && \
   sleep 5 && yarn node -list'
# 预期输出：
#   Total Nodes:1
#            Node-Id      Node-State Node-Http-Address Number-of-Running-Containers
#    hadoop-lab:45454         RUNNING     hadoop-lab:8042                           0
# Total Nodes:0 就再等 5 秒重试；浏览器开 http://<VM IP>:8088 是 RM UI
```

```bash
# [任意节点] 3. 提交第一个 MR 作业（2 个 map 估 Pi）
docker exec hadoop-lab bash -c \
  'hadoop jar $HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples-*.jar pi 2 10 2>&1 | tail -4'
# 预期输出：Job ... completed successfully
#           Estimated value of Pi is 3.4x（随机数不同略有差异）
# RM UI 的 Applications 页能看到这次提交的 RUNNING→FINISHED 全程
```

```bash
# [任意节点] 4. 用命令行复盘这个应用：状态、队列、日志聚合
docker exec hadoop-lab bash -c \
  'yarn application -list -appStates FINISHED'
# 预期输出：一行 APPLICATION_ID 形如 application_1769..._0001，STATE=FINISHED，
#           Final-State=SUCCEEDED, Queue=default
docker exec hadoop-lab bash -c \
  'yarn logs -applicationId application_1769000000000_0001 2>/dev/null | head -15'
# 预期输出：AM 与 task container 的 stdout/stderr 聚合内容（把 ID 换成上一步的真实值）
docker exec hadoop-lab hdfs dfs -ls /tmp/logs/root/logs
# 预期输出：一个以 application_xxx 命名的目录——聚合日志的最终落点
```

```bash
# [任意节点] 5. 看默认队列长什么样
docker exec hadoop-lab yarn queue -status root.default
# 预期输出：Capacity : 100.0%，Current Capacity 随作业水位变化，Node Labels : {}
```

```bash
# [任意节点] 6. 队列热更新：加 root.dw 队列并刷新
docker exec -i hadoop-lab bash -s <<'EOS'
cat > $HADOOP_HOME/etc/hadoop/capacity-scheduler.xml <<'XML'
<configuration>
  <property><name>yarn.scheduler.capacity.root.queues</name><value>default,dw</value></property>
  <property><name>yarn.scheduler.capacity.root.default.capacity</name><value>50</value></property>
  <property><name>yarn.scheduler.capacity.root.default.maximum-capacity</name><value>100</value></property>
  <property><name>yarn.scheduler.capacity.root.dw.capacity</name><value>50</value></property>
  <property><name>yarn.scheduler.capacity.root.dw.maximum-capacity</name><value>100</value></property>
  <property><name>yarn.scheduler.capacity.root.dw.acl_submit_applications</name><value>etl,ops</value></property>
</configuration>
XML
yarn rmadmin -refreshQueues && yarn queue -status root.dw
EOS
# 预期输出：dw 队列 Capacity : 50.0%；RM 日志无异常，正在跑的应用不受影响
# 把 capacity 改成 40/50（和不等于 100）再刷新一次，观察报错——热更新的护栏是真实的
```

```bash
# [任意节点] 7.（可选）提交一个慢作业并 kill，体会应用状态流转
docker exec hadoop-lab bash -c \
  'nohup hadoop jar $HADOOP_HOME/share/hadoop/mapreduce/hadoop-mapreduce-examples-*.jar \
     pi 16 500000 > /tmp/pi2.log 2>&1 & sleep 8; yarn application -list'
# 记下 RUNNING 状态的应用 ID，然后：
docker exec hadoop-lab yarn application -kill application_1769000000000_0002
# 预期输出：Killing application ... / State 变为 KILLED（若作业已先跑完看到 FINISHED 也算验证）
```

验证方法汇总：`yarn node -list` 有 RUNNING 节点、Pi 作业 SUCCEEDED、`yarn logs` 能拉到聚合日志、`root.dw` 队列热加载成功。容器保留（06 章还会用同款方式跑 ZooKeeper）。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 作业一直 ACCEPTED，container 不动 | 队列满了/单容器申请超 maximum-allocation/AM 资源被 am-percent 卡住 | `yarn queue -status`、`yarn application -status` 看诊断信息 |
| container 报 running beyond virtual memory limits | vmem-pmem-ratio 2.1 对 JVM 应用过紧（第 2 节假 OOM） | `yarn.nodemanager.vmem-check-enabled=false` |
| container 报 running beyond physical memory limits | 真超内存：executor/AM 堆外没算够 | 提高该角色 memory 配置（堆外按堆的 20~40% 预留） |
| AM 报 Could not find or load main class MRAppMaster | 容器内 HADOOP_MAPRED_HOME 未设置 | 演练第 1 步的三个 env 补丁 |
| refreshQueues 报错 | 子队列 capacity 总和不等于 100 / 删除了还有应用的队列 | 改配置满足约束再刷新（RM 不会因此挂掉） |
| `yarn logs` 报 Unable to get logs | 应用还在跑（聚合未发生）且 NM 已重启，或聚合未开 | 跑完再拉；确认 aggregation-enable 与 retain-seconds |
| RM 切换后所有作业失败重提 | HA 开了但 recovery 没开 | `yarn.resourcemanager.recovery.enabled=true` + ZK store（第 7 节） |
| vcore 用满 100% 但 CPU 空闲 / 反之 | vcores 只是记账，未开 CPU cgroup 隔离 | 看宿主机指标；需要硬限再开 cgroup CPU 隔离 |
| 某队列用户独占资源 | 没有 user-limit-factor / maximum-am-resource-percent 过小 | 按第 3 节骨架补配置并热更新 |
| 打了 GPU 标签的机器全部闲置 | exclusive 标签没有队列声明 accessible-node-labels | 补队列标签配置后 refreshQueues，`yarn node -list -showDetails` 核对 |

## 自测

1. AM 为什么不做成 RM 内部的一个线程，而要每个应用独立进程？这个设计换来了什么、付出了什么？
<details><summary>答案</summary>

这是 MRv1→MRv2 的核心改造：JobTracker 既管资源又执行应用逻辑，任何作业的 bug 都可能拖垮整个集群调度。拆出 AM 后，应用逻辑失败只影响自己的 AM（RM 只需为它重新申请一个容器重跑），RM 保持极简稳定；还换来了框架中立——Spark/Flink/Tez 都实现了自己的 AM，不必改 RM。代价：每个应用多一个进程与一轮协商（小作业启动开销变大）、AM 本身要占资源（于是有 am-percent 防挤占）、运维多了一层"AM 挂了导致应用重试"的排障面。
</details>

2. 一个大队列里跑着几百个"永远只要 1 个 container"的小应用，`maximum-am-resource-percent` 保持默认 0.1，会发生什么？为什么这个默认值是对的行为？
<details><summary>答案</summary>

AM 也占队列资源，几百个小应用的 AM 加起来可能吃掉远超 10% 的配额，于是后续应用的 AM 拿不到容器，全部排在 ACCEPTED——队列明明还有资源却没有一个应用能干活。默认 0.1 正是防这种死锁的护栏：AM 是"管理开销"，必须给真正的 task 留出主体资源。正确处置是识别负载形态：这类场景要么调大 am-percent，要么把常驻型应用（Spark Thrift Server 等）挪到独立队列。
</details>

3. 为什么"内存打满、vcores 大量剩余"是 YARN 集群常态？容量规划时你按哪个维度做主轴？
<details><summary>答案</summary>

因为应用申请的内存配比普遍高于整机配比：Spark executor 常见 4C/16G（1:4），JVM 堆外、Python 进程（PySpark）还要额外内存，而纯计算对 vcores 的记账消耗增长慢；同时 vcores 默认只是配额不设硬限，超售也无感。所以按 memory-mb 做主轴：队列保底/上限、扩容决策、水位告警都先看内存；vcores 用来防"单个超大 container"和粗粒度配额。演练第 8 节的 240GB/60C 推导就是这个逻辑。
</details>

4. RM HA 切换时正在跑的 Spark 作业为什么不重启也能继续？它的前提条件有哪些？
<details><summary>答案</summary>

work-preserving restart：新 Active 从 ZK StateStore 恢复应用登记，NM 重新汇报各自持有的运行中容器，AM 检测到 RM 重连后重新注册，作业继续。前提：recovery.enabled=true、StateStore 用 ZK 实现（与选举共用 ZK 集群）、NM 的容器没被误杀、AM 的重连窗口足够（否则 AM 自杀重跑也是可接受的降级）。若 recovery 没开，切换等于全集群作业清零——这是配置审计里比 HA 本身更容易漏的一项。
</details>

5. 同样基于 cgroup，YARN 的容器隔离和 K8s 的 Pod 隔离差在哪里？为什么说 YARN 是"半个容器系统"？
<details><summary>答案</summary>

K8s（准确说容器运行时）用 cgroup + **namespace** 双重隔离：文件系统、PID、网络栈全部隔离，还叠加 Seccomp/SELinux 等安全边界。YARN 默认的 DefaultContainerExecutor 只起进程不隔离；即便配了 linux-container-executor + cgroup，也只有资源维度（内存硬限/可选 CPU），进程间共享同一文件系统、同一网络命名空间、同一用户上下文——所以 YARN 集群必须靠"所有节点有相同的 Linux 用户"来隔离文件权限。这就是大数据作业可以直接读本地 HDFS 目录、却很难安全承载多租户任意代码的原因，也是计算层最终迁向 K8s 的根本动力之一。
</details>

## 延伸阅读

- YARN 官方架构文档：https://hadoop.apache.org/docs/stable/hadoop-yarn/hadoop-yarn-site/YARN.html
- Capacity Scheduler（队列/ACL/抢占官方说明）：https://hadoop.apache.org/docs/stable/hadoop-yarn/hadoop-yarn-site/CapacityScheduler.html
- Fair Scheduler：https://hadoop.apache.org/docs/stable/hadoop-yarn/hadoop-yarn-site/FairScheduler.html
- Node Labels（标签调度）：https://hadoop.apache.org/docs/stable/hadoop-yarn/hadoop-yarn-site/NodeLabel.html
- ResourceManager HA 与 Recovery：https://hadoop.apache.org/docs/stable/hadoop-yarn/hadoop-yarn-site/ResourceManagerHA.html
- YARN Commands（rmadmin/application/logs/queue）：https://hadoop.apache.org/docs/stable/hadoop-yarn/hadoop-yarn-site/YarnCommands.html
- Apache YuniKorn（K8s 上的队列化调度器）：https://yunikorn.apache.org/
