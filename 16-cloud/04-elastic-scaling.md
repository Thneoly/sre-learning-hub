# 04 · 弹性伸缩：从 ESS/ASG 到 K8s 的三层伸缩

> 模块：16-cloud ｜ 建议时长：3 小时 ｜ 关联认证：CKA-资源管理（HPA 是明列考点）/ —（云侧伸缩无直接考点） ｜ 前置：第 01、02 章；HPA 机制细节见 04-k8s-fundamentals/04 §5

## 学习目标

- 能画出"入口 → Pod → Node → VM 配额"的分层伸缩模型，说清每层伸缩的对象、信号与时延量级
- 能说出 ASG（AWS）/ESS（阿里云）的三个组成部分与冷却时间、缩容策略的作用
- 能对比 HPA、cluster-autoscaler、Karpenter 的职责边界，解释"为什么 Karpenter 不需要节点组"
- 能给一条可预测的业务曲线设计定时伸缩方案（含预热时间的选择依据）
- 能组合 PDB、terminationGracePeriodSeconds、preStop 与 Spot 回收通知，保证缩容/回收不伤 SLI

## 1. 分层模型：谁在伸、靠什么信号、多快

```
流量 ──► 入口层：SLB/ALB 规格与带宽、网关副本        秒级（配置/计费维度变更）
      ──► Pod 层：HPA 改 replicas                    10s~分钟（受调度与镜像拉取限制）
      ──► Node 层：cluster-autoscaler / Karpenter    1~5 分钟（机型库存、节点启动、join）
      ──► 资源层：ASG/ESS 容量、vCPU 配额、镜像限额    分钟~天（配额提工单、库存不足）
```

| 层 | 伸缩对象 | 触发信号 | 典型时延 | 失败模式 |
|----|---------|---------|---------|---------|
| 入口 | 带宽/规格/网关副本 | QPS、连接数 | 秒 | 计费变更滞后、限速策略 |
| Pod | replicas | CPU/内存水位、QPS、队列深度（HPA 指标源） | 秒~分 | 镜像拉取慢、节点没资源（卡到下一层） |
| Node | 节点数 | Pending Pod（CA/Karpenter 的信号是"调度失败"） | 分 | 机型无库存、启动慢、join 失败 |
| 资源 | 配额/库存 | 人工+工单 | 分~天 | 账号 vCPU 配额打满、按量库存不足 |

两条直接推论：**上层快、下层慢**——Pod 层秒级响应，但它的天花板由 Node 层决定，Node 层又受配额约束，所以链路越往下越要提前量（第 4 节定时伸缩）；**各层信号不同源**——HPA 看"水位"，CA/Karpenter 看"调度失败"，入口层看"流量"，混用信号（比如用 CPU 水位去扩节点）通常比让它看本职信号更慢更钝。

## 2. VM 层：ASG（AWS）与 ESS（阿里云）

### 2.1 三个组成部分

| 组成 | ASG（AWS） | ESS（阿里云） | 说明 |
|------|-----------|--------------|------|
| 伸缩组 | Auto Scaling Group | 伸缩组 | 圈定 Min/Max/Desired、VSwitch/Subnet 范围（可跨 AZ） |
| 伸缩配置 | Launch Template | 伸缩配置 | 镜像、规格、安全组、存储、实例角色 |
| 伸缩规则 | 告警/定时/目标追踪策略 | 定时/报警/目标追踪规则 | 何时加/减几台，或维持某指标目标 |

工作循环：规则触发 → 伸缩组按配置创建/移出实例 → 新实例跑 user-data（或入集群，见第 3 节）→ 健康检查失败的实例被自动替换。**健康检查替换是伸缩组被低估的能力**：宿主机故障时它自动重建实例，等于云层的"自愈副本"。

两个关键参数：

- **冷却时间（cooldown）**：一次伸缩活动后多久内不再触发下一次，防止指标抖动导致连环加机器。注意它作用于简单/步骤策略；目标追踪（target tracking）类策略自带调节节奏，不依赖手工冷却。
- **缩容策略（termination policy）**：决定砍谁——默认倾向移出最旧实例（ASG 的 `OldestLaunchTemplate`、ESS 的旧配置优先）。对"实例无状态、配置即代码"的组是合理默认；有本地缓存的组要显式配置再想想。

### 2.2 与 K8s 的两种结合方式

```
方式 A（传统）：ASG/ESS ──user-data──► kubeadm join ──► 节点进集群
              cluster-autoscaler 反向调用 ASG/ESS API 改 Desired
方式 B（Karpenter）：Karpenter 直接调 EC2 API 创建/回收节点（不经过 ASG）
```

方式 A 是多数托管集群的默认形态（ACK 的 cluster-autoscaler 组件、EKS 配合 ASG 的托管节点组）；方式 B 把"节点组"这层抽象拆掉，见 3.3。

## 3. K8s 层：HPA / cluster-autoscaler / Karpenter 分层

### 3.1 HPA：Pod 层

HPA 的指标源、`期望副本 = ceil(当前副本 × 当前值 / 目标值)` 公式与 behavior 稳定窗口（扩容抢时间、缩容防抖）在 [04-k8s-fundamentals/04 §5](../04-k8s-fundamentals/04-workload-controllers.md) 已完整拆解，[21-perf-testing/02 §5](../21-perf-testing/02-capacity-planning.md) 给了 Proactive Scaling 视角的 behavior 配置。这里只补云侧认知两点：CPU/内存指标来自 metrics-server（ACK/EKS 托管集群默认装好，自建集群要手动装）；目标值设定要参考压测拐点（21 章的方法），拍 50% 还是 70% 应该有依据。

### 3.2 cluster-autoscaler：Node 层的传统形态

核心机制是**模拟调度**：有 Pod 一直 Pending → CA 按节点组的规格"试算"这些 Pod 放进去能不能调度成功 → 能则在对应节点组加节点。缩容方向同理：某节点上的 Pod 都能被挪走且低于水位阈值，节点进入"可回收"名单，默认观察约 10 分钟后排水移除。它是"节点组的调停者"——加减的粒度永远是你预先定义好的节点组（机型、池），不能凭空变出一台更合适的机器。

### 3.3 Karpenter：直接按 Pod 供给节点

Karpenter 把节点组扔掉了：直接监听 Pending Pod，**按这批 Pod 的实际需求（CPU/内存/GPU/拓扑/容忍度）实时挑机型**（NodePool 里允许的范围内），一次创建一台"刚好装下"的节点，还能合并碎片做整合（consolidation）。对 Spot 特别友好：机型列表放开后，某种库存不足自动换下一种，比"固定的 Spot 节点组"存活率高得多。EKS 上已是主流；ACK 侧对应能力以其官方组件文档为准。对比：

| 维度 | cluster-autoscaler | Karpenter |
|------|--------------------|-----------|
| 决策单位 | 节点组（预定义机型池） | 直接面向 Pending Pod 临时选型 |
| 机型选择 | 只能在组内选 | NodePool 约束内任选（含多架构/Spot 多样化） |
| 资源利用率 | 组规格固定，容易大材小用 | 按需 bin-packing，碎片少 |
| 侵入性 | 依赖云厂商集成（ASG/ESS） | 直接调云 API，无 ASG 层 |
| 心智负担 | 概念成熟、资料多 | 新抽象（NodePool/NodeClass） |

选型不是二选一的对错题：已有 ASG/ESS 运维体系、机型标准化程度高的团队用 CA 顺手；Spot 占比高、负载异构（大小 Pod 混跑）的集群 Karpenter 收益明显。

## 4. 定时伸缩：把可预测的曲线提前消化

流量有日常节律（白天高、夜间低、周报批处理）的负载，不必等指标越线再被动扩——**定时伸缩用确定性换响应速度**：

| 业务形态 | 方案 | 关键参数 |
|---------|------|---------|
| 白天 9~22 点高、夜间低 | ESS 定时任务 / ASG scheduled action：早 8:30 扩、晚 23:00 缩 | 幅度按历史曲线 7 天分位数留余量 |
| nightly CI（凌晨跑 2h） | 定时创建 Spot runner，跑完销毁 | 结合 01 章 §3 的计费选型 |
| K8s 侧周期容量 | cron-hpa 定时改 HPA 的 minReplicas（ACK 组件/开源 kubernetes-cronhpa-controller） | 只动 min，峰值仍由 HPA 接 |
| 大促/重保 | 手动 + 定时双保险，提前 1 天扩足 | 与第 15 模块冻结窗口联动 |

三个坑要写进方案：**时区**——云厂商定时规则默认 UTC 还是本地因产品而异，规则里显式带时区；**预热**——扩容要提前 15~30 分钟而不是准点：节点要启动 join、镜像要拉、缓存要热，准点扩容等于让第一批用户替你预热；**节假日曲线**——工作日模型在春节/大促会失真，日历事件要进伸缩计划的例外表。

## 5. 缩容保护：PDB、优雅终止与 Spot 回收

扩容失败损失的是"响应变慢"，缩容失误损失的是"在役实例被砍"——所以缩容需要一整组保护。先分清中断类型（PDB 的管辖边界，详见 [04-k8s-fundamentals/08 §7](../04-k8s-fundamentals/08-scheduling.md)）：

| 中断 | 例子 | PDB 管不管 |
|------|------|-----------|
| 自愿中断 | drain 驱逐、Spot 回收触发的排水、节点伸缩组缩容 | 管（Eviction API 放行前查 PDB） |
| 非自愿中断 | 宿主机宕机、内核 panic | 不管（靠副本冗余兜底） |
| 控制器缩容 | deployment `scale --replicas`、滚动更新 | **不管**（分别靠 minReplicas 与 maxUnavailable） |

### 5.1 优雅终止时序：preStop 与 terminationGracePeriodSeconds

```
Pod 收到删除 ──► 并行：① endpoints 控制器把它摘出 Service（异步，秒级传播）
                     ② preStop hook 执行（如 sleep 10 —— 等 ① 传播完）
                ──► 发 SIGTERM 给主进程（preStop 结束后）
                ──► 等进程退出，最长等 terminationGracePeriodSeconds
                ──► 超时 SIGKILL 强杀
```

`terminationGracePeriodSeconds` 必须大于 preStop 时长 + 进程真实排空时间，否则 sleep 还没结束就被 SIGKILL，保护归零。经验公式：`grace = preStop sleep + 应用最长请求超时 + 冗余`（如 10 + 30 + 5 ≈ 45s）。

### 5.2 Spot 回收：把"突然死"翻译成"有序退场"

```
回收通知（AWS Spot：提前 2 分钟事件；阿里云抢占式：回收前约 5 分钟，见 01 章 §3.2）
  ──► 节点排水：cordon + drain（eviction 尊重 PDB）
  ──► Pod 在别处重建（调度到按量/常备节点）
  ──► 2/5 分钟到点：实例被回收 —— 服务容量未受损
```

配套三件事：**通知处理器**（EKS 用 Node Termination Handler 或 Karpenter 内置响应；自建/ACK 用厂商事件驱动排水，以官方文档为准）把回收事件翻译成 drain；**PDB 兜底**——即使排水被 PDB 卡住（比如别处一时放不下），minAvailable 保证在役副本数不跌破底线；**分机型**——Spot 节点池/Karpenter NodePool 放开多机型，单一规格库存紧张时自动换，避免"集体同时被回收"。

### 5.3 缩容保护检查单

1. Deployment 已配 PDB（minAvailable 或 maxUnavailable，二选一）且副本数 > min。
2. preStop sleep ≥ endpoints 传播时间；terminationGracePeriodSeconds > preStop + 排空时间。
3. 入口层连接耗尽：SLB/ALB 的 deregistration delay ≥ 最长请求时间（01/02 章的 100.64.0.0/10 健康检查同链路）。
4. 有本地状态的负载（队列 consumer、批任务）先排空再退场：grace 期内处理完在途任务，或用 Job 的 completion 语义。
5. 缩容速率有上坡：HPA behavior 缩容策略（21/02 §5 的防抖配置）+ ASG/ESS 每次收缩比例上限，避免"水位一降全砍光、随后又全量扩回"的震荡。

## 实战演练

环境：kubeadm 单节点集群即可（演练 A/B），演练 C 是纸面设计。

### 演练 A：PDB 挡住一次 drain（10 分钟）

```bash
# [master] 部署 3 副本服务 + 一个"零中断容忍"的 PDB
kubectl create deployment web --image=docker.io/stefanprodan/podinfo:6.7.6 --replicas=3
kubectl set resources deploy/web --requests=cpu=10m,memory=16Mi
kubectl expose deploy/web --port=9898
kubectl apply -f - <<'EOF'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
spec:
  minAvailable: 3          # 故意设满：驱逐任何一个都会越线
  selector:
    matchLabels: { app: web }
EOF
kubectl get pods -l app=web -o wide
```

```bash
# [master] 模拟"节点要下线"（Spot 回收/缩容的第一步都是 drain）
kubectl drain $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') \
  --ignore-daemonsets --delete-emptydir-data --timeout=60s || true
```

预期输出包含 `error when evicting pods ... (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget`——**Eviction API 在放行前查了 PDB，排水被挡住**。这就是缩容保护的核心一环：任何走驱逐通道的下线（drain、Spot 回收排水）都要先过这道闸。恢复：`kubectl uncordon <node>` 后 `kubectl delete pdb web-pdb`。

### 演练 B：preStop 让缩容"零错误"（15 分钟）

```yaml
# [master] graceful.yaml —— 与 15 模块金丝雀实验同款手法：loadgen 持续打流量
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app
spec:
  replicas: 4
  selector:
    matchLabels: { app: app }
  template:
    metadata:
      labels: { app: app }
    spec:
      terminationGracePeriodSeconds: 20
      containers:
        - name: podinfo
          image: docker.io/stefanprodan/podinfo:6.7.6
          ports: [{ containerPort: 9898 }]
          readinessProbe: { httpGet: { path: /healthz, port: 9898 }, periodSeconds: 5 }
          lifecycle:
            preStop:
              exec: { command: ["sleep", "10"] }   # 等 endpoints 摘除传播
          resources: { requests: { cpu: 10m, memory: 16Mi }, limits: { memory: 64Mi } }
---
apiVersion: v1
kind: Service
metadata:
  name: app
spec:
  selector: { app: app }
  ports: [{ name: http, port: 9898 }]
```

```bash
# [master] 起一个常驻 probe Pod，先测基线 200 次，再缩容并测缩容窗口内 400 次
kubectl apply -f graceful.yaml && kubectl rollout status deploy/app
kubectl run probe --image=docker.io/busybox:1.36 -- \
  sh -c 'while true; do wget -q -O /dev/null http://app:9898/; done'
kubectl exec probe -- sh -c 'ok=0; bad=0; for i in $(seq 1 200); do wget -q -O /dev/null http://app:9898/ && ok=$((ok+1)) || bad=$((bad+1)); done; echo "before ok=$ok bad=$bad"'
kubectl scale deploy/app --replicas=1
kubectl exec probe -- sh -c 'ok=0; bad=0; for i in $(seq 1 400); do wget -q -O /dev/null http://app:9898/ && ok=$((ok+1)) || bad=$((bad+1)); done; echo "during ok=$ok bad=$bad"'
```

预期：带 preStop 时 during 的 `bad=0` 或个位数（endpoints 摘除在 sleep 窗口内完成，在途请求被排空）；对照组删掉 `lifecycle` 与 `terminationGracePeriodSeconds` 再跑一轮，`bad` 明显增加——**同样的缩容动作，差的只是摘流量与退出之间的先后顺序**。清理：`kubectl delete -f graceful.yaml && kubectl delete pod probe --grace-period=0 --force`。

### 演练 C：纸面设计——给一条业务曲线配三层伸缩（20 分钟）

业务画像：电商 API，工作日 10:00 与 20:00 双峰（峰值约为夜间 6 倍），周五晚发布窗口，预算允许 40% Spot。写出下表并互相评审（参数给依据）：

```text
层     工具与动作                            参数与依据
入口   SLB 规格按峰值×1.3 预留                依据压测拐点（21 章）
Pod    HPA：目标 CPU 60%，min/max = ?        min=夜间基线，max=峰值副本×余量
Node   Karpenter NodePool：Spot 机型≥5 种    混部比例 40%，回收兜底 PDB
定时   早 9:45 预扩（预热 15 分钟）          峰值前水位必须已就位
保护   PDB minAvailable=? / preStop=? / grace=?   按本节数字填
```

自检三问：双峰之间的午谷允许缩回去吗（缩容防抖设多久）？周五发布窗口与伸缩策略怎么互不打架（15 模块第 6 章）？Spot 全体被回收的最坏时刻，剩余容量还够承载多少流量？

## 常见坑

| 症状 | 原因 | 解法 |
|------|------|------|
| HPA 一扩容 Pod 就 Pending，几分钟后才恢复 | 只建了 HPA 没配 Node 层伸缩，或 CA 节点组无库存 | 三层一起设计；Pending 时先看 `kubectl describe pod` 的调度失败原因 |
| HPA 指标一直 `<unknown>` | metrics-server 没装/证书问题；Pod 没配 requests | 装 metrics-server（kubeadm 需 `--kubelet-insecure-tls`）；Resource 型指标依赖 requests 做分母 |
| 流量洪峰时伸缩"来不及" | 只靠被动指标触发，冷启动叠加（节点启动+镜像拉取+预热） | 定时/预测先行，指标兜底；镜像预热与 PDB 保护联动 |
| 定时扩容准点执行，用户仍感觉慢 | 节点 join 后还要拉镜像、热缓存，"就绪"≠"热身完成" | 提前 15~30 分钟扩；预热期跑真实流量回放 |
| drain 卡住不动 | PDB minAvailable 设得等于副本数（演练 A 的"故意"在生产就是事故） | minAvailable 留冗余（如 3 副本配 2）；监控 eviction blocked 事件 |
| preStop sleep 10 仍丢请求 | grace < preStop + 排空时间，或入口层 deregistration delay 太短 | 按第 5.1 节公式重算三层超时：Pod grace ≥ preStop+排空 ≥ 最长请求 |
| Spot 节点集中被回收，容量塌方 | 单一机型 Spot 库存紧张时集体回收，无兜底 | 机型多样化 + 按量兜底池 + PDB；监控 Spot 回收率换机型 |

## 自测

1. 为什么说"HPA 看 CPU、cluster-autoscaler 看 Pending Pod"是各司其职，而"用 CPU 水位去扩节点"通常更差？
<details><summary>答案</summary>

HPA 的本职是维持 Pod 水位（用户可感知的容量），CA 的本职是消除调度失败（资源供给侧）。用 CPU 水位扩节点的问题：节点 CPU 是许多 Pod 的混合均值，个别 Pod 水位高但节点整体不缺 CPU 时不会扩（漏判），反之空载节点上少量系统负载也可能误触；而 Pending Pod 是"资源确实不够"的确定性信号，无需再猜。信号离决策对象越近，链路越短越准——这也是分层伸缩的第一设计原则。
</details>

2. Karpenter 去掉了节点组，这个"减法"换来了什么、付出了什么？
<details><summary>答案</summary>

换来：机型实时选择（按 Pending Pod 的真实需求挑"刚好装下"的规格，碎片少）、Spot 多样化更容易（一个 NodePool 放开多种机型自动切换）、少维护一层 ASG/ESS 与 user-data。付出：云侧原有的伸缩组能力（健康检查自动替换、组级计费归集）不再按组呈现，排障从"看一组节点"变成"看一台台独立节点"；机型放得太宽时成本模型复杂化（要靠标签与预算策略收敛）；运维心智从成熟的 CA 生态切到新抽象。
</details>

3. PDB 挡不住 `kubectl scale --replicas=1`，也挡不住滚动更新——那缩容保护靠什么？
<details><summary>答案</summary>

PDB 只管辖走 Eviction API 的自愿中断（drain、Spot 回收排水）。控制器缩容的防线在别处：HPA behavior 的缩容策略（stabilization window + 每周期百分比上限）控制缩容速率；Deployment 滚动更新由 maxUnavailable/maxSurge 保证在役数量；deployment 侧的 minReplicas 与"禁止缩到 0"的策略守底线。一句话：**PDB 管"平台替你下线实例"，控制器参数管"你自己决定砍副本"**——两套闸门都要配。
</details>

4. Spot 回收提前 2 分钟通知（AWS），你的 Pod 光"优雅退出"就要 45 秒，来得及吗？整个链路要怎么排？
<details><summary>答案</summary>

来得及，但前提是排好序：通知到达（T+0）→ 处理器立即 cordon+drain（eviction 立刻开始，PDB 放行）→ Pod preStop 10s + 排空 30s ≈ T+45s 退出 → 剩余 75 秒是缓冲（排水排队、重建调度）。真正的风险不是单 Pod 退出时间，而是"重建去哪"：回收的节点上的 Pod 必须能调度到其他节点（按量兜底池/其他 Spot），且入口层已在更早时刻把它摘除。所以答案是链路三段都要预算时间，2 分钟里最贵的不是退出而是重建落位。
</details>

5. 定时伸缩规则设在"早 8:30 扩容"，为什么实际把 8:30 当成"开始准备"而不是"已经扩好"？
<details><summary>答案</summary>

从规则触发到"容量真正可用"有一串冷启动：云实例启动（分钟级）→ join 集群/就绪（分钟级）→ 拉镜像（取决于镜像大小与网络）→ 应用预热（JIT、缓存、连接池）。业务高峰 9:00 到来前这些必须全部完成，所以触发点要倒推：9:00 − 预热余量 15~30 分钟 = 8:30 触发只是保守起点；冷启动越慢（大镜像、跨 Region 拉取）越要提前，并用"预热期水位列"验证而非拍脑袋。
</details>

## 延伸阅读

- Kubernetes 官方 · Horizontal Pod Autoscaler（指标源与算法）：https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscaler/
- cluster-autoscaler 官方仓库（FAQ 覆盖绝大多数调参问题）：https://github.com/kubernetes/autoscaler/tree/master/cluster-autoscaler
- Karpenter 官方文档（NodePool/Spot/整合机制）：https://karpenter.sh/docs/
- AWS Auto Scaling 用户指南（目标追踪与缩容策略）：https://docs.aws.amazon.com/autoscaling/ec2/userguide/
- 阿里云弹性伸缩 ESS 文档（伸缩组/配置/规则）：https://www.alibabacloud.com/help/zh/ess/
- AWS Node Termination Handler（Spot 回收事件处理）：https://github.com/aws/aws-node-termination-handler
