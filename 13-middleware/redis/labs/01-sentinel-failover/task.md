# Lab 01 · Redis 哨兵故障转移实战：一主二从三哨兵

> 难度：★★☆ ｜ 考点：中间件高可用（对应第 2 章持久化与 HA） ｜ 前置：装有 Docker 的 Ubuntu 22.04/24.04 VM ｜ 预计 40~60 分钟

## 场景

你是业务组的 SRE。线上的会话缓存是一个单实例 Redis，上周宿主机内核 panic 重启 20 分钟，期间所有登录态丢失，全站被动登出。复盘结论：必须有自动故障转移。你决定在演练环境先验证方案：用 Docker 起一套 **一主二从 + 三哨兵**，亲手杀掉主库，记录从宕机到恢复写入的总耗时，确认客户端跟随新主库重连，再把旧主拉回来验证它会自动降级为从库。

另一个遗留问题也要一并复现：上次大促时 Redis 打满 `maxmemory` 后写入全部报错，当时没人说得清原因。你要在演练环境制造内存打满，分别观察 LRU 淘汰和 noeviction 报错两种行为，拿到第一手现象。

网络约定（后面 check.sh 依赖这些名字与地址，请严格使用）：

| 容器 | 名字 | 静态 IP | 说明 |
|---|---|---|---|
| docker 网络 | redis-ha-net | 172.28.0.0/24 | 自定义 bridge 网络 |
| 主库 | redis-master | 172.28.0.11 | 被杀掉后重启 |
| 从库 | redis-replica1 / redis-replica2 | 172.28.0.12 / 172.28.0.13 | 其一会被提升为新主 |
| 哨兵 | sentinel1 / sentinel2 / sentinel3 | 172.28.0.21~23 | quorum=2 |
| 内存实验 | redis-mem | 172.28.0.31 | maxmemory 16mb + allkeys-lru |
| 内存实验 | redis-mem2 | 172.28.0.32 | maxmemory 8mb + noeviction |

## 任务清单

1. 创建 docker 网络 `redis-ha-net`（子网 172.28.0.0/24），按上表用静态 IP 启动 `redis-master`、`redis-replica1`、`redis-replica2`（镜像 `redis:7.2`，两个从库以 `--replicaof redis-master 6379` 启动）
2. 部署三个哨兵容器 `sentinel1/2/3`，监控名 `mymaster`，`quorum 2`、`down-after-milliseconds 5000`、`failover-timeout 30000`、`parallel-syncs 1`（提示：sentinel 配置文件需要可写目录，哨兵会回写状态）
3. 验证初始状态：`INFO replication` 确认 1 主 2 从且 `master_link_status:up`；`SENTINEL master mymaster` 的 flags 正常、`SENTINEL ckquorum mymaster` 通过；三个哨兵互相可见（`num-other-sentinels` 为 2）
4. 向主库写入 `session:1` 到 `session:100`（值为 `v1` 到 `v100`），并确认从库能读到
5. 用 `docker kill redis-master` 模拟主机宕机（注意不要用 `docker stop`），从 kill 时刻开始计时，轮询 `SENTINEL get-master-addr-by-name mymaster` 直到返回的地址不再是 172.28.0.11，记录总耗时；同时从任一哨兵的 `docker logs` 里找出 `+sdown`、`+odown`、`+switch-master` 等关键事件
6. 验证切换结果：新主 `role:master`，另一个从库 `master_link_status:up` 且指向新主；`session:100` 数据仍在；对新主写入 `probe:manual` 成功
7. `docker start redis-master` 拉回旧主，确认它被哨兵自动降级为从库（`role:slave`、`master_link_status:up`）
8. 模拟客户端重连：写一个每秒一次的循环，每次先问哨兵要 master 地址再 SET 一个 `probe:<时间戳>` key，全程打印时间戳与结果，观察不可用窗口有多长
9. 启动 `redis-mem`（16mb + allkeys-lru），灌入约 5 万个 300 字节的 key，观察 `INFO memory`、`INFO stats` 的 `evicted_keys` 与 `DBSIZE`，解释看到的现象
10. 启动 `redis-mem2`（8mb + noeviction）重复灌数据，观察写入报错与 `DBSIZE` 停在哪里，并用 `CONFIG GET`、`INFO memory` 完成一次"接到 OOM 报错后 5 分钟内定位原因"的排障推演

## 验收标准

- `docker ps` 显示 redis-master/redis-replica1/redis-replica2 与 sentinel1/2/3 全部运行中；当前 master 是两个 replica 之一（IP 不是 172.28.0.11），redis-master 以从库身份在线
- 三个哨兵对 master 地址的判断一致，`mymaster` 的 flags 中没有任何下线标记
- 新主上 `session:1` 的值仍为 `v1`，且可以正常写入新 key
- 你能给出三个数字：kill 到哨兵切换视图的秒数、客户端不可用窗口秒数、redis-mem2 被拒绝写入前写入的 key 数
- `redis-mem` 发生过淘汰（`evicted_keys > 0`）且 maxmemory 为 16777216；`redis-mem2` 策略为 noeviction 且内存已打满

运行 check.sh 通过（SCORE: 13/13）后再做清理。

## 提示（卡住再看）

<details><summary>提示 1：哨兵容器怎么起</summary>

`redis:7.2` 镜像自带 `redis-sentinel` 入口。给每个哨兵建一个目录放 `sentinel.conf`（监听 172.28.0.11 6379、quorum 2、down-after 5000），**挂载目录而不是单个文件**——哨兵会把识别到的从库与其他哨兵回写进配置文件，rename 覆盖单文件挂载会失败。启动命令形如 `docker run -d --name sentinel1 --network redis-ha-net --ip 172.28.0.21 -v ~/redis-ha/s1:/conf redis:7.2 redis-sentinel /conf/sentinel.conf`。
</details>

<details><summary>提示 2：怎么计时</summary>

`date +%s` 在 kill 前取一次，循环里每秒问一次 `SENTINEL get-master-addr-by-name mymaster`，地址变化时再取一次，相减即可。别忘了观察哨兵日志：`docker logs sentinel1 2>&1 | grep -E 'sdown|odown|switch-master|promoted'`。
</details>

<details><summary>提示 3：灌数据别用 for 循环逐条 SET</summary>

5 万条逐条 `docker exec ... redis-cli SET` 要跑好几分钟。生成 RESP 命令流后用 `redis-cli --pipe` 一次灌入（`seq` + `sed` 拼出 `SET key value` 行即可）。
</details>

<details><summary>提示 4：客户端循环的宿主</summary>

宿主机不在 docker 网络里，直接连 172.28.0.x 不通。把循环里的每次请求放到 `docker exec sentinel1 sh -c '...'` 里执行：容器内先用 `redis-cli -p 26379` 问出 master IP，再 `redis-cli -h $IP SET ...`。
</details>
