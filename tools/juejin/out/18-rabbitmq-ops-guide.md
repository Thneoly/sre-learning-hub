---
title_juejin: RabbitMQ 运维入门：从 AMQP 模型到仲裁队列高可用
title_zhihu: RabbitMQ 运维入门：从 AMQP 模型到仲裁队列高可用
description: AMQP四层模型/四种交换机/仲裁队列Raft高可用/4.x监控大坑（默认只有聚合指标）/死信队列。含可直接抄走的告警规则。
category_id: "6809637769959178254"
tags: "后端,架构"
---

# 凌晨两点，八百万条消息积压：RabbitMQ 生产环境运维避坑指南

凌晨两点被电话叫醒：订单服务全线超时，排查发现一条队列积压了八百万条消息，Broker 内存水位报警，直接阻断了所有生产端连接。

更扎心的是，Grafana 上的队列深度曲线三天前就越过了红线——那条红线是复盘时才画上去的，当时根本没人给这条曲线配过告警，更没人知道它意味着什么。

这篇文章就是为了让下一次告警响起来时，你知道先看哪个指标、先动哪台机器。全文按模型、确认、高可用、监控四块推进，最后附一张可以直接抄走的速查表；默认你已有 K8s/Docker 基础，全文站在 K8s 时代运维工程师的视角。

## 一、AMQP 模型：消息从来不直接进队列

那晚的八百万条消息，为什么会安安静静堆在一条队列里？回答这个问题，得先搞清楚消息是怎么进队列的。RabbitMQ 实现的是 AMQP 0-9-1 协议，很多同学接手的方式是"先把服务跑起来，出事再补模型知识"，这条路径最容易翻车，因为排查路由问题全靠对模型的理解。

消息流转分四层：Producer → Exchange → Binding → Queue → Consumer。生产者永远不直接把消息投给队列，这是它和 Kafka 心智模型最大的差别——Kafka 生产者按分区器写分区日志、消费者自己拉位点；RabbitMQ 由交换机按 binding 规则推送给消费者，路由这件事 Broker 替你做了。

`Exchange` 是路由器，接收生产者发来的消息；`Binding` 是交换机与队列之间的绑定关系，附带 routing key；`Queue` 是真正落地存消息的缓冲区；`Consumer` 从队列消费。

```text
Producer --(routing key)--> Exchange --(binding)--> Queue --> Consumer
```

一句话总结：**消息能不能进队列，取决于交换机类型加绑定规则，而不是队列本身**。

关键认知：如果消息路由不到任何队列，Broker 默认直接丢弃，不报错、不留痕，这就是"消息莫名丢了"的头号根因。用 `mandatory` 标志配合 Return 回调，或给交换机配 alternate exchange 兜底，可以把这类无声丢弃拦下来。

运维视角的第二个要点：队列是"有名字、可枚举、可独立配置参数"的资源，所以队列数量、队列类型、队列参数都是巡检对象，后面监控部分会反复用到。

顺带说一句 vhost：它是逻辑隔离单元，队列、交换机、权限都挂在 vhost 下面。多业务共用一套集群时，用 vhost 划边界，比全挤在默认虚拟主机里清爽得多，权限管理也干净。

## 二、四种交换机：一张表选型

交换机类型决定路由算法，四种官方类型各有明确场景，**选型错了，后面全是补丁**。

| 类型 | 路由规则 | 典型场景 |
|---|---|---|
| direct | routing key 与 binding key 完全相等 | 点对点任务分发 |
| fanout | 广播到所有绑定队列，忽略 key | 一份事件多方订阅（通知、审计） |
| topic | 通配符匹配：`*` 一个词，`#` 零到多个词 | 按主题订阅，如 `order.*` |
| headers | 按消息 header 匹配，`x-match=all/any` | 复杂路由且不想污染 routing key |

direct 里有个特殊角色叫默认交换机：名字是空字符串，每个队列自动与它绑定，binding key 等于队列名，所以看起来像"直接投给队列"，本质只是走了一条内置路由。

topic 是业务上最常用的：`order.*` 能匹配 `order.created` 和 `order.paid`，`#.error` 匹配所有错误事件。注意通配符按"点分单词"匹配，`order.created.v2` 里的 `*` 只吃掉一个词。

headers 交换机少见，多存在于遗留系统：匹配完全绕开 routing key，只看 header 键值对，性能也比前三种差，新设计不建议选。

用 curl 走 HTTP API 声明交换机，比点管理界面更适合固化进 Ansible 或 CI 流水线：

```bash
curl -u admin:$PASS -X PUT http://mq:15672/api/exchanges/%2F/order.events \
  -H "content-type: application/json" \
  -d '{"type":"topic","durable":true}'
```

其中 `%2F` 是默认虚拟主机 `/` 的 URL 编码，这个细节写脚本时最容易漏。

## 三、消息确认：ack 不是走个流程

消息可靠性靠两端确认：生产者侧叫 publisher confirm，保证消息被 Broker 收到；消费者侧叫 ack，保证消息被业务处理完。**只做一边，可靠性就是纸糊的**。

顺带澄清一个高频误区：`durable=true` 只保证队列元数据在 Broker 重启后还在，消息本身要落盘，还得发布端把 delivery mode 设为 `persistent`，两个开关缺一不可。但"缺一不可"不等于"都开了就不丢"：`persistent` 消息是异步刷盘，Broker 宕机时仍可能丢掉最近一段；要接近不丢，得靠第四节的仲裁队列加 publisher confirm。

消费者有三种应答：`basicAck` 表示处理成功；`basicNack` 可否定一批消息，`requeue=true` 会塞回队列重新投递；`basicReject` 否定单条。`requeue=true` 要小心：消息若是"毒药"（一解析就抛异常），会陷入投递、崩溃、再投递的死循环——4.x 起仲裁队列默认投递上限 20 次、超次自动死信，算是兜底；3.x 没有这个默认，真会无限循环。

更稳的做法不是把失败一刀切，而是按错误类型分流：可重试错误（超时、下游抖动）reject/nack 时 `requeue=true` 塞回重投，由仲裁队列的 `x-delivery-limit`（见第四节）超次自动死信兜底；不可重试错误（格式非法、业务校验不过）直接 `requeue=false` 进死信队列，一次重试都不浪费。

`autoAck`（自动确认）是丢消息的经典开关：Broker 把消息推给消费者就删除，业务还没处理完进程就挂了，消息无法找回。除非是可容忍丢失的日志类消息，否则别开。

`prefetch` 是配合 ack 的限流阀门：限制单个消费者同时持有的未确认消息数，处理完一条补一条。不设置的默认值是"无限"，消费者内存会被瞬间推来的消息撑爆——那晚挂掉的消费者 Pod，多半就栽在这个默认值上。这是第二个经典翻车点。

经验值：单条消息处理耗时 10ms 级的业务，`prefetch` 从 10~100 起步，再按 consumer utilization 调优。以 Python 的 pika 为例：

```python
channel.basic_qos(prefetch_count=50)

def on_message(ch, method, props, body):
    try:
        process(body)                                # 业务处理
        ch.basic_ack(method.delivery_tag)            # 成功确认
    except RetryableError:
        # 可重试错误，塞回重投。前提：队列是配了 x-delivery-limit 的
        # 仲裁队列（见第四节），classic 队列这么写会复现上面的死循环
        ch.basic_nack(method.delivery_tag, requeue=True)
    except Exception:
        ch.basic_reject(method.delivery_tag, requeue=False) # 直接种死信
```

生产者侧打开 confirm 模式后，还要处理 broker nack 和路由失败两种回调，缺一个就有缝隙。巡检时用这条命令看每个队列的积压与消费状态：

```bash
rabbitmqctl list_queues name type messages_ready \
  messages_unacknowledged consumers
```

## 四、高可用：镜像队列已死，仲裁队列当立

先说结论：**经典镜像队列（`ha-mode` 那套策略）从 3.9 起废弃，4.0 彻底移除**。如果你的集群还在跑镜像队列，升级路径必须排进计划。版本口径在此统一：本文按 4.x 行为描述，涉及 3.x 差异的地方单独标注。

镜像队列的病根是主从异步复制加手工重同步，网络分区时容易脑裂和数据不一致，大队列重同步还会长时间阻塞服务。替代品是仲裁队列（Quorum Queue）：基于 Raft 共识，写入要过半数节点确认才算成功，天然规避脑裂场景下的数据丢失，主节点故障自动选主，不需要人工裁决。

代价是 Raft 日志要落盘、对磁盘延迟敏感，生产环境建议 SSD，副本数保持奇数（3 或 5），默认就是 3。

声明一个仲裁队列，顺手挂上死信交换机和投递上限：

```bash
curl -u admin:$PASS -X PUT http://mq:15672/api/queues/%2F/order.create \
  -H "content-type: application/json" \
  -d '{"durable":true,
       "arguments":{
         "x-queue-type":"quorum",
         "x-dead-letter-exchange":"order.dlx",
         "x-delivery-limit":5}}'
```

队列类型创建后不可更改，经典迁仲裁要建新队列再用 Shovel 插件或双写搬数据，没有原地切换这条路。另一个容易想当然的点：4.x 允许给虚拟主机（或节点级）配置默认队列类型，但未配置时默认仍是 classic——不声明 `x-queue-type` 直接建队列，会静默拿到 classic 队列，和"核心队列全部 quorum"的整改目标正好打架。要让新建即 quorum，要么显式设置 `default_queue_type`（节点级，3.13.3+ 支持），要么建 vhost 时指定默认类型，要么逐队列声明 `x-queue-type`，别赌默认值。

K8s 上部署推荐官方 RabbitMQ Cluster Operator，StatefulSet、持久卷、节点发现、滚动升级全部托管，几行 CRD 拉起三节点集群：

```yaml
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: mq-prod
spec:
  replicas: 3
  resources:
    requests: {cpu: "1", memory: 2Gi}
    limits:   {cpu: "2", memory: 4Gi}
  rabbitmq:
    additionalConfig: |
      # 3.x 默认 0.4、4.x 默认 0.6：显式写出可避免跨版本漂移，
      # 但在 3.x 上这是上调水位线，内存趋势告警要同步前移
      vm_memory_high_watermark.relative = 0.6
      disk_free_limit.absolute = 2GB
```

K8s 侧两个保命配置：反亲和把三个副本摊到不同宿主机，否则单机一挂直接丢仲裁；配 PodDisruptionBudget 至少保住两个副本，防止节点排水时运维自己把集群搞残。

另外在配置里加 `cluster_partition_handling = pause_minority`：真的发生网络分区时，少数派自动暂停而不是继续服务，从机制上杜绝分区两边都继续对外提供服务造成的双活撕裂。

## 五、死信队列：给消息一个体面的退场

死信队列不是特殊的队列类型，它就是普通队列，只不过别的队列把 `x-dead-letter-exchange` 指向了它的入口。消息被死信后，header 里会带上 `x-death`，记录死亡原因、时间和来源队列，排查时非常有用。

触发死信的几种情况：消费者 reject/nack 且 `requeue=false`；消息 TTL 到期；队列超过 `max-length`；仲裁队列里投递次数超过 `x-delivery-limit`。

运维视角下，**死信队列是业务异常的信号灯**：它开始堆积，说明有消息在反复处理失败。核心业务的死信队列必须单独配告警，并设置足够长的 TTL 供人工排查，同时加 `max-length` 防止它自己无限膨胀——但要清楚这两个是有损兜底：TTL 到期和 `max-length` 默认的 `overflow=drop-head` 都会静默丢消息，丢的恰恰是你留给人工排查的证据。要防膨胀又不毁证据，给死信队列配 `overflow=reject-publish`（注意：它只对带 confirm 的客户端发布者有反压意义；死信转入是 broker 内部转发，不走 publisher confirm，挡不住死信洪峰本身），或让它再挂一层 DLX 链式死信、定期归档落地，并且堆积告警要打在触达上限之前。

验证死信链路是否配通，看绑定关系最快：

```bash
rabbitmqctl list_bindings source_name destination_name routing_key
```

确认源队列的死信交换机上确实挂了到死信队列的 binding，这条链路才算闭环。

## 六、监控：Prometheus 插件与积压告警

RabbitMQ 3.8 起内置 `rabbitmq_prometheus` 插件，每个节点在 15692 端口暴露 `/metrics`。K8s 里用 PodMonitor 或 ServiceMonitor 逐节点抓取——headless service 背后的每个 Pod 都要抓到，漏一个节点监控就有盲区。

启用插件并快速验证指标输出：

```bash
rabbitmq-plugins enable rabbitmq_prometheus
curl -s localhost:15692/metrics/per-object | grep rabbitmq_queue_messages_ready
```

**关键坑：4.x 默认 `/metrics` 只有聚合指标**。插件配置项 `prometheus.return_per_object_metrics` 默认为 `false`，默认 `/metrics` 端点里不存在 `rabbitmq_queue_messages_ready` 这类 per-queue 序列——上一条命令若抓不到任何输出，多半不是插件坏了，而是抓错了端点。两条路二选一：把抓取路径指向 `/metrics/per-object`（本文采用，指标名保持不变），或在 `rabbitmq.conf` 里设置 `prometheus.return_per_object_metrics = true` 让 `/metrics` 直接输出 per-object 序列。下文统一按 `/metrics/per-object` 口径：K8s 里 PodMonitor/ServiceMonitor 的 `path` 字段必须显式写 `/metrics/per-object`，沿用默认 `/metrics` 的话，下面的告警规则一条都不会触发。

指标名随版本可能有增减，具体以你所用版本的实际输出和官方文档为准。开头那条三天没人看懂的曲线，就是下面第一行的 `rabbitmq_queue_messages_ready`。运维最该盯的核心指标如下表：

| 指标 | 含义 | 告警建议 |
|---|---|---|
| `rabbitmq_queue_messages_ready` | 待消费消息数（积压） | 超阈值持续 10 分钟 |
| `rabbitmq_queue_messages_unacknowledged` | 已投递未确认 | 长期高企查消费者 |
| `rabbitmq_queue_consumers` | 存活消费者数 | 积压时为 0 立即报警 |
| `rabbitmq_connections_opened_total` / `closed_total` | 连接建立/关闭计数 | 差值持续增长即泄漏 |
| `rabbitmq_memory_used_bytes` | 节点内存用量 | 接近水位线提前预警 |
| `rabbitmq_disk_free_bytes` | 磁盘剩余空间 | 低于 `disk_free_limit` 报警 |

积压阈值没有万能值，用业务峰值消费速率乘以可容忍的追平时间倒推。两条最实用的告警规则，PrometheusRule 直接抄走：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: rabbitmq-queue
spec:
  groups:
    - name: rabbitmq.queue
      rules:
        # 前提：抓取端点必须是 /metrics/per-object（PodMonitor/ServiceMonitor
        # 的 path 字段），默认 /metrics 只有聚合指标、无 per-queue 序列
        - alert: RabbitMQQueueBacklog
          expr: rabbitmq_queue_messages_ready > 50000
          for: 10m
          labels: {severity: warning}
          annotations:
            summary: "队列 {{ $labels.queue }} 积压超过 5 万"
            description: "队列 {{ $labels.queue }} 的 ready 消息 {{ $value }} 已持续 10 分钟超过 50000，按速查表处置。"
        # 同样依赖 /metrics/per-object 端点（PodMonitor/ServiceMonitor 的
        # path 字段），默认 /metrics 抓不到 per-queue 序列，此规则不会触发
        - alert: RabbitMQQueueNoConsumer
          expr: rabbitmq_queue_messages_ready > 100 and rabbitmq_queue_consumers == 0
          for: 5m
          labels: {severity: critical}
          annotations:
            summary: "队列 {{ $labels.queue }} 有积压但无消费者"
            description: "队列 {{ $labels.queue }} 积压 {{ $value }} 且 consumers 为 0 已持续 5 分钟，大概率应用挂了或被误杀。"
```

第二条往往比第一条更要命：有积压但消费者还在跑，说明消费慢；**消费者直接归零，说明应用挂了或被误杀**，恢复窗口从这里开始抢。

还要理解一个"反直觉"行为：内存或磁盘水位触发的 alarm 会阻断所有发布连接——这是保护机制不是 bug，那晚订单全线超时的直接原因就是它。所以内存趋势告警必须打在水位线之前，别等报警了才发现队列在裸奔。

不想从零画面板的话，官方提供了现成的 Grafana Dashboard（如 RabbitMQ-Overview，ID 10991），导入后对上 Prometheus 数据源即用，再按业务裁剪。

## 七、常见坑速查表

回到开头那次凌晨两点——按表处置就是：先看 `consumers` 是不是归零，再决定限流入口还是扩容消费端，**删消息永远是最下策**，真要删，先备份到别处。

表格之前补一个和连接泄漏有关的模型点：一条 TCP 连接上可以复用多个 channel，正确姿势是应用长生命周期持有少量连接、channel 按需开关，连接泄漏多半是框架层每请求新建连接、异常分支又不关闭造成的。量化判断看速率：`sum(rate(rabbitmq_connections_opened_total[5m]))` 持续大于 `closed_total` 的同口径速率，两条曲线只升不降，基本就能定性。

最后是承诺的速查表，按"症状、根因、处置"整理，出事时直接对号入座：

| 症状 | 根因 | 处置 |
|---|---|---|
| 连接数只涨不跌 | 应用每请求新建连接不复用，异常路径不关闭 | 推动连接池改造；监控 churn 差值；设连接上限 |
| 消费者内存暴涨 | `prefetch` 未设置，默认无限 | 设 10~100，观察 consumer utilization |
| Broker 内存打满、发布被阻断 | 队列无 TTL 无限长，积压顶到内存水位 | 加 `max-length` 与 overflow 策略，扩容消费者 |
| 消息莫名丢失 | 路由不到队列被默认丢弃；或开了 `autoAck` | `mandatory` 加备份交换机；关闭自动确认 |
| 消息被重复处理 | 处理完还没 ack 就断线，消息重新投递 | 业务侧幂等设计，ack 放在事务成功之后 |
| 网络分区后队列数据不一致 | 经典镜像队列脑裂 | 迁移到仲裁队列 |
| K8s 滚动升级时集群不可用 | 副本不足或没配反亲和与 PDB | 3 副本起步，反亲和加 PodDisruptionBudget |

## 写在最后：今天就能开工的行动清单

先交代那晚的结局：最后是紧急扩了三倍消费者，把八百万积压扛了六个小时才清完的；但真正的修复发生在第二天——给 consumers 归零和死信堆积挂上告警，那条红线从此有人认领。

第一，今天就给生产集群挂上那两条告警规则，核心业务的死信队列单独再加一条。

第二，本周用 `rabbitmqctl` 巡检一轮所有队列参数，把没有 TTL 和 `max-length` 保护的队列列成整改清单。

第三，两周内确认核心队列全部是仲裁队列类型，存量镜像队列排出带演练的迁移计划。

第四，本月内做一次混沌演练：`kubectl delete pod` 杀掉一个 Broker 节点，验证 Raft 自动选主和消费恢复时间，把结论写进 Runbook。

RabbitMQ 的运维难点不在命令，而在"模型理解"和"默认值陷阱"的组合拳。这篇文章的速查表和告警规则我都整理在 [sre-learning-hub](https://github.com/Thneoly/sre-learning-hub) 仓库里，clone 即用，配套还有 K8s、Prometheus 和其他中间件的运维学习路径。

速查表七行，你踩过哪一行？评论区报个坐标，我按呼声补进表里。
