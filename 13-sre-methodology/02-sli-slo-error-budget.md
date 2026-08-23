# 02 · SLI/SLO 与错误预算：给可靠性定价

> 模块：13-sre-methodology ｜ 建议时长：5 小时 ｜ 关联认证：PCA-PromQL / PCA-告警（燃烧率告警直接复用 08-pca 的规则与路由机制）

## 学习目标

- 能用"好事件 / 总事件"的口径写出请求式与窗口式两类 SLI，并避开"拿系统指标当 SLI"的错误
- 能按用户旅程法为一个小服务定出一组可执行的 SLO（含 SLI 定义、窗口、目标、责任人）
- 能手工计算错误预算，并设计"预算烧穿 → 冻结发布"的止损规则
- 能解释多窗口多燃烧率告警的公式来源，并写出可直接执行的 PromQL
- 能说清 SLA 与 SLO 在受众、宽严、后果上的区别

## 1. 四层指标：SLI → SLO → Error Budget → SLA

```
┌─ SLI ──────────── Service Level Indicator：测什么
│   "过去 5 分钟非 5xx 响应占比 99.97%"——它只是一个测量值
│
├─ SLO ──────────── Service Level Objective：要达到多少
│   "30 天内该 SLI ≥ 99.9%"——工程团队对内的目标
│
├─ Error Budget ─── 错误预算 = 1 − SLO
│   99.9% → 允许 0.1% 的"坏"：发版风险、硬件故障全从这里扣
│   预算是创新与稳定之间的货币：有余额才允许激进变更
│
└─ SLA ──────────── Service Level Agreement：对外合同
    "月度可用性低于 99.5% 赔付代金券"——法务与商务口径，通常比 SLO 松
```

一句话记住分工：**SLI 是仪表读数，SLO 是内部及格线，错误预算是及格线之外的挥霍额度，SLA 是写进合同的底线**。

## 2. SLI 选择：好事件除以总事件

### 2.1 通用公式

一切 SLI 都能写成两种口径之一：

| 口径 | 公式 | 适用 |
|------|------|------|
| 请求式（事件式） | 好事件数 / 总事件数 | 有明确请求边界的在线服务：API、页面加载 |
| 窗口式（时间式） | 状态良好的时间占比 | 无请求语义的组件：副本可用性、数据新鲜度 |

请求式的经典三兄弟：

```promql
# [Prometheus Web UI] 可用性：非 5xx 占比（好事件 = code 非 5xx 的响应）
sum(rate(http_requests_total{job="api",code!~"5.."}[5m]))
/ sum(rate(http_requests_total{job="api"}[5m]))

# [Prometheus Web UI] 延迟：快于 400ms 的请求占比（好事件 = 落在 le="0.4" 桶内）
sum(rate(http_request_duration_seconds_bucket{job="api",le="0.4"}[5m]))
/ sum(rate(http_request_duration_seconds_count{job="api"}[5m]))

# [Prometheus Web UI] 正确性：业务成功占比（好事件 = result="ok"）
sum(rate(biz_results_total{job="api",result="ok"}[5m]))
/ sum(rate(biz_results_total{job="api"}[5m]))
```

窗口式例子（本课实战演练会用到，直接以 Prometheus 抓取成功与否为状态）：

```promql
# [Prometheus Web UI] 目标可用时间占比：up=1 的采样点比例
avg_over_time(up{job=~"grafana.*"}[1h])
```

### 2.2 选 SLI 的三条铁律

1. **从用户视角出发**：用户感知的是"页面打不开""下单失败"，不是 CPU 90%。CPU、内存、队列长度是**诊断指标**，可以触发告警帮助定位，但不能当 SLI——把它们调好了用户未必受益。
2. **少而关键**：一条用户旅程（user journey）至多配 3 个 SLI，通常就是可用性 + 延迟 +（如有）正确性/新鲜度。SLI 多到一屏放不下等于没有重点。
3. **可测量、有归属**：每个 SLI 要能落到具体 metric 与查询语句，且有一个明确的责任团队；查不出来的"体感可用性"不可运营。

常见 SLI 菜单（按服务类型）：

| 服务类型 | 推荐SLI |
|----------|---------|
| 在线 API/网关 | 非错误响应占比；快于阈值占比 |
| 网页前端 | 页面可渲染占比；首屏 < 2s 占比 |
| 存储/数据库 | 读写成功率；P99 延迟达标占比 |
| 流水线/批处理 | 按时完成占比；数据新鲜度 < 15min 占比 |

## 3. SLO 设定方法与示例

### 3.1 五步法

1. **列用户旅程**：用户怎么用这个系统？挑出"失败即流失"的关键路径。
2. **配 SLI**：每条旅程 ≤ 3 个（第 2 节铁律）。
3. **定初始目标**：拿最近 30 天实测数据做基准，目标定在"比现状略好、努力可达"的位置（例如实测 99.7%，目标 99.9%）；没有数据时参考同行业标准，先宽后紧。
4. **写成 SLO 文档**：每个 SLO 必含五要素——SLI 定义（含查询语句）、窗口、目标值、责任人、**预算烧穿的后果**（缺最后一条的 SLO 是装饰品）。
5. **季度复盘**：预算常年用不掉（消耗 < 10%）说明目标太松，可以收紧释放变更速度；经常烧穿说明目标脱离现实或可靠性欠债太多，要么投入工程要么放宽。

### 3.2 目标值速算表（30 天窗口）

| SLO 目标 | 30 天允许的完全不可用时间 |
|----------|--------------------------|
| 99% | 7 小时 12 分 |
| 99.5% | 3 小时 36 分 |
| 99.9% | 43 分 12 秒 |
| 99.95% | 21 分 36 秒 |
| 99.99% | 4 分 19 秒 |

两个直接推论：目标每多一个 9，预算缩小 10 倍而成本通常指数上升；**100% 是非法目标**——既不可达也无意义，等价于宣布任何变更都不该发生。

### 3.3 示例：一个门户站点的 SLO 集

```text
<!-- 存放于 git 仓库 docs/slo/portal.md，产品与工程共同签署后生效 -->
SLO 文档 · 学习中心门户（demo）
─────────────────────────────────────────────────────────────
用户旅程：学员打开门户并浏览课程页

SLI-1 可用性（请求式）
  定义：5 分钟窗口内非 5xx 响应占比
  查询：sum(rate(http_requests_total{job="portal",code!~"5.."}[5m]))
        / sum(rate(http_requests_total{job="portal"}[5m]))
  SLO：滚动 30 天 ≥ 99.9%（预算 43 分钟/30 天）
SLI-2 延迟（请求式）
  定义：P99 视角——响应时间 < 400ms 的请求占比
  SLO：滚动 30 天 ≥ 99%（慢请求预算 1%）
责任人：平台组
烧穿后果（两个 SLO 任一适用）：
  预算剩余 < 25%：发版需双人评审
  预算耗尽：冻结非可靠性变更，直到预算回正；可靠性任务优先排期
```

## 4. 错误预算：消耗、观测与止损

### 4.1 计算与查询

预算消耗率 = 实际错误率 / 允许错误率。SLO 99.9% 时允许错误率 0.001：

```promql
# [Prometheus Web UI] 过去 30 天 Grafana 的预算已消耗比例（>1 即超支）
(1 - avg_over_time(up{job=~"grafana.*"}[30d])) / 0.001

# [Prometheus Web UI] 预算剩余比例（负数会被下限截为 0 更好读）
1 - (1 - avg_over_time(up{job=~"grafana.*"}[30d])) / 0.001
```

注意：**窗口不能超过 Prometheus 的 retention**。练习环境按 `scripts/setup/install-prom-stack.sh` 默认装出来 retention 只有 3d，`[30d]` 窗口拿不满数据，算出来的"预算消耗"会虚假地偏小——生产要么调大 retention，要么接受基于 3d 的滚动近似。

### 4.2 止损：预算烧完就冻结发布

错误预算的价值全在"预先约定、自动执行"的后果上，推荐三档：

| 预算状态 | 触发 | 动作 |
|----------|------|------|
| 剩余 > 25% | 正常 | 正常发版节奏 |
| 剩余 ≤ 25% | 预警 | 非必要变更延后；发版需双人评审；排查预算大头来源 |
| 耗尽（≤ 0） | 止损 | 冻结功能发布，只允许安全修复与可靠性变更；团队转入还债 |

关键点：冻结规则必须**事先与产品方写进 SLO 文档**（第 3.3 节五要素的最后一条）。预算烧穿才去和产品吵"要不要停发"，说明这套体系还没建起来。反向同理——预算大量结余时，应该主动说服产品方"这个季度可以更激进"，让预算双向发挥作用。

## 5. 燃烧率告警：多窗口多燃烧率

### 5.1 公式与推导

**燃烧率（burn rate）= 实际错误率 / SLO 允许的错误率**。匀速烧穿全部预算时 burn rate = 1；burn rate = 10 表示按当前速度 1/10 个窗口就会烧完全部预算。

告警的困境：对"快速大火"要分钟级 page；对"缓慢渗漏"要小时~天级 ticket 且不惊动睡眠中的人。单窗口做不到两全，于是有了**多窗口多燃烧率**：长短两个窗口同时越过阈值才告警（短窗口防抖、长窗口定严重度），并用不同燃烧率分档。

Google SRE Workbook 第 5 章的经典参数（30 天 SLO）：

| 档位 | 长窗口 | 短窗口 | 燃烧率 | 该档消耗预算 | 动作 |
|------|--------|--------|--------|--------------|------|
| 快火 | 1h | 5m | 14.4 | 2% | page（立即处理） |
| 中火 | 6h | 30m | 6 | 5% | page |
| 慢火 | 3d | 6h | 1 | 10% | ticket（工作时间处理） |

数字不是拍脑袋：`14.4 × (1h/720h) = 2%`，`6 × (6h/720h) = 5%`，`1 × (3d/30d) = 10%`——每一档都对应"烧掉预算的多大比例"，这就是阈值之间的内在逻辑。

### 5.2 生产模板（30d SLO、99.9%、请求式 SLI）

```promql
# [Prometheus Web UI] 快火档：1h 与 5m 双窗口同时越过 14.4 × 0.001
(
  sum(rate(http_requests_total{job="api",code=~"5.."}[5m]))
/ sum(rate(http_requests_total{job="api"}[5m]))
) > (14.4 * 0.001)
and
(
  sum(rate(http_requests_total{job="api",code=~"5.."}[1h]))
/ sum(rate(http_requests_total{job="api"}[1h]))
) > (14.4 * 0.001)

# [Prometheus Web UI] 慢火档：3d 与 6h 双窗口同时越过 1 × 0.001 → 走 ticket
(
  sum(rate(http_requests_total{job="api",code=~"5.."}[6h]))
/ sum(rate(http_requests_total{job="api"}[6h]))
) > (1 * 0.001)
and
(
  sum(rate(http_requests_total{job="api",code=~"5.."}[3d]))
/ sum(rate(http_requests_total{job="api"}[3d]))
) > (1 * 0.001)
```

`and` 两侧向量 label 集合一致才能匹配（这里两侧都聚合到无 label 的单序列，天然匹配）。分母为 0（无流量）时除式无样本，告警静默——这是特性不是 bug：没流量就没有用户受影响。

告警的路由（page 打给谁、ticket 进哪个队列、分组与静默）在 08-pca/05-alerting-alertmanager.md 已展开，本课只管"expr 怎么写、阈值怎么来"。PromQL 基础（rate/聚合/子查询）见 08-pca/03-promql-guide.md。

## 6. SLA 与 SLO 的区别

| 维度 | SLA | SLO |
|------|-----|-----|
| 性质 | 商业合同条款 | 内部工程目标 |
| 受众 | 客户、销售、法务 | 工程、产品团队 |
| 违约后果 | 赔付、退款、合同解除、声誉 | 冻结发布、可靠性投入、复盘 |
| 宽严 | 通常更松（给履约留缓冲） | 通常更严（内部先于客户发现劣化） |
| 度量口径 | 自然月/合同期，事后审计 | 滚动窗口，实时可查 |
| 能否没有 | 可以（内部产品无 SLA） | 不该没有（没有 SLO 就没有预算） |

典型组合：SLA 99.5%（跌破赔付代金券）+ 内部 SLO 99.9%。内部目标更严，使得团队在客户感知之前就收到燃烧率告警；SLA 只承诺 99.5%，给内部留出 0.4% 的缓冲带。**用 SLA 的口径做内部目标**是常见错误：等到合同线才报警，赔付已经在路上。

## 实战演练：给 Grafana 定一个 SLO，烧掉它，再算账

环境：kubeadm 集群 + `scripts/setup/install-prom-stack.sh` 装好的 kube-prometheus-stack（ns `monitoring`，release `prom`，retention 3d）。

练习口径说明：因 retention 3d，实战采用**1 小时窗口的练习 SLO**——机制与生产完全同构，只是窗口缩短。

```
<!-- 练习口径的 SLO 文档，同样遵循 3.3 节五要素 -->
SLO 文档（练习）：Grafana 可用性
  SLI：窗口式，avg_over_time(up{job=~"grafana.*"}[1h])
  目标：≥ 99%（1 小时错误预算 = 36 秒完全不可用）
  燃烧率分档（窗口等比缩小）：page 档 burn 14.4，窗口 10m/1m
```

### Step 1 提交 recording rule + 燃烧率告警

```yaml
# [master] grafana-slo-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: grafana-slo
  namespace: monitoring
  labels:
    release: prom            # 必须与 helm release 名一致，operator 靠它选规则
spec:
  groups:
    - name: grafana-slo.record
      interval: 30s
      rules:
        - record: slo:grafana:avail_ratio_1m
          expr: avg_over_time(up{job=~"grafana.*"}[1m])
        - record: slo:grafana:avail_ratio_10m
          expr: avg_over_time(up{job=~"grafana.*"}[10m])
        - record: slo:grafana:avail_ratio_1h
          expr: avg_over_time(up{job=~"grafana.*"}[1h])
    - name: grafana-slo.alert
      interval: 30s
      rules:
        - alert: GrafanaSLOBurnRateFast
          expr: |
            (1 - slo:grafana:avail_ratio_1m) > (14.4 * 0.01)
            and
            (1 - slo:grafana:avail_ratio_10m) > (14.4 * 0.01)
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Grafana SLI 燃烧率 >14.4（1h 练习窗口）"
```

```bash
# [master] 应用并确认规则被加载
kubectl apply -f grafana-slo-rules.yaml
kubectl -n monitoring port-forward svc/prom-kube-prometheus-stack-prometheus 9090:9090 &
sleep 10
curl -s http://localhost:9090/api/v1/rules | grep -o '"name":"GrafanaSLOBurnRateFast"'
```

预期输出：`"name":"GrafanaSLOBurnRateFast"`。若为空，九成是 `release` 标签与 `helm ls -n monitoring` 的 release 名不一致。

### Step 2 基线确认

```promql
# [Prometheus Web UI] http://localhost:9090/graph
slo:grafana:avail_ratio_1h
```

预期当前值 = 1（Grafana 一直在线）。这就是"稳态"。

### Step 3 制造故障，观测燃烧

```bash
# [master] 把 Grafana 缩为 0（与 08-pca 告警课同一手法）
kubectl -n monitoring scale deployment/prom-grafana --replicas=0
date +%T
```

时间线预期（保持故障约 6 分钟）：

- T+0~1min：`up` 翻 0，`slo:grafana:avail_ratio_1m` 掉到 0；
- T+1.5min 左右：10m 窗口平均值越过 14.4%（0.144），双窗口条件首次同时满足，告警进入 **Pending**（/alerts 页可见）；
- 再满 `for: 2m`：变 **Firing**，severity=critical 走向 Alertmanager（路由见 08-pca/05）；
- 同期在 UI 查预算消耗：

```promql
# [Prometheus Web UI] 预算已消耗比例（允许错误率 0.01）
(1 - slo:grafana:avail_ratio_1h) / 0.01
```

### Step 4 恢复并结算

```bash
# [master] 恢复 Grafana，观察告警 resolved
kubectl -n monitoring scale deployment/prom-grafana --replicas=1
```

```promql
# [Prometheus Web UI] 结算：本次 6 分钟完全故障在 1h 窗口里的错误占比
1 - slo:grafana:avail_ratio_1h
```

预期约 0.1（6min/60min）——**单次 6 分钟故障消耗了 10 倍的小时预算**（允许 0.01，实际 0.1）。对照第 4.2 节止损表：若这是真实 SLO，此刻应当处于"冻结非可靠性变更"状态。把这次消耗记进演练笔记，第 4 章复盘课会拿它当素材。

清理：保留 `grafana-slo-rules.yaml`（后续课程复用），杀掉 port-forward（`jobs` 查后台任务后 `kill %1`）。

## 常见坑

| 症状 | 原因 | 解法 |
|------|------|------|
| SLO 定了 100% | 把"追求完美"带进工程目标 | 100% 等于零预算零变更；从 99%/99.9% 起步，用数据逼近上限 |
| SLI 用 CPU/内存占比 | 混淆诊断指标与用户体验指标 | SLI 只从用户旅程出发；资源指标留给定位告警 |
| 燃烧率告警从不触发 | 长窗口（1h/3d）超过 retention，`avg_over_time` 拿不满数据 | 检查 `--storage.tsdb.retention.time`，窗口 ≤ retention；或调大 retention |
| 预算烧穿了没人动作 | SLO 文档缺"烧穿后果"五要素 | 事先与产品签订冻结规则，并让预算剩余量出现在发版流程里 |
| 告警只盯"预算耗尽"瞬间 | 耗尽才报 = 只能事后救火 | 用燃烧率分档（14.4/6/1）在烧掉 2%/5%/10% 时就分级响应 |
| 双窗口告警频繁误报 | 短窗口太短（如 30s）被瞬时抖动击穿 | 短窗口 ≥ 4×抓取间隔，且必须与长窗口同时越线（`and`） |

## 自测

<details><summary>1. 为什么多窗口告警需要长、短两个窗口同时越线，而不是只看短窗口？</summary>

短窗口（如 5m）灵敏但易被瞬时抖动击穿：一次抓取超时、一次瞬时 5xx 尖峰就可能让 5 分钟错误率冲高。加上长窗口（如 1h）同时越线，相当于要求"问题不仅在最近几分钟存在，而且已持续到拉高了 1 小时均值"——长窗口定严重度、短窗口定灵敏度，两者相与兼顾快速检出与低误报。
</details>

<details><summary>2. 30 天 99.9% 的 SLO 下，burn rate 14.4 的 1 小时窗口为什么对应"烧掉 2% 预算"？</summary>

允许错误率 = 0.001。burn rate 14.4 意味着当前错误率 = 14.4 × 0.001 = 0.0144；持续 1 小时消耗的错误量 = 0.0144 × 1h = 0.0144 小时"全错时间"。30 天总预算 = 0.001 × 720h = 0.72h。占比 = 0.0144/0.72 = 2%。所有档位的阈值都能这样从"想让它消耗多少比例预算"反推出来。
</details>

<details><summary>3. 你的服务流量高峰在白天、深夜几乎为零，分母趋近 0 时请求式 SLI 会出现什么问题？</summary>

PromQL 中分母为 0 时除式无样本，SLI 序列在深夜"消失"；若告警 expr 依赖该序列，深夜将静默——低流量时这通常无害。但若担心少量请求时的比值剧烈摆动，可以：给 SLI 加最小流量下限（分母 < 阈值时视为 1 或直接告警"无流量"）；或对窗口式 SLI 用 `avg_over_time` 口径替代；另加一条独立的"零流量"告警区分"没人用"与"探测不到"。
</details>

<details><summary>4. 产品经理说"下个月大促，SLO 先放宽到 99%，过完再调回 99.9%"。你怎么评估这个提议？</summary>

机制上是合法操作：SLO 本来就该按业务节奏与产品共同修订，大促期间主动放宽等于预留更大错误预算给变更与过载风险，避免冻结机制在大促关键期卡死发版。但要满足三点：修订要提前生效并写进 SLO 文档（不能事后补）；放宽容户侧体验要有依据（99% 意味着 30 天允许 7.2 小时不可用，客户是否可接受）；大促结束必须复位并复盘实际消耗，防止"临时放宽"变成永久放松。
</details>

<details><summary>5. SLA 承诺月度 99.95%，工程团队把内部 SLO 也定为 99.95%。这个设计有什么隐患？</summary>

内部目标与合同线重合，等于没有缓冲带：内部燃烧率告警触发时，SLA 违约已在同一条线上，团队没有提前处置的窗口。标准做法是内部 SLO 严于 SLA（如 SLA 99.95% + SLO 99.99%），用两者之间的差值做预警缓冲；同时注意口径差——SLA 按自然月事后审计，SLO 按滚动窗口实时计算，两者的"同一时刻读数"本来就不相等。
</details>

## 靶场联动：靶场是这些方法论的练习场

本课的每个概念都能在靶场里"花掉"：跑 `sudo bash scripts/faults/break-coredns.sh`，集群 DNS 解析全停——如果你按第 2 节给业务 Pod 的 http 探测定了 SLI，此刻它的燃烧率会立刻飙到三位数，快火档告警应当在几分钟内 page 你。12 个 break 脚本就是 12 种"预算燃烧场景"：注入前先写下你预期 SLI 曲线的形状，注入后对照实际曲线，这种"预测 → 验证"正是把 SLO 从文档变成肌肉记忆的方法。第 5 章混沌工程会把这个流程系统化。

## 延伸阅读

- SRE Book 第 3 章 Embracing Risk（错误预算）：https://sre.google/sre-book/embracing-risk/
- SRE Book 第 4 章 SLOs：https://sre.google/sre-book/service-level-objectives/
- SRE Workbook 第 5 章 Alerting on SLOs（多窗口多燃烧率原始出处）：https://sre.google/workbook/alerting-on-slos/
- Prometheus 官方文档 · recording rules：https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/
