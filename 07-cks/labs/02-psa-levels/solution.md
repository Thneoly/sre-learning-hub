# Lab 02 · 解答 —— Pod Security Admission 三级模式实验

## 背景：PSA 在哪一层工作

```
kubectl create pod
      |
      v
 apiserver: 认证 --> RBAC 授权 --> [mutating admission] --> [validating admission]
                                                        ^^^ PSA 在这里
                                                        违规: enforce 模式直接 403
                                                              audit 模式写 apiserver 审计日志
                                                              warn 模式回显 warning
```

PSA 是内置 admission 插件（1.25 起 stable，替代已删除的 PodSecurityPolicy），配置入口只有 namespace 标签：

| 标签 | 效果 |
|---|---|
| `pod-security.kubernetes.io/enforce` | 违规直接拒绝创建 |
| `pod-security.kubernetes.io/audit` | 放行，但审计日志记录 policy violation |
| `pod-security.kubernetes.io/warn` | 放行，向发起方回显 warning |

value 是标准名：`privileged` / `baseline` / `restricted`（label 值不允许冒号，写 `restricted:latest` 会被 kubectl 报 `invalid label value` 拒绝）。版本是独立标签 `<mode>-version`（如 `enforce-version=v1.24`），不写默认 `latest`。可以同时打多个标签组合使用（例如先 audit+warn 观察，再切 enforce——生产迁移的标准套路）。

## 步骤 1：创建三个 namespace 并打标签

```bash
# [master]
kubectl create ns cks-lab02-enforce
kubectl create ns cks-lab02-audit
kubectl create ns cks-lab02-warn

kubectl label ns cks-lab02-enforce pod-security.kubernetes.io/enforce=restricted
kubectl label ns cks-lab02-audit    pod-security.kubernetes.io/audit=restricted
kubectl label ns cks-lab02-warn     pod-security.kubernetes.io/warn=restricted

kubectl get ns cks-lab02-enforce --show-labels
```

验证：`--show-labels` 输出中能看到 `pod-security.kubernetes.io/enforce=restricted`。

## 步骤 2：在 enforce ns 尝试创建违规 Pod

```bash
# [master]
kubectl -n cks-lab02-enforce run bad --image=busybox:1.36 --restart=Never -- sleep 3600
```

预期直接报错（这是 admission 拒绝，对象从未落库）：

```
Error from server (Forbidden): pods "bad" is forbidden: violates PodSecurity "restricted:latest":
    unrestricted capabilities (container "bad" must set securityContext.capabilities.drop=["ALL"]),
    runAsNonRoot != true (container "bad" must set securityContext.runAsNonRoot=true),
    seccompProfile (container "bad" must set securityContext.seccompProfile.type to "RuntimeDefault" or "Localhost")
```

错误信息本身就是一份"整改清单"——逐条补齐即可通过。

确认没有创建：

```bash
# [master]
kubectl -n cks-lab02-enforce get pod bad
# Error from server (NotFound): pods "bad" not found
```

## 步骤 3：在 audit / warn ns 创建同样的违规 Pod

```bash
# [master]
kubectl -n cks-lab02-audit run bad --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl -n cks-lab02-warn  run bad --image=busybox:1.36 --restart=Never -- sleep 3600
```

预期（warn ns）：

```
Pod/cks-lab02-warn/bad created
Warning: violates PodSecurity "restricted:latest": ...
```

Pod 照常 Running。audit 模式的告警**不在命令输出里，也不产生 k8s Event**——PSA 的 audit 注解只写入 apiserver 审计日志（需要集群开启 `--audit-log-path` 等 audit 参数才能看到）：

```bash
# [master]（未开启 audit log 的集群上无输出，属正常）
grep pod-security /var/log/kubernetes/audit.log | tail -3
# "annotations": { "pod-security.policy:audit": "restricted:latest" ... }
```

没开审计日志时，audit 模式与"什么都没发生"无区别——这也是为什么迁移期通常 audit+warn 两个标签一起打。

## 步骤 4：在 enforce ns 创建合规 Pod

```yaml
# [master] good.yaml
apiVersion: v1
kind: Pod
metadata:
  name: good
  namespace: cks-lab02-enforce
spec:
  containers:
  - name: main
    image: busybox:1.36
    command: ["sleep", "3600"]
    securityContext:
      runAsNonRoot: true
      runAsUser: 1000
      runAsGroup: 1000
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      seccompProfile:
        type: RuntimeDefault
```

```bash
# [master]
kubectl apply -f good.yaml
kubectl -n cks-lab02-enforce get pod good
```

预期 `Running`。字段对照 restricted 标准的要求：

| 字段 | restricted 要求 | 作用 |
|---|---|---|
| `runAsNonRoot: true` | 必须显式声明 | 阻止容器以 uid 0 运行 |
| `allowPrivilegeEscalation: false` | 必须 | 禁止 setuid/setgid 提权 |
| `capabilities.drop: ["ALL"]` | 必须 | 丢弃全部 Linux capabilities |
| `seccompProfile.type: RuntimeDefault` | 必须非空 | 应用容器运行时默认 seccomp 白名单 |

注意 busybox 默认以 root 运行，因此同时写 `runAsUser: 1000`；只写 `runAsNonRoot: true` 而不给 uid 的话，kubelet 起容器时会报 `container has runAsNonRoot and image will run as root`（Error: CreateContainerConfigError），admission 不拦但运行期失败。

## 步骤 5：对照 warning 与标准清单

把步骤 2 错误信息中的三条与上面的表格逐条对照，就能记住 restricted 的核心要求。官方完整标准还包括：禁 hostPID/hostIPC/hostNetwork、只允许声明的 capabilities（默认空）、volume 类型限制等。详见文末链接。

## 生产迁移套路（audit + warn 先行）

```
新策略上线:  label audit=restricted + warn=restricted   --> 观察两周（warn 回显 + 审计日志）
           | 无违规或已整改
           v
           label enforce=restricted                    --> 开始硬拦截
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| enforce ns 里 Pod 还是创建成功了 | 标签打错（value 写成 `restricted:latest` 会直接报 invalid label value，根本打不上） | `kubectl label ns ... pod-security.kubernetes.io/enforce=restricted`（版本要写就用独立的 `-version` 标签） |
| good Pod 一直 `CreateContainerConfigError` | 只有 `runAsNonRoot` 没有 `runAsUser`，镜像默认 root | 显式 `runAsUser: 1000` |
| audit ns 看不到 Event | PSA audit 本来就不写 k8s Event，只写 apiserver 审计日志 | 要观察违规就同时打 `warn` 标签，或开启 apiserver audit log |
| 想对个别 Pod 豁免 | PSA 不支持对象级豁免 | 用独立的 namespace（打 privileged 标签）承载例外工作负载 |

## 判分结果

```bash
# [master]
cd 07-cks/labs/02-psa-levels
chmod +x check.sh
./check.sh
```

预期输出：

```
PASS: ns cks-lab02-enforce 标签 enforce=restricted
PASS: ns cks-lab02-audit 标签 audit=restricted
PASS: ns cks-lab02-warn 标签 warn=restricted
PASS: enforce ns 中违规 Pod bad 不存在（被 admission 拒绝）
PASS: audit ns 中 Pod bad 为 Running
PASS: warn ns 中 Pod bad 为 Running
PASS: enforce ns 中 Pod good 为 Running
PASS: good 容器 runAsNonRoot=true
PASS: good 容器 allowPrivilegeEscalation=false
PASS: good 容器 capabilities.drop 含 ALL
PASS: good 容器 seccompProfile=RuntimeDefault

SCORE: 11/11
```

## 延伸阅读

- Pod Security Admission: https://kubernetes.io/zh-cn/docs/concepts/security/pod-security-admission/
- Pod Security Standards: https://kubernetes.io/zh-cn/docs/concepts/security/pod-security-standards/
