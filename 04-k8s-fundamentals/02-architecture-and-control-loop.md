# 02 · 架构与控制循环：控制面四组件、list-watch 与 kubelet

> 模块：04-k8s-fundamentals ｜ 建议时长：3 小时 ｜ 关联认证：CKA-集群架构·故障排查 / CKS-集群加固

## 学习目标

- 能画出控制面组件与节点组件的数据流图，并解释"只有 kube-apiserver 读写 etcd"
- 能解释 etcd RAFT 多数派原理，以及为什么成员数必须是奇数
- 能解释 kube-scheduler 两阶段决策与 Binding 写回、controller-manager 的"多循环合一"
- 能解释 list-watch / Informer 为什么是增量推送而非轮询，以及 resourceVersion 的作用
- 能排查静态 Pod、kubelet（PLEG/CRI）与控制面证书类故障

## 1. 全景：一次调度的旅程

```
# [图] 控制面与节点组件全景（kubeadm 单 master 集群）
                          ┌────────────────── control-plane 节点 ──────────────────┐
   kubectl ──HTTPS:6443──►│ kube-apiserver ◄──► etcd (状态唯一存储)                 │
                          │     ▲    ▲                                             │
                          │     │watch│watch                                       │
                          │ kube- │ kube-controller-manager (几十个控制循环)        │
                          │ scheduler (只写 Binding)                               │
                          └──────────┬─────────────────────────────────────────────┘
                                     │ watch Pod(带 nodeName) / 上报 NodeStatus:6443
                          ┌──────────▼───────────── worker 节点 ───────────────────┐
                          │ kubelet ──CRI(gRPC)──► containerd ──► 容器(含 pause)   │
                          │ kube-proxy(iptables/ipvs)  CNI(Calico)                 │
                          └────────────────────────────────────────────────────────┘
```

三条铁律，先记住再看细节：

1. **etcd 只被 kube-apiserver 访问**。scheduler、controller-manager、kubelet 全部通过 apiserver 的 REST API 工作，没有谁绕过它直连 etcd。
2. **控制面组件之间互相不通信**。scheduler 和 controller-manager 互不知晓对方存在，它们只 watch apiserver 里自己关心的对象。组件间解耦的介质就是 API 对象本身。
3. **控制面从不直接碰容器**。创建容器的唯一路径是 kubelet → 容器运行时。控制面连节点都是"被动"访问的（exec/logs 时 apiserver 才主动连 kubelet 的 10250）。

## 2. kube-apiserver：唯一的状态入口

kube-apiserver 是无状态的（状态全在 etcd），因此可以多副本 + LB 横向扩展。它对一个写请求的处理链：

```
# [图] apiserver 请求处理链
请求 ──► ① 认证 Authentication (客户端证书/token/OIDC → 你是谁)
     ──► ② 授权 Authorization  (RBAC/Node/Webhook → 能不能做)
     ──► ③ 准入 MutatingWebhook + 内置默认值改写 (对象可被改)
     ──► ④ Schema 校验 + ValidatingWebhook (对象必须合法)
     ──► ⑤ 乐观并发检查 (resourceVersion 是否仍是别人改之前的)
     ──► ⑥ 写入 etcd (RAFT 提交后返回 201/200)
```

两个排障相关的行为：

- **读路径带缓存**：apiserver 内部有 watch cache，大部分 list/get 请求直接从内存应答，不落 etcd。所以 etcd 慢不一定等于 kubectl get 慢。
- **watch 是长连接**：HTTP chunked 响应持续推送。apiserver 会主动掐断长连接以防负载不均——连接存活时间在 `--min-request-timeout`（默认 1800s）与其 2 倍之间随机，客户端必须能断线重连（见第 6 节）。

```bash
# [master] 看 apiserver 静态 Pod 里的关键参数
sudo cat /etc/kubernetes/manifests/kube-apiserver.yaml | grep -E 'etcd-servers|secure-port|service-cluster-ip-range'
# 预期: --etcd-servers=https://127.0.0.1:2379 等
```

## 3. etcd：RAFT 多数派

etcd 是强一致的分布式 KV 存储，K8s 所有对象的唯一真身都在这里（键形如 `/registry/pods/default/<pod-name>`）。一致性由 RAFT 协议保证：

- 写请求转发给 leader，leader 先写本地日志，再并行发给所有 follower；
- **多数派（quorum = N/2 + 1）确认后**才算提交（commit），然后应应用户；
- 任一时刻多数派存活，集群就能继续服务；丢失多数派，etcd 拒绝写入（不是降级，是不可用）——这是保护数据一致性的正确行为。

| 成员数 | 多数派 | 可容忍故障成员 | 结论 |
| --- | --- | --- | --- |
| 1 | 1 | 0 | 实验环境 |
| 2 | 2 | 0 | 比 1 更差：多花一台机器，容错仍为 0 |
| 3 | 2 | 1 | 生产最小规格 |
| 4 | 3 | 1 | 容错与 3 相同，写吞吐反而更低 → 不要用 |
| 5 | 3 | 2 | 大规模生产 |

这就是"etcd 成员数永远取奇数"的原因：偶数成员只增加写延迟，不增加容错。

etcd 还提供两个上层依赖的特性：**MVCC + 全局单调递增的 revision**（这是 resourceVersion 的来源，见第 6 节）和 **watch**（监听某个 key 前缀的变更）。

```bash
# [master] 在 etcd 静态 Pod 里执行 etcdctl（kubeadm 集群 etcd 监听 127.0.0.1:2379）
kubectl -n kube-system exec etcd-$(hostname) -- sh -c \
  "ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key \
   --endpoints=https://127.0.0.1:2379 endpoint status -w table"
# 预期输出含 DB SIZE / RAFT TERM / LEADER 列; 单成员集群 IS LEADER=true

# [master] 直接看对象在 etcd 里的键名
kubectl -n kube-system exec etcd-$(hostname) -- sh -c \
  "ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key \
   --endpoints=https://127.0.0.1:2379 get /registry/deployments/ --prefix --keys-only | head -4"
```

快照备份/恢复与压缩（`snapshot save`、`compact`、`defrag`）在 `05-cka/04-etcd-backup-restore.md` 专门展开。

## 4. kube-scheduler：两阶段决策

scheduler 的工作被刻意设计得极窄：**给没有 nodeName 的 Pod 挑一个节点，并把结果写回 apiserver**。它不创建容器、不管副本数。流程：

```
# [图] 调度两阶段
Pod 队列(spec.nodeName 为空)
   │
   ▼ ① Filter 过滤(老文档叫 Predicates): 硬条件淘汰
   │   资源够不够 / 端口冲突 / 节点亲和(nodeAffinity required) /
   │   污点容忍(taint/toleration) / 卷拓扑
   ▼ ② Score 打分(老文档叫 Priorities): 软条件排序
   │   资源均衡度 / 副本打散 / 节点亲和 preferred / image 本地缓存
   ▼ 选出得分最高的节点
   │
   └──► 向 apiserver POST 一个 Binding 对象 {podName, targetNode}
        → apiserver 把 spec.nodeName 写进 Pod → 该节点 kubelet 接手
```

补充三个实战要点：

- **两阶段失败的处理不同**：Filter 全军覆没 → Pod 留在 `Pending`，事件是 `FailedScheduling`（`0/1 nodes are available: ...`，这句后面直接给出被淘汰的原因）；Score 平分 → 随机选一个。
- **队列与重试**：调度失败的 Pod 进入 unschedulable 队列退避等待；只有集群发生变化（新节点、Pod 删除释放资源、标签/污点改动）才会被重新唤醒——所以"删了一个大 Pod，Pending 的 Pod 过一会儿才调度"是正常现象。
- **scheduler 挂了的世界**：已运行的 Pod 不受任何影响（没有它也照常跑），只是新 Pod 全部 `Pending`。这是判断"控制面坏了还是节点坏了"的重要线索。

## 5. kube-controller-manager：几十个循环的集合

kube-controller-manager 不是单一控制器，而是一批控制器进程的合集，共享同一个进程内的 shared informer 缓存：

| 分类 | 控制器（示例） | 职责 |
| --- | --- | --- |
| 工作负载 | deployment、replicaset、statefulset、daemonset、job、cronjob | 第 04 章全部展开 |
| 网络 | endpoint、endpointslice、endpointslicemirroring | 维护 Service ↔ Pod IP 映射 |
| 节点 | node-lifecycle | 节点失联后打污点、驱逐 Pod |
| 命名空间 | namespace | 创建默认对象、级联删除 |
| 清理 | garbage-collector、pod-garbage-collector | ownerReferences 级联删除 |
| 存储 | persistentvolume-binder、attach-detach | PVC/PV 绑定与挂载 |
| 其他 | serviceaccount、horizontalpodautoscaling、cloud-node-lifecycle | 各司其职 |

```bash
# [master] 查看默认启用了哪些控制器
kubectl -n kube-system get pod -l component=kube-controller-manager -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep controllers || echo "(未显式指定 --controllers, 默认启用全部)"
# 可用 --controllers=-foo 的形式禁用单个控制器(如排障时关掉 garbage-collector)
```

两个 HA 相关行为：多副本部署时通过 `kube-system` 里的 **Lease 对象选主**（`kubectl -n kube-system get lease` 可见 kube-controller-manager 与 kube-scheduler 两条），同一时刻只有一个实例在干活，其余热备；所以它挂了不会立刻丢功能，但持续宕机意味着"没人 reconcile"，集群会慢慢偏离期望状态。

## 6. list-watch 与 Informer：为什么增量、不轮询

假设集群有 30 个控制器 + 每个节点上的 kubelet 都需要感知 Pod 变化。若用轮询（每秒 list 一次全量 Pod）：

```
# [图] 轮询 vs list-watch 的请求量
轮询: 300 客户端 × 每秒 1 次 list × 5000 个 Pod 的全量序列化
      = apiserver 每秒要序列化 150 万个对象 → 直接被打死

list-watch: 每客户端启动时 1 次 list(全量) + 之后只收增量事件
           对象不变 = 0 流量; 对象变 = 只传变化的那 1 个
```

### 6.1 watch 的事件流

`GET /api/v1/pods?watch=true&resourceVersion=<rv>` 建立长连接后，apiserver 推送：

| 事件类型 | 含义 |
| --- | --- |
| ADDED | 新对象 |
| MODIFIED | 对象被修改 |
| DELETED | 对象被删除 |
| BOOKMARK | 只有 resourceVersion 的"书签"，专门用来让客户端定期保存最新 RV |
| ERROR | 出错（典型：410 Gone，见下） |

### 6.2 resourceVersion 与断线重连

- 每个对象的 `metadata.resourceVersion` 来自 etcd 的全局 revision，**任何一次修改都会变化**；
- 客户端记录断线前见到的最大 RV，重连时带上：`watch=true&resourceVersion=<rv>`，apiserver 只补发这之后的事件；
- 若该 RV 已被 etcd 压缩（compact）掉，apiserver 返回 **410 Gone**，客户端的处理是固定的：**重新 list 全量，再从新的 RV 继续 watch**；
- 所以 Informer 的正确性不依赖连接不断，而依赖"list 建立基线 + 增量追赶 + 410 兜底重置"。

### 6.3 Informer：把 list-watch 封装成本地缓存

client-go 的 Informer 是所有控制器的标准底座：

```
# [图] Informer 内部结构
                ┌───────────────────────────────────────────────┐
 apiserver ───► │ Reflector: list 一次 + 持续 watch             │
                └───────────────┬───────────────────────────────┘
                                ▼
                        DeltaFIFO（对同一对象的连续变更合并排队）
                                ▼
                ┌───────────────────────────────────────────────┐
                │ Local Store / Indexer: 本地全量缓存 + 索引     │
                │ 控制器读缓存 → 不打 apiserver                  │
                └───────────────┬───────────────────────────────┘
                                ▼
              OnAdd / OnUpdate / OnDelete 回调 → 控制器业务逻辑
              （另有周期性 resync：把缓存重放一遍，兜底错过的处理）
```

理解两点就够了：

1. **控制器 reconcile 时读的是本地缓存**，不是 apiserver——这就是几十个控制器共存却压不垮 apiserver 的原因。代价是缓存有秒级延迟：你刚 apply 完，控制器可能要过一瞬间才"看到"。
2. **shared informer**：controller-manager 进程内多个控制器共享同一份 Pod 缓存，一份 watch 养活所有控制器。

```bash
# [master] 亲眼看到 resourceVersion 在跳: 终端 A 持续 watch
kubectl get pods -A -w -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,RV:.metadata.resourceVersion | head -20
# 另开终端 B 给任意 Pod 打个标签, 回到终端 A: 该 Pod 的 RV 变化会作为新事件出现
kubectl label pod -n kube-system -l component=kube-scheduler debug-marker=1 --overwrite
kubectl label pod -n kube-system -l component=kube-scheduler debug-marker- --overwrite
```

## 7. 静态 Pod：kubelet 的"私活"

静态 Pod 由 **kubelet 直接监视本地 manifest 文件创建**，绕过 apiserver 的调度，也不经过 scheduler。kubeadm 用它来跑控制面本身——鸡生蛋问题的解法：apiserver 还没起来之前，得有人把它拉起来。

- kubelet 监视 `staticPodPath`（kubeadm 默认 `/etc/kubernetes/manifests`），目录变化即触发创建/更新/删除，另有周期性全量扫描兜底；
- 静态 Pod 在 apiserver 里有**镜像 Pod（mirror pod）**用于可见性（名字带节点后缀，如 `kube-apiserver-cka000021`），但它只是只读投影；
- 通过 API 删不掉静态 Pod：删了 mirror pod，kubelet 马上重建。**唯一的删除方式是移走 manifest 文件**。

```bash
# [master] 1. 确认 kubelet 的 manifests 目录
sudo grep staticPodPath /var/lib/kubelet/config.yaml
# 预期: staticPodPath: /etc/kubernetes/manifests

# [master] 2. 看控制面四个静态 Pod
ls /etc/kubernetes/manifests/
# 预期: etcd.yaml  kube-apiserver.yaml  kube-controller-manager.yaml  kube-scheduler.yaml

# [master] 3. 试图用 API 删除(演示它删不掉)
kubectl -n kube-system delete pod kube-scheduler-$(hostname) --wait=true
kubectl -n kube-system get pod kube-scheduler-$(hostname)
# 预期: 删除成功后数秒内同名 Pod 重新出现(AGE 归零)。
# 注: kubectl 删的是 mirror pod, kubelet 立刻按 manifest 重建——这正是排障时的干扰项
```

## 8. kubelet：节点上的全能管家

kubelet 是节点代理，职责是"让本节点的实际状态匹配 apiserver 里属于我的 Pod 清单"。内部模块：

```
# [图] kubelet 内部
apiserver(6443) ──watch 本节点 Pod──► PodManager
                                        │
   节点状态/Lease 上报 ◄── StatusManager │
                                        ▼
   探针执行 ◄── ProberManager ──── PodWorker(每 Pod 一个 goroutine)
                                        │
                          ┌─────────────┼──────────────┐
                          ▼             ▼              ▼
                    CRI(gRPC)      PLEG          cAdvisor
                 containerd       检测容器启停     容器/节点指标
                 /run/containerd/ 每~1s relist    /metrics/cadvisor
                 containerd.sock  生成事件
```

- **CRI（Container Runtime Interface）**：kubelet 通过 gRPC 与容器运行时（containerd/CRI-O）通信：sandbox 创建、镜像拉取、容器启停。dockershim 已在 1.24 移除，这也是 03-docker 模块强调 containerd 原生命令（ctr/crictl）的原因。
- **PLEG（Pod Lifecycle Event Generator）**：kubelet 不收运行时事件，而是每秒**全量 list** 一次容器状态、与上次对比，生成 "容器 X 启动了/退出了" 事件驱动 PodWorker。containerd 卡顿时 relist 变慢，kubelet 日志会出现经典的 `pleg is not healthy`，节点被打成 `NotReady`——遇到它先查容器运行时，不是查网络。
- **cAdvisor**：内嵌的指标采集器，提供容器 CPU/内存数据，Prometheus 从 `/metrics/cadvisor` 抓取（PCA 关联点）。
- **节点心跳**：kubelet 定期更新 NodeStatus（Ready 等条件）并在 `kube-node-lease` 名词空间续约 Lease；controller-manager 侧超过 `node-monitor-grace-period`（默认 40s）没心跳就打 `node.kubernetes.io/not-ready` 污点，之后驱逐逻辑介入。
- **端口**：10250（HTTPS，apiserver 连它做 exec/logs/probe，kubelet 自身 client 证书双向认证）；10248（本地 healthz）。10255 只读端口已废弃。

```bash
# [worker1] 若无 crictl 先安装(注意版本可到 cri-tools releases 页查最新)
VERSION=v1.31.1
wget -qO- "https://github.com/kubernetes-sigs/cri-tools/releases/download/${VERSION}/crictl-${VERSION}-linux-amd64.tar.gz" | sudo tar xz -C /usr/local/bin

# [worker1] 用 CRI 视角看本节点容器: 每个 Pod 一个 sandbox(pause)
sudo crictl pods | head -3
sudo crictl ps --name Pause | head -3
# 预期: 每个业务 Pod 对应一行 sandbox + 一个 pause 容器(第 03 章展开)
```

## 9. 节点与控制面的双向证书认证链路（总图）

kubeadm 在 `/etc/kubernetes/pki` 生成一棵 CA（`ca.crt/ca.key`），所有组件身份都由它签发。把下面这张图看懂，CKA/CKS 的证书排障题就都有了地图：

```
# [图] kubeadm 集群认证链路总图
        你(kubectl)                control-plane 节点                     worker 节点
      ─────────────              ─────────────────────                ──────────────
                                                       
  ~/.kube/config=admin.conf          
  客户端证书 CN=kubernetes-admin,      
  O=system:masters(超管组)            
        │ ① HTTPS:6443              
        ▼                            
  ┌─────────────────────────────────────────┐         
  │ kube-apiserver :6443                    │         
  │ 服务端证书 apiserver.crt                 │         
  │ SAN: 节点IP/10.96.0.1/kubernetes.default │◄────────┐
  └──────┬───────────────┬───────────────────┘         │
         │               │                             │
  ② etcd 客户端证书  ③ 连 kubelet:10250 的客户端         │ ⑤ kubelet 客户端证书
  apiserver-        apiserver-kubelet-client.crt       │ /var/lib/kubelet/pki/
  etcd-client.crt   (exec/logs/probe 走这里)            │ kubelet-client-current.pem
         │               │                             │ CN=system:node:<节点名>
         ▼               ▼                             │ O=system:nodes
  ┌─────────────┐   ┌──────────────────┐               │ → Node 授权器只允许它
  │ etcd        │   │ kubelet :10250   │◄──────────────┘   管本节点的对象
  │ :2379 客户端 │   │ 服务端证书(默认   │
  │ :2380 对等  │   │ 自签,未配 CA 时   │
  │ etcd/ca 单独 │   │ apiserver 不校验) │
  │ 签发 server/ │   └──────────────────┘
  │ peer 证书    │      ▲
  └─────────────┘      │ RAFT 内部也是 mTLS
                       
  scheduler.conf / controller-manager.conf / kube-proxy.conf
  = 各自的客户端证书 + apiserver 地址, 权限由 RBAC Role/ClusterRoleBinding 界定
  front-proxy-ca + front-proxy-client.crt = 聚合 API(如 metrics-server)的用户代理链
```

读图要点：**每个箭头都有两份证书**——客户端证书证明"我是谁"，服务端证书用于加密与防冒充；kubelet 的客户端身份（`system:node:<name>` + `system:nodes` 组）配合 Node 授权器，天然只能操作自己节点上的 Pod，这是"最小权限"在传输层的落地。

```bash
# [master] 4. 检查 apiserver 服务端证书的 SAN(排障: 客户端连不上 6443 报证书错误)
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A1 'Subject Alternative Name'

# [master] 5. 检查证书有效期(CKA 常考: 证书过期导致组件全部失联)
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate
# 集中式检查可用: sudo kubeadm certs check-expiration
```

## 实战演练

在 master 上完成（worker 相关步骤可 ssh 到 worker1）。

```bash
# [master] 步骤 1: 确认控制面组件都是静态 Pod 且宿主机上看得到进程
kubectl -n kube-system get pods -o wide | grep -E 'etcd|kube-apiserver|kube-controller-manager|kube-scheduler'
sudo ps aux | grep -E 'kube-apiserver|etcd' | grep -v grep | head -4
# 预期: 四个 Pod 状态 Running; ps 能看到容器化的进程(containerd 起的进程属于宿主机进程表)

# [master] 步骤 2: 观察选主 Lease
kubectl -n kube-system get lease
# 预期: kube-controller-manager 与 kube-scheduler 两条, holderIdentity 指向当前 master

# [master] 步骤 3: etcd 健康与角色
kubectl -n kube-system exec etcd-$(hostname) -- sh -c \
  "ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
   --endpoints=https://127.0.0.1:2379 member list -w table"
# 预期: 单成员, 状态 started

# [master] 步骤 4: 复现"静态 Pod 删不掉"
kubectl -n kube-system delete pod kube-scheduler-$(hostname)
sleep 5 && kubectl -n kube-system get pod -l component=kube-scheduler
# 预期: 同名 Pod 重建, AGE 只有几秒

# [worker1] 步骤 5: 节点侧视角
sudo crictl ps | head -5
sudo tail -n 5 /var/log/kubelet.log 2>/dev/null || sudo journalctl -u kubelet -n 5 --no-pager
# 预期: crictl 列出本节点容器; journal 里能看到 PLEG/Probe 相关周期日志
```

验证：每步"预期"即标准。若步骤 4 Pod 未重建，检查 `/etc/kubernetes/manifests/kube-scheduler.yaml` 是否存在、kubelet 是否 Running。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 新 Pod 全部 Pending，事件 `FailedScheduling` | 资源不足/污点不容忍/scheduler 挂了 | `kubectl describe pod` 看 Events；`kubectl -n kube-system get pod -l component=kube-scheduler` |
| 节点 `NotReady`，kubelet 日志 `pleg is not healthy` | containerd 卡顿，relist 超时 | 重启 containerd；检查磁盘 IO 与镜像堆积 |
| 证书过期：kubectl 报 `x509: certificate has expired` | kubeadm 证书默认 1 年 | `sudo kubeadm certs check-expiration` + `sudo kubeadm certs renew all` 后重启控制面静态 Pod |
| 删除 kube-system 里的控制面 Pod"失败了"又出现 | 那是静态 Pod 的 mirror pod | 改/删 `/etc/kubernetes/manifests/` 下的 manifest 文件才有效 |
| 客户端报 `tls: failed to verify certificate` | apiserver 证书 SAN 不含访问所用地址 | 用 SAN 里的地址连，或重签证书（kubeadm 需重建 apiserver.crt） |
| etcd 2 副本"更安全" | 恰恰相反：quorum=2，挂一台就不可写 | 永远 1/3/5 奇数成员 |

## 自测

1. 为什么 scheduler 和 controller-manager 互相不通信也能协同完成"部署一个 Deployment"？协同的介质是什么？

<details><summary>答案</summary>

介质是 apiserver 里的 API 对象。deployment 控制器创建 Pod（无 nodeName）→ scheduler watch 到未绑定 Pod，写入 Binding → kubelet watch 到属于自己节点的 Pod，拉起容器。每个组件只与 apiserver 对话，靠对象状态的流转完成协作。这种解耦让任何组件都可以独立崩溃重启。
</details>

2. 如果 etcd 3 成员集群同时挂掉 2 台，apiserver 还能读旧对象吗？能写吗？为什么这是"正确"的行为？

<details><summary>答案</summary>

不能可靠地读也不能写：RAFT 失去多数派（quorum=2，只剩 1 个成员）时 etcd 停止服务，apiserver 的读写都会失败。这是刻意的：少数派成员可能已经落后，若继续提供服务，等网络恢复就会产生脑裂式的分叉。宁可不服务，不能不一致。恢复手段是把残留成员重启成单成员集群（`--force-new-cluster` 或移除失败成员），或从快照恢复。
</details>

3. Informer 明明已经在 watch 了，为什么还要周期性 resync？resync 会重新 list apiserver 吗？

<details><summary>答案</summary>

resync 不是重新 list，而是把**本地缓存**里的对象重新推一遍 OnUpdate 回调。它兜的是"事件到了但处理器逻辑出错/错过"的场景：配合 reconcile 的 level-triggered 设计，定期重算全量差值保证最终收敛。重新与 apiserver 对齐的动作只在断线且 resourceVersion 返回 410 Gone 时发生（re-list）。
</details>

4. 你 `kubectl delete pod` 删掉了 kube-apiserver 的 mirror pod， apiserver 会重启吗？这和普通 Pod 的"删除重建"区别在哪？

<details><summary>答案</summary>

不会有任何中断。mirror pod 只是 apiserver 里的一条只读记录，真正的 apiserver 容器由 kubelet 依据 manifest 文件管理；删除 mirror pod 后 kubelet 重建一条新记录而已。普通 Pod 的删除是真的触发容器终止。判断依据：看 Pod 是否属于静态 Pod 机制（名字带节点后缀、`ownerReferences` 为空、位于 kube-system）。
</details>

5. apiserver 主动连 kubelet 的 10250 端口做什么？如果 kubelet 的服务端证书是自签的，这条链路还能用吗？

<details><summary>答案</summary>

做 exec/logs/port-forward/探针代理等需要进入容器的操作。能用：kubelet 默认自签服务端证书，apiserver 侧未配置 `--kubelet-certificate-authority` 时只加密不校验身份，认证靠反向的客户端证书（apiserver-kubelet-client.crt）+ webhook 授权。CKS 视角这是个可加固点：给 kubelet 签发 CA 背书的服务端证书并开启校验。
</details>

## 延伸阅读

- Kubernetes 组件：https://kubernetes.io/docs/concepts/overview/components/
- kube-apiserver 概念（含请求处理链）：https://kubernetes.io/docs/concepts/architecture/kube-apiserver/
- etcd 运维（官方）：https://etcd.io/docs/v3.5/op-guide/
- client-go Informer 机制（官方仓库 wiki）：https://github.com/kubernetes/client-go/blob/master/tools/cache/shared_informer.go
- 静态 Pod：https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
- kubelet 与证书引导：https://kubernetes.io/docs/concepts/architecture/nodes/
