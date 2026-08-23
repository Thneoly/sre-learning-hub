# Lab 18 · 解答：ImagePullBackOff 与 CrashLoopBackOff 排障

## 故障演化时间线

```
apply(nginxxx:latest + sh 覆盖)
   │ kubelet 拉镜像失败
   ▼
Pod: ImagePullBackOff ──set image nginx:1.27-alpine──> 拉镜像成功
   │ 但 /bin/sh -c "exit 1" 一秒即退出
   ▼
Pod: CrashLoopBackOff ──去掉 command/args──> nginx 前台运行
   ▼
Deployment 2/2 Available
```

排障的核心习惯：**改一处，观察状态变化**，状态不变说明没修到点上。

## 第 1 步：还原现场

```bash
# [master]
kubectl create namespace cka-triage
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: broken-app
  namespace: cka-triage
spec:
  replicas: 2
  selector:
    matchLabels:
      app: broken-app
  template:
    metadata:
      labels:
        app: broken-app
    spec:
      containers:
      - name: web
        image: nginxxx:latest
        command: ["/bin/sh", "-c"]
        args: ["echo 'starting'; sleep 1; exit 1"]
        ports:
        - containerPort: 80
EOF
```

## 第 2 步：定位镜像层故障

```bash
# [master]
kubectl -n cka-triage get pods -w
```

预期 STATUS 先是 `ContainerCreating`，几十秒内变 `ImagePullBackOff`（Ctrl-C 退出 watch）。取证：

```bash
# [master]
kubectl -n cka-triage describe pod -l app=broken-app | tail -20
```

Events 段的关键证据：

```
Failed to pull image "nginxxx:latest": rpc error:
  code = Unknown desc = Error response from daemon:
  pull access denied for nginxxx, repository does not exist
Error: ErrImagePull
Back-off pulling image
```

`repository does not exist` = 镜像名拼错（或仓库私有未认证）。这类问题**只**在 Events 里可见，logs 是空的（容器从未起来）。

## 第 3 步：修镜像，观察状态跃迁

```bash
# [master]
kubectl -n cka-triage set image deployment/broken-app web=nginx:1.27-alpine
kubectl -n cka-triage get pods -w
```

预期：新 Pod 的镜像拉取成功、容器启动——然后状态停在 `CrashLoopBackOff`。**状态变了**，说明第一处问题已修好；CrashLoop 是第二处独立问题。

## 第 4 步：取证 CrashLoop

```bash
# [master]
kubectl -n cka-triage logs deploy/broken-app --previous
```

预期输出：

```
starting
```

`--previous` 读的是**上一次崩溃容器**的日志；不带它常报 "container ... is waiting to start"（当前实例还没起来）。再看退出原因：

```bash
# [master]
kubectl -n cka-triage describe pod -l app=broken-app | grep -A4 "Last State"
```

预期：

```
Last State:  Terminated
  Reason:    Error
  Exit Code: 1
```

`Exit Code: 1` + 日志里有 `starting`：应用自己打印后主动 `exit 1`——问题在我们注入的 `command/args` 把镜像默认入口（nginx master process）覆盖成了 sh 脚本。

## 第 5 步：移除 command/args 覆盖

```bash
# [master]
kubectl -n cka-triage patch deployment broken-app --type=json -p='[
  {"op":"remove","path":"/spec/template/spec/containers/0/command"},
  {"op":"remove","path":"/spec/template/spec/containers/0/args"}
]'
kubectl -n cka-triage rollout status deployment/broken-app --timeout=180s
```

预期 `deployment "broken-app" successfully rolled out`。终态验证：

```bash
# [master]
kubectl -n cka-triage get deploy broken-app
# NAME          READY   UP-TO-DATE   AVAILABLE   AGE
# broken-app    2/2     2            2           10m
kubectl -n cka-triage get pods -l app=broken-app
# 两个 Running, RESTARTS 0
```

## 第 6 步：Exit Code 速查答案

| Exit Code | 含义 | 集群里的典型场景 |
| --- | --- | --- |
| 0 | 正常退出 | 任务型 Job 完成 |
| 1 | 应用自身错误 | 配置错/依赖连不上（本 lab） |
| 126 / 127 | 命令不可执行 / 不存在 | command 写错、二进制不在 PATH |
| 137 | SIGKILL（128+9） | OOM 被 cgroup kill，或 livenessProbe 失败被 kubelet 杀 |
| 143 | SIGTERM（128+15） | 优雅终止（滚动更新时正常出现） |

`Reason: OOMKilled` 一定伴随 137，表示内存超限，修法是调大 resources.limits.memory 或查内存泄漏，而不是重启策略。

## 常见错误回顾

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| ImagePullBackOff: pull access denied | 私有仓库未配 imagePullSecrets 或名字拼错 | 核对镜像名；`kubectl create secret docker-registry` 并在 Pod 里引用 |
| ImagePullBackOff: no such host | registry 域名解析不了（节点 DNS/代理） | 节点上 `crictl pull` 手工验证 |
| CrashLoopBackOff: Exit 1 | 应用配置错/被 command 覆盖 | `logs --previous` 看崩溃前输出 |
| CrashLoopBackOff: OOMKilled | limit 太小 | 调大 memory limit |
| 修完一直 CrashLoop | livenessProbe 误杀（探测太早/端口错） | describe 的 Last State Reason + kubelet 事件 |

## 延伸阅读

- https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/
- https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/#container-states

## check.sh 运行结果

```bash
# [master]
chmod 755 check.sh && ./check.sh
```

预期：

```
PASS: namespace cka-triage 存在
PASS: Deployment broken-app 存在
PASS: 镜像为 nginx:1.27-alpine
PASS: command/args 覆盖已移除(使用镜像默认入口)
PASS: availableReplicas=2
PASS: broken-app 的两个 Pod 均 Running
PASS: 容器 restartCount 稳定(最大 0)

SCORE: 7/7
```
