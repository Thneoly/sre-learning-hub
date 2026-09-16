# Lab 01 · 最小 Collector 管道：OTLP 进、文件出

> 难度：★☆☆ ｜ 考点：OTel Collector 基础（PCA 可观测性概念的动手延伸）｜ 前置：无 ｜ 预计 30 分钟

## 前置条件与环境说明

- 一套可用的 kubeadm 练习集群（单 master + Calico 即可），节点能访问 `ghcr.io` 拉取镜像。
- 资源需求很小：1 个 Collector Pod，约 512Mi 内存即可。
- 用到的镜像：
  - `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib`（含 file exporter，核心版没有）
  - `ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen`（官方数据生成器）
- **环境不具备时的替代验证方式**：没有集群但有 Docker 的 Ubuntu VM，可用同一份 Collector 配置文件直接 `docker run` 起 Collector、用 `docker run` 跑 telemetrygen，验证方式见 solution.md 末尾"替代验证方式（Docker 单机）"一节。

## 场景

团队决定所有服务先把 trace/metric 统一送到一个 OpenTelemetry Collector，再决定最终后端（Jaeger？Prometheus REMOTE_WRITE？先不关心）。领导要你先搭一条最小管道证明链路通：

```
telemetrygen ──OTLP(gRPC 4317)──> Collector ──> debug exporter（日志可见）
                                              └─> file exporter（/var/lib/otelcol/telemetry.json）
```

你现在只有一台单 master 的 kubeadm 集群，要求：Collector 以 Deployment 跑在集群里，配置放在 ConfigMap 里，数据落地文件挂 emptyDir，同时日志里能看到数据流过，最后能用官方 telemetrygen 工具分别发 trace 和 metric 验证到达。

## 任务清单

1. 创建 namespace `otel-lab`。
2. 编写 Collector 配置（ConfigMap `otel-collector-config`）：OTLP receiver（gRPC 4317 + HTTP 4318）、`batch` processor、`debug` exporter（verbosity: detailed）、`file` exporter（输出到 `/var/lib/otelcol/telemetry.json`），traces 与 metrics 两条 pipeline。
3. 以 Deployment（1 副本，contrib 镜像）+ Service（暴露 4317/4318）运行 Collector，配置与数据目录分别挂 ConfigMap 和 emptyDir。
4. 用 telemetrygen 跑一个 Job 向 Collector 发 3 条 trace；再用 `kubectl run` 临时 Pod 发 10 个 metric。
5. 验证：
   - `kubectl get pods -n otel-lab` 中 Collector 处于 `Running`；
   - `kubectl logs` 能看到 debug exporter 打出的 span/metric（含 `service.name=telemetrygen`）；
   - `kubectl exec` 读出 `/var/lib/otelcol/telemetry.json`，内容里能 grep 到 `telemetrygen`。

## 验收标准

- Deployment `otel-collector` Ready 副本数 >= 1；
- Service `otel-collector` 暴露 4317 端口；
- Job `telemetrygen` 状态为 Complete（succeeded=1）；
- Collector 容器内 `/var/lib/otelcol/telemetry.json` 存在且包含 telemetrygen 产生的数据；
- 运行 `./check.sh` 输出 `SCORE: 6/6`。

## 提示（卡住再看）

<details><summary>提示 1：ConfigMap 里放 YAML 配置用什么方式？</summary>

用块标量 `|` 整段写入，Collector 启动参数 `--config=/conf/config.yaml` 指过去，ConfigMap 挂载到 `/conf`：

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  namespace: otel-lab
data:
  config.yaml: |
    receivers:
      otlp:
        ...
```
</details>

<details><summary>提示 2：file exporter 是 contrib 独有，镜像别选错</summary>

核心版镜像 `opentelemetry-collector`（不带 `-contrib` 后缀）没有 file exporter，启动会报 `unknown exporter type "file"`。用 `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib`。
</details>

<details><summary>提示 3：telemetrygen 怎么发数据？</summary>

telemetrygen 第一个参数是信号类型，`--otlp-insecure` 关 TLS，endpoint 用集群内 Service DNS：

```bash
# [master]
kubectl -n otel-lab run tg-traces --rm -i --restart=Never \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  -- traces --otlp-insecure --otlp-endpoint=otel-collector.otel-lab.svc:4317 --traces=3
```
</details>
