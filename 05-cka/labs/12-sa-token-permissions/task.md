# Lab 12 · ServiceAccount Token 与权限验证
> 难度：★★ ｜ 考点：CKA-安全（ServiceAccount / RBAC / TokenRequest） ｜ 前置：lab 11 ｜ 预计 35 分钟
> 运行位置：全部操作在 [master] 完成

## 场景

CI 系统需要一个身份在集群里发布服务：它只应操作 namespace `cka-sa` 里的 Deployment 和 Pod（读日志、临时拉起 Pod），绝不能看 Node、不能动其他 namespace。安全团队明确要求：**不许给 SA 绑 cluster-admin**，并且要用真实 token 调一次 API Server 验证边界——token 能干活的范围必须与设计一致。

注意：Kubernetes 1.24 起 ServiceAccount 不再自动生成永久 Secret token，取而代之的是 `kubectl create token`（TokenRequest API，短期 token）。

## 任务清单

1. 创建 namespace `cka-sa` 和 ServiceAccount `ci-bot`（SA 必须在 `cka-sa` 内）。
2. 创建 Role `ci-deployer`，规则为：
   - `apps` 组的 `deployments`：`get`、`list`、`watch`、`create`、`update`
   - 核心组 `pods`：`get`、`list`、`watch`、`create`
   - 核心组 `pods/log`：`get`
3. 创建 RoleBinding `ci-bot-deployer`，把 **ServiceAccount** `ci-bot`（namespace `cka-sa`）绑定到该 Role。
4. 用 impersonation 快速验证（不发真实请求）：
   - `kubectl auth can-i create deployments.apps -n cka-sa --as=system:serviceaccount:cka-sa:ci-bot` → `yes`
   - `kubectl auth can-i get nodes --as=system:serviceaccount:cka-sa:ci-bot` → `no`
   - `kubectl auth can-i get pods -n default --as=system:serviceaccount:cka-sa:ci-bot` → `no`
5. 用 `kubectl create token` 为 `ci-bot` 签发一个 token，然后携带该 token 真实调用一次 API Server 验证边界：
   - 在 `cka-sa` 内 `get pods`（应成功，HTTP 200）
   - 执行 `get nodes`（应被拒绝，HTTP 403）

   注意：admin kubeconfig 用**客户端证书**认证，直接 `kubectl --token` 不会生效——请求会同时带上证书和 token，而 API Server 认证器优先校验客户端证书，身份仍是 `kubernetes-admin`。要用 curl 只带 token 调用（见提示 2）。

## 验收标准

- `kubectl -n cka-sa get sa,role,rolebinding` 三类对象齐备，RoleBinding 的 subject 是 `ServiceAccount/ci-bot`。
- 第 4 步三条 can-i 结果为 yes/no/no。
- 第 5 步：token 身份能列出 `cka-sa` 的 Pod；`get nodes` 返回 `Forbidden`。

## 提示（卡住再看）

<details><summary>提示 1：SA 作为 subject 的写法</summary>

```yaml
subjects:
- kind: ServiceAccount
  name: ci-bot
  namespace: cka-sa
```

SA 是唯一需要写 `namespace` 的 subject 类型（User/Group 是集群全局命名）。SA 在 API Server 眼里的真实用户名是 `system:serviceaccount:<namespace>:<name>`，这就是第 4 步 `--as` 的取值来源。

</details>

<details><summary>提示 2：签发并使用 token</summary>

```bash
# [master]
TOKEN=$(kubectl create token ci-bot -n cka-sa)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

# 只带 token 调 API Server（-k 跳过证书校验，实验环境足够）
curl -sk -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/namespaces/cka-sa/pods"    # 200
curl -sk -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/nodes"                     # 403
```

`kubectl create token` 走 TokenRequest API，签出的是**短期** JWT（默认 1 小时），不落盘成 Secret。想长期使用时再创建 `type: kubernetes.io/service-account-token` 的 Secret 并标注 `kubernetes.io/service-account.name`。

为什么不用 `kubectl --token`：admin kubeconfig 的用户走客户端证书认证，`--token` 只是在请求上**追加**一个 bearer token，API Server 会优先用证书识别身份（认证器顺序：证书在前），所以身份不会变成 SA。若想看 kubectl 的报错原文，可以用一个"不带证书"的临时身份：

```bash
# [master]
KUBECONFIG=/dev/null kubectl --server="$APISERVER" --insecure-skip-tls-verify \
  --token="$TOKEN" get nodes    # Forbidden
```

</details>

<details><summary>提示 3：token 里的东西</summary>

```bash
# [master]
kubectl create token ci-bot -n cka-sa | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null; echo
```

解码中段 payload 能看到 `"system:serviceaccount:cka-sa:ci-bot"`（`sub` 字段）——API Server 就是从这里识别身份，再套用 RBAC 判定的。

</details>
