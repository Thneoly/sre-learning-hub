# Lab 07 · 解答与讲解

> 前置：Ubuntu VM 已装 Docker；宿主机装有 `libcap2-bin`（提供 `capsh`，`sudo apt-get install -y libcap2-bin`，仅解码演示用）。

## 第 1 步：baseline——默认有多松

```bash
# [Ubuntu VM]
docker run -d --name lab07-base alpine sleep infinity
docker exec lab07-base sh -c 'grep -E "Cap(Inh|Prm|Eff|Bnd)" /proc/self/status'
CAPEFF=$(docker exec lab07-base sh -c 'grep CapEff /proc/self/status' | awk '{print $2}')
echo "$CAPEFF"
# 在宿主机解码（需要 libcap2-bin）：
capsh --decode="$CAPEFF"
```

预期 `CapEff` 形如 `00000000a80425fb`，解码出 Docker 默认的 14 项 capability：

```
0x00000000a80425fb=cap_chown,cap_dac_override,cap_fowner,cap_fsetid,cap_kill,
cap_setgid,cap_setuid,cap_setpcap,cap_net_bind_service,cap_net_raw,cap_sys_chroot,
cap_mknod,cap_audit_write,cap_setfcap
```

关键认知：**容器里的 root 不是真 root**——它没有 `SYS_ADMIN`（mount）、`NET_ADMIN`（改网络）、`SYS_TIME` 等高危项；但 `SETUID`/`SETGID`（配合镜像里的 setuid 文件提权）、`NET_RAW`（伪造包/嗅探）仍是现实攻击面。加固思路就是把不需要的从默认集合里再删掉。

位图字段速查：

| 字段 | 含义 |
|---|---|
| CapInh | inheritable，exec 时可从父继承的集合 |
| CapPrm | permitted，当前允许持有上限 |
| CapEff | effective，**当前真正生效**（检查权限看它） |
| CapBnd | bounding set，exec 后也突破不了的天花板 |

`--cap-drop ALL` 会把 bounding set 一并清空，所以新 exec 进来的进程也无法再捡回任何 capability。

## 第 2 步：--cap-drop ALL

```bash
# [Ubuntu VM]
docker run -d --name lab07-nocap --cap-drop ALL alpine sleep infinity
docker exec lab07-nocap sh -c 'grep CapEff /proc/self/status'
docker exec lab07-nocap sh -c 'mkdir -p /mnt && mount -t tmpfs none /mnt' 2>&1 | head -1
docker exec lab07-nocap ping -c 1 -W 2 127.0.0.1 2>&1 | head -1 || true
```

预期：

```
CapEff:     0000000000000000
mount: permission denied       （无 SYS_ADMIN）
```

`ping 127.0.0.1` 能否成功取决于宿主机 `net.ipv4.ping_group_range`：本例宿主机为 `0 2147483647`（全放开，允许无特权 ICMP ping socket），ping 仍通；较老的默认值 `1 0` 下才会 `ping: permission denied`。所以 cap-drop 的可靠证据是 **CapEff 位图与 mount 被拒**，ping 只作参考。

如果业务确实需要某一项，最小化放行而不是放弃加固：

```bash
# [Ubuntu VM]
docker run --rm --cap-drop ALL --cap-add NET_BIND_SERVICE alpine \
  sh -c 'echo "只补回绑定低端口的能力"'
```

## 第 3 步：非 root 用户

```bash
# [Ubuntu VM]
docker run -d --name lab07-noroot --user 1000:1000 alpine sleep infinity
docker exec lab07-noroot id
docker exec lab07-noroot sh -c 'touch /forbidden.txt' 2>&1 | head -1
```

预期：

```
uid=1000 gid=1000 groups=1000
touch: /forbidden.txt: Permission denied   （rootfs 属主 root，uid 1000 无 w 位）
```

两种落法：运行期 `--user 1000:1000`（本实验），或镜像内固化（Dockerfile 里 `USER appuser`，更推荐——镜像自带声明，K8s `runAsNonRoot` 校验的就是镜像 USER 或 securityContext）。注意 uid 1000 在 alpine 里没有对应账户名，`id` 只显示数字——这是正常的，内核鉴权认 uid 不认名字。

## 第 4 步：no-new-privileges 封死 setuid 通道

在 `--rm` 容器里自制一枚 setuid 的 `cat`，再用 `setpriv` 降到 uid 1000 去读只有 root 能读的文件（`setpriv` 做"切到普通用户"这一步不需要特权通道，让对比只剩 setuid 一个变量）：

```bash
# [Ubuntu VM]
DEMO='cp /bin/cat /tmp/rootcat && chmod 4755 /tmp/rootcat && echo secret-content > /root/secret.txt && chmod 600 /root/secret.txt && setpriv --reuid=1000 --regid=1000 --clear-groups /tmp/rootcat /root/secret.txt'

docker run --rm ubuntu:24.04 sh -c "$DEMO" 2>&1 | tail -1
docker run --rm --security-opt no-new-privileges ubuntu:24.04 sh -c "$DEMO" 2>&1 | tail -1
```

典型输出对比：

```
# 第一条（无 NNP）：setuid 位生效，cat 以 euid=0 运行，读到 root 专属文件
secret-content

# 第二条（有 NNP）：内核忽略 setuid 位，cat 仍是 uid 1000
/tmp/rootcat: /root/secret.txt: Permission denied
```

> 为什么不用 `alpine su root -c id`：alpine 的 `/bin/su` 只是指向 busybox 的软链，而 busybox **不带 setuid 位**（`ls -l /bin/busybox` 是 755）——就算 root 手工补上 `chmod u+s`，busybox 也会为 shell applet 主动丢弃特权。所以在 alpine 上这个命令有无 NNP 都是同一句 `su: must be suid to work properly`，演示不出对比。ubuntu 镜像里造 setuid 副本才是可靠做法。

原理：`no-new-privileges` 置位内核 `no_new_privs` 标志后，该进程及所有后代 execve 时不再应用文件 setuid/setgid 位与 file capabilities，特权只降不升。镜像里一枚被做手脚的 setuid 二进制（历史 CVE： Dirty Cow 场景下的利用放大）从此失去意义。

## 第 5 步：整合容器 lab07-hard

```bash
# [Ubuntu VM]
docker run -d --name lab07-hard \
  --user 1000:1000 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --read-only \
  --tmpfs /tmp:rw,size=16m,mode=1777 \
  alpine sleep infinity
```

逐项验证：

```bash
# [Ubuntu VM]
docker exec lab07-hard id -u                                   # 1000
docker exec lab07-hard sh -c 'grep CapEff /proc/self/status'   # 0000000000000000
docker exec lab07-hard sh -c 'touch /etc/probe' 2>&1 | head -1 # Read-only file system
docker exec lab07-hard sh -c 'echo writable > /tmp/ok && cat /tmp/ok'   # writable
```

预期：

```
1000
CapEff:     0000000000000000
touch: /etc/probe: Read-only file system
writable
```

四开关 → K8s securityContext 对照表（CKS 直接考点）：

| Docker | Pod securityContext |
|---|---|
| `--user 1000:1000` | `runAsUser: 1000` / `runAsGroup: 1000`（或 `runAsNonRoot: true`） |
| `--cap-drop ALL` | `containers[].securityContext.capabilities.drop: ["ALL"]` |
| `--security-opt no-new-privileges` | `allowPrivilegeEscalation: false` |
| `--read-only` | `readOnlyRootFilesystem: true` |
| `--tmpfs /tmp` | emptyDir volume 挂到 /tmp |
| `--privileged`（反面教材） | `privileged: true`（等于放弃全部隔离，仅在嵌套 Docker/内核调试时用） |

## 第 6 步：终态证据（inspect 核对）

```bash
# [Ubuntu VM]
docker inspect lab07-hard --format \
  'User={{.Config.User}}
SecurityOpt={{json .HostConfig.SecurityOpt}}
CapDrop={{json .HostConfig.CapDrop}} CapAdd={{json .HostConfig.CapAdd}}
ReadonlyRootfs={{.HostConfig.ReadonlyRootfs}}
Privileged={{.HostConfig.Privileged}}'
```

预期输出：

```
User=1000:1000
SecurityOpt=["no-new-privileges:true"]
CapDrop=["ALL"] CapAdd=null
ReadonlyRootfs=true
Privileged=false
```

这一段输出就是安全审计报告里"最小权限已落地"的证据链：声明（Config/HostConfig）与运行时（exec id / CapEff）两边对得上。

## 判分脚本结果

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

预期输出：

```
PASS: lab07-base 运行中且 CapEff 非零
PASS: lab07-nocap 运行中且 CapEff 为 0000000000000000
PASS: lab07-noroot 运行中且 id -u 为 1000
PASS: lab07-hard 运行中且含 no-new-privileges
PASS: lab07-hard CapDrop=ALL 且 CapAdd 为空
PASS: lab07-hard ReadonlyRootfs 为 true
PASS: lab07-hard id -u 为 1000
PASS: lab07-hard 的 /tmp 可写（tmpfs 生效）

SCORE: 8/8
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| cap-drop ALL 后应用起不来 | 应用确实依赖某项 capability（如绑 80 端口） | 逐项补 `--cap-add NET_BIND_SERVICE`，或改高位端口 |
| `capsh: command not found` | 宿主机没装 libcap2-bin | `sudo apt-get install -y libcap2-bin`（只影响解码演示） |
| `--user 1000` 后日志写不了 | 应用要写 /var/log 等属 root 的路径 | `--tmpfs` 或 volume 划出可写区；或 chown 镜像内目录 |
| NNP 后某些 init 脚本失败 | 脚本靠 setuid 工具降权/提权 | 改用 `su-exec`/`gosu` 在 entrypoint 直接切换（它们不依赖 setuid） |
| read-only 下 /tmp 报错 | 忘了给可写挂载 | `--tmpfs /tmp:rw,size=16m,mode=1777` |
| ping 偶尔在 cap-drop 后还能用 | 镜像/内核放开 ping_group_range | 属正常，以 CapEff 位图为准而非单一命令 |

## 清理（保留终态供复查，彻底清理用）

```bash
# [Ubuntu VM]
# docker rm -f lab07-base lab07-nocap lab07-noroot lab07-hard
```

## 延伸阅读

- Docker runtime security 选项：https://docs.docker.com/engine/security/
- capabilities(7) 手册：https://man7.org/linux/man-pages/man7/capabilities.7.html
- Kubernetes Pod SecurityContext：https://kubernetes.io/docs/tasks/configure-pod-container/security-context/
