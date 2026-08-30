# Lab 03 · 解答与讲解

> 运行环境：Ubuntu 24.04 VM（docker-ce 29.7.2 含 compose 插件，内存 10G，磁盘余约 25G）。Doris 2.x 镜像 tag 以 Docker Hub `apache/doris` 页面为准：**旧的 `2.0.3-fe-x86_64` 形态 tag 已从 Docker Hub 下架（pull 直接 not found），现行命名是 `fe-2.1.x` / `be-2.1.x`**（2026-08 实测 `fe-2.1.9`/`be-2.1.9` 可用，且仍支持本 lab 用的 `FE_SERVERS`/`FE_ID`/`BE_ADDR` 环境变量）。注意镜像不小：FE 解压后约 3.3G、BE 约 7.8G，合计约 11G 磁盘，拉取与解压都慢，预留时间。命令除特别标注外均在 `[任意节点]`（VM）执行。

## 第 1 步：compose 编排（固定 IP + 双容器各 2G）

```bash
# [任意节点]
mkdir -p ~/doris-lab && cd ~/doris-lab

cat > docker-compose.yml <<'EOF'
networks:
  doris_net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.31.80.0/24

services:
  fe:
    image: ${DORIS_FE_IMAGE:-apache/doris:fe-2.1.9}
    container_name: doris-fe
    hostname: fe
    networks:
      doris_net:
        ipv4_address: 172.31.80.2
    ports:
      - "8030:8030"   # FE HTTP（Stream Load 入口 / Web UI）
      - "9030:9030"   # FE MySQL 协议
    mem_limit: 2g
    environment:
      FE_SERVERS: "fe1:172.31.80.2:9010"
      FE_ID: "1"
      PRIORITY_NETWORKS: "172.31.80.0/24"

  be:
    image: ${DORIS_BE_IMAGE:-apache/doris:be-2.1.9}
    container_name: doris-be
    hostname: be
    depends_on:
      - fe
    networks:
      doris_net:
        ipv4_address: 172.31.80.3
    ports:
      - "8040:8040"   # BE HTTP（Stream Load 实际写入端）
    mem_limit: 2g
    environment:
      FE_SERVERS: "fe1:172.31.80.2:9010"
      BE_ADDR: "172.31.80.3:9050"
      PRIORITY_NETWORKS: "172.31.80.0/24"
EOF
```

为什么每个字段都长这样（SRE 视角逐条）：

- **固定 `ipv4_address`**：FE 把 BE 的 IP 写进元数据，BE 也把 FE 地址写进本地配置。用默认 DHCP 分配的容器 IP，一次 `down/up` 就换地址，元数据里留着旧 IP 的"幽灵 BE"。官方 docker 部署文档的标准做法就是专属子网 + 固定 IP；
- **`mem_limit: 2g` 各一**：VM 共 10G，FE+BE+容器开销+页缓存留有余量。注意 BE 的 `be.conf` 里 `mem_limit` 默认按**宿主机**内存百分比计算（看到的是 10G 而不是 2g 的 cgroup），若 BE 被 OOMKilled，进容器把 `be.conf` 的 `mem_limit` 改成绝对值（如 1600000000）再重启，以官方文档为准；
- **`BE_ADDR` 声明式注册**：镜像启动时自动向 `FE_SERVERS` 指定的 FE 注册，省掉手工 `ALTER SYSTEM ADD BACKEND`——但生产物理机部署仍要会那条 SQL（见第 2 步后的说明）；
- **8040 必须映射**：Stream Load 是 FE 回 307 把客户端重定向到 BE 的 8040，宿主机 curl 收到的重定向地址就是这个端口。

## 第 2 步：启动、等就绪、确认 FE/BE 存活

```bash
# [任意节点]
docker compose up -d
docker compose ps
# 预期: doris-fe  Up  doris-be  Up（BE 完成注册约需 30~60s）

# 轮询等 FE 的 MySQL 协议就绪（最多 5 分钟）
for i in $(seq 1 60); do
  if docker exec doris-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SELECT 1' >/dev/null 2>&1; then
    echo "FE ready (${i}x5s)"; break
  fi
  sleep 5
done

# 等到 BE Alive
for i in $(seq 1 24); do
  if docker exec doris-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SHOW BACKENDS\G' 2>/dev/null | grep -Eq 'Alive:[[:space:]]*(1|true|Yes)'; then
    echo "BE alive (${i}x5s)"; break
  fi
  sleep 5
done

docker exec doris-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SHOW FRONTENDS\G' | grep -E 'Name:|Alive:|Role:'
docker exec doris-fe mysql -h127.0.0.1 -P9030 -uroot -e 'SHOW BACKENDS\G'  | grep -E 'Alive:|TotalCapacity|HeartbeatPort'
# 预期: Alive: 1/true（FE 与 BE 各一行），TotalCapacity 为容器可见磁盘
```

说明：

- FE 容器镜像自带 mysql 客户端，所以全部 SQL 走 `docker exec doris-fe mysql ...`；若你用的镜像版本没有它，`sudo apt-get install -y mysql-client` 后在宿主机直连 `127.0.0.1:9030` 等价（协议同 `11-middleware/mysql`，Navicat/DBeaver 也能直接连）；
- 物理机部署时对应动作是手工注册：在 FE 的 MySQL 会话里执行 `ALTER SYSTEM ADD BACKEND "be-host:9050";`——docker 镜像的环境变量只是替你做了这一步，排障时要知道背后发生了什么；
- FE 自身高可用用内置的 BDBJE 复制 + Follower 选举（多 FE 观察者/候选者），**不需要 ZooKeeper**——这点与 `16-bigdata/06-zookeeper` 讲的"哪些系统真正依赖 ZK"对照：Kafka（旧版）/YARN RM HA/HBase 依赖，Doris/StarRocks 不依赖。

## 第 3 步：建库建表（Unique 模型）

```bash
# [任意节点]
docker exec -i doris-fe mysql -h127.0.0.1 -P9030 -uroot <<'EOF'
CREATE DATABASE IF NOT EXISTS sre_lab;
USE sre_lab;
CREATE TABLE IF NOT EXISTS events (
  event_day  DATE        NOT NULL COMMENT 'event date, part of unique key',
  event_time DATETIME    NOT NULL COMMENT 'event timestamp, part of unique key',
  host       VARCHAR(64) NOT NULL COMMENT 'hostname',
  metric     VARCHAR(64) NOT NULL COMMENT 'metric name',
  value      DOUBLE      COMMENT 'metric value, replaced on duplicate key'
)
UNIQUE KEY(event_day, event_time, host, metric)
PARTITION BY RANGE(event_day) (
  PARTITION p20260829 VALUES [("2026-08-29"), ("2026-08-30"))
)
DISTRIBUTED BY HASH(host) BUCKETS 4
PROPERTIES (
  "replication_num" = "1"
);
SHOW CREATE TABLE sre_lab.events\G
EOF
```

> **为什么 value 列不写 `REPLACE`**：Doris 2.x 的 Unique 模型建表若给非 key 列声明聚合类型，直接报 `errCode = 2, detailMessage = UNIQUE_KEYS table should not specify aggregate type for non-key column[value]`（2.1.9 实测）。语义不需要声明——Unique 模型对相同 Key 的行**本来就**是"后到整行覆盖"（早期 1.x 写法才要 `REPLACE`，照抄旧文档必踩）。要显式 REPLACE 聚合语义时应建 Aggregate 模型表，那是另一种模型。

模型选择的运维逻辑（对照 `16-bigdata/05-olap-doris-starrocks` 章）：

| 模型 | 语义 | 适用 |
| --- | --- | --- |
| Duplicate（明细） | 全保留，不去重 | 原始日志留底 |
| Aggregate | Key 相同按 value 列聚合函数合并 | 报表预聚合 |
| **Unique（本例）** | Key 相同整行覆盖（语义即 REPLACE，DDL 里不写 REPLACE，2.x 写了报错） | **幂等入库、CDC 同步、按主键更新** |

三重分桶/分区结构也要能讲出来：

- **UNIQUE KEY 四列**：监控场景天然主键 =（日期，时间，主机，指标名）——同一主机同一秒同一指标重复上报只保留一份；
- **RANGE 分区（按天）**：TTL/按天删除是"drop 掉一个分区"而非逐行 delete，数据生命周期管理的标准姿势；
- **HASH(host) BUCKETS 4**：数据按 host 摇到 4 个 tablet，查询可被 4 个 BE 并行扫（本实验单 BE 也生效，tablet 是并行与副本的最小单位，`replication_num=1` 是演示配置，生产至少 3）。

## 第 4 步：确定性造 1 万行 CSV

```bash
# [任意节点]（VM 自带 python3）
cd ~/doris-lab
python3 - <<'EOF'
import datetime

base = datetime.datetime(2026, 8, 29, 0, 0, 0)
with open("events.csv", "w") as f:
    for i in range(10000):
        t = base + datetime.timedelta(seconds=i)
        host = "host%02d" % (i % 20)                      # host00..host19 各 500 行
        metric = ("cpu_util", "mem_util", "disk_io", "net_in", "net_out")[i % 5]
        value = round((i % 1000) * 1.5, 2)                # SUM = 10x(0+..+999)x1.5 = 7492500
        f.write("2026-08-29,%s,%s,%s,%.2f\n" % (t.strftime("%Y-%m-%d %H:%M:%S"), host, metric, value))
print("events.csv: 10000 rows")
EOF

wc -l events.csv   # 预期 10000
head -2 events.csv
# 预期: 2026-08-29,2026-08-29 00:00:00,host00,cpu_util,0.00
#       2026-08-29,2026-08-29 00:00:01,host01,mem_util,1.50
```

预计算答案（判分依据，先手算再验证是容量/正确性验证的基本功）：

- `COUNT(*)` = 10000；`host07` 恰好 10000/20 = 500 行；
- `SUM(value)`：i%1000 完整跑 10 轮 0..999，`10 × (999×1000/2) × 1.5 = 7,492,500`。

## 第 5 步：Stream Load 首次导入 + 幂等重放

```bash
# [任意节点] label 参数化的导入脚本（SIMULATED 模式交付物之一，两模式同文件）
cat > stream-load.sh <<'EOF'
#!/usr/bin/env bash
# 用法: ./stream-load.sh <csv文件> <label>
# 运行位置: [任意节点] 能 curl 到 FE 8030 端口即可；label 每批必须唯一
set -eu
CSV="${1:?用法: $0 <csv文件> <label>}"
LABEL="${2:?用法: $0 <csv文件> <label>}"
curl -sS -u root: --location-trusted \
     -H "Expect: 100-continue" \
     -H "label:${LABEL}" \
     -H "column_separator:," \
     -H "columns:event_day,event_time,host,metric,value" \
     -H "max_filter_ratio:0.01" \
     -T "${CSV}" \
     http://127.0.0.1:8030/api/sre_lab/events/_stream_load
echo
EOF
chmod +x stream-load.sh
```

> **为什么必须显式 `Expect: 100-continue`**：Stream Load 走"FE 307 → BE"两段式，服务端要求客户端先声明 100-continue 再传数据体。有些 curl 模板习惯用 `-H "Expect:"` 把这个头删掉（对普通 HTTP 服务是防 1 秒等待的技巧），但对 Doris 会直接得到 `{"status":"FAILED","msg":"There is no 100-continue header"}`（2.1.9 实测）。curl 对大于 1KB 的 PUT 体通常会自动带上该头，但小文件不会——所以显式写上最稳。

```bash
# 第一次导入（label 一）
./stream-load.sh events.csv load-$(date +%Y%m%d%H%M%S)
# 预期返回 JSON 关键字段:
#   "Status": "Success"
#   "NumberLoadedRows": 10000
#   "NumberFilteredRows": 0

# 验证一：行数与聚合
docker exec doris-fe mysql -h127.0.0.1 -P9030 -uroot -e "
USE sre_lab;
SELECT COUNT(*) AS total FROM events;
SELECT host, ROUND(SUM(value),2) AS total_v FROM events GROUP BY host ORDER BY host LIMIT 3;
SELECT COUNT(*) AS h07 FROM events WHERE host='host07';"
# 预期: total=10000   h07=500   total_v 按 host 递增: host00=367500.00, host01=368250.00 ...
#       （每个 host 比上一个多 750，host07=372750.00，20 个 host 合计 7492500.00）

# 重放：新 label 再灌同一文件（模拟 Kafka consumer rebalance 后的重复消费）
sleep 2
./stream-load.sh events.csv load-replay-$(date +%Y%m%d%H%M%S)

# 验证二：重放后行数必须仍是 10000（Duplicate 模型会变 20000）
docker exec doris-fe mysql -h127.0.0.1 -P9030 -uroot -e "
USE sre_lab;
SELECT COUNT(*) AS total_after_replay FROM events;
SELECT ROUND(SUM(value),2) AS sum_v FROM events;"
# 预期: total_after_replay=10000   sum_v=7492500.00
```

幂等的两层机制（排障时必须分清）：

- **label 层（导入幂等键）**：同一 label 短期内重交会被拒绝（`label already used`），防的是**网络重试导致的同批多次写入**——At-Most-Once；
- **Unique 模型层（数据去重）**：不同 label 但主键相同的行，读取合并（merge-on-read / 2.x 的写时合并，以所用版本文档为准）后只留一份，防的是**上游业务侧重放**。两层各管一类重复，缺一不可。

Stream Load 三段式再确认：`curl → FE:8030`（鉴权、计划）`→ 307 → BE:8040`（真正写入，生成 label 事务）。所以 BE 挂了 Stream Load 必失败、FE 挂了则整库不可写但已有数据仍可从 BE 读（MPP 架构控制面/数据面分离，和 `12-data-streaming` 里 Kafka controller 与 broker 的分层同构）。

## 第 6 步（SIMULATED 路径）：三份交付物

环境跑不动（内存不够/镜像拉不动）时，在 lab 目录 `16-bigdata/labs/03-doris-quickstart/` 下产出：

1. **`doris-schema.sql`**：第 3 步的完整 DDL 原样落成文件；
2. **`stream-load.sh`**：第 5 步的导入脚本原样落成文件；
3. **`import-plan.md`**：导入计划文档，模板：

```markdown
# sre_lab.events 导入计划

## 数据概况
- 来源: 主机指标导出任务, 单批 10000 行, CSV 约 700KB
- 目标: Doris Unique 模型表 sre_lab.events（按天分区 / HASH(host) 4 桶）

## 批次与 label 规则
- 批次大小: 单批 <= 10 万行或 1GB（超过拆批, 大文件走 Broker Load）
- label 命名: load-{YYYYMMDD}-{批次序号}-{源端位点 topic-partition-offset}
  例: load-20260829-007-hostmetrics-2-384211
- 规则: label 全局唯一且可从源头追溯到重放区间

## 失败重试
- HTTP 非 200 / Status != Success: 检查 NumberFilteredRows 与 ErrorURL
- 同 label 重复提交被拒: 属预期（幂等保护）, 换新 label 重新导入
- BE 8040 不可达: 检查 BE Alive 后重试, FE 端事务默认 300s 超时后自动放弃

## 校验查询（每批导入后必跑）
- SELECT COUNT(*) FROM sre_lab.events;            -- 与源端行数对账
- SELECT ROUND(SUM(value),2) FROM sre_lab.events; -- 与源端预聚合对账
- SHOW LOAD WARNINGS;                             -- 过滤行排查
```

```bash
# [任意节点] SIMULATED 交付物生成示意（ddl 与脚本从上文复制）
cd <learning-hub>/16-bigdata/labs/03-doris-quickstart
vim doris-schema.sql stream-load.sh import-plan.md   # 内容如上
chmod +x stream-load.sh
./check.sh    # 自动输出 SIMULATED 模式并判分
```

## 第 7 步：清理（check.sh 通过后再做）

```bash
# [任意节点]
cd ~/doris-lab
docker compose down -v
rm -rf ~/doris-lab/events.csv
```

## 常见坑速查

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| Stream Load 返回 Fail to connect BE | BE 未 Alive 或 8040 未映射 | `SHOW BACKENDS` 确认 Alive；compose 补 8040 映射 |
| Stream Load 返回 `There is no 100-continue header` | curl 用 `-H "Expect:"` 把 100-continue 头删了（或小文件未自动带） | 显式加 `-H "Expect: 100-continue"`，见第 5 步说明 |
| 同 label 二次导入被拒 | label 幂等保护（预期行为） | 换新 label；重放场景本就该新 label |
| 重放后 COUNT 变 20000 | 建成了 Duplicate 模型表 | `SHOW CREATE TABLE` 核对，重建为 UNIQUE KEY 表 |
| FE 反复重启 | JVM 堆超过 2g 容器限额被 OOM kill | 进容器调小 `conf/fe.conf` 的 `-Xmx`（如 1g） |
| BE 容器 OOMKilled | be.conf 的 mem_limit 按宿主机 10G 百分比计算 | 改绝对值（如 1600000000），重启容器 |
| 建表报 too many tablets / 磁盘不足 | BE 可用磁盘不足默认水位（90%） | 单 BE 演示盘余量充足即可；生产加盘/加 BE |

## 附：check.sh 通过结果

full 模式：

```text
# [任意节点]
$ chmod +x check.sh && ./check.sh
== 模式: full（检测到 doris-fe 容器 Running，按真实集群判分） ==

PASS: 容器 doris-fe 处于 Running
PASS: 容器 doris-be 处于 Running
PASS: SHOW BACKENDS 中 BE 的 Alive 为真（已注册且存活）
PASS: 重放后 COUNT(*) 仍为 10000（Unique 模型幂等生效）
PASS: SUM(value) 为 7492500.0（与造数公式一致）
PASS: host07 行数为 500
PASS: events 表为 UNIQUE KEY 模型

SCORE: 7/7
```

simulated 模式：

```text
== 模式: SIMULATED（未检测到 Running 的 doris-fe，按三份交付物判分） ==

PASS: doris-schema.sql 存在且声明 UNIQUE KEY
PASS: doris-schema.sql 含 BUCKETS 与 replication_num
PASS: stream-load.sh 存在且含 _stream_load 端点与 label
PASS: import-plan.md 存在且含 label 规则与失败重试

SCORE: 4/4
```

## 延伸阅读

- Doris docker 部署（compose 与环境变量语义）：<https://doris.apache.org/docs/install/construct-docker/deploy-docker-compose/>
- Stream Load 手册（label/事务/307 重定向）：<https://doris.apache.org/docs/data-operate/import/import-way/stream-load-manual/>
- 数据模型（Unique/Aggregate/Duplicate）：<https://doris.apache.org/docs/data-table/data-model/>
