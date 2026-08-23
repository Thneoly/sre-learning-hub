# 03 · PromQL 指南：数据模型、函数辨析与 histogram 数学

> 模块：PCA 备考 ｜ 建议时长：8 小时（本模块最重要的一篇） ｜ 关联认证：PCA-PromQL（28%）

## 学习目标

- 能用"时序 = 指标名 + 标签集"解释基数、selector 匹配与聚合后标签的变化
- 能区分四种值类型，并判断给定表达式是否合法（类型检查题是常客）
- 能从外推与 counter reset 的角度说清 rate/irate/increase 的差异，以及"窗口至少 4 倍抓取间隔"的由来
- 能手算 histogram_quantile 的插值结果，并避开它的三大典型错误
- 能写出子查询，并按官方惯例命名 recording rules

## 1. 数据模型：一切从"时序"开始

一条时序（time series）= **指标名 + 一组标签的键值对**。指标名其实只是一个特殊标签 `__name__`，因此：

```
http_requests_total{code="200", method="GET"}   ← 一条时序
http_requests_total{code="500", method="GET"}   ← 另一条时序（标签集不同）
```

- **sample（样本）**：某条时序在某个时刻的值，即 `(timestamp: ms, value: float64)`。PromQL 里没有"字符串值"、没有 null
- **同一时序的样本按时间排序存储**，所有函数本质上是对样本序列做计算
- 基数即"时序条数"（01 文件 3 节），label 每多一种取值组合，时序就多一条

## 2. 四种值类型

任何 PromQL 表达式求值后必为下列四种之一，**类型题几乎每年都考**：

| 类型 | 含义 | 例子 | 能出现在哪 |
| --- | --- | --- | --- |
| instant vector | 每条时序各一个样本（同一时刻） | `up`、`rate(x[5m])` | 画图、告警、二元运算 |
| range vector | 每条时序一段时间的多个样本 | `x[5m]` | **只能作为函数入参**，不能直接画图 |
| scalar | 一个裸数字 | `2 * 3`、`scalar(sum(x))` | 运算中间量 |
| string | 一个裸字符串 | `"hello"`（几乎只出现在 count_values 参数等处） | 极少 |

两条铁律：

1. `[5m]` 之类的 range selector 一出现，就是 range vector；它**必须**交给 rate/irate/increase/xxx_over_time/changes/holt_winters 等函数消化
2. 告警与画图需要 instant vector（或 scalar）；把 range vector 直接放表达式末尾会报错 `expected type instant vector, got range vector`

```promql
# [Prometheus Web UI] 类型错误的典型样例（会报错，感受一下）
rate(http_requests_total)
# 报错: expected type range vector, got instant vector
http_requests_total[5m]
# 报错（作为表达式末尾时）: expected type instant vector, got range vector
```

## 3. selector：选中哪些时序

### 3.1 四种标签匹配符

| 匹配符 | 语义 | 例子 |
| --- | --- | --- |
| `=` | 精确相等 | `job="node"` |
| `!=` | 不等 | `job!="node"` |
| `=~` | 正则匹配（**全锚定**） | `code=~"5.."` |
| `!~` | 正则不匹配 | `code!~"2.."` |

正则全锚定意味着 `code=~"5"` 等价于 `^5$`，只匹配字面 "5"；想匹配 5xx 必须写 `5..` 或 `5.*`。这是选择题最爱的坑。

其他规则：

- selector 必须至少含一个**能排除空串的 matcher**：`{}` 或 `{job=~".*"}` 非法，报错 `vector selector must contain at least one non-empty matcher`
- 多个 matcher 之间是**与**关系：`{job="a", code=~"5.."}` 同时满足
- 单下划线开头的 `__name__` 可作 matcher：`{__name__=~"kube_pod_.*"}`（比写一长串指标名干净）

### 3.2 range selector 的边界行为

`x[5m]` 取"当前时刻往前 5 分钟"内的样本，**区间对齐到查询时刻而非抓取时刻**：左边界恰好的样本是否包含与其落点有关，因此窗口内的样本数会随评估时刻浮动（5 分钟窗口、15s 抓取间隔时为 19~21 个）。这不是 bug，是理解 rate 外推的前提。

## 4. offset 与 @：操作时间

```promql
# [Prometheus Web UI] offset：整体往回平移（昨天同一时刻的 5 分钟速率）
rate(http_requests_total[5m] offset 1d)

# [Prometheus Web UI] @：钉死到某个绝对 Unix 时间戳（Prometheus 2.25+）
http_requests_total @ 1700000000

# [Prometheus Web UI] range selector 也能钉
http_requests_total[5m] @ 1700000000

# [Prometheus Web UI] @ start() / @ end()：锚定查询窗口首尾（2.28+）
max_over_time(up[1h] @ end())
```

- `offset` 平移"看哪个时刻"，`@` 指定"就看这一时刻"，二者可并用（先 offset 后 @ 的位置规则以官方文档为准）
- 典型用途：同比/环比、在 recording rule 里引用窗口边界

## 5. 聚合与标签处理

### 5.1 by / without

聚合算子（sum、avg、min、max、count、stddev、stdvar、topk、bottomk、quantile、group、count_values，2.42+ 另有 limitk/limit_ratio）把多条时序压成一条，**结果一定丢掉 `__name__`**，其他标签去留由 by/without 决定：

| 子句 | 语义 | 例子 |
| --- | --- | --- |
| `by (a, b)` | 只保留列出的标签 | `sum by (job) (rate(x[5m]))` 结果只有 job |
| `without (a, b)` | 移除列出的、保留其余 | `sum without (instance) (...)` 保留 job 等 |

记法：**by 白名单，without 黑名单**。不写则保留全部（除 __name__）。

```promql
# [Prometheus Web UI] 每个 job 的每秒请求数
sum by (job) (rate(http_requests_total[5m]))

# [Prometheus Web UI] 排除 instance 维度后求错误率
sum without (instance) (rate(http_requests_total{code=~"5.."}[5m]))
  / sum without (instance) (rate(http_requests_total[5m]))
```

topk/bottomk 不做合并，只挑选：`topk(5, sum by (job) (rate(http_requests_total[5m])))` 是"聚合后再选前 5"，写反成 `sum by (job) (topk(5, rate(...)))` 语义完全不同（每个时序维度内选前 5 再求和）——括号顺序即计算顺序。

### 5.2 二元运算与 vector matching

两个 instant vector 做算术/比较时，Prometheus 按标签集配对：

- 默认要求两边标签集**完全一致**（不含 __name__）
- `on (l1, l2)`：只按列出的标签配对；`ignoring (l1, l2)`：忽略列出的标签配对
- 一对一不够时用 `group_left` / `group_right` 声明多对一（"多"的一侧带 group_left）

```promql
# [Prometheus Web UI] 经典 group_left：左边按 method+code 多条，右边按 method 一条
# 左：method_code:http_errors:rate5m   右：method:http_requests:rate5m
method_code:http_errors:rate5m
  / ignoring(code) group_left
method:http_requests:rate5m
```

```promql
# [Prometheus Web UI] 常用形态：按 path 分别求错误率（两边 by 相同标签，天然对齐）
sum by (path) (rate(http_requests_total{code=~"5.."}[5m]))
  / sum by (path) (rate(http_requests_total[5m]))
```

配不上对的样本直接丢弃（不报错），"除法结果少了几个序列"多半是这个原因。

## 6. rate vs irate vs increase：深度辨析（必考）

### 6.1 共同的前提：counter

三者只用于 **counter**（只增、重启归零）。核心算法都是：取窗口内**首、尾两个样本**，若中途出现减少（重启归零），按"假设归零前一刻的值就是减少量"补偿。gauge 用它们没有意义，该用 `xxx_over_time` 家族。

### 6.2 三者对照

| | rate(v[d]) | irate(v[d]) | increase(v[d]) |
| --- | --- | --- | --- |
| 语义 | 窗口内**平均每秒**增量 | 最后**两个样本**的瞬时每秒增量 | 窗口内**总增量**（估算） |
| 用哪些样本 | 窗口内全部（首尾定斜率） | 只用最后两个 | 同 rate |
| 曲线形态 | 平滑 | 尖锐、抖 | 平滑、与 rate 同形 |
| 适用 | 告警、面板默认选择 | 抓瞬时尖峰、抓取间隔很短 | "5 分钟内多了多少次" |
| 慢抓取/稀疏数据 | 稳 | 差（两点间距大，误读） | 稳 |

### 6.3 外推：increase 为什么不是整数

counter 是整数，但 `increase(http_requests_total[5m])` 常返回 `8.66` 之类的小数。原因是**外推（extrapolation）**：

```
窗口 [T-5m, T] 内样本落在 t0..tn，首尾只覆盖了 [t0, tn] < 窗口
rate = (末值-首值+reset补偿) / (tn - t0)          ← 样本区间的斜率
然后假设斜率在窗口内不变，把结果线性外推到窗口两端
（外推量有上限：不超过平均抓取间隔的 1.1 倍，防止跑飞）
increase = rate × 窗口秒数
```

所以 increase 是"假设匀速"下的**估计值**，不是窗口内样本差值的精确计数。考题问"increase 会返回非整数吗"——会，且这是设计行为。

### 6.4 为什么窗口要覆盖至少 4 个样本

rate 最少需要 2 个样本，但**窗口 ≥ 4 × 抓取间隔**是官方告警实践给出的经验下限，三个理由：

1. 3.2 节说过窗口边界与抓取落点不对齐：窗口太短时（如 15s 间隔配 30s 窗口），边界切割可能让实际落入的样本低到 1 个，rate 直接无值（曲线断点）
2. 单次抓取失败（目标短暂 503）会把短窗口内的样本数砍半，rate 抖动剧烈；有 4 个以上样本时丢 1 个影响有限
3. for 告警依赖连续为真，rate 频繁断点会让告警"起不来"

推论：**抓取间隔 15s 时，rate 窗口至少 1m，推荐 5m**。窗口越长越平滑但对突变越迟钝，这是你要做的权衡，而不是对错。

## 7. histogram 与 summary：数学原理

### 7.1 histogram：桶是累计的

histogram 把每次观测（通常耗时/大小）落进**预定义边界**的桶，导出的序列：

```
request_latency_seconds_bucket{le="0.1"}  12    ← ≤0.1s 的观测累计 12 次
request_latency_seconds_bucket{le="0.25"} 30    ← ≤0.25s 的 30 次（含上面的 12）
request_latency_seconds_bucket{le="0.5"}  45
request_latency_seconds_bucket{le="1"}    49
request_latency_seconds_bucket{le="+Inf"} 50    ← 恒等于 _count
request_latency_seconds_sum              18.7  ← 所有观测值之和
request_latency_seconds_count            50
```

三个要点：桶是**累计（cumulative）**而非区间计数；`+Inf` 桶 = `_count`；`_sum/_count` 给算术平均。桶边界在**埋点时**固定，分位数在**查询时**计算——因此可以把多实例的桶相加后重算整体分位数（可聚合）。

### 7.2 histogram_quantile 的插值：手算一遍

`histogram_quantile(φ, bucket向量)` 在桶内做线性插值。以上面的数据求 P90：

```
目标位次 = φ × total = 0.9 × 50 = 45
找桶：cum(0.1)=12，cum(0.25)=30，cum(0.5)=45 → 30 < 45 ≤ 45，落在 (0.25, 0.5] 桶
插值：q = 0.25 + (45-30)/(45-30) × (0.5-0.25) = 0.5
```

通用公式：`q = le_prev + (目标位次 - cum_prev)/(cum_cur - cum_prev) × (le_cur - le_prev)`。

两个直接推论：

- **分位数是估算**：误差上界 = 所在桶的宽度。桶越宽，估得越糙
- 若目标位次超过最后一个**有限**桶（落进 +Inf 桶），只能按最后一个有限桶的斜率外推，基本不可信——桶边界没把你的分位数包住

### 7.3 summary：分位数在客户端算好

summary 由客户端库直接算分位数并导出：

```
request_duration_seconds{quantile="0.99"}  0.21
request_duration_seconds_sum               ...
request_duration_seconds_count             ...
```

- 分位数在**埋点时**由客户端在滑动窗口内计算并固定，查询侧只是读数
- **不可聚合**：3 个实例各自的 P99 无法合成服务整体 P99（分位数没有"平均"运算，avg(P99_a, P99_b) 在数学上是错的）
- 换分位数（想加个 P95）要改代码重新部署

### 7.4 选型表

| | histogram | summary |
| --- | --- | --- |
| 分位数在哪算 | 服务端（PromQL） | 客户端 |
| 跨实例聚合 | 支持（sum by (le) 后再算） | 不支持 |
| 桶/分位数可变性 | 查询时任选 φ | 埋点时定死 |
| 服务端成本 | 序列多（桶数×维度） | 序列少 |
| 平均值 | _sum/_count | _sum/_count |
| Apdex | 可 | 难 |

默认选 histogram（可聚合是压倒性优势），summary 用于不能接受桶开销、且只在单实例维度看分位数的场景。

### 7.5 histogram_quantile 的三大常见错误

**错误一：聚合时丢了 le。** `le` 是桶的身份证，任何聚合必须把它留在 by 里：

```promql
# [Prometheus Web UI] 错：sum 后 le 没了，直接报错或结果无意义
histogram_quantile(0.9, sum by (instance) (rate(x_bucket[5m])))

# [Prometheus Web UI] 对：先 sum by (le, ...)（保留需要的分组维度 + le）
histogram_quantile(0.9, sum by (le, job) (rate(x_bucket[5m])))
```

正确顺序是**先聚合桶、后取分位数**。跳过聚合则得到"每个实例各自的 P90"，再在面板上求平均是二次犯错。

**错误二：用错指标。** 对 `_sum`/`_count`、对 summary 的 `quantile="0.99"` 序列调 histogram_quantile 都是类型错配。求平均用 `_sum/_count`，summary 分位数直接读数、绝不聚合：

```promql
# [Prometheus Web UI] 平均延迟（histogram 与 summary 都支持）
rate(x_sum[5m]) / rate(x_count[5m])
```

**错误三：高估精度与桶设计失误。** 把插值结果当精确值（误差可达一个桶宽）；桶边界没有覆盖关心的分位数（P99 落在 +Inf 桶或 1s~10s 的巨桶里）。埋点时应让目标分位数附近有**窄桶**（如 0.9/0.95/0.99 附近各有一档边界）。

## 8. 子查询

想对"一个函数的结果"再做时间维度的函数（比如 rate 之后再取 1 小时最大值），需要子查询：

```promql
# [Prometheus Web UI] 语法：<instant 查询>[<range>:<step>]，step 省略则用全局评估间隔
max_over_time(rate(http_requests_total[5m])[1h:1m])

# [Prometheus Web UI] 求过去 1h 内每节点最低的内存可用比例（表达式要加括号）
min_over_time(
  (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes)[1h:]
)
```

- 方括号里是**冒号**分隔的 `range:step`，与 range selector 的 `[5m]` 一眼可辨
- step 是子查询的求值步长，越小越准越贵
- 典型用途：对 rate/max/min 的结果再做 over_time 统计、在 recording rule 中引用历史

## 9. recording rules：把贵查询算一次

面板和告警反复执行的同一段昂贵表达式，应预计算成新序列。规则文件格式：

```yaml
# [master] /etc/prometheus/rules/http.yml（promtool check rules 校验通过的形式）
groups:
  - name: http-rates
    interval: 30s                     # 组内规则多久评估一次
    rules:
      - record: job:http_requests:rate5m
        expr: sum by (job) (rate(http_requests_total[5m]))
      - record: job:http_errors:rate5m
        expr: sum by (job) (rate(http_requests_total{code=~"5.."}[5m]))
      - record: job:http_error_ratio:rate5m
        expr: job:http_errors:rate5m / job:http_requests:rate5m
```

```bash
# [master] 用 promtool 校验规则文件（docker 方式，无需本地装二进制）
docker run --rm -v "$PWD/http.yml":/rules/http.yml prom/prometheus promtool check rules /rules/http.yml
```

在 kube-prometheus-stack 里用 PrometheusRule CRD 提交（注意 `release` 标签，operator 靠它选规则；放 monitoring namespace）：

```yaml
# [master] kubectl apply -f prometheus-rule.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: http-rates
  namespace: monitoring
  labels:
    release: prom-stack
spec:
  groups:
    - name: http-rates
      interval: 30s
      rules:
        - record: job:http_requests:rate5m
          expr: sum by (job) (rate(http_requests_total[5m]))
```

**官方命名惯例：`level:metric:operations`**，冒号是保留分隔符（指标名里不许随便用冒号）：

- `job:http_requests:rate5m` —— level=job，指标 http_requests，操作 rate5m
- `instance_path:requests:rate5m`、`path:requests:rate5m`（上层聚合掉 instance）
- 惯例还包括：同一指标各层级用**相同的 by 标签集合**，让上层规则直接引用下层序列

## 实战演练：梯度练习十题

环境：kube-prometheus-stack 已装（见 01 文件）。`kubectl -n monitoring port-forward svc/prom-stack-kube-prom-prometheus 9090:9090` 后在 <http://localhost:9090> 逐题执行，先自己写再看答案。

1. 有几个抓取目标活着？——`count(up == 1)`
2. 按 job 统计挂了几个目标？——`count by (job) (up == 0)`
3. Prometheus 每秒入库多少样本？——`rate(prometheus_tsdb_head_samples_appended_total[5m])`
4. 每节点 CPU 使用率（%）——`(1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100`
5. 每节点内存使用率（%）——`(1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100`
6. 磁盘使用率最高的 5 个挂载点——`topk(5, (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}) * 100)`
7. 每个 namespace 的 Pod 每秒 CPU 核数——`sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m]))`
8. Prometheus 自身 HTTP 请求的 P99——`histogram_quantile(0.99, sum by (le) (rate(prometheus_http_request_duration_seconds_bucket[5m])))`
9. 5 分钟错误率（不存在 http_requests_total 时改用 up 感受语法即可）——`sum(rate(http_requests_total{code=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))`
10. 过去 1h 内第 4 题结果的最小值（子查询）——`min_over_time(((1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))) * 100)[1h:])`

验证方法：每题先预测"返回几条序列、各带什么标签"，再执行对照。预测错的地方就是你理解的空洞——这正是 PCA 读代码题的训练方式。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| `expected type range vector, got instant vector` | rate/over_time 忘了 `[5m]` | 函数要求 range vector，补窗口 |
| `vector selector must contain at least one non-empty matcher` | 所有 matcher 都能匹配空串 | 至少一个非空匹配（如精确 = 或非空正则） |
| 正则匹配不到 5xx | `=~"5"` 全锚定只匹配字面 "5" | 写 `5..` 或 `5.*` |
| increase 结果是 8.67 不是整数 | 外推是设计行为 | 接受估计值；要精确计数用日志系统 |
| 除法右边全 0 或缺序列 | 分母序列被 by/without 聚合没了或配对失败 | 两侧 by 相同标签；确认分母非零 |
| histogram_quantile 报错或输出怪值 | 聚合丢了 le / 用在了 _sum 上 | `sum by (le, …)`；只用 _bucket 序列 |
| P99 曲线贴着 1s 不动 | P99 落在过宽的桶或 +Inf 桶 | 埋点侧加窄桶，覆盖目标分位数 |
| summary 多实例 avg 出"整体 P99" | 分位数不可平均 | 改 histogram，sum by (le) 后重算 |
| 面板越来越慢 | 每个面板重复算大范围 rate | 拆成 recording rules，面板只查预聚合序列 |

## 自测

1. `sum by (job) (http_requests_total)` 与 `sum(rate(http_requests_total[5m])) by (job)` 在语义上有什么根本区别？
<details><summary>答案</summary>

前者把 counter 的当前累计值按 job 加总，得到的是"从启动至今的总请求数之和"，毫无运营意义且随实例重启跳变；后者先对每条时序求每秒速率再按 job 求和，得到"该 job 当前每秒请求数"。counter 必须先进 rate/increase 再聚合，顺序不可颠倒。
</details>

2. 抓取间隔 30s，某面板用 `rate(x[1m])`，偶发断点。为什么？怎么改？
<details><summary>答案</summary>

1m 窗口在 30s 间隔下只有约 2 个样本，窗口边界与抓取落点不对齐时可能只包住 1 个样本，rate 无输出（断点）；单次抓取失败影响也占一半样本。按"窗口 ≥ 4×间隔"改为至少 [2m]，稳妥用 [5m]。
</details>

3. `irate` 比 `rate` 更"实时"，为什么告警规则里反而用 rate？
<details><summary>答案</summary>

irate 只用最后两个样本，单个慢样本或抓取抖动就产生尖峰，告警会频繁误触发；且 for 计时要求条件持续为真，irate 的锯齿让条件反复真假切换。rate 用全窗口平滑数据，是告警的正确选择；irate 适合交互式探查瞬时尖峰。
</details>

4. 三个实例的 histogram 桶已 sum by (le, job) 聚合，算出的 P99 与"三个实例各自 P99 的平均值"为什么不一致？哪个才对？
<details><summary>答案</summary>

分位数是分布的属性，不是均值的属性。正确做法是把分布（桶计数）相加再求分位数；对分位数求平均没有数学意义（两个双峰分布的平均分位数可能不在任何真实分布上）。sum by (le) 后的 histogram_quantile 才是服务整体 P99。
</details>

5. `{__name__=~"kube_.*"}` 合法而 `{job=~".*"}` 非法，为什么？
<details><summary>答案</summary>

规则要求 selector 至少含一个不匹配空字符串的 matcher。`.*` 能匹配空串，因此 `{job=~".*"}` 不满足"非空 matcher"要求；而 `__name__` 一定非空（指标名必填），`{__name__=~"kube_.*"}` 天然排除空串，合法。
</details>

6. recording rule `job:http_requests:rate5m` 已存在。写告警"QPS 超 1000"时该用原表达式还是规则名？理由是什么？
<details><summary>答案</summary>

用规则名：`job:http_requests:rate5m > 1000`。评估成本从"对全部原始序列算 rate 再聚合"降为"读几条预聚合序列"；多个告警与面板复用同一条规则还保证口径一致。代价是 30s 的预聚合延迟，对告警完全可接受。
</details>

7. `min_over_time(rate(x[5m])[1h:1m])` 里把 step 改成 1s 会发生什么？什么时候值得这么做？
<details><summary>答案</summary>

子查询在 1h 内以 1s 步长求值 3600 次，每次都对 [5m] 窗口算 rate，计算量暴增（约等于 3600 次独立查询），通常纯属浪费。只有当你要捕捉的"最小值"本身可能在秒级出现、且这是一次性交互查询而非常驻面板时才值得；常驻需求应拆成 recording rule 链。
</details>

## 延伸阅读

- PromQL 基础（类型/selector/offset/@）：<https://prometheus.io/docs/prometheus/latest/querying/basics/>
- 运算符（聚合/二元/vector matching）：<https://prometheus.io/docs/prometheus/latest/querying/operators/>
- 函数参考（rate/histogram_quantile/子查询）：<https://prometheus.io/docs/prometheus/latest/querying/functions/>
- histogram 实践（插值误差、桶设计）：<https://prometheus.io/docs/practices/histograms/>
- recording rules 与命名惯例：<https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/>
