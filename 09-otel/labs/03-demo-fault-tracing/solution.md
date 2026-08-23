# Lab 03 · 解答：Astronomy Shop 故障注入与根因定位

## 步骤 0：确认前置

```bash
# [master]
sudo snap install helm --classic 2>/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version --short      # 预期 v3.x
free -h                   # 建议空闲 >= 6GB
```

## 步骤 1：安装精简子集

完整 Astronomy Shop 有 20+ 组件。本 lab 裁掉与下单链路无关的 AI/统计类组件（accounting、fraud-detection、agent、chatbot、mcp、telemetry-docs、astronomy-db），保留完整业务链 frontend → checkout → cart → valkey-cart 与可观测性组件（collector/jaeger/prometheus/grafana/opensearch 用 chart 默认值全开，保证 collector 配置里的各个 exporter 都有对端，日志干净）。

两个关键事实（chart 的命名规则，后面所有命令都依赖它）：

- 组件开关在 values 的 `components.<name>.enabled`，组件名是 `frontend`、`cart`、`checkout`、`valkey-cart`、`load-generator` 这样的短名（不是 `adService`/`cartService` 驼峰名，那是 docker compose 老版本的叫法）；
- 生成的 Deployment/Service 名就是组件名本身，**不带 release 名前缀**（release 名 `astro` 只出现在 label 里）。

```bash
# [master]
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update

cat > reduced-values.yaml <<'EOF'
components:
  accounting:
    enabled: false
  agent:
    enabled: false
  chatbot:
    enabled: false
  fraud-detection:
    enabled: false
  mcp:
    enabled: false
  telemetry-docs:
    enabled: false
  astronomy-db:
    enabled: false
EOF

helm install astro open-telemetry/opentelemetry-demo \
  -n astro-demo --create-namespace -f reduced-values.yaml
```

> 注意：`reduced-values.yaml` 里的键名要与你实际用的 chart 版本一致。若 `helm install` 报 values schema 校验错误（说明你的 chart 版本没有某个组件），先 `helm show values open-telemetry/opentelemetry-demo | grep -E '^  [a-z-]+:'` 对照实际的组件名列表，把不存在的键删掉再装。
>
> 内存吃紧时可以进一步加 `grafana.enabled: false`、`prometheus.enabled: false`、`opensearch.enabled: false`（顶层键，不在 components 下）——代价是 collector/jaeger 会周期性地对这些后端重试报错，属预期，不影响本 lab 只看 trace。

等待就绪并确认名称（后续步骤以实际名称为准）：

```bash
# [master]
kubectl -n astro-demo get pods -w        # 全部 Running/Ready 后 Ctrl-C
kubectl -n astro-demo get deploy
```

预期看到 `frontend`、`frontend-proxy`、`cart`、`checkout`、`valkey-cart`、`load-generator`、`flagd` 等 Deployment（注意没有 `astro-` 前缀）。首次拉镜像约 3~5GB，耐心等待。

## 步骤 2：建立基线

先找到 Jaeger 的查询 Service（chart 用 `fullnameOverride: jaeger`，Service 名里含 jaeger，查询端口 16686）：

```bash
# [master]
JAEGER_SVC=$(kubectl -n astro-demo get svc -o custom-columns=NAME:.metadata.name,PORTS:.spec.ports[*].port | awk '/16686/ {print $1; exit}')
echo "$JAEGER_SVC"
kubectl -n astro-demo port-forward svc/"$JAEGER_SVC" 16686:16686
```

浏览器打开 `http://localhost:16686/jaeger/ui`（当前 chart 内置的是 Jaeger v2，UI 挂在 `/jaeger/ui` 路径下）：

- Service 下拉应出现 `frontend`、`cart`、`checkout` 等；
- 选 `frontend` → Find Traces，随便点开一条，瀑布图应包含 frontend → checkout → (cart / payment / email / product-catalog / currency ...) 的完整链路，全部绿色。

把这条正常 trace 的截图或服务列表记下来——排障时"和基线对比"是最快的差异发现法。

## 步骤 3：注入故障

先记录 cart 当前配置（养成习惯：改配置前先留底）：

```bash
# [master]
kubectl -n astro-demo get deploy cart -o yaml | grep -A1 'VALKEY_ADDR'
# 预期: - name: VALKEY_ADDR / value: valkey-cart:6379
```

把缓存地址改成一个不存在的 Service（DNS 解析失败 → Redis 客户端连接异常）：

```bash
# [master]
kubectl -n astro-demo set env deploy/cart VALKEY_ADDR=valkey-cart-missing:6379
kubectl -n astro-demo rollout status deploy/cart --timeout=180s
```

`kubectl set env` 会修改 Deployment pod template 并自动触发滚动更新——与 `scripts/faults/break-*.sh` 一样是"一次变更、一个变量"，破坏点清晰可控。

为什么改完之后 cart Pod 仍然是 Running/Ready？看 Deployment：

```bash
# [master]
kubectl -n astro-demo get deploy cart -o jsonpath='{.spec.template.spec.initContainers[0].command}'; echo
```

chart 给 cart 配了 init 容器 `wait-for-valkey-cart`，它探测的地址是**写死的** `valkey-cart 6379`（真实服务仍健康），而我们改的是主容器运行时才用的 `VALKEY_ADDR`。于是出现教科书式的"应用层故障"：进程活着、探针通过、但每次访问缓存都抛连接异常——这正是只有 trace 才能快速暴露的一类问题。

此刻运行检查脚本（在故障注入状态下）：

```bash
# [master]
chmod +x check.sh && ./check.sh
```

预期：

```
PASS: namespace astro-demo 存在
PASS: demo 子集 >= 8 个 Deployment 且全部 Ready（当前 20+ 个，未就绪: 无）
PASS: frontend 与 load-generator Deployment 就绪（frontend / load-generator）
PASS: Jaeger Service 存在（可用于 trace 查看）
PASS: 故障已注入：cart 的缓存地址指向 missing 主机（当前: VALKEY_ADDR=valkey-cart-missing:6379）

SCORE: 5/5
```

## 步骤 4：排障演练（对应 task.md 的思考题）

1. **缩小范围**：Jaeger UI 中 Service 选 `frontend`，时间窗 Recent 15 minutes，Find Traces。等待 1~2 分钟让 load-generator 打出流量后，会出现带红色 ERROR 标记的 trace。
2. **下钻**：点开一条 error trace。瀑布图中 frontend 的 span 报 5xx；展开 checkout → cart 链路，最深处 `cart` 的 span 状态为 ERROR。
3. **读证据**：点开该 span 的 Tags/Logs，可见名为 `exception` 的 event，`exception.type` 为 .NET Redis 客户端（StackExchange.Redis）的异常类，`exception.message` 是连接类错误（DNS 解析失败或 socket 连不上）。
4. **下结论**：cart 进程本身健康（Pod 仍 Running、无重启、init 探测通过），是它对缓存（valkey-cart）的连接配置错了。用 kubectl 交叉验证——配置层面能直接看到病根：

   ```bash
   # [master]
   kubectl -n astro-demo get deploy cart -o jsonpath='{range .spec.template.spec.containers[*]}{range .env[*]}{.name}={.value}{"\n"}{end}{end}' | grep ADDR
   kubectl -n astro-demo get pods -l app.kubernetes.io/component=cart -o wide   # 无 CrashLoop，证明不是进程问题
   ```

   注意第二条命令的 label 选择器若不匹配，用 `kubectl -n astro-demo get pods | grep cart` 即可。

排障路径总结（与 task.md 引导一致）：

```
服务级错误分布(frontend 5xx) → 下钻单条 trace → 最深异常 span(cart) → exception event → 配置核对(VALKEY_ADDR) → 修复
```

## 步骤 5：恢复并验证

```bash
# [master]
kubectl -n astro-demo set env deploy/cart VALKEY_ADDR=valkey-cart:6379   # 改回步骤 3 留底的原值
kubectl -n astro-demo rollout status deploy/cart --timeout=180s
```

等待 1~2 分钟（新流量进来），在 Jaeger 把时间窗收窄到 Recent 5 minutes 再查 `frontend`：新 trace 应不再有 ERROR，cart → valkey-cart 子链路恢复正常。如思考题 4 所说，旧 trace 在历史时间窗里仍会显示错误，这是正常的。

## 替代验证方式（Docker 单机，docker compose）

demo 仓库把 compose 文件做了分层：`compose.yaml` 是核心业务服务，`compose.observability.yaml` 提供 jaeger/grafana/prometheus 等。在装有 Docker 与 docker compose v2 的 Ubuntu VM 上：

```bash
# [装有Docker的Ubuntu VM]
git clone https://github.com/open-telemetry/opentelemetry-demo.git
cd opentelemetry-demo

# 核心业务 + 可观测性（jaeger 等）
docker compose -f compose.yaml -f compose.observability.yaml up -d
# 商城入口 http://localhost:8080 ，Jaeger UI http://localhost:8080/jaeger/ui

# 注入同类故障：用第三个 compose 文件覆盖 cart 的缓存地址
cat > compose.fault.yaml <<'EOF'
services:
  cart:
    environment:
      - VALKEY_ADDR=valkey-cart-missing:6379
EOF
docker compose -f compose.yaml -f compose.observability.yaml -f compose.fault.yaml up -d cart

# 交叉验证：cart 日志出现 Redis/valkey 连接异常
docker compose -f compose.yaml -f compose.observability.yaml logs cart | grep -i -m5 'exception\|redis\|valkey'

# 恢复：去掉 compose.fault.yaml 重建 cart
docker compose -f compose.yaml -f compose.observability.yaml up -d cart
```

compose 里 cart 的 `depends_on` 健康检查同样指向真实的 `valkey-cart`，所以容器能起来、运行时报错——与 K8s 版故障语义一致。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| `helm install` 报 values schema 错误 | chart 版本不同，`reduced-values.yaml` 里有该版本不存在的组件键 | `helm show values` 对照实际键名，删掉不存在的键 |
| Pod 大量 Pending | 节点内存不足 | `kubectl describe pod` 看 FailedScheduling；按步骤 1 的说明再关 grafana/prometheus/opensearch，或换大 VM |
| ImagePullBackOff | 节点访问不了 ghcr.io / 限流 | 提前 `docker pull` 或配镜像代理 |
| Jaeger 服务列表空 | load-generator 未启用或刚启动还没流量 | 确认 `load-generator` Deployment 在跑，等 1~2 分钟再查 |
| 注入故障后看不到错误 trace | rollout 未完成或 Jaeger 时间窗太窄 | `kubectl rollout status` 确认后，把时间窗放宽再逐步收窄 |
| Jaeger UI 打不开（404） | Jaeger v2 的 UI 挂在 `/jaeger/ui` 子路径 | 访问 `http://localhost:16686/jaeger/ui`，不要只开根路径 |
| collector 日志持续报 opensearch/prometheus 连接错误 | 裁剪了后端但 collector 默认配置仍引用它们 | 属预期重试噪声，不影响 trace；想干净就保留默认后端 |

## 清理（可选）

```bash
# [master]
helm uninstall astro -n astro-demo
kubectl delete ns astro-demo
```
