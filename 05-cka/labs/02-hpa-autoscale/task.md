# Lab 02 · HPA 基于 CPU 的自动扩缩容

> 难度：★★☆ ｜ 考点：CKA-应用伸缩（HorizontalPodAutoscaler） ｜ 前置：lab 01 ｜ 预计 25~35 分钟

## 场景

你们的对外 API 网关 `api-front` 流量有明显潮汐：白天高峰、夜间空闲。团队决定用 HorizontalPodAutoscaler 代替人工 `kubectl scale`：

- 平时保持 2 个副本；
- CPU 平均使用率超过 50% 就扩容，最多 6 个副本，最少 2 个；
- 流量回落后能自动缩回（默认伸缩策略即可，不需要自定义 behavior）。

集群已由 scripts/setup 装好 metrics-server（HPA 的数据来源），可用 `kubectl top node` 验证。

## 任务清单

1. 创建 namespace `lab02-autoscale`。
2. 创建 Deployment `api-front`：
   - labels `app=api-front`，副本数 `2`
   - 容器名 `api-front`，镜像 `nginx:1.27`，containerPort `80`
   - 必须为容器声明资源请求：`requests.cpu: 100m`、`requests.memory: 128Mi`（HPA 百分比计算的分母就是 request）
3. 创建 Service `api-front`，port `80` → targetPort `80`，类型 ClusterIP，供压测 Pod 访问。
4. 创建 HPA `api-front`：
   - 作用目标为上述 Deployment
   - `minReplicas=2`、`maxReplicas=6`
   - CPU 目标（`averageUtilization`）为 `50`
5. （可选加分）发起压测观察副本从 2 扩到 4+，再停压观察回落。

## 验收标准

终态（`kubectl -n lab02-autoscale` 观察）：

- `describe hpa api-front`：Min replicas 2 / Max replicas 6 / CPU target 50%，且能看到当前 CPU 指标（非 `<unknown>`）
- `get hpa api-front` 的 TARGETS 列形如 `xx%/50%`
- Deployment 的容器带有 cpu request（没有 request 的容器无法被 HPA 计算）

运行判分脚本：

```bash
# [master]
cd 05-cka/labs/02-hpa-autoscale
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：为什么必须设置 resources.requests</summary>

HPA 的 `averageUtilization` 是"实际用量 ÷ 该容器 request"的百分比。没有 request 的容器拿不到分母，metrics-server 不会为它上报 utilization，HPA 会一直显示 `<unknown>/50%` 并拒绝伸缩。这是考试和实战中最常见的坑。
</details>

<details><summary>提示 2：一条命令建 HPA</summary>

```bash
# [master]
kubectl -n lab02-autoscale autoscale deployment api-front \
  --min=2 --max=6 --cpu-percent=50
```
或者用 YAML（考场两种都要会写），字段在 `autoscaling/v2` 的 `spec.metrics[0].resource.target`。
</details>

<details><summary>提示 3：压测怎么打</summary>

```bash
# [master]
kubectl -n lab02-autoscale run load-gen --image=curlimages/curl:8.8.0 --restart=Never -- \
  sh -c 'while true; do curl -s http://api-front/ >/dev/null; done'
```
观察：`kubectl -n lab02-autoscale get hpa -w`。结束后 `kubectl -n lab02-autoscale delete pod load-gen`。
</details>
