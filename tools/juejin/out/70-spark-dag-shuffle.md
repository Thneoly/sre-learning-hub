---
title_juejin: 'Spark 比 MR 快在哪？管住最贵的 shuffle'
title_zhihu: 'Spark 快过 MapReduce 的真相：不是内存计算四个字，是少落了几次盘'
description: 'explain 三行读法（Exchange/Broadcast/partial）、宽窄依赖切 stage、统一内存模型与堆外 OOM 真相、数据倾斜三板斧：加盐、广播、两阶段聚合。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686341072617242662"
---

# Spark 比 MapReduce 快在哪：DAG、宽窄依赖，和那条最贵的 shuffle

「Spark 为什么比 MapReduce 快？」面试标准答案四个字：内存计算。

这个答案只对了一半：Spark 的 stage 边界照样写盘，shuffle 溢写起来满磁盘飞；倾斜的 task 照样跑几十分钟，两百个 task 给一个热点 key 陪跑。

真正的差别在三处：DAG 把一串算子编译进同一个 task、宽窄依赖决定哪里必须落盘、那条最贵的 shuffle 到底贵在哪。

## 一、架构先摆正：大脑、中介、干活的

Driver 是大脑，不是干活的：把用户代码反向解析成 DAG、切 stage、生成 taskset 发给 executor，顺带起 4040 的 Web UI。注意 `collect()` 会把数据拉回 Driver——**Driver OOM 常常是业务代码往 driver 收了太多数据**。

ClusterManager 只回答两个问题：「还有资源吗」和「容器挂了通知你」。它不认识 RDD，换 master 只是换中介——**同一份代码能跑 local、YARN、K8s，根子在这**。

Executor 是常驻 JVM：`--executor-cores` 决定同时跑几个 task 线程，task 复用 JVM，省掉 MapReduce 每任务起一个 JVM 的开销。

## 二、lazy 求值与 explain：先看计划，再动手

transformation（map/filter/groupBy）只累积 DAG 不执行，action（count、write、collect）才触发。lazy 是为了全局优化：Catalyst 看到整条 SQL，才能做谓词下推、列裁剪、join 策略、whole-stage codegen。

动手前先 explain（Hive 数仓场景，orders 带 dt 分区）：

```python
# 读三行：Exchange、Broadcast、partial
spark.sql("""
  SELECT city_id, sum(amount) FROM orders WHERE dt='2026-08-29' GROUP BY city_id
""").explain("formatted")
```

```text
== Physical Plan ==
* HashAggregate(keys=[city_id], functions=[sum(amount)])          ← 最终聚合
+- Exchange hashpartitioning(city_id, 200)                        ← shuffle 边界=stage 边界
   +- * HashAggregate(keys=[city_id], functions=[partial_sum(amount)])  ← map 端预聚合
      +- * Project [city_id, amount]
         +- * Filter (dt = 2026-08-29)
            +- * Scan ORC ... PushedFilters: [EqualTo(dt,...)]    ← 谓词下推到读取器
```

三行读法：

- `Exchange` 出现一次就是一次 shuffle，**数 Exchange 的个数，就是在数账单**；
- join 前的 `BroadcastExchange`：小表将广播，shuffle 绕过（板斧三）；
- `partial_` 前缀是 map 端预聚合，两阶段聚合的自动版。

## 三、宽窄依赖：stage 在哪切，盘就在哪落

**窄依赖**：分区一对一（map、filter），同一个 task 里 pipeline 连续执行，算子间不落盘。**宽依赖**（shuffle）：分区一对多（groupByKey、join、窗口），下游要「凑齐」上游各分区里属于自己的那份，必须切 stage 边界。

心法：问「这个算子需要别的分区的数据流进来吗」——需要就是宽依赖，stage 在这里切一刀。

**窄依赖是内存里的流水线，宽依赖是磁盘上的收费站。**收费站内部（sort-based shuffle）：

```text
map 端：按分区号写内存缓冲 → 满 → 排序溢写为 spill 文件（spark.local.dir，磁盘！）
        → task 结束 merge，产出数据 + index（记各 reduce 分区偏移）
reduce 端：按 index 精确拉取自己分区那段 → 边拉边聚合
```

正面回答标题。MapReduce 里 map 输出落盘、reduce 输出落 HDFS，作业串联就是一轮轮完整落盘【从业者判断】；Spark 把一串窄依赖编译进同一个 task 流水执行，只在宽依赖边界落一次盘，还是本地盘加 index 精确拉取，不走 HDFS 往返。

「内存计算」的准确说法是：**落盘从每作业一次，降到每宽依赖一次**；数量级提速只在多步迭代场景兑现【从业者判断】。

排障两个落点：

1. Stage 页 Spill 列大量溢写 = 执行内存不够，task 反复「排序-写盘-再读盘」，spill 到 GB 级慢 10 倍很正常；
2. `spark.sql.shuffle.partitions`（默认 200）：100GB 只给 200 分区必然溢写，小数据给 2000 分区纯浪费调度开销。

## 四、统一内存模型：OOM 为什么常在堆外

YARN/K8s 分给一个 executor 的容器内存，是堆加堆外两笔账：

```text
容器总内存 = spark.executor.memory（JVM 堆，-Xmx）
           + memoryOverhead（堆外，默认 max(executor.memory×0.10, 384MB)）
```

堆内三块：Reserved 固定 300MB；User Memory 装用户对象和 UDF，没人管；Unified Memory（可用 ×0.6）再分 Execution（shuffle 缓冲、排序、聚合）和 Storage（cache）。

「统一」体现在动态借用，且不对称：Execution 缺内存可抢占 Storage 借走的部分，被借走的缓存块强制落盘逐出——task 不能等；反向只能借对方空闲的部分，一需要立刻归还。UDF 塞大 dict 的堆内 OOM，就出在没人管的 User Memory。

真相时间。**YARN 和 K8s 杀容器看的是进程 RSS，不是 -Xmx**。RSS = 堆 + metaspace + 线程栈 + netty 直接内存 + malloc 碎片。

shuffle 拉取量大时 netty 直接内存先膨胀，堆明明有富余，RSS 已顶到容器上限：YARN 报 `Container killed by YARN for exceeding memory limits`，K8s 是 `OOMKilled, Exit 137`。

处置是调 `spark.executor.memoryOverhead`，不是加大 -Xmx——堆变大反而挤压堆外。生产三件套：

```bash
# [任意节点] 堆 8g、堆外 2g、G1GC
--executor-memory 8g --executor-cores 4 \
--conf spark.executor.memoryOverhead=2g \
--conf spark.executor.defaultJavaOptions=-XX:+UseG1GC
```

## 五、数据倾斜三板斧：先复现，再动手

某个 stage 绝大多数 task 秒级完成、少数跑几十分钟，Spill 和 GC 飙高，即可判定倾斜。**倾斜不是慢，是并行度的谎言。**先 explain 确认在哪个 Exchange。构造典型案例（city_id=0 占 10% 流量）：

```bash
# [任意节点] local 模式 pyspark，UI 挂 4040
docker run -it -p 4040:4040 apache/spark-py:3.5.1 \
  /opt/spark/bin/pyspark --master "local[2]"
```

```python
# [容器内 pyspark] 构造典型案例：10% 的行 city_id=0，其余摊到 2000 个 key
from pyspark.sql import functions as F

orders = (spark.range(0, 10_000_000)
    .withColumn("city_id", F.when(F.col("id") % 10 == 0, F.lit(0))
                          .otherwise(F.col("id") % 2000))
    .withColumn("amount", (F.rand() * 100)))

# 跑完去 4040 的 Jobs → 最新 Stage 看 Summary Metrics
orders.groupBy("city_id").agg(F.sum("amount").alias("total")).count()
# 预期：median 与 max 差约一个数量级，0 号 key 所在 task 明显长尾
```

**板斧一：加盐打散（join 倾斜）。**大表加随机前缀，小表复制 N 份补齐前缀，join 后去掉；代价是小表膨胀 N 倍，只对小表用：

```python
# [容器内 pyspark]
N = 16
big   = orders.withColumn("salt", (F.rand() * N).cast("int"))
small = (spark.createDataFrame([(i, f"city-{i}") for i in range(2000)], ["city_id", "name"])
         .withColumn("salt", F.explode(F.sequence(F.lit(0), F.lit(N - 1)))))
big.join(small, ["city_id", "salt"]).count()
```

**板斧二：两阶段聚合（聚合倾斜）。**先按 (key, salt) 局部聚合压扁，再去 salt 全局聚合；`partial_sum` 只压行数不压体积，单 key 特别大仍要先加盐：

```python
# [容器内 pyspark]
N = 16
(orders.withColumn("salt", (F.rand() * N).cast("int"))
       .groupBy("city_id", "salt")
       .agg(F.sum("amount").alias("s1"))       # 第一阶段：局部聚合
       .groupBy("city_id")
       .agg(F.sum("s1").alias("total"))        # 第二阶段：全局聚合
       .count())
```

**板斧三：broadcast 小表绕过 shuffle。**小维表（默认 < `spark.sql.autoBroadcastJoinThreshold` = 10MB）广播到所有 executor，大表完全不动，没有任何 Exchange。

反噬：「小表」其实有 300MB 时，广播会同时顶爆 Driver 和每个 Executor，比 shuffle 还危险：

```python
# [容器内 pyspark]
cities = spark.createDataFrame([(i, f"city-{i}") for i in range(2000)], ["city_id", "name"])
orders.join(F.broadcast(cities), "city_id").count()
# explain 对比：聚合版有 Exchange，这版只有 BroadcastHashJoin
```

选型口诀：小表能装下用 broadcast；聚合倾斜用两阶段；join 倾斜且小表可膨胀用加盐。「Spark 3.5 的 AQE 不是默认开了吗，还手工什么？」——skewJoin 只自动拆 sort-merge / shuffled hash join 这类 shuffle join 的倾斜分区，聚合倾斜它不认，照样得手工两阶段。

「假倾斜」另论：null/空串 key 堆积，`WHERE key IS NOT NULL` 拆出去单独处理，别上三板斧。

## 六、一张表带走，外加 Flink 一句

| 维度 | MapReduce | Spark |
|---|---|---|
| 执行模型 | 每任务起一个 JVM | 常驻 Executor，task 线程复用 |
| 算子编排 | 固定 Map→Reduce，作业间串联【从业者判断】 | DAG 任意编排，窄依赖 pipeline |
| 中间结果 | map 输出落盘、reduce 输出落 HDFS【从业者判断】 | 只在宽依赖边界落本地盘 |

一句话总结：**Spark 没有消灭落盘，只是把落盘降到每宽依赖一次**——管住 shuffle 边界，就管住了成本的大头。

Flink 只留一句：它常驻、状态持续增长、资源钉死 slot；Spark 批无状态、分区幂等、动态分配潮汐伸缩——流批的深水区，这里不展开。

## 七、现在就能做的一件事

动手：先跑第五节的倾斜版，在 4040 看 max 与 median 差一个数量级；再跑两阶段或 broadcast 版看收敛；最后 `explain("formatted")` 指出哪行是 shuffle 边界——能指出来，就值回票价。

你们最近一次数据倾斜，最后是 AQE 自动救的，还是手工加盐救的？评论区说出你的故事。

整理自我维护的 SRE 学习仓库，GitHub 搜 sre-learning-hub——Spark 章在大数据模块，内存公式推导、动态资源分配与 external shuffle service 都在那一章。点个收藏，更新不迷路。
