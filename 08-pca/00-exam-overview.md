# 00 · PCA 考试概览与备考策略

> 模块：PCA 备考 ｜ 建议时长：1 小时（通读）＋ 持续备考参考 ｜ 关联认证：PCA（全域）

## 学习目标

- 能说出 PCA 的题量、时长、及格线与五大域权重
- 能描述 PCA 与 CKA/CKS 的题型差异（纯选择题 vs 实操题）以及由此带来的不同复习方法
- 能针对"概念辨析多、存在多选题"的特点建立一套审题与排除策略
- 能按一个可执行的四周计划把五个域的学习分配到本模块的 7 篇文件

## 1. PCA 是什么

PCA（Prometheus Certified Associate）是 CNCF/Linux Foundation 推出的 Prometheus 关联工程师认证，考察对 Prometheus 生态（指标、PromQL、告警、可视化）的概念级掌握。它定位为**入门级知识型认证**：

- 无硬性前置认证，不需要先过 CKA（但内容与 CKA 的可观测部分互补）
- 不考 Kubernetes 运维操作，考的是"你理不理解 Prometheus 这套系统的设计与用法"
- 官方页面（报名、费用、重考政策、证书有效期等商务条款以这里为准）：
  <https://training.linuxfoundation.org/certification/prometheus-certified-associate-pca/>

本模块读者已经在备考 CKA/CKS，这对 PCA 是优势：你有一个真实集群可以随手做实验，而 PCA 的核心难点 PromQL 恰恰是"看会了不会写、写一遍才会"的典型。

## 2. 考试形式

| 项目 | 说明 |
| --- | --- |
| 形式 | 线上考试，远程监考（摄像头＋屏幕共享＋房间检查），需要政府签发带照片证件 |
| 时长 | 90 分钟 |
| 题量 | 60 道选择题 |
| 题型 | 单选题为主，**存在多选题**（选所有符合项）；全部为知识题，无实操终端 |
| 及格线 | 75%（60 题约需对 45 题） |
| 语言 | 英文考题（以官方说明为准） |
| 出分 | 考后 24 小时内在 LF 账户出结果 |

与 CKA/CKS 最大的区别：CKA 是 2 小时实操，PCA 是 90 分钟概念问答。这决定了两件事：

1. **没有 terminal 可用**，所有 PromQL 题都是"读代码 + 心算结果"——你必须能靠眼睛判断一条查询返回什么类型、哪些序列会被选中、聚合后标签还剩什么
2. **节奏比深度更危险**，平均每题 1.5 分钟，读题慢比不会做更容易丢分

## 3. 官方大纲五域与本模块文件的映射

| 域 | 权重 | 核心考点 | 对应文件 |
| --- | --- | --- | --- |
| Observability Concepts | 18% | 可观测三支柱、SLI/SLO/错误预算、基数、push vs pull | 01 |
| Prometheus Fundamentals | 20% | 架构组件、pull 模型、服务发现、relabel、TSDB、HA、federation/remote_write | 02 |
| PromQL | 28% | 数据模型、selector、rate/increase、histogram、聚合、子查询 | 03 |
| Instrumentation and Exporters | 20% | 四种指标类型、client 库、exporter 体系、Pushgateway、label 设计 | 04 |
| Alerting and Visualization | 14% | alerting rules、Alertmanager 路由/分组/抑制/静默、Grafana 面板 | 05、06 |

两个读表要点：

- **PromQL 一个域占 28%**，接近三分之一。及格线 75% 意味着任何一域都不能整域放弃，但复习时间应当明显向 03 倾斜
- 告警与可视化合计只有 14%，且概念相对少（一张语义表＋一个状态机就覆盖大半），是**性价比最高**的得分域

本模块七篇文件的分工：

```
00-exam-overview             你在这里
01-observability-concepts    三支柱 / SLI-SLO-错误预算 / 高基数 / push vs pull
02-prometheus-architecture   组件 / pull / 服务发现 / relabel / TSDB / HA / federation
03-promql-guide              数据模型 / 函数辨析 / histogram 数学 / 子查询 / recording rules
04-instrumentation-exporters 指标类型选型 / client 埋点 / exporter 对比 / Pushgateway
05-alerting-alertmanager     for 状态机 / 路由树 / 分组语义 / 抑制与静默 / AM 集群
06-grafana-dashboards        数据源 / 变量 / 面板选型 / recording rules 配合
```

## 4. 题型特点与解题策略

### 4.1 概念辨析题占大头

典型问法："Which of the following about rate() is true?"，四个选项长得像四胞胎。高发辨析对：

| 经常互为干扰项的概念 | 一句话区分 |
| --- | --- |
| rate vs irate vs increase | 平均速率 / 瞬时速率 / 窗口内总量估算 |
| histogram vs summary | 服务端插值可聚合 / 客户端预算分位数不可聚合 |
| counter vs gauge | 只增（重置归零）/ 可升可降 |
| relabel_configs vs metric_relabel_configs | 抓取前作用于 target / 抓取后作用于样本 |
| group_wait vs group_interval vs repeat_interval | 新组首通知等待 / 组内容更新最小间隔 / 同内容重发间隔 |
| federation vs remote_write | 拉取式层级聚合 / 推送式远端长期存储 |
| node_exporter vs kube-state-metrics vs cAdvisor | 节点 OS / K8s 对象状态 / 容器运行时资源 |
| SLI vs SLO | 测量值 / 目标值 |

复习时每学一个概念，就逼自己回答"它和 XX 的区别一句话是什么"。答不出一句话，说明还没懂。

### 4.2 多选题策略

多选题通常按"全部选对才得分"计（以官方规则为准），半对不给分。策略：

- 先逐项独立判 true/false，把明显错的划掉；宁缺勿滥——两个必对＋一个五五开时，只选两个必对的
- 多选题最爱考"哪些场景适合 Pushgateway""哪些是 pull 模型的优点"这类**枚举型知识**，复习时主动把可枚举点整理成清单

### 4.3 PromQL 读代码题

给你一条查询，问返回类型、返回哪些序列或某个值。心算流程固定为四步：

1. selector 选中了哪些序列（正则是否锚定、label 匹配符）
2. 传给的是 instant vector 还是 range vector（有没有 `[5m]`）
3. 函数输出什么（rate 返回 per-second、increase 返回估算总量、可能带小数）
4. 聚合后 by/without 留下了哪些标签

这个流程只有在真实数据上练过十几遍才会变成本能，这正是下面备考策略的核心。

## 5. 备考策略：动手写胜过背

PCA 内容特点是"知识点都不深，但互相咬合"。背清单能应付 40% 的题，剩下 60% 需要"手感"。建议的四周计划（每天 1 小时）：

| 周 | 内容 | 动手任务 |
| --- | --- | --- |
| 第 1 周 | 文件 01 + 02 | 集群上装好 kube-prometheus-stack，curl 抓一次 /metrics，在 Web UI 里把 /targets 的每个字段看懂 |
| 第 2 周 | 文件 03 前半（数据模型、selector、rate 家族） | 每天在 Prom UI 写 10 条查询，故意改坏再看报错信息 |
| 第 3 周 | 文件 03 后半 + 04 | 自己埋点一个 Python 应用的 counter/histogram；把 histogram_quantile 跑通并观察插值误差 |
| 第 4 周 | 文件 05 + 06 + 全模块自测 | 触发一条真实告警走完 pending→firing→Alertmanager 全链路；Grafana 建一个三面板 dashboard |

三条原则：

1. **每个函数都在真实数据上调一次参数**。看 `rate(x[1m])` 和 `rate(x[5m])` 的曲线差异，比读十遍文档记得牢
2. **报错是最好的老师**。`vector selector must contain at least one non-empty matcher`、`expected type range vector` 这类报错本身就常被改编成考题
3. **用官方文档当地图，不用第三方题库当教材**。prometheus.io 的 querying/functions、practices/alerting、practices/histograms 三篇与考点重合度极高

## 6. 考前 48 小时清单

- 把五域各过一遍"一句话区分"表（4.1 节那张表自己扩写）
- 重做 03/05 文件里所有自测题，不展开答案先口算
- 熟记关键默认值：group_wait 30s、group_interval 5m、repeat_interval 4h、TSDB retention 15d、global scrape_interval 1m（helm 安装的监控栈常改为 30s，以 /api/v1/status/flags 实际输出为准）
- 确认证件、网络、监考软件要求；考试中遇到模糊措辞选"最一般、最不带附加条件"的那个选项

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 概念题四个选项都觉得对 | 只记了定义没记边界条件 | 每个概念配一个反例（如 summary 不能跨实例聚合） |
| PromQL 题时间不够 | 在脑内模拟完整求值过程 | 固定 4.3 节四步流程，先看类型再看数值 |
| 多选题总是差一个 | 靠模糊印象选 | 只选能说出理由的项，枚举型知识整理成清单背诵 |
| 模拟练习全对、真题发懵 | 只在熟悉的指标名上练过 | 换 job/label 名重新写同一批查询，练的是结构不是指标 |
| 时间分配失衡 | 在 18% 的域上耗了过多时间 | 按 4:4:8:4:2 的小时比例分配五域复习时间 |

## 自测

1. PCA 五域中权重最高的是哪个域？占多少？它与其他域复习投入的合理比例大概是多少？
<details><summary>答案</summary>

PromQL，28%。接近三分之一的权重，且是需要动手练习才能掌握的技能域，复习时间投入应显著高于其他域（其余四域合计 72% 但多为概念记忆）。及格线 75% 意味着即使 PromQL 全对，其他域也不能放弃超过四分之一。
</details>

2. 为什么"背题库"对 PCA 的效果明显差于对 CKA 的效果（同样是背）？
<details><summary>答案</summary>

CKA 考操作流程，流程可以背成肌肉记忆；PCA 考概念辨析和 PromQL 求值，题目换个指标名或换个措辞，背过的答案就不匹配了。PromQL 题要求对类型系统和函数语义的真实理解，不理解时甚至无法排除干扰项。
</details>

3. 一道多选题你确定其中两个选项正确，第三个五五开。选还是不选？为什么？
<details><summary>答案</summary>

不选。多选题通常全部选对才得分，选错一个导致整题零分，而少选一个也只是零分——但"确定正确的两个"已经保住了你在其他题上的时间与心态；期望值上，五五开的选项加选不加分反而可能致零，不选是更优策略（前提是无法进一步推理排除）。
</details>

4. 考试中遇到 "Which metric type should you use to compute quantiles that can be aggregated across instances?" 这类题，你的推理链是什么？
<details><summary>答案</summary>

抓关键词 "aggregated across instances"：summary 的分位数在客户端算好，跨实例只能平均分位数，数学上错误；histogram 把观测装进 cumulative bucket，服务端可用 histogram_quantile 对 sum by (le) 聚合后的桶重新计算分位数，数学上正确。因此答案 histogram。这类题的推理链是"关键词 → 数学性质 → 类型"。
</details>

5. 90 分钟 60 题，前 20 题你用了 40 分钟。给出应对方案。
<details><summary>答案</summary>

剩余 40 题 50 分钟，平均 1.25 分钟/题，节奏已偏慢。应对：先做一遍只挑一眼会的题，标记难的跳过；多选题超过 1 分钟无思路直接选最有把握的项提交；最后回头处理标记题。线上考试一般允许回看和修改答案（以考试界面实际功能为准），不要在一道题上死磕。
</details>

## 延伸阅读

- PCA 官方页面（报名与考试政策）：<https://training.linuxfoundation.org/certification/prometheus-certified-associate-pca/>
- Prometheus 官方文档入口：<https://prometheus.io/docs/introduction/overview/>
- 与考点重合度最高的三篇实践文档：<https://prometheus.io/docs/prometheus/latest/querying/functions/>、<https://prometheus.io/docs/practices/alerting/>、<https://prometheus.io/docs/practices/histograms/>
