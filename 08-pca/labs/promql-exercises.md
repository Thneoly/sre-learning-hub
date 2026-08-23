# PromQL 练习题 60 道

> 模块：08-pca ｜ 建议时长：每题 5~15 分钟，全部完成约 12 小时（可分 6 次刷完） ｜ 关联认证：PCA-PromQL（核心） / CKS-监控（部分）
>
> 本文按 `_meta/STYLE.md` 的"题库文件模板"（Lab 三件套的豁免形态，仅限 08-pca）组织：题目正确性依赖 Prometheus UI 查询结果，逐题到"如何验证你的答案"一节给出的环境中自查。

## 0. 如何验证你的答案

两种方式，任选其一：

**方式 A：练习集群（推荐）**

在 kubeadm 单 master 集群上先装好监控栈（Prometheus + node-exporter + kube-state-metrics，即 kube-prometheus-stack），然后打开 Prometheus UI 执行查询：

```bash
# [master]
bash scripts/setup/install-prom-stack.sh
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 --address 0.0.0.0 &
# 浏览器访问 http://<master IP>:9090 ，切到 Graph 标签页
```

本文的指标名以 kube-prometheus-stack 默认暴露的为准（`node_*` 来自 node-exporter，`kube_*` 来自 kube-state-metrics，`apiserver_*` 来自 kube-apiserver 自身 metrics）。

**方式 B：在线 playground**

打开 <https://play.promlabs.com/>（promlabs.com 官方在线 PromQL playground，内置 demo 数据集，可回放时间轴）。注意 playground 的指标名是 `demo_*` 前缀（如 `demo_api_request_duration_seconds_bucket`、`demo_cpu_usage_seconds_total`），把下文查询里的指标名替换即可，语法完全一致。

**刷题约定**

- 每题先自己写，再展开答案。答案里的"解析"说明为什么这么写，"常见错误"给出典型错法对比——PCA 考试里错法辨析比正解更常考。
- 涉及具体 IP（`172.30.30.21` 等）的题请换成你环境的实际地址。
- 所有查询默认在 Prometheus UI 的 **Table** 标签页验证（看瞬时值），画曲线时切 Graph。

---

## 第一组 · 基础选择器与向量语义（Q1~Q10）

### Q1. 找出所有抓取失败的 target

**场景**：早上巡检，你想先确认有没有 target 掉线。
**要求**：一条查询，列出当前所有抓取失败的抓取目标。
**预期输出**：0 行（健康）或若干行，每行带 `job`、`instance` 标签，值为 0。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
up == 0
```

**解析**：`up` 是 Prometheus 抓取时自动注入的 health metric，抓取成功为 1、失败为 0。`== 0` 是**过滤操作符**，保留值为 0 的原序列（标签不变）。用 `up` 做"探活"是告警的第一条规则。

**常见错误**：写 `up = 0`（PromQL 没有 `=` 赋值）；写 `up{value="0"}`（value 不是标签，不能在 `{}` 里匹配样本值）。

</details>

### Q2. 查某个节点的可用内存，单位 GiB

**场景**：你只关心 master 节点（`172.30.30.21`）还剩多少内存，并且要人能读的单位。
**要求**：用标签匹配限定该节点（node-exporter 端口 9100），把字节换算成 GiB。
**预期输出**：1 行，值为个位数到十几之间的浮点数（比如 `5.83`）。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
node_memory_MemAvailable_bytes{instance="172.30.30.21:9100"} / 1024^3
```

**解析**：`instance` 标签的值是 `host:port` 形式。PromQL 里 `^` 是幂运算，`1024^3` 等于 1024 的三次方；也可以写 `/ (1024 * 1024 * 1024)`。

**常见错误**：只写 `node_memory_MemAvailable_bytes` 然后用 `avg()`——不同节点不该被平均；`/ 1024*1024*1024` 少打括号（从左到右运算，等价于除了三次 1024 之外的错误结果——实际是 `/1024*1024*1024` 先除再乘，值完全错）。

</details>

### Q3. 只看 CPU 花在 user 和 system 上的时间

**场景**：你想排除 idle/iowait，只看真正干活的 CPU 时间序列。
**要求**：用**一条**正则匹配选出 `mode` 为 `user` 或 `system` 的所有序列。
**预期输出**：每个节点每核 2 行（user 一行、system 一行）。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
node_cpu_seconds_total{mode=~"user|system"}
```

**解析**：`=~` 是完全锚定的正则匹配（自动在前后加 `^$`），所以 `user|system` 不需要写 `^(user|system)$`。多个值用 `|` 分隔是最省事的做法。

**常见错误**：`=~"user"` 与 `="user"` 结果相同但语义冗余；`~"user|system"`（漏了 `=`，语法错误）；写成 `mode=~"user|system|"` 会额外匹配空字符串标签（此处无害，但在其他指标上会多出不想要序列）。

</details>

### Q3 补充练习（不计分）：`!~` 排除法

同一目标也可以反向写：`node_cpu_seconds_total{mode!~"idle|iowait|steal|softirq|irq|nice"}`。正向枚举比反向排除安全——新增 mode 时正向写法不会把未知项悄悄带进来。

### Q4. 排除监控自身命名空间的容器 CPU

**场景**：你想看业务容器的 CPU，`monitoring` namespace 里 Prometheus 自己很吵，要排除。
**要求**：查询 `container_cpu_usage_seconds_total`，排除 `monitoring` namespace，且排除 pause 容器（container 为空或 `POD`）。
**预期输出**：业务 namespace 的每个容器一行。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
container_cpu_usage_seconds_total{namespace!="monitoring", container!="", container!="POD"}
```

**解析**：cAdvisor 指标里 pause 容器的 `container` 标签是空字符串，较老版本里是字面量 `POD`，两个都要排除，否则 pod 级聚合时每个 pod 会多算一份。`!=` 是"不等于且标签存在"——注意它**不会匹配标签缺失**的序列，这里恰好是我们要的行为。

**常见错误**：只排除 `container!="POD"`，结果空字符串容器混进来；用 `namespace=~"monitoring"`（方向写反）。

</details>

### Q5. 过去 10 分钟内的最低可用内存

**场景**：内存是不是"现在还行、刚才崩过"？瞬时值会骗人，你要看窗口内的最差点。
**要求**：对 Q2 的指标取 10 分钟窗口的最小值，单位 GiB。
**预期输出**：1 行，值不大于当前瞬时值。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
min_over_time(node_memory_MemAvailable_bytes{instance="172.30.30.21:9100"}[10m] ) / 1024^3
```

**解析**：`[10m]` 是 range vector 选择器，必须配合 `*_over_time` 系列函数"折叠"成一个瞬时值。Gauge 型指标用 `min_over_time`/`max_over_time`/`avg_over_time` 都是合法的。

**常见错误**：直接 `node_memory_MemAvailable_bytes[10m]`——range vector 不能在 Table 里直接显示，也不能参与除法（除法操作数必须是瞬时向量）；把 `[10m]` 写到函数外面再套一层 `min(...)`——`min()` 是聚合操作符，不是时间窗口函数。

</details>

### Q6. 内存比 1 小时前少了多少

**场景**：怀疑内存泄漏，想知道当前值与 1 小时前的差值（正数=减少的量）。
**要求**：用 `offset` 计算"1 小时前的可用内存 − 当前可用内存"，单位 MiB。
**预期输出**：1 行，泄漏场景下为正数。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
(node_memory_MemAvailable_bytes{instance="172.30.30.21:9100"} offset 1h
 - node_memory_MemAvailable_bytes{instance="172.30.30.21:9100"}) / 1024^2
```

**解析**：`offset 1h` 把瞬时向量的取值点整体回退 1 小时，标签保持不变，因此二元减法按标签完美匹配。这是"自己和自己比"的标准写法。

**常见错误**：写成 `node_memory_MemAvailable_bytes - 3600`（那是减常数）；写成 `node_memory_MemAvailable_bytes{...}[1h]`（把 offset 和范围选择器混淆——前者平移取值时刻，后者取一段区间）。

</details>

### Q7. 用 `@` 修饰符取窗口起点的值

**场景**：在 UI 里画了最近 6 小时曲线，想加一条"6 小时前那一刻的内存"做基线对比。
**要求**：用 `@` 修饰符取评估区间起点时刻的样本值。
**预期输出**：Table 里 1 行；Graph 里是一条水平直线。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
node_memory_MemAvailable_bytes{instance="172.30.30.21:9100"} @ start()
```

**解析**：`@`（at）修饰符直接指定取值的时间戳，`start()` / `end()` 是当前查询区间的起止 unix 时间，也接受绝对值如 `@ 1755800000`。它和 `offset` 一样作用于选择器，且可以与 `offset` 组合（先 offset 再 @，以文档为准）。

**常见错误**：试图用 `offset -1h`（负 offset 语义是"看向未来"，不是取起点）；用 Grafana 的 `$__range` 直接塞进 PromQL（那是模板变量替换后的区间字符串，只在 Grafana 里有效）。

</details>

### Q8. 用 `__name__` 匹配同时选两个指标

**场景**：想在一条查询里同时拿到 `node_memory_MemTotal_bytes` 和 `node_memory_MemAvailable_bytes`（比如先肉眼对比），但不能在 `{}` 里写指标名（指标名本质是个标签）。
**要求**：用 `__name__` 正则一次选出这两个指标。
**预期输出**：每个节点 2 行。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
{__name__=~"node_memory_Mem(Total|Available)_bytes"}
```

**解析**：指标名在存储层就是 `__name__` 标签，所以"没有指标名、只有 `{}`"的空匹配器写法是合法的，适合一次捞一族指标。后面接算术运算时两个不同 `__name__` 的序列标签集不同（__name__ 不同即视为不同序列），二元运算匹配时会自动忽略 `__name__`。

**常见错误**：`{__name__="node_memory_*"}`——`=` 是精确匹配不是通配，要用 `=~"node_memory_.*"`。

</details>

### Q9. 按主机名列出集群节点信息

**场景**：你想确认 kube-prometheus-stack 是否把三台机器都监控到了，并且要按主机名（不是 IP）筛选 master（主机形如 `cka000001`）。
**要求**：用 `node_uname_info` 的 `nodename` 标签匹配 `cka0000` 开头的主机，展示每台的内核版本等信息。
**预期输出**：master 节点 1 行，值为 1，标签里有 `release`（内核版本）、`machine`（架构）。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
node_uname_info{nodename=~"cka0000.*"}
```

**解析**：`node_uname_info` 是个恒为 1 的 info metric，价值全在标签上。node-exporter 的 `instance` 是 IP:9100，而 `nodename` 保留了真实主机名——按主机名筛选比按 IP 筛选更稳（DHCP 环境下 IP 会变）。

**常见错误**：用 `instance=~"master.*"` 去猜地址；忘记 `.*` 导致 `=~"cka0000"` 匹配不到 `cka000001`。

</details>

### Q10. 统计当前健康的 target 数

**场景**：你要往 dashboard 放一个"监控覆盖率"数字。
**要求**：数出当前 `up == 1` 的序列个数。
**预期输出**：1 行，值等于集群里被抓取的 endpoint 总数（比如 30 左右）。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
count(up == 1)
```

**解析**：`count()` 是聚合操作符，作用于**瞬时向量**，统计序列条数。`up == 1` 先过滤，`count` 再数数。注意它数的是**序列数**不是"实体数"——如果一个 target 贡献多条 `up`（正常不会），会重复计数。

**常见错误**：`count(up) == 1`（语义变成"只有一个 target 时输出 1"）；`sum(up)`（数值求和，恰好等于个数只是因为值都是 1，语义错误且失败 target 存在时结果会错）。

</details>

---

## 第二组 · 函数与速率（Q11~Q22）

### Q11. kube-apiserver 每秒请求数，按 verb 分组

**场景**：看 apiserver 的 QPS 分布，判断是读多还是写多。
**要求**：对 `apiserver_request_total`（counter）用 5 分钟窗口算每秒速率，按 `verb` 聚合。
**预期输出**：每个 verb 一行（GET、LIST、POST…），值为 req/s，GET/LIST 通常远大于其他。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
sum by (verb) (rate(apiserver_request_total[5m]))
```

**解析**：counter 只增不减，直接看值没有意义，必须 `rate()`（窗口内增量 / 窗口秒数，自动处理 counter 回绕即进程重启）。`rate` 的窗口至少要覆盖 2 个样本，经验值是 4 倍抓取间隔；kube-prometheus 默认 30s 抓取，`[5m]` 覆盖 10 个点，安全。

**常见错误**：`rate(apiserver_request_total)` 缺 `[5m]`——rate 只吃 range vector；`sum(apiserver_request_total)` 直接对 counter 求和（无意义的大数）；先 `sum by (verb) (apiserver_request_total)` 再套 `rate(... [5m])`——见 Q56 的对比。

</details>

### Q12. 过去 1 小时 apiserver 总共处理了多少请求

**场景**：你要写周报："过去 1 小时 apiserver 处理了 N 次请求"。
**要求**：返回窗口内**增量**（次数，不是每秒速率），不分组。
**预期输出**：1 行，值为几十万级别的整数（浮点表示）。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
sum(increase(apiserver_request_total[1h]))
```

**解析**：`increase()` 就是 `rate() * 窗口秒数`，只是保留"次数"口径，外层套 `sum` 把各序列增量加总。汇报用 increase、计算用 rate，是一个团队的好习惯。

**常见错误**：`sum(apiserver_request_total) - sum(apiserver_request_total offset 1h)`——两端如果有进程重启（counter 回绕），会出现负数或漏算，`increase` 的回绕补偿逻辑能处理；对窗口语义不清楚时用 `rate(...) * 3600`，效果与 increase 基本一致，但可读性差。

</details>

### Q13. `irate` 与 `rate` 的取舍

**场景**：你在给一个高频指标画图，想知道"此刻"的瞬时速率；另一个场景是要设告警阈值。
**要求**：分别写出适合画瞬时尖峰的查询和适合告警的查询（对 `node_network_receive_bytes_total`，device 为主网卡 `ens192` 或 `eth0`，按你环境改）。
**预期输出**：两条查询，各自返回 bytes/s。

<details><summary>答案</summary>

```promql
# [Prometheus UI] 瞬时尖峰（画图用）
sum by (instance, device) (irate(node_network_receive_bytes_total{device=~"ens192|eth0"}[1m]))

# [Prometheus UI] 平滑速率（告警用）
sum by (instance, device) (rate(node_network_receive_bytes_total{device=~"ens192|eth0"}[5m]))
```

**解析**：`irate` 只取窗口内**最后两个**样本算斜率，反应快但抖动大；`rate` 用窗口内全部样本做线性回归，平滑但有滞后。告警必须用 `rate`——`irate` 会因为两个样本的微小毛刺触发误报。

**常见错误**：给 `irate` 配 `[10m]` 大窗口（窗口大小对 irate 几乎无意义，只有最后两个样本参与）；告警表达用 `irate` 导致 flapping。

</details>

### Q14. 检测 counter 发生过重置（进程重启）

**场景**：怀疑 apiserver 昨晚重启过，想从指标上找证据。
**要求**：统计过去 6 小时 `apiserver_request_total` 序列的重置次数，按 instance 聚合。
**预期输出**：正常 0；重启过则为正整数。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
sum by (instance) (resets(apiserver_request_total[6h]))
```

**解析**：`resets()` 返回窗口内 counter 值下降（回绕）的次数，即目标进程重启次数。配合 Q21 的 `changes()` 与 `time() - process_start_time_seconds` 可以互相印证。

**常见错误**：用 `increase` 出现负数来"推断"重启——increase 不会输出负数；对 gauge 用 `resets()`（gauge 下降是正常的，结果没有意义）。

</details>

### Q15. 用 `deriv` 看内存的每秒变化趋势

**场景**：怀疑某进程内存泄漏，想量化"每秒涨多少字节"。
**要求**：对 10 分钟窗口的 `node_memory_MemAvailable_bytes` 求每秒斜率（gauge 适用）。
**预期输出**：泄漏时为负数（可用内存每秒减少），量级约几万字节/秒。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
deriv(node_memory_MemAvailable_bytes{instance="172.30.30.21:9100"}[10m])
```

**解析**：`deriv()` 用线性回归求 gauge 的斜率（每秒变化量），只对 gauge 有意义。`rate` 是给 counter 的（只升不降），`deriv` 是给 gauge 的（可升可降）。

**常见错误**：对 counter 用 `deriv`（counter 恒正斜率，结果恒正，等于一个劣化版 rate）；对 gauge 用 `rate`（gauge 下降会被误判为 counter 回绕而丢掉样本）。

</details>

### Q16. 预测 4 小时后磁盘是否写满

**场景**：根分区 40 GB，日志涨得快，你想在"还剩 4 小时写满"时就收到告警，而不是等 90% 水位。
**要求**：基于过去 1 小时的写入趋势做线性外推，输出"4 小时后的剩余字节"，过滤掉 tmpfs/overlay。
**预期输出**：每个节点每个真实文件系统一行；危险时值为负。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs", mountpoint!=""}[1h], 4 * 3600) < 0
```

**解析**：`predict_linear(v, t)` 基于窗口内线性回归预测 t 秒后的值。`< 0` 作为过滤条件只留下"会写满"的序列，这就是社区标准的磁盘告警写法。挂载点过滤掉容器运行时的 overlay，避免误报。

**常见错误**：外推时间窗口太长（`[5m]` 外推 24h，噪音极大）；忘记 `mountpoint!=""`；把 `< 0` 写成 `> 0`（变成只显示不会写满的分区）。

</details>

### Q17. `delta` 与 `idelta` 的用途

**场景**：你要"过去 10 分钟可用内存的变化量"和"最近两个样本之间的变化量"两个口径。
**要求**：分别用 `delta` 与 `idelta` 写出来（gauge 指标）。
**预期输出**：两个数值，`delta` 平滑、`idelta` 抖动。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
delta(node_memory_MemAvailable_bytes{instance="172.30.30.21:9100"}[10m])
idelta(node_memory_MemAvailable_bytes{instance="172.30.30.21:9100"}[10m])
```

**解析**：`delta` = 窗口末值 − 窗口首值（有外推补偿）；`idelta` = 窗口内最后两个样本之差，和 `irate` 的关系类似 `delta` 和 `rate` 的关系。注意：这两个函数**在 counter 上也能跑但结果无意义**，语义上只该用于 gauge。

**常见错误**：拿 `delta` 对 counter 求"增量"（counter 重启回绕时不处理，可能出负数）——counter 的增量永远用 `increase`。

</details>

### Q18. 用 `absent` 检测"指标整个消失"

**场景**：node-exporter 在 `172.30.30.22` 上应该一直有 `up` 序列。如果它挂了，`up == 0` 能报警；但如果**整条序列没了**（比如抓取配置被误删），`up == 0` 也查不出来。
**要求**：写一条查询，该序列不存在时返回一行值 1。
**预期输出**：正常时无结果；序列消失时返回 1 行（标签与选择器里的恒定标签一致）。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
absent(up{job="node-exporter", instance="172.30.30.22:9100"})
```

**解析**：`absent()` 在输入为空时返回 `{job="node-exporter", instance="172.30.30.22:9100"} 1`（保留匹配器里写死的标签），非空时返回空。它是"存在性告警"的标配：series 级别的死亡只有它能发现。

**常见错误**：告警只写 `up == 0`（覆盖不了 target 被删配置的场景）；给 `absent()` 的匹配器里用正则 `=~"172.*"`——正则标签不会被继承到结果标签里，结果标签会缺失（结果仍是 1 行，但标签为空，告警里区分不了是谁丢了）。

</details>

### Q19. 用 `clamp_*` 控制比率边界

**场景**：做一个"内存使用率"面板，分子分母来自不同来源，极端时刻可能算出 105% 或负数，图很难看。
**要求**：计算 `100 * (1 - 可用/总量)`，并把结果钳制在 `[0, 100]` 区间。
**预期输出**：每节点一行，值在 0~100 之间。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
clamp_max(
  clamp_min(
    100 * (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes),
    0
  ),
  100
)
```

**解析**：`clamp_min`/`clamp_max` 分别设下限/上限。除零或样本错位产生的 NaN 不会被 clamp 修掉（NaN 比较返回 NaN），所以本质治理还是靠数据面，clamp 只是展示层兜底。

**常见错误**：只 clamp 一边；以为 clamp 能消除 NaN——不能，NaN 需要在查询里用 `!= NaN`? 实际写法是过滤或修数据（PromQL 里可用 `x != x` 检出 NaN，因为 NaN 不等于自身）。

</details>

### Q20. 用 `round` 让面板数字可读

**场景**：GiB 保留 1 位小数足够了。
**要求**：把 Q2 的结果四舍五入到 0.1 精度。
**预期输出**：比如 `5.8`。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
round(node_memory_MemAvailable_bytes{instance="172.30.30.21:9100"} / 1024^3, 0.1)
```

**解析**：`round(v, to_nearest)` 第二参数省略时默认取整。round 只影响显示，不影响告警判断；**告警表达式里不要 round**，否则阈值边界会抖动。

**常见错误**：`round(x, 1)` 期望保留 1 位小数（实际是四舍五入到整数——第二参数是"最近的倍数"，不是小数位数）。

</details>

### Q21. 用 `changes` 检测节点状态翻转（flapping）

**场景**：一台 worker 昨晚在 Ready/NotReady 之间反复横跳，你想量化翻转次数。
**要求**：统计过去 1 小时 `kube_node_status_condition{condition="Ready", status="true"}` 每个节点的值变化次数，过滤出变化超过 2 次的节点。
**预期输出**：稳定节点不出现；flapping 节点一行，值 >= 3。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
changes(kube_node_status_condition{condition="Ready", status="true"}[1h]) > 2
```

**解析**：`changes()` 数窗口内样本值发生变化的次数，是 0/1 型 gauge 的 flapping 检测标准工具。kube-state-metrics 把 condition 拆成 `status="true|false|unknown"` 三条序列，每条值为 1 或 0，盯 `status="true"` 这条即可。

**常见错误**：忘记过滤 `status` 标签，三条序列都算，change 次数虚高 3 倍；用它去数 counter 的变化（counter 每个样本都在变，结果等于样本数减一，没有信息量）。

</details>

### Q22. 用 `time() - timestamp()` 发现抓取滞后

**场景**：怀疑某个 target 抓取间隔被拉长（网络丢包），想看每个 target 最新样本距离现在多久。
**要求**：输出每个 node-exporter target 的"最新样本年龄"（秒）。
**预期输出**：正常 30 秒以内（默认抓取间隔）；异常时几十上百秒。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
time() - timestamp(up{job="node-exporter"})
```

**解析**：`time()` 是求值时刻的 unix 秒；`timestamp()` 取**样本自带的时间戳**（不是评估时间）。两者之差即样本新鲜度。注意它永远 >= 0 且约等于一个抓取间隔——因为 `up` 的样本就是最近一次抓取写下的。

**常见错误**：用 `timestamp()` 减 `timestamp()` 之外还想当然地写成 `now()`（PromQL 没有这个函数，取当前时间用 `time()`）。

</details>

---

## 第三组 · histogram 与分位数（Q23~Q32）

### Q23. kube-apiserver 写请求的 P95 延迟

**场景**：SLO 关注写延迟。写 verb 是 POST/PUT/PATCH/DELETE。
**要求**：按 verb 聚合，算 5 分钟窗口的 P95 延迟（秒）。
**预期输出**：每个写 verb 一行，值通常在 0.005~0.1 之间。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
histogram_quantile(
  0.95,
  sum by (le, verb) (
    rate(apiserver_request_duration_seconds_bucket{verb=~"POST|PUT|PATCH|DELETE"}[5m])
  )
)
```

**解析**：模板 = `histogram_quantile(q, sum by (le, <分组维度>) (rate(bucket[窗口])))`。三要素缺一不可：`rate`（bucket 也是 counter）、聚合时**保留 `le`**（这是 bucket 的维度标签）、分组维度放在 `by` 里与 `le` 并列。

**常见错误**：三个要素各丢一个，见 Q25/Q26。

</details>

### Q24. 从 `_sum`/`_count` 算平均延迟

**场景**：P95 太敏感，先看平均值给老板汇报。
**要求**：用 histogram 的 `_sum` 和 `_count` 系列算 5 分钟平均延迟（秒），对写请求。
**预期输出**：每个写 verb 一行，值 < P95（平均值恒不超过同分布的分位数上界这一直觉通常成立）。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
sum by (verb) (rate(apiserver_request_duration_seconds_sum{verb=~"POST|PUT|PATCH|DELETE"}[5m]))
/
sum by (verb) (rate(apiserver_request_duration_seconds_count{verb=~"POST|PUT|PATCH|DELETE"}[5m]))
```

**解析**：`_sum` 是观测值的累计和、`_count` 是观测次数的累计和（等价于 `le="+Inf"` 的 bucket）。和/次数 = 加权平均值，这是 histogram 平均值的唯一正确算法。

**常见错误**：`avg(rate(_sum[5m]))`——把"每个序列的平均增速"再平均，完全不是平均延迟；`rate(_sum)/rate(_count)` 不加 sum 直接除——多副本时分子分母各自只匹配一个序列，或干脆匹配不上返回空。

</details>

### Q25. 错误示范：忘了 `rate` 会发生什么

**场景**：新人写了下面这条查询，P95 结果是个天文数字。
**要求**：解释错误并给出修正。
**预期输出**：理解"为什么必须是 rate"。

<details><summary>答案</summary>

```promql
# [Prometheus UI] 错误写法
histogram_quantile(0.95, sum by (le, verb) (apiserver_request_duration_seconds_bucket{verb=~"POST"}))

# [Prometheus UI] 正确写法
histogram_quantile(0.95, sum by (le, verb) (rate(apiserver_request_duration_seconds_bucket{verb=~"POST"}[5m])))
```

**解析**：bucket 是累计 counter。不 rate 直接进 `histogram_quantile`，函数会按"各 le 桶的当前累计值"做插值——累计值之间**保持单调**，插值在数学上"能算"，但得到的分位数反映的是**开机以来所有历史请求**的分位数，窗口语义完全丢失，且数值随运行时间漂移。错误写法的典型症状是"重启后结果剧烈变化"。

**常见错误变体**：用 `irate`（只看两个样本，bucket 边界处插值极不稳定，禁止使用）。

</details>

### Q26. 错误示范：聚合时丢了 `le`

**场景**：另一条"看起来对"的查询，P95 结果异常偏高或等于最大桶。
**要求**：解释错误并修正。
**预期输出**：理解 le 必须保留在 by 列表里。

<details><summary>答案</summary>

```promql
# [Prometheus UI] 错误写法：le 被聚合掉
histogram_quantile(0.95, sum by (verb) (rate(apiserver_request_duration_seconds_bucket[5m])))

# [Prometheus UI] 正确写法
histogram_quantile(0.95, sum by (le, verb) (rate(apiserver_request_duration_seconds_bucket[5m])))
```

**解析**：错误写法把同一 verb 的**所有桶**（le=0.001、0.0025、…、+Inf）的速率加成了一个数，`histogram_quantile` 收到的"每个分组只有一条序列"，它会把这当作"只有一个桶的 histogram"——分位数直接坍缩到桶边界，结果可能是 `+Inf` 或一个无意义的上界。规则：**by 列表 = 你的分组维度 + `le`，永远如此**。

**快速自检**：展开内层 `sum by (...)` 单独执行，如果结果里看不到 `le="0.0x"` 这样的多行桶，就是写错了。

</details>

### Q27. 分位数不会超过最大桶边界

**场景**：你算出 P99 = 0.05s，但老板说"我看到有请求 3 秒才返回"。查了配置，histogram 的桶边界最大到 `0.05`（然后是 `+Inf`）。
**要求**：解释为什么 P99 恰好等于 0.05，以及怎么修。
**预期输出**：理解插值边界语义。

<details><summary>答案</summary>

桶边界类似 `le="0.001", "0.005", "0.025", "0.05", "+Inf"` 时：

```promql
# [Prometheus UI] 验证 +Inf 桶占比：慢请求确实存在
sum(rate(apiserver_request_duration_seconds_bucket{le="0.05"}[5m]))
/
sum(rate(apiserver_request_duration_seconds_count[5m]))
```

**解析**：`histogram_quantile` 在**相邻两个桶边界之间线性插值**；如果分位数落在最大有限桶与 `+Inf` 之间，它只能返回最大有限桶的值（0.05），因为 `+Inf` 侧没有上界可插值。修复方法是应用侧重新设计 bucket 边界（加大上限），监控侧无解。

**常见错误**：以为 `le="+Inf"` 桶能提供上界——它只提供"总量"，不提供形状。

</details>

### Q28. 按 resource 维度看 P90

**场景**：apiserver 延迟要按操作对象（pods、nodes、secrets…）分析，定位哪类资源慢。
**要求**：P90，按 `resource` 分组，窗口 5m，只看 LIST（大对象列表是重灾区）。
**预期输出**：每个 resource 一行。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
histogram_quantile(
  0.90,
  sum by (le, resource) (
    rate(apiserver_request_duration_seconds_bucket{verb="LIST"}[5m])
  )
)
```

**解析**：和 Q23 同一个模板，只是分组维度换掉。注意 `resource` 标签有部分请求为空（非资源请求如 `/healthz`），它们会被聚合到 `resource=""` 一组，属正常。

**常见错误**：把 `verb` 和 `resource` 都想要，却在 by 里漏了 `le`——回到 Q26。

</details>

### Q29. 算"0.05 秒内完成的请求占比"

**场景**：SLO 写的是"95% 的写请求 < 50ms"，你想直接算达标率而不是分位数。
**要求**：用 bucket 直接算占比，目标 0.95。
**预期输出**：1 行，值在 0~1 之间。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
sum(rate(apiserver_request_duration_seconds_bucket{verb=~"POST|PUT|PATCH|DELETE", le="0.05"}[5m]))
/
sum(rate(apiserver_request_duration_seconds_count{verb=~"POST|PUT|PATCH|DELETE"}[5m]))
```

**解析**：bucket 本身就是"<= 边界"的累计计数，`le="0.05"` 桶 / 总数 = 达标率。**误差预算**玩法：`(1 - 上式)` 得到错误率，乘以时间窗口的预算消耗。注意 `le` 的值必须是 bucket 边界里真实存在的值，否则分子为空。

**常见错误**：用 `histogram_quantile(0.95, ...)` 的结果和 0.05 比较——分位数是"插值出来的估计"，达标率是"精确计数之比"，后者才是 SLO 的正确口径。

</details>

### Q30. 检查 bucket 设计是否合理

**场景**：新服务的 histogram 所有请求都落在最大有限桶里，你怀疑 bucket 边界配错了。
**要求**：列出该 histogram 每个 `le` 的速率，肉眼检查分布。
**预期输出**：一张各桶速率表，用于判断"绝大多数流量落在哪个区间"。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
sum by (le) (rate(apiserver_request_duration_seconds_bucket[5m]))
```

**解析**：桶是**累计**的（le=0.001 <= le=0.005 <= ...），读数时要记住"每个桶 = 所有更小桶 + 本区间"。两个实用判读法：(1) 如果最小的几个桶速率几乎为 0、最后一个有限桶又几乎等于 `+Inf` 桶，说明流量集中在"最后一个有限桶到无穷"这个无法插值的区间——桶上限配小了（回到 Q27）；(2) 想看各**区间**的分布，把这张表导出到 Grafana，用 `le` 做 X 轴画台阶图的差分即可，PromQL 本身没有"相邻桶相减"的函数（桶之间不是时间平移，`offset` 帮不上忙）。

**常见错误**：把累计桶当独立桶解读，得出"le=+Inf 的桶请求量最大"这类错误结论。

</details>

### Q31. gauge 型"平均延迟"的陷阱

**场景**：某应用只有一个 gauge `app_last_request_duration_seconds`（最近一次请求的延迟），新人直接对它取 `avg_over_time` 当作"平均延迟"汇报。
**要求**：解释为什么错、什么时候"勉强可用"。
**预期输出**：概念题，无查询。

<details><summary>答案</summary>

**解析**：`avg_over_time(app_last_request_duration_seconds[5m])` 是"时间维度上每秒采样的平均"，权重 = 时间；而真正的平均延迟权重 = 请求次数。低峰期 1 个慢请求会被 299 个重复采样的"快值"稀释，反之高峰期一个值代表几百个请求。它只能刻画"最近一次请求延迟的平滑走势"，不能当 SLA 数字。

正确姿势是推动应用侧改用 histogram（`_count`/`_sum`/`_bucket`），监控端无解。这也是 PCA 考试里"辨识 instrumentation 是否合格"的常考点。

**常见错误**：用 `max_over_time` 代替 P99——max 是极值不是分位数，一个异常值就能毁掉整张图。

</details>

### Q32. 多副本聚合为什么仍然正确

**场景**：apiserver 只有 1 个副本时你算过 P95；扩到 3 副本后，同样的查询（`sum by (le, verb)`）返回的对不对？
**要求**：解释聚合后 le 语义为何仍成立。
**预期输出**：概念题。

<details><summary>答案</summary>

**解析**：histogram 是**可加的**：每个桶是"<= 该边界的观测次数"计数器，3 个副本各自计数相加后，语义变成"3 个副本合计的 <= 边界次数"，仍然是合法的 histogram。这就是 histogram 相比 pre-computed quantile（应用端直接算好 P95 再 expose 成 gauge）的核心优势——**分位数不能跨实例平均，但桶可以跨实例相加再取分位数**。

**常见错误**：应用端 expose `app_p95_seconds` gauge，然后 `avg by (pod)` 聚合——"分位数的平均值"在数学上不等于"总体的分位数"，副本数越多误差越大。这是 PCA 最经典的陷阱之一。

</details>

---

## 第四组 · 聚合与标签操作（Q33~Q42）

### Q33. 每个节点的"非 idle"CPU 使用核数

**场景**：dashboard 要一行一个节点显示总 CPU 使用（单位：核）。
**要求**：`sum by` 聚合 `node_cpu_seconds_total`，排除 idle 与 iowait，5m 窗口。
**预期输出**：每节点一行，2 核机器值在 0.1~2.0 之间。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
sum by (instance) (rate(node_cpu_seconds_total{mode!="idle", mode!="iowait"}[5m]))
```

**解析**：每核每 mode 一条序列，`rate` 后每条是"该核花在该 mode 的时间占比"（0~1，正好等于核数单位），`sum by (instance)` 把所有核加起来就是总核数消耗。

**常见错误**：漏 `rate` 直接 sum（得到开机以来的累计秒数，天文数字）；`by (instance, mode)` 保留了 mode（那是下一题想要的，不是本题）。

</details>

### Q34. `by` 与 `without` 的区别

**场景**：同 Q33 的需求也可以用 `without` 写。
**要求**：用 `without` 重写 Q33，并说明两者差异与各自适用场景。
**预期输出**：一条等价查询 + 概念说明。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
sum without (cpu, mode, job) (rate(node_cpu_seconds_total{mode!="idle", mode!="iowait"}[5m]))
```

**解析**：`by (a, b)` = 只保留列出的标签（白名单）；`without (a, b)` = 去掉列出的标签、其余全保留（黑名单）。`without` 适合"标签很多、只想扔掉少数几个"；`by` 适合"标签很多、只要少数几个"（更稳，推荐默认用 by，不受未来新增标签影响）。

**常见错误**：`without` 忘了 `cpu`，结果每核一行；以为两者可以混写成 `sum by (x) without (y)`——语法错误，只能二选一。

</details>

### Q35. CPU 消耗最高的 5 个容器

**场景**：容量排查，找 Top 5 吃 CPU 的 pod。
**要求**：按 pod 聚合 5m 平均 CPU（核），只保留前 5 名。
**预期输出**：至多 5 行，从高到低排列（Table 按值排）。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
topk(5,
  sum by (namespace, pod) (
    rate(container_cpu_usage_seconds_total{container!="", container!="POD", namespace!=""}[5m])
  )
)
```

**解析**：`topk(k, v)` 只作用于**瞬时向量**，按样本值取前 k。注意它不是"排序显示"，而是过滤；想要完整排序去 Grafana 里点表头。

**常见错误**：`sort(topk(5, ...))` 以为能升序展示（sort 是整体排序，会把 topk 的 5 条重排，倒是没错，但 `sort_desc(topk(...))` 才是"从高到低"）；对 range vector 用 topk（语法错误）。

</details>

### Q36. "平均的平均"陷阱

**场景**：你要算"每个 namespace 的平均容器 CPU"。新人写了 `avg by (namespace) (rate(container_cpu_usage_seconds_total[5m]))`。
**要求**：指出问题并给出正确写法。
**预期输出**：正确写法每 namespace 一行。

<details><summary>答案</summary>

```promql
# [Prometheus UI] 错误：每个容器的均值再均值，容器数多的 namespace 被稀释
avg by (namespace) (rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m]))

# [Prometheus UI] 正确：总量平均到容器才是"平均容器 CPU"；要"总量"则只要 sum
sum by (namespace) (rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m]))
/
count by (namespace) (rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m]))
```

**解析**：`avg` 在 PromQL 里是**每个序列一票**的算术平均。如果各容器权重本应不同（QPS、请求数），必须显式写成 `sum(x*w)/sum(w)` 的加权形式（回顾 Q24 的 `_sum/_count` 就是这个套路）。判断标准：问自己"我平均的是序列还是事件"。

**常见错误**：在跨 namespace 汇总时再套一层 `avg(avg by (namespace) (...))`——误差逐层放大。

</details>

### Q37. 数出每个节点的 CPU 核数

**场景**：容量盘点：每台机器几核？
**要求**：用 `node_cpu_seconds_total` 数出每节点逻辑核数。
**预期输出**：每节点一行，值为核数（比如 2 或 4）。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
count by (instance) (node_cpu_seconds_total{mode="idle"})
```

**解析**：每个逻辑核一条 `mode="idle"` 序列，`count` 数序列即数核。这比 `count(count by (cpu) (...))` 简单，也和官方 node-exporter dashboard 的做法一致。

**常见错误**：`count(node_cpu_seconds_total)`——没按 instance 分组，把所有节点的核加到了一起；用 `node_cpu_seconds_total{mode="idle"}` 直接看值（那是累计秒数）。

</details>

### Q38. 用 `group` 判断"是否存在"

**场景**：检测 `kube-system` 里是否**还有任何 Running 的 pod**（比如排查 CoreDNS 全挂）。
**要求**：结果只有 0/1 语义：存在则 1、不存在则无结果。
**预期输出**：正常 1 行值为 1；全挂时无结果（可配 `or vector(0)`，见 Q60）。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
group(kube_pod_status_phase{namespace="kube-system", phase="Running"})
```

**解析**：`group(v)` 把所有输入序列折叠成一条值为 1 的序列（标签只留分组的）。它是"存在性"的聚合版：不关心值只关心有没有。相比 `count(...) > 0`，group 意图更直白，还能带上 `by` 维度（`group by (namespace) (...)` 每个 namespace 一行 1）。

**常见错误**：用 `sum(...) >= 0` 判断存在——恒真，无意义。

</details>

### Q39. 用 `label_replace` 从 `instance` 提取短主机名

**场景**：dashboard 上 `instance="172.30.30.21:9100"` 太长，想显示成 `172.30.30.21`。
**要求**：用 `label_replace` 生成一个 `short_instance` 标签。
**预期输出**：每行多出 `short_instance="172.30.30.21"`。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
label_replace(up{job="node-exporter"}, "short_instance", "$1", "instance", "(.+):9100")
```

**解析**：参数依次是：向量、目标标签名、替换模板、源标签、正则。正则全锚定，捕获组 `$1` 填进新标签。`label_replace` 只在**查询时**改标签；要永久生效应在抓取配置 `relabel_configs` 里做（PCA 两者都考）。

**常见错误**：正则里忘了捕获组 `(.+)`，`$1` 无内容导致标签为空串；把它当成能"改名"原标签的工具——其实可以（dst_label 写成 `instance` 会覆盖原值），但覆盖后原信息就丢了。

</details>

### Q40. 用 `label_join` 拼接唯一 key

**场景**：要把 `namespace` 和 `pod` 拼成一个 `ns_pod` 标签用于两条指标之间的匹配。
**要求**：用 `label_join` 生成 `ns_pod="namespace/pod"`。
**预期输出**：每行多出 `ns_pod="monitoring/prometheus-..."`。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
label_join(
  kube_pod_info{namespace="monitoring"},
  "ns_pod", "/", "namespace", "pod"
)
```

**解析**：参数为：向量、目标标签、分隔符、若干源标签。它常用于给两条标签体系不一致的指标制造人工 join key——但注意二元运算的 `on/ignoring`（见 Q42）通常更干净，`label_join` 是没有办法时的办法。

**常见错误**：分隔符和源标签顺序写反（第 3 参是分隔符，之后才是源标签列表）。

</details>

### Q41. `topk` 的平局问题

**场景**：你用 `topk(3, ...)` 却看到了 5 行结果。
**要求**：解释原因，并给出"每组分前三"的写法。
**预期输出**：概念 + 一条 `topk by` 查询。

<details><summary>答案</summary>

```promql
# [Prometheus UI] 每个 namespace 内的 Top 3
topk by (namespace) (3,
  sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m]))
)
```

**解析**：`topk` 在值并列时会**多返回**序列（k 是下界不是上界），比如很多 pod 值恰好相同时结果膨胀。另外 topk 支持 `by/without` 前缀，变成"组内 Top N"，这是"每个 namespace 最忙的 pod"这类需求的标准解，比给每个 namespace 单独写一条查询优雅得多。

**常见错误**：以为 `topk by (...)` 语法是 `topk(3, ...) by (namespace)`——聚合操作符的 by 前缀必须写在函数名和括号之间。

</details>

### Q42. 二元运算的标签匹配：`on` / `ignoring` / `group_left`

**场景**：算"每容器 CPU 使用率 = 使用量 / requests"。左边 `container_cpu_usage_seconds_total` 的标签有 `namespace,pod,container,image,id,instance,job`；右边 `kube_pod_container_resource_requests{resource="cpu"}` 的标签有 `namespace,pod,container,node,resource,unit` 等。
**要求**：写出这条除法，保证两边正确配对且结果保留左边全部标签。
**预期输出**：每容器一行，值为使用率（0.5 = 用了半个核）。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m])
  / on (namespace, pod, container)
    group_left
  kube_pod_container_resource_requests{resource="cpu", unit="core"}
```

**解析**：默认（无修饰）二元运算是**标签集完全相同**才匹配——这两条指标标签差异太大，不写匹配修饰结果必为空。`on(a,b,c)` 指定只按这几个标签配对，忽略其余；`group_left` 声明"左边是多的一侧"，允许左边多条序列共享右边同一条序列，并保留左边的完整标签集（反过来右边多就用 `group_right`）。记法：**多的一侧写在哪边，group_* 后缀就是哪边**。

**常见错误**：漏 `group_left` 报 "many-to-many matching not allowed"；把 `group_left` 写在没有多对一关系的地方（无害但冗余）；`on` 列表里放了只在一边存在的标签（永远匹配不上，结果为空）。

</details>

---

## 第五组 · 子查询与运维场景（Q43~Q52）

### Q43. 1 小时内"5 分钟平均流量"的峰值

**场景**：网络告警基于 5m 平均速率，你想知道过去 1 小时这个告警口径下的峰值到过多少。
**要求**：用**子查询**组合 `rate` 与 `max_over_time`，单位 Mbps。
**预期输出**：每 (instance, device) 一行。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
max_over_time(
  rate(node_network_receive_bytes_total{device=~"ens192|eth0"}[5m])[1h:1m]
) * 8 / 1024 / 1024
```

**解析**：子查询语法 `expr[range:step]`，把一个瞬时向量表达式在时间轴上按 step 重放，变成 range vector，从而能套 `*_over_time`。这里 `rate(...[5m])` 先算成每分钟的速率序列，再取 1 小时最大值。`*8` 是字节转比特。

**常见错误**：想当然写 `max_over_time(rate(...[5m]))`——rate 的输出是瞬时向量，`max_over_time` 只接受 range vector，语法直接报错；步长写太大（`[1h:30m]` 只有 2 个点，峰值被漏掉）。

</details>

### Q44. 1 小时内"1 分钟速率"的 P95

**场景**：同 Q43，但你要的是分布而不是极值（峰值可能是单次毛刺）。
**要求**：用 `quantile_over_time` + 子查询。
**预期输出**：每 (instance, device) 一行。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
quantile_over_time(0.95,
  rate(node_network_receive_bytes_total{device=~"ens192|eth0"}[1m])[1h:30s]
)
```

**解析**：`quantile_over_time(q, range)` 对**单条序列的时间轴**取分位数；与之相对的 `histogram_quantile` 是对**同一时刻的多条序列**取分位数。两者名字像，维度完全不同，PCA 常拿这个对照出题。

**常见错误**：把 `quantile_over_time` 用在"多条 pod 序列"上想得到 pod 间 P95——那样每个 pod 各得一个值，应该用 `histogram_quantile`（如果原始指标是 histogram）或对聚合值做 `quantile()` 聚合。

</details>

### Q45. 每个命名空间"不处于 Running 灯"的 pod 数

**场景**：值班大盘要一列"当前异常 pod 数"。
**要求**：按 namespace 统计 phase 不是 Running 的 pod 数量，只要非零的。
**预期输出**：只显示有异常的 namespace，值为异常 pod 数。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
sum by (namespace) (kube_pod_status_phase{phase!="Running"}) > 0
```

**解析**：`kube_pod_status_phase` 对每个 pod 的每个 phase 各暴露一条序列，实际取值 1（该 pod 处于此 phase）或 0（不处于）。所以"非 Running 的 pod 数"= 把 Pending/Unknown/Succeeded/Failed 各 phase 中值为 1 的加起来——直接 `sum by (namespace)` 即可（值为 0 的序列贡献 0，不影响和），`> 0` 过滤掉干净的 namespace。

**常见错误**：`kube_pod_status_phase{phase!="Running"} == 1` 忘了过滤值为 0 的序列，把已 Running 的 pod 的 Pending 序列（值 0）也显示出来；用 `!=` 匹配 phase 却忘了 Succeeded/Failed 的 job pod 会长期计入，需要业务上另行排除（加 `phase=~"Pending|Unknown"` 只盯"卡住"的更常用）。

</details>

### Q46. 容器 1 小时内重启超过 3 次

**场景**：CrashLoop 的早期信号。
**要求**：按 pod 列出 1 小时重启增量大于 3 的容器，带上 namespace。
**预期输出**：异常 pod 一行，值为重启次数。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[1h])) > 3
```

**解析**：`kube_pod_container_status_restarts_total` 是 kube-state-metrics 暴露的 counter（每容器一条），`increase` 取窗口增量。注意 pod 被删除重建后是新序列（pod name 可能相同但 UID 变了，`uid` 标签不同），极端场景下会漏计。

**常见错误**：直接取瞬时值比较（那是开机以来累计重启数，长期运行的 pod 天然超 3）；用 `rate(...) * 60` 而不是 increase，数值口径绕弯且易错。

</details>

### Q47. CPU 使用超过 requests 的 pod

**场景**：超 requests 不至于被杀（那是 limits），但会造成 throttling 风险与调度超卖，要找出来。
**要求**：每容器"使用量 / requests"，过滤出比值 > 1 的，按 pod 聚合。
**预期输出**：超卖的 pod 一行，值为倍数（1.2 = 超了 20%）。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m]))
  / on (namespace, pod)
    sum by (namespace, pod) (kube_pod_container_resource_requests{resource="cpu", unit="core"})
> 1
```

**解析**：两边都先 `sum by (namespace, pod)` 成同标签集，配对自然成立（一比一，不需要 group_left）。多容器 pod 里"总量/总 requests"是团队常用口径；要看单容器就用 Q42 的写法。

**常见错误**：分母序列存在但某 pod 没 requests（值为空导致该 pod 整行消失——这是**正确**行为，但你要知道为什么）；把 `> 1` 写进括号里 `sum(...) > 1 / ...`（运算优先级，比较和除法混写必须用括号控制）。

</details>

### Q48. "4 小时内会写满"的磁盘告警口径

**场景**：把 Q16 变成告警规则，还要排除剩余空间仍然很大的假阳性（趋势很陡但盘子太空）。
**要求**：predict_linear 小于 0 **且** 当前剩余已低于 15%，两个条件与。
**预期输出**：返回同时满足两个条件的 (instance, mountpoint)。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
(predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs", mountpoint!=""}[1h], 4 * 3600) < 0)
and on (instance, device, mountpoint)
(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs", mountpoint!=""}
  / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs", mountpoint!=""} < 0.15)
```

**解析**：`and` 是集合交（保留左边中标签匹配右边的序列），`on(...)` 指定匹配键。双条件能显著降低"新挂盘刚开始有写入趋势"（斜率高但盘子还空）造成的误报。**注意**：不同 node-exporter 版本的文件系统大小指标名统一是 `node_filesystem_size_bytes`，但 fstype/mountpoint 的过滤值可能因环境而异，先单独执行第二个条件确认非空再合并。

**常见错误**：只用单条件 predict_linear（大盘低斜率误报、小盘高斜率漏报的权衡无解）；把 `and` 写成 `/`（除法不是逻辑与）。

</details>

### Q49. kube-state-metrics 整体挂掉的检测

**场景**：`kube_pod_status_phase` 等一大批指标来自 kube-state-metrics（KSM）。KSM 挂了之后所有 `kube_*` 告警**静默失效**——这是监控系统的单点。
**要求**：写一条"KSM 消失"的检测表达式。
**预期输出**：正常无结果；KSM 的序列整体消失时返回 1。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
absent(kube_pod_status_phase)
```

**解析**：`absent` 接"任何一条 KSM 必产出的指标"，全消失时报警。更完整的元监控三件套：`absent(up{job="kube-state-metrics"})`（target 没了）、`up{job="kube-state-metrics"} == 0`（抓取失败但 target 还在）、`absent(kube_pod_status_phase)`（target 在、抓取成功、但业务指标没了，比如 KSM 起来了但 watch 失败）。三层覆盖三种故障模式。

**常见错误**：以为 `up == 0` 就够——它覆盖不了"job 配置被删"和"指标为空"两种情况。

</details>

### Q50. apiserver 5xx 错误率百分比

**场景**：apiserver 健康大盘的核心指标。
**要求**：5 分钟窗口，5xx 占总请求的百分比，舍入到 0.01。
**预期输出**：1 行，健康集群一般 < 1（百分比数值）。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
round(
  100 *
  sum(rate(apiserver_request_total{code=~"5.."}[5m]))
  /
  sum(rate(apiserver_request_total[5m])),
  0.01
)
```

**解析**：`code=~"5.."` 匹配 500~599。分子分母都从 0 开始 `sum`（不带 by），标签全部聚合掉后两边各剩一条"无标签"序列，自然匹配。除零：当 apiserver 完全没有请求时分母为空，整个表达式为空——可以接受（无流量=无错误率）。

**常见错误**：分子分母 `by (code)` 分组不一致导致一堆序列两两相除（label 不匹配为空）；用 `code=~"5.*"`——`.` 在正则里匹配任意字符，`"5.*"` 会匹配 "5x" 之外还会把 "50x" 之类都算进来，正确写法是 `5..`（两个点各匹配一个字符）。

</details>

### Q51. 把复杂查询做成 recording rule

**场景**：Q50 这条错误率查询被 12 个 dashboard 和 3 条告警引用，每次都实时算，Prometheus 吃力。
**要求**：写一份 recording rules 文件，把 Q50 固化成 `apiserver:5xx_error_ratio:percent5m`，并说明在 kubeadm 集群上怎么挂进 kube-prometheus-stack。
**预期输出**：YAML 片段 + 应用命令。

<details><summary>答案</summary>

```yaml
# [master，保存为 /tmp/apiserver-rules.yaml]
groups:
  - name: apiserver.slo
    interval: 30s
    rules:
      - record: apiserver:5xx_error_ratio:percent5m
        expr: |
          100 *
          sum(rate(apiserver_request_total{code=~"5.."}[5m]))
          /
          sum(rate(apiserver_request_total[5m]))
```

```bash
# [master] 挂进 kube-prometheus-stack（它会自动加载 PrometheusRule 资源）
kubectl -n monitoring create configmap apiserver-rules \
  --from-file=apiserver-rules.yaml --dry-run=client -o yaml | kubectl apply -f -
```

更贴合 kube-prometheus-stack 的方式是创建 `PrometheusRule` CR：

```yaml
# [master，保存为 /tmp/prometheusrule-apiserver.yaml]
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: apiserver-slo
  namespace: monitoring
  labels:
    release: kube-prometheus-stack   # 必须匹配 Prometheus CR 的 ruleSelector
spec:
  groups:
    - name: apiserver.slo
      interval: 30s
      rules:
        - record: apiserver:5xx_error_ratio:percent5m
          expr: |
            100 *
            sum(rate(apiserver_request_total{code=~"5.."}[5m]))
            /
            sum(rate(apiserver_request_total[5m]))
```

```bash
# [master]
kubectl apply -f /tmp/prometheusrule-apiserver.yaml
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090 &
# UI 里查询 apiserver:5xx_error_ratio:percent5m 应立刻有值
```

**解析**：recording rule 提前算好存成新序列，dashboard/告警直接查新指标。命名约定 `level:metric:operations`（如 `apiserver:5xx_error_ratio:percent5m`），冒号是保留分隔符，不能用于普通指标名，恰好避免冲突。`ruleSelector` 匹配不上是规则不生效的第一嫌疑（label `release` 的值以你的安装参数为准）。

**常见错误**：新指标名里用了冒号以外的奇怪字符或与已有指标重名；`ruleSelector` label 不匹配导致规则根本没被加载（Prometheus UI 的 Rules 页面里看不到）。

</details>

### Q52. 对速率序列做指数平滑

**场景**：流量曲线锯齿严重，想在图上叠加一条平滑趋势线。
**要求**：对 5m 速率序列做 double exponential smoothing（Prometheus 3.x；2.x 老版本函数名为 `holt_winters`），通过子查询提供 range vector。
**预期输出**：与原曲线同标签的平滑序列。

<details><summary>答案</summary>

```promql
# [Prometheus UI，Prometheus 3.x]
double_exponential_smoothing(
  rate(node_network_receive_bytes_total{device=~"ens192|eth0"}[5m])[1h:1m],
  0.3, 0.3
)

# [Prometheus UI，Prometheus 2.x 老版本]
holt_winters(
  rate(node_network_receive_bytes_total{device=~"ens192|eth0"}[5m])[1h:1m],
  0.3, 0.3
)
```

**解析**：平滑因子 sf 与趋势因子 tf 都在 (0,1)，越小越平滑（更迟钝）。和 Q43/Q44 一样，它需要 range vector，所以子查询 `[1h:1m]` 不可少。函数可用性以你 Prometheus 版本为准（官方 functions 文档）。

**常见错误**：直接把 `rate(...[5m])` 塞进去（类型错误）；sf 设到 0.9 以上基本等于没平滑。

</details>

---

## 第六组 · 排错与陷阱（Q53~Q60）

### Q53. 查询返回空：稀疏序列上的 rate

**场景**：某批处理任务每 15 分钟才更新一次 counter，`rate(x[5m])` 永远是空。
**要求**：解释原因并修正。
**预期输出**：能取到速率的查询。

<details><summary>答案</summary>

```promql
# [Prometheus UI] 窗口放大到覆盖至少 2 个样本
rate(batch_job_processed_total[45m])
```

**解析**：`rate` 需要**窗口内至少 2 个样本**才能算斜率。15 分钟一个样本时 `[5m]` 里最多 1 个点，直接无值（不是 0，是空）。经验法则：rate 窗口 >= 4 倍样本间隔。代价是延迟与平滑，稀疏指标的低精度是原理性的，改不了。

**常见错误**：看到空结果以为是"表达式写错"；把窗口拉到 `[1h]` 但间隔其实不均匀（偶发漏抓时仍然偶尔为空）——这类指标更适合 `increase` 长窗口或 pushgateway 场景。

</details>

### Q54. 二元运算结果为空：标签不匹配

**场景**：`kube_pod_container_resource_requests{resource="memory"}` 除以 `kube_node_status_allocatable{resource="memory"}` 想算"占用率"，结果一行都没有。
**要求**：解释空结果的原因，并给出正确方向。
**预期输出**：概念题。

<details><summary>答案</summary>

**解析**：默认二元运算只在**标签集完全一致**的序列间配对。左边标签是 `namespace,pod,container,node,resource,unit`，右边是 `node,resource,unit`——没有任何一对序列标签集相同，输出为空（且**不报错**，这是最阴险的地方）。修正思路：两边先各自 `sum by (node)` 聚合到同一标签集再相除：

```promql
# [Prometheus UI]
sum by (node) (kube_pod_container_resource_requests{resource="memory", unit="byte"})
/ on (node)
kube_node_status_allocatable{resource="memory", unit="byte"}
```

排错技巧：把二元运算的**每一侧单独执行**，肉眼比对两边标签集差在哪，再决定用聚合还是 `on/ignoring/group_left`（见 Q42）。

**常见错误**：以为空结果是"没数据"，去查 exporter；加了 `on(node)` 但左边还有重复 node（多条序列同 node）触发 many-to-one 报错——这时必须先聚合或在多的一侧声明 `group_left`。

</details>

### Q55. 比较运算的 `bool` 修饰符

**场景**：你想在 dashboard 上放一个"是否超阈值"的 0/1 序列，写 `x > 0.8` 得到的却是原始值。
**要求**：解释过滤与 bool 两种模式，写出输出 0/1 的查询。
**预期输出**：超阈值时 1、未超时 0（两种序列都在）。

<details><summary>答案</summary>

```promql
# [Prometheus UI] 过滤模式（默认）：只保留满足条件的序列，值不变
node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.2

# [Prometheus UI] bool 模式：所有序列保留，值变成 0 或 1
(node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < bool 0.2)
```

**解析**：`> bool` / `== bool` 等把比较结果当作 0/1 写回样本值。告警用过滤模式（只对越线的序列报警）；做"健康打分面板"用 bool 模式。**注意**：`bool` 不能用于两个向量之间的集合式比较关键词 `and/or/unless`。

**常见错误**：在告警表达式里加 `bool`——告警对值 0 的序列同样会评估 expr 是否非空，`x > bool 0.8` 恒非空，等于永远触发（值 0 也算 firing），是灾难性写法。

</details>

### Q56. `sum(rate(x))` 与 `rate(sum(x))` 哪个对

**场景**：两个新人为"多副本总 QPS"吵起来：A 写 `sum(rate(x[5m]))`，B 写 `rate(sum(x)[5m])`。
**要求**：判断哪个正确、另一个错在哪。
**预期输出**：概念题。

<details><summary>答案</summary>

**解析**：`sum(rate(x[5m]))` 正确：先对每条序列算速率（处理各自的 counter 回绕），再求和。`rate(sum(x)[5m])` 把 counter 先加总再取速率——加总后的序列只要**任何一个副本重启**（单体回绕），总和就下降，`rate` 会把下降当作一次大回绕丢掉那段样本，结果严重偏低甚至为空。顺序口诀：**先 rate 后聚合**。唯一例外是 bucket（histogram 桶本身语义可加且没有"值回绕污染"问题? 不——bucket 也是 counter 同样会回绕，所以 histogram 同样要先 rate 再 sum，见 Q23 模板）。

**常见错误**：觉得 `rate(sum(x))` "少一层函数更快"——计算量确实略小，但正确性没了；在 recording rule 里埋下这个错，全公司 dashboard 一起错。

</details>

### Q57. `histogram_quantile` 返回 NaN 或怪值

**场景**：应用侧把 bucket 边界 expose 成了字符串排序的 label（或有人手工加了非数值 le），`histogram_quantile` 开始返回 NaN。
**要求**：列出两个最常见根因和排查 SQL。
**预期输出**：概念 + 一条排查查询。

<details><summary>答案</summary>

排查查询——先看原始桶：

```promql
# [Prometheus UI] 检查 le 标签的实际取值
count by (le) (apiserver_request_duration_seconds_bucket)
```

**解析**：两大根因：(1) `le` 的值不是合法浮点数（比如 `le="100ms"` 这种带单位的字符串），插值无法进行，返回 NaN——le 必须是纯数字或 `+Inf`；(2) 聚合丢了 `le` 或序列中缺少 `+Inf` 桶（某些客户端库配置错误），桶不完整时 `histogram_quantile` 的累计关系被破坏。修复都在**应用侧/client 库配置**，PromQL 侧救不了。

**常见错误**：怀疑是 Prometheus 的 bug；试图在 PromQL 里用 `label_replace` 把 "100ms" 洗成 "0.1"——即使洗成功了，桶的累计关系也未必对，属于掩盖问题。

</details>

### Q58. `offset` 与 `[range]` 的语义混淆

**场景**：同事说"我要看 1 小时前的 5 分钟速率"，写了 `rate(x[5m] offset 5m)`。
**要求**：给出正确写法并解释。
**预期输出**：一条查询。

<details><summary>答案</summary>

```promql
# [Prometheus UI] 以 1 小时前为终点、向前取 5 分钟窗口
rate(x_total[5m] offset 1h)
```

**解析**：`offset n` 把**整个取值点**（含 range window）回退 n；`[5m]` 只是窗口宽度。所以"1 小时前的 5 分钟速率"是 `[5m] offset 1h`。而 `[5m] offset 5m` 是"25 分钟前的 5 分钟速率"，与需求不符。Grafana 里还有第三种需求"锚定到面板区间的起点"，那是 `$__range offset ...` 或 `@ start()`（Q7）的事。

**常见错误**：`rate(x offset 1h[5m])`——语法错误，`[range]` 必须紧跟在选择器、`offset` 在其之后：`metric{...}[5m] offset 1h`。

</details>

### Q59. `up == 0` vs `absent()`：三张故障面孔

**场景**：一次故障复盘发现：node-exporter 的进程 OOM 被杀后，`up{instance="172.30.30.22:9100"} == 0` 告警 15 分钟后才发出来；另一次是运维删错了 ServiceMonitor，同样的告警**一条都没发**。
**要求**：解释两种场景分别被什么表达式覆盖，设计成对出现的两条告警。
**预期输出**：两条表达式 + 说明。

<details><summary>答案</summary>

```promql
# [Prometheus UI] 场景 A：target 存在、抓取失败（进程挂了但 job 配置还在）
up{job="node-exporter"} == 0

# [Prometheus UI] 场景 B：序列整个消失（job 配置被删 / relabel 全过滤掉）
absent(up{job="node-exporter"})
```

**解析**：`up == 0` 的前提是 Prometheus **仍在尝试**抓这个 target；配置没了，连 `up` 序列都不复存在，`up == 0` 恒为空——监控的盲区。所以"target 掉线"告警必须成对出现：`== 0` 抓失败、`absent` 抓消失。场景 A 延迟 15 分钟通常是 Prometheus 的 `scrape_timeout`/target 状态机与告警 `for` 叠加所致，与本题主旨无关但值得顺带排查。

**常见错误**：只写 `absent(up)` 不带 job 过滤——任何一个 job 被删都报警且标签里分不清是谁（正则匹配器的标签不会出现在 absent 的输出标签里，见 Q18）。

</details>

### Q60. 序列消失后的"补零"

**场景**：批处理 pod 每天跑完就删，`rate(batch_records_total[5m])` 在 pod 删除 5 分钟后变空，你的"吞吐量"面板出现断线。你想让它在 pod 不存在时显示 0。
**要求**：用 `or vector(0)` 补零，并说明副作用。
**预期输出**：一条查询 + 取舍说明。

<details><summary>答案</summary>

```promql
# [Prometheus UI]
sum(rate(batch_records_total[5m])) or vector(0)
```

**解析**：`or` 取并集：左边为空时右边的 `vector(0)`（无标签、值 0）补进来，面板显示 0 而不是断线。副作用：(1) `vector(0)` 没有任何标签，如果左边 `sum by (job)` 保留了标签，补零行的标签是空的，Grafana 里表现为一条名为 `{}` 的序列；(2) 它掩盖了"指标消失"这个事实本身——如果你还需要对消失报警（Q59），两套逻辑别混用。带标签补零的进阶写法是 `... or on(job) group_left vector(0)`? 不可行（vector(0) 无标签无法 on 匹配），标准做法是对有限的已知标签值用 `label_replace(vector(0), "job", "batch", "", "")` 手工构造。

**常见错误**：`rate(x[5m]) or vector(0)`（左边还带着一堆标签，右边空标签，得到的是"原有序列 + 一条多余的 {} 序列"而不是补零——只有先聚合掉标签才能干净补零）；用它掩盖采集故障——补零只该用于"预期内的生命周期断线"。

</details>

---

## 收尾自查

刷完 60 题后，用下面 5 个问题检验是否真正消化（先想再展开）：

1. 为什么 `rate` 的窗口至少要 4 倍抓取间隔？2 倍行不行？
<details><summary>参考</summary>rate 最少需要 2 个样本，2 倍间隔只是"平均恰好 2 个样本"，任何一次漏抓就空值；4 倍间隔容错 1~2 次漏抓并平滑抖动。窗口大小是"正确性最低要求"与"延迟/平滑"的权衡。</details>

2. `histogram_quantile` 为什么必须保留 `le`？桶为什么可以跨实例 sum？
<details><summary>参考</summary>le 是桶的维度标签，丢了等于把不同边界加在一起，histogram 形状被破坏；桶语义是"<= 边界的累计计数"，天然可加，加完仍是合法 histogram，所以先 rate 再 sum by (le, 维度) 是安全的。</details>

3. `sum(rate(x))` 与 `rate(sum(x))` 在什么条件下结果一样？
<details><summary>参考</summary>所有序列在窗口内都无 counter 回绕（进程都没重启）时，加法和求导可交换，两者近似相等；任何一次回绕都会让后者丢样本。所以永远写前者。</details>

4. 告警表达式里为什么禁止 `< bool`？
<details><summary>参考</summary>bool 模式让所有序列都有值（0 或 1），表达式恒非空，告警会在值为 0 时也触发，等于常开告警。</details>

5. `quantile_over_time` 与 `histogram_quantile` 的区别一句话？
<details><summary>参考</summary>前者对单条序列在时间轴上取分位数（输入 range vector），后者对同一时刻多条 bucket 序列在"值分布"上取分位数（输入带 le 的瞬时向量）。</details>

## 延伸阅读

- PromQL 查询基础：<https://prometheus.io/docs/prometheus/latest/querying/basics/>
- Operators（含 vector matching / bool）：<https://prometheus.io/docs/prometheus/latest/querying/operators/>
- Functions（rate/histogram_quantile/subquery 等）：<https://prometheus.io/docs/prometheus/latest/querying/functions/>
- Histograms and summaries：<https://prometheus.io/docs/practices/histograms/>
- 在线 playground：<https://play.promlabs.com/>
