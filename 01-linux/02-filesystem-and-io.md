# 02 · 文件系统与 IO

> 模块：01-linux 深入 ｜ 建议时长：3.5 小时 ｜ 关联认证：CKA-存储（PV/挂载/扩容思路同源）

## 学习目标

- 能解释 VFS、superblock、inode、dentry、数据块各自的职责，以及"文件名存在哪里"
- 能从 inode 角度解释硬链接与软链接的全部行为差异，并动手验证
- 能对比 ext4 与 xfs 的取舍，为 etcd/数据库/日志盘做选型
- 能正确写 fstab（UUID、nofail、pass 字段），并用 LVM 完成一次在线扩容
- 能判读 iostat -x 的输出，区分"设备慢、队列深、调度器不合适"三种 IO 问题

## 1. VFS：一切文件系统的抽象层

Linux 支持 ext4/xfs/btrfs/tmpfs/nfs/procfs 等几十种文件系统，`open()`/`read()` 却不关心底层差异，这层统一接口就是 **VFS（Virtual File System）**。VFS 定义了四个核心对象：

```text
# VFS 核心对象与关系（打开 /var/log/syslog 读完它）
  superblock                inode                    dentry              file
 (一个已挂载fs)         (一个文件/目录的元数据)   (一层目录项,构成dentry树)  (一次open的结果)
 +-------------+        +---------------+        +-------------+     +-------------+
 | fs 类型      |  <--  | 权限/属主      |  <--   | 文件名 ->    |     | fd + 读写   |
 | 块大小/inode |        | 大小/时间戳    |        | inode 号映射 |     | 位置(offset)|
 | 空闲块位图   |        | 块指针(extent)|        | 父子关系缓存|     | 打开模式    |
 +-------------+        +---------------+        +-------------+     +-------------+
        |                     |                        |                  |
   记录"整个fs"的        记录"这个文件"的          记录"路径长什么样"      记录"这个进程
   全局状态               内容在哪、属性            (加速路径解析)         怎么用它"
```

打开 `/var/log/syslog` 的完整路径：进程调用 `open()` → 内核逐级解析路径（dentry cache 命中则免读盘）→ 拿到 inode → 建立 `struct file` → 返回 fd。此后 `read(fd, ...)` 都经由 fd 找到 file 与 inode。三个推论：

- 同一文件被两个进程打开，是两个 file（各自 offset），共享一个 inode。
- `ls` 快是因为 dentry cache；`ls -l` 慢是因为要取每个 inode 的属性。
- 挂载点只是"换了一棵 dentry 子树的来源"，VFS 让 procfs、tmpfs 与 ext4 用同一套调用。

```bash
# [任意节点]
cat /proc/filesystems        # 内核当前支持的文件系统
findmnt | head -15           # 比 mount 命令更清晰的挂载树视图
stat /var/log/syslog | head -8
```

## 2. inode：文件系统的心脏

### 2.1 inode 存什么、不存什么

| inode 存 | inode 不存 |
|---|---|
| 文件类型与权限（rwx） | 文件名 |
| 属主/属组 UID/GID | 目录层级关系（由 dentry 表达） |
| 大小、三个时间戳（atime/mtime/ctime） | "自己被谁引用"（引用计数即链接数，本身在 inode 内） |
| 硬链接计数（Links） | 数据本身 |
| 数据块指针（ext4 为 extent 树） | |

文件名的真面目：**目录也是一种文件，其内容是一张"文件名 → inode 号"的映射表**。所谓改名、移动（同文件系统内）只是改目录里的这条记录，inode 不动——所以 `mv` 一个 100GB 文件是瞬间完成的。

```bash
# [任意节点]
ls -i /etc/hosts                    # 看 inode 号
stat /etc/hosts | grep -E 'Inode|Links'
df -i /                             # inode 使用率（而不是空间）
sudo dumpe2fs -h /dev/sda1 2>/dev/null | grep -E 'inode size|Free inodes|Block count' || true
```

**inode 耗尽**是经典事故：`df -h` 明明有空间，写入却报 `No space left on device`。查 `df -i` 会看到 IUse% 100%。典型元凶是海量小文件（邮件队列、session 文件、容器镜像层的解包目录）。解法只有删文件；事前预防靠 mkfs 时更大的 bytes-per-inode 比例。

### 2.2 硬链接与软链接：本质差异

```text
# 硬链接：两个文件名指向同一个 inode
 /etc/data1 (名)          /etc/data2 (名)
       \                    /
        +------------------+
        |  inode 12345     |  Links 计数 = 2
        |  数据块指针 ...   |
        +------------------+

 # 软链接：一个独立 inode，内容是"另一个路径的字符串"
 /etc/soft1 (inode 22222, 类型=符号链接, 内容="/etc/data1") --> 按/else路径重新解析
```

```bash
# [任意节点] 动手验证
mkdir -p ~/linktest && cd ~/linktest && echo "original" > data1
ln data1 data2                # 硬链接
ln -s data1 soft1             # 软链接
ls -li                        # data1/data2 inode 相同；soft1 是新 inode
stat -c '%i %h %n' data1 data2 soft1
rm data1                      # 删掉原名
cat data2 && cat soft1        # data2 正常；soft1 仍正常（inode 还被 data2 引用）
rm data2 && cat soft1         # soft1 变悬空：cat: soft1: No such file or directory
ls -l soft1                   # 仍显示红色闪烁（如果有颜色）
cd ~ && rm -rf ~/linktest
```

| 行为 | 硬链接 | 软链接 |
|---|---|---|
| 是否新 inode | 否，共享原 inode | 是，独立 inode |
| 跨文件系统 | 不能（inode 号只在单个 fs 内有意义） | 能（只是字符串） |
| 链接目录 | 不允许（防止环） | 允许 |
| 原文件删除后 | 内容仍在（Links 减 1，到 0 才真正释放） | 悬空（dangling） |
| 判据 | `Links` 计数 | `ls -l` 首字符 `l` 与 `->` |

删除的真相：`rm` 只是减少 inode 的链接计数并把目录项移除；计数归零且无进程打开它时才释放数据块。**进程还打开着的大文件被 rm 后，空间不会释放**——这是"df 显示满、du 找不到大文件"的经典原因，第 6 章用 lsof 处理。

## 3. ext4 与 xfs

### 3.1 ext4 磁盘布局

```text
# ext4 把盘分成若干 block group（简化）
+---------+----------+---------------+-----------+--------------+----------------+
| 超级块  | 组描述符 | 块/inode 位图 | inode 表  |  journal     |   数据块 ...   |
|(sb备份) |  (GDT)   |  (占用位图)   | (整张表)  | (日志区域)    |                |
+---------+----------+---------------+-----------+--------------+----------------+
```

- **超级块**：文件系统的"身份证"——块大小、总块数、inode 数、挂载次数。损坏则整个 fs 不可挂载，所以它在多个组里有备份（`dumpe2fs` 可查，`e2fsck -b` 可用备份修复）。
- **journal**：写前先记日志（数据元数据操作的顺序），崩溃后 `e2fsck` 按 journal 重放，把 fs 快速恢复到一致状态，代价是写放大。
- **extent**：ext4 用"起始块 + 长度"的区间描述取代 ext2/3 的多级间接块指针，大文件的元数据更小、顺序性更好。
- **保留块**：默认 5% 给 root（`tune2fs -l` 可查 `Reserved block count`）。数据盘上这 5% 基本浪费，运维常调整。

```bash
# [任意节点]
sudo tune2fs -l $(findmnt -no SOURCE /) | grep -E 'Block count|Reserved|Block size|Filesystem features' | head
sudo tune2fs -m 1 $(findmnt -no SOURCE /)     # 保留块降到 1%（root fs 建议保持 5% 不动，数据盘可降）
```

### 3.2 xfs 的设计取舍

xfs 是 SGI 设计的高性能文件系统，RHEL 系默认。三个关键差异：

- **Allocation Group（AG）**：把盘切成多个 AG，元数据与分配操作可在 AG 间**并行**，多线程大文件写吞吐显著优于 ext4。
- **元数据更激进**：xfs 用 B+ 树管理 inode 与空闲空间，海量文件场景元数据性能更好；配合作业的延迟分配（delayed allocation）提升大文件连续性。
- **只支持在线扩、不支持缩**：`xfs_growfs` 在线扩容很稳；要缩容只能备份后重建。ext4 可扩（在线）也可缩（离线，风险高）。

| 维度 | ext4 | xfs |
|---|---|---|
| 默认于 | Ubuntu/Debian | RHEL 8+/Rocky |
| 大文件/高并发写 | 良好 | 更优（AG 并行） |
| 海量小文件 | 良好 | 元数据更优 |
| 在线扩容 | resize2fs | xfs_growfs |
| 缩容 | 支持（离线、慢、险） | 不支持 |
| fsck | e2fsck（较快，journal 重放） | xfs_repair（挂载态不支持在线修复，修复前须卸载） |
| 适用 | 通用系统盘、K8s 节点根盘 | etcd/数据库/大容量日志与对象盘 |

经验法则：K8s 节点系统盘保持发行版默认（Ubuntu=ext4）即可；独立数据盘、etcd 盘、大流量日志盘选 xfs。etcd 另有 fsync 延迟要求，底层至少要有 SSD，这与文件系统选择是两件事。

## 4. 挂载与 fstab

### 4.1 mount 选项里值得记住的

```bash
# [任意节点]
findmnt -no OPTIONS /            # 看根分区挂载选项
mount | grep -E ' /\s'           # 同上，老命令视角
```

- `relatime`（默认）：atime 只在比 mtime 旧或超过一天才更新，几乎无损；读敏感场景可显式 `noatime` 再省一点元数据写。
- `discard` vs `fstrim.timer`：SSM/TRIM 二选一。连续 discard 在老设备上伤性能，现代发行版默认用周期性 `fstrim.timer`，检查：`systemctl status fstrim.timer`。
- `nofail`：设备缺失时不阻塞启动。**外挂盘/NFS 必加**，否则一次存储抖动就让节点卡在 emergency mode。
- `_netdev`：标记设备需要网络就绪后再挂载（iSCSI/NFS）。

### 4.2 fstab 六个字段

```text
# [任意节点] 文件: /etc/fstab 示例（第 1~6 字段）
# <设备或UUID>                    <挂载点>  <类型>  <选项>              <dump> <pass>
UUID=1c2d...-ab                   /         ext4    errors=remount-ro   0      1
/dev/vg0/data                     /data     xfs     defaults,noatime    0      0
UUID=9f8e...-cd                   /srv/nfs  nfs4    defaults,_netdev,nofail,x-systemd.device-timeout=10  0  0
```

- 字段 5（dump）：几乎总为 0，历史遗留。
- 字段 6（pass）：fsck 顺序，`1` 给根、`2` 给其他本地盘、`0` 表示启动时不查（xfs 写 0，由 xfs_repair 自身在需要时处理；网络盘必须 0）。

```bash
# [任意节点]
sudo blkid                         # 拿 UUID（fstab 里用 UUID，避免设备名漂移）
sudo mount -a                      # 把 fstab 里未挂的都挂上（校验 fstab 的安全方法）
findmnt --verify                   # systemd 提供的 fstab 语法/语义校验
```

fstab 写错的后果分级：选项错误→启动进 emergency mode（第 1 章演练 B 的逃生通道就是为它准备的）；设备写死且丢失且没加 `nofail`→同样 emergency。养成习惯：改完 fstab 先 `findmnt --verify`，再 `mount -a`，两步都过了再重启。

## 5. LVM 基础

LVM 在"分区"之上加了一层可伸缩抽象，K8s 本地存储方案（local-path、OpenEBS LVM、Longhorn 底层思路）大量复用这套模型：

```text
# 三层抽象
 物理卷 PV          卷组 VG            逻辑卷 LV
+----------+      +--------------+   +--------+--------+
| /dev/sdb | -->  |              |   | lv-data| lv-swap |
| /dev/sdc | -->  |   vg0 (池子) |-->|  20G   |  4G     |
| (pvcreate)|     |  (vgcreate)  |   +--------+--------+
+----------+      +--------------+    (lvcreate, 对上层就是块设备 /dev/vg0/lv-data)
                                        再 mkfs.ext4 / mkfs.xfs 后挂载使用
```

用 loop 设备可以在不插新盘的 VM 上完整演练（生产请用真实盘）：

```bash
# [任意节点] 演练环境准备（kubeadm 节点也可，仅占 /tmp 空间）
sudo apt-get update && sudo apt-get install -y lvm2
fallocate -l 512M /tmp/lvm-disk1.img
sudo losetup /dev/loop10 /tmp/lvm-disk1.img       # 把文件模拟成块设备
sudo pvcreate /dev/loop10
sudo vgcreate vg_demo /dev/loop10
sudo lvcreate -n lv_data -L 400M vg_demo
sudo mkfs.ext4 /dev/vg_demo/lv_data
sudo mkdir -p /mnt/lvdata
sudo mount /dev/vg_demo/lv_data /mnt/lvdata
df -h /mnt/lvdata
```

在线扩容四步（生产最常用流程，加盘后无需停机）：

```bash
# [任意节点] 再塞一块"盘"进 VG，然后扩 LV 与文件系统
fallocate -l 512M /tmp/lvm-disk2.img
sudo losetup /dev/loop11 /tmp/lvm-disk2.img
sudo vgextend vg_demo /dev/loop11                 # 1. VG 吃进新空间
sudo lvextend -r -L +400M /dev/vg_demo/lv_data    # 2+3. 扩 LV 并(-r)联动扩文件系统
df -h /mnt/lvdata                                 # 4. 验证：可用容量增加
```

`-r` 参数内部对 ext4 调 `resize2fs`、对 xfs 调 `xfs_growfs`，免去手敲两套命令。三个查看命令背下来：`pvs`、`vgs`、`lvs`（详细版 `pvdisplay/vgdisplay/lvdisplay`）。

```bash
# [任意节点] 清理演练环境
sudo umount /mnt/lvdata
sudo lvremove -f vg_demo/lv_data && sudo vgremove -f vg_demo
sudo pvremove /dev/loop10 /dev/loop11
sudo losetup -d /dev/loop10 /dev/loop11
rm -f /tmp/lvm-disk1.img /tmp/lvm-disk2.img
```

## 6. IO 路径与调度器

### 6.1 一次 write 的完整旅程

```text
# 写路径（缓冲写）
 应用 write(fd, buf, 4096)
    |  (立即返回! 数据只进了内存)
    v
 page cache (页变 dirty)
    |  flusher 线程: 脏页超过 vm.dirty_background_ratio(默认~10%) 开始回写
    |               超过 vm.dirty_ratio(默认~20%) 时 write() 被反压阻塞
    v
 block layer (通用块层)
    |  IO 调度器: 合并/排序/强制公平
    v
 设备控制器 (可选 cache) --> 磁盘介质

 应用 fsync(fd) ----+  强制把该文件的脏页立刻落盘并等待完成(数据库/etcd 的保命调用)
                    |
 应用 O_DIRECT 写 --+  绕过 page cache 直达块层(数据库自管缓存时用)
```

推论：`cp` 完一个大文件后立刻断电，文件可能丢失或残缺——数据在 page cache 里；数据库不依赖这个"骗局"，所以它显式 fsync，etcd 的延迟瓶颈之一就是 fsync。看两个阈值：

```bash
# [任意节点]
sysctl vm.dirty_background_ratio vm.dirty_ratio
```

### 6.2 IO 调度器

```bash
# [任意节点]
cat /sys/block/sda/queue/scheduler 2>/dev/null     # SATA 云盘常见: [mq-deadline] ...
ls /sys/block/ | grep -E '^(sd|vd|nvme)'          # 本机有哪些盘
cat /sys/block/nvme0n1/queue/scheduler 2>/dev/null || true   # NVMe 常见: [none]
```

| 调度器 | 思路 | 适用 |
|---|---|---|
| `none` | 不排队，最小软件开销 | NVMe（硬件自身并行、队列深）默认 |
| `mq-deadline` | 按读/写分队列，保证请求不饿死，读优先 | SATA SSD/云盘默认 |
| `bfq` | 按进程公平分配带宽，交互友好 | 桌面、单进程慢 IO 会拖所有人的场景 |
| `kyber` | 以延迟为目标，简单快路径 | 快速多队列设备 |

临时切换（重启失效；持久化靠 udev 规则或 systemd tmpfiles，按发行版文档为准）：

```bash
# [任意节点]
echo bfq | sudo tee /sys/block/sda/queue/scheduler
cat /sys/block/sda/queue/scheduler       # 应显示 ...[bfq]...
echo mq-deadline | sudo tee /sys/block/sda/queue/scheduler   # 改回去
```

## 7. iostat 判读

```bash
# [任意节点]
sudo apt-get install -y sysstat
iostat -xz 1 3             # -x 扩展统计, 每秒 1 次, 共 3 次（首帧是开机以来均值，忽略它）
```

扩展列逐个解释（以 `sda` 一行为例）：

| 列 | 含义 | 判读要点 |
|---|---|---|
| `r/s w/s` | 每秒读/写请求数 | 与 `rareq-sz` 相乘才是带宽 |
| `rMB/s wMB/s` | 读/写带宽 | 看是否贴着设备上限 |
| `r_await w_await` | 读/写平均耗时（含队列等待） | HDD >10ms 常态，SSD 应 <1~2ms，明显高=排队或设备劣化 |
| `aqu-sz` | 平均队列深度 | >1 且 await 高 → 已饱和 |
| `rareq-sz wareq-sz` | 平均请求大小 | 4KB=随机小 IO；几百 KB 以上=顺序大 IO |
| `%util` | 有 IO 的时间占比 | **并行设备（SSD/NVMe）上严重低估利用率**，只能看趋势 |

三种典型画像：

1. **设备慢**：`await` 高、`aqu-sz` 在 1~2 附近、`%util` 中等——请求本身没堆积，是每个 IO 都慢（机械盘随机、远端存储抖动）。
2. **设备饱和**：`await` 高、`aqu-sz` 很大（几十）、`%util` 接近 100——排队严重，要么限流上层，要么换更快的盘。
3. **SSD 误读**：`%util` 100% 但 `await` 仍 <1ms——NVMe 并行能力强，`%util` 满不代表没余量，要看 await 与带宽是否达标。

定位"是谁在打 IO"用 `pidstat -d 1`（第 6 章 60 秒清单的一员），容器环境再配 `kubectl top`。

## 实战演练：眼见为实地看 page cache

```bash
# [任意节点] 生成 1G 测试文件，观察 page cache 与直写的差别
dd if=/dev/urandom of=/tmp/bigfile bs=1M count=1024 oflag=direct status=none   # 直写(不占cache)
free -h | awk 'NR==1||/Mem/'            # 记下 buff/cache
time cat /tmp/bigfile > /dev/null        # 第一次读: 读入 page cache
free -h | awk 'NR==1||/Mem/'            # buff/cache 涨了约 1G
time cat /tmp/bigfile > /dev/null        # 第二次读: 明显变快(内存命中)
```

预期：第一次读受磁盘带宽限制（几百 MB/s 量级），第二次接近内存速度（GB/s 量级）；`free` 的 `buff/cache` 增加、`available` 基本不减（cache 可回收）。这直接衔接第 3 章：**buff/cache 高不是问题，是 Linux 在把闲置内存当磁盘缓存用**。

再观察缓冲写 vs 直写的写延迟差异：

```bash
# [任意节点]
dd if=/dev/zero of=/tmp/w1 bs=1M count=512 status=none            # 缓冲写: 秒回(page cache)
dd if=/dev/zero of=/tmp/w2 bs=1M count=512 oflag=direct status=none  # 直写: 必须等盘
sync; rm -f /tmp/bigfile /tmp/w1 /tmp/w2
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `df -h` 有空间但报 No space left | inode 耗尽 | `df -i` 确认，清理小文件 |
| `df` 满、`du` 找不到大文件 | 大文件被 rm 但进程仍打开 | `lsof +L1` 定位，重启或重定向该 fd |
| 重启进 emergency mode | fstab 设备丢失/写错 | GRUB 加 `systemd.unit=emergency.target` 修 fstab；平时加 `nofail` |
| mv 百 GB 文件瞬间完成 | 同 fs 内只是改目录项 | 正常行为，不是错觉 |
| 删掉原文件后软链接失效 | 软链接存路径 | 用硬链接或接受语义差异 |
| xfs 盘想缩容 | xfs 不支持 | 备份后重建；要缩容场景选 ext4 |
| SSD 上 `%util` 100% 以为满载 | %util 不度量并行度 | 看 await/带宽判断真实压力 |
| cp 完断电文件损坏 | 数据尚在 page cache | 关键数据靠 fsync，不是依赖 cp 返回 |

## 自测

1. 为什么硬链接不能跨文件系统，而软链接可以？

<details><summary>答案</summary>

硬链接的本质是"在同一张 inode 表里增加一个指向既有 inode 的目录项"，而 inode 号只在单个文件系统内部唯一（每个 fs 有自己的 inode 编号空间），换个文件系统这个号码指向谁无从知晓。软链接是一个新文件，内容只是目标**路径字符串**，解析时按路径重新走 VFS 查找，天然跨文件系统、甚至可以指向尚未存在的路径。
</details>

2. `rm` 掉一个 10GB 且正被某进程读写的日志文件，为什么 `df` 不释放空间？正确的处置顺序是什么？

<details><summary>答案</summary>

rm 只移除目录项并把 inode 链接计数减到 0，但只要有进程持有该文件的 fd，inode 与数据块就不能回收。处置：先让进程自己滚动日志（如 nginx 的 `USR1`、或 logrotate 的 copytruncate/postrotate 机制），它会打开新文件、关闭旧 fd；若进程不支持，只能重启进程。应急释放空间的偏方是对着 `/proc/<PID>/fd/<n>` 做 `truncate -s 0`，但这会让写该 fd 的进程输出错乱，仅救急用。
</details>

3. 同样是在线扩容，ext4 与 xfs 的命令链有什么不同？`lvextend -r` 帮你省了什么？

<details><summary>答案</summary>

ext4：`lvextend -L +10G /dev/vg/lv` 之后 `resize2fs /dev/vg/lv`；xfs：之后 `xfs_growfs /挂载点`（注意 xfs_growfs 接的是挂载点，不是设备名）。`-r` 让 LVM 调 fsadm 自动识别文件系统类型并执行对应命令，省去记两套命令并避免"扩了 LV 忘了扩 fs"（fd 显示 LV 变大但文件系统容量不变）或"顺序搞反"的错误。
</details>

4. iowait 高但应用仍卡顿，`iostat` 里 await 正常、aqu-sz 很小，可能是什么问题？

<details><summary>答案</summary>

await 正常且队列浅说明本地块设备没有饱和，问题可能在别处：NFS/网络存储（iostat 不统计，要用 nfsiostat 或 sar -n DEV 看网络）；单次 IO 很大但很稀疏；或根本不是 IO 问题——iowait 只是"CPU 空闲且有未完成 IO"的派生值，CPU 一忙它反而会降（第 6 章详述）。应继续用 pidstat -d 确认进程级 IO、sar -n DEV 看网络吞吐，避免被单一指标带偏。
</details>

5. 为什么说 journal 让 ext4 崩溃恢复快？它保护的是什么、不保护什么？

<details><summary>答案</summary>

journal 把"将要做的元数据变更"先写进日志区再执行，崩溃后 e2fsck 只需重放/丢弃 journal 即可恢复一致性，不必全盘扫描。它保护的是**文件系统元数据一致性**（不出现半截 inode、目录项悬空），默认模式（data=ordered）只保证数据在元数据指向前先落盘的顺序，不保证文件**内容**在断电后完整——新写入的数据仍可能丢，这正是数据库要 fsync、etcd 对 fsync 延迟敏感的原因。
</details>

## 延伸阅读

- 内核文件系统文档索引：<https://docs.kernel.org/filesystems/index.html>
- ext4 文档：<https://docs.kernel.org/filesystems/ext4/index.html>
- xfs 官方站点：<https://xfs.org/>
- LVM 指南（含 VG/PV/LV 命令全表）：<https://man7.org/linux/man-pages/man8/lvm.8.html>
- sysstat / iostat 官方：<https://github.com/sysstat/sysstat>
