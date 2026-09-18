---
title_juejin: etcd 不只是数据库：K8s 控制面的命脉
title_zhihu: etcd 不只是数据库：K8s 控制面的命脉
description: etcd与K8s控制面的关系：RAFT多数派与集群可用性、list-watch数据源、备份恢复全流程、为什么3节点只能容1故障。
category_id: "6809637769959178254"
tags: "Kubernetes,后端"
column_id: "7686346277555683378"
---

# 凌晨两点，K8s 集群脑死亡——etcd 挂 1 台没事，挂 2 台全完

凌晨两点，3 台 master 的集群宕了 1 台，告警响了，读写看起来一切正常——顶多读延迟有点毛刺，你翻个身继续睡。半小时后第 2 台也倒了：`kubectl create` 全部超时，Pod 不再调度，节点加入不了，整个集群"脑死亡"——业务容器还在跑，但控制面已经没了。

为什么 3 台只容 1 台？为什么第 2 台倒下后重启也救不回来？出事那天你唯一能靠的是什么？答案都在 etcd 的多数派数学里。

## 一、先纠正一个认知：etcd 不是"K8s 的数据库"

很多人把 etcd 理解成"K8s 的 MySQL"，存 Pod、Service 这些对象。不能说错，但严重低估了它的地位。更准确的说法是：**etcd 是整个集群的唯一事实来源（Single Source of Truth）**。

在 K8s 里，只有 apiserver 有权读写 etcd。kubectl、scheduler、controller-manager、kubelet，全是 apiserver 的客户端。你以为的"查一下 Pod 状态"，链路其实是这样：

```text
kubectl get pods
   └─► kube-apiserver（认证、鉴权、准入）
          └─► etcd（唯一的持久化存储）
```

这带来一个冷酷的推论：**etcd 不可用 = 整个控制面不可用**。apiserver 启动时连不上 etcd 会直接崩溃重启，控制器停摆，新调度停止。worker 上的存量 Pod 还在跑，但集群已经"失忆 + 失能"。

所以 etcd 的可用性，就是 K8s 控制面的可用性。而它的可用性，由 RAFT 多数派决定。

etcd 里没有表，每条 key 就是一个对象的序列化数据，前缀按资源类型组织：`/registry/pods/<ns>/<name>`、`/registry/services/<ns>/<name>`。这也解释了官方为什么建议单 key 控制在 100KB 级以内——一个大对象，apiserver 序列化和 etcd 存储两边一起遭殃。想亲眼看一眼这些 key 的话，第五节备了一条只读命令。

## 二、RAFT 写路径：一次 kubectl apply 的旅程

etcd 用 RAFT 协议在多个成员之间复制数据。看懂一次写入，多数派就懂了。以 3 成员为例：

```text
a ──PUT /registry/pods/default/x──► 任意成员
       │  非 leader 收到 → 转发给 leader
       ▼
L ① 本地 WAL 追加（先落盘，未提交）
      │ ② 并行 AppendEntries ──► F1、F2 各自落盘 WAL
      ▼ ③ 多数派（⌊3/2⌋+1=2，含 leader 自己）确认
L ④ commit → apply 到 MVCC 存储（全局 revision +1）
      │ ⑤ 应答客户端；follower 随后 apply 追上
      ▼
客户端拿到成功 = 该写已持久化到多数成员
```

三个关键词展开说说：

- **WAL 先行**：写入先追加预写日志并 fsync 落盘，然后才发给 follower。这就是官方强烈建议 etcd 独占一块低延迟 SSD/NVMe 的原因——fsync 慢，整个集群的写吞吐跟着慢。
- **多数派确认**：leader 自己算一票。3 节点凑满 2 票即可提交，不用等最慢的那个。
- **成功即持久**：客户端拿到成功，数据就已落在多数成员的磁盘上。这个语义是下面一切容错分析的基础。

还有一个反直觉的结论：**决定写延迟的不是最快的节点，是多数派里最慢的那个**。leader 要凑票，3 节点里必须有 2 个确认才算数。如果一个 follower 磁盘老化，fsync 从 2ms 涨到 50ms，整个集群的写延迟就跟着涨。

所以 etcd 成员的硬件要同构，别拿一台老机器凑数——它一个人就能拖慢所有人。

## 三、多数派数学：为什么 3 节点只能容 1 台故障

quorum 公式一句话：`N 个成员，提交需要 ⌊N/2⌋+1 票`。逐个算给你看：

| 集群规模 | 提交票数 | 可容忍故障 | 点评 |
| --- | --- | --- | --- |
| 1 | 1 | 0 | kubeadm 默认单机 etcd，磁盘坏 = 全没 |
| 2 | 2 | 0 | 最坑拓扑，白白多一台却不容错 |
| 3 | 2 | **1** | 生产最小 HA 单元 |
| 4 | 3 | 1 | 比 3 多一台，容错没变，写还更慢 |
| 5 | 3 | 2 | 大集群常见选择 |

回到开头那一幕：3 节点挂到第 2 台时，活着的 1 票 < 需要的 2 票。既无法提交任何写入，也无法选出 leader，etcd 整体失权，apiserver 跟着瘫。业务 Pod 没死，但没人再回答"这个集群里有什么"。

**为什么是多数，而不是全部？** 两个原因：

1. **容错**：允许少数成员失联，写入不阻塞，等它们回来追日志即可；
2. **防脑裂**：网络分区把集群切成两半时，最多一边拥有多数派，另一边自动失权。两边同时是"多数"在数学上不可能——这就是旧数据永远不会覆盖新数据的保证。

举个具体的例子：网络把集群分区成 3+3（6 成员），两边各只有 3 票，都凑不够 4 票，于是都停止写入。宁可整体不可用，也不让两边各自接写造成数据分叉——这就是 CAP 里选 CP 的活教材。

顺带回答一个高频问题：**4 节点为什么不如 5 节点？** 票数涨到 3，容错却还是 1 台，纯粹的浪费。奇数成员是铁律，要么 3 要么 5，别选偶数。

冷知识：**单成员 etcd 里 RAFT 依然有意义**。WAL 先落盘、quorum=1 自己确认即提交、每个写照样拿全局单调的 revision。失去的只是容错，不是一致性。但磁盘一坏数据全失——所以单 master 集群更要勤做快照。

**顺带说一句：stacked 还是 external。**kubeadm 部署 HA 集群时默认是 stacked etcd——每台 master 上跑一个 etcd 成员，和 apiserver 同宿主。优点是省机器、开箱即用；代价是 etcd 与 apiserver 抢 CPU 和磁盘，而且"master 宕 = etcd 成员宕"，故障域绑在一起。

另一种是 external etcd：etcd 独立成集群，master 上只跑 apiserver。资源隔离更干净，但你得多养一套三节点集群。多数团队选 stacked，那就更要记住一句话：**master 的磁盘和网络，就是 etcd 的命**——别在上面跑别的 IO 大户。

## 四、读路径与 list-watch：K8s 的心跳从哪来

etcd 有两种读法，区别直接影响你观察到的行为：

| 读法 | 过程 | 特点 |
| --- | --- | --- |
| 串行读 serializable | 直接读本成员 KV | 快，可能读到旧值 |
| 线性读 linearizable | 先经 ReadIndex 与多数派确认"我还是 leader"，再返回 | 强一致，多一次往返，**默认** |

线性读是默认值。这也解释了一个现象：偶尔挂掉一个 follower，读延迟会出现毛刺——因为每次读都要多数派点头。

**list-watch 的数据源也在这里。** etcd 是 MVCC 多版本存储，每次修改全局 revision +1，旧版本保留一段时间供追赶。K8s 对象的 resourceVersion，本质就是 etcd 的 revision。所有组件的套路是统一的：

```text
1. LIST 全量：拿到当前所有对象 + 各自的 resourceVersion
2. WATCH 增量：从该 revision 起订阅变更事件流
3. 事件驱动：controller-manager / scheduler / kubelet 的
   informer 据此维护本地缓存，之后几乎不再全量拉取
```

这套机制的代价是：**历史 revision 要留给 watch 追赶，磁盘只增不减**。组件断线重连后要从老 revision 追，追不上（已被压缩）就收到 `410 Gone`，退回全量 LIST。这就引出日常运维里最容易被忽视的两个动作——compact 和 defrag。

再注意一个细节：**这些组件谁都不直连 etcd**。list-watch 的对象是 apiserver，由 apiserver 统一 watch etcd，再扇出给所有客户端。这个设计把 etcd 保护得很好——不管集群里有多少 controller、多少 kubelet，etcd 承受的连接数都是可控的。

代价则由 apiserver 扛：每个对象的每次变更，都要推给所有订阅它的 informer。这就是为什么大集群要给 apiserver 留足 watch-cache 内存，也是为什么一个疯狂 LIST 全命名空间的脚本能把控制面打挂。

## 五、日常运维三件事：健康、空间、告警

kubeadm 的 etcd 监听 127.0.0.1:2379，证书在 Pod 里。先包一个函数（仅当前 shell 有效，本文后面都用它）：

```bash
ectl() {
  kubectl -n kube-system exec etcd-"$(hostname)" -- sh -c \
    "ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
--endpoints=https://127.0.0.1:2379 $*"
}
```

第一节欠你的那条命令现在兑现——看看 etcd 里到底存了什么（生产环境只读别写，演示集群随便玩）：

```bash
ectl get / --prefix --keys-only --limit=5
```

例行三查，建议进巡检脚本：

```bash
ectl endpoint status -w table   # DB SIZE / RAFT INDEX / IS LEADER——谁是 leader，只有这里看得到
ectl endpoint health            # 应输出 is healthy: successfully committed proposal
ectl member list -w table       # 成员列表与成员状态（输出不含 leader 信息，别找错地方）
```

**空间回收，顺序不能反。** compact 是"记账"——声明某 revision 之前的历史不再需要（不可逆，之后再读更老的 revision 会拿 `410`）；defrag 是"还钱"——把已死版本占的空洞真正归还给文件系统。

```bash
# 压缩到当前 revision（保留现值，历史全部可回收）
REV=$(ectl endpoint status -w json | grep -o '"revision":[0-9]*' | head -1 | grep -o '[0-9]*')
ectl compact "$REV"

# 碎片整理：多成员集群务必逐个 endpoint 做，避免同时 defrag 引起抖动
ectl defrag

# 复核 DB SIZE 是否下降
ectl endpoint status -w table
```

只 compact 不 defrag，磁盘占用不降；只 defrag 不 compact，没空洞可收，等于白干。先记账，后还钱。

不过日常生产，优先让 etcd 自己压：启动参数配上 `--auto-compaction-retention`（如 `1h` 到 `5h`）周期压缩，给 watch 留出追赶窗口——这才是官方推荐的常规做法。上面这种手动 compact 到当前 revision 属于"激进回收"：全部历史一刀清掉，任何正要重连或落后的 informer 都会收到 `410` 退回全量 LIST，生产集群上可能引起一波 apiserver/etcd 压力。真要手动做，要么 compact 到 `REV-N` 留个追赶窗口，要么做完盯着 informer 的 re-list。

**别忘了配额。** etcd backend 默认配额约 2GB（以官方文档为准），超限触发 `alarm NOSPACE`，etcd 直接转只读。标准的翻车剧本是这样的：半夜你先被拉进故障群——"发布失败了""kubectl 超时""Pod 建不出来"；然后所有人开始查 K8s：apiserver 日志翻一遍、controller 看一圈、网络也没问题，就是没人想到去问一个"数据库"的磁盘配额。因为表象确实是 apiserver 拒绝一切写入，第一反应都以为是 K8s 的 bug。处理套路：

```bash
ectl alarm list                 # 确认 NOSPACE
# ...先 compact + defrag 回收空间...
ectl alarm disarm               # 解除告警，恢复读写
```

长期巡检的话，重点盯三样东西：

- **DB SIZE**：持续上涨是常态，逼近配额就该安排 compact + defrag；
- **WAL fsync 延迟**：它直接决定写吞吐，磁盘抖动最先在这里暴露（对应 etcd 的 `etcd_disk_wal_fsync_duration_seconds` 指标）；
- **leader 变更次数**：频繁切主说明网络或磁盘有问题，别等真挂了才看。

## 六、备份：先解决薛定谔的问题

回到开头那个凌晨——第 2 台倒下之后，快照是唯一还来得及起作用的牌；但牌要提前备好，出事当天是来不及的。快照是 etcd 灾备的唯一正解，而**没验证过、没恢复过的备份是薛定谔的备份**：不打开盒子，你永远不知道它能不能救命。这一节先做一份、验一份，把恢复演练留给第七节。

快照是在线操作：etcdctl 连上 2379，走 mTLS 认证，流出一份一致性视图。动手前两个前提先说清：

- **为什么不能复用第五节的 ectl 包装**——exec 进容器执行的话，快照文件会留在容器文件系统里取不出来，所以要直接在宿主机跑；
- **宿主机默认没有 etcdctl**（kubeadm 只以静态 Pod 方式跑 etcd），先 `sudo apt-get install -y etcd-client`；不想装的话，参照第五节 exec 进 Pod 执行，save 之后用 `kubectl cp` 把文件拷出来。

完整命令（master 宿主机执行）：

```bash
sudo mkdir -p /opt/etcd-backup

sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/etcd-backup/etcd-snapshot-$(date +%Y%m%d-%H%M).db
```

参数依据一张表说清：

| 参数 | 取值依据 |
| --- | --- |
| `ETCDCTL_API=3` | 永远显式设置；旧版 etcdctl 不设会落到 v2，snapshot 子命令直接不存在 |
| `--endpoints` | stacked etcd 固定本机 2379；2380 是 peer 端口，别写混 |
| `--cacert` | etcd 用独立 CA，不是集群根 CA 的 `pki/ca.crt` |
| `--cert` / `--key` | server 证书对兼作本机 client 证书；更规范可用 apiserver-etcd-client 对 |

**备了必须验，否则等于没备**（`snapshot status` 只接受单个文件，多份快照并存时别直接写通配符——会展开成多个参数报错，所以这里取最新一份）：

```bash
sudo ETCDCTL_API=3 etcdctl snapshot status \
  "$(ls -t /opt/etcd-backup/*.db | head -1)" --write-out=table
# 输出 HASH / REVISION / TOTAL KEYS / TOTAL SIZE
# TOTAL KEYS 为 0 或文件只有几 KB = 快照是坏的，重做
```

再配一个定时快照。命令拆成"脚本 + 一行 crontab"两段，免得挤成三百字符的一长条（手机上复制必断）：

```bash
sudo tee /usr/local/bin/etcd-snapshot.sh <<'EOF'
#!/bin/sh
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/etcd-backup/etcd-snapshot-$(date +%Y%m%d-%H%M).db \
  && find /opt/etcd-backup -name '*.db' -mtime +7 -delete
EOF
sudo chmod +x /usr/local/bin/etcd-snapshot.sh
echo '0 3 * * * root /usr/local/bin/etcd-snapshot.sh' | sudo tee /etc/cron.d/etcd-snapshot
```

命名和手工快照是同一套（`etcd-snapshot-<时间戳>.db`），上面那条验证命令对手工和定时的产物都生效。

两个提醒：快照务必**异地存放**——本机磁盘和 etcd 一起阵亡的场景下，**快照放同一块盘就是陪葬**；升级、改 manifest 等高危操作前，也先手动拍一份。

还有一点容易被忽略：快照是某一时刻的**一致性全量视图**，里面是全部对象——包括所有 Secret 和 ConfigMap。所以快照文件本身要当敏感数据对待，目录权限收紧、传输通道加密，别随手扔到共享存储上。

## 七、恢复：从快照救回集群

再回一次那个凌晨：多数派已经找不回来，重启无效——能救集群的就只剩这一节了。先记住一句话：**恢复 = 文件级重建 + 让 etcd 改读新目录**。apiserver 只是被动地跟着重连。单 master 全流程四步：

```text
┌──────────────┐   ┌────────────────────┐   ┌─────────────────────────┐
│ 1. 验快照可用 │──►│ 2. restore 到新目录 │──►│ 3. 改 etcd.yaml 两处     │
│ snapshot ... │   │ --data-dir=...     │   │ kubelet 自动重建 etcd    │
└──────────────┘   └────────────────────┘   └───────────┬─────────────┘
                                              4. 验证：kubectl get nodes
```

**第一步：验快照。** 对应图里的第 1 格。先用第六节的 `snapshot status` 确认 HASH / REVISION / TOTAL KEYS 正常，再动手——别把坏快照 restore 进去，等集群起不来才发现，那才是雪上加霜。

**第二步：restore 到新目录。** 它只操作文件、不连任何 etcd 进程，所以不需要 endpoints/cacert 那套参数。目标目录必须为空或不存在：

```bash
sudo ls -lh /opt/etcd-backup/    # 先看清楚要用的快照文件名
SNAP=/opt/etcd-backup/etcd-snapshot-20260917-0300.db   # ← 换成你上面确认的那份

sudo rm -rf /var/lib/etcd-restore

sudo ETCDCTL_API=3 etcdctl \
  --data-dir=/var/lib/etcd-restore \
  snapshot restore "$SNAP"

sudo ls -R /var/lib/etcd-restore | head   # 应出现 member/snap 子目录
```

**第三步：改静态 Pod。** etcd 是静态 Pod，改 manifest 即生效。两处必须一起改，少一处恢复就不生效：

```yaml
# /etc/kubernetes/manifests/etcd.yaml（节选，只列改动行）
spec:
  containers:
  - command:
    - etcd
    - --data-dir=/var/lib/etcd-restore   # 改动1：command 里的 data-dir
    volumeMounts:
    - mountPath: /var/lib/etcd-restore   # 改动2a：挂载点跟随
      name: etcd-data
  volumes:
  - hostPath:
      path: /var/lib/etcd-restore        # 改动2b：hostPath 指向新目录
      type: DirectoryOrCreate
    name: etcd-data
```

保存后 kubelet 检测到 manifest 变化，自动重建 etcd 容器，无需手动重启：

```bash
watch crictl ps --name etcd      # 新容器 Running、旧容器 Exited
kubectl -n kube-system get pod | grep etcd
kubectl get nodes                # 数据应回到快照时间点
```

**第四步：验证。** 快照之后创建的对象应消失，写入应正常：

```bash
kubectl create cm restore-check --from-literal=t=$(date +%s)
kubectl get cm restore-check -o yaml | grep t:

# 确认稳定后，旧目录留档再清理
sudo mv /var/lib/etcd /var/lib/etcd.bak.$(date +%s)
```

**3 节点集群的恢复原则**：只在其中一个成员上 restore（此时要额外给 `--name`、`--initial-cluster`、`--initial-advertise-peer-urls` 描述拓扑），其余成员清空数据目录后重新加入，由恢复节点同步数据。

千万别在每个成员上独立 restore——会得到三份 cluster ID 各不相同的数据目录，RAFT 身份对不上，根本组不成一个集群。多成员细节以 etcd 官方 disaster recovery 文档为准。

最后啰嗦一句，把第六节开头那句话补完：**没恢复过的备份是薛定谔的备份**——演练过一次，盒子才算真正打开。建议每季度找个变更窗口，在演练集群上完整走一遍恢复流程，把命令变成肌肉记忆——真出事的那天，你没时间翻文档。

## 八、踩坑速查表

这张表建议直接截图收藏，出事时按症状对号入座：

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| defrag 完 DB SIZE 没变 | 只 compact 没 defrag，或顺序反了 | 先记账后还钱，复核 endpoint status |
| etcd 只读，日志见 `alarm NOSPACE` | 配额（默认约 2GB）打满 | 回收空间后 `alarm disarm` |
| snapshot 报子命令不存在 | 没设 `ETCDCTL_API=3`，落到 v2 API | 命令前显式加前缀 |
| 连 2379 报 `x509: certificate signed by unknown authority` | cacert 误用了集群根 CA（`pki/ca.crt`） | 改用 `pki/etcd/ca.crt` |
| 连 2379 报 `certificate is valid for X, not Y` | endpoints 写了不在 server 证书 SAN 里的地址 | 改回 `https://127.0.0.1:2379`，或给证书补 SAN |
| 恢复后数据没变 | 只改了 data-dir 没改 hostPath（或反之） | etcd.yaml 两处一起改 |
| 恢复后 apiserver CrashLoop | etcd 起慢了，或 manifest 改坏了 | `crictl logs` 分别看 etcd / apiserver |
| 4 节点集群挂 2 台全瘫 | 偶数成员浪费容错 | 永远用奇数：3 或 5 |
| 3 节点挂 2 台后拼命重启 | 多数派已失，重启救不了 | 修复故障成员找齐多数派，或走快照恢复 |

## 写在最后

etcd 在 K8s 里从来不是"一个附件数据库"，它是控制面的心脏：RAFT 多数派决定它的可用性，MVCC revision 撑起整个 list-watch 生态，快照是它唯一的后悔药。

多数派的数学很冷酷——3 节点就是只能挂 1 台，第 2 台倒下的那一刻，集群就进入倒计时。但这个数学也很慷慨：**一份异地存放、验证过的快照，能把最坏情况从"数据全失"拉回"只损失快照之后的增量"**。

现在就能做的一件事——登录你的 master，跑下面几条，看看自己处在哪个世界（ectl 的定义在第五节，这里再给一份自包含版，已定义过可跳过第一行）：

```bash
ectl() {
  kubectl -n kube-system exec etcd-"$(hostname)" -- sh -c \
    "ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
--endpoints=https://127.0.0.1:2379 $*"
}
ectl endpoint health
ectl endpoint status -w table
sudo ls -lh /opt/etcd-backup/ 2>/dev/null || echo "还没有备份目录，今天就是补上的日子"
```

如果最后一行输出让你冒了冷汗，把第六节那套快照脚本配上，今晚就能睡踏实。

**全文金句，截图带走**：

- 多数派数学：N 个成员，提交需要 ⌊N/2⌋+1 票——3 节点就是只能挂 1 台；
- 先记账后还钱：compact 是记账，defrag 是还钱，顺序反了等于白干；
- 快照放同一块盘，就是陪葬；
- 没恢复过的备份，是薛定谔的备份；
- etcd 不可用 = 控制面"失忆 + 失能"，存量 Pod 再热闹也只是余温。

这些内容整理自我在维护的开源学习库 [sre-learning-hub](https://github.com/Thneoly/sre-learning-hub)：labs/13 是配套的 etcd 快照恢复 lab，可以在练习集群上把"备份 → 误删 → 恢复"完整跑一遍；labs/20 则是综合故障演练 lab，拿来检验整门课的成色正好。如果这篇帮到了你，掘金这边点个赞、点个收藏，就是最实际的支持；仓库 star 随缘，练完 lab 再点也不迟。

最后留个互动：上面最后一条命令的输出，敢跑的评论区晒一下；再报个数——你的 etcd 几个成员、备份几分频？有没有被哪个疯狂 LIST 的脚本打挂过控制面？评论区交代一下，让我看看有多少集群正在裸奔。
