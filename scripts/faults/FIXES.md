# 故障注入靶场 · 排障手册（FIXES）

> 模块：混沌靶场（scripts/faults）｜ 关联认证：CKA-故障排除 / CKA-集群架构 / CKS-集群加固
> 前置：kubeadm + Calico 单 master 集群（Ubuntu 22.04/24.04）

## 使用说明

- 注入：`sudo bash break-xxx.sh`；恢复：`sudo bash break-xxx.sh --restore`。
- 每个脚本注入前都会把**原值**备份到 `/tmp/fault-backup-xxx`，`--restore` 从备份还原——这是硬性安全设计。排障训练时**不允许**靠 `--restore` 交作业：先手工定位、手工修复，再用 `--restore` 核对。
- 正确训练顺序：注入 → 只看"告警现象" → 手工排障 → 对照本手册对应章节复盘 → `--restore` 恢复 → 重来一次。
- 注意：备份在 `/tmp` 下，**节点重启会丢**。丢了就按本手册的"修复命令"手工兜底。
- 注入前建议打 VMware 快照（见 `scripts/README.md` 的快照策略）；本手册按故障逐条展开，赶时间先看下面的决策表。

## 快速决策表：现象 → 先查什么

| # | 现象 | 第一跳命令 | 定位到 |
|---|------|-----------|--------|
| 1 | kubectl 全部 connection refused | `ss -lntp \| grep -E '6443\|6444'` | 6443 无监听且 6444 有、apiserver 容器 Running → 故障 11；6443 无监听、apiserver 容器反复重启 → 故障 3 |
| 2 | 节点 NotReady，已有 Pod 还在跑 | `kubectl describe node` 看 Conditions，再 `systemctl status kubelet` | Conditions 点名 NetworkPluginNotReady → 故障 4；kubelet 服务反复崩溃 → 故障 2 |
| 3 | 新 Pod 一直 Pending，事件有 Insufficient cpu | `kubectl describe node \| grep -A8 "Allocated resources"` | 资源被占满 → 故障 9 |
| 4 | 新 Pod 一直 Pending，几乎没有事件 | `kubectl -n kube-system get pods \| grep scheduler` | scheduler Pod 消失 → 故障 5 |
| 5 | 新 Pod 卡 ContainerCreating / Pending（节点被污 not-ready） | `kubectl describe pod` 看 Events + `kubectl get ds -A \| grep calico` | CNI 掉线 → 故障 4 |
| 6 | 全集群 Pod 解析域名失败 | `kubectl -n kube-system logs deploy/coredns --tail=50` | CoreDNS 转发坏 → 故障 1 |
| 7 | 只有某个 namespace 的 Pod 解析失败 | `kubectl exec <pod> -- cat /etc/resolv.conf` | resolv.conf 没有/不止集群 DNS → 故障 12 |
| 8 | 业务日志刷 Forbidden | `kubectl auth can-i <verb> <resource> --as=<报错里的 User>` | RBAC 被删 → 故障 6 |
| 9 | Service VIP 不通，Pod IP 直连通 | `kubectl get endpoints <svc>` | Endpoints 空 → 故障 7 |
| 10 | Pod 出网/跨节点全不通，容器全 Running | `sysctl net.ipv4.ip_forward` | 转发被关 → 故障 8 |
| 11 | Pod ImagePullBackOff | `kubectl describe pod` 看 Events 里镜像地址 | 坏 tag → 故障 10 |

---

## 1. break-coredns —— 集群 DNS 解析失效（难度 ★★☆）

### 现象（告警原文）

- Pod 内 `nslookup baidu.com` 失败：`connection timed out; no servers could be reached` 或 `server can't find baidu.com: SERVFAIL`。
- 业务日志大量 `dial tcp: lookup xxx on 10.96.0.10:53: no such host`。
- CoreDNS Pod 本身 Running、READY 1/1、不重启。

### 排查路径（先看什么）

```bash
# [master] 第一步：区分"全挂"还是"个别挂"——起一个干净测试 Pod
kubectl run dns-test --image=busybox:1.36 --restart=Never -it --rm -- nslookup baidu.com

# [master] 第二步：CoreDNS 自身日志，看有没有 forward 报错
kubectl -n kube-system logs deploy/coredns --tail=50

# [master] 第三步：直接看 Corefile 配置
kubectl -n kube-system get configmap coredns -o jsonpath='{.data.Corefile}'
```

第二步的日志里反复出现 `forward: ... read: connection refused`（上游拒绝连接）；第三步输出里 `forward` 行指向了明显不该出现的地址（本靶场是 `127.0.0.1:5353`），根因即在此。

> 现象边界：`*.svc.cluster.local` 完整 FQDN 由 CoreDNS 的 kubernetes 插件本地应答、不走 forward，
> 故障期间照常解析——别因为 `nslookup kubernetes.default.svc.cluster.local` 没挂就排除 DNS。
> 而**裸短名**（busybox `nslookup kubernetes.default`：busybox 先查裸名、SERVFAIL 即中止，
> 不再展开 search 域）会被 CoreDNS 转发到坏上游，同样失败。判断口径以"外部域名 SERVFAIL"为准。

### 根因

CoreDNS ConfigMap 的 `Corefile` 中 `forward .` 上游被改成无法响应的地址。kubeadm 默认 Corefile 里这一行带缩进且是块形式（`forward . /etc/resolv.conf { max_concurrent 1000 }`），注入脚本保留块结构只换上游，所以 CoreDNS 配置合法、能正常启动——Pod Running 不代表 DNS 没病。集群内所有外部递归查询都被转发到死地址；`kubernetes` 插件负责的 `*.svc.cluster.local` 完整 FQDN 由 CoreDNS 本地应答、不走 forward，仍可解析（排障时别被 FQDN 还能解析误导；裸短名则会随 forward 一起失败，见上面"现象边界"）。

### 修复命令

```bash
# [master] 把 forward 上游改回节点默认 DNS（保留原有块结构）
kubectl -n kube-system edit configmap coredns
#   将    forward . 127.0.0.1:5353 {
#   改回  forward . /etc/resolv.conf {

# [master] ConfigMap 不会热加载，必须滚动重启 CoreDNS
kubectl -n kube-system rollout restart deployment/coredns
kubectl -n kube-system rollout status deployment/coredns --timeout=120s
```

### 验证方法

```bash
# [master] 内部域名与外部域名都要通
kubectl run dns-test --image=busybox:1.36 --restart=Never -it --rm -- nslookup kubernetes.default
kubectl run dns-test --image=busybox:1.36 --restart=Never -it --rm -- nslookup baidu.com
```

### --restore 说明

备份 `/tmp/fault-backup-coredns` 保存的是原始 `Corefile` 全文。`--restore` 用它重建 ConfigMap 并滚动重启 CoreDNS，随后自动删除备份。

---

## 2. break-kubelet —— kubelet 认证配置损坏（难度 ★★☆）

### 现象（告警原文）

- `kubectl get nodes`：某节点约 40~60 秒后变 NotReady。
- 节点上已有 Pod 继续运行，但无法新建/删除，`kubectl logs/exec` 对该节点 Pod 报错。

### 排查路径（先看什么）

```bash
# [master] 第一步：确认是哪个节点、从什么时候开始
kubectl get nodes -o wide

# [故障节点] 第二步：kubelet 服务状态——activating (auto-restart) 就是反复崩溃
systemctl status kubelet

# [故障节点] 第三步：看崩溃原因
journalctl -u kubelet -n 50 --no-pager
```

`journalctl` 里能看到类似 `failed to construct kubelet dependencies: unable to load client CA file /etc/kubernetes/pki/nonexistent-ca.crt: open ...: no such file or directory` 的报错，直接点名坏掉的路径。

> 环境提示（本靶场 VM）：journald 未落盘（`journalctl -u kubelet` 报 "No journal files
> were found"），日志只在 `/var/log/syslog`。`journalctl` 查不到时改用：
> `grep kubelet /var/log/syslog | tail -20`

### 根因

`/var/lib/kubelet/config.yaml` 中 `authentication.x509.clientCAFile` 被指向不存在的文件。kubelet 启动时构建 X509 认证器失败即退出，systemd 反复拉起，节点心跳（lease 更新）停止，超过 `node-monitor-grace-period`（默认 40s）后节点被标记 NotReady。

### 修复命令

```bash
# [故障节点] 把 CA 路径改回 kubeadm 默认值
sudo sed -i 's|clientCAFile: .*|clientCAFile: /etc/kubernetes/pki/ca.crt|' /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet
```

### 验证方法

```bash
# [故障节点]
systemctl status kubelet          # active (running)，不再 auto-restart

# [master] 约 30 秒内
kubectl get nodes                 # 回到 Ready
```

### --restore 说明

备份 `/tmp/fault-backup-kubelet/config.yaml` 是改动前的完整配置。`--restore` 原文件覆盖回去并重启 kubelet，随后删除备份目录。

---

## 3. break-etcd-endpoint —— apiserver 连不上 etcd（难度 ★★★）

### 现象（告警原文）

- kubectl 任意命令 `The connection to the server ...:6443 was refused` 或超时。
- 已有业务 Pod 与 Service 转发不受影响（数据面不依赖 apiserver）。

### 排查路径（先看什么）

注意：此时 kubectl 不可用，一切排查用节点上的容器运行时工具。

```bash
# [master] 第一步：看 apiserver 容器是不是在反复重启
crictl ps -a | grep kube-apiserver

# [master] 第二步：看崩溃容器日志，会直接打出连不上的地址
crictl logs --tail 50 "$(crictl ps -a -q --name kube-apiserver | head -1)"

# [master] 第三步：确认 etcd 本身是好的，再查 manifest
ss -lntp | grep 2379                                # etcd 还在正常监听
grep etcd-servers /etc/kubernetes/manifests/kube-apiserver.yaml
```

第三步对比：etcd 在 2379 正常监听，而 manifest 里 apiserver 却指向了另一个端口（2399）。

### 根因

kube-apiserver 静态 Pod 的 `--etcd-servers` 被改为错误地址（`https://127.0.0.1:2399`）。apiserver 启动时连不上 etcd 即崩溃，kubelet 不断按 manifest 重建，形成 crash loop，等价于控制面整体失联。

### 修复命令

```bash
# [master] 改回正确端口
sudo sed -i 's|--etcd-servers=.*|--etcd-servers=https://127.0.0.1:2379|' \
  /etc/kubernetes/manifests/kube-apiserver.yaml
# kubelet 监测到 manifest 变化，约 1~2 分钟内自动重建容器
```

### 验证方法

```bash
# [master]
crictl ps | grep kube-apiserver     # 稳定 Running，RESTARTS 不再增长
kubectl get nodes                   # 控制面恢复
journalctl -u kubelet --since -5min | grep -i apiserver
```

### --restore 说明

备份 `/tmp/fault-backup-etcd-endpoint/kube-apiserver.yaml` 是原始 manifest。`--restore` 纯文件复制，**不依赖 kubectl**——这是有意设计：apiserver 挂掉时恢复手段必须绕过 apiserver。

---

## 4. break-cni —— Calico 被下线（难度 ★★☆）

### 现象（告警原文）

- `kubectl get nodes`：节点约 1 分钟内变 NotReady。`describe node` 的 Conditions 里：
  `Ready=False ... Message:container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady message:"Network plugin returns error: cni plugin not initialized"`。
- 新建 Pod 一直 Pending：`FailedScheduling ... node(s) had untolerated taint(s) node.kubernetes.io/not-ready`
  （NotReady 带来的连带污点）；已在节点上重建的 Pod 卡 ContainerCreating。
- `kubectl get pods -A | grep calico-node` 为空，但节点上已有的旧 Pod 还在运行。

### 排查路径（先看什么）

```bash
# [master] 第一步：节点为什么 NotReady——看 Conditions，本故障会点名 CNI
kubectl describe node | grep -A6 Conditions

# [master] 第二步：全局看 CNI 组件还在不在
kubectl get daemonset -A | grep -E 'calico|flannel'

# [master] 第三步：看 CNI Pod 实况与节点上的 CNI 配置
kubectl get pods -A | grep calico
ls /etc/cni/net.d/        # [故障节点] 配置目录被清空同样是 CNI 下线的特征
```

第二步会发现 calico-node 的 DESIRED/CURRENT 变成 0（nodeSelector 多了个陌生标签），第三步一个 agent Pod 都没有。

### 根因

calico-node DaemonSet 的 Pod 模板 `nodeSelector` 被塞进一个不存在的标签（`fault-cni-disabled: "true"`），集群里没有任何节点带这个标签，DaemonSet 控制器随即把所有 agent Pod 删光；节点上的 `/etc/cni/net.d` CNI 配置也一并消失。kubelet 的网络就绪检查失败，于是：节点被置为 NotReady（并连带 `node.kubernetes.io/not-ready` 污点，新 Pod 无法调度），沙箱创建报 `cni plugin not initialized`。已有 Pod 的 veth 设备还在，所以在设备被回收前"回光返照"式正常。

> 背景知识一：DaemonSet 没有 `spec.replicas` 字段、也没有 scale 子资源
> （`kubectl scale daemonset xxx` 直接 404），所以"缩容到 0"这类故障在 DS 上
> 的等价实现就是 nodeSelector 匹配不到节点——线上排障时看到的则是镜像/容忍度被改等变体。
> 背景知识二：只删 agent Pod、不动 net.d 时节点不会 NotReady，新 Pod 甚至能拿到 IP
> 正常 Running，但 Felix 不在、数据面无人接管，Pod IP 间互访逐步不通——"看起来都好，
> 其实网络已瘫"的形态，排障时要靠 ping 打点发现。

### 修复命令

```bash
# [master] 先看当前 nodeSelector，确认多出来的坏 key
kubectl -n kube-system get ds calico-node -o jsonpath='{.spec.template.spec.nodeSelector}'

# [master] strategic merge patch：键的值置 null 即删除该键，不影响其他键
kubectl -n kube-system patch daemonset calico-node \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"fault-cni-disabled":null}}}}}'
# calico-node 回来后会自动重写 /etc/cni/net.d 配置，节点约 1 分钟内恢复 Ready
```

### 验证方法

```bash
# [master]
kubectl -n kube-system get pods -o wide | grep calico-node   # 每节点一个 Running
kubectl -n <ns> delete pod <卡住的Pod>                        # 重建后能拿到 IP 正常 Running
kubectl run net-test --image=busybox:1.36 -it --rm -- ping -c2 <另一Pod的IP>
```

### --restore 说明

备份目录 `/tmp/fault-backup-cni/` 记录 DaemonSet 所在 namespace，并保存了移走的 net.d 配置文件。`--restore` 把配置移回 `/etc/cni/net.d`，再用 strategic merge patch 把坏 key 的值置 null（等价于删除该键），恢复每节点一个 agent。

---

## 5. break-static-pod —— 静态 Pod manifest 被移走（难度 ★★☆）

### 现象（告警原文）

- `kubectl -n kube-system get pods` 里 kube-scheduler Pod 直接消失（不是 CrashLoopBackOff）。
- 新建 Deployment 的 Pod 永远 Pending；apiserver、etcd、controller-manager 全部正常。

### 排查路径（先看什么）

```bash
# [master] 第一步：Pending Pod 的 describe 往往连 FailedScheduling 事件都很少
kubectl -n <ns> describe pod <pending-pod>

# [master] 第二步：控制面组件盘点——谁不在？
kubectl -n kube-system get pods

# [master] 第三步：去静态 Pod 目录看文件
ls -l /etc/kubernetes/manifests/
```

manifest 目录里少了 `kube-scheduler.yaml`：kubelet 没有 manifest 可看，自然不再创建该静态 Pod。

### 根因

kubelet 通过监视 `/etc/kubernetes/manifests/` 管理静态 Pod。manifest 文件被移出目录后，kubelet 会删除对应 Pod。调度器消失，所有新建 Pod 无人调度，永远 Pending；由于静态 Pod 不受 Deployment/ReplicaSet 控制，没有任何控制器会把它拉回来。

### 修复命令

```bash
# [master] 首选：把文件放回去（本靶场移到了 /tmp/fault-backup-static-pod/）
sudo mv /tmp/fault-backup-static-pod/kube-scheduler.yaml /etc/kubernetes/manifests/

# [master] 备份丢失时：让 kubeadm 重新生成（参数与集群默认一致，建议对照其他控制面组件检查）
sudo kubeadm init phase control-plane scheduler
```

### 验证方法

```bash
# [master] 约 10~30 秒内
kubectl -n kube-system get pods | grep scheduler     # 重新出现并 Running
kubectl -n <ns> get pods                             # Pending 的 Pod 被调度为 Running
```

### --restore 说明

移出的 manifest 原件就存放在 `/tmp/fault-backup-static-pod/`。`--restore` 把它移回 `/etc/kubernetes/manifests/`，纯文件操作，不依赖 kubectl。

---

## 6. break-rbac —— 业务依赖的 ClusterRoleBinding 被删（难度 ★★☆）

### 现象（告警原文）

- fault-rbac 命名空间的 rbac-checker Pod 状态 Running，日志持续刷：
  `Error from server (Forbidden): pods is forbidden: User "system:serviceaccount:fault-rbac:fault-app-reader" cannot list resource "pods" in API group "" in the namespace "fault-rbac"`
- 集群其他一切正常：节点 Ready、网络畅通、其他命名空间无异常。

### 排查路径（先看什么）

```bash
# [master] 第一步：从日志里拿到报错的 User（即 ServiceAccount），直接验证权限
kubectl auth can-i list pods --as=system:serviceaccount:fault-rbac:fault-app-reader

# [master] 第二步：该 SA 被绑定了哪些角色？
kubectl get clusterrolebinding -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.roleRef.name}{"\n"}{end}' | grep fault

# [master] 第三步：对象还在不在（区分是 Role 没了还是 Binding 没了）
kubectl get clusterrole | grep fault
kubectl get clusterrolebinding | grep fault
```

第一步返回 `no`，第二、三步发现 ClusterRole 还在而 ClusterRoleBinding 消失——授权链断在绑定这一环。

### 根因

Kubernetes 的授权判定是 `User --(Binding)--> Role --(rules)--> Resource` 三段式。删掉 ClusterRoleBinding 后 SA 与 ClusterRole 失联，等于没有任何权限，RBAC 拒绝（不是认证失败，token 仍然有效）。

### 修复命令

```bash
# [master] 重建被删的绑定
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fault-demo-pod-reader-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fault-demo-pod-reader
subjects:
- kind: ServiceAccount
  name: fault-app-reader
  namespace: fault-rbac
EOF
```

### 验证方法

```bash
# [master]
kubectl auth can-i list pods --as=system:serviceaccount:fault-rbac:fault-app-reader   # yes
kubectl -n fault-rbac logs deploy/rbac-checker --tail=20                              # 不再 Forbidden
```

### --restore 说明

备份 `/tmp/fault-backup-rbac.yaml` 就是被删 ClusterRoleBinding 的完整 YAML（演示对象，本脚本自建，未动系统关键绑定）。`--restore` 重新 apply 该文件。演示命名空间保留，清理命令在脚本输出里。

---

## 7. break-endpoints —— Service 没有后端（难度 ★★☆）

### 现象（告警原文）

- `curl fault-web-svc.fault-ep.svc.cluster.local` connection refused 或挂起超时。
- 后端 Pod 全部 Running（deployment READY 2/2），用 Pod IP 直访是通的。

### 排查路径（先看什么）

```bash
# [master] 第一步：Endpoints 是不是空的——Service 故障十有八九先看这里
kubectl -n fault-ep get endpoints fault-web-svc

# [master] 第二步：对比 Service selector 与 Pod 实际 labels
kubectl -n fault-ep describe svc fault-web-svc | grep -A2 Selector
kubectl -n fault-ep get pods --show-labels

# [master] 第三步：新版本集群也可以看 EndpointSlice
kubectl -n fault-ep get endpointslices
```

第一步 ENDPOINTS 为 `<none>`；第二步一眼看出 selector 与 Pod labels 对不上。

### 根因

Service 的 `spec.selector` 被改成匹配不到任何 Pod 的值（`app: fault-web-typo`）。EndpointsController 不再选中任何后端，Endpoints 为空；kube-proxy 的转发规则没有目的地址，流量直接被拒。控制器与调度都没坏——是"选错人"了。

### 修复命令

```bash
# [master] 把 selector 改回与 Pod labels 一致
kubectl -n fault-ep patch svc fault-web-svc --type=json \
  -p '[{"op":"replace","path":"/spec/selector/app","value":"fault-web"}]'
```

### 验证方法

```bash
# [master] Endpoints 秒级回填（控制循环 1~2 秒一个周期）
kubectl -n fault-ep get endpoints fault-web-svc          # 出现两个 Pod IP
kubectl run ep-test --image=busybox:1.36 -it --rm --restart=Never -- \
  wget -qO- --timeout=3 fault-web-svc.fault-ep.svc.cluster.local
```

### --restore 说明

备份 `/tmp/fault-backup-endpoints` 记录原始 selector（键=值，取自注入时的集群现场）。`--restore` 按备份 patch 回去并删除备份。

---

## 8. break-ipforward —— 宿主机 IP 转发被关闭（难度 ★★☆）

### 现象（告警原文）

- 本节点 Pod curl 外网、访问其他节点 Pod IP 全部超时。
- 容器全部 Running，无 CrashLoop，应用日志除网络超时外无异常。
- 节点之间互相 ping 正常，SSH 正常。

### 排查路径（先看什么）

```bash
# [master] 第一步：节点与容器都"活着"，怀疑内核转发层
kubectl get pods -A -o wide            # Pod 都在，只是不通

# [故障节点] 第二步：直接查转发开关（正常集群必须是 1）
sysctl net.ipv4.ip_forward

# [故障节点] 第三步：对照确认转发链路
iptables -S FORWARD | head -5
```

第二步返回 `net.ipv4.ip_forward = 0`，根因落定。SSH/节点互 ping 走 INPUT 链不受影响，这是该故障"半边瘫"特征的来源。

### 根因

Pod 流量经 veth pair 进入宿主机协议栈后依赖 `net.ipv4.ip_forward=1` 做 routing/forward。kubelet 与 CNI 启动时都会把它打开，一旦被人为置 0，所有需要"转发"的路径（Pod→外网、Pod→其他节点、部分同节点 Pod→Pod）全部不通。

### 修复命令

```bash
# [故障节点] 立即恢复
sudo sysctl -w net.ipv4.ip_forward=1

# [故障节点] 防止重启后再丢（与集群既有持久化方式保持一致）
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-k8s-forward.conf
sudo sysctl --system
```

### 验证方法

```bash
# [master]
kubectl run net-test --image=busybox:1.36 -it --rm --restart=Never -- \
  wget -qO- --timeout=3 http://1.1.1.1      # 能返回内容即通
```

### --restore 说明

备份 `/tmp/fault-backup-ipforward` 存的是注入前的 sysctl 原值。`--restore` 把原值写回。注意：部分 Calico/kubelet 版本会周期性自行把该值改回 1，训练时若发现"故障自己好了"，这本身就是一条重要线索。

---

## 9. break-scheduler-pod —— 节点资源被低优先级 Pod 占满（难度 ★★☆）

### 现象（告警原文）

- fault-sched 命名空间的 fault-app 两个副本一直 Pending，0/2 READY。
- describe pod 事件：`FailedScheduling ... Insufficient cpu`。
- 节点 Ready，scheduler/controller-manager 都正常，已有业务不受影响。

### 排查路径（先看什么）

```bash
# [master] 第一步：看事件，确认是"资源不够"而不是"组件坏了"
kubectl -n fault-sched describe pod <pending-pod> | grep -A5 Events

# [master] 第二步：节点分配情况——requests 已顶到 100%？
kubectl describe node | grep -A8 "Allocated resources"

# [master] 第三步：找出吃 CPU 的大户
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.containers[0].resources.requests.cpu}{"\n"}{end}' | sort -t$'\t' -k2 -r | head
```

第三步会看到 `fault-sched/fault-sponge-xxxx` 独占了几千 millicore。

### 根因

一个低优先级（PriorityClass `fault-low`）的"资源海绵"Deployment 把节点可分配 CPU 几乎全部占用（requests 接近 allocatable）。Kubernetes 按 requests 而非实际用量做调度决策，后续任何请求 CPU 的新 Pod 都无节点可落；又因为业务 Pod 优先级（默认 0）不高于海绵（10），抢占也不会被触发，调度器只能持续输出 Insufficient cpu。

### 修复命令

```bash
# [master] 三选一：
# 1) 直接删海绵（最可靠）
kubectl -n fault-sched delete deployment fault-sponge
# 2) 降 requests——注意会触发滚动更新，而 maxUnavailable=0 时新海绵 Pod 落不下去、
#    旧海绵又不退场，rollout 会卡死：降完必须手工删掉旧的海绵 Pod
kubectl -n fault-sched set resources deployment/fault-sponge --requests=cpu=100m
kubectl -n fault-sched delete pod -l app=fault-sponge
# 3)（更有教学价值）给业务更高优先级，触发抢占把海绵挤走
kubectl -n fault-sched patch deployment fault-app --type=json \
  -p '[{"op":"add","path":"/spec/template/spec/priorityClassName","value":"system-cluster-critical"}]'
```

### 验证方法

```bash
# [master] 删除/降配后 fault-app 立即被调度
kubectl -n fault-sched get pods -w                     # Pending → Running 1/1
kubectl describe node | grep -A8 "Allocated resources" # requests 回落
```

### --restore 说明

所有对象都建在 fault-sched 命名空间，备份 `/tmp/fault-backup-scheduler-pod` 记录命名空间名。`--restore` 直接删除整个命名空间与 PriorityClass `fault-low`，海绵与演示业务一起清理。

---

## 10. break-imagepull —— 镜像拉取失败（难度 ★☆☆）

### 现象（告警原文）

- 新 Pod 状态 ErrImagePull，随后 ImagePullBackOff，按退避节奏反复重试。
- Events：`Failed to pull image "nginx:1.27.99-notexist": not found`。

### 排查路径（先看什么）

```bash
# [master] 第一步：Events 里是"镜像仓库返回的原始错误"
kubectl -n fault-imagepull describe pod <pod> | grep -A8 Events

# [master] 第二步：deployment 当前用的镜像串
kubectl -n fault-imagepull get deploy fault-web -o jsonpath='{.spec.template.spec.containers[0].image}'

# [master] 第三步（可选）：确认 registry 上该 tag 是否存在
docker manifest inspect nginx:1.27.99-notexist 2>&1 | head -3
```

区分三类错误：`not found/manifest unknown`（tag 不存在——本靶场）、`authentication required`（仓库认证）、`i/o timeout`（网络/代理问题）。修复动作不同。

### 根因

deployment 的镜像被改成不存在的 tag。kubelet 依 Pod spec 指定的镜像拉取，registry 返回 404，Pod 停在 ImagePullBackOff；Deployment 滚动更新卡住，旧副本（若在）继续服务。

### 修复命令

```bash
# [master] 改回存在的 tag。注意：新版 kubectl 的 create deployment NAME --image=X
# 生成的容器名取自镜像名（这里是 nginx，不是 deployment 名 fault-web）；
# 不确定时先查：kubectl -n fault-imagepull get deploy fault-web -o jsonpath='{.spec.template.spec.containers[0].name}'
kubectl -n fault-imagepull set image deployment/fault-web nginx=nginx:1.27-alpine
```

### 验证方法

```bash
# [master]
kubectl -n fault-imagepull rollout status deployment/fault-web --timeout=180s
kubectl -n fault-imagepull get pods                  # 全部 Running，BackOff Pod 消失
```

### --restore 说明

备份 `/tmp/fault-backup-imagepull` 存的是注入前的镜像字符串。`--restore` set image 改回并等待 rollout 完成。

---

## 11. break-apiserver-port —— apiserver 监听端口被改（难度 ★★★）

### 现象（告警原文）

- kubectl 任意命令 `The connection to the server ...:6443 was refused`。
- controller-manager/scheduler/kubelet 日志刷 connection refused。
- 已有业务 Pod 继续运行。

### 排查路径（先看什么）

```bash
# [master] 第一步：6443 没人监听，还是 apiserver 整个没起来？
ss -lntp | grep -E '6443|6444'

# [master] 第二步：6444 有进程在听？看看是谁（输出 pid/kube-apiserver 即"端口飞了"）
ss -lntp | grep 6444

# [master] 第三步：核对 manifest 与实际容器状态
grep secure-port /etc/kubernetes/manifests/kube-apiserver.yaml
crictl ps | grep kube-apiserver     # 容器 Running、不重启
```

与故障 3 的关键区别：那边 apiserver 起不来（crash loop）；这边 apiserver 活得好好的（kubeadm 把探针端口与 BindPort 写成同一个值，本靶场连探针一起搬到了新端口，所以容器健康稳定），纯粹是端口错位——所以第一跳永远先是 `ss -lntp`。

### 根因

kube-apiserver 静态 Pod 的 `--secure-port` 被改成 6444。所有客户端组件与 kubeconfig 仍指向 6443，等价于"服务换了门牌但没人通知客户"。TLS 与 etcd 全都正常。

### 修复命令

```bash
# [master] 改回默认端口。注意探针端口也要一起改回，否则容器会被探针反复杀死：
#   旧版 kubeadm manifest：liveness/readiness/startup 探针里直接写 port: 6444
#   新版（v1.31+）：探针写 port: probe-port，实际端口在 ports 段 containerPort: 6444
# 一刀切改法：
sudo sed -i 's/6444/6443/g' /etc/kubernetes/manifests/kube-apiserver.yaml
# kubelet 监测到 manifest 变化，约 1~2 分钟内自动重建容器
```

### 验证方法

```bash
# [master] 约 1~2 分钟内
ss -lntp | grep 6443                    # kube-apiserver 重新监听 6443
crictl ps | grep kube-apiserver         # Running
kubectl get nodes                       # 恢复
```

### --restore 说明

备份 `/tmp/fault-backup-apiserver-port/kube-apiserver.yaml` 是原始 manifest。`--restore` 纯文件覆盖，不依赖 kubectl（apiserver 失联时必须如此）。

---

## 12. break-dns-config —— Pod 级 DNS 配置错误（难度 ★★☆）

### 现象（告警原文）

- 只有 fault-dns 命名空间的 Pod 解析失败：`nslookup kubernetes.default` 超时。
- 其他命名空间（含 default）一切正常，CoreDNS 指标无异常。

### 排查路径（先看什么）

```bash
# [master] 第一步："单命名空间中招"几乎锁定 Pod 级配置，直接看 resolv.conf
kubectl -n fault-dns exec deploy/fault-dns-client -- cat /etc/resolv.conf

# [master] 第二步：看 workload 定义里的 dnsPolicy 与 dnsConfig
kubectl -n fault-dns get deploy fault-dns-client -o yaml | grep -B2 -A8 -E 'dnsPolicy|dnsConfig'
```

第一步输出里**只有** `nameserver 192.0.2.53`（RFC 5737 文档地址，永不可达），完全没有集群 DNS（10.96.0.10）——不是排错了顺序，而是被整份替换了。第二步能看到 `dnsPolicy: None` 加一份坏的 `dnsConfig`。

> 环境提示（本靶场网络）：若实验网络存在透明 DNS 劫持（任何目标 IP 的 53 端口都被网关应答，
> 返回 198.18.x.x 这类 fake-IP），"nslookup 超时"会被掩盖成"解析出怪地址"——判断依据改为
> resolv.conf 里**没有集群 DNS** 且解析结果不是真实 ClusterIP。

### 根因

deployment 的 `dnsPolicy` 被改为 `None` 且 `dnsConfig.nameservers` 指向不可达地址，Pod 的 resolv.conf 完全由这份坏配置生成，所有查询都被发往死地址。CoreDNS 本身无辜——这是"只有一部分 Pod 中招"类故障的典型代表。

深挖一个容易反直觉的点：kubelet 对 `dnsPolicy: ClusterFirst` + `dnsConfig` 的合并是把 dnsConfig 的 nameservers **追加在集群 DNS 之后**（源码 `appendDNSConfig`，官方文档措辞是 combined；见延伸阅读）。也就是说"只加一个坏 nameserver、不动 policy"时解析器根本轮不到它——所以本故障必须配合 `dnsPolicy: None` 才成立。反过来，线上遇到"Pod 配了自定义 DNS 却不生效"，答案也在这里。

### 修复命令

```bash
# [master] 改回默认 policy 并删掉坏 dnsConfig
kubectl -n fault-dns patch deployment fault-dns-client --type=json -p '[
  {"op":"replace","path":"/spec/template/spec/dnsPolicy","value":"ClusterFirst"},
  {"op":"remove","path":"/spec/template/spec/dnsConfig"}]'
```

### 验证方法

```bash
# [master] 滚动更新完成后
kubectl -n fault-dns exec deploy/fault-dns-client -- cat /etc/resolv.conf   # nameserver 10.96.0.10
kubectl -n fault-dns logs deploy/fault-dns-client --tail=5                  # nslookup 正常返回
```

### --restore 说明

备份 `/tmp/fault-backup-dns-config` 存的是注入前的 dnsPolicy 原值。`--restore` 改回原 policy、移除 dnsConfig 并等待 rollout。演示命名空间保留，清理命令在脚本输出里。

---

## 建议训练法：随机注入 + 限时排障

### 单轮流程（每轮 15~20 分钟）

```bash
# [master] 1. 随机抽一个故障注入（不给自己看脚本内容）
cd scripts/faults
FAULT=$(ls break-*.sh | shuf -n1)
sudo bash "$FAULT"

# [master] 2. 计时开始：只依据告警现象排障，目标 15 分钟内
#    a. 说出"第一跳命令"（对照上方决策表）
#    b. 定位根因（能指到具体对象/文件/参数）
#    c. 手工修复 + 验证通过

# [master] 3. 用 --restore 还原现场，并确认恢复后集群健康
sudo bash "$FAULT" --restore
kubectl get nodes && kubectl get pods -A | grep -Ev 'Running|Completed'
```

### 计分建议（满分 10）

| 维度 | 分值 | 标准 |
|------|-----|------|
| 第一跳方向 | 3 | 10 分钟内选中决策表对应方向，无大海捞针式乱试 |
| 根因定位 | 4 | 指到具体配置项/对象（如 `--secure-port`、Corefile 的 forward 行） |
| 修复与验证 | 2 | 修复命令一次成功，且做了验证而非"看起来好了" |
| 复盘 | 1 | 能写出该故障的监控/告警建议（下次如何更早发现） |

### 进阶玩法

1. **叠加注入**：先注入 2 个故障（如 coredns + endpoints），现象会互相掩盖，训练"先分域再下钻"。
2. **盲恢复**：不修，只允许 `--restore`，但必须先口头说出根因才允许执行。
3. **限时加压**：CKA 考试平均每题 6 分钟，把单轮目标逐步压到 8 分钟。
4. **写 Runbook**：每轮结束把"现象→命令→根因→修复"四行追加到自己的笔记，两周后回看能否 3 分钟内复现同样的排查路径。
5. **告警设计**：每个故障问自己"哪条 PromQL/哪条事件能在 1 分钟内暴露它"——这是从排障到可观测性的进阶（衔接 08-pca 模块）。

## 延伸阅读

- Troubleshooting Clusters：https://kubernetes.io/docs/tasks/debug/debug-cluster/
- Troubleshoot Applications：https://kubernetes.io/docs/tasks/debug/debug-application/
- Debugging DNS Resolution：https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- Pod 的 DNS 策略与 dnsConfig（含合并语义）：https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- Using RBAC Authorization：https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- kubelet Config 默认值：https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
- Static Pods：https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/
