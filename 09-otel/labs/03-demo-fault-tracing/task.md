# Lab 03 · Astronomy Shop 故障注入与根因定位

> 难度：★★★ ｜ 考点：分布式 trace 排障（PCA instrumentation/tracing 主题综合演练）｜ 前置：Lab 01/02（理解 Collector 与 OTLP 链路）｜ 预计 60~90 分钟

## 前置条件与环境说明（本 lab 环境依赖重，务必先读）

- kubeadm 练习集群，master 节点建议 **>= 8GB 内存、4 核、40GB 磁盘**（精简子集实测约 4~5GB 内存；低于 6GB 空闲内存不建议上）。
- 节点能访问 `ghcr.io`、`registry.k8s.io`（demo 服务镜像与 jaeger）。
- master 上安装 helm 3：

  ```bash
  # [master]
  sudo snap install helm --classic 2>/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  helm version --short
  ```

- 部署前自查资源：

  ```bash
  # [master]
  free -h && df -h / && kubectl top nodes 2>/dev/null
  ```

- **环境不具备时的替代验证方式**：
  1. 只有装有 Docker 的 Ubuntu VM：用 demo 仓库分层 compose 文件起核心业务 + 可观测性（`compose.yaml` + `compose.observability.yaml`），再用一个额外的 `compose.fault.yaml` 把 cart 的 `VALKEY_ADDR` 改成不存在的主机注入同类故障，操作片段见 solution.md 末尾。
  2. 连 Docker 都没有：回到 Lab 02 环境，把 python-demo 的 `OTEL_EXPORTER_OTLP_ENDPOINT` patch 成错误地址，从 Jaeger 中服务断流的角度演练"可观测性排障"闭环。
- check.sh 设计为在**故障注入后**运行（第 5 项检查故障已生效）；完成恢复步骤后再跑第 5 项会 FAIL，属预期。

## 场景

周五下午，值班群截图：Astronomy Shop 商城页面加购物车偶发报错、下单失败。你打开 Jaeger，看到的是几百个服务各说各话的瀑布图。你的任务不是"重启大法"，而是走标准的 trace 排障路径：**先看服务级错误分布 → 再下钻单条 trace 找报错的 span → 最后用 span 上的 exception event 锁定根因**。这次故障的注入方式与 `scripts/faults/break-*.sh` 的思路一致——破坏一个真实依赖，让你用可观测性工具把它找出来（本 lab 是应用配置层故障：cart 服务连缓存的地址被改错了）。

```
frontend ──> checkout ──> cart ──X──> valkey(地址已被改错: valkey-cart-missing)
    |           |
    |           +──────> payment / email / ...
    +──> productcatalog / currency / recommendation ...
```

## 任务清单

1. 添加 open-telemetry helm 仓库，以 release 名 `astro` 安装 Astronomy Shop **精简子集**到 namespace `astro-demo`：用 values 文件关掉与下单链路无关的组件（accounting、fraud-detection、agent、chatbot、mcp、telemetry-docs、astronomy-db），保留 frontend/cart/checkout 等完整业务链与 valkey-cart、kafka、flagd、load-generator，可观测性组件（collector/jaeger 等）用 chart 默认值。注意 chart 生成的 Deployment/Service 名就是组件短名（`frontend`、`cart`、`valkey-cart`…），**不带 release 前缀**。等待全部 Pod Ready。
2. 建立基线：port-forward Jaeger 查询端口（16686，UI 在 `/jaeger/ui` 子路径），确认能查到 `frontend` 等服务的正常 trace，记录一条正常下单 trace 的样子（瀑布图里有哪些服务）。
3. 注入故障：把 cart Deployment 的 `VALKEY_ADDR` 改为 `valkey-cart-missing:6379`（`kubectl set env deploy/cart`），等待 rollout 完成。
4. 排障演练（先自己做，再展开"思考题"答案核对）：
   - 在 Jaeger 里用最小操作次数回答"哪个服务最先出错"；
   - 下钻一条 error trace，找到异常 span 并读出 exception 信息；
   - 说明根因和你修复它要改的那一行配置。
5. 恢复故障（把 `VALKEY_ADDR` 改回原值），验证错误消失、trace 恢复正常。
6. 注入故障状态下运行 `./check.sh`，输出 `SCORE: 5/5`。

## 验收标准

- `astro-demo` namespace 内业务 Deployment 全部 Ready（Ready 数与期望副本数一致）；
- Jaeger UI 能看到 `frontend`（组件名即服务名）的 trace；
- 故障期间：trace 中 cart 相关 span 出现 ERROR 状态和 exception event；
- 恢复后：新 trace 不再报错；
- 故障注入状态下 `./check.sh` 输出 `SCORE: 5/5`。

## 排查路径引导 + 思考题（先自己看 trace，再展开答案）

<details><summary>引导 1：Jaeger 里第一步看什么？别一上来就翻 trace</summary>

Jaeger 首页按 Service 列表 + Search 操作符（`Tags` 里可写 `error=true`）。第一步是缩小范围：选 `frontend`、时间窗拉到最近 15 分钟、Find Traces，看瀑布图里红色（ERROR）span 集中在哪个服务下面，而不是逐条翻。
</details>

<details><summary>思考题 1：为什么最先看到的报错多半在 frontend，但 frontend 不是根因？</summary>

frontend 是流量入口，所有下游错误都会在它的入站请求上表现为 HTTP 5xx / span ERROR——它是"受害者"（victim），不是"凶手"（culprit）。判别方法：沿瀑布图往下看第一个从"正常"变"异常"的服务边界。本例中 checkout 调用 cart 失败、cart 内部调用 valkey 抛异常，异常链的**最深一层**才是根因所在。
</details>

<details><summary>思考题 2：根因 span 长什么样？依据是什么？</summary>

cart 服务的 span 处于 ERROR 状态，且带有 exception event（event name 为 `exception`，attributes 含 `exception.type` / `exception.message`），典型消息是 Redis 客户端的连接类异常（如 "No connection is active/available..."，或 socket/DNS 层错误）。这类消息说明应用进程活着（不是 CrashLoop/OOM），是它**连不上下游**——结合 span 的 `service.name=cart` 与 network 对端信息，即可锁定"cart → 缓存"这条依赖。
</details>

<details><summary>思考题 3：修复要改哪一行？为什么不用重启 Pod、不用回滚镜像？</summary>

根因是 cart Deployment 的环境变量 `VALKEY_ADDR=valkey-cart-missing:6379` 指向了不存在的 Service（DNS NXDOMAIN）。把它改回 `valkey-cart:6379` 即可，`kubectl set env` 会自动触发滚动更新，不需要手动重启或回滚镜像——镜像从来没错过，错的是配置。这也是"配置即代码"的价值：变更范围一目了然。
</details>

<details><summary>思考题 4：为什么恢复后 Jaeger 里"错误还没消失"？</summary>

三个原因叠加：(1) 滚动更新 + 客户端连接池重建需要时间；(2) Jaeger 查询的是历史数据，时间窗内旧 trace 仍是错的；(3) 应用可能有本地重试/退避缓存。判断恢复要看**新产生**的 trace（把时间窗收窄到最近 1~2 分钟），而不是看总体错误率立刻归零。
</details>

<details><summary>思考题 5：如果 trace 断在 checkout、看不到 cart 以下的 span，说明什么？</summary>

说明插桩覆盖有缺口：checkout 调用 cart 的客户端库被插桩了（能发出对 cart 的子 span），但 cart 自身或其 Redis 客户端没有被插桩（链路在进程/库边界断裂）。分布式 tracing 只能显示"被观测到"的部分——这也是 OTel 强调 instrumentation 覆盖率和 context propagation 的原因。本 demo 各服务都内置 OTel 插桩，所以能看到完整链路。
</details>
