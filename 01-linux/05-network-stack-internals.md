# 05 · 内核网络栈：收包路径、netfilter 与 TIME_WAIT

> 模块：01-linux 深入 ｜ 建议时长：5 小时 ｜ 关联认证：CKA-网络（Service/kube-proxy 底座）/ CKS-网络策略（Calico 规则即 netfilter）

本章面向有网络基础的学习者：交换机路由器那套"线上的包"，这里补上"内核里的包"。K8s 网络（Service、NetworkPolicy、CNI）几乎全部建立在本章机制之上。

## 学习目标

- 能解释一个包从网卡到应用内存的完整路径（中断/NAPI/softirq/协议栈），并定位每一段的丢包计数
- 能画出 netfilter 五链与四表的矩阵，说清 conntrack 与 NAT 的协作关系
- 能排查 conntrack 表满、TIME_WAIT 堆积、ephemeral 端口耗尽三类经典故障
- 能用 tcpdump 抓一次三次握手并逐字段解读，用 ss 替代 netstat 做日常判读
- 能在 kubeadm 节点上解释 veth/网桥如何把 Pod 接进这张大图

## 1. 收包路径：从网线到应用内存

### 1.1 全景图

```text
# [RX 路径] 编号即流程
(1) 帧到达 NIC --> (2) NIC 通过 DMA 把帧写进驱动预留的 RX Ring Buffer
        |
(3) NIC 发出硬中断(hardirq, 通常 MSI-X, 告知"有货")
        |
(4) 驱动中断处理: 只做最小工作 -- 关闭该队列中断, 给 NAPI 排一个 softirq
        |
(5) softirq 上下文(NET_RX, 优先在硬中断返回后立刻跑; 持续过载时落到 ksoftirqd/N 线程)
        |
(6) NAPI poll: 轮询 RX Ring, 一次最多处理 net.core.netdev_budget 个包(默认300)
        |     (把"来一个包断一次"变成"断一次,捞一网")
(7) 每个包包成 skb; GRO 在此合并同流小包, 减少协议栈开销
        |
(8) 协议栈上行: ip_rcv --> netfilter PREROUTING 钩子 --> 路由判断
        |                                       |
        |  发往本机                              |  需转发(ip_forward=1)
        v                                       v
   netfilter INPUT --> TCP/UDP 处理        netfilter FORWARD --> POSTROUTING --> 发出
        |
(9) 数据放入 socket 接收队列, 唤醒睡在 recv/epoll 上的进程
        |
(10) 应用从内核拷走(或零拷贝直达)
```

三个设计的"为什么"：

- **为什么硬中断里只排队不处理**：10Gbps 下每秒千万包，逐包中断会把 CPU 打死（interrupt storm）。所以中断只当"门铃"，搬运用轮询。
- **为什么 softirq 可能落在 ksoftirqd**：softirq 在硬中断返回后于"借来的"上下文里跑；若持续处理不完（time_squeeze），内核把它推给每 CPU 的 `ksoftirqd/N` 内核线程——像普通进程一样被调度，避免饿死用户态。`ps -eLo comm | grep ksoftirqd | head` 能看到这些线程。
- **为什么有 GRO**：合并同流的小帧再走一遍协议栈，减少每包固定开销；它是收方向 TSO 的镜像。代价是抓包视角被"污染"（见 1.3）。

### 1.2 观测每一层

```bash
# [任意节点]
grep -E 'virtio|vmxnet|eth0' /proc/interrupts | head        # 网卡队列的中断分布在哪些 CPU
cat /proc/net/softnet_stat | head -5                        # 每 CPU 一行, 16 进制
mpstat -P ALL 1 3 | head -12                                # %soft 列: 各 CPU 的 softirq 占比
DEV=$(ip -o route get 1.1.1.1 | awk '{print $5; exit}')
sudo ethtool -S $DEV 2>/dev/null | grep -iE 'drop|miss|fifo' | head
```

`/proc/net/softnet_stat` 前三列（16 进制）是最常用的一行判读：

| 列 | 含义 | 增长说明 |
|---|---|---|
| 第 1 列 | 该 CPU 处理的包数 | 正常计数 |
| 第 2 列 | **丢包**：backlog 满（`net.core.netdev_max_backlog`）或 RPS 转发丢 | 应用层无感知地丢，查这里 |
| 第 3 列 | **time_squeeze**：一个 softirq 周期内 budget 用完仍有包 | 软中断处理不过来，常伴 `%soft` 高 |

丢包三线排查顺序（由底向上）：NIC 层 `ethtool -S` 的 rx_drops/rx_no_buffer（ring 太小，`ethtool -G` 加大）→ softnet 第 2 列（backlog/RPS，调 `net.core.netdev_max_backlog`）→ 协议栈 `nstat -az` 的 receive errors 与 listen 队列溢出（溢出计数看 `nstat -az` 的 ListenOverflows/TCPBacklogDrop，受 `somaxconn` 与应用 backlog 影响）。

多队列与亲和：现代 NIC 按 RSS 把队列散到多 CPU（`/proc/interrupts` 里同网卡多行）；VMware 的 virtio/vmxnet3 也支持多队列。单队列老设备可用 RPS（按哈希把包转发到别的 CPU 处理）。`irqbalance` 服务默认在跑，通用服务器交给它即可；低延迟场景才手工绑定中断亲和（`/proc/irq/N/smp_affinity`）。

### 1.3 发送路径与 offload 家族

TX 是 RX 的镜像，但排队点变多了：

```text
# [TX 路径] 应用 send() 之后
(1) 数据进入 socket 发送缓冲(so_sndbuf, 受 wmem_max 约束; 满则 send 阻塞/非阻塞返回EAGAIN)
        |
(2) TCP: 拥塞控制/重传决策; 可把最大 64KB 的大段直接交给下层(TSO/GSO)
        |
(3) qdisc 排队(每队列一个, tc qdisc show 查看): fq_codel/pfifo_fast 在此整形与防排队膨胀
        |
(4) 驱动 DMA 到 TX Ring --> NIC; NIC 负责真正分段(TSO)/算校验和/发线
```

offload 家族一览——抓包与性能排障时都要心里有这张表：

| 名称 | 方向 | 做什么 | 排障关联 |
|---|---|---|---|
| TSO | TX | 内核交大段，NIC 分段 | tcpdump 看到 64KB"巨帧" |
| GSO | TX | 同 TSO 但可在内核更早处分段 | 同上 |
| GRO | RX | NIC/驱动把同流小帧合并成大 skb | 抓包长度异常、CPU 软中断下降 |
| LRO | RX | GRO 的硬件前身，不保真 | 现代驱动基本弃用 |
| checksum offload | 双向 | 校验和由硬件算 | tcpdump 报"bad checksum" |
| RSS/multi-queue | RX | 多队列哈希到多 CPU | `%soft` 分布、中断亲和 |
| RPS/XPS | 双向 | 软件版多队列定向 | 单队列 VM 的软中断打散 |

`ethtool -k $DEV` 可查看/开关这些卸载（排障时临时关 GRO 再抓包能还原真实帧长，测完记得开回来）。**tcpdump 的坑**正式版：抓包点在 qdisc 与卸载之前，所以 TX 方向的"巨帧+坏校验和"是 TSO/checksum offload 还没干活，不是故障。

### 1.4 socket 层：缓冲区与等待队列

协议栈的终点是 socket：每个 socket 有收发两个缓冲区，接收方向数据入队后唤醒睡在其上的进程。三个运维相关事实：缓冲区上限由 `net.core.rmem_max/wmem_max` 与 `net.ipv4.tcp_rmem/tcp_wmem` 控制，长肥管道（高带宽×高 RTT）要够大才喂得饱窗口；应用层的 select/poll/epoll 本质是"同时在很多 socket 的等待队列上挂号"，epoll 的 O(1) 是靠内核回调而不是轮询实现的；`ss -m` 能看每个连接的内存占用，配合 `ss -i` 的 `cwnd`/`ssthresh` 可以判断"吞吐上不去"是窗口受限还是丢包受限。

```bash
# [任意节点]
sysctl net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem
ss -tm dst 10.96.0.1 | head -8       # 内存 + TCP 内部状态一起看
```

## 2. netfilter：五链四表

### 2.1 链与表的矩阵

netfilter 在协议栈里埋了 5 个钩子点（"链"），表按职能区分，交叉处打勾表示该表在该链生效：

```text
#                     PREROUTING   INPUT     FORWARD    OUTPUT    POSTROUTING
# raw(连接跟踪豁免)        v          -          -          v          -
# mangle(改包文头)         v          v          v          v          v
# nat(地址转换,首包查)     v          -          v          v          v
# filter(过滤)             -          v          v          v          -

# 三条典型路径:
#  本机收: NIC -> PREROUTING -> 路由判断(是给我的) -> INPUT -> 本机 socket
#  转发:   NIC -> PREROUTING -> 路由判断(不是给我的) -> FORWARD -> POSTROUTING -> NIC
#  本机发: 本机 socket -> OUTPUT(含nat) -> 路由 -> POSTROUTING -> NIC
```

记两个要害：

- **nat 表只在一个流的第一个包上查**：首包建 conntrack 条目并做 NAT，后续包直接按条目 fast path 改写。所以"改了 iptables NAT 规则、老连接还走旧路"是设计使然，不是 bug。
- **kube-proxy(iptables 模式) 的 Service 就活在 nat 表**：PREROUTING/OUTPUT 挂 `KUBE-SERVICES` 链，DNAT 到 Endpoint；Calico 的策略在 filter 表的 `cali-*` 链。链名就是现场排障的地图。

### 2.2 动手看一遍

```bash
# [master]
sudo iptables -t nat -L PREROUTING -n -v | head -8       # 看 KUBE-SERVICES 挂载点
sudo iptables -t nat -L KUBE-SERVICES -n -v 2>/dev/null | head -10
sudo iptables -t filter -L FORWARD -n -v | head -8       # cali-* 链在这里
sudo iptables-save | wc -l                               # 规则总量(K8s 节点上千行很正常)
```

读懂一行输出：`pkts bytes target prot opt in out source destination`——`pkts` 是**命中计数**，排查"规则到底有没有被走到"就盯它。Ubuntu 22.04+ 的 `iptables` 默认是 `iptables-nft` 后端（规则同样生效，底层由 nftables 实现）；Calico 与 kube-proxy 均已兼容，混用旧教程的 `iptables-legacy` 反而造成"互相看不到规则"的分裂，保持默认即可，细节以官方文档为准。

### 2.3 conntrack：连接跟踪

conntrack 在比 nat 更早的钩子上给每个流记账，NAT 与状态防火墙都依赖它。状态机五种状态：

| 状态 | 含义 | 典型用途 |
|---|---|---|
| NEW | 首包（如收到 SYN） | 允许出站 NEW、拒绝入站 NEW |
| ESTABLISHED | 双向已通 | `-m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT` 是最常用的"放行回程" |
| RELATED | 与既有流相关（FTP 数据连接、ICMP 错误） | 同上合并放行 |
| INVALID | 无法归类（校验错、无连接的 ACK） | 显式 DROP，防扫描 |
| UNTRACKED | 被 raw 表 NOTRACK 豁免 | 高性能旁路 |

```bash
# [master]
sudo sysctl net.netfilter.nf_conntrack_max
cat /proc/sys/net/netfilter/nf_conntrack_count
sudo cat /proc/net/nf_conntrack | head -5
```

```text
# [master] /proc/net/nf_conntrack 一行的读法(字段顺序: 原方向, 应答方向, 状态)
ipv4 2 tcp 6 431984 ESTABLISHED src=10.244.1.12 dst=10.96.0.1 sport=52312 dport=443 \
      src=172.30.30.21 dst=10.244.1.12 sport=6443 dport=52312 [ASSURED] mark=0 use=2
#   第一个 src/dst/sport/dport = Pod 发出的原方向(目标是 Service IP:443)
#   第二组 = 应答方向, sport 已变成 6443、源变成 apiserver 实地址 -> DNAT+SNAT 的账本
#   431984 = 剩余秒数(ESTABLISHED 默认 5 天, TIME_WAIT 类条目另有短超时)
```

表满是最常见的集群级事故：

```text
# [任意节点] 表满时内核日志(每秒可能刷屏)
nf_conntrack: table full, dropping packet
```

处置：临时 `sysctl -w net.netfilter.nf_conntrack_max=<更大值>`（持久化写 `/etc/sysctl.d/`，建议同时调 `/sys/module/nf_conntrack/parameters/hashsize`，经验值为 max/4）；根治是减少流数或缩短无关超时（`net.netfilter.nf_conntrack_tcp_timeout_established` 默认 432000 秒即 5 天，长连接稀少的场景可大幅调短）。K8s 为什么容易满：每个 Pod 到 Service 的连接、NodePort 的双向 SNAT、探针产生的短连接都在记账。监控对应 node_exporter 的 `node_nf_conntrack_entries` 与 `node_nf_conntrack_entries_limit`（PromQL 告警常用比值超 0.8）。

## 3. TIME_WAIT：机制与调优

### 3.1 谁进入 TIME_WAIT、为什么是 2MSL

```text
# 四次挥手(主动关闭方视角)
 主动方                    被动方
   | ---- FIN (主动方进 FIN_WAIT_1) ---> |
   | <--- ACK (FIN_WAIT_2) ------------ |
   | <--- FIN ------------------------- |   (被动方等应用 close, 停在 CLOSE_WAIT)
   | ---- ACK (主动方进 TIME_WAIT) ----> |
   |      [等待 2*MSL = Linux 固定 60 秒] |
   v  到期 -> CLOSED, 四元组可复用
```

**主动关闭方**进入 TIME_WAIT（被关闭方停在 CLOSE_WAIT 等应用调用 close，堆积 CLOSE_WAIT 是应用代码 bug）。2MSL 的两个理由：最后的 ACK 丢了还能等对方重发 FIN；让旧连接的迟到报文在网络里自然死亡，防止污染同四元组的新连接。Linux 把 2MSL 写死为 60 秒（`TCP_TIMEWAIT_LEN`，改需重编内核）；大量 TIME_WAIT 只占内核内存里的小结构（tw bucket），不占 fd，本身**不是病**。

### 3.2 什么时候才是病：客户端端口耗尽

一个 (源IP, 源port, 目的IP, 目的port) 四元组唯一即可建连。作为**客户端**高频短连接同一目标时，源端口受 `ip_local_port_range`（默认 32768~60999，约 2.8 万个）限制，60 秒内四元组不可复用 → `connect(): Cannot assign requested address`。对策分层：

```bash
# [任意节点] 先确认病情
sysctl net.ipv4.ip_local_port_range
ss -tan state time-wait | wc -l
ss -tan | awk 'NR>1{print $1}' | sort | uniq -c | sort -rn    # 各状态总数
```

| 手段 | 机制 | 备注 |
|---|---|---|
| 扩大端口范围 | `ip_local_port_range = 10240 60999` | 简单直接，先做 |
| `tcp_tw_reuse = 1` | 允许**发起方向**复用 TIME_WAIT 端口，依赖 TCP timestamps 区分新旧报文（延迟阈值 `tcp_tw_reuse_delay` 默认 1000ms） | 只对 outgoing 连接安全。取值语义：0=禁用；1=全局启用发起方复用；2=仅对 loopback 流量启用。**默认值随内核版本变化**：4.12 引入三态后多年默认 0，较新内核已改为 2（实测 Ubuntu 24.04 的 6.8 内核在新 netns 中默认为 2，可用 `sudo unshare -n cat /proc/sys/net/ipv4/tcp_tw_reuse` 验证；5.15 等旧内核多为 0——**永远以目标机实读为准**）。注意 =2 只对回环生效，出口/客户端节点缓解端口耗尽仍应显式设 1 |
| 长连接/连接池 | 治本 | 应用层方案，微服务场景首选 |
| 多个源 IP | 每个源 IP 独享约 2.8 万端口 | VIP/SNAT 池思路 |

两个老谣言必须止于本章：`tcp_tw_recycle`（曾号称回收 TIME_WAIT）因在 NAT 环境把整批客户端误杀，**内核 4.12 已删除**，搜到的老文章一律作废；`tcp_fin_timeout` 调的不是 TIME_WAIT，是主动方停在 FIN_WAIT_2 的时长（对端不回 FIN 时的保护超时）。服务端角色则基本不用慌 TIME_WAIT——监听端口可被任意源端口连接，不存在端口耗尽；服务端该做的是确认 `somaxconn`/`tcp_max_syn_backlog` 足够，以及重启绑定报 `Address already in use` 时用 `SO_REUSEADDR`（应用层）。

### 3.3 ss 判读

```bash
# [任意节点]
ss -s                                              # 总览: 各状态连接统计
ss -tan state time-wait '( dport = :6443 )' | wc -l  # 到 6443 的 tw 计数
ss -tanp | head -5                                 # -p 需要 root 才显示进程
ss -tim dst 10.96.0.1 | head -10                   # -t TCP -i 内部信息 -m 内存
ss -lnt                                            # 监听队列视角(下述)
```

`ss -lnt` 的两列队列是服务端健康的快照：`Recv-Q` = 当前等待 accept 的完成握手连接数，`Send-Q` = 应用 listen(backlog) 与 `somaxconn` 取小后的上限。`Recv-Q` 长期贴着 `Send-Q` = 应用消费不过来（accept 循环慢或线程池打满），该查应用而不是内核。`ss -i` 对 TIME_WAIT 显示 `timer:(timewait,52sec,0)`（剩余 52 秒）；对活跃连接的 `rtt`/`cwnd`/`retrans` 是比 ping 更真实的链路质量证据。

## 4. tcpdump 实战：抓一次三次握手

### 4.1 命令与输出

```bash
# [master] 终端 1: 抓与 apiserver 的握手
sudo tcpdump -i any -nn -c 12 'host 10.96.0.1 and tcp port 443' 2>/dev/null
# 终端 2: 发起一次连接(-k 跳过证书验证, 任何返回码都可以, 我们只要握手)
curl -k --max-time 3 https://10.96.0.1/version 2>/dev/null; true
```

```text
# [master] 输出示例(时间戳略), 逐行解读:
# 1) 客户端 -> 服务端 SYN
10.244.0.5.45678 > 10.96.0.1.443: Flags [S], seq 1853365232, win 64240, \
    options [mss 1460,sackOK,TS val 1234567890 ecr 0,nop,wscale 7], length 0
# 2) 服务端 -> 客户端 SYN+ACK
10.96.0.1.443 > 10.244.0.5.45678: Flags [S.], seq 3921048553, ack 1853365233, \
    win 65160, options [mss 1460,sackOK,TS val 3098765432 ecr 1234567890,nop,wscale 7], length 0
# 3) 客户端 -> 服务端 ACK (握手完成, 无数据)
10.244.0.5.45678 > 10.96.0.1.443: Flags [.], ack 3921048554, win 502, length 0
# 4) 客户端发出第一个数据包(TLS ClientHello)
10.244.0.5.45678 > 10.96.0.1.443: Flags [P.], seq 1853365233:1853365391, ack 3921048554, length 58
```

字段判读清单：

- `Flags [S]`/`[S.]`/`[.]`/`[P.]`/`[R]`：SYN、SYN+ACK、纯 ACK、PSH+ACK、RST。`[S.]` 里的点就是 ACK 位。
- `seq/ack`：**SYN 与 FIN 各消耗一个序号**，所以 SYN+ACK 的 ack = 对端 seq+1；纯 ACK 的 ack 指向"期望收到的下一个字节"。
- `win`：接收窗口通告（缩放前的值）。`wscale 7` 表示真实窗口 = win × 2^7；窗口缩放**只在 SYN 里协商**——中间设备拦掉 SYN 里的 wscale 会导致大流量卡死在小窗口。
- `mss 1460`：以太网 MTU 1500 减 IP/TCP 头各 20。`sackOK`：选择性重传。`TS val/ecr`：时间戳与回显（RTT 计量，`tcp_tw_reuse` 依赖它）。
- `length 0`：不含 payload——三次握手三行都应为 0；握手带数据属于 TCP Fast Open，罕见。

排障模式速记：只见 `[S]` 不见 `[S.]` = 服务端没回（后端挂/防火墙丢）；`[S.]` 回了但无第三次 = 回程不通（双向路径不对称的经典症状）；连接刚建立就 `[R]` = 对端拒绝（端口没人听是 RST，不是"超时"）；大量 `TCP Retransmission` 标注 = 丢包链路。过滤表达式常用款：`'tcp[tcpflags] & tcp-syn != 0'`（所有 SYN）、`'tcp[tcpflags] & (tcp-syn|tcp-ack) = tcp-syn'`（纯 SYN，即新建连接监控）、`'port 53'`。复杂分析加 `-w file.pcap` 落盘，scp 回 Windows 用 Wireshark 看流跟踪与 IO Graph。

## 5. 与 K8s 网络的衔接（预告）

Pod 不是虚拟机，它的网络是内核对象拼出来的：

```text
# 一个 Pod 的网络接入(Calico 为例, flannel 则多一层 cni0 网桥)
 +------------------ 节点 network namespace ------------------+
 |  eth0 (172.30.30.21)                                        |
 |      |                                                      |
 |  路由表: 10.244.x.y -> cali-abc dev (Calico: 每Pod一条路由) |
 |      |                                                      |
 |  cali-abc <==== veth pair ====> eth0 (Pod netns 10.244.x.y) |
 |  (主机端)                       (容器内看到的第一块"网卡")    |
 +-------------------------------------------------------------+
 # veth 是成对的虚拟连线: 从一端塞进的包会从另一端出来, 天然跨越 netns 边界
 # flannel: Pod 接 cni0 网桥, 同节点 Pod 走二层; Calico: 无桥, 纯三层路由
```

把本章机制映射上去：Pod 发出的包在 veth 主机端进入 PREROUTING——kube-proxy 的 DNAT（Service→Endpoint）与 Calico 策略链都在这附近生效；跨节点流量走 `ip_forward=1` 的 FORWARD 链；NodePort 场景还会在 POSTROUTING 做 MASQUERADE。下面这个实验能"亲眼看到 DNAT"（tcpdump 的两个抓包点分别在 netfilter 钩子前后）：

```bash
# [任意节点] 观察 DNAT 前后
kubectl get svc kubernetes                         # 记下 ClusterIP(示例 10.96.0.1)
sudo timeout 8 tcpdump -i any -nn -c 6 'tcp and port 6443' 2>/dev/null &
curl -k --max-time 3 https://10.96.0.1/version 2>/dev/null; true
# -i any 会看到同一连接出现两个"目的": 入向抓包点 dst=10.96.0.1:443(DNAT前)
# 与后续 dst=172.30.30.21:6443(DNAT后, apiserver 在本机经 lo 送达)
sudo cat /proc/net/nf_conntrack | grep 10.96.0.1 | head -3     # conntrack 账本互证
```

K8s 节点常用网络 sysctl 速查（改法统一：写 `/etc/sysctl.d/` 后 `sysctl --system`）：

| 参数 | 作用 | 常见调整场景 |
|---|---|---|
| `net.ipv4.ip_forward` | 允许转发（Pod 网段路由） | kubeadm 必设 1 |
| `net.bridge.bridge-nf-call-iptables` | 网桥流量进 iptables | 用网桥型 CNI 时必设 1 |
| `net.core.somaxconn` | 全局 listen 上限 | 高并发监听服务调大（应用 backlog 也要跟上） |
| `net.ipv4.tcp_max_syn_backlog` | 半连接队列 | SYN 洪峰/高并发新建 |
| `net.core.netdev_max_backlog` | 收包 backlog | softnet 第 2 列丢包时 |
| `net.ipv4.ip_local_port_range` | 出站源端口范围 | 客户端端口耗尽 |
| `net.ipv4.tcp_tw_reuse` | 发起方复用 TIME_WAIT（0=禁用，1=全局启用，2=仅 loopback） | 短连接密集的出口节点设 1 |
| `net.netfilter.nf_conntrack_max` | conntrack 容量 | table full 告警时 |

这套"抓包定位包在哪一层被改/被丢"的能力，会在 04-k8s-fundamentals 的网络章节与 05-cka 的 Service 排障 lab 里反复使用。

## 实战演练

### 演练 A：制造 TIME_WAIT 并观察

```bash
# [master] 用 apiserver 当靶子制造客户端短连接
for i in $(seq 1 60); do curl -sk --max-time 2 -o /dev/null https://10.96.0.1/version; done
ss -tan state time-wait | head -5
ss -tan state time-wait | wc -l
ss -tim state time-wait | grep -o 'timewait,[0-9]*sec' | head -5   # 剩余秒数
```

预期：能看到几十条到 10.96.0.1:443 的 TIME_WAIT（每次 curl 主动关闭）；`ss -s` 的 `closed` 计数同步上涨。对照 3.2 节思考：这里是 curl（客户端）主动关，所以 TIME_WAIT 在本机；若换成 apiserver 主动超时断连，TIME_WAIT 会出现在对端。

### 演练 B：观察收包软中断分布

```bash
# [任意节点] 终端 1 先看基线
mpstat -P ALL 1 5 > /tmp/mpstat-before.txt; tail -12 /tmp/mpstat-before.txt
# 终端 2 制造流量(并发短连接)
for i in $(seq 1 400); do curl -sk --max-time 2 -o /dev/null https://10.96.0.1/version & done; wait
# 回终端 1 期间观察 %soft 列
cat /proc/net/softnet_stat | head -4
sudo ethtool -S $(ip -o route get 1.1.1.1 | awk '{print $5; exit}') | grep -iE 'drop|miss' | head -3
```

判读：流量期间部分 CPU 的 `%soft` 明显抬升（多队列时分散、单队列时集中在一两个核）；softnet 第 2 列应保持稳定——若增长说明 backlog 溢出，是 1.2 节的调优对象。

### 演练 C：conntrack 全链路验证

```bash
# [master]
kubectl get svc kubernetes -o wide                       # ClusterIP 与 port
sudo conntrack -L -p tcp --dport 443 2>/dev/null | head -5 || sudo cat /proc/net/nf_conntrack | head -5
sudo iptables -t nat -L KUBE-SERVICES -n -v | grep -E 'kubernetes|dpt:443' | head -3
sudo iptables -t nat -L KUBE-SEP-$(sudo iptables -t nat -L KUBE-SERVICES -n | grep -oE 'KUBE-SEP-[A-Z0-9]+' | head -1) -n -v 2>/dev/null | head -4
```

把三样东西对上：conntrack 条目里的 `dst=10.96.0.1 dport=443`（改写前）、KUBE-SERVICES 命中计数、SEP 链里的 DNAT 目标（apiserver 实地址:6443）。这一套对应关系就是 Service 排障的底图：**conntrack 记账 + nat 表改写 + 命中计数验证**。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 大量 TIME_WAIT 被当故障 | 主动关闭方正常状态，仅占内存小结构 | 只在客户端端口耗尽时才需处理 |
| Cannot assign requested address | ephemeral 端口耗尽 | 扩 ip_local_port_range、tcp_tw_reuse=1、连接池 |
| nf_conntrack: table full | 流数超 nf_conntrack_max | 调大 max+hashsize，监控 entries/max |
| 照老文章设 tcp_tw_recycle | 该参数 4.12 已删除 | 用 tcp_tw_reuse=1（仅发起方向；=2 只是 loopback 生效） |
| tcpdump 巨帧/坏校验和 | TSO/GRO 与校验和卸载在抓包点之后 | 正常现象，别当故障 |
| CLOSE_WAIT 堆积 | 应用收到 FIN 后不调 close | 改代码，不是内核参数问题 |
| SYN 发出无 SYN+ACK | 后端挂或中间丢 | tcpdump 定位丢包段，查 Service endpoint |
| 单核 %soft 100% | RSS/RPS 未散列 | 多队列驱动、irqbalance、RPS 配置 |
| ss -lnt 的 Recv-Q 贴满 | 应用 accept 消费不过来 | 查应用线程池，somaxconn 只是上限 |
| 改 iptables 后老连接仍走旧路 | nat 表仅首包查，老连接走 conntrack | 重启业务连接或清 conntrack 条目 |
| ping 通但端口不通 | ping 是 ICMP，端口是 TCP/UDP | nc/curl 验证后再 tcpdump |

## 自测

1. 为什么 10G 场景必须用 NAPI 的"中断+轮询"混合，而不能纯中断或纯轮询？

<details><summary>答案</summary>

纯中断：小包线速下每秒千万级中断，中断处理本身耗尽 CPU，还会出现 receive livelock（中断处理挤掉了真正搬数据的 softirq）。纯轮询：空转浪费 CPU，低流量时延迟高。NAPI 取中：第一个包用中断通知（保证低流量及时性），驱动随即关闭该队列中断改轮询——有货连续捞、无货重开中断，把"每包一次中断"摊薄成"每批一次"。
</details>

2. 修改了 kube-proxy 的 iptables 规则后，已存在的长连接仍走旧路径，为什么？

<details><summary>答案</summary>

netfilter 的 nat 表只在一个流的**第一个包**上查询：首包匹配规则做 DNAT/SNAT 并写入 conntrack 条目，后续所有包直接按 conntrack 账本改写（fast path），不再遍历 nat 规则链。这是性能设计——每包都遍历上千条 KUBE-SERVICES 规则不可接受。要切断老连接：重启客户端连接，或清掉对应 conntrack 条目（`conntrack -D`），这也是"改了 Service 后旧 Pod 还连着旧 Endpoint"的标准解释。
</details>

3. 同样是"高 TIME_WAIT"，什么时候必须处理、什么时候无视？

<details><summary>答案</summary>

判据是角色与资源：若节点作为**客户端**对外高频短连（出口网关、爬虫、微服务调用方），四元组受源端口范围约束，TIME_WAIT 占住端口 60 秒，出现端口耗尽就必须处理（扩端口范围、tcp_tw_reuse=1、连接池）。若节点主要作为服务端（被连接方），TIME_WAIT 只在它主动关闭时产生且仅占内核小桶，几十万条也只是几十 MB 量级，无需干预。盲目"清理"TIME_WAIT 是把正常机制当病治。
</details>

4. ss -lnt 里 Recv-Q 长期等于 Send-Q，说明什么？调大 somaxconn 能否解决？

<details><summary>答案</summary>

Recv-Q 是已完成三次握手、等待应用 accept() 的连接数；Send-Q 是 listen backlog 上限。两者贴满说明握手完成的速度远超应用消费速度，客户的连接会在队列满后被 SYN+ACK 后丢弃或拒绝。调大 somaxconn 只是把队排得更长（缓解突发），根因是应用 accept 循环慢/线程池打满——扩应用消费能力才是解。somaxconn 同时受应用 listen() backlog 参数与内核值取小，单改内核侧不生效的场景也很常见。
</details>

5. 抓包看到客户端 SYN 与服务端 SYN+ACK 之间隔了 2 秒且时有时无，给出排查方向。

<details><summary>答案</summary>

2 秒接近 SYN 的重传间隔（初始 RTO 约 1 秒，指数退避），说明**服务端没收到 SYN，或 SYN+ACK 回程丢**。排查顺序：服务端 `nstat -az`/`netstat -su` 看 listen drops 与 SYN cookies 触发（溢出说明 `tcp_max_syn_backlog` 不够）；服务端抓包确认 SYN 是否到达——到了没回是协议栈/规则丢（查 iptables 与 backlog），没到是中间路径丢；再查反向路径。若是 K8s Service，还要确认 endpoint 就绪与 kube-proxy 规则命中计数。
</details>

## 延伸阅读

- 内核网络文档索引：<https://docs.kernel.org/networking/index.html>
- ip-sysctl（net.ipv4.* 参数官方释义）：<https://docs.kernel.org/networking/ip-sysctl.html>
- netfilter/iptables 官方：<https://netfilter.org/documentation/>
- tcpdump man 手册：<https://www.tcpdump.org/manpages/tcpdump.1.html>
- Brendan Gregg 网络栈观测：<https://www.brendangregg.com/linuxperf.html>
- K8s Service 与 kube-proxy：<https://kubernetes.io/docs/concepts/services-networking/service/>
