# 01 · 容器核心概念：Namespace、Cgroups 与联合文件系统

> 模块：03-docker ｜ 建议时长：3 小时 ｜ 关联认证：CKA-架构基础 / CKS-系统加固 / —（无直接考题，但是一切的前提）

## 学习目标

- 能解释容器与虚拟机的本质区别（共享内核 vs 独立内核），并据此判断哪些 workload 不适合容器化
- 能操作 `lsns`、`nsenter`、`unshare` 查看和进入任意进程的 namespace
- 能排查"容器里看到的 PID / 主机名 / 文件系统为什么和宿主机不一样"这类问题
- 能解释 cgroups v1 与 v2 在挂载布局上的差异，并读出容器的 CPU/内存限制
- 能解释 overlayfs 如何用"只读层 + 可写层"实现秒级启动与镜像共享

## 1. 容器是什么：一个被内核"隔离"的普通进程

容器不是轻量级虚拟机。它是一个普通的 Linux 进程，只是启动时被内核附加了两组属性：

1. **namespace**：让进程"看不见"其他进程的网络栈、进程树、挂载点等资源——隔离"看到什么"
2. **cgroups**：限制进程能用多少 CPU、内存、IO——控制"用到多少"

这两样都是**内核功能**，Docker/containerd/runc 只是帮用户组装它们的工具。所以容器内运行的所有系统调用都直接打到宿主机内核——这叫**共享内核**，是理解容器安全边界的起点。

```
        虚拟机（VMware/KVM）                    容器（Docker）
┌─────────────────────────────┐      ┌──────────┬──────────┬──────────┐
│  App A   │  App B           │      │  App A   │  App B   │  App C  │
├──────────┴──────────┤        │      ├──────────┴──────────┴──────────┤
│  Guest 内核（独立） │        │      │  （无独立内核，直接 syscalls） │
├─────────────────────┤        │      ├────────────────────────────────┤
│  虚拟硬件（vCPU/网卡）│       │      │  Host 内核（namespace+cgroups） │
├─────────────────────┤        │      ├────────────────────────────────┤
│  Host 内核 + Hypervisor│     │      │  Host 硬件                      │
└─────────────────────┘        │      └────────────────────────────────┘
  启动：分钟级（要引导内核）           启动：毫秒级（只是 clone+exec）
  隔离：硬件级（逃逸极难）            隔离：内核策略级（逃逸面更大）
```

推论：Windows 镜像无法跑在 Linux 宿主机上（除非宿主机是 Windows 内核）；内核漏洞（如 Dirty Pipe）可以同时打穿宿主机上所有容器——这是 CKS 关注的重点。

## 2. 六大 Namespace 逐个拆

内核 clone 系列 flag 对应六种（加上较新的 cgroup namespace 是七种，日常说"六大"）：

| Namespace | clone flag | 隔离对象 | 容器里的直观感受 |
|---|---|---|---|
| UTS | `CLONE_NEWUTS` | hostname、domainname | `hostname` 只显示容器 ID |
| IPC | `CLONE_NEWIPC` | System V IPC、POSIX message queue | 看不到宿主机的 `ipcs` |
| NET | `CLONE_NEWNET` | 网络设备、IP、路由表、iptables、端口 | 独立的 eth0、/etc/resolv.conf |
| PID | `CLONE_NEWPID` | 进程号空间 | 自己是 PID 1 |
| MNT | `CLONE_NEWNS` | 挂载点视图 | 看到镜像的根文件系统 |
| USER | `CLONE_NEWUSER` | UID/GID 映射 | 容器内 root ≡ 宿主机普通用户 |
| CGROUP（第七个） | `CLONE_NEWCGROUP` | cgroup 根路径视图 | 容器内 /proc/self/cgroup 看到的是相对路径 |

> **为什么恰好是这六种？** 推导一遍胜过死记：进程要"相信自己独占一台机器"，得骗过它的全部感官——**我是谁**（UTS 主机名、USER 身份、PID 进程号）、**我有什么**（MNT 文件系统、NET 网络栈）、**我能和谁通信**（IPC）。六个维度恰好穷尽一个进程对"环境"的全部感知。
>
> 内核实际有 **8 种** namespace，另两个为何不入列：**cgroup ns**（4.6）只改 `/proc/self/cgroup` 的显示视图，**不做任何资源限制**——真正限资源的是 cgroups 本身（容器配方的另一半，与 namespace 是并列关系）；**time ns**（5.6）只能隔离单调时钟，改不了墙上时间（分布式系统要求钟面全局一致），runc 默认不用。这 6 个在 2013 年 Docker 诞生时刚好全部可用（user ns 于 3.8 成熟）——"六大"是容器起点的完整配方。
>
> **方向修正（易误解点）**：namespace 不是把进程"伪装给外界看"——宿主机 `ps` 里它们就是普通进程，毫无遮掩。它改变的是进程**向内看**的视野（`getpid`/`hostname`/`ip addr`/`ls /` 的答案被裁剪）。推论：**namespace 限制"看见什么" ≠ 权限边界**，容器逃逸攻的就是这个差别（CKS 核心话题）。

### 2.1 UTS：最简单的一个

隔离的只有 hostname 这两个字符串（实现在 `kernel/utsname.c`，结构体里就是 nodename 和 domainname）。`docker run --hostname web1` 就是在创建时设置新 UTS namespace 的 nodename。

### 2.2 IPC：System V 信号量/共享内存

隔离 System V IPC 对象和 POSIX 消息队列。注意：**它不隔离 Unix domain socket**——socket 属于 NET namespace（文件系统路径属于 MNT）。PostgreSQL、Redis 这类依赖 shared memory 的进程，容器化后 `ipcs -m` 是空的，shmax 等参数要靠 `--shm-size` 调整。

### 2.3 NET：网络出身的人最容易理解的一个

一个 NET namespace = 一套完整的网络栈：独立的网卡（lo、eth0）、IP 地址、路由表、iptables 规则、socket 端口空间、sysctl（`net.*` 大部分 namespaced）。容器里的 nginx 监听 80，和宿主机 80、另一个容器里的 nginx 80 互不冲突，因为端口表本来就是 per-namespace 的。第 3 章会画完整的包路径。

### 2.4 PID：为什么容器里 node 是 1 号进程

PID namespace 是**树形嵌套**的：子 namespace 里的进程在父 namespace 里照样有另一个 PID。容器内 `ps aux` 只能看到同 namespace 的进程，且入口进程固定为 PID 1。PID 1 在 Linux 里有特殊语义——要回收孤儿进程、处理信号，所以"容器里跑的前台进程不处理 SIGTERM"会导致 `docker stop` 等待 10 秒后被 SIGKILL，这是常见面试题。

### 2.5 MNT：挂载视图隔离

每个 MNT namespace 有自己的挂载表副本。容器启动时 runc 在新 MNT namespace 里 pivot_root 到镜像根目录，于是容器内 `/` 是 Ubuntu 而宿主机 `/` 是另一棵树。`/proc`、`/sys`、`/dev` 都是启动时挂进去的伪文件系统。Docker 的 `-v /host/path:/container/path` 本质是 bind mount——bind mount 不复制数据，只是把同一份 inode 挂到另一个路径。

### 2.6 USER：容器内 root ≠ 宿主机 root

USER namespace 建立 UID 映射：容器内的 UID 0 映射到宿主机的某个非特权 UID（如 100000，run as `--userns-remap=default` 时 Docker 自动生成映射区间）。效果：容器内进程名义上 root，能 chown/chroot，但发出的 syscall 到达内核时用的是宿主机 UID 100000 的权限——拿不到真实特权。代价是某些操作（挂载某些文件系统、`mknod`）在映射后不可用。没有 USER namespace 时，容器内 root 与宿主机 root 是同一个 UID 0，只是被 capability 裁剪了权限——CKS 中 `securityContext.runAsNonRoot` 就是防这个。

### 2.7 宿主机视角：一个进程，两套 PID

每个容器进程在内核里是同一个 `task_struct`，但记着两个编号：**全局 PID**（宿主机视角）+ 所在 pid namespace 的**局部 PID**。`getpid()` 返回哪个，取决于调用者自己站在哪个 namespace 里：

```
宿主机 ps -ef:                 容器内 ps:
PID 4821  nginx master   ⇔   PID 1   nginx master
PID 4832  nginx worker   ⇔   PID 7   nginx worker
PID 4833  nginx worker   ⇔   PID 8   nginx worker
        同一批进程，两套编号系统
```

共享与隔离的精确边界：内核/调度器/系统调用通道**完全共享**（容器进程与宿主机进程在同一张 CFS 桌子上抢 CPU）；隔离的只是"各看各的视野"（PID 树/网卡/挂载点/主机名）；cgroups 再发"粮票"限制用量。

运维价值——**宿主机是终极逃生口**：

- `docker top <容器>`：两套编号的映射表。容器内只看到 PID 7，宿主机用映射后的号直接 `strace -p`、`cat /proc/<宿主PID>/status`
- `nsenter -t <宿主PID> -n/-m/-p -- bash`：不经过 docker exec/kubectl 直接钻进容器排障——exec 通道全挂时的最后手段
- `kill -9 <宿主PID>`：从宿主机强杀容器进程，对容器内 PID 1 同样有效（SIGKILL 从父 namespace 打下来是内核强制的例外；SIGTERM 若无 handler 则无效——PID 1 的内核特判）
- 反面推论：共享内核 ⇒ 内核漏洞（Dirty Pipe 类）一次打穿宿主机上**所有**容器——"隔离是内核策略级"这句话的由来，也是 CKS 整个模块的存在理由

### 2.7 动手：用 lsns / nsenter / unshare 亲手摸 namespace

```bash
# [任意节点] （Ubuntu VM，需 root 或 sudo）
# 启一个长驻容器，拿到宿主机视角的 PID
docker run -d --name ns-demo --hostname inside-box alpine sleep 3000
PID=$(docker inspect -f '{{.State.Pid}}' ns-demo)
echo "容器入口进程在宿主机上的 PID = $PID"

# lsns 列出该进程的所有 namespace（TYPE 列）
lsns -p $PID -o NS,TYPE,PATH
# 预期：依次列出uts/ipc/net/pid/mnt/cgroup/cgroup:ns 之类的 TYPE

# 比较两个 namespace：宿主机 vs 容器
readlink /proc/$PID/ns/net    # 形如 net:[4026532281]
readlink /proc/1/ns/net       # init 进程的，编号一定不同
```

```bash
# [任意节点] nsenter：以宿主机 root 身份"进入"容器的 namespace 执行命令
# -t 目标PID；-n 进 NET ns；-u 进 UTS ns；-m 进 MNT ns；-p 进 PID ns
nsenter -t $PID -n ip addr      # 不进 MNT，用宿主机的 ip 命令看容器网络栈
nsenter -t $PID -u hostname     # 输出 inside-box
nsenter -t $PID -m -p -- ps aux # 进入容器视角：sleep 是 PID 1
```

```bash
# [任意节点] unshare：不用 Docker，手工造一个新 UTS namespace
unshare --uts --fork bash -c 'hostname demo-host && hostname'
hostname   # 回到宿主机 shell 后仍是原主机名：子进程的修改被隔离了
```

排障场景：容器里没有任何调试工具（distroless 镜像）时，`nsenter -t <PID> -m -n -p -- sh` 是唯一救急手段。

## 3. Cgroups：资源限制的账本

### 3.1 v1 与 v2 的布局差异

cgroups v1：每种资源一个独立层级（`/sys/fs/cgroup/cpu`、`/sys/fs/cgroup/memory`……），一个容器要在每个层级里各建一个目录，管理割裂。cgroups v2：**统一层级**（unified hierarchy），一个目录管所有资源控制器，`memory.current`、`cpu.stat`、`memory.events` 等接口语义也更统一。Ubuntu 22.04/24.04 默认 **cgroup v2**（`systemd.unified_cgroup_hierarchy=1` 已是默认）。

```bash
# [任意节点] 确认当前模式
mount | grep cgroup
# v2 只有一行：cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime)
# v1 会有多行：cgroup on /sys/fs/cgroup/cpu type cgroup (...)

cat /sys/fs/cgroup/cgroup.controllers
# v2 输出示例：cpuset cpu io memory hugetlb pids rdma misc
```

### 3.2 找到容器的 cgroup 并读限制

```bash
# [任意节点] 以 Docker 容器为例（cgroup v2 + systemd 驱动）
PID=$(docker inspect -f '{{.State.Pid}}' ns-demo)
cat /proc/$PID/cgroup
# v2 输形如：0::/system.slice/docker-<容器长ID>.scope

# 用 docker stats 验证（另一终端持续观察）
docker stats --no-stream ns-demo
# 直接读内核文件（路径接在上面 cgroup 路径下）
CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' ns-demo).scope
cat $CG/memory.max     # 字节数；docker run --memory 256m 时为 268435456
cat $CG/cpu.max        # "100000 100000" 表示 1 核（--cpus=1）
```

`cpu.max` 格式为 `<period 微秒> <quota 微秒>`：quota/period = 可用核数。`memory.max` 写入 `max` 表示不限。容器 OOMKill 时，v2 下 `memory.events` 里的 `oom_kill` 计数会 +1——Kubernetes 里 `kubectl describe pod` 看到的 `OOMKilled` 就源于此事件链（cgroup 事件 → kubelet → Pod status）。

### 3.3 Kubernetes 侧的对应关系

| K8s 字段 | cgroup 落点（v2） |
|---|---|
| `resources.limits.memory` | `memory.max` |
| `resources.requests.cpu` | `cpu.weight`（v1 是 cpu.shares） |
| `resources.limits.cpu` | `cpu.max` |
| Pod QoS Guaranteed | Pod 级 cgroup 的 memory.max == 所有容器之和 |

## 4. Overlayfs：镜像分层与可写层

### 4.1 为什么需要联合挂载

镜像由多个只读层堆叠，如果每起一个容器都复制整份镜像，磁盘和启动时间都不可接受。overlayfs 允许**多个目录叠加呈现为一个目录**，写操作通过 copy-up 落到最上层。

```
容器看到的 /（merged）
┌───────────────────────────────┐
│  upperdir（可写层，容器自己的改动）│ ← docker run 后的写入、修改、删除
├───────────────────────────────┤
│  lowerdir N（镜像最上层，只读）  │
│  lowerdir ...（逐层向下）        │ ← 每个 Dockerfile 指令一层
│  lowerdir 1（基础镜像层）        │
├───────────────────────────────┤
│  workdir（overlayfs 内部使用）  │
└───────────────────────────────┘
```

读文件：自上而下找，第一个命中的生效（上层"遮住"下层同名文件）。
改下层文件：触发 **copy-up**——把文件从 lowerdir 复制到 upperdir 再改，所以"改大文件"在容器里反而多占一份空间。
删文件：在 upperdir 放一个 **whiteout** 字符（设备号 0/0 的特殊节点）标记"此文件已删"，下层并不动。

### 4.2 实地查看一个容器的 overlay 挂载

```bash
# [任意节点]
docker inspect -f '{{json .GraphDriver.Data}}' ns-demo | python3 -m json.tool
# 输出 LowerDir / MergedDir / UpperDir /WorkDir 四个路径

# 直接看宿主机挂载表里的同一条记录
mount | grep overlay | head -3
# overlay on /var/lib/docker/overlay2/<id>/merged type overlay
#   (rw,relatime,lowerdir=...,upperdir=...,workdir=...)

# 在容器里造一个文件，然后到 UpperDir 里找到它
docker exec ns-demo sh -c 'echo hello > /tmp/evidence.txt'
UP=$(docker inspect -f '{{.GraphDriver.Data.UpperDir}}' ns-demo)
ls $UP/tmp/    # 能看到 evidence.txt —— 这就是可写层
```

### 4.3 写时复制带来的两个推论

1. **同一镜像起 N 个容器，磁盘只占 1 份只读层 + N 份薄薄的 upperdir**——这是"秒级扩容"的存储基础。
2. **容器可写层随容器删除而消失**——数据持久化必须用 volume/bind mount（第 4 章展开）。

## 5. OCI：把"容器"标准化

2015 年 Docker 捐出 runC 后形成的开放容器倡议，两份规范：

- **runtime-spec**：定义"一个容器的配置与生命周期状态"（creating/created/running/stopped），实现者有 runc、crun、kata。配置文件就是 `config.json`（namespace、cgroups、mount、process 全在里面）。
- **image-spec**：定义镜像格式——manifest、config、layers 三类 JSON/blob，以及文件系统层格式。任何符合规范的工具都能构建、存储、运行它。

```
Docker CLI ──gRPC──► containerd ──► containerd-shim ──► runc（OCI runtime）
   （不直接碰容器）      （守护进程）      （每容器一个）      （创建后即退出，
                                                            shim 接管 stdio/信号）
```

runc 按 runtime-spec 做的事：clone(带六个 NEW* flag) → 设置 cgroup → pivot_root → exec 入口进程。`docker run` 的完整链路是 CLI → dockerd → containerd → shim → runc。Kubernetes 集群里则是 kubelet → CRI 接口 → containerd（可换成 CRI-O），所以第 2 章的镜像知识对 K8s 完全通用。

## 实战演练：解剖一个容器

环境：装有 Docker 的 Ubuntu 22.04/24.04 VM，全程 root。

```bash
# [任意节点] 第 1 步：准备实验容器
docker rm -f ns-demo 2>/dev/null
docker run -d --name ns-demo --hostname inside-box \
  --memory 256m --cpus 1 alpine sleep 3000
```

```bash
# [任意节点] 第 2 步：验证六大 namespace 全部独立于宿主机
PID=$(docker inspect -f '{{.State.Pid}}' ns-demo)
echo "== 容器 namespace =="; lsns -p $PID -o NS,TYPE,NPROCS,PID,COMMAND
echo "== 宿主机 init 的 namespace =="; lsns -p 1 -o NS,TYPE | head -8
# 对比两边 TYPE 相同的行，NS 编号应全部不同
```

```bash
# [任意节点] 第 3 步：验证 PID namespace 的嵌套映射
nsenter -t $PID -m -p -- ps aux
# 容器视角：PID 1 是 sleep 3000
ps -p $PID -o pid,ppid,comm
# 宿主机视角：同一个进程有另一个 PID，父进程是 containerd-shim
```

```bash
# [任意节点] 第 4 步：验证 cgroup 限制真实存在
CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' ns-demo).scope
grep . $CG/memory.max $CG/cpu.max
# 预期：memory.max:268435456  cpu.max:100000 100000
docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}' ns-demo
```

```bash
# [任意节点] 第 5 步：制造 copy-up 并观察 UpperDir
UP=$(docker inspect -f '{{.GraphDriver.Data.UpperDir}}' ns-demo)
echo "upperdir before: $(find $UP -type f | wc -l) files"
docker exec ns-demo sh -c 'cp /etc/alpine-release /tmp/copied && echo data >> /etc/hostname.tmp'
echo "upperdir after:  $(find $UP -type f | wc -l) files"
find $UP -type f -exec ls -la {} \;
# 预期：新增了 /tmp/copied 与 /etc/hostname.tmp 两个文件
```

```bash
# [任意节点] 第 6 步：清理
docker rm -f ns-demo
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `docker stop` 要等 10 秒才停 | 容器 PID 1 不处理 SIGTERM | 入口进程前台化并处理信号（如 `nginx -g "daemon off;"`），或加 `--init` 让 tini 代收信号 |
| 容器内 `ps aux` 看不到任何进程 | 容器里没装 procps，或 /proc 挂载异常 | `nsenter` 从宿主机侧查看；镜像里带 `ps` 或用 `/proc` 直读 |
| 改了 `/proc/sys/net/...` 报 read-only | Docker 默认把 /proc/sys 挂为 ro | `--sysctl net.ipv4.ip_forward=1` 按参数放开，或 `--privileged`（危险，CKS 明确不推荐） |
| 共享内存不够（PG/Redis 报错） | /dev/shm 默认只有 64MB | `docker run --shm-size=1g`；K8s 用 emptyDir medium:Memory |
| `--user 1000` 后写 /data 报 Permission denied | bind mount 保留宿主机属主 | chown 宿主机目录或 `--user $(id -u):$(id -g)` 对齐 UID |
| 镜像明明在本地却重复占空间 | 每个容器独立 upperdir，误以为镜像复制 | `docker system df` 区分 Images/Containers/Volume 占比 |

## 自测

<details><summary>1. 如果两个容器的 NET namespace 编号相同（lsns 里 NS 相同），它们之间是什么关系？有什么实际用途？</summary>

它们共享同一套网络栈：同一组网卡、IP、路由表、端口空间，lo 也互通。用途：Kubernetes Pod 的本质——infra（pause）容器先创建 NET namespace，业务容器全部 `--network container:<pause>` 加入进来，所以 Pod 内多容器可以用 localhost 互访、共占端口。排障时若两个容器 NS 编号相同，也说明它们在同一 Pod 或用 `--network container:` 链接。
</details>

<details><summary>2. 容器内 PID 1 睡死了不响应信号，为什么 SIGKILL 依然能杀掉它？SIGTERM 却不行？</summary>

SIGKILL 由内核直接执行，不经过目标进程的信号处理器；SIGTERM 默认行为也是终止，但 PID 1 特殊：内核对 PID 1 忽略没有注册 handler 的**默认终止类信号**，防止误杀 init。所以 PID 1 没写 handler 时 SIGTERM 被丢弃，只能等 docker stop 超时升级为 SIGKILL。解法是让入口进程注册 SIGTERM handler 优雅退出，或用 `--init`。
</details>

<details><summary>3. 一个镜像层里的 /etc/passwd 是 5KB，容器启动后只 append 了一行，磁盘实际多占了多少？为什么？</summary>

大约多占 5KB 量级（受块大小取整影响），而不是一行的大小。因为 lowerdir 只读，对它任何文件的首次写触发 copy-up：整个文件先复制到 upperdir，再在副本上追加。这也是"容器里频繁改镜像内大文件"会放大磁盘占用的原因。
</details>

<details><summary>4. cgroup v1 和 v2 下，kubelet 需要的 cgroupDriver 配置有什么差别？配错会怎样？</summary>

两者都要 kubelet 的 `cgroupDriver` 与容器运行时一致。v1 时代常用 `cgroupfs`，systemd 主机推荐 `systemd` 驱动；v2 只支持统一层级，systemd 驱动下容器 cgroup 挂在 system.slice/kubepods.slice 下。驱动不一致（如 kubelet=systemd、containerd=cgroupfs）时，两边各自创建 cgroup，限制不生效或 Pod 无法启动（kubelet 报 "cgroup not found"）。kubeadm 默认安装时 containerd 与 kubelet 均为 systemd 驱动。
</details>

<details><summary>5. 容器以 root 运行且没启用 user namespace，攻击者拿到容器内 root 后离宿主机 root 还差什么？</summary>

差的是 capabilities 与命名空间边界：容器 root 默认只带一小撮 capabilities（CHOWN、NET_BIND_SERVICE、SETUID 等），缺少 SYS_ADMIN、SYS_MODULE 等；且被 DAC/MAC（如 AppArmor/SELinux）与 seccomp 过滤限制。但共享内核意味着内核漏洞或挂载 /dev、hostPath 等配置失误都可能补齐这最后一步，因此 CKS 要求 runAsNonRoot、drop ALL capabilities、只放行必需的。本质回答：容器安全边界 = namespace(可见性) + cgroups(用量) + capabilities/seccomp/MAC(特权)，三者共同裁剪 root。
</details>

## 延伸阅读

- Namespaces 手册：https://man7.org/linux/man-pages/man7/namespaces.7.html
- cgroups v2 规范：https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html
- Overlayfs 文档：https://docs.kernel.org/filesystems/overlayfs.html
- OCI runtime-spec：https://github.com/opencontainers/runtime-spec
- OCI image-spec：https://github.com/opencontainers/image-spec
- Docker 架构官方文档：https://docs.docker.com/get-started/docker-overview/
