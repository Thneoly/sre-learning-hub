# Lab 04 · Volume vs Bind Mount 与 --volumes-from

> 难度：★★☆ ｜ 考点：CKA-存储（volume/bind mount/数据持久化） ｜ 前置：lab 01 ｜ 预计 30~40 分钟

## 场景

运维组的一个新手在容器里写了几十 GB 的审计日志，`docker rm` 之后数据全没了来找你哭。你要用实验向团队证明三件事：(1) 容器可写层随容器删除而消失；(2) named volume 的生命周期独立于容器，删容器不删数据；(3) bind mount 是把宿主机目录"投影"进容器，宿主机与容器双向可见。最后再用 `--volumes-from` 演示多个容器共享同一份数据——这是理解 Kubernetes PV/PVC 与 Pod 内多容器共享 volume 的前置课。

## 任务清单

1. 反例：启动 `bad01`（alpine）向 `/tmp/lost.txt` 写入内容，`docker rm -f` 后确认数据无处可寻（说明可写层已删）。
2. `docker volume create webdata`；启动 `w1` 将 `webdata` 挂到 `/webdata`，在容器内写入 `/webdata/index.html`（内容含 `persisted-by-volume`）；`docker rm -f w1` 后启动 `w2` 挂同一个 volume 读回该文件——数据仍在。
3. bind mount：宿主机建 `~/lab04/html/index.html`（内容含 `bind-mount-ok`），启动 `b1`（nginx:alpine，`-v ~/lab04/html:/usr/share/nginx/html:ro`，`-p 8084:80`），curl 验证返回自定义页面；在宿主机改文件内容，刷新 curl 立即生效。
4. `--volumes-from`：创建 donor 容器 `dv1`（挂 named volume `appdata` 到 `/data`，保持运行）；启动 `cv1` 用 `--volumes-from dv1`，在 `cv1` 内向 `/data/report.txt` 写入，再到 `dv1` 内读出——两个容器看到同一份 `/data`。
5. 用 `docker volume inspect webdata` 找到 Mountpoint，到宿主机路径直接查看文件，验证 volume 本体就在 `/var/lib/docker/volumes/` 下。
6. `docker system df -v` 观察卷占用，说明 volume 的回收要靠 `docker volume rm` / `docker volume prune`，rm 容器不会带上。

## 验收标准

- volume `webdata`、`appdata` 存在；
- 任何新容器挂 `webdata` 都能读到含 `persisted-by-volume` 的 `/webdata/index.html`；
- `b1` 运行中，宿主机 `curl http://localhost:8084` 返回含 `bind-mount-ok` 的页面，且 bind 源是 `~/lab04/html`；
- `cv1` 运行中且 `VolumesFrom` 包含 `dv1`。

完成后运行判分脚本：

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：volume 和 bind mount 的 -v 写法区别在哪？</summary>

`-v webdata:/webdata` 首段是 volume 名（无斜杠）→ named volume；`-v /home/me/html:/usr/share/nginx/html` 首段以 `/` 开头 → bind mount。`:ro` 后缀两者通用。判别规则只看第一段是不是绝对路径。
</details>

<details><summary>提示 2：--volumes-from 拿到的是什么？</summary>

donor 容器的全部 volume 挂载配置（匿名+具名）会被复制到新容器，指向**同一个** volume 本体。注意它挂的是"volume 数据"而不是"donor 的可写层"——donor 可写层里没进 volume 的文件，consumer 看不到。
</details>

<details><summary>提示 3：nginx 为什么用 :ro？</summary>

静态站点容器不需要写自己的内容目录；只读挂载能让"容器被入侵也无法篡改站点文件"成为确定事实（深度防御，CKS 同款思路）。
</details>
