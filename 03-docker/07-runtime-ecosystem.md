# 07 · 运行时生态：dockerd、containerd、runc 与 CRI

> 模块：03-docker ｜ 建议时长：1.5 小时 ｜ 关联认证：CKA-集群架构 / CKA-故障排查（crictl 是考场必备）/ CKS-运行时安全（RuntimeClass 的地基）

本章命令分两类环境：**装有 Docker 的 Ubuntu VM** 标注为 `[任意节点]`（重启 daemon 的实验不要放在 kubeadm 节点上做）；**kubeadm 集群（单 master + Calico）** 标注为 `[master]`。

## 学习目标

- 能画出并解释 `docker CLI → dockerd → containerd → containerd-shim → runc → 容器进程` 的调用链，说出 shim 存在的三个理由
- 能解释 CRI 的定位、dockershim 为什么在 Kubernetes 1.24 被移除、cri-dockerd 扮演什么角色
- 能解释 OCI image spec 与 runtime spec 各自定义了什么，为什么分层标准让运行时可替换
- 能在 kubeadm 节点上用 crictl 与 ctr 观察同一批容器的两种视角，并知道排障时选哪个
- 能区分 docker / nerdctl / crictl / ctr 四个 CLI 的定位与典型误用

## 1. 调用链全景：为什么叠了这么多层

```
 用户面
+-------------------+      +--------------------+
| docker CLI        |      | kubectl            |
+---------+---------+      +----------+---------+
          | REST                     | （经由 API server→kubelet，不直连运行时）
          | /var/run/docker.sock     |
          v                          v
+-------------------+      +--------------------+
| dockerd           |      | kubelet            |
| 构建/卷/网络(CNM)/API|    +----------+---------+
+---------+---------+                 |
          | gRPC                      | CRI (gRPC, RuntimeService+ImageService)
          v                           v
      +------------------------------------------+
      | containerd（systemd 服务，独立于 dockerd）  |
      |  生命周期/快照(overlay2)/镜像拉取/CRI 插件   |
      +------+-----------------------------+------+
             | 每容器一个                     | 每容器一个
             v                             v
      +--------------+              +--------------+
      | containerd-  |              | containerd-  |
      | shim-runc-v2 |              | shim-runc-v2 |
      +------+-------+              +------+-------+
             | fork+exec                   | fork+exec
             v                            v
      +---------+                  +---------+
      |  runc   |                  |  runc   |     OCI runtime：创建容器后即退出
      +----+----+                  +----+----+
           |                            |
           v                            v
      容器进程（父进程是 shim，不是 dockerd/containerd）
```

各层职责（自下而上）：

- **runc**：OCI runtime 参考实现。输入一份 `config.json`，用 clone/namespace/cgroup/capabilities 把容器进程拉起来，**容器启动完成后 runc 进程退出**。只管"创建这一个进程"，不管镜像、不管网络、不管重启。
- **containerd-shim**：每个容器一个，是容器进程的真正父进程。存在的理由：
  1. **解耦 daemon 重启**：dockerd/containerd 崩溃或升级时，容器进程挂在 shim 下继续跑，daemon 回来后重新接管，容器无感。
  2. **收殓容器进程**：作为 PID 1 的父进程收割孤儿、转发信号（`docker stop` 的 SIGTERM/SIGKILL 由 shim 送达）、记录并上报 exit code。
  3. **持有 stdio 与句柄**：日志、终端的文件描述符由 shim 持有，daemon 不必为每个容器长期占用资源，也让 runc 可以"即建即退"的无 daemon 化成为可能。
- **containerd**：容器生命周期管理、镜像分发、snapshotter（把镜像层组织成 overlay2）。自带 CRI 插件，是 Kubernetes 的标准运行时。
- **dockerd**：面向开发者的产品层——REST API、`docker build`（BuildKit）、volume、CNM 网络模型、认证。它自己不创建容器进程，只是 containerd 的客户端。

在 Docker VM 上亲眼看到这条链：

```bash
# [任意节点] 顺着 PPid 向上爬
docker run -d --name chain nginx:1.27-alpine
PID=$(docker inspect --format '{{.State.Pid}}' chain)
ps -o pid,ppid,user,comm -p "$PID"                 # 容器进程 nginx
PP=$(ps -o ppid= -p "$PID" | tr -d ' ')
ps -o pid,ppid,user,comm -p "$PP"                  # 预期 comm=containerd-shim
ps -o pid,ppid,user,comm -p "$(ps -o ppid= -p "$PP" | tr -d ' ')"   # 预期 comm=containerd
ps -ef | grep [c]ontainerd-shim | head -2
# 注意参数里有 -namespace moby：Docker 把容器放在 containerd 的 moby 命名空间
docker rm -f chain
```

shim 解耦的公开验证——`live-restore`（让 dockerd 重启不杀容器）：

```bash
# [任意节点] 开启 live-restore（若 /etc/docker/daemon.json 已有内容，请手动合并而不是覆盖）
docker run -d --name survivor nginx:1.27-alpine
sudo tee /etc/docker/daemon.json <<'EOF'
{ "live-restore": true }
EOF
sudo systemctl restart docker
docker ps --filter name=survivor
# 预期 STATUS 是 Up（创建时间早于 daemon 重启）——容器进程从未死过，只是换了条"管理通道"
docker rm -f survivor
```

不开 `live-restore`（默认）时，重启 docker 会停掉容器再按 restart policy 拉起，产生中断。注意此实验仅限纯 Docker VM，不要在 kubeadm 节点上改 daemon.json。

## 2. CRI 与 dockershim 的历史

| 时间 | 事件 |
|---|---|
| 2013 | Docker 发布，容器事实标准形成 |
| 2014.06 | Kubernetes 开源，kubelet **硬编码直连** Docker API |
| 2015.06 | OCI 成立：runtime-spec（源自 libcontainer/runc）与后续 image-spec 标准化 |
| 2016.12 | Kubernetes 1.5 引入 **CRI**（gRPC 接口），kubelet 只对 CRI 说话；Docker 没有 CRI，于是 kubelet 内置 **dockershim** 做翻译层 |
| 2017–2018 | containerd 捐给 CNCF，1.1 起内置 CRI 插件；CRI-O 1.0 发布，"原生 CRI 运行时"成熟 |
| 2020.12 | Kubernetes 1.20 宣布弃用 dockershim |
| 2022.05 | Kubernetes 1.24 **移除 dockershim**；社区出现 cri-dockerd 补位 |

CRI（Container Runtime Interface）是一组 gRPC 服务：`RuntimeService`（PodSandbox 与容器的生命周期、exec/attach、stats）+ `ImageService`（拉取/列举/删除镜像）。kubelet 是客户端，任何实现 CRI 的运行时都能接入。

dockershim 被移除的原因，看这两条链就懂：

```
kubelet ──CRI──> dockershim(在 kubelet 里) ──Docker API──> dockerd ──> containerd ──> shim ──> runc
                   ↑ 翻译层                     ↑ 额外一整层 daemon（有自己的镜像/卷/网络概念）

kubelet ──CRI──> containerd(cri 插件) ──> containerd-shim ──> runc
                  ↑ 少两层，且 PodSandbox、镜像 GC、runtime handler 等 CRI 语义原生支持
```

具体代价：dockershim 要把 CRI 的 PodSandbox 概念硬套到 Docker 的容器+网络上，映射永远别扭；Docker 与 Kubernetes 各自维护一份容器状态容易漂移；Kubernetes 每加一个运行时特性（镜像 GC 策略、Pod 资源上报、RuntimeClass）都要 dockershim 跟着改，维护成本压垮收益。

两个高频误会先澄清：

- **"1.24 之后不能用 Docker 了？"**——不能的是 dockershim 这条链。`docker build` 产出的是 OCI 标准镜像，任何 registry + 任何 CRI 运行时照常拉起。开发机 Docker 照用，节点上换成 containerd/CRI-O 而已。
- **确实离不开 Docker 的遗留环境**可以装 cri-dockerd（独立进程充当 CRI→Docker 翻译层），但那只是把 dockershim 从 kubelet 里搬到外面，链路照样长，仅作过渡。

## 3. OCI：让这一切可替换的两份标准

OCI（Open Container Initiative）定义两份规范，把"镜像格式"和"容器怎么跑"拆开：

- **image spec**：镜像 = 按 content-addressable digest 组织的 manifest + config + layers，配 registry 的分发协议。docker save 的 tar 是 Docker 自有打包格式（内含 manifest.json），registry 里流转的才是标准 OCI 布局，两者可互转。亲手解包看一眼：

```bash
# [任意节点]
docker save nginx:1.27-alpine -o /tmp/nginx.tar
mkdir -p /tmp/img && tar -xf /tmp/nginx.tar -C /tmp/img
ls /tmp/img | head
# manifest.json、若干 <hash>.json（config）、若干 <hash>/layer.tar（层）
cat /tmp/img/manifest.json
# [{"Config":"<hash>.json","RepoTags":["nginx:1.27-alpine"],"Layers":["<hash>/layer.tar",...]}]
# 每个层一个 tar，config 描述入口/env/层顺序——这就是"分层镜像"的物理形态
```

- **runtime spec**：一份 `config.json`（rootfs 路径、process、mounts、linux.namespaces/cgroups/capabilities/seccomp）+ 容器生命周期状态机。runc 是参考实现，crun（C 写、更快）、runsc（gVisor，用户态内核）、kata（轻量 VM）都实现同一份规范：

```
create ──> start ──> running ──> stop
   │         │         │
 created   started   stopped   （runtime spec 定义的状态与操作；K8s 的 RuntimeClass
                                就是让 Pod 指定用哪种 runtime 实现，见 CKS 实验室）
```

分层的价值：Kubernetes 只认 CRI，CRI 后面可以接 containerd/CRI-O/Docker(经 cri-dockerd)；containerd 只认 OCI runtime，后面可以换 runc/crun/runsc/kata。任何一层被替换，上下游无需改代码——这是"生态"而非"产品"的根本原因。

## 4. 四个 CLI：docker / nerdctl / crictl / ctr

| CLI | 对谁说话 | 定位 | 典型场景 | 注意 |
|---|---|---|---|---|
| `docker` | dockerd | 面向开发者的产品级工具 | 本地开发、构建、调试 | kubeadm 节点上通常**不存在** dockerd，别指望它 |
| `nerdctl` | containerd（原生 API） | "给 containerd 的 docker"，命令体验几乎一致 | 裸 containerd 主机上的开发调试 | 默认 namespace 是 default，不碰 kubelet 的 k8s.io |
| `crictl` | CRI 接口（containerd/CRI-O 的 CRI socket） | 站在 **kubelet 同一视角**的排障工具 | K8s 节点查 Pod/容器/镜像/日志 | 只应观察与调试，不要拿它"手工运维"容器 |
| `ctr` | containerd（原生 API） | containerd 官方低层调试客户端 | 深挖 containerd 内部（namespace、snapshot、连接） | 语法原始、无 CRI 语义，容易误操作 |

一句话选型：**开发机用 docker；K8s 节点排障用 crictl；crictl 看不到的底层细节用 ctr；纯 containerd 环境的开发体验用 nerdctl。**

在 kubeadm 集群上实战对比（cri-tools 版本请替换为与集群匹配的版本，下例以 1.31.x 为准）：

```bash
# [master] 若未安装 crictl
curl -LO https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.31.0/crictl-v1.31.0-linux-amd64.tar.gz
sudo tar -C /usr/local/bin -xzf crictl-v1.31.0-linux-amd64.tar.gz
sudo crictl config runtime-endpoint unix:///run/containerd/containerd.sock
```

```bash
# [master] crictl 视角：kubelet 的世界观（Pod 沙箱与业务容器分离）
sudo crictl pods -o wide | head -5          # PodSandbox，多含 pause 容器
sudo crictl ps | head -5                    # 业务容器（State/镜像名一眼可读）
sudo crictl images | head -5
sudo crictl logs "$(sudo crictl ps -q --name coredns | head -1)" | head -5
```

```bash
# [master] ctr 视角：containerd 的内部账本（k8s.io 命名空间，能看到 pause 容器本体）
sudo ctr -n k8s.io containers list | head -5
sudo ctr -n k8s.io images list | head -5
ps -ef | grep [c]ontainerd-shim | head -3   # 参数里是 -namespace k8s.io（对比 Docker 的 moby）
```

对照要点：`crictl ps` 列出的是 CRI 语义的"应用容器"，pause（sandbox）被折叠进 `crictl pods`；而 `ctr -n k8s.io containers list` 会把 pause 和应用容器**混在一张表里**，因为它只认 containerd 对象、不认识 Pod。这正是"crictl 优先"的原因——排障要的是与 kubelet 一致的心智模型。

```bash
# [任意节点] nerdctl 参考：在装有 containerd 的机器上获得 docker 般体验（可选安装）
curl -LO https://github.com/containerd/nerdctl/releases/download/v1.7.7/nerdctl-1.7.7-linux-amd64.tar.gz
sudo tar -C /usr/local/bin -xzf nerdctl-1.7.7-linux-amd64.tar.gz nerdctl
nerdctl --namespace k8s.io ps    # 与 ctr 同源，但输出对人类友好得多
```

无论用哪个：**k8s.io 命名空间属于 kubelet**。手工在里面拉起/删除容器，很快会被 kubelet 的垃圾回收/调谐回收，白忙一场还可能误删。

## 5. 接下来 K8s 章节如何衔接

Docker 模块到本章收口，四个概念地图直接平移到 02 模块：

- **调用链位置**：`kubelet → CRI → containerd → shim → runc` 将出现在架构图里（02-02）。你已在本章用 `crictl pods`/`crictl ps` 亲眼看过它的两个视角，考场上排障的三板斧就是 `crictl ps` / `crictl logs` / `crictl images`。
- **Pod 的底层形态**：`crictl pods` 里的 PodSandbox 就是"pause 容器 + 共享 network namespace"的正式表达——02-03 Pods 深入会从它讲到容器为什么天然共享网络栈。
- **镜像体系**：OCI image spec 的 manifest/layers 直接对接 02-01 的"为什么 K8s 能拉 Docker 构建的镜像"；供应链安全（CKS 04-04）的镜像签名、digest 锁定也建立在这套 content-addressable 结构上。
- **运行时可替换**：runtime spec 的状态机与实现多样性是 CKS RuntimeClass 实验（gVisor/Kata）的前置知识（07-cks/labs/05-runtimeclass）。
- **概念迁移表**：compose 服务 → Deployment+Service（05 章映射表）、volume → PV/PVC（04 章）、CNM 网络模型 → CNI 插件体系（02-10）。

至此，容器层的"为什么"已经铺完：镜像是分层的 OCI 工件、进程是 namespace+cgroup 的受裁剪视图、编排是声明式期望状态。02 模块开始，把"单机 Docker"换算成"集群 API 对象"。

## 实战演练

两类环境各一条链：Docker VM 上验证调用链与 daemon 解耦，kubeadm 集群上对比 crictl/ctr 两种视角。

**演练 1：顺着 PPid 爬调用链（对应第 1 节）**

```bash
# [任意节点]
docker run -d --name chain nginx:1.27-alpine
PID=$(docker inspect --format '{{.State.Pid}}' chain)
ps -o pid,ppid,user,comm -p "$PID"      # 容器进程 nginx
ps -o pid,ppid,user,comm -p "$(ps -o ppid= -p "$PID" | tr -d ' ')"     # comm=containerd-shim
ps -o pid,ppid,user,comm -p "$(ps -o ppid= -p $(ps -o ppid= -p "$PID" | tr -d ' ') | tr -d ' ')"   # comm=containerd
ps -ef | grep [c]ontainerd-shim | head -2   # 参数含 -namespace moby（Docker 的 containerd 命名空间）
```

**演练 2：live-restore 验证 shim 解耦（对应第 1 节，仅限纯 Docker VM）**

```bash
# [任意节点]
docker run -d --name survivor nginx:1.27-alpine
sudo tee /etc/docker/daemon.json <<'EOF'
{ "live-restore": true }
EOF
sudo systemctl restart docker
docker ps --filter name=survivor    # 验证：STATUS 仍 Up，容器进程未死
docker rm -f survivor chain
```

**演练 3：解包镜像看 OCI 物理形态（对应第 3 节）**

```bash
# [任意节点]
docker save nginx:1.27-alpine -o /tmp/nginx.tar
mkdir -p /tmp/img && tar -xf /tmp/nginx.tar -C /tmp/img
cat /tmp/img/manifest.json
# 验证：Config + RepoTags + Layers[] —— 分层镜像的物理形态
```

**演练 4：crictl 与 ctr 的两种视角（对应第 4 节）**

```bash
# [master] crictl：与 kubelet 一致的世界观
sudo crictl pods -o wide | head -5      # PodSandbox（pause 容器在这里）
sudo crictl ps | head -5                # 业务容器，不含 pause
sudo crictl images | head -5

# [master] ctr：containerd 内部账本
sudo ctr -n k8s.io containers list | head -5   # pause 与业务容器混在一张表
ps -ef | grep [c]ontainerd-shim | head -3      # 参数是 -namespace k8s.io（对比 moby）
```

完成标准：能画出从 docker CLI / kubectl 两条入口到容器进程的完整调用链，并说出 crictl 与 ctr 在同一节点上看到的容器列表差在哪、为什么。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `crictl ps` 报 `runtime endpoint connect: no such file or directory` | 未配置 CRI socket | `sudo crictl config runtime-endpoint unix:///run/containerd/containerd.sock` |
| `ctr containers list` 在 K8s 节点上为空 | 默认 namespace 是 default，不是 k8s.io | `sudo ctr -n k8s.io containers list` |
| 在 K8s 节点上找不到 `docker` 命令 | 1.24+ kubeadm 默认装 containerd，根本没装 dockerd | 用 crictl；确需 Docker 工具链另装并走 cri-dockerd（不推荐） |
| 用 ctr/nerdctl 在 k8s.io 里手工建容器后消失 | kubelet 按 CRI 状态对账并做垃圾回收 | 调试容器放到 default namespace，或直接用 Pod |
| 以为重启 containerd 会重启所有 Pod | shim 是容器进程父进程，containerd 重启不杀容器 | 属正常现象；但 CRI 连接会抖动，操作仍应 drain 后进行 |
| CI 里 `docker build` 的镜像担心 1.24 后不可用 | 混淆"运行时链路"与"镜像格式" | 镜像是 OCI 标准，照常推 registry、照常被 containerd 拉起 |
| `docker info` 正常但 `nerdctl ps` 报连接失败 | nerdctl 直连 containerd socket，与 dockerd 无关 | 确认 containerd socket 路径与 namespace |

## 自测

1. runc 在容器启动后就退出了，容器进程的父进程是谁？这个设计解决了什么问题？shim 崩溃会怎样？

<details><summary>答案</summary>

父进程是 containerd-shim。设计动机：容器生命周期不该绑定任何 daemon 进程——runc "即建即退"避免常驻进程成为单点，shim 以极小的职责面（信号转发、收尸、exit code 上报、stdio 持有）常驻。shim 崩溃时容器进程失去父进程，被 PID 1 收养通常仍在运行，但 stop/日志/状态上报会失灵，containerd 检测到后会按策略清理并让 kubelet 重建容器。

</details>

2. Kubernetes 1.24 移除 dockershim 后，CI 里 `docker build` 打出的镜像还能在集群里跑吗？为什么？

<details><summary>答案</summary>

能。移除的是 kubelet 到 Docker daemon 的翻译层，与镜像格式无关。docker build 产出的是符合 OCI image spec 的分层镜像（manifest/config/layers），推到 registry 后由节点上的 containerd/CRI-O 通过 CRI 的 ImageService 拉取并解包成 snapshot，创建容器走 runtime spec。真正受影响的只是"节点上还跑着一个纯 dockerd"的运行时链路。

</details>

3. crictl 和 ctr 都能列出容器，K8s 节点排障为什么首选 crictl？

<details><summary>答案</summary>

crictl 说 CRI 协议，看到的世界与 kubelet 完全一致：PodSandbox（crictl pods）与应用容器（crictl ps）分离，镜像列表就是 kubelet 拉取的那份，还能直接 `crictl logs`/`crictl exec`。ctr 是 containerd 原生客户端，只能看到一串容器对象（pause 混在其中），不知道哪些受 kubelet 管理，用它误删的容器 kubelet 可能并不在感知范围内修复。一句话：排障要复现"控制器的视角"。

</details>

4. 为什么 kubelet 不直接调用 runc，中间要有 containerd（或 CRI-O）？

<details><summary>答案</summary>

runc 只负责"把一个进程按 config.json 拉起来"并退出，不管镜像拉取与解包、网络（CNI 调用时机）、卷挂载、sandbox 生命周期、状态上报、垃圾回收。这些"运行时工程问题"由高层运行时承担，并以 CRI 为接口向 kubelet 屏蔽实现。分层还带来可替换性：换掉高层（containerd↔CRI-O）或低层（runc↔kata）都不影响 kubelet。

</details>

5. `live-restore` 和 containerd-shim 是什么关系？为什么它能让 dockerd 升级而容器不中断？

<details><summary>答案</summary>

shim 提供了"容器进程不依赖 daemon 存活"的机制，live-restore 是 dockerd 暴露的使用策略：默认（关闭时）dockerd 停机会主动停掉容器（保持状态一致）；开启后 dockerd 停机前与 shim 约定"保持运行"，重启后按 containerd 的元数据重新接管既有 shim。所以升级 dockerd 期间容器进程完全无感——这正是"daemon 死了容器不能死"这一分布式系统刚需的工程化。

</details>

## 延伸阅读

- containerd 官方站与架构文档：https://containerd.io/docs/
- OCI runtime spec：https://github.com/opencontainers/runtime-spec
- OCI image spec：https://github.com/opencontainers/image-spec
- Kubernetes CRI 概念：https://kubernetes.io/docs/concepts/architecture/cri/
- 官方博客"别慌：Kubernetes 与 Docker"（1.20 弃用公告）：https://kubernetes.io/blog/2020/12/02/dont-panic-kubernetes-and-docker/
- dockershim 移除 FAQ：https://kubernetes.io/blog/2022/02/17/dockershim-faq/
- cri-tools（crictl）：https://github.com/kubernetes-sigs/cri-tools
- nerdctl：https://github.com/containerd/nerdctl

---

上一章：[06 容器安全最佳实践](06-security-best-practices.md) ｜ 下一模块：[02 Kubernetes 基础](../04-k8s-fundamentals/01-why-kubernetes.md) ｜ 配套练习：`labs/08-local-registry`
