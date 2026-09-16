# Lab 01 · Solution：SLO Workshop

按 task.md 的顺序逐步讲解。每步都给出"做什么 + 为什么 + 验证输出"。所有命令都在 master 上、lab 目录 `~/labs/01-slo-workshop/` 内执行。

## Step 0 · 部署脚手架（task.md 已给全量清单）

```bash
# [master]
cd ~/labs/01-slo-workshop
kubectl apply -f app.yaml
kubectl apply -f load.yaml
kubectl -n slo-demo rollout status deploy/slo-demo --timeout=180s
# 预期：deployment "slo-demo" successfully rolled out

kubectl -n slo-demo get pods
# NAME                        READY   STATUS    RESTARTS   AGE
# load-gen-5d7c8b9f4-x7k2p    1/1     Running   0          30s
# slo-demo-7b9f6c8d5-abcde    1/1     Running   0          45s
# slo-demo-7b9f6c8d5-fghij    1/1     Running   0          45s
```

**为什么先做这步**：SLO 的分母是"真实流量"。先让 load-gen 持续打流量，后面所有 ratio 类 recording rule 才有数据，`/set` 注入的错误也才能立刻反映到燃烧率上。

验证采集链路（ServiceMonitor 生效约需 1~2 分钟）：

```bash
# [master]
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -s "http://${NODE_IP}:30900/api/v1/targets" | python3 -m json.tool | grep -B2 -A6 slo-demo | head -30
# 预期：activeTargets 里出现 job "slo-demo/slo-demo/0"，health "up"
```

浏览器打开 `http://<NODE_IP>:30900/query`，执行：

```promql
# [Prometheus UI]
sum(rate(demo_http_requests_total[2m]))
```

预期得到一个 >0 的数值（8 路并发 wget 在本机网络下大约几十到一百多 rps）。

## Step 1 · 写 slo-design.md：SLI/SLO 正式化

**做什么**：把"基本不出错"、"响应要快"翻译成两条可度量的约定，并算清 error budget 与燃烧率档位。

**为什么**：SLO 的价值在于把"好不好"变成一个可以报警、可以决策（要不要停发布）的数字。写下来的那一刻，值班标准才存在。

### 1.1 两条 SLO

| 维度 | SLI（好事件 / 总事件） | 目标 | 窗口 |
|---|---|---|---|
| 可用性 | 非 5xx 请求占比 | ≥ 99.9% | 30 天滚动 |
| 延迟 | 延迟 ≤ 200ms 的请求占比 | ≥ 99% | 30 天滚动 |

对应 PromQL（这是设计稿，真正生效的是 Step 2 的 recording rules）：

```promql
# [Prometheus UI] 可用性 SLI
1 - (
  sum(rate(demo_http_requests_total{code=~"5.."}[5m]))
  /
  clamp_min(sum(rate(demo_http_requests_total[5m])), 1e-10)
)

# [Prometheus UI] 延迟 SLI（好事件 = le="0.2" 桶）
sum(rate(demo_http_request_duration_seconds_bucket{le="0.2"}[5m]))
/
clamp_min(sum(rate(demo_http_request_duration_seconds_count[5m])), 1e-10)
```

`clamp_min(…, 1e-10)` 兜底分母为 0 的情况：无流量时比率算出 1（可用性）/0（延迟）之外的东西没有意义，宁可让它安静地保持 1。

### 1.2 error budget 换算

```
30 天 = 43 200 min
可用性目标 99.9%  → 预算 = 0.1% × 43 200 min = 43.2 min 全停等价时间
延迟目标 99%      → 预算 = 1%   × 30 d      = 7.2 h 内允许"慢于 200ms"
```

预算不是"配额"而是"风险储备"：预算还剩很多时可以激进发布，预算烧完就应冻结变更、优先修可靠性。

### 1.3 燃烧率（burn rate）与告警档位

```
burn rate = 实际错误率 / 允许错误率
            （例：可用性 SLO 允许 0.1%，实际错误率 2% → burn 20）
```

| 档位 | burn 阈值 | 预算耗尽时间（30 天窗口） | 窗口对 | 动作 |
|---|---|---|---|---|
| fast | 14.4 | 30d/14.4 ≈ 50h ≈ 2 天 | 1h + 5m | page |
| slow | 6 | 30d/6 = 5 天 | 6h + 30m | ticket |
| （参考） | 1 | 恰好用满 30 天 | — | 只做看板 |

多窗口的意义（Google SRE 工作簿 Workbook 第 5 章 Alerting on SLOs 的做法）：

```
        长窗口（1h）越限？ ──否──> 不触发（偶发抖动）
              │是
        短窗口（5m）也越限？ ──否──> 不触发（已恢复）
              │是
        for: 2m 仍越限 ──> firing，page
```

写好的 `slo-design.md` 应包含上表与两条 SLI 的 PromQL，约 30 行即可满足验收。

## Step 2 · 编写 slo-rules.yaml

**做什么**：一个 PrometheusRule CR，两组规则——`slo-demo.recording`（SLI 固化）与 `slo-demo.alerts`（燃烧率告警）。

**为什么用 recording rules**：SLI 表达式会在看板、告警、事后复盘中反复使用；固化成命名序列后，三处引用同一个名字，改 SLI 只改一处，也避免告警里的长表达式写错分母这类事故。

完整文件（可直接使用）：

```yaml
# [master] 保存为 ~/labs/01-slo-workshop/slo-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: slo-demo-slo
  namespace: monitoring
  labels:
    release: prom
spec:
  groups:
    - name: slo-demo.recording
      interval: 30s
      rules:
        # ---- 请求量与错误量（分子分母分开记录） ----
        - record: slo:slo_demo_requests:rate1m
          expr: sum(rate(demo_http_requests_total[1m]))
        - record: slo:slo_demo_requests:rate5m
          expr: sum(rate(demo_http_requests_total[5m]))
        - record: slo:slo_demo_requests:rate30m
          expr: sum(rate(demo_http_requests_total[30m]))
        - record: slo:slo_demo_requests:rate1h
          expr: sum(rate(demo_http_requests_total[1h]))
        - record: slo:slo_demo_requests:rate6h
          expr: sum(rate(demo_http_requests_total[6h]))
        - record: slo:slo_demo_errors:rate1m
          expr: sum(rate(demo_http_requests_total{code=~"5.."}[1m]))
        - record: slo:slo_demo_errors:rate5m
          expr: sum(rate(demo_http_requests_total{code=~"5.."}[5m]))
        - record: slo:slo_demo_errors:rate30m
          expr: sum(rate(demo_http_requests_total{code=~"5.."}[30m]))
        - record: slo:slo_demo_errors:rate1h
          expr: sum(rate(demo_http_requests_total{code=~"5.."}[1h]))
        - record: slo:slo_demo_errors:rate6h
          expr: sum(rate(demo_http_requests_total{code=~"5.."}[6h]))
        # ---- 可用性比率：目标 99.9% ----
        - record: slo:slo_demo_availability:ratio_rate1m
          expr: 1 - slo:slo_demo_errors:rate1m / clamp_min(slo:slo_demo_requests:rate1m, 1e-10)
        - record: slo:slo_demo_availability:ratio_rate5m
          expr: 1 - slo:slo_demo_errors:rate5m / clamp_min(slo:slo_demo_requests:rate5m, 1e-10)
        - record: slo:slo_demo_availability:ratio_rate30m
          expr: 1 - slo:slo_demo_errors:rate30m / clamp_min(slo:slo_demo_requests:rate30m, 1e-10)
        - record: slo:slo_demo_availability:ratio_rate1h
          expr: 1 - slo:slo_demo_errors:rate1h / clamp_min(slo:slo_demo_requests:rate1h, 1e-10)
        - record: slo:slo_demo_availability:ratio_rate6h
          expr: 1 - slo:slo_demo_errors:rate6h / clamp_min(slo:slo_demo_requests:rate6h, 1e-10)
        # ---- 延迟达标比率：目标 99%（≤ 200ms 视为好事件） ----
        - record: slo:slo_demo_latency_good:ratio_rate5m
          expr: sum(rate(demo_http_request_duration_seconds_bucket{le="0.2"}[5m])) / clamp_min(sum(rate(demo_http_request_duration_seconds_count[5m])), 1e-10)
        - record: slo:slo_demo_latency_good:ratio_rate1h
          expr: sum(rate(demo_http_request_duration_seconds_bucket{le="0.2"}[1h])) / clamp_min(sum(rate(demo_http_request_duration_seconds_count[1h])), 1e-10)
        # ---- 1 天窗口燃烧率（看板用；本栈 retention 只有 3d，不配 30d 窗口） ----
        - record: slo:slo_demo_burn:ratio1d
          expr: (sum(rate(demo_http_requests_total{code=~"5.."}[1d])) / clamp_min(sum(rate(demo_http_requests_total[1d])), 1e-10)) / 0.001
    - name: slo-demo.alerts
      rules:
        # ==== 生产档位：fast burn 14.4，1h + 5m 双窗口 ====
        - alert: SloDemoAvailabilityFastBurn
          expr: |
            (
              slo:slo_demo_availability:ratio_rate1h < 1 - (1 - 0.999) * 14.4
              and
              slo:slo_demo_availability:ratio_rate5m < 1 - (1 - 0.999) * 14.4
            )
          for: 2m
          labels:
            severity: page
            slo: slo-demo-availability
          annotations:
            summary: "slo-demo 可用性预算快速燃烧（14.4x，1h+5m）"
            description: "5m 可用性 {{ $value | humanizePercentage }} 的燃烧速度将在约 2 天内耗尽 30 天预算，需立即处理。"
        # ==== 生产档位：slow burn 6，6h + 30m 双窗口 ====
        - alert: SloDemoAvailabilitySlowBurn
          expr: |
            (
              slo:slo_demo_availability:ratio_rate6h < 1 - (1 - 0.999) * 6
              and
              slo:slo_demo_availability:ratio_rate30m < 1 - (1 - 0.999) * 6
            )
          for: 15m
          labels:
            severity: ticket
            slo: slo-demo-availability
          annotations:
            summary: "slo-demo 可用性预算慢性燃烧（6x，6h+30m）"
            description: "按当前速度约 5 天烧完预算，工作时间跟进即可。"
        # ==== 生产档位：延迟 fast burn 14.4 ====
        - alert: SloDemoLatencyFastBurn
          expr: |
            (
              slo:slo_demo_latency_good:ratio_rate1h < 1 - (1 - 0.99) * 14.4
              and
              slo:slo_demo_latency_good:ratio_rate5m < 1 - (1 - 0.99) * 14.4
            )
          for: 2m
          labels:
            severity: page
            slo: slo-demo-latency
          annotations:
            summary: "slo-demo 延迟预算快速燃烧（14.4x，1h+5m）"
            description: "慢于 200ms 的请求占比正以约 2 天耗尽预算的速度累积。"
        # ==== 演练专用：短窗口（1m+5m），仅为快速验证告警链路 ====
        # 生产环境请删掉本条：窗口太短会放大偶发抖动，失去多窗口过滤的意义
        - alert: SloDemoAvailabilityBurnLabFast
          expr: |
            (
              slo:slo_demo_availability:ratio_rate5m < 1 - (1 - 0.999) * 14.4
              and
              slo:slo_demo_availability:ratio_rate1m < 1 - (1 - 0.999) * 14.4
            )
          for: 1m
          labels:
            severity: warning
            slo: slo-demo-availability
            lab_only: "true"
          annotations:
            summary: "slo-demo 演练用短窗口燃烧告警 firing"
            description: "演练注入的错误已把 1m/5m 窗口可用性拉到阈值以下；生产请使用 FastBurn/SlowBurn 档位。"
```

要点说明：

- 命名遵循 Prometheus 社区惯例 `level:metric:operations`（如 `slo:slo_demo_availability:ratio_rate5m`），窗口作为后缀，一看就知道能不能跨窗口组合；
- 生产档位的 1h/6h 窗口需要历史数据填满才能体现真实燃烧率——这正是它们抗抖动的来源，也是它"慢"的原因；
- `SloDemoAvailabilityBurnLabFast` 的注释把删除义务写死在规则里，防止演练配置泄漏到生产。

## Step 3 · 应用与校验

**做什么**：apply 之后用 promtool 验语法、用 Prometheus API 验加载。

**为什么两道关**：promtool 只验语法（表达式能不能解析）；Prometheus `/api/v1/rules` 的 `health` 才证明规则真的在跑（比如 `for` 里的低级错误只有运行时才暴露）。

```bash
# [master]
kubectl apply -f slo-rules.yaml
# prometheusrule.monitoring.coreos.com/slo-demo-slo created
```

本机有 promtool 就直接校验；没有就把 spec 段剥出来，借 Prometheus Pod 里的 promtool：

```bash
# [master] 本机有 promtool 时
sed -n '/^  groups:/,$p' slo-rules.yaml | sed 's/^  //' > /tmp/slo-lab-rules.extract.yml
promtool check rules /tmp/slo-lab-rules.extract.yml
# Checking /tmp/slo-lab-rules.extract.yml
#   SUCCESS: 22 rules found

# [master] 本机没有 promtool 时（借 Pod 内二进制；只写 /tmp，不动集群配置）
# 注意：新版 prometheus 镜像是 distroless（无 sh/tar/curl），kubectl cp 进不去，
#       用 stdin 重定向喂给 /dev/stdin 才行：
PROM_POD=$(kubectl -n monitoring get pod -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}')
sed -n '/^  groups:/,$p' slo-rules.yaml | sed 's/^  //' > /tmp/slo-lab-rules.extract.yml
kubectl -n monitoring exec -i "$PROM_POD" -c prometheus -- promtool check rules /dev/stdin < /tmp/slo-lab-rules.extract.yml
#   SUCCESS: 22 rules found
```

（`sed -n '/^  groups:/,$p'` 依赖 `spec:` 的第一个子键是 `groups:`——上面的 YAML 正是这么排的。）

确认 Prometheus 已加载：

```bash
# [master]
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -s "http://${NODE_IP}:30900/api/v1/rules" | python3 -m json.tool | grep -E '"name"|"health"' | head
# "name": "slo-demo.recording"
# "health": "ok"
# "name": "slo-demo.alerts"
# "health": "ok"
```

## Step 4 · 查询 recording rules

**做什么**：在 UI 里用规则名查询，确认 SLI 有值。

```promql
# [Prometheus UI]
slo:slo_demo_availability:ratio_rate5m     # 预期 ≈ 1（当前无注入）
slo:slo_demo_latency_good:ratio_rate5m     # 预期 ≈ 1（本机网络下 P99 远小于 200ms）
slo:slo_demo_burn:ratio1d                  # 预期 ≈ 0
```

## Step 5 · 压测验证告警触发

**做什么**：注入 50% 错误率，观察演练告警 firing，再恢复观察 resolved。

**为什么**：没被验证过的告警等于不存在——这是 SRE 检修告警的基本纪律（对应 05-chaos-engineering 的思想：监控本身也是需要演练的系统）。

```bash
# [master] 记录注入时刻
date '+%F %T'; echo "inject fail_rate=0.5"

# 注入（deploy 后面跟 pod 名均可，kubectl 会选一个 Ready 副本）
kubectl -n slo-demo exec deploy/slo-demo -- python3 -c \
  "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8000/set?fail_rate=0.5&latency_ms=0').read().decode())"
# {"fail_rate": 0.5, "latency_ms": 0}
```

燃烧率的爬升路径（`exec deploy/` 只注入一个副本：聚合错误率 ≈25%，burn ≈ 250；若两个副本都注入则 burn ≈ 500）：

```
注入后时间   ratio_rate1m        ratio_rate5m        告警状态
 t+0s        ~1.0                ~1.0                inactive
 t+45s       ~0.75               ~0.93               inactive（5m 窗口还没"泡透"）
 t+90s       ~0.75               ~0.87               pending（两窗口均 < 0.9856）
 t+2m30s     ~0.75               ~0.80               firing（for: 1m 满足）
```

阈值核对：可用性比率的越限线是 `1-(1-0.999)*14.4 = 0.9856`，即可用性低于 98.56% 就算越限；注入 50% 错误后各窗口很快全部越限。

观察（两条路任选）：

```bash
# [master] API 方式
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
watch -n 10 "curl -s http://${NODE_IP}:30900/api/v1/alerts | python3 -c \"import json,sys; [print(a['labels']['alertname'], a['state']) for a in json.load(sys.stdin)['data']['alerts']]\""
# 预期约 2~3 分钟后出现：SloDemoAvailabilityBurnLabFast firing
```

浏览器路径：`http://<NODE_IP>:30900/alerts`，找 `slo-demo.alerts` 组，观察 `SloDemoAvailabilityBurnLabFast` 从 inactive → pending → firing。

把 firing 时刻记进 `slo-design.md`（例：`14:32:05 注入，14:34:40 firing，耗时 2m35s`），然后恢复：

```bash
# [master]
kubectl -n slo-demo exec deploy/slo-demo -- python3 -c \
  "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8000/set?fail_rate=0&latency_ms=0').read().decode())"
# {"fail_rate": 0.0, "latency_ms": 0}
```

约 5~6 分钟后（5m 窗口里的错误被稀释到阈值以上）告警转 `resolved`。如果想再验证延迟 SLO，可以注入 `latency_ms=400` 看 `slo:slo_demo_latency_good:ratio_rate5m` 跌到 0 附近，再恢复。

**常见现象**：生产档位 `SloDemoAvailabilityFastBurn` 比演练档位晚几分钟才 firing——这不是 bug：它的 1h 窗口会把错误稀释，注入的错误要在窗口里累计到 1.44% 以上（聚合 25% 错误率下约需 4 分钟，两个副本都注入约 2 分钟）才 pending，再等 `for: 2m` 才 firing。偶发的秒级尖峰几乎不可能凑够这个量——长窗口告警本来就该"钝"，这是设计而非缺陷。相应地，恢复后它也要等错误样本移出 1h 窗口（最长约 1 小时）才 resolved。

## Step 6 · 运行检查脚本

```bash
# [master]
cd ~/labs/01-slo-workshop
chmod +x check.sh
./check.sh
```

通过时的输出（10 项）：

```
PASS: slo-rules.yaml 存在且规则语法校验通过（promtool 优先，无则等效校验）
PASS: monitoring 命名空间存在 prometheusrule/slo-demo-slo
PASS: recording rule 含 slo:slo_demo_availability:ratio_rate5m
PASS: 告警规则含 SloDemoAvailabilityFastBurn 与 SloDemoAvailabilitySlowBurn
PASS: namespace slo-demo 存在
PASS: deployment/slo-demo Ready 副本 >= 1（当前 2）
PASS: svc/slo-demo 暴露 8000 端口
PASS: servicemonitor/slo-demo 存在且带 release=prom label
PASS: Prometheus 已加载 slo-demo.recording / slo-demo.alerts 规则组且 health=ok
PASS: demo_http_requests_total 指标已被 Prometheus 采集（查询有结果向量）

SCORE: 10/10
```

check.sh 的判分链是三级回退：本机 promtool → python3+PyYAML 的结构断言 → grep 结构检查；再加上 Prometheus `/api/v1/rules` 的 health 校验，即使没装 promtool 也能给出"等效验证"。

## 收尾

实验做完后现场可以保留（lab 02 会重新搭自己的环境，不依赖这里）；要清理时：

```bash
# [master]
kubectl delete -f slo-rules.yaml
kubectl delete -f app.yaml
kubectl delete -f load.yaml
```
