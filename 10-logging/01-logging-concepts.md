# 01 · 日志概念：可观测三支柱的日志腿

> 模块：日志（10-logging）｜ 建议时长：2 小时 ｜ 前置：08-pca/01 可观测性概念（推荐）｜ 关联认证：—（无直接考点，PCA 可观测概念的动手延伸）

## 学习目标

- 能解释日志在"metrics → traces → logs"排查漏斗中的位置，以及它为这个位置付出的代价
- 能区分结构化（JSON）与非结构化日志，并用 grep 与 jq 的对比证明机器可处理性的差距
- 能对比节点 DaemonSet / sidecar / 应用直推 / 中心网关四种采集拓扑，并按场景选型
- 能解释日志侧的 cardinality 成本在 ELK 与 Loki 中分别如何体现，判断一个字段该进索引/标签还是留在正文
- 能说清 OTel 的 logs 信号与传统日志管道（Filebeat/Promtail）的关系与衔接方式

## 1. 三支柱中的日志腿

08-pca/01 里已经建立了三支柱的框架（见 [08-pca/01-observability-concepts.md](../08-pca/01-observability-concepts.md)），这里从日志的视角再压一遍：

| | Metrics | Traces | Logs |
|---|---|---|---|
| 回答什么 | 系统整体是否异常、哪里异常 | 一个请求慢在哪个环节、为什么 | 异常时刻到底发生了什么细节 |
| 数据形态 | 预聚合的时序数字 | 带 span 树的事件链 | 逐条文本事件 |
| 量级 | 最小（可压缩、可降采样） | 中（必须采样） | 最大（不采样就全量） |
| 单条成本 | 极低 | 中 | 高（存储 + 索引 + 传输） |
| 典型工具 | Prometheus | Jaeger/Tempo | Loki / ELK |

排查漏斗是自上而下的：

```
  metrics：低成本持续扫描全量信号 → 触发告警（"5xx 涨了"）
     │  exemplar / label
     ▼
  traces：按 trace_id 摊开一个慢请求的完整路径（"慢在 downstream 调用"）
     │  span 里带的 trace_id
     ▼
  logs：在已知时间窗、已知组件内精确捞细节（"connection pool exhausted"）
```

日志的独特价值在于三点，这三点是另外两支柱给不了的：

1. **一次性事件**：配额拒绝、证书过期、OOM kill 这类"只发生一次、没有统计形态"的事，只有日志记录了原始现场。
2. **完整业务上下文**：一行日志可以同时带订单号、用户动作、错误码，不受 metric label 有界性的约束。
3. **黑盒组件**：内核、第三方中间件、老旧应用，你改不了它们的埋点，但它们都会往 stdout/stderr 吐日志。

代价同样明确：日志是三支柱里量最大的信号，"什么都记、什么都索引"是日志系统成本失控的头号原因，第 5 节展开。

## 2. 结构化日志 vs 非结构化日志

同一件事的两种写法：

```
非结构化：
2026-08-22T03:14:05Z ERROR payment handle order 4711 failed, took 312ms, trace=ab12cd34ef56

结构化（JSON）：
{"ts":"2026-08-22T03:14:05Z","level":"error","service":"payment",
 "msg":"handle order failed","order_id":4711,"duration_ms":312,
 "trace_id":"ab12cd34ef56"}
```

区别不在人读起来怎么样，而在机器处理时一个要"猜"，一个能"取"：

| 维度 | 非结构化 | 结构化（JSON） |
|---|---|---|
| 字段提取 | 正则/grok，规则随格式漂移而失效 | 按键取值，格式稳定 |
| 值的类型 | 全是字符串 | 数字/布尔/嵌套对象可保留 |
| 聚合分析 | 先解析再统计 | `jq`/`| json` 一步到位 |
| 解析失败的影响面 | 一条正则错，整批字段错 | 单条失败可标记 `__error__` 跳过 |
| 采集端成本 | 需要复杂 filter（CPU 大户） | 解析廉价，字段过滤可下推 |

结构化日志的最低字段集（面试可直接背）：`timestamp`（RFC3339、UTC）、`level`（小写规范值 info/warn/error）、`service`（服务名）、`msg`（人类可读摘要）、可选的 `trace_id`（与 traces 支柱的接缝）、以及少量业务键。**timestamp 必须由应用自己打**，不要依赖采集时间——采集链路有缓冲延迟，故障排查时几百毫秒的偏差就可能对不上现场。

实战演练一节会用 grep vs jq 实测这个差距。

## 3. 一条日志管道的通用形态

不管后端是 ELK 还是 Loki，管道的段是固定的：

```
┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────────┐   ┌──────────┐
│  日志源   │ → │  采集     │ → │  处理     │ → │  传输/缓冲    │ → │ 存储/索引 │ → 查询/告警
│ 应用stdout│   │ agent    │   │ 解析/富化 │   │ 批量/压缩/重试│   │ ES / 对象 │
│ 文件/journald│ │ filebeat │   │ 脱敏/路由 │   │ (kafka 可选) │   │ 存储+Loki │
└──────────┘   │ promtail │   └──────────┘   └──────────────┘   └──────────┘
               │ otelcol  │
               └──────────┘
```

每一段的工程要点：

- **采集**：离日志源越近越好，读文件比轮询 API 便宜；要记住读取位置（positions/registry），重启后不重读不漏读。
- **处理**：解析（JSON/grok）、富化（补 node/namespace 等 K8s 元数据）、脱敏（密码/token）、过滤（debug 级别的噪声）。处理越靠前，后端存储越干净。
- **传输/缓冲**：批量 + 压缩 + 有限重试；后端故障时的背压策略是"阻塞采集"还是"丢弃并计数"。超大规模时在采集与存储之间加 Kafka 削峰（第 2 章架构演进题展开）。
- **存储/索引**：成本的分水岭——索引多少，直接决定了系统是"贵而快"（ELK）还是"省而准"（Loki），第 5 节展开。

## 4. 采集 agent 选型与拓扑

常见 agent 一览（都活跃维护，选型看生态与功能交集）：

| Agent | 出身 | 强项 | 弱项 | 常见位置 |
|---|---|---|---|---|
| Fluent Bit | CNCF（Fluentd 轻量版） | 极低内存、插件极多、支持输出到几乎所有后端 | 配置模型较琐碎 | K8s 节点 DaemonSet 的事实标准之一 |
| Filebeat | Elastic | 读文件成熟稳定（registry）、与 ES/Logstash 天衣无缝 | 只做采集，处理弱 | ELK 链路的shipper |
| Promtail | Grafana | K8s SD + pipeline_stages 与 Loki 标签模型贴合 | 只为 Loki而生；已宣布维护模式（见第 3 章） | Loki 链路 |
| Vector | Datadog 开源 | 吞吐最高、VRL 转换语言强、无锁架构 | 生态较新 | 高吞吐通用管道 |
| OTel Collector | CNCF | 三信号统一（logs/metrics/traces）、processor 生态、厂商中立 | 日志侧功能仍在追赶专用 agent | 统一采集层（09-otel 的主角） |

部署拓扑有四种，先看图再选：

```
A. 节点 agent（DaemonSet，主流默认）        B. sidecar（每 Pod 一个）
   ┌ node1 ────────────┐                  ┌ Pod ──────────────────┐
   │ app1 app2 app3     │                  │ app        sidecar-  │
   │   └──┬──┘          │                  │  stdout→file  agent  │
   │    daemonset-agent │                  └──────────────────────┘
   └────────┬───────────┘                  每 Pod 付出一份内存/CPU
            └──→ 后端

C. 应用直推（SDK push）                     D. 中心 gateway（两级管道）
   app ──SDK──→ 后端                        agents ──→ 中心 Collector ──→ 多后端
   （改代码、嵌 SDK，最不通用）                 （富化/路由/限流集中做）
```

选型经验：

1. **默认 A**：K8s 里容器 stdout/stderr 已经落在节点文件上（第 4 章详解），一个 DaemonSet 读全节点，资源开销与 Pod 数量解耦。
2. **B 用于特例**：应用写自己的文件而不写 stdout（多行日志按文件分路）、需要按 Pod 精细过滤、或安全边界要求日志不落节点盘。
3. **C 只在有框架且后端压力大时**：埋点见 09-otel，日志直推容易让应用耦合后端细节。
4. **D 是规模化后的形态**：节点 agent 只做"采"，解析富化路由集中到 gateway，与 09-otel/03 的 Collector 部署模式一节同构。
5. 现实里常见组合：**Fluent Bit/OTel Collector 做节点 agent + 中心 OTel Collector 做路由**，一套管道同时喂 Loki（日志）、Prometheus（指标）、Tempo（链路）。

## 5. 日志的 cardinality 成本问题

08-pca 里说过 metrics 的头号杀手是高基数 label（"无界集合只配进 logs/traces"）。日志系统收下了这些无界字段，但**有自己的代价边界：字段可以无界，前提是它不被索引**。

两套后端的爆炸方式不同：

| | ELK（全文索引） | Loki（只索引标签） |
|---|---|---|
| 什么被索引 | 分词后的**每一个词项**（term） | 只有 **label set**（流标识） |
| 高基数字段的影响 | `user_id` 出现一百万个不同值 → 一百万个 term → 倒排索引体积暴涨、segment 合并变慢 | `user_id` 进 label → 一百万条**流（stream）**→ ingester 内存暴涨、索引膨胀、触发流数限制 |
| 成本量级感 | 索引体积常见为原始日志的 1~3 倍（取决于分词与字段量） | 索引通常只有数据量的零头，但流数超限直接拒绝写入 |
| 正确姿势 | 高基数字段设 `index: false`（只存不索引），查询时走慢速扫描 | 高基数字段留在正文，用 `| json` 运行时提取 |

把上一节的两种日志拿来算一笔账。设 1000 QPS、每条日志 500 字节、日志里含 `user_id`（百万级取值）：

```
原始数据：1000 × 500B × 86400s ≈ 43 GB/天（这部分两个系统都跑不掉，靠压缩省）
ELK 索引：若 user_id 被索引 → term 数 ≈ 活跃用户数，倒排表碎片化，
          索引额外 ≈ 数十 GB/天，且拖慢 merge 与查询
Loki    ：若 user_id 进 label → 活跃流数从 O(服务数) 变成 O(用户数)，
          ingester 内存与 TSDB 索引同步爆炸，很快撞 max_global_streams_per_user
正确做法 ：user_id 留在 JSON 正文，ELK 设 index:false，Loki 用 |= "u_12345" 或 | json 后过滤
```

判定规则一句话（面试可用）：**先问"这个字段的取值集合是不是随流量线性增长"，是——进正文不进索引/标签；不是（namespace、cluster、service、env、level 这类有界枚举）——才有资格进索引或 label**。这与 08-pca/01 给 metrics label 的判据完全同源，只是日志系统把"违规的代价"从时序数变成了索引体积/流数。

顺带一个日志独有的维度：**行数本身就是 cardinality**。debug 级别日志在生产里全量保留，等于为"将来可能看"支付 100% 的存储与索引；分级采样（debug 采样保留 1%、error 全量）是日志侧最有效的成本杠杆之一。

## 6. 与 OTel logs 信号的关系

09-otel 模块（见 [09-otel/01-signals-and-context-propagation.md](../09-otel/01-signals-and-context-propagation.md)）讲过三大信号，logs 是最后一个稳定（stable）的信号。它与传统管道的关系不是替代，而是**标准化了"日志怎么表示、怎么传"**：

| 维度 | 传统管道 | OTel 体系 |
|---|---|---|
| 数据模型 | 各家自定义（Filebeat event / Promtail entry） | 统一 Log Record：Body、SeverityNumber、TraceId/SpanId、Attributes、Resource |
| 传输 | 私有协议或 HTTP 自定义 | OTLP（gRPC 4317 / HTTP 4318） |
| 与 trace 的关联 | 靠约定俗成地把 trace_id 打进文本 | 模型内建 TraceId 字段，SDK 自动注入 |
| 采集 | Filebeat/Promtail/Fluent Bit | OTel SDK 直推，或 Collector 的 filelog receiver 收存量日志 |

关键认知：存量应用不会改代码，它们的日志仍然从文件/stdout 来。所以现实的 OTel 日志管道是**混合形态**——这正好是 09-otel/03 Collector 章的用武之地：

```
存量应用（stdout→节点文件） ──filelog receiver──┐
                                              ├─→ OTel Collector ──(OTLP)──→ Loki（3.x 原生支持 OTLP HTTP）
新应用（SDK 直推 OTLP）      ──otlp receiver──┘   processors: k8sattributes 富化、batch、脱敏
```

两条路在 Collector 汇成同一种 Log Record，后端随便换——这就是 09-otel 反复强调的 vendor 无关在日志腿上的落点。第 4 章会给出 filelog receiver 的完整可用配置。

## 实战演练：用 jq 体会结构化的价值

环境：任意一台 Ubuntu 22.04/24.04 VM（有 Docker 更好，没有也行）。

**1. 生成一份带结构的日志文件**

```bash
# [任意Ubuntu VM]
sudo apt-get update && sudo apt-get install -y jq
mkdir -p /opt/log-lab
cat > /opt/log-lab/gen.sh <<'EOF'
#!/usr/bin/env bash
for i in $(seq 1 200); do
  lvl=info
  [ $((i % 10)) -eq 0 ] && lvl=error
  printf '{"ts":"%s","level":"%s","service":"payment","trace_id":"%08x","msg":"handle order %d took %dms"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lvl" $((RANDOM % 4294967295)) "$i" $((RANDOM % 500)) >> /opt/log-lab/app.log
  sleep 0.01
done
EOF
chmod +x /opt/log-lab/gen.sh && /opt/log-lab/gen.sh
wc -l /opt/log-lab/app.log
```

预期输出：`200 /opt/log-lab/app.log`。

**2. 同一个问题，两种问法**

问题：error 日志里耗时最长的三条是什么？

```bash
# [任意Ubuntu VM]
# 非结构化思路：先把 JSON 当纯文本 grep（拿到整行，但没法对 duration 排序）
grep '"level":"error"' /opt/log-lab/app.log | head -3

# 结构化思路：按字段取值、过滤、排序，一条管道完成
jq -r 'select(.level=="error") | [.duration_ms, .msg] | @tsv' /opt/log-lab/app.log \
  | sort -rn | head -3
```

预期输出（数值随机）：三行 `数字<TAB>handle order N took Xms`，按耗时降序。grep 版只能给出"哪些行是 error"，排序、统计、类型比较都要再写解析代码。

**3. 聚合一把（这正是 LogQL/ES 聚合在后台做的事）**

```bash
# [任意Ubuntu VM]
jq -s 'group_by(.level) | map({level: .[0].level, count: length, avg_ms: (map(.msg|capture("took (?<d>[0-9]+)ms").d|tonumber)|add/length)})' /opt/log-lab/app.log
```

预期输出：一个数组，info 约 180 条、error 约 20 条，各带平均耗时。记住这个手感——第 3 章的 LogQL `sum by (level) (count_over_time(...))` 做的就是同一件事，只是发生在服务端、对着 TB 级数据。

**4. 反面教材：时间戳不在字段里**

```bash
# [任意Ubuntu VM]
printf '2026-08-22T03:14:05Z ERROR payment order 4711 failed\n' >> /opt/log-lab/raw.log
jq -r '.level' /opt/log-lab/raw.log 2>&1 | head -2
```

预期输出：报 `jq: error (at <stdin>:1): Cannot index string with "level"`（或 parse error）——非结构化行连解析都过不去，这就是采集端 grok/正则 规则永远在修的原因。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 采集端 CPU 很高 | 对非结构化日志跑大量正则/grok | 推动应用输出 JSON，处理成本降一个数量级 |
| 日志时间戳与告警时间对不上 | 用了采集时刻而非事件时刻 | 应用自己打 RFC3339/UTC 时间戳；采集端解析事件时间覆盖 |
| 排查时找不到某服务的日志 | 日志写了文件而非 stdout，节点 agent 只扫 /var/log/pods | 要么改写到 stdout，要么加 sidecar 采集该文件（第 4 章） |
| 后端存储月度账单线性上涨 | debug 级日志全量入库 + 高基数字段被索引 | 分级采样 + 高基数字段移出索引/标签（第 5 节） |
| 采集重启后日志重复或丢失 | positions/registry 文件放在容器可写层，Pod 重建即丢 | positions 文件挂持久卷或 hostPath |

## 自测

1. 为什么排查顺序是"metrics → traces → logs"而不是反过来？反过来你实际支付了什么？

<details><summary>答案</summary>

metrics 聚合度高、单条成本极低，适合 7x24 扫描全量信号并触发告警；traces 把单个请求摊开但需要按 trace_id 定位；logs 细节最全但量最大，只适合在已知时间窗、已知组件后精确捞取。反过来等于在海量低信号数据里盲搜：存储、索引、扫描成本都按"全量日志"支付，而且没有 metrics 的聚合视图，你甚至不知道该看哪个时间窗。
</details>

2. 应用已经把 trace_id 打进每行日志，这三个支柱在一次故障排查里怎么串起来？

<details><summary>答案</summary>

metrics 告警给出"什么指标、什么时间窗异常"；若指标带 exemplar 或告警信息里能拿到慢请求样本，直接得到 trace_id；在 tracing 后端看该 trace 的 span 树定位慢环节；最后用 trace_id 作为日志的过滤条件（`|= "ab12cd34"` 或解析后的字段过滤），拿到该请求全链路的日志细节。日志侧不需要"索引 trace_id"也能这么用——运行时过滤即可，这正是第 5 节的结论。
</details>

3. 同样 1 TB/天的日志，ELK 和 Loki 的成本结构分别是什么？谁更怕"没有标签约束的查询"？

<details><summary>答案</summary>

ELK：CPU 花在分词与 segment 合并，磁盘花在"原始数据 + 倒排索引"（索引常见为数据量的 1~3 倍），查询快是因为索引把"找词"变成了查表。Loki：磁盘几乎只有压缩后的 chunk（放对象存储，最便宜的一层），索引只有标签流，体积极小；查询时对选中的流做正文扫描，所以**没有标签 narrowing 的查询**（`{}` 裸扫或只带一个宽标签）会退化为对海量 chunk 的暴力扫描，这是 Loki 最怕的场景。ELK 怕的是写入与存储账单，Loki 怕的是自由全文查询。
</details>

4. `user_id` 放进日志正文没问题，为什么把它设成 Loki label 或 ES 索引字段就会出事？

<details><summary>答案</summary>

正文是无索引的压缩数据，多一个字段只是多几个字节。Loki label 决定流的身份：user_id 进 label 意味着每个活跃用户一条独立流，流数从 O(服务数) 变成 O(用户数)，ingester 内存、TSDB 索引、flush 次数全部同比例爆炸，并很快撞 max_global_streams_per_user 被拒写。ES 侧同理：百万 distinct term 碎片化倒排表，索引体积暴涨、merge 与查询变慢。两边的正确做法都是"存而不索引，查询时运行时提取/过滤"。
</details>

5. OTel 已经有 logs 信号了，Filebeat/Promtail 这类专用 agent 还有存在价值吗？

<details><summary>答案</summary>

有，至少在存量系统漫长的一生里。OTel logs 标准化的是"新应用的 SDK 直推"和"Collector 之间的传输"；存量应用、第三方组件、系统日志不改代码就只有文件/stdout 一条路，谁来读文件谁就是入口。OTel Collector 的 filelog receiver 正在读这个角色，但专用 agent 在读文件成熟度、既有生态（如 ELK 链路的 Filebeat registry、Loki 链路的 promtail K8s 发现）上仍有存量优势。现实选型常是：节点层保留专用 agent 或直接用 OTel Collector，中心层用 OTel Collector 统一路由——入口可以渐进替换，OTLP 作为共同语言。
</details>

## 延伸阅读

- Kubernetes 官方：Logging Architecture — <https://kubernetes.io/docs/concepts/cluster-administration/logging/>
- OpenTelemetry Logs 规范 — <https://opentelemetry.io/docs/specs/otel/logs/>
- Grafana Loki 官方文档（概念：标签与流） — <https://grafana.com/docs/loki/latest/get-started/labels/>
- Elastic 下游数据采集文档 — <https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html>
- 本模块后续：[02-elk-stack.md](02-elk-stack.md)、[03-loki-stack.md](03-loki-stack.md)、[04-k8s-logging.md](04-k8s-logging.md)
