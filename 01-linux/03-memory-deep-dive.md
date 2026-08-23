# 03 · 内存深入：虚拟内存、page cache 与 OOM

> 模块：01-linux 深入 ｜ 建议时长：3.5 小时 ｜ 关联认证：CKA-集群架构（资源限制与 OOMKilled）/ PCA（node_memory_* 指标判读）

## 学习目标

- 能解释虚拟地址如何经页表翻译成物理地址，以及 minor/major fault 的差别
- 能说清 `/proc/meminfo` 里 Buffers 与 Cached 的真实语义，正确读 `free`（看 available）
- 能操作 buddy 与 slab 的观测接口（/proc/buddyinfo、/proc/slabinfo）判断内存碎片与内核对象占用
- 能解释 swappiness 的真实含义与"0 不等于禁用 swap"的原因
- 能排查一次 OOM：从内核日志重建 victim 选择过程，并区分 node 级 OOM 与 cgroup 级 OOM

## 1. 虚拟内存与页表

### 1.1 为什么每个进程都"独占 4GB（其实是 128TB）"

虚拟内存给每个进程一套连续、隔离的假象地址空间，CPU 的 MMU 负责把虚拟地址（VA）翻译成物理地址（PA）。它买到三样东西：**隔离**（进程 A 写不进 B 的地址）、**灵活**（物理页可以不连续、可以换出到 swap）、**共享**（同一段物理页可映射进多个进程，如共享库、后面 page cache 的 mmap 加速）。

```text
# 4KB 页 + 4 级页表（x86_64 常见配置，LA57 则 5 级）
 虚拟地址 48 bit = [PGD 9][PUD 9][PMD 9][PTE 9][页内偏移 12]
      |            |         |        |       |
      v            v         v        v       v
   CR3寄存器 -> PGD页 --PUD页 --PMD页 --PTE页 --物理页帧
   (每进程一个)                （PTE 里存: 物理页帧号 + Present/Dirty/_RW 等标志位）

 TLB: MMU 的翻译缓存。TLB 命中->零内存开销; 未命中->走 1~4 次内存读页表(page table walk)
```

两个运维推论：

- **页表本身也占内存**，约每 GB 映射 2MB 量级的页表（4KB 页、4 级表的下限）；海量进程的 VMM/DB 会体现为内核内存增长。
- **上下文切换贵在 TLB 失效**。换地址空间要把 TLB 冲掉，这是虚拟化/微服务进程切换成本的一部分；大页（2MB）能把 TLB 条目覆盖面扩大 512 倍，这是 THP 与 HugeTLB 存在的理由。

### 1.2 看一个真实进程的地址空间

```bash
# [任意节点]
cat /proc/self/maps        # 这条 cat 自己的映射
```

```text
# [任意节点] 输出示例（节选，地址因系统而异）
5551e6a00000-5551e6a01000 r--p 00000000 08:01 1234   /usr/bin/cat      # 代码段(只读)
5551e6a01000-5551e6a04000 r-xp 00001000 08:01 1234   /usr/bin/cat      # 可执行
5551e6a04000-5551e6a06000 r--p 00003000 08:01 1234   /usr/bin/cat      # 只读数据
5551e6a06000-5551e6a07000 rw-p 00005000 08:01 1234   /usr/bin/cat      # 已初始化数据
5551e6a07000-5551e6a08000 rw-p 00000000 00:00 0                         # 匿名(bss/heap 起步)
7f21c0000000-7f21c0021000 rw-p 00000000 00:00 0                         # 匿名(mmap 区)
7ffd3a120000-7ffd3a141000 rw-p 00000000 00:00 0    [stack]              # 栈
```

**VSZ 与 RSS 的区别**：VSZ 是映射的总大小（含从未触碰的部分），RSS 是真正落到物理页的部分。由于 lazy allocation，`malloc(10GB)` 只涨 VSZ；RSS 要等真的写入发生缺页才涨。监控看 RSS（容器里看 cgroup 的 `memory.current` 更准，它含 page cache）。

## 2. 缺页与 mmap

### 2.1 一次缺页的完整流程

```text
# CPU 访问 VA -> TLB 未命中 -> 页表 walk -> PTE 的 Present=0 -> 触发缺页异常
                内核 handle_mm_fault()
                        |
        该 VA 在某个 VMA(进程自己申请的映射区间)里吗?
          | 否 -> SIGSEGV (段错误, 就是"野指针访问"的内核回应)
          | 是
          +-- 映射的是文件页且已在 page cache? -> 建立映射, 直接返回
          |       = minor fault (次缺页, 无磁盘IO)
          +-- 文件页不在 cache / 匿名页被换出到 swap? -> 发起磁盘读
          |       = major fault (主缺页, 有磁盘IO, 贵百倍)
          +-- 匿名页首次触碰? -> 分配物理页清零并映射 (minor)
```

```bash
# [任意节点] 用 time -v 看缺页计数（多数发行版 /usr/bin/time 装于 time 包）
/usr/bin/time -v grep -r --include='*.conf' -l 'PermitRoot' /etc 2>&1 | grep -E 'Maximum resident|page faults'
# 输出关注:
#   Maximum resident set size (kbytes): 2340      <- 峰值 RSS
#   Minor (reclaiming a frame) page faults: 320   <- 走内存即可
#   Major (requiring I/O) page faults: 12         <- 动了磁盘(常是首次加载二进制/库)
```

**排查视角**：进程"变慢但 CPU 不忙"，看 major fault 是否在持续增长（`pidstat -r 1` 的 majflt/s 列）——内存吃紧导致反复换入换出时的典型信号。

### 2.2 mmap：把"文件"直接铺进地址空间

`mmap` 把一个文件（或匿名区域）映射进 VMA：读那段地址就是读文件（内核按需把 page cache 页挂进来），写完 `msync`/`munmap` 或依赖回写落盘。第 2 章 `cat` 第二遍变快的另一半解释：动态链接器加载 `.so` 用的就是文件 mmap——所有进程共享同一份 page cache 物理页。

| 组合 | 行为 | 典型用户 |
|---|---|---|
| 文件 + 私有（MAP_PRIVATE） | 写时复制，改动不回文件 | 加载可执行文件/共享库 |
| 文件 + 共享（MAP_SHARED） | 改动写回文件，进程间共享 | 数据库自管文件、内存映射 IPC |
| 匿名 + 私有 | 普通 malloc 大块内存 | 应用堆（glibc 大于 128KB 阈值走 mmap） |
| 匿名 + 共享 | 进程间共享内存 | 共享内存 IPC |

## 3. page cache 与 free 的正确读法

### 3.1 Buffers vs Cached 终极辨析

历史上 Linux 有两套缓存：buffer cache（按块缓存块设备内容）与 page cache（按页缓存文件内容）。2.4 之后**统一进 page cache**，`/proc/meminfo` 里两个计数成了"同一机制的两种记账"：

| 字段 | 真实语义 | 典型大小 |
|---|---|---|
| `Buffers` | 块设备裸块与文件系统**元数据**（ext* 的超级块/位图等经 buffer head 的部分） | 几十~几百 MB |
| `Cached` | 文件内容页 + tmpfs 的页（Shmem 也计在这里） | 通常最大头 |
| `SReclaimable` | slab 中可回收部分（dentry/inode 缓存等） | 几百 MB |
| `Shmem` | tmpfs/共享内存占用的页——**在 Cached 里但不可直接丢弃** | 取决于 /dev/shm、容器 tmpfs |

`free` 的 `buff/cache` 列 = Buffers + Cached + SReclaimable；这些页几乎都能在缺内存时立刻丢弃或回写让出——除了 Shmem 部分（只能换出），`available` 已经把这笔账算进去了。

### 3.2 free 输出逐列解读

```bash
# [任意节点]
free -w -h
```

```text
# [任意节点] 输出示例（-w 把 buffers/cache 拆开）
               total        used        free      shared     buffers       cache   available
Mem:           7.6Gi       1.4Gi       512Mi        64Mi       210Mi       5.5Gi       5.8Gi
Swap:             0B          0B          0B
```

判读规则只有一条主线：**看 available，不看 free**。`available` 是内核估计的"不换出的前提下还能给新分配的量"（含可回收 cache，扣除部分保留水位）。free 少是 Linux 的正常状态——闲置内存被拿去做 cache，任何进程要内存时毫秒级归还。`used` 大涨先查是不是 tmpfs（shared 列）与 slab，而不是急着"清理内存"。

顺带破除一个迷信——`echo 3 > /proc/sys/vm/drop_caches`：它只应在可重复的基准测试前清场用，生产上执行后短时间 IO 飙高（所有热数据重新从盘读），通常弊大于利。

### 3.3 写回与脏页水位

```bash
# [任意节点]
grep -E 'Dirty|Writeback' /proc/meminfo      # 当前脏页量（KB）
sysctl vm.dirty_background_bytes vm.dirty_ratio
```

脏页积累到 `vm.dirty_background_ratio`（百分比）或 `_bytes` 触发后台回写；到 `vm.dirty_ratio` 时写进程被**反压**（write 阻塞）强制回写。K8s 节点上如果有大流量日志落盘，适当调低 background 水位可让 IO 更平滑，代价是回写更频繁。

## 4. buddy 与 slab：内核自己的两套分配器

### 4.1 buddy：管物理页帧

内核按 2 的幂次（order 0=4KB，order 1=8KB，… order 10=4MB）组织空闲页。分配大块需要**物理连续**的高阶页，长时间运行后内存碎片化，高阶阶位枯竭——这就是"内存还有富余，但大页/某些设备分配失败"的原因（内核靠 compaction 迁移页缓解）。

```bash
# [任意节点]
cat /proc/buddyinfo
```

```text
# [任意节点] 输出示例: 每个节点/zone 一行, 第 N 列 = order N 的空闲块数
Node 0, zone   DMA32    12   8   4   2   1   0   0   0   0   0   0
Node 0, zone  Normal   340 256 180  90  31  12   3   1   0   0   0
# 读法: Normal 区 order0 有 340 个 4KB 页, order4 有 31 个 64KB 块, order8 以上为 0
# 若右侧高阶列长期全 0 -> 碎片化, 透明大页/巨页分配会失败
cat /sys/kernel/mm/transparent_hugepage/enabled   # THP: always/madvise/never
```

### 4.2 slab：管内核小对象

内核频繁分配固定大小的小对象（inode、dentry、网络包描述符、锁），逐页分配太浪费，slab 把"对象池 + 穘初始化缓存"做成一层。**它就是 VFS 快的原因之一**：`ls` 不读盘，因为 dentry/inode 还躺在 slab 里。

```bash
# [任意节点]
head -3 /proc/slabinfo
sudo slabtop -o -s c | head -15        # slabtop 随 procps 预装; 按大小排序看活跃 slab 缓存
```

关注两个名字：`dentry`（路径名缓存）与各 fs 的 inode cache（如 `ext4_inode_cache`）。容器节点上海量镜像层与短生命周期文件会让它们膨胀；它们属于 `SReclaimable`，压力下内核会收缩，一般无需人工干预——若怀疑"slab 吃内存"，对比 `SReclaimable` 与 `Slab` 的差值（不可回收部分 `SUnreclaim` 才是真占用）。

## 5. swap 与 swappiness

### 5.1 swap 到底换什么

page cache 页可以直接丢弃（数据在盘上已有），**匿名页**（堆、栈这些没有文件背书的页）想腾出物理内存就只有一条路：写到 swap。所以 swap 的本质是"给匿名页也配一个可退让的盘上后备"。

```bash
# [任意节点]
swapon --show            # 有无 swap 设备/文件及优先级
free -h | grep -i swap
cat /proc/meminfo | grep -E '^Swap'
```

K8s 节点惯例：kubelet 传统上要求禁用 swap（检测到即拒绝启动，`fail-swap-on`）。新版本有条件支持（需额外配置），生产集群仍普遍关闭——这会让"内存压力"直接走向回收 page cache 与 OOM，而不是换出。本课程练习集群按官方安装文档保持 swap off。

### 5.2 swappiness 的真实含义

`vm.swappiness`（0~100，默认 60）不是"swap 使用率"，而是**内核在匿名页与 page cache 之间的倾向权重**：

| 取值 | 行为 | 场景 |
|---|---|---|
| 0 | 尽量不换出匿名页，只有接近 OOM 才动 swap | **不等于禁用**；内存够时也不碰 swap |
| 1 | 最小程度换出 | 部分 DB 建议 |
| 10~20 | 温和 | 延迟敏感型服务常见折中 |
| 60（默认） | 平衡 | 通用 |
| 100 | 积极换出匿名页保 page cache | 桌面"回来还是热的" |

误读"0=禁用 swap"的代价：以为设 0 就高枕无忧，结果内存吃紧时内核仍会 swap（或更糟——直接 OOM）。要真禁用只能 `swapoff -a` 并移除 fstab 中的 swap 条目。

### 5.3 判读换页是否成为问题

```bash
# [任意节点]
vmstat 1 5               # si/so 两列: 每秒从 swap 换入/换出量(KiB)
```

`si/so` 长期非零且伴随业务延迟上升 = 内存真不足或 swappiness 过高；偶发小尖峰（如夜间备份唤醒冷页）不必处理。`si` 持续高比 `so` 更伤——换入是随机读，会直接打爆 IO。

## 6. OOM killer：选人逻辑与现场还原

### 6.1 什么时候触发

分配内存的路径上：先尝试回收（丢干净 page cache、回写脏页、必要时换出匿名页）→ 仍凑不齐且越过水位线 → 触发 OOM。**cgroup 场景是另一条触发**：进程组用量顶到 `memory.max`（K8s 的 memory limit），即使整机内存充裕，也照样在 cgroup 内杀进程——这就是 Pod `OOMKilled` 的来源。

### 6.2 victim 怎么选

内核的 badness 打分（现代内核以进程占用总页数为基准：RSS + swap + 页表页，再按 `oom_score_adj` 修正）：

```text
badness ∝ (RSS + swap + page tables) 的总量, 再叠加 oom_score_adj 修正
```

- `/proc/<PID>/oom_score`：只读，当前得分（越高越先死）。
- `/proc/<PID>/oom_score_adj`：可写，-1000 ~ +1000。**-1000 = 免死**，+1000 = 优先杀。

K8s 的实用关联：QoS 等级映射到不同 adj——Guaranteed Pod 常见 -997（较难被杀），BestEffort 常见 +1000（先死），kubelet 自身 -999。node 级内存压力驱逐（eviction）是 kubelet 行为，与内核 OOM 是两层机制，但 victim 倾向一致。

### 6.3 日志现场与排查命令

```bash
# [任意节点]
journalctl -k -b | grep -iE 'out of memory|oom-kill|killed process' | tail -20
```

```text
# [任意节点] 内核日志示例（节选，逐行解读）
node invoked oom-killer: gfp_mask=0x...(GFP_KERNEL), order=0, oom_score_adj=0
                                              # 谁触发: 进程分配内存时失败, order=0 表示只要一页
Mem-Info: ... free:21000 min:... low:... high:...   # 空闲页已低于水位线
Out of memory: Killed process 3189 (java) total-vm:8388600kB, anon-rss:6123456kB, total-vm:8GB...
                                              # victim: java, 匿名 RSS 6GB 是它被选中的原因
```

排查三问：被杀的是谁（身份 + anon-rss）？它该不该吃这么多（应用侧泄漏 or 配置错误）？为什么是它（查 `/proc/<PID>/oom_score_adj` 是否被 K8s QoS 推高）。容器场景先跑 `kubectl describe pod` 看 `Last State: Terminated, Reason: OOMKilled`，再回节点看这段内核日志区分 node 级还是 cgroup 级。

## 实战演练

### 演练 A：制造并观察一次 cgroup OOM

用 systemd 的 transient scope 给一条命令加内存上限，比改 unit 干净：

```bash
# [任意节点]
sudo systemd-run --scope -p MemoryMax=64M -p MemorySwapMax=0 \
  python3 -c 'a = bytearray(300*1024*1024); print("allocated", len(a))'
```

预期：python 被 SIGKILL，shell 提示进程退出；`echo $?` 在交互 scope 外拿不到，直接看日志：

```bash
# [任意节点]
journalctl -k --since "-2 min" | grep -iE 'oom|memory' | tail -5
```

预期看到 `Memory cgroup out of memory: Killed process ... (python3)`。这正是 Pod 内存 limit 的底层机制（cgroup v2 `memory.max`，Ubuntu 22.04+ 默认 cgroup v2），对照 K8s：把 limit 设 64Mi、容器申请 300Mi，效果相同——`OOMKilled`。

### 演练 B：看 free 的三个时刻

```bash
# [任意节点]
free -h && grep -E '^(Buffers|Cached|SReclaimable|Shmem|Available):' /proc/meminfo
dd if=/dev/urandom of=/tmp/mem-demo bs=1M count=300 status=none
time cat /tmp/mem-demo > /dev/null          # 第一次: 有磁盘读
grep -E '^(Cached|Available):' /proc/meminfo # Cached 涨 ~300MB
time cat /tmp/mem-demo > /dev/null          # 第二次: page cache 命中, 明显变快
free -h                                     # available 基本不变: cache 是"随时可让"的
rm -f /tmp/mem-demo
```

### 演练 C：检查练习集群节点的内存画像

```bash
# [master]
free -w -h
cat /proc/buddyinfo
head -5 /proc/slabinfo
kubectl get pods -A -o jsonpath='{range .items[*]}{.status.qosClass}{"\n"}{end}' | sort | uniq -c
```

最后一行的目的：把"节点 available 不足 → node 级压力 → QoS 低的先被驱逐/杀死"这条因果链和自己集群里的 Pod 清单对上号。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| buff/cache 占大半被当内存泄漏 | page cache 是正常设计 | 看 available 判定真实余量 |
| 用 free 列判断"内存快满了" | free 必然趋近于小 | 看 available |
| 设 swappiness=0 以为禁了 swap | 0 只是"尽量不"，压力下仍会换出 | `swapoff -a` + 清 fstab 条目 |
| Pod OOMKilled 但节点内存充裕 | cgroup memory.max 触发，与整机无关 | 提 limit 或查应用内存增长 |
| shared 列大导致 available 偏低 | tmpfs 占用不可回收 | 排查 /dev/shm 与容器 tmpfs |
| 内存有富余却分配大页失败 | buddy 高阶碎片化 | 看 /proc/buddyinfo，安排 compaction 或预留 hugepages |
| Slab 占用大被当异常 | dentry/inode 缓存是 SReclaimable | 压力下自动收缩，先对比 SUnreclaim |
| drop_caches 后服务变慢 | 热数据全部失效重读 | 只用于基准测试清场 |

## 自测

1. 进程 malloc 了 10GB 但 RSS 只有 200MB，断电重启后（假设无 swap）这 10GB 里丢失了什么？

<details><summary>答案</summary>

严格说什么都没"丢失"——malloc 本身只是登记了一段 VMA，从未写入的匿名页根本没有分配物理页，也没有任何数据存在过。真正写入过的那部分（在 RSS 里）因断电丢失（匿名页无盘上后备）。这个例子说明 VSZ 只是"承诺"，物理占用以缺页发生为准，监控与容量规划都应基于 RSS/cgroup 计数。
</details>

2. Buffers 和 Cached 在现代内核里为什么还是两个数字？tmpfs 的页藏在哪个数字里，为什么 available 不会把它算成可回收？

<details><summary>答案</summary>

统一 page cache 后二者只是记账口径不同：Buffers 记块设备/文件系统元数据路径上的块，Cached 记文件内容页。tmpfs 的页没有文件后备，但仍被计入 Cached（同时体现在 Shmem），它们不能像普通脏净页那样"丢弃后可从文件重读"，只能换出到 swap 才能腾出物理页。available 的估算因此对 Shmem 打折扣——把 tmpfs 当"可用内存"是容量规划常见错误。
</details>

3. 为什么 `si`（换入）持续高比 `so` 高对性能伤害更大？

<details><summary>答案</summary>

`so` 换出的是内核主动选择的"冷页"，可以批量、顺序地写，且换来的是当时的物理页余量；`si` 换入则完全由访问模式驱动——进程碰到被换出的页发生 major fault，同步等待一次随机读。冷页换出是"预付"，换入是"到期还账"，还账是随机的、在请求路径上的。所以看到 si 持续非零说明工作集已大于物理内存，扩内存或调 swappiness 比优化 IO 更对症。
</details>

4. 一个 Guaranteed Pod 和一个 BestEffort Pod 同在一个内存紧张的节点上，为什么死的总是后者？kubelet 用了什么机制？

<details><summary>答案</summary>

两层机制都偏向保护 Guaranteed：kubelet 给不同 QoS 的容器设置不同的 oom_score_adj（Guaranteed 常见 -997、BestEffort 常见 +1000），内核 OOM 打分时 adj 越高越先被选为 victim；此外 kubelet 的驱逐（eviction）在节点内存压力下也按 QoS 排序先驱逐 BestEffort。这解释了生产建议"重要服务配 Guaranteed（requests=limits）"的底层理由——不只是调度行为，还有 OOM 时的免死倾向。
</details>

5. 节点显示还有 2GB available 却发生了 OOM，给出至少两种可能解释。

<details><summary>答案</summary>

（1）cgroup 级 OOM：某容器顶到自己的 memory.max，与整机余量无关，日志里是 "Memory cgroup out of memory"。（2）分配约束不满足：申请的是高阶连续页或特定 zone（如 DMA32），available 有量但碎片化/分布不满足，看 buddyinfo 与日志里的 order=/nodemask。（3）available 是估算值，水位线（min/low）与不可回收部分（kernel、SUnreclaim）使"可用"不等于"可即刻分配"。排查先读 oom 日志里的 gfp_mask/order 与触发进程，再对号入座。
</details>

## 延伸阅读

- 内核内存管理概念（官方文档）：<https://docs.kernel.org/admin-guide/mm/concepts.html>
- OOM killer 文档：<https://docs.kernel.org/admin-guide/mm/oom.rst>
- swap 与 swappiness：<https://docs.kernel.org/admin-guide/mm/swap.html>
- /proc/meminfo 字段：<https://docs.kernel.org/filesystems/proc.html#meminfo>
- K8s 资源管理（requests/limits/QoS）：<https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/>
