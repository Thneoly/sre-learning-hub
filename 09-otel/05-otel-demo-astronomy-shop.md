# 05 · Astronomy Shop：OpenTelemetry Demo 实战

> 模块：OpenTelemetry（06）｜ 建议时长：3 小时 ｜ 前置：01~04 章 ｜ 关联实验环境：kubeadm 单 master 集群（16 GB 内存为宜），或装有 Docker 的 Ubuntu VM

## 学习目标

- 能说出 OpenTelemetry Demo（Astronomy Shop）的组成：约 20 个多语言微服务、自带观测后端与特性开关
- 能操作：用 Helm 把 demo 部署到练习集群，资源紧张时做合理精简
- 能操作：在 Grafana 里沿一条 trace 贯穿多个服务，读懂瀑布图、span 属性与日志关联
- 能演练：注入故障后按"指标定层 → trace 定点 → 日志定因"的方法论从 trace 定位根因，并与本仓库 `scripts/faults` 靶场联动

## 1. Demo 是什么：一个"活的"可观测教材

前四章的组件各自为零散示例；OpenTelemetry Demo（外号 Astronomy Shop，天文电商）是官方维护的参考应用，把整本书装进一个集群：

- 一个在线天文望远镜商店的完整业务流：浏览目录、推荐、购物车、下单结算、支付、发货、报价；
- **约 20 个 polyglot 微服务**，语言刻意混用（完整服务表以官方 README 为准，新增服务会调整）：

| 服务 | 语言 | 职责 |
|---|---|---|
| frontend | Go | Web 入口 BFF，串起各下游 |
| frontend-proxy | Envoy(C++) | 统一入口/路由 |
| ad-service | Java | 广告推荐 |
| cart-service | C++ | 购物车（Valkey 存储） |
| checkout-service | Go | 结算编排，调用支付/购物车/汇率/库存等 |
| currency-service | C++ | 汇率换算 |
| email-service | C++ | 发确认邮件 |
| payment-service | TypeScript(Node.js) | 支付 |
| product-catalog-service | Go | 商品目录 |
| quote-service | PHP | 运费报价 |
| recommendation-service | Python | 推荐 |
| shipping-service | Rust | 物流时效 |
| accounting-service / fraud-detection-service | PHP / Kotlin | 消费 Kafka 的异步账务与风控 |
| flagd | Go | 特性开关中心 |
| image-provider | Go | 图片服务 |
| load-generator | Python(Locust) | 持续制造流量 |
| otel-collector / Jaeger / Prometheus / Grafana / OpenSearch | — | 自带的观测全家桶 |

- **特性开关**：由 flagd 集中管理（如 recommendation 缓存开关、checkout 走 Kafka 异步的开关等，名称以官方 README 的 feature flags 小节为准），运行中可切换行为，是天然的"受控实验"入口；
- **全链路埋点开箱即用**：每个服务都带 SDK，collector 的配置就是一份生产级参考（分层、采样、多后端分发）。

对你的价值：它是一个"怎么打都坏不了、坏了能看"的靶场——这正是把前四章知识变成排障手感的地方。

## 2. 资源要求与精简策略

全量 demo 含 OpenSearch（日志后端）、Prometheus、Jaeger、Grafana 与十几个业务服务，内存大头在 OpenSearch、recommendation(Java 系)与 ad(Java)。经验值（以官方 README 当前建议为准）：

| 档位 | 内存 | 做法 | 代价 |
|---|---|---|---|
| 全量 | ≥ 12 GB 空闲 | 默认 values | 无，日志关联演示完整 |
| 精简 | 6~8 GB | 关闭 flagd-ui、OpenSearch，压低 load-generator 与 collector 的资源 | logs 面板无数据（第 1、5 节的日志关联演示受限） |

练习集群是单 master kubeadm，还要注意两件事：

1. master 默认带 `node-role.kubernetes.io/control-plane:NoSchedule` taint，demo 的 Pod 会全体 Pending——实验期间临时去掉 taint 最简单；
2. 精简 values 的键位结构（`components.<name>.enabled` 与 `components.<name>.resources`）以所装 chart 版本的 values.yaml 为准。

```yaml
# [master] 保存为 values-trimmed.yaml,资源紧张时随 helm install -f 传入
components:
  flagd-ui:
    enabled: false        # 特性开关管理 UI,演示期可关
  opensearch:
    enabled: false        # 最省内存的一刀;代价是 logs 相关面板/关联失效
  load-generator:
    enabled: true
    resources:
      limits:
        memory: 512Mi
  otel-collector:
    resources:
      limits:
        memory: 1Gi
```

## 实战演练一：把 demo 跑起来

1. （单 master 集群）临时移除 taint，让工作负载能调度上去：

```bash
# [master]
MASTER=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl taint node ${MASTER} node-role.kubernetes.io/control-plane:NoSchedule-
```

预期输出：`node/${MASTER} untainted`。练完记得恢复（见本章末尾清理）。

2. 安装（需要集群里有 Helm；没有就先 `sudo snap install helm --classic` 或按官方脚本安装）：

```bash
# [master]
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
helm install my-otel-demo open-telemetry/opentelemetry-demo \
  -n otel-demo --create-namespace \
  -f values-trimmed.yaml
```

3. 等待就绪（首次拉镜像较慢，视网络 5~15 分钟）：

```bash
# [master]
kubectl -n otel-demo get pods
```

预期：所有 Pod 陆续 `Running 2/2`（许多服务带 flagd sidecar，所以是两个容器）。load-generator Running 说明压测流量已开始。

4. 打开 Grafana：

```bash
# [master]
kubectl -n otel-demo port-forward svc/my-otel-demo-grafana 3000:80
```

浏览器（本地 Windows）访问 `http://localhost:3000`（如提示登录，默认 `admin/admin`，以 chart values 为准）。Dashboards 里有一组预置面板（服务 RED 指标、Collector 流量等），先花两分钟扫一遍：这就是"全集群默认可观测"的样子。

## 实战演练二：看一条 trace 贯穿多个服务

1. 制造一次下单（load-generator 已经在持续打流量；也可以从浏览器 `port-forward svc/my-otel-demo-frontend-proxy 8080:8080` 手动逛店下单）。

2. Grafana → Explore → 选择 Jaeger 数据源 → Service Name 选 `frontend` → Find Traces，随便点开一条 `/api/cart` 或 `/checkout` 的 trace。

3. 读瀑布图（对照第 1 章的数据模型）：

```
frontend-proxy  ─███████████████████████████████████████   (SERVER, Envoy 入口)
 frontend         ─█████████████████████████████████      (SERVER, Go)
  frontend          ─█████████████ (CLIENT → currency)
  currency             ─█████████                        (SERVER, C++)
  frontend          ─██████████████ (CLIENT → product-catalog)
  product-catalog     ─█████████                         (SERVER, Go)
  frontend          ─███████████████ (CLIENT → cart)
  cart                 ─████████                        (SERVER, C++)
  checkout           ─███████████████████████            (SERVER, Go, 编排)
   checkout            ─█████ (CLIENT → payment)
   payment               ████                            (SERVER, TS)
   checkout            ─█████ (CLIENT → kafka:orders)    (PRODUCER, 到此为止)
```

4. 逐层下钻做三个动作：

- 点开最深的某个 span，看 Attributes：`http.response.status_code`、`db.query.text`、`k8s.*`（collector 富化）；
- 点 span 上的 Logs 标签（需要日志后端在线）：同 trace_id 的日志行直接挂上来——三信号闭环（第 1 章第 5 节）；
- 回到 Explore 换 Service Graph 面板：请求量/错误率画在服务拓扑边上，"哪个方向红"一眼可见。

5. 认识一个"正常的设计性断链"：开启 checkout 异步开关（flagd）后，trace 的同步段到 `kafka:orders` 的 PRODUCER span 为止；accounting/fraud-detection 从 Kafka 消费的那段是另一条 trace，通过 trace_id/links 关联而非父子——这是第 1 章 PRODUCER/CONSUMER 语义的真实样本。

## 实战演练三：故障注入与"从 trace 定位根因"

方法论（先把套路背下来，再动手）：

```
 ①指标定层   RED 指标看哪个服务红了(错误率/延迟突变)      ← Grafana/PromQL
 ②trace 定点  拉该服务的错误/慢 trace,找最深异常 span      ← Jaeger 瀑布图
 ③属性定因   span attributes 看状态码/异常/SQL/目标地址     ← span 详情
 ④日志定据   按 trace_id 查日志,拿到进程内证据             ← 日志关联
⑤K8s 验证   describe/get/events 确认基础设施层事实         ← kubectl
 ⑥修复回归   恢复后看指标回落、trace 变绿                  ← 回到 ①
```

### 场景 A：依赖消失（应用层根因）

```bash
# [master] 注入:把汇率服务缩为 0
kubectl -n otel-demo scale deploy/my-otel-demo-currency --replicas=0
```

一两分钟后观察：

```promql
# [本地Windows] Grafana Explore(Prometheus 数据源):按服务看 5xx 速率
sum by (service_name) (
  rate(http_server_request_duration_seconds_count{http_response_status_code=~"5.."}[2m])
)
```

（demo 的指标经 OTel 进 Prometheus，命名如 `http_server_request_duration_seconds_*`、标签如 `service_name`/`http_response_status_code`；若名字对不上，先在 Explore 的 metric browser 里搜 `http_server` 前缀确认。）

预期：`frontend`、`checkout` 出现 5xx 尖峰。切到 Jaeger 找一条红 trace：checkout 对 currency 的 CLIENT span 是 ERROR（connect refused），于是 checkout 自己的 SERVER span 置 Error、向上传染到 frontend。用第 4 步（`kubectl -n otel-demo get deploy | grep currency` 看到 0/0）确认根因，然后恢复：

```bash
# [master]
kubectl -n otel-demo scale deploy/my-otel-demo-currency --replicas=1
```

### 场景 B：资源饥饿（"没有报错的慢"）

```bash
# [master] 注入:把推荐服务 CPU 限到 10m(约 1% 核),触发 CPU 限流
kubectl -n otel-demo set resources deploy/my-otel-demo-recommendation \
  --limits=cpu=10m,memory=256Mi
```

预期现象：没有任何 error span，但含 recommendation 的 trace 里该 span 时长持续飙高（限流是"变慢"不是"报错"），frontend P95 抬升：

```promql
# [本地Windows] frontend 延迟 P95
histogram_quantile(0.95,
  sum by (le) (
    rate(http_server_request_duration_seconds_bucket{service_name="frontend"}[5m])
  )
)
```

这类"安静的退化"最能体现 tracing 的价值：指标只告诉你 frontend 慢，瀑布图直接指认 recommendation。恢复：

```bash
# [master]
kubectl -n otel-demo set resources deploy/my-otel-demo-recommendation \
  --limits=cpu=500m,memory=256Mi
```

### 场景 C：基础设施故障（呼应 scripts/faults 靶场）

本仓库 `scripts/faults/` 是集群层靶场（coredns、kubelet、CNI、endpoints 等）。demo 稳定运行后，挑网络/DNS 类脚本注入，练习"从 trace 反推基础设施层故障"：

```bash
# [master] 例子:DNS 配置类故障(动手前先读该目录 README 与 FIXES.md,确认恢复步骤)
bash scripts/faults/break-dns-config.sh
```

观察要点：trace 中 CLIENT span 的错误形态会从 `connection refused`（对端进程不在）变成 `no such host`/`i/o timeout`（名字解析/网络层故障）——错误信息所在的**最深 span + 错误类型**就是故障所在层的指纹。练完按 `scripts/faults/FIXES.md` 恢复，并回到 Grafana 确认恢复。

形态速查表：

| 注入 | trace 上的典型形态 | 指向 |
|---|---|---|
| 服务缩容 | CLIENT span ERROR：connection refused | 应用层，对端无进程 |
| CPU 限额 | 无错误、单 span 时长持续走高 | 应用层，资源限流 |
| DNS 故障 | CLIENT span ERROR：no such host / resolution failure | 集群 DNS（coredns） |
| endpoints 清空 | CLIENT span ERROR：connection refused/no endpoints | Service/endpoints |
| CNI/转发故障 | timeout 类错误、跨节点路径整体失败 | 网络/CNI |

### 清理

```bash
# [master]
helm -n otel-demo uninstall my-otel-demo
kubectl delete namespace otel-demo
MASTER=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl taint node ${MASTER} node-role.kubernetes.io/control-plane:NoSchedule:NoSchedule
```

最后一条把 taint 加回去，恢复练习集群原状。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 大批 Pod Pending | master taint 未移除或内存不足 | 本章演练一步骤 1；或换精简 values |
| OpenSearch/collector OOMKilled | 资源档位不够 | 用 values-trimmed.yaml 关闭 opensearch、压资源 |
| ImagePullBackOff | 部分镜像仓库需要外网 | 配镜像加速/代理后 `kubectl -n otel-demo rollout restart deploy` |
| Grafana 3000 打不开 | port-forward 断开或被占用 | 重新执行 port-forward；确认命令仍在前台运行 |
| trace 到 kafka 就"断" | 异步段本来就是独立 trace，靠 links/trace_id 关联 | 见演练二第 5 步，这是设计而非故障 |
| 日志标签页空 | 精简模式关了 OpenSearch | 要练日志关联就恢复全量；或按第 3 章把 logs 发给外部 Loki |
| PromQL 查无此序列 | 指标名/标签与示例不一致（semconv 版本演进） | 在 metric browser 里搜前缀确认实际名称再写查询 |
| load-generator 停了 | 压测任务按配置结束 | `kubectl -n otel-demo rollout restart deploy/my-otel-demo-load-generator` 重新制造流量 |

## 自测

1. 场景 A 里为什么 cart 相关 span 正常、currency 相关 span 报错？从 trace 树的因果结构解释。

<details><summary>答案</summary>

trace 树是调用的因果树：checkout 并行调用 currency、cart、payment 等下游，currency 缩容只切断"checkout→currency"这个子树，该分支的 CLIENT span 记录 connect refused 并置 Error，错误沿 checkout→frontend 向上传播；cart 子树与故障无因果关系，故正常。瀑布图的这种"局部坏、整体从坏点向上染色"正是根因定位的依据：最深的异常 span 就是故障点。
</details>

2. 场景 B 里 Prometheus 只看到"frontend 变慢"，为什么 trace 能直接指认 recommendation？

<details><summary>答案</summary>

指标是按服务聚合的维度数据，frontend 的延迟直方图里混入了所有下游的耗时贡献，无法归因；trace 保留了单次请求的完整调用树与每段耗时，recommendation span 在瀑布图中明显变长，归因是结构自带的。这正是"指标定层、trace 定点"分工的原因——也解释了为什么两者要一起上（指标便宜连续，trace 贵但可归因）。
</details>

3. 要演练"从 exemplar 跳 trace"和"trace 关联日志"，分别需要什么前提？

<details><summary>答案</summary>

exemplar 跳 trace 需要：histogram 指标带 exemplar（SDK/collector 链路开启）、Prometheus 存储 exemplar、Grafana 数据源开启 exemplar 支持。trace 关联日志需要：应用日志接入 OTel（带 TraceId/SpanId）、日志后端在线（demo 里是 OpenSearch，精简模式关掉了它）、Grafana 配好 trace→logs 的关联规则（按 trace_id 查询）。前者是 metrics→traces，后者是 traces→logs，两段拼起来才是三信号闭环。
</details>

4. 精简掉 OpenSearch 后，collector 的 logs pipeline 会出现什么行为？这会污染什么？

<details><summary>答案</summary>

collector 的日志 exporter 对着不存在的后端持续重试并记录错误（sending_queue 缓冲→满→丢弃），日志面板与 trace 的日志标签页无数据。污染的是 collector 自身日志与自我指标（export 失败计数上涨），traces/metrics 管道不受影响——因为三种信号是独立 pipeline（第 3 章）。生产上应同步关闭对应管道或重定向到其他后端，而不是留一个必然失败的 exporter。
</details>

5. 如何用这个 demo 验证第 2 章的采样结论（parentbased 一致性）？

<details><summary>答案</summary>

demo 流量由 load-generator 持续产生，观察窗口足够长。可通过 chart values 覆盖某服务的 `OTEL_TRACES_SAMPLER=parentbased_traceidratio` 与较小的 ARG（键位以 chart values 为准），等新配置随 Pod 生效后在 Jaeger 里统计：新 trace 要么整条（frontend 到最深的异步边界）都在，要么整条不在，不会出现"前半截在、某个下游缺失"的碎片——如果出现，说明该服务没有跟随父决策，正是第 2 章讲的一致性破坏。
</details>

## 延伸阅读

- Demo 官方文档（服务表、feature flags、运行方式）：https://opentelemetry.io/docs/demo/
- Demo 源码仓库：https://github.com/open-telemetry/opentelemetry-demo
- Demo Helm chart：https://github.com/open-telemetry/opentelemetry-helm-charts
- flagd（特性开关）：https://flagd.dev/
- 本仓库故障靶场说明：`scripts/faults/README.md` 与 `scripts/faults/FIXES.md`（随仓库分发）
