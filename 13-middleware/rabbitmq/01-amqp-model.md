# 01 · RabbitMQ AMQP 模型：路由、确认与语义边界

> 模块：13-middleware/rabbitmq ｜ 建议时长：3 小时 ｜ 关联认证：—（CKA/CKS/PCA 无直接考点；消息可靠性参数评审、积压指标告警与 PCA 思路相通，K8s 部署见第 2 章）

## 学习目标

- 能画出 Producer → Exchange → Binding → Queue → Consumer 四层模型，解释"消息从不直接进队列"以及路由失败时会发生什么
- 能按 routing key 匹配规则表，为 direct / fanout / topic / headers 四种交换机做选型，并手算一组 topic 通配符匹配
- 能区分 publisher confirm、mandatory、durable、persistent、consumer ack 各自保证与不保证什么，说出 prefetch 的背压作用
- 能用一张表对比 RabbitMQ 与 Kafka 的模型差异（路由树 vs 分区日志、push vs pull、语义边界），按场景选型
- 能解释 Redis pub/sub 与 RabbitMQ 在持久化、消费确认上的本质差别，说出各自合适的场景

版本约定：以 **RabbitMQ 3.13**（docker 镜像 `rabbitmq:3-management`）为准，4.x 行为差异处单独标注；AMQP 协议版本是 0-9-1（AMQP 1.0 插件 rabbitmq_amqp1_0 自 3.7.0 起随 RabbitMQ 分发、长期标注 experimental，原生核心 AMQP 1.0 支持是 4.0 才引入的，本文不展开）。

## 1. 四层模型：消息从不直接进队列

RabbitMQ 实现的是 AMQP 0-9-1 协议。它最核心的设计决定：**生产者永远不把消息投给队列，只投给交换机**；消息进哪条（甚至哪几条）队列，由交换机类型 + 绑定规则决定：

```
 Producer ──publish──► Exchange ──binding──► Queue ──push──► Consumer
 (routing key)          (路由算法)  (routing key)             (ack/nack)

   P1 ──"order.pay"──► ┌─────────────┐
                      │ logs.topic   │──"#"──────► q.all ─────► C1
                      │ (topic)      │─"*.pay"───► q.pay ──┐
                      └─────────────┘─"order.#"──► q.order │
                                                  C2 ◄─────┘
   一条 "order.pay" 同时命中三条绑定 → 投进三条队列，成为三条独立副本
```

各层职责：

| 层 | 是什么 | 运维关注点 |
|---|---|---|
| Exchange | 路由器，收到消息后按类型与绑定做匹配 | 类型选型、durable、未被使用的交换机堆积 |
| Binding | 交换机到队列的边，带 binding key | 排查"消息没进队列"第一现场 |
| Queue | 真正存消息的缓冲区（有名字、可枚举） | durable、类型（classic/quorum/stream）、积压深度 |
| Consumer | 从队列收消息并 ack 的客户端 | prefetch、unacked 数、重复消费 |

三条容易踩命的规则：

- **路由不到任何队列 = 静默丢弃**。broker 不报错、不留痕，这是"消息莫名丢了"的头号根因。防护：发布时带 `mandatory` 标志（路由失败经 `basic.return` 退回生产端），或给交换机声明 `alternate-exchange` 参数兜底。
- **一条消息命中 N 条绑定，就是 N 份独立副本**。改其中一条队列的消费进度不影响其他队列——这和 Kafka"一份日志多个消费组各自管 offset"完全不同（§4）。
- **vhost 是逻辑隔离单元**。队列、交换机、绑定、权限都挂在 vhost 下；默认 vhost 是 `/`，HTTP API 里要 URL 编码成 `%2F`。多业务共用集群时按 vhost 划边界。

默认交换机是唯一"看起来像直接投队列"的例外：名字是空字符串的 direct 交换机，每条队列声明时自动与它绑定、binding key 等于队列名——所以"往默认交换机发 routing key = 队列名"效果上等于直投，本质只是走了一条内置路由。

## 2. 四种交换机与匹配规则

| 类型 | 路由算法 | 典型场景 | 备注 |
|---|---|---|---|
| direct | routing key 与 binding key **完全相等** | 点对点任务分发 | 默认交换机就是 direct |
| fanout | 广播到**所有**绑定队列，完全忽略 key | 一份事件多方订阅（通知、审计） | binding 上的 key 形同虚设 |
| topic | 通配符匹配点分单词 | 按主题订阅 `order.*`、`#.error` | 业务上最常用 |
| headers | 只看消息 header 键值对，`x-match=any/all` | 复杂路由且不想污染 routing key | 性能最差，多见于遗留系统 |

topic 的通配符按**点分单词**匹配：`*` 恰好吃掉一个词，`#` 吃零到多个词。用一张表手算（✓ 投递 / ✗ 不投递）：

| binding key \ routing key | `order.pay` | `order.pay.v2` | `pay` | `user.pay` | `order` |
|---|---|---|---|---|---|
| `order.*` | ✓ | ✗ | ✗ | ✗ | ✗（`*` 必须恰好一个词） |
| `order.#` | ✓ | ✓ | ✗ | ✗ | ✓（`#` 可以零个词） |
| `*.pay` | ✓ | ✗ | ✗ | ✓ | ✗ |
| `#` | ✓ | ✓ | ✓ | ✓ | ✓（全匹配） |

两个高频错误：`order.*` 收不到 `order.pay.v2`（`*` 只吃一个词）；`order.*` 收不到 `order`（`*` 不匹配零个词，要用 `#`）。

## 3. 可靠性三道闸：confirm、持久化、ack

一条消息从生产到消费完成，三道确认缺一不可：

```
 生产端                                消费端
   │ publish(mandatory)                  │ basic.consume(prefetch=N)
   ▼                                     ▼
 ┌──────────────────── broker ──────────────────────────┐
 │ 路由不到队列 ──► basic.return（仅 mandatory=true 时退回）│
 │ 路由成功     ──► 异步回执 confirm（ack/nack）           │
 │   ├─ transient 消息：broker 接收即 confirm             │
 │   ├─ durable 队列 + persistent 消息：落盘后 confirm     │
 │   └─ quorum 队列：多数派落盘后 confirm（第 2 章）        │
 │                                                       │
 │ basic.deliver ──► unacked ──► basic.ack ──► 消息删除    │
 │                          └─► nack/reject ──► 重投或死信 │
 └───────────────────────────────────────────────────────┘
```

### 3.1 生产端：publisher confirm 与 mandatory

- **confirm**：信道开启 `confirm.select` 后，broker 对每条消息异步回执 `confirm.ack`（收到）或 `confirm.nack`（内部错误，极罕见）。回执时机取决于消息与队列属性：持久化消息要等落盘，quorum 队列要等多数派落盘——所以 confirm 是"broker 部分负责"的证据，不是"业务处理完成"的证据。
- **mandatory**：只管路由。路由不到任何队列时经 `basic.return` 退回，而不是静默丢弃。和 confirm 解决的是两个正交问题：一个管"到没到队列"，一个管"broker 收没收"。两个都开才算把生产端闭环。
- **AMQP 事务（tx.select/commit）**：同步阻塞、吞吐差，confirm 的出现就是为了替代它，新代码不要再用。

### 3.2 持久化：两个开关缺一不可

`durable=true` 只保证**队列定义**在 broker 重启后还在；消息本身要落盘还必须发布时带 `properties.delivery_mode = 2`（persistent）。只开一个就是经典的"重启后队列还在、消息没了"。但两个都开也**不等于绝对不丢**：classic 队列的持久化是异步刷盘，broker 宕机仍可能丢掉最近一段——要接近不丢，用仲裁队列（quorum，第 2 章）+ confirm。

### 3.3 消费端：ack、nack、reject 与 prefetch

broker 把消息 push 给消费者（`basic.deliver`），消息进入 unacked 状态；消费者回三种回执之一：

| 回执 | 范围 | requeue=true | requeue=false |
|---|---|---|---|
| `basic.ack` | 单条或多条（multiple 标志） | — | — |
| `basic.nack` | 可批量否定 | 重新入队、再次投递 | 丢弃或进死信队列（配了 DLX 时） |
| `basic.reject` | 只能单条 | 同上 | 同上 |

- 消费者在 ack 之前**连接断开/信道关闭**，所有 unacked 消息自动 requeue，重投时 `redelivered=true`——这就是"消费者反复收到同一条消息"的机理，也是 RabbitMQ 至少一次语义的来源（§4）。
- `requeue=true` 没有"重试几次"概念，消息处理一直失败就会无限重投（毒消息循环）。正确姿势：配 `x-dead-letter-exchange` + 仲裁队列的 `x-delivery-limit`（超次转死信，第 2 章）。
- **prefetch（basic.qos）**：限制单个消费者 unacked 的上限。不设的话 broker 会把队列里能推的都推给先连上的消费者——快消费者闲死、慢消费者压死。推模型下这就是 broker 端背压：unacked 打满即暂停推送，消费者一 ack 立刻补发。经验值 10~100 起步，处理越慢设越小。
- **consumer_timeout**（3.8.15+ 默认 30 分钟）：消息投出后超时未 ack，broker 直接关闭信道（`PRECONDITION_FAILED`），unacked 全部重投。长任务要么拆分要么显式调参。

## 4. 与 Kafka 对比：路由模型 vs 分区日志

Kafka 的心智模型见 [14-data-streaming/kafka/01-log-model-and-architecture.md](../14-data-streaming/kafka/01-log-model-and-architecture.md)（topic/partition/offset 三层模型）与 [02 章](../14-data-streaming/kafka/02-replication-and-reliability.md) §8（位移提交语义）。两者常被混用，但底层模型几乎处处相反：

| 维度 | RabbitMQ | Kafka |
|---|---|---|
| 数据模型 | 路由树：一条消息按绑定投给 N 条队列，消费即删 | 分区日志：消息按 key 哈希进分区，append-only，按 retention 保留 |
| 路由 | broker 内完成（exchange + binding） | 客户端分区器决定进哪个分区，消费组订阅分区 |
| 投递方向 | **push**（broker 主动 basic.deliver） | **pull**（消费者自己 fetch、自己管 offset） |
| 背压 | 靠 prefetch/unacked 上限显式限制 | pull 天然背压（[kafka 01](../14-data-streaming/kafka/01-log-model-and-architecture.md) §4-5） |
| 回溯 | ack 后即删，不可重放（stream 队列类型除外） | offset 任意回放，天然支持重跑/补数 |
| 顺序 | 单队列 FIFO | 单分区内有序 |
| 语义 | confirm = broker 收到（quorum 下多数派落盘）；消费端 at-least-once，去重靠业务幂等 | 幂等 producer + 事务，**Kafka→Kafka 链路可端到端 exactly-once**（[kafka 02](../14-data-streaming/kafka/02-replication-and-reliability.md) §8） |
| 积压指标 | queue depth（messages_ready/unacked） | consumer lag |
| 强项 | 低延迟路由、任务队列、细粒度分发规则 | 高吞吐流式管道、回放、多消费者独立进度 |

**exactly-once 的语义边界**要答准：Kafka 的事务只覆盖"从 Kafka 读、处理后写回 Kafka"的流处理链路，一旦下游是外部系统（写库、发 HTTP），它同样退化为 at-least-once、靠业务幂等兜底。RabbitMQ 的 confirm 只承诺 broker 侧接收与落盘，消费端 ack 前崩溃必然重投——**没有任何消息系统能替业务消灭重复，只能选择"丢"还是"重"**，这正是 kafka 02 章位移提交语义的同款取舍：先处理后确认 = at-least-once，先确认后处理 = at-most-once。

选型一句话：要回放、要吞吐、要多组独立消费进度 → Kafka；要复杂路由、要任务队列、要秒级低延迟分发 → RabbitMQ。

## 5. 与 Redis pub/sub 对比：持久化与确认

Redis 的 `PUBLISH/SUBSCRIBE` 是纯内存的 fire-and-forget 广播；RabbitMQ 队列是可落盘、可确认的缓冲区。Redis 的持久化机制（RDB/AOF，见 [13-middleware/redis/02-persistence-and-ha.md](../redis/02-persistence-and-ha.md) §2-3）**只覆盖键空间**，pub/sub 频道里的消息从不进 RDB/AOF：

| 维度 | RabbitMQ 队列 | Redis pub/sub |
|---|---|---|
| 存储 | durable 队列 + persistent 消息落盘（quorum 多数派落盘） | 纯内存转发，从不持久化 |
| 离线订阅者 | 消息堆积在队列等消费者回来 | 断线期间的消息直接错过 |
| 消费确认 | ack/nack/prefetch，未确认自动重投 | 无确认，发完即忘 |
| 慢消费者 | prefetch 限流，消息留在 broker | 订阅者 output buffer 超限被直接断连（`client-output-buffer-limit pubsub`） |
| 语义 | at-least-once | at-most-once |
| 典型用途 | 任务队列、可靠事件分发 | 在线广播、缓存失效通知这类"错过一条也无妨"的场景 |

如果需要"Redis 生态里的 RabbitMQ"，对标的不是 pub/sub 而是 **Redis Streams**（`XADD/XREADGROUP/XACK`，pending 列表 + 消费组），它补上了持久化与确认。反过来，用 Redis pub/sub 承载业务关键事件，等于默认接受了"订阅者重启就丢消息"。

## 实战演练

环境：装有 Docker 的 Ubuntu VM（下同，标注 `[任意节点]`）。目标：用 HTTP API + Web UI 把第 1、2 节的路由规则亲手跑一遍。

```bash
# [任意节点] 起单节点（management 镜像内置 Web UI + HTTP API，端口 5672/15672）
# 官方镜像的 conf.d/10-defaults.conf 写了 loopback_users.guest = false，Docker 里的 guest
# 并无"仅限 localhost"限制（裸机/包安装才默认受限，见第 3 章 §4.1）；
# 这里设 RABBITMQ_DEFAULT_USER=sre 建专用账号，此时 guest 根本不会被创建
docker run -d --name rmq-lab -p 5672:5672 -p 15672:15672 \
  -e RABBITMQ_DEFAULT_USER=sre -e RABBITMQ_DEFAULT_PASS=sre12345 \
  rabbitmq:3-management
```

浏览器打开 `http://<VM-IP>:15672`，用 sre / sre12345 登录。Exchanges 页能看到预声明的 `amq.direct / amq.fanout / amq.topic / amq.headers` 与默认交换机（名字为空）。

```bash
# [任意节点] 声明 topic 交换机（%2F 是默认 vhost "/" 的 URL 编码，写脚本最常漏这个）
curl -s -u sre:sre12345 -X PUT http://localhost:15672/api/exchanges/%2F/logs.topic \
  -H "content-type: application/json" -d '{"type":"topic","durable":true}'

# [任意节点] 声明三条 durable 队列
for q in q.all q.pay q.order; do
  curl -s -u sre:sre12345 -X PUT http://localhost:15672/api/queues/%2F/$q \
    -H "content-type: application/json" -d '{"auto_delete":false,"durable":true}'
done

# [任意节点] 绑定：# / *.pay / order.#
curl -s -u sre:sre12345 -X POST http://localhost:15672/api/bindings/%2F/e/logs.topic/q/q.all \
  -H "content-type: application/json" -d '{"routing_key":"#"}'
curl -s -u sre:sre12345 -X POST http://localhost:15672/api/bindings/%2F/e/logs.topic/q/q.pay \
  -H "content-type: application/json" -d '{"routing_key":"*.pay"}'
curl -s -u sre:sre12345 -X POST http://localhost:15672/api/bindings/%2F/e/logs.topic/q/q.order \
  -H "content-type: application/json" -d '{"routing_key":"order.#"}'
```

```bash
# [任意节点] 验证 §2 的匹配表：发布 order.pay，应同时进三条队列
curl -s -u sre:sre12345 -X POST http://localhost:15672/api/exchanges/%2F/logs.topic/publish \
  -H "content-type: application/json" \
  -d '{"properties":{"delivery_mode":2},"routing_key":"order.pay",
       "payload":"order-1001","payload_encoding":"string"}'
# 预期: {"routed":true}
docker exec rmq-lab rabbitmqctl list_queues name messages_ready messages_unacknowledged
# 预期: q.all/q.pay/q.order 各 1（order.pay 命中 #、*.pay、order.# 三条绑定）

# 再发一条 order.pay.v2 验证通配符边界：*.pay 不该收到
curl -s -u sre:sre12345 -X POST http://localhost:15672/api/exchanges/%2F/logs.topic/publish \
  -H "content-type: application/json" \
  -d '{"properties":{"delivery_mode":2},"routing_key":"order.pay.v2",
       "payload":"order-1002","payload_encoding":"string"}'
docker exec rmq-lab rabbitmqctl list_queues name messages_ready
# 预期: q.all +1、q.pay 不变、q.order +1（order.* 语义边界用绑定 order.* 可自行复测）
```

```bash
# [任意节点] 演示"路由不到 = 静默丢弃"：往没有对应绑定的 amq.direct 发
curl -s -u sre:sre12345 -X POST http://localhost:15672/api/exchanges/%2F/amq.direct/publish \
  -H "content-type: application/json" \
  -d '{"properties":{},"routing_key":"no.such.queue","payload":"lost","payload_encoding":"string"}'
# 预期: {"routed":false} —— 生产端若不开 mandatory，这条消息无声消失（Web UI 无任何痕迹）
```

```bash
# [任意节点] 消费与确认：get 接口带 ackmode，等价于客户端的 basic.get + ack
curl -s -u sre:sre12345 -X POST http://localhost:15672/api/queues/%2F/q.pay/get \
  -H "content-type: application/json" \
  -d '{"count":1,"ackmode":"ack_requeue_true","encoding":"auto"}'
# 预期: 返回 order-1001 且 "redelivered":false —— requeue=true 表示未确认回队列
curl -s -u sre:sre12345 -X POST http://localhost:15672/api/queues/%2F/q.pay/get \
  -H "content-type: application/json" \
  -d '{"count":1,"ackmode":"ack_requeue_true","encoding":"auto"}'
# 预期: 同一条消息但 "redelivered":true —— 这就是"未 ack 就重投"的最小复现
curl -s -u sre:sre12345 -X POST http://localhost:15672/api/queues/%2F/q.pay/get \
  -H "content-type: application/json" \
  -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}'
# 预期: redelivered:true 且取走后 messages_ready 归零（等价 basic.ack）
```

验证方法：每步用 `rabbitmqctl list_queues` 与 Web UI 队列页的消息曲线交叉核对；Web UI 里点进 logs.topic 可视化看到三条 binding。清理：`docker rm -f rmq-lab`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 消息发出去了，下游说没收到 | 路由不到任何队列，broker 静默丢弃 | 排查 bindings；发布开 mandatory + Return 回调，或配 alternate exchange |
| Web UI 用 guest 登录被拒 | 本章容器设了 RABBITMQ_DEFAULT_USER，guest 根本未被创建（注意：官方镜像配了 loopback_users.guest = false，Docker 里的 guest 并非"仅限 localhost"，别因这个误解放松处理） | 用独立账号登录；裸机/包安装的 guest 默认仅限 localhost，见第 3 章 §4.1 |
| broker 重启后队列还在、消息没了 | 只开了队列 durable，消息 delivery_mode=1 | durable 队列 + persistent 消息两个开关都开 |
| 消费者反复收到同一条消息 | ack 前断连触发重投，requeue 无限循环 | 业务幂等 + DLX + 仲裁队列 x-delivery-limit |
| 某个消费者内存暴涨、其余吃不饱 | 没设 prefetch，broker 把消息全推给先连上的 | basic.qos 设 prefetch，10~100 起步按处理耗时调 |
| 消费 30 分钟后信道报 PRECONDITION_FAILED | consumer_timeout 默认 30 分钟未 ack | 拆任务或调 consumer_timeout；别用它当业务重试 |
| topic 绑 order.* 收不到 order.created.v2 | `*` 只匹配一个点分单词 | 改 order.#；边界规则回看 §2 匹配表 |

## 自测

1. 为什么说"生产者从不直接把消息投给队列"？默认交换机为什么看起来像例外？
<details><summary>答案</summary>

AMQP 把路由职责完全交给 exchange：生产者只声明目标交换机 + routing key，消息进哪条队列由交换机类型和 binding 决定，因此换路由规则不需要改生产者代码。默认交换机（名字为空的 direct）并不是绕过路由，而是 broker 为每条队列自动创建的 binding key = 队列名的内置绑定，"直投"只是复用了这条内置路由。
</details>

2. publisher confirm 和 mandatory 分别解决什么问题？两者能互相替代吗？
<details><summary>答案</summary>

不能，正交。confirm 回答"broker 是否收到并（按消息属性）落盘"，覆盖路由成功后的整条链路；mandatory 回答"这条消息是否路由到了至少一条队列"，路由失败经 basic.return 退回。只开 confirm：路由失败时 broker 一样回 confirm（它确实"收到"了），消息无声消失；只开 mandatory：broker 宕机、落盘前断电无任何回执。生产端闭环 = confirm + mandatory。
</details>

3. durable 队列、persistent 消息、publisher confirm 全开了，为什么仍可能丢消息？
<details><summary>答案</summary>

classic 队列的持久化是异步刷盘：confirm 回执可能在消息还在页缓存时发出，broker 断电丢掉最近一段；confirm 本身只承诺 broker 侧接收，不承诺消费完成。要继续收敛窗口：用 quorum 队列（confirm 等多数派落盘，第 2 章）+ 消费端幂等 ack；彻底不丢不存在，只剩"丢"与"重"的取舍。
</details>

4. RabbitMQ 是推模式，为什么还必须由客户端设 prefetch？这个参数和 Kafka 的 pull 模式里的"背压"是什么关系？
<details><summary>答案</summary>

推模式下 broker 只要知道消费者在线就会投递，不做速度协商；没有 prefetch 时 unacked 无上限，快消费者囤消息、慢消费者被打爆，broker 内存也被 unacked 记账撑大。prefetch 就是推模型的显式背压：unacked 打满即停推、一 ack 即补发。Kafka 用 pull 把同一问题交给消费者自己解决——fetch 速率天然就是背压，不需要 broker 端流控参数（kafka 01 章 §4-5）。
</details>

5. 同样是"发布-订阅"，什么场景 Redis pub/sub 就够，什么场景必须上 RabbitMQ？
<details><summary>答案</summary>

消息丢了无所谓、订阅者必然在线、追求最低延迟与零运维：Redis pub/sub 够（典型：缓存失效通知、在线状态广播）。订阅者可能离线、消息不能丢、需要按主题路由且要消费确认/重试/死信：必须 RabbitMQ（或 Redis Streams——要持久化与确认但不想引入新组件时它是 Redis 生态内的折中）。判据就两条：离线订阅者的消息要不要补、消费失败要不要重投。
</details>

## 延伸阅读

- 官方 AMQP 0-9-1 模型（exchange/binding/queue）：https://www.rabbitmq.com/tutorials/amqp-concepts
- 官方 publisher confirm 指南：https://www.rabbitmq.com/confirms
- 官方 consumer confirm / prefetch / consumer_timeout：https://www.rabbitmq.com/consumers
- 官方 topic exchange 教程：https://www.rabbitmq.com/tutorials/tutorial-five-python
- 官方死信与 TTL：https://www.rabbitmq.com/dlx
