# Lab 01 · 解答：主从复制搭建、断连追平与 binlog 误删恢复

按 task.md 的六个任务逐步讲解。每步给"做什么 + 为什么 + 验证输出"。文中位点数值（如 `P1=1259`）与 binlog 文件名是示例，实际以你机器上 `SHOW MASTER STATUS` 的输出为准（新起容器初始化会滚动几次日志，常见 `binlog.000002`/`binlog.000003`，不一定是 `.000001`）。另：`mysql:8.0` 镜像**不含 mysqlbinlog**，第 5 步起需要在宿主机 `sudo apt-get install -y mysql-server-core-8.0`（提供 `/usr/bin/mysqlbinlog`，只装工具不起服务）。

## 0. 清场（如果之前试过）

```bash
# [Ubuntu VM]
docker rm -f mysql-m mysql-s 2>/dev/null
docker network rm mysqlnet 2>/dev/null
```

## 1. 起一主一从两个容器

```bash
# [Ubuntu VM]
docker network create mysqlnet

docker run -d --name mysql-m --net mysqlnet \
  -e MYSQL_ROOT_PASSWORD=root123 -p 3306:3306 \
  mysql:8.0 \
  --server-id=1 \
  --log-bin=binlog \
  --binlog-format=ROW

docker run -d --name mysql-s --net mysqlnet \
  -e MYSQL_ROOT_PASSWORD=root123 -p 3307:3306 \
  mysql:8.0 \
  --server-id=2 \
  --read-only=ON
```

为什么：

- `--log-bin=binlog` 打开 binlog 且指定文件前缀，复制与恢复全靠它；`--binlog-format=ROW` 是 8.0 默认，恢复时重放的是行镜像，最安全。
- `--read-only=ON` 防止应用误连从库写入（root 仍可写，这是后面验证"从库数据被复制改变"的前提）。
- 两容器同在 `mysqlnet`，从库可以直接用容器名 `mysql-m` 当主机名解析。

等主库就绪（首次初始化要十几秒）：

```bash
# [Ubuntu VM] mysqladmin 在容器内自检,直到返回 mysqld is alive
until docker exec mysql-m mysqladmin ping -uroot -proot123 --silent 2>/dev/null; do
  sleep 3; echo waiting...
done
```

## 2. 建复制账号并挂上主库

```bash
# [Ubuntu VM] 在主库建复制账号
docker exec mysql-m mysql -uroot -proot123 -e "
CREATE USER 'repl'@'%' IDENTIFIED BY 'repl123';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
FLUSH PRIVILEGES;"
```

账号只需要 `REPLICATION SLAVE` 一个权限，最小授权，泄漏了也读不到业务数据。

```bash
# [Ubuntu VM] 记下主库当前位点(例: File=binlog.000001, Position=157)
docker exec mysql-m mysql -uroot -proot123 -e "SHOW MASTER STATUS\G"
```

输出形如（数字以你的为准，8.4+ 里这条命令改名为 `SHOW BINARY LOG STATUS`）：

```
*************************** 1. row ***************************
             File: binlog.000001
         Position: 157
     Binlog_Do_DB:
 Binlog_Ignore_DB:
```

两个实例现在都是空库，从任意位点开始都行——就用当前位置。

```bash
# [Ubuntu VM] 从库挂主库并启动复制(把 LOG_FILE/LOG_POS 换成你刚查到的)
docker exec mysql-s mysql -uroot -proot123 -e "
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-m',
  SOURCE_PORT=3306,
  SOURCE_USER='repl',
  SOURCE_PASSWORD='repl123',
  SOURCE_LOG_FILE='binlog.000001',
  SOURCE_LOG_POS=157,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;"
```

`GET_SOURCE_PUBLIC_KEY=1` 是 8.0 的经典坑：默认认证插件 `caching_sha2_password` 要求从库先拿到主库公钥才能完成握手，缺这个参数 IO 线程会报 `Authentication requires secure connection`。

```bash
# [Ubuntu VM] 验证复制线程
docker exec mysql-s mysql -uroot -proot123 -e "SHOW REPLICA STATUS\G" | grep -E 'Running:|Seconds_Behind'
```

预期输出：

```
          Replica_IO_Running: Yes
         Replica_SQL_Running: Yes
     Seconds_Behind_Source: 0
```

IO 收日志、SQL 重放，两个 `Yes` 才算链路通。

## 3. 造数据验证复制

```bash
# [Ubuntu VM] 主库建表插前 3 行(一行一条语句,便于后面按位点截取)
docker exec mysql-m mysql -uroot -proot123 -e "
CREATE DATABASE shop;
CREATE TABLE shop.orders (id INT PRIMARY KEY, v VARCHAR(50)) ENGINE=InnoDB;
INSERT INTO shop.orders VALUES (1,'row-1');
INSERT INTO shop.orders VALUES (2,'row-2');
INSERT INTO shop.orders VALUES (3,'row-3');"

# 验证从库已同步
docker exec mysql-s mysql -uroot -proot123 -e "SELECT COUNT(*) FROM shop.orders;"
# COUNT(*): 3
```

记位点（下一步恢复的起点）：

```bash
# [Ubuntu VM] 记 P1,示例输出 Position: 1259
docker exec mysql-m mysql -uroot -proot123 -e "SHOW MASTER STATUS\G" | grep -E 'File:|Position:'
```

## 4. 模拟从库停止 + 追平

```bash
# [Ubuntu VM] 从库"宕机":停复制线程(容器保持运行,便于观察)
docker exec mysql-s mysql -uroot -proot123 -e "STOP REPLICA;"

# 主库继续写入 id=4,5
docker exec mysql-m mysql -uroot -proot123 -e "
INSERT INTO shop.orders VALUES (4,'row-4');
INSERT INTO shop.orders VALUES (5,'row-5');"

# 记 P2(= 恢复的终点,只覆盖 4、5 两条 INSERT),示例 Position: 2340
docker exec mysql-m mysql -uroot -proot123 -e "SHOW MASTER STATUS\G" | grep -E 'File:|Position:'

# 主库再写 id=6(故意放在 P2 之后,验证恢复区间不会碰到它)
docker exec mysql-m mysql -uroot -proot123 -e "
INSERT INTO shop.orders VALUES (6,'row-6');"
```

此刻验证"停了就是停了"：

```bash
# [Ubuntu VM]
docker exec mysql-s mysql -uroot -proot123 -e "SELECT COUNT(*) FROM shop.orders;"
# COUNT(*): 3   ← 从库停在 3 行

docker exec mysql-s mysql -uroot -proot123 -e "SHOW REPLICA STATUS\G" | grep -E 'Running:|Seconds_Behind'
# Replica_IO_Running: No / Replica_SQL_Running: No / Seconds_Behind_Source: NULL
# 停机期间"延迟"是 NULL 而不是 0——监控上必须把 NULL 当告警,不能当正常
```

追平：

```bash
# [Ubuntu VM] 恢复复制,轮询直到追平
docker exec mysql-s mysql -uroot -proot123 -e "START REPLICA;"
sleep 3
docker exec mysql-s mysql -uroot -proot123 -e "SELECT COUNT(*) FROM shop.orders;"
# COUNT(*): 6

docker exec mysql-s mysql -uroot -proot123 -e "SHOW REPLICA STATUS\G" | grep -E 'Running:|Seconds_Behind'
# 两个 Yes,Seconds_Behind_Source: 0
```

原理：IO 线程凭记录的位点从主库 binlog 断点续传到 relay log，SQL 线程补放——这就是"主从延迟"在极端情况下的全貌。

## 5. 模拟误删

```bash
# [Ubuntu VM] 开发手滑,删了两行,且已复制到从库
docker exec mysql-m mysql -uroot -proot123 -e "
DELETE FROM shop.orders WHERE id IN (4,5);"

sleep 2
docker exec mysql-s mysql -uroot -proot123 -e "SELECT COUNT(*) FROM shop.orders;"
# COUNT(*): 4   ← 从库也没了,这就是要在主库侧恢复再"流"下去的原因
```

先"验尸"再动手——解码 binlog 确认坏事件确实在、且看清楚位置：

```bash
# [Ubuntu VM] 镜像里没有 mysqlbinlog:先在宿主机装,再把 binlog 拷出来解码
sudo apt-get install -y mysql-server-core-8.0（若提示输密码，见本地 _meta/labtest-brief.md，不写入公开文档）
docker cp mysql-m:/var/lib/mysql/binlog.000003 /tmp/    # 文件名以 SHOW MASTER STATUS 的 File 为准
mysqlbinlog --base64-output=decode-rows -vv /tmp/binlog.000003 | tail -40
# 尾部应能看到:
# ### DELETE FROM `shop`.`orders`
# ###   @1=4
# ### DELETE FROM `shop`.`orders`
# ###   @1=5
```

## 6. 用 binlog 恢复（区间重放）

思路：第 3 步记的 `P1` 是"插完 1~3"的位点，第 4 步记的 `P2` 是"插完 4、5"的位点，`[P1, P2)` 恰好只包含 id 4、5 两条 INSERT 的行事件。把这段重放进主库，等于让那两行"再发生一次"；重放本身又写进主库 binlog，自然复制到从库。

```bash
# [Ubuntu VM] 先预览要重放的内容(把 1259/2340 换成你的 P1/P2,文件名以实际为准)
mysqlbinlog --start-position=1259 --stop-position=2340 \
  /tmp/binlog.000003 | head -50
# 应只出现 @1=4 和 @1=5 的 Write_rows,没有 id=6,更没有 DELETE

# 确认无误后,管道重放进主库(宿主机 mysqlbinlog 解出事件流,docker exec -i 接管道)
mysqlbinlog --start-position=1259 --stop-position=2340 \
  /tmp/binlog.000003 \
  | docker exec -i mysql-m mysql -uroot -proot123 shop
```

位点语义（PITR 的通用规则）：`--start-position` 从"该偏移开始的事件"读起；`--stop-position` 在"始于该偏移的事件"前停下。`SHOW MASTER STATUS` 返回的正是下一个事件的起始偏移，所以 P1/P2 天然是安全边界。误删场景的完整版本是"备份恢复 + 从备份位点重放到坏事件之前"，本 lab 省掉备份那步，直接从 binlog 里捞原始 INSERT。

验证恢复且已同步：

```bash
# [Ubuntu VM]
docker exec mysql-m mysql -uroot -proot123 -e "SELECT COUNT(*) FROM shop.orders;"
# COUNT(*): 6

docker exec mysql-s mysql -uroot -proot123 -e "SELECT COUNT(*) FROM shop.orders;"
# COUNT(*): 6

# 两边逐行一致
docker exec mysql-m mysql -uroot -proot123 -e "CHECKSUM TABLE shop.orders;"
docker exec mysql-s mysql -uroot -proot123 -e "CHECKSUM TABLE shop.orders;"
# 两行输出的 Checksum 值相同

docker exec mysql-s mysql -uroot -proot123 -e "SHOW REPLICA STATUS\G" | grep -E 'Running:|Seconds_Behind'
# 两个 Yes,Seconds_Behind_Source: 0
```

## 7. 运行判分脚本

```bash
# [Ubuntu VM] 把本目录 check.sh 拷到 VM 后
chmod +x check.sh
./check.sh
```

预期输出：

```
== Lab 01 检查开始 ==
PASS: 主库容器 mysql-m 运行中
PASS: 从库容器 mysql-s 运行中
PASS: Replica_IO_Running=Yes
PASS: Replica_SQL_Running=Yes
PASS: 复制延迟 Seconds_Behind_Source=0
PASS: 主库 shop.orders 行数=6
PASS: 从库 shop.orders 行数=6
PASS: 主库误删行(id 4,5)已恢复
PASS: 从库误删行(id 4,5)已恢复
PASS: 主从 CHECKSUM TABLE 一致
== 结果 ==
SCORE: 10/10
```

## 复盘要点

- 复制三线程：dump 在主库，IO/SQL 在从库；排障先分清是"收不到"（IO）还是"放不动"（SQL）。
- `Seconds_Behind_Source` 为 NULL 表示链路断，不是延迟为零；监控必须区分对待。
- binlog 恢复的本质是"重放一段事件区间"，位点边界来自"坏事件开始的位置"；动手前一定先 `--base64-output=decode-rows -vv` 预览，重放前先确认区间内容。
- 生产上等价流程是"XtraBackup 全量恢复 + mysqlbinlog 从备份位点重放到误操作前"，本 lab 的区间截取就是其中的最后一步。
