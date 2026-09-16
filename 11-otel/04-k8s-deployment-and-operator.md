# 04 · Kubernetes 部署与 OTel Operator

> 模块：OpenTelemetry（06）｜ 建议时长：3 小时 ｜ 前置：01~03 章 ｜ 关联认证：CKA-工作负载/RAC（弱相关）｜ 关联实验环境：kubeadm 单 master 集群 + Calico

## 学习目标

- 能解释 OTel Operator 的职责（两类 CRD + mutating webhook）以及它为什么依赖 cert-manager
- 能操作：安装 cert-manager 与 Operator，用 `OpenTelemetryCollector` CR 部署节点 agent（DaemonSet），采集 OTLP、kubeletstats、hostmetrics、容器日志
- 能操作：用 `Instrumentation` CR + Pod 注解实现 Python 零代码注入，并说清各语言注入机制的差异
- 能把 agent 与练习集群的 Prometheus 栈（ServiceMonitor）整合成一条完整拓扑

## 1. Operator 做什么

第 3 章的 Collector 是一个 YAML 配一个实例；进了 K8s，OTel Operator 把"实例"变成资源对象：

| CRD | 管什么 |
|---|---|
| `OpenTelemetryCollector` | Collector 的部署与升级：`mode` 支持 deployment / daemonset / sidecar；嵌套第 3 章讲过的 `config`；自动创建同名 Service、ServiceAccount、ConfigMap |
| `Instrumentation` | 零代码注入的"全局配置"：OTLP 端点、propagators、采样器、各语言 agent 镜像与环境变量 |
| `OpAMPBridge` | 远程管理 Collector 配置的通道（本模块不展开） |

关键机制是 **mutating webhook**：带注入注解的 Pod 创建时，Operator 修改其 spec（插 init 容器、注入环境变量）——这就是"零代码"的实现位置。webhook 需要 TLS 证书，因此**安装 Operator 前必须先装 cert-manager**（Operator 用它签发 webhook 证书）。

版本纪律：Operator 与各语言注入镜像迭代快且版本彼此独立，本文统一用 `latest` 安装，动手前以 https://github.com/open-telemetry/opentelemetry-operator 的 release 页为准。

## 2. 安装 cert-manager 与 Operator

```bash
# [master]
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/latest/download/cert-manager.yaml
kubectl -n cert-manager wait --for=condition=Available deployment --all --timeout=300s
```

预期输出：`deployment.apps/cert-manager condition met`（共 3 个 deployment 就绪）。

```bash
# [master]
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml
kubectl -n opentelemetry-operator-system wait --for=condition=Available deployment --all --timeout=300s
kubectl get crd | grep opentelemetry
```

预期输出包含 `instrumentations.opentelemetry.io` 与 `opentelemetrycollectors.opentelemetry.io`。

```bash
# [master] 本实验专用命名空间
kubectl create namespace otel
```

## 3. 第一个 Collector CR：跑通 debug 管道

```yaml
# [master] kubectl apply -f hello-collector.yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: hello-collector
  namespace: otel
spec:
  config:
    receivers:
      otlp:
        protocols:
          grpc: {}
          http: {}
    processors:
      batch: {}
    exporters:
      debug:
        verbosity: detailed
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [batch]
          exporters: [debug]
```

```bash
# [master]
kubectl -n otel get pods,svc
```

预期（命名规则：资源名 + `-collector`）：

```
NAME                                          READY   STATUS    RESTARTS
hello-collector-collector-7d8f9c6b5-x2k4p     1/1     Running   0

NAME                                  TYPE        CLUSTER-IP     PORT(S)
hello-collector-collector             ClusterIP   10.96.x.x      4317/TCP,4318/TCP
```

灌一条 trace 进去验证管道（在集群内起一个一次性 Pod，通过 Service 名直连 Collector 的 4317）：

```bash
# [master]
kubectl -n otel run telemetrygen --rm -i --restart=Never \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  -- traces --otlp-insecure --otlp-endpoint hello-collector-collector:4317 --traces 1
```

```bash
# [master] 观察:debug exporter 把 span 打出来
kubectl -n otel logs -f deploy/hello-collector-collector -c otc-container
```

预期日志里出现 span 明细（含 Resource、Attributes）。容器名固定为 `otc-container`。

## 4. 节点 agent（DaemonSet）：采集 OTLP + K8s 面 + 主机面

目标形态（先看图再动手，每一段都对应下方 YAML 的一块）：

```
 练习集群 (kubeadm 单 master + Calico)
 ─────────────────────────────────────────────────────────────────
   业务 Pod (SDK / Operator 自动注入)
       │  OTLP http/protobuf :4318
       ▼
   otel-agent   [OpenTelemetryCollector CR, mode: DaemonSet, 每节点一个]
     ├─ otlp receiver   ← 应用的 traces / metrics / logs
     ├─ kubeletstats    ← kubelet :10250 容器资源指标
     ├─ hostmetrics     ← /hostfs 主机指标
     ├─ filelog         ← /var/log/pods 容器日志
     └─ k8sattributes   ← 反查 apiserver,补 k8s.* 元数据
       │
       ├─ traces  ──► Jaeger (集群内 Deployment, UI :16686)
       └─ metrics ──► :8889 ◄── ServiceMonitor ◄── Prometheus
                        (练习集群 kube-prometheus-stack / PCA 栈)
```

### 4.1 先部署集群内 Jaeger（承接 traces）

```yaml
# [master] kubectl apply -f jaeger-incluster.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: jaeger
  namespace: otel
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
          image: jaegertracing/all-in-one:latest
          env:
            - name: COLLECTOR_OTLP_ENABLED
              value: "true"
          ports:
            - containerPort: 16686
            - containerPort: 4317
            - containerPort: 4318
---
apiVersion: v1
kind: Service
metadata:
  name: jaeger
  namespace: otel
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
```

（内存存储，仅实验用。）

### 4.2 完整 agent CR

在 3 章的配置上加四路采集。注意三个 K8s 特有件：`tolerations`（单 master 集群必须，否则 DaemonSet 不上控制面节点）、`spec.env` 用 Downward API 注入节点名、hostPath 挂载主机目录：

```yaml
# [master] kubectl apply -f otel-agent.yaml
apiVersion: opentelemetry.io/v1beta1
kind: OpenTelemetryCollector
metadata:
  name: otel-agent
  namespace: otel
spec:
  mode: daemonset
  tolerations:
    - key: node-role.kubernetes.io/control-plane   # 单 master 练习集群必需
      operator: Exists
      effect: NoSchedule
  env:
    - name: K8S_NODE_NAME
      valueFrom:
        fieldRef:
          fieldPath: spec.nodeName
  volumes:
    - name: varlogpods
      hostPath:
        path: /var/log/pods                        # 容器日志原始位置
    - name: varlibdockercontainers
      hostPath:
        path: /var/lib/docker/containers
    - name: hostfs
      hostPath:
        path: /                                     # 主机根,给 hostmetrics 用
  volumeMounts:
    - name: varlogpods
      mountPath: /var/log/pods
      readOnly: true
    - name: varlibdockercontainers
      mountPath: /var/lib/docker/containers
      readOnly: true
    - name: hostfs
      mountPath: /hostfs
      readOnly: true
  ports:
    - name: otlp-grpc
      port: 4317
      protocol: TCP
    - name: prom-metrics
      port: 8889
      protocol: TCP
  config:
    receivers:
      otlp:
        protocols:
          grpc:
            endpoint: 0.0.0.0:4317
          http:
            endpoint: 0.0.0.0:4318
      kubeletstats:
        collection_interval: 30s
        auth_type: serviceAccount
        endpoint: https://${env:K8S_NODE_NAME}:10250
        insecure_skip_verify: true
      hostmetrics:
        root_path: /hostfs                          # 不指过去就只能看到容器自己的 /proc
        scrapers:
          cpu: {}
          memory: {}
          load: {}
          disk: {}
          network: {}
          filesystem:
            exclude_mount_points:
              mount_points: [/dev/*, /proc/*, /sys/*, /run/*, /var/lib/docker/*]
            exclude_fs_types:
              fs_types: [sysfs, tmpfs, devtmpfs, overlay, proc, ramfs]
      filelog:
        include:
          - /var/log/pods/*/*/*.log
        start_at: end
        include_file_path: true
        operators:
          - type: regex_parser                      # K8s 日志行格式: 时间 流 标志 正文
            id: parse_line
            regex: '^(?P<time>\d{4}-\d{2}-\d{2}T[^\s]+) (?P<stream>stdout|stderr) (?P<logtag>[FP]) (?P<message>.*)$'
          - type: time_parser
            parse_from: attributes.time
            format: RFC3339Nano
          - type: move
            from: attributes.message
            to: body
          - type: regex_parser                      # 从文件路径抠出 ns/pod/容器
            id: extract_meta
            parse_from: attributes["log.file.name"]
            regex: '^.*pods/(?P<namespace>[^_]+)_(?P<pod_name>[^_]+)_(?P<pod_uid>[a-f0-9\-]{36})/(?P<container_name>[^\.\d]+)/(?P<retry_count>\d+)\.log$'
          - type: move
            from: attributes.namespace
            to: resource["k8s.namespace.name"]
          - type: move
            from: attributes.pod_name
            to: resource["k8s.pod.name"]
          - type: move
            from: attributes.container_name
            to: resource["k8s.container.name"]
    processors:
      memory_limiter:
        check_interval: 1s
        limit_mib: 512
        spike_limit_mib: 128
      k8sattributes:
        node_from_env_var: K8S_NODE_NAME            # 只反查本节点,省 apiserver 压力
        extract:
          metadata:
            - k8s.namespace.name
            - k8s.pod.name
            - k8s.node.name
            - k8s.deployment.name
        pod_association:
          - sources:
              - from: resource_attribute
                name: k8s.pod.ip
      batch:
        timeout: 5s
        send_batch_size: 1024
    exporters:
      otlp/jaeger:
        endpoint: jaeger.otel.svc.cluster.local:4317
        tls:
          insecure: true
        sending_queue:
          enabled: true
          queue_size: 4096
        retry_on_failure:
          enabled: true
          initial_interval: 1s
          max_interval: 30s
          max_elapsed_time: 120s
      prometheus:
        endpoint: 0.0.0.0:8889                      # 给练习集群的 Prometheus 拉
      debug:
        verbosity: basic
    service:
      pipelines:
        traces:
          receivers: [otlp]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [otlp/jaeger]
        metrics:
          receivers: [otlp, kubeletstats, hostmetrics]
          processors: [memory_limiter, k8sattributes, batch]
          exporters: [prometheus]
        logs:
          receivers: [otlp, filelog]
          processors: [memory_limiter, batch]
          exporters: [debug]                        # 日志后端接法见第 3 章配方 C
```

### 4.3 RBAC（k8sattributes 与 kubeletstats 都要）

```yaml
# [master] kubectl apply -f otel-agent-rbac.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: otel-agent-role
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces"]       # k8sattributes 反查元数据
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["replicasets"]              # 追溯 deployment 名
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["nodes/stats"]              # kubeletstats 读 /stats/summary
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: otel-agent-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: otel-agent-role
subjects:
  - kind: ServiceAccount
    name: otel-agent-collector              # Operator 自动创建的 SA: <CR 名>-collector
    namespace: otel
```

### 4.4 验证

```bash
# [master]
kubectl -n otel get pods -o wide                 # DaemonSet 应在 master 上 Running
kubectl -n otel logs ds/otel-agent-collector | tail -n 5
kubectl -n otel port-forward svc/otel-agent-collector 8889:8889 &
curl -s http://127.0.0.1:8889/metrics | grep -m 3 '^k8s_'
```

预期：`curl` 能看到 `k8s_` 开头的 kubeletstats/hostmetrics 指标（如 `k8s_pod_cpu_usage`、`k8s_node_memory_usage`，具体名称以 receiver 文档为准）。日志管道当前走 debug exporter，`kubectl logs` 里能直接看到集群各容器的日志行被收集。

## 5. Instrumentation CR：零代码注入

### 5.1 创建 Instrumentation CR

```yaml
# [master] kubectl apply -f instrumentation.yaml
apiVersion: opentelemetry.io/v1beta1
kind: Instrumentation
metadata:
  name: lab-instrumentation
  namespace: otel
spec:
  exporter:
    endpoint: http://otel-agent-collector:4318    # agent 的 Service 名 + OTLP/HTTP 端口
  propagators:
    - tracecontext
    - baggage
  sampler:
    type: parentbased_always_on
  python:
    env:
      - name: OTEL_EXPORTER_OTLP_PROTOCOL          # 显式声明协议,不赌各语言默认值
        value: http/protobuf
```

### 5.2 一个"无埋点"应用 + 一条注解

应用用公共镜像 + ConfigMap 挂脚本，启动时现装 flask（首次拉取依赖约需 1 分钟）：

```yaml
# [master] kubectl apply -f flask-demo.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: flask-demo-app
  namespace: otel
data:
  app.py: |
    from flask import Flask, jsonify
    import requests

    app = Flask(__name__)

    @app.get("/api/order")
    def order():
        r = requests.get("http://flask-demo:5000/api/inventory", timeout=3)
        return jsonify(order="ok", items=r.json()["items"])

    @app.get("/api/inventory")
    def inventory():
        return jsonify(items=42)
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-demo
  namespace: otel
spec:
  replicas: 1
  selector:
    matchLabels:
      app: flask-demo
  template:
    metadata:
      labels:
        app: flask-demo
      annotations:
        instrumentation.opentelemetry.io/inject-python: "true"   # 唯一要加的一行
    spec:
      containers:
        - name: flask-demo
          image: python:3.12-slim
          command: ["/bin/sh", "-c"]
          args:
            - pip install --quiet flask requests && python /app/app.py
          ports:
            - containerPort: 5000
          volumeMounts:
            - name: app
              mountPath: /app
      volumes:
        - name: app
          configMap:
            name: flask-demo-app
---
apiVersion: v1
kind: Service
metadata:
  name: flask-demo
  namespace: otel
spec:
  selector:
    app: flask-demo
  ports:
    - port: 5000
      targetPort: 5000
```

```bash
# [master] 验证注入:应看到注入的 init 容器
kubectl -n otel get pod -l app=flask-demo -o jsonpath='{.items[0].spec.initContainers[*].name}'
echo
# 打流量
kubectl -n otel port-forward svc/flask-demo 5000:5000 &
curl -s http://127.0.0.1:5000/api/order
# 看 trace
kubectl -n otel port-forward svc/jaeger 16686:16686 &
```

预期：jsonpath 输出形如 `otel-agent-inject-python`（init 容器名以实际为准）；curl 返回 `{"items":42,"order":"ok"}`；浏览器（本地 Windows）打开 `http://localhost:16686`，Service `flask-demo` 下出现 trace：`GET /api/order`(SERVER) + `GET`(CLIENT) + `GET /api/inventory`(SERVER)，并且 span 上带有 k8sattributes 补的 `k8s.pod.name` 等资源属性。

### 5.3 各语言注入机制差异

| 语言 | Pod 注解 | 原理 | 特别注意 |
|---|---|---|---|
| Java | `instrumentation.opentelemetry.io/inject-java: "true"` | init 容器复制 javaagent，`JAVA_TOOL_OPTIONS` 挂上 | 最成熟，首选试点语言 |
| Python | `inject-python: "true"` | init 容器把 wheel 装进共享卷，设 `PYTHONPATH` 生效 | 应用镜像 Python 版本要兼容；协议建议显式声明 |
| Node.js | `inject-nodejs: "true"` | 复制 node_modules，`NODE_OPTIONS=--require` | 多容器 Pod 需 `container-names` 指定目标容器 |
| .NET | `inject-dotnet: "true"` | 共享卷 + CLR profiler 环境变量 | 依赖 profiler 机制，见官方 zero-code .NET 文档 |
| Go | `inject-go: "true"` | eBPF 探针 init 容器 | 还需 `instrumentation.opentelemetry.io/otel-go-auto-target-exe` 指定目标二进制路径，且有内核版本要求；以官方文档为准 |
| 已手动埋点 | `inject-sdk: "true"` | 只注入 `OTEL_*` 环境变量，不装 agent | 给自带 SDK 的应用统一配置 |
| Collector sidecar | `sidecar.opentelemetry.io/inject: "true"` | 注入一个 sidecar Collector | 值可为布尔或某个 Collector CR 名 |

三条通用规则：

1. 注解可以打在 **namespace** 上（全量生效），也可以打在 **Pod template** 上（精确控制）；值可以是 `"true"`（用同 namespace 的唯一 Instrumentation）或直接写 CR 名；
2. **注入只发生在 Pod 创建时**——给已有 Deployment 加注解必须触发滚动重启（`kubectl rollout restart`）才生效；
3. 多容器 Pod 用 `instrumentation.opentelemetry.io/container-names: "<容器名>"` 告诉 Operator 该动哪个容器（Go/Node.js 必需）。

## 实战演练：与练习集群 Prometheus 栈整合

前提：已用 `scripts/setup/install-prom-stack.sh` 装好 kube-prometheus-stack（含 Prometheus Operator）。整合点是 agent 的 8889 端口——按 PCA 的老路子：ServiceMonitor 让 Prometheus 来拉。

```bash
# [master] 先弄清 Prometheus 实例挑选 ServiceMonitor 的标签
kubectl get prometheus -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.spec.serviceMonitorSelector.matchLabels}{"\n"}{end}'
# 再核对 agent Service 的标签(ServiceMonitor 的 selector 要能选中它)
kubectl -n otel get svc otel-agent-collector --show-labels
```

```yaml
# [master] kubectl apply -f otel-agent-servicemonitor.yaml
# 注意 release 标签的值要改成上面第一条命令查到的内容
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: otel-agent
  namespace: otel
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/managed-by: opentelemetry-operator
      app.kubernetes.io/instance: otel.otel-agent
  namespaceSelector:
    matchNames:
      - otel
  endpoints:
    - port: prom-metrics
      interval: 30s
```

```bash
# [master] 验证 target 已被抓取(或浏览器打开 Prometheus UI 的 Status->Targets)
kubectl -n <prometheus 的 ns> port-forward svc/<prometheus service> 9090:9090 &
curl -s http://127.0.0.1:9090/api/v1/targets | grep -o 'otel-agent[^"]*' | head -n 3
```

Prometheus 里跑两条查询验证数据在（Grafana Explore 同样可用）：

```promql
# [本地Windows] 在 Prometheus/Grafana Explore 中执行:agent 存活与 K8s 指标
up{job=~".*otel-agent.*"}
```

```promql
# [本地Windows] 每 Pod 内存用量(指标名以 kubeletstats 文档为准,可先搜 {__name__=~"k8s\..+"})
topk(5, k8s.pod.memory.usage)
```

至此完整拓扑成立：**应用(注解注入) → agent(DaemonSet, 富化+缓冲) → Jaeger(traces) + Prometheus(metrics, ServiceMonitor 拉) + debug/任意后端(logs)**。要加 Loki，把 logs pipeline 的 exporter 换成第 3 章配方 C 的 `otlphttp/loki` 即可。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 创建 CR 后一直不出现 pod | cert-manager 未就绪，webhook 起不来 | `kubectl -n opentelemetry-operator-system get pods` 与 logs 排查，重装前先装 cert-manager |
| DaemonSet 显示 0/1，master 上没有 | 控制面 taint 未容忍 | CR 里加 `node-role.kubernetes.io/control-plane` 的 toleration |
| filelog 收不到任何日志 | 没挂 `/var/log/pods` hostPath | 对照 4.2 的 volumes/volumeMounts |
| hostmetrics 数值明显是容器自己的 | 没挂 hostfs 或没设 `root_path` | 挂载主机根到 `/hostfs` 并配置 `root_path: /hostfs` |
| span 上没有 k8s.* 属性 | RBAC 缺失或 pod_association 匹配不上 | 对照 4.3 的 ClusterRole；`kubectl logs` 里看 k8sattributes 报错 |
| 加了注解却没注入 | 注解打在已有 Deployment 上但没重启 | `kubectl rollout restart deploy/<name>`；确认注解在 pod template 而非 Deployment 顶层 |
| Python 应用注入后 CrashLoop | init 容器与镜像 Python 版本/架构不兼容，或协议与端口不匹配 | 换匹配的 python 镜像；`OTEL_EXPORTER_OTLP_PROTOCOL` 与 4317/4318 配套 |
| Prometheus 抓不到 agent | ServiceMonitor 的 release 标签或 selector 不匹配 | 用实战演练一节的两条 jsonpath 命令现场对齐标签 |

## 自测

1. 为什么 Operator 强依赖 cert-manager？去掉它会坏什么功能？

<details><summary>答案</summary>

Operator 的核心机制之一是 mutating webhook（Pod 注入、Collector CR 的默认值写入）。kube-apiserver 调 webhook 强制走 TLS，证书由 cert-manager 签发与轮换。没有 cert-manager，webhook 起不来或 apiserver 拒绝调用，于是 Instrumentation 注入失效、部分 CR 变换失败——Collector 本身的部署可能还在，但"零代码注入"这条腿断了。
</details>

2. 单 master 练习集群上 DaemonSet agent 不加 tolerations 会怎样？如何现场确认是 taint 问题？

<details><summary>答案</summary>

kubeadm 默认给 master 打 `node-role.kubernetes.io/control-plane:NoSchedule`，DaemonSet pod 会 Pending（单节点集群则完全调度不上）。确认：`kubectl get events` 看到 FailedScheduling 提及 taint，或 `kubectl describe node <master> | grep -A3 Taints`。解法是 CR 里加对应 toleration（本实验的做法），生产上则应该把采集面放在 worker 节点上。
</details>

3. kubeletstats 和 Prometheus 常用的 cAdvisor/kube-state-metrics 各覆盖什么？为什么要三个都用？

<details><summary>答案</summary>

kubeletstats 走 kubelet 的 `/stats/summary`，提供容器/pod/node 三级的用量（CPU/内存/网络/卷）；cAdvisor（kubelet 内置、由 Prometheus 直接抓）粒度类似但来源与标签体系不同；kube-state-metrics 提供的是"对象状态"而非资源用量（副本数、重启次数、pod phase）。三者互补：用量看 kubeletstats/cAdvisor，状态看 kube-state-metrics。OTel agent 用 kubeletstats 的好处是与 traces/logs 同一条管道、同一套 k8s.* 标签。
</details>

4. 为什么 filelog 的 `start_at: end` 对练习环境很重要？默认值会带来什么现象？

<details><summary>答案</summary>

`start_at: end` 让 agent 从文件末尾开始读，只收新产生的日志。若从头读，agent 一启动会把节点上全部历史容器日志（可能几千个文件、GB 级）灌进管道，练习集群的后端（debug/Jaeger）瞬间被打爆。生产上要配合保留策略与过滤（include/exclude、drop processor）权衡历史回填与冲击。
</details>

5. 假设 Instrumentation CR 被误删，正在运行的带注入 Pod 会立刻失去埋点吗？为什么？

<details><summary>答案</summary>

不会。注入发生在 Pod 创建那一刻（webhook 把 init 容器、PYTHONPATH、OTEL_* env 写进 pod spec），之后这些内容随 Pod 生命周期存在，不依赖 CR 存活。受影响的是**新建/重建的 Pod**——没有 CR 时 webhook 不注入（Pod 可能仍能启动，只是没有埋点）。这也是排查"同一个 Deployment 有的 Pod 有 trace 有的没有"时要先看 Pod 创建时间的原因。
</details>

## 延伸阅读

- OTel Operator 官方文档：https://opentelemetry.io/docs/platforms/kubernetes/operator/
- 注解速查（零代码注入）：https://opentelemetry.io/docs/platforms/kubernetes/operator/automatic/
- Operator 仓库（版本以 release 页为准）：https://github.com/open-telemetry/opentelemetry-operator
- cert-manager 安装：https://cert-manager.io/docs/installation/
- kubeletstats receiver：https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/kubeletstatsreceiver
- hostmetrics receiver：https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/hostmetricsreceiver
- filelog receiver（stanza operators）：https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/receiver/filelogreceiver
