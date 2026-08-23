# Lab 18 · ImagePullBackOff 与 CrashLoopBackOff 排障
> 难度：★★ ｜ 考点：CKA-排错（工作负载故障定位） ｜ 前置：无 ｜ 预计 30 分钟
> 运行位置：kubectl 操作全部在 [master]

## 场景

有人提交了一个 Deployment，`kubectl get pods` 里 Pod 一直不 Ready。你接手时只知道下面这份 YAML（**它有两处独立的问题，第一处修好后才会暴露第二处**）：

```yaml
# [master] 已应用到集群(现场还原命令见任务清单第 1 步)
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
```

业务要求的终态：镜像 `nginx:1.27-alpine`，容器以镜像默认入口运行，2/2 Available。

## 任务清单

1. 还原现场：创建 namespace `cka-triage` 并 apply 上面的 Deployment。
2. 观察 Pod 的第一个故障状态（STATUS 列），用 `kubectl describe pod` 找出**镜像层**的证据（Failed to pull ... 报错），判断问题性质。
3. 把镜像改为 `nginx:1.27-alpine`（用 `kubectl set image` 或 `kubectl edit`），观察故障**变化**为 CrashLoopBackOff——说明镜像问题已解决，进入下一个问题。
4. 对 CrashLoop 的 Pod：`kubectl logs --previous` 取**上一次崩溃**的日志（应能看到 `starting`），并从 `describe` 的 `Last State` 里读出 **Exit Code**，推断是启动命令的问题。
5. 修复启动命令（去掉 command/args 覆盖，让 nginx 用镜像默认 entrypoint），等待 2/2 Available。
6. 回答：Exit Code 1 / 137 / 1 且 `OOMKilled` 各代表什么？（solution 有答案）

## 验收标准

- Deployment `broken-app` 在 `cka-triage`：`image` 为 `nginx:1.27-alpine`，`containers[0].command` 与 `args` 为空。
- `kubectl -n cka-triage get deploy broken-app` 显示 `2/2`，两个 Pod `Running`。
- 你能口头复述：describe 哪一段看 pull 错误、logs --previous 看 CrashLoop、Last State 的 Exit Code 看退出原因。

## 提示（卡住再看）

<details><summary>提示 1：两种状态的本质区别</summary>

```
ImagePullBackOff : kubelet 拉不到镜像     -> 看 describe 的 Events(ErrImagePull)
CrashLoopBackOff : 容器启动了但退出(反复) -> 看 logs / logs --previous + Last State
```

STATUS 只是结果，证据永远在 `describe` 的 Events 和 `logs` 里。

</details>

<details><summary>提示 2：改镜像的最小操作</summary>

```bash
# [master]
kubectl -n cka-triage set image deployment/broken-app web=nginx:1.27-alpine
kubectl -n cka-triage rollout status deployment/broken-app
```

set image 会触发一次 rollout，新 ReplicaSet 的 Pod 会重新走"拉镜像"流程。

</details>

<details><summary>提示 3：Exit Code 速记</summary>

0 正常退出；1 应用自身错误；126/127 命令不可执行/不存在；134 SIGABRT；137 SIGKILL（常见于 OOM 或 livenessProbe 失败被杀）；143 SIGTERM。`Last State: Terminated, Reason: OOMKilled` 则是内存超 limit 被内核杀掉。

</details>
