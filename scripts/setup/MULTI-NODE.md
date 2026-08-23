# 多节点集群 · VMware 克隆扩容指南

> 模块：scripts（练习集群基础设施） ｜ 前置：`kubeadm-single-node.sh` 已跑通或全新三台 VM ｜ 预计 60~90 分钟

## 学习目标

- 能从单节点 master 克隆出 `1 master + 2 worker`，并说清克隆机必须处理的三大残留（machine-id / MAC / hostname）
- 能用 netplan 给克隆机配静态 IP，并解释 podCIDR 为什么不能与宿主 NAT 网段重叠
- 能走通 `kubeadm token create --print-join-command` → worker join → 节点 Ready 的完整流程并排查常见 join 故障

单节点集群覆盖了 80% 的考点，但有一类实验必须多节点：Pod 跨节点通信、`kubectl drain/cordon` 节点维护（05-cka lab 14）、NetworkPolicy 跨节点隔离、node-exporter 多节点采集。本文给出从单节点克隆出 `1 master + 2 worker` 的完整流程。

## 1. 目标拓扑

```
                VMware NAT 网段 192.168.31.0/24（示例，按你的实际 NAT 网段调整）
                                │
          ┌─────────────────────┼─────────────────────┐
          │                     │                     │
  ┌───────┴───────┐     ┌───────┴───────┐     ┌───────┴───────┐
  │     k8s-m     │     │    k8s-w1     │     │    k8s-w2     │
  │ 192.168.31.11 │     │ 192.168.31.12 │     │ 192.168.31.13 │
  │ master 2C/4G  │     │ worker 2C/4G  │     │ worker 2C/4G  │
  │  disk 40 GB   │     │  disk 40 GB   │     │  disk 40 GB   │
  └───────┬───────┘     └───────┬───────┘     └───────┬───────┘
          │                     │                     │
          └─────────────────────┴─────────────────────┘
                                │
              podCIDR 172.31.0.0/16（Calico，跨节点走 IPIP 隧道）
              serviceCIDR 10.96.0.0/12（kubeadm 默认，无需改动）
```

规划要点：

| 项目 | 取值 | 说明 |
|------|------|------|
| 节点规格 | 每台 2 vCPU / 4 GB / 40 GB | 三台总内存 12 GB，宿主机至少 16 GB |
| 节点名 | `k8s-m` / `k8s-w1` / `k8s-w2` | hostname 必须唯一，小写、不含下划线 |
| IP | 静态，同网段连续 | DHCP 保留或 netplan 静态配置，见 2.3 节 |
| podCIDR | `172.31.0.0/16` | 与单节点脚本默认一致；克隆自单节点时**不要改** |
| serviceCIDR | `10.96.0.0/12` | kubeadm 默认，无特殊需求不动 |

podCIDR 与 NAT 网段**重叠**是"Pod 跨节点不通"的第一大坑：本例 NAT 用 `192.168.31.0/24`，与 podCIDR `172.31.0.0/16` 不重叠，正好安全。若你的 VMware NAT 网段恰好在 `172.16.0.0 ~ 172.31.255.255`（RFC1918 的 172.16/12 段）内，建集群时务必加 `--cidr 10.244.0.0/16` 之类的不重叠网段；已建好的集群改 podCIDR 很麻烦，不如三台 reset 后重建。

## 2. 从单节点克隆（推荐路径）

前提：单节点集群那台 VM 已按 `scripts/README.md` 打了快照 `cluster-ready`。

### 2.1 克隆前准备 master

先在 master 上确认 podCIDR 与 taint 状态，多节点后 master 通常不再跑业务 Pod：

```bash
# [master] 确认当前 podCIDR（克隆出来的 worker 要加入同一个集群，不能另起网段）
kubectl get nodes -o jsonpath='{.items[0].spec.podCIDR}'; echo
```

```bash
# [master] 把 control-plane taint 加回去（可选；加了之后业务 Pod 只上 worker）
kubectl taint nodes k8s-m node-role.kubernetes.io/control-plane=:NoSchedule
```

### 2.2 VMware 克隆与"三件套"去重

在 VMware Workstation / vSphere 里对 master VM 做**完整克隆（Full Clone）**两次，得到 w1、w2。克隆机有三大残留必须清理：machine-id、MAC 地址、hostname。MAC 在克隆向导勾选 "I copied it" / 自动生成新 MAC 即可（Workstation 默认处理）；machine-id 和 hostname 手工改：

```bash
# [worker1] 克隆后第一次开机，root 登录执行（w2 上同理，主机名换成 k8s-w2）
hostnamectl set-hostname k8s-w1
rm -f /etc/machine-id /var/lib/dbus/machine-id
systemd-machine-id-setup
```

```bash
# [worker1] 检查 MAC 已与 master 不同（克隆向导自动分配则本步只是确认）
ip link show | grep ether
```

若 MAC 撞了（手工复制虚拟机磁盘目录时会出现），在 VMware 设置里：Network Adapter → Advanced → Generate 生成新 MAC；netplan 配置里若写死了 `match: macaddress` 也要同步改。

### 2.3 静态 IP（netplan）与 hosts

```bash
# [worker1] 写静态 IP（文件名以 ls /etc/netplan/ 实际结果为准，覆盖或新建均可）
sudo tee /etc/netplan/00-k8s.yaml <<'EOF'
network:
  version: 2
  ethernets:
    ens160:                       # 网卡名用 ip a 确认，NAT 下常见 ens160/ens33
      dhcp4: false
      addresses: [192.168.31.12/24]
      routes:
        - to: default
          via: 192.168.31.2        # NAT 网段网关，VMware NAT 通常是 .2
      nameservers:
        addresses: [223.5.5.5, 8.8.8.8]
EOF
sudo netplan apply
```

```bash
# [worker1] 三台机器都写 hosts（kubeadm join 的证书预签、后续节点互解析都用得上）
sudo tee -a /etc/hosts <<'EOF'
192.168.31.11 k8s-m
192.168.31.12 k8s-w1
192.168.31.13 k8s-w2
EOF
```

## 3. worker 侧清理 kubeadm 残留再 join

**关键点**：克隆自装好集群的 master，worker 机器上带着整套控制面身份（`/etc/kubernetes/pki`、`admin.conf`、etcd 数据）。直接 `kubeadm join` 一定失败，先 reset：

```bash
# [worker1] 把克隆残留清干净（脚本对"没有集群"的状态也安全，w2 同理）
sudo bash scripts/setup/reset-cluster.sh
```

reset 后 worker 保留了 `kubeadm/kubelet/containerd` 二进制与内核参数（`modules-load.d`、`sysctl.d`、swap 关闭都是持久化的），这正是 join 需要的全部前置条件——**不需要**重跑 `kubeadm-single-node.sh`。

## 4. join 流程

```bash
# [master] 生成 join 命令（token 默认 24h 过期，过期重新生成一条即可）
kubeadm token create --print-join-command
# 输出形如：
# kubeadm join 192.168.31.11:6443 --token abcdef.0123456789abcdef \
#   --discovery-token-ca-cert-hash sha256:...
```

```bash
# [worker1] 执行上面输出的完整命令（w2 同理）
sudo kubeadm join 192.168.31.11:6443 --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:<你的hash>
```

```bash
# [master] 观察 worker Ready（Calico 会自动在新节点起 calico-node Pod）
kubectl get nodes -w
# 看到 k8s-w1 / k8s-w2 Ready 后 Ctrl+C 退出 watch
kubectl get pods -n kube-system -o wide | grep calico
```

join 排错速查：

| 症状 | 原因 | 解法 |
|------|------|------|
| `connection refused 6443` | master 防火墙或 join 地址写错 | master 上 `ss -lntp \| grep 6443` 确认监听；核对 worker 上的 join 命令 |
| preflight 报 swap 未关 | 克隆机 fstab 的 swap 注释没生效 | `swapoff -a` 后重跑 join |
| `token invalid` / `token expired` | token 过了 24h 有效期 | master 重新 `kubeadm token create --print-join-command` |
| 节点加入但 NotReady | worker 上 CNI 接口/配置残留 | worker 重跑 `reset-cluster.sh` 后再 join |
| 节点反复 NotReady→Ready 抖动 | 克隆机 machine-id 相同导致节点对象冲突 | 回到 2.2 节检查 machine-id |

## 5. 多节点专有实验校验

集群变多节点后，值得立刻做的三个验证（都是单节点做不动的）：

```bash
# [master] 1) 跨节点 Pod 通信：两个调试 Pod，确认落在不同节点后互 ping Pod IP
kubectl run net-a --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl run net-b --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl get pod net-a net-b -o wide
POD_B_IP=$(kubectl get pod net-b -o jsonpath='{.status.podIP}')
kubectl exec net-a -- ping -c 2 "$POD_B_IP"
kubectl delete pod net-a net-b
# busybox 来自 Docker Hub：拉不动时先给节点配 DOCKER_MIRROR 或代理（见 scripts/README.md）
```

```bash
# [master] 2) 节点维护演练（对应 05-cka lab 14 与 06-node-maintenance-troubleshooting）
kubectl drain k8s-w1 --ignore-daemonsets --delete-emptydir-data
kubectl uncordon k8s-w1
```

```bash
# [master] 3) 监控栈多节点采集（08-pca 前置）：node-exporter 每个节点一个 Pod
kubectl get pod -n monitoring -l app.kubernetes.io/name=prometheus-node-exporter -o wide
```

## 6. 与单节点脚本的关系

| 场景 | 用什么 |
|------|--------|
| 从零搭单节点 | master 上跑 `kubeadm-single-node.sh`（一次跑完） |
| 单节点扩成多节点 | master 不动；克隆机跑 `reset-cluster.sh` → 手工 `kubeadm join`（本文第 3、4 节） |
| 全新三台 VM 搭多节点 | 只在 master 上跑 `kubeadm-single-node.sh`（它就是 master 的完整初始化）；worker 装好 containerd/kubeadm 后直接 join，**从来不需要**跑 single-node 脚本 |
| 整个集群推倒重来 | 每台节点各自跑 `reset-cluster.sh`，master 再重跑 `kubeadm-single-node.sh`，worker 重新 join |

全新 VM（不经克隆）手工初始化 worker 时，需要的最小前置恰好是 single-node 脚本的 Step 1~4：关 swap、内核参数、containerd SystemdCgroup、安装 kubeadm/kubelet。可以把脚本拷到 worker 上执行完 Step 4 后 Ctrl+C，或直接照 `05-cka/03-kubeadm-install-upgrade.md` 的命令做。

## 常见坑

| 症状 | 原因 | 解法 |
|------|------|------|
| join "成功"但 `kubectl get nodes` 看不到 | worker 的 kubelet 还持着旧集群证书 | worker 上 `reset-cluster.sh` 后重新 join |
| Pod 跨节点不通、同节点通 | podCIDR 与 NAT 网段重叠（见第 1 节警告） | 三台全部 reset，`--cidr` 换非重叠网段重建 |
| 三台机器 hostname 相同 | 忘了 `hostnamectl set-hostname` | 回到 2.2 节重做；hostname 撞了节点会互相踢 |
| Grafana 突然访问不了 | 克隆后 NodePort 被别的服务占了 | `kubectl get svc -A | grep -E '30900|30903|30300'` 检查冲突 |
| 克隆机 containerd/docker 起不来 | machine-id 重复引发的一串玄学问题 | 重生成 machine-id 后 `systemctl restart containerd` |
| `kubectl logs` 间歇性失败 | hosts 没写全，节点名解析不稳定 | 三台都补 /etc/hosts（2.3 节） |

## 自测

<details><summary>1. 为什么克隆出来的 worker 必须先 reset 才能 join？直接 join 会发生什么？</summary>

克隆机带着 master 的 `/etc/kubernetes/pki`、`admin.conf`、`kubelet.conf` 与 etcd 数据。kubelet 启动时读到的 kubelet.conf 指向"自己是控制面"的身份，`kubeadm join` 的 preflight 会发现节点已存在集群配置而拒绝；或 join 后新旧的节点身份互相冲突，节点被反复踢出。reset 清掉这些身份文件，但保留二进制与内核参数，正好是 join 需要的干净前置状态。
</details>

<details><summary>2. podCIDR 和 VMware NAT 网段重叠会发生什么？为什么"同节点通、跨节点不通"？</summary>

Calico 为 Pod 网段在内核里写路由，重叠时去往"Pod IP"的流量被宿主当作同网段局域网主机直接 ARP/转发，永远不会进入 IPIP/VXLAN 隧道；反过来宿主访问某些"本地服务"的包也可能被 Pod 网段路由劫走。同节点 Pod 通信走本机 veth pair / 路由表短路径，不涉及跨节点隧道，所以看起来一切正常，跨节点才暴露。判断方法很简单：把 podCIDR 和 `ip route` 里的宿主网段做包含关系比较，有交集就换 `--cidr` 重建。
</details>

<details><summary>3. kubeadm 的 join token 过期了怎么办？discovery-token-ca-cert-hash 是哪来的、防的是什么？</summary>

`kubeadm token create --print-join-command` 随时生成新 token（默认 24h 有效；single-node 脚本 init 时带了 `--token-ttl=0` 即永不过期）。hash 是 master CA 证书公钥的 SHA256 指纹，worker 用它校验 control plane 身份，防止 join 到一个伪造的 apiserver（中间人）。可用 `openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl pkey -pubin -outform DER | openssl sha256` 自行核对。
</details>

<details><summary>4. 多节点后把 control-plane taint 加回 master，之前单节点时调度上去的业务 Pod 会怎样？</summary>

已运行的 Pod 不会被立即驱逐，taint 只影响新的调度决策；那些 Pod 在删除/重建（rollout、OOM 重启、节点重压）时会因无节点可调度而 Pending。要主动清走存量用 `kubectl drain k8s-m --ignore-daemonsets --delete-emptydir-data`，代价是 etcd/apiserver 等静态 Pod 之外的业务全部迁去 worker。
</details>

<details><summary>5. 三台 VM 的 /etc/hosts 为什么建议都写？不写会出什么问题？</summary>

kubelet 上报的节点名、apiserver 证书校验、Calico 节点间通信、node-exporter 的 instance 标签都依赖"节点名稳定可解析"。某节点 hostname 解析失败时，`kubectl logs`、metrics 采集、证书轮换都可能出现间歇性失败且很难定位。生产环境用 DNS，练习环境 hosts 文件最省事。
</details>

## 延伸阅读

- kubeadm 创建集群（官方）：https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
- kubeadm token 管理（官方）：https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-token/
- netplan 配置参考：https://netplan.readthedocs.io/en/latest/netplan-reference/
- Calico IP pool 配置（官方）：https://docs.tigera.io/calico/latest/networking/configuring/ippool
