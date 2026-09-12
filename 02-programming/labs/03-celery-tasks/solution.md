# Lab 03 解答 · Celery 任务队列：积压、消化与重复执行实证

对应任务：[task.md](./task.md)。每步给出"做什么 + 为什么 + 验证输出"。全程在装有 Docker 的 Ubuntu VM 上进行，命令标注 `[任意节点]`，所有文件放在 lab 目录。

## 步骤 0：环境准备

```bash
# [任意节点] Redis 作 broker/结果后端
docker run -d --name celery-redis -p 6392:6379 redis:7-alpine
docker exec celery-redis redis-cli PING
# 预期: PONG

# [任意节点] venv 装 celery（直连超时就切清华源；有代理则配 pip 代理）
python3 -m venv ~/venvs/celery
~/venvs/celery/bin/pip install -U pip
~/venvs/celery/bin/pip install "celery[redis]" \
  || ~/venvs/celery/bin/pip install -i https://pypi.tuna.tsinghua.edu.cn/simple "celery[redis]"
~/venvs/celery/bin/celery --version
# 预期: 5.x
```

为什么：broker 与 result backend 是两个独立角色（第 06 章三角架构），本 lab 用同一个 Redis 实例的不同 db（1 与 2）承担，互不挤占。6392 端口错开机器上可能已有的 Redis。

## 步骤 1：tasks.py —— 任务集与证据落盘

```python
# [任意节点] tasks.py
#!/usr/bin/env python3
"""celerylab: 快/失败重试/长 三类任务 + acks_late 重复执行演示。"""
import json
import socket
import time
from datetime import datetime, timezone
from pathlib import Path

from celery import Celery

BROKER = "redis://127.0.0.1:6392/1"
BACKEND = "redis://127.0.0.1:6392/2"
LAB = Path(__file__).resolve().parent
RESULTS = LAB / "results"
ACKS = LAB / "acks"

app = Celery(
    "celerylab",
    broker=BROKER,
    backend=BACKEND,
    # 可见性超时: unacked 消息超过该秒数未确认即被重新投递。
    # lab 故意设 10s 让 kill 演示快速出结果; 生产必须 > 最长任务时长!
    broker_transport_options={"visibility_timeout": 10},
)
app.conf.update(
    worker_prefetch_multiplier=1,   # 长任务场景公平分发, 新 worker 立刻能接到活
    result_expires=3600,
    timezone="UTC",
    enable_utc=True,
)


def _dump(folder: Path, name: str, payload: dict) -> None:
    """把一次执行的证据写成 JSON 文件——lab 的判分只认落盘。"""
    folder.mkdir(parents=True, exist_ok=True)
    payload.update(ts=datetime.now(timezone.utc).isoformat(),
                   host=socket.gethostname())
    (folder / name).write_text(json.dumps(payload, ensure_ascii=False, indent=2))


@app.task(bind=True)
def fast_task(self, n: int) -> int:
    _dump(RESULTS, f"fast-{self.request.id}.json",
          {"task": "fast", "task_id": self.request.id, "n": n})
    return n * 2


@app.task(bind=True, max_retries=3)
def flaky_task(self) -> str:
    if self.request.retries < 1:          # 首次执行必失败, 3s 后重投
        raise self.retry(countdown=3)
    _dump(RESULTS, f"flaky-{self.request.id}.json",
          {"task": "flaky", "task_id": self.request.id,
           "retries": self.request.retries})
    return "ok-after-retry"


@app.task(bind=True)
def slow_task(self, duration: float = 0.5) -> str:
    time.sleep(duration)
    _dump(RESULTS, f"slow-{self.request.id}.json",
          {"task": "slow", "task_id": self.request.id, "duration": duration})
    return f"slept {duration}"


@app.task(bind=True, acks_late=True)
def fragile_task(self) -> str:
    # 一进任务就落盘"本次执行"证据, 再睡 20s——中途被 kill 会留下半份证据。
    # 编号取"该 task_id 已有 attempt 文件数 + 1": 可见性超时的重投不递增
    # retries(只有 retry() 才递增), 按 retries 编号第二次执行会覆盖 attempt1
    attempt = len(list(ACKS.glob(f"{self.request.id}.attempt*"))) + 1
    _dump(ACKS, f"{self.request.id}.attempt{attempt}.txt",
          {"task": "fragile", "task_id": self.request.id, "attempt": attempt})
    time.sleep(20)
    return "done"
```

为什么：`worker_prefetch_multiplier=1` 关掉预取囤货，后面"加 worker 加速消化"才能立刻见效；`fragile_task` 把证据写在 sleep **之前**，保证被 kill 的那次执行也留下文件；attempt 编号按已有证据文件数计数——重投(可见性超时恢复)**不会**递增 `self.request.retries`，若按 `retries + 1` 编号，重投进来的第二次执行算出的仍是 attempt1 并覆盖第一次的证据，`acks/` 里永远只有一个文件；按文件计数，第二次执行看到 attempt1 已存在，自然写出 attempt2。

## 步骤 2：producer.py —— 单 worker 跑通

```python
# [任意节点] producer.py
#!/usr/bin/env python3
"""enqueue 一批任务并等待全部结果, 统计结果文件数。"""
import time
from pathlib import Path

from tasks import RESULTS, fast_task, flaky_task, slow_task


def main() -> None:
    RESULTS.mkdir(exist_ok=True)
    jobs = [fast_task.delay(i) for i in range(3)]
    jobs.append(flaky_task.delay())
    jobs += [slow_task.delay(1.0) for _ in range(2)]
    for r in jobs:
        print(r.get(timeout=60))
    time.sleep(1)                                   # 等最后一个文件落盘
    n = len(list(RESULTS.glob("*.json")))
    print(f"result files: {n}")
    assert n >= 6, "结果文件不足 6 个"


if __name__ == "__main__":
    main()
```

```bash
# [任意节点] 终端 1（lab 目录）
~/venvs/celery/bin/celery -A tasks worker -c 2 -n w1@%h --loglevel=INFO
# 预期: startup banner 出现 [tasks] 列表(4 个任务), ready 提示

# [任意节点] 终端 2
~/venvs/celery/bin/python producer.py
# 预期: 0 / 2 / 4 / ok-after-retry / slept 1.0 / slept 1.0, 最后 result files: 6
ls results/
# 预期: 3 个 fast-*.json + 1 个 flaky-*.json + 2 个 slow-*.json
cat results/flaky-*.json | grep retries
# 预期: "retries": 1   ← flaky 首次失败、3 秒后重投成功的证据
```

为什么先单 worker：把"任务定义正确、broker 通、结果能落盘"这条最小链路打通，再叠加变量（多 worker、积压、kill），出问题时才能定位是哪一层引入的。

## 步骤 3：双 worker 观察分发

```bash
# [任意节点] 终端 3 再起一个 worker
~/venvs/celery/bin/celery -A tasks worker -c 2 -n w2@%h --loglevel=INFO
# [任意节点] 终端 2 重跑
~/venvs/celery/bin/python producer.py
```

验证分发：两个 worker 终端交替出现 `Task ... received` / `succeeded` 日志；`celery -A tasks inspect ping` 能列出 `w1@<host>` 与 `w2@<host>` 两个应答。同机双 worker 时结果 JSON 的 `host` 相同，区分靠 worker 名（日志）而不是 host——这也解释了为什么结果文件里额外记 worker 名/日志比只看文件更有说服力。

```bash
# [任意节点] 健康检查视角
~/venvs/celery/bin/celery -A tasks inspect ping --timeout 2
# 预期: 2 个节点各回 -> pong (ok)
```

## 步骤 4：制造 1000 积压

```bash
# [任意节点] backlog_recorder.sh（chmod +x）
#!/usr/bin/env bash
# 轮询 LLEN, 记录峰值与"曾有峰值后归零"
set -u
Q=${1:-celery}
PEAK=0
while :; do
  N=$(docker exec celery-redis redis-cli -n 1 LLEN "$Q" 2>/dev/null | tr -d '[:space:]')
  [ -z "$N" ] && N=0
  echo "$(date -Is) LLEN=$N"
  if [ "$N" -gt "$PEAK" ]; then
    PEAK=$N
    echo "$N" > backlog-peak.txt
  fi
  if [ "$PEAK" -gt 0 ] && [ "$N" -eq 0 ]; then
    echo "$(date -Is) LLEN=0 (peak=$PEAK)" > backlog-drained.txt
  fi
  sleep 2
done
```

```python
# [任意节点] flood.py
#!/usr/bin/env python3
"""批量 enqueue 慢任务, 制造积压。用法: flood.py [count]"""
import sys

from tasks import slow_task


def main() -> None:
    count = int(sys.argv[1]) if len(sys.argv) > 1 else 1000
    handles = [slow_task.apply_async(args=[0.5]) for _ in range(count)]
    print(f"enqueued {len(handles)} slow_task(0.5)")
    print("first task_id:", handles[0].id)


if __name__ == "__main__":
    main()
```

```bash
# [任意节点] 终端 4 先起 recorder
chmod +x backlog_recorder.sh && ./backlog_recorder.sh
# [任意节点] 终端 2 flood
~/venvs/celery/bin/python flood.py 1000
# 预期: enqueued 1000 slow_task(0.5)

# [任意节点] 终端 5 观察（可选: flower）
~/venvs/celery/bin/pip install flower
~/venvs/celery/bin/celery -A tasks flower --port=5555
# 浏览器 http://<host>:5555 可看任务流速与成功率
```

预期：recorder 滚动输出 `LLEN=` 快速上涨——两个 worker、共 4 个并发、每条 0.5s，理论消化速率约 8 条/s，而 enqueue 更快，于是积压堆到数百（上限 1000 − enqueue 期间已消化数）。`cat backlog-peak.txt` 应见一个 ≥ 100 的数值。这一步同时验证了第 06 章的判断：**积压本身不是事故，消化时间才是**——此刻 LLEN 很大，但按 8 条/s 算约一两分钟排空。

## 步骤 5：加速消化

```bash
# [任意节点] 终端 6：IO 密集(纯 sleep)任务用高并发 gevent worker 最对症
~/venvs/celery/bin/celery -A tasks worker -P gevent -c 32 -n boost@%h --loglevel=INFO
```

预期：消化速率跳到约 60+ 条/s（32 协程 × 每 2 条/s），LLEN 一两分钟内归零；recorder 在归零时写出 `backlog-drained.txt`（内容形如 `2026-09-12T10:41:33+00:00 LLEN=0 (peak=613)`）。期间新 worker 能立刻接到活，得益于步骤 1 的 `worker_prefetch_multiplier=1`——若保持默认 4，老 worker 会先囤走 4 倍消息，boost 白等。

## 步骤 6：acks_late 重复执行实证

```bash
# [任意节点] 终端 7：专用 victim，只消费 acks 队列
~/venvs/celery/bin/celery -A tasks worker -c 1 -n victim@%h -Q acks --loglevel=INFO

# [任意节点] 终端 2：enqueue 并记下 task_id
~/venvs/celery/bin/python -c "
from tasks import fragile_task
r = fragile_task.apply_async(queue='acks')
print(r.id, file=open('dup-task-id.txt', 'w'))
print('task_id:', r.id)"
# 预期: task_id: <uuid>

sleep 3   # 等 victim 取走任务、attempt1 文件已写出、任务正在 sleep(20)
pkill -9 -f 'victim@'          # 杀掉 victim（父进程与子进程一并 -9）
ls acks/                       # 此刻只有 <task_id>.attempt1.txt —— 第一次执行的证据

# [任意节点] 立刻起替代 worker 接管 acks 队列
~/venvs/celery/bin/celery -A tasks worker -c 1 -n survivor@%h -Q acks --loglevel=INFO
```

时间线推演（对应第 06 章第 3/5 节）：

```
t=0    victim BRPOP 取走消息(进 unacked hash, acks_late=执行完才确认), 写 attempt1, 开始 sleep(20)
t=3    kill -9 victim —— 无确认、无 reject, 消息滞留在 unacked
t≈10   survivor 的轮询恢复逻辑发现该消息超过 visibility_timeout(10s), 重新入队
t≈10+  survivor 取走, 写 attempt2, 再睡 20s
t≈30   survivor 执行完 ack; acks/ 下同一 task_id 两个文件
```

验证与判分要点：

```bash
# [任意节点]
cat dup-task-id.txt
ls acks/
# 预期: <task_id>.attempt1.txt 与 <task_id>.attempt2.txt 两个文件
cat acks/*.attempt1.txt acks/*.attempt2.txt
# 预期: 两个 JSON, task_id 相同、attempt 分别为 1/2、ts 相差约 7~10s
```

对照理解：把 `fragile_task` 的 `acks_late=True` 去掉重做一遍，kill 后 survivor 永远等不到消息（早确认模式下 kill 即丢任务），`acks/` 只有一个文件——**acks_late 用"可能重复"换"不会丢失"**（第 06 章第 5 节）。同时注意本 lab 的 `visibility_timeout=10` 故意小于任务时长 20s：生产中这本身就是重复执行的隐患来源，正确姿势是让它大于最长任务，重投只留给"worker 真死了"的场景。

## 步骤 7：判分

```bash
# [任意节点] 保持 celery-redis 运行与产物文件原样
bash check.sh
```

预期输出：

```
PASS: redis 容器 celery-redis 处于 Running
PASS: broker 可达: redis-cli PING -> PONG (当前 LLEN celery=0)
PASS: tasks.py 定义了快/失败重试/长/acks_late 四类任务及 visibility_timeout
PASS: results/ 下有 6 个结果文件 (>= 6)
PASS: flaky 任务结果记录了 retries >= 1 (重试链路生效)
PASS: 积压峰值已记录: LLEN 峰值 = 613 (>= 100)
PASS: 消化清零已记录: 2026-09-12T10:41:33+00:00 LLEN=0 (peak=613)
PASS: 重复执行证据成立: task_id=... 存在 attempt1/attempt2 两份文件
----------------------------------------
SCORE: 8/8
```

（峰值为示例数值，以实际记录为准；只要 ≥ 100 即 PASS。）

收尾（判分通过后再做）：停掉所有 worker、flower 与 recorder（Ctrl+C），实验数据留在 `results/`、`acks/` 备查；如需彻底清理 `docker rm -f celery-redis`——注意清理后 check.sh 的 T1/T2 将不再通过。

## 常见卡点

| 现象 | 原因 | 处理 |
|---|---|---|
| worker 起不来，报连接拒绝 | redis 容器没起 / 端口写错 | `docker ps` + `redis-cli -p 6392 PING` 先通再起 worker |
| flood 后 LLEN 一直 0 | enqueue 抛错（broker 配置）/ 队列名不一致 | 看 flood.py 输出是否报错；队列名统一用默认 `celery` |
| kill 后没有 attempt2 | survivor 没起或起晚了、visibility_timeout 未生效 | kill 后**立刻**起 survivor；确认 tasks.py 里 `broker_transport_options` 写在 `Celery(...)` 构造参数里 |
| attempt2 迟迟不出现 | unacked 恢复由存活 worker 的轮询驱动 | 确认 survivor 在跑且 `-Q acks`；最多等到 visibility_timeout + 数秒 |
| producer 卡在 `.get(timeout=60)` | worker 没起 / 任务定义未注册 | worker 日志找 `received`；确认在 lab 目录起 worker（能 import tasks） |
