# 01 · K8s 资源生命周期图鉴：八张状态图一张网

> 模块：20-lifecycles ｜ 建议时长：2 小时 ｜ 关联认证：CKA-故障排查（App 疑难 / 集群维护）/ —（无新考点，是 04-k8s 与 05-cka 的横向收口章）

## 本章怎么用

本模块是**横向参考图鉴**，不讲新原理：组件的机制你已经在 04-k8s-fundamentals 和 05-cka 里逐个学过，这里把八类 K8s 资源的生命周期统一画成 ASCII 状态图，一眼对照"它现在停在哪、谁负责把它推走、为什么推不动"。

每张图四个固定件：① 状态图（方框 = 状态，箭头 = 转移，箭头上的字 = 触发条件）② 状态说明表 ③ 最常见卡住场景（引全站索引 [SCENARIOS.md](../SCENARIOS.md)）④ 深入章节引用。

读图三条纪律：

- **方框名 = kubectl 眼中的显示值**。注意不少"状态"（Terminating、CrashLoopBackOff）不是 `status.phase`，是 kubectl 拼出来的显示串（[04-k8s/03 章 §2](../04-k8s-fundamentals/03-pods-deep-dive.md) 的三层状态模型）。
- **卡住 = 停在只有入箭头、没有出箭头的框**。排障第一问不是"它怎么了"，而是"谁负责把它推出这个框"——那个组件才是根因现场。
- **自愈环不需要救**。各种 BackOff 环、HPA 的周期环会自己转，要做的是趁退避间隙收集证据（logs /previous、describe 的 Events）。

全章八张图共用一批"计时器"，先记住，后面反复出现：优雅退出宽限 30s、节点心跳宽限 40s、NotReady 后驱逐容忍 300s、HPA 缩容稳定窗口 300s、滚动更新死线 600s。

---

## 1. Pod：一条主路，两个自愈环

### ① 状态图

```
# [图] Pod 生命周期：主路自上而下；两个 BackOff 环会自己转，终态框出不去
  kubectl apply（apiserver 写入期望）
        │
        │ scheduler 绑定节点（PodScheduled=True）
        ▼
  ┌───────────┐                      ┌───────────────────┐  拉镜像失败       ┌─────────────────┐
  │  Pending  │ ───────────────────► │ ContainerCreating │◄─(退避后重试)──── │ ImagePullBackOff │
  └───────────┘                      └─────────┬─────────┘                  └─────────────────┘
        │                                      │ 建沙箱+拉镜像+挂卷              ▲ 只在镜像层打转：
        │ 卡死点：Events 只有                   │ 全部就绪                       │ not found / 认证
        │ FailedScheduling（资源不足/             ▼                              │ /网络超时 三类
        │ 污点不容忍/亲和无解）——不是死局：      ┌─────────────────┐              │
        │ 调度器会持续重试绑定，资源释放后        │ PodInitializing  │ init 容器按序跑│
        │ 走得出去；没有出箭头的是终态框         └────────┬────────┘              │
        │                                               │ 全部成功(Initialized=True)
        │                                               ▼
        │                                      ┌────────────────┐  容器退出(非 0)  ┌─────────────────┐
        │                                      │    Running     │ ──────────────► │CrashLoopBackOff │
        │                                      │ readiness 通过  │ ◄────────────── │ 退避 10s→20s→…  │
        │                                      │ = Ready，进    │   退避结束重启    │   上限 300s     │（容器稳定
        │                                      │ Endpoints      │  (liveness 失败  └─────────────────┘  运行 10min
        │                                      └───┬────────┬───┘   也走此环)            后退避计数清零）
        │                正常退出(exit 0) 且         │        │ kubectl delete / 控制器回收
        │                restartPolicy≠Always       │        ▼
        │                                          │ ┌──────────────┐ grace 默认 30s：
        │                                          │ │ Terminating  │ Endpoints 立刻摘 →
        │                                          │ │              │ preStop → SIGTERM →
        │                                          │ └──────┬───────┘ 超时 SIGKILL
        │                                          │        │ 对象消失
        │                异常退出(非 0) 且           │        │
        │                restartPolicy=Never       ▼        │
        │                                     ┌────────────────────┐
        └─────────────────────────────────────│ Succeeded / Failed │（终态：Job 类 Pod 的归宿，
                                              │  （进入后不再重启）  │ 全图唯一没有出箭头的框）
                                              └────────────────────┘
```

### ② 状态说明表

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
| --- | --- | --- | --- |
| Pending | 已入 etcd，未绑定节点或未建容器 | kube-scheduler | 资源不足、污点不容忍、亲和/拓扑约束无解、PVC 未绑定 |
| ContainerCreating | kubelet 建沙箱、拉镜像、挂卷 | 节点 kubelet + 容器运行时 + CNI | 大镜像拉取慢、RWO 卷 Multi-Attach、CNI 未就绪 |
| PodInitializing | init 容器按序执行 | kubelet | init 容器自身失败或卡死（`kubectl logs -c <init>`） |
| Running | 主容器在跑；readiness 通过才算 Ready | kubelet | 不是问题态；NotReady 在此暴露（探针失败/Pending 依赖） |
| CrashLoopBackOff | 反复崩溃后的指数退避等待 | kubelet | 应用崩溃、liveness 过严、OOMKilled（exit 137） |
| ImagePullBackOff | 拉镜像失败后的退避等待 | kubelet + 运行时 | 镜像名/Tag 错、registry 认证、网络超时 |
| Terminating | 等优雅退出完成（宽限默认 30s） | kubelet | preStop 卡死、PID 1 是 sh 不转发 TERM、finalizer 未清 |
| Succeeded / Failed | 终态 | — | Job 类负载的归宿；Deployment Pod 永远在重启环里 |

### ③ 最常见卡住场景（SCENARIOS.md §3 工作负载）

- **一直 Pending**：`FailedScheduling ... Insufficient cpu`——调度器会一直重试，但资源不释放就永远出不去（不是终态死局，却没人推就走不动），改资源请求/加节点才有出路（`kubectl describe pod` 的 Events 一句话给全原因）。
- **CrashLoopBackOff 分不清根因**：三连取证——`kubectl logs --previous`（上一次崩溃输出）→ `describe`（探针失败/OOMKilled exit 137）→ `get events --sort-by=.lastTimestamp`。
- **删除 Pod 等满 30s 才停**：TERM 没人接——入口用 exec 形式顶替 sh，滚动期配 preStop sleep 等 Endpoints 摘除生效。

### ④ 深入

状态三层模型、探针语义、init/sidecar、优雅退出时序与退避算法：[04-k8s/03 章](../04-k8s-fundamentals/03-pods-deep-dive.md) §2 / §3 / §4 / §5 / §6。

**从图中一眼看出的排障要点**：Succeeded / Failed 才是全图唯一没有出箭头的框（终态，进入后不再重启）；Pending 卡在 FailedScheduling 不是死局——调度器资源释放后会继续重试绑定，但没人释放资源它就永远出不去；两个 BackOff 环的箭头都是闭环（自己会重试）；Terminating 卡 30s 以上说明环末端 SIGKILL 那步的执行者 kubelet 失联，或 finalizer 拦着对象删除。

---

## 2. Deployment：两条 RS 此消彼长

### ① 状态图

```
# [图] Deployment：所谓状态，本质是"新 ReplicaSet 的扩容进度"；pause/undo 只是改目标
  kubectl apply（replicas=N，模板 v1）
        │ deployment 控制器创建 RS-v1 并扩到 N
        ▼
  ┌──────────────┐  set image / apply 改模板       ┌──────────────────────────────┐
  │  Complete    │ ─────────────────────────────► │ Progressing（滚动中）          │
  │  （稳态）     │                                │ 新 RS +1（总数 ≤ N+maxSurge）  │
  │ 新RS=N 旧RS=0 │ ◄──────────────────────────── │ →等新 Pod Ready 且待满         │
  └──────▲───────┘   新 RS 达 N、旧 RS 缩 0、      │  minReadySeconds              │
         │           可用 ≥ N−maxUnavailable      │ →旧 RS −1，循环至新=N 旧=0     │
         │                                        └──────┬───────────────────────┘
         │                                               │ kubectl rollout pause
         │  滚动超 progressDeadlineSeconds（默认 600s）：   │（进 Paused 的唯一入口是人）
         │  condition 标为 ProgressDeadlineExceeded，     ▼
         │  只标记不停止：不暂停、不回退，仍停在       ┌────────────────┐ rollout resume
         │  Progressing 等人工介入（卡住信号）         │ Paused（暂停）  │ ───► 回 Progressing
         │                                        │ 冻结当前新旧比例 │
         │                                        └────────────────┘
         │  rollout undo：把某个旧 RS 当"新目标"重新扩容（反向滚动，镜像在节点
         │  本地有缓存，秒级完成）；本钱 = revisionHistoryLimit（默认 10）个
         │  被缩到 0 但保留的旧 RS 对象
         └───────────────────────────────────────────────────┘
  删除：kubectl delete deploy → RS 与 Pod 级联删除（--cascade=orphan 例外）
```

### ② 状态说明表

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
| --- | --- | --- | --- |
| Complete | 新 RS=N，可用副本达标 | deployment 控制器 | — |
| Progressing | 新旧 RS 此消彼长 | deployment 控制器；readiness 是放行闸门 | 新 Pod 不 Ready、surge 余量资源不够、RWO 卷仍被旧 Pod 持有 |
| ProgressDeadlineExceeded | 超 600s 未完成（标记型状态） | deployment 控制器 | 上行原因未修，`rollout status` 会一直等 |
| Paused | 冻结当前比例，改多项配置只滚一次 | 人（`rollout pause`） | 忘记 resume，永远半新半旧 |
| 回滚 | 旧 RS 重新扩容，一次反向滚动 | deployment 控制器 | revision 被淘汰（limit 太小 / orphan 删除） |

### ③ 最常见卡住场景（SCENARIOS.md §3 工作负载）

- **滚动更新瞬间 5xx**：放行闸门（readiness）与摘流量不对称——新 Pod 没 Ready 就接不了流量，旧 Pod 删时立刻被摘；readinessProbe + preStop sleep 组合拳。
- **rollout undo 说没有历史**：旧 RS 被 revisionHistoryLimit 淘汰——真正兜底是 Git 里的旧 YAML。

### ④ 深入

属主链、maxSurge/maxUnavailable 逐行推演、undo 的本钱与代价：[04-k8s/04 章](../04-k8s-fundamentals/04-workload-controllers.md) §2 / §3 / §4。

**从图中一眼看出的排障要点**：Progressing 框里唯一的放行动作是"新 Pod Ready"，滚动停滞先查新 Pod 的探针而不是 Deployment 本身；Paused 只有 resume 一条出箭头（人设置的人解除）；Complete 与 Progressing 之间的往返箭头永远存在——任何模板改动都会再进环。

---

## 3. Service / Endpoints：唯一的坏状态是无后端

### ① 状态图

```
# [图] Service/Endpoints：Service 对象永远"创建成功"；坏只会坏在 Endpoints 为空
  kubectl apply svc（selector: app=web）
        │ endpoints controller（kube-controller-manager 内）watch selector 命中的 Pod
        ▼
  ┌──────────────────────┐   至少一个 Pod"匹配 selector 且 Ready=True"
  │ 端点同步              │ ──────────────────────────────────────────┐
  └──────────────────────┘                                           ▼
        │ 匹配 0 个 / 全部 NotReady                            ┌───────────────┐
        ▼                                                    │ 有后端         │
  ┌──────────────────────┐   Pod 恢复 Ready / selector 修好   │ endpoints=N   │
  │ 无后端 <none>         │ ◄───────────────────────────────── │（N = 匹配且    │
  │ curl VIP 无响应或超时  │     Pod 掉 Ready / 进入 Terminating │  Ready 的 Pod  │
  │（iptables 规则链空转） │     （删 Pod 立刻摘，不等 30s）      │  数，周期同步） │
  └──────────────────────┘                                    └───────┬───────┘
                                                                      │ kube-proxy watch
                                                                      ▼
                                                        改写本节点 iptables/ipvs 规则（数据面）
```

### ② 状态说明表

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
| --- | --- | --- | --- |
| 端点同步 | Endpoints/EndpointSlice 随 Pod 变化持续更新 | endpoints controller | 正常运转，不是问题态 |
| 有后端 | N 个合格地址在 Endpoints 里 | endpoints controller（控制面）+ kube-proxy（数据面） | 两层各一半：地址对但规则没更新（kube-proxy 挂） |
| 无后端 `<none>` | 0 个"匹配且 Ready"的 Pod | endpoints controller | selector 笔误、标签不匹配、Pod NotReady、selector 选错 namespace |

### ③ 最常见卡住场景（SCENARIOS.md §2 网络与 DNS）

- **VIP 不通、后端 Pod 全 Running**：`kubectl get endpoints <svc>` 是 `<none>`——五步法：describe svc → `get pods -l` → 比对 labels → 查 Ready → 核对 targetPort 语义（端口号 vs 端口名）。
- **endpoints 有值、Pod Running，curl 仍不通**：故障不在这张图里——换层直连 Pod IP 二分定位 CNI / NetworkPolicy / 目标端口。

### ④ 深入

五步排错法与 EndpointSlice 机制：[04-k8s/05 章](../04-k8s-fundamentals/05-service-and-dns.md) §5。

**从图中一眼看出的排障要点**：从 `<none>` 回来只有两条箭头（修 selector、让 Pod 重新 Ready），`get endpoints` 一条命令就能把"控制面选错后端"和"数据面不通"分流；摘与加不对称（删立刻摘、加等 readiness）正是滚动更新掉流量的结构性根源。

---

## 4. PVC / PV：Released 之后按 reclaimPolicy 分岔

### ① 状态图

```
# [图] PVC/PV：Bound 是双向锁；删 PVC 后 PV 的命运由 reclaimPolicy 决定
  kubectl apply pvc（请求 5Gi，RWO）
        │
        ▼
  ┌──────────────┐  动态：SC 的 provisioner 造出 PV ──► 进入匹配
  │ PVC Pending  │  静态：binder 挑 Available 的 PV
  └──────┬───────┘  匹配维度：容量 ≥ 请求 / AccessModes 兼容 / 同一个 SC
         │ WFFC 模式：还要等第一个消费者 Pod 出现才真正绑定
         ▼
  ┌──────────────┐ ◄──── claimRef 互相锁定 ────► ┌──────────────┐
  │  PVC Bound   │                              │   PV Bound    │
  └──────┬───────┘                              └──────┬───────┘
         │ kubectl delete pvc（用户动作）                │ claimRef 仍指着已不存在的 PVC
         ▼                                            ▼
  （PVC 对象消失）                              ┌──────────────┐
                                               │ PV Released  │──┬─ Retain：停在这等管理员
                                               └──────────────┘  │  （对象与数据都保留）
                                                                 ├─ Delete：provisioner 删
                                                                 │  后端卷 + PV 对象（不可逆）
                                                                 └─ Recycle：已废弃，
                                                                    新版本已移除回收器
  管理员复用 Retain 卷：清掉 claimRef ──► PV 回 Available ──► 可被新 PVC 绑定
```

### ② 状态说明表

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
| --- | --- | --- | --- |
| PVC Pending | 无 PV 可绑或等供给 | binder / provisioner（kube-controller-manager / CSI） | 集群没有默认 SC、storageClassName 不匹配（`""` 与省略语义不同）、WFFC 等 Pod、容量不足 |
| Bound（双侧） | PVC 与 PV 互相锁定 | — | 稳定态；想改只能扩容（只升不降） |
| PV Released | PVC 已删，PV 与数据仍在 | reclaimPolicy=Retain | 设计出的死胡同：等人工清 claimRef 才回 Available |
| PV 删除 | 后端卷与对象一起删 | reclaimPolicy=Delete 的 provisioner | 不可逆；生产删 PVC 前可在线把策略改成 Retain 兜底 |
| PVC Lost | 绑定的 PV 被管理员误删 | 病态 | 排障时才见 |

### ③ 最常见卡住场景（SCENARIOS.md §4 存储与中间件）

- **PVC 一直 Pending / 有 SC 也绑不上**：`kubectl get sc` + `describe pvc` 看 Events——SC 名不匹配与 WFFC 是两大主因。
- **Pod 卡 ContainerCreating 报 Multi-Attach error / Retain 的 PV 一直 Released**：RWO 卷未 detach（失联节点可强删 volumeattachment）；Released 需清 claimRef。

### ④ 深入

完整状态机、静态/动态供给时序、WFFC 调度拓扑、三种 reclaimPolicy 的对照实验：[04-k8s/07 章](../04-k8s-fundamentals/07-storage.md) §2 / §3 / §6 / §7。

**从图中一眼看出的排障要点**：Pending 只有向下一条箭头且全部依赖"别人先动"（造 PV 或等 Pod）；Released(Retain) 的出箭头画在人身上——没有控制器帮你复用；Delete 分岔是单行道，删 PVC 前先确认策略。

---

## 5. Node：健康轴与调度轴是两个正交开关

### ① 状态图

```
# [图] Node：健康轴（Ready↔NotReady）与调度轴（可调度↔封锁）独立翻转，可任意组合
  健康轴
  ┌────────┐   心跳超时（kubelet 默认 10s 上报，40s 没续上判死）  ┌──────────┐
  │ Ready  │ ────────────────────────────────────────────────► │ NotReady │
  └────────┘ ◄──────────────────────────────────────────────── └──────────┘
     ▲           kubelet / 容器运行时 / 节点网络恢复                  │
     │                                                             │ 存量 Pod 继续跑，但
     │                                                             │ 不能新建、删除无确认；
     │                                                             │ 再过 300s（默认
     │                                                             │ tolerationSeconds）
     │                                                             │ 开始被驱逐
  调度轴（cordon 只动这条轴，不动健康轴）
  ┌──────────────┐  kubectl cordon（置 unschedulable，  ┌────────────────────────┐
  │  可调度       │   调度器不再派新 Pod 到此）           │ Ready,Scheduling-      │
  └──────────────┘ ──────────────────────────────────►  │ Disabled（封锁）        │
        ▲                                            └───────────┬────────────┘
        │  kubectl uncordon（维护收尾）                            │ kubectl drain
        └────────────────────────────────────────────────────────┤（= cordon + 逐个 evict
                                                                 │  Pod，控制器在别的节点
                                                                 │  重建；evict 尊重 PDB，
                                                                 ▼  不满足则重试等待）
                                                          维护动作（重启运行时/升级内核…）
```

### ② 状态说明表

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
| --- | --- | --- | --- |
| Ready | 心跳正常、可接新 Pod | kubelet（心跳源） | — |
| NotReady | 40s 无心跳 | node lifecycle controller（判死方） | kubelet 挂、containerd 挂、CNI 挂（NetworkPluginNotReady）、断网/断电 |
| SchedulingDisabled | 封锁，新 Pod 不来 | 人（cordon / drain 第一步） | 维护完忘 uncordon |
| Draining（过程） | 存量 Pod 被逐个 evict | 人 + PDB + 各控制器 | DaemonSet（--ignore-daemonsets）、emptyDir（--delete-emptydir-data）、裸 Pod（--force）、PDB 不满足 |

### ③ 最常见卡住场景（SCENARIOS.md §1 集群与控制面）

- **drain 卡住不动**：三类默认报错对象各配一个放行参数；第四种是 PDB 卡着（`kubectl get pdb -A`）。
- **节点 40~60 秒变 NotReady**：40s 是判死窗口——`systemctl status kubelet` 查心跳源，存量业务不受影响是定位线索不是反证。

### ④ 深入

三命令语义边界、drain 放行参数、五层定位法与十大故障速查表：[05-cka/06 章](../05-cka/06-node-maintenance-troubleshooting.md) §1 / §1.1 / §2 / §3。

**从图中一眼看出的排障要点**："NotReady 但业务还在跑"走健康轴查 kubelet，"Ready 但 SchedulingDisabled"走调度轴一条 uncordon 解决——先看 `kubectl get nodes` 第二列再决定查哪边；NotReady→驱逐中间隔 300s，这段时间是抢修窗口。

---

## 6. HPA：扩容快、缩容慢的控制环

### ① 状态图

```
# [图] HPA：每 15s 一圈；指标取不到时环断在起点
        ┌────────────────────────────────────────────────────────┐
        │ HPA 控制器（默认 15s 一圈）                              │
        │ 读指标 → 期望副本 = ceil(当前副本 × 当前指标值 / 目标值)   │
        └───────┬────────────────────────────────────────────────┘
                │
     指标取不到  │ TARGETS 列 <unknown>/60%
     （环断在起点）▼ 不扩不缩，直到指标恢复
        ┌──────────────┐
        │  <unknown>   │ ◄── 修指标链路（装/通 metrics-server）是唯一出路；
        └──────────────┘     HPA 对象本身没坏，删了重建也没用
                │ 指标可用
       ┌────────┼─────────────────────┐
       ▼        ▼                     ▼
   指标超目标   变化在 ±10% 容差内      指标低于目标
       │        │                     │
       ▼        ▼                     ▼
  ┌─────────┐ ┌────────┐    ┌────────────────────┐
  │ 扩容     │ │ 不动   │    │ 缩容候选            │
  │ 立即写入 │ │（防抖） │    │ 回看 300s 稳定窗口  │
  └────┬────┘ └────────┘    │ 内的最小建议值      │
       │                    └─────────┬──────────┘
       │  窗口满且建议值仍低            │
       ▼                              ▼
  写 Deployment.spec.replicas（下一圈再读，闭环）
  手动 kubectl scale 改的 replicas 会被下一圈重算覆盖——两条互斥的管理路径别混用
```

### ② 状态说明表

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
| --- | --- | --- | --- |
| `<unknown>` | 指标取不到，环没有输入 | metrics-server（数据链路） | 未装 metrics-server、kubelet 10250 证书校验失败、Pod 没定义 resources.requests（百分比无从算）、聚合 API 不通 |
| 扩容 | 副本上调，立即生效 | HPA 控制器 | 集群资源不足——新 Pod 卡 Pending，问题转到 Pod 图 |
| 不动（容差内） | ±10% 内不动作 | HPA 控制器 | 预期行为，不是故障 |
| 稳定窗口 | 缩容回看 300s 内最小建议值 | HPA behavior | 看似"不缩容"，实际在等窗口；负载反复抖动会一直续期 |
| 已写入 | replicas 落到 Deployment | HPA → Deployment → RS → Pod | 手动 scale 被覆盖（见上图注） |

### ③ 最常见卡住场景（SCENARIOS.md §3 工作负载）

- **TARGETS `<unknown>` / 手动 scale 后副本又变回去**：前者查指标链路（`kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes` 验证聚合 API），后者是 HPA 周期重算的预期行为。
- **停压测后迟迟不缩容**：不是 bug——缩容必须熬满 300s 稳定窗口且只认窗口内最保守值。

### ④ 深入

指标源三组聚合 API、核心公式与 10% 容差、behavior 稳定窗口、metrics-server 安装：[04-k8s/04 章](../04-k8s-fundamentals/04-workload-controllers.md) §5。

**从图中一眼看出的排障要点**：`<unknown>` 只有"修指标链路"一条出箭头；扩容路径上没有任何等待框（快是故意的），缩容路径必经 300s 窗口（慢也是故意的）——不对称设计防的是打摆。

---

## 7. Job / CronJob：Active 是唯一活状态

### ① 状态图

```
# [图] Job：Active 是唯一"活"框，两个终态各有明确入箭头；CronJob 只是定时孵化 Job
  kubectl apply job（completions=N，parallelism=M，backoffLimit=6）
        │ job 控制器按 parallelism 建 Pod（restartPolicy 只能 OnFailure/Never）
        ▼
  ┌──────────────────────────────────────────────┐
  │ Active（succeeded < completions）             │◄──┐ Pod 成功一个：succeeded+1
  │ 同一时刻至多 M 个 Pod 在跑                      │───┘ 工作队列模式：成功一个补一个
  └──────┬───────────────────────┬───────────────┘
         │ succeeded = completions│ 失败累计 > backoffLimit
         ▼                        ▼ 或超过 activeDeadlineSeconds
  ┌──────────┐             ┌──────────┐
  │ Complete │             │  Failed  │─── ttlSecondsAfterFinished 后自动删（可选）
  └──────────┘             └──────────┘
         spec.suspend=true：Active 冻结，不建新 Pod（人设置，人解除）

  CronJob 层（在 Job 之上再包一个定时器）
  schedule 到点 ──► 孵化一个新 Job（进入上图）
      重叠策略 concurrencyPolicy：Allow（默认，并存）/ Forbid（上个没完就跳过）/ Replace（杀旧再跑）
      startingDeadlineSeconds：错过调度点多久内还补跑
      历史保留：successfulJobsHistoryLimit 默认 3 / failed 默认 1
```

### ② 状态说明表

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
| --- | --- | --- | --- |
| Active | 未完成且未超限 | job 控制器 | Pod 卡 Pending（资源/PVC）或反复失败重试（根因在 Pod 图） |
| Complete | 成功数 = completions | job 控制器 | — （终态） |
| Failed | backoffLimit 耗尽 或 超过 activeDeadlineSeconds | job 控制器 | 应用退出码非 0、任务卡死超时、旧版 sidecar 不退出 |
| Suspend | spec.suspend=true 冻结 | 人 | 忘了改回 false |

### ③ 最常见卡住场景（SCENARIOS.md §3 工作负载）

- **Job 一直不 Complete**：`kubectl logs` 查退出码非 0 且重试预算没耗尽（预算默认 6，够它慢耗很久）；旧版本 sidecar 不退出也算不成功。
- **CronJob 不触发**：时区（schedule 按 controller-manager 主机时区解释）与 startingDeadlineSeconds 错过；`describe cronjob` 看 LastScheduleTime。

### ④ 深入

四个参数语义、三种典型形态、CronJob 重叠策略：[04-k8s/04 章](../04-k8s-fundamentals/04-workload-controllers.md) §8。

**从图中一眼看出的排障要点**：卡 Active 时问题几乎总在下游 Pod 图（Job 控制器本身极少坏）；Failed 的两条入箭头要分清——backoffLimit 耗尽是"重试预算花完"（改应用），activeDeadlineSeconds 是"总时长超限"（任务卡死，查为什么慢）。

---

## 8. kubeadm 控制面证书：一年一轮回换

### ① 状态图

```
# [图] kubeadm 控制面证书：默认 1 年有效期；renew 与重启是必须连做的两步
  kubeadm init / join
        │ 用自签 CA 签出六张 apiserver 相关证书（/etc/kubernetes/pki）
        ▼
  ┌──────────┐  静态 Pod 启动时读文件加载进进程
  │  使用中   │ ──────────────────────────────────────────────┐
  └──────────┘                                               │ 时间流逝
        ▲    ▲                                               ▼
        │    │ kubeadm certs renew（到期前主动做）       ┌──────────────┐
        │    │ 重签出新文件——但只改文件，               │ 临期          │
        │    │ 进程内存里还是旧证书                      │ check-       │
        │    │                                           │ expiration   │
        │    │                                           │ 一张表看全部 │
        │    │                                           └──────┬───────┘
        │    │                                                  │ 放任不管
        │    │                                                  ▼
        │    │                                           ┌──────────────┐
        │    └────────────── crictl stop 重建静态 Pod      │ 已过期        │
        │      （进程重读新证书，轮换闭环）                  │ 症状按证书分布 │
        │                                                  │ CA→全组件失联 │
        └── 漏了 stop 这步 = 图中断开的两截：                │ apiserver→   │
            文件是新的、进程用的还是旧的                     │ kubectl refused│
                                                           │ client→401/403│
                                                           └──────────────┘
  边界：kubelet 自己的客户端证书在 /var/lib/kubelet/pki/，由 kubelet 自动轮换，
        kubeadm renew 不覆盖——"单节点 NotReady 但控制面证书都新"先查它
```

### ② 状态说明表

| 状态 | 含义 | 谁控制 | 常见卡住原因 |
| --- | --- | --- | --- |
| 签发 | init/join 自签，默认 1 年 | kubeadm | — |
| 使用中 | 静态 Pod 进程持有 | — | — |
| 临期 | notAfter 逼近 | 人（巡检发现） | 无巡检制度 → 直接掉进"已过期" |
| 已轮换 | renew 重签 + 静态 Pod 重建加载 | 人（renew + crictl stop 两步） | 只 renew 忘 stop → 症状依旧；kubeconfig 里旧副本需重拷 |
| 已过期 | 症状爆发 | — | x509 expired / 401/403 / 组件失联；CA 过期只能重签集群 |

### ③ 最常见卡住场景（SCENARIOS.md §1 集群与控制面）

- **所有组件同时失联，报 `x509: certificate has expired`**：`kubeadm certs check-expiration` 一张表定位，再按"症状→证书"表对号入座。
- **`certs renew all` 后症状没变**：静态 Pod 没重启（补 crictl stop）+ admin.conf 里是旧证书副本需重拷——两截断箭头都要接上。

### ④ 深入

六张证书用途表、check-expiration / renew 全流程、过期症状速查：[05-cka/05 章](../05-cka/05-secrets-and-cert-troubleshooting.md) §3 / §4 / §5。

**从图中一眼看出的排障要点**：这是八张图里唯一没有控制器救场的资源——所有转移箭头都握在人手里（巡检、renew、stop）；"renew → 重建静态 Pod"两个动作在图上是断开的两截，忘掉后半截就是本考点第一大坑。

---

## 收尾：八张图的共同规律

| 组件 | 最常卡的框 | 第一条命令 | 负责把它推出这个框的 |
| --- | --- | --- | --- |
| Pod | Pending | `kubectl describe pod <p>` 看 Events | kube-scheduler |
| Pod | CrashLoopBackOff | `kubectl logs --previous` | kubelet（自愈中，取证即可） |
| Deployment | Progressing 停滞 | `kubectl rollout status deploy/<d>` | deployment 控制器 + readiness 探针 |
| Service | Endpoints `<none>` | `kubectl get endpoints <svc>` | endpoints controller |
| PVC | Pending | `kubectl describe pvc` | binder / provisioner |
| Node | NotReady | `systemctl status kubelet`（节点上） | kubelet（心跳源） |
| HPA | `<unknown>` | `kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes` | metrics-server |
| Job | Active 不退 | `kubectl get pods -l job-name=<j>` | job 控制器（根因在 Pod 图） |
| 证书 | 已过期 | `kubeadm certs check-expiration` | 人 |

三条总结论：

1. **卡住 = 只有入箭头的框**。排障顺序永远是：确认框 → 查表找"负责推它的组件" → 去看那个组件的日志/状态，而不是反复删了重建对象（删 Pod 又冒新的、PVC 越删越乱，都是跟错误层较劲）。
2. **闭环 = 自愈**。CrashLoopBackOff、ImagePullBackOff、Endpoints 周期同步、HPA 每圈重算都在闭环里，时间会替你重试；要做的只是趁退避间隙把证据抓全。
3. **计时器决定"等多久才算卡"**：优雅退出 30s、心跳宽限 40s、NoExecute 驱逐 300s、HPA 缩容窗口 300s、滚动死线 600s。没超过对应计时器就继续等，超过了立刻按第 1 条查推进者。

## 延伸阅读

- Pod 生命周期（官方）：https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- Deployment 策略与进度管理：https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#strategy
- EndpointSlice 与端点同步：https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
- PV/PVC 生命周期与回收策略：https://kubernetes.io/docs/concepts/storage/persistent-volumes/#lifecycle
- 节点状态与心跳（Node condition）：https://kubernetes.io/docs/concepts/architecture/nodes/#condition
- HPA 与稳定窗口：https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- Job 生命周期与失败策略：https://kubernetes.io/docs/concepts/workloads/controllers/job/
- kubeadm 证书管理：https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
