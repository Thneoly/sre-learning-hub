# Lab 01 · 解答：副本集部署、故障转移与断连追平

按 task.md 的六个任务逐步讲解。每步给"做什么 + 为什么 + 验证输出"。

## 0. 清场（如果之前试过）

```bash
# [Ubuntu VM]
docker rm -f mongo-rs1 mongo-rs2 mongo-rs3 2>/dev/null
docker network rm mongonet 2>/dev/null
```

## 1. 起三个 mongod 容器

```bash
# [Ubuntu VM]
docker network create mongonet

for i in 1 2 3; do
  docker run -d --name mongo-rs$i --net mongonet \
    mongo:7.0 --replSet rs0 --bind_ip_all
done
```

为什么：

- `--replSet rs0` 声明本实例属于副本集 `rs0`，未 initiate 前处于 STARTUP 状态，只接受 `rs.initiate` 等管理命令。
- `--bind_ip_all` 让 mongod 监听所有网卡，否则容器间无法互连（默认只绑 localhost）。
- 三容器同在 `mongonet`，副本集成员地址可直接用容器名互相解析。
- 不映射宿主机端口：所有操作都通过 `docker exec` 在容器内完成，也避免与宿主已有的 27017 冲突。
- 省略了认证（生产必须用 keyfile 或 x509 做副本集内部认证，见 task.md 延伸说明；lab 环境为聚焦复制机制不启用）。

## 2. 初始化副本集

```bash
# [Ubuntu VM] 等 mongod 就绪几秒后,在 mongo-rs1 上执行
docker exec mongo-rs1 mongosh --quiet \
  "mongodb://localhost:27017/?directConnection=true" --eval '
rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "mongo-rs1:27017", priority: 2 },
    { _id: 1, host: "mongo-rs2:27017" },
    { _id: 2, host: "mongo-rs3:27017"  }
  ]
})'
```

为什么：

- `_id: "rs0"` 必须与三个实例的 `--replSet` 一致；`members[].host` 用容器名，副本集成员之间就是靠这些地址互相找的。
- `priority: 2` 只给 `mongo-rs1`：优先级高者优先当选，保证初始 PRIMARY 确定性地落在 rs1 上——这是 task.md 的约定，也让第 4 步的 stepDown 演练"有主可让"。默认三个成员 priority 都是 1，初始主随机。
- URL 里的 `directConnection=true`：不进入副本集发现逻辑，直连本实例执行管理命令。

```bash
# [Ubuntu VM] 等待选举完成(约 10 秒),确认 1 主 2 从
sleep 10
docker exec mongo-rs1 mongosh --quiet \
  "mongodb://localhost:27017/?directConnection=true" --eval \
  'rs.status().members.forEach(m => print(m.name, m.stateStr))'
```

预期输出：

```
mongo-rs1:27017 PRIMARY
mongo-rs2:27017 SECONDARY
mongo-rs3:27017 SECONDARY
```

也可用 `rs.status().myState`（1=PRIMARY，2=SECONDARY）或 `db.hello().isWritablePrimary` 单点确认。

## 3. 写入前 60 条并验证复制

```bash
# [Ubuntu VM] 在主库 mongo-rs1 上写入
docker exec mongo-rs1 mongosh --quiet \
  "mongodb://localhost:27017/?directConnection=true" --eval '
db = db.getSiblingDB("app")
db.orders.insertMany(
  Array.from({length: 60}, (_, i) => ({ _id: i + 1, v: "row-" + (i + 1) }))
)
db.orders.countDocuments({})'
# 60
```

`insertMany` 一批写入；`_id` 显式给 1~60，计数可预测，也避免 ObjectId 打乱输出排序。

```bash
# [Ubuntu VM] 直连两个从库验证(注意 directConnection)
for h in mongo-rs2 mongo-rs3; do
  docker exec $h mongosh --quiet \
    "mongodb://localhost:27017/?directConnection=true" --eval \
    'db.getSiblingDB("app").orders.countDocuments({})'
done
# 60
# 60
```

为什么能同步：每次写入在主库追加 oplog，从库开 tailable cursor 拉取并在本地重放，这一步看到的 60 就是复制链路端到端通畅的证明。顺便看一眼复制状态：

```bash
# [Ubuntu VM]
docker exec mongo-rs1 mongosh --quiet \
  "mongodb://localhost:27017/?directConnection=true" --eval \
  'rs.printSecondaryReplicationInfo()'
# 两个从库落后 0 秒
```

## 4. 故障转移演练：主库让位

```bash
# [Ubuntu VM] 让 mongo-rs1 下台,120 秒内不再竞选
docker exec mongo-rs1 mongosh --quiet \
  "mongodb://localhost:27017/?directConnection=true" --eval \
  'rs.stepDown(120)'
# 输出 MongoServerError: elect failed 之类是正常的:
# stepDown 的实现就是"发起一次必然把自己选下去的选举"
sleep 5
```

为什么：

- `rs.stepDown(120)` 等价于"主动故障转移"：旧主让位并进入 SECONDARY，参数是它 120 秒内不得再竞选（保护窗口）。生产打补丁前就是这么做的。
- 它 priority=2 也不会立刻抢回，因为竞选保护生效且当前有健康主库；这保证了终态 rs1 是 SECONDARY。

```bash
# [Ubuntu VM] 看新拓扑
docker exec mongo-rs1 mongosh --quiet \
  "mongodb://localhost:27017/?directConnection=true" --eval \
  'rs.status().members.forEach(m => print(m.name, m.stateStr))'
# mongo-rs1:27017 SECONDARY   ← 旧主已让位
# mongo-rs2:27017 PRIMARY     ← 新主(rs2/rs3 谁上都对,输出可能相反)
# mongo-rs3:27017 SECONDARY

# 验证写入已恢复:在新主上插一条试写,再删掉,不影响终态计数
NEWPRIMARY=mongo-rs2   # 换成你上面看到的 PRIMARY
docker exec $NEWPRIMARY mongosh --quiet \
  "mongodb://localhost:27017/?directConnection=true" --eval '
db.getSiblingDB("app").orders.insertOne({ _id: 999, v: "probe" })
db.getSiblingDB("app").orders.deleteOne({ _id: 999 })
db.getSiblingDB("app").orders.countDocuments({})'
# 60
```

故障转移窗口：心跳超时 + 选举大约 10 秒，期间写会短暂失败；应用侧的正规姿势是驱动 `retryWrites` 重试，lab 里人肉等 5 秒即可。

## 5. 停掉一台从库，主库继续写

```bash
# [Ubuntu VM] 模拟 mongo-rs3 宕机(容器停止,数据卷保留)
docker stop mongo-rs3

# 集群剩 2/3,多数派(2 票)仍在,写入不受影响
docker exec $NEWPRIMARY mongosh --quiet \
  "mongodb://localhost:27017/?directConnection=true" --eval '
db = db.getSiblingDB("app")
db.orders.insertMany(
  Array.from({length: 60}, (_, i) => ({ _id: i + 61, v: "row-" + (i + 61) }))
)
db.orders.countDocuments({})'
# 120
```

为什么停一台还能写：副本集要求多数派存活才接受写，3 节点容忍 1 台故障。对比实验（可选）：如果这时把 `mongo-rs2` 也停掉，剩 1/3 不够多数，写入会一直失败——这就是"2 节点副本集挂一台就整体失写"的原因。

看一眼停机期间的状态与健康度：

```bash
# [Ubuntu VM] 主库视角:rs3 掉线
docker exec $NEWPRIMARY mongosh --quiet \
  "mongodb://localhost:27017/?directConnection=true" --eval \
  'rs.status().members.forEach(m => print(m.name, m.stateStr, m.health))'
# mongo-rs1:27017 SECONDARY 1
# mongo-rs2:27017 PRIMARY 1
# mongo-rs3:27017 (not reachable/healthy) 0
```

注意默认写关注是 `w:1`（主库本地确认即可），所以从库少一台不影响写入返回速度；若用 `w:"majority"` 依然能成功（2/3 就是多数），只是要等 rs1 也确认。

## 6. 恢复 mongo-rs3 并追平

```bash
# [Ubuntu VM] 拉回"修好的机器"
docker start mongo-rs3
sleep 10   # 给它重连 + 重放 oplog 的时间

# 状态回到 SECONDARY
docker exec mongo-rs1 mongosh --quiet \
  "mongodb://localhost:27017/?directConnection=true" --eval \
  'rs.status().members.forEach(m => print(m.name, m.stateStr))'

# 三节点数据一致
for h in mongo-rs1 mongo-rs2 mongo-rs3; do
  docker exec $h mongosh --quiet \
    "mongodb://localhost:27017/?directConnection=true" --eval \
    'db.getSiblingDB("app").orders.countDocuments({})'
done
# 120
# 120
# 120
```

为什么能追平：rs3 重连后拿着自己最后应用的 oplog 位点向主库开 tailable cursor，把停机期间缺的 60 条增量拉过来重放——这就是"掉线不超过 oplog 窗口就能增量追上"的现场版。如果停得太久、位点已被环形覆盖，它就只能 initial sync 全量重建（lab 数据量小，窗口绰绰有余）。

## 7. 运行判分脚本

```bash
# [Ubuntu VM] 把本目录 check.sh 拷到 VM 后
chmod +x check.sh
./check.sh
```

预期输出（PRIMARY 落在 rs2 或 rs3 都正确，脚本自动识别）：

```
== Lab 01 检查开始 ==
PASS: 容器 mongo-rs1 运行中
PASS: 容器 mongo-rs2 运行中
PASS: 容器 mongo-rs3 运行中
PASS: 副本集名为 rs0
PASS: 有且仅有 1 个 PRIMARY
PASS: mongo-rs1 已让位为 SECONDARY(演练过故障转移)
PASS: 三个成员均为 PRIMARY/SECONDARY
PASS: PRIMARY 上 app.orders 文档数=120
PASS: mongo-rs2 上 app.orders 文档数=120
PASS: mongo-rs3 上 app.orders 文档数=120
== 结果 ==
SCORE: 10/10
```

## 复盘要点

- 多数派是副本集一切行为的钥匙：3 节点容 1 台；选举、写关注可用性全部围绕 ⌊N/2⌋+1。
- 故障转移有约 10 秒窗口，应用必须靠 `retryWrites` + 幂等写入消化，而不是假设写永不失败。
- `rs.stepDown()` 是生产可用的"计划内主库切换"，比 `docker kill` 温和得多，排练时就该用它。
- 从库恢复的增量追平依赖 oplog 窗口；写多的库要核对 `local.oplog.rs` 大小能否覆盖最长预计停机时间。
- 本 lab 未启用认证：生产副本集要用 keyfile（或 x509）做内部认证，配合 TLS 与最小权限账号，详见官方手册 Security Checklist。
