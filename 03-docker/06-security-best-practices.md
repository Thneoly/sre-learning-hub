# 06 · 容器安全与最佳实践：非 root、能力裁剪与镜像供应链

> 模块：03-docker ｜ 建议时长：2 小时 ｜ 关联认证：CKS-微服务漏洞最小化 / CKS-供应链安全 / CKS-集群加固（Pod Security Standards restricted 的单机版预演）

本章命令默认在**装有 Docker 的 Ubuntu 22.04/24.04 VM** 上执行，标注为 `[任意节点]`。

## 学习目标

- 能解释容器内 root 与宿主机 root 的差异：namespace 隔离了什么、没隔什么，默认 14 个 capabilities 是什么
- 能操作 `--user`、`--cap-drop`、`--security-opt no-new-privileges`、`--read-only` 组合加固一个容器，并逐项验证效果
- 能解释 rootless Docker 的原理（user namespace + subuid/subgid 映射）及其对存储路径、端口、bind mount 的限制
- 能解释默认 seccomp profile 的工作方式与 `--privileged` 关掉了哪几层防线
- 能用多阶段构建把镜像压到 10MB 级，并用 trivy / docker scout 扫描验证瘦身前后 CVE 数量变化

## 1. 威胁模型：容器内 root 到底有多危险

容器不是虚拟机。没有 user namespace 时，**容器内的 uid 0 在内核眼里就是宿主机的 uid 0**——namespace 只是隔离了"视图"（PID、网络、文件系统挂载点），syscall 权限判定仍按真实 uid/capability 走。Docker 的保护来自三件套的**裁剪**：

```
容器内 root 进程发起 syscall
        │
        ▼
┌──────────────────────────────────────────────────────┐
│ 1. capabilities：默认只留 14 个，剥夺 CAP_SYS_ADMIN 等 │
│ 2. seccomp：默认 profile 按 allowlist 过滤 syscall     │
│ 3. LSM（AppArmor/SELinux）：发行版策略再做一道限制     │
└──────────────────────────────────────────────────────┘
        │ 全部放行才到达内核
        ▼
   Linux kernel（共享攻击面：逃逸漏洞的目标）
```

Docker 默认 capability 集合（`docker run --rm ubuntu:24.04 cat /proc/self/status | grep Cap`，用 `capsh --decode=` 解码）：

```
AUDIT_WRITE, CHOWN, DAC_OVERRIDE, FOWNER, FSETID, KILL,
MKNOD, NET_BIND_SERVICE, NET_RAW, SETFCAP, SETGID,
SETPCAP, SETUID, SYS_CHROOT
```

注意被剥夺的才是重点：没有 `SYS_ADMIN`（不能 mount、不能改 cgroup）、没有 `SYS_TIME`、没有 `SYS_PTRACE`（跨进程调试）、没有 `SYS_MODULE`（不能加载内核模块）。容器安全的实操就是继续做减法。

```bash
# [任意节点] 安装解码工具并查看容器实际生效的 capabilities
sudo apt-get install -y libcap2-bin
CAPS=$(docker run --rm ubuntu:24.04 awk '/CapEff/{print $2}' /proc/self/status)
capsh --decode="$CAPS" | tr ',' '\n' | head -20
```

## 2. 非 root 运行

### 2.1 两个入口：Dockerfile `USER` 与运行参数 `--user`

```dockerfile
# [任意节点] 文件：Dockerfile 片段 —— 镜像内置用户（适合自研应用）
FROM ubuntu:24.04
RUN useradd --uid 10001 --no-create-home appuser
COPY app /app
USER 10001:10001        # 数字 uid，不依赖 /etc/passwd 也可被外部识别
ENTRYPOINT ["/app"]
```

```bash
# [任意节点] 运行时覆盖（适合第三方镜像，不改镜像）
docker run --rm --user 1000:1000 nginx:1.27-alpine id
# 预期输出：uid=1000 gid=1000（数字型 uid 的好处：镜像里没有该用户也能跑）
```

优先在镜像里固化 `USER`（镜像即契约），`--user` 用于临时覆盖与补救。

### 2.2 非 root + 监听 80 端口的矛盾

非 root 进程不能绑定 <1024 的端口，三条出路：

1. 应用改听高位端口（8080/8443），最干净。
2. 保留 `NET_BIND_SERVICE` 这一个 capability（只为一件事开一扇窗）。
3. 镜像里 `setcap cap_net_bind_service=+ep /usr/sbin/nginx`（给二进制打能力标签）。

### 2.3 与存储的交叉坑

非 root 容器写 volume/bind mount 时，目录属主是 root（首次 copy-up 的默认属主）会直接 `Permission denied`。解法：入口脚本先以 root chown 再降权（`setpriv`/`gosu`），或建卷时就设好属主。这是第 04 章存储与本章安全的连接点。

## 3. capabilities：只留必要的

```bash
# [任意节点] 全部剥夺后再按需加回——"白名单"心智模型
docker run --rm --cap-drop ALL busybox ping -c 1 -W 1 127.0.0.1
# 预期失败：ping: socket: Operation not permitted（ping 需要 NET_RAW）
docker run --rm --cap-drop ALL --cap-add NET_RAW busybox ping -c 1 -W 1 127.0.0.1
# 预期成功：1 packets received —— 精准加回一个能力即可恢复功能
```

生产模板是 **`--cap-drop ALL` 起步，缺什么补什么**。补能力前先问：能不能改应用（换高位端口、关 ICMP）？大多数 Web 服务 `--cap-drop ALL` 后零能力也能跑。

## 4. no-new-privileges：封死 setuid 提权通道

Linux 允许二进制带 setuid root 位（`passwd`、`su`、`sudo`），进程执行它们时自动获得 root 身份。这是容器内"从普通用户变 root"的合法通道，也常被滥用。`no_new_privs` 位一旦设置即不可撤销，内核从此对该进程及其所有子进程禁用 setuid/setgid/文件 capability 生效：

```bash
# [任意节点] 直接观察内核标志位
docker run --rm ubuntu:24.04 grep NoNewPrivs /proc/self/status
# 预期：NoNewPrivs:    0
docker run --rm --security-opt no-new-privileges ubuntu:24.04 grep NoNewPrivs /proc/self/status
# 预期：NoNewPrivs:    1
```

即便镜像被打进了一个恶意 setuid 后门，或应用被 RCE 后尝试执行 `/usr/bin/su` 类二进制，也无法借此提权。开销为零，默认给所有容器加上。

## 5. rootless Docker：把"守护进程去 root 化"做到底

### 5.1 原理

让 dockerd、containerd、shim、容器进程**全部**以普通用户身份运行，靠 user namespace 把容器内的 uid 映射到宿主机一段无特权 uid 区间：

```
容器内 uid:    0(root)      1        2   ...   65535
                 │          │        │          │
                 │ /etc/subuid: dockuser:231072:65536（子 uid 区间）
                 ▼          ▼        ▼          ▼
宿主机 uid:  231072     231073   231074  ...  296707   （全是无真实用户的 uid）
宿主机上运行 dockerd 的用户 dockuser 本身也不需要任何 sudo
```

于是"容器内 root 逃逸到宿主机"的下限从 root 变成一个谁也不是的 uid 231072——这正是 K8s 新版本引入 Pod 级 user namespace 的同一思想（K8s 1.30 进入 beta、1.31 起默认开启，GA 于 1.33，细节以 kubernetes.io 官方博客为准）。

### 5.2 代价与限制

| 方面 | rootful | rootless |
|---|---|---|
| 数据根目录 | `/var/lib/docker` | `~/.local/share/docker` |
| socket | `/var/run/docker.sock` | `/run/user/<uid>/docker.sock` |
| bind mount | 任意路径 | 只能挂该用户有权限访问的路径（`/home/<user>`、`/tmp` 等） |
| 监听 <1024 端口 | 可以 | 需 `sysctl net.ipv4.ip_unprivileged_port_start=0` |
| 网络后端 | iptables | slirp4netns/pasta（性能略低） |
| 前置依赖 | — | `uidmap`、`dbus-user-session`、subuid/subgid 配置 |

### 5.3 安装（选做，不影响已有 rootful Docker）

```bash
# [任意节点] 选做实验：为 rootless 单独建一个用户
sudo apt-get install -y uidmap slirp4netns dbus-user-session
sudo useradd -m -s /bin/bash dockuser 2>/dev/null || true
sudo sh -c 'echo "dockuser:231072:65536" >> /etc/subuid'
sudo sh -c 'echo "dockuser:231072:65536" >> /etc/subgid'
sudo loginctl enable-linger dockuser    # 保证用户级 systemd 实例常驻
sudo -iu dockuser bash -c 'curl -fsSL https://get.docker.com/rootless | sh'
sudo -iu dockuser systemctl --user enable --now docker
sudo -iu dockuser bash -c 'export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock; docker info --format "{{.DockerRootDir}}"'
# 预期输出 /home/dockuser/.local/share/docker —— 与 rootful 完全隔离
sudo -iu dockuser bash -c 'export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock; docker run --rm alpine id'
# 容器内 id 显示 root，但宿主机 ps 看到属主是 231072
```

## 6. seccomp：syscall 防火墙

Docker 默认为每个容器加载 moby 项目的默认 profile（https://github.com/moby/moby/blob/master/profiles/seccomp/default.json）：**allowlist 模式**，只放行约三百个"正常容器需要"的 syscall，其余返回 `EPERM`。典型被拦项：`kexec_load`（换内核）、`init_module`/`finit_module`（加载内核模块）、无特权 `bpf`、`keyctl`、`userfaultfd`；`mount` 仅放行极少数文件系统类型——完整清单以该 JSON 为准。

自定义 profile 最小示例——只封 `mkdir`，其余全放行：

```bash
# [任意节点] 写入自定义 seccomp profile：文件 /tmp/block-mkdir.json（只封 mkdir，其余放行）
cat > /tmp/block-mkdir.json <<'EOF'
{
  "defaultAction": "SCMP_ACT_ALLOW",
  "syscalls": [
    {
      "names": ["mkdir", "mkdirat"],
      "action": "SCMP_ACT_ERRNO"
    }
  ]
}
EOF
```

```bash
# [任意节点] 验证：同一命令，默认 profile 正常，自定义 profile 被拦
docker run --rm alpine mkdir /tmp/ok && echo allowed
# 预期输出 allowed
docker run --rm --security-opt seccomp=/tmp/block-mkdir.json alpine mkdir /tmp/ok
# 预期输出：mkdir: can't create directory '/tmp/ok': Operation not permitted
docker info --format '{{.SecurityOptions}}'
# 预期包含 name=seccomp,profile=default —— 确认默认开启
```

### `--privileged` 关掉了哪些防线

`--privileged` 一次性解除：全部 capabilities（含 `SYS_ADMIN`）、seccomp 过滤、LSM 限制，并挂入宿主机几乎所有设备、放开 `/sys` 与 `cgroup` 写权限。它把上面三件套全部归零，仅剩 namespace 视图隔离——除非做受控的容器内调试/驱动开发，生产环境见到就该追问。CKS 视角的等价物是 Pod Security Standards 的 `privileged` 级别，与本章一一对应：

| docker 参数 | K8s securityContext 字段（PSS restricted 要求） |
|---|---|
| `--user 1000:1000` | `runAsUser` / `runAsNonRoot: true` |
| `--cap-drop ALL` | `capabilities.drop: [ALL]` |
| `--security-opt no-new-privileges` | `allowPrivilegeEscalation: false` |
| `--security-opt seccomp=...` | `seccompProfile.type: RuntimeDefault` |
| `--read-only` | `readOnlyRootFilesystem: true` |

## 7. 镜像瘦身与最小化

镜像越小，攻击面（装了的包越多 CVE 越多）、传输与启动成本越小。三板斧：多阶段构建、最小基础镜像、锁版本。

```go
// [任意节点] 文件：~/tinyapp/main.go
package main

import (
	"fmt"
	"log"
	"net/http"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "hello from a tiny image")
	})
	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ok")
	})
	log.Fatal(http.ListenAndServe(":8080", nil))
}
```

```dockerfile
# [任意节点] 文件：~/tinyapp/Dockerfile —— 多阶段构建：编译期工具不进最终镜像
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/app .

FROM scratch
COPY --from=build /out/app /app
USER 1000:1000
EXPOSE 8080
ENTRYPOINT ["/app"]
```

```bash
# [任意节点] 构建并对比体积
cd ~/tinyapp
docker build -t tinyapp:1.0 .
docker images --format '{{.Repository}}:{{.Tag}}  {{.Size}}' | grep -E 'tinyapp|golang'
# 预期：tinyapp:1.0  约 6-8MB；golang:1.22-alpine  数百 MB（只作为构建层存在）
docker run -d --name tiny -p 18080:8080 tinyapp:1.0
curl -s http://127.0.0.1:18080/healthz          # 预期 ok
ps -o pid,user,comm -p "$(docker inspect --format '{{.State.Pid}}' tiny)"
# USER 列是 1000（scratch 无 /etc/passwd，显示数字 uid）——非 root 生效
```

其他减重手段：`apt-get install --no-install-recommends` 并同一层清理 `/var/lib/apt/lists/*`；`.dockerignore` 排除 `.git`；优先 `alpine`/`debian-slim`/distroless/scratch 这一梯队；避免 `latest`，用具体版本甚至 `@sha256:<digest>` 锁定（供应链可追溯，CKS 考点）。

## 8. 漏洞扫描：trivy 与 docker scout

```bash
# [任意节点] 安装 trivy（官方 APT 源）
sudo apt-get install -y wget apt-transport-https gnupg lsb-release
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key \
  | sudo gpg --dearmor -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" \
  | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update && sudo apt-get install -y trivy
```

```bash
# [任意节点] 三连对比：同一软件的"全家桶"与"精简"镜像
trivy image --severity HIGH,CRITICAL nginx:latest | tail -5
trivy image --severity HIGH,CRITICAL nginx:1.27-alpine | tail -5
trivy image tinyapp:1.0 | tail -5
# 预期趋势：latest 最多，alpine 明显减少，scratch 应用为 0（无 OS 包可扫）
trivy image --exit-code 1 --severity CRITICAL nginx:1.27-alpine >/dev/null; echo $?
# 预期 0（当前无 CRITICAL 则通过）——CI 门禁的写法：有 CRITICAL 即失败
trivy image --scanners secret tinyapp:1.0     # 还能顺带扫镜像里的硬编码秘密
```

`docker scout` 是官方内建方案（需 Docker Scout 插件，Docker 官方 APT 源可装 `docker-scout-plugin`；查公共镜像通常无需登录，部分高级功能需 `docker login`）：

```bash
# [任意节点]
sudo apt-get install -y docker-scout-plugin
docker scout cves nginx:1.27-alpine | head -15
```

流水线建议：构建即扫描（CI 门禁 `--exit-code 1`）、定期重扫已上线镜像（CVE 库每天更新，旧镜像会"凭空多出漏洞"）、扫的是镜像里的**包清单**，scratch 类无包数据库的镜像扫不出东西（见常见坑）。

## 9. 加固模板：一条命令汇总本章

```bash
# [任意节点] 五重加固同时生效，功能不受影响（应用只需高位端口 + 无写盘需求）
docker run -d --name hardened \
  --user 1000:1000 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --read-only \
  --tmpfs /tmp \
  -p 18081:8080 tinyapp:1.0
curl -s http://127.0.0.1:18081/healthz      # 预期 ok —— 最小化镜像 + 全套加固依旧能服务
docker run --rm --read-only alpine touch /etc/newfile
# 预期报错：read-only file system —— 根文件系统只读生效
# （hardened 基于 scratch，没有 shell，所以用上面独立容器验证 --read-only）
docker rm -f hardened tiny
```

## 实战演练

从"看清默认权限"到"全套加固后业务照常"的一条完整链，覆盖本章全部加固手段。前置：完成第 7 节的 tinyapp 镜像构建（`~/tinyapp` 目录，`docker build -t tinyapp:1.0 .`）。

**演练 1：看清默认 capability 集（对应第 1 节）**

```bash
# [任意节点]
sudo apt-get install -y libcap2-bin
CAPS=$(docker run --rm ubuntu:24.04 awk '/CapEff/{print $2}' /proc/self/status)
capsh --decode="$CAPS" | tr ',' '\n' | head -20
# 验证：只有 14 个能力，无 SYS_ADMIN / SYS_PTRACE / SYS_MODULE
```

**演练 2：逐项验证加固开关（对应第 2~4、6 节）**

```bash
# [任意节点] cap-drop 白名单模型：全删 → 缺什么补什么
docker run --rm --cap-drop ALL busybox ping -c 1 -W 1 127.0.0.1        # 失败：Operation not permitted
docker run --rm --cap-drop ALL --cap-add NET_RAW busybox ping -c 1 -W 1 127.0.0.1   # 成功

# [任意节点] no-new-privileges 内核标志位
docker run --rm ubuntu:24.04 grep NoNewPrivs /proc/self/status                          # 0
docker run --rm --security-opt no-new-privileges ubuntu:24.04 grep NoNewPrivs /proc/self/status   # 1

# [任意节点] 自定义 seccomp：封 mkdir（profile 文件见第 6 节 /tmp/block-mkdir.json）
docker run --rm alpine mkdir /tmp/ok && echo allowed                                   # 默认 profile 放行
docker run --rm --security-opt seccomp=/tmp/block-mkdir.json alpine mkdir /tmp/ok      # EPERM
```

**演练 3：最小化镜像 + 五重加固（对应第 7、9 节）**

```bash
# [任意节点]
docker run -d --name hardened \
  --user 1000:1000 --cap-drop ALL --security-opt no-new-privileges \
  --read-only --tmpfs /tmp -p 18081:8080 tinyapp:1.0
curl -s http://127.0.0.1:18081/healthz     # 验证：ok —— 全套加固下业务照常
ps -o pid,user,comm -p "$(docker inspect --format '{{.State.Pid}}' hardened)"
# 验证：USER 列是 1000（非 root 生效）
docker run --rm --read-only alpine touch /etc/newfile    # 验证：read-only file system
```

**演练 4：扫描对比验证瘦身收益（对应第 8 节）**

```bash
# [任意节点]
trivy image --severity HIGH,CRITICAL nginx:latest | tail -5        # 最多
trivy image --severity HIGH,CRITICAL nginx:1.27-alpine | tail -5   # 明显减少
trivy image tinyapp:1.0 | tail -5                                  # 0（scratch 无包清单）
docker rm -f hardened
```

完成标准：一条 `docker run` 同时带上 `--user/--cap-drop ALL/no-new-privileges/--read-only/--tmpfs` 且 healthz 返回 ok，并能解释每个开关分别挡住了哪类攻击。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 非 root 容器写 volume 报 Permission denied | volume 首次 copy-up 属主为 root | 入口脚本 chown 后降权，或预先设置卷属主 |
| `--cap-drop ALL` 后 nginx 起不来 | 监听 80 需要 NET_BIND_SERVICE | 改监听 8080，或 `--cap-add NET_BIND_SERVICE` |
| rootless 下 `docker run -v /etc/nginx:...` 失败 | bind 源路径不在该用户可访问范围 | 拷贝配置到用户目录再挂，或退回 rootful |
| trivy 对 scratch/distroless 显示 0 漏洞就认为安全 | 无 OS 包数据库，扫描器无从比对 | 0 漏洞 ≠ 无漏洞；应用依赖漏洞要扫 SBOM/锁文件 |
| `--privileged` 图省事跑 CI 容器 | seccomp/caps/LSM 全关 | 用细粒度 `--cap-add` + devices 白名单替代 |
| Dockerfile 里 `USER` 写在 `COPY --chown` 之前 | 后续指令以非 root 执行失败 | 调整顺序：先复制改属主，最后 `USER` 降权 |
| `docker info` 看不到 seccomp | 发行版/配置异常 | 确认 `SecurityOptions` 含 `name=seccomp,profile=default` |

## 自测

1. 容器内 root 与宿主机 root 的关系，为什么说"namespace 隔离视图，capability 裁剪权限"？

<details><summary>答案</summary>

namespace 决定进程能"看见"什么（PID 1、独立网络栈、受限挂载表），但 syscall 到达内核后的权限判定基于真实 uid 与 capability 位。没有 user namespace 时容器 uid 0 就是内核 uid 0，之所以危险受限，是因为 runc 创建容器时默认把 capability 集合裁到 14 个并用 seccomp/LSM 过滤。一旦 `--privileged` 或内核逃逸漏洞绕过这些裁剪，共享内核的代价立即显现——这也是 rootless/user namespace（改变 uid 映射本身）更彻底的原因。

</details>

2. `--cap-drop ALL` 之后 `ping 127.0.0.1` 失败，加回 NET_RAW 就通。如果目标是 `ping example.com`（外网域名），只加 NET_RAW 够吗？

<details><summary>答案</summary>

不够，但要分两段看：DNS 解析走 UDP 53（普通 socket，`cap-drop ALL` 也能发包）；ICMP 回显请求需要 NET_RAW（busybox ping 的 raw socket 路径）。所以加 NET_RAW 后通常能通；若仍失败，依次怀疑默认 seccomp（一般不拦 socket/sendto）、容器网络/NAT 问题、上游 DNS 不可达——排查工具用 `nslookup` 先把"解析"和"发包"两段分开验证。

</details>

3. rootless 模式下容器内 `id` 仍显示 root，这算不算没有生效？

<details><summary>答案</summary>

算生效。`id` 读的是容器 user namespace 内的 `/etc/passwd` 与 uid 映射，容器内 uid 0 经映射后对应宿主机无特权区间（如 231072）。验证方法：在宿主机 `ps -o user -p <容器进程pid>` 看到的是数字 uid 231072 而非 root。user namespace 的价值恰恰是"容器内自称 root，宿主机上是nobody"。

</details>

4. trivy 扫描 tinyapp:1.0（scratch 基底）显示 0 个漏洞，能据此写"安全合规通过"的结论吗？

<details><summary>答案</summary>

不能。scratch 镜像没有 OS 包数据库，扫描器是"对包清单查 CVE 库"的工作方式，无清单即无结果（不是无漏洞）。静态编译的 Go 二进制也可能带 CVE 的依赖（可用 `trivy fs` 扫 go.sum）。合规结论应基于：SBOM 完整性、应用依赖扫描、镜像签名（cosign）与运行时加固，而不是单点扫描零报告。

</details>

5. `no-new-privileges` 和 `--cap-drop ALL` 防的是同一件事吗？

<details><summary>答案</summary>

不同层。`--cap-drop` 削减的是**当前已拥有**的权限集合（进程起点有多强）；`no-new-privileges` 封的是**未来获得更多权限的通道**（setuid/setgid/文件 capability 生效）。两者正交：一个限起点，一个封上行通道。CKS 的 PSS restricted 同时要求 `allowPrivilegeEscalation: false` 与 `capabilities.drop: [ALL]`，正是把这两层都焊死。

</details>

## 延伸阅读

- Docker 安全总览：https://docs.docker.com/engine/security/
- 官方加固指南（非 root/caps/read-only）：https://docs.docker.com/engine/containers/run/#container-security 与 https://docs.docker.com/build/building/best-practices/
- rootless 模式手册：https://docs.docker.com/engine/security/rootless/
- 默认 seccomp profile（moby 仓库）：https://github.com/moby/moby/blob/master/profiles/seccomp/default.json
- trivy 官方文档：https://aquasecurity.github.io/trivy/latest/
- Docker Scout 文档：https://docs.docker.com/scout/
- K8s Pod Security Standards（restricted 对照）：https://kubernetes.io/docs/concepts/security/pod-security-standards/

---

上一章：[05 Docker Compose](05-compose.md) ｜ 下一章：[07 运行时生态](07-runtime-ecosystem.md) ｜ 配套练习：`labs/07-security-hardening`
