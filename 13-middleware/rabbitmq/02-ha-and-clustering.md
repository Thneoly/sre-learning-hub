# 02 · RabbitMQ 高可用与集群：仲裁队列、网络分区与跨机房复制

> 模块：13-middleware/rabbitmq ｜ 建议时长：4 小时 ｜ 关联认证：CKA-工作负载/CRD（Cluster Operator 是 StatefulSet + PVC + Operator 模式的完整范例）

## 学习目标

- 能画出三节点集群的架构，说清"元数据全节点同步、消息数据默认只在一个节点"这一最容易误解的事实
- 能复述 disk 节点与 RAM 节点的差别、Erlang 集群互信与端口要求，以及节点发现的几种方式
- 能讲清镜像队列为什么被废弃、仲裁队列用什么思路（Raft 多数派）接替它，并按容错需求算出副本数
- 能用 `rabbitmq-queues quorum_status` 观测仲裁队列的 Raft 状态，说出三种网络分区策略各自的行为
- 能对比 Shovel 与 Federation 的定位，并说明它们为什么不能替代同机房 quorum 集群

版本约定：以 **RabbitMQ 3.13**（docker 镜像 `rabbitmq:3-management`）为准；**镜像队列在 4.0 已整体移除**，仲裁队列的默认值在 3.x/4.x 也有差异，涉及处单独标注，拿不准的以官方文档为准。

## 1. 集群架构：什么被复制，什么没有

RabbitMQ 集群跑在 Erlang 分布式运行时上：节点间用共享 cookie 互信，经 epmd（TCP 4369）发现彼此，数据面走 TCP 25672：

```
        元数据（vhost/用户/exchange/binding/队列定义）── 全节点同步
   ┌───────────────────────────────────────────────────────────────┐
   │   rabbit@rmq1 (disc)      rabbit@rmq2 (disc)      rabbit@rmq3 (disc) │
   │      ├──── Erlang 分布式：epmd 4369 + 节点间 25672 ────┤      │
   └───────────────────────────────────────────────────────────────┘
        │                         │                         │
   classic 队列 q.a           quorum 队列 orders.qq 的三个 Raft 成员
   （数据只住在 rmq1）        leader@rmq2   follower@rmq1   follower@rmq3
```

关键事实，先说三遍都不多：**集群只复制元数据，不复制（classic）队列里的消息**。一条 classic 队列的数据始终只住在其宿主节点上；客户端可以连接集群任意节点，非宿主节点会把操作内部转发到宿主节点。所以三节点集群里 rmq1 宕机：

- 用户、vhost、交换机、绑定、队列定义：不丢（每个节点都有全量元数据）。
- 宿主在 rmq1 的 classic 队列：整个不可用，直到 rmq1 恢复（数据还在它的盘上）。
- 这就是消息层高可用必须引入仲裁队列（§3）的原因。

### 1.1 disk 节点与 RAM 节点

| 节点类型 | 元数据存放 | 现状 |
|---|---|---|
| disc（disk） | 内存 + 磁盘都存 | 生产唯一推荐：所有节点都用 disc |
| ram | 只在内存（少量子集除外），重启后从 disk 节点拉全量 | 3.8 元数据子系统重构后基本失去意义，官方明确不建议 |

RAM 节点是历史产物（Mnesia 元数据写盘慢的年代省几个毫秒的元数据变更延迟）。排障时遇到 `rabbit@xxx` 标成 ram 的老集群，规划就是错的，升级时顺手改掉。

### 1.2 组集群的三个前提

1. **Erlang cookie 一致**：`/var/lib/rabbitmq/.erlang.cookie`（docker 里用 `RABBITMQ_ERLANG_COOKIE` 注入）。cookie 是节点互信的共享密钥，不一致直接握手失败。
2. **节点名可解析**：节点名 `rabbit@<短主机名>`，节点间必须能互相解析这个主机名（docker 用容器名，K8s 用 headless service，见 §6）。
3. **端口放行**：4369（epmd）、25672（节点间 + CLI 工具）、5672（AMQP）、15672（management）。跨主机组集群时安全组漏 25672 是最常见故障。

节点发现：老式做法是配置文件里写死 `cluster.nodes`；现代做法是 peer discovery 子系统，后端有 classic config、DNS、Consul、etcd、Kubernetes（Operator 就用它）——新节点起来后自己去发现已有成员并加入。

## 2. 从镜像队列到仲裁队列

消息层高可用的演进，一行时间线：

```
classic 队列(单节点数据) ──► 经典镜像队列 CMQ(3.x) ──► 仲裁队列 QQ(3.8+) ──► 4.0
   宿主挂=队列不可用          policy 驱动主从镜像          Raft 多数派复制        CMQ 移除
                              3.9 起官方弃用               3.13 起默认推荐
```

**经典镜像队列（classic mirrored queue）**：用 policy（`ha-mode: all/exactly/nodes`）声明队列在多个节点各留一份，master 接收读写、mirror 同步副本。它被废弃不是因为想法错，而是工程上修不动：

- 同步是"尽力而为"：新加 mirror 要全量同步，同步期间集群压力巨大；没同步上的 mirror 被提升为新 master 就丢数据。
- 分区场景下"谁是 master"与"哪些副本真正同步过"难以推理，官方文档用整章描述其失败模式，仍无法保证一致。
- 与确认机制耦合出诡异的边界 case（confirm 已回但 mirror 未落盘）。

**仲裁队列（quorum queue，3.8+）**换了个思路：不再发明自己的复制协议，直接把队列实现成一条 **Raft 复制日志**——每个队列是一组 Raft 成员（默认 3 个，跨节点分布），写入多数派落盘才算成功。共识理论在 [19-distributed/03-consensus-and-replication.md](../19-distributed/03-consensus-and-replication.md) §4 有完整推导（选举、日志匹配、提交规则），RabbitMQ 只是 Raft 的又一个工业实现，运维语义全部可以平移：多数派写 = 失少数派不丢已确认数据；leader 挂 = 剩余成员秒级选出新 leader；失多数派 = 宁可拒绝写。

## 3. 仲裁队列详解

### 3.1 quorum 定位与副本数

`quorum = N/2 + 1`（多数派）。副本数（Raft 成员数）决定容错能力，直接套 [19-distributed/03](../19-distributed/03-consensus-and-replication.md) §2 的公式：

| 初始成员数 | quorum | 容忍故障节点 | 可用性 |
|---|---|---|---|
| 3 | 2 | 1 | 常用最小生产配置 |
| 5 | 3 | 2 | 更高容错，写放大与延迟也随之增加 |
| 2 | 2 | 0 | **反模式**：挂任何一个都不可用，永远别配偶数 |

声明方式是队列参数 `x-queue-type: quorum`，初始成员数用 `x-quorum-initial-group-size`（**3.x 与 4.x 默认都是 3**；五节点集群里也只在其中三个节点上各放一个成员，另两个节点不托管任何成员——要 5 副本必须显式声明该参数，4.0 改的默认队列类型与 delivery-limit，没有改这个默认值，以官方 Quorum Queues 文档为准）。成员数不是越多越好：每次写都要多数派落盘，副本越多 fsync 延迟越高。

### 3.2 观测：quorum_status 与队列类型

```bash
# [任意节点] 队列类型用 type info item（值为 classic/quorum/stream）
rabbitmqctl list_queues name type messages_ready messages_unacknowledged

# [任意节点] 看仲裁队列的 Raft 状态：成员、leader/follower、term、日志索引
rabbitmq-queues quorum_status orders.qq --vhost /
# 预期: 表格列出三个成员各自的 Raft State（leader / follower）、Term、Last Index 等
#       （输出列随版本略有差异，以实际版本为准）

# [任意节点] 副本再平衡（新增节点后把成员迁过去）与伸缩
rabbitmq-queues rebalance quorum
# grow 语法：grow <node> <selector> --vhost-pattern <正则> --queue-pattern <正则>（模式匹配一批队列）
rabbitmq-queues grow rabbit@rmq4 all --vhost-pattern / --queue-pattern 'orders\.qq'
# shrink 只接节点名：把该节点从它持有的全部仲裁队列成员中移除
rabbitmq-queues shrink rabbit@rmq1
```

勘误提示：部分二手资料提到 `rabbitmqctl list_queues` 有个 `quorum-crc` info item——官方 rabbitmqctl(8) 与 rabbitmq-queues(8) man page 里均无此项。查队列类型用 `type`，查 Raft 状态用 `quorum_status`，可用 info item 以官方文档为准。

### 3.3 与镜像队列的行为差异表

| 行为 | 经典镜像队列（3.x 遗留） | 仲裁队列 |
|---|---|---|
| 复制协议 | 自研主从同步 | Raft 多数派提交 |
| 数据安全承诺 | 无严格承诺，未同步副本提升即丢 | 多数派落盘，与 confirm 联动（confirm = 多数派已落盘） |
| durable | 可 true/false | **恒为 durable**，声明时 durable 必须为 true |
| 独占队列 | 支持 | 不支持 exclusive |
| 消息重投上限 | 无（配合 DLX 自己挡） | `x-delivery-limit`：超过次数转死信，治毒消息循环（3.x 默认无限次，4.0 默认 20，以官方文档为准） |
| 存放位置 | 镜像尽量驻留内存 | 数据以磁盘为主、内存做缓存——对 fsync 延迟敏感，必须上 SSD |
| 重启后 | 全量同步 mirror | Raft 日志回放，从盘上恢复 |
| 4.0 命运 | 整体移除 | 默认推荐 |

与第 1 章 §3 串起来：生产端 confirm + 仲裁队列 + 持久化消息，是 RabbitMQ 能给出的最强"不丢"组合——confirm 回执等的就是多数派落盘。代价是每次写的 fsync 延迟与跨节点 RTT，吞吐上限明显低于 classic 队列：可靠性换性能，没有免费午餐（和 Kafka `acks=all` + `min.insync.replicas` 的取舍同构，见 [14-data-streaming/kafka/02-replication-and-reliability.md](../14-data-streaming/kafka/02-replication-and-reliability.md) §5）。

## 4. 网络分区：pause_minority 与朋友

```
 分区前: A ── B ── C                分区后: A  ║  B ── C
                                      少数派      多数派
 ┌─────────┐   ┌─────────┐   ┌─────────┐
 │    A    │═══│    B    │═══│    C    │      ignore（默认）:
 └─────────┘   └─────────┘   └─────────┘        两侧各自继续写，愈合后数据冲突
                                              pause_minority: A 自我暂停，B-C 继续服务
                                              pause_if_all_down: 联不上可信列表即暂停
```

`cluster_partition_handling` 三种策略：

| 策略 | 行为 | 适用 |
|---|---|---|
| `ignore`（默认） | 双侧继续跑，各自写各自的，愈合后元数据冲突要人工修 | 仅配合仲裁队列的纯 QQ 集群才勉强可接受，一般不要用 |
| `pause_minority` | **少数派自我暂停**（拒绝一切客户端操作），多数派继续 | 3+ 奇数节点集群的官方推荐 |
| `pause_if_all_down` | 与配置的可信节点列表全部失联才暂停 | 多网卡/多可用区等 pause_minority 误判的场景 |

- `pause_minority` 的本质是**把分布式共识里的"少数派闭嘴"上移到整节点级别**（理论见 [19-distributed/03](../19-distributed/03-consensus-and-replication.md) §2 的 quorum 数学）。它要求集群是 3 个以上奇数节点：2+2 的四节点双分区两侧都是少数派，会全部暂停、整体不可用——这就是"不要偶数节点"的运维后果。
- 仲裁队列自身在分区里已经安全：少数派侧的 Raft 成员选不出 leader、写入失败，多数派侧正常服务。`pause_minority` 仍被推荐，是为了少数派侧的 classic 队列、元数据写入不要在分区期间制造需要人工修复的分裂。
- 愈合后：被暂停的节点重启或分区恢复时自动重新入队同步。`rabbitmqctl cluster_status` 的 `Partitions` 段非空 = 出过分区，日志里搜 `partition` 能看到处理过程。

## 5. 跨机房复制：Shovel 与 Federation

quorum 集群解决的是**同机房**容错；把三副本拉到跨机房会让每次写都吃广域 RTT，仲裁队列的 fsync 延迟直接被距离放大。跨机房通常做法：每机房一套独立集群，之间用插件做**逻辑复制**：

```
 机房一（3 节点 quorum 集群）              机房二（3 节点 quorum 集群）
  exchange orders ──► queue q1             exchange orders ──► queue q2
        ▲                                        ▲
        └─── Federation：按绑定持续单向复制 ───────┘
        或者 Shovel：把 q1 的消息搬运到对端队列/交换机
```

| 维度 | Shovel（rabbitmq_shovel） | Federation（rabbitmq_federation） |
|---|---|---|
| 复制什么 | **具体队列里的消息**：源队列消费 → 发布到目的地（队列或交换机） | **逻辑交换机/队列的订阅流**：上游按本地下发的绑定持续推送 |
| 工作方式 | 点对点搬运（像一条泵） | 单向持续复制（像订阅上游） |
| 语义 | at-least-once（源端 ack 在目的端 confirm 之后） | at-least-once |
| 断线行为 | 自动重连、源队列堆积等待 | 自动重连、恢复续传 |
| 典型用途 | 集群间迁移、机房间的消息搬运、削峰缓冲 | 事件跨机房扇出、多机房→中心汇聚（树形拓扑） |
| 配置形态 | dynamic shovel：`rabbitmqctl set_parameter shovel ...` 一条参数即建 | upstream + policy 声明在接收端 |

两个共同点决定它们的定位：**都是应用层逻辑复制，不参与对方的 quorum**——机房一整体炸了，机房二只有已被复制过去的消息；复制链路是异步的，跨机房 RPO 不为零。所以它们是"跨地域分发/容灾降级"方案，不是把两个机房凑成一个 HA 集群的手段。

## 6. K8s 部署：RabbitMQ Cluster Operator

生产上自搭集群（docker run + join_cluster）不适合长期运维，官方提供 [Cluster Operator](https://github.com/rabbitmq/cluster-operator)：一个 CRD 撑起全部运维意图（CKA 学的 Operator + StatefulSet + PVC 模式的标准应用）。

```bash
# [master] 安装 Operator（版本以官方文档最新发布为准）
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml
kubectl -n rabbitmq-system get deployment
```

```yaml
# [master] rmq-cluster.yaml：3 副本 + 持久卷 + 分区策略（字段以所装 Operator 版本的官方 API 为准）
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: rmq
  namespace: rabbits
spec:
  replicas: 3
  persistence:
    storageClassName: standard      # 换成练习集群实际存在的 StorageClass
    storage: 10Gi
  rabbitmq:
    additionalConfig: |
      cluster_partition_handling = pause_minority
```

```bash
# [master] 部署并验证
kubectl create namespace rabbits
kubectl -n rabbits apply -f rmq-cluster.yaml
kubectl -n rabbits get rabbitmqcluster rmq        # 预期: AllReplicasReady 与 ReconcileSuccess 逐渐变为 true
                                                  #（该 CRD 的打印列是 AllReplicasReady/ReconcileSuccess/Age，没有 STATUS 列）
kubectl -n rabbits get pods -l app.kubernetes.io/name=rmq
# 预期: rmq-server-0/1/2 三个 Pod（Operator 建的 StatefulSet 叫 <name>-server）
kubectl -n rabbits get pvc                         # 预期: 每副本一块 10Gi PVC——队列数据就靠它活过重启
kubectl -n rabbits get secret rmq-default-user -o jsonpath='{.data.username}' | base64 -d; echo
# 预期: 输出自动生成的默认用户名（密码在同名 secret 的 password 键）
kubectl -n rabbits port-forward svc/rmq 15672:15672   # 本地打开 http://localhost:15672
```

Operator 替你做了 §1 的全部体力活：headless service `rmq-nodes` 保证节点名解析、Erlang cookie 自动生成进 secret、peer discovery 走 Kubernetes API（新 Pod 起来自己找组织）、PVC 与 StatefulSet 绑定。要改队列默认类型、镜像/资源、监控插件，全部改 CR spec。监控面：默认带 Prometheus 插件（15692 端口），队列深度、unacked、Raft 成员状态都有现成指标，接 PCA 的告警思路（积压绝对值 + 增速两条线）。

## 实战演练

环境：装有 Docker 的 Ubuntu VM。目标：组三节点集群，建仲裁队列，停掉 leader 验证多数派继续服务。真正的网络分区需要 iptables/tc 拓扑，本演练用"停节点"近似"多数派存活"场景。

```bash
# [任意节点] 三节点：同网络 + 同 Erlang cookie + name 与 hostname 一致（容器名即节点名可解析）
docker network create rmq-net
docker run -d --name rmq1 --network rmq-net --hostname rmq1 \
  -p 5672:5672 -p 15672:15672 \
  -e RABBITMQ_ERLANG_COOKIE=SRE-RMQ-LAB \
  -e RABBITMQ_DEFAULT_USER=sre -e RABBITMQ_DEFAULT_PASS=sre12345 \
  rabbitmq:3-management
docker run -d --name rmq2 --network rmq-net --hostname rmq2 \
  -p 5673:5672 -p 15673:15672 -e RABBITMQ_ERLANG_COOKIE=SRE-RMQ-LAB rabbitmq:3-management
docker run -d --name rmq3 --network rmq-net --hostname rmq3 \
  -p 5674:5672 -p 15674:15672 -e RABBITMQ_ERLANG_COOKIE=SRE-RMQ-LAB rabbitmq:3-management
sleep 15
```

```bash
# [任意节点] rmq2/rmq3 依次加入 rmq1（stop_app→reset→join→start_app 四步是标准姿势）
for n in rmq2 rmq3; do
  docker exec $n rabbitmqctl stop_app
  docker exec $n rabbitmqctl reset
  docker exec $n rabbitmqctl join_cluster rabbit@rmq1
  docker exec $n rabbitmqctl start_app
done
docker exec rmq1 rabbitmqctl cluster_status | grep -A4 'Running Nodes'
# 预期: rabbit@rmq1 / rabbit@rmq2 / rabbit@rmq3 三行，且 Partitions 为空
# 用户 sre 是元数据，随集群同步——三个节点都能用它登录（试试 http://<VM-IP>:15673）
```

```bash
# [任意节点] 建一条仲裁队列 + 一条 classic 队列对比
curl -s -u sre:sre12345 -X PUT http://localhost:15672/api/queues/%2F/orders.qq \
  -H "content-type: application/json" \
  -d '{"auto_delete":false,"durable":true,"arguments":{"x-queue-type":"quorum"}}'
curl -s -u sre:sre12345 -X PUT http://localhost:15672/api/queues/%2F/orders.classic \
  -H "content-type: application/json" -d '{"auto_delete":false,"durable":true}'
docker exec rmq1 rabbitmqctl list_queues name type
# 预期: orders.qq  quorum
#       orders.classic  classic
docker exec rmq1 rabbitmq-queues quorum_status orders.qq
# 预期: 三个成员分列 leader / follower / follower，记下谁是 leader（假设下面输出显示是 rmq1）
```

```bash
# [任意节点] 停掉 leader，从幸存节点发布并消费——多数派无感切换
docker stop rmq1
sleep 5
curl -s -u sre:sre12345 -X POST http://localhost:15673/api/exchanges/%2F/amq.default/publish \
  -H "content-type: application/json" \
  -d '{"properties":{"delivery_mode":2},"routing_key":"orders.qq",
       "payload":"order-9001","payload_encoding":"string"}'
# 预期: {"routed":true}（经默认交换机投进 orders.qq；quorum=2，两成员落盘即成功）
curl -s -u sre:sre12345 -X POST http://localhost:15673/api/queues/%2F/orders.qq/get \
  -H "content-type: application/json" \
  -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}'
# 预期: payload 含 order-9001 —— 剩余两成员已选出新 leader，读写正常
docker exec rmq2 rabbitmq-queues quorum_status orders.qq
# 预期: 成员列表仍列出 3 个成员——宕机成员只有显式 shrink 才会从列表消失；
#       rmq1 行的 Raft State 显示异常（RPC 失败/不可达），leader 已换成 rmq2 或 rmq3

docker start rmq1; sleep 20
docker exec rmq2 rabbitmq-queues quorum_status orders.qq
# 预期: rmq1 行恢复为 follower（成员数前后都是 3，变化的是状态与 leader 位置，不是成员数量）
docker exec rmq1 rabbitmqctl cluster_status | grep -A4 'Running Nodes'
```

验证方法：围绕 `quorum_status` 做前后对照（3 成员 → 停 leader 后仍列 3 个成员、宕机行状态异常、leader 切换 → 重启后该行恢复 follower；成员行只有显式 `shrink` 后才从列表消失）；对照 classic 队列 orders.classic——它没有 quorum_status 可看，如果它的宿主恰好是被停的节点，连 get 都会失败，亲手验证 §1 的"消息不默认复制"。清理：`docker rm -f rmq1 rmq2 rmq3; docker network rm rmq-net`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| join_cluster 卡住/握手失败 | Erlang cookie 不一致，或 4369/25672 不通、节点名解析失败 | 三件事逐一查：cookie、端口、hostname 解析 |
| 三节点集群，一个节点挂了消息还是丢 | classic 队列数据只在宿主节点，集群不复制消息 | 关键队列用 quorum 类型；梳理存量队列 `list_queues name type` |
| 队列声明报错 PRECONDITION_FAILED | 同名队列已存在且参数不同（type/durable/参数都要完全一致） | 改参数必须删队列重建（或换名字）；声明参数进版本管理 |
| 仲裁队列写延迟高、TPS 上不去 | 每写一次多数派 fsync，副本多/磁盘慢/跨机房 | SSD、副本数 3 或 5、集群留在同机房，跨机房走 Shovel/Federation |
| 毒消息无限重投打满 CPU | requeue=true 没有次数上限概念 | quorum 队列配 x-delivery-limit + DLX |
| 分区愈合后元数据错乱、要人工修 | 用了默认 ignore 分区策略 | pause_minority + 奇数节点；复盘看 cluster_status 的 Partitions |
| 4.0 升级后老队列消失 | 镜像队列在 4.0 整体移除 | 升级前把 CMQ 迁到 quorum（官方有迁移指引） |
| 四节点集群对等分区分区后全停 | pause_minority 下两侧都是少数派 | 节点数保持奇数；跨机房用 3+3 两套集群 + 复制插件 |

## 自测

1. "RabbitMQ 集群高可用，所以 rmq2 宕机不影响消息"——这句话错在哪？什么时候才算对？
<details><summary>答案</summary>

集群只复制元数据，classic 队列的消息数据始终只在宿主节点；rmq2 宕机，宿主在 rmq2 的 classic 队列整体不可用直到节点恢复。只有把队列建成仲裁队列（Raft 多数派复制）后，单节点故障才不影响该队列的读写——对的那一刻前提是"quorum 队列 + 剩余节点仍构成多数派"。
</details>

2. 镜像队列和仲裁队列都做"多副本"，为什么官方宁可废弃前者重写后者？
<details><summary>答案</summary>

镜像队列的复制是自研主从同步：没有多数派提交的数学保证，未完成同步的 mirror 被提升成 master 就丢数据；分区行为难以推理，confirm 与复制的边界 case 修不完。仲裁队列把队列实现成 Raft 日志，借共识协议拿到可证明的安全性（多数派落盘才确认、至多一个 leader、选举不丢已提交条目——见 19-distributed/03 §4），以可理解性换工程正确率，这正是 Raft 论文的设计初衷。
</details>

3. 五节点集群里一条仲裁队列配了初始成员数 5，再挂 2 个节点，队列还能读写吗？配 4 个成员呢？
<details><summary>答案</summary>

5 成员 quorum=3，挂 2 剩 3 恰好多数派，可继续读写（但再挂一个就不可写）。4 成员 quorum=3，挂 2 剩 2 < 3，队列拒绝写入——容忍故障数是 1，比 3 成员（容忍 1）花了更多副本却没换来更高容错，偶数成员纯属浪费，这是 19-distributed/03 §2 的 NWR 数学在运维侧的直接应用。
</details>

4. pause_minority 策略下，三节点集群 A|B-C 分区：A 侧的客户端会发生什么？为什么这个"不可用"反而是设计目的？
<details><summary>答案</summary>

A 检测到自己属少数派后暂停，A 侧客户端所有 AMQP 操作直接报错。设计目的是防止少数派侧继续接受写入、在分区愈合后与多数派产生元数据与队列数据冲突——宁可少数派整体不可用，也不产出需要人工修复的分裂数据。这是"少数派必须闭嘴"（19-distributed/03 §2）在整节点级别的实现；代价是分区期间挂在少数派上的业务必须容忍报错（重试/降级），这与 Redis 哨兵 min-replicas-to-write 的取舍同构。
</details>

5. 为什么说 Shovel/Federation 是容灾降级而不是高可用？给出一个必须用它们、同时必须再配同机房 quorum 集群的场景。
<details><summary>答案</summary>

它们做的是应用层逻辑复制：异步、at-least-once、不参与对端 quorum——机房一整体故障时，机房二只拥有"已被复制过去"的消息，RPO 不为零，且复制链路断开期间消息只堆积在源端。双活/异地容灾场景里：同机房内必须 quorum 集群保证单个节点/磁盘故障零丢失，跨机房再用 Federation 做事件扇出（或 Shovel 做迁移/搬运），两层各管一类故障，不能互相替代。
</details>

## 延伸阅读

- 官方集群构成指南（disk/ram、peer discovery、端口）：https://www.rabbitmq.com/clustering
- 官方仲裁队列文档（复制、delivery-limit、rebalance）：https://www.rabbitmq.com/quorum-queues
- 官方网络分区处理（pause_minority 等）：https://www.rabbitmq.com/partitions
- 官方经典镜像队列废弃说明与迁移指引：https://www.rabbitmq.com/ha
- Shovel 与 Federation 官方文档：https://www.rabbitmq.com/shovel 、https://www.rabbitmq.com/federation
- Cluster Operator 官方仓库与文档：https://github.com/rabbitmq/cluster-operator
