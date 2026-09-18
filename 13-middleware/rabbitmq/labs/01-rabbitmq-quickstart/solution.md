# Lab 01 · 解答：RabbitMQ 上手与核心排障实验

环境：装有 Docker 与 docker compose 插件的 Ubuntu 22.04/24.04 VM。除标注 `[本地Windows]` 的浏览器步骤外，所有命令标注 `[任意节点]`。目录结构与文件名固定如下（check.sh 只依赖容器/队列/策略名，脚本名供对照）：

```text
~/rabbit-lab/
├── compose.yaml
└── client/
    ├── publish_orders.py     # 发布 100 条订单
    ├── consume_orders.py     # 可调 prefetch/延迟的消费者
    └── publish_delay.py      # 发 5 条进 TTL 队列
```

## 步骤 1：compose 起两容器

做什么：写 `compose.yaml` 并 `up -d`。为什么这样写：`RABBITMQ_DEFAULT_USER/PASS` 让首次启动直接创建专用账号（**此时 guest 根本不会被创建**，一举消灭默认账号隐患）；healthcheck 用官方诊断命令探 5672，`start_period` 给 RabbitMQ 20 秒上下的启动时间；client 用 `sleep infinity` 保活，靠 `service_healthy` 保证起容器时 broker 已就绪。

```yaml
# [任意节点] ~/rabbit-lab/compose.yaml
services:
  rabbit:
    image: rabbitmq:3.13-management
    container_name: rabbit-lab
    hostname: rabbit-lab
    ports:
      - "5672:5672"
      - "15672:15672"
      - "15692:15692"
    environment:
      RABBITMQ_DEFAULT_USER: app
      RABBITMQ_DEFAULT_PASS: app-secret
    healthcheck:
      test: ["CMD", "rabbitmq-diagnostics", "check_port_connectivity"]
      interval: 10s
      timeout: 10s
      retries: 12
      start_period: 30s
  client:
    image: python:3.12-slim
    container_name: rabbit-client
    depends_on:
      rabbit:
        condition: service_healthy
    command: sleep infinity
    volumes:
      - ./client:/client
```

```bash
# [任意节点] 启动并等待 healthy（首次拉镜像 + 启动约 1 分钟）
cd ~/rabbit-lab && docker compose up -d
watch -n5 'docker ps --format "{{.Names}} {{.Status}}" | grep rabbit'
# 预期: rabbit-lab (healthy)，rabbit-client Up
```

## 步骤 2：账号验证三连（guest 为什么登不上）

做什么：先看镜像默认配置，再用 guest 实测 401，最后浏览器登录。

为什么：交接文档说"guest 只能 localhost"只对了一半——**裸机/包安装**默认确实如此；但**官方 Docker 镜像**的 `10-defaults.conf` 明确写了 `loopback_users.guest = false`，即镜像把限制关掉了，理论上 guest 可以从任意网络登录。本 lab 因为设了 `RABBITMQ_DEFAULT_USER`，guest 压根没被创建，401 的原因是"用户不存在"（RabbitMQ 对"不存在"与"密码错"统一返回 401，不泄露信息）。

```bash
# [任意节点] 镜像默认配置里对 guest 的处理
docker exec rabbit-lab grep -A1 -B1 loopback /etc/rabbitmq/conf.d/10-defaults.conf
# 预期: loopback_users.guest = false（镜像注释原话：allow access to the guest user from anywhere on the network）

# [任意节点] 从 client 容器用 guest 请求管理 API
docker exec rabbit-client python3 -c "
import sys, base64, urllib.request, urllib.error
req = urllib.request.Request('http://rabbit-lab:15672/api/overview')
req.add_header('Authorization', 'Basic ' + base64.b64encode(b'guest:guest').decode())
try:
    urllib.request.urlopen(req, timeout=10); print('LOGIN OK (unexpected!)')
except urllib.error.HTTPError as e:
    print('HTTP', e.code)"
# 预期: HTTP 401

# [任意节点] 确认用户表里只有 app
docker exec rabbit-lab rabbitmqctl -q list_users
# 预期:
# user    tags
# app     [administrator]
```

```text
# [本地Windows] 浏览器打开 http://<VM-IP>:15672，app / app-secret 登录成功；
# 顺手在首页记下 Ports and contexts：amqp 5672 / management 15672 / prometheus 15692。
```

## 步骤 3：CLI 建拓扑

做什么：在 broker 容器内用 rabbitmqadmin 声明 direct 交换机、队列和绑定。为什么用 CLI 不点界面：拓扑即代码，可以进 Ansible/CI；rabbitmqadmin 走的就是 HTTP API（3.13 镜像自带 v2 版，语法以 `rabbitmqadmin --help` 为准）。

```bash
# [任意节点] 声明三件套 + 验证
docker exec rabbit-lab rabbitmqadmin -u app -p app-secret declare exchange name=orders.ex type=direct durable=true
docker exec rabbit-lab rabbitmqadmin -u app -p app-secret declare queue name=orders.q durable=true
docker exec rabbit-lab rabbitmqadmin -u app -p app-secret declare binding source=orders.ex destination=orders.q routing_key=order.new
# 预期: 三行 exchange declared / queue declared / binding declared
docker exec rabbit-lab rabbitmqadmin -u app -p app-secret list exchanges name type | grep orders
docker exec rabbit-lab rabbitmqctl -q list_bindings source_name destination_name routing_key | grep orders.ex
# 预期: orders.ex | direct；orders.ex → orders.q，rk=order.new
```

## 步骤 4：发布 100 条消息

做什么：client 容器装 pika，写发布脚本跑一次。为什么强调 `delivery_mode=2`：durable 队列只保元数据，消息本身要 persistent 才落盘（重启不丢的两个开关缺一不可）。

```python
# [任意节点] ~/rabbit-lab/client/publish_orders.py
import pika

params = pika.ConnectionParameters(
    host='rabbit-lab', credentials=pika.PlainCredentials('app', 'app-secret'))
ch = pika.BlockingConnection(params).channel()
for i in range(1, 101):
    ch.basic_publish(exchange='orders.ex', routing_key='order.new',
                     body=f'order-{i:03d}',
                     properties=pika.BasicProperties(delivery_mode=2))
print('PUBLISHED=100')
```

```bash
# [任意节点] 安装依赖并发布（VM 需可访问 pypi）
docker exec rabbit-client pip install -q pika==1.3.2
docker exec rabbit-client python3 /client/publish_orders.py
# 预期: PUBLISHED=100
docker exec rabbit-lab rabbitmqctl -q list_queues name messages_ready messages_unacknowledged | grep orders.q
# 预期: orders.q    100    0    ← 全部 ready，还没有消费者
```

## 步骤 5：手动 ack 消费

做什么：写一个参数化的消费者脚本（后面两个实验复用它），先以不设限、零延迟把 100 条消费完。为什么手动 ack：autoAck 模式下 Broker 推出即删，业务处理失败消息就没了；手动 ack + 断线重投才是 at-least-once。

```python
# [任意节点] ~/rabbit-lab/client/consume_orders.py
import sys, time, pika

prefetch = int(sys.argv[1]) if len(sys.argv) > 1 else 0      # 0 = 不设置（无限）
delay    = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0  # 每条处理耗时

params = pika.ConnectionParameters(
    host='rabbit-lab', credentials=pika.PlainCredentials('app', 'app-secret'))
conn = pika.BlockingConnection(params)
ch = conn.channel()
if prefetch > 0:
    ch.basic_qos(prefetch_count=prefetch)

acked, last = 0, time.time()

def on_message(channel, method, properties, body):
    global last, acked
    last = time.time()
    time.sleep(delay)                            # 模拟业务处理
    channel.basic_ack(method.delivery_tag)       # 手动 ack
    acked += 1

ch.basic_consume(queue='orders.q', on_message_callback=on_message, auto_ack=False)

while True:
    conn.process_data_events(time_limit=1)
    if time.time() - last > (3 if acked else 10):   # 连续无新消息即认为清空
        break
print(f'ACKED={acked}')
conn.close()
```

```bash
# [任意节点] 消费完 100 条
docker exec rabbit-client python3 /client/consume_orders.py 0 0
# 预期: ACKED=100
docker exec rabbit-lab rabbitmqctl -q list_queues name messages_ready messages_unacknowledged | grep orders.q
# 预期: orders.q    0    0
# 手动 ack 的证据在管理 DB 的 message_stats 里（约 5s 刷新）：
curl -su app:app-secret http://localhost:15672/api/queues/%2F/orders.q | grep -o '"ack":[0-9]*' | head -1
# 预期: "ack":100（若用了 autoAck，这里会是 "deliver_no_ack":N 而 ack 为 0——判分脚本查的就是这点）
```

## 步骤 6：无 prefetch 的 unacked 堆积（第一手数据 ①）

做什么：再发 100 条，开两个终端：终端 A 前台跑"不设 prefetch、每条 5 秒"的慢消费者，终端 B 观察队列。为什么：无限 prefetch 时 Broker 把整个队列一口气推给消费者，unacked 全记在 Broker 内存——这就是"消费者内存暴涨"事故的最小复现。

```bash
# [任意节点]（终端 A：前台慢消费，观察完按 Ctrl-C）
docker exec -it rabbit-client python3 /client/consume_orders.py 0 5

# [任意节点]（终端 B：消费进行中反复执行）
docker exec rabbit-lab rabbitmqctl -q list_queues name messages_ready messages_unacknowledged | grep orders.q
# 预期: orders.q    0    99    ← ready 秒清零，99 条 unacked 压在内存（另 1 条正在处理）
```

在终端 A 按 Ctrl-C 断开消费者，再在终端 B 看：

```bash
# 预期: orders.q    99    0    ← 连接断开，unacked 全部重投回 ready（at-least-once 的代价：可能重复消费）
```

## 步骤 7：prefetch=10 的对比（第一手数据 ②）

做什么：同一个脚本换参数（prefetch=10、每条 3 秒）重复观察。

```bash
# [任意节点]（终端 A）
docker exec -it rabbit-client python3 /client/consume_orders.py 10 3

# [任意节点]（终端 B）
docker exec rabbit-lab rabbitmqctl -q list_queues name messages_ready messages_unacknowledged | grep orders.q
# 预期: orders.q    87    10   ← unacked 恒定 10，ready 缓慢下降；对比步骤 6 的 0/99
```

结论落盘：**无 prefetch = unacked 等于队列长度（Broker 与消费者双内存风险）；prefetch=10 = unacked 被钉死在 10**，内存可控、且后加的消费者能立即分到消息。Ctrl-C 停掉后清空队列拿到终态：

```bash
# [任意节点] 清空（本实验残留 97 条左右）
docker exec rabbit-client python3 /client/consume_orders.py 100 0
# 预期: ACKED=97 左右；随后 orders.q 为 0 0
```

## 步骤 8：死信实验（TTL 过期进 DLX）

做什么：先建死信侧拓扑（orders.dlx、orders.dead、binding）和待过期的 orders.wait，再用 policy 给 orders.wait 挂三键参数，最后发 5 条消息看它们 3 秒后"搬家"。

为什么用 policy 而不是建队列时的 x-arguments：policy 运维侧随时可挂可摘，不用重新声明队列；`dead-letter-routing-key` 是本实验的关键——死信 republish 保留原 routing key（orders.wait），不重写成 order.new 的话，orders.dlx→orders.dead 的绑定匹配不上，死信会被**静默丢弃**（orders.dead 永远为空，还不报错）。

```bash
# [任意节点] 死信拓扑 + policy（注意 pattern 的反斜杠转义）
docker exec rabbit-lab rabbitmqadmin -u app -p app-secret declare exchange name=orders.dlx type=direct durable=true
docker exec rabbit-lab rabbitmqadmin -u app -p app-secret declare queue name=orders.dead durable=true
docker exec rabbit-lab rabbitmqadmin -u app -p app-secret declare binding source=orders.dlx destination=orders.dead routing_key=order.new
docker exec rabbit-lab rabbitmqadmin -u app -p app-secret declare queue name=orders.wait durable=true
docker exec rabbit-lab rabbitmqctl set_policy --apply-to queues dlx-wait '^orders\.wait$' \
  '{"message-ttl":3000,"dead-letter-exchange":"orders.dlx","dead-letter-routing-key":"order.new"}'
# 预期: Setting policy "dlx-wait" for pattern "^orders\.wait$" to "{...}" ...（policy 定义即时生效）
```

```python
# [任意节点] ~/rabbit-lab/client/publish_delay.py
import pika

params = pika.ConnectionParameters(
    host='rabbit-lab', credentials=pika.PlainCredentials('app', 'app-secret'))
ch = pika.BlockingConnection(params).channel()
for i in range(1, 6):
    ch.basic_publish(exchange='', routing_key='orders.wait',   # 默认交换机：rk = 队列名
                     body=f'delay-{i}',
                     properties=pika.BasicProperties(delivery_mode=2))
print('PUBLISHED=5 -> orders.wait')
```

```bash
# [任意节点] 发布后分两个时间点观察
docker exec rabbit-client python3 /client/publish_delay.py
sleep 2
docker exec rabbit-lab rabbitmqctl -q list_queues name messages_ready | grep -E 'orders.(wait|dead)'
# 预期: orders.wait 5 / orders.dead 0     ← 还在"躺"着等 TTL
sleep 4
docker exec rabbit-lab rabbitmqctl -q list_queues name messages_ready | grep -E 'orders.(wait|dead)'
# 预期: orders.wait 0 / orders.dead 5     ← 3 秒 TTL 到期，整批死信搬家
# 取一条看死信档案（ackmode=ack_requeue_true：取出后塞回，不破坏现场）
docker exec rabbit-lab rabbitmqadmin -u app -p app-secret -f pretty_json get queue=orders.dead count=1 ackmode=ack_requeue_true | grep -A9 'x-death'
# 预期:
#   "x-death": [ { "count": 1,
#                  "exchange": "",
#                  "queue": "orders.wait",
#                  "reason": "expired",
#                  "routing-keys": ["orders.wait"], ... } ]
# 外层 headers 还有 x-first-death-reason / x-last-death-reason，排障时直接回答"为什么死、死了几次"
```

## 步骤 9：监控指标验证

```bash
# [任意节点] 宿主机直连 15692（rabbitmq_prometheus 插件在镜像里默认启用）
docker exec rabbit-lab rabbitmq-plugins list -e | grep rabbitmq_prometheus
# 预期: [E*] rabbitmq_prometheus   3.13.x
curl -s http://localhost:15692/metrics | grep -E '^rabbitmq_(queue_messages_ready|connections_opened_total)' | head -3
# 预期: rabbitmq_queue_messages_ready 5     ← 聚合值，没有 queue 标签！
curl -s http://localhost:15692/metrics/per-object | grep 'rabbitmq_queue_messages_ready{vhost="/",queue="orders.dead"}'
# 预期: rabbitmq_queue_messages_ready{vhost="/",queue="orders.dead"} 5
# 结论：按队列画曲线/告警必须抓 /metrics/per-object，默认 /metrics 只有聚合序列
```

## 运行 check.sh

```bash
# [任意节点]（在 lab 目录内）
chmod +x check.sh && ./check.sh
```

预期全部通过：

```text
PASS: rabbit-lab 容器运行中
PASS: rabbit-client 容器运行中
PASS: 管理 API 可用且 app 认证成功
PASS: guest 远程登录被拒（401）
PASS: app 对 / 的 configure/write/read 权限齐全
PASS: exchange orders.ex 存在且类型 direct
PASS: 队列 orders.q 与 binding（rk=order.new）存在
PASS: orders.q 已消费完且为手动 ack（ready=0、unacked=0、ack>=100）
PASS: policy dlx-wait 含 message-ttl/dead-letter-exchange/dead-letter-routing-key
PASS: 死信链路闭环（orders.dlx→orders.dead 且死信 >= 1）
PASS: 监控可用（/metrics 含队列深度指标且插件已启用）

SCORE: 11/11
```

## 清理

```bash
# [任意节点] check 通过后清理（-v 连同具名卷一起删）
cd ~/rabbit-lab && docker compose down -v
```

## 复盘要点

- 账号：guest 的 loopback 限制在 Docker 镜像里默认被关闭（`10-defaults.conf` 可见），设 `RABBITMQ_DEFAULT_USER` 后 guest 干脆不创建——生产上专用账号 + 不留 guest；
- prefetch：同一队列、同一消费速度，无 prefetch 时 unacked 实测 ≈ 队列长度（0/99），prefetch=10 时被钉死在 10（87/10）——内存风险的差距一目了然；
- 断线重投：Ctrl-C 之后 unacked 秒级回到 ready，这是 at-least-once 的来源，业务侧必须幂等（对照 Kafka 位移重放，见 14-data-streaming/kafka 第 2 章）；
- 手动 ack 的证据在 `/api/queues/%2F/<q>` 的 `message_stats.ack`（autoAck 走的是 `deliver_no_ack` 计数），巡检时一条 curl 就能识别消费模式；
- DLX：死信保留原 routing key，`dead-letter-routing-key` 不配 + DLX binding 不匹配 = 死信静默丢弃，orders.dead 永远为空还不报错——配完必须用 `rabbitmqadmin get` 看到带 `x-death`（reason=expired）的消息才算闭环；
- 监控：默认 `/metrics` 是无标签聚合值，按队列的曲线与告警要抓 `/metrics/per-object`。
