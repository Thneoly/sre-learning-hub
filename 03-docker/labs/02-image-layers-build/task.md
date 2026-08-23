# Lab 02 · 镜像分层观察与多阶段构建

> 难度：★★☆ ｜ 考点：Docker 镜像/构建（CKAD/CKA 镜像优化基础） ｜ 前置：lab 01 ｜ 预计 30~40 分钟

## 场景

你们的 CI 流水线打出的业务镜像越来越大（几百 MB 起步），部署到边缘节点时 pull 一次要几分钟。Lead 让你先搞清楚"一个镜像到底由哪些层组成、每层多大"，再用 multi-stage build 把一个 Go 静态页服务的镜像压缩到极小。你还要能回答：改一行代码重新 build，为什么大部分层都命中 cache、只有最后几层重建？

## 任务清单

1. 拉取 `alpine:3.20`，用 `docker history` 观察它的每一层；用 `docker image inspect` 找到 `GraphDriver.LowerDir`，数一数 `/var/lib/docker/overlay2` 下对应的 layer 目录。
2. 准备一个 20 行以内的 Go HTTP 服务 `hello.go`（监听 8080，返回 `hello from lab02`）。
3. 写 `Dockerfile.single`：单阶段，直接在 `golang:1.22-alpine` 里编译并运行，构建为镜像 `lab02-single`。
4. 写 `Dockerfile.multi`：multi-stage，编译阶段用 `golang:1.22-alpine`，运行阶段用 `alpine:3.20` 只 COPY 二进制，构建为镜像 `lab02-multi`。
5. 对比两个镜像的 SIZE 与 `docker history` 层数；解释差在哪几层。
6. 用 `lab02-multi` 启动容器 `lab02-web`，映射 `8082:8080`，宿主机 curl 验证返回 `hello from lab02`。
7. 修改 `hello.go` 中的一行输出文字后重新 build `lab02-multi`，观察 `--progress=plain` 输出中哪些 step 是 `CACHED`、哪些重建。

## 验收标准

- 镜像 `lab02-single` 与 `lab02-multi` 均存在，且 `lab02-multi` 的 SIZE 明显小于 `lab02-single`；
- `docker history lab02-multi` 能看到 `COPY --from=build` 层；
- 容器 `lab02-web` 运行中，`curl http://localhost:8082` 返回 `hello from lab02`。

完成后运行判分脚本：

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：镜像元数据在哪看层？</summary>

`docker image inspect -f '{{json .RootFS.Layers}}' alpine:3.20` 给出每层的 sha256 digest；`docker inspect -f '{{.GraphDriver.Data.LowerDir}}' <容器>` 是运行时 overlay 挂载的只读层路径（注意：inspect **镜像**没有 GraphDriver，要先跑成容器）。

> 若你的 `docker info` 显示 `Storage Driver: overlayfs`（`driver-type: io.containerd.snapshotter.v1`，Docker 28+ 全新安装默认的 containerd image store），容器 inspect 里**没有** GraphDriver 字段，层目录在 `/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/` 下；想按 overlay2 方式观察，可在 `/etc/docker/daemon.json` 里 `"features": {"containerd-image-store": false}` 后重启 docker。
</details>

<details><summary>提示 2：多阶段构建的关键字是什么？</summary>

第一阶段用 `FROM ... AS build` 命名，第二阶段直接是新的一行 `FROM alpine:3.20`，然后 `COPY --from=build /src/hello /app/hello` 只把编译产物带过来。Go 静态编译产物不依赖 libc 之外的东西（可加 `CGO_ENABLED=0` 保证纯静态），运行阶段不需要 golang 工具链。
</details>

<details><summary>提示 3：为什么 Go 二进制还要加 `CGO_ENABLED=0`？</summary>

alpine 用 musl libc，golang:alpine 镜像里若开 CGO 会动态链接 glibc/musl，换基础镜像可能跑不起来。`CGO_ENABLED=0` 产出纯静态二进制，甚至可以直接用 `FROM scratch`。
</details>
