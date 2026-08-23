# Lab 01 · 容器基本操作与生命周期

> 难度：★☆☆ ｜ 考点：CKA-容器运行时基础 / Docker 日常操作 ｜ 前置：无 ｜ 预计 20~30 分钟

## 场景

你刚拿到一台干净的 Ubuntu 22.04 VM，上面装好了 Docker。团队要求你在上面跑一个对内的静态页面服务 `web01`，并约定：

- 宿主机 8081 端口对外提供页面（容器内是 80）；
- VM 重启或 Docker daemon 挂掉后服务要能自己回来，但如果你**手动 stop** 了它，就不许它自己爬起来（避免维护窗口被干扰）；
- 另有一个一次性任务容器 `side01`，任务结束后应停留在退出状态，**不许**被自动重启。

在动手之前，你需要先想清楚 `pause` 与 `stop` 的区别——这两者都会让服务"不可用"，但内核层面的含义完全不同，这也是后续理解 Kubernetes livenessProbe 与容器状态机的第一步。

## 任务清单

1. 拉取 `nginx:alpine` 镜像。
2. 后台启动名为 `web01` 的容器：端口映射宿主机 `8081 -> 容器 80`，restart policy 为 `unless-stopped`。
3. 在宿主机用 `curl` 验证页面可访问，并查看容器日志。
4. 对 `web01` 执行 `docker pause`，观察 STATUS 变化与 curl 结果；随后 `docker unpause` 恢复。
5. 启动一次性容器 `side01`（同镜像，执行 `sleep 60` 后自然退出，restart policy 为 `no`），等它退出后确认其状态为 `Exited (0)`。
6. 对 `web01` 执行 `docker stop` 再 `docker start`，观察 PID 1 重启的证据（`docker inspect` 的 `State.Pid` 变化）。

## 验收标准

终态要求（`docker ps` / `docker ps -a` / `curl` 可验证）：

- `web01` 处于 `Up` 状态，restart policy 为 `unless-stopped`，端口映射 `0.0.0.0:8081 -> 80/tcp`；
- 宿主机 `curl -s http://localhost:8081` 返回 nginx 欢迎页；
- `side01` 存在且状态为 `Exited (0)`（或 `Exited`，退出码为 0）。

完成后运行判分脚本（与 task.md 同目录）：

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：restart policy 怎么选？</summary>

`always` 与 `unless-stopped` 的唯一区别在"手动 stop 之后 daemon 重启"的场景：`always` 会把手动停掉的容器也拉起来，`unless-stopped` 不会。本场景明确要求"手动 stop 后不许自己爬起来"，所以用 `unless-stopped`。一次性任务容器用默认的 `no`。
</details>

<details><summary>提示 2：pause 和 stop 在内核层差在哪？</summary>

`pause` 只是冻结该容器的所有进程（cgroup freezer，进程状态变为 D/S 不可调度），容器的 network namespace、IP、已建立的连接都还在；`stop` 是先发 `SIGTERM` 给 PID 1、超时后 `SIGKILL`，容器进程组退出，namespace 销毁，下次 `start` 是全新进程（PID 1 重新执行 entrypoint）。
</details>

<details><summary>提示 3：怎么证明 start 后是"新进程"？</summary>

`docker inspect -f '{{.State.Pid}}' web01` 在 stop 前后各看一次：PID 变了，说明容器内的 PID 1 在宿主机上对应的进程换了人。
</details>
