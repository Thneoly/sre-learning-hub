# 01 · MongoDB 文档模型与 WiredTiger 存储引擎

> 模块：中间件-MongoDB ｜ 建议时长：3 小时 ｜ 关联认证：—（CKA/CKS/PCA 无直接考点，但为 SRE 面试与线上排障核心知识）

## 学习目标

- 能解释文档模型与关系模型的本质差异，以及"内嵌 vs 引用"两种建模方式的取舍依据
- 能操作：用 `mongosh` 观察 BSON 文档、`_id` 生成规则与集合的存储文件布局
- 能解释 WiredTiger 的 cache / checkpoint / journal 三层写入路径，以及一次写操作什么时候才算"安全落盘"
- 能解释 MongoDB B-tree 索引的 ESR 命中规则，并用 `explain("executionStats")` 判断索引是否生效
- 能排查：根据 cache 脏页占比与命中率判断"变慢是缺索引还是内存不够"

## 1. 文档模型：BSON、集合与模式设计

MongoDB 的基本数据单位是**文档**（document）：一组 `字段: 值` 的有序结构，序列化为 BSON（Binary JSON）。集合（collection）对应关系库的表，但不要求字段固定——同一集合里的两个文档可以有完全不同的字段。

```
   关系模型                              文档模型
   ┌─────────┬────────┬──────────┐      ┌────────────────────────────┐
   │ orders   │        │          │      │ { "_id": ObjectId("..."),  │
   ├─────────┼────────┼──────────┤      │   "user": {"name":"Li",    │
   │ id  PK   │ 1:N    │ items 表 │      │              "level": 3},  │
   │ user_id ─┼──────▶ │ order_id │      │   "status": "paid",        │
   │ status   │        │ sku, qty │      │   "items": [               │
   └─────────┴────────┴──────────┘      │     {"sku":"A","qty":2},   │
        join 才能取整单                  │     {"sku":"B","qty":1}],  │
                                         │   "created": ISODate(...)  │
   user 表另有一张                        │ }                          │
                                         └────────────────────────────┘
                                         一次查询拿整单,读路径无 join
```

模式设计的第一性问题：**一起读的数据放一起（内嵌），分开增长的数据分开放（引用）**。

| 判断维度 | 内嵌（embed） | 引用（reference） |
|---|---|---|
| 访问模式 | 整单一起读写（订单+明细） | 各实体独立高频访问（用户/订单） |
| 基数 | 一对少（几十条以内） | 一对多且多端无限增长（评论百万级） |
| 更新频率 | 整体变更 | 各自独立变更 |
| 文档大小风险 | 16MB 上限，数组无限膨胀会撑爆 | 无 |
| 读放大 | 一次查询 | 需要 `$lookup` 或应用侧多次查 |

`$lookup` 相当于左外连接，能做但不是 MongoDB 的强项；出现大量 `$lookup` 通常说明建模开始向关系模式倒退，应重新审视内嵌边界。

### _id 与 ObjectId

每个文档必须有 `_id`，集合内唯一。不显式指定时驱动自动生成 12 字节的 ObjectId：

```
  ObjectId("665f1a2b3c4d5e6f7a8b9c0d")
  ├── 4 字节: Unix 秒级时间戳(可反解出创建时间)
  ├── 5 字节: 进程级随机值(每台机器启动时生成一次)
  └── 3 字节: 递增计数器(每进程每秒最多 1677 万个)
```

时间戳前缀使 ObjectId **大体按时间有序**——作为默认 `_id` 时新文档总追加在 B-tree 尾部，避免随机插入的页分裂，这与 MySQL"别拿 UUIDv4 当主键"是同一个道理的反面教材。

BSON 相对 JSON 的扩展类型运维要认识几个：`ObjectId`、`ISODate`（UTC 时间，mongosh 显示带时区）、`NumberLong`（64 位整数）、`Decimal128`（精确小数，**金额字段必须用它**，双精度浮点会丢分）、嵌套文档与数组。日期统一 UTC 存储，展示层再做时区转换，别在入库时做时区偏移。

## 2. WiredTiger：cache、checkpoint 与 journal

自 4.2 起所有部署只有 WiredTiger 一个存储引擎（MMAPv1 已删除）。它的写入路径是理解一切"MongoDB 为什么慢/为什么丢不丢数据"的基础：

```
   应用写入 (insert/update/delete)
        │
        ▼
   ┌──────────────────────────────┐
   │  WiredTiger cache            │
   │  ┌────────────────────────┐  │   ① 改内存中的 B-tree 页(变脏)
   │  │ collection 的 B-tree 页  │  │      文档级并发控制,写锁粒度极细
   │  │ index 的 B-tree 页       │  │
   │  └────────────────────────┘  │
   └──────┬───────────────┬───────┘
          │ ② 顺序追加      │ ③ 每 60s 或 journal 达 2GB
          ▼               ▼
   ┌────────────┐   ┌──────────────┐
   │ journal    │   │ checkpoint   │  checkpoint = 把全部脏页刷盘,
   │ (WAL,压缩) │   │ (写 *.wt 文件)│  之后的 journal 即可归档循环
   └────────────┘   └──────────────┘
        ↑ 崩溃恢复只回放 checkpoint 之后的 journal,几分钟内拉起
```

三个关键机制的运维含义：

1. **写路径是 WAL**：提交的写先追加 journal（顺序写、压缩），数据文件可以慢慢刷。`j: true`（journal 确认）与 writeConcern 组合决定"多安全"，下一章展开。
2. **checkpoint 是全量边界**：默认每 60 秒或 journal 膨胀到 2GB 做一次。checkpoint 期间 IO 压力上升，表现为周期性的延迟毛刺——如果你看到"每分钟一次的规律性抖动"，先想到它。
3. **cache 是中间层**：默认 `max(50% (RAM - 1GB), 256MB)`。注意这**从 OS 角度看是进程私有内存**，容器里给 MongoDB 的 memory limit 必须大于 cache 上限再加数 GB 余量，否则 OOM kill。

磁盘上的文件布局（`dbPath`，默认 `/data/db`）：

| 文件 | 内容 |
|---|---|
| `collection-<n>.wt` | 每个集合一个（数据） |
| `index-<n>.wt` | 每个索引一个 |
| `WiredTiger.wt` | 元数据（表目录等） |
| `journal/` | WAL 日志文件，循环复用 |
| `_mdb_catalog.wt` | 集合命名空间目录 |

数据文件默认 snappy 压缩，索引默认前缀压缩——同样的数据落盘往往比关系库小，但压缩本身吃 CPU，极端写场景可换 zstd 或关闭（`block_compressor` 选项）。

### 文档级并发

WiredTiger 对写操作只在**文档级别**加锁：两个并发写只要不碰同一个文档就互不阻塞，同一集合上也一样。读侧则是 MVCC：每个读操作进入时对 cache 拍一张一致性快照（snapshot），执行期间其他写事务的提交不影响它看到的页版本，因此读写互不阻塞、也读不到"改到一半"的文档——这也是 checkpoint 能"边写边刷盘"而不加全局锁的前提。全局只有意向锁（intent）在读写共存时共享。这意味着 MongoDB 没有"表锁导致全表写入排队"这类问题；取而代之的瓶颈在别处——cache 驱逐（eviction）与 ticket（读写各 128 个并发槽，见第 3 章）。

## 3. 索引：B-tree 与 ESR 规则

索引默认是 B-tree（4.2+ 部分场景有列存索引，联机分析用，运维面少见）。复合索引的**字段顺序**决定它能服务哪些查询，判断规则是 ESR：

```
   E (Equality 等值)  →  S (Sort 排序)  →  R (Range 范围)

   查询: { user_id: 42, status: {$in:[1,2]}, created: {$gte: ...} }, sort {created: 1}

   等值:   user_id, status        ┐ 放最前,顺序任意(等值列之间可交换)
   排序:   (本例 sort 列被范围覆盖) ┘
   范围:   created                ┐ 放最后
                                   ┘
   → { user_id: 1, status: 1, created: 1 }
```

为什么范围放最后：等值条件把 B-tree 定位到一个连续区间；若范围列夹在中间，排序字段就只能部分有序，引擎还得再排序（内存排序超 100MB 直接报错，`allowDiskUse` 才能落盘）。等值列放前面则排序在索引内天然有序，免 sort 阶段。

运维必知的索引种类：

| 索引 | 语法要点 | 用途 |
|---|---|---|
| 复合 | `{a:1, b:-1}`，最多 32 个字段 | 覆盖 ESR 查询 |
| 多键（multikey） | 自动，数组字段上建即生效 | 数组元素匹配 |
| TTL | `{t:1}` + `expireAfterSeconds` | 日志/会话自动过期删除（后台每 60s 扫一次，非精确定时） |
| 唯一 | `{a:1},{unique:true}` | 业务唯一约束 |
| 稀疏/部分 | `partialFilterExpression` | 只索引子集，省空间（如只索引 status="active"） |
| 文本/地理 | `text` / `2dsphere` | 全文检索与 LBS（全文建议交给搜索引擎） |

```javascript
// [任意节点] 用 explain 判断索引是否生效
db.orders.find({ user_id: 42, status: 2 }).sort({ created: -1 })
  .explain("executionStats")

// 看输出里的:
//   winningPlan.stage = "COLLSCAN"          → 全表扫描,缺索引
//   IXSCAN + indexName                       → 命中了哪个索引
//   executionStats.totalDocsExamined         → 扫了多少文档
//   executionStats.nReturned                 → 返回多少
//   totalDocsExamined >> nReturned           → 索引选择性差,等于白扫
```

`totalKeysExamined / totalDocsExamined / nReturned` 三者接近 1:1:1 才是好索引；`keys` 远大于 `docs` 说明索引列区分度不足。

## 4. 一次读写请求的完整路径

把前两节串起来，一条查询进来：

```
   客户端/驱动
      │ ① 选中节点(副本集拓扑里选 primary,或按 readPreference 选 secondary)
      ▼
   mongod 服务层: 解析 → 权限 → 查询计划缓存命中则复用
      │
      ▼
   WiredTiger: cache 中找 B-tree 页
      ├─ 命中 → 内存内遍历,直接返回(读 ticket 占用期间)
      └─ 未命中 → 读盘加载该页(以及 journal 恢复的脏页)
      ▼
   按 projection 裁剪字段,回给驱动
```

写入则多两步：改 cache 页 → 追加 journal（按 writeConcern 决定何时向客户端确认）。理解这条路径后，排障时的归因顺序就固定了：**先看是不是没走索引（EXPLAIN），再看是不是 cache 不够（命中率/驱逐），最后才谈磁盘与 CPU**。

## 实战演练

环境：装有 Docker 的 Ubuntu VM。

```bash
# [Ubuntu VM] 起一个单节点实例
docker run -d --name mongo-learn -p 27017:27017 mongo:7.0 --bind_ip_all

# [Ubuntu VM] 进入交互 shell
docker exec -it mongo-learn mongosh
```

```javascript
// [容器内] 建集合并观察文档结构
use app
db.orders.insertMany(Array.from({length: 10000}, (_, i) => ({
  _id: i + 1,
  user_id: Math.floor(Math.random() * 500),
  status: Math.floor(Math.random() * 4),
  amount: NumberDecimal((Math.random() * 500).toFixed(2)),
  items: [{ sku: "A", qty: i % 5 + 1 }],
  created: new Date(Date.now() - Math.floor(Math.random() * 720) * 3600e3)
})))

// 观察 _id 的默认形态(不指定 _id 时)
db.tmp.insertOne({ a: 1 })
db.tmp.findOne()
// _id 是 ObjectId;反解时间戳:
ObjectId("665f1a2b3c4d5e6f7a8b9c0d").getTimestamp()
```

```javascript
// [容器内] 实验 1:无索引 vs 有索引
db.orders.find({ user_id: 42 }).sort({ created: -1 }).explain("executionStats")
// stage=COLLSCAN,totalDocsExamined≈10000

db.orders.createIndex({ user_id: 1, created: -1 })
db.orders.find({ user_id: 42 }).sort({ created: -1 }).explain("executionStats")
// stage=IXSCAN且无SORT阶段,totalDocsExamined≈20,keys≈docs≈returned

// 实验 2:违反 ESR,范围列夹中间
db.orders.find({ user_id: 42, created: { $gte: new Date("2020-01-01") } })
  .sort({ status: 1 }).explain("executionStats")
// 出现 SORT 阶段;改 { user_id:1, status:1, created:-1 } 可消掉
```

```javascript
// [容器内] 实验 3:观察 WiredTiger cache 与存储文件
db.serverStatus().wiredTiger.cache
// 关注: "bytes currently in the cache"      已用
//       "tracked dirty bytes in the cache"  脏页(>20% 会触发积极驱逐)
//       "pages read into cache" vs "pages requested from the cache"
//       命中率 = 1 - read/requested

db.orders.stats()
// wtName 对应磁盘文件名;size(逻辑) vs storageSize(压缩后落盘)

db.orders.createIndex(
  { created: 1 },
  { expireAfterSeconds: 3600, name: "ttl_created" }
)
// TTL 索引:created 早于 1 小时前的文档会被后台任务删除
```

```bash
# [容器内] 对照磁盘文件
ls -lh /data/db | head -20
# collection-2--*.wt 是 orders 的数据文件
# index-4--*.wt 是刚建的索引文件
# journal/ 是 WAL
```

验证方法：实验 1 前后 `totalDocsExamined` 从万级降到 20 左右；实验 3 的 `tracked dirty bytes` 在批量写入后短暂上升又回落，说明 checkpoint/驱逐在正常工作。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 容器一跑高负载就被 OOM kill | cache 上限(约 50% RAM) + 连接/排序内存超出容器 limit | 容器 limit ≥ cache 上限 + 2~3GB，或显式 `--wiredTigerCacheSizeGB` |
| 写入延迟每分钟规律性抖动一次 | 60 秒周期 checkpoint 集中刷脏 | 分散写批；确认磁盘 IOPS 匹配；接受或调 `checkpoint` 相关参数（以官方文档为准） |
| 明明建了索引查询还是慢 | 复合索引字段顺序不满足 ESR，或查询列不在索引里 | `explain("executionStats")` 确认 COLLSCAN/SORT 后重排索引 |
| 金额对账差一分钱 | 用了 double 存钱 | 金额字段用 `NumberDecimal`（Decimal128） |
| 集合越来越大删了数据也不释放空间 | 删除只标记可复用，文件不收缩 | 空间复用是常态；确需回收用 `compact`（见第 3 章） |
| TTL 索引不准时删除 | 后台任务每 60 秒跑一次且要求字段为 BSON Date | 接受分钟级误差；字段必须是 `ISODate`，不能存字符串 |

## 自测

1. 为什么 MongoDB 的默认 `_id`（ObjectId）不会像 MySQL 的 UUIDv4 主键那样带来严重写放大？

<details><summary>答案</summary>

ObjectId 的前 4 字节是秒级时间戳，同一秒内生成的 id 时间前缀相同、后 3 字节计数器递增，整体近似单调递增。B-tree 插入总发生在树的最右侧，页分裂是顺序的、空间利用率高。UUIDv4 完全随机，插入位置均匀散布，导致频繁页分裂与缓存局部性差。两者对比的本质是"主键是否有序"，而不是文档库与关系库的差异。
</details>

2. 应用报告"订单列表接口偶尔 2 秒+，其余时间正常"，你第一时间查什么？为什么不是先加内存？

<details><summary>答案</summary>

先抓慢查询的 `explain("executionStats")` 与 `db.currentOp()`，确认是否 COLLSCAN 或内存排序。规律性的偶发延迟更可能是：缺索引导致全表扫描碰上 cache 未命中、checkpoint 周期刷脏、或内存排序触顶。加内存只对"cache 不够"这一种成因有效，而且 MongoDB cache 上限默认已锁在 50% RAM，盲目加机器内存若不同步调 cache 参数甚至不生效。
</details>

3. journal 和 checkpoint 各自解决什么问题？如果只保留 checkpoint、去掉 journal，会失去什么？

<details><summary>答案</summary>

checkpoint 定期把 cache 中的全部脏页刷进数据文件，形成一致的磁盘镜像；journal（WAL）记录 checkpoint 之后的每次变更。去掉 journal 后，崩溃恢复只能回到上一个 checkpoint（最多丢 60 秒已确认的写入），且 `j:true` 语义不复存在——用户确认的写不再有崩溃安全保证。保留 journal，恢复时只需回放 checkpoint 之后的少量日志，恢复窗口从"全量数据"缩小到"一个 checkpoint 周期"。
</details>

4. 集合 A 每文档内嵌一个评论数组，评论数从几百涨到几十万，会发生什么？该怎么改？

<details><summary>答案</summary>

文档逼近 16MB 硬上限，最终插入报错（document too large）；同时每次读整文档都要把几十万评论一起读出来，写评论也要整文档重写（WiredTiger 按文档为修改单位），读放大与写放大同时爆炸。改法是把评论拆成独立集合，用 `post_id` 引用并建索引；主文档只保留评论数等聚合字段。这是一对多且多端无限增长时"必须引用"的标准判例。
</details>

5. `explain` 输出 `totalKeysExamined=100000, totalDocsExamined=100000, nReturned=15`，说明什么？该怎么改？

<details><summary>答案</summary>

索引确实被用了（IXSCAN），但扫了 10 万个索引键才命中 15 条——索引前导列区分度太低（例如在 status 这种只有几个取值的列上建了索引）。要么把高区分度的等值列放到复合索引最前（重排 ESR 顺序），要么改用部分索引只覆盖关心的子集。索引"被使用"不等于"有收益"，三个数字必须一起看。
</details>

## 延伸阅读

- MongoDB 官方手册 Documents：https://www.mongodb.com/docs/manual/core/document/
- 官方手册 WiredTiger Storage Engine：https://www.mongodb.com/docs/manual/core/wiredtiger/
- 官方手册 Journaling：https://www.mongodb.com/docs/manual/core/journaling/
- 官方手册 Index Strategies / ESR Rule：https://www.mongodb.com/docs/manual/tutorial/equality-sort-rule/
- 官方手册 Explain Results：https://www.mongodb.com/docs/manual/reference/explain-results/
