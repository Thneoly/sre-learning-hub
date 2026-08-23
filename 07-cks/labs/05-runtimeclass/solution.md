# Lab 05 · 解答 —— RuntimeClass：把 Pod 交给 gVisor 沙箱运行

## 背景：RuntimeClass 的三件套

```
RuntimeClass(api 对象)          Pod spec                 节点 containerd
  name: gvisor                   runtimeClassName: gvisor   runtimes.gvisor:
  handler: gvisor    ---选中-->                            runtime_type: io.containerd.runsc.v1
                                                            \_ 底层调用 runsc 二进制
```

- **handler**：节点上注册的运行时名，kubelet 拿它去请求 containerd；
- **runtimeClassName**：Pod 级字段，任何 workload（Deployment/Job/StatefulSet 的 podTemplate）都能引用；
- **运行时本体**：gVisor（`runsc`，用户态内核，拦截容器 syscall）或 Kata（每个 Pod 一个轻量 VM）。两者 handler 名不同，RuntimeClass 写法完全一致。

gVisor vs Kata 取舍：gVisor 启动快、密度高，兼容性略差（部分 syscall 未实现）；Kata 隔离最强（独立内核），资源开销更大。CKS 考试只要求会创建 RuntimeClass 并让 Pod 引用。

## 步骤 1：安装 gVisor 并注册（有环境路径）

```bash
# [master]
curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases/release/main/x86_64 /" | sudo tee /etc/apt/sources.list.d/gvisor.list
sudo apt-get update && sudo apt-get install -y runsc
```

注册进 containerd：

```bash
# [master]
sudo cp /etc/containerd/config.toml /etc/containerd/config.toml.bak
sudo tee -a /etc/containerd/config.toml >/dev/null <<'EOF'
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]
  runtime_type = "io.containerd.runsc.v1"
EOF
sudo systemctl restart containerd
```

验证（输出中应出现 `"gvisor"` 及其 runtime_type）：

```bash
# [master]
sudo crictl info | grep -B1 -A3 '"gvisor"'
```

注意：重启 containerd 会短暂影响节点上所有沙箱拉起，存量 Pod 不受影响；生产上应先排水再操作。

## 步骤 2：创建 RuntimeClass

```yaml
# [master] runtimeclass-gvisor.yaml
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: gvisor
scheduling:
  nodeSelector:
    kubernetes.io/os: linux
```

```bash
# [master]
kubectl apply -f runtimeclass-gvisor.yaml
kubectl get runtimeclass gvisor -o wide
# NAME     HANDLER   AGE
# gvisor   gvisor    5s
```

`scheduling` 段可选：可加 `nodeSelector`（只调度到装了 runsc 的节点，多节点集群必备）或 `tolerations`。本单节点实验保留一个简单 selector。

## 步骤 3：创建引用 RuntimeClass 的 Pod

```yaml
# [master] sandbox-web.yaml
apiVersion: v1
kind: Pod
metadata:
  name: sandbox-web
  namespace: cks-lab05
  labels:
    app: sandbox-web
spec:
  runtimeClassName: gvisor
  containers:
  - name: main
    image: busybox:1.36
    command: ["sleep", "3600"]
```

```bash
# [master]
kubectl create ns cks-lab05
kubectl apply -f sandbox-web.yaml
kubectl -n cks-lab05 get pod sandbox-web
```

## 步骤 4：验证沙箱真的生效

```bash
# [master]
kubectl -n cks-lab05 exec sandbox-web -- dmesg | head -1
# gVisor  (普通 runc Pod 这里会输出宿主内核的启动日志)

kubectl -n cks-lab05 exec sandbox-web -- uname -r
# 形如 4.4.0 （gVisor 伪装的内核版本，与宿主 5.15/6.x 明显不同）

# 对照：在 default ns 起一个 runc Pod 比对
kubectl run runc-ref --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl exec runc-ref -- dmesg | head -1   # 宿主内核日志
```

## 模拟路径（未安装 gVisor 时）

依次执行步骤 2、3 的 `kubectl apply`。观察：

```bash
# [master]
kubectl -n cks-lab05 get pod sandbox-web
# NAME          READY   STATUS              RESTARTS
# sandbox-web   0/1     ContainerCreating   0

kubectl -n cks-lab05 describe pod sandbox-web | tail -5
# Events: ... RunPodSandbox failed: runtime handler "gvisor" not found
```

Pod 会一直卡住（调度到了节点，但 kubelet/containerd 找不到 handler）。这本身就是一个很好的故障演练：**RuntimeClass 是纯 API 对象，创建永远成功；真正决定 Pod 能否跑起来的是节点上的运行时注册**。判分脚本在此环境下检查 RuntimeClass 的 handler 字段和 Pod spec 的 runtimeClassName 字段。

## 给 Deployment 用（举一反三）

```yaml
# [master] deploy-gvisor.yaml（示意，判分不依赖）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sandbox-app
  namespace: cks-lab05
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sandbox-app
  template:
    metadata:
      labels:
        app: sandbox-app
    spec:
      runtimeClassName: gvisor   # 写在 podTemplate.spec
      containers:
      - name: app
        image: nginx:1.27
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `runtime handler "gvisor" not found` | containerd 没注册该名字 | 核对 config.toml 的 `runtimes.gvisor` 段，重启 containerd |
| `runtime "io.containerd.runsc.v1" binary not installed "containerd-shim-runsc-v1"` | 只装了 runsc，没有 shim 二进制（Ubuntu 仓库的 runsc 包不含 shim；gVisor 官方 apt 源在部分网络下无 Release 文件装不上） | 从 `https://storage.googleapis.com/gvisor/releases/release/latest/x86_64/containerd-shim-runsc-v1` 直接下载到 `/usr/local/bin/`（同目录下也放新版 runsc），无需重启 containerd |
| Pod 沙箱反复退出（runsc exit 137） | Ubuntu 自带 runsc 太老（2023 版），在 6.x 内核上启动即崩 | 用上面的直接下载路径装最新 release 二进制 |
| 装完 runsc 重启 containerd 后节点 NotReady | config.toml 追加段格式错误（嵌套错位） | 用备份恢复 `config.toml.bak`，用 `containerd config dump` 验证 |
| RuntimeClass 创建报错 `handler: Required value` | 忘写 handler 字段 | handler 是必填字段 |
| gVisor 下某些镜像跑不起来 | 镜像用了 gVisor 未实现的 syscall | 换 Kata 或镜像降级；gVisor 兼容性以官方 issue 列表为准 |
| check.sh 误判 Running | 模拟环境里 Pod 恰好 Running | 不会：脚本先探测 config.toml 再决定检查项 |

## 判分结果

```bash
# [master]
cd 07-cks/labs/05-runtimeclass
chmod +x check.sh
./check.sh
```

有 gVisor 环境：

```
PASS: namespace cks-lab05 存在
PASS: RuntimeClass gvisor 存在
PASS: RuntimeClass handler 为 gvisor
PASS: Pod sandbox-web 存在于 cks-lab05
PASS: Pod spec.runtimeClassName 为 gvisor
PASS: 节点已注册 gvisor runtime，Pod 应为 Running
PASS: 沙箱生效：容器内 dmesg 输出含 gVisor

SCORE: 7/7
```

模拟环境：

```
PASS: namespace cks-lab05 存在
PASS: RuntimeClass gvisor 存在
PASS: RuntimeClass handler 为 gvisor
PASS: Pod sandbox-web 存在于 cks-lab05
PASS: Pod spec.runtimeClassName 为 gvisor
SIMULATED: 节点未注册 gvisor runtime，跳过 Running/dmesg 检查（模拟环境按 spec 判分）
PASS: 模拟环境：RuntimeClass 与 Pod spec 引用完整

SCORE: 6/6
```

## 延伸阅读

- RuntimeClass 官方文档: https://kubernetes.io/zh-cn/docs/concepts/containers/runtime-class/
- gVisor 安装指南: https://gvisor.dev/docs/user_guide/install/
- Kata Containers: https://github.com/kata-containers/kata-containers
