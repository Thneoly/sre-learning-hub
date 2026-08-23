# 05 · 混沌工程：用可控的故障换取韧性

> 模块：13-sre-methodology ｜ 建议时长：5 小时 ｜ 关联认证：CKA-故障排除（实验环境即 kubeadm 集群）/ —（方法论无考点，高级岗面试高频）

## 学习目标

- 能解释稳态假设、爆炸半径、最小化影响三原则，并区分混沌工程与普通故障注入测试
- 能独立设计一次完整的混沌演练：稳态定义 → 假设 → 注入 → 验证 → 复盘
- 能在 kubeadm 集群上安装 Chaos Mesh，用 PodChaos/NetworkChaos 完成两类实验
- 能说出 ChaosBlade 的形态与适用场景，并给出与 Chaos Mesh 的选型建议
- 能列出生产落地混沌工程的六条护栏，并解释为什么"没有 SLI 就不该做混沌"

## 1. 原理：稳态假设、爆炸半径、最小化影响

### 1.1 定义与误区

混沌工程是在**生产或类生产系统上主动注入故障、观测系统响应**，以发现未知弱点、验证韧性假设的实验方法论。2011 年 Netflix 上云后推出 Chaos Monkey（随机杀生产实例），2015 年归纳出 Principles of Chaos。

要划清的边界：

| | 故障注入测试（FIT） | 混沌工程 |
|---|---------------------|----------|
| 问题形态 | "这个 bug 修了吗？"（已知预期） | "系统会怎么失效？我们不知道哪里会断" |
| 方法 | 断言式：注入 A，断言 B | 探索式：扰动系统，观测稳态是否守住 |
| 结果 | 通过/失败 | 新认知（常常发现预期之外的耦合故障） |

`scripts/faults/` 的 break 脚本本属"故障注入"——它是你学习的拐杖；本章要把它升级成有假设、有护栏、有结论的实验。

### 1.2 实验循环与三原则

```
   ┌──────────────────────────────────────────────────┐
   │ 1. 定义稳态：SLI 的正常水平（第 2 章的输出）      │
   │ 2. 提出假设：注入 X 后稳态仍能守住（因为机制 Y）   │
   │ 3. 圈定爆炸半径：只影响哪些 workload              │
   │ 4. 基线观测：注入前先量出正常波动                 │
   │ 5. 注入真实故障（可控、可中止）                   │
   │ 6. 对照观测：稳态守住了吗？哪里变形了？           │
   │ 7. 收敛半径/放大半径，回到 4 迭代；记录结论       │
   └──────────────────────────────────────────────────┘
```

- **稳态假设**（steady state hypothesis）：先有"系统正常时长什么样"的量化描述，才有"扰动后是否仍然正常"的判据。没有 SLI 的混沌是砸场子——你连"坏了没有"都无法判定。
- **爆炸半径**（blast radius）：故障影响面要有硬边界——namespace、label、节点、实例百分比。半径按阶梯放大：单 Pod → 单 Deployment → 单节点 → 控制面 → 可用区。
- **最小化影响**：用能得出结论的最小剂量做实验；必须有**一键 abort**（删除实验对象即恢复）和自动到期（duration）；生产演练要避开业务高峰并设冻结期。

### 1.3 稳态假设的写法模板

```text
<!-- 撰写于实验计划文档（git 版本化），每个实验一份 -->
在 <SLI> 处于 <水平> 的稳态下，
注入 <故障>（爆炸半径 = <范围>），
预期 <SLI 在 SLO 内保持/在 X 分钟内恢复>，
因为 <系统的韧性机制>。
若预期不成立，说明 <韧性机制失效/缺失>，产出行动项。
```

实例（本章实战演练会验证它）：

> 在 podinfo 服务"5 分钟非错误响应占比 = 100%、响应时间 < 100ms"的稳态下，注入"每分钟杀死一个 Pod"（爆炸半径 = default ns 中 app=podinfo 的一个实例），预期可用性仍 ≥ 99%，因为 Deployment 副本冗余 + Service 端点摘除会让流量在存活副本间继续。若可用性跌破 99%，说明冗余/摘除机制存在问题（如 readinessProbe 缺失导致流量打到未就绪 Pod）。

## 2. 演练流程设计

九步流程，缺第 1、3、7 步的"演练"都是事故：

| 步 | 动作 | 产出物 |
|----|------|--------|
| 1 | 选场景：从近期复盘/top 风险清单挑（不是随手注入） | 实验目标 |
| 2 | 写稳态假设（1.3 模板） | 假设文档 |
| 3 | 定护栏：爆炸半径、abort 方式、超时、冻结条件 | 护栏清单 |
| 4 | 拍快照/确认回滚路径（VMware snapshot、`--restore`） | 回滚预案 |
| 5 | 基线观测：注入前量 2~5 分钟稳态 | 基线数据 |
| 6 | 注入并持续观测（不离开屏幕） | 实验数据 |
| 7 | 中止条件检查：SLI 跌破阈值/出现计划外影响 → 立即 abort | 决策记录 |
| 8 | 解除注入，验证系统回到稳态 | 恢复确认 |
| 9 | 复盘：结论 + 行动项（第 4 章模板） | postmortem/实验报告 |

组织形态上叫 **GameDay**：一组人操作、一组人只观测记分（稳态守住几个指标、MTTR 多少），规则与计分卡事先公开。演练节奏建议：每季度一次全组 GameDay，每周一次个人小实验（靶场 15 分钟循环）。

## 3. 工具：Chaos Mesh 与 ChaosBlade

### 3.1 Chaos Mesh（CNCF 孵化项目，K8s 原生）

一切实验都是 CRD，可 git 版本化、可被 Workflow 编排：

| CRD | 能力 |
|-----|------|
| PodChaos | pod-kill（杀 Pod）/ pod-failure（Pod 持续 NotReady）/ container-kill |
| NetworkChaos | delay / loss / duplicate / corrupt / partition（网络分区） |
| StressChaos | CPU / 内存压力 |
| IOChaos | 磁盘 IO 延迟、错误 |
| TimeChaos | 时钟偏移 |
| DNSChaos | DNS 解析错误/延迟 |
| HTTPChaos | HTTP 中断/延迟/状态码篡改 |
| Schedule / Workflow | 定时与多步编排（串行/并行/条件分支） |

### 3.2 ChaosBlade（阿里巴巴开源，CLI 优先）

同样的故障域，交互形态不同：`blade create <场景>` 即时生效、`blade destroy` 恢复，也提供 Operator 把实验写成 `ChaosBlade` CRD。亮点是**主机层实验**（进程 CPU、网卡、磁盘、文件系统）不依赖 K8s，混合环境（VM + 容器）一套工具通吃，官方中文文档完善。

### 3.3 选型对照

| 维度 | Chaos Mesh | ChaosBlade |
|------|-----------|------------|
| 形态 | CRD + Workflow + Dashboard | CLI + CRD 双形态 |
| K8s 场景丰富度 | 全（含 HTTP、时钟、IO） | 全（偏经典资源故障） |
| 主机/VM 层 | 弱（需额外方案） | 强（进程/磁盘/网络设备级） |
| 编排 | Workflow 原生（多步、串并行） | 单实验为主，复杂编排靠外部调度 |
| 上手曲线 | 需理解 CRD 与 selector | 一条命令见效果 |
| 适用 | 深耕 K8s 的平台团队 | 混合环境、快速验证、中文团队 |

练习集群是纯 kubeadm K8s，本章实战用 Chaos Mesh 做应用层实验，靶场 break 脚本覆盖平台层故障，两者互补。

## 4. 与 scripts/faults 靶场打通：注入 → 观测 → 验证稳态 → 复盘

靶场的 12 个 break 脚本是现成的"平台层混沌原语"，套上本章流程就是完整演练：

| 阶段 | 动作 | 具体命令/工具 |
|------|------|---------------|
| 注入 | 选一个与假设相关的故障，记录 T0 | `sudo bash scripts/faults/break-cni.sh`（新 Pod 起不来）/ `break-kubelet.sh`（节点 NotReady）等 |
| 观测 | 看第 2 章的 SLI 与燃烧率是否变形 | Prometheus UI：`slo:grafana:avail_ratio_10m`；业务侧 http 探测 |
| 验证稳态 | 按假设检查：稳态守住了吗？多久恢复？ | curl 探测循环、`kubectl get pods -A` 对照预期 |
| 复盘 | 时间线 + 结论 + 行动项 | 第 4 章 postmortem 模板；对照 `FIXES.md` 验证你的排障路径 |

示例假设（可直接做）："在集群稳态下注入 `break-coredns.sh`（CoreDNS 上游被改坏），预期**已建立的 Service 访问不受影响**（kube-proxy 与已有连接不依赖新建 DNS 查询），但**新建跨服务调用会在缓存过期后失败**——爆炸半径 = 依赖新 DNS 解析的流量。"注入后逐项验证两条预测，这比"挂了然后修好"多产出一个架构事实。

## 5. 生产落地护栏

把靶场习惯带进生产前，六条护栏逐条过：

1. **监控先行**：目标系统必须有 SLI 与告警（第 2 章）。混沌实验的第一观众是监控，不是人眼。
2. **审批与窗口**：变更单流程走起，演练窗口避开高峰与大促冻结期；爆炸半径写进审批单。
3. **半径递增**：新实验从"单实例、1 分钟"起步，同场景至少成功三次才放大半径。
4. **一键 abort + 自动到期**：删除 CR 即恢复；每个实验必带 `duration`；值守者有权不经讨论直接中止。
5. **预算保护**：错误预算剩余 < 25% 时暂停混沌（第 2 章 4.2 节同一条止损规则的延伸）——预算快烧穿还注入故障，等于自纵火。
6. **先 staging 后生产**：staging 无法复现的（真实数据量、真实依赖拓扑）才进生产，且生产首轮只跑最小剂量。

## 实战演练：在练习集群上完成一次闭环混沌实验

环境：kubeadm 单 master 集群（`scripts/setup/kubeadm-single-node.sh`）。全程约 40 分钟。

### Step 1 前置：快照 + 组件检查

```text
# [本地Windows] VMware：先给 VM 打快照 "before-chaos-lab"（scripts/README.md 的快照策略）
```

```bash
# [master] 集群健康基线
kubectl get nodes
kubectl -n kube-system get pods | grep -v Running || echo "组件全部 Running"
```

### Step 2 安装 Chaos Mesh

```bash
# [master] 官方 chart 安装（版本细节以 chaos-mesh.org/docs 为准）
helm repo add chaos-mesh https://charts.chaos-mesh.org
helm repo update
kubectl create ns chaos-testing
helm install chaos-mesh chaos-mesh/chaos-mesh -n chaos-testing \
  --set chaosDaemon.runtime=containerd \
  --set chaosDaemon.socketPath=/run/containerd/containerd.sock
kubectl -n chaos-testing get pods
```

预期：chaos-controller-manager、chaos-daemon、chaos-dashboard 全部 Running。daemon 起不来时优先怀疑 runtime/socketPath 与本机 containerd 不符（`ls /run/containerd/containerd.sock` 验证）。

### Step 3 部署被测系统与探测器

```yaml
# [master] podinfo.yaml —— 被测系统：2 副本无状态服务
apiVersion: apps/v1
kind: Deployment
metadata:
  name: podinfo
  labels:
    app: podinfo
spec:
  replicas: 2
  selector:
    matchLabels:
      app: podinfo
  template:
    metadata:
      labels:
        app: podinfo
    spec:
      containers:
        - name: podinfo
          image: docker.io/stefanprodan/podinfo:6.7.6
          ports:
            - containerPort: 9898
          readinessProbe:
            httpGet:
              path: /
              port: 9898
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            requests: { cpu: 10m, memory: 16Mi }
            limits:   { memory: 64Mi }
---
apiVersion: v1
kind: Service
metadata:
  name: podinfo
  labels:
    app: podinfo
spec:
  selector:
    app: podinfo
  ports:
    - name: http
      port: 9898
      targetPort: 9898
```

```yaml
# [master] probe.yaml —— SLI 采集器：每秒一次记录状态码与耗时
apiVersion: v1
kind: Pod
metadata:
  name: probe
  labels:
    app: probe
spec:
  restartPolicy: Never
  containers:
    - name: probe
      image: curlimages/curl:8.10.1
      command: ["sh", "-c"]
      args:
        - |
          i=0
          while [ "$i" -lt 1800 ]; do
            out="$(curl -s -o /dev/null -w '%{http_code} %{time_total}' --max-time 3 http://podinfo:9898/)"
            echo "$(date +%T) ${out:-000 3.000}"
            i=$((i+1))
            sleep 1
          done
```

```bash
# [master] 应用并等待就绪（国内网络拉不动镜像时按 scripts/README.md 配代理或 DOCKER_MIRROR）
kubectl apply -f podinfo.yaml
kubectl apply -f probe.yaml
kubectl rollout status deployment/podinfo --timeout=120s
```

### Step 4 基线观测（稳态测量）

```bash
# [master] 等 2 分钟后统计基线
kubectl logs pod/probe | awk '{t++; if($2==200) ok++} END{printf "samples=%d ok=%d avail=%.2f%%\n", t, ok, ok*100/t}'
kubectl logs pod/probe | awk '{s=$3+0; if(s<0.1)a++; else if(s<0.3)b++; else c++} END{printf "<100ms:%d  100-300ms:%d  >300ms:%d\n",a,b,c}'
```

预期基线（稳态）：`avail=100.00%`，全部样本落在 `<100ms` 桶。把这两个数字写进假设文档——它们就是本实验的稳态定义。

### Step 5 实验一：NetworkChaos（网络延迟）

假设：注入 200ms 网络延迟（半径 = podinfo 全部 Pod 的出口流量），预期可用性仍 100%、延迟分桶整体移到 100–300ms 档。

```yaml
# [master] net-delay-podinfo.yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: NetworkChaos
metadata:
  name: net-delay-podinfo
  namespace: chaos-testing
spec:
  action: delay
  mode: all
  selector:
    namespaces:
      - default
    labelSelectors:
      app: podinfo
  delay:
    latency: "200ms"
    correlation: "0"
    jitter: "10ms"
  duration: "3m"
```

```bash
# [master] 注入 → 3 分钟后自动解除；期间统计两次看变化
kubectl apply -f net-delay-podinfo.yaml
sleep 90
kubectl logs pod/probe | awk '{t++; if($2==200) ok++} END{printf "samples=%d avail=%.2f%%\n", t, ok*100/t}'
kubectl logs pod/probe | awk '{s=$3+0; if(s<0.1)a++; else if(s<0.3)b++; else c++} END{printf "<100ms:%d  100-300ms:%d  >300ms:%d\n",a,b,c}'
```

预期：可用性仍 100%，100–300ms 桶样本明显增加（延迟来自 Pod 出口，curl 测的是客户端视角往返）。要提前中止：`kubectl -n chaos-testing delete networkchaos net-delay-podinfo`。

### Step 6 实验二：PodChaos（周期性杀 Pod）

假设即 1.3 节实例：每分钟杀一个 Pod，可用性 ≥ 99%。

```yaml
# [master] pod-kill-podinfo.yaml
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: pod-kill-podinfo
  namespace: chaos-testing
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces:
      - default
    labelSelectors:
      app: podinfo
  scheduler:
    cron: "@every 1m"
```

```bash
# [master] 注入，观察 5 分钟（约 5 次杀 Pod），期间盯副本与端点
kubectl apply -f pod-kill-podinfo.yaml
watch -n 5 'kubectl get pods -l app=podinfo; kubectl get endpoints podinfo'
```

另一个终端持续统计：

```bash
# [master] 每 60 秒滚动输出可用性（时间戳用 shell 的 date，不依赖 awk 的 strftime）
for i in 1 2 3 4 5; do
  printf '%s ' "$(date +%T)"
  kubectl logs pod/probe | tail -60 | awk '{t++; if($2==200) ok++} END{printf "avail=%.2f%%\n", ok*100/t}'
  sleep 60
done
```

判定：5 分钟窗口 avail ≥ 99% → 假设成立，冗余机制有效；明显跌破 → 检查 readinessProbe 与 endpoints 摘除延迟（这本身就是高价值结论）。

### Step 7 解除与清理

```bash
# [master] 删除实验对象即 abort；随后清场
kubectl -n chaos-testing delete podchaos pod-kill-podinfo
kubectl -n chaos-testing delete networkchaos --all
kubectl delete -f probe.yaml
kubectl delete -f podinfo.yaml
kubectl -n chaos-testing get podchaos,networkchaos 2>/dev/null || echo "实验对象已清空"
# 不再练习时整体卸载：helm uninstall chaos-mesh -n chaos-testing && kubectl delete ns chaos-testing
```

### Step 8 复盘

用第 4 章模板写实验报告（把"影响"换成"假设验证结果"）：两个实验各记一条结论与一条行动项。示例行动项："PodChaos 实验中 avail 最低 98.7%，出现在杀 Pod 后约 8 秒——为 podinfo 加 PodDisruptionBudget 与 preStop sleep 2s，owner/期限/验证命令三要素写全再关单。"至此你完成了本书方法论篇的完整闭环：SLO 定价（02）→ 事件响应（03）→ 复盘沉淀（04）→ 主动验证（05）。

## 常见坑

| 症状 | 原因 | 解法 |
|------|------|------|
| 注入后"什么都没发生" | selector 没匹配到 Pod（label/ns 写错） | 注入前先 `kubectl get pods -l <selector> -n <ns>` 验证半径非空 |
| chaos-daemon 起不来 | runtime/socketPath 与节点容器运行时不符 | `ls /run/containerd/containerd.sock` 核对，docker 则改 runtime=docker 及对应 socket |
| 杀的是 kube-system 的 Pod | selector 用了过宽的 namespaces/label | 护栏：爆炸半径先写成显式 labelSelectors，禁止只用 namespace 圈定 |
| 实验做完集群"还坏着" | CR 未删干净或 duration 未设 | 每个实验带 duration；收尾 `kubectl -n chaos-testing get podchaos,networkchaos` 确认为空 |
| 结论"系统挺稳的"却说不稳在哪 | 没写稳态假设，注入前后没有对照数据 | 先跑 Step 4 基线；假设文档不合格不注入 |
| 生产演练当天正好故障 | 无冻结期与预算检查 | 第 5 节护栏 2、5：审批窗口 + 错误预算 < 25% 即暂停 |
| 演练结论没有下文 | 复盘缺行动项跟踪 | 用第 4 章模板与 tracker，行动项三要素齐全 |

## 自测

<details><summary>1. 为什么说"没有 SLI 就不该做混沌工程"？</summary>

混沌实验的输出是"稳态是否守住"，稳态必须先被量化定义——这就是 SLI。没有 SLI 时只有两种结局：凭感觉说"好像没坏"（无法判定实验结果），或者拿用户投诉当探测器（实验变成了真实事故）。这也解释了本章在课程顺序上放在第 2 章之后：SLO 体系是混沌工程的前置依赖，不是并列选项。
</details>

<details><summary>2. 爆炸半径为什么必须显式声明（label/百分比），而不是"整个 namespace 都是我的实验对象"？</summary>

半径是实验的对照变量与安全边界。只按 namespace 圈定时：(1) 系统组件（如 kube-system 里的 CNI/DNS）可能被卷进来，实验同时扰动多个变量，结论不可归因；(2) 影响面随 namespace 内容漂移而失控——今天 ns 里 5 个 Pod，明天 50 个。显式 label + 百分比让每次实验的扰动强度可复现、可审计、可中止，这是"科学实验"与"制造事故"的分界线。
</details>

<details><summary>3. NetworkChaos 实验里延迟加在 podinfo Pod 的出口，curl 探测看到的是往返延迟。若想单独验证"入口方向"的抗压能力，实验该怎么改？</summary>

把注入对象换成客户端侧：selector 圈定 probe（或真实的接入层），对 probe 的出口流量注入 delay/loss，这样 podinfo 收到的请求已经带扰动，测的是服务端在"慢客户端/坏网络"下的行为（超时、队列、连接堆积）。Chaos Mesh 的 NetworkChaos 支持 direction 与 target 组合做定向注入；若两侧同注入，注意延迟会叠加，先单侧再双侧，半径递增原则同样适用于方向维度。
</details>

<details><summary>4. PodChaos 实验里 avail 跌到 98.7%，这个"失败"的实验有价值吗？</summary>

有，且常常比成功实验更有价值：它证实了冗余机制存在缺口（endpoint 摘除/就绪探测的秒级窗口），并给出了量化缺口（杀 Pod 后约 8 秒服务能力下降）。行动项随之明确：PDB、preStop、更快的 readinessProbe。混沌工程的目标本来就不是"证明系统稳"，而是用最小代价找到不稳的证据；把预期外的结果当成发现而不是事故，是这项方法论的基本态度（也与第 4 章 blameless 一脉相承）。
</details>

<details><summary>5. 团队想在生产引入 Chaos Mesh，领导问"会不会把生产搞挂"。你的完整回答框架是什么？</summary>

分三层。风险层：承认存在残余风险，但用护栏压缩它——半径从单实例起步、每实验带 duration 与一键 abort、值守者可无讨论中止、冻结期与错误预算联动（预算 < 25% 不演练）。收益层：故障在生产必然发生（变更、硬件、依赖），主动小剂量注入让我们在可控时间、可控半径内预演，比"等真实故障来教我们"便宜得多；Netflix/阿里等大规模实践可作参照。落地层：先 staging 三个月、SLI 齐备后再上生产、首轮只跑最小剂量、每次实验产出复盘与行动项——给出可审计的推进计划，而不是热情。
</details>

## 靶场联动：靶场是这些方法论的练习场

本模块五章到此闭环，靶场（`scripts/faults/`）是贯穿五章的练习场：第 1 章把每次手工排障记进 toil 账本；第 2 章把 break 脚本当"预算燃烧发生器"验证 SLI 与燃烧率告警；第 3 章拿它做 20 分钟事件推演练角色分工；第 4 章把排障过程沉淀成 runbook 与 postmortem；本章再为它加上稳态假设与护栏，升级为可控实验。建议的周常：每周抽 30 分钟，随机一个 break 脚本 + 一张第 5 节的护栏清单 + 第 4 章的报告模板，走完"注入 → 观测 → 验证稳态 → 复盘"四拍——面试里被问"你们怎么做稳定性保障"时，你手里有的是跑过很多遍的流程，而不是背下来的名词。

## 延伸阅读

- Principles of Chaos（混沌工程原则原文）：https://principlesofchaos.org/
- Chaos Mesh 官方文档（安装与各 CRD 字段）：https://chaos-mesh.org/docs/
- Chaos Mesh GitHub 仓库：https://github.com/chaos-mesh/chaos-mesh
- ChaosBlade GitHub 仓库（含中文文档）：https://github.com/chaosblade-io/chaosblade
- Netflix Chaos Monkey：https://github.com/Netflix/chaosmonkey
