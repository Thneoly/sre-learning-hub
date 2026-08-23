# Lab 02 · Chaos Drill：一次完整的混沌演练与无责复盘

> 难度：★★☆ ｜ 考点：SRE 方法论（混沌工程流程 + postmortem）｜ 前置：已完成 `scripts/setup/install-prom-stack.sh`（监控栈，release 名 `prom`）；可选路线 B 需要 `scripts/faults/break-dns-config.sh` ｜ 预计 60~90 分钟

## 前置条件与环境说明

- kubeadm 练习集群（单 master + Calico）+ kube-prometheus-stack（namespace `monitoring`，Prometheus UI NodePort `30900`）。
- 本 lab 与 lab 01 互不依赖：示例服务在独立命名空间 `chaos-demo` 重新部署一份。
- 工作目录：把本 lab 目录（含 `check.sh`）拷到 master，例如 `~/labs/02-chaos-drill/`。演练的两个产出物 `drill-plan.md` 与 `postmortem.md` 必须写在这个目录里。
- 路线选择：**路线 A（默认，本文主线）**为应用层故障注入；**路线 B（可选）**使用 `scripts/faults/break-dns-config.sh` 做集群层 DNS 故障。check.sh 对两条路线都适用。

## 场景

上周生产上出过一次事故：一个服务因为依赖的下游劣化，错误率悄悄爬到 5%，跑了 40 分钟才有人发现——发现它的不是告警，而是用户的工单。复盘会上大家心虚地发现：监控有指标、有看板，但**没人验证过"故障发生时我们能不能及时发现"**。

你提议做一次正式的混沌演练（chaos drill），并按 Netflix Principles of Chaos 的路数来：先声明稳态（steady state）假设，再在爆炸半径（blast radius）内注入故障，盯着观测点看系统与监控的真实反应，任何时刻满足中止条件（abort conditions）就立刻回滚。演练结束后按无责（blameless）模板写复盘。

本 lab 的交付物不是"把服务搞挂"，而是三样东西：

1. `drill-plan.md` —— 演练前写好、演练中当剧本用的方案；
2. 一次真实的执行记录（贴回 `drill-plan.md` 的执行日志节，含时间戳）；
3. `postmortem.md` —— 按无责模板写的复盘。

```
演练闭环：

  声明稳态 ──> 定义爆炸半径 ──> 注入故障 ──> 观测（人 + 告警谁先发现？）
      ▲              │              │
      │              │              ▼
      └── 验证恢复 <─┴──── 满足中止条件立即回滚 <─┘
                     │
                     └──> postmortem（无责复盘 → 行动项）
```

## 脚手架：部署演练目标（直接照抄 apply）

与 lab 01 相同的示例服务（纯 Python、自带 `/metrics` 与 `/set` 故障注入接口），部署到 `chaos-demo` 命名空间，外加 4 路并发压测流量。保存为 `app.yaml`：

```yaml
# [master] 保存为 ~/labs/02-chaos-drill/app.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: chaos-demo
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: chaos-demo-app
  namespace: chaos-demo
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
                code, body = 200, b"hello from chaos-demo\n"
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
  name: chaos-demo
  namespace: chaos-demo
  labels:
    app: chaos-demo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: chaos-demo
  template:
    metadata:
      labels:
        app: chaos-demo
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
            name: chaos-demo-app
---
apiVersion: v1
kind: Service
metadata:
  name: chaos-demo
  namespace: chaos-demo
  labels:
    app: chaos-demo
spec:
  selector:
    app: chaos-demo
  ports:
    - name: http
      port: 8000
      targetPort: http
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: chaos-demo
  namespace: chaos-demo
  labels:
    release: prom
spec:
  selector:
    matchLabels:
      app: chaos-demo
  endpoints:
    - port: http
      interval: 15s
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: load-gen
  namespace: chaos-demo
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
              for i in 1 2 3 4; do
                (while :; do wget -q -O /dev/null http://chaos-demo:8000/ || true; done) &
              done
              sleep infinity
          resources:
            requests:
              cpu: 50m
              memory: 32Mi
```

```bash
# [master]
cd ~/labs/02-chaos-drill
kubectl apply -f app.yaml
kubectl -n chaos-demo get pods
# 预期：2 个 chaos-demo-* + 1 个 load-gen-* 全部 Running
```

## 任务清单

1. **先写方案再动手**：在本目录创建 `drill-plan.md`，至少包含以下小节（标题用这些词，check.sh 会查）：
   - `演练目标`：要验证什么假设（例："注入 10% 错误率后，燃烧率告警能在 5 分钟内通知到人"）；
   - `稳态假设`：用可度量的语句描述"系统正常"，含验证用的 PromQL 与命令；
   - `爆炸半径`：故障影响哪些资源/命名空间、不影响什么、演练时段与窗口；
   - `观测点`：人盯哪几个指标/命令、期望哪个告警先响；
   - `中止条件`：出现什么情况立即回滚（例：master 组件异常、演练目标外资源受影响、超过 15 分钟未恢复）；
   - `执行步骤`、`恢复步骤`、`执行日志`（留空，演练时逐条带时间戳回填）。
2. **建立稳态基线**：记录注入前的关键读数（5m 错误率、`demo_fail_rate`、Pod 状态）。
3. **注入故障**（路线 A 主线）：
   ```bash
   # [master] 注入 10% 错误率（爆炸半径 = chaos-demo 命名空间内）
   kubectl -n chaos-demo exec deploy/chaos-demo -- python3 -c \
     "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8000/set?fail_rate=0.1&latency_ms=0').read().decode())"
   ```
   可选路线 B（集群层，DNS 故障，替代或追加）：
   ```bash
   # [master] 需要 scripts/ 仓库在本机
   sudo bash scripts/faults/break-dns-config.sh
   ```
4. **观测并记录**：按观测点逐条记录（时间戳 + 指标值 + 告警状态），回填到 `drill-plan.md` 的执行日志节。重点回答：**是你先发现，还是告警先发现？**
5. **触发中止条件或到达演练时长后恢复**：路线 A 用 `/set?fail_rate=0&latency_ms=0`；路线 B 用 `--restore`。
6. **验证稳态回归**：错误率回到 0、`demo_fail_rate 0`、Pod 全部 Ready，记录恢复时间戳。
7. **写 `postmortem.md`**（无责模板，标题须含 `时间线`、`影响`、`根因`、`行动项`，行动项至少 2 条、用 `- [ ]` 勾选格式并标注负责人与截止时间）。
8. 保持终态（现场已恢复、文件已写好），运行 `./check.sh`。

## 验收标准

- `drill-plan.md` 存在且包含：稳态假设、爆炸半径、观测点、中止条件四个关键小节；
- `postmortem.md` 存在且包含：时间线、影响、根因、行动项小节，行动项 ≥ 2 条；
- 集群终态：`chaos-demo` 命名空间 deployment Ready ≥ 1，注入已清除（`demo_fail_rate` 为 0）；若走过路线 B，`fault-dns` 相关故障已 `--restore`；
- `chmod +x check.sh && ./check.sh` 输出 `SCORE: 11/11`。

## 提示（卡住再看）

<details><summary>提示 1：稳态假设怎么写才算"可度量"？</summary>

反例："服务正常运行"。正例：

> 在 15s 抓取间隔下，`chaos-demo` 的 5 分钟错误率
> `sum(rate(demo_http_requests_total{code=~"5.."}[5m])) / clamp_min(sum(rate(demo_http_requests_total[5m])), 1e-10)`
> 稳定为 0，且 `demo_fail_rate == 0`，Pod Ready = 2/2。

稳态必须是"注入前测得出、恢复后测得回"的句子，否则你无法宣布"演练成功恢复"。

</details>

<details><summary>提示 2：爆炸半径怎么收窄？</summary>

三条手段叠加：独立命名空间（本 lab 的 `chaos-demo`）、独立注入面（`/set` 只影响这一个进程）、低强度起步（先 0.05 再 0.1，不要一上来 0.5）。`/set` 接口本身就是爆炸半径控制——它碰不到 kubelet、CNI、DNS，天然不会外溢。路线 B 的 `break-dns-config.sh` 同理只作用于 `fault-dns` 命名空间。

</details>

<details><summary>提示 3：观测点选什么？</summary>

每个观测点 = 一个命令 + 一个预期。最少三个：业务（错误率/延迟的 PromQL）、告警（`/api/v1/alerts` 状态或 UI /alerts）、资源（`kubectl -n chaos-demo get pods`）。演练的真正产出是"MTTD"——从注入到被发现的时延，写进执行日志。

</details>

<details><summary>提示 4：无责复盘的"无责"体现在哪？</summary>

时间线只写事实与时刻，不写"某某误操作"；根因分析对准系统与流程（为什么靠用户工单才发现？为什么告警阈值没覆盖 5% 错误率？），行动项落到"改系统"而不是"培训某人小心"。假设一切人为动作都是合理的，问的是"什么系统让这个合理动作造成了事故"。

</details>
