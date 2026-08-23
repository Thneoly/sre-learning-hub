# Lab 19 · 解答：资源压力诊断

## 核心概念

```
Capacity(kubelet 探测的物理量, 如 4 CPU / 8GiB)
  - 系统保留(kube-reserved/system-reserved/eviction-hard)
  = Allocatable(scheduler 的"货架容量", 如 4800m / 7820Mi)

scheduler 装箱规则(只看 requests, 不看真实占用):
  sum(已调度 Pod 的 requests) + 新 Pod requests <= Allocatable ?
```

所以"节点 free 还有 6 个 G"与"Pod 调度不进去"并不矛盾——scheduler 数的是**账面 requests**，不是实际内存。

## 第 1 步：还原现场

```bash
# [master]
kubectl create namespace cka-res
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: big-batch
  namespace: cka-res
spec:
  replicas: 1
  selector:
    matchLabels:
      app: big-batch
  template:
    metadata:
      labels:
        app: big-batch
    spec:
      containers:
      - name: worker
        image: busybox:1.36
        command: ["sleep", "3600"]
        resources:
          requests:
            cpu: "8"
            memory: "16Gi"
EOF
```

## 第 2 步：确认症状与事件证据

```bash
# [master]
kubectl -n cka-res get pods
```

预期：

```
NAME                         READY   STATUS    RESTARTS   AGE
big-batch-6b8d9f7c4-x7qkl    0/1     Pending   0          2m
```

取 FailedScheduling 证据：

```bash
# [master]
kubectl -n cka-res describe pod -l app=big-batch | tail -8
```

预期 Events：

```
Warning  FailedScheduling  2m   default-scheduler  0/1 nodes are available:
1 Insufficient cpu, 1 Insufficient memory. preemption: 0 PreemptionLowerPriority not needed...
```

这条 message 就是"为什么 Pending"的一手答案：所有节点上 **requests 累加后都放不下 8 CPU / 16Gi**。事件也可以用 `kubectl -n cka-res get events --field-selector reason=FailedScheduling` 单独捞。

## 第 3 步：读取 Allocatable

```bash
# [master]
kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}{"\n"}'
kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}{"\n"}'
```

预期输出（以 4C/8G 的 VM 为例）：

```
4000m
7820Mi
```

再交叉验证 describe 视图：

```bash
# [master]
kubectl describe node "$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')" | grep -A14 "Allocated resources"
```

预期段（关键在 `Allocated resources` 的 requests 列）：

```
Allocated resources:
  Resource           Requests      Limits
  cpu                650m (16%)    300m (8%)
  memory             290Mi (3%)    170Mi (2%)
```

## 第 4 步：写 answers 文件

```bash
# [master] 以下数值以你的集群实际输出为准
cat >/tmp/lab19-answers.txt <<'EOF'
ALLOCATABLE_CPU=4000m
ALLOCATABLE_MEM=7820Mi
PENDING_REASON=big-batch 的 requests(8 CPU/16Gi) 超过节点 Allocatable 余量, Insufficient cpu/memory 导致 FailedScheduling
EOF
```

## 第 5 步：解释"明明还有内存"

三个角色分工：

- **requests**：调度依据。scheduler 把它"预扣"在节点账上，不管容器实际用多少。
- **limits**：运行时上限。超过 CPU limit 被限流（throttle），超过 memory limit 触发 OOMKill。
- **Allocatable**：节点可承诺给 Pod 的总量 = Capacity - kubelet 保留。

本例：节点 Allocatable 总共 4000m/7820Mi，系统 Pod 已占约 650m/290Mi，剩余约 3350m/7530Mi。Pod 要 8 CPU/16Gi，**账面缺口巨大**，scheduler 拒绝是正确行为——若没有 requests 这道闸，这个 Pod 一启动就能把节点内存打爆，连累同节点的所有 Pod。修复方向有两个：改小 requests（本 lab 采用），或给集群加节点。

## 第 6 步：修复并验证

```bash
# [master]
kubectl -n cka-res set resources deployment/big-batch \
  --requests=cpu=100m,memory=128Mi
kubectl -n cka-res rollout status deployment/big-batch --timeout=120s
```

预期 `deployment "big-batch" successfully rolled out`。终态：

```bash
# [master]
kubectl -n cka-res get pods -l app=big-batch
# NAME                        READY   STATUS    RESTARTS   AGE
# big-batch-7d9c8b5f4-m2r8t   1/1     Running   0          40s
kubectl -n cka-res get deploy big-batch -o jsonpath='{.spec.template.spec.containers[0].resources.requests}{"\n"}'
# {"cpu":"100m","memory":"128Mi"}
```

## 常见错误回顾

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| Pending + Insufficient memory/cpu | requests 超过 Allocatable 余量 | 调小 requests 或加节点 |
| Pending + node(s) had untolerated taint | 污点没有 toleration | 给 Pod 加 tolerations 或去掉污点 |
| Pending + node(s) didn't match Pod anti-affinity | 亲和性规则冲突 | 检查 affinity/拓扑约束 |
| Running 但 CPU 高负载被限流 | limits 太低（throttling） | 区分"调度不足"与"限流"，看 metrics |
| Running 但被 OOMKilled | memory limit 太低 | 调大 limit 或查泄漏 |

## 延伸阅读

- https://kubernetes.io/docs/concepts/scheduling-eviction/resource-bin-packing/
- https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/

## check.sh 运行结果

```bash
# [master]
chmod 755 check.sh && ./check.sh
```

预期：

```
PASS: namespace cka-res 存在
PASS: Deployment big-batch 存在
PASS: requests 已改小(cpu=100m, memory=128Mi)
PASS: big-batch 的 Pod 为 Running
PASS: answers 文件 /tmp/lab19-answers.txt 存在
PASS: ALLOCATABLE_CPU=4000m 与实际(4000m)一致
PASS: PENDING_REASON 已填写(big-batch 的 requests(8 CPU/16Gi) 超过节点 Allocatable 余量...)

SCORE: 7/7
```
