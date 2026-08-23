# 07 · 存储体系：PV / PVC / StorageClass 与 CSI 的完整链路

> 模块：04-k8s-fundamentals ｜ 建议时长：4 小时 ｜ 关联认证：CKA-存储（约 10% 题量，PVC 创建/绑定/扩容是高频操作题）

## 学习目标

- 能解释 PV / PVC / StorageClass 三个对象各自的职责、作用域（集群级 vs 命名空间级）与为什么这样切分
- 能画出 PV 与 PVC 的状态机（Pending → Bound → Released），并说明每次状态迁移的触发者
- 能画出动静态两种供给的完整时序（PVC → SC → provisioner → PV → 绑定），据此解释"PVC 一直 Pending"的各种成因
- 能解释四种 AccessModes 到底限制的是什么（节点/ Pod 级挂载语义，而不是文件权限或安全边界）
- 能描述 CSI 的三类组件与 VolumeStage / VolumePublish 在一次挂载中的调用顺序
- 能解释 WaitForFirstConsumer 为什么存在，以及 reclaimPolicy 三种取值的实际后果并动手验证

## 1. 三个对象，三种职责

| 对象 | 作用域 | 谁创建 | 职责一句话 |
|---|---|---|---|
| PersistentVolume (PV) | 集群级 | 管理员静态创建，或 provisioner 动态创建 | "集群里真实存在的一份存储"（NFS 导出、一块云盘、一个目录），含容量/访问模式/后端参数 |
| PersistentVolumeClaim (PVC) | 命名空间级 | 用户/应用 | "我要多大、什么访问模式的存储"——纯申请单，不关心后端 |
| StorageClass (SC) | 集群级 | 管理员 | "这类申请单怎么被满足"——provisioner 是谁、什么参数、reclaimPolicy、绑定时机 |

切分的动机与 Service/Pod 的分离一致：用户不应也不需要知道存储后端细节（那是基础设施团队的事），但两边必须在 API 层面上对接——PVC 是接口，PV 是实现，SC 是"实现工厂"的说明书。Pod 通过 `volumes.persistentVolumeClaim.claimName` 引用 PVC，kubelet 负责把它挂进容器。

```
Pod --volumes[].persistentVolumeClaim--> PVC(命名空间内的申请单)
PVC --bind(双向锁定 claimRef)--> PV(集群级的真实存储) --动态创建/静态预置--> StorageClass
(StorageClass 说明这类申请单怎么被满足: provisioner / reclaimPolicy / bindingMode)
```

```bash
# [master] 本实验集群基线：kubeadm 装出来的集群默认没有任何 StorageClass
kubectl get sc        # No resources found —— 与 minikube/kind 不同, 动态供给需要自己装
```

## 2. 生命周期状态机

PV 与 PVC 各有一组 phase，两边通过 `claimRef` 互相锁定：

```
        PVC 状态机                          PV 状态机
   ┌──────────────┐                    ┌──────────────┐
   │   Pending    │  无可用 PV/等消费者 │  Available   │
   └──────┬───────┘  (provisioner 或    └──────┬───────┘
          │           binder 处理中)           │ binder 匹配容量/模式/SC
          ▼                                  ▼ │ claimRef 写入
   ┌──────────────┐     相互绑定        ┌──────────────┐
   │    Bound     │ ◄────────────────► │    Bound     │
   └──────┬───────┘                    └──────┬───────┘
          │ 用户 kubectl delete pvc            │ PVC 已删, claimRef 仍在
          ▼                                   ▼
   ┌──────────────┐                    ┌──────────────┐
   │ (对象消失)    │                    │  Released    │
   └──────────────┘                    └──────┬───────┘
          ▲                                   │ reclaimPolicy=Retain: 停在这等管理员
          │ PVC 找不到绑定的 PV                │ reclaimPolicy=Delete: provisioner 删后端卷+PV 对象
   ┌──────┴───────┐                    ┌──────────────┐
   │    Lost      │  (PV 被误删)        │ (对象消失)    │
   └──────────────┘                    └──────────────┘
```

关键认知：

- **Released 不等于删除**。PVC 删掉后，Retain 策略的 PV 带着 claimRef 进入 Released，谁也绑不上（claimRef 还指着已不存在的 PVC），必须人工清理后才能复用（见第 7 节实验）。
- **双向锁定**：Bound 之后两边互相记录对方，删除任意一边都会影响另一边进入下一状态。
- `Lost` 是病态（管理员删了还绑着的 PV），日常只会在排障时见到。

## 3. 静态绑定 vs 动态供给：两条完整时序

### 3.1 静态绑定（管理员先造 PV，用户再来申请）

```
管理员                     API server                PersistentVolumeBinder
  │ kubectl apply pv          │                        (kube-controller-manager 内)
  ├──────────────────────────►│ PV: Available           │
  │                           │                        │
用户                           │                        │
  │ kubectl apply pvc         │                        │
  ├──────────────────────────►│ PVC: Pending            │
  │                           │──────watch 触发────────►│
  │                           │                        │ 遍历 Available PV:
  │                           │                        │   capacity ≥ 请求?
  │                           │                        │   accessModes ⊇ 请求?
  │                           │  bind(双向写 claimRef)  │   storageClassName 相同?
  │                           │◄───────────────────────┤   selector labels 匹配?
  │                           │ PVC: Bound, PV: Bound  │
  │ kubectl apply pod         │                        │
  ├──────────────────────────►│ 调度 → kubelet 按 PV 定义挂载 │
```

```yaml
# [master] kubectl apply -f - <<'EOF' —— 静态绑定三件套
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: manual
provisioner: kubernetes.io/no-provisioner   # 声明"本类不动态供给"
volumeBindingMode: WaitForFirstConsumer
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-static-demo
spec:
  capacity:
    storage: 1Gi
  accessModes: [ReadWriteOnce]
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual          # 与 PVC 的 storageClassName 对齐才能配对
  hostPath:
    path: /data/pv-static-demo      # 单 master 实验集群, Pod 只会落在 master 上
    type: DirectoryOrCreate
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-static
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 512Mi
  storageClassName: manual
EOF
```

```bash
# [master] 观察：WFFC 下 PVC 停在 Pending, 直到有 Pod 消费它(见第 6 节)
kubectl get pvc pvc-static        # STATUS Pending
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: app-static
spec:
  volumes:
  - name: data
    persistentVolumeClaim: {claimName: pvc-static}
  containers:
  - name: busybox
    image: busybox:1.36
    command: ["sh", "-c", "echo hello-static > /data/out.txt && sleep 3600"]
    volumeMounts:
    - {name: data, mountPath: /data}
EOF
kubectl get pvc pvc-static        # STATUS Bound
kubectl get pv pv-static-demo -o jsonpath='{.status.phase}{"\n"}'   # Bound
kubectl exec app-static -- cat /data/out.txt          # hello-static
ls /data/pv-static-demo                                # 宿主机目录里就是同一个文件
```

### 3.2 动态供给（用户只写 PVC，SC 找工厂生产）

```
用户                API server            PVC 控制器/kube-scheduler        provisioner( CSI sidecar )
 │ kubectl apply pvc     │                        │                          │
 ├──────────────────────►│ PVC: Pending           │                          │
 │                       │───────────────────────►│ 发现无可用 PV,在 PVC 上写 │
 │                       │                        │ annotation: storage-     │
 │                       │                        │ provisioner=<SC的值>     │
 │                       │                        │──────watch 匹配 SC──────►│
 │                       │                        │                          │ (WFFC: 先等调度器
 │                       │                        │                          │  在 PVC 打上 selected-node)
 │                       │                        │                          │ 调后端 API/SDK 建卷
 │                       │   create PV            │                          │
 │                       │◄────────────────────────────────────────────────┤
 │                       │ binder: PV(Available) ↔ PVC 匹配 → 双双 Bound    │
 │ kubectl apply pod     │                        │                          │
 ├──────────────────────►│  调度 → AD/kubelet 走 CSI 挂载流水线(第 5 节)      │
```

实验环境里最省事的动态 provisioner 是 local-path-provisioner（基于节点目录，行为足够真实：有 CSI 式生命周期、支持 WFFC/Retain）：

```bash
# [master] 安装（版本以官方仓库 release 为准）
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml
kubectl -n local-path-storage wait --for=condition=Available deployment/local-path-provisioner --timeout=300s
kubectl get sc local-path -o yaml | grep -E 'provisioner|reclaimPolicy|volumeBindingMode'
# provisioner: rancher.io/local-path
# reclaimPolicy: Delete
# volumeBindingMode: WaitForFirstConsumer
```

## 4. AccessModes：到底限制的是什么

| 缩写 | 全称 | 语义（限的是"谁能以什么模式挂载"） | 常见后端 |
|---|---|---|---|
| RWO | ReadWriteOnce | **单个节点**可读写挂载；该节点上可以同时有多个 Pod 挂它 | 块设备卷：云盘、local、Longhorn 副本 |
| ROX | ReadOnlyMany | **多个节点**可同时只读挂载 | NFS、部分文件系统 |
| RWX | ReadWriteMany | **多个节点**可同时读写挂载 | NFS、CephFS、云文件存储 |
| RWOP | ReadWriteOncePod | **单个 Pod** 可读写挂载（全集群独占；v1.29 GA），RWO 的更严格版 | 同 RWO；用于必须独占的卷（如本地数据库） |

三个必须钉死的认知：

1. **限制的是节点/Pod 级的挂载行为，不是文件级权限**。RWO 防的是"两个节点同时以读写挂同一块 ext4/xfs 导致文件系统损坏"，它不提供任何 ACL 语义，也不是安全边界（CKS 视角：真正的隔离靠 SELinux/AppArmor/Pod Security Admission）。
2. **RWO 限制的是节点数，不是 Pod 数**。同一节点上 5 个 Pod 同时读写挂同一个 RWO 卷，Kubernetes 不会阻止，数据是否安全取决于应用（多进程写同一文件系统本就是合法操作）。
3. **AccessModes 是 PV 声明的能力集合，PVC 是需求**。binder 要求 PV 的模式集合覆盖 PVC 请求的模式；最终挂载按 PVC 的模式执行。真正的强制发生在 AD controller/kubelet 的 attach/mount 阶段——第二个节点试图以 RW 挂一个已被别的节点 RWO 挂载的卷时，操作被拒绝，典型症状是 Pod 卡 `ContainerCreating`、事件里出现 `Multi-Attach error`。

```bash
# [master] 日常查询：每个 PV 支持哪些模式一目了然（MODES 列）
kubectl get pv
```

## 5. CSI 架构：三类组件与一次挂载的调用序列

CSI（Container Storage Interface）是把"存储驱动"从 Kubernetes 内核里拆出来的标准 gRPC 接口——任何存储厂商实现一次，就能被任何 CSI 兼容的编排系统（K8s/Nomad/其它）使用。一个 CSI 驱动部署到集群里，永远由三类组件构成：

```
┌──────────────────── K8s 控制面与 kubelet ────────────────────────────┐
│  API 对象: PVC / PV / StorageClass / VolumeAttachment / CSIDriver /  │
│           CSINode          kubelet VolumeManager(每节点)              │
└──────▲───────────────────────────────▲──────────────────────────────┘
       │ watch + 转换为 gRPC 调用        │ gRPC (unix domain socket)
┌──────┴─────────────────┐   ┌─────────┴──────────────────────────────┐
│ ① Controller Plugin    │   │ ② Node Plugin (DaemonSet, 每节点一份)   │
│   (Deployment)         │   │   实现 NodeStage/NodePublish 等          │
│   实现 CreateVolume/   │   │   + node-driver-registrar sidecar        │
│   ControllerPublish    │   │     (向 kubelet 注册 socket 与驱动信息)    │
│   外挂 sidecar:        │   │   + livenessprobe sidecar                │
│   external-provisioner │   └─────────────────────────────────────────┘
│   external-attacher    │
│   external-resizer     │   ┌─────────────────────────────────────────┐
│   external-snapshotter │   │ ③ 存储后端 (NFS server/Ceph/云盘/本机目录) │
└──────┬─────────────────┘   └─────────────────────────────────────────┘
       │ 厂商 SDK/API
       ▼
```

- **① Controller 侧**：Deployment 跑驱动 Controller 服务 + 一堆 external-* sidecar。sidecar 负责"watch K8s 对象 → 调用驱动的 gRPC"：provisioner 盯 PVC 建卷、attacher 盯 VolumeAttachment 做盘的 attach/detach、resizer 盯 PVC 扩容、snapshotter 盯 VolumeSnapshot。
- **② Node 侧**：DaemonSet 跑驱动 Node 服务，通过 unix socket 接 kubelet 的调用；node-driver-registrar 把驱动注册进 kubelet（信息汇总为集群的 CSINode 对象）。
- **③ 后端**：真正的存储系统。前两者只是适配层。

一次 Pod 挂载 CSI 卷的完整调用序列（local-path 等简化驱动会合并步骤，但语义一致）：

```
Pod 调度到 node-1
  │ ① kube-controller-manager(AD controller) 创建 VolumeAttachment 对象
  │ ② Controller 侧 external-attacher watch 到 → 调 ControllerPublishVolume
  │      "把卷 X attach 到 node-1" → 后端把设备/导出映射到该节点
  │ ③ kubelet VolumeManager 调 Node 插件:
  │      NodeStageVolume   ← 每卷每节点一次: 格式化 + 挂到节点级暂存目录
  │        /var/lib/kubelet/plugins/kubernetes.io/csi/<driver>/<volID>/globalmount
  │ ④    NodePublishVolume ← 每卷每 Pod 一次: 把 globalmount bind-mount 到
  │        /var/lib/kubelet/pods/<pod-uid>/volumes/kubernetes.io~csi/<volID>/mount
  │ ⑤ 容器启动, 该目录再 bind 进容器挂载点 (mountPath)
  ▼
卸载为逆序: NodeUnpublish → NodeUnstage → (Pod 删除)
           → ControllerUnpublishVolume(detach) → DeleteVolume(仅当 reclaimPolicy=Delete 且 PVC 已删)
```

Stage 与 Publish 拆成两步是性能设计：一个卷被同节点 10 个 Pod 挂载时，格式化和设备挂载（贵）只做一次（Stage），每个 Pod 只需一次 bind mount（便宜）。

```bash
# [master] 亲手看一遍证据链（local-path 不是 CSI 驱动, 本实验集群输出可能为空;
#          这些命令留给你在有 CSI 驱动的集群里对照）
kubectl get csidriver                 # 集群注册了哪些 CSI 驱动
kubectl get csinode                   # 每个节点有哪些驱动 socket
kubectl get volumeattachment          # 谁在 attach(块存储才有)
ls /var/lib/kubelet/plugins/kubernetes.io/csi/ 2>/dev/null   # 节点级暂存目录
```

## 6. WaitForFirstConsumer 与调度拓扑

SC 的 `volumeBindingMode` 两个取值，决定"建卷发生在调度之前还是之后"：

```
volumeBindingMode: Immediate（先建卷, 后调度）
  PVC 创建 ──► provisioner 立刻建卷, 落在 zone-a ──► PV Bound(zone-a)
  Pod  创建 ──► 调度器发现唯一满足 CPU/内存的节点在 zone-b
              ──► 卷拓扑不允许跨 zone 挂载 ──► Pod 永远 Pending（卷已花钱, 却没人能用）

volumeBindingMode: WaitForFirstConsumer（先调度, 后建卷）
  PVC 创建 ──► PVC 停在 Pending, provisioner 按兵不动
  Pod  创建 ──► 调度器综合考虑"Pod 资源 + PVC 的拓扑约束", 选中 node-2(zone-b)
              ──► 在 PVC 上打标注 volume.kubernetes.io/selected-node=node-2
  provisioner 读到标注 ──► 按 node-2 所属拓扑(zone-b)建卷 ──► PV Bound ──► Pod 启动
```

WFFC 的本质：**让卷的拓扑决策服从调度的拓扑决策**。凡是后端卷有"位置属性"的（云上的 zonal 磁盘、local PV、local-path 这类节点本盘），都必须用 WFFC，否则会造出"Pod 永远挂不上"的死局。它也解释了 3.1 实验里的现象：静态 PV + WFFC 时，PVC 在 Pod 出现前一直 Pending——不是故障，是设计。

```bash
# [master] 复现并解释 WFFC 行为（local-path 就是 WFFC）
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-wffc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: local-path
  resources:
    requests:
      storage: 128Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: app-wffc
spec:
  volumes:
  - name: data
    persistentVolumeClaim: {claimName: pvc-wffc}
  containers:
  - name: busybox
    image: busybox:1.36
    command: ["sh", "-c", "echo wffc-ok > /data/f && sleep 3600"]
    volumeMounts:
    - {name: data, mountPath: /data}
EOF
kubectl get pvc pvc-wffc -w    # Pending → Bound, 触发点正是 Pod 完成调度的瞬间
kubectl get pvc pvc-wffc -o jsonpath='{.metadata.annotations}{"\n"}' | tr ',' '\n' | grep -i selected-node
```

## 7. reclaimPolicy：三种取值与验证

| 取值 | PVC 被删后 | 后端数据 | 适用 |
|---|---|---|---|
| Retain | PV 进 Released，对象与数据都保留 | 保留 | 生产默认保险；需人工确认后再清理 |
| Delete | provisioner 删后端卷 + PV 对象 | **永久删除** | 动态供给的默认；CI/临时环境 |
| Recycle | 已废弃（scrub 后复用，新版本已移除回收器） | — | 不要再用 |

实验建议（完整走一遍 Retain 与 Delete 的分岔）：

```bash
# [master] local-path 自带的 SC(local-path) 就是 Delete 策略, 只需再造一个 Retain 的对照组
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: lp-retain
provisioner: rancher.io/local-path
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
EOF
kubectl get sc -o custom-columns='NAME:.metadata.name,POLICY:.reclaimPolicy,BINDING:.volumeBindingMode'
```

```bash
# [master] 各建一对 PVC+Pod, 写入标记文件（local-path=Delete 臂, lp-retain=Retain 臂）
for sc in local-path lp-retain; do
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-$sc
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: $sc
  resources:
    requests:
      storage: 128Mi
---
apiVersion: v1
kind: Pod
metadata:
  name: app-$sc
spec:
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: pvc-$sc
  containers:
  - name: busybox
    image: busybox:1.36
    command: ["sh", "-c", "echo $sc > /data/tag && sleep 3600"]
    volumeMounts:
    - {name: data, mountPath: /data}
EOF
done
kubectl get pvc,pod -o wide | grep -E 'lp-|local-path|NAME'

# [master] 同时删除两个 Pod 和 PVC, 观察 PV 命运分岔
kubectl delete pod app-local-path app-lp-retain --wait=false
kubectl delete pvc pvc-local-path pvc-lp-retain
kubectl get pv -w >/tmp/pv-watch.log 2>&1 &    # Delete 臂的 PV 直接消失; Retain 臂的 PV 变成 Released
WATCH_PID=$!; sleep 5; kill "$WATCH_PID"; cat /tmp/pv-watch.log

# [master] Retain 的收尾三步（管理员手工动作）
PV=$(kubectl get pv -o jsonpath='{.items[?(@.status.phase=="Released")].metadata.name}')
ls /opt/local-path-provisioner/ | tail -2        # 后端目录还在, 数据可救
kubectl patch pv "$PV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Delete"}}'  # 改成 Delete 让 provisioner 清理
kubectl get pv; ls /opt/local-path-provisioner/ | tail -2                        # PV 与目录都没了
```

```bash
# [master] 生产救命招：回收策略可以在线改（例如误用了 Delete, 删 PVC 前改成 Retain）
BOUNDPV=$(kubectl get pv -o jsonpath='{.items[?(@.status.phase=="Bound")].metadata.name}' | cut -d' ' -f1)
kubectl patch pv "$BOUNDPV" -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'

# [master] Released 的 PV 想再次利用（例如恢复数据后再给新 PVC 绑）：清掉 claimRef 即回到 Available
REL=$(kubectl get pv -o jsonpath='{.items[?(@.status.phase=="Released")].metadata.name}')
kubectl patch pv "$REL" -p '{"spec":{"claimRef":null}}'
kubectl get pv "$REL"   # Available —— 可被同规格的新 PVC 抢先绑定
```

```bash
# [master] 本章清理（含第 3、6、7 节全部实验对象）
kubectl delete pod app-static app-wffc app-local-path app-lp-retain --ignore-not-found --wait=false
kubectl delete pvc pvc-static pvc-wffc pvc-local-path pvc-lp-retain --ignore-not-found
kubectl delete sc manual lp-retain --ignore-not-found
kubectl delete pv pv-static-demo --ignore-not-found
kubectl delete -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.30/deploy/local-path-storage.yaml --ignore-not-found
rm -rf /data/pv-static-demo /opt/local-path-provisioner /tmp/pv-watch.log
```

## 实战演练

各节动手内容串成一条完整实验流（单 master kubeadm + Calico 集群即可完成）：

1. 确认基线：`kubectl get sc` 为空 → 印证"kubeadm 集群没有动态供给" → 第 1 节
2. 安装 local-path-provisioner，读 SC 的三个关键字段 → 第 3.2 节
3. 静态绑定三件套（SC manual + PV hostPath + PVC），观察 WFFC 下 PVC 等 Pod 才 Bound，`kubectl exec` 读回写入的文件，再到宿主机目录看到同一文件 → 第 3.1 节
4. 对照 `kubectl get pv` 的 MODES 列理解四种 AccessModes → 第 4 节
5. WFFC 实验：PVC Pending → 建 Pod → 瞬间 Bound，抓 `selected-node` 注解 → 第 6 节
6. reclaim 实验：Delete 臂 PV 消失、Retain 臂停在 Released；在线 patch 回收策略、清 claimRef 复用 PV → 第 7 节
7. 最后执行第 7 节末尾的清理块

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| PVC 一直 Pending | 三选一：没有匹配的静态 PV / 集群没有 SC（kubeadm 默认没有）/ WFFC 在等第一个消费者 | `kubectl get sc`；`kubectl describe pvc` 看 Events；WFFC 场景先建 Pod |
| 有 SC、PV 也有，就是绑不上 | PVC 的 `storageClassName` 与 PV 的对不上（注意空字符串语义不同） | `""` 表示"只匹配没有 SC 的静态 PV、禁用动态供给"；省略字段则用默认 SC |
| Pod 卡 ContainerCreating，事件报 Multi-Attach error | RWO 卷已被另一节点挂载（前一个节点未正常 detach） | 等 detach 完成；节点失联时可能需要强制删除 volumeattachment；根本上是 RWO 的节点独占语义 |
| 删了 PVC 但数据还想找回 | reclaimPolicy=Delete 已把后端卷删了 | 只能靠备份；重要数据把 SC/PV 的策略设为 Retain |
| Retain 的 PV 一直 Released 没人管 | 设计如此：claimRef 仍指向已删除的 PVC | 清 claimRef 复用，或改 Delete 让 provisioner 清理（见第 7 节） |
| PVC 扩容报错 | SC 未开 `allowVolumeExpansion: true`；或试图缩容（不支持） | 给 SC 加该字段并重试；只升不降 |
| hostPath 直接写进 Pod | 绕过了整个 PV 体系：不进生命周期、不可迁移，restricted PSA 直接禁止 | 学习/单机除外，一律走 PV/PVC；CKS 视角 hostPath 是高危面 |
| local-path 的数据目录爆盘 / WFFC 下 PVC 长期 Pending 被误判故障 | 数据默认落在节点 /opt/local-path-provisioner（根分区）；WFFC 的"等第一个消费者"语义没被理解 | 改其 ConfigMap 的 nodePathMap 指到大盘目录；WFFC 属特性，要立即建卷就用 Immediate（拓扑安全自负责） |

## 自测

<details><summary>1. PVC Pending 有哪两大类成因？分别用什么命令在 30 秒内区分？</summary>

第一类：供需不匹配——无匹配 PV、无 SC、accessModes/容量/selector 不符。第二类：WFFC 在等第一个消费者——PVC 本身没问题，只是 Pod 还没来。区分：`kubectl get sc` 看 volumeBindingMode；`kubectl describe pvc <name>` 的 Events（第一类会有 failed to provision / no volumes available 之类事件，第二类通常安静无事件）；再 `kubectl get pod | grep -c Pending` 看是否有引用它的 Pod。3.1 与第 6 节实验分别复现了两类。
</details>

<details><summary>2. PVC 里 `storageClassName: ""`（空字符串）与完全不写这个字段，行为差在哪？</summary>

空字符串是显式声明"禁用动态供给，只匹配那些同样没有 SC 名字的静态 PV"——这是静态绑定场景的正确写法（新版里静态 PV 与 PVC 双方都写 `""` 或双方写同一个不存在的 SC 名也可配对）。完全不写则每次创建时被 admission 补成**默认 SC 的名字**（集群有默认 SC 时），走动态供给；集群没有默认 SC 时按空处理。一个字符的差别决定了"找现成的"还是"下订单生产"，是静态绑定实验最常见的翻车点。
</details>

<details><summary>3. NodeStageVolume 和 NodePublishVolume 为什么拆成两步？如果合成一步，同节点 20 个 Pod 挂同一个卷会发生什么？</summary>

Stage 是"卷级、节点级"的昂贵操作：识别设备、格式化、挂到节点级暂存目录（globalmount），每个卷每节点只需一次。Publish 是"Pod 级"的廉价操作：把 globalmount bind-mount 到 Pod 的卷目录。合并成一步的话，20 个 Pod 就要重复 20 次设备挂载/格式化判断——既慢又有竞态（并发 mkfs 风险）。分层设计与 Linux 全局挂载 + bind mount 的传统手法同源。
</details>

<details><summary>4. WFFC 模式下 scheduler 往 PVC 上写了什么？provisioner 拿它做什么？如果跳过这一步（Immediate）在多 zone 集群里会出什么死局？</summary>

调度器选好节点后给 PVC 打 `volume.kubernetes.io/selected-node` 注解；provisioner 由此推断卷应创建的拓扑域（节点/zone），调 CreateVolume 时带 topology 参数，保证"卷一定在被选节点可达的位置"。Immediate 的死局：卷先被创建在 zone-a，Pod 调度时却因资源约束只能落 zone-b，zonal 卷不可跨 zone attach，Pod 永远 Pending——钱花了、卷废了，只能删卷重来。
</details>

<details><summary>5. 团队把生产数据库的 PVC 误删了，reclaimPolicy=Delete。复盘时你能给出哪两条预防措施？</summary>

（1）策略前置：数据库类 SC 单独建一份 `reclaimPolicy: Retain`，或至少在删 PVC 前对已 Bound 的 PV 在线 patch 成 Retain（回收策略随时可改），让删除动作停在第一个人工关口。（2）备份侧兜底：PV 不是备份，数据库要有独立备份链路（CSI VolumeSnapshot 快照 + 异地备份），误删 PVC 丢的应该是"可用性"而不是"数据"。辅助手段：用 RBAC 收紧 delete pvc 权限、用 admission 策略保护带特定 label 的 PVC。
</details>

## 延伸阅读

- Persistent Volumes 官方概念（含状态机与 reclaimPolicy）：https://kubernetes.io/docs/concepts/storage/persistent-volumes/
- StorageClass 与 volumeBindingMode：https://kubernetes.io/docs/concepts/storage/storage-classes/
- 动态供给机制说明：https://kubernetes.io/docs/concepts/storage/dynamic-provisioning/
- CSI 官方文档（架构、sidecar、开发指南）：https://kubernetes-csi.github.io/docs/
- 卷类型与挂载流程（kubelet 卷管理器）：https://kubernetes.io/docs/concepts/storage/volumes/
- local-path-provisioner 仓库：https://github.com/rancher/local-path-provisioner
