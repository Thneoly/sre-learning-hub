---
title_juejin: 服务不通先别抓包：DNS 解析器的坑比内核网络栈多
title_zhihu: 服务不通先别抓包：DNS 解析器的坑比内核网络栈多
description: ping IP 通、curl 域名不通，别急着抓包。nsswitch 顺序、127.0.0.53 stub、ndots:5 放大与 dig +trace 四步路径，定位解析链断点，命令可直接复制。
category_id: "6809637769959178254"
tags: "后端,程序员"
column_id: "7686472562230312970"
---
# 服务不通先别抓包：DNS 解析器的坑比内核网络栈多

> 先说结论：**ping IP 通、curl 域名不通**的时候，问题十有八九不在内核网络栈，而在"名字到 IP"这段解析链上。这时候上 tcpdump 抓 SYN，方向大概率是错的——应用发出的第一个包，往往不是为了连 IP，而是为了问一句：这个域名是什么地址？

## 一、先看全景：一条会断很多次的链

主机侧把名字解析拆成一条链，任何一环断裂，症状都是同一句：ping IP 通，curl 域名不通。

```text
# [解析链] 应用视角自上而下；排障时自下而上逐环验证
getaddrinfo("kubernetes.default")
   | NSS(/etc/nsswitch.conf): hosts: files dns myhostname  <-- 顺序在这里定死
   +-- files --> /etc/hosts        命中即返回，不再往下问
   +-- dns  --> /etc/resolv.conf（nameserver 127.0.0.53 = systemd-resolved stub）
                    --> resolved 的真实上游（按接口/VPN/DoT 各自不同）--> UDP/TCP 53
```

三个要害，后面的坑都从它们长出来：

- **顺序在 nsswitch.conf 里定死**：`hosts: files dns myhostname`，files 永远排在 dns 前面
- **/etc/hosts 命中即返回**：一条旧记录能让后面所有环节变成摆设
- **resolv.conf 不只有 nameserver**：nameserver 最多 3 个，还有 search、timeout、attempts

## 二、三个工具打架的那一刻，就是分叉点

DNS 排障最容易犯的错，是拿一个工具的结果否定另一个工具。先分清三条命令各走哪段链：

| 命令 | 实际走哪段链 | 等价于 |
|---|---|---|
| `getent hosts github.com` | 完整 NSS 链（files → dns） | 最接近应用真实行为 |
| `dig +short github.com` | resolv.conf 里的 nameserver | 绕过 /etc/hosts |
| `dig @1.1.1.1 +short github.com` | 直连外部上游 | 连本机链都绕过 |

```bash
grep '^hosts:' /etc/nsswitch.conf          # 解析顺序：files 优先于 dns
getent hosts github.com                    # 走完整 NSS 链
dig +short github.com                      # 绕过 /etc/hosts
dig @1.1.1.1 +short github.com             # 直测外部上游
resolvectl status | head -20               # resolved 视角：每接口上游 + 全局
```

结果两两组合，结论直接查表：

| 现象 | 结论 |
|---|---|
| getent 通、dig 不通 | /etc/hosts 有旧记录，或 NSS 顺序被动过 |
| dig 通、应用不通 | 应用读的根本不是这份 resolv.conf（容器/chroot） |
| dig 不通、dig @1.1.1.1 通 | 本机 stub 或它的上游配置坏了 |

这三行是 DNS 排障的半壁江山。剩下半壁，是下面两个具体的坑。

## 三、127.0.0.53：stub 的三个陷阱

Ubuntu 的 /etc/resolv.conf 通常是指向 /run/systemd/resolve/stub-resolv.conf 的软链，内容只有一行 `nameserver 127.0.0.53`。真正的上游配置活在 systemd-resolved 里——按接口、按 VPN、甚至 DoT，各自可以不同。

**陷阱一：抓包抓不到。** 应用到 127.0.0.53 的查询走 loopback，`tcpdump -i eth0 port 53` 只能看到 resolved 与上游的对话，你关心的应用 → stub 那段根本不在这块网卡上。

**陷阱二：软链被替换。** 照十年前的教程往 /etc/resolv.conf 手写静态 nameserver，从这一刻起 `resolvectl` 里改什么都不生效——文件不再是 stub 软链，resolved 被整体绕过。先 `ls -l /etc/resolv.conf` 确认指向，再谈别的。

**陷阱三：跨 netns 不可达。** 127.0.0.53 只在本网络命名空间的 lo 上有意义。nsenter 进容器再 dig 127.0.0.53 必然失败——不是 DNS 坏了，是你把宿主机的习惯带进了别人的 netns。

## 四、容器里：抄来的 resolv.conf，变了味的解析

容器有自己的 netns 和自己的 /etc/resolv.conf，但内容来源和宿主机不是一回事——这是"容器里解析行为和宿主机不一样"的第一嫌疑人。

Docker 默认抄宿主机的 resolv.conf，并**过滤回环地址**（127.0.0.53 在容器 netns 里不可达，抄进去也没用），过滤完为空则回退 8.8.8.8。`--dns` / `--add-host` 可显式覆盖。

把这个行为串到内网/离线环境走一遍【从业者判断】：

```text
宿主机 resolv.conf 只有 stub 一个 nameserver
  → 容器抄到空列表（回环被过滤）→ 回退 8.8.8.8
  → 机房防火墙不放行公网 53
  → 容器里所有域名解析超时；宿主机自己一切正常（resolved 真实上游是内网 DNS）
```

链条上每步机制都是事实，串起来的场景是从业判断。这种故障最冤的地方在于：查网络的人盯着防火墙看一晚上，不会想到问题出在 resolv.conf 的继承规则上。

## 五、ndots:5：K8s 里每个外部域名都在交税

到了 K8s，解析链完全另起一套：kubelet 给每个 Pod 生成 resolv.conf，nameserver 指向 kube-dns 的 ClusterIP（通常是 service CIDR 的第 10 个地址，如 10.96.0.10），默认 `dnsPolicy: ClusterFirst`。

```bash
kubectl run netlab-dig --image=nicolaka/netshoot --rm -it --restart=Never -- bash
```

```text
# [Pod 内] cat /etc/resolv.conf
nameserver 10.96.0.10
search netlab.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

`ndots:5` 的规则：名字点数少于 5 时，先用 search 列表逐个拼后缀查询，全部失败才查名字本身。于是访问 `www.example.com`（2 个点）实际发了 4 个查询：

```text
www.example.com.netlab.svc.cluster.local.   → NXDOMAIN
www.example.com.svc.cluster.local.          → NXDOMAIN
www.example.com.cluster.local.              → NXDOMAIN
www.example.com.                            → 真正的结果
```

nslookup 会把每次失败的 search 尝试都打出来：

```bash
nslookup www.example.com
# ** server can't find www.example.com.netlab.svc.cluster.local: NXDOMAIN
# （另两个后缀同样 NXDOMAIN，略）
# Address: 93.184.216.34   ← 第 4 次才成功
```

`github.com` 只有 1 个点，同样最多先经历 3 次 NXDOMAIN 才轮到绝对名查询。每次外部解析多 3 次往返；CoreDNS 故障或跨数据中心上游慢时，这 3 次失败查询会把外部访问延迟放大数倍，高 QPS 下全是无效负载。

零成本的最优解是**结尾加一个点**——带点是绝对域名，解析器不再拿 search 后缀去试。想在 Pod 里亲眼看到这笔税，注意一个坑：**dig 默认不应用 resolv.conf 的 search 列表**（`+[no]search` 默认 nosearch），直接 `dig +short` 两种写法都只发一次查询、看不出差异；必须加 `+search` 才能模拟 glibc getaddrinfo/curl 这类默认走 search 的解析路径：

```bash
# [Pod 内] dig 的 ndots 默认取自 resolv.conf（这里是 ndots:5）
time dig +search www.example.com    # 先拼 3 次 search 后缀 → 3 次 NXDOMAIN + 1 次命中 = 4 次查询
time dig +search www.example.com.   # 尾点 = 绝对名，跳过 search → 1 次查询
# 尾点 = 绝对名的规则对 getaddrinfo/curl 等应用解析同样生效：
# 应用里写 www.example.com.（带尾点），glibc 同样直接查绝对名，不多交 3 次税
```

四种缓解，按侵入性排：

| 手段 | 做法 | 适用 |
|---|---|---|
| FQDN 加点 | 外部域名一律写 `www.example.com.` | 零成本，很多基准测试里"加个点"就能显著降延迟 |
| 调低 ndots | `dnsConfig.options` 改 ndots | 外部流量多的特定 Pod |
| 换上游 | `dnsPolicy: None` 自定义 resolv.conf | 纯外部型 workload |
| NodeLocal DNSCache | 节点级缓存 | 减少 53 端口竞争与 iptables DNAT 开销 |

先别急着骂 ndots:5 反人类。**内部短名恰恰受益于 search 机制**——`web`、`web.netlab` 这类短名靠它才能工作；一刀切调低 ndots，伤的是集群内部调用。

## 六、三份 resolv.conf，三个世界

把三条链摆在一起，很多"玄学"立刻具体：

| 环境 | resolv.conf 来源 | nameserver | 最高频的坑 |
|---|---|---|---|
| 宿主机（Ubuntu） | stub 软链 → resolved | 127.0.0.53 | 软链被替换；eth0 上抓不到查询 |
| Docker 容器 | 抄宿主机 + 过滤回环 | 空则回退 8.8.8.8 | 与宿主机不一致；内网/离线全挂 |
| K8s Pod | kubelet 生成 | CoreDNS ClusterIP | ndots:5 放大；CoreDNS 挂了 |

宿主机 dig 通、容器里不通，先想想"应用读的是不是同一份 resolv.conf"——正是第二节"dig 通、应用不通"那行结论的展开。

## 七、排障决策路径：四步自下而上

```bash
dig @1.1.1.1 kubernetes.io                                # ① 外部上游本身通不通
dig kubernetes.io                                         # ② 本机 stub/转发链通不通
getent hosts kubernetes.io                                # ③ NSS/hosts 这层对不对
curl -v --max-time 3 http://kubernetes.io 2>&1 | head -5  # ④ 应用视角
```

①不通是网络/防火墙的事，别查 DNS 了；①通②不通，查本机 stub 和 resolved 上游；②通③不通，查 /etc/hosts 和 nsswitch；③通④不通，应用读的不是这份 resolv.conf，去查容器/chroot。

真要抓包，姿势也得对——`-i any` 能同时看到 lo 上的 stub 对话和物理网卡上的上游对话，一次抓全：

```bash
sudo tcpdump -i any -nn port 53
```

两个进阶武器，用在刀刃上：

- `dig +trace kubernetes.io`：从根逐级迭代（根 → TLD → 权威），验证权威侧链路，区分"无答案"与"转发丢"
- `dig +search nginx`：按 search 列表扩后缀再查，直接观察 ndots 行为

还有一个便宜但常被忘的判据：**answer 里的 TTL 是缓存秒数**。"改了记录还是旧结果"，先看 TTL 再怀疑 CoreDNS——大概率是缓存没过期。

K8s 侧补一刀，确认 CoreDNS 活着、配置没被动过：

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}'
```

## 八、评论区高频反驳，先答为敬

**Q：把 ndots 调成 1 不就完了？**
内部短名靠 search 机制才能工作，全局调低等于牺牲内部调用换外部解析。正确姿势是分治：外部占比高的 Pod 用 dnsConfig 单独调，或干脆 `dnsPolicy: None`。

**Q：进了 K8s 直接看 CoreDNS 日志不就行了？**
日志只覆盖 CoreDNS 那一段。四步法的①都不通时，那是网络/防火墙问题，CoreDNS 日志一行 relevant 的都不会有。【从业者判断】先花 30 秒定位断点在哪一环再决定去哪看，比上来翻日志快。

**Q：这些是 Ubuntu 的行为，我这 RHEL 呢？**
nsswitch、ndots、search 是 glibc 与 K8s 的通用机制；stub 软链是 Ubuntu 的典型形态。机制同名，默认值和文件形态以你的机器实测为准——本文第一条命令就是干这个的。

## 九、教训

1. **ping IP 通只证明网络栈没问题**：域名不通先查解析链，再考虑抓包
2. **工具结果打架是信息，不是噪音**：getent / dig / dig @upstream 各走一段链，分叉即结论
3. **resolv.conf 是"抄"出来的配置**：宿主机、Docker、K8s 三份来源不同，容器里的解析行为从不保证和宿主机一致

## 现在就做：30 秒自检

任意一台怀疑 DNS 的机器，跑这三条：

```bash
grep '^hosts:' /etc/nsswitch.conf     # files 排在 dns 前面？
ls -l /etc/resolv.conf                # 软链还在，还是被谁改成了静态文件？
getent hosts github.com               # 通 → 链健康；不通 → 按四步法往下走
```

有集群的话，进 Pod 跑一次 `nslookup www.example.com`，数数几次 NXDOMAIN——那是你每个外部请求都在交的税。

留个话头：你上一次"ping 通、curl 域名不通"，最后卡在哪一环？评论区对个暗号。
