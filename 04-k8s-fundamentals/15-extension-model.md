# 15 · K8s 扩展模型：CRD、自定义控制器、聚合 API 与准入扩展

> 模块：04-k8s-fundamentals ｜ 建议时长：2.5 小时 ｜ 关联认证：CKA-（无直接考点，生态认知底座）/ CKS-准入链与 CRD 权限面 / PCA-Prometheus Operator

## 学习目标

- 能解释 apiserver 请求链上的四类扩展点（自定义资源、自定义控制器、聚合 API、准入扩展）各自改的是链条哪一段
- 能操作 CRD：写出带 structural schema 的类型定义，解释字段剪枝与 x-kubernetes-preserve-unknown-fields 的分工
- 能解释 Operator = CRD + 自定义控制器的控制环封装，说清 declarative + level-triggered 为什么必须搭配幂等与周期重试
- 能区分聚合 API 与 CRD 的适用边界，说清 metrics.k8s.io 为什么是前者而非后者
- 能说出三种准入扩展（MutatingWebhook / ValidatingWebhook / ValidatingAdmissionPolicy）的执行位置与风险纪律

## 1. 全景：四个扩展点，各改链条的一段

前 14 章用的都是内置对象（类型与控制器编译进 apiserver / kube-controller-manager）。想让集群"原生理解"一个新东西时，K8s 提供的不是插件槽，而是四段可以各自挂载的链路——回顾第 12 章 §1 的请求链，扩展点就长在这条链上：

```
# [图] 四类扩展点在请求链上的位置（写请求为例）
kubectl apply -f xxx.yaml
  ──► 认证 → 鉴权
  ──► ① 准入扩展: MutatingWebhook(可改) → 内置默认值 → CEL 策略 / ValidatingWebhook(可拒)
  ──► ② 对象层: 新类型两条注册路 —— CRD(声明式登记, apiserver 全托管)
        或 聚合 API(整个 group 交给外部进程 serve)
  ──► etcd ──► ③ 控制器层: 任何进程都能 list-watch 并调谐(自定义控制器/Operator)
  └─► ④ 读路径: APIService 把 /apis/<group>/<version> 路由给扩展 apiserver(kubectl 无感)
```

一句话分工：**CRD 加"名词"，自定义控制器加"动词"，聚合 API 换掉"一整本词典"，准入扩展管"进门检查"**。Operator 不是第五种扩展点，而是"CRD + 自定义控制器"的打包形态——本章主角。

## 2. CRD：让 apiserver 认识一个新对象

### 2.1 定义与实例：CRD 是类型，CR 是实例

CRD（CustomResourceDefinition）描述"一种新对象长什么样"；照着它创建出来的对象叫 CR（Custom Resource）。注册之后，etcd 存储、REST 端点、RBAC、label/annotation、finalizer、ownerReferences、kubectl get/explain 全部自动获得——这就是"K8s 原生"的含义。

```yaml
# [master] 保存为 crd-maintenance.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: maintenancewindows.ops.example.com    # 命名固定为 <复数>.<group>
spec:
  group: ops.example.com
  scope: Namespaced                           # Cluster 则全集群一份
  names:
    plural: maintenancewindows
    kind: MaintenanceWindow
    shortNames: ["mw"]
  versions:
  - name: v1
    served: true
    storage: true                             # 多版本并存时只能有一个 storage 版本
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
                enum: ["drain", "cordon-only"]    # 值域校验
                default: "drain"
              nodes:
                type: array
                items:
                  type: string
            required: ["windowStart"]
    subresources:
      status: {}                              # spec/status 分离读写
```

```bash
# [master] 注册后立刻可用（不需要重启任何组件）
kubectl apply -f crd-maintenance.yaml
kubectl api-resources --api-group=ops.example.com
kubectl apply -f - <<'EOF'
apiVersion: ops.example.com/v1
kind: MaintenanceWindow
metadata:
  name: kernel-patch-0919
spec:
  windowStart: "2026-09-19T22:00:00+08:00"
  nodes: ["worker1"]
EOF
kubectl get mw && kubectl explain maintenancewindow.spec
```

注意此刻**没有任何控制器认识它**：status 恒为空，对象安静地躺在 etcd 里。数据模型（CRD）与自动化逻辑（控制器）是解耦的两半——这正是第 6 章"装了 Gateway API CRD 还要装 Envoy Gateway 实现"的原因（GatewayClass 需要控制器认领）。

### 2.2 校验与剪枝：schema 说了算，没说的会被剪掉

| 机制 | 行为 | 什么时候关心 |
| --- | --- | --- |
| 字段剪枝（pruning） | CRD v1 默认丢弃 schema 未声明的字段：写进去，读出来就没了 | 不知情时最易踩（见实战演练 3） |
| x-kubernetes-preserve-unknown-fields | 子树上声明 true 后不再剪枝该子树 | 想把一段任意结构原样透传给控制器（如嵌入的 raw JSON），通常配 type: object |
| x-kubernetes-validations | 在字段上写 CEL 表达式，违反直接拒绝（apiserver 内完成，比 webhook 便宜） | 字段间约束，如"只允许两档时长" |

```yaml
# [master] openAPIV3Schema.spec.properties 片段：保留未知字段 + CEL 校验
              ticket:
                type: object
                x-kubernetes-preserve-unknown-fields: true   # 该子树原样保存
              duration:
                type: string
                x-kubernetes-validations:
                - rule: "self == '2h' || self == '4h'"
                  message: "duration 只允许 2h 或 4h"
```

一条红线：**CRD 不是数据库**。对象最终存进 etcd，单个对象体积有硬上限（etcd 默认单次请求约 1.5 MiB），把日志、批次数据塞进 CR 是最常见的滥用——大块数据走专用存储，CR 只放期望状态。另外，自定义资源沿用第 1 章的三套通用机制：generation/observedGeneration（控制器抄进 status，外界才能判断"期望到达了吗"）、finalizer（§7：清理外部资源靠它，"卸载 Operator 后对象卡 Terminating"的原理也在那）、ownerReferences（CR 作属主，级联删除自动完成）。

## 3. 自定义控制器与 Operator 模式：控制环的用户态

### 3.1 控制环骨架：observe → diff → act

第 2 章 §5 讲过 kube-controller-manager 是"几十个循环的集合"；你自己写的控制器与内置的是同构的：

```
# [图] Reconcile 循环（Operator 的心脏）
 ① observe: list-watch CR 与相关对象, Informer 本地缓存兜底(第 2 章 §6)
      ▼
 期望: CR.spec = {mode: drain, nodes: [worker1]} ｜ 实际: worker1 仍在正常调度
      ▼ ② diff: 有差距吗? 没有就退出(本轮无事可做)
      ▼ ③ act: cordon + drain worker1 —— 同样走 Eviction API,
             尊重 PDB(第 8 章 §7 的闸门对自定义控制器一样生效)
      ▼ ④ requeue: 固定周期 / 相关事件到来时重新进入循环
```

### 3.2 declarative + level-triggered：两个必须内化的词

| 术语 | 含义 | 工程后果 |
| --- | --- | --- |
| declarative（声明式） | 用户只写"想要什么"（CR.spec），从不写"怎么做" | 控制器可随时被杀掉重启：重启后对比期望与实际就能续上，不存在"脚本执行到一半"的悬空状态 |
| level-triggered（电平触发） | 每轮处理"当前全量状态"，不依赖"恰好收到某次事件"（edge-triggered） | 丢事件无害：下一轮重算差值自然补上；代价是循环必须幂等——同一动作执行两遍结果不变 |

第 2 章 §6 讲 resync 时已埋下伏笔：Informer 定期把缓存对象重推一遍回调，兜的就是"事件丢了/处理器出错"。由此得到两条写代码前就要接受的推论：**reconcile 会被并发地、重复地调用；一切外部动作（重启数据库、调云 API、cordon 节点）都要能安全地做第二遍**。

### 3.3 Operator：把运维知识编码进控制环

官方口径很朴素：Operator 是用 CRD 管理复杂有状态应用的软件，其控制器把人类运维的知识编码了进去。拆开是三件套：**CRD**（描述"应用期望长什么样"——版本、副本、备份策略）、**控制器**（把部署、扩缩容、failover、备份、升级、续期变成 reconcile 里的分支）、**交付**（CRD 清单与控制器 Deployment 打包成 Helm chart，装完即得）。

"该不该上 Operator"的朴素判断：这套运维是否有清晰的期望状态、能否写成一轮轮可重入的对比与修补？是——Operator 合适；只是"定时跑个脚本"——Job/CronJob 更简单。前 14 章里你已多次与它擦肩而过：第 6 章 Gateway API 的实现控制器、第 10 章 Calico 的 IP Pool CRD、第 14 章背后整个可观测生态。

概念读完想动手，进阶路线在 02-programming 模块：[05 · Go for SRE](../02-programming/05-go-for-sre.md) 的 Informer 演示是控制器骨架的最小形态；[07 · CRD 与 Operator 开发](../02-programming/07-operator-development.md) 用 kubebuilder/controller-runtime 从零写一个完整 Operator。本章与它是同一主题的"概念/实操"两层，建议先在此建立模型，再去那边敲代码。

## 4. 聚合 API 与 AA 层：换掉一整本词典

CRD 是"把新类型登记进 apiserver，存储与 serving 仍归 apiserver"；聚合 API（Aggregated API）则是"把一整个 API group 的 serving 交给外部进程"。第 14 章 §1 的 metrics.k8s.io 就是活例：

```
# [图] 一次 kubectl top 背后的聚合（回顾第 14 章第 1 节）
kubectl top nodes ──► apiserver /apis/metrics.k8s.io/v1beta1/nodes
  └─► kube-aggregator 查 APIService: group=metrics.k8s.io, 路由到 spec.service
        指向的 metrics-server(扩展 apiserver, AA 层)
        认证: front-proxy 证书链透传"原始用户是谁"(第 2 章 §9)
```

为什么它不用 CRD？三个理由都具有普适性：**数据是派生的、易变的**（Pod 用量是 metrics-server 内存里的瞬时值，写进 etcd 既浪费又必然滞后）；**需要自定义存储/协议**（扩展 apiserver 可接自己的数据库与聚合逻辑）；**与 apiserver 解耦部署**（APIService 的 Available 条件单独报告，实现挂了只影响这一个 group——`kubectl top` 报错，集群其他功能完好，第 14 章的排障结论）。

| 维度 | CRD | 聚合 API（AA） |
| --- | --- | --- |
| 谁来 serve 新类型 | apiserver 自己 | 你写的扩展 apiserver（普通 Pod） |
| 存储 | etcd（apiserver 托管） | 自定（可以完全不落盘） |
| 校验/默认值 | structural schema + CEL | 完全自定义 |
| 开发成本 | 低（一份 YAML） | 高（实现 apiserver 协议、证书、APIService） |
| 典型例子 | ServiceMonitor、Certificate、Gateway | metrics.k8s.io、custom-metrics-api（HPA 自定义指标） |

## 5. 准入扩展三种：进门检查的三种做法

第 12 章 §1 的链里，准入在认证/鉴权之后、落 etcd 之前，只作用于写请求。这一段有三条可插拔的路：

| 扩展 | 形态 | 位置与顺序 | 典型用途 |
| --- | --- | --- | --- |
| MutatingWebhookConfiguration | 自建 HTTP 服务（经 Service 寻址） | 准入链最前，可修改对象 | 注入 sidecar、补默认字段、改写镜像仓库 |
| ValidatingAdmissionPolicy | 内置 CEL 表达式，无需起服务 | 与校验段同位，只放行/拒绝 | 简单硬约束：必须带 owner 标签、禁止 :latest 镜像 |
| ValidatingWebhookConfiguration | 自建 HTTP 服务 | 准入链最后，只放行/拒绝 | 复杂策略：OPA Gatekeeper / Kyverno 的引擎本体 |

三条纪律（CKS 视角同样考）：

- **failurePolicy 想清楚再选**：Fail 意味着 webhook 服务不可用时写路径跟着挂；Ignore 则静默放行。生产上通常用 `namespaceSelector` 把 kube-system 等关键 namespace 排除在 webhook 范围外，避免"webhook 挂了，连修复它的 Deployment 都 apply 不进去"的死锁；**准入里也不做慢调用**——每个写请求都过这里，一次几十毫秒的外部查询乘上全集群写量就是事故；
- **策略尽量前移**：能写在 CRD schema/CEL 里的不进准入层，能在 apiserver 内完成的（CEL）不外呼 webhook——每靠外一层，延迟、故障面、运维成本都在涨。第 12 章的结论在这里升级：RBAC 管"能不能做"，准入管"做成什么样"，互补而非互备。

第 7 章 PVC 被补上默认 StorageClass 名、第 8 章每个 Pod 被注入 not-ready/unreachable 容忍，靠的都是**内置**准入控制器（DefaultStorageClass、DefaultTolerationSeconds）——与 webhook 同一段，只是编译在 apiserver 里，所以零配置生效。

## 6. 两个实例拆解：Prometheus Operator 与 Cert-Manager

### 6.1 Prometheus Operator：ServiceMonitor 声明"抓谁"

练习集群的 kube-prometheus-stack（`scripts/setup/install-prom-stack.sh`，见第 14 章 §5）装完会带来一组 CRD，最常打交道的是 ServiceMonitor——声明"照 label 找 Service，抓它背后的 Pod"：

```yaml
# [master] 给 3.3 节的 web Deployment 配监控（需已装 Prometheus Operator）
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: web-sm
  labels:
    release: prom        # 必须被 Prometheus CR 的 serviceMonitorSelector 选中, 否则整条链断在这
spec:
  selector:
    matchLabels:
      app: web           # 圈定要抓取的 Service
  endpoints:
  - port: http           # 对应 Service 的 port 名
```

从 ServiceMonitor 到抓取生效，是一条标准控制环：

```
# [图] ServiceMonitor 的 reconcile
你 apply ServiceMonitor ──► Prometheus Operator watch 到它
  ──► diff: 该 SM 是否已体现在 Prometheus 的抓取配置里?
  ──► act: 重新生成抓取配置并触发热加载
  ──► Prometheus 按 selector 找 Service→Endpoints→Pod, 开始抓 /metrics
  （新 Pod 上线/下线 Operator 不用动 —— 目标列表由发现机制自动维护）
```

排障入口三连：`kubectl get servicemonitor -A`（CR 在吗）→ `kubectl get prometheus -A -o yaml | grep -A4 serviceMonitorSelector`（label 匹配吗）→ Prometheus UI 的 Service Discovery 页（target 进列表了吗）。这就是"声明式监控"：没人手改 prometheus.yml，全是 CR 驱动——PCA 模块全程建立在这个模型上。

### 6.2 Cert-Manager：证书也是一种期望状态

cert-manager 同样是 CRD + 控制器：Certificate 描述"我要一张什么证书、存进哪个 Secret"，Issuer/ClusterIssuer 描述"去哪个 CA、用什么方式签"（如 ACME Let's Encrypt）：

```
# [图] Certificate 的控制环（以 ACME http-01 为例）
Certificate(secretName: tls-web) ──► 控制器: 没有证书 / 快到期?
  ├─ 触发签发 ──► 创建 Order ──► 创建 Challenge（http-01: 临时改 Ingress 暴露校验路径）
  │                   └─► CA 回访验证通过 ──► 签发 ──► 写入 kubernetes.io/tls Secret
  └─ Secret 被 Ingress/网关引用（第 6 章 §4 的 TLS 终止）
       └─ 续期：控制器盯着 renewBefore, 到期前自动把上面的环再跑一遍
```

价值对比：没有它，证书续期是"某个运维的日历提醒"；有了它，续期是控制环的常态——这正是第 3 节"把运维知识编码"的含义。

### 6.3 装与升级：交给 Helm/GitOps，但把 CRD 当独立发布物

这两个 Operator 以及 kube-prometheus-stack 通常用 Helm 安装，chart 结构与升级细节在 [07-cd-gitops/02 · Helm](../07-cd-gitops/02-helm.md)。那里的一个坑在这里同样致命：**Helm 升级默认不更新已存在的 CRD、卸载默认也不删 CRD**，于是"chart 升到新版，旧版 CRD 缺新字段"是一类经典故障（apply 报 no matches for kind，或新字段被静默剪掉）。纪律：CRD 变更当作独立发布物对待，升级前先 diff。

## 7. 选型速查与边界

| 你想做的事 | 用什么 | 见 |
| --- | --- | --- |
| 给新概念一个 K8s 原生对象（kubectl/RBAC/配额全免费） | CRD | §2 |
| 让对象自动驱动现实（部署、备份、failover、续期） | CRD + 自定义控制器（Operator） | §3 |
| serve 派生数据/自定义存储的一整个 API group | 聚合 API | §4 |
| 拦截/改写所有写请求 | Mutating/Validating Webhook、ValidatingAdmissionPolicy | §5 |
| 改节点级行为（网络、存储、设备） | CNI/CSI/设备插件——Kubelet/运行时层扩展，见第 10 章 | — |

三条收尾纪律：自定义资源同样要配 RBAC（第 12 章 §4.3，apiGroups 填你的 group）；CRD 命名带独立 group 前缀，避免与未来内置类型撞车；任何"自动化腾挪"（包括你自己写的控制器）都要过 PDB 与优雅终止这道闸（第 8 章 §7）。

## 实战演练

环境：kubeadm 练习集群。目标：亲手走一遍"定义类型 → 建实例 → 看剪枝与校验 → 体会无控制器时的空转 → finalizer 卡删除"。

```bash
# [master] 1. 注册 2.1 节的 CRD；2. 创建 CR，观察"没有控制器"的世界
kubectl apply -f crd-maintenance.yaml
kubectl api-resources --api-group=ops.example.com
# 预期: maintenancewindows  mw  ...  namespaced  MaintenanceWindow
kubectl apply -f - <<'EOF'
apiVersion: ops.example.com/v1
kind: MaintenanceWindow
metadata:
  name: kernel-patch-0919
spec:
  windowStart: "2026-09-19T22:00:00+08:00"
EOF
kubectl get mw kernel-patch-0919 -o jsonpath='{.status}'; echo
# 预期: 空输出（或 {}）—— 数据进了 etcd, 但没有控制器写 status
```

```bash
# [master] 3. 剪枝肉眼可见；4. schema 校验拒绝 enum 之外的值
kubectl patch mw kernel-patch-0919 --type=merge -p '{"spec":{"owner":"sre-a"}}'
kubectl get mw kernel-patch-0919 -o jsonpath='{.spec.owner}'; echo
# 预期: 空输出 —— 未声明字段被静默剪除（apply 同理，不报错）
kubectl patch mw kernel-patch-0919 --type=merge -p '{"spec":{"mode":"reboot"}}'
# 预期: ... is invalid: spec.mode: Unsupported value: "reboot": supported values: "drain", "cordon-only"
```

```bash
# [master] 5. finalizer 模拟"控制器已死"（第 1 章 §7 的机制在 CR 上同样成立）
kubectl patch mw kernel-patch-0919 --type=merge \
  -p '{"metadata":{"finalizers":["ops.example.com/cleanup"]}}'
kubectl delete mw kernel-patch-0919 &
sleep 3; kubectl get mw
# 预期: kernel-patch-0919 仍在 —— deletionTimestamp 已打, 但 finalizer 没人摘
kubectl patch mw kernel-patch-0919 --type=merge -p '{"metadata":{"finalizers":null}}'   # 预期: 立即真正消失
kubectl delete crd maintenancewindows.ops.example.com   # 注意: 会级联删光该类型所有 CR, 不可恢复
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| CR 里写的字段 get 出来不见了 | CRD v1 默认剪枝未声明字段 | schema 补声明；确需透传时子树加 x-kubernetes-preserve-unknown-fields: true |
| chart 升级后报 no matches for kind / 新字段不生效 | Helm 默认不更新已存在的 CRD | 先手动 apply 新版 CRD 再升级 chart（见 07-cd-gitops/02） |
| ServiceMonitor 建了但 Prometheus 不抓 | label 没被 serviceMonitorSelector 选中，或 Service 无匹配的 port 名 | §6.1 的三步排障 |
| 卸载 Operator 后 CR 一直 Terminating | 加 finalizer 的控制器没了，没人摘（第 1 章 §7 自测 5） | 确认外部资源已处理，再 patch 清空 finalizers |
| 误删 CRD 后该类型实例全没了 | 删 CRD 会级联清理其全部 CR，不可恢复 | 当高危操作管权限；灾备靠 etcd 快照（第 13 章 §3） |

## 自测

1. CRD 已经注册了新类型，为什么还需要自定义控制器才能形成闭环？没有控制器的 MaintenanceWindow 处在什么状态？

<details><summary>答案</summary>

CRD 只解决"存储与 API 面"：对象能进 etcd、能被 kubectl/RBAC 管理，但没人读它、没人对它采取行动，status 恒为空。闭环 = 期望状态（CR.spec）+ 一个不断对比并修补现实的控制循环。没有控制器的 CR 只是躺在 etcd 里的一份配置文档——第 6 章"装了 Gateway API CRD 还要装 Envoy Gateway 实现"正是这个关系。
</details>

2. 控制器重启后没有任何"断点续传"信息，为什么工作还能接上？这个性质对写代码提出了什么硬要求？

<details><summary>答案</summary>

因为控制环是 level-triggered：每轮 reconcile 都从当前全量状态出发重算期望与实际的差值，而不是依赖"上次处理到哪"这类边沿记忆。重启后第一轮 reconcile 自然发现差距并继续修补。硬要求是幂等：同一动作做两遍结果不变（写"确保 DaemonSet 存在"而不是"创建 DaemonSet"），因为同一差值可能被多次、并发地触发处理。
</details>

3. 假设把 metrics.k8s.io 改用 CRD 实现——每 15 秒为每个 Pod 写一个用量 CR。列出至少三个会出问题的地方。

<details><summary>答案</summary>

①写放大：数千 Pod 乘每 15 秒一次的 etcd 写入，etcd 写吞吐与磁盘先成为瓶颈，还推高快照与压缩压力；②数据没有过期语义：CR 无 TTL，历史读数不断堆积，还挤占单对象体积上限；③审计与 watch 噪音：高频写产生海量事件与审计记录，干扰正常排障。聚合 API 让 metrics-server 在内存里现算现卖，读请求直达、不落 etcd——派生型瞬时数据不适合声明式存储。
</details>

4. ValidatingAdmissionPolicy（CEL）与 CRD 的 x-kubernetes-validations 都能拒绝非法对象，两者作用域有何不同？为什么说"策略尽量前移"？

<details><summary>答案</summary>

x-kubernetes-validations 只约束这一种 CRD 类型的字段，apiserver 内联执行、零额外依赖；ValidatingAdmissionPolicy 作用于任意（含内置）资源的写请求，同样由 apiserver 内评估 CEL、无需自建 webhook 服务。"前移"指：能写进 schema 的约束不进准入层，能在 apiserver 内完成的（CEL）不外呼 webhook——每往外靠一层，延迟、故障面、运维成本都在涨。
</details>

5. `helm upgrade` 明明成功了，新版本 ServiceMonitor 的字段却报 unknown field 或被忽略。升级流程漏了什么？

<details><summary>答案</summary>

Helm 3 默认不更新集群里已存在的 CRD（防止破坏在用资源），新 chart 引入的新字段不在旧 CRD 的 schema 里：未开严格校验时被静默剪掉，开了校验则直接报错。正确流程是把 CRD 当独立发布物：升级 chart 前先 apply 新版 CRD 并 diff 确认兼容——详见 07-cd-gitops/02 的坑表。
</details>

## 延伸阅读

- 自定义资源（含结构化 schema 与剪枝）：https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/custom-resources/
- Operator 模式：https://kubernetes.io/docs/concepts/extend-kubernetes/operator/
- 聚合层与 APIService：https://kubernetes.io/docs/concepts/extend-kubernetes/api-extension/apiserver-aggregation/
- 准入控制器参考与 ValidatingAdmissionPolicy：https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/ 、https://kubernetes.io/docs/reference/access-authn-authz/validating-admission-policy/
- Prometheus Operator（ServiceMonitor 设计）与 cert-manager 文档：https://github.com/prometheus-operator/prometheus-operator 、https://cert-manager.io/docs/
