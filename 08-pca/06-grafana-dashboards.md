# 06 · Grafana：数据源、变量模板与面板选型

> 模块：PCA 备考 ｜ 建议时长：2 小时 ｜ 关联认证：PCA-告警与可视化（14%）

## 学习目标

- 能在 kubeadm 集群里把 Grafana 接到 Prometheus，并解释数据源 URL 为什么指向 Service
- 能用 query variable + label_values 建立可复用的 dashboard 模板，并在查询中正确引用
- 能为给定数据形态选择正确面板（stat/time series/heatmap 等）并说明理由
- 能用 recording rules 预聚合减轻面板查询压力，并知道何时值得这么做

## 1. Grafana 在链路中的位置与数据源

Grafana 不是存储，只是"读视图"：它把 PromQL 发给 Prometheus 的 HTTP API，拿即时/区间结果画图。第一件事是配数据源：

- kube-prometheus-stack 安装时**自动**创建了名为 `Prometheus` 的数据源（CRD `PodMonitor` 之外，它用 sidecar 里的 datasource 配置）
- 手工添加时，URL 必须是 **Grafana 容器可达**的地址。集群内就是 Service DNS：

```yaml
# [master] 手工配置数据源时的关键字段（Grafana UI: Connections → Data sources → Add）
Name:     Prometheus
URL:      http://prom-stack-kube-prom-prometheus.monitoring.svc.cluster.local:9090
Access:   Server (proxy)      # 由 Grafana 后端代为查询，浏览器不需要直达
```

```bash
# [master] 拿到自动生成的 Grafana 管理员密码（默认用户 admin）
kubectl -n monitoring get secret prom-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d
kubectl -n monitoring port-forward svc/prom-stack-grafana 3000:80
```

浏览器打开 <http://localhost:3000>，admin + 上一步密码登录（chart 默认密码为 `prom-operator`）。

## 2. 变量模板：一个 dashboard 服务所有对象

### 2.1 建变量

Dashboard → Settings → Variables → New，Type 选 **Query**，数据源选 Prometheus：

| 变量 | Query | 说明 |
| --- | --- | --- |
| `job` | `label_values(up, job)` | 列出所有抓取 job |
| `instance` | `label_values(up{job=~"$job"}, instance)` | **级联**：随 job 的选择变化 |
| `interval`（Interval 变量） | 值 `1m,5m,15m,1h` | 控制 rate 窗口（见 2.3） |

`label_values(序列选择器, 标签名)` 从当前序列的标签里取去重值列表——这是变量查询最常用的函数。

### 2.2 在查询里引用

勾选 Multi-value 与 Include All 后，变量在查询里有两种形态：

```promql
# [Grafana 面板] 单值等匹配
up{job="$job"}

# [Grafana 面板] 多值正则匹配（选了多个/All 时必须用 =~）
up{job=~"$job", instance=~"$instance"}
```

选了多项或 All 时 Grafana 把 `$job` 渲染成 `(a|b|c)` 形式的正则，因此必须配 `=~`；用 `=` 会因值不再是单个字符串而失配——这是变量模板第一坑。

变量还能用在标题、面板文本、dashboard 链接里（`$job`），让一张图按所选对象自动改标题。

### 2.3 与 rate 窗口联动

面板里 rate 的窗口可用变量控制，配合 Grafana 内置的 `$__rate_interval`（自动取"至少 4×抓取间隔、不小于 15s"）恰好满足 03 文件 6.4 节的"窗口 ≥ 4×间隔"法则：

```promql
# [Grafana 面板] 用内置动态窗口，缩放时间范围也不破功
rate(node_cpu_seconds_total{mode="idle", instance=~"$instance"}[$__rate_interval])
```

## 3. 面板选型：数据形态决定面板

| 面板 | 数据形态 | 典型查询 | 不适合 |
| --- | --- | --- | --- |
| Time series | 每序列一条线，随时间变化 | `rate(...)`、gauge 趋势 | 只有"当前值"意义的指标（如 build_info） |
| Stat | 一个当前数 + 阈值着色 | `count(up == 0)`、错误率、`prometheus_tsdb_head_series` | 多序列（会挤成一排小方块） |
| Gauge | 当前值对着满量程 | 内存/磁盘使用率 | 时序趋势 |
| Bar gauge | 按标签并列的当前值排名 | 每节点当前 CPU/内存 | 精细历史 |
| Table | 行=序列，列=当前值/最近变化 | `topk(...)` 结果、对象清单 | 趋势 |
| State timeline | 离散状态块随时间 | `up`、`kube_node_status_condition` | 连续浮点值 |
| Heatmap | histogram 桶 × 时间的密度 | `_bucket` 序列（见 3.1） | 非 histogram 指标 |

选型口诀：**看趋势用 time series，看现状用 stat/gauge/bar gauge，看状态变迁用 state timeline，看分布用 heatmap，看清单用 table**。

### 3.1 Heatmap 与 histogram 指标的配合

Heatmap 面板是专为 latency 桶设计的：

1. Query：`sum by (le) (rate(prometheus_http_request_duration_seconds_bucket[5m]))`，Format 保持 Time series，Legend 填 `{{le}}`
2. 面板选 Heatmap，Data format 选 Time series；Grafana 按 `le` 标签识别桶边界（老版本需确认 Bucket bound label = le）
3. 看到的是"延迟分布随时间的热力图"——颜色越深的格子表示该时间点落在该延迟区间的请求越多

用普通折线画 `_bucket` 是反模式：十来条累计曲线互相缠绕，什么也看不出来。

### 3.2 一组可直接用的面板查询

```promql
# [Grafana 面板] Stat：当前挂掉的抓取目标（>0 变红）
count(up{job=~"$job"} == 0)

# [Grafana 面板] Time series：每节点 CPU 使用率%
(1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle", instance=~"$instance"}[$__rate_interval]))) * 100

# [Grafana 面板] Stat：内存使用率（阈值 80/90）
(1 - node_memory_MemAvailable_bytes{instance=~"$instance"} / node_memory_MemTotal_bytes{instance=~"$instance"}) * 100

# [Grafana 面板] Bar gauge：磁盘使用率排行
topk(10, (1 - node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay"}) * 100)

# [Grafana 面板] State timeline：节点就绪状态
kube_node_status_condition{condition="Ready", status="true"}
```

## 4. 与 recording rules 配合：把贵的算一次

### 4.1 问题与解法

一个 dashboard 假如有 12 个面板，每面板 30s 刷新一次、每次都对几百条原始序列算 `rate(...[5m])` 再聚合，Prometheus 的查询负载是 12 × 2/分钟次全量计算。打开这个 dashboard 的人越多、刷新越密，压力线性放大。

recording rules 把计算搬到 server 侧周期执行一次，面板变成对预聚合序列的"点查"：

```yaml
# [master] kubectl apply -f node-cpu-rule.yaml（kube-prometheus-stack 形式）
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: node-cpu-recording
  namespace: monitoring
  labels:
    release: prom-stack
spec:
  groups:
    - name: node-cpu
      interval: 30s
      rules:
        - record: instance:node_cpu_usage:rate5m
          expr: 100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))
```

```promql
# [Grafana 面板] 面板查询从贵表达式变成读一条预聚合序列
instance:node_cpu_usage:rate5m{instance=~"$instance"}
```

收益与代价：

| 收益 | 代价 |
| --- | --- |
| 面板加载从秒级到毫秒级 | 30s 的预聚合延迟（监控场景可接受） |
| 查询压力与观看人数解耦 | 多一份要维护的规则（命名与口径） |
| 多 dashboard/告警共用同一口径 | 占用少量序列存储 |

经验法则：**任何出现在多个面板/告警里的 rate+聚合、以及一切 histogram_quantile，都值得做成 recording rule**；临时探查用完即弃的表达式不值得。命名沿用 03 文件 9 节的 `level:metric:operations` 惯例（如 `instance:node_cpu_usage:rate5m`），上下层规则保持一致的 by 标签。

## 5. Dashboard 工程化：变更可见与 as-code

### 5.1 用 annotation 把"变更"画到时间轴上

排障时最值钱的一根线往往是"我们几点改了什么"。两种落法：

- **手工 annotation**：面板上快捷键直接标注"14:32 升级 v1.7"
- **告警 annotation**：Dashboard Settings → Annotations → New，数据源选 Prometheus，查询告警序列，告警的 pending/firing/resolved 就会以区间形式叠在所有面板时间轴上：

```promql
# [Grafana annotation query] 把活跃告警画在时间轴上（排除心跳类）
ALERTS{alertname!="Watchdog", alertstate="firing"}
```

### 5.2 面板设置纪律

- **Unit 必设**：percent(0-100)、seconds、bytes、Bps——不设 unit 的轴等于强迫读者心算
- **Min step / Max data points**：控制查询点数，长时段自动降采样，防止一次拖出 12h × 15s 的巨型查询
- **Legend 用标签模板**：`{{instance}}`、`{{namespace}}/{{pod}}`，别用默认的序列全串
- **Thresholds 与告警阈值一致**：面板上 80% 变黄、90% 变红，就应当有对应的告警规则在同值触发，视觉与通知口径统一

### 5.3 Dashboard as-code

Grafana 的 dashboard 本质是一份 JSON（Dashboard Settings → JSON model）。手工建好之后应纳入版本管理：导出 JSON，用 ConfigMap + sidecar 让集群自动加载（kube-prometheus-stack 的 Grafana 已带 sidecar，识别 `grafana_dashboard: "1"` 标签的 ConfigMap）：

```yaml
# [master] kubectl apply -f pca-basics-dashboard.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pca-basics-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"       # sidecar 靠它发现并加载
data:
  pca-basics.json: |
    {
      "title": "PCA lab: basics",
      "uid": "pca-basics",
      "schemaVersion": 39,
      "refresh": "30s",
      "time": {"from": "now-1h", "to": "now"},
      "templating": {"list": []},
      "panels": [
        {
          "id": 1,
          "type": "stat",
          "title": "Down targets",
          "datasource": "Prometheus",
          "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
          "targets": [{"expr": "count(up == 0)", "refId": "A"}]
        }
      ]
    }
```

apply 后稍等片刻 dashboard 出现在 Dashboards 里；改 ConfigMap 即滚动更新。从此 dashboard 跟应用一起走 GitOps，重建集群不丢图。

## 实战演练：十五分钟建一个三面板 dashboard

环境：kubeadm 集群 + kube-prometheus-stack。先完成 1 节的登录（admin/密码）。

1. **建变量**：Settings → Variables，新建 `job`（Query：`label_values(up, job)`，勾 Multi-value 与 Include All）、`instance`（Query：`label_values(up{job=~"$job"}, instance)`，同样勾选）
2. **Stat 面板**：Add → Visualization → Stat，查询 `count(up{job=~"$job"} == 0)`，Title "Down targets"；Thresholds 设 0 绿、0+ 红
3. **Time series 面板**：查询 3.2 节的每节点 CPU 使用率（把窗口写成 `$__rate_interval`），Legend 设 `{{instance}}`
4. **Heatmap 面板**：按 3.1 节配置 `prometheus_http_request_duration_seconds_bucket`
5. **应用 recording rule**：kubectl apply 4.1 节的 PrometheusRule，等 30s 后把第 3 个面板查询替换为 `instance:node_cpu_usage:rate5m{instance=~"$instance"}`，确认曲线形状不变、查询耗时（Query inspector → Refresh）显著下降
6. **保存** dashboard 命名为 "PCA lab: basics"，验证变量切换 job 后所有面板联动刷新

预期结果：切换 `job` 到任意值时 instance 下拉随之过滤；Stat 在缩掉一个有 exporter 的 deployment 时变红；Query inspector 里 recording rule 面板的执行时间通常比原始表达式低一个数量级。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 面板查无数据（No data） | 数据源 URL 用了 localhost（指到 Grafana 自己） | 用集群内 Service DNS；查 Query inspector 看实际请求 |
| 变量选了多个值后查询为空 | 多值渲染成 `(a\|b)` 正则但查询用了 `=` | 多值/All 一律配 `=~` |
| heatmap 显示一堆折线 | 用了 Time series 面板画 `_bucket` | 换 Heatmap 面板，Data format = Time series，Legend `{{le}}` |
| 面板越刷越卡、Prometheus 高负载 | 每个面板重复大范围 rate 聚合 | 高频复用表达式做成 recording rules |
| 缩放时间范围后 rate 出现断点 | 固定窗口太短或窗口 < 4×抓取间隔 | 用 `$__rate_interval` 或加大窗口 |
| stat 面板显示一堆碎块 | 把多序列指标塞给 stat | stat 只放聚合后的单值；多序列用 time series/bar gauge |
| dashboard 分享后别人看不到我的变量值 | 变量是 dashboard 级、每个会话独立 | 用 dashboard 链接（含变量 query 参数）分享当前状态 |

## 自测

1. 数据源 URL 为什么写 Service DNS 而不是 `localhost:9090`？
<details><summary>答案</summary>

查询由 Grafana 后端进程发起（Access=Server），localhost 指向 Grafana 容器自身而非 Prometheus。集群内正确地址是 Prometheus Service 的 DNS 名；port-forward 只是把 Grafana UI 暴露给你浏览器，不改变数据源求值位置。
</details>

2. `up{job=~"$job"}` 在变量只选了一个值时也工作吗？为什么统一用 `=~` 是好习惯？
<details><summary>答案</summary>

工作：单值时正则匹配单一字符串同样成立。统一 `=~` 使查询在单选/多选/All 三种状态下行为一致，切到多值不会突然查空——这属于"防御性模板写法"。
</details>

3. 延迟分布为什么用 heatmap 而不是画 P95 折线？二者各丢了什么信息？
<details><summary>答案</summary>

P95 折线只保留一个分位点，双峰/长尾等分布形状信息全丢；heatmap 保留整张分布随时间的演化，能看出"一部分请求变慢"而非"平均变慢"。heatmap 的代价是读起来粗（桶粒度）且不能直接当告警条件。成熟做法两者并存：折线做 SLI，heatmap 做根因下钻。
</details>

4. 一个面板查询在 Explore 里 200ms 返回，做成 dashboard 后所有人都喊慢。可能发生了什么？
<details><summary>答案</summary>

dashboard 是多面板 × 定时刷新 × 多用户并发的乘积：12 面板 30s 刷新 = 每分钟 24 次重查询，再乘观众数，Prometheus 查询队列排队。解法：预聚合（recording rules）、拉长刷新间隔、时间范围/步长降采样（min interval、max data points）。
</details>

5. 为什么 kube-prometheus-stack 的 dashboard 几乎不直接写 rate(...[5m]) 而是查 `xxx:rate5m` 这类序列？
<details><summary>答案</summary>

它们的 mixin 体系把所有昂贵表达式都预生成成 recording rules（命名就是 level:metric:operations 惯例），dashboard 只做轻量点查。这是"重计算一次、轻消费多次"的标准架构，也是官方对社区的最佳实践示范。
</details>

## 延伸阅读

- Grafana 官方文档（面板/变量/数据源）：<https://grafana.com/docs/grafana/latest/>
- Prometheus 数据源专项（含 $__rate_interval）：<https://grafana.com/docs/grafana/latest/datasources/prometheus/>
- recording rules 与命名惯例：<https://prometheus.io/docs/prometheus/latest/configuration/recording_rules/>
- kube-prometheus（规则与 dashboard 的工程化范例）：<https://github.com/prometheus-operator/kube-prometheus>
