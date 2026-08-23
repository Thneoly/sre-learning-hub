# 06 · 性能分析方法论：USE、60 秒巡检与火焰图

> 模块：01-linux 深入 ｜ 建议时长：4 小时 ｜ 关联认证：PCA（node_* 指标判读）/ CKA-故障排查

## 学习目标

- 能用 USE 方法对 CPU/内存/存储 IO/网络逐资源列出检查点，避免"想到哪查到哪"
- 能执行 60 秒巡检清单，并对每个工具的输出给出正确判读（含 iowait 与 %util 的陷阱）
- 能用 perf record + FlameGraph 脚本生成一次火焰图并找到宽平顶热点
- 能说清 strace/lsof 的原理边界与适用时机，不再对生产进程乱挂 strace
- 能沿"CPU 高排查决策树"走完一次从指标到根因的完整定位

## 1. USE 方法：先搭框架再动手

USE（Utilization、Saturation、Errors）对**每种资源**问三个问题：用得多满？排队长不长？报错没有？这把排障从"背命令"变成"填表格"：

| 资源 | Utilization 利用率 | Saturation 饱和度 | Errors 错误 |
|---|---|---|---|
| CPU | `vmstat 1` 的 us+sy；`mpstat` | 运行队列 `r` > 核数；load/核 > 1 | —（通常无硬件级计数） |
| 内存 | `free -m` available | `vmstat` si/so；major fault | OOM 日志（journalctl -k -i oom） |
| 存储 IO | `iostat -xz` %util（仅 HDD 语义强） | aqu-sz 深队列、await 高 | dmesg 里 I/O error、smart 状态 |
| 网络 IO | `sar -n DEV` 带宽/接口速率 | 重传、丢包（`nstat`、softnet 第2列） | `ip -s link` 的 errors/dropped |

USE 的纪律：**逐资源走完 U/S/E 再下结论**，发现饱和立即深挖该资源的消费者。它不告诉你根因，但保证你不漏掉某个资源维度。

## 2. 60 秒巡检清单（Brendan Gregg）

```bash
# [任意节点] 工具准备（一次性）
sudo apt-get update && sudo apt-get install -y sysstat stress-ng linux-tools-common linux-tools-$(uname -r)
uptime
sudo dmesg -T | tail -20
vmstat 1 5
mpstat -P ALL 1 3
pidstat 1 3
iostat -xz 1 3
free -m
sar -n DEV 1 3
sar -n TCP,ETCP 1 3
```

十条命令覆盖 USE 的全部资源，60 秒内跑完。逐个讲判读：

### 2.1 uptime：负载与核数的比值

```text
# [任意节点] 输出示例
 21:35:02 up 12 days,  3:12,  2 users,  load average: 4.02, 2.10, 1.30
```

三个数是 1/5/15 分钟指数移动平均（含 D 状态，见第 4 章）。判读：`load1 / nproc` 超过 1 提示饱和；**只看 load1 会误判**——`1.30` 的 load15 配 `4.02` 的 load1 说明问题最近 1 分钟才开始；反过来 load15 高 load1 低说明正在恢复。旧值惯性大，新值敏感，两者一起读。

### 2.2 dmesg | tail：最近的内核层大事件

OOM kill、ext4 错误、NIC link down、CPU MCE、conntrack table full 全在这里。`-T` 给人类可读时间戳。这是清单里唯一"读文本"而非"读数"的一项，但信息密度最高——**性能问题背后常是一次硬件/内核异常**。

### 2.3 vmstat 1：一行看全 CPU 与 IO 骨架

```text
# [任意节点] 输出示例(每列一族)
procs ---------memory---- --swap- ----io---- -system-- ------cpu-----
 r  b   swpd   free   buff/cache   si   so    bi    bo   in   cs us sy id wa st
 2  0      0 210000    5600000      0    0     0    40 1200 2400 12  3 84  1  0
```

| 列族 | 字段 | 判读 |
|---|---|---|
| procs | `r`/`b` | r=运行队列长度（>核数=CPU 饱和）；b=阻塞在 IO 的 task 数（D 状态的瞬时计数） |
| memory | swpd/free/buff-cache | 呼应第 3 章：看 available 语义，free 小是常态 |
| swap | `si`/`so` | 持续非零=内存压力（si 更伤，见第 3 章 5.3） |
| io | `bi`/`bo` | 每秒读/写块量（KiB），与 iostat 互证 |
| system | `in`/`cs` | 中断/上下文切换；cs 骤增配合 sy 高=切换风暴 |
| cpu | us/sy/id/wa/st | 用户/内核/空闲/等IO/虚拟化窃取 |

`wa`（iowait）的经典误解：它是"CPU 空闲**且**有未完成 IO"的时间占比——**CPU 一忙起来 wa 反而下降**，所以 wa 低不代表 IO 没问题，要配 `b`、`bi/bo` 与 iostat 一起看。`st` 是 hypervisor 分给别的虚机的时间——你的 base 集群在 VMware 上，宿主机超卖时 st 上升，VM 内任何调优都无效，找宿主机管理员。

### 2.4 mpstat：把"平均"拆到每核

`mpstat -P ALL 1` 的价值在两处：单核 `%soft` 高=网络软中断集中在少数 CPU（第 5 章 RSS/RPS 问题）；单核 `%iowait`/`%usr` 高而整体平均不高=单线程瓶颈或中断亲和问题——`top` 里按 1 也能看，mpstat 更适合留档对比。

### 2.5 pidstat：从"系统"下钻到"进程"

```bash
# [任意节点]
pidstat 1 3                    # 每 CPU 排名
pidstat -d 1 3                 # 谁在打 IO(kB_rd/s kB_wr/s)
pidstat -r 1 3                 # 内存: RSS 与 majflt/s(持续非零=换页,第3章)
pidstat -w 1 3                 # 上下文开关: cswch/s(自愿,等资源) 与 nvcswch/s(非自愿,被抢占)
```

`%wait` 列是"可运行但没抢到 CPU 的时间占比"——CPU 饱和时它先于 %CPU 满而上升，是限流感知最早的信号。容器场景：节点上的 pidstat 以 host PID 视角直接看得到容器进程，K8s 层再用 `kubectl top pod` 对应到具体容器。

### 2.6 iostat -xz：第 2 章的浓缩

三画像复习：await 高+aqu-sz 小=设备慢；await 高+aqu-sz 大=排队饱和；SSD 上 %util 满但 await 低=并行设备误读。`iostat` 不看 NFS/网络存储，那要 `sar -n DEV` 补位。

### 2.7 free -m：只看 available

第 3 章已展开：free 少、buff/cache 大是健康状态；判定余量用 available；shared 大提示 tmpfs。

### 2.8 sar -n DEV 与 sar -n TCP,ETCP

```text
# [任意节点] sar -n DEV 1 关键列
IFACE  rxpck/s  txpck/s  rxkB/s  txkB/s  rxmcst/s  %ifutil
eth0     12000    14000    8500     9200         0      3.20
# pps 与 KB/s 分开看: 小包(如 DNS/心跳)pps 高带宽低; %ifutil 估算接口利用率

# sar -n TCP,ETCP 1 关键列
active/s passive/s iseg/s  oseg/s  retrans/s  atmptf/s  estres/s
     320       45  18000   19000       2.1         0         0
# active=主动打开(客户端视角连接), passive=被动打开(服务端视角)
# retrans/s 持续增长 = 丢包或拥塞, 与第5章 tcpdump/s -i 互证
```

`sar` 的另一个杀手锏是**历史回放**：sysstat 的 cron（`/etc/cron.d/sysstat`，Ubuntu 装完需取消 enable 开关）每 10 分钟采样落盘，`sar -r -f /var/log/sysstat/sa22` 能回看今天 22 号的内存曲线——凌晨三点的事故不用等复现。

## 3. perf 与火焰图

### 3.1 perf 三板斧

```bash
# [任意节点]
sudo perf stat -p $(pidof kubelet) -- sleep 5     # 计数器: IPC、cache miss、上下文切换
sudo perf top -e cycles                      # 实时热点(像 top 但按函数)
sudo perf record -F 99 -p <PID> -g -- sleep 30   # 99Hz 采样带调用栈 30 秒
sudo perf report --no-children               # 交互式读报告(按 -/+/展开)
```

`-F 99` 是经验值：采样频率够勾出热点又足够低开销（<1% CPU）；`-g` 记调用栈，火焰图必需。内核态函数符号正常可见（`kallsyms`）；用户态程序若没调试符号，函数显示为地址——这是"看不到函数名"的常见原因，不是 perf 坏了。

### 3.2 生成一张火焰图

```bash
# [任意节点] 取 FlameGraph 官方脚本(一次性)
mkdir -p ~/flame && cd ~/flame
curl -fsSL -o stackcollapse-perf.pl https://raw.githubusercontent.com/brendangregg/FlameGraph/master/stackcollapse-perf.pl
curl -fsSL -o flamegraph.pl          https://raw.githubusercontent.com/brendangregg/FlameGraph/master/flamegraph.pl
chmod +x *.pl

# 采样 -> 折叠 -> 成图
sudo perf record -F 99 -ag -- sleep 15          # -a 全 CPU, -g 调用栈
sudo perf script | ./stackcollapse-perf.pl | ./flamegraph.pl > cpu.svg
```

把 `cpu.svg` 拷回 Windows（浏览器打开）即可交互检索。读图三则：**宽度=CPU 时间占比**（不是调用层级深浅）；找"宽平顶"=单函数吃掉大量 CPU 的热点；多个相似塔尖=被不同调用路径触发的同一函数。若目标换成 `off-CPU`/内存，改采样事件即可，思路不变。

## 4. strace 与 lsof：何时用、何时别用

### 4.1 strace：系统调用显微镜（代价昂贵）

strace 基于 `ptrace`，**每次系统调用都要把目标进程停下来两次**（进/出内核各一次），多线程高系统调用的服务可被拖慢 10~100 倍。纪律：只用于低流量排障、一次性命令、或你能接受其变慢的进程；对生产大流量服务先想 perf（采样不拦截执行）。

```bash
# [任意节点] 正确姿势
strace -f /usr/bin/curl -s -o /dev/null https://10.96.0.1/version   # 从头跟踪(推荐: 起子进程)
strace -c -f /usr/bin/curl -s -o /dev/null https://10.96.0.1/version # 只看汇总表(最常用)
strace -p <PID> -f -e trace=%network,fd -s 128                     # 附加到已运行进程(慎用)
```

`-c` 汇总表直接给出"哪个 syscall 调用最多/最耗时"，诊断"应用慢在哪个调用"极快。典型命中场景：`ENONENT`（文件不存在）、`ECONNREFUSED`（连不上）、疯狂 `futex`（锁竞争）、`restart_syscall` 频繁（被信号打断）。`-e trace=%network` 只看网络族，`-s 128` 放大字符串参数。

### 4.2 lsof：fd 视角的现场

lsof 列出进程打开的文件描述符（Linux 的"一切皆文件"使它覆盖普通文件、socket、pipe、设备）：

```bash
# [任意节点]
sudo lsof -nP -iTCP:6443 -sTCP:LISTEN         # 谁在监听 6443 (-n 跳过DNS解析, -P 跳过端口名)
sudo lsof -p $(pidof containerd) | wc -l      # 某进程 fd 总数(泄漏排查)
sudo lsof +L1                                # 链接数为0却仍被打开的文件(被删大文件!)
```

`lsof +L1` 正是第 2 章"df 满 du 找不到"的解药：日志被 rm 后进程仍持有 fd，看到 `(deleted)` 标记即为元凶。处置优先滚动/重启该进程；救急可 `sudo truncate -s 0 /proc/<PID>/fd/<N>`，但要清楚这会让继续写该 fd 的输出错乱。fd 持续增长不回落=泄漏，配合 `ls /proc/<PID>/fd | wc -l` 定期采样留证。

## 5. "CPU 高"完整排查决策树

```text
# [任意节点] 入口: top 的 %Cpu(s) 行(或 vmstat 的 us/sy/wa/st)
                 +-- us 高(用户态) --------> pidstat 1 找进程
                 |      +-- 是业务进程 --> perf record -g -> 火焰图找宽平顶 -> 代码热点
                 |      +-- 是 runtime 进程 --> GC/即时编译(JVM: 加 GC 日志; go: pprof)
                 |
                 +-- sy 高(内核态) --------> pidstat -w 看 cswch/s nvcswch/s
                 |      +-- cs 飙升 --> 锁竞争(strace -c 见大量 futex)/线程过多
                 |      +-- mpstat %soft 单核高 --> 网络软中断: softnet_stat 第2/3列,
                 |      |        ethtool -S 丢包 -> 第5章收包路径(队列/RPS/backlog)
                 |      +-- 页错误多 --> /usr/bin/time -v 或 pidstat -r 的 majflt/s(内存)
                 |
                 +-- wa 高(iowait) -------> iostat -xz 1: await/aqu-sz/%util 三画像
                 |      +-- 设备饱和 --> pidstat -d 找打IO进程 -> lsof 看它在写什么
                 |      +-- 设备慢/远端存储 --> NFS? 云盘限流? sar -n DEV 看网络面
                 |
                 +-- st 高(steal) --------> hypervisor 超卖: 找宿主机(VMware 管理员)
                 |                          VM 内无解, 联系资源方
                 |
                 +-- load 高但 idle ------> ps 数 D 状态(第4章): 存储挂起/NFS 卡
                                            /proc/<PID>/stack 定位等待点
```

树的价值在于**先分支再取数**：us/sy/wa/st 把"CPU 高"这个模糊主诉切成四类完全不同的病。每一支的叶子都落在前面章节的某个工具上——这就是本模块六章拼成一张网的方式。

K8s 场景的最后一公里：节点维度收敛到容器后，用 `kubectl top pod --containers` 找到对应容器；若容器 CPU 使用率不高仍慢，回第 4 章查 cgroup 节流（`cpu.stat` 的 nr_throttled）。PCA 视角的常驻监控等价物：

```promql
# [Prometheus] 节点 CPU 使用率(排除 idle/iowait 的各模式也可单独看)
100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))

# [Prometheus] load 归一化(呼应第4章: 分母是核数, 且 load 含 D 状态)
node_load5 / count by (instance) (node_cpu_seconds_total{mode="idle"})
```

## 实战演练：60 秒巡检 + 三种人造负载

### 演练 A：基线采样

```bash
# [任意节点] 先存基线(事故时没有基线是最贵的代价)
mkdir -p ~/perf-baseline && cd ~/perf-baseline
{ uptime; free -m; vmstat 1 5; mpstat -P ALL 1 3; iostat -xz 1 3; sar -n DEV 1 3; } | tee baseline.txt
```

### 演练 B：CPU 负载（us 分支）

```bash
# [任意节点]
stress-ng --cpu 2 --timeout 60s &        # 两个 CPU 密集 worker
sleep 8 && vmstat 1 3 | tail -4          # 预期: us 上涨, r>=2
pidstat 1 2 | grep -E 'stress|UID' | head -5
mpstat -P ALL 1 2 | head -12
wait
```

### 演练 C：IO 负载（wa 分支）

```bash
# [任意节点]
stress-ng --io 2 --timeout 45s &         # sync/buffer 类 IO 压力
sleep 8 && vmstat 1 3 | tail -4          # 预期: b>=1~2, bi/bo 活动, wa 可能上升
iostat -xz 1 3 | grep -E 'Device|sd|vd' | head -8    # await/aqu-sz 变化
ps -eo stat,comm | awk '$1 ~ /^D/' | wc -l           # D 计数(注意 load 也会被它推高)
wait
```

观察点（也是自测考点）：演练 C 里 uptime 的 load 会涨，但 us/id 几乎不动——"load 高 CPU 闲"的复现。若 60 秒内 load 变化不明显，记住移动平均的滞后性，用 `vmstat` 的 `r`/`b` 看瞬时真值。

### 演练 D：一次完整的火焰图

```bash
# [任意节点]
stress-ng --cpu 1 --timeout 40s &
sudo perf record -F 99 -ag -- sleep 10
wait
cd ~/flame && sudo perf script | ./stackcollapse-perf.pl | ./flamegraph.pl > cpu-demo.svg
# 把 cpu-demo.svg 拷回 Windows 打开, 搜索(Ctrl-F)stress -> 应能看到 stress-ng 相关宽塔
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| iowait 低就排除 IO 问题 | CPU 一忙 wa 被挤掉 | 配 vmstat 的 b/bi/bo 与 iostat 判读 |
| SSD %util 100% 当饱和 | %util 不度量并行度 | 看 await 与带宽是否到瓶颈 |
| load 高就加 CPU | load 含 D 状态 | 先分 R/D：vmstat r/b + ps 数 D |
| 对生产大服务挂 strace | ptrace 逐调用拦截，慢 10~100 倍 | 改用 perf 采样；strace 只做短附加或一次性命令 |
| free 少当内存不足 | buff/cache 是可回收缓存 | 看 available |
| 只看 load1 判定突发 | 移动平均滞后 | 三个窗口同读，配 r/b 瞬时值 |
| perf 看不到函数名 | 缺调试符号 | 装 dbgsym 或接受地址；内核符号查 kallsyms |
| st 高在 VM 内调优 | hypervisor 层窃取 | 找宿主机资源方，VM 内无解 |
| 火焰图按"塔高低"找热点 | 高度=调用栈深度 | 宽度才是 CPU 占比，找宽平顶 |

## 自测

1. 为什么"iowait 下降"反而可能意味着系统更忙？这个指标的数学定义是什么？

<details><summary>答案</summary>

iowait = CPU 空闲(idle)且该 CPU 上有未完成磁盘 IO 的时间占比。它是 idle 的一个子集：当 CPU 变忙（us/sy 上升）时，即使 IO 依旧没完成，这部分等待时间会被归入 busy 而非 wa——所以 wa 从 20% 掉到 2% 可能只是 CPU 更忙"抢走了记账"，IO 压力一点没变。正确判读必须配合 vmstat 的 b/bi/bo 与 iostat 的 await/aqu-sz。
</details>

2. mpstat 显示整体 CPU 30% 但单核 100%，为什么 top（默认视图）看不出来？两种可能根因分别查什么？

<details><summary>答案</summary>

top 默认聚合所有核，单核饱和被平均稀释（按 1 键展开可破）。两种根因：单线程应用瓶颈（该进程 us 高、`taskset`/`perf` 确认线程只在单核跑）——优化并行度或接受；中断/软中断亲和问题（该核 %soft 或 %irq 高，`/proc/interrupts` 看队列是否都落在同核）——开多队列 RSS/RPS 或调 irqbalance 绑定。前者是应用问题，后者是第 5 章收包路径问题。
</details>

3. 什么情况下 perf 比 strace 更合适？给出判断依据，并说明两者看到的世界有何本质不同。

<details><summary>答案</summary>

perf 是采样型：周期性读程序计数器与调用栈，不拦截执行，开销 ~1% 量级，适合生产环境定位"CPU 时间花在哪个函数"；它看不到单次系统调用的参数与返回值。strace 是拦截型：经 ptrace 在每个系统调用边界停两次目标进程，能看到参数、errno、时序，但开销可达 10~100 倍，只适合低流量/一次性场景。判断依据：要"时间去了哪"用 perf，要"这次调用到底发生了什么"用 strace；高流量生产进程上先 perf 后（必要时、可承受时）strace。
</details>

4. st（steal）持续 20%，而你是这台 VM 的管理员，为什么任何来宾侧调优都无效？该如何正确推进？

<details><summary>答案</summary>

steal 时间是 hypervisor 把物理 CPU 分给其他虚机/宿主机事务的时段，来宾内核只是"记账方"——它根本没被调度上 CPU，来宾内的调度器、应用、内核参数都无从改善。正确推进：确认证据（vmstat/mpstat 的 st 持续高，且来宾 us+sy 并不饱和），向宿主机/云平台方申诉 CPU 超卖，申请资源预留（reservation/anti-affinity）或迁移到空闲宿主机。K8s 角度：这是"节点性能问题在节点之外"的典型，排障边界感本身就是能力。
</details>

5. 火焰图里同一个函数出现在多个不同塔尖，且没有一个塔特别宽，说明了什么？下一步怎么做？

<details><summary>答案</summary>

该函数的总 CPU 占用被多条调用路径分摊——单看每一处都不显眼，但求和可能可观；同时也说明没有"一招见效"的单点热点。下一步：用火焰图交互式搜索（Ctrl-F 输入函数名）把所有实例反色求和，确认总占比；若总和确实高，考虑在调用方收敛（缓存/合并公共路径）而非改函数本身；若总和也不高，则热点判断不成立，回到 60 秒清单重新分支（可能问题在 IO/锁/off-CPU，换 off-CPU 火焰图或 pidstat -w 视角）。
</details>

## 延伸阅读

- Brendan Gregg Linux 性能（60 秒清单出处）：<https://www.brendangregg.com/linuxperf.html>
- USE 方法原文：<https://www.brendangregg.com/usemethod.html>
- FlameGraph 官方仓库：<https://github.com/brendangregg/FlameGraph>
- perf 官方 wiki：<https://perf.wiki.kernel.org/>
- sysstat（sar/vmstat/iostat/pidstat）：<https://github.com/sysstat/sysstat>
- K8s 排查工具（kubectl top 与资源监控）：<https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-usage-monitoring/>
