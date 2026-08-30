# Lab 02 · Spark local 模式：词频统计与数据倾斜加盐实验

> 难度：★★☆ ｜ 考点：16-bigdata/04-spark（shuffle/聚合倾斜/两阶段聚合） ｜ 前置：16-bigdata/labs/01；12-data-streaming/flink 的反压实验（同一现象的批处理版） ｜ 预计 45~60 分钟

## 场景

上游日志分析平台反馈"一批 3 小时才跑完的 groupBy 统计作业"。你拿到一份 100 万行的单词数据（其中 90% 的行是同一个热点 key），要在单容器 Spark local 模式下复现两个问题并给出量化对比：

1. 常规词频统计能否得到正确 top N；
2. 同一份热点数据上，朴素 `groupBy().count()` 与"加盐两阶段聚合"的耗时差异，以及从 Spark UI 上怎么看出 straggler（拖后腿任务）。

这和 `12-data-streaming/flink/labs/01` 里 Flink 的热点 key 反压实验是**同一个物理规律的两个投影**：数据按 key 哈希后倾斜到同一个任务，批处理里表现为 straggler task，流处理里表现为反压。YARN/K8s 上部署 Spark 的部分见 `16-bigdata/02-yarn` 与 `04-spark` 章，本 lab 专注计算语义本身。

```
                输入 words.txt (100 万行, 90% 是 hotkey)
                         │  按 key 哈希分发 (shuffle)
         ┌───────────────┼───────────────┐
   partition 0     partition 1      partition 2 ...
   hotkey×90万行    其余 key 分散      几乎空闲
   ↑ straggler: 最慢任务决定整个 stage 耗时

   加盐两阶段: stage1 按 (key+盐值) 分散聚合 → stage2 去盐合并 → straggler 消失
```

## 任务清单

1. 启动容器 `spark-lab`（镜像 `apache/spark:3.5.1`，内存限 4G，映射 4040 端口），确认容器内 `python3` 与 `/opt/spark/bin/spark-submit` 可用。
2. 在容器 `/opt/spark/work-dir` 生成确定性数据 `words.txt`：100 万行，其中**恰好** 90 万行是 `hotkey`，其余 10 万行均匀分布到 10 个 `word*` key——不许用随机数（保证 top1 计数可判分）。
3. 编写并提交 `lab.py`（pyspark，`master=local[*]`，`spark.sql.shuffle.partitions=4`）：词频统计并把完整结果落盘到 `output/wordcount-full/`、top10 写入 `output/top10.txt`。
4. 倾斜实验（同一脚本内完成，计时写 `output/timing.txt`）：先跑一次预热不计分，然后分别对朴素 `groupBy("value").count()` 与加盐两阶段聚合（盐值 0~3 拼进 key，第二阶段去盐求和）计时，并以断言证明两种算法结果完全一致。
5. 提交期间打开 Spark UI（`http://<VM-IP>:4040`），找到倾斜作业里耗时显著高于同 stage 其他 task 的那个 straggler，记录其耗时与数据 locality；对比加盐后 stage 数量变化（1 个聚合 stage 变 2 个）。
6. 清理（跑完 check.sh 之后）：删除容器。

## 验收标准

- `docker ps` 能看到 `spark-lab` Running；
- 容器内 `wc -l /opt/spark/work-dir/words.txt` 为 1000000；
- `output/top10.txt` 第一行为 `hotkey 900000`；
- `output/timing.txt` 含 `naive_ms=<整数>` 与 `salted_ms=<整数>` 两行；`output/wordcount-full/_SUCCESS` 存在。

运行判分脚本：

```bash
# [任意节点]
cd 16-bigdata/labs/02-spark-local
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：为什么要造"确定性"的 90% 倾斜</summary>

判分脚本要求 top1 计数精确等于 900000。用 `random` 造数据即使固定种子，换 Python 版本结果也可能漂移。用取模构造：`i % 10 != 0` 时写 `hotkey`，否则写 `word%d % (i % 100)`——100 万行里恰好 90 万个 hotkey，其余 10 个 key 各 1 万行，任何环境下可复现。

</details>

<details><summary>提示 2：shuffle partitions 为什么设成 4</summary>

默认 200 个 shuffle 分区会把 100 万行摊得极碎，每个 task 只有毫秒级，straggler 现象反而看不出来。设成 4（与实验盐值个数一致）后热点 key 所在分区与其余分区差距明显，Spark UI 的 task 时间条一长三短，肉眼可见。生产上这是"分区数与数据量匹配"的同一个调优问题。

</details>

<details><summary>提示 3：加盐的盐值加在哪个 key 上</summary>

盐值要与原 key 拼接参与第一阶段聚合（`hotkey` 变成 `hotkey_0..hotkey_3` 四个 key 分散到不同分区），第二阶段再按**原 key** 二次聚合求和。常见错误是给所有行统一加一个固定前缀——那不改变哈希分布，等于没加。另注意 `F.rand()` 是按行随机的非确定函数，正好用作盐。

</details>

<details><summary>提示 4：第一次跑为什么特别慢</summary>

首个 action 要初始化 SparkSession、编译查询计划（codegen），不能代表算法差异。所以脚本先做一次**不计时的预热** action，再分别计时；对比实验里两种算法也都要重扫同一份输入（都不 cache），保证公平。

</details>

<details><summary>提示 5：Spark UI 打不开 4040</summary>

UI 只在应用运行期间存在，作业结束就下线。`-p 4040:4040` 已映射，提交脚本时同步在浏览器开 `http://<VM-IP>:4040` 刷新即可；跑完了可以 `docker exec spark-lab bash -c "cat /opt/spark/work-dir/output/timing.txt"` 先看数值结论，再用更大数据量重跑观察 UI。

</details>
