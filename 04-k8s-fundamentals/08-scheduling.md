# 08 · 调度器：过滤、打分、亲和、污点与抢占

> 模块：04-k8s-fundamentals ｜ 建议时长：3 小时 ｜ 关联认证：CKA-调度 / CKS-（无直接考点）

## 学习目标

- 能解释 kube-scheduler 的 Filter → Score 两阶段框架，说清"Filter 看 requests、不看 limits 与实时用量"
- 能操作 nodeSelector、nodeAffinity、pod affinity/anti-affinity、topologySpreadConstraints 四类约束控制 Pod 落点
- 能操作 taint/toleration 的三种 effect，并分别预测"已运行 Pod"和"新建 Pod"的遭遇
- 能解释 PriorityClass 的抢占流程与受害者选择规则
- 能排查 Pod Pending：从 FailedScheduling 事件链区分"调度失败"与"被驱逐"

## 1. 调度器在架构里的位置：一次性决策

kube-scheduler 是控制面里的一个普通控制器：watch 所有 `spec.nodeName` 为空的 Pod，为它选一个节点，然后把节点名写回去（Bind）。写回之后，这个 Pod 就归该节点的 kubelet 管，调度器不再碰它。

```
# [图] 一次调度的完整旅程
kube-apiserver (Pod, spec.nodeName="") ──watch──► kube-scheduler
   1. Filter：把不可能的节点剔除 → FeasibleNodes
   2. Score ：对 FeasibleNodes 打分排序
   3. Reserve/PreBind/Bind → 写回 Pod.spec.nodeName = "worker1"（唯一的"输出"）
                          └──watch──► 目标节点 kubelet → CRI 拉容器 → CNI 配网络
```

三个贯穿全章的关键认知：

| 认知 | 含义 |
| --- | --- |
| 决策是一次性的 | 所有约束都叫 `...IgnoredDuringExecution`：节点标签后来变了，已运行的 Pod 不会被迁移 |
| 决策基于快照 | 用的是"决策那一刻"的节点列表、已承诺 requests、已有 Pod 拓扑 |
| 资源只看 requests | Filter 比较的是 Pod 的 `resources.requests` 与节点 `Allocatable`，limits 和实时用量不参与（详见第 11 章） |

## 2. 两阶段框架：Filter → Score

### 2.1 Filter（预选）：不合格的节点直接出局

Filter 是硬性淘汰：任何一个条件不满足，该节点就被剔除。全部节点都被剔除时 Pod 保持 Pending，事件 reason 为 `FailedScheduling`。

| Filter 插件 | 剔除哪些节点 |
| --- | --- |
| NodeName / NodeUnschedulable | `spec.nodeName` 指定了别的节点；节点被 `kubectl cordon` |
| NodeResourcesFit | `Allocatable - 已承诺 requests` 放不下本 Pod 的 requests |
| NodePorts | `hostPort` 与已运行 Pod 冲突 |
| NodeAffinity | 节点标签不满足 required nodeAffinity |
| TaintToleration | 节点上有本 Pod 不容忍的 NoSchedule/NoExecute 污点 |
| InterPodAffinity | 违反 pod affinity / anti-affinity 的 required 规则 |
| VolumeZone / VolumeBinding / VolumeLimits | PV 的 zone 不符；WFFC 的 PVC 未绑定；节点卷数超上限 |
| NodeDiskPressure / NodeMemoryPressure / NodePIDPressure | 节点处于对应资源压力状态 |

### 2.2 Score（优选）：给活下来的节点打分

Score 是软性排序：每个插件给节点打 0~100 分，乘权重后求和，总分最高的节点胜出（平分随机）。

| Score 插件 | 打分逻辑 | 默认权重 |
| --- | --- | --- |
| NodeResourcesFit（LeastAllocated 策略） | 节点剩余资源比例越高分越高，倾向"铺开" | 1 |
| NodeResourcesBalancedAllocation | CPU 与内存占用率越接近分越高（避免只耗尽一种） | 1 |
| ImageLocality | 节点上已缓存本 Pod 需要的镜像层越多分越高 | 1 |
| InterPodAffinity | 满足 preferred pod affinity/anti-affinity 的程度 | 2 |
| NodeAffinity | 满足 preferred node affinity 的程度 | 2 |
| TaintToleration | 节点上 PreferNoSchedule 污点越多分越低 | 3 |

权重与打分策略可通过 `KubeSchedulerConfiguration` 调整（默认值以官方文档为准）。高频考点：**Filter 决定"能不能"，Score 决定"好不好"**；前者答错直接 Pending，后者答错只是落点不理想。

## 3. 让 Pod 挑节点：四类约束从粗到细

### 3.1 nodeSelector：等值匹配

```yaml
# [master] 保存为 node-selector.yaml
apiVersion: v1
kind: Pod
metadata:
  name: on-ssd
spec:
  nodeSelector:
    disktype: ssd        # 节点必须带有这个 label，且值完全相等
  containers:
  - name: main
    image: nginx:1.27
```

```bash
# [master] 先打标签再创建，观察落点
kubectl label node worker1 disktype=ssd && kubectl apply -f node-selector.yaml
kubectl get pod on-ssd -o wide
```

nodeSelector 只支持"多个键值全部相等"（AND），没有或、没有软规则。表达力不足时升级到 nodeAffinity。

### 3.2 nodeAffinity：带运算符与软规则

```yaml
# [master] 保存为 node-affinity.yaml
apiVersion: v1
kind: Pod
metadata:
  name: affinity-demo
spec:
  affinity:
    nodeAffinity:
      # 硬规则：必须满足，否则 Pending
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
        - matchExpressions:
          - key: disktype
            operator: In
            values: ["ssd", "nvme"]
      # 软规则：满足加分，不满足也调度
      preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 80
        preference:
          matchExpressions:
          - key: node-type
            operator: In
            values: ["compute"]
  containers:
  - name: main
    image: nginx:1.27
```

| operator | 语义 |
| --- | --- |
| In / NotIn | 标签值在/不在给定集合 |
| Exists / DoesNotExist | 该 key 存在/不存在 |
| Gt / Lt | 标签值（整数）大于/小于给定值（仅 nodeAffinity 可用，value 必须是单个整数） |

组合语义（官方文档原文口径）：`nodeSelectorTerms` 之间是**或**（满足任意一个 term 即可），单个 term 内的多个 `matchExpressions` 之间是**与**。若同时写了 `nodeSelector` 和 nodeAffinity，两者都要满足。

### 3.3 podAffinity / podAntiAffinity：以其他 Pod 的位置为条件

与 nodeAffinity 的本质区别：条件不是节点自身的标签，而是"同一拓扑域里已经跑着哪些 Pod"。`topologyKey` 定义拓扑域（常用 `kubernetes.io/hostname` 表示"一个节点"、`topology.kubernetes.io/zone` 表示"一个可用区"）。

```yaml
# [master] 保存为 anti-affinity.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      affinity:
        podAntiAffinity:
          # 每个节点最多一个 app=web 副本（硬规则）
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                app: web
            topologyKey: kubernetes.io/hostname
      containers:
      - name: main
        image: nginx:1.27
```

replicas 超过可调度节点数时，多出来的副本会永远 Pending——这是反亲和最经典的翻车方式。软化写法是把 `required...` 换成带 `weight`（1~100）的 `preferred...`。两个官方限制要记住：required 反亲和的 `topologyKey` 默认只允许 `kubernetes.io/hostname`（由 LimitPodHardAntiAffinityTopology 准入控制约束）；数百节点以上的大集群不建议用 pod affinity，计算开销大。

### 3.4 topologySpreadConstraints：控制分布倾斜度

反亲和回答"能不能同域"，分布约束回答"各域差几个"：

```yaml
# [master] Deployment spec.template.spec 片段
      topologySpreadConstraints:
      - maxSkew: 1                 # 任意两个域内副本数之差不得超过 1
        topologyKey: kubernetes.io/hostname
        whenUnsatisfiable: DoNotSchedule   # 不满足时硬拒绝；ScheduleAnyway 则只降分
        labelSelector:
          matchLabels:
            app: web
```

| 手段 | 匹配对象 | 硬/软 | 典型场景 |
| --- | --- | --- | --- |
| nodeSelector | 节点标签 | 只能硬 | 一次性粗分（该上 GPU 节点） |
| nodeAffinity | 节点标签 | 硬 + 软 | 精确圈定节点池 |
| podAffinity/AntiAffinity | 同域内其他 Pod 标签 | 硬 + 软 | 共置（web 贴 cache）/互斥（主从打散） |
| topologySpreadConstraints | 各域内同标签 Pod 计数 | 硬 + 软（maxSkew 量化） | 副本跨节点/跨 zone 均摊 |

## 4. 让节点挑 Pod：taint 与 toleration

前三节是"Pod 挑节点"；污点(taint)反过来"节点拒 Pod"：节点被打上污点后，不"容忍"该污点的 Pod 无法调度进来（NoExecute 还会赶走已运行的）。

| effect | 对新建 Pod | 对已运行且不容忍的 Pod |
| --- | --- | --- |
| NoSchedule | 不调度进来 | 不驱逐，继续跑 |
| PreferNoSchedule | 尽量不调度进来（软，参与 Score 降分） | 不驱逐 |
| NoExecute | 不调度进来 | **立即驱逐**（配合 tolerationSeconds 可延迟） |

```bash
# [master] 污点的增删查
kubectl taint node worker1 tier=edge:NoSchedule          # 加污点
kubectl describe node worker1 | grep -i taint            # 查看
kubectl taint node worker1 tier=edge:NoSchedule-         # 删除（key+effect 后加减号）
```

toleration 的两种写法：

```yaml
# [master] Pod spec 片段
  tolerations:
  - key: "tier"                       # Equal 写法：key+value 精确匹配
    operator: "Equal"
    value: "edge"
    effect: "NoSchedule"
  - key: "node.kubernetes.io/not-ready"   # Exists 写法：只要污点存在即可容忍
    operator: "Exists"
    effect: "NoExecute"
    tolerationSeconds: 30             # 仅 NoExecute 有意义：失联后先撑 30 秒再走
```

节点异常时由 node controller / kubelet 自动打的内置污点（排障天天见）：

| taint key | 触发条件 | 默认 effect |
| --- | --- | --- |
| node.kubernetes.io/not-ready | 节点 NotReady | NoExecute |
| node.kubernetes.io/unreachable | 节点失联（node lease 超时） | NoExecute |
| node.kubernetes.io/memory-pressure / disk-pressure / pid-pressure | 对应资源压力 | NoSchedule |
| node.kubernetes.io/unschedulable | 被 cordon/drain | NoSchedule |
| node-role.kubernetes.io/control-plane | kubeadm 控制面节点默认污点 | NoSchedule |

另有 `node.kubernetes.io/network-unavailable`（CNI 未就绪时，host network 节点相关）。普通 Pod"看起来能容忍" not-ready/unreachable，是因为 apiserver 的 DefaultTolerationSeconds 准入控制器默认给每个 Pod 注入了这两个污点各 300 秒的容忍——这解释了"节点挂了，Pod 先在原节点停留约 5 分钟再被驱逐"的现象。

## 5. PriorityClass 与抢占

### 5.1 优先级从哪来

```yaml
# [master] 保存为 priorityclasses.yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: urgent
value: 100000                    # 用户自定义上限 1000000000
globalDefault: false
description: "线上紧急任务，允许抢占"
preemptionPolicy: PreemptLowerPriority   # 默认值；设为 Never 则只插队不抢
```

```bash
# [master] 低优先级类用一行命令建即可
kubectl apply -f priorityclasses.yaml
kubectl create priorityclass batch-low --value=100 --description="离线批任务，可被抢占"
```

```bash
# [master] 系统内置的两个高优先级（值超过用户上限，供系统组件用）
kubectl get priorityclass
# NAME                      VALUE        GLOBAL-DEFAULT
# system-cluster-critical   2000000000   false    ← coredns 等
# system-node-critical      2000001000   false    ← calico/kube-proxy 等（同上省略）
```

未引用 PriorityClass 的 Pod 优先级为 0。优先级有两个独立作用：决定调度队列顺序；决定谁能抢谁。注意 priorityClassName 只是引用，同名的 PriorityClass 必须先创建，否则 apiserver 直接拒绝该 Pod。

### 5.2 抢占流程与受害者选择

高优先级 Pod 放不下时（Pending），scheduler 会尝试"腾地方"：

```
# [图] 抢占流程
urgent Pod (priority 100000) Pending
   1. 确认允许抢占（preemptionPolicy != Never）
   2. 找候选节点：模拟删掉部分低优先级 Pod 后，urgent 能否放下
   3. 挑受害者（victim）：只考虑优先级【严格低于】抢占者的 Pod；
      优先删优先级最低的、尽量少删、尽量不违反 PodDisruptionBudget
   4. 通过 API 删除受害者（带优雅终止），给 urgent 记 nominatedNodeName
   5. 受害者的 Deployment 重建副本 → 重新排队（可能落在别的节点）
```

两个易错点：优先级**相等**的 Pod 永远不会被抢占者赶走；`nominatedNodeName` 只是"提名"，若释放资源的瞬间有别的高优先级 Pod 抢先落位，抢占者继续 Pending 重来。

## 6. 调度失败 vs 驱逐：两个不同组件的两种失败

| 维度 | 调度失败（FailedScheduling） | 驱逐（Evicted） |
| --- | --- | --- |
| 发起组件 | kube-scheduler（控制面） | kubelet（节点资源压力）或人工/API 发起的 eviction（如 drain） |
| 触发原因 | 没有节点同时满足所有 Filter：资源不足、污点不容忍、亲和不满足、卷没绑定 | memory.available / nodefs.available 等硬阈值被突破，节点自保 |
| Pod 状态 | 一直 Pending，不创建容器 | Pod 被删除（事件 reason=Evicted / SystemOOM），重建后重新调度 |
| 恢复方式 | 条件缓解后 scheduler 自动重试 | 阈值回落即停止；需处理根因（清盘/加内存/查泄漏） |
| 与 QoS 的关系 | 无关（只看 requests） | 强相关（BestEffort 最先被赶，见第 11 章） |

一句话记忆：**调度失败是"没地方去"，驱逐是"待不下去了"**。前者看 apiserver 的 FailedScheduling 事件，后者看节点 kubelet 日志与 Pod 的 Evicted 事件。

## 实战演练

环境：kubeadm 集群（单 master + Calico）。把命令中的 `worker1` 替换成你环境里的真实节点名。

```bash
# [master] 看节点、污点与可分配 CPU
kubectl get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key,ALLOC-CPU:.status.allocatable.cpu'
```

### 演练 1：亲手制造一次 FailedScheduling

```bash
# [master] requests 直接要 500 核，任何节点都放不下
kubectl run too-big --image=nginx:1.27 --restart=Never --requests=cpu=500
kubectl get pod too-big; kubectl describe pod too-big | grep -A4 Events
# 预期输出（核心两行）：
#   Warning  FailedScheduling  ...  0/2 nodes are available: 2 Insufficient cpu.
#   ...  preemption: 0/2 nodes are available: 2 No preemption victims found for incoming pod.
kubectl -n kube-system logs kube-scheduler-$(hostname) --tail=5
kubectl delete pod too-big
```

第二行 "No preemption victims found" 说明 scheduler 也尝试过抢占，但节点上没有优先级更低的受害者可删——排障时这行能帮你把"资源不够"和"约束不满足"区分开。

### 演练 2：nodeAffinity 硬规则与软规则

```bash
# [master] 只给 worker1 打标签，制造节点差异
kubectl label node worker1 disktype=ssd --overwrite
kubectl apply -f node-affinity.yaml        # 内容见 3.2 节
kubectl get pod affinity-demo -o wide      # 落在 worker1（唯一满足 In [ssd,nvme] 的节点）
```

把 required 的 values 改成 `["fc"]` 再建一个新名字的 Pod，会看到事件 `node(s) didn't match Pod's node affinity/selector`。实验后 `kubectl delete pod affinity-demo`。

### 演练 3：污点三种 effect 对照

```bash
# [master] 步骤 A：NoSchedule 只挡新 Pod；NoExecute 连存量都赶走
kubectl taint node worker1 tier=edge:NoSchedule
kubectl run taint-probe --image=nginx:1.27 --restart=Never
kubectl get pod taint-probe -o wide      # Pending：untolerated taint
kubectl delete pod taint-probe --force --grace-period=0
kubectl taint node worker1 tier=edge:NoExecute --overwrite
# 预期：worker1 上无容忍的 Pod 批量 Evicted/Terminating，控制器在别的节点重建

# 步骤 B：带容忍的 Pod 进得来；实验后清理两条污点
kubectl run edge-ok --image=nginx:1.27 --restart=Never \
  --overrides='{"spec":{"tolerations":[{"key":"tier","operator":"Equal","value":"edge","effect":"NoSchedule"}]}}'
kubectl get pod edge-ok -o wide && kubectl delete pod edge-ok
kubectl taint node worker1 tier=edge:NoExecute-
kubectl taint node worker1 tier=edge:NoSchedule-
```

### 演练 4：副本打散（topologySpreadConstraints）

```bash
# [master] 应用 3.3 节的 web Deployment（replicas=3）并加 3.4 节的 spread 约束
kubectl apply -f anti-affinity.yaml
kubectl get pods -l app=web -o wide   # 副本按节点均摊；若只有 1 个可调度节点，多出的副本 Pending
```

### 演练 5：抢占旁观

先按 5.1 节创建两个 PriorityClass，然后填节点、插队（low 的 replicas 目标：占满节点后剩余放不下 urgent）：

```yaml
# [master] 保存为 low-batch.yaml（数值按 2 vCPU 节点设计；4 vCPU 节点把 replicas 改为 5）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: low-batch
spec:
  replicas: 3
  selector:
    matchLabels:
      app: low-batch
  template:
    metadata:
      labels:
        app: low-batch
    spec:
      priorityClassName: batch-low
      containers:
      - name: main
        image: busybox:1.36
        command: ["sh", "-c", "sleep 3600"]
        resources:
          requests:
            cpu: 600m      # 3 个共 1800m，加上系统负载后 2 核节点再无整块空间
```

```bash
# [master] 观察：urgent 触发抢占，受害者被删、Deployment 重建
kubectl apply -f low-batch.yaml && sleep 20
kubectl run urgent --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"priorityClassName":"urgent"}}' \
  --requests=cpu=600m -- sh -c "sleep 600"
kubectl get events --field-selector reason=Preempted --sort-by=.lastTimestamp
# 预期输出：Normal Preempted ... Preempted by pod default/urgent on node worker1
kubectl get pods -o wide    # urgent Running；low-batch 少一个副本、多一个 Pending
kubectl delete -f low-batch.yaml; kubectl delete pod urgent --force --grace-period=0
kubectl delete priorityclass urgent batch-low
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 单节点集群 Pod 全 Pending，事件含 `untolerated taint node-role.kubernetes.io/control-plane` | 控制面默认污点未清 | `kubectl taint node <master> node-role.kubernetes.io/control-plane-` 或给 Pod 加 toleration |
| `0/2 nodes are available: 2 Insufficient cpu` | requests 总和超过 Allocatable（含系统 Pod 已占部分） | 调低 requests 或扩容；`kubectl describe node` 看 Allocated resources |
| Deployment 扩容后部分副本永久 Pending | required 反亲和/spread 超过节点数 | 改 preferred/ScheduleAnyway，或加节点 |
| 改了节点标签，已运行 Pod 没动 | IgnoredDuringExecution：绑定后不再迁移 | 滚动重启让新 Pod 按新标签落位 |
| 以为 NoSchedule 会踢 Pod，节点上却安然无恙 | NoSchedule 只拦新 Pod | 要踢存量用 NoExecute 或 drain |

## 自测

1. `requiredDuringSchedulingIgnoredDuringExecution` 里的 IgnoredDuringExecution 到底"忽略"了什么？如果想让"节点标签变化"触发存量 Pod 迁移，有哪些现实做法？

<details><summary>答案</summary>

忽略的是执行期：调度决策只做一次，绑定之后节点标签、污点、其他 Pod 位置的变化都不再影响该 Pod。想让存量 Pod 迁移只能制造一次"重新调度"：delete Pod 让控制器重建、`kubectl rollout restart`，或用 Descheduler 类工具周期性重排。集群没有"搬运行中 Pod"的原生能力。
</details>

2. 节点忽然断电，为什么 Pod 在原节点上还会"存活"约 5 分钟才被驱逐？谁注入了什么 toleration？

<details><summary>答案</summary>

节点失联后 node controller 打上 `node.kubernetes.io/unreachable:NoExecute` 污点。DefaultTolerationSeconds 准入控制器在 Pod 创建时就注入了对 not-ready/unreachable 两个 NoExecute 污点各 300 秒的容忍，所以驱逐要等容忍窗口耗尽——目的是防网络抖动造成大规模无谓迁移。
</details>

3. `kubectl cordon node` 和 `kubectl taint node x key:NoSchedule` 都能挡新 Pod，二者在机制上有何差异？DaemonSet 为什么两个都拦不住？

<details><summary>答案</summary>

cordon 把 `spec.unschedulable` 置 true，默认调度器不再往该节点放新 Pod；drain 内部就是 cordon + eviction。taint 是通用机制，可带任意 key/value/effect，还能用 NoExecute 驱逐存量。DaemonSet 控制器创建 Pod 时直接设置 `spec.nodeName` 绕过默认调度器，cordon 挡不住它；同时它自动为 Pod 添加对内置节点条件污点（not-ready/压力类/unschedulable）的容忍，所以这些内置污点也拦不住它——只有自定义污点默认能挡住 DaemonSet 的新 Pod。
</details>

4. 抢占者删掉受害者后为什么仍可能 Pending？`nominatedNodeName` 有什么保证？

<details><summary>答案</summary>

没有任何保证。提名节点后资源释放是异步的（受害者有优雅终止期），期间另一个更高优先级或先到的 Pod 可能在该节点落位；释放出的资源也可能因卷绑定、亲和等条件不满足而用不上。于是抢占者带着 nominatedNodeName 继续排队，必要时再发起一轮抢占。
</details>

5. 节点实际 CPU 闲得很（`top` 显示 5%），新建 Pod 却报 Insufficient cpu。为什么"实际用量"救不了它？

<details><summary>答案</summary>

调度只认账本不认现状：Filter 比较的是 `requests <= Allocatable - Σ(已承诺 requests)`。requests 是调度层面的"预订"，与实际用量、limits 是两套约束（运行时由 cgroups 执行，见第 11 章）。解法：清理僵尸负载、调低 requests 或扩容节点。
</details>

## 延伸阅读

- 把 Pod 分配到节点（亲和/反亲和）：https://kubernetes.io/docs/concepts/scheduling-eviction/assign-pod-node/
- 污点与容忍：https://kubernetes.io/docs/concepts/scheduling-eviction/taint-and-toleration/
- Pod 拓扑分布约束：https://kubernetes.io/docs/concepts/scheduling-eviction/topology-spread-constraints/
- Pod 优先级与抢占：https://kubernetes.io/docs/concepts/scheduling-eviction/pod-priority-preemption/
