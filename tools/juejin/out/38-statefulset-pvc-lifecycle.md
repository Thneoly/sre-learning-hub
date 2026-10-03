---
title_juejin: '删了 StatefulSet，数据还在：PVC 复活事故'
title_zhihu: '删了 StatefulSet 数据还在：不是残留是设计，复活才是事故'
description: '删 STS 不删 PVC 不是残留是设计：序号身份、缩容留盘、扩容接回旧盘、Retain 的 Released 陷阱、唯一正确的销毁顺序，一篇讲透。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686346277555683378"
---

# 被你删掉的数据库，两周后自己回来了

> 存储与有状态负载｜K8s 深入理解

周五测试环境大扫除，你敲下 `kubectl delete sts pg`，清单划掉一项。两周后新项目同名起了一套 pg，DBA 连上去——库里躺着"已删除"的数据，旧密码还能登录。（场景是构造的，坑是真实的默认行为。）

没有一条命令失败。问题出在对"删除"的理解：**删 STS 删的是逻辑不是数据，PVC 生死线从不跟着级联。**

## 一、一个序号，两张名片：DNS 名与 PVC 名

Deployment 的副本无名无姓、重启即换；STS 的副本有名字、有存储、有顺序——身份的根是序号，两份身份都从它派生。

第一张名片是 DNS 名：STS 必须配 headless Service（`clusterIP: None`），每个 Pod 得到唯一域名 `<pod-name>.<service-name>.<namespace>.svc.cluster.local`，重启后名字与解析记录不变。

普通 Service 只解析到 ClusterIP 轮询，寻址不到具体副本、做不了主从选举，所以 `serviceName` 必须指向 headless Service。

第二张名片是 PVC 名：`volumeClaimTemplates` 为每个序号生成专属 PVC，命名三段拼接——**模板名-STS 名-序号**。模板叫 data、STS 叫 pg，三个副本就是 data-pg-0/1/2；Pod 重调度后重新绑回原来的 PVC，数据跟着序号走。

```yaml
# 保存为 pg-sts.yaml（前置: 在 GitHub 搜 rancher/local-path-provisioner, 装好并设为默认 SC;
#                    local-path 的卷建在单个节点上、不能跨节点挂载, 本篇实验在单节点集群最稳）
apiVersion: v1
kind: Service
metadata: {name: db}
spec:
  clusterIP: None          # headless: DNS 直接解析到各 Pod IP
  selector: {app: pg}
  ports: [{port: 5432}]
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: pg}
spec:
  serviceName: db          # 必须指向 headless Service
  replicas: 3
  selector: {matchLabels: {app: pg}}
  template:
    metadata: {labels: {app: pg}}
    spec:
      containers:
      - name: pg
        image: postgres:16
        env: [{name: POSTGRES_PASSWORD, value: "pgpass"}]
        volumeMounts: [{name: data, mountPath: /data}]
  volumeClaimTemplates:
  - metadata: {name: data}          # PVC 名 = data-pg-<序号>
    spec:
      accessModes: ["ReadWriteOnce"]
      resources: {requests: {storage: 1Gi}}
```

```bash
kubectl apply -f pg-sts.yaml
kubectl get pods -l app=pg -w
# 预期: pg-0 Running → pg-1 → pg-2, 严格依次
kubectl get pvc
# data-pg-0   Bound   1Gi
# data-pg-1   Bound   1Gi
# data-pg-2   Bound   1Gi
kubectl delete pod pg-1
# 新 Pod 仍叫 pg-1, 重新绑回 data-pg-1 —— 名字和盘都不换
```

**两张名片一个根：DNS 名与 PVC 名都由序号派生。**

## 二、删 STS 不删 PVC：善意的设计，事故的源头

`kubectl delete sts pg` 之后：Pod 按 N−1 到 0 逆序删除、STS 对象消失、PVC 一个没动——不是 bug，是数据安全设计。【从业者判断】级联删除跟着属主引用走，volumeClaimTemplates 生成的 PVC 不挂 STS 属主，冲击波到这层就停了。

善意的一面：误删、重建、迁移，只要 PVC 在，同名重建后旧盘全部接回，一行不丢。

暗面：你说的"删除"和 K8s 的"删除"不是同一个词。两个剧本。

剧本 A，数据复活——就是开头那单：测试库带着上一位使用者的数据回来，旧密码照常登录；多租户环境里就是数据泄露。

剧本 B，静默泄漏——删了 STS 又删了 PVC，但 SC 是 Retain：PV 进 Released、谁也绑不上，数据永远躺在后端计费。

**善意和事故是同一条规则：数据跟着名字走，不管你认不认。**

## 三、缩容与扩容：删的是高序号，接的是旧盘

缩容按 N−1 到 0 逆序删（`kubectl scale sts pg --replicas=1`：pg-2、pg-1 依次走人），被删 Pod 的 PVC 原样保留——缩容省的是计算资源，一个字节存储都没省。

扩容接回的是谁的盘？由 PVC 名决定：

| 扩容时该序号的 PVC | 接到什么 | 旧数据 |
| --- | --- | --- |
| 还在（Bound） | 接回原盘 | 完整回归——复活的来源 |
| 已删，SC=Delete | 全新空盘 | 后端卷已被 provisioner 删掉，找回只能靠备份 |
| 已删，SC=Retain | 全新空盘 | 躺在 Released 的旧 PV 里，占着容量，无人管理 |

第三行最阴险：数据既没删掉，也没人接，只是从视野里消失。【从业者判断】缩容几个月再扩容，回来的副本带着过期的复制位点、陈旧的缓存键集——"旧"本身也是事故。

**缩容删的是 Pod 不是字节；扩容接的是序号名下的旧盘。**

## 四、partition 灰度与 podManagementPolicy

STS 有个 Deployment 没有的更新旋钮：`updateStrategy.rollingUpdate.partition`——**序号 ≥ partition 的才更新**。replicas=3、partition=2，只有 pg-2 换新版本，2 号就是金丝雀。

没问题就降到 1、再降到 0，每降一格放行一个序号。身份和盘都不动，动的只是二进制。

podManagementPolicy 管副本创建与删除的节奏：

- **OrderedReady（默认）**：0 到 N−1 依次创建，前一个 Ready 才建下一个，删除逆序——启动顺序变成启动依赖，0 号卡住，整条队伍不存在。
- **Parallel**：关掉启动等待，副本并行创建，DNS 与存储身份不变；相互独立、启动慢的集群用它，上线时间从"串行求和"压到"最慢那一个"。

**OrderedReady 是特性也是单点：0 号卡住全队停。**

## 五、正确销毁姿势：顺序是语义，不是仪式

先问自己：要数据，还是要销毁数据？

要数据（迁移、误删恢复）：只删 STS，PVC 原地不动；重建时同名、同模板名，旧盘全部接回。模板名从 data 改成 dat，新 PVC 就叫 dat-pg-0，旧盘全部沦为孤儿——"删了重建数据丢了"，十有八九是名字对不上。

彻底销毁，顺序只有一条是对的：

```bash
kubectl delete sts pg --wait=false
kubectl get pods -l app=pg        # 确认 Pod 已清空
kubectl delete pvc data-pg-0 data-pg-1 data-pg-2
kubectl get pv
# SC=Delete: PV 与后端卷直接消失, 数据永久没了
# SC=Retain: PV 变 Released, 数据还在, 还得处理 PV
```

非要反过来（Pod 还在就先删 PVC）？【从业者判断】PVC 带保护性 finalizer，被引用时删除停在 Terminating，Pod 退出后照常执行——结果一样，但你丢掉了删除之间那道人工检查窗口。

两招在线救命：

```bash
# 误用 Delete 的盘, 删 PVC 前先改成 Retain —— 给销毁加人工关口
kubectl patch pv <pv-name> -p '{"spec":{"persistentVolumeReclaimPolicy":"Retain"}}'
# Released 的 PV 想复用: 清 claimRef 回到 Available
kubectl patch pv <pv-name> -p '{"spec":{"claimRef":null}}'
```

第二招有暗坑：Available 的 PV 会被同规格的新 PVC 抢先绑定。【从业者判断】STS 重建时 data-pg-2 可能抢到当年 data-pg-0 的盘——跨序号接线、数据错位。

| 意图 | 动作序列 |
| --- | --- |
| 误删恢复 / 迁移 | 只删 STS → 同名、同模板名重建 |
| 换新盘但留旧数据 | 删 STS → PV 先 patch 成 Retain → 删 PVC |
| 彻底销毁 | 删 STS → 等 Pod 清空 → 删 PVC → Retain 再清 PV |
| 清理缩容残留 | 只删对应序号的 PVC（如 data-pg-2） |

**销毁顺序是语义：先删 STS 留关口，先删 PVC 是引爆。**

## 现在就能做的事

零门槛档：`kubectl get sts -A` 对照 `kubectl get pvc -A`，找没有 STS 认领的 PVC——那是孤儿盘清单；再 `kubectl get pv` 扫一遍 Released，数数"删了但没删掉"的存量。

动手档，五分钟复现复活事故：

```bash
kubectl exec pg-0 -- sh -c 'echo alive-before-delete > /data/tombstone'
kubectl delete sts pg --wait=false
kubectl get pvc        # data-pg-0/1/2 还在 —— 它们不跟 STS 走
kubectl get pods -l app=pg -w   # 等 Pod 全部消失再重建(Ctrl-C 退出), 顺序同上节
kubectl apply -f pg-sts.yaml    # 前提同开头注释: local-path 盘在原节点上, Pod 落回同一节点才接得回旧盘
kubectl exec pg-0 -- cat /data/tombstone
# alive-before-delete —— "已删除"的数据, 原样复活
kubectl delete sts pg --wait=false
kubectl delete pvc data-pg-0 data-pg-1 data-pg-2   # 收尾
```

30 秒自检三问：删 STS 和删 PVC 是一个按钮吗？缩容留下的 PVC 谁在记账？数据库的 SC 是 Delete 还是 Retain？

评论区聊两件事：你遇过"数据复活"吗，怎么收的场；销毁顺序有 runbook 吗，还是全凭手感。

这些内容整理在我维护的学习仓库，GitHub 搜 sre-learning-hub：工作负载控制器与存储体系两章是底稿，pg-sts.yaml 与 reclaimPolicy 的 Retain/Delete 分岔实验都在里面。觉得有用点个 star。
