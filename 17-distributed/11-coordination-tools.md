# 11 · 协调服务三件套：etcd vs Consul vs Nacos

> 模块：17-distributed ｜ 建议时长：4 小时 ｜ 关联认证：—（无直接考点；但"服务发现怎么做""注册中心怎么选"是微服务运维与终面的常青题，本章是 03 章 Raft 与 06 章 gossip 的工业选型落地）

## 学习目标

- 能按一致性协议、语言、部署形态三列说清 etcd / Consul / Nacos 的架构差异，并解释 Nacos 为什么同时要 Raft 和 Distro 两个协议
- 能用功能对比表回答"配置放哪、服务发现用谁、多数据中心谁内建"
- 能讲清服务发现的三种姿势（DNS / HTTP API / SDK）各自的优缺点与对应工具的最佳实践
- 能对比三家的健康检查机制（lease TTL / agent 检查 / 心跳上报），并按 01/06 章的故障检测谱系给阈值建议
- 能独立操作 etcd 的 snapshot 备份恢复与 compact/defrag 空间治理，说清 Consul 的 LAN/WAN gossip 与 Nacos 的集群存储要求

## 1. 协调服务管什么、不管什么

先把 16-bigdata/06 章的界线搬过来（ZooKeeper 一节的原表）：**协调服务管元数据与成员关系**——服务在哪、配置是什么、谁是主、锁归谁；**不管业务数据**。KV 小、写入低频、要求强一致，这是它与存储服务的分水岭，也是 03 章"为什么 K8s 不把 Pod 数据放 etcd"的答案。

这一层的三件套，加上存量的 ZooKeeper，就是当前的全部主流选项：

| 系统 | 出身 | 在这套体系里的角色 |
|---|---|---|
| etcd | CoreOS/CNCF，Raft 最早的工业级采纳者之一（03 章 §6） | K8s 控制面的存储底座，你天天在管但很少"直接用" |
| Consul | HashiCorp | 服务发现+健康检查+多数据中心，多语言微服务的主力 |
| Nacos | 阿里开源，Spring Cloud Alibaba 生态核心 | 注册中心+配置中心双合一，国内 Java 生态事实标准 |
| ZooKeeper | Apache/Hadoop 生态 | 存量刚需（HDFS HA/YARN/HBase），新建系统不再首选（16-bigdata/06 章趋势判断） |

三件套的共识底座你在 03 章全部学过了：etcd 是纯 Raft，Consul 的 server 组是 Raft，Nacos 的持久数据也是 Raft——**选型差异不在共识协议，在协议外面裹的架构形态**。这正是本章的主线。

## 2. 架构对比：同一份 Raft，三种裹法

| 维度 | etcd | Consul | Nacos |
|---|---|---|---|
| 一致性协议 | Raft（全局唯一） | Raft（server 组内）+ Serf/memberlist gossip（成员关系层） | Raft（持久实例+配置等）+ **Distro**（临时实例，AP） |
| 实现语言 | Go | Go | Java |
| 部署形态 | **静态集群**：3/5 成员，客户端直连任一成员 | **Agent + Server**：每台机器一个（client）agent，中心 3/5 个 server | **Server 集群**：≥3 节点；单机可内嵌 Derby，集群必须外置 MySQL |
| 成员变更 | 在线 member API，一次一个（learner 先行，06 章 §5） | agent 自动发现/退出（`-retry-join`），server 变更走 Raft | cluster.conf 列表 + 滚动重启（以官方文档为准） |
| 客户端接入 | gRPC/HTTP API | DNS + HTTP API + SDK | OpenAPI/HTTP + SDK（2.x 起 gRPC 长连接） |

```
[图] 三种拓扑（●=共识成员 □=无状态代理 ○=应用/客户端）

etcd —— 无代理层，客户端自己挑成员连：
    ○──►●────Raft────●────Raft────●     成员表 init 时写死，变更走 member API 一次一个

Consul —— agent 铺到每台主机，重共识收敛到 server：
    ○─□  ○─□  ○─□  ○─□                □=client agent（转发 / 本地健康检查 / 就近 DNS）
     ╲   │╱  ╱│    ╱                   全部 agent 组成一个 LAN gossip 池（8301）：
      ╲  │  ╱ │   ╱                      成员发现 + 故障检测（SWIM，06 章 §1）
       ●──Raft──●──Raft──●              ●=server（3/5 个，存全部状态）
                │
                └── WAN gossip（8302）只连其他 DC 的 server

Nacos —— 客户端直连任一 server，协议按数据分流：
    ○(SDK/OpenAPI) ──►●──┬─ Distro(AP)：临时实例，内存+心跳，最终一致
    ○ ──────────────►●──┤
    ○ ──────────────►●──┴─ Raft(CP)：持久实例+配置 ──► MySQL（集群的真相库）
```

三个要点展开：

**etcd 的"静态"是刻意设计**。成员表在 `--initial-cluster` 里写死，变更必须走 member API 一次一个（06 章 §5 的单成员变更约束）。换来的是拓扑极简：没有代理层、没有额外的成员关系协议，Raft 一个协议包办一切。代价是客户端要感知成员列表（endpoint 带全量成员），且它不主动去"发现"任何东西——服务发现要自己拼（第 4 节）。

**Consul 的 agent 是它一切差异的来源**。每台主机一个 client agent：无状态、轻量，替本机应用做三件事——转发请求到 server、**在本地执行健康检查**（第 5 节的关键）、就近应答 DNS 查询。成员关系（谁在线谁失联）不占 Raft，走 LAN gossip（SWIM 家族，06 章 §1 的 O(log n) 收敛）——**元数据走共识、成员关系走 gossip**，正是 06 章"传播用 gossip、决策用过半"的分层实践。gossip 池规模因此等于主机数，超大集群要拆分 LAN 池（官方有分区方案，以官方文档为准）。

**Nacos 的双协议是按数据类型分流的**（第 10 章"CRDT 与共识不是二选一，而是按数据分片"的同款工程思路，只是分流对象换成了 AP vs CP）：

- **临时实例（ephemeral，默认）走 Distro（AP）**：微服务实例随发布频繁生死，注册信息靠客户端心跳/长连接维持，数据只在内存，各 server 分片负责+异步同步，最终一致。丢一台 server 不丢注册表的可用性——**可用性优先，因为实例列表本来就在不停变**。
- **持久实例与配置走 Raft（CP）**：DNS 类固定实例、配置中心的数据变更频率低但**错一条就故障**，必须过半提交——一致性优先。

一句话对比：**etcd 把一切交给 Raft；Consul 把成员关系外包给 gossip；Nacos 按数据脾气分 CP/AP 两轨**。

## 3. 功能对比：各自强在哪、弱在哪

| 功能 | etcd | Consul | Nacos |
|---|---|---|---|
| KV 存储 | ★★★ 线性一致 + MVCC revision + watch + lease（线性读/revision 见 03 章 §5；lease/锁见 Lab 02 与 06 章 §4.3） | ★★ 有 KV 但官方明示不适合大 value/高吞吐（全量 Raft+内存） | 无通用 KV（配置模型不是裸 KV） |
| 服务发现 | 自己拼：`put`+lease+prefix `get`+watch，无注册/实例概念 | ★★★ DNS+HTTP+SDK 三姿势全支持，实例自动反注册 | ★★★ SDK 自动注册/发现，控制台可视化 |
| 健康检查 | 无内建，靠 lease TTL 兜底 | ★★★ agent 本地执行 HTTP/TCP/gRPC/TTL 多类型 | 心跳/连接保活（临时）+服务端探测（持久） |
| 配置管理 | 裸 KV，无命名空间/灰度/推送 UI | KV + consul-template/envconsul 渲染成文件 | ★★★ 命名空间/分组/灰度发布/变更推送/控制台 |
| 多数据中心 | 无内建（可外挂 mirror 类工具，以官方文档为准） | ★★★ WAN gossip + 跨 DC RPC 转发，原生内建 | 无内建（跨集群同步方案以官方文档为准） |
| ACL/安全 | RBAC + TLS（K8s 里默认全链路证书） | token/policy 分级，gossip 可加密 | 命名空间隔离 + 鉴权开关（**默认关闭，上线必须显式打开**） |

读表三个要点：**etcd 的强项是"当底座"而不是"当产品"**——它是给 K8s apiserver、Patroni 这类系统当存储用的（PostgreSQL HA 的 DCS 就可选 etcd/ZK/Consul，`../11-middleware/postgresql/02-replication-and-ha.md`），人直接用它做注册中心的场景少；**Consul 与 Nacos 的主战场重叠度高**（发现+配置），胜负手在生态——多语言/多 DC 偏 Consul，Java 一体化偏 Nacos；**多数据中心只有 Consul 是原生的**，这经常是跨国业务一票定音的那一项。

## 4. 服务发现的三种姿势

同一个问题"我怎么知道 web 服务现在有哪些实例"，三种接入姿势，对应不同工具的最佳实践：

| 姿势 | 谁在获取 | 优点 | 缺点/坑 | 最佳实践对应 |
|---|---|---|---|---|
| **DNS** | 客户端系统解析器 | 零 SDK、语言无关、老应用零改造 | 只有地址（SRV 补端口）、**TTL 缓存窗口**（02 章 §4.2 的二次放大）、无法带元数据过滤 | Consul DNS 接口（8600 端口，`web.service.consul`）；K8s 的 CoreDNS 同姿势（`../04-k8s-fundamentals/05-service-and-dns.md`） |
| **HTTP API** | 应用/网关/sidecar 主动拉 | 全量元数据、按标签过滤、可做 watch 长轮询 | 要自己管重连与本地缓存；轮询式拉取会压垮 server | Consul blocking query（`?index=` 长轮询）；etcd watch（revision 断点续传，与 K8s list-watch 同构，06 章 §2） |
| **SDK** | 客户端库内嵌 | 注册+发现+心跳+配置推送一条龙，长连接秒级推送 | 语言绑定（Java 之外功能打折）、SDK 升级与服务端耦合 | Nacos/Spring Cloud Alibaba；Consul 也有 SDK 但用得少 |

三种姿势可以混用，而且生产上常常就该混用：**网关走 HTTP API**（要全量元数据做路由决策），**存量/非 JVM 服务走 DNS**（零改造），**新 Java 服务走 SDK**（注册心跳配置全自动）。评审时盯住一个数：**摘除延迟 = 检查间隔×失败次数 + 服务端传播 + 客户端缓存 TTL**——DNS 姿势的 TTL 是最容易被漏算的一层（02 章 §4.2 的老坑）。

## 5. 健康检查机制对比

01 章的结论先立在桌上："宕机判定永远是在猜"（01 §1，06 §3）。三件套对"怎么猜"给出了三种答案，恰好覆盖谱系：

| 维度 | etcd（lease TTL） | Consul（agent 检查） | Nacos（心跳/探测） |
|---|---|---|---|
| 谁证明活着 | **客户端上报**：进程定期 lease keepalive | **agent 主动拉**：HTTP/TCP/gRPC 探测；或 TTL 型由服务主动上报 | 临时实例：客户端心跳（1.x）/gRPC 连接保活（2.x）；持久实例：服务端探测 |
| 谁计时 | etcd 服务端统一计时 | agent 本地 | Nacos server |
| 判定语义 | TTL 到期即摘除（key 自动删除） | 连续失败 → critical（可配自动反注册） | 1.x 经典语义：5s 心跳、15s 标记不健康、30s 摘除（阈值以官方文档为准） |
| 应用侵入 | 要进程里写 keepalive | HTTP/TCP 型**零侵入**（agent 去探） | SDK 全托管；OpenAPI 注册则要自己发心跳 |
| 检测视角 | lease 是单点判定 | agent 单点判定，server 只汇总视图 | server 单点判定，Distro 同步结论 |

三个运维判断：

1. **检测方的位置决定侵入性**：Consul 的 HTTP/TCP 检查是 agent 替你去探，应用一行代码不用改（老系统友好）；etcd lease 与 Nacos 心跳都是"应用必须自己报"——忘了续租，活着也会被摘。发布重启窗口内 keepalive 停止导致的"发布即误摘"，是这两种模式共同的经典坑（对策：摘除阈值 > 发布耗时，或发布时主动反注册）。
2. **判定都没有多数派交叉验证**：单 lease、单 agent、单 server 的判定就足以摘除实例——因为摘错一个实例的代价（少一个副本/摘掉重连）远小于摘错一个 leader（06 章 §3 谱系：参与者越多越保守）。**成员层面的死亡判定**才需要多点确认（Consul gossip 的 SWIM suspect 机制就在成员层做了这件事，06 章 §1）。阈值取舍与 06 章 HDFS 10 分钟 vs etcd 1 秒是同一杆秤：实例检查偏灵敏（秒级），成员判定偏保守。
3. **时钟依赖全在服务端**：三家的到期判定都由服务端/agent 本地计时，不跨节点比墙钟——06 章 §4.3"租约要服务端统一计时"的教训被普遍吸收了。

## 6. 运维深讲

### 6.1 etcd：备份恢复与空间治理

**备份**：`etcdctl snapshot save` 一条命令拿全量一致性快照（快照本身经 Raft 提交保证一致）。完整的命令参数、证书路径、考场流程在 `../05-cka/04-etcd-backup-restore.md` §2 逐行拆过，这里补协调服务视角的三条纪律：

1. **snapshot 是"新集群的种子"，不是"原地回滚"**：restore 会生成一套全新 member 数据目录，必须先停旧成员/换目录再拉起——把它当成灾备的最后一招，日常的成员故障优先走"救回一台恢复 quorum"（03 章 §2.2 的持久性账）。
2. **异地与演练缺一不可**：快照留在同宿主机等于没备；恢复流程每季度真跑一次（不然和你没写过的 runbook 一样，是装饰品——13-sre 方法论的老规矩）。
3. **cron 里别用 `docker exec` 取证书的方式做长期方案**：练习集群图省事，生产用独立 etcdctl + 专用证书，权限收敛到备份账号。

**空间治理**（04-k8s/13 章 §2.2 讲过三件事的命令，这里串成闭环）：etcd 的 MVCC 保留全部历史版本，`compact` 指定 revision 之前的版本可删（不可逆，之后读旧 revision 拿 410），`defrag` 才把空间真正还给文件系统。**顺序永远是先 compact 后 defrag，defrag 逐成员做、别同时**（同时做等于主动制造一次 quorum 抖动）。静态 Pod 里配 `--auto-compaction-retention` 让压缩常态化，比人肉 cron 稳。

**监控**（07 章演练 3 已摘过 fsync 与提案指标，协调服务视角再补三件）：

```promql
# [本地Windows·浏览器] 协调服务的三条命根子：有主吗、盘快吗、库满吗
rate(etcd_server_leader_changes_seen_total[15m])        # >0 持续出现 = 脑旋前兆（03 章常见坑）
histogram_quantile(0.99, rate(etcd_disk_wal_fsync_duration_seconds_bucket[5m]))
etcd_mvcc_db_total_size_in_bytes / etcd_server_quota_backend_bytes
# 第三条逼近 1 时集群会触发 NOSPACE 告警并进入只读保护——07 章演练 2 查的就是它的现场；
# 指标名以集群 etcd 版本实际输出为准
```

另备一条救火命令：`etcdctl alarm list` 看 NOSPACE，处理完空间后 `alarm disarm` 解除只读（恢复动作本身也要走一遍 Raft，别在失 quorum 时做）。

### 6.2 Consul：Agent 模式与 LAN/WAN gossip

Consul 的部署单元是 **agent**，两种角色：**client agent**（每台主机一个，无状态、不存数据，转发 RPC、本地跑健康检查、应答 DNS）与 **server agent**（3/5 个，Raft 成员，存全部状态）。这套分层的精髓是把"重共识"收敛到极少数 server，把"轻交互"（探活、DNS、本地缓存）撒到每台机器——对照 etcd 的"客户端直连共识成员"，代价是每个主机多养一个常驻进程（内存占用不大，但要纳入主机管理与监控清单）。

gossip 两层（06 章 §1 的模型在这里落地）：

- **LAN gossip（端口 8301，UDP/TCP）**：单个数据中心内全部 agent（client+server）组成一个成员池。职责是成员发现（新 agent `-retry-join` 自动入池）与故障检测——SWIM 式探测+suspect 确认，节点失联的消息 O(log n) 轮传遍全池。**注意这一层判的是"agent/主机死没死"，与第 5 节的服务健康检查是两码事**：前者防的是 Consul 自己的成员视图腐化，后者管业务实例。
- **WAN gossip（端口 8302）**：只连各数据中心的 server，让多个 DC 互相知道"对方 DC 的 server 是谁"。跨 DC 的服务发现请求由本 DC server 经 RPC（8300）转发到目标 DC——**每个 DC 一套独立 Raft，数据不跨 DC 复制**。这是"联邦"不是"多副本"，与第 10 章 CRDB 的数据多活是两个层面的事。

运维三条：gossip 开加密（`-encrypt`，LAN/WAN 各一把钥匙）；大集群拆分 LAN 池防 gossip 风暴；WAN 跨公网时 server 间 RPC 走 TLS 与合适的安全组——gossip 只解决"找到人"，不负责"链路安全"。

排障与防火墙离不开这张端口表（以官方文档为准）：

| 端口 | 协议 | 用途 |
|---|---|---|
| 8300 | TCP | server 间 Raft/RPC |
| 8301 | TCP+UDP | LAN gossip（同一 DC 全部 agent） |
| 8302 | TCP+UDP | WAN gossip（跨 DC，只有 server 参与） |
| 8500 | TCP | HTTP API（演练 1 用的注册/查询接口） |
| 8600 | TCP+UDP | DNS 接口（演练 1 的 dig 打这里） |

记忆锚点：**8300 段是 Consul 自己人说话（RPC/gossip），8500/8600 是对外服务**；UDP 只出现在 gossip 和 DNS 上——安全组漏了 UDP 的 8600，就会出现"API 正常、DNS 间歇超时"的怪象（DNS 走 UDP 先试）。

### 6.3 Nacos：集群与存储

生产部署的硬约束：**至少 3 个 server 节点组成集群**，成员表写在每台的 cluster.conf 里（列全部节点 IP:port），配合外置数据库。存储是分叉点，也是最容易踩的坑：

- **单机模式**可用内嵌 **Derby**（Java 内置的小数据库，零配置）——只配测试和练手；
- **集群模式必须外置 MySQL**（官方建议主备高可用）：配置数据、持久实例的真相在 MySQL，各 server 直读数据库并通过事件通知同步缓存，持久数据的一致性再叠 Raft/Distro 分轨（实现细节随版本演进，以官方文档为准）。它与 etcd"一切经 Raft、一切在 member 里"是两种哲学——**Nacos 把真相放在外置 DB、共识只管内存态的同步与仲裁**，因此多了一层"MySQL 挂了 Nacos 还能不能写配置"的依赖要进故障预案。

版本敏感的两条（以官方文档为准）：2.x 起 SDK 走 **gRPC 长连接**，端口按"主端口+偏移"计算（8848 的客户端 gRPC 在 9848、服务端在 9849）——**安全组只放行 8848 会看到控制台正常、SDK 全连不上的经典症状**；临时实例的摘除语义（心跳 5s/15s/30s 是 1.x 经典值）在 2.x 长连接模式下由连接保活承担，阈值随版本调整。环境隔离用**命名空间**（dev/prod 物理分开）+ 分组，别让测试实例混进生产注册表。

最后补配置中心的运维纪律——这是 Nacos 双合一身份里最容易被轻视的一半。配置变更是**高危操作**：一次推送直达全部在线实例，等于同时改了整个集群的行为，而且是推送制（改完即生效，没有"下次发布才生效"的缓冲）。三条规矩：**灰度先行**（Nacos 支持 Beta 推送——先推一台/一组验证，控制台或 OpenAPI 均可，用法以官方文档为准）；**变更可回滚**（历史版本留档，回滚也要演练）；**配置即代码**（配置文件进 Git 走评审，控制台只做应急通道——与 06-cicd-iac-gitops 模块的 GitOps 思想同源：手动改配置就像手动改 K8s 对象，下一次同步就把它冲掉）。

## 7. 选型决策树

```
你要协调的对象是谁？
│
├─ K8s 集群与云原生栈
│    └──► etcd——已经随 K8s 存在，不需要"再选一个"；
│         K8s 内的服务发现直接用 Service + DNS（04-k8s/05 章），
│         别在 K8s 旁边再立一套注册中心给原生工作负载
│
├─ 多语言微服务 + 多数据中心 + 要细粒度健康检查
│    └──► Consul——Agent 铺满主机，DNS/API/SDK 全姿势，多 DC 原生
│
├─ 国内 Java/Spring Cloud 生态，注册中心+配置中心想一把抓
│    └──► Nacos——双合一、中文控制台、SDK 与配置灰度生态最深
│
└─ Hadoop 生态存量（HDFS HA/YARN/HBase）
     └──► ZooKeeper——存量刚需（16-bigdata/06），新建系统不再引入
```

用本仓库的 JD 调研校准一遍预期（`../_meta/research-2026-08-jd-platforms.md`）：排名表里 Linux 是近乎 100% 的前置，"容器与 K8s"紧随其后排第 2，是"高频（云原生必备，传统岗快速渗透）"级的第一梯队技能——**etcd 是你已经在管、不需要另选的那一个**；而 Consul/Nacos 从不以独立技能名出现在运维 JD，它们藏在"微服务治理""配置中心""Spring Cloud"这类字样后面，跟着公司技术栈走：国内 Java 一脉（阿里系）基本默认 Nacos，海外/多云/多语言环境多见 Consul。这与 16-bigdata/06 章末尾的趋势判断同向："服务发现/配置场景被 Nacos/Consul 分流，独立的协调服务正在退出新建系统的架构图"。所以面试的最佳答法不是背三件套参数，而是**先问"协调的对象是什么"，再按决策树落地，最后补一句趋势**——第 2 节那张架构对比表就是你的论据。

## 实战演练

三个演练把三种服务发现姿势和三种健康检查各跑一遍。环境：装有 Docker 的 Ubuntu VM。

```bash
# [任意节点] 演练 1：Consul——DNS/HTTP 两种姿势 + agent 健康检查摘除
docker network create consnet
docker run -d --name web1 --network consnet nginx:1.25-alpine
docker run -d --name consul-lab --network consnet -p 8500:8500 -p 8600:8600/udp consul:1.15
sleep 5
# 向 consul 注册 web 服务，健康检查 = agent 每 5s 探一次 HTTP（agent 容器与 web1 同网络可达）
WEB1=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' web1)
curl -s -X PUT http://127.0.0.1:8500/v1/agent/service/register -H 'Content-Type: application/json' -d @- <<EOF
{"Name":"web","ID":"web-1","Address":"$WEB1","Port":80,
 "Check":{"HTTP":"http://$WEB1:80/","Interval":"5s","DeregisterCriticalServicesAfter":"2m"}}
EOF
# 预期：无输出（HTTP 200）；等 5~10s 让第一次检查通过

# 姿势一：DNS 发现（dig 在 dnsutils 包：apt-get install -y dnsutils）
dig @127.0.0.1 -p 8600 web.service.consul +short
# 预期：$WEB1 —— 健康实例才被 DNS 返回

# 姿势二：HTTP API 发现（带元数据，可过滤）
curl -s 'http://127.0.0.1:8500/v1/health/service/web?passing=true' | python3 -m json.tool | grep -E '"Address"|"Port"|"Status"'
# 预期：Address=$WEB1  Port: 80  Status: passing

# 健康检查摘除现场：停掉 nginx，agent 探测失败 → critical → DNS 不再返回
docker stop web1; sleep 8
curl -s 'http://127.0.0.1:8500/v1/health/service/web?passing=true'
# 预期：[] —— passing 过滤后为空（这就是"摘除"，2 分钟后自动反注册）
dig @127.0.0.1 -p 8600 web.service.consul +short
# 预期：无输出 —— 第 4 节的摘除预算公式在这里肉眼可见
```

```bash
# [任意节点] 演练 2：etcd——lease TTL 当注册表（无内建检查，全靠续租）
docker run -d --name etcd-lab gcr.io/etcd-development/etcd:v3.5.16 \
  etcd --listen-client-urls http://0.0.0.0:2379 --advertise-client-urls http://etcd-lab:2379
E() { docker exec etcd-lab etcdctl --endpoints=http://127.0.0.1:2379 "$@"; }
LEASE=$(E lease grant 15 | awk '{print $2}')
E put /svc/web/instance-1 "10.1.2.3:80" --lease="$LEASE"
E get --prefix /svc/web/
# 预期：一条记录 instance-1 —— "注册"=put 绑 lease

sleep 16   # 不发 keepalive = 模拟进程死了没人续租
E get --prefix /svc/web/
# 预期：空 —— lease 到期 key 自动删除，服务"被摘除"；
# 对照：若期间一直跑 E lease keep-alive $LEASE &，key 就一直活着
docker rm -f etcd-lab
```

```bash
# [任意节点] 演练 3：Nacos——临时实例的心跳摘除（单机模式，内嵌 Derby 仅限于此）
docker run -d --name nacos-lab -e MODE=standalone -p 8848:8848 -p 9848:9848 nacos/nacos-server:v2.2.3
sleep 40   # Java 启动慢；9848 是 SDK 的 gRPC 端口（8848+1000），OpenAPI 演练用不到但顺手放出
curl -s -X POST "http://127.0.0.1:8848/nacos/v1/ns/instance?serviceName=web&ip=10.1.2.3&port=8080&ephemeral=true"
curl -s "http://127.0.0.1:8848/nacos/v1/ns/instance/list?serviceName=web" | python3 -m json.tool | grep -E '"ip"|"port"|"healthy"'
# 预期：ip=10.1.2.3 port=8080 healthy=true —— 临时实例注册成功
# （浏览器开 http://127.0.0.1:8848/nacos，默认 nacos/nacos，控制台里也能看到这个实例）

sleep 35   # 这个用 curl 注册的实例没有人心跳
curl -s "http://127.0.0.1:8848/nacos/v1/ns/instance/list?serviceName=web" | python3 -m json.tool | grep -c '"ip"'
# 预期：0 —— 15s 不健康、30s 摘除的心跳语义；2.x 行为与阈值以官方文档为准

# [任意节点] 清理三个演练
docker rm -f consul-lab web1 nacos-lab && docker network rm consnet
```

验证方法：三个演练分别对应三种检查机制的"摘除时刻"——Consul 是 agent 探测失败后 DNS 静默（秒级），etcd 是 lease 到期 key 消失（TTL 级），Nacos 是无人心跳后列表清空（30s 级）。把三者耗时记下来，就是第 5 节"检测方位置决定一切"的实测注脚。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| etcd DB 涨满、集群突然只读 | MVCC 历史版本累积触发 NOSPACE 配额保护 | `alarm list` 确认 → compact+defrag → `alarm disarm`；常态化 auto-compaction + 配额使用率告警（6.1 节） |
| defrag 后集群抖动甚至短暂失主 | 多成员同时 defrag | 逐成员串行做，避开业务高峰（04-k8s/13 §2.2 的原话） |
| Consul 摘了实例，调用方还在打 | 摘除预算漏算了客户端 DNS 缓存 TTL | 调小记录 TTL 与检查间隔；预算公式=检查间隔×次数+传播+客户端 TTL（第 4 节） |
| etcd 上注册的服务"死了还在" | put 没绑 lease，进程死了没人删 key | 注册一律绑 lease+keepalive（演练 2 的反面教材） |
| 发布重启期间实例被误摘、又被注册回来 | keepalive/心跳在滚动窗口内中断，摘除阈值小于发布耗时 | 摘除阈值 > 发布耗时；或发布流水线里先反注册再停进程 |
| Nacos 集群各节点数据对不上 | 集群模式误用内嵌 Derby（Derby 只支持单机） | 集群必须外置 MySQL，三节点起步 + cluster.conf 各节点一致（6.3 节） |
| Nacos 控制台正常，SDK 全连不上 | 2.x gRPC 端口（8848+1000=9848）没放行 | 安全组/防火墙把偏移端口一起开；以官方文档为准 |
| 用轮询打 Consul/etcd 的发现接口 | 没用 blocking query/watch，QPS 随实例数暴涨 | 长轮询或 watch 断点续传（第 4 节，对照 06 章 list-watch） |
| 注册中心裸奔，任何人可注册伪造服务名 | Nacos 鉴权默认关闭/ACL 没配 | 上线前显式开鉴权与 ACL，注册入口收敛到内网 |

## 自测

1. 为什么 Nacos 要同时维护 Raft 和 Distro 两个协议？把临时实例也改成 Raft 管会怎样？
<details><summary>答案</summary>

临时实例随发布频繁生死、数量大，注册表的价值在"永远可用且够新"，错了短暂影响小（实例本来就要死要活）——所以走 Distro（AP）：内存分片+异步同步+心跳维持，牺牲强一致换可用性与吞吐。持久实例与配置是低频高危数据（配置错一条全站故障），必须过半提交——走 Raft（CP）。若临时实例也走 Raft：每次注册/心跳摘除都要过半 fsync，发布高峰的注册风暴会直接打满共识层（03 章共识代价的全款），而换来的"强一致实例表"在秒级变化的负载面前没有意义。这正是第 10 章"按数据脾气分流 CP/AP"的运维版。
</details>

2. Consul 的多数据中心与 Redis CRDB 的多活，都是"多地部署"，本质差异是什么？
<details><summary>答案</summary>

Consul 的多 DC 是**控制面联邦**：每个 DC 一套独立 Raft，数据不跨 DC 复制，跨 DC 请求靠 WAN gossip 找到对端 server 再 RPC 转发——它解决"多地都能查到本 DC 的注册视图"，不复制业务数据。CRDB 是**数据面多活**：多地实例互相异步复制业务数据本身，靠 CRDT 合并冲突（第 10 章）。一句话：Consul 复制的是"目录"，CRDB 复制的是"货"。混用两个词是面试常见口误。
</details>

3. 公司已经用 K8s 了，为什么还常见旁边再立一套 Nacos/Consul？什么时候不应该立？
<details><summary>答案</summary>

立的原因：K8s Service+DNS 只服务"跑在 K8s 里、网络可达 Pod"的工作负载；混合部署（物理机/虚机/多 K8s/跨环境）、需要配置中心（灰度/推送/控制台）、非 JVM 老系统要 DNS 发现、注册视图要跨 K8s 集群统一——这些 K8s 原生机制不覆盖，需要独立注册中心。不应该立的情况：工作负载全是单一 K8s 集群内的原生服务——这时再立一套等于两份实例真相（endpoint 与注册表）要互相同步，发布/扩缩容要双写，经典的"元数据双头"。原则：注册中心跟"部署域"走，一个部署域一份真相。
</details>

4. 业务反馈"实例挂了 2 分钟才摘除"。按第 4 节的预算公式列出排查顺序，并给每层一个可调参数。
<details><summary>答案</summary>

预算=检查间隔×失败次数+服务端传播+客户端缓存 TTL，按层排查：① 检查层——Consul 的 `Interval` 与临界阈值（或 Nacos 的 15s/30s 心跳阈值、etcd 的 lease TTL）；② 传播层——server 间同步周期（Distro/gossip 的间隔）、DNS 视图刷新；③ 客户端层——DNS 记录 TTL、SDK 本地缓存刷新间隔（02 章 §4.2 的二次放大）。逐层量出耗时再定调哪个参数——盲目调小检查间隔会把网络抖动变成误摘（06 章 §3 的取舍）。
</details>

5. etcd 的 snapshot 恢复为什么不能当"日常回滚"用？给出一次该走 snapshot 而不是"抢修一台成员"的判断标准。
<details><summary>答案</summary>

snapshot restore 生成的是全新数据目录，必须停旧成员、换目录、重拉全集群，期间协调服务整体不可用——它是分钟级灾备动作，不是秒级运维动作。日常的成员故障优先走"救回任一成员恢复 quorum"：03 章 §2.2 的持久性账——挂掉台数 < quorum 时已提交数据必然还在多数派手里，救一台即恢复读写，成本远低于重建。该走 snapshot 的判断标准：存活成员已不足 quorum 且无法救回（数据目录损坏/多数成员同时丢失），即"多数派持有数据"这一前提被物理破坏——此时 snapshot 是最后的种子。中间态（恰好挂到 quorum 数）仍然先抢修，别急着重建（03 章常见坑原条目）。
</details>

## 延伸阅读

- etcd 灾备官方指南（snapshot save/restore 的权威流程）：https://etcd.io/docs/latest/op-guide/recovery/
- etcd 维护官方指南（compact/defrag/quota 语义）：https://etcd.io/docs/latest/op-guide/maintenance/
- Consul 架构官方文档（agent/server 分层与共识）：https://developer.hashicorp.com/consul/docs/architecture
- Consul gossip 官方概念（LAN/WAN 池与 Serf）：https://developer.hashicorp.com/consul/docs/concept/gossip
- Nacos 官方文档入口（部署模式/集群/OpenAPI，版本细节以此为准）：https://nacos.io/en-us/docs/what-is-nacos.html
- ZooKeeper 章的协调服务定位与趋势判断（本仓库）：`../16-bigdata/06-zookeeper.md`
