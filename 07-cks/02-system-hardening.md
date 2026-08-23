# 02 · 系统加固：seccomp、AppArmor、沙箱运行时与内核参数

> 模块：CKS 备考 ｜ 建议时长：3.5 小时 ｜ 关联认证：CKS-System Hardening / CKS-Minimize Microservice Vulnerabilities（隔离）

## 学习目标

- 能解释 seccomp 在内核层的位置，并能给 Pod 配 RuntimeDefault 与自定义 Localhost profile
- 能编写、加载 AppArmor profile 并通过 annotation 绑定到容器，验证其生效
- 能对比 gVisor 与 Kata 的隔离原理，并在 containerd 集群上完成 RuntimeClass 全流程
- 能给出一份节点内核参数加固表，并知道哪些参数绝不能动

## 1. 三层隔离的坐标图

Kubernetes 的 workload 隔离由外向内分三层，CKS 的 System Hardening 域要求你全都用得上：

```
┌─────────────────────────────────────────────────────┐
│  宿主机内核                                          │
│   ├─ namespaces: 进程/网络/挂载点视野隔离（容器默认） │
│   ├─ cgroups:    资源限制                            │
│   ├─ capabilities: root 也被切成细粒度特权           │
│   ├─ seccomp:    系统调用过滤器（BPF，白/黑名单）    │  <-- 本篇 1 节
│   ├─ AppArmor:   LSM 强制访问控制（按路径限制读写）  │  <-- 本篇 2 节
│   └─ 沙箱运行时: 换掉"共享内核"假设                  │  <-- 本篇 3 节
│         ├─ gVisor: 用户态内核拦截 syscall            │
│         └─ Kata:   轻量虚拟机，每 Pod 一个客户内核   │
└─────────────────────────────────────────────────────┘
```

三者的分工：seccomp 管"能不能调用这个 syscall"，AppArmor 管"这个路径能不能读/写"，沙箱运行时管"就算前两层全绕过，也摸不到宿主内核"。

## 2. seccomp

### 2.1 机制

seccomp（secure computing mode）用 BPF 规则过滤容器进程发起的系统调用：动作有 `SCMP_ACT_ALLOW`（放行）、`SCMP_ACT_ERRNO`（拒绝并返回错误）、`SCMP_ACT_LOG`（放行但记录）、`SCMP_ACT_KILL`（直接杀进程）。绝大多数容器只需要几十个 syscall，放行列表外的一律拒绝，就能挡掉一大类内核漏洞利用。

Kubernetes 中 `securityContext.seccompProfile.type` 有三个值：

| 取值 | 含义 |
| --- | --- |
| `RuntimeDefault` | 使用容器运行时的默认 profile（containerd/Docker 内置，即 Docker 时代的 default profile）。K8s 1.25 起 Pod 级默认即 RuntimeDefault |
| `Localhost` | 使用 kubelet 节点上的自定义 profile 文件 |
| `Unconfined` | 不做任何过滤（等于裸奔，仅调试用） |

### 2.2 用 RuntimeDefault（一行的事，收益最大）

```yaml
# [master] kubectl apply 后创建
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-default
  namespace: default
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: main
      image: busybox:1.36
      command: ["sleep", "3600"]
```

验证容器进程确实处于 filter 模式（`Seccomp: 2` 即 seccomp filter，0 为关闭）：

```bash
# [master] 找到容器进程，在运行该 Pod 的节点上查 /proc
kubectl get pod seccomp-default -o jsonpath='{.status.containerStatuses[0].containerID}'
# 输出形如 containerd://8f5d...，取哈希段
```

```bash
# [worker1]（Pod 所在节点，8f5d 换成上一步 containerID 的哈希段）
PID=$(crictl inspect --go-template '{{.status.pid}}' 8f5d)
grep Seccomp /proc/$PID/status
# 预期: Seccomp: 2  Seccomp_filters: 1
```

### 2.3 自定义 Localhost profile

Localhost profile 放在 kubelet 节点的 `<kubelet-root>/seccomp/` 下（默认 `/var/lib/kubelet/seccomp/`），`localhostProfile` 写相对路径。先造两个有教学价值的 profile——一个只记录不拦截（观察 syscall 面），一个真拦截：

```bash
# [worker1]
sudo mkdir -p /var/lib/kubelet/seccomp/profiles
```

```json
# [worker1] /var/lib/kubelet/seccomp/profiles/audit.json —— 放行但记录全部调用
{
  "defaultAction": "SCMP_ACT_LOG",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"]
}
```

```json
# [worker1] /var/lib/kubelet/seccomp/profiles/violation.json —— 白名单放行常用调用，其余拒绝
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"],
  "syscalls": [
    {
      "names": [
        "accept4", "access", "arch_prctl", "bind", "brk", "clone",
        "close", "connect", "epoll_create1", "epoll_ctl", "epoll_pwait",
        "execve", "exit", "exit_group", "fcntl", "fstat", "futex",
        "getdents64", "getpid", "getppid", "getrandom", "getsockname",
        "gettimeofday", "ioctl", "listen", "lseek", "madvise", "mmap",
        "mprotect", "munmap", "nanosleep", "newfstatat", "open", "openat",
        "poll", "prlimit64", "pread64", "pwrite64", "read", "readlink",
        "recvfrom", "rseq", "rt_sigaction", "rt_sigprocmask",
        "rt_sigreturn", "sendto", "set_robust_list", "set_tid_address",
        "setitimer", "shutdown", "sigreturn", "socket", "stat", "sysinfo",
        "uname", "write"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

引用它的 Pod（注意相对路径不带开头的 seccomp/）：

```yaml
# [master] kubectl apply 后创建
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-violation
  namespace: default
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/violation.json
  containers:
    - name: main
      image: bash:5.2
      command: ["sh", "-c", "chmod 777 /tmp/x 2>&1; sleep 3600"]
```

`chmod` 依赖的 `chmod`/`fchmod` syscall 不在白名单里，进程会收到 Operation not permitted——这就是自定义过滤的直接效果。看审计日志可以用 audit.json 那个 profile 跑一遍，在节点 `journalctl` 或 `/var/log/syslog` 里搜 seccomp 记录。

## 3. AppArmor

### 3.1 机制

AppArmor 是 Linux LSM，按**可执行程序/容器**挂 profile，规则基于路径（"deny /etc/** w"），非特权进程逃不出规则。与 seccomp 互补：seccomp 拦 syscall 类型，AppArmor 拦文件/能力访问面。Ubuntu 默认启用（`cat /sys/module/apparmor/parameters/enabled` 应输出 Y）。

### 3.2 写一个 profile 并加载

AppArmor 是**节点本地**的：profile 必须加载到 Pod 会调度到的那台节点上。

```profile
# [worker1] /etc/apparmor.d/k8s-deny-write
#include <tunables/global>

profile k8s-deny-write flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  file,

  # 禁止容器内一切文件写入
  deny /** w,
}
```

```bash
# [worker1] 加载并确认
sudo apparmor_parser -r /etc/apparmor.d/k8s-deny-write
sudo aa-status | grep -A3 'profiles are loaded' | head -5
sudo aa-status | grep k8s-deny-write
# 预期: k8s-deny-write is enforced.（未加载时无此行）
```

### 3.3 绑定到容器（annotation 写法）

AppArmor 通过 Pod metadata annotation 指定（key 为 `container.apparmor.security.beta.kubernetes.io/<容器名>`，value 三选一）：

| value | 含义 |
| --- | --- |
| `runtime/default` | 用运行时默认 profile |
| `localhost/<profile-name>` | 用节点上已加载的 profile |
| `unconfined` | 不加载（危险） |

```yaml
# [master] kubectl apply 后创建
apiVersion: v1
kind: Pod
metadata:
  name: apparmor-denied
  namespace: default
  annotations:
    container.apparmor.security.beta.kubernetes.io/main: localhost/k8s-deny-write
spec:
  containers:
    - name: main
      image: busybox:1.36
      command: ["sleep", "3600"]
```

验证（写入被拒、读取正常、当前 profile 可查）：

```bash
# [master]
kubectl exec apparmor-denied -- sh -c 'echo x > /tmp/f; echo exit=$?'
# 预期: Permission denied, exit=1
kubectl exec apparmor-denied -- cat /etc/hostname
# 预期: 正常输出 pod 名（读不受限）
kubectl exec apparmor-denied -- cat /proc/self/attr/current
# 预期: k8s-deny-write (enforce)
```

> Kubernetes 1.30 起引入了字段化的 `securityContext.appArmorProfile` 作为 annotation 的替代，逐步演进中；考试与当前生产仍以 annotation 写法为主，字段细节以官方 Security For Linux Nodes 页为准。

## 4. gVisor 与 Kata：RuntimeClass 沙箱

### 4.1 原理对比

```
普通容器 / runc:
  容器进程 ──syscall──> 宿主机内核（共享，内核漏洞=逃逸）

gVisor / runsc:
  容器进程 ──syscall──> Sentry(用户态内核, runsc 实现) ──少量 syscall──> 宿主机内核
                        拦截并重新实现 syscalls，攻击面被压缩到 runsc 自身

Kata / kata-qemu:
  容器进程 ──syscall──> 每个 Pod 一个轻量 VM 的客户内核 ──VT-x──> 宿主机内核(hypervisor)
                        硬件级隔离，逃逸需要同时攻破客户内核与虚拟化层
```

| 维度 | gVisor（runsc） | Kata（kata-qemu） |
| --- | --- | --- |
| 隔离级别 | 系统调用拦截（用户态内核） | 硬件虚拟化（独立内核） |
| 兼容性 | 少数 syscall 不支持，个别程序异常 | 接近原生（就是 VM） |
| 启动开销 | 低（毫秒级，略高于 runc） | 高（秒级） |
| 内存开销 | 低 | 高（每 Pod 一个 VM） |
| 宿主机要求 | 无特殊要求 | /dev/kvm（VMware 需开嵌套虚拟化） |
| 典型场景 | 跑不可信或多租户无状态服务 | 强隔离需求、内核敏感负载 |

### 4.2 安装 gVisor（kubeadm + containerd 集群）

```bash
# [worker1] 官方 apt 仓库（来自 gvisor.dev 安装文档）
sudo apt-get update && sudo apt-get install -y apt-transport-https ca-certificates curl gnupg
curl -fsSL https://gvisor.dev/archive.key | sudo gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" | sudo tee /etc/apt/sources.list.d/gvisor.list > /dev/null
sudo apt-get update && sudo apt-get install -y runsc
runsc --version | head -2
```

注册到 containerd（`runtimes.runsc` 这个键名即后续 RuntimeClass 的 `handler`）：

```toml
# [worker1] 在 /etc/containerd/config.toml 末尾追加（kubelet 默认 CRI 插件路径）
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
```

```bash
# [worker1]
sudo systemctl restart containerd
```

若只是想在带 Docker 的 Ubuntu VM 上体验（不经 K8s）：

```bash
# [任意节点]（装有 Docker 的 Ubuntu VM）
sudo runsc install          # 写入 /etc/docker/daemon.json 的 runtimes 段
sudo systemctl restart docker
docker run --rm --runtime=runsc hello-world
```

### 4.3 RuntimeClass 与使用

```yaml
# [master] kubectl apply 后创建
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
---
apiVersion: v1
kind: Pod
metadata:
  name: gvisor-test
  namespace: default
spec:
  runtimeClassName: gvisor
  containers:
    - name: main
      image: busybox:1.36
      command: ["sleep", "3600"]
```

验证 Pod 真跑在 gVisor 里（gVisor 的 dmesg 自带横幅）：

```bash
# [master]
kubectl wait --for=condition=ready pod/gvisor-test --timeout=120s
kubectl exec gvisor-test -- dmesg | head -3
# 预期: 出现 gVisor 字样（普通 runc 容器看到的是宿主机内核 ring buffer）
```

### 4.4 Kata（Ubuntu 仓库版）

```bash
# [worker1] Ubuntu 22.04/24.04 自带 kata-containers 包
sudo apt-get install -y kata-containers
kata-runtime --version | head -2
ls /dev/kvm && echo "KVM OK"   # Kata-qemu 依赖 KVM
```

```toml
# [worker1] /etc/containerd/config.toml 追加（键名 kata 即 RuntimeClass handler）
[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata-qemu.v2"
```

```bash
# [worker1]
sudo systemctl restart containerd
```

```yaml
# [master] kubectl apply 后创建
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: kata
handler: kata
---
apiVersion: v1
kind: Pod
metadata:
  name: kata-test
  namespace: default
spec:
  runtimeClassName: kata
  containers:
    - name: main
      image: busybox:1.36
      command: ["sleep", "3600"]
```

验证：`kubectl exec kata-test -- uname -r` 会显示形如 `5.15.x-kata` 的客户内核版本，与宿主机 `uname -r` 不同。

VMware 练习环境注意：Kata 需要 CPU 虚拟化扩展直通（vCPU 设置里勾选"虚拟化 Intel VT-x/EPT"），否则 `/dev/kvm` 不存在、Pod 一直 ContainerCreating。gVisor 无此要求，虚拟机里开箱即用。

## 5. 内核参数加固表

节点级 sysctl 统一放 `/etc/sysctl.d/`，`sysctl --system` 生效。推荐值：

| 参数 | 建议值 | 作用 |
| --- | --- | --- |
| `kernel.kptr_restrict` | 2 | 隐藏内核指针，防 /proc 泄露内核地址（KASLR 配套） |
| `kernel.dmesg_restrict` | 1 | 非 root 不能读 dmesg（防内核日志泄露内存布局） |
| `kernel.unprivileged_bpf_disabled` | 1 | 禁止非特权用户加载 BPF 程序 |
| `kernel.yama.ptrace_scope` | 2 | 限制 ptrace 到祖先进程（反调试/防注入） |
| `kernel.perf_event_paranoid` | 3 | 禁止非特权 perf 事件（侧信道防护） |
| `fs.protected_symlinks` / `fs.protected_hardlinks` | 1 / 1 | 防符号链接/硬链接提权（Ubuntu 默认已开） |
| `fs.suid_dumpable` | 0 | SUID 程序不产生 core dump（防内存泄露） |
| `vm.unprivileged_userfaultfd` | 0 | 禁非特权 userfaultfd（曾被多个提权漏洞利用） |
| `net.ipv4.conf.all.rp_filter` | 1 | 反向路径校验（防 IP 欺骗） |

```bash
# [worker1] 一次落地
sudo tee /etc/sysctl.d/99-hardening.conf > /dev/null <<'EOF'
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
kernel.yama.ptrace_scope = 2
kernel.perf_event_paranoid = 3
fs.suid_dumpable = 0
vm.unprivileged_userfaultfd = 0
net.ipv4.conf.all.rp_filter = 1
EOF
sudo sysctl --system | grep -E 'kptr|dmesg|bpf|yama'
```

**绝不能乱动的参数**：

- `net.ipv4.ip_forward = 1`：CNI（Calico 转发 Pod 流量）依赖它，关掉整网断
- `vm.overcommit_memory = 1`：kubelet 期望值，`protectKernelDefaults: true` 时改回 0 会拒绝启动
- `kernel.keys.root_maxkeys` 等：kubelet 在部分内核上也有期望值，报错提示为准

## 实战演练：同一容器跑三种隔离

目标：busybox 容器分别以 runc＋seccomp、runc＋AppArmor、gVisor 运行，观察差异。

```bash
# [worker1] 准备 seccomp profile 与 AppArmor profile（按第 2、3 节内容落盘）
sudo mkdir -p /var/lib/kubelet/seccomp/profiles
sudo tee /var/lib/kubelet/seccomp/profiles/audit.json > /dev/null <<'EOF'
{
  "defaultAction": "SCMP_ACT_LOG",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86", "SCMP_ARCH_X32"]
}
EOF
sudo tee /etc/apparmor.d/k8s-deny-write > /dev/null <<'EOF'
#include <tunables/global>

profile k8s-deny-write flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  file,
  deny /** w,
}
EOF
sudo apparmor_parser -r /etc/apparmor.d/k8s-deny-write
sudo aa-status | grep k8s-deny-write
```

```bash
# [master] 依次创建三个 Pod（yaml 见正文 2.2、2.3、3.3、4.3 各节）
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: iso-apparmor
  annotations:
    container.apparmor.security.beta.kubernetes.io/main: localhost/k8s-deny-write
spec:
  containers:
    - name: main
      image: busybox:1.36
      command: ["sleep", "3600"]
EOF
kubectl exec iso-apparmor -- sh -c 'touch /tmp/a; echo rc=$?'
# 预期: Permission denied, rc=1

kubectl exec gvisor-test -- dmesg | head -1
# 预期: gVisor 横幅

kubectl exec seccomp-default -- cat /proc/self/status | grep Seccomp
# 预期: Seccomp: 2
```

清理：`kubectl delete pod iso-apparmor gvisor-test seccomp-default seccomp-violation`。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| Pod 卡在 ContainerCreating，Events 报 "profile not found" | Localhost profile 路径写错，或文件不在 Pod 所在节点 | 路径相对 `/var/lib/kubelet/seccomp/`；写 `profiles/xx.json` 而不是 `seccomp/profiles/xx.json`；调度到哪台节点就在哪台放文件 |
| AppArmor Pod 起不来，报 cannot load profile | 节点上没加载该 profile，或 annotation 的容器名写错 | `apparmor_parser -r` 加载后 `aa-status` 确认；annotation key 必须精确匹配容器名 |
| seccomp 白名单太紧，应用随机报错 | 缺少该运行时需要的 syscall | 先切 `SCMP_ACT_LOG` profile 跑一遍，从日志收集实际 syscall 集再生成白名单 |
| gVisor Pod 报 runsc 未注册 | containerd config.toml 的 runtimes 键名与 RuntimeClass handler 不一致，或改完没重启 containerd | 两边统一为 `runsc`；`systemctl restart containerd` 后 `crictl info | grep -A2 runsc` 验证 |
| Kata Pod 一直 ContainerCreating | 节点无 /dev/kvm（VMware 未开嵌套虚拟化） | vCPU 勾选虚拟化 VT-x/EPT；`kata-runtime check` 诊断；或改用 gVisor |
| 加固 sysctl 后网络异常 / kubelet 不起 | 动了 ip_forward 或 kubelet 期望的参数 | 恢复 `net.ipv4.ip_forward=1`；`journalctl -u kubelet -n 50` 看具体报错 |

## 自测

1. seccomp RuntimeDefault 和自定义 Localhost profile 各适合什么场景？为什么"先 LOG 再 ALLOW 清单"是推荐流程？

<details><summary>答案</summary>

RuntimeDefault 覆盖常见安全基线、零维护成本，适合绝大多数业务；Localhost 用于需要更紧白名单（如只读工具容器）或需要放行特殊 syscall 的程序。先用 SCMP_ACT_LOG 收集真实调用集，再据此生成 ALLOW 白名单，可以避免"拍脑袋清单"把业务打挂。
</details>

2. AppArmor annotation 的 value `unconfined` 与不写 annotation 有区别吗？什么情况下 Pod 仍会被 AppArmor 限制？

<details><summary>答案</summary>

显式 `unconfined` 表示明确要求不加载（等价继承节点/运行时状态里的无保护），不写 annotation 则由 kubelet/运行时决定（现代版本通常继承节点默认）。若容器镜像内进程自带 profile（如某些基础镜像），仍可能被节点上其他强制 profile 波及，但 Kubernetes 层面 annotation 是主开关。
</details>

3. gVisor 说"拦截 syscall"，为什么它对宿主内核漏洞免疫性更好？它的剩余风险在哪？

<details><summary>答案</summary>

容器进程的 syscall 由 runsc 的 Sentry 在用户态重新实现，宿主内核只收到 runsc 代理的少量、受控调用，大量内核攻击面（如冷门 syscall 的漏洞）不再可达。剩余风险是 runsc 自身代码缺陷，以及它必须放行的那些宿主调用路径。
</details>

4. 同样是沙箱，为什么 Kata 的内存开销显著高于 gVisor？给出选型建议。

<details><summary>答案</summary>

Kata 给每个 Pod 一个真实 VM（独立内核+QEMU 进程），固定内存开销就是几十到几百 MB；gVisor 只是宿主机上的用户态进程，无独立内核。追求高密度、快速伸缩选 gVisor；需要硬件级边界（合规、跑深度不可信代码、依赖非常规 syscall）选 Kata。
</details>

5. 你把 `kernel.unprivileged_bpf_disabled=1` 推到所有节点后，某个 Cilium eBPF 功能失效了，怎么权衡？

<details><summary>答案</summary>

该参数只禁"非特权" BPF；Cilium agent 以 root 加载 eBPF 不受影响。失效的多半是某组件以非特权方式使用 BPF（或 Falco/部分观测 agent）。要么让该组件以特权运行加载 BPF，要么在受影响节点回退该参数——安全基线与功能冲突时，先确认组件真实的凭证需求再局部放宽，并记录例外。
</details>

## 延伸阅读

- Seccomp 教程（官方 Tutorial）：<https://kubernetes.io/docs/tutorials/security/seccomp/>
- AppArmor 教程（官方 Tutorial）：<https://kubernetes.io/docs/tutorials/security/apparmor/>
- Security For Linux Nodes：<https://kubernetes.io/docs/concepts/security/linux-kernel-security-constraints/>
- RuntimeClass 与 gVisor 官方文档：<https://kubernetes.io/docs/concepts/containers/runtime-class/>、<https://gvisor.dev/docs/>
- Kata Containers 官方文档：<https://katacontainers.io/docs/>
