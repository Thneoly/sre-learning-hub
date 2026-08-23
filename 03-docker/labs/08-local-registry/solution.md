# Lab 08 · 解答与讲解

> 前置：Ubuntu VM 已装 Docker；能访问 Docker Hub 拉取 `registry:2` 与 `nginx:alpine`（lab 01 已拉过 nginx）。

## 第 1 步：起 registry

```bash
# [Ubuntu VM]
docker volume create lab08-data
docker run -d --name lab08-registry \
  --restart always \
  -p 5000:5000 \
  -v lab08-data:/var/lib/registry \
  registry:2
docker ps --filter name=lab08-registry --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

预期输出：

```
NAMES             STATUS         PORTS
lab08-registry    Up 10 seconds  0.0.0.0:5000->5000/tcp
```

要点回顾：`--restart always` 让 VM 重启/daemon 恢复后仓库自己回来（lab 01）；named volume 让镜像数据独立于容器生命周期（lab 04）；`registry:2` 是官方 Docker Distribution 的镜像，`/var/lib/registry` 是它的存储根（可设 `REGISTRY_STORAGE_DELETE_ENABLED=true` 环境变量开启 API 删除，默认只增不减）。

## 第 2 步：API v2 存活探测

```bash
# [Ubuntu VM]
curl -s http://localhost:5000/v2/ ; echo
curl -s -o /dev/null -w "HTTP %{http_code}\n" http://localhost:5000/v2/
```

预期：

```
{}
HTTP 200
```

`/v2/` 返回 200 + `{}` 是"registry 活着"的标准探测（K8s 里 registry 类组件的 readiness probe 常打这个端点）。

## 第 3 步：tag 与 push

```bash
# [Ubuntu VM]
docker tag nginx:alpine localhost:5000/lab/nginx:alpine
docker push localhost:5000/lab/nginx:alpine
```

预期输出（分层上传，已存在的层显示 Layer already exists）：

```
The push refers to repository [localhost:5000/lab/nginx:alpine]
xxxxxxx: Pushed
yyyyyyy: Pushed
alpine: digest: sha256:<64位十六进制> size: 952
```

为什么不需要配 TLS：Docker daemon 对 `localhost`/`127.0.0.1` 目标默认按 insecure registry 处理（HTTP 明文）。如果换对外 IP：

```bash
# [Ubuntu VM]（仅当你要从其他机器访问时才需要；本实验可跳过）
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "insecure-registries": ["172.30.30.21:5000"]
}
EOF
sudo systemctl restart docker
```

生产环境正确做法是给 registry 签发 TLS 证书（Let's Encrypt 或内部 CA），让 daemon 走 HTTPS。

## 第 4 步：用 API 查目录与 tag

```bash
# [Ubuntu VM]
curl -s http://localhost:5000/v2/_catalog ; echo
curl -s http://localhost:5000/v2/lab/nginx/tags/list ; echo
```

预期：

```
{"repositories":["lab/nginx"]}
{"name":"lab/nginx","tags":["alpine"]}
```

`_catalog` 默认最多返回 100 条，多了带 `Link` 响应头分页（`?n=100&last=xxx`）。这套 REST API（OCI Distribution Spec）对所有兼容仓库通用——Harbor、GHCR、_quay_ 都是同一套接口，巡检脚本换个域名就能用。

## 第 5 步：删了再拉（闭环验证）

```bash
# [Ubuntu VM]
docker rmi localhost:5000/lab/nginx:alpine
docker images | grep 'localhost:5000' || echo "本地已无该镜像"
docker pull localhost:5000/lab/nginx:alpine
docker images | grep 'localhost:5000'
```

预期最后能看到：

```
localhost:5000/lab/nginx   alpine   <id>   x days ago   43.2MB
```

push/pull 闭环成立——仓库确实保存了可用的镜像数据（存在 `lab08-data` volume 里）：

```bash
# [Ubuntu VM]
sudo ls "$(docker volume inspect lab08-data --format '{{.Mountpoint}}')/docker/registry/v2/repositories/lab"
```

## 第 6 步：digest 双向核对

```bash
# [Ubuntu VM]
docker inspect --format '{{index .RepoDigests 0}}' localhost:5000/lab/nginx:alpine
curl -sI -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  http://localhost:5000/v2/lab/nginx/manifests/alpine | grep -i docker-content-digest
```

预期两处 digest 完全一致（形如）：

```
localhost:5000/lab/nginx@sha256:1cde0e...
Docker-Content-Digest: sha256:1cde0e...
```

> Accept 头必须把 **OCI 类型也带上**：Docker 28+ 默认的 containerd image store push 上去的是 OCI mediatype 的 manifest，registry 的内容协商很严格——只带老的 `application/vnd.docker.distribution.manifest.v2+json`（或不带 Accept）会得到 **404 Not Found**，四类全带才返回 200 与 digest 头。若 push 时看到 `Info -> Not all multiplatform-content is present...`，说明本地只有单平台层，registry 存的是单平台 manifest，属正常提示。

digest 是 manifest 内容的 sha256。意义：tag 会漂移（`alpine` 明天可能指向新构建），digest 不会。供应链安全实践（CKS）：

```bash
# [Ubuntu VM]
# 用 digest 拉取，确保拿到的一字不差：
DIGEST=$(curl -sI -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
  http://localhost:5000/v2/lab/nginx/manifests/alpine | awk 'tolower($1)=="docker-content-digest:"{gsub("\r","",$2); print $2}')
echo "localhost:5000/lab/nginx@${DIGEST}"
docker pull "localhost:5000/lab/nginx@${DIGEST}"
```

## 第 7 步：再推一个仓库

```bash
# [Ubuntu VM]
docker tag lab02-multi localhost:5000/lab/hello:1.0
docker push localhost:5000/lab/hello:1.0
curl -s http://localhost:5000/v2/_catalog ; echo
```

预期：

```
{"repositories":["lab/hello","lab/nginx"]}
```

（若 lab 02 未做、没有 lab02-multi，用任意本地镜像代替即可，例如 `docker tag alpine:3.20 localhost:5000/lab/hello:1.0`。）

镜像引用的解剖：

```
localhost:5000  /  lab/nginx  :  alpine      @  sha256:1cde...
└─── registry 主机:端口       └── 仓库路径   └── tag        └── digest（不可变定位）
无主机前缀（nginx:alpine）⇒ 默认 registry-1.docker.io（即 Docker Hub）
```

## 给 kubeadm 集群用的铺垫（后续模块衔接）

单 master 集群各节点要拉同一个镜像时，把节点 docker 也指向这个 registry（ insecure-registries 配置），再 `kubeadm config images pull` / 改 `--image-repository`。这样整个离线演练链路（构建 → push 本地 registry → 节点 pull）就通了。

## 判分脚本结果

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

预期输出：

```
PASS: lab08-registry 运行中且 RestartPolicy 为 always
PASS: lab08-registry 发布 5000->5000
PASS: GET /v2/ 返回 {}
PASS: /v2/_catalog 含 lab/nginx
PASS: /v2/lab/nginx/tags/list 含 alpine
PASS: 本地存在镜像 localhost:5000/lab/nginx:alpine
PASS: lab08-registry 挂载 volume lab08-data
PASS: volume lab08-data 存在

SCORE: 8/8
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| push 报 `http: server gave HTTP response to HTTPS client` | 用了非 localhost 地址且未配 insecure-registries | daemon.json 加 insecure-registries 后重启 docker，或给 registry 上 TLS |
| push 报 no basic auth credentials | registry 配了认证而本地未 `docker login` | `docker login localhost:5000`（本实验未开认证，不涉及） |
| `/v2/_catalog` 404 | 打的是老镜像 `registry:2.7` 之前的 API 或路径拼错 | 用 `registry:2`；路径必须是 `/v2/_catalog` |
| 删除镜像 API 405 | 默认未开启删除 | 启动时加 `-e REGISTRY_STORAGE_DELETE_ENABLED=true` |
| 磁盘只涨不掉 | registry 不会自动 GC | 上面环境变量 + `/bin/registry garbage-collect /etc/docker/registry/config.yml` |
| 其他节点 pull 失败 | 只有本机信任 localhost | 各节点 daemon.json 都加 insecure-registries，指向 registry 的对外 IP |

## 清理（保留终态供复查，彻底清理用）

```bash
# [Ubuntu VM]
# docker rm -f lab08-registry && docker volume rm lab08-data
# docker rmi localhost:5000/lab/nginx:alpine localhost:5000/lab/hello:1.0
```

## 延伸阅读

- Docker Registry 官方文档（部署与配置）：https://docs.docker.com/registry/
- OCI Distribution Spec（Registry HTTP API v2）：https://github.com/opencontainers/distribution-spec/blob/main/spec.md
- 测试 insecure registry：https://docs.docker.com/reference/cli/daemon/#insecure-registries
