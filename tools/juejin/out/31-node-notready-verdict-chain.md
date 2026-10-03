---
title_juejin: '节点 NotReady 是判出来的，不是崩出来的：340 秒'
title_zhihu: '节点 NotReady 是判出来的，不是崩出来的：340 秒'
description: 'kubelet 心跳与 Lease 租约、40 秒 NotReady 判定、NoExecute 污点与 tolerationSeconds 300 秒驱逐时间线、根因分诊树与修复清单，一篇讲透。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686346277555683378"
---

# 节点上什么都没崩，Pod 却被删了：NotReady 是一纸判决，不是事故现场

> 节点失联判定与驱逐｜K8s 深入理解

凌晨两点，告警群炸了：worker1 NotReady。你 SSH 上去——kubelet 在跑，containerd 在跑，容器一个个活得好好的。节点上什么都没崩。

但在 apiserver 眼里，这台机器已经失联五分多钟，上面的 Pod 正被逐个删除、在别的节点重建。上一篇我们把 drain 卡住的锅甩给了 PDB，这一篇讲另一条没人申请就自动发动的驱逐：心跳怎么报、40 秒怎么判、Pod 怎么被删——以及为什么说 NotReady 是"判"出来的，不是"崩"出来的。

## 一、心跳：节点活着的唯一证据

先立一条前提：**控制面从不主动检查节点**。apiserver 只有 exec/logs 这类操作才会主动连节点的 10250 端口，其余时间只等节点上报——控制面没有"探测"能力，只有"数心跳"的能力。

kubelet 定期干两件事：更新 NodeStatus（Ready 等一揽子条件），以及在 kube-node-lease 命名空间续约一个小小的 Lease 对象。

为什么搞两个通道？【从业者判断】老机制的心跳就是更新 NodeStatus 本体——它带着 capacity、conditions、地址、镜像一整坨，几千节点按秒级上报，etcd 的写入直接被打爆。Lease 只有几个字段、续约近乎免费，心跳于是搬进小对象，NodeStatus 降频为条件变化时才报。

kube-system 里的 Lease 还顺便给 controller-manager、scheduler 选主，一处机制两处复用。这笔账和控制器读本地缓存是同一个思路：高频路径必须便宜，贵的数据低频走。

**心跳从"交体检报告"变成"签到"，让"活着"说得足够便宜。**

眼见为实：

```bash
# 每个节点一条 Lease
kubectl -n kube-node-lease get lease
# NAME      HOLDER     AGE
# worker1   worker1    30d

# 看心跳本体：隔几秒再跑一次，renewTime 一直在往前跳
kubectl -n kube-node-lease get lease worker1 -o yaml | grep -E 'renewTime|holderIdentity'
# holderIdentity: worker1
# renewTime:      "2026-10-02T18:00:05.000000Z"
```

renewTime 的跳动，就是节点在控制面眼里的生命体征。

## 二、40 秒判决：判的是失联，不是宕机

心跳断了谁来判？不是 apiserver，是 controller-manager 里的 node-lifecycle 控制器——几十个控制循环中专管节点生死的那一个。判据一条：超过 node-monitor-grace-period（默认 40 秒）没收到心跳。

判决内容两件事：Node 的 Ready 条件翻转（get nodes 里的 NotReady 就是外显），同时打上 NoExecute 污点——心跳断时 Ready 翻为 Unknown，污点是 node.kubernetes.io/unreachable；节点自己显式上报 NotReady（Ready=False）时才是 node.kubernetes.io/not-ready。之后，驱逐逻辑介入。

三个推论，个个反直觉。

**判的是失联，不是宕机——整条链上没人看过节点一眼。** 40 秒里没有任何组件真正检查过节点。网络分区时节点和容器全都健康，照样被判 NotReady、照样被驱逐，依据只有"你没说话"。

第二，kubelet 死了不等于容器死了。【从业者判断】kubelet 挂掉时 containerd 还在，容器继续跑——驱逐删掉的只是 API 里的 Pod 对象，失联节点上的旧容器收不到终止指令，要等节点恢复才被真正清理。节点 NotReady 和服务恢复之间，隔着一整条判决链。

第三，判决会误伤：网络抖 40 秒就足以触发一次。【从业者判断】grace-period 调小恢复快但误判多，调大则相反——默认 40 秒是官方拍的板。

判决书写在 Node 对象上，四条命令看到全文：

```bash
kubectl get nodes
# NAME      STATUS     ROLES    AGE   VERSION
# worker1   NotReady   <none>   30d   v1.31.1

# 判决书：心跳停在哪一刻
kubectl describe node worker1 | grep -A5 Conditions
#   Ready   Unknown/False   LastHeartbeatTime: 停在几分钟前

# 污点是执行机关
kubectl describe node worker1 | grep -A3 Taints
#   node.kubernetes.io/unreachable:NoExecute ...
#   （心跳断 → Ready=Unknown，对应 unreachable 污点；
#    节点显式上报 NotReady 时，才是 not-ready）

# 排除干扰项：维护后忘了解封
kubectl get node worker1
# NotReady,SchedulingDisabled = 有人 cordon/drain 过没恢复，uncordon 即可
```

## 三、时间线推演：从最后一次心跳到最后一个 Pod 被删

设 T0 为最后一次成功的 Lease 续约，此后心跳中断：

```text
T0         最后一次心跳成功（kubelet 卡死 / 网络中断）

T0+40s     node-monitor-grace-period 耗尽
           → node-lifecycle 判 NotReady、打污点
           → 调度器不再往这台节点放任何新 Pod

T0+40s     NoExecute 污点生效，多数 Pod 带着默认注入的
           容忍：tolerationSeconds=300，倒计时开始

T0+340s    容忍到期，驱逐逻辑开始删 Pod
           → 控制器在健康节点重建副本

T0+340s+   每个 Pod 再走自己的终止宽限期，流量切到新副本
```

关键数字就是 340 = 40 + 300：40 秒是控制面的耐心，300 秒是 Pod 的缓冲。

300 秒不是你配置的，是 apiserver 的准入控制（DefaultTolerationSeconds 插件）在 Pod 创建时自动注入的——只要没自己写这条容忍，就默认带上 not-ready 和 unreachable 两条 NoExecute 容忍、各 300 秒：

```bash
kubectl run demo --image=nginx:1.27 --restart=Never
kubectl get pod demo -o jsonpath='{.spec.tolerations}' | tr ',' '\n'
#  {"key":"node.kubernetes.io/not-ready"
#   "effect":"NoExecute"
#   "tolerationSeconds":300}
#  {"key":"node.kubernetes.io/unreachable"
#   "effect":"NoExecute"
#   "tolerationSeconds":300}
kubectl delete pod demo
```

你没写过的容忍，是准入控制替你写的——300 秒就是这么来的。

两个直接结论。

第一，算 SLA 按 340 秒起步：单节点故障，副本从"消失"到"别处 Ready"至少 5 分 40 秒，还要加每个 Pod 的终止宽限期。多副本的恢复预期按这个数算，别按"马上切走"的直觉算。复盘时它也是最有说服力的证据链：告警时间、污点出现时间、Pod 删除时间，三个点连起来就是判决全程。

第二，**失联驱逐 PDB 拦不住，唯一缓冲是那 300 秒**。上一篇讲过 PDB 只管自愿中断——节点失联属于非自愿中断，驱逐不等预算、直接执行。想给关键服务更长缓冲，显式写一条：

```yaml
tolerations:
- key: node.kubernetes.io/unreachable
  effect: NoExecute
  tolerationSeconds: 3600   # 给慢启动的有状态服务留一小时
```

【从业者判断】代价：缓冲越长，真故障时流量切得越慢；但节点若只是网络分区，长容忍能避免无谓搬家——赌的是"多数失联是网络，不是机器"。

## 四、根因分诊树：五个嫌疑人，一人一条命令

判决链解释"谁删了你的 Pod"，不解释"心跳为什么停"。分诊管后者，入口就一问：

```text
Q: 节点纯 NotReady（无 SchedulingDisabled）→ SSH 上去
   第一问：kubelet 活着吗？
 ├─ systemctl status kubelet → inactive/dead
 │    └─ journalctl -u kubelet 查退出原因：
 │         ├─ 检测到 swap → swapoff -a（fstab 没注释净，重启又犯）
 │         └─ x509 报错   → 证书过期，跳嫌疑人四
 ├─ kubelet active，日志刷 pleg is not healthy
 │    └─ 查运行时：sudo timeout 5 crictl ps
 │         ├─ 5 秒不返回 → containerd 卡死（多半是磁盘 IO）
 │         └─ containerd inactive → start 并设自启
 └─ kubelet active，日志干净
      └─ 下沉系统层：df -h / free -h / dmesg
           └─ 磁盘打满（日志/镜像/emptyDir）既是独立根因也是 PLEG 诱因
```

五个嫌疑人过堂：

| 嫌疑人 | 第一条命令 | 特征现场 | 修复 |
| --- | --- | --- | --- |
| kubelet 挂/被停 | `systemctl status kubelet` | inactive；日志见检测到 swap | `systemctl enable --now kubelet`；`swapoff -a` |
| containerd 挂/卡 | `sudo timeout 5 crictl ps` | crictl 不返回；或 inactive | `systemctl restart containerd`，查磁盘 IO |
| 磁盘压力 | `df -h` | 分区 100%，日志/镜像堆积 | 清日志与悬空镜像，扩盘 |
| 证书过期 | `sudo kubeadm certs check-expiration` | journalctl 刷 x509: certificate has expired | `sudo kubeadm certs renew all` 后重启组件 |
| PLEG not healthy | `journalctl -u kubelet \| grep 'pleg'` | 每秒的容器全量 list 超时 | 治 containerd 和磁盘，别查网络 |

重点说第五个，它最迷惑人。kubelet 不收运行时的事件推送，而是每秒全量 list 一次容器状态、跟上次对比，自己生成"谁启动了、谁退出了"——这就是 PLEG。containerd 一卡顿，relist 就超时，日志开始刷 pleg is not healthy，节点随之 NotReady。

所以 **PLEG 报的病，根子多半在 containerd**——先查运行时，别查网络。五秒定罪：`sudo timeout 5 crictl ps`，五秒不返回，运行时罪名坐实。

【从业者判断】证书和 swap 各提醒一句：kubeadm 证书默认一年，过期是周期性事故，把到期日上日历；节点重启后 fstab 里的 swap 复活、kubelet 检测到直接退出，是"重启后莫名 NotReady"的头号解释。

## 五、和 drain 对照：一个是判决，一个是搬家申请

同样是"节点上的 Pod 被搬走"，drain 和这条链性质完全不同：

| | 被动判定链（本文） | drain 主动维护 |
| --- | --- | --- |
| 发起者 | node-lifecycle 控制器 | 人 |
| 触发条件 | 40 秒没心跳 | 你敲 kubectl drain |
| 是否等 PDB | 不等，非自愿中断拦不住 | 等，Eviction API 预算不足就卡住重试 |
| 时间线 | 40+300 秒，默认值说了算 | 你说了算 |

**drain 是搬家申请，NotReady 是缺席判决。** drain 内部自带 cordon，先保证"删一个不会被调度回本节点"再动手；判决链的对应动作是污点，调度器自动绕开。上一篇 drain 卡 40 分钟，是 PDB 在替你把关；这一篇的驱逐 PDB 拦不住——集群已认定节点没了，预算让位于自愈。两条路合起来，才是节点上 Pod 离开的完整地图。

还要会认混合态：NotReady,SchedulingDisabled = 判决链和维护链撞在同一台节点。先修 NotReady（走第四节），再 uncordon，顺序别反。

## 六、修复动作清单

```bash
# [master] 1. 先看判决书：心跳停在哪一刻、污点是什么
kubectl describe node worker1 | grep -A5 Conditions
kubectl describe node worker1 | grep -A3 Taints

# [worker1] 2. 修根因（对照第四节），两个服务一起看
sudo systemctl status kubelet containerd --no-pager

# [master] 3. 心跳恢复后 Ready 自动翻转——这条链不需要 uncordon
kubectl get node worker1
# STATUS 回到 Ready；被驱逐的副本早被控制器重建，无需搬回

# [master] 4. 只有出现过 SchedulingDisabled 才需要解封
kubectl uncordon worker1

# [master] 5. 回归验证：副本分布与服务健康
kubectl get pods -A -o wide | grep worker1
```

三个容易翻车的收尾细节：

- 修完仍 NotReady，回第四节换嫌疑人，kubelet 和 containerd 都要查；
- 证书续期后组件不自动换证，控制面静态 Pod 要重启才生效；
- 被驱逐的副本不用手动搬回，uncordon 只恢复调度——回流靠滚动更新，急验证可 rollout restart。

**修复的终点不是节点 Ready，是服务在别处恢复接客。**

## 现在就能做的事

- 零门槛档：跑 `kubectl -n kube-node-lease get lease` 看心跳；再挑个 Pod 看 tolerations，找到那条你没写过的 tolerationSeconds: 300；
- 动手档：可糟蹋的节点上 `sudo systemctl stop kubelet`，掐表看三件事——约 40 秒时 Conditions 变化、污点出现、约 340 秒时 Pod 被删，然后 start 复原。六分钟，比读十篇文档都牢。

30 秒自检三问：核心服务的 tolerationSeconds 是多少？上次 NotReady 你 SSH 下去的第一条命令是什么？节点证书下次到期是哪天？

评论区聊两件事：一，你见过最冤的一次 NotReady——节点明明没坏，凶手最后是谁；二，默认 300 秒你们动过吗，调大还是调小。

这些内容整理在我维护的学习仓库，GitHub 搜 sre-learning-hub：架构与节点维护两章是底稿，scripts/faults 里还有 break-kubelet 故障注入脚本，可以在测试集群亲手复现这条 340 秒链路。觉得有用点个 star。
