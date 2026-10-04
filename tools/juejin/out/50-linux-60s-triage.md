---
title_juejin: 别上来就 strace：60 秒十条命令看清一台病机
title_zhihu: 上手就 strace 是在错误的层捞针——60 秒十条命令的分诊逻辑
description: uptime负载三元、dmesg揪OOM、vmstat看r与b、mpstat单核打满、pidstat找进程、iostat三画像、free认available、top稀释单核，USE收口附分流图。
category_id: "6809637769959178254"
tags: "后端,程序员"
column_id: "7686346277555716146"
---

# 别上来就 strace：60 秒十条命令看清一台病机

机器一慢，很多人的第一反应是挂个 strace 看它在干嘛。这一挂，大概率是把病人按上手术台才开始问诊——连病在哪个系统都还不知道。

代价不只是慢。strace 基于 ptrace，目标进程每次系统调用都要被停下来两次（进、出内核各一次），高系统调用的服务能被拖慢 10~100 倍。更糟的是层错了：你还不知道问题在 CPU、内存、IO 还是网络，就一头扎进了某个进程的调用细节，捞半天针，针根本不在这层。

正确顺序是先用 60 秒拿全貌，再决定往哪层钻。这套清单出自 Brendan Gregg，下面逐条讲判读：看哪个列，什么数值算异常。

## 一、十条命令，先整体跑一遍

工具一次性装齐（Ubuntu）：

```bash
sudo apt-get update && sudo apt-get install -y sysstat stress-ng linux-tools-common linux-tools-$(uname -r)
```

清单本体，60 秒内跑完：

```bash
uptime
sudo dmesg -T | tail -20
vmstat 1 5
mpstat -P ALL 1 3
pidstat 1 3
iostat -xz 1 3
free -m
sar -n DEV 1 3
ss -s
top
```

说明一句：连接面我按习惯把原版的 sar -n TCP,ETCP 换成 ss -s 拿快照，retrans 的判读放第八节；top 本来就是原版第十条，值得单讲——它有一个均值稀释的坑。

60 秒买的是方向感：**先知道病在哪个系统，再决定开哪种刀。**

## 二、uptime：三个数字要一起读

```text
# 输出示例
 21:35:02 up 12 days,  3:12,  2 users,  load average: 4.02, 2.10, 1.30
```

三个数是 1/5/15 分钟的指数移动平均，而且不只数正在运行的进程——D 状态（不可中断等 IO）的任务也计入。判读看比值：load1 除以核数（nproc）超过 1，提示饱和。

但只看 load1 会误判。上面这组，load15 只有 1.30、load1 冲到 4.02——问题最近 1 分钟才开始；反过来 load15 高、load1 低，说明正在恢复。旧值惯性大，新值敏感。

**只看 load1 不看 load15，是开错药的捷径。**

## 三、dmesg -T：唯一读文本的一项，信息密度最高

```bash
sudo dmesg -T | tail -20
```

OOM kill、ext4 错误、网卡 link down、CPU MCE、conntrack table full——硬件与内核层的大事件全在这里留痕，-T 把时间戳转成人类可读。

我建议它在清单里排第二：**性能问题背后常站着一次硬件或内核异常**，先排掉这层，后面的数字才有意义。dmesg 里有 I/O error 或 MCE，先处理硬件，别急着调参。OOM 的完整判读链（容器里 137 与 OOMKilled 的分野），我另一篇《一启动就 Exited(137)》拆过，可对照。

## 四、vmstat 1：一行看全 CPU 与 IO 骨架

```text
# 输出示例(每列一族)
 r  b   swpd   free   buff/cache   si   so    bi    bo   in   cs us sy id wa st
 2  0      0 210000    5600000      0    0     0    40 1200 2400 12  3 84  1  0
```

最值钱的是头两列：r 是运行队列长度，**r 超过核数就是 CPU 饱和**；b 是阻塞在 IO 上的任务数（D 状态的瞬时计数），b 持续非零说明 IO 拖后腿——这时 load 也高，但 CPU 其实闲着。

其余各族快速扫：si/so 持续非零是内存压力（si 更伤）；cs 骤增配 sy 高是上下文切换风暴；st 是 hypervisor 把 CPU 分给了别的虚机——st 持续高，VM 内任何调优都无效，直接找宿主机管理员。

wa 有个经典误解：它定义为「CPU 空闲且有未完成 IO」的时间占比，是 idle 的子集。**CPU 一忙起来，wa 反而被挤低**——wa 低不代表 IO 没问题，要配 b 与 bi/bo 一起看。

vmstat 一行顶十行：r 和 b 就是 CPU 病与 IO 病的分岔口。

## 五、mpstat 与 top：整体均值掩盖单核打满

mpstat -P ALL 1 把「平均」拆到每核：

```bash
mpstat -P ALL 1 3
# 重点看: 各 CPU 行的 %usr %iowait %soft 是否有单核异常
```

两个异常形态：某单核 %soft 高——网络软中断集中在少数 CPU，是收包路径问题；某单核 %usr 或 %iowait 顶满而整体均值不高——单线程瓶颈或中断亲和问题。32 核机器上一个核打满，均值只涨 3%，看整体你什么都不会发现。

这正是 top 默认视图的坑：**top 把所有核聚合成一行，单核饱和被平均稀释**。破法很简单，top 里按 1 键展开每核视图。mpstat 相对 top 的优势是输出规整，适合留档做前后对比。

## 六、pidstat：从系统下钻到进程

前面所有命令都在回答「哪类资源」，pidstat 开始回答「谁」：

```bash
pidstat 1 3      # 每 CPU 排名
pidstat -d 1 3   # 谁在打 IO(kB_rd/s kB_wr/s)
pidstat -r 1 3   # RSS 与 majflt/s(持续非零=在换页)
pidstat -w 1 3   # cswch/s(自愿,等资源) nvcswch/s(非自愿,被抢占)
```

重点盯 %wait 列：它是「可运行但没抢到 CPU」的时间占比，**CPU 饱和时它先于 %CPU 满而上升**——限流感知最早的信号。容器场景，节点上的 pidstat 以 host PID 视角直接看得见容器进程，K8s 层再用 kubectl top pod 对应到具体容器。

## 七、iostat 与 free：IO 看三画像，内存只认 available

iostat -xz 1 的判读就三句话：await 高且 aqu-sz 小，设备本身慢；await 高且 aqu-sz 大，排队饱和；SSD 上 %util 顶满但 await 不高，是并行设备的误读——%util 不度量并行度，只在 HDD 上语义强。另外 iostat 看不了 NFS/网络存储，那要 sar -n DEV 补位。

free -m 只看 available 一列。free 少、buff/cache 大是健康状态，那本来就是可回收的缓存。**拿 free 列喊内存不足，是 Linux 判读里最老的冤案**。顺带：shared 大，提示 tmpfs 在吃内存。

## 八、sar -n DEV 与 ss -s：网络面与连接面

sar -n DEV 1 3 看网卡：

```text
# 关键列
IFACE  rxpck/s  txpck/s  rxkB/s  txkB/s  rxmcst/s  %ifutil
eth0     12000    14000    8500     9200         0      3.20
```

pps 和 KB/s 要分开看：小包流量（DNS、心跳）pps 高而带宽低；%ifutil 估算接口利用率。原版清单的 sar -n TCP,ETCP 也值得记一条：retrans/s 持续增长，就是丢包或拥塞的证据。

sar 真正的杀手锏是历史回放：sysstat 的 cron 每 10 分钟采样落盘（Ubuntu 装完默认不采集，要把 /etc/default/sysstat 的 ENABLED 改成 true），凌晨三点的事故不用等复现：

```bash
sar -r -f /var/log/sysstat/sa22
# 回看 22 号全天的内存曲线
```

ss -s 一行拿到连接面总量快照：TCP 总数、estab、timewait 等各状态计数。【从业者判断】estab 突增配合应用报错，先查连接泄漏或重试风暴；timewait 大本身不是事——我讲 tcp_tw_reuse 的那篇拆过，同一个下游把源端口打满才算真耗尽。

## 九、USE 方法：十条命令的归位表

十条命令散着记会忘。USE 方法（Utilization、Saturation、Errors）对每种资源问三个问题：用得多满？排队长不长？报错没有？归位如下：

| 资源 | 利用率 U | 饱和度 S | 错误 E |
| --- | --- | --- | --- |
| CPU | vmstat us+sy、mpstat | r>核数、load/核>1 | 通常无硬件级计数 |
| 内存 | free 的 available | si/so、major fault | OOM 日志（dmesg） |
| 存储 IO | iostat %util（仅 HDD 语义强） | aqu-sz 深队列、await 高 | dmesg I/O error、smart 状态 |
| 网络 IO | sar -n DEV 带宽 | 重传、丢包（nstat、softnet） | ip -s link 的 errors/dropped |

纪律：**逐资源走完 U/S/E 再下结论**。USE 不告诉你根因，但保证你不漏维度——60 秒清单，就是这张表的命令化。

## 十、分流图：异常项指向哪条深钻路径

60 秒跑完，按异常项走分支，每支的叶子落在更重的工具上：

```text
load1/核>1 或 vmstat r>核数 ──> 疑似 CPU 饱和(load 也计 D 状态, id 高先走末行), mpstat 先看单核
  ├─ us 高 -> pidstat 定位进程
  │     ├─ 业务进程 -> perf record -g -> 火焰图找宽平顶
  │     └─ runtime 进程 -> 查 GC/JIT(JVM 加 GC 日志, go 用 pprof)
  ├─ sy 高 -> pidstat -w 看切换; cs 飙升 -> 锁竞争(strace -c 见大量 futex)
  │          mpstat 单核 %soft 高 -> 软中断收包路径(softnet_stat/ethtool -S)
  ├─ wa 高 或 b>0 -> iostat 三画像 -> pidstat -d 找进程 -> lsof 看在写什么
  │                  设备慢且是远端存储 -> NFS? 云盘限流? sar -n DEV 补位
  └─ st 高 -> hypervisor 超卖, VM 内无解, 找宿主机资源方

load 高但 id 高 -> ps 数 D 状态 -> 存储挂起/NFS 卡 -> /proc/<PID>/stack 定位等待点
available 低 或 si/so 非零 -> pidstat -r 的 majflt/s -> dmesg 找 OOM
%ifutil 高 或 retrans 涨 -> tcpdump / ip -s link
dmesg 有 OOM/MCE/I/O error -> 先处理硬件与内核事件, 再谈调参
```

树的价值是先分支再取数：us/sy/wa/st 把「CPU 高」这个模糊主诉，切成四种完全不同的病。

## 十一、反方观点：60 秒只够分诊，不够确诊

必须说清这套清单的边界，否则它会被滥用成「跑完就下结论」。

第一，清单只回答「哪类资源出问题」，不回答「为什么」。us 高之后，你还是得 perf 采样、火焰图找宽平顶；wa 高之后，还是得 pidstat -d 加 lsof 追到具体文件。

顺带把工具边界说死：perf 是采样型，开销约 1% 量级；strace 是拦截型，能看到单次调用的参数与 errno。「时间去了哪」用 perf；「这次调用发生了什么」才轮到 strace，且只挂你承受得起变慢的进程。

第二，60 秒是瞬时窗口，间歇性问题会漏。每分钟卡 5 秒的病，你盯着的这 60 秒可能一片祥和——这正是 sar 历史回放存在的理由。

第三，有些病这套清单天然扫不到：等锁的进程不在 CPU 上（off-CPU 问题，要 pidstat -w 或 off-CPU 火焰图）；应用层 GC 停顿；容器被 cgroup 节流（cpu.stat 的 nr_throttled）。清单说「系统层没异常」，不等于「没有病」。

所以我的立场是：**60 秒清单是分诊台不是手术室——它指路，不直接开药。**

## 十二、现在就能做的三件事

第一，趁机器健康，把基线存下来。事故时没有基线，是最贵的代价：

```bash
mkdir -p ~/perf-baseline && cd ~/perf-baseline
{ uptime; free -m; vmstat 1 5; mpstat -P ALL 1 3; iostat -xz 1 3; sar -n DEV 1 3; } | tee baseline.txt
```

第二，把十条命令按顺序手敲一遍，对着本文逐列判读。尤其按下 top 的 1 键——看看你过去有没有被均值骗过。

第三，拿一台真慢的机器跑完清单（没有的话，stress-ng --cpu 2 --timeout 60s 可以现造一台），评论区报你的「异常项 + 走了哪个分支」，我们一起对答案。

这套清单的完整版——USE 全表、决策树全文、三种人造负载的对照演练——在我的学习仓库：GitHub 搜 sre-learning-hub。

命令以 Ubuntu（apt 系）为准，RHEL 系替换包管理器即可。
