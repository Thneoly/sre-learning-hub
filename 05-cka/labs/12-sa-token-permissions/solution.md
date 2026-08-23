# Lab 12 · 解答：ServiceAccount Token 与权限验证

## 思路

SA 的身份链路：

```
Pod(挂载 token) ──> JWT(sub=system:serviceaccount:cka-sa:ci-bot)
                        │ API Server 认证(Authentication): 识别身份
                        ▼
                   RBAC 授权(Authorization): RoleBinding 命中 Role 规则才放行
```

1.24 起 SA 不再自动下发永久 token；`kubectl create token` 走 TokenRequest API 签发短期 JWT。本 lab 顺带验证一个安全常识：**token 本身不含任何权限**，权限完全由 RBAC 决定，所以"换个 token"不会越权，"绑错 Role"才会。

## 第 1 步：namespace 与 ServiceAccount

```bash
# [master]
kubectl create namespace cka-sa
kubectl -n cka-sa create serviceaccount ci-bot
```

验证：

```bash
# [master]
kubectl -n cka-sa get sa ci-bot
```

预期输出一行 `ci-bot   <age>`，且 **没有** `secrets` 列的旧式 token（1.24+ 的正常表现）。

## 第 2 步：Role ci-deployer

```bash
# [master]
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ci-deployer
  namespace: cka-sa
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "create", "update"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch", "create"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
EOF
```

要点：deployments 在 `apps` API 组，`apiGroups: ["apps"]`；写 `deployments.apps` 或漏写 apiGroup 都会导致规则不命中。

## 第 3 步：RoleBinding（SA 作为 subject）

```bash
# [master]
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-bot-deployer
  namespace: cka-sa
subjects:
- kind: ServiceAccount
  name: ci-bot
  namespace: cka-sa
roleRef:
  kind: Role
  name: ci-deployer
  apiGroup: rbac.authorization.k8s.io
EOF
```

与 lab 11 的区别：`kind: ServiceAccount` 且必须写 `namespace`。SA 是 namespace 级身份，跨 namespace 引用 SA 不会生效。

验证：

```bash
# [master]
kubectl -n cka-sa describe rolebinding ci-bot-deployer
```

预期 Subjects 段：

```
Subjects:
  Kind            Name     Namespace
  ----            ----     ---------
  ServiceAccount  ci-bot   cka-sa
```

## 第 4 步：impersonation 快速验证

```bash
# [master]
kubectl auth can-i create deployments.apps -n cka-sa --as=system:serviceaccount:cka-sa:ci-bot
# yes

kubectl auth can-i get nodes --as=system:serviceaccount:cka-sa:ci-bot
# no

kubectl auth can-i get pods -n default --as=system:serviceaccount:cka-sa:ci-bot
# no
```

`--as` 的取值就是 SA 的规范用户名 `system:serviceaccount:<ns>:<name>`，注意三段用冒号分隔。`can-i create deployments.apps` 用 `resource.group` 的写法指定 apps 组。

## 第 5 步：真实 token 调用 API Server

```bash
# [master]
TOKEN=$(kubectl create token ci-bot -n cka-sa)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')

# 只带 token 调用（域名内）
curl -sk -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/namespaces/cka-sa/pods"
# 200

# 集群级资源
curl -sk -o /dev/null -w "%{http_code}\n" -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/nodes"
# 403
```

为什么不用 `kubectl --token`：admin kubeconfig 的用户是**客户端证书**认证，`--token` 只是在请求上追加一个 bearer token，而 API Server 的认证器链里证书排在 token 前面，身份仍然是 `kubernetes-admin`——token 根本没被校验。想看 kubectl 的中文 Forbidden 报错，可以用一个不带证书的临时身份：

```bash
# [master]
KUBECONFIG=/dev/null kubectl --server="$APISERVER" --insecure-skip-tls-verify \
  --token="$TOKEN" get nodes
```

预期被拒：

```
Error from server (Forbidden): nodes is forbidden:
User "system:serviceaccount:cka-sa:ci-bot" cannot list resource "nodes" in API group ""
at the cluster scope
```

Forbidden 报错里会**明说**是哪个 User 在哪个资源上被拒——排障时这个报错就是最直接的证据。

顺带看一眼 JWT payload（选做）：

```bash
# [master]
kubectl create token ci-bot -n cka-sa | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null; echo
```

能看到 `"sub":"system:serviceaccount:cka-sa:ci-bot"` 与 `"exp"` 过期时间戳。

## 常见错误回顾

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| token 调用 401 Unauthorized | token 过期（默认 1h）或 `create token` 的 ns/name 拼错 | 重新签发，核对 `-n cka-sa ci-bot` |
| `kubectl --token` 后身份没变（还能 get nodes） | kubeconfig 走证书认证，API Server 优先校验证书，token 被忽略 | 用 curl 只带 token，或 `KUBECONFIG=/dev/null kubectl --token=...` |
| can-i yes 但真实调用 403 | impersonation 与真实身份不一致（如 `--as` 少了 `system:serviceaccount:` 前缀） | 用规范用户名重验 |
| deployments 操作 403 | Role 的 apiGroups 漏了 `apps` | 核对 rules 的 apiGroups |
| 想要长期 token | TokenRequest 只签短期 token | 创建 `kubernetes.io/service-account-token` 类型 Secret 并打标注 |

长期 token 的标准做法（供参考，本 lab 不要求）：

```bash
# [master]
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ci-bot-token
  namespace: cka-sa
  annotations:
    kubernetes.io/service-account.name: ci-bot
type: kubernetes.io/service-account-token
EOF
```

## check.sh 运行结果

```bash
# [master]
chmod 755 check.sh && ./check.sh
```

预期：

```
PASS: namespace cka-sa 存在
PASS: ServiceAccount ci-bot 存在于 cka-sa
PASS: Role ci-deployer 存在于 cka-sa
PASS: Role 规则覆盖 deployments(apps) 与 pods/pods/log
PASS: RoleBinding ci-bot-deployer 存在
PASS: RoleBinding 将 SA cka-sa/ci-bot 绑定到 ci-deployer
PASS: SA 可在 cka-sa 内 create deployments (can-i=yes)
PASS: SA 不能 get nodes (最小权限)
PASS: SA 在 default 内不能 get pods (namespace 隔离)
PASS: token 身份可在 cka-sa 内 get pods (真实调用 HTTP 200)
PASS: token 身份 get nodes 被拒绝 (HTTP 403)

SCORE: 11/11
```
