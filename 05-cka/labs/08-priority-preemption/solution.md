# Lab 08 · 解答：PriorityClass 与调度抢占

## 步骤 1：namespace 与两个 PriorityClass

```bash
# [master]
kubectl create namespace lab08-preempt
```

```yaml
# [master] cat > priorityclasses.yaml <<'EOF'
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: batch-low
value: 100
description: low priority batch jobs
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: critical-high
value: 1000000
globalDefault: false
description: critical payment service
EOF
kubectl apply -f priorityclasses.yaml
kubectl get priorityclass batch-low critical-high
```

```text
NAME             VALUE        GLOBAL-DEFAULT   AGE
batch-low        100          false            5s
critical-high    1000000      false            5s
```

为什么 value 差要拉大：抢占只对"优先级比自己低的 Pod"动手，差距大是为了确保任何 filler 都可能成为牺牲者；1 million 这个量级是集群内置 system-cluster-critical 的惯用取值范围，便于对照记忆。

## 步骤 2：测量节点并占满 CPU 账面

```bash
# [master]
kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}{"\n"}'
# 假设输出 4
```

按 4 核创建 4 个副本（每个 request 1000m，requests 总量 4000m ≥ allocatable——再加上系统组件已占的份额，节点一定装不下全部副本）：

```yaml
# [master] cat > filler-low.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: filler-low
  namespace: lab08-preempt
  labels:
    app: filler-low
spec:
  replicas: 4          # <- 改成你节点的 allocatable CPU 核数
  selector:
    matchLabels:
      app: filler-low
  template:
    metadata:
      labels:
        app: filler-low
    spec:
      priorityClassName: batch-low
      containers:
      - name: filler
        image: busybox:1.36
        command: ["sh", "-c", "sleep infinity"]
        resources:
          requests:
            cpu: 1000m
            memory: 32Mi
EOF
kubectl apply -f filler-low.yaml
```

等 30 秒左右观察：部分副本 Running、至少一个 Pending：

```text
# [master]
$ kubectl -n lab08-preempt get pods
NAME                          READY   STATUS    RESTARTS   AGE
filler-low-5d97c8b7d-7xz92    0/1     Pending   0          25s
filler-low-5d97c8b7d-f4kq1    1/1     Running   0          25s
filler-low-5d97c8b7d-mzv38    1/1     Running   0          25s
filler-low-5d97c8b7d-q9tp2    1/1     Running   0          25s
```

看节点账面（Allocated resources 一栏，CPU Requests 应接近 100%）：

```bash
# [master]
kubectl describe node "$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')" | grep -A 6 "Allocated resources"
```

此时节点实际 CPU 几乎空闲（busybox 在睡觉），满的只是调度账本——这就是 requests 占位法安全的原因。

## 步骤 3：投放高优先级 Pod，触发抢占

```yaml
# [master] cat > payment-gateway.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: payment-gateway
  namespace: lab08-preempt
  labels:
    app: payment-gateway
spec:
  priorityClassName: critical-high
  containers:
  - name: pay
    image: nginx:1.27
    resources:
      requests:
        cpu: 1000m
        memory: 64Mi
EOF
kubectl apply -f payment-gateway.yaml
```

发生了什么（时间线）：

```text
1. scheduler 给 payment-gateway 找位子 -> 唯一节点 CPU requests 已满 -> Unschedulable
2. preemption 逻辑启动：候选牺牲者 = 节点上优先级 < 1000000 的 Pod
3. 挑出 1 个 filler-low 副本（释放 1000m 即够），发 Preempted 事件并删除
4. payment-gateway 通过第二次调度 -> Running
5. filler-low 的 ReplicaSet 想补副本 -> 节点依旧满 -> 新副本 Pending
```

验证：

```bash
# [master]
kubectl -n lab08-preempt get pod payment-gateway   # Running
kubectl -n lab08-preempt get deploy filler-low     # READY 3/4（4核示例）
kubectl -n lab08-preempt get events --sort-by=.lastTimestamp | tail -8
```

```text
...  Normal   Preempted           ...  payment-gateway preempted filler-low-5d97c8b7d-f4kq1
...  Normal   Scheduled           ...  Successfully assigned lab08-preempt/payment-gateway to master
...  Normal   Pulling             ...  Pulling image "nginx:1.27"
```

`Preempted` 事件的 message 会写明"谁抢了谁"，这是考场上最硬的证据。

`spec.priority` 已被系统注入（引用 PriorityClass 的 value）：

```bash
# [master]
kubectl -n lab08-preempt get pod payment-gateway \
  -o jsonpath='{.spec.priority}{"\n"}'
# 1000000
```

## 步骤 4：反向验证优先级语义（可选）

删除 payment-gateway，filler 会立刻补满；这验证"抢占只在资源不足时发生，平时高低优先级和平共处"：

```bash
# [master]
kubectl -n lab08-preempt delete pod payment-gateway
sleep 10
kubectl -n lab08-preempt get deploy filler-low   # READY 恢复 4/4（4核示例）
```

做完想复演就把 payment-gateway.yaml 再 `apply` 一次。

## 步骤 5：运行判分脚本

```bash
# [master]
cd 05-cka/labs/08-priority-preempt
chmod +x check.sh
./check.sh
```

通过结果（以 4 核节点为例）：

```text
PASS: namespace lab08-preempt 存在且 Active
PASS: priorityclass batch-low 存在
PASS: batch-low value 为 100
PASS: priorityclass critical-high 存在
PASS: critical-high value 为 1000000
PASS: filler-low priorityClassName 为 batch-low
PASS: filler-low 每副本 requests.cpu 为 1000m
PASS: filler-low 期望副本数 >= 2（实际 4）
PASS: pod payment-gateway 为 Running（含抢占等待）
PASS: payment-gateway priorityClassName 为 critical-high
PASS: payment-gateway requests.cpu 为 1000m
PASS: payment-gateway 的 spec.priority(1000000) 高于 filler 的优先级
PASS: filler-low readyReplicas(3) < 期望副本数(4)，低优先级被挤掉
PASS: 存在 Pending 的 filler-low Pod（节点 CPU 账面已满）

SCORE: 14/14
```

## 常见坑速查

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 高优先级 Pod 一直 Pending，没有抢占 | filler 没占满 allocatable（副本太少） | 提高副本数到节点核数；确认 requests 写的是 cpu 不是只写 limits |
| filler 全部 Running、没有 Pending | 节点核数大于你写的副本数 | `kubectl get nodes -o jsonpath=...cpu` 重新测，副本数 = 核数 |
| 抢占发生但删的是系统 Pod | 高优先级 Pod request 太大，牺牲者集合扩大 | 练习环境 request 控制在 1 核内 |
| Pod 事件里只有 FailedScheduling 无 Preempted | 候选牺牲者优先级更高（如 system pods） | 检查 PriorityClass value 是否足够大 |

## 考点回顾

- 调度只认 requests；`kubectl describe node` 的 Allocated resources 是"账面"，`kubectl top node` 是"实际"，两者排障时别混。
- 抢占两步走：挑牺牲者（优先级低、释放量够、且尽量少删）→ 删除后重新调度；被删的 Deployment 副本会自动重建，但可能继续 Pending。
- PriorityClass 的 `globalDefault` 全集群至多一个 true；未引用任何 class 的 Pod priority 为 0。PodDisruptionBudget 可以给抢占设置保护伞（结合 lab 14 drain 理解）。
