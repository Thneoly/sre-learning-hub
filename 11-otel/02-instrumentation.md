# 02 · 埋点：手动 SDK、自动注入与采样

> 模块：OpenTelemetry（06）｜ 建议时长：2.5 小时 ｜ 前置：00、01 章 ｜ 关联认证：—（无直接考点，PCA 进阶）

## 学习目标

- 能操作：用 Python/Go 手动写出带属性、事件、状态的 span，并通过 OTLP 发给后端
- 能解释自动埋点的两条路线（语言发行包 agent 与 K8s Operator 注入）各自的原理与适用面
- 能说出语义约定（Semantic Conventions）的价值，并正确使用 HTTP/DB/RPC 常见属性名
- 能权衡 head-based 与 tail-based 采样，并用 parentbased 保证全链路决策一致
- 能排查：自动埋点后看不到 span 的常见原因

## 1. 两条路线：手动还是自动

| 路线 | 做法 | 覆盖内容 | 适合 |
|---|---|---|---|
| 手动埋点 | 代码里用 API 创建 span/指标 | 框架中间件覆盖不到的**业务语义**（一次结算、一次审批） | 精确表达业务关键路径 |
| 自动埋点（zero-code） | 运行时注入 agent / Operator 修改 Pod | HTTP 服务端客户端、DB 驱动、RPC、MQ、日志 | 快速拿到全量技术指标，零代码改动 |

实践定式：**先上自动埋点拿"面"，再对关键业务路径补手动 span 拿"点"**。两者共存于同一 SDK，trace_id 天然衔接。

## 2. 手动埋点最小示例

### 2.1 Python（与 00 章的 Jaeger 配合，VM 上可直接跑）

```bash
# [任意节点]（带 Docker 的 Ubuntu VM,Jaeger 已按 00 章启动）
python3 -m venv ~/otel-ch02
source ~/otel-ch02/bin/activate
pip install opentelemetry-sdk opentelemetry-exporter-otlp
```

```python
# [任意节点] 保存为 ~/manual_span.py,在 venv 中运行
import time
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import SpanKind, Status, StatusCode

provider = TracerProvider(resource=Resource.create({"service.name": "manual-demo"}))
provider.add_span_processor(BatchSpanProcessor(
    OTLPSpanExporter(endpoint="http://127.0.0.1:4318/v1/traces")
))
trace.set_tracer_provider(provider)
tracer = trace.get_tracer("manual.demo")

with tracer.start_as_current_span(
    "checkout",
    kind=SpanKind.SERVER,
    attributes={"order.id": "A-1234", "order.amount_cents": 9900},
) as span:
    time.sleep(0.02)  # 模拟干活
    span.add_event("inventory.checked", attributes={"stock": 42})
    span.set_status(Status(StatusCode.OK))

provider.shutdown()  # 刷掉批量队列里还没发出去的 span
```

```bash
# [任意节点]
source ~/otel-ch02/bin/activate
python3 ~/manual_span.py
```

到 `http://<VM_IP>:16686` 查服务 `manual-demo`，应看到一条 `checkout` span。要点：

- endpoint 用 OTLP/HTTP 时要带完整路径 `/v1/traces`（gRPC 则是裸地址 + 4317）；
- `set_status` 与 `add_event` 分工：前者是给机器看的结论，后者是时间点事实；
- 出现异常时用 `span.record_exception(e)` + `set_status(Status(StatusCode.ERROR, ...))`（见 01 章演练）。

### 2.2 Go（同语义的最小版）

```go
// [任意节点] 保存为 ~/go-demo/main.go(需 Go 环境;依赖见下方 go get)
package main

import (
	"context"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	sdkresource "go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	"go.opentelemetry.io/otel/trace"
)

func main() {
	ctx := context.Background()
	exp, err := otlptracegrpc.New(ctx,
		otlptracegrpc.WithEndpoint("127.0.0.1:4317"),
		otlptracegrpc.WithInsecure(),
	)
	if err != nil {
		panic(err)
	}
	res, err := sdkresource.New(ctx,
		sdkresource.WithAttributes(attribute.String("service.name", "go-demo")),
	)
	if err != nil {
		panic(err)
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exp),
		sdktrace.WithResource(res),
	)
	defer func() { _ = tp.Shutdown(ctx) }()
	otel.SetTracerProvider(tp)

	_, span := otel.Tracer("example").Start(ctx, "process-order",
		trace.WithSpanKind(trace.SpanKind.SERVER),
		trace.WithAttributes(
			attribute.String("order.id", "A-1234"),
			attribute.Int("order.amount_cents", 9900),
		),
	)
	defer span.End()

	span.AddEvent("payment.ok", trace.WithAttributes(attribute.Bool("payment.captured", true)))
	span.SetStatus(codes.Error, "inventory short")
}
```

```bash
# [任意节点]（需已安装 Go,如 sudo apt install -y golang-go）
cd ~/go-demo
go mod init go-demo
go get go.opentelemetry.io/otel go.opentelemetry.io/otel/sdk go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc
go run .
```

Go 的特点：没有全局魔法，`context.Context` 必须一路显式传（`tracer.Start(ctx, ...)` 返回新 ctx 传给下层），这是它进程内不断链的原因，也是从 Python/Java 转过来最容易踩的差异。

### 2.3 通用环境变量（免改代码改行为）

SDK 行为大量收敛到标准环境变量，运维改配置不动代码就靠它们：

| 变量 | 作用 |
|---|---|
| `OTEL_SERVICE_NAME` | 设置 resource 的 `service.name` |
| `OTEL_RESOURCE_ATTRIBUTES` | 追加 resource，如 `deployment.environment.name=lab,k8s.namespace.name=prod` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP 端点（协议写法见 00 章） |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` 或 `http/protobuf` |
| `OTEL_TRACES_SAMPLER` / `OTEL_TRACES_SAMPLER_ARG` | 采样器与参数（见第 5 节） |

## 3. 自动埋点路线一：语言发行包（zero-code）

各语言的官方发行包/agent 机制不同，原理都是在库加载期包一层：

| 语言 | 启用方式 | 说明 |
|---|---|---|
| Java | `java -javaagent:opentelemetry-javaagent.jar -Dotel.service.name=checkout -jar app.jar` | 最成熟，字节码增强，覆盖面最广 |
| Python | `opentelemetry-instrument python app.py` | 通过 `PYTHONPATH` 注入 sitecustomize 钩子，import 即插桩 |
| .NET | 安装发行包后设置 `OTEL_DOTNET_AUTO_*` 环境变量启用 | 依赖 CLR profiler 机制，细节以官方 zero-code .NET 文档为准 |
| Node.js | `node --require @opentelemetry/auto-instrumentations-node app.js` | 模块加载期插桩 |
| Go | 无字节码可改：eBPF 方案（`go.opentelemetry.io/auto`，构建时加 `-tags=otelngoinstrumentation` 并用 `OTEL_GO_AUTO_TARGET_EXE` 指定目标二进制）；另有基于 `-toolexec` 的编译期注入路线 | 两者都在快速演进，内核/编译要求以官方 Go automatic instrumentation 文档为准 |

版本纪律：发行包与 agent 版本迭代快（各语言独立），统一以 https://opentelemetry.io/docs/zero-code/ 各语言页的 release 说明为准。

### 实战演练：Python 自动埋点跑通跨进程传播

目标：两个 Flask 服务（order-svc 调 inventory-svc），零业务代码改动，在 Jaeger 里看到跨服务的完整 trace。环境：00 章的 Jaeger 仍在运行。

1. 装发行包与常用插桩库：

```bash
# [任意节点]
source ~/otel-ch02/bin/activate
pip install flask requests opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install
```

`opentelemetry-bootstrap -a install` 会检测环境里已有的库（flask、requests……）并自动补装对应的 instrumentation 包。

2. 写两个服务：

```python
# [任意节点] 保存为 ~/app_inventory.py
import random, time
from flask import Flask, jsonify

app = Flask(__name__)

@app.get("/api/inventory")
def inventory():
    time.sleep(random.uniform(0.01, 0.05))
    return jsonify(items=42)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5001)
```

```python
# [任意节点] 保存为 ~/app_order.py
import requests
from flask import Flask, jsonify

app = Flask(__name__)

@app.get("/api/order")
def order():
    r = requests.get("http://127.0.0.1:5001/api/inventory", timeout=3)
    return jsonify(order="ok", items=r.json()["items"])

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
```

3. 分别以不同 `OTEL_SERVICE_NAME` 启动（两个终端，或一个加 `&` 放后台）：

```bash
# [任意节点] 终端 A
source ~/otel-ch02/bin/activate
OTEL_SERVICE_NAME=inventory-svc \
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
opentelemetry-instrument python ~/app_inventory.py
```

```bash
# [任意节点] 终端 B
source ~/otel-ch02/bin/activate
OTEL_SERVICE_NAME=order-svc \
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
opentelemetry-instrument python ~/app_order.py
```

4. 打流量并验证：

```bash
# [任意节点] 第三个终端
curl -s http://127.0.0.1:5000/api/order
```

预期输出：`{"items":42,"order":"ok"}`。Jaeger UI（`http://<VM_IP>:16686`）里 Service 选 `order-svc` → Find Traces，应看到三个 span 组成的一条 trace：

```
order-svc       SERVER   GET /api/order
order-svc       CLIENT   GET            ← requests 自动插桩,注入 traceparent
inventory-svc   SERVER   GET /api/inventory
```

你没有写一行 OTel 代码，traceparent 的注入/提取由插桩库自动完成——对照 01 章手工实验，理解"自动埋点 = 把 inject/extract 与 span 创建标准化了"。

5. 实验一：手工指定 trace_id（模拟外部入口）：

```bash
# [任意节点]
TRACE_ID=$(openssl rand -hex 16)
SPAN_ID=$(openssl rand -hex 8)
curl -s -H "traceparent: 00-${TRACE_ID}-${SPAN_ID}-01" http://127.0.0.1:5000/api/order
echo "TRACE_ID=${TRACE_ID}"
```

到 Jaeger UI 左侧 Find by Trace ID 粘贴 `TRACE_ID`，能查到这条完全由你指定 id 的 trace——服务端 propagator 会尊重外来的 traceparent。

6. 实验二：采样生效验证（重启 order 服务前加采样变量）：

```bash
# [任意节点] 终端 B 重启,加两个变量
OTEL_TRACES_SAMPLER=parentbased_traceidratio \
OTEL_TRACES_SAMPLER_ARG=0.25 \
OTEL_SERVICE_NAME=order-svc \
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318 \
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf \
opentelemetry-instrument python ~/app_order.py
```

```bash
# [任意节点] 第三个终端连打 20 次
for i in $(seq 1 20); do curl -s -o /dev/null http://127.0.0.1:5000/api/order; done
```

预期：Jaeger 中新增 trace 数约为 5 条上下（25% 采样），且**要么整条在、要么整条不在**——这就是 parentbased 的一致性；inventory-svc 不加采样变量也不会产生半截链路，因为它跟随上游的 sampled 位。

## 4. 自动埋点路线二：K8s Operator 注入

在 Kubernetes 里逐个 Pod 配发行包 env 太琐碎，OTel Operator 提供了"给 Pod 打一个注解即完成注入"的机制：`Instrumentation` CR 定义全局端点/采样/propagators，namespace 或 pod 上的注解决定给哪个工作负载注入哪种语言的 agent（Java 注入 init 容器复制 javaagent、Python 注入 wheel 目录并设置 PYTHONPATH、Go 注入 eBPF 探针容器）。注解名、各语言差异与完整实战在第 04 章，此处先记住分工：

| 对比项 | 语言发行包 | Operator 注入 |
|---|---|---|
| 生效位置 | 进程启动参数/环境变量 | Pod 创建时（mutating webhook） |
| 改造量 | 每个部署描述文件 | 一条注解 + 一个 CR |
| 适用环境 | VM、容器、K8s 通吃 | 仅 K8s |

## 5. 语义约定（Semantic Conventions）

自动埋点的 span 属性为什么"长得一样"？因为都遵循语义约定——一套跨语言、跨厂商的属性命名规范。价值：跨服务聚合（所有服务的 `http.response.status_code` 都能进同一条 PromQL）、仪表盘与告警模板复用、厂商后端自动识别。

高频属性速查（以官方 semconv 页为准，规范在持续演进）：

| 领域 | 常见属性 |
|---|---|
| HTTP server | `http.request.method`、`url.scheme`、`url.path`（或带参数模板的 `url.template`）、`http.response.status_code`、`server.address`、`server.port`、`user_agent.original` |
| HTTP client | 同上，另加 `url.full`、`network.peer.address` |
| DB | `db.system.name`（postgresql/mysql/redis…）、`db.namespace`、`db.operation.name`、`db.query.text`（高敏，注意脱敏配置）、`db.response.status_code` |
| RPC | `rpc.system`（grpc/dubbo…）、`rpc.service`、`rpc.method`、`rpc.grpc.status_code` |
| Messaging | `messaging.system`、`messaging.destination.name`、`messaging.operation.name`（publish/deliver/process） |
| Resource（必备） | `service.name`、`service.version`、`service.instance.id`、`k8s.namespace.name`、`k8s.pod.name`、`container.id`、`host.name` |

版本演进注意（务必留意，否则"面板好好的换了 SDK 版本就空了"）：semconv 有过一次大的改名，例如 `http.method` → `http.request.method`、`http.status_code` → `http.response.status_code`、`db.name` → `db.namespace`。各语言 SDK 遵循的 semconv 版本不同，有的提供兼容开关（如 Java 的 semconv stability 配置），以所用 SDK 版本的文档为准。手动埋点也建议用这些名字，别自造。

## 6. 采样策略

全量 trace 的成本（网络、后端存储、Grafana 查询）随流量线性上涨，采样是成本治理的核心手段。

### 6.1 head-based（头部采样，SDK 侧）

在 span 创建**之前**决定整条链路记不记。默认 `parentbased`：根上按规则决策，沿途通过 traceparent 的 sampled 位同步给所有下游。

| 采样器（`OTEL_TRACES_SAMPLER` 取值） | 行为 |
|---|---|
| `always_on` | 全采（默认，练习环境用它） |
| `always_off` | 全不采 |
| `traceidratio` | 按 trace_id 哈希比例采（如 ARG=0.25） |
| `parentbased_always_on` / `parentbased_traceidratio` 等 | 上述采样器包上"跟随父决策"的逻辑 |

优点：零内存压力、实现简单、一致性好。缺点：**看不到"没被采到的慢请求"**——决策发生在看到结果之前。

### 6.2 tail-based（尾部采样，Collector 侧）

先收完整条 trace，再按整体特征决定保留：Collector 的 `tail_sampling` processor 概念示例（完整部署见第 3、4 章）：

```yaml
# [master] Collector 端 tail_sampling 概念示例(节选,语法以所装 contrib 版本文档为准)
processors:
  tail_sampling:
    decision_wait: 10s        # 攒齐一条 trace 的等待窗口
    num_traces: 50000         # 内存里同时跟踪的 trace 数
    policies:
      - name: keep-errors
        type: status_code
        status_code:
          status_codes: [ERROR]
      - name: keep-slow
        type: latency
        latency:
          threshold_ms: 800
      - name: keep-baseline
        type: probabilistic
        probabilistic:
          sampling_percentage: 10
```

优点：可以"所有错误全留、正常流量抽 10%"，排障价值最高。代价：Collector 要在内存里缓冲整条 trace（延迟 + 内存），且要求 trace 的所有 span 都先到这同一个 Collector（分层部署时要规划好，见第 3 章）。

### 6.3 组合定式

练习集群：`always_on`，数据量小、看得全。生产常见：SDK 侧 `parentbased_traceidratio`（如 100% 的 W3C 传播 + 高比例头部采样）+ Collector 侧 tail（错误/慢全留、其余抽稀），两层配合把成本压到可控。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `opentelemetry-bootstrap` 装完仍无 span | 应用依赖版本不在插桩库支持矩阵里 | `pip list` 对照 instrumentation 包的版本要求；或手动 `pip install opentelemetry-instrumentation-flask` 等 |
| endpoint 4318 报 404 / 4317 报协议错误 | HTTP 端点少了 `/v1/traces` 路径，或协议变量与端口不配套 | HTTP：`http://host:4318/v1/traces` 且 `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`；gRPC：`host:4317` |
| Go 服务永远没有自动 span | 误以为 Go 也有 javaagent 式注入 | Go 走 eBPF/编译期方案，或直接手动埋点（见 2.2） |
| 升级 SDK 后仪表盘空了 | semconv 属性改名（`http.method` → `http.request.method` 等） | 对齐 SDK 的 semconv 版本，用兼容开关或更新查询 |
| 加了 traceidratio 后链路时有时无、断半截 | 采样器不是 parentbased，下游不跟随根决策 | 用 `parentbased_*` 系列；跨服务统一策略 |
| Jaeger 里 service 名是 unknown_service | 没设 `OTEL_SERVICE_NAME`/resource | 启动时显式设置，别依赖默认值 |

## 自测

1. 自动埋点已经覆盖了 HTTP/DB，为什么还需要手动埋点？举一个自动埋点永远给不了的例子。

<details><summary>答案</summary>

自动埋点只认识"通用技术动作"（一次 HTTP 请求、一条 SQL）。业务语义层的信息——"这次 checkout 涉及 3 个仓库、走了人工审核分支、优惠金额 25 元"——只有业务代码知道。在关键路径上包一个业务 span（如 `order.checkout`，带 `order.warehouse_count` 等属性），才能把技术耗时归因到业务环节。
</details>

2. `OTEL_TRACES_SAMPLER=traceidratio` 与 `parentbased_traceidratio` 在多服务环境下行为有什么本质差别？

<details><summary>答案</summary>

前者每个服务独立按 trace_id 哈希决策：同一 trace_id 的哈希结果虽然一致（同一条链路要么都采要么都不采，比例本身一致），但**与根决策无关**——若各服务配的比例不同，会出现"上游没采、下游采了"的孤儿 span。parentbased 先看 traceparent 的 sampled 位，没有父才用比例规则，保证整条链路跟随根上的一次决策。
</details>

3. 为什么 tail sampling 通常部署在"能看到整条 trace"的层级？放在节点 agent 上会怎样？

<details><summary>答案</summary>

tail sampling 要等一条 trace 的全部 span 到齐才能评估（是否出错、总耗时）。节点 agent 只能看到本节点产生的 span，跨节点的服务调用会让同一条 trace 的 span 分散在多个 agent，各自决策必然碎片化。所以 tail sampling 放在中心层（gateway），由分层拓扑把所有 span 先汇聚（见第 3 章部署模式）。
</details>

4. semconv 改名（如 `http.status_code` → `http.response.status_code`）期间，如何让新旧 SDK 混跑的集群仪表盘不出空洞？

<details><summary>答案</summary>

在采集层兼容：Collector 的 attributes/transform processor 把旧名归一化成新名（或反向），统一后端里的标签；或者临时用 Grafana 变量/多查询合并两个标签。长期靠统一 SDK 版本与 semconv 策略，版本升级前列出属性名变更清单（以官方 semconv changelog 为准）。
</details>

5. 你把 `OTEL_EXPORTER_OTLP_ENDPOINT` 从 `http://collector:4318` 改成了 `collector:4317`，为什么可能反而连不上了？

<details><summary>答案</summary>

端口切换必须伴随协议切换：4317 是 gRPC、4318 是 HTTP。端点改了但 `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` 没变，等于对 gRPC 端口说 HTTP（或反之），握手失败。两个端口对应两种传输，endpoint 写法（有无 scheme/路径）与协议变量必须成套修改。
</details>

## 延伸阅读

- Zero-code 埋点总入口（各语言）：https://opentelemetry.io/docs/zero-code/
- 手动埋点文档（按语言）：https://opentelemetry.io/docs/languages/
- 语义约定索引：https://opentelemetry.io/docs/specs/semconv/
- 采样规范（含 parentbased）：https://opentelemetry.io/docs/specs/otel/trace/trace-api-sampling/
- tail_sampling processor：https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/processor/tailsamplingprocessor
- Go 自动埋点（eBPF/编译期路线）：https://opentelemetry.io/docs/languages/go/automatic/
