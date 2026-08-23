# 04 · 进程、CFS 调度与负载均值

> 模块：01-linux 深入 ｜ 建议时长：3 小时 ｜ 关联认证：CKA-集群架构（CPU limit 与调度）/ —（Linux 内功）

## 学习目标

- 能解释 fork/exec/写时复制与进程线程的真实关系（内核里只有 task）
- 能演示 nice 值对 CPU 分配的影响，并把 cgroup CPU 配额与 K8s 的 requests/limits 对应起来
- 能识别 R/S/D/Z 状态，解释 D 状态为什么 kill -9 杀不死、僵尸怎么清理
- 能说出 Linux 负载均值把什么算进去了，并据此判断"load 高≠CPU 忙"
- 能处理信号语义差异，包括容器里 PID 1 不响应 SIGTERM 的经典问题

## 1. 进程、线程与 fork/exec

### 1.1 内核视角：一切皆 task

应用层区分进程/线程，内核里只有 `task_struct`。所谓线程，是用 `clone()` 时带上了 `CLONE_VM | CLONE_FILES | CLONE_SIGHAND...` 标志的 task——它们共享地址空间与文件描述符表，仅各自持有栈与寄存器上下文。Linux 线程模型（NPTL）是 1:1 映射：每个线程就是一个可被独立调度的 task。

```text
# 进程 vs 线程（内核对象视角）
 传统"进程"                      "多线程进程"
 +-------------------+          +-------------------+
 | task_struct       |          | task_struct  (tid=1)|--+
 | mm(地址空间) 唯一  |          | task_struct  (tid=2)|--|--> 共享同一个 mm
 | files(fd表) 唯一   |          | task_struct  (tid=3)|--+    与 files 表
 +-------------------+          +-------------------+
 ps 里 1 行                        ps -eLf 里 3 行(LWP 列)
```

```bash
# [任意节点]
ps -eLf | head -5                 # LWP 列即线程 tid
ls /proc/$(pidof containerd)/task | wc -l    # 该进程线程数
ls /proc/$(pidof containerd)/task | head -3  # 每个 tid 一个目录
cat /proc/self/status | grep -E '^Threads|^Pid|^PPid'
```

pid 与 tid：对内核而言调度单位是 tid；`getpid()` 在线程里返回的是组长 pid。工具层面：`top` 默认按进程聚合（按 H 切到线程视图），`pidstat -t` 直接列线程。

### 1.2 fork 与写时复制

`fork()` 复制当前进程：内核并不真的复制整个地址空间，而是复制页表并把这些页标记为**只读共享**——父子谁写谁触发缺页，内核那时才复制那一页（Copy-On-Write）。这使 fork 出 64GB 内存的 JVM 只需要复制页表的代价。`fork()` 返回两次：父进程拿到子进程 PID，子进程拿到 0。

fork 之后通常是 `execve()`：丢弃整个地址空间换上新程序映像，但 **PID 不变、已打开的 fd 继承**（除非打了 close-on-exec 标志）。这个"fork+exec"组合就是 shell 起命令、containerd 起容器的路径。

### 1.3 孤儿与僵尸：容器时代的必修课

- 子进程先退出、父进程没 `wait()` 回收 → 子进程变成**僵尸（Z）**：内核必须保留它的退出状态等信息。僵尸不占内存 CPU，但占 PID 表项，海量僵尸会耗尽 PID。
- 父进程先死 → 子进程成孤儿，被**重新收养给 PID 1**，由 PID 1 负责回收。

推论到容器：容器里 PID 1 若不收割僵尸（不处理 SIGCHLD、不做 wait），僵尸会在容器里堆积。这就是 `tini`、`docker --init`、K8s `shareProcessNamespace` 存在的理由之一。原生会收割的镜像（大多数基础镜像的 ENTRYPOINT 用 bashexec 的场景除外）没有这个问题。

## 2. CFS：完全公平调度器

### 2.1 vruntime 与红黑树

CFS（Completely Fair Scheduler，2.6.23~6.5；6.6 起被 EEVDF 取代，思想同源：仍是按权重与虚拟运行时间排队，Ubuntu 24.04 的 6.8 内核已是 EEVDF）的核心想法：不按时间片轮转，而是追踪每个 task 的**虚拟运行时间 vruntime**，总是调度 vruntime 最小者。

```text
# 每个 CPU 一个运行队列（红黑树按 vruntime 排序, 左边最"亏欠"）
        CFS runqueue (CPU 0)
            [最左节点 = vruntime 最小 = 下一个被调度]
             |
   +---------+-----------------------------+
   |vruntime:| 100 | 205 | 310 | 412 | ... |
   |nice:     |  0  |  0  |  5  |  5  |
   +--------------------------------------+
   vruntime 增速 = 实际运行时间 × (NICE_0_LOAD / 该task权重)
   nice 越高(优先级越低) -> 权重越小 -> vruntime 涨得越快 -> 更快"轮完"被别人超车
```

权重表（kernel `sched_prio_to_weight`）：nice 0 = 1024，**相邻 nice 差约 1.25 倍**。所以 nice 0 与 nice 5 同跑一核，CPU 之比约 1.25^5 ≈ 3:1；nice 差 19（最高 0 最低 19）约 68:1。

```bash
# [任意节点] 动手验证：两个死循环绑同一核，一个降 nice
stress-ng --version >/dev/null 2>&1 || sudo apt-get install -y stress-ng
taskset -c 0 stress-ng --cpu 1 --timeout 60s >/dev/null 2>&1 &
P1=$!
taskset -c 0 nice -n 19 stress-ng --cpu 1 --timeout 60s >/dev/null 2>&1 &
P2=$!
sleep 10 && top -b -n1 -p $(pidof stress-ng | tr ' ' ',') | tail -3
# 观察 %CPU: 高优先级(nice 0)约 98%~99%, nice 19 约 1%~2%
kill $P1 $P2 2>/dev/null; true
```

调整既有进程优先级用 `renice`（普通用户只能调低优先级即增大 nice，root 可任意）：

```bash
# [任意节点]
sudo renice -n 5 -p <PID>
ps -o pid,ni,comm -p <PID>
```

### 2.2 cgroup CPU 配额：K8s limit 的真身

CFS 除了公平还有**带宽控制**（CFS bandwidth）：给一组进程规定"每周期最多跑多少"。cgroup v2 里是 `cpu.max`：

```text
# [任意节点] /sys/fs/cgroup/<path>/cpu.max 语法
cpu.max = "<quota(微秒)> <period(微秒)>"
  50000 100000   ->  每 100ms 周期最多用 50ms CPU = 0.5 核
  20000 100000   ->  0.2 核 (对应 K8s limits.cpu: 200m)
  max 100000     ->  不限
```

配额用尽的进程在周期剩余时间内被** throttle（冻结）**，下个周期恢复。这是 K8s CPU limit 的底层机制，也解释了经典怪象：**容器 CPU 使用率不高却莫名变慢**——不是没有 CPU 可用，是 50ms 的粮票在周期前段就花光了，剩下的时间只能等。

```bash
# [任意节点] 观察 kubelet 容器 cgroup 的节流统计（cgroup v2）
CG=/sys/fs/cgroup/kubepods.slice; ls $CG >/dev/null 2>&1 && cat $CG/cpu.stat
# 关注: nr_throttled(发生节流次数) throttled_usec(被冻结总时长)
# 任何一个持续增长的 nr_throttled 都值得核对该组内 Pod 的 limits.cpu 是否过紧
```

| K8s 概念 | 对应机制 | 效果 |
|---|---|---|
| `requests.cpu: 500m` | cgroup `cpu.weight`（v1 为 cpu.shares） | 竞争时的最小保障，不设上限 |
| `limits.cpu: 500m` | cgroup `cpu.max`（quota 50ms/period 100ms） | 硬顶，超了 throttle |
| `requests=limits`（Guaranteed） | 权重与配额一致 | 可预期，无节流意外 |

## 3. 进程状态：R/S/D/Z

`ps` 的 STAT 列与 `/proc/<PID>/stat` 的 state 字段：

| 状态 | 名字 | 含义 | 能否被信号打断 |
|---|---|---|---|
| `R` | Running/Runnable | 正在跑或在运行队列里等 CPU | —（无需打断） |
| `S` | Interruptible sleep | 可中断睡眠：等事件（IO 完成、锁、数据到达） | 能，信号立刻投递 |
| `D` | Uninterruptible sleep | 不可中断睡眠：通常在等底层 IO/存储 | **不能，SIGKILL 也不行** |
| `Z` | Zombie | 已退出，等父进程 wait 回收 | 不能（已死，只差收尸） |
| `T`/`t` | Stopped/traced | 被 SIGSTOP 或调试器挂起 | 能（SIGCONT 恢复） |

### 3.1 D 状态深挖

为什么设计成"不可中断"？内核路径里有些等待不允许被打断后重入（比如持有自旋锁、正在提交关键 IO）。代价是：**D 状态进程对 SIGKILL 免疫**——信号记下了，但要等它从内核返回用户态才处理，而它卡在内核里回不来。

```bash
# [任意节点]
ps -eo pid,stat,wchan:25,comm | awk '$2 ~ /^D/'          # 谁在 D, 卡在哪个内核函数
sudo cat /proc/<D状态PID>/stack 2>/dev/null | head       # 内核栈(需 root)
```

判读：D 集中出现且 `wchan`/栈指向存储路径（`nfs_`、`io_schedule`、`fuse` 等）→ 查存储/NFS 服务端；个别进程偶发 D 属正常（每次同步 IO 都会短暂经过）。**长时间不退的 D 只能靠解决底层 IO 或重启**——这也是"kill -9 杀不死"时该看的第一个地方。

### 3.2 僵尸的正确清理

```bash
# [任意节点] 制造一只僵尸看看
cat > /tmp/zombie-demo.sh <<'EOF'
#!/usr/bin/env bash
bash -c 'exit 7' &        # 子进程立刻退出
sleep 300                 # 父进程(bash)不 wait, 子进程变僵尸
EOF
chmod +x /tmp/zombie-demo.sh && /tmp/zombie-demo.sh &
sleep 1
ps -eo pid,ppid,stat,comm | awk '$3 ~ /Z/'
```

给僵尸本身发任何信号都无效（它没有可执行的上下文）。正解是**让父进程去 wait，或杀掉父进程**让它被 PID 1 收养并收割：

```bash
# [任意节点]
pkill -f zombie-demo.sh
sleep 1; ps -eo pid,stat,comm | awk '$2 ~ /Z/'    # 僵尸消失(systemd 收割了)
rm -f /tmp/zombie-demo.sh
```

## 4. 信号

| 信号 | 编号 | 默认行为 | 常见用途 |
|---|---|---|---|
| SIGHUP | 1 | 终止 | 守护进程重读配置（`nginx -s reload`、kill -HUP） |
| SIGINT | 2 | 终止 | Ctrl-C |
| SIGTERM | 15 | 终止 | **优雅停止的正规信号**（K8s 停 Pod 发的就是它） |
| SIGKILL | 9 | 终止(不可捕获) | 强杀；对 D 状态无效 |
| SIGSTOP/CONT | 19/18 | 暂停/恢复(不可捕获) | 冻结进程查现场 |
| SIGCHLD | 17 | 忽略 | 子进程退出通知（收割僵尸靠它） |

三条纪律：SIGTERM 先行给应用善后机会（flush、断连），宽限期后再 SIGKILL——K8s 的 `terminationGracePeriodSeconds` 就是这个节奏（默认 30s）；SIGKILL 与 SIGSTOP 无法被捕获或忽略；**PID 1 是特例**：内核不会对 PID 1 施加"未注册处理器之信号的默认致命行为"，换句话说容器主进程如果不显式处理 SIGTERM，`docker stop`/Pod 删除时它会安然无恙直到宽限期被 SIGKILL 硬杀。这就是"优雅退出"要从镜像入口脚本做起的原因（trap 'cleanup' TERM）。

```bash
# [任意节点] 观察进程怎么处理信号
nginx -v 2>/dev/null || sudo apt-get install -y nginx
ps -eo pid,ppid,comm | grep -w nginx            # master + workers
sudo kill -HUP $(cat /run/nginx.pid 2>/dev/null || pgrep -o nginx)
journalctl -u nginx --since "-1 min" --no-pager | tail -5    # reload 而非重启
```

## 5. 负载均值：到底在算什么

`uptime` 的三个数字是 1/5/15 分钟的**指数移动平均**，Linux 的公式把两类 task 计入：

```text
load = 处于 R(运行/可运行) 的 task 数 + 处于 D(不可中断睡眠) 的 task 数
```

包含 D 是 Linux 的"特色"（Unix 传统只算 CPU 就绪队列），本意是让磁盘瓶颈也反映在 load 上。两个后果必须内化：

1. **load 高 ≠ CPU 忙**：NFS 服务端挂了、底层存储抖动，一排进程进 D，load 能冲到几十而 CPU 几乎 idle。
2. **load 是"个数"不是"百分比"**：与 CPU 核数比才有意义，4 核机器 load 4 意味着刚好满载；单线程死循环在 64 核机器上只贡献 1.0。

```bash
# [任意节点]
uptime                                   # 三个窗口的 load
cat /proc/loadavg                        # 前 3 个同上 + 运行/总task数 + 最近PID
nproc                                    # 核数(记得 load 要除以它)
vmstat 1 3                               # r 列 = 此刻运行队列长度(瞬时值, 与 load 互为印证)
ps -eo stat,comm | grep -c '^D' || true  # 现在有几个 D
```

判别口诀：load 高 + `r` 大 + CPU us 高 → 真 CPU 饱和；load 高 + CPU idle + D 多 → IO/存储卡（去查 iostat/NFS）；PCA 同源提醒：`node_load1` 就是 `/proc/loadavg` 第一列，PromQL 里习惯除以核数做归一：

```promql
# [任意节点 Prometheus/Thanos 上执行] load 与核数之比
node_load1 / count by (instance) (node_cpu_seconds_total{mode="idle"})
```

## 实战演练：在练习集群上读一次调度现场

```bash
# [master]
kubectl -n kube-system get pods -o wide | head -5
PID=$(pidof kubelet); ps -o pid,ni,stat,pcpu,time,comm -p $PID
ps -eLf | awk -v p="$PID" '$2==p' | wc -l          # kubelet 线程数(填入上面 PID)
```

制造可对比的负载并观察三个视角（vmstat 的 r、uptime 的 load、top 的单核）：

```bash
# [master]
uptime; vmstat 1 5 &                        # 后台先看基线: r 通常 0~2
stress-ng --cpu $(nproc) --timeout 45s >/dev/null 2>&1 &
sleep 10; uptime; vmstat 1 3
# 预期: load1 开始爬升, r 接近核数, us 打满; 45 秒后 stress 退出, load 缓慢指数回落
# 注意 load 的回落远慢于负载消失——移动平均的滞后性, 排障时别被"旧 load"误导
wait
```

容器节流观察（若集群有跑着的工作负载）：

```bash
# [任意节点]
find /sys/fs/cgroup -name cpu.stat -path '*kubepods*' 2>/dev/null | head -3 | xargs -I{} sh -c 'echo "== {}"; cat {}'
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| kill -9 杀不死进程 | D 状态等内核 IO | 查 /proc/PID/stack 定位存储；解决 IO 或重启 |
| load 很高但 CPU idle | load 含 D 状态 task | `ps` 数 D，查 iostat/NFS |
| 容器内 CPU 使用率低但响应慢 | cgroup CPU 配额被 throttle | 看 cpu.stat 的 nr_throttled，调高 limits |
| Pod 删除总要等 30s 才真正停 | PID 1 不处理 SIGTERM | 镜像入口 trap TERM 或用 init 容器方案 |
| 容器里僵尸越积越多 | PID 1 不收割 | tini/dumb-init、docker --init、shareProcessNamespace |
| top 里进程看不全线程 | top 默认聚合进程 | 按 H 键或 `top -H`、`pidstat -t` |
| renice 后没变化 | 调高优先级需 root | `sudo renice -n -5 -p PID` |
| load 显示 100+ 以为 CPU 爆炸 | 存储故障致 D 堆积 | 先 `ps` 分状态再下结论 |

## 自测

1. fork 一个占 8GB RSS 的进程为什么能瞬间完成？父子此后各写 100MB 会发生什么？

<details><summary>答案</summary>

fork 只复制页表并把共享页标记只读，不复制数据（Copy-On-Write），代价与地址空间大小线性但常数极小。之后父子各写 100MB 时，各自触发写保护缺页，内核为被写的页分配新物理页并复制内容——物理内存才开始真正多占（约各 100MB，加上页表）。这也是 JVM 这类大堆进程避免运行期频繁 fork（改用 posix_spawn/线程池）的原因：页表复制本身在大堆时也不便宜。
</details>

2. nice 相差 5 的两个 CPU 密集进程绑同一核，CPU 大致怎么分？如果把低优先级那个的 nice 从 19 改成 0 会怎样？

<details><summary>答案</summary>

相邻 nice 权重比约 1.25，差 5 约 1.25^5 ≈ 3，所以约 75% 对 25%。从 19 改成 0 后权重从约 15 升到 1024（约 68 倍），两进程变成 1:1，原来的高优先级进程立刻损失约一半 CPU——renice 会即时改变 vruntime 增速，内核通过在新进程入队时赋予接近队列最小 vruntime 的初值来避免它饿死别人，但稳态占比立刻按新权重重分配。这提醒我们：优先级调整是全局零和游戏。
</details>

3. 为什么 D 状态对 SIGKILL 免疫？这个设计换来了什么？

<details><summary>答案</summary>

信号在进程返回用户态的边界上处理；D 状态的进程停在内核等待点（如提交给存储的 IO）上，永远没到那个边界，SIGKILL 只能登记待办。设计上这是把"内核路径不可重入/不可中途放弃"的正确性放在了"可被立刻杀死"的便利性之前——若允许在持锁或事务中途被打断，轻则数据不一致，重则死锁整个内核。运维含义：D 堆积=底层子系统问题，杀进程无济于事，必须治存储或重启。
</details>

4. 64 核机器上 load average 为 8，CPU 使用率 12%，判断是否有性能问题？

<details><summary>答案</summary>

不能只看这两个数。load 8 / 64 核 = 12.5% 的"就绪+不可中断"水平，若全部来自 R（8 个满跑的线程对应 12% CPU），说明负载轻；若 CPU 只有 12% 而 load 仍 8，则更可能大部分来自 D——存在 IO/存储等待，应查 iostat 的 await/aqu-sz、`ps` 的 D 计数与具体进程的 wchan。这正是"负载均值不含 D 才可怕/含 D 才需要分辨"的实务点：load 与 CPU 利用率的差值本身就是线索。
</details>

5. K8s 里 limits.cpu=500m 的 Pod，为什么 CPU 使用率明明只有 40% 还会卡顿？

<details><summary>答案</summary>

500m 的实现是每 100ms 周期 50ms 配额（cpu.max）。若应用是突发型（比如一个请求触发 30ms 的密集计算），它可能在周期开始就耗尽 50ms 配额，随后被 throttle 到下个周期——周期内看平均使用率不高（40%），但请求经历了最多 50ms 的强制等待。判据是 cpu.stat 的 nr_throttled 持续增长。解法：提高 limits、改用更小的周期粒度（发行版/运行时支持时）、或优化突发本身的 CPU 消耗。
</details>

## 延伸阅读

- CFS 设计文档：<https://docs.kernel.org/scheduler/sched-design-CFS.html>
- 调度器文档索引（含 EEVDF）：<https://docs.kernel.org/scheduler/index.html>
- cgroup v2 CPU 控制器：<https://docs.kernel.org/admin-guide/cgroup-v2.html#cpu>
- proc(5) 手册（/proc/PID/stat 状态字段）：<https://man7.org/linux/man-pages/man5/proc.5.html>
- signal(7) 手册：<https://man7.org/linux/man-pages/man7/signal.7.html>
