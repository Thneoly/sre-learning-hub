---
title_juejin: 'kubectl delete --wait=false：打完回执，对象还能活 30 秒'
title_zhihu: '删除不是一步到位：K8s 对象要先领死期，再等签字'
description: 'deletionTimestamp、finalizer 谁加谁摘、级联三模式与孤儿、preStop→SIGTERM→SIGKILL 30 秒时间线、摘流量不对称、卡死处置清单，一篇讲透。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686346277555683378"
---

# kubectl delete --wait=false，回车 0.1 秒就报 deleted，对象真消失要 30 秒：中间 4 道闸门，每道一个放行人

> 删除链路与垃圾回收｜K8s 深入理解

`kubectl delete pod xxx --wait=false` 回车，0.1 秒后终端打出 `pod "xxx" deleted`。多数人以为删除到此为止——这一刻对象还好端端躺在 etcd 里，宽限倒计时才刚开始。（不加 `--wait=false` 时，kubectl 默认会一直等到对象真的消失才打这句回执——正是这条默认等待，把删除的中间过程藏了起来。）

前面把创建拆成 8 步的那篇，结尾说删除全流程在写了，这篇兑现。创建是四个组件接力把你拉起来；删除是四个持有者依次签字放你走。**删除不是一个动作，是一场交接**——卡在哪一环，对象就躺在哪一环。

## 一、delete 只做一件事：贴死期

【从业者判断】DELETE 请求打到 apiserver 后，只要对象带 finalizer，或是个要优雅终止的 Pod，就不会被直接从 etcd 删掉，只在 metadata 里写一个 deletionTimestamp——字面意义的"死期"。对象随之进入 Terminating。

顺带纠偏：Terminating 和 CrashLoopBackOff 一样不是 status.phase，是 kubectl 拼给你看的显示串。

对象真正出 etcd 的条件【从业者判断】：死期已置、finalizers 清空、优雅终止完成，三样齐了才删。造一个能看全过程的样本：

```bash
cat > slowdie.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: slowdie
spec:
  terminationGracePeriodSeconds: 60
  containers:
  - name: main
    image: busybox:1.36
    command: ["sh", "-c", "sleep 3600"]
    lifecycle:
      preStop:
        exec:
          command: ["sleep", "50"]
EOF
# 宽限 60 秒 + preStop 睡 50 秒，留足观察窗口

kubectl apply -f slowdie.yaml
kubectl delete pod slowdie --wait=false
# pod "slowdie" deleted   ← 回执已打，对象还在
kubectl get pod slowdie
# NAME      STATUS        RESTARTS   AGE
# slowdie   Terminating   0          2m
kubectl get pod slowdie -o jsonpath='{.metadata.deletionTimestamp}'; echo
# 2026-10-04T09:00:00Z   ← 死期就写在对象上
```

`--wait=false` 让 kubectl 打完回执就走、不等对象消失。顺带一句：回执打出后你 Ctrl+C，取消的不是删除，只是等待【从业者判断】——意图已经落库，谁都拦不住。

**--wait=false 时，deleted 回显的是意图，不是结果。**

## 二、30 秒时间线：preStop → SIGTERM → SIGKILL

取 T0 为 delete 到达 apiserver 的时刻，Pod 这条链完整展开：

```text
T0        deletionTimestamp 置上 → Terminating
          Endpoints 立刻摘，一秒都不等宽限期
T0 起     preStop 执行（阻塞，占的是宽限预算）
preStop 完 SIGTERM 发给容器 PID 1
T0+30s    还没死 → SIGKILL，没有商量
容器死光 + finalizers 清空 → 对象才从 etcd 消失
```

宽限默认 30 秒，三个容易看漏的点：

preStop 和 SIGTERM 共用同一份预算——preStop 卡死就吃完全部宽限再被 SIGKILL。Pod 卡 Terminating 的三大原因——preStop 卡死、PID 1 是 sh 不转发 TERM、finalizer 未清——前两个都出在这条链上。

"删 Pod 等满 30 秒才停"多半是 TERM 没人接：入口写成 `sh -c xxx`，sh 当 PID 1 不转发 TERM，只能干等 SIGKILL。解法是入口用 exec 形式顶替 sh；slowdie 故意用 sh，就是在复刻这个病。

**到点必 SIGKILL——前提是 kubelet 还在。** Terminating 卡得比宽限期还久只有两种解释：kubelet 失联，或 finalizer 在拦。第七节分诊靠的就是这条判据。

```bash
# 上一节的 slowdie 已经删掉了，先 kubectl apply -f slowdie.yaml 重新起一份；
# 另一终端先挂 kubectl get pod slowdie -w，再执行：
kubectl delete pod slowdie
# 约 60 秒后才返回 pod deleted —— 你平时等的那 30 秒，等的是这条链
# watch 侧：Running → Terminating → 对象消失
```

反方主张也听一听："30 秒太慢，把宽限砍到 5 秒。"但预算里装的是 preStop 和进程收尾，砍短等于让 SIGKILL 提前替你截断——要调，先量出应用真实收尾耗时【从业者判断】。

**宽限期是预算：preStop 花的每秒都从 30 秒里扣。**

## 三、摘流量：不对称才是掉流量的根源

删除链里最先完成的是摘流量：Pod 进 Terminating 的瞬间，Endpoints 立刻摘除，不等宽限期走完：

```bash
kubectl run web --image=nginx:1.27 --restart=Never --port=80 --labels=app=web
kubectl expose pod web --port=80
kubectl get endpoints web
# NAME   ENDPOINTS       AGE
# web    10.244.2.15:80  5s

kubectl delete pod web --wait=false
kubectl get endpoints web
# web   <none>   25s   ← 摘除立刻发生：宽限 30 秒是给进程的，不是给流量的
kubectl delete svc web
```

问题出在对称性：删，立刻摘；加，必须等 readiness 探针通过才收进 Endpoints。摘是毫秒级断腕，加是秒级过审【从业者判断】——**这个不对称正是滚动更新瞬间 5xx 的结构性根源**：新 Pod 没过 readiness 接不了流量，旧 Pod 一删立刻被摘，容量在缝里漏掉。

补救是组合拳：readinessProbe 管进门，体检合格才放流量；preStop sleep 管出门，删后先睡几秒再退出：

```yaml
lifecycle:
  preStop:
    exec:
      command: ["sleep", "5"]   # 睡几秒？量出摘除生效耗时再定，别拍脑袋
```

【从业者判断】"摘除生效"不是一瞬间的事：endpoints controller 改的是对象，kube-proxy 把新规则刷到每个节点、各处转发表才真正放过这条后端——preStop sleep 补的就是这段传播窗口。

**摘立刻、加过审——掉流量的根源不是删得急，是不对称。**

## 四、finalizer：每个持有者都要签字

finalizer 是 metadata.finalizers 里的一串标记。【从业者判断】规则四条：带 finalizer 的对象收到 DELETE 只得到死期、不被删除；谁加的谁摘；控制器干完清理活才摘；列表清空，apiserver 才真正删对象。

它保护的是"清理动作必须发生"——卷要从云上释放、外部资源要注销，删快了就是事故。

看签字簿，一行命令：

```bash
kubectl get pvc <name> -o jsonpath='{.metadata.finalizers}{"\n"}'
# kubernetes.io/pvc-protection   ← 在用中的 PVC 常见这张签名（数组里有几项就是几张签名）
```

【从业者判断】finalizer 的命名习惯带控制器自己的前缀，顺着前缀就能找到加它的控制器；集群自带的保护类标记，挡的就是"卷还在被用就被删"。

硬摘也是一行：

```bash
kubectl patch pod demo -p '{"metadata":{"finalizers":null}}' --type=merge
```

但摘之前先过三问【从业者判断】：谁加的？它要做的清理做了没有（云盘、LB 还在不在）？摘掉的遗留担不担得起（计费的云资源不会因为对象消失就停止计费）？

**finalizer 是清理未完成的收据：硬撕收据，账单还在。**

## 五、级联三模式：ownerReferences 决定谁陪葬

Deployment 删除时，RS 和 Pod 是级联跟着走的，除非 `--cascade=orphan`。级联的依据是子对象身上的 ownerReferences。三种模式【从业者判断】：

| 模式 | 行为 | 适合 |
| --- | --- | --- |
| background（默认） | 父对象先删，GC 后台回收子对象 | 常规删除 |
| foreground | 父对象先进 Terminating，等子对象删光才消失 | 不许留孤儿的关键删除 |
| orphan | 断绝父子关系，子对象全部留下 | 换爹、迁移 |

```bash
kubectl create deployment nginx --image=nginx:1.27
kubectl delete deployment nginx --cascade=orphan
# deployment.apps "nginx" deleted
kubectl get rs,pods -l app=nginx
# RS 和 Pod 全在——爹没了，孩子还在跑
kubectl delete rs,pods -l app=nginx
```

（--cascade 字符串取值要 kubectl 1.20+，老版本等价 --cascade=false。）

构造典型案例：有团队迁移时用 orphan 删旧 Deployment，想让存量 Pod 把手头的活跑完。两周后发现这批无主 Pod 还占着三成节点内存——没有任何控制器认识它们，发布、扩缩容、排查全都够不着，只能逐个手删。

两个相邻的坑。一是 namespace 删除会把里面所有对象级联掉【从业者判断】，namespace 卡 Terminating 多半是里面有带 finalizer 的东西删不掉——先清里面的，外面的自己走。二是存储线另有分岔：删 PVC 后 PV 按 reclaimPolicy 走，Delete 模式连后端卷一起删、不可逆——生产上删 PVC 前可先在线把策略改成 Retain 兜底。

Job 则可选配 ttlSecondsAfterFinished，结束后到点自动清走——常用负载里唯一的"扫尸"开关【从业者判断】。

**orphan 不叫保留，叫遗弃——留下的是没人认领的活容器。**

## 六、镜像：创建 8 步，删除 4 道闸门

和创建那篇对起来看，删除就是倒着走的流水线：

| 创建（8 步） | 删除（4 道闸） | 谁放行 |
| --- | --- | --- |
| apiserver 写入 etcd | ① 置 deletionTimestamp | apiserver（finalizer 可拦） |
| endpointslice 收录、放流量 | ② Endpoints 立刻摘 | endpoints controller |
| kubelet/CRI 建容器 | ③ preStop→SIGTERM→SIGKILL | kubelet |
| 父对象创建子对象 | ④ 级联回收、finalizer 清零 | GC + 各控制器 |

**创建是接力赛，删除是签字仪式**——但排障纪律是同一条：卡住先问"谁负责把它推走"，而不是反复删了重建——删 Pod 又冒新的、PVC 越删越乱，都是跟错误的层较劲。

## 七、卡在 Terminating：处置清单

第一条命令永远是看死期和签字簿：

```bash
kubectl get pod demo -o jsonpath='{.metadata.deletionTimestamp}{"\n"}{.metadata.finalizers}{"\n"}'
```

| 症状 | 卡在哪 | 第一条命令 | 谁放行 |
| --- | --- | --- | --- |
| 超宽限期还挂着、finalizers 空 | kubelet 失联 | `kubectl get node <n>` 查 NotReady 链 | kubelet |
| finalizers 非空 | 清理没做完 | 顺前缀找加它的控制器 | 那个控制器 |
| namespace 卡 Terminating | 里面有删不掉的 | `kubectl get ns <n> -o yaml \| grep finalizers` | 里面的对象 |
| 新 Pod 报 Multi-Attach | 失联节点 RWO 卷没 detach | `kubectl get volumeattachment` | 强删 attachment |
| 滚动更新瞬间 5xx | 摘与加不对称 | `kubectl get endpoints <svc>` | readiness + preStop |

节点那条线上一篇（31）讲过：40 秒判 NotReady、再 300 秒开始驱逐——"Terminating 超宽限 + 节点失联"两条链在这里汇合。确认节点回不来、优雅终止也不需要了，才动核弹：

```bash
kubectl delete pod demo --force --grace-period=0
```

【从业者判断】它只是绕过一切等待、把 API 对象从 etcd 里挑掉；节点若其实还活着，上面的容器就成了没人管的孤儿，真要干净得上节点用 crictl 清。

存储两个收尾：失联节点的 RWO 卷未 detach 会卡住新 Pod（Multi-Attach 报错），可强删对应的 volumeattachment；Retain 的 PV 一直 Released 不是故障是设计——清掉 claimRef 它就回 Available 等复用。

**先看死期和签字簿，再决定动谁。**

## 现在就能做的事

零门槛档：挑一个在用的 PVC，跑第四节那条签字簿命令。动手档：60 秒亲手造一次"删不掉的 namespace"：

```bash
kubectl create ns held
kubectl patch ns held --type=merge -p '{"metadata":{"finalizers":["demo/hold"]}}'
kubectl delete ns held --wait=false
# namespace "held" deleted —— 回执打了，人没走
kubectl get ns held
# NAME   STATUS        AGE
# held   Terminating   30s
kubectl patch ns held --type=merge -p '{"metadata":{"finalizers":null}}'
# 摘掉签名，namespace 立刻消失——第四节的全过程
```

30 秒自检三问：核心服务的 terminationGracePeriodSeconds 是多少？preStop sleep 配了没、几秒？上次卡 Terminating，找到签字的人了吗？

评论区聊两件事：一，你见过卡得最久的 Terminating 对象是什么、最后没签字的凶手是谁；二，你们的 preStop sleep 配几秒、怎么定出来的。

这些内容整理在我维护的学习仓库，GitHub 搜 sre-learning-hub：资源生命周期图鉴一章是这篇的底稿，八张状态图一张网，创建和删除两条链都标在上面。觉得有用点个 star。
