# 06 · Celery 分布式任务队列：异步化、削峰与定时的运维视角

> 模块：02-programming ｜ 建议时长：5 小时 ｜ 关联认证：—（无直接考点；与 CKA 的 HPA/Deployment、PCA 的队列深度监控思路相通）

## 学习目标

- 能用"异步化 / 削峰 / 定时"三场景判断一个需求该不该上任务队列，而不是"顺手就用"
- 能画出 broker / worker / result backend 三角架构，并在 Redis 与 RabbitMQ 之间按语义差异选型（含 Redis 可见性超时陷阱）
- 能解释 prefork / gevent / threads 三种 worker 并发模型与 `-c` 参数的语义
- 能拆解 acks_late 的"至少一次"语义与重复执行陷阱，并给任务配上指数退避重试与幂等设计
- 能用 LLEN / flower / inspect 排查积压，给出 systemd 与 K8s（按队列深度伸缩）两种部署形态

## 1. 为什么需要任务队列：三个场景

Web 请求的同步模型里，"用户点了一下按钮"到"响应返回"之间的每一毫秒都在占用连接与 worker 槽位。三类典型场景把"慢"从请求路径上摘出去：

| 场景 | 问题形态 | 任务队列的解法 |
|---|---|---|
| 异步化 | 注册要发邮件、上传要转码、下单要扣库存+发通知，同步等 10s 用户就走了 | 请求里只做 enqueue（毫秒级），慢动作交给 worker，结果用轮询/回调拿 |
| 削峰 | 秒杀/批量报表瞬间涌入 10 万请求，数据库连接池被打穿 | 请求进队列即返回，worker 按自身容量匀速消费，峰值被"蓄水"消化 |
| 定时 | crontab 散在 30 台机器上，谁跑了谁没跑没人知道 | beat 集中产生调度消息，与业务任务走同一条链路，可观测可重试 |

判断口诀：**动作慢（秒级以上）、结果可以晚到、允许重试**，就考虑队列；三者缺一（比如必须同步给用户看结果）就别硬上。队列不是免费的——它把"慢"换成了"复杂度"：消息可能重复、可能延迟、需要监控积压，这些代价贯穿全章。

## 2. 架构三角：producer / broker / worker / result backend

```
 producer(Web/API/脚本)          broker(消息中转)              worker(N 个, 可横向扩)
 ┌────────────────────┐        ┌──────────────────┐        ┌────────────────────┐
 │ order.delay(42)    │ ─LPUSH►│ Redis list 或     │ BRPOP  │ w1 -c 4  (prefork) │
 │  毫秒级返回 task_id │        │ RabbitMQ queue   │◄────── │ w2 -c 4            │
 └────────────────────┘        │                  │        │ w3 -c 100 (gevent) │
        │                      └──────────────────┘        └─────────┬──────────┘
        │  result.get() / 轮询                                        │ 任务完成后写
        ▼                                                             ▼
        └──────────────► result backend(Redis / DB / 关闭)◄───────────┘
```

三角的三个顶点各自独立扩缩：producer 跟着 Web 流量走，worker 跟着队列深度走，broker 决定可靠性上限。**result backend 是可选件**——只关心"丢给队列就算完成"的场景（发通知、刷缓存）应显式关闭（`task_ignore_result=True`），省掉每个任务一次状态写回。

最小可跑的 app（完整动手在本章 lab，见文末实战演练）：

```python
# [任意节点] tasks.py —— 三角的最小定义
from celery import Celery

app = Celery(
    "myapp",
    broker="redis://127.0.0.1:6392/1",     # 消息走 db1
    backend="redis://127.0.0.1:6392/2",    # 结果走 db2，分开避免互相挤占
    broker_transport_options={"visibility_timeout": 3600},  # 见第 3 节
)

@app.task
def order(n: int) -> int:
    return n * 2
```

```bash
# [任意节点] 起一个 worker，另开终端 enqueue
celery -A tasks worker -c 2 --loglevel=INFO
python3 -c "from tasks import order; print(order.delay(21).get(timeout=10))"   # 42
```

## 3. broker 选型：Redis vs RabbitMQ

Celery 对 broker 只要求"能存取消息"，于是两个主流选项的语义差异全部下沉到 broker 本身：

| 维度 | Redis | RabbitMQ |
|---|---|---|
| 消息模型 | LPUSH/BRPOP 一个 list（默认 key 就叫 `celery`），list 底层是 quicklist（[redis 01 章 §list](../13-middleware/redis/01-data-structures-and-memory.md)） | AMQP：exchange 按 routing key 分发到 queue，支持 topic/fanout 灵活路由 |
| 确认语义 | **无原生 ack**。Celery/kombu 自己记账：取走的消息塞进 `unacked` hash，确认后删除——"确认"是模拟出来的 | 原生 AMQP ack，unacked 消息在连接断开时自动重新入队 |
| 重复执行风险 | **可见性超时陷阱**（下文详解）：unacked 消息超过 `visibility_timeout`（默认 3600s）未确认即被重新投递 | 连接断开才重投，处理中的消息不会被"超时抢走" |
| 持久化 | AOF everysec 最坏丢约 2 秒（[redis 02 章 §3](../13-middleware/redis/02-persistence-and-ha.md)），broker 重启可能丢这 2 秒内的 enqueue | 队列与消息可标记持久化，落盘语义明确 |
| 优先级/延迟队列 | 优先级支持有限（分多个 list 模拟）；延迟要靠 ETA 或额外组件 | 原生 priority 队列；延迟可用插件（以官方文档为准） |
| 运维成本 | 一鱼多吃：缓存+队列共用一套，已有 Redis 就零新增组件 | 独立集群、独立监控，但管理界面与语义更完整 |
| 适合 | 已有 Redis、任务可幂等、允许极端情况重复 | 任务路由复杂、可靠性要求高、长任务多 |

**可见性超时陷阱**是 Redis broker 最重要的语义：worker 取走消息后消息进 `unacked` hash，若 worker 进程僵死（OOM、GC 停顿、网络分区）而未确认，这条消息对其他 worker "不可见"；只有超过 `visibility_timeout` 后才会被重新投递。两个后果：

1. worker 假死时，故障发现时间 = visibility_timeout——设 1 小时意味着任务可能延迟 1 小时才被别人接手；
2. **任务执行时长一旦超过 visibility_timeout，还在正常执行的消息也会被判"超时"而重新投递给其他 worker——同一条任务被两个 worker 同时执行**。所以铁律是：`visibility_timeout` 必须大于最长任务的执行时间（含重试）；长任务要么调大它，要么换 RabbitMQ。版本敏感的默认值与参数写法以官方文档为准（docs.celeryq.io → "Redis & Riak backend settings"）。

选型结论：缓存型、可幂等、已有 Redis——用 Redis broker 顺手；任务长、路由复杂、重复执行代价高——RabbitMQ 的原生 ack 语义值得多养一套集群。

## 4. worker 并发模型：prefork / gevent / threads

`celery -A tasks worker -P <池> -c <并发数>`，`-P` 选池，`-c` 设并发单元数：

| 池 | `-c` 的含义 | 适用 | 坑 |
|---|---|---|---|
| prefork（默认） | **子进程数**，默认 = CPU 核数 | CPU 密集（压缩、转码、计算） | 每个子进程独立内存，`-c` 大了先爆内存；与 fork 不安全的库（某些驱动）冲突 |
| gevent | **绿色线程数**，可设到数百上千 | IO 密集（HTTP 调用、查库、发通知） | 依赖 monkey patch，一个任务陷入 C 层同步调用会卡住整个 worker；CPU 密集任务彻底不适用 |
| threads | 线程数 | IO 密集但 gevent patch 出问题的库 | 受 GIL 约束，真并行不存在 |

经验：`-c` 不是越大越好。prefork 下 `-c` 超过 CPU 数只增加调度开销；gevent 下 `-c 1000` 意味着瞬时对外连接也可能是 1000，下游（数据库、第三方 API）先被打挂。**容量规划从下游承受力倒推，不从 worker 野心正推**。

另一个关键参数 `worker_prefetch_multiplier`（默认 4）：worker 会提前从队列抓 `c × multiplier` 条消息囤在本地。默认值对"几千条 1 秒任务"是吞吐优化，对"每条 10 分钟任务"是灾难——先被抢到的 worker 囤了 4 倍的活，新扩容的 worker 只能干等。长任务场景固定配 `worker_prefetch_multiplier=1`（公平分发）。

## 5. 任务生命周期与 acks_late 的重复执行陷阱

任务状态机：`PENDING → SENT → STARTED → (RETRY →) SUCCESS / FAILURE / REVOKED`。`PENDING` 是"还没看到结果"的默认态——**任务不存在与任务排队中在结果端不可区分**，这是用 result backend 时要心里有数的细节。

确认时机（ack）决定故障语义：

| 配置 | ack 时机 | worker 半路被 kill 的后果 |
|---|---|---|
| 默认（early ack） | **收到任务就 ack** | 任务直接丢失，无重投。换来的是绝无重复 |
| `acks_late=True` | **执行完才 ack** | 任务被重新投递、再次执行——"至少一次" |

这正是 [19-distributed/04 §5](../19-distributed/04-distributed-transactions.md) 拆穿的"恰好一次真相"在任务队列里的化身：**acks_late 买到的是"不丢"，代价是"可能重"**，工程上能兑现的只有 at-least-once + 幂等——没有任何 ack 时机能同时给出不丢与不重。配套参数 `task_reject_on_worker_lost=True`（默认 False）决定 worker 进程被杀死时任务是否立即 requeue；而 kill -9 掉整个 worker（父进程也死）时，Redis broker 下的重投靠的是第 3 节的可见性超时恢复。

运维上的推论：**所有配了 acks_late 的任务，一律按"会被执行两次"来设计**——发短信要去重、扣款要幂等、写文件要先写临时名再原子 rename。lab 里我们会真刀真枪 kill 一次 worker，把重复执行的证据落盘。

## 6. 重试与幂等设计

### 6.1 指数退避：retry_backoff

瞬时故障（网络抖动、下游 503）靠重试吸收，固定间隔重试会在下游恢复瞬间造成同步冲击，所以要指数退避：

```python
# [任意节点] 声明式重试：失败的 IOError 自动重试，间隔 1s/2s/4s...（带默认抖动）
@app.task(
    bind=True,
    autoretry_for=(ConnectionError,),
    retry_backoff=True,          # 指数退避: 1, 2, 4, 8 ...
    retry_backoff_max=600,       # 退避上限（秒），默认 600
    retry_jitter=True,           # 随机抖动，防止重试风暴同相（默认开）
    max_retries=5,               # 超过后任务判 FAILURE
    time_limit=300,              # 硬超时: 到点 SIGKILL 进程，防长任务霸占槽位
    soft_time_limit=280,         # 软超时: 先抛 SoftTimeLimitExceeded 给任务善后
)
def sync_inventory(sku: str):
    ...
```

命令式等价物是任务体内 `raise self.retry(countdown=5, exc=e)`。两个纪律：**每个任务都要有 time_limit**（没有超时的任务会在队列里越积越死，见第 8 节反模式）；**重试只救瞬时故障**，参数错误重试一万次也是错——非瞬时异常别放进 autoretry_for。

### 6.2 幂等：重试的承重墙

重试必然带来重复，幂等模式直接复用 [19-distributed/04 §6](../19-distributed/04-distributed-transactions.md) 的速查表：能落库用业务唯一键（`UNIQUE KEY` + `INSERT IGNORE`），跨系统用消息 ID 去重表，短窗口去重用 `SET NX EX`。落到 Celery 语境的映射：**task_id 就是现成的消息 ID**——消费侧以 `(task_name, task_id)` 建去重键，第二个 worker 重新执行同一条任务时命中去重，副作用只发生一次。去重键的窗口必须覆盖"最长重投延迟"（可见性超时 + 重试链），太短等于没设。

### 6.3 可运行骨架：task_id 去重守卫 + 完整任务定义

把 §6.1 的重试参数与 §6.2 的去重思路合成一份可直接拷走的骨架（[labs/03](./labs/03-celery-tasks/solution.md) 负责实证"重复必然发生"，本骨架负责"发生了也不重复执行副作用"，两者互补）：

```python
# [任意节点] dedupe.py —— 消费侧幂等守卫 + 生产配置（沿用 lab 的 Redis 端口 6392）
import redis
from celery import Celery

app = Celery(
    "myapp",
    broker="redis://127.0.0.1:6392/1",
    backend="redis://127.0.0.1:6392/2",
    broker_transport_options={"visibility_timeout": 7200},
)
rdb = redis.Redis.from_url("redis://127.0.0.1:6392/3")  # 去重键独立 db，不与 broker/backend 挤占

app.conf.update(
    worker_prefetch_multiplier=1,        # 长任务公平分发（第 4 节）
    task_acks_late=True,                 # 至少一次语义，配套下面的去重守卫
    task_reject_on_worker_lost=True,
    result_expires=3600,                 # 结果 1h 后过期清理，防 result db 无限膨胀
    task_ignore_result=True,             # 默认不写结果：多数任务 fire-and-forget
)

DEDUPE_TTL = 7200 + 1800  # 必须覆盖 visibility_timeout + 重试链总时长，否则等于没设


def first_time(task_id: str) -> bool:
    """SET NX EX 原子判定：第一个到场返回 True，重投的第二个直接 False"""
    return bool(rdb.set(f"dedupe:{task_id}", 1, nx=True, ex=DEDUPE_TTL))


@app.task(
    bind=True,
    autoretry_for=(ConnectionError,),    # 只救瞬时故障（§6.1）
    retry_backoff=True,
    retry_backoff_max=60,
    retry_jitter=True,
    max_retries=5,
    soft_time_limit=280,                 # 软超时先抛异常给任务善后
    time_limit=300,                      # 硬超时兜底杀进程
)
def sync_inventory(self, sku: str) -> str:
    if not first_time(self.request.id):  # 消费侧检查：重投进来的同一 task_id 到此为止
        return "duplicate-skipped"
    ...  # 真实副作用：写库/调第三方——业务唯一键仍是最后防线（§6.2）
    return "ok"


@app.task(ignore_result=False)           # 少数确实要读结果的任务单独放开
def query_report(n: int) -> int:
    return n * 2
```

四个要点：`SET NX EX` 必须一条命令完成，`SETNX` + `EXPIRE` 两步在中间崩溃会留下永不过期的键；`task_ignore_result=True` 是全局默认关、个别任务用 `ignore_result=False` 单独开，方向别写反；`result_expires` 只清理 result backend 的状态键，与 broker 消息无关；`DEDUPE_TTL` 的下界就是 §6.2 说的"最长重投延迟"——可见性超时 7200s 加最长重试链，这里留了 30 分钟余量。

## 7. 积压监控：LLEN / flower / 探针

积压（backlog）是任务队列的第一健康指标——队列深度只增不减，等于系统在"假活着"。

```bash
# [任意节点] 队列深度：Redis broker 的队列就是一个 list，key 名默认 celery
docker exec <redis容器> redis-cli LLEN celery          # 待处理消息数
docker exec <redis容器> redis-cli HLEN unacked         # 已取走未确认数（worker 手里的活）
# 健康检查：要求 worker 在 2s 内应答 ping（K8s 探针、监控脚本都用它）
celery -A tasks inspect ping --timeout 2
celery -A tasks inspect active                         # 各 worker 正在执行的任务明细
celery -A tasks inspect stats                          # 池类型/并发/已处理计数
```

比瞬时值更有意义的是**消化时间**：`积压消化时间 ≈ LLEN ÷ 完成速率`。LLEN=1000 而吞吐 50 条/s 只是 20 秒的浪，LLEN=100 而吞吐 1 条/s 才是要报警的病——**告警阈值要按"预计消化时长"设，不按绝对条数设**。把 LLEN 暴露成 Prometheus Gauge 的思路与 [02-programming/04 第 2 节](./04-python-ops-toolkit.md)的自定义 exporter 完全一致（定时 `LLEN` 后 `Gauge.set`），也可以直接用现成的 redis_exporter 抓队列 key。

flower 是官方生态里的实时监控面板（每任务的事件流、成功率、各 worker 状态）：

```bash
# [任意节点] pip install flower，对业务零侵入
celery -A tasks flower --port=5555     # 浏览器开 http://<host>:5555
```

排障三板斧：LLEN 看积压在不在 → `inspect ping` 看 worker 活没活 → `inspect active` + worker 日志看任务是卡死还是在慢跑。三步就能区分"没人在干活"（worker 挂了）与"干不过来"（扩容/优化）。

## 8. beat 定时与 cron 对比；部署形态

### 8.1 beat vs crontab

```python
# [任意节点] beat_schedule：集中式调度表
from celery.schedules import crontab

app.conf.beat_schedule = {
    "nightly-report": {
        "task": "myapp.report",
        "schedule": crontab(hour=2, minute=30),   # 时区由 app.conf.timezone 决定
        "args": ("daily",),
    },
}
```

| 维度 | crontab | celery beat |
|---|---|---|
| 部署 | 每台机器各一份，漂移无感知 | 单点进程集中调度，任务在任意 worker 执行 |
| 错过补偿 | 停机期间的任务直接错过 | 同样错过（默认不补），但错过的是"消息"而非"执行"，可观测 |
| 失败处理 | 脚本自己管，重试/告警各写各的 | 直接继承任务的重试/超时/监控体系 |
| 单点风险 | 无（本来就分散） | **beat 必须只跑一个实例**，多副本会重复触发调度；HA 靠 systemd 自动拉起或 K8s 单副本 Deployment |

beat 的定位：把"定时"从 N 台机器的 crontab 收敛成一条与异步任务同链路、可观测的消息流。动态调度表（运行时改计划）用 django-celery-beat，以官方文档为准。

### 8.2 systemd 形态（VM 时代）

```ini
# [任意节点] /etc/systemd/system/celery-worker.service
[Unit]
Description=celery worker
After=network-online.target redis-server.service

[Service]
User=celery
WorkingDirectory=/opt/myapp
Environment=CELERY_BROKER_URL=redis://127.0.0.1:6379/1
ExecStart=/opt/myapp/venv/bin/celery -A tasks worker -c 4 --prefetch-multiplier 1
Restart=on-failure                # worker 被 OOMKill 后自动复活
KillSignal=SIGTERM                # 优雅退出: 不再取新任务, 执行完手头的再走

[Install]
WantedBy=multi-user.target
```

beat 同款再写一个 `celery-beat.service`（ExecStart 换成 `celery -A tasks beat`），**只部署一台**。

### 8.3 K8s 形态：按队列深度伸缩

CPU 利用率对 worker 是个坏指标——IO 密集型 worker 队列积压一万条、CPU 却不到 10%，原生 HPA（[04-k8s-fundamentals/04 §5](../04-k8s-fundamentals/04-workload-controllers.md)）完全不会扩容。正确信号是队列深度：

```
                    ┌──────────────────────────────────────────────┐
                    │  KEDA (或 custom-metrics-adapter + HPA)       │
                    │  指标: LLEN celery  ──►  目标: 每副本 ≤ 200 条  │
                    └───────────────┬──────────────────────────────┘
                                    │ scale
                                    ▼
                    Deployment celery-worker (replicas 2~12)
                                    │ BRPOP
                                    ▼
                          Redis broker (list: celery)
                                    ▲ LPUSH
                          producer (Web Deployment)
```

KEDA 的 Redis Lists scaler 原生支持以 list 长度为伸缩信号（trigger 字段名如 `listName`、`targetListLength` 随版本演进，以 KEDA 官方文档为准）；不想引入 KEDA 时，用 [02-programming/04](./04-python-ops-toolkit.md) 的 exporter 把 LLEN 变成自定义指标，接 custom-metrics-adapter 供 HPA 查询。beat 用单副本 Deployment + 永不并行的纪律（或分布式锁方案，以官方文档为准）。Pod 里 worker 的存活探针就是第 7 节的 `celery inspect ping`。

### 8.4 反模式清单

| 反模式 | 症状 | 纠正 |
|---|---|---|
| 长任务无 time_limit | worker 槽位被占满，LLEN 只涨不降 | 每任务配 time_limit；超长任务拆阶段（chord/链）或换专用队列独立扩缩 |
| 同步链：任务 A 里调 `B.delay(...).get()` | A 占着槽位干等 B，并发能力被链式平方级放大消耗 | 用 `chain()/chord()` 声明编排，worker 只执行不等待 |
| 把队列当 RPC：每个 Web 请求都 `.get()` 等结果 | "异步"名存实亡，还多了 broker 一跳延迟 | 需要同步结果的需求就别进队列；确需等待用轮询/回调 |
| 无超时地调外部服务 | 一个下游抖动冻结一串 worker | requests/DB 客户端全部显式 timeout，配合任务级 time_limit 双保险 |
| 所有任务挤一个队列 | 快任务被慢任务堵死（队头阻塞） | 按耗时拆队列（fast/slow），worker 用 `-Q` 分队列消费，各自独立扩缩 |
| beat 起了两个副本 | 所有定时任务双倍执行 | beat 单实例；多副本环境用锁或调度去重，以官方文档为准 |
| 不幂等却开 acks_late / 开重试 | 短信发两遍、库存扣两次 | 第 6 节：task_id 去重 + 业务唯一键兜底 |

## 实战演练

本章配套 [labs/03-celery-tasks](./labs/03-celery-tasks/task.md)（在装有 Docker 的 Ubuntu VM 上，约 60 分钟）完整走一遍：docker 起 Redis broker → venv 装 celery → 单 worker 跑通快/失败重试/长三类任务并落结果文件 → 双 worker 观察分发 → 脚本制造 1000 条积压并用 LLEN 记录峰值 → 提高并发消化到清零 → kill -9 正在执行任务的 worker，亲手拿到 acks_late 重复执行的同 task_id 双证据文件。章节里所有"陷阱"在 lab 里都有对应的实证步骤。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 任务偶发被执行两次 | 任务时长 > visibility_timeout，被超时重投 | 调大 broker_transport_options 的 visibility_timeout 或拆短任务；任务本身幂等兜底 |
| worker 被杀后任务消失 | 默认 early ack，收到即确认 | 关键任务 `acks_late=True` + `task_reject_on_worker_lost=True`，并接受至少一次语义 |
| 队列越积越多，CPU 却很闲 | IO 密集任务用了 prefork 小 `-c` | 换 `-P gevent -c 100+`，或增加 worker 副本 |
| 扩容的 worker 接不到活 | prefetch_multiplier 默认 4，老 worker 囤光 | `worker_prefetch_multiplier=1` 重启全部 worker |
| 任务报 `SoftTimeLimitExceeded` 后仍卡着 | 软超时抛异常但任务吞了异常继续跑 | 确保不捕获裸 Exception；硬 time_limit 是最后防线 |
| flower 上看不到任务 | worker 没发事件 | worker 启动加 `-E`（或 `worker_send_task_events=True`） |
| Redis 重启后丢了一批 enqueue | AOF everysec 的 2 秒丢失窗口（[redis 02 章 §3](../13-middleware/redis/02-persistence-and-ha.md)） | 重要队列评估 RabbitMQ；Redis 侧确认 AOF 开启且磁盘健康 |
| 定时任务全部执行了两遍 | beat 多副本 | 只留一个 beat 实例，其余下线 |

## 自测

<details><summary>1. 为什么"任务执行时长超过 visibility_timeout"是 Redis broker 下最危险的配置？给出一个具体翻车时序。</summary>

worker A 在 t=0 取走任务（时长 30 分钟，visibility_timeout=10 分钟），消息进 unacked hash。t=10 分钟起，任何 worker 的轮询恢复逻辑都会发现这条消息"超时未确认"，把它重新入队；worker B 取走并开始执行。此刻 A、B 在**同时执行同一个任务**：库存被扣两次、文件被写两遍，且直到 A 执行完 ack 前，系统层面没有任何报错——重复是静默的。铁律 visibility_timeout > 最长任务时长；做不到就拆任务或换 RabbitMQ（原生 ack，无超时重投语义）。
</details>

<details><summary>2. acks_late=True 到底买到了什么、付出了什么？为什么说它和 early ack 都不是"恰好一次"？</summary>

买到：worker 半途死亡（kill -9、OOM）时任务不丢——未确认消息会被重新投递。付出：至少一次语义，重复执行成为必须面对的现实（[19-distributed/04 §5](../19-distributed/04-distributed-transactions.md)：exactly-once delivery 不存在，能兑现的只有效果恰好一次）。early ack 是"至多一次"（崩了就丢），acks_late 是"至少一次"（崩了就重）——确认时机只是在丢失与重复之间选边，两全的唯一出路是 at-least-once + 下游幂等（task_id 去重、业务唯一键）。
</details>

<details><summary>3. 同一批 IO 密集任务，prefork -c 4 改成 gevent -c 4 为什么可能没提升，改成 gevent -c 200 才有？什么时候反而不该这么改？</summary>

prefork 的并发单元是进程，4 个进程在同一时刻最多 4 个任务在跑，IO 等待时槽位空转；gevent 的单元是绿色线程，IO 等待时让出给其他协程，所以 -c 4 时 4 个协程依然只能填满 4 个"等待槽"，吞吐与 prefork 差不多；-c 200 才把"等待重叠"的杠杆用起来。不该改的场景：任务是 CPU 密集（协程没有并行能力，还互相卡）；任务里有未 monkey patch 的 C 扩展同步调用（一个卡全体卡）；以及下游承受力不足时——200 并发任务意味着瞬时 200 个下游连接，容量规划要倒推。
</details>

<details><summary>4. LLEN=500 该不该报警？给出你的判断公式与两个反例。</summary>

单独的绝对值没有意义，判断公式是消化时间 = LLEN ÷ 完成速率。反例一：吞吐 100 条/s，LLEN=500 只是 5 秒的浪，报警纯属噪音；反例二：吞吐约 1 条/分钟（如每条任务跑 30 分钟、只有几个并发），LLEN=500 意味着约 8 小时的积压，用户侧早已超时——这才是 P1。所以告警规则应写成"预计消化时长 > N 分钟"（PromQL 上即 backlog / rate(完成计数)，完成计数来自事件或 worker stats 导出），而不是"LLEN > X"。
</details>

<details><summary>5. 为什么 K8s 上 worker 用 CPU 利用率做 HPA 指标会失灵？beat 又为什么绝不能跟着 HPA 扩容？</summary>

worker 的瓶颈通常不在 CPU：IO 密集任务队列积压上万条时，worker 进程都在等网络/数据库，CPU 利用率可能不到 10%，HPA（按 CPU 利用率与 requests 的比值伸缩，见 04-k8s-fundamentals/04 §5）永远不会触发扩容；反过来 CPU 密集任务压测时又可能过扩。正确信号是队列深度——KEDA 的 Redis Lists scaler 或自定义指标（LLEN 导出成 Gauge）。beat 不能进 HPA 的原因：beat 是调度消息的**生产者**而非消费者，队列深度与它无关；且调度必须全局单点，两个 beat 会对同一条 crontab 各发一次消息，所有定时任务翻倍执行——它的 HA 是单副本 + 快速拉起，不是多副本。
</details>

## 延伸阅读

- Celery 官方文档（架构/broker/最佳实践）：https://docs.celeryq.dev/en/stable/
- Celery Redis broker 设置（visibility_timeout 等，版本敏感以此为准）：https://docs.celeryq.dev/en/stable/userguide/configuration.html#redis-backend-settings
- RabbitMQ 官方（AMQP 模型与持久化）：https://www.rabbitmq.com/tutorials/amqp-concepts.html
- flower（Celery 监控）：https://github.com/mher/flower
- KEDA Redis Lists scaler：https://keda.sh/docs/latest/scalers/redis-lists/
