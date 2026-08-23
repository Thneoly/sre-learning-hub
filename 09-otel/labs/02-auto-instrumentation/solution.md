# Lab 02 · 解答：OTel Operator 自动插桩

整体链路：

```
python-demo(注入的SDK) --OTLP http/protobuf 4318--> Collector --otlp gRPC--> Jaeger all-in-one(16686 UI)
```

## 步骤 1：安装 cert-manager

operator 的 validating/mutating webhook 需要 TLS 证书，官方推荐 cert-manager 提供。

```bash
# [master]
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.3/cert-manager.yaml
kubectl -n cert-manager wait --for=condition=Available deploy --all --timeout=300s
kubectl -n cert-manager get pods
```

预期 3 个 Pod（cert-manager / webhook / cainjector）都 Running。

## 步骤 2：安装 OTel Operator

```bash
# [master]
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/download/v0.109.0/opentelemetry-operator.yaml
kubectl -n opentelemetry-operator-system wait --for=condition=Available deploy --all --timeout=300s
kubectl -n opentelemetry-operator-system get pods
```

预期 controller-manager Pod Running。安装完成后集群里多出一批 CRD：

```bash
# [master]
kubectl get crd | grep opentelemetry
```

应看到 `instrumentations.opentelemetry.io`、`opentelemetrycollectors.opentelemetry.io` 等。注意 v0.109.0 的 Instrumentation CRD 只有 `v1alpha1` 一个版本（`v1beta1` 是更晚的 operator 才引入的），所以下面 CR 的 apiVersion 用 `opentelemetry.io/v1alpha1`。

## 步骤 3：部署 Jaeger 与 Collector

Jaeger all-in-one 开 OTLP 接收只需一个环境变量；Collector 负责中转并打 debug 日志（复用 Lab 01 的思路）。

```bash
# [master]
kubectl create namespace otel-lab 2>/dev/null || true
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: otel-lab
  labels:
    app: jaeger
spec:
  replicas: 1
  selector:
    matchLabels:
      app: jaeger
  template:
    metadata:
      labels:
        app: jaeger
    spec:
      containers:
      - name: jaeger
        image: jaegertracing/all-in-one:1.57.0
        env:
        - name: COLLECTOR_OTLP_ENABLED
          value: "true"
        ports:
        - containerPort: 16686
          name: ui
        - containerPort: 4317
          name: otlp-grpc
        - containerPort: 4318
          name: otlp-http
        resources:
          requests:
            cpu: 50m
            memory: 256Mi
          limits:
            memory: 1Gi
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: otel-lab
spec:
  selector:
    app: jaeger
  ports:
  - name: ui
    port: 16686
    targetPort: 16686
  - name: otlp-grpc
    port: 4317
    targetPort: 4317
  - name: otlp-http
    port: 4318
    targetPort: 4318
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: otel-lab
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
    processors:
      batch: {}
    exporters:
      debug:
        verbosity: basic
      otlp/jaeger:
        endpoint: jaeger.otel-lab.svc:4317
        tls:
          insecure: true
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug, otlp/jaeger]
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: otel-collector
  namespace: otel-lab
  labels:
    app: otel-collector
spec:
  replicas: 1
  selector:
    matchLabels:
      app: otel-collector
  template:
    metadata:
      labels:
        app: otel-collector
    spec:
      containers:
      - name: collector
        image: ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.111.0
        args: ["--config=/conf/config.yaml"]
        ports:
        - containerPort: 4317
        - containerPort: 4318
        volumeMounts:
        - name: conf
          mountPath: /conf
      volumes:
      - name: conf
        configMap:
          name: otel-collector-config
---
apiVersion: v1
kind: Service
metadata:
  name: otel-collector
  namespace: otel-lab
spec:
  selector:
    app: otel-collector
  ports:
  - name: otlp-grpc
    port: 4317
    targetPort: 4317
  - name: otlp-http
    port: 4318
    targetPort: 4318
EOF
kubectl -n otel-lab rollout status deploy/jaeger --timeout=180s
kubectl -n otel-lab rollout status deploy/otel-collector --timeout=180s
```

## 步骤 4：创建 Instrumentation CR

这是"插桩配置"的唯一事实来源：operator 读它决定注入哪个语言的 SDK、数据发到哪。

```bash
# [master]
kubectl apply -f - <<'EOF'
apiVersion: opentelemetry.io/v1alpha1
kind: Instrumentation
metadata:
  name: python-instr
  namespace: otel-lab
spec:
  exporter:
    endpoint: http://otel-collector.otel-lab.svc:4317
  propagators:
    - tracecontext
    - baggage
    - b3
  sampler:
    type: parentbased_traceidratio
    argument: "1"
  python:
    env:
      # 官方文档要求：Python 自动插桩默认用 http/protobuf，
      # OTEL_EXPORTER_OTLP_ENDPOINT 必须指向 4318 而不是 4317
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: http://otel-collector.otel-lab.svc:4318
      # 本 lab 的 Collector 只建了 traces pipeline，关掉另两路信号
      - name: OTEL_METRICS_EXPORTER
        value: none
      - name: OTEL_LOGS_EXPORTER
        value: none
EOF
kubectl -n otel-lab get instrumentation python-instr
```

预期输出一行，AGE 正常增长即表示 CR 已被 API Server 接受（operator 不会为它起任何 Pod）。

## 步骤 5：部署示例应用并加注解

用一个最小 Flask 应用验证：ConfigMap 放代码，`python:3.12-slim` 启动时安装依赖。关键只有两处：pod template 的注解 + 显式 `OTEL_SERVICE_NAME`。

```bash
# [master]
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: python-demo-app
  namespace: otel-lab
data:
  app.py: |
    from flask import Flask
    import time

    app = Flask(__name__)

    @app.route("/")
    def index():
        return "hello otel\n"

    @app.route("/slow")
    def slow():
        time.sleep(1)
        return "slow ok\n"

    @app.route("/error")
    def error():
        return "boom\n", 500

    if __name__ == "__main__":
        app.run(host="0.0.0.0", port=8080)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: python-demo
  namespace: otel-lab
  labels:
    app: python-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: python-demo
  template:
    metadata:
      labels:
        app: python-demo
      annotations:
        instrumentation.opentelemetry.io/inject-python: "true"
    spec:
      containers:
      - name: myapp
        image: python:3.12-slim
        command: ["/bin/sh", "-c"]
        args: ["pip install --no-cache-dir flask==3.0.3 && python /app/app.py"]
        env:
        - name: OTEL_SERVICE_NAME
          value: "python-demo"
        ports:
        - containerPort: 8080
        readinessProbe:
          httpGet:
            path: /
            port: 8080
          periodSeconds: 5
        volumeMounts:
        - name: app
          mountPath: /app
          readOnly: true
      volumes:
      - name: app
        configMap:
          name: python-demo-app
---
apiVersion: v1
kind: Service
metadata:
  name: python-demo
  namespace: otel-lab
spec:
  selector:
    app: python-demo
  ports:
  - name: http
    port: 8080
    targetPort: 8080
EOF
kubectl -n otel-lab rollout status deploy/python-demo --timeout=300s
```

> 启动耗时主要在 `pip install`（约 20~60 秒，取决于网络）；readinessProbe 保证 Flask 就绪后才判 Ready。

验证注入。注意：mutating webhook 拦截的是 Pod 的 CREATE 事件，Deployment 对象不会被改写，所以要看**运行中的 Pod**：

```bash
# [master]
POD=$(kubectl -n otel-lab get pod -l app=python-demo -o jsonpath='{.items[0].metadata.name}')
kubectl -n otel-lab get pod "$POD" -o jsonpath='{.spec.initContainers[*].name}'; echo
kubectl -n otel-lab get pod "$POD" -o jsonpath='{.spec.containers[0].env[*].name}'; echo
```

预期输出：

```
opentelemetry-auto-instrumentation-python
OTEL_SERVICE_NAME OTEL_EXPORTER_OTLP_ENDPOINT OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER PYTHONPATH OTEL_EXPORTER_OTLP_PROTOCOL OTEL_TRACES_EXPORTER OTEL_POD_IP OTEL_NODE_IP OTEL_POD_NAME OTEL_TRACES_SAMPLER OTEL_TRACES_SAMPLER_ARG OTEL_PROPAGATORS OTEL_RESOURCE_ATTRIBUTES
```

（注入顺序：`python.env` 里声明的变量 + `PYTHONPATH` + `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` 等 SDK 默认项 + sampler/propagators 对应变量；个别项以实际输出为准。）

再直观一点：

```bash
# [master]
kubectl -n otel-lab describe pod -l app=python-demo
```

输出里能看到 init 容器 `opentelemetry-auto-instrumentation-python`（执行 `cp -r /autoinstrumentation/. /otel-auto-instrumentation-python`，把 SDK 拷进共享 emptyDir），主容器挂了同名 volume 且 `PYTHONPATH` 指向它——这就是"零代码接入"的全部机制：SDK 在解释器启动时经 sitecustomize 自动挂钩，对 Flask/Werkzeug 等已安装的库做 monkey-patch。

## 步骤 6：打流量并在 Jaeger 查看

```bash
# [master]
kubectl -n otel-lab apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: traffic
  namespace: otel-lab
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: curl
        image: curlimages/curl:8.9.1
        command: ["/bin/sh", "-c"]
        args: ["for i in $(seq 1 20); do curl -s -o /dev/null -w '%{http_code}\\n' http://python-demo:8080/; curl -s -o /dev/null http://python-demo:8080/slow; sleep 1; done"]
EOF
kubectl -n otel-lab wait --for=condition=complete job/traffic --timeout=120s
```

端口转发访问 Jaeger（保持前台，浏览器开 http://localhost:16686）：

```bash
# [master]
kubectl -n otel-lab port-forward svc/jaeger 16686:16686
```

也可以直接查 Jaeger 的 HTTP API 验证（另开一个终端）：

```bash
# [master]
kubectl -n otel-lab port-forward svc/jaeger 16686:16686 >/dev/null 2>&1 &
sleep 3
curl -s http://localhost:16686/api/services
```

预期返回类似：`{"data":["jaeger-query","python-demo"],"total":2,...}`。在 UI 里选 Service=`python-demo`、Find Traces，能看到 `GET /` 与 `GET /slow` 的 span（Flask/Werkzeug 自动插桩产生），`GET /slow` 链路里还能看到服务端 span 的耗时约 1s。

## 步骤 7：运行检查脚本

```bash
# [master]
chmod +x check.sh && ./check.sh
```

预期结果：

```
PASS: cert-manager: deployment/cert-manager Ready
PASS: opentelemetry-operator: controller-manager Ready
PASS: instrumentation/python-instr 存在
PASS: deployment/jaeger Ready（OTLP 接收已开启）
PASS: deployment/otel-collector Ready
PASS: python-demo Pod 已注入 init 容器与 OTEL_* 环境变量

SCORE: 6/6
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 应用 Pod 起不来，init 容器 ErrImagePull | 离线环境拉不到 SDK 注入镜像 | 给 operator 配 `relatedImages`（离线镜像列表），见 operator 文档 "custom-images" 一节 |
| Deployment 上看不到 init 容器 | webhook 只在 Pod CREATE 时注入，不改 Deployment 对象 | 用 `kubectl get pod -l app=python-demo` 查看运行中的 Pod |
| Pod 无任何变化、没 init 容器 | 注解加在了 Deployment 顶层而非 pod template，或 CR 不在同 namespace 且注解值没写 `ns/name` | 检查 `spec.template.metadata.annotations`；注解值可写 `"true"`（用同 namespace 的唯一 Instrumentation）或 `"otel-lab/python-instr"` |
| Jaeger 里连不上 Collector | endpoint 用了 4317（gRPC）但 Python 默认 `http/protobuf` | `python.env` 里把 `OTEL_EXPORTER_OTLP_ENDPOINT` 指向 4318（官方文档明确要求） |
| Pod Ready 但 Jaeger 没有 service | 流量还没打、或 `OTEL_SERVICE_NAME` 没设置导致 service 名是 Pod 名 | 先跑 traffic Job；确认 Deployment env 里有 `OTEL_SERVICE_NAME=python-demo` |
| `error: the server doesn't have a resource type "instrumentation"` | operator 没装好或 CRD 还没建立 | `kubectl get crd | grep opentelemetry` 确认，重跑 operator 安装命令 |

## 清理（可选）

```bash
# [master]
kubectl delete ns otel-lab
kubectl delete -f https://github.com/open-telemetry/opentelemetry-operator/releases/download/v0.109.0/opentelemetry-operator.yaml
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.15.3/cert-manager.yaml
```
