# Lab 04 · 解答与讲解

> 前置：Ubuntu VM 已装 Docker，当前用户可免 sudo 使用 docker；查看 `/var/lib/docker/volumes` 时需要 sudo。

## 第 1 步：反例——可写层随容器消失

```bash
# [Ubuntu VM]
docker run --name bad01 alpine sh -c 'echo "important data" > /tmp/lost.txt && ls -l /tmp/lost.txt'
docker rm bad01
docker run --rm alpine sh -c 'ls /tmp/lost.txt 2>&1 || echo "文件不存在（预期）"'
```

预期最后一次输出 `文件不存在（预期）`。原因：`> /tmp/lost.txt` 写进了容器的**可写层（upperdir）**，`docker rm` 删除容器时连可写层一起删掉。注意 `docker stop`/`start` 不丢（可写层还在），只有 `rm` 才丢。

## 第 2 步：named volume 的独立生命周期

```bash
# [Ubuntu VM]
docker volume create webdata
docker run --name w1 -v webdata:/webdata alpine sh -c 'echo "persisted-by-volume" > /webdata/index.html'
docker rm w1
docker run --rm -v webdata:/webdata alpine cat /webdata/index.html
```

预期输出：

```
persisted-by-volume
```

容器删了，数据还在——volume 的本体在容器之外：

```
  容器 w1（已删）          Docker 主机
  ┌─────────────┐        ┌──────────────────────────────────┐
  │ /webdata ───┼────────┼─▶ /var/lib/docker/volumes/       │
  │ (挂载点)     │  bind  │   webdata/_data/index.html      │
  └─────────────┘        └──────────────────────────────────┘
   可写层(已删)             volume 本体（独立生命周期）
```

## 第 3 步：bind mount 与双向可见

```bash
# [Ubuntu VM]
mkdir -p ~/lab04/html
echo '<h1>bind-mount-ok</h1>' > ~/lab04/html/index.html
docker run -d --name b1 \
  -p 8084:80 \
  -v ~/lab04/html:/usr/share/nginx/html:ro \
  nginx:alpine
curl -s http://localhost:8084/
```

预期返回 `<h1>bind-mount-ok</h1>`。验证双向可见（宿主机改、容器即时看到）：

```bash
# [Ubuntu VM]
echo '<h1>bind-mount-ok v2</h1>' > ~/lab04/html/index.html
curl -s http://localhost:8084/
# 立即变成 v2，无需重启容器
# 终态恢复 v1，保证判分通过：
echo '<h1>bind-mount-ok</h1>' > ~/lab04/html/index.html
```

验证 `:ro` 真的只读：

```bash
# [Ubuntu VM]
docker exec b1 sh -c 'echo x > /usr/share/nginx/html/try.txt' 2>&1 | head -1
# 预期: sh: can't create ... Read-only file system
```

## 第 4 步：--volumes-from 共享数据

```bash
# [Ubuntu VM]
docker volume create appdata
docker run -d --name dv1 -v appdata:/data alpine sleep infinity
docker run -d --name cv1 --volumes-from dv1 alpine sleep infinity
docker exec cv1 sh -c 'echo "written-by-cv1" > /data/report.txt'
docker exec dv1 cat /data/report.txt
```

预期输出 `written-by-cv1`：cv1 写、dv1 读，两个容器挂的是**同一个 volume 本体**（appdata）。`--volumes-from` 把 donor 的全部挂载复制给新容器，等价于对新容器再写一遍 `-v appdata:/data`。

Kubernetes 对照：

| Docker | Kubernetes |
|---|---|
| named volume | PV（由 CSI/local-provisioner 提供） |
| `-v webdata:/webdata`（声明式挂载） | PVC + Pod.volumeMounts |
| `--volumes-from dv1` | Pod 内多容器共享同一个 `volumes` 条目（emptyDir/PVC） |
| bind mount | hostPath（节点本地路径投影） |

Pod 内 sidecar 与主容器共享 volume（如 Filebeat 收集日志文件）就是 `--volumes-from` 思想在 K8s 里的形态。

## 第 5 步：找到 volume 本体

```bash
# [Ubuntu VM]
docker volume inspect webdata --format '{{.Mountpoint}}'
sudo ls -l "$(docker volume inspect webdata --format '{{.Mountpoint}}')"
sudo cat "$(docker volume inspect webdata --format '{{.Mountpoint}}')/index.html"
```

预期 Mountpoint 形如 `/var/lib/docker/volumes/webdata/_data`，宿主机直接能看到容器写入的文件。**不要**直接往这个目录手工塞数据当常规操作（绕过了 daemon 的管理），但排障时它是你确认"数据到底在不在"的最终手段。

对比记忆：

| 特性 | named volume | bind mount | 匿名 volume（`-v /data`） |
|---|---|---|---|
| 存储位置 | `/var/lib/docker/volumes/<name>/_data` | 任意宿主机路径 | 同 named，名字为随机 hash |
| 生命周期 | 独立，需显式 rm/prune | 跟随宿主机目录 | 跟随容器（`docker rm -v` 可带走） |
| 可移植性 | 好（换机器靠 volume driver/备份） | 差（依赖节点路径） | 差 |
| 典型用途 | 数据库数据、共享缓存 | 开发时代码热载、注入配置文件 | 避免数据写进可写层 |
| K8s 对应 | PV/PVC | hostPath | emptyDir（近似） |

## 第 6 步：volume 回收

```bash
# [Ubuntu VM]
docker system df -v | sed -n '1,3p;/Volumes space usage/,/^$/p' | head -12
docker volume ls
```

预期 `docker system df` 有单独一段 `Local Volumes space usage`。回收手段：

```bash
# [Ubuntu VM]
# docker volume rm webdata          # 删除指定 volume（有容器挂载时会拒绝）
# docker volume prune               # 删除所有未被任何容器引用的 volume（危险，先 ls 确认）
```

注意 `docker rm` 容器**不会**删 named volume——这就是"删容器放不下数据"与"磁盘被匿名 volume 悄悄塞满"两个相反问题的同一根源。生产上数据库容器务必用 named volume 并建立备份（`docker run --rm -v pgdata:/data -v $PWD:/backup alpine tar czf /backup/pg.tgz /data`）。

## 判分脚本结果

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

预期输出：

```
PASS: volume webdata 存在
PASS: volume appdata 存在
PASS: webdata/index.html 含 persisted-by-volume
PASS: b1 运行中且 bind mount 源为 lab04/html
PASS: curl http://localhost:8084 返回 bind-mount-ok
PASS: b1 的 bind mount 带 ro 选项
PASS: cv1 运行中且 VolumesFrom 含 dv1
PASS: cv1 写入的 report.txt 可从独立容器经 appdata 读出

SCORE: 8/8
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| bind mount 后 nginx 403 | 挂进去的目录/文件对容器内 uid 不可读 | `chmod`/`chown` 宿主机侧；nginx 需要路径上有 x 权限 |
| `-v data:/data` 宿主机找不到 `data` 目录 | 首段无 `/`，被识别为 named volume | bind mount 必须写绝对路径（`$(pwd)/data`） |
| `docker volume rm` 报 volume in use | 仍有容器（含 stopped）引用 | 先 rm 容器，或按名字精确排查 `docker ps -a --filter volume=webdata` |
| 删容器后匿名 volume 堆满磁盘 | 大量 `-v /path` 匿名卷残留 | `docker volume ls -f dangling=true` 后 prune |
| Windows/macOS 上 bind mount 权限怪异 | 文件经虚拟机共享层转译 | 生产语义以 Linux 为准；权限问题优先在 volume 里复现 |

## 清理（保留终态供复查，彻底清理用）

```bash
# [Ubuntu VM]
docker rm -f b1 cv1 dv1
# docker volume rm webdata appdata && rm -rf ~/lab04
```

## 延伸阅读

- Docker volumes：https://docs.docker.com/engine/storage/volumes/
- bind mounts：https://docs.docker.com/engine/storage/bind-mounts/
