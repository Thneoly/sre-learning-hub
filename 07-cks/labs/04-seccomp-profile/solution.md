# Lab 04 · 解答 —— Seccomp：RuntimeDefault 与自定义 profile 阻断 syscall

## 背景：seccomp 的三种配置入口

```
Pod spec securityContext.seccompProfile.type:
  +-- RuntimeDefault : 继承容器运行时(containerd/Docker)的默认白名单（~300 个常用 syscall）
  +-- Localhost      : 加载 kubelet 节点上的自定义 profile 文件（JSON，libseccomp 格式）
  +-- Unconfined     : 不做过滤（等于裸奔，restricted PSA 不允许）
```

Seccomp 只过滤 syscall 本身，不区分参数与路径（那是 AppArmor 的活）。三层防线各司其职：

| 层 | 控制粒度 | 典型用途 |
|---|---|---|
| Seccomp | 哪些 syscall | 禁 `chmod`、`mount`、`bpf` 等 |
| AppArmor | 哪些文件/能力 | 禁写 `/tmp`、禁读 shadow |
| LSM+Capabilities | root 的子权限 | drop NET_ADMIN 等 |

## 步骤 1：创建 namespace

```bash
# [master]
kubectl create ns cks-lab04
```

## 步骤 2：Pod A —— RuntimeDefault

```yaml
# [master] seccomp-default.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-default
  namespace: cks-lab04
spec:
  containers:
  - name: main
    image: busybox:1.36
    command: ["sleep", "3600"]
    securityContext:
      seccompProfile:
        type: RuntimeDefault
```

```bash
# [master]
kubectl apply -f seccomp-default.yaml
kubectl -n cks-lab04 get pod seccomp-default
kubectl -n cks-lab04 exec seccomp-default -- grep Seccomp /proc/self/status
# Seccomp:    2   （2 = seccomp filter 模式，已生效）
```

`securityContext` 写在 Pod 级（`spec.securityContext`）会被所有容器继承、写在容器级（`spec.containers[*].securityContext`）只作用于该容器——两者运行效果一样，但对象里存的位置不同：Pod 级写法不会填充 `containers[0].securityContext` 字段，本 lab 的判分脚本查的是容器级字段，所以按上面容器级写。

## 步骤 3：编写自定义 profile

```bash
# [master]
sudo mkdir -p /var/lib/kubelet/seccomp/profiles

sudo tee /var/lib/kubelet/seccomp/profiles/block-chmod.json >/dev/null <<'EOF'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "architectures": [
    "SCMP_ARCH_X86_64",
    "SCMP_ARCH_X86",
    "SCMP_ARCH_X32"
  ],
  "syscalls": [
    {
      "names": ["chmod", "fchmod", "fchmodat"],
      "action": "SCMP_ACT_ERRNO",
      "errnoRet": 1
    }
  ]
}
EOF

sudo cat /var/lib/kubelet/seccomp/profiles/block-chmod.json | python3 -m json.tool
```

设计说明：

- `defaultAction: SCMP_ACT_ALLOW`——先全放行，再精准打洞。这是"业务兼容优先"的写法；反过来的全默认拒绝 + 大白名单（`SCMP_ACT_ERRNO` 为 defaultAction、逐个 allow 上百个 syscall）安全性最高，但漏一个 syscall 业务就挂，适合逐业务打磨；
- `errnoRet: 1` = EPERM，进程看到的是普通的"权限不足"而不是被杀；
- 多节点集群需把该文件分发到每个可能调度该 Pod 的节点（Ansible/ DaemonSet 都行）。

## 步骤 4：Pod B —— Localhost 引用

```yaml
# [master] seccomp-block-chmod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-block-chmod
  namespace: cks-lab04
spec:
  containers:
  - name: main
    image: busybox:1.36
    command: ["sleep", "3600"]
    securityContext:
      seccompProfile:
        type: Localhost
        localhostProfile: profiles/block-chmod.json
```

```bash
# [master]
kubectl apply -f seccomp-block-chmod.yaml
kubectl -n cks-lab04 get pod seccomp-block-chmod
```

如果 Pod 一直 `ContainerCreating`，describe 常见错误：`failed to load seccomp profile` ——路径错了或文件不是合法 JSON。

## 步骤 5：对照验证

```bash
# [master]
# 限制组：touch 成功（open/at 未被拦），chmod 被拒
kubectl -n cks-lab04 exec seccomp-block-chmod -- touch /tmp/f
kubectl -n cks-lab04 exec seccomp-block-chmod -- chmod 400 /tmp/f
# chmod: /tmp/f: Operation not permitted
# error: command terminated with exit code 1

# 对照组：chmod 正常
kubectl -n cks-lab04 exec seccomp-default -- touch /tmp/f
kubectl -n cks-lab04 exec seccomp-default -- chmod 400 /tmp/f && echo OK
# OK
```

`Operation not permitted`（EPERM）正是 `SCMP_ACT_ERRNO` + `errnoRet: 1` 的效果。节点侧可用审计日志确认（若打开了审计）：

```bash
# [master]
sudo dmesg | grep -i seccomp | tail
```

## 顺带理解 RuntimeDefault 里有什么

containerd 的默认 profile（`github.com/containerd/containerd/contrib/seccomp`）放行了日常 syscall、拒绝 `kexec_load`、旧 `mount` 一类高危调用，但 **`chmod` 在白名单里**——所以对照组成功。想看某运行时默认 profile 全文，参考 containerd 源码 contrib/seccomp/seccomp_default.go（以官方仓库为准）。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `failed to load seccomp profile` | `localhostProfile` 路径写成了绝对路径或放错目录 | 必须相对 `/var/lib/kubelet`，文件在 `/var/lib/kubelet/seccomp/profiles/` 下 |
| Pod 起不来且 profile 明明存在 | JSON 语法错（多余逗号等） | `python3 -m json.tool` 校验后再 apply |
| 改了 profile 不生效 | seccomp 在容器启动时加载，运行期不热更 | 删 Pod 重建 |
| restricted PSA 拒绝 Pod | `seccompProfile.type: Unconfined` 或未设置（版本相关） | 用 RuntimeDefault 或 Localhost |
| 想拦容器内提权 syscall | `chmod` 只是表象 | 再加 `setuid`、`setgid`、`unshare`、`bpf` 等到 ERRNO 列表 |

## 判分结果

```bash
# [master]
cd 07-cks/labs/04-seccomp-profile
chmod +x check.sh
sudo ./check.sh    # /var/lib/kubelet 目录 0700 仅 root 可读
```

预期输出：

```
PASS: namespace cks-lab04 存在
PASS: profile 文件 /var/lib/kubelet/seccomp/profiles/block-chmod.json 存在
PASS: profile 默认动作 SCMP_ACT_ALLOW
PASS: profile 将 chmod/fchmod/fchmodat 设为 SCMP_ACT_ERRNO
PASS: profile 是合法 JSON
PASS: Pod seccomp-default 为 Running
PASS: seccomp-default 引用 RuntimeDefault
PASS: Pod seccomp-block-chmod 为 Running
PASS: seccomp-block-chmod 引用 Localhost profile
PASS: 限制 Pod 内 chmod 被拒（Operation not permitted）
PASS: 对照 Pod 内 chmod 成功（RuntimeDefault 不拦 chmod）

SCORE: 11/11
```

## 延伸阅读

- Seccomp 官方教程: https://kubernetes.io/zh-cn/docs/tutorials/security/seccomp/
- Pod 安全上下文: https://kubernetes.io/zh-cn/docs/tasks/configure-pod-container/security-context/
