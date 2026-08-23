# Lab 04 · Seccomp：RuntimeDefault 与自定义 profile 阻断 syscall

> 难度：★★★ ｜ 考点：CKS-系统加固（Seccomp） ｜ 前置：无 ｜ 预计 30~40 分钟

## 场景

安全团队下发了两条要求：

1. 所有新业务 Pod 默认启用 `seccompProfile: RuntimeDefault`（容器运行时的默认 syscall 白名单）——这是 CKS 反复强调的基线；
2. 一个沙箱化的第三方工具需要更细的控制：明确禁止 `chmod` 系列 syscall，防止其改动文件权限位埋后门。

你要在同 namespace 里做两组对照实验：A 组只开 RuntimeDefault；B 组写一个自定义 seccomp profile 放到 kubelet 目录，通过 `Localhost` 类型引用，并证明 `chmod` 在 B 组容器内确实被 `EPERM` 拒绝。

## 任务清单

1. 创建 namespace `cks-lab04`。
2. 部署 Pod `seccomp-default`（busybox:1.36，`sleep 3600`），容器 `securityContext.seccompProfile.type: RuntimeDefault`，确认 Running。
3. 在节点上创建目录 `/var/lib/kubelet/seccomp/profiles/`，写入自定义 profile `block-chmod.json`：默认放行（`SCMP_ACT_ALLOW`），但把 `chmod` / `fchmod` / `fchmodat` 设为 `SCMP_ACT_ERRNO`（返回 EPERM）。
4. 部署 Pod `seccomp-block-chmod`（busybox:1.36，`sleep 3600`），`seccompProfile.type: Localhost`、`localhostProfile: profiles/block-chmod.json`，确认 Running。
5. 对照验证：两个 Pod 内都先 `touch /tmp/f` 成功；`chmod 400 /tmp/f` 在 `seccomp-default` 里成功、在 `seccomp-block-chmod` 里报 `Operation not permitted`。

## 验收标准

- `kubectl -n cks-lab04 get pods` 两个 Pod 均 Running
- `seccomp-default` 的 spec 里 `seccompProfile.type == RuntimeDefault`
- `seccomp-block-chmod` 的 spec 里 `seccompProfile.type == Localhost` 且 `localhostProfile == profiles/block-chmod.json`
- 节点上 `/var/lib/kubelet/seccomp/profiles/block-chmod.json` 存在且包含 `SCMP_ACT_ERRNO`
- `seccomp-block-chmod` 内执行 `chmod` 退出码非 0

运行判分脚本：

```bash
# [master]
cd 07-cks/labs/04-seccomp-profile
chmod +x check.sh
sudo ./check.sh    # /var/lib/kubelet 目录仅 root 可读；脚本内 kubectl 会自动选对 kubeconfig
```

## 提示（卡住再看）

<details><summary>提示 1：localhostProfile 的路径基准</summary>

`localhostProfile` 是相对 kubelet 的 `--root-dir`（默认 `/var/lib/kubelet`）的路径。写 `profiles/block-chmod.json` 对应文件系统路径 `/var/lib/kubelet/seccomp/profiles/block-chmod.json`。注意不是相对当前目录。
</details>

<details><summary>提示 2：SCMP_ACT_ERRNO 和 SCMP_ACT_KILL 的区别</summary>

`ERRNO` 让 syscall 返回错误码（EPERM），进程活着并得到"正常失败"；`KILL` 直接 SIGSYS 杀进程。业务兼容性要求高用 ERRNO，锁死已知恶意路径用 KILL。本 lab 用 ERRNO 才能看到 `chmod: /tmp/f: Operation not permitted`。
</details>

<details><summary>提示 3：怎么确认 RuntimeDefault 生效</summary>

在 Pod 内 `grep Seccomp /proc/self/status`，输出 `Seccomp: 2`（2 = filter 模式）。若 Pod 未设置 seccomp 且 kubelet 未默认，通常为 `Seccomp: 2`（Docker 默认也有 profile）或 `0`（disabled），cka 集群以 `/proc` 实测为准。
</details>
