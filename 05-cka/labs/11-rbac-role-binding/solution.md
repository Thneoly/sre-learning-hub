# Lab 11 · 解答：RBAC Role 与 RoleBinding

## 思路

RBAC 三件套的关系：

```
User/Group/ServiceAccount ──(subjects)── RoleBinding ──(roleRef)── Role(rules)
                                                      (namespace 级)
```

- Role 是权限的**定义**（谁能对哪些 resource 做哪些 verb），属于某个 namespace。
- RoleBinding 是权限的**发放**（把 Role 授给 subjects 列表里的身份）。
- 授权判定在 API Server 内联完成，`kubectl auth can-i` 走的就是同一条判定路径，所以它是验证 RBAC 题的唯一可靠手段。

## 第 1 步：创建 namespace

```bash
# [master]
kubectl create namespace cka-rbac
```

验证：

```bash
# [master]
kubectl get ns cka-rbac
```

预期输出包含一行 `cka-rbac   Active   <age>`。

## 第 2 步：创建 Role pod-reader

`pods/log` 与 `pods` 的 verbs 不同，分成两条 rule 写，语义最清晰：

```bash
# [master]
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pod-reader
  namespace: cka-rbac
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
EOF
```

要点：

- `apiGroups: [""]` 是核心 API 组（core），pods 属于核心组；deployments 属于 `apps` 组，别混。
- `pods/log`、`pods/exec`、`pods/portforward` 都是**子资源**（subresource），必须单独写。

验证：

```bash
# [master]
kubectl -n cka-rbac describe role pod-reader
```

预期看到 `Pods: get, list, watch` 与 `Pods/log: get` 两组规则。

## 第 3 步：创建 RoleBinding

```bash
# [master]
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-user-pod-reader
  namespace: cka-rbac
subjects:
- kind: User
  name: dev-user
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF
```

要点：

- subjects 的 `kind` 必须是 `User`。写成 `ServiceAccount` 会绑定到另一个身份（SA 的真实用户名是 `system:serviceaccount:<ns>:<name>`），授权不会落到 `dev-user` 头上。
- `roleRef` 一旦创建**不可修改**，绑错了只能删掉重建。

验证：

```bash
# [master]
kubectl -n cka-rbac describe rolebinding dev-user-pod-reader
```

预期输出：

```
Name:         dev-user-pod-reader
Labels:       <none>
Role:
  Kind:  Role
  Name:  pod-reader
Subjects:
  Kind  Name      Namespace
  ----  ----      ---------
  User  dev-user
```

## 第 4 步：can-i 逐条验证

```bash
# [master]
kubectl auth can-i get pods -n cka-rbac --as=dev-user
# yes

kubectl auth can-i create pods -n cka-rbac --as=dev-user
# no

kubectl auth can-i get pods -n default --as=dev-user
# no
```

三条结果为 yes / no / no 即达标：

- 第 1 条：Role 规则命中（`pods` + `get`）。
- 第 2 条：rules 里没有 `create`，RBAC 默认拒绝一切未显式授予的操作。
- 第 3 条：Role/RoleBinding 只存在于 `cka-rbac`，对 `default` 天然无效。

## 第 5 步：查看完整权限表

```bash
# [master]
kubectl auth can-i --list --as=dev-user -n cka-rbac
```

预期输出（只截取非空部分）：

```
Resources                                       Non-Resource URLs   Resource Names   Verbs
pods                                            []                  []               [get list watch]
pods/log                                        []                  []               [get]
selfsubjectaccessreviews.authorization.k8s.io   []                  []               [create]
...
```

最后两行是系统自动允许的"自我查询"权限，所有用户都有，不影响最小权限结论。

## 常见错误回顾

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| can-i 全部 no | subjects.kind 写错（如写成了 SA），或 name 拼错 | describe rolebinding 核对 subjects |
| can-i get pods 是 no 但 list 是 yes | `pods` 与 `pods/log` 写在同一条 rule，verbs 没含 get | 分两条 rule，见第 2 步 |
| default 里也能 get pods | 把 Role 写成了 ClusterRole，或绑了内置 cluster-admin | 改用 namespace 级 Role |
| RoleBinding apply 报错不可修改 roleRef | roleRef 字段 immutable | 删除 RoleBinding 重建 |

## check.sh 运行结果

```bash
# [master]
chmod 755 check.sh && ./check.sh
```

预期：

```
PASS: namespace cka-rbac 存在
PASS: Role pod-reader 存在于 cka-rbac
PASS: Role 规则覆盖 pods(get/list/watch) 与 pods/log
PASS: RoleBinding dev-user-pod-reader 存在
PASS: RoleBinding 将 User dev-user 绑定到 Role pod-reader
PASS: dev-user 在 cka-rbac 内可以 get pods (can-i=yes)
PASS: dev-user 在 cka-rbac 内不能 create pods (最小权限)
PASS: dev-user 在 default 内不能 get pods (namespace 隔离)

SCORE: 8/8
```
