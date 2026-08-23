# 10 · CNI 与 Pod 网络：veth、overlay 与 NetworkPolicy

> 模块：04-k8s-fundamentals ｜ 建议时长：3.5 小时 ｜ 关联认证：CKA-网络 / CKS-网络分段（NetworkPolicy）

## 学习目标

- 能解释 Pod 网络模型的三条要求（每 Pod 一 IP、NAT-free 互通、节点与 Pod 互通）及其推论
- 能操作节点上的工具观察到 pause 容器、veth pair、podCIDR 路由，画出"同节点/跨节点"两种包路径
- 能对比三种实现路线：VXLAN overlay 逐层拆包、BGP 路由、underlay；算清 VXLAN 的 MTU 开销
- 能对比 flannel / calico / cilium 的选型差异
- 能解释 NetworkPolicy"有策略即白名单"的默认翻转行为并落地一套 deny-all + 放行规则

## 1. Pod 网络模型：三条要求

K8s 对网络只有三条要求，所有 CNI 都是为了满足它们：

| 要求 | 含义 | 推论 |
| --- | --- | --- |
| 每 Pod 一个独立 IP | Pod 内所有容器共享一个 netns，像同一台机器上的进程；Pod 之间是 IP 级互通 | 不需要"容器端口映射"，Pod 里的进程监听什么端口就是什么端口 |
| Pod 之间 NAT-free | 任意两 Pod（无论是否同节点）直接用对方 Pod IP 通信，中间不做 SNAT | 对端看到的源 IP 就是 Pod IP；`externalTrafficPolicy` 才有"保源 IP"问题 |
| 节点代理可达所有 Pod | kubelet 与节点上的 agent 能和本节点全部 Pod 通信 | 健康检查、metrics 抓取不依赖额外网络 |

```
# [图] 一张图看懂 Pod 网络（以 Calico、10.244.0.0/16 为例）
        Node1 (podCIDR 10.244.1.0/24)          Node2 (podCIDR 10.244.2.0/24)
        ┌───────────────────────────┐          ┌───────────────────────────┐
        │ podA 10.244.1.5           │          │ podC 10.244.2.7           │
        │   │ eth0 (pod netns)      │          │   │ eth0 (pod netns)      │
        │   │ veth pair             │          │   │ veth pair             │
        │ cali<hash> (host netns)   │          │ cali<hash> (host netns)   │
        │   │                        │          │   │                        │
        │ 内核路由表                 │          │ 内核路由表                 │
        │ 10.244.2.0/24 ──(BGP/VXLAN)──────────►│ 10.244.1.0/24             │
        └───────────────────────────┘  underlay └───────────────────────────┘
        podA → podC：IP 头始终是 10.244.1.5 → 10.244.2.7，全程无 NAT
```

K8s 只定义 Service CIDR 与 Pod CIDR 两个平面（kubeadm 的 `--pod-network-cidr`，写入 kubeadm-config 的 `networking.podSubnet`），怎么把包送到目的地是 CNI 的事。

## 2. CNI 的位置：kubelet → CRI → CNI

kubelet 创建 Pod 时先让 containerd 起一个 sandbox（即 pause 容器）拿到 netns，再以 CRI 语义调用 CNI 插件（可执行文件）配置网络：

```
# [图] 一个 Pod 的网络建立流程
kubelet (CreatePodSandbox)
   → containerd 创建 pause 容器 → 得到新 network namespace
   → kubelet 调 CNI ADD：读 /etc/cni/net.d/*.conflist 选插件链
        1. IPAM 分配 Pod IP（host-local / calico-ipam / whereabouts）
        2. 建 veth pair：一端留在 host，一端塞进 pause 的 netns 成为 eth0
        3. 配路由/ARP/iptables/eBPF（不同 CNI 的分水岭）
   → Pod 内所有业务容器共享 pause 的 netns（join 同一个 ns）
```

CNI 规范由 containernetworking/cni 仓库维护：插件分 main（bridge/ptp/vlan/macvlan...）、meta（portmap/bandwidth/tuning...）、IPAM 三类，以 conflist 串联。

## 3. pause 容器与 veth pair：在节点上看真相

```bash
# [master] 起一个实验 Pod
kubectl run net-demo --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl get pod net-demo -o wide        # 记下 IP 和所在节点，假设是 worker1
```

```bash
# [worker1] CNI 配置与插件都在节点本地
cat /etc/cni/net.d/*.conflist | head -20
ls /opt/cni/bin/ | head
```

```bash
# [worker1] 找到 pause 进程，进入它的 netns
SANDBOX=$(crictl pods --name net-demo -q)
crictl ps --name net-demo        # 看到的是业务容器；pause 要用 inspectp 找
PID=$(crictl inspectp "$SANDBOX" | grep -oP '"pid":\s*\K[0-9]+' | head -1)
nsenter -t "$PID" -n ip addr     # Pod netns：eth0@if<N> 10.244.x.x
nsenter -t "$PID" -n ip route    # Pod 内默认路由指向 host 侧 veth
```

```bash
# [worker1] 验证 veth pair：Pod 里 eth0@if13 的 13 就是宿主机接口编号，反之亦然
ip -o link | grep cali | head
nsenter -t "$PID" -n ip -o link show eth0     # 输出形如 ...: eth0@if13@
ip -o link | awk -F': ' '$1+0==13 {print $2}'  # 宿主机编号 13 的接口，即 cali<hash>
```

要点：业务容器根本没有"自己的网卡"——它们的 netns 就是 pause 的 netns，`localhost` 互通、端口共享都因此而来。pause 的另一职责是收割僵尸进程（PID 1），所以它必须是 Pod 内寿命最长的进程：pause 挂了，整个 Pod 的网络与进程空间随之销毁。

同节点两个 Pod 通信的路径（Calico 路由模式）：podA eth0 → veth → 宿主机路由表（目标是本机 podCIDR 内的 cali 接口）→ 直接内核转发到 podB 的 veth → podB eth0。全程不经过 docker0 那种网桥，也不出网卡。

## 4. podCIDR 怎么分给节点：实地观察

```
# [图] 地址分配的两条线
kubeadm init --pod-network-cidr=10.244.0.0/16
   → 写入 kubeadm-config（networking.podSubnet）
   → kube-controller-manager --cluster-cidr=10.244.0.0/16 --allocate-node-cidrs=true
        节点注册时，CIDR Allocator 从大网段切 /24 写进 node.spec.podCIDR
   → CNI 各自消费：
      flannel：直接按 node.spec.podCIDR 配路由
      calico：还有自己的 IP Pool CRD（通常与 podSubnet 一致），按 /26 block 细分
```

```bash
# [master] 看每个节点分到的 podCIDR
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
# 预期输出：
#   master    10.244.0.0/24
#   worker1   10.244.1.0/24
#   worker2   10.244.2.0/24

# [master] Calico 的 IP Pool（CRD，独立于 node.spec.podCIDR）
kubectl get ippools.crd.projectcalico.org -o wide
```

```bash
# [worker1] 节点路由表就是 podCIDR 的"落地账本"
ip route | grep -E '10\.244'
# 预期输出（BGP 模式）：
#   10.244.1.0/24 dev cali<hash> scope link        ← 本节点 Pod，直接走 veth
#   10.244.0.0/24 via 192.168.30.21 dev ens33 ...  ← 其他节点 Pod，下一跳是对方物理 IP
#   10.244.2.0/24 via 192.168.30.23 dev ens33 ...
# 预期输出（VXLAN 模式）：
#   10.244.2.0/24 via 10.244.2.0 dev vxlan.calico onlink
```

这份路由表由 CNI 的控制面维护（Calico 是每个节点上的 bird BGP 进程互相学路由），数据面只是内核照表转发。podSubnet 必须与物理网段不重叠，否则"下一跳"会与真实局域网冲突，产生路由黑洞。

## 5. 三种实现路线：overlay、路由、underlay

### 5.1 VXLAN overlay：把二层包装进 UDP

```
# [图] Node1→Node2 一次跨节点包的逐层封装（VXLAN）
Pod 发出： [ETH: podA→podC][IP: 10.244.1.5→10.244.2.7][TCP/Payload]
                │ 封装（vxlan.calico / flannel.1 接口完成）
                ▼
┌─ 外层 ETH: worker1_mac → worker2_mac ─────────────────────────────┐
│ 外层 IP : 192.168.30.22 → 192.168.30.23                           │
│ 外层 UDP: 端口 4789（VXLAN 固定端口）                              │
│ VXLAN 头: VNI=4096（标识虚拟网络）                                 │
│ ┌─ 内层（原封不动的 Pod 包）──────────────────────────────────┐   │
│ │ [ETH][IP: 10.244.1.5→10.244.2.7][TCP/Payload]              │   │
│ └─────────────────────────────────────────────────────────────┘   │
└────────────────────────────────────────────────────────────────────┘
开销 = 外层 IP(20) + UDP(8) + VXLAN(8) = 50 字节 → Pod MTU = 1500 - 50 = 1450
```

特点：物理网络零改造（只要能通 UDP），跨子网/云上都能跑；代价是每包 50 字节开销 + 两次封解包的 CPU，且要放行 UDP 4789。

### 5.2 BGP 路由（Calico 默认路线）

不做封装：每个节点用 BGP（bird）向同伴宣告"10.244.1.0/24 在我这"，所有节点路由表互相学到达路径，转发就是普通三层路由。零封装开销、可观测性好（`ip route` 即真相）；代价是要求节点间二层可达或 underlay 支持配 BGP，路由条目随节点数增长（规模化要 route reflector）。Calico 的 IPIP 模式是折中：IP 头套 IP 头（协议号 4），开销 20 字节，用于 underlay 不能直接路由的环境。

### 5.3 underlay / host-gw：直接用物理网络

flannel 的 host-gw 模式在每个节点加一条"对端 podCIDR 下一跳 = 对端物理 IP"的静态路由（本质是 5.2 的手动简化版）；或用 macvlan/ipvlan/SR-IOV 让 Pod 直接挂物理网卡、用数据中心 IP（underlay CNI，如 calico 的 host-local 直连模式、metallb 同类的 L2 方案）。性能最好，但 IP 管理、ARP/广播域、多网络能力都受制于物理网络。

### 5.4 flannel vs calico vs cilium

| 维度 | flannel | calico | cilium |
| --- | --- | --- | --- |
| 模型 | overlay（VXLAN）或 host-gw | 三层路由（BGP）+ 可选 IPIP/VXLAN | eBPF 替换 kube-proxy，路由或 overlay |
| 数据面 | 内核转发（bridge/ vxlan） | 内核路由 + iptables/eBPF | eBPF（绕开 iptables） |
| NetworkPolicy | 不支持 | 全量支持（L3/L4） | 全量支持 + L7（HTTP/DNS 级） |
| 加密 | 无 | WireGuard/IPSec | WireGuard/IPSec |
| MTU 开销 | VXLAN 50 字节 | BGP 0 字节 | 视模式 0~50 |
| 生态定位 | 小集群、只要连通 | 大多数场景的默认解 | 服务网格、可观测性、egress gateway |

选型口诀：只要"通"，flannel 够用但要放弃 NetworkPolicy（CKS 场景直接排除）；要策略与性能，calico；要 L7 策略/网格/eBPF 可观测，cilium。

## 6. NetworkPolicy：实现原理与"白名单翻转"

### 6.1 默认全通，有策略即白名单

NetworkPolicy 的语义是"带方向的选择器 + 放行列表"：

- 集群默认没有策略 = 所有流量全通（K8s 出厂没有 deny-all）
- 一旦某 Pod 被**任意一条**策略的 `podSelector` 选中且策略声明了某方向（`policyTypes` 含 Ingress/Egress），该 Pod 在该方向立即翻转为**默认全拒**，只放行策略明确允许的
- 多条策略对同一 Pod 是叠加关系（规则求并集）；没被任何策略选中的 Pod 行为不变

实现层面：策略由 CNI 落地（不是 kube-proxy，也不是 apiserver 强制）。Calico 把规则编译成 iptables 链 + ipset（或 eBPF），挂在与 veth/转发路径相关的钩子上逐包匹配；flannel 没有实现，写了也不生效（这是排障第一怀疑点）。

### 6.2 落地一套最小可用的隔离

```bash
# [master] 实验环境：独立 namespace + 一台 web + 一台 probe
kubectl create ns np-lab
kubectl -n np-lab run web --image=nginx:1.27 --expose --port=80
kubectl -n np-lab run probe --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl -n np-lab exec probe -- wget -qO- --timeout=3 http://web | head -3
# 预期输出：nginx 欢迎页 HTML，说明默认全通
```

```yaml
# [master] 保存为 np-deny-all.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: np-lab
spec:
  podSelector: {}          # 选中 namespace 内所有 Pod
  policyTypes:
  - Ingress
  - Egress
```

```bash
# [master] 应用后立刻全断（连 DNS 都不通）
kubectl apply -f np-deny-all.yaml
kubectl -n np-lab exec probe -- wget -qO- --timeout=3 http://web
# 预期输出：wget: download timed out
```

```yaml
# [master] 保存为 np-allow.yaml：两条规则一起补回"web 的入站"与"probe 的出站"
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: web-allow-probe
  namespace: np-lab
spec:
  podSelector:
    matchLabels:
      run: web             # kubectl run 自动打的标签
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          run: probe
    ports:
    - protocol: TCP
      port: 80
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: probe-allow-egress
  namespace: np-lab
spec:
  podSelector:
    matchLabels:
      run: probe
  policyTypes: ["Egress"]
  egress:
  - to:
    - podSelector:
        matchLabels:
          run: web
    ports:
    - protocol: TCP
      port: 80
  - to:
    - namespaceSelector:        # 放行 kube-dns（否则解析不了 http://web）
        matchLabels:
          kubernetes.io/metadata.name: kube-system
    ports:
    - protocol: UDP
      port: 53
    - protocol: TCP
      port: 53
```

```bash
# [master] 恢复通信
kubectl apply -f np-allow.yaml
kubectl -n np-lab exec probe -- wget -qO- --timeout=3 http://web | head -3
# 预期输出：nginx 欢迎页 HTML
```

语义细节（考试与实操双高频）：同一条规则里 `namespaceSelector` 与 `podSelector` 同时出现是**交集**（该 namespace 内且带该标签的 Pod）；分写两条规则才是并集。`kube-dns` 在 kube-system，所以几乎每套 egress 白名单都要带 53 端口放行——deny-all 之后"忽然连 Service 名都解析不了"就是这个原因。

```bash
# [worker1] 眼见为实：Calico 把策略编译成的 iptables 链
sudo iptables-save | grep -E 'cali-.*fw|cali-.*policy' | head
# [master] 清理
kubectl delete ns np-lab --wait=false
```

## 实战演练：把本章串成一条线

```bash
# [master] 步骤 1：Pod IP 从哪来（在 worker1 上执行 3 节命令的整合版）
kubectl run net-demo --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl get pod net-demo -o wide
```

```bash
# [worker1] 步骤 2：veth、netns、路由三连（见第 3、4 节命令）
SANDBOX=$(crictl pods --name net-demo -q)
PID=$(crictl inspectp "$SANDBOX" | grep -oP '"pid":\s*\K[0-9]+' | head -1)
nsenter -t "$PID" -n ip -o addr show eth0
nsenter -t "$PID" -n ip route
ip -o link | grep cali | head -3
ip route | grep -E '10\.244'
```

```bash
# [worker1] 步骤 3：MTU 与隧道接口（VXLAN 模式下）
ip -d link show vxlan.calico 2>/dev/null | head -2 || echo "非 VXLAN 模式（BGP/IPIP）"
# 预期输出（VXLAN）：... mtu 1450 ... vxlan id 4096 ...
# [master]（可选，双节点）跨节点抓包验证封装方式：
#   VXLAN：sudo tcpdump -ni ens33 'udp port 4789' -c 5
#   IPIP ：sudo tcpdump -ni ens33 'proto 4' -c 5
```

```bash
# [master] 步骤 4：把 MTU 问题复现出来（可选）
kubectl exec net-demo -- ping -c2 -W2 -s 1400 -M do <另一节点的 Pod IP>   # 1450 内应通
kubectl exec net-demo -- ping -c2 -W2 -s 1472 -M do <另一节点的 Pod IP>   # 超过 MTU 应 100% 丢包
kubectl delete pod net-demo
```

```bash
# [master] 步骤 5：NetworkPolicy 三段式（6.2 节全流程：全通→全断→白名单恢复）
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 装了 flannel，NetworkPolicy 不生效 | flannel 未实现 NetworkPolicy | 换 calico/cilium，或加装独立策略引擎 |
| deny-all 后所有域名解析失败 | egress 白名单没放行 kube-dns 53 | 补 UDP/TCP 53 到 kube-system 的规则 |
| Pod 互 ping 不通但节点互 ping 正常 | VXLAN UDP 4789 或 IPIP 协议 4 被防火墙拦 | underlay 放行对应端口/协议 |
| 小包通、大包/页面卡死 | MTU 未同步：overlay 50 字节开销 | CNI 配置与节点 MTU 一起调，用 `ping -M do -s` 定界 |
| Pod IP 网段与物理网段重叠 | podSubnet 规划失误，路由下一跳指向真实设备 | 重装 CNI 并换独立网段 |
| Calico 节点间不通（多网卡 VM） | IP_AUTODETECTION_METHOD 选错网卡 | 环境变量指定网卡（如 `interface=ens192`） |
| `namespaceSelector` + `podSelector` 结果比预期少 | 同一规则内是交集不是并集 | 拆成两条规则 |

## 自测

1. Pod 里 `localhost` 为什么能通到同 Pod 的另一个容器？跨容器"端口冲突"吗？

<details><summary>答案</summary>

同 Pod 所有容器共享 pause 持有的同一个 network namespace，等价于同一台机器上的多个进程，localhost 就是本 netns 回环，所以互通且端口在同一命名空间内天然冲突（一个占了 8080 另一个再监听 8080 会失败）。不同 Pod 各有独立 netns，互不冲突。
</details>

2. 同节点 podA→podB 与跨节点 podA→podC 的转发路径分别是什么（Calico 路由模式）？

<details><summary>答案</summary>

同节点：podA eth0 → veth → 宿主机内核查路由，目标是本机 podCIDR 内的 cali 接口 → 直接送到 podB 的 veth → podB eth0，不出物理网卡。跨节点：宿主机路由表把 10.244.x.0/24 指向对端节点的物理 IP（BGP 学来），包从物理网卡发出，对端节点按本机路由送到对应 cali 接口。VXLAN 模式则在发出前多一步 UDP 4789 封装、对端解封装。
</details>

3. 为什么 podSubnet 与物理网段重叠会出"路由黑洞"？举例说明受害流量。

<details><summary>答案</summary>

节点路由表里 `10.244.1.0/24 via <对端物理IP>` 的下一跳解析依赖物理网段正常；若 Pod CIDR 与局域网真实网段重叠（如都是 192.168.30.0/24），去往某 Pod IP 的包会被物理网络的三层设备按真实网段转发到无关机器，或本机路由与物理路由互相覆盖，产生间歇性不可达。受害的不只是 Pod 流量，与重叠地址同段的物理主机访问也会被 Pod 路由劫持。
</details>

4. 一条策略也没写的集群为什么"看起来什么都没发生"？写出让默认 deny-all 生效的最小 YAML（三行核心）。

<details><summary>答案</summary>

NetworkPolicy 是白名单模型：没有策略选中某 Pod 时，该 Pod 不受任何隔离，即默认全通。最小 deny-all：`spec: { podSelector: {}, policyTypes: [Ingress] }`（Egress 同理追加）。`podSelector: {}` 表示选中 namespace 内全部 Pod。
</details>

5. NAT-free 三要求对应用有什么实际影响？举两个具体场景。

<details><summary>答案</summary>

（示例）一是服务端拿到的 source IP 是真实 Pod IP，可以做 IP 级审计与限流；从集群外进来的流量则因 SNAT 丢失源 IP，要靠 `externalTrafficPolicy: Local` 或 proxy protocol 找回。二是 Pod 主动访问外部时一般经 masquerade 出节点（ip-masq-agent 可控），对端看到的是节点 IP，回包能被正确路由回来——"Pod 间 NAT-free、出集群才 NAT"是两回事。
</details>

## 延伸阅读

- 集群网络模型：https://kubernetes.io/docs/concepts/cluster-administration/networking/
- NetworkPolicy 概念与示例：https://kubernetes.io/docs/concepts/services-networking/network-policies/
- CNI 规范与插件：https://github.com/containernetworking/cni
- Calico 架构（BGP/VXLAN/IPPool）：https://docs.tigera.io/calico/latest/reference/architecture/overview
- Cilium eBPF 数据面：https://docs.cilium.io/en/stable/overview/architecture/
- flannel：https://github.com/flannel-io/flannel
