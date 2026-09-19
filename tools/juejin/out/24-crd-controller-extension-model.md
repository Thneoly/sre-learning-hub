---
title_juejin: 装完 CRD 集群毫无反应？K8s 扩展模型是个套娃
title_zhihu: 装完 CRD 集群毫无反应？K8s 扩展模型是个套娃
description: CRD加名词，控制器加动词，Operator是打包。讲透level-triggered控制环、Reconcile幂等、schema剪枝、ServiceMonitor链路，何时不该写Operator。
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686346277555683378"
---

# 装完 CRD，集群毫无反应：K8s 扩展是个套娃，你只拿到了一半

> CRD + 控制器：K8s 扩展模型｜K8s 深入理解

第一次玩 CRD 的人，几乎都经历过同一个时刻：`kubectl apply` 完一个 CustomResourceDefinition，返回 `created`，然后——什么都没发生。不报错、不干活、status 永远是空的。

更早入坑的那批人，则在 Operator 上撞过另一堵墙：Reconcile 明明写对了，日志却无限刷屏，同一个对象一分钟被调谐几十次。

这两个现象是同一个根源。K8s 的扩展模型是个套娃：**CRD 和控制器是解耦的两半**，apply CRD 只是把一个"名词"登记进 apiserver，"动词"从来不会随 CRD 附赠。今天把这只套娃逐层拧开，讲五件事：控制环、幂等、schema 校验、ServiceMonitor 真实链路，以及——什么时候不该写 Operator。读完能带走：一张控制环骨架图、一套可直接复制执行的验证命令、一张"该不该写 Operator"的判断表。

## 全景：四个扩展点，各改请求链的一段

先回忆 apiserver 的写请求链：认证 → 鉴权 → 变更准入（mutating）→ 对象 schema 校验 → 验证准入（validating）→ 落 etcd。注意准入拆成两道：mutating 在校验前改对象（含内置默认值填充），validating（ValidatingWebhook / CEL 策略）在校验后拒绝。想让集群"原生理解"一个新东西，K8s 给的不是插件槽，而是链条上四段可以各自挂载的位置：

| 扩展点 | 改哪一段 | 一句话分工 |
| --- | --- | --- |
| CRD | 对象层：登记新类型 | 加"名词" |
| 自定义控制器 | 控制器层：list-watch 并调谐 | 加"动词" |
| 聚合 API | 读路径：整个 group 交给外部进程 serve | 换掉一整本词典 |
| 准入扩展 | 写路径进门检查 | 管"做成什么样" |

Operator 不是第五种扩展点，官方口径很朴素：用 CRD 管理复杂有状态应用的软件，控制器把人类运维的知识编码了进去。拆开是三件套——CRD 描述"应用期望长什么样"（版本、副本、备份策略），控制器把部署、扩缩容、failover、备份、升级变成 reconcile 里的分支，交付则把 CRD 清单和控制器 Deployment 打包成 Helm chart，装完即得。本文主角就是它。

聚合 API 为什么存在？因为 metrics.k8s.io 这种"数据是派生的、易变的瞬时值"不适合走 CRD 落 etcd，那是另一个故事，这里按下不表。

这张表也解释了一个常见困惑：为什么有人把"注入 sidecar"叫扩展 K8s，有人把"写个 Operator"叫扩展 K8s——他们改的是链条上不同的段，不冲突。

## CRD 只是名词：但注册完，免费送一整套 API 待遇

CRD（CustomResourceDefinition）描述"一种新对象长什么样"；照着它创建出来的实例叫 CR（Custom Resource）。注册之后，etcd 存储、REST 端点、RBAC、label/annotation、finalizer、ownerReferences、`kubectl get/explain` 全部自动获得——这就是"K8s 原生"的含义。

一段可直接跑的完整演示：

```bash
kubectl apply -f - <<'EOF'
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: maintenancewindows.ops.example.com   # 固定格式：<复数>.<group>
spec:
  group: ops.example.com
  scope: Namespaced
  names:
    plural: maintenancewindows
    kind: MaintenanceWindow
    shortNames: ["mw"]
  versions:
  - name: v1
    served: true
    storage: true                            # 多版本并存只能有一个 storage 版本
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              windowStart:
                type: string
              mode:
                type: string
                enum: ["drain", "cordon-only"]  # 值域校验
                default: "drain"
              nodes:
                type: array
                items:
                  type: string
            required: ["windowStart"]
    subresources:
      status: {}                             # spec/status 分离读写
EOF
# 注册立刻生效，不需要重启任何组件
kubectl wait --for=condition=Established crd/maintenancewindows.ops.example.com --timeout=30s
```

建一个实例，然后看它的 status：

```bash
kubectl apply -f - <<'EOF'
apiVersion: ops.example.com/v1
kind: MaintenanceWindow
metadata:
  name: kernel-patch-0919
spec:
  windowStart: "2026-09-19T22:00:00+08:00"
  nodes: ["worker1"]
EOF
kubectl get mw kernel-patch-0919 -o jsonpath='{.status}'; echo
# 输出：空 —— 数据进了 etcd，但没有任何控制器写 status
```

此刻**没有任何控制器认识它**。对象安静地躺在 etcd 里，status 恒为空。数据模型（CRD）与自动化逻辑（控制器）是解耦的两半——这就是"装了 Gateway API 的 CRD，还要再装 Envoy Gateway 实现"的原因：GatewayClass 需要一个控制器来认领。

顺带两句。CR 沿用 K8s 的三套通用机制：generation/observedGeneration（控制器把它抄进 status，外界才能判断"期望到达了吗"）、finalizer、ownerReferences（CR 作属主，级联删除自动完成）。另外自定义资源同样要配 RBAC——Role 里 apiGroups 填你的 group，新类型不免检。

## schema：说了算的留下，没说的静默剪掉

CRD 的 openAPIV3Schema 不只是文档，它是 apiserver 里的执法者：

| 机制 | 行为 | 什么时候关心 |
| --- | --- | --- |
| 字段剪枝（pruning） | schema 未声明的字段直接丢弃，默认剪掉不报错（kubectl patch / Helm 等走 PATCH 的路径；kubectl ≥1.25 的 apply 默认 strict 校验，会直接报 Unknown field） | "apply 的字段怎么不见了"几乎都栽这 |
| x-kubernetes-preserve-unknown-fields | 子树声明 true 后不再剪枝该子树 | 想原样透传一段任意结构给控制器 |
| x-kubernetes-validations | 字段上写 CEL 表达式，违反直接拒 | 字段间约束，比 webhook 便宜 |

肉眼验证，接着上一节的 CR：

```bash
kubectl patch mw kernel-patch-0919 --type=merge -p '{"spec":{"owner":"sre-a"}}'
kubectl get mw kernel-patch-0919 -o jsonpath='{.spec.owner}'; echo
# 输出：空 —— PATCH 请求默认不校验未知字段（fieldValidation=Ignore），owner 被静默剪除
# 注意：kubectl ≥1.25 的 apply 默认 strict 校验（server 端 ServerSideFieldValidation，v1.27 起 GA），
# 同样的字段会直接报 "Unknown field" 错。"静默剪掉"发生在 patch / --validate=ignore 或 warn / Helm 等
# 以 PATCH 提交的路径上
kubectl patch mw kernel-patch-0919 --type=merge -p '{"spec":{"mode":"reboot"}}'
# 报错：spec.mode: Unsupported value: "reboot": supported values: "drain", "cordon-only"
```

字段间约束用 CEL，直接写在 schema 里（片段）：

```yaml
              duration:
                type: string
                x-kubernetes-validations:
                - rule: "self == '2h' || self == '4h'"
                  message: "duration 只允许 2h 或 4h"
```

两条工程纪律。其一，**CRD 不是数据库**：对象最终存进 etcd，单次请求约 1.5 MiB 是硬上限，把日志、批次数据塞进 CR 是最常见的滥用——大块数据走专用存储，CR 只放期望状态。

其二，正经项目别手写 schema。kubebuilder 从 Go 类型生成 CRD：json tag 是 schema 的直接来源，`//+kubebuilder:` 注释（markers）声明 status 子资源、RBAC、打印列，三条命令闭环：

```bash
make manifests    # Go 类型 + markers → CRD 与 RBAC 清单
make install      # 把 CRD apply 进集群
make run          # 本地跑控制器进程，连上集群，日志直接可见
```

字段改名或删掉时编译器立刻报错；手写 YAML 的剪枝是静默的，排查极难。

## 控制环：declarative + level-triggered，一对拆不开的搭档

你写的控制器与 kube-controller-manager 里几十个内置循环是同构的，骨架就四步：

```text
① observe: list-watch CR 与相关对象，Informer 本地缓存兜底
② diff:    期望（CR.spec）与实际有差距吗？没有就退出本轮
③ act:     补差值 —— cordon/drain 同样走 Eviction API，照样尊重 PDB
④ requeue: 固定周期 / 相关事件到来时重新进入循环
```

两个必须内化的词：

| 术语 | 含义 | 工程后果 |
| --- | --- | --- |
| declarative 声明式 | 用户只写"想要什么"（spec），从不写"怎么做" | 控制器可随时被杀掉重启，重启后对比期望与实际就能续上，不存在"脚本执行到一半"的悬空状态 |
| level-triggered 电平触发 | 每轮处理"当前全量状态"，不依赖"恰好收到某次事件" | 丢事件无害，下一轮重算差值自然补上；代价是循环必须幂等 |

对照脚本思维最清楚：**脚本问"发生了什么"，Reconcile 问"现在该是什么样"**。

为什么必须幂等？因为事件是 edge 语义：会丢（watch 断线重连缝隙里发生的增删改，全部丢失且无从感知）、会重（至少一次投递）、会乱序。Informer 还有个兜底设计叫 resync——定期把缓存对象重推一遍回调，专门对付"事件丢了、处理器出错了"。

用 controller-runtime 的话说，事件先进 workqueue（按 key 去重、限速、指数退避）再进你的 Reconcile；同一 key 同时只有一个 Reconcile 在跑，不用对自己加锁——但重复调谐躲不掉。`Reconcile(ctx, req) (Result, error)` 这个签名本身就是三条铁律：

| 铁律 | 含义 |
| --- | --- |
| req 只有名字 | 拿 namespace/name 自己 Get 最新对象，不假设"为什么被触发" |
| 返回值三态 | 返回 error 走指数退避重试；返回 RequeueAfter 做周期对账；全空则本轮结束 |
| 幂等 | 同一对象跑 N 次结果一致，重复调谐是常态 |

第一行值得多嚼几下：为什么传名字而不传事件对象？因为对象名是 level 的锚点——拿着名字 Get 一次，永远拿到当前真相；若直接传事件，控制器的正确性就依赖"我没错过任何事件"这个不成立的前提。Cache 断线重连对 Reconcile 完全透明，恢复后涌来的一批调谐，恰好是 level-triggered 不怕的形态。

由此得到写代码前就要接受的推论：**reconcile 会被并发地、重复地调用；一切外部动作都要能安全地做第二遍**。写"确保 DaemonSet 存在"，不要写"创建 DaemonSet"；重启数据库、调云 API、cordon 节点，都要经得起跑两遍。

违反幂等最经典的现场是 status 死循环，事件链长这样：

```text
Reconcile 无条件写 status → resourceVersion 变化 → informer 收到 Update 事件
→ 同一 key 再入队 → 再写 status → 无限循环
```

表现为日志刷屏、apiserver 写 QPS 异常。解法一句话：status 只在值变化时写；必要时再在事件入口加 predicates，过滤掉纯 status 变化的事件。

## 套娃的真相：你的输出，是内置控制器的输入

现在可以回答"套娃"套在哪了。假设你写了个 CronTab Operator，把 CR 调谐成 CronJob——故事没完，反而刚刚开始：

```text
CronTab(CR) ──你的控制器──► CronJob ──内置控制器──► Job ──► Pod ──kubelet──► 容器
```

你的控制器不直接创造现实，它创建的是**内置对象**，交给内置控制器继续调谐；内置控制器再创建 Pod，交给 kubelet 执行。每一层的输出都是下一层的输入，每一层都是同一个"期望 vs 实际"的环。

整个 K8s 就是一组同构控制环的递归嵌套，扩展模型只是允许你在最外层再包一层——所谓扩展 K8s，全部真相就是"注册一对新 API + 新控制循环"，没有更多魔法。

两个直接推论：

- **Operator 不是 apiserver 的插件**。它就是用 client-go 机制 watch 集群的普通进程，跑在 Deployment 里。挂了只影响"没人调谐 CR"，集群本身无恙。
- **删除路径基本不用写**。子资源带 ownerReferences，级联回收外包给 garbage collector。只有清理集群外资源（云盘、外部 DNS 记录）才需要 finalizer——而"卸载 Operator 后 CR 卡在 Terminating"，就是控制器加了 finalizer 后自己没了、没人摘。另外，删 CRD 会级联删光该类型所有 CR，不可恢复，当高危操作管好权限。

finalizer 卡删除可以亲手复现，就用前面的 MaintenanceWindow：

```bash
kubectl patch mw kernel-patch-0919 --type=merge -p '{"metadata":{"finalizers":["ops.example.com/cleanup"]}}'
kubectl delete mw kernel-patch-0919 &
sleep 3; kubectl get mw
# kernel-patch-0919 仍在 —— deletionTimestamp 已打，但 finalizer 没人摘
kubectl patch mw kernel-patch-0919 --type=merge -p '{"metadata":{"finalizers":null}}'
# 这条一执行，对象立即真正消失
```

## ServiceMonitor：一条真实链路把前面全串起来

装 kube-prometheus-stack 会带来一组 CRD，最常打交道的是 ServiceMonitor——声明"照 label 找 Service，抓它背后的 Pod"：

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: web-sm
  labels:
    release: prom        # 必须被 Prometheus CR 的 serviceMonitorSelector 选中
spec:
  selector:
    matchLabels:
      app: web           # 圈定要抓取的 Service
  endpoints:
  - port: http           # 对应 Service 的 port 名
```

YAML 里那行注释是整条链最脆的一环：Prometheus CR 用 serviceMonitorSelector 挑选 ServiceMonitor，label 对不上，后面环节全白搭——下文排障三连的第二步查的就是它。

从 apply 到抓取生效，是一条标准控制环：

```text
你 apply ServiceMonitor ──► Prometheus Operator watch 到它
  ──► diff: 这条 SM 体现在抓取配置里了吗？
  ──► act: 重新生成抓取配置并触发热加载
  ──► Prometheus 按 selector 找 Service → Endpoints → Pod, 开抓 /metrics
  （新 Pod 上线下线 Operator 不用动 —— 目标列表由发现机制自动维护）
```

注意最后一行括号，这是声明式的红利：Operator 只负责把"声明"翻译成"配置"，目标集合的动态维护交给了 Prometheus 自己的发现机制——又一层套娃。没人手改 prometheus.yml，全是 CR 驱动。

同构的例子还有 cert-manager，换个领域你就能举一反三：Certificate 描述"我要一张什么证书、存进哪个 Secret"，Issuer/ClusterIssuer 描述"去哪个 CA、用什么方式签"。控制器盯着有效期，到期前自动把"签发 → CA 回访验证 → 写入 Secret"整个环再跑一遍。没有它，证书续期是某个运维的日历提醒；有了它，续期是控制环的常态——这就是"把运维知识编码进控制环"的含义。

ServiceMonitor 建了却不抓，排障三连：

```bash
kubectl get servicemonitor -A                                          # CR 在吗
kubectl get prometheus -A -o yaml | grep -A4 serviceMonitorSelector    # label 匹配吗
# 第三步：打开 Prometheus UI 的 Service Discovery 页，看 target 进列表了吗
```

三步走完，问题一定停在某一格：要么 CR 根本没建成（回 schema 一节查剪枝），要么 label 断链，要么目标没进发现列表——每格对应一个完全不同的修法。

顺便一个升级坑：Helm 升级默认不更新已存在的 CRD、卸载也不删。于是"chart 升到新版、旧 CRD 缺新字段"是一类经典故障——新字段被静默剪掉或报 no matches for kind。纪律：CRD 当独立发布物，升级前先 apply 新版 CRD 并 diff。

## 什么时候不该写 Operator

讲了这么多，最实用的一节反而是这节。朴素判断就两条：这套运维有没有**清晰的期望状态**？能不能写成**一轮轮可重入的对比与修补**？两个都是——Operator 合适；有一个含糊——别写。

而且你大概率早就在用 Operator 而不自知：Gateway API 的实现控制器、Calico 的 IP Pool、Prometheus 整套可观测栈，背后都是 CRD + 控制器。判断"该不该"的能力，比"会不会写"更常被用到。

具体到几类常见需求：

| 需求 | 该用什么 |
| --- | --- |
| 定时跑个脚本（备份、清理、对账） | Job/CronJob，别上 Operator |
| 配置分发、一次性动作，没有持续对账需求 | ConfigMap + 一段消费它的脚本 |
| 部署/扩缩/failover/证书续期这类持续对账 | CRD + 控制器，值得 |
| 给派生数据一个 API（如指标） | 聚合 API，不是 CRD |

第二行展开一句【从业者判断】：配置渲染这类一次性动作没有"持续维护期望状态"的需求，ConfigMap 加十几行脚本就闭环了；为它引入新类型、新控制器、新 RBAC，换来的只是排障面变大。判断标准始终是"有没有清晰的期望状态要持续收敛"，而不是"Operator 显得高级"。

预埋一个反方观点，评论区一定有人提：**"kubebuilder 半小时就能脚手架出一个 Operator，AI 还能写代码，成本已经很低，为什么不统一都用 Operator？"**【从业者判断】我的回应是：脚手架生成的是骨架，成本大头在骨架之外——schema 演进、多版本转换、RBAC 边界、Helm CRD 升级、webhook 证书轮换，以及凌晨三点 on-call 的人能不能看懂你的调谐逻辑。工具降低的是第一天的成本，降低不了之后三年的负债。

## 症状速查：先存这张表

| 症状 | 原因 | 第一动作 |
| --- | --- | --- |
| CR 里写的字段 get 出来不见了 | schema 未声明，被默认剪枝 | 补 schema；确需透传加 x-kubernetes-preserve-unknown-fields。若 apply 直接报 Unknown field，是新版 kubectl 默认 strict 校验拦下的，同一根源 |
| chart 升级后报 no matches for kind | Helm 默认不更新已存在的 CRD | 先手动 apply 新版 CRD 再升级 chart |
| ServiceMonitor 建了但 Prometheus 不抓 | label 没被 serviceMonitorSelector 选中，或 port 名不匹配 | 上文排障三连逐级查 |
| 卸载 Operator 后 CR 一直 Terminating | 加 finalizer 的控制器没了，没人摘 | 确认外部资源已处理，patch 清空 finalizers |
| 误删 CRD 后该类型实例全没了 | 删 CRD 级联清理全部 CR，不可恢复 | 灾备靠 etcd 快照，事前管好删除权限 |

这张表覆盖了 CRD 相关故障的绝大多数现场，比背十篇概念文管用。

## 一分钟版本

> **背这段（约一分钟）**
>
> K8s 的扩展模型是套娃：CRD 把新"名词"登记进 apiserver，etcd、RBAC、kubectl 全部免费，但没有控制器时 CR 只是躺在 etcd 里的空壳。控制器每轮 list-watch 拿到当前全量状态，对比期望与实际、补差值、requeue——这是 level-triggered：丢事件无害，所以 Reconcile 必须幂等，一切外部动作都要能安全地做第二遍。你的控制器的输出（如 CronJob）是内置控制器的输入，环环相扣。Operator 就是 CRD 加控制器的打包，只有存在需要持续收敛的清晰期望状态时才值得写。

## 现在就能做的事

三档任选：

- 零门槛档：把"一分钟版本"背下来。下次面试聊 Operator，你能从控制环讲到幂等，再讲到什么时候不该写——多数人答不到第三层。
- 动手档（任意集群，5 分钟）：把"CRD 只是名词"一节的演示跑起来，亲眼看看没有控制器的世界——CR 进了 etcd、kubectl 能查、status 恒为空；再跑 schema 一节的 patch，看字段被静默剪掉。
- 排障档（装有 kube-prometheus-stack 的集群）：对任何一个"建了却不抓"的 ServiceMonitor 跑一遍三连排查，大概率停在 label 没被 serviceMonitorSelector 选中。

```bash
# 动手档收尾：体验完删干净。注意：会级联删光该类型所有 CR，不可恢复
kubectl delete crd maintenancewindows.ops.example.com
```

一句话收束：**CRD 加名词，控制器加动词，Operator 是打包；套娃的每一层，都是同一个控制环。**下次见到一个新 Operator，先看它的 CRD 问"期望状态长什么样"，再看它的 Reconcile 问"它把期望翻译成了哪个内置对象"——两问下去，任何 Operator 你都能十分钟读个大概。

评论区聊两件事：一，你们生产里自研了几个 Operator，最难缠的是哪个？二，你见过最"大炮打蚊子"的 Operator 是为什么需求写的？我先说方向：答案里"每天定时改一个 ConfigMap"这种的一定不少。

K8s 深入理解系列从 Pod、Service 一路讲到控制面，都在专栏合集里。这一篇整理自我在维护的学习仓库，里面还有用 kubebuilder 从零写一个完整 Operator 的实操路线，CRD 章节带着完整的实战演练——GitHub 搜 sre-learning-hub，觉得有用点个 star 不迷路。
