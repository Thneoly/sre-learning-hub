# Lab 05 解答 · ClickHouse 双分片集群

对照 task.md 的 9 步逐步给出"做什么 + 为什么 + 验证输出"。所有命令在装有 docker 的 Ubuntu VM 上执行（`# [任意节点]`），工作目录 `~/ch-lab/`。

## 第 1 步：compose 与配置文件

**做什么**：写 1 个 compose + 3 个配置 XML（两 CH 共享一份 cluster.xml、各一份 macros）。

```bash
# [任意节点] 目录骨架
mkdir -p ~/ch-lab/conf && cd ~/ch-lab

# cluster.xml：两节点内容完全相同——ZK 后端 + 两个集群拓扑
cat > conf/cluster.xml <<'EOF'
<clickhouse>
    <zookeeper>
        <node index="1">
            <host>zookeeper</host>
            <port>2181</port>
        </node>
    </zookeeper>
    <remote_servers>
        <!-- 主拓扑：2 分片 × 各 1 副本，验证数据分布与 parts -->
        <sre_lab>
            <shard>
                <internal_replication>true</internal_replication>
                <replica>
                    <host>ch1</host>
                    <port>9000</port>
                </replica>
            </shard>
            <shard>
                <internal_replication>true</internal_replication>
                <replica>
                    <host>ch2</host>
                    <port>9000</port>
                </replica>
            </shard>
        </sre_lab>
        <!-- 副本演示：1 分片 × 2 副本，验证 ZK 协调的真复制 -->
        <sre_lab_ha>
            <shard>
                <internal_replication>true</internal_replication>
                <replica>
                    <host>ch1</host>
                    <port>9000</port>
                </replica>
                <replica>
                    <host>ch2</host>
                    <port>9000</port>
                </replica>
            </shard>
        </sre_lab_ha>
    </remote_servers>
</clickhouse>
EOF

# macros：两节点各一份，{shard}/{replica} 宏在建表时展开
cat > conf/macros-ch1.xml <<'EOF'
<clickhouse>
    <macros>
        <shard>01</shard>
        <replica>r1</replica>
    </macros>
</clickhouse>
EOF
cat > conf/macros-ch2.xml <<'EOF'
<clickhouse>
    <macros>
        <shard>02</shard>
        <replica>r2</replica>
    </macros>
</clickhouse>
EOF
```

```yaml
# [任意节点] ~/ch-lab/docker-compose.yml（yaml 用编辑器写入，内容如下）
services:
  zookeeper:
    image: zookeeper:3.9
    container_name: zookeeper
    hostname: zookeeper
    networks: [ch-lab-net]
    mem_limit: 512m
    environment:
      ZOO_4LW_COMMANDS_WHITELIST: "srvr,mntr,ruok"
      ZK_SERVER_HEAP: "256"          # 镜像默认堆可能超过 512m 容器限额，压到 256MB
  ch1:
    image: ${CH_IMAGE:-clickhouse/clickhouse-server:25.3}
    container_name: ch1
    hostname: ch1
    networks: [ch-lab-net]
    mem_limit: 2g
    depends_on: [zookeeper]
    environment:
      CLICKHOUSE_SKIP_USER_SETUP: "1"   # 不跳过的话镜像会把 default 用户限制为仅本机访问，
                                        # Distributed 的 ch1->ch2 跨节点查询/写入直接 AUTHENTICATION_FAILED
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    ports:
      - "8123:8123"
      - "9000:9000"
    volumes:
      - ./conf/cluster.xml:/etc/clickhouse-server/config.d/cluster.xml:ro
      - ./conf/macros-ch1.xml:/etc/clickhouse-server/config.d/macros.xml:ro
  ch2:
    image: ${CH_IMAGE:-clickhouse/clickhouse-server:25.3}
    container_name: ch2
    hostname: ch2
    networks: [ch-lab-net]
    mem_limit: 2g
    depends_on: [zookeeper]
    environment:
      CLICKHOUSE_SKIP_USER_SETUP: "1"
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    ports:
      - "8124:8123"
      - "9001:9000"
    volumes:
      - ./conf/cluster.xml:/etc/clickhouse-server/config.d/cluster.xml:ro
      - ./conf/macros-ch2.xml:/etc/clickhouse-server/config.d/macros.xml:ro
networks:
  ch-lab-net:
    name: ch-lab-net
```

**为什么**：CH 对"集群"的全部认知来自 config.d 的 XML（remote_servers + zookeeper 节点），没有像 Doris FE 那样的中心元数据——这是 08 章第 8 节"元数据与协调"一行的具体形态。宏必须在两节点不同：metrics_local 的 zk 路径靠 `{shard}` 展开成 01/02 两条独立子树（各自一组单副本），ha_local 写死共享路径靠 `{replica}` 区分两个副本（提示 3 的两种拓扑就差在这一个字符串上）。镜像 tag（默认 25.3）以 Docker Hub `clickhouse/clickhouse-server` 官方页面当前 LTS 为准，`CH_IMAGE=...` 可一键覆盖。`internal_replication=true` 表示"写入由表引擎自己复制"（对 sre_lab 是单副本，对 sre_lab_ha 是双副本），这是 Replicated* 引擎拓扑的标准声明。

## 第 2 步：起集群并确认 ZK 通道

```bash
# [任意节点] 起三容器，轮询等两节点就绪
cd ~/ch-lab
docker compose up -d
for i in $(seq 1 60); do
  if docker exec ch1 clickhouse-client --query 'SELECT 1' >/dev/null 2>&1 && \
     docker exec ch2 clickhouse-client --query 'SELECT 1' >/dev/null 2>&1; then
    echo "both ready"; break
  fi
  sleep 2
done

# ZK 协调通道在位：能读到根下的 znode（至少 1 个：clickhouse/）
docker exec ch1 clickhouse-client --query "SELECT name FROM system.zookeeper WHERE path = '/'"
# 预期：clickhouse（以及 CH 自建的分布式 DDL 队列等；数量 ≥ 1 即通）

# 顺手验证宏生效（两节点应分别输出 01/r1 与 02/r2）
docker exec ch1 clickhouse-client --query "SELECT * FROM system.macros FORMAT TSV"
docker exec ch2 clickhouse-client --query "SELECT * FROM system.macros FORMAT TSV"
```

**为什么**：`system.zookeeper` 是 CH 内建的对 ZK 树的 SQL 视图（08 章第 9 节），查得动 = config.d 的 zookeeper 配置、容器网络、ZK 进程三者全通。第 3 步的 `ON CLUSTER` DDL 走 ZK 的分布式 DDL 队列，这一步不通后面全部白搭。

## 第 3 步：ON CLUSTER 建表（先建 MV 后写入）

```bash
# [任意节点] 写 init.sql 并送进 ch1 执行（-i 走 stdin，--multiquery 支持多语句）
cat > init.sql <<'EOF'
CREATE DATABASE IF NOT EXISTS sre_lab ON CLUSTER sre_lab;

-- 本地表：真正存数据的 ReplicatedMergeTree（08 章第 5 节双表架构的"里层"）
CREATE TABLE sre_lab.metrics_local ON CLUSTER sre_lab (
    ts     DateTime,
    host   String,
    metric String,
    val    Float64
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/metrics_local', '{replica}')
  PARTITION BY toDate(ts)
  ORDER BY (host, ts);

-- 分布式表：不存数据的路由视图，分片键 sipHash64(host)——同一 host 恒定落同一分片
CREATE TABLE sre_lab.metrics_all ON CLUSTER sre_lab AS sre_lab.metrics_local
  ENGINE = Distributed('sre_lab', 'sre_lab', 'metrics_local', sipHash64(host));

-- 预聚合目标表 + 物化视图（必须先于写入创建：MV 只处理建表之后的数据）
CREATE TABLE sre_lab.host_agg ON CLUSTER sre_lab (
    host String,
    cnt  UInt64,
    vsum Float64
) ENGINE = SummingMergeTree ORDER BY host;

CREATE MATERIALIZED VIEW sre_lab.metrics_mv ON CLUSTER sre_lab TO sre_lab.host_agg AS
SELECT host, count() AS cnt, sum(val) AS vsum
FROM sre_lab.metrics_local GROUP BY host;

-- host_agg 的查询入口（对称地也做一层 Distributed）
CREATE TABLE sre_lab.host_agg_all ON CLUSTER sre_lab AS sre_lab.host_agg
  ENGINE = Distributed('sre_lab', 'sre_lab', 'host_agg', sipHash64(host));

-- 副本演示表：zk 路径写死共享（不带 {shard}），两副本 = r1/r2 同组
CREATE TABLE sre_lab.ha_local ON CLUSTER sre_lab_ha (
    id   UInt32,
    note String
) ENGINE = ReplicatedMergeTree('/clickhouse/tables/ha/ha_local', '{replica}')
  ORDER BY id;
EOF
docker exec -i ch1 clickhouse-client --multiquery < init.sql
# 预期：每条 DDL 返回两节点各一行的执行状态（num_errors 为 0、exception 为空），
#      无 ExceptionSummary / TIMEOUT 字样

# 抽查：两个节点上都有本地表与 Distributed 表（DDL 队列广播到位）
docker exec ch2 clickhouse-client --query \
  "SELECT name, engine FROM system.tables WHERE database = 'sre_lab' ORDER BY name FORMAT PrettyCompact"
```

**为什么**：`ON CLUSTER sre_lab` 让 DDL 经 ZK 队列广播到两个节点（省去逐台执行，也埋下"节点离线期间漏 DDL"的 schema 漂移风险——08 章第 8 节对比表的由来）。`ORDER BY (host, ts)` 是给"按主机+时间范围"的监控查询设计的排序键（08 章第 3 节：排序键决定压缩与裁剪）。MV 先建是硬性顺序，否则 sum(cnt) 只会计到建视图之后的部分（提示 4）。

## 第 4 步：批量写入 100000 行

```bash
# [任意节点] 10 批 × 10000 行，服务端 numbers() 造确定性数据（ts 按批次 b 错开 1 小时）
for b in 0 1 2 3 4 5 6 7 8 9; do
  docker exec ch1 clickhouse-client --query "
    INSERT INTO sre_lab.metrics_all
    SELECT toDateTime(today()) + ${b} * 3600 + (n % 3600)       AS ts,
           concat('host', leftPad(toString(n % 20), 2, '0'))    AS host,
           if(n % 2 = 0, 'cpu', 'mem')                          AS metric,
           toFloat64(n % 100)                                   AS val
    FROM (SELECT number + ${b} * 10000 AS n FROM numbers(10000))"
  echo "batch $b done"
done

# 等异步分发到齐（Distributed 默认 insert_distributed_sync=0，秒级延迟）
for i in $(seq 1 30); do
  c=$(docker exec ch1 clickhouse-client --query 'SELECT count() FROM sre_lab.metrics_all')
  [ "$c" = "100000" ] && { echo "count=$c"; break; }
  sleep 2
done
```

**为什么**：确定性造数让每个数字都可复核：n 取 0..99999 → 每 host 恰 5000 行；`val = n % 100` 的全量和 = 1000 × (0+1+…+99) = **4950000**；host07 的行满足 `n ≡ 7 (mod 20)`，其 `val` 和为 200000 + 5000×7 = **235000**。ts 里的 `${b} * 3600` 批次偏移不是装饰：四个字段的取值周期（3600/20/2/100）都整除 3600，而批次间隔 10000 行、batch b 与 b+9 恰好相差 90000（3600 的整数倍）——不加偏移时这两批的 INSERT 块**逐字节相同**，会被 ReplicatedMergeTree 的按块哈希去重当成重复写入丢弃（日志特征 `Deduplication path already exists`），总量定格 90000。每批 INSERT 在每个分片生成至多 1 个新 part——10 批就是第 6 步要观察的 parts 基数，也是"too many parts"病灶的最小模型（08 章第 6 节：生产里把这里的 10 批换成每秒 10 次插入，就会看到写入被 delay 再被拒绝）。异步窗口的运维含义见 08 章第 5 节：发起节点崩溃在"缓冲与送达之间"会丢这批数据，要不丢就 `insert_distributed_sync=1`。

## 第 5 步：验证数据分布

```bash
# [任意节点] 分布式总量与数值
docker exec ch1 clickhouse-client --query \
  "SELECT count(), toUInt64(sum(val)) FROM sre_lab.metrics_all"
# 预期：100000    4950000

# 两节点本地 count：都 > 0，之和 = 100000（各自数字随 sipHash 分布，不必是 50000）
docker exec ch1 clickhouse-client --query 'SELECT count() FROM sre_lab.metrics_local'
docker exec ch2 clickhouse-client --query 'SELECT count() FROM sre_lab.metrics_local'
# 预期示例：50440 / 49560（你的数字不同但两者相加必须精确等于 100000）

# 再看一层的分布语义：每个 host 的全部行都完整落在同一个分片
docker exec ch1 clickhouse-client --query \
  "SELECT host, count() FROM sre_lab.metrics_local GROUP BY host ORDER BY host LIMIT 3"
docker exec ch2 clickhouse-client --query \
  "SELECT host, count() FROM sre_lab.metrics_local GROUP BY host ORDER BY host LIMIT 3"
# 预期：两边各自的 host 集合不相交，且每个 host 都是 5000
```

**为什么**："之和 = 总量"验证的是 sharding（每行恰好存一份），"各 host 集合不相交"验证的是分片键语义：`sipHash64(host)` 是确定性哈希，同一 host 永远同一分片——这既是读侧裁剪的来源，也是"按 host 的查询永远只打一个分片"倾斜风险的来源（对照 17-distributed/05-sharding-and-rebalancing.md 第 1 节范围与哈希分片的取舍）。

## 第 6 步：parts 观察（写入后 merge 前后）

```bash
# [任意节点] 写入后立刻取两节点的 active parts 数（before）
P1=$(docker exec ch1 clickhouse-client --query \
  "SELECT count() FROM system.parts WHERE database='sre_lab' AND table='metrics_local' AND active")
P2=$(docker exec ch2 clickhouse-client --query \
  "SELECT count() FROM system.parts WHERE database='sre_lab' AND table='metrics_local' AND active")
echo "ch1=$P1 ch2=$P2"     # 预期：各 10 上下（后台 merge 已在跑则更小）

# 可选：趁 merge 未完，看一次进行中的合并（参与合并的 part 数、耗时、进度）
docker exec ch1 clickhouse-client --query \
  "SELECT database, table, elapsed, num_parts, round(progress * 100, 1) AS pct
   FROM system.merges FORMAT PrettyCompact"
# 预期：0~数行 metrics_local 的 merge；跑慢一步可能已经空（合并完成了）

# 手工强制合并（演示用；生产别当日常操作——它重写整个分区）
docker exec ch1 clickhouse-client --query 'OPTIMIZE TABLE sre_lab.metrics_local FINAL'
docker exec ch2 clickhouse-client --query 'OPTIMIZE TABLE sre_lab.metrics_local FINAL'

# 合并后（after）并落盘记录
A1=$(docker exec ch1 clickhouse-client --query \
  "SELECT count() FROM system.parts WHERE database='sre_lab' AND table='metrics_local' AND active")
A2=$(docker exec ch2 clickhouse-client --query \
  "SELECT count() FROM system.parts WHERE database='sre_lab' AND table='metrics_local' AND active")
cat > parts-observation.txt <<EOF
ch1 parts_before=$P1 parts_after=$A1
ch2 parts_before=$P2 parts_after=$A2
EOF
cat parts-observation.txt
# 预期示例：
#   ch1 parts_before=10 parts_after=1
#   ch2 parts_before=10 parts_after=1
# （before=1 也合法：merge 已追平；after 通常= 分区数×1）

# 顺带看单个 part 的压缩效果（rows 与 bytes_on_disk 的巨大差距就是 08 章第 1 节）
docker exec ch1 clickhouse-client --query \
  "SELECT partition, name, rows, formatReadableSize(bytes_on_disk) AS disk
   FROM system.parts WHERE database='sre_lab' AND table='metrics_local' AND active
   ORDER BY partition FORMAT PrettyCompact"
```

**为什么**：这份记录是 08 章第 6 节因果链的实测起点——`before` 是"INSERT 产生 parts"的速度样本，`after` 是 merge 能把它们压回去的证据；两者的差值就是后台合并的消化能力。判分只认文件格式（ch1/ch2 两行、`parts_before=N parts_after=M`），after≥1 即可，数字本身随 merge 时机浮动（提示 6）。文件写在 `~/ch-lab/` 即可，check.sh 会在自己目录、`~/ch-lab`、运行目录三处找。

## 第 7 步：验证物化视图

```bash
# [任意节点] 总量与维度核对
docker exec ch1 clickhouse-client --query 'SELECT sum(cnt) FROM sre_lab.host_agg_all'
# 预期：100000（MV 覆盖全部写入——因为第 3 步先建了它）

docker exec ch1 clickhouse-client --query \
  "SELECT host, sum(cnt) AS cnt, toUInt64(sum(vsum)) AS vsum
   FROM sre_lab.host_agg_all WHERE host IN ('host00','host07','host19')
   GROUP BY host ORDER BY host FORMAT PrettyCompact"
# 预期：
#   host00   5000   200000
#   host07   5000   235000
#   host19   5000   295000
```

**为什么**：写入路径是"INSERT → metrics_local 落 part → 同一 insert block 触发 metrics_mv → 聚合行写入本节点 host_agg"，所以 host_agg 的行分布在两个节点上，经 `host_agg_all` 汇聚后语义完整。查询用 `sum(cnt)` 而不是直接 `cnt`：SummingMergeTree 的合并在后台异步，同 host 可能暂时多行，`sum()` 恒等于全量（08 章第 2 节"合并语义"的读侧姿势）。

## 第 8 步：副本演练——真复制与停节点

```bash
# [任意节点] 先看复制协调的"正面"：ch1 插入，ch2 无需任何写入就能查到
docker exec ch1 clickhouse-client --query \
  "INSERT INTO sre_lab.ha_local VALUES (1,'written-on-ch1'),(2,'synced-via-zk'),(3,'stop-node-demo')"
sleep 3
docker exec ch2 clickhouse-client --query 'SELECT id, note FROM sre_lab.ha_local ORDER BY id'
# 预期：3 行原样出现——数据经 ZK 复制日志从 r1 同步到 r2（06 章租户表那行的现场版）

# 停掉 ch2：两种拓扑一好一坏
docker stop ch2
docker exec ch1 clickhouse-client --query 'SELECT count() FROM sre_lab.ha_local'
# 预期：3——ha_local 在 ch1 上还有完整副本，查询照常（副本冗余）

docker exec ch1 clickhouse-client --query 'SELECT count() FROM sre_lab.metrics_all'
# 预期：报错（Connection refused / All connection attempts failed 一类，随版本措辞不同）
#      —— metrics_local 每分片只有 1 个副本，shard 02 随 ch2 一起不可达

# 恢复：ch2 回来后自动重连 ZK、追平复制状态
docker start ch2
for i in $(seq 1 30); do
  docker exec ch2 clickhouse-client --query 'SELECT 1' >/dev/null 2>&1 && { echo "ch2 back"; break; }
  sleep 2
done
docker exec ch1 clickhouse-client --query 'SELECT count() FROM sre_lab.metrics_all'
# 预期：100000——分片回来，分布式表恢复完整视图
```

**为什么**：这一步把 08 章第 4 节的可用性网格演成了实验：`sre_lab_ha`（1 分片 ×2 副本）坏一个副本不伤查询，`sre_lab`（2 分片 ×1 副本）坏一个节点就缺一块数据。生产的 2 分片 ×2 副本（4 节点）把两个维度相乘，任意单节点故障两者都不受影响——代价是 ZK/Keeper 至少 3 节点（过半仲裁，06 章第 3 节）。注意停的是副本而数据仍在 ch1 本地 part 里：再证 06 章"ZK 挂/副本掉不等于数据丢，丢的是协调与冗余"。

## 第 9 步：判分与清理

```bash
# [任意节点] 在仓库 lab 目录运行判分（只读检查）
cd 16-bigdata/labs/05-clickhouse-cluster
chmod +x check.sh
./check.sh
```

通过结果（14 项全过）：

```
PASS: 容器 ch1 处于 Running
PASS: 容器 ch2 处于 Running
PASS: 容器 zookeeper 处于 Running
PASS: 分布式表 metrics_all count() = 100000
PASS: 两个分片都有数据（ch1=50440，ch2=49560）
PASS: 两节点本地 count 之和 = 100000（50440 + 49560）
PASS: SUM(val) = 4950000（与造数公式一致）
PASS: metrics_local 为 ReplicatedMergeTree（ZK 副本协调的本地表）
PASS: metrics_all 为 Distributed 分布式表
PASS: system.zookeeper 可查（ZK 协调通道在位，根下 1 个 znode）
PASS: system.replicas 无 is_readonly 副本（副本表健康）
PASS: 物化视图聚合总量 sum(cnt) = 100000
PASS: host07 聚合正确（cnt=5000，vsum=235000）
PASS: parts 观察记录存在且格式正确（/home/user/ch-lab/parts-observation.txt）

SCORE: 14/14
```

（分片计数、znode 数等示例值以你的实测为准；判分只比较确定性数值。）

```bash
# [任意节点] 清理：down 连同 ch-lab-net 网络一起删；磁盘紧张再删镜像
cd ~/ch-lab && docker compose down
docker rmi clickhouse/clickhouse-server:25.3 zookeeper:3.9   # 可选
```

常见卡点速查：ZK 连不上先看 `docker logs zookeeper`（OOMKill 反复重启 = 堆超限额，回第 1 步的 `ZK_SERVER_HEAP=256`）；`ON CLUSTER` 卡住不动 = DDL 队列在等离线节点，确认两容器都 Running；`Too many parts` 出现说明你把批次拆得比本方案碎得多——正好回 08 章第 6 节对照因果链。
