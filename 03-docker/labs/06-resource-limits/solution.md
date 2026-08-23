# Lab 06 · 解答与讲解

> 前置：Ubuntu 22.04/24.04 VM（cgroup v2 默认开启），已装 Docker，至少 2 核 CPU 更容易观察对照差异。

## 第 1、2 步：起受限容器与对照组

```bash
# [Ubuntu VM]
docker run -d --name lab06-cpu \
  --cpus 0.5 --memory 128m \
  alpine sh -c 'while true; do :; done'

docker run -d --name lab06-free \
  alpine sh -c 'while true; do :; done'
```

参数与 cgroup v2 的对应关系（这是本 lab 的核心）：

| Docker 参数 | cgroup v2 文件 | 本例值 | 含义 |
|---|---|---|---|
| `--cpus 0.5` | `cpu.max` | `50000 100000` | 每 100ms 周期最多用 50ms CPU |
| `--memory 128m` | `memory.max` | `134217728` | 内存硬上限，超出触发 OOM |
| `--memory-swap`（未设） | `memory.swap.max` | 随 memory | 默认 swap 总量=memory，即不许额外换出 |

`--cpus 0.5` 是 `--cpu-quota=50000 --cpu-period=100000` 的语法糖；`NanoCpus=500000000` 是 daemon 内部以纳秒为单位的等价表示（0.5 CPU = 5e8 ns/s）。

## 第 3 步：docker stats 对比

```bash
# [Ubuntu VM]
docker stats --no-stream --format \
  "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}" lab06-cpu lab06-free
```

典型输出：

```
NAME         CPUPerc   MemUsage
lab06-cpu    50.02%    1.3MiB / 128MiB
lab06-free   99.87%    1.2MiB / 15.4GiB
```

`docker stats` 的数据源就是各容器 cgroup 的 `cpu.stat`/`memory.current`，CPU% 是"自上次采样以来的用量差值 / 配额"。受限容器死死贴在 50%（单核口径），对照组贴 100%。

## 第 4 步：进容器读 cgroup 文件

```bash
# [Ubuntu VM]
docker exec lab06-cpu cat /sys/fs/cgroup/cpu.max
docker exec lab06-cpu cat /sys/fs/cgroup/memory.max
```

预期输出：

```
50000 100000
134217728
```

为什么容器内能直接看到自己的 cgroup：cgroup v2 + 默认 `cgroupns=private`，容器内 `/sys/fs/cgroup` 挂载的就是**本容器自己的子树根**。宿主机视角等价路径：

```bash
# [Ubuntu VM]
CID=$(docker inspect -f '{{.Id}}' lab06-cpu)
sudo cat "/sys/fs/cgroup/system.slice/docker-${CID}.scope/cpu.max"
```

## 第 5 步：观察 nr_throttled 增长（限流实锤）

```bash
# [Ubuntu VM]
docker exec lab06-cpu cat /sys/fs/cgroup/cpu.stat
sleep 30
docker exec lab06-cpu cat /sys/fs/cgroup/cpu.stat
```

预期两次输出形如：

```
usage_usec 4031000
user_usec 3960000
system_usec 71000
nr_periods 82
nr_throttled 78        ← 30 秒后明显变大（每个 100ms 周期都在 50ms 处被掐断）
throttled_usec 3180000
```

throttle 机制图解：

```
每 100ms 一个周期（period）
 ├────────────────────────────────┤
 ████████░░░░░░░░░░░░░░░░░░░░░░░░
 0      50ms                    100ms
 用满 50ms 配额后，剩余 50ms 内该 cgroup 所有任务被置为不可调度
 （nr_throttled++，throttled_usec 累计），下个周期恢复
```

对照组 `lab06-free` 的 `cpu.max` 为 `max 100000`，`nr_throttled` 恒为 0：

```bash
# [Ubuntu VM]
docker exec lab06-free sh -c 'cat /sys/fs/cgroup/cpu.max; grep nr_throttled /sys/fs/cgroup/cpu.stat'
```

K8s 对照：`resources.limits.cpu: 500m` 最终就是容器 cgroup 里同样的 quota 配置；`kubectl describe pod` 里的 `--cpu-period/--cpu-quota` 参数、以及节点上 `/sys/fs/cgroup/.../cpu.stat` 的 nr_throttled，是诊断"CPU limit 导致服务长尾延迟"的第一现场。

## 第 6 步：daemon 侧确认

```bash
# [Ubuntu VM]
docker inspect lab06-cpu --format \
  'NanoCpus={{.HostConfig.NanoCpus}} Memory={{.HostConfig.Memory}} MemorySwap={{.HostConfig.MemorySwap}} PidsLimit={{.HostConfig.PidsLimit}}'
```

预期输出：

```
NanoCpus=500000000 Memory=134217728 MemorySwap=268435456 PidsLimit=0
```

`MemorySwap=268435456`（256MiB）说明默认 swap 上限 = memory + 128m（允许换出一份等量内存）。若要严格禁止换出，显式加 `--memory-swap 128m`。

## 第 7 步（选做）：内存 OOM 演示

```bash
# [Ubuntu VM]
docker run --name oom-demo -m 64m alpine dd if=/dev/zero of=/dev/shm/big bs=1M count=200 || true
docker inspect oom-demo --format 'ExitCode={{.State.ExitCode}} OOMKilled={{.State.OOMKilled}}'
docker ps -a --filter name=oom-demo --format '{{.Names}}: {{.Status}}'
docker rm oom-demo
```

预期输出：

```
ExitCode=137 OOMKilled=true
oom-demo: Exited (137) ...
```

200M 的写入撞上 64M 的 `memory.max`（/dev/shm 是 tmpfs，计入 cgroup 内存），内核 OOM killer 选中容器 PID 1（128+9=137 即 SIGKILL）。这正是 K8s 里 `Last state: Terminated, Reason: OOMKilled` 的来源——排查思路：limit 是否小于应用实际工作集。

> 为什么不用常见的 `polinux/stress`：该镜像只有 `CMD ["/usr/local/bin/stress"]`、没有 ENTRYPOINT，直接跟 `--vm 1 ...` 会报 `exec: "--vm": executable file not found`；写全 `polinux/stress stress --vm 1 --vm-bytes 128M --vm-hang 0` 能跑，但 stress 是**fork 出 worker 进程**干活的——被 OOM 杀的是 worker（日志 `worker got signal 9`），PID 1 只是以 1 退出，你看到的是 `ExitCode=1 OOMKilled=false`。要观察"PID 1 被杀"的完整形态（137 + OOMKilled），用单进程的 dd 方案最干净。

补充：观察 `memory.events`（oom/oom_kill 计数）：

```bash
# [Ubuntu VM]
docker exec lab06-cpu cat /sys/fs/cgroup/memory.events
```

## 判分脚本结果

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

预期输出：

```
PASS: 宿主机使用 cgroup v2
PASS: lab06-cpu 运行中
PASS: lab06-cpu NanoCpus 为 500000000（--cpus 0.5）
PASS: lab06-cpu Memory 为 134217728（128MiB）
PASS: lab06-cpu 容器内 cpu.max 为 50000 100000
PASS: lab06-cpu 容器内 memory.max 为 134217728
PASS: lab06-cpu 的 nr_throttled 大于 0（发生限流）
PASS: lab06-free 运行中且 NanoCpus 为 0（无限制）

SCORE: 8/8
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| stats 里 CPUPerc 超过限制值 | 短窗口采样与周期不对齐 | 看长周期平均；以 cpu.stat 为准 |
| `--memory` 设了但被忽略 | 旧内核 cgroup swap 记账未开（`swapaccount=0`） | Ubuntu 22.04+ 默认正常；`docker info` 看 WARNING |
| 容器被杀 ExitCode 137 但没 OOMKilled | 可能是 `docker stop` 超时强杀 | 看时间线与 `memory.events`，区分 OOM 与人工 kill |
| throttling 严重导致应用卡顿 | limit 太贴近实际用量 | 提高 limit；对延迟敏感服务建议绑核或用静态 CPU 管理器 |
| exec 看不到 cpu.stat | cgroup namespace 模式为 host（老版本/自配） | 用宿主机路径 `/sys/fs/cgroup/.../docker-<id>.scope/` |

## 清理（保留终态供复查，彻底清理用）

```bash
# [Ubuntu VM]
# docker rm -f lab06-cpu lab06-free
```

## 延伸阅读

- Docker 运行时资源约束：https://docs.docker.com/engine/containers/resource_constraints/
- cgroup v2 文档（kernel.org）：https://docs.kernel.org/admin-guide/cgroup-v2.html
