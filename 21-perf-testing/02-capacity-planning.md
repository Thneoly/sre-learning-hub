# 02 · 容量规划：从压测拐点到扩容决策

> 模块：21-perf-testing ｜ 建议时长：3 小时 ｜ 关联认证：—（无直接考点，与 CKA-资源管理、PCA-PromQL、15-sre-methodology 错误预算联动）

## 学习目标

- 能把第 1 章压出的"拐点 RPS + 饱和资源"外推成副本数与安全水位，并说清外推何时失效（共享瓶颈）
- 能用 USE 方法对每类资源回答"利用率/饱和度/错误"三问，并据此划分绿黄红水位线
- 能判读 K8s 的三本账——requests/allocatable（调度账）、usage/requests（HPA 账）、usage/limits（真实拥挤度）——不再把"CPU 利用率"当一句话
- 能给 Redis（内存与 eviction）、MySQL（连接与缓冲池）、应用侧连接池定容量基线和告警阈值
- 能解释 Proactive Scaling 为什么必须做在水位抬头之前，并输出一份可评审的容量评估报告

## 1. 从拐点到容量数字：外推法与安全水位

第 1 章的产出是两个数字：**拐点出现在多少 RPS、当时第一个饱和的资源是什么**。本章从这两个数字开工：

```
 吞吐
   │                        ╭── 拐点 400 RPS（CPU 饱和，第 1 章演练 B 记下的数字）
   │              ●─────●──╯
   │        ●────●   ← 线性区：外推只用这一段的斜率
   │   ●────●          ← 安全容量 = 拐点 × 水位系数 70% = 280 RPS
   └──┬─────┬─────────┬──────────→ 负载
    日常均值  峰值 950   目标 = 峰值 × (1+增长) 
```

三步外推法：

1. **单副本安全容量** = 拐点 RPS × 水位系数。水位系数常取 0.6~0.75——留的不是余量，是"突发、缓存冷启动、单副本故障后的重排"这些必然发生的事。
2. **目标负载** = 峰值 RPS × 增长系数（下个周期业务预估，如 1.3）。峰值取实测（网关 P95 流量），不取拍脑袋的"设计值"。
3. **副本数 N** = ceil(目标负载 ÷ 单副本安全容量) + 1。**+1 就是 N-1 原则**：峰值时刻挂掉任何一个副本（节点维修、drain、OOM），剩余副本仍在安全水位内。算例见实战演练 A。

外推的**适用边界**必须写进报告：线性外推假设"副本数翻倍、拐点翻倍"，这只在瓶颈是**无共享资源**（本副本的 CPU/内存）时成立。瓶颈如果是共享的——DB 连接池、下游配额、中心缓存带宽——副本数翻倍拐点不动甚至更糟（争抢加剧）。所以外推之后必须**抽样复验**：副本加倍后按第 1 章 2.3 脚本复压一轮，确认拐点接近翻倍；偏差超过 20% 就说明撞上了共享瓶颈，继续加副本无效，要么拆瓶颈（读写分离、连接池复用、配额扩容），要么改架构。

容量数字与错误预算的关系（详见 ../15-sre-methodology/02-sli-slo-error-budget.md 第 4 节）：容量不足从来不是"性能问题"，而是**可用性问题**——过载的延迟与失败直接烧错误预算。可用性目标越高，水位系数和 N-1 余量就该越保守；反过来，错误预算烧速异常时，第一个要排查的假设之一就是"流量是否已逼近拐点"。

## 2. USE 方法与饱和度水位

容量水位不能只盯"CPU 百分之多少"。USE 方法（Brendan Gregg）对**每类资源**问三个问题——利用率（Utilization）、饱和度（Saturation）、错误（Errors）：

| 资源 | 利用率 U | 饱和度 S（排队/等待证据） | 错误 E |
| --- | --- | --- | --- |
| CPU | us+sy 占比 | 运行队列长度、容器 CFS `nr_throttled` 增长 | —（CPU 本身不报错，节流即事实错误） |
| 内存 | working_set / limit | 匿名页换出、OOM 前的回收抖动 | OOMKilled（exit 137） |
| 磁盘 I/O | 吞吐占带宽比（`%util` 只在 HDD 时代可当利用率，见 01-linux/06 常见坑） | `iowait`/`await` 上涨、队列深度 | I/O error、fs 只读 |
| 网络 | 带宽占比 | 重传、丢包、缓冲溢出 dropped | errors 计数 |

为什么利用率不够：排队论的等待时间不是随利用率线性涨，而是**越接近 100% 抬得越陡**：

```
 平均等待时间
   │                                        ●  ← 98%
   │                                  ●  ← 95%
   │                            ●  ← 90%
   │                     ●  ← 80%：曲线开始离开地板
   │          ●  ← 60%
   │●───●───●  ← ≤50%：几乎不用等
   └───┬────┬────┬────┬────┬────┬──→ 利用率
      50%  60%  70%  80%  90% 100%
       ↑绿线之前"加负载不怎么加等待"
                     ↑黄线：等待开始值得花钱买走
```

利用率刻画"忙不忙"，饱和度刻画"排队多久"，而用户感知的是排队延迟——等利用率数字"变红"再动手，用户已经在付 p99 的账。第 1 章的 p99 拐点本质就是"饱和度指标在系统外的投影"，两者互为印证：p99 跳档的那一级负载，回去看资源快照，必有一个 S 列指标先抬头；反过来，巡检时发现 S 列抬头（如 `nr_throttled` 持续增长），即使 U 列只有 40%，也该按"拐点将至"对待。

据此把水位切成三档（阈值为通用起点，按业务压测数据校准）：

| 档位 | 含义 | 动作 |
| --- | --- | --- |
| 绿 < 60% | 日常水位 | 无动作，季度复核 |
| 黄 60%~75% | 计划线 | 立项扩容/优化，给排期；每周看趋势斜率 |
| 红 > 75% | 行动线 | 72 小时内扩容或降级预案待命；同时盯错误预算烧速 |

## 3. K8s 资源水位：requests / limits / allocatable 三本账

同一个"CPU 使用率"在 K8s 里至少有三个分母，混用它们是容量报告最常见的错误：

| 账本 | 算式 | 谁在读它 | 容量含义 |
| --- | --- | --- | --- |
| 调度账 | Σrequests / allocatable | scheduler（只看 requests） | **超卖度**：>100% 是设计而非故障 |
| HPA 账 | usage / requests | HPA（目标 utilization 基于 requests） | **弹性的刻度**：requests 定松了 HPA 就懒 |
| 拥挤账 | usage / limits | cgroup（limits 是硬上限） | **真实挤压**：逼近 100% 即节流/OOM 前夜 |
| 节点账 | Σusage / allocatable | 容量规划（你） | **节点真实水位**：三本账里唯一能外推机器数的 |

requests 与 limits 落到 cgroup 的机制见 04-k8s-fundamentals/11-resources-and-qos.md 第 1、2 节；allocatable = 节点 capacity 减去 kube-reserved、system-reserved 与 eviction-hard 预留——**买 8C 的机器，可分配给业务的往往只有 7C 出头**，按采购标称容量做规划必然高估。

```bash
# [master] 节点三本账一次看完
kubectl describe node <node> | sed -n '/Allocated resources/,/Events:/p'
#   Allocated resources 段的 requests 列 = 调度账；limits 列 = 超卖上限账
kubectl top nodes          # 真实用水（节点账的分子）
```

`Allocated resources` 段长这样（数值为示意）：

```
  Resource           Requests      Limits
  cpu                6500m (81%)   9500m (118%)
  memory             9Gi (58%)     14Gi (90%)
```

三行判读：cpu requests 81%——调度账高位，节点快塞满了，**再调度大 Pod 会 Pending**；cpu limits 118%——超卖 18%，若这些 Pod 同时真用到 limits 会争抢物理 CPU（此刻节点账显示真实用量多少决定是否疼）；memory limits 90% 比更危险的是 requests 58% 与实际用水的差值——内存没有"超卖后限流"这回事，**超卖的内存一旦真用满，代价是 OOM 驱逐**（04-k8s-fundamentals/11-resources-and-qos.md 第 4、6 节）。所以内存超卖度要给得比 CPU 更保守，这是容量评审里的一条硬规则。

```promql
# [任意节点] 拥挤账：Pod CPU 用量占自身 limit 的比例（>0.8 即节流前夜）
sum by (pod)(rate(container_cpu_usage_seconds_total{container!="",image!=""}[5m]))
  / on (pod) sum by (pod)(kube_pod_container_resource_limits{resource="cpu"})

# [任意节点] 节点账：节点 CPU 真实水位（node_exporter 视角）
1 - avg by (instance)(rate(node_cpu_seconds_total{mode="idle"}[5m]))

# [任意节点] HPA 账：用量占 requests 的比例（HPA 内部算的就是它）
sum by (pod)(rate(container_cpu_usage_seconds_total{container!="",image!=""}[5m]))
  / on (pod) sum by (pod)(kube_pod_container_resource_requests{resource="cpu"})
```

判读纪律：**先看拥挤账定"谁在疼"，再看调度账定"还能塞多少"，最后用节点账定"要不要买机器"**。QoS 顺带复核：容量吃紧的集群里，Burstable/BestEffort Pod 是驱逐优先级链上的前排（04-k8s-fundamentals/11-resources-and-qos.md 第 4 节），关键服务 requests=limits 换 Guaranteed，是容量规划的一部分而不只是性能优化。

## 4. 中间件容量基线

中间件的容量不是"CPU 内存多大"，而是**各自信任的那把尺子**还剩多少刻度：

**Redis**（机制详见 13-middleware/redis/03-caching-patterns-troubleshooting.md 第 4、6 节）：

| 基线 | 怎么看 | 阈值 |
| --- | --- | --- |
| 内存水位 | `redis_memory_used_bytes / redis_memory_max_bytes` | < 80%（到 100% 开始拒绝写或淘汰） |
| 淘汰速率 | `rate(redis_evicted_keys_total[5m])` | 恒为 0；> 0 即缓存穿透前兆，先查是流量涨了还是 TTL 设计变了 |
| 碎片率 | `mem_fragmentation_ratio`（RSS/used） | 1.0~1.5 健康；> 2 该看 activedefrag 或对齐页 |
| 连接 | `redis_connected_clients` vs maxclients（默认 10000） | 业务侧连接池复用后通常 < 1000；`redis_rejected_connections_total` 增长即已伤业务 |
| fork 余量 | 容器/宿主内存 ≥ 1.5 × maxmemory | 给 bgsave 的 COW 留量，否则 OOMKill 打断 RDB（13-middleware/redis/02-persistence-and-ha.md 常见坑） |

**MySQL**（排障详见 13-middleware/mysql/03-tuning-troubleshooting.md 第 4、6 节）：

| 基线 | 怎么看 | 阈值 |
| --- | --- | --- |
| 连接水位 | `Threads_connected / max_connections` | < 80%；打满报 1040，先分型再 KILL |
| 活跃连接 | `Threads_running` 突增 | 与慢查询速率对齐——是"连接多"还是"查询慢"的分水岭 |
| 缓冲池命中 | `Innodb_buffer_pool_reads / read_requests` | 物理读占比 > 1% 考虑加内存；`innodb_buffer_pool_size` 独占实例按内存 50%~75% 起步，以命中率为准迭代 |
| 慢查询速率 | `rate(mysql_global_status_slow_queries[5m])` | 突增先对齐发布时间轴，再 EXPLAIN |

**应用侧连接池**（最容易被忽略的一层）：容量公式用 HikariCP/PostgreSQL 社区的经典起点 `连接数 ≈ (CPU 核数 × 2) + 有效磁盘数`——**这不是真理，是让"池越大越好"幻觉破产的论据**：池远大于核数后，上下文切换与 InnoDB 行锁排队让吞吐不升反降。落地纪律：以公式为起点，用第 1 章的阶梯压测扫一遍池大小（如 10/20/40/80），取拐点前的平台值；同时在 DB 侧核对 `Σ各应用 pool 上限 + 预留 < max_connections`——这条不等式不成立，就是"每个应用都自以为没超配，合起来打爆 DB"的经典容量事故（复盘案例见 ../22-incident-stories/01-classic-incidents.md 故事 4）。

```
 应用 Pod ×6（每 Pod 池上限 50）        MySQL（max_connections 300）
 ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐ ┌────┐
 │ 50 │ │ 50 │ │ 50 │ │ 50 │ │ 50 │ │ 50 │   Σ 上限 = 300
 └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘ └──┬──┘
    └───────┴───────┴───┬───┴───────┴───────┘
                        ↓            运维/监控/备份预留 ？ ← 没留，首个排队的就是你
                 [ 连接打满：1040 Too many connections ]
```

连接池之外还有一层**缓存容量纪律**：`maxmemory-policy` 与业务语义对齐（缓存场景用 allkeys-lru 一类、不能丢的计数/锁场景别依赖淘汰），批量预热的 key 给 **TTL 加随机抖动**（如基础 TTL ± 20%）——同刻过期就是给 DB 的一次齐射，雪崩复盘见 ../22-incident-stories/01-classic-incidents.md 故事 2。

## 5. Proactive Scaling：把扩容做在水位抬头之前

HPA 这类**响应式**（reactive）扩容天然滞后，滞后是一条链：指标窗口聚合 → HPA 计算周期 → 新 Pod 调度 + 拉镜像 → 应用预热（JIT、连接池、本地缓存）。**每一环加起来 3~10 分钟**，而早高峰流量爬坡可能只要 5 分钟——水位冲过红线后扩容才到，p99 已经抖过了。

| 手段 | 做法 | 适用 |
| --- | --- | --- |
| HPA behavior 提速 | `behavior.scaleUp` 关 stabilizationWindow、放大步长；scaleDown 保留长窗口防抖 | 流量形态平缓的常规服务 |
| 定时预扩 | KEDA cron scaler / 周期性提前把副本从 N 扩到 N+k，峰后回收 | 强周期业务（早高峰、整点抢购） |
| 节点缓冲 | Cluster Autoscaler 之外维持 k 台空余节点（或节点池 min 提前上调） | 节点拉起比 Pod 拉起更慢，是链路最长的一环 |
| 事件驱动预扩 | 大促/推送前置任务先触发扩容流水线 | 已知流量事件 |

```yaml
# [master] HPA behavior：扩容抢时间、缩容防抖（字段语义以官方文档为准）
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata: { name: web, namespace: default }
spec:
  scaleTargetRef: { apiVersion: apps/v1, kind: Deployment, name: web }
  minReplicas: 3
  maxReplicas: 12
  metrics:
  - type: Resource
    resource:
      name: cpu
      target: { type: Utilization, averageUtilization: 65 }   # HPA 账（usage/requests）
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0        # 不等稳定窗，立刻扩
      policies: [{ type: Percent, value: 100, periodSeconds: 30 }]   # 每 30s 最多翻倍
    scaleDown:
      stabilizationWindowSeconds: 300      # 缩容慢半拍，防流量双峰来回割
```

`averageUtilization: 65` 与本章水位线的对应关系要心里有数：HPA 的 65% 是 **usage/requests**（第 3 节 HPA 账），不是节点账也不是拥挤账——requests 给松了（比如 2 核实际只用 0.6 核），HPA 到 65% 时真实拥挤度可能还很低，扩容形同虚设；requests 给紧了则天天虚警。**调 HPA 目标值之前先审 requests 的合理性**，这是三本账串起来用的实战例子。

预扩的本质是**用可预测性换滞后时间**：流量可预测的部分用日历解决，不可预测的部分才交给 HPA 兜底。Proactive 与容量报告的关系：报告给出"黄线何时到"的趋势斜率，预扩负责在那天到来之前把动作做完；两者都不该由告警触发——告警触发时用户已经在付延迟的账了。

## 6. 容量评估报告模板

```markdown
# <服务名> 容量评估报告 YYYY-MM
1. 结论先行：当前安全容量 X RPS，可支撑至 YYYY-MM（按周增速 3% 外推）；
   建议动作（扩容副本至 N / 优化瓶颈 / 无动作）+ 责任人 + 期限
2. 输入：压测日期与脚本版本（引用第 1 章报告）、拐点 RPS、当时饱和资源、
   生产峰值 RPS（取自网关 P95）、错误预算状态（15-sre-methodology/02 第 4 节）
3. 外推过程：水位系数、增长系数、N-1 校验算式；外推边界与共享瓶颈排查结论
4. 水位快照（本月）：四本账 + 中间件基线表，各附一行判读
5. 风险与依赖：共享瓶颈、单副本故障演练结果、CA/预算约束
6. 复核安排：下月重跑压测的条件（流量涨 20% / 大版本发布 / 架构变更）
```

报告里最容易写虚的是第 3、5 两节：外推边界写"无"等于没查（共享瓶颈要给出排查过的证据：加倍副本复压的对比数据）；N-1 不是算式里的 +1 就完事——**用一次真实的单副本下线验证延迟仍在 SLO 内**，这正是混沌工程"稳态假设"的用武之地（../15-sre-methodology/05-chaos-engineering.md 第 1 节：把"容量够"写成可证伪的假设，再用实验证它）。

## 实战演练：把第 1 章的拐点变成三张表

### 演练 A：外推算例（纸面，30 分钟）

取第 1 章演练 B 你记下的数字（下例用示意值，替换成你自己的）：拐点 400 RPS（CPU 饱和）。
安全容量 = 400 × 0.7 = 280 RPS/副本；生产峰值 950 RPS，季度增长预估 30% → 目标 1235 RPS。
N = ceil(1235 ÷ 280) + 1 = 5 + 1 = **6 副本**；N-1 校验：剩 5 副本 × 280 = 1400 ≥ 1235，通过。
把三个系数各改一档（0.6/0.8、增长 1.1/1.5）重算，体会结论对系数的敏感度——报告里要展示这组敏感性，而不是只给一个数。

### 演练 B：节点三本账判读（10 分钟）

```bash
# [master] 依次采集四本账
kubectl describe node $(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') \
  | sed -n '/Allocated resources/,/Events:/p'    # 调度账 + limits 账
kubectl top nodes                                 # 节点账分子
kubectl get hpa -A                                # HPA 账（TARGETS 列即 usage/requests）
```

对每个数字回答 USE 三问：哪个资源 U 高？S 证据在哪（`kubectl exec <pod> -- cat /sys/fs/cgroup/cpu.stat` 的 `nr_throttled`、`kubectl get events --field-selector reason=OOMKilling`）？写进报告第 4 节。

### 演练 C：中间件基线采集（15 分钟）

```bash
# [master] 集群内有 Redis/MySQL 时（可复用 13-middleware 对应 lab 环境）
redis-cli -h <host> -p <port> INFO memory | grep -E 'used_memory_human|maxmemory_human|mem_fragmentation_ratio'
redis-cli -h <host> -p <port> INFO stats  | grep -E 'evicted_keys|rejected_connections'
```

```sql
-- [任意节点] MySQL：连接水位与缓冲池命中（对照第 4 节阈值表判读）
SHOW GLOBAL STATUS LIKE 'Threads_connected';
SHOW GLOBAL STATUS LIKE 'Threads_running';
SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read%';
SHOW VARIABLES LIKE 'max_connections';
```

产出：一张 Redis 基线表 + 一张 MySQL 基线表，各 5 行以内，每行末尾写"绿/黄/红"。这就是容量报告第 4 节的中间件部分。

### 演练 D：N-1 验证（20 分钟，把 +1 从算式变成证据）

```bash
# [master] 靶标沿用第 1 章演练 A 的 nginx-bench；先扩到 3 副本
kubectl scale deploy/nginx-bench --replicas=3
kubectl rollout status deploy/nginx-bench --timeout=60s
# 用第 1 章 2.3 脚本打到目标负载的 1/2（副本已 ×3，等效验证剩余容量的余量），稳住后：
kubectl delete pod $(kubectl get pods -l app=nginx-bench \
  -o jsonpath='{.items[0].metadata.name}')   # 只删一个，模拟单副本故障
# 观察 k6 摘要与 Grafana：p99 是否抬档、错误率是否为 0、恢复时间多少秒
```

判定：删除一个副本后 p99 仍在阈值内、无错误，N-1 假设成立，写进报告第 5 节；p99 跳档则回到演练 A 加副本或提水位系数。这就是一次最小化的**稳态假设验证**——15-sre-methodology/05-chaos-engineering.md 第 1 节的方法用容量问题当靶子。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 副本翻倍，拐点没翻倍 | 共享瓶颈（DB 连接池、下游配额、中心缓存）先饱和 | 外推后加倍复压验证；瓶颈侧单独做容量基线（第 4 节） |
| 节点"CPU 60%"却频发 p99 尖刺 | 看的是调度账/采购标称，真实拥挤账已逼近 limits | 分清四本账（第 3 节），告警打在 usage/limits 与饱和度上 |
| HPA 扩了，p99 还是抖过了早高峰 | 响应式滞后链 3~10 分钟，爬坡 5 分钟就到峰 | 定时预扩 + behavior 提速（第 5 节） |
| 连接池从 50 加到 200 反而更慢 | 池远大于核数：上下文切换与锁排队吃掉吞吐 | 按核数公式起步，压测扫池大小取平台值（第 4 节） |
| 容量报告每季度都"结论无变化" | 只填模板不复压：代码发布让拐点漂移，旧外推早已失效 | 报告第 6 节写明重跑条件并挂进发布检查单 |

## 自测

<details><summary>1. 为什么容量告警应该打在饱和度（排队证据）而不是利用率上？举一个"利用率不高但已饱和"的实例。</summary>

利用率回答"忙不忙"，饱和度回答"排队多久"——用户感知的是排队延迟。排队论的等待时间随利用率非线性增长（80% 利用率之后抬升加速），等利用率数字"变红"再动，用户已经在付 p99 的账。实例：容器 CPU 用量 60% of limit 却周期性尖刺——CFS 配额在 100ms 周期内提前用完，`nr_throttled` 增长即饱和证据，利用率视角完全看不见（第 1 章 2.3 与 04-k8s-fundamentals/11 第 2 节）。
</details>

<details><summary>2. 调度账 120%、拥挤账 40%、节点账 55%——这三个数字矛盾吗？各回答什么问题？</summary>

不矛盾，它们是三本不同的账。调度账 120% 是超卖度（Σrequests/allocatable），K8s 设计如此，回答"还能不能塞更多 Pod"；拥挤账 40%（usage/limits）回答"业务现在挤不挤"——低说明 limits 给得宽或流量低；节点账 55%（Σusage/allocatable）回答"这台机器还要不要买"。容量规划的主口径是节点账+拥挤账，调度账只是调度器的排队依据。
</details>

<details><summary>3. N-1 原则里的 +1 到底在防什么？它和 PDB、错误预算各是什么关系？</summary>

防"峰值时刻单副本（或其所在节点）不可用"：drain、节点故障、OOMKill 都会让副本数瞬时 -1，剩余副本若被顶过拐点，故障就升级为容量事故。与 PDB 的关系：PDB 保证主动驱逐时服务方可见的下限（05-cka/06 第 1 节），N-1 保证驱逐发生时剩余容量仍在安全水位——前者管"允不许赶"，后者管"赶了之后接不接得住"。与错误预算的关系：N-1 不足最先表现为错误预算加速燃烧（延迟与失败），预算烧速是容量缺口的最早信号之一（15-sre-methodology/02 第 4、5 节）。
</details>

<details><summary>4. 应用连接池公式为什么是"核数级"而不是"并发用户数级"？把它接到第 1 章的拐点方法论上说明。</summary>

池里的每个连接在 DB 端对应一个线程/会话，真正并行执行 SQL 的能力受 CPU 核数与磁盘数约束；池超过这个数后，多出来的连接只是在 DB 端排队（上下文切换 + 锁等待），吞吐不升反降。用拐点语言说：连接池大小是横轴，DB 吞吐是纵轴——池大小自己就有一条拐点，扫出它（10/20/40/80 阶梯复压）取平台值，和给服务找 RPS 拐点是同一套方法论（第 4 节）。
</details>

<details><summary>5. 为什么"报告写明重跑条件"比"每季度固定重跑"更可靠？</summary>

容量漂移的驱动因素是事件（大版本发布、新依赖、流量结构变化、限流参数调整），不是日历——固定周期要么浪费（无变化也复压），要么滞后（发布当周就漂移）。把重跑条件（流量涨 20%、架构变更、大促前）写进报告并挂到发布检查单，让复压被真正的风险事件触发；日历只做兜底复核。
</details>

## 延伸阅读

- USE 方法（Brendan Gregg，利用率/饱和度/错误）：<https://www.brendangregg.com/usemethod.html>
- Kubernetes 资源管理（requests/limits 与节点 allocatable）：<https://kubernetes.io/docs/concepts/configuration/manage-resources-containers/>
- 水平自动扩缩（HPA 算法与 behavior）：<https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/>
- KEDA（定时/事件驱动扩缩容）：<https://keda.sh/docs/latest/>
- Google SRE Book 第 4 章 SRE 中的容量规划：<https://sre.google/sre-book/embracing-risk/> 及 SRE Workbook 容量规划章：<https://sre.google/workbook/capacity-planning/>
