# 07 · 用户与权限体系：凭证、sudo、SUID 与 capabilities

> 模块：01-linux 深入 ｜ 建议时长：3 小时 ｜ 关联认证：CKS-系统加固（capabilities 最小权限）/ CKS-微服务漏洞（runAsNonRoot）

## 学习目标

- 能解释 uid/gid 与进程凭证（real/effective/saved），判断"这个进程到底以谁的身份在跑"
- 能操作 sudoers：用 visudo 与 `/etc/sudoers.d/` 做最小授权，说清 NOPASSWD 的边界
- 能排查一台机器的提权面：SUID/SGID 二进制与 file capabilities 的清点与收敛
- 能用 getcap/setcap/capsh 把 root 特权拆成 capability 粒度，而不是全有或全无
- 能推算 umask 对新文件/目录权限的影响，并解释 PAM 栈为什么只影响登录会话

## 1. uid/gid：内核只认数字

### 1.1 账号文件的三个来源

用户名只是给人看的标签，内核判定身份只用数字 uid/gid。三张表：

| 文件 | 存什么 | 运维要点 |
|---|---|---|
| `/etc/passwd` | name:x:uid:gid:GECOS:home:shell | uid 0 就是 root，改名字不改身份；nologin shell 挡交互登录 |
| `/etc/shadow` | 密码哈希与过期策略 | 仅 root 可读，所以改密码需要特权 |
| `/etc/group` | gid 到组名、附加成员 | `id` 看到的 groups 是主组+附加组全集 |

```bash
# [任意节点]
id                                    # uid=1000(cka) gid=1000(cka) groups=1000(cka),27(sudo)...
getent passwd cka                     # 比 grep passwd 好使：走 NSS，能查到 LDAP 用户
ls -l /etc/shadow                     # -rw-r----- root:shadow，普通用户读不到
```

### 1.2 进程凭证：ruid/euid/suid 三元组

每个进程有三个 uid：**real**（谁启动了我，信号与审计用）、**effective**（内核做权限判定只看它）、**saved**（exec 前的 euid 备份，供 setuid 切回）。gid 同理另有 fsgid/egid 一组补充。

```text
# [进程凭证] 同一个普通用户，两种处境
 fork/exec 继承父进程              exec 一个 SUID root 文件
 +----------------+   -------->   +----------------+
 | ruid=1000      |               | ruid=1000      |  real: 谁创建了我
 | euid=1000      |               | euid=0         |  effective: 权限判定看这里
 | suid=1000      |               | suid=0         |  saved: 允许切回的备份
 +----------------+               +----------------+
 权限检查: open()/bind() 等系统调用失败返回 EACCES/EPERM，都拿 euid 说话
```

```bash
# [任意节点] 观察三元组
ps -o pid,uid,euid,args -p $$                        # 当前 shell：三者相同
sudo sh -c 'ps -o pid,uid,euid,args -p $$'           # sudo 提权后：三者皆 0
```

### 1.3 容器里的 uid 是真的

没有 user namespace 时，容器内 uid 与宿主机 uid 是**同一个内核数字**：容器里 uid 101 的进程，宿主机 `ps` 也显示 101。这正是 K8s `runAsNonRoot: true` 的意义——apiserver 只是拒绝"镜像默认 root 且未声明非 0"的 Pod，真正的安全收益来自"容器内不是 uid 0，逃逸后拿不到宿主机 root 特权"（[09-cks/03 章 §2](../09-cks/03-microservice-vulnerabilities.md) 的 restricted profile 把它列为必选项）。反过来，"容器里的 root"在 capabilities 未裁剪时几乎等于宿主机 root，只是被 namespace 挡住了视线——威胁模型见 [03-docker/06 章 §1](../03-docker/06-security-best-practices.md)。

## 2. sudo：受托的提权

### 2.1 sudoers 语法与 visudo

sudo 自身是 SUID root 二进制，读 `/etc/sudoers` 决定"谁可以以谁的身份跑什么"。规则四段式：

```text
# [任意节点] 语法: 谁   在哪台机器=(以谁的身份)  能跑什么
cka             ALL=(root) /usr/bin/systemctl restart kubelet
%sre            ALL=(ALL)  ALL                     # %开头是组
Cmnd_Alias NETOPS = /usr/sbin/ip, /usr/sbin/bridge
netops          ALL=(root) NETOPS                   # 命令别名聚合授权
```

```bash
# [任意节点]
sudo visudo                                 # 唯一正确的编辑方式：加锁+保存前语法检查
sudo visudo -c                              # 只校验不编辑，CI 里也用它
ls -l $(which sudo)                         # -rwsr-xr-x：SUID root（第 3 节展开）
sudo -l                                     # 我被授权了什么，排障第一步
sudo -i                                     # 完整 login shell（root 环境变量）
sudo -u nobody id                           # 以指定用户执行，不总是提 root
```

生产习惯：主文件不动，新增授权一律放 `/etc/sudoers.d/<name>`（无后缀、无 `.` 与 `#`、权限 0440——带点的文件会被 includedir **静默忽略**）。sudoers 匹配规则是"同一用户多条命中时**取最后一条**"，`@includedir` 位于主文件末尾，所以 sudoers.d 天然是覆盖位：想给某人 NOPASSWD，落一个后置文件即可生效，而不是去改主文件里的 `%sudo ALL=(ALL) ALL`。

```bash
# [任意节点] 文件: /etc/sudoers.d/appops（先 useradd -m appops）
echo 'appops ALL=(root) NOPASSWD: /usr/bin/systemctl restart demo-svc.service' | sudo tee /etc/sudoers.d/appops
sudo chmod 440 /etc/sudoers.d/appops && sudo visudo -c
```

### 2.2 sudo 的审计与边界

每次 sudo 成员资格判定与执行都留痕：`sudo journalctl -t sudo --since today`。两个边界要有意识：`Defaults env_reset` + `secure_path` 意味着 sudo 后环境变量被清洗、PATH 换成可信列表——"sudo 找不到我自己装的命令"多半是这个原因；`NOPASSWD` 方便但也把"拿到这个账号"与"拿到 root"画了等号，只给机器账号与 CI runner 这类无法交互输密码的场景。

## 3. 文件权限的三个特殊位

### 3.1 SUID/SGID/sticky 一览

普通 rwx 之外还有三个千年老位，占数值模式的千位：

| 位 | 数值 | 在文件上 | 在目录上 | 例子 |
|---|---|---|---|---|
| SUID | 4000 | exec 时 euid=文件属主 | 无意义 | `/usr/bin/passwd`、`sudo` |
| SGID | 2000 | exec 时 egid=属组 | **新文件继承目录的组** | 团队共享目录 |
| sticky | 1000 | 无意义 | 仅属主（及目录属主）能删文件 | `/tmp` 是 1777 |

`ls -l` 里显示为属主 x 位上的 `s`（有 x 时）或 `S`（无 x 时，此时 SUID 无效——常见错误：给 chmod 4644 的文件期待提权）。SGID 目录是团队协作的正解：`mkdir /srv/share && chgrp sre /srv/share && chmod 2775 /srv/share`，之后谁在里面建文件都属于 sre 组，不会再出现"我的文件你改不了"。

### 3.2 提权面清点

SUID/SGID root 的二进制是教科书级攻击面（每多一个，就多一个"有漏洞的 root"）：

```bash
# [任意节点] 两张清单，加固前后各跑一次做对比
sudo find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null
sudo getcap -r / 2>/dev/null
```

两条边界知识防误判：Linux **忽略脚本的 SUID**（`#!/bin/sh` 文件设 4755 也不会提权，内核不信任解释器的竞态窗口），所以"给 shell 脚本 chmod +s"是无效操作；容器侧则相反——SUID 被 `no-new-privileges` 一键封死（[03-docker/06 章 §4](../03-docker/06-security-best-practices.md)），这正是它比"删光 SUID 文件"更优雅的地方。

## 4. capabilities：把 root 拆成几十把钥匙

### 4.1 机制：root 特权的位图

root 的"无所不能"在内核里被拆成 capability 位图（目前四十个上下，随内核版本增减）。判定逻辑变成：open 别人的文件要 `CAP_DAC_OVERRIDE`、绑 1024 以下端口要 `CAP_NET_BIND_SERVICE`、发 raw packet 要 `CAP_NET_RAW`、`CAP_SYS_ADMIN` 则是"新 root"——容器/挂载/cgroup 大杂烩。进程有五集合（permitted 许可上限、effective 当前生效、inheritable 可继承、bounding 天花板、ambient），文件端有三集合，exec 时按固定公式合并：

```text
# [exec(2) 时的合并（简化，完整规则见 capabilities(7)）]
 文件 inheritable & 进程 inheritable ──┐
 文件 permitted   & 进程 bounding    ──┼──> 新进程 permitted
 进程 ambient（非 root 保住的钥匙）  ──┘
 文件 effective 位=1  --> 新进程 effective = permitted
 文件 effective 位=0  --> 新进程 effective = 空（root exec 有补全特例）
```

这套设计的意义：**一个进程可以只带一两把钥匙**，而不是揣着整个 root 钥匙串。它也是容器安全的底层词汇——Docker 默认给容器 14 个 capabilities 而非全部，`--cap-drop=ALL --cap-add=NET_BIND_SERVICE` 就是裁钥匙（[03-docker/06 章 §3](../03-docker/06-security-best-practices.md)）；K8s restricted profile 的 `drop ALL` + `runAsNonRoot` 则是同一思想推到极限（[09-cks/03 章 §2](../09-cks/03-microservice-vulnerabilities.md)）。

### 4.2 工具三件套

```bash
# [任意节点]
sudo apt-get install -y libcap2-bin        # getcap/setcap/capsh 都在这个包
sudo getcap -r / 2>/dev/null               # 全盘 file capabilities 清单
getcap /usr/bin/ping                       # /usr/bin/ping = cap_net_raw=ep
capsh --print | head -8                    # 当前 shell 的五集合
capsh --decode=0xa80425fb                  # 把 /proc/<pid>/status 的 CapEff 解码成名字
sysctl net.ipv4.ping_group_range           # 空 getcap 时查它: 部分新发行版改放开普通用户 ICMP
```

`getcap` 输出里的 `=ep` 是 `permitted+effective` 两位同时置位；`setcap` 的 `+`/`-` 是在现有基础上加/减。ping 是最好的活教材：早年它靠 SUID root，现在发行版普遍改发 `cap_net_raw=ep`——从"整个 root"降到"只能发 raw packet"，出漏洞时爆炸半径小了一个数量级。

```bash
# [任意节点] setcap 的写与删（改完立即生效，无需重启）
sudo setcap 'cap_net_bind_service=+ep' /usr/bin/some-server
sudo setcap -r /usr/bin/some-server        # 清除，恢复默认
```

`capsh` 还能做"先试后买"：`sudo capsh --drop=cap_net_raw -- -c 'ping -c1 127.0.0.1'`——注意如果 ping 带 file capability，这条常常**仍然成功**：进程的 bounding set 没被裁，exec 时又从文件拿回了钥匙。想真裁死要把 bounding 一起裁，这正是容器 `--cap-drop` 的实现层。

## 5. umask：新文件的反向模板

新文件基线 0666、新目录 0777，实际权限 = 基线 & ~umask（把 mask 里出现的位抠掉）：

| umask | 新文件 | 新目录 | 语义 |
|---|---|---|---|
| 022 | 644 | 755 | 服务器默认：别人只读 |
| 002 | 664 | 775 | 配合 SGID 共享目录：组可写 |
| 027 | 640 | 750 | 收紧：别人不可见内容 |
| 077 | 600 | 700 | 最严：仅自己 |

基线里文件没有 x 是刻意设计：新建文件不可执行，可执行必须显式 chmod。登录 shell 的 umask 来自 `/etc/login.defs` 的 `UMASK`（经 pam_umask，见下节）；systemd 服务则看 unit 的 `UMask=`。"守护进程写的日志组内读不了"这类问题，先看进程 umask 再谈 chmod。

```bash
# [任意节点]
umask                                     # 查当前 shell
umask 027                                 # 临时改（仅本 shell 及子进程）
systemctl show kubelet -p UMask           # 服务进程的 umask
```

## 6. PAM 概览：登录会话的插件栈

PAM（Pluggable Authentication Modules）把"认证/账号/密码/会话"四类逻辑做成可插拔栈，每个服务一个 `/etc/pam.d/<service>` 配置，sshd、login、su、sudo 各有一份：

```text
# [任意节点] /etc/pam.d/sshd 里一行的读法
 auth  required  pam_unix.so
  |       |          |
  |       |          +-- 模块(动态库/参数)
  |       +-- 控制位: required(失败也走完栈再拒绝) requisite(立即拒) sufficient(成功即够) optional
  +-- 类型: auth(你是谁) account(能不能用,如过期) password(改密) session(会话建立/拆除)
```

运维最常打交道的三个模块：`pam_limits.so`（session 类型，`/etc/security/limits.conf` 就是它的配置——第 1 章 4.2 节"limits.conf 管不住 systemd 服务"的根因在这里：**服务由 PID 1 fork 出来，不经过任何 PAM 会话栈**）；`pam_umask.so`（把 login.defs 的 umask 应用到会话）；`pam_faillock.so`（auth 类型，连续失败锁定账户，取代老教程里的 pam_tally2）。排障入口是日志：`sudo journalctl -u ssh --since "10 min ago"` 能看到 PAM 拒绝的具体模块与原因。

## 实战演练

### 演练 A：提权面体检

```bash
# [任意节点]
sudo find / -xdev -type f -perm -4000 2>/dev/null | wc -l      # SUID 数量基线(记录下来)
sudo getcap -r / 2>/dev/null
sudo -l                                                        # 我的授权面
sudo cat /etc/sudoers.d/* 2>/dev/null                          # 谁给我开的口子
```

判读要点：SUID 清单应只有发行版自带那批（passwd/sudo/mount/su...），出现自编译程序就是红旗；`sudo -l` 里的 `(root) NOPASSWD: ALL` 在生产节点上几乎总是事故预约。

### 演练 B：用 capability 替代 root 绑 80 端口

```bash
# [任意节点]
timeout 3 python3 -m http.server 80 --directory /tmp           # 失败: Permission denied(非root不能绑<1024)
PY=$(readlink -f "$(which python3)")
sudo setcap "cap_net_bind_service=+ep" "$PY"
timeout 3 python3 -m http.server 80 --directory /tmp           # 成功: Serving HTTP on 0.0.0.0 port 80
sudo setcap -r "$PY"                                           # 清理
getcap "$PY"                                                   # 确认已无输出
```

注意：给解释器设 capability 是**演示用的反模式**——等于给机器上所有 python 脚本发了这把钥匙。生产上正确做法：专用小二进制、侦听高位端口，或 `AmbientCapabilities=CAP_NET_BIND_SERVICE`（systemd unit 内做同样的拆权）。

### 演练 C：最小化 sudoers 授权

```bash
# [任意节点] 准备用户与被授权命令（沿用第 1 章的 demo-svc 或换任意无害命令）
sudo useradd -m -s /bin/bash appops
echo 'appops ALL=(root) NOPASSWD: /usr/bin/systemctl restart demo-svc.service' | sudo tee /etc/sudoers.d/appops
sudo chmod 440 /etc/sudoers.d/appops && sudo visudo -c          # parsed OK 才算数
su - appops -c 'sudo -l'                                        # 应只看到这一条
su - appops -c 'sudo systemctl restart demo-svc'                # 允许
su - appops -c 'sudo reboot'                                    # 拒绝: not allowed
sudo rm /etc/sudoers.d/appops && sudo userdel -r appops         # 清理
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 手改 sudoers 后 sudo 全体不可用 | 语法错误，sudo 拒绝解析 | 开着 root 会话用 visudo 改；`visudo -c` 校验 |
| sudoers.d 里的规则不生效 | 文件名带 `.` 或 `#` 被 includedir 忽略，或权限不是 0440 | 无后缀命名 + chmod 440 |
| NOPASSWD 加了仍要密码 | 多条规则命中取最后一条，主文件 `%sudo` 在后覆盖 | 覆盖规则放 sudoers.d（include 在末尾） |
| 给 shell 脚本 chmod +s 没效果 | 内核忽略解释型脚本的 SUID | 换编译型 helper 或 sudoers 精确授权 |
| setcap 后 cp/scp 丢失能力 | cp 重建 inode 不带 xattr | 用 `cp --preserve=xattr` 或部署后重跑 setcap |
| 给 python/grep 设了 setcap | 解释器带 cap = 所有脚本带 cap | 只给专用二进制设；发现即 `setcap -r` |
| 共享目录里互改不了文件 | 各自 umask 022 + 主组不同 | 目录 SGID(2775) + umask 002 |
| limits.conf 对服务不生效 | 服务不经 PAM 会话栈 | unit drop-in 写 `LimitNOFILE=`（第 1 章 4.2） |
| sudo 找不到自装命令 | env_reset/secure_path 清洗了 PATH | 用绝对路径或 Defaults 配 secure_path 追加 |

## 自测

1. `/etc/shadow` 是 root-only，普通用户却能改自己的密码。完整走一遍这条链。

<details><summary>答案</summary>

用户跑的是 `/usr/bin/passwd`，它带 SUID root 位：exec 时进程的 euid 从 1000 变成 0、suid 也备份为 0，内核权限判定按 euid=0 放行对 shadow 的读写；程序内部再核对 ruid 确认"你只能改你自己的条目"，改完退出进程，权限随进程消失。要点：特权跟着**进程凭证**而不是用户走，SUID 只是把"这一步操作"临时交给 root 身份执行。
</details>

2. sudoers 里同一用户先匹配到 `%sudo ALL=(ALL) ALL`（要密码），后面又匹配到自己的一条 `NOPASSWD`，最终行为是什么？为什么设计成这样？

<details><summary>答案</summary>

取最后匹配的一条：免密。sudoers 的语义是"最后规则胜出"，这让后加载的覆盖文件（sudoers.d 在 include 链末尾）天然具有更高优先级，可以在不动主文件的情况下收紧或放宽某人——等价于可追加的策略层。代价是排查"为什么行为和我想的不一样"时必须看**全部**命中规则按顺序排，只看单条会得出相反结论。
</details>

3. 容器以 `runAsUser: 101` 运行，宿主机上 `ps -o uid` 显示什么？"容器里的 root 是假的、uid 是真的"这句话怎么理解？

<details><summary>答案</summary>

显示 101。未启用 user namespace 时容器内外共享同一套内核 uid 空间，数字原样穿透。后半句：容器里的"root"只是 `/etc/passwd` 里名为 root 的映射，其真实权力=进程的 capabilities 与 namespace 可见范围，可以被裁剪（drop ALL、no-new-privileges），所以它可假；而 uid 101 就是宿主机的 101，文件系统权限按这个数字判——挂载进来的 hostPath 上如果文件属主恰是 101，容器内"无名小卒"反而能读写它。runAsNonRoot 的价值正是把进程从"全能但被隔离的 0"换成"真实且受限的非 0"。
</details>

4. ping 从 SUID root 迁移到 `cap_net_raw=ep`，收益具体是什么？为什么 `capsh --drop=cap_net_raw` 后再跑 ping 有时还能通？

<details><summary>答案</summary>

收益是把漏洞爆炸半径从"全部 root 特权"缩到"仅 raw socket"：即便 ping 被打出任意代码执行，攻击者拿到的进程 permitted 集里只有 CAP_NET_RAW。后一问：`--drop` 只动了当前 shell 的集合，exec ping 时新进程的 permitted = 文件 permitted & **进程 bounding**——bounding 没被裁，文件上的 cap_net_raw 又把钥匙发回来了。要真正禁掉，得同时裁 bounding set（容器 `--cap-drop` 就是这么实现的），这正是"看 /proc/<pid>/status 的 CapBnd 而不是只看 CapEff"的原因。
</details>

5. 新部署的服务组内互访读不了彼此的日志，umask、SGID、PAM 三者各在哪一层起作用？

<details><summary>答案</summary>

umask 决定进程**新建**文件的缺省权限（022 会抠掉组写位），是"每文件出生属性"；SGID 目录决定新文件**继承目录属组**，解决"文件属于谁的组"，配合 umask 002 才能让组内可写；PAM 决定这些策略对谁生效——登录会话的 umask 来自 pam_umask/pam_limits 走的 session 栈，而 systemd 服务不经 PAM，其 umask 与组要在 unit（`UMask=`/`Group=`）里设。三层对不上就会出现"登录手测一切正常、服务起来就 640 root:root"的经典错配。
</details>

## 延伸阅读

- capabilities(7) 官方手册：<https://man7.org/linux/man-pages/man7/capabilities.7.html>
- sudoers 官方文档：<https://www.sudo.ws/docs/man/sudoers.man/>
- Linux-PAM 官方与模块文档：<http://www.linux-pam.org/Linux-PAM-html/>
- K8s securityContext（容器侧 capabilities/runAsNonRoot）：<https://kubernetes.io/docs/tasks/configure-pod-container/security-context/>
