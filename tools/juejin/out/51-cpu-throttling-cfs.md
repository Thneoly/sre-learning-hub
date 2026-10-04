---
title_juejin: 'CPU 40%，P99 翻倍：--cpus=1 买的不是核'
title_zhihu: '容器均值正常而长尾爆炸，多半不是慢，是 CFS 限流'
description: '--cpus=1 不是一颗核，是每 100ms 发的时间粮票。cpu.max 读法、nr_throttled 判读、长尾与均值的矛盾、--cpu-shares 语义差、pidstat 排查链路。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686472562230312970"
---

# CPU 40%，P99 翻倍：--cpus=1 买的不是核

监控一片绿：容器 CPU 使用率 40%，离 limits 远着呢。用户却在报慢，P99 比上周翻了倍。

扩容都没触发——HPA 盯的也是均值，40% 够不着阈值。有人让他去读一个文件：`cpu.stat` 里的 `nr_throttled` 每秒涨 3。谜底揭开：不是没有 CPU，是突发在前半段就烧光 100ms 周期的粮票，剩下的时间全在罚站。

一个构造的典型案例，细节模糊化，现象真实。这篇只算一本账：`--cpus` 到底买了什么。

## 一、--cpus=1 的真身：不是一颗核，是每 100ms 发 100ms 粮票

`--cpus` 落到内核，是 cgroup CPU 控制器的带宽控制：给一组进程规定"每周期最多跑多少"。cgroup v2 里就一个文件 `cpu.max`：

```text
cpu.max = "<quota(微秒)> <period(微秒)>"
100000 100000  ->  每 100ms 周期最多 100ms CPU 时间 = 1 核
50000  100000  ->  0.5 核（对应 K8s limits.cpu: 500m）
20000  100000  ->  0.2 核
max    100000  ->  不限
```

换算一句话：`--cpus` 是 `--cpu-period`/`--cpu-quota` 的封装，period 默认 100000 微秒，quota = 核数 × period。`--cpus 1.5` 等价于 `--cpu-period 100000 --cpu-quota 150000`；quota 允许大于 period，4 核就是 400000。

两套写法同时给，docker 直接报错。dockerd 自己记的是纳秒核 `HostConfig.NanoCpus`（1.5 核 = 1500000000）。

亲手读一次：

```bash
docker run -d --name quota-demo --cpus 1 alpine sleep 3000
CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' quota-demo).scope
grep . $CG/cpu.max
# 预期：100000 100000——"每 100ms 发 100ms"，不是"分到一颗核"
cat /proc/$(docker inspect -f '{{.State.Pid}}' quota-demo)/cgroup
# 预期：0::/system.slice/docker-<长ID>.scope（v2 统一层级，一个目录管所有资源）
docker rm -f quota-demo
```

v1 时代这两个数写在 cpu.cfs_quota_us、cpu.cfs_period_us 两个文件里；v2 合成 cpu.max 一行。Ubuntu 22.04/24.04 默认就是 v2——`mount | grep cgroup` 的输出里只看得到 cgroup2 一行，即是。

另外调度器本体 6.6 内核起换成了 EEVDF，但这套带宽账本原样保留——24.04 上读的还是同一套文件。

**--cpus 买的不是核，是 100ms 一发的粮票。**

## 二、限流的体感：均值 40%，P99 爆炸

配额用尽的进程在周期剩余时间内被 throttle（冻结），下个周期恢复。这是 K8s CPU limit 的底层机制，也解释了那桩经典怪象：容器 CPU 使用率不高，却莫名变慢。

拿 limits.cpu=500m 推演：每 100ms 周期 50ms 配额。应用是突发型——一个请求触发 30ms 密集计算，两个请求叠在周期开头，50ms 配额瞬间烧光。从烧光到周期结束，cgroup 里所有线程整体冻结，请求实打实多等最多 50ms——这是按一核速率烧票的上限，计算摊到多核并行时冻结窗口更长（第五节算这笔账）。

更阴的是连坐：粮票记在整个 cgroup 头上，一个线程烧光，同组所有线程陪着冻结。多线程服务里常是某条处理线程突发吃票，无辜的 IO 线程、心跳线程一起罚站；限流的第二现场往往不在计算本身——健康检查超时、超时重试扎堆，都可能是罚站的连带伤害【从业者判断】。

坏就坏在"平均"二字。使用率按监控窗口均摊，50ms 冻结摊进几秒的窗口，均值还是 40%；但每个撞上冻结窗口的请求都多了几十毫秒。均值正常、长尾爆炸，是 CPU 限流的标准签名【从业者判断：体感归纳；冻结机制见上文】。

**限流不是让容器变慢，是让它整段整段地缺席。**

## 三、30 秒亲手数一次 nr_throttled

两个死循环想吃两核，只发一核粮票：

```bash
docker run -d --name thr-demo --cpus 1 alpine \
  sh -c 'while :; do :; done & while :; do :; done & wait'

CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' thr-demo).scope
grep -E 'nr_periods|nr_throttled|throttled_usec' $CG/cpu.stat
sleep 5
grep -E 'nr_periods|nr_throttled|throttled_usec' $CG/cpu.stat
# 预期：三个数都在涨——每秒约 10 个周期，周期周期被节流

docker stats --no-stream thr-demo
# 预期：CPU 约 100%（粮票顶格），宿主机大片 idle——不是没有 CPU，是不让用

vmstat 1 3
# 预期：id 很高、r 很低——机器很闲，容器在罚站
docker rm -f thr-demo
```

读法：`nr_periods` 是经过的周期数，`nr_throttled` 是发生节流的周期数，`throttled_usec` 是被冻结的总时长。三个数都是自 cgroup 创建起的累计值，隔几秒读两次看增速才有判据——单看一次快照，非零分不清是历史欠账还是正在发生。

顺带一句：`docker stats` 的 CPU% 是用量，不是配额命中率——100% 只说明粮票花光了，不说明有人挨饿。挨没挨饿，只有 cpu.stat 说话。

K8s 上同一件事，读 kubelet 的 cgroup：

```bash
CG=/sys/fs/cgroup/kubepods.slice; ls $CG >/dev/null 2>&1 && cat $CG/cpu.stat
# 关注：nr_throttled（节流次数）与 throttled_usec（冻结总时长）
find /sys/fs/cgroup -name cpu.stat -path '*kubepods*' 2>/dev/null | head -3 \
  | xargs -I{} sh -c 'echo "== {}"; cat {}'
```

**nr_throttled 是限流现场唯一不撒谎的证人。**

## 四、--cpu-shares：另一个语义，别拿它防节流

| K8s 概念 | 对应机制 | 效果 |
| --- | --- | --- |
| requests.cpu: 500m | cpu.weight（v1 为 cpu.shares） | 竞争时的最小保障，不设上限 |
| limits.cpu: 500m | cpu.max（quota 50ms / period 100ms） | 硬顶，超了 throttle |

`--cpu-shares 512` 落到 cpu.weight（v1 叫 cpu.shares），是相对权重：只在大家抢同一份 CPU 时决定谁多分一点，不设上限——机器空着就随便跑。权重思想承自 CFS 本体：nice 0 权重 1024，相邻 nice 差约 1.25 倍，权重越小虚拟运行时间涨得越快，越快被别人超车。

所以"把 shares 调大点防节流"是类别错误：shares 管排队名次，quota 管总量红线，两个旋钮拧的不是同一根轴。只靠 shares 撑场面的服务，上限其实由同机的空闲程度决定。

K8s 里 requests 落权重、limits 落配额，两行字段各管一头。想不节流，要么调大 cpu.max，要么 requests=limits（Guaranteed QoS：权重与配额一致，可预期、无节流意外）。

**--cpus 是粮票本，--cpu-shares 是加塞权。**

## 五、多核场景：配额是池子，不是每核一份

quota 记在 cgroup 头上，不按核拆分。这个设计有两面。

借的一面：这个核上的线程短促忙完就睡，省下的时间，同 cgroup 其他核上的线程随时接着用——池内先到先得，总量不超就行。

还的一面：--cpus=1 的容器开 4 线程并行爆发，四个核同时扣同一个池子，100ms 预算约 25ms 墙钟就烧光，剩下 75ms 全体冻结。核越多、并行越猛，烧得越快——"限流是突发问题"说的就是这件事。

把账算细一点：--cpus=1 配两条满负荷线程，并行跑时 100ms 预算 50ms 墙钟烧光，后 50ms 双双冻结；错峰跑则相安无事。同一条 limit，并行度不同命运完全不同。【从业者判断】这也是"压测正常、上线长尾"的经典剪刀差：压测流量平铺，线上突发叠加。

反过来，--cpus=4 配单线程应用：池子再大，一条线程每个周期最多也只能花 100ms，配额形同虚设。【从业者判断】不少"设了 limit 却从不节流"的容器，limit 从来没被并发摸到过。

**记账在 cgroup 不在核：能借，也能一次烧光。**

## 六、排查链路与三条解法

定性五步，从现象到实锤：

```bash
# 1-2. 定位 cgroup 并做 cpu.stat 差分（隔几秒读两次，看增速）
CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' <容器>).scope
grep -E 'nr_periods|nr_throttled|throttled_usec' $CG/cpu.stat
sleep 5
grep -E 'nr_periods|nr_throttled|throttled_usec' $CG/cpu.stat

# 3. 容器总量是否顶格
docker stats --no-stream <容器>

# 4. 线程视角：top 默认按进程聚合，按 H 键或 pidstat -t 才列线程
PID=$(docker inspect -f '{{.State.Pid}}' <容器>)
pidstat -t -p $PID 1 5

# 5. 宿主机视角：id 高、r 低、nr_throttled 却在涨，是"不让用"而非"没有"
vmstat 1 5
```

`pidstat -t` 这步对多线程应用（JVM 之类）是必做项：总量顶格不等于人人有份，先揪出是哪个线程在吃粮票。要更精细的队列延迟分布，可以再看 runqlat 直方图，被冻结的线程重新入队后的等待会在那里现形【从业者判断】。

解法三条，按代价排序：提高 limits，最直接；改用更小的周期粒度（发行版/运行时支持时），同样的配额切得更碎，单次冻结的上限随之变短；优化突发本身，治本。至于"干脆不设 limits"那一派：节流确实消失了，代价是失去噪声隔离——你的突发没了硬顶，直接挤到同机邻居头上。

Docker 下 `docker update --cpus 2` 在线生效不重启；K8s 下 Pod 的 resources 一直只能改了重建——原地扩缩容（In-place Pod Vertical Scaling）1.33 才进默认 beta（19 那篇拆参数时提过，以官方文档为准）——又是 Docker 比 K8s 灵活的一处。

**nr_throttled 增速说话：增速非零调配额，增速为零查别处。**

## 七、和内存坑对照：一个是钝刀，一个是猝死

同一套 cgroups，两种超限命运：CPU 摸顶是被冻结变慢，内存摸顶是 OOM 猝死——内存侧那四个参数，19 那篇已拆透，这里只摆对照。

| 维度 | CPU 超限（cpu.max） | 内存超限（memory.max） |
| --- | --- | --- |
| 下场 | 冻结变慢 | cgroup OOM，SIGKILL，Exited(137) |
| 面板 | 均值正常，长尾恶化 | 容器退出，或子进程悄悄消失 |
| 留痕 | cpu.stat 的 nr_throttled | OOMKilled=true、dmesg、memory.events |
| 在线调参 | docker update --cpus | docker update --memory |

内存超限是猝死，有死亡证明：137 = 128 + 9，先看 inspect 的 OOMKilled 再看 dmesg。CPU 超限是钝刀，进程全活着，只有延迟知道。**猝死当天就有人查，钝刀能拖一个季度。**

最常见的错位，是拿内存的直觉套 CPU：以为配额超限就会有报错、有退出、有日志。CPU 配额什么都不给——进程不退出，日志无异常，唯一的痕迹在 cpu.stat 和延迟曲线里。内存坑一次 137 就能定位，CPU 坑靠的是有人想得起去读计数器。

## 现在就能做的三件事

第一，扫一遍在跑容器谁在生产长尾：

```bash
for c in $(docker ps -q); do
  CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' $c).scope
  echo "$(docker inspect -f '{{.Name}}' $c): $(grep -E 'nr_throttled|throttled_usec' $CG/cpu.stat | tr '\n' ' ')"
done
# 重点：nr_throttled 非 0 且两次扫描在涨的容器，正在给你的长尾上供
```

第二，把扫描结果与各自的 --cpus 对一遍，配额紧的先补文档再补配额。

第三，延迟敏感的服务，评估 requests=limits 的 Guaranteed 配置——用资源换可预期性，值不值让 P99 说话。

这套实验（cpu.max 直读、限流复现、cgroup 差分，附自动判分脚本）在我的学习仓库：GitHub 搜 sre-learning-hub。

最后一句心法：**均值会撒谎，nr_throttled 不会。**评论区聊聊：你见过最冤的一次"CPU 很闲却慢"，最后定位到了什么？

实验基于 Ubuntu 22.04/24.04 + cgroup v2；K8s 细节以官方文档为准。
