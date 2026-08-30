# 04 · 分布式事务：从 2PC 的阻塞点到"恰好一次"的真相

> 模块：17-distributed ｜ 建议时长：3.5 小时 ｜ 关联认证：—（无直接考点；Flink exactly-once 是 12 模块的理论深化，MySQL 的两阶段血缘在 11 模块）

## 学习目标

- 能指出 2PC 的两个结构性缺陷（协调者单点、参与者持锁阻塞）在故障时刻的具体表现
- 能解释 3PC 解决了什么、又为什么没有任何生产系统采用它
- 能给 TCC / Saga / 本地消息表各配一个业务例子，并说出各自的代价与适用边界
- 能拆穿"恰好一次"：讲清工程上的真相是 at-least-once + 幂等（映射 Flink checkpoint 两阶段提交与 Kafka 事务）
- 能按场景在四种幂等模式（唯一键 / 去重表 / 版本号 / 条件更新）里选型并写出可执行的 SQL

## 1. 问题：跨系统的"要么都成、要么都不"

单库事务靠一套 WAL + undo 保证原子性。但"下单要同时扣库存（库存库）、记账（账户库）、发消息（Kafka）"跨了三个系统，没有任何一家能看到全局——分布式事务的全部方案，都是在回答**"谁来记这本总账，记在哪儿，崩了之后怎么继续"**。先记住分水岭，后面所有方案都站在其中一侧：

- **强一致路线**：2PC/3PC/XA——让参与者先把结果"锁住"，等全局决定。可用性与吞吐被锁拖垮。
- **柔性路线**：TCC/Saga/本地消息表——放弃同时性，接受中间态，用补偿与重试收敛到最终一致。
- **流处理路线**：at-least-once + 幂等——干脆承认会重复，让重复"不可见"。

## 2. 2PC：数据库层的事务协议

### 2.1 你其实早就见过它

MySQL 内部就跑着一个 2PC：**redo log prepare → 写 binlog → commit**，以"binlog 是否完整落盘"作为崩溃恢复时提交或回滚的裁决依据。没有这层两阶段，就会出现"主库有、从库无"或反向的不一致——[11-middleware/mysql/01-innodb-fundamentals.md](../11-middleware/mysql/01-innodb-fundamentals.md) §4（三大日志与两阶段提交）有完整的反例推演。跨系统的 2PC 是同一思想的放大：**把"两个日志系统"换成"两个参与者系统"，把"本地 binlog"换成"协调者的决策日志"**。

### 2.2 流程、阻塞点与单点

```
                ① prepare（投票阶段）
 client ──► 协调者 ────┬──► 参与者A：写本地日志、拿到锁、回 YES
                       └──► 参与者B：写本地日志、拿到锁、回 YES
                ② 协调者写决策日志（commit/abort）并持久化
                ③ commit（执行阶段）
 协调者 ────┬──► 参与者A：真正提交、放锁
            └──► 参与者B：真正提交、放锁
```

两个结构性缺陷，全部集中在"中间那格"：

| 缺陷 | 故障时序 | 后果 |
|---|---|---|
| **参与者持锁阻塞** | A、B 都投了 YES，协调者在写完决策日志**之前**崩溃 | A/B 不知道全局结论，只能抱着行锁等待协调者复活——锁着资源干等，超时也无权自行决定（投了 YES 就交出了自决权） |
| **协调者单点** | 协调者所在机器磁盘损坏，决策日志没了 | 参与者永远等不到结论；人工介入是唯一出路 |

运维视角的翻译：2PC 最坏情况下把"一个组件的故障"放大成"所有参与者的锁堆积"——上游超时、连接池打满、雪崩。这不是实现瑕疵，是协议的固有形状。

**MySQL 半同步是它的"半个"版本**：主库 commit 后等至少一个从库 ACK binlog 才应答客户端（[11-middleware/mysql/02-backup-replication.md](../11-middleware/mysql/02-backup-replication.md) 半同步一节），超时（默认 10s）自动降级回异步——工程上承认"强一致窗口"有价格，价格太贵就显式降级并让监控看见。这正是 2PC 不肯做的事。

## 3. 3PC：为什么教科书有它、生产没有它

3PC 在 prepare 前加一步 CanCommit（先问"能不能干"不锁资源），并给参与者加了超时自决：超时未收到指令就按既定规则单方面提交或回滚，缓解"协调者崩了大家干等"。代价与残余缺陷：

1. **多一轮 RTT**：每次事务三趟往返，吞吐进一步下降；
2. **假设有界延迟**：超时自决的前提是"消息要么到要么超时"，真实网络分区不保证；
3. **分区下仍可能不一致**：一侧按时收到 abort、另一侧超时自决 commit——它把"阻塞"换成了"不一致"，对一个正确性优先的协议来说这是更坏的交换。

所以工程界的结论不是"3PC 修好了 2PC"，而是**放弃在数据库层做强一致跨系统事务，转向柔性事务 + 幂等**。面试答法：3PC 的教训是"用超时对抗分区"这条路走不通，可用性与一致性的取舍要显式交给业务（第 4 节），而不是藏在协议里。

## 4. 柔性事务三件套

| 方案 | 一句话机制 | 业务例子 | 代价与坑 |
|---|---|---|---|
| TCC | 每个参与方实现 Try（预留）/ Confirm（落实）/ Cancel（释放）三接口 | 支付下单：Try 冻结余额 + 预扣库存；Confirm 真扣冻结额与库存；Cancel 解冻返还 | 业务侵入最大（一张表拆三个动作）；空回滚（Try 没到 Cancel 先到）、悬挂（Cancel 之后 Try 才到）都要防——所以 Confirm/Cancel 必须幂等 |
| Saga | 长流程拆成一串本地事务，每步配一个反向补偿，失败时逆序补偿 | 订行程：建订单 → 扣机票库存 → 订酒店 → 租车；租车失败则依次取消酒店、还机票库存、取消订单 | 中间态对外可见（没有隔离性）；补偿逻辑是第二套业务代码，也要幂等可重试；编排（中心协调器）vs 协同（事件驱动）二选一，出错定界难度不同 |
| 本地消息表 | 业务写入与消息记录放进**同一个本地事务**，后台任务扫表投递 | 订单库 transaction 里同时 `INSERT orders` + `INSERT outbox(msg)`；relay 进程扫 outbox 发 Kafka，成功后标记 | 保证"业务成功 ⇔ 消息必发"（at-least-once）；下游必须幂等去重；outbox 要清理归档，relay 要监控积压 |

三件套的共同底牌：**用"可重试的最终一致"换掉"锁住的强一致"**，重试必然带来重复，所以幂等（第 6 节）不是可选项，是柔性事务的承重墙。

## 5. 恰好一次的真相：at-least-once + 幂等

"Exactly-once delivery"在分布式里不存在：网络重试与崩溃恢复必然造成重复或丢失（三选一：at-most-once / at-least-once / 什么都没有）。**工程上能兑现的是 exactly-once effect（效果恰好一次）**——上游可重放 + 下游原子提交或幂等吸收，让重复"不可见"。

### 5.1 Flink：把 2PC 装进 checkpoint

Flink 的端到端 exactly-once 是"缩小版 2PC"，角色映射是面试高频：

| 2PC 概念 | Flink 里的对应物 |
|---|---|
| 协调者 | JobManager 的 CheckpointCoordinator |
| 协调者决策日志 | **持久化的 checkpoint 本身**（状态目录落 PVC，见 [12-data-streaming/flink/02-deployment-and-exactly-once.md](../12-data-streaming/flink/02-deployment-and-exactly-once.md) §2） |
| 参与者 | 各算子，尤其是 sink |
| prepare | preCommit：barrier 对齐后 flush，事务句柄写进 checkpoint 状态 |
| commit | `notifyCheckpointComplete` 到达后 sink 真正 commit 事务 |

这个设计把经典 2PC 的两大缺陷各缓解了一半：协调者崩溃可从 checkpoint 恢复（决策日志持久化了）；但"commit 通知丢失"的窗口仍在——事务悬挂要靠 `transaction.timeout.ms` 兜底，所以才有那条硬约束：**transaction.timeout.ms 必须 > checkpoint 间隔 + 预期恢复时长，且 ≤ broker 的 transaction.max.timeout.ms**。三条前提与参数细节见 [flink 02 章 §5](../12-data-streaming/flink/02-deployment-and-exactly-once.md)（三前提缺一不可：内部 barrier 对齐、source 可重放、sink 事务性）。

### 5.2 Kafka：幂等生产者与事务

- **会话内幂等**：`enable.idempotence=true`（3.0 起默认）给每个 producer 发 PID，按 `<PID, partition>` 维护递增序列号，broker 端去重窗口拒绝重试重复。边界：跨会话（重启换 PID）、跨分区都不保证——见 [kafka 01 章 §7](../12-data-streaming/kafka/01-log-model-and-architecture.md) 的生产者幂等一节。
- **跨会话与跨分区**：事务（`transactional.id`），broker 端 transaction coordinator 记 epoch，**重启后的 producer 带同一 transactional.id 会顶掉旧 epoch——这正是第 06 章要讲的 fencing token 思想在消息系统里的化身**（防僵尸生产者）。下游用 `isolation.level=read_committed` 只读已提交数据。
- **消费侧语义**：先处理后提交 = at-least-once，崩溃时重复消费，业务侧用幂等键（订单号、消息 UUID）兜底——[kafka 02 章 §8](../12-data-streaming/kafka/02-replication-and-reliability.md) 有"poll 到 500 条处理到 300 条被 OOMKill"的完整推演。

### 5.3 一张表收尾

| 语义 | 怎么实现 | 代价 | 谁在用 |
|---|---|---|---|
| at-most-once | 先提交位移后处理 | 崩溃丢数据 | 几乎无（日志类可容忍） |
| at-least-once + 幂等 | 重放 + 下游唯一键/upsert | 幂等表维护、去重窗口 | Kafka 消费业务、大多数管道 |
| exactly-once effect | checkpoint 两阶段提交 + 事务 sink | 延迟（等 checkpoint）、约束多 | Flink→Kafka 端到端 |

降级路径要记牢：若 sink 只能做幂等写入（按主键 upsert 的库），就退回 at-least-once + 幂等，吞吐与延迟都更好——这不是妥协，是正确选型（[flink 02 章 §5](../12-data-streaming/flink/02-deployment-and-exactly-once.md) 末尾原文）。

## 6. 幂等设计模式速查

| 模式 | 机制 | 适用 | 注意 |
|---|---|---|---|
| 唯一键 | `UNIQUE KEY` + `INSERT IGNORE` / `ON DUPLICATE KEY UPDATE` | 天然有业务键的落库（订单号、流水号） | 依赖数据库唯一性约束，最硬的兜底 |
| 去重表 | 消息 ID 先插去重表（主键冲突=已处理），再做业务 | 消费侧去重 | 去重表与业务写法放同一本地事务，否则出现"记了没做/做了没记" |
| 版本号 | `UPDATE ... SET v=v+1 WHERE id=? AND v=?`，按影响行数判定 | 并发更新同一行（乐观锁） | ABA 要靠业务版本字段，别用时间戳当版本（时钟不可靠，见第 06 章） |
| 条件更新 | `UPDATE ... WHERE status='INIT'` 状态机推进 | 状态流转（支付回调、工单） | 影响行数=0 即"已被处理"，直接当成功返回 |
| 去重缓存 | Redis `SET key val NX EX ttl` | 短窗口去重、限流合用 | TTL 决定窗口；Redis 故障时的降级路径要先想好 |

选型口诀：**能落库就用唯一键，跨系统就上消息 ID 去重表，会并发就配版本号，有状态机就配条件更新**。四者不互斥，生产组合常见"消息 ID 去重表 + 业务唯一键"双保险。

## 实战演练

环境：装有 Docker 的 Ubuntu VM。用 MySQL 验证四种幂等模式，用 Redis 验证去重缓存。命令标注 `[任意节点]`。

```bash
# [任意节点] 起 MySQL 与 Redis（端口错开，避免与本机已有实例冲突）
docker run -d --name idem-mysql -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=idem -p 33061:3306 mysql:8.0
docker run -d --name idem-redis -p 63901:6379 redis:7-alpine
# 等 MySQL 就绪（约 20~40s）
until docker exec idem-mysql mysqladmin ping -uroot -proot --silent 2>/dev/null; do sleep 2; done
echo mysql-ready
```

```sql
-- [任意节点] 建表：一张业务表（带唯一键/版本/状态机）+ 一张去重表
docker exec -i idem-mysql mysql -uroot -proot idem <<'EOF'
CREATE TABLE orders (
  id       BIGINT AUTO_INCREMENT PRIMARY KEY,
  order_no VARCHAR(64) NOT NULL,
  amount   INT NOT NULL,
  status   VARCHAR(16) NOT NULL DEFAULT 'INIT',
  version  INT NOT NULL DEFAULT 0,
  UNIQUE KEY uk_order_no (order_no)
) ENGINE=InnoDB;
CREATE TABLE consumed_messages (
  msg_id      VARCHAR(64) PRIMARY KEY,
  consumed_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
EOF
```

```bash
# [任意节点] 模式 1（唯一键）：重试造成的重复插入被唯一键挡下
docker exec -i idem-mysql mysql -uroot -proot idem <<'EOF'
INSERT INTO orders (order_no, amount) VALUES ('ORD-1001', 99);
INSERT IGNORE INTO orders (order_no, amount) VALUES ('ORD-1001', 99);
-- 预期：第一条 affected 1；第二条 affected 0（重复被吞，客户端拿到成功而非 1062）
SELECT order_no, amount FROM orders WHERE order_no='ORD-1001';
-- 预期：仅一行 ORD-1001 99 —— "重试 N 次，效果一次"
EOF
```

```bash
# [任意节点] 模式 2（去重表）：模拟同一条消息被投递两次
docker exec -i idem-mysql mysql -uroot -proot idem <<'EOF'
INSERT IGNORE INTO consumed_messages (msg_id) VALUES ('MSG-20260830-0001');
SELECT ROW_COUNT();
INSERT IGNORE INTO consumed_messages (msg_id) VALUES ('MSG-20260830-0001');
SELECT ROW_COUNT();
-- 预期：第一次 1（执行业务），第二次 0（直接跳过业务）。
-- 生产写法：去重表插入与业务写在同一事务里提交
EOF

# [任意节点] 模式 3（版本号乐观锁）：两个并发更新只有一个成功
docker exec -i idem-mysql mysql -uroot -proot idem <<'EOF'
UPDATE orders SET amount=199, version=version+1
 WHERE order_no='ORD-1001' AND version=0;
-- 预期：affected 1（拿到版本 0 的那次成功）
UPDATE orders SET amount=299, version=version+1
 WHERE order_no='ORD-1001' AND version=0;
-- 预期：affected 0（版本已到 1，旧版本写入被拒——这就是并发下的条件竞争被收敛）
EOF

# [任意节点] 模式 4（条件更新/状态机）：支付回调重放不产生副作用
docker exec -i idem-mysql mysql -uroot -proot idem <<'EOF'
UPDATE orders SET status='PAID' WHERE order_no='ORD-1001' AND status='INIT';
UPDATE orders SET status='PAID' WHERE order_no='ORD-1001' AND status='INIT';
-- 预期：第一次 affected 1，第二次 affected 0（重复回调幂等）
EOF
```

```bash
# [任意节点] 模式 5（Redis 去重缓存）：短窗口去重
docker exec idem-redis redis-cli SET dedup:msg:MSG-0002 1 NX EX 3600
# 预期：OK（首次，执行业务）
docker exec idem-redis redis-cli SET dedup:msg:MSG-0002 1 NX EX 3600
# 预期：(nil)（窗口内重复，跳过）——NX = Not eXists，EX = 过期秒数
docker exec idem-redis redis-cli TTL dedup:msg:MSG-0002
# 预期：3599 左右（去重窗口剩余时间）

# [任意节点] 清理
docker rm -f idem-mysql idem-redis
```

验证方法：每种模式都"同一操作执行两次、看第二次的 affected/返回值"——第二次不产生新副作用即幂等成立。把五次实验的第二行输出抄进笔记，就是"幂等模式速查"的证据链。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 消费者明明幂等了还是出现重复订单 | 只挡了"消息重投"，没挡"两个来源写同一业务键"（定时任务+消息并发） | 业务唯一键兜底（最后一道防线永远在数据库约束上） |
| 去重表插了，业务没执行 | 去重表与业务写不在同一本地事务 | 合并进一个 transaction；或先业务后补去重 + 冲突回滚 |
| Flink 作业频繁报事务超时 / 数据延迟可见 | `transaction.timeout.ms` ≤ checkpoint 间隔 | 调大事务超时或调小 checkpoint 间隔；同时不超过 broker 的 `transaction.max.timeout.ms`（[flink 02 章 §5](../12-data-streaming/flink/02-deployment-and-exactly-once.md) 三条硬约束） |
| 下游"偶尔读到一半数据" | 消费者没设 `isolation.level=read_committed` | read_committed 是事务生效的一半，漏了等于自欺 |
| 版本号用时间戳 | 时钟回拨/漂移导致版本回退，乐观锁失效 | 用单调递增整数或数据库自增；时钟问题见第 06 章 |
| Saga 补偿执行两次，库存多退了一份 | 补偿动作不幂等 | 补偿与正操作一样过幂等设计（第 6 节模式照用） |
| 想用 XA 把两个 MySQL 强一致绑一起 | 2PC 持锁阻塞 + 协调者单点，高峰期锁堆积雪崩 | 评估柔性事务；真要强一致考虑合并库或多数派复制（第 03 章） |

## 自测

1. 协调者在"写决策日志之后、广播 commit 之前"崩溃，参与者此时已投 YES。等待中的参与者能不能超时后自行提交？为什么这是 2PC 最危险的窗口？
<details><summary>答案</summary>

不能安全地自行决定。投 YES 意味着"我已准备好提交且交出了自决权"——协调者的决策日志可能已经是 commit（只是广播没送达），此时回滚会造成与已提交参与者不一致；也可能没写成功，此时提交同样危险。参与者只能持锁等待协调者恢复后查询决策，这就是"阻塞"二字的由来：一个组件的故障被协议放大成所有参与者的资源冻结。3PC 试图用超时自决解决它，但分区下两侧可能做出相反决定（第 3 节）。
</details>

2. Flink 的两阶段提交把"协调者日志"换成了 checkpoint，为什么说它只缓解了一半问题？
<details><summary>答案</summary>

checkpoint 持久化让"协调者崩溃后决策可恢复"成立（从最近 completed checkpoint 恢复，事务句柄就在状态里）。但经典 2PC 的另一半风险——决策已定、执行通知未达——变成了"`notifyCheckpointComplete` 丢失/迟到"：sink 的事务停在已 preCommit 未 commit，消费者在 read_committed 下看不到数据，事务悬挂直到 `transaction.timeout.ms` 才被 broker 回滚。所以必须让事务寿命覆盖"checkpoint 间隔 + 恢复时长"，这是那条硬约束的由来（[flink 02 章 §5](../12-data-streaming/flink/02-deployment-and-exactly-once.md)）。
</details>

3. 本地消息表方案里，"业务成功但消息永远没发出去"还会发生吗？
<details><summary>答案</summary>

本地事务保证"业务与 outbox 记录同生共死"，所以消息至少被**记录**下来；但"记录 → 投递"靠 relay 进程扫描，这一段仍可能积压/失败（relay 挂、Kafka 不可用、标记失败）。所以答案是：消息不会丢（还在表里），但会**延迟**——运维要监控 outbox 积压与最老未发消息年龄。投递本身是 at-least-once（重试会重复发），下游幂等去重表是配套必选。两段合起来才是完整方案。
</details>

4. Kafka producer 幂等开了，为什么跨会话还是可能重复？
<details><summary>答案</summary>

幂等的去重键是 `<PID, partition>` 上的序列号，而 PID 是 producer 启动时从 broker 领的**会话级**标识——重启后 PID 变了，broker 的去重窗口对新 PID 从零开始，崩溃前"已写入但未收到 ack"的那批消息重发后无法被识别为重复。跨会话要靠事务：固定的 `transactional.id` 让 coordinator 用递增 epoch 绑定"同一逻辑生产者"，新会话顶掉旧 epoch，旧 PID 的僵尸写入被拒绝——这就是 fencing（第 06 章）。见 [kafka 01 章 §7](../12-data-streaming/kafka/01-log-model-and-architecture.md)。
</details>

5. 为什么说"版本号乐观锁不要用时间戳"？给一个具体的翻车时序。
<details><summary>答案</summary>

时间戳依赖机器时钟，而时钟可回拨可跳变（NTP 步进、VM 挂起恢复，漂移与跳变的机理见 [01-failure-models-and-time.md](./01-failure-models-and-time.md) §2）。时序：节点 A 读到 v=10:00:00 → A 发生长 GC/网络延迟 → 节点 B 已推进到 v=10:05:00 → B 所在机 NTP 校正回拨到 09:58 → B 写入 v=09:58:00，条件 `WHERE ts <= 09:59` 满足 → A 恢复后带 10:00:00 的写入反而"看起来更新"成功覆盖了 B。单调递增整数/自增版本没有这个问题——它由数据库单点分配，不依赖任何时钟。这也是第 06 章"租约怕时钟、fencing 用单调令牌"的同一个教训。
</details>

## 延伸阅读

- Flink Checkpointing 与 exactly-once 官方文档：https://nightlies.apache.org/flink/flink-docs-stable/docs/dev/datastream/fault-tolerance/checkpointing/
- Kafka 事务与幂等（KIP-98 / KIP-129）：https://kafka.apache.org/documentation/#transactional_sender
- Kafka Exactly Once Semantics 官方博文：https://www.confluent.io/blog/exactly-once-semantics-are-possible-kafka-kafka-streams/
- MySQL 两阶段提交与崩溃恢复：https://dev.mysql.com/doc/refman/8.0/en/binary-log-group-commit.html
- Saga 模式（Chris Richardson, microservices.io）：https://microservices.io/patterns/data/saga.html
- Kleppmann《Designing Data-Intensive Applications》第 7/8 章（本章多处结论的出处）
