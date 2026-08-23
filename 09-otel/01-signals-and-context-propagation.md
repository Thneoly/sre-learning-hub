# 01 · 三大信号与上下文传播

> 模块：OpenTelemetry（06）｜ 建议时长：2 小时 ｜ 前置：00 章 ｜ 关联认证：—（无直接考点，PCA 进阶）

## 学习目标

- 能逐字段解释 trace/span 数据模型（trace_id / span_id / parent_span_id / attributes / events / links / status / kind）
- 能逐段拆解 W3C Trace Context 的 `traceparent` 头，并说明 baggage 的用途与边界
- 能说明上下文在 HTTP header、gRPC metadata、消息队列三种载体上的传播方式，以及断链的常见原因
- 能描述 OTel metrics 模型与 Prometheus 数据模型的映射关系
- 能解释日志如何携带 trace_id 实现三信号关联，并操作验证 span 的每个字段

## 1. 三信号的公共底座：Resource 与 Scope

三大信号共享两块"公共底座"，理解它们是理解关联的前提：

- **Resource**：产生遥测数据的实体描述，一个进程一份。典型键：`service.name`、`service.version`、`k8s.namespace.name`、`k8s.pod.name`、`container.id`。Collector 侧的 k8sattributes processor 补的也是这些（见第 3、4 章）。
- **Instrumentation Scope**：标记"这份数据由哪个埋点库/模块产生"，如 `io.opentelemetry.grpc-1.6` 或你手动埋点时命名的 tracer。排查"某库里点量异常"时靠它。

三个信号加上这两个底座，才构成能互相关联的整体：

```
            Resource (service.name = checkout, k8s.pod.name = checkout-7f9c...)
                        │
        ┌───────────────┼───────────────┐
        ▼               ▼               ▼
     traces           metrics          logs
   (trace_id...      (时间序列+        (severity+
    span_id)          labels)           body)
        └──── trace_id / span_id 串起 ────┘
        └──── exemplar(指标点携带 trace_id) ──┘
```

## 2. Trace / Span 数据模型逐字段

一次分布式调用的树状结构：trace 是一次逻辑请求的全貌，span 是其中一段工作。

```
trace_id = 0af7651916cd43dd8448eb211c80319c
时间 ─────────────────────────────────────────────►
frontend        ████████████████████████████████  (SERVER)
  └─ checkout       ██████████████████████        (SERVER, parent=frontend)
       ├─ cart          ████████                  (CLIENT→SERVER 对)
       ├─ currency         ██████
       ├─ payment             ████
       └─ kafka:order          ▲ PRODUCER
                                 └─ accounting  ████ CONSUMER (异步,靠 links 关联)
```

字段逐个过（这是排查和写埋点时的"字典"）：

| 字段 | 类型/格式 | 说明 |
|---|---|---|
| `trace_id` | 16 字节，32 个 hex 字符 | 一次逻辑请求全程不变；全零非法 |
| `span_id` | 8 字节，16 个 hex 字符 | 仅在所属 trace 内唯一；全零非法 |
| `parent_span_id` | 8 字节 | 父 span 的 id；根 span 此字段为空。整棵树靠它串成 |
| `trace_state` | 键值对列表 | W3C Tracestate，给厂商携带额外路由/采样提示，最多 32 项 |
| `name` | 字符串 | span 语义名，遵循语义约定时如 `GET /users/:id`、`SELECT db.users` |
| `kind` | 枚举 | SERVER / CLIENT / INTERNAL / PRODUCER / CONSUMER，见下表 |
| `start_time` / `end_time` | 时间戳 | 由 `GetTimestamp` 类时钟源生成，纳秒精度 |
| `attributes` | 键值 map | 静态描述：`http.request.method=POST`、`db.system.name=postgresql` |
| `events` | 列表 | 时间点事实（打点）：`cache.miss`、异常栈，各自带时间戳与属性 |
| `links` | 列表 | 指向**其他 trace** 中 span 的引用（trace_id+span_id+attributes），用于批处理、异步消费 |
| `status` | 枚举+描述 | `Unset` / `Ok` / `Error`（+ message）。是给机器看的结论，别用属性凑合 |
| `resource` | 键值 map | 见第 1 节 |
| `instrumentation_scope` | 对象 | 见第 1 节 |

kind 的语义（直接影响后端如何渲染调用关系）：

| kind | 场景 | 后端视角 |
|---|---|---|
| SERVER | 收到入站请求（HTTP handler、gRPC service） | 展示为"服务节点" |
| CLIENT | 发出出站请求（调用下游） | 挂在 SERVER 下，两端各记一段 |
| INTERNAL | 进程内函数/步骤 | 不跨进程，通常折叠 |
| PRODUCER | 发消息到队列（Kafka produce） | 同步链到此为止 |
| CONSUMER | 从队列收消息 | 常与 PRODUCER 通过 links 关联，而非 parent |

三个容易用错的点：

- **CLIENT 与 SERVER 是两个 span**：调用方记 CLIENT、被调方记 SERVER，两侧 trace_id 相同、SERVER 的 parent 指向 CLIENT，这是"一根线跨两个服务"的实现方式；
- **status 要显式设置**：SDK 不会因为函数抛异常自动把 status 置为 Error，异常要用 `record_exception` 记成 event 并手动置 Error（见第 2 章）；
- **links 不是 parent**：异步消费、批量处理时"因果但不嵌套"的关系用 links，后端会画成虚线关联。

## 3. 上下文传播（context propagation）

### 3.1 进程内：context 对象

当前"活跃 span"由语言级 context 承载：Go 的 `context.Context`、Python 的 `contextvars`、Java 的 ThreadLocal/ScopedValue。SDK 在创建 span 时读它、结束时写回。**业务代码把 context 一路显式传递**（尤其是 Go），是进程内不断链的前提。

### 3.2 跨进程：W3C Trace Context

出进程时，context 被序列化成 HTTP header（gRPC metadata 同名）。OTel 默认 propagator 是 W3C Trace Context + Baggage。`traceparent` 逐字段拆解：

```
traceparent: 00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01
             ┬─┬ ┬──────────────────────────────┬ ┬──────────────┬ ┬┘
             │ │                                │                │  └─ trace-flags
             │ │                                │                └──── parent-id (16 hex)
             │ │                                └───────────────────── trace-id (32 hex)
             │ └────────────────────────────────────────────────────── version (2 hex, 00)
             └──────────────────────────────────────────────────────── 头固定字面量
```

| 字段 | 长度 | 含义 |
|---|---|---|
| version | 2 hex | `00` 为当前版本 |
| trace-id | 32 hex | 整条链路统一，不得为全零 |
| parent-id | 16 hex | **发起方当前的 span_id**（即将成为接收方新 span 的 parent） |
| trace-flags | 2 hex | 位图，bit0 = sampled（`01` 采样、`00` 未采样） |

注意两点：

- `parent-id` 就是"传出去的那个 span"，所以拿到 traceparent 的服务，其 SERVER span 的 `parent_span_id` 恰好等于头里的 parent-id——手工排查断链时靠这个对账；
- `trace-flags=01` 是下游"是否继续采样"的信号，配合 parentbased 采样器保证整条链路决策一致（见第 2 章）。

配套的 `tracestate`（如 `traceparent` 旁边一行 `tracestate: congo=t61rcWkgMzE`）给厂商/平台放附加键值，日常排障很少碰它。

### 3.3 Baggage：随请求传播的业务键值

Baggage 是与 trace **并行**的另一组传播数据，同样走 HTTP header：

```
baggage: user_id=42, tenant=acme
```

- 用途：把租户、用户、灰度标记一路带到所有下游，供埋点属性、日志、业务逻辑读取；
- 边界：**明文传播、默认无完整性校验**，不要放敏感数据（token、身份证号）；总大小有限（W3C 建议整头不超过若干 KB，代理可能截断超长头）；
- 区分：baggage 传"业务上下文"，tracestate 传"厂商追踪提示"，别混用。

### 3.4 三种载体与断链高发区

| 载体 | 机制 | 注意 |
|---|---|---|
| HTTP | header：`traceparent`、`baggage` | 反向代理/网关必须放行这两个头；curl 手工构造即可注入 |
| gRPC | metadata，键名相同 | 拦截器（interceptor）负责注入/提取，自动埋点一般已覆盖 |
| 消息队列 | 消息属性/头：Kafka record headers、AMQP headers | PRODUCER 注入、CONSUMER 提取；批量消费时一条消息一个 context，循环里要逐条切换 |

异步场景（线程池、定时任务、`go func()`）是断链重灾区：SDK 不会自动跨线程搬运 context，需要在任务提交时捕获、执行时恢复（各语言有对应工具，如 Python 的 `contextvars.copy_context()`）。

## 4. Metrics 模型与 Prometheus 的映射

OTel metrics 是"测量 + 属性 + 时间性"三要素，与 Prometheus 概念基本一一对应：

| OTel instrument | 语义 | Prometheus 对应 |
|---|---|---|
| Counter | 单调递增计数 | counter（导出时按约定追加 `_total`） |
| UpDownCounter | 可增可减（连接数、队列深度） | gauge |
| Gauge | 瞬时值 | gauge |
| Histogram | 显式桶的累计分布 | histogram（`_bucket`/`_sum`/`_count`） |
| ExponentialHistogram | 指数桶，桶数少分辨率高 | 原生 histogram（转换导出） |
| ObservableCounter/Gauge/UpDownCounter | 异步回调采集 | 同上，类型同基名 |

映射时的三处"翻译"（由 Collector 的 prometheus exporter/remote write 完成）：

1. **命名**：`http.server.request.duration` → `http_server_request_duration`（点换下划线）；
2. **单位**：OTel 用 URI 风格单位（`s`、`By`），导出转基本单位并追加后缀，如 `_seconds`；
3. **temporality（时间性）**：Prometheus 只接受累计（cumulative）语义；OTel SDK 支持 cumulative/delta，默认 cumulative，可用环境变量 `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` 控制。给 Prometheus 喂 delta 直方图会被丢弃或告警，这是集成时的高频坑。

第四个信号位是 **exemplars**：histogram 的数据点可以携带"生成这个点的那次请求的 trace_id"。Grafana 里从直方图点击 exemplar 直接跳 trace——metrics 与 traces 的关联就靠它（Prometheus 支持有限容量的 exemplar 存储，参数以官方文档为准）。

## 5. Logs 如何带 trace_id：三信号关联的闭环

OTel 的 LogRecord 模型字段：

| 字段 | 说明 |
|---|---|
| Timestamp / ObservedTimestamp | 事件时间 / 采集端观测时间 |
| SeverityNumber / SeverityText | 级别数字（1~24）/ 文本（INFO/WARN/…） |
| Body | 日志正文（进 Loki 就是 line） |
| Attributes | 结构化键值 |
| **TraceId / SpanId** | 关联键——日志发出时的活跃 span 上下文自动写入 |
| Resource / Scope | 与 traces、metrics 同源 |

关联机制汇总（Grafana 里全部可点）：

- **trace → logs**：在 trace 视图按 trace_id 查日志（Jaeger/Tempo 与 Loki 数据源联动）；
- **logs → trace**：日志行上的 trace_id 链接跳回瀑布图；
- **metrics → trace**：exemplar。
- 前提是日志真的带上了 trace_id——用第 2 章的日志桥接（log appender）而不是裸 `print`。

## 实战演练：把每个字段打印出来亲手玩一遍

目标：不接任何后端，用 `ConsoleSpanExporter` 把 span 的完整字段打在终端上，再手工完成一次"进程边界"的注入/提取。环境：任意 Ubuntu 22.04/24.04（VM 或节点均可，只需 Python 3）。

1. 建 venv 装包（Ubuntu 24.04 起 pip 受 PEP 668 限制，必须用 venv）：

```bash
# [任意节点]
python3 -m venv ~/otel-ch01
source ~/otel-ch01/bin/activate
pip install opentelemetry-sdk
```

2. 写演示脚本：

```python
# [任意节点] 保存为 ~/span_fields_demo.py,在 venv 中运行
from opentelemetry import trace
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor, ConsoleSpanExporter
from opentelemetry.sdk.trace.sampling import ALWAYS_ON
from opentelemetry.trace import Link, SpanKind, Status, StatusCode
from opentelemetry.propagate import inject, extract

resource = Resource.create({
    "service.name": "ch01-demo",
    "deployment.environment.name": "lab",
})
provider = TracerProvider(resource=resource, sampler=ALWAYS_ON)
provider.add_span_processor(BatchSpanProcessor(ConsoleSpanExporter()))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("ch01.demo", "1.0.0")

# 先造一条"历史"trace,用它的 span 演示 links(因果但非父子)
with tracer.start_as_current_span("batch-item") as old:
    linked = Link(old.get_span_context(), attributes={"reason": "checkout-included-batch"})

# 入口 span,相当于一次进站请求
with tracer.start_as_current_span(
    "POST /api/checkout",
    kind=SpanKind.SERVER,
    attributes={"http.request.method": "POST", "url.path": "/api/checkout"},
) as server:
    server.add_event("cache.miss", attributes={"cache.key": "user:42"})

    # 进程边界:把当前 context 注入 HTTP 头
    headers = {}
    inject(headers)
    tid = format(server.get_span_context().trace_id, "032x")
    sid = format(server.get_span_context().span_id, "016x")
    print(">>> trace_id    :", tid, "len =", len(tid))
    print(">>> span_id     :", sid, "len =", len(sid))
    print(">>> traceparent :", headers.get("traceparent"))

    # 模拟下游服务:从头里恢复 context,再开自己的 span(于是 parent 指向对端)
    ctx = extract(headers)
    with tracer.start_as_current_span(
        "GET /api/inventory",
        kind=SpanKind.CLIENT,
        context=ctx,
        links=[linked],
    ) as client:
        try:
            raise ValueError("connection refused")
        except Exception as e:
            client.record_exception(e)
            client.set_status(Status(StatusCode.ERROR, "inventory unreachable"))

provider.shutdown()  # 刷掉 BatchSpanProcessor 里排队中的 span
```

3. 运行并对照字段：

```bash
# [任意节点]
source ~/otel-ch01/bin/activate
python3 ~/span_fields_demo.py
```

预期输出两段 JSON（ConsoleSpanExporter 的输出），节选关键结构：

```text
>>> trace_id    : 4bf92f3577b34da6a3ce929d0e0e4736 len = 32
>>> span_id     : 00f067aa0ba902b7 len = 16
>>> traceparent : 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
{
    "name": "GET /api/inventory",
    "context": {
        "trace_id": "0x4bf92f3577b34da6a3ce929d0e0e4736",
        "span_id": "0x5b8aa5a2d2c89610",
        ...
    },
    "parent_id": "0x00f067aa0ba902b7",
    "kind": "SpanKind.CLIENT",
    ...
    "status": { "status_code": "ERROR", "description": "inventory unreachable" }
}
```

逐条验证三件事：

- `trace_id` 恒为 32 个 hex、`span_id` 恒为 16 个 hex（脚本已打印长度）；
- 两个 span 的 `trace_id` 相同，且子 span 的 `parent_id` == 父 span 的 `span_id` == traceparent 里的 parent-id 段；
- 异常被记成 event（含栈），status 显式为 ERROR。

4. 变换实验（理解采样标志）：把 `sampler=ALWAYS_ON` 改成 `ALWAYS_OFF` 再跑一次。预期：没有任何 span JSON 输出（采样器拒绝记录），且注入的 traceparent 末段变成 `-00`（sampled=0）。这就是"上游未采样时，下游也按约定不再记录"的机制源头。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| Jaeger/Grafana 里链路在某一跳断成两截 | 该跳没装 propagator、代理剥掉了 traceparent 头、或异步任务丢了 context | 在断点前后对账 traceparent 的 parent-id；网关放行 `traceparent`/`baggage` 头；异步处显式搬运 context |
| 全链路只有零星几个服务出现 | 各服务采样决策不一致（有的 1%、有的全量） | 用 parentbased 采样（第 2 章），保证跟随根决策 |
| 子 span 的 parent_id 与对端 span_id 对不上 | 中间某层"消费"了 traceparent 却没传下去（如消息消费者批量处理） | 检查 MQ consumer 是否逐消息提取 context；必要时用 links 显式关联 |
| baggage 里的值到下游变成了空/截断 | 值未按规范 percent-encode，或总长超限被中间盒丢弃 | 只放简单 token 值；敏感/大对象放业务存储，baggage 只带键 |
| 给 Prometheus 的直方图消失并报 temporality 警告 | SDK 配成 delta，而 Prometheus 语义要求 cumulative | `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative`（或后端改用支持 delta 的存储） |
| 日志查不到 trace_id | 应用用裸 print/自有 logger，没接 OTel 日志桥接 | 用第 2 章的日志集成自动注入 TraceId/SpanId |

## 自测

1. 为什么 CLIENT 和 SERVER 要记成两个 span，而不是调用方记一个"跨服务 span"？

<details><summary>答案</summary>

一次跨服务调用发生在两台机器、两个进程，时钟、进程上下文、故障域都不同。两侧各记一个 span（CLIENT 在调用方、SERVER 在被调方），trace_id 相同、parent 指向 CLIENT，既能分别反映两侧视角的耗时与错误（网络耗时可由两者差值推算），又便于按 SERVER span 聚合"服务级"指标。单 span 无法表达"网络那一段"和"被调方处理段"的差异。
</details>

2. 如果入口服务采样率 100%、下游服务 10%，会发生什么？反过来呢？

<details><summary>答案</summary>

采样决策通过 traceparent 的 sampled 位向下游传播。若下游不跟随父决策而自作主张：入口 100% + 下游 10%，则 90% 的请求在下游只有前半段，链路"半截"；反过来入口 10% + 下游 100%，则偶发下游 span 找不到父链（孤儿 span）。两种都破坏分析。所以默认采样器是 parentbased：根上决策一次，全链路跟随。
</details>

3. PRODUCER/CONSUMER 场景为什么常用 links 而不是 parent？如果强行用 parent 会怎样？

<details><summary>答案</summary>

消息的消费时间可能远晚于生产，且一条消息可能被批量消费、一个消费者处理多条来自不同 trace 的消息，父子关系（严格的嵌套时间窗）不成立。强行用 parent 会造成时间线错乱（子 span 早于父结束之后才开始）和一对多的冲突。links 表达"因果引用"而非"时间嵌套"，后端按虚线关联渲染，语义正确。
</details>

4. `trace_flags=01` 和"这条 trace 一定会被存储"是等价的吗？

<details><summary>答案</summary>

不等价。sampled 位只是"沿途各方建议记录"的传播信号；最终是否落库还取决于每个环节的策略——例如后端本身的过滤规则，或 Collector 的 tail sampling 在收集端改判（保留错误的、丢弃正常的）。反之 tail sampling 想保留某条链路时，也要求沿途 sampled=01 才能拿到完整数据，因此 tail 方案通常配合全量/高比例 head 采样。
</details>

5. 同一个指标在 OTel 里叫 `http.server.request.duration`（unit=s），进 Prometheus 后名字变成什么样？中间发生了哪几步"翻译"？

<details><summary>答案</summary>

通常变为 `http_server_request_duration_seconds`（直方图则再带 `_bucket`/`_sum`/`_count` 后缀；counter 追加 `_total`）。翻译包括：属性分隔符点换下划线、单位转换为基本单位秒并按命名约定加 `_seconds` 后缀、按 instrument 类型加类型后缀。做仪表盘或 PromQL 时要按转换后的名字查（拿不准先在 Prometheus 的 metric explorer 里搜前缀）。
</details>

## 延伸阅读

- W3C Trace Context 规范：https://www.w3.org/TR/trace-context/
- W3C Baggage 规范：https://www.w3.org/TR/baggage/
- OTel 信号数据模型（spec）：https://opentelemetry.io/docs/specs/otel/
- Python SDK 文档：https://opentelemetry.io/docs/languages/python/
- Prometheus 与 OTel 的集成说明：https://prometheus.io/docs/prometheus/latest/feature_flags/#otlp-receiver（特性状态以官方文档为准）
