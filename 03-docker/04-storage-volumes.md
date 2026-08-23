# 04 · 存储与数据卷：volume、bind mount 与 tmpfs

> 模块：03-docker ｜ 建议时长：1.5 小时 ｜ 关联认证：CKA-存储（PV/PVC 的前置直觉）/ CKS-系统加固（rootless 对存储路径的影响）

本章命令默认在**装有 Docker 的 Ubuntu 22.04/24.04 VM** 上执行，标注为 `[任意节点]`；涉及 kubeadm 集群的命令标注为 `[master]`。

## 学习目标

- 能解释 volume、bind mount、tmpfs 三种挂载方式在宿主机上的真实落盘位置、由谁创建、生命周期在哪一步结束
- 能操作 named volume 的创建、共享、备份与清理，并用 `docker inspect`、`mount`、`findmnt` 验证挂载关系
- 能解释 volume 的 copy-on-first-use 与 bind mount 的遮盖（masking）行为差异，说出 rprivate/rshared/rslave 各自的适用场景
- 能排查"容器删了数据还在 / 数据莫名丢失 / 挂载后容器内目录变空"三类故障

## 1. 为什么需要挂载：可写层的三个问题

容器的根文件系统是 overlay2 联合挂载。镜像层只读，所有写入落在最上面的可写层（upperdir）：

```
容器内看到的 / （overlay2 联合挂载）
        │
        ▼
┌─────────────────────────────────────────────────────┐
│ merged   ← 容器进程实际读写的统一视图                  │
├─────────────────────────────────────────────────────┤
│ upperdir(rw)   /var/lib/docker/overlay2/<id>/diff    │
│                首次修改已有文件 → 整文件 copy_up       │
├─────────────────────────────────────────────────────┤
│ lowerdir(ro)   镜像层，可堆叠多层                     │
├─────────────────────────────────────────────────────┤
│ workdir        overlay 内部使用，用户不可见            │
└─────────────────────────────────────────────────────┘
```

直接把数据写进可写层有三个问题：

1. **生命周期被容器绑架**：`docker rm` 删除容器时可写层一起被删，数据库文件随之蒸发。
2. **写放大**：修改 lowerdir 里的文件要先整份复制上来（copy_up），对数据库这类随机写大文件的负载性能很差。
3. **不可管理**：可写层藏在 `/var/lib/docker/overlay2/` 里，无法单独备份、迁移、限速。

三种挂载方式就是三条绕开可写层的通道：

```
        宿主机                                     容器内
┌──────────────────────────────┐
│ /var/lib/docker/volumes/     │  volume（dockerd 管理）
│   html/_data ━━━━━━━━━━━━━━━━┿━━▶ /usr/share/nginx/html
│                              │
│ /home/you/vol-lab/default.conf│ bind mount（用户指定路径）
│   ━━━━━━━━━━━━━━━━━━━━━━━━━━━┿━━▶ /etc/nginx/conf.d/default.conf
│                              │
│ （内存 + swap，无磁盘位置）    │  tmpfs
│                              ┿━━▶ /var/cache/nginx
└──────────────────────────────┘
```

用 `docker diff` 可以直观看到 copy_up：

```bash
# [任意节点]
docker create --name cow alpine sh -c 'echo patch >> /etc/apk/repositories'
docker start cow
docker diff cow
# 预期输出（C = Changed，整个文件被复制到了可写层）：
# C /etc
# C /etc/apk/repositories
docker inspect --format '{{.GraphDriver.Data.MergedDir}}' cow
docker rm cow
```

## 2. 三种挂载方式总览

| 维度 | volume（named） | bind mount | tmpfs |
|---|---|---|---|
| 宿主机位置 | `/var/lib/docker/volumes/<name>/_data` | 用户指定的任意路径 | 内存（swap 兜底），不落盘 |
| 由谁创建 | dockerd | 用户给出路径（`-v` 会自动建目录） | 内核 tmpfs 实例 |
| 生命周期 | 独立于容器，需显式 `rm`/`prune` | 宿主机文件系统说了算 | 容器停止即消失 |
| 首次挂载时镜像内容 | **复制**进 volume（copy-on-first-use） | **不复制**，直接遮盖 | 不复制 |
| 可移植性 | 高（驱动抽象，可换 NFS 等后端） | 低（依赖特定主机路径） | 高 |
| 典型场景 | 数据库、应用状态、需备份的数据 | 开发热更新、注入配置文件 | 秘密、临时缓存、敏感中间文件 |

写法上有两种等价语法，`-v/--volume` 简短，`--mount` 更明确（推荐脚本里用）：

```bash
# [任意节点]
# volume 的两种写法
docker run -v html:/usr/share/nginx/html nginx:1.27-alpine
docker run --mount type=volume,source=html,target=/usr/share/nginx/html nginx:1.27-alpine

# bind mount 的两种写法
docker run -v "$PWD/default.conf":/etc/nginx/conf.d/default.conf:ro nginx:1.27-alpine
docker run --mount type=bind,source="$PWD/default.conf",target=/etc/nginx/conf.d/default.conf,readonly nginx:1.27-alpine

# tmpfs 的两种写法
docker run --tmpfs /var/cache/nginx:size=32m nginx:1.27-alpine
docker run --mount type=tmpfs,destination=/var/cache/nginx,tmpfs-size=32m nginx:1.27-alpine
```

## 3. volume：交给 Docker 管的持久化

### 3.1 named 与 anonymous

```bash
# [任意节点]
docker volume create html                 # 显式创建 named volume
docker run -d --name web -v html:/usr/share/nginx/html nginx:1.27-alpine
docker volume ls                          # DRIVER=local, NAME=html
docker run --name anon-demo -v /anon alpine true   # 只写目标路径 → 匿名 volume
docker volume ls                          # 多出一长串 hash 命名的匿名 volume
docker rm anon-demo                       # 容器删了，匿名 volume 仍然留着
docker volume prune -f                    # 清理未使用的（新版默认只清匿名卷）
docker volume rm html                     # named volume 必须显式删
```

两条经验：

- **匿名 volume 是垃圾来源**：镜像里 `VOLUME /var/lib/mysql` 这类指令会在每次 `docker run`（不带 `--rm`）时生成一个匿名卷。`docker run --rm` 会随容器一起删掉匿名卷；定期 `docker volume prune` 兜底。
- **`docker rm -v` 只删匿名卷**，named volume 永远不会被 `rm -v` / `prune`（不带 `-a`）误删。`docker volume prune -a`（CLI ≥ 23.0）才会删未使用的 named volume，行为以你手上的官方文档为准。

### 3.2 copy-on-first-use：volume 独有的复制语义

把**空的** named volume 挂到镜像中已有内容的路径上，Docker 会把镜像里的内容复制进 volume：

```bash
# [任意节点]
docker volume create html
docker run --rm -v html:/usr/share/nginx/html nginx:1.27-alpine true
sudo ls /var/lib/docker/volumes/html/_data
# 预期输出：50x.html  index.html   ← 从镜像层复制而来
```

这个语义只为 volume 存在（可用 `--mount` 加 `volume-nocopy` 关闭），bind mount 永远不复制。设计动机见自测第 1 题。

### 3.3 volume 的"底层真相"：一个普通目录 bind 进容器

local 驱动的 volume 并不是独立文件系统，只是 dockerd 名下的目录，再以 bind 方式挂进容器：

```bash
# [任意节点]
docker run -d --name vtest -v html:/usr/share/nginx/html nginx:1.27-alpine
docker exec vtest grep ' /usr/share/nginx/html' /proc/self/mountinfo
# 挂载记录的源子路径字段是 /var/lib/docker/volumes/html/_data ——
# volume 本质 = 把宿主机目录 bind 进容器（alpine 无 findmnt，用 mountinfo 最可靠）
sudo findmnt /var/lib/docker/volumes/html/_data || echo "宿主机上不是挂载点，只是普通目录"
docker rm -f vtest
```

volume 也支持共享：两个容器挂同一个 named volume，或 `--volumes-from web` 复制挂载配置。换后端靠 volume driver，例如 NFS：

```bash
# [任意节点] 参考：需要一台可用的 NFS 服务器，无环境可跳过
docker volume create --driver local \
  --opt type=nfs \
  --opt o=addr=172.30.30.21,rw,nfsvers=4 \
  --opt device=:/export/backup \
  nfsbak
```

## 4. bind mount：把宿主机路径原样塞进容器

### 4.1 遮盖（masking）而不是复制

bind mount 挂到哪个路径，容器里那个路径的镜像内容就被**整体遮住**：

```bash
# [任意节点]
mkdir -p ~/bind-demo && cd ~/bind-demo
echo "from host" > index.html
docker run --rm -v "$PWD":/usr/share/nginx/html nginx:1.27-alpine ls /usr/share/nginx/html
# 预期输出只有 index.html —— 镜像里的 50x.html 被遮住了
```

### 4.2 两个行为差异要记牢

| 行为 | `-v` | `--mount type=bind` |
|---|---|---|
| 宿主机路径不存在 | **自动创建目录**（属主 root，常是坑） | 直接报错 |
| 单文件挂载 | 支持 | 支持 |

自动创建看起来贴心，实则会把"路径打错"变成"挂了个空目录"，生产脚本里用 `--mount` 让错误尽早暴露。

### 4.3 权限与 SELinux 标记

- 容器内进程以 root 运行时读写 bind 目录基本无感；切到非 root 用户后，宿主机目录属主/权限（第 06 章非 root 实践）立刻成为故障点。
- 挂载选项 `:z` / `:Z` 只在启用 SELinux 的发行版（RHEL 系）有意义，Ubuntu 默认不适用，见到别慌。

## 5. tmpfs：不落盘的内存挂载

- 数据在内存中，超出物理内存后写 swap，**容器停止即清零**。
- 不指定大小时，内核 tmpfs 默认上限是宿主机 RAM 的 50%。
- tmpfs 页计入容器 cgroup 内存配额——大 tmpfs 会把容器 OOM。

```bash
# [任意节点]
docker run --rm --tmpfs /scratch:size=16m alpine \
  sh -c 'dd if=/dev/zero of=/scratch/big bs=1M count=32 2>&1 | tail -1; df -h /scratch | tail -1'
# dd 在第 17MB 处报 "No space left on device"，df 显示 /scratch 挂载为 tmpfs、容量 16.0M
docker run --rm alpine sh -c 'mount | grep -c " /tmp "' || true
# 输出 0：容器里并不会自动有 tmpfs，必须显式声明
```

典型场景：注入只在本容器生命周期内有效的秘密文件、编译临时目录、任何"落盘即违规/即浪费"的中间数据。安全边界要清楚：tmpfs 防的是"磁盘残留"，不防进程读取。

## 6. mount propagation：rprivate / rshared / rslave

bind mount 与 volume 默认传播模式是 `rprivate`：容器内再执行 mount/unmount 不会影响宿主机，宿主机在该路径下新增挂载也不会进容器。内核可选模式：

| 模式 | 宿主机 → 容器 | 容器 → 宿主机 | 说明 |
|---|---|---|---|
| rprivate（默认） | 不传播 | 不传播 | 最安全，绝大多数场景够用 |
| rshared | 传播 | 传播 | 双向共享同一 peer group |
| rslave | 传播 | 不传播 | 只接收宿主机方向的挂载事件 |
| rshared/rslave 的非递归版 shared/slave | — | — | 不递归处理子挂载，几乎不用 |

需要显式开启的场景：容器内要创建挂载并让外部看到（容器里跑 systemd、存储插件），或反之宿主机热插挂载要进容器。K8s 文档 *Mount propagation* 一章的 Bidirectional ≈ rshared、HostToContainer ≈ rslave、None ≈ private，概念完全同源。

宿主机路径本身要先变成 shared 挂载点，实验才能成立：

```bash
# [任意节点] 需 root；实验后记得按步骤 4 清理
sudo mkdir -p /srv/prop-demo
sudo mount --bind /srv/prop-demo /srv/prop-demo   # 自绑定，使其成为独立挂载点
sudo mount --make-rshared /srv/prop-demo
findmnt -o TARGET,PROPAGATION /srv/prop-demo      # 预期显示 shared
```

对照实验——同样在宿主机挂 tmpfs，rshared 的容器看得见，默认 rprivate 的看不见：

```bash
# [任意节点] 步骤 2：起两个容器，只差 bind-propagation 参数
docker run -d --name prop-shared \
  --mount type=bind,source=/srv/prop-demo,target=/mnt/shared,bind-propagation=rshared \
  alpine sleep 300
docker run -d --name prop-private \
  --mount type=bind,source=/srv/prop-demo,target=/mnt/private \
  alpine sleep 300

sudo mkdir -p /srv/prop-demo/from-host
sudo mount -t tmpfs none /srv/prop-demo/from-host
sudo touch /srv/prop-demo/from-host/hello.txt

docker exec prop-shared ls /mnt/shared/from-host    # 输出 hello.txt —— 传播进来了
docker exec prop-private ls /mnt/private/from-host  # 同样输出 hello.txt（目录本身在同一文件系统）
docker exec prop-private mount | grep from-host     # 输出为空 —— 挂载事件没有传播
docker exec prop-shared mount | grep from-host      # 有 tmpfs on /mnt/shared/from-host 的记录
```

说明：目录能 `ls` 到是因为两个 bind 指向同一底层目录；区别在"新挂载事件"是否穿透——rprivate 容器里 `/mnt/private/from-host` 只是普通目录，不是 tmpfs 挂载点。反向（容器内 mount 让宿主机看到）同理需要 rshared，且容器内执行 mount 还需要 `--privileged` 或 `CAP_SYS_ADMIN`。

```bash
# [任意节点] 步骤 4：清理
docker rm -f prop-shared prop-private
sudo umount /srv/prop-demo/from-host
sudo umount /srv/prop-demo
```

## 实战演练：一次把三种挂载全部跑通

目标：起一个 nginx，同时使用三种挂载，逐项验证位置与生命周期。

```bash
# [任意节点] 步骤 1：准备 bind 文件
mkdir -p ~/vol-lab && cd ~/vol-lab
cat > default.conf <<'EOF'
server {
    listen 80;
    location / {
        root /usr/share/nginx/html;
        index index.html;
    }
}
EOF
```

```bash
# [任意节点] 步骤 2：三种挂载一次挂上
docker run -d --name web \
  -v html:/usr/share/nginx/html \
  -v "$PWD/default.conf":/etc/nginx/conf.d/default.conf:ro \
  --tmpfs /var/cache/nginx:size=32m \
  -p 8080:80 \
  nginx:1.27-alpine
```

```bash
# [任意节点] 步骤 3：验证三种挂载的真实位置
docker inspect --format '{{json .Mounts}}' web
# 预期看到三条记录：Type=volume（Name=html）、Type=bind（Source=.../default.conf）、Type=tmpfs
docker exec web grep -E 'nginx/html|conf.d|cache/nginx' /proc/self/mountinfo
# 每行格式：挂载ID 父ID 主:次 源子路径 挂载点 选项
# volume 行源子路径含 /var/lib/docker/volumes/html/_data，挂载点 /usr/share/nginx/html
# bind 行源子路径是 /home/<你>/vol-lab/default.conf，选项含 ro
# tmpfs 行挂载点 /var/cache/nginx，文件系统类型 tmpfs，选项含 size=32768k
sudo ls /var/lib/docker/volumes/html/_data     # 50x.html  index.html —— copy-on-first-use 的证据
docker exec web df -h /var/cache/nginx | tail -1   # 容量 32.0M 的 tmpfs
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/   # 预期 200
```

```bash
# [任意节点] 步骤 4：备份 volume（运维视角：数据不进容器也能打包）
docker run --rm -v html:/data -v "$PWD":/backup alpine tar czf /backup/html.tgz -C /data .
tar -tzf html.tgz | head
```

```bash
# [任意节点] 步骤 5：生命周期——容器没了，数据还在
docker rm -f web
docker volume ls                                # html 仍在列表中
sudo ls /var/lib/docker/volumes/html/_data      # 数据完好
docker volume rm html                           # 此刻数据才真正删除
docker run --name anon-demo -v /anon alpine true
docker volume ls                                # 出现匿名卷
docker volume prune -f && docker volume ls      # 匿名卷被清掉
```

### 映射到 Kubernetes

| Docker 概念 | K8s 对应 | 备注 |
|---|---|---|
| named volume | PV / PVC | local PV 在"节点本地目录"这点上最像 |
| 匿名 volume | emptyDir | 生命周期跟随 Pod |
| bind mount | hostPath / ConfigMap / Secret 挂载 | hostPath 有同名的 propagation 选项 |
| tmpfs 挂载 | emptyDir 且 `medium: Memory` | 同样计入容器内存 |
| volume driver（nfs 等） | StorageClass + CSI 驱动 | 把驱动选择交给集群管理员 |

```yaml
# [master] 文件：vol-demo.yaml —— K8s 里 tmpfs 的等价写法，详情见 04-k8s-fundamentals/07-storage.md
apiVersion: v1
kind: Pod
metadata:
  name: vol-demo
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "df -h /scratch && sleep 3600"]
    volumeMounts:
    - name: scratch
      mountPath: /scratch
  volumes:
  - name: scratch
    emptyDir:
      medium: Memory    # 等价于 docker --tmpfs
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| bind mount 挂上后容器内目录"变空" | 遮盖语义：宿主机空目录盖住了镜像内容 | 确认宿主机路径；把镜像内容先拷出来（或改用 volume 吃 copy 语义） |
| `-v /etc/foo/bar.conf` 后容器异常 | 路径打错被 `-v` 自动建成空目录 | 脚本改用 `--mount`，让错误立刻报出来 |
| 磁盘被匿名 volume 慢慢吃满 | `VOLUME` 指令 + 无 `--rm` 的临时容器 | 定期 `docker volume prune`；镜像里少写 `VOLUME` |
| 数据库放可写层，`docker rm` 后数据全丢 | 可写层生命周期 = 容器生命周期 | 数据永远放 named volume |
| 非 root 容器写 volume 报 Permission denied | volume 初次复制/挂载内容属主是 root | 入口脚本 chown，或建卷时预设属主（见第 06 章） |
| 宿主机新挂的盘在容器里看不到 | 默认 rprivate 不传播挂载事件 | 需要传播时显式 `bind-propagation=rslave/rshared` |

## 自测

1. 为什么 volume 首次挂载会把镜像内容复制进去，而 bind mount 刻意不复制？如果 bind mount 也复制，会破坏什么假设？

<details><summary>答案</summary>

volume 的语义是"这块存储归容器这一侧的应用所有"，首次初始化时把镜像里的种子数据带过去（如空库初始化脚本），符合"新卷即新数据目录"的直觉。bind mount 的语义是"宿主机路径是唯一事实来源"，开发者把源码目录挂进容器，期望看到的永远是宿主机当前内容；如果 Docker 往里复制/覆盖文件，等于工具反向污染了用户的源码目录，破坏"挂载是只读视角的延伸"这个信任假设。

</details>

2. 容器 A 以 `--volumes-from B` 启动后，B 被 `docker rm`，A 的数据会怎样？

<details><summary>答案</summary>

不受影响。`--volumes-from` 只是复制挂载配置，A 与 B 指向同一个 volume（本质是同一个宿主机目录），volume 的生命周期独立于任何容器。只有显式 `docker volume rm`（或 prune）才会删掉数据。

</details>

3. 默认 rprivate 为什么是安全默认值？如果默认改成 rshared，举一个会被破坏的场景。

<details><summary>答案</summary>

rprivate 保证容器内的 mount/unmount 事件被限制在容器的 mount namespace 里，宿主机和其他容器的挂载表不受影响。若默认 rshared，容器内任何组件（甚至被入侵后攻击者手工 `mount`）创建的挂载都会传播到宿主机挂载表，等于把"容器内文件系统操作"升级成"可修改宿主机全局状态"的权限面，隔离边界被击穿。

</details>

4. `--tmpfs /x:size=16m` 的容器往 `/x` 写 32MB 会发生什么？这和写 32MB 到可写层有什么本质区别？

<details><summary>答案</summary>

写满 tmpfs 后触发 ENOSPC（No space left on device），进程写失败，但容器不会因此被杀。区别一：tmpfs 占内存并计入 cgroup 内存配额，超的是容器 memory limit 时可能先触发 OOMKill；可写层占磁盘。区别二：tmpfs 随容器消失，可写层随 `docker rm` 消失但存在期间可用 `docker cp`/`docker diff` 取证。

</details>

5. `docker volume rm html` 报 "volume is in use"，怎么排查是哪个容器占着？

<details><summary>答案</summary>

用 `docker ps -a --filter volume=html` 直接列出引用该卷的容器（含已停止的）；或对疑似容器批量 `docker inspect --format '{{.Name}} {{range .Mounts}}{{.Name}} {{end}}' $(docker ps -aq)` 过滤。找不到容器仍报错时，检查是否被另一个 Docker 命名空间（如 rootless 实例、containerd 的 k8s.io 命名空间）持有。

</details>

## 延伸阅读

- 官方存储总览与三种挂载：https://docs.docker.com/engine/storage/
- volumes 细节与 volume driver：https://docs.docker.com/engine/storage/volumes/
- bind mounts 与 propagation 配置：https://docs.docker.com/engine/storage/bind-mounts/
- tmpfs 挂载：https://docs.docker.com/engine/storage/tmpfs/
- K8s 卷与 mount propagation 矩阵：https://kubernetes.io/docs/concepts/storage/volumes/#mount-propagation
- 内核共享子树（shared subtrees）文档：https://docs.kernel.org/filesystems/sharedsubtree.html

---

上一章：[03 容器网络](03-container-networking.md) ｜ 下一章：[05 Docker Compose](05-compose.md) ｜ 配套练习：`labs/04-volumes-persistence`
