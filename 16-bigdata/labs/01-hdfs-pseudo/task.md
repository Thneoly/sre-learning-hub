# Lab 01 · HDFS 伪分布式：块、小文件代价与 safemode

> 难度：★★☆ ｜ 考点：16-bigdata/01-hdfs（块机制 / NameNode 元数据 / safemode） ｜ 前置：03-docker 容器与资源限制 ｜ 预计 45~60 分钟

## 场景

你接手了一套即将下线前的 HDFS 验证环境：一台装有 docker 的 Ubuntu VM（10G 内存 / 余 25G 磁盘），要在上面用单容器把 NameNode + DataNode + ResourceManager + NodeManager 跑成伪分布式，回答值班时最常被问到的三件事：

1. 一个 200MB 的文件在 HDFS 里到底被切成几块、落在哪个 DataNode？
2. 业务一次性灌了 500 个小文件，为什么 NN 堆内存和 DataNode block report 量都跟着涨？
3. 集群卡在 safemode 时，读写到底哪些能做哪些不能做？怎么人为触发和解除？

对应生产语境：块大小影响 map 数与顺序读吞吐（`12-data-streaming` 里 Kafka 的分段文件是同一类"大顺序写"设计），NN 元数据全内存决定集群文件数上限，safemode 是 DN 掉线/块丢失后的第一现场。

```
                ┌────────────── docker 容器 hdfs-lab (3G 内存) ──────────────┐
  hdfs 客户端 → │ NameNode(元数据,全内存) ←── block report ── DataNode(存块) │
  (同容器内)    │ SecondaryNameNode(定期 checkpoint NN 编辑日志)              │
                │ ResourceManager ← NodeManager (YARN, 本 lab 只验证启动)     │
                └──────────────────────────────────────────────────────────────┘
```

## 任务清单

1. 启动容器 `hdfs-lab`（镜像 `apache/hadoop:3.3.6`，内存限 3G，映射 9870/8088 端口），并确认容器内 `hdfs` 命令可用。注意：该镜像只带 JRE，**没有 `jps`**（jps 是 JDK 工具），也没有 `which`——查进程用 `ps -ef | grep`。
2. 写入三份配置（`core-site.xml` 指向 `hdfs://localhost:9000`、`hdfs-site.xml` 设 replication=1、`yarn-site.xml` 单机模式），格式化 NameNode，以 daemon 方式启动 NN / SNN / DN / RM / NM，`ps -ef` 确认五个进程齐全（镜像未设 `HADOOP_HOME`，但 `HADOOP_CONF_DIR=/opt/hadoop/etc/hadoop` 已指向真实配置目录）。
3. `hdfs dfsadmin -report` 解读：Configured Capacity、DFS Remaining、Live datanodes 各是什么含义，容量数字与容器磁盘如何对应。
4. `dd` 生成 200MB 文件上传到 `/labs/big.bin`，用 `hdfs fsck -files -blocks -locations` 数出块数并解释为什么是这个数；观察两块的落点。
5. 批量造 500 个小文件上传 `/labs/small`，对比上传耗时与 fsck 的 Total files / Total blocks；用"每对象约 150B NN 堆"的经验值估算 500 文件、1 亿文件分别吃掉多少 NN 内存。
6. 触发 safemode：`hdfs dfsadmin -safemode enter` 后分别尝试写入和读取，记录两者行为；再 `-safemode leave` 恢复。
7. 清理（**跑完 check.sh 之后再做**）：删 HDFS 数据与本地临时文件、删容器。

## 验收标准

- `docker ps` 能看到 `hdfs-lab` 处于 Running；容器内 `ps -ef`（或 jps，若镜像带 JDK）五个进程齐全；
- `hdfs dfsadmin -report` 显示 `Live datanodes (1)`；
- `hdfs fsck /labs/big.bin` 的 `Total blocks (validated)` 为 2；`hdfs fsck /labs/small` 的 `Total files` 为 500；
- safemode 退出后 `hdfs dfsadmin -safemode get` 输出 `Safe mode is OFF`。

运行判分脚本（在装 docker 的 VM 上）：

```bash
# [任意节点]
cd 16-bigdata/labs/01-hdfs-pseudo
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：apache/hadoop 镜像该用哪个 tag</summary>

教材主线用 `apache/hadoop:3.3.6`（3.3.x 系列）。若该 tag 在 Docker Hub 上不可用，先 `docker pull apache/hadoop:3`（指向 3.x 最新），或到 Docker Hub 的 `apache/hadoop` 页面查当前可用的 3.3.x tag——具体 tag 以官方页面为准，本 lab 的命令对 3.3.x 任一版本通用。

</details>

<details><summary>提示 2：为什么要自己写配置文件，start-dfs.sh 不行吗</summary>

`start-dfs.sh` 走 SSH 到多台机器拉起进程，单容器里没有完整的 SSH 环境。更贴近运维真相的做法是逐个 `hdfs --daemon start <角色>`——它不依赖 SSH，而且和你将来排查"某个角色起不来"时的操作完全一致。配置文件的 `fs.defaultFS` 用 `localhost:9000`，容器内所有角色互访都走 localhost。

</details>

<details><summary>提示 3：fsck 看不到块位置</summary>

`hdfs fsck /labs/big.bin` 默认只给汇总；要逐块看落点必须加 `-files -blocks -locations`。输出里每个 `blk_` 开头的块后面跟的 `Datanode info` 就是副本所在节点——伪分布式只有一个 DN，所以两块全在它上面（生产 3 副本会分散到三个 DN）。

</details>

<details><summary>提示 4：格式化报错 or DN 起不来</summary>

`hdfs namenode -format` 只允许做一次：重复格式化会生成新的 clusterID，已存在的 DN 数据目录带着旧 clusterID 注册不上（表现为 `dfsadmin -report` 里 Live datanodes (0)）。修复：删掉 `/data/hdfs-tmp/dfs/data` 再重启 DN。这和生产上"误格式化 NN 导致全集群 DN 失联"是同一个机制。

</details>

<details><summary>提示 5：safemode 里写失败的具体报错长什么样</summary>

写入报 `put: Cannot create file/labs/new.txt._COPYING_. Name node is in safe mode.`（3.3.6 实测原文，核心是 `Name node is in safe mode`）——NN 只读，任何修改命名空间的操作（put/mkdir/rm）都被拒；读（`-cat`/`-get`/`fsck`）不受影响，因为元数据照常可查。这就是为什么"卡 safemode"的集群监控告警是"写失败率 100%"而不是全停。

</details>
