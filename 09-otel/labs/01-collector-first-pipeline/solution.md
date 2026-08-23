# Lab 01 · 解答：最小 Collector 管道

目标拓扑：

```
+---------------+   OTLP gRPC 4317   +---------------------------+
| telemetrygen  | ----------------> | Collector (Deployment)    |
| (Job/Pod)     |                   |  - otlp receiver          |
+---------------+                   |  - batch processor        |
                                    |  - debug exporter -> 日志 |
                                    |  - file exporter  -> 文件 |
                                    +---------------------------+
                                      svc/otel-collector:4317/4318
```

## 步骤 1：创建 namespace

```bash
# [master]
kubectl create namespace otel-lab
```

预期输出：`namespace/otel-lab created`。

## 步骤 2：Collector 配置（ConfigMap）

为什么放 ConfigMap：Collector 是纯配置驱动的组件，配置与镜像分离后，改管道不用重建镜像；这也是后面接 OTel Operator 时的标准做法。

```bash
# [master]
kubectl apply -f - <<'EOF'
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
      batch:
        send_batch_size: 512
        timeout: 1s
    exporters:
      debug:
        verbosity: detailed
      file:
        path: /var/lib/otelcol/telemetry.json
    service:
      telemetry:
        logs:
          level: info
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug, file]
        metrics:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug, file]
EOF
```

要点：

| 组件 | 作用 | 为什么需要 |
|---|---|---|
| `otlp` receiver | 监听 4317(gRPC)/4318(HTTP) | OTel 数据的事实标准入口 |
| `batch` processor | 攒批再发 | 降低 exporter 的写入压力，生产必加 |
| `debug` exporter | 把数据打进容器日志 | 排障期最直观的"数据到了没" |
| `file` exporter | 落地 JSON 文件 | contrib 独有，验证产出物、离线回放 |

## 步骤 3：Deployment + Service

```bash
# [master]
kubectl apply -f - <<'EOF'
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
          name: otlp-grpc
        - containerPort: 4318
          name: otlp-http
        resources:
          requests:
            cpu: 50m
            memory: 128Mi
          limits:
            memory: 512Mi
        volumeMounts:
        - name: conf
          mountPath: /conf
        - name: data
          mountPath: /var/lib/otelcol
      volumes:
      - name: conf
        configMap:
          name: otel-collector-config
      - name: data
        emptyDir: {}
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
kubectl -n otel-lab rollout status deploy/otel-collector --timeout=180s
```

验证：

```bash
# [master]
kubectl -n otel-lab get pods -o wide
kubectl -n otel-lab logs deploy/otel-collector | head -20
```

预期日志能看到 Collector 正常启动、`Everything is ready` 字样；若配置写错，这里会直接报 `error loading configuration` 并 CrashLoopBackOff。

## 步骤 4：telemetrygen 发 trace 和 metric

先用 Job 发 trace（Job 的好处：可被 check.sh 检查 succeeded 状态）：

```bash
# [master]
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: telemetrygen
  namespace: otel-lab
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: telemetrygen
        image: ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest
        args:
        - traces
        - --otlp-insecure
        - --otlp-endpoint=otel-collector.otel-lab.svc:4317
        - --traces=3
EOF
kubectl -n otel-lab wait --for=condition=complete job/telemetrygen --timeout=120s
```

再用临时 Pod 发 metric（`--rm -i` 跑完即删，控制台能直接看结果）：

```bash
# [master]
kubectl -n otel-lab run tg-metrics --rm -i --restart=Never \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  -- metrics --otlp-insecure --otlp-endpoint=otel-collector.otel-lab.svc:4317 --metrics=10
```

预期输出（截取）：

```
2024/.. INFO    traces    starting tracer
2024/.. INFO    metrics    stopping meter
INFO    metrics    generated 10 metrics
pod "tg-metrics" deleted
```

> 说明：镜像 tag 用 `latest` 便于练习环境直接拉取；生产建议固定版本号（tag 与 contrib 版本一致，以官方 ghcr 页面为准）。

## 步骤 5：验证数据到达

看 debug exporter 日志：

```bash
# [master]
kubectl -n otel-lab logs deploy/otel-collector | grep -i telemetrygen | head
```

预期看到类似（verbosity: detailed 会打印 resource 属性）：

```
ResourceSpans#0
Resource attributes[1]:
   service.name: Str(telemetrygen)
ScopeSpans #0
ScopeSpans Schema URL:
InstrumentationScope telemetrygen
Span #0
```

读产出文件：

```bash
# [master]
kubectl -n otel-lab exec deploy/otel-collector -- cat /var/lib/otelcol/telemetry.json | head -5
kubectl -n otel-lab exec deploy/otel-collector -- cat /var/lib/otelcol/telemetry.json | grep -c telemetrygen
```

预期：文件存在，`grep -c` 结果 > 0（trace 和 metric 都会写入同一文件，每行一个 JSON 对象，含 `"service.name":"telemetrygen"` 或对应 metric 名 `gen.*`）。

## 步骤 6：运行检查脚本

```bash
# [master]
chmod +x check.sh && ./check.sh
```

预期结果：

```
PASS: namespace otel-lab 存在
PASS: deployment/otel-collector Ready 副本 >= 1（当前 1）
PASS: svc/otel-collector 暴露 4317 端口（OTLP gRPC）
PASS: collector 配置含 file exporter 及 traces/metrics 两条 pipeline
PASS: job/telemetrygen 成功完成（succeeded=1）
PASS: collector 已收到 telemetrygen 数据（产出文件或日志含 service.name=telemetrygen）

SCORE: 6/6
```

## 替代验证方式（Docker 单机）

没有集群、只有装有 Docker 的 Ubuntu VM 时，把步骤 2 的 `config.yaml` 内容存成本地文件，然后：

```bash
# [装有Docker的Ubuntu VM]
cat > config.yaml <<'EOF'
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318
processors:
  batch:
exporters:
  debug:
    verbosity: detailed
  file:
    path: /var/lib/otelcol/telemetry.json
service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug, file]
    metrics:
      receivers: [otlp]
      processors: [batch]
      exporters: [debug, file]
EOF

# collector 镜像内以非 root（UID 10001）运行，先给宿主机目录放开写权限
mkdir -p "$PWD/data" && chmod 777 "$PWD/data"

docker run -d --name otelcol -p 4317:4317 -p 4318:4318 \
  -v "$PWD/config.yaml:/conf/config.yaml" -v "$PWD/data:/var/lib/otelcol" \
  ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.111.0 \
  --config=/conf/config.yaml

docker run --rm \
  ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  traces --otlp-insecure --otlp-endpoint=host.docker.internal:4317 --traces=3

docker logs otelcol 2>&1 | grep telemetrygen | head
grep -c telemetrygen "$PWD/data/telemetry.json"
```

> 注意：Linux 上 Docker 的 `host.docker.internal` 需要 Docker 20.10+（默认可用）；若不通，把 endpoint 换成宿主机 IP。

## 清理（可选）

```bash
# [master]
kubectl delete ns otel-lab
```
