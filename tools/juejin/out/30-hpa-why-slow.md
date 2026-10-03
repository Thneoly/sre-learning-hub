---
title_juejin: HPA 为什么总是慢半拍：10% 死区与 300 秒冷静期
title_zhihu: HPA 慢半拍不是 bug：扩容快、缩容慢，都是故意的
description: HPA 扩容公式、10% 容差死区、指标链路延迟、缩容稳定窗口 300 秒、Pod 预热反压、假 HPA 反模式与 QoS、requests 联动，一篇讲透弹性伸缩的节奏问题。
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686346277555683378"
---

# CPU 冲到 80%，HPA 还在看表：慢半拍不是 bug，是四段防抖

> 弹性伸缩的节奏｜K8s 深入理解

下午四点活动开闸，CPU 曲线一根直线拉起来。你开着 `kubectl get hpa web -w`：TARGETS 从 30% 爬到 80%，REPLICAS 还是 4。四十多秒后它终于动了一波；活动结束流量归零，副本又原样挂满五分钟才开始缩。

你撂下一句：这 HPA，永远慢半拍。慢是真的，但这半拍是四段延迟的叠加：公式里的死区、指标链路的滞后、新副本的反压、缩容的稳定窗口。**HPA 的每一段"慢"，都是防抖设计，不是性能缺陷。**

## 一、扩容公式与 10% 死区：不是"超标就扩"

核心算法一行写完：

```text
期望副本 desiredReplicas = ceil( 当前副本 × 当前指标值 / 期望指标值 )
(带 10% 容差: 容差内不动, 防抖; 指标缺失/为 0 时不缩)
```

4 副本、CPU 77%、目标 60%：4 × 77 / 60 = 5.13，向上取整 6。真正构成第一段延迟的是旁边的小字：**偏离不超过 10%（tolerance），这一轮直接跳过。**

60% 的目标，死区约在 54% 到 66%——TARGETS 显示 64%/60% 不扩是正常的，64/60 = 1.07，还在死区内。死区是防抖：没有它，58% 与 62% 之间的抖动会换算成副本数一天几百次的加减。

推论两条：目标值别贴上限——80% 目标的死区上沿 88%，离 limits 红线只剩一步（第六节展开）；10% 是控制器默认容差，为一个服务调全集群的灵敏通常不划算【从业者判断】。

**HPA 的触发条件不是"超标"，是"越出死区"。**

## 二、指标链路：你看到的 64%，是十几秒前的旧闻

Resource 指标（cpu/memory）的链路有四跳：kubelet 的 cAdvisor 采集 → metrics-server 周期抓取聚合 → 聚合 API 暴露 → HPA 控制器重算，控制器每十几秒重算一次并覆盖 spec.replicas。

叠上 metrics-server 的抓取周期与计算窗口，从"CPU 升到 80%"到"HPA 看见 80%"，总滞后在十几到几十秒量级【从业者判断：具体秒数取决于部署参数】。

链路断了，TARGETS 显示 `<unknown>/60%`，三个高频根因：

| 根因 | 验证 |
| --- | --- |
| metrics-server 没装或 CrashLoop | `kubectl -n kube-system get pod -l k8s-app=metrics-server` |
| kubelet 自签证书校验失败（日志 x509） | 补 `--kubelet-insecure-tls` |
| Pod 没写 resources.requests.cpu | 利用率没了分母，查 resources 字段 |

第三条最隐蔽：HPA 的"利用率"是用量比上 requests，**没有 requests，就没有分母。** 另一个冷细节：指标缺失或为 0 时，HPA 不缩容，链路抖一下缩容侧自动刹车，又是防抖。

```bash
kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes
# 有 JSON 输出 = 聚合 API 通；报错 = 链路断
```

**你监控的是现在，HPA 看到的是十几秒前。**

## 三、预热期反压：新副本是成果，也是下一轮的刹车

公式假设副本数与指标线性相关，现实里新副本有一段低利用率的预热期。

两条节奏事实先摆出来：新 Pod 要通过 readiness、待满 minReadySeconds 才算可用；平均利用率是跨 Pod 均摊的。叠起来：【从业者判断】刚 Ready 的副本 JIT、连接池、缓存全是冷态，用量远低于老副本，拉低平均值，下一轮扩容建议随之变小。

扩容越猛，新副本占比越高，稀释越狠——扩容被自己的成果压住，我管这叫新鲜度反压。第一波快、第二三波越来越钝，不是 HPA 倦了，是冷副本在拖分母。

对策三条。一是换指标：CPU 是结果指标，RPS、消息速率、队列深度是原因指标，早半个身位感知流量。

指标源本身就是选型菜单：Resource 走 metrics-server（CPU 利用率）；Pods 走 custom.metrics API（Prometheus Adapter、KEDA，每秒消息数）；External 走 external.metrics API（Kafka lag）。

二是前置扩容：活动前 scale 到预期值预热，流量没来它会在稳定窗口后缩回去，多付的只是几分钟副本钱。三是别给 scaleUp 乱加稳定窗口：默认扩容 0 窗口快速响应，给救火通道装闸门是亲手加延迟。

**新副本既是扩容的产出，也是下一轮扩容的阻力。**

## 四、缩容 300 秒：冷静期是特性，不是 bug

behavior 里最常被当成 bug 的一段。完整可用的 HPA 保存为 web-hpa.yaml：

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: {name: web}
spec:
  scaleTargetRef: {apiVersion: apps/v1, kind: Deployment, name: web}
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource: {name: cpu, target: {type: Utilization, averageUtilization: 60}}
  behavior:
    scaleUp: {stabilizationWindowSeconds: 0, selectPolicy: Max, policies: [
      {type: Percent, value: 100, periodSeconds: 15},   # 每 15s 最多翻倍
      {type: Pods, value: 4, periodSeconds: 15}]}
    scaleDown: {stabilizationWindowSeconds: 300, policies: [   # 缩容冷静 5 分钟
      {type: Percent, value: 25, periodSeconds: 60}]}          # 每 60s 最多缩 25%
```

scaleDown 稳定窗口的语义：回看窗口期内出现过的所有建议值，取副本数**最大**的那个——也就是缩得最少的保守建议。哪怕 5 分钟里指标低了 4 分半、只高了 30 秒，这次缩容也按那 30 秒的高负载建议来，保守到近乎固执。

为什么？缩容的代价不对称——多挂 5 分钟副本损失点资源费；缩猛了流量回升，要重走"指标爬升、越出死区、扩容、预热"全链路，抖回去的成本高一截。对比 scaleUp 的 0 窗口、每 15 秒允许翻倍、双策略取激进——**扩容救火要快，缩容收兵要慢，不对称是故意的。**

HPA 接管 spec.replicas 后，三条铁律：手动 `kubectl scale` 十几秒内被覆盖，别抢方向盘；HPA 与 VPA 同资源同维度会打架；GitOps 下 replicas 要么交给 HPA 全权管理，要么从 Git 移除。

## 五、HPA 之上还有一层：cluster-autoscaler 各慢各的

HPA 扩的是副本，副本要落节点。节点账本满了——调度器只看 Σrequests，不看实时用量——新副本集体 Pending，事件写着 Insufficient cpu。

生产上的常见解法，是在 HPA 之上再配第二层 cluster-autoscaler（下文简称 CA）：**HPA 决定副本数，CA 决定机器数。**

但两层串行，延迟也串行【从业者判断】：HPA 算出副本（十几秒级）→ 新 Pod Pending → CA 判定缺节点、向云厂商开机 → 就绪、调度、预热（分钟级）。突发场景里第二层的分钟级延迟才是天花板，HPA 再灵敏也快不过开一台机器。

配合要点：节点池留余量让第一波扩容落得下去；CA 删节点前要腾 Pod，又回到上一篇 PDB 的账；秒级突发两层都来不及，那是 minReplicas 和入口限流的活【从业者判断】。

**两层弹性各慢各的，总延迟相加而不是取快。**

## 六、假 HPA 与 QoS：min=max 是在骗监控面板

一个流行的反模式：minReplicas 与 maxReplicas 写成同一个数。数学后果是公式输出被夹死在一个值上——HPA 对象存在、状态正常、面板写着"已配置弹性"，却永远不会动作。

**假 HPA 骗的不是调度器，是你的监控面板**：故障时你以为有兜底，兜底从来没缝在身上。要么给真实区间，要么删掉 HPA【从业者判断：反模式定性；夹死由 min=max 夹住公式输出推得】。

QoS 与 HPA 的联动，三件事必须一起想。

分母联动：利用率 = 用量 / requests。requests 虚高，利用率被压低，扩容迟迟不来；虚低则利用率虚高、过度扩容，还叠加驱逐排序"用量超出 requests 最多的先被牺牲"——一个数字写错，两处买单。

红线联动：CPU 触到 limits 先被 CFS 节流（100ms 周期，nr_throttled 计数），HPA 十几秒后才看到利用率。limits 紧，节流尖刺先于扩容到达：用户已经在报慢，HPA 曲线上个周期还是绿的【从业者判断：节流机制是 K8s 通用行为，先后次序是综合推断】。

等级联动：关键服务的合理基准是 Guaranteed 或 requests/limits 比不低于 0.8；requests == limits 时利用率 100% 与节流红线重合，目标值要给死区上沿留余量——60% 目标、上沿 66%，距红线还有 34 个点。

```bash
kubectl exec deploy/web -- cat /sys/fs/cgroup/cpu.stat
# nr_throttled 持续增长 = 节流先于扩容发生了
```

**requests 是 HPA 的分母、驱逐的名次、调度的账本**，一个数字三处生效。

## 七、节奏排障表：把"慢"对号入座

排障第一步是定性：**多数"HPA 慢"最后不是修好的，是想通的。**

| 症状 | 节奏归属 | 定性 |
| --- | --- | --- |
| TARGETS 64%/60%，不动 | 10% 死区 | 正常 |
| 压测停了 5 分钟才缩 | 300s 窗口取最保守建议 | 特性 |
| 第二波扩容明显变钝 | 新副本稀释平均值 | 换原因指标 |
| TARGETS <unknown>/60% | 指标链路断 | 查 metrics-server、证书、requests |
| 扩了但新副本 Pending | 节点层，不归 HPA | 账本满，加节点或等 CA |

三分钟亲手感知节奏。前置一：web Deployment 已配 resources.requests（HPA 的分母）。

前置二：metrics-server——在 GitHub 搜 kubernetes-sigs/metrics-server，按 release 页的 components.yaml 部署，kubeadm 集群补一个参数：

```bash
kubectl patch deployment -n kube-system metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl top nodes    # 能出数即 OK
```

然后压测并掐表：

```bash
kubectl expose deployment web --port=80
kubectl apply -f web-hpa.yaml
kubectl run loadgen --image=busybox:1.36 --rm -it --restart=Never -- \
  sh -c 'for i in 1 2 3 4 5 6 7 8; do (while true; do wget -qO- http://web >/dev/null 2>&1; done) & done; wait'
# 另一终端: kubectl get hpa web -w
# 预期: TARGETS 从 3%/60% 一路上涨, REPLICAS 4→5→…
# Ctrl-C 停止压测后掐表: 缩容要等满 300s 才发生
kubectl delete hpa web && kubectl delete svc web
```

这一趟跑完，死区吞掉的那次扩容、300 秒拦下的那次缩容，你都亲手掐过表——节奏这种东西，读过会忘，掐过表才真信。

## 现在就能做的事

零门槛档：`kubectl get hpa -A` 扫一遍，专找 min 等于 max 的假 HPA 和 TARGETS 带 unknown 的断链路。动手档：第七节实验跑一遍，掐一次 300 秒的表。

30 秒自检三问：目标值的死区上沿离 limits 红线还有多远？缩容窗口是默认 300 还是被人当 bug 调小过？RPS、队列深度这些原因指标备好了吗？

评论区聊两件事：一，你见过最离谱的 HPA 慢半拍事故，最后定位是四段延迟里的哪一段；二，缩容窗口敢不敢用默认 300 秒，调小过吗、后悔过吗。

这些内容整理在我维护的学习仓库，GitHub 搜 sre-learning-hub：工作负载控制器与资源 QoS 两章是底稿，本文的 HPA 完整 YAML 和压测命令都在里面。觉得有用点个 star。
