# 03 · 容器网络：docker0、veth、iptables 端口映射与四种网络模式

> 模块：03-docker ｜ 建议时长：4 小时 ｜ 关联认证：CKA-网络 / CKS-网络策略（CNI 的全部前置）

## 学习目标

- 能画出 bridge 模式下容器收发包的完整路径（含 veth、docker0、iptables 各链的先后顺序）
- 能操作 `nsenter`/`ip`/`iptables`/`tcpdump`/`conntrack` 定位"端口不通"问题
- 能解释 `-p 8080:80` 背后的 DNAT/MASQUERADE 规则并手工阅读 DOCKER 链
- 能解释四种网络模式（bridge/host/none/container）各自的 namespace 布局与适用场景
- 能解释内嵌 DNS（127.0.0.11）何时生效、为何默认 bridge 不解析容器名

## 1. 三样东西：bridge + veth + iptables

Docker 单机网络（bridge 模式）只用了三个内核设施，全部在第 1 章的 NET namespace 之上搭建：

```
              宿主机网络栈（host netns）
 ┌────────────────────────────────────────────────────┐
 │  eth0 (192.168.1.50)                                │
 │    │                                                │
 │    └── docker0 (Linux bridge, 172.17.0.1/16)        │
 │          │        │                                 │
 │        vethXX   vethYY        ← veth pair 宿主机侧   │
 └──────────┼────────┼─────────────────────────────────┘
            │        │   （veth 跨 namespace，两端同生共死）
 ┌──────────┼────────┼──────────┐
 │        eth0     eth0         │  ← 容器侧（改名自 veth 另一端）
 │      172.17.0.2 172.17.0.3   │
 │   容器A(netns)    容器B(netns) │
 └──────────────────────────────┘
```

- **docker0**：一个二层网桥（`ip link add docker0 type bridge`），自带 IP 172.17.0.1/16，是所有 bridge 容器的默认网关。
- **veth pair**：成对的虚拟网卡，从一端进必然从另一端出，是**把网卡"伸进"另一个 netns 的标准手法**。Docker 每起一个容器就建一对：一端 `ip link set vethXX master docker0` 挂到网桥，另一端塞进容器 netns 改名 eth0。
- **iptables**：容器的南北向流量（出公网、被端口映射进来）全靠 nat 表改地址、filter 表做策略。二层的东西（同网桥容器互访）不走 iptables——除非加载了 `br_netfilter`（见第 6 节的坑）。

```bash
# [任意节点] 起实验容器并验证上面的图
docker run -d --name net-a --ip 172.17.0.2 nginx:alpine 2>/dev/null || docker run -d --name net-a nginx:alpine
docker run -d --name net-b alpine sleep 3000

ip -d link show docker0        # 类型 bridge
ip link | grep -A1 veth        # 看到 veth8f3a21c@if12 之类：veth 宿主机侧
docker exec net-a ip addr show eth0   # 容器侧地址（另一端）
docker exec net-a ip route             # default via 172.17.0.1 dev eth0
bridge link                       # 谁挂在了 docker0 上
```

```bash
# [任意节点] 找出"哪根 veth 属于哪个容器"——按 ifindex 对应关系
CPID=$(docker inspect -f '{{.State.Pid}}' net-a)
CINDEX=$(nsenter -t $CPID -n cat /sys/class/net/eth0/ifindex)
HINDEX=$((CINDEX + 1))   # veth 两端 ifindex 相邻（约定俗成，非规范；最稳的是按 peer 计）
for v in /sys/class/net/veth*; do
  p=$(cat $v/ifindex); peer=$(ethtool -S $(basename $v) 2>/dev/null | awk '/peer_ifindex/{print $2}')
  echo "$(basename $v) ifindex=$p peer_ifindex=$peer"
done
# peer_ifindex 等于容器内 eth0 的 ifindex 的那根，就是 net-a 的 veth
```

## 2. 容器出公网：MASQUERADE 与转发链

容器源 IP 是 172.17.0.x，私网地址出宿主机必须 SNAT。Docker 在 nat 表 POSTROUTING 链放了一条：

```
-A POSTROUTING -s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
```

含义：源在 172.17.0.0/16、且出接口**不是** docker0（即要离开本机网桥）的包，做动态 SNAT（MASQUERADE 会自动选出口 IP，等价于动态版的 `--to-source <出接口IP>`）。同网桥内容器互访走纯二层转发，不命中此规则，源 IP 保持不变——这就是"容器看到彼此真实 IP"的原因。

转发本身还需要两个内核开关：

```bash
# [任意节点] 检查转发与桥接防火墙
sysctl net.ipv4.ip_forward                 # 必须 = 1（Docker 启动时自动设）
sysctl net.bridge.bridge-nf-call-iptables  # br_netfilter 模块，K8s/Calico 也依赖
lsmod | grep -E 'br_netfilter|ip_tables|nf_conntrack|overlay'
```

## 3. 端口映射 `-p 8080:80` 的完整包路径（重点）

发布端口后，Docker 写入两条核心规则（以容器 172.17.0.2:80 为例）：

```
# nat 表
-A PREROUTING -m addrtype --dst-type LOCAL -j DOCKER        # 外部进来的包先进 DOCKER 链
-A OUTPUT ! -d 127.0.0.0/8 -m addrtype --dst-type LOCAL -j DOCKER  # 本机进程访问本机IP时也进
-A DOCKER ! -i docker0 -p tcp -m tcp --dport 8080 -j DNAT --to-destination 172.17.0.2:80
# filter 表（放行转发到该容器）
-A DOCKER -d 172.17.0.2/32 ! -i docker0 -o docker0 -p tcp --dport 80 -j ACCEPT
```

### 3.1 外部客户端 → 容器（DNAT 方向）

```
外部 192.168.1.100:44444 ──► 宿主机 eth0 :8080
        │
        ▼
   ┌──────────────────────────────────────────────────────┐
   │ PREROUTING (nat)                                     │
   │   └─► DOCKER 链：DNAT to 172.17.0.2:80                │
   │          dst 改写：192.168.1.50:8080 → 172.17.0.2:80  │
   ├──────────────────────────────────────────────────────┤
   │ 路由判定：目标 172.17.0.2 经 docker0 → 需要 FORWARD    │
   ├──────────────────────────────────────────────────────┤
   │ FORWARD (filter)                                     │
   │   └─► DOCKER-USER（用户自定义策略入口，必经）           │
   │   └─► DOCKER-FORWARD / DOCKER-ISOLATION-STAGE-1/2     │
   │        （版本不同链名不同，隔离不同 bridge 间的转发）    │
   │   └─► DOCKER 链：-d 172.17.0.2 --dport 80 -j ACCEPT   │
   ├──────────────────────────────────────────────────────┤
   │ docker0（二层）→ veth 宿主机侧 → 容器 eth0             │
   └──────────────────────────────────────────────────────┘
        │
        ▼
   容器 net-a (172.17.0.2) nginx 收到，源 IP 仍是 192.168.1.100
        │
        ▼ 回程
   容器 → 172.17.0.1 网关 → conntrack 查表发现属于已建立的 DNAT 连接
   → 反向改写 src 172.17.0.2:80 → 192.168.1.50:8080 → 发回客户端
```

回程不需要新 NAT 规则：netfilter 的 **conntrack** 记录了这条连接的 DNAT 映射，反向包在 PREROUTING 的 `ctstatus` 处理中自动还原（对 netfilter 而言 DNAT 的反向是自动 SNAT）。这就是为什么容器日志里看到的客户端 IP 是真实 IP（1:1 DNAT 而非代理）。

### 3.2 宿主机本机进程 → 容器（localhost 方向）

`curl 127.0.0.1:8080` 不经过 PREROUTING（本机发出的包走 OUTPUT），所以 nat 表 OUTPUT 链里也有指向 DOCKER 链的跳转，DNAT 同样发生；随后路由判定目标 172.17.0.2 需转发，进入 FORWARD 链。注意 DNAT 后源 IP 是 172.17.0.1（docker0），因为本机访问自己网段源地址选出口地址——所以容器看到 localhost 来的请求源是 172.17.0.1。

### 3.3 动手：把规则一条条读出来

```bash
# [任意节点] 实验前置：清场并发布端口
docker rm -f net-a net-b 2>/dev/null
docker run -d --name net-a -p 8080:80 nginx:alpine
sleep 2 && curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080   # 200
```

```bash
# [任意节点] 第 1 步：nat 表总览（-v 看包计数，--line-numbers 看优先级）
iptables -t nat -L PREROUTING -n -v --line-numbers
iptables -t nat -L DOCKER -n -v --line-numbers
# 找到 --dport 8080 的 DNAT 行，pkts 计数应 >0（刚 curl 过）

# 第 2 步：MASQUERADE 规则
iptables -t nat -L POSTROUTING -n -v | grep -i masq
# 预期：-s 172.17.0.0/16 ! -o docker0 -j MASQUERADE

# 第 3 步：filter 表 FORWARD 与 DOCKER 链
iptables -L FORWARD -n -v --line-numbers | head -12
iptables -L DOCKER -n -v --line-numbers
iptables -L DOCKER-USER -n -v        # 空链：所有策略的必经入口，写限流/审计规则的地方

# 第 4 步：一次性看全量规则（最推荐的方式，能看原始匹配条件）
iptables-save | grep -E '8080|docker0' | head -20
```

```bash
# [任意节点] 第 5 步：用 conntrack 验证 NAT 映射
conntrack -L -p tcp --dport 80 2>/dev/null | head -5
# 能看到形如：
# tcp  6 86398 ESTABLISHED src=192.168.x.y dst=192.168.1.50 sport=... dport=8080
#     src=172.17.0.2 dst=192.168.x.y sport=80 dport=... [ASSURED] mark=0 use=1
# 第二行就是 DNAT 之后的双向五元组

# 第 6 步：tcpdump 双端抓包对照（两个终端同时跑）
# 终端A：宿主机物理口
tcpdump -ni <宿主机外网口名> tcp port 8080
# 终端B：docker0（看到的是 DNAT 后的地址）
tcpdump -ni docker0 tcp port 80
# 再 curl 一次：A 上 src/dst 是 宿主机IP:8080，B 上已变成 172.17.0.2:80
```

```bash
# [任意节点] 第 7 步：删除验证（理解 DOCKER-USER 的拦截作用）
iptables -I DOCKER-USER -p tcp --dport 80 -m conntrack --ctorigdstport 8080 -j DROP
curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080   # 此时输出 000（超时）
iptables -D DOCKER-USER -p tcp --dport 80 -m conntrack --ctorigdstport 8080 -j DROP
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080        # 恢复 200
docker rm -f net-a
```

注：Docker 27/28 起 filter 表链名调整为 `DOCKER-FORWARD`、`DOCKER-BRIDGE`、`DOCKER-CT` 等，老版本是 `DOCKER-ISOLATION-STAGE-1/2`。`DOCKER-USER` 在所有版本都是策略入口，链名以你机器上 `iptables-save` 实际输出为准。

## 4. 四种网络模式对比

| 模式 | `--network` 参数 | netns 情况 | IP/端口 | 典型用途 |
|---|---|---|---|---|
| bridge（默认） | `bridge` | 每容器独立 netns，挂 docker0（或自定义网桥） | 172.17.0.x，端口需 `-p` 发布 | 绝大多数场景 |
| host | `host` | **不创建新 netns**，直接用宿主机 netns | 共享宿主机 IP，`-p` 被忽略（端口直接监听在宿主机） | 高性能转发、监控 agent（node-exporter） |
| none | `none` | 独立 netns，**只有 lo** | 无 IP、无路由 | 只要计算/文件，网络外挂（如再手工 `ip` 配置，或安全沙箱） |
| container | `container:<name|id>` | 与目标容器**共用同一个 netns** | 同 IP 同端口空间，localhost 互通 | K8s Pod 的实现模型（pause 容器） |

```bash
# [任意节点] host 模式验证：端口直接出现在宿主机
docker run -d --name net-host --network host nginx:alpine
ss -tlnp | grep ':80 '          # 宿主机上直接看到 nginx :80（进程名是容器里的）
docker rm -f net-host

# [任意节点] none 模式验证：只有 lo
docker run -d --name net-none --network none alpine sleep 3000
docker exec net-none ip addr    # 只有 lo: <LOOPBACK,UP,...>
docker exec net-none ip route   # 空
docker rm -f net-none

# [任意节点] container 模式验证：共享 netns（Pod 的原型）
docker run -d --name pod-infra --network none alpine sleep 3000     # 充当 pause
docker run -d --name pod-app --network container:pod-infra nginx:alpine
docker exec pod-app ip addr        # 有 lo + eth0（属于 infra 的 netns）
docker exec pod-infra cat /proc/net/tcp | head -3   # infra 里也能看到 80 端口监听
# 两容器的 ns 编号相同：
lsns -t net -o NS,COMMAND | head -5
docker rm -f pod-app pod-infra
```

自定义 bridge 网络（生产写法）：

```bash
# [任意节点] 自定义网络：独立网段、独立网桥、内嵌 DNS 生效
docker network create --driver bridge --subnet 172.28.0.0/24 lab-net
docker run -d --name web --network lab-net nginx:alpine
docker run -d --name client --network lab-net alpine sleep 3000
docker exec client wget -qO- http://web    # 用容器名直接访问 ← 内嵌 DNS 在工作
ip -d link | grep -B1 'br-'                # 新网桥 br-xxxxxx
iptables -t nat -L POSTROUTING -n -v | grep 172.28   # 该网段也有自己的 MASQUERADE
# 跨网桥隔离：DOCKER-ISOLATION-STAGE-1/2（或新版本 DOCKER-BRIDGE）会 DROP lab-net ↔ docker0 的转发
docker exec client wget -qO- --timeout=3 http://172.17.0.1 ; echo "exit=$?"   # 不通（被隔离或无服务）
docker rm -f web client && docker network rm lab-net
```

## 5. 内嵌 DNS：什么时候容器名能解析

Docker daemon 内置一个 DNS server，监听在**每个自定义网络的 netns 里的 127.0.0.11:53**（不是宿主机上）。规则：

| 网络类型 | 容器名 → IP 解析 | resolv.conf 指向 |
|---|---|---|
| 默认 bridge（`--network bridge`） | **不解析**（只有已废弃的 `--link` 提供hosts注入） | 沿用宿主机 DNS |
| 自定义 bridge / overlay | **解析**，支持服务发现 | `nameserver 127.0.0.11` |
| host / none | 无内嵌 DNS | 沿用宿主机 / 无 |

```bash
# [任意节点] 验证 127.0.0.11 与解析范围
docker network create dnstest
docker run -d --name dns-web --network dnstest nginx:alpine
docker run --rm --network dnstest alpine sh -c 'cat /etc/resolv.conf; nslookup dns-web; nslookup www.example.com'
# 预期：nameserver 127.0.0.11；dns-web 解析到 172.x.0.x；
#       外部域名也能解析——内嵌 DNS 会把非本网络查询转发给宿主机配置的上游 DNS

# 反例：默认 bridge 不解析
docker run -d --name plain-web nginx:alpine
docker run --rm alpine nslookup plain-web   # 解析失败
docker rm -f plain-web dns-web && docker network rm dnstest
```

内嵌 DNS 的行为边界（网络出身的人要特别注意）：

1. 它只监听容器 netns 内的 127.0.0.11，宿主机上 `dig @127.0.0.11` 是不通的；DNS 查询流量在 netns 内被 iptables REDIRECT 到 daemon 的监听端口（`iptables -t nat -L -n` 容器 netns 内可见）。
2. 只解析**同一网络内**的容器名/网络别名（`--alias`），跨网络的名字不解析。
3. 每次容器启停，名字映射实时更新——不像 DNS 有 TTL 缓存问题，但应用层自己缓存的旧 IP 不会自动刷新。
4. Kubernetes 里没有这套东西：Pod 的 DNS 是集群级 CoreDNS（`ClusterFirst`），Service 名解析依赖 kube-dns 记录，而不是 Docker daemon。Calico CNI 的 Pod 网络也不走 docker0——但 veth + netns + iptables 三件套完全同源，第 1 章和本章的知识直接迁移。

## 实战演练

一条完整的排障式演练链：搭环境 → 看转发路径上的每一跳 → 用工具验证 → 验证策略入口。命令取自本章各节，可整段照抄执行。

**演练 1：搭环境并确认 veth/网桥拓扑（对应第 1 节）**

```bash
# [任意节点]
docker run -d --name net-a -p 8080:80 nginx:alpine
ip -d link show docker0                 # 验证：类型为 bridge，IP 172.17.0.1/16
docker exec net-a ip route              # 验证：default via 172.17.0.1 dev eth0
bridge link                             # 验证：veth 宿主机侧挂在 docker0 上
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080   # 200，端口映射生效
```

**演练 2：把 `-p 8080:80` 的 NAT/过滤规则逐条读出来（对应第 3 节）**

```bash
# [任意节点]
iptables -t nat -L DOCKER -n -v --line-numbers | grep 8080
# 验证：DNAT to 172.17.0.2:80，pkts 计数 > 0（刚 curl 过）
iptables -t nat -L POSTROUTING -n -v | grep -i masq
# 验证：-s 172.17.0.0/16 ! -o docker0 -j MASQUERADE
iptables -L DOCKER-USER -n -v           # 空链：所有策略的必经入口
iptables-save | grep -E '8080|docker0' | head -20    # 原始匹配条件全量视图
conntrack -L -p tcp --dport 80 2>/dev/null | head -5
# 验证：能看到 DNAT 前后两个五元组（宿主机IP:8080 ↔ 172.17.0.2:80）
```

**演练 3：DOCKER-USER 拦截实验（对应第 3 节）**

```bash
# [任意节点] 插入 DROP → 超时 → 删除 → 恢复
iptables -I DOCKER-USER -p tcp --dport 80 -m conntrack --ctorigdstport 8080 -j DROP
curl -s -m 3 -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080   # 000（超时）
iptables -D DOCKER-USER -p tcp --dport 80 -m conntrack --ctorigdstport 8080 -j DROP
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080        # 200
```

**演练 4：四种网络模式 + 内嵌 DNS（对应第 4、5 节）**

```bash
# [任意节点] container 模式共享 netns（Pod 原型）
docker run -d --name pod-infra --network none alpine sleep 3000
docker run -d --name pod-app --network container:pod-infra nginx:alpine
docker exec pod-app ip addr            # 验证：lo + eth0 来自 infra 的 netns
lsns -t net -o NS,COMMAND | head -5    # 验证：两容器同一 NS 编号

# [任意节点] 自定义网络容器名解析；默认 bridge 不解析（反例）
docker network create lab-net
docker run -d --name web --network lab-net nginx:alpine
docker exec web wget -qO- --timeout=3 http://127.0.0.11 >/dev/null; echo "dns=$?"
docker run --rm --network lab-net alpine nslookup web    # 解析成功
docker run --rm alpine nslookup web 2>&1 | tail -1       # 解析失败（默认 bridge）
docker rm -f pod-app pod-infra web net-a && docker network rm lab-net
```

完成标准：不翻笔记能画出"外部客户端 → PREROUTING(DNAT) → FORWARD(DOCKER-USER/DOCKER) → docker0 → veth → 容器"的路径图，并说出回程靠 conntrack 自动还原。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `-p 8080:80` 外部通、本机 `curl 127.0.0.1` 也通，但另一容器 `curl 宿主机IP:8080` 不通 | 容器访问宿主机 IP 会走 FORWARD 链，命中 DROP；或 hairpin 场景源地址与目的地址同网段 | 用 `--userland-proxy=false` 观察差异；正确做法是容器间直接连目标容器 IP/服务名，而不是绕行宿主机端口 |
| 同网桥容器互 ping 通，但跨网段（自定义网络 ↔ docker0）不通 | DOCKER-ISOLATION-STAGE-1/2 / DOCKER-BRIDGE 显式 DROP 跨网桥转发 | 这是设计行为；要互通就 `docker network connect` 把容器接入同一网络 |
| 端口发布不生效，`ss -tlnp` 看到 docker-proxy 进程在监听 | userland-proxy 兜底路径生效（DNAT 之外的第二条路），可能掩盖 iptables 问题 | `iptables -t nat -L DOCKER -n -v` 确认 DNAT 命中计数；理解两条路径并存 |
| iptables 里看不到容器间流量统计 | 未加载 br_netfilter 时，同网桥二层转发不过 netfilter | `modprobe br_netfilter`（K8s 需要）；排障统计改用 `tcpdump -i docker0` |
| 容器内访问外网慢/MTU 报错（内核日志 pmtu 相关） | 隧道/VPN 环境下 veth 默认 MTU 1500 大于路径 MTU | `docker network create -o com.docker.network.driver.mtu=1400`；K8s Calico 同理有 MTU 配置 |
| 改了 DOCKER 链的规则，重启容器后失效 | Docker 每次发布端口会重写自己的链 | 自定义策略只写 `DOCKER-USER`（它在 Docker 重建时被保留） |
| 容器名解析失败 | 用了默认 bridge，或两个容器不在同一自定义网络 | `docker network create` + 两边都 `--network` 接入 |
| 内核报 `nf_conntrack: table full, dropping packet` | 容器高并发短连接耗尽 conntrack 表 | `sysctl net.netfilter.nf_conntrack_max` 调大；或业务侧启用 keep-alive |

## 自测

<details><summary>1. 为什么容器互访能看到对方真实 IP，而外部客户端经 `-p` 进来的流量在 nginx 日志里也是真实 IP？两者靠什么机制保持源地址？</summary>

同网桥互访是纯二层交换（docker0 学习 MAC 表转发），根本没有 NAT 发生；`-p` 进来的流量是 1:1 的 DNAT（只改目的地址），源地址不动，回程由 conntrack 按连接记录自动反向改写。两者都不是 proxy 模式，所以没有"经过代理变成网关 IP"的问题。只有容器**主动出公网**时才会 MASQUERADE 成宿主机 IP。
</details>

<details><summary>2. 把 `iptables -P FORWARD DROP` 设为默认 DROP 后，新起的 bridge 容器立刻失联，但老容器还活着。为什么？</summary>

Docker daemon 启动时会把 FORWARD 链的策略设为 DROP 并插入自己的 ACCEPT 跳转（DOCKER 链等）；你在 daemon 不知情时改了链策略或清了规则，新容器的发布端口规则不会再补 FORWARD 放行规则的老容器条目——更准确地说：老容器的连接已被 conntrack 记为 ESTABLISHED，命中 `ctstate RELATED,ESTABLISHED ACCEPT` 继续放行；新连接需要新建规则，被 DROP。修复：重启 docker daemon 让它重建规则，或手工补 `iptables -I FORWARD -i docker0 -j ACCEPT` 类规则。生产上 K8s 节点绝不能手工清 iptables。
</details>

<details><summary>3. host 模式容器和 `-p 80:80` 的 bridge 容器都能让外部访问 80 端口，数据面差在哪？什么场景必须选 host？</summary>

bridge+`-p`：包要经过 PREROUTING DNAT、FORWARD 过滤、veth/docker0 二层，再进容器 netns——多两次地址改写和一层转发；host：容器进程直接在宿主机 netns 监听，外部包直达到 socket，零 NAT 零转发，性能等同原生进程。必须选 host 的场景：高性能转发（网关、DPDK 类）、需要看到/处理宿主机完整网络栈（抓包 agent、监控 exporte 器拿网卡指标）、或协议对 NAT 敏感（一些集群心跳协议）。代价：端口冲突风险、无网络隔离、攻击面直通宿主机。
</details>

<details><summary>4. K8s Pod 里两个容器如何做到共享网络栈？结合 `--network container:` 说明 pause 容器的价值。</summary>

kubelet 先创建 infra（pause）容器，它持有 Pod 的唯一 NET namespace；业务容器全部以 `container:` 模式加入该 netns，共享 eth0、路由表、端口空间与 127.0.0.11。pause 的价值：（1）业务容器崩溃重启时 netns 不销毁，IP 不变；（2）pause 极小且永不退出，作为网络栈的稳定挂载点；（3）它还负责回收 Pod 内孤儿进程（PID 1 语义）。如果业务容器各自独立 netns，任一容器重启都会导致整个 Pod 网络身份变化。
</details>

<details><summary>5. 容器里 `nslookup` 一个外部域名超时，但 `ping <公网IP>` 通。给出排查顺序（至少四步，对应不同层）。</summary>

（1）resolv.conf 层：`cat /etc/resolv.conf` 是否为 127.0.0.11（自定义网络）或合法上游；`--dns` 是否被覆盖错。（2）内嵌 DNS 转发层：宿主机 `/etc/resolv.conf` 上游是否可用（在宿主机直接 dig 验证），127.0.0.11 只是转发器，上游坏它也坏。（3）UDP 53 出网层：iptables/安全组是否放行容器网段（172.17.0.0/16 MASQUERADE 后的源是宿主机 IP，检查宿主机出向策略）、conntrack 表是否满。（4）MTU/分片层：DNS 响应较大（DNSSEC 或长应答）超过路径 MTU 且被 drop 时表现为小查询通、大响应超时，检查隧道环境 MTU 与 `ip route` 的 pmtu。顺带区分：ping 通说明 L3 转发与 MASQUERADE 正常，问题锁定在 DNS/UDP/应用层。
</details>

## 延伸阅读

- Docker 网络概述：https://docs.docker.com/network/
- iptables 官方手册：https://man7.org/linux/man-pages/man8/iptables.8.html
- conntrack-tools：https://conntrack-tools.netfilter.org/
- veth 与 bridge（内核文档）：https://docs.kernel.org/networking/veth.html 、 https://docs.kernel.org/networking/bridge.html
- br_netfilter 说明：https://wiki.libvirt.org/NetfilterBridge.html
- Kubernetes Pod 网络概念：https://kubernetes.io/docs/concepts/workloads/pods/#pod-networking
