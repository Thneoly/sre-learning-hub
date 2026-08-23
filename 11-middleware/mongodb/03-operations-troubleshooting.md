# 03 · MongoDB 运维与排障

> 模块：中间件-MongoDB ｜ 建议时长：3 小时 ｜ 关联认证：—（CKA/CKS/PCA 无直接考点，但为 SRE 面试与线上排障核心知识）

## 学习目标

- 能操作：用 `mongostat` / `mongotop` / `serverStatus` / `currentOp` / profiler 定位"慢在哪一层"
- 能解释 cache 驱逐与 read/write tickets 两个最常见的"MongoDB 自己限流自己"的瓶颈
- 能排查：按固定套路区分"缺索引 / cache 不足 / 复制延迟 / 连接风暴"四类问题
- 能解释 mongodump 与快照 + oplog 两种备份路线的适用边界，以及 PITR 的做法
- 能操作：安全地重建索引、回收磁盘空间、加节点与滚动升级的顺序
- 能操作：用 mongodb_exporter 把副本集接进 Prometheus，说出连接/复制/cache 三类必看指标；能解释 OTel 对 mongo 只能客户端埋点的原因

## 1. 可观测性：四件套先看什么

排障第一原则：**先分层，再深入**。MongoDB 的慢只有四个去处——没走索引、cache 不够、复制卡住、排队（tickets/连接）。

| 工具 | 看什么 | 类比 |
|---|---|---|
| `mongostat` | 每秒 insert/query/update、qr\|qw 队列、dirty/used cache、repl lag | top |
| `mongotop` | 每个集合的读写耗时分布 | iotop |
| `serverStatus()` | 全量指标：connections、tickets、wiredTiger.cache、opcounters | /proc 全家桶 |
| `db.currentOp()` | 此刻正在执行的操作（谁在慢） | SHOW PROCESSLIST |
| profiler（`system.profile`） | 慢操作历史与执行计划 | slow log + explain 合体 |

```bash
# [任意节点] mongostat 共输出 10 行、每 2 秒一行(练习环境未开认证;
#   生产环境加 -u <user> -p <pwd> --authenticationDatabase admin)
mongostat -n 10 2
# insert query update delete | getmore command | qr qw | ar aw | dirty used | res | repl  time
#   qr/qw: 等待读/写的客户端队列(>0 说明处理不过来)
#   ar/aw: 正在执行读/写的客户端(active)
#   dirty/used: WiredTiger cache 脏页占比/总使用占比(%)
```

```javascript
// [任意节点] serverStatus 的黄金指标
db.serverStatus().connections          // current/available: 连接水位
db.serverStatus().wiredTiger.concurrentTransactions
//   read/write 的 available+out: tickets,默认各 128
db.serverStatus().wiredTiger.cache
//   "tracked dirty bytes in the cache"   脏页字节
//   "bytes currently in the cache"        已用字节
//   "pages evicted"                       驱逐速度(持续暴涨=内存不够)
db.serverStatus().metrics.operation   // scanAndOrder(内存排序次数,应接近 0)
```

```javascript
// [任意节点] 开 profiler 抓慢查询(阈值毫秒)
db.setProfilingLevel(1, { slowms: 100, sampleRate: 1 })
// 之后在业务库:
db.system.profile.find().sort({ ts: -1 }).limit(5)
//   看 planSummary: COLLSCAN(全表扫) / IXSCAN{...}(走了哪个索引)
//   看 millis / docsExamined / nreturned
db.setProfilingLevel(0)   // 排障完关掉,profile 集合本身占资源
```

## 2. cache 驱逐与 tickets：两个隐形的刹车

### cache 驱逐（eviction）

WiredTiger cache 用到上限（默认 50% RAM）附近时，eviction 线程开始把冷页挤出、脏页刷盘腾地方。**脏页占比超过 20%** 或 cache 压力大时，应用线程会被拉去协助驱逐（eviction 在申请路径上同步发生），表现为**写入延迟整体抬升**：

```
   正常:  写 → cache → journal 确认(微秒~毫秒)
   压力:  写 → cache 满 → 应用线程帮忙刷脏页 → 才能确认(几十~几百 ms)
          mongostat 上 dirty 持续 >5%、used 持续 >95%、evicted 持续增长
```

处理顺序：先确认 working set 是否真的超内存（`db.stats().dataSize` 对比 cache 上限）——超了加内存/调大 `wiredTigerCacheSizeGB`；没超则通常是缺索引导致的全表扫描把冷数据反复搬进 cache，回到第 1 章的 EXPLAIN 修索引。

### tickets：读写各 128 个并发槽

每个读/写操作执行期间占用一个 ticket，默认读写各 128。CPU 或 IO 打满时 128 个槽全部在跑且变慢，新请求排队（`mongostat` 的 ar/aw 满格、qr/qw 堆积）。**tickets 变小不是它坏了，是底层变慢了**——先查慢查询与磁盘，不要先调 ticket 数（调大只是让排队换个地方）。极端场景（如全 SSD 且操作极轻）可适度调大，以官方文档为准。

## 3. 排障套路：四类问题对号入座

```
   慢/超时
     │
     ├─ 个别接口慢,其他正常 ──▶ explain / profiler: COLLSCAN? SORT?
     │                          → 建/改索引(ESR),消除 scanAndOrder
     │
     ├─ 整体延迟抬升,mongostat dirty/used 高
     │                          → cache 不够: 加内存或修全表扫描
     │                          → 或 checkpoint/eviction 抖动: 看磁盘 IOPS
     │
     ├─ qw 堆积,ar/aw 满格     → tickets 打满: 底层 CPU/IO 瓶颈,
     │                          currentOp 找出那批长操作
     │
     └─ 连接数暴涨/被拒        → 连接风暴: 应用重连风暴或 maxIncomingConnections
                                到顶;查连接来源(ss -tn)与驱动连接池配置
```

### 找出正在执行的长操作

```javascript
// [任意节点] 超过 5 秒的活跃操作
db.currentOp({
  active: true,
  secs_running: { $gte: 5 }
}).inprog.forEach(op =>
  print(op.op, op.secs_running + "s", op.ns,
        JSON.stringify(op.command).slice(0, 200)))

// 确认是失控查询后杀掉(先确认,再动手):
db.killOp(opid)
```

### 复制延迟

```javascript
// [PRIMARY] 各从库落后情况
rs.printSecondaryReplicationInfo()
// syncedTo 落后秒数;出现 "X secs behind" 持续增大即是延迟

rs.status().members.forEach(m =>
  print(m.name, m.stateStr,
        m.optimeDate,                    // 该成员已应用到的时间
        m.optimeDurableDate))            // 已持久化(journal)的时间
```

延迟的常见成因与解法：

| 成因 | 特征 | 解法 |
|---|---|---|
| 从库 IO/CPU 打满 | 从库自身 mongostat 高 | 把备份/报表挪到 hidden 成员；限制分析查询 |
| 主库写尖峰，从库单线程重放跟不上 | oplog 写入速率突增 | 拆批降速率；从库换更快磁盘 |
| 从库 initial sync | state=STARTUP2 | 等待；错峰做 |
| 网络带宽不足 | 跨机房延迟大 | 检查带宽；journal/oplog 压缩已默认开 |

## 4. 备份恢复：两条路线

| 路线 | 一致性 | 代价 | 适用 |
|---|---|---|---|
| `mongodump`/`mongorestore` | 副本集 + `--oplog` 可得时间点快照；单节点裸跑不保证一致 | 逻辑导出，大库极慢 | 小库、跨版本迁移 |
| 文件快照（LVM/云盘/EBS）+ journal | 天然一致（checkpoint+journal 原子） | 快，但要求快照原子性 | 生产标配 |

关键点：**备份副本集请对 hidden/延迟成员做，或用 `db.fsyncLock()` 冻结写入后再对文件系统做快照**：

```javascript
// [SECONDARY] 冻结:刷脏页并阻塞写,保证数据文件自洽
db.fsyncLock()
//   (此刻对该节点做 LVM/云盘快照)
db.fsyncUnlock()   // 完成后解锁,节点恢复复制
```

PITR（恢复到任意时间点）= 快照恢复 + 重放快照点之后的 oplog：

```bash
# [任意节点] 用 --oplogLimit 把从库 oplog 重放到坏操作之前
mongorestore --oplogReplay --oplogLimit '<epochSeconds>:<ordinal>' \
  --host ... /backup/dump
# oplogLimit 是"重放到这条之前停",位点取自坏操作的第一条 oplog
```

排障口径与 MySQL 的 binlog PITR 完全同构：**坏事件的起点就是停止位点**。误删集合的完整流程：停应用写入 → 快照恢复到临时副本集 → dump 出被删集合 → 回灌生产 → 校验计数。生产建议直接用文件快照 + oplog 全量归档，mongodump 只做小范围救火。

## 5. 空间回收与索引维护

```javascript
// [任意节点] 看库/集合的真实占用
db.stats()            // dataSize(逻辑) vs storageSize(压缩后) vs indexSize
db.orders.stats()

// 删除大量文档后回收空间:文件不收缩,但内部页可压缩重整
db.runCommand({ compact: "orders" })
// 4.4+ 对大多数读写不阻塞;在 PRIMARY 上执行必须加 force: true
// 仍建议低峰做,且逐个 SECONDARY 滚动执行
// 真正收缩文件需 dump/restore 或 initial sync 重建
```

滚动维护（重建索引、升级版本、加节点）的通用顺序，保证多数派始终在场：

```
   对每个 SECONDARY 轮流: 摘流量 → 维护 → 恢复 → 等追平
   PRIMARY 最后: rs.stepDown() 让位 → 降为旧主维护 → 回归
   约束: 任意时刻下线的投票成员 < 多数派,否则集群失写
```

加索引用**后台/滚动方式**：4.4+ 的 `createIndex` 默认优化的构建过程（不长期阻塞），大索引仍建议滚动法——单节点 isolated 构建，再让其余节点复制索引构建结果。

## 6. 监控接入与生态：exporter、Operator、OTel

### mongodb_exporter 必看指标

社区标准采集器是 percona/mongodb_exporter，默认监听 9216。对第 2 章的副本集环境：

```bash
# [Ubuntu VM] 起一个 exporter 指向副本集(接入 mongonet 才能用容器名解析)
docker run -d --name mongo-exporter --net mongonet -p 9216:9216 \
  percona/mongodb_exporter:0.40 \
  --mongodb.uri=mongodb://mongo-1:27017/admin --collect-all

# 若连接被拒,给副本集建监控只读账号后再放入 URI;生产还要求 TLS
curl -s localhost:9216/metrics | grep -E '^mongodb_(up|ss_connections)' | head
```

注意：exporter 0.20 前后是两套指标命名，接入后先 `curl /metrics` 对齐名字再写 PromQL，下面按 0.20+ 的命名举例。

| 关注点 | 对应来源 | 指标族 |
|---|---|---|
| 实例存活 | — | `mongodb_up` |
| 连接水位 | connections | `mongodb_ss_connections{conn_type=...}` |
| 复制健康 | rs.status().members | `mongodb_mongod_replset_member_health` / `..._my_state` |
| 复制位点 | members.optimeDate | `mongodb_mongod_replset_member_optime_date` |
| cache 压力 | wiredTiger.cache | `mongodb_ss_wt_*` 系列 |
| 读写速率 | opcounters | `mongodb_ss_opcounters_*` |

```promql
# 实例掉线
mongodb_up == 0

# 副本集成员不健康(health=0)
mongodb_mongod_replset_member_health == 0

# 连接使用率 current/(current+available),持续 >0.8 告警
sum by (instance) (mongodb_ss_connections{conn_type="current"})
  /
sum by (instance) (mongodb_ss_connections{conn_type=~"current|available"})
```

告警规则示例（指标名以 exporter 实际输出为准）：

```yaml
# [master] /etc/prometheus/rules/mongodb.rules(或经 PrometheusRule CRD 下发)
groups:
  - name: mongodb.rules
    rules:
      - alert: MongoDBInstanceDown
        expr: mongodb_up == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "MongoDB 实例 {{ $labels.instance }} 掉线"
      - alert: MongoDBReplicaSetMemberUnhealthy
        expr: mongodb_mongod_replset_member_health == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "副本集成员 {{ $labels.name }} 不健康"
```

### Percona MongoDB Operator

K8s 上跑 MongoDB 的主流路线是 Percona Operator for MongoDB（管理 Percona Server for MongoDB，协议兼容社区版）。它把第 5 节那张"滚动维护检查清单"产品化：拓扑编排、probe、内部认证 keyfile、备份（集成 Percona Backup for MongoDB，支持 PITR）、滚动升级全部由 CR 驱动。

```bash
# [master] 安装 operator(版本号以官方 GitHub release 为准)
kubectl apply -f https://raw.githubusercontent.com/percona/percona-server-mongodb-operator/v1.17.0/deploy/bundle.yaml
kubectl get pods --selector=name=percona-server-mongodb-operator
```

```yaml
# [master] 最小 CR:起一个 3 节点副本集 rs0(字段细节以 operator 版本的 cr.yaml 为准)
apiVersion: psmdb.percona.com/v1
kind: PerconaServerMongoDB
metadata:
  name: learn-rs
spec:
  crVersion: 1.17.0
  secrets:
    users: mongodb-users   # 需预建 secret,内含 MONGODB_USER_ADMIN_PASSWORD 等
  replsets:
    - name: rs0
      size: 3
```

排障入口双线并行：`kubectl get psmdb` 看状态与事件；进 Pod 后仍是本章的 mongosh 工具集——Operator 不改变 MongoDB 本身的排障逻辑，只是把"怎么部署"自动化了。

### OTel：对 MongoDB 的追踪

mongod 是被动方，自己不产生 trace，对它的分布式追踪**只能在客户端驱动埋点**。主流语言的 OTel instrumentation 都已覆盖：

| 语言 | 组件 | 覆盖范围 |
|---|---|---|
| Node.js | `@opentelemetry/instrumentation-mongodb` | 驱动全部命令 |
| Python | `opentelemetry-instrumentation-pymongo` | pymongo |
| Go | `otelmongo` | official mongo-go-driver |
| Java | javaagent 自动埋点 | 驱动自动打点，零代码 |

Span 遵循 database 语义约定：`db.system=mongodb`、`db.operation`（insert/find…）、`db.mongodb.collection`、`net.peer.name`。定位"一次慢接口到底慢在哪条 mongo 命令"时，OTel（客户端视角：谁发的、等了多久）与 profiler（服务端视角：扫了多少文档）正好互补——前者圈出嫌疑查询，后者给出执行计划实锤。

## 实战演练

沿用第 1 章的 `mongo-learn` 容器（`app.orders` 一万条）。

```bash
# [Ubuntu VM] 若容器已清场则重建并灌数
docker start mongo-learn 2>/dev/null || docker run -d --name mongo-learn -p 27017:27017 mongo:7.0 --bind_ip_all
docker exec mongo-learn mongosh --quiet --eval '
db = db.getSiblingDB("app")
if (db.orders.countDocuments({}) === 0) {
  db.orders.insertMany(Array.from({length: 10000}, (_, i) => ({
    _id: i + 1, user_id: Math.floor(Math.random() * 500),
    status: Math.floor(Math.random() * 4),
    created: new Date(Date.now() - Math.floor(Math.random() * 720) * 3600e3)
  })))
}'
```

```bash
# [Ubuntu VM] 终端 A:持续观察
docker exec mongo-learn mongostat -n 30 2
# 关注 dirty/used 与 qr/qw
```

```javascript
// [容器内] 实验 1:制造并抓住一次全表扫描
db.setProfilingLevel(1, { slowms: 50 })
db.orders.find({ user_id: 37 }).sort({ created: -1 })   // 此刻还没有索引
db.system.profile.find({}, { ns: 1, millis: 1, planSummary: 1, docsExamined: 1 })
  .sort({ ts: -1 }).limit(3)
// planSummary: COLLSCAN, docsExamined: 10000 → 实锤

db.orders.createIndex({ user_id: 1, created: -1 })
db.orders.find({ user_id: 37 }).sort({ created: -1 })
db.system.profile.find().sort({ ts: -1 }).limit(1)
// planSummary: IXSCAN{ user_id: 1, created: -1 }, docsExamined 降到 ~20
db.setProfilingLevel(0)
```

```javascript
// [容器内] 实验 2:观察 cache 与连接水位
db.serverStatus().wiredTiger.cache["bytes currently in the cache"]
db.serverStatus().wiredTiger.cache["tracked dirty bytes in the cache"]
db.serverStatus().connections
db.serverStatus().wiredTiger.concurrentTransactions   // tickets

// 实验 3:currentOp 里看自己(另开一个 mongosh 跑一个慢查询后)
db.currentOp({ active: true, secs_running: { $gte: 1 } })
```

```bash
# [Ubuntu VM] 实验 4:各集合读写耗时分布
docker exec mongo-learn mongotop -n 5 2
# 哪个集合读/写毫秒最高,配合 profiler 定位到具体查询
```

验证方法：实验 1 中加索引前后 `docsExamined` 从 10000 降到 20 左右、`millis` 显著下降；实验 4 的 mongotop 能看到 `app.orders` 占大头。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| mongostat dirty 长期 >20%、写延迟整体抬升 | 应用线程被拉去驱逐/刷脏 | 核对 working set 与 cache 上限；修全表扫描；升磁盘 IOPS |
| qr/qw 堆积但 CPU 不高 | tickets 满 + 底层 IO 等待 | currentOp 找长操作；别先调 tickets |
| `sort exceeded memory limit` 报错 | 内存排序超过 100MB 且未允许落盘 | 建覆盖排序的复合索引；必要时 `allowDiskUse`（治标） |
| mongodump 恢复后的库"少了最新数据" | 单节点裸 dump 无一致性 | 副本集 + `--oplog`，或直接文件快照 |
| compact 跑完磁盘没变小 | compact 只重整内部空间不收缩文件 | 接受复用；确需收缩用 initial sync 重建 |
| 升级时整个集群瞬间失写 | 同时重启了两个投票成员 | 滚动操作，多数派永不下线 |
| 连接数瞬间打满 | 应用重启引发重连风暴，或连接池无上限 | 驱动 maxPoolSize 收敛；前置 LB 排队；查慢操作是否拖住连接 |
| profiler 开着忘了关，磁盘被 system.profile 吃掉 | level 1 长期运行 | 排障结束 `setProfilingLevel(0)` 并 drop profile 集合 |
| 副本集一天内多次无故切主（选举震荡） | 网络抖动或节点资源打满，频繁触发心跳超时（默认 10s） | 看 rs.status 各成员 uptime/electionTime；修网络与主机负载；跨机房用 priority 固定主库机房 |
| 磁盘 100%，mongod 拒写甚至退出 | journal/日志/oplog 膨胀或数据超预期增长 | du 归因 dbPath、journal、log；轮转清理日志；扩容；事后重估 oplogSize |

## 自测

1. `mongostat` 显示 `ar=128 aw=0 qr=500 qw=0`，CPU 只用了 30%，问题最可能在哪？

<details><summary>答案</summary>

读 tickets（128）全部占用，读请求排队 500，但 CPU 不高——说明这 128 个在跑的读操作都卡在 IO 等待上（等 cache 未命中的页从磁盘读入），不是计算密集。方向是：磁盘 IOPS/延迟是否退化（HDD 混入、云盘限流），以及是否大量全表扫描把冷数据反复拉进 cache。用 profiler 确认查询计划，用 `iostat -x` 确认磁盘。
</details>

2. 一个报表查询每天凌晨把从库复制延迟拉到 30 分钟，报表又必须在从库跑，怎么破？

<details><summary>答案</summary>

把报表挪到专门的 hidden 成员（对驱动不可见、不被读流量选中、正常参与复制），或将一个成员设为 delayed + hidden 只做分析；其次给报表查询本身修索引降低 IO。如果延迟依然出现，考虑报表读"更旧的数据"是否可接受（delayed 本身就是故意的延迟）。核心思路是隔离：复制延迟的本质是"该成员把资源花在了别处"。
</details>

3. 为什么对运行中的单节点直接 `mongodump` 得到的备份可能不一致，而 LVM 快照 + journal 却一致？

<details><summary>答案</summary>

mongodump 逐集合导出耗时数分钟，期间写入持续发生，各集合对应的时间点不同（类比不带 --single-transaction 的 mysqldump）。LVM 快照是块设备层的原子瞬时视图，配合 WiredTiger 的 checkpoint+journal 机制：数据文件要么在 checkpoint 边界自洽，要么由 journal 回放补齐，恢复时等价于一次崩溃恢复，得到一致状态。若一定要逻辑备份，须在副本集成员上用 `--oplog` 记录导出期间的增量，恢复后重放补齐。
</details>

4. 磁盘告警 90%，你删掉了库里 40% 的文档，一周后磁盘还是 90%，为什么？该怎么办？

<details><summary>答案</summary>

删除只把文档标记为可复用空间（ WiredTiger 内部位图/页内空洞），文件大小不变，后续写入会优先复用这些空间——所以"不变"本身是正常且通常无害的。若确实要归还磁盘：低峰对该集合执行 `compact` 重整内部碎片（文件仍不收缩），彻底收缩需要 dump/restore 或让节点重新 initial sync。另外先确认这 40% 是数据而非 oplog/journal/日志膨胀——空间归因要用 `db.stats()` 与 du 对照。
</details>

5. 滚动升级 7 节点副本集（1 主 6 从），最多允许同时停几个？为什么？正确顺序是什么？

<details><summary>答案</summary>

多数派 = 4，因此最多同时停 7-4=3 个投票成员。但实践中应**一次只停一个**：逐台升级 SECONDARY（停 → 升级 → 起 → 等追平），全部从库完成后对 PRIMARY 执行 `rs.stepDown()` 让位，等新主就绪再升级旧主。一次一个的原因是留足余量：任何一台升级失败或起不来，集群仍保有 5/7 甚至更多成员，多数派与可用性都不受威胁。
</details>

## 延伸阅读

- 官方手册 Monitoring for MongoDB：https://www.mongodb.com/docs/manual/administration/monitoring/
- 官方手册 Evaluate Performance of Current Operations：https://www.mongodb.com/docs/manual/tutorial/evaluate-operation-performance/
- 官方手册 Database Profiler：https://www.mongodb.com/docs/manual/tutorial/manage-the-database-profiler/
- 官方手册 Backup and Restore：https://www.mongodb.com/docs/manual/core/backups/
- 官方手册 compact Command：https://www.mongodb.com/docs/manual/reference/command/compact/
- percona/mongodb_exporter：https://github.com/percona/mongodb_exporter
- Percona Operator for MongoDB：https://docs.percona.com/percona-operator-for-mongodb/
- OTel database 语义约定：https://opentelemetry.io/docs/specs/semconv/database/
