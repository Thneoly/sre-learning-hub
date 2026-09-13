# Lab 03 · 解答：Consul 服务发现与健康检测

> 逐步操作 + 原理对应 + 面试答法。先自己按 task.md 走，卡住再对照。
> 运行位置统一：装有 Docker 与 docker compose 的 Ubuntu VM（`[任意节点]`，示例环境 user@172.30.30.50）。
> 镜像 tag 与命令输出细节随 Consul 1.x 版本略有差异，以官方文档为准：https://developer.hashicorp.com/consul/docs

## 0. 原理速览：一个 Consul 集群里跑着两套分布式机制

```
        ┌───────────── 控制面（强一致：Raft）─────────────┐
        │  dist-consul-1(leader)   dist-consul-2   dist-consul-3
        │      │◄──── LAN gossip（SWIM/serf，成员管理）────►│◄──►│
        └──────┼──────────────────────────────────────────────┘
               │ 本 agent 每 2s 执行一次 HTTP 检查（遗漏故障判定）
               ▼
        dist-web-1 :8080/health   （python http.server 假服务）
               ▲
               │ DNS 8600 / HTTP API 8500 查询 web.service.consul
        消费方（宿主 dig / curl）—— 只拿到 passing 实例的地址
```

两套机制各管一件事，正好把本模块第 03/06 章捏在一起：

| 平面 | 机制 | 管什么 | 已学对照 |
|---|---|---|---|
| 成员平面 | LAN gossip（SWIM 家族） | 谁在线（serfHealth 检查就是它）| Redis Cluster 的 cluster bus（06 章第 1 节）；"gossip 管知情" |
| 状态平面 | Raft 多数派 | 服务目录、KV、检查结果的唯一真相 | etcd（Lab 01 杀的就是同一个协议）；"quorum 管定罪" |

三句话把语义说死（面试可直接用）：

1. **健康检查是遗漏故障判定，不是死亡证明**（01 章第 1 节）：HTTP 探测 2s 一次、1s 超时，失败即 critical——Consul 不区分"进程死了"和"网络到它不通"，它只是**停止向消费方推荐这个实例**。
2. **DNS/API 只返回 passing**：消费方拿不到地址 = 流量被摘。摘除的滞后 = 检查间隔 + 超时 + 客户端 DNS 缓存——这三个数加起来就是你告警里"用户还在打到坏实例"的窗口。
3. **注册走 agent API，不走 catalog API**：catalog 的 Check 字段只写一条静态健康记录，**没有 agent 会去执行它**，状态永远不更新（官方文档明说"要真正启用检查必须走 agent 配置或 agent 端点"）。生产注册姿势是本 lab 的 `/v1/agent/service/register`，或配置文件/`consul services register`。

## 1. 起环境：三节点 server 集群 + 假服务

compose.yaml 全文见 task.md 提示 1。要点逐条说清：

- `-dev` 是单 agent 纯内存模式，无法组网；三节点用 server agent 的最小配置（无 TLS/ACL、不挂数据卷）等价替代，行为同样"重启即清空"，仅练习用。
- `-bootstrap-expect=3`：凑齐 3 个 server 才发起选举。这就是 03 章的 quorum 账——3 成员 quorum=2，挂 1 台还能读写，挂 2 台集群宁可无主。
- `consul2/3` 的 `-retry-join=dist-consul-1`：通过容器 DNS 找到 1 号再加入，比让它们自己互相猜稳定。
- 端口只发布 `dist-consul-1` 的 8500（HTTP）与 8600（DNS）到宿主——运维上这就是"你只暴露一个接入端点，集群内部东西向流量不外漏"。

```bash
# [任意节点] 启动并等 bootstrap（首次拉镜像会慢）
mkdir -p ~/dist-consul && cd ~/dist-consul
#（把 task.md 提示 1 的内容存为 compose.yaml）
docker compose -p dist-consul up -d
sleep 12
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'dist-consul|dist-web'
# 预期：四个容器全部 Up
```

## 2. 集群状态验证：members、raft、leader 三件套

```bash
# [任意节点] 成员表：gossip 平面的视图
docker exec dist-consul-1 consul members
# 预期（IP 换成实际分配值）：
# Node           Address          Status  Type    Build   Protocol  DC   Segment
# dist-consul-1  172.29.1.2:8301  alive   server  1.20.x  2         dc1  <all>
# dist-consul-2  172.29.1.3:8301  alive   server  1.20.x  2         dc1  <all>
# dist-consul-3  172.29.1.4:8301  alive   server  1.20.x  2         dc1  <all>

# Raft 平面的视图：谁是 leader
docker exec dist-consul-1 consul operator raft list-peers
# 预期：三行，State 列恰好一个 leader、两个 follower

# 宿主经 HTTP API 问 leader（消费方视角，无需进容器）
curl -s http://127.0.0.1:8500/v1/status/leader
# 预期："172.29.1.2:8300"（非空字符串；无 leader 时返回 ""）
```

**为什么两条命令都要看**：`members` 问的是 gossip（成员关系），`raft list-peers` 问的是共识（日志复制关系）。绝大多数时候两者一致，但**排障时它们可能分叉**——比如某节点 gossip 活着但 Raft 日志严重落后（06 章第 1 节"集群视图短暂不一致是常态"）。先分清你问的是哪个平面，再看差异。

## 3. KV 存取：写走 Raft，读要分一致性档位

```bash
# [任意节点] 写两个键（在任一 server 容器内；非 leader 成员会把写转发给 leader）
docker exec dist-consul-1 consul kv put service/config/nginx/port 8080
docker exec dist-consul-1 consul kv put dist/lab/owner sre
# 预期：Success! Data written to: service/config/nginx/port
#       Success! Data written to: dist/lab/owner

docker exec dist-consul-1 consul kv get service/config/nginx/port | tee ~/dist-consul/kv.txt
docker exec dist-consul-1 consul kv get dist/lab/owner | tee -a ~/dist-consul/kv.txt
# 预期：8080 / sre（ tee 进 kv.txt，check 第 7 项要读的就是它）
```

KV 的每笔写都是一次 Raft 提交（过半持久化才应答）——与 etcd 的写路径同构（03 章第 4.3 节）。**读默认不是线性一致**：Consul 的 default 档读可能命中 follower 的旧值，要严格一致得加 `?consistent`（等价 etcd 的线性读/ReadIndex 思路），要更低延迟可 `?stale`（容忍任期内旧值）。这三档的取舍与 etcd `--consistency=s` 的串行读是同一张账（Lab 01 第 7 步的"失仲裁时串行读仍能读到旧值"就是它的极端形态）。KV 适合放"低频、小、要强一致的元数据"——和 etcd 当配置中心的边界完全一样。

## 4. 注册 web 服务：JSON 走 agent API

web.json 全文见 task.md 提示 2。三个字段最值得记：

- `Name` 是**查询键**：DNS 的 `web.service.consul`、API 的 `/v1/health/service/web` 都用它；
- `Address`/`Port` 是**实例真实地址**，`Address` **必须填 IP**——Consul DNS 对非 IP 的 Service.Address 只回 CNAME、不回 `web.service.consul` 自身的 A 记录（1.x/2.x 行为一致），而 A 记录正是任务 6 的判分对象。它也可以与执行检查的 agent 不在一台机器——本 lab 故意如此：注册在 dist-consul-1，服务在 dist-web-1。生产里通常每台机器跑一个本地 client agent、服务注册到本地 agent（检查走 localhost，避免"检查通了服务、挂了网络"的假阳性）；
- `Checks` 是数组：一个服务可挂多个检查，全 passing 服务才 passing。检查的 HTTP URL 允许用主机名（agent 走容器 DNS 解析 `dist-web-1`），与 `Address` 填 IP 并不矛盾。

```bash
# [任意节点] 取容器 IP 生成 web.json（全文见 task.md 提示 2），再注册并确认入目录
WEB1=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dist-web-1)
#（用提示 2 的 heredoc 把 "Address": "$WEB1" 写进 ~/dist-consul/web.json）
curl -s -X PUT -H 'Content-Type: application/json' \
     --data-binary @$HOME/dist-consul/web.json \
     http://127.0.0.1:8500/v1/agent/service/register
docker exec dist-consul-1 consul catalog services
# 预期两行：consul / web
```

**为什么不用 `/v1/catalog/register`**：catalog 是"目录的直写通道"（低层机制），它写的 Check 是静态记录，没有 agent 执行，状态永远不会翻转——你在界面里会看到一个永远 passing 的假健康。agent API 注册的服务由 agent 周期探测，结果再经反熵（anti-entropy，02 章第 4 节 §4.1 的术语：副本间持续对账）同步进 catalog。一句话：**catalog 是结果，agent 才是产生结果的机制**。这也解释了本 lab 能做出 critical 的前提——检查真的有人在跑。

## 5. 验证 passing 与 DNS 解析

```bash
# [任意节点] 轮询等首次探测成功（wait_status 函数见 task.md 提示 3）
wait_status passing
# 预期：t=1s 或 t=2s 时 "Status":"passing"
#       ——注册后到首次探测之间有一个短暂的初始 critical 窗口，正常现象

curl -s http://127.0.0.1:8500/v1/health/service/web \
  | grep -o '"Status":"[a-z]*"' | tee ~/dist-consul/health-passing.txt
# 预期两行：
# "Status":"passing"     ← serfHealth：节点级检查，gossip 成员关系给的
# "Status":"passing"     ← web-1-http：服务级检查，agent 每 2s 探测给的

# DNS 查询（宿主；dig 在容器里没有，consul 镜像不带）
dig @127.0.0.1 -p 8600 web.service.consul | tee ~/dist-consul/dns.txt
# 预期（节选）：
# ;; ANSWER SECTION:
# web.service.consul.  0  IN  A  172.29.1.5      ← TTL=0：别缓存，每次都来问
# ;; Query time: 0 msec

# 核对 A 记录确实是假服务的容器 IP
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dist-web-1
```

两条运维细节：A 记录 **TTL=0** 是设计——服务发现地址的可用性以 Consul 实时健康为准，缓存会放大摘除窗口（要用 TTL 也只敢给几秒，且要清楚代价）；两条检查（serfHealth/web-1-http）分开看的价值马上体现。还有一条注册姿势：这条 `IN A` 之所以存在，是因为第 4 步的 `Address` 填的是**容器 IP**——填主机名只会得到 `IN CNAME dist-web-1.`，check 第 12 项的正则永远匹配不上。

## 6. kill 假服务 → critical：观察摘除

```bash
# [任意节点] 杀进程（SIGKILL；容器进入 Exited，注册与检查仍在——正是要的语义）
docker kill dist-web-1
wait_status critical
# 预期：2~4 个轮询周期内翻转（间隔 2s + 超时 1s）

curl -s http://127.0.0.1:8500/v1/health/service/web \
  | grep -o '"Status":"[a-z]*"' | tee ~/dist-consul/health-critical.txt
# 预期两行：
# "Status":"passing"      ← serfHealth 仍 passing：节点（dist-consul-1）没死，gossip 照常
# "Status":"critical"     ← web-1-http critical：只是服务死了

# 摘流量实证：DNS ANSWER 段变空
dig @127.0.0.1 -p 8600 web.service.consul +short
# 预期：空输出（默认只返回 passing；想看全量可用 dig ... 'web.service.consul?passing=false'）
```

`health-critical.txt` 里那行仍然 passing 的 serfHealth 是本 lab 最有教学价值的一笔：**节点检查（gossip 成员）与服务检查（HTTP 探测）是两个独立的判定来源**。进程死 → 只有服务级 critical；宿主机死 → serfHealth 也变 critical，该节点上**所有**服务一起被摘。半夜排障先看是哪一种：前者重启进程/容器，后者先救机器。而判定语义都一样——**超时只是在猜**（01 章），所以生产检查间隔要按"误报代价 vs 摘除延迟"调，本 lab 的 2s 是练习值。

## 7. 恢复 → passing：闭环

```bash
# [任意节点] 拉起同一个容器（沿用原 command，服务照旧监听 8080）
docker start dist-web-1
wait_status passing
# 预期：容器起来后 2~4s 内回 passing；dig +short 重新返回 IP
```

注意语义：恢复的是**健康状态**，注册从未消失——agent 里的注册表与 catalog 的对账（反熵）一直在做。生产里实例滚动重启就是靠这个闭环：新实例 passing 后 DNS 自动"挂"回地址，全程无人工。

## 8.（可选）杀 Leader：把 Lab 01 在 etcd 上做过的事再来一遍

```bash
# [任意节点] 脚本见 task.md 提示 4；核心是 State 列找 leader、kill、对幸存者轮询
cat ~/dist-consul/leader-elect.txt
# 预期（示例）：
# 1427
# dist-consul-3
```

预期耗时几百毫秒到几秒（Consul 的 Raft 选举超时与 etcd 同量级，默认值以官方文档为准）。与 Lab 01 的 etcd 数字并排看：**同一协议，换宿主换名字，切换耗时同量级**——这就是 03 章第 7 节"换词汇表"的实测版。两个 Lab 的差异才值得回味：本 lab 杀 Leader 的同时**服务发现读不受影响**（DNS/API 读不需要每次都过 Raft——agent 本地应答，容忍短暂旧视图），而 etcd 失 Leader 期间默认线性读也要等——**读路径的一致性档位决定了故障期的用户体验**（07 章读路径分解法的活例子）。

做完记得 `docker start` 恢复该节点并 `consul members` 确认三席归位，再跑 check。

## 9. 判分与清理

```bash
# [任意节点] 在 check.sh 所在目录
chmod +x check.sh && ./check.sh
```

通过输出：

```
PASS: dist-consul-1 容器在运行
PASS: dist-consul-2 容器在运行
PASS: dist-consul-3 容器在运行
PASS: dist-web-1 容器在运行（健康服务已恢复）
PASS: 集群 leader 存在（/v1/status/leader 返回 "172.29.1.2:8300"）
PASS: consul members 显示 3 个 alive 的 server agent
PASS: KV service/config/nginx/port 的值为 8080
PASS: 服务 web 已注册（consul catalog services 列出 web）
PASS: health-passing.txt 记录了服务健康（passing）状态
PASS: health-critical.txt 记录了服务被摘除（critical）状态
PASS: web-1-http 当前状态为 passing（服务已恢复）
PASS: dns.txt 含 web.service.consul 的 A 记录（DNS 服务发现证据）

SCORE: 12/12
```

（全部只读：docker inspect、consul 只读子命令、HTTP GET、文件 grep。`leader-elect.txt` 是可选任务，不判分。）

```bash
# [任意节点] check 通过后清理
cd ~/dist-consul && docker compose -p dist-consul down -v --remove-orphans
docker network rm dist-consul-net 2>/dev/null
```

## 10. 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 注册后检查状态永远不变 | 用了 `/v1/catalog/register` 的 Check 字段——静态记录，无人执行 | 改走 `/v1/agent/service/register`（或 agent 配置文件/`consul services register`） |
| 杀了服务 DNS 还返回旧 IP | 摘除延迟 = 检查间隔 + 超时 + 客户端 DNS 缓存 | 缩短 Interval；A 记录 TTL 本就是 0，别在客户端侧加长缓存 |
| dig 只有 CNAME（`web.service.consul → dist-web-1`），没有 A 记录 | 注册时 `Address` 填了主机名——Consul DNS 对非 IP 的 Service.Address 只回 CNAME，不回 `web.service.consul` 自身的 A 记录 | `Address` 改填容器 IP（`docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dist-web-1`）后重新注册；健康检查 URL 可继续用主机名 |
| 注册后短暂 critical 就报警 | 首次探测前的初始 critical 窗口是正常语义 | 告警加"注册后 N 秒内不告"的静默，或用 `SuccessBeforePassing` 平滑（参数以官方文档为准） |
| 检查 green 但用户打不通 | 检查地址与真实服务地址不一致（健康检查打到别处） | 检查地址、端口、路径与 Service.Address/Port 同源；生产用本地 agent 注册 |
| 分不清"服务挂"还是"节点挂" | 只看了一个检查 | serfHealth（gossip 节点级）与服务检查分开看：前者 critical=救机器，后者 critical=救进程 |
| `members` 显示 alive 但 Raft 落后 | gossip 与 Raft 是两个平面，短暂分叉是常态 | 以 `raft list-peers` 的 State/CommitIndex 为准判断共识健康 |
| 2 节点 Consul"感觉也够用" | 2 成员 quorum=2，容错 0（03 章奇数原则） | server 固定奇数起步 3/5；client agent 不受此限 |

## 11. 自测（面试怎么答）

<details><summary>1. Consul 里 gossip 和 Raft 各管什么？为什么不全用 Raft？</summary>

gossip（SWIM/serf，LAN 8301）管成员关系与失败疑似：O(log n) 轮收敛、无中心、对丢包容忍，节点数大也便宜；Raft 管需要唯一真相的状态——服务目录、KV、检查结果：每次写过半提交、强一致但每次都有往返成本。不全用 Raft 因为成员探测是**每节点每秒级的高频心跳**，过半确认会把心跳成本放大成 O(n²) 往返且中心化；不全用 gossip 因为"服务到底注册没有、值是多少"必须任意两读一致，概率收敛给不了。这是 06 章"gossip 管知情、quorum 管定罪"的架构级落地。
</details>

<details><summary>2. 用 catalog API 注册的 check 为什么不执行？这个设计的边界在哪？</summary>

catalog 是强一致目录的直写通道，它只接受"状态的快照"而不负责"产生状态"——Check 字段写进去就是一条静态健康记录，没有任何 agent 被指派去跑它（官方文档明确：要启用检查须走 agent 配置或 agent 端点）。它的定位是给"外部系统已经自己有健康数据"的场景手工同步目录用的。本 lab 需要真实翻转 passing/critical，所以必须 agent API。边界判断一句话：**谁产生状态，就注册到谁那里**。
</details>

<details><summary>3. 从实例挂掉到消费方拿不到它的地址，延迟由哪几段组成？</summary>

四段相加：检查间隔（本 lab 2s）+ 单次探测超时（1s，且若配了连续 N 次失败才判死还要乘 N）+ agent 把结果写进 catalog/Raft 的传播时间（秒级内）+ 消费方侧 DNS 缓存 TTL（Consul 返回的 A 记录 TTL=0，但客户端/解析器可能自作主张缓存）。所以"秒级摘除"是诚实预期，"毫秒级"要么牺牲误报率（间隔调小），要么上客户端主动健康探测。这本质是 01 章"误杀 vs 检测延迟"的取舍在服务发现上的重现。
</details>

<details><summary>4. 杀掉服务进程和杀掉 Consul server（Leader），对服务发现的影响有何不同？</summary>

杀服务进程：只有该服务的 HTTP 检查变 critical，DNS 摘掉该实例，集群无感——注册数据仍在，恢复即 passing。杀 server Leader：Raft 在剩余成员里重新选举（几百毫秒到几秒，本 lab 第 8 步实测），期间**新写**（注册/注销/KV）失败，但 DNS/API 的**读**仍由各 agent 本地应答——读不过 Raft，容忍短暂旧视图。对照 etcd：失 Leader 时默认线性读也要等（ReadIndex 要确认 leader），Consul 的服务发现读更像"串行读"档位。答案的关键词是：写路径受共识保护、读路径看一致性档位（07 章读路径分解法）。
</details>

<details><summary>5. 已经有 etcd 了，为什么还会选 Consul？反过来呢？</summary>

两者共识层都是 Raft，差别在"面向的对象"：Consul 面向服务发现——DNS 接口（存量应用零改造）、多数据中心 WAN gossip、健康检查内建、KV 只是附带；etcd 面向"某系统的唯一真相存储"——watch+MVCC revision 的可靠事件流（K8s list-watch 的地基），没有 DNS/健康检查。选型句式：**要"让别的系统找到服务"选 Consul，要"给某个系统当一致性的元数据底座"选 etcd**；在 K8s 里这两件事都被内置方案（Service/DNS + etcd）覆盖了，所以新引入任何一个都要先回答"为什么不用平台原生能力"（06 章第 2 节）。
</details>

## 延伸阅读

- Consul 架构指南（gossip/Raft 双平面的官方说明）：https://developer.hashicorp.com/consul/docs/architecture
- Agent HTTP API（服务与检查注册，含 catalog 不执行 check 的说明）：https://developer.hashicorp.com/consul/api-docs/agent
- Catalog HTTP API（静态健康记录的边界原文）：https://developer.hashicorp.com/consul/api-docs/catalog
- Consul DNS 接口（端口 8600、`<service>.service.consul`、TTL 与过滤参数）：https://developer.hashicorp.com/consul/docs/discovery/dns
- SWIM 论文（Consul 成员机制的源头）：https://www.cs.cornell.edu/~asdas/research/dsn02-SWIM.pdf
