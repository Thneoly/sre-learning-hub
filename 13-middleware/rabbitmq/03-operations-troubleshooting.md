# 03 · RabbitMQ 运维与排障：监控、死信/延迟队列、常见坑与积压处置

> 模块：13-middleware/rabbitmq ｜ 建议时长：4 小时 ｜ 关联认证：PCA-指标与告警（PromQL 规则直接复用）；CKA-工作负载（Operator 部署与 PodMonitor 抓取）

## 学习目标

- 能启用并验证 rabbitmq_prometheus 插件，说出队列深度、发布/消费速率、连接、内存磁盘六类必看指标的含义与告警阈值依据
- 能用 queue argument 或 policy 配置 DLX，说清死信的四种触发条件与"死信被静默丢弃"的路由坑，并用 TTL + DLX 组出延迟队列
- 能按固定路径定位四类高频故障：连接泄漏、prefetch 失当、积压打爆内存、镜像队列脑裂残留；并执行配套运维操作（用户权限、队列迁移、插件、日志）
- 能按"先看 consumers 再看 ready"的顺序处置消息积压，并说明 shovel 疏散、purge 清空的适用条件与代价

本章命令在 rabbitmq:3.13-management（3.13.7）容器里逐一验证过；3.x/4.x 行为差异处均单独标注，**以官方文档为准**。

## 1. 监控：rabbitmq_prometheus 与必看指标

### 1.1 插件与抓取通道

3.8 起内置 `rabbitmq_prometheus` 插件（官方 Docker 镜像默认启用），每个节点在 **15692** 端口暴露 `/metrics`：

```bash
# [任意节点] 启用（已启用则无输出变化）并验证
rabbitmq-plugins enable rabbitmq_prometheus
rabbitmq-plugins list -e          # 列出已启用插件，应看到 rabbitmq_prometheus
curl -s http://localhost:15692/metrics | grep -E '^rabbitmq_queue_messages_ready'
```

两个抓取细节，漏掉就会"指标有了但画不出图"：**默认 `/metrics` 的队列指标是聚合值，没有 queue 标签**（控制时间序列基数），要按队列出曲线或写按队列告警必须抓 `/metrics/per-object`（给出 `rabbitmq_queue_messages_ready{vhost="/",queue="orders.q"}` 标签序列）；K8s 里 PodMonitor 要逐 Pod 抓取 headless Service 背后的 15692，漏一个节点就有盲区。

### 1.2 必看指标表（3.13 实测名称）

| 指标 | 含义 | 告警建议 | 依据 |
|---|---|---|---|
| `rabbitmq_queue_messages_ready` | 待消费消息数（积压深度） | 绝对值持续 10m 超阈值 | 消费能力不足或消费者挂了 |
| `rabbitmq_queue_messages_unack` | 已投递未确认数 | 长期高企查消费者 | prefetch 失当/处理卡死 |
| `rabbitmq_queue_consumers` | 队列存活消费者数 | 与 ready 联动：`ready>100 and consumers==0` | 消费者归零=应用挂了，比积压更急 |
| `rabbitmq_global_messages_received_total` | 发布进集群的消息计数（rate 即发布速率） | 趋势监控 | 与消费速率对比判断追平能力 |
| `rabbitmq_global_messages_delivered_total` / `..._acknowledged_total` | 投递/确认计数 | delivered 持续大于 acknowledged → unacked 堆积前兆 | 两速率差=确认缺口 |
| `rabbitmq_global_messages_redelivered_total` | 重投计数（断线、consumer_timeout） | rate > 0 持续告警 | at-least-once 的重复消费正在发生 |
| `rabbitmq_global_messages_unroutable_dropped_total` | 路由不到任何队列被**静默丢弃**的消息 | rate > 0 立即告警 | "消息莫名丢失"的量化证据 |
| `rabbitmq_global_messages_dead_lettered_expired_total`（另有 rejected/maxlen/delivery_limit） | 死信计数，按原因分解 | 核心队列死信增长告警 | 业务处理失败/超期的信号灯 |
| `rabbitmq_connections_opened_total` / `rabbitmq_connections_closed_total` | 连接建立/关闭计数 | `increase(opened[10m]) - increase(closed[10m]) > N` | 差值只增不减=连接泄漏 |
| `rabbitmq_connections` / `rabbitmq_channels` / `rabbitmq_consumers` | 当前连接/信道/消费者数（gauge） | 接近上限告警 | 容量水位 |
| `rabbitmq_memory_used_bytes` | 节点内存用量 | 趋势告警打在水位线之前 | 见 1.3 |
| `rabbitmq_alarms_memory_used_watermark` / `rabbitmq_alarms_free_disk_space_watermark` | 内存/磁盘水位告警状态（1=触发） | `== 1` 立即 critical | 触发即阻断发布，见 1.3 |
| `rabbitmq_disk_space_available_bytes` | 磁盘剩余（3.13 实际指标名；配套水位线 `rabbitmq_disk_space_available_limit_bytes`，没有 `rabbitmq_disk_free_bytes` 这个指标） | 低于水位线的 2 倍预警 | 同上 |

指标名随版本有增减（例如 channel 级计数在 channel 关闭后即消失），落地前先 `curl /metrics` 核对实际输出，以官方 Metrics 指标文档为准。

### 1.3 水位告警：阻断的是发布端

内存与磁盘两道水位线是 Broker 的自我保护：`vm_memory_high_watermark`（3.x 默认 0.4、4.x 默认 0.6，以文档为准）与 `disk_free_limit`。**触发 alarm 后阻断的是所有发布连接（state 变成 blocked），消费不受影响**——积压顶到水位的故障形态是"生产端全部超时"。

```bash
# [任意节点] 人为触发内存水位告警，观察发布端被阻断
rabbitmqctl set_vm_memory_high_watermark absolute 64MB   # 阈值压到 VM 基线之下
rabbitmq-diagnostics check_local_alarms                  # 有告警时退出码非 0，并打印告警内容
rabbitmqctl -q list_connections user state               # 发布中的连接显示 blocked
rabbitmqctl set_vm_memory_high_watermark 0.4             # 恢复（3.x 默认），alarm 自动解除
```

### 1.4 告警规则示例

```yaml
# [任意节点] Prometheus 规则文件（抓取路径需为 /metrics/per-object 才有 queue 标签）
# 积压阈值按"峰值消费速率 × 可容忍追平时间"倒推（500 条/s × 2 分钟 → 6 万）；官方 Grafana 面板 grafana.com ID 10991
groups:
- name: rabbitmq-alerts
  rules:
  - alert: RabbitMQQueueBacklog
    expr: rabbitmq_queue_messages_ready > 50000
    for: 10m
    labels: {severity: warning}
    annotations:
      summary: '队列 {{ $labels.queue }} 积压 {{ $value }} 持续 10 分钟'
  - alert: RabbitMQQueueNoConsumer
    expr: rabbitmq_queue_messages_ready > 100 and rabbitmq_queue_consumers == 0
    for: 5m
    labels: {severity: critical}
    annotations:
      summary: '队列 {{ $labels.queue }} 有积压但消费者为 0（应用挂了或被误杀）'
  - alert: RabbitMQConnectionsLeak
    expr: increase(rabbitmq_connections_opened_total[10m]) - increase(rabbitmq_connections_closed_total[10m]) > 100
    for: 10m
    labels: {severity: warning}
    annotations:
      summary: '连接净增长 {{ $value }}/10m，疑似连接泄漏'
  - alert: RabbitMQAlarm
    expr: rabbitmq_alarms_memory_used_watermark == 1 or rabbitmq_alarms_free_disk_space_watermark == 1
    labels: {severity: critical}
    annotations:
      summary: '节点 {{ $labels.node }} 触发资源水位告警，发布端已被阻断'
```

## 2. 死信队列与延迟队列

### 2.1 DLX：不过是"别的队列指向的普通交换机"

死信队列不是特殊队列类型：源队列通过参数 `x-dead-letter-exchange`（或 policy 的 `dead-letter-exchange`，运维侧不用重新声明队列即可生效，生产推荐）指向一个普通交换机，消息被死信后按路由规则进入死信队列。四种触发条件：

| 触发 | 场景 |
|---|---|
| 消费者 reject/nack 且 `requeue=false` | 业务处理失败的兜底 |
| 消息 TTL 过期（per-message expiration 或队列 x-message-ttl/policy message-ttl） | 延迟队列的基础 |
| 队列超过 `max-length` 且 overflow=drop-head | 队列自保护 |
| quorum 投递超 `x-delivery-limit` | 毒消息超次自动死信（4.x 有默认上限、3.x 需显式配，以文档为准） |

死信消息会带上 `x-death` header（reason、原队列、次数、时间）以及 `x-first-death-*`/`x-last-death-*`，排障时能直接回答"这条消息为什么死、死了几次"。

### 2.2 死信路由的坑：原 routing key 被保留

被死信的消息用**原来的 routing key**（除非配了 `dead-letter-routing-key`）重新发布到 DLX。如果 DLX 上没有对应 binding，**死信被静默丢弃，不报错**——这是"DLX 配了但没有死信"的头号原因：

```
orders.wait（TTL 3s，DLX=orders.dlx）
   │ 消息以 routing_key = "orders.wait" 发布进来 → 3 秒后过期
   │ 以原 key "orders.wait" republish 到 orders.dlx
   ▼
orders.dlx 上只有 binding key = "order.new" 的绑定 → 匹配失败 → 消息静默丢弃
   解法：policy 加 "dead-letter-routing-key":"order.new"，或给 DLX 补一条同 key 的 binding
```

```bash
# [任意节点] policy 三件套：TTL + DLX + 重写路由 key（本组命令在 3.13 实测通过）
rabbitmqadmin -u app -p app-secret declare exchange name=orders.dlx type=direct durable=true
rabbitmqadmin -u app -p app-secret declare queue name=orders.dead durable=true
rabbitmqadmin -u app -p app-secret declare queue name=orders.wait durable=true
rabbitmqadmin -u app -p app-secret declare binding source=orders.dlx destination=orders.dead routing_key=order.new
rabbitmqctl set_policy --apply-to queues dlx-wait '^orders\.wait$' \
  '{"message-ttl":3000,"dead-letter-exchange":"orders.dlx","dead-letter-routing-key":"order.new"}'
# 验证死信与 x-death（ackmode=ack_requeue_true = 取出后塞回，不破坏现场）
rabbitmqadmin -u app -p app-secret -f pretty_json get queue=orders.dead count=1 ackmode=ack_requeue_true
```

### 2.3 延迟队列：TTL + DLX 组合

```
Producer ──► orders.wait（message-ttl=30s，DLX=orders.dlx）
                  │ 消息在队列里"躺" 30 秒，无人消费
                  ▼ 过期死信
             orders.dlx ──► orders.dead ──► 延迟任务的消费者（如"下单 30 分钟未支付自动取消"）
```

队头阻塞坑：**per-message TTL（发布时带 expiration）的消息只从队头过期**——一条 TTL 10s 的消息排在一条 TTL 60s 的消息后面，要等 60s 那条先出队才会轮到它。需要精确延迟的场景要么用队列级 TTL（每档延迟一个队列），要么用官方社区插件 rabbitmq_delayed_message_exchange（延迟存内存，大流量下有容量代价，以官方插件文档为准）。

### 2.4 语义对比：RabbitMQ vs Kafka vs Redis pub/sub

| 维度 | RabbitMQ | Kafka（14-data-streaming/kafka） | Redis PUBLISH/SUBSCRIBE（13-middleware/redis） |
|---|---|---|---|
| 投递语义 | at-least-once：unacked 的消息在连接断开后**重投**（redelivered 标志） | 取决于位移提交时序：先处理后提交 ≈ at-least-once，自动提交有丢失窗口（第 2 章第 8 节） | 尽力而为：订阅者离线即丢，接近 at-most-once |
| 消息留存 | 消费 ack 即删，队列只是缓冲 | retention 内全量留存，可回放重放 | 不留存 |
| 消费模型 | Broker **push**，prefetch 限流 | 消费者 **pull** + max.poll.records | push，无流控无确认 |
| 死信 | DLX 原生，x-death 带原因 | 无内建，业务自己写死信 topic | 无 |
| 去重 | 业务幂等键（重投必然发生） | 业务幂等键（或事务 producer/EOS） | 无从谈起 |

选型直觉：任务分发、需要按消息 ack/拒绝、消息消费完就该删 → RabbitMQ；高吞吐流式、要回放、多消费者组各自独立进度 → Kafka；进程间即时通知、丢一条无所谓 → Redis pub/sub。

## 3. 四类高频故障的定位与修复

### 3.1 连接泄漏（未 close channel）

一条 TCP 连接可复用多个 channel，正确姿势是长生命周期连接 + 按需开关 channel。泄漏多半来自框架层每请求新建连接、异常分支不关闭。定位：

```bash
# [任意节点] 看 peer 地址与信道数：同一客户端 IP 的连接是否只增不减
rabbitmqctl -q list_connections user peer_host channels state
rabbitmqctl -q list_channels connection number consumer_count messages_unacknowledged
# Prometheus 净增长持续为正即泄漏（1.4 的 ConnectionsLeak 规则）
```

修复推动业务改连接池；运维侧兜底用 `user_limits` 给用户限 `max-connections`（以文档为准）。

### 3.2 prefetch 失当与 unacked 堆积

prefetch 不设置时默认**无限**：Broker 把整个队列一口气推给消费者，unacked 全部记在 Broker 内存里，消费者自己也被撑爆。经验值：单条处理 10ms 级的业务从 10~100 起步，按 consumer utilization 调优。另一个隐形杀手是 `consumer_timeout`（3.8.15+ 默认 30 分钟）：unacked 持有超过该时长，Broker 直接关闭 channel（PRECONDITION_FAILED），消息全部重投——"处理超过 30 分钟的慢任务"会周期性炸 channel，需调大配置或拆分任务。unacked 卡死的量化指标就是 `rabbitmq_queue_messages_unack` 长期高企。

### 3.3 消息堆积打爆内存

队列无限长 + 无 TTL + 消费端停摆 → 积压顶到 `vm_memory_high_watermark` → alarm 阻断**所有**发布连接（见 1.3），故障从"一条队列积压"升级为"全集群发布不可用"。防线按优先级：给消费者挂掉配 `NoConsumer` 告警（恢复窗口从这里抢）；队列配 `max-length` + overflow（drop-head 丢老消息，reject-publish 反压生产端）；按业务设 message-ttl；内存趋势告警必须打在水位线**之前**。classic 队列会把非驻留消息页出（page out）到磁盘缓解内存，但治本仍是消费追平或扩容磁盘。

### 3.4 镜像队列脑裂残留

经典镜像队列（ha-mode）从 3.9 起废弃、**4.0 彻底移除**。它的病根：异步复制 + 网络分区时若 `cluster_partition_handling` 配了 `ignore`（老默认），分区两侧各自接受写，恢复后数据不一致，残留表现为：不同步的 slave（synchronised 副本缺失）、队列数据与 master 对不上、甚至"幽灵队列"（一侧删除另一侧仍在）。处置顺序：`rabbitmqctl cluster_status` 看 partitions 是否为空 → 残留队列排水后删除重建 → 迁移到 quorum 队列（Raft 多数派，天然杜绝分区双写）→ 新集群固定配 `cluster_partition_handling = pause_minority`。队列类型创建后不可原地改，迁移路径见 4.2。

## 4. 日常运维操作

### 4.1 用户、vhost 与权限

```bash
# [任意节点] 多业务共用集群：vhost 划边界 + 专用账号 + 最小权限
rabbitmqctl add_vhost orders
rabbitmqctl add_user app 'app-secret'
rabbitmqctl set_user_tags app management                # 管理界面只读权限
# configure/write/read 三列都是正则，作用于队列与交换机的名字空间
rabbitmqctl set_permissions -p orders app '^orders\.' '^orders\.' '^orders\.'
```

guest 账号的两个例外必须知道：**裸机/包安装默认 guest 只能从 localhost 登录**（loopback 限制）；而**官方 Docker 镜像的默认配置 `conf.d/10-defaults.conf` 里写了 `loopback_users.guest = false`，guest 可以从任意网络登录**——容器里"guest 怎么哪都能连"不是错觉，是镜像放开限制。生产两步走：要么 `RABBITMQ_DEFAULT_USER` 直接建专用号（此时 guest 不会被创建），要么起来后立即删除 guest。

### 4.2 队列迁移（classic → quorum）

队列类型不可原地修改，迁移固定四步：声明新类型队列 → 搬数据 → 切路由 → 删旧队列。搬数据用 **dynamic shovel**（无需停机，源队列排空即追平）：

```bash
# [任意节点] 启用插件并声明一条 shovel：把 orders.q 搬到 orders.q.new（3.13 实测通过）
rabbitmq-plugins enable rabbitmq_shovel rabbitmq_shovel_management
rabbitmqctl set_parameter shovel migrate-orders \
  '{"src-protocol":"amqp091","src-uri":"amqp://app:app-secret@localhost:5672/%2F","src-queue":"orders.q",
    "dest-protocol":"amqp091","dest-uri":"amqp://app:app-secret@localhost:5672/%2F","dest-queue":"orders.q.new"}'
curl -s -u app:app-secret http://localhost:15672/api/shovels    # 查看 shovel 状态
rabbitmqctl clear_parameter shovel migrate-orders              # 排空后拆除
```

URI 里 vhost `/` 必须写成 `%2F`。迁移期双写或短暂停发布由业务定，切换后观察旧队列 ready 恒为 0 再删除。

### 4.3 插件管理

```bash
# [任意节点] 常用命令；--offline 用于节点未启动时改 enabled_plugins 文件
rabbitmq-plugins list -e                    # 已启用的
rabbitmq-plugins enable rabbitmq_shovel     # 在线启用
```

常用插件：`rabbitmq_management`（Web UI/HTTP API）、`rabbitmq_prometheus`（监控）、`rabbitmq_shovel`(+`_management`)（搬迁）、`rabbitmq_top`（Erlang 进程级 CPU/内存，定位 Broker 内部瓶颈）。Docker 里启用状态写在容器文件系统，容器重建即丢——持久化要挂载 `/etc/rabbitmq` 或用 K8s Operator 的 `additionalPlugins`。

### 4.4 日志与健康检查

```bash
# [任意节点] 容器场景日志走 stdout：docker logs rabbit-lab | grep -iE 'error|closed|missed'
# 裸机日志文件在 /var/log/rabbitmq/<node>.log；3.9+ 用配置项 log.console / log.file.level（以文档为准）
docker logs rabbit-lab 2>&1 | grep -E 'Missed heartbeats|PRECONDITION_FAILED|operation basic' | tail -5
# 健康检查（K8s 探针同款，非 0 退出码即不健康）
rabbitmq-diagnostics check_running             # 节点进程活着
rabbitmq-diagnostics check_port_connectivity   # 5672 可连
rabbitmq-diagnostics check_local_alarms        # 无资源告警（有 alarm 时退出码非 0）
```

日志里最该 grep 的三类：`Missed heartbeats from client`（客户端假死/网络抖动，连接被服务端关）、`PRECONDITION_FAILED ... consumer_timeout`（3.2 节的慢消费者超时）、`closing AMQP connection`（配合连接 churn 判断泄漏还是正常发布）。

## 5. 消息积压处置：三板斧与决策顺序

```
rabbitmq_queue_messages_ready 告警
   │
   ├─ consumers == 0？ ──► 应用挂了/被误杀：先恢复消费者（重启/回滚发布），再谈别的   ← 最急
   │
   ├─ consumers > 0 且 unack 高？ ──► 消费卡死：查 prefetch、consumer_timeout、下游依赖（DB/Redis 慢）
   │
   └─ consumers > 0 且在正常 ack，只是慢？ ──► 按序选择：
        ① 扩容消费者：加实例/加消费线程；同一队列的消费者是竞争消费，并行度≈消费者数×prefetch，
           若瓶颈在"队列数"本身，用 shovel 或 consistent hash exchange 拆队列
        ② shovel 疏散：搬到另一集群/另一组队列（4.2 同款命令），适合本集群接近水位或要分流
        ③ purge 清空：rabbitmqctl purge_queue —— 最后手段；只清 ready 清不掉 unacked，
           消息还有价值就先 shovel 到归档队列再 purge，删消息永远是最下策
```

处置口诀：**先看 consumers 再看 ready；恢复消费优先于清理消息；purge 之前先归档**。

## 实战演练

环境：装有 Docker 的 Ubuntu VM（`[任意节点]`）。三个演练：水位告警阻断发布、purge 与 unacked 的边界、shovel 排水。

```bash
# [任意节点] 起环境：broker + 客户端 + 专用账号 + 拓扑
docker network create rmq-ops-net
docker run -d --name rabbit-ops --network rmq-ops-net --hostname rabbit-ops \
  -p 15672:15672 -p 15692:15692 rabbitmq:3.13-management
docker run -d --name rmq-client --network rmq-ops-net python:3.12-slim sleep infinity
sleep 25 && docker exec rabbit-ops rabbitmq-diagnostics check_running
docker exec rabbit-ops rabbitmqctl add_user ops ops-secret
docker exec rabbit-ops rabbitmqctl set_permissions -p / ops '.*' '.*' '.*'
docker exec rabbit-ops rabbitmqadmin -u ops -p ops-secret declare exchange name=drill.ex type=direct durable=true
docker exec rabbit-ops rabbitmqadmin -u ops -p ops-secret declare queue name=drill.q durable=true
docker exec rabbit-ops rabbitmqadmin -u ops -p ops-secret declare binding source=drill.ex destination=drill.q routing_key=drill
docker exec rmq-client pip install -q pika==1.3.2
```

```bash
# [任意节点] 演练 1：内存水位告警阻断发布端
docker exec rabbit-ops rabbitmqctl set_vm_memory_high_watermark absolute 64MB
sleep 3
docker exec rabbit-ops rabbitmq-diagnostics check_local_alarms   # 预期: Memory alarm ...，退出码非 0
docker exec rabbit-ops rabbitmqadmin -u ops -p ops-secret publish exchange=drill.ex routing_key=drill payload=x &
sleep 4
docker exec rabbit-ops rabbitmqctl -q list_connections user state   # 预期: 该发布连接 state=blocked
docker exec rabbit-ops rabbitmqctl set_vm_memory_high_watermark 0.4   # 恢复后 alarm 自动解除（等几秒）
```

```bash
# [任意节点] 演练 2：purge 只清 ready，清不掉 unacked
docker exec rabbit-ops sh -c \
  'for i in $(seq 1 50); do rabbitmqadmin -u ops -p ops-secret publish exchange=drill.ex routing_key=drill payload=m$i >/dev/null; done'
docker exec rmq-client sh -c 'cat > /tmp/hold.py <<EOF
import time, pika
p = pika.ConnectionParameters(host="rabbit-ops", credentials=pika.PlainCredentials("ops", "ops-secret"))
ch = pika.BlockingConnection(p).channel()
[ch.basic_get("drill.q", auto_ack=False) for _ in range(20)]   # 取走 20 条不 ack
print("HELD=20"); time.sleep(120)
EOF
nohup python /tmp/hold.py >/tmp/hold.log 2>&1 & echo $! > /tmp/hold.pid'
sleep 3
docker exec rabbit-ops rabbitmqctl -q list_queues name messages_ready messages_unacknowledged | grep drill.q
# 预期: ready 30  unacked 20
docker exec rabbit-ops rabbitmqctl purge_queue drill.q
docker exec rabbit-ops rabbitmqctl -q list_queues name messages_ready messages_unacknowledged | grep drill.q
# 预期: ready 0  unacked 20 —— purge 动不了 unacked
docker exec rmq-client sh -c 'kill $(cat /tmp/hold.pid)'   # kill 是 sh 内建，slim 镜像没有 kill 二进制
sleep 2
docker exec rabbit-ops rabbitmqctl -q list_queues name messages_ready messages_unacknowledged | grep drill.q
# 预期: ready 20  unacked 0 —— 连接断开，unacked 全部重投回队列
```

```bash
# [任意节点] 演练 3：shovel 排水（把 drill.q 清到新队列）+ 指标验证
docker exec rabbit-ops rabbitmqadmin -u ops -p ops-secret declare queue name=drill.archive durable=true
docker exec rabbit-ops rabbitmq-plugins enable rabbitmq_shovel rabbitmq_shovel_management
docker exec rabbit-ops rabbitmqctl set_parameter shovel drain-drill \
  '{"src-protocol":"amqp091","src-uri":"amqp://ops:ops-secret@localhost:5672/%2F","src-queue":"drill.q",
    "dest-protocol":"amqp091","dest-uri":"amqp://ops:ops-secret@localhost:5672/%2F","dest-queue":"drill.archive"}'
sleep 8
docker exec rabbit-ops rabbitmqctl -q list_queues name messages_ready | grep drill
# 预期: drill.q 0，drill.archive 20
docker exec rabbit-ops rabbitmqctl clear_parameter shovel drain-drill
curl -s http://localhost:15692/metrics/per-object | grep 'rabbitmq_queue_messages_ready{vhost="/",queue="drill.archive"}'
# 预期: drill.archive 20 —— per-object 指标带队列标签
```

验证方法：演练 1 里 blocked 状态与 alarm 退出码互相印证；演练 2 的三个数字（30/20 → 0/20 → 20/0）就是 purge 语义的完整证据链；演练 3 以 drill.q 排空对照 /metrics/per-object 的标签序列。清理：`docker rm -f rabbit-ops rmq-client && docker network rm rmq-ops-net`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| DLX 配了但死信队列是空的 | 死信保留原 routing key，DLX 上无匹配 binding 被静默丢弃 | policy 加 dead-letter-routing-key 或补 binding；先跑 2.2 的验证命令 |
| 连接数只涨不跌 | 每请求新建连接/channel，异常分支不关闭 | 业务改连接池；churn 差值告警；user_limits 限连接数 |
| 消费者内存暴涨、unacked 巨大 | prefetch 未设置（默认无限），消息被一口气推下来 | basic_qos 设 10~100，盯 messages_unack |
| 消费者每隔约 30 分钟炸一次 channel | unacked 持有超 consumer_timeout（默认 30 分钟） | 调大 consumer_timeout 或拆分长任务，日志 grep PRECONDITION_FAILED |
| 消息莫名丢失 | 路由不到队列被默认丢弃，或开了 autoAck | mandatory + 备份交换机；关 autoAck；盯 unroutable_dropped 指标 |
| 延迟消息比设定晚很多才触发 | per-message TTL 队头阻塞：前面的长 TTL 挡住后面的短 TTL | 队列级 TTL 分档建队列，或 delayed_message_exchange 插件 |
| 网络分区后队列数据不一致 | 经典镜像队列 + ignore 分区策略的双写残留 | pause_minority；排水删除重建为 quorum 队列 |
| Broker 内存报警、全站发布超时 | 积压顶到 vm_memory_high_watermark，alarm 阻断发布连接 | 恢复/扩容消费者；队列配 max-length + TTL；趋势告警前移 |

## 自测

1. 内存水位告警触发后，为什么"消费还能继续、发布全挂"？这个设计保护了什么？
<details><summary>答案</summary>

水位告警的目的是阻止内存继续增长，而积压的来源是发布端，消费端恰恰在帮 Broker 减负（ack 后消息删除），所以阻断发布连接、放行消费是让水位回落的最快路径——把"Broker OOM 崩溃"降级为"发布端超时"，用可用性换存活。运维要点：这种故障的表现不在 RabbitMQ 指标里，而在生产端业务报错里，所以要配 `rabbitmq_alarms_memory_used_watermark == 1` 的前置告警，而不是等业务先喊。
</details>

2. prefetch=0（不设置）和 prefetch=10 各自的场景？如果把一个 10ms 消费一条的消费者 prefetch 设成 10000 会怎样？
<details><summary>答案</summary>

不设置=无限：Broker 把队列现有消息全部推下来，unacked 记在 Broker 内存，消费者本地也缓存全部消息——只有"队列永远很短、消息极小"才可接受。prefetch=10：任意时刻最多 10 条在途，吞吐换内存安全。设成 10000：内存风险回来了，而且第一个消费者会囤走一大波消息、后加的消费者闲着，扩容收敛变慢。经验值从"单条处理耗时 × 目标吞吐"倒推，10~100 起步再看 consumer utilization。
</details>

3. purge_queue 之后队列消息数不是 0，你可能看到了什么？怎么解释？
<details><summary>答案</summary>

purge 只清除 ready 消息；unacked 属于"已投递、在等 ack"，purge 动不了，持有者断开后还会**重投回 ready**。所以 purge 后看到 unacked 不为 0、或过一会儿 ready 又涨回来，都是这个语义。想彻底清空必须先停消费者（断开连接让 unacked 重投），再 purge。
</details>

4. 为什么"死信队列堆积"本身也要配告警和 max-length？两层兜底各自防什么？
<details><summary>答案</summary>

死信队列是业务异常的汇聚点：正常时近似空，开始堆积说明有消息在反复处理失败（代码 bug、下游故障、毒消息），需要人工介入，所以要单独告警。但它自己也可能被异常流量灌爆（上游 bug 导致百万消息全部 reject），所以要配 max-length 防膨胀——注意 overflow=drop-head 丢的恰恰是"留给人工排查的证据"，因此要么配 reject-publish 反压，要么再挂一层 DLX 链式归档，把"防膨胀"与"保证据"分开。两层兜底：告警防"没人知道出事了"，max-length 防"知道出事之前 Broker 先死"。
</details>

5. 同样是"消费到一半进程挂了"，RabbitMQ 和 Kafka 恢复后各自会发生什么？
<details><summary>答案</summary>

RabbitMQ：连接断开后所有 unacked 消息立即重投（可能给其他消费者），at-least-once，业务必须幂等（redelivered 标志、x-death 的 count 可辅助识别）。Kafka：位移只有提交过才前移，没提交的部分下次 poll 重新读出，重复窗口取决于提交策略（见 14-data-streaming/kafka 第 2 章第 8 节）。差别在"确认的载体"：RabbitMQ 逐条 ack（Broker 推、等确认），Kafka 批量位移提交（消费者自己拉、自己管进度）；前者的重复是即时逐条的，后者是整段回放的。
</details>

## 延伸阅读

- 官方 Prometheus 插件与指标清单：https://www.rabbitmq.com/docs/prometheus
- 官方死信文档（DLX 触发条件与 x-death）：https://www.rabbitmq.com/docs/dlx
- 官方 TTL 文档（队头过期语义）：https://www.rabbitmq.com/docs/ttl
- 官方 shovel 插件：https://www.rabbitmq.com/docs/shovel
- 官方生产检查清单（水位线/guest/分区处理）：https://www.rabbitmq.com/docs/production-checklist
