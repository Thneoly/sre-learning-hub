---
title_juejin: 一启动就 Exited(137)：内存限制背后藏了四个参数
title_zhihu: 一启动就 Exited(137)：内存限制背后藏了四个参数
description: 容器Exited(137)不全是OOM。--memory-swap不设默认翻倍；reservation软顶救不了OOM；pids-limit防fork炸弹；update在线调参。附137判读链。
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686472562230312970"
---

# 一启动就 Exited(137)：内存限制背后藏了四个参数

周五晚上，两个容器先后以 Exited (137) 退场。

第一个 OOMKilled=true，同事把 --memory 一路加到 2g，照样退——--memory-swap 不设时额度默认翻倍、tmpfs 也计入配额，这两件事他都不知道。

第二个 OOMKilled=false，压根不是 OOM，是 docker stop 十秒超时后的 SIGKILL。同一个退出码，两种死法，调内存只治其一。

这篇把 137 的判读链和 --memory 背后那四个决定生死的参数一次讲透。

## 一、30 秒亲手造一次 137

137 = 128 + 9，进程死于 SIGKILL。它只说明"被强杀"，不说明为什么被杀——见到 137 就调大内存，是误判的起点。复现只要 30 秒：

```bash
# /dev/shm 是 tmpfs，写入的每一字节都算容器内存
docker run -d --name oom-demo -m 64m alpine \
  dd if=/dev/zero of=/dev/shm/big bs=1M count=200
sleep 2
docker inspect -f 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}}' oom-demo
# 预期：OOMKilled=true ExitCode=137
```

64m 的配额撞 200m 的写入，秒退。tmpfs 同样计入 cgroup 内存配额——"没分配多少堆内存怎么也 OOM"的答案常在这。

-m 64m 是 --memory 64m 的缩写，落到内核里叫 memory.max。要读这个数字，得换一个活着的长驻容器——cgroup 文件只在容器存活时可读，定位方式如下（cgroup v2，Ubuntu 22.04/24.04 默认，`mount | grep cgroup` 只有一行 cgroup2 即是）：

```bash
docker run -d --name cg-demo -m 64m alpine sleep 3000
CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' cg-demo).scope
grep . $CG/memory.max
# 预期：67108864（64MiB 的字节数）
docker rm -f cg-demo
```

别对刚才那个已经 OOM 退出的 oom-demo 读：容器主进程被杀、容器进入 Exited 后，systemd 会随即回收 docker-<id>.scope 这个 transient unit 的 cgroup 目录（containerd-shim 也已退出），此时 `grep . $CG/memory.max` 大概率报 `No such file or directory`。死容器只能靠 docker inspect / dmesg 留证——这也是上文用 inspect 而非 cgroup 文件收尾的原因。

## 二、判读链路：memory.max → oom_score → 137

内存触到 memory.max、换出与回收都无济于事时，内核走这条链：

```text
容器内存用量 → 触到 memory.max
        ▼
cgroup OOM killer 按 badness（oom_score）打分挑 victim，
通常最吃内存的进程分数最高 → 发 SIGKILL(9)
        ▼  ← 内核强制执行：不经过 handler，PID 1 的信号特判也保不住它
victim 是 PID 1 ─────────── victim 是普通子进程
        ▼                          ▼
容器退出 Exited (137)       容器还在，只是少了个进程
inspect: OOMKilled=true     只有 memory.events 的 oom_kill 计数留痕
```

判读证据三连，一次拷全：

```bash
docker inspect -f 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}}' <容器>
dmesg -T | grep -iE 'oom-killer|killed process' | tail
docker events --since 10m --filter event=oom
```

两个易混点，都是复盘吵架高发区。

其一，OOMKilled=false 的 137 也存在：docker stop 等满 10 秒超时后升级成 SIGKILL，就是这个码（PID 1 不处理 SIGTERM 的经典坑）。先看 OOMKilled 再看 dmesg。

其二，victim 不是 PID 1 时容器根本不退出。现象退化为"部分连接莫名消失"，日志一片祥和，唯一留痕是 memory.events 的 oom_kill 计数——这时加内存治标不治本，得揪出哪个子进程在吃。

顺带：--oom-score-adj 调被宿主机全局 OOM 选中的倾向；--oom-kill-disable 仅在与 --memory 同用时才安全。【从业者判断】不设上限就关它，等于放任容器吃到全局 OOM，死的可能是别人。

## 三、参数一 --memory-swap：你以为的 256m 是 512m

最贵的一个坑。--memory 是硬顶，--memory-swap 约定 memory + swap 的总额度，四种组合记牢：

| 启动参数 | 实际效果 |
| --- | --- |
| 只设 --memory 300m | 默认额度为 2 倍内存：总额 600m，其中 300m 可换出到 swap |
| --memory 300m --memory-swap 300m | swap 额度为 0，等于禁用 swap |
| --memory 300m --memory-swap 500m | swap 200m |
| --memory 300m --memory-swap -1 | swap 不限量（仍受宿主机 swap 总量约束） |

推论：以为 --memory 256m 锁死了 256m，实际容器最多占 512m 物理资源，一半泡在 swap 里。更阴的是换页把延迟拖垮——内存没超、进程没死，只是慢得没道理。

前提：宿主机启用了 swap（`swapon --show` 可查）。无 swap 的主机（云 VM 常见默认）上，这个默认翻倍只是 memory.swap.max 里的一个数字，无处换页，容器仍在 --memory 处即被杀——先确认主机 swap 状态，再按"翻倍"思路排查。

纪律就一条：对延迟敏感的服务，--memory-swap 一律设成与 --memory 相等。

## 四、参数二 --memory-reservation：软顶，救不了 OOM

--memory-reservation 落到 cgroup v2 的 memory.low（v1 叫 memory.soft_limit_in_bytes），是软限制：只在宿主机内存紧张时影响内核"优先从谁那里回收"，不挡分配，也不触发 OOM。

"我都设了 reservation 怎么还 137"是最常见的误用。会不会 OOM 只看 memory.max 一个文件，reservation 管不到生死，只管回收顺序。

它的正确舞台是缓存型服务：常驻内存大半是可重建的 cache，软限制让内核紧张时优先从你这回收。【从业者判断】经验值：reservation ≈ 常驻工作集，--memory ≈ 峰值加余量，以压测为准。

## 五、参数三 --pids-limit：第三种死法，还会连坐宿主机

资源超限的三种下场：CPU 超限是变慢（throttle），内存超限是死（OOM），进程数失控则把整台宿主机拖下水——一句 `:(){ :|:& };:` 就够。裸 Docker 默认不设 pids 限制。复现只要半分钟：

```bash
docker run -d --name fork-demo --pids-limit 20 alpine \
  sh -c 'while :; do sleep 300 & done'
sleep 3
docker ps -a --filter name=fork-demo --format '{{.Names}}: {{.Status}}'
docker logs fork-demo | tail -2
# 预期：容器很快退出，日志尾部 can't fork: Resource temporarily unavailable
docker rm -f fork-demo
```

判据是 pids.current 顶在 pids.max、pids.events 的 max 行计数被拒的 fork。注意这次不是 SIGKILL，是 fork 直接被拒——死法连 137 都不是，拿 OOM 的思路去查，第一步就歪了。

pids.max 计的是进程 + 线程总数：JVM 这类多线程应用每个线程都占名额，配额要给线程池留余量。【从业者判断】按实测峰值乘安全系数起步比较稳。

K8s 侧的对应物是 kubelet 的 podPidsLimit。【从业者判断】集群可经 kubelet 统一下发；裸 Docker 主机全靠自觉。

## 六、参数四 docker update：不重启，在线调参

前面三个参数设错了，不用等发版窗口。docker update 在线生效，容器进程不重启：

```bash
docker run -d --name updt --memory 256m --cpus 1 alpine sleep 3000
docker update --memory 512m --memory-swap 512m --cpus 2 --pids-limit 100 updt
cat /sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' updt).scope/cpu.max
# 预期：200000 100000
docker inspect -f 'StartedAt={{.State.StartedAt}}' updt
# 预期：时间没变——未重启
docker rm -f updt
```

事故现场最值钱的用法：OOM 杀完容器，先 update 调大限额保住业务，再从容查内存曲线——不销毁重建，容器 ID、日志等现场证据都还在。

两条规矩：--memory-swap 要与 --memory 一起调，前者不得小于后者；--memory 不能调到低于当前实际用量。

对照 K8s，这反而是 Docker 的长板：Pod 的 resources 长期只能改了重建（In-place Pod Vertical Scaling 1.27 起 alpha、1.33 才进默认 beta，以官方文档为准）。

## 七、和 K8s OOMKilled 对照着看

K8s 只是换了层翻译，底层还是同一套 cgroup 文件：

| K8s 概念 | docker 参数 | cgroup v2 落点 |
| --- | --- | --- |
| resources.limits.memory | --memory | memory.max |
| resources.limits.cpu | --cpus | cpu.max |
| Pod 进程数上限 | --pids-limit | pids.max（对应 kubelet 的 podPidsLimit） |
| Guaranteed QoS | — | Pod 级 memory.max == 所有容器 limit 之和 |

kubelet 把 137 翻译成 `Last State: Terminated, Reason: OOMKilled`——kubectl describe 里那行 OOMKilled，和 docker inspect 的 OOMKilled=true 是同一件事的两件马甲。

判读方法可以完全平移：先分 OOMKilled 与否，再 dmesg，再查子进程 victim。

【从业者判断】swap 翻倍主要坑裸 Docker / compose 环境，且前提是宿主机有 swap（见第三节）；K8s 的容器 swap 支持近几版才逐步放开，以官方文档为准——limits.memory 直接写 memory.max，不会被没写出来的默认值坑到。

## 八、两个反对意见，先替你问出来

"swap 默认 2 倍不是白捡的缓冲吗？"对能接受慢的离线任务，我同意留着——问题在不知情：延迟敏感的服务泡在 swap 里换页，内存没超、进程没死，只是 P99 悄悄爬升。

那 pids-limit 会不会误伤多线程应用？会，线程也计数；但"怕误伤就不设"更危险——fork 炸弹不给后悔的机会。按实测峰值留余量，两头都顾。

## 九、现在就能做的三件事

第一，扫所有容器的 137 历史：

```bash
docker ps -a -q | xargs docker inspect \
  -f '{{.Name}} OOMKilled={{.State.OOMKilled}} Exit={{.State.ExitCode}}'
# 重点：OOMKilled=true Exit=137（真 OOM，查内存）
#       OOMKilled=false Exit=137（stop 超时强杀，别调内存）
```

第二，审计谁踩在 swap 翻倍默认上：

```bash
swapon --show || echo '宿主机无 swap，翻倍默认无实际影响'
for c in $(docker ps -q); do
  CG=/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' $c).scope
  max=$(cat $CG/memory.max)
  [ "$max" = "max" ] && { echo "$(docker inspect -f '{{.Name}}' $c): 未设内存限制，跳过"; continue; }
  printf '%s max=%s swap=%s\n' "$(docker inspect -f '{{.Name}}' $c)" "$max" "$(cat $CG/memory.swap.max)"
done
# 判据分两步：
# 1. memory.max 是字符串 max ＝压根没设 --memory（跳过，谈不上 swap 翻倍）；
# 2. 再看 memory.swap.max：数值 == memory.max（且非 0）＝踩在 2 倍默认；
#    swap=0 ＝已禁用；swap 显示 max 字符串 ＝不限量（--memory-swap -1）。
# 注意：「配额存在」不等于「真的会换页」——宿主机无 swap 时 OOM 仍在 --memory 处触发。
```

第三，给裸奔容器补进程数上限，不用重启：

```bash
docker update --pids-limit 200 <容器名>
```

这套实验（cgroup 直读、137 复现、fork 炸弹防线，附自动判分脚本）在我的学习仓库：GitHub 搜 sre-learning-hub。

最后一句心法：--memory 只是入场券，生死簿写在 memory.max、memory.swap.max、pids.max 三个文件里。**137 是死亡证明，死因要去 cgroup 里找。**你见过 OOMKilled=false 的 137 吗？评论区对个暗号。

实验基于 Ubuntu 22.04/24.04 + cgroup v2，v1 文件名差异已随注；K8s 细节以官方文档为准。
