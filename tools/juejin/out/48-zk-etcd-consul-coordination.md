---
title_juejin: 'ZK、etcd、Consul 怎么选：差别不在共识，在壳'
title_zhihu: '协调服务选型：先问你要协调的对象是谁，再谈 ZK、etcd 还是 Consul'
description: 'ZooKeeper一次性watch、etcd lease续租、Consul健康检查、ZAB与Raft底座对照、session timeout两难、K8s选etcd、多数团队加条DNS就够。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686341072617242662"
---

# ZooKeeper、etcd、Consul 怎么选：共识底座是同一定理，差别全在外面的壳

架构评审会上最容易吵起来的一题：协调服务用 ZooKeeper、etcd 还是 Consul？然后各方开始背参数，谁吞吐高、谁延迟低、谁 ZAB 谁 Raft。

这些吵点大多是假问题。先把结论摆桌上：**选型差异不在共识协议，在协议外面裹的壳**——怎么表达"活着"（会话、租约还是健康检查）、watch 触发一次还是持续推、服务是不是一等公民。这三问答完，答案自己会浮出来。

## 1. 协调面管什么：四个共同原语

先划一条比任何对比表都重要的界线：**协调服务管元数据与成员关系，不管业务数据**——服务在哪、配置是什么、谁是主、锁归谁，是它的地盘；KV 小、写入低频、要求强一致，这是它与存储服务的分水岭。

三兄弟手里其实是同样的四件武器：

- **强一致 KV**：小数据。ZK 甚至故意把自己限制得又小又慢（相对存储系统）来换强一致——数据全内存、写走过半提交，单机写吞吐万级每秒、延迟毫秒级。
- **会话/租约**：把"活着"变成服务端可判定的状态。ZK 的会话、etcd 的 lease、Consul 的健康检查，是同一件武器的三种握法。
- **watch**：变更通知，配置下发与服务发现的实时更新全靠它。
- **锁与选主**：不是独立功能，是前三件拼出来的组合拳。

SRE 视角补一刀：这类组件挂了，不影响已有数据管道的"数据面"，但所有依赖它的"控制面"（HA 切换、选主、寻址）会瘫痪——典型的小而致命，监控优先级应与 etcd 同级。

**协调面的全部生意，是替一组对等进程回答"谁活着、谁是主"。**

## 2. ZK 的壳：znode 树、临时节点、一次性 watch

ZK 的命名空间是一棵树，每个节点（znode）最多存 1MB 数据。真正值钱的是两类特殊节点：

- **临时节点**：与创建它的会话绑定，会话结束（quit、崩溃、超时）节点自动删除。天然表达"活着"：实例注册一个节点，进程挂了注册自动消失，无需人工清理。
- **顺序节点**：创建时自动追加 ZK 保证单调的 10 位序号，分布式排队全靠它。

锁和选主就是这两块积木的拼法。选主最小化：`create -e /myapp/leader`，创建成功者为主，失败者 watch 这个节点，节点消失即重新竞争——HDFS 的 ZKFC 就是这个逻辑加一层 fencing。

锁的排队版：临时加顺序节点，序号最小者持锁，其余人只 watch 恰好比自己小一号的节点——只通知一个人，避免 N 个等待者同时被唤醒冲击 ZK（羊群效应）。

**watch 是一次性的，这是 ZK 最容易踩的语义坑**：

- 事件触发一次即失效，必须重新注册才能继续监听；
- "收到事件"与"重新注册"之间存在丢失窗口，正确姿势是收到后立刻重注册、再全量读一次；
- 会话过期后，所有 watch 与临时节点全部作废——大量"监听莫名失效"问题的根因。

为什么不做成永久的？一次性让服务端状态简单可预期，代价是把复杂度推给客户端：要么自己重注册，要么用 Curator Cache 封装。

旧版 Kafka controller 的 watch 风暴是反面教材：一个 broker 下线触发大量 watch 回调，回调又去创建/删除节点触发更多 watch，把故障放大——这也是 KRaft 要消灭 ZK 依赖的动机之一。

两条终端，亲眼看"只触发一次"：

```bash
docker run -d --name zk-lab zookeeper:3.9
docker exec -it zk-lab zkCli.sh      # 终端 A：进入客户端
```

```text
# 终端 A 内：
create /myapp ""
create /myapp/config v1
get -w /myapp/config                 # 注册一次性 watch
```

```bash
docker exec -it zk-lab zkCli.sh      # 终端 B：同一容器再开一个客户端
```

```text
# 终端 B 内：
set /myapp/config v2   # 终端 A 立即打印 WATCHED EVENT ... NodeDataChanged
set /myapp/config v3   # 终端 A 毫无反应——watch 只触发一次

# 临时节点随会话消失：终端 A 执行 create -e /myapp/leader me 后 quit，
# 1~2 秒后终端 B 执行 ls /myapp —— leader 已被服务端自动清理
```

```bash
docker rm -f zk-lab                   # 清理
```

## 3. etcd 的壳：lease、revision、持续 watch

etcd 用两样东西回答同样的问题。

**lease（租约）**：注册等于 put 一个 key 并绑上 lease，进程定期 keepalive 续租；TTL 到期 key 自动删除。服务端统一计时，进程死了没人续租，注册自动消失——与 ZK 临时节点语义等价，只是表达从"会话"换成了"租约"。

**revision（全局单调版本号）**：MVCC 多版本存储，每次修改全局 revision 加一；watch 是持续推送的，断线重连可从上次的 revision 续传，历史版本被压缩越过才退回全量 list（读旧 revision 拿 410）。

K8s 的 list-watch 与此同构：先 LIST 全量、再从 revision 起 WATCH 增量长推，controller、scheduler、kubelet 全靠这套机制活着。

**etcd 把重注册的复杂度收回了服务端**——持续 watch 加 revision 续传，这是 K8s 选 etcd 的语义层理由。

架构层还有一条：etcd 是刻意的静态集群——成员表初始化时写死，无代理层，Raft 一个协议包办一切，成员变更走 member API 一次一个。

拓扑极简，适合当底座；代价是它不主动"发现"任何东西，服务发现要自己拼：put 加 lease 加 prefix get 加 watch，没有"注册""实例"的概念。

所以有一句从业者共识：**etcd 的强项是当底座，不是当产品**——K8s apiserver、Patroni 这类系统拿它当存储底座，人直接拿它当注册中心的场景反而少。

八条命令看 lease 当注册表（无人续租即摘除）：

```bash
docker run -d --name etcd-lab gcr.io/etcd-development/etcd:v3.5.16 \
  etcd --listen-client-urls http://0.0.0.0:2379 --advertise-client-urls http://etcd-lab:2379
E() { docker exec etcd-lab etcdctl --endpoints=http://127.0.0.1:2379 "$@"; }
LEASE=$(E lease grant 15 | awk '{print $2}')
E put /svc/web/instance-1 "10.1.2.3:80" --lease="$LEASE"
E get --prefix /svc/web/
# 预期：一条记录 instance-1 —— "注册"就是 put 绑 lease

sleep 16    # 不发 keepalive，模拟进程死了没人续租
E get --prefix /svc/web/
# 预期：空 —— lease 到期 key 自动删除，服务"被摘除"
docker rm -f etcd-lab
```

## 4. Consul 的壳：服务目录与健康检查是原生的

Consul 换了个思路：不给你积木，直接把"服务"做成一等公民。

部署单元是 agent，两种角色：每台主机一个 client agent，无状态，替本机应用做三件事——转发请求到 server、在本地执行健康检查、就近应答 DNS；中心 3~5 个 server 组成 Raft，存全部状态。

成员关系（谁在线谁失联）不占 Raft，走 LAN gossip（SWIM 式探测）。**元数据走共识、成员关系走 gossip**——重共识收敛到极少数 server，轻交互撒到每台机器。

这套分层换来两个别家没有的原生能力：

- **健康检查零侵入**：HTTP/TCP/gRPC 型检查是 agent 替你去探，应用一行代码不用改，老系统友好。对照 etcd lease 和心跳模式都是"应用必须自己报"——忘了续租，活着也会被摘。
- **服务发现三姿势全支持**：DNS（零 SDK、老应用零改造）、HTTP API（全量元数据、可过滤）、SDK（注册心跳配置一条龙）。生产上常常就该混用：网关走 API、存量系统走 DNS、新服务走 SDK。

**ZK 和 etcd 卖积木，Consul 卖装好的目录**。只有它把"发现服务"当主业做：实例自动反注册、健康才进 DNS。

经常一票定音的还有一条：多数据中心原生内建（WAN gossip 连各 DC 的 server）。注意它是"联邦"不是"多副本"——每个 DC 一套独立 Raft，数据不跨 DC 复制，跨 DC 请求靠 RPC 转发。一句话：Consul 复制的是目录，不是货。

KV 它也有，但官方明示不适合大 value、高吞吐（全量走 Raft 且在内存）——它没打算在 KV 上跟 etcd 打。

再看 agent 探活怎么把实例从 DNS 里摘掉（dig 在 dnsutils 包：apt-get install -y dnsutils）：

```bash
docker network create consnet
docker run -d --name web1 --network consnet nginx:1.25-alpine
docker run -d --name consul-lab --network consnet -p 8500:8500 -p 8600:8600/udp consul:1.15
sleep 5
WEB1=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' web1)
curl -s -X PUT http://127.0.0.1:8500/v1/agent/service/register \
  -H 'Content-Type: application/json' -d @- <<EOF
{"Name":"web","ID":"web-1","Address":"$WEB1","Port":80,
 "Check":{"HTTP":"http://$WEB1:80/","Interval":"5s",
          "DeregisterCriticalServicesAfter":"2m"}}
EOF
# 预期：无输出（HTTP 200）；等 5~10 秒让第一次检查通过
dig @127.0.0.1 -p 8600 web.service.consul +short
# 预期：输出 $WEB1 —— 健康实例才会被 DNS 返回

docker stop web1 && sleep 8      # agent 探测失败 → critical
dig @127.0.0.1 -p 8600 web.service.consul +short
# 预期：无输出 —— 实例被"摘除"，这就是发现侧看到的死亡
docker rm -f consul-lab web1 && docker network rm consnet
```

## 5. 共识底座：ZAB vs Raft，同一页纸

把三兄弟的底座掀开，全是同一条定理：**过半提交，同一任期至多一个 Leader**。ZK 的 ZAB、etcd 的 Raft、Consul server 组的 Raft，差别在术语，不在数学。

| 概念 | ZAB（ZooKeeper） | Raft（etcd / Consul） |
| --- | --- | --- |
| 任期 | epoch（zxid 高 32 位） | term |
| 提交序号 | zxid | log index |
| 提交条件 | 过半 ACK 后广播 COMMIT | 过半复制即提交 |
| 读旧数据 | 本地读可能旧，读己之写需 sync | 线性读走 ReadIndex |
| 成员变更 | 3.5+ 动态 reconfig，默认关 | 原生成员 API，一次一个 |

ZAB 选举规则是理解它的钥匙，优先级三层：epoch 大者胜，再到 zxid 大者胜，最后 myid 大者胜。zxid 大等于事务日志最全，让数据最新的节点当选，避免已提交事务被回滚。

脑裂防护也是同一套数学：5 节点被分区成 2+3，少数派侧的 PROPOSAL 永远凑不够过半 ACK，事务卡死不提交；多数派侧选出新 Leader、epoch 加一，分区恢复后旧侧以更高 epoch 为准。

**同一 epoch 过半互斥，至多一个 Leader 能提交**——与 Kafka ISR 的 min.insync.replicas、MongoDB 副本集多数派是同一条定理的三个化身。

连部署铁律都同源：3 节点容 1 台，扩容跳过 4 直接到 5——4 节点过半要 3 票，容错还是 1 台。**共识底座不构成选型理由：学会一个，就懂了另一个。**

## 6. session timeout 的两难：超时永远是在猜

本专栏故障检测那篇的结论先立在桌上：完美故障检测不存在，超时是在误杀率和检测延迟之间选边站。session timeout，就是这个两难在协调面上的工程化。

ZK 的会话超时，是客户端请求值被服务端的 [minSessionTimeout, maxSessionTimeout]（默认 4s~40s，由 tickTime 派生）夹逼后的协商值；客户端周期性发 ping 维持，**判死权在服务端**。两难具体长这样：

设短了：一次长 GC、一段网络抖动，服务端就判死会话、删光它的临时节点——锁没了、主被重选。客户端从 GC 里醒来，还以为会话在、锁在，这就是"会话漂移"和僵尸持有者（zombie holder）。

设长了：真死的进程要干等超时才释放临时节点，主备切换整体变慢——HBase、HDFS 的切换延迟直接受它影响。

Kleppmann 在《DDIA》里有经典论述：ZK 锁解决"互相知情"，解决不了"进程暂停后旧持有者继续写下游"——治本靠 fencing token（把 znode 的 version/czxid 当令牌随每次下游写入携带，下游拒绝旧令牌）。

工程结论只有一句：**不要把会话超时设得比业务最长暂停还短，也不要盲目调大到分钟级**——最长暂停按长 GC、网络重试这类窗口算。

etcd 的 lease 是同一杆秤的另一端：keepalive 一停、TTL 一到就摘，于是"发布即误摘"成了 lease 与心跳模式共同的经典坑——滚动重启窗口内续租中断，活着的服务被摘掉。对策写死在预案里：摘除阈值大于发布耗时，或者发布流水线里先反注册再停进程。

再背一个预算公式，排查"摘太慢"全靠它：**摘除延迟=检查间隔×失败次数+服务端传播+客户端缓存TTL**——DNS 姿势里的 TTL 是最常被漏算的一层。

补一段谱系感：实例层的死亡判定，单 lease、单 agent、单 server 说了就算——摘错一个实例的代价，远小于摘错一个 leader。

成员层的死亡判定才需要多点交叉确认（Consul gossip 的 suspect 机制就做在成员层）。实例检查偏灵敏、成员判定偏保守，两套阈值不对称不是拍脑袋，是代价不对称。

## 7. 选型：先问协调的对象是谁

决策树直接抄进评审纪要：

- **K8s 集群与云原生栈 → etcd**。它已随 K8s 存在，不需要"再选一个"；K8s 内的服务发现直接用 Service + DNS。K8s 从第一天就选了 etcd。
- **多语言微服务 + 多 DC + 细粒度检查 → Consul**。Agent 铺满主机，DNS/API/SDK 全姿势，多 DC 原生。（国内 Java、Spring Cloud 一脉是 Nacos 的地盘：注册加配置双合一，不在三兄弟之列但绕不开。）
- **Hadoop 生态存量 → ZooKeeper**。HDFS HA、YARN RM HA、HBase 在 3.3.x 时代深度绑定，存量集群的 ZK 技能仍是刚需。

再看趋势：**ZK 正被替换出新建系统的架构图**。Kafka 是它最大的前租户，KRaft 把元数据本身变成一条 Raft 复制的日志，时间线一步到位：2.8 引入（preview）→ 3.3 生产可用 → 3.5 弃用 ZK 模式 → 4.0 移除。

同方向的还有 ClickHouse Keeper（Raft 实现、协议兼容 ZK 客户端、去 JVM）。

为什么被替换？旧架构的痛是结构性的：元数据存 ZK，broker 启动全量拉取加注册 watch，分区多时启动慢、watch 风暴放大故障；controller 切换分钟级；两套系统的证书、备份、扩容都要人养——ZK 成员表是静态配置，加一台节点要改所有节点配置并逐台重启。

**共识被内嵌进产品自身，独立的协调服务正在退场**。选型评审时可以直接写进结论的一条：不为任何新项目引入 ZK【从业者判断】。

## 8. 反方：很多团队只需要 etcd 加一条 DNS

讲完"三兄弟怎么选"，自己拆一次台：**多数团队不需要第三套系统：etcd 加条 DNS 就够**【从业者判断】。

什么时候不该在 K8s 旁边再立注册中心？工作负载全是单一 K8s 集群内的原生服务时。再立一套等于两份实例真相（endpoint 与注册表）要互相同步，发布、扩缩容都要双写——经典的"元数据双头"。

什么时候该立？K8s 原生机制覆盖不了的四类场景：混合部署（物理机、虚机、多 K8s、跨环境）；要配置中心（灰度、推送、控制台）；非 JVM 老系统要 DNS 发现；注册视图要跨集群统一。

原则一句话：**注册中心跟"部署域"走，一个部署域一份真相**。所以选型的第一问不是"哪个最强"，而是"你有没有第二个部署域"。没有，就别立；有，再回第 7 节的决策树。

## 9. 一张表带走

| 维度 | ZooKeeper | etcd | Consul |
| --- | --- | --- | --- |
| 共识底座 | ZAB | Raft | Raft（server 组）+ gossip（成员层） |
| "活着"的表达 | 会话 + 临时节点 | lease + keepalive | agent 健康检查，可零侵入 |
| watch 语义 | 一次性，客户端重注册 | 持续推送，revision 续传 | blocking query 长轮询（DNS 靠 TTL 刷新兜底） |
| 服务发现 | 无概念，拼 znode | 无概念，拼 lease 加 watch | 一等公民，DNS/API/SDK |
| 多数据中心 | 无 | 无内建 | 原生内建（联邦，非复制） |
| 新架构定位 | 存量刚需，不再引入 | K8s 底座 | 多语言、多 DC 主力 |

面试一句话：三兄弟底座同源，差异在壳——活着的表达、watch 的续传、服务是否一等公民；先问协调对象，K8s 用 etcd、纯服务发现加多 DC 用 Consul、Hadoop 存量守 ZK；而只有一个 K8s 部署域的团队，etcd 加一条 DNS 就够。

## 现在就能做的事

跑第 2 节那两个终端，亲眼看 watch 沉默的那一下——那一下，就是 Kafka 要消灭 ZK 的理由。顺手自检三问：

你们的注册表和 K8s endpoint，是一份真相还是两份？session timeout、lease TTL 是拍的，还是按最长 GC 与发布耗时标定的？锁方案带 fencing token 吗，还是"用了锁就当绝对安全"？

这套对照表和三个实验收在我维护的 SRE 学习仓库：GitHub 搜 sre-learning-hub——ZK 章在大数据模块（含四字命令运维手册），etcd/Consul/Nacos 章在分布式模块（含 Nacos 双协议 Raft 加 Distro 的完整拆解）。

最后聊个实的：你们生产现在跑的是三兄弟里哪一个，当年是谁拍板、为什么选它？评论区交代一下这段架构史，我挑最有故事的一个画成演进图。
