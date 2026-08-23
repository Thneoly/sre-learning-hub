# Lab 06 · 解答 —— Audit Policy：让 apiserver 记下谁动了什么

## 背景：审计事件的生命周期

```
client(kubectl/lib) --request--> apiserver
                                   |-- 认证/授权
                                   |-- admission
                                   |-- 执行 & 响应
                                   +-- 每个阶段(RequestReceived/ResponseStarted/Panic)按 policy 定级落盘
level: None | Metadata | Request | RequestResponse
```

policy 是"首个命中生效"的有序规则表；没命中任何规则的请求走默认 `Metadata`（建议显式写兜底，语义清晰）。日志一行一个 JSON 事件，核心字段：`auditID`、`stage`、`verb`、`user.username`、`sourceIPs`、`objectRef`（resource/namespace/name）、`requestObject` / `responseObject`（级别够高才有）。

## 步骤 1：编写 policy

```bash
# [master]
sudo tee /etc/kubernetes/audit-policy.yaml >/dev/null <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
  - "RequestReceived"
rules:
  # 1. 高频只读噪音直接丢弃
  - level: None
    users: ["system:kube-proxy"]
    verbs: ["watch", "list", "get"]
    resources:
      - group: ""
        resources: ["endpoints", "services"]

  # 2. Pod 的写操作记录请求与响应体（变更留痕）
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete", "deletecollection"]
    resources:
      - group: ""
        resources: ["pods"]

  # 3. 敏感对象只记元数据（不落 Secret 内容，防日志泄密）
  - level: Metadata
    resources:
      - group: ""
        resources: ["secrets", "configmaps"]

  # 4. 兜底
  - level: Metadata
EOF
sudo cat /etc/kubernetes/audit-policy.yaml
```

规则顺序解读：

| 顺序 | 规则 | 为什么 |
|---|---|---|
| 1 | kube-proxy 只读 None | watch 每几秒一条，不压掉会把磁盘写爆 |
| 2 | pods 写操作 RequestResponse | 审计核心诉求：改了什么、改成了什么样 |
| 3 | secrets Metadata | 记录"谁在何时读了哪个 Secret"，但**不记录内容**——日志系统往往比 etcd 更容易被翻 |
| 4 | 兜底 Metadata | 其他一切留元数据 |

## 步骤 2：给 apiserver 挂上 policy 与日志路径

先备份再改：

```bash
# [master]
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/kube-apiserver.yaml.bak
sudo mkdir -p /var/log/kubernetes
sudo chmod 700 /var/log/kubernetes
```

编辑 `/etc/kubernetes/manifests/kube-apiserver.yaml`，三处改动：

1. `command` 列表末尾追加两个参数：

```yaml
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit.log
    - --audit-log-maxage=7
    - --audit-log-maxbackup=5
    - --audit-log-maxsize=100
```

（后三个是轮转策略：保留 7 天 / 5 个旧文件 / 单文件 100MB，可不加。）

2. `volumeMounts` 列表追加：

```yaml
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/kubernetes
      name: audit-log
      readOnly: false
```

注意 policy 文件用"文件级挂载"（`mountPath` 直接指向文件），日志目录用目录级挂载。

3. `volumes` 列表追加：

```yaml
  - hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
    name: audit-policy
  - hostPath:
      path: /var/log/kubernetes
      type: DirectoryOrCreate
    name: audit-log
```

## 步骤 3：确认 apiserver 重启就绪

静态 Pod 由 kubelet 监听 manifest 变化自动重建：

```bash
# [master]
kubectl -n kube-system get pods -l component=kube-apiserver -w
# 等 1~2 分钟，新 Pod Running 即生效
```

如果 Pod 反复重启，九成是 YAML 缩进或挂载路径错误：

```bash
# [master]
kubectl -n kube-system describe pod -l component=kube-apiserver | tail -20
# 修复后如无法恢复：sudo cp /etc/kubernetes/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
```

## 步骤 4：制造事件

```bash
# [master]
kubectl create ns cks-lab06

kubectl -n cks-lab06 create secret generic db-password \
  --from-literal=password='S3cr3t!'

kubectl -n cks-lab06 run victim --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl -n cks-lab06 wait --for=condition=Ready pod/victim --timeout=60s
kubectl -n cks-lab06 delete pod victim --wait=false
```

## 步骤 5：从日志中检索验证

```bash
# [master]
# 1) Secret 创建的 Metadata 事件
sudo grep '"name":"db-password"' /var/log/kubernetes/audit.log | grep '"verb":"create"' | head -1 | python3 -m json.tool
```

预期关键字段：

```json
{
  "auditID": "…",
  "verb": "create",
  "user": { "username": "kubernetes-admin" },
  "objectRef": { "resource": "secrets", "namespace": "cks-lab06", "name": "db-password" },
  "level": "Metadata",
  ...
}
```

注意 Metadata 级别的事件**没有** `requestObject`——Secret 内容没进日志，这正是我们要的。

```bash
# [master]
# 2) Pod create 的 RequestResponse 事件（带请求体）
sudo grep '"name":"victim"' /var/log/kubernetes/audit.log | grep '"verb":"create"' | head -1 | python3 -m json.tool | grep -A3 requestObject
#   "requestObject": { "apiVersion": "v1", "kind": "Pod", ... }

# 3) kube-proxy 噪音确实被 None 掉了
sudo grep -c '"username":"system:kube-proxy"' /var/log/kubernetes/audit.log
# 0（或仅剩非 endpoints/services 的条目）

# 4) 快速统计各类事件量
sudo grep -o '"verb":"[a-z]*"' /var/log/kubernetes/audit.log | sort | uniq -c | sort -rn | head
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| apiserver 起不来 | manifest 改错（缩进/挂载漏写） | 用 `.bak` 恢复重来；describe 看 Events |
| 日志文件为空 | policy 规则全 None / flags 没生效 | `kubectl -n kube-system exec … cat /etc/kubernetes/audit-policy.yaml` 确认挂进去了 |
| 磁盘被日志打爆 | 没配 omitStages/None 规则/轮转 | 加 `--audit-log-max*` 轮转 + None 规则瘦身 |
| grep 不到 db-password | Secret 创建发生在 apiserver 重启前 | 重启完成后再制造事件 |
| 想把日志送 SIEM | 单文件不够 | 加 `--audit-log-webhook-url` 或用 Fluent bit/Vector 采集文件 |

## 判分结果

```bash
# [master]
cd 07-cks/labs/06-audit-policy
chmod +x check.sh
./check.sh
```

预期输出：

```
PASS: policy 文件 /etc/kubernetes/audit-policy.yaml 存在
PASS: policy apiVersion=audit.k8s.io/v1 且 kind=Policy
PASS: policy 全局 omitStages RequestReceived
PASS: policy 含 secrets 的 Metadata 规则
PASS: policy 含 pods 的 RequestResponse 规则
PASS: apiserver manifest 含 --audit-policy-file
PASS: apiserver manifest 含 --audit-log-path
PASS: kube-apiserver 静态 Pod 为 Running
PASS: audit log /var/log/kubernetes/audit.log 存在且非空
PASS: audit log 首行为合法 JSON 且含 auditID
PASS: 日志含 Secret db-password 的 create 记录
PASS: 日志含 Pod victim 的 create/delete 记录
PASS: Pod create 记录带 requestObject（RequestResponse 生效）
PASS: system:kube-proxy 的 endpoints watch 未入日志
PASS: namespace cks-lab06 存在

SCORE: 15/15
```

## 延伸阅读

- Audit 官方文档: https://kubernetes.io/zh-cn/docs/tasks/debug/debug-cluster/audit/
- apiserver audit 相关 flags: https://kubernetes.io/zh-cn/docs/reference/command-line-tools-reference/kube-apiserver/
