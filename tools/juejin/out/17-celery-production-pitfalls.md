---
title_juejin: Celery 生产踩坑：1000 任务积压与 acks_late 双重执行
title_zhihu: Celery 生产踩坑：1000 任务积压与 acks_late 双重执行
description: 1000任务积压怎么消化、acks_late双重执行的血证（同task_id两个结果文件）、可见性超时不是retries。实测演示每个坑的复现和修复。
category_id: "6809637769959178254"
tags: "Python,后端"
---

# Celery 积压 1000 条、worker 全活着：凌晨两点那晚的三笔账，和 retries 纹丝不动的双执行铁证

凌晨两点，报警群炸了：任务队列积压 1000 条，worker 全活着，CPU 利用率只有 8%。
有人喊"重启大法"，这次没用——问题不在 worker 死没死，而在没人说得清要消化多久。
第二个坑更阴：kill -9 一个 worker，我拿到了同一个 task_id 的两份执行证据。

## 一、先把案发现场搬进实验室

先把账单立在这：队列不是免费的，它把"慢"换成了复杂度——消息可能重复、可能延迟、需要监控积压。本文三个坑全是这笔账单上的项目，凌晨两点那晚，不过是账单到期。

实验台很简单，一台有 Docker 的机器就够。Redis 当 broker，Celery 用 5.x，十分钟搭完：

```bash
# 环境准备：Redis + venv + celery
docker run -d --name celery-redis -p 6392:6379 redis:7-alpine
python3 -m venv ~/venvs/celery
~/venvs/celery/bin/pip install "celery[redis]"
~/venvs/celery/bin/celery --version   # 预期 5.x
```

四个角色先对齐：producer 负责 enqueue，broker 中转消息，worker 消费执行，result backend 存结果——各自独立扩缩。

result backend 是可选件：只关心"丢进队列就算完成"的场景（发通知、刷缓存），建议显式配 task_ignore_result=True，省掉每个任务一次状态写回。

顺带一句选型判断：动作慢（秒级以上）、结果可以晚到、允许重试，就考虑队列；三者缺一就别硬上——代价就是开头那张账单。

任务定义先亮出来，里面两个参数是全文主角：

```python
# tasks.py
from celery import Celery

app = Celery(
    "celerylab",
    broker="redis://127.0.0.1:6392/1",    # 消息走 db1
    backend="redis://127.0.0.1:6392/2",   # 结果走 db2，分开避免互相挤占
    # lab 故意设 10 秒，为了快速看到重投；生产必须大于最长任务时长！
    broker_transport_options={"visibility_timeout": 10},
)
app.conf.update(worker_prefetch_multiplier=1)   # 长任务场景公平分发
```

先记住 visibility_timeout 的语义：worker 取走消息后，消息进 Redis 的 unacked hash；超过这个秒数还没确认，就会被重新投递。两件事以官方文档（docs.celeryq.io）为准：一是参数默认值和写法随版本变化，kombu 5.x 当前的默认值是 3600 秒；二是重投并不掐着表准点发生——kombu 的恢复扫描约每 10 秒才真正执行一批，实际重投延迟 = visibility_timeout + 最多约 10 秒的扫描间隔。这个余量先记着，坑三算去重窗口时要用。

## 二、坑一：1000 条积压，先算账再扩容

积压怎么造？先在 tasks.py 里补一个纯 IO 的慢任务：

```python
# tasks.py 追加：纯 IO 慢任务，睡完即成
import time

@app.task
def slow_task(seconds: float) -> str:
    time.sleep(seconds)
    return f"slept {seconds}s"
```

再写个脚本把 1000 条一口气塞进队列：

```python
# flood.py：批量 enqueue 后立即返回
from tasks import slow_task

handles = [slow_task.apply_async(args=[0.5]) for _ in range(1000)]
print(f"enqueued {len(handles)} slow_task(0.5)")
```

关键动作是"边塞边看"。Redis broker 的队列就是一个 list，key 默认叫 celery，一条命令读深度：

```bash
# 队列深度 = 待处理消息数；注意 broker 在 db1，忘了 -n 1 会一直查 db0
docker exec celery-redis redis-cli -n 1 LLEN celery
# 已取走未确认数 = worker 手里的活，同样值得监控（也在 db1，-n 1 一样不能少）
docker exec celery-redis redis-cli -n 1 HLEN unacked
```

这个小坑卡过我十分钟：忘了 -n 1，LLEN 永远返回 0，差点误判"根本没积压"。完整的峰值记录脚本长这样：

```bash
# backlog_recorder.sh：核心循环，每 2 秒采样一次
PEAK=0
while :; do
  N=$(docker exec celery-redis redis-cli -n 1 LLEN celery | tr -d '[:space:]')
  [ "$N" -gt "$PEAK" ] && PEAK=$N && echo "$N" > backlog-peak.txt
  # 记录过峰值之后首次归零：写下排空时刻
  if [ "$N" -eq 0 ] && [ "$PEAK" -gt 0 ] && [ ! -f backlog-drained.txt ]; then
    date -Iseconds > backlog-drained.txt
  fi
  sleep 2
done
```

跑起来的实况：两个 prefork worker（各 -c 2）在灌入的同时一直消费，LLEN 峰值冲到 600 多就到头，不是 1000。这现象本身就有信息量：峰值不是你 enqueue 了多少条，而是灌入期间速率差的累计——峰值 ≈（灌入速率 − 消化速率）× 灌入时长。

想让峰值更贴近 1000，可以先停掉所有 worker 再 flood，灌完再启动——顺便体会一把"冷启动面对存量积压"的排空观感：LLEN 从 1000 出头近乎线性地匀速下降，没有平时那种边灌边消化、锯齿一样拉锯的波形。

接下来是全文最重要的公式：**消化时间 ≈ LLEN ÷ 完成速率**。当时实测约 8 条/s，600 条一分多钟排空——积压本身不是事故，消化时间才是。LLEN=1000 而吞吐 50 条/s 只是 20 秒的浪；LLEN=100 而吞吐 1 条/s 才是要报警的病。

所以告警阈值别按绝对条数设，按"预计消化时长"设。落地思路：定时 LLEN 导出成 Prometheus Gauge（自研 exporter 或现成 redis_exporter），告警规则写成 backlog 除以完成速率的滑动窗口，超过 N 分钟才触发。

想加速消化，要对症下药。任务是纯 IO（sleep、HTTP 调用、查库），prefork 加进程性价比很低，直接上一个高并发 gevent 实例：

```bash
# IO 密集任务的最对症扩容：绿色线程池
# 注意：gevent 池要单独安装，celery[redis] 不自带，少了它 -P gevent 直接 ImportError
~/venvs/celery/bin/pip install gevent
~/venvs/celery/bin/celery -A tasks worker -P gevent -c 32 -n boost@%h
```

实测消化速率从 8 条/s 跳到 60+ 条/s，一两分钟 LLEN 归零。但注意：-c 32 意味着瞬时可能有 32 个下游连接，容量规划从下游承受力倒推，不是从 worker 野心正推。

这里还叠着一个坑中坑：如果没配 worker_prefetch_multiplier=1（默认是 4），老 worker 会持续占住"并发数 × multiplier"的预留缓冲——本例 2 个老 worker × c2 × 4，最多囤 16 条，消化掉随取随补。深积压时新扩容的 worker 起步就有活干；真正吃亏的是队列浅、灌入慢的涓流阶段——老 worker 的缓冲始终吃得满，新上场的 boost 可能长期抢不到消息。长任务场景老实配 1，让预留只等于并发数，分配才公平。

回到开头那晚，排障三板斧就能区分"没人在干活"与"干不过来"：

```bash
# 排障三板斧
celery -A tasks inspect ping --timeout 2   # worker 活着吗，K8s 存活探针也用它
celery -A tasks inspect active             # 各 worker 正在执行的任务明细
celery -A tasks inspect stats              # 池类型/并发/已处理计数
```

想看任务级事件流可以上 flower（worker 记得加 -E 发事件），但 LLEN 归零那一刻的踏实感，还是 recorder 脚本写进 backlog-drained.txt 的那行时间戳给的。

K8s 同学重点看这段：worker 用 CPU 利用率做 HPA 指标会失灵。IO 密集任务积压上万条时，worker 都在等网络和数据库，CPU 可能不到 10%，HPA 永远不会触发扩容。

正确信号是队列深度。KEDA 的 Redis Lists scaler 原生支持拿 list 长度当伸缩指标，比如目标定为每副本不超过 200 条，Deployment 副本数随 LLEN 自动上下；trigger 字段名随版本演进，以 KEDA 官方文档为准。

## 三、坑二：acks_late 双重执行的铁证

背景知识：acks_late=True 表示"执行完才确认"，worker 半路被杀，任务会被重新投递——所谓"至少一次"。文档看十遍，不如亲手 kill -9 一次。先把话说明白：开头那两份执行证据，来自我复盘那晚事故后做的受控复现——线上偶现、无法重放的坑，最有说服力的打开方式就是把它变成一个随时能重跑的实验。

设计一个"易碎任务"：一进来就把执行证据落盘，然后睡 20 秒，给 kill 留窗口：

```python
# fragile_task：acks_late + 证据落盘
import json, time
from datetime import datetime, timezone
from pathlib import Path

ACKS = Path(__file__).parent / "acks"
ACKS.mkdir(exist_ok=True)          # 证据目录，落盘全靠它

@app.task(bind=True, acks_late=True)
def fragile_task(self):
    # 编号 = 该 task_id 已有的 attempt 文件数 + 1（为什么不用 retries，下一节说）
    attempt = len(list(ACKS.glob(f"{self.request.id}.attempt*"))) + 1
    (ACKS / f"{self.request.id}.attempt{attempt}.txt").write_text(
        json.dumps({"task": "fragile", "task_id": self.request.id,
                    "attempt": attempt,
                    "ts": datetime.now(timezone.utc).isoformat()}))
    time.sleep(20)
    return "done"
```

开演。起一个专用 victim worker（单并发、只消费 acks 队列），投一条任务并记下 task_id：

```bash
# 终端 1：victim 就位
~/venvs/celery/bin/celery -A tasks worker -c 1 -n victim@%h -Q acks &

# 终端 2：enqueue 并记录 task_id
~/venvs/celery/bin/python -c "
from tasks import fragile_task
r = fragile_task.apply_async(queue='acks')
print(r.id, file=open('dup-task-id.txt', 'w'))"

sleep 3                      # victim 已取走任务、写完 attempt1、正在 sleep
pkill -9 -f 'victim@'        # 杀！父进程子进程一并 -9
ls acks/                     # 此刻只有 <task_id>.attempt1.txt
```

然后立刻起一个替代 worker 接管 acks 队列（名字换 survivor），静静等 45~60 秒。时间线推演如下：

```text
t=0      victim 取走消息（进 unacked hash），写 attempt1，开始 sleep(20)
t=3      kill -9 victim —— 没机会确认，消息滞留在 unacked
t≈10~20  survivor 侧的恢复扫描发现消息超过 visibility_timeout(10s)，
         重新入队并取走，写 attempt2（扫描约每 10 秒一批，见第一节）
t≈30~40  survivor 跑完并确认；acks/ 下同一 task_id 两个文件
```

验收时刻：cat 两个文件，task_id 完全相同，attempt 分别是 1 和 2，时间戳相差约 10~20 秒。这就是"双重执行"的铁证——不是靠日志推测，是 cat 得出来的两份落盘文件。

对照组同样重要：把 acks_late 去掉（默认早确认，收到任务就 ack），重做一遍，kill 之后 survivor 永远等不到消息——任务直接丢了，acks/ 里只剩 attempt1 一个孤儿文件。

所以 acks_late 的本质是：用"可能重复"换"不会丢失"。早确认是"至多一次"（崩了就丢），晚确认是"至少一次"（崩了就重），确认时机只是在丢与重之间选边站，没有两全。

这也是分布式系统的老实话：投递层面的"恰好一次"不存在，任何 ack 时机都给不了"不丢且不重"。工程上能兑现的只有 at-least-once 加下游幂等，认了这个前提，后面的设计才立得住。

运维上的推论很直接：acks_late 把故障从"丢任务"变成了"重任务"。丢任务用户会投诉没收到，重任务用户也会投诉收到两次——后者更难查，因为它静默，日志里全是成功的绿色。

补一个配套参数：task_reject_on_worker_lost 默认 False，想让 worker 进程被杀时任务立即 requeue，要显式设为 True。注意它只在 acks_late=True 时生效——早确认模式下消息在执行前就已 ack，这个参数设了也无效。而 kill -9 掉整个 worker（父进程也死）时，Redis broker 下的重投靠的就是可见性超时恢复机制。

## 四、坑三：可见性超时不是 retries

第一版代码我给证据文件编号用的是 self.request.retries + 1，结果 attempt2 永远不出现。debug 半天才发现：第二次执行算出的编号还是 attempt1，把第一次的证据直接覆盖了——证据永远凑不齐两个。

先看什么才是"真重试"。lab 里另有一个故意失败的任务，第一次执行主动调 self.retry()，3 秒后重投、第二次成功：

```python
# flaky_task：主动重试才递增 retries（ACKS、json 沿用上文 fragile_task 的定义）
@app.task(bind=True, max_retries=3)
def flaky_task(self):
    (ACKS / f"{self.request.id}.retry.txt").write_text(
        json.dumps({"task": "flaky", "task_id": self.request.id,
                    "retries": self.request.retries}))
    if self.request.retries < 1:
        raise self.retry(countdown=3)   # RETRY 状态，3 秒后重投
    return "ok-after-retry"             # 第二次进来 retries 已经是 1
```

这条链路里 retries 老老实实从 0 变 1，落盘文件里能清楚看到 "retries": 1。但 kill -9 场景的重投，retries 纹丝不动——同样是"任务又跑了一遍"，底层是两条完全不同的路径。

根因一句话：**可见性超时的重投不递增 retries**。retries 是任务体内的应用层概念，只有 self.retry() 会加一；超时重投是 broker 层的恢复机制，任务代码完全感知不到。两者是两套互不相干的机制。

这个认知偏差在生产里是个监控盲区：你在 flower 里看到一条任务 retries=0，它却可能已经被执行过两次——重试计数器根本没动过。想统计真实执行次数，得在任务侧自己记账（文件计数、去重表自增列都行）。

第二层含义更危险：任务执行时长一旦超过 visibility_timeout，还在正常执行的消息也会被判"超时"而重投——两个 worker 同时执行同一条任务，库存扣两次、文件写两遍。而且直到先跑完的那个 ack 之前，系统层面没有任何报错，重复是静默的。

修复就一句话：**visibility_timeout 必须大于最长任务的执行时间（含重试链）**。做不到就拆短任务，或者换 RabbitMQ——原生 AMQP ack，连接断开才重投，没有"超时抢走"的语义。但别把它当免死金牌：RabbitMQ ≥3.8.15 默认开启 consumer_timeout（30 分钟），消费者超过这个时长没 ack，服务端会关闭 channel 并 requeue 未确认消息——超长任务换过去照样重投，只是伴随连接错误日志、不再完全静默而已，该调大还得调大，该拆短还得拆短。参数写法版本敏感，以官方文档为准。

拆任务的具体做法：按阶段拆成任务链（chain/chord），或把超长批处理切片成 N 条子任务投递，单条执行时间压到分钟级，重投窗口的影响自然就小了。

光调参还不够，第三道保险是幂等。task_id 就是现成的消息 ID，消费侧以 (task_name, task_id) 建去重键，重投进来的第二次命中去重、直接返回：

```python
# 幂等兜底：SET NX EX 短窗口去重
if redis.set(f"dedup:{task_name}:{task_id}", 1, nx=True, ex=7200):
    do_side_effect()      # 副作用只发生一次
else:
    return "skipped"      # 重投的第二次执行，直接跳过
```

去重窗口必须覆盖"最长重投延迟"——visibility_timeout，加最多约 10 秒的扫描间隔，再加重试链——设太短等于没设。能落库的场景优先用业务唯一键（UNIQUE KEY 加 INSERT IGNORE），跨系统用消息 ID 去重表。

## 五、把坑收敛成生产检查项

回到凌晨两点那晚——如果重来一次，下面五条检查项就是当时的答案；三个坑收拢成五条，也是这篇文章的收网。

**检查项 1：告警按消化时长设。**导出 LLEN 成指标，规则写成"预计消化时长 > N 分钟"，而不是"LLEN > X"。再配一条 unacked 数量的监控，两者合起来才能回答"堵在队列里还是卡在 worker 手里"。

**检查项 2：按"会被执行两次"做设计。**所有配了 acks_late 或重试的任务，发短信要去重、扣款要幂等、写文件先写临时名再原子 rename。所有"应该不会重复"的假设，都会在第一次静默双跑时重新定价。

**检查项 3：超时与重试三件套。**每个任务都要有 time_limit，重试要指数退避。一份够用的配置模板如下：

```python
# 重试三件套 + 双超时
@app.task(
    bind=True,
    autoretry_for=(ConnectionError,),   # 只重试瞬时故障
    retry_backoff=True,                 # 间隔 1s/2s/4s/8s...
    retry_backoff_max=600,              # 退避上限
    retry_jitter=True,                  # 抖动，防重试风暴同相
    max_retries=5,
    soft_time_limit=280,                # 软超时：先抛异常给任务善后
    time_limit=300,                     # 硬超时：到点 SIGKILL 兜底
)
def sync_inventory(sku: str) -> None:
    resp = requests.put(f"http://inventory:8000/stock/{sku}",
                        timeout=(3, 10))   # 连接 3s、读 10s，显式超时
    resp.raise_for_status()
```

两条纪律：重试只救瞬时故障，参数错误重试一万次也还是错，非瞬时异常别放进 autoretry_for；外部调用客户端必须显式 timeout，一个下游抖动冻结一串 worker 的事故太常见了。

**检查项 4：快慢队列隔离。**队列按耗时拆分（fast/slow），worker 用 -Q 分队列消费，各自独立扩缩。快任务被慢任务堵死（队头阻塞）是积压最常见的根因之一。

```bash
# 队列拆分：快慢隔离，各自独立扩缩
celery -A tasks worker -n fast@%h -Q celery_fast -c 8
celery -A tasks worker -n slow@%h -Q celery_slow -c 2 --prefetch-multiplier 1
```

**检查项 5：beat 只跑一个实例。**如果用了 beat 做定时调度，确保全局只有一个实例。K8s 上它绝不能跟着队列深度扩容——两个 beat 会对同一条调度表各发一次消息，所有定时任务翻倍执行，静默程度比 acks_late 还高。

## 结尾：今晚就能做的三件事

第一，grep 你们的 Celery 配置里的 visibility_timeout，和线上最长任务的 P99 执行时长比一比——任务时长超过它，就是定时炸弹，随时可能静默双跑。

第二，检查 worker_prefetch_multiplier。长任务场景不是 1 就改成 1，否则队列一浅、灌入一慢，扩容的 worker 就可能长期抢不到活，你以为加了机器，其实加了寂寞。

第三，在预发环境做一次 kill -9 演练。任务带 acks_late、证据落盘，亲手拿一次同 task_id 双执行的铁证。团队里每个人都看过这份铁证之后，"幂等设计"就不再是嘴上说说。

第三件事不想从零搭环境？这三个坑的完整实验整理在我维护的 [sre-learning-hub](https://github.com/Thneoly/sre-learning-hub) 仓库的 lab 03 里：从环境搭建到 8 项验收点全部通过（附 check.sh 自动判分脚本，8 项判分点全过才算复现成功），含全部产物文件，照着敲一遍就能复现本文所有现象。

讲义里还有正文没篇幅展开的增量：RabbitMQ 迁移对比、flower 部署实战、完整反模式清单和全部判分验收脚本。

今晚就 kill -9 一次：十分钟，跑出你自己的那份双执行铁证。
