// quiz-data.js · 学习中心自测题库
// 结构：window.QUIZ_DATA = { pca: [...], cka: [...], cks: [...], basics: [...],
//   linux: [...], programming: [...], cicd: [...], otel: [...], logging: [...],
//   middleware: [...], datastream: [...], sre: [...], cloud: [...], aiops: [...],
//   bigdata: [...] }
// 每题对象：q(题干) / options(四选项) / answer(正确索引 0-3) / explain(解析)
// PCA 对齐五域权重：可观测概念 4 题、Prometheus 基础 8 题、PromQL 13 题、
// 插桩与 Exporter 6 题、架构与运维 9 题；CKA/CKS 按官方大纲五域分布。
// 其余模块按各自章节主线命题：basics 20 题（Docker 10 + K8s 10）、linux 15 题、
// programming 12 题、cicd 20 题、otel 12 题、logging 11 题、middleware 10 题、datastream 10 题、
// sre 10 题、cloud 10 题、aiops 10 题、bigdata 15 题（HDFS 4 / YARN 3 / Hive 2 /
// Spark 3 / Doris 2 / ZooKeeper 1）。

window.QUIZ_DATA = {

  // ========== PCA：Prometheus Certified Associate（40 题）==========

  pca: [

    // --- 域1 可观测概念（4 题）---

    {
      "q": "关于 SLI、SLO、SLA 三者的关系，下面哪种说法是正确的？",
      "options": [
        "SLI 是对服务状态的度量指标，SLO 是基于 SLI 设定的目标值，SLA 是写进合同、违反后有业务后果的协议",
        "SLO 是度量指标，SLI 是目标值，SLA 只是 SLO 的另一种叫法",
        "三者是同一个概念在三个厂商里的不同叫法",
        "SLA 只与基础设施可用性有关，SLI/SLO 只与应用性能有关"
      ],
      "answer": 0,
      "explain": "考察点是可观测三大概念的定义链：SLI（指标，如成功率、P99 延迟）→ SLO（对 SLI 的目标，如 99.9% 可用）→ SLA（带违约责任的合同条款）。易错处是把 SLO 和 SLI 的方向搞反，或者认为 SLA 是技术约定。记住：SLA 一定涉及商务后果，内部运维通常只谈 SLI/SLO 和 error budget。"
    },
    {
      "q": "Google SRE 的“四大黄金信号（four golden signals）”指的是哪一组？",
      "options": [
        "CPU、内存、磁盘 I/O、网络带宽",
        "延迟、流量、错误、饱和度",
        "可用性、吞吐、并发、队列长度",
        "QPS、P50、P90、错误码分布"
      ],
      "answer": 1,
      "explain": "黄金信号是 latency、traffic、errors、saturation，是 PCA 可观测概念域的高频考点。选项 A 是典型干扰项，那是 Brendan Gregg 的 USE 方法（Utilization/Saturation/Errors）关注的资源维度。易错处：把 CPU/内存这类资源指标当成黄金信号本身，其实饱和度（如队列长度、线程池耗尽）才是。"
    },
    {
      "q": "Prometheus 采用 pull（拉取）模型采集指标，相比 push 模型的主要优势不包括以下哪项？",
      "options": [
        "抓取失败本身就是一个健康信号，目标挂了采集自然失败，便于发现异常",
        "目标重启后 Prometheus 重新拉取即可拿到最新的计数器值，不需要在本地缓存状态",
        "Prometheus 自身发生故障后恢复，不会丢失目标端已经缓冲的历史数据",
        "天然防止采集到的指标比目标真实状态更新得更快而产生虚假突变"
      ],
      "answer": 2,
      "explain": "考察 pull 与 push 模型对比。A、B、D 都是官方文档列出的 pull 优点：抓取失败即探活、目标本地无需缓存、时序天然按采集时间排序。C 是 push 系统（如带缓冲的 agent）才有的特性，pull 模型下 Prometheus 宕机期间的数据就是缺失的。易错点：误以为 Prometheus 有某种补偿机制能找回宕机期间的数据，实际只能靠 remote_write 或双实例旁路。"
    },
    {
      "q": "关于指标基数（cardinality），下列说法正确的是？",
      "options": [
        "基数等于一个 job 下被抓取的 target 数量",
        "基数指 metric name 加 label 组合出的活跃时间序列总数，是 Prometheus 内存和磁盘开销的主要驱动因素",
        "给指标多加几个 label 不会影响资源消耗，因为 label 是压缩存储的",
        "基数只影响磁盘空间，不影响查询速度"
      ],
      "answer": 1,
      "explain": "考察点：一个时间序列由 metric name + 唯一 label 集合确定，序列总数就是基数，直接决定 TSDB 内存、写入和查询成本。易错处是低估 label 的影响：给 http 请求打上 user_id 或 url 全量 label，基数会爆炸到百万级，Prometheus 会 OOM 或查询超时。排查工具是 TSDB 状态页（/tsdb-status）和 promtool tsdb analyze。"
    },

    // --- 域2 Prometheus 基础（8 题）---

    {
      "q": "counter 类型的进程重启后会从 0 重新计数，PromQL 中 rate() 对此的处理是？",
      "options": [
        "rate() 会把计数器下降识别为重启，将下降量补到后续样本上继续计算，结果仍然正确",
        "rate() 遇到计数器下降会直接返回空结果，必须先用 resets() 修复",
        "rate() 会把下降当作负增长，计算出的速率出现负值",
        "counter 重启后必须调用 reset API 通知 Prometheus，否则数据作废"
      ],
      "answer": 0,
      "explain": "rate()/increase() 内置 counter reset 检测：单次样本下降被假设为一次重启，下降量会被加回。易错处：很多初学者以为重启会破坏数据，或者以为需要额外配置；实际上只需要记住 counter reset 只能被假设发生一次，如果区间内重启多次且中间样本缺失，结果会有偏差。resets() 只是统计重启次数，不是修复工具。"
    },
    {
      "q": "要监控“当前已使用的文件描述符数”，应该选用哪种指标类型？",
      "options": [
        "counter",
        "gauge",
        "histogram",
        "summary"
      ],
      "answer": 1,
      "explain": "考察指标四类型选型：可增可减、反映当前瞬时值的量用 gauge（如内存使用、队列长度、温度）。counter 只增不减（请求数、错误数），histogram/summary 用于观测延迟类分布。易错处：把“当前值”也用 counter 存，重启归零后语义就乱了；或者想对 gauge 求 rate()——rate 只适用于 counter，对 gauge 应该用 deriv() 或直接取值。"
    },
    {
      "q": "关于 histogram 和 summary 的区别，正确的是？",
      "options": [
        "两者都在服务端计算分位数，区别只是精度不同",
        "histogram 把样本放进 bucket（le 标签），分位数在服务端用 histogram_quantile() 计算，可以跨实例聚合；summary 在客户端预先算好 quantile 标签，服务端无法再聚合",
        "summary 的分位数可以在 PromQL 里用 histogram_quantile() 重新计算",
        "histogram 占用的存储比 summary 小，因为 bucket 会自动合并"
      ],
      "answer": 1,
      "explain": "这是 Prometheus 最经典考点之一：histogram 客户端只分桶，分位数服务端算，因此支持 sum 后再求分位数（跨实例聚合）；summary 的分位数在客户端固定，不同实例的分位数不能平均。易错处：对 summary 的 quantile 做 avg() 在数学上是错的。另外 histogram 的 bucket 是可预估误差（bucket 边界决定），summary 的误差是客户端配置的可调节误差。"
    },
    {
      "q": "下面哪一组信息唯一确定了一条 Prometheus 时间序列？",
      "options": [
        "metric name 和所属的 job",
        "metric name 加上全部 label 的键值对集合（不含 __name__ 本身的差异）",
        "target 的 IP 和端口",
        "metric name、job 和 instance 三个标签"
      ],
      "answer": 1,
      "explain": "时间序列的身份 = metric name（本质是 __name__ 标签）+ 其余所有 label 的键值集合，任何 label 值变化都会产生新序列、旧序列变为 stale。易错处：以为 job/instance 就够唯一，实际上业务标签（path、status 等）都会参与区分；也因此标签值里放高变动值（如 session id）会造成序列膨胀。可以理解为每条序列是“标签集合 → (时间戳, 值) 流”的映射。"
    },
    {
      "q": "当某个 scrape target 停止响应后，Prometheus 会如何处理它已有的时间序列？",
      "options": [
        "序列立即消失，查询立刻查不到任何数据",
        "序列最后一次被写入后的约 5 分钟（默认 staleness 标记窗口）会被标记为 stale，此后的查询不再返回该序列",
        "序列会一直保留并重复最后一个值，直到 target 恢复",
        "Prometheus 会主动删除该 target 的所有历史序列"
      ],
      "answer": 1,
      "explain": "考察 staleness 处理：抓取失败后序列不会立刻消失，而是经过默认 5 分钟的 lookback 之后被标记 stale，查询中该序列停止出现。易错处：以为会沿用最后值（那是 pushgateway 场景）或以为历史数据被删除（历史 block 完好，只是不再有新样本）。这个机制也解释了为什么 target 恢复后图表会出现断档而非直线。"
    },
    {
      "q": "在 Prometheus 中，metric name 在存储层面实际上是什么？",
      "options": [
        "一个独立的字段，与 label 体系无关",
        "一个名为 __name__ 的 label",
        "文件系统里的目录名",
        "TSDB block 的元数据键"
      ],
      "answer": 1,
      "explain": "Prometheus 把 metric name 实现为保留标签 __name__，所以可以用 label_replace 或 {'__name__'} 选择器对它做操作，也可以用 metric_name{} 语法按标签过滤。易错处：不了解这一点的人在给指标重命名（如聚合后改名）时会卡住；利用 label_replace(v, '__name__', 'new_name', '__name__', '(.*)') 可以实现序列重命名。以 __ 开头和结尾的是内部保留标签：__name__ 作为指标名随样本正常入库，而 __address__、__metrics_path__ 等仅用于 relabel 阶段的内部标签在写入 TSDB 前会被剔除。"
    },
    {
      "q": "关于 recording rules（记录规则）的主要作用，最准确的说法是？",
      "options": [
        "把数据发送到远端长期存储",
        "把常用且开销大的 PromQL 表达式预先算好存成新序列，让仪表盘和告警直接查询预计算结果",
        "降低 scrape 频率以节省资源",
        "替代告警规则，直接在规则文件里发通知"
      ],
      "answer": 1,
      "explain": "recording rules 定期评估表达式并把结果写成新的时间序列，典型场景是把跨大量序列的聚合（如按集群统计 QPS）预计算，dashboard 查询从秒级降到毫秒级。易错处：把它和 alerting rules 混淆——后者产生 ALERTS 序列并发送告警；也别以为它能降低采集量，它反而会新增序列。规则文件可用 promtool check rules 校验。"
    },
    {
      "q": "关于 scrape_interval 与 scrape_timeout 的约束，正确的是？",
      "options": [
        "scrape_timeout 必须小于等于 scrape_interval，且默认 interval 为 1m、timeout 为 10s",
        "scrape_timeout 可以大于 scrape_interval，Prometheus 会自动排队",
        "两者必须严格相等，否则抓取会失败",
        "默认 interval 为 15s、timeout 为 5s，且 timeout 不能修改"
      ],
      "answer": 0,
      "explain": "全局默认 scrape_interval 是 1m、scrape_timeout 是 10s，且 timeout 不允许超过 interval，这是配置合法性约束。易错处：给慢目标调大 timeout 时忘记检查 interval，导致配置加载报错；另外 interval 决定了 rate() 的最小合理窗口——[5m] 窗口在 1m 间隔下约有 5 个样本，窗口再小就没有足够样本了。"
    },

    // --- 域3 PromQL（13 题）---

    {
      "q": "要计算过去 5 分钟 http 请求的每秒平均速率，正确的写法是？",
      "options": [
        "http_requests_total[5m]",
        "rate(http_requests_total[5m])",
        "increase(http_requests_total) / 300",
        "irate(http_requests_total[5m]) * 60"
      ],
      "answer": 1,
      "explain": "counter 求速率必须用 rate() 并给出 range selector，选项 A 只是 range vector 不能直接展示，C 缺少时间窗口。易错点：rate() 是“平均速率”（窗口内增量除以时间，并对边界做外推），适合图表和告警；irate() 只看最后两个样本，适合高精度短时观察但容易抖动。记住口诀：告警用 rate，看瞬时尖刺用 irate。"
    },
    {
      "q": "rate() 和 increase() 的关系是？",
      "options": [
        "两者完全等价，只是返回单位不同",
        "increase() 返回的是窗口内 counter 的增长总量（近似值），rate() 返回每秒速率；increase 本质是 rate 乘以窗口秒数（带边界外推）",
        "increase() 只能用于 gauge，rate() 只能用于 counter",
        "increase() 计算的是精确值，rate() 是估算值"
      ],
      "answer": 1,
      "explain": "考察点：increase(x[1h]) 约等于 rate(x[1h]) * 3600，两者都基于采样点插值外推，所以增加量往往不是整数（比如 7.9），这是正常现象不是 bug。易错处：看到小数以为是计算错误；或者拿 increase 除以窗口想“更精确”，其实那只是重新得到 rate。对重启次数这类离散计数想取整需要用 floor() 包一层。"
    },
    {
      "q": "计算 P95 接口延迟的正确 PromQL 是？",
      "options": [
        "histogram_quantile(0.95, rate(http_request_duration_seconds_sum[5m]))",
        "histogram_quantile(0.95, sum by (le) (rate(http_request_duration_seconds_bucket[5m])))",
        "quantile(0.95, http_request_duration_seconds_bucket)",
        "histogram_quantile(0.95, avg by (instance) (http_request_duration_seconds_bucket))"
      ],
      "answer": 1,
      "explain": "histogram_quantile() 的第二个参数必须是 bucket 序列的 rate/increase，且聚合时必须按 le 保留（或按 le 加业务维度），否则分位数无法计算。A 用 _sum 是最常见错误——sum 是总量不是分布；C 对 bucket 直接求分位数没有意义；D 用 avg 聚合 bucket 会把计数平均掉。结果是预估值，落在某个 bucket 区间内，最大误差由 bucket 边界决定。"
    },
    {
      "q": "sum by (code) (http_requests_total) 与 sum without (code) (http_requests_total) 的区别是？",
      "options": [
        "by (code) 按 code 分组求和；without (code) 去掉 code 维度、按其余所有标签分组求和",
        "两者都会按 code 分组，只是语法风格不同",
        "without (code) 会删除所有标签只留总和，by (code) 保留全部标签",
        "by 只能用于 rate 的结果，without 只能用于原始序列"
      ],
      "answer": 0,
      "explain": "by 是白名单（结果只保留列出的标签），without 是黑名单（结果去掉列出的标签，其余保留）。易错处：把 without 的语义记反，以为它也是保留；两者都可用于任何 instant vector，不需要先 rate。做题技巧：想按接口聚合就 by (handler)，想抹掉机器维度就 without (instance)。"
    },
    {
      "q": "要对比“今天此刻”与“昨天此刻”的 QPS，下面哪个表达式正确？",
      "options": [
        "rate(http_requests_total[5m]) - rate(http_requests_total[5m] offset 1d)",
        "rate(http_requests_total[5m]) - rate(http_requests_total[5m])[1d:5m]",
        "rate(http_requests_total[5m]) - delay(rate(http_requests_total[5m]), 86400)",
        "rate(http_requests_total[5m] - 86400)"
      ],
      "answer": 0,
      "explain": "offset 修改的是瞬时向量的求值时间点，offset 1d 表示取 24 小时前的值再参与运算。B 的方括号子查询语法写法不对（子查询应为 [1d:5m] 直接作用在表达式上），C、D 都是编造的函数。易错处：offset 要放在 range selector 之后、圆括号外面也可，但作用对象必须是向量表达式；环比/同比监控是 offset 的标准应用场景。"
    },
    {
      "q": "磁盘剩余空间预计多久写满的告警，最合适的表达式是？",
      "options": [
        "deriv(node_filesystem_avail_bytes[1h]) < 0",
        "predict_linear(node_filesystem_avail_bytes[1h], 4 * 3600) < 0",
        "linear_predict(node_filesystem_avail_bytes, 1h, 4h) < 0",
        "node_filesystem_avail_bytes - avg_over_time(node_filesystem_avail_bytes[1h]) < 0"
      ],
      "answer": 1,
      "explain": "predict_linear(v, t) 用窗口内简单线性回归预测 t 秒后的值，配合 < 0 就是经典的“4 小时后写满”告警。A 只能说明在下降，不能说明何时耗尽；C 是编造的函数名；D 只是均值偏差。易错处：predict_linear 用的是线性模型，对突发写入型增长会低估风险，窗口选择（1h~6h）要结合业务写入模式。"
    },
    {
      "q": "要计算“每 5 分钟速率在 1 小时内的最大值”，正确的子查询写法是？",
      "options": [
        "max_over_time(rate(http_requests_total[5m]))",
        "max_over_time(rate(http_requests_total[5m])[1h:1m])",
        "rate(max_over_time(http_requests_total[5m])[1h:1m])",
        "max(rate(http_requests_total[5m][1h:1m]))"
      ],
      "answer": 1,
      "explain": "子查询语法是 <expr>[<range>:<step>]，作用在表达式之后，因此先按 step（可省略，省略时用评估步长）对每个点求 rate 得到瞬时序列，再用 [1h:1m] 把它转成区间向量交给 max_over_time。A 把 rate 的结果（瞬时向量）直接喂给 max_over_time，而该函数只接受区间向量，必须先经子查询转换；C 把方向弄反了；D 的 max 聚合器不能直接作用于子查询结果并保持每序列取最大（max 会按所有标签分组，行为不同）。易错点：子查询开销大，适合临时分析，不建议放进高频仪表盘。"
    },
    {
      "q": "label_replace(up, 'team', 'infra', 'instance', '.*:(.*)') 的作用是？",
      "options": [
        "把 up 指标的 instance 标签整体替换成 infra",
        "基于 instance 标签的正则捕获，为序列新增（或覆盖）team 标签，值为 infra，原 instance 标签不变",
        "删除 instance 标签并改名为 team",
        "把导出端口的团队名抓取出来并按 team 重命名指标"
      ],
      "answer": 1,
      "explain": "label_replace(v, dst_label, replacement, src_label, regex) 从 src_label 取值、按 regex 匹配，把 replacement 写入 dst_label，源标签保持不变；不匹配的序列原样保留（新标签缺失）。易错处：以为它会修改源标签，或以为不匹配的序列被过滤掉——那是 keep/filter 的语义，label_replace 不做过滤。常用于在查询侧补齐虚拟标签再分组。"
    },
    {
      "q": "当某个 job 的所有实例都消失时仍想触发告警，应该用哪个函数？",
      "options": [
        "absent(up{job='api'}) == 1",
        "up{job='api'} == 0",
        "count(up{job='api'}) == 0",
        "rate(up{job='api'}[5m]) < 1"
      ],
      "answer": 0,
      "explain": "absent() 在选择器没有匹配到任何序列时返回一个值为 1 的单元素向量，因此能对“序列本身消失”（如配置被删、job 全灭）告警。B 和 C 在序列不存在时结果为空向量，告警根本不会触发，这是 absent 存在的意义。D 在无数据时同样为空。易错点：absent 的参数要带完整标签，才能保证返回的向量带有可供路由的标签。"
    },
    {
      "q": "表达式 A / on (instance) group_left B 中，group_left 的含义是？",
      "options": [
        "左侧是“多”的一侧，把右侧的标签复制到结果上，允许一对多匹配",
        "右侧允许多条序列匹配左侧一条，多余的被丢弃",
        "把左侧序列按 instance 分组后再相除",
        "结果只保留左侧的标签，右侧标签全部丢弃"
      ],
      "answer": 0,
      "explain": "group_left 表示“多对一”中多的那侧在左边，右边（一的那侧）的额外标签会被复制到结果，典型用途是把机器级元数据（如核心数）除到每核指标上。group_right 则相反。易错处：方向写反会报 many-to-many matching not allowed 错误；不加 group 修饰的一对一匹配要求双方标签完全对齐，且匹配不上时序列被丢弃。"
    },
    {
      "q": "topk(5, http_requests_total) 在没有分组上下文时的行为是？",
      "options": [
        "返回每个 label 组合下最大的 5 条序列",
        "对所有序列整体取最大的 5 条返回，值随评估时间变化",
        "返回出现次数最多的 5 个标签值",
        "把每条序列的最高历史值取出来再排序"
      ],
      "answer": 1,
      "explain": "topk/bottomk 是聚合运算，不分组时（即不写 by/without）作用于全部输入序列，返回当前评估时刻值最大的 k 条。若写 topk(5, x) by (job)，则每个 job 组内各取前 5。易错处：以为 topk 会“每个分组默认取前 k”；以及把它与排序展示混用——它只用于过滤，仪表盘排序应交给图表端。"
    },
    {
      "q": "下列哪个表达式可以安全地把布尔条件转成 0/1 值用于计算（而不是过滤序列）？",
      "options": [
        "node_memory_available_bytes > 1000000000",
        "node_memory_available_bytes > bool 1000000000",
        "bool(node_memory_available_bytes > 1000000000)",
        "node_memory_available_bytes and 1000000000"
      ],
      "answer": 1,
      "explain": "比较运算符默认做过滤（保留满足条件的原值），加 bool 修饰后返回 0/1 的向量，可用于例如 sum(成功率类布尔) 统计满足条件的实例数。C 是编造的函数写法；and 是集合操作符，语义完全不同。易错处：想统计“低于阈值的机器数”时直接 count(x < n)，结果永远是被过滤后的序列数——其实这样也行，但想按机器维度打分列就必须用 bool。"
    },
    {
      "q": "查询 sum(rate(http_requests_total[5m])) by (job) 时，某个实例刚重启导致 counter 归零，结果会？",
      "options": [
        "该实例在该点的贡献被正确处理，整体速率无明显异常",
        "整个 job 的速率瞬间变成 0",
        "该实例的序列被从聚合中永久剔除",
        "查询会因为 counter reset 而报错"
      ],
      "answer": 0,
      "explain": "rate() 在每个序列内部先处理 counter reset（把下降量补回），聚合发生在 rate 之后，因此单实例重启不会污染 job 级结果。易错点在于操作顺序：应该“先 rate 后 sum”，写成 sum(http_requests_total) 再除时间会把多个 counter 的绝对值加起来毫无意义。这也是聚合公式的黄金法则：聚合 rate，而不是 rate 聚合。"
    },

    // --- 域4 插桩与 Exporter（6 题）---

    {
      "q": "Prometheus 抓取的 /metrics 文本格式中，TYPE 行声明 metric 的作用是？",
      "options": [
        "只是注释，抓取时会被忽略，不影响任何行为",
        "告诉 Prometheus 该指标是 counter/gauge/histogram/summary/untyped，影响元数据展示和某些函数的语义约束",
        "用于声明指标的单位",
        "用于声明指标的归属团队"
      ],
      "answer": 1,
      "explain": "exposition format 里 # TYPE name counter 这类行声明类型，Prometheus 会把它记入元数据（可查询 /api/v1/metadata），类型决定了哪些用法合理（比如对 gauge 求 rate 无意义）。易错处：以为 TYPE 可有可无——省略时会被当作 untyped，dashboard 元信息和部分客户端校验会退化；HELP 只是帮助文本。"
    },
    {
      "q": "要采集 MySQL 服务器的指标，社区的标准做法是？",
      "options": [
        "在 Prometheus 里配置 mysql_sd_configs 直接连接 MySQL",
        "部署 prometheus/mysqld_exporter，由它连 MySQL 暴露 /metrics，Prometheus 抓取该 exporter",
        "让应用在业务代码里上报数据库指标",
        "用 node_exporter 加载 MySQL 插件"
      ],
      "answer": 1,
      "explain": "第三方服务的指标通过专用 exporter 适配：exporter 负责连 MySQL 查 SHOW STATUS 等并转成 Prometheus 格式。A 是编造的 SD 配置（MySQL SD 只做服务发现，不存在）；C 把基础设施指标混进业务代码是反模式；node_exporter 只管主机层。易错点：exporter 应部署在尽量靠近目标的位置，且要注意 exporter 自身的 exporter_last_scrape_error 与 scrape_duration 指标。"
    },
    {
      "q": "关于 Pushgateway 的适用场景，正确的是？",
      "options": [
        "所有短生命周期任务的指标都必须先推到 Pushgateway 再由 Prometheus 抓取",
        "Pushgateway 适合批处理/定时任务等无法被主动抓取的作业；指标推上去后会一直保留，直到被显式删除或覆盖，因此不适合当消息队列用",
        "Pushgateway 会自动按时间清理过期指标，默认 5 分钟",
        "Pushgateway 主要用于缓解 Prometheus 抓取压力，作为常驻缓冲层"
      ],
      "answer": 1,
      "explain": "Pushgateway 是“指标暂存点”，服务端不会自动过期清理（除非配置了 --metrics.max-age 之类参数，默认永久保留），所以任务重启后旧值残留会误导监控。易错点：把 success/failure 这类语义指标推给它长期堆积；官方明确不建议把它当作事件缓冲队列，因为它不保证送达语义、也无去重时间线。"
    },
    {
      "q": "Prometheus 官方维护（first-party）的客户端库不包括以下哪个？",
      "options": [
        "Go",
        "Java",
        "Python",
        "Node.js"
      ],
      "answer": 3,
      "explain": "官方 client library 是 Go、Java/JVM 系、Python、Ruby，Node.js 等属于社区维护。考察点是插桩时优先选官方库以保证语义正确（如 histogram bucket 默认值一致）。易错处：以为所有流行语言都有官方库，结果用了社区库后发现默认 bucket 或命名约定不一致；命名要遵循 counter 加 _total 后缀等约定。"
    },
    {
      "q": "在应用里给 counter 打标签时，下面哪种做法会带来基数风险？",
      "options": [
        "http_requests_total{method='GET', handler='/api/users'}",
        "http_requests_total{method='GET', status='200'}",
        "http_requests_total{user_id='1029384', session='abc-def'}",
        "http_requests_total{region='cn-east-1'}"
      ],
      "answer": 2,
      "explain": "每个不同的 label 值组合都是一条新序列，user_id/session 这类无界（unbounded）标签会让序列数随用户数线性甚至更快增长，撑爆内存。易错点：基数本身不是绝对的坏，A/B 的有界标签（HTTP method、状态码、路由模板）是推荐做法；关键是绝对不要用无界维度，且路由要用模板而不是原始 URL。"
    },
    {
      "q": "关于 histogram 的默认 bucket，正确的理解是？",
      "options": [
        "默认 bucket 覆盖大约 5ms 到 10s 的范围，适合典型网络请求；延迟特征不同的系统应自定义 bucket",
        "默认 bucket 覆盖 0 到正无穷，因此永远不需要自定义",
        "bucket 边界由 Prometheus 服务端根据数据分布自动调整",
        "bucket 越多越好，精度随数量线性提升且无成本"
      ],
      "answer": 0,
      "explain": "客户端默认 bucket（如 .005 到 10 共十几档）针对普通服务延迟设计，如果你监控的是毫秒级缓存或分钟级批任务，就必须自定义边界，否则分位数全部落进第一个或最后一个 bucket，误差巨大。易错点：bucket 是在客户端预定义的、服务端不能追溯调整，选型时要先看 SLO 目标值（如 99 线在 300ms，就要在附近密分桶）。"
    },

    // --- 域5 架构与运维（9 题）---

    {
      "q": "Prometheus 自身高可用（HA）的官方推荐方式是？",
      "options": [
        "多副本间自动分片，各自抓一半 target",
        "运行两个配置完全相同的 Prometheus 实例，各自独立抓取全量数据，告警统一发到做了 cluster（gossip 去重）的 Alertmanager",
        "在 Prometheus 前加负载均衡器把抓取流量分摊",
        "开启 --ha 标志启用主备热切换"
      ],
      "answer": 1,
      "explain": "Prometheus 没有内置集群模式，标准做法是跑两个一模一样的实例（数据各自独立、有细微时间差），重复告警由 Alertmanager 集群的 gossip 协议去重。易错点：以为可以像数据库那样做共享存储主备；分片抓取属于水平扩展方案，需要配合 Thanos/Cortex/Mimir 这类全局查询层才有完整视图。"
    },
    {
      "q": "Alertmanager 中 group_by 的作用是？",
      "options": [
        "把来自不同 Prometheus 实例的重复告警去重",
        "把具有相同指定标签值的告警合并成一条通知，配合 group_wait/group_interval 控制发送节奏",
        "按标签把告警路由给不同的接收人",
        "把告警按严重程度排序"
      ],
      "answer": 1,
      "explain": "group_by 定义聚合维度（如 ['alertname', 'cluster']），同组告警在 group_wait 内等待合并、之后按 group_interval 追加发送。A 是 Alertmanager 集群 gossip 去重干的活；C 是 route 的 match/match_re 配合 receiver 做的；排序与抑制（inhibit_rules）也不是它的职责。易错点：group_wait 设太短会告警风暴，设太长会延迟关键通知。"
    },
    {
      "q": "Prometheus federation（联邦）的典型用途是？",
      "options": [
        "把全局集群的指标实时复制到多个区域，实现多活",
        "层级化架构：下层 Prometheus 抓取本域细节，上层通过 /federate 端点只拉取少量聚合后的关键指标",
        "替代 remote_write，把全量原始样本传到远端",
        "让多个 Prometheus 共享同一个存储卷"
      ],
      "answer": 1,
      "explain": "联邦是“拉取聚合”的层级方案：上层用 match[] 选择器从下层的 /federate 抓取已被 recording rule 聚合过的序列，适合树状组织监控。易错点：拿联邦去同步全量数据会重复抓取且语义混乱，全量长期存储应该用 remote_write + Thanos/Mimir；联邦和级联（hierarchical）通常只是聚合层面的桥接。"
    },
    {
      "q": "Thanos / Cortex / Mimir 这类方案解决的核心问题是？",
      "options": [
        "让 PromQL 支持 join 语法",
        "提供跨 Prometheus 实例的全局查询视图、对象存储长期保留和水平扩展，弥补单机 Prometheus 的保留期与查询范围限制",
        "替代 Alertmanager 实现告警去重",
        "给 exporter 自动生成配置"
      ],
      "answer": 1,
      "explain": "单机 Prometheus 的两个硬伤是保留期有限（本地盘）和查询范围限于本实例；Thanos Sidecar/Receive 配合对象存储可实现历史归档与全局 Dedup 查询，Cortex/Mimir 走分片多副本路线。易错点：以为上了 Thanos 就不需要每个实例本地存储，Sidecar 模式仍依赖本地 TSDB 上传 block；查询全局视图需要 Query 组件聚合去重。"
    },
    {
      "q": "关于 remote_write 的说法，正确的是？",
      "options": [
        "remote_write 用于让 Prometheus 主动把采集到的样本发往远端存储（如 Thanos Receive、Mimir、VictoriaMetrics），属于推送路径",
        "remote_write 让 Prometheus 从其他 Prometheus 拉数据",
        "remote_write 会自动压缩历史数据并删除本地副本",
        "remote_write 只能发给另一个相同版本的 Prometheus"
      ],
      "answer": 0,
      "explain": "remote_write 是 Prometheus 里少有的“推”路径：抓取进本地的样本按配置（remote_write 组，含 queue、批量、重试）外发到兼容接收端。易错点：以为 remote_write 是联邦的别名——联邦是上层拉取，remote_write 是本端推送；开启后要关注 prometheus_remote_storage_samples_total 与发送队列积压指标，网络抖动会造成样本延迟与重排。"
    },
    {
      "q": "relabel_configs 与 metric_relabel_configs 的区别是？",
      "options": [
        "前者在抓取前对 target 标签（如 __address__、来自服务发现的元标签）操作，决定抓谁、贴什么标签；后者在抓取后对样本操作，常用于丢弃或改写指标",
        "前者只对 Prometheus 自身指标生效，后者对业务指标生效",
        "两者等价，只是新旧版本的配置名",
        "前者修改告警标签，后者修改记录规则标签"
      ],
      "answer": 0,
      "explain": "relabel_configs 处于服务发现之后、抓取之前，典型任务是替换 __address__、按 __meta_* 元标签过滤目标；metric_relabel_configs 在样本入库前执行，典型任务是 drop 高基数或无用指标（如 drop 带_container_label_xxx 的序列）。易错点：想丢弃某指标却写在了 relabel_configs 里，那是按目标级别整组过滤，粒度完全不同。"
    },
    {
      "q": "关于 Prometheus 本地 TSDB 的 block 机制，正确的是？",
      "options": [
        "所有样本追加写入内存中的 head block，默认每 2 小时被压缩成一个不可变的磁盘 block",
        "每个 scrape 请求都会直接写一个新 block",
        "block 只在 Prometheus 重启时生成",
        "block 大小固定为 1 天且不可配置"
      ],
      "answer": 0,
      "explain": "TSDB 的写入路径是 head（可写）→ 每 2 小时 cut block（只读，含 index/chunks）→ 后台 compaction 合并压实。易错点：以为数据是立刻落盘成小文件，实际上 head 阶段靠 WAL 崩溃恢复；保留策略 --storage.tsdb.retention.time 控制旧 block 删除，手工删 block 会导致 index 不一致，只能整体操作。"
    },
    {
      "q": "在 Kubernetes 环境下动态发现抓取目标，最合适的服务发现机制是？",
      "options": [
        "static_configs 手工维护 IP 列表",
        "kubernetes_sd_configs 配合 role（node/pod/service/endpoints 等）与 relabel 规则动态发现目标",
        "consul_sd_configs，因为 Kubernetes 内置了 Consul",
        "file_sd_configs，配合脚本每分钟重写 JSON"
      ],
      "answer": 1,
      "explain": "kubernetes_sd_configs 直连 API server，按 role 暴露 __meta_kubernetes_* 元标签，再用 relabel 转成 job/instance。易错点：以为 file_sd 或 static 也能凑合——K8s 里 Pod IP 频繁变化，静态配置必然漂移；另外对 Pod 要靠注解 prometheus.io/scrape 之类的约定 + relabel keep 来筛选，而不是全量抓。"
    },
    {
      "q": "Prometheus 的 Web UI 查询结果中，Table 与 Graph 视图对 range vector 的处理是？",
      "options": [
        "两者都能直接完整展示 range vector 的每个样本",
        "Table 视图会显示区间内每个序列的原始采样点列表，Graph 视图需要把 range vector 转成 instant vector（例如套 rate()）才能画图",
        "Graph 视图可以直接画 range vector，Table 视图不行",
        "两个视图都会自动对 range vector 求平均"
      ],
      "answer": 1,
      "explain": "range vector（带 [5m] 的选择器结果）是“多样本集合”，画图引擎只接受每个时间点一个值的 instant vector，所以 graph 里直接查 http_requests_total[5m] 会画不出线，常见报错就是 invalid expression type。易错点：初学者在 UI 里看到 Table 有数据就以为查询没问题，一换 Graph 就报错；解决方法是套一层 rate/increase/max_over_time 之类的函数。"
    }
    ],

    // ========== CKA（30 题）==========

    cka: [

      // --- 域1 集群架构、安装与配置（8 题）---

      {
        "q": "kubeadm 集群中，kube-apiserver、kube-scheduler 等 control plane 组件以什么形式运行？",
        "options": [
          "以 systemd 服务运行，配置在 /etc/systemd/system/",
          "以 static Pod 运行，manifest 固定放在 /etc/kubernetes/manifests/ 下，由本节点 kubelet 直接管理",
          "以 Deployment 运行在 kube-system namespace",
          "以 DaemonSet 运行在所有节点"
      ],
        "answer": 1,
        "explain": "考察点：static Pod 机制。kubelet 监视 /etc/kubernetes/manifests 目录，里面的 Pod 会被直接创建且不经过 API server 调度（镜像里通常带 k8s.gcr.io 前缀的 pause 容器机制）。易错处：以为改了 YAML 后要 kubectl apply——static Pod 直接改文件即可，kubelet 会自动重建；以及它显示在 kubectl get pods -n kube-system 里却不能被 API server 删除。"
    },
    {
      "q": "查看 kubeadm 集群证书到期时间的命令是？",
        "options": [
          "kubeadm certs check-expiration",
          "openssl list -certs",
          "kubectl get csr",
          "kubeadm token list"
      ],
        "answer": 0,
        "explain": "kubeadm certs check-expiration 列出各组件证书的到期时间与剩余天数，续期用 kubeadm certs renew。易错点：kubectl get csr 查的是 Kubernetes 的 CertificateSigningRequest 对象（一般是 kubelet 请求），与控制面 TLS 证书完全是两回事；证书过期后 control plane static pod 无法启动，节点 NotReady。"
    },
    {
      "q": "为新 worker 节点生成加入命令，正确的是？",
        "options": [
          "kubeadm join --print-command",
          "kubeadm token create --print-join-command",
          "kubectl bootstrap new-node",
          "kubeadm init phase node"
      ],
        "answer": 1,
        "explain": "kubeadm token create --print-join-command 会新建 token 并打印完整的 join 命令（含 CA 证书 hash，防中间人）。易错点：token 默认 24 小时过期，旧命令失效要重新生成；--discovery-token-ca-cert-hash 用于校验 control plane 身份，不要为了省事去掉。忘了参数时可以用 kubeadm token generate 配合手动拼。"
    },
    {
      "q": "etcd 备份的标准做法是？",
        "options": [
          "直接 tar 打包 /var/lib/etcd 目录即可，无需停任何进程",
          "使用 ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-snapshot.db --endpoints=... --cacert/--cert/--key 认证参数",
          "kubectl dump etcd -n kube-system",
          "etcdctl backup --data-dir 自动定时备份"
      ],
        "answer": 1,
      "explain": "在线快照用 etcdctl snapshot save，认证参数（--cacert、--cert、--key）缺一不可，kubeadm 集群证书在 /etc/kubernetes/pki/etcd/ 下。易错点：v3 API 下老命令 etcdctl backup 已不可用，且直接拷目录在运行中有一致性风险；恢复流程是 etcdctl snapshot restore 先还原到新目录再重启 etcd，考试常考完整链路。"
    },
    {
      "q": "升级一个 kubeadm 集群的 master 节点，正确的顺序是？",
        "options": [
          "kubeadm upgrade apply -> apt 安装新版本 kubelet/kubectl -> 重启 kubelet",
          "先 apt 安装 kubeadm 新版本 -> kubeadm upgrade apply -> 升级 kubelet/kubectl 并重启",
          "直接 apt upgrade 全部组件，kubeadm 会自动跟上",
          "先升级所有 worker，最后升级 master"
      ],
        "answer": 1,
      "explain": "官方流程：升级 kubeadm 包 → kubeadm upgrade plan（看可升级版本）→ kubeadm upgrade apply v1.x.x（更新 static pod 镜像）→ 升级 kubelet 与 kubectl 包并 systemctl restart kubelet。易错点：kubelet 不归 kubeadm upgrade 管，忘记升级它会导致版本偏差；worker 节点用 kubeadm upgrade node，且升级前要 drain。"
    },
    {
      "q": "把节点置为维护模式（驱逐 Pods 且不再调度新 Pod）的组合命令是？",
        "options": [
          "kubectl cordon <node> 即可完成驱逐",
          "kubectl drain <node> --ignore-daemonsets --delete-emptydir-data",
          "kubectl delete node <node>",
          "kubectl taint <node> key=value:NoSchedule"
      ],
        "answer": 1,
      "explain": "drain = cordon（标记不可调度）+ 驱逐可驱逐的 Pod；--ignore-daemonsets 跳过 DaemonSet，--delete-emptydir-data 允许删除使用 emptyDir 的 Pod（老版本参数是 --delete-local-data）。易错点：只 cordon 不会驱逐存量 Pod；taint NoSchedule 只挡新调度，也不驱逐存量（NoExecute 才会）。"
    },
    {
      "q": "kubelet 的主配置文件在 kubeadm 集群里通常是哪个？",
      "options": [
        "/etc/kubernetes/kubelet-config.yaml",
        "/var/lib/kubelet/config.yaml（由 --config 引用，标志写在 /etc/systemd/system/kubelet.service.d/10-kubeadm.conf）",
        "/etc/kubelet.conf",
        "~/.kube/config"
      ],
        "answer": 1,
      "explain": "kubelet 参数分两层：systemd drop-in 文件里的 --config 指向 /var/lib/kubelet/config.yaml，认证 kubeconfig 是 /etc/kubernetes/kubelet.conf。易错点：~/.kube/config 是 kubectl 的客户端配置，与 kubelet 无关；修改 config.yaml 后要 restart kubelet 生效，排查时可用 kubectl describe node 看 kubelet 上报的条件。"
    },
    {
      "q": "关于 kubectl config 的三件套（cluster/user/context），正确说法是？",
      "options": [
        "context 绑定一个 cluster 与一个 user，切换 context 即可同时切换访问目标与身份",
        "切换 context 只切换 user，cluster 需要单独切换",
        "一个 kubeconfig 只能存一个 context",
        "current-context 是集群端的属性"
      ],
        "answer": 0,
      "explain": "考察 kubeconfig 结构：clusters（API 地址与 CA）、users（凭证）、contexts（cluster+user+可选 namespace 的组合）。易错点：kubectl config use-context 切的是本地文件里的 current-context，对集群无影响；做题时经常要求 kubectl config set-context --current --namespace=xxx 切默认 namespace，比每次加 -n 高效。"
    },

    // --- 域2 工作负载与调度（5 题）---

    {
      "q": "回滚 Deployment 到上一个版本的命令是？",
      "options": [
        "kubectl rollout undo deployment/nginx",
        "kubectl rollout restart deployment/nginx",
        "kubectl replace -f deployment.yaml --revision 1",
        "kubectl set image deployment/nginx nginx=nginx:old"
      ],
      "answer": 0,
      "explain": "rollout undo 默认回退一个 revision，也可 --to-revision=2 指定；配合 kubectl rollout history 查看版本列表。易错点：rollout restart 是原位重启（常用于让 Pod 重新挂载 ConfigMap），不是回滚；revision 信息依赖 kubernetes.io/change-cause 注解，没有注解时历史记录描述为空但 revision 仍可用。"
    },
    {
      "q": "Pod 的容器只设置了 resources.requests.cpu、未设置 limits，调度器的行为是？",
      "options": [
        "调度按 requests 找满足空闲的节点，运行时该容器可用 CPU 不受硬限制",
        "调度器忽略 requests，按节点物理核数随机放置",
        "没有 limits 的 Pod 无法被调度",
        "requests 会被自动设为 limits 的两倍"
      ],
      "answer": 0,
      "explain": "调度依据 requests（节点 Allocatedable 扣减），limits 才是运行时上限（CPU 被限流、内存超限 OOMKill）。易错点：把 requests 记成“运行时保底占用”就答错方向——requests 只影响调度决策与 OOM 分数权重；QoS 等级由 requests/limits 是否相等且全部设置决定，只设 requests 属于 Burstable。"
    },
    {
      "q": "要强制 Pod 只能运行在带 label disk=ssd 的节点上，正确做法是？",
      "options": [
        "spec.nodeSelector 配 disk: ssd",
        "spec.nodeName 填 ssd",
        "给 Pod 加 toleration",
        "在节点上打 taint disk=ssd 即可"
      ],
      "answer": 0,
      "explain": "nodeSelector 是最简单的硬约束匹配；更灵活的是 requiredDuringScheduling nodeAffinity。易错点：nodeName 是直接指定节点名跳过调度器，不是按标签；taint 是排斥默认 Pod 的，配合的应是 Pod 的 toleration + nodeSelector/affinity 组合；没有 selector 的 taint 只会把 Pod 赶走不会吸引。"
    },
    {
      "q": "taint 效果 NoSchedule 与 NoExecute 的区别是？",
      "options": [
        "NoSchedule 只阻止新 Pod 调度上来，存量 Pod 不受影响；NoExecute 还会立即驱逐不容忍该 taint 的存量 Pod",
        "两者都会驱逐存量 Pod，只是速度不同",
        "NoExecute 只对 DaemonSet 生效",
        "NoSchedule 对已有 Pod 也生效但会等待 300 秒"
      ],
      "answer": 0,
      "explain": "NoExecute 会立刻驱逐（tolerationSeconds 可宽限），典型是 node.kubernetes.io/not-ready:NoExecute；NoSchedule 只影响未来的调度决策。易错点：master 节点上的 node-role.kubernetes.io/control-plane:NoSchedule 意味着加了对应 toleration 的普通 Pod 也能调度上去，taint 不是权限系统；驱赶与容忍要成对分析。"
    },
    {
      "q": "关于 DaemonSet 的描述，正确的是？",
      "options": [
        "在每个符合条件的节点上运行一个 Pod 副本，典型用途是日志采集、监控 agent 等",
        "按 CPU 负载自动增减副本数",
        "保证指定数量的 Pod 副本始终运行，支持滚动更新与回滚",
        "只能在 master 节点上运行"
      ],
      "answer": 0,
      "explain": "DaemonSet 的单位是“节点”而不是副本数，新节点加入会自动拉起，配合 toleration 可以跑在 control plane 上（如 Calico、node-exporter）。易错点：B 是 HPA 的职责，C 是 Deployment+ReplicaSet 的职责；做题时看到“每个节点一个 agent”就选 DaemonSet，看到“恒定 N 个”就选 Deployment。"
    },

    // --- 域3 服务与网络（6 题）---

    {
      "q": "Service 的流量转发实际由谁完成？",
      "options": [
        "kube-apiserver 在数据面逐包转发",
        "每个节点上的 kube-proxy 通过 iptables 或 IPVS 规则完成转发，Service ClusterIP 是虚拟 IP 不属于任何网卡",
        "CoreDNS 直接把请求转发到 Pod",
        "etcd 维护连接表并转发"
      ],
      "answer": 1,
      "explain": "ClusterIP 是 iptables/IPVS 规则虚拟出来的地址，kube-proxy watch Service/EndpointSlice 变化并写转发规则，流量根本不经过 apiserver。易错点：以为 ClusterIP 可以 ping 通——iptables 模式下没有真实设备应答 ICMP；排查 Service 不通要先看 Endpoints 有没有条目，再看 kube-proxy 模式与规则。"
    },
    {
      "q": "NodePort Service 的默认端口范围是？",
      "options": [
        "30000-32767",
        "1024-65535 任意端口",
        "80-443",
        "8000-9000"
      ],
      "answer": 0,
      "explain": "默认 nodePortRange 是 30000-32767，可通过 apiserver 的 --service-node-port-range 修改。易错点：kubectl expose 时手填 nodePort 超出范围会被拒绝，不填则自动分配；外部访问节点端口时任意节点都能进（iptables 规则集群同步），即使本地没有该 Pod 也会再转发。"
    },
    {
      "q": "部署了默认 deny 的 NetworkPolicy 后 Pod 仍能互相访问，最可能的原因是？",
      "options": [
        "NetworkPolicy 需要 CNI 插件支持，如果集群用的是不支持 NP 的 CNI（如裸 flannel），策略会被静默忽略",
        "需要重启 apiserver 才生效",
        "NetworkPolicy 只对 NodePort 生效",
        "必须同时在两端 Pod 上各写一个 policy"
      ],
      "answer": 0,
      "explain": "NetworkPolicy 的执行者是 CNI，kubeadm 默认没装 CNI 或装了不支持的（flannel 不支持 NP）时，API 层创建成功但毫无效果，这是“策略创建了却不生效”的头号原因。易错点：排查时要先确认 CNI（Calico/Cilium 支持），用 calico 的 calicoctl 或 kubectl get networkpolicy 看策略是否选中目标 Pod；policySelector 的方向（ingress/egress）也要逐项核对。"
    },
    {
      "q": "Service 对应的 Endpoints 为空（<none>），最不可能的原因是？",
      "options": [
        "Service 的 selector 与 Pod 的 label 不匹配",
        "目标 Pod 未通过 readiness probe，endpoint 不会被加入",
        "Service 的 targetPort 写成了不存在的端口名",
        "kube-proxy 模式是 iptables 而不是 ipvs"
      ],
      "answer": 3,
      "explain": "Endpoints（或 EndpointSlice）由 apiserver 的 controller 按 selector+readiness 生成，kube-proxy 只消费这个结果，模式不影响生成。易错点：C 中 targetPort 写错时 Pod 可能进 endpoints 但连不通（更隐蔽），而 selector 不匹配是 endpoints 直接为空；排查顺序是 describe service 看 selector → kubectl get pods -l ... → 检查容器端口与 targetPort。"
    },
    {
      "q": "在 namespace myapp 中访问名为 db 的 Service 的完整 FQDN 是？",
        "options": [
          "db.myapp.svc.cluster.local",
          "db.svc.myapp.local",
          "myapp.db.cluster.local",
          "db.cluster.local.myapp"
      ],
      "answer": 0,
      "explain": "格式是 <service>.<namespace>.svc.cluster.local，同 namespace 可以直接用 db 短名，跨 namespace 用 db.myapp。易错点：ndots=5 的 resolv.conf 行为会导致多段名先走搜索域，抓包看到多次 NXDOMAIN 是正常的；CoreDNS 挂了的现象是短名解析失败但 IP 直连正常，用它区分 DNS 问题与网络问题。"
    },
    {
      "q": "关于 Ingress 的前提条件，正确的是？",
      "options": [
        "只要创建了 Ingress 对象，负载均衡就会自动工作",
        "必须先部署 Ingress Controller（如 ingress-nginx），Ingress 对象只是给 controller 看的配置",
        "Ingress 对象只能由 cloud provider 解释",
        "Ingress 可以不指定 backend Service"
      ],
      "answer": 1,
      "explain": "Ingress 资源本身只是一份声明，没有 controller 集群不会发生任何转发行为，这是“配了 Ingress 不通”的最常见原因。易错点：controller 一般以 DaemonSet/Deployment + hostNetwork 或 Service 暴露，rules 里的 host 头要与 curl -H 'Host: xxx' 对得上；backend 指向的 Service 有 endpoints 才能转发。"
    },

    // --- 域4 存储（3 题）---

    {
      "q": "PV 的 accessModes 中，RWO（ReadWriteOnce）的含义是？",
      "options": [
        "整个集群只能有一个节点以读写方式挂载",
        "只能被一个 Pod 挂载",
        "只能读不能写",
        "只能挂载一次，卸载后作废"
      ],
      "answer": 0,
      "explain": "Once 的单位是节点（node-level），同一节点上的多个 Pod（包括被调度到同机的）仍可同时挂载。易错点：把 RWO 理解成单 Pod 限制，导致对 StatefulSet 行为误判；RWX（ReadWriteMany）需要 NFS/CephFS 等共享后端，本地盘不支持。Deployment 滚动时新旧 Pod 分属不同节点就可能因 RWO 冲突而卡住。"
    },
    {
      "q": "PVC 删除后底层 PV 的回收行为由什么决定？",
      "options": [
        "由 StorageClass 的 reclaimPolicy（或静态 PV 的 persistentVolumeReclaimPolicy）决定，Delete 会连底层卷一起删，Retain 保留数据并让 PV 进入 Released",
        "一律删除底层存储",
        "一律保留底层存储",
        "由 Pod 的 restartPolicy 决定"
      ],
      "answer": 0,
      "explain": "动态供应的 PV 继承 StorageClass 的 reclaimPolicy（默认 Delete）；Retain 时 PV 变 Released、不能直接被新 PVC 绑定，需要管理员手工清理并重建。易错点：误删生产 PVC 后想恢复——Delete 策略下云盘可能已经删了，所以重要数据要 Retain 或快照；PV 的 status/claim 引用清理是考题常客。"
    },
    {
      "q": "hostPath 与 local PV 的关键区别是？",
      "options": [
        "没有区别，只是写法不同",
        "local PV 是拓扑感知的调度资源，Pod 会因为依赖它而被调度到卷所在的节点；hostPath 只是直接把节点目录塞进容器，调度器不了解它",
        "hostPath 只能读，local PV 可写",
        "local PV 不需要 PV 对象"
      ],
      "answer": 1,
      "explain": "local PV 声明了 nodeAffinity，调度器把它当作节点约束参与调度；hostPath 绕过一切，Pod 漂移到别的节点就会挂到不同的目录，数据“消失”。易错点：考试里数据固定在某节点磁盘时优先 local PV + nodeAffinity；hostPath 是安全风险（CKS 常考）也是排障时查看节点文件的临时手段。"
    },

    // --- 域5 故障排查（8 题）---

    {
      "q": "查看上一次崩溃容器日志的命令是？",
      "options": [
        "kubectl logs pod/x --previous",
        "kubectl logs pod/x -f --tail=1",
        "kubectl describe pod x 里没有日志，必须上节点看 /var/log",
        "kubectl get events --field-selector reason=Crash"
      ],
      "answer": 0,
      "explain": "--previous 读取重启前那个容器实例的日志（kubelet 本地保留的上次运行日志）。易错点：CrashLoopBackOff 时直接 logs 只能看到本次短暂输出，必须加 --previous；如果容器被逐出太久，previous 日志可能已被清理，这时要靠节点容器运行时的日志目录或中心化日志。"
    },
    {
      "q": "kubectl describe pod 显示 Events 里 FailedScheduling，0/3 nodes are available: insufficient cpu，说明？",
      "options": [
        "节点上的 CPU 物理满载，进程卡死",
        "调度层面可分配 CPU（按 requests 累计的 Allocatable）不足，Pod 一直 Pending",
        "容器 limits 设置过小被限流",
        "kubelet 版本与 apiserver 不匹配"
      ],
      "answer": 1,
      "explain": "调度失败看的是节点 status.allocatable 减去已调度 Pod 的 requests 总和，与真实使用率无关，节点 CPU 空闲也可能 insufficient。易错点：排障时一上来 top 节点看使用率是错方向，应该 kubectl describe node 看 Allocated resources 表；解法是调低 requests、扩节点或清理悬空负载。"
    },
    {
      "q": "新建 Pod 一直停在 ContainerCreating，describe 里出现 network plugin is not ready 或 cni config uninitialized，最可能的原因是？",
        "options": [
        "镜像仓库配额不足",
        "CNI 插件未安装或未就绪（如 Calico Pod 尚未 Running）导致 Pod 网络无法分配",
        "etcd 磁盘满",
        "kube-scheduler 未运行"
      ],
        "answer": 1,
      "explain": "kubeadm 初始化后不装 CNI，所有业务 Pod 都会卡在 ContainerCreating，CoreDNS 也 Pending，这是实验室环境第一大坑。易错点：只盯着业务 Pod describe，忘了看 kube-system 下 CNI Pod 状态；验证是 kubectl -n kube-system get pods 与节点 /etc/cni/net.d 配置。"
    },
    {
      "q": "节点显示 NotReady，最先应该在哪台机器上执行什么命令排查？",
      "options": [
        "master 上 kubectl delete node 把它移除",
        "到该节点上 systemctl status kubelet 与 journalctl -u kubelet 检查 kubelet 是否运行、证书/配置是否有效",
        "重启整个集群",
        "kubectl scale deployment 增加 kube-proxy 副本"
      ],
      "answer": 1,
      "explain": "NotReady 的判定来自节点状态（node lease 停更），根因多在本机 kubelet：进程挂了、证书过期、容器运行时挂了、swap 被打开。易错点：直接 delete node 是最后手段，会丢掉节点上的 Pod 信息；排查链是 describe node 看 condition 原因 → 上节点看 kubelet 日志 → containerd/kubeadm 检查。"
    },
    {
      "q": "检查 etcd 集群成员健康状态的命令组合是？",
        "options": [
          "etcdctl member list 以及 etcdctl endpoint health --cluster（带证书参数）",
          "kubectl get etcd -n kube-system",
          "etcdctl status --write-out=tables",
          "curl http://localhost:2379/healthz"
      ],
        "answer": 0,
      "explain": "member list 看成员与 leader，endpoint health --cluster 逐端点探活；认证仍需 --endpoints 与证书三元组。易错点：2379 是客户端口且默认 TLS，裸 curl 会失败；2380 是 peer 口；端点 status 的 dbSize 还能顺带看数据量，排查慢查询与压缩问题有用。"
    },
    {
      "q": "本地排查集群内 Service 连通性，把本地端口映射到 Service 的命令是？",
        "options": [
          "kubectl port-forward svc/myapp 8080:80",
          "kubectl expose port myapp",
          "kubectl proxy --port 8080",
          "kubectl attach svc/myapp"
      ],
      "answer": 0,
      "explain": "port-forward 建立本地到 Pod/Service 的隧道（到 Service 时实际选一个后端 Pod），适合快速验证。易错点：kubectl proxy 代理的是 apiserver 的 REST API，不是业务端口；port-forward 不走 kube-proxy 规则，因此它通不能证明 Service 转发正常，排障时要用集群内 Pod curl ServiceIP 全链路验证。"
    },
    {
      "q": "Pod 状态 ImagePullBackOff，describe 中的关键信息应重点看哪里？",
      "options": [
        "Events 里的 Failed to pull ... 报错（NotFound/denied/timeout），据此修镜像名、凭证或网络",
        "containerStatuses 的 restartCount",
        "Pod 的 QoS class",
        "node 的 kernel version"
      ],
      "answer": 0,
      "explain": "ImagePullBackOff 的根因都在 Events：镜像名/标签写错（NotFound）、私有仓库未配 imagePullSecrets（denied）、出口被墙（timeout）。易错点：改了 secret 后 Pod 不会自动重试成功，需要删除 Pod 让其重建；secret 必须与 Pod 同 namespace 且类型为 dockerconfigjson。"
    },
    {
      "q": "要快速查看某 namespace 下所有最近事件并按时间排序，最直接的命令是？",
      "options": [
        "kubectl get events -n myapp --sort-by=.lastTimestamp",
        "kubectl describe namespace myapp",
        "kubectl logs -n myapp --all",
        "kubectl top events"
      ],
      "answer": 0,
      "explain": "events 是排障第一入口，--sort-by=.lastTimestamp 按时间排序避免默认按名字乱序。易错点：默认只列出当前 ns 的事件且保留期约 1 小时，历史问题要靠日志系统；kubectl get events 加 -o wide 可以看到更多字段，配合 --field-selector type=Warning 过滤警告。"
    }
    ],

  // ========== CKS（20 题）==========

  cks: [

    // --- 域1 集群加固（3 题）---

    {
      "q": "关于 RBAC 中 Role 与 ClusterRole 的区别，正确的是？",
      "options": [
                "Role 只作用于单个 namespace，ClusterRole 作用于集群级资源或所有 namespace；把两者绑定给用户时分别用 RoleBinding 与 ClusterRoleBinding",
                "Role 可以跨 namespace 生效，只要用户是集群管理员",
                "RoleBinding 只能绑定 ClusterRole",
                "ClusterRole 是 Role 的升级版，权限一定更大"
      ],
      "answer": 0,
      "explain": "考察最小权限设计：namespaced 资源权限用 Role+RoleBinding 限定在单 ns；ClusterRole 也常配合 RoleBinding 使用（把集群级定义的规则只授予某 ns）。易错点：为了省事全部给 ClusterRoleBinding 是 CKS 的典型反模式；检查 RBAC 用 kubectl auth can-i --list 与 kubectl who-can（krew 插件）。"
    },
    {
      "q": "防止应用 Pod 自动拿到默认 ServiceAccount 的 API token，正确做法是？",
      "options": [
                "把 Pod 的 serviceAccountName 设为空字符串",
                "删除 default ServiceAccount",
                "给 default SA 绑定 deny-all 的 ClusterRole",
                "在 SA 上设置 automountServiceAccountToken: false，必要时再在 Pod 显式开启"
      ],
      "answer": 3,
      "explain": "automountServiceAccountToken: false 写在 ServiceAccount（或 Pod）上即可阻止 kubelet 投射 token；删除 default SA 是不允许的（API 会拒绝创建无 SA 的 Pod）。易错点：v1.22+ 的 token 是投射卷、短期有效，但不挂载才是真正的最小权限；配合检查 Secret 里的旧 token 类型，legacy long-lived token 要清理。"
    },
    {
      "q": "收紧 kube-apiserver 匿名访问的合理做法是？",
      "options": [
                "设置 --insecure-port=0 会自动开启匿名访问",
                "设置 --anonymous-auth=false（并确保认证与 RBAC 就绪），避免未认证请求获得 system:unauthenticated 组的权限",
                "把 kube-apiserver 端口改成非 6443",
                "删除 system:unauthenticated Subject 需要修改源码"
      ],
      "answer": 1,
      "explain": "匿名请求被映射到 system:anonymous 用户，若误给该组绑权限就有暴露面，关闭 anonymous-auth 是 CIS 基线推荐。易错点：改 static pod manifest 后要等 kubelet 重建容器；同时关注 --profiling=false、--audit-log-* 等同级加固项；RBAC 未就绪就关匿名会把自己锁在外面。"
    },

    // --- 域2 系统加固（3 题）---

    {
      "q": "给 Pod 启用默认 seccomp profile 的正确字段是？",
      "options": [
                "在容器里执行 ulimit -c unlimited",
                "securityContext.seccompProfile.type: RuntimeDefault（可放 Pod 级或容器级）",
                "spec.runtimeClassName: RuntimeDefault",
                "annotations: seccomp.security.alpha.kubernetes.io/pod: runtime/default 已是唯一方式"
      ],
      "answer": 1,
      "explain": "v1.19 起 securityContext.seccompProfile 是 GA 字段，type 取 RuntimeDefault 表示使用容器运行时的内置默认 profile（containerd/docker 等），限制危险 syscall。易错点：老的注解方式已废弃；RuntimeDefault 是 seccompProfile.type 的一个取值，与字段 runtimeClassName（填 RuntimeClass 名，用于接 gVisor/Kata 等沙箱运行时）名字相近但用途完全不同，极易混淆。"
    },
    {
      "q": "容器安全上下文要实现“root filesystem 只读，可写 /tmp”，正确的组合是？",
      "options": [
                "readOnlyRootFilesystem: true 并挂一个 emptyDir 到 /tmp",
                "以 root 运行并 chmod 777 /tmp",
                "readOnlyRootFilesystem: true 即可，/tmp 天然可写",
                "挂 hostPath /tmp"
      ],
      "answer": 0,
      "explain": "readOnlyRootFilesystem 让镜像层不可写，应用要写临时文件必须显式提供 emptyDir（可加 medium: Memory）。易错点：应用崩溃排查时发现是写 /var/log 被拒——只读根文件系统下所有可写路径都要规划；这是 CKS 减少篡改面的标准姿势，配合 drop 能力效果更好。"
    },
    {
      "q": "在 Ubuntu + containerd 节点上为 Pod 启用 AppArmor profile，正确的流程是？",
      "options": [
                "把 profile 文件放进 Pod 的 ConfigMap 挂载即可生效",
                "AppArmor 只支持 Docker，containerd 用不了",
                "在 Pod securityContext 里写 appArmorProfile 字段即可，节点无需准备",
                "先在节点上 apparmor_parser 加载 profile，再给 Pod 打注解 container.apparmor.security.beta.kubernetes.io/<container>: localhost/<profile>（v1.30 前的注解方式）"
      ],
      "answer": 3,
      "explain": "AppArmor 是节点级 LSM：profile 必须先存在于运行 Pod 的节点上（apparmor_parser -r 文件），调度器在 v1.30 之前通过注解感知；Pod 被调度到未加载 profile 的节点会失败。易错点：以为像 seccomp 一样是纯 API 字段；对默认 profile 可用 runtime/default，自定义则必须逐节点加载。"
    },

    // --- 域3 减少微服务漏洞面（4 题）---

    {
      "q": "容器需要绑定 80 端口但不给 root，最佳做法是？",
      "options": [
                "给容器 privileged: true 再用 sudo 降权",
                "以 root 运行容器并保留全部能力",
                "把端口改成 8080 并用 iptables 在节点上转发（无需任何特权）",
                "capabilities: drop: [ALL] 加上 add: [NET_BIND_SERVICE]，并以非 root 用户运行"
      ],
      "answer": 3,
      "explain": "CAP_NET_BIND_SERVICE 允许非 root 绑定 1024 以下端口，先 drop ALL 再按需 add 是最小能力原则。易错点：privileged 会挂载宿主机几乎所有能力，是 CKS 明确要避免的；注意默认容器已经 drop 了不少能力，但显式 drop ALL 更可审计，并且 allowPrivilegeEscalation: false 应同时设置。"
    },
    {
      "q": "强制容器以非 root 运行的字段组合是？",
      "options": [
                "readOnlyRootFilesystem: true",
                "securityContext.runAsNonRoot: true（配合镜像内有非 root 用户或 runAsUser）",
                "spec.hostNetwork: false",
                "imagePullPolicy: Never"
      ],
      "answer": 1,
      "explain": "runAsNonRoot: true 让 kubelet 校验容器进程 UID 非 0，否则拒绝启动；镜像本身 ENTRYPOINT 是 root 时需要 runAsUser 指定 UID（如 1000）。易错点：只改 Dockerfile 的 USER 而不在 securityContext 里声明，无法防止被覆盖；runAsGroup、fsGroup 影响文件组权限，别混为一谈。"
    },
    {
      "q": "限制某组 Pod 只能访问同 namespace 内指定端口的 Pod，应该用？",
      "options": [
                "RBAC Role",
                "ServiceAccount",
                "NetworkPolicy（ingress/egress 规则 + podSelector/namespaceSelector 组合）",
                "PodDisruptionBudget"
      ],
      "answer": 2,
      "explain": "微服务间东西向流量的最小化靠 NetworkPolicy：默认 deny all，再按 selector 精确放行（DNS 的 53 也要记得放行）。易错点：把 RBAC 当网络限制——RBAC 管 API 权限不管数据面；egress 全 deny 后连 kube-dns 解析都失败是新手必踩坑，需允许 kube-system namespace 的 53/UDP+TCP。"
    },
    {
      "q": "对不受信任的负载提供更强隔离，应选用？",
      "options": [
                "把 Pod 放到单独的 namespace",
                "privileged: false 就足够了",
                "runtimeClassName 指向 gVisor（runsc）或 Kata Containers 等沙箱运行时",
                "给 Pod 加多个 taint"
      ],
      "answer": 2,
      "explain": "gVisor 在用户态实现内核接口、Kata 用轻量 VM，都能显著缩小内核攻击面，Pod 通过 runtimeClassName 选择节点上注册的 RuntimeClass。易错点：普通 namespace 隔离不隔离内核；需要先在节点装运行时并注册 RuntimeClass 对象，调度器会把 Pod 调到支持该 class 的节点（scheduling 字段）。"
    },

    // --- 域4 供应链安全（4 题）---

    {
      "q": "固定镜像到不可变版本的写法是？",
      "options": [
                "image: nginx@sha256:<digest>",
                "image: nginx（不带标签）",
                "image: nginx:v1.*",
                "image: nginx:latest"
      ],
      "answer": 0,
      "explain": "@sha256 digest 引用内容寻址，任何字节变化都会导致拉取失败，能防止 tag 被覆盖后的供应链投毒。易错点：tag 是可变的，latest 与 v1.2 都可能被重推；生产建议 digest 固定 + admission 校验，调试时 digest 与 tag 可并存（nginx:1.25@sha256:...）。"
    },
    {
      "q": "部署前扫描镜像漏洞的常用工具是？",
      "options": [
                "kube-bench",
                "docker inspect --vulns",
                "trivy image <image>",
                "kubectl scan image"
      ],
      "answer": 2,
      "explain": "Trivy 扫镜像层内的包漏洞与密钥泄漏，输出按严重度分级，CKA/CKS 场景常见于 CI 卡点。易错点：kube-bench 是跑 CIS 基线检查节点配置的，不是镜像扫描；扫描应放进构建流水线并配合策略（如阻断 CRITICAL），部署后再扫属于事后补救。"
    },
    {
      "q": "镜像内容不含 shell 与包管理器、攻击面最小的方案是？",
        "options": [
                    "ubuntu:latest 并卸载 apt",
                    "把二进制静态编译后仍放进 debian:stable",
                    "distroless 或 scratch 基础镜像",
                    "alpine 加上 bash"
      ],
      "answer": 2,
      "explain": "distroless 只带运行时依赖（如 glibc）不含 shell/apk/apt，攻击者即便 RCE 也难以落地进行后续动作。易错点：排查需要 exec sh 时 distroless 会失败，这是安全的代价，调试可用临时 debug 镜像 sidecar（kubectl debug）；最小镜像同时还能减小漏洞扫描面。"
    },
    {
      "q": "确保集群只运行经过签名的镜像，合理的机制是？",
      "options": [
                "依赖网络边界防火墙即可",
                "把镜像放在公有仓库并开匿名拉取",
                "在 kubelet 里开启 --verify-signature",
                "部署 admission 策略（Kyverno/OPA Gatekeeper 或镜像验证 webhook）校验 cosign 签名，配合私有 registry 与 imagePullSecrets"
      ],
      "answer": 3,
      "explain": "供应链准入要在 apiserver 的 admission 阶段做：Kyverno/Gatekeeper 校验镜像仓库白名单与 sigstore/cosign 签名，不满足即拒绝创建 Pod。易错点：kubelet 没有内置签名校验开关；签名与 registry 凭证是两件事——imagePullSecrets 只解决“能不能拉”，不解决“内容是否可信”。"
    },

    // --- 域5 监控、日志与运行时安全（6 题）---

    {
      "q": "审计策略中 AuditLevel 为 Request 的含义是？",
      "options": [
                "记录事件元数据与请求体，但不记录响应体（RequestResponse 才记录响应体）",
                "只记录元数据（Metadata 级别）",
                "记录完整请求与响应体",
                "不记录任何内容"
      ],
      "answer": 0,
      "explain": "四级从少到多：None（不记）、Metadata（只记元数据如 user/verb/resource）、Request（元数据+请求体）、RequestResponse（再加响应体）。易错点：把 Request 与 RequestResponse 记反；策略按 rules 首条匹配生效，建议对 Secret/PVC 详情用 Metadata 降级、对 exec/attach 等敏感动词用 Request 级记录。"
    },
    {
      "q": "启用 apiserver 审计日志需要配置哪些内容？",
      "options": [
                "kubectl edit cm audit-config -n kube-system",
                "审计默认开启，无需配置",
                "--audit-policy-file 指向策略文件，并配置 --audit-log-path（或 webhook 后端）；策略文件需提前存在",
                "只需创建 AuditPolicy CRD 对象"
      ],
      "answer": 2,
      "explain": "审计是 apiserver 启动参数驱动的：policy 文件必须预先放好（static pod 挂载进 manifest），否则 apiserver 起不来。易错点：改完 manifest 要确认 Pod 重建成功；日志默认 append，还有 --audit-log-maxage/maxsize 等轮转参数；题目常要求把 exec 类操作记入指定文件。"
    },
    {
      "q": "要审计“谁在容器里执行了命令”，策略文件的 verbs/resources 应写成？",
      "options": [
                "verbs: [create]，resources: [pods/exec]（group 为空 core 组），level 用 Request 或 RequestResponse",
                "verbs: [exec]，resources: [containers]",
                "verbs: [watch]，resources: [events]",
                "verbs: [get]，resources: [pods]"
      ],
      "answer": 0,
      "explain": "kubectl exec 在 API 层是对 pods/exec 子资源发 POST（verb=create），请求体里的 command 就是具体命令。易错点：把 verb 写成 exec——审计里没有这个动词；子资源写作 pods/exec 或 pods/attach，配合 userGroups 排除系统账号可减少噪音。"
    },
    {
      "q": "Falco 在运行时安全里的角色是？",
      "options": [
                "做网络七层防火墙",
                "基于内核态事件（syscall/内核模块或 eBPF）实时检测容器异常行为（如 shell 启动、写 /etc、加密货币进程）并告警",
                "扫描镜像漏洞",
                "管理 RBAC"
      ],
      "answer": 1,
      "explain": "Falco 是运行时威胁检测引擎：驱动层抓 syscall，规则引擎匹配宏/条件，输出告警（stdout/webhook）。易错点：它与镜像扫描（事前）、NetworkPolicy（网络面）互补而不是替代；规则由 macro+condition+output 构成，考试常考改规则、测规则（falco -c 配置测试事件）。"
    },
    {
      "q": "把容器日志按节点集中收集的推荐部署方式是？",
        "options": [
                    "每个应用自己把日志推到 ES",
                    "用 kubectl logs 定时轮询并落盘",
                    "把日志写到 emptyDir 由侧车 scp 出去",
                    "DaemonSet 跑日志 agent（如 Fluent Bit/filebeat），读 /var/log/pods 与 /var/log/containers 下节点日志"
      ],
      "answer": 3,
      "explain": "节点级 agent（DaemonSet）+ 容器标准输出/错误落盘（/var/log/pods/<ns>_<pod>_<uid>/<container>/*.log，/var/log/containers 是软链）是最经典架构。易错点：日志轮转由容器运行时负责，agent 要容忍轮转造成的短暂缺行；应用写文件而不写 stdout 会让 kubectl logs 看不到任何东西。"
    },
    {
      "q": "检测是否有 Pod 挂载了 hostPath 导致的逃逸风险，最直接的巡检命令是？",
        "options": [
                    "kubectl get nodes -o wide",
                    "kubectl get pods -A -o jsonpath 检查 spec.volumes[].hostPath 字段并输出 Pod/路径",
                    "kubectl describe sa default",
                    "kubectl top pods -A"
      ],
      "answer": 1,
      "explain": "hostPath 把节点目录暴露给容器，挂 /、/var/run/docker.sock 等是典型逃逸路径，巡检就是按字段过滤。易错点：只盯 securityContext 忽略卷挂载面；配套策略是 admission 拒绝 hostPath（或要求前缀白名单），运行时用 Falco 监控对敏感路径的写入。"
    }
    ],

  // ========== 基础：Docker + K8s（20 题）==========

  basics: [

    // --- Docker 基础（10 题）---

    {
      "q": "Docker 容器的隔离主要依靠什么内核机制实现？",
      "options": [
                "每个容器一个独立内核",
                "Linux namespace（隔离 pid/net/mnt/uts/ipc/user 等视图）配合 cgroup（限制资源）",
                "chroot 单独实现全部隔离",
                "Hypervisor 提供的硬件虚拟化"
      ],
      "answer": 1,
      "explain": "容器本质是共享宿主内核、被 namespace 划视图、被 cgroup 限额的进程组，这是与 VM 的根本区别。易错点：以为容器里有独立内核（所以内核漏洞会横向影响容器）；chroot 只换根目录视图，隔离强度远不如 namespace 组合。"
    },
    {
      "q": "关于镜像分层与容器可写层，正确的是？",
      "options": [
                "镜像层数不影响任何行为，可以无限叠加",
                "镜像的每一层都是只读的，多个容器可共享同一份镜像层；容器运行时的写入发生在自己独占的可写层（overlay2  upperdir）",
                "可写层在容器内写的数据会自动合入镜像",
                "每个容器都会复制完整的镜像文件，互不共享"
      ],
      "answer": 1,
      "explain": "联合文件系统（overlay2）把只读 lower 层叠起来加一个可写 upper 层，copy-on-write 让同镜像多容器节省磁盘与内存页缓存。易错点：容器删除可写层即丢数据（持久化要用 volume）；docker commit 才会把可写层固化为新镜像层。"
    },
    {
      "q": "Dockerfile 中 CMD 与 ENTRYPOINT 的关系，正确说法是？",
      "options": [
                "两者必须同时出现否则构建失败",
                "ENTRYPOINT 只能是 shell 脚本",
                "ENTRYPOINT 定义固定入口可执行文件，CMD 提供默认参数；docker run 追加的参数会替换 CMD 而不替换 ENTRYPOINT（exec 形式下）",
                "CMD 会覆盖 ENTRYPOINT"
      ],
      "answer": 2,
      "explain": "exec 形式下最终命令是 ENTRYPOINT + CMD 拼接，运行时给的位置参数顶掉 CMD，这让镜像既开箱即用又可传参。易错点：shell 形式（ENTRYPOINT sh -c '...'）会丢信号处理，PID 1 是 sh 导致 SIGTERM 收不到；写 Chart/YAML 时 args 对应的就是 CMD 位。"
    },
    {
      "q": "COPY 与 ADD 指令的区别，最需要记住的一点是？",
      "options": [
                "ADD 支持自动解压本地 tar 与远程 URL，有隐式行为；拷贝本地文件应优先用 COPY，行为可预期",
                "COPY 支持远程 URL，ADD 不支持",
                "ADD 只能用于构建阶段，运行时必须用 COPY",
                "两者完全等价"
      ],
      "answer": 0,
      "explain": "最佳实践是默认 COPY，只在需要自动解压 tar 时用 ADD；远程 URL 下载不会解压且不走缓存校验，应改用 RUN curl/ADD 后固定。易错点：ADD 一个 context 外的路径会直接报错（build context 限制），而多阶段构建里 COPY --from=stage 才是拷构建产物的姿势。"
    },
    {
      "q": "docker run -m 512m 限制内存后，容器超限时的行为是？",
      "options": [
                "内核 cgroup 内存控制器触发 OOM killer，容器主进程被 kill（exit code 137）",
                "容器进程被暂停等待内存释放",
                "只是统计告警，不做任何限制",
                "自动扩容到宿主机可用内存"
      ],
      "answer": 0,
      "explain": "cgroup v1/v2 的内存上限触发 OOM，退出码 137 = 128 + 9（SIGKILL），K8s 里对应 OOMKilled 状态。易错点：--memory-swap 与 swap 语义容易绕晕（swap 为 -1 或 2x 时的行为不同）；JVM 等不吃 cgroup 的老程序要显式设置堆上限。"
    },
    {
      "q": "默认 bridge 网络下容器访问外网，流量路径是？",
      "options": [
                "通过 docker proxy 用户态进程逐包转发",
                "每个容器直接从物理网卡抓 IP",
                "容器 veth 接到 docker0 网桥，经宿主机 iptables SNAT/MASQUERADE 出去",
                "容器不能访问外网"
      ],
      "answer": 2,
      "explain": "默认是 veth pair + docker0 + netfilter 源地址伪装，这正是理解 K8s Pod 网络（Calico veth + iptables/ipvs MASQUERADE）的前置知识。易错点：-p 发布端口在 docker-proxy 与 iptables DNAT 两条路径间选择（localhost 访问走 proxy）；自定义 bridge 才有内嵌 DNS，默认 bridge 用 /etc/hosts。"
    },
    {
      "q": "volume 与 bind mount 的区别是？",
      "options": [
                "volume 由 Docker 管理（存放在 /var/lib/docker/volumes），适合持久数据与迁移；bind mount 直接挂宿主任意路径，依赖宿主目录结构",
                "volume 不能被多个容器共享",
                "bind mount 由 Docker 管理存储位置",
                "两者没有区别"
      ],
      "answer": 0,
      "explain": "volume 生命周期独立于容器、内容与宿主路径解耦；bind mount 方便开发时挂源码，但把宿主目录结构泄漏进运行时。易错点：匿名 volume 会堆积（docker volume prune 清理）；K8s 里 emptyDir 近似临时卷、hostPath 近似 bind mount，映射关系要建立起来。"
    },
    {
      "q": "docker stop 的默认停止流程是？",
      "options": [
                "先发 SIGTERM，默认等待 10 秒仍未退出再发 SIGKILL",
                "发 SIGQUIT 并不等待",
                "先发 SIGINT 再发 SIGHUP",
                "直接发 SIGKILL"
      ],
      "answer": 0,
      "explain": "优雅停止依赖进程正确处理 SIGTERM（清理、flush、反注册），K8s 同样是 SIGTERM + terminationGracePeriodSeconds（默认 30s）后 SIGKILL。易错点：docker kill 才是立即 SIGKILL；shell 形式 ENTRYPOINT 的 PID 1 是 sh，不转发信号，应用收不到 TERM 是“停不干净”的经典原因。"
    },
    {
      "q": "nginx:1.25 这种 tag 与 digest 的区别，正确理解是？",
      "options": [
                "tag 与 digest 一一对应且都不可变",
                "本地镜像的 IMAGE ID 就是 digest",
                "digest 会随拉取时间变化",
                "tag 是可变的指针，随时可能被仓库重推指向新内容；digest（sha256）对内容寻址，不可变"
      ],
      "answer": 3,
      "explain": "同一 tag 可被覆盖推送，所以生产与 CKS 场景强调 digest 固定；镜像 ID 是本地配置 hash，不是 registry 层内容的 digest。易错点：docker images 里 <none> tag 是悬空镜像（旧层失去 tag），与多架构 manifest list 的 digest 概念也不相同，pull 按 tag 时实际经过 manifest digest 校验。"
    },
    {
      "q": "Docker 主机的存储驱动 overlay2 中，容器读文件时的查找顺序是？",
      "options": [
                "把所有层合并成新文件再读",
                "从可写层（upper）向下逐层找，命中即停；三层都命中时最上层的生效（copy-on-write）",
                "随机选择一层读取",
                "只读镜像层优先生效"
      ],
      "answer": 1,
      "explain": "overlay 语义是“上遮下”：upperdir 覆盖 lowerdir，写镜像层文件触发 copy-up 到可写层。易错点：删除 lower 层文件会生成 whiteout 标记而非真删；大文件在层间修改会导致层膨胀，RUN 指令合并清理（rm 与安装同层）能让镜像更小。"
    },

    // --- K8s 基础（10 题）---

    {
      "q": "关于 namespace 的作用，正确的是？",
      "options": [
                "namespace 只影响 kubectl 输出分组",
                "在物理上隔离节点的计算资源",
                "每个 namespace 分配独立网络与独立 apiserver",
                "划分 API 对象的作用域与配额/策略边界（如 ResourceQuota、RBAC、NetworkPolicy），但节点、PV 等集群级资源不属于任何 namespace"
      ],
      "answer": 3,
      "explain": "namespace 是逻辑作用域：同名 Deployment 可在不同 ns 共存，配额与策略挂 ns；而 node、PV、StorageClass 是集群级。易错点：--all-namespaces 查不到集群级对象变化这种直觉是错的；ns 删除会级联删其中对象，且不可轻易恢复，操作生产前要 double check。"
    },
    {
      "q": "Kubernetes 的最小调度单元是什么？",
      "options": [
                "Deployment",
                "Pod（可含一个或多个共享网络与存储的容器）",
                "容器",
                "Node"
      ],
      "answer": 1,
      "explain": "调度器按 Pod 整体选节点，Pod 内容器共享 network namespace（同一 IP、localhost 互通）和可选的 volume。易错点：把 Pod 等同于容器——多容器 Pod 的 sidecar 模式（代理、日志收集）正依赖这种共生；同一 Pod 的容器一定同节点，这也是“两个强耦合容器要不要拆”的判断依据。"
    },
    {
      "q": "Deployment、ReplicaSet、Pod 的关系是？",
      "options": [
                "Deployment 直接管理 Pod，不经过 ReplicaSet",
                "三者互相独立",
                "Deployment 管理 ReplicaSet，ReplicaSet 保证 Pod 副本数；滚动更新时 Deployment 新建 RS 并逐步缩旧 RS",
                "ReplicaSet 管理 Deployment"
      ],
      "answer": 2,
      "explain": "分层控制：Deployment 提供版本与回滚，RS 提供副本维持，Pod 是运行体；rollout 时新旧 RS 并存，扩一个缩一个是默认策略。易错点：手改 RS 副本会被 Deployment 的期望值纠正；回滚就是把旧 RS 的 replicas 拉回来，kubectl rollout history 对应的就是历史 RS。"
    },
    {
      "q": "Service（ClusterIP 类型）的虚拟 IP 数据面路径是？",
      "options": [
                "由 etcd 维护连接表转发",
                "由 CoreDNS 做四层代理",
                "kube-proxy 在各节点写 iptables/IPVS 规则，把发往 ClusterIP 的流量 DNAT 到某个后端 Pod，流量不经过 apiserver",
                "流量先到 apiserver 再由它转发"
      ],
      "answer": 2,
      "explain": "Service 是规则不是进程：kube-proxy watch Service/EndpointSlice，规则在所有节点一致，因此任意节点访问 ClusterIP 都行。易错点：kube-proxy 挂了的表现是规则陈旧（新 Service 不通）；理解了这条链路，K8s 网络排障（conntrack 表满、endpoint 空、规则缺失）就有了顺序。"
    },
    {
      "q": "kube-proxy 的 IPVS 模式相对 iptables 模式的主要优势是？",
      "options": [
                "大量 Service 场景下规则查找是 O(1) 哈希，更新与转发性能显著优于线性遍历的 iptables 规则链",
                "IPVS 模式下不需要 EndpointSlice",
                "IPVS 支持七层路由",
                "IPVS 不依赖内核模块"
      ],
      "answer": 0,
      "explain": "iptables 模式规则数随 Service×Pod 增长呈线性膨胀，大规模集群同步与匹配都变慢；IPVS 用哈希表与连接复用（需要 ipset 配合）。易错点：两者都只做四层，七层是 Ingress/controller 的活；IPVS 提供多种负载均衡算法（rr/lc/sh），要内核加载 ip_vs 模块。"
    },
    {
      "q": "Service 如何确定后端 Pod 集合？",
      "options": [
                "由 Deployment 主动注册",
                "通过 selector 匹配 Pod label，把 ready 且端口吻合的 Pod IP:targetPort 写入 Endpoints/EndpointSlice 对象",
                "按创建时间顺序取最近创建的 Pod",
                "随机选节点上的所有 Pod"
      ],
      "answer": 1,
      "explain": "endpoint controller 维护地址列表，readiness 不通过的 Pod 不会进列表，所以“Pod Running 但 Service 不通”先查 endpoints。易错点：targetPort 可以是数字或 Pod 里定义的端口名（named port），写名时以容器端口名为准；无 selector 的 Service 可手工填 endpoints（对接外部服务）。"
    },
    {
      "q": "ConfigMap 以环境变量和以 volume 两种方式注入，更新后的表现差异是？",
      "options": [
                "环境变量方式会更新，volume 方式不会",
                "两种方式都不会更新，必须重建 Pod",
                "两种方式都会实时生效",
                "volume 注入会周期性（同步周期内）刷新文件内容；环境变量注入只在 Pod 启动时确定，之后 ConfigMap 更新不会生效"
      ],
      "answer": 3,
      "explain": "kubelet 同步周期（默认约 1 分钟）内 volume 里的文件会被替换（symlink 原子切换），应用要自己 watch/inotify；env 是启动时快照。易错点：subPath 挂载的文件不会随 ConfigMap 更新；多数应用仍需要滚动重启（kubectl rollout restart）来吃到新配置。"
    },
    {
      "q": "kubectl exec 进入容器，底层链路是？",
      "options": [
                "kubectl 直接连 Pod IP",
                "kubectl 通过 etcd 中转流数据",
                "kubectl -> apiserver（pods/exec 子资源，POST）-> 该节点 kubelet -> 容器运行时 exec API，数据走 SPDY/WebSocket 流",
                "kubectl 经 kube-proxy 转发"
      ],
      "answer": 2,
      "explain": "exec 的流由 apiserver 到 kubelet 的通道承载，kubelet 调 CRI（containerd）进入容器，这正是审计日志记录 verbs=create resources=pods/exec 的原因。易错点：网络不通不影响 exec（不走 Pod 网络），但 kubelet 或运行时异常时 exec 失败；exec 属于敏感操作，CKS 里要求审计与告警覆盖。"
    },
    {
      "q": "关于 Pod QoS 等级（Guaranteed/Burstable/BestEffort）与驱逐顺序，正确的是？",
      "options": [
                "QoS 由调度器在调度时动态计算",
                "Guaranteed 的 Pod 永远不会被驱逐",
                "QoS 按命名空间优先级排序",
                "requests 与 limits 全部设置且相等为 Guaranteed；只设部分为 Burstable；都不设为 BestEffort。节点资源紧张时 BestEffort 最先被驱逐"
      ],
      "answer": 3,
      "explain": "QoS 由 Pod 内所有容器的 requests/limits 设置推导，决定节点压力（内存）下的驱逐顺序与 OOM 分数调整：BestEffort 先死，Burstable 按超请求量排序。易错点：想保住关键服务就给 Guaranteed（requests=limits）；QoS 不等于 Priority（preemption 用 priorityClass），两个维度要分开记。"
    },
    {
      "q": "Pod 长期处于 CrashLoopBackOff，含义是？",
      "options": [
                "镜像一直拉不下来",
                "Pod 没有被调度到节点",
                "容器在等待依赖服务就绪",
                "容器反复启动后退出（非 0），kubelet 按指数退避拉起（间隔从 10 秒翻倍到上限 5 分钟）"
      ],
      "answer": 3,
      "explain": "CrashLoopBackOff 是重启退避状态，根因通常是进程错误退出（配置错、依赖连不上、探针失败被杀），用 kubectl logs --previous 看上次退出输出。易错点：ImagePullBackOff 才是拉镜像退避；liveness probe 失败也会表现为 CrashLoop（被 kill 后重启），别只盯应用日志漏看 probe 配置。"
    }
  ],

  // ========== Linux 底座与性能（15 题）==========

  linux: [
    {
      "q": "systemd 中定义文件系统挂载点的专用单元类型是？",
      "options": [
                ".target",
                ".slice",
                ".mount（可搭配 .automount 实现按需挂载）",
                ".device"
      ],
      "answer": 2,
      "explain": "考察 systemd 单元类型分工：service、socket、device、mount、automount、target、timer 等，/etc/fstab 条目会被 systemd-generator 转成 .mount 单元。易错点：以为挂载只能写 fstab——写成 .mount 后可声明依赖与顺序（如 After=network-online.target），systemctl list-units --type=mount 可查看。"
    },
    {
      "q": "systemd 中 Wants= 与 Requires= 的区别是？",
      "options": [
                "Requires 是 Wants 的别名，行为完全一致",
                "Wants 只在开机生效，Requires 只在手动启动时生效",
                "两者都会拉起依赖单元；Wants 是弱依赖（依赖失败不影响本单元），Requires 是强依赖（依赖失败则本单元跟着失败/停止）",
                "Wants 会保证顺序，Requires 不保证任何事"
      ],
      "answer": 2,
      "explain": "依赖与顺序是两回事：Requires 只表达失败联动，不保证先后，需要 After= 配合（Requires + After= 才是『它先起来我再起』）。易错点：只写 Requires 没写 After，两个服务并发启动时序不定，表现为『偶尔起不来』；systemctl list-dependencies 与 journalctl -u xxx 是排查入口。"
    },
    {
      "q": "查看上一次启动周期的日志（如排查机器重启原因），正确的 journalctl 用法是？",
      "options": [
                "journalctl --last-boot",
                "journalctl -b -1",
                "journalctl -f --previous",
                "dmesg --boot=-1 | head"
      ],
      "answer": 1,
      "explain": "-b（--boot）按启动周期过滤，-b -1 指上一次、-b 0 指本次，配 -p err 可只看错误优先级。易错点：dmesg 只看内核环形缓冲区且重启后丢失；跨重启查询需要 journal 持久化（存在 /var/log/journal，Storage=persistent）。"
    },
    {
      "q": "数据库想绕过 page cache 直接读写磁盘（自管共享缓冲池），应使用？",
      "options": [
                "以 O_DIRECT 标志打开文件（可先用 dd oflag=direct 验证磁盘真实性能）",
                "把数据文件放到 /tmp",
                "每次读写前执行 echo 3 > /proc/sys/vm/drop_caches",
                "改用 mmap 映射文件"
      ],
      "answer": 0,
      "explain": "O_DIRECT 绕过 page cache 直达块层（要求偏移与长度按块对齐），数据库自管缓存时用它避免双重缓存与后台刷脏干扰，也是测磁盘真实吞吐的手段。易错点：drop_caches 只是清缓存不是绕过，生产乱用会造成性能抖动；mmap 同样经过 page cache。"
    },
    {
      "q": "一台机器 load average 很高但 CPU idle 也很高，最可能的原因是？",
      "options": [
                "CPU 被虚拟化偷走（steal time）",
                "大量进程处于不可中断睡眠（D 状态），典型是 IO 阻塞；现代内核把 D 状态也计入 load",
                "内存充足属于正常现象，无需处理",
                "load 统计把 user 和 system 相加导致翻倍"
      ],
      "answer": 1,
      "explain": "Linux 的 load 不仅统计 R 状态还统计 D 状态（uninterruptible），所以慢盘、NFS 卡顿会把 load 抬起来而 CPU 很闲。排查：vmstat 1 看 b 列（阻塞进程数）与 wa 列，pidstat -d 找 IO 大户。易错点：只看 load 就判断『CPU 不够』去扩容，方向完全错了。"
    },
    {
      "q": "关于 CFS 调度器中 nice 值的说法，正确的是？",
      "options": [
                "普通用户可以直接把 nice 调到 -20",
                "nice 直接限制进程可用 CPU 的百分比上限",
                "nice 表示进程所在队列的长度",
                "nice 影响进程权重进而影响分得 CPU 时间的比例，范围 -20（最高优先级）到 19（最低）"
      ],
      "answer": 3,
      "explain": "CFS 按 vruntime 公平调度，nice 每差 1 约等于权重差 1.25 倍（1024/820 权重表），只改变相对份额。易错点：想要硬限额应该用 cgroup（cpu.max / cfs_quota），renice 做不到；调低 nice（更优先）需要 root 权限。"
    },
    {
      "q": "短连接密集的服务器上出现数万条 TIME_WAIT，下列理解正确的是？",
      "options": [
                "TIME_WAIT 出现在被动关闭的一端",
                "TIME_WAIT 出现在主动关闭连接的一端，持续 2MSL（Linux 默认 60 秒）；高并发短连接下出现在服务端通常是正常现象，先确认是否真的端口耗尽再谈调优",
                "必须立刻重启服务清理",
                "出现 TIME_WAIT 说明对端异常断开"
      ],
      "answer": 1,
      "explain": "谁主动关闭谁进 TIME_WAIT，作用是让旧报文自然消亡并保证最后的 ACK 可重发。排查用 ss -s 看连接分布；客户端侧才容易端口耗尽（单目标约 2.8 万个可用端口）。易错点：盲目开 tcp_tw_reuse（只对客户端 connect 侧有效且依赖时间戳）；服务端的正解是长连接/连接池，而不是消灭 TIME_WAIT。"
    },
    {
      "q": "Brendan Gregg 的 60 秒巡检里，用于观察每个 CPU 核的使用率与软中断的工具是？",
      "options": [
                "mpstat -P ALL 1",
                "free -m",
                "uptime",
                "iostat -xz 1"
      ],
      "answer": 0,
      "explain": "mpstat -P ALL 1 逐核输出 %usr/%sys/%iowait/%soft 等，单核 softirq 飙高（网卡中断集中）是经典瓶颈；iostat 看的是块设备。整套顺序：uptime → dmesg|tail → vmstat 1 → mpstat → pidstat → iostat → free → sar -n DEV → sar -n TCP。易错点：只看 CPU 总平均会掩盖单核打满（软中断、单线程应用）。"
    },
    {
      "q": "USE 方法对每类资源检查的三个维度是？",
      "options": [
                "Utilization（利用率）、Saturation（饱和度）、Errors（错误）",
                "User、System、Idle",
                "Usage、Speed、Efficiency",
                "Latency、Traffic、Errors"
      ],
      "answer": 0,
      "explain": "USE 是资源侧方法论：对 CPU/内存/网络/磁盘逐类资源问利用率（忙了多久）、饱和度（排队/等待，如 runq、%iowait）和错误（设备级计数器）。「Latency、Traffic、Errors」那组是黄金信号（服务侧）。易错点：把两者混用——黄金信号面向用户视角的服务健康，USE 面向机器资源排查，从告警到定位通常是先信号后 USE。"
    },
    {
      "q": "Linux OOM killer 选择牺牲进程的主要依据是？",
      "options": [
                "badness 分数（综合内存与 swap 占用等，可用 /proc/<pid>/oom_score_adj 调整）",
                "CPU 使用率最高的进程",
                "进程名的字母顺序",
                "随机选择"
      ],
      "answer": 0,
      "explain": "打分综合 oom_score（RSS、swap 占用、root 有加成/减免），oom_score_adj 范围 -1000~1000 可人工干预（-1000 等于免杀，sshd 等关键进程可调负）。排查：dmesg 里搜 Killed process；/proc/<pid>/oom_score 现场查看。易错点：以为 OOM 只杀内存最大的进程；容器里被 OOMKill 的 137 退出码同源。"
    },
    {
      "q": "Linux 主机从加电到 systemd 成为 1 号进程，正确的顺序是？",
      "options": [
                "initramfs 就是最终的根文件系统，内核一直在里面运行",
                "固件（BIOS/UEFI）→ 引导加载器（GRUB2）→ 加载内核与 initramfs → 内核初始化、挂载真实根文件系统 → 启动 systemd（PID 1）",
                "systemd 先启动，再由它加载内核与驱动",
                "GRUB2 直接启动一个 bash，再手工拉起 systemd"
      ],
      "answer": 1,
      "explain": "考察启动链路与 initramfs 的定位：它只是挂真实根之前的临时环境（携带根所在磁盘/RAID/LVM 所需驱动），切换到真实根（switch_root）后即退场。对应学习中心 01-linux 模块「01 · 启动流程与 systemd」一章。易错点：initramfs 损坏或缺少驱动会卡在挂根之前，此时内核已起来、可用 GRUB 菜单按 e 编辑参数救急；systemd-analyze blame / critical-chain 可量化各阶段耗时。"
    },
    {
      "q": "df 显示根分区使用率 95%，但 du -x / 逐层统计远小于该值，最可能的原因是？",
      "options": [
                "du 默认跳过 7 天内未修改的文件",
                "df 统计的是 inode 使用量而不是空间",
                "存在已删除但仍被进程打开的文件：空间要等最后一个 fd 关闭才释放，而 du 按目录树遍历看不到这些文件",
                "文件系统保留块让 du 少算了一半空间"
      ],
      "answer": 2,
      "explain": "经典线上案例：日志被 rm 但进程仍持有句柄，空间不降反涨。排查：lsof +L1 或 ls -l /proc/<pid>/fd | grep deleted 找到持有者，让程序重开文件（如 nginx -s reload 触发 USR1 重开日志）或择机重启进程。对应 01-linux「02 · 文件系统与 IO」一章。易错点：未定位持有者就盲目扩盘，只是推迟问题；kill 进程前先确认业务影响。"
    },
    {
      "q": "关于 vm.swappiness（默认 60）的语义，正确的是？",
      "options": [
                "它表示当前 swap 使用率已达 60%",
                "设为 0 就彻底禁用了 swap",
                "它表示最多允许 60% 物理内存换出到 swap",
                "它是内存回收时倾向换出匿名页（走 swap）还是回收 page cache 的权重（取值 0~200），不是 swap 已用百分比，也不决定 swap 分区大小"
      ],
      "answer": 3,
      "explain": "swappiness 是回收倾向的权重：调低偏向回收 page cache（数据库、延迟敏感服务常设 10 以内），调高更愿意换出匿名页；新内核里 0 也只是极力避免、极端内存压力下仍可能换出，彻底不用 swap 要 swapoff 或不配交换区。对应 01-linux「03 · 内存深入：虚拟内存、page cache 与 OOM」。易错点：把它当百分比做监控告警；K8s 节点通常直接关 swap，此时该参数无意义。"
    },
    {
      "q": "容器（cgroup）内应用平均 CPU 利用率只有 40%，但请求延迟呈周期性毛刺，cgroup 层面最该检查什么？",
      "options": [
                "memory.max 是否触顶",
                "blkio 的设备加权值",
                "cpu.stat 里的 nr_throttled / throttled_usec：CFS 配额（cpu.max）按周期发放，周期内配额用完就被限流到下个周期，平均利用率看不出这种瞬时限流",
                "cpuset 绑定的核心列表"
      ],
      "answer": 2,
      "explain": "CFS bandwidth control 以周期（默认 100ms）为单位发配额，突发把配额提前用光就被 throttle，表现为规律毛刺而均值正常；cgroup v2 的 cpu.stat（v1 的 cpu.stat 里 throttled_time）是直接证据。对应 01-linux「04 · 进程、CFS 调度与负载均值」，K8s 侧对应 04-k8s-fundamentals「11 · 资源与 QoS」。易错点：只看平均利用率得出『CPU 充足』的结论；解法是提高 limit / 多核配额，而非横向扩容。"
    },
    {
      "q": "内核日志出现 nf_conntrack: table full, dropping packet，含义与正确处置是？",
      "options": [
                "TCP TIME_WAIT 到达上限，必须重启业务进程",
                "物理网卡收包队列溢出，需要更换网卡",
                "iptables 规则条数太多，合并规则即可解决",
                "连接跟踪表达到 nf_conntrack_max，无法为新连接建跟踪项而丢包；应先查连接是否泄漏/规格是否不足，再合理调大 nf_conntrack_max 与 hashsize，或对无需跟踪的流量用 raw 表 NOTRACK 豁免"
      ],
      "answer": 3,
      "explain": "netfilter 对每条经 NAT 或状态防火墙的连接建跟踪项，表满即丢弃新建连接，高发于 NAT 网关与 K8s 节点（Service 转发）这类短连接密集场景。排查：对比 sysctl 的 nf_conntrack_count 与 nf_conntrack_max、conntrack -S 看 insert_failed 等统计。对应 01-linux「05 · 内核网络栈：收包路径、netfilter 与 TIME_WAIT」。易错点：只调大 max 是治标（每个表项耗内存），先确认是否存在不复用、不释放的连接泄漏。"
    }
  ],

  // ========== 运维编程：Shell / Python / Go（12 题）==========

  programming: [
    {
      "q": "运维脚本开头写 set -euo pipefail 的含义是？",
      "options": [
                "-e 命令失败即退出、-u 引用未定义变量报错、pipefail 让管道中任一环节失败都算整体失败",
                "-e 输出错误日志、-u 使用 UTF-8、pipefail 失败重试",
                "分别是：扩展模式、超时控制、管道并行",
                "等价于 set -x，只是写法不同"
      ],
      "answer": 0,
      "explain": "三件套是 bash 脚本的最低安全线：默认 bash 只看管道最后一个命令的退出码，curl|jq 时 curl 404 也会被忽略，pipefail 补上这个洞。易错点：set -e 对 if 条件里的命令与 && 链不生效；预期会失败的命令要显式 || true 豁免。"
    },
    {
      "q": "bash 中带引号的 \"$@\" 与 \"$*\" 的区别是？",
      "options": [
                "两者在任何情况下完全等价",
                "\"$@\" 只能用于函数传参",
                "\"$*\" 会丢弃第一个参数",
                "\"$@\" 把每个参数保持为独立个体传给下游，\"$*\" 合并成一个以 IFS 首字符连接的字符串"
      ],
      "answer": 3,
      "explain": "转发参数一律用 \"\"$@\"：展开成 N 个独立词，空格与通配符不丢；\"$*\" 是单串。易错点：不加引号的 $@ 会发生词分割与 glob 展开，参数里的 * 会被展开成文件列表——这是脚本『偶尔炸』的经典来源。"
    },
    {
      "q": "脚本里安全创建临时文件的做法是？",
      "options": [
                "f=/tmp/foo 固定路径",
                "先 touch /tmp/foo.lock 再判断文件是否存在",
                "f=$(mktemp)，并配 trap 在退出时删除",
                "f=/tmp/foo.$$"
      ],
      "answer": 2,
      "explain": "mktemp 生成全局唯一名字并原子创建，避免符号链接攻击与并发覆盖；$$ 只是 PID，同机并发脚本可能撞车。易错点：临时文件要配 trap 'rm -f \"$f\"' EXIT 保证异常退出也清理；『判断再创建』（TOCTOU）在并发下有竞态。"
    },
    {
      "q": "关于 bash 的 [[ ]] 与 [ ]，下列说法正确的是？",
      "options": [
                "[ ] 是关键字而 [[ ]] 是命令",
                "[[ ]] 是 shell 关键字：支持 =~ 正则、&&/||，变量不加引号也不会词分割；[ ] 是命令，参数会被词分割与 glob 影响",
                "[[ ]] 只能用于数值比较",
                "两者行为完全相同，加不加引号都一样"
      ],
      "answer": 1,
      "explain": "[ 是普通命令（test 的别名），变量含空格必须加引号；[[ 是语法结构，内部不做词分割，还能用 =~ 捕获正则（BASH_REMATCH）。易错点：跨平台 POSIX sh 脚本里没有 [[，只能用 [ + 严格引号；数值比较推荐 (( ))。"
    },
    {
      "q": "trap 'cleanup' EXIT 的效果是？",
      "options": [
                "每次函数返回都执行",
                "脚本退出时（无论正常结束、set -e 出错还是被信号终止）都执行 cleanup",
                "仅收到 SIGINT 时执行",
                "仅正常退出时执行"
      ],
      "answer": 1,
      "explain": "EXIT trap 覆盖所有退出路径，是清理锁文件、临时目录、kill 子进程的标准写法。易错点：要稳妥处理 SIGTERM 应写 trap 'cleanup' EXIT TERM（kill 默认发 TERM）；trap 里的变量注意加单引号延迟展开。"
    },
    {
      "q": "shellcheck 在脚本工程化中的定位是？",
      "options": [
                "执行脚本的沙箱环境",
                "格式化工具，等价于 gofmt",
                "静态分析 bash 脚本，报出未加引号、误用 test 等带 SC 编号的可疑模式，可在 CI 里当 lint 卡点",
                "bash 调试器，支持单步执行"
      ],
      "answer": 2,
      "explain": "SC2086（变量未加引号）与 SC2035 这类告警正是脚本『偶尔炸』的根因，shellcheck 给出编号与修法，CI 里配 severity 卡点即可。易错点：它是静态检查，发现不了逻辑错误与运行时数据问题；有意的写法用 # shellcheck disable=SC2086 显式注明。"
    },
    {
      "q": "以下哪个 Python 库不属于标准库、需要 pip 安装？",
      "options": [
                "requests",
                "argparse",
                "json",
                "concurrent.futures"
      ],
      "answer": 0,
      "explain": "json/argparse/concurrent.futures 随解释器发布；requests 是三方库但已是事实标准的 HTTP 客户端（标准库 http.client 太底层、urllib 接口难用）。易错点：发给运维同事的脚本要考虑目标机器能否联网装包——纯标准库脚本 scp 过去就能跑。"
    },
    {
      "q": "用 prometheus_client 写 exporter 的标准姿势是？",
      "options": [
                "导入 start_http_server 与 Counter，定义带 _total 后缀的 Counter，main 里 start_http_port 后台线程 + 主线程更新指标",
                "在 Flask 视图里每次请求实时拼 /metrics 文本",
                "用 Counter 类型但命名为 counter_1",
                "把指标 print 到 stdout 由 cron 采集"
      ],
      "answer": 0,
      "explain": "标准结构：客户端库维护注册表并自动渲染 /metrics 文本，start_http_server(9101) 起独立线程的 HTTP 服务，主线程采集并更新指标。易错点：Counter 必须单调递增且命名以 _total 结尾；Gauge 才能上下浮动；反复重建 Counter 会丢掉累计语义。"
    },
    {
      "q": "Python 用 with open(...) as f 管理文件句柄的主要原因是？",
      "options": [
                "不写 with 会报语法错误",
                "异常路径也会确定性释放资源（等价 try/finally + close），避免句柄泄漏",
                "读写速度更快",
                "with 会自动加文件锁"
      ],
      "answer": 1,
      "explain": "with 调用上下文管理器的 __enter__/__exit__，异常时也保证 close；requests 的 session、线程锁、subprocess.Popen 同理。易错点：长驻脚本裸 open 忘记 close，fd 缓慢增长直到 ulimit 报 Too many open files，排查用 ls /proc/<pid>/fd 或 lsof。"
    },
    {
      "q": "运维工具选 Go 的核心理由与 goroutine 特性，正确的是？",
      "options": [
                "Go 程序必须依赖 JVM 运行",
                "goroutine 就是内核线程，一比一映射",
                "Go 不支持交叉编译",
                "goroutine 是用户态轻量执行流（初始栈 KB 级、可百万级并发），静态编译单二进制，配 client-go 适合写 Operator 与采集工具"
      ],
      "answer": 3,
      "explain": "GMP 调度把海量 goroutine 复用到少量 OS 线程，写并发采集（同时探活几百台主机）成本极低；静态编译 + GOOS/GOARCH 交叉编译让分发只是一个可执行文件。易错点：goroutine 泄漏（channel 永远没人读）会让内存缓慢上涨，pprof 是排查入口。"
    },
    {
      "q": "count=0; cat list.txt | while read -r line; do count=$((count+1)); done 执行后 echo $count 仍是 0，原因是？",
      "options": [
                "read 命令不接受来自管道的输入",
                "count 必须 export 之后才允许在循环里修改",
                "管道右侧的 while 运行在子 shell 里，循环内对变量的修改随子 shell 退出而丢弃；应改为 while read ... done < list.txt 或 done < <(cat list.txt)",
                "while 循环体内不允许做算术运算"
      ],
      "answer": 2,
      "explain": "bash 管道两端各自 fork 子 shell，这是脚本里计数器、累积变量『不生效』的头号原因；重定向喂给 while 则循环留在当前 shell，变量修改得以保留。对应 02-programming「01 · Shell 基础」与「02 · Shell 运维模式」两章。易错点：bash 可用 shopt -s lastpipe（关掉 job 控制时）绕开，但跨平台脚本首选重定向写法；逐行处理大文件用 done < file 也比 cat 管道少一个进程。"
    },
    {
      "q": "用 Go 写的采集器在生产环境 CPU 飙高，语言本身自带的排查路径是？",
      "options": [
                "用 gdb 在生产进程上单步调试",
                "只能加打印日志重新编译发版",
                "Go 不提供性能分析能力，必须采购商业 APM",
                "引入 net/http/pprof（或 runtime/pprof），用 go tool pprof 对 /debug/pprof/profile 采样，定位热点函数并看火焰图"
      ],
      "answer": 3,
      "explain": "net/http/pprof 暴露 /debug/pprof 系列端点：profile 采样 CPU 热点、heap 看内存分配、goroutine 看协数与泄漏，block/mutex 分析锁竞争，均可 go tool pprof 交互式分析。对应 02-programming「05 · Go for SRE」一章。易错点：pprof 端点务必限内网访问（它会暴露运行时细节）；CPU profile 是采样式的，调用栈『越宽』代表越耗 CPU。"
    }
  ],

  // ========== CI/CD 与 IaC / GitOps（20 题）==========

  cicd: [
    {
      "q": "Git 中分支的本质是？",
      "options": [
                "指向某个 commit 的可动指针（ref），创建分支几乎零成本",
                "工作区文件的一份完整拷贝",
                "远端仓库里的一个目录",
                "一种特殊的 tag"
      ],
      "answer": 0,
      "explain": ".git/refs/heads/<name> 里只存 40 个字符的 commit SHA，HEAD 指向当前分支；切分支只是改 HEAD 与索引。易错点：以为切分支要复制文件所以慢——理解 ref 之后，reset --hard origin/main 这类救命操作就不再神秘。"
    },
    {
      "q": "误操作 git reset --hard 丢了刚提交的代码，找回的主要依靠是？",
      "options": [
                "必须立刻执行 git fsck --lost-found 否则彻底丢失",
                "没 push 的提交一定无法恢复",
                "git reflog 记录了 HEAD 的每次移动，从中找到丢失 commit 的 SHA 再 reset/cherry-pick 回来",
                "git stash pop"
      ],
      "answer": 2,
      "explain": "reflog 是本机 HEAD 移动历史（默认保留 90 天），reset/rebase/checkout 都留痕，找到 SHA 后 git reset --hard <sha> 或 git branch rescue <sha> 即可。易错点：真正不可恢复的是被 gc 掉且无引用指向的对象；reflog 只在本机有效，别把它当备份。"
    },
    {
      "q": "git merge 与 git rebase 对历史的差异，正确的是？",
      "options": [
                "两者产出完全相同的提交图",
                "merge 保留分叉历史并新增合并提交；rebase 把提交摘下来重放到目标分支之上，历史线性但改写了提交 SHA",
                "rebase 会新建一个合并提交",
                "merge 会删掉分支上的提交"
      ],
      "answer": 1,
      "explain": "团队协作铁律：未推送的本地提交可以 rebase 换线性历史，已共享的分支不要 rebase（别人基于旧 SHA 的工作会断裂）。易错点：rebase 冲突是逐提交重放，比一次性 merge 更琐碎；方向别搞反——是在特性分支上 rebase master。"
    },
    {
      "q": "GitLab CI 中把前一 stage 的产物交给后一 stage，靠的是？",
      "options": [
                "同一个 runner 自动共享全部文件",
                "把产物 commit 进仓库",
                "job 里 artifacts 声明的路径（后续 job 下载使用，配 needs 可精确拉取）",
                "cache 与 artifacts 完全等价"
      ],
      "answer": 2,
      "explain": "artifacts 上传后在同 pipeline 后续 job 可下载，build→test→deploy 传镜像 tar 或二进制全靠它；cache 用于加速（依赖包），生命周期与语义都不同。易错点：artifacts 默认有 expire_in 过期时间；并行化与按需拉取要配 needs。"
    },
    {
      "q": "GitOps（如 ArgoCD）与传统 CI 推模式部署的本质区别是？",
      "options": [
                "集群内的控制器持续从 Git 拉取期望状态并收敛，Git 是唯一事实来源，集群凭证不必外泄给 CI",
                "GitOps 只是改用 git 存配置，部署仍由 CI 脚本 ssh 进集群执行",
                "拉模式必须依赖 GitHub Actions",
                "两者只是工具名不同"
      ],
      "answer": 0,
      "explain": "控制回路思想：控制器 watch Git 与集群实际状态，diff 后同步，天然具备漂移检测与 git revert 式回滚。易错点：CI 仍然存在（构建镜像、改 manifest 并提交），只是最后一步 apply 从 CI 移交给集群内控制器，因此 CI 不再持有集群写凭证。"
    },
    {
      "q": "ArgoCD 中 automated sync + selfHeal 的效果是？",
      "options": [
                "selfHeal 负责 Pod 崩溃后的自动重启",
                "只做只读比对，不实际变更集群",
                "禁止任何人再修改 Git 仓库",
                "Git 内容变化自动应用，且有人手工 kubectl 改了集群资源后会被自动纠正回 Git 版本"
      ],
      "answer": 3,
      "explain": "syncPolicy.automated 开启自动同步，selfHeal: true 纠正手工修改造成的漂移，prune: true 才会删除 Git 里已移除的资源。易错点：只想观察漂移不自动纠正时只开 automated 不开 selfHeal，用 ArgoCD UI 的 diff 视图复盘更安全。"
    },
    {
      "q": "Ansible 强调的幂等性（idempotency）指？",
      "options": [
                "同一 playbook 多次执行结果一致，已满足的任务显示 ok 而不是 changed",
                "用 shell 模块写的任务天然幂等",
                "每个 task 都必须写 when 条件",
                "playbook 只能运行一次"
      ],
      "answer": 0,
      "explain": "声明式模块（apt、copy、user、file）先比对再改，重复执行无副作用；shell/command 是裸执行，幂等要自己保证（creates/removes 参数或判断再执行）。易错点：playbook 第二遍跑全是 changed，多半是 shell 里的 rm/mkdir/sed 写法，要换成 file/lineinfile 模块。"
    },
    {
      "q": "Terraform state 文件的作用与团队协作要点，正确的是？",
      "options": [
                "apply 操作完全不依赖 state",
                "state 记录资源与配置的映射，是 plan 比对的基线；团队应放远端 backend（S3/OSS 等）并加锁防并发 apply",
                "state 必须提交进 git 由人肉合并",
                "state 只是运行日志，删了也能随时重建"
      ],
      "answer": 1,
      "explain": "Terraform 靠 state 知道哪些资源是自己管的、当前属性如何，丢失后 import 成本极高；远端 backend + state locking 防两人同时 apply 互相覆盖。易错点：state 里明文含敏感字段（数据库密码），要配加密与最小权限，绝不能提交进 Git。"
    },
    {
      "q": "terraform plan 与 apply 的关系是？",
      "options": [
                "plan 会创建资源但打上 plan 标记",
                "apply 无法限定资源范围，只能全量执行",
                "apply 之前不需要 plan，两者完全独立",
                "plan 只做干跑计算并展示变更（+ ~ -/销毁标记），apply 才实际执行；先 review plan 再 apply 是基本纪律"
      ],
      "answer": 3,
      "explain": "plan 是刷新 state 后的三方比对（配置/state/真实云资源）；apply 默认先隐式 plan，救火可用 -target=module.xxx 缩小爆炸半径（常规别依赖）。易错点：CI 里建议 plan 出评论、人工确认后再 apply 的两步流程，防止一把 apply 把生产改飞。"
    },
    {
      "q": "GitHub Actions 中限定只有 main 分支的 push 触发某 workflow，应写？",
      "options": [
                "trigger: main",
                "on: push: tags: [main]",
                "on: push: branches: [main]",
                "on: schedule: cron: main"
      ],
      "answer": 2,
      "explain": "branches 过滤器限定触发分支，配 paths 还能只对指定目录变更触发；PR 检查用 on: pull_request（针对目标分支）。易错点：push 与 pull_request 语义不同，发布流水线通常两个都配——PR 上跑检查、合入 main 后跑部署。"
    },
    {
      "q": "git checkout 到某个历史提交后提示 HEAD detached at <sha>，正确的理解是？",
      "options": [
                "HEAD 文件已损坏，需要 git fsck 修复",
                "HEAD 直接指向该提交而非某个分支；此时的新提交不属于任何分支，切走后只能靠 reflog 找回，继续开发应先 git switch -c 建新分支",
                "仓库进入了只读保护状态，禁止任何提交",
                "本地仓库与远端失去关联，必须重新 clone"
      ],
      "answer": 1,
      "explain": "HEAD 正常指向分支名（分支再指向提交），detached 即直接指向提交；此时产生的提交没有分支引用兜底，切走后成为悬空对象。对应 06-cicd-iac-gitops「01 · Git 深入：对象模型、分支本质与救命操作」一章。易错点：CI 按 tag/commit SHA checkout 天然处于 detached 状态，做构建没问题但不要在其中推新提交；新语法 git switch --detach 与之等价。"
    },
    {
      "q": "GitLab CI 中同一 stage 内多个 job 的执行方式，以及下一 stage 何时开始，正确的是？",
      "options": [
                "同 stage 的 job 严格按 yml 里的书写顺序串行执行",
                "一条 pipeline 全程同时只允许一个 job 运行",
                "下一个 stage 只要任意一个上游 job 成功即开始",
                "同 stage 的 job 默认并行执行（各自分给可用 runner），下一个 stage 要等上一个 stage 的全部 job 成功后才启动"
      ],
      "answer": 3,
      "explain": "stage 是同步屏障：stage 内并行带来速度（依赖多 runner），任一 job 失败则后续 stage 不再启动（除非 allow_failure 豁免）；要跨 stage 按作业级精确依赖、进一步并行，用 needs: 拉成 DAG。对应 06-cicd-iac-gitops「02 · GitLab CI：从 pipeline 概念到多环境交付」一章。易错点：误以为默认串行而把可并行的检查拆进多个 stage 拖慢流水线；实际并行度还受 runner 并发与 resource_group 约束。"
    },
    {
      "q": "Kustomize 中 base 与 overlays 的关系，正确的是？",
      "options": [
                "overlay 是一份独立于 base 的完整资源副本，两者互不相干",
                "base 是带变量的模板，overlay 负责喂值渲染出最终 manifest",
                "overlay 不产生新资源，它是对 base 的一个有序变换（transform）序列；kustomize build 是纯本地计算，同输入必得同输出",
                "一个 base 只能被一个 overlay 引用，跨团队复用必须复制目录"
      ],
      "answer": 2,
      "explain": "对应 06-cicd-iac-gitops「07 · Kustomize」第 2 节：overlay 只是 base 的有序变换序列，渲染是纯函数（无模板引擎、不碰集群），这正是它天然适配 GitOps 的原因（ArgoCD 的 repo-server 内部就是调它渲染）；对应关系是多对多——一个 base 可被 N 个 overlay 引用，overlay 的 resources 还能引用远程 URL。「base 是模板」是 Helm 的心智模型。"
    },
    {
      "q": "kustomization.yaml 里声明 patchesStrategicMerge 时报错 field not found，原因与正确改法是？",
      "options": [
                "kubectl 1.27 起内置 kustomize v5，已移除该顶层字段（旧版本只是废弃警告）；迁移为 patches: - path: xxx.yaml，语义不变",
                "补丁文件语法错误，必须改写成 JSON6902 补丁",
                "Kustomize v5 不再支持任何形式的补丁，只能换用 Helm",
                "需要降级 kubectl 到 1.26 才能继续使用该字段"
      ],
      "answer": 0,
      "explain": "「07 · Kustomize」常见坑首条：kubectl 1.27 起内置 kustomize v5，patchesStrategicMerge 从“废弃警告”变成“直接报 field not found”；统一后的 patches 字段既能写 strategic merge（path 指向文件或内联对象），也能写 JSON6902（target + patch），语义与旧字段一致。补丁不生效但无报错的另一常见原因是补丁缺 metadata.name 或 kind 拼错，静默不命中。"
    },
    {
      "q": "kustomization.yaml 里用 helmCharts 引入第三方 chart，与 helm install 的本质区别是？",
      "options": [
                "两者完全等价，都会在集群里创建 release 记录",
                "helmCharts 渲染的资源由 helm 继续管理生命周期",
                "helmCharts 只是不需要 chart 仓库地址，安装流程相同",
                "helmCharts 只渲染出资源、没有 release 概念；hooks 类注解没有执行者，回滚靠 Git revert、删除靠 kubectl delete -k"
      ],
      "answer": 3,
      "explain": "「07 · Kustomize」5.2 节对比表：helm install 的产物是 release Secret（sh.helm.release.v1.*）+ 资源，生命周期走 helm upgrade/rollback/uninstall，hooks 会真的执行；helmCharts 只做“渲染”——没有 release 记录、hook 类注解没有执行者。GitOps 语境下后者更纯粹（Git 是唯一真相），但失去 helm 的版本管理与 hook 能力；混用前务必 kubectl kustomize 过一遍渲染产物（尤其带 hooks 的 chart）。"
    },
    {
      "q": "业界常见的分工格局：自家业务应用与第三方中间件分别用什么管理？",
      "options": [
                "自家业务用 Kustomize 管 base/overlays（任何字段都能覆写、差异显式可 review）；第三方用社区 Helm chart 装（别人维护、版本化、可升级）",
                "两者都用 Helm，统一进 chart 仓库管理",
                "两者都用 Kustomize，把 chart 内容复制进自己仓库再打补丁",
                "自家业务用 Helm 拿分发能力，第三方用 Kustomize 打补丁"
      ],
      "answer": 0,
      "explain": "「07 · Kustomize」5.1 与「08 · Helm」第 1 节的一句话分工：Kustomize 的参数自由度是“任意字段都能覆写”，代价是没有分发能力；Helm 只能改 chart 作者暴露的 values 键，换来成熟的版本化分发。反向选择会同时吃到两条路线的短处；把 chart 内容复制进自己仓库则失去升级能力，是被明确反对的做法。"
    },
    {
      "q": "Helm 3 中一个 release 的版本历史（元数据）存储在哪里？",
      "options": [
                "master 节点的本地文件（如 /root/.helm 目录）",
                "Tiller 服务维护的专用数据库",
                "release 所在命名空间的一个 Secret（sh.helm.release.v1.<release>.v<N>，内容为 gzip+base64 的完整产物）",
                "chart 仓库的 OCI registry 里"
      ],
      "answer": 2,
      "explain": "「08 · Helm」第 5 节：每次 install/upgrade 把整个 release（chart + values + 渲染产物）gzip+base64 后存入业务命名空间的 Secret sh.helm.release.v1.<name>.v<N>（type=helm.sh/release.v1），revision 号 N 自增。因此 kubectl get secret 就能审计装了什么，helm get manifest/values 可还原“当时装了什么”；Helm 2 的 Tiller 单点在 Helm 3 已废除。"
    },
    {
      "q": "helm upgrade --atomic 的语义是？",
      "options": [
                "只渲染不安装，相当于 helm template",
                "只是 --wait 的别名，等待时间更长而已",
                "升级前强制先做一次 helm diff 供人工确认",
                "失败时自动 rollback 到上一个 deployed revision（隐含 --wait），坏版本落地即回退，命令以非零退出码返回"
      ],
      "answer": 3,
      "explain": "「08 · Helm」：--wait 把“成功”的定义从“资源已 apply”改成 Deployment available / PVC bound / Job complete；--atomic = --wait + 失败自动 rollback，把“人工发现故障再手动回滚”的窗口压缩到零。注意它只看 K8s 层健康信号，不能替代流水线测试；大 chart 配套显式 --timeout（默认 5m）。"
    },
    {
      "q": "Helm values 的覆盖优先级（低 → 高），正确的是？",
      "options": [
                "--set < -f 文件 < chart 内 values.yaml 默认值",
                "chart 内 values.yaml 默认值 < -f 文件（多个时后者覆盖前者同名键）< --set",
                "-f 文件 < chart 内 values.yaml 默认值 < --set",
                "三者优先级相同，按文件名字母序决定"
      ],
      "answer": 1,
      "explain": "「08 · Helm」2.2 节：默认值 < -f（多个 -f 按传入顺序，后者覆盖前者同名键）< --set 最高。生产纪律是 values 分层（values-base.yaml + values-prod.yaml）而不是养一个巨型文件；helm get values <release> 查看最终生效的用户值。子 chart 场景再叠一层：子 chart 自己的 values.yaml < 父 values 里的子 chart 段 < -f/--set。"
    },
    {
      "q": "关于 Helm hook 与普通 Job 的关系，正确的说法是？",
      "options": [
                "hook 只能是 Job 类型，普通 Job 不能出现在 chart 里",
                "hook 是带 helm.sh/hook 注解的任意资源，Helm 在生命周期时机创建它并等待完成（Job 看成功、Pod 看 Ready）才继续主流程；迁移类 hook 几乎总用 Job，hook 失败则整个 install/upgrade 失败",
                "hook 由 CronJob 定时触发，与 install 生命周期无关",
                "chart 里的普通 Job install 时 Helm 也会等它成功才返回"
      ],
      "answer": 1,
      "explain": "「08 · Helm」第 4 节：注解只是“时机”标记，资源类型任选；Job“跑一次直到成功”的语义与迁移吻合，Deployment 没有终点做 hook 永远等不完，CronJob 不能当 hook。hook 失败或等待超时会让整个 install/upgrade 失败、主资源不更新——这正是 pre-upgrade 迁移没成功就不动应用的保护逻辑，也是“安装卡住”排障时先看 jobs/pods 的原因；普通 Job 只是 chart 资源，Helm 并不等它。"
    }
  ],

  // ========== OpenTelemetry（12 题）==========

  otel: [
    {
      "q": "OpenTelemetry 的三大信号是？",
      "options": [
                "CPU、内存、磁盘",
                "latency、traffic、errors",
                "traces、metrics、logs",
                "events、alerts、dashboards"
      ],
      "answer": 2,
      "explain": "OTel 统一了三支柱的 API/SDK/协议与采集端：trace 由 span 树组成，另有 baggage 传播键值。易错点：别把黄金信号（服务健康视角）与三大信号（遥测数据类型视角）混淆；profile 是推进中的第四信号（以官方文档为准）。"
    },
    {
      "q": "跨服务链路透传的标准头部（W3C Trace Context）是？",
      "options": [
                "trace-id: auto",
                "b3: 1",
                "X-Otel-Span: on",
                "traceparent: 00-<trace-id>-<parent-id>-<trace-flags>"
      ],
      "answer": 3,
      "explain": "W3C Trace Context 用 traceparent 携带 trace-id、父 span id 与采样标志，各语言 SDK 的 propagator 默认对接它，跨语言链路才能串起来。易错点：网关或 mesh 没透传该头部时链路断成多截；对接老系统用 B3 头（X-B3-TraceId）需在 propagator 加兼容。"
    },
    {
      "q": "一个 trace 的正确描述是？",
      "options": [
                "一次告警的事件列表",
                "一个进程的全部指标集合",
                "一台机器上顺序写入的日志行",
                "由共享同一 trace-id 的多个 span 按 parent 关系组成的树，每个 span 记录一次操作的时间与属性"
      ],
      "answer": 3,
      "explain": "span 是最小单元（名称、起止时间、属性、事件、状态），trace_id 串起全部 span，parent span id 决定层级。易错点：调用链图的深度与宽度取决于埋点密度——『链路断』通常是中间组件没传播 context 或没埋点，不是数据丢了。"
    },
    {
      "q": "头部采样与尾部采样的区别是？",
      "options": [
                "头部采样在 SDK/请求入口按比例决定是否记录（省资源，错过的无法回溯）；尾部采样在 Collector 汇总整条 trace 后按结果（含错误、超慢）决定保留",
                "尾部采样必须关闭所有采样",
                "头部采样能保证错误请求 100% 被保留",
                "两者都发生在后端存储层"
      ],
      "answer": 0,
      "explain": "错误/慢请求占比极小，纯比例头部采样会把最需要的样本丢掉；尾部采样用 collector 的 tail_sampling processor 保留 100% error + 小比例正常。易错点：尾部采样要求同一 trace 的 span 汇聚到同一 collector（按 trace_id 路由），Agent→Gateway 架构要提前规划。"
    },
    {
      "q": "OTel Collector 管道的三大组件是？",
      "options": [
                "agent → broker → storage",
                "receivers（接入）→ processors（加工）→ exporters（输出）",
                "scrape → rule → remote_write",
                "input → filter → alert"
      ],
      "answer": 1,
      "explain": "一条 pipeline 声明信号类型与三段组件，常用 processor：batch（必配，减少 RPC 次数）、memory_limiter（防 OOM）、attributes/transform（洗标签）。易错点：extensions（如 health_check）不属于 pipeline；处理器顺序有讲究，memory_limiter 要放最前。"
    },
    {
      "q": "Collector 的 agent 模式与 gateway 模式的部署差异是？",
      "options": [
                "agent 跟随应用就近部署（K8s 里常为 DaemonSet）负责采集与初步处理；gateway 独立集中部署，负责聚合、尾部采样与多后端分发、凭证收敛",
                "两者必须成对使用，缺一不可",
                "agent 只能接 metrics，gateway 只能接 traces",
                "gateway 必须部署在每个 Pod 里"
      ],
      "answer": 0,
      "explain": "经典两级：应用 OTLP → agent（DaemonSet）→ gateway → 各后端（Jaeger/Prometheus/Loki 等），后端凭证只在 gateway 收敛。易错点：agent 自身也占资源，要配 memory_limiter 与限额；层级越多链路越长，小规模可以直连 gateway。"
    },
    {
      "q": "OTel Operator 实现无侵入接入的核心机制是？",
      "options": [
                "直接修改应用源码重新编译",
                "Operator 只能部署 Collector，不能做插桩",
                "Instrumentation CR + Pod 注解（instrumentation.opentelemetry.io/*），由 admission webhook 向 Pod 注入 agent 并改写启动参数（Java/Python/Node 等）",
                "必须手工在每个容器里安装 SDK"
      ],
      "answer": 2,
      "explain": "mutation webhook 按语言注入对应的 auto-instrumentation（javaagent、opentelemetry-inject-python 等），应用零改码接入。易错点：注解要写在 Pod 模板（deployment spec.template）上且语言写对；Go 没有通用字节码注入，仍需编译期方案或手工 SDK（以官方文档为准）。"
    },
    {
      "q": "OTLP over gRPC 与 HTTP 的默认端口是？",
      "options": [
                "4317 只支持 HTTP",
                "4317（gRPC）/ 4318（HTTP）",
                "没有默认端口，必须自选",
                "9090 / 9091"
      ],
      "answer": 1,
      "explain": "collector 的 otlp receiver 在 4317（gRPC）与 4318（http/protobuf）两个约定端口监听，K8s Service 直接暴露即可。易错点：容器网络里 HTTP 方式更易穿透（gRPC 需要 HTTP/2 且部分 L7 LB 不支持）；客户端协议要与 receiver 配置一致，否则连接被拒。"
    },
    {
      "q": "W3C Baggage 与 Trace Context 的分工是？",
      "options": [
                "baggage 是 traceparent 的别名",
                "baggage 只能传指标值",
                "traceparent 传播链路标识（trace/span id），baggage 传播业务键值（如 tenant=id），两者独立、都要控制体积与敏感信息",
                "两者都会自动加密传输"
      ],
      "answer": 2,
      "explain": "baggage 让下游拿到『这次请求属于谁』这类上下文，用于给日志与 span 打业务标签，键值跨服务全程携带。易错点：往 baggage 塞大对象或 PII（用户名、token）会放大每跳开销并泄漏敏感信息——先定义白名单再传播。"
    },
    {
      "q": "OTel 里标识『遥测来自哪个服务』的标准资源属性是？",
      "options": [
                "resource 的 service.name（常配 service.version、deployment.environment 等）",
                "指标名的服务前缀",
                "自动生成的 hostname 标签",
                "不需要标识，后端会自动推断"
      ],
      "answer": 0,
      "explain": "resource 描述遥测的产生者，SDK 用 OTEL_SERVICE_NAME 或 resource attributes 配置，后端按 service.name 聚合服务维度视图。易错点：漏配时全部落到 unknown_service，服务列表直接废掉；K8s 里常用 resource detector 自动补 k8s.pod.* 属性。"
    },
    {
      "q": "OTel SDK 中把一个 span 标记为『出错』的标准做法是？",
      "options": [
                "把 traceparent 头里的 trace-flags 置为 0",
                "结束 span 时抛出异常，SDK 会自动捕获并标记",
                "把 span 名称改成以 ERROR_ 开头",
                "span.setStatus 设为 Error（可附描述），并用 span.recordException 把异常类型、消息与堆栈记录为带时间戳的事件"
      ],
      "answer": 3,
      "explain": "状态与异常是两个动作：recordException 写入 exception.type / exception.message / exception.stacktrace 属性的事件，setStatus 才决定后端按什么口径统计错误率；多数自动埋点在捕获异常时会两步都做，手写代码别漏。对应 09-otel「01 · 三大信号与上下文传播」与「02 · 埋点：手动 SDK、自动注入与采样」两章。易错点：只 record 不 setStatus，这条失败请求会从错误率指标里消失；trace-flags 只携带采样位，与错误语义无关。"
    },
    {
      "q": "微服务调用链中上游已对某请求采样（traceparent 的 flags=1），下游服务默认采样器的行为是？",
      "options": [
                "下游必须无条件记录所有请求，没有选择权",
                "默认的 ParentBased 采样器会跟随父上下文的采样决定继续记录，保证整条 trace 完整",
                "采样决定无法跨服务传播，链路必然断成多截",
                "下游按自己的比例独立重新采样，与上游决定无关"
      ],
      "answer": 1,
      "explain": "采样决策编码在 traceparent 的采样位里随上下文传播，各语言 SDK 默认的 ParentBased 采样器读取它做跟随，这是链路不残缺的前提；若各服务独立配置固定比例采样，同一条 trace 就会出现『半截』。对应 09-otel「01 · 三大信号与上下文传播」与「02 · 埋点」的采样小节。易错点：用调小头部采样比例来省成本时，错误链路也被等比例丢弃，应配合 Collector 尾部采样兜底（保错保慢）。"
    }
  ],

  // ========== 日志体系：ELK 与 Loki（11 题）==========

  logging: [
    {
      "q": "结构化日志（如每行一个 JSON）相对纯文本的核心优势是？",
      "options": [
                "人眼阅读速度一定更快",
                "占用空间一定更小",
                "字段可被索引与检索（level、trace_id、user_id），能直接做过滤、聚合与告警",
                "完全不依赖采集器"
      ],
      "answer": 2,
      "explain": "机器可解析是中心化日志的前提：解析失败率与字段缺失率直接决定检索体验，应用侧输出 JSON 比采集端正则解析靠谱得多。易错点：结构化不等于全量输出——敏感字段（token、手机号）要在输出前脱敏，且一行一条。"
    },
    {
      "q": "Elasticsearch 全文检索快，核心原因是？",
      "options": [
                "它把所有日志压进了内存哈希表",
                "倒排索引：term 到文档列表的映射，查询按词直接命中而无需扫描原文",
                "它按时间提前排好了序",
                "它使用了 GPU 加速"
      ],
      "answer": 1,
      "explain": "写入时分词建倒排，查询走 term 字典定位 posting list；这正是 ES 重资源（CPU 分词、内存 segment）的来源。易错点：分词只对 text 字段做，keyword 是整串精确匹配；日志场景要控制字段集与索引模板，否则存储与 heap 都会失控。"
    },
    {
      "q": "经典 ELK 日志管道的正确顺序是？",
      "options": [
                "Filebeat/Fluent Bit 采集 → Logstash 解析富化 → Elasticsearch 存储索引 → Kibana 查询可视化",
                "Kibana 负责落盘，ES 负责画图",
                "Elasticsearch 先抓取，Kibana 再解析",
                "Logstash 直接读取应用磁盘是唯一方式"
      ],
      "answer": 0,
      "explain": "采集端轻量（占用小、断点续传），重的解析富化放 Logstash，检索存储在 ES，展示在 Kibana。易错点：轻量采集器也自带基本解析能力（Filebeat processors / Fluent Bit filter），小场景可以省掉 Logstash 这一层，别为了『标准架构』硬加。"
    },
    {
      "q": "Loki 相对 Elasticsearch 的根本差异是？",
      "options": [
                "Loki 只对标签建索引、正文不索引，查询时再过滤压缩的 chunk，成本低但依赖标签设计且查询要扫描",
                "两者没有实质差异",
                "Loki 索引了全部字段，只是用了更快的算法",
                "Loki 不能存日志，只能转发"
      ],
      "answer": 0,
      "explain": "标签选得好（app、env、namespace 这类低基数）查询才快；把高基数（user_id、trace_id）塞标签会创建海量 stream 打爆 Loki。易错点：正文检索用 |= 是 grep 语义，大时间范围全文搜会慢，先用 label 缩小范围再用 | json / | pattern 提字段。"
    },
    {
      "q": "LogQL 查询『nginx 应用日志中含 error 的行数速率』，正确写法是？",
      "options": [
                "select count(*) from logs where app='nginx' and msg like '%error%'",
                "sum(errors{app=\"nginx\"})",
                "count(logs{app=nginx}) where message like 'error'",
                "rate({app=\"nginx\"} |= \"error\" [5m])"
      ],
      "answer": 3,
      "explain": "先流选择器 {标签} 再行过滤器 |=（包含）/ |~（正则），外套 rate/count_over_time 就变成指标查询，可直接配告警规则。易错点：标签值是精确匹配不是全文搜索；管道后可用 | json 提字段，再按字段过滤与聚合。"
    },
    {
      "q": "Promtail 在 Loki 生态里的角色是？",
      "options": [
                "Grafana 的可视化插件",
                "采集器：发现日志文件、打标签（含 Kubernetes 元数据发现）并推送给 Loki",
                "日志解析的规则引擎",
                "Loki 的存储后端"
      ],
      "answer": 1,
      "explain": "Promtail watch 文件尾部，把 Kubernetes 元数据（namespace/pod/container）变成标签，是 Loki 标签体系的第一现场。易错点：官方重心已转向 Grafana Alloy（Promtail 处于维护状态，以官方文档为准）；标签在采集端决定，事后改标签等于重建索引。"
    },
    {
      "q": "Kubernetes 节点上容器 stdout/stderr 的落盘位置是？",
      "options": [
                "/var/lib/kubelet/logs/",
                "日志不落盘，只存于 etcd",
                "/var/log/containers_only/",
                "/var/log/pods/<ns>_<pod>_<uid>/<container>/*.log（/var/log/containers 是指向它们的软链）"
      ],
      "answer": 3,
      "explain": "容器运行时负责写入与轮转（默认单文件 10MB、保留 5 个），kubelet 的 containerLogMaxSize/MaxFile 可调；采集 DaemonSet 读这个路径即可拿到全部 stdout 日志。易错点：应用写文件不写 stdout 时 kubectl logs 是空的，采集也抓不到——优先改造成标准输出。"
    },
    {
      "q": "长跑节点磁盘被容器日志吃满，参数级的解法是？",
      "options": [
                "只能上机手动 rm /var/log/pods",
                "把 /var/log 挂到更大的盘是唯一办法",
                "kubelet 配置 containerLogMaxSize 与 containerLogMaxFile 控制单容器日志大小与保留份数",
                "重启 kubelet 会清空全部日志"
      ],
      "answer": 2,
      "explain": "kubelet 配置文件里 containerLogMaxSize（如 50Mi）与 containerLogMaxFile（如 3）让运行时按大小轮转，防单容器刷屏拖垮磁盘。易错点：轮转会带来文件截断/重命名，采集器要正确配置防丢行；写入失控的应用要治本。"
    },
    {
      "q": "Java 栈追踪这类多行日志合并的常用手段是？",
      "options": [
                "靠 ES 存储端自动合并",
                "每行加一个 UUID 由后端拼接",
                "多行日志无法采集",
                "采集端配置 multiline 解析（以时间戳开头的行视为新事件，其余行续接到上一条），或应用直接输出单行 JSON"
      ],
      "answer": 3,
      "explain": "Fluent Bit multiline parser / Logstash multiline codec 用行首正则判断事件边界，把 at ... 这类行并进上一条。易错点：multiline 必须在采集侧尽早做；多文件/多流并发时要按流隔离，否则不同容器的行会互相串。"
    },
    {
      "q": "K8s 日志采集选 DaemonSet 还是 Sidecar，权衡点是？",
      "options": [
                "只能用 DaemonSet",
                "DaemonSet 每节点一个 agent 资源省、运维集中，但与节点日志路径耦合；Sidecar 每 Pod 一个隔离好、可按业务定制，但资源随 Pod 数线性增长",
                "只能用 Sidecar",
                "两种方式的资源占用完全相同"
      ],
      "answer": 1,
      "explain": "默认选 DaemonSet 读 /var/log/pods；需要按业务定制解析、多租户网络隔离或采集非标准输出文件时才上 Sidecar。易错点：Sidecar 会降低节点可调度密度（每个 Pod 多一个容器），还要注意 Pod 删除时采集器的冲刷退出。"
    },
    {
      "q": "Elasticsearch 防止脑裂（split-brain，分区两侧各自选主）依靠的机制是？",
      "options": [
                "7.x 版本仍必须手工设置 discovery.zen.minimum_master_nodes",
                "只要数据节点足够多就不会出现双主",
                "master 候选节点的选主需要多数派（quorum）投票：网络分区时只有占多数的一侧能选主，少数派一侧拒绝服务，避免双主写坏数据；7.x 起投票配置由集群自动维护",
                "由 Kibana 充当第三方仲裁节点"
      ],
      "answer": 2,
      "explain": "多数派仲裁是共识底线：master 候选节点建议奇数个（如 3 个容忍 1 个故障），分区后少数派自我罢免；6.x 需手工设 discovery.zen.minimum_master_nodes，7.x 改为自动投票配置（首次组建用 cluster.initial_master_nodes 引导），该 zen 参数已被移除。对应 10-logging「02 · ELK 栈：Elasticsearch 原理与日志管道」一章。易错点：2 个候选主节点在 1:1 分区时两侧都不足多数、全集群无主；少数派侧的请求是被拒绝而非静默双写。"
    }
  ],

  // ========== 中间件：Nginx / MySQL / Redis / MongoDB（10 题）==========

  middleware: [
    {
      "q": "Nginx 的 master-worker 进程模型中，master 的职责是？",
      "options": [
                "worker 监听 80，master 监听 443",
                "读取配置、管理 worker 进程（拉起/重载/平滑升级），自身不处理请求；worker 处理实际连接",
                "master 直接处理全部请求，worker 只写日志",
                "master 是缓存管理进程"
      ],
      "answer": 1,
      "explain": "master 持有监听 socket 并 fork worker，reload 时新 worker 起新配置、旧 worker 处理完存量连接后优雅退场，实现平滑加载。易错点：worker 数对齐 CPU 核（auto）而不是越多越好；master 以 root 运行（绑低端口），worker 应按 user 指令降权。"
    },
    {
      "q": "nginx worker_processes 的推荐设置是？",
      "options": [
                "固定为 1 最稳定",
                "必须等于数据盘数量",
                "auto（等于 CPU 逻辑核数，可配 worker_cpu_affinity 绑核）",
                "越大越好，比如 64"
      ],
      "answer": 2,
      "explain": "worker 是单线程事件循环（epoll），核数个 worker 即可用满 CPU，更多只会增加切换与竞争。易错点：容器里 auto 读到的是宿主机核数，CPU 配额 2 核的容器应显式 worker_processes 2 对齐。"
    },
    {
      "q": "nginx location 匹配优先级的正确描述是？",
      "options": [
                "= 精确匹配 > ^~ 前缀匹配（命中后不再走正则）> 正则（~ / ~*，按出现顺序）> 普通前缀（取最长）",
                "普通前缀优先于精确匹配",
                "按配置文件出现顺序先到先得",
                "正则优先于一切"
      ],
      "answer": 0,
      "explain": "= 与 ^~ 是短路利器：静态资源用 ^~ /static/ 避免逐条试正则；多个正则按书写顺序首个命中生效。易错点：proxy_pass 落在『看起来更具体』的普通前缀却被别的正则 location 抢走，是代理路径错乱的头号原因，用 nginx -T 导出核对。"
    },
    {
      "q": "InnoDB 表主键设计的最佳实践与原因是？",
      "options": [
                "用自增或趋势递增的短主键：聚簇索引按主键组织数据，递增插入顺序写、短键让二级索引更小",
                "用随机 UUID 字符串，更安全",
                "不建主键也没问题",
                "主键越长越好，避免冲突"
      ],
      "answer": 0,
      "explain": "数据行按主键序物理存放（聚簇），随机主键导致页分裂与缓存命中率差；每个二级索引叶子都存主键值，主键越长二级索引越肥。易错点：无显式主键时 InnoDB 用隐藏 rowid 兜底，对复制与闪回都不友好，业务表显式主键应是硬规范。"
    },
    {
      "q": "MySQL 中 binlog、redo log、undo log 的分工，正确的是？",
      "options": [
                "redo log 用于主从复制",
                "三者是同一个日志的三个名字",
                "undo log 记录慢查询",
                "binlog 是 server 层逻辑日志用于复制与时间点恢复；redo log 是 InnoDB 物理日志保证崩溃持久（WAL）；undo log 支持回滚与 MVCC"
      ],
      "answer": 3,
      "explain": "内部两阶段提交让 redo 与 binlog 保持一致（崩溃恢复按 prepare + binlog 决定是否提交）；innodb_flush_log_at_trx_commit 与 sync_binlog 是性能/安全旋钮（双 1 最安全）。易错点：误删恢复靠 binlog，不是 redo；三者的层级（server vs 存储引擎）要分清。"
    },
    {
      "q": "MySQL 主从延迟增大，以下最不可能的原因是？",
      "options": [
                "回放线程并行度不足（单 SQL 线程）",
                "主库有大事务（一条语句更新千万行）",
                "从库自身读压力把 IO/CPU 打满",
                "从库机器规格比主库更高"
      ],
      "answer": 3,
      "explain": "排查看 performance_schema.replication_applier_status_by_worker（老版本 show slave status）确认 SQL 线程与并行回放，大事务拆分与 LOGICAL_CLOCK 并行复制是标准解。易错点：Seconds_Behind_Master 在断连重连或时钟差时会跳变，别只信这一个数。"
    },
    {
      "q": "Redis 命令执行『单线程』的含义与 6.0 IO 多线程的关系，正确的是？",
      "options": [
                "Redis 用 16 个工作线程执行命令",
                "命令执行始终单线程（避免锁与切换），6.0 的多线程只用于网络读写与协议解析，不改变命令串行语义",
                "6.0 起所有命令并行执行，需要加锁",
                "单线程指每秒只能处理一个命令"
      ],
      "answer": 1,
      "explain": "单线程 + epoll 事件循环撑起十万级 QPS，瓶颈通常在网络与内存而非 CPU；io-threads 只加速 IO 路径。易错点：慢命令（keys *、大 key 的 del、超大集合操作）会阻塞全部请求，要用 scan 渐进遍历与 UNLINK 异步删除。"
    },
    {
      "q": "缓存穿透、击穿、雪崩的区分，正确的是？",
      "options": [
                "穿透：查询根本不存在的数据（缓存与库都 miss 打到库）；击穿：单个热点 key 过期瞬间打库；雪崩：大批 key 同时过期或缓存整体宕机",
                "击穿指缓存把数据库写穿",
                "三者是同一现象的三种叫法",
                "雪崩指磁盘损坏"
      ],
      "answer": 0,
      "explain": "对策分别是：穿透用布隆过滤器/空值缓存短 TTL；击穿用互斥重建（singleflight）或逻辑过期；雪崩用过期时间加随机抖动、多级缓存与集群高可用。易错点：把所有打库都叫雪崩会选错方案，先分清『不存在』『单热点』还是『批量失效』。"
    },
    {
      "q": "Redis RDB 与 AOF 的取舍，正确的是？",
      "options": [
                "AOF 的性能开销为零",
                "混合持久化在 4.0 之后已被废弃",
                "RDB 是定时快照（文件小、恢复快，但丢最近一段数据）；AOF 追加写命令（丢得少，文件大恢复慢）；生产常同开并用 aof-use-rdb-preamble 混合持久化",
                "RDB 一定不丢数据"
      ],
      "answer": 2,
      "explain": "aof-use-rdb-preamble=yes 时 AOF 重写产物前半是 RDB 全量、后半是增量命令，兼顾恢复速度与丢失窗口。易错点：主从结构里持久化可下沉到从库换性能，但至少留一个持久化节点；fork 做 RDB 时的页表复制会让大实例停顿。"
    },
    {
      "q": "MongoDB 副本集的写入安全与选举机制，正确的是？",
      "options": [
                "副本集任意节点都能接受写请求",
                "选举只需要一票",
                "writeConcern: majority 要求写到达多数成员才确认；primary 故障后由多数派投票选出新 primary（与 Raft 类似）",
                "majority 写入的速度与单节点确认完全相同"
      ],
      "answer": 2,
      "explain": "三节点（一主两从）是最小生产单元；primary 挂掉后其余成员多数派选出新 primary（默认心跳/超时秒级），期间集群只读。易错点：arbiter 只投票不存数据，两数据节点 + arbiter 能选举但存储无冗余；读偏好 secondaryPreferred 常用于分流读。"
    }
  ],

  // ========== 数据流：Kafka / Flink（10 题）==========

  datastream: [
    {
      "q": "Kafka 保证消息顺序的范围是？",
      "options": [
                "整个集群全局有序",
                "单个分区内有序，跨分区不保证；需要全局有序只能单分区（牺牲并行与吞吐）",
                "顺序完全没有保证",
                "整个 topic 全局有序"
      ],
      "answer": 1,
      "explain": "分区是并行、顺序与复制的最小单位，producer 按 key 哈希路由保证同 key 进同分区。易错点：扩分区后同 key 仍同分区，但与历史顺序可能错位（分区数变化改变哈希）；消费端乱序常因并行处理未按 key 聚合。"
    },
    {
      "q": "acks=all 与 min.insync.replicas 的配合，正确理解是？",
      "options": [
                "acks=all 只要 leader 写入即可确认",
                "min.insync.replicas 设为 1 最安全",
                "acks=all 要求消息被 ISR 中全部副本（含 leader）写入才确认；min.insync.replicas 划定 ISR 少于该值时拒绝写入，防止降级丢数据",
                "两者互不相干"
      ],
      "answer": 2,
      "explain": "三副本常见配置 replication.factor=3 + min.insync.replicas=2：容忍一台故障仍可写且消息至少两份。易错点：producer 还要开幂等（enable.idempotence）+ acks=all 才有 exactly-once 投递语义（不重复不丢失）。"
    },
    {
      "q": "Kafka 中 HW（high watermark）的作用是？",
      "options": [
                "HW 是磁盘水位，决定日志清理",
                "HW 是单 topic 分区数上限",
                "消费者最多只能读到 HW，即已被 ISR 全部复制的位置，之下的消息才对消费者可见",
                "HW 限制 producer 的写入速率"
      ],
      "answer": 2,
      "explain": "LEO 是每个副本的下一条写入位置，HW 取 ISR 中最小 LEO，保证消费者不会读到将来可能因 leader 切换被回滚的消息。易错点：副本重启后从 HW 截断再追平；replica.lag.time.max.ms 决定落后多久被踢出 ISR。"
    },
    {
      "q": "Kafka 消费端拉取消息路径的『零拷贝』指？",
      "options": [
                "消费者不走网络",
                "producer 端的压缩算法",
                "消息不写磁盘直接转发",
                "用 sendfile 让日志数据从 page cache 直达网卡，不经过用户态缓冲区拷贝"
      ],
      "answer": 3,
      "explain": "日志段文件由 OS page cache 托管，消费走 sendfile 绕过用户态，多个消费者重复读同一份热点数据时全命中 cache。易错点：零拷贝服务于读路径，producer 写路径仍是普通写；端到端延迟更多取决于批量（linger.ms）与刷盘策略。"
    },
    {
      "q": "Kafka 磁盘占用持续增长时的日志保留机制是？",
      "options": [
                "按 retention.ms / retention.bytes 对整个日志段（segment）过期删除，或按 key 压缩（log.cleanup.policy=compact），不是逐条删消息",
                "自动把旧消息搬到对象存储",
                "没有保留策略，必须人工清理",
                "逐条删除最旧的消息腾出空间"
      ],
      "answer": 0,
      "explain": "删除以 segment 为单位（活跃段不删），log.retention.hours 默认 168 小时；compact 按 key 保留最新值，适合 changelog 场景。易错点：调小 retention 只影响后续滚动；磁盘 85% 水位前要做容量规划，扩盘优于临时删数据。"
    },
    {
      "q": "触发 consumer group rebalance 的原因是？",
      "options": [
                "组成员变化（加入/退出/崩溃）、订阅的 topic 或分区数变化",
                "broker 磁盘写满",
                "producer 发送速率过高",
                "消费者读了过期数据"
      ],
      "answer": 0,
      "explain": "rebalance 期间整组停止消费（eager 协议 stop-the-world），session.timeout.ms 与 max.poll.interval.ms 决定成员被判死的条件。易错点：处理一批超过 max.poll.interval.ms 会被踢出触发再均衡，形成『慢→踢出→再均衡→更慢』的循环，要减小 max.poll.records 或异步化。"
    },
    {
      "q": "consumer 的 offset 提交时机与投递语义的关系，正确的是？",
      "options": [
                "自动提交保证 exactly-once",
                "offset 提交与投递语义无关",
                "at-least-once 意味着绝不重复",
                "先处理后提交得到 at-least-once（崩溃重启可能重复消费）；先提交后处理是 at-most-once（可能丢）；要避免处理中途发生自动提交"
      ],
      "answer": 3,
      "explain": "重复消费要求下游幂等；Kafka 事务（事务 sink + read_committed 消费者）才能做到端到端 exactly-once，成本更高。易错点：默认 enable.auto.commit=true 不审视提交时机，处理耗时与提交间隔错开会造成丢失或重复。"
    },
    {
      "q": "Flink 事件时间语义与 Watermark 的作用是？",
      "options": [
                "watermark 用于给算子分配 slot",
                "事件时间等于消息到达时间",
                "watermark 是背压水位线",
                "以事件自身的时间戳为准处理乱序流；watermark 声明『到此时间戳为止的数据基本到齐』，用于推动事件时间窗口触发计算"
      ],
      "answer": 3,
      "explain": "乱序与重放场景必须 event time + watermark（延迟界 trade-off：太紧丢数据、太松延迟高），窗口在 watermark 越过结束边界时触发。易错点：allowedLateness 与 side output 可以兜晚到数据；空闲数据源要让 watermark 前进（idle 超时），否则窗口永不触发。"
    },
    {
      "q": "Flink checkpoint 的机制是？",
      "options": [
                "每次 checkpoint 都要重启作业",
                "基于 Chandy-Lamport 分布式快照：source 注入 barrier 随数据流动，算子对齐后把状态异步持久化，失败时全体回退到同一快照",
                "checkpoint 期间必须停止数据写入",
                "只保存 Kafka offset，算子状态不保存"
      ],
      "answer": 1,
      "explain": "barrier 对齐（EXACTLY_ONCE 模式）保证快照一致性，AT_LEAST_ONCE 跳过对齐换吞吐；状态后端（RocksDB）与增量 checkpoint 决定快照大小与速度。易错点：checkpoint 超时往往源于反压（barrier 流不动）或状态过大，先治反压再调 timeout。"
    },
    {
      "q": "Flink 写 Kafka 实现端到端 exactly-once，依赖的是？",
      "options": [
                "把每条消息重复写三遍",
                "依赖 Kafka 自动去重",
                "两阶段提交：checkpoint 时预提交事务，快照完成时提交，消费者以 read_committed 隔离级别读取",
                "Flink 不可能做到 exactly-once"
      ],
      "answer": 2,
      "explain": "两阶段提交把消费 offset 与输出事务绑定在同一快照里，故障恢复后旧事务 abort、重放后新事务提交，效果是恰好一次可见。易错点：下游必须 read_committed 才看不到未提交数据；事务超时（transaction.max.timeout.ms）要两侧协调。"
    }
  ],

  // ========== SRE 方法论（10 题）==========

  sre: [
    {
      "q": "可用性 SLO 99.9% 对应的每月错误预算约是？",
      "options": [
                "约 5 分钟",
                "约 43 分钟（43200 分钟 × 0.001）",
                "约 43 秒",
                "约 4.3 小时"
      ],
      "answer": 1,
      "explain": "月预算 = 43200 × (1 - SLO)：99.9% 约 43.2 分钟、99.95% 约 21.6 分钟、99.99% 约 4.3 分钟。易错点：SLO 通常是滚动窗口（如 28 天）而非自然月；预算烧完比可用率数字更早暴露问题，这正是它的运营价值。"
    },
    {
      "q": "error budget 的核心用途是？",
      "options": [
                "用来计算故障扣款",
                "为『还能承受多少不可靠』给出量化额度，用于决策发布节奏、变更冻结与稳定性投入优先级",
                "只是一个汇报指标，不影响任何决策",
                "替代监控告警体系"
      ],
      "answer": 1,
      "explain": "预算剩余多可以激进发布，烧完就冻结变更、优先还债——把可靠性当资源管理是 SRE 与纯运维的分水岭。易错点：SLO 定得比用户真实需求高会白费成本（过度工程），定低则用户流失，应从用户行为反推合理 SLI。"
    },
    {
      "q": "一个好的比率型可用性 SLI 定义是？",
      "options": [
                "每周工单数量",
                "CPU 使用率",
                "成功请求数 / 总请求数（成功标准可量化，如非 5xx 且延迟达标），口径明确且可自动采集",
                "团队满意度评分"
      ],
      "answer": 2,
      "explain": "SLI 要能代表用户体验、可度量、口径无争议；常见请求驱动型四件套是可用性/延迟/吞吐/正确性。易错点：把资源指标当 SLI（CPU 高不一定影响用户）；延迟 SLI 用分位数（P99）而不是平均值。"
    },
    {
      "q": "基于燃烧率（burn rate）的多窗口多告警，相对固定阈值告警的优势是？",
      "options": [
                "快烧（短窗口+长窗口同时超阈值）立刻 page，慢烧只走工单，既不漏慢性消耗又对短暂波动不误报",
                "可以替代一切监控",
                "燃烧率告警不需要定义 SLO",
                "只需要一个窗口，配置更省"
      ],
      "answer": 0,
      "explain": "经典 SRE 配方（SRE Workbook 第 5 章多窗口多燃烧率）：14.4 倍燃烧率配 1h/5m 双窗口、6 倍配 6h/30m 双窗口，两档都是 page（分别对应烧掉 2%/5% 预算）；3 倍配 1d/2h、1 倍配 3d/6h 才是工单级。双窗口同时超阈才报以抑制毛刺。易错点：燃烧率 = 实际错误率 / (1 - SLO)，忘了除基线会把阈值配成天文数字。"
    },
    {
      "q": "判断一条告警是否值得半夜 page 的标准是？",
      "options": [
                "只要指标超阈值就 page",
                "告警条数越多越安全",
                "是否需要人立即行动（影响用户且不可自动恢复、有明确处置动作）；否则降级为工单或仪表盘",
                "按上级偏好配置"
      ],
      "answer": 2,
      "explain": "每条 page 都应可行动、可理解并附带 runbook 链接；不可行动的告警只会训练人忽略报警。易错点：symptom（症状：错误率、延迟）才值得 page，cause（原因：CPU 高、GC 频繁）进工单——症状驱动告警是 SRE 基本功。"
    },
    {
      "q": "重大事故管理中 Incident Commander（IC）的职责是？",
      "options": [
                "指挥与协调：维护时间线、分配任务、把握沟通节奏，通常不亲手排障，保证有人全局把控",
                "负责事后追责定责",
                "必须由最资深工程师担任并亲自修复",
                "只负责写复盘报告"
      ],
      "answer": 0,
      "explain": "IC + 操作（动手）+ 沟通（对内公告/对外状态页）+ 记录（时间线）的角色分离让救火不失控，IC 可交接但必须唯一。易错点：全员扑在终端上没人看全局与同步干系人，是拉长 MTTR 的典型模式；宣布事故成立要果断。"
    },
    {
      "q": "blameless postmortem（无责复盘）的原则与原因是？",
      "options": [
                "聚焦『系统为什么允许这个错误发生』（流程、工具、防御层），不追究个人；惩罚文化会让人隐瞒问题，导致同类故障重演",
                "只复盘大事故，小故障不用看",
                "目的是找出责任人写进绩效",
                "无责等于不需要任何人签字确认"
      ],
      "answer": 0,
      "explain": "人的失误是给系统的反馈：改 checklist、加防护（准入校验、灰度、回滚演练）比『下次小心』有效；复盘产出要有 owner 与截止日期并跟踪闭环。易错点：把无责读成无事——没有可验证行动项的复盘只是作文。"
    },
    {
      "q": "Runbook 对 on-call 的价值是？",
      "options": [
                "Runbook 等价于全量架构文档",
                "只有新人需要，资深工程师用不上",
                "写一次终身有效不用维护",
                "把验证过的处理步骤固化（症状 → 诊断命令 → 处置 → 升级路径），让值班者在高压下按图索骥，也是 LLM 辅助排障的知识底料"
      ],
      "answer": 3,
      "explain": "好 runbook 按症状组织、含真实命令与预期输出、写明风险与回滚；每次事故后把新知识补进去形成闭环。易错点：写成按系统组织的『架构百科』在半夜根本查不到；命令已失效的 runbook 比没有更危险，要演练校对。"
    },
    {
      "q": "混沌工程实验的第一步与『最小爆炸半径』原则是？",
      "options": [
                "混沌工程就是压力测试",
                "不需要假设，观察热闹即可",
                "先定义并度量稳态指标（baseline）、提出假设，然后在小范围可回滚环境注入故障，逐步放大，且随时能终止实验",
                "直接在生产随机杀节点，越乱越好"
      ],
      "answer": 2,
      "explain": "流程：稳态假设 → 选真实故障（杀 Pod、断网、注延迟）→ 最小爆炸半径注入 → 对照监控验证行为 → 复盘加固；平台（ChaosBlade/Litmus 等）要有 abort 机制。易错点：没有稳态基线就无法判断实验是否异常；与压测的区别在于验证韧性假设而非容量。"
    },
    {
      "q": "SRE 中 toil 的判定特征是？",
      "options": [
                "写代码的工作不算 toil",
                "一切运维工作都叫 toil",
                "toil 只与加班时长有关",
                "手工、重复、可自动化、战术性、无长期价值且随服务规模线性增长；占比过高（如超 50%）就该投入自动化"
      ],
      "answer": 3,
      "explain": "Google 的经验值：toil 超过 50% 的团队应把工程时间转向自动化与工具，否则人力被事务吞掉且留不住工程师。易错点：把忙碌当产出——消除重复工作的价值高于再做一次英雄式救火；toil 统计是立项自动化的依据。"
    }
  ],

  // ========== 云计算：阿里云与 AWS（10 题）==========

  cloud: [
    {
      "q": "VPC 中公有子网与私有子网的本质区别是？",
      "options": [
                "两者只是命名习惯不同",
                "路由表是否含去往 Internet 网关（IGW）的默认路由；私有子网出公网靠 NAT 网关",
                "公有子网不能使用内网 IP",
                "公有子网带宽更大"
      ],
      "answer": 1,
      "explain": "子网的公/私由路由决定而非 IP 本身：公有子网里带公网 IP/EIP 的实例可双向进出，私有子网实例无公网地址且路由不达 IGW。易错点：安全组没放行、路由缺 NAT、实例没公网 IP 三者症状相似（SSH 不通、镜像拉不下来），要沿路径逐跳排查。"
    },
    {
      "q": "安全组（Security Group）与网络 ACL 的区别是？",
      "options": [
                "安全组无状态，ACL 有状态",
                "ACL 只能用于公网入口",
                "两者完全等价",
                "安全组有状态（回包自动放行）且作用在实例/网卡级；ACL 无状态（出入都要显式规则）且作用在子网级"
      ],
      "answer": 3,
      "explain": "默认拒绝、有状态的安全组是主防线；ACL 适合子网级粗粒度兜底（如显式封禁某源地址段）。易错点：互访的两端安全组都要放行；无状态 ACL 容易漏掉回包方向，排障先看安全组再看 ACL。"
    },
    {
      "q": "私有子网中的 ECS 需要拉取公网镜像（docker pull），正确路径是？",
      "options": [
                "给 ECS 直接绑定 EIP（那就不再是纯私有部署）",
                "子网路由经 NAT 网关（绑定 EIP）SNAT 出公网",
                "必须通过 VPN 回本地机房",
                "私有子网永远无法出公网"
      ],
      "answer": 1,
      "explain": "NAT 网关承载整子网的出向流量（按量计费、带宽可配），实例自身不暴露公网、进向仍不可达。易错点：批量拉镜像要核对 NAT 的 EIP 带宽；账单异常先查出向流量（备份走公网、恶意外联都会烧钱）。"
    },
    {
      "q": "阿里云高可用 Web 架构的标准搭配是？",
      "options": [
                "ESS 必须固定台数不能弹性",
                "单台大规格 ECS 加定时备份即可",
                "SLB 挂多可用区 ECS，后端配 ESS 伸缩组（健康检查 + 自动扩缩），前置 DNS/CDN；对应 AWS 的 ELB + Auto Scaling",
                "SLB 只能转发 TCP 流量"
      ],
      "answer": 2,
      "explain": "多可用区 + 无状态层 + 伸缩组是模板：健康检查摘除坏节点、按 CPU 或队列长度伸缩。对照记忆：SLB≈ALB/NLB、ECS≈EC2、OSS≈S3、RDS≈RDS。易错点：伸缩组用的镜像/启动模板要预热并灰度，否则扩出来的机器带病上岗。"
    },
    {
      "q": "公有云『共享责任模型』的划分是？",
      "options": [
                "云厂商负责云本身（物理设施、虚拟化、托管服务底层）的安全；客户负责云上内容（系统补丁、账号权限、数据与配置）",
                "按付费金额划分责任",
                "全部由云厂商负责",
                "全部由客户负责"
      ],
      "answer": 0,
      "explain": "IaaS 客户管 OS 以上，PaaS/SaaS 客户责任面收窄，但配置（桶策略、IAM、加密）仍是自己的；『用了云』不等于『安全合规』。易错点：AK/SK 泄漏、对象存储公开读、安全组 0.0.0.0/0 全开，都是客户侧责任的高频翻车点。"
    },
    {
      "q": "存放网站静态资源（图片、JS）并按流量分发，最合适的云存储形态是？",
      "options": [
                "文件存储（NAS）共享目录",
                "对象存储（OSS/S3）+ CDN 边缘加速",
                "块存储（云盘）挂给每台 ECS",
                "存进数据库的 BLOB 字段"
      ],
      "answer": 1,
      "explain": "对象存储按量计费、HTTP 原生访问、配 CDN 缓存最适合海量静态资源；块存储面向单机挂盘（数据库），NAS 面向多机共享文件系统。易错点：对象存储的权限（公有读/私有 + 签名 URL）与防盗链要配置，计费模型（流量/请求）也与云盘完全不同。"
    },
    {
      "q": "多可用区（AZ）部署的核心价值与代价是？",
      "options": [
                "AZ 间物理隔离（独立供电/网络）且以低延迟内网互联，单 AZ 故障时服务继续；代价是跨 AZ 流量费与少量延迟",
                "一个 region 里只有一个 AZ",
                "多 AZ 只是合规要求，技术上无意义",
                "AZ 之间零延迟"
      ],
      "answer": 0,
      "explain": "生产标准是同 region 多 AZ：SLB 多可用区、RDS 主备跨 AZ、ECS 反亲和分散；跨 region 才谈容灾（成本与延迟都高一档）。易错点：只有无状态层跨 AZ 而数据库单 AZ，等于没做；把多 AZ 当多 region 宣传是误解。"
    },
    {
      "q": "IaaS / PaaS / SaaS 的责任划分，正确的是？",
      "options": [
                "SaaS 需要自己维护操作系统",
                "三者是同一产品的价格档位",
                "IaaS 给虚机自己装一切；PaaS 给运行时（数据库、容器平台）你管代码与数据；SaaS 开箱即用只管配置与账号",
                "PaaS 就是加了监控的 IaaS"
      ],
      "answer": 2,
      "explain": "越往上托管越多、可控越少：RDS 省去备份高可用，但 superuser 权限与部分参数受限。易错点：『省运维』不等于『无运维』——RDS 的慢查询、连接数、参数与备份策略仍要人管，迁移前先读限制清单。"
    },
    {
      "q": "自建 MySQL 迁到云 RDS，通常不需要自己做的是？",
      "options": [
                "评估业务停机窗口",
                "梳理账号与权限",
                "搭建主从复制与备份调度（RDS 已内建高可用与自动备份）；但兼容性核对、数据迁移与割接演练仍是自己的活",
                "准备回滚预案"
      ],
      "answer": 2,
      "explain": "托管化买断的是高可用/备份/补丁这类基建；数据迁移（DTS）、大事务与存储过程兼容、只读实例延迟仍要自己负责。易错点：割接前必须演练（含回滚），双向同步要做数据一致性校验，别把『能连上』当成『能割接』。"
    },
    {
      "q": "云成本优化的常见有效手段不包括？",
      "options": [
                "存储生命周期策略（转低频/归档）",
                "闲置资源治理（低利用率 ECS、未挂载云盘、过期快照）",
                "包年包月/预留实例覆盖长期稳定负载",
                "把数据库等核心有状态服务全部换成抢占式/竞价实例"
      ],
      "answer": 3,
      "explain": "竞价实例随时可能被回收，适合无状态、可中断、可容错的批处理，核心数据库不能上；其余三项是成本治理基本盘，账单按标签分摊到业务更容易推进。易错点：只盯单价不看利用率——一台闲着的大机器比三台忙的小机器更贵。"
    }
  ],

  // ========== AIOps 与 LLM（10 题）==========

  aiops: [
    {
      "q": "LLM 的『幻觉』（hallucination）指？",
      "options": [
                "输出乱码不可读",
                "模型训练时的显卡故障",
                "响应速度太慢",
                "生成看似可信实际错误的内容（编造参数、不存在的命令或版本），生产使用前必须用文档与实验验证"
      ],
      "answer": 3,
      "explain": "排障场景的高危区：编造不存在的 kubectl 参数、虚构配置项、过时的版本行为。对策：把权威文档/知识库喂进上下文（RAG）、要求给出来源、关键命令在测试环境先跑。易错点：语气自信不等于内容正确，直接复制粘贴执行是事故源头。"
    },
    {
      "q": "RAG（检索增强生成）解决的核心问题是？",
      "options": [
                "在生成前把私有/最新知识检索出来拼进上下文，缓解模型知识截止与不了解内部系统的问题",
                "替代数据库",
                "自动压缩模型参数",
                "让模型训练得更快"
      ],
      "answer": 0,
      "explain": "内部 runbook、历史故障、架构文档不在公网训练集里，RAG 用向量检索把相关片段注入 prompt，让回答贴着企业事实。易错点：RAG 的上限是知识库质量——过时 runbook 被检索出来只会让模型自信地给出旧答案，治理比算法重要。"
    },
    {
      "q": "向量检索（embedding）在 RAG 中的角色是？",
      "options": [
                "把模型变小",
                "对文本进行加密",
                "把文本映射成语义向量，用相似度（如余弦）召回与问题最相关的知识片段",
                "直接生成最终答案"
      ],
      "answer": 2,
      "explain": "常见链路：文档切块 → embedding 入库 → 查询同模型向量化 → top-k 召回 → 重排 → 拼 prompt。易错点：切块粒度影响召回质量（太大稀释语义、太小丢上下文）；查询与文档必须用同一 embedding 模型，换模型要重建索引。"
    },
    {
      "q": "用 LLM 辅助排障，最有效的提问方式是？",
      "options": [
                "什么都不给，考考模型的能力",
                "把整个磁盘的日志原样粘贴进去",
                "只说『服务挂了怎么办』",
                "贴出报错原文、版本、相关配置与已尝试过的操作，再说明目标（『想让 X 恢复』而不是『帮我看看』）"
      ],
      "answer": 3,
      "explain": "输出质量与上下文质量强相关：报错栈、版本、拓扑、变更历史这四要素给全，模型才能给出可执行的假设排序。易错点：倾倒无关日志会稀释重点还可能撞上下文上限，先自己 grep 出关键片段再喂。"
    },
    {
      "q": "排障/运维场景调用 LLM 时，temperature 参数应如何设置？",
      "options": [
                "temperature 控制响应速度",
                "必须固定为 1 不可修改",
                "调低（如 0~0.3）追求稳定确定，诊断与分类任务不需要发散",
                "调到最大让模型更有创造力"
      ],
      "answer": 2,
      "explain": "采样温度越低输出越确定（同问近似同答），头脑风暴类任务才需要高温度。易错点：低温度不等于零幻觉——确定性指『稳定』不是『正确』；结构化输出（JSON）场景配合低温度与格式约束更可靠。"
    },
    {
      "q": "关于上下文窗口（context window），正确的理解是？",
      "options": [
                "上下文是无限的",
                "token 只统计中文字符数",
                "模型单次能处理的 token 有上限；超长日志要先截断/筛选/摘要，塞满窗口还会稀释重点、增加费用与时延",
                "窗口越大答案必然越好"
      ],
      "answer": 2,
      "explain": "窗口再大也有代价：注意力稀释（lost in the middle）、费用与时延线性上涨；标准做法是先过滤（grep 关键行）再分块摘要。易错点：把『能塞下』当『效果好』；长对话历史要定期摘要压缩，避免早期关键信息被冲掉。"
    },
    {
      "q": "LLM Agent 的『工具调用』（function calling）机制是？",
      "options": [
                "模型自己在服务器上执行 shell 命令",
                "模型按意图输出结构化的调用请求（工具名 + 参数），由外部代码执行后把结果回填给模型继续推理",
                "工具调用就是网页搜索",
                "Agent 等于带界面的聊天框"
      ],
      "answer": 1,
      "explain": "模型只决定调用什么与参数是什么，执行权在外部框架——这正是可控点：白名单工具、参数校验、审计日志都在执行层做。易错点：模型可能编造不存在的工具或错误参数，执行前必须做 schema 校验；要设步数上限防死循环。"
    },
    {
      "q": "运维 Agent 落地时的人机审批边界，合理的设计是？",
      "options": [
                "只读操作（查询、诊断）可自动执行，变更类（重启生产、删数据、改配置）默认人工审批，且动作可回滚、全程留痕",
                "让 LLM 自行评估风险决定是否需要审批",
                "全部都要人工点确认，包括 cat 日志",
                "全部操作全自动，效率优先"
      ],
      "answer": 0,
      "explain": "分级授权：读自治、写审批、删除双人或禁止；执行前生成计划（plan）给人确认，执行后要有回滚预案与审计日志。易错点：让模型自己评估自己行为的风险等于没有边界；凭证要用 Agent 专属最小权限账号，不能复用人的权限。"
    },
    {
      "q": "不接任何工具与数据源时，当前 LLM 最不适合的任务是？",
      "options": [
                "解释一段陌生配置的含义",
                "对本集群实时指标做精确计算并触发告警（需要实时数据与确定性计算）",
                "把一段报错翻译成可能的故障原因清单",
                "根据时间线草拟故障复盘初稿"
      ],
      "answer": 1,
      "explain": "预训练模型没有实时数据、精确算术也弱；实时监控计算属于指标系统 + 规则/告警的领地。易错点：把『什么都能聊』误读成『什么都能干』——接上工具与数据源（函数调用、知识库）之后，能力边界才真正扩展。"
    },
    {
      "q": "为 LLM 辅助排障建设运维知识库，最应优先沉淀的是？",
      "options": [
                "全部聊天记录原样归档",
                "只保存监控截图",
                "知识库与 CMDB、变更系统完全隔离，纯手工维护",
                "结构化的 runbook 与历史故障复盘（症状、排查步骤、根因、命令与预期输出），并保持与实际环境同步"
      ],
      "answer": 3,
      "explain": "知识库是 RAG 的地基：按症状组织、字段结构化、命令可执行且与现网版本一致，检索命中率才高。易错点：数量堆砌不如质量治理——过时的旧文档被召回比没有文档更危险，定期演练校对要排进日历。"
    }
  ],

  // ========== bigdata：大数据平台（15 题，按 16-bigdata 各章命题）==========

  bigdata: [

    // --- HDFS：NameNode、块模型与丢失块排障（4 题）---

    {
      "q": "机架感知已正确配置时，HDFS 默认的 3 副本放置策略（BlockPlacementPolicyDefault）对一个由集群内节点（如 Spark task 所在 DataNode）写入的块是怎么摆放的？",
      "options": [
        "三个副本分别放在三个不同机架的随机 DataNode 上，容灾最大化优先",
        "三个副本放在同一机架的三台不同 DataNode 上，节省核心交换机带宽",
        "第 1 副本写在本机，第 2 副本放远端机架的随机 DN，第 3 副本放在与第 2 副本同机架的另一台 DN",
        "三个副本全部由 NameNode 统一随机分配，与写入方所在位置无关"
      ],
      "answer": 2,
      "explain": "三条设计动机：第 1 副本本机省一次网络传输（写吞吐）；第 2 副本跨机架保证机架级容灾；第 3 副本回到第 2 副本的机架——既不碰第三个机架（省核心交换机带宽），又不和第 2 副本同机。易错点：以为“跨三个机架最安全”，实际是在容灾与带宽之间取平衡。写入方是集群外客户端时，第 1 副本才是随机选 DN，第 2/3 副本规则不变。"
    },
    {
      "q": "NameNode 重启后长时间停在 safemode，UI 显示 “The reported blocks 0.9950 has reached the threshold 0.999”。下面哪组判断与处置是正确的？",
      "options": [
        "safemode 只影响写入不影响读取说明集群健康，直接 hdfs dfsadmin -safemode leave 强制退出即可",
        "safemode 是只读保护态：块报告覆盖比例到不了阈值就不会退出。应先 hdfs dfsadmin -report 确认 DataNode 是否全部在线注册，比例不动才考虑丢块；手动 leave 的前提是确认 DN 全部健康",
        "卡在 safemode 说明块已经丢失，应立即 hdfs fsck / -delete 清理丢失块后再重启",
        "safemode 是 NameNode 内存不足触发的保护机制，加大 NN 堆后自动退出"
      ],
      "answer": 1,
      "explain": "safemode 的语义是“元数据里应有的块还没被 DN 报告确认，禁止一切修改（写/删/重命名/副本调整）”，避免 NN 在信息不全时误判大量 under-replicated 触发复制风暴。退出条件：DN 块报告覆盖比例 ≥ dfs.namenode.safemode.threshold-pct（默认 0.999）并保持 extension 时间（默认 30 秒）。卡住的典型原因：DN 没起来/没注册、确实丢了块、大集群块报告还在路上。强行 leave 后 missing blocks 该有还是会有，写流量还会立刻压上来；“一见 missing 就 -delete”是明令禁止的动作。"
    },
    {
      "q": "关于 HDFS 小文件的实际代价，下面哪个说法是准确的？",
      "options": [
        "小文件只浪费 DataNode 磁盘空间，对 NameNode 没有影响",
        "小文件的危害主要是 3 副本带来的存储开销翻三倍",
        "一个 10KB 小文件在 NameNode 里占用的元数据比文件本身还小，可以忽略",
        "官方口径每个文件/目录/块对象约占 NN 堆 150 字节；小文件的显性成本是 NN 堆与 GC，隐性成本还包括全量块报告变慢、重启重建映射变慢、fsck 跑几小时、MR/Spark 每个 task 打开文件的固定开销"
      ],
      "answer": 3,
      "explain": "小文件的本质问题是“元数据规模 = 堆规模”：一个 10KB 文件至少是 inode + 块两个对象再加副本映射，元数据可达数据本身的 30 倍以上；同样 1PB 数据，用 1MB 小文件是 10 亿个块对象，任何 NN 都撑不住。易错点：只盯着磁盘空间——小文件在存储上并不“费盘”，费的是 NN 内存与一切要遍历元数据的操作。治理优先级：入口合并（治本）> 存量归并（INSERT OVERWRITE / ORC CONCATENATE）> HAR 归档。"
    },
    {
      "q": "某集群一直没配机架感知脚本（net.topology.script.file.name），后来补配并重启了 NameNode。已有的 3 副本数据会怎样？",
      "options": [
        "已有副本不会自动搬家：放置策略只在写入那一刻生效；需要用 hadoop fs -setrep 触发重复制（或重写数据）纠正分布，Balancer 只搬数据量不纠正拓扑",
        "NameNode 后台任务会自动把不合规的副本迁移到正确机架",
        "hdfs balancer 会自动按新拓扑重新摆放所有副本",
        "副本分布不需要处理，HDFS 读写时会自动绕开同机架的副本"
      ],
      "answer": 0,
      "explain": "没配机架感知时全部节点都在 /default-rack，放置策略退化为随机，3 副本可能全落在同一机架，单机架断电即丢数据，且 NN 日志会持续告警拓扑不可用。后配脚本不会搬旧副本，因为 NN 没有“副本位置不合规就迁移”的后台任务——全量数据重写一遍网络的代价太高。发现手段是 hdfs fsck -blocks -locations -racks 看每块的 rack 分布；纠正手段是 setrep 触发重复制或 distcp 重写。"
    },

    // --- YARN：容器、队列与多租户调度（3 题）---

    {
      "q": "关于 YARN 的 Capacity Scheduler 与 Fair Scheduler，正确的说法是？",
      "options": [
        "Fair Scheduler 默认开启抢占，Capacity Scheduler 默认关闭",
        "两者的抢占都默认开启，只是算法不同",
        "两者的抢占默认都是关闭的，都需要显式开启（Capacity 要开 scheduler monitor 一族配置，Fair 要 preemption=true 并配 PreemptionTimeout），且误开抢占会把别人的长跑作业杀掉",
        "Capacity Scheduler 不支持队列层级与 ACL"
      ],
      "answer": 2,
      "explain": "高频坑：把“公平调度会抢资源”当成开箱即用。实际两者的抢占都默认关闭：Capacity 需要 yarn.resourcemanager.scheduler.monitor.enable 一族配置，Fair 需要 preemption=true 且配置 fairShare/minShare PreemptionTimeout（不配 timeout 就永不抢占）。抢占语义是“超过 guaranteed 的借用部分可被回收”，误开会把别人的长跑 Spark 作业杀一半（退出码 143），开之前要先在测试队列演练并确认业务有重试。队列树、ACL、rmadmin -refreshQueues 热更新两者都支持；新装机默认 Capacity。"
    },
    {
      "q": "Spark on YARN 作业的 container 频繁被杀，日志报 “Container ... is running beyond virtual memory limits”，而堆内存明明还很富余。最合理的处置是？",
      "options": [
        "立即调大 spark.executor.memory（-Xmx），堆大自然不会超",
        "这是 vmem-pmem-ratio（默认 2.1）对 JVM 应用过紧导致的经典“假 OOM”：社区通行做法是设 yarn.nodemanager.vmem-check-enabled=false，物理内存检查保留",
        "把 yarn.nodemanager.resource.memory-mb 整机调大一倍",
        "关闭 cgroup 隔离，改用 DefaultContainerExecutor"
      ],
      "answer": 1,
      "explain": "JVM 应用的虚拟地址空间（堆外内存、线程栈、NIO direct buffer）远大于物理内存使用，2.1 倍比例经常被触发——这是 Hadoop 运维最经典的误杀。处置是关掉虚拟内存检查、保留物理内存检查；真报 “running beyond physical memory limits” 才去加内存（堆外按堆的 20~40% 预留）。盲目加 -Xmx 反而挤压堆外空间，让 RSS 更快顶到容器上限。"
    },
    {
      "q": "YARN 集群监控里看到“vcore 使用率 100% 但宿主机 CPU 大量空闲”，同时某 container 退出码 137。下面解读正确的是？",
      "options": [
        "vcores 是硬限制，说明 CPU 真的打满了，应该扩容",
        "137 是应用代码抛异常，看 stderr 找第一个 Caused by 即可",
        "137 表示被抢占（SIGTERM）；0 以外的退出码都是磁盘满导致",
        "不开 CPU cgroup 隔离时 vcores 只是记账配额不是硬限，不能当真实 CPU 水位看，要看宿主机 mpstat/top；退出码 137 = SIGKILL（物理内存超限被 NM 强杀或宿主 OOM killer），143 = SIGTERM（被抢占/管理员 kill）"
      ],
      "answer": 3,
      "explain": "Container 的两个维度里内存才是硬限制：进程树物理内存超限，NM 先 SIGTERM 后 SIGKILL。vcores 默认只是调度账本。退出码速查：0 正常结束、1 应用异常看 stderr、137 SIGKILL（内存超限/宿主 OOM）、143 SIGTERM（被抢占、超限先杀、管理员 kill）。“内存打满、vcores 大量剩余”是 YARN 集群常态，容量规划按 memory-mb 做主轴。"
    },

    // --- Hive 与数仓分层（2 题）---

    {
      "q": "同一条 SQL（WHERE dt='2026-08-29' AND amount>100 GROUP BY city）在计算引擎完全相同的情况下，TextFile 表和 ORC 表的执行差距主要来自哪一层？",
      "options": [
        "文件读取层：ORC 先读 footer 统计，dt 靠分区裁剪跳过目录，amount>100 靠 stripe/row group 的 min-max（可加 bloom filter）整块跳过，且只反序列化用到的列；TextFile 必须把命中分区的所有行完整读入并解析全部字段",
        "SQL 解析层：ORC 表的 SQL 会被自动重写成更优的语法",
        "网络层：ORC 文件平均更小，传输更快是唯一原因",
        "执行引擎层：查 ORC 表会自动切换到 Tez，查 TextFile 走 MR"
      ],
      "answer": 0,
      "explain": "差距主要不在引擎而在文件读取层，IO 量与反序列化 CPU 差一个数量级很常见。列存压缩率高的原因也很朴素：同列数据类型相同、重复度高，排序后 RLE/字典编码效果远好于行存的混合类型字节流。生产 Hive 系用 ORC 居多的原因：Hive 原生优化（向量化、ACID）先落在 ORC、压缩与统计信息最全、compaction/CONCATENATE 只对 ORC 完整支持；主引擎是 Spark/Trino 则 Parquet 同样合理——跟着平台默认走，别混用。"
    },
    {
      "q": "数仓分层的 ODS 层任务失败通常配最高级告警（电话），而 ADS 层单任务失败常常只开工单。背后的判断依据是？",
      "options": [
        "ODS 数据量最大，存储成本最高",
        "ODS 任务跑得最慢，失败概率最高",
        "影响面 × 恢复成本：ODS 是全链路的数据源头，它失败意味着 DWD/DWS/ADS 全部顺延、报表 SLA 整体风险，且重跑要回源重拉（代价最大、窗口最长）；ADS 失败通常只影响一张报表，数据仍在下层、重算是廉价的本地重算",
        "ADS 层没有监控指标，只能靠人肉发现"
      ],
      "answer": 2,
      "explain": "告警分级本质上是对“影响面 × 恢复成本”排序。分层是团队规范而非 Hive 功能，但对运维的影响实打实：任务依赖定位（沿血缘回溯有明确站牌，5 分钟定位是哪个环节的锅）、告警归层（没有分层语义只能“谁失败叫谁”，噪声大）、存储治理（ODS 短 TTL + ORC zstd + 可降副本，DWD 长期保留 3 副本，分层是配额与生命周期策略的作用域）。"
    },

    // --- Spark 架构与调优（3 题）---

    {
      "q": "Spark on YARN 报 “Container killed by YARN for exceeding memory limits ... Consider boosting spark.executor.memoryOverhead”，但 executor 堆（-Xmx 6g，容器上限 8GB）才用到一半。问题出在哪、怎么调？",
      "options": [
        "堆内存配置有误，把 spark.executor.memory 调到 8g 即可解决",
        "是 Driver 的问题，把 deploy-mode 改成 cluster 就好",
        "YARN 杀容器看的是进程 RSS 而不是 -Xmx：RSS = 堆 + metaspace + 线程栈 + netty 直接内存等。shuffle 拉取量大时堆外先膨胀，堆还有富余 RSS 已顶到容器上限。应调大 spark.executor.memoryOverhead（必要时减 executor-cores 降并发），而不是盲目加 -Xmx",
        "调大 spark.sql.shuffle.partitions，让每个 task 的数据量变小"
      ],
      "answer": 2,
      "explain": "这是“OOM 常在堆外”的经典场景。容器总内存 = spark.executor.memory（JVM 堆）+ memoryOverhead（默认 max(executor.memory×0.10, 384MB)）+ 可选 offHeap/PySpark 内存。加堆反而挤压堆外空间，OOM 会更频繁。K8s 上同一现象表现为 OOMKilled、Exit 137，处置相同：确认 request/limit = memory + overhead。"
    },
    {
      "q": "Spark 数据倾斜三板斧的适用场景匹配，正确的一组是？",
      "options": [
        "小表能装下 → broadcast 绕过 shuffle；聚合倾斜 → 两阶段聚合（先按 (key, salt) 局部聚合再全局聚合）；join 倾斜且小表可膨胀 → 大表加盐打散、小表按 N 份复制补齐所有前缀",
        "任何倾斜都优先加盐，broadcast 只用于小结果集返回",
        "聚合倾斜用 broadcast，join 倾斜用两阶段聚合",
        "三板斧必须同时叠加使用才有效"
      ],
      "answer": 0,
      "explain": "口诀即选型依据。细节：加盐只对小表用（代价是小表膨胀 N 倍）；两阶段聚合的 partial_sum 只能压缩行数、压不了单 key 的原始体积，单 key 特别大时仍要先加盐；broadcast 的反噬是“小表”其实几百 MB 时会同时顶爆 Driver 和每个 Executor 的内存，比 shuffle 更危险。另有一类“假倾斜”：null/空串 key 堆积，用 WHERE key IS NOT NULL 拆出去单独处理，别上三板斧。Spark 3.x 先让 AQE（skewJoin）自动处理——它主要覆盖排序 join 的倾斜，聚合倾斜仍要手工两阶段。"
    },
    {
      "q": "Spark 统一内存模型里，Execution 与 Storage 之间的动态借用规则是什么？这个不对称保护的是什么？",
      "options": [
        "双向对等：谁缺内存都可以抢占对方，被抢占方立刻无条件释放",
        "Execution 缺内存时可以抢占 Storage 借走的部分（被借走的缓存块强制落盘/逐出）；反向 Storage 只能借用 Execution 当时空闲的部分，Execution 一需要就必须立刻归还——保护“正在运行的 task 不能被中断”，缓存丢了可以重算，task 失败则整个 stage 重来",
        "Storage 优先级更高，缓存块永远不会被逐出",
        "User Memory 也参与 Execution/Storage 之间的动态借用"
      ],
      "answer": 1,
      "explain": "Execution 内存不够时 task 无法让步（算到一半的数据不能扔），只能挤掉可重建的缓存块腾地方；反向若 Storage 能抢占 Execution，缓存写入会随时杀掉正在执行的 task。一句话：可重算的资源永远让位于不可中断的计算。User Memory（用户对象/UDF）完全不参与借用，Spark 不管它——UDF 里塞大 dict 导致的堆内 OOM 就出在这里。"
    },

    // --- OLAP：Doris 与 StarRocks（2 题）---

    {
      "q": "同一份订单数据要做两件事：“审计明细留存（永不合并、可随时按新口径重算）”和“实时余额查询（按主键 upsert、点查要快）”。Doris 建表分别应选什么模型？",
      "options": [
        "都用 Duplicate 模型，靠 rollup 区分两种场景",
        "都用 Unique + merge-on-read，一表两用",
        "明细留存用 Aggregate（SUM），余额查询用 Duplicate",
        "明细留存用 Duplicate（写最便宜、永不合并）；实时余额用 Unique + merge-on-write（写时用 delete bitmap 打掉旧版本，读路径接近纯明细表、点查快）"
      ],
      "answer": 3,
      "explain": "三种模型语义：Duplicate 一行就是一行（写最便宜、读时聚合最贵）；Aggregate 同 key 按聚合函数在导入/compaction/查询多阶段合并（写放大换读加速）；Unique 同 key 后写覆盖先写。Unique 的 MoW/MoR 取舍是把合并成本放在写路径还是读路径：MoW 写放大明显但读快，实时画像/订单状态基本必选，配 sequence 列可声明乱序到达时按谁的新旧为准；MoR 写便宜读贵。容量规划口诀：明细层 Duplicate + 按天分区（删分区秒级回收空间），报表层 Aggregate/Unique + rollup，不要指望一张表既存全量明细又扛所有报表。"
    },
    {
      "q": "Flink → Doris 链路的作业从 checkpoint 恢复后重放，Doris 侧出现大量 “Label Already Exists”。这是什么问题？",
      "options": [
        "导入事务堆积的故障信号，应立即删除这些 label 释放资源",
        "正常现象：label 是 Stream Load 的幂等键，重复提交同一 label 直接返回 Label Already Exists 而不会写两遍；at-least-once 的上游正是靠这层去重达到端到端 exactly-once，不要去删 label",
        "Doris FE 过载，需要重启 FE 清空 label 记录",
        "说明 sink.enable-2pc 配置错误，必须关掉两阶段提交"
      ],
      "answer": 1,
      "explain": "label = 前缀 + subtask + checkpointId，天然幂等。exactly-once 三前提缺一不可：source 可重放（Kafka offset 在 checkpoint）、算子状态随 checkpoint 持久化、sink 两阶段提交（先 precommit 写不可见数据，notifyCheckpointComplete 后才 commit 对查询可见）。恢复重放撞上已有 label 是幂等在起作用；真正要警惕的是 2PC 长时间不 commit 导致的导入事务堆积。这与 KafkaSink 的事务型 producer 是同一个模式，只是“事务”从 Kafka 事务日志换成了 label 的 precommit/commit。"
    },

    // --- ZooKeeper：协调服务（1 题）---

    {
      "q": "基于 ZooKeeper 的经典分布式锁（create -e -s /lock/node- 得到全局递增序号）中，等待者为什么只 watch “恰好比自己小一号”的节点，而不是 watch 整个 /lock 目录？",
      "options": [
        "watch 目录会被 ZooKeeper 拒绝，ZK 不支持目录级 watch",
        "为了减少 znode 数量，节省服务端内存",
        "只通知一个人：前驱释放/崩溃时只有下一个等待者被唤醒。若 watch 整个目录，任何节点变动都会唤醒全部 N 个等待者同时冲击 ZK——这就是羊群效应（herd effect）",
        "因为顺序节点的 watch 在协议上只能设在序号比自己小的节点上"
      ],
      "answer": 2,
      "explain": "临时 + 顺序节点是锁与选主的基石：临时节点把持有权与会话绑定（进程崩溃/断连即自动删除，无需人工清理），顺序节点由 ZK 保证分布式单调递增。等待链上“各 watch 自己的前驱”把唤醒做成链式，避免羊群效应。另注意 watch 是一次性的：触发即失效，收到事件后必须“重注册 + 全量读一次”处理丢失窗口；会话过期后所有 watch 与临时节点全部作废——这是大量“监听莫名失效”问题的根因。"
    }
  ]
};

// 共 245 题（pca 40 + cka 30 + cks 20 + basics 20 + linux 15 + programming 12 +
// cicd 20 + otel 12 + logging 11 + middleware/datastream/sre/cloud/aiops 各 10 + bigdata 15）
