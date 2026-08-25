# 02 · 镜像原理：分层、构建缓存、多阶段构建与 Registry 协议

> 模块：03-docker ｜ 建议时长：3 小时 ｜ 关联认证：CKA-镜像管理 / CKS-供应链安全（镜像精简与 digest 固定）

## 学习目标

- 能解释镜像分层与容器可写层的关系，并用 `docker history` 逐层还原一个镜像
- 能操作 Dockerfile 的指令顺序与 `--cache-from`、BuildKit 缓存挂载，把重复构建时间压到秒级
- 能解释多阶段构建为什么能瘦身，并写出 Go/Node 项目的多阶段 Dockerfile（给前后对比数据）
- 能解释 tag 与 digest 的区别，说明为什么生产环境必须用 digest 固定镜像
- 能排查"构建缓存突然全失效"的问题

## 1. 镜像 = 一叠只读层 + 一份 JSON 配置

第 1 章讲过 overlayfs 的 lowerdir 堆叠，镜像就是那叠 lowerdir 的**可运输形态**。OCI image-spec 规定镜像由三部分组成：

```
manifest.json        ── 指向 1 个 config blob + N 个 layer blob（含各层 sha256）
config（JSON blob）  ── 入口命令 Env/Cmd/Entrypoint、层顺序、构建历史
layer N（tar blob）  ── 每层是一个文件系统变更集（新增/修改/whiteout 删除标记）
```

```bash
# [任意节点] 把一个镜像解剖成 OCI 结构
docker pull alpine:3.20
docker image inspect alpine:3.20 --format '{{json .RootFS.Layers}}'
# 输出是一串 sha256，每个元素就是一层 —— alpine 只有一层

docker history alpine:3.20
# IMAGE / CREATED BY / SIZE 三列：每一行对应一层（或 metadata 配置行）
# 注意有些行 SIZE 为 0 且 MISSING：那是配置变更（ENV/CMD 等），不产生文件层
```

关键事实：**层是内容寻址的**（layer digest = 该 tar 的 sha256），所以两台机器上 digest 相同的层内容必然完全一致，这是 registry 去重与拉取增量化的基础。

## 2. Dockerfile 毇令如何变成层（与不变成层的）

| 指令 | 产生文件层？ | 层里内容 | 备注 |
|---|---|---|---|
| `FROM` | 是（引用） | 继承基础镜像全部层 | 后续层叠在其上 |
| `RUN` | 是 | 该命令对文件系统的全部改动 | 同一层的删除不能缩小前面的层 |
| `COPY` / `ADD` | 是 | 复制进来的文件 | `ADD` 多了自动解压与远程 URL（不推荐用） |
| `ENV` / `LABEL` / `EXPOSE` / `USER` / `WORKDIR` / `VOLUME` / `STOPSIGNAL` | 否（只写 config） | 镜像 JSON 配置字段 | `docker history` 里 SIZE 为 0 |
| `CMD` / `ENTRYPOINT` | 否（写 config） | 启动命令 | 两者同时存在时的组合规则见第 4 节 |
| `ARG` | 否 | 仅构建期变量 | 不进入运行期配置 |
| `HEALTHCHECK` | 否 | 写 config | 被 K8s 探针取代 |
| `ONBUILD` / `SHELL` | 否 | 触发器/默认 shell | 少用 |
| `MAINTAINER` | 已废弃 | — | 用 `LABEL maintainer=` |

**最重要的一条规则**：`RUN apt-get update && apt-get install -y xxx && rm -rf /var/lib/apt/lists/*` 必须写在**同一条**指令里。因为每一层只记录"相对上一层的 diff"，如果 update 在第 1 层、rm 在第 3 层，那么 update 下载的索引文件永远留在第 1 层里——镜像体积白占，删不掉。

## 3. 构建缓存命中规则

Docker（BuildKit）逐条指令对照缓存，判定规则按指令类型分两类：

1. **`COPY`/`ADD`**：对被复制文件/目录做内容哈希（mtime 变了内容没变也算命中），哈希一致且目标路径一致 → 命中。
2. **`RUN` 等其他指令**：对**指令字符串 + 父层链**求哈希。字符串里任何字符变化（包括换行、注释位置）都会 miss。`ARG`/环境变量会先代入再哈希。
3. **链式失效**：某一条 miss，其后所有指令必 miss——缓存是链式的，没有"跳过中间命中"。

推论（也是 Dockerfile 优化的全部逻辑）：**把变化最慢的放最上面，变化最快的放最下面**。依赖清单（requirements.txt / package.json / go.mod）先 COPY 再装依赖，源码最后 COPY。

```
优化前（每次改一行代码都重装依赖）:      优化后（改代码只重建最后一层）:
FROM python:3.12-slim                    FROM python:3.12-slim
WORKDIR /app                             WORKDIR /app
COPY . /app            ← 源码先进来       COPY requirements.txt .
RUN pip install -r requirements.txt      RUN pip install --no-cache-dir -r requirements.txt
CMD ["python","app.py"]                  COPY . .         ← 源码最后进来
                                         CMD ["python","app.py"]
```

```bash
# [任意节点] 观察缓存命中
mkdir -p /tmp/cachedemo && cd /tmp/cachedemo
cat > Dockerfile <<'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python", "app.py"]
EOF
echo 'flask==3.0.3' > requirements.txt
echo 'print("hi")' > app.py
docker build -t cachedemo:v1 .    # 第一次：全部 CACHED 为空，逐层执行
echo 'print("hi v2")' > app.py
docker build -t cachedemo:v2 .    # 预期：前 4 步 CACHED，仅 COPY . . 重建
```

```bash
# [任意节点] BuildKit 缓存挂载：装依赖不再依赖"层缓存"这个粗粒度机制
cat > Dockerfile.mount <<'EOF'
# syntax=docker/dockerfile:1.7
FROM ubuntu:24.04
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    apt-get update && apt-get install -y --no-install-recommends curl
EOF
docker build -f Dockerfile.mount -t aptcachedemo .
# 重复执行第二次时，apt 索引来自缓存挂载，几乎瞬间完成
# 关键区别：缓存挂载的数据不进镜像层，只留在本机构建缓存里
```

`--cache-from` 用于 CI：把上次的镜像推到 registry，本次构建拉下来当缓存源（`docker build --cache-from repo/app:ci .`），适合每次都是全新 runner 的流水线。

## 4. 多阶段构建：为什么能瘦身

### 4.1 原理

编译期只需要"编译器"，运行期只需要"产物+运行时"。单阶段构建把 gcc/node_modules/go toolchain 全部打进了最终镜像；多阶段构建用 `COPY --from=<阶段>` 只把产物搬到干净的运行时镜像里——编译器所在的层根本不进入最终镜像的层链，**因为最终镜像的 RootFS.Layers 只包含被 COPY 进来的那一层**。

### 4.2 前后对比（实测数量级）

```
Go 应用单阶段（FROM golang:1.22 编译并运行）:  约 830 MB
Go 多阶段（FROM golang 编译 → FROM scratch/distroless 运行）: 约 8~15 MB
Node 应用单阶段（含 node_modules/devDeps）:    约 1.2 GB
Node 多阶段（builder 装依赖+build → runner 仅 prod deps+dist）: 约 180 MB
```

```dockerfile
# [任意节点] 单阶段（反面教材）
# Dockerfile.single
FROM golang:1.22-bookworm
WORKDIR /src
COPY . .
RUN go build -o /bin/app ./cmd/app
CMD ["/bin/app"]
```

```dockerfile
# [任意节点] 多阶段（生产写法）
# Dockerfile.multi
FROM golang:1.22-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /out/app ./cmd/app

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

```bash
# [任意节点] 对比验证：单阶段（用 heredoc 直接构建，无需准备项目文件）
cd /tmp/cachedemo
docker build -t demo:single - <<'EOF'
FROM golang:1.22-bookworm
WORKDIR /src
COPY . .
RUN go build -o /bin/app . 2>/dev/null || true
EOF

# 再构建多阶段版本（同样不需要真实 Go 源码，只为看体积差异）
docker build -t demo:multi - <<'EOF'
FROM golang:1.22-bookworm AS build
WORKDIR /src
COPY . .
RUN mkdir -p /out && (go build -o /out/app . 2>/dev/null || touch /out/app)
FROM alpine:3.20
COPY --from=build /out/app /app
ENTRYPOINT ["/app"]
EOF

docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep demo
# 预期：demo:single 约 800+MB（含整个 Go 工具链层），demo:multi 只有几十 MB
docker history demo:single --format '{{.Size}}\t{{.CreatedBy}}' | head -8
# history 能看到单阶段里 go 工具链占了哪些层；多阶段最终镜像的 history 里没有这些层
```

CKS 视角：镜像越小，攻击面越小（没有 shell、没有包管理器），`trivy` 扫出的 CVE 也越少。distroless/scratch 是终极形态。

### 4.3 CMD 与 ENTRYPOINT 的组合（构建知识的收尾）

| Dockerfile 写法 | `docker run img arg` 实际执行 | 典型用途 |
|---|---|---|
| 只有 `CMD ["a","b"]` | `a b` 被整体替换为 `arg` | 简单镜像 |
| 只有 `ENTRYPOINT ["a"]` | `a arg` | 固定入口 |
| `ENTRYPOINT ["a"]` + `CMD ["b"]` | `a b`；传 arg 则 `a arg`（CMD 作为默认参数） | 最常用模式 |
| shell 形式 `ENTRYPOINT a b` | `/bin/sh -c "a b"`，**收不到信号** | 避免，PID 1 问题见第 1 章 |

心智模型一句话：**ENTRYPOINT 是句子的"动词"（容器存在的目的，固定），CMD 是"默认宾语"（可整体替换）**。`docker run img <args>` 只干一件事：顶掉 CMD、保留 ENTRYPOINT。

**三套覆盖手段与 K8s 映射**（高频面试题）：

| 手段 | 覆盖谁 | 例子 |
|---|---|---|
| `docker run img <args>` | CMD | `docker run img -t`（默认参数让位） |
| `docker run --entrypoint <cmd> img` | ENTRYPOINT | `docker run --entrypoint sh img`（瞬变调试容器） |
| K8s Pod 字段 | **`command` ↔ ENTRYPOINT，`args` ↔ CMD** | `command: ["nginx"]` + `args: ["-t"]` |

K8s 命名反直觉（它的 `command` 对应 Docker 的 ENTRYPOINT 而非 CMD），记"command=动词，args=宾语"。大坑：**Pod 里只写 `args` 不写 `command`，镜像 ENTRYPOINT 保留、CMD 被换**——很多人以为行为会全变，其实入口没动。

**exec 形式 vs shell 形式深挖**（接第 1 章 PID 1 一课）：

| 写法 | 实际执行 | PID 1 是谁 | 信号到 app？ |
|---|---|---|---|
| `["nginx","-g","daemon off;"]` | 直接 exec | **nginx** | ✅ |
| `nginx -g "daemon off;"` | `/bin/sh -c '...'` | **/bin/sh** | ❌（SIGTERM 被 sh 吞掉，10 秒后 SIGKILL 强杀） |

shell 形式唯一诱人处是变量展开，正确写法是显式包一层并 `exec`：

```dockerfile
# [文件 Dockerfile]
ENTRYPOINT ["sh", "-c", "exec java -jar app.jar --port=${PORT:-8080}"]
#                              ↑↑↑↑ exec 让 java 顶替 sh 成为 PID 1
```

**官方 nginx 的三层设计**（ENTRYPOINT + CMD 配合的教科书）：

```dockerfile
ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]
```

entrypoint 脚本结尾必然是 `exec "$@"`：先做初始化（模板渲染、环境变量注入），再把自己替换成 CMD 的内容——初始化必跑 + PID 1 正确移交 + 默认参数可覆盖，三件事各归其位。

**PID 1 的两个"不配做"与三种补救**：容器入口进程当了 PID 1，但内核给它特权待遇——**未注册 handler 的信号（含默认致命信号）对它一律无效**，且它该负责收割僵尸、转发信号，业务 app 通常不会做。补救：

1. **`init: true` / `docker run --init`**：Docker 1.13+ 内置 tini（`/usr/bin/docker-init`）自动垫成 PID 1，镜像零改动（compose 里就写 `init: true`）
2. **镜像里装 tini/dumb-init**：`ENTRYPOINT ["/sbin/tini","--","java","-jar","app.jar"]`。tini（30KB 静态 C 程序）转发信号给直接子进程 + 收割僵尸 + 透传退出码；dumb-init（Yelp）默认把信号广播给整个进程组，适合 app 自己不做信号分发的场景（`--single-child` 可切回 tini 行为）。**K8s 没有原生 init 开关，把 tini 打进镜像是标准做法**（`shareProcessNamespace: true` 让 pause 当 PID 1 也能收割，但 delete pod 的信号语义会变，慎用）
3. **最常见的真凶其实不需要 tini**：shell 形式 ENTRYPOINT 让 `/bin/sh` 当了 1 号。排障口诀——容器里 `ps -f 1` 看一眼，1 号是 sh 就改 exec 形式；app 确实 fork 短命子进程（zombie 风险）再上 tini

### 4.4 Docker 里跑 Docker：真嵌套与假嵌套

**DinD（Docker-in-Docker，真嵌套）**——容器里跑完整内层 dockerd（自己的 containerd/镜像库/再造容器）：

```
┌ 宿主机 ─────────────────────────┐
│ ┌ 外层容器（--privileged）───┐ │
│ │ dockerd（内层）            │ │
│ │  ├─ nginx（孙容器）        │ │
│ │  └─ redis（孙容器）        │ │
│ └───────────────────────────┘ │
└────────────────────────────────┘
```

必须 `--privileged`：造容器要动 namespace/cgroup/mount，普通容器被裁掉的权限内层 dockerd 全都要（"在 VR 眼镜里再造 VR 眼镜，先得拿管理员权限"）。典型用户：GitLab CI 的 `docker:27-dind` service、**kind**（Kubernetes-in-Docker，容器套整套 K8s）。隔离好，但镜像缓存独立、体积大。

**socket 复用（DooD，假嵌套）**——容器里只有 docker 客户端，挂宿主机 `/var/run/docker.sock`，命令发宿主机 dockerd：

```
宿主机 dockerd ←─ socket ─┐
 ├─ 容器 A（你的"外层"容器）│
 └─ 容器 B（A 里 run 出来的）← A 的兄弟，不是孩子！
```

关键认知：**不是嵌套，是兄弟**。由此三个经典 CI 坑：`docker ps` 看到的是宿主机容器；`-v ./code:/src` 的路径按**宿主机**文件系统解析；好处是镜像缓存与宿主机共享、零开销。gitlab-ci lab 实测踩过的坑同源：`docker:27-cli` 默认 context 指向不存在的 `tcp://docker:2375`（为 dind 预设），挂 socket 必须显式 `DOCKER_HOST=unix:///var/run/docker.sock`。

第三条路：**kaniko/buildkit** 无守护进程构建，进程直接拼镜像推仓库——K8s 原生 CI 主流。选型：CI 简单优先挂 socket；K8s 原生/安全优先 kaniko；要隔离的一次性环境用真 DinD。

**安全警告（CKS 级）**：`docker.sock` ≈ 宿主机 root——拿到 socket 就能 `docker run -v /:/host --privileged` 改宿主机任意文件。绝不可挂给不可信容器；需要时考虑 rootless docker / podman socket 降权。

## 5. Registry 协议与 tag/digest

### 5.1 push/pull 时发生了什么（OCI Distribution Spec）

Registry 就是一个 HTTP API 服务（v2 协议），核心端点：

```
GET  /v2/                                      → 握手（是否可用、是否要认证）
GET  /v2/<name>/manifests/<reference>          → 取 manifest（tag 或 digest 皆可作 reference）
GET  /v2/<name>/blobs/<digest>                 → 下载 layer/config blob
PUT  /v2/<name>/manifests/<tag>                → push manifest
POST /v2/<name>/blobs/uploads/                 → 开始 blob 上传（返回 session URL）
```

拉取流程：`GET manifest` → 解析出 config digest 与 layer digest 列表 → 本地已有的跳过（增量拉取）→ 逐个 `GET blobs` → 按层组装 overlay。认证用 Token（Bearer）方案：401 响应带 `WWW-Authenticate` 头告诉客户端去哪换 token。

```bash
# [任意节点] 直接用 curl 观察 Docker Hub 的 registry 协议
# 第 1 步：匿名拿 token（Docker Hub 要求先换 token）
TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/alpine:pull" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

# 第 2 步：取 manifest（注意 Accept 必须声明 OCI 类型）
curl -s -H "Authorization: Bearer $TOKEN" \
  -H "Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
  https://registry-1.docker.io/v2/library/alpine/manifests/3.20 | python3 -m json.tool
# 输出：config.digest + layers[].digest（各一行一个 sha256）
```

### 5.2 tag 是标签，digest 是指纹

- **tag**（如 `alpine:3.20`）：可变的指针，维护者随时可以把 `:latest`、甚至 `:3.20` 重新指向新的 manifest。**同 tag 两次 pull 可能得到不同内容**。
- **digest**（如 `alpine@sha256:c5...`）：manifest 内容的 sha256。内容变则 digest 变，**全球唯一且不可变**。

```bash
# [任意节点] 查看并固定 digest
docker inspect --format '{{index .RepoDigests 0}}' alpine:3.20
# 输出形如 alpine@sha256:0bd4e7d9...——把这一串写进部署清单就是"锁版本"

docker manifest inspect alpine:3.20 | head -5
# 多架构镜像：manifest list（index）里按 platform 指向多个子 manifest
```

Kubernetes 里 `image: nginx:1.27` 是按 tag 拉取；`imagePullPolicy: IfNotPresent` 时一旦本地有了该 tag 就不再核对 registry——tag 被覆盖后节点上跑的还是旧镜像。`image: nginx@sha256:...` 才是确定性部署，CKS 考试与生产基线都要求 digest 固定（配合 `imagePullPolicy: Always` 或签名校验 cosign）。

### 5.3 本地 registry 实验（完整闭环）

```bash
# [任意节点] 起一个本地 registry（第 1 章原理的现成验证工具）
docker run -d -p 5000:5000 --restart=always --name registry registry:2
docker tag alpine:3.20 localhost:5000/lab/alpine:3.20
docker push localhost:5000/lab/alpine:3.20
# 验证：直接调它的 v2 API（本地 registry 无需认证）
curl -s http://localhost:5000/v2/_catalog            # {"repositories":["lab/alpine"]}
curl -s http://localhost:5000/v2/lab/alpine/tags/list
docker rmi localhost:5000/lab/alpine:3.20
docker pull localhost:5000/lab/alpine:3.20           # 从本地 registry 秒回
```

## 实战演练

把本章的核心机制串成一条可在任意 Docker 节点上完成的验证链（每步都有预期输出）。

**演练 1：解剖镜像与构建缓存命中（对应第 1、3 节）**

```bash
# [任意节点] 看层、看 history，再做两次构建观察缓存
docker pull alpine:3.20
docker image inspect alpine:3.20 --format '{{json .RootFS.Layers}}'   # 一串 sha256，每元素一层
docker history alpine:3.20                                            # SIZE 为 0 的行是 config 变更

mkdir -p /tmp/cachedemo && cd /tmp/cachedemo
cat > Dockerfile <<'EOF'
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
CMD ["python", "app.py"]
EOF
echo 'flask==3.0.3' > requirements.txt
echo 'print("hi")' > app.py
docker build -t cachedemo:v1 .        # 第一次全部执行
echo 'print("hi v2")' > app.py
docker build -t cachedemo:v2 .        # 验证：前 4 步 CACHED，仅 COPY . . 重建
```

**演练 2：单阶段 vs 多阶段体积对比（对应第 4 节）**

```bash
# [任意节点] 用 heredoc 构建两个版本，只看体积与层链差异
cd /tmp/cachedemo
docker build -t demo:single - <<'EOF'
FROM golang:1.22-bookworm
WORKDIR /src
COPY . .
RUN go build -o /bin/app . 2>/dev/null || true
EOF
docker build -t demo:multi - <<'EOF'
FROM golang:1.22-bookworm AS build
WORKDIR /src
COPY . .
RUN mkdir -p /out && (go build -o /out/app . 2>/dev/null || touch /out/app)
FROM alpine:3.20
COPY --from=build /out/app /app
ENTRYPOINT ["/app"]
EOF
docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.Size}}' | grep demo
# 验证：demo:single 800+MB，demo:multi 几十 MB
docker history demo:multi --format '{{.Size}}\t{{.CreatedBy}}' | head -5
# 验证：最终镜像的层链里找不到 Go 工具链层 —— builder 阶段没有进入层链
```

**演练 3：tag/digest 与本地 registry 闭环（对应第 5 节）**

```bash
# [任意节点] 起本地 registry，push/pull/rmi 再拉回，用 v2 API 验证内容
docker run -d -p 5000:5000 --restart=always --name registry registry:2
docker tag alpine:3.20 localhost:5000/lab/alpine:3.20
docker push localhost:5000/lab/alpine:3.20
curl -s http://localhost:5000/v2/_catalog          # {"repositories":["lab/alpine"]}
docker inspect --format '{{index .RepoDigests 0}}' alpine:3.20
# 输出形如 alpine@sha256:0bd4...—— 写进部署清单即锁版本
docker rmi localhost:5000/lab/alpine:3.20
docker pull localhost:5000/lab/alpine:3.20         # 验证：层已在本机，秒级完成
docker rm -f registry && docker rmi demo:single demo:multi cachedemo:v1 cachedemo:v2 2>/dev/null
```

完成标准：能口头复述每步输出里"哪个数字/哪一行"证明了对应机制（层链、缓存命中、层共享、digest 固定）。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 改了一行代码，构建却从头重来 | 变化频繁的文件被早层 COPY；或构建上下文里 .env/构建产物变化导致 COPY 哈希变 | 用 `.dockerignore`；按"变更频率升序"重排指令 |
| `RUN rm` 了文件镜像没变小 | rm 在新层，旧层数据还在 | 同一条 RUN 里清理；或多阶段构建 |
| CI 上缓存永远 miss | CI runner 每次全新 | `--cache-from` 挂上次镜像；或自建 BuildKit 缓存卷 |
| `docker pull` 报 manifest unknown | tag 拼错/多架构 index 里没有当前架构（如 arm 机器拉 amd64-only 镜像） | `docker manifest inspect` 确认 platform 列表；加 `--platform linux/amd64` |
| 同一 tag 在不同节点行为不一致 | tag 可变 + `imagePullPolicy: IfNotPresent` | 生产用 `@sha256:` 固定；或 tag 用不可变的构建号 |
| push 到本地 registry 报 http: server gave HTTP response to HTTPS client | Docker 默认对远程 registry 走 HTTPS | `/etc/docker/daemon.json` 加 `{"insecure-registries":["<registry:5000>"]}` 后重启 docker |
| build 提示 no such file/requirements.txt | 构建上下文与 Dockerfile 所在目录不一致 | `docker build -f path/Dockerfile .` 的上下文是最后的 `.`，COPY 相对它 |

## 自测

<details><summary>1. 为什么 `RUN apt-get update` 和 `RUN rm -rf /var/lib/apt/lists/*` 分成两条指令写，镜像体积不会减小反而可能更大？</summary>

层是叠加的 diff：第一条层里写入了索引文件，第二条层里记录的是"删除这些文件"的 whiteout。拉取和存储时两层都要保留，旧层数据仍占空间；只有把两者用 `&&` 合并进同一条 RUN（同一个 diff 里先写后删，最终不存在），文件才真正不进层。极端情况下分两条还会因为元数据和目录项多占一点。
</details>

<details><summary>2. 构建日志显示前 5 步 CACHED，第 6 步 `RUN pip install` 重新执行了，而 requirements.txt 根本没改。给出至少两种可能原因。</summary>

（1）第 6 步之前的某条指令字符串变了——比如在它上面新加了一行注释、改了 ARG 默认值、调整了 ENV，父层链哈希变了；（2）用了 `--no-cache` 或 CI 环境 changed builder；（3）requirements.txt 的 COPY 目标路径/权限元数据变化，或 `.dockerignore` 变化导致上下文哈希变化；（4）基础镜像 tag 更新且显式 pull 过，FROM 层 digest 变了。缓存判定 = 指令串哈希 + 父层链，任何上游变化都会传导下来。
</details>

<details><summary>3. 多阶段构建里，builder 阶段的层最终去了哪里？为什么最终镜像里看不到它们？</summary>

它们只存在于构建过程与本机构建缓存中，不会被引用进最终镜像的层链。最终镜像的 manifest 只包含最后阶段（FROM 行开始的层）加 `COPY --from` 生成的那一层。这就是瘦身原理：不是"删掉了"builder 的层，而是最终镜像的层链从头就没包含它们。
</details>

<details><summary>4. 生产deployment里 `image: app:2.1` 且 `imagePullPolicy: IfNotPresent`，上游把 `:2.1` 覆盖推了新内容。滚动重启后集群行为如何？</summary>

已缓存旧镜像的节点：kubelet 发现本地有 `app:2.1`，直接复用旧镜像，跑的是旧内容；从未拉过该镜像的新节点：拉到的是新内容。结果同 tag 异版本并存，流量行为不可预测。修复：用 digest（`app@sha256:...`）或不可变 tag（含 git sha/构建号）+ IfNotPresent，或可变 tag 配 Always 策略。
</details>

<details><summary>5. `docker pull` 一个 500MB 的新 tag 却只下载了几 MB 就完成，怎么回事？两个 tag 之间是什么关系？</summary>

该镜像的绝大多数层与本地已有镜像共享（layer digest 相同）。pull 先取 manifest，逐层比对 digest，本地已存在的层直接跳过下载，只拉缺失的少量层和 config。两个 tag 的 manifest 指向了重叠的层集合——典型场景：同一基础镜像的新版本应用，只有最上面 `COPY` 那一层不同。这也是节点镜像预热与 P2P 分发能省带宽的底层原因。
</details>

## 延伸阅读

- Dockerfile 最佳实践（官方）：https://docs.docker.com/develop/develop-images/dockerfile_best-practices/
- BuildKit 与 dockerfile 语法扩展：https://docs.docker.com/build/building/cache/
- 多平台镜像构建（buildx + QEMU，一份 Dockerfile 出 amd64/arm64）：https://docs.docker.com/build/building/multi-platform/
- OCI image-spec：https://github.com/opencontainers/image-spec
- OCI Distribution Spec：https://github.com/opencontainers/distribution-spec
- Registry 开源实现：https://github.com/distribution/distribution
- distroless 镜像：https://github.com/GoogleContainerTools/distroless
