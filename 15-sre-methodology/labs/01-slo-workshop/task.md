# Lab 01 · SLO Workshop：给示例服务定义 SLI/SLO 并落地燃烧率告警

> 难度：★★☆ ｜ 考点：SRE 方法论（SLI/SLO/error budget）+ PCA-PromQL recording rules ｜ 前置：已完成 `scripts/setup/install-prom-stack.sh`（kube-prometheus-stack，release 名 `prom`）｜ 预计 60~90 分钟

## 前置条件与环境说明

- 一套可用的 kubeadm 练习集群（单 master + Calico），已用 `scripts/setup/install-prom-stack.sh` 装好监控栈：
  - namespace `monitoring`，Helm release 名 `prom`；
  - Prometheus UI 经 NodePort `30900` 暴露，Grafana 在 `30300`；
  - Prometheus Operator 在位（能识别 `PrometheusRule` / `ServiceMonitor` CR）。
- 本实验**不依赖** lab 环境里的其他服务：示例服务由下面的脚手架清单提供，直接 apply 即可。
- 工作目录：把本 lab 目录（含 `check.sh`）拷到 master 上某个目录，例如 `~/labs/01-slo-workshop/`，后续文件都写在这里。

## 场景

你是平台组的值班工程师。团队刚给一个内部演示服务 `slo-demo` 定了两条口头承诺："基本不出错"、"响应要快"。领导要求你把这种模糊说法变成可度量、可告警的正式约定：

1. 用 SLI/SLO 语言把两条承诺写清楚（可用性 + 延迟），并算出 error budget；
2. 在 Prometheus 里用 recording rules 固化 SLI 计算（不要让每个看板都重写一遍 PromQL）；
3. 配置 multi-window multi-burn-rate（多窗口多燃烧率）告警，让"烧预算的速度"而不是"单次错误"触发 page；
4. 用压测 + 故障注入验证告警真的会响，然后恢复现场。

实验完成后，你应该能回答：**"服务现在还有多少 error budget？烧得多快？"**——并且这个答案来自 Prometheus，而不是来自感觉。

## 脚手架：部署示例服务（直接照抄 apply）

先把被测服务跑起来。它是一个纯 Python 标准库写的 HTTP 服务，自带 `/metrics`（counter + histogram），并支持运行时注入故障：

- `GET /`：正常请求（受注入参数影响）；
- `GET /set?fail_rate=0.5&latency_ms=400`：运行时把 50% 的请求变成 500、所有请求加 400ms 延迟（这是后面"压测验证告警"的故障注入开关）；
- `GET /metrics`：Prometheus 文本格式指标；
- `GET /healthz`：存活/就绪探针用。

保存为 `app.yaml`：

```yaml
# [master] 保存为 ~/labs/01-slo-workshop/app.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: slo-demo
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: slo-demo-app
  namespace: slo-demo
data:
  app.py: |
    import http.server
    import json
    import random
    import threading
    import time
    import urllib.parse

    CONFIG = {"fail_rate": 0.0, "latency_ms": 0}
    LOCK = threading.Lock()
    REQUESTS = {"200": 0, "500": 0}
    BUCKETS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.4, 0.8, 1.6]
    HIST = [0] * len(BUCKETS)
    STATS = {"count": 0, "sum": 0.0}

    def record(code, elapsed):
        with LOCK:
            REQUESTS[str(code)] = REQUESTS.get(str(code), 0) + 1
            STATS["count"] += 1
            STATS["sum"] += elapsed
            for i, le in enumerate(BUCKETS):
                if elapsed <= le:
                    HIST[i] += 1

    def render_metrics():
        with LOCK:
            lines = []
            lines.append("# HELP demo_http_requests_total Total HTTP requests handled.")
            lines.append("# TYPE demo_http_requests_total counter")
            for code in sorted(REQUESTS):
                lines.append('demo_http_requests_total{code="%s"} %d' % (code, REQUESTS[code]))
            lines.append("# HELP demo_http_request_duration_seconds Request latency in seconds.")
            lines.append("# TYPE demo_http_request_duration_seconds histogram")
            for i, le in enumerate(BUCKETS):
                lines.append('demo_http_request_duration_seconds_bucket{le="%s"} %d' % (le, HIST[i]))
            lines.append('demo_http_request_duration_seconds_bucket{le="+Inf"} %d' % STATS["count"])
            lines.append("demo_http_request_duration_seconds_sum %.6f" % STATS["sum"])
            lines.append("demo_http_request_duration_seconds_count %d" % STATS["count"])
            lines.append("# HELP demo_fail_rate Injected failure probability.")
            lines.append("# TYPE demo_fail_rate gauge")
            lines.append("demo_fail_rate %s" % CONFIG["fail_rate"])
            lines.append("# HELP demo_latency_ms Injected latency in milliseconds.")
            lines.append("# TYPE demo_latency_ms gauge")
            lines.append("demo_latency_ms %d" % CONFIG["latency_ms"])
            return ("\n".join(lines) + "\n").encode()

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path == "/metrics":
                self._send(200, render_metrics(), "text/plain; version=0.0.4; charset=utf-8")
                return
            if parsed.path == "/healthz":
                self._send(200, b"ok\n")
                return
            if parsed.path == "/set":
                q = urllib.parse.parse_qs(parsed.query)
                with LOCK:
                    if "fail_rate" in q:
                        CONFIG["fail_rate"] = min(max(float(q["fail_rate"][0]), 0.0), 1.0)
                    if "latency_ms" in q:
                        CONFIG["latency_ms"] = max(int(float(q["latency_ms"][0])), 0)
                with LOCK:
                    body = json.dumps(CONFIG).encode()
                self._send(200, body, "application/json")
                return
            start = time.monotonic()
            with LOCK:
                fail_rate = CONFIG["fail_rate"]
                latency_ms = CONFIG["latency_ms"]
            if latency_ms:
                time.sleep(latency_ms / 1000.0)
            if random.random() < fail_rate:
                code, body = 500, b"internal server error\n"
            else:
                code, body = 200, b"hello from slo-demo\n"
            record(code, time.monotonic() - start)
            self._send(code, body)

        def _send(self, code, body, ctype="text/plain; charset=utf-8"):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            pass

    if __name__ == "__main__":
        server = http.server.ThreadingHTTPServer(("0.0.0.0", 8000), Handler)
        server.daemon_threads = True
        server.serve_forever()
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: slo-demo
  namespace: slo-demo
  labels:
    app: slo-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: slo-demo
  template:
    metadata:
      labels:
        app: slo-demo
    spec:
      containers:
        - name: app
          image: python:3.12-alpine
          command: ["python3", "/opt/app/app.py"]
          ports:
            - name: http
              containerPort: 8000
          readinessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 3
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 128Mi
          volumeMounts:
            - name: app
              mountPath: /opt/app
              readOnly: true
      volumes:
        - name: app
          configMap:
            name: slo-demo-app
---
apiVersion: v1
kind: Service
metadata:
  name: slo-demo
  namespace: slo-demo
  labels:
    app: slo-demo
spec:
  selector:
    app: slo-demo
  ports:
    - name: http
      port: 8000
      targetPort: http
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: slo-demo
  namespace: slo-demo
  labels:
    release: prom
spec:
  selector:
    matchLabels:
      app: slo-demo
  endpoints:
    - port: http
      interval: 15s
```

再部署压测流量（8 路并发 busybox wget 循环）保存为 `load.yaml`：

```yaml
# [master] 保存为 ~/labs/01-slo-workshop/load.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: load-gen
  namespace: slo-demo
  labels:
    app: load-gen
spec:
  replicas: 1
  selector:
    matchLabels:
      app: load-gen
  template:
    metadata:
      labels:
        app: load-gen
    spec:
      containers:
        - name: load
          image: busybox:1.36
          command:
            - sh
            - -c
            - |
              for i in 1 2 3 4 5 6 7 8; do
                (while :; do wget -q -O /dev/null http://slo-demo:8000/ || true; done) &
              done
              sleep infinity
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
```

```bash
# [master]
cd ~/labs/01-slo-workshop
kubectl apply -f app.yaml
kubectl apply -f load.yaml
kubectl -n slo-demo get pods -w
# 预期：2 个 slo-demo-* 与 1 个 load-gen-* 全部 Running/Ready 后 Ctrl+C
```

验证采集链路（2 分钟内 ServiceMonitor 生效）：

```bash
# [master]
kubectl -n slo-demo exec deploy/slo-demo -- python3 -c \
  "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8000/metrics').read().decode())" | head
# 预期：能看到 demo_http_requests_total{code="200"} ... 等 indicator

curl -s "http://$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'):30900/api/v1/query?query=up{job=\"slo-demo/slo-demo/0\"}"
# 预期："value":["<ts>","1"]；job 名以实际 /targets 页签为准，重点是 up == 1
```

## 任务清单

1. 在本 lab 目录写 `slo-design.md`（不少于 20 行），包含：
   - 两条正式 SLO：可用性（成功率）与延迟（快于阈值的比例），各写出 SLI 的 PromQL 定义、目标值、窗口（30 天）；
   - 可用性 SLO 的 error budget 换算（30 天窗口折合多少分钟的全停时间）；
   - 燃烧率（burn rate）公式与 14.4 / 6 两档阈值的含义（为什么 25.92 是 30 天预算 2 天烧完对应的燃烧率，14.4 是 3 天烧完）。
2. 编写 `slo-rules.yaml`（PrometheusRule，namespace `monitoring`，带 `release: prom` label），包含：
   - recording rules 组 `slo-demo.recording`：请求速率、错误速率、可用性比率（1m/5m/30m/1h/6h 窗口）、延迟达标比率（`le="0.2"` 桶）、1 天窗口的燃烧率；
   - alerting rules 组 `slo-demo.alerts`：可用性 fast burn（14.4，1h+5m 双窗口）、slow burn（6，6h+30m 双窗口）、延迟 fast burn（14.4，1h+5m），以及一个**演练专用**的 1m+5m 短窗口告警（用于快速验证，注释说明生产不要用）。
3. 应用规则并用 promtool（本机有则用本机，没有则借 Prometheus Pod 里的 promtool，见 solution.md）校验语法；在 Prometheus UI `/rules` 页签确认两组规则加载且健康。
4. 用 `slo:slo_demo_availability:ratio_rate5m` 等 recording rule 名在 Prometheus UI 查询，确认有数据。
5. 压测验证告警触发：
   - 用 `/set` 注入 `fail_rate=0.5`；
   - 在 Prometheus UI `/alerts` 或 API `/api/v1/alerts` 观察演练专用告警在 3 分钟内进入 `firing`；
   - 记录 firing 时刻，然后 `/set?fail_rate=0&latency_ms=0` 恢复，确认告警转 `resolved`。
6. 保持现场（服务、load-gen、规则都在），运行 `./check.sh`。

## 验收标准

- `kubectl -n monitoring get prometheusrule slo-demo-slo` 存在；
- Prometheus UI `/rules` 能看到 `slo-demo.recording` 与 `slo-demo.alerts` 两个组，全部 health=ok；
- 注入 50% 错误率后，演练专用燃烧率告警 ≤3 分钟 firing；恢复后 resolved；
- `slo-design.md` 与 `slo-rules.yaml` 存在于本 lab 目录；
- `chmod +x check.sh && ./check.sh` 输出 `SCORE: 10/10`。

## 提示（卡住再看）

<details><summary>提示 1：可用性 SLI 的比率怎么写才稳？</summary>

错误率 = 错误请求速率 / 总请求速率，注意分母为 0（无流量时）会得到 NaN，用 `clamp_min(..., 1e-10)` 兜底。可用性比率 = `1 - 错误率`。recording rule 里先分别记录分子分母两个 rate，再组合出比率，避免一条超长表达式。

</details>

<details><summary>提示 2：延迟 SLI 为什么用 histogram 的固定桶而不是 avg？</summary>

延迟关注的是"多大比例的请求足够快"，不是平均值。选 `le="0.2"` 桶（200ms）：

```promql
sum(rate(demo_http_request_duration_seconds_bucket{le="0.2"}[5m]))
/
clamp_min(sum(rate(demo_http_request_duration_seconds_count[5m])), 1e-10)
```

这也是 SRE 工作簿推荐的"event-based"延迟 SLI 写法（好事件 / 总事件），与可用性 SLI 同构，燃烧率公式可以直接复用。

</details>

<details><summary>提示 3：多窗口燃烧率告警的表达式骨架？</summary>

```promql
# [Prometheus UI] 多窗口燃烧率告警骨架
(
  slo:slo_demo_availability:ratio_rate1h < 1 - (1 - 0.999) * 14.4
  and
  slo:slo_demo_availability:ratio_rate5m < 1 - (1 - 0.999) * 14.4
)
```

两个窗口同时越限才触发：长窗口（1h）防止偶发抖动误报，短窗口（5m）确认"现在还在烧"。
阈值写在可用性比率上要**先减再比**：`可用性 < 1 - (1 - 目标) × 燃烧率`（否则变成"可用性 < 0.0144"的全停条件）。
14.4 对应 30 天预算约 2 天烧完（30d/14.4 ≈ 50h），6 对应约 5 天烧完。

</details>

<details><summary>提示 4：PrometheusRule 为什么带 release: prom label？</summary>

kube-prometheus-stack 默认给 Prometheus 配置了 `ruleSelector: matchLabels: release: prom`——没有这个 label 的 PrometheusRule 不会被任何 Prometheus 实例捡起，`/rules` 页签会一直空白。ServiceMonitor 同理。

</details>
