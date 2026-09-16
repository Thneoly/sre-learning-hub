# Lab 01 · 解答：流复制全流程、延迟量化与断连追平

环境：装有 Docker 的 Ubuntu 22.04/24.04 VM（本学习中心的 candidate）。所有命令标注 `[任意节点]`，均在 VM 的 bash 里执行；SQL 经 `docker exec` 进入容器。

先建立全景：PG 的物理流复制在做什么。

```text
   应用写入(INSERT/UPDATE/COMMIT)
        │
        ▼
┌──────────────────┐    WAL 字节流(TCP 5432)     ┌──────────────────┐
│  pg-primary      │   walsender ───────────────► │  pg-replica      │
│  先写 WAL 再说   │   (pg_stat_replication 视角)  │  walreceiver     │
│  pg_wal/ 目录     │                              │  WAL 落盘 → 回放  │
└──────────────────┘                              │  hot standby 只读 │
   提交即返回（异步复制，                            └──────────────────┘
   不等备库确认）                                     pg_stat_wal_receiver 视角
```

和已学的几个机制对齐着理解：

- **WAL 先行**：MongoDB 里我们说过"写路径是 WAL"——提交的写先追加 journal（对照 `13-middleware/mongodb/01` 第 1 节）。PG 更彻底：数据页的修改总是先记入 WAL，崩溃恢复与复制消费的是同一份日志，所以"物理备库"本质上就是"另一台机器在重放崩溃恢复"。
- **一个位点走天下**：MySQL 主从要操心 binlog file + position（或 GTID，对照 `13-middleware/mysql/02` 第 3 节"主从复制全流程"），PG 只有一个全局单调递增的 **LSN**（Log Sequence Label，字节偏移）。主库问"你回放到哪个 LSN 了"，就知道备库落后多少字节——延迟计算因此是一条 SQL 的事。
- **全量 vs 增量**：首次接入要做物理全量（`pg_basebackup`），之后靠 WAL 流增量跟进；断线重连时，只要主库还留着那段 WAL（`wal_keep_size` 或复制槽担保）就直接续传，对应 Redis 的"全量 sync vs 部分重同步靠 repl_backlog"那一组对照（`13-middleware/redis/02` 5.1/5.2 节）。区别要记住：**repl_backlog 是固定环形缓冲，旧的会被冲掉；PG 的复制槽是"点名保留"——你不断开我可以无限留，代价是断开的从库会拖到主库磁盘写满**，这是后面第 7 步要亲手看到的。

版本说明：本 lab 用 `postgres:16`，17 同样适用；`wal_keep_size` 自 PG13 取代旧的 `wal_keep_segments`（条数），`pg_stat_replication` 的 `write_lag/flush_lag/replay_lag` 自 PG10 起提供——字段语义与默认值以官方文档为准。

## 步骤 1：网络与主库

做什么：建网络、起主库，显式带上流复制四参数。

为什么显式写出来：`wal_level=replica` 和 `max_wal_senders=10` 在 PG16 里恰好是默认值，但 SRE 不赌默认值——把容灾依赖的参数钉在启动命令里，任何环境拉起来的行为都一致。`wal_keep_size=256MB` 是给"短暂断线的从库"兜底的 WAL 保留量；`max_replication_slots=10` 给复制槽留名额。

```bash
# [任意节点] 建网 + 起主库（复制参数全部显式）
docker network create pg-lab-net
docker run -d --name pg-primary --network pg-lab-net \
  -e POSTGRES_PASSWORD=pg123 \
  postgres:16 \
  postgres -c wal_level=replica -c max_wal_senders=10 \
           -c wal_keep_size=256MB -c max_replication_slots=10

# 等主库就绪
until docker exec pg-primary pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done
docker exec pg-primary psql -U postgres -Atc "SHOW wal_level;"
```

验证输出：

```text
replica
```

## 步骤 2：复制账号与 pg_hba

做什么：建 `repl` 账号，给 `pg_hba.conf` 加一条 replication 专用规则，然后 reload。

为什么：物理复制的连接连的不是普通数据库，而是一个**伪数据库 `replication`**——`pg_hba.conf` 里 `host all all ...` 的 `all` 不匹配它，漏掉这条规则是新手搭流复制的第一大坑（现象：`pg_basebackup` 卡在 `no pg_hba.conf entry for replication`）。生产上右边的来源列应写从库网段而不是 `all`，这里演练环境从简。

```bash
# [任意节点] 复制账号 + pg_hba + 热加载
docker exec pg-primary psql -U postgres -c \
  "CREATE ROLE repl WITH LOGIN REPLICATION PASSWORD 'repl123';"
docker exec pg-primary bash -c 'echo "host replication repl all scram-sha-256" >> $PGDATA/pg_hba.conf'
docker exec pg-primary psql -U postgres -c "SELECT pg_reload_conf();"
```

验证输出：

```text
CREATE ROLE
 pg_reload_conf
----------------
 t
(1 row)
```

`pg_reload_conf()` 只热加载配置文件，不断连接——对应 MySQL 的 `SET GLOBAL ...` + 部分reload 场景，不需要重启实例。

## 步骤 3：pg_basebackup 拉起备库

做什么：用一条幂等的容器命令把"全量备份 + 起备库"合成一步。

为什么每个细节都在：

- `--user postgres`：默认以 root 跑 `pg_basebackup` 会落下一属主为 root 的数据目录，postgres 启动时直接 FATAL 拒绝；
- `-R`：备份结束时写 `standby.signal`（PG12+ 备库的身份标记，旧的 `standby_mode` 参数已不存在）和 `primary_conninfo`；
- `-X stream`：全量期间产生的 WAL 也走流式传输，保证备份自洽（这是生产唯一推荐的姿势，`-X fetch` 要求 WAL 留到备份结束）；
- `-C -S lab_slot`：顺手创建名为 `lab_slot` 的物理复制槽并让备库认领——从此主库为它**点名保留** WAL；
- `.pgpass`：`-R` 写进 `primary_conninfo` 的连接串**不含密码**，首次 walreceiver 认证用的是容器启动时的 `PGPASSWORD` 环境变量，但 `docker start` 重启后走的是 `~/.pgpass`（HOME=/var/lib/postgresql，在容器层里，stop/start 不丢）；
- `if [ ! -f "$PGDATA/standby.signal" ]`：幂等开关。`docker start` 会重放容器命令，没有它，重启时 `pg_basebackup` 会对非空目录报错，备库永远起不来——这正是"停机再恢复"演练能成立的前提。

```bash
# [任意节点] 备库：首次启动时做 basebackup，之后重启直接以备库拉起
mkdir -p ~/pg-lab
docker run -d --name pg-replica --network pg-lab-net --user postgres \
  -e PGPASSWORD=repl123 \
  postgres:16 \
  bash -c 'set -e; if [ ! -f "$PGDATA/standby.signal" ]; then \
    pg_basebackup -h pg-primary -U repl -D "$PGDATA" -R -X stream -C -S lab_slot -P; \
    echo "pg-primary:5432:replication:repl:repl123" > "$HOME/.pgpass"; chmod 600 "$HOME/.pgpass"; \
  fi; exec docker-entrypoint.sh postgres'

# 看着它完成：先是一段 basebackup 进度，随后 postgres 以 standby 启动
docker logs -f pg-replica
# 出现 "database system is in consistent standby mode" / "started streaming WAL from primary" 即 Ctrl-C
```

验证输出（主库视角的复制会话）：

```bash
# [任意节点]
docker exec pg-primary psql -U postgres -x -c \
  "SELECT application_name, client_addr, state, sync_state, sent_lsn, replay_lsn FROM pg_stat_replication;"
docker exec pg-replica psql -U postgres -Atc "SELECT pg_is_in_recovery();"
docker exec pg-replica psql -U postgres -Atc "SELECT status FROM pg_stat_wal_receiver;"
```

```text
-[ RECORD 1 ]----+-------------------------
application_name | walreceiver
client_addr      | 172.18.0.3
state            | streaming
sync_state       | async
sent_lsn         | 0/3000060
replay_lsn       | 0/3000060
t
streaming
```

三个观察点：`state=streaming` 即流复制建立；`sync_state=async` 说明这是异步复制——主库提交不等备库（`sent_lsn` 与 `replay_lsn` 的差就是字节级落后）；`application_name` 显示 `walreceiver` 是默认值，生产上多从库时应在 `primary_conninfo` 里加 `application_name=pg-replica-1` 以便区分（`pg_stat_replication` 每个从库一行，与 MySQL `SHOW PROCESSLIST` 里看 Binlog Dump 线程同一个思路）。

## 步骤 4：验证复制——主写从查

做什么：建业务表、灌初始数据，从备库读回来。

```bash
# [任意节点] 建 schema 与业务表 + 1000 行种子数据（全新库里没有 app schema，必须先建）
docker exec pg-primary psql -U postgres -c "CREATE SCHEMA IF NOT EXISTS app;"
docker exec pg-primary psql -U postgres -c \
  "CREATE TABLE app.events(id bigserial PRIMARY KEY, payload text NOT NULL, created_at timestamptz DEFAULT now());"
docker exec pg-primary psql -U postgres -c \
  "INSERT INTO app.events(payload) SELECT 'seed-'||g FROM generate_series(1,1000) g;"
docker exec pg-replica psql -U postgres -Atc "SELECT count(*) FROM app.events;"
# 增量也通：主库补 1 行，备库立刻可见（异步复制，本地盘通常毫秒级）
docker exec pg-primary psql -U postgres -c "INSERT INTO app.events(payload) VALUES ('manual-1');"
sleep 1
docker exec pg-replica psql -U postgres -Atc "SELECT count(*) FROM app.events;"
```

验证输出：

```text
INSERT 0 1000
1000
INSERT 0 1
1001
```

顺手验证备库的只读语义（这就是报表/OLAP 查询能安全挂上来的原因，把 18-bigdata/05 里"长报表拖垮交易库"的互相伤害问题在数据库层隔离开）：

```bash
# [任意节点] 备库上写会被拒绝
docker exec pg-replica psql -U postgres -c "INSERT INTO app.events(payload) VALUES ('nope');"
```

```text
ERROR:  cannot execute INSERT in a read-only transaction
```

注意这行报错是**恢复模式**给的，不是权限：备库进程以恢复状态运行，天然拒绝一切写。`hot_standby=on`（PG 默认）让它在恢复的同时还能接读连接。

## 步骤 5：pgbench 压测 + 延迟采样落盘

做什么：先起采样循环（每 0.5 秒一条追加到 `~/pg-lab/lag.log`），再压主库 30 秒。

为什么这样量化：`pg_stat_replication` 一行里有两类延迟——`write_lag/flush_lag/replay_lag`（**时间**维度：主库提交后，本地落盘、备库收到、备库回放各落后多久）和 `pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)`（**字节**维度：备库还欠多少 WAL 没回放）。时间维度拿来对用户讲 SLA（"报表最多慢 X 秒"），字节维度拿来做容量与告警（WAL 保留量、磁盘水位）。落盘的样本就是以后接 Prometheus exporter 的数据源形态（自己写 exporter 可对照 `02-programming/04` 工具二的 prometheus_client 套路，把这条循环换成常驻进程即可）。

```bash
# [任意节点] 终端 A：采样循环（60 次 × 0.5s ≈ 30s，覆盖整个压测窗口）
for i in $(seq 1 60); do
  B=$(docker exec pg-primary psql -U postgres -Atc \
    "SELECT coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn),0) FROM pg_stat_replication;" 2>/dev/null | cut -d. -f1)
  L=$(docker exec pg-primary psql -U postgres -Atc \
    "SELECT coalesce(extract(epoch from replay_lag),0) FROM pg_stat_replication;" 2>/dev/null)
  printf '%s lag_bytes=%s replay_lag_s=%s\n' "$(date +%T)" "${B:-NA}" "${L:-NA}" >> ~/pg-lab/lag.log
  sleep 0.5
done
```

```bash
# [任意节点] 终端 B：初始化 pgbench 数据（-s 1 → pgbench_accounts 10 万行，每 scale 单位 10 万行）并压测
docker exec pg-primary pgbench -i -s 1 -U postgres postgres
docker exec pg-primary pgbench -U postgres -c 4 -j 2 -T 30 postgres
```

验证输出（压测中段看主库）：

```bash
# [任意节点]
docker exec pg-primary psql -U postgres -x -c \
  "SELECT state, write_lag, flush_lag, replay_lag,
          pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
   FROM pg_stat_replication;"
tail -5 ~/pg-lab/lag.log
```

```text
-[ RECORD 1 ]-------------------------
state      | streaming
write_lag  | 00:00:00.0012
flush_lag  | 00:00:00.0158
replay_lag | 00:00:00.0417
lag_bytes  | 90984
21:40:07 lag_bytes=104536 replay_lag_s=0.0389
21:40:08 lag_bytes=90984 replay_lag_s=0.0417
21:40:08 lag_bytes=59320 replay_lag_s=0.0271
21:40:09 lag_bytes=0 replay_lag_s=0
21:40:09 lag_bytes=0 replay_lag_s=0        ← 压测结束，几十毫秒内追平
```

读这段数据的姿势：`write_lag < flush_lag < replay_lag` 是正常排序（写→落盘→回放逐级累加）；本地盘 + 4 客户端的负载下 lag 在几十 KB~几百 KB 间抖动、压测一停秒归零。如果生产上 `replay_lag` 持续上涨且 `lag_bytes` 不收敛，就是备库回放能力不足（单回放进程是瓶颈，常见于备库还挂着大报表）——对策思路与 MySQL"延迟成因与对策"（`13-middleware/mysql/02` 第 3 节）同源：隔离负载、砍单事务大事务、备库换更快的盘。

## 步骤 6：模拟备库宕机 → 主库继续写 → 拉回追平

做什么：`docker stop` 备库，主库再写 5000 行，`docker start` 备库，轮询到追平并留档。

为什么值得盯中间态：备库一断，主库 `pg_stat_replication` 的那一行**直接消失**（对照 MySQL：从库断开后 dump 线程退出，`SHOW REPLICAS` 同样没了）——监控"复制状态"要同时盯"有没有行"和"行的 state"，这是 PromQL 里两条告警规则的区别。而 `lab_slot` 会转为 `active=f`，主库仍为它保留 WAL：断线期间主库产生的 `down-*` 行全在这段保留的 WAL 里。

```bash
# [任意节点] 1) 停备库
docker stop pg-replica

# 2) 观察主库：复制行消失、槽仍在并保留 WAL
docker exec pg-primary psql -U postgres -Atc "SELECT count(*) FROM pg_stat_replication;"
docker exec pg-primary psql -U postgres -x -c \
  "SELECT slot_name, active, restart_lsn FROM pg_replication_slots;"

# 3) 主库继续写入（真实场景：从库宕了，交易不受影响——这就是异步复制的可用性语义）
docker exec pg-primary psql -U postgres -c \
  "INSERT INTO app.events(payload) SELECT 'down-'||g FROM generate_series(1,5000) g;"

# 4) 拉回备库（幂等命令直接走 standby 分支，不重新 basebackup）
docker start pg-replica
until docker exec pg-replica pg_isready -U postgres >/dev/null 2>&1; do sleep 1; done

# 5) 轮询追平：备库 count == 主库 count 即追平
TARGET=$(docker exec pg-primary psql -U postgres -Atc "SELECT count(*) FROM app.events;" | tr -d '[:space:]')
while :; do
  C=$(docker exec pg-replica psql -U postgres -Atc "SELECT count(*) FROM app.events;" | tr -d '[:space:]')
  [ "$C" = "$TARGET" ] && break
  sleep 1
done
printf '%s catchup ok rows=%s\n' "$(date +%T)" "$C" >> ~/pg-lab/catchup.log
cat ~/pg-lab/catchup.log
```

验证输出：

```text
0                          ← pg_stat_replication 行数：备库断开后归零
-[ RECORD 1 ]--------------
slot_name   | lab_slot
active      | f            ← 槽空闲但保留着 restart_lsn
restart_lsn | 0/4A21B450
INSERT 0 5000
21:46:33 catchup ok rows=6001
```

追平的机制拆开看：`docker start` 后 walreceiver 用 `.pgpass` 过 scram 认证、从槽的 `restart_lsn` 续传断线期间的 WAL、备库回放线程消费——三件事都不需要重新全量。**但是**：如果断线时间足够长、积压 WAL 超过了主库的保留能力（`wal_keep_size` 之外又没有槽担保），walsender 会因为"需要的 WAL 已被回收"拒绝续传，备库就只能重新 `pg_basebackup`。所以"槽保数据"与"槽撑磁盘"是一体两面：生产上必须配"槽积压量"告警（`pg_replication_slots` 的 `restart_lsn` 落后 `pg_current_wal_lsn()` 的字节数），积压到水位先处理从库、必要时先删槽保主库——这正是本 lab 第 5 步那条采样曲线的镜像用法。

最终一致性核对（对应 check.sh 第 8/9 项）：

```bash
# [任意节点]
docker exec pg-primary psql -U postgres -Atc "SELECT count(*) FROM app.events;"
docker exec pg-replica  psql -U postgres -Atc "SELECT count(*) FROM app.events;"
docker exec pg-primary psql -U postgres -Atc "SELECT count(*) FROM pgbench_accounts;"
docker exec pg-replica  psql -U postgres -Atc "SELECT count(*) FROM pgbench_accounts;"
```

```text
6001
6001
100000
100000
```

## 步骤 7（选学）：Patroni 三容器——流复制的"自动挡"

做什么：换一套 compose，把"谁来当主库"这件事从人手里交给 Patroni + etcd。

为什么 lab 主体不这么做：手工方案让你看清了流复制的每个零件（walsender/槽/standby.signal/追平），Patroni 是在这些零件外面加一层**自动编排**——DCS（etcd，Raft 多数派，选主的安全性来自 `19-distributed/03` 第 4 节"Raft 全流程"里讲的任期与多数派约束）里租约一个 leader 键，持有者即主库；PG 挂了或租约丢了，Patroni 把备库提升为新主并改写其余备库的 `primary_conninfo`。这填补的是流复制最大的空白：**PG 原生没有 failover**——主库死了，备库不会自己升主，应用也不会知道该连谁（对照 redis lab 里哨兵 `+switch-master` 事件完成的事，`13-middleware/redis/labs/01`）。

```yaml
# [任意节点] 保存为 ~/pg-lab/patroni-compose.yml（选学，判分不包含）
# 镜像 tag、环境变量解析规则以 Patroni/etcd 官方仓库为准（ghcr.io/zalando/patroni）
services:
  etcd:
    image: quay.io/coreos/etcd:v3.5.17
    environment:
      ETCD_NAME: etcd0
      ETCD_LISTEN_CLIENT_URLS: http://0.0.0.0:2379
      ETCD_ADVERTISE_CLIENT_URLS: http://etcd:2379
      ETCD_LISTEN_PEER_URLS: http://0.0.0.0:2380
      ETCD_INITIAL_ADVERTISE_PEER_URLS: http://etcd:2380
      ETCD_INITIAL_CLUSTER: etcd0=http://etcd:2380
      ETCD_INITIAL_CLUSTER_TOKEN: patroni-pg-lab
  pg1:
    image: ghcr.io/zalando/patroni:latest
    hostname: pg1
    environment:
      PATRONI_NAME: pg1
      PATRONI_ETCD3_HOSTS: "'etcd:2379'"
      PATRONI_RESTAPI_LISTEN: 0.0.0.0:8008
      PATRONI_POSTGRESQL_LISTEN: 0.0.0.0:5432
      PATRONI_SUPERUSER_USERNAME: postgres
      PATRONI_SUPERUSER_PASSWORD: pg123
      PATRONI_REPLICATION_USERNAME: replicator
      PATRONI_REPLICATION_PASSWORD: repl123
    depends_on: [etcd]
    ports: ["8008:8008"]
  pg2:
    image: ghcr.io/zalando/patroni:latest
    hostname: pg2
    environment:
      PATRONI_NAME: pg2
      PATRONI_ETCD3_HOSTS: "'etcd:2379'"
      PATRONI_RESTAPI_LISTEN: 0.0.0.0:8008
      PATRONI_POSTGRESQL_LISTEN: 0.0.0.0:5432
      PATRONI_SUPERUSER_USERNAME: postgres
      PATRONI_SUPERUSER_PASSWORD: pg123
      PATRONI_REPLICATION_USERNAME: replicator
      PATRONI_REPLICATION_PASSWORD: repl123
    depends_on: [etcd]
    ports: ["8009:8008"]
```

```bash
# [任意节点] 起栈 → 看集群拓扑（Leader 诞生过程就是一次 Raft 租约抢占）
cd ~/pg-lab && docker compose -f patroni-compose.yml up -d
sleep 20
curl -s http://localhost:8008/cluster
docker compose -f patroni-compose.yml exec pg1 patronictl list
```

验证输出（`/cluster` 的形态，名字以你实际配置为准）：

```json
[{"name":"pg1","role":"Leader","state":"running","api_url":"http://pg1:8008"},
 {"name":"pg2","role":"Replica","state":"running","api_url":"http://pg2:8008"}]
```

试两件事加深理解（做完 `docker compose down` 清掉）：`docker compose stop pg1` 后 `curl http://localhost:8009/cluster`，看到 pg2 在几秒内变为 Leader——这就是 lab 主体的"手工追平"之外，"自动升主 + 拓扑收敛"补齐的半边；再想一个问题：这个两节点集群 etcd 只有一个，**etcd 自身成了新的单点**——生产至少三节点 etcd 与两节点 PG 配对，或五节点 etcd，这也是 `19-distributed/03` "N=3 容 1" 那笔账（2.2 节）的具体应用。K8s 环境里 Patroni 常被 Operator（如 CloudNativePG/Zalando postgres-operator）替代，DCS 换成 Kubernetes API 本身——选型时以官方文档为准。

## 运行 check.sh

```bash
# [任意节点]（在 lab 目录内）
chmod +x check.sh && ./check.sh
```

预期全部通过：

```text
PASS: 主库容器 pg-primary 运行中
PASS: 备库容器 pg-replica 运行中
PASS: 两容器均接入 pg-lab-net
PASS: 主库 pg_is_in_recovery=f
PASS: 备库 pg_is_in_recovery=t
PASS: 备库存在 standby.signal
PASS: 主库 pg_stat_replication 出现 state=streaming
PASS: 物理复制槽 lab_slot 存在且 active
PASS: 主备 app.events 行数一致（>=6000）
PASS: 主备 pgbench_accounts 各 100000 行
PASS: 备库只读（INSERT 被拒绝且报 read-only）
PASS: lag.log 存在且数值合理（>=5 行，lag_bytes 均在 [0,256MB)）
PASS: catchup.log 存在且追平记录有效（rows=6001）

SCORE: 13/13
```

## 清理

```bash
# [任意节点] check 通过后再清理
docker rm -f pg-primary pg-replica
docker network rm pg-lab-net
cd ~/pg-lab && docker compose -f patroni-compose.yml down --remove-orphans 2>/dev/null; cd -
rm -rf ~/pg-lab
```

## 复盘要点

- **异步复制的契约**：主库提交即返回，备库落后是常态而非故障。本 lab 里 `replay_lag` 几十毫秒；要"提交即确认至少落一个备库"，PG 的做法是 `synchronous_standby_names` 指定同步备库 + `synchronous_commit=on`（备库已 fsync 落盘即确认，对应第 02 章 §1 五档表的第四档，等价 MySQL after_sync 半同步）；若还要求"提交后立即可在备库读到"，才提级到 `synchronous_commit=remote_apply`（等备库重放完成，对照同表第五档）——与 MySQL 半同步复制（`13-middleware/mysql/02` 第 3 节）是同一权衡的两家实现；读写分离下"写后立读"的一致性陷阱也一样：刚提交的数据在备库可能还查不到，对策同 MySQL"读写分离一致性陷阱"一节。
- **一个 LSN 走天下**：位点（file+pos/GTID vs 单调 LSN）、延迟（Seconds_Behind_Source vs replay_lag/lag_bytes）、保留（repl_backlog 环形缓冲 vs wal_keep_size/复制槽）——三组概念在两家数据库间严格对位，面经与排障都能互相翻译。
- **复制槽是双刃剑**：它保证断线从库不丢 WAL，也保证磁盘会被断线从库写满。槽积压量（`pg_current_wal_lsn() - restart_lsn`）必须进告警，处置顺序永远是"先救从库，实在不行再弃槽"。
- **备库重启不等于重建**：`standby.signal` + `primary_conninfo` + `.pgpass` 三件套齐了，`docker start` 就是纯续传。重建（重新 basebackup）只发生在所需 WAL 已被回收时——所以保留量参数（`wal_keep_size`）的大小等于你给自己买的"从库修复时间窗口"。
- **流复制 ≠ 高可用**：本 lab 的从库恢复是自动的，但主库死了没有东西会切。自动 failover 要靠外层编排（Patroni/Operator），而编排的安全性来自 DCS 的多数派——数据库的高可用最终又落回 `19-distributed/03` 的共识问题。
