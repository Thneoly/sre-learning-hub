# Lab 08 · PriorityClass 与调度抢占

> 难度：★★★ ｜ 考点：CKA-调度（PriorityClass / preemption） ｜ 前置：lab 01 ｜ 预计 30~45 分钟

## 场景

单节点练习集群资源有限（以节点 allocatable CPU 为准）。运维组要演练一次"紧急业务抢占批量任务"：

1. 先建两个 PriorityClass：`batch-low`（value 100，用于离线批量任务）和 `critical-high`（value 1000000，用于核心交易业务）；
2. 用低优先级的 Deployment `filler-low`（busybox `sleep infinity`，每个副本 `requests.cpu: 1000m`、`requests.memory: 32Mi`）把节点 CPU 的**request 配额吃满**——副本数取节点 allocatable CPU 核数（例如 4 核就 4 个副本）。busybox 睡眠时实际 CPU 接近 0，所以集群是安全的，只有"调度账本"被占满；
3. 此时创建高优先级 Pod `payment-gateway`（priorityClassName `critical-high`，requests.cpu 1000m，nginx:1.27）。它会发现节点放不下自己，进而**抢占**：调度器驱逐一个 `filler-low` 副本，把位置让给 `payment-gateway`；
4. 终态：`payment-gateway` Running；`filler-low` 至少 1 个副本 Pending（节点已无余量），Deployment 的 READY 数小于期望副本数。

这个实验完整演示"资源不足时，优先级决定谁活下来"。

## 任务清单

1. 创建 namespace `lab08-preempt`。
2. 创建 PriorityClass `batch-low`（value 100，description `low priority batch jobs`）和 `critical-high`（value 1000000，`globalDefault: false`，description `critical payment service`）。
3. 查询节点 allocatable CPU：`kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}'`（单节点集群即 master；练习集群 master 已去掉 NoSchedule 污点，可调度）。
4. 创建 Deployment `filler-low`：labels `app=filler-low`，副本数 = allocatable CPU 核数（数字去掉单位，如 `4` 就写 4），priorityClassName `batch-low`，容器 `filler`（busybox:1.36，command `sh -c 'sleep infinity'`），requests cpu `1000m` / memory `32Mi`。
5. 确认 filler 部分副本 Pending（节点装不下全部），无需处理——这正是"资源已被占满"的证据。
6. 创建单 Pod `payment-gateway`（priorityClassName `critical-high`，容器 `pay` 镜像 nginx:1.27，requests cpu `1000m` / memory `64Mi`），观察它驱逐 filler 后 Running。
7. 观察证据链：`kubectl -n lab08-preempt get events --sort-by=.lastTimestamp | tail -20` 里应能看到 `Preempted` 事件（reason 为 `Preempted`，message 提到 `payment-gateway`）。

## 验收标准

- `kubectl get priorityclass batch-low critical-high`：GLOBAL DEFAULT 均为 false，两个 value 分别是 100 / 1000000
- `kubectl -n lab08-preempt get pod payment-gateway`：Running，且 `spec.priorityClassName` 为 `critical-high`
- `kubectl -n lab08-preempt get deploy filler-low`：READY 小于期望副本数（至少 1 个副本起不来）
- events 中出现 Preempted 事件（判分不强制，用于自查）

运行判分脚本：

```bash
# [master]
cd 05-cka/labs/08-priority-preempt
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：抢占的触发条件</summary>

高优先级 Pod 首先正常调度；只有当**所有节点都放不下**（requests 超余量）时才进入抢占流程：调度器挑选"牺牲者"（牺牲者优先级必须低于自己），删除它们释放出足够 requests。被删的低优先级 Deployment 副本随后想重建，但节点还是满的，于是 Pending。所以整个演示的前提是 filler 的 requests 真的占满了 allocatable CPU。
</details>

<details><summary>提示 2：为什么用 requests 占位而不是压测</summary>

调度只看 requests（账面），不看实际使用率。busybox `sleep infinity` 的真实 CPU 几乎为 0，节点不会卡死，但调度账本已经满了——这是做调度实验最安全的方式。千万别用 stress 镜像把节点 CPU 真吃满。
</details>

<details><summary>提示 3：PriorityClass YAML 骨架</summary>

`apiVersion: scheduling.k8s.io/v1`、`kind: PriorityClass`、`spec.value`（32 位整数，越大越优先）、可选 `globalDefault`（全集群只能有一个为 true）、`description`。Pod 里通过 `spec.priorityClassName` 引用，Pod 的 `spec.priority` 由系统自动注入。
</details>
