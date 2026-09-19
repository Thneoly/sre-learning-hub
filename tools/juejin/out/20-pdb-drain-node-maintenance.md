---
title_juejin: drain 卡了 40 分钟：PDB 才是节点维护的主语
title_zhihu: drain 卡了 40 分钟：PDB 才是节点维护的主语
description: drain 卡住多因 PDB 在拦。自愿与非自愿中断的分界、Eviction API 与 DELETE 的区别、minAvailable 二选一、排障四步与节点维护标准清单，一篇讲透。
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686346277555683378"
---

# kubectl drain 卡住的那晚：拦住它的不是 bug，是一道数学题

> 节点维护与中断预算｜K8s 深入理解

晚上十一点，内核补丁的维护窗口，`kubectl drain worker1` 敲下去。终端每隔几秒刷一行 error，重试、再重试——40 分钟过去，一个 Pod 都没走成。

你盯着 `Cannot evict pod as it would violate the pod's disruption budget`，第一反应是集群出 bug。不是。那晚我搞明白的是：节点维护的真正主语不是节点，也不是 drain，而是一本叫 PodDisruptionBudget 的账。

## 一、先分锅：drain 卡住，嫌疑人只有四个

drain 的本质是"逐个 evict，遇到保护对象就停"。卡住只有四种，报错各有文案：

| 报错关键词 | 原因 | 解法 |
| --- | --- | --- |
| cannot delete DaemonSet-managed Pods | DS Pod 绑死本节点，赶走没意义 | 补 `--ignore-daemonsets` |
| cannot delete Pods with local storage | emptyDir 数据随 Pod 消亡 | 确认可丢后补 `--delete-emptydir-data` |
| cannot delete Pods (with no controller) | 裸 Pod 无控制器、删了不复活 | 补 `--force`（慎用：等于人工兜底删除） |
| Cannot evict ... disruption budget | PDB 预算耗尽 | 默认不放行——这是设计；确需强推用 `--disable-eviction` 退回普通 DELETE 绕过 PDB，效果等同砸锁，仅在能承受中断时使用 |

前三个是"你没给授权"，参数一加就走；第四个没有安全的放行参数——`--disable-eviction` 能绕，但那已经不是受 PDB 保护的 drain。前三种是流程问题，第四种是数学问题。

定位三连，跑完就能对号入座：

```bash
kubectl get pdb -A                                  # 有没有 PDB 卡着
kubectl get pod -A -o wide | grep worker1           # 剩下的是不是 DS/裸 Pod
kubectl describe node worker1 | grep -A3 Taints     # 确认 cordon 产生的污点还在
```

## 二、PDB 管哪类中断：自愿与非自愿的分界线

K8s 把 Pod 中断正式分成两类，PDB 只管其中一类：

| 类型 | 谁发起 | 例子 | PDB 管不管 |
| --- | --- | --- | --- |
| 非自愿 involuntary | 不可抗力或节点自保 | 宿主机硬件故障、内核 panic、节点失联、节点压力驱逐 | 管不了，但会占用预算 |
| 自愿 voluntary | 人或自动化主动发起 | drain 做维护/升级、集群缩容腾挪 | 管其中走 Eviction API 的部分 |

直觉记法：硬件挂掉是灾难，计划内下线是决策。PDB 管不了灾难，节点资源压力该驱逐还是驱逐；它管的是决策——别让你亲手把可用副本摁到红线以下。

所以 PDB 的本体很"轻"：不创建任何东西、不参与调度，只是一本"同一组 Pod 同时自愿下线数量"的账，被 Eviction API 放行驱逐前查询；副本基数由控制器的 `spec.replicas` 经 ownerReferences 反查得到。

## 三、Eviction API 与 DELETE：一字之差，隔着一道闸

drain 删 Pod 走的不是普通 DELETE，而是 eviction 子资源——一次"受 PDB 约束的 DELETE"。apiserver 只有三种回应：

| apiserver 回应 | 含义 | drain 的反应 |
| --- | --- | --- |
| 200 | 放行（无 PDB 或预算充足） | 删除该 Pod，继续下一个 |
| 429 Too Many Requests | 会打破 PDB | 每隔约 5 秒重试，直到预算恢复或超时 |
| 500 | 配置错误 | 最典型：两个 PDB 的 selector 圈中了同一个 Pod |

裸 `kubectl delete pod` 不走这条链路，PDB 拦不住——这是"绕闸"的原理，也是危险所在：drain 的全部保护在这一刻失效。

还有两个"不保护"边界，排障前先自查：

- 滚动升级不受 PDB 约束——升级造成的不健康副本只是计入预算，拦不住升级本身；
- 非自愿中断防不住——PDB 的职责只是别让自愿中断雪上加霜。

## 四、minAvailable 与 maxUnavailable：二选一，选哪个是学问

PDB 的 YAML 短得可怜：

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: web-pdb
spec:
  minAvailable: 2           # 也可写 "50%"
  selector:
    matchLabels:
      app: web              # 与控制器 selector 一致
```

两个语义相反的字段**只能设一个**，同时写会被 apiserver 直接拒绝：

| 字段 | 语义 | 3 副本时 | 适用场景 |
| --- | --- | --- | --- |
| minAvailable: 2 | 驱逐后"存活数"下限 | 最多赶 1 个 | 关心绝对可用数的核心服务 |
| maxUnavailable: 1 | 驱逐后"下线数"上限 | 最多赶 1 个 | replicas 常变（HPA），不用跟着改 PDB |

百分比取整是面试级细节：`minAvailable: "50%"` 向上取整的是"必须存活数"（7 副本 → 留 4）；`maxUnavailable: "30%"` 向上取整的是"允许下线数"（7 副本 → 赶 3）——实际不可用比例可能略超百分比。

两个坑直接点名：

- 单副本应用配 `minAvailable: 1` 数学无解：允许下线数永远为 0，任何 drain 都被卡死，要么加副本要么调 PDB；
- policy/v1 下空 selector 的 PDB 匹配 namespace 全部 Pod（v1beta1 是 0 个）——别裸提交空 selector，等于给整个命名空间上锁。

## 五、那晚的排障路径：从 429 到 ALLOWED DISRUPTIONS

回到开头，drain 卡住时的真实输出：

```text
error when evicting pods/"web-5d8f9c7b4a-abcde" -n "default" (will retry after 5s):
Cannot evict pod as it would violate the pod's disruption budget.
```

先说反直觉的结论：**"drain 卡住"多数时候不是故障，而是 PDB 在等别处副本恢复健康**——重建副本 Ready 后预算自动回来。你要判断的是"等得起吗"和"预算为什么是 0"。

四步排障路径：

1. `kubectl get pdb web-pdb` 看 `ALLOWED DISRUPTIONS`。为 0 就查预算被谁占——Pending/未 Ready 的副本同样占预算，别只数 Running；
2. 预算数学上就是 0（单副本 + minAvailable: 1）→ 加副本或调 PDB，没有第三条路；
3. 报 500 → 找 selector 重叠的 PDB：两个都圈中同一个 Pod 时 apiserver 直接报错；
4. 确属紧急 → 裸 `kubectl delete pod` 绕闸，后果自己评估；或 `kubectl drain worker1 --disable-eviction --ignore-daemonsets --delete-emptydir-data --force` 一把梭（危险，已绕过 PDB 保护）。

前两条是治病，第四条是砸锁。

3 分钟复现现场（worker1 换成真实节点名）：

```bash
# 单副本服务 + "一个都不许少"的 PDB
kubectl create deployment solo --image=nginx:1.27 --replicas=1
kubectl apply -f - <<'EOF'
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: solo-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: solo
EOF
kubectl get pdb solo-pdb
# MIN AVAILABLE 1, ALLOWED DISRUPTIONS 0 —— 没有任何余量

kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data --timeout=30s
# error when evicting pods/"solo-xxxxxxx-xxxxx" (will retry after 5s):
# Cannot evict pod as it would violate the pod's disruption budget.

# 松绑后重跑（模拟加了副本/调了 PDB），立刻完成
kubectl patch pdb solo-pdb --type=merge -p '{"spec":{"minAvailable":0}}'
kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data --timeout=120s
kubectl uncordon worker1 && kubectl delete deployment solo && kubectl delete pdb solo-pdb
```

看到 ALLOWED DISRUPTIONS 从 0 变 1、drain 秒过，这道数学题你就解过了。

## 六、标准动作清单：cordon → drain → 升级 → uncordon

三条命令的边界先划清：

| 命令 | 做什么 | 不做什么 | 撤销 |
| --- | --- | --- | --- |
| cordon | 置 SchedulingDisabled，新 Pod 不进来 | 不驱逐存量 Pod | uncordon |
| drain | = cordon + 逐 Pod evict | 不处理 DS/emptyDir/裸 Pod（默认报错） | uncordon（副本自动回来） |
| uncordon | 恢复调度 | 不主动搬回任何 Pod | — |

生产维护窗口的完整序列，建议原样进 runbook：

```bash
# [master] 0. 基线快照，便于回归比对
kubectl get pods -A -o wide | grep worker1

# [master] 1. 驱逐并封锁（三个放行参数按需叠加）
kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data

# [master] 2. 确认终态：Ready,SchedulingDisabled，只剩 DS/静态 Pod
kubectl get node worker1
kubectl get pods -A -o wide | grep worker1

# [worker1] 3. 维护动作（内核/kubelet 升级、换盘，示例重启 kubelet）
sudo systemctl daemon-reload && sudo systemctl restart kubelet

# [master] 4. 恢复调度并回归
kubectl uncordon worker1
kubectl get nodes                                # 回到 Ready，无 SchedulingDisabled
kubectl get pods -A -o wide | grep -c worker1    # 副本陆续回流
```

四个实战细节：

- 顺序不能反：drain 内部自带 cordon，先保证"删一个不会被调度回本节点"，再动手；
- drain 中途失败，已驱逐的不会回滚，重跑安全，带正确参数再跑即可；
- uncordon 后负载不会立刻回来——它只恢复"可调度"，靠新副本和滚动更新逐步回归，急着验证可 `rollout restart`；
- 集群只有这一个 worker 时别 drain：驱逐的 Pod 无处可去、全部 Pending（有 PDB 直接卡死），先扩节点或临时去掉 master 的 control-plane 污点。

## 七、反方观点：「我们裸 delete pod，也没出过事」

一定有人这么说，而且多半是真的：小集群、低频维护、单人操作时，PDB 几乎感知不到——你脑子里那份"先看别的节点副本健康没有"的清单，就是人肉 PDB。

PDB 的账本压在"同时"二字上。单台维护出不了事，并发才出事：20 台节点滚动升级、自动化并发 drain、维护窗口撞上另一场变更——没人肉清单兜底。【从业者判断】我的底线是：有多副本控制器的服务，PDB 跟着 Deployment 一起提交——成本是维护时多等几分钟，收益是把"计划内下线的并发上限"写进集群，而非写进每个人的记忆。

## 现在就能做的事

两档任选：

- 零门槛档：跑 `kubectl get pdb -A`，看有没有 `ALLOWED DISRUPTIONS` 为 0 的行——有，它就是下次维护卡你 40 分钟的嫌疑人；
- 动手档：把第五节的 3 分钟复现跑一遍，被 PDB 拦一次、松绑再过一次，比读十篇文档都牢。

30 秒自检三问：核心服务有 PDB 吗？用的是 minAvailable 还是 maxUnavailable？有没有单副本应用配着 minAvailable: 1？

评论区聊两件事：一，你被 drain 卡住最长的一次是多久，最后是等好的还是砸锁砸开的；二，你们的 PDB 是跟着应用仓库走，还是平台统一下发。这些内容整理在我维护的学习仓库，GitHub 搜 sre-learning-hub：调度与节点维护两章是底稿，还有配套的 kubeadm 升级 drain lab。觉得有用点个 star。
