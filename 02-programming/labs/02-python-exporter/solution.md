# Lab 02 · 参考实现与讲解

> 本文给出 `ops_exporter.py` 的完整参考实现，并逐段说明设计取舍。先自己写完、跑过 check.sh 再来对照。

## 总体设计

```
ops_exporter.py
 ├─ 指标注册（模块级全局对象，prometheus_client 默认 REGISTRY 自动收集）
 │    ├─ 系统指标: host_cpu_load1 / host_mem_available_bytes / host_disk_free_bytes{mount}
 │    └─ 业务指标: app_requests_total{route} / app_queue_depth{queue}
 │                 / app_request_duration_seconds (Histogram)
 ├─ collect_system()     主循环每 5s 调一次，解析 /proc 与 statvfs 后 .set()
 ├─ simulate_traffic()   后台 daemon 线程，每 0.2s 产生一次模拟请求
 └─ main()               start_http_server(9877) → 主循环刷新系统指标
```

关键取舍：exporter 的本质是**把"当前状态"翻成 exposition 文本**。系统指标是"拉"模型——每次刷新时从 /proc 读；业务指标是"推"模型——Counter/Gauge 的值在事件发生时更新，`/metrics` 被抓取时只是序列化快照。`start_http_server` 自带一个后台 HTTP 线程，主线程绝不能退出，所以主循环 `while True` 常驻。

## 完整脚本

```python
# [任意节点] 文件: ops_exporter.py（python3 ops_exporter.py 运行）
#!/usr/bin/env python3
"""ops_exporter.py - 自定义 Prometheus exporter

采集 /proc 系统指标 + 模拟业务指标，在 9877 端口暴露 /metrics。
"""
import os
import random
import threading
import time

from prometheus_client import Counter, Gauge, Histogram, start_http_server

PORT = int(os.environ.get("OPS_EXPORTER_PORT", "9877"))

# ---------- 系统指标（解析 /proc 与 statvfs，单位遵循 Prometheus 惯例） ----------
CPU_LOAD1 = Gauge("host_cpu_load1", "1-minute load average, from /proc/loadavg")
MEM_AVAILABLE = Gauge("host_mem_available_bytes", "MemAvailable in bytes, from /proc/meminfo")
DISK_FREE = Gauge("host_disk_free_bytes", "Free bytes on a filesystem", ["mount"])

# ---------- 业务指标（模拟流量） ----------
ROUTES = ("/api", "/login", "/health")
REQUESTS = Counter("app_requests_total", "Simulated total requests", ["route"])
QUEUE_DEPTH = Gauge("app_queue_depth", "Simulated work queue depth", ["queue"])
REQUEST_LATENCY = Histogram(
    "app_request_duration_seconds",
    "Simulated request latency in seconds",
    buckets=(0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0),
)


def collect_system():
    """刷新系统指标，由主循环每 5 秒调用一次。"""
    with open("/proc/loadavg", encoding="ascii") as f:
        # 格式: "0.52 0.58 0.59 1/487 12345"，第一个字段是 1 分钟平均负载
        CPU_LOAD1.set(float(f.read().split()[0]))

    mem_available_kb = 0
    with open("/proc/meminfo", encoding="ascii") as f:
        for line in f:
            if line.startswith("MemAvailable:"):
                mem_available_kb = int(line.split()[1])
                break
    MEM_AVAILABLE.set(mem_available_kb * 1024)

    st = os.statvfs("/")
    DISK_FREE.labels(mount="/").set(st.f_bavail * st.f_frsize)


def simulate_traffic(stop):
    """后台线程：每 0.2 秒模拟一次业务请求，更新 Counter/Histogram/Gauge。"""
    depth = 0
    while not stop.is_set():
        REQUESTS.labels(route=random.choice(ROUTES)).inc()
        # 指数分布模拟延迟，钳到 bucket 上界 5.0 以内
        REQUEST_LATENCY.observe(min(random.expovariate(4.0), 5.0))

        if random.random() < 0.3:
            depth += random.randint(1, 5)
        depth = max(0, depth - random.randint(0, 3))
        QUEUE_DEPTH.labels(queue="orders").set(depth)

        stop.wait(0.2)


def main():
    start_http_server(PORT)
    print(f"ops_exporter listening on http://0.0.0.0:{PORT}/metrics", flush=True)

    stop = threading.Event()
    worker = threading.Thread(target=simulate_traffic, args=(stop,), daemon=True)
    worker.start()

    try:
        while True:
            try:
                collect_system()
            except OSError as exc:
                # /proc 读取失败只降级，不让 exporter 崩掉
                print(f"collect_system error: {exc}", flush=True)
            time.sleep(5)
    finally:
        stop.set()


if __name__ == "__main__":
    main()
```

## 逐段讲解

### 1. 指标类型选型：Counter / Gauge / Histogram

| 问题 | 类型 | 本例 |
| --- | --- | --- |
| 这个量只增不减吗？ | Counter | `app_requests_total` |
| 这个量可以上下波动吗？ | Gauge | load1、内存、磁盘、队列深度 |
| 我要分位数（P95/P99）吗？ | Histogram（或 Summary） | `app_request_duration_seconds` |

选型错误会让 PromQL 直接失效：对 Gauge 做 `rate()` 没有意义（它不是单调的），对延迟用 Counter 则永远算不出分位数。`host_mem_available_bytes` 用 Gauge，因为可用内存随分配/释放上下跳动。

**单位惯例**：时间用秒（`_seconds`）、字节数用 bytes（`_bytes`），这样 Grafana 的格式化器和 `rate()`/人均换算才能正常工作。/proc/meminfo 给的是 kB，必须乘 1024。

### 2. Labels：给指标加维度而不是复制指标

`DISK_FREE.labels(mount="/").set(...)` 与 `REQUESTS.labels(route="/api").inc()` 中，`mount`、`route` 是维度（dimension），同一个指标族下不同 label 组合是不同时间序列。反模式是为每个 route 定义一个独立指标（`app_requests_api_total`、`app_requests_login_total`……）——那会让 PromQL 无法用一条查询聚合，Prometheus 的 label 匹配（`app_requests_total{route=~"/api|/login"}`）也就失去了意义。

注意 labels 的基数（cardinality）要受控：route 是有限集合没问题；如果把 user_id 之类的无界值当 label，序列数会爆炸，这是 Prometheus 生产事故的常见来源。

### 3. 采集线程模型：一个推、一个拉

- 业务线程每 0.2 秒主动更新指标对象（推）——事件驱动的量必须在事件发生时记录，事后无法补。
- 系统指标由主循环每 5 秒刷新（拉）——/proc 是"读即快照"，刷新频率即数据新鲜度；Gauge 两次刷新之间保持旧值，Prometheus 按抓取间隔采样。

`stop.wait(0.2)` 而不是 `time.sleep(0.2)`：前者能被 `stop.set()` 立刻唤醒，进程退出时线程能干净收尾（虽然它是 daemon 线程，主进程退出也会被强杀，这里只是好习惯）。daemon=True 保证主线程意外退出时整个进程不被业务线程拖住。

### 4. /proc 解析的鲁棒性

- `/proc/loadavg` 格式是 `0.52 0.58 0.59 1/487 12345`，取 `split()[0]`。
- `/proc/meminfo` 逐行找 `MemAvailable:`，**找到就 break**——这个文件几百行，没必要读完；同时"没找到"时保持 0 值而不是抛异常（老内核无此字段）。
- `collect_system()` 里的 OSError 只打日志：exporter 的可用性应高于单次采集的成功率，一次读失败就让进程退出反而制造监控盲区（监控挂了谁监控监控）。

`os.statvfs("/")` 是 POSIX 调用的 Python 封装，`f_bavail` 是普通用户可用块数（区别于 root 视角的 `f_bfree`），`f_frsize` 是块大小，两者相乘即自由字节数——与 node_exporter 的 `node_filesystem_avail_bytes` 语义一致。

### 5. Histogram 的 bucket 如何选

Histogram 不存原始值，只把每次 observe 落进**累积 bucket**（`le="0.05"` 表示 <=0.05 秒的次数，含更早的桶）。分位数由 Prometheus 服务端用 `_bucket` 序列插值计算：

```promql
# [任意节点] PromQL：模拟流量的 P95 延迟（5 分钟窗口）
histogram_quantile(0.95,
  sum by (le) (rate(app_request_duration_seconds_bucket[5m])))
```

bucket 边界应覆盖业务的 SLO 刻度：本例桶最细到 0.01s、最粗到 5.0s，模拟延迟均值 0.25s（expovariate(4.0) 的期望），落在中间桶，P95 估计才有意义。若所有样本都落在 `+Inf` 桶，任何分位数都只能返回上界——这是自研 exporter 最常见的坑。

### 6. Counter 命名与进程重启

Counter 暴露名必须以 `_total` 结尾：`Counter("app_requests_total", ...)` 直接合规；写 `Counter("app_requests", ...)` 时客户端自动补 `_total`。进程重启后 Counter 归零，这正是 PromQL 一律用 `rate()`/`increase()` 而不直接读值的原因——`rate` 会自动识别并跳过重置点。check.sh 的 T7 验证两次抓取之间数值递增，就是在验证模拟线程确实在驱动这个 Counter。

## 运行演示

```bash
# [任意节点]
cd 02-programming/labs/02-python-exporter
python3 ops_exporter.py &
sleep 2

# 系统指标（数值随机器不同）
curl -s http://127.0.0.1:9877/metrics | grep -E '^host_'
# host_cpu_load1 0.31
# host_mem_available_bytes 1.26089728e+09
# host_disk_free_bytes{mount="/"} 1.1066397184e+10

# 业务指标
curl -s http://127.0.0.1:9877/metrics | grep -E '^app_requests_total'
# app_requests_total{route="/api"} 34
# app_requests_total{route="/login"} 29
# app_requests_total{route="/health"} 33

# 2 秒后 Counter 应增长（模拟线程每 0.2s 一次请求）
sleep 2
curl -s http://127.0.0.1:9877/metrics | grep -c '^app_requests_total'

# 响应头确认 exposition 格式(prometheus_client 不接受 HEAD,会 405,必须用 GET)
curl -s -D - -o /dev/null http://127.0.0.1:9877/metrics | grep -i content-type
# Content-Type: text/plain; version=0.0.4; charset=utf-8
```

接到练习集群的 Prometheus（抓取配置片段，供后续 PCA 章节使用）：

```yaml
# [master] prometheus 抓取 job（追加到 scrape_configs，需重启/热加载 Prometheus）
scrape_configs:
  - job_name: "ops-exporter"
    static_configs:
      - targets: ["172.30.30.21:9877"]
```

## check.sh 通过结果

```bash
# [任意节点]
bash check.sh
```

```
PASS: ops_exporter.py 存在于 lab 目录
PASS: python3 与 prometheus_client 可用
PASS: 脚本中定义了全部 6 个要求的指标名
PASS: exporter 启动成功且 http://127.0.0.1:9877/metrics 返回 HTTP 200
PASS: /metrics 输出包含全部 6 个要求的指标名
PASS: exposition 格式正确（Content-Type: text/plain，含 # HELP 与 # TYPE 行）
PASS: app_requests_total 随时间递增（41 -> 52）
----------------------------------------
SCORE: 7/7
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| `ValueError: label names ... missing` 崩溃 | 对声明了 label 的指标直接 `.set()`/`.inc()` | 先 `.labels(mount="/")` 取实例再操作 |
| `/metrics` 里指标名变成 `app_requests_total_total` | 定义名已带 `_total` 却又用了旧版客户端的双重后缀（或手动拼了后缀） | 定义时直接写 `app_requests_total`，输出名以 curl 实测为准 |
| `pip3 install --user` 报 externally-managed | Ubuntu 24.04 的 pip 受 PEP 668 保护 | `pip3 install --user --break-system-packages prometheus_client` 或用 venv |
| Histogram 的 P95 永远等于最大 bucket | 所有样本落在 `+Inf`，bucket 边界没覆盖真实延迟分布 | 按业务 SLO 重选 buckets，观察 `_bucket` 序列分布后再定 |
| 端口 9877 被占用，exporter 直接退出 | 上一次运行的进程没杀干净 | `ss -ltnp | grep 9877` 找到 PID kill，或用 `OPS_EXPORTER_PORT` 换端口 |
| 指标抓得到但值一直是 0 | 主循环没启动 / 系统采集函数抛异常后线程死掉 | 检查终端日志里的 `collect_system error`，异常要 catch 后继续循环 |
| label 里放了 user_id 之类无界值 | 序列基数爆炸，Prometheus 内存暴涨 | label 只用有限维（route、mount、queue），无界信息放日志 |

## 收尾自查

<details><summary>为什么 Gauge 不能做 rate()，而 Counter 可以？</summary>

`rate()` 的前提是序列单调递增（允许重置归零，靠检测值下降识别重启）。Counter 语义保证单调，重置可被正确跳过；Gauge 上下波动，任何一次下降都会被误判为"进程重启"，算出的速率毫无意义。Gauge 想看变化应使用 `deriv()`（每秒线性变化率）或 `delta` 类的 `idelta`/直接对比 `offset`。
</details>

<details><summary> exporters 为什么普遍选 pull（HTTP 暴露）而不是把指标 push 出去？</summary>

pull 模型下 Prometheus 是唯一发起方：目标列表集中管理、抓取失败即 `up==0` 可自监控、用 curl 就能调试任何 target；push 模型（如 statsd/Graphite）目标异常时监控端无从得知"它没发数据"还是"它挂了"。Pushgateway 只作为批处理任务的补丁存在，长驻服务一律 pull。这也是本 lab 要求"本地 curl 验证"的原因——curl 通了，Prometheus 就能抓。
</details>

<details><summary>如果把 collect_system 的刷新间隔从 5 秒改成 60 秒，抓取间隔 15 秒，会看到什么？</summary>

Prometheus 每 15 秒抓到的是同一份 60 秒才刷新一次的 Gauge 快照，图上出现 4 个连续相同的点拼成的阶梯。数据不会错，但陈旧度最高 60 秒——磁盘/内存这类慢变量可以接受，换成就绪探针类指标就不行。经验法则：刷新间隔 <= 抓取间隔的一半，保证每个抓取窗口内至少刷新一次。
</details>

<details><summary>histogram_quantile 算出的 P95 为什么是"估计值"？</summary>

客户端只保留每个 bucket 边界内的累计计数，样本在桶内的分布未知；Prometheus 在目标桶内做线性插值假设均匀分布。桶越密估计越准、序列数越多（每桶一条时间序列）。Summary 在客户端精确算分位数，但无法跨实例聚合、分位数不可后补——所以多实例服务几乎都选 Histogram。
</details>
