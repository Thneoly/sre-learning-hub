---
title_juejin: '手改副本数 60 秒被打回：GitOps 自愈还是自伤'
title_zhihu: 'GitOps 的自愈不是免费午餐：drift 三大来源与开关组合的风险账'
description: 'GitOps四原则、三态判定、drift三大来源、self-heal与prune开关矩阵、App of Apps、sync wave与hook，一篇讲透ArgoCD同步循环。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686346277555683378"
---

# 手改副本数 60 秒被打回：同步循环不是在针对你

> GitOps 的同步循环｜K8s 深入理解

凌晨两点，流量吃紧，你 `kubectl scale` 把副本拉到 4。一分钟后它自己回到 1。你截图发群：集群闹鬼了。

没闹鬼。是 ArgoCD 的调和循环在干活：Git 写的是 1，集群就得是 1。同一循环换个开关画风全变——一次错误 rebase 让 Git 少半个目录，prune 开着时 ArgoCD 忠实删掉这些生产资源。

自愈与事故，是同一条循环的两种结果。今天拆开讲：三态判定、drift 来源、开关组合、规模化，最后泼两盆冷水——GitOps 不是备份，也不完全替代审计。

## 一、四条原则里，最值钱的是没人爱听的那条

OpenGitOps 社区定义了四原则：**声明式**（期望状态用 YAML/Helm 描述）、**版本化且不可变**（期望状态放 Git，有完整历史）、**自动拉取**（集群内 agent 自己拉 Git，不被 CI 推着走）、**持续调和**（实际与期望持续比对，偏了就拉回）。

```text
push：CI ── kubectl apply ──▶ 集群（CI 持有 kubeconfig，高危）
pull：CI 改 manifest ──▶ Git ◀──持续拉取── ArgoCD（集群内）──▶ 自动 apply
```

三个优势：凭据倒置，CI 不再持有生产 kubeconfig；单一真相，"集群里跑什么"去 Git 看，回滚＝git revert；自愈，手滑改动自动纠正。

难点在前提纪律：**只能通过改 Git 来改集群**。留着"紧急时手改"的后门，单一真相名存实亡；应急改完必须回写 Git，否则下个调和周期把它当 drift 处理。

## 二、三态判定：比对一直跑，问 Git 每三分钟一次

架构一句：repo-server 拉 Git 并用 kustomize/helm 渲染最终 YAML（带缓存），application-controller 拿渲染结果与集群实际持续比对——循环的心脏。

| 状态 | 判定 | 你该做什么 |
| --- | --- | --- |
| Synced | 渲染结果与集群一致 | 无 |
| OutOfSync | 存在差异 | 先 diff 分类再决定动作 |
| Unknown | 比对失败：渲染报错、repo 连不上、集群失联【从业者判断】 | 先修链路，别急着点同步 |

另一个误会：Sync 与健康度独立评估，Synced + Degraded 可同时成立——镜像 tag 写错，YAML 全 apply 成功，Pod 却 ImagePullBackOff。**Synced 只保证部署了声明的东西，不保证声明的东西能跑。**

时序默认值：仓库约每 3 分钟 refresh 一次；盯集群的比对勤得多，手改一分钟内就被逮到——慢的从来只是 Git 这头。"改了 Git 半天没反应"多半是还没轮到；要快就给 Git 平台配 webhook。

## 三、drift 三大来源：一半真漂移，一半假警报

实验环境（repoURL 换成你自己的）：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: demo-guestbook, namespace: argocd}   # 必须建在 ArgoCD watch 的 ns
spec:
  project: default
  source: {repoURL: '<你的仓库>', path: guestbook}
  destination: {server: 'https://kubernetes.default.svc', namespace: demo}
  syncPolicy: {automated: {prune: false, selfHeal: true}, syncOptions: [CreateNamespace=true]}
```

**来源一：人工 kubectl。真 drift，最经典。**

```bash
kubectl -n demo scale deploy guestbook-ui --replicas=4
kubectl -n demo get deploy guestbook-ui              # 此刻 4
sleep 60 && kubectl -n demo get deploy guestbook-ui  # 回到 1：selfHeal 拉回 Git 版本
```

边界：selfHeal 默认只纠 spec 级改动（副本数、镜像、env）——scale 能被纠正，正因它改的是 spec。

**来源二：字段默认值差异。假 drift，最冤枉。**症状："一直 OutOfSync 但肉眼看一样"。

根因：apiserver 与控制器会写进你清单没写的字段——namespace 注入、Service 的 clusterIP、labels、CRD 的 status。处置两步：`argocd app diff` 看真实差异；不可控字段用 ignoreDifferences 让出。

**来源三：控制器回写。灰色地带，最容易吵架。**控制器天生要写字段：HPA 持续覆盖 spec.replicas，Operator 持续维护 CR 的 status。"以谁为准"没有普适答案，解法是划界：**控制器管的字段，从 Git 移除或让出**。

之前 HPA 那篇的铁律即此：replicas 要么全交给 HPA，要么从 Git 删掉，两头都写必打架【从业者判断】。

**drift 排障先分类：人工改的是漂移，默认值和回写是噪音。**

## 四、三个开关：self-heal 错了改回去，prune 错了删生产

```yaml
automated:
  prune: true         # Git 里删了，集群里也删
  selfHeal: true      # 手改被拉回 Git 版本
  allowEmpty: false   # 渲染为空拒绝同步，防"空清单＋prune"清场【从业者判断】
```

五个组合的风险账：

| auto-sync | prune | selfHeal | 手改集群的结局 | Git 误删文件的结局 |
| --- | --- | --- | --- | --- |
| 关 | — | — | 留存，漂移无人管 | 不删，不迁移 |
| 开 | 关 | 关 | 留到下次 Git 触发 sync【从业者判断】 | 不删，仅 OutOfSync |
| 开 | 关 | 开 | 下个调和周期拉回（实测约 60 秒） | 不删，人工清理 |
| 开 | 开 | 关 | 长期留存 | 自动删生产 |
| 开 | 开 | 开 | 拉回 | 自动删生产 |

生产常见的是第三行：`automated: {selfHeal: true, prune: false}`——漂移自动恢复，删除必须人工确认。**selfHeal 上限是改参数，prune 上限是删资源。**

prune 事故的典型剧本：目录重构让旧路径整批消失、新路径因笔误没被渲染。prune 全开时，合并几分钟内旧目录对应的生产资源被逐个删掉——ArgoCD 忠实执行了声明，错的恰是声明本身。误删形态多是错误 rebase、目录移动这类"看着无害"的提交。

自愈那面同样可以亲手做：删资源，看它重建。

```bash
kubectl -n demo delete deploy guestbook-ui
sleep 60 && kubectl -n demo get deploy guestbook-ui   # 重新出现
```

## 五、规模化：把"有哪些应用"也搬进 Git

环境一多，"每个环境手工建一次 Application"本身就是漂移源。App of Apps：Application 清单也进 Git，一个根应用指向 apps/ 目录。

```yaml
# [apps/root-app.yaml] 根应用：同步 apps/ 下的 Application
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: {name: root, namespace: argocd}
spec:
  project: default
  source: {repoURL: '<你的仓库>', path: apps, directory: {recurse: true}}
  destination: {server: 'https://kubernetes.default.svc', namespace: argocd}
  syncPolicy: {automated: {prune: true, selfHeal: true}}
```

收益：新增环境＝提一个 YAML 走 PR；ArgoCD 配置也进 Git，可 review 可回滚；灾备重建只 apply 一个根应用，子应用全部自举。

代价：间接性，排障先分清哪层出问题——根应用没同步出子应用，还是子应用 OutOfSync。再往上用 ApplicationSet：git generator 按目录或集群矩阵批量生成 Application，思想一致。

**App of Apps 是把"有哪些应用"也搬进 Git。**

## 六、wave 管顺序，hook 管动作，都不管回滚

【从业者判断】素材未覆盖此节，按通用实践写。sync wave 用注解排顺序：

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "-1"   # 小于默认的 0，先执行
```

资源按 wave 升序 apply，上一波全 Healthy 才放行下一波——典型编排：wave 0 建 CRD 与 namespace，wave 1 中间件，wave 2 业务。hook 管时机：PreSync 的 Job 同步前跑（如 DB migration），PostSync 验证，SyncFail 收尾。

要清醒：wave 和 hook 都不是事务，中途失败不回滚，要么靠 retry，要么在 SyncFail hook 里自己写补救。**编排解决"按什么顺序做"，不解决"做砸了怎么办"。**

## 七、泼两盆冷水：Git 不是备份，git log 不是完整审计

冷水一：GitOps 仓库不是集群备份。Git 存的是期望状态而非集群全量——未纳管的资源、控制器回写的 status、Secret、数据卷都不在仓库里。Git 能重建"声明过的"，重建不了"实际存在的"，灾备仍靠 etcd 快照与卷备份【从业者判断】。

好消息：Git 断连时资源继续运行（渲染结果缓存在本地、K8s 自治），Git 挂了不会"击落"在线业务。

冷水二：git log 不是完整审计。它记录"变更意图"——谁何时想把集群改成什么样；但集群实际发生了什么——谁绕过 Git kubectl 了什么、准入注入了什么、控制器回写了什么——不在 git log 里，要答"集群被谁改过"，仍需 K8s 的 audit log【从业者判断】。

断网应急只能手改，恢复后必须回写 Git，否则 selfHeal 当 drift 回滚——这个回写窗口，正是单一真相最脆的时刻。

**Git 管"应该是什么"；"实际是什么"靠备份与审计兜底。**

## 症状速查：先存这张表

| 症状 | 根因 | 第一动作 |
| --- | --- | --- |
| 一直 OutOfSync 但看着一样 | 字段默认值差异（clusterIP/labels/status） | argocd app diff；ignoreDifferences |
| 改了 Git 半天不生效 | 默认 3 分钟 refresh，或 webhook 未配 | Hard Refresh；补 webhook |
| 手动改动一直不回滚 | selfHeal 未开或改的不是 spec | 开 selfHeal；确认字段层级 |
| sync 报 immutable field | 改了 clusterIP、selector 等不可变字段 | 删除重建，或改清单设计 |
| repo 连接失败 | 仓库凭据缺失或权限不足 | UI Settings → Repositories 配凭据 |
| Application 建在业务 namespace | ArgoCD 默认只 watch argocd | 移回 argocd namespace |

## 一分钟版本

> **背这段（约一分钟）**
>
> GitOps 四原则：声明式、版本化、自动拉取、持续调和，纪律是只通过改 Git 改集群。同步循环持续比对：一致 Synced、有差异 OutOfSync、比不出 Unknown。drift 三来源：人工 kubectl 真漂移、字段默认值假警报、控制器回写要划界。
>
> 开关：selfHeal 错了改回去，prune 错了删生产。规模化用 App of Apps；wave 管顺序，hook 管动作，都不管回滚。Git 不是备份，git log 不是完整审计。

## 现在就能做的事

三档任选：

- 零门槛档：`argocd app list` 扫一遍，挑出长期 OutOfSync 的应用跑 `argocd app diff`——真漂移还是字段噪声。
- 动手档（5 分钟）：跑第三节的 scale 实验，亲手被 selfHeal 打回一次，再删一次 Deployment 看它重建。
- 审计档：查生产所有 Application 的 prune 开关，对照第四节矩阵，确认删除动作有没有人工确认这道闸。

评论区聊两件事：一，你见过的 prune 血案或险情，触发点是什么；二，你们生产敢开 prune 吗，不开的话删除流程走什么。

K8s 深入理解系列都在专栏合集里。这篇整理自我维护的学习仓库，ArgoCD 章节带完整的安装、自愈、prune 实操——GitHub 搜 sre-learning-hub，觉得有用点个 star 不迷路。
