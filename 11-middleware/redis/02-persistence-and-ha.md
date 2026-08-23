# 02 · Redis 持久化与高可用：RDB/AOF、主从、哨兵与 Cluster

> 模块：11-middleware/redis ｜ 建议时长：4 小时 ｜ 关联认证：—（无直接考点；与 CKA 的 StatefulSet/持久卷、PCA 的复制延迟监控思路相通）

## 学习目标

- 能解释 RDB 的 fork 与 COW 机制，说出三个由此产生的线上坑及对应参数
- 能对比 AOF 三种 fsync 策略的丢失窗口与性能代价，解释 AOF 重写为什么也是 fork
- 能画出主从全量同步与部分重同步的流程，按业务写流量估算 `repl-backlog-size`
- 能复述哨兵从主观下线到故障转移的完整流程，配置脑裂防护参数并说明其保护边界
- 能解释 Cluster 的 16384 槽、MOVED/ASK 重定向与迁槽步骤，并给出"哨兵够用/必须 Cluster"的选型依据

## 1. 全景：从单点到 Cluster 的演进逻辑

```
单实例 ──加──► 持久化(RDB/AOF) ──加──► 复制(主从) ──加──► 哨兵(自动故障转移)
  │              解决:重启丢数据         解决:读扩展/冗余      解决:主库挂了要人爬起来
  └──换架构──► Cluster(16384 槽分片)  解决:写扩展 + 容量超过单机 + 在线扩缩容
```

每一层都在解决上一层的遗留问题，但也引入新问题（fork 延迟、复制延迟、脑裂、多 key 限制）。排障时先定位故障在哪一层。

## 2. RDB：fork 与 COW

RDB 是某一时刻内存数据的二进制快照。两种生成方式：`SAVE`（主进程做，全程阻塞，基本只用于调试）和 `BGSAVE`（fork 子进程做，线上唯一正确姿势）。自动触发条件由 `save <秒> <变更数>` 定义，7.x 默认 `save 3600 1 300 100 60 10000`，即 1 小时内 1 次、5 分钟内 100 次、1 分钟内 1 万次变更各触发一次 BGSAVE。

### 2.1 fork + COW 机制

```
主进程 ──fork()──► 子进程（拿到同一份物理内存的视角）
   │                    │
   │ 继续处理写命令         │ 遍历内存生成 RDB 文件
   │                      │
   ▼                      ▼
写 page A → 内核发现该页被子进程引用 → 复制一份给主进程改（Copy-On-Write）
           子进程仍读旧页 → 快照保持 fork 瞬间的数据一致性
```

COW 粒度是一个内存页（4KB）。BGSAVE 期间写入越多，被复制的页越多，内存峰值越接近翻倍。

### 2.2 三个经典坑

| 坑 | 表现 | 处理 |
|---|---|---|
| fork 延迟 | 快照前瞬间 P99 抖动，与数据量成正比（经验量级每 GB 10~20ms，差异大，以实测为准） | 用 `INFO stats` 的 `latest_fork_usec` 持续观测；控制单实例内存；避免与其他内存大户同机 |
| THP 放大 COW | Transparent Huge Pages 把复制粒度从 4KB 变 2MB，延迟与内存双涨 | `echo never > /sys/kernel/mm/transparent_hugepage/enabled`（Redis 启动日志也会告警） |
| fork 失败/内存翻倍 | 大内存 + 写入高峰时 OOM | `sysctl vm.overcommit_memory=1`；maxmemory 只设物理内存的 70%~80%，给 COW 留余量 |

另一个容易被忽略的参数：`stop-writes-on-bgsave-error yes`（默认）——BGSAVE 失败（如磁盘满）后 Redis 拒绝所有写命令，宁可拒绝服务也不静默丢快照。看到突发的写报错先查 `INFO persistence` 的 `rdb_last_bgsave_status`。

RDB 特点：文件紧凑、恢复快、适合异地容灾备份；代价是两次快照之间的数据会丢（分钟级窗口）。只开 RDB 的实例宕机 = 丢最近一次快照后的所有写入。

## 3. AOF：三种 fsync 与重写

AOF 记录每条写命令（RESP 协议文本）。命令执行成功后先写进 `aof_buf` 缓冲，再按 `appendfsync` 策略落盘——OS 把 write 写入 page cache，fsync 才真正强制刷盘，所以**策略的差异本质是"谁来等 fsync"**：

| appendfsync | 机制 | 最多丢多少 | 性能 |
|---|---|---|---|
| always | 每条命令 fsync 一次（主线程等） | 1 条命令 | 最慢，磁盘 IO 决定写 QPS |
| everysec（默认） | 后台线程每秒 fsync 一次；若上次还没完成，本次只写不 fsync | **官方说明最坏约 2 秒** | 与 RDB 相差不大，推荐值 |
| no | 只 write，刷盘交给 OS（通常 30s） | 不确定（OS 决定） | 最快，最不可控 |

everysec"最坏 2 秒"的原因：fsync 在后台线程做，主线程发现上一次 fsync 仍在进行时会跳过本轮，等下一秒再来——连续两轮被跳过就是 2 秒的命令只躺在 page cache 里，此时断电即丢。

### 3.1 AOF 重写

同一个 key 被改一万次，AOF 里就有一万条记录，文件无限膨胀、恢复越来越慢。AOF 重写根据**当前内存状态**生成等价的最小命令集（`SET k v` 一条顶一万条 INCR）。重写同样走 fork：子进程写新文件，期间主进程的新命令照常追加。

Redis 7.0 起 AOF 改为多文件结构（Multi-Part AOF）：

```
/data/appendonlydir/
├── appendonly.aof.1.base.rdb    # 基础文件：重写时刻的全量数据
├── appendonly.aof.1.incr.aof    # 增量文件：base 之后的新命令（可多个 incr）
└── appendonly.aof.manifest      # 清单：记录上面文件的元信息
```

自动重写条件：`auto-aof-rewrite-percentage 100`（比上次重写后大小增长 100%）且 `auto-aof-rewrite-min-size 64mb`。手动命令 `BGREWRITEAOF`。

重写期间的取舍参数：`no-appendfsync-on-rewrite yes`——子进程大量写盘时跳过主 AOF 的 fsync，避免主线程被磁盘阻塞（代价是这一窗口内宕机可能多丢几秒）。观察指标：`INFO persistence` 的 `aof_last_write_status`、`aof_last_bgrewrite_status`，`INFO stats` 的 `aof_delayed_fsync`（everysec 被迫跳过 fsync 的次数，持续增长说明磁盘扛不住）。

## 4. 混合持久化

`aof-use-rdb-preamble yes`（4.0+ 引入，7.x 默认开）：重写产生的 base 文件直接用 **RDB 二进制格式**，incr 文件仍是命令文本。恢复时先快速载入 RDB 基底，再重放少量增量命令——恢复速度接近纯 RDB，丢失窗口又是 AOF 级别（秒级），两者优点兼得。生产推荐保持默认开启。

优先级：实例重启时若 AOF 开启则**优先加载 AOF**（更完整），RDB 只作为无 AOF 时的兜底。

## 5. 主从复制

### 5.1 全量同步流程

```
replica                                master
   │ ── REPLCONF/握手 ──────────────────►│
   │ ── PSYNC <replid> <offset> ────────►│ 首次连接 replid=? offset=-1
   │◄─ FULLRESYNC <replid> <offset> ─────│ 判定：无法部分重同步
   │                                    │ BGSAVE 生成 RDB（fork+COW，同上）
   │                                    │ 同时把期间新写命令暂存到 replica 的
   │                                    │ client output buffer
   │◄──── RDB 文件传输 ──────────────────│
   │ 清空自身旧数据，载入 RDB              │
   │◄──── 补发 buffer 里的增量命令 ────────│
   │ ◄══════ 命令流（持续复制）═══════════│
```

要点：

- 全量同步成本极高：master 一次 fork + 磁盘 IO + 网络 RDB 传输，replica 还要清空旧数据。多个 replica 同时断线重连会造成**全量同步风暴**，master 直接被拖垮。缓解：级联复制（replica 挂 replica）、`repl-diskless-sync yes`（无盘复制，RDB 直接走网络，省一次磁盘写）。
- replica 积压命令写不出去时会被 master 断开：`client-output-buffer-limit replica 256mb 64mb 60`（持续超 256MB，或 60 秒内持续超 64MB 即断）。
- `replica-read-only yes` 默认开，从库拒绝写。

### 5.2 部分重同步与 repl_backlog

master 维护一个**环形缓冲区** repl backlog（默认仅 1MB，所有 replica 共享）：

```
        ┌───────────── repl_backlog（环形，写满覆盖最旧）─────────────┐
        │ ██████████░░░░░░░░░░██████████████████████████████           │
        │ ▲已被覆盖          ▲最旧可用            ▲master_repl_offset ▲│
        └──────────────────────────────────────────────────────────────┘
replica 断线重连后带着旧 offset 回来：
  offset 仍落在 backlog 范围内且 replid 匹配 → CONTINUE，只补差量（部分重同步）
  offset 已被覆盖 / replid 不匹配            → FULLRESYNC，重来一次全量
```

backlog 容量估算：`repl-backlog-size ≥ 可能的最长断线秒数 × 峰值写流量(bytes/s)`。例：预期最长断线 60s、峰值写入 8MB/s → 至少 480MB，常见生产值 256MB~1GB。观察 `INFO stats`：`sync_full`（全量次数）、`sync_partial_ok`（部分重同步成功）、`sync_partial_err`（失败回退全量）；`sync_full` 增长是最需要警惕的信号。

failover 后仍可能部分重同步：提升的新主保留 `replid2`（旧主的 replid），旧主回来时用它对上，避免一次无谓全量。

## 6. 哨兵 Sentinel

### 6.1 架构与配置

```
              ┌────────┐ ┌────────┐ ┌────────┐
              │sentinel1│ │sentinel2│ │sentinel3│   ≥3 个、奇数、不同物理机
              └───┬────┘ └───┬────┘ └───┬────┘
   互相发现: __sentinel__:hello 频道每 2s 广播 │  每 1s PING master/replicas
                  └──────────┼──────────┘
                             ▼
                        ┌────────┐   复制
      客户端问 sentinel  │ master │◄────── ┌─────────┐
      要 master 地址 ──► └────────┘        │ replica1 │
                             └──────────►┌─────────┐
                                         │ replica2 │
                                         └─────────┘
```

最小配置（sentinel.conf）：

```bash
# [任意节点] sentinel 核心参数（目录：/etc/sentinel.conf，sentinel 会回写该文件）
port 26379
sentinel monitor mymaster 172.28.0.11 6379 2        # 监控对象 + quorum=2
sentinel down-after-milliseconds mymaster 5000      # 5s 无响应判主观下线
sentinel failover-timeout mymaster 30000            # failover 全程超时/重试节奏
sentinel parallel-syncs mymaster 1                  # 同时重指向新主的 replica 数
```

### 6.2 下线判定与 leader 选举

1. **主观下线 SDOWN**：单个 sentinel 发现 master 在 `down-after-milliseconds` 内无效回复（PING 超时/错误回复）。
2. **客观下线 ODOWN**：该 sentinel 询问其他 sentinel（`SENTINEL is-master-down-by-addr`），认为下线的数量达到 **quorum** → 客观判定成立。
3. **leader 选举**：任一 sentinel 发起选举（Raft 思想：epoch 单调递增，先到先得投票，自己不能投自己），获得**多数派（majority，与 quorum 是两回事）**选票的 sentinel 成为 leader 执行 failover。
4. quorum 只用于 ODOWN 判定；选举和 failover 授权需要 majority。所以 5 个 sentinel 配 quorum=2 仍需 3 票才能动手——**哨兵总数必须 ≥3 且为奇数**，2 个哨兵挂 1 个就永远无法 failover。

### 6.3 故障转移全流程（lab 里会逐条看到这些事件）

```
+sdown master      ← 某哨兵发现 master 没响应
+odown master      ← 达到 quorum，客观下线
+new-epoch / +vote-for-leader / +elected-leader
                     ← leader 选举（通常 1~2s）
+failover-state-select-slave → +selected-slave
                     ← 按规则挑新主：先排除与 master 断链过久的 replica，
                       再比 replica-priority（小者优先，0 永不提升）、
                       复制 offset（大者优先，数据最全）、runid（字典序）
+failover-state-send-slaveof-noone → +promoted-slave
                     ← 对选中者发 SLAVEOF NO ONE，等它升为主
+failover-state-reconf-slaves → +slave-reconf-done
                     ← 其余 replica 改为 replicaof 新主（parallel-syncs 个一批）
+switch-master mymaster 172.28.0.11 6379 172.28.0.12 6379
                     ← 切换完成，所有哨兵更新自己的 master 记录
（旧 master 恢复后）+convert-to-slave / +slave-reconf-done
                     ← 哨兵把它降级为新主的 replica
```

客户端接入方式：向 sentinel 查 `SENTINEL get-master-addr-by-name mymaster` 拿 master 地址，并订阅 `+switch-master` 频道感知切换；主流客户端（Jedis/Lettuce、redis-py、go-redis）都内置 sentinel 模式，配置哨兵地址列表即可。

### 6.4 脑裂与防护

```
        ┌────── 网络分区 ──────┐
        │  少数派侧             │           │ 多数派侧
   ┌─────────┐                 │  ┌────────┬────────┬────────┐
   │ 旧master │ ←─仍在接受写入!  │  │sentinel│sentinel│sentinel│
   └─────────┘                 │  └────────┴────────┴────────┘
        └──────────────────────┘            │ 提升 replica2 为新 master
分区愈合后：旧 master 被哨兵降级为 replica → 全量同步新主 →
           分区期间写进旧 master 的数据【全部丢失】
```

防护参数（配在 master 上）：

```bash
# [任意节点] 脑裂防护：至少 1 个 replica 延迟 ≤10s 时才接受写
redis-cli CONFIG SET min-replicas-to-write 1
redis-cli CONFIG SET min-replicas-max-lag 10
```

原理：分区发生后旧 master 侧不再有同步正常的 replica，写请求直接报错，把选择权交还业务侧。注意边界：它防的是"旧主在无 replica 确认的情况下继续吞数据"，若恰好有 1 个 lag 很小的 replica 留在旧主侧，仍可能有秒级丢失——它是**缩小损失窗口**，不是消除脑裂。业务侧必须处理这期间的写错误（重试/降级），否则换成写失败风暴。

## 7. Redis Cluster

### 7.1 16384 槽与路由

数据分片不按一致性哈希，而是把键空间切成 **16384 个 slot**，每个节点负责一段：

```
slot = CRC16(key) mod 16384
nodeA: slots 0-5460        nodeB: slots 5461-10922        nodeC: slots 10923-16383

key 含 {user:1000}.profile 形式的 hash tag 时，只用 {} 内部分做 CRC16 → 强制同槽
（多 key 命令/事务/Lua 脚本要求所有 key 在同一节点）
```

为什么不用一致性哈希：槽把"数据归属"变成显式、可枚举的元数据（每节点一个 16384bit=2KB 的 bitmap），扩缩容时迁移单位是槽的集合而不是随机散布的 key，可控、可暂停、可回滚；一致性哈希加减节点只影响相邻节点，但分布完全由哈希决定，冷热与倾斜无法人工干预，还需要虚拟节点撑均匀性。16384 这个数则是心跳包里槽位图 2KB 与官方建议最大 1000 节点的折中（作者 antirez 在 issue 里有完整解释）。

节点间用 gossip 协议（专用的 cluster bus 端口 = 服务端口 + 10000）交换节点/槽视图：MEET（加入集群）、PING/PONG（每秒向随机节点探活）、FAIL（半数以上 master 认为某节点失联才标记，避免误判）。客户端可以连任意节点，节点按槽归属返回数据或重定向：

| 重定向 | 含义 | 客户端行为 |
|---|---|---|
| `MOVED 3999 172.28.0.12:6379` | 槽 3999 已**永久**归 12 节点 | 更新本地槽表，以后直接找新节点 |
| `ASK 3999 172.28.0.12:6379` | 槽 3999 **正在迁移**，这个 key 已搬过去 | 仅本次先发 `ASKING` 再重试目标节点，不改槽表 |

### 7.2 迁槽过程（在线扩容的核心）

```
目标节点                          源节点
CLUSTER SETSLOT 601 IMPORTING <src-id>
                                 CLUSTER SETSLOT 601 MIGRATING <tgt-id>
                                 循环: CLUSTER GETKEYSINSLOT 601 100
                                       MIGRATE <tgt> 6379 "" 0 5000 KEYS k1 k2 ...
   （迁移中该槽的 key：源节点还在 → ASK 重定向到目标；目标没有但槽在 IMPORTING → 收 ASKING 后接受）
两边都完成后：
CLUSTER SETSLOT 601 NODE <tgt-id>（目标、源各执行一次，其余节点靠 gossip 收敛）
```

运维要点：MIGRATE 是同步阻塞源节点的单线程命令，大批量小 key 会造成源节点卡顿，要小批量循环（如每批 10~100 个 key）；`cluster-require-full-coverage yes`（默认）下任何槽没有节点负责时整个集群拒绝写；`cluster-node-timeout 15s` 决定失联判定，也影响 failover 速度。K8s/NAT 环境需 `cluster-announce-ip/port/bus-port`，否则 gossip 广播的是 Pod IP，外部客户端连不上。

## 8. 选型：什么时候哨兵就够

| 维度 | 主从+哨兵 | Cluster |
|---|---|---|
| 写扩展 | 不行，写只能打 master（单线程约 10w QPS 量级） | 按节点数近似线性 |
| 容量 | 上限 = 单机内存 × 0.7~0.8 | 理论上限 ≈ 节点数 × 单机内存 |
| 客户端 | sentinel 协议，主流 SDK 原生支持 | 需 smart client（槽缓存 + MOVED/ASK 处理） |
| 多 key/事务 | 随便用 | 必须同槽（hash tag），DB 只能用 0 |
| 运维复杂度 | 低：一套哨兵管多个主从组 | 高：槽迁移、gossip、bus 端口、倾斜治理 |

经验法则：**单实例内存 < 10~20GB、写 QPS 远未到单线程瓶颈、希望简单——哨兵足矣**（缓存场景尤其如此，容量不够先垂直拆业务）。数据量或写压力真超单机、需要在线水平扩缩，再上 Cluster。两种都别手搭在裸机上自嗨：K8s 上用 Operator（见第 3 章）或直接用云托管，把 failover 与备份交给平台。

## 实战演练

环境：装有 Docker 的 Ubuntu VM。哨兵 failover 的完整动手在 lab 01 做，这里聚焦持久化与复制观测。

```bash
# [任意节点] 起一个 RDB+AOF 混合持久化实例（数据目录落到宿主机便于查看）
mkdir -p /root/redis-persist
docker run -d --name redis-persist -p 6405:6379 \
  -v /root/redis-persist:/data \
  redis:7.2 --save 60 1 --appendonly yes
```

```bash
# [任意节点] RDB：BGSAVE、fork 耗时、状态
docker exec redis-persist redis-cli SET order:1001 sku-42
docker exec redis-persist redis-cli BGSAVE
docker exec redis-persist redis-cli INFO stats | grep latest_fork_usec
# 预期: latest_fork_usec:300 左右（微秒；空实例 fork 极快，线上大实例才是重点）
docker exec redis-persist redis-cli INFO persistence | grep -E 'rdb_last_bgsave_status|rdb_last_save_time'
# 预期: rdb_last_bgsave_status:ok
```

```bash
# [任意节点] AOF：多文件结构与混合持久化验证
docker exec redis-persist ls -l /data/appendonlydir
# 预期: appendonly.aof.1.base.rdb  appendonly.aof.1.incr.aof  appendonly.aof.manifest
docker exec redis-persist head -c 5 /data/appendonlydir/appendonly.aof.1.base.rdb; echo
# 预期: REDIS   ← base 文件是 RDB 格式（aof-use-rdb-preamble 混合持久化生效）
docker exec redis-persist tail -c 60 /data/appendonlydir/appendonly.aof.1.incr.aof | cat -v
# 预期: 可见 RESP 文本，如 *3$3SET$9order:1001$6sku-42
docker exec redis-persist redis-cli CONFIG GET appendfsync aof-use-rdb-preamble
```

```bash
# [任意节点] 主从：全量同步与部分重同步对比
docker network create redis-repl-net
docker run -d --name repl-master --network redis-repl-net redis:7.2
docker run -d --name repl-slave --network redis-repl-net redis:7.2 --replicaof repl-master 6379
sleep 2
docker exec repl-slave redis-cli INFO replication | grep -E '^role|master_link_status'
# 预期: role:slave / master_link_status:up（首次连接已完成一次全量同步 sync_full:1）
docker exec repl-master redis-cli INFO replication | grep -E '^role|connected_slaves|master_replid|repl_backlog_size'
```

```bash
# [任意节点] 场景 A：短断线 + 默认 1MB backlog → 部分重同步
docker stop repl-slave
docker exec -i repl-master sh -c 'seq 1 200 | sed "s/^/SET k:/" | sed "s/$/ v/" | redis-cli --pipe'
docker start repl-slave; sleep 3
docker exec repl-master redis-cli INFO stats | grep -E 'sync_full|sync_partial'
# 预期: sync_full:1（首次）  sync_partial_ok:1（本次断线靠 backlog 补齐，没有新全量）
docker exec repl-slave redis-cli GET k:200
# 预期: "v"
```

```bash
# [任意节点] 场景 B：断线期间写入量超过默认 1MB backlog → 只能全量同步
docker stop repl-slave
docker exec -i repl-master sh -c 'seq 1 60000 | sed "s/^/SET m:/" | sed "s/$/ v/" | redis-cli --pipe'
docker start repl-slave; sleep 5
docker exec repl-master redis-cli INFO stats | grep -E 'sync_full|sync_partial'
# 预期: sync_full:2（6 万条 ≈ 2MB 命令量把 1MB 的环形缓冲冲掉了，
#       replica 的 offset 已被覆盖，回退全量；sync_partial_err 可能 +1）
docker exec repl-slave redis-cli GET m:60000
# 预期: "v"（全量同步后数据最终一致）
```

验证方法：两场景对比 `sync_full`/`sync_partial_ok` 的计数变化，直观看到 backlog 大小如何决定重连成本。清理：`docker rm -f redis-persist repl-master repl-slave; docker network rm redis-repl-net; rm -rf /root/redis-persist`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 磁盘满后所有写报错 | BGSAVE 失败 + `stop-writes-on-bgsave-error yes` | 修磁盘是第一优先级；该参数是保护不是 bug，别急着关 |
| 每分钟固定时间点延迟尖刺 | 自动 BGSAVE 触发 fork，实例大 | 监控 `latest_fork_usec`；调 `save` 策略错峰、控制实例大小、关 THP |
| replica 闪断一次就全量同步 | backlog 太小，断线期间写入超出缓冲 | 按断线时长 × 写流量调大 `repl-backlog-size` |
| 三节点哨兵挂两个后不切换 | 剩一个凑不满 majority | 哨兵 ≥3 且奇数、跨机架分布；接受 N-1 容忍度现实 |
| failover 后旧主数据丢了 | 分区期间旧主继续接受写 | `min-replicas-to-write 1` + `min-replicas-max-lag 10`；业务侧处理写错误 |
| Cluster 迁槽时源节点卡顿 | MIGRATE 阻塞单线程且一次搬太多 key | 小批量（10~100/批）循环，低峰执行，观察源节点延迟 |
| 客户端疯狂报 MOVED | 客户端没实现 smart client/槽表没更新 | 用支持 Cluster 的 SDK；确认迁移已 `SETSLOT NODE` 收敛 |
| K8s 里 Cluster 节点互相连不上 | gossip 广播了 Pod IP/默认 bus 端口 | `cluster-announce-ip/port/bus-port` 显式声明可达地址 |

## 自测

1. `appendfsync everysec` 号称每秒刷盘，为什么官方说最坏可能丢 2 秒数据？
<details><summary>答案</summary>

fsync 由后台线程执行。主线程写 AOF 时如果发现上一次 fsync 仍在进行（磁盘慢），为了避免阻塞会跳过本轮 fsync，等后台线程下一秒再触发——连续两轮跳过后，最多约 2 秒的命令只存在于 page cache，此时主机断电即丢。指标 `aof_delayed_fsync` 记录了跳过次数，持续增长说明磁盘 IO 已成为瓶颈。
</details>

2. BGSAVE 期间业务写入量很大，进程内存为什么会明显上涨甚至翻倍？容量上怎么防？
<details><summary>答案</summary>

fork 后父子进程共享物理页，子进程负责遍历生成快照，主进程继续处理写命令；内核 COW 机制在主进程首次修改某页时复制出一个新页，快照仍然读旧页保证一致性。写入越多、越分散，被复制的 4KB 页越多，极端情况下全部页都被改写一遍 = 内存翻倍。防：maxmemory 只设物理内存的 70%~80%；关闭 THP（否则复制粒度变 2MB，更费内存更卡）；错峰 BGSAVE；磁盘慢导致 BGSAVE 拉长也会放大 COW 窗口。
</details>

3. replica 重连时什么条件走部分重同步？backlog 该设多大？
<details><summary>答案</summary>

条件：replica 上报的复制 offset 仍落在 master 的 repl_backlog 环形缓冲范围内，且复制 ID 匹配（failover 场景下新主的 replid2 记着旧主 replid，也能对上）。任一不满足就 FULLRESYNC 全量重来。容量公式：backlog ≥ 预期最长断线秒数 × 峰值写流量（字节/秒），再留一倍余量；同时确认 `client-output-buffer-limit replica`（默认 256mb 64mb 60）不会在全量同步时把 replica 踢掉。观察 `sync_full` 是否增长来验证设置是否够。
</details>

4. `min-replicas-to-write 1`、`min-replicas-max-lag 10` 到底防住了什么，没防住什么？
<details><summary>答案</summary>

防住：网络分区时旧 master 身边不再有"lag ≤10s 的同步 replica"，于是拒绝写入，分区愈合后旧主被降级重同步，不会用旧主的分区分裂写入覆盖新主的数据。没防住：分区期间业务写入直接失败（必须自己处理错误，否则写失败风暴）；以及旧主侧恰好还挂着 1 个 lag 极小的 replica 时，秒级窗口内的写入仍可能丢。它是缩小损失窗口的参数，不是强一致方案。
</details>

5. 迁槽过程中，为什么源节点必须返回 ASK 而不能直接回 MOVED？
<details><summary>答案</summary>

槽迁移是中间态：槽 601 的 key 一部分还在源节点、一部分已到目标节点，但槽的"正式归属"还没切换（要等迁移完成执行 `SETSLOT NODE` 广播）。若此时回 MOVED，客户端会永久把槽 601 记到目标节点，但目标上还没迁完的那些 key 会被查无此 key，而且目标节点对"未正式拥有"的槽也会回 MOVED 指回源，造成重定向死循环。ASK 是一次性重定向：客户端仅对这一条命令先发 ASKING 再去目标执行，槽表不变，迁移结束后 MOVED 才接管。
</details>

## 延伸阅读

- 官方持久化机制详解（RDB/AOF/重写/混合）：https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/
- 官方复制机制（PSYNC/backlog/无盘复制）：https://redis.io/docs/latest/operate/oss_and_stack/management/replication/
- 官方 Sentinel 文档（配置项与事件完整列表）：https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/
- 官方 Cluster 规范（槽/重定向/gossip/迁移）：https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/
- antirez 关于 16384 槽的原始讨论：https://github.com/redis/redis/issues/2576
