# Lab 01 · PostgreSQL 流复制：物理备库、延迟观测与断连追平

> 难度：★★☆ ｜ 考点：中间件高可用（PG 物理流复制与容灾） ｜ 前置：装有 Docker 的 Ubuntu 22.04/24.04 VM ｜ 预计 40~60 分钟

## 场景

你是电商组的 SRE。订单库是单机 PostgreSQL，上周一次计划内重启导致报表查询把交易查询拖到超时——复盘时你翻到 16-bigdata/05 里那句话："一次大扫描把 buffer pool 里的热点交易页全部挤出去……长报表又占用行锁和 undo 链路，拖垮主从复制"，结论很清楚：报表负载必须与交易库隔离。团队决定先在演练环境验证 PostgreSQL 原生方案：**一主一物理备库（流复制）**，备库开 hot standby 只读承接报表，同时充当容灾副本。

今天要演练四件事，全部是生产真实形态：

1. 从零搭一主一从：主库起复制参数 → `pg_basebackup` 做物理全量 → WAL 流式同步；
2. 验证复制：主库写、备库读，`pg_stat_replication` 里看到 `streaming`；
3. 用 pgbench 压主库，**量化**复制延迟并落盘留档（以后接告警的就是这条曲线）；
4. 模拟备库机器宕机：停掉备库 → 主库继续写 → 拉回备库 → 验证自动追平。

环境：一台装有 Docker 的 Ubuntu 22.04/24.04 VM（本学习中心统一叫 candidate）。全部操作在本机 bash 与 `docker exec` 内完成，不需要 kubeadm 集群。

约定（check.sh 按此判分，务必遵守）：

| 对象 | 值 | 说明 |
|---|---|---|
| docker 网络 | `pg-lab-net` | 普通 bridge 网络即可，无需静态 IP（原因见提示 2） |
| 主库容器 | `pg-primary` | 镜像 `postgres:16`（17 同样适用；字段与参数差异以官方文档为准） |
| 备库容器 | `pg-replica` | 同镜像，用 `pg_basebackup` 出来的数据目录直起 |
| 超级用户 | `postgres` / `pg123` | `POSTGRES_PASSWORD` |
| 复制账号 | `repl` / `repl123` | 权限 `REPLICATION` |
| 复制槽 | `lab_slot` | `pg_basebackup -C -S` 创建的物理槽 |
| 业务表 | `app.events(id bigserial PK, payload text, created_at timestamptz)` | 最终主从各 **6001** 行（1000 seed + 1 手工 + 5000 down） |
| 压测 | `pgbench -i -s 1` 后 `-T 30` | `pgbench_accounts` 两边各 **100000** 行（每 scale 单位 10 万行） |
| 延迟留档 | `~/pg-lab/lag.log` | 每行 `HH:MM:SS lag_bytes=<整数> replay_lag_s=<小数>` |
| 追平留档 | `~/pg-lab/catchup.log` | 至少一行 `HH:MM:SS catchup ok rows=<整数>` |

## 任务清单

1. 创建网络 `pg-lab-net`，启动主库 `pg-primary`：显式带上 `wal_level=replica`、`max_wal_senders=10`、`wal_keep_size=256MB`、`max_replication_slots=10`（其中 `wal_keep_size` 是 PG13+ 的写法，替代旧的 `wal_keep_segments`）。
2. 在主库创建复制账号 `repl`，并修改 `pg_hba.conf` 允许其复制连接后 `pg_reload_conf()`。注意：`host all all ...` 里的 `all` **不匹配** `replication` 伪数据库，必须单独加一条 `host replication repl ...`。
3. 启动备库 `pg-replica`：容器命令里先判断 `$PGDATA/standby.signal` 不存在才执行 `pg_basebackup -h pg-primary -U repl -D $PGDATA -R -X stream -C -S lab_slot -P`（`-R` 负责写 `standby.signal` 与 `primary_conninfo`，`-C -S` 顺带创建物理复制槽），随后 `exec docker-entrypoint.sh postgres`。这个幂等判断是后面"停机再恢复"能直接 `docker start` 的关键。
4. 验证复制建立：主库 `pg_stat_replication` 出现 `state=streaming` 行、备库 `pg_stat_replication` 对应的 `pg_stat_wal_receiver` 为 `streaming`、`pg_is_in_recovery()` 主 f 从 t。
5. 主库建 schema `app` 与表 `app.events` 并插入 1000 行（`seed-1` 到 `seed-1000`），确认备库能查到同样行数；主库再手工插 1 行确认增量同步。
6. 主库 `pgbench -i -s 1` 初始化，随后开一个**采样循环**（每 0.5 秒一次，格式见约定表）把 `pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn)` 与 `replay_lag` 追加到 `~/pg-lab/lag.log`；循环跑起来后再执行 `pgbench -c 4 -j 2 -T 30 postgres` 压主库。结束后确认 log 里有压测期间的非零延迟样本。
7. 模拟备库宕机：`docker stop pg-replica`，观察主库 `pg_stat_replication` 行消失、`pg_replication_slots` 里 `lab_slot` 变 `active=f` 但 WAL 仍被保留；主库继续插入 `down-1` 到 `down-5000` 共 5000 行；然后 `docker start pg-replica`，轮询直到备库 `app.events` 行数追平主库，把结果按约定格式写入 `~/pg-lab/catchup.log`，并确认两边 count 一致。
8. （选学，判分不包含）用 solution.md 附带的 Patroni compose（etcd + 双 PG）体会"流复制 + DCS + 自动 failover"与手工方案的差距。

## 验收标准

- `docker ps` 能看到 `pg-primary`、`pg-replica` 两个运行中的容器，均接入 `pg-lab-net`
- 主库 `SELECT state FROM pg_stat_replication;` 返回 `streaming`；物理槽 `lab_slot` 存在且 `active=t`
- 备库 `pg_is_in_recovery()` 为 `t` 且 `standby.signal` 存在；备库可读、写入被拒绝（read-only）
- 主备两边 `SELECT count(*) FROM app.events;` 均为 6001，`pgbench_accounts` 均为 100000
- `~/pg-lab/lag.log` 存在、不少于 5 行有效样本、`lag_bytes` 为 0 到 256MB 之间的整数
- `~/pg-lab/catchup.log` 存在且含 `catchup ok rows=<n>`（n ≥ 6001）
- 运行 `./check.sh` 输出 `SCORE: 13/13`

## 提示（卡住再看）

<details><summary>提示 1：备库容器到底怎么起</summary>

三个要点：**以 postgres 用户跑**（`--user postgres`，否则 `pg_basebackup` 落下的文件属主是 root，postgres 拒绝用该数据目录启动）；**幂等判断**（`standby.signal` 存在就跳过 basebackup，`docker start` 才能直接拉起备库）；**补 .pgpass**（`-R` 写进 `primary_conninfo` 的连接串不含密码，重启后 walreceiver 过 scram 认证靠 `~/.pgpass`）：

```bash
docker run -d --name pg-replica --network pg-lab-net --user postgres \
  -e PGPASSWORD=repl123 \
  postgres:16 \
  bash -c 'set -e; if [ ! -f "$PGDATA/standby.signal" ]; then \
    pg_basebackup -h pg-primary -U repl -D "$PGDATA" -R -X stream -C -S lab_slot -P; \
    echo "pg-primary:5432:replication:repl:repl123" > "$HOME/.pgpass"; chmod 600 "$HOME/.pgpass"; \
  fi; exec docker-entrypoint.sh postgres'
```
</details>

<details><summary>提示 2：为什么这次不像 redis lab 那样给静态 IP</summary>

redis 的哨兵把**IP**回写进自己的配置文件，IP 漂移就找不回旧主（对照 `11-middleware/redis/labs/01`）；而 PG 备库的 `primary_conninfo` 写的是**主机名** `pg-primary`，docker 内置 DNS 每次解析都能拿到当前地址，容器重建也不怕。什么时候仍需要固定地址：宿主机直连、或跨 subnet 做防火墙策略时。
</details>

<details><summary>提示 3：延迟采样的一条 SQL</summary>

在主库上查 `pg_stat_replication`（备库断开时该视图没有行，注意 `coalesce`/空值处理）：`SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn), replay_lag FROM pg_stat_replication;`——前者是**字节**落后量，后者是**时间**落后量。采样循环放在压测命令之前启动，压完再停。
</details>

<details><summary>提示 4：压测期间 lag.log 里全是 0 怎么办</summary>

采样频率提到 0.5 秒、压测延长到 `-T 60`，或把 pgbench 客户端加到 `-c 8`。本地盘上流复制回放很快，偶尔全 0 是正常的好消息；判分只要求记录有效且数值合法，不要求非零。
</details>
