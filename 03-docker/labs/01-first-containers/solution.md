# Lab 01 · 解答与讲解

> 前置：一台装有 Docker 的 Ubuntu 22.04/24.04 VM，当前用户已在 docker 组（`sudo usermod -aG docker $USER` 后重新登录），或命令前加 `sudo`。

## 第 1 步：拉取镜像

```bash
# [Ubuntu VM]
docker pull nginx:alpine
docker images nginx
```

预期输出（SIZE 约 40~50 MB）：

```
REPOSITORY   TAG       IMAGE ID       CREATED        SIZE
nginx        alpine    2e659e342ccf   x days ago    43.2MB
```

为什么用 alpine：同样的 nginx，debian 版约 190 MB。镜像越小，pull/push 越快，攻击面越小——这也是后面 lab 02 多阶段构建要继续放大的思路。

## 第 2 步：后台启动 web01

```bash
# [Ubuntu VM]
docker run -d \
  --name web01 \
  --restart unless-stopped \
  -p 8081:80 \
  nginx:alpine
```

参数解释：

| 参数 | 作用 |
|---|---|
| `-d` | detached 模式，容器在后台运行，不占用当前终端 |
| `--name web01` | 固定容器名，方便后续命令引用 |
| `--restart unless-stopped` | 退出后自动重启，但手动 stop 后不再拉起 |
| `-p 8081:80` | 宿主机 8081 映射到容器 80（宿主机端口:容器端口） |

restart policy 全家福（考试常考）：

| Policy | 容器退出后 | daemon 重启后 | 手动 stop 后 daemon 重启 |
|---|---|---|---|
| `no`（默认） | 不重启 | 不启动 | 不启动 |
| `always` | 重启 | 启动 | **也启动** |
| `unless-stopped` | 重启 | 启动 | 保持停止 |
| `on-failure[:N]` | 非 0 退出码才重启（可限次数） | 启动 | 保持停止 |

验证：

```bash
# [Ubuntu VM]
docker ps --filter name=web01 --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

预期输出：

```
NAMES   STATUS          PORTS
web01   Up 5 seconds    0.0.0.0:8081->80/tcp
```

## 第 3 步：验证访问与日志

```bash
# [Ubuntu VM]
curl -sI http://localhost:8081 | head -3
docker logs web01 | tail -5
docker logs -f web01   # 实时跟踪，Ctrl+C 退出
```

预期 `curl -sI` 输出包含：

```
HTTP/1.1 200 OK
Server: nginx/1.x.x
```

`docker logs` 的本质：daemon 收集容器 PID 1 的 stdout/stderr（json-file 或 local 驱动），落盘在 `/var/lib/docker/containers/<id>/<id>-json.log`。这就是为什么"日志必须打到 stdout"是容器化十二要素应用的要求——Kubernetes 里 `kubectl logs` 走的是同样的路。

## 第 4 步：pause / unpause

```bash
# [Ubuntu VM]
docker pause web01
docker ps --filter name=web01 --format "{{.Names}}: {{.Status}}"
curl -s --max-time 3 http://localhost:8081 || echo "curl 失败（超时/拒绝）"
```

pause 后 STATUS 变为 `Up x seconds (Paused)`；curl 表现为**超时**而不是 connection refused——因为 network namespace 还在，内核还在应答（接受 SYN 进 backlog），但没有任何用户态进程能被调度去处理请求。这是 freezer cgroup 冻结进程的结果，连接、IP、mount 全部原样保留。

恢复：

```bash
# [Ubuntu VM]
docker unpause web01
curl -sI http://localhost:8081 | head -1
```

再次返回 `200 OK`，且 nginx 的连接计数、worker 进程都没变——证明进程只是被冻结，没有重启。

## 第 5 步：一次性容器 side01

```bash
# [Ubuntu VM]
docker run -d --name side01 --restart no nginx:alpine sleep 60
sleep 65
docker ps -a --filter name=side01 --format "{{.Names}}: {{.Status}}   ExitCode={{.State}}"
docker inspect -f 'Status={{.State.Status}} ExitCode={{.State.ExitCode}} OOM={{.State.OOMKilled}}' side01
```

预期输出：

```
side01: Exited (0) x seconds ago   ExitCode=map[Status:exited ExitCode:0 OOMKilled:false]
Status=exited ExitCode=0 OOMKilled:false
```

退出码速查（排障时第一步看的东西）：

| ExitCode | 含义 |
|---|---|
| 0 | 正常退出 |
| 1 | 应用错误（未捕获异常等） |
| 125 | docker run 本身参数/环境错误 |
| 126 | 命令不可执行（权限） |
| 127 | 命令找不到（PATH/镜像里没这个二进制） |
| 137 | SIGKILL（128+9），常见于 OOM 或 docker stop 超时强杀 |
| 143 | SIGTERM（128+15），docker stop 正常路径 |

注意：`sleep 60` 覆盖了镜像的 CMD，所以 nginx 根本没启动，容器只活 60 秒——这正是"容器生命周期 = PID 1 生命周期"的体现。

## 第 6 步：stop / start 与 PID 变化

```bash
# [Ubuntu VM]
docker inspect -f 'PID before stop: {{.State.Pid}}' web01
docker stop web01
docker ps -a --filter name=web01 --format "{{.Names}}: {{.Status}}"
docker start web01
docker inspect -f 'PID after start:  {{.State.Pid}}' web01
curl -sI http://localhost:8081 | head -1
```

预期：stop 后状态 `Exited (0)`（nginx 收到 SIGTERM 优雅退出，默认宽限 10 秒，可用 `-t` 调整）；start 前后 `State.Pid` **不同**——容器内 PID 1 在宿主机上换了一个新进程，文件系统可写层保留、内存状态清零。这就是 pause（冻结现场）与 stop（销毁进程保磁盘）的本质区别：

```
                pause                 stop
 进程           冻结（仍在）          SIGTERM -> SIGKILL 退出
 namespace      保留                  销毁
 IP / 连接      保留                  丢失
 可写层         保留                  保留
 恢复代价       unpause 立即          start 重新执行 entrypoint
```

## daemon 重启验证（选做）

```bash
# [Ubuntu VM]
sudo systemctl restart docker
sleep 5
docker ps --format "{{.Names}}: {{.Status}}"
```

预期：`web01` 被自动拉起（`unless-stopped`），`side01` 仍保持 exited。再试一次：手动 `docker stop web01` 后 `sudo systemctl restart docker`，`web01` **不会**回来——这正是 `unless-stopped` 与 `always` 的分界线。做完记得 `docker start web01` 恢复终态再跑判分。

## 判分脚本结果

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

预期输出：

```
PASS: web01 处于运行状态
PASS: web01 的 RestartPolicy 为 unless-stopped
PASS: web01 发布端口 8081->80
PASS: curl http://localhost:8081 返回 nginx 欢迎页
PASS: side01 存在且状态为 exited
PASS: side01 的 RestartPolicy 为 no

SCORE: 6/6
```

## 清理（本机继续做后续 lab 时可保留 web01）

```bash
# [Ubuntu VM]
docker rm -f side01
# 如需彻底清理：docker rm -f web01
```
