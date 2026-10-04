---
title_juejin: '采样采错地方，trace 全断链：OTel 尾部采样的代价账'
title_zhihu: '采样采在哪，决定 trace 是断链还是全链：head 与 tail 的代价账'
description: '独立head采样必断链；tail采样等span齐再判，内存与宕机窗口是代价；agent近源富化、gateway全局采样；memory_limiter永远第一；refused与dropped分清。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686472562230312970"
---

# 采样采错地方，trace 全断链：OTel 尾部采样的代价账

上周四 14:23，支付回调失败率冲到 3%。你从错误日志里抄下一条 trace_id，打开 Jaeger 一搜——空白。换一条，还是空白。（构造典型案例，下同）

复盘翻到两周前的变更：为了省存储，四个服务的 SDK 各配了 10% 采样。事故链路一条都没留下。这篇把这笔账从头算清：head 采样为什么断链，tail 采样要付什么代价，processors 顺序错在哪，以及出口的队列与背压怎么兜底。

## 一、head 采样：独立掷骰子必断链

head 采样在 span 诞生那一刻做决定。SDK 在应用进程里掷骰子，10% 保留、90% 当场丢弃——被丢的 span 根本不离开进程。这是它便宜的原因：网络、CPU、存储在源头就省了，Collector 什么都看不见。

坑在「各自掷骰子」四个字。四个服务各自独立采 10%，一条贯穿四跳的 trace 完整到达后端的概率是 0.1 的四次方——万分之一。后端里不是「少了点数据」，而是躺满断链碎片：只有入口的、只有中段的，每段都引向一个搜不到的父 span 或子 span，就是连不成链。

修法是 ParentBased【从业者判断】：只有链路入口掷一次骰子，结果写进 trace 上下文（traceparent 头）随请求传递；下游服务读到 sampled 标志就跟随，不再自己掷。

链不断了，但决定权还留在第一跳——入口采 1%，意味着 99% 的错误 trace 从未存在过。不是丢了，是从没被记录过，日志里有 trace_id 也无处可搜。

**独立采样断链，父子采样瞎丢——head 采样的两难躲不掉。** 它丢的是「还不知道有没有用」的数据，且不可撤销。

## 二、tail 采样：决定后移，代价是等和存

想把「保链」和「保错误」同时要到手，只能把决定往后挪：等 trace 的 span 到齐了再判。这就是 tail sampling——Collector 把同一条 trace 的所有 span 攒在内存里，等齐（或等到超时）再整体决定去留：错误的整条留，正常的整条抽。

两笔代价，都实打实。

代价一：内存。未决 trace 全部挂在 Collector 进程内存里，挂多少条、每条多少 span，直接决定 gateway 的内存水位；吞吐翻倍，这个缓存近似翻倍【从业者判断】。

代价二：宕机丢失窗口。从 span 到达、到判完发出，这整段窗口里数据只活在内存里——Collector 一挂，窗口内所有未决 trace 全部蒸发。

注意这与 head 采样不同：head 丢的是「没进门的数据」，tail 丢的是「已经收下、正在打算盘的数据」。exporter 的 sending_queue 只能缓冲「判完待发」的，缓冲不了「还没判」的。

**tail 采样用内存和宕机风险，换错误 100% 在场。**

## 三、agent 与 gateway：谁近源，谁全局

tail 采样还有第三个约束：必须挂在能看到全量 span 的位置。这让部署形态从「随便选」变成「算位置」。

K8s 里规模上来了就是分层：应用 → 节点 agent（DaemonSet）→ 中心 gateway → 后端们。agent 干贴身的活（k8s 元数据富化、快速截断），gateway 干需要全貌的活（tail 采样、路由、限流）。

为什么 agent 上不能做 tail 采样：跨节点的 trace，一半 span 在节点 A 的 agent 内存里，另一半在节点 B，谁都只见半条链，谁都做不了整条决定。例外只有「全链路都在单节点」的旧应用。

| 模式 | 实例数 | 优点 | 代价 | 定位 |
| --- | --- | --- | --- | --- |
| sidecar | 每 Pod 一个 | 同生命周期、强隔离、按应用配策略 | 资源 × Pod 数、运维面大 | 多租户、Serverless |
| 节点 agent | 每节点一个 | 省资源、能采节点面数据 | 单点=整节点、升级影响全节点 | 近源富化 |
| 中心 gateway | 少量、可扩缩 | 统一策略、多后端收敛点 | 跨可用区流量、要做高可用与容量规划 | 全局采样 |

两层策略必须一起设计：gateway 做 tail 采样，SDK 侧就得高比例甚至全量 head 上报——span 在 SDK 门口被丢，gateway 就没得判。这句反过来就是账单：tail 采样的隐性成本，含着一份「全量上报」的网络流量。

**采样点选在哪层，等于决定谁能看到多大的链路全貌。**

## 四、processors 顺序：数组顺序就是执行顺序

Collector 的 processors 数组顺序就是执行顺序，顺序错了语义就错。traces 管道里三个经典坑：

memory_limiter 永远第一。它的语义是「在入口评估内存、拒收新数据」；若排在 batch 之后，数据已被 batch 持有，限流器看到的全是「已进来」的，闸门形同虚设，OOM 保护失效。

k8sattributes 排在 tail_sampling 之前【从业者判断】。采样策略常按属性过滤——比如生产 namespace 全保、某个服务 100%。富化排在采样后，策略读到的属性是空的，静默地一条都匹配不上：不报错，只是采样行为和你以为的完全不同。

batch 排在采样之后、管道末端。先采样再批量，批的是减量后的数据；batch 天生合并「即将导出」的数据，靠近末端。代价是至多 timeout 的延迟（默认 200ms，常配到 5s）。

```yaml
# [中心 gateway] 顺序即语义：processors 与 traces pipeline（receiver 与 exporter 定义见第六节，拼起来才是可跑配置）
processors:
  memory_limiter:
    check_interval: 1s
    limit_mib: 512           # 软上限，约为容器 memory limit 的 75%
    spike_limit_mib: 128     # 突发缓冲，硬上限 = limit + spike
  k8sattributes:
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.pod.name
        - k8s.deployment.name
  tail_sampling:
    decision_wait: 15s       # 等 span 到齐的窗口
    num_traces: 100000       # 内存里同时挂着的未决 trace 上限
    policies:
      - name: errors         # 错误 trace 100% 保留
        type: status_code
        status_code: {status_codes: [ERROR]}
      - name: slow           # 慢请求 100% 保留
        type: latency
        latency: {threshold_ms: 800}
      - name: baseline       # 正常流量 5% 兜底
        type: probabilistic
        probabilistic: {sampling_percentage: 5}
  batch:
    timeout: 5s
    send_batch_size: 1024

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, k8sattributes, tail_sampling, batch]
      exporters: [otlp/jaeger]
```

（tail_sampling 的字段名与默认值随版本演进，以所装版本文档为准【从业者判断】。）

**顺序口诀：限流在最前，富化在采样前，批量在最后。**

## 五、组合策略：错误全保，正常抽样

上面配置的灵魂是策略组合：策略之间是「或」的关系，任何一条命中，整条 trace 保留【从业者判断】。于是错误 trace 100% 在场，慢请求 100% 在场，正常流量按 5% 兜底——排障时错误不缺证据，容量上又不会被打爆。

这笔账要算两边。省下的：95% 正常 trace 的存储与后端计算。花掉的：全量 span 涌向 gateway 的网络、内存里挂着的未决 trace 缓存、gateway 宕机时的丢失窗口。组合策略不是免费午餐，是把成本从后端存储搬进了管道内存。

验证方式很直观，给管道注入一条错误 trace：

```bash
# [任意节点] 注入一条 status=ERROR 的 trace（OTLP/HTTP 可直接收 JSON）
curl -s -X POST http://localhost:4318/v1/traces \
  -H 'Content-Type: application/json' \
  -d '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"demo-api"}}]},"scopeSpans":[{"spans":[{"traceId":"5b8efff798038103d269b633813fc60c","spanId":"eee19b7ec3c1b174","name":"POST /callback","kind":2,"startTimeUnixNano":"1730000000000000000","endTimeUnixNano":"1730000000200000000","status":{"code":2,"message":"500"}}]}]}]}'
# 预期：返回 200 空响应。立刻去后端搜这个 traceId——搜不到，
# 它还压在 decision_wait 的等待窗口里；等 20 秒左右再搜
# （15s decision_wait + 至多 5s batch），100% 在场
```

「发完搜不到、等一会儿才出现」——这个延迟本身就是 tail 采样的工作证明。

## 六、出口三本账：sending_queue、retry、背压

采样解决「存多少」，出口配置解决「断不断」。「应用 → Collector」和「Collector → 后端」是两段独立缓冲：SDK 侧有自己的批量队列，Collector 侧靠 exporter 的 sending_queue。

```yaml
# [中心 gateway] exporter 级重试与排队
exporters:
  otlp/jaeger:
    endpoint: jaeger:4317
    tls:
      insecure: true
    sending_queue:
      enabled: true
      num_consumers: 4
      queue_size: 4096       # 后端不可用时的缓冲容量
    retry_on_failure:
      enabled: true
      initial_interval: 1s
      max_interval: 30s
      max_elapsed_time: 120s # 重试超过 2 分钟则放弃（丢弃）
```

queue_size 不是拍脑袋：峰值吞吐 × 后端最长可预期故障时长 ÷ send_batch_size。按 2000 spans/s、后端可能抖 120 秒算：2000×120÷1024 ≈ 235 批，取 512 留余量；配方里的 4096 是高吞吐起步值，落地前按公式重算。锚点是实测吞吐——看按小时分位的峰值，不看均值，更不看感觉【从业者判断】。

背压是一条完整的减压链：后端变慢 → exporter 队列上涨 → memory_limiter 触到软上限熔断拒收 → 拒收沿管道反压回入口（refused 计数上涨，SDK 会重试）→ SDK 队列在应用进程里堆积 → 堆满后丢弃，老数据让位新数据。链条末端是业务进程的内存——Collector 过载，最终由应用买单。

三种「丢法」必须分清：refused 是入口拒绝，数据还在 SDK 队列里、会重试；dropped 是进了管道却被丢；send_failed 是重试用尽后丢弃。后两种是永久丢失。排查「后端少数据」，先看三个计数器谁在涨，再决定是扩 Collector 还是修后端。

还有一本重启账：sending_queue 默认在内存，Collector 重启即清零——连重启都不许丢的场景，把 sending_queue.storage 指到 file_storage extension，让队列落盘。

**queue 满了依然会丢；容量预算是给后端故障时长上保险。**

## 七、Collector 自己也要被监控

采集层自己瞎了，全集群的可观测性一起瞎。Collector 默认在 8888 端口暴露 otelcol_* 内部指标，指标名随版本演进，以自己 /metrics 端点的实际输出为准：

| 指标（示例名） | 回答的问题 |
| --- | --- |
| otelcol_receiver_refused_spans | 入口拒收量，非 0 = Collector 过载 |
| otelcol_processor_dropped_spans | 进了管道却被丢的量 |
| otelcol_exporter_queue_size / capacity | 发送队列水位，涨向 capacity 是「后端跟不上」最早信号 |
| otelcol_exporter_send_failed_spans | 重试后仍失败（出口方向丢失） |
| otelcol_process_memory_rss | 内存水位，对照容器 limit 与 limit_mib |

两条查询直接进大盘：

```promql
# 队列水位：持续大于 0.8 就是「即将丢数据」
otelcol_exporter_queue_size / otelcol_exporter_queue_capacity

# 入口拒收：非 0 说明 SDK 正在重试堆积，减压链已启动
otelcol_receiver_refused_spans
```

```bash
# [任意节点] 快速看一眼三种丢法谁在涨
curl -s http://localhost:8888/metrics | grep -E 'receiver_refused|processor_dropped|send_failed'
# 预期：过滤出各计数器的当前值；隔几秒抓两次对比，谁在涨，丢数据的位置就在哪一跳
```

一个反直觉告诫：别用「Collector 抓自己再转发」做主路径——后端故障时这条路跟着一起死，自我观测必须落在被观测对象之外。

**观测管道的第一课：先观测观测者。**

## 八、反方：不是所有链路都值得 tail 采样

拆台时间。

其一，tail 采样的前提是全量上报。低流量系统全量不采样，存储未必比「gateway 内存 + 高可用改造」贵【从业者判断】。

其二，decision_wait 既加排障延迟，又造丢失窗口。为了「错误全保」引入「gateway 一挂未决全丢」的新单点，在部分可用性要求下是负收益【从业者判断】。

其三，穷人的替代品存在：错误 100% 进日志、日志 100% 保留，trace 只负责还原细节现场——head 采 1% 也许就够，因为你手里已有 100% 的「错误发生记录」【从业者判断】。

**采样策略的正确问法：错误发生时，你手里有什么。**

## 现在就能做的三件事

第一，把那两条查询贴进 Prometheus，看队列水位与 refused 此刻是多少——多数人第一次看都会愣住【从业者判断】。

第二，翻开 Collector 配置检查 processors 数组：memory_limiter 是不是第一个？k8sattributes 是不是排在采样前？

第三，用公式算一遍 queue_size：峰值吞吐 × 后端最长可预期故障时长 ÷ batch size，对一下现值——差一个数量级的，今晚就改。

命令、配置与容量公式的底稿，都在我的学习仓库：GitHub 搜 sre-learning-hub，OTel 模块的 Collector 章节有完整可跑的配方。

评论区报个数：你现在 head 还是 tail？采样率多少？出过「日志里有 trace_id、后端里搜不到」的事故吗——那次最后背锅的是谁？
