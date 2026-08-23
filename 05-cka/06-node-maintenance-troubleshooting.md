# 06 · 节点维护与集群排错方法论

> 模块：05-cka ｜ 建议时长：3 小时 ｜ 关联认证：CKA-Troubleshooting（30% 权重域的主线）

## 学习目标

- 能精确说出 cordon / drain / uncordon 三条命令各自做什么、不做什么、如何撤销
- 能解释 `--ignore-daemonsets`、`--delete-emptydir-data`、`--force` 三个参数分别放行什么
- 能沿着五层排错决策树（get nodes → 控制面 Pod → describe events → crictl → journalctl）定位任意故障题
- 能查表处理 10 个最高频的故障现象，每条都知道"第一检查命令"是什么

## 1. 节点维护三命令：语义与边界

| 命令 | 做什么 | 不做什么 | 撤销 |
| --- | --- | --- | --- |
| `kubectl cordon <node>` | 给节点加 `SchedulingDisabled`，新 Pod 不再调度到它 | 不驱逐已有 Pod；节点与存量负载一切照旧 | `kubectl uncordon <node>` |
| `kubectl drain <node>` | **= cordon + evict**：优雅驱逐可驱逐的 Pod（控制器会重建到别的节点） | 不处理 DaemonSet Pod（默认直接报错）、emptyDir Pod（默认报错）、裸 Pod（默认报错）——要加参数放行 | `kubectl uncordon <node>`（evicted 的副本会自动回来） |
| `kubectl uncordon <node>` | 恢复调度 | 不搬回任何 Pod（节点上重新变空的负载要等重建或手工） | — |

标准维护窗口的完整序列：

```bash
# [master] 0. 基线快照：记下当前分布，便于回归比对
kubectl get pods -A -o wide | grep worker1

# [master] 1. 驱逐并封锁（三个放行参数按需叠加）
kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data

# [master] 2. 确认终态：Ready,SchedulingDisabled，本节点只剩 DaemonSet/静态 Pod
kubectl get node worker1
kubectl get pods -A -o wide | grep worker1

# [worker1] 3. 执行维护动作（示例：重启容器运行时与 kubelet）
sudo systemctl restart containerd
sudo systemctl daemon-reload && sudo systemctl restart kubelet

# [master] 4. 恢复调度并回归
kubectl uncordon worker1
kubectl get nodes                      # worker1 回到 Ready（无 SchedulingDisabled）
kubectl get pods -A -o wide | grep -c worker1   # 副本陆续回流
```

### 1.1 drain 的三个放行参数

drain 的本质是"逐个 evict，遇到保护对象就停"。被停的原因与放行参数一一对应：

| 遇到的对象 | drain 默认行为 | 放行参数 | 语义代价 |
| --- | --- | --- | --- |
| DaemonSet Pod（calico-node、kube-proxy…） | 报错退出（它们绑死本节点，驱逐无意义） | `--ignore-daemonsets` | 无：这些 Pod 本来就该留在节点上，维护重启它们是正常的 |
| 挂 emptyDir 的 Pod | 报错退出（emptyDir 数据随 Pod 消亡） | `--delete-emptydir-data` | emptyDir 里的临时数据丢失——确认可丢再给 |
| 裸 Pod（无 Deployment/Job 等控制器） | 报错退出（驱逐=删除且无人重建） | `--force` | Pod 被删且不复活，接近人工兜底 |

evict 与 delete 的差别：evict 走 API 的 eviction 子资源，**尊重 PodDisruptionBudget（PDB）**——若驱逐会打破 PDB 的 minAvailable，drain 会重试等待。这既是生产保护，也是考试里"drain 卡住不动"的第三种原因（前两种是 emptyDir 与 DaemonSet）。

```bash
# [master] drain 卡住时的定位三连
kubectl get pdb -A                                        # 有没有 PDB 卡着
kubectl get pod -A -o wide | grep worker1                 # 剩下的是不是 DaemonSet/裸 Pod
kubectl describe node worker1 | grep -A3 Taints           # 确认 cordon 产生的污点还在
```

### 1.2 cordon 的独立用途

只想"软下线"——例如观察节点问题、防止新负载落上来——用 cordon 就够，存量 Pod 不受影响。排错题里"NotReady 之外的 SchedulingDisabled"通常意味着**前一位维护者忘了 uncordon**，直接 `kubectl uncordon` 恢复。

## 2. 排错决策树：五层定位法

拿到故障题先别乱敲命令，按层次从上往下走，每层一个问题：

```
# [图] CKA 排错决策树
Q0: kubectl get nodes 通不通？
 ├─ 连不上 apiserver（timeout/refused）
 │    └─ L1 控制面层：crictl ps -a | grep -E 'apiserver|etcd'
 │         ├─ 容器没起 → 看 /etc/kubernetes/manifests/*.yaml 是否被改坏、crictl logs
 │         └─ 容器在跑 → kubelet 与 apiserver 之间问题：journalctl -u kubelet、证书（05 章）
 ├─ 有节点 NotReady
 │    └─ L2 节点进程层（SSH 到该节点）：
 │         systemctl status kubelet containerd
 │         journalctl -u kubelet -S -1h | grep -iE 'error|fail|x509'
 └─ 节点全 Ready，但业务异常
      └─ Q1: kubectl get pod -A 找到异常 Pod，看 STATUS
       ├─ Pending        → kubectl describe pod <p> 的 Events（调度器没给说法＝资源/taint/亲和）
       ├─ ImagePullBackOff→ describe 的 Events + 镜像名/registry/拉取 secret
       ├─ CrashLoopBackOff→ kubectl logs <p> --previous（上次挂掉的现场）
       ├─ Running 但服务不通
       │    └─ Q2: Service 链路：get endpoints → selector 与 Pod label 对不上?targetPort?
       │         再查 DNS：kubectl run tmp --rm -it --image=busybox -- nslookup <svc>
       └─ 全体 Pod 都异常、跨节点 → 怀疑 CNI/CoreDNS：get pod -n kube-system / -n calico-system
```

五层工具各管一段，记成"由近及远"：

| 层 | 工具 | 回答的问题 |
| --- | --- | --- |
| L1 集群层 | `kubectl get nodes / get pod -A` | 控制面活着吗？故障面有多大（单 Pod/单节点/全集群） |
| L2 对象层 | `kubectl describe`、`kubectl events`、`kubectl logs --previous` | 对象自己怎么说（Events 与上一次崩溃现场） |
| L3 容器层 | `crictl ps -a / logs / inspect` | 绕过 apiserver 直接看节点上的容器真相（静态 Pod 排错唯一入口） |
| L4 节点服务层 | `systemctl status`、`journalctl -u kubelet/containerd` | 节点上的进程与 kubelet 日志 |
| L5 系统层 | `df -h`、`free -h`、`dmesg`、`ip a / ip r / ss -lntp` | 磁盘/内存/内核/网络这些"地基" |

**故障面决定入口**：全集群故障从 L1 进（多半控制面/证书/etcd）；单 Pod 故障从 L2 进；apiserver 挂死时 kubectl 全废，直接跳 L3。

### 2.1 crictl：apiserver 之外的眼睛

```bash
# [worker1] 全部容器（含退出的）——静态 Pod 排错第一步
sudo crictl ps -a

# [worker1] 看某个容器的日志（CONTAINERID 取 ps -a 输出第一列）
sudo crictl logs --tail=50 <containerID>

# 2. 查容器详细状态（退出码、重启次数、挂载、启动命令）
sudo crictl inspect <containerID> | grep -E 'exitCode|restartCount|attemptCount'

# [worker1] 若提示未配置 runtime endpoint（考场少见但要会救）
sudo crictl config runtime-endpoint unix:///run/containerd/containerd.sock
```

### 2.2 journalctl：kubelet 的时间机器

```bash
# [worker1] 最近 1 小时的 kubelet 错误
sudo journalctl -u kubelet -S -1h | grep -iE 'error|fail|x509|refused'

# [worker1] 限定时间窗（题目说"上周五 14 点后出问题"）
sudo journalctl -u kubelet -S "2026-08-21 14:00" -U "2026-08-21 15:00"

# [worker1] 实时跟踪（配合另一终端重启服务复现）
sudo journalctl -u kubelet -f
```

journalctl 能回答"kubelet 为什么没起来/为什么报证书错/为什么连不上 apiserver"，是 L4 的主力；`-S/-U`（since/until）比肉眼翻屏快一个量级。

## 3. 十大高频故障现象速查表

| # | 现象 | 第一检查命令 | 最常见原因与速修 |
| --- | --- | --- | --- |
| 1 | Node `NotReady` | `ssh` 后 `systemctl status kubelet` | kubelet 挂了/被停：`systemctl start kubelet`；swap 被重新打开：`swapoff -a`；证书过期见 #8 |
| 2 | Node `NotReady,SchedulingDisabled` | `kubectl describe node <n> \| grep -A3 Taints` | 维护后忘 uncordon：`kubectl uncordon <n>`（NotReady 部分另查 #1） |
| 3 | Pod 一直 `Pending` | `kubectl describe pod <p> \| sed -n '/Events/,$p'` | Events 会直说：Insufficient cpu/memory（调 requests 或扩容）、node(s) had taint（加 toleration 或去 taint）、亲和性无解 |
| 4 | `ImagePullBackOff` | `kubectl describe pod <p> \| grep -A5 Events` | 镜像名/tag 拼错；私有仓库缺 imagePullSecrets；网络不通 registry。修 manifest 后 `kubectl rollout restart` 或删 Pod 重建 |
| 5 | `CrashLoopBackOff` | `kubectl logs <p> --previous --tail=50` | 应用启动即退：错误参数/缺 ConfigMap 键/权限。看 previous 日志里的报错改 spec；配合 `kubectl edit` 后观察 |
| 6 | Service 不通、`curl` 超时 | `kubectl get ep <svc> -n <ns>` | endpoints 为空 = selector 与 Pod label 不匹配或 targetPort 写错；endpoints 有值再查 CNI/网络策略 |
| 7 | Pod 内域名解析失败 | `kubectl -n kube-system get pod -l k8s-app=kube-dns`；`nslookup <svc>` | CoreDNS 挂了/CNI 断了；`resolv.conf` 的 `search ... svc.cluster.local` 被改坏；`ndots:5` 导致外部域名先走集群后缀（用 FQDN 结尾点测试） |
| 8 | `kubectl` 全部报 connection refused / x509 | `crictl ps -a \| grep apiserver`；`sudo crictl logs <apiserverID> \| grep -i x509` | apiserver 静态 Pod 起不来：manifest 被改坏（常见 etcd-servers 地址、证书路径）；证书过期（05 章 renew + crictl stop） |
| 9 | 集群"只读"或大面积超时 | `ETCDCTL_API=3 etcdctl ... endpoint health` | etcd 不可用/磁盘满（`df -h /var/lib/etcd`）；多数成员失联。备份与恢复走 04 章流程 |
| 10 | drain 卡住不动 | `kubectl get pdb -A`；`kubectl get pod -A -o wide \| grep <n>` | PDB 打不破（扩副本或临时删 PDB）；emptyDir/DaemonSet/裸 Pod 分别加 `--delete-emptydir-data/--ignore-daemonsets/--force` |

使用方式：考场上对号入座先跑"第一检查命令"，80% 的题在第一跳就能看到答案；剩下的 20% 沿第 2 节决策树换层。

## 实战演练：一次完整的维护窗口 + 一次排错全链

### 演练 A：worker1 维护窗口（约 15 分钟）

```bash
# [master] 部署一个多副本负载做观察对象
kubectl create ns maint-drill
kubectl -n maint-drill create deployment web --image=nginx:1.29 --replicas=3
kubectl -n maint-drill rollout status deployment web

# [master] 逐条执行第 1 节的维护序列（drain 时刻意不带参数，观察报错与放行参数的关系）
kubectl drain worker1
# 期望看到报错：cannot delete DaemonSet-managed Pods ... use --ignore-daemonsets
kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data

# [worker1] 维护动作：重启 kubelet（模拟内核升级后的要求）
sudo systemctl daemon-reload && sudo systemctl restart kubelet

# [master] 恢复与回归
kubectl uncordon worker1
kubectl -n maint-drill get pod -o wide      # 副本数不变，分布恢复
kubectl get nodes
kubectl delete ns maint-drill               # 收尾
```

### 演练 B：排错全链走一遍（约 20 分钟）

在练习集群上把决策树五层各跑一次，目标是把命令练到肌肉记忆：

```bash
# [master] L1 集群层
kubectl get nodes && kubectl get pod -A | grep -vE 'Running|Completed'

# [master] L2 对象层：找一个业务 Pod 看事件与日志
kubectl -n kube-system describe pod -l k8s-app=kube-dns | sed -n '/Events/,$p'
kubectl -n kube-system logs -l k8s-app=kube-dns --tail=20 --all-containers

# [master] L3 容器层（apiserver 之外的眼睛）
crictl ps -a | head
crictl inspect $(crictl ps -q --name kube-apiserver | head -1) | grep -E 'exitCode|restartCount'

# [worker1] L4 节点服务层
systemctl status kubelet --no-pager | head -5
journalctl -u kubelet -S -1h | grep -iE 'error|fail' | tail

# [worker1] L5 系统层
df -h /var/lib/etcd /var/lib/kubelet && free -h && ip br | head
```

有余力可配合本仓库 `scripts/faults/` 的注入脚本（break-kubelet.sh、break-coredns.sh 等）制造真实故障再走链路，等于把故障速查表 #1~#8 各实操一遍。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| drain 报 `cannot delete DaemonSet-managed Pods` | 没带 `--ignore-daemonsets` | 补参数重跑；drain 失败不会半途驱逐已成功的部分，重跑安全 |
| drain 报 `cannot delete Pods with local storage` | emptyDir Pod 未放行 | 确认数据可丢后加 `--delete-emptydir-data` |
| uncordon 后负载没有回到节点 | uncordon 只恢复"可调度"，不主动迁移 | 正常现象：新副本与滚动更新会逐步回来；急着验证可 `rollout restart` |
| 维护完节点仍 NotReady | kubelet/containerd 没起来或证书问题 | `systemctl status kubelet containerd` + `journalctl -u kubelet`，对 #1/#8 处理 |
| `crictl ps` 报 runtime endpoint 未配置 | containerd socket 路径非默认 | `crictl config runtime-endpoint unix:///run/containerd/containerd.sock` |
| describe Pod 的 Events 为空 | 事件已过 1 小时被聚合清理 | `kubectl get events -n <ns> --sort-by=.lastTimestamp`；或直接删 Pod 重建复现 |
| `kubectl logs` 报容器已重启看不到旧日志 | 看的是当前实例 | 加 `--previous` 看上一次的现场（CrashLoop 必用） |
| endpoints 有值、Pod Running，curl 仍不通 | CNI/NetworkPolicy/目标端口错 | 按决策树换层：`calicoctl node status` 或查 NetworkPolicy；`curl PodIP:targetPort` 直连二分 |

## 自测

1. `kubectl drain node1 --ignore-daemonsets --delete-emptydir-data --force` 与逐个 `kubectl delete pod` 相比，多保护了什么？

<details><summary>答案</summary>

drain 走 eviction API，**尊重 PodDisruptionBudget**：如果驱逐会把某服务的可用副本数压到 minAvailable 以下，会停下等待（其他节点副本恢复/扩容）再继续，并且整体先 cordon 保证不出现"删一个又被调度回本节点"的空转。裸 delete 不查 PDB，可能瞬间打断服务。代价是 PDB 配置过紧时 drain 会卡住（速查表 #10）。
</details>

2. apiserver 完全失联（`kubectl get nodes` 超时）。此时你还剩哪些排错手段？为什么它们仍可用？

<details><summary>答案</summary>

SSH 到 master 上：`crictl ps -a`（直接问 containerd，不经 apiserver）、`crictl logs`（读容器日志文件）、`journalctl -u kubelet`（systemd 日志）、检查 `/etc/kubernetes/manifests/*.yaml`（静态 Pod 定义）。它们工作在节点本地（containerd 的 CRI 接口与文件系统），不依赖 apiserver 存活——这正是控制面排错不从 kubectl 开始的原因（决策树 Q0 的左分支）。
</details>

3. Pod 状态 `Running`、Service 有 endpoints，但通过 Service 访问 502/超时；直连 PodIP:80 正常。最可能的两个原因？

<details><summary>答案</summary>

（1）targetPort 与容器实际监听端口不一致（Service 的 port 通了但转发到错误端口）——`kubectl get svc -o yaml` 核对 targetPort 与容器 port/命名；（2） NetworkPolicy 只放行了某来源而没放行 kube-proxy 转发路径，或 CNI 在该节点异常。二分法：先从集群内另一个 Pod `curl PodIP:targetPort`，再 `curl svc`，把故障定位在"Service 定义"还是"网络平面"。
</details>

4. 节点重启后一直是 NotReady，`journalctl -u kubelet` 干净无报错。按决策树下一层查什么？

<details><summary>答案</summary>

下一层是节点进程与系统层：`systemctl status kubelet`（active 吗？）、`systemctl status containerd`（runtime 活着 kubelet 才能上报）、swap 是否被重新打开（fstab 注释失效）、`journalctl -u containerd`。典型根因是重启后 swap 复活（kubelet 启动参数检测到 swap 直接退出）或 containerd 未设自启——两条 systemctl status 一眼可见。
</details>

5. 考题："把 node2 上的所有应用 Pod 移到其他节点，期间保持服务可用，完成后允许 node2 继续接收新 Pod。"哪三条命令完成？如果集群只有 node2 一个 worker 呢？

<details><summary>答案</summary>

三条命令：`kubectl drain node2 --ignore-daemonsets --delete-emptydir-data` → 等副本在其他节点 Ready（`kubectl get pod -A -o wide`）→ `kubectl uncordon node2`。若 node2 是唯一 worker：驱逐的 Pod 无处可去，会全部 Pending（有 PDB 时 drain 直接卡住）——先扩容一个 worker（03 章 join 流程）或临时把 master 的 control-plane taint 去掉接收负载，再执行 drain。
</details>

## 延伸阅读

- 安全清空节点（drain 官方语义）：https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/
- 手动节点管理（cordon/uncordon）：https://kubernetes.io/docs/concepts/architecture/nodes/#manual-node-administration
- 应用故障排查（CrashLoop/ImagePull 等）：https://kubernetes.io/docs/tasks/debug/
- 集群故障排查（含 crictl）：https://kubernetes.io/docs/tasks/debug/debug-cluster/
- cri-tools（crictl 官方仓库）：https://github.com/kubernetes-sigs/cri-tools
- 本模块配套练习：labs 14-kubeadm-upgrade-drain、16-kubelet-troubleshoot、17-dns-debugging、18-crashloop-triage、19-resource-pressure-diagnosis、20-cluster-recovery-drill
