# 01 · 启动流程与 systemd

> 模块：01-linux 深入 ｜ 建议时长：3 小时 ｜ 关联认证：CKA-集群架构（kubelet 服务管理、kubeadm 装机）/ CKS-系统加固（sysctl）

## 学习目标

- 能解释从按下电源到 login 提示符之间，固件、GRUB、initramfs、内核、systemd 各自做了什么
- 能操作 systemd：查看/管理 unit、写一个自定义 service、用 drop-in 覆盖配置
- 能排查启动类故障：会用 GRUB 编辑进入 rescue/emergency 模式修系统
- 能用 journalctl 三板斧快速定位"这台机器刚才发生了什么"
- 能区分 sysctl 与 ulimit 两类系统参数，并知道它们在 K8s 节点上的正确落点

## 1. 从加电到 login：启动全链路

```text
# 启动全链路（x86_64 服务器/VM）
+------+
| POST |  通电自检：CPU/内存/设备枚举
+--+---+
   v
+------------------+   UEFI/Legacy BIOS 按 boot order 找启动设备
| 固件 (BIOS/UEFI) |   读磁盘 MBR 或 EFI 分区(\EFI\ubuntu\grubx64.efi)
+--+---------------+
   v
+------------------+   显示内核选择菜单(约 5 秒)
| GRUB2            |   加载 /boot/vmlinuz-* 与 /boot/initrd.img-* 到内存
| (bootloader)     |   传递内核参数(ro root=UUID=... quiet splash)
+--+---------------+
   v
+------------------+   解压 initramfs 到内存，作为第一个"根文件系统"
| initramfs        |   加载存储驱动/LVM 模块，找到真实根设备
| (内存中的临时根) |   挂载真实根，switch_root 跳过去
+--+---------------+
   v
+------------------+   初始化 CPU/内存/中断/时钟，启动内核线程(kthreadd)
| 内核初始化       |   挂载真实根后启动第一个用户态进程
+--+---------------+
   v
+------------------+   PID 1，按依赖并行启动 default.target 下的 unit
| systemd          |   最终给出 login 提示符
+------------------+
```

### 1.1 POST 与固件

POST（Power-On Self-Test）只关心"硬件是不是活的"。对运维有意义的两点：**boot order**——VMware 虚机用 ISO 装完机没改回磁盘启动，就会"重启又进安装器"；**UEFI vs Legacy**——Ubuntu 22.04/24.04 默认 UEFI，GRUB 是 EFI 分区里的一个 `.efi` 程序，`efibootmgr` 可查看启动项。

### 1.2 GRUB2：内核的选择与参数

GRUB 的菜单与参数来自 `/boot/grub/grub.cfg`，这个文件**不要手改**——它由 `/etc/default/grub` 加 `/etc/grub.d/*` 模板生成：

```bash
# [任意节点]
cat /etc/default/grub          # GRUB_TIMEOUT / GRUB_CMDLINE_LINUX_* 在这里改
sudo update-grub               # 重新生成 grub.cfg（Debian/Ubuntu 特有封装）
```

内核参数（cmdline）是运维调优的正规入口，例如 `nomodeset`、`systemd.unit=rescue.target`。开机时在 GRUB 菜单按 `e` 可以**临时**修改本次启动参数——这正是救援的入口（见实战演练）。

### 1.3 initramfs：为什么不能省

一个先有鸡还是先有蛋的问题：内核文件在 `/boot`，根文件系统可能在一个需要驱动才能读的设备上（RAID 卡、LVM），而驱动模块本身就在真实根的 `/lib/modules` 里。**initramfs 就是打破循环的那个临时根**：一个打包进内存的微型 Linux（cpio 归档），包含足以找到并挂载真实根的模块与脚本。Ubuntu 用 `initramfs-tools`（`update-initramfs` 命令）管理，RHEL 系用 `dracut`。换内核后起不来，高频原因就是忘了重新生成 initramfs。

```bash
# [任意节点]
lsinitramfs /boot/initrd.img-$(uname -r) | head -15            # 看临时根里装了什么
lsinitramfs /boot/initrd.img-$(uname -r) | grep -E 'ext4|nvme|lvm' | head
sudo update-initramfs -u                                        # 改模块配置后重新生成
```

### 1.4 内核初始化与 systemd

内核解压后初始化各子系统，创建内核线程（`ps` 里带方括号的 `[ksoftirqd/0]`、`[kworker/...]`），挂载真实根，然后把控制权交给第一个用户态程序——Ubuntu 上 `/sbin/init` 是 `/lib/systemd/systemd` 的软链接。systemd 作为 PID 1 干三件事：按依赖并行启动 unit、回收孤儿进程（第 4 章展开）、把日志交给 journald。

```bash
# [任意节点]
ps -p 1 -o pid,comm,args        # PID 1 是 systemd
readlink /sbin/init             # -> /lib/systemd/systemd
cat /proc/cmdline               # 本次启动实际生效的内核参数
```

## 2. systemd：unit、target 与依赖

### 2.1 unit 类型

| 类型 | 后缀 | 作用 | K8s 里的对应物 |
|---|---|---|---|
| service | `.service` | 守护进程/一次性命令 | kubelet、containerd、docker |
| socket | `.socket` | 监听 socket，按需激活 service | systemd 生态的 lazy 启动 |
| target | `.target` | 一组 unit 的"里程碑" | 类似"这批组件都起来了"的状态聚合 |
| timer | `.timer` | 定时触发 service，替代 cron | CronJob 的灵感来源 |
| mount/automount | `.mount` | systemd 管理的挂载点 | 节点磁盘/网络盘 |
| path | `.path` | 路径变化触发 | 类似 inotify 触发器 |
| slice/scope | `.slice`/`.scope` | 进程资源分组（cgroup 树） | 与 K8s QoS 分层思想同源 |

`systemctl list-units --type=service` 只显示**已加载**的 unit（`--all` 才含未激活）；`systemctl list-unit-files` 显示**磁盘上安装了**哪些。

### 2.2 target 依赖图

```text
# multi-user.target 附近的真实依赖（简化）
                    +------------------+
                    |  basic.target    |
                    +----+--------+----+
                         |        |
              +----------+        +------------+
              v                                v
   +---------------------+          +----------------------+
   | sysinit.target      |          | network-online       |
   | (挂载/交换/随机种子)|          | .target (等地址就绪) |
   +---------------------+          +----------+-----------+
                                                |
   +-------------------------------------------+----------+
   |                                                      |
   v                                                      v
+---------------------------------------------------------------+
|                     multi-user.target                          |
|  Wants= : ssh.service kubelet.service ...                     |
+------------------------------+---------------------------------
                               v
                     +-------------------+
                     | graphical.target  |  (服务器一般不到这层)
                     +-------------------+
```

依赖关系三要素，写 unit 时必须分清：

| 指令 | 语义 | 失败时 |
|---|---|---|
| `Wants=` | 想要你起来，你不起来我也不陪你死 | 各自独立 |
| `Requires=` | 强依赖，你失败则我也失败 | 本 unit 跟着 failed |
| `After=` | 仅声明**顺序**，不是依赖 | — |

最经典的错误写法：只有 `After=network.target` 就以为"网络好了才启动我"。`network.target` 的语义其实是"网络栈配置已交出"；想表达"有可用地址"要用 `Wants=network-online.target` + `After=network-online.target`。kubelet 的 unit 同时声明了这两条。

```bash
# [master]
systemctl get-default                                    # 通常 multi-user.target
systemctl set-default multi-user.target
systemctl list-dependencies multi-user.target | head -25
systemctl list-dependencies --reverse kubelet.service    # 谁依赖 kubelet
```

### 2.3 systemctl 常用操作与陷阱

```bash
# [任意节点]
systemctl status kubelet              # 状态、PID、最近日志片段
systemctl cat kubelet                 # 完整 unit(含所有 drop-in 合并结果)
systemctl show kubelet -p ExecStart -p FragmentPath -p DropInPaths
systemctl daemon-reload               # 改过 unit 文件后的必做动作
systemctl restart kubelet
systemctl mask kubelet                # 禁止一切形式启动(链接到 /dev/null)
systemctl unmask kubelet
systemctl list-units --state=failed   # 排障第一站
```

`disable` 与 `mask` 的区别：`disable` 只是不开机自启，手工 `start` 或被别的 unit `Wants=` 仍能拉起；`mask` 把 unit 链接到 `/dev/null`，任何途径都无法启动。排查时想临时彻底排除某服务嫌疑，`mask` 比 `stop` 可靠。

### 2.4 写一个自定义 service（含 drop-in 覆盖）

vendor unit（`/lib/systemd/system/` 下）不要直接改——包升级会覆盖。正规姿势：新文件放 `/etc/systemd/system/`，覆盖配置用 drop-in 目录 `/etc/systemd/system/<name>.service.d/*.conf`。

```bash
# [任意节点] 准备演示内容
sudo mkdir -p /srv/demo && echo "hello from demo-svc $(hostname)" | sudo tee /srv/demo/index.html
```

```ini
# [任意节点] 文件: /etc/systemd/system/demo-svc.service
[Unit]
Description=Demo HTTP service for learning-hub
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 -m http.server 18080 --directory /srv/demo
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
```

```bash
# [任意节点] 启用并验证
sudo systemctl daemon-reload
sudo systemctl enable --now demo-svc.service
systemctl status demo-svc --no-pager | head -8
curl -s http://127.0.0.1:18080/
```

用 drop-in 加资源限制，不动原文件：

```ini
# [任意节点] 文件: /etc/systemd/system/demo-svc.service.d/10-limits.conf
[Service]
MemoryMax=256M
LimitNOFILE=65535
```

```bash
# [任意节点]
sudo systemctl daemon-reload && sudo systemctl restart demo-svc
systemctl show demo-svc -p MemoryMax -p LimitNOFILE
```

timer 的写法（systemd 替代 cron 的形态）记个套路即可：`demo-report.timer` 用 `OnCalendar=*-*-* 03:30:00` 触发同名 `demo-report.service`（Type=oneshot），`Persistent=true` 允许补跑错过的周期，`systemctl list-timers` 查看下次触发时间。它的优势：输出进 journal、可补跑、防重叠。

## 3. journalctl 三板斧

journald 是 systemd 自带的结构化日志守护进程：二进制存储、按字段索引。三板斧覆盖 90% 的查日志场景。

**第一板斧：按 unit 过滤 + 跟随**

```bash
# [master]
journalctl -u kubelet -f                          # 实时跟随
journalctl -u kubelet --since "30 min ago"        # 时间窗
journalctl -u kubelet --since today -p warning    # 今天的 warning 及更严重
journalctl -u kubelet -n 100 --no-pager           # 最近 100 行
```

**第二板斧：按严重级别 + 按启动**

```bash
# [任意节点]
journalctl -p err -b           # 本次启动以来的 err 及更严重（err=4）
journalctl -p err -b -1        # 上一次启动（排查重启原因/宕机前现场）
journalctl --list-boots        # 历次启动编号与时间
```

**第三板斧：内核日志**

```bash
# [任意节点]
journalctl -k -b                          # 等价 dmesg，但可按启动过滤
journalctl -k -g -i 'oom|out of memory'   # grep 模式，查 OOM 现场（第 3 章展开）
```

组合拳——"kubelet 20 分钟前报过一次错，看看全系统上下文"：

```bash
# [master]
journalctl --since "-20 min" -p err -u kubelet --no-pager | tail -30
```

持久化与磁盘治理：Ubuntu 22.04/24.04 默认持久化（存在 `/var/log/journal`）。若 `journalctl --list-boots` 只有一行，说明是 volatile 模式，建目录重启 journald 即可：

```bash
# [任意节点]
sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald
journalctl --disk-usage
sudo journalctl --vacuum-size=500M     # 立即压到 500M 以内
sudo journalctl --vacuum-time=30d      # 只保留 30 天
```

长期上限写进配置而不是依赖手工 vacuum：

```ini
# [任意节点] 文件: /etc/systemd/journald.conf.d/99-size.conf
[Journal]
SystemMaxUse=1G
MaxRetentionSec=90day
```

## 4. sysctl 与 ulimit：两类系统参数

### 4.1 sysctl：内核参数

`sysctl` 读写的是 `/proc/sys/` 下的内核参数。`-w` 立即生效但重启丢失，持久化必须落 `/etc/sysctl.d/`：

```bash
# [任意节点]
sysctl net.ipv4.ip_forward                  # 读单个
sudo sysctl -w net.ipv4.ip_forward=1        # 立即写，重启丢
sudo sysctl --system                        # 按 /etc/sysctl.d、sysctl.conf 顺序全部重放
```

kubeadm 节点必设项（安装文档标准动作）：

```bash
# [任意节点] 文件: /etc/modules-load.d/k8s.conf
overlay
br_netfilter
```

```ini
# [任意节点] 文件: /etc/sysctl.d/99-k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
```

```bash
# [任意节点]
sudo modprobe overlay && sudo modprobe br_netfilter
sudo sysctl --system
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward   # 三个值都应是 1
```

意义：`ip_forward` 让节点路由 Pod 网段；`bridge-nf-call-iptables` 让网桥流量经过 iptables——没有它，NetworkPolicy 与 kube-proxy 规则对网桥流量不生效（第 5 章从 netfilter 角度再讲一次）。

### 4.2 ulimit：进程资源限制

`ulimit` 限制**单个进程**（fd 数、进程数、core 大小等）。关键边界：`/etc/security/limits.conf` 走 **PAM**，只对登录会话（ssh/su/login）生效；**systemd 服务完全不看它**，要用 unit 的 `LimitNOFILE=` 等（见 2.4 drop-in）。

```bash
# [任意节点]
ulimit -n            # soft 限制，常见 1024
ulimit -Hn           # hard 限制，常见 1048576
ulimit -n 65535      # 在 hard 上限内随时可调 soft（仅本 shell 及子进程有效）
cat /proc/$(pidof kubelet)/limits | grep -i 'open files'   # 看真实进程的限制
```

登录会话放开 nofile 写 limits.d：

```text
# [任意节点] 文件: /etc/security/limits.d/99-nofile.conf
*  soft  nofile  65535
*  hard  nofile  65535
```

排查 "Too many open files" 时，先 `cat /proc/<PID>/limits` 确认进程真实生效的限制，再决定改 limits.conf 还是 unit 的 `LimitNOFILE`——看错地方是最常见的弯路。

## 实战演练

### 演练 A：启动性能分析

```bash
# [任意节点]
systemd-analyze                                 # 固件/loader/内核/userspace 各阶段耗时
systemd-analyze blame | head -15                # 各 unit 耗时(并行启动,不可加总)
systemd-analyze critical-chain multi-user.target # 关键路径: 真正拖慢整体的是这条链
```

判读：`blame` 前列只是"串行链上较慢的一环"，要盯 `critical-chain` 的结尾几项。若 `network-online.target` 在链上且耗时长，多半是 wait-online 在等一个永远不 up 的接口（VM 挂了多余网卡时常见）。

### 演练 B：GRUB 救援（改 root 密码 / 修坏系统）

在 VMware 控制台重启 VM，GRUB 菜单出现时按 `e` 编辑：找到以 `linux /boot/vmlinuz-...` 开头的行，行尾追加 `init=/bin/bash`，按 `Ctrl-X` 启动，得到一个根为只读的 shell：

```bash
# [救援shell] 进入后的操作
mount -o remount,rw /        # 根变为可写
passwd                       # 设置新 root 密码
sync                         # 务必落盘
reboot -f                    # 强制重启(systemd 未运行,正常 reboot 不可用)
```

更温和的入口：把 `ro quiet splash` 改成 `systemd.unit=rescue.target`（单用户维护模式，有基本环境）或 `systemd.unit=emergency.target`（根只读最小 shell，修 fstab 错误用它）——这是第 2 章"fstab 写错导致起不来"的逃生通道。

### 演练 C：在 master 上体检 kubelet

```bash
# [master]
systemctl cat kubelet | head -40                        # 主 unit + 10-kubeadm.conf drop-in
journalctl -u kubelet -b --no-pager | tail -20          # 本次启动日志
cat /proc/$(pidof kubelet)/limits | grep -E 'open files|processes'
```

清理演练产物：

```bash
# [任意节点]
sudo systemctl disable --now demo-svc.service
sudo rm -rf /etc/systemd/system/demo-svc.service /etc/systemd/system/demo-svc.service.d
sudo systemctl daemon-reload && sudo rm -rf /srv/demo
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 改了 unit 文件 restart 不生效 | systemd 缓存了旧定义 | `systemctl daemon-reload` 后再 restart |
| 服务起不来但 `start` 无报错 | unit 被 mask 成 /dev/null | `systemctl unmask` 后再查 |
| limits.conf 对 kubelet 无效 | PAM 只管登录会话 | unit drop-in 写 `LimitNOFILE=` |
| `sysctl -w` 的参数重启消失 | 未持久化 | 写 `/etc/sysctl.d/*.conf` + `sysctl --system` |
| 换内核后卡在挂载根 | initramfs 缺新内核模块 | `update-initramfs -u -k all` |
| 磁盘满后服务行为诡异 | journald 写满 /var/log | `--vacuum-size=` + `SystemMaxUse` |
| kubelet 报 running with swap on | 装机带了 swap 分区 | `swapoff -a`，注释 fstab 中 swap 行 |
| 开机进 emergency mode | fstab 设备/选项错误 | GRUB 加 `systemd.unit=emergency.target` 修 fstab |

## 自测

1. 为什么内核不能直接挂载真实根文件系统，必须经过 initramfs？

<details><summary>答案</summary>

真实根所在设备的驱动可能是内核模块，而模块文件就在真实根的 `/lib/modules` 里——先有根才能加载驱动，先有驱动才能读根。initramfs 把"够用的驱动 + 挂载逻辑"打包进内存做临时根，打破循环。若驱动已编进内核（如常见 virtio），理论上可以不用 initramfs，但发行版为保证同一镜像能在各种存储上启动，默认都保留。
</details>

2. `Requires=` 加 `After=` 与只写 `Requires=` 有什么行为差异？

<details><summary>答案</summary>

`Requires=` 只声明依赖：被依赖者失败时本 unit 也转 failed；但 systemd 默认并行启动，两者**顺序不确定**，可能出现"我要的 socket 还没建好，我已经开跑"的竞态。`After=` 补上顺序约束。所以强依赖几乎总是成对出现；反过来只有 `After=` 时，即使对方没启动我也会启动，只是排队。
</details>

3. 为什么 `/etc/security/limits.conf` 管不住 systemd 服务？`LimitNOFILE` 又是怎么生效的？

<details><summary>答案</summary>

limits.conf 由 PAM 的 `pam_limits` 模块处理，只在建立登录会话时应用。systemd 服务由 PID 1 直接 fork/exec，不经过 PAM 会话栈，完全看不到这些限制。systemd 在 exec 服务进程前自己调用 `setrlimit(2)`，把 unit 里的 `LimitNOFILE=` 变成进程的真实限制——所以验证要看 `/proc/<PID>/limits` 而不是查 limits.conf。
</details>

4. `journalctl --list-boots` 只显示一条记录，说明什么？如何让上次宕机的现场可查？

<details><summary>答案</summary>

说明日志是 volatile 模式，只存在 `/run/log/journal`（内存文件系统），重启即丢。执行 `mkdir -p /var/log/journal && systemctl restart systemd-journald` 切到持久化。注意：断电这类"没机会写日志"的场景最后一截日志仍可能缺失，持久化只是扩大可查范围到历次启动，不保证完整。
</details>

5. `disable` 了某服务，为什么它还是会跑起来？什么场景必须用 `mask`？

<details><summary>答案</summary>

`disable` 仅移除自启链接，两条路仍能拉起它：手工 `systemctl start`，或被其他 unit `Wants=`/`Requires=`（被依赖激活）。`mask` 把 unit 链接到 `/dev/null`，systemd 视其为不存在，任何途径都无法启动。排查"疑似某 agent 干扰"想彻底排除、或防止某服务被间接拉起时用 `mask`。
</details>

## 延伸阅读

- systemd 官方手册：<https://www.freedesktop.org/software/systemd/man/systemd.html>
- unit 指令全表：<https://www.freedesktop.org/software/systemd/man/systemd.directives.html>
- journalctl 手册：<https://www.freedesktop.org/software/systemd/man/journalctl.html>
- kubeadm 安装前置（含 sysctl 清单）：<https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/>
