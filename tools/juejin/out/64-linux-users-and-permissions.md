---
title_juejin: 'su、sudo -i、sudo -s：生产上只有一个正确答案'
title_zhihu: '提权方式的选择就是安全边界的选择——su、sudo 与 Linux 权限机制全景'
description: 'su与sudo差异、sudoers最小授权、NOPASSWD定价、SUID/SGID/sticky、passwd写shadow、capabilities拆权、ACL补位、umask、四步排障法。'
category_id: "6809637769959178254"
tags: "后端,运维"
column_id: "7686346277555716146"
---

# su、sudo -i、sudo -s：生产上只有一个正确答案

登上一台不熟的机器，要 root 权限，你敲哪条命令？大多数人敲的是自己学会的第一条——至于 su - 和 sudo -i 差在哪、sudo -s 又是干嘛的，答不上来的人比想象中多。

这不只是记法问题。**你选的切换方式，决定接下来的环境变量、工作目录与审计留痕**——选错一种，排障时看到的现象全在骗你。

这篇把三条命令连同底下的整套机制讲完：sudoers、SUID、capabilities、ACL、umask，最后给一套 Permission denied 的定位顺序。

## 一、三条命令差在哪：一张表说清

| 命令 | 验谁的密码 | 登录 shell | 环境变量 | 工作目录 |
| --- | --- | --- | --- | --- |
| su | root 的 | 否 | 大体继承你的 | 原地 |
| su - | root 的 | 是 | root 的 | /root |
| sudo -i | 你自己的 | 是 | root 的 | /root |
| sudo -s | 你自己的 | 否 | 被 env_reset 清洗 | 原地 |

五行命令眼见为实（普通用户，站在自己家目录执行）：

```bash
pwd                # /home/cka
su -c pwd          # /home/cka   不换目录,环境大体还是你的
su - -c pwd        # /root       登录 shell,连目录一起换
sudo -s pwd        # /home/cka
sudo -i pwd        # /root
```

差别在 shell 启动方式：登录 shell 会读 /etc/profile 和 root 的 profile，环境按 root 重建；非登录 shell 不走 profile 这套（bash 交互式仍会读 .bashrc 一类 rc 文件），环境大体是你带进去什么就是什么。

各发行版细节略有出入，以你机器实测为准【从业者判断】。

sudo 还有 Defaults env_reset 与 secure_path 加持：**sudo 之后环境变量被清洗、PATH 换成可信列表**。「sudo 找不到我自己装的命令」十有八九是这个原因，用绝对路径最省事。

那为什么生产只该用 sudo？三个理由。

密码模型：su 要 root 密码，知道的人越多越不可回收；sudo 验你自己的密码，权限来自 sudoers 白名单，收权改一行配置。

授权粒度：su - 全有或全无；sudoers 能精确到「谁、在哪台机器、以谁的身份、跑哪条命令」。

审计留痕：每次 sudo 的资格判定与执行都有日志（sudo journalctl -t sudo --since today）；su 只留下「谁切过一次」，进去干了什么没人知道【从业者判断】。

反方观点也得摆出来：一台机器就你一个管理员，root 密码自己攥着，su - 一步到位不是更省事？短期是。但惯例会传染——你今天 su - 顺手，明天新人照抄，密码从此只增不收；sudo -i 给的是同一个 root shell，还多留一条借条。省下的一步，是拿密码的可回收性换的。

**su - 递的是整串钥匙，sudo 借一把、留张借条。**

## 二、内核只认数字：权限判定只看 euid

用户名只是给人看的标签，内核判定身份只用 uid/gid 数字。

三张表各管一段：/etc/passwd 存 name:x:uid:gid:home:shell，uid 0 就是 root，改名字不改身份；/etc/shadow 存密码哈希，仅 root 可读，所以改密码需要特权；/etc/group 管附加组，id 看到的 groups 是主组加附加组的全集。

每个进程有三个 uid：real（谁启动了我，信号与审计用）、effective（内核权限判定只看它）、saved（exec 前的 euid 备份，供切回），gid 同理另有一组。open()、bind() 失败返回的 EACCES/EPERM，都拿 euid 说话。

```bash
id                                            # uid=1000(cka) gid=1000(cka) groups=1000(cka),27(sudo)...
getent passwd cka                             # 比 grep passwd 好使:走 NSS,能查到 LDAP 用户
ls -l /etc/shadow                             # -rw-r----- root:shadow,普通用户读不到
ps -o pid,uid,euid,args -p $$                 # 当前 shell:三者相同
sudo sh -c 'ps -o pid,uid,euid,args -p $$'    # sudo 提权后:三者皆 0
```

容器场景这条更要紧：没有 user namespace 时，容器内外的 uid 是**同一个内核数字**——容器里 uid 101 的进程，宿主机 ps 也显示 101。

这正是 K8s runAsNonRoot: true 的意义：真正的收益不是 apiserver 挡一下，而是容器内不是 uid 0，逃逸后拿不到宿主机 root 特权。

## 三、sudoers：受托提权的合同书

sudo 自身就是个 SUID root 二进制（下一节展开），它读 /etc/sudoers 决定「谁可以以谁的身份跑什么」。规则四段式：

```text
# 语法: 谁   在哪台机器=(以谁的身份)  能跑什么
cka      ALL=(root) /usr/bin/systemctl restart kubelet
%sre     ALL=(ALL)  ALL                      # %开头是组
Cmnd_Alias NETOPS = /usr/sbin/ip, /usr/sbin/bridge
netops   ALL=(root) NETOPS                   # 命令别名聚合授权
```

编辑只有一种正确姿势：

```bash
sudo visudo          # 唯一正确的编辑方式:加锁+保存前语法检查
sudo visudo -c       # 只校验不编辑,CI 里也用它
```

**手改 sudoers 错一个字符，sudo 全体陪葬**——visudo 的存在不是仪式，是止损。

生产习惯是主文件不动，新增授权一律放 /etc/sudoers.d/<name>：文件无后缀、名字不带点与井号、权限 0440。带点的文件会被 includedir 静默忽略，你配了半天的规则根本没生效。

一个高频坑：NOPASSWD 加了仍要密码。sudoers 匹配是「同一用户多条命中取最后一条」，主文件的 %sudo 在后面命中就会盖掉你先写的那条。而 @includedir 位于主文件末尾，所以 sudoers.d 天然是覆盖位——想给某人免密，落后置文件即可，别去改主文件。

NOPASSWD 本身要定价：它把「拿到这个账号」与「拿到 root」画了等号，只该给机器账号与 CI runner 这类无法交互输密码的场景。给活人账号配 NOPASSWD: ALL，等于把 root 密码写在备注栏里【从业者判断】。

## 四、SUID/SGID/sticky：passwd 为什么能写 /etc/shadow

/etc/shadow 是 root-only，普通用户却能改自己的密码——这条链走通靠的是 SUID。

/usr/bin/passwd 带 SUID root 位：exec 它的瞬间，进程 euid 从 1000 变 0、saved 备份为 0，内核按 euid=0 放行对 shadow 的读写；程序内部再核对 ruid 确认你只能改自己的条目；进程退出，特权随进程消失。

**特权跟着进程凭证走，不跟用户走**——SUID 只是把「这一步操作」临时交给 root 身份执行。

三个特殊位占数值模式的千位：

| 位 | 数值 | 在文件上 | 在目录上 |
| --- | --- | --- | --- |
| SUID | 4000 | exec 时 euid=文件属主 | 无意义 |
| SGID | 2000 | exec 时 egid=属组 | 新文件继承目录的组 |
| sticky | 1000 | 无意义 | 仅属主（及目录属主）能删文件 |

/tmp 的 1777 就是 sticky：所有人可写，但只有文件属主删得掉自己的文件。SGID 目录是团队共享的正解：

```bash
sudo mkdir -p /srv/share && sudo chgrp sre /srv/share && sudo chmod 2775 /srv/share
# 之后谁在里面建文件都属于 sre 组,不再出现"我的文件你改不了"
```

ls -l 里它们显示为属主 x 位上的 s（有 x 时）或 S（无 x 时，此时 SUID 无效——常见错误是 chmod 4644 后期待提权）。

两条边界知识防误判：内核忽略脚本的 SUID，给 shell 脚本 chmod +s 是无效操作；容器侧则相反，用 no-new-privileges 一键封死整个机制。

SUID/SGID root 的二进制是教科书级攻击面，每多一个就多一个「有漏洞的 root」：

```bash
sudo find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null
sudo getcap -r / 2>/dev/null
```

构造典型案例：某台老机器的 SUID 清单里混着一个早年自编译的 setuid helper，多年没人认领——渗透测试拿它提权是剧本第一页。清单里出现非发行版自带的程序，就是红旗。

## 五、capabilities：把 root 钥匙串拆成几十把

「root 无所不能」在内核里其实是一张 capability 位图，四十个上下，随内核版本增减。判定逻辑变成：open 别人的文件要 CAP_DAC_OVERRIDE，绑 1024 以下端口要 CAP_NET_BIND_SERVICE，发 raw packet 要 CAP_NET_RAW。

CAP_SYS_ADMIN 则是「新 root」——容器、挂载、cgroup 大杂烩，看到它就别自称最小权限。

进程端有五集合：permitted 许可上限、effective 当前生效、inheritable 可继承、bounding 天花板、ambient。

exec 时按固定公式合并，简化版：新进程的 permitted ≈ 文件 capability 与进程 bounding 的交集，再并上 ambient。

这套设计的意义：**一个进程只带一两把钥匙，而不是揣着整个 root 钥匙串**。

ping 是最好的活教材。它早年靠 SUID root，现在发行版普遍改发 cap_net_raw=ep——出漏洞时爆炸半径从「全部 root 特权」缩到「只能发 raw packet」，小了一个数量级：

```bash
sudo apt-get install -y libcap2-bin    # getcap/setcap/capsh 都在这个包
getcap /usr/bin/ping                   # /usr/bin/ping = cap_net_raw=ep
capsh --print | head -8                # 当前 shell 的五集合
capsh --decode=0xa80425fb              # 把 /proc/<pid>/status 的 CapEff 解码成名字
```

=ep 是 permitted 与 effective 同时置位；getcap 对 ping 无输出时，查 sysctl net.ipv4.ping_group_range——部分新发行版改用直接放开普通用户 ICMP。setcap 改完立即生效，无需重启：

```bash
sudo setcap 'cap_net_bind_service=+ep' /usr/bin/some-server
sudo setcap -r /usr/bin/some-server    # 清除,恢复默认
```

一个反直觉的坑：capsh --drop=cap_net_raw 之后再跑 ping，部分机器上**仍然成功**——但别急着归因于 drop 没生效：--drop 裁的恰恰是 bounding set（裁 bounding 要 CAP_SETPCAP，一般只有 root 拿得到）。

仍能通的机器，多半是 ping 走了 ping_group_range 放开的 ping socket（前文 getcap 无输出的那批发行版），本来就不吃 CAP_NET_RAW。

bounding 是真正的天花板：只要没裁它，exec 时文件 capability 就会把钥匙发回来——这正是容器 --cap-drop 的实现层。

这也是容器安全的底层词汇：Docker 默认只发 14 个 capabilities，--cap-drop=ALL --cap-add=NET_BIND_SERVICE 就是裁钥匙；K8s restricted profile 的 drop ALL 加 runAsNonRoot 是同一思想推到极限。

部署提醒一：setcap 设的能力在 cp/scp 之后会丢——cp 重建 inode 不带 xattr，用 cp --preserve=xattr 或部署后重跑 setcap。

提醒二：给 python 这类解释器设 capability 是演示用的反模式，等于给机器上所有脚本发了这把钥匙；生产正解是专用小二进制、高位端口，或 systemd unit 里的 AmbientCapabilities=。

## 六、umask 与 ACL：一个管出生，一个管后补

新文件基线 0666、新目录 0777，实际权限 = 基线 & ~umask，把 mask 里出现的位抠掉：

| umask | 新文件 | 新目录 | 语义 |
| --- | --- | --- | --- |
| 022 | 644 | 755 | 服务器默认：别人只读 |
| 002 | 664 | 775 | 配合 SGID 共享目录：组可写 |
| 027 | 640 | 750 | 收紧：别人不可见内容 |
| 077 | 600 | 700 | 最严：仅自己 |

基线里文件没有 x 是刻意设计：新建文件不可执行，可执行必须显式 chmod。登录 shell 的 umask 来自 /etc/login.defs 经 pam_umask；systemd 服务则看 unit 的 UMask=——「守护进程日志组内读不了」，先看进程 umask 再谈 chmod。

同一个根因还解释了 limits.conf 的经典抱怨：服务由 PID 1 fork 出来、不经过任何 PAM 会话栈，limits.conf 天然管不到它——要调，写进 unit 的 drop-in。

```bash
umask                          # 查当前 shell
umask 027                      # 临时改,仅本 shell 及子进程
systemctl show kubelet -p UMask
```

传统权限有个天花板：一个文件只有一个属主、一个属组，「其他人」是全体一刀切——想把第二个用户单独加进来，传统位做不到。多数人此刻的第一反应是 chmod 777：**那是把门拆了，不是授权**。ACL 补的就是这块（工具在 acl 包：sudo apt-get install -y acl）：

```bash
getfacl /srv/share/report.md                     # 查 ACL 账本
sudo setfacl -m u:cka:rw /srv/share/report.md    # 给第二个用户单独授权
ls -l /srv/share/report.md                       # 权限位末尾多了个 +
sudo setfacl -x u:cka /srv/share/report.md       # 移除单条
sudo setfacl -b /srv/share/report.md             # 整本清空
```

使用要点一：mask 是 ACL 里组权限的天花板【从业者判断】——随手 chmod 改组位会顺带压低 mask，把已授权的 ACL 一起收紧。权限「莫名变小」，先 getfacl 看 mask。

要点二：目录上设 default ACL（setfacl -d -m g:sre:rwx /srv/share）能让新建文件自动带授权，与 SGID 配 umask 002 是同一件事的两种写法——选一种用到底，别两套叠加【从业者判断】。

umask 决定文件出生时的权限，**ACL 决定出生之后还能给谁开**。

## 七、Permission denied 的四步定位

碰到 Permission denied，按固定顺序走，别猜：

```bash
id                                    # 第一步:我是谁,组全不全(漏附加组是常因)
sudo -l                               # 第二步:我被授权了什么
getfacl /srv/share/app/logs/app.log   # 第三步:有没有 ACL/mask 在压权限
namei -l /srv/share/app/logs/app.log  # 第四步:逐级看路径上每一层的权限
```

namei -l 把路径上每层目录的属主、属组、权限位逐行列出。经验之谈：**病根常不在最后一层文件，而在中间某层目录少了 x**——目录没有 x 位你连「穿过」它都做不到，更别说读到底下的文件【从业者判断】。

进程侧再补一枪 ps -o pid,uid,euid,args -p <pid>，确认这个进程到底以谁的身份在跑。

## 教训

1. **su - 与 sudo -i 行为像、性质不像**：一个共享 root 密码，一个受托且留痕
2. **sudoers 只用 visudo 改**：新增落 sudoers.d，多条命中取最后一条
3. **NOPASSWD 有价**：只卖给无法交互输密码的机器账号
4. **SUID/SGID 是躺在硬盘上的提权面**：清单里出现非发行版程序就是红旗
5. **capabilities 把 root 拆成钥匙**：裁权要连 bounding 一起裁才算数
6. **777 不是授权，是把门拆了**：出生权限交给 umask，后补授权走 ACL

## 现在就做：一次提权面体检

四条命令，加固前后各跑一次做对比：

```bash
sudo find / -xdev -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | wc -l   # SUID/SGID 基线
sudo getcap -r / 2>/dev/null                     # file capabilities 清单
sudo -l                                          # 我的授权面
sudo cat /etc/sudoers.d/* 2>/dev/null            # 谁给我开的口子
```

判读：SUID 清单应只有发行版自带那批（passwd/sudo/mount/su...）；sudo -l 里的 (root) NOPASSWD: ALL 在生产节点上几乎总是事故预约。

留个话头：把第一条和第三条跑完，评论区报两个数——你机器上的 SUID/SGID 数量，和你 sudo -l 里最宽的那条授权。如果后者是 NOPASSWD 开头的，今晚就把它收窄到具体命令。

这套提权面体检、capability 替代 root 绑端口的完整演练，在我的学习仓库：GitHub 搜 sre-learning-hub。

命令以 Ubuntu（apt 系）为准，RHEL 系替换包管理器即可。
