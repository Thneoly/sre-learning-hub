# Lab 01 · etcd Raft 观测：亲手制造一次选举与一次仲裁丢失

> 难度：★★☆ ｜ 考点：分布式理论-共识与复制（对应模块第 03 章） ｜ 前置：装有 Docker 的 Ubuntu VM（本文以 user@172.30.30.50 为例，下文 `[任意节点]` 均指这台 VM） ｜ 预计 40~60 分钟

## 场景

你是平台组的 SRE。生产 K8s 的控制面状态全在 etcd 里（`04-k8s-fundamentals/13-cluster-admin-and-etcd.md` 第 2 节讲过"写走 leader、提交看多数派、读默认线性"三句话），但那套 etcd 是 kubeadm 的静态 Pod，不能拿来随便杀。你要在演练 VM 上用 docker compose 起一套 **3 节点 etcd**，亲手完成两件事：

1. **杀 Leader**：记录从 `docker kill` 到新 Leader 产生的时间——这个数字就是"控制面不可写窗口"，升级/重启 etcd 成员前必须心里有数；
2. **杀到只剩 1/3**：验证"失去过半 = 集体停写"不是文档吓唬人，并拿到 put 的报错原文——下次半夜收到这个报错，你能立刻反应过来是仲裁丢了而不是"etcd 挂了"。

最后恢复两节点，确认集群自愈、写入恢复，再用 watch 感受一下 K8s list-watch 所依赖的那条推送通道。

Raft 的术语在这里不是算法课：**Leader**（唯一接受写的成员）、**选举超时**（follower 收不到心跳后发起投票，etcd 默认 1s 起）、**过半/多数派**（3 成员中 2 个，含 Leader 自己）。同样的机制你在两门课里已经见过化身：Redis 哨兵的 leader 选举要 majority 选票（`11-middleware/redis/02-persistence-and-ha.md` 6.2 节，quorum 只管判定下线、选举要过半，两者不是一回事）；ZooKeeper ZAB 的过半提交与脑裂防护（`16-bigdata/06-zookeeper.md` 第 3 节，自测里的原话是"宁可停写，不可双主"）。本 lab 把它落到 etcd 上操作一遍。

网络与命名约定（check.sh 依赖，请严格使用）：

| 对象 | 名字 | 说明 |
|---|---|---|
| compose 项目 | `dist-etcd` | `docker compose -p dist-etcd` |
| docker 网络 | `dist-etcd-net`（172.29.0.0/24） | 独立 bridge，避开 172.28.0.0/24（redis-ha-lab 在用） |
| 容器 | `dist-etcd-1` / `dist-etcd-2` / `dist-etcd-3` | 前缀 `dist-etcd`，避免与其它 lab 冲突 |
| 测试 key | `dist/lab/probe` | 值依次 v1 → v2 → v3 |
| 工作目录 | `~/dist-etcd/` | compose.yaml 与全部实验记录都放这里 |

实验记录文件（check.sh 要检查，一个都不能少）：

| 文件 | 内容 |
|---|---|
| `~/dist-etcd/leader-before.txt` | 初始 Leader 的 endpoint URL（一行） |
| `~/dist-etcd/election.txt` | 两行：第 1 行选举耗时（毫秒整数），第 2 行新 Leader 的 endpoint URL |
| `~/dist-etcd/quorum-lost-error.txt` | 失去过半后 put 的报错原文 |
| `~/dist-etcd/watch-output.txt` | watch 演示捕获到的事件输出 |

## 任务清单

1. 创建 `~/dist-etcd/compose.yaml`（内容见提示 1），`docker compose -p dist-etcd up -d` 启动 3 节点 etcd，`docker ps` 确认三个容器 Running
2. 定义 shell 函数 `etcdctl_all`（见提示 2），用 `endpoint status -w table` 找到 `IS LEADER` 为 true 的成员，把它的 endpoint URL 记入 `~/dist-etcd/leader-before.txt`（形如 `http://dist-etcd-2:2379`）
3. 写入测试 key `dist/lab/probe` 值为 `v1`，`get` 验证（注意：写到哪个成员都行，非 Leader 会转发）
4. **杀 Leader**：对初始 Leader 容器执行 `docker kill`（不是 `docker stop`——kill 是 SIGKILL，等价于断电；stop 会触发优雅退出），kill 前后各取一次 `date +%s%3N`，轮询 `endpoint status` 直到出现与旧 Leader 不同的新 Leader，把耗时毫秒数与新 Leader 的 endpoint URL 写入 `~/dist-etcd/election.txt`（格式见提示 3）
5. 从任一存活成员再写入一次 `dist/lab/probe` 值 `v1b`，确认选举后集群可写
6. **杀第二个节点**（`docker kill` 剩下两个中的任意一个）：此时 3 成员只剩 1 个，不足过半（2），执行 `put dist/lab/quorum lost` 并**把报错原文原样存入 `~/dist-etcd/quorum-lost-error.txt`**（提示 4）
7. 仲裁丢失期间的读行为观察（只记录不判分）：默认线性读 `get dist/lab/probe` 也会失败；改用 `--consistency=s`（串行读）能读到旧值——想清楚为什么
8. **恢复**：`docker start` 两个被杀的容器，轮询等待 `endpoint health` 全部 healthy，写入 `dist/lab/probe` 值 `v2` 并 get 验证——这就是"重启 etcd 成员后集群自愈"
9. **watch 演示**：终端 2 跑 `docker exec dist-etcd-1 etcdctl watch dist/lab/probe | tee ~/dist-etcd/watch-output.txt`；终端 1 `put dist/lab/probe v3`；回到终端 2 观察 PUT 事件与推送的值，确认后 Ctrl-C 退出
10. 运行 check.sh，`SCORE: 11/11` 后再执行提示 5 的清理（恢复后的集群留着跑 check，别提前拆）

## 验收标准

- `dist-etcd-1/2/3` 三个容器全部 Running，`dist-etcd-net` 存在；`member list` 3 个成员全部 started；`endpoint health` 3 个端点全部 healthy；恰好 1 个成员是 Leader
- `leader-before.txt` 与 `election.txt` 齐全：新 Leader 与旧 Leader 不同，选举耗时是一个合理的毫秒数（几百毫秒到几十秒之间）
- `quorum-lost-error.txt` 里能看到真实的失败报错（含 `etcdserver` 或超时类字样），不是你自己写的描述
- 恢复后 `dist/lab/probe` 可读，值为 `v2` 或 `v3`
- `watch-output.txt` 捕获到 `PUT` 事件与值 `v3`

## 提示（卡住再看）

<details><summary>提示 1：compose.yaml</summary>

镜像说明：etcd 官方发布在 `gcr.io/etcd-development/etcd`；本 lab 默认用 quay 上的 `quay.io/coreos/etcd`（版本 tag 以官方仓库为准），也可用 docker hub 上的官方/社区 etcd 镜像，参数完全相同。拉取走已配置的代理即可。

```yaml
# [任意节点] ~/dist-etcd/compose.yaml
x-etcd-common: &etcd-common
  image: ${ETCD_IMAGE:-quay.io/coreos/etcd:v3.5.17}   # tag 以官方仓库为准
  networks: [dist-net]

services:
  etcd1:
    <<: *etcd-common
    container_name: dist-etcd-1
    command:
      - etcd
      - --name=dist-etcd-1
      - --data-dir=/etcd-data
      - --listen-client-urls=http://0.0.0.0:2379
      - --advertise-client-urls=http://dist-etcd-1:2379
      - --listen-peer-urls=http://0.0.0.0:2380
      - --initial-advertise-peer-urls=http://dist-etcd-1:2380
      - --initial-cluster=dist-etcd-1=http://dist-etcd-1:2380,dist-etcd-2=http://dist-etcd-2:2380,dist-etcd-3=http://dist-etcd-3:2380
      - --initial-cluster-state=new
      - --initial-cluster-token=dist-etcd-lab
  etcd2:
    <<: *etcd-common
    container_name: dist-etcd-2
    command:
      - etcd
      - --name=dist-etcd-2
      - --data-dir=/etcd-data
      - --listen-client-urls=http://0.0.0.0:2379
      - --advertise-client-urls=http://dist-etcd-2:2379
      - --listen-peer-urls=http://0.0.0.0:2380
      - --initial-advertise-peer-urls=http://dist-etcd-2:2380
      - --initial-cluster=dist-etcd-1=http://dist-etcd-1:2380,dist-etcd-2=http://dist-etcd-2:2380,dist-etcd-3=http://dist-etcd-3:2380
      - --initial-cluster-state=new
      - --initial-cluster-token=dist-etcd-lab
  etcd3:
    <<: *etcd-common
    container_name: dist-etcd-3
    command:
      - etcd
      - --name=dist-etcd-3
      - --data-dir=/etcd-data
      - --listen-client-urls=http://0.0.0.0:2379
      - --advertise-client-urls=http://dist-etcd-3:2379
      - --listen-peer-urls=http://0.0.0.0:2380
      - --initial-advertise-peer-urls=http://dist-etcd-3:2380
      - --initial-cluster=dist-etcd-1=http://dist-etcd-1:2380,dist-etcd-2=http://dist-etcd-2:2380,dist-etcd-3=http://dist-etcd-3:2380
      - --initial-cluster-state=new
      - --initial-cluster-token=dist-etcd-lab

networks:
  dist-net:
    name: dist-etcd-net
    driver: bridge
    ipam:
      config:
        - subnet: 172.29.0.0/24
```

注意 `--initial-cluster` 三个成员必须完全一致，`--name` 与 `container_name` 保持同名（peer 间靠容器 DNS 互访）。
</details>

<details><summary>提示 2：etcdctl_all 函数与找 Leader</summary>

```bash
# [任意节点] 当前 shell 里定义（也可以写进 ~/dist-etcd/env.sh 每次 source）
# etcdctl 从【还活着】的容器里发起：Leader 可能恰好是被杀的那个，逐个试
etcdctl_all() {
  local c
  for c in dist-etcd-1 dist-etcd-2 dist-etcd-3; do
    if docker exec "$c" etcdctl \
      --endpoints=http://dist-etcd-1:2379,http://dist-etcd-2:2379,http://dist-etcd-3:2379 \
      "$@" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}
etcd_leader() {
  # IS LEADER 列为 true 的那一行：表格行以 | 开头，endpoint 在第 2 列
  etcdctl_all endpoint status -w table 2>/dev/null | grep -w true | awk '{print $2}' | head -1
}
```

`etcd_leader` 返回形如 `http://dist-etcd-2:2379`（注意取 `$2`：表格行以 `|` 开头，第 1 列是竖线本身）。写入记录：`etcd_leader > ~/dist-etcd/leader-before.txt`。
</details>

<details><summary>提示 3：测量选举耗时</summary>

```bash
# [任意节点] OLD 是初始 Leader 的 endpoint；容器名可由 endpoint 反推（dist-etcd-2 ↔ http://dist-etcd-2:2379）
OLD=$(cat ~/dist-etcd/leader-before.txt)
LEADER_CONTAINER=$(echo "$OLD" | sed 's|http://dist-etcd-\([123]\):2379|dist-etcd-\1|')

START=$(date +%s%3N)
docker kill "$LEADER_CONTAINER"

NEW=""
while :; do
  CAND=$(etcd_leader)
  if [ -n "$CAND" ] && [ "$CAND" != "$OLD" ]; then NEW="$CAND"; break; fi
  sleep 0.2
done
END=$(date +%s%3N)

printf '%s\n%s\n' "$((END - START))" "$NEW" > ~/dist-etcd/election.txt
cat ~/dist-etcd/election.txt
```

etcd 默认心跳 100ms、选举超时 1s 起（随机化），预期耗时在 1~3 秒量级。轮询别太快也不要 `docker exec` 打太猛，0.2s 一轮足够。
</details>

<details><summary>提示 4：丢失过半后的 put 报错</summary>

```bash
# [任意节点] 再杀一个存活节点（比如按上一步的 NEW 反推容器名），
# 然后在【唯一还活着的那个容器】里执行（下面以 dist-etcd-1 为例，换成实际幸存者）：
docker exec dist-etcd-1 etcdctl --command-timeout=10s \
  put dist/lab/quorum lost 2>&1 | tee ~/dist-etcd/quorum-lost-error.txt
```

注意 `2>&1 | tee`：报错走 stderr，漏了重定向文件里就是空的。报错原文形如 `etcdserver: request timed out` 或 `context deadline exceeded`（以实际版本为准），**原文记录，不要改写**。
</details>

<details><summary>提示 5：清理</summary>

```bash
# [任意节点] check 通过后再执行
cd ~/dist-etcd && docker compose -p dist-etcd down -v --remove-orphans
docker network rm dist-etcd-net 2>/dev/null
```

容器内 data-dir 随容器销毁；记录文件留在 `~/dist-etcd/` 无妨，重做 lab 前先删掉旧记录避免误判。
</details>

## 关联阅读

- 本模块理论对应章：Raft 全流程、Quorum 数学与"失仲裁先抢修一台别急着重建"的推论见 `../../03-consensus-and-replication.md` 第 2/4/5 节（本章实战演练与本 lab 同一套 etcd，本 lab 是它的故障注入完整版）
- 写路径/读路径/多数派的三句话总结与生产 etcd 运维：`../../../04-k8s-fundamentals/13-cluster-admin-and-etcd.md` 第 2 节
- K8s 控制面为什么押在 etcd 的 watch + MVCC revision 上（list-watch 而非轮询/而非 gossip 扩散）：`../../../04-k8s-fundamentals/02-architecture-and-control-loop.md` 第 6 节
- 同一个"过半"在 Redis 哨兵（quorum 判定 vs majority 授权）与 ZooKeeper ZAB（宁可停写不可双主）里的化身：`../../../11-middleware/redis/02-persistence-and-ha.md` 6.2 节、`../../../16-bigdata/06-zookeeper.md` 第 3 节
- etcd 备份恢复实操（本 lab 之外灾备唯一正解）：`../../../05-cka/04-etcd-backup-restore.md`
