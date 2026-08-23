# Lab 11 · RBAC Role 与 RoleBinding
> 难度：★★ ｜ 考点：CKA-安全（RBAC 授权） ｜ 前置：无 ｜ 预计 30 分钟
> 运行位置：全部操作在 [master] 完成（kubectl admin kubeconfig 已就位）

## 场景

开发组的同事 `dev-user` 报障："我在 `cka-rbac` 这个项目空间里看不到 Pod 状态，也没法查日志，帮我把权限开一下。"

你是集群管理员。安全规范要求**最小权限**：`dev-user` 只应在这个 namespace 内查看 Pod 列表、Pod 详情和 Pod 日志，不允许创建/删除任何资源，也不允许访问其他 namespace。集群已开启 RBAC（默认即开启），你需要用 Role + RoleBinding 完成授权，并用 `kubectl auth can-i` 逐条验证。

## 任务清单

1. 创建 namespace `cka-rbac`。
2. 在该 namespace 内创建 Role `pod-reader`，规则为：
   - 对 `pods`：`get`、`list`、`watch`
   - 对 `pods/log`：`get`
3. 创建 RoleBinding `dev-user-pod-reader`，把 **User** `dev-user` 绑定到 Role `pod-reader`（注意 subjects 的 `kind` 是 `User`，不是 `ServiceAccount`，也不是 `Group`）。
4. 用 `kubectl auth can-i` 验证以下三条结论（把命令记下来，check.sh 会复查同样的语义）：
   - `dev-user` 在 `cka-rbac` 内 `get pods` → `yes`
   - `dev-user` 在 `cka-rbac` 内 `create pods` → `no`
   - `dev-user` 在 `default` namespace 内 `get pods` → `no`
5. 附加：执行 `kubectl auth can-i --list --as=dev-user -n cka-rbac`，确认权限表里只有你授予的内容。

## 验收标准

- `kubectl -n cka-rbac get role,rolebinding` 能看到 `pod-reader` 与 `dev-user-pod-reader`。
- 三条 `can-i` 验证结果与任务清单一致（yes/no/no）。
- 不存在把 `dev-user` 加进 `system:masters` 或授予 ClusterRole `cluster-admin` 之类的"一把梭"操作。

## 提示（卡住再看）

<details><summary>提示 1：Role 的 rules 怎么写</summary>

`pods` 与 `pods/log` 是**两条独立的 resource 条目**，写在一个 rule 的 resources 列表里时 verbs 会共用。`pods/log` 只需要 `get`（读日志本质是读取 pod 的子资源）。更清晰的做法是分成两个 rule。

</details>

<details><summary>提示 2：can-i 的 --as 用法</summary>

```bash
# [master]
kubectl auth can-i get pods -n cka-rbac --as=dev-user
kubectl auth can-i create pods -n cka-rbac --as=dev-user
kubectl auth can-i get pods -n default --as=dev-user
```

`--as` 是 impersonation（身份模拟），admin 有 `impersonate` 权限，可以在不做真实认证的情况下验证某用户的最终授权结果，考试里验证 RBAC 题全靠它。

</details>

<details><summary>提示 3：为什么 default 里是 no</summary>

Role 是 **namespace 级**对象，只在自己所在 namespace 生效；RoleBinding 也只引用**同 namespace** 的 Role。namespace 隔离是 RBAC 的天然边界，不需要额外写 deny 规则——RBAC 默认没有显式 deny，只有累加的 allow。

</details>
