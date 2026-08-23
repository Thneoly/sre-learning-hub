# 01 · 为什么需要 Kubernetes：声明式系统与控制循环

> 模块：04-k8s-fundamentals ｜ 建议时长：2 小时 ｜ 关联认证：CKA-应用管理·集群架构 / CKS-（无直接考点，但是一切的底座）

## 学习目标

- 能解释声明式 API 与命令式运维在"故障恢复"上的本质差异，并举出一条完整事件链
- 能用 期望状态（spec）/ 实际状态（status）/ reconcile 三要素拆解任意一个 K8s 控制器
- 能操作 kubectl 验证 generation、observedGeneration、ownerReferences、finalizer 的存在与变化
- 能排查"删掉的 Pod 又冒出来""Namespace 卡在 Terminating"两类经典故障

## 1. 一段命令式运维的失败史

假设你用 shell 脚本 + systemd 管 6 台 VM 上的 nginx。半夜 2 点进程挂了，你的系统会经历：

```
# [图] 命令式运维的故障链条
02:00  nginx 进程 OOM 被内核杀死
02:00  没有任何组件"知道"期望状态是什么 → 无人负责拉起
02:35  用户报障 → 值班人工 ssh 登录 → systemctl start nginx
02:36  恢复，但: 没有留下审计记录、没有事件、没有可复盘的时间线
```

命令式（imperative）系统的三个结构性缺陷：

| 缺陷 | 说明 |
| --- | --- |
| 期望状态只存在于执行者脑中 | "应该跑 3 个副本"这个事实没有落在系统里，进程死了系统无从得知"少了东西" |
| 操作不是幂等的 | `systemctl start` 执行两次、由两个人各执行一次，结果不可预测 |
| 恢复逻辑散落在外部脚本 | 脚本本身也会挂、也会丢事件，恢复依赖"事件不丢 + 脚本恰好活着" |

Kubernetes 的解法不是"更好的重启脚本"，而是换一种表达方式：把期望状态本身写进系统，让一组常驻循环持续把实际状态推向期望状态。

## 2. 声明式：只说"我要什么"

声明式（declarative）系统里，你提交的是"终态描述"：

```yaml
# [master] 保存为 web.yaml，声明"我要 3 个带这个标签的 Pod"
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
      containers:
      - name: nginx
        image: nginx:1.27
```

`kubectl apply -f web.yaml` 之后真正发生的事：

```
# [图] 一次 apply 的完整旅程
kubectl                      kube-apiserver                  etcd
  │  POST/PATCH 对象            │                              │
  ├──────────────────────────► │ 1. 认证: 你是谁               │
  │                            │ 2. 授权: RBAC 能不能写        │
  │                            │ 3. 准入: Mutating→Validating │
  │                            │ 4. 默认值填充 + 校验          │
  │                            │ 5. 写入 etcd (RAFT 提交) ───►│
  │                            │      此时【没有任何容器被创建】│
  │  201 Created ◄─────────────┘                              │
  │                                                           │
  │        scheduler / controller-manager 通过 watch 感知新对象  │
  │        → 各自 reconcile → kubelet 收到绑定 → CRI 拉起容器    │
```

关键认知：**apply 返回成功 ≠ 应用在运行**。apply 只保证"期望状态已持久化"，容器是由后续一连串异步控制循环创建的。

| 维度 | 命令式 | 声明式 |
| --- | --- | --- |
| 表达内容 | 怎么做（步骤序列） | 要什么（终态） |
| 重复执行 | 有副作用，需人工去重 | 幂等，apply 一百次结果一致 |
| 故障恢复 | 依赖外部脚本捕获事件 | 控制器持续比对状态，错过事件也能收敛 |
| 审计与回滚 | 靠命令历史，不可靠 | 对象即文档，可 diff、可 git 化（GitOps） |
| 并发修改 | 冲突难以合并 | resourceVersion 乐观并发控制（冲突返回 409） |

## 3. 期望状态与实际状态

每个 API 对象都被拆成两半：

- `spec`：期望状态，由**你**写入（"我要 3 副本、镜像 1.27"）
- `status`：实际状态，由**控制器**观测后写回（"当前 3 副本、3 Ready、副本集 abc 创建于…"）

```bash
# [master] 查看 spec 与 status 两侧
kubectl get deployment web -o jsonpath='{.spec.replicas}{"\n"}'
kubectl get deployment web -o jsonpath='{.status.readyReplicas}{"\n"}'
kubectl get deployment web -o jsonpath='{.metadata.generation} {.status.observedGeneration}{"\n"}'
```

两个用于追踪"控制器跟没跟上"的字段：

- `metadata.generation`：spec 被修改的代数，**只有 spec 变化才会 +1**（改 label、status 不会）
- `status.observedGeneration`：控制器声明"我已经处理到第几代"

如果 `generation=3` 而 `observedGeneration=2`，说明你最新的修改还没被控制器消化——这在排障时非常有用（控制器挂了/卡住会表现为两者长期不一致）。

## 4. reconcile：整个系统的发动机

所有控制器——无论是内置的 ReplicaSet 控制器还是你自己写的 Operator——都在跑同一个循环：

```text
# [伪代码] 每个控制器都是一个无限循环
for {
  desired := apiserver 里某对象的 spec        // 例如: replicas=3
  current := 观测到的真实世界                  // 例如: 存活且匹配 selector 的 Pod 数

  if current != desired {
    执行动作让 current 逼近 desired            // 少了就建 Pod, 多了就删 Pod
  }
  // 相等则什么都不做, 下一轮再看
}
```

三条推论，也是面试与排障的核心：

1. **循环必须幂等**：动作可以重复执行（"已存在就跳过"）。因为循环可能在你不知道的时候重跑。
2. **level-triggered（水平触发）而非 edge-triggered（边沿触发）**：控制器每轮读取的是**全量状态**并做比较，不依赖"我曾经收到过一次变更事件"。哪怕 watch 断连、事件丢失、控制器进程崩溃重启，下一轮循环依然能算出正确的差值并收敛。这就是 K8s 能在"不可靠环境"里保持正确的根本原因。
3. **没有"完成"这个概念**：循环永不退出。你眼中的"部署完成"只是某一轮比较结果相等而已。

## 5. 自愈、扩缩容、滚动更新：同一个循环的三张面孔

初学者以为是三种机制，其实是同一个 reconcile 在三种输入下的表现：

| 场景 | 谁修改了 spec | 谁在 reconcile | 循环看到的差值与动作 |
| --- | --- | --- | --- |
| 自愈：Pod 挂了 | 没人改 spec | ReplicaSet 控制器 | desired=3, current=2 → 新建 1 个 Pod |
| 扩缩容 | 你：`kubectl scale` | ReplicaSet 控制器 | desired=5, current=3 → 新建 2 个 Pod |
| 滚动更新 | Deployment 控制器改写"目标 RS" | Deployment + RS 控制器 | 新 RS 的 desired 从 0 逐步加到 3，旧 RS 逐步减到 0 |

```
# [图] 三种场景共用同一个比较逻辑
                ┌────────────────────────────────────┐
                │  desired (spec.replicas = 3)       │
                └──────────────┬─────────────────────┘
                               │ 比较
                ┌──────────────▼─────────────────────┐
   自愈:  current=2 (容器死了)      → 补 1 个        │
   扩容:  current=3, spec 改成 5   → 补 2 个        │
   更新:  换一个"期望模板", 新建新RS │ 逐个替换       │
                └────────────────────────────────────┘
```

所以"K8s 会自愈"这句话的准确翻译是：**自愈不需要额外的自愈模块，它只是控制器在无人改 spec 的情况下继续跑循环的副产品**。HPA（自动扩缩）也不过是把"修改 spec.replicas"这一步交给另一个控制器而已（见第 04 章）。

## 6. ownerReferences 与级联垃圾回收

控制器创建的对象会自动带上"属主"标记，形成属主链：

```
# [图] 属主链与级联删除
Deployment(web) ──owns──► ReplicaSet(web-7d4b8c) ──owns──► Pod(web-7d4b8c-xk7p9)
     │                        │                              │
     └── 删除 Deployment ──────┴── GC 级联删除 RS ────────────┴── 再级联删除 Pod
```

```bash
# [master] 验证属主链: Pod 的 owner 是 RS, RS 的 owner 是 Deployment
kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.ownerReferences[0].kind}{"\n"}'
# ReplicaSet
kubectl get rs -l app=web -o jsonpath='{.items[0].metadata.ownerReferences[0].name}{"\n"}'
# web
kubectl get deployment web -o jsonpath='{.metadata.uid}{"\n"}'   # 与 RS ownerReferences 的 uid 一致
```

垃圾回收（GC）由 kube-controller-manager 里的 garbage-collector 控制器执行，三种级联模式：

| 模式 | 行为 | 典型场景 |
| --- | --- | --- |
| background（默认） | 属主立即删除，后台异步删除从属对象 | 日常删除，从属对象可能"多活几秒" |
| foreground | 属主先进入 Terminating 并打上 `foregroundDeletion` finalizer，等所有从属对象删光后才真正消失 | 需要保证删除顺序时 |
| orphan | 只删属主，从属对象的 ownerReferences 被摘除，变成"孤儿"继续存活 | 交接/迁移对象所有权 |

```bash
# [master] orphan 实验: 删除 Deployment 但保留其 RS 与 Pod
kubectl delete deployment web --cascade=orphan
kubectl get rs,pod -l app=web          # RS 和 Pod 都还在
kubectl get rs -l app=web -o jsonpath='{.items[0].metadata.ownerReferences}{"\n"}'
# 输出为空: ownerReferences 已被摘除, 这些 RS/Pod 从此无人管辖、也不会被级联删除
```

## 7. finalizer：删除前的"最后确认"

删除一个带 finalizer 的对象时，API server **不会真正删除它**，只打上 `deletionTimestamp` 并等待。对象停留在 Terminating，直到某个控制器做完清理（断开外部存储、注销 DNS、释放云资源）并把 finalizer 从列表里移除，删除才会真正发生。

```
# [图] finalizer 的生命周期
用户 DELETE ──► API server: metadata.finalizers 非空?
                     │ 是
                     ├── 打上 deletionTimestamp (对象进入 Terminating, 只读)
                     ├── 等待负责的控制器完成外部清理
                     └── 控制器把 finalizer 移除 ──► 对象此刻才真正从 etcd 消失
```

这就是"PVC 删不掉""Namespace 卡 Terminating"的统一原理：某个控制器没能（或没机会）摘掉它加的 finalizer，删除动作就永远悬在半空。

```bash
# [master] 亲手制造一个"删不掉的对象"并解除
kubectl create configmap fin-demo
kubectl patch configmap fin-demo --type=merge \
  -p '{"metadata":{"finalizers":["example.com/protect"]}}'
kubectl delete configmap fin-demo --wait=false     # 立刻返回
kubectl get configmap fin-demo -o jsonpath='{.metadata.deletionTimestamp}{"\n"}'
# 非空: 对象卡在 Terminating
kubectl patch configmap fin-demo --type=merge -p '{"metadata":{"finalizers":null}}'
kubectl get configmap fin-demo                     # NotFound: 真正删除完成
```

警告：手动清 finalizer 是"最后手段"。finalizer 的语义是"外面还有资源没回收"，直接清空等于替控制器签字"清完了"，可能造成外部资源泄漏。生产上应先确认负责的控制器（如某个 Operator）是否已停止工作，再决定清理。

## 实战演练

环境：kubeadm 单 master 集群 + Calico。在 master 上操作。

```bash
# [master] 1. 部署并观察三个经典场景
kubectl create deployment web --image=nginx:1.27 --replicas=2
kubectl get deployment web -o jsonpath='{.metadata.generation} {.status.observedGeneration}{"\n"}'
# 预期: 1 1

# [master] 2. 场景一: 自愈(不改 spec)
kubectl delete pod -l app=web && kubectl get pods -l app=web -w
# 预期: 被删 Pod 消失的数秒内出现一个新 Pod(名字不同), 这是 ReplicaSet 控制器在补差值

# [master] 3. 场景二: 扩缩容(改 spec)
kubectl scale deployment web --replicas=4
kubectl get deployment web -o jsonpath='{.metadata.generation} {.status.observedGeneration}{"\n"}'
# 预期: 2 2 —— generation 因 spec 变化 +1

# [master] 4. 场景三: 滚动更新(控制器改写期望)
kubectl set image deployment/web nginx=nginx:1.29
kubectl rollout status deployment/web
# 预期: 逐步替换; 细节在第 04 章展开

# [master] 5. 验证属主链与级联删除三模式
kubectl get rs,pod -l app=web -o jsonpath='{range .items[*]}{.kind}/{.metadata.name} owner={.metadata.ownerReferences[0].name}{"\n"}{end}'
kubectl delete deployment web --cascade=orphan
kubectl get rs,pod -l app=web          # RS、Pod 全部幸存且 owner 被摘除
kubectl delete rs,pod -l app=web       # 清理现场
```

验证方法：每一步的"预期"注释即验收标准；若第 2 步没有新 Pod 出现，先看 ReplicaSet 是否存在（`kubectl get rs -l app=web`）。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| `kubectl delete pod` 后又冒出一个新 Pod | Pod 有 owner（RS/StatefulSet/DaemonSet），控制器在补副本 | 删控制器或先缩容，别跟 Pod 较劲 |
| Namespace/PVC 长期 Terminating | 某控制器加的 finalizer 未被摘除 | `kubectl get <obj> -o jsonpath='{.metadata.finalizers}'` 定位；确认控制器已死后再 patch 清空 |
| `kubectl apply` 成功但服务没起来 | apply 只写期望状态，后续链路（调度/kubelet/拉镜像）是异步的 | `kubectl rollout status` + `kubectl describe` 看 events |
| 手动 `kubectl edit` 改 status 无效 | status 由控制器持续写回，人工修改会被覆盖 | 永远改 spec |
| orphan 删除后出现无主"僵尸 Pod" | 使用了 `--cascade=orphan` 且忘了接管 | 按标签清理并补建控制器 |

## 自测

1. ReplicaSet 控制器进程崩溃 30 秒，期间有人手动删掉了 1 个 Pod。控制器恢复后副本数如何收敛？为什么不需要"补发事件"？

<details><summary>答案</summary>

恢复后控制器做一次全量比较：desired=replicas，current=当前匹配 selector 的存活 Pod 数。发现少 1 个，新建 1 个。不需要补发事件，因为 reconcile 是 level-triggered 的——它读的是状态而非事件流，30 秒里发生的一切都体现在"当前少一个 Pod"这个事实里。
</details>

2. `kubectl scale deployment web --replicas=5` 这条命令到底修改了什么？谁是这条命令的"执行者"？

<details><summary>答案</summary>

只修改了 Deployment 对象的 `spec.replicas`（经 apiserver 写入 etcd），没有创建任何容器。真正的"执行者"是 Deployment/ReplicaSet 控制器：它们 watch 到变化后按新期望值建 Pod。命令式外壳包裹着声明式内核。
</details>

3. foreground 级联删除为什么能让属主"活到"从属对象删光之后？它借助了哪个机制？

<details><summary>答案</summary>

借助 finalizer。foreground 删除时 apiserver 给属主打上 `foregroundDeletion` finalizer 并设置 deletionTimestamp，属主进入 Terminating 但不消失；GC 控制器先删除所有从属对象，全部删光后摘掉这个 finalizer，属主才真正删除。
</details>

4. 如果把控制器写成 edge-triggered（只对 watch 事件做反应、不做全量比较），会多出哪些故障模式？

<details><summary>答案</summary>

watch 断线期间的变化全部丢失；控制器重启后内存状态清零而无从追赶；事件重复投递导致重复动作；"缓慢漂移"（如有人直接在节点上 kill 容器）不产生 API 事件，永远无人纠正。level-triggered 每轮重算差值，天然免疫这些问题。
</details>

5. 一个带自定义 finalizer 的对象，负责它的 Operator 已经被卸载。为什么 apiserver 永远不删它？正确处置流程是什么？

<details><summary>答案</summary>

apiserver 的删除语义是：finalizers 非空则只打 deletionTimestamp，不真正删除；而摘除 finalizer 的责任在加它的控制器。控制器没了就没人摘，对象无限期 Terminating。处置：确认 Operator 已卸载、其管理的**外部**资源已手工处理（这是 finalizer 存在的意义），然后 patch 清空 finalizers 让删除完成。
</details>

## 延伸阅读

- 对象的 spec 与 status：https://kubernetes.io/docs/concepts/overview/working-with-objects/kubernetes-objects/
- 级联删除与垃圾回收：https://kubernetes.io/docs/concepts/architecture/garbage-collection/
- finalizer 设计指南：https://kubernetes.io/docs/concepts/overview/working-with-objects/finalizers/
- 控制面组件概览：https://kubernetes.io/docs/concepts/overview/components/
