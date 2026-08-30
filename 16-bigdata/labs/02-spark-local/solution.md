# Lab 02 · 解答与讲解

> 运行环境：Ubuntu 24.04 VM（docker-ce 29.7.2，内存 10G，磁盘余约 25G）。镜像 `apache/spark:3.5.1`（约 1G，含 python3 与 pyspark；3.5.x 其他小版本同理，tag 以 Docker Hub `apache/spark` 页面为准）。命令全部在 `[任意节点]` 执行，Spark UI 在 `[本地Windows]` 浏览器看。

## 第 1 步：启动容器

```bash
# [任意节点]
docker run -d --name spark-lab \
  --memory 4g --cpus 2 \
  -p 4040:4040 \
  apache/spark:3.5.1 tail -f /dev/null

docker exec spark-lab bash -c 'python3 --version && ls /opt/spark/bin/spark-submit && nproc'
# 预期: Python 3.8.x / 3.9.x
#       /opt/spark/bin/spark-submit
#       2（local[*] 将拿满容器 CPU 配额）
```

要点：

- `--cpus 2` + `local[*]`：local 模式的并行度 = executor 内核数，容器配额就是它的上限。这是 `03-docker` 的 CPU 配额知识直接复用——限制配额比限制并发数更能模拟真实集群的"少核多任务"；
- `--memory 4g`：driver 默认堆 1G，100 万行数据完全够；镜像内进程以 uid 185（spark 用户）运行，`/opt/spark/work-dir` 是其可写的默认工作目录。

## 第 2 步：确定性造数

在宿主机写脚本、`docker cp` 进容器（比 `docker exec` 里贴 heredoc 更可复现）：

```bash
# [任意节点]
cat > gen_data.py <<'EOF'
# 造 100 万行倾斜数据：恰好 90 万行 hotkey，10 万行均摊到 word00..word09（每个 1 万行）
n = 1_000_000
with open("words.txt", "w") as f:
    for i in range(1, n + 1):
        if i % 10 != 0:
            f.write("hotkey\n")
        else:
            f.write("word%02d\n" % ((i // 10) % 10))
print("words.txt written:", n, "lines")
EOF

docker cp gen_data.py spark-lab:/opt/spark/work-dir/
docker exec -w /opt/spark/work-dir spark-lab python3 gen_data.py
# 预期: words.txt written: 1000000 lines

docker exec spark-lab wc -l /opt/spark/work-dir/words.txt
docker exec spark-lab grep -c '^hotkey$' /opt/spark/work-dir/words.txt
# 预期: 1000000
#       900000
```

为什么用取模而不是随机数：`i % 10 != 0` 的 90 万行写 `hotkey`；其余 10 万行里 `word00..word09` 各恰好 1 万行。分布对任何 Python 版本可复现——判分脚本才能断言 top1 恒为 900000。运维视角：造可复现的压测数据是容量评估（SRE 容量规划）的前提，"大约 90%" 的随机数据没法做回归对比。

## 第 3 步：词频统计 + 落盘

```bash
# [任意节点]
cat > lab.py <<'EOF'
import os
import time

from pyspark.sql import SparkSession, functions as F

spark = (
    SparkSession.builder.master("local[*]")
    .appName("bigdata-lab02")
    .config("spark.sql.shuffle.partitions", "4")
    .getOrCreate()
)
spark.sparkContext.setLogLevel("WARN")

df = spark.read.text("words.txt")
print("input rows:", df.count())

# 词频统计（同时充当预热 action：初始化、查询计划编译、codegen 都发生在这一轮）
warm = df.groupBy("value").count()
warm.collect()

# 完整词频落盘（单文件，按 count 降序）——"结果落本地文件"
(
    warm.orderBy(F.desc("count"))
    .coalesce(1)
    .write.mode("overwrite")
    .csv("output/wordcount-full")
)

# ---------- 倾斜实验 1：朴素 groupBy ----------
t0 = time.time()
naive = df.groupBy("value").count().collect()
naive_ms = int((time.time() - t0) * 1000)

# ---------- 倾斜实验 2：加盐两阶段聚合 ----------
# stage1: hotkey 被打散成 hotkey_0..hotkey_3 分散到不同 shuffle 分区
# stage2: 去掉盐值二次聚合，还原真实计数
t0 = time.time()
salted = (
    df.withColumn("salt", (F.rand() * 4).cast("int"))
    .groupBy(F.concat(F.col("value"), F.lit("_"), F.col("salt")).alias("skey"))
    .count()
    .groupBy(F.expr("substring(skey, 1, length(skey) - 2)").alias("value"))
    .agg(F.sum("count").alias("cnt"))
    .collect()
)
salted_ms = int((time.time() - t0) * 1000)

# 两种算法必须得到完全相同的词频（结果一致性断言，不一致直接抛错）
naive_map = {r.value: r["count"] for r in naive}
salted_map = {r.value: r.cnt for r in salted}
assert naive_map == salted_map, "FATAL: 两种聚合结果不一致"

os.makedirs("output", exist_ok=True)
top10 = sorted(naive_map.items(), key=lambda kv: (-kv[1], kv[0]))[:10]
with open("output/top10.txt", "w") as f:
    for w, c in top10:
        f.write("%s %d\n" % (w, c))
with open("output/timing.txt", "w") as f:
    f.write("naive_ms=%d\nsalted_ms=%d\n" % (naive_ms, salted_ms))

print("naive_ms=%d salted_ms=%d" % (naive_ms, salted_ms))
print("top1:", top10[0])
spark.stop()
EOF

docker cp lab.py spark-lab:/opt/spark/work-dir/
docker exec -w /opt/spark/work-dir spark-lab /opt/spark/bin/spark-submit lab.py
# 预期末尾输出（毫秒数随机器浮动）:
#   naive_ms=6900 salted_ms=5200
#   top1: ('hotkey', 900000)
```

代码里三处与运维直接相关的设计：

- **预热再计时**：首个 action 承担了 SparkSession 初始化与 codegen，不预热的话谁先跑谁吃亏，对比无效。生产上调优对比（如开 AQE 前后）同样要扔掉第一轮；
- **一致性断言**：`assert naive_map == salted_map`——任何"性能优化"先证结果等价，再谈耗时。这在改写 SQL/换执行引擎的变更窗口里是必做的回归校验；
- **盐值只参与第一阶段**：`F.rand()*4` 逐行取 0~3，`hotkey` 的 90 万行被切成 4 份分到不同分区；第二阶段用 `F.expr("substring(skey, 1, length(skey) - 2)")` 去掉 `_N` 后缀再合并。注意去盐**必须走 `F.expr`**：`F.substring` 的第三个参数（长度）只收字面 int，传 `F.length(col)-2` 这种 Column 会在提交时抛 `PySparkTypeError: Column is not iterable`（3.5 实测踩过）；`F.lit("_")` 拼接与去尾 `-2`（去掉 `_` 加一位数字）成对出现。

提交期间在浏览器开 `http://<VM-IP>:4040`（`[本地Windows]`）。

## 第 4 步：从 Spark UI 看 straggler 与 stage 变化

**朴素 groupBy（倾斜作业）**：进入 Jobs → 该 job → groupBy 那个 stage 的 Summary Metrics，会看到 4 个 task 里：

```text
task   duration   (示例)
#0     6.2 s      ← 90 万行 hotkey 全在这里（straggler）
#1     0.4 s
#2     0.4 s
#3     0.3 s
```

一长三短就是教科书式倾斜：stage 耗时 = 最慢 task 耗时，其余 3 个核在等它。放大到生产（10 亿行、200 分区、单 key 占 90%），straggler 会把 5 分钟的作业拖成 3 小时——正是场景里"3 小时跑不完"的成因。

**加盐两阶段**：DAG 里聚合从 1 个 shuffle stage 变成 2 个（stage1 按 `skey`、stage2 按 `value`）。每个 stage 内 4 个 task 耗时趋于均匀（热点已被切成 4 份），straggler 消失，代价是多一次 shuffle 的网络与序列化开销。

**结果怎么解读（诚实的部分）**：100 万行、单机 local 模式下，节省的 straggler 时间可能抵不过多一轮 shuffle 开销，`salted_ms` 不保证小于 `naive_ms`——数据量小时甚至可能更慢。这不是实验失败：本实验的可判分产物是"结果一致 + 两种计时都有"，而加盐的收益在**数据量大、并行度高、key 倾斜极端**时才单调显现。生产上的替代方案还有 AQE 自动倾斜处理（`spark.sql.adaptive.skewJoin.enabled`，Spark 3.x 默认开启，对 join 倾斜有效）与 broadcast join 绕开 shuffle，见 `16-bigdata/04-spark` 章。

## 第 5 步：验证产物

```bash
# [任意节点]
docker exec spark-lab bash -c '
cat /opt/spark/work-dir/output/top10.txt
cat /opt/spark/work-dir/output/timing.txt
ls /opt/spark/work-dir/output/wordcount-full/
'
# 预期:
#   hotkey 900000
#   word00 10000
#   word01 10000
#   ...（10 个 word* 各 10000，top10 恰好 11 选 10）
#   naive_ms=6900
#   salted_ms=5200
#   _SUCCESS  part-00-....csv
```

`top10.txt` 前 1 行是 hotkey、后 9 行是任意 9 个 word*（它们计数并列，排序取字典序在前者）——check.sh 只断言第一行精确等于 `hotkey 900000`，不约束并列项顺序。`_SUCCESS` 是 Spark 写出器的事务成功标志（与 Hive/HDFS 写路径一致的两阶段提交思路，`16-bigdata/03-hive-warehouse` 会再遇到）。

## 第 6 步：清理（check.sh 通过后再做）

```bash
# [任意节点]
docker rm -f spark-lab
rm -f gen_data.py lab.py
```

## 常见坑速查

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| spark-submit 报 Python worker 无法启动 | PATH 里 python3 缺失或 PYSPARK_PYTHON 未指向 | apache/spark 官方镜像自带 python3；自做镜像时设 `PYSPARK_PYTHON=python3` |
| 4040 打不开 | 应用已结束，UI 随之下线 | 提交期间刷新；或改用 `spark.ui.port` 常驻 history server（生产标配） |
| salted 反而更慢 | 数据量太小，多一轮 shuffle 的固定开销未摊薄 | 正常现象，见第 4 步解读；加大数据量（如 2000 万行）重跑 |
| assert 两种结果不一致 | 去盐逻辑写错（如 substring 长度算错把 key 截断） | 检查 `-2` 与 `_` + 单位盐值的对应关系 |
| 提交即抛 `PySparkTypeError: Column is not iterable` | 把 `F.length(col)-2` 这种 Column 传给了 `F.substring` 的长度参数 | 改用 `F.expr("substring(skey,1,length(skey)-2)")`，SQL 表达式里长度可以做算术 |
| driver OOM | 把超大 collect() 拉回 driver | 本 lab 仅 11 个 key 安全；生产上聚合结果也应落盘而非 collect |

## 附：check.sh 通过结果

```text
# [任意节点]
$ chmod +x check.sh && ./check.sh
PASS: 容器 spark-lab 处于 Running
PASS: words.txt 存在且为 1000000 行
PASS: output/top10.txt 存在
PASS: top1 为 hotkey 900000
PASS: output/timing.txt 存在
PASS: timing.txt 含 naive_ms=<整数>
PASS: timing.txt 含 salted_ms=<整数>
PASS: output/wordcount-full/_SUCCESS 存在（完整词频已落盘）

SCORE: 8/8
```

## 延伸阅读

- Spark Tuning Guide（数据倾斜与 AQE）：<https://spark.apache.org/docs/latest/tuning.html>
- Adaptive Query Execution（SQL 部分）：<https://spark.apache.org/docs/latest/sql-migration-guide.html#aqe>
- pyspark.sql API：<https://spark.apache.org/docs/latest/api/python/getting_started/quickstart_df.html>
