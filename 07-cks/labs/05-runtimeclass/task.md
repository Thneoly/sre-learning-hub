# Lab 05 · RuntimeClass：把 Pod 交给 gVisor 沙箱运行

> 难度：★★★ ｜ 考点：CKS-系统加固（gVisor/Kata RuntimeClass） ｜ 前置：无 ｜ 预计 30~45 分钟

## 前置安装（环境不具备时的替代验证方式见本节末尾）

本 lab 完整体验需要在**运行 Pod 的节点**上安装备用容器运行时（gVisor 的 `runsc` 或 Kata Containers 的 `kata`），并注册进 containerd。在 master 上执行：

```bash
# [master] 安装 gVisor runsc
curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases/release/main/x86_64 /" | sudo tee /etc/apt/sources.list.d/gvisor.list
sudo apt-get update && sudo apt-get install -y runsc

# [master] 把 gvisor 运行时注册进 containerd 并重启
sudo tee -a /etc/containerd/config.toml >/dev/null <<'EOF'
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]
  runtime_type = "io.containerd.runsc.v1"
EOF
sudo systemctl restart containerd

# [master] 验证 containerd 已注册 gvisor runtime
sudo crictl info | grep -A2 '"gvisor"'
```

**apt 源不可用时的替代安装路径**（storage.googleapis.com 的 apt 仓库部分网络下无 Release 文件；另外 Ubuntu 自带的 `runsc` 包太老，在 6.x 内核上沙箱会启动即崩，别用）——直接下载官方二进制即可，`runsc` 与 v1 shim 各约 100MB：

```bash
# [master] 直接下载 release 二进制（含 containerd-shim-runsc-v1，缺它 Pod 会报
# "runtime io.containerd.runsc.v1 binary not installed"）
BASE=https://storage.googleapis.com/gvisor/releases/release/latest/x86_64
curl -fsSL "$BASE/runsc"                     -o /tmp/runsc-new
curl -fsSL "$BASE/containerd-shim-runsc-v1"  -o /tmp/shim-v1
sudo install -m 0755 /tmp/runsc-new /usr/local/bin/runsc
sudo install -m 0755 /tmp/shim-v1   /usr/local/bin/containerd-shim-runsc-v1
sudo rm -f /tmp/runsc-new /tmp/shim-v1
# 之后同样执行上面的 containerd 注册步骤
```

**环境不具备时（无法出网安装 / 不允许重启 containerd）的替代验证方式**：跳过安装，直接完成"模拟路径"——任务清单第 1、2、3 步（创建 RuntimeClass 对象 + 创建引用它的 Pod + 保留其 spec）照做；Pod 可能停留在 `ContainerCreating`/`Pending`（节点上没有对应 handler），这是预期现象，不影响判分。判分脚本对"未安装 gVisor"的模拟环境同样给分，但会额外检查：一旦检测到节点已注册 gvisor runtime，则要求 Pod 真正 Running。

## 场景

一批处理外部上传文件的服务被安全组要求"必须运行在内核隔离的沙箱里"。K8s 的机制是 RuntimeClass：一个 API 对象把 `handler`（节点上注册的运行时名）映射成 Pod spec 里的 `runtimeClassName`，kubelet 据此选择 containerd 里的备用运行时。你要部署 gVisor（用户态内核，拦截系统调用）并让 Pod 明确跑在 `runsc` 上，再用 `/proc` 验证内核确实换了。

```
普通 Pod:      容器 syscall --> Linux Kernel
gVisor Pod:    容器 syscall --> Sentry(用户态内核, runsc) --> Linux Kernel(仅必要部分)
Kata Pod:      容器 --> 独立轻量 VM 的内核
```

## 任务清单

1. （有环境）按文首命令安装 `runsc` 并注册到 containerd；确认 `crictl info` 能看到 `gvisor` runtime。
2. 创建 namespace `cks-lab05` 和 RuntimeClass 对象 `gvisor`：`handler: gvisor`，并加 `scheduling` 注解说明用途（可选）。
3. 创建 Pod `sandbox-web`（busybox:1.36，`sleep 3600`），`runtimeClassName: gvisor`。
4. 验证：Pod Running 后 `kubectl exec ... -- dmesg | head -1`——gVisor 下 dmesg 输出 `gVisor` 而非宿主内核信息；`uname -a` 也不等于宿主机内核版本。
5. （模拟路径）若未安装 gVisor：确保 RuntimeClass 对象存在、Pod spec 中 `runtimeClassName` 字段存在，记录 Pod 实际 phase 并理解原因。

## 验收标准

- `kubectl get runtimeclass gvisor` 存在，`HANDLER` 列为 `gvisor`
- `kubectl -n cks-lab05 get pod sandbox-web -o jsonpath='{.spec.runtimeClassName}'` 输出 `gvisor`
- 装了 gVisor 的环境：Pod Running，且 `dmesg | head -1` 含 `gVisor`
- 模拟环境：Pod 存在（phase 任意），check.sh 输出 `SIMULATED` 提示

运行判分脚本：

```bash
# [master]
cd 07-cks/labs/05-runtimeclass
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：RuntimeClass 的 handler 填什么</summary>

`handler` 必须与节点 containerd `config.toml` 里 `runtimes.<name>` 的 `<name>` 完全一致（本实验为 `gvisor`），不是二进制名 `runsc`。kubelet 把这个名字透传给 containerd 的 `runtime_type`/runtime 名称。
</details>

<details><summary>提示 2：Pod 卡在 ContainerCreating 怎么排查</summary>

`kubectl describe pod` 看 Events：`RunPodSandbox failed: runtime handler "gvisor" not found` 说明节点没注册该 handler；先回到文首注册步骤，再删除 Pod 重建。
</details>

<details><summary>提示 3：怎么证明跑的是 gVisor 而不是 runc</summary>

容器里 `dmesg | head -1` 输出 `gVisor`（runc 会显示宿主内核环形缓冲），`uname -r` 也与宿主不同。这两个是最快的"沙箱生效"证据。
</details>
