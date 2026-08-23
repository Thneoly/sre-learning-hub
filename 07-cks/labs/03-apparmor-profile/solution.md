# Lab 03 · 解答 —— AppArmor Profile 限制 Nginx 文件写入

## 背景：AppArmor 在容器栈里的位置

```
进程(nginx) --syscall--> Linux Kernel
                         |-- DAC: uid/gid rwx        （容器内 root 基本全过）
                         |-- LSM: AppArmor profile   （按 profile 白名单二次裁决）
                         \-- Seccomp: syscall 过滤    （lab 04 的主题）
```

AppArmor 是路径级（path-based）的强制访问控制：profile 中没有显式允许的路径，读/写/执行都会被拒。它与 Seccomp 互补——Seccomp 管"能调哪些 syscall"，AppArmor 管"能碰哪些文件/能力"。

## 步骤 1：编写 profile

```bash
# [master]
sudo tee /etc/apparmor.d/docker-nginx-cks >/dev/null <<'EOF'
#include <tunables/global>

profile docker-nginx-cks flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>

  # 网络：nginx 只需要常规 inet 套接字
  network inet tcp,
  network inet udp,
  network inet icmp,
  deny network raw,

  # 日志与 pid：nginx 运行必需的可写路径（白名单）
  # /var/run 是指向 /run 的软链，attach_disconnected 下内核审计路径是 /run/nginx.pid，两条都要写
  /var/log/nginx/** rw,
  /var/run/nginx.pid rw,
  /run/nginx.pid rw,
  /var/cache/nginx/** rw,

  # 日志管道：镜像把 access.log/error.log 软链到 /dev/stdout、/dev/stderr
  /dev/std* rw,
  /proc/1/fd/* rw,

  # entrypoint 的 25-listen 脚本会改写默认 vhost；dpkg-query 查包元数据
  /etc/nginx/conf.d/*.conf rw,
  /var/lib/dpkg/status r,

  # 用户与名称解析（只读；写仍被下方 deny 拦住）
  /etc/passwd r,
  /etc/nsswitch.conf r,
  /etc/group r,
  /etc/hosts r,
  /etc/resolv.conf r,

  # 配置与静态资源：只读
  /etc/nginx/** r,
  /usr/share/nginx/html/** r,

  # capability：nginx master 切 worker 用户、绑定 80 端口所需
  capability chown,
  capability dac_override,
  capability setuid,
  capability setgid,
  capability net_bind_service,
  capability kill,

  # 目录枚举（entrypoint 用 find 扫 docker-entrypoint.d）
  / r,
  /docker-entrypoint.d/ r,

  # 容器入口脚本与基础工具（nginx 官方镜像的 docker-entrypoint）
  /docker-entrypoint.sh rix,
  /docker-entrypoint.d/** rix,
  /bin/* rix,
  /usr/bin/* rix,

  # 二进制与库：可读可执行
  /usr/sbin/nginx rix,
  /usr/lib/** mr,

  # 显式拒绝敏感文件（即使 allow 规则意外覆盖也能拦住）
  deny /etc/shadow rwklx,
  deny /etc/passwd wklx,
  deny /etc/group wklx,

  # /tmp 全禁写（AppArmor 默认拒绝已覆盖，这里显式写出便于审计）
  deny /tmp/* rw,
  deny /tmp/** rw,
}
EOF
```

要点：

- `profile docker-nginx-cks`——名字会被 Pod annotation 引用；
- `flags=(attach_disconnected,mediate_deleted)`：容器文件系统与宿主机的命名空间差异需要这两个标志，官方示例同款；
- `rw` / `r` / `rix` / `mr`：读写 / 只读 / 继承执行 / mmap+执行；
- `deny ... rwklx`：r 读 w 写 k 锁 l 硬链接 x 执行，全部禁止；
- **只 allow `/var/log/nginx/**` 这类"业务路径"是起不来 nginx 的**（实测教训）：官方镜像的入口是 `/docker-entrypoint.sh`（要 `rix`），master 进程要读 `/etc/passwd` 找 nginx 用户（要显式 `r`，`deny ... wklx` 只拦写）、要 `setuid/chown` 等 capability、要把日志写到 `/dev/stdout`（软链到 `/proc/1/fd/*`）。写规则的标准工作流是：先跑、看 `dmesg | grep DENIED`、按缺的补——本 profile 就是这样迭代出来的；
- `/etc/nginx/conf.d/*.conf rw` 看似"放开了 /etc"，其实是 entrypoint 的 25-listen-on-ipv6 脚本要改写默认 vhost 的固有行为；范围只限这一个文件，/etc 下其他路径依旧默认拒绝。

## 步骤 2：加载 profile 并确认

```bash
# [master]
sudo apparmor_parser -r /etc/apparmor.d/docker-nginx-cks
sudo aa-status | grep -A20 'profiles are in enforce' | grep docker-nginx-cks
```

`aa-status` 的 `profiles are in enforce mode` 段落里应出现 `docker-nginx-cks`。
（`-r` = replace，重复执行安全；改完 profile 后必须重新 `-r` 加载，运行中的容器立即生效。）

先确认节点 AppArmor 已启用（Ubuntu 默认启用）：

```bash
# [master]
cat /sys/module/apparmor/parameters/enabled
# Y
```

## 步骤 3：创建 Pod 引用 profile

```yaml
# [master] nginx-apparmor.yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx-apparmor
  namespace: cks-lab03
  annotations:
    container.apparmor.security.beta.kubernetes.io/nginx: localhost/docker-nginx-cks
spec:
  containers:
  - name: nginx
    image: nginx:1.27
```

```bash
# [master]
kubectl create ns cks-lab03
kubectl apply -f nginx-apparmor.yaml
kubectl -n cks-lab03 get pod nginx-apparmor
```

工作机制：kubelet 看到注解 `localhost/<profile>` 后，在**运行该 Pod 的节点**上查找同名 profile；找不到则 Pod 起不来（`CreateContainerError`，报 `apparmor: profile not found` 之类错误）。因此多节点集群里要把 profile 分发到所有候选节点。

## 步骤 4：验证三件事

```bash
# [master]
# 1) 服务正常
kubectl -n cks-lab03 exec nginx-apparmor -c nginx -- \
  curl -s -o /dev/null -w "%{http_code}\n" localhost
# 200

# 2) 写 /tmp 被拒
kubectl -n cks-lab03 exec nginx-apparmor -c nginx -- touch /tmp/pwned
# touch: /tmp/pwned: Permission denied   (command terminated with exit code 1)

# 3) 读 shadow 被拒
kubectl -n cks-lab03 exec nginx-apparmor -c nginx -- cat /etc/shadow
# cat: can't open '/etc/shadow': Permission denied

# 节点侧审计记录
sudo dmesg | grep DENIED | grep docker-nginx-cks | tail -5
```

对比实验（加深理解）：同样的 Pod 不加 annotation，`touch /tmp/pwned` 会成功——容器内 root 的 DAC 权限对 `/tmp` 不设防，这就是 AppArmor 的增量价值。

## 调试技巧

profile 写得太紧导致 nginx 起不来时，两步定位：

```bash
# [master]
kubectl -n cks-lab03 describe pod nginx-apparmor | grep -A5 -i 'events\|error'
sudo dmesg | grep DENIED | tail -10        # 内核告诉你哪条路径被拒
```

按 DENIED 记录往 profile 里补 allow 规则，`apparmor_parser -r` 重载即可，不用删 Pod。也可以先把最后一行临时换成 complain 模式（`sudo aa-complain /etc/apparmor.d/docker-nginx-cks`，只记录不拦截）观察一轮再收紧。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| Pod `CreateContainerError`，提示 profile not found | 节点上没加载 profile 或名字对不上 | `aa-status` 核对 profile 名；重跑 `apparmor_parser -r` |
| annotation 改了不生效 | annotation 只在创建时评估 | 删掉 Pod 重建 |
| nginx 起不来，dmesg 一堆 DENIED | 白名单漏了路径（如 `/var/cache/nginx/**`） | 按 DENIED 补 allow，重载 profile |
| exec 里 Permission denied 但 dmesg 没有 DENIED | 可能是 DAC/readonly 挂载拦的，不是 AppArmor | `describe pod` 看挂载；AppArmor 拦截一定有审计日志 |
| check.sh 报 `/sys/kernel/security/apparmor/profiles` 读不到 | 不是 root 或 AppArmor 未启用 | 用 root/sudo 跑 check.sh；确认内核参数为 Y |

## 判分结果

```bash
# [master]
cd 07-cks/labs/03-apparmor-profile
chmod +x check.sh
sudo ./check.sh    # 读 /sys/kernel/security/apparmor/profiles 需要 root
```

预期输出：

```
PASS: namespace cks-lab03 存在
PASS: profile 文件 /etc/apparmor.d/docker-nginx-cks 存在
PASS: profile 显式 deny /etc/shadow
PASS: profile 允许写 /var/log/nginx/**
PASS: profile docker-nginx-cks 已加载为 enforce 模式
PASS: Pod nginx-apparmor 为 Running
PASS: annotation 引用 localhost/docker-nginx-cks
PASS: Pod 内 touch /tmp/pwned 被拒（Permission denied）
PASS: Pod 内 cat /etc/shadow 被拒（Permission denied）
PASS: Pod 内 nginx 正常响应 200

SCORE: 10/10
```

## 延伸阅读

- AppArmor 教程（含本 lab 的原型 profile）: https://kubernetes.io/zh-cn/docs/tutorials/security/apparmor/
- AppArmor 官方文档: https://gitlab.com/apparmor/apparmor/-/wikis/Documentation
