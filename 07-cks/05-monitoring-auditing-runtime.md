# 05 · 监控、审计与运行时安全：audit log、Falco 与容器逃逸检测

> 模块：CKS 备考 ｜ 建议时长：4.5 小时 ｜ 关联认证：CKS-Monitoring, Logging and Runtime Security

## 学习目标

- 能写出完整的 audit policy（level/stage/verbs/writeOnly 语义），挂载到 apiserver 并验证日志
- 能解读一条 audit 事件的关键字段，并用 jq 定位"谁动了 Secret"
- 能安装 Falco、读懂规则语法、编写自定义规则并解读告警日志
- 能列举容器逃逸的典型路径并说出对应的检测与防护手段
- 能用 readOnlyRootFilesystem 等手段保证容器运行时不可变

## 1. Kubernetes 审计（Audit）

### 1.1 事件从哪来：四个 stage

每个 API 请求在 apiserver 内的生命周期各阶段都可产生审计事件：

```
client ──> 认证 ──> 授权 ──> admission ──> etcd 写入 ──> 响应
            │         │         │             │           │
        RequestReceived                ResponseComplete
        (刚收到)                       (响应发完，最常用)
        ResponseStarted：长连接(watch)响应头已发
        Panic：处理过程崩溃
```

### 1.2 level：记多细

| level | 记录内容 |
| --- | --- |
| `None` | 不记录（命中即短路，用于降噪） |
| `Metadata` | 只记元数据：用户、verb、资源、时间、来源 IP 等（**不含**请求/响应体） |
| `Request` | 元数据＋请求体（Secret 的明文会进日志，慎用） |
| `RequestResponse` | 元数据＋请求体＋响应体（list/watch 的响应体可能巨大） |

两个实用字段：

- `omitStages`：全局或单条规则里排除某个 stage，最常见 `omitStages: ["RequestReceived"]`——ResponseComplete 已含结果，RequestReceived 会把量翻倍
- 规则是**自上而下首条命中**（first match wins），最后一条通常是兜底的 `level: Metadata`

关于 "writeOnly"：旧版 `audit.k8s.io/v1beta1` 的规则里有 `writeOnly: true`（只在写请求记 body），该字段在 v1 里已移除。v1 的等价做法是用 verbs 限定写操作：`verbs: ["create", "update", "patch", "delete", "deletecollection"]`。

### 1.3 一份可直接用的 policy

```yaml
# [master] /etc/kubernetes/audit/audit-policy.yaml
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"
rules:
  # 1. Secret/ConfigMap 只记 Metadata：body 里有明文，绝不用 RequestResponse
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # 2. 只审计对 secrets 的"写"操作（v1beta1 writeOnly 的等价写法）
  - level: Request
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""
        resources: ["secrets"]

  # 3. 管理员与高权限组的操作全量记录（含请求与响应）
  - level: RequestResponse
    userGroups: ["system:masters"]

  # 4. exec/attach/portforward 是红队最爱，必须记
  - level: RequestResponse
    resources:
      - group: ""
        resources: ["pods/exec", "pods/attach", "pods/portforward"]

  # 5. 系统组件的日常 watch/list 降噪
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch"]
  - level: None
    userGroups: ["system:nodes"]
    verbs: ["get", "list", "watch"]
    resources:
      - group: ""
        resources: ["nodes", "pods", "endpoints", "services"]

  # 6. 兜底：其余全部记元数据
  - level: Metadata
```

注意规则顺序： secrets 的写操作要命中第 2 条就必须放在第 1 条之前，否则会被第 1 条的 Metadata 先截获。上面示例为了教学保持 1、2 顺序演示"首条命中"的坑，生产请把更细的那条放前面。

### 1.4 挂到 apiserver（static Pod）

```bash
# [master] 放置 policy 与日志目录
sudo mkdir -p /etc/kubernetes/audit /var/log/kubernetes/audit
sudo cp audit-policy.yaml /etc/kubernetes/audit/audit-policy.yaml
sudo chown root:root /etc/kubernetes/audit/audit-policy.yaml
```

编辑 `/etc/kubernetes/manifests/kube-apiserver.yaml`：

```yaml
# [master] command 段追加
    - --audit-policy-file=/etc/kubernetes/audit/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit/audit.log
    - --audit-log-maxage=7
    - --audit-log-maxbackup=5
    - --audit-log-maxsize=100
```

```yaml
# [master] volumeMounts 段追加
      - mountPath: /etc/kubernetes/audit/audit-policy.yaml
        name: audit-policy
        readOnly: true
      - mountPath: /var/log/kubernetes/audit/
        name: audit-log
        readOnly: false
```

```yaml
# [master] volumes 段追加
    - name: audit-policy
      hostPath:
        path: /etc/kubernetes/audit/audit-policy.yaml
        type: File
    - name: audit-log
      hostPath:
        path: /var/log/kubernetes/audit/
        type: DirectoryOrCreate
```

apiserver 自启后验证：

```bash
# [master]
kubectl get secrets -n default >/dev/null    # 触发一次 secrets 读
sudo tail -n 1 /var/log/kubernetes/audit/audit.log | jq '.level, .objectRef.resource, .verb'
# 预期: "Metadata" "secrets" "list"
```

### 1.5 日志字段解读

一条事件（已格式化）的关键字段：

```
{
  "auditID": "3f7b...",                       事件唯一 ID，排查时跨系统对账用
  "level": "RequestResponse",                 该事件的记录级别
  "stage": "ResponseComplete",                生命周期阶段
  "requestURI": "/api/v1/namespaces/payment/secrets",
  "verb": "create",                           list/get/create/update/patch/delete/watch
  "user": {
    "username": "system:serviceaccount:dev:ci",  谁发起的（SA 也有名字）
    "groups": ["system:serviceaccounts", ...]
  },
  "sourceIPs": ["10.0.2.15"],                 来源（Pod IP 能反查节点/Pod）
  "userAgent": "kubectl/v1.31 ...",           客户端指纹
  "objectRef": {                              操作对象
    "resource": "secrets", "namespace": "payment", "name": "db-cred"
  },
  "responseStatus": { "code": 201 },          201 成功创建；403 被拒也是有效线索
  "requestObject": { ... },                   请求体（level>=Request 才有）
  "annotations": {
    "authorization.k8s.io/decision": "allow", 授权结果与原因
    "authorization.k8s.io/reason": "RBAC:role=..."
  }
}
```

三问定位法（who/what/result）：`user.username`＋`sourceIPs` → 谁；`verb`＋`objectRef` → 干了什么；`responseStatus.code`＋`annotations.authorization.*` → 结果与授权依据。

高频 jq 查询：

```bash
# [master]（audit.log 属 root，jq 需 sudo 读取）
AUDIT=/var/log/kubernetes/audit/audit.log

# 谁读/写了哪些 Secret
sudo jq -c 'select(.objectRef.resource=="secrets") |
  {t:.stageTimestamp,u:.user.username,v:.verb,ns:.objectRef.namespace,n:.objectRef.name,code:.responseStatus.code}' $AUDIT | tail -5

# 所有 exec 进容器的记录
sudo jq -c 'select(.objectRef.resource=="pods/exec" and .stage=="ResponseComplete") |
  {u:.user.username,pod:.objectRef.name,ns:.objectRef.namespace}' $AUDIT | tail -5

# 被拒绝的操作（横向移动痕迹）
sudo jq -c 'select(.responseStatus.code==403) | {u:.user.username,uri:.requestURI}' $AUDIT | tail -5
```

## 2. Falco：运行时行为检测

### 2.1 事件来源与部署形态

Falco 在**节点上**对 syscall 流做规则匹配，事件来源（engine/driver）三选一：

| driver | 原理 | 要求 |
| --- | --- | --- |
| kmod | 内核模块 | 每次内核升级要重编；SecureBoot 需签名 |
| eBPF probe | 传统 eBPF 探针 | 内核较老也兼容 |
| modern eBPF | 无需内核构件的现代 eBPF | 内核较新（练习环境首选，零依赖） |

部署形态：直接装在节点（下文），或用 Helm 以 DaemonSet 跑进集群（`helm repo add falcosecurity https://falcosecurity.github.io/charts`）。

### 2.2 安装（Ubuntu 22.04/24.04）

```bash
# [worker1] 配置官方 apt 仓库（key 与 repo 地址以 falco.org/docs/setup/packages 为准）
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://falco.org/repo/falcosecurity-packages.asc \
  | sudo gpg --dearmor -o /etc/apt/keyrings/falcosecurity-packages.gpg
echo "deb [signed-by=/etc/apt/keyrings/falcosecurity-packages.gpg] https://download.falco.org/packages/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/falcosecurity.list
sudo apt-get update

# 非交互安装并指定 modern eBPF 驱动（无需内核头文件）
sudo FALCO_FRONTEND=noninteractive FALCO_DRIVER_CHOICE=modern_ebpf apt-get install -y falco

sudo systemctl status falco-modern-bpf --no-pager | head -5
```

### 2.3 规则语法：list / macro / rule

Falco 规则文件（`/etc/falco/falco_rules.yaml` 内置，自定义放 `/etc/falco/rules.d/`）由三种结构组成：

```yaml
# [worker1] /etc/falco/rules.d/custom-rules.yaml
# list：可复用的字符串集合
- list: shell_binaries
  items: [bash, sh, dash, zsh, ash]

# macro：可复用的条件片段（内置规则已占用 container 这个名字，自定义加前缀避免重定义报错）
- macro: my_container
  condition: (container.id != host)

# rule：条件 + 输出 + 优先级
- rule: Terminal Shell in Payment Namespace
  desc: 检测 payment namespace 的 Pod 里起了 shell
  condition: >
    my_container and
    evt.type in (execve, execveat) and evt.dir=< and
    proc.name in (shell_binaries) and
    k8s.ns.name="payment"
  output: >
    Shell in pod (user=%user.name pod=%k8s.pod.name ns=%k8s.ns.name
    container=%container.name shell=%proc.name parent=%proc.pname cmdline=%proc.cmdline)
  priority: WARNING
  tags: [k8s, container, shell, mitre_execution]
```

语法要素：`evt.type` 是 syscall 名；`evt.dir=<` 表示"进入"事件（ syscall 调用发生时）；`container.id != host` 排除宿主机进程；`k8s.*` 字段来自容器运行时元数据（Falco 需要能读 containerd/docker socket）。priority 从低到高：DEBUG < INFO < NOTICE < WARNING < ERROR < CRITICAL < ALERT < EMERGENCY。

改完规则文件，Falco 默认热加载（`watch_config_files`）；必要时 `systemctl restart falco-modern-bpf`。

### 2.4 触发与日志解读

```bash
# [master] 在集群里制造一次"读敏感文件"
kubectl run probe --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl exec probe -- cat /etc/shadow
```

```bash
# [worker1]（Pod 所在节点）看 Falco 告警
sudo journalctl -u falco-modern-bpf --since "5 min ago" | grep -i 'sensitive\|shell' | tail -3
```

典型输出（内置规则 Read sensitive file trusted after startup）：

```
{
  "time": "...", "rule": "Read sensitive file trusted after startup",
  "priority": "Warning",
  "output": "06:02:11.318491389: Warning Sensitive file opened for reading by non-command-proc
    (user=root command=cat /etc/shadow parent=kubelet file=/etc/shadow container=...)",
  "output_fields": {
    "user.name": "root", "proc.name": "cat", "proc.cmdline": "cat /etc/shadow",
    "fd.name": "/etc/shadow", "container.name": "probe", "k8s.ns.name": "default"
  },
  "tags": ["filesystem", "mitre_credential_access"]
}
```

读法：`rule` 是命中的规则名，`output_fields` 是结构化字段（proc.* 进程、fd.* 文件、container.*/k8s.* 容器与 Pod 归属），`tags` 关联 MITRE ATT&CK 战术。JSON 输出由 `/etc/falco/falco.yaml` 的 `json_output: true` 控制，接 SIEM 时打开并配 file_output/webhook 输出。

常用内置规则（不同版本名称略有差异）：Terminal shell in container、Read sensitive file trusted after startup、Write below /etc、Change thread namespace、Contact cloud metadata service from container、Container escape via cgroup release_agent。

## 3. 容器逃逸：典型路径与检测思路

```
容器内 shell ──> 想拿到宿主机 root，常见 6 条路：
  1 privileged 容器      : 直接 mknod/mount 宿主磁盘，或写 cgroup release_agent
  2 hostPID/hostNetwork  : nsenter 进入宿主进程命名空间；嗅探节点流量
 3 挂载敏感 hostPath     : /、/var/run/docker.sock、/var/run/containerd/containerd.sock
 4 危险 capabilities     : CAP_SYS_ADMIN(挂载/内核模块)、CAP_SYS_PTRACE(注入)、CAP_DAC_READ_SEARCH(任意读)
 5 内核漏洞              : Dirty Pipe/Dirty COW 类，共享内核直接中招
 6 泄露的凭证            : SA token 外带 → API 横向；节点上的 kubeconfig/证书
```

逐条对照：防护在前（PSA restricted 一票否决 1/2/3/4 的绝大多数配置）、检测在后（Falco 对应行为告警）：

| 逃逸路径 | 事前防护 | 运行时检测信号 |
| --- | --- | --- |
| privileged + release_agent | PSA enforce=restricted（拒绝 privileged） | Falco: Container escape via cgroup release_agent；Write below /dev |
| hostPID + nsenter | PSA baseline/restricted 禁 hostPID | Falco: Change thread namespace（setns 调用） |
| 挂 docker.sock 起特权容器 | PSA 限制 hostPath；NetworkPolicy 限出站 | 新容器创建事件＋调用方是容器内进程（audit log sourceIP 是 Pod IP） |
| CAP_SYS_PTRACE 注入 | restricted 要求 drop ALL | Falco: 非 root 使用 ptrace/sudo setuid 类规则 |
| 内核漏洞利用 | 及时升级内核/K8s（Cluster Hardening 域考点） | seccomp 拦截异常 syscall；Falco 记录异常 syscall 序列 |
| SA token 外带 | automountServiceAccountToken=false | audit log 里出现 Pod IP 对 secrets 的 list/get；出站流量到 6443 |

调查一条攻击链时把三类日志串起来：audit log（API 层"谁干了什么"）→ Falco（节点层"进程干了什么"）→ 容器镜像指纹（"用什么打的"）。

## 4. 运行时不可变（Immutability）

"容器运行中不改自己"能废掉一半的持久化手段：

```yaml
# [master] kubectl apply -f
apiVersion: v1
kind: Pod
metadata:
  name: immutable-app
  namespace: default
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: main
      image: nginx:1.27
      securityContext:
        runAsNonRoot: true
        runAsUser: 101
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true   # 根文件系统只读
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE"]
      volumeMounts:
        - name: tmp-write              # 必须写的目录用 emptyDir 单独放开
          mountPath: /var/cache/nginx
  volumes:
    - name: tmp-write
      emptyDir: {}
```

验证：`kubectl exec immutable-app -- touch /etc/x` 应报 Read-only file system。配合禁 `kubectl exec` 的 RBAC（不给 pods/exec 权限）与不在镜像里放包管理器（见 04 篇 distroless），运行时基本无可"下毒"的落点。

## 实战演练：从审计到 Falco 的完整检测链

环境：kubeadm 单 master＋1 worker。目标：模拟"攻击者在 Pod 里读敏感文件并尝试起 shell"，三个观测点全部命中。

```bash
# [master] Step1 部署 audit policy（1.3/1.4 节），确认日志在滚动
kubectl create secret generic canary -n default --from-literal=k=v
sudo grep -c '"resource":"secrets"' /var/log/kubernetes/audit/audit.log

# [worker1] Step2 安装 Falco 并加自定义规则（2.2/2.3 节），确认服务 active
sudo systemctl is-active falco-modern-bpf

# [master] Step3 制造事件：读敏感文件＋起 shell
kubectl exec probe -- cat /etc/shadow
kubectl exec -it probe -- sh -c 'id'

# [worker1] Step4 解读告警
sudo journalctl -u falco-modern-bpf --since "3 min ago" \
  | grep -E 'sensitive|Terminal' | tail -5

# [master] Step5 在 audit log 里找到这次 exec 的 API 记录
sudo jq -c 'select(.objectRef.resource=="pods/exec") | {u:.user.username,ns:.objectRef.namespace,ip:.sourceIPs[0]}' \
  /var/log/kubernetes/audit/audit.log | tail -3

# [master] Step6 清理
kubectl delete pod probe; kubectl delete secret canary -n default
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- |---|
| audit.log 一直是空文件 | policy 文件没挂进容器/apiserver 未加 `--audit-policy-file`；或只配了 policy 没配 `--audit-log-path` | 两个 flag＋两个 volumeMount 缺一不可；`crictl exec` 进 apiserver 容器确认文件路径可见 |
| apiserver 起不来，报 policy parse 错误 | audit-policy.yaml 缩进错或用了 v1 不存在的字段（如 writeOnly） | `crictl logs` 看具体行号；v1 里用 verbs 表达 writeOnly 语义 |
| 日志量爆炸把磁盘打满 | watch/list 记成 RequestResponse；没 omit RequestReceived | 系统 watch 用 level None 降噪；maxsize/maxbackup/maxage 三限位；Secret 只记 Metadata |
| Falco 装完服务 failed | 驱动不可用（老内核/无头文件/SecureBoot 拦截 kmod） | 改用 modern eBPF：重装时 FALCO_DRIVER_CHOICE=modern_ebpf；`journalctl -u falco*` 看驱动报错 |
| 自定义规则不生效 | rules.d 路径不在 rules_files 列表；condition 语法错（热加载失败会写日志） | `falco --validate /etc/falco/rules.d/custom-rules.yaml` 校验；确认 falco.yaml 的 rules_files 含该目录 |
| k8s.pod.name 字段为空 | Falco 读不到容器运行时 socket（容器化部署未挂） | 挂载 /run/containerd/containerd.sock（只读）或用节点直装方式 |
| readOnlyRootFilesystem 后应用崩 | 应用要写 /tmp、/var/log 等 | 用 emptyDir 挂到必写路径；这是改造应用的正常成本，别回退只读 |

## 自测

1. policy 里把 secrets 记成 `level: RequestResponse` 会发生什么？正确做法是什么？

<details><summary>答案</summary>

创建/读取 Secret 的请求与响应体（含 base64 明文）全部进日志，日志本身变成最高价值泄露源。正确做法：secrets 用 Metadata；确需审计写入内容时单独一条 `level: Request`＋写动词 verbs，并保护好日志存储权限。
</details>

2. 规则自上而下首条命中。你的 policy 第 1 条是 `secrets: Metadata`，第 5 条是 `verbs 写操作: Request`，为什么"Secret 写操作记 body"永远不生效？

<details><summary>答案</summary>

secrets 的写请求先命中第 1 条（Metadata）并被赋级别，后续规则不再参与。细化规则必须排在宽泛规则之前——这也是写 audit policy 时最经典的顺序错误。
</details>

3. Falco 与 audit log 的检测视角有何本质区别？为什么两者都要有？

<details><summary>答案</summary>

audit log 记录 API 层（对 apiserver 的操作），Falco 记录节点层（进程 syscall，例如读文件、起 shell、setns）。攻击者拿到 shell 后可以不碰 API（纯节点内横向），而 Pod 间滥用又只出现在 API 层；两层合起来才覆盖"控制面作恶"与"数据面作恶"。
</details>

4. 攻击者在 default namespace 的 Pod 里执行 `cat /var/run/secrets/kubernetes.io/serviceaccount/token`，事前事后各有什么信号能发现他？

<details><summary>答案</summary>

事前：该 Pod 本不该自动挂 token——automountServiceAccountToken=false 本可让这个文件不存在（04/03 篇手段）。事后：Falco 的 Read sensitive file 类规则对 token 路径告警；随后他用 token 访问 API 时，audit log 里出现 sourceIP 为 Pod IP、username 为 system:serviceaccount:... 的请求记录，403 风暴更说明在试探权限。
</details>

5. `--audit-log-maxsize=100 --audit-log-maxbackup=5` 在量大的集群里为什么危险？怎么权衡？

<details><summary>答案</summary>

单文件 100MB×5 个＝最多 500MB 历史，高流量集群几分钟就滚动覆盖，攻击回溯窗口几乎为零。要么放宽保留（外置 webhook backend 送 SIEM，本地只做缓冲），要么用更激进的降噪策略（系统组件 None、metadata 为主）压低产生速率。
</details>

## 延伸阅读

- Auditing（官方文档）：<https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/>
- Audit Policy 配置参考（v1 全字段）：<https://kubernetes.io/docs/reference/config-api/apiserver-audit.v1/>
- Falco 官方文档（安装/规则/字段）：<https://falco.org/docs/>
- Falco 官方仓库与默认规则集：<https://github.com/falcosecurity/falco>
- Security Checklist（含 immutability 检查项）：<https://kubernetes.io/docs/concepts/security/security-checklist/>
