# 02 · Prometheus 架构：组件、服务发现、relabel 与 TSDB

> 模块：PCA 备考 ｜ 建议时长：4 小时 ｜ 关联认证：PCA-Prometheus 基础（20%）

## 学习目标

- 能画出 Prometheus server 内外的主要组件，并说明一次 scrape 从服务发现到落盘经过哪些环节
- 能分别解释 static_configs、file_sd_configs、kubernetes_sd_configs 的发现机制与适用场景
- 能准确说出 relabel_configs 与 metric_relabel_configs 的执行时机差异并正确选用
- 能描述 TSDB 中 WAL、head block、2h block、compaction、retention 的生命周期
- 能为给定场景在 federation 与 remote_write 之间做出选择并说明理由

## 1. 组件总览

```
                        ┌──────────────────────── Prometheus server ────────────────────────┐
 ┌───────────┐  pull    │ ┌─────────┐   ┌──────────┐   ┌────────────┐   ┌────────┐          │
 │ Exporter  │<─────────┼─┤ Service │   │  Scrape  │──>│    TSDB    │<──│ PromQL │          │
 │ /metrics  │          │ │Discovery│──>│  Loops   │   │ (WAL+块)   │   │ Engine │          │
 └───────────┘          │ └─────────┘   └──────────┘   └─────┬──────┘   └────┬───┘          │
 ┌───────────┐  push    │      ▲            ▲               │          ┌────┴───┐          │
 │Pushgateway│<─────────┼──────┼────────────┼───────────────┼─────────>│Web UI/ │          │
 └───────────┘          │      └── relabel_configs ─────────┘          │API     │          │
 ┌───────────┐          │                (抓取前改 target)             └────────┘          │
 │  Client   │          │            metric_relabel_configs                              │
 │ libraries │          │                (抓取后改样本)      │ 告警规则评估                     │
 └───────────┘          │                                     ▼                             │
                        └──────────────────────────────────> Alertmanager ──> email/slack/...┘
                                  (HA: 双 Prometheus 同抓，Alertmanager 去重)
```

组件职责速查：

| 组件 | 职责 | 不做什么 |
| --- | --- | --- |
| Prometheus server | 服务发现、抓取、存储（TSDB）、PromQL 求值、规则评估 | 不做长期存储（默认 15d）、不集群化 |
| Exporter | 把第三方系统状态翻成 /metrics 文本 | 不存储、不发送（等待被抓） |
| Client library | 应用内埋点，内存中维护指标，暴露 /metrics | 不推送（Prometheus pushgateway 除外） |
| Pushgateway | 短命任务的推送中转站 | 不衰减、不清理（见 04 文件） |
| Alertmanager | 去重、分组、抑制、静默、路由通知 | 不评估表达式（评估在 server） |
| Grafana | 可视化 | 不是数据源（查 Prometheus API） |

一个常见考题辨析：**规则评估发生在 Prometheus server，通知逻辑发生在 Alertmanager**。"alerting rule 的 expr 谁来算"——server；"一条告警发给谁、和谁合并"——Alertmanager。

## 2. pull 模型的架构后果

01 文件已对比过 push/pull 的通用权衡，这里看 pull 对架构的三处塑造：

1. **服务发现必须存在**。pull 方向下"抓谁"是服务端的中央配置，动态环境（K8s 里 Pod 随生随灭）必须有自动发现机制——这就是 SD + relabel 体系的由来
2. **抓取失败本身是信号**。每个 target 自动获得 `up` 指标（1/0）、`scrape_duration_seconds`、`scrape_samples_scraped` 等。不需要给每个被监控对象单独配"存活告警"，`up == 0` 一条规则全覆盖
3. **目标端零状态**。Exporter/client 只需应答 HTTP GET，没有队列、没有重试、不知道 Prometheus 的存在；同一目标可以被多个互不相识的 Prometheus 同时抓（HA 的基础）

## 3. 服务发现：三种机制

### 3.1 机制对比

| 机制 | 发现方式 | 变更生效 | 适用场景 |
| --- | --- | --- | --- |
| static_configs | 手写死列表 | 改配置 + reload | 3~5 台固定 VM、交换机、测试环境 |
| file_sd_configs | 监听 JSON/YAML 文件 | inotify 实时 + 定期兜底（refresh_interval 默认 5m） | 配置管理工具（Ansible 等）生成目标清单 |
| kubernetes_sd_configs | watch kube-apiserver | watch 推送，近实时 | K8s 集群内一切 |

static 与 file_sd 的选择经常考：**file_sd 不需要重启/reload Prometheus 就能增删目标**，把"目标清单"和"抓取逻辑"解耦，这是它对 static 的本质优势。

### 3.2 file_sd 示例

```yaml
# [master] prometheus.yml 片段：file_sd 抓 node_exporter
scrape_configs:
  - job_name: node-file
    file_sd_configs:
      - files:
          - /etc/prometheus/file_sd/*.json
        refresh_interval: 5m
```

```json
# [master] /etc/prometheus/file_sd/nodes.json（格式：target 组数组，labels 附到每个 target 上）
[
  {
    "targets": ["172.30.30.21:9100", "172.30.30.22:9100"],
    "labels": { "env": "lab", "zone": "a" }
  }
]
```

往该目录写/改文件后，无需任何 reload，几十秒内新 target 出现在 /targets 页。

### 3.3 kubernetes_sd_configs：role 决定发现什么

| role | 每个 target 对应 | __address__ 指向 | 典型用途 |
| --- | --- | --- | --- |
| node | 一个节点 | kubelet 10250 | 抓 kubelet/cAdvisor、node 统计 |
| pod | 每个声明了端口的容器 | Pod IP:容器端口 | 抓应用自身 /metrics（配注解过滤） |
| service | 每个 Service 的每个端口 | ClusterIP:端口 | 探测 Service 可用性（常配 blackbox） |
| endpoints | Endpoint 后端的每个地址 | 每个 Pod IP:端口 | 抓"实际服务实例"，最常用 |
| endpointslice | 同上（按 EndpointSlice） | 同上 | 新版 K8s 的等价物 |
| ingress | 每个 Ingress 的每个 rule | Ingress 的 host | blackbox 探测入口 |

发现的对象带大量 `__meta_kubernetes_*` 临时标签（namespace、pod_name、label_*、annotation_*），relabel 阶段据此过滤与改名。标准套路（几乎每个集群都在用）：

```yaml
# [master] prometheus.yml 片段：按 pod 注解自动抓取
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      # 只抓带 prometheus.io/scrape: "true" 注解的 Pod
      - source_labels: [__meta_kubernetes_pod_annotation_prometheus_io_scrape]
        action: keep
        regex: "true"
      # __address__ 改写成 注解里声明的端口
      - source_labels: [__address__, __meta_kubernetes_pod_annotation_prometheus_io_port]
        action: replace
        regex: ([^:]+)(?::\d+)?;(\d+)
        replacement: $1:$2
        target_label: __address__
      # Pod 的 K8s label 原样提升为指标 label
      - action: labelmap
        regex: __meta_kubernetes_pod_label_(.+)
      - source_labels: [__meta_kubernetes_namespace]
        target_label: namespace
```

这段配置是"给 Pod 打注解就自动被监控"的实现，考题常考 keep/replace/labelmap 各自动作了什么。

## 4. relabel_configs vs metric_relabel_configs：时机决定一切

两类配置都叫"重新打标签"，差别只在**执行时机**，而时机决定了能力边界：

```
服务发现（static / file_sd / k8s SD）
   │ 产出候选 target，附 __meta_*、__address__ 等临时标签
   ▼
【relabel_configs】──────────── 抓取之前，作用于 target
   │  能力：keep/drop 决定"抓不抓"；改 __address__ 换目标地址；
   │        给 target 附加最终 label（job/instance/namespace...）
   ▼
HTTP GET http://<target>/metrics（scrape 发生在这里）
   │ 得到一批原始样本（指标文本解析后的每条时序）
   ▼
【metric_relabel_configs】───── 抓取之后、写入 TSDB 之前，作用于样本
   │  能力：drop 不想要的序列、改样本标签值、删高基数 label；
   │        改不了"抓不抓"（HTTP 请求已经发生并计费了带宽）
   ▼
TSDB（head block + WAL）
```

一张对照表（背下来，考试直接出）：

| | relabel_configs | metric_relabel_configs |
| --- | --- | --- |
| 时机 | 抓取前 | 抓取后、入库前 |
| 作用对象 | target（整目标） | sample（每条时序） |
| 能否决定抓不抓 | 能（keep/drop target） | 不能（只能丢已抓回的序列） |
| 典型用途 | 按 __meta_ 过滤 target、改地址、注入 label | 丢弃 go__* 噪声、labeldrop 高基数标签 |
| `up` 指标是否受影响 | 受（drop 后无 up） | 不受（up 是抓取结果，drop 序列不影响 up） |

```yaml
# [master] prometheus.yml 片段：两类 relabel 并存的完整示例
scrape_configs:
  - job_name: kubernetes-pods
    kubernetes_sd_configs:
      - role: pod
    relabel_configs:
      - source_labels: [__meta_kubernetes_namespace]
        action: keep
        regex: monitoring|default        # 只抓这两个 namespace 的 Pod
    metric_relabel_configs:
      - source_labels: [__name__]
        regex: go_[a-z_]+                # 抓回来之后丢弃所有 go_* 运行时噪声
        action: drop
      - action: labeldrop
        regex: pod_template_hash         # 删掉高变动 label，降低基数
```

常用 action 速记：`replace`（改值/改名）、`keep`/`drop`（按正则留或弃）、`labelmap`（按正则批量改名）、`labeldrop`/`labelkeep`（删/留 label）、`hashmod`（分片用）。

## 5. TSDB 内部：从 WAL 到 block

### 5.1 写入路径

```
样本到达
   ▼
┌──────────────────────────── head block（内存）───────────────────────────┐
│  活跃时序的最近数据；每 2h 一个窗口                                         │
│  同时：每个样本先追加写 WAL（磁盘、顺序写、崩溃恢复用）                        │
│  满的 chunk 落盘到 chunks_head/，但索引仍在内存                             │
└───────────────┬──────────────────────────────────────────────────────────┘
                │ 每 2h（默认）截断：head → 持久化为一个磁盘 block
                ▼
        data/01HXY.../（不可变 2h block：index + chunks）
                │ compaction（后台）
                ▼
        相邻小块合并成大块（2h → … → 更大，上限受 --storage.tsdb.max-block-duration
          约束，默认取 31d 与 retention 10% 中较小者，以 --help 输出为准）
                │ retention 到期
                ▼
        整块删除（--storage.tsdb.retention.time，默认 15d）
```

### 5.2 关键结论（考试高频）

| 概念 | 一句话 |
| --- | --- |
| WAL | head 的预写日志，写样本前先顺序落盘；重启时重放（replay）恢复最近 2h 数据 |
| head block | 内存中的活跃块，所有新样本先到这里；`prometheus_tsdb_head_series` 即其时序数 |
| 2h block | head 每 2h 截断出的磁盘不可变块，是删除与压缩的最小单位 |
| compaction | 后台把小块合并成大块（去重、排序、减小索引开销）；核心 Prometheus 合并但**不降采样**（降采样是 Thanos 的特性） |
| retention | 只能整块删；想删块内时间段需 admin API（--web.enable-admin-api）写 tombstone |
| 删除粒度 | "删最近 10 分钟的数据"这种需求默认做不到——没有块级以下删除 |

### 5.3 实际看一眼目录

```bash
# [master] 查看 Prometheus pod 内的数据目录（kube-prometheus-stack 的数据在 /prometheus）
kubectl -n monitoring exec prom-stack-kube-prom-prometheus-0 -- ls -l /prometheus
```

预期看到：`wal/`、`chunks_head/`、`queries.active`、`lock`、以及若干 `01…`（ULID 命名）的 block 目录；每个 block 内有 `meta.json`、`index`、`chunks/`、`tombstones`。

### 5.4 与 TSDB 健康相关的查询

```promql
# [Prometheus Web UI] 活跃时序数（内存压力的第一信号）
prometheus_tsdb_head_series

# [Prometheus Web UI] 每秒入库样本数
rate(prometheus_tsdb_head_samples_appended_total[5m])

# [Prometheus Web UI] WAL 重放耗时（重启慢的元凶）
prometheus_tsdb_wal_replay_duration_seconds
```

## 6. HA 与去重

Prometheus server **自身不支持集群**：两个 Prometheus 实例互不知道对方。HA 的标准做法是"两层去重"：

```
            ┌─ Prometheus A ─┐
 targets ──┤                ├──> 同一批告警 ──> Alertmanager 集群（去重：相同 label 集
            └─ Prometheus B ─┘                    的告警只通知一次）
```

- **告警侧去重**：A、B 用相同规则抓相同目标，产生的告警 label 集完全一致，Alertmanager 按 fingerprint 去重，用户只收到一条——这就是"Alertmanager 也参与 HA"的含义
- **查询侧去重**：Grafana 查 A 还是 B？两份数据有细微时间差。要全局单一视图需查询层聚合去重（Thanos Query / Mimir / VictoriaMetrics 的 dedup），或干脆接受"查任意一个"
- 代价提醒：双实例 = 双倍抓取流量与目标负载，`up` 指标两份，基数不变但样本量翻倍

## 7. federation 与 remote_write

两者都解决"数据要出去"，方向与语义完全不同：

| | federation | remote_write |
| --- | --- | --- |
| 方向 | 下游 Prometheus **拉**上游 /federate 端点 | 上游 Prometheus **推**给远端存储 |
| 传输内容 | 每次抓取只取每个序列的**当前值**（instant） | 全量样本流（近实时逐条转发） |
| 选择性 | 强：match[] 指定只要哪些序列 | 可配规则过滤，但通常整库转发 |
| 典型用途 | 层级聚合：各团队/机房 Prom → 全局 Prom 只拉聚合后的少量序列 | 长期存储与全局视图：Prom → Thanos/Mimir/VictoriaMetrics/商业存储 |
| 成本 | 极低（只有少量 instant 查询） | 高（持续推送全量） |

```yaml
# [master] federation：全局 Prometheus 只收各团队聚合结果
scrape_configs:
  - job_name: federate
    honor_labels: true            # 保留上游 job/instance 等标签（否则会被加 exported_ 前缀）
    metrics_path: /federate
    params:
      'match[]':
        - '{job="demo-app"}'
        - '{__name__=~"job:.*"}'  # recording rules 的命名惯例（见 03 文件）
    static_configs:
      - targets: ['team-a-prom:9090', 'team-b-prom:9090']
```

```yaml
# [master] remote_write：样本转发到远端接收端
remote_write:
  - url: http://thanos-receive:19291/api/v1/write
    queue_config:
      max_samples_per_send: 5000
```

选型口诀：**要"少量聚合指标、层级汇报"用 federation；要"全量长期存储、跨集群查询"用 remote_write**。

## 实战演练：在集群上摸一遍架构

环境：kubeadm 单 master 集群 + kube-prometheus-stack（安装命令见 01 文件实战演练）。

```bash
# [master] Step1 看 SD 与 relabel 的产物：列出所有抓取目标及其最终 label
kubectl -n monitoring port-forward svc/prom-stack-kube-prom-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/targets | python3 -m json.tool | grep -E '"(scrapeUrl|health)"' | head -20
```

浏览器打开 <http://localhost:9090/targets>，任选一个 `job=kubernetes-pods` 目标点开，确认能看到 `namespace`、`pod` 等 label——它们都来自 __meta_kubernetes_* 的 relabel 提升。

```bash
# [master] Step2 观察 TSDB 布局与生效参数
kubectl -n monitoring exec prom-stack-kube-prom-prometheus-0 -- ls /prometheus
curl -s http://localhost:9090/api/v1/status/flags | python3 -m json.tool | grep -iE 'retention|storage.tsdb'
```

预期输出包含 `wal`、`chunks_head`、若干 ULID block 目录，以及 `storage.tsdb.retention.time=10d` 之类的当前值（helm chart 默认与官方 15d 不同，以 flags 输出为准）。

```bash
# [master] Step3 触发一次 WAL 重放：删除 Pod 观察重启日志
kubectl -n monitoring delete pod prom-stack-kube-prom-prometheus-0
kubectl -n monitoring logs -f prom-stack-kube-prom-prometheus-0 | grep -iE 'wal|replay'
```

预期日志出现 `WAL replay` 相关行；重放期间 Web UI 暂时不可用——这就是"重启慢先怪 WAL"的直观体验。

```bash
# [master] Step4 验证 up 的语义：把一个 exporter 的 ServiceMonitor 断掉（删 Service）
kubectl -n monitoring delete svc prom-stack-kube-prom-node-exporter
```

到 Web UI 执行 `up{job="node-exporter"}`，所有实例变为 0（抓取失败即失联）；随后 `kubectl rollout restart` 恢复方式依环境而定，或重装 chart 恢复。实验后务必 `helm upgrade prom-stack prometheus-community/kube-prometheus-stack -n monitoring` 回滚环境。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 改了 file_sd 的 JSON 但 target 没出现 | 文件格式错（必须是对象数组）；或路径 glob 不匹配 | 用 `promtool check config` 校验主配置；确认 files 通配符 |
| relabel 里 drop 了序列却仍有 HTTP 抓取流量 | 用错了 relabel_configs——它在抓取后，HTTP 已发生 | 想省流量/不抓，用 relabel_configs 的 keep/drop 在抓取前过滤 target |
| Prometheus 重启要几分钟 | WAL 重放 2h 数据 | 属正常机制；减小重启频率，或接受之（WAL 是数据安全的代价） |
| 想删最近 1 小时的坏数据做不到 | TSDB 只支持整块删除 | admin API 的 delete series 写 tombstone（需 --web.enable-admin-api），或等 retention 滚出 |
| 两个 Prometheus 都告警，收到两条 | 告警 label 集不完全一致（如 instance 带了 replica 标识） | 保证两实例 external_labels 之外规则/目标完全一致；差异 label 放 external_labels |
| federation 后指标 label 变成 exported_job | honor_labels 未开 | federation job 配 honor_labels: true |

## 自测

1. 为什么 Prometheus 选择把规则评估放在 server、把通知去重放在 Alertmanager，而不是让 server 直接发通知？
<details><summary>答案</summary>

通知语义（分组、抑制、静默、重发、渠道失败重试）是有状态且需要集群协调的，与抓取/存储的生命周期不同；分离后 HA 变成"多个 server 指向一个 Alertmanager 集群"，告警去重免费获得。若 server 直接发通知，双实例必然双通知，且 server 重启会丢通知队列。
</details>

2. kubernetes_sd 的 pod role 与 endpoints role 都能抓到 Pod IP，实际生产为何更常用 endpoints？
<details><summary>答案</summary>

pod role 对"每个声明端口的容器"都生成 target，容易抓到 Sidecar/管理端口等非指标端点，且 Service 扩缩容时要靠注解逐 Pod 控制；endpoints role 跟随 Service 的 Endpoint 列表，天然等于"这个服务的活实例集合"，抓谁由 Service 定义统一管理，语义更干净。
</details>

3. `metric_relabel_configs` 里 drop 了某序列后，`scrape_samples_scraped` 会变小吗？
<details><summary>答案</summary>

不会。scrape_samples_scraped 统计的是从端点抓回的样本数，metric_relabel 发生在其之后，只影响最终入库的序列。这正是"metric_relabel 省的是存储与查询，不省抓取带宽"的体现。
</details>

4. head block 为什么要先写 WAL 而不是等 2h 直接落 block？
<details><summary>答案</summary>

2h 窗口内的数据只在内存，进程崩溃即丢失全部最近数据。WAL 以顺序追加方式把每个样本先落盘，崩溃后重放恢复——用较小的写放大换取崩溃安全。这是数据库"内存索引 + 预写日志"的经典组合。
</details>

5. 三个机房各一套 Prometheus，公司要一个"全局大盘"（只要 QPS、错误率、P99 三个指标）和一个"近一年数据可查"的审计需求。分别选什么方案？为什么不用同一个？
<details><summary>答案</summary>

全局大盘：federation——全局 Prometheus 用 match[] 只拉三个 recording rule 结果，每 15s 三个 instant 值，成本几乎为零。一年数据：remote_write 到 Thanos Receive/Mimir 等长期存储——federation 只传 instant 值且依赖下游持续在线，不能补历史；全量样本必须逐条转发。两者成本差数个量级，需求不同方案不同。
</details>

6. 双 Prometheus HA 方案中，`up{job="node"}` 在两实例上各有一份。Grafana 面板查 `count(up{job="node"} == 0)` 会不会因为双实例而误报？
<details><summary>答案</summary>

会。面板数据源指向单实例时不会（只看到自己那份），但如果经 Thanos Query 之类聚合双实例且未做去重，同一节点的 up 序列会出现两条（带不同 replica label），一台宕机会数出 2。必须在查询层配置按 replica label 去重，或在面板上按去重后的 label 聚合。
</details>

## 延伸阅读

- 官方架构概览（含组件图）：<https://prometheus.io/docs/introduction/overview/>
- 配置参考（SD/relabel 全字段）：<https://prometheus.io/docs/prometheus/latest/configuration/configuration/>
- TSDB 存储说明：<https://prometheus.io/docs/prometheus/latest/storage/>
- federation 说明：<https://prometheus.io/docs/prometheus/latest/federation/>
- remote_write 与兼容生态：<https://prometheus.io/docs/prometheus/latest/feature_flags/#remote-write-receiver> 及 <https://prometheus.io/docs/operating/integrations/#remote-endpoints-and-storage>
