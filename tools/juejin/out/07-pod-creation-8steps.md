---
title_juejin: 从 kubectl 回车到容器跑起来：完整 8 步
title_zhihu: 从 kubectl 回车到容器跑起来：完整 8 步
description: Pod创建全流程8步详解：API写etcd→Scheduler→kubelet→CRI→CNI→探针→Service。每步的组件交互和排障入口。
category_id: "6809637769959178254"
tags: "Kubernetes,后端"
column_id: "7686346277555683378"
---

# kubectl 敲下去 0.1 秒，Pod 跑起来 5 分钟：中间这 8 步，每步一条命令验尸

> 从 kubectl 回车到容器跑起来｜K8s 链路拆解系列 · 07

`kubectl apply` 敲下去 0.1 秒，到 Pod 真正跑起来，中间隔着 5 秒到 5 分钟的"黑盒时间"：Pod 卡在 `ContainerCreating`，你除了反复 describe 什么都做不了。

今天把这条链路拆成 8 步，每一步配一组验证命令（多数开箱即敲）——下次再卡，你能精确说出卡在第几步。**文末有一张「症状 → 卡在第几步 → 第一条命令」的排障地图，建议先存再看。**

## 先看全景：一条流水线，8 道工序

1. **kube-apiserver → etcd**：认证、授权、准入后落盘，此刻 Pod 还没有 nodeName
2. **kube-scheduler**：watch 到"没有 nodeName 的 Pod"，放进调度队列
3. **kube-scheduler**：Filter 过滤 + Score 打分，写回 Binding（绑定节点）
4. **kubelet（目标节点）**：watch 到"属于我这台节点的 Pod"，开始拉镜像
5. **CRI（containerd）**：先建 pause 沙箱，再创建业务容器
6. **CNI（Calico 等）**：给沙箱分配 Pod IP（来自节点的 podCIDR）
7. **kubelet**：探针通过，Pod 的 Ready 条件置 True
8. **endpointslice 控制器**：收录 Pod IP，kube-proxy 刷新转发规则

| 步 | 干活的组件 | 核心动作 | 卡住时的样子 |
| --- | --- | --- | --- |
| 1 | apiserver → etcd | 校验后落盘 | 403 / 对象根本没建成 |
| 2 | scheduler | watch 到新 Pod | 几乎无感（毫秒级） |
| 3 | scheduler | 两阶段决策 + Binding | Pending + FailedScheduling |
| 4 | kubelet | 拉镜像 | ImagePullBackOff |
| 5 | containerd | 建 pause 沙箱 + 业务容器 | ContainerCreating |
| 6 | CNI 插件 | 分配 Pod IP | ContainerCreating 迟迟不结束 |
| 7 | kubelet | 探针通过，Ready=True | Running 但接不了流量 |
| 8 | endpointslice 控制器 | 收录 IP，刷转发规则 | Ready 但 Service 访问不通 |

谁在干活、卡住长什么样，表里都有了。进细节。

## 第 1 步：API 写入 etcd——对象先"落户口"

kubectl 本质是个 HTTP 客户端。它读 kubeconfig 拿到 apiserver 地址，把 JSON POST 到 `/api/v1/namespaces/default/pods`。它不连 etcd，也不"通知"任何人。

这条链路的第一条铁律就埋在这里：**etcd 只被 apiserver 访问**。scheduler、controller-manager、kubelet 全走 REST API，没人直连数据库。

apiserver 收到写请求后要过六道关：

```text
① 认证   客户端证书/token/OIDC → 你是谁
② 授权   RBAC/Node → 能不能做
③ 准入   MutatingWebhook + 默认值注入(比如自动补 serviceAccount)
④ 校验   Schema + ValidatingWebhook → 对象必须合法
⑤ 并发   resourceVersion 乐观锁, 防并发覆盖
⑥ 落盘   写入 etcd, RAFT 多数派确认后才返回 201
```

③ 准入这步比想象中忙：你没写 serviceAccountName，Pod 里却多了个 `default`——就是 Mutating 准入补的。Gatekeeper 策略检查、服务网格注入 sidecar，也都发生在这里。

一个关键细节：此刻落盘的 Pod **没有 `spec.nodeName`**，phase 是 Pending。这个"没主人"的状态，正是下一步 scheduler 的触发条件。

还有个性能排障常识：apiserver 是无状态的，状态全在 etcd，所以能多副本加负载均衡横扩。

而且它内部有 watch cache，大部分 get/list 直接从内存应答，根本不碰 etcd。所以 **etcd 慢不一定等于 kubectl get 慢——定位时别冤枉人**。

眼见为实：

```bash
kubectl run demo --image=nginx:1.27 --restart=Never
# 再来一次, 开 -v=8 看 kubectl 实际发出的 HTTP 请求
# 输出里有对 /api/v1/namespaces/default/pods 的 POST, 响应 201 Created
kubectl run demo2 --image=nginx:1.27 --restart=Never -v=8 2>&1 | grep -E 'POST|GET'
# 可选进阶: 看对象在 etcd 里的键名(master 节点执行, kubeadm 集群, 需要全套证书)
kubectl -n kube-system exec etcd-$(hostname) -- sh -c \
  "ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
   --cert=/etc/kubernetes/pki/etcd/server.crt \
   --key=/etc/kubernetes/pki/etcd/server.key \
   --endpoints=https://127.0.0.1:2379 get /registry/pods/default/ --prefix --keys-only"
# 不想 ssh master 的轻量替代: 从 raw 接口看 apiserver 眼里的这个对象
# 刚建完时 grep 不到 nodeName, 过几秒再跑就有了——那正是第 2、3 步干的活
kubectl get --raw /api/v1/namespaces/default/pods/demo | tr ',' '\n' | grep nodeName
```

顺带记一句：RAFT 要求多数派确认，所以 etcd 成员数永远取奇数（3 或 5）——偶数只会拉高写延迟，容错一档都不加。

这步的典型翻车：403（RBAC 没权限）、ResourceQuota 超限、准入 webhook 超时。报错都很直白，别往 scheduler 身上赖。

## 第 2 步：Scheduler watch——没人"叫"它，它自己盯着

很多人以为 apiserver 会主动"通知"scheduler。恰恰相反，是 scheduler 一直在 watch apiserver："把所有 Pod 的变更事件推给我"。

**没人"叫"它，它自己盯着**。这是第二条铁律：控制面组件互相不通信，scheduler 不知道 controller-manager 存在，大家只 watch 自己关心的对象，靠 API 对象的状态流转协作。

这就是 list-watch 机制。算笔账就知道为什么不能轮询：

```text
轮询:       300 个客户端 × 每秒 1 次 list × 5000 个 Pod 的全量序列化
            = apiserver 每秒要吐 150 万个对象, 直接被打死
list-watch:  启动时 1 次全量 list + 之后只收增量事件
            没变化 = 0 流量; 有变化 = 只传那 1 个对象
```

scheduler 通过 Informer 的**本地缓存**看到新 Pod，发现 `spec.nodeName` 为空，丢进调度队列。全程通常不到 100 毫秒，基本无感。

watch 是 HTTP chunked 长连接持续推送，但它**不保证永不断**。apiserver 会主动随机掐断长连接（防止流量在副本间倾斜），客户端必须能带着 resourceVersion 重连：

- 对象每被改一次，**resourceVersion** 就变一次（来自 etcd 的全局 revision）；
- 客户端记下断线前见到的最大 RV，重连时带上，apiserver 只补发这之后的事件；
- RV 已被 etcd 压缩掉，返回 **410 Gone**，客户端重新 list 全量、再从新 RV 继续 watch。

所以 Informer 的正确性不靠"连接不断"，而靠"list 建基线 + 增量追赶 + 410 兜底重置"。这也是为什么控制器挂了重启，不会漏掉任何变化。

```bash
# 亲眼看看 watch 的增量推送: 终端 A 持续 watch resourceVersion
# 注意别接 head 之类的管道——head 收满退出会把 watch 一起带崩, 后面就什么都看不到了
kubectl get pods -A -w -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,RV:.metadata.resourceVersion
# 终端 B 给任意 Pod 打个标签, 回终端 A: 只有该 Pod 的 RV 变化, 作为一条新事件出现
kubectl label pod -n kube-system -l component=kube-scheduler debug-marker=1 --overwrite
kubectl label pod -n kube-system -l component=kube-scheduler debug-marker- --overwrite
```

## 第 3 步：Filter + Score，写回 Binding——Pod 找到家

scheduler 的职责被刻意设计得极窄：**给没有 nodeName 的 Pod 挑一个节点，写回去，完事**。它不建容器、不管副本数。

挑节点分两个阶段：

| 阶段 | 干什么 | 依据 |
| --- | --- | --- |
| Filter 过滤 | 硬条件淘汰，不行就是不行 | 资源够不够、端口冲突、nodeAffinity(required)、污点容忍、卷拓扑 |
| Score 打分 | 软条件排序，优中选优 | 资源均衡度、副本打散、preferred 亲和、镜像是否本地有缓存 |

选定后，scheduler 向 apiserver POST 一个 Binding 对象——就 podName 和 targetNode 两个字段。apiserver 据此把 `spec.nodeName` 写进 Pod。从这一刻起，那台节点的 kubelet 正式"认领"它。

```bash
# 看 Pod 被绑到了哪个节点
kubectl get pod demo -o jsonpath='{.spec.nodeName}'; echo
# 调度失败的原因写在事件里, 直接给答案
kubectl describe pod demo | grep -A 5 Events
# 调度成功也有事件: 找 Normal Scheduled 这条
kubectl get events --field-selector involvedObject.name=demo
```

提醒一个坑：网上常见 `kubectl logs kube-scheduler-xxx | grep "Successfully bound"`。那句日志是 klog V(2) 级别，而 kube-scheduler 默认 verbosity 是 0，kubeadm 的静态 Pod 清单也不带 -v 参数——默认集群里 grep 不到是正常的，不是你操作错了。真想看决策日志，得给 scheduler 加 `-v=2` 以上，并在 master 节点上看它的日志。

两条实战经验：

- Filter 全军覆没 → Pod 停在 Pending，事件 `FailedScheduling`，消息直接列原因，比如 `0/3 nodes are available: 3 Insufficient cpu`。
- Filter 全挂的 Pod 进入**不可调度队列（unschedulable pods）**，**集群有变化才重新唤醒**（新节点加入、大 Pod 被删、标签污点改动）；只有瞬时错误才进 backoffQ 重试。所以"删了个大 Pod，Pending 的要过一会儿才调度走"是正常现象，不是 bug。

两个进阶冷知识，面试里说出来是加分项：

- master 节点上为什么不长业务 Pod？因为它带 `node-role.kubernetes.io/control-plane:NoSchedule` 污点，Filter 阶段直接把不容忍污点的 Pod 淘汰了。
- 多副本部署的 scheduler 靠 kube-system 里的 Lease 选主，同一时刻只有一个实例干活，其余热备。

```bash
# 看选主的 Lease(kubeadm 集群)
kubectl -n kube-system get lease
```

**scheduler 挂了：已运行的 Pod 照常跑，新 Pod 全部 Pending——这是判断"控制面坏了还是节点坏了"的第一条线索。**

## 第 4 步：kubelet 拉镜像——出镜率最高的卡点

节点上的 kubelet 一直在 watch "nodeName 等于自己" 的 Pod。新 Pod 一绑定过来，PodWorker 开始 syncPod，大致顺序：建沙箱 → 跑 init 容器 → 拉主镜像 → 起容器。

镜像拉取走 CRI 接口，交给 containerd 执行。拉不动，就是你最熟的 `ImagePullBackOff`。

```bash
kubectl get pod demo -w
kubectl describe pod demo | grep -iE 'pulling|pulled|error'
```

这步翻车 TOP 3：

- 私有仓库没配 `imagePullSecrets`，或者 secret 和 Pod 不在同一个 namespace。
- 镜像 tag 写错或不存在 → `ErrImagePull` / `ImagePullBackOff`，报错里直接带着它试图拉的 tag。这条还有个更隐蔽的真身：image 省略 tag 时等价于 `:latest`，默认 policy 也随之变成 Always——"没写 tag，结果拉到个意外版本"的事故就出在这。顺带纠个偏：不存在"拉失败自动回退去拉 latest"的机制，别被带偏。
- 架构不匹配：x86 节点拉了 arm64 镜像，**拉取成功、启动暴毙——最迷惑人的翻车姿势**，容器一启动就报 `exec format error`。

`imagePullPolicy` 三个值顺手过一遍：

| 策略 | 行为 |
| --- | --- |
| Always | 每次创建容器都去 registry 检查（tag 是 latest 时默认它） |
| IfNotPresent | 本地没有才拉（其他 tag 默认它） |
| Never | 永不拉，本地没有直接报 ErrImageNeverPull |

这套默认规则截至 1.31 官方文档没有变过。一个提速技巧：把常用大镜像做成 DaemonSet 提前铺到所有节点，业务 Pod 用 IfNotPresent，扩容时能省掉大半等待。

## 第 5 步：CRI 创建容器——先来一个 pause

第三条铁律在这步落地：**控制面从不直接碰容器**，创建容器的唯一路径是 kubelet → 容器运行时。kubelet 通过 gRPC 指挥容器运行时（containerd 的 socket 在 `/run/containerd/containerd.sock`）：建沙箱、拉镜像、启停容器，全走 CRI 接口。

关键角色是 **pause 容器**：一个永远在睡觉的极小容器，作用是持有 network namespace 等命名空间。业务容器创建时全部加入它名下的这些 namespace，于是一个 Pod 里的容器共享网络——localhost 互通、共享同一个 IP。

所以"每个 Pod 一个 IP"的真相是：**IP 挂在沙箱上，业务容器只是蹭网的**。面试聊 Pod 创建能讲到 pause 这层的，面试官能看出你不是背答案的。

```bash
# 在 Pod 所在节点上, 用 CRI 视角看(kubeadm 集群)
sudo crictl pods --name demo
sudo crictl ps --name demo
sudo crictl ps -a | head -5
```

补一句历史：dockershim 在 1.24 就被移除了。想在节点上用 docker 命令找 Pod，是找不到的，请用 crictl。

再送一个 kubelet 内部冷知识——PLEG。先讲机制：kubelet 不接收运行时的事件推送，而是**每秒全量 list 一次容器状态、跟上次对比**，自己生成"谁启动了、谁退出了"的事件（这是默认的 legacy PLEG 模式；订阅式的 Evented PLEG 已进主线，但目前默认关闭）。

这个机制贡献了一个经典事故现场：

- 现象：节点突然 NotReady，kubelet 日志隔一会儿就刷 `pleg is not healthy`，上面的 Pod 陆续从 Service 被摘除；
- 根因：containerd 卡死（常见诱因是磁盘 IO 打满），kubelet 每秒的那次全量 list 跟着超时，PLEG 停摆，kubelet 上报自己 NotReady；
- 验证：上节点敲一条 crictl，5 秒不返回，运行时的罪名基本坐实。

```bash
sudo journalctl -u kubelet | grep -i 'pleg is not healthy' | tail -3
# 这条如果 5 秒都不返回, 就别猜了, 给 containerd 定罪
sudo timeout 5 crictl ps
```

遇到它先查容器运行时（多数情况 `systemctl restart containerd` 能救急），别去查网络。

## 第 6 步：CNI 分配 IP——IP 是配给沙箱的

每个节点都会分到一段 podCIDR（比如 10.244.3.0/24）。CNI 插件在沙箱创建时被调用：从本节点的段里挑一个空闲 IP，配到沙箱的网卡上，同时把路由发布到全集群——这就是跨节点 Pod 互通的底层。

小声说：严格顺序是"先建沙箱 → CNI 配 IP → 再启业务容器"，上一节为了讲清职责略有简化。排障时记住"IP 挂在沙箱上"这个事实更重要。

```bash
# Pod 拿到的 IP
kubectl get pod demo -o jsonpath='{.status.podIP}'; echo
# 节点被分配的网段
kubectl get node $(kubectl get pod demo -o jsonpath='{.spec.nodeName}') -o jsonpath='{.spec.podCIDR}'; echo
```

注意：podCIDR 由控制器管理器里的节点控制器分配，但 Cilium 这类自带 IPAM 的 CNI 不依赖它，这个字段会是空的——空不等于有病，先看你用的 CNI 属于哪类。

经典大坑：podCIDR 和物理网络或 Service 网段重叠，Pod 访问外部地址被"吸"进集群，各种诡异不通。规划集群时，下面三段必须互不重叠：

| 网段 | 给谁用 | 在哪定义 |
| --- | --- | --- |
| 节点物理网段 | 机器管理网络 | 机房/云平台分配 |
| podCIDR | Pod IP | kubeadm 的 `--pod-network-cidr` |
| Service CIDR | ClusterIP | apiserver 的 `--service-cluster-ip-range` |

参数名随安装方式不同：kubeadm 是上面这两个，RKE2 写在 config.yaml 的 cluster CIDR，云托管集群干脆由平台托管。

## 第 7 步：探针通过——Running 不等于 Ready

容器起来了，kubelet 还要按你定义的探针做体检。探针是 kubelet 亲自执行的，不是别人：

| 探针 | 作用 | 不通过的后果 |
| --- | --- | --- |
| startupProbe | 慢启动保护 | 通过之前不跑下面两个探针 |
| readinessProbe | 能不能接流量 | Ready=False，从 Service 摘除 |
| livenessProbe | 活没活 | 重启容器 |

Running 只说明"进程在"，Ready 才说明"能接活"。**没配 readinessProbe 时，容器一启动 Ready 就置 True**——很多"半成品容器接流量"事故的根源就在这。我们组就栽过一次：一个还没连上数据库的服务没配 readiness，Ready 秒置 True，流量进来，对外报了五分钟错。从此 readinessProbe 成了 code review 必查项。

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: web
spec:
  containers:
  - name: nginx
    image: nginx:1.27
    readinessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 2
      periodSeconds: 3
```

探针端口写错、路径写错，Pod 会一直 Running 但 Ready=False，流量一滴都进不来。查的时候分清三个位置：Ready 条件在 `.status.conditions`，容器级状态（CrashLoopBackOff、OOMKilled）在 `.status.containerStatuses`，而**探针失败的原因只在 describe 的 Events 里**（`Readiness probe failed: ...`）。

```bash
kubectl apply -f web.yaml
# Ready 条件: False 就是探针没过
kubectl get pod web -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}'; echo
# 容器级状态: CrashLoopBackOff / OOMKilled 看这里
kubectl get pod web -o jsonpath='{.status.containerStatuses[0].state}'; echo
# 探针失败原因: Events 里的 Readiness probe failed
kubectl describe pod web | grep -A 5 Events
```

一个老派习惯的替代方案：与其用 `initialDelaySeconds` 拍脑袋猜应用启动要多久，不如上 startupProbe——`failureThreshold × periodSeconds` 就是给应用的总启动预算，慢启动应用从此不用"猜数字"。

## 第 8 步：Service 收录 Endpoint——流量进门的最后一环

endpointslice 控制器（住在 controller-manager 里）watch 带 selector 的 Service 和 Pod，把**selector 匹配且 Ready** 的 Pod IP 写进 EndpointSlice 对象。

kube-proxy 再 watch EndpointSlice，刷新本节点的 iptables/IPVS 规则。到这一步，集群里任何机器访问 Service 的 VIP，才能被转发到你的容器。

所以"Pod 明明 Running，Service 就是打不通"的排查终点站，就是看 endpoints 里有没有 IP：

```bash
# 给 demo 挂一个 Service
kubectl expose pod demo --port=80
# 看 endpoints 收录了谁
kubectl get endpoints demo -o wide
# 新版本推荐看 EndpointSlice
kubectl get endpointslice -l kubernetes.io/service-name=demo -o wide
```

endpoints 为空的三大原因：selector 不匹配（label 拼错）、Pod Ready=False（回到第 7 步查探针）、targetPort 写了端口名但和 containerPort 的 `name` 对不上——名字对不上，等于这个端口不存在。

为什么推荐看 EndpointSlice？老的 Endpoints 是一个 Service 一个大对象，后端一变就全量推送；EndpointSlice 把后端切成多个小片，变更只推受影响的切片，对大规模集群更友好。排障两边内容一致，看哪个都行。

kube-proxy 的转发实现默认是 iptables，大规模集群可切 ipvs（连接多时规则同步更快），userspace 模式早已淘汰。

## 排障地图：症状 → 卡在第几步

| 症状 | 大概率卡在 | 第一条命令 |
| --- | --- | --- |
| 403 / 对象创建失败 | 第 1 步 | `kubectl auth can-i create pods` |
| Pending + FailedScheduling | 第 3 步 | `kubectl describe pod <name>` |
| ImagePullBackOff | 第 4 步 | `kubectl describe pod <name> \| grep -i pull` |
| ContainerCreating 超一分钟 | 第 5/6 步 | 登录节点 `sudo crictl ps -a`，再看 CNI 日志 |
| Running 但 Ready=False | 第 7 步 | `kubectl describe pod <name>` 看探针失败记录 |
| Ready 但 Service 不通 | 第 8 步 | `kubectl get endpoints <svc>` |
| 删掉控制面 Pod 又原地复活 | 偏题：静态 Pod | 改 `/etc/kubernetes/manifests/` 才有效 |
| 节点 NotReady + `pleg is not healthy` | 第 5 步的运行时 | 登录节点重启 containerd，查磁盘 IO |

把这张表存下来，比背十篇面试经都管用。

## 彩蛋：面试一分钟版本

排障是这篇的主线，但这个问题面试出现率确实高。下面这段建议原文背下来——全文第二个值得收藏的锚点就是它：

> **背这段（约一分钟）**
>
> kubectl 把请求发给 apiserver，经过认证、授权、准入后写入 etcd，此时 Pod 没有 nodeName。scheduler 通过 watch 机制发现它，经过 Filter 和 Score 两阶段选出节点，把结果用 Binding 写回 apiserver。
>
> 目标节点的 kubelet watch 到属于自己节点的 Pod，先通过 CRI 让 containerd 建 pause 沙箱、拉镜像，CNI 插件给沙箱分配 podCIDR 里的 IP，再启动业务容器。最后探针通过，Pod 变 Ready，endpointslice 控制器把它的 IP 收录进去，kube-proxy 刷新规则，Service 的流量才真正进来。

## 现在就能做的事

两档任选：

- 零门槛档：把上面的排障地图截图存进手机——比跑一遍集群更保值，下次卡住它直接帮你省半小时。
- 动手档：花 3 分钟在任意集群上跑一遍，8 步的事件流会按顺序打印在你眼前：

```bash
kubectl run demo --image=nginx:1.27 --restart=Never
# 终端 A
kubectl get pod demo -w
# 终端 B: 按时间顺序对照本文的 8 步
kubectl get events --field-selector involvedObject.name=demo --watch
# 最后补一环: 看 endpoints 收录
kubectl expose pod demo --port=80 && kubectl get endpoints demo -o wide
```

能看到 `Scheduled → Pulling → Pulled → Created → Started` 这串事件依次出现，这条链路你就真吃透了。

评论区聊两件事：一，你们被 Running 但 Ready=False 坑过吗？说说事故现场；二，你们环境拉一个 nginx 镜像要几秒？我先来——我本地裸网络大概 8 秒，走海外 registry 的那套测试环境要 3 分钟。

另外"Pod 删除全流程"也在写了，想先看哪个角度（graceful shutdown 两阶段、Finalizer 卡删除、还是 endpoint 摘流量的时序），评论区留言，票高的先写。觉得有帮助的话，点赞收藏一下，能让更多人刷到这篇。

## 往期与下篇

- 上篇：06 · DaemonSet 扩容 404 迷案（掘金链接发布后补）
- 本篇：07 · Pod 创建 8 步（你在这）
- 下篇：08 · 画出 iptables 链路图才算懂 Service——ClusterIP 根本不在网卡上（掘金链接发布后补）

这篇脱胎自我在维护的学习仓库 [sre-learning-hub](https://github.com/Thneoly/sre-learning-hub)：里面有这篇对应的"控制面架构"章节，还有一个控制面瘫痪演练 lab——把 master 整个停掉，亲眼看哪些事还能做、哪些立刻停。觉得有用去点个 star。
