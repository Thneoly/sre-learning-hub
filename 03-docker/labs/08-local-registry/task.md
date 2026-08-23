# Lab 08 · 起一个本地 registry:2 并完成 push/pull 闭环

> 难度：★★☆ ｜ 考点：镜像仓库 / insecure registry（CKA 集群排障常见环节） ｜ 前置：lab 01、lab 02 ｜ 预计 20~30 分钟

## 场景

内网环境访问不了 Docker Hub，你需要在这台 VM 上起一个私有镜像仓库，供后续 kubeadm 集群拉镜像做离线演练。要求：registry 数据落在 named volume（重启不丢）、服务开机自起、push/pull 闭环可用，并且能用 Registry HTTP API v2 查到仓库目录——这个 API 也是你以后写镜像巡检脚本（列 tag、查 digest、比对 digest 防"latest 漂移"）的基础。

## 任务清单

1. 创建 volume `lab08-data`，启动容器 `lab08-registry`（镜像 `registry:2`，端口 `5000:5000`，`--restart always`，数据目录 `/var/lib/registry` 挂 volume）。
2. 验证 `curl http://localhost:5000/v2/` 返回 `{}`（API v2 存活探测）。
3. 把本机已有的 `nginx:alpine` 重新 tag 为 `localhost:5000/lab/nginx:alpine` 并 push。
4. 用 API 查目录与 tag：`/v2/_catalog` 应含 `lab/nginx`，`/v2/lab/nginx/tags/list` 应含 `alpine`。
5. `docker rmi localhost:5000/lab/nginx:alpine` 删除本地副本，再 `docker pull localhost:5000/lab/nginx:alpine` 拉回，验证闭环。
6. 查询该 tag 的 digest（`docker inspect --format '{{index .RepoDigests 0}}'`），再用 `curl -I` 的 `Docker-Content-Digest` 头交叉验证 API 侧 digest 一致。
7. 思考题验证：把 `lab02-multi`（lab 02 产物，若无则任意本地镜像）push 为 `localhost:5000/lab/hello:1.0`，然后 `curl /v2/_catalog` 确认仓库数变为 2。

## 验收标准

- `lab08-registry` 运行中、restart policy 为 `always`、发布 `5000->5000`；
- `curl http://localhost:5000/v2/` 返回 `{}`；
- `/v2/_catalog` 含 `lab/nginx`，其 tags 含 `alpine`；
- 本地存在镜像 `localhost:5000/lab/nginx:alpine`（pull 回来的）；
- volume `lab08-data` 存在。

完成后运行判分脚本：

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：为什么不用配 insecure-registries？</summary>

Docker daemon 默认把 `localhost`/`127.0.0.1` 开头的 registry 视为 insecure（跳过 TLS 与认证），本实验全在本机走 localhost，因此不需要改 daemon.json。一旦换成 VM 的对外 IP（如 172.30.30.x:5000），daemon 会拒绝 HTTP push——需要 `/etc/docker/daemon.json` 加 `"insecure-registries": ["172.30.30.x:5000"]` 后 `sudo systemctl restart docker`（生产正确做法是上 TLS 证书）。
</details>

<details><summary>提示 2：tag 的命名规则是什么？</summary>

完整引用 `registry.example.com:5000/repo/name:tag`：`主机[:端口]/路径:tag`。没有主机前缀（如 `nginx:alpine`）默认推 docker.io；有主机前缀才推对应 registry。push 的本质是把本地镜像分层 blob 逐层上传（已存在的层跳过），最后写 manifest。
</details>

<details><summary>提示 3：digest 和 tag 有什么区别？</summary>

tag 是可变的指针（随时可以指向新 manifest），digest 是 manifest 内容的 sha256，不可变。K8s 里 `image: repo/app@sha256:abc...` 就是钉死 digest 的用法——供应链安全（CKS supply-chain 一节）的基本功。
</details>
