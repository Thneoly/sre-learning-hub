# 02 · MongoDB 副本集与分片

> 模块：中间件-MongoDB ｜ 建议时长：3 小时 ｜ 关联认证：—（CKA/CKS/PCA 无直接考点，但为 SRE 面试与线上排障核心知识）

## 学习目标

- 能解释副本集的 PRIMARY/SECONDARY 角色划分、选举的多数派原则，以及"为什么生产至少 3 个投票成员"
- 能操作：用 `rs.initiate` / `rs.status` / `rs.stepDown` 搭建与演练一套三节点副本集
- 能解释 oplog 的工作机制与"oplog 窗口"的意义，以及 w:1 与 w:"majority" 的安全性差异
- 能解释分片架构中 mongos / config server / shard 三层职责，以及好分片键的两条判据
- 能排查：根据 rs.status 与 oplog 位点判断复制延迟、脑裂残余与回滚风险

## 1. 副本集架构：一个可写的 PRIMARY

副本集（Replica Set）是 MongoDB 高可用的基本单位：**同一时刻最多一个 PRIMARY** 接受写，其余成员异步复制。客户端只配置副本集地址，驱动通过拓扑发现自动连 PRIMARY；PRIMARY 挂掉，剩余成员选出新 PRIMARY，应用无感切换。

```
             写 ──▶ PRIMARY (mongo-1)
                       │  每次写追加进 local.oplog.rs
                       │ 从库开 tailable cursor 拉取
          ┌────────────┼────────────┐
          ▼            ▼            ▼
     SECONDARY     SECONDARY      SECONDARY
     (mongo-2)     (mongo-3)     (mongo-4, hidden+delayed)
          │            │
          └── 读(readPreference=secondary) ──▶ 报表/分析流量
```

成员角色速查：

| 成员类型 | 是否投票 | 是否存数据 | 典型用途 |
|---|---|---|---|
| 普通成员 | 是 | 是 | 承接选举与数据 |
| priority=0 成员 | 是 | 是 | 永不竞选 PRIMARY 的冷备/异地成员 |
| hidden 成员 | 是 | 是 | 对驱动不可见，专供备份与监控查询 |
| delayed 成员 | 是 | 是 | 落后 N 小时，防误删（人祸回滚位） |
| arbiter 仲裁者 | 是 | **否** | 凑多数派票数（仅有 2 数据节点时） |

规模规则：投票成员最多 **7** 个，整套副本集成员（含非投票）最多 50 个。选举要求**多数派**（majority = ⌊N/2⌋+1），所以：

- 3 节点可容忍 1 个故障；
- 2 节点 + 1 arbiter 同样容 1 个，但 arbiter 不存数据，**只为省一台机器的数据盘**，官方已不推荐；
- **偶数个数据节点是浪费**：4 节点与 3 节点同样只容 1 个故障，还多花一台。

## 2. oplog：复制的唯一事实源

PRIMARY 把每次写（含 `rs.reconfig` 等管理操作）记录到 `local` 库的 `oplog.rs` 集合，SECONDARY 以 tailable cursor 持续拉取并在本地重放。oplog 是 **capped collection**（固定大小、环形覆盖）：

```
   oplog.rs (默认 5% 空闲磁盘, Linux 上 990MB~50GB)
   ┌───────────────────────────────────────────┐
   │ 最旧 oplog 条目            最新条目 ▶ 不断追加 │
   └▲──────────────────────────────────▲───────┘
     └── SECONDARY 尚未拉到这里          └── PRIMARY 当前位点
     如果"最旧"被覆盖到 SECONDARY 位点之前 → 该从库进入 RECOVERING,
     只能全量初同步 (initial sync)

   oplog 窗口 = 最旧条目时间戳 到 现在 的时间差
              = 从库最多能"掉线多久还能增量追平"
```

三条运维结论：

1. **写多库要主动调大 oplog**（`mongod --oplogSize` 或 replSetResizeOplog），窗口建议至少覆盖你最长的备份/维修时间（如 24~48 小时）。
2. oplog 条目是**幂等语义**（按 `_id` set 而非盲目 apply），所以重放安全；`$inc` 等操作落 oplog 时已展开为绝对值赋值。
3. 复制延迟看的是从库 `appliedOpTime` 落后 PRIMARY 多少——**秒数与条目数都要看**（`rs.printSecondaryReplicationInfo`）。

### initial sync

新成员或掉出窗口的成员执行全量初同步：克隆全量数据（含索引）→ 回放克隆期间的 oplog → 建索引 → 追平转 SECONDARY。生产加节点要避开业务高峰，克隆与建索引都是重 IO。

## 3. 选举与故障转移

选举协议是 protocolVersion 1（pv1，Raft 的工程变体；更早的 pv0 是 bully 风格的自研协议），核心规则：**获得多数派选票才能当选 PRIMARY**。触发选举的场景：PRIMARY 失联（心跳超时，默认约 10 秒）、`rs.stepDown()`、优先级变更等。

```
   3 节点, PRIMARY(mongo-1) 宕机:

   mongo-2 ──┐                    mongo-2 当选 PRIMARY(2/3 多数)
              ├─ 互相心跳 ──▶ 选举  写入恢复,总中断 ≈ 心跳超时+选举 ≈ 10~15s
   mongo-3 ──┘

   网络分区: [mongo-1] | [mongo-2, mongo-3]
   mongo-1 一侧只有 1/3,不够多数 → 降级为 SECONDARY(写拒绝)
   mongo-2 一侧 2/3 → 当选
   ⇒ 天然防脑裂:少数派一侧永远无法写
```

`priority` 决定票选偏好（数字大的优先），`priority: 0` 表示永不竞选。跨机房部署常把主机房设高优先级，保证主库稳定落在一个中心。

故障转移期间驱动自动重试（可结合 `retryWrites`），但**未确认到多数派的写**在切换边界上可能需要回滚：旧 PRIMARY 恢复后重新加入，若发现自己持有多数派没有的写，会把这些文档抽出来写进 `rollback` 目录的 BSON 文件，并回退到多数派状态。这正是 writeConcern 存在的意义。

## 4. writeConcern / readPreference / readConcern

三个维度决定"写多安全、读多新鲜、读写一致性"：

**writeConcern（写确认给谁）**——`w` 决定 PRIMARY 收到几个成员确认才算写成功：

| 写关注 | 语义 | 风险 |
|---|---|---|
| `w: 0` | 发出即忘 | 不知道成败，仅限可丢弃的日志类写入 |
| `w: 1`（默认） | PRIMARY 本地 journal 相关确认即可（是否等 journal 由 `j` 决定） | PRIMARY 立即宕机且未复制出去的写会被回滚 |
| `w: "majority"` | 多数派成员确认 | 不会被回滚，与 readConcern majority 配合是强一致基线 |

`j: true` 额外要求确认前先落本机 journal。重要业务写推荐 `{ w: "majority", j: true }`，并**始终配 `wtimeout`**（如 `wtimeout: 5000`），否则从库全挂时写请求会无限等待，把连接池拖死。

**readPreference（从谁读）**：

```
   primary              一切读走主(默认,最强一致)
   primaryPreferred     首选主,主没了才读从
   secondary            一律读从(报表专用)
   secondaryPreferred   优先从(读写分离常用)
   nearest              就近(低延迟优先,不管角色)
```

读从库必然读到旧数据（异步复制），报表、缓存预热等场景可接受；任何"写完立刻读要看到"的逻辑禁止用 secondary。

**readConcern（读到多新鲜）**：`local`（默认，本节点已有即可，可能是未扩散到多数派的）与 `majority`（只读已被多数派持久化的数据，不会读到会被回滚的写）。因果一致（读己之写、单调读）要 `readConcern majority` + 会话（causally consistent session）配合。

一张速查：

| 组合 | 效果 |
|---|---|
| w:1 + readPreference primary | 默认，性能好，切换窗口可能回滚 |
| w:"majority" + readConcern majority | 不会回滚不会脏读，金融基线 |
| w:1 + readPreference secondary | 最弱，仅离线分析可接受 |

## 5. 分片：水平扩展的边界方案

单副本集到瓶颈（单机写上限、数据量超出单机磁盘/内存）才上分片。架构三层：

```
                     应用/驱动
                         │ (连接串里全是 mongos)
                   ┌─────▼─────┐
                   │  mongos   │  无状态路由层,可任意多实例
                   └──┬─────┬──┘
              路由依据  │     │  shard key
            ┌──────────▼─┐ ┌─▼──────────┐
            │ shard 1    │ │ shard 2    │   每片 = 一个完整副本集
            │ (副本集)   │ │ (副本集)    │
            └────────────┘ └────────────┘
                   ▲             ▲
                   └─────┬───────┘
                   config servers (副本集)
                   存集群元数据:各片持有哪些 chunk、路由表
                   mongos 缓存路由表并定期刷新
```

- **config server** 是集群的"大脑"，自身必须是副本集，它的可用性等于集群可用性。
- 数据按 **shard key** 切成 chunk（默认约 128MB 一段）分布在各片；balancer 后台搬 chunk 保持均衡。
- 查询**带 shard key** → mongos 定向路由到目标片（targeted）；不带 → 广播所有片再聚合（scatter-gather），代价成倍。索引也一样：每片本地索引，没有全局索引。

好分片键的两条判据——**高基数**（取值足够多，否则切不出足够 chunk）与**高打散度**（写均匀分布，避免全打一片），再叠加访问模式（尽量让查询带 shard key）：

| 分片键 | 特点 |
|---|---|
| `{user_id: 1}` ranged | 同一用户聚集，按 user 查询高效；user_id 递增时写热点在最后一片 |
| `{user_id: "hashed"}` | 写均匀打散，range 查询失效变 scatter-gather |
| `{tenant_id, ...}` 复合 | 多租户标配：tenant 等值 + 高基数第二列 |

两个必须能一眼识别的分片病理：

- **单调递增键的写热点**：自增 id、时间戳做 ranged 分片键时，所有新写入永远落在"最后一片"，其余片闲置——要么换 hashed，要么复合一列高基数随机值打散。
- **jumbo chunk**：一个 chunk 内所有文档共享同一分片键取值（低基数键、或某键值下文档量巨大）时无法 split，超出大小上限后被标记为 jumbo，balancer 搬不动只能原地放置，数据与负载同时倾斜。解法是 `refineCollectionShardKey` 给键增补高基数后缀列（4.4+）或重选键——本质还是"基数/打散度"两条判据没满足的病。

分片键历史上不可改（5.0 起可用 `reshardCollection` 在线重分片，代价很大）；单文档 16MB 上限依旧，跨文档事务 4.2 起已支持但开销显著，建模上仍应优先靠内嵌规避。**分片不是免费的**：路由层、balancer、跨片查询复杂度都在收费，容量规划先确认副本集+读扩展真的不够。

## 实战演练

目标：15 分钟搭一套三节点副本集，亲手触发一次故障转移（lab 01 会完整重做一遍，这里是最小路径）。

```bash
# [Ubuntu VM] 起三个 mongod,同一 docker network,副本集名 rs0
docker network create mongonet
for i in 1 2 3; do
  docker run -d --name mongo-$i --net mongonet mongo:7.0 --replSet rs0 --bind_ip_all
done
```

```bash
# [Ubuntu VM] 在 mongo-1 上初始化(等容器就绪几秒)
docker exec mongo-1 mongosh --quiet "mongodb://localhost:27017/?directConnection=true" --eval '
rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "mongo-1:27017" },
    { _id: 1, host: "mongo-2:27017" },
    { _id: 2, host: "mongo-3:27017" }
  ]
})'
sleep 10

# 观察角色
docker exec mongo-1 mongosh --quiet "mongodb://localhost:27017/?directConnection=true" \
  --eval 'rs.status().members.forEach(m => print(m.name, m.stateStr))'
# mongo-1:27017 PRIMARY
# mongo-2:27017 SECONDARY
# mongo-3:27017 SECONDARY
```

```bash
# [Ubuntu VM] 写入并验证复制与写关注差异
docker exec mongo-1 mongosh --quiet "mongodb://localhost:27017/?directConnection=true" --eval '
db = db.getSiblingDB("app")
db.orders.insertOne({ _id: 1, v: "a" })
db.orders.insertOne({ _id: 2, v: "b" }, { writeConcern: { w: "majority", j: true } })
rs.printSecondaryReplicationInfo()   # 各从库落后秒数'

# 从 SECONDARY 直连读(必须 directConnection 或 readPreference)
docker exec mongo-2 mongosh --quiet "mongodb://localhost:27017/?directConnection=true" \
  --eval 'db.getSiblingDB("app").orders.countDocuments({})'
# 2
```

```bash
# [Ubuntu VM] 故障转移演练:让主库主动下台
docker exec mongo-1 mongosh --quiet "mongodb://localhost:27017/?directConnection=true" \
  --eval 'rs.stepDown(60)'    # 60 秒内不再竞选
sleep 5

# 谁当选了?写入是否恢复?
docker exec mongo-2 mongosh --quiet "mongodb://localhost:27017/?directConnection=true" \
  --eval 'rs.status().members.forEach(m => print(m.name, m.stateStr))
          db.getSiblingDB("app").orders.insertOne({ _id: 3, v: "c" })
          db.getSiblingDB("app").orders.countDocuments({})'
# mongo-2 或 mongo-3 成为 PRIMARY,写入成功,数量 3

# 观察旧主:已变为 SECONDARY,数据最终一致
docker exec mongo-1 mongosh --quiet "mongodb://localhost:27017/?directConnection=true" \
  --eval 'db.getSiblingDB("app").orders.countDocuments({})'
# 3
```

验证方法：stepDown 后 `rs.status()` 显示恰好一个 PRIMARY 且不是 mongo-1；三节点 count 一致。若想看"少数派不能写"，可 `docker stop mongo-2 mongo-3`（只剩 mongo-1 一个，1/3 不够多数），再插入会持续失败——记得把容器 `docker start` 回来。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 2 节点副本集，一个挂了另一个也不能写 | 剩 1/2 不够多数派，防脑裂设计 | 最少 3 个投票成员；临时解法是连 arbiter 救急 |
| 写请求全部挂起，连接数暴涨 | 从库全挂 + w:"majority" 无 wtimeout | 重要写**必须**带 wtimeout；监控复制健康度 |
| 新加的 SECONDARY 一直 RECOVERING | 掉线超过 oplog 窗口，增量追不上 | 调大 oplog；让其重新 initial sync |
| 报表读从库偶尔缺最新一条 | secondary 读的是异步旧数据 | 改读 primary，或接受最终一致；别在从库做"写后立读" |
| 旧主恢复后 rollback 目录出现 BSON 文件 | w:1 的写在切换边界未达多数派被回滚 | 重要写用 w:"majority"；回滚文件按需人工合并 |
| 分片后某些查询反而更慢 | 查询不带 shard key，全片 scatter-gather | 改查询模式或重选分片键；explain 看 SHARD_MERGE |
| 新 chunk 集中写在最后一片 | 单调递增的 ranged 分片键 | 用 hashed 分片键或复合打散 |

## 自测

1. 为什么 4 个数据节点的容错能力与 3 个相同？多出来的那台机器有什么用？

<details><summary>答案</summary>

多数派 = ⌊N/2⌋+1。N=3 时需要 2 票，容 1 故障；N=4 时需要 3 票，同样只能容 1 故障（挂 2 台剩 2 台不够 3 票）。多出的机器不能提升可用性，只能提升读容量与数据冗余副本数。要容 2 故障至少要 5 节点。
</details>

2. 主库宕机期间应用有一条 `w:1` 的写成功了，故障转移后这条数据去哪了？

<details><summary>答案</summary>

取决于它是否已被复制到多数派。若已复制到某个从库且该从库当选新主，写保留；若只存在于旧主本地（oplog 没来得及传出去），旧主重新加入时发现自己落后于多数派，会把这条多余写抽到 rollback 目录的 BSON 文件并回退状态，集群里不再可见。运维需要检查 rollback 文件决定是否人工恢复。这正是关键写要用 w:"majority" 的原因。
</details>

3. oplog 大小 10GB，写入速率 5MB/s，从库最长可以停机多久还能增量追平？停机更久会怎样？

<details><summary>答案</summary>

10GB / 5MB/s ≈ 2000 秒，约 33 分钟的窗口。超过后最旧的 oplog 条目被环形覆盖，从库恢复时发现自己需要的位点已不存在，进入 RECOVERING，只能全量 initial sync（克隆全部数据 + 重建索引），大库上要数小时且消耗大量 IO。生产上写流量大的库要把 oplog 调到能覆盖最长预计中断时间（备份窗口、版本发布等）。
</details>

4. 客户端报 "not master" 或连接在故障转移瞬间批量报错，是驱动坏了吗？

<details><summary>答案</summary>

不是。故障转移有 10 秒级窗口：心跳超时 + 选举期间没有 PRIMARY，期间的写必然失败。驱动会重新发现拓扑并连到新主；应用侧要做的两件事是开启 `retryWrites`（可重试写，驱动对新主自动重发）和对写入做幂等设计（如以业务键为 `_id`）。把故障转移当作"每几年一次的正常事件"设计，而不是异常。
</details>

5. 什么情况下应该选 hashed 分片键？它的代价是什么？

<details><summary>答案</summary>

分片键取值单调递增（如自增 id、时间戳）且写入量大时，ranged 分片会把所有新 chunk 堆在最后一片形成写热点，此时 hashed 分片键把写入均匀打散到所有片。代价是分片键失去范围语义：任何不带完整 hashed key 等值条件的范围查询都会退化为 scatter-gather（广播全片聚合），读放大显著。适合"写入吞吐优先、按 key 点查为主"的场景，不适合范围扫描型负载。
</details>

## 延伸阅读

- 官方手册 Replication：https://www.mongodb.com/docs/manual/replication/
- 官方手册 Replica Set Election：https://www.mongodb.com/docs/manual/core/replica-set-elections/
- 官方手册 Read Preference / Write Concern：https://www.mongodb.com/docs/manual/core/read-preference/ 、https://www.mongodb.com/docs/manual/reference/write-concern/
- 官方手册 Sharding：https://www.mongodb.com/docs/manual/sharding/
- 官方手册 Choose a Shard Key：https://www.mongodb.com/docs/manual/core/sharding-choose-a-shard-key/
