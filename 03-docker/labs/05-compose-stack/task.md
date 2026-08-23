# Lab 05 · Compose 三服务栈：nginx + redis + app

> 难度：★★★ ｜ 考点：Docker Compose / 服务编排（CKA 应用部署基础） ｜ 前置：lab 03、lab 04 ｜ 预计 40~50 分钟

## 场景

你要在一台 VM 上部署一个小型演示应用：前端 `web`（nginx 反代）暴露在宿主机 8085 端口，后面是自研 `app`（Python HTTP 服务），`app` 依赖 `redis` 做后端探活。团队约定：所有服务声明在一个 `compose.yaml` 里，服务间一律用**服务名**通信（不写 IP），redis 与 app 都要配 healthcheck，`web` 必须等 `app` 健康后才启动。这套"服务发现靠 DNS、依赖关系靠 healthcheck"的模式正是 Kubernetes Service + readinessProbe 的微缩版。

## 任务清单

1. 建工作目录 `~/lab05-stack`，编写 `app.py`：监听 8000；`GET /` 返回 `hello from app`；`GET /redis-ping` 连接主机名 `redis` 的 6379 端口执行 PING，返回 `PONG`；`GET /healthz` 返回 `ok`。
2. 编写 `requirements.txt`（`redis==5.0.8`）与 `Dockerfile`（基于 `python:3.12-alpine`，不要把缓存打进层里）。
3. 编写 `nginx.conf`：把 `/` 反代到 `http://app:8000`。
4. 编写 `compose.yaml`：三个服务 `redis`（redis:7-alpine）、`app`（build 本地 Dockerfile）、`web`（nginx:alpine，发布 `8085:80`，只读挂载 nginx.conf）；redis/app 配 healthcheck，app `depends_on` redis（`service_healthy`），web `depends_on` app（`service_healthy`）。
5. 用项目名 `lab05` 启动：`docker compose -p lab05 up -d --build`，观察启动顺序符合依赖约束。
6. 验证三条链路：宿主机 `curl localhost:8085/` 得到 `hello from app`（证明 web→app DNS+反代）；`curl localhost:8085/redis-ping` 得到 `PONG`（证明 app→redis DNS）；`docker compose -p lab05 ps` 三个服务均 `running (healthy)`。
7. 做一次破坏演练：`docker compose -p lab05 stop redis`，再 `curl localhost:8085/redis-ping` 观察 502，然后 `start` 恢复。

## 验收标准

- `docker compose -p lab05 ps` 显示 redis / app / web 三服务均运行且 redis、app 为 `running (healthy)`；
- 宿主机 `curl http://localhost:8085/` 返回 `hello from app`；
- 宿主机 `curl http://localhost:8085/redis-ping` 返回 `PONG`（服务名解析成功的端到端证据）；
- 容器 `lab05-app-1` 内能解析服务名 `redis`。

完成后运行判分脚本（与 `compose.yaml` 同目录）：

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：服务名怎么就通了？</summary>

`docker compose up` 会自动创建一个名为 `<project>_default`（这里是 `lab05_default`）的用户自定义 bridge 网络，三个容器全接进去——lab 03 已验证：自定义网络内 embedded DNS 按服务名解析。`docker compose -p lab05 exec app ping -c1 redis` 可以直接确认。
</details>

<details><summary>提示 2：depends_on 的长语法是什么？</summary>

短语法 `depends_on: [redis]` 只保证**启动顺序**；要等健康必须用长语法：

```yaml
depends_on:
  redis:
    condition: service_healthy
```
</details>

<details><summary>提示 3：app 的 healthcheck 用什么探测？</summary>

镜像里只有 python，没有 curl/wget。用标准库即可：

```yaml
test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz')"]
```
</details>
