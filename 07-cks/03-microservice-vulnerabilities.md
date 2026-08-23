# 03 · 微服务漏洞最小化：PSA、RBAC 收权、SA token 与 NetworkPolicy 分层

> 模块：CKS 备考 ｜ 建议时长：3 小时 ｜ 关联认证：CKS-Minimize Microservice Vulnerabilities / CKA-RBAC

## 学习目标

- 能解释 Pod Security Admission 的三个 level 与三个 mode，并用 namespace label 落地
- 能用一条命令链识别集群里的过度权限 RBAC 并收敛为最小 Role
- 能说明 automountServiceAccountToken 的作用域并验证 token 不再被挂载
- 能设计"先全禁、再按需开"的 NetworkPolicy 分层并验证连通性

## 1. 纵深防御：四个互相独立的闸门

一个微服务 Pod 的暴露面由四层控制，任何一层失守，其他层仍能兜底：

```
入口流量 ──> NetworkPolicy（谁能连我 / 我能连谁）
             │
             v
        Pod 安全基线（PSA：privileged? hostPID? capabilities?）
             │
             v
        Pod 内凭证（SA token 是否自动挂载、RBAC 权限多大）
             │
             v
        出口流量 ──> NetworkPolicy（egress）+ API 访问审计
```

CKS 这一域占 20%，考法通常是：给一个"危险现状"（default SA 有大权限、namespace 无 PSA、无 NetworkPolicy），让你逐层修好。

## 2. Pod Security Admission（PSA）

### 2.1 三个 level 与三个 mode

PSA 是内置 admission controller（1.25 GA），取代已删除的 PodSecurityPolicy。它按 namespace 的 label 决定对 Pod 的管控。

Level（管多严）：

| level | 含义 | 禁止的典型字段 |
| --- | --- | --- |
| `privileged` | 不限制 | —— |
| `baseline` | 阻止已知的越权提权 | hostNetwork/hostPID/hostIPC、hostPath、privileged: true、多数 capabilities、hostPort |
| `restricted` | 当前最佳实践基线 | baseline 全部＋必须 runAsNonRoot、drop ALL capabilities（仅可加 NET_BIND_SERVICE）、必须 seccompProfile RuntimeDefault/Localhost、限制卷类型 |

Mode（以什么姿态管）：

| mode | 行为 |
| --- | --- |
| `enforce` | 违规 Pod 直接拒绝创建 |
| `audit` | 允许创建，但在 audit log 里记违规（配 05 篇的审计） |
| `warn` | 允许创建，但 kubectl 向用户回显警告 |

### 2.2 namespace label 落地与版本映射

标签格式：`pod-security.kubernetes.io/<mode>[-version]=<level>`，共 6 个 label：

```bash
# [master]
kubectl create namespace payment
kubectl label --overwrite namespace payment \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.29 \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/audit-version=v1.29 \
  pod-security.kubernetes.io/warn=restricted \
  pod-security.kubernetes.io/warn-version=v1.29

kubectl describe namespace payment | grep -A6 'Labels:'
```

版本映射规则（重要）：

- `enforce-version=v1.29` 表示"按 Kubernetes v1.29 时点的 restricted 定义来检查"。标准是随版本演进的（例如 seccompProfile 要求就是 v1.25 起 restricted 的一部分），钉住版本可避免集群升级后一夜之间大量 Pod 违规
- 不写 version 或写 `latest`，等于用** apiserver 当前版本**的定义
- 钉到比 v1.25 更早的版本时，restricted/baseline 会向上取到 v1.25 定义（PSA GA 起点）

### 2.3 体验三个 mode 的差别

```bash
# [master] 违规 Pod：privileged + root + hostNetwork
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
  namespace: payment
spec:
  hostNetwork: true
  containers:
    - name: main
      image: busybox:1.36
      command: ["sleep", "3600"]
      securityContext:
        privileged: true
EOF
# 预期: Error from server (Forbidden): ... violates PodSecurity "restricted:v1.29":
#        hostNamespaceNetworking, privileged, runAsNonRootPolicy, ...
```

把 enforce 临时摘掉、只留 warn，再建一次会看到 Pod 创建成功但终端打印 warning。audit 违规则出现在 audit log（policy 需覆盖 Pod 写操作，见 05 篇）。

### 2.4 apiserver 级默认与豁免

PSA 自身的默认行为可以用 `--admission-control-config-file` 配置（例如给未打 label 的 namespace 定基线、豁免系统 namespace）：

```yaml
# [master] /etc/kubernetes/admission-config.yaml（挂载方式见 04 篇 admission 链）
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      apiVersion: pod-security.admission.config.k8s.io/v1
      kind: PodSecurityConfiguration
      defaults:
        enforce: "privileged"
        enforce-version: "latest"
        audit: "privileged"
        audit-version: "latest"
        warn: "privileged"
        warn-version: "latest"
      exemptions:
        usernames: []
        runtimeClasses: []
        namespaces: [kube-system]
```

生产建议：未打 label 的 namespace 默认值收紧到 baseline，并对 kube-system 等系统 namespace 显式豁免。

## 3. 识别并收敛过度权限 RBAC

### 3.1 三个高信号检查点

1. 通配符权限：`verbs: ["*"]`、`resources: ["*"]`、`apiGroups: ["*"]`
2. 危险动词：`escalate`（改自己的 Role 提权）、`bind`（把高权限 ClusterRole 绑给自己）、`impersonate`（冒充别人）
3. 高价值资源：`secrets`（读全集群 Secret）、`nodes/proxy`（通过 apiserver 打到任意节点 kubelet）、`pods/exec`（任意容器内执行命令）

```bash
# [master] 找出含通配符的 ClusterRole
kubectl get clusterrole -o json \
  | jq -r '.items[] | select(.rules[]? | ((.verbs // [])|index("*")) or ((.resources // [])|index("*"))) | .metadata.name'

# [master] 找出对 secrets 有读权限的 ClusterRole（去掉 ResourceQuota/系统只读角色再人工审）
kubectl get clusterrole -o json \
  | jq -r '.items[] | select(.rules[]? | ((.resources // [])|index("secrets")) and (((.verbs // [])|index("get")) or ((.verbs // [])|index("list")) or ((.verbs // [])|index("watch")))) | .metadata.name'

# [master] 模拟某个 ServiceAccount，列出它的全部权限
kubectl auth can-i --list --as=system:serviceaccount:dev:default -n dev
```

### 3.2 一个收敛案例

现状：dev namespace 的 default SA 通过某 RoleBinding 拿到了 `pods/exec`＋`secrets get` 的 ClusterRole。业务其实只需要"读自己 namespace 的 ConfigMap"。

```bash
# [master] 先找到是谁给的权限
kubectl get rolebinding,clusterrolebinding -A -o wide | grep -i system:serviceaccount:dev

# [master] 建最小 Role
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: configmap-reader
  namespace: dev
rules:
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
EOF
kubectl create rolebinding configmap-reader-binding \
  --role=configmap-reader --serviceaccount=dev:default -n dev --dry-run=client -o yaml | kubectl apply -f -

# [master] 删除旧的过度绑定（OLD_BINDING 换成上一步查到的实际名字）
OLD_BINDING=overpowered-binding
kubectl delete clusterrolebinding "$OLD_BINDING"

# [master] 验证：权限清单变短，且敏感动词为 no
kubectl auth can-i --list --as=system:serviceaccount:dev:default -n dev
kubectl auth can-i create pods/exec --as=system:serviceaccount:dev:default -n dev
# 预期: no
```

细节提醒：RoleBinding 引用 ClusterRole 时，ClusterRole 的权限只在**该 namespace 内**生效——这既是收权手段，也常被误当成"全局权限"造成误判，审查时以 `kubectl auth can-i --list --as=...` 的实际结果为准。

## 4. ServiceAccount token：默认不挂载

每个 Pod 默认自动挂载其 SA 的 token（`/var/run/secrets/kubernetes.io/serviceaccount/`）。容器被 RCE 后，攻击者拿到的第一件武器就是这个 token。绝大多数业务根本不需要访问 Kubernetes API，应当默认关闭：

```yaml
# [master] SA 级关闭（对该 SA 的所有 Pod 生效）
apiVersion: v1
kind: ServiceAccount
metadata:
  name: webapp
  namespace: payment
automountServiceAccountToken: false
```

```yaml
# [master] 单 Pod 级覆盖（spec 级字段，优先级高于 SA）
apiVersion: v1
kind: Pod
metadata:
  name: no-token
  namespace: payment
spec:
  serviceAccountName: webapp
  automountServiceAccountToken: false
  containers:
    - name: main
      image: busybox:1.36
      command: ["sleep", "3600"]
```

验证挂载点消失：

```bash
# [master]
kubectl exec no-token -- ls /var/run/secrets/kubernetes.io/serviceaccount 2>&1 || echo "OK: token not mounted"
# 预期: ls 报 No such file or directory，随后打印 OK
```

确需访问 API 的组件，用 TokenRequest 的 projected token（带 audience、限时、可轮换）代替长效 Secret 型 token：

```yaml
# [master] 需要调 API 的 Pod：显式声明短期 token 卷
apiVersion: v1
kind: Pod
metadata:
  name: api-client
  namespace: payment
spec:
  automountServiceAccountToken: false
  containers:
    - name: main
      image: busybox:1.36
      command: ["sleep", "3600"]
      volumeMounts:
        - name: api-token
          mountPath: /var/run/secrets/tokens
  volumes:
    - name: api-token
      projected:
        sources:
          - serviceAccountToken:
              audience: api-client
              expirationSeconds: 3600
              path: token
```

default SA 的治理：新建 namespace 后 `default` SA 依旧存在且可被挂载，做法是对其关闭 automount，并禁止业务用 default SA 部署（配合 RBAC 让 default SA 没有任何权限）。

## 5. NetworkPolicy：先全禁，再按需开

### 5.1 语义要点

- NetworkPolicy 是**加法**：多条 policy 对一个 Pod 取并集，"允许的并集"之外全拒
- `podSelector: {}` 选中 namespace 内**全部 Pod**——这是默认拒绝的标准写法
- 没有任何 policy 选中某 Pod 时，该 Pod 流量不受限（Calico/kubeadm 默认如此）
- policy 一旦选中某 Pod 的某方向（ingress/egress），该方向即进入白名单模式

### 5.2 分层设计

```
L0  default-deny-all      全 namespace：ingress+egress 全禁（兜底，先上）
L1  allow-dns             放开到 kube-system/CoreDNS 的 53/UDP+TCP
L2  allow-same-ns         同 namespace 指定端口互通（或加 label 细化到服务对）
L3  allow-cross-ns        跨 namespace 白名单（frontend ns -> payment ns:8080）
L4  allow-egress-internet 按需放外网（IP 段/CIDR）
```

L0（打底，必须最先存在）：

```yaml
# [master] kubectl apply -f
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payment
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

L1（DNS 不放开，服务发现全瘫）：

```yaml
# [master] kubectl apply -f
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: payment
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

注意同一 `to` 条目里 `namespaceSelector` 与 `podSelector` 是**与**关系（kube-system 里带 `k8s-app=kube-dns` 的 Pod）；写成两个并列条目就变成了"或"，会把整个 kube-system 都放开。

L2（同 namespace 互通，8080 为例）：

```yaml
# [master] kubectl apply -f
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-same-ns-8080
  namespace: payment
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector: {}
      ports:
        - protocol: TCP
          port: 8080
```

L3（跨 namespace 白名单）：

```yaml
# [master] kubectl apply -f
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-frontend
  namespace: payment
spec:
  podSelector:
    matchLabels:
      app: payment-api
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: frontend
      ports:
        - protocol: TCP
          port: 8080
```

### 5.3 验证方法（考题必查）

```bash
# [master] 造两个测试 Pod
kubectl run np-test --image=busybox:1.36 -n payment --restart=Never -- sleep 3600
kubectl run np-outside --image=busybox:1.36 -n default --restart=Never -- sleep 3600

# 同 namespace 应能通 8080（payment-api 存在时）
kubectl exec np-test -n payment -- nc -zv -w3 payment-api 8080 2>&1 | tail -1

# 跨 namespace 未在白名单，应超时
kubectl exec np-outside -n default -- nc -zv -w3 payment-api.payment.svc.cluster.local 8080 2>&1 | tail -1
# 预期: 超时（open ... timed out）
```

策略校验小技巧：`kubectl get networkpolicy -n payment -o yaml | grep -c policyTypes` 快速确认 L0 覆盖了两个方向。

## 实战演练：把一个"裸奔"namespace 修成纵深防御

初始状态：namespace `payment` 无 PSA label、无 NetworkPolicy，业务 Pod 用 default SA 且 token 自动挂载。

```bash
# [master] Step1 打 PSA label（见 2.2，先 audit/warn 观察一轮再 enforce 也行）

# [master] Step2 业务 SA 关 token 自动挂载并换掉 default
kubectl patch serviceaccount default -n payment -p '{"automountServiceAccountToken": false}'
kubectl set serviceaccount deployment/payment-api webapp -n payment
kubectl rollout status deployment/payment-api -n payment

# [master] Step3 验证 token 未挂载
TOKENPOD=$(kubectl get pod -n payment -l app=payment-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n payment $TOKENPOD -- ls /var/run/secrets/kubernetes.io/serviceaccount 2>&1 || echo OK

# [master] Step4 依次 apply L0/L1/L2/L3 四条 policy，然后跑 5.3 的连通性验证

# [master] Step5 确认 RBAC 无多余权限
kubectl auth can-i --list --as=system:serviceaccount:payment:webapp -n payment
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| PSA label 打了却不生效 | label 打在 Pod 上而不是 namespace 上；或拼错 key | PSA 只认 namespace 的 `pod-security.kubernetes.io/*` label；`kubectl get ns payment --show-labels` 核对 |
| enforce=restricted 后大量 Pod 报 runAsNonRootPolicy | 镜像默认 root 且未声明 runAsNonRoot | 给容器加 `securityContext.runAsNonRoot: true` 与非 0 的 `runAsUser`，或换 nonroot 镜像 |
| default-deny 后 DNS 全挂 | L1 的 DNS egress 没放开，或 CoreDNS selector/label 不匹配 | 检查 `kubectl get pods -n kube-system -l k8s-app=kube-dns`；53 端口 UDP/TCP 都要放 |
| NetworkPolicy 似乎完全无效 | CNI 没就绪/不支持（如集群只有 flannel 早期版本）或 policy 未选中目标 Pod | 确认 Calico 已就绪；`kubectl describe networkpolicy -n payment` 看 podSelector 是否命中 |
| automountServiceAccountToken 改了 Pod 里还有 token | 旧 Pod 没重建，或 Pod 级显式 true 覆盖了 SA 级 false | 滚动重启；Pod 级字段优先级最高，删掉显式 true |
| `kubectl auth can-i --list` 显示权限与 Role 定义不一致 | 经过 group（system:authenticated）或 ClusterRoleBinding 生效 | 用 `kubectl auth can-i <verb> <resource> --as=...` 针对性确认，再排查 binding 链 |

## 自测

1. 为什么推荐"enforce 用 restricted 而 audit/warn 同时开 audit=restricted"？迁移期三种 mode 怎么排布？

<details><summary>答案</summary>

先 warn+audit（或 enforce=baseline）观察存量违规，再收紧 enforce。三 mode 并行时：enforce 保证新 Pod 达标，warn 把隐患即时反馈给开发者，audit 把违规留痕到 audit log 供平台侧统计，三者互不替代。生产常见路径：warn/audit=restricted 上线 → 修完存量 → enforce=restricted。
</details>

2. `podSelector: {}` 在 NetworkPolicy 的 spec 位置不同（spec 级 vs ingress.from 里）含义分别是什么？

<details><summary>答案</summary>

spec 级 `podSelector: {}` 表示该 policy 作用于 namespace 内所有 Pod（做默认拒绝）；ingress.from 里的 `podSelector: {}` 表示允许"同 namespace 内所有 Pod"作为来源。前者是作用域，后者是同类筛选，位置决定语义。
</details>

3. 某业务 Pod 被打穿后攻击者拿到了 token，但 `kubectl get secrets -n payment` 仍被拒。哪些设计在起作用？

<details><summary>答案</summary>

automountServiceAccountToken=false 使常规业务 Pod 根本没有 token（拿到说明例外组件）；即使有 token，RBAC 只给了最小权限（无 secrets 读取）；NetworkPolicy 的 egress 限制还可能直接挡掉它对 apiserver 的出站访问——多层防御各自独立生效。
</details>

4. RoleBinding 引用 ClusterRole，管理员认为"只是 namespace 级权限"，为什么会出安全事故？

<details><summary>答案</summary>

权限收敛到 namespace 内没错，但若该 ClusterRole 里含 `secrets` 的 get/list，绑定后 SA 能读整个 namespace 的 Secret；若 ClusterRole 含 `pods/exec` 或 escalate/bind 这类动词，同样能在 namespace 内横向。审查要看动词与资源的组合，而不是绑定对象类型。
</details>

5. `enforce-version` 钉在 v1.25，两年后集群升到 v1.33，这期间 standard 的定义变严了，你的策略会变吗？风险是什么？

<details><summary>答案</summary>

不会变——PSA 按钉住版本的定义检查，这正是钉版本的目的（可预期的策略）。风险是"标准演进带来的新要求（如新版 restricted 增加的字段）不会自动生效"，需要运维有计划地滚动上调 enforce-version 并配合 warn/audit 预热。
</details>

## 延伸阅读

- Pod Security Admission：<https://kubernetes.io/docs/concepts/security/pod-security-admission/>
- Pod Security Standards：<https://kubernetes.io/docs/concepts/security/pod-security-standards/>
- RBAC Good Practices：<https://kubernetes.io/docs/concepts/security/rbac-good-practices/>
- Configure Service Accounts for Pods：<https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/>
- NetworkPolicies：<https://kubernetes.io/docs/concepts/services-networking/network-policies/>
