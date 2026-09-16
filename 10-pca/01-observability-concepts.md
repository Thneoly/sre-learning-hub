# 01 · 可观测性概念：三支柱、SLI/SLO 与高基数

> 模块：PCA 备考 ｜ 建议时长：3 小时 ｜ 关联认证：PCA-可观测概念（18%）

## 学习目标

- 能分别说出 metrics/logs/traces 三支柱各自回答什么问题、各自的代价与互补关系
- 能用 PromQL 表达一个 SLI，并根据 SLO 算出错误预算与消耗速率
- 能解释"高基数"为什么是指标系统头号杀手，并判断一个 label 是否安全
- 能从健康检查、时间戳、负载控制等角度对比 push 与 pull 两种采集模型

## 1. 可观测性三支柱

### 1.1 各自回答什么问题

可观测性（observability）的定义：**仅凭系统的外部输出推断系统内部状态的能力**。它比"监控"更进一步——监控回答"我知道它坏了"，可观测性回答"我还知道为什么坏"。三支柱是三种外部输出：

```
              ┌──────────────┬──────────────┬──────────────┐
              │   Metrics    │    Traces    │    Logs      │
              │  （指标）     │  （追踪）     │  （日志）     │
├──────────────┼──────────────┼──────────────┼──────────────┤
回答的问题      │ 现在整体如何？│ 一个请求在哪慢│ 那一行代码出  │
              │ 趋势在变好?   │ 哪个环节出问题│ 了什么事      │
数据形态        │ 数字+时间戳   │ span 树       │ 离散事件文本  │
存储成本        │ 低（可聚合） │ 中            │ 高           │
适合告警        │ 最适合        │ 少量          │ 中           │
适合根因定位    │ 弱           │ 强（跨服务）  │ 强（细节）    │
典型工具        │ Prometheus   │ OpenTelemetry│ Loki/ELK     │
```

三者的互补关系是一条"漏斗"：

```
告警触发（metrics：错误率涨了）
    │  按 指标→trace 下钻（exemplar 关联 trace_id）
    ▼
定位环节（trace：支付服务到 DB 的 span 占了 800ms）
    │  按 trace_id 捞日志
    ▼
看到细节（log：connection pool exhausted）
```

exemplar 是把漏斗串起来的关键机制：histogram 的样本可以附带一个 exemplar（通常带 trace_id），Grafana 里点一个延迟桶就能跳到对应 trace。这就是"metrics 指路、traces 定位、logs 拍板"。

### 1.2 一个必须会做的辨析

"监控（monitoring）"与"可观测性（observability）"在考题中常互为干扰项：

- 监控是动作和工具集合：采集、看图、告警
- 可观测性是系统的属性：输出是否足以回答你**事先没想过要问**的问题
- 一个系统可以有完善的监控但可观测性很差（只有 CPU/内存图，出问题全靠猜）

## 2. SLI、SLO 与错误预算

### 2.1 定义链

```
SLI (Service Level Indicator)   指示器：一个精确定义的"好坏事件比值"
        │  设定目标
        ▼
SLO (Service Level Objective)   目标：SLI 在一段时间内要达到的值
        │  写进合同、带违约后果
        ▼
SLA (Service Level Agreement)   协议：法律层面的承诺（不达标赔钱）
```

只有 SLI 没有 SLO，就只是又一张图；有了 SLO，"稳定性"才变成可预算、可决策的量。

### 2.2 好的 SLI 长什么样

SLI 必须从**用户视角**定义，经典模板：`好事件数 / 总事件数`。

| 场景 | 好 SLI（用户视角） | 坏 SLI（内部视角） |
| --- | --- | --- |
| API 服务 | 非 5xx 响应占比；<300ms 完成的请求占比 | CPU 利用率、goroutine 数 |
| 存储 | 成功读写次数占比 | 磁盘队列长度 |
| 网站 | 首页可用探测成功率 | 交换机带宽 |

用 PromQL 表达一个"请求成功率" SLI（假设指标 `http_requests_total` 带 `code` 标签）：

```promql
# [Prometheus Web UI] 好事件 / 总事件
sum(rate(http_requests_total{code=~"2..|3..|4.."}[5m]))
/
sum(rate(http_requests_total[5m]))
```

```promql
# [Prometheus Web UI] 延迟 SLI：300ms 内完成的请求占比（histogram 指标）
sum(rate(request_latency_seconds_bucket{le="0.3"}[5m]))
/
sum(rate(request_latency_seconds_count[5m]))
```

### 2.3 错误预算：算一遍就永远会了

错误预算（error budget）＝ 1 − SLO。以"SLO = 99.9% 的请求成功，窗口 30 天"为例：

```
窗口总时长 = 30 × 24 × 60 = 43200 分钟
错误预算  = 43200 × (1 - 0.999) = 43.2 分钟   ← 30 天内允许的"全量不可用"时间
按请求算  = 每 100 万个请求允许 1000 个失败
```

错误预算的用途是把"稳不稳定"从争吵变成算术：

- 预算还剩很多 → 可以激进上线、做混沌实验
- 预算烧完 → 冻结发布，只修稳定性问题

### 2.4 消耗速率（burn rate）

预算消耗速率 = 实际错误率 / 允许的错误率。匀速花完 30 天预算就是 1x；烧得越快越该立刻告警。官方告警实践给出的经典组合（30 天窗口、99.9% SLO）：

| 意图 | 长窗口 | 短窗口 | burn rate 阈值 |
| --- | --- | --- | --- |
| 快速消耗（2% 预算/1h，立即 page） | 1h | 5m | 14.4 |
| 中速消耗（5% 预算/6h，page） | 6h | 30m | 6 |
| 慢速消耗（10% 预算/3d，工单） | 3d | 6h | 1 |

```promql
# [Prometheus Web UI] 快烧告警的表达式骨架：长窗口与短窗口同时超阈值
(
  sum(rate(http_requests_total{code=~"5.."}[1h]))
  /
  sum(rate(http_requests_total[1h]))
) > 14.4 * 0.001
and
(
  sum(rate(http_requests_total{code=~"5.."}[5m]))
  /
  sum(rate(http_requests_total[5m]))
) > 14.4 * 0.001
```

双窗口的意义：只有长短两个窗口都超阈值才告警，短窗口防止单个尖峰误报，长窗口防止慢漏不报。

## 3. 高基数：指标系统的头号杀手

### 3.1 机制

Prometheus 的每条时序由**指标名 + 一组唯一标签值**决定。同一个指标，标签组合有多少种，就有多少条时序：

```
http_requests_total{code="200",method="GET"}          ──> 1 条时序
     code ∈ {200,500}, method ∈ {GET,POST}            ──> 4 条时序
     再加 user_id ∈ 1,000,000 个用户                    ──> 4,000,000 条时序
```

基数（cardinality）就是**一个指标展开后的时序条数**。高基数的伤害是三重的：

1. **内存**：TSDB head 中每条活跃时序常驻内存（KB 级/条），百万级序列轻松把 Prometheus 推向 OOM
2. **查询**：一条 `sum(rate(http_requests_total[5m]))` 要对百万序列逐条计算再聚合，面板卡死
3. **抓取**：/metrics 响应体膨胀，scrape 超时（默认 10s）越来越常见

### 3.2 判断一个 label 是否安全

| 安全（有界） | 危险（无界或大集合） |
| --- | --- |
| code、method、region、env | user_id、email、session_id |
| instance（机器数可控） | request_id、trace_id、url 全路径带参数 |
| bucket 的 le（桶数固定） | container_id 全 hash、pod 全名（频繁重建时） |

经验法则：**先问"这个 label 的取值集合会不会随流量增长"，会的不进 label**。请求级细节属于 traces/logs，不属于 metrics；确实想从指标跳到 trace，用 exemplar 而不是把 trace_id 塞进 label。

### 3.3 现场诊断高基数

```promql
# [Prometheus Web UI] 时序总数（head 中活跃序列）
prometheus_tsdb_head_series

# [Prometheus Web UI] 按指标名统计各自贡献多少条时序，取前 10
topk(10, count by (__name__)({__name__=~".+"}))

# [Prometheus Web UI] 每秒入库样本数（速率异常时先看它）
rate(prometheus_tsdb_head_samples_appended_total[5m])
```

## 4. push vs pull：模型之争

### 4.1 两种采集方向

```
push（推送）                          pull（拉取，Prometheus 的选择）
┌────────┐   指标    ┌────────┐      ┌────────┐   定时 HTTP GET   ┌────────┐
│ 应用 A │ ────────> │ 采集端  │      │ 采集端  │ ────────────────> │ 应用 A │
│ 应用 B │ ────────> │        │      │(Prometh)│ <──── /metrics ── │ 应用 B │
└────────┘           └────────┘      └────────┘                   └────────┘
客户端知道服务端地址                  客户端只需暴露端口，不知道谁来抓
```

### 4.2 权衡表

| 维度 | pull（Prometheus） | push |
| --- | --- | --- |
| 健康检查 | 天然内置：抓不到即 `up == 0`，"没数据"本身就是信号 | 沉默有歧义：是没得推还是进程死了？需额外心跳 |
| 客户端状态 | 目标无状态，只要暴露 HTTP 端点 | 客户端要保存重试队列、处理推送失败 |
| 配置中心点 | 集中在 Prometheus（改抓取策略不用动应用） | 每个客户端要配服务端地址与凭证 |
| 调试 | `curl http://目标/metrics` 即见原始数据，本地可复现 | 需查服务端是否收到、何时收到 |
| 时间戳 | 由服务端统一打点（默认抓取时刻），时钟一致性好 | 依赖各客户端时钟，NTP 漂移直接歪数据 |
| 过载控制 | 服务端控制抓取频率与并发，目标只被动应答 | 服务端难以拒绝恶意/失控客户端的洪泛 |
| NAT/防火墙 | Prometheus 必须能直连目标（跨网段要额外方案） | 客户端只要能出站即可，穿 NAT 更自然 |
| 短命任务 | 进程退出即消失，抓不到（需 Pushgateway 中转） | 退出前推一把即可，天然适配 |

### 4.3 考试视角的结论

- Prometheus 选 pull 的核心理由记三条：**抓取失败即可见（天然健康检查）、目标端零状态、集中配置与统一时钟**
- push 不是"错误答案"，而是"不同场景的答案"：批处理作业、NAT 后目标、极短生命周期进程是 push 的主场，Prometheus 用 **Pushgateway** 补这个位（详见 04 文件）
- 考题常把"pull 模型下如何监控 5 分钟一次的 cron job"作为辨析点：答案是 Pushgateway，而它在长驻服务上是反模式

## 实战演练：把概念落在集群上

环境：kubeadm 单 master 集群（Calico CNI）。先装 kube-prometheus-stack（详细讲解见 02 文件，此处三条命令速装）：

```bash
# [master] 安装监控栈（若本仓库 scripts/setup/install-prom-stack.sh 已就绪可直接使用）
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install prom-stack prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
```

```bash
# [master] 等待就绪后转发 Prometheus Web UI 到本地
kubectl -n monitoring wait --for=condition=Available deployment/prom-stack-grafana --timeout=300s
kubectl -n monitoring port-forward svc/prom-stack-kube-prom-prometheus 9090:9090
```

浏览器打开 <http://localhost:9090>，依次完成三件事：

1. **看原始指标文本**：`curl -s http://<node-ip>:9100/metrics | head -20`（node-exporter 以 hostPort 9100 运行在每个节点），亲眼看到 `# TYPE` 注释与 `指标名{标签="值"} 数字` 的 exposition 格式
2. **验证 SLI 查询**：在 Web UI 执行 2.2 节的延迟 SLI，把 `request_latency_seconds` 全局替换为 `prometheus_http_request_duration_seconds`（监控栈自带），确认能返回 0~1 之间的数
3. **量化本集群基数**：执行 3.3 节三条诊断查询，记下 `prometheus_tsdb_head_series` 的值；再执行 `topk(10, count by (__name__)({__name__=~".+"}))`，找出本集群贡献时序最多的指标——通常是 cAdvisor 的 `container_*` 家族

预期结果：三步都有数字返回；第 3 步你会直观看到一个几节点的小集群也有几万条时序，从而理解为什么"基数"在所有设计讨论里排第一。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| SLI 定成"CPU 使用率 < 80%" | 从内部视角而非用户视角定义 | 先问"用户感受到什么"，再找能代理它的比值型指标 |
| 错误预算算出 43.2 分钟却当成"每月可停机 43 分钟随便停" | 忽略预算是给变更与风险用的管理工具 | 预算烧完应触发发布冻结，而不是停机配额 |
| 面板越做越卡、Prometheus 内存爬升 | 某个指标被加了高基数 label | 用 `topk(10, count by (__name__)({__name__=~".+"}))` 定位元凶，label 放日志或删掉 |
| push 模型下服务挂了但监控一切正常 | 沉默被误读为健康 | push 系统必须有独立心跳/存活指标 |
| 多团队各算各的"可用性"数字对不上 | SLI 定义不一致（分子分母口径不同） | SLI 定义写进文档并对齐到用户可见行为 |

## 自测

1. 为什么"metrics → traces → logs"是排查的下钻顺序，而不是反过来？
<details><summary>答案</summary>

metrics 聚合程度最高、成本最低，适合持续扫描全量信号并在异常时触发告警；traces 把一个问题请求的完整路径摊开，代价是采样且需按 trace_id 定位；logs 细节最全但量最大，只适合在已知时间、已知组件后精确捞取。反过来从日志开始等于在海量低信号数据里盲搜，成本不可接受。
</details>

2. SLO 定成 100% 有什么问题？
<details><summary>答案</summary>

错误预算为 0：任何一次失败都违反 SLO，告警会永久触发，团队要么麻木要么冻结所有变更。100% 可用性在工程上也不可达（网络分区、节点故障是常态）。合理做法是选一个"用户几乎无感"的目标（如 99.9%），把剩余预算当风险管理资源。
</details>

3. 同样是"每用户请求数"，`http_requests_total{user_id="..."}` 和"按 user_id 分维度的日志统计"差别在哪？
<details><summary>答案</summary>

前者把 user_id 作为 label，百万用户即百万时序，直接制造高基数（内存、查询、抓取三重代价）；后者发生在日志系统里，按需过滤聚合，不预付存储成本。无界集合只配进 logs/traces，metrics 的 label 必须有界。
</details>

4. pull 模型要求 Prometheus 能直连所有目标，跨 VPC/NAT 场景怎么办？这算 pull 的缺陷吗？
<details><summary>答案</summary>

可用方案：在目标侧网络跑一个 Prometheus（federation/remote_write 汇聚）、Pushgateway 中转短任务、或代理暴露端点。这是 pull 的真实代价（连通性前提），考题问"pull 的缺点"时应列出；但换来的收益是抓取失败即失联告警、目标端零状态、统一时钟——权衡而非缺陷。
</details>

5. 一个服务 SLO 是"99% 的请求 < 500ms（30 天窗口）"，某天延迟 SLI 跌到 98.5%。这一定该立刻 page 吗？给出判断框架。
<details><summary>答案</summary>

不一定。看消耗速率而非单点值：98.5% 意味着错误率 1.5%，是允许值（1%）的 1.5 倍 burn rate，30 天窗口下这只是慢速消耗（按 3d+6h 双窗口、1x 阈值发工单即可）。是否 page 取决于 burn rate 与窗口的组合（快烧才 page），而不是 SLI 是否跌破 SLO——SLO 本身是 30 天的统计目标，瞬时跌破是常态。
</details>

## 延伸阅读

- Prometheus 概述（含三支柱定位）：<https://prometheus.io/docs/introduction/overview/>
- Google SRE 书监控章节：<https://sre.google/sre-book/monitoring-distributed-systems/>
- Google SRE 手册 SLO 实施章：<https://sre.google/workbook/implementing-slos/>
- Prometheus 告警实践（burn rate 双窗口）：<https://prometheus.io/docs/practices/alerting/>
