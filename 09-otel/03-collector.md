# 03 · Collector：架构、部署模式与经典配方

> 模块：OpenTelemetry（06）｜ 建议时长：2.5 小时 ｜ 前置：00~02 章 ｜ 关联认证：—（无直接考点，PCA 进阶）

## 学习目标

- 能解释 Collector 的三段式架构（receivers → processors → exporters 组成 pipelines）及其 YAML 结构
- 能对比三种部署模式（sidecar / 节点 agent DaemonSet / 中心 gateway）并给出选型理由
- 能配置常用 processor：batch、memory_limiter、attributes、k8sattributes，以及 exporter 级的重试与排队
- 能操作：在 VM 上独立跑通三条经典配方——OTLP→Jaeger、OTLP→Prometheus remote write、OTLP→Loki

## 1. Collector 是什么

Collector 是一个独立的二进制（Go 编写），是 OTel 体系里的"数据平面"：接收各种来源的遥测、做富化/采样/脱敏/批量，再分发给任意多个后端。它不依赖任何应用 SDK，单独就能用（比如只拿它收集 K8s 节点指标和容器日志，见第 4 章）。

两个官方发行版（版本迭代快，**以官方 release 页为准**，本模块统一用 contrib 镜像演示）：

| 发行版 | 内容 | 适用 |
|---|---|---|
| `otelcol`（core） | 核心 receiver/processor/exporter（OTLP、debug、batch、memory_limiter 等） | 只要 OTLP 进 OTLP 出 |
| `otelcol-contrib` | core + 上百个社区组件（k8sattributes、filelog、hostmetrics、prometheus…） | 现实中的默认选择 |

发布页：https://github.com/open-telemetry/opentelemetry-collector-releases
组件目录：https://github.com/open-telemetry/opentelemetry-collector-contrib

## 2. 架构：三段组件拼成 pipelines

```
   receivers                  processors                    exporters
┌────────────┐   ┌─────────────────────────────┐   ┌──────────────────┐
│ otlp       │   │ memory_limiter (永远第一)    │   │ otlp/jaeger      │
│ filelog    │──►│ k8sattributes (富化元数据)   │──►│ prometheus       │
│ kubeletstats│  │ attributes  (改/删/哈希属性) │   │ prometheusremotewrite│
│ hostmetrics│   │ batch      (攒批发送)        │   │ otlphttp/loki    │
│ prometheus │   │ tail_sampling (尾部采样)     │   │ debug            │
└────────────┘   └─────────────────────────────┘   └──────────────────┘
      │                  按信号分道                       │
      └────── traces / metrics / logs 三条 pipeline ──────┘

   另有两类配角：connectors（把一条 pipeline 的输出当另一条的输入，如路由/计数），
               extensions（不碰数据流的周边能力，如健康检查 health_check、pprof）
```

对应的 YAML 骨架（组件定义 + service 引用，**没被 service 引用的组件不生效**）：

```yaml
# [任意节点] Collector 配置骨架示意
receivers:
  otlp:                     # 组件名/实例名
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128
  batch:
    timeout: 5s
    send_batch_size: 1024

exporters:
  debug:
    verbosity: detailed     # 实验期看明细,量产改 basic

service:
  pipelines:
    traces:                 # 三种信号各自独立组管道
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [debug]
```

要点：

- 组件实例名可以带后缀区分用途（`otlp/jaeger`、`otlphttp/loki`），斜杠前是类型；
- processors 的**数组顺序就是执行顺序**，顺序错了语义就错（后面细讲）；
- Collector 自身默认在 8888 端口暴露自己的内部指标（`otelcol_...`），生产上应该把它自己也监控起来。

## 3. 部署模式：sidecar、节点 agent、中心 gateway

```
 模式一 sidecar             模式二 节点 agent(DaemonSet)      模式三 中心 gateway(Deployment)
┌────────────────┐         ┌──────────────────────────┐     ┌────────────────────────┐
│ Pod            │         │ node1  pods──►┌────────┐ │OTLP │  gateway (可多副本)      │
│  app           │         │               │ agent  │ │────►│  富化/尾部采样/路由       │
│  collector     │         │ node2  pods──►└────────┘ │     │   ├─► Jaeger            │
│  (localhost:   │         │ node3  pods──►┌────────┐ │     │   ├─► Prometheus        │
│   4317)        │         │               │ agent  │ │     │   └─► Loki              │
└────────────────┘         │               └────────┘ │     └────────────────────────┘
                           └──────────────────────────┘
```

| 模式 | 实例数 | 优点 | 缺点 | 典型场景 |
|---|---|---|---|---|
| sidecar | 每 Pod 一个 | 与应用同生命周期、网络隔离好、按应用配策略 | 资源开销 × Pod 数、运维面大 | 强隔离的多租户、Serverless |
| 节点 agent | 每节点一个 | 资源省、能采节点面数据（kubeletstats/hostmetrics/容器日志）、应用只配一个地址 | 单点=整节点；升级影响全节点 | K8s 采集的默认选择 |
| 中心 gateway | 少量（可扩缩） | 统一策略（脱敏、尾部采样）、对接多后端的收敛点 | 跨可用区流量、需要高可用与容量规划 | 中大规模的二级汇聚 |

规模上来了就是分层：**应用 → 节点 agent → 中心 gateway → 后端们**。agent 负责"近源"（k8s 元数据富化、快速截断），gateway 负责"全局"（tail sampling、路由、限流）。练习集群规模小，第 4 章只部署 agent 一层。

## 4. 常用 processor 逐个拆

### 4.1 memory_limiter —— 永远放第一位

```yaml
# [任意节点] 片段:memory_limiter(完整可运行配置见实战演练)
processors:
  memory_limiter:
    check_interval: 1s     # 检查间隔
    limit_mib: 512         # 软上限:到达后开始拒绝数据并置 circuit breaker
    spike_limit_mib: 128   # 突发缓冲:硬上限 = limit + spike
```

作用：在 OOM 杀进程之前主动丢数据保命。必须放在 processors 数组**第一位**（放在 batch 之后会因 batch 持有数据而失效）。配套建议：容器 memory limit 与 `limit_mib` 留出余量，并可设 `GOMEMLIMIT` 让 Go runtime 同时收敛 GC。

### 4.2 batch —— 性价比最高的优化

```yaml
# [任意节点] 片段:batch
processors:
  batch:
    timeout: 5s           # 默认 200ms
    send_batch_size: 1024 # 攒够或超时即发
    send_batch_max_size: 2048
```

把小请求合并成大批，减少对后端的 RPC 次数。代价是引入至多 `timeout` 的延迟——tracing 排障场景一般可接受，实时告警链路要评估。默认值以所装版本文档为准。

### 4.3 attributes —— 进后端前的最后一道手

```yaml
# [任意节点] 片段:attributes 脱敏/改写
processors:
  attributes/scrub:
    actions:
      - key: customer.email          # 删敏感属性
        action: delete
      - key: customer.id             # 不可逆哈希
        action: hash
      - key: deployment.environment  # 没有则补,有则覆盖
        value: lab
        action: upsert
```

| action | 语义 |
|---|---|
| `insert` / `update` | 仅当键不存在 / 仅当键已存在 时写入 |
| `upsert` | 不存在则建、存在则覆盖 |
| `delete` | 删除键 |
| `hash` | SHA-1 哈希值（脱敏但可对账） |
| `extract` | 用正则从现有属性抽取新键 |
| `convert` | 改类型 |

### 4.4 k8sattributes —— 给数据打上 K8s 身份

```yaml
# [任意节点] 片段:k8sattributes 元数据富化(RBAC 见第 4 章)
processors:
  k8sattributes:
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.pod.name
        - k8s.node.name
        - k8s.deployment.name
      labels:
        - tag_name: app      # 把 pod label app=xxx 变成资源属性 app
          key: app
          from: pod
    pod_association:
      - sources:
          - from: resource_attribute
            name: k8s.pod.ip
```

原理：Collector 用 pod IP 反查 kube-apiserver，把 namespace/pod/deployment/label 写进资源的 `k8s.*` 属性——之后 PromQL、Jaeger 服务名、Grafana 变量都能按 K8s 维度切。前提两条：给 Collector 的 ServiceAccount 配 RBAC（`pods`、`namespaces` 的 get/list/watch，见第 4 章）；DaemonSet 模式下用环境变量把范围限定在本节点（`node_from_env_var`），避免每个 agent 都缓存全集群元数据。

### 4.5 重试与排队 —— 配在 exporter 上

后端抖动不可避免，可靠性配置长在 exporter 一级（新版 Collector 已把它标准化为所有 exporter 的公共配置，个别组件以文档为准）：

```yaml
# [任意节点] 片段:exporter 级重试与排队
exporters:
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true
    sending_queue:
      enabled: true
      num_consumers: 4
      queue_size: 4096        # 后端不可用时最多缓冲的数据量
    retry_on_failure:
      enabled: true
      initial_interval: 1s
      max_interval: 30s
      max_elapsed_time: 120s  # 超过则放弃(丢弃)
```

理解成"应用 → Collector"和"Collector → 后端"是两段独立的缓冲：SDK 侧有自己的批量队列，Collector 侧靠 sending_queue。queue 满了依然会丢——容量按"后端最长可预期故障时长 × 吞吐"估算。

## 实战演练：三条经典配方（Docker VM）

环境：装有 Docker 的 Ubuntu 22.04/24.04 VM。全部命令在同一目录下执行，镜像用 `latest`（版本以官方 release 页为准）。

### 配方 0：最小管道，先看见数据

```bash
# [任意节点]（带 Docker 的 Ubuntu VM）
docker network create otelnet

docker run -d --name jaeger --network otelnet \
  -p 16686:16686 -e COLLECTOR_OTLP_ENABLED=true \
  jaegertracing/all-in-one:latest
```

```yaml
# [任意节点] 保存为 ~/recipe-basic.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128
  batch:
    timeout: 5s
    send_batch_size: 1024

exporters:
  otlp/jaeger:
    endpoint: jaeger:4317
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
  debug:
    verbosity: basic

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlp/jaeger, debug]
```

```bash
# [任意节点]
docker run -d --name otelcol --network otelnet \
  -p 4317:4317 -p 4318:4318 \
  -v ~/recipe-basic.yaml:/etc/otelcol-contrib/config.yaml \
  ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:latest

# 打 3 条 trace 进 Collector
docker run --rm --network otelnet \
  ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  traces --otlp-insecure --otlp-endpoint otelcol:4317 --traces 3

# 观察:Collector 日志应有转发/导出记录
docker logs otelcol 2>&1 | tail -n 5
```

浏览器打开 `http://<VM_IP>:16686`，Service 里选 `otel-otlp-trace-tester`，能看到 3 条 trace——这一步验证了配方 A（OTLP→Jaeger）已经成立：`telemetrygen → Collector(4317) → Jaeger`。

### 配方 B：OTLP → Prometheus remote write

remote write 是"推"模式：Collector 主动把指标写进 Prometheus，省掉拉取发现那一层。先把 Prometheus 起成可接收 remote write 的模式：

```bash
# [任意节点]
docker run -d --name prom-rw -p 9090:9090 \
  prom/prometheus:latest \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/prometheus \
  --web.enable-remote-write-receiver
```

```yaml
# [任意节点] 保存为 ~/recipe-promrw.yaml(在 recipe-basic.yaml 基础上改)
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128
  batch:
    timeout: 5s
    send_batch_size: 1024

exporters:
  prometheusremotewrite:
    endpoint: http://prom-rw:9090/api/v1/write

service:
  pipelines:
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [prometheusremotewrite]
```

```bash
# [任意节点]
docker rm -f otelcol
docker run -d --name otelcol --network otelnet \
  -p 4317:4317 -p 4318:4318 \
  -v ~/recipe-promrw.yaml:/etc/otelcol-contrib/config.yaml \
  ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:latest

# 发 5 条指标序列
docker run --rm --network otelnet \
  ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  metrics --otlp-insecure --otlp-endpoint otelcol:4317 --metrics 5

# 验证:查 Prometheus 里已出现的指标名
curl -s http://localhost:9090/api/v1/label/__name__/values | head -c 300
```

预期返回 JSON 里出现 telemetrygen 生成的指标名（形如 `gauge-*`，以实际输出为准）。`--web.enable-remote-write-receiver` 是必开的开关，否则写入接口的路由未注册，全部请求 404。

变体（与 PCA 栈更搭的"拉"模式）：把 exporter 换成 `prometheus`（`endpoint: 0.0.0.0:8889`），Collector 自己暴露 `/metrics`，由 Prometheus 的 scrape + ServiceMonitor 来拉——K8s 里的完整做法见第 4 章。两种方式二选一即可，别同时给同一份数据走两条路（会双倍序列）。

### 配方 C：OTLP → Loki

Loki 3.x 起原生接收 OTLP 日志（端点在 `/otlp/v1/logs`，能力状态以 Loki 官方文档为准）：

```bash
# [任意节点]
docker run -d --name loki -p 3100:3100 \
  grafana/loki:latest \
  -config.file=/etc/loki/local-config.yaml
```

```yaml
# [任意节点] 保存为 ~/recipe-loki.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512
    spike_limit_mib: 128
  batch:
    timeout: 5s
    send_batch_size: 1024

exporters:
  otlphttp/loki:
    endpoint: http://loki:3100/otlp     # exporter 会自动追加 /v1/logs

service:
  pipelines:
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch]
      exporters: [otlphttp/loki]
```

```bash
# [任意节点]
docker rm -f otelcol
docker run -d --name otelcol --network otelnet \
  -p 4317:4317 -p 4318:4318 \
  -v ~/recipe-loki.yaml:/etc/otelcol-contrib/config.yaml \
  ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:latest

# 发 5 条日志
docker run --rm --network otelnet \
  ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  logs --otlp-insecure --otlp-endpoint otelcol:4317 --logs 5

# 验证一:Loki 已生成的标签(OTLP 的 resource 属性会变成 Loki 标签,如 service_name)
curl -s http://localhost:3100/loki/api/v1/labels

# 验证二:直接查日志内容
curl -sG "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={service_name=~".+"}' \
  --data-urlencode 'limit=5' | head -c 500
```

预期返回 JSON 的 `result` 里有 5 条 body 为 `Log` 的日志行。注意 Loki 的标签来自 resource 属性（`service.name` → `service_name`），高基数属性（如 `trace_id`）默认不会成为标签，而是在日志体里——这正是"标签低基数、正文高基数"的 Loki 哲学。

### 收尾清理

```bash
# [任意节点]
docker rm -f otelcol jaeger prom-rw loki
docker network rm otelnet
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 改了组件配置却毫无变化 | 组件没被 `service.pipelines` 引用，或挂载路径/文件名不对 | 确认 pipelines 里引用了实例名；contrib 镜像默认读 `/etc/otelcol-contrib/config.yaml` |
| remote write 全部 404 | Prometheus 没开 receiver，`/api/v1/write` 路由未注册 | 启动参数加 `--web.enable-remote-write-receiver` |
| Collector 被OOMKilled | memory_limiter 缺失或放在 batch 之后，或 limit 贴着容器 limit | memory_limiter 放首位，`limit_mib` 低于容器 memory limit 约 20% |
| k8sattributes 报权限/属性不出现 | SA 没有 RBAC，或 pod_association 匹配不上 | 见第 4 章的 ClusterRole；默认按 `k8s.pod.ip` 关联 |
| Jaeger 一直没数据但 Collector 无报错 | exporters 的 endpoint 用了 service 名但不在同一网络 | docker 场景加 `--network`；K8s 场景核对 service FQDN 与端口 |
| Loki 收不到日志 | Loki 版本 < 3.x 不支持 OTLP intake，或 endpoint 没写到 `/otlp` | 升级 Loki；`otlphttp` 的 endpoint 填 `http://loki:3100/otlp`（自动拼 `/v1/logs`） |
| 同一份数据在后端出现两倍序列 | 同时配了 pull（8889）和 push（remote write） | 一个信号只选一条通路 |

## 自测

1. 为什么 memory_limiter 必须是 processors 数组的第一个，而 batch 通常在最后一个附近？

<details><summary>答案</summary>

memory_limiter 的语义是"在入口处评估当前内存并拒绝新数据"。若排在 batch 之后，数据已被 batch 持有（发送队列里挂着），限流器看到的是"已经进来"的数据，起不到入口闸门作用，OOM 保护失效。batch 的作用是合并"即将导出"的数据，天然靠近管道末端，放在限流之后也不影响其聚合效果。
</details>

2. Collector 挂掉 30 秒，期间应用发生了什么？恢复后数据会怎样？

<details><summary>答案</summary>

SDK 侧的 BatchSpanProcessor/批量队列先在应用进程内堆积并重试（占应用内存），队列满后按各自策略丢弃（老数据让位新数据）。Collector 恢复后 SDK 重连继续发送，丢掉的部分永久缺失。因此可用性要求高的场景要么上 gateway 高可用多副本，要么接受这段语义上的"尽力而为"。
</details>

3. sidecar 模式下，应用和 Collector 之间还需要配 sending_queue/retry 吗？

<details><summary>答案</summary>

需要分层看：应用→sidecar 是 localhost，几乎不会失败，SDK 侧重试足够；sidecar→后端这段仍然要配 sending_queue/retry，因为后端和网络的抖动与部署位置无关。sidecar 的意义主要是隔离与生命周期绑定，不是省掉可靠性配置。
</details>

4. 你的指标经 Collector 进了 Prometheus，但所有 histogram 都消失、只有 counter/gauge 在。最可能的原因？

<details><summary>答案</summary>

temporality 不匹配：SDK 以 delta 时间性输出直方图时，Prometheus 的转换路径（prometheus exporter / remote write）不接受 delta 直方图会丢弃并记录警告。设 `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative`（各 SDK 环境变量名以文档为准）即可恢复，代价是 SDK 侧内存略增。
</details>

5. 什么情况下你会把 tail_sampling 从 gateway 下沉到（或上提到）别处？"下沉到每个节点 agent"可行吗？

<details><summary>答案</summary>

tail_sampling 必须看到整条 trace 才能决策，所以它属于"全量 span 的汇聚点"。节点 agent 只见本节点 span，不可行；正确位置是中心 gateway。若某些业务全链路都在单节点（如单机部署的旧应用），例外地可以在该节点 agent 上做，但这是特例。反过来，如果 gateway 需要尾部采样，SDK 侧就应高比例/全量头部采样，两层策略要一起设计。
</details>

## 延伸阅读

- Collector 官方文档：https://opentelemetry.io/docs/collector/
- 组件目录（receiver/processor/exporter 全列表）：https://github.com/open-telemetry/opentelemetry-collector-contrib
- 部署模式官方指引：https://opentelemetry.io/docs/collector/deployment/
- k8sattributes processor：https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/k8sattributesprocessor
- Prometheus remote write：https://prometheus.io/docs/prometheus/latest/storage/#remote-storage
- Loki OTLP intake：https://grafana.com/docs/loki/
