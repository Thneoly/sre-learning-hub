# 11 · 资源与 QoS：requests、limits 与 cgroups 的真相

> 模块：04-k8s-fundamentals ｜ 建议时长：3 小时 ｜ 关联认证：CKA-资源管理 / PCA-PromQL（资源指标）

## 学习目标

- 能解释 requests 与 limits 的两个去向：requests 给调度器记账，limits 由 kubelet 落到 cgroups
- 能操作容器内 `/sys/fs/cgroup` 完成 CPU 节流与 memory OOMKill 两个实验并解读计数器
- 能解释 Mi/M、100m/0.5 等单位语义，避开常见的 4.9%/7.4% 偏差
- 能用 QoS 三类判定规则表推断任意 Pod 的 QoS 等级与被驱逐顺序
- 能设计一套合理的超卖比例并用 PromQL 度量集群超卖率与节流率

## 1. requests 与 limits：一句话分清

```yaml
# [master] 资源字段全景（Pod spec 片段）
    resources:
      requests:          # "预订"：调度器拿它记账，决定去哪个节点
        cpu: 250m        #   同时也是节点压力驱逐时的"配额基线"
        memory: 128Mi
      limits:            # "天花板"：kubelet 写进 cgroups，内核强制执行
        cpu: 500m        #   CPU 超了 → 节流（throttle），不杀进程
        memory: 256Mi    #   内存超了 → OOMKill，容器被杀
```

| 字段 | 消费者 | 生效机制 | 超限后果 |
| --- | --- | --- | --- |
| requests.cpu | kube-scheduler（Filter） | 只影响放置，不影响运行时 | 放不放得下的问题，无运行时后果 |
| requests.memory | 调度器 + kubelet 驱逐排序 | 驱逐时按"用量超出 requests 多少"排序 | 超出 requests 的用量最先被牺牲 |
| limits.cpu | kubelet → cgroup `cpu.max` | CFS 带宽控制，每 100ms 周期发配额 | 节流：进程被暂停到下个周期 |
| limits.memory | kubelet → cgroup `memory.max` | 内存硬上限 | OOMKill：exit code 137，`OOMKilled` |

CPU 是**可压缩资源**（慢一点能忍），内存是**不可压缩资源**（没法"挤一挤"，只能杀）。这个不对称决定了两者的超卖策略完全不同。

查看某节点"账本"的方式（调度器视角的已承诺量）：

```bash
# [master] Allocated resources 一栏的 requests 总和就是调度依据
kubectl describe node worker1 | sed -n '/Allocated resources/,/Events/p'
```

## 2. limits 落到 cgroups：两个亲手实验

环境：Ubuntu 22.04/24.04（cgroups v2）+ containerd（systemd cgroup driver）。cgroups v2 下 CPU 配额在 `cpu.max`（格式 `quota period`），内存在 `memory.max`，节流计数在 `cpu.stat`。

### 2.1 CPU 节流实验

```yaml
# [master] 保存为 throttle-demo.yaml
apiVersion: v1
kind: Pod
metadata:
  name: throttle-demo
spec:
  containers:
  - name: main
    image: busybox:1.36
    command: ["sh", "-c", "yes > /dev/null & sleep 3600"]   # yes：单核满载空转
    resources:
      requests:
        cpu: 50m
      limits:
        cpu: 100m          # 每周期 100ms 只准用 10ms
```

```bash
# [master] 起起来直接读 cgroup（容器内 /sys/fs/cgroup 就是自己的限制）
kubectl apply -f throttle-demo.yaml
sleep 20
kubectl exec throttle-demo -- cat /sys/fs/cgroup/cpu.max
# 预期输出：10000 100000    ← quota=10000us / period=100000us = 0.1 核
kubectl exec throttle-demo -- cat /sys/fs/cgroup/cpu.stat
# 预期输出（数值持续增长）：
#   nr_periods 20
#   nr_throttled 20         ← 每个周期都被节流
#   throttled_usec 1800000  ← 被暂停的累计微秒数
```

解读：`yes` 想要 100% 的核，但每 100ms 只拿到 10ms 配额，用完即被内核挂起——进程没死，只是"卡"。这是"CPU 用量不高但 P99 延迟尖刺"的头号嫌疑，应用往往每 100ms 集中卡一次（CFS 周期默认 100ms）。

```bash
# [worker1] 节点视角：Pod 在 kubepods 层级下（systemd 驱动 + cgroups v2）
ls /sys/fs/cgroup/ | grep -i kubepods
ls /sys/fs/cgroup/kubepods.slice/ | head -5
```

### 2.2 内存 OOMKill 实验

```yaml
# [master] 保存为 oom-demo.yaml
apiVersion: v1
kind: Pod
metadata:
  name: oom-demo
spec:
  containers:
  - name: main
    image: busybox:1.36
    # 往 tmpfs (/dev/shm) 猛写：页内存计入本容器的 memcg，很快突破 32Mi
    command: ["sh", "-c", "dd if=/dev/zero of=/dev/shm/fill bs=1M count=200; sleep 3600"]
    resources:
      requests:
        memory: 16Mi
      limits:
        memory: 32Mi
```

```bash
# [master] 复现与取证
kubectl apply -f oom-demo.yaml
sleep 10
kubectl get pod oom-demo                # CrashLoopBackOff（restartPolicy 默认 Always）
kubectl describe pod oom-demo | grep -A4 'Last State'
# 预期输出：
#   Last State:  Terminated
#     Reason:    OOMKilled
#     Exit Code: 137          ← 128+9(SIGKILL)，内存超限的铁证
#     Started:   ...
kubectl get pod oom-demo -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'
# 预期输出：OOMKilled
kubectl delete pod oom-demo throttle-demo --force --grace-period=0
```

注意区分两类 OOM：**容器超限**（cgroup `memory.max` 触发，reason=OOMKilled）与**节点内存耗尽**（内核全局 OOM 或 kubelet 驱逐，事件里能看到 SystemOOM/Evicted）。前者看 limits，后者看节点 Allocatable 与驱逐阈值。

## 3. 单位陷阱：M 不是 Mi

| 写法 | 精确含义 | 常见误解 |
| --- | --- | --- |
| `cpu: 1` | 1 核（1 vCPU 的时间片） | 以为是 1% 或 1 毫秒 |
| `cpu: 100m` | 100 millicores = 0.1 核 | m 被当成 MB/百万 |
| `cpu: 0.5` | 0.5 核，等价 `500m` | 合法但风格混乱，建议统一用 m |
| `memory: 128M` | 128 × 10^6 = 128,000,000 字节 | 与 128Mi 差约 4.9% |
| `memory: 128Mi` | 128 × 2^20 = 134,217,728 字节 | 正确的"运维直觉"单位 |
| `memory: 1G` / `1Gi` | 10^9 / 2^30 字节 | 两者差约 7.4% |
| `nvidia.com/gpu: 1` | 扩展资源不可分割 | `100m` GPU 非法，最小 1 |

实测对比：

```bash
# [master] 两个"看起来一样"的内存限制
kubectl run mem-m  --image=busybox:1.36 --restart=Never --limits=memory=100M -- sleep 3600
kubectl run mem-mi --image=busybox:1.36 --restart=Never --limits=memory=100Mi -- sleep 3600
kubectl get pod mem-m mem-mi -o custom-columns='NAME:.metadata.name,LIMIT:.spec.containers[0].resources.limits.memory'
# 预期输出：
#   NAME    LIMIT
#   mem-m   100M       ← 100,000,000 字节
#   mem-mi  100Mi      ← 104,857,600 字节，多出 4.86%
kubectl delete pod mem-m mem-mi
```

规范：CPU 用 `m`、内存用 `Mi/Gi`，全集群统一，避免"差一点就够"的悬案。

## 4. QoS 三类：判定规则与驱逐顺序

QoS 等级不是设置出来的，是 apiserver 按 Pod 内每个容器的资源字段**推导**的，写在 `status.qosClass`：

| QoS | 判定规则（逐容器检查，全部满足才算） | oom_score_adj | 被驱逐/被杀顺序 |
| --- | --- | --- | --- |
| Guaranteed | 每个容器**同时**设置 cpu 与 memory，且 requests == limits（只写 limits 也算：默认 requests=limits） | -997 | 最后（几乎免疫节点 OOM 的优先牺牲） |
| Burstable | 至少一个容器设置了 requests 或 limits，但不满足 Guaranteed | 2~999（随 memory request 占节点内存比例递减） | 中间：超出 requests 的用量先被牺牲 |
| BestEffort | 所有容器都完全没写 requests/limits | 1000（最先被内核 OOM killer 盯上） | 最先 |

```bash
# [master] 一条命令查 QoS，再亲手验证三类
kubectl get pods -A -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,QOS:.status.qosClass' | head -10
kubectl run qos-g --image=busybox:1.36 --restart=Never \
  --limits=cpu=200m,memory=128Mi -- sleep 3600        # 只写 limits → requests 默认相等
kubectl run qos-b --image=busybox:1.36 --restart=Never \
  --requests=cpu=100m -- sleep 3600
kubectl run qos-e --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl get pods qos-g qos-b qos-e -o custom-columns='POD:.metadata.name,QOS:.status.qosClass'
# 预期输出：
#   POD    QOS
#   qos-g  Guaranteed
#   qos-b  Burstable
#   qos-e  BestEffort
kubectl exec qos-e -- cat /proc/self/oom_score_adj     # 1000
kubectl exec qos-g -- cat /proc/self/oom_score_adj     # -997（越大越先被 OOM killer 选中）
kubectl delete pod qos-g qos-b qos-e
```

### 节点压力驱逐：kubelet 的自保

当节点资源触及硬阈值，kubelet 按顺序杀 Pod 自保。默认硬阈值（可配置）：

| 信号 | 默认阈值 | 含义 |
| --- | --- | --- |
| memory.available | < 100Mi | 节点可用内存 |
| nodefs.available | < 10% | kubelet 根文件系统 |
| nodefs.inodesFree | < 5% | 同上 inode |
| imagefs.available | < 15% | 镜像/容器层盘 |
| imagefs.inodesFree | < 5% | 同上 inode |

```yaml
# [master] KubeletConfiguration 关键字段速查（/var/lib/kubelet/config.yaml，供阅读比对，不要在实验集群乱改）
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
evictionHard:
  memory.available: "100Mi"
  nodefs.available: "10%"
evictionSoft:
  memory.available: "500Mi"          # 软阈值：超过宽限期才动手
evictionSoftGracePeriod:
  memory.available: "1m30s"
evictionMaxPodGracePeriod: 30
```

驱逐排序算法：先杀"用量超出 requests 最多"的 Pod（BestEffort 的 requests 是 0，全部用量都算超出），同级再看优先级与使用量。这解释了两条纪律：给关键服务 requests ≈ 真实用量（别虚低）；不写资源的 Pod 就是在节点内存紧张时替全节点"挡枪"。

三个"被杀/被赶"概念的最后区分：**调度失败**（scheduler，放不下，Pending）、**节点压力驱逐**（kubelet，阈值触发，事件 Evicted）、**API 驱逐**（kubectl drain 走 eviction API，尊重 PDB，见第 8 章）。

## 5. 管住别人不写资源：LimitRange 与 ResourceQuota

```yaml
# [master] 保存为 ns-quota.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: dev
---
apiVersion: v1
kind: LimitRange
metadata:
  name: defaults
  namespace: dev
spec:
  limits:
  - type: Container
    defaultRequest:          # 没写 requests 的容器兜底
      cpu: 100m
      memory: 128Mi
    default:                 # 没写 limits 的容器兜底；与 defaultRequest 不相等 → QoS 推导为 Burstable
      cpu: 500m
      memory: 256Mi
    max:                     # 单容器上限，写超了直接被 apiserver 拒绝
      cpu: "2"
      memory: 2Gi
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota
  namespace: dev
spec:
  hard:
    requests.cpu: "4"        # namespace 内 requests 总账
    requests.memory: 4Gi
    limits.cpu: "8"
    limits.memory: 8Gi
    pods: "20"
```

```bash
# [master] 应用并在该 namespace 里创建不写资源的 Pod，观察兜底
kubectl apply -f ns-quota.yaml
kubectl -n dev run no-res --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl -n dev get pod no-res -o custom-columns='QOS:.status.qosClass,REQ:.spec.containers[0].resources.requests'
# 预期输出：QOS=Burstable（requests 100m/128Mi，limits 500m/256Mi，两者不等）
kubectl -n dev delete pod no-res && kubectl delete -f ns-quota.yaml
```

## 6. 超卖设计：requests 是账，cgroups 是命

超卖（overcommit）= 故意让 Σrequests 超过物理容量，赌所有容器不会同时用满。合理的前提是分资源讨论：

| 资源 | 常见超卖倍数 | 超过之后的连锁反应 |
| --- | --- | --- |
| CPU | Σrequests : 物理 ≈ 1:1~1.5，Σlimits 可到 3~10 倍 | 节流、延迟尖刺，可容忍、可观测（nr_throttled） |
| 内存 | Σrequests : 物理 ≤ 1（或最多 1.1~1.2） | OOMKill 与驱逐连锁，一次误判就是生产事故 |

设计准则：requests 定位"平时的真实用量"（决定调度密度与驱逐排序），limits 定位"峰值允许值"（决定节流/被杀的红线）。关键在线服务建议 Guaranteed 或 requests/limits 比 0.8 以上；批处理/离线用低 priority + 低 requests，被抢占被驱逐都不心疼（配合第 8 章 PriorityClass）。

用 PromQL 度量超卖与节流（kube-state-metrics + cAdvisor，已部署 kube-prometheus-stack 即可）：

```promql
# [本地Windows] Prometheus/Grafana 探索框中执行
# 1. 集群内存超卖率（>1 即已超卖）
sum(kube_pod_container_resource_requests{resource="memory", unit="byte"})
  /
sum(kube_node_status_allocatable{resource="memory", unit="byte"})

# 2. CPU 超卖率
sum(kube_pod_container_resource_requests{resource="cpu", unit="core"})
  /
sum(kube_node_status_allocatable{resource="cpu", unit="core"})

# 3. 某容器被节流的周期占比（>0.2 就该提高 limit 或查代码）
sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total{container!=""}[5m]))
  /
sum by (namespace, pod) (rate(container_cpu_cfs_periods_total{container!=""}[5m]))

# 4. 内存逼近 limits 的程度（>0.9 随时 OOM）
max by (namespace, pod) (container_memory_working_set_bytes{container!=""})
  /
max by (namespace, pod) (kube_pod_container_resource_limits{resource="memory", unit="byte"})

# 5. 实际用量 vs requests（超卖是否"赌赢"：usage/requests 长期远小于 1 说明 requests 虚高）
sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!=""}[5m]))
  /
sum by (namespace, pod) (kube_pod_container_resource_requests{resource="cpu", unit="core"})
```

## 实战演练

10 分钟把第 2/3/4 节的内嵌实验串成一条验证链（对象定义见对应小节）：

```bash
# [master] 1) CPU 节流：读 cgroup 计数器（2.1 的 throttle-demo.yaml）
kubectl apply -f throttle-demo.yaml
sleep 20
kubectl exec throttle-demo -- cat /sys/fs/cgroup/cpu.max      # 预期: 10000 100000
kubectl exec throttle-demo -- cat /sys/fs/cgroup/cpu.stat
# 预期: nr_throttled 持续增长 —— CPU 超限是"卡"不是"死"

# [master] 2) 内存 OOMKill：拿退出码铁证（2.2 的 oom-demo.yaml）
kubectl apply -f oom-demo.yaml
sleep 10
kubectl get pod oom-demo                                        # 预期: CrashLoopBackOff
kubectl get pod oom-demo -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}{"\n"}'
# 预期: OOMKilled（Exit Code 137）

# [master] 3) QoS 判定三类一次跑出（第 4 节）
kubectl run qos-g --image=busybox:1.36 --restart=Never \
  --limits=cpu=200m,memory=128Mi -- sleep 3600
kubectl run qos-b --image=busybox:1.36 --restart=Never \
  --requests=cpu=100m -- sleep 3600
kubectl run qos-e --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl get pods qos-g qos-b qos-e \
  -o custom-columns='POD:.metadata.name,QOS:.status.qosClass'
# 预期: Guaranteed / Burstable / BestEffort 各一行

# [master] 4) 清理
kubectl delete pod throttle-demo oom-demo qos-g qos-b qos-e --force --grace-period=0 --wait=false
```

有 Prometheus 环境时，用第 6 节的 PromQL 1（内存超卖率）与 3（节流周期占比）复查上面实验留下的真实数据，完成"实验 → 指标"的闭环。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 容器内存给的是 100M，程序按 100Mi 申请却 OOM | M 是 10^6，少了 4.9% | 全集群统一 Mi/Gi |
| CPU 利用率不高但接口周期性卡顿 | limits 触发 CFS 节流（`nr_throttled` 增长） | 提高/cpu limit；查 `cpu.stat`；热点容器单独调优 |
| exit code 137 / Reason OOMKilled | 超 limits.memory，或节点内存压力连坐 | 对照 `container_memory_working_set_bytes` 与 limit |
| Pod 状态 Evicted，节点 NotReady 后恢复 | 节点触及 evictionHard（常见 nodefs/内存） | `kubectl describe node` 看条件与事件，清理镜像/查泄漏 |
| 节点明明空闲，却报 Insufficient cpu | 调度只看 Σrequests，已被僵尸负载占满账本 | describe node 的 Allocated resources，清理 CrashLoop 负载（它们仍占 requests） |
| 关键服务在节点内存紧张时先死 | BestEffort/Burstable 顺序在前 | requests 贴真实用量，或直接 Guaranteed |
| 只写 limits 却自称 Burstable | 只写 limits 时默认 requests=limits，实为 Guaranteed | 记住判定规则，用 `status.qosClass` 验证 |
| Go/Java 容器按节点核数设线程池，limit 只有 1 核 | 运行时读的是节点 CPU 数而非 cgroup 配额（旧版本 Go 如此） | 显式设 GOMAXPROCS / UseContainerSupport，或引入 automaxprocs 类方案 |

## 自测

1. 为什么 CPU 超限是"节流"而内存超限是"杀死"？从两种资源的可压缩性解释。

<details><summary>答案</summary>

CPU 是时间片资源，可压缩：内核 CFS 可以把进程暂停（throttle），下个周期再跑，正确性不受影响，只是变慢。内存是不可压缩的：已分配的物理页没法"先少用一点"，等价的选择只有换出（受 swap 语义/延迟限制）或回收页缓存，耗尽时唯一止损手段就是杀进程释放整块内存，所以内核选择 OOMKill。
</details>

2. 一个容器只写了 `limits: {cpu: 1, memory: 1Gi}`，QoS 是什么？为什么？

<details><summary>答案</summary>

Guaranteed。apiserver 默认把未写的 requests 补成与 limits 相等（这是合法的简写）。但注意：补全只发生在"该资源写了 limits 未写 requests"时；若写了 requests 没写 limits，则不会反向补，Pod 是 Burstable。
</details>

3. 节点内存告急，三个候选 Pod：A（BestEffort，用 500Mi）、B（Burstable，requests 100Mi，用 600Mi）、C（Guaranteed 1Gi/1Gi，用满 1Gi）。kubelet 先驱逐谁？排序依据是什么？

<details><summary>答案</summary>

先 B 或 A（按"用量超出 requests 的量"排）：B 超出 500Mi（600-100），A 超出 500Mi（500-0），两者同量级时继续比优先级和总体使用量，A 的 requests 为 0、无优先级通常先死；C 超出量为 0（1Gi-1Gi），Guaranteed 且 oom_score_adj=-997，最后才会被动到。核心规则：驱逐牺牲的是"超额部分"，requests 就是各自的"保底配额"。
</details>

4. cpu.max 输出 `10000 100000`，对应多少核的 limit？`throttled_usec` 半小时涨了 300 秒说明什么？

<details><summary>答案</summary>

quota/period = 10000/100000 = 0.1 核（100m）。throttled_usec 半小时涨 300s 表示该容器在半小时里有 300 秒处于"被内核挂起等下个周期"的状态（16.7% 的时间不可用），即使平均利用率看着不高，延迟敏感型请求也会周期性卡顿。
</details>

5. 为什么"CPU 超卖 5 倍"是常规操作，而"内存超卖 5 倍"几乎必然出事？

<details><summary>答案</summary>

CPU 超卖的后果是可压缩的：竞争时大家变慢（节流），负载回落后自动恢复，损失是延迟而非可用性，且可用 nr_throttled 监控兜底。内存超卖的后果是二元的：分配失败即 OOMKill，而很多负载的内存峰值同时出现（早高峰、缓存预热），赌注必输；同时 OOM 会触发重建风暴进一步放大内存压力。因此内存通常只允许 Σrequests ≤ 物理容量，最多留 10%~20% 的统计型冗余。
</details>

## 延伸阅读

- 管理容器的计算资源：https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/
- Pod 服务质量（QoS）：https://kubernetes.io/docs/concepts/workloads/pods/pod-qos/
- 节点压力驱逐：https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/
- 为系统守护进程预留资源：https://kubernetes.io/docs/tasks/administer-cluster/reserve-compute-resources/
- LimitRange 与 ResourceQuota：https://kubernetes.io/docs/concepts/policies/limit-range/ 、https://kubernetes.io/docs/concepts/policy/resource-quotas/
- cgroup v2：https://kubernetes.io/docs/concepts/architecture/cgroups/
