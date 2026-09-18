# Lab 01 · RabbitMQ 上手与核心排障实验：从 CLI 拓扑到死信与监控

> 难度：★★☆ ｜ 考点：中间件-消息队列（对应第 3 章监控/死信/常见坑） ｜ 前置：装有 Docker 与 docker compose 插件的 Ubuntu 22.04/24.04 VM，可访问外网（拉镜像、pip 装 pika） ｜ 预计 40~60 分钟

## 场景

你是新入职的 SRE。团队用 RabbitMQ 承接订单异步处理（下单 → 扣库存 → 通知），下周交给你值班。交接文档只有一句话："管理界面在 15672"。你决定在演练环境把整条链路亲手走一遍：用 docker compose 起一套 broker + 客户端容器，搞清账号为什么登不上，用 CLI 建拓扑、发 100 条订单消息、消费并确认，把 prefetch 不设与设为 10 的行为差异拿到第一手数据，再做一次"延迟消息 TTL 过期进死信"的完整实验，最后确认监控指标能被抓到——值班的底气就来自这九步。

网络与命名约定（check.sh 依赖这些名字，请严格使用）：

| 对象 | 名字 | 说明 |
|---|---|---|
| broker 容器 | rabbit-lab | rabbitmq:3.13-management，映射 5672/15672/15692 |
| 客户端容器 | rabbit-client | python:3.12-slim + pika 1.3.2，挂载 `./client` 到 /client |
| 管理用户 | app / app-secret | 用 compose 环境变量创建（注意：此时 guest 不会被创建） |
| 业务交换机 | orders.ex | direct、durable，binding rk = `order.new` |
| 业务队列 | orders.q | durable；发布 100 条、手动 ack 消费的主战场 |
| TTL 队列 | orders.wait | 由 policy `dlx-wait` 控制：message-ttl=3000 + 死信 |
| 死信交换机 | orders.dlx | direct、durable |
| 死信队列 | orders.dead | binding rk = `order.new` |

## 任务清单

1. 在 `~/rabbit-lab/` 写 `compose.yaml`：服务 `rabbit`（镜像 rabbitmq:3.13-management，容器名 rabbit-lab，hostname rabbit-lab，映射 5672/15672/15692，环境变量创建 app/app-secret，healthcheck 用 `rabbitmq-diagnostics check_port_connectivity`）与服务 `client`（python:3.12-slim，容器名 rabbit-client，依赖 rabbit 健康，`sleep infinity` 保活，bind mount `./client:/client`）；`docker compose up -d` 后等到 rabbit-lab 状态 healthy
2. 账号验证三连：在 rabbit-lab 容器里 `cat /etc/rabbitmq/conf.d/10-defaults.conf`，找出镜像对 guest 的 loopback 限制做了什么；从 rabbit-client 容器用 guest/guest 请求 `http://rabbit-lab:15672/api/overview`，确认拿到 401；在本地 Windows 浏览器打开 `http://<VM-IP>:15672` 用 app/app-secret 登录成功
3. CLI 建拓扑（在 rabbit-lab 容器内用 rabbitmqadmin，账号 app）：direct 交换机 orders.ex（durable）、队列 orders.q（durable）、binding orders.ex → orders.q（rk=order.new），用 `list exchanges` / `list bindings` 验证
4. 在 rabbit-client 里 `pip install pika==1.3.2`，写 `client/publish_orders.py`：向 orders.ex 以 rk=order.new 发布 **100** 条 persistent（delivery_mode=2）消息；发布后用 `rabbitmqctl list_queues` 确认 orders.q 的 messages_ready=100
5. 写 `client/consume_orders.py`（参数：prefetch（0=不设限）、每条处理延迟秒数）：basic_consume + **手动 ack**，队列空后自动退出并打印 ACKED 总数；用 delay=0 把 100 条消费完，确认 ready=0、unacked=0，并用 HTTP API `/api/queues/%2F/orders.q` 的 `message_stats.ack` 证明是手动 ack（≥100）
6. 再发布 100 条，另开终端跑慢消费者（不设 prefetch、每条 sleep 5 秒），消费进行中用 `rabbitmqctl -q list_queues name messages_ready messages_unacknowledged` 观察：ready 归零、unacked 接近 100（无 prefetch 时消息被一口气推下来）；Ctrl-C 停掉慢消费者，再观察 unacked 重投回 ready
7. prefetch 实验：用同一个脚本以 prefetch=10、每条 sleep 3 秒慢消费，观察 unacked 恒 ≤10、ready 缓慢下降；对比第 6 步数据得出结论；最后 delay=0 清空 orders.q（终态 ready=0、unacked=0）
8. 死信实验：rabbitmqadmin 建 orders.dlx（direct、durable）、orders.dead（durable）、binding（rk=order.new）；`rabbitmqctl set_policy --apply-to queues dlx-wait '^orders\.wait$' '{"message-ttl":3000,"dead-letter-exchange":"orders.dlx","dead-letter-routing-key":"order.new"}'`；写 `client/publish_delay.py` 向默认交换机 rk=orders.wait 发 5 条消息；先建好队列 orders.wait（plain，无参数）再发布；等 5 秒后验证 orders.dead 收到 5 条死信，并用 `rabbitmqadmin -f pretty_json get queue=orders.dead count=1 ackmode=ack_requeue_true` 查看其中一条的 `x-death` header（reason 应为 expired）
9. 监控验证：宿主机 `curl -s http://localhost:15692/metrics` 能看到 `rabbitmq_queue_messages_ready`、`rabbitmq_connections_opened_total`；`rabbitmq-plugins list -e` 确认 rabbitmq_prometheus 已启用；对比默认 `/metrics`（无 queue 标签）与 `/metrics/per-object`（带 `{vhost,queue}` 标签）的输出差异

## 验收标准

- rabbit-lab（healthy）与 rabbit-client 两容器运行中；app 能通过 Web UI 与 API 登录，guest 从 rabbit-client 请求 API 返回 401
- orders.ex（direct）、orders.q、orders.ex→orders.q 的 binding（rk=order.new）存在
- orders.q 终态：messages_ready=0、messages_unacknowledged=0、`message_stats.ack` ≥ 100（手动 ack 的证据）
- policy dlx-wait 作用于 orders.wait，含 message-ttl、dead-letter-exchange、dead-letter-routing-key 三键；orders.dead 至少 1 条死信
- 宿主机 15692 的 /metrics 可访问且含队列深度指标；rabbitmq_prometheus 出现在已启用插件列表
- 你能说出三个数字：无 prefetch 时 unacked 的峰值、prefetch=10 时 unacked 的稳定值、orders.dead 的死信条数

运行 check.sh 通过（SCORE: 11/11）后再做清理。

## 提示（卡住再看）

<details><summary>提示 1：compose 的 healthcheck 与 depends_on</summary>

healthcheck 用 `["CMD", "rabbitmq-diagnostics", "check_port_connectivity"]`，配 `start_period: 30s`（RabbitMQ 启动要 20 秒上下）；client 侧 `depends_on: { rabbit: { condition: service_healthy } }`。client 容器里没有 systemd，用 `command: sleep infinity` 保活，之后所有客户端操作都 `docker exec rabbit-client ...`。
</details>

<details><summary>提示 2：guest 到底能不能远程连？</summary>

分两层：**裸机/包安装**的 RabbitMQ 默认 guest 只能 localhost 登录（loopback 限制）；但**官方 Docker 镜像**的 `10-defaults.conf` 写了 `loopback_users.guest = false` 把限制关了。本 lab 设了 `RABBITMQ_DEFAULT_USER=app`，此时候选行为是 guest **根本不会被创建**——所以 guest/guest 请求 API 是 401（用户不存在也是 401）。生产结论：专用账号 + 不留 guest。
</details>

<details><summary>提示 3：rabbitmqadmin 的语法</summary>

3.13-management 镜像自带 rabbitmqadmin（3.13.7 是 v2，`/usr/local/bin/rabbitmqadmin`，`--version` 可查）。关键子命令：`declare exchange name=... type=direct durable=true`、`declare queue name=... durable=true`、`declare binding source=... destination=... routing_key=...`、`list exchanges name type`、`list bindings source_name destination_name routing_key`、`get queue=... count=1 ackmode=ack_requeue_true`。选项 `-u app -p app-secret` 放在子命令前。细节以容器内 `rabbitmqadmin --help` 为准。
</details>

<details><summary>提示 4：手动 ack 消费的三件套</summary>

`ch.basic_qos(prefetch_count=N)`（N>0 才生效，0 表示不设置）、`ch.basic_consume(queue=..., on_message_callback=..., auto_ack=False)`、回调里 `ch.basic_ack(method.delivery_tag)`。队列空后退出可以用 `conn.process_data_events(time_limit=1)` 的循环 + "连续 3 秒没新消息"判断。慢消费者在第二个终端前台跑（`docker exec -it`），Ctrl-C 即断开——断开后 unacked 会立刻重投，这正是要观察的现象。
</details>

<details><summary>提示 5：TTL 队列的坑</summary>

死信 republish 时保留**原 routing key**（orders.wait），如果 policy 里没有 `dead-letter-routing-key` 把它重写成 order.new，而 orders.dlx→orders.dead 只绑了 order.new，死信会被**静默丢弃**——orders.dead 永远是空的。这是第 3 章 2.2 节的头号坑，亲手踩一遍。
</details>

<details><summary>提示 6：pika 连接参数</summary>

`pika.ConnectionParameters(host='rabbit-lab', credentials=pika.PlainCredentials('app', 'app-secret'))`，端口默认 5672、vhost 默认 `/`。发布 persistent 消息记得 `properties=pika.BasicProperties(delivery_mode=2)`；向默认交换机发布用 `exchange=''`、`routing_key='orders.wait'`。
</details>
