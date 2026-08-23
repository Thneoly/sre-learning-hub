# Lab 01 · 主从复制搭建、断连追平与 binlog 误删恢复

> 难度：★★☆ ｜ 考点：SRE-MySQL 复制链路与数据恢复 ｜ 前置：无（建议先读 11-middleware/mysql/02） ｜ 预计 40~60 分钟

## 场景

你是值班 SRE。团队有一套 MySQL 主从（还没搭，你来搭）：主库承接写入，从库供报表与容灾。今天要演练三件事，都是生产真实发生过的：

1. 新业务上线前，先把"一主一从"搭起来，并验证数据能同步；
2. 从库所在机器"宕机"过一次（用停止复制线程模拟），恢复后要追平主库；
3. 开发在主库上误删了两行数据（`DELETE` 已经复制到从库），需要用 binlog 把这两行救回来，且恢复动作本身也要同步到从库。

环境：一台装有 Docker 的 Ubuntu 22.04/24.04 VM。全部操作在本机 bash 与 `docker exec` 内完成，不需要 kubeadm 集群。

约定（check.sh 按此判分，务必遵守）：

- 容器名 `mysql-m`（主）与 `mysql-s`（从），镜像 `mysql:8.0`
- `MYSQL_ROOT_PASSWORD=root123`
- 业务表：`shop.orders(id INT PRIMARY KEY, v VARCHAR(50))`，最终主从各有 **6 行**（id 1~6）
- 误删的是 **id=4 与 id=5** 两行，最终必须恢复

## 任务清单

1. 用 Docker 起两个 `mysql:8.0` 实例：主库开 `--log-bin`（binlog 文件名 `binlog`）、`--server-id=1`；从库 `--server-id=2` 并设只读；两容器接入同一个 docker network。
2. 在主库创建复制账号 `repl`（密码 `repl123`，权限 `REPLICATION SLAVE`）；从库用 `CHANGE REPLICATION SOURCE TO` 按主库当前 binlog 位点（file + position，不开 GTID）挂上主库并 `START REPLICA`，确认 `Replica_IO_Running` / `Replica_SQL_Running` 均为 `Yes`。
3. 主库建库建表 `shop.orders`，插入 id 1~3，确认从库能查到（造数据验证复制）。
4. 在从库停止复制线程，主库插入 id 4、5、6，确认从库数据停在 3 行；随后重新启动复制，等待并确认从库追平到 6 行。
5. 模拟误删：在主库执行 `DELETE FROM shop.orders WHERE id IN (4,5);`，确认从库也只剩 4 行。
6. 用 `mysqlbinlog` 从主库 binlog 中截取"插入 id 4、5"那段事件区间，重放进主库，使误删的两行恢复；确认恢复动作被复制到从库，最终主从各 6 行且 `CHECKSUM TABLE` 一致。注意：`mysql:8.0` 镜像里**不带 mysqlbinlog**，在宿主机 `sudo apt-get install -y mysql-server-core-8.0` 装一个（Ubuntu 24.04 的 mysqlbinlog 在这个包里，只装二进制、不会起 MySQL 服务），再 `docker cp` 把 binlog 拷到宿主机处理。

## 验收标准

- `docker ps` 能看到 `mysql-m`、`mysql-s` 两个运行中的容器
- 从库 `SHOW REPLICA STATUS\G` 中 `Replica_IO_Running: Yes`、`Replica_SQL_Running: Yes`、`Seconds_Behind_Source: 0`
- 主库与从库 `SELECT COUNT(*) FROM shop.orders;` 均为 6，且 `SELECT id FROM shop.orders WHERE id IN (4,5);` 两边都返回 4、5
- 主从两边 `CHECKSUM TABLE shop.orders;` 的校验值相同
- 运行 `./check.sh` 输出 `SCORE: 10/10`

## 提示（卡住再看）

<details><summary>提示 1：从库连不上主库 / IO 线程起不来</summary>

`CHANGE REPLICATION SOURCE TO` 里 `SOURCE_HOST` 用容器网络里的主库容器名（同一 network 内可解析）。若报认证错误，8.0 默认 `caching_sha2_password`，在 CHANGE 语句里加 `GET_SOURCE_PUBLIC_KEY=1`。出错先看 `SHOW REPLICA STATUS\G` 的 `Last_IO_Error`。
</details>

<details><summary>提示 2：不知道从哪个位点开始复制</summary>

刚起的主库上执行 `SHOW MASTER STATUS\G`（8.0；8.4+ 为 `SHOW BINARY LOG STATUS`），把显示的 `File` 与 `Position` 填进 `SOURCE_LOG_FILE` / `SOURCE_LOG_POS`，再 `START REPLICA`。位点之后发生的写都会被从库拉走。
</details>

<details><summary>提示 3：怎么截取"只包含 id 4、5 插入"的 binlog 区间</summary>

关键是在插入前后各记一次位点：插完 id 1~3 记 `P1`，插完 id 4、5（插 6 之前）记 `P2`。恢复时（binlog 文件名以 `SHOW MASTER STATUS` 的 File 为准，新起的容器不一定是 `.000001`；`mysql:8.0` 镜像里没有 mysqlbinlog，先在宿主机装 `mysql-server-core-8.0`）：

```bash
docker cp mysql-m:/var/lib/mysql/binlog.000003 /tmp/
mysqlbinlog --start-position=P1 --stop-position=P2 /tmp/binlog.000003 | docker exec -i mysql-m mysql -uroot -proot123 shop
```

就只会重放这两条 INSERT。区间边界等于"坏事件开始的位置"，这正是 PITR 的通用套路。
</details>

<details><summary>提示 4：恢复后怎么确认同步到了从库</summary>

对主库 binlog 的重放就是普通的 SQL 会话写入，会照常写主库 binlog、被 dump 线程推给从库。循环看从库 `SELECT COUNT(*)` 与 `SHOW REPLICA STATUS` 的 `Seconds_Behind_Source` 回到 0 即可。
</details>
