# Lab 02 · 解答与讲解

> 前置：Ubuntu VM 已装 Docker；能访问 Docker Hub 拉取 `golang:1.22-alpine` 与 `alpine:3.20`。

## 第 1 步：观察一个现成镜像的层

```bash
# [Ubuntu VM]
docker pull alpine:3.20
docker history alpine:3.20
docker image inspect -f '{{json .RootFS.Layers}}' alpine:3.20 | tr ',' '\n'
```

预期输出（history 部分）：

```
IMAGE          CREATED       CREATED BY                                      SIZE
ebce8527b8f4   x weeks ago   /bin/sh -c #(nop)  CMD ["/bin/sh"]              0B
<missing>      x weeks ago   /bin/sh -c #(nop) ADD file:... in /              7.80MB
```

alpine 只有一个数据层（约 7.8 MB 的 rootfs tar），其余 `#(nop)` 行是**配置元数据**（CMD、ENV 等），SIZE 为 0——层不只是文件 diff，还包括对镜像 config 的修改记录。

`RootFS.Layers` 是每层内容的 sha256 digest：

```
["sha256:945e2b7..."]
```

再看运行时挂载：镜像本身没有 GraphDriver 信息，必须跑成容器。

```bash
# [Ubuntu VM]
docker run -d --name lab02-probe alpine:3.20 sleep 300
docker inspect -f '{{.GraphDriver.Data.LowerDir}}' lab02-probe | tr ':' '\n'
```

输出是 `/var/lib/docker/overlay2/<diff-id>/diff` 形式的路径，数量与 `RootFS.Layers` 一致。用 sudo 验证其中真实存在：

> Docker 28+ 全新安装默认启用 containerd image store（`docker info` 显示 `Storage Driver: overlayfs`），此时容器 inspect 没有 GraphDriver 字段（模板报 `map has no entry for key "GraphDriver"`），层目录改为 `/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/<id>/fs`。本步其余观察（RootFS.Layers、docker diff）不受影响。

```bash
# [Ubuntu VM]
LOWER=$(docker inspect -f '{{.GraphDriver.Data.LowerDir}}' lab02-probe | cut -d: -f1)
sudo ls "$LOWER"
```

overlay 挂载结构（cgroup v2 + overlay2 storage driver）：

```
容器看到的 /  =  overlay(lowerdir + upperdir + workdir)
                 ┌────────────────────────────┐
   upperdir ───▶ │ 可写层（容器内写入落在这里）│
   lowerdirs ──▶ │ 镜像只读层（ro，可共享）    │
                 └────────────────────────────┘
   同一镜像起的 N 个容器共享 lowerdir，各有一份 upperdir
```

```bash
# [Ubuntu VM]
docker exec lab02-probe touch /tmpfile && docker exec lab02-probe sh -c 'echo hi > /data.txt'
docker diff lab02-probe
```

`docker diff` 只显示相对镜像层的差异（`C` changed / `A` added / `D` deleted），全部落在 upperdir：

```
C /tmp
A /data.txt
```

## 第 2 步：准备 Go 源码

```bash
# [Ubuntu VM]
mkdir -p ~/lab02 && cd ~/lab02
cat > hello.go <<'EOF'
package main

import (
	"fmt"
	"net/http"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintln(w, "hello from lab02")
	})
	http.ListenAndServe(":8080", nil)
}
EOF
```

## 第 3 步：单阶段 Dockerfile

```bash
# [Ubuntu VM]
cd ~/lab02
cat > Dockerfile.single <<'EOF'
FROM golang:1.22-alpine
WORKDIR /src
COPY hello.go .
RUN go mod init hello && CGO_ENABLED=0 go build -o /app/hello .
EXPOSE 8080
CMD ["/app/hello"]
EOF

docker build -t lab02-single -f Dockerfile.single .
```

预期输出末尾：

```
=> => naming to docker.io/lab02-single
```

## 第 4 步：多阶段 Dockerfile

```bash
# [Ubuntu VM]
cd ~/lab02
cat > Dockerfile.multi <<'EOF'
FROM golang:1.22-alpine AS build
WORKDIR /src
COPY hello.go .
RUN go mod init hello && CGO_ENABLED=0 go build -o /app/hello .

FROM alpine:3.20
COPY --from=build /app/hello /app/hello
EXPOSE 8080
CMD ["/app/hello"]
EOF

docker build -t lab02-multi -f Dockerfile.multi .
```

## 第 5 步：对比 SIZE 与层

```bash
# [Ubuntu VM]
docker images | grep -E 'lab02-(single|multi)'
echo '--- lab02-single ---'
docker history lab02-single
echo '--- lab02-multi ---'
docker history lab02-multi
```

典型结果（数字随版本浮动）：

```
lab02-single   latest   ...   400MB以上   ← 整个 golang 工具链 + 源码 + Go module cache 都在最终镜像里
lab02-multi    latest   ...   10~15MB     ← alpine 基础层 7.8MB + 一个 ~7MB 的静态二进制
```

`docker history lab02-multi` 里能看到类似：

```
COPY /app/hello /app/hello        7.2MB   ← 来自 build 阶段的产物层
```

差异的本质：**最终镜像只包含最后一个 FROM 之后的层**。multi-stage 让"编译环境"与"运行环境"解耦——类似 CI 里的 builder 节点不随产物发布。

## 第 6 步：运行并验证

```bash
# [Ubuntu VM]
docker rm -f lab02-probe
docker run -d --name lab02-web -p 8082:8080 lab02-multi
curl -s http://localhost:8082/
```

预期输出：

```
hello from lab02
```

## 第 7 步：cache 命中观察

```bash
# [Ubuntu VM]
cd ~/lab02
sed -i 's/hello from lab02/hello from lab02 v2/' hello.go
docker build --progress=plain -t lab02-multi -f Dockerfile.multi . 2>&1 | grep -E 'CACHED|DONE|RUN|COPY'
# 恢复原文，保证判分脚本通过
sed -i 's/hello from lab02 v2/hello from lab02/' hello.go
docker build -t lab02-multi -f Dockerfile.multi .
```

第一次 rebuild 的输出里：

- `COPY hello.go .` 这一步**没有** CACHED（源码变了，hash 不同）；
- 其后的 `RUN go build` 也重建；
- 但如果你把 `COPY hello.go` 之前还有 `RUN apk add` 之类的步骤，它们会显示 `CACHED`。

cache 规则：**按 Dockerfile 指令 + 指令输入内容（文件 hash）逐层匹配，一旦某层 miss，其后所有层必然重建**。这就是"Dockerfile 里把不常变的步骤放前面、源码 COPY 放最后"这条最佳实践的来源。改回原文后再 build 一次，因为内容 hash 与第一次相同，几乎全部 CACHED（产物层直接复用）。

最后确认终态没被第 7 步破坏：

```bash
# [Ubuntu VM]
curl -s http://localhost:8082/
# hello from lab02
```

## 判分脚本结果

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

预期输出：

```
PASS: 镜像 lab02-single 存在
PASS: 镜像 lab02-multi 存在
PASS: lab02-multi SIZE 比 lab02-single 至少小 50MB
PASS: lab02-multi history 含 COPY 产物层（多阶段证据）
PASS: lab02-web 运行中且使用 lab02-multi 镜像
PASS: curl http://localhost:8082 返回 hello from lab02

SCORE: 6/6
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 多阶段容器启动即 `not found` | 二进制动态链接了 glibc，alpine 没有 | build 时加 `CGO_ENABLED=0` |
| 改一行代码全量重建 | `COPY . .` 放在最前，或源码目录里有频繁变动的文件 | 调整指令顺序；加 `.dockerignore` 排除无关文件 |
| `docker image inspect` 看不到 GraphDriver | 镜像元数据不含运行时挂载信息 | 先 `docker run` 起来，再 inspect **容器** |
| 层显示 `<missing>` | 该层属于基础镜像，本地只有 digest 引用 | 正常现象，`--no-trunc` 可看完整链 |

## 延伸阅读

- Docker 官方文档 Multi-stage builds：https://docs.docker.com/build/building/multi-stage/
- overlayfs 与 storage driver：https://docs.docker.com/storage/storagedriver/overlayfs-driver/
