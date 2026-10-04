---
title_juejin: '选举之后，数据去哪了：MongoDB rollback 目录里的失踪写入'
title_zhihu: '拿到多数派确认之前，写入不属于你：MongoDB 回滚文件从哪来'
description: 'MongoDB切主后旧主回队，未达多数派的w:1写入被抽进rollback目录。拆解丢失窗口、local/majority两级真相、回滚文件三种处置与oplog窗口过小的全量同步代价。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686472562230312970"
---

# 选举之后，数据去哪了：MongoDB rollback 目录里的失踪写入

> （构造典型案例，细节与数字已脱敏虚构）凌晨切主 15 秒完成，没有任何报警。第二天上午，库存对账差了 87 笔——DBA 翻遍三个节点，最后在旧主数据目录的 rollback 文件夹里把它们全找了出来：一排 BSON 文件，安安静静躺着，集群里谁也看不见它们。

## 一、时间线：写返回了成功，然后切了主

三节点副本集 rs0，mongo-1 是 PRIMARY，业务用的是 w:1 写关注。23:47:03，机房网络抖动，mongo-1 与另外两个节点之间断了——但心跳还没超时，mongo-1 自己不知道，继续接写。

| 时间 | 事件 | 后果 |
| --- | --- | --- |
| 23:47:03 | 网络分区：[mongo-1] ｜ [mongo-2, mongo-3] | mongo-1 不知情，继续以 w:1 接写并返回成功 |
| 23:47:13 | 心跳超时（默认约 10 秒），mongo-1 降级 | 分区期间的 87 笔扣减全留在旧主本地 |
| 23:47:18 | mongo-2 拿到 2/3 选票当选，写恢复 | 总中断约 15 秒，一切"正常" |
| 23:52 | mongo-1 重新入队 | 发现多数派没有的写 → 抽进 rollback 目录 |

最扎心的是：**全程没有一条写失败的报错**。那 87 笔写入在应用日志里全是成功——w:1 的确认只到旧主本地，而网络断的恰恰是 oplog 往外走的路。

## 二、机制：少数派回队，先交出多数派没有的写

选举协议（pv1，Raft 的工程变体）要求拿到多数派选票才能当 PRIMARY，多数派 = ⌊N/2⌋+1，天然防脑裂：分区时少数派凑不够票，降级为 SECONDARY，写直接被拒。

但还有另一半。旧主重新加入时，如果发现自己 oplog 里持有多数派不存在的写，它不会把这些写强推给集群，而是反过来：把多余文档抽出来，写进 rollback 目录的 BSON 文件，然后回退到多数派状态。这些写从此在集群里不可见，只活在那几个文件里。

一条 w:1 的写最后是"保留"还是"失踪"，取决于它当时被复制到了哪：

- 已复制到某个从库、且该从库一系当选新主 → 写保留，业务无感；
- 只存在于旧主本地、oplog 没来得及传出去 → 进 rollback 目录，集群里消失。

**回滚不是故障，是多数派一致性在收账**——冲突时真相以多数派为准，少数派的账挂起，等你来裁决。

## 三、丢失窗口：w:1 和 majority 差的那一瞬

writeConcern 决定"确认到谁才算写成功"：

| 写关注 | 确认到哪 | 切换边界风险 |
| --- | --- | --- |
| w:0 | 发出即忘 | 不知道成败，仅限可丢弃日志 |
| w:1 | PRIMARY 本地（是否等 journal 由 j 决定） | 未复制出去的写会被回滚 |
| w:"majority" | 多数派成员确认 | 不会被回滚 |

注意默认值有版本差异：4.x 及更早文档默认 w:1，MongoDB 5.0 起多数部署（含三节点纯数据副本集）的隐式默认写关注已是 w:"majority"——但驱动、连接串、ORM 每一层都可能改写它，重要写永远显式声明，别赌默认。

丢写的窗口，就是从"w:1 返回成功"到"这份数据复制到多数派"之间。平时只有一瞬，所以你几年都遇不上；一次网络分区或主库宕机，窗口里的所有写一起清算。**w:1 省下的那点延迟，是在拿切换窗口赌运气。**

重要写的标配是 `{ w: "majority", j: true, wtimeout: 5000 }`：j:true 要求确认前先落本机 journal；wtimeout 更不是可选项——从库全挂时 majority 永远凑不齐，不带超时的写请求会无限等待，把连接池整个拖死。

切主瞬间驱动报的错，交给 retryWrites 加幂等 _id 兜底——把故障转移当正常事件设计，而非异常。

## 四、readConcern：你读到的到底是谁的真相

写有分级，读也有。readConcern 决定节点返回给你的数据"新鲜到什么程度"：

- local（默认）：本节点已有的就返回——可能是还没扩散到多数派的写。分区期间直连旧主，你能读到最终被回滚掉的数据。
- majority：只返回已被多数派持久化的数据，保证不会读到将被回滚的写。

所以那 87 笔扣减在 23:47 到 23:52 之间是"薛定谔的写入"：readConcern local 且连对节点，读得到；readConcern majority，永远读不到。**local 读的是节点的现在，majority 读的是集群站得住的过去。**

读己之写、单调读这类因果保证，要 readConcern majority 配合因果一致会话才成立；而 readPreference 只要落到 secondary，读到的必然是异步旧数据——"写完立刻读要看到"的逻辑，禁止读从。

速查一张表：

| 组合 | 效果 |
| --- | --- |
| w:1 + 读 primary | 默认，性能好，切换窗口可能回滚 |
| w:"majority" + readConcern majority | 不回滚不脏读，金融基线 |
| w:1 + 读 secondary | 最弱，仅离线分析可接受 |

## 五、打开 rollback 目录：三种处置

先说清楚：MongoDB 不会替你自动恢复这些数据——回滚文件按需人工合并，恢复与否由人来裁决。为什么不做自动恢复，第八节展开。

【从业者判断】回滚文件在旧主 dbPath 下的 rollback/ 子目录（默认 /data/db/rollback），7.x 里再往下一层是集合 UUID 目录，文件名为 removed.<时间戳>.<序号>.bson；集合名不写在文件里，要 grep mongod 日志里的 "rollback file" 或按 info.uuid 反查，具体以官方文档为准。三种处置：

处置一：确认丢弃。判定这些写业务上可放弃（下游已重放、可由上游重建），归档留证后删除。【从业者判断】多数回滚文件最终走的是这条路。

处置二：手工回放。导出成 JSON 交给业务侧，按业务键幂等重放——幂等是硬前提，样板就在 oplog 自己身上：条目按 _id set 而非盲目 apply。

处置三：mongorestore 灌回。新版回滚文件不带命名空间信息，要逐文件显式指定目标库与集合；适合整批都要、且新主上没有同 _id 冲突的场景。

```bash
# [旧主节点·从业者判断，以官方文档为准] 默认 dbPath 为 /data/db
ls -lR /data/db/rollback/
# <集合UUID>/removed.<时间戳>.0.bson   ← 回滚文档按集合 UUID 分目录，文件名不含库与集合名

F=$(ls /data/db/rollback/*/removed.*.bson | head -1)   # 取第一个回滚文件
bsondump --quiet "$F"
# {"_id":40021,"sku":"A-7","qty":-3,...}   逐行 JSON，先验货

mongorestore --uri "mongodb://mongo-2:27017/?directConnection=true" \
  --db app --collection orders "$F"
# 逐文件指定目标库集合；已在新主存在的 _id 报错跳过（默认继续、不覆盖），不会二次扣减
```

顺序：先 bsondump 验货、判断业务影响，再选处置路径。**rollback 文件是数据库留给运维的裁决权，不是垃圾**——盲目删除等于替业务做了它不知道的决策。

## 六、oplog 窗口：另一条让节点"失踪"的路

数据会失踪，节点也会。oplog 是 local 库里的 capped collection（默认占 5% 空闲磁盘），环形覆盖：新条目从尾部追加，最旧的从头部被挤掉。

oplog 窗口 = 最旧条目到现在的时间差，也就是**从库最多能掉线多久还能增量追平**。一笔账：oplog 10GB、写入速率 5MB/s，窗口只有 2000 秒，约 33 分钟。

掉线超过窗口的从库，恢复时发现自己要的位点已被覆盖，进入 RECOVERING，只剩一条路：全量 initial sync——克隆全部数据、回放克隆期的 oplog、重建所有索引。大库上是数小时级的重 IO 工程，同步期间该成员不再是可接管的故障转移目标，集群冗余度从"容一故障"实际掉到"零容错"【从业者判断】。

运维上三件事：

1. 写流量大的库主动调大 oplog（--oplogSize 或 replSetResizeOplog），窗口至少覆盖最长备份/维修时间，常见量级 24~48 小时；
2. 复制延迟盯 rs.printSecondaryReplicationInfo，秒数与条目数都要看；
3. 防人祸留一手：delayed 成员落后 N 小时，误删时有回滚位。

**oplog 窗口是副本集后悔药的保质期，过期就得全量重来。**

## 七、亲手摸一次：15 分钟复现切主

```bash
# [Ubuntu VM] 三节点副本集最小路径
docker network create mongonet
for i in 1 2 3; do
  docker run -d --name mongo-$i --net mongonet mongo:7.0 --replSet rs0 --bind_ip_all
done
docker exec mongo-1 mongosh --quiet "mongodb://localhost:27017/?directConnection=true" --eval '
rs.initiate({_id: "rs0", members: [
  { _id: 0, host: "mongo-1:27017" },
  { _id: 1, host: "mongo-2:27017" },
  { _id: 2, host: "mongo-3:27017" }]})'
sleep 10
```

```javascript
// 进 mongo-1 的 mongosh 后执行：docker exec -it mongo-1 mongosh
// 对比两种写关注的确认路径
db = db.getSiblingDB("app")
db.orders.insertOne({ _id: 1, v: "a" }, { writeConcern: { w: 1 } })
// 显式 w:1：主库本地确认即返回（7.0 隐式默认已是 majority，验证 w:1 必须显式指定）
db.orders.insertOne({ _id: 2, v: "b" }, { writeConcern: { w: "majority", j: true, wtimeout: 5000 } })
// 多数派确认+落盘+超时，重要写标配
rs.printSecondaryReplicationInfo()   // 各从库落后秒数
```

```bash
M='mongodb://localhost:27017/?directConnection=true'
docker exec mongo-1 mongosh --quiet "$M" --eval 'rs.stepDown(60)'
# 旧主主动下台，60 秒内不再竞选
sleep 5
docker exec mongo-2 mongosh --quiet "$M" \
  --eval 'rs.status().members.forEach(m => print(m.name, m.stateStr))'
# mongo-2 或 mongo-3 当选 PRIMARY，三节点 count 最终一致
```

诚实边界：stepDown 场景数据是最终一致的，基本不会产生回滚文件；真正的回滚要旧主带着"没来得及复制出去的写"重新入队，得人为制造分区才复现得了【从业者判断】。所以很多人第一次见 rollback 目录，就是在生产事故里。

## 八、预答两个反方

"全部上 w:majority 不就完了？"代价有两层。延迟层：每次写等多数派确认，尾延迟直接上去。可用性层：从库全挂时 majority 凑不齐，没带 wtimeout 的写请求无限等待——这正是"写请求全部挂起、连接数暴涨"的经典事故。

正解是分级：钱和状态机用 majority+j+wtimeout，可丢弃日志用 w:0/1。**写关注分级不是偷懒，是架构决策。**

"回滚了数据库不该自动帮我恢复吗？"不该。自动恢复等于少数派的写强行覆盖多数派裁决，防脑裂就白设了。MongoDB 把裁决权交给人——处置流程要提前进 runbook，别等出了事再现查文档。

## 九、教训与 30 秒自检

| 要点 | 一句话 |
| --- | --- |
| 丢失窗口 | w:1 返回成功到复制达多数派之间，切主即清算 |
| 回滚去向 | 未达多数派的写抽进 rollback 目录的 BSON 文件 |
| 读的真相 | local 可能读到将被回滚的写，majority 不会 |
| 回滚处置 | 丢弃/手工回放/mongorestore，先验货再动手 |
| oplog 窗口 | 掉出窗口只能 initial sync，按最长中断倒推（如 24~48 小时） |

三件现在就能做的事。第一件，扫服务的连接串与写入代码，确认写关注是显式配置而非赌隐式默认值。第二件，对每个副本集跑一次 rs.printSecondaryReplicationInfo，顺手算算 oplog 窗口能覆盖多长中断。第三件，把 rollback 文件处置写进切主预案。

## 写在最后

这篇真正想留下的只有一句话：**拿到多数派确认之前，写入不属于你。**它是 MongoDB 一致性模型的全部要点——选举看多数派，写安全看多数派，读真相也看多数派；少数派节点上发生的一切，都只是待裁决的提案。把这句话带进每一次 writeConcern 选型，"87 笔失踪写入"这种事，就轮不到你的值班群。

时间线、lab 脚本与回滚处置命令整理自我维护的开源学习库——GitHub 搜 sre-learning-hub，MongoDB 副本集章节附可复跑的 VM lab。你最后一次见到的 rollback 目录是怎么处置的——丢弃、重放，还是 mongorestore？评论区对个暗号。
