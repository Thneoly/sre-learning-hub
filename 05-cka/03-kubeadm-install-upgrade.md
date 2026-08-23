# 03 · kubeadm 集群安装、扩节点与版本升级

> 模块：05-cka ｜ 建议时长：3 小时 ｜ 关联认证：CKA-Cluster Architecture（kubeadm 安装/升级是明列考点）

## 学习目标

- 能在干净的 Ubuntu 22.04/24.04 上从零完成：内核参数 → containerd → kubeadm init → Calico → 集群可用
- 能解释 `kubeadm init` 每个关键参数（`--pod-network-cidr`、`--service-cidr`、`--apiserver-advertise-address` 等）的选型依据
- 能完成 worker / control-plane 两种节点 join，并处理 token 与 certificate-key 过期
- 能按步骤表完成一次 minor 升级（unhold → plan → apply → drain → kubelet → uncordon → hold）
- 能背出 version skew 规则：kubelet 最多比 apiserver 旧多少、升级为什么一次只能跨一个 minor

## 1. 从零 init：前置准备（所有节点）

以下步骤在**每个节点**（master 与 worker）上执行一次。环境假设：干净的 Ubuntu 22.04/24.04，2C/2G 以上，节点间网络互通，唯一网卡（多网卡时见 2.1 的 `--apiserver-advertise-address`）。

### 1.1 主机名、hosts 与 swap

```bash
# [任意节点] 每台设置唯一主机名（示例：master / worker1）
sudo hostnamectl set-hostname master

# [任意节点] 所有节点互写 hosts（按实际 IP 修改）
sudo tee -a /etc/hosts <<'EOF'
172.30.30.21 master
172.30.30.22 worker1
EOF

# [任意节点] 关 swap：kubelet 要求 swapoff，否则节点起不来
sudo swapoff -a
sudo cp /etc/fstab /etc/fstab.bak
sudo sed -i '/ swap / s/^/#/' /etc/fstab     # 注释开机挂载行，重启后仍保持关闭
free -h                                       # Swap 一行应全为 0B
```

### 1.2 内核模块与 sysctl

```bash
# [任意节点] 加载 overlay 与 br_netfilter（CNI 依赖）
cat <<'EOF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# [任意节点] 桥接流量进 iptables + 开 IP 转发
cat <<'EOF' | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# [任意节点] 验证（三条都应为 1）
sysctl net.bridge.bridge-nf-call-iptables net.bridge.bridge-nf-call-ip6tables net.ipv4.ip_forward
```

### 1.3 containerd：SystemdCgroup 是最大的坑

```bash
# [任意节点] 安装并生成默认配置
sudo apt-get update
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# [任意节点] 关键一步：cgroup driver 改为 systemd（kubelet 默认用 systemd）
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
grep SystemdCgroup /etc/containerd/config.toml    # 应输出 SystemdCgroup = true

# [任意节点] 重启并设自启
sudo systemctl restart containerd
sudo systemctl enable containerd
sudo crictl info | grep cgroupDriver 2>/dev/null || sudo ctr version   # 确认 containerd 活着
```

漏改 `SystemdCgroup` 的典型后果：集群能 init 成功，但之后 kubelet 报 `failed to get container info for ...`、Pod 状态异常——两边的 cgroup driver 不一致。若镜像仓库拉取慢，可另行修改 `sandbox_image`（以环境内镜像源为准）。

### 1.4 安装 kubelet / kubeadm / kubectl

```bash
# [任意节点] k8s 官方 apt 仓库（pkgs.k8s.io 按 minor 分仓库，这里以 v1.31 为例）
sudo apt-get install -y apt-transport-https ca-certificates curl gpg
sudo mkdir -p -m 755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update

# [任意节点] 安装三个组件并锁定版本（防止 apt upgrade 意外升级）
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
kubeadm version
```

## 2. kubeadm init：参数选择与执行

### 2.1 参数速查

| 参数 | 作用 | 什么时候必须显式给 |
| --- | --- | --- |
| `--pod-network-cidr` | Pod IP 段，写入 kubeadm-config，CNI 要与之保持一致 | 凡是装 CNI 都建议给；本环境用 `10.244.0.0/16`（与 Calico 配置一致） |
| `--service-cidr` | Service VIP 段 | 默认 `10.96.0.0/12`；与内网已有网段冲突时改 |
| `--apiserver-advertise-address` | apiserver 对外宣告的地址 | 多网卡 / 有 NAT 网卡时必须指定到集群互联那张卡 |
| `--kubernetes-version` | 固定版本，避免拉最新 | 考试与练习都建议固定，如 `1.31.4`（可用值以 `kubeadm upgrade plan` 或 apt-cache 为准） |
| `--service-dns-domain` | 集群 DNS 后缀 | 默认 `cluster.local`，一般不动 |
| `--cri-socket` | 指定 runtime endpoint | containerd 默认可省；用 cri-dockerd 时必须 `unix:///run/cri-dockerd.sock` |
| `--control-plane-endpoint` | HA 集群的 VIP/LB 地址 | 多 master 或前置负载均衡时；单 master 可省 |
| `--upload-certs` | 上传 control-plane 证书供其他 master join | 初始化多 master 时配合 `--certificate-key` |
| `--ignore-preflight-errors` | 跳过个别预检 | 练习机 1 核/内存偏小时给 `NumCPU,Mem`（生产慎用） |

### 2.2 init 执行

```bash
# [master] 初始化（按实际网卡 IP 修改 advertise-address）
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --apiserver-advertise-address=172.30.30.21 \
  --kubernetes-version=1.31.4 \
  --image-repository=registry.k8s.io
```

成功输出末尾有两段"后续步骤"，照抄即可：

```bash
# [master] 配 kubectl
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# [worker1] 临时拷 kubeconfig 的替代法（考试常用）
# scp master:/etc/kubernetes/admin.conf ~/.kube/config && chown $(id -u):$(id -g) ~/.kube/config
```

此刻 `kubectl get nodes` 里 master 是 `NotReady`——因为还没装 CNI，这属于预期中间态，先别排错。

### 2.3 装 Calico

```bash
# [master] tigera operator（本仓库练习环境也可用 /opt/yaml/tigera-operator.yaml 本地副本）
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/tigera-operator.yaml

# [master] 下载 custom-resources 并把 cidr 改成与 init 一致的 10.244.0.0/16
curl -LO https://raw.githubusercontent.com/projectcalico/calico/v3.28.0/manifests/custom-resources.yaml
sed -i 's#cidr: 192.168.0.0/16#cidr: 10.244.0.0/16#' custom-resources.yaml
kubectl create -f custom-resources.yaml

# [master] 等 Calico 起来，节点转 Ready
kubectl -n calico-system get pod --watch
# 全部 Running 后 Ctrl+C
kubectl get nodes        # STATUS 应为 Ready
```

`cidr` 不一致的症状：calico-node 一直 `Init:0/2` 或 Pod 拿不到 IP（`podCIDR` 分配了但 IPAM 池对不上）。改法就是让 Calico 的 `ipPools.cidr` 等于 init 时的 `--pod-network-cidr`（题库手册题目 13 的考点）。

### 2.4 单机练习集群去 taint

```bash
# [master] 单节点想跑业务负载，去掉 control-plane 的 NoSchedule
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
kubectl describe node master | grep -i taint     # 应无输出（NoSchedule 污点已移除）
```

## 3. join 流程：worker 与 control-plane

前置：worker 节点已完成第 1 节全部步骤（含安装 kubelet/kubeadm 与 hold，**不执行 init**）。

### 3.1 生成与使用 join 命令

```bash
# [master] 生成完整 join 命令（token 默认 24 小时有效）
kubeadm token create --print-join-command
# 输出形如：
# kubeadm join 172.30.30.21:6443 --token abcdef.0123456789abcdef \
#     --discovery-token-ca-cert-hash sha256:3f2a...

# [worker1] 直接粘贴执行（需要 root：加 sudo）
sudo kubeadm join 172.30.30.21:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:3f2a...
```

token 相关操作：

```bash
# [master] 查看现存 token 与剩余有效期
kubeadm token list

# [master] 过期了就再发一个；练习环境可发永久 token（生产不要）
kubeadm token create --ttl 0 --print-join-command

# [master] 丢了 CA hash 也能查（discovery-token-ca-cert-hash 的值）
openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | \
  openssl rsa -pubin -outform DER 2>/dev/null | sha256sum
```

### 3.2 join 第二个 control-plane（多 master 时）

```bash
# [master] init 时没带 --upload-certs 的话，补传证书（certificate-key 默认 2 小时有效）
sudo kubeadm init phase upload-certs --upload-certs
# 输出：Using certificate key: <hex>

# [master] 生成带 --control-plane 的 join 命令
kubeadm token create --print-join-command --certificate-key <上面的hex>

# [worker1] 以 control-plane 身份 join（同样要求已装 kubelet/kubeadm）
sudo kubeadm join 172.30.30.21:6443 --token <token> \
    --discovery-token-ca-cert-hash sha256:<hash> \
    --control-plane --certificate-key <hex> \
    --apiserver-advertise-address=172.30.30.22
```

两种 join 的差别：worker join 后节点角色是 `<none>`；control-plane join 会额外生成一份 apiserver/etcd 静态 Pod 清单与证书，节点角色变 `control-plane`。

### 3.3 join 失败三查

```bash
# [worker1] 1. 网络与端口：6443 必须可达
nc -zv 172.30.30.21 6443

# [worker1] 2. runtime 就绪：containerd active 且 SystemdCgroup=true
sudo systemctl status containerd --no-pager
grep SystemdCgroup /etc/containerd/config.toml

# [worker1] 3. 残留状态：失败重试前先清理（join 卡在 preflight 时）
sudo kubeadm reset
sudo rm -f /etc/cni/net.d/* /var/lib/kubelet/* -r
sudo systemctl restart kubelet containerd
```

## 4. 升级演练

### 4.1 版本偏差（skew）规则

| 组件对 | 规则 |
| --- | --- |
| kube-apiserver ↔ 其他 control plane 组件（scheduler/controller-manager） | 必须同一 minor 版本 |
| kubelet ↔ kube-apiserver | kubelet 不得比 apiserver **新**；最多可**旧** 3 个 minor（1.28+ 支持 n-3，1.27 及更早为 n-2） |
| kubectl ↔ kube-apiserver | 可新可旧，各不超过 1 个 minor |
| kubeadm ↔ 目标版本 | 升级 control plane 前，kubeadm 版本必须等于目标 control plane 版本（`kubeadm upgrade` 只能升到 kubeadm 自身版本） |
| etcd | 版本随 `kubeadm upgrade apply` 自动处理，无需手工干预 |
| 升级路径 | **一次只能升一个 minor**：1.31→1.32→1.33，不允许 1.31 直升 1.33 |

```
# [图] 一次 minor 升级中各组件版本的相对关系（1.31 → 1.32）
时间轴 ──────────────────────────────────────────────────────►
apiserver(scheduler/cm):  1.31 ──────────► 1.32 ──────────► 1.32
kubeadm(master):         1.31 ──► 1.32 ──(apply)────────────────────►
kubelet(master):         1.31 ─────────────────────► 1.32
kubelet(worker1):        1.31 ─────────────────────────────► 1.32
                          升级期间 kubelet 落后 apiserver ≤1 个 minor，skew 规则允许
```

### 4.2 升级前检查清单

```bash
# [master] 1. 集群健康基线：全 Ready、无异常 Pod
kubectl get nodes
kubectl get pod -A | grep -vE 'Running|Completed'

# [master] 2. 备份 etcd（重大变更前必做，做法见 04 章）
# [master] 3. 把 apt 仓库指向目标 minor（pkgs.k8s.io 每个 minor 一个仓库！）
sudo sed -i 's#/core:/stable:/v1.31/deb# /core:/stable:/v1.32/deb#' /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update

# [master] 4. 查看可用的精确版本号（下面示例用 1.32.4-1.1，以本输出为准）
apt-cache madison kubeadm | head
```

### 4.3 升级步骤表（control-plane 节点）

```bash
# [master] ① 解锁并升级 kubeadm 到目标版本（版本号换成 madison 查到的）
sudo apt-mark unhold kubeadm && \
sudo apt-get install -y kubeadm=1.32.4-1.1 && \
sudo apt-mark hold kubeadm
kubeadm version

# [master] ② 看升级计划：确认"可升级到"、etcd/coredns 组件版本
sudo kubeadm upgrade plan

# [master] ③ 应用 control plane 升级（静态 Pod 会逐个重建，需几分钟）
sudo kubeadm upgrade apply v1.32.4

# [master] ④ 升级本节点 kubelet 与 kubectl
sudo apt-mark unhold kubelet kubectl && \
sudo apt-get install -y kubelet=1.32.4-1.1 kubectl=1.32.4-1.1 && \
sudo apt-mark hold kubelet kubectl

# [master] ⑤ 重启 kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

说明：control-plane 节点**不需要 drain 自己**——`kubeadm upgrade apply` 会对 apiserver/etcd 等静态 Pod 做逐个滚动重建；单 master 集群里 drain 自己反而无意义（工作负载没有第二落点）。

### 4.4 升级步骤表（worker 节点）

```bash
# [master] ① 先驱逐负载并封锁节点
kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data
kubectl get node worker1     # 应显示 Ready,SchedulingDisabled

# [worker1] ② 升级 kubeadm（apt 仓库同样先切到 v1.32，见 4.2 第 3 步）
sudo apt-mark unhold kubeadm && \
sudo apt-get install -y kubeadm=1.32.4-1.1 && \
sudo apt-mark hold kubeadm

# [worker1] ③ worker 用 upgrade node（不是 apply）
sudo kubeadm upgrade node

# [worker1] ④ 升级 kubelet/kubectl 并重启
sudo apt-mark unhold kubelet kubectl && \
sudo apt-get install -y kubelet=1.32.4-1.1 kubectl=1.32.4-1.1 && \
sudo apt-mark hold kubelet kubectl
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# [master] ⑤ 恢复调度
kubectl uncordon worker1
kubectl get nodes -o wide     # worker1 版本列应变为 v1.32.4，Ready
```

`--ignore-daemonsets`：节点上必然有 CNI（calico-node）与 kube-proxy 这类 DaemonSet Pod，它们绑定在本节点，drain 不走就永远完不成；`--delete-emptydir-data`：本地可能有 emptyDir Pod，drain 默认拒绝删它们。语义细节见 06 章。

### 4.5 升级后验证

```bash
# [master] 版本与节点
kubectl get nodes -o wide
kubectl version

# [master] 系统组件全部 Running、无 CrashLoop
kubectl get pod -n kube-system -o wide
kubectl -n kube-system logs -l k8s-app=kube-proxy --tail=5 --all-containers

# [master] 业务回归：抽查一个跨节点 Service
kubectl run curl-test --image=curlimages/curl:8.10.1 -it --rm -- \
  sh -c 'curl -s http://kubernetes.default.svc'
```

## 实战演练：一次完整的 1.31 → 1.32（练习集群）

在 `ssh cka0000XX` 的练习集群上完整走一遍（预算 60 分钟）：

1. 按 4.2 完成基线检查与 etcd snapshot（04 章）。
2. 按 4.3 升级 master，记录 `kubeadm upgrade plan` 输出里 etcd 的目标版本。
3. 按 4.4 升级 worker1，drain 与 uncordon 各截屏一次 `kubectl get nodes`。
4. 故意复现一个故障再修复：把 worker1 的 `/etc/apt/sources.list.d/kubernetes.list` 保持在 v1.31，重复 4.4 ②，观察 `apt-get install kubeadm=1.32.4-1.1` 报"无法找到版本"——然后修正仓库再装。这是考场真实出现的坑。
5. 回滚不做（kubeadm 升级不提供原地回滚，靠 04 章的 etcd 恢复兜底），但把这次升级前的 snapshot 保留一周。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| init 后节点一直 NotReady | 没装 CNI，或 CNI 的 cidr 与 `--pod-network-cidr` 不一致 | 装/改 Calico ipPools.cidr（2.3） |
| kubelet 起来但 Pod 状态诡异、报 cgroup 相关错误 | containerd 的 `SystemdCgroup` 没改 true | 1.3 的 sed 后 `systemctl restart containerd kubelet` |
| `kubeadm upgrade plan` 提示无可用新版本 | apt 仓库还停在旧 minor（pkgs.k8s.io 按 minor 分仓） | 改 `kubernetes.list` 到目标 minor 再 `apt-get update` |
| `apt-get install kubeadm=1.32.4` 报无法定位 | 版本号写法不带包后缀 | Debian 包版本是 `1.32.4-1.1`，用 `apt-cache madison kubeadm` 查准确串 |
| drain 卡住不动 | DaemonSet Pod / emptyDir Pod / 未受管 Pod | `--ignore-daemonsets --delete-emptydir-data`；独立 Pod 加 `--force`（先确认可删） |
| join 报 token 不存在或过期 | token TTL 24h（certificate-key 2h）已过 | master 上 `kubeadm token create --print-join-command` 重发 |
| join 失败后重试仍失败 | 上次 join 的残留状态 | `sudo kubeadm reset` + 清 `/etc/cni/net.d` 后重来（3.3） |
| 升级后 `get nodes` 里 kubelet 版本没变 | 只升了 kubeadm，忘了升 kubelet 包或没 restart | 4.3 ④⑤ / 4.4 ④ 逐条核对 |

## 自测

1. 为什么 kubelet 可以比 kube-apiserver 旧，但绝不能比它新？升级流程是怎么利用这一点的？

<details><summary>答案</summary>

apiserver 是版本的"锚"：新 apiserver 必须兼容旧 kubelet 的请求格式（向上兼容由 apiserver 保证），反之旧 apiserver 可能不认识新 kubelet 的字段与特性。升级流程因此总是"先 apiserver（kubeadm upgrade apply）后 kubelet"——升级窗口内 kubelet 落后一个 minor，处于 skew 策略允许的 n-3 区间内，集群功能不中断。
</details>

2. 单 master 集群升级 control-plane 节点时，为什么官方步骤里没有 drain 这一步？什么节点才必须 drain？

<details><summary>答案</summary>

drain 的目的是把业务负载迁到别处滚动升级；control-plane 节点上的 apiserver/etcd/scheduler 是静态 Pod，绑定本节点、无法迁移，`kubeadm upgrade apply` 自带逐个重建的流程。必须 drain 的是承载普通业务 Pod 的节点——多 master 集群里其他 master 也可能跑业务，考试中最常见的是升级 worker 前的 drain/uncordon（lab 14 的主场景）。
</details>

3. `kubeadm upgrade plan` 显示最新可用版本是 1.33.x，而你当前是 1.31.4。给出正确的升级路径与理由。

<details><summary>答案</summary>

必须走 1.31→1.32→1.33 两次 minor 升级，每轮完整执行 4.3/4.4（kubeadm 先到位 → apply → 各节点 kubelet）。原因：skew 策略与 kubeadm 自身约束——kubeadm 只能升到与自身版本相同的 control plane 版本，且不支持跨 minor 直升；跳级会导致 etcd 数据格式、API 弃用项一次性叠加，出问题无法定位。
</details>

4. worker1 join 时报 `connection refused 172.30.30.21:6443`，但 master 上 apiserver 明明在跑。列出至少三个排查点。

<details><summary>答案</summary>

（1）advertise-address 绑到了错误网卡（如 NAT 口），worker 到该地址不通——init 时应显式 `--apiserver-advertise-address`；（2）worker 与 master 之间防火墙/安全组挡了 6443（`nc -zv master 6443` 验证）；（3）join 命令里的地址抄错（用了 hostname 但 hosts 没配）。逐条排除后再 `nc` 验证端口，最后重发 join。
</details>

5. `kubectl drain worker1 --ignore-daemonsets` 仍卡住，报某 Pod 无法删除。哪类 Pod 最可能？两个处理选项及取舍？

<details><summary>答案</summary>

最可能是挂了 emptyDir 的 Pod（drain 默认拒绝删除 emptyDir 数据）或裸 Pod（无控制器，删了不会重建）。选项一：加 `--delete-emptydir-data`（emptyDir 数据会丢，确认可丢再给）；选项二：裸 Pod 加 `--force`（强制删且不重建，等于放弃该 Pod）。考试里按题目要求给参数；生产里先确认数据归属再动手。
</details>

## 延伸阅读

- kubeadm 安装前置（内核参数与 containerd 官方口径）：https://kubernetes.io/docs/setup/production-environment/container-runtimes/
- 用 kubeadm 创建集群：https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- kubeadm 升级官方步骤（本文 4.3/4.4 的权威出处）：https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- 版本偏差策略：https://kubernetes.io/releases/version-skew-policy/
- Calico 安装与 ipPools 说明：https://docs.tigera.io/calico/latest/getting-started/kubernetes-self-managed/
- 本模块配套练习：lab 14-kubeadm-upgrade-drain
