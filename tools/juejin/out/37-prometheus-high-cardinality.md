---
title_juejin: '一个 user_id 打爆 Prometheus'
title_zhihu: '一个 user_id label 乘出百万条时序：高基数是怎么把 Prometheus 打爆的'
description: '基数即时序条数，加 label 是乘法，乘到 OOM；断流留 5 分钟遗像；三刀：relabel_configs、metric_relabel_configs、recording rule。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686472562230312970"
---

# 一个 user_id label 乘出百万条时序：高基数是怎么把 Prometheus 打爆的

周一早上打开 Grafana，面板白屏。Prometheus 昨晚 OOM 重启了三次，每次重启都要先重放 WAL，告警断断续续——但业务方说，昨晚流量根本没涨。

翻上周 diff，凶手只有一行：有人给 http_requests_total 加了个 label，叫 user_id。这篇把这笔账从头算清：基数怎么乘出来的、TSDB 为什么怕、断流后那 5 分钟的错觉，以及三刀治理。

## 一、基数不是"数据量大"，是"时序条数"

Prometheus 的数据模型一句话讲完：一条时序 = 指标名 + 一组标签键值对，指标名本身只是个叫 __name__ 的特殊标签。

`http_requests_total{code="200", method="GET"}` 和 `http_requests_total{code="500", method="GET"}` 是两条不同的时序。样本只是某条时序在某时刻的 (时间戳, 值)。而基数就是时序的条数——**label 每多一种取值组合，时序就多一条**。

所以加 label 不是加法，是乘法。算一笔账：http_requests_total 原有 code 5 种取值、method 4 种、instance 10 台实例，5×4×10 = 200 条时序，规模可控。

加上 user_id、日活 10 万，理论上限 5×4×10×100000 = 两千万条；实际每个用户只碰少数组合，但 head 里同时挂着的时序也轻松到百万量级。

磁盘未必先爆——单条样本很小。真正先爆的是内存：每条时序都要在索引里挂号、都要占 head 的位置。**基数是笛卡尔积：加一个 label，其余所有维度跟着乘一轮。**

## 二、TSDB 为什么怕：索引住在内存里

先看写入路径。样本先到 head block（内存中的活跃块，2h 一个窗口），且每个样本先顺序追加写 WAL 再进内存；满的 chunk 数据落盘到 chunks_head/，**但索引仍在内存**；每 2h 截断一次，head 才变成磁盘上不可变的 block。

怕点就在最后半句：chunk 数据能落盘，索引不能。【从业者判断】这个索引是按 label 值组织的倒排索引，selector 能毫秒级锁定 `{code="500"}` 靠的就是它；代价是时序条数越多索引越大，而且常驻内存。基数翻十倍，索引体积跟着翻，head 的内存水位跟着涨。

落到症状，曲线大致是这样（【从业者判断】）：

```text
head series 台阶式上涨（每次发版/扩容跳一级）
  → Prometheus RSS 平滑爬升，没人配告警，没人发现
  → head series 破百万，抓取开始偶发超时
  → 重启越来越慢：WAL 要重放最近 2h 数据，重放期间 Web UI 不可用
  → 某天流量高峰 OOM；重启 → 重放 → 再 OOM，循环
```

三条自监控查询，建议直接贴进自己的大盘：

```promql
# 活跃时序数——内存压力的第一信号
prometheus_tsdb_head_series

# 每秒入库样本数
rate(prometheus_tsdb_head_samples_appended_total[5m])

# WAL 重放耗时（重启慢的元凶）
prometheus_tsdb_wal_replay_duration_seconds
```

**磁盘按 2h 块过日子，索引在内存里陪你熬夜。**记住这句，TSDB 的一切症状都能自己推出来。

## 三、重灾区名单：这些值一个都别放进 label

按危险程度排个名单（【从业者判断】）：

| label | 为什么致命 |
| --- | --- |
| user_id / session_id | 取值随用户数线性涨，没有上界 |
| request_id / trace_id | 每个请求一个新值，时序活一个抓取间隔就死 |
| 客户端 IP / Pod IP | Pod 每次重建都换 IP，等价于无限新时序 |
| 全量 path（/user/123/profile） | 路由参数没归一化，路径数等于数据行数 |
| pod_template_hash 等高变动 K8s label | 每次发版全体时序换一轮血 |

最后一行不是危言耸听：我的教学示例配置里就常备 `labeldrop pod_template_hash` 一行，注释写的正是"删掉高变动 label，降低基数"——入门配置就该默认防它。

判别法一句话：**看这个 label 的取值集合有没有上界。**method、code、region、namespace 是有界小集合，是维度；user_id、request_id 是无界集合，是毒药。无界维度想要细粒度，去日志和 trace 系统要，时序数据库不伺候。

## 四、staleness：断流不是消失，是 5 分钟的遗像

高基数的另一半账记在 staleness 头上。（本节均属【从业者判断】。）

Prometheus 处理"序列不再有新样本"分两种死法。第一种：同一个 target 这次抓取里少了个序列，Prometheus 写入 staleness 标记，instant 查询立刻不再返回它——干净的死法。

第二种是脏的死法：整个 target 断流（宕机、网络分区），没人能写标记，查询引擎按默认 5 分钟的回看窗口（lookback delta）找样本——评估时刻往前 5 分钟内的最后一个值，照常返回。

脏死法就是误导的来源。还原现场：一台实例 14:00 宕机，14:03 你在面板查 `http_requests_total`，它的最后读数还在——一条死了 3 分钟的 counter，挂着遗像。

更隐蔽的是 rate：只要 [5m] 窗口里还剩两个样本，rate 就还算得出值，死实例的"每秒请求数"继续画在图上，直到窗口滑空。

高基数与 staleness 还互相放大：user_id 这种高变动 label，意味着每分钟都在发生大规模"断流"——旧用户的序列不再更新，新用户的序列不断诞生。这些僵尸时序占着 head 的索引，要等下一次 2h 截断才让位。

**断流不是消失，是冻结 5 分钟的遗像。**排查"数据看起来还在"的怪象，先想到这条。

## 五、查询侧的症状：rate 巨慢、面板白屏

写入侧 OOM 之前，查询侧先疼。症状链（【从业者判断】）：一次 `rate(http_requests_total[5m])` 要先经索引找出全部匹配序列，再逐条定位窗口内数据。

序列从 200 条涨到百万条，这一步从毫秒变分钟；Grafana 一个面板几十条查询，条条超时——白屏的本质是查询超时，不是 Grafana 的锅。

排障清单里有一条直接对应："面板越来越慢——每个面板重复算大范围 rate——拆成 recording rules，面板只查预聚合序列"。

顺带纠正一个高基数下最常见的错法：`sum by (job) (http_requests_total)` 对 counter 的当前累计值求和，得到的是"所有实例从启动至今的总请求数"，毫无运营意义且随重启跳变。**counter 必须先进 rate 再聚合，顺序不可颠倒**——降维聚合的对象，永远是 rate 之后的值。

## 六、治理三刀：挡在三个不同的位置

三刀的时机与作用对象不同，先摆对照表：

| | relabel_configs | metric_relabel_configs | recording rule |
| --- | --- | --- | --- |
| 时机 | 抓取前 | 抓取后、入库前 | 周期评估 |
| 作用对象 | target | 样本 | 查询结果 |
| 省什么 | 整个目标的抓取流量与存储 | 存储与查询，不省抓取带宽 | 面板与告警的查询成本 |

第一刀 relabel_configs：不抓它。抓取前作用于 target，keep/drop 决定"抓不抓"。适合整类目标就不该进来的场景——调试 exporter、无关 namespace，连 HTTP 请求都不发生。

第二刀 metric_relabel_configs：抓回来，但不入库。抓取后、写 TSDB 前作用于每条时序，专治高基数 label：

```yaml
# prometheus.yml 片段：入库前拆掉高基数维度
scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_namespace]
        action: keep
        regex: monitoring|default        # 抓取前：只抓这两个 namespace 的 Pod
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: go_[a-z_]+                # 入库前：丢弃 go_* 运行时噪声
        action: drop
      - action: labeldrop
        regex: 'user_id|pod_template_hash'  # 入库前：删高基数 label，直接降维
```

两个边界要记牢：metric_relabel 省的是存储与查询，不省抓取带宽——HTTP 已经发生，`scrape_samples_scraped` 不会因此变小；`up` 也不受影响。想连被抓都不被抓，回第一刀。

第三刀 recording rule：把维度乘法在写入侧先算掉。面板和告警反复执行的同一段昂贵表达式，预计算成新序列：

```yaml
# rules/http.yml：按 job 预聚合，user_id 这类维度在 sum 里直接消失
groups:
  - name: http-rates
    interval: 30s
    rules:
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))
```

命名用官方惯例 `level:metric:operations`，冒号是保留分隔符。改完先校验：

```bash
# promtool 校验规则文件（docker 方式，无需本地装二进制）
docker run --rm -v "$PWD/http.yml":/rules/http.yml \
  prom/prometheus promtool check rules /rules/http.yml
# 预期：SUCCESS: 1 rules found
```

**第一刀管谁进门，第二刀管谁上桌，第三刀管端多大的菜。**高基数事故优先上第二刀（精准、影响面小），第三刀是所有热点查询的长期功课。

## 七、已经打爆了怎么办：delete_series 不是橡皮擦

事故进行时的第一反应往往是"把烂数据删了"。做不到，至少做不到你想要的粒度：

- retention 只能整块删——block 是删除的最小单位，"删最近 10 分钟的数据"这种粒度默认删不了
- 想删块内数据要用 admin API 的 delete series 写 tombstone，前提是 `--web.enable-admin-api`

而且【从业者判断】tombstone 只是把数据标记为不可见，磁盘与索引占用要等后续 compaction 才真正回收。所以"删掉高基数数据立刻降内存"不成立。真正有效的止血顺序（【从业者判断】）：

```text
1. metric_relabel_configs 拒新序列入库（先止血）
2. reload 配置，看 head series 增速归零（验证止血成功）
3. 旧序列等 2h 截断滚出 head、retention 滚出磁盘（等它痊愈）
```

**delete_series 是遮羞布，不是橡皮擦。**止血靠拒绝入库，痊愈靠时间窗口滚动。

## 八、反方说一句：维度正是 Prometheus 的价值

看到这里，可能有人想把所有 label 一刀全 drop。别。

把 code、method、region 打进 label，正是 PromQL 按维度切分的能力来源：`sum by (job) (rate(...))` 一秒切出全局面，`code=~"5.."` 一秒圈出错误——多维标签是 Prometheus 相对"只有一条全局总数"的老式监控的核心优势。

把 label 全删了，监控就退化成一条 TOTAL 曲线，出故障连二分定位都做不了。

该治的是失控的维度，不是维度本身。失控的判据两条（【从业者判断】）：取值无界；没有任何面板或告警按它切分。两个条件同时满足的 label 才是治理对象——**给维度做预算，而不是给维度判死刑。**

## 现在就能做的三件事

第一，看自己离悬崖多远：

```promql
# 活跃时序数与每秒入库样本数，贴进 Prometheus Web UI
prometheus_tsdb_head_series
rate(prometheus_tsdb_head_samples_appended_total[5m])
```

第二，找出基数 top 10 的指标（【从业者判断】，我最常用的审计查询）：

```promql
# 每个指标名各有多少条活跃时序，取前 10（本查询要扫全库索引，低峰期跑）
topk(10, count by (__name__)({__name__=~".+"}))
# 预期：排前面的应是 kube_/container_ 系；若业务指标进前 3，回第三节对名单
```

第三，审计 prometheus.yml 里每个 job 的 label，给高变动的补 labeldrop，改完先校验再 reload：

```bash
# promtool 校验主配置
docker run --rm -v "$PWD/prometheus.yml":/etc/prometheus/prometheus.yml \
  prom/prometheus promtool check config /etc/prometheus/prometheus.yml
# 预期：SUCCESS 之后再 reload 生效
```

这套东西的底稿（relabel 时机对照、TSDB 生命周期、recording rule 命名惯例、60 道 PromQL 梯度题）在我的学习仓库：GitHub 搜 sre-learning-hub。

最后一个问题，评论区报个数：你生产环境的 prometheus_tsdb_head_series 是多少？老集群和新集群差着两三个数量级——看看你在哪个档位，离 OOM 的台阶还有几级。
