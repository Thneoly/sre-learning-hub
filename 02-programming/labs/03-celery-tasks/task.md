# Lab 03 · Celery 任务队列：积压、消化与重复执行实证

> 难度：★★☆ ｜ 考点：02-programming/06（broker/worker/acks_late/积压监控） ｜ 前置：`02-programming/03-python-for-ops.md`（venv）、`03-docker` 基础 ｜ 预计 60 分钟

## 场景

你接手了一套跑在 VM 上的批处理服务：白天 Web 侧不断把"慢任务"丢给 Celery，夜里定时报表也要走同一条队列。上一任留下的只有一句话——"队列偶尔堵，重启 worker 就好"。你要在实验环境里把这套系统的行为完整复现一遍并留下证据：先让它正常跑（单 worker/双 worker 的分发），再人为制造一次 1000 条的积压并观察消化，最后做一次"杀 worker"演练，亲手证明 `acks_late` 意味着同一条任务会被执行两次。全程证据落盘，check.sh 只认文件与 Redis 状态。

所有文件做在本 lab 目录（与 check.sh 同级）：`tasks.py`、`producer.py`、`flood.py`、`backlog_recorder.sh`，证据目录 `results/`、`acks/`，记录文件 `backlog-peak.txt`、`backlog-drained.txt`、`dup-task-id.txt`。

## 任务清单

1. **环境准备（VM 上 docker 起 Redis + venv 装 celery）**
   ```bash
   # [任意节点] Redis 作为 broker/结果后端（宿主机 6392，避开已有实例）
   docker run -d --name celery-redis -p 6392:6379 redis:7-alpine
   docker exec celery-redis redis-cli PING          # 预期 PONG

   # [任意节点] venv + celery（直连不行就走代理或清华源）
   python3 -m venv ~/venvs/celery
   ~/venvs/celery/bin/pip install -U pip
   ~/venvs/celery/bin/pip install "celery[redis]" \
     || ~/venvs/celery/bin/pip install -i https://pypi.tuna.tsinghua.edu.cn/simple "celery[redis]"
   ~/venvs/celery/bin/celery --version              # 预期 5.x
   ```

2. **定义任务集（`tasks.py`）**，broker 用 `redis://127.0.0.1:6392/1`、backend 用 db2，并满足：
   - `broker_transport_options={"visibility_timeout": 10}`（第 6 步 kill 演示要在 10 秒内看到重投；生产中它必须大于最长任务时长，见第 06 章第 3 节）。
   - `fast_task(n)`：立即把 JSON（含 task_id、host、时间戳）写入 `results/fast-<task_id>.json`。
   - `flaky_task()`：第一次执行必失败，`self.retry(countdown=3)` 后第二次成功，结果写 `results/flaky-<task_id>.json`（记录 retries 次数）——验证重试链路。
   - `slow_task(duration)`：sleep 后写 `results/slow-<task_id>.json`——积压制造的主角。
   - `fragile_task()`：`acks_late=True`，**一进任务就**把本次执行证据写到 `acks/<task_id>.attempt<N>.txt`（N = 该 task_id 已有的 attempt 文件数 + 1。**不要**用 `self.request.retries + 1` 编号：可见性超时的重投不递增 retries——只有 `retry()` 才递增——按 retries 编号会让重投的第二次执行覆盖 attempt1，永远凑不出两个文件），然后 `time.sleep(20)`。
   - 结果 JSON 统一含 `task`、`task_id`、`host`、`ts` 字段。

3. **单 worker 跑通（`producer.py`）**：enqueue 3 个 fast、1 个 flaky、2 个 slow(1.0)，`.get(timeout=60)` 等全部结果；跑完后 `results/` 下 ≥ 6 个 JSON。
   ```bash
   # [任意节点] 终端 1（在 lab 目录）
   ~/venvs/celery/bin/celery -A tasks worker -c 2 -n w1@%h --loglevel=INFO
   # [任意节点] 终端 2
   ~/venvs/celery/bin/python producer.py
   ```

4. **双 worker 观察分发**：另开终端再起 `worker -n w2@%h -c 2`，重跑 `producer.py`；用结果 JSON 里的 `host`/worker 日志确认任务分给了两个 worker。

5. **制造 1000 积压并记录（`flood.py` + `backlog_recorder.sh`）**：
   - `flood.py` 批量 `slow_task.apply_async(args=[0.5])` enqueue 1000 条后立即返回。
   - `backlog_recorder.sh` 每 2 秒 `docker exec celery-redis redis-cli -n 1 LLEN celery`（broker 在 **db 1**，不带 `-n 1` 会一直查 db 0 读到 0），把见过的最大值写入 `backlog-peak.txt`；观察到"曾有峰值后归零"时把 0 与时间戳写入 `backlog-drained.txt`。
   - 先起 recorder，再 flood，看着 LLEN 冲上去；期间可开 flower（`~/venvs/celery/bin/celery -A tasks flower`，浏览器 5555 端口）或盯 worker 日志观察任务流入。
   - **加速消化**：新开 worker（`-c 4`）或直接起一个 `-P gevent -c 32` 的高并发实例，等 `backlog-drained.txt` 出现、`LLEN celery` 归零。

6. **acks_late 重复执行实证**：
   - 起专用 victim worker：`celery -A tasks worker -n victim@%h -c 1 -Q acks`。
   - enqueue：`fragile_task.apply_async(queue='acks')`，把返回的 task_id 写进 `dup-task-id.txt`。
   - 约 3 秒后（任务正在 sleep）`pkill -9 -f 'victim@'` 杀掉它；紧接着起替代 worker（同样 `-Q acks`，名字换 `survivor@%h`）。
   - 等待约 30 秒：可见性超时（10s）到点后消息被重新投递，survivor 再次执行同一条任务。验收：`acks/` 下出现 **两个文件、同一个 task_id、attempt1 与 attempt2**——重复执行落盘成证据。
   - 对照理解：若 `fragile_task` 不带 `acks_late`（默认早确认），kill 后这条任务只会消失，不会有第二份证据。

7. **收尾自查**（保持 redis 容器与全部产物文件不动，跑判分）：
   ```bash
   # [任意节点]
   bash check.sh        # 预期 SCORE: 8/8
   ```

## 验收标准

- `docker ps` 可见 `celery-redis` 处于 Running，`redis-cli PING` 返回 PONG。
- `results/` 下有 ≥ 6 个结果 JSON，其中 `flaky-*.json` 记录了 `retries >= 1`。
- `backlog-peak.txt` 存有一个 ≥ 100 的 LLEN 峰值数值；`backlog-drained.txt` 记录了归零时刻。
- `dup-task-id.txt` 里的 task_id 在 `acks/` 下恰好对应 attempt1/attempt2 两个证据文件。
- 在本目录运行 `bash check.sh`，得到 `SCORE: 8/8`。

## 提示（卡住再看）

<details><summary>提示 1：flaky_task 怎么"第一次必失败、第二次成功"？</summary>

用绑定任务的 `self.request.retries`（第几次重试，首次执行为 0）：
```python
@app.task(bind=True, max_retries=3)
def flaky_task(self):
    if self.request.retries < 1:
        raise self.retry(countdown=3)   # 3 秒后重投
    _dump(..., {"task": "flaky", "retries": self.request.retries})
```
retry 抛出的异常会让本次执行以 RETRY 状态挂起，到点后消息重新入队，第二次进来 `retries` 已是 1，走成功分支。
</details>

<details><summary>提示 2：kill 之后的重投为什么等 10 秒才发生，而不是立刻？</summary>

victim 是被 `kill -9` 的，没机会确认也没机会 reject；这条消息停在 Redis 的 `unacked` hash 里，对其他 worker 不可见。替代 worker 的轮询恢复逻辑每次会检查"unacked 超过 visibility_timeout（本 lab 设 10s）的消息"并重新入队——所以时间线是：t=0 取走、t=3 被杀、t≈10 超时重投、survivor 接手。这正是第 06 章讲的"可见性超时"语义：它既是故障恢复机制，也是任务超过它就会被重复执行的陷阱来源。
</details>

<details><summary>提示 3：flood 之后 LLEN 没到 1000 就开始掉？</summary>

正常现象：enqueue 的同时两个 worker 一直在消费（每秒约 4 条），LLEN 峰值 ≈ 1000 − enqueue 期间已消化的数量。判分只要求峰值 ≥ 100。想让峰值更接近 1000，先把两个 worker 停掉、flood 完再启动（还能顺便体会"冷启动面对存量积压"的排空过程）。
</details>

<details><summary>提示 4：backlog_recorder.sh 怎么判断"消化完成"？</summary>

维护一个 `PEAK` 变量：每次读到的 LLEN 比它大就覆盖写入 `backlog-peak.txt`；一旦 `PEAK > 0` 且当前 LLEN 为 0，说明经历了"有积压→清零"的完整过程，把 0 和时间戳写进 `backlog-drained.txt`。注意用 `tr -d '[:space:]'` 清理 redis-cli 输出的空白，避免字符串比较出错。
</details>
