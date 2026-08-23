# Lab 02 · 用 Python 写一个 Prometheus exporter

> 难度：★★☆ ｜ 考点：PCA-Prometheus 指标暴露与 exposition 格式 ｜ 前置：`02-programming/03-python-for-ops.md`、`02-programming/04-python-ops-toolkit.md` ｜ 预计 40 分钟

## 场景

练习集群里已经跑了 node_exporter，但它只覆盖内核暴露的通用指标。你有一个自己写的订单处理服务，需要回答三个问题：机器负载与内存余量是否正常（系统侧）、请求量/延迟/积压队列（业务侧）。团队不想为此引入整套 SDK，决定用 `prometheus_client` 写一个独立的 `ops_exporter.py`：采集 `/proc` 里的系统指标，再用模拟流量填充业务指标，在 `9877` 端口暴露 `/metrics`，之后即可被 Prometheus 抓取。

你要实现的脚本名固定为 `ops_exporter.py`，放在本 lab 目录（与 check.sh 同级）。

## 任务清单

1. **环境准备**
   ```bash
   # [任意节点]
   python3 -c "import prometheus_client" 2>/dev/null \
     || pip3 install --user prometheus_client \
     || pip3 install --user --break-system-packages prometheus_client
   python3 -c "import prometheus_client; from importlib.metadata import version; print(version('prometheus_client'))"
   ```

2. **系统指标（真实采集，3 个）**
   - `host_cpu_load1`（Gauge）：解析 `/proc/loadavg` 第一个字段。
   - `host_mem_available_bytes`（Gauge）：解析 `/proc/meminfo` 的 `MemAvailable`，kB 值乘 1024 换算成字节。
   - `host_disk_free_bytes`（Gauge，带 `mount` label）：`os.statvfs("/")` 的 `f_bavail * f_frsize`。

3. **业务指标（模拟流量，3 个）**
   - `app_requests_total`（Counter，带 `route` label，取值如 `/api` `/login` `/health`）：由后台线程持续累加。
   - `app_queue_depth`（Gauge，带 `queue` label）：模拟的队列深度，随时间波动。
   - `app_request_duration_seconds`（Histogram，自定义 buckets）：模拟请求延迟，持续 observe。

4. **运行结构**
   - `start_http_server(9877)` 暴露 `/metrics`；端口允许用环境变量 `OPS_EXPORTER_PORT` 覆盖。
   - 一个后台 daemon 线程模拟业务流量（每个迭代 `inc()` Counter、`observe()` Histogram、更新 Gauge）。
   - 主循环每 5 秒刷新一次系统指标；`/proc` 读取失败要打日志继续跑，不能让整个 exporter 崩掉。

5. **本地验证**
   ```bash
   # [任意节点]
   python3 ops_exporter.py &
   sleep 2
   curl -s http://127.0.0.1:9877/metrics | grep -E '^(host_cpu_load1|host_mem_available_bytes|host_disk_free_bytes)'
   curl -s http://127.0.0.1:9877/metrics | grep -E '^app_requests_total'
   sleep 2
   curl -s http://127.0.0.1:9877/metrics | grep -E '^app_requests_total'   # 数值应比上次大
   ```

## 验收标准

- `curl -s http://127.0.0.1:9877/metrics` 返回 exposition 文本：包含全部 6 个指标名、`# HELP` / `# TYPE` 元信息行，Content-Type 为 `text/plain`。
- 两次抓取间隔 2 秒，`app_requests_total`（各 route 之和）严格递增。
- 在本目录运行 `bash check.sh`，得到 `SCORE: 7/7`。

## 提示（卡住再看）

<details><summary>提示 1：Counter 命名的 _total 后缀</summary>

`prometheus_client` 的 `Counter("app_requests_total", ...)` 暴露的指标名就是 `app_requests_total`；如果你写 `Counter("app_requests", ...)`，客户端会自动补上 `_total`。这是 OpenMetrics/Prometheus 命名惯例：Counter 必须以 `_total` 结尾（另有 `_created` 辅助序列，抓取时正常）。Gauge/Histogram 不加。
</details>

<details><summary>提示 2：带 label 的指标要先 labels() 再 set/inc</summary>

定义时声明 label 名：`Gauge("app_queue_depth", "...", ["queue"])`；使用时必须先取实例：`QUEUE_DEPTH.labels(queue="orders").set(depth)`。直接对带 label 的指标 `.set()` 会抛 `ValueError`。同理 Counter 是 `REQUESTS.labels(route="/api").inc()`。
</details>

<details><summary>提示 3：Histogram 暴露的是 bucket/sum/count 三件套</summary>

`Histogram` 在 `/metrics` 里输出 `app_request_duration_seconds_bucket{le="0.05"} ...`、`..._sum`、`..._count`。验证时 grep 前缀 `^app_request_duration_seconds` 即可。buckets 建议 `(0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0)`，覆盖模拟延迟的主要区间；bucket 边界要按业务的 SLO 选，之后算 P95/P99 才有意义。
</details>
