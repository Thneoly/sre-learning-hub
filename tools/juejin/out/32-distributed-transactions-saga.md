---
title_juejin: '跨服务扣款怎么不丢钱：2PC 把锁攥死，Saga 把账补回来'
title_zhihu: '跨服务扣款不丢钱，靠的不是更强的协议，而是更会补的账'
description: '2PC持锁阻塞与协调者单点、3PC为何无人采用、TCC空回滚与悬挂防御、Saga编排vs协同、补偿幂等三难点、本地消息表outbox、MQ事务消息边界，附一致性×吞吐×成本决策树。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686341072617242662"
---

# 跨服务扣款怎么不丢钱：2PC 把锁攥死，Saga 把账补回来

```text
t0  用户点支付：账户库扣 100 元，权益库发一张 50 元券
t1  两个库都投了 YES，行锁在手，本地日志已落盘
t2  协调者在写决策日志之前——崩了
t3  两把行锁抱着不放，等一个永远不会来的结论
t4  上游超时重试，连接池打满，支付链路开始雪崩
```

这是构造的典型时序，不是某次真实事故——但每一步，在真实的 2PC 故障里都有原型。这就是 2PC 最贵的那个窗口。先把核心判断放在这里：跨服务扣款的每一种方案，回答的都是同一道题——**谁来记总账，记在哪，崩了之后怎么继续**。

强一致路线（2PC/XA）用锁换正确，柔性路线（TCC/Saga/本地消息表）用账换吞吐。两条线的代价逐段拆，最后给一张能直接抄的决策树。

## 1. 先问一句：这笔钱真的需要跨系统事务吗

方案评审的第一句话不该是"选哪个框架"，而是"能不能不分布"。合并库、同库不同表，一个单机事务收工。

**最好的分布式事务，是让事务不分布**——这是所有选项里一致性和吞吐都最高的那片叶子。只有强一致边界实在缩不小（账户与权益分属不同库），才轮到下面的方案上场。

## 2. 2PC：投了 YES，就交出了自决权

流程本身只有三步：

```text
① prepare（投票）：协调者问两边"能不能提交"
   参与者 A/B：写本地日志、拿行锁、回 YES
② 协调者写决策日志（commit/abort）并持久化
③ commit（执行）：广播决定，两边真正提交、放锁
```

两个结构性缺陷，全部集中在第 ② 步：

| 缺陷 | 故障时序 | 后果 |
|---|---|---|
| 参与者持锁阻塞 | A、B 都投了 YES，协调者写决策日志**之前**崩溃 | 两边只能抱锁干等，超时也无权自行决定 |
| 协调者单点 | 协调者机器磁盘损坏，决策日志没了 | 参与者永远等不到结论，人工介入是唯一出路 |

为什么投了 YES 就交出自决权？决策日志可能已经是 commit（广播没送达），回滚会和另一边不一致；也可能没写成功，提交同样危险。两头都不敢动，只能锁着资源等——这就是"阻塞"的由来。

2PC 把"一个组件的故障"放大成"所有参与者的锁堆积"——**这不是实现瑕疵，是协议的固有形状**。

两个对照帮你把它看透：

- MySQL 内部就跑着一个 2PC：redo log prepare → 写 binlog → commit，以 binlog 是否完整落盘裁决崩溃恢复。跨系统 2PC 是同一思想的放大：日志系统换成参与者系统，binlog 换成协调者的决策日志。
- MySQL 半同步复制是"半个 2PC"：主库 commit 后等至少一个从库 ACK binlog 才应答客户端，超时（默认 10s）自动降级回异步。工程上承认强一致窗口有价格，太贵就显式降级、让监控看见——**这正是 2PC 不肯做的事**。

## 3. 3PC：把阻塞换成了不一致，更贵

3PC 有两处改动：prepare 前加一步 CanCommit（先问"能不能干"，不锁资源），再给参与者加超时自决——超时收不到指令，就按既定规则单方面提交或回滚。看着治好了"协调者崩了大家干等"。

账单有三张：每次事务多一轮 RTT，吞吐进一步下降；超时自决的前提是"消息要么到要么超时"，真实网络分区不保证这个；分区下仍可能不一致——一侧按时收到 abort，另一侧超时自决 commit。

对一个正确性优先的协议，**把"阻塞"换成"不一致"是更坏的交换**。所以工程界的结论不是"3PC 修好了 2PC"，而是没有任何生产系统采用它，掉头去做柔性事务加幂等。面试答法：3PC 的教训是"用超时对抗分区"走不通，取舍要显式交给业务，而不是藏在协议里。

## 4. TCC：资金场景为什么用"冻结"而不是行锁

TCC 要求每个参与方实现三个接口：Try（预留）、Confirm（落实）、Cancel（释放）。支付下单的标准走法：

```text
Try     账户冻结 100 元 + 库存预扣 1 件（不真扣，先占住）
Confirm 真扣冻结额、真扣库存（落实）
Cancel  解冻返还、释放预扣（释放）
```

机制一句话：**Try 预留资源，等于应用层给中间态上锁**。它买到的隔离性正是 Saga 给不了的——并发请求踩不到未决资源，库存不会被重复扣。

【从业者判断】它与 2PC 的本质差别在锁的载体：行锁跨 RTT 是全局灾难，冻结字段跨 RTT 只是"这笔钱暂时不可用"。代价也直白：业务侵入最大，一张表拆三个动作，还要防空回滚和悬挂（第 6 节）。

## 5. Saga：把账记成流水，失败逆序补

Saga 把长流程拆成一串本地事务，每步配一个反向补偿，失败时逆序执行。订行程的经典链路：

```text
正向：建订单 → 扣机票库存 → 订酒店 → 租车
租车失败，逆序补偿：取消酒店 → 还机票库存 → 取消订单
```

必须认账的两个属性：**中间态对外可见，没有隔离性**（机票订上了、酒店还没订，用户看得见这个半成品）；**补偿逻辑是第二套业务代码**，同样要幂等可重试。

形态二选一，取舍点在出错定界：

| 形态 | 机制 | 取舍 |
|---|---|---|
| 编排 | 中心协调器按流程定义推进 | 定界容易，一眼看到走到哪步 |
| 协同 | 事件驱动，各服务听事件干活 | 耦合低，但流程散在各处，定界难 |

**Saga 拿隔离性换吞吐和长流程容忍度**，赌注是"中间态被看到也不致命"——所以它适合流程长、人工在环的业务，而不是账务核心。

## 6. 补偿的三个难点：幂等、空回滚、悬挂

柔性事务的共同底牌：**用"可重试的最终一致"换掉"锁住的强一致"**。重试必然带来重复，所以幂等不是可选项，是承重墙。三个难点逐个过：

**难点一，补偿必须幂等。** 补偿执行两次，库存就多退一份——补偿与正操作一样要过幂等设计。

**难点二，空回滚。** Try 因网络延迟没到，Cancel 先到了：没冻结过，解冻什么？

**难点三，悬挂。** Cancel 执行完，迟到的 Try 才到：预留的资源从此没人释放，账上永远挂着一笔冻结。

公共解法是一张事务控制表：每个分支事务记一条（事务 ID、状态），所有动作先查表再动身。现场复现，有 Docker 就行：

```bash
# [任意节点] 起 MySQL（端口错开，避免与本机实例冲突）
docker run -d --name idem-mysql -e MYSQL_ROOT_PASSWORD=root \
  -e MYSQL_DATABASE=idem -p 33061:3306 mysql:8.0
# 等 MySQL 就绪（约 20~40s）
until docker exec idem-mysql mysqladmin ping -uroot -proot --silent 2>/dev/null; do sleep 2; done
echo mysql-ready
```

```bash
# 建表：业务表（唯一键 + 状态机）+ 去重表
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

三段实验，每段都"同一操作执行两次，看第二次的 affected"：

```bash
# 实验 1（唯一键）：重试造成的重复插入被唯一键挡下
docker exec -i idem-mysql mysql -uroot -proot idem <<'EOF'
INSERT INTO orders (order_no, amount) VALUES ('ORD-1001', 99);
INSERT IGNORE INTO orders (order_no, amount) VALUES ('ORD-1001', 99);
-- 预期：第一条 affected 1；第二条 affected 0（重复被吞，效果只有一次）
EOF

# 实验 2（去重表）：模拟同一条消息被投递两次
docker exec -i idem-mysql mysql -uroot -proot idem <<'EOF'
INSERT IGNORE INTO consumed_messages (msg_id) VALUES ('MSG-20260830-0001');
SELECT ROW_COUNT();
INSERT IGNORE INTO consumed_messages (msg_id) VALUES ('MSG-20260830-0001');
SELECT ROW_COUNT();
-- 预期：第一次 1（执行业务），第二次 0（直接跳过）
EOF

# 实验 3（条件更新/状态机）：重放不产生副作用
docker exec -i idem-mysql mysql -uroot -proot idem <<'EOF'
UPDATE orders SET status='PAID' WHERE order_no='ORD-1001' AND status='INIT';
UPDATE orders SET status='PAID' WHERE order_no='ORD-1001' AND status='INIT';
-- 预期：第一次 affected 1，第二次 affected 0（重复回调幂等）
EOF
```

【从业者判断】空回滚与悬挂的落地防御正是实验 3 的状态机：Cancel 先到、查不到 Try 记录，就先写一条"已回滚"状态；迟到的 Try 再来，条件更新 affected 0，预留被拒——悬挂被挡在门外。

第四种模式是版本号乐观锁（`UPDATE ... SET v=v+1 WHERE id=? AND v=?`，按影响行数判定），并发更新同一行时用。

选型口诀：能落库就用唯一键，跨系统就上消息 ID 去重表，会并发就配版本号，有状态机就配条件更新——四者不互斥，生产常见"去重表 + 业务唯一键"双保险。

## 7. 本地消息表：跨系统双写的真身

多数场景里的"分布式事务"，拆到最后是同一个真身：业务写库成功之后，**把一条消息可靠地送到另一个系统**。双写的裂缝人尽皆知——写库成功、发消息前进程崩了，下游永远不知道这笔订单存在。

本地消息表（outbox）的解法：把业务写入和消息记录放进同一个本地事务，一荣俱荣、一损俱损。

```bash
# 补一张 outbox 表
docker exec -i idem-mysql mysql -uroot -proot idem <<'EOF'
CREATE TABLE outbox (
  msg_id     VARCHAR(64) PRIMARY KEY,
  topic      VARCHAR(64) NOT NULL,
  payload    JSON NOT NULL,
  sent       TINYINT NOT NULL DEFAULT 0,
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;
EOF
```

```bash
# 业务与消息记录同一个事务：两条 INSERT 同生共死
docker exec -i idem-mysql mysql -uroot -proot idem <<'EOF'
START TRANSACTION;
INSERT INTO orders (order_no, amount) VALUES ('ORD-1002', 199);
INSERT INTO outbox (msg_id, topic, payload)
VALUES ('MSG-ORD-1002', 'order.created', '{"order_no":"ORD-1002"}');
COMMIT;
-- 预期：Query OK，订单与待发消息要么都在、要么都不在
EOF
```

后台 relay 进程扫 outbox 投递，成功后标记：

```bash
docker exec -i idem-mysql mysql -uroot -proot idem <<'EOF'
UPDATE outbox SET sent=1 WHERE msg_id='MSG-ORD-1002' AND sent=0;
-- 预期：affected 1（relay 重试时 affected 0，标记本身幂等）
EOF
```

它保证的是"业务成功 ⇔ 消息必发"（at-least-once），三件配套缺一不可：下游必须幂等（重试会重复发，实验 2 的去重表就是给它配的）；outbox 要清理归档，不然无限膨胀；relay 积压要监控——**消息不会丢（还在表里），但会延迟**，盯"最老未发消息的年龄"这条曲线。

## 8. MQ 事务消息：承包"不丢"，承包不了"恰好一次"

三个常见误会，逐个拆。

**误会一：AMQP 事务（tx.select）能保消息不丢。** 它只是生产端信道上的同步提交点，只保证"本信道消息按序发出"，不覆盖路由成败、不等落盘、更不管消费端——连一个合格的 2PC 参与者都算不上。官方文档明确用 publisher confirm 替代它，新代码不要再用。

**误会二：开了 confirm 就是恰好一次。** confirm（quorum 队列下等的是多数派落盘）加 `mandatory=true` 处理路由失败，买到的只是"消息真的进了队列"。消费侧做不到恰好一次：ack 前断线必重投——幂等只能业务自己做。

**误会三：Kafka 事务能罩住外部系统。** `transactional.id`/epoch 能把"读 Kafka → 处理 → 写回 Kafka"做成端到端 exactly-once，但下游一旦是外部系统就退回 at-least-once；RabbitMQ 更弱，连"跨队列原子组"都没有，confirm 是逐条回执、不是原子组。

【从业者判断】RocketMQ 那类"事务消息"（half message 加状态回查）本质是把 outbox 从业务库挪进 broker：半消息先落地，本地事务成功才提交，broker 定时回查兜底。它省掉 relay 扫表，但"本地事务结果可回查"这门功课一件没少，下游照样要幂等。

一句话收束：**消息系统能承包"不丢"，承包不了"恰好一次"**——恰好一次永远由业务幂等收尾。

## 9. 一张决策树：一致性 × 吞吐 × 成本

选型不是挑框架，是先回答几个故障问题——"崩的那一刻，你愿意付出什么"：

```text
Q1 跨系统的"同时成功/同时失败"，业务上真的需要吗？
 │  └─ 先试"不分布"：合并库/同库不同表 → 单机事务收工
 ▼ 确实跨系统
Q2 事务中途崩溃/超时，允许对外可见的中间态吗？
 ├─ 不允许（资金划拨、账务核心，逐分钱可解释）
 │     ├─ 参与者少、事务毫秒级、流量可控 ──► XA/2PC
 │     │     纪律：参与者尽量少、事务尽量短、锁等待有监控与超时预案
 │     └─ 约束改不动 ──► 回去重新切分业务，把强一致边界缩小到一个库，
 │             而不是给烂边界套更强的协议
 └─ 允许（最终一致，靠补偿与对账兜住）
       Q3 中间态被并发踩到会出错吗？
       ├─ 会（库存被重复扣）──► TCC
       └─ 不会/流程长、人工在环 ──► Saga（编排 or 协同）
       Q4 "一致"的落点，是"把一条消息可靠送到另一系统"吗？
       └─ 是 ──► 本地消息表/outbox（第 7、8 节）
```

每片叶子在三个轴上各有定价：

| 方案 | 一致性/隔离 | 吞吐 | 成本记在哪 | 崩溃瞬间 |
|---|---|---|---|---|
| 合并单库 | ACID 全档 | 最高 | 业务拆分与容量规划 | 单机故障半径 |
| XA/2PC | 强一致，持锁隔离 | 低（锁跨 RTT） | 协调者运维+锁等待监控 | 抱锁等决策，锁堆积 |
| TCC | 最终一致，应用层隔离 | 中 | 每接口三实现+幂等防御 | 资源被冻结，可恢复 |
| Saga | 最终一致，无隔离 | 高 | 补偿=第二套业务代码 | 逆序补偿，补偿要幂等 |
| 本地消息表 | 最终一致，消息必发 | 高（多一行 INSERT） | relay 运维+下游幂等 | 消息延迟但不丢，积压可监控 |

读树两条纪律：**一致性每升一档，吞吐与成本就在标价，没有免费档位**；叶子是拼装件不是单选题——"单库事务包住账务 + outbox 发通知 + 外围 Saga"是常见组合，决策树按数据流逐段走。

## 现在就能做的事

5 分钟路径：把第 6、7 节跑一遍，每个实验执行两次、抄下第二次的 affected——那行 0，就是你家扣款接口未来挡掉的那笔重复退款。跑完清理：

```bash
docker rm -f idem-mysql
```

这套演练（幂等三板斧加 outbox 表结构）收在我维护的 SRE 学习仓库：GitHub 搜 sre-learning-hub，分布式模块第 04 章——同一章还有 Flink 把 2PC 装进 checkpoint 的角色映射表，和"恰好一次"真相的完整推导。

最后聊个实的：你们生产的扣款链路，现在站在决策树哪片叶子上？真在高峰期跑过 XA 的，评论区说说锁等待的体感——我想看看有多少团队是靠夜间对账活到今天的。
