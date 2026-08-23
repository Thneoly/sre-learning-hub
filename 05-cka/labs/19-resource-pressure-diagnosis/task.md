# Lab 19 · 资源压力诊断：Pending 的 Pod
> 难度：★★ ｜ 考点：CKA-排错（调度资源不足 / requests 与 allocatable） ｜ 前置：无 ｜ 预计 30 分钟
> 运行位置：kubectl 操作全部在 [master]

## 场景

团队申请上线一个"批处理"应用，apply 之后 Pod 永远 Pending。上线的人说："节点明明还有内存，为什么调度不进去？"你需要给出**数据支撑的结论**：用 `kubectl describe node` 与 `kubectl get events` 计算出节点的 Allocatable 余量，解释 Pending 的真实原因，然后按业务能接受的最小资源（CPU 100m / 内存 128Mi）改小 requests 完成上线。

## 任务清单

1. 还原现场：创建 namespace `cka-res` 并 apply 下面的 Deployment：

```yaml
# [master] 已应用到集群(现场还原命令见 solution)
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
```

2. 确认 Pod 状态为 `Pending`，用 `kubectl describe pod` 找到 `FailedScheduling` 事件，抄下事件的完整 message（它写明了为什么调不进去）。
3. 用两条命令分别获取节点的 CPU/内存 **Allocatable**：

```bash
# [master]
kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}{"\n"}'
kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}{"\n"}'
```

4. 把结果写入 `/tmp/lab19-answers.txt`，格式（值原样照抄 jsonpath 输出）：
   ```
   ALLOCATABLE_CPU=<第一行输出, 如 4000m 或 4>
   ALLOCATABLE_MEM=<第二行输出, 如 7820Mi>
   PENDING_REASON=<FailedScheduling message 里的一句中文归纳>
   ```
5. 用 `kubectl describe node <node>` 的 `Allocated resources` 段回答：requests 8 CPU / 16Gi 的 Pod 为什么放不进这台节点（哪怕"真实内存没占满"）？
6. 修复：把 `big-batch` 的 requests 改为 `cpu: 100m` / `memory: 128Mi`（`kubectl edit` 或 patch），等待 Pod `Running`。

## 验收标准

- `cka-res` 内 big-batch 的 Pod `Running`，requests 为 `100m/128Mi`。
- `/tmp/lab19-answers.txt` 三行齐全，`ALLOCATABLE_CPU` 的数值与集群实际一致。
- 你能说清 requests/limits/allocatable 三者的关系（solution 复述）。

## 提示（卡住再看）

<details><summary>提示 1：FailedScheduling 事件怎么看</summary>

```bash
# [master]
kubectl -n cka-res describe pod -l app=big-batch | tail -10
```

Events 里形如：

```
Warning  FailedScheduling  ...  0/1 nodes are available:
1 Insufficient cpu, 1 Insufficient memory. preemption: 0 PreemptionLowerPriority...
```

"Insufficient memory" 指的是 **requests 总量超过 Allocatable 余量**，不是物理内存用光。

</details>

<details><summary>提示 2：改 requests 的最小操作</summary>

```bash
# [master]
kubectl -n cka-res set resources deployment/big-batch \
  --requests=cpu=100m,memory=128Mi
```

改 requests 会触发滚动更新，等 `rollout status` 完成即可。

</details>

<details><summary>提示 3：Allocatable 是怎么来的</summary>

`Allocatable = Capacity - 系统保留(eviction thresholds 等 kubelet 配置)`。scheduler 只按 **requests 之和 <= Allocatable** 来做装箱决策，不看节点真实使用率——这是 Burstable/BestEffort Pod 能"超卖"的前提，也是本题"明明还有内存却调不进"的答案。

</details>
