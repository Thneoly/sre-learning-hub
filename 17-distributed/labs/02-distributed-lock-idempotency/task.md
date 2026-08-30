# Lab 02 · 分布式锁的坑与幂等兜底：Redis 单实例实操

> 难度：★★☆ ｜ 考点：分布式理论-互斥与 fencing（对应模块第 03/06 章） ｜ 前置：完成 11-middleware/redis 三章（尤其第 2 章持久化与 HA）、本模块 Lab 01 ｜ 预计 45~60 分钟

## 场景

你是交易组的 SRE。业务开发要在"库存扣减"接口里加一把 Redis 分布式锁防超卖，代码是网上抄的三行：`SET NX` 抢锁、干活、`DEL` 释放。上线前你来评审，你要能拿出**亲手复现的故障证据**而不是"听说有问题"。本 lab 用一个 Redis 单实例容器（复用 11-redis 已学的操作面）把三个坑逐个踩出来，再落地正确姿势（`SET key uuid NX PX` + Lua 校验删除），最后做一组幂等实验：同一个下单请求连点两次，无幂等键 = 两张订单，加了唯一键去重表 = 只有一张——重复消费/重复请求在分布式系统里不是意外是常态（Kafka 的 at-least-once 语义明确要求业务侧幂等，见 `../../../12-data-streaming/kafka/02-replication-and-reliability.md`）。

一个必须先想清楚的问题：**Redis 锁是"效率锁"不是"正确性锁"**。它防止重复干活，但不提供共识保证——真正要"绝对不双写"该去找共识系统（etcd/ZooKeeper，见 Lab 01）。评审结论通常是：单实例 + fencing/幂等兜底就够，本 lab 结束时你要能说出为什么。

命名约定（check.sh 依赖，请严格使用）：

| 对象 | 名字 | 说明 |
|---|---|---|
| 容器 | `dist-lock-redis`（redis:7.2） | 挂载 `~/dist-lock` 到容器 `/labs` |
| 工作目录 | `~/dist-lock/` | 脚本、Lua、全部实验记录 |
| 坑 1/2/3 的锁 key | `lock:naive:noexp` / `lock:naive:whoever` / `lock:naive:timeout` | 故意做错的三个 key |
| 正确姿势的锁 key | `lock:order:stock` | 用完必须已释放（不存在） |
| 幂等去重 key | `dedup:order:<request_id>` | SET NX PX 实现"唯一键去重表" |
| 订单流水 | `order:naive:booked` / `order:idem:booked` | 两个 list，对比用 |

实验记录文件（check.sh 要检查）：

| 文件 | 内容 |
|---|---|
| `~/dist-lock/unlock.lua` | 校验值再删除的 Lua 脚本 |
| `~/dist-lock/pitfall1.txt` | 坑 1 证据：TTL 为 -1 的输出 |
| `~/dist-lock/pitfall2.txt` | 坑 2 证据：误删他人锁的输出（DEL 返回 1 + GET 为 nil） |
| `~/dist-lock/pitfall3.txt` | 坑 3 证据：锁先于业务过期（TTL -2 或归属变更） |
| `~/dist-lock/orders-before.txt` | 无幂等保护：同一请求连点两次后的订单流水（应有两条） |
| `~/dist-lock/orders-after.txt` | 加去重表后：同一请求重放两次的流水（应只有一条） |
| `~/dist-lock/redlock-notes.md` | RedLock 争议小结（须含 antirez / kleppmann / fencing 三个词） |

## 任务清单

1. 启动 Redis 容器：`docker run -d --name dist-lock-redis -v ~/dist-lock:/labs redis:7.2`，`PING` 通；建目录 `~/dist-lock`
2. **坑 1 · 无过期 → 死锁**：客户端 A 用 `SET lock:naive:noexp owner-A NX`（没有 PX）抢到锁后"进程崩溃"（那个 docker exec 已经结束，永远不会有人来 DEL）。验证：`TTL lock:naive:noexp` 返回 `-1`；客户端 B 再 `SET ... NX` 抢锁永远 `(nil)`。把 TTL 输出存入 `pitfall1.txt`
3. **坑 2 · 锁值不校验 → 误删他人锁**：B 抢到锁（`SET lock:naive:whoever owner-B NX PX 60000`）业务未完；此时 A 的旧请求终于返回，无脑 `DEL lock:naive:whoever`（返回 1）；`GET` 已是 nil——B 还在干活锁却没了，C 立刻也能 `SET ... NX` 抢到。把 DEL 与 GET 的输出存入 `pitfall2.txt`
4. **坑 3 · 业务超时 → 锁先过期**：`SET lock:naive:timeout owner-A NX PX 3000`，然后 `sleep 5` 模拟业务比锁 TTL 长（慢 SQL / GC 停顿 / 网络抖动），醒来 `TTL` 已是 `-2`（或已被别人持有）。把前后两次 TTL 输出存入 `pitfall3.txt`，并想清楚：此时如果 A 还去执行无校验的 DEL，就回到了坑 2
5. **正确姿势**：生成 token（`cat /proc/sys/kernel/random/uuid`），`SET lock:order:stock <token> NX PX 10000`；业务；把 `~/dist-lock/unlock.lua`（内容见提示 1）用 `redis-cli --eval /labs/unlock.lua lock:order:stock , <token>` 释放——返回 `(integer) 1`；再演示持有后用**错误 token** 释放返回 `(integer) 0`。结束时 `lock:order:stock` 必须已不存在
6. **RedLock 争议**：阅读下面的背景段，用自己的话写 `~/dist-lock/redlock-notes.md`（三五句即可，必须出现 antirez、kleppmann、fencing 三个词）
7. **幂等实验 · 无保护**：写 `~/dist-lock/order_naive.sh`（见提示 2），同一个 request_id 连续执行两次，`LRANGE order:naive:booked 0 -1 > ~/dist-lock/orders-before.txt`——两条订单，这就是"用户双击 + 网关重试"的现场
8. **幂等实验 · 加去重表**：写 `~/dist-lock/order_idem.sh`（见提示 3），换一个新的 request_id 连续执行两次，`LRANGE order:idem:booked 0 -1 > ~/dist-lock/orders-after.txt`——只有一条订单
9. 运行 check.sh，`SCORE: 9/9` 后清理容器

### RedLock 背景段（任务 6 的输入）

RedLock 是 antirez（Redis 作者）提出的多数派加锁方案：向 N 个独立 Redis 实例依次 `SET NX`，超过半数成功且总耗时小于锁有效期才算拿到锁。Martin Kleppmann（《Designing Data-Intensive Applications》作者）公开批评：它依赖各节点时钟不走快（时钟跳变/GC 停顿会让"已过期"的锁被当成仍持有），且不带 fencing token，无法阻止持有过期锁的客户端继续写下游。antirez 回应：时钟问题可控、可以加 token。工程界的落地结论大致是：**多数正确性要求下，单实例锁 + 唯一约束/fencing token/幂等设计通常已经够；要绝对互斥就用共识系统（etcd/ZK）而不是更多 Redis**。

## 验收标准

- `dist-lock-redis` 运行中，PING 返回 PONG
- `unlock.lua` 存在且 check.sh 用 `redis-cli --eval` 实测：token 匹配返回 1，token 不匹配返回 0
- `orders-before.txt` 里同一个 request_id 出现 **≥2 次**；`orders-after.txt` 里出现 **恰好 1 次**
- `redlock-notes.md` 含 antirez、kleppmann、fencing 三个关键词
- `lock:order:stock` 不存在（正确姿势的锁没有悬挂）
- 三份 pitfall 记录齐全（check 不判分但 solution 会对照，面试时这就是你的案例库）

## 提示（卡住再看）

<details><summary>提示 1：unlock.lua（校验值再删，GET 与 DEL 在 Redis 内单线程原子执行）</summary>

```lua
-- ~/dist-lock/unlock.lua ：只删除自己持有的锁
-- KEYS[1] = 锁 key；ARGV[1] = 自己的 token
if redis.call("GET", KEYS[1]) == ARGV[1] then
  return redis.call("DEL", KEYS[1])
else
  return 0
end
```

运行（注意 `--eval` 的 key 与参数之间是 **空格逗号空格**）：

```bash
# [任意节点] 挂载在容器内 /labs/，redis-cli 在容器里跑，读的是容器内路径
docker exec dist-lock-redis redis-cli --eval /labs/unlock.lua lock:order:stock , "$TOKEN"
```
</details>

<details><summary>提示 2：order_naive.sh（无幂等保护）</summary>

```bash
#!/usr/bin/env bash
# [任意节点] ~/dist-lock/order_naive.sh —— 模拟下单接口：调一次记一单，没有任何防重
set -u
REQ_ID="${1:?用法: order_naive.sh <request_id> [amount]}"
AMT="${2:-199}"
R() { docker exec dist-lock-redis redis-cli --raw "$@"; }
N=$(R INCR order:naive:seq)
R LPUSH order:naive:booked "req=$REQ_ID amount=$AMT seq=$N" >/dev/null
echo "BOOKED req=$REQ_ID seq=$N"
```

`chmod +x` 后连点两次：`./order_naive.sh promo-2026-001; ./order_naive.sh promo-2026-001`
</details>

<details><summary>提示 3：order_idem.sh（唯一键去重表）</summary>

```bash
#!/usr/bin/env bash
# [任意节点] ~/dist-lock/order_idem.sh —— 带幂等键的下单
# dedup:order:<request_id> 就是"唯一键去重表"：SET NX 抢到才算第一次，重放全部跳过
# 生产里这张表通常是 MySQL 唯一索引（重复 insert 报 1062）或 Kafka 的事务去重，语义相同
set -u
REQ_ID="${1:?用法: order_idem.sh <request_id> [amount]}"
AMT="${2:-199}"
R() { docker exec dist-lock-redis redis-cli --raw "$@"; }
GOT=$(R SET "dedup:order:$REQ_ID" "$(hostname)-$$" NX PX 86400)
if [ "$GOT" != "OK" ]; then
  echo "DUPLICATE req=$REQ_ID skipped"
  exit 0
fi
N=$(R INCR order:idem:seq)
R LPUSH order:idem:booked "req=$REQ_ID amount=$AMT seq=$N" >/dev/null
echo "BOOKED req=$REQ_ID seq=$N"
```

用**新的** request_id 连点两次：`./order_idem.sh idem-2026-001; ./order_idem.sh idem-2026-001`——第一次 BOOKED，第二次 DUPLICATE。
</details>

<details><summary>提示 4：清理</summary>

```bash
# [任意节点] check 通过后
docker rm -f dist-lock-redis
```

记录文件留在 `~/dist-lock/` 无妨；重做前清掉旧记录避免误判。
</details>

## 关联阅读

- 本模块理论对应章："恰好一次 = at-least-once + 幂等"的推导与四种幂等模式（唯一键/去重表/版本号/条件更新）选型：`../../04-distributed-transactions.md` 第 5/6 节
- Redis 持久化与 HA 的底座（锁的可用性取决于它）：`../../../11-middleware/redis/02-persistence-and-ha.md`
- 哨兵 failover 演练（主从切换时锁丢没丢的问题在那里现场可见）：`../../../11-middleware/redis/labs/01-sentinel-failover/task.md`
- "多等一步换安全"的同类权衡：MySQL 半同步复制等从库 ACK（`../../../11-middleware/mysql/02-backup-replication.md` 半同步一节）、Flink 两阶段提交等 checkpoint 完成再 commit（`../../../12-data-streaming/flink/02-deployment-and-exactly-once.md` 第 5 节）
- 幂等的生产化身：Kafka producer 幂等（PID+seq 去重窗口，`../../../12-data-streaming/kafka/01-log-model-and-architecture.md` 第 7 节）、消费侧 at-least-once + 业务幂等键（`../../../12-data-streaming/kafka/02-replication-and-reliability.md`）
- 要"正确性锁"时的替代品：本模块 `../01-etcd-raft-observation/task.md`（etcd 的共识保证从哪来）
