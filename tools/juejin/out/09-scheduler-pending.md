---
title_juejin: 你的 Pod 为什么 Pending：调度器两阶段
title_zhihu: 你的 Pod 为什么 Pending：调度器两阶段
description: 调度器两阶段全景（过滤→打分）、四类约束、抢占流程、Pending排查五步法。附可直接运行的复现实验。
category_id: "6809637769959178254"
tags: "Kubernetes,后端"
column_id: "7686346277555683378"
---

# 节点全绿、CPU 闲着，Pod 却集体 Pending——调度器只看你承诺了多少

周一早上发版，CI 全绿，Pod 就是不起来。`kubectl get nodes` 齐刷刷 Ready，登节点 `top` 一看 CPU 才用 8%；`kubectl get pods` 里新副本排成一排 Pending，像集体罢工。

describe 点开，答案就一行：`0/1 nodes are available: 1 Insufficient cpu.`——机器闲得能跑马，调度器说你 CPU 不够。

它没冤枉你。**调度器看的从来不是机器还剩多少，是你承诺出去了多少。** 这篇就从这个"一切健康、但什么都起不来"的现场出发，把 Pending 的每一类原因、每一类解法，以及"我明明修了、Pod 为什么还不动"的怪象，一次讲透。

上一篇讲 Pod 创建 8 步时，调度器只在第 3 步露了一脸。这次把它单独拎出来审问。读完你能带走：一张 Pending 排查决策树、四类约束各自的验证命令、一次亲手做完的抢占实验，还有一个大多数人答不上来的问题——删掉占资源的大 Pod 之后，Pending 的 Pod 为什么还是不动。

## 一、先复现：五分钟搭出"集体 Pending"现场

这个故障不用等生产赏赐，可以主动制造。仓库里现成一个故障注入脚本，一条命令让所有新 Pod Pending：

```bash
git clone https://github.com/Thneoly/sre-learning-hub.git
cd sre-learning-hub/scripts/faults
sudo bash break-scheduler-pod.sh            # 注入故障
# sudo bash break-scheduler-pod.sh --restore  # 一键恢复，实验完记得收尾
```

脚本干的事一句话讲完：建一个低优先级的"资源海绵" Deployment，requests 要走节点上几乎全部可分配 CPU；之后再创建的业务 Pod（requests 只要 100m）就全部 Pending。所有对象都圈在 fault-sched 命名空间里，`--restore` 删掉命名空间就还原，实验集群放心玩。

脚本按单 master 集群写的。多节点集群请按脚本头部注释把对象改到目标节点，不然业务会被调度去别的节点，现场就搭不起来了。

注入完等十几秒，看现场三件套：

```bash
kubectl get nodes                                   # 全部 Ready，绿得发光
kubectl -n fault-sched get pods                     # fault-app 0/2，全是 Pending
kubectl -n fault-sched describe pod -l app=fault-app | grep -A4 Events
```

事件里躺着两行金子：

```text
Warning  FailedScheduling  ...  0/1 nodes are available: 1 Insufficient cpu.
Warning  FailedScheduling  ...  preemption: 0/1 nodes are available: 1 No preemption victims found for incoming pod.
```

这时看看节点的真实用量——海绵是个睡觉的 nginx，实际 CPU 接近零（装了 metrics-server 用 `kubectl top node`，没装就登节点 `top`，一样）。节点 Ready、CPU 闲着、控制面活蹦乱跳，新 Pod 就是上不去。所有监控都正常，这种错位感就是 Pending 故障的标配。

再看一眼账本，矛盾就解开了：

```bash
kubectl describe node "$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')" | grep -A8 'Allocated resources'
```

`Allocated resources` 那张表里，CPU requests 一栏接近 100%。真实用量 8%，承诺出去的却是 100%——调度器记账，记的是后者。

## 二、两阶段全景：Filter 说"能不能"，Score 说"好不好"

调度器给每个没绑定的 Pod 做的事，本质是两道面试：先 Filter 刷简历，再 Score 排名次。

Filter 是硬淘汰，一条不满足就出局；全部节点出局，Pod 保持 Pending，事件 reason 就是 FailedScheduling。注意这个设计有多贴心：调度器会把每个节点被拒的理由汇总写进事件里，等于把诊断答案直接递到你手上，不读白不读。

跟 Pending 直接相关的 Filter 插件就这几张面孔：

| Filter 插件 | 剔除哪些节点 | 事件里的措辞 |
| --- | --- | --- |
| NodeResourcesFit | 放不下本 Pod 的 requests | `Insufficient cpu` / `Insufficient memory` |
| NodeAffinity + nodeSelector | 节点标签不匹配 | `node(s) didn't match Pod's node affinity/selector` |
| TaintToleration | 有本 Pod 不容忍的污点 | `node(s) had untolerated taint {xxx: }` |
| InterPodAffinity | 违反 required 的 pod 亲和/反亲和 | `didn't match pod anti-affinity rules` 一类 |
| VolumeBinding / VolumeZone | PVC 未绑定、PV 拓扑不符 | `pod has unbound immediate PersistentVolumeClaims` / `volume node affinity conflict` |
| NodeUnschedulable + 节点压力 | 被 cordon、磁盘/内存/PID 压力 | 也表现为 untolerated taint |

Score 是软排序，活下来的节点谁分高谁赢。默认策略是 LeastAllocated：节点剩余资源比例越高分越高，倾向把 Pod"铺开"而不是堆在一起；再加上镜像本地缓存、preferred 亲和这些打分项加权求和。

一句话分清两者：**Filter 决定"能不能"，答错直接 Pending；Score 决定"好不好"，答错只是落点不理想。** 排查 Pending 时只看 Filter，Score 不背这个锅。

再看第一节那个矛盾，公式就一行：

```text
节点剩余可承诺 = Allocatable - Σ(已绑定 Pod 的 requests)
本 Pod 过 Filter ⇔ 自己的 requests ≤ 这个数（CPU、memory、GPU 逐项都要满足）
```

海绵睡不睡觉根本不在公式里，它 requests 占的坑才是。所以想让业务 Pod 上去只有三条路：调低谁的 requests、删掉谁的 Pod、加节点。没有第四条。

最后钉三条铁律，条条都能解释一类"怪象"：

1. **只看 requests**。limits 和实时用量都不参与调度，运行时超不超限是 cgroups 的事。
2. **决策基于快照**。调度用的是决策那一刻的节点列表和账本，过时信息不存在的。
3. **决策是一次性的**。所有约束都叫 `...IgnoredDuringExecution`：绑定之后节点标签再变，已运行的 Pod 不会被搬家。想让它按新标签落位，只能删了重建或 `rollout restart`。

## 三、Pending 四大案发动机：逐个对号入座

FailedScheduling 那行字就是案发动机。四类约束、四种措辞，各自一条验证命令。

### 1. 资源：Insufficient cpu / memory

最常见的一类。验证就是拿账本对一下你的 requests：

```bash
kubectl describe node <node> | grep -A8 'Allocated resources'
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].resources.requests}'; echo
```

解法按这个顺序想：先清"订了位置没来"的僵尸负载（很多测试 Pod requests 留着没人管），再压一压拍脑袋写出来的 requests，最后才是加节点。注意系统 Pod 占的 requests 也记在账本里，别只盯着业务。

### 2. 亲和性：didn't match node affinity/selector

nodeSelector 或 required nodeAffinity 把可选节点圈得太窄，甚至圈没了。验证一句：

```bash
kubectl get nodes -l <你的选择器>     # 空输出 = 满足条件的节点一个都没有
```

最经典的翻车是 required 反亲和：replicas 3、要求每节点最多 1 个、可调度节点只有 2 个，第 3 个副本永远 Pending。解法：改成带 weight 的 preferred 软规则，或把 spread 约束的 `whenUnsatisfiable` 改成 ScheduleAnyway，或者干脆加节点。

### 3. 污点：untolerated taint

措辞是 `node(s) had untolerated taint {xxx: }`，花括号里直接写明了污点名。两个高频面孔：

单节点集群，花括号里是 `node-role.kubernetes.io/control-plane`——控制面默认污点把你的 Pod 挡在门外。解法二选一：给 Pod 加 toleration，或者删污点：

```bash
kubectl taint node <node> node-role.kubernetes.io/control-plane-
```

花括号里是 `node.kubernetes.io/disk-pressure` / `memory-pressure`——这不是谁手贱配的，是节点压力状态自动打的。这时候**别加 toleration 硬闯**，先处理节点本身：

```bash
kubectl describe node <node> | grep -A6 Conditions   # DiskPressure / MemoryPressure 是不是 True
```

### 4. 卷：unbound PVC / volume node affinity conflict

Local PV 和带拓扑的存储最常见：PVC 绑到的 PV 在 zone-a，Pod 又被亲和性钉死在 zone-b，事件就报 `node(s) had volume node affinity conflict`。验证顺着 PVC 找到 PV：

```bash
kubectl get pvc <pvc> -o jsonpath='{.spec.volumeName}'; echo
kubectl get pv <上面的名字> -o yaml | grep -A6 nodeAffinity
```

解法：换用 WaitForFirstConsumer 模式的 StorageClass（先调度 Pod、再按落点绑卷），或者把 Pod 的亲和和卷的拓扑对齐，别让两边各说各话。

### 案外案：别把"被驱逐"当"Pending"

排查第一步其实是分诊，两个故障长得像，责任人完全不同：

| 维度 | 调度失败（Pending） | 驱逐（Evicted） |
| --- | --- | --- |
| 谁说的"不行" | scheduler：没地方去 | kubelet：待不下去了 |
| Pod 状态 | 一直 Pending，容器压根没建 | Pod 被删，等控制器重建 |
| 去哪看原因 | apiserver 的 FailedScheduling 事件 | 节点日志与 Pod 的 Evicted 事件 |
| 典型诱因 | 资源/亲和/污点/卷 | memory.available 等硬阈值被突破 |

`kubectl get pod` 里一排 `Evicted` 的，去查节点磁盘和内存；一排 Pending 的，才轮到这篇的内容。

把上面全部收进一棵决策树，建议截图存着：

```text
FailedScheduling: 0/N nodes are available: N <理由>
 ├─ Insufficient cpu/memory                → 账本不够    → describe node 看 Allocated resources
 ├─ didn't match affinity/selector         → 圈太窄      → get nodes -l <选择器> 验证空集
 ├─ untolerated taint {控制面/自定义}       → 污点不容忍  → describe node 看 Taints
 ├─ untolerated taint {disk/memory-pressure} → 节点压力  → describe node 看 Conditions
 └─ unbound PVC / volume affinity conflict → 卷拓扑冲突  → get pvc → get pv 的 nodeAffinity
```

## 四、抢占：请高优先级 Pod 出手，把海绵请出去

回到现场。不删海绵、不加节点，有没有办法让 Pod 上去？有——抢占。但先解释为什么它没有自动发生。

脚本故意给海绵 priority 10、业务 Pod 默认 0。抢占的铁律是**受害者优先级必须严格低于抢占者**：业务 Pod(0) 动不了海绵(10)。所以那行 `No preemption victims found` 的真实含义是："比我低的受害者，一个都找不到。"

亲手做一次抢占救场（接着第一节的现场，先建高优先级类）：

```bash
kubectl create priorityclass urgent --value=100000 --description="救场用"
# 救场 Pod：单 master 集群要带上控制面污点的容忍，多节点可去掉 tolerations
kubectl run urgent --image=busybox:1.36 --restart=Never \
  --overrides='{"spec":{"priorityClassName":"urgent","tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}]}}' \
  --requests=cpu=100m -- sh -c "sleep 600"
```

几秒后看战果：

```bash
kubectl get events --field-selector reason=Preempted --sort-by=.lastTimestamp
# Normal  Preempted  ...  Preempted by pod default/urgent on node <你的节点>
kubectl -n fault-sched get pods -o wide
```

剧情按这个顺序展开：urgent 同样过不了 Filter → 调度器启动抢占，模拟"删掉部分低优先级 Pod 之后我放不放得下" → 选中海绵（唯一比它低的）→ 删掉海绵 Pod，给 urgent 记一个 nominatedNodeName → 海绵的 Deployment 立刻重建副本，但账本已被 urgent 和恢复的 fault-app 占住——新海绵反过来 Pending。

一句话总结：**救场 Pod 进场，海绵被请出去，业务全部恢复，海绵自己成了 Pending 的那个。** 优先级就是集群里的座位规则。（节点很小的话，你会看到 urgent Running、其余继续 Pending——座位还是优先级说了算。）

四个容易错的细节，面试和排障都用得上：

- **优先级相等永远不会互抢**。value 相同的两个 Pod，谁也动不了谁。
- **nominatedNodeName 只是提名，不是保留**。受害者优雅终止要时间，资源释放是异步的；这期间被别的 Pod 抢先落位，抢占者就带着提名继续排队，必要时再来一轮。
- 抢占会尽量少删人、优先删优先级最低的、尽量不违反 PodDisruptionBudget。它比你想象的克制。
- PriorityClass 设 `preemptionPolicy: Never`，就变成"只插队不抢人"：排队排前面，但绝不动已在座的人。另外 priorityClassName 引用的类必须先建好，否则 apiserver 直接拒收 Pod。

## 五、高潮实验：删了大 Pod，Pending 的为什么还不动

接下来是这篇最反直觉的实验。很多人修完 Pending 故障的第一反应是"我删掉那个占资源的大 Pod"，然后发现 Pending 的小 Pod 并没有立刻动，开始怀疑人生。我们把这件事拆开看明白。

先把现场重置回第一节的样子（上一节抢占已经把海绵干掉了）：

```bash
kubectl delete pod urgent --force --grace-period=0
kubectl delete priorityclass urgent
sudo bash break-scheduler-pod.sh --restore && sudo bash break-scheduler-pod.sh
```

**实验 A：只删海绵的 Pod**——最像"手滑清理"的操作：

```bash
kubectl -n fault-sched delete pod -l app=fault-sponge
kubectl -n fault-sched get pods -w
```

大概率几秒之内：海绵的新副本 Running，fault-app 依旧 Pending，FailedScheduling 又刷一条。账本刚空出来，就被原样占回去了。背后有两个机制在合谋：

- 海绵的 Deployment 比你还快，Pod 一删它就建新的。新 Pod 直接进调度器的活跃队列；fault-app 虽然也被"Pod 删除"事件唤醒，但退避没到期，只会先挪回退避队列等一会。
- 活跃队列按**优先级**弹出。海绵 10、业务 0，同在队列里海绵永远排在前面。

（如果你实验里是 fault-app 抢先落位、海绵 Pending，那是两个事件赛跑你运气好。不管谁先坐上去，另一边都会 Pending——坑就那么大，队列规则决定谁坐。）

**实验 B：正确的修复，连"承诺"一起清掉**：

```bash
kubectl -n fault-sched scale deployment fault-sponge --replicas=0
```

这次几秒内 fault-app 全部 Running。删 Pod（产生事件）+ 不再重建（没有新竞争者），账本是真的空出来了。

**实验 C：无效的修复，只动机器，不动账本**。

登节点清磁盘、重启某个进程、甚至 `kubectl exec` 进海绵把 nginx 杀掉——这些动作既不改变任何 Pod 的 requests，也不产生调度器关心的集群事件。在调度器眼里，世界一秒钟都没变过，账本还是满的，Pending 纹丝不动。不是 bug，是你修的东西不在考卷上。

实验 A 和 C 的诡异，根源都在调度器的重试机制。调度失败的 Pod 不是每秒被重试，它躺在"不可调度队列"里，靠三样东西唤醒：

| 唤醒方式 | 触发条件 | 延迟量级 |
| --- | --- | --- |
| 集群事件 | Pod 删除、节点增改、标签/污点变化、PVC 绑定 | 秒级 |
| 退避到期 | 失败后 1s 起指数翻倍，10s 封顶 | 秒级 |
| 5 分钟兜底 | 在不可调度队列待满 5 分钟，强制拉出来重试 | 分钟级 |

所以盯着 `kubectl get events -w` 看，FailedScheduling 的间隔会越来越稀——那是退避在起作用，不是调度器死了。而"我修了，Pod 愣了几秒才动"也是正常现象：事件传播、队列挪动、下一轮调度循环，每一跳都有延迟。

这套机制反过来用就是生产守则：**清理动作要删得干净、且产生事件**。删负载要 scale 到 0（防止控制器秒级回填）；改 resources 要真的改对象（spec 一变，Pod 会直接回活跃队列）；实在没动作可做，5 分钟兜底也会替你重试一次。

## 六、Pending 排查五步法

把全篇收进一张操作卡。下次遇到 Pending，照着走，五步之内必有答案。

| 步 | 动作 | 命令 | 在找什么 |
| --- | --- | --- | --- |
| 1 | 分诊 + 读判决书 | `kubectl get pod <p>`；`kubectl describe pod <p> \| grep -A6 Events` | 是 Pending 不是 Evicted；FailedScheduling 原文 |
| 2 | 对号入座 | 拿第 1 步的理由去查上面的决策树 | 四类约束命中哪一类 |
| 3 | 查节点侧账本 | `kubectl describe node <n>` 看 Taints、Conditions、Allocated resources | requests 满 / 污点 / 压力 |
| 4 | 查对象侧约束 | `get nodes -l`、`get pvc`、affinity 字段 | 选择器空集 / 卷拓扑冲突 / 圈太窄 |
| 5 | 干净地修 + 确认 | scale 0、`taint ...-`、调 requests、加节点 | `Normal Scheduled` 事件出现 |

最后附一张高频翻车速查表：

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 单节点集群 Pod 全 Pending，事件含 control-plane 污点 | 控制面默认污点 | 加 toleration 或删污点 |
| 节点 CPU 明明很闲，事件报 Insufficient cpu | requests 账本满了，账本与实时用量无关 | 清负载 / 调 requests / 扩容 |
| 扩容后部分副本永久 Pending | required 反亲和或 spread 超过节点数 | 改 preferred / ScheduleAnyway |
| 改了节点标签，存量 Pod 没反应 | IgnoredDuringExecution，绑定后不迁移 | 删了重建或 rollout restart |
| 修完故障 Pod 迟迟不动 | 退避 + 事件驱动重试的正常延迟 | 确认修复产生了事件，等秒级 |

## 写在最后

Pending 不是调度器在为难你，是它在替你说真话：你承诺出去的资源，比你以为的多；你圈定的节点，比你以为的少；你的修复动作，可能压根不在它关心的账本上。

那句话值得再念一遍：**调度器看的不是机器还剩多少，是你承诺出去了多少。** 记住它，一半的 Pending 故障在你看到事件那一秒就有了答案。

现在就能做的事——把这条命令跑一遍，五分钟后你会亲眼看到"节点全绿 + 集体 Pending"这个名场面，然后亲手用抢占和 scale 0 把它救回来：

```bash
git clone https://github.com/Thneoly/sre-learning-hub.git
cd sre-learning-hub/scripts/faults
sudo bash break-scheduler-pod.sh          # 注入，观察，做第四节和第五节的实验
sudo bash break-scheduler-pod.sh --restore  # 收尾，还原集群
```

评论区想做个小调查：你生产上遇到过的 Pending 是哪一种？Insufficient cpu、untolerated taint、反亲和圈太窄，还是 PVC 拓扑冲突？报个类型加一句当时的现象——每种我都见过不小的案子，你的踩坑经历可能正好是别人的排查线索。

这篇整理自我在维护的开源学习仓库 [sre-learning-hub](https://github.com/Thneoly/sre-learning-hub)，调度专题在 04-k8s-fundamentals 有一整章：PriorityClass、亲和、污点的完整演练命令都在里面。觉得有用点个 star，下一篇聊控制面的命脉 etcd——为什么挂 1 台没事，挂 2 台全完。
