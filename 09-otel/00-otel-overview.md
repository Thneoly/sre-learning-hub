# 00 · OpenTelemetry 概览：可观测性的行业事实标准

> 模块：OpenTelemetry（06）｜ 建议时长：1.5 小时 ｜ 关联认证：—（无直接考点，PCA 可观测理念的进阶延伸）

## 学习目标

- 能解释 OpenTelemetry 为什么诞生（OpenTracing 与 OpenCensus 的合并），以及它和 PCA 里学过的 Prometheus/Jaeger/Loki 是什么关系
- 能说出 OTel 的组成部分（规范 / API / SDK / OTLP / Collector / Operator）与三大信号的成熟度现状
- 能描述 OTLP 协议的两种传输方式（gRPC 4317 / HTTP 4318）和一条典型数据链路
- 能操作：在一台装有 Docker 的 Ubuntu VM 上，用 10 分钟搭出"应用 → OTLP → Jaeger"最小链路并看到第一条 trace

## 1. 为什么需要一个"新"标准

PCA 模块里你已经攒了一套可观测栈：Prometheus 拉指标、Loki 收日志、Jaeger/Tempo 存 trace。现在回答一个尖锐的问题：**埋点代码写在哪？**

埋点发生在业务应用内部（进程里的 SDK、JVM 里的 agent），它是整条链路里最贴近业务、也最难改的一层。如果埋点绑定某个后端厂商的私有 SDK（Datadog dogstatsd、Dynatrace OneAgent、New Relic agent……），换后端就意味着改业务代码、回归测试、全量重新发布。这是过去十年可观测领域最大的锁定痛点。

OpenTelemetry（下称 OTel）给出的答案：**埋点层 vendor 无关**——应用只认识一套标准 API 和一种标准线协议（OTLP），数据先交给一个中立的采集层（Collector），由它负责对接任何后端：

| OTel 管什么 | OTel 不管什么 |
|---|---|
| API/SDK（生成 traces/metrics/logs） | 长期存储 |
| OTLP 线协议（怎么传） | 告警规则（仍是 Prometheus Alertmanager 的地盘） |
| Collector（采集、处理、路由） | 可视化（仍是 Grafana 的地盘） |
| Operator（K8s 里的自动化） | PromQL 等查询语言 |

一句话定位：**OTel 是"产生和运输遥测数据"的事实标准，不是后端**。你在 PCA 学的 PromQL、Grafana 仪表盘、告警链路全部继续有效。

## 2. 历史：两个项目合并成一个标准

OTel 不是凭空发明的，它是两代分布式追踪标准的合并产物：

| 项目 | 出生 | 定位 | 留下的遗产 |
|---|---|---|---|
| OpenTracing | 2016，CNCF | 厂商中立的 tracing **API 规范**，多语言、多后端实现 | API 形态（Tracer/Span/Scope）被 OTel 直接继承 |
| OpenCensus | 2018 前后开源，Google 主导 | tracing + metrics 一体，自带采集 agent（ocagent）与传播格式 | "API + 运行时 + 采集层"的完整版图、agent 分发思路 |
| OpenTelemetry | 2019-05 宣布合并 | CNCF 项目，目标"可观测领域的 Kubernetes" | 统一 API/SDK/OTLP/Collector，三大信号 |

合并的动因很现实：两套标准并存时，库作者要写两遍插桩、厂商要适配两边、用户要赌方向。2019 年 5 月 CNCF 联合双方宣布合并为 OpenTelemetry，社区与厂商迅速靠拢。

今天的地位（这是本模块反复强调的背景）：

- CNCF 内活跃度第一梯队：贡献者数量、提交频率常年与 Kubernetes、Prometheus 并列前排；
- 主流可观测厂商（Datadog、Dynatrace、New Relic、Grafana、Splunk、Honeycomb 等）与三大云（AWS、GCP、Azure 的托管服务）都原生支持 OTLP 接入；
- CNCF 生态新项目默认以 OTel 作为埋点出口，就像容器运行时默认对接 CRI 一样。

结论：**学 OTel 不是学一个可选工具，而是学行业默认接口**。

## 3. 项目组成与信号成熟度

OTel 是一组子项目的集合，先建立全景：

```
┌──────────────────────────────────────────────────────────────┐
│  Specification（规范：信号模型、语义约定、OTLP、环境变量）      │
└───────────────────────────┬──────────────────────────────────┘
                            │ 定义
                            ▼
┌─────────────┐  实现   ┌──────────────┐  OTLP   ┌─────────────┐
│ API（接口）  │ ──────► │ SDK（各语言） │ ──────► │ Collector   │
│ Go/Java/Py/ │         │ 采样/批处理/  │         │ 独立数据平面 │
│ JS/.NET/... │         │ 资源描述      │         │             │
└─────────────┘         └──────┬───────┘         └──────┬──────┘
                             │                       │
                             │  zero-code 自动埋点     │ 处理/路由/转发
                             ▼                       ▼
                      自动注入（发行包 /         各类后端
                      K8s Operator 注入）
```

三大信号（signals）的成熟度现状（版本细节以官方规范状态页为准）：

| 信号 | 规范状态 | 主流语言 SDK | 备注 |
|---|---|---|---|
| Traces | stable（1.x，最早在 2021 年初冻结） | Go/Java/Python/JS/.NET 均稳定 | 最成熟，自动埋点覆盖最广 |
| Metrics | stable（其后冻结） | 主流语言稳定 | 与 Prometheus 模型互转顺畅 |
| Logs | stable（最晚冻结） | 各语言"日志桥接"完备度不一 | logs bridge API 在部分语言仍标注 experimental，以官方文档为准 |

版本纪律（本模块统一约定）：**规范与三大信号的 SDK 已进入稳定的 1.x；但 Collector 发行版（core/contrib）、Operator、各语言自动埋点镜像的版本迭代很快且彼此不同步**。本模块所有内容不写死小版本号，动手前以对应仓库官方 release 页为准：

- Collector 发行版：https://github.com/open-telemetry/opentelemetry-collector-releases
- Collector contrib 组件：https://github.com/open-telemetry/opentelemetry-collector-contrib
- Operator：https://github.com/open-telemetry/opentelemetry-operator

## 4. OTLP：一条线协议统一所有信号

OTLP（OpenTelemetry Protocol）是 OTel 规范定义的传输协议，基于 protobuf 编码，三种信号用同一套端点体系：

| 传输 | 默认端口 | 路径（HTTP） | 特点 |
|---|---|---|---|
| OTLP over gRPC | 4317 | — | 长连接、流式、支持双向；K8s 内常用 |
| OTLP over HTTP | 4318 | `/v1/traces`、`/v1/metrics`、`/v1/logs` | 简单、穿透性好（走普通 HTTP/1.1 或 HTTP/2），支持 gzip |

几个运维视角的要点：

- 4317/4318 是规范约定的**默认端口**，Collector 的 OTLP receiver 开箱即监听这两个端口，看到 4317 基本可以条件反射地想到 OTLP；
- HTTP 载体是 protobuf 二进制（`Content-Type: application/x-protobuf`），也接受 JSON（`application/json`），排查时可以用 curl 直接构造请求；
- 请求幂等性没有保证，重试可能造成重复数据，后端要能去重（Jaeger/Tempo/Loki 均可处理）；
- 应用侧只需要配一个 `OTEL_EXPORTER_OTLP_ENDPOINT`，这就是"换后端不动代码"的落点。

## 5. 生态位：一张图看懂数据流向

```
┌─────────────┐   ┌─────────────┐   ┌─────────────┐
│  应用 Pod A  │   │  应用 Pod B  │   │  VM 上服务 C │    代码内 SDK / 运行时注入 agent
│  Go + SDK   │   │ Java + agent│   │ Python SDK  │
└──────┬──────┘   └──────┬──────┘   └──────┬──────┘
       │                 │       OTLP            │
       │        gRPC 4317 / HTTP 4318           │
       └─────────────────┼──────────────────────┘
                         ▼
          ┌───────────────────────────────┐
          │   OpenTelemetry Collector     │   处理层：富化 k8s 元数据 / 采样 /
          │   （节点 agent 或中心 gateway）│   脱敏 / 批量 / 路由分发
          └───┬────────┬────────┬────┬───┘
              │        │        │    │
      OTLP    │        │pull/   │    │ OTLP / 私有协议
      ▼        ▼        ▼推送    ▼    ▼
  ┌───────┐ ┌──────────┐ ┌─────┐ ┌──────────────┐
  │Jaeger │ │Prometheus│ │Loki │ │ 云厂商/商业后端 │
  │/Tempo │ │(指标存储) │ │(日志)│ │ (native OTLP) │
  └───┬───┘ └────┬─────┘ └──┬──┘ └──────────────┘
      └──────────┴──────────┘
                  ▼
            Grafana（统一可视化，用 trace_id 串三信号）
```

这张图是整个模块的"地图"，后面五章都在放大它的某一段：

- 第 1 章放大"应用内部"：信号的数据模型和跨服务传播；
- 第 2 章放大"SDK/agent"：怎么埋点、怎么采样；
- 第 3 章放大"Collector"：内部结构、部署模式、对接后端；
- 第 4 章把整张图搬进 Kubernetes（Operator 化）；
- 第 5 章用官方 Astronomy Shop Demo 把全图跑起来做故障演练。

## 6. 与既有生态的桥接关系

你已经有 PCA 的技术底子，逐个对齐：

| 组件 | 与 OTel 的关系 | 接入方式 |
|---|---|---|
| Prometheus | 互补而非替代：Prometheus 仍是指标存储 + PromQL + 告警的事实标准 | 两条路：Collector 用 `prometheus` exporter 暴露 `/metrics`(默认 8889) 让 Prometheus 拉；或用 `prometheusremotewrite` exporter 推到 remote write 端点。详见第 3 章 |
| Jaeger | tracing 后端；较新版本原生接收 OTLP（4317/4318 直接当 collector 用） | Collector 的 `otlp` exporter 直连 Jaeger 4317 |
| Tempo | Grafana 系 tracing 后端，OTLP-first 设计 | 同上，天然对接 |
| Loki | 日志后端；3.x 起原生支持 OTLP intake（`/otlp/v1/logs`），以 Loki 官方文档为准 | Collector 的 `otlphttp` exporter 指到 Loki 3100 |
| Grafana | 统一可视化：metrics/traces/logs 三类数据源，用 trace_id 互相跳转 | 不直接对接 OTel，消费上面的后端 |
| Alertmanager / PromQL | 完全不变 | 指标进了 Prometheus 之后，PCA 技能原样可用 |

vendor 无关采集层的实际价值，翻译成运维语言：

1. **换后端只改 Collector 配置**：业务发布一次都不用发；
2. **一处埋点，多后端分发**：迁移期新旧后端并行收数据做对比验证；
3. **处理前移**：PII 脱敏、裁剪高基数属性、tail 采样，都在进后端之前完成，直接省存储成本；
4. **故障隔离**：后端宕机时 Collector 本地排队缓冲，业务进程的 exporter 队列不炸（应用侧仍然要防丢数据，见第 2、3 章）。

## 实战演练：10 分钟最小 OTLP 链路（Docker VM）

目标：在一台装有 Docker 的 Ubuntu 22.04/24.04 VM 上跑通 `应用(telemetrygen 模拟) → OTLP → Jaeger`，并看到 trace。镜像用 `latest`，动手时以官方 release 页为准。

1. 启动 Jaeger all-in-one（内置存储为内存，重启即清空，仅适合实验）：

```bash
# [任意节点]（带 Docker 的 Ubuntu VM）
docker run -d --name jaeger \
  -p 16686:16686 -p 4317:4317 -p 4318:4318 \
  -e COLLECTOR_OTLP_ENABLED=true \
  jaegertracing/all-in-one:latest
```

`-e COLLECTOR_OTLP_ENABLED=true` 在新版镜像中是默认开启的，写出来可以兼容旧版。

2. 用 `telemetrygen`（Collector 仓库自带的压测/冒烟工具）模拟一个应用向 4317 发 3 条 trace：

```bash
# [任意节点]
docker run --rm --network host \
  ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:latest \
  traces --otlp-insecure --otlp-endpoint localhost:4317 --traces 3
```

预期输出（数字以实际为准）：

```
2026-xx-xx ... info traces ...
3 traces were generated
```

3. 验证 Jaeger UI 已经收到数据：

```bash
# [任意节点]
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:16686/api/services
```

预期输出：`200`。浏览器打开 `http://<VM_IP>:16686`，Service 下拉框里选 `otel-otlp-trace-tester`（telemetrygen 使用的服务名，若不同则选列表里唯一新增的那个），点 Find Traces，能看到 3 条 trace，展开后是 span 树。

4. 实验完毕清理：

```bash
# [任意节点]
docker rm -f jaeger
```

这一步走通后，你已经验证了本模块最重要的两件事：OTLP 默认端口工作正常、Jaeger 原生吃 OTLP。第 3 章会把 Collector 插到这条链路中间。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| telemetrygen 报 connection refused | Jaeger 没起或端口没映射；gRPC 打到了 4318 | `docker ps` + `docker logs jaeger` 确认；gRPC 用 4317，HTTP 用 4318 |
| 4317 能通、4318 不通（或反过来） | 只映射了一个端口 | `-p 4317:4317 -p 4318:4318` 两个都要映射 |
| Jaeger UI 打不开 | VM 防火墙拦截 16686 | `sudo ufw status`，放行或用 SSH 隧道转发 |
| 认为"上了 OTel 就要扔掉 Prometheus" | 混淆采集层与存储层 | 指标照常进 Prometheus，PromQL/告警不动 |
| all-in-one 重启后 trace 全没了 | 内存存储是设计如此 | 实验可接受；生产用真实后端（见第 3、4 章） |

## 自测

1. OpenTracing 和 OpenCensus 各自的短板是什么，使得合并成为社区共识？

<details><summary>答案</summary>

OpenTracing 只定义了 API 规范，没有配套的采集/传输层与 metrics 能力，落地要自己拼；OpenCensus 功能全但由 Google 主导、社区参与感弱，且与 OpenTracing 的 API 不兼容。两套标准并存导致库作者、厂商、用户三边都要双份投入，于是 2019 年在 CNCF 主导下合并为 OpenTelemetry，兼顾"社区中立"与"端到端完整"。
</details>

2. 如果你的后端只支持 Zipkin 协议，OTel 体系还能用吗？改造点在哪一层？

<details><summary>答案</summary>

能用。应用侧继续输出 OTLP，由 Collector 的 `zipkin` exporter 做协议转换后推给 Zipkin。这正是"采集层 vendor 无关"的设计意图：协议转换是 Collector 的职责，不侵入应用代码。
</details>

3. `OTEL_EXPORTER_OTLP_ENDPOINT` 配成 `http://collector:4318` 和 `collector:4317`，区别是什么？

<details><summary>答案</summary>

端口对应传输协议：4317 是 OTLP over gRPC，4318 是 OTLP over HTTP（路径 `/v1/traces` 等）。endpoint 的写法也要配套——gRPC 通常写裸地址 `collector:4317`，HTTP 需要带 scheme（`http://collector:4318`）。SDK 与协议不匹配（比如对 4317 发 HTTP 请求）会得到连接层报错，这是最常见的配置失误之一。
</details>

4. 为什么说"OTel 不会取代 Prometheus"？从数据模型和查询语言两个角度回答。

<details><summary>答案</summary>

OTel 定位在遥测的产生与运输（SDK/OTLP/Collector），不提供长期存储与查询能力；Prometheus 的价值在指标存储、PromQL 分析与基于 PromQL 的告警体系。OTel metrics 通过 Collector 进 Prometheus 后，原有仪表盘、Recording Rule、Alertmanager 链路原样工作，两者是上下游关系而不是竞争关系。
</details>

5. 三大信号的成熟度差异，对你制定接入计划有什么影响？

<details><summary>答案</summary>

Traces 最成熟，自动埋点覆盖广，适合最先上；metrics 稳定且与 Prometheus 互转顺畅，可以渐进迁移采集路径；logs 的规范虽已 stable，但部分语言的日志桥接还在收敛，落地前要核对所选语言 SDK 的日志状态（以官方文档为准），必要时先用 Collector 的 filelog/receiver 路线兜底（见第 4 章）。
</details>

## 延伸阅读

- OTel 官方文档总入口：https://opentelemetry.io/docs/
- OTel 规范（含信号状态）：https://opentelemetry.io/docs/specs/otel/
- OTLP 协议规范：https://opentelemetry.io/docs/specs/otlp/
- Collector 发布页（版本以这里为准）：https://github.com/open-telemetry/opentelemetry-collector-releases
- telemetrygen 工具说明：https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/cmd/telemetrygen
- Jaeger 官方文档：https://www.jaegertracing.io/docs/
