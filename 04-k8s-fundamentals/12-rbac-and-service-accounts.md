# 12 · RBAC 与 ServiceAccount：从"你是谁"到"你能做什么"

> 模块：04-k8s-fundamentals ｜ 建议时长：3 小时 ｜ 关联认证：CKA-安全·集群管理 / CKS-最小权限

## 学习目标

- 能根据 401 / 403 / 准入报错判断请求死在 apiserver 处理链的哪一环，并说出每一环使用的机制
- 能解释 Role 与 ClusterRole 的真正区别是"授权落在哪个作用域"而非"能管多少种资源"，并能预测 RoleBinding 引用 ClusterRole 时的实际效果
- 能写出 verbs / resources / apiGroups / resourceNames 四要素齐备的最小权限规则
- 能解释 1.24 前后 ServiceAccount token 机制的差异，并手工签发、解码、挂载 token
- 能用 kubectl auth can-i --as 与 --list 完成权限自测，不再靠"改了再试"

## 1. 请求全链路：认证 → 鉴权 → 准入

第 02 章画过 apiserver 的处理链，本章把前三环拆开——这三环恰好对应三类故障、三种报错：

```
# [图] apiserver 请求处理链(写请求为例)
 kubectl / client-go / kubelet / controller
        │ HTTPS(客户端证书 / Bearer JWT)
        ▼
 ┌───────────────────────────────────────────────────────────────┐
 │ ① Authentication 认证 —— 你是谁?                              │
 │    x509: CN→用户名, 每个 O→一个组                              │
 │    SA JWT: system:serviceaccount:<ns>:<sa名>                  │
 │    OIDC: IdP 签发的 id_token                                  │
 │    认证不通过 → 请求以 system:anonymous 身份继续(或被拒)         │
 │    失败报错: 401 Unauthorized                                  │
 ├───────────────────────────────────────────────────────────────┤
 │ ② Authorization 鉴权 —— 能不能做?                             │
 │    授权器链: Node → RBAC → Webhook(任一 Allow 即放行)          │
 │    判定输入: 用户 + verb + resource + apiGroup + namespace     │
 │    失败报错: 403 Forbidden                                     │
 ├───────────────────────────────────────────────────────────────┤
 │ ③ Admission 准入 —— 对象能不能长这样?(仅写请求)                │
 │    MutatingWebhook → 内置默认值/改写 → ValidatingWebhook       │
 │    失败报错: 带 "admission webhook ... denied the request"     │
 ├───────────────────────────────────────────────────────────────┤
 │ ④ Schema 校验 + 乐观并发 → 写入 etcd                           │
 │    失败报错: 422 Invalid / 409 Conflict                        │
 └───────────────────────────────────────────────────────────────┘
```

| 阶段 | 回答的问题 | 失败报错(特征) | 排障方向 |
| --- | --- | --- | --- |
| ① 认证 | 你是谁 | 401 / `You must be logged in to the server (Unauthorized)` | kubeconfig、token 过期、证书对不对 |
| ② 鉴权 | 能不能做 | 403 / `User "xxx" cannot <verb> resource ...` | RBAC 对象（本章主角） |
| ③ 准入 | 对象合不合法 | 400/403 带 `admission webhook` 字样 | 准入控制器/第三方 webhook，不是 RBAC |
| ④ 持久化 | 版本冲不冲突 | 409 Conflict / 422 | resourceVersion、字段校验 |

读请求只走 ①②；③ 只作用于写请求。这三环是**串行**的：认证过了才轮到鉴权，鉴权过了才轮到准入。排障时先归类报错属于哪一环，不要一上来就改 Role。

## 2. 认证：三种主流身份来源

| 方式 | 身份从哪来 | 典型使用者 | 要点 |
| --- | --- | --- | --- |
| x509 客户端证书 | 证书 Subject：CN = 用户名，O = 组（可多个） | kubeadm 的 admin.conf、kubelet 引导、组件间 mTLS | 证书本身不过期前一直有效；吊销只能靠删 RBAC 或换 CA |
| ServiceAccount token | apiserver 签发的 JWT（Bearer） | Pod 内进程、CI/CD | 用户名 `system:serviceaccount:<ns>:<name>`，见第 5 节 |
| OIDC | 企业 IdP（Keycloak/ADFS/Google）签发的 id_token | 人类用户 SSO | apiserver 配 `--oidc-issuer-url` 等，kubectl 侧用 oidc-login 插件换取 token |

kubeadm 集群里你每天在用的就是 x509：`admin.conf` 的证书身份是 `O=system:masters, CN=kubernetes-admin`。`system:masters` 是超级管理员组——它之所以万能，是被 `cluster-admin` 这个 ClusterRoleBinding 授权的（RBAC 层面，不是代码写死的）。

```bash
# [master] 从 kubeconfig 反查自己的 x509 身份
grep client-certificate-data ~/.kube/config | awk '{print $2}' | base64 -d \
  | openssl x509 -noout -subject
# 预期: subject=O = system:masters, CN = kubernetes-admin

# [master] 1.28+ 可直接问 apiserver "我是谁"(SelfSubjectReview)
kubectl auth whoami
# 预期: Attributes: Username: kubernetes-admin, Groups: system:masters, system:authenticated
```

OIDC 只需建立概念：人类用公司账号登录 IdP → IdP 发 id_token → kubectl 把它作为 Bearer 发给 apiserver → apiserver 用 IdP 的公钥验签，token 里的 `sub`/`groups` 映射成 K8s 用户和组。配置细节在 CKS/生产加固时再展开。

## 3. RBAC 四对象：作用域才是重点

四个对象，两两配对：

```
# [图] 权限 = 规则(Rules) × 作用域(Binding 决定)
 ClusterRole X  [rules: get/list pods]          Role Y  [ns=dev, rules: delete pods]
      │                                              │
      ├── ClusterRoleBinding ──► 全集群生效            │
      │                                              │
      └── RoleBinding(ns=dev) ──► 只在 dev 生效 ◄─────┘(RoleBinding 引用同 ns 的 Role)

 判定: 遍历该用户/组/SA 命中的所有 Binding, 全部规则求并集;
       RBAC 只有 Allow 没有 Deny —— 权限只增不减
```

**Role 与 ClusterRole 的真正区别不是"资源范围"，而是"被绑定时授权能落到哪个作用域"：**

- `Role` 是名字空间内的对象，规则**只能**通过同 ns 的 RoleBinding 生效，授权半径永远是一个 namespace；
- `ClusterRole` 是集群级对象，有两副面孔：被 ClusterRoleBinding 引用时全集群生效；被 RoleBinding 引用时**只在那个 namespace 生效**。

四种组合一次说清：

| 角色 | 绑定 | 实际效果 |
| --- | --- | --- |
| Role | RoleBinding（同 ns） | 该 ns 内生效（标准用法） |
| ClusterRole | ClusterRoleBinding | 全集群生效（标准用法） |
| ClusterRole | RoleBinding | **仅 RoleBinding 所在 ns 生效**（复用场景，见下） |
| Role | ClusterRoleBinding | 不允许：RoleBinding 只能引用同 ns 的 Role，ClusterRoleBinding 只能引用 ClusterRole |

### 3.1 RoleBinding 引用 ClusterRole：微妙在哪

这是 RBAC 最容易答错的一分。语义只有一句：**授权的作用域由 Binding 决定，与 Role 对象是 Role 还是 ClusterRole 无关**。

- 设计动机是**复用**：内置的 `view`、`edit`、`system:controller:xxx` 都是 ClusterRole。想让 dev 团队只在自己 ns 里拥有只读权限，给 `view` 挂一个 ns 级的 RoleBinding 即可，不必每个 ns 抄一份 Role。
- 常见误解："把 ClusterRole 绑到 RoleBinding 就能获得全集群权限"——错，权限被压进那一个 ns。
- 反向坑：往 Role 里写集群级资源（nodes、PV、CSRB）是无效授权——请求 nodes 这类非命名空间资源时，RBAC 只看 ClusterRoleBinding，RoleBinding 根本不参与判定。

```bash
# [master] 亲眼验证两种绑定的差别(只读观察, 不改动)
kubectl get clusterrole view -o jsonpath='{.rules}' | head -c 200; echo
kubectl get rolebinding -A | head -5
# 找一条 subjects 指向某个 SA/Group 且引用 clusterrole/view 的 RoleBinding,
# 对应主体 can-i get nodes 必然是 no —— 这就是"作用域由 Binding 决定"
```

另外两个全局规则：**没有 Deny**（要"允许一切除了 delete"必须上 OPA/Kyverno 这类准入层，RBAC 表达不了）；**ClusterRole 可聚合**（`aggregationRule` 让 `view`/`edit` 自动合并其他带标签的 ClusterRole，自定义资源权限就是这么进内置角色的）。

## 4. 规则解剖：verbs / resources / apiGroups

一条 rule 由三个列表（加可选的 resourceNames）构成，三者的笛卡尔积就是授权的动作集合。

### 4.1 verbs 全表

| verb | 对应 HTTP | 说明 |
| --- | --- | --- |
| get | GET（单个对象） | 读单对象；配合 resourceNames 可精确到某几个名字 |
| list | GET（集合） | 列表/分页遍历 |
| watch | GET + `?watch=true` | 流式订阅；与 list 是两个独立 verb，只给 watch 不给 list 也能跑 |
| create | POST | 创建 |
| update | PUT | 全量替换对象 |
| patch | PATCH | 增量合并（strategic/merge/json 三种类型） |
| delete | DELETE（单个） | 删除单对象 |
| deletecollection | DELETE（集合） | `kubectl delete pods --all` 走这个 |

三个特殊 verb（CKS 常考）：`bind`（允许把高权限角色绑给别人）、`escalate`（允许授权超出自己已有的权限）、`impersonate`（允许模拟其他用户，`--as` 的权限来源）。RBAC 自身的角色/绑定对象同时受普通 verb 和这三个"元权限"约束。

### 4.2 resources（含 subresource）

普通资源直接写复数：`pods`、`deployments`、`secrets`。**subresource 用 `父资源/子资源` 表示**，不写就不会被隐式授予：

| subresource | 谁在用 |
| --- | --- |
| pods/log | kubectl logs |
| pods/exec | kubectl exec |
| pods/portforward | kubectl port-forward |
| pods/attach | terminal 附加到容器 stdin |
| deployments/scale | kubectl scale / HPA |
| deployments/status、nodes/status | 状态子资源（controller 回写用） |
| serviceaccounts/token | kubectl create token |

`resourceNames` 把授权收窄到具体对象名（只对 get/update/patch/delete 这类"点名"操作有效，对 list/watch/create 无意义）。

### 4.3 apiGroups 速查

| apiGroups | 包含的常见资源 |
| --- | --- |
| `""`（core 组） | pods、services、nodes、namespaces、configmaps、secrets、serviceaccounts、pv、events、endpoints |
| `apps` | deployments、replicasets、statefulsets、daemonsets |
| `batch` | jobs、cronjobs |
| `networking.k8s.io` | ingresses、networkpolicies |
| `rbac.authorization.k8s.io` | roles、rolebindings、clusterroles、clusterrolebindings |
| `storage.k8s.io` | storageclasses、csidrivers、volumeattachments |
| `policy` | poddisruptionbudgets |
| `apiextensions.k8s.io` | customresourcedefinitions |
| `metrics.k8s.io` | 聚合出来的资源指标 API（kubectl top，见第 14 章） |

### 4.4 组装一个最小权限 Role

```yaml
# [master] kubectl apply -f - <<'EOF' —— CI 只读部署与日志
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deploy-reader
  namespace: dev
rules:
- apiGroups: ["apps"]            # apps 组
  resources: ["deployments"]     # 仅 deployments
  verbs: ["get", "list", "watch"]
- apiGroups: [""]                # core 组
  resources: ["pods", "pods/log"]
  verbs: ["get", "list"]         # kubectl logs 需要 pods/log 的 get
EOF
```

```yaml
# [master] kubectl apply -f - <<'EOF' —— 把它授给 ServiceAccount
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-bot-read
  namespace: dev
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: deploy-reader
subjects:
- kind: ServiceAccount
  name: ci-bot
  namespace: dev
EOF
```

## 5. ServiceAccount 与 token 的变迁

SA 是"给进程用的账号"。token 机制按版本分三个阶段：

| 版本 | 行为 |
| --- | --- |
| ≤ 1.20 | 每个 SA 自动生成一个 Secret，内含**永不过期**的 token |
| 1.21 ~ 1.23 | Pod 默认改挂 TokenRequest 签发的**投影 token**（短时、自动刷新）；仍会自动生成 legacy Secret |
| ≥ 1.24 | **不再自动生成 Secret**；Pod 里挂的全部是短时投影 token；永久 token 只能手工创建 |

投影 token 的关键属性：audience 是 apiserver、默认有效期约 1 小时、kubelet 在到期前自动用 TokenRequest API 换新——所以长跑 Pod 永远拿着有效 token，而落盘的 token 泄漏后也只值一小时。挂载路径固定为 `/var/run/secrets/kubernetes.io/serviceaccount/`（`token`、`ca.crt`、`namespace` 三件套）。Pod 不需要 API 权限时显式关掉：`automountServiceAccountToken: false`（SA 上设置可对整个 ns 生效，SA 级优先于 Pod 级）。

```bash
# [master] 1.24+ 集群: 新建 SA 不再自带 Secret
kubectl create namespace dev
kubectl create serviceaccount ci-bot -n dev
kubectl get sa ci-bot -n dev -o jsonpath='{.secrets}'; echo
# 预期: 空输出(老集群则会显示一个 token Secret 名)

# [master] 现签一个 10 分钟的短时 token(不落盘)
kubectl create token ci-bot -n dev --duration=10m

# [master] 手工创建永久 token(只给无法自动刷新的旧系统/外部 CI)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: ci-bot-token
  namespace: dev
  annotations:
    kubernetes.io/service-account.name: ci-bot
type: kubernetes.io/service-account-token
EOF
```

解码 JWT 能直接看到"非永久"的证据（`exp` 字段）：

```bash
# [master] 查看 token 载荷: iss/aud/sub/exp
TOKEN=$(kubectl create token ci-bot -n dev --duration=10m)
python3 -c 'import sys,json,base64; p=sys.argv[1].split(".")[1]; p+="="*(-len(p)%4); print(json.dumps(json.loads(base64.urlsafe_b64decode(p)),indent=2))' "$TOKEN"
# 预期: "iss": "https://kubernetes.default.svc.cluster.local",
#       "sub": "system:serviceaccount:dev:ci-bot", "aud": ["kubernetes"], "exp": <10 分钟后>
```

## 6. kubectl auth can-i：不猜，直接问

权限调试的正道是把问题抛给 apiserver 的鉴权器，而不是改一版 YAML 再跑一次：

```bash
# [master] 1. 问自己
kubectl auth can-i create deployments -n dev
# 预期: yes(你是 system:masters)

# [master] 2. 模拟别的身份(--as, 底层是 impersonation)
kubectl auth can-i list pods -n dev --as=system:serviceaccount:dev:ci-bot
# 预期: no(第 5 节刚建的 SA 还没绑定任何角色)

# [master] 3. 模拟某个组(--as-group, 可多次)
kubectl auth can-i get nodes --as=dev-lead --as-group=dev-readers

# [master] 4. 一次列全: 该身份在该 ns 的完整权限矩阵
kubectl auth can-i --list -n dev --as=system:serviceaccount:dev:ci-bot
# 预期: 表格列出可访问的 resources 与 verbs; 未授权时只有自察类权限

# [master] 5. 通配检查
kubectl auth can-i '*' '*' --as=system:serviceaccount:dev:ci-bot
# 预期: no
```

两点提醒：`--as` 走 impersonation，当前用户需要 `impersonate` 权限（admin 有，普通用户没有——所以普通用户只能测自己）；`can-i` 的判定与真实请求走同一条 RBAC 代码路径，它说 no 就是真 no。

## 7. 报错解读：拆开一条 Forbidden

```
# [图] Forbidden 报错的五要素
Error from server (Forbidden): pods is forbidden:
User "system:serviceaccount:dev:default"  cannot list resource "pods"
└──────────── 身份(是谁) ─────────────────┘         └─ verb ─┘ └ 资源 ─┘
in API group ""  in the namespace "dev"
└── apiGroup ──┘ └──── namespace ────┘
```

五要素齐了，缺什么补什么：身份对不对（是不是用了 default SA）、verb 对不对（要 list 只给 get）、resource 是否带 subresource、apiGroup 是否漏写、namespace 是否写错。

| 报错原文（截选） | 真实含义 | 修法 |
| --- | --- | --- |
| `error: You must be logged in to the server (Unauthorized)` | 401 认证失败：token 过期/证书错/kubeconfig 指向错集群 | 换 token、重新生成 kubeconfig；与 RBAC 无关 |
| `User "system:serviceaccount:dev:default" cannot list resource "pods" ...` | default SA 没有任何权限（默认即如此） | 建 Role + RoleBinding 绑给对应 SA |
| `pods/exec is forbidden: User "..." cannot create resource "pods/exec" ...` | exec 是 subresource 且 verb 是 create | resources 加 `pods/exec`，verbs 加 `create` |
| `cannot create resource "deployments" in API group "apps" in the namespace "dev"` | 缺 apps 组的 create | apiGroups 加 `apps` |
| `admission webhook "xxx.example.com" denied the request: ...` | 不是 RBAC！请求死在准入 | 查 webhook 服务与策略 |
| `User "a" cannot impersonate user "b"` | --as 的发起者没有 impersonate 权限 | 给发起者授权 impersonate，或换 admin 测 |

## 实战演练

目标：从零体验"403 → 授权 → 200"的完整闭环。在 master 上执行。

```bash
# [master] 步骤 1: 未授权状态 —— 两种方式确认"没有权限"
#   (前置: 第 5 节已创建 ns dev 与 SA ci-bot; 下面两条幂等, 重跑无害)
kubectl create namespace dev --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount ci-bot -n dev --dry-run=client -o yaml | kubectl apply -f -
kubectl auth can-i list pods -n dev --as=system:serviceaccount:dev:ci-bot
# 预期: no

TOKEN=$(kubectl create token ci-bot -n dev --duration=10m)
curl -s --cacert /etc/kubernetes/pki/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://127.0.0.1:6443/api/v1/namespaces/dev/pods | head -c 200; echo
# 预期: {"kind":"Status",...,"code":403,...,"reason":"Forbidden"...}
```

```bash
# [master] 步骤 2: 下发第 4.4 节的 Role 与 RoleBinding(整段重贴, 保证演练自包含)
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deploy-reader
  namespace: dev
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods", "pods/log"]
  verbs: ["get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ci-bot-read
  namespace: dev
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: deploy-reader
subjects:
- kind: ServiceAccount
  name: ci-bot
  namespace: dev
EOF
# 预期: role.rbac.authorization.k8s.io/deploy-reader created + rolebinding... created

# [master] 步骤 2b: 复核权限矩阵
kubectl auth can-i --list -n dev --as=system:serviceaccount:dev:ci-bot
# 预期: 出现 pods 与 deployments 的只读行

kubectl auth can-i list deployments -n dev --as=system:serviceaccount:dev:ci-bot
# 预期: yes

# [master] 步骤 3: 同一个 token 再请求一次
curl -s --cacert /etc/kubernetes/pki/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://127.0.0.1:6443/api/v1/namespaces/dev/pods | head -c 120; echo
# 预期: {"kind":"PodList","apiVersion":"v1","metadata":{...},  "items":[]} —— 200

# [master] 步骤 4: 越界验证(改问别的 ns, 应当还是 403)
curl -s --cacert /etc/kubernetes/pki/ca.crt \
  -H "Authorization: Bearer $TOKEN" \
  https://127.0.0.1:6443/api/v1/namespaces/default/pods | grep -o '"code":[0-9]*'
# 预期: "code":403 —— RoleBinding 的作用域没跑偏

# [master] 步骤 5: 走进 Pod 看投影 token 三件套
kubectl -n dev run probe --image=busybox:1.36 --restart=Never --rm -it -- sh -c \
  'ls /var/run/secrets/kubernetes.io/serviceaccount/ && cut -c1-40 /var/run/secrets/kubernetes.io/serviceaccount/token; echo'
# 预期: ca.crt namespace token 三行 + token 前 40 字符(ey 开头的 JWT 头)

# [master] 步骤 6: 清理
kubectl delete namespace dev
```

验证标准即每步"预期"。若步骤 3 仍 403，用 `kubectl get rolebinding -n dev -o yaml` 检查 roleRef 与 subjects 的 namespace 字段。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| Pod 内调 API 报 403 | 用的是 default SA，零权限 | 建专用 SA + RoleBinding，Pod 里显式 `serviceAccountName` |
| 老脚本 `kubectl get sa -o yaml` 拿不到 token Secret | 1.24+ 不再自动生成 | `kubectl create token`（短时）或手工建带注解的 Secret（永久） |
| 给了 pods 的 get 仍 kubectl logs 失败 | logs 走 pods/log subresource | resources 写 `pods/log` |
| "RoleBinding 绑 ClusterRole 后全集群可用"的预期落空 | 作用域由 Binding 决定 | 要全集群就上 ClusterRoleBinding |
| 升级后 Pod 无法访问 API | 投影 token 到期但 kubelet 换新失败（常见于 apiserver 长时间不可用） | 恢复 apiserver 后重启受影响 Pod |
| `--as` 报 cannot impersonate | 发起者没有 impersonate 权限 | 用 admin 发起，或先授 impersonate |
| 把允许写进 Role 期望"排除法" | RBAC 没有 Deny | 改用准入控制（OPA/Kyverno） |

## 自测

1. 为什么 `system:masters` 组拥有全部权限？如果把 `cluster-admin` 这个 ClusterRoleBinding 删掉，会发生什么、怎么恢复？

<details><summary>答案</summary>

`system:masters` 的全能来自 `cluster-admin` ClusterRoleBinding 把 `cluster-admin` ClusterRole（`*:*`）绑给了这个组——是 RBAC 授权，不是硬编码。删掉它之后，所有靠证书 O=system:masters 进来的请求（包括 admin.conf）全部 403，apiserver 本身还在跑但 kubectl 失能。恢复必须绕过 API：用 etcdctl 直接把对象写回 etcd，或用其他未被回收权限的身份。这也是 CKS 强调"保护好 /etc/kubernetes/pki 和 etcd 访问权"的原因——它们的权限在 RBAC 之外。
</details>

2. 一个 ClusterRole 的规则里写了 `nodes` 和 `pods`，分别通过 RoleBinding（ns=dev）和 ClusterRoleBinding 各绑一次。最终用户能 get node 吗？能 delete 哪些 ns 的 pod？

<details><summary>答案</summary>

node 是集群级资源，RBAC 判定时只看 ClusterRoleBinding——该用户没有 ClusterRoleBinding 便不能 get node（写进 ClusterRole 的 nodes 规则只是"备而未用"）。pod 的 delete 权限来自 RoleBinding，作用域是 dev，所以只能 delete dev 里的 pod。一句话：规则决定"能做什么动作"，Binding 决定"作用域落在哪"，两者相乘才是最终权限。
</details>

3. 为什么 `kubectl logs` 需要的是 `pods/log` 的 `get`，而 `kubectl exec` 需要的是 `pods/exec` 的 `create`？这对写最小权限有什么提示？

<details><summary>答案</summary>

subresource 的 verb 映射的是底层 HTTP 语义：logs 是读取已有数据（GET），exec 是在服务端"创建"一条流式连接（POST/SPDY upgrade 语义上属 create）。提示：给权限前先想清楚动作对应哪个 subresource、哪个 verb，别顺手写 `verbs: ["*"]`；用 `kubectl auth can-i --as` 先验证再下发。
</details>

4. 1.24+ 的 Pod 拿到的 token 约 1 小时就过期，为什么一个跑了半年的 Pod 还能正常访问 apiserver？这个机制失效的典型场景是什么？

<details><summary>答案</summary>

token 是 kubelet 通过 TokenRequest API 签发的投影卷，kubelet 监测有效期并在到期前自动换新（ProjectedVolumeToken 热更新）。失效典型场景：apiserver 长时间不可用导致换新失败，token 真正过期后 Pod 内调用开始 401；apiserver 恢复后重启 Pod 即可。这也解释了"永久 token"只应留给无法配合刷新的外部系统。
</details>

5. 安全团队要求"dev 组可以操作 dev ns 的一切，但不能 RBAC 相关对象"。只用 RBAC 怎么实现？如果要求"可以删 Pod 但不能删 Secret"之外的更复杂排除逻辑呢？

<details><summary>答案</summary>

把内置 `admin` ClusterRole 用 ns 级 RoleBinding 绑给 dev 组（复用语义，权限只落在 dev），它本就不含 RBAC 对象的写权限。RBAC 只有 Allow 没有 Deny，表达不了"除了 X 都允许"的任意排除逻辑；更复杂的策略要上 ValidatingAdmissionPolicy、OPA Gatekeeper 或 Kyverno 这类准入层。
</details>

## 延伸阅读

- Using RBAC Authorization：https://kubernetes.io/docs/reference/access-authn-authz/rbac/
- Authorization Overview（含 can-i）：https://kubernetes.io/docs/reference/access-authn-authz/authorization/
- Authenticating：https://kubernetes.io/docs/reference/access-authn-authz/authentication/
- ServiceAccount 安全与 token 卷投影：https://kubernetes.io/docs/concepts/security/service-account-security/
- kubectl create token / 组织集群访问：https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
