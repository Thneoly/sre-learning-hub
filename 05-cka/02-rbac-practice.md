# 02 · RBAC 实操：Role、绑定与 can-i 验证

> 模块：05-cka ｜ 建议时长：2.5 小时 ｜ 关联认证：CKA-Cluster Architecture（RBAC 是明列考点）

## 学习目标

- 能默写 RBAC 考题的三步模板：create role → create rolebinding → `auth can-i` 验证，命令行与 YAML 双解
- 能解释 Role / ClusterRole / RoleBinding / ClusterRoleBinding 四个对象的生效范围与三种合法组合
- 能识别并避开四大组合陷阱：namespace 混淆、隐式 default ServiceAccount、cluster-scoped 资源、verbs/apiGroups 精确匹配
-能独立完成 5 道自编练习并在 15 分钟内用 can-i 全部验证

## 1. 对象模型：一张图记住四个对象

```
# [图] RBAC 授权链
  Subject(谁)          Binding(绑定)              Role(权限)
┌───────────────┐   ┌────────────────────┐   ┌──────────────────┐
│ User / Group  │──►│ RoleBinding        │──►│ Role             │
│ ServiceAccount│   │ (namespace 级生效)  │   │ (namespace 级资源) │
└───────────────┘   └────────────────────┘   └──────────────────┘
┌───────────────┐   ┌────────────────────┐   ┌──────────────────┐
│ User / Group  │──►│ ClusterRoleBinding │──►│ ClusterRole      │
│ ServiceAccount│   │ (全集群生效)        │   │ (任意/集群级资源)  │
└───────────────┘   └────────────────────┘   └──────────────────┘

Role 与 Binding 都是 namespace 资源（Cluster* 两个除外）；
Role = 一组 rules，每条 rule = apiGroups × resources × verbs（可再加 resourceNames 收窄）。
```

三种合法组合务必记牢：

| 组合 | 效果 | 典型用途 |
| --- | --- | --- |
| Role + RoleBinding | 权限只作用于**单个 namespace** | 给 ns 内某 SA 开 pods 读权限 |
| ClusterRole + RoleBinding | ClusterRole 里**名字空间级资源的规则**被限制在该 RoleBinding 的 namespace 内生效；**集群级资源（nodes/PV/namespace 等）不生效** | 集群里定义一份通用只读角色，各 ns 复用 |
| ClusterRole + ClusterRoleBinding | 全集群、含集群级资源 | 监控组件、运维账号 |

第四种组合（Role + ClusterRoleBinding）**不存在**：ClusterRoleBinding 的 `roleRef.kind` 只能是 ClusterRole，API 会直接拒绝。

verbs 常用取值：`get / list / watch / create / update / patch / delete / deletecollection`，以及 `*` 全量。它们是**精确匹配**——后面陷阱 4 展开。

## 2. 考题标准模板：三步走

CKA 的 RBAC 题几乎都是同一个骨架的三步。下面是一个标准例题：

> 在 namespace `app-ns` 中：创建 Role `ap-dev`，允许对 `deployments` 执行 `get`、`watch`、`list`；创建 RoleBinding `ap-dev-binding`，把它绑给 ServiceAccount `cicd`（位于 app-ns）；确保 `cicd` 能 list deployments 但不能 delete。

### 2.1 命令行解法（考场首选，快）

```bash
# [master] 第 0 步：切到题目 namespace，创建环境
kubectl create ns app-ns
kubectl -n app-ns create serviceaccount cicd

# [master] 第 1 步：Role（--verb 可逗号分隔，--resource 同理）
kubectl -n app-ns create role ap-dev \
  --verb=get,watch,list \
  --resource=deployments

# [master] 第 2 步：RoleBinding（--serviceaccount=<namespace>:<name>）
kubectl -n app-ns create rolebinding ap-dev-binding \
  --role=ap-dev \
  --serviceaccount=app-ns:cicd

# [master] 第 3 步：can-i 验证（正向应为 yes，反向应为 no）
kubectl auth can-i list deployments -n app-ns \
  --as=system:serviceaccount:app-ns:cicd      # yes
kubectl auth can-i delete deployments -n app-ns \
  --as=system:serviceaccount:app-ns:cicd      # no
```

`--as=system:serviceaccount:<ns>:<name>` 是固定拼法，背下来——它让你不用真的拿 token 登录就能验证任何 SA 的权限。

### 2.2 YAML 解法（等价，复杂规则时更稳）

```yaml
# [master] rbac.yaml：kubectl apply -f rbac.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: cicd
  namespace: app-ns
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ap-dev
  namespace: app-ns
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "watch", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ap-dev-binding
  namespace: app-ns
roleRef:                              # roleRef 一经创建不可改名，只能删除重建
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: ap-dev
subjects:
- kind: ServiceAccount
  name: cicd
  namespace: app-ns                   # subjects 里的 SA 必须写 namespace
```

两种解法可混用：骨架用 `create role/rolebinding` 秒出，特殊字段（resourceNames、subresource）再 `kubectl edit` 补。

### 2.3 验证工具箱

```bash
# [master] 列出某 SA 在某 ns 的全部权限（一眼看出多授权了什么）
kubectl auth can-i --list -n app-ns \
  --as=system:serviceaccount:app-ns:cicd

# [master] 查看绑定关系：谁引用了这个 Role / ClusterRole
kubectl -n app-ns get rolebinding -o wide
kubectl get clusterrolebinding -o wide | grep <name>

# [master] 用真实 token 实测（1.24+ token 不再自动生成，手动签发）
kubectl -n app-ns create token cicd
# 把输出填到下面，用"另一个身份"访问 API，再对照 can-i 的预测
kubectl --token=<上一步输出的token> -n app-ns get deploy
```

考场没有 `--as` 之外的捷径：`can-i --list` 输出里多一条不该有的权限，题目就可能不给分——务必正反两向都验。

## 3. 组合陷阱

| 陷阱 | 症状 | 原因 | 解法 |
| --- | --- | --- | --- |
| 1. namespace 混淆 | 权限"不生效"，can-i 返回 no | Role/RoleBinding 建在了 `default` ns，题目要求 `app-ns`；或 subjects 里 SA 的 namespace 写错 | 三处 namespace 必须一致：Role.metadata.namespace、RoleBinding.metadata.namespace、subjects[].namespace |
| 2. 隐式 default SA | 给 Pod 的 SA 授权后 Pod 仍然 Forbidden | Deployment 未指定 `serviceAccountName`，Pod 用的是 `default` SA，授权给的是另一个 SA | `kubectl -n <ns> edit deploy <name>` 加 `spec.template.spec.serviceAccountName: <sa>`；或把权限绑给 default SA（按题意选） |
| 3. 集群级资源绑不出权限 | RoleBinding 引用含 `nodes` 规则的 ClusterRole，can-i get nodes 仍是 no | nodes/PV/namespaces/StorageClass/CRD 是 cluster-scoped，RoleBinding 只对名字空间级资源生效 | 集群级资源必须 ClusterRole + **ClusterRoleBinding** |
| 4. verbs 精确匹配 | `get` 有了却 `kubectl get pod` 报 Forbidden | 列表操作需要 `list`（逐个按名查询才是 `get`）；`watch`、`deletecollection` 也各自独立 | 按题目原文给 verbs，逐个验证；拿不准就 `can-i --list` 对着看 |
| 5. apiGroups 写错 | 资源名对、verbs 对，还是 Forbidden | pods/services/configmaps/secrets 在 core 组（`apiGroups: [""]`）；deployments 在 `apps`；priorityclasses 在 `scheduling.k8s.io` | `kubectl explain <res> | grep GROUP` 现场确认组名 |
| 6. roleRef 改不动 | `kubectl edit rolebinding` 改 roleRef.name 报错 immutable | roleRef 是不可变字段 | 删除 RoleBinding 重建；命令行 `create rolebinding` 重跑一遍即可 |

## 4. 五道自编练习

环境均为练习集群（kubeadm，单 master + Calico）。每题独立，做完在练习集群里验证。

### 练习 1（★☆☆）：最小只读 Role

在 `web` ns 创建 SA `reader`、Role `pod-view`（允许 `get`、`list` pods）、RoleBinding `pod-view-bind`。验收：`reader` 能 `kubectl get pods`，不能 `kubectl delete pod`。

<details><summary>答案</summary>

```bash
# [master]
kubectl create ns web
kubectl -n web create sa reader
kubectl -n web create role pod-view --verb=get,list --resource=pods
kubectl -n web create rolebinding pod-view-bind \
  --role=pod-view --serviceaccount=web:reader

# 验证
kubectl auth can-i list pods -n web --as=system:serviceaccount:web:reader   # yes
kubectl auth can-i delete pods -n web --as=system:serviceaccount:web:reader # no
```
</details>

### 练习 2（★★☆）：resourceNames 与 subresource

在 `secure` ns：允许 SA `auditor`（该 ns）`get` 名为 `app-config` 的**那一个** ConfigMap（不能 list 全部），并允许读取任意 Pod 的日志（`pods/log`）。验收：`get cm app-config` 为 yes，`list cm` 为 no，`get pods/log` 为 yes。

<details><summary>答案</summary>

```bash
# [master] 环境与命令行骨架
kubectl create ns secure
kubectl -n secure create configmap app-config --from-literal=k=v
kubectl -n secure create sa auditor

# resourceNames 与 subresource 用 YAML 最稳（create role 亦支持 --resource-name，YAML 更直观）
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: auditor-role
  namespace: secure
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  resourceNames: ["app-config"]        # 只收窄到这一个对象；verbs 必须含 get
  verbs: ["get"]
- apiGroups: [""]
  resources: ["pods", "pods/log"]      # pods/log 是 subresource，要显式列出
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: auditor-bind
  namespace: secure
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: auditor-role
subjects:
- kind: ServiceAccount
  name: auditor
  namespace: secure
EOF

# 验证
kubectl auth can-i get cm app-config -n secure --as=system:serviceaccount:secure:auditor # yes
kubectl auth can-i list cm -n secure --as=system:serviceaccount:secure:auditor          # no
kubectl auth can-i get pods/log -n secure --as=system:serviceaccount:secure:auditor     # yes
```

要点：带 `resourceNames` 的 rule 不允许 `create`/`list`（它们天然是"跨对象"动作）；`kubectl logs` 走的是 `pods/log` subresource，只给 `get pods` 时日志仍然 Forbidden。
</details>

### 练习 3（★★☆）：cluster-scoped 资源的绑定路径

SA `ops-monitor`（ns `monitor`）需要 `get`、`list` **nodes**。先按"ClusterRole + RoleBinding"做一遍并验证失败，再改用正确组合通过。验收：最终 `can-i list nodes` 为 yes。

<details><summary>答案</summary>

```bash
# [master] 第 1 次尝试：ClusterRole 定义了 nodes 规则，但用 RoleBinding 绑定
kubectl create ns monitor
kubectl -n monitor create sa ops-monitor
kubectl create clusterrole node-viewer --verb=get,list --resource=nodes
kubectl -n monitor create rolebinding node-viewer-rb \
  --clusterrole=node-viewer --serviceaccount=monitor:ops-monitor

kubectl auth can-i list nodes --as=system:serviceaccount:monitor:ops-monitor
# no —— nodes 是 cluster-scoped，RoleBinding 不生效（陷阱 3）

# [master] 第 2 次：删除重建为 ClusterRoleBinding
kubectl -n monitor delete rolebinding node-viewer-rb
kubectl create clusterrolebinding node-viewer-crb \
  --clusterrole=node-viewer --serviceaccount=monitor:ops-monitor

kubectl auth can-i list nodes --as=system:serviceaccount:monitor:ops-monitor
# yes
```

对照实验：把同一份 ClusterRole 用 RoleBinding 绑定、rule 换成名字空间级资源（如 pods），can-i 会是 yes——这就是"ClusterRole 复用到单 ns"的正确打开方式。
</details>

### 练习 4（★★☆）：只许扩缩，不许删除

在 `shop` ns：SA `sre` 能对 deployments `get`、`patch`（含 `deployments/scale` subresource），不能 `delete`。验收：`scale` 一个测试 Deployment 成功，`delete` 被拒。

<details><summary>答案</summary>

```bash
# [master] 环境
kubectl create ns shop
kubectl -n shop create sa sre
kubectl -n shop create deployment web --image=nginx:1.29 --replicas=1

# 授权：kubectl scale 实际是对 deployments/scale 做 patch
kubectl -n shop create role scale-operator \
  --verb=get,patch \
  --resource=deployments,deployments/scale
kubectl -n shop create rolebinding scale-operator-rb \
  --role=scale-operator --serviceaccount=shop:sre

# 验证：用真实 token 实测一次，模拟考场上的"Pod 视角"
TOKEN=$(kubectl -n shop create token sre)
kubectl --token=$TOKEN -n shop scale deployment web --replicas=3   # scaled
kubectl --token=$TOKEN -n shop get deploy web                      # OK
kubectl --token=$TOKEN -n shop delete deploy web                   # Error: forbidden
```

若只给 `patch deployments` 而漏了 `deployments/scale`，`kubectl scale` 会 Forbidden——subresource 是独立资源。
</details>

### 练习 5（★★★）：排错——授权了却仍然 Forbidden

在 `legacy` ns 已有 Deployment `api`（未指定 SA）与一组"看起来正确"的 RBAC：

```bash
# [master] 复现故障环境（一段一段执行）
kubectl create ns legacy
kubectl -n legacy create deployment api --image=nginx:1.29
kubectl -n legacy create sa app-sa
kubectl -n legacy create role app-role --verb=get,list --resource=pods
kubectl -n legacy create rolebinding app-rb --role=app-role --serviceaccount=legacy:app-sa
```

现象：Pod 内程序以自己的 SA 调 API list pods 仍然 Forbidden。要求：定位两层原因并修复，使 Pod 里的 SA 拥有该权限（不许改动 Role 的 rules）。

<details><summary>答案</summary>

第一层：Deployment 没写 `serviceAccountName`，Pod 用的是隐式 `default` SA，而权限绑给了 `app-sa`（陷阱 2）。第二层（修复后自然显形）：验证时要用 Pod 真正的 SA 身份去 can-i。

```bash
# [master] 第 1 步：确认 Pod 当前实际用的 SA
kubectl -n legacy get pod -o jsonpath='{.items[0].spec.serviceAccountName}'
# （空输出或 default，说明未指定 → 用的是 default）

# 第 2 步：把 Deployment 指到 app-sa
kubectl -n legacy set serviceaccount deployment api app-sa
kubectl -n legacy rollout status deployment api

# 第 3 步：等新 Pod 就绪后，以 app-sa 身份验证
kubectl auth can-i list pods -n legacy --as=system:serviceaccount:legacy:app-sa
# yes

# 第 4 步：进 Pod 用真实 token 复验（可选，最接近生产排错）
POD=$(kubectl -n legacy get pod -l app=api -o name | head -1)
kubectl -n legacy exec $POD -- sh -c \
  'wget -qO- --header="Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token)" \
   https://kubernetes.default.svc/api/v1/namespaces/legacy/pods --no-check-certificate' | head -c 200
```

`set serviceaccount` 会触发滚动重建，等 `rollout status` 完成再验证。题面"不许改 rules"逼你从绑定对象一侧（SA 选择）解题，这正是考题最爱考的方向。
</details>

## 实战演练：考场全流程走一遍

用 15 分钟把模板题在练习集群完整走一遍并计时：

```bash
# [master] 1. 读题提取四要素：ns=rb-exam / Role=ex-r / SA=ex-sa / 资源=pods+services verbs=get,list
kubectl create ns rb-exam
kubectl -n rb-exam create sa ex-sa
kubectl -n rb-exam create role ex-r --verb=get,list --resource=pods,services
kubectl -n rb-exam create rolebinding ex-rb --role=ex-r --serviceaccount=rb-exam:ex-sa

# [master] 2. 正向 + 反向验证
kubectl auth can-i list pods -n rb-exam --as=system:serviceaccount:rb-exam:ex-sa     # yes
kubectl auth can-i list services -n rb-exam --as=system:serviceaccount:rb-exam:ex-sa # yes
kubectl auth can-i create pods -n rb-exam --as=system:serviceaccount:rb-exam:ex-sa   # no
kubectl auth can-i list pods --as=system:serviceaccount:rb-exam:ex-sa                 # no（其他 ns 无权限）

# [master] 3. 全量权限清单复核
kubectl auth can-i --list -n rb-exam --as=system:serviceaccount:rb-exam:ex-sa

# [master] 4. 清理
kubectl delete ns rb-exam
```

能稳定在 5 分钟内做完并全绿，RBAC 题就从"缺口"变成"送分题"。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| `create role` 报 `unable to recognize` 之类错误 | kubectl 版本过老或资源名单复数写错 | 资源名用复数（pods/deployments）；`kubectl create role --help` 现场看示例 |
| RoleBinding 建好了，can-i 还是 no | subjects 的 namespace 漏写/写错；或 roleRef 引用的 Role 在别的 ns | `kubectl get rolebinding -o yaml` 逐字段核对三处 namespace |
| `kubectl logs` Forbidden 但给了 pods 读权限 | 缺 `pods/log` subresource | rule 里 resources 加 `pods/log`（练习 2） |
| `kubectl scale` Forbidden | 缺 `deployments/scale` 或缺 `patch` | rule 加 subresource 与 `patch` verb（练习 4） |
| `can-i` yes 但真实调用失败 | 验证的 SA 与 Pod 实际 SA 不一致（default vs 指定） | `get pod -o jsonpath='{.spec.serviceAccountName}'` 确认后再验 |
| 考场上把 ClusterRoleBinding 绑给了 Role | roleRef.kind 写错 | ClusterRoleBinding 只能引 ClusterRole；改回来删绑定重建 |

## 自测

1. ClusterRole 里同时有 `pods` 和 `nodes` 的规则，用 RoleBinding 绑定后分别能拿到什么权限？为什么这样设计？

<details><summary>答案</summary>

只有该 namespace 内的 pods 权限，nodes（cluster-scoped）拿不到。设计动机：namespace 是管理边界，namespaced 的绑定不允许把集群级资源的权限"走私"进某个 ns；要集群级资源必须显式用 ClusterRoleBinding，让权限边界可见。
</details>

2. `verbs: ["get"]` 的 Role，用户执行 `kubectl get pods` 会怎样？执行 `kubectl get pod my-pod` 呢？

<details><summary>答案</summary>

`kubectl get pods`（列表）需要 `list`，会 Forbidden；`kubectl get pod my-pod`（按名取单个）只需要 `get`，会成功。反过来只有 `list` 没有 `get` 时，列表能出但 describe 单个对象会失败——describe 需要 get。
</details>

3. 题目要求"让 default namespace 里所有新 Pod 默认就能 list configmaps"，有哪些实现路径？各自的副作用？

<details><summary>答案</summary>

路径一：给 default SA 建 RoleBinding（Role 含 list configmaps，ns=default）——ns 内所有未显式指定 SA 的 Pod 立即获得该权限，范围大、粒度粗。路径二：逐个 Deployment 显式指定专用 SA 并绑定——粒度细但要改每个工作负载。考题如果只说"default SA 需要权限"就选路径一；如果给了专用 SA 名字，绝不要用 default SA 挂绑定（评分只认题目指定的 SA）。
</details>

4. `kubectl -n x get rolebinding rb -o yaml` 里 subjects 写了正确的 SA，roleRef 也对，但授权仍不生效。给出三个检查点。

<details><summary>答案</summary>

（1）RoleBinding 与 Role 的 namespace 是否都是题目要求的 ns（RoleBinding 只能引用同 ns 的 Role）；（2）subjects[].kind 是否 ServiceAccount 且 namespace 字段指向 SA 真实所在 ns；（3）rule 的 apiGroups/resources/verbs 是否与题目一致（core 组要写 `""`，subresource 要显式列出）。最后用 `can-i --list` 与预期清单比对。
</details>

5. 为什么考场 RBAC 题做完必须做一次"反向 can-i"（验证不该有的操作是 no）？

<details><summary>答案</summary>

评分脚本通常同时检查"允许的操作 yes"和"禁止的操作 no"——权限给多一样扣分。`--verb=*`、`--resource=*` 这类省事写法极易把 delete/create 一起放开。反向验证一次，成本 10 秒，能保住整题分。
</details>

## 延伸阅读

- RBAC 官方文档（考场可开，权威且带全部示例）：https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- 使用 RBAC 授权细化（含 subresource 示例）：https://kubernetes.io/docs/reference/access-authn-authz/rbac/#referring-to-resources
- ServiceAccount 与 token（1.24+ 行为变化）：https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- `kubectl auth` 命令参考：https://kubernetes.io/docs/reference/generated/kubectl/kubectl-commands#auth
- 本模块配套练习：labs 11-rbac-role-binding、12-sa-token-permissions
