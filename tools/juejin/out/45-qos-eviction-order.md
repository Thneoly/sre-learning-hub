---
title_juejin: 节点内存一紧张，K8s 先杀谁？这份死亡名单是你自己写的
title_zhihu: 节点内存吃紧 K8s 先杀谁：不是随机的，是你写的 requests 决定的
description: QoS 判定规则、oom_score_adj、驱逐排序、软硬阈值与宽限期、drain 与驱逐对照、OOMKilled 与 Evicted 判别、分层配 QoS，节点内存吃紧先杀谁。
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686346277555683378"
---

# 节点内存一紧张，K8s 先杀谁？这份死亡名单是你自己写的

凌晨两点，node-3 内存告警。五分钟后三个 Pod 变成 Evicted，删掉重建，业务恢复，收工。第二周同一台节点又死一批——这次名单里有你的核心服务。

为什么死的是它，不是隔壁吃着 2Gi 内存的日志采集器？这不是玄学：**驱逐名单是按你写的 requests 排出来的。**没写 requests 的 Pod，等于亲手把自己排到名单最前面。

这篇讲透：QoS 判定、驱逐排序、软硬阈值、两种死法的验尸，外加分层配置策略。

## 一、QoS 是算出来的，不是你声明的

QoS 没有"设置"入口：它是 apiserver 按 Pod 内**每个容器**的资源字段推导的，写在 `status.qosClass`，逐容器检查、全部满足才作数：

| QoS | 判定规则 | oom_score_adj | 被杀顺序 |
| --- | --- | --- | --- |
| Guaranteed | 每个容器同时设置 cpu 与 memory，且 requests == limits（只写 limits 也算） | -997 | 最后 |
| Burstable | 至少一个容器写了 requests 或 limits，但不满足 Guaranteed | 2~999 | 中间 |
| BestEffort | 所有容器完全没写 requests/limits | 1000 | 最先 |

三个高频误判全出在"相等"上：

- 只写 limits 不是 Burstable：apiserver 把缺的 requests 补成与 limits 相等，实为 Guaranteed
- 反向不补：写了 requests、没写 limits，还是 Burstable
- 一票否决：主容器配得再完美，sidecar 裸奔，整个 Pod 照样掉级（逐容器判定）

三十秒验证三类：

```bash
kubectl run qos-g --image=busybox:1.36 --restart=Never \
  --limits=cpu=200m,memory=128Mi -- sleep 3600
kubectl run qos-b --image=busybox:1.36 --restart=Never \
  --requests=cpu=100m -- sleep 3600
kubectl run qos-e --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl get pods qos-g qos-b qos-e -o custom-columns='POD:.metadata.name,QOS:.status.qosClass'
# 预期输出：
#   qos-g  Guaranteed
#   qos-b  Burstable
#   qos-e  BestEffort
kubectl exec qos-e -- cat /proc/self/oom_score_adj   # 预期输出：1000
kubectl exec qos-g -- cat /proc/self/oom_score_adj   # 预期输出：-997
```

oom_score_adj 是内核 OOM killer 的打分，越大越先死：-997 几乎免疫，1000 是靶心。

**QoS 写在资源字段里，不在注释、命名或你的自我感觉里。**

## 二、驱逐排序：先死的是超额最多的

节点内存触线，kubelet 的排序算法一句话：**先杀超额最多的，同级再比优先级与总体用量。**

BestEffort 的 requests 是 0，全部用量都算超额——它"首当其冲"不是等级歧视，是数学上必然全额超标。

构造典型案例：一台节点内存告急，三个候选。

- A：BestEffort，实际用 500Mi，超额 500Mi
- B：Burstable，requests 100Mi，实际用 600Mi，超额 500Mi（600 - 100）
- C：Guaranteed，1Gi/1Gi，用满 1Gi，超额 0

A 与 B 打平，比优先级与总体用量：A 的 requests 为 0、通常没配优先级，先死。C 超额为 0，再叠加 -997 的打分，最后才被动到。

把 B 的用量改成 700Mi，它就死在 A 前面——驱逐不是按等级清场，超额量才是排序键。

两条纪律：requests 贴真实用量，虚低则超额被放大、排名前移——requests 写 100Mi、实际跑 600Mi 的核心服务，在名单里就是个准 BestEffort；不写资源的 Pod 则在替全节点挡枪，死得最早。

**驱逐只牺牲超额部分，requests 是保底配额。**

## 三、软阈值给体面，硬阈值保性命

默认硬阈值（可配置）。nodefs 是 kubelet 根文件系统，imagefs 是镜像与容器层盘：

| 信号 | 默认阈值 |
| --- | --- |
| memory.available | < 100Mi |
| nodefs.available | < 10%（inodesFree < 5%） |
| imagefs.available | < 15%（inodesFree < 5%） |

软硬分工看 KubeletConfiguration 片段（/var/lib/kubelet/config.yaml，供比对，别乱改）：

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
evictionHard:
  memory.available: "100Mi"       # 硬阈值：触线即杀
evictionSoft:
  memory.available: "500Mi"       # 软阈值：更早触发，但等宽限期
evictionSoftGracePeriod:
  memory.available: "1m30s"       # 宽限期：期内回升就不驱逐，超期仍触线才动手
evictionMaxPodGracePeriod: 30     # 驱逐时优雅退出的上限
```

可用内存往下掉，先跌破 500Mi（软），后跌破 100Mi（硬）。软阈值反而更早介入——还有余量时从容挑目标、给宽限期走优雅退出；硬阈值触线立刻动手，再等就是内核全局 OOM，kubelet 要抢在系统失控前自保【从业者判断：设计意图归纳】。

默认只配硬阈值；**补软阈值的意义，是把"半夜硬杀"换成"提前从容赶走"**【从业者判断】。

## 四、两套驱逐：kubelet 自保，drain 拆迁

"Pod 被赶走"有两套机制，排障第一步是分清谁动的手：

| 维度 | 节点压力驱逐 | API 驱逐（drain） |
| --- | --- | --- |
| 发起者 | kubelet，节点本地决策 | kubectl drain，走 eviction API |
| 触发 | 资源触线，自动 | 人工或运维流程 |
| PDB | 不查，自保等不了仲裁【从业者判断】 | 尊重，受 PDB 约束 |
| 现场 | 节点 MemoryPressure/DiskPressure | 维护窗口，先 cordon 再 drain |

再补一个易混概念：调度失败是 scheduler 放不下、Pod 卡 Pending，事件 FailedScheduling——连节点都没上，与驱逐无关。

drain 是计划内拆迁，PDB 保副本底线，可重试可取消；kubelet 驱逐是应激反射，前提是"不杀你们，全家一起死"。别指望 PDB 在节点压力下救你——它管得住运维的手，管不住 kubelet 的刀【从业者判断】。

**drain 是谈判，节点压力驱逐是自卫，规则完全两套。**

## 五、OOMKilled 与 Evicted：两种死法的验尸报告

容器内存篇（另篇）拆过 137：那是容器撞了自己的 cgroup memory.max。视角抬到节点层，死因多出一类——节点内存耗尽，内核全局 OOM 或 kubelet 驱逐出手，事件里是 SystemOOM 或 Evicted。

一句话分诊：**前者看 limits，后者看节点驱逐阈值。**

| 死法 | 层面 | 铁证 | 根因方向 |
| --- | --- | --- | --- |
| OOMKilled | 容器 | Reason: OOMKilled, Exit Code 137 | limits 太低或泄漏 |
| Evicted | 节点 | STATUS=Evicted 加驱逐事件 | 节点超卖或同居者泄漏 |
| SystemOOM | 内核 | 系统级 OOM 事件 | kubelet 没来得及，内核先动手 |

验尸命令：

```bash
# 容器层：看 Last State 与退出码
kubectl describe pod <pod> | grep -A4 'Last State'
# 预期输出（容器超限）：
#   Last State:  Terminated
#     Reason:    OOMKilled
#     Exit Code: 137
# 节点层：看驱逐与 OOM 事件
kubectl get events --sort-by=.lastTimestamp | grep -iE 'evict|oom'
```

一个高频误诊点：137 不一定是自己 limits 太低——节点内存压力连坐时，容器同样可能被 OOMKilled。判别靠曲线，对照 working_set 与 limit 的比值：长期高于 0.9 是 limits 太低；曲线不高但节点 MemoryPressure 为 True，是节点的事，调自己 limits 治不了。

**OOMKilled 是私事，Evicted 是连坐。**

## 六、磁盘压力走同一套逻辑

驱逐信号表里有四个是磁盘：nodefs 与 imagefs 的空间和 inode。它最迷惑人的形态是"内存明明够，Pod 却 Evicted、节点 NotReady 一阵又自己恢复"——常见根因是 nodefs 触线，比如日志落盘失控、emptyDir 滥用、镜像堆积【从业者判断：诱因归纳】。

排查同内存：describe node 看条件与事件，清镜像、查泄漏。

kubelet 对 imagefs 压力还有一层缓冲：先做镜像垃圾回收腾空间，不够才升级到驱逐 Pod——"节点开始清镜像"就是磁盘驱逐的前兆，imagefs.available 跌破 20% 就该清理，别等 15% 的阈值线【从业者判断】。

**imagefs 压力先吃镜像、后动 Pod；nodefs 压力则直接对 Pod 开刀。**

## 七、反方：全配 Guaranteed 是用密度换心安

既然 Guaranteed 最后死，全配不就高枕无忧？代价藏在调度器：调度只看 Σrequests，而 Guaranteed 要求 requests == limits，等于按所有人的峰值记账。

对照超卖基准：CPU 的 Σrequests 与物理容量常规配比 1:1 到 1.5，limits 可放到 3~10 倍；全部 Guaranteed 后这份空间归零，节点密度大跌、成本直线上涨【从业者判断】。内存本就建议 Σrequests 不超物理容量（最多 1.1~1.2 倍），内存侧损失小，CPU 侧是真金白银。

正确姿势是按业务分层。

- 核心在线：Guaranteed，或 requests/limits 比不低于 0.8，值得免死金牌
- 一般在线：Burstable，requests 贴平时用量，limits 给峰值余量
- 批处理/离线：低 priority 加低 requests，被抢占被驱逐都不心疼（配合 PriorityClass）
- 开发测试：LimitRange 兜底防裸奔，defaultRequest 与 default 不等，落在 Burstable，不当靶心

**requests 是账本和名次，limits 是红线。**Burstable 不是"配置不认真"，而是"节点困难时我让出超额部分"的契约——超卖能成立，靠的正是这份契约。

## 排障对照表

| 症状 | 定性 | 动作 |
| --- | --- | --- |
| Pod Evicted，节点 NotReady 后恢复 | 触及 evictionHard，常见 nodefs/内存 | describe node 看条件与事件，清镜像查泄漏 |
| 关键服务内存紧张时先死 | requests 虚低或没写，超额量排前 | requests 贴真实用量或 Guaranteed |
| exit 137 | 撞自己 limits；节点有 MemoryPressure 则是连坐 | 对照 working_set 与 limit 曲线 |

## 现在就能做的事

第一件，扫全集群 QoS 分布，数数 BestEffort 都是谁：

```bash
kubectl get pods -A -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,QOS:.status.qosClass' | head -20
```

第二件，给 BestEffort 名单逐个补资源字段，或交给 LimitRange 兜底。第三件，看一眼 /var/lib/kubelet/config.yaml 的 eviction 配置——大概率只有硬阈值，要不要补软阈值，值得一次评审。

30 秒自检三问：核心服务的 requests 离真实用量差多远？有没有 Pod 在裸奔？驱逐阈值留没留软阈值宽限？

评论区聊两件事：你遇过的 Evicted 事故，根因是内存还是磁盘；你们集群 Guaranteed 与 Burstable 的比例，敢不敢晒一晒。

这些内容整理在我维护的学习仓库，GitHub 搜 sre-learning-hub：资源与 QoS 一章是底稿，三 Pod 推演、oom_score_adj 验证、LimitRange 实验的完整命令都在里面。觉得有用点个 star。
