# 01 · Redis 数据结构与内存：编码转换、碎片率与 bigkey 治理

> 模块：11-middleware/redis ｜ 建议时长：3 小时 ｜ 关联认证：—（CKA/CKS/PCA 无直接考点；本章是 Redis 容量规划、慢查询排障、监控指标解读的地基，第 2/3 章与 sentinel lab 都建立在这些概念上）

## 学习目标

- 能解释 SDS 相比 C 字符串的四个优势，并推导 embstr 与 raw 的 44 字节分界是怎么来的
- 能画出 dict 渐进式 rehash 的双表结构，解释 rehash 期间查找为什么要查两张表
- 能根据 `OBJECT ENCODING` 输出判断当前编码，说出触发编码转换的阈值参数
- 能读懂 `INFO memory` 关键字段，用 `mem_fragmentation_ratio` 区分碎片与 swap 两种相反的异常
- 能操作 `redis-cli --bigkeys`、`--hotkeys`、`MEMORY USAGE` 定位 bigkey/hotkey，并说出其危害与治理手段

版本约定：本文以 **Redis 7.2** 行为准（docker 镜像 `redis:7.2`），与 7.0 之前 ziplist 时代旧资料的差异在第 7 节专门对照。

## 1. 两层结构：redisObject 与底层编码

Redis 对每个值维护两层结构：上层是统一的 `redisObject`（类型层），下层是具体数据结构（编码层）。同一个 TYPE 可以有多种 ENCODING，Redis 按数据特征自动选择省内存的那种：

```
  客户端命令 SET user:1 alice
        │
        ▼
┌─────────────────────────────────┐
│ redisObject                     │
│  type     = OBJ_STRING          │ ← TYPE user:1 看到的是这层
│  encoding = OBJ_ENCODING_EMBSTR │ ← OBJECT ENCODING user:1 看到的是这层
│  lru      = LRU/LFU 时钟与计数  │ ← 淘汰策略用的元数据（第 3 章）
│  refcount = 1                   │
│  ptr      ──► SDS / listpack / skiplist / dict / intset ...
└─────────────────────────────────┘
```

- `type` 决定命令语义（`TYPE key` 返回 string/hash/list/set/zset/stream）。
- `encoding` 决定该值当前用哪种物理结构存储（`OBJECT ENCODING key`）。
- 小数据用紧凑结构（listpack/intset）省内存、对 CPU cache 友好；超过阈值自动转成支持 O(1)/O(logN) 操作的结构。
- **编码转换是自动且单向的**：超阈值会升级，之后删数据降回阈值以下也不会降级（intset 同样只升不降）。

排障意义：一个 hash 从 listpack 变成 hashtable，内存可能跳涨数倍；反过来把阈值调得过大，`HGETALL` 这类 O(N) 命令又会在单线程里阻塞所有请求。这是"同一份数据、不同内存与延迟"的根源。

## 2. SDS：Simple Dynamic String

Redis 自建的字符串结构（3.2 起按长度分 5 种头，最常用 `sdshdr8`）：

```
+--------+--------+--------+------------------------------------+------+
| len 1B |alloc 1B|flags 1B| buf[]（内容，二进制安全）             | '\0' |
+--------+--------+--------+------------------------------------+------+
 已用长度  总容量   头类型                                    兼容 C 函数
```

相比 C 字符串的四个优势：

| 特性 | C 字符串 | SDS |
|---|---|---|
| 取长度 | O(N) 遍历 | O(1) 读 `len`，`STRLEN` 不卡 |
| 缓冲区安全 | 可能越界写坏相邻内存 | 修改前检查 `alloc`，空间不够先扩容 |
| 二进制安全 | 遇 `\0` 截断 | 按 `len` 存取，可存图片/序列化对象 |
| 内存预分配 | 每次 realloc | < 1MB 翻倍、≥ 1MB 每次 +1MB，摊薄分配次数；缩短后惰性保留空间 |

44 字节分界的推导（面试高频）：`embstr` 把 redisObject 和 SDS 放进**一块连续内存、一次分配**。redisObject 头 16B + sdshdr8 头 3B + 字符串结尾 `'\0'` 1B = 20B 固定开销；jemalloc 按 16B 的 size class 分配，64B 桶去掉 20B 开销，正好容纳 **44 字节**内容。超过就是 `raw`（两次分配、两块内存）。embstr 只读：`APPEND`、`SETRANGE` 等原地修改会先把它转成 raw。

## 3. dict 与渐进式 rehash

hash 类型底层（以及整个 keyspace 本身）用的就是 dict——数组 + 链地址法，冲突节点形成链表。它最大的运维知识点是**渐进式 rehash**：

```
rehash 开始前                        rehash 进行中（rehashidx 指向待迁移桶）
┌────────┐                          ┌────────┐      ┌────────┐
│ ht[0]  │  桶数组 size=N            │ ht[0]  │      │ ht[1]  │ 桶数组 size=2N
│ used=k │                          │ used=70│      │ used=30│
└────────┘                          └────────┘      └────────┘
                                       │  未迁移部分       ▲
                                       ▼                  │
                                    [桶3][桶4][桶5] ──迁移──┘
                                    rehashidx=3：每次增删改查顺手迁 1 个桶
```

关键规则：

- 触发扩容：负载因子（used/size）≥ 1 时扩到不小于 used*2 的 2 的幂；**有 BGSAVE/BGREWRITEAOF 子进程在跑时阈值提高到 5**（尽量避免 fork 期间再 copy 页）。
- 缩容：负载因子 < 0.1 时缩到最小能装下的 2 的幂。
- rehash 期间：新增只写 ht[1]；查找/删除/更新先查 ht[0] 再查 ht[1]；每次 CRUD 顺手迁移 1 个桶，迁完交换表、`rehashidx` 置 -1。
- 为什么渐进式：一次性 rehash 百万级 key 会卡住主线程数百毫秒以上；渐进式把代价摊到每个操作里。
- 代价：rehash 期间两张表并存，内存短时上升；`SCAN` 遍历两表，可能重复返回同一 key（客户端要幂等）。

## 4. list 与 listpack：紧凑列表

**listpack**（7.0 起全面替换 ziplist）：一块连续内存里逐个存放 `[总长][内容][backlen 反向长度]`，每个节点只记录自己的长度，不记录前后指针。

```
+--------+ +--------+ +--------+
│entry[0]│ │entry[1]│ │entry[2]│   连续内存，遍历靠长度跳转
+--------+ +--------+ +--------+
  头部记 total bytes 与元素数；尾部记 0xFF 结束符
```

- 优点：省指针（每元素零指针开销）、内存连续、cache 友好；listpack 修掉了 ziplist 的"级联更新"问题（节点只存自身长度，改一个不影响别人）。
- 缺点：中间插删要 memmove 整块内存，O(N)；只适合小集合，所以每种类型都有阈值。

**list 类型 = quicklist**：双向链表串起多个 listpack 节点，兼顾"大列表"与"节点内紧凑"：

```
quicklist ⟷ [listpack 节点 ≤8KB] ⟷ [listpack 节点] ⟷ [listpack 节点] ⟷
             参数 list-max-listpack-size -2（每节点最大 8KB，负数表示字节数）
             参数 list-compress-depth 0（两端多少个节点不压缩，LZF 压缩中间节点）
```

## 5. zset 与 skiplist：跳表

zset 超过阈值后用 **skiplist + dict 双结构**：dict 提供 member→score 的 O(1) 查询，skiplist 提供按 score 的有序能力。

```
 level4 ─────────────────────────────────────► NULL
 level3 ──────► [95]──────────────► NULL
 level2 ──────► [95]────► [99]────► NULL
 level1 ─► [17]─► [22]─► [95]─► [99]─► NULL   ← level1 是双向链表（有 backward 指针）
 head      17     22     95     99            （score 排序示意）

 每个节点插入时以 1/4 概率升一层，最大 32 层
 平均每节点 1/(1-0.25) ≈ 1.33 个前进指针
 节点里的 span（跨度）让 ZRANK / ZRANGE 这类按排名的查询保持 O(logN)
```

为什么用跳表而不是红黑树（自问自答，面试高频）：

- 范围查询 `ZRANGEBYSCORE` 直接沿 level1 双向链表走，比平衡树中序遍历简单；
- 实现简单，无旋转、无再平衡，概率性平衡即可；
- 内存可控（平均 1.33 指针/节点），且配套 dict 才能做到 member 精确查找 O(1)——红黑树做不到这组合。

## 6. set 与 intset：整数集合

全是整数且元素个数 ≤ 512 时，set 用 **intset**：有序整型数组，查找二分 O(logN)。

```
+-----------+-----+----------------------------+
| encoding  | len | contents（升序整数数组）     |
| INT16/32/64│ 4  │ [1, 5, 10, 500]            |
+-----------+-----+----------------------------+
 插入更大范围的整数时整体升级编码：int16 → int32 → int64（重分配+逐个搬移）
 只升不降；插入非整数元素则整体转成 listpack/hashtable
```

## 7. 编码转换规则总表（Redis 7.2 默认值）

| TYPE | ENCODING | 转换条件 | 相关参数 |
|---|---|---|---|
| string | int | 值可解析为 long 且长度 ≤ 20 | — |
| string | embstr | 长度 ≤ 44 字节（创建时判定） | — |
| string | raw | 长度 > 44，或 embstr 被原地修改 | — |
| list | quicklist | 恒为 quicklist（节点内为 listpack） | `list-max-listpack-size -2`、`list-compress-depth 0` |
| hash | listpack | 条目 ≤ 128 且 field/value 各 ≤ 64B | `hash-max-listpack-entries 128`、`hash-max-listpack-value 64` |
| hash | hashtable | 超出上述任一阈值 | 同上 |
| set | intset | 全整数且元素 ≤ 512 | `set-max-intset-entries 512` |
| set | listpack | （7.2+）元素 ≤ 128 且每个 ≤ 64B | `set-max-listpack-entries 128`、`set-max-listpack-value 64` |
| set | hashtable | 含非整数或超出阈值 | 同上 |
| zset | listpack | 元素 ≤ 128 且 member ≤ 64B | `zset-max-listpack-entries 128`、`zset-max-listpack-value 64` |
| zset | skiplist | 超出阈值（skiplist + dict） | 同上 |

旧资料对照：7.0 起 hash/zset/list 的 ziplist 全部换成 listpack，配置名从 `*-max-ziplist-*` 改为 `*-max-listpack-*`；set 的 listpack 编码 7.2 才引入（7.0/7.1 的小 set 只有 intset 与 hashtable 两态）。看资料先看版本。

## 8. 内存构成、碎片率与 maxmemory

### 8.1 一台 Redis 的内存花在哪

```
┌────────────────────────── used_memory（INFO memory，分配器视角）──────────────────────────┐
│  数据本身：key 对象 + SDS + listpack/skiplist/dict + 编码元数据                             │
│  内部开销 used_memory_overhead：客户端 buffer、复制积压 repl backlog、                      │
│    AOF/RDB 缓冲、dict 桶数组、LFU/LRU 元数据 ……                                           │
└──────────────────────────────────────────────────────────────────────────────────────────┘
┌────────────────────────── used_memory_rss（操作系统视角，进程驻留内存）────────────────────┐
│  used_memory + 分配器碎片（jemalloc size class 未用满）+ 页级碎片 + fork COW 脏页          │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

### 8.2 mem_fragmentation_ratio：一个比值两种病

`mem_fragmentation_ratio = used_memory_rss / used_memory`：

| 比值区间 | 含义 | 动作 |
|---|---|---|
| 1.0 ~ 1.5 | 正常（有少量分配器/页碎片） | 不处理 |
| > 1.5（如 2.0） | 碎片偏高：频繁删改、大小不一的 value、页未归还 OS | 观察是否持续；必要时开启 `activedefrag` 或低峰滚动重启 |
| < 1.0（如 0.85） | **比碎片危险得多：发生 swap**，部分页被换到磁盘 | 立刻查宿主机/容器内存 limit、cgroup OOM 事件； Redis 官方建议 `vm.swappiness` 调到 1 并保证物理内存充足 |

主动碎片整理（4.0+，jemalloc 构建，官方镜像满足）：

```bash
# [任意节点] 碎片率持续 > 1.5 时在线开启（不重启）
docker exec redis-ds redis-cli CONFIG SET activedefrag yes
docker exec redis-ds redis-cli CONFIG SET active-defrag-ignore-bytes 100mb      # 碎片绝对量小于此值不整理
docker exec redis-ds redis-cli CONFIG SET active-defrag-threshold-lower 10     # 碎片率低于 10% 不整理
docker exec redis-ds redis-cli CONFIG SET active-defrag-threshold-upper 100    # 高于此值全力整理（占 CPU 上限）
docker exec redis-ds redis-cli CONFIG GET activedefrag
```

注意：defrag 要拷贝数据、消耗 CPU，只在碎片率确实高且 CPU 有余量时开。

### 8.3 maxmemory

- `maxmemory 0` 表示不限制（默认），Redis 会一直吃内存直到被 OOM kill——生产必设。
- **不要设成等于机器/容器内存**：要给 fork COW（第 2 章 RDB）、复制缓冲、碎片留余量，经验值是物理内存的 70%~80%。
- 达到 maxmemory 后行为由 `maxmemory-policy` 决定（8 种策略对比见第 3 章）；默认 `noeviction` 会直接报 `OOM command not allowed when used memory > 'maxmemory'`。
- 7.x 里 replica 默认 `replica-ignore-maxmemory yes`：从库不打满也不淘汰，直到主库把它提升。

## 9. bigkey 与 hotkey

### 9.1 bigkey：多大算大

参考线（各团队标准不同，给常用值）：String value > 10KB，或集合类型元素数 > 5000 / 序列化后 > 1MB。

四类危害，全部最终表现为"线上抖动"：

| 危害 | 机理 |
|---|---|
| 单线程阻塞 | `HGETALL`/`SMEMBERS`/`LRANGE` O(N) 一次读出几十万元素，期间所有请求排队 |
| 删除卡顿 | 同步 `DEL` 要逐个释放，百万元素可卡秒级（用 `UNLINK` 异步释放） |
| 内存与槽倾斜 | Cluster 里 key 只属于一个槽/节点，大 key 把单节点内存与带宽打爆 |
| 过期风暴 | 同一时刻大量元素过期/淘汰，触发集中淘汰与业务回源雪崩（第 3 章） |

发现手段（由粗到细）：

```bash
# [任意节点] 在线采样：给每种类型找 top1 与均值，不阻塞（生产可用，但结果有采样误差）
redis-cli --bigkeys
redis-cli --bigkeys -i 0.1          # 每 100 个 key sleep 0.1s，进一步降低影响

# [任意节点] 精确测量单个 key（集合类默认采样估算，SAMPLES 0 全量扫描）
redis-cli MEMORY USAGE user:1001
redis-cli MEMORY USAGE big:hash SAMPLES 0

# [任意节点] 全量离线分析：备份 RDB 后用工具扫，不碰线上
# rdb-tools / redis-rdb-cli（GitHub 官方仓库），输出 top N 大 key 报表
```

治理：拆分（`hash:{uid}` 分桶）、压缩 value 后再存、改用 `UNLINK`/配置 `lazyfree-lazy-user-del yes`、给大集合的读改成 `HSCAN`/`SSCAN` 游标分页。

### 9.2 hotkey：访问集中的 key

危害：单 key QPS 极高时，Cluster 模式无法靠加节点分摊（key 不会被拆到两个节点），单节点 CPU 与带宽先死。

发现手段：

```bash
# [任意节点] LFU 计数排行（要求 maxmemory-policy 是 allkeys-lfu / volatile-lfu，见第 3 章）
redis-cli CONFIG SET maxmemory-policy allkeys-lfu
redis-cli --hotkeys
redis-cli OBJECT FREQ user:1001            # 单 key 的 LFU 计数

# [任意节点] MONITOR 实时看命令流（生产环境严禁长时间开，输出量本身会拖垮实例）
redis-cli MONITOR | grep --line-buffered '"get" "user:1001"' | head
```

更稳妥的做法是在客户端/proxy 层统计 key 访问频次。治理：本地多级缓存（进程内 cache 兜住读）、key 打散（`user:1001:{0..7}` 随机选一副本写、全部副本读）、读走 replica。

## 实战演练

环境：装有 Docker 的 Ubuntu VM（下同，所有命令标注 `[任意节点]`）。

```bash
# [任意节点] 起观察实例
docker run -d --name redis-ds -p 6401:6379 redis:7.2
```

```bash
# [任意节点] string 三种编码：int / embstr / raw
docker exec redis-ds redis-cli SET num 12345
docker exec redis-ds redis-cli OBJECT ENCODING num     # 预期: int
docker exec redis-ds redis-cli SET s hello
docker exec redis-ds redis-cli OBJECT ENCODING s       # 预期: embstr
docker exec redis-ds redis-cli SET big "$(printf 'x%.0s' $(seq 1 45))"
docker exec redis-ds redis-cli OBJECT ENCODING big     # 预期: raw（45 字节 > 44）
docker exec redis-ds redis-cli SET mut hello
docker exec redis-ds redis-cli APPEND mut world
docker exec redis-ds redis-cli OBJECT ENCODING mut     # 预期: raw（embstr 不可原地修改）
```

```bash
# [任意节点] hash：listpack → hashtable（写满 129 个 field 触发）
docker exec redis-ds redis-cli HSET h f0 v0
docker exec redis-ds redis-cli OBJECT ENCODING h       # 预期: listpack
for i in $(seq 1 128); do docker exec redis-ds redis-cli HSET h "f$i" "v$i" >/dev/null; done
docker exec redis-ds redis-cli OBJECT ENCODING h       # 预期: hashtable
docker exec redis-ds redis-cli CONFIG GET hash-max-listpack-entries
```

```bash
# [任意节点] zset 与 set 的编码
docker exec redis-ds redis-cli ZADD z 1 m1
docker exec redis-ds redis-cli OBJECT ENCODING z                     # 预期: listpack
docker exec redis-ds redis-cli ZADD z 1 "$(printf 'm%.0s' $(seq 1 65))"
docker exec redis-ds redis-cli OBJECT ENCODING z                     # 预期: skiplist
docker exec redis-ds redis-cli SADD s 1 2 3
docker exec redis-ds redis-cli OBJECT ENCODING s                     # 预期: intset
docker exec redis-ds redis-cli SADD s a
docker exec redis-ds redis-cli OBJECT ENCODING s                     # 预期: listpack（7.2+）
```

```bash
# [任意节点] 制造并定位 bigkey
docker exec redis-ds redis-cli SET bigstr "$(printf 'v%.0s' $(seq 1 500000))"
for i in $(seq 1 3000); do docker exec redis-ds redis-cli RPUSH biglist "item-$i" >/dev/null; done
docker exec redis-ds redis-cli --bigkeys
docker exec redis-ds redis-cli MEMORY USAGE bigstr        # 预期: 约 500KB（含对象与 SDS 开销）
docker exec redis-ds redis-cli MEMORY USAGE biglist SAMPLES 0
docker exec redis-ds redis-cli INFO memory | grep -E 'used_memory_human|used_memory_rss_human|mem_fragmentation_ratio'
# 预期: used_memory 约 1MB 出头；RSS 可能明显更大——小实例页/分配器开销占比高，属正常
```

验证方法：每条 `OBJECT ENCODING` 的输出与上表对照；`MEMORY USAGE` 与 `STRLEN`/`LLEN` 交叉验证量级。做完清理：`docker rm -f redis-ds`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 资料说 ziplist，线上 `OBJECT ENCODING` 显示 listpack | 7.0 起 ziplist 已被 listpack 替换，配置名同步改名 | 以 `redis-cli INFO server` 里的 redis_version 对照版本看资料 |
| `APPEND` 之后 String 内存翻倍 | embstr 转 raw，新旧两段短暂并存 | 正常现象；频繁追加的 key 直接预生成 |
| 碎片率 0.9 比 2.0 报警更急 | RSS < used_memory 说明数据在 swap | 查内存 limit/宿主机内存，尽快归还内存或迁移实例 |
| `--bigkeys` 找不到已知的大 key | 采样算法，key 越多越容易漏 | `MEMORY USAGE` + SCAN 或离线 RDB 分析 |
| `DEL` 一个百万元素的 hash 卡 2 秒 | 同步释放内存阻塞主线程 | 用 `UNLINK`；配 `lazyfree-lazy-user-del yes` |
| 删掉一半元素后内存没降 | 编码不降级 + 分配器惰性归还 + 页碎片 | 预期行为；必要时 `activedefrag` 或低峰重启 |

## 自测

1. 为什么 embstr 与 raw 的分界是 44 字节？写出推导。
<details><summary>答案</summary>

redisObject 头 16B + sdshdr8 头 3B + 结尾 '\0' 1B = 20B 固定开销。embstr 要求对象与字符串一次分配、放在一块 64B 的 jemalloc size class 里，64 - 20 = 44 字节正好用满这一档；再长一档浪费率上升，就切成 raw（对象与 SDS 各自分配）。
</details>

2. dict 渐进式 rehash 期间执行 `GET`，Redis 要查几张表？为什么 `SCAN` 此时可能重复返回同一个 key？
<details><summary>答案</summary>

查两张：先 ht[0] 再 ht[1]。因为迁移是一桶一桶进行的，key 可能在任意一张表里。SCAN 的游标用"反向二进制迭代"顺序保证扩缩容时不会整体漏桶（已扫描桶在扩容后的映射关系仍先于未扫描桶被覆盖到），代价是部分桶可能被访问两次，因此 key 可能重复返回——客户端必须幂等。SCAN 只保证"遍历全程都存在的 key 至少返回一次"。
</details>

3. 把 `hash-max-listpack-entries` 调到 100000 图省内存，会引入什么新问题？
<details><summary>答案</summary>

一是 O(N) 命令阻塞：10 万元素的 hash 走 listpack，`HGETALL` 一次读出全部，单线程下卡住所有请求；二是 listpack 是连续内存，中间插删要整块 memmove，尾部增长反复 realloc 拷贝；三是到达阈值那一刻一次性转 hashtable，转换本身也卡。省内存要以读写模式为前提：只小范围读 field 的 hash 才适合放大阈值。
</details>

4. zset 为什么选 skiplist 而不是红黑树？
<details><summary>答案</summary>

范围查询（ZRANGEBYSCORE）沿底层双向链表顺序走即可，实现与性能都优于平衡树中序遍历；插入删除只改指针、无旋转再平衡，实现简单；平均每节点 1.33 个指针，内存可预期。更重要的是 zset 实际是 skiplist + dict 双结构：member→score O(1) 查询与有序性兼得，红黑树给不了这个组合；skiplist 的 span 还让按排名的 ZRANK 保持 O(logN)。
</details>

5. 实例 `mem_fragmentation_ratio` 从 1.3 缓慢升到 2.6，另一次从 1.3 掉到 0.85。哪个更紧急？各自说明什么、怎么处理？
<details><summary>答案</summary>

0.85 更紧急。碎片率 < 1 意味着 RSS < 逻辑内存，部分数据已被换出到 swap，每次访问都是缺页 IO，延迟暴涨且可能连累复制超时——先查宿主机内存/容器 limit 与 cgroup OOM 记录，把内存还回来或迁移实例，平时把 vm.swappiness 调到 1。2.6 只是碎片（频繁删改、value 大小差异大、fork COW 脏页），表现为内存浪费而非变慢，可在低峰开启 activedefrag 或滚动重启回收。
</details>

## 延伸阅读

- 官方数据类型与内部编码：https://redis.io/docs/latest/develop/data-types/
- 官方内存优化（含碎片整理与 bigkey 建议）：https://redis.io/docs/latest/develop/use/memory-optimization/
- `OBJECT ENCODING` 命令与各类型可能的编码值：https://redis.io/commands/object-encoding/
- `MEMORY USAGE` 命令：https://redis.io/commands/memory-usage/
