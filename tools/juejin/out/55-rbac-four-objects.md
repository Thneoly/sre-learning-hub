---
title_juejin: '给了 get 还是 403？RBAC 四个对象，处处反直觉'
title_zhihu: 'get 不等于 list：RBAC 的授权语义是 HTTP 直译，不是英语直觉'
description: 'RBAC四对象与合法组合；get/list/watch为何分开；list在secrets的暴露面；roleRef不可变；三个元权限；can-i --as自查；token默认挂载与403排障。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686346277555683378"
---

# 给了 get 还是 403？RBAC 四个对象，处处反直觉

第一次认真配 RBAC 的人几乎都愣在同一处：Role 里写了 `get`、`pods`，`kubectl get pods` 一敲，还是 Forbidden。

更危险的是反方向：有人觉得只授 list 顶多看看名字——在 secrets 上，这直觉会出事故。全文两根柱子：**verbs 是 HTTP 语义的直译，不是英语直觉**；**权限 = 规则 × 作用域，作用域由 Binding 决定**。

## 一、四对象：Binding 决定作用域，Role 只决定动作

Role 与 ClusterRole 的真正区别，不在"能管多少种资源"，而在"授权能落到哪个作用域"。四种组合，三种合法：

| 角色 | 绑定 | 实际效果 |
| --- | --- | --- |
| Role | RoleBinding（同 ns） | 该 ns 内生效 |
| ClusterRole | ClusterRoleBinding | 全集群生效 |
| ClusterRole | RoleBinding | 仅该 ns 生效（复用） |
| Role | ClusterRoleBinding | 不存在，API 直接拒绝 |

第三行最容易被答错。把内置 view、edit 挂上 ns 级 RoleBinding 是官方的复用姿势：权限被压进那一个 ns，不会升级成全集群。反向更隐蔽：往 Role 里写 nodes、PV 这类集群级资源是无效授权——集群级资源只认 ClusterRoleBinding，要它就必须留一行显眼的绑定。

同一份 ClusterRole，换个绑定方式结果就变，亲手跑一遍：

```bash
kubectl create ns monitor && kubectl -n monitor create sa ops-monitor
kubectl create clusterrole node-viewer --verb=get,list --resource=nodes
kubectl -n monitor create rolebinding node-viewer-rb \
  --clusterrole=node-viewer --serviceaccount=monitor:ops-monitor
kubectl auth can-i list nodes --as=system:serviceaccount:monitor:ops-monitor
# no —— cluster-scoped 资源，RoleBinding 不参与
kubectl -n monitor delete rolebinding node-viewer-rb
kubectl create clusterrolebinding node-viewer-crb \
  --clusterrole=node-viewer --serviceaccount=monitor:ops-monitor
kubectl auth can-i list nodes --as=system:serviceaccount:monitor:ops-monitor
# yes
```

RBAC 没有 Deny：多份绑定求并集、只增不减，"允许一切除了 delete"表达不了，要排除就上准入层。

## 二、verbs：英语直觉在 HTTP 语义面前不值钱

三个"读"动词先掰开：get 是 GET 单个对象，可配 resourceNames 收窄；list 是 GET 集合；watch 是 GET 加 watch 参数做流式订阅——三者互不包含。写操作是 create/update/patch/delete，集合删除另有 deletecollection。

**列表走 list，点名才走 get**：`kubectl get pods` 走 list，`kubectl get pod my-pod` 才走 get，describe 也是——只给 list 的人，describe 必挂。

subresource 是第二重非直觉：子资源用"父/子"表示、不写就不授，verb 还不同——logs 要 pods/log 的 get，exec 要 pods/exec 的 create，scale 要 deployments/scale 的 patch。

高频错配还有 apiGroups：pods、secrets 在 core 组，要写 `apiGroups: [""]`；资源名对、verbs 对、还是 403，先查组名。

secrets 更要命。**list 从来不是"只看名字"**【从业者判断】：`kubectl get secrets` 的表格输出确实只见名字和键数量，但换成 `-o yaml`，data 字段连同内容整包返回——list 与 get 返回的都是完整对象。

收窄正道是 get 配 resourceNames 点名；它对 list/watch/create 天然无效。

**把 list 当"只看名单"，等于连保险箱一起送了出去。**

## 三、三个元权限：impersonate 横向提权，escalate/bind 纵向提权

默认规则很保守【官方，Kubernetes RBAC 文档，2026-10】：你只能授出自己已有的权限——改 Role 时新加的权限必须你先持有；建绑定引用角色时，要么持有其全部权限，要么有角色上的 bind。三个元权限是闸门的三次例外：

- escalate：允许在 Role 里写进你没有的权限；
- bind：允许把你不持有的角色绑给别人；
- impersonate：允许以其他用户、组、SA 的身份发请求，kubectl --as 的权限来源。

前两个是纵向——把自己没有的权限"造"出来发下去；impersonate 是横向——权限没涨，却能借任何身份行事，等于拿到对方全部权限。

这三个口子不是设计疏漏：平台团队替租户发权限要 bind，自动化替用户办事要 impersonate——问题从来不是动词存在，而是它们落进了谁的 rules。

**授这三个 verb 等于开侧门，按发 root 的标准审**【从业者判断】。只该管自己 ns 的角色，rules 里出现这三个词就是审计红旗。

## 四、roleRef 不可变：官方的取舍，换绑定的正确姿势

`kubectl edit rolebinding` 改 roleRef 的下场是报 immutable。官方规则【官方，Kubernetes RBAC 文档，2026-10】：绑定一经创建，roleRef 不能改指别的角色，只能删除绑定、重建一个。

为什么焊死？【从业者判断】若 roleRef 可改，任何有 update 权限的人都能把现成绑定悄悄改指 cluster-admin——update 的校验远比创建时的 bind/escalate 检查宽松。焊死它，"换角色"必走一遍完整创建校验，提权绕行的路没有了。

正确姿势只有一种——删除重建：

```bash
kubectl -n app-ns delete rolebinding ap-dev-binding
kubectl -n app-ns create rolebinding ap-dev-binding \
  --role=ap-dev-v2 --serviceaccount=app-ns:cicd
# rolebinding.rbac.authorization.k8s.io/ap-dev-binding created
```

subjects 是可变的，加人减人直接 edit——官方焊死"指到哪份权限"，放开"发给谁"。

## 五、can-i：不猜，直接问鉴权器

**把问题抛给鉴权器，而不是改一版 YAML 再试一次**。can-i 与真实请求走同一条 RBAC 代码路径，它说 no 就是真 no。边界也要知道：can-i 只问鉴权这一环，准入拦不拦它管不着——那是第七节的事。

```bash
kubectl auth can-i list pods -n dev --as=system:serviceaccount:dev:ci-bot
# no —— 固定拼法 system:serviceaccount:<ns>:<name>
kubectl auth can-i --list -n dev --as=system:serviceaccount:dev:ci-bot
# 完整权限矩阵
kubectl auth can-i '*' '*' --as=system:serviceaccount:dev:ci-bot
# no —— 通配检查
```

两条纪律。其一，**正向 yes 和反向 no 都要验**：`--verb=*` 最容易把 delete/create 一起放开，反向 can-i 一次十秒，考场保分、生产保命。

其二，--as 走 impersonation，发起者要有 impersonate 权限，admin 有、普通用户只能测自己。要用真实 token 复测就 `kubectl create token` 现签，但别在带 admin 证书的终端里——证书会静默盖掉 --token，token 与证书那篇（03）拆过。

## 六、automountServiceAccountToken 默认 true：每个 Pod 都揣着一把集群钥匙

每个 Pod 出生就自动挂三个文件：/var/run/secrets/kubernetes.io/serviceaccount/ 下的 token、ca.crt、namespace——不管需不需要 API，起个 busybox 看那个目录，三件套都在。

token 机制在变好：1.21 起默认挂短时投影 token，1.24 起 SA 不再自动生成永久 Secret；投影 token 约一小时有效、kubelet 自动换新，落盘泄漏只值一小时。

但"有 token"不等于"有权限"——token 管认证（你是谁），RBAC 管授权（你能做什么）。Pod 被攻破后，攻击者拿钥匙试探 API，最后一道软垫是 default SA 的默认零权限。两条纪律：

- 不需要访问 API 的 Pod，显式写 automountServiceAccountToken: false（Pod 或 SA 上设都行；两处都设时 Pod spec 优先【官方，Kubernetes 文档，2026-10】）；
- 需要 API 的 Pod，建专用 SA 并显式写 serviceAccountName。最经典的排障现场：给 app-sa 授了权，Deployment 没写 serviceAccountName，Pod 用的是隐式 default SA，照样 Forbidden。

## 七、401、403、admission：先分环，再动手

RBAC 修不好 401。请求串行走三环：认证（你是谁）→ 鉴权（能不能做）→ 准入（能不能长这样），修法各不相同。

`You must be logged in` 是 401，死在认证：查 kubeconfig、token 过期、证书，与 RBAC 无关；`cannot verb resource` 是 403，死在鉴权，归本文管；带 admission webhook 字样，死在准入，查 webhook 策略，别改 Role。

403 报错自带五要素：身份、verb、resource、apiGroup、namespace——缺什么补什么。

最后一条边界：kubeadm 的 admin.conf 证书身份是 O=system:masters，其全能来自 cluster-admin 这个 ClusterRoleBinding 把 `*:*` 的 ClusterRole 绑给了它——**是 RBAC 授权，不是代码写死**。

反过来，改坏 RBAC 能把 admin 锁在门外（恢复只能绕过 API 写 etcd），RBAC 对象的写权限要按高危操作管。

## 症状速查表

| 症状 | 第一动作 |
| --- | --- |
| 给了 pods 的 get，logs 还是 Forbidden | resources 加 pods/log |
| 列表能出，describe 失败 | verbs 补 get |
| RoleBinding 绑 ClusterRole，get nodes 还是 no | 换 ClusterRoleBinding |

## 一分钟版本

> 权限 = 规则 × 作用域：Role 决定动作，Binding 决定落点，集群级资源只认 ClusterRoleBinding。get 管按名取单个，list 不是只看名单。默认授不出你没有的权限，元权限是例外。roleRef 不可变，删除重建。can-i 正反两向都验。token 不需要就关；401 归认证，403 归 RBAC。

## 现在就能做的事

- 30 秒档：把常用 SA 代进那条通配检查，答案是 yes 就该问问为什么；跑完第一节对照实验，看同一份 ClusterRole 从 no 变 yes。
- 审计档：扫一遍谁握着元权限：

```bash
kubectl get roles -A -o yaml | grep -E 'escalate|impersonate'
kubectl get clusterroles -o yaml | grep -E 'escalate|impersonate'
# 内置 edit/admin 聚合角色本就含 serviceaccounts 的 impersonate，属基线；
# 基线之外每多一行，就去核对归属
```

一句话收束：**get 不等于 list**，**Role 不等于小号 ClusterRole**，有 token 不等于有权限——每处反直觉，都是刻意设计的边界。

评论区聊两件事：一，你审计过自己集群的 Role 吗，最夸张的 verbs 是什么？二，automountServiceAccountToken 你们关了吗？我先说方向：跑完审计档，结果干净的通常是少数。

这一篇整理自我在维护的学习仓库，两个模块里有完整的 RBAC 实战演练和五道练习，命令全部可直接复制执行——GitHub 搜 sre-learning-hub，觉得有用点个 star 不迷路。
