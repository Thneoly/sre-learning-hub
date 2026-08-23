# 05 · Service 与 DNS：虚拟 IP、iptables 规则链与 CoreDNS

> 模块：04-k8s-fundamentals ｜ 建议时长：4 小时 ｜ 关联认证：CKA-服务与网络 / CKA-集群架构 / —（DNS 部分对 CKS 排障也有用）

## 学习目标

- 能解释 Pod IP 为什么不能当服务地址用（重建、滚动、漂移三个来源），以及 Service 用"虚拟 IP + label selector + 四层负载均衡"分别解决其中哪两个问题
- 能画出 iptables 模式下 ClusterIP 的完整规则链（KUBE-SERVICES → KUBE-SVC → KUBE-SEP → DNAT），并解释为什么是"随机选一"而不是轮询
- 能操作 `iptables-save`、`ipvsadm`、`conntrack`、`dig` 定位"Service 不通"与"DNS 解析异常"两类故障
- 能用五步法排查 selector 失配导致的 Endpoints 为空
- 能解释四种 Service 类型、headless 的 DNS 行为差异，以及 `ndots:5` 给外部域名解析带来的代价

## 1. 为什么需要 Service：Pod IP 是易失的

Pod IP 会在三种常见情况下变化，每一种都足以让"把 Pod IP 写进配置文件"这类方案崩溃：

| 场景 | IP 变化范围 | 触发者 |
|---|---|---|
| 容器崩溃 / Pod 重建 | 单个 Pod 换 IP | kubelet（restartPolicy） |
| 滚动更新 | 全部副本逐个换 IP | Deployment controller |
| 节点故障 / 重新调度 | Pod 换 IP，甚至换节点 | scheduler / 集群自愈 |

Service 在不引入任何代理进程的前提下解决了两件事：

1. **稳定寻址**：一个不会变的虚拟 IP（ClusterIP）+ 一个不会变的 DNS 名字（`web.netlab.svc.cluster.local`）。
2. **后端聚合与分发**：用 label selector 动态圈定"哪些 Pod 是我的后端"，流量在四层分发给它们——注意它**不是**七层代理，本质是 netfilter 规则做的 DNAT（见第 2 节）。

```bash
# [master] 最小实验环境：3 副本 nginx + ClusterIP Service
kubectl create ns netlab
kubectl -n netlab create deployment web --image=nginx:alpine --replicas=3
kubectl -n netlab wait --for=condition=Available deployment/web --timeout=120s
kubectl -n netlab expose deployment web --port=80 --target-port=80 --name=web

kubectl -n netlab get svc,pod -o wide
# NAME   TYPE        CLUSTER-IP      PORT(S)   ...
# web    ClusterIP   10.96.57.208    80/TCP    ...
# 三个 Pod 各有 10.244.x.x 的 IP（Calico 分配，以实际输出为准）

# [master] 本实验集群的 service CIDR（Pod 里能用 ClusterIP 的前提）
kubectl -n kube-system get cm kubeadm-config -o yaml | grep -E 'serviceSubnet|podSubnet'
```

## 2. ClusterIP 的本质：一条 iptables 规则簇，不是一张网卡

ClusterIP **不属于任何接口**。`ip addr` 在所有节点上都找不到 10.96.57.208 这个地址；它只存在于每个节点 kube-proxy 写下的 netfilter 规则里。查 DNS 得到 ClusterIP → 发包 → 包在 PREROUTING/OUTPUT 被规则改写成某个 Pod IP → 到达 Pod。全程没有用户态进程参与转发（kube-proxy 只写规则，不在数据路径上）。

```
        以 Service web（ClusterIP=10.96.57.208:80，3 个 endpoint）为例

Pod 内进程 curl http://web/ ──► DNS 解析得 10.96.57.208 ──► 发 SYN 到 10.96.57.208:80
        │
        ▼  包进入节点网络栈（本实验单 master，即 master 本机）
┌────────────────────────────────────────────────────────────────────┐
│ nat 表 PREROUTING（其它节点/外部进来的包）                            │
│ nat 表 OUTPUT    （本机进程发出的包，两条路都汇入下面）               │
│     └─► -j KUBE-SERVICES            ← 所有 Service 流量总入口       │
├────────────────────────────────────────────────────────────────────┤
│ KUBE-SERVICES（每 Service 一条匹配规则）                             │
│     -d 10.96.57.208/32 -p tcp --dport 80 -j KUBE-SVC-N57TFCL4K7MYVTP │
├────────────────────────────────────────────────────────────────────┤
│ KUBE-SVC-N57TFCL4K7MYVTP（每 Service 一条链，后缀是名的哈希，示意）    │
│     -m statistic --mode random --probability 0.3333 -j KUBE-SEP-A   │
│     -m statistic --mode random --probability 0.5000 -j KUBE-SEP-B   │
│     -j KUBE-SEP-C                    ← 前两条都未命中时必然走 C      │
├────────────────────────────────────────────────────────────────────┤
│ KUBE-SEP-YYYYYYYY（每 endpoint 一条链，充当"转发表"）                │
│     -j DNAT --to-destination 10.244.2.11:80  ← 改写成 Pod IP:port   │
│     （部分场景同时 -j KUBE-MARK-MASQ，给回程伪装打标记，见下）        │
├────────────────────────────────────────────────────────────────────┤
│ conntrack 记录该连接的 DNAT 映射                                     │
│     同一连接后续包不再经过 KUBE-SVC 的随机选择，直接按表改写           │
│     = "连接级粘滞"：一条 TCP 连接永远落在同一个 Pod 上                │
└────────────────────────────────────────────────────────────────────┘
        │
        ▼ 路由决策：目标 10.244.x.x → Calico 的 veth/路由 → 目标 Pod
          源地址保持客户端 IP 不变（1:1 DNAT，不是 proxy）
```

三个值得展开的细节：

- **概率级联**：0.3333、0.5000、1.0 三条规则的条件概率算下来是 1/3、1/2×2/3=1/3、1/3，数学期望均等。endpoint 数量变化时 kube-proxy 整体重写这组概率。
- **为什么不轮询**：见下节专门解释。
- **KUBE-MARK-MASQ 的存在**：DNAT 之后如果"源 Pod = 目标 Pod"（Pod 通过 Service 访问自己，hairpin），回程会被当成直连而错乱；所以这类流量打标记后经 KUBE-POSTROUTING 做 MASQUERADE，把源改成节点 IP。这也是"Pod 通过 Service 访问自己时，对方看到的源 IP 是节点 IP"的原因。

```bash
# [master] 逐级把这条链亲手读一遍
SVCIP=$(kubectl -n netlab get svc web -o jsonpath='{.spec.clusterIP}')
echo "ClusterIP=$SVCIP"

# 第 1 级：谁指向这个 IP —— 拿到 KUBE-SVC- 开头的链名（后缀形如 N57TFCL4K7MYVTP）
iptables-save -t nat | grep -- "-d $SVCIP/32" | head -2
# -A KUBE-SERVICES -d 10.96.57.208/32 -p tcp -m comment ... --dport 80 -j KUBE-SVC-N57TFCL4K7MYVTP

# 第 2 级：负载均衡链（-v 看随机规则的命中计数）
SVCCHAIN=$(iptables-save -t nat | grep -- "-d $SVCIP/32" | grep -oE 'KUBE-SVC-[A-Z0-9]+' | head -1)
iptables -t nat -L "$SVCCHAIN" -n -v

# 第 3 级：随便挑一个 endpoint 链看 DNAT 目标
SEP=$(iptables -t nat -S "$SVCCHAIN" | grep -oE 'KUBE-SEP-[A-Z0-9]+' | head -1)
iptables -t nat -S "$SEP"
# -A KUBE-SEP-... -p tcp -m comment ... -j DNAT --to-destination 10.244.2.11:80

# 第 4 级：访问 10 次再回来计数，random 规则的 pkts 在涨、三条大致均分
for i in $(seq 1 10); do curl -s -o /dev/null -m 3 "http://$SVCIP"; done
iptables -t nat -L "$SVCCHAIN" -n -v

# 第 5 级：conntrack 里能看到改写后的双向五元组
conntrack -L -p tcp --dport 80 2>/dev/null | grep "$SVCIP" | head -3
```

> 若上面任何一步 grep 不到规则：先确认 kube-proxy 实际模式——较新的 Kubernetes 版本允许（部分发行版默认）nftables 模式，此时规则在 nft 里：`nft list ruleset | grep -m5 KUBE-SVC`，链路语义与 iptables 完全对应，只是观测命令不同。以你集群 `kubectl -n kube-system get cm kube-proxy -o yaml | grep -A3 mode` 的输出为准。

```bash
# [master] 验证请求确实散到了 3 个 Pod（每 Pod 一份访问日志）
for i in $(seq 1 9); do curl -s -o /dev/null -m 3 "http://$SVCIP"; done
kubectl -n netlab logs -l app=web --prefix=true --tail=3
# 三个不同 Pod 名的日志都出现 GET，即"连接级随机分发"的直接证据
```

### 2.1 为什么是随机选一，而不是轮询

1. **iptables 是无状态匹配器**。`statistic` 模块虽有 `nth`（轮询）模式，但计数器是每节点独立的，而且 Endpoints 一变 kube-proxy 就整链重写，计数清零，分布立刻失真；跨节点也没有共享状态可用。
2. **负载均衡粒度是"连接"不是"请求"**。DNAT 只发生在 conntrack 建立新连接的时刻，后续报文直接命中连接表反向改写，根本不再经过 KUBE-SVC。所以即便换成轮询，"轮"的也是新连接，HTTP keep-alive 一条连接上的成百上千个请求仍然全部落在同一 Pod。
3. 无状态的随机规则在数学期望上均等、在任何一台节点上独立可复现，是纯规则集能做到的最优解。**真正的 rr/wrr/lc/sh 调度器由 IPVS 提供**（第 3 节），这也正是大规模集群切 ipvs 的动机之一。

## 3. kube-proxy：iptables 模式 vs ipvs 模式

kube-proxy 是每个节点上的规则编写器（控制面组件，不在数据路径上），有四种模式：`userspace`（最古老的用户态 proxy，已废弃并在新版本移除）、`iptables`（默认）、`ipvs`、`nftables`（新版本引入，以官方文档为准）。重点对比前两种可长期使用的：

| 维度 | iptables 模式 | ipvs 模式 |
|---|---|---|
| 规则组织 | 线性链，逐条匹配，O(规则数) | 内核哈希表，O(1) 查找 |
| 规则更新 | 全量替换，Service 多时同步耗时、锁竞争 | 增量同步（配合 ipset） |
| 调度算法 | 仅 random | rr / wrr / lc / sh / sed / nq 任选 |
| 会话保持 | ClientIP 靠 recent 模块 | IPVS 内建 persistent session |
| 观测手段 | `iptables-save -t nat` 看计数 | `ipvsadm -Ln --stats` 每真实服务器计数 |
| 额外依赖 | 无（默认就有） | `ip_vs` 系列内核模块、ipset、ipvsadm |
| VIP 归属 | 不存在于任何接口（ping 通常不通） | 绑在 `kube-ipvs0` dummy 接口上 |

经验值：Service 数上千、或需要真实 LB 调度算法时选 ipvs；小集群 iptables 完全够用。

```bash
# [master] 切换实验：iptables → ipvs（多节点集群需在每个节点执行 modprobe）
modprobe ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack
cat >/etc/modules-load.d/ipvs.conf <<'EOF'
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

kubectl -n kube-system edit cm kube-proxy      # 把 config.conf 里 mode: "" 改为 mode: "ipvs"
kubectl -n kube-system rollout restart ds kube-proxy
kubectl -n kube-system rollout status ds kube-proxy
kubectl -n kube-system logs ds/kube-proxy | grep -im2 'ipvs'

apt-get install -y ipvsadm     # 观测工具
ipvsadm -Ln | head -20         # 能看到 10.96.0.1:443 等 Virtual Server 与真实服务器列表
ipvsadm -Ln --stats | grep -A3 "$SVCIP" | head -5   # 每个 Pod 的连接/包计数

# 改回 iptables：把 mode 改回 "" 后再次 rollout restart 即可
```

## 4. 四种 Service 类型与 headless

| 类型 | 关键字段 | 可达范围 | 地址来源 | 典型用途 |
|---|---|---|---|---|
| ClusterIP（默认） | `type: ClusterIP` | 集群内 | service CIDR 中的虚拟 IP | 内部互访 |
| NodePort | `type: NodePort` | 集群内 + 所有节点 | ClusterIP + 每节点 30000-32767 端口 | 无 LB 的裸金属暴露 |
| LoadBalancer | `type: LoadBalancer` | 外部 | 云厂商分配的外部 IP（含一个 NodePort） | 云上标准入口；裸金属需 MetalLB |
| ExternalName | `type: ExternalName` | 仅 DNS 层 | `externalName` 的 CNAME | 服务别名/迁移过渡 |
| headless（ClusterIP 特例） | `clusterIP: None` | 仅 DNS 层 | 直接返回后端 Pod IP | StatefulSet、客户端自建负载均衡 |

```bash
# [master] NodePort：规则链多一跳 KUBE-NODEPORTS
kubectl -n netlab expose deployment web --type=NodePort --port=80 --name=web-np
NP=$(kubectl -n netlab get svc web-np -o jsonpath='{.spec.ports[0].nodePort}')
NODEIP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -s -o /dev/null -w 'nodeport HTTP %{http_code}\n' "http://$NODEIP:$NP"
iptables-save -t nat | grep -E 'KUBE-NODEPORTS|dport '"$NP" | head -5
# 路径：PREROUTING → KUBE-SERVICES(尾部) → KUBE-NODEPORTS → KUBE-SVC-... → DNAT
```

```yaml
# [master] kubectl apply -f - <<'EOF' —— ExternalName 与 headless
apiVersion: v1
kind: Service
metadata:
  name: external-db
  namespace: netlab
spec:
  type: ExternalName
  externalName: db.prod.example.com
---
apiVersion: v1
kind: Service
metadata:
  name: ngs
  namespace: netlab
spec:
  clusterIP: None          # headless：不要虚拟 IP
  selector:
    app: ngs
  ports:
  - name: http
    port: 80
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: ngs
  namespace: netlab
spec:
  serviceName: ngs
  replicas: 2
  selector:
    matchLabels:
      app: ngs
  template:
    metadata:
      labels:
        app: ngs
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
        ports:
        - containerPort: 80
          name: http
EOF
```

ExternalName 与 headless 的共同点是"不提供虚拟 IP、只动 DNS"，但方向相反：ExternalName 把集群内的名字**指向外部域名**（返回 CNAME，不产生任何转发规则）；headless 把集群内的名字**直接解析到 Pod IP 列表**，把"选后端"这件事交还给客户端。StatefulSet 依赖 headless 获得 `ngs-0.ngs.netlab.svc.cluster.local` 这种每个 Pod 稳定的域名。

## 5. Endpoints / EndpointSlice 与"五步排错法"

Service 的 selector 并不直接驱动 kube-proxy。中间有一层由 kube-controller-manager 维护的对象：

```
Service(selector) ──watch──► endpoints controller ──► Endpoints(旧, core/v1)
                                    │                    与 EndpointSlice(discovery.k8s.io/v1)
                                    │                    每个 slice 默认最多 100 个 endpoint
                                    ▼
                          kube-proxy watch Endpoints/EndpointSlice
                                    ▼
                          改写本节点的 iptables/ipvs 规则（KUBE-SEP 增删）
```

```bash
# [master] 两个对象对照着看
kubectl -n netlab describe svc web | grep -A3 'Endpoints\|Selector'
kubectl -n netlab get endpointslices -l kubernetes.io/service-name=web -o wide
# ADDRESS-TYPE 列为 IPv4；endpoints 计数应等于 Ready 的 Pod 数
```

**selector 失配五步法**（Endpoints 为 `<none>` 时的标准动作序）：

```bash
# [master] 第 0 步：制造故障现场——selector 写错一个字母
kubectl -n netlab patch svc web -p '{"spec":{"selector":{"app":"webb"}}}'
kubectl -n netlab get svc web -o yaml | grep -A2 selector
curl -s -m 3 -o /dev/null -w '%{http_code}\n' "http://$SVCIP"   # 000：超时/拒绝
```

1. **看 Service**：`kubectl -n netlab describe svc web`。`Endpoints: <none>` 说明转发面根本没有后端——问题在"选不到 Pod"，与 DNS、kube-proxy、网络策略都无关，直接跳到第 2 步。
2. **用 selector 找 Pod**：`kubectl -n netlab get pods -l app=webb`。结果为空 ⇒ selector 与集群现状不匹配。注意 selector **只在同 namespace 内匹配**，跨 namespace 永远选不到。
3. **比对 label 全集**：`kubectl -n netlab get pods --show-labels` 与 selector 逐键比对。常见笔误：`app=webb`、`tier=front-end` vs `tier=frontend`、大小写、`_` 与 `-` 混用。
4. **检查 Ready 状态**：Endpoints 只收录 Ready 的 Pod。`kubectl -n netlab get pods` 里 `0/1 Running`（readinessProbe 失败）的 Pod 会被摘除——这是"Pod 活着但不接流量"的第一大原因。
5. **检查端口语义**：`targetPort` 缺省等于 `port`；若写的是**名字**（如 `http`），必须与 Pod 的 `containerPort.name` 完全一致，否则该 Pod 不会被收录进 Endpoints。对照 `kubectl get endpointslices` 的 ports 与 `kubectl get pod -o yaml` 的 containerPort。

```bash
# [master] 修复并复核（第 3 步定位到笔误后）
kubectl -n netlab patch svc web -p '{"spec":{"selector":{"app":"web"}}}'
sleep 3
kubectl -n netlab get endpointslices -l kubernetes.io/service-name=web -o jsonpath='{.items[0].endpoints[*].addresses}'
curl -s -o /dev/null -w 'after fix HTTP %{http_code}\n' "http://$SVCIP"   # 200
```

## 6. CoreDNS：svc.cluster.local 下的两种 A 记录

kubeadm 部署的集群里 CoreDNS 以 Deployment 跑在 kube-system，Service IP 通常是 service CIDR 的第 10 个地址（如 10.96.0.10）。Pod 默认 `dnsPolicy: ClusterFirst`，resolv.conf 指向它。

```bash
# [master] 看一眼 CoreDNS 配置：kubernetes 插件负责 cluster.local 区
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
```

同名 FQDN `web.netlab.svc.cluster.local.` 在两种 Service 下返回**两种 A 记录**：

| Service 形态 | A 记录返回 | 含义 |
|---|---|---|
| 普通 ClusterIP Service | 一条记录 = ClusterIP | 依赖 kube-proxy 的规则链做分发 |
| headless（clusterIP: None） | 多条记录 = 全部 Ready Pod 的 IP | 没有转发面，客户端自己挑 |

```bash
# [master] 进入调试 Pod（退出自动删除），以下命令在 Pod 内执行
kubectl run netlab-dig --image=nicolaka/netshoot --rm -it --restart=Never -- bash
```

```bash
# [netlab-dig Pod 内]
cat /etc/resolv.conf
# nameserver 10.96.0.10
# search netlab.svc.cluster.local svc.cluster.local cluster.local
# options ndots:5

dig +short web.netlab.svc.cluster.local        # 普通 Service → 一条 ClusterIP
dig +short ngs.netlab.svc.cluster.local        # headless → 两条 Pod IP
dig +short ngs-0.ngs.netlab.svc.cluster.local  # StatefulSet 单个 Pod 的稳定域名
dig +short _http._tcp.ngs.netlab.svc.cluster.local   # SRV 记录:端口+目标名
dig +short 10-244-2-13.netlab.pod.cluster.local      # Pod 直查(默认 Corefile pods insecure)
dig +short external-db.netlab.svc.cluster.local      # ExternalName → CNAME 链
```

### 6.1 ndots:5 陷阱

`options ndots:5` 的规则：**名字中的点数少于 5 时，先用 search 列表逐个拼后缀查询，全部失败后才查名字本身**。后果是访问外部域名 `www.example.com`（2 个点）要发 4 个查询：

```
www.example.com.netlab.svc.cluster.local.   → NXDOMAIN
www.example.com.svc.cluster.local.          → NXDOMAIN
www.example.com.cluster.local.              → NXDOMAIN
www.example.com.                            → 真正的结果
```

每次外部解析多 3 次往返；CoreDNS 故障或跨数据中心上游慢时，这 3 次失败查询会把外部访问延迟放大数倍，且高 QPS 下全是无效负载。

```bash
# [netlab-dig Pod 内] nslookup 会把每次失败的 search 尝试都打出来
nslookup www.example.com
# Server:  10.96.0.10
# ** server can't find www.example.com.netlab.svc.cluster.local: NXDOMAIN
# ** server can't find www.example.com.svc.cluster.local: NXDOMAIN
# ** server can't find www.example.com.cluster.local: NXDOMAIN
# Address: 93.184.216.34   ← 第 4 次才成功

time dig +short www.example.com.   # 结尾加点 = 绝对域名,跳过 search,一次命中
```

工程上的四种缓解：外部域名一律写成 FQDN（结尾加 `.`）；用 `dnsConfig.options` 调低 ndots；外部流量占比高的 Pod 用 `dnsPolicy: None` 自定义上游；节点部署 NodeLocal DNSCache 减少 53 端口竞争与 iptables DNAT 开销。内部服务用短名（`web`、`web.netlab`）反而受益于 search 机制，这是它存在的意义。

## 实战演练

```bash
# [master] 汇总实验：10 分钟过一遍本章所有可验证结论
kubectl create ns netlab
kubectl -n netlab create deployment web --image=nginx:alpine --replicas=3
kubectl -n netlab expose deployment web --port=80 --name=web
kubectl -n netlab wait --for=condition=Available deployment/web --timeout=120s

SVCIP=$(kubectl -n netlab get svc web -o jsonpath='{.spec.clusterIP}')

# 1) ClusterIP 可达且分发到多 Pod
curl -s -o /dev/null -w 'svc %{http_code}\n' "http://$SVCIP"

# 2) iptables 规则链完整可见（第 2 节的五级命令）
iptables-save -t nat | grep -- "-d $SVCIP/32" | head -1

# 3) headless 与普通 Service 的 DNS 差异（先应用第 4 节的 ngs YAML）
kubectl run dns1 --image=nicolaka/netshoot --rm -it --restart=Never -- \
  sh -c 'dig +short web.netlab.svc.cluster.local; dig +short ngs.netlab.svc.cluster.local'

# 4) Endpoints 空洞五步法（第 5 节的 patch/修复循环）

# 5) 清理
kubectl delete ns netlab --wait=false
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `ping ClusterIP` 不通但 `curl` 通 | iptables 模式只对 Service 端口的 TCP/UDP 写了规则，ICMP 没人接 | 属预期行为；改用 `curl`/`nc` 验证（ipvs 模式下 ping 通常通，因为 VIP 在 kube-ipvs0 上） |
| Service DNS 名解析失败 | 目标与客户端不在同一 namespace；或 CoreDNS 挂了 | 用全 FQDN `web.netlab.svc.cluster.local` 再试；`kubectl -n kube-system get pods -l k8s-app=kube-dns` |
| `Endpoints: <none>`，curl 超时 | selector 失配 / Pod 不 Ready / targetPort 名不匹配 | 按第 5 节五步法走 |
| 客户端日志里源 IP 变成节点 IP | hairpin 场景 KUBE-MARK-MASQ 伪装，或 NodePort 跨节点转发 SNAT | 要保源 IP 用 `externalTrafficPolicy: Local`（注意节点上没 Pod 时流量会被丢） |
| LoadBalancer Service 一直 `<pending>` | 裸金属没有云 LB 控制器 | 装 MetalLB，或临时用 NodePort |
| 切 ipvs 后 Service 全断 | 节点未加载 `ip_vs` 模块 | 每节点 `modprobe ip_vs ip_vs_rr ...` 并持久化，再重启 kube-proxy |
| Pod 通过 Service 访问自己间歇性失败 | hairpin 路径依赖 masquerade，部分 CNI 默认关闭 | 让客户端直连 Pod IP/headless，或给节点开 hairpin（Calico 一般无碍，逐 case 排查） |
| 外部域名解析偶发秒级延迟 | ndots:5 的 search 展开叠加 CoreDNS/上游抖动 | 见 6.1 的四种缓解 |
| `kubectl get svc` 有 IP，但 `dig` 无记录 | 名字空间后缀写错（漏 .svc）或 CoreDNS 的 cluster.local 区配置被改 | `dig web.netlab.svc.cluster.local +search` 对照 |

## 自测

<details><summary>1. 为什么 iptables 模式做不到严格的请求级轮询？两层原因分别是什么？</summary>

规则层：iptables 是无状态匹配器，`statistic --mode nth` 的轮询计数每节点独立，且 Endpoints 每次变更都触发整链重写、计数清零，跨节点也没有共享状态。语义层：负载均衡粒度是"连接"——DNAT 只在 conntrack 新建连接时发生，后续报文直接按连接表改写，一条 keep-alive 连接上的所有请求都会落在同一 Pod。所以 kube-proxy 选择了无需状态的 random 模式（条件概率级联保证期望均等），真正的 rr/wrr 由 IPVS 调度器实现。
</details>

<details><summary>2. Service 有 3 个 endpoint 时，iptables 规则为什么写成 0.3333 和 0.5000 两条概率，而不是三条 0.3333？</summary>

iptables 的 statistic 规则是**顺序执行**的：第二条只有在第一条未命中时才被求值。若三条都写 0.3333，实际分布是 1/3、2/3×1/3、剩余 1/3（未命中前两条的概率是 4/9，最后一条是兜底必达），总计 1/3、2/9、4/9，严重倾斜。写成条件概率 1/3、1/2、兜底，分布才是 1/3、1/3、1/3。这是概率级联，不是三次独立抽样。
</details>

<details><summary>3. headless Service 的客户端把解析结果缓存了 30 秒（TTL），滚动更新会发生什么？如何缓解？</summary>

headless 的 A 记录直接指向 Pod IP，滚动更新时旧 Pod 被删、IP 失效，但客户端缓存里的记录在 TTL 内仍然有效，请求会打到已不存在的 IP 上，表现为滚动窗口内随机失败。缓解：客户端尊重 TTL 且不额外缓存；发布时先缩容后端/做连接排空；或干脆不用 headless 而用普通 Service（虚拟 IP 不变，由 Endpoints 摘除保证）。StatefulSet 场景下按 Pod 域名访问（`ngs-0.ngs...`）也能避开整批 IP 更替。
</details>

<details><summary>4. ExternalName Service 和"无 selector + 手工维护 Endpoints"的 Service 都能指向外部，数据面差在哪？</summary>

ExternalName 只是一条 CNAME：CoreDNS 把 `external-db.netlab.svc.cluster.local` 解析成 `db.prod.example.com` 再由上游解析出最终 IP，集群内**不产生任何 iptables 规则**，流量从 Pod 直接到外部地址（源 IP 不经伪装，受网络策略约束）。手工 Endpoints 则把外部 IP 塞进 EndpointSlice，kube-proxy 照常为它建 KUBE-SVC/KUBE-SEP 链，流量先到 ClusterIP 再 DNAT 到外部 IP——好处是外部后端获得了稳定的集群内地址 + 四层分发 + 可挂 NetworkPolicy，代价是多一跳 DNAT。前者适合"起个别名"，后者适合"把外部 IP 当集群后端管理"。
</details>

<details><summary>5. Pod resolv.conf 里 search 有 3 个后缀、ndots:5。访问 `a.b.example.com`（3 个点）和 `www.example.com.`（结尾带点）各发几次 DNS 查询？</summary>

`a.b.example.com` 有 3 个点 < 5，仍走 search 展开：3 次 NXDOMAIN + 1 次真实查询 = 4 次。`www.example.com.` 以点结尾是绝对域名，且点数（3，含结尾）≥5 的判断对绝对名无意义——resolver 对 FQDN 直接一次查询 = 1 次。结论：写外部域名时**结尾加一个点**是零成本的最优实践；这也是为什么很多基准测试里"加个点"能显著降低外部请求延迟。
</details>

<details><summary>6. 为什么上千个 Service 的集群推荐 ipvs？除了查找复杂度，再给两个理由。</summary>

（1）规则同步方式：iptables 模式每次 Endpoints 变化都要全量替换 nat 表规则，Service 多时同步耗时有锁竞争，规则变更期间可能出现短暂的不一致/抖动；ipvs 用哈希表 + ipset 做增量更新。（2）调度能力：ipvs 有真实的内核级调度器（rr/wrr/lc/sh/sed/nq）和内建 persistent session，iptables 只有 random + recent 模块的近似。（3）观测：`ipvsadm -Ln --stats` 直接给出每台真实服务器的连接与流量计数，排障粒度远好于读 iptables 计数器。
</details>

## 延伸阅读

- Service 官方概念（含虚拟 IP 机制说明）：https://kubernetes.io/docs/concepts/services-networking/service/
- 虚拟 IP 与代理实现细节：https://kubernetes.io/docs/reference/networking/virtual-ips/
- Service 排障官方指南（与本节五步法互补）：https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/
- Pod 与 Service 的 DNS：https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/
- CoreDNS kubernetes 插件：https://coredns.io/plugins/kubernetes/
- IPVS 管理（含调度算法）：http://www.linuxvirtualserver.org/Documents.html
- EndpointSlice：https://kubernetes.io/docs/concepts/services-networking/endpoint-slices/
