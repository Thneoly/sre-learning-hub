# Lab 02 · 解答：分布式锁的坑与幂等兜底

> 逐步操作 + 原理对应 + 面试答法。先自己按 task.md 走，卡住再对照。
> 运行位置统一：装有 Docker 的 Ubuntu VM（`[任意节点]`，示例环境 user@172.30.30.50）。

## 0. 原理速览：三个坑是同一个坑的三种时间线

分布式锁的全部难点在于**锁的生命周期与业务的生命周期是两条线**，任何一处对不齐就出事：

```
理想：  |----持锁----业务----释放----|          两条线重合
坑1：   |----持锁----(客户端崩溃)             释放永远不会来 → 死锁（没 TTL）
坑2：   |----持锁----业务----释放----|
              |----别人已抢先持锁----|          释放删掉了别人的锁（没校验值）
坑3：   |----锁(TTL 3s)---|                    业务还没完，锁先没了（TTL < 业务时长）
              |--------业务 5s--------|
```

正确姿势 = 给锁一个**随机身份**（token）+ 一个**死期**（TTL）+ 一段**原子化的验身删除**（Lua）：

```
SET lock:order:stock <uuid> NX PX 10000     ← 抢锁：只允许第一次写入，且自带死期
... 业务 ...
EVAL unlock.lua lock:order:stock , <uuid>   ← 释放：值是自己的才删，GET+DEL 原子执行
```

## 1. 起环境

```bash
# [任意节点] 目录 + 容器（挂载让容器内 redis-cli 能读宿主上的 Lua/脚本）
mkdir -p ~/dist-lock
docker run -d --name dist-lock-redis -v ~/dist-lock:/labs redis:7.2
docker exec dist-lock-redis redis-cli PING
# 预期: PONG
```

单实例就够本 lab 用。这不是偷懒：**加节点不改变锁的语义**——主从异步复制下 failover 仍可能丢锁（哨兵提升从库时未同步的 SET 会丢，见 `../../../11-middleware/redis/labs/01-sentinel-failover/task.md` 里主从切换的数据窗口），这也是后文 RedLock 争论的起点。

## 2. 坑 1：无过期 → 死锁

```bash
# [任意节点] 客户端 A 抢锁（抄来的三行代码，没有 PX）
docker exec dist-lock-redis redis-cli SET lock:naive:noexp owner-A NX
# 预期: OK

# A 的进程此刻"崩溃"——docker exec 已结束，世界上再没有人会执行 DEL
docker exec dist-lock-redis redis-cli TTL lock:naive:noexp | tee ~/dist-lock/pitfall1.txt
# 预期: -1   ← 永不过期

# 客户端 B 永远抢不到锁：
docker exec dist-lock-redis redis-cli SET lock:naive:noexp owner-B NX
# 预期: (nil)
```

**运维后果**：表现为"某个定时任务/某类操作全体卡死，但 Redis 本身健康、CPU 空闲"。`TTL = -1` 是指纹。修复可以应急 `DEL`，根因是代码必须带 PX。这也是"为什么所有封装库（Redisson 等）都强制默认 leaseTime"。

## 3. 坑 2：锁值不校验 → 误删他人锁

```bash
# [任意节点] B 拿到锁，业务要跑一阵
docker exec dist-lock-redis redis-cli SET lock:naive:whoever owner-B NX PX 60000
# 预期: OK

# A 的旧请求（比如被 GC/慢查询卡了 30s）终于走到释放，无脑 DEL——不检查锁是谁的
docker exec dist-lock-redis redis-cli DEL lock:naive:whoever | tee -a ~/dist-lock/pitfall2.txt
# 预期: (integer) 1    ← 删的成功，但删的是 B 的锁

docker exec dist-lock-redis redis-cli GET lock:naive:whoever | tee -a ~/dist-lock/pitfall2.txt
# 预期: (nil)          ← B 还在临界区里干活，锁没了

# C 现在也能进来 —— B、C 同时持"锁"
docker exec dist-lock-redis redis-cli SET lock:naive:whoever owner-C NX PX 60000
# 预期: OK
```

**运维后果**：超卖/重复扣款类事故里最常见的一环，且**不留任何报错日志**——每一步都返回成功。这就是为什么"锁值必须是随机 token、删除必须先比对"。

## 4. 坑 3：业务超时 → 锁先过期

```bash
# [任意节点] A 持锁 3 秒，业务预计 1 秒
docker exec dist-lock-redis redis-cli SET lock:naive:timeout owner-A NX PX 3000
docker exec dist-lock-redis redis-cli TTL lock:naive:timeout | tee ~/dist-lock/pitfall3.txt
# 预期: 3

sleep 5   # 真实业务：慢 SQL、Full GC、容器 CPU 被限流、网络抖动……
docker exec dist-lock-redis redis-cli TTL lock:naive:timeout | tee -a ~/dist-lock/pitfall3.txt
# 预期: -2   ← 锁已消失，期间别人早已进出过临界区
```

**运维后果**：TTL 设短了互斥失效，设长了故障时阻塞加倍（坑 1 的温和版）。生产解法是**看门狗续期**：持锁线程定期把 TTL 延长（Redisson 的 watchdog 就是后台定时 `EXPIRE`），进程死掉则无人续期、锁自然过期——用"续期"代替"一次拍脑袋定死 TTL"。本 lab 不实现续期，但要能说出它的名字和它解决的是哪条时间线。

坑 3 与坑 2 是连环的：锁过期后 A 若再执行无校验的 DEL，删的就是新持有者的锁。所以正确姿势的两个要素（token + Lua）缺一不可。

## 5. 正确姿势：SET NX PX + Lua 验身删除

```bash
# [任意节点] 写脚本
cat > ~/dist-lock/unlock.lua <<'EOF'
-- 只删除自己持有的锁：GET 与 DEL 都在 Redis 单线程里执行，天然原子
if redis.call("GET", KEYS[1]) == ARGV[1] then
  return redis.call("DEL", KEYS[1])
else
  return 0
end
EOF

# 抢锁：值是随机 token（uuid），NX 只许第一次，PX 10s 兜底死锁
TOKEN=$(cat /proc/sys/kernel/random/uuid)
echo "token=$TOKEN"
docker exec dist-lock-redis redis-cli SET lock:order:stock "$TOKEN" NX PX 10000
# 预期: OK

# 业务（省略）……然后释放：只有值等于自己的 token 才 DEL
docker exec dist-lock-redis redis-cli --eval /labs/unlock.lua lock:order:stock , "$TOKEN"
# 预期: (integer) 1

# 反向验证：先补一把锁（模拟别人持有），用错误 token 释放
docker exec dist-lock-redis redis-cli SET lock:order:stock "someone-else" NX PX 10000
docker exec dist-lock-redis redis-cli --eval /labs/unlock.lua lock:order:stock , "wrong-token"
# 预期: (integer) 0   ← 拒绝误删

# 把别人的锁清掉，终态 key 不存在（check 第 9 项查的就是它）
docker exec dist-lock-redis redis-cli EVAL "$(cat ~/dist-lock/unlock.lua)" 1 lock:order:stock someone-else
# 预期: (integer) 1
```

为什么必须是 Lua：`GET` 判断 + `DEL` 两步如果分开做，中间可能恰好过期切换持有者（坑 3 + 坑 2 叠加窗口）。Lua 脚本在 Redis 内原子执行，消除这个窗口。`--eval` 的分隔符是"空格逗号空格"，写错会把参数当 key 处理，报 wrong number of arguments。

一句话面试版：**抢锁用 `SET key <随机token> NX PX <ttl>`，释放用 Lua 比对 token 再删；TTL 兜底死锁，token 防误删，原子释放防过期窗口。**

## 6. RedLock：一段话答清楚

写入 `~/dist-lock/redlock-notes.md` 的参考版本（自己的话写，关键词齐全即可）：

> antirez 的 RedLock：向 N 个独立 Redis 实例依次 SET NX，过半成功且总耗时小于有效期才算持锁，用多数派对抗单点丢失。Kleppmann 的批评：它依赖时钟不跳变，且没有 fencing token，GC 停顿/时钟跳变后持有"过期锁"的客户端仍会继续写下游，安全性不成立。结论：多数业务用单实例锁 + fencing token（或唯一约束/幂等）已够；确实需要严格互斥时用共识系统（etcd/ZooKeeper）而不是堆 Redis 实例。

补两句背景好在面试里加分：

- fencing token 的通用形态是**单调递增号**：锁服务每次授权发一个更大的号，存储侧拒绝比已见过的号更老的写——etcd 的 revision、ZK 的 zxid 天然就是这种号，所以它们能做"正确性锁"（Lab 01 的 MVCC revision 就是现成的）。MySQL 侧的等价物是唯一索引。
- "多等一步换安全"在别的中间件里你已经见过：MySQL 半同步让 commit 等一个从库 ACK（`../../../11-middleware/mysql/02-backup-replication.md` 半同步一节），Flink 的 KafkaSink 等整个 checkpoint 完成才提交事务（2PC，`../../../12-data-streaming/flink/02-deployment-and-exactly-once.md` 第 5 节）。锁、复制、事务的权衡骨架相同：多一次确认，换掉一类丢失。

## 7. 幂等实验

### 7.1 无保护：连点两次 = 两张订单

```bash
# [任意节点] 脚本内容见 task.md 提示 2
chmod +x ~/dist-lock/order_naive.sh
cd ~/dist-lock
./order_naive.sh promo-2026-001        # 用户第 1 次点击
./order_naive.sh promo-2026-001        # 用户手抖/网关超时重试
# 预期:
# BOOKED req=promo-2026-001 seq=1
# BOOKED req=promo-2026-001 seq=2

docker exec dist-lock-redis redis-cli LRANGE order:naive:booked 0 -1 | tee ~/dist-lock/orders-before.txt
# 预期（两条，同一个请求）:
# req=promo-2026-001 amount=199 seq=2
# req=promo-2026-001 amount=199 seq=1
```

### 7.2 加唯一键去重表：重放只有一张

```bash
# [任意节点] 脚本内容见 task.md 提示 3
chmod +x ~/dist-lock/order_idem.sh
./order_idem.sh idem-2026-001          # 第一次
./order_idem.sh idem-2026-001          # 重放（同 request_id）
# 预期:
# BOOKED req=idem-2026-001 seq=1
# DUPLICATE req=idem-2026-001 skipped

docker exec dist-lock-redis redis-cli LRANGE order:idem:booked 0 -1 | tee ~/dist-lock/orders-after.txt
# 预期（只有一条）:
# req=idem-2026-001 amount=199 seq=1
```

原理一句话：`SET dedup:order:<request_id> ... NX PX` 把"这个请求处理过没有"变成一次原子判断——NX 决定第一次与重放天然可区分，PX（86400）保证去重表本身不会无限膨胀。**这和 Kafka producer 幂等是同一个模式**：broker 按 `<PID, seq>` 去重窗口拒绝重复写入（`../../../12-data-streaming/kafka/01-log-model-and-architecture.md` 第 7 节），消费侧 at-least-once 语义下重复投递是常态，靠业务幂等键吸收（`../../../12-data-streaming/kafka/02-replication-and-reliability.md`）。生产落地时这张去重表更常是 MySQL 唯一索引（重复 insert 报 `Duplicate entry ... error 1062`），语义与本实验完全一致。

注意边界：Redis 实现的去重表随数据丢失（重启/主从切换）而失效，兜底 TTL 到期后同号重放也会再次通过——**幂等键的持久性要求有多高，决定去重表放哪**。资金类场景放数据库唯一索引或 Kafka 事务，不放缓存。

## 8. 判分与清理

```bash
# [任意节点] 在 check.sh 所在目录
chmod +x check.sh && ./check.sh
```

通过输出：

```
PASS: dist-lock-redis 容器在运行
PASS: PING 返回 PONG
PASS: unlock.lua 存在且含 GET/ARGV[1]/DEL 校验逻辑
PASS: Lua 释放：token 匹配返回 1 且锁被删除
PASS: Lua 释放：token 不匹配返回 0 且锁未被误删
PASS: orders-before.txt 显示无幂等保护时重复下单产生了多条流水
PASS: orders-after.txt 显示加去重表后重放只剩一条流水
PASS: redlock-notes.md 覆盖 antirez/kleppmann/fencing 三个要点
PASS: lock:order:stock 已正确释放（无悬挂锁）

SCORE: 9/9
```

（check 第 4/5 项会在 redis 里写一个一次性的 `lock:labcheck:<pid>` 键做正反验证，随后清理，不动你的实验数据。）

```bash
# [任意节点] 清理
docker rm -f dist-lock-redis
```

## 9. 自测（面试怎么答）

<details><summary>1. 为什么 DEL 之前必须校验锁值？校验和删除分两条命令发不行吗？</summary>

不校验就会删掉别人的锁（坑 2）：业务超时/暂停后锁可能已易主。分两条命令也不行——GET 和 DEL 之间锁恰好过期被别人抢走，DEL 一样误删；必须用 Lua（或事务+WATCH）让"比对+删除"原子执行。
</details>

<details><summary>2. Redis 主从 + 哨兵架构下，锁还安全吗？</summary>

不严格安全：主库确认 SET 后未同步到从库就宕机，哨兵提升从库，锁丢失，第二个客户端可再次抢到。这是异步复制的固有窗口（`11-middleware/redis/labs/01-sentinel-failover` 里切换实验可见数据窗口）。RedLock 想用多数派解决这个问题但引出时钟争议；工程答案是把正确性交给 fencing token/幂等，或改用 etcd/ZK。
</details>

<details><summary>3. 客户端拿到锁之后进程卡了 30 秒（GC），锁 10 秒就过期了，怎么兜底？</summary>

锁只保证"开始时互斥"，不保证"全程互斥"。兜底在下游：写库存/订单时校验 fencing token（或版本号、唯一索引），让拿着旧授权的写被拒绝。续期看门狗能缩小窗口但不能证明消除（续期请求本身也可能迟到）。这道题考的是"锁不是事务"。
</details>

<details><summary>4. 幂等键去重表为什么必须带过期时间/清理策略？放 Redis 和放 MySQL 各有什么代价？</summary>

不带过期，表无限增长（每次请求一行/一键）。放 Redis：判断原子且快，但随故障丢数据，重放会穿透；放 MySQL 唯一索引：持久、和业务事务同库可原子提交，但每请求多一次写盘。按业务"重放窗口 + 丢失代价"选：普通接口 Redis + TTL 即可，资金/订单用唯一索引。
</details>

<details><summary>5. 如果面试官问"那你们为什么不用 etcd 做锁"？</summary>

答权衡而不是答教条：etcd 有共识与 revision（天然 fencing），正确性强；但它是为低频元数据设计的（`04-k8s-fundamentals/13` 章：别拿 etcd 当通用数据库），高并发短临界区会把控制面存储打垮。库存扣减这类高频场景用"Redis 效率锁 + 下游唯一约束"更合适；低频关键互斥（选主、任务分派）才值得上 etcd/ZK。
</details>

## 延伸阅读

- Redis 官方文档 Distributed locks（含 RedLock 与正确性讨论）：https://redis.io/docs/latest/develop/use/patterns/distributed-locks/
- Martin Kleppmann, "How to do distributed locking"：https://martin.kleppmann.com/2016/02/08/how-to-do-distributed-locking.html
- antirez 对 Kleppmann 的回应 "Is Redlock safe?"：https://antirez.com/news/101
- SET 命令 NX/PX 语义（官方）：https://redis.io/commands/set/
