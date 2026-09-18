---
title_juejin: kubectl scale ds 是个 404：DaemonSet 没有 replicas
title_zhihu: kubectl scale ds 是个 404：DaemonSet 没有 replicas
description: kubectl scale ds是404——DaemonSet没有replicas子资源。CNI故障注入脚本因此整个重写为nodeSelector+移走配置的真实机制。
category_id: "6809637769959178254"
tags: "Kubernetes,安全"
column_id: "7686472562230312970"
---

> 说明：本文不涉及 Strimzi——发布标题保留系列编号、slug 已定不再改，内容是 DaemonSet 缩容 404 这条线。

给故障演练靶场写"CNI 整体下线"故障，我第一反应是副本数清零：`kubectl scale ds calico-node -n kube-system --replicas=0`。

回车下去，API server 回了个 404。不是没权限——虽然我第一反应就是去查了半天 RBAC，纯属冤案——也不是参数错，是你要操作的东西在 API 层面压根不存在。

于是注入脚本推倒重写。更坑的是重写到一半才发现：只删 agent，集群看起来一切正常，数据面其实已经瘫了。这三层坑，一层层讲。

## 一、事故现场：一条看起来天经地义的命令

靶场要模拟 Calico 全线宕机，学员只看告警现象练排障。对 Deployment 来说，"下线"就是一行：

```bash
kubectl scale deployment coredns -n kube-system --replicas=0
```

于是对 DaemonSet 如法炮制：

```bash
kubectl scale daemonset calico-node -n kube-system --replicas=0
```

返回长这样（kubectl 版本不同文案略有差异，以官方文档为准）：

```text
Error from server (NotFound): the server could not find the requested resource
```

404。品一下分量：

**不是"你不能这么做"，而是"你要的东西不存在"。**

一个是"不许"，一个是"没有"——开头那半天的 RBAC 排查，就是把"没有"当"不许"查了。

## 二、为什么是 404：scale 是个"子资源"

先补一句背景：`kubectl scale` 并不是直接改 `spec.replicas` 的魔法，它走 **scale 子资源**——对 `/scale` 路径的一次 GET + PUT。

Deployment、StatefulSet、ReplicaSet 都注册了它，DaemonSet 没注册，路径本身就是死的：

```bash
# deployment：返回 kind: Scale 的 JSON，子资源存在
kubectl get --raw "/apis/apps/v1/namespaces/kube-system/deployments/coredns/scale"

# daemonset：404（kube-proxy 几乎每个 kubeadm 集群都有）
kubectl get --raw "/apis/apps/v1/namespaces/kube-system/daemonsets/kube-proxy/scale"
```

字段层面同样看得见——DS 的 spec 里没有 replicas：

```bash
kubectl explain deployment.spec | grep -i replicas   # 有输出
kubectl explain daemonset.spec | grep -i replicas || echo "DS 没有 replicas 字段"
```

为什么不给 DS 做 replicas？因为两类控制器的语义不同：

| 控制器 | 副本数从哪来 | 运维动作 |
|---|---|---|
| Deployment / StatefulSet | spec 里写死的 N | 改数字 |
| DaemonSet | 控制器**算出来**的：匹配节点数 | 改"匹配条件" |

DS 的语义是"该跑的节点每个跑一个"。

**副本数是导数——改不了结果，只能改条件。**

所以"DS 缩容到 0"翻译过来就是：**让它匹配不到任何节点**。

## 三、重写后的注入方式：nodeSelector 塞一个不存在的标签

思路：往 Pod 模板塞一个集群里没有任何节点会有的标签，匹配节点数从 N 变 0。

```bash
kubectl patch daemonset calico-node -n kube-system \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"fault-cni-disabled":"true"}}}}}'
```

两个细节值得停一下。

**1. strategic merge patch 对 map 是合并不是覆盖。** 原有的 nodeSelector（如 `kubernetes.io/os: linux`）被保留，只是多了个坏键。最小 diff，恢复时只删这一个键。

**2. 效果不是"停了"而是"清场"。** DS 控制器发现没有节点匹配，会主动删光所有 agent Pod。

```bash
kubectl rollout status daemonset/calico-node -n kube-system --timeout=120s
kubectl get daemonset -A | grep calico    # DESIRED / CURRENT 掉到 0
```

为什么不用 `kubectl delete ds`？对象一删，恢复就得整份重建。我的铁律是**最小可逆**：改一个键进来，删一个键就能回去。当然，坚持删了再整份 apply 回来的 GitOps 流派也有他们的道理——你们会怎么选，为什么？

顺带一个生产推论：摘某个节点的 DS agent，靠的也是标签和污点——DS Pod 默认容忍 unschedulable 等污点，`kubectl cordon` 根本赶不走它；想单独摘一个节点，得加一个它不容忍的自定义污点。这个坑下一篇单拆。

## 四、只杀 agent 还不够：/etc/cni/net.d 也要搬走

重写到这，agent 这半边算落定了——但真正值得单开一节的，是另一半：`/etc/cni/net.d` 也要搬走。

只删 agent Pod、不动 `/etc/cni/net.d` 的话，故障是"静默半瘫"形态：

- 节点**不会** NotReady：kubelet 的就绪检查只看 net.d 里有没有配置
- 新 Pod 甚至能正常拿 IP、正常 Running
- 但 Felix 不在，路由和策略没人接管，Pod IP 互访逐步不通

看起来一切都好，其实数据面已经瘫了。这种形态排障难度最高，作为入门训练又太阴。

所以脚本加了第二步：把 net.d 也搬走，凑出教科书式的显性故障。

| 维度 | 只删 agent（形态 A） | agent + net.d 都下线（形态 B，本脚本） |
|---|---|---|
| 节点状态 | Ready | 约 1 分钟变 NotReady |
| 新建 Pod | 能 Running | Pending / 卡 ContainerCreating |
| Pod 互访 | 逐步不通 | 拿不到新 IP |
| 排障难度 | 要 ping 打点才暴露 | 经典症状，适合训练 |

搬家命令（原样出自重写后的脚本）：

```bash
sudo mkdir -p /tmp/fault-backup-cni/net.d
sudo chmod 700 /tmp/fault-backup-cni
sudo find /etc/cni/net.d -maxdepth 1 -type f ! -name '.*' \
  -exec mv -t /tmp/fault-backup-cni/net.d/ {} +
```

注意**顺序是硬约束**：必须先让 agent 死透再搬——install-cni 是 init 容器，只在 Pod 启动时跑一次，并不会周期性重跑；但只要 agent 仍匹配存活，任何一次 Pod 重启（容器崩溃、节点重启、DS 重建）都会在 init 阶段重跑它，把刚搬走的配置写回，当场翻盘注入。先杀 agent 再搬，消除的就是这个竞态。

小设计：文件搬到 `/tmp/fault-backup-cni/`（权限 700）而非删除；备份目录已存在就拒绝重注入，保证幂等。

## 五、学员看到什么：故障长什么样

注入完成后，学员拿到的是一份纯现象清单：

| 现象 | 背后机制 |
|---|---|
| 节点约 1 分钟变 NotReady | NetworkReady=false（kubelet 日志里对应 NetworkPluginNotReady） |
| 新 Pod 一直 Pending | NotReady 连带污点，FailedScheduling |
| 已调度 Pod 卡 ContainerCreating | 建沙箱时找不到 CNI 配置 |
| calico-node Pod 全部消失 | DS 匹配不到节点，控制器清场 |
| 老 Pod 约 5 分钟内还在跑 | veth 设备还在，没人回收；not-ready 污点是 NoExecute，默认 tolerationSeconds=300 到期后被逐出——回光返照 |

describe node 的 Conditions（节选）：

```text
Ready   False   KubeletNotReady   container runtime network not ready:
                                   NetworkReady=false:
                                   no network config file in "/etc/cni/net.d"
```

而 `NetworkPluginNotReady` / `cni plugin not initialized` 这类字样不会出现在 describe node 的 Conditions 里——它们是 kubelet 日志的格式，要去节点上翻服务日志：

```bash
journalctl -u kubelet | grep -E 'NetworkPluginNotReady|cni plugin not initialized'
```

排障三连，第一跳就该指向 CNI：

```bash
kubectl describe node | grep -A6 Conditions          # Ready=False + NetworkReady=false 在这
kubectl get daemonset -A | grep -E 'calico|flannel'  # DESIRED=0，选择器被动过
kubectl get pods -A | grep calico                    # 一个 agent 都没有
```

第二步其实就破案了：DS 的 DESIRED 变 0，无非 nodeSelector/节点标签变了、加了不可容忍的污点、或 nodeAffinity 不匹配几种可能。镜像拉不下来则是另一种症状——DESIRED 不变、AVAILABLE 掉 0、Pod 卡 ImagePullBackOff，别混进这个排查方向。

## 六、恢复：null 值删键的冷门技巧

恢复是注入的镜像：net.d 搬回去，坏键删掉。删键用的是 strategic merge patch 的冷门语义：

**键的值置为 null，等于删除这个键**，且不碰同一 map 里的其他键：

```bash
kubectl patch daemonset calico-node -n kube-system \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"fault-cni-disabled":null}}}}}'
```

net.d 搬回原位（calico-node 回来后会自动重写配置，搬回去是为了不等它）：

```bash
sudo mv /tmp/fault-backup-cni/net.d/* /etc/cni/net.d/
```

验证三件套，缺一不可——"看起来好了"不算好：

```bash
NS=$(kubectl get ds -l k8s-app=calico-node -A -o jsonpath='{.items[0].metadata.namespace}')
kubectl -n ${NS} get pods -o wide | grep calico-node  # 每个节点一个 Running
kubectl get nodes                                    # 全部回 Ready
kubectl run net-test --image=busybox:1.36 -it --rm \
  --restart=Never -- wget -qO- -T 3 http://1.1.1.1   # Pod 出网正常
```

一个细节：Calico 不一定在 kube-system，operator 装的在 calico-system。本文前面的命令按 kubeadm 默认写死 kube-system，照抄前先 `kubectl get ds -A` 对一下；验证块开头那条 `NS=` 就是把这一步固化成命令——按标签动态取它所在 namespace，别写死。

## 七、这个 404 教会我的三件事

**1. kubectl 的很多命令是"子资源糖"。** scale、log、exec 都是对应服务端子资源路径的糖（`/scale`、`pods/log`、`pods/exec`）；`/status` 则是给控制器写状态用的子资源，kubectl 没有为它做专用命令，读写要靠 `--subresource=status` 标志（1.24+）。类型没注册对应的子资源，命令就是 404。

遇到"命令对 B 资源不好使"，先想想是不是拿 A 的套路在套 B。

**2. DS 没有副本数，只有覆盖范围。** 它的伸缩单位是"节点选择条件"。HPA 也因此拿 DS 没办法——没有 scale 子资源可以读写（HPA 靠 GET/PUT `/scale` 调整副本数），DS 压根没注册这个接口。

**3. 注入脚本的安全设计比故障本身重要。** 备份原值、幂等、最小 diff、一键兜底。

这次把"缩容"换成"改标签 + 搬目录"，看着绕，但每步都可逆、可验证。

## 写在最后：30 秒验证

不用等写故障脚本，花 30 秒在任意集群验证今天的主角：

```bash
kubectl explain daemonset.spec | grep -i replicas || echo "DS 没有 replicas 字段"
kubectl get --raw "/apis/apps/v1/namespaces/kube-system/daemonsets/kube-proxy/scale" \
  || echo "scale 子资源不存在，这就是那个 404"
```

把第二条里的 `daemonsets/kube-proxy` 换成 `deployments/coredns`，还能看到成功返回长什么样。一败一成，比看十篇文章记得牢。

这套脚本来自我维护的学习靶场 [github.com/Thneoly/sre-learning-hub](https://github.com/Thneoly/sre-learning-hub)：`scripts/faults/` 下十几个 break-*.sh 全带"备份 + 一键恢复"，配套手册有决策表和计分标准，可自行取用练手。

留个话头：你有没有拿 A 资源的套路套过 B 资源，炸出过什么离谱报错？评论区对个暗号。

觉得这类拆解有用，点个收藏。下一篇拆今天埋的那个坑：cordon 为什么赶不走 DS Pod——摘单个节点 agent 的正确姿势。
