# Lab 02 · Pod Security Admission 三级模式实验

> 难度：★★☆ ｜ 考点：CKS-集群加固（Pod Security Standards / Admission） ｜ 前置：无 ｜ 预计 25~35 分钟

## 场景

集群里三个团队共用 K8s：`pay` 团队处理支付，必须最严格；`dev` 团队还在试验，不能直接强制；`ops` 团队只要求能看到提示。你决定用 Pod Security Admission（PSA）的 namespace 标签做差异化管控，先在实验 namespace 验证三种模式的行为差异：

- `cks-lab02-enforce`：`enforce=restricted`——违规 Pod 直接被 apiserver 拒绝；
- `cks-lab02-audit`：`audit=restricted`——违规 Pod 允许创建，但审计日志出 warning；
- `cks-lab02-warn`：`warn=restricted`——违规 Pod 允许创建，kubectl 回显 warning。

"违规"定义为不满足 restricted 标准：未设置 `runAsNonRoot`、未 `seccompProfile: RuntimeDefault`、未 drop ALL capabilities 等任一条件。

## 任务清单

1. 创建三个 namespace 并分别打上对应标签（`pod-security.kubernetes.io/<mode>=restricted`；label 值不能含冒号，版本写在独立标签 `pod-security.kubernetes.io/<mode>-version`，不写默认 `latest`）。
2. 在 `cks-lab02-enforce` 尝试创建违规 Pod `bad`（busybox:1.36，`sleep 3600`，不带任何 securityContext）：确认被拒绝，错误信息含 "violates PodSecurity"。
3. 在 `cks-lab02-audit` 和 `cks-lab02-warn` 各创建一个同样违规的 Pod（名字也用 `bad`）：确认创建成功，且 kubectl 输出 warning。
4. 在 `cks-lab02-enforce` 创建合规 Pod `good`：busybox:1.36，`sleep 3600`，容器级 securityContext 满足 restricted（`runAsNonRoot`、`runAsUser: 1000`、`allowPrivilegeEscalation: false`、`capabilities.drop: [ALL]`、`seccompProfile: RuntimeDefault`），确认 Running。
5. 观察三条违规 warning 各自指向哪些字段（对照 Kubernetes 官方 restricted 标准清单）。

## 验收标准

- `kubectl get ns cks-lab02-enforce --show-labels` 能看到 `pod-security.kubernetes.io/enforce=restricted`
- `kubectl -n cks-lab02-enforce get pod bad` 报 `NotFound`（被 admission 拒绝，从未创建）
- `kubectl -n cks-lab02-audit get pod bad` 与 `kubectl -n cks-lab02-warn get pod bad` 均为 Running
- `kubectl -n cks-lab02-enforce get pod good` 为 Running

运行判分脚本：

```bash
# [master]
cd 07-cks/labs/02-psa-levels
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：PSA 标签怎么打</summary>

标签 key 是固定的四选一：`pod-security.kubernetes.io/enforce|audit|warn`，value 是标准名：`privileged` / `baseline` / `restricted`（注意 label 值不能含冒号，写 `restricted:latest` 会报 `invalid label value`）。版本是另一条独立标签 `<mode>-version`（如 `enforce-version=v1.24`），不写默认 `latest`。一条命令即可：

```bash
# [master]
kubectl label ns cks-lab02-enforce pod-security.kubernetes.io/enforce=restricted
```
</details>

<details><summary>提示 2：audit 模式的 warning 去哪了</summary>

audit 模式的告警写入 **apiserver 审计日志**（audit annotations，形如 `pod-security.policy: audit="restricted:latest"`），需要集群开启 audit log 才能看到，`kubectl get events` 里**没有**；warn 模式直接回显在 kubectl 命令输出里。两者都不阻断。
</details>

<details><summary>提示 3：restricted 到底要哪几项</summary>

最小集（对普通容器）：`securityContext.runAsNonRoot: true`、`allowPrivilegeEscalation: false`、`capabilities.drop: ["ALL"]`、`seccompProfile.type: RuntimeDefault`。镜像本身以非 root 运行（`runAsUser: 1000`）可避免运行期报错。
</details>
