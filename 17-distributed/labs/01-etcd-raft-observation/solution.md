# Lab 01 · 解答：etcd Raft 观测

> 本文档给出逐步操作与原理对应。先自己按 task.md 走，卡住再对照。
> 运行位置统一：装有 Docker 的 Ubuntu VM（`[任意节点]`，示例环境 user@172.30.30.50）。

## 0. 原理速览：你将看到什么

3 成员 etcd，多数派 = 2（含 Leader 自己）。本 lab 的两个实验对应 Raft 的两条硬约束：

```
实验 A（杀 Leader，剩 2/3）          实验 B（再杀一个，剩 1/3）
┌─────────┐ ┌─────────┐ ┌─────────┐   ┌─────────┐ ┌─────────┐ ┌─────────┐
│ etcd-1  │ │ etcd-2  │ │ etcd-3  │   │ etcd-1  │ │   ✝     │ │   ✝     │
│ follower│ │ Leader✝ │ │ follower│   │ 唯一存活 │ │ (killed)│ │ (killed)│
└─────────┘ └─────────┘ └─────────┘   └─────────┘ └─────────┘ └─────────┘
 心跳中断 → 选举超时(默认1s起)          写入需要 2/3 确认，只有 1/3
 → 剩余两员投票 → 新 Leader            → 永远凑不齐 → 全部写超时失败
 耗时 ≈ 1~3 秒（这就是停写窗口）        → 宁可停写，不可双主（防脑裂）
```

- 实验 A 的耗时数字就是"etcd 成员故障时的写不可用窗口"。K8s 控制面在这几秒里 `kubectl create` 会报错，但已存数据与 watch 连接不受影响。
- 实验 B 验证"丢失仲裁 = 停写"。这不是缺陷是特性：如果 1/3 还能写，等另外两台回来就会出现两个都自称提交过的 Leader（脑裂）。ZooKeeper 章的原话是"宁可停写，不可双主"（`../../../16-bigdata/06-zookeeper.md` 自测第 1 题，脑裂防护推导在其第 3 节）。

## 1. 起集群

```bash
# [任意节点] 建目录、写 compose.yaml（内容见 task.md 提示 1）
mkdir -p ~/dist-etcd && cd ~/dist-etcd
vim compose.yaml
docker compose -p dist-etcd up -d
docker ps --format '{{.Names}}\t{{.Status}}'
```

预期输出（3 个容器全部 Up）：

```
NAMES               STATUS
dist-etcd-3         Up 10 seconds
dist-etcd-2         Up 10 seconds
dist-etcd-1         Up 10 seconds
```

为什么用独立网络与前缀：`dist-etcd-net`（172.29.0.0/24）避开 redis 哨兵 lab 的 172.28.0.0/24；容器名统一 `dist-etcd-N`，与 `04-k8s-fundamentals` 里 kubeadm 集群的 `etcd-<hostname>` 静态 Pod 不会混淆。

镜像说明：官方发布在 `gcr.io/etcd-development/etcd`，本 lab 走 quay（`quay.io/coreos/etcd`），tag 以官方仓库为准；compose 里写成 `${ETCD_IMAGE:-...}`，拉不动时 `export ETCD_IMAGE=<替代镜像>` 覆盖即可，etcd 参数各发行版一致。

## 2. 找初始 Leader

```bash
# [任意节点] 定义本 lab 的两个函数（写进 ~/dist-etcd/env.sh，每个新 shell source 一次）
# etcdctl 从【还活着】的容器里发起：Leader 可能恰好是被杀的那个，逐个试
cat > ~/dist-etcd/env.sh <<'EOF'
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
  etcdctl_all endpoint status -w table 2>/dev/null | grep -w true | awk '{print $2}' | head -1
}
EOF
. ~/dist-etcd/env.sh

etcdctl_all endpoint status -w table
```

预期输出（列较多，节选关键列；谁是 Leader 由内部投票决定，你的环境不一定是 etcd-2）：

```
+--------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
|         ENDPOINT         |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | RAFT APPLIED INDEX | ERRORS |
+--------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
| http://dist-etcd-1:2379  | 8e9e05c52164694d |  3.5.17 |  20 kB  |   false   |   false    |         2 |         13 |                 13 |        |
| http://dist-etcd-2:2379  | 91bc3c398fb3c146 |  3.5.17 |  20 kB  |   true    |   false    |         2 |         13 |                 13 |        |
| http://dist-etcd-3:2379  | fd422379fda50e48 |  3.5.17 |  20 kB  |   false   |   false    |         2 |         13 |                 13 |        |
+--------------------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
```

```bash
# [任意节点] 记录初始 Leader
etcd_leader > ~/dist-etcd/leader-before.txt
cat ~/dist-etcd/leader-before.txt
# 预期: http://dist-etcd-2:2379（以你环境为准）
```

怎么找到 Leader 行：`grep -w true` 匹配 `IS LEADER` 列的 `true`（非 Leader 行是 `false`，不含独立的 true 词）；`-w table` 的表格行以 `|` 开头，所以 endpoint 在第 2 列，awk 取 `$2`。

## 3. 写入测试 key

```bash
# [任意节点] put 到非 Leader 成员也可以：follower 会转发给 Leader
etcdctl_all put dist/lab/probe v1
etcdctl_all get dist/lab/probe
# 预期:
# OK
# dist/lab/probe
# v1
```

对应读写路径：写 → 转发 Leader → WAL 先落盘 → 并行 AppendEntries → 2/3 确认 → commit → 应答（`../../../04-k8s-fundamentals/13-cluster-admin-and-etcd.md` 2.1 节的图）。客户端拿到 OK 时，这条写已持久化在多数成员上——这就是为什么后面剩 1/3 时**读旧值可以、写不行**。

## 4. 杀 Leader 并测量选举耗时

```bash
# [任意节点] 反推 Leader 容器名并 kill（SIGKILL ≈ 断电）
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

预期输出（毫秒数量级因环境而异，典型 1000~3000）：

```
1723
http://dist-etcd-1:2379
```

这 1~3 秒里发生了什么：follower 在心跳超时后进入候选者状态（etcd 选举超时默认 1s 起、随机化错开），先给自己投票再拉票，拿到 2/3 票数者成为新 Leader、term +1。运维读法：

- **这就是"杀一个 etcd 成员"的真实代价**：秒级停写，自动恢复，无人工介入。生产上滚动重启 etcd（升级、证书轮换）时，每个成员的停写窗口都这么长，所以要一台一台来——和 ZooKeeper "一次只动一台"的扩缩容纪律同源（`../../../16-bigdata/06-zookeeper.md` 第 6 节运维手册）。
- 旧 Leader 回来后不会"官复原职"，它以 follower 身份追日志。Raft 的 Leader 是**任期制**不是**终身制**。

```bash
# [任意节点] 选举后集群可写
etcdctl_all put dist/lab/probe v1b
# 预期: OK
```

## 5. 杀第二个节点：丢失仲裁

```bash
# [任意节点] kill 剩余两个成员中的任意一个（下面以 dist-etcd-1 为例；$NEW 是新 Leader，
# 杀新 Leader 或 follower 都行，结论一样：只剩 1/3）
docker kill dist-etcd-1

# 在唯一幸存的容器里执行（示例幸存者是 dist-etcd-3，换成你的）
docker exec dist-etcd-3 etcdctl --command-timeout=10s \
  put dist/lab/quorum lost 2>&1 | tee ~/dist-etcd/quorum-lost-error.txt
```

预期输出（原文记录，不同版本措辞略有差异）：

```
Error: etcdserver: request timed out
```

或 `context deadline exceeded`。两条都算"真实报错"，check.sh 认 `etcdserver` / `timed out` / `deadline` 关键字。

### 为什么写不进去

剩下的那台 etcd 进程还活着、数据也全，但它是 3 成员里的 1 个，凑不齐 2/3 确认，任何写都无法提交——请求挂到超时。**进程健康 ≠ 集群可服务**，判据永远是"在线成员数 ≥ 过半"。

### 读行为对比（task 第 7 条）

```bash
# [任意节点] 默认线性读：先要跟多数派确认"我还是 Leader"，同样失败
docker exec dist-etcd-3 etcdctl --command-timeout=5s get dist/lab/probe
# 预期: Error: etcdserver: request timed out

# 串行读：直接读本成员 KV，不要仲裁 → 能读到旧值
docker exec dist-etcd-3 etcdctl get dist/lab/probe --consistency=s
# 预期: 返回 dist/lab/probe / v1b
```

这就是"串行读快但可能旧、线性读强一致但多一次仲裁确认"的现场版（`../../../04-k8s-fundamentals/13-cluster-admin-and-etcd.md` 2.1 节）。面试问"etcd 挂了为什么 kubectl get 有时还能用"：apiserver 侧有 watch cache 兜底（`../../../04-k8s-fundamentals/02-architecture-and-control-loop.md` 2 节），是另一层缓冲。

### 排障话术

半夜收到批量 `etcdserver: request timed out`，第一反应不是"重启 etcd"，而是：

```bash
# [任意节点] 生产上是 ectl member list / endpoint status（kubeadm 环境的包装函数见 04-k8s-fundamentals/13 章 2.2 节）
etcdctl member list            # 数 started 成员数
etcdctl endpoint status -w table
```

在线成员 < (总数/2+1) → 仲裁丢失，正确动作是把**失联成员拉回来**（修网络/开机），而不是删成员重建。

## 6. 恢复：集群自愈

```bash
# [任意节点] 把两个被杀的容器拉回来
docker start "$LEADER_CONTAINER" dist-etcd-1    # 换成你实际杀掉的两个名字

# 轮询等待全部 healthy（几秒内完成）
until etcdctl_all endpoint health >/dev/null 2>&1; do sleep 1; done
etcdctl_all endpoint health
```

预期输出：

```
http://dist-etcd-1:2379 is healthy: successfully committed proposal: took = 1ms
http://dist-etcd-2:2379 is healthy: successfully committed proposal: took = 2ms
http://dist-etcd-3:2379 is healthy: successfully committed proposal: took = 1ms
```

```bash
# [任意节点] 写入恢复 + 数据仍在
etcdctl_all put dist/lab/probe v2
etcdctl_all get dist/lab/probe --print-value-only
# 预期: v2
```

自愈的机制：回归成员带着旧数据目录重启，向现任 Leader 报到，按 Raft 日志追平。期间仲裁已恢复（3/3），集群随时可写。**前提是数据目录还在**——容器没被 `rm`、磁盘没丢；真丢了成员就走 member remove/add + 数据重建，灾备靠 snapshot（`../../../05-cka/04-etcd-backup-restore.md`）。

## 7. watch：K8s list-watch 的底座

```bash
# [任意节点] 终端 2：盯着这个 key，输出同时存档
docker exec dist-etcd-1 etcdctl watch dist/lab/probe | tee ~/dist-etcd/watch-output.txt

# [任意节点] 终端 1：写新值
etcdctl_all put dist/lab/probe v3
```

终端 2 预期输出（随后 Ctrl-C 退出）：

```
PUT
dist/lab/probe
v3
```

为什么这个演示值得做：K8s 整个控制面的"感知"都建立在这条通道上——apiserver 把对象写进 etcd，kubelet/controller/scheduler 通过 watch 收增量事件，而不是轮询（`../../../04-k8s-fundamentals/02-architecture-and-control-loop.md` 第 6 节：list 一次全量 + 之后只收增量）。也顺带回答一个架构问题：**K8s 为什么选 list-watch 而不是 gossip 扩散状态**——控制面有唯一事实源（apiserver/etcd），增量推送 + resourceVersion 断点续传就能让所有组件收敛到同一视图；gossip 适合无中心的成员发现（如某些集群的故障检测），拿它扩散"期望状态"会让每个节点都成为事实源，冲突无从仲裁。etcd 的 MVCC revision 就是 resourceVersion 的来源，watch 断线重连时带着旧 revision 续读，不丢事件。

## 8. 判分与清理

```bash
# [任意节点] 在 check.sh 所在目录
chmod +x check.sh && ./check.sh
```

通过输出（11 项全部 PASS）：

```
PASS: dist-etcd-1/2/3 均在运行
PASS: docker 网络 dist-etcd-net 存在（bridge）
PASS: member list 显示 3 个成员且全部 started
PASS: endpoint health：3 个端点全部 healthy
PASS: 恰好 1 个成员是 Leader（IS LEADER=true 的行数为 1）
PASS: leader-before.txt 存在且为合法的成员 endpoint
PASS: election.txt 选举耗时为合理毫秒数（200ms~600s，实测 1723ms）
PASS: election.txt 新 Leader 与初始 Leader 不同（http://dist-etcd-2:2379 → http://dist-etcd-1:2379）
PASS: quorum-lost-error.txt 记录了真实的仲裁丢失报错原文
PASS: watch-output.txt 捕获到 PUT 事件且值为 v3
PASS: 恢复后 dist/lab/probe 可读，值为 v3（自愈成功）

SCORE: 11/11
```

（数值与 Leader 名以你的环境为准；watch 演示在判分前做过，最终值通常是 v3，check 对 v2/v3 都接受。）

```bash
# [任意节点] 清理（check 通过后再执行）
cd ~/dist-etcd && docker compose -p dist-etcd down -v --remove-orphans
docker network rm dist-etcd-net 2>/dev/null
```

## 9. 自测（面试怎么答）

<details><summary>1. 生产 3 节点 etcd 同时挂 2 台，kubectl get pod 还能用吗？create 呢？</summary>

get 大概率还能用：apiserver 有 watch cache，且部分 list 走缓存不落 etcd（`04-k8s-fundamentals/02` 2 节"读路径带缓存"）。create/更新一定失败——写需要多数派确认，1/3 凑不齐，报 `etcdserver: request timed out`。恢复动作是把失联成员拉回，不是删重建。
</details>

<details><summary>2. 选举耗时由什么决定？能调吗？</summary>

主要由选举超时（etcd 默认 1s 起，随机化拉开）决定，加上投票往返。调小超时能缩短停写窗口，但网络抖动下会频繁误选举（脑旋），ZK 章叫"选举震荡"（`16-bigdata/06-zookeeper.md` 6 节）。生产建议默认值 + 保证 etcd 磁盘 fsync 延迟（WAL 落盘慢会拖垮心跳，等价于变相超时）。
</details>

<details><summary>3. 为什么 3 节点能容忍 1 台故障，4 节点也是 1 台？</summary>

多数派 = N/2+1：3 → 2，4 → 3。容错数都是 ⌊(N-1)/2⌋ = 1。4 节点反而多一台待确认，扩容直接 3 → 5。这条纪律在 ZK（`16-bigdata/06-zookeeper.md` 第 6 节"3 → 4 反而降低可用性"）、Redis 哨兵（总数 ≥3 且奇数，`11-middleware/redis/02-persistence-and-ha.md` 6.2 节）、etcd 部署建议里是同一个定理。
</details>

<details><summary>4. 剩 1/3 时那台机器上的数据是"错"的吗？</summary>

不是错的，是不新的：它可能有未提交的本地日志，但已 apply 的状态机数据与多数派一致（本 lab 里你用 `--consistency=s` 读到了正确的 v1b）。分区恢复后它以现任 Leader 的日志为准追平。危险的不是这份数据，而是有人把它当单机 etcd 拿去用。
</details>

<details><summary>5. 如果用 5 节点，kill 几台会丢仲裁？停写窗口变长还是变短？</summary>

5 台多数派是 3，kill 3 台丢仲裁（容错 2 台，比 3 节点多一台）。单次选举窗口不变（还是选举超时量级），但滚动重启一遍的**总**不可用次数更多、每次都要严格一次一台——"更多副本"买的是容错数，不是更短的切换时间。
</details>

## 延伸阅读

- etcd 官方文档（architecture / tuning / disaster recovery）：https://etcd.io/docs/
- Raft 论文（In Search of an Understandable Consensus Algorithm）：https://raft.github.io/raft.pdf
- etcd 官方 tunnelled/本地集群实验说明：https://etcd.io/docs/latest/demo/
