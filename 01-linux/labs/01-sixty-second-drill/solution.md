# Lab 01 · 解答:60 秒应急排查演练(CPU / 内存 / 磁盘)

> 演练方式:每轮先执行本文件对应场景的"注入命令",**只看注入那一节就合上文件**,
> 计时 60 秒排查,写完 `answers.txt` 再回来对照分析。三个场景互不影响,务必一轮一轮做。

## 0. 环境准备

做什么:装齐工具,建工作目录。为什么:`pidstat` 属于 sysstat,Ubuntu 最小安装默认没有。

```bash
# [任意节点]
sudo apt-get update
sudo apt-get install -y stress-ng sysstat
mkdir -p ~/drill
touch ~/drill/answers.txt
```

验证输出:

```bash
# [任意节点]
stress-ng --version && pidstat -V
# stress-ng 0.15.10 / sysstat 12.6.x(版本号以实际为准)
```

## 1. 场景 1 · CPU 打满

### 1.1 注入命令

做什么:用 stress-ng 把所有核压到约 95% 负载,持续 20 分钟,给你足够的排查窗口。

```bash
# [任意节点] 场景 1 注入
stress-ng --cpu "$(nproc)" --cpu-load 95 --timeout 20m --metrics-brief >/tmp/stress-ng.log 2>&1 &
```

`--cpu "$(nproc)"` 表示"用满所有在线 CPU 核";后台运行后立即开始计时。
注意别想当然写 `--cpu 0`:0 的含义是"所有**已配置**的处理器"。不少云镜像
`/sys/devices/system/cpu/possible` 是 0-127 而 `online` 只有 0-3,这时 `--cpu 0`
会一口气起 128 个 worker,负载冲到几十,`ps` 里每个 worker 只分到百分之几的
CPU——与"每核一个 worker、各 ~95%"的预期完全不符。实测用 `nproc` 最稳。

### 1.2 排查路径(60 秒时间线)

第 0~15 秒,确认负载是真的:

```bash
# [任意节点]
uptime
```

```text
# [任意节点] 预期输出(2 vCPU 机器)
 21:14:03 up 3:12,  2 users,  load average: 1.92, 0.87, 0.35
```

load average 1 分钟值逼近核数,且 1min > 5min > 15min——正在恶化,不是历史均值。

第 15~40 秒,找出谁在吃 CPU:

```bash
# [任意节点]
ps -eo pid,comm,pcpu --sort=-pcpu | head -6
```

```text
# [任意节点] 预期输出
   PID COMMAND          %CPU
  8412 stress-ng-cpu   96.7
  8413 stress-ng-cpu   95.9
  8411 stress-ng       0.7
     1 systemd          0.0
```

每个核一个 `stress-ng-cpu` worker,父进程是 `stress-ng`。

第 40~60 秒,确认持续性并回填告警指标:

```bash
# [任意节点]
pidstat -u 1 3 | grep -v '^$' | tail -8
```

`%CPU` 连续三个采样都在 95 上下,排除瞬时抖动。对应到告警:
`node_cpu_seconds_total{mode="idle"}` 掉到 5% 以下,就是这些 worker 把 idle 时间吃掉了。

### 1.3 根因

一个用户态压测进程 `stress-ng`(worker 为 `stress-ng-cpu`)打满了所有 CPU 核。
真实环境里同类"凶手"还有失控的压缩/加密任务、Java GC 风暴、被 DDoS 的应用。

### 1.4 还原命令

```bash
# [任意节点] 场景 1 还原
pkill -x stress-ng
rm -f /tmp/stress-ng.log
uptime   # load average 会在 1~5 分钟内回落
```

### 1.5 answers.txt 要点

Q1 填 `stress-ng-cpu(PID 8412 等,核数个 worker)`;Q2 至少两条(如 `uptime` + `ps --sort=-pcpu`);
Q3 一句话:"用户态压测进程打满所有核,非内核/IO 等待";Q4 填上面的 `pkill -x stress-ng`。

## 2. 场景 2 · 内存泄漏

### 2.1 注入命令

做什么:放一个每 2 秒泄漏 64 MiB 的 Python 进程,累计约 2 GiB 后停止增长(避免直接触发
OOM killer 把你的 shell 一锅端;泄漏量别超过物理内存的一半,4 GB 的机器泄 4 GiB 必被 OOM)。

```bash
# [任意节点] 场景 2 注入
cat > ~/drill/memleak.py <<'EOF'
#!/usr/bin/env python3
# 每 2 秒分配 64 MiB 且永不释放;累计约 2 GiB 后保持持有,避免触发 OOM killer
import time
chunks = []
for _ in range(32):
    chunks.append(bytearray(64 * 1024 * 1024))
    time.sleep(2)
print("leak stopped growing, holding ~2 GiB")
while True:
    time.sleep(60)
EOF
nohup python3 ~/drill/memleak.py >/tmp/memleak.log 2>&1 &
```

### 2.2 排查路径(60 秒时间线)

第 0~15 秒,看内存大盘,分清 available 与 free:

```bash
# [任意节点]
free -m
```

```text
# [任意节点] 预期输出(示例,总内存与系统占用不同数字会浮动;泄漏达到上限时)
               total        used        free      shared  buff/cache   available
Mem:            3888        3411         108          12         368         321
Swap:            975         208         767
```

告警看的是 `available`(内核眼里的可分配量),它低而 buff/cache 还在,说明内存被"拿住了",
不是页缓存——这是泄漏与"文件读多了"的第一分水岭。

第 15~45 秒,按 RSS 排序找进程,并确认"在涨":

```bash
# [任意节点]
ps -eo pid,comm,rss --sort=-rss | head -4
watch -n2 grep VmRSS /proc/10233/status
```

```text
# [任意节点] 预期输出
   PID COMMAND           RSS
 10233 python3        4023168
```

`VmRSS` 每 2 秒涨约 65536 kB——单调递增且不回落,泄漏实锤。

第 45~60 秒,看有没有已经发生的 OOM 事件:

```bash
# [任意节点]
dmesg -T | grep -i 'out of memory' | tail -3
```

真实环境里这条日志能直接告诉你被杀进程的 PID 与当时各进程 RSS 排名。

### 2.3 根因

`python3 ~/drill/memleak.py` 持续分配内存且持有不释放,RSS 单调增长直到把
`MemAvailable` 压到告警线。真实对应物:忘了设上限的缓存、加载全量数据的批处理、
容器没配 memory limit 导致整机可用内存被吃穿。

### 2.4 还原命令

```bash
# [任意节点] 场景 2 还原
pkill -f memleak.py
rm -f ~/drill/memleak.py /tmp/memleak.log
free -m   # available 应回到 2 GB 以上
```

### 2.5 answers.txt 要点

Q1 填 `python3 memleak.py,PID 10233,RSS 约 2000 MiB(仍在涨,直到 2 GiB 上限)`;Q3 写清两个特征:
RSS 单调增长 + 持有不释放;Q4 填 `pkill -f memleak.py`。

## 3. 场景 3 · 磁盘写满

### 3.1 注入命令

做什么:在 `/var/log` 下用 fallocate 造一个 8 GiB 的真实占块文件。先看剩余空间再定大小,
目标是让 `/` 使用率超过 90%。

```bash
# [任意节点] 场景 3 注入(20 GB 盘、剩余 10 GB 时用 8G;按你的机器调整)
df -h /
sudo fallocate -l 8G /var/log/diag-big.bin
df -h /
```

```text
# [任意节点] 预期输出(注入后)
/dev/sda2        20G   19G  412M  98% /
```

### 3.2 排查路径(60 秒时间线)

第 0~10 秒,确认是哪个文件系统满了:

```bash
# [任意节点]
df -h
```

第 10~40 秒,从根往下钻,`-x` 保证不跨文件系统、不误入挂载的虚拟目录:

```bash
# [任意节点]
sudo du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -6
sudo du -xh --max-depth=1 /var 2>/dev/null | sort -rh | head -6
sudo ls -lh /var/log/*.bin
```

```text
# [任意节点] 预期输出(最后一步)
-rw-r--r-- 1 root root 8.0G Aug 22 21:40 /var/log/diag-big.bin
```

第 40~60 秒,排除"df 满但 du 不满"的陷阱——确认没有已删除但仍被持有的句柄:

```bash
# [任意节点]
sudo lsof +L1 /var/log | head
```

本场景输出为空(文件仍在目录树里);若有输出,说明要处理的不是删文件而是重启持有句柄的进程。
小坑:`/var/log` 不是独立分区时,lsof 按所在设备过滤,同分区里其他"已删除仍被持有"的文件
(比如包升级后残留的 containerd-shim 二进制)也会混进来——看 NAME 列是否真在你排查的目录里。

### 3.3 根因

`/var/log` 下出现一个 8 GiB 的人工大文件,把根文件系统可用空间压到 5% 以下。
真实对应物:未轮转的应用日志、崩溃转储(core dump)、容器日志 JSON 文件失控。

### 3.4 还原命令

```bash
# [任意节点] 场景 3 还原
sudo rm -f /var/log/diag-big.bin
df -h /   # 使用率应回到 60% 以下
```

提醒:若文件被某进程持有,`rm` 后空间不会回来(df 仍满),此时要么 `truncate -s 0`,
要么重启该进程;本场景无进程持有,直接删即生效。

### 3.5 answers.txt 要点

Q1 填 `/var/log/diag-big.bin,8.0G`;Q2 如 `df -h` + `du -xh --max-depth=1`;
Q3 一句话:"日志目录被单一大文件占满,非 inode 耗尽";Q4 填上面的 `sudo rm -f`。

## 4. 收尾与判分

三个场景全部还原后运行判分:

```bash
# [任意节点]
cd 01-linux/labs/01-sixty-second-drill
chmod +x check.sh
./check.sh ~/drill/answers.txt
```

```text
# [任意节点] check.sh 通过时的输出
PASS: answers.txt 存在且包含场景 1/2/3
PASS: 场景 1 根因指向 stress/stress-ng
PASS: 场景 1 记录了 >=2 种排查工具
PASS: 场景 2 根因指向 python 泄漏进程
PASS: 场景 2 记录了内存占用数值
PASS: 场景 3 根因指向 /var/log 大文件
PASS: 还原命令已记录(kill + rm)
PASS: 现场已清理:无 stress/stress-ng 进程
PASS: 现场已清理:无 memleak.py 进程
PASS: 现场已清理:/var/log/diag-big.bin 已删,/ 使用率 41% < 90%
SCORE: 10/10
```

## 5. 延伸阅读

- 告警指标语义:node_exporter 指标列表 https://github.com/prometheus/node_exporter
- proc 文件系统字段(VmRSS 等):https://man7.org/linux/man-pages/man5/proc.5.html
- 内核内存管理文档:https://www.kernel.org/doc/html/latest/admin-guide/mm/concepts.html
