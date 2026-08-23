# 03 · Loki 栈：只索引标签的日志系统

> 模块：日志（10-logging）｜ 建议时长：3.5 小时 ｜ 前置：01~02 章、08-pca/03 PromQL（强烈推荐）｜ 关联认证：—（无直接考点，PCA 可观测生态的日志主干）

## 学习目标

- 能解释 Loki 为什么便宜（只索引 label set，正文压缩成 chunk 放对象存储）以及它为此牺牲了什么
- 能画出 Loki 的组件架构（distributor/ingester/querier/query-frontend/compactor）与对象存储的依赖关系
- 能写出正确的 LogQL：流选择器、行过滤器、`| json` 解析、`count_over_time`/`rate` 度量查询，并能说出它与 PromQL 的同构关系
- 能运用标签设计原则（低基数）判断哪些字段可以进 label
- 能用对比表在 Loki 与 ELK 之间做选型决策

## 1. 为什么便宜：索引的东西不一样

第 2 章的结论：ES 的成本大头是"给每个词建倒排索引"。Loki 的设计决策就是从反面来的——**不索引正文，只索引标签**：

```
ES：       每条日志的每个词 ──► 倒排索引（大，常为原始数据的 1~3 倍）
Loki：     只有 label set 进索引 ──► 找到"流"（stream）
           正文原样压缩成 chunk ──► 对象存储（S3/MinIO/本地盘，最便宜的存储层）
```

核心数据模型三个词：

- **stream（流）**：一个唯一 label set 对应的、时间有序的日志序列。`{namespace="default", app="logger"}` 就是一条流。
- **chunk（块）**：流上的一段日志（默认约 1.5 MB 或超时）压缩成一个块，整块进对象存储。压缩比对 JSON 日志常见 10~20 倍。
- **index（索引）**：TSDB 索引，只记录"哪个 label set 存在、它的 chunk 在哪、时间范围如何"。体积通常是数据量的零头。

查询时序对比（这就是代价）：

```
ES 查询  error AND service:payment
   └─► 查倒排表直接得到含这些词的文档 id ──► 快，代价是写入时就付了索引成本

Loki 查询 {app="payment"} |= "error"
   └─► 先用标签查索引得到流及其 chunk ──► 拉回 chunk 解压 ──► 逐行正则/字符串扫描
       标签越准，扫描的 chunk 越少；没有标签就退化为暴力全扫
```

一句话总结（面试可用）：**Loki 把 ES 在"写入时"付的钱挪到了"查询时"**。写路径只做压缩追加，存储用对象存储，于是海量低价值日志（基础设施日志、debug 级日志）的持有成本降了一个数量级；代价是"不知道标签的全文搜索"很慢——而现实中的日志排查几乎总是带着标签边界（哪个集群、哪个 namespace、哪个应用、哪段时间）进行的，这是 Loki 敢这么设计的行为学前提。

## 2. 架构：组件与对象存储依赖

```
                                  ┌────────────────────────────┐
 promtail/Alloy/OTel Collector    │           Loki             │
 ──► /loki/api/v1/push ─────────► │ distributor                │
   (采集端：读文件/SD 发现,        │   验证、按 stream 哈希、    │
    打标签、压缩推送)              │   按 replication_factor 复制│
                                  │        │                   │
                                  │        ▼                   │      ┌──────────┐
                                  │ ingester（内存攒 chunk）─────┼────►│          │
                                  │   满/超时 → flush            │      │  对象存储 │
                                  │                            │      │  S3/MinIO│
                                  │ querier ◄───────────────────┼──────│  /本地盘  │
                                  │   （合并 ingester 热数据     │      │          │
                                  │    与存储冷数据）            │      └──────────┘
                                  │ query-frontend              │
                                  │   （拆分/缓存/合并大查询）    │   compactor：保留策略、
                                  │ ruler（LogQL 告警规则）      │   索引压缩
                                  └────────────────────────────┘   （均依赖对象存储）
```

组件职责速记：

| 组件 | 职责 | 关键点 |
|---|---|---|
| distributor | 接收 push、校验行（超长/超旧/标签非法）、按 stream 哈希分发 | 无状态，可任意扩 |
| ingester | 把同 stream 的行攒成压缩 chunk；最近数据常驻内存 | 查最近日志先问它；优雅关闭前把 chunk 刷走 |
| querier | 执行 LogQL：先问 ingester 拿热数据，再从对象存储拉 chunk | 水平扩展增加扫描并行度 |
| query-frontend | 大查询拆分、去重、缓存、限队列 | 大范围查询不拖垮 querier 的关键 |
| compactor | 索引合并、按 retention 物理删除 | retention 必须显式开启 |
| ruler | 用 LogQL 评估告警规则 | 与 Prometheus 规则同构 |

**对象存储是一等公民依赖**：chunk 和索引都放里面，这既是便宜的原因（对象存储每 GB 成本最低、容量无限感），也是运维重心——存储故障 = 读写全断。三种部署模式按规模选：

- **single binary**：所有组件一个进程，单副本。开发/小环境（本文实战与 lab 用它）。
- **simple scalable**：读写分离两组 Deployment（3 的倍数扩），中小生产的标准答案。
- **microservices**：每组件独立扩缩，大规模。

采集端现状提示：**Promtail 已进入维护模式**（官方后继者是 Grafana Alloy，基于 OTel Collector 的发行版）。Promtail 的 K8s 发现、pipeline_stages、标签模型仍是理解这套生态的最短路径，存量部署极多；新生产项目建议直接评估 Alloy 或 OTel Collector 的 filelog receiver（第 4 章）。本模块沿用 Promtail 教学，概念全部可迁移。

## 3. LogQL：与 PromQL 同构的查询语言

学过 08-pca/03 的 PromQL（见 [08-pca/03-promql-guide.md](../08-pca/03-promql-guide.md)），LogQL 几乎是"换了选择器皮肤的 PromQL"：

| 概念 | PromQL | LogQL |
|---|---|---|
| 选择器 | `http_requests_total{job="api"}` | `{job="api", namespace="default"}`（必须有至少一个标签匹配） |
| 时间范围 | `[5m]` range vector | `count_over_time({...}[5m])` |
| 速率 | `rate(x[5m])` | `rate({job="api"}[5m])`（行数/秒） |
| 聚合 | `sum by (pod) (...)` | `sum by (pod) (count_over_time({...}[5m]))` |
| 即时 vs 区间 | instant query / range query | `/query`（度量/瞬时）/ `/query_range`（日志行） |
| 唯一新增 | — | 行过滤器与解析器：`|= "err"`、`\| json`、`\| logfmt` |

LogQL 查询分两类，两类都"先选流，再处理"：

**第一类：日志查询（返回日志行）**

```text
# 1. 流选择器：标签必须至少匹配一个，支持 = ~ != !~ 四种匹配
{namespace="default", app=~"logger|api"}

# 2. 行过滤器（在服务端对 chunk 扫描前先做粗筛，越靠前越省）
{namespace="default"} |= "error"              # 包含子串
{namespace="default"} |~ "time(d )?out"       # 正则（RE2 语法，不支持回溯）
{namespace="default"} != "healthz"            # 不包含

# 3. 解析器：运行时把 JSON 正文提为可过滤的"提取字段"
{namespace="default"} | json | level="error"             # 等价于按字段过滤
{namespace="default"} | json | duration_ms > 400          # 数值比较
{namespace="kube-system"} | logfmt                        # logfmt 格式同理
{namespace="default"} | pattern "<ip> - <user> \"<method> <uri>\""   # 模板提取

# 4. 解析失败的行会带 __error__，习惯性丢弃
{namespace="default"} | json | __error__="" | level="error"

# 5. 输出格式化（调试/导出时用）
{namespace="default"} | json | line_format "{{.level}} | {{.msg}}"
```

`| json` 提取的是**临时字段**，不占索引不占标签——第 1 章"user_id 只能进正文"的结论在查询侧的落点就在这里。

**第二类：度量查询（返回时序）**

```text
# 计数类：把日志行变成指标
count_over_time({app="logger"}[5m])                       # 每 5 分钟窗口的行数
sum by (level) (count_over_time({app="logger"} | json [5m]))   # 按 level 聚合（解析器可进选择器）
rate({app="logger"}[5m])                                  # 行/秒，告警首选
sum by (node_name) (rate({namespace="kube-system"}[5m]))  # 每节点日志速率

# unwrap 类：把日志里的数值字段变成可聚合的样本（注意 [] 位置在 unwrap 之后）
max_over_time({app="logger"} | json | unwrap duration_ms [5m])
quantile_over_time(0.99, {app="logger"} | json | unwrap duration_ms [5m])
```

与 PromQL 唯一的语义差异要记牢：LogQL 的 range vector 永远绑在"流选择器 + 过滤器"上（日志是事件流，没有现成的样本序列），`count_over_time`/`unwrap` 才是把事件折叠成样本的动作。告警规则（ruler 或 Grafana 统一告警里）写法与 Prometheus Recording/Alerting 规则一致：

```yaml
groups:
  - name: log-alerts
    rules:
      - alert: AppLogErrorSpike
        expr: |
          sum by (app) (rate({namespace="default"} | json | level="error" [5m])) > 0.5
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "{{ $labels.app }} 错误日志速率超过 0.5 行/秒"
```

## 4. 标签设计原则：低基数，再低基数

Loki 的标签 = ES 的索引字段 + Prometheus 的 label 的合体约束，第 1 章的判定规则在这里是**硬约束**：

**可以进 label 的（有界、能缩小扫描范围）**：

- `cluster`、`env`、`region`
- `namespace`、`app`/`job`、`container`、`node_name`（节点数有界）
- `level`（若你的应用 level 只有 5 个值）

**绝对不进 label 的（无界，或界随流量增长）**：

- `user_id`、`session_id`、`request_id`、`trace_id`、`order_id`
- `ip`、`email`、`url`（带 query 参数的完整 URL）
- 时间粒度类（把分钟放进标签等于按分钟切流）

违反的后果是三连：**流数暴涨**（每个新 label 值 = 一条新流，ingester 内存里每条流都要维护 chunk 状态）→ **索引膨胀**（TSDB 里流标记变多）→ **写放大会恶化**（chunk 变小变碎，对象存储上小对象海量）。Loki 有兜底限制（如 `max_global_streams_per_user`、每流速率限制 `per_stream_rate_limit`），撞限的表现是 push 返回 429/400，日志开始**整批丢**——高基数标签把"贵"变成"直接不可用"。

另一个隐蔽的坑是**流抖动（stream churn）**：标签本身低基数，但取值频繁变（如把 deployment 的 generation、或每次发布变化的哈希放进标签），旧流不断冷却、新流不断创建，flush 与索引压力同样失控。判定口诀再背一遍：**取值集合随流量/时间增长的，一律留在正文，用 `| json` 在查询时提取**。

## 5. Loki vs ELK 对比与选型

| 维度 | ELK（Elasticsearch） | Loki |
|---|---|---|
| 索引内容 | 全文（每个 term） | 仅 label set |
| 存储 | 本地盘为主（SSD），冷数据可快照到对象存储 | 对象存储为主（chunk + 小索引） |
| 持有成本 | 高（索引 1~3 倍数据量 + SSD） | 低（压缩 chunk 放最便宜的存储） |
| 写入成本 | 高（分词、merge） | 低（压缩追加） |
| 全文检索 | 快（倒排查表） | 慢（标签 narrowing 后扫描） |
| 任意字段聚合 | 强（aggregation 生态成熟） | 够用（LogQL 度量查询） |
| 复杂分析（join、嵌套聚合） | 强 | 弱 |
| 与 Prometheus/Grafana 的亲和 | 一般 | 原生（同一 UI、同套标签、exemplar/trace 跳转） |
| 运维复杂度 | 高（JVM、分片/副本/merge 调优） | 中（组件多但无 JVM，重心在对象存储） |
| 资源弹性 | 扩节点要迁分片 | 对象存储天然"无限"，querier 独立扩 |

选型话术（面试可直接用）：

1. **默认新项目选 Loki**：基础设施与 K8s 日志的查询几乎总带着标签边界（cluster/namespace/app/时间窗），持有成本敏感，且与既有 Prometheus/Grafana 标签体系同构。
2. **这些场景仍选 ELK**：需要真正的全文检索（安全审计按任意关键词捞、合规取证）；需要复杂聚合分析（运营报表、跨字段聚合）；日志是"产品"本身（搜索框给用户用）。
3. **混合是常态**：海量低价值日志进 Loki（长保留、低成本），少量高价值审计/业务日志进 ES（强检索、短列表）。在采集端（OTel Collector / Fluent Bit）做路由分流即可。

## 实战演练：Docker 起单机 Loki，收文件日志并用 curl 查询

环境：装有 Docker 的 Ubuntu 22.04/24.04 VM。镜像以官方 release 为准（本文用 3.4.x）。

**1. 起 Loki（single binary + filesystem 存储）**

```bash
# [装Docker的Ubuntu VM]
mkdir -p /opt/loki-lab/data
cat > /opt/loki-lab/loki-config.yaml <<'EOF'
auth_enabled: false

server:
  http_listen_port: 3100

common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory

schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h

limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  allow_structured_metadata: true
EOF
docker network create loki-net
docker run -d --name loki --network loki-net -p 3100:3100 \
  -v /opt/loki-lab/loki-config.yaml:/etc/loki/local-config.yaml:ro \
  -v /opt/loki-lab/data:/loki \
  grafana/loki:3.4.2 -config.file=/etc/loki/local-config.yaml
sleep 5 && curl -s http://localhost:3100/ready
```

预期输出：`ready`（首次启动建索引需要几秒）。

**2. 准备日志文件与 Promtail**

```bash
# [装Docker的Ubuntu VM]
for i in $(seq 1 300); do
  lvl=info; [ $((i % 10)) -eq 0 ] && lvl=error
  printf '{"ts":"%s","level":"%s","service":"payment","msg":"order %d took %dms"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lvl" "$i" $((RANDOM % 500)) >> /opt/loki-lab/app.log
  sleep 0.01
done
cat > /opt/loki-lab/promtail-config.yaml <<'EOF'
server:
  http_listen_port: 9080

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://loki:3100/loki/api/v1/push

scrape_configs:
  - job_name: app
    static_configs:
      - targets: [localhost]
        labels:
          job: app
          env: lab
          __path__: /var/log/*.log
    pipeline_stages:
      - json:
          expressions:
            level: level
            service: service
      - labels:
          level:
          service:
EOF
docker run -d --name promtail --network loki-net \
  -v /opt/loki-lab/promtail-config.yaml:/etc/promtail/config.yml:ro \
  -v /opt/loki-lab/app.log:/var/log/app.log:ro \
  grafana/promtail:3.4.2 \
  -config.file=/etc/promtail/config.yml
```

注意这份配置在演示"**低基数字段提取进标签**"（level、service 有界，安全），而 ts/msg 留在正文。promtail 的 positions 写在容器内 /tmp——实验环境无所谓，生产要挂持久卷。

**3. 追加新日志并验证采集**

```bash
# [装Docker的Ubuntu VM]
printf '{"ts":"%s","level":"error","service":"payment","msg":"synthetic failure for drill"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> /opt/loki-lab/app.log
sleep 3
curl -sG "http://localhost:3100/loki/api/v1/labels" | jq -r '.data[]'
```

预期输出含：`env`、`job`、`level`、`service`、`filename`（filename 默认会被移除，取决于配置；至少应看到前四个）。

**4. 用 curl 练 LogQL（这就是 Grafana Explore 在后台发的请求）**

```bash
# [装Docker的Ubuntu VM]
# 日志查询：error 行
curl -sG "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="app"} |= "error"' \
  --data-urlencode 'since=1h' --data-urlencode 'limit=5' \
  | jq -r '.data.result[].values[] | .[1]' | head -5

# 解析器：按提取字段过滤（正文里的 level，而非标签）
curl -sG "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="app"} | json | msg =~ "order .*" | line_format "{{.service}} {{.msg}}"' \
  --data-urlencode 'since=1h' --data-urlencode 'limit=3' \
  | jq -r '.data.result[].values[] | .[1]'

# 度量查询：按 level 数行数（/query 是 instant 查询端点）
curl -sG "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query=sum by (level) (count_over_time({job="app"} | json [30m]))' \
  | jq -c '.data.result[] | {level: .metric.level, lines: .value[1]}'
```

预期输出：第一条能捞出若干含 `"level":"error"` 的原始行；第三条返回类似 `{"level":"info","lines":"271"}` 与 `{"level":"error","lines":"30"}`（数量以你实际生成量为准）。

**5. 反面实验：高基数标签撞限**

```bash
# [装Docker的Ubuntu VM]
# 给每行造一个唯一标签值（模拟把 order_id 塞进 label 的错误做法）
docker exec promtail sh -c 'echo done' >/dev/null 2>&1
# 演示用 Loki 的流数限制观察：查看当前限制值
curl -s http://localhost:3100/config | grep -A3 'max_global_streams\|per_stream_rate_limit' | head -8
```

预期输出：能看到默认限制（如 `per_stream_rate_limit: 3MB` 一类，随版本以 `/config` 实际输出为准）。把主配置 `limits_config` 里加 `max_streams_per_user: 10` 后 `docker restart loki`、再生成一批带唯一标签的日志，就能亲眼看到 push 被拒——生产事故的微缩版。清理：`docker rm -f loki promtail && docker network rm loki-net && sudo rm -rf /opt/loki-lab`。

K8s 上的完整版（DaemonSet 采集全集群 + Grafana 面板）在 [labs/01-loki-pipeline](labs/01-loki-pipeline/task.md) 里做。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 查询 `{job="app"}` 永远慢 | 标签太宽，扫的 chunk 太多 | 检查标签设计，补上 namespace/app 等能收窄范围的标签 |
| push 返回 429 / entry too far behind | 撞每流速率限制 / 日志时间戳超出 reject_old_samples 窗口 | 排查高基数标签；容器时钟与日志时间戳是否错位 |
| 日志延迟可见（1~2 分钟） | chunk 未满未刷 + 查询没覆盖 ingester 热数据 | 正常现象；急需实时就查最近 5 分钟窗口（先问 ingester） |
| Pod 重建后日志从头再收 | promtail positions 在容器可写层 | positions 挂 hostPath/持久卷 |
| Grafana 里查 Loki 报 "no label name" | LogQL 裸 `{}` 不合法 | 流选择器必须至少一个标签匹配 |
| 日志里有 `__error__="json_parse_error"` | 正文不是合法 JSON 的行混入 | 查询加 `\| __error__=""`；或修正应用输出 |

## 自测

1. Loki 为什么便宜？它用哪种能力换来了这个成本结构？

<details><summary>答案</summary>

只索引 label set（流标识），正文压缩成 chunk 放对象存储，索引体积极小、存储层用的是每 GB 最便宜的对象存储、写入只是压缩追加（无分词无 merge 风暴）。换来的是"无标签 narrowing 的全文检索"能力：查询要先靠标签锁定流，再对 chunk 解压逐行扫描，标签不准则退化为暴力扫描。即把 ES 在写入时的索引成本转移到了查询时。
</details>

2. 把 `user_id` 设为 Loki label，具体会发生什么连锁反应？

<details><summary>答案</summary>

每个活跃用户创建一条独立流（label set 唯一）：ingester 为每条流维护内存 chunk 状态 → 内存暴涨；TSDB 索引里的流标记暴增；流变得极碎（每个用户每次几行就 flush 一个小 chunk）→ 对象存储小对象海量、flush 写放大；最终撞 max_global_streams_per_user / per_stream_rate_limit，push 被拒，日志整批丢。正解是留在正文，用 `| json | user_id="u_123"` 查询时过滤。
</details>

3. `count_over_time({app="x"}[5m])` 与 PromQL 的 `increase(x[5m])` 在语义上哪里同、哪里不同？

<details><summary>答案</summary>

同：都是"把一段时间窗内的事件折叠成一个数"，都绑 range vector、都可在其上做 sum by/rate 聚合。不同：PromQL 作用于已有的时序样本（counter 的递增要处理重置与外推），LogQL 的 range vector 绑在日志流选择器上，count_over_time 数的是原始行数（没有 counter 语义，也就没有重置问题）；要"每秒"用 rate({...}[5m])，它就是行数除以窗口秒数。
</details>

4. 团队抱怨"K8s 里查个日志比 ELK 慢多了"，你在标签设计上会做哪些改进？

<details><summary>答案</summary>

确认查询都带 namespace/app/container 这些有界标签（promtail 的 K8s relabel 默认就有）；把常用过滤维度中低基数的提为标签（如 level）；确保没人把 url/user_id 放进标签反而稀释了流；检查是否查询时间窗过大（让 query-frontend 拆分与缓存生效）；最后才考虑扩 querier 副本。原则：先让标签把扫描范围收窄，再谈资源。
</details>

5. 什么场景你会明确推荐 ELK 而不是 Loki？

<details><summary>答案</summary>

查询模式是"任意关键词全文检索"（安全审计、合规取证、按任意自由文本捞人）；需要复杂聚合与二次分析（跨字段 group/join、运营报表）；日志面向最终用户的搜索产品。这些场景 Loki 的扫描成本或 LogQL 表达能力跟不上，而 ES 的倒排索引正是为它们付费的理由。基础设施/K8s 运维日志则相反，Loki 是默认答案。
</details>

## 延伸阅读

- Loki 官方：架构与存储模型 — <https://grafana.com/docs/loki/latest/get-started/architecture/>
- Loki 官方：LogQL 语法 — <https://grafana.com/docs/loki/latest/query/>
- Loki 宐方：标签与最佳实践（cardinality） — <https://grafana.com/docs/loki/latest/get-started/labels/bp-labels/>
- Promtail 配置参考 — <https://grafana.com/docs/loki/latest/send-data/promtail/configuration/>
- 下一章：[04-k8s-logging.md](04-k8s-logging.md)（K8s 里日志到底落在哪）
