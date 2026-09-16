# Lab 02 · OTel Operator 自动插桩：零代码接入 Python 应用

> 难度：★★☆ ｜ 考点：OTel Operator 与 auto-instrumentation（PCA instrumentation 主题的 K8s 落地）｜ 前置：Lab 01（复用 namespace 习惯，非硬性）｜ 预计 45 分钟

## 前置条件与环境说明

- kubeadm 练习集群（单 master + Calico），节点可访问 `ghcr.io`、`quay.io` 拉镜像，Pod 内能访问 PyPI（应用容器启动时要 `pip install flask`）。
- 资源需求：约 2GB 空闲内存（cert-manager 3 Pod + operator 1 Pod + Jaeger/Collector/应用各 1 Pod）。
- 需要联网安装：cert-manager（`quay.io/jetstack/cert-manager-*`）与 OTel Operator（`ghcr.io/open-telemetry/opentelemetry-operator/*`）。版本以官方 release 页面为准，本 lab 使用 cert-manager v1.15.3、operator v0.109.0。
- **环境不具备时的替代验证方式**（无法装 operator，例如离线环境或没有 CRD 权限）：改用应用侧手动接入验证同一后端链路——在应用的启动命令前加 `opentelemetry-instrument`：

  ```bash
  # [装有Docker的Ubuntu VM]（应用镜像构建/启动时执行）
  pip install opentelemetry-distro opentelemetry-exporter-otlp flask==3.0.3
  opentelemetry-bootstrap -a install
  OTEL_EXPORTER_OTLP_ENDPOINT=http://<collector地址>:4318 \
  OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
  OTEL_SERVICE_NAME=my-app opentelemetry-instrument python app.py
  ```

  此时 check.sh 的第 1、2、6 项会 FAIL 属预期，人工核对 Jaeger 里有 trace 即算达成学习目标。

## 场景

团队里有一批存量 Python/Go/Java 服务，业务代码一行都不想动，但老板要求"全部服务上 tracing"。你决定上 OTel Operator 的 auto-instrumentation：装好 operator 后，只需要一个 `Instrumentation` CR 描述"SDK 从哪来、数据发到哪"，再给 Deployment 的 pod template 加一条注解，operator 就会在**每次创建 Pod 时**注入 init 容器（把 SDK 拷进共享 volume）和一整套 `OTEL_*` 环境变量。后端先用 Jaeger all-in-one 接 OTLP。

```
                     +------------------- pod template 加注解 -------------------+
                     |  instrumentation.opentelemetry.io/inject-python: "true"   |
                     +----------------------------------------------------------+
                                        |
                     OTel Operator (mutating webhook 拦截 Pod CREATE)
                                        v
   +--------------------------- python-demo Pod ---------------------------+
   | init: opentelemetry-auto-instrumentation-python  (拷贝 SDK 到 emptyDir) |
   | main: 应用容器 + PYTHONPATH/OTEL_EXPORTER_OTLP_* 等 env 注入           |
   +--------------------------- OTLP http/protobuf 4318 -------------------+
                                        v
                     Collector --(otlp gRPC exporter)--> Jaeger all-in-one UI
```

## 任务清单

1. 安装 cert-manager（operator 的 webhook 证书前置依赖），等待其 3 个 Deployment Ready。
2. 安装 OTel Operator v0.109.0，等待 `opentelemetry-operator-system` 里的 controller Pod Running。
3. 在 namespace `otel-lab` 部署 Jaeger all-in-one（`COLLECTOR_OTLP_ENABLED=true`，UI 16686，OTLP 4317/4318）和最小 Collector（OTLP receiver → `debug` + `otlp/jaeger` exporter，只建 traces pipeline）。
4. 创建 `Instrumentation` CR：propagators 含 `tracecontext`/`baggage`/`b3`，sampler 全采样；注意官方文档的要求——Python 自动插桩默认用 `http/protobuf` 协议，exporter endpoint 要指向 **4318** 端口。
5. 部署示例 Python 应用（ConfigMap 提供一个最小 Flask 应用，`python:3.12-slim` 镜像启动时安装依赖），**只在 pod template 加注解** `instrumentation.opentelemetry.io/inject-python: "true"`，并显式设置 `OTEL_SERVICE_NAME=python-demo`，服务名即为 `python-demo`。
6. 用一个 curl Job 给应用打流量，验证：
   - 应用 **Pod**（注意不是 Deployment 对象）出现 init 容器 `opentelemetry-auto-instrumentation-python`；
   - 应用容器被注入 `OTEL_EXPORTER_OTLP_ENDPOINT`、`PYTHONPATH` 等环境变量；
   - Jaeger UI（port-forward 16686）里能看到 service `python-demo` 的 trace。

## 验收标准

- `kubectl -n cert-manager get deploy` 三个 Deployment 均 Ready；
- `kubectl -n opentelemetry-operator-system get pods` 中 operator controller Running；
- `kubectl -n otel-lab get instrumentation python-instr -o name` 返回非空；
- 运行中的 python-demo Pod（`kubectl -n otel-lab get pod -l app=python-demo -o jsonpath='{.items[0].spec.initContainers[*].name}'`）含 `opentelemetry-auto-instrumentation-python`；
- Jaeger UI 能查到 `python-demo` 的 trace；
- 运行 `./check.sh` 输出 `SCORE: 6/6`。

## 提示（卡住再看）

<details><summary>提示 1：注解加在哪一层？</summary>

加在 Deployment 的 `spec.template.metadata.annotations`（Pod 模板），不是 Deployment 顶层 metadata。operator 的 mutating webhook 拦截的是**即将创建的 Pod**。
</details>

<details><summary>提示 2：Instrumentation 的 exporter endpoint 怎么写？</summary>

官方 auto-instrumentation 文档明确：Python 插桩默认走 `http/protobuf`，数据必须发到 4318 而不是 4317。在 CR 的 `python.env` 里写：

```yaml
spec:
  exporter:
    endpoint: http://otel-collector.otel-lab.svc:4317
  python:
    env:
      - name: OTEL_EXPORTER_OTLP_ENDPOINT
        value: http://otel-collector.otel-lab.svc:4318
```

operator 也会自动给容器注入 `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`。
</details>

<details><summary>提示 3：怎么确认注入生效？看 Pod，不是 Deployment</summary>

webhook 只在 Pod CREATE 时注入（MutatingWebhookConfiguration 的 rules 是 `pods` 的 `CREATE`），Deployment 对象本身不会被改写，所以要看**运行中的 Pod**：

```bash
# [master]
POD=$(kubectl -n otel-lab get pod -l app=python-demo -o jsonpath='{.items[0].metadata.name}')
kubectl -n otel-lab get pod "$POD" -o jsonpath='{.spec.initContainers[*].name}'; echo
kubectl -n otel-lab get pod "$POD" -o jsonpath='{.spec.containers[0].env[*].name}'; echo
```

第一条输出里应出现 `opentelemetry-auto-instrumentation-python`，第二条里应出现 `OTEL_EXPORTER_OTLP_ENDPOINT`、`PYTHONPATH`。
</details>

<details><summary>提示 4：应用容器里怎么跑 Flask？</summary>

`python:3.12-slim` 镜像本身没有 Flask，用 ConfigMap 放 `app.py` 挂进容器，启动命令里先装依赖再运行：`pip install --no-cache-dir flask==3.0.3 && python /app/app.py`。SDK 在解释器启动时通过 `PYTHONPATH` 里的 sitecustomize 自动挂钩，运行时才装上的 Flask 一样会被插桩。
</details>
