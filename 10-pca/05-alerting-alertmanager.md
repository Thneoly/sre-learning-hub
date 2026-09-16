# 05 · 告警：alerting rules 状态机与 Alertmanager 路由

> 模块：PCA 备考 ｜ 建议时长：4 小时 ｜ 关联认证：PCA-告警与可视化（14%）

## 学习目标

- 能写出含 for/labels/annotations 的 alerting rule，并解释 pending 与 firing 的状态迁移
- 能逐词解释 group_by/group_wait/group_interval/repeat_interval 的语义并推演一条告警的时间线
- 能配置 inhibition 与 silence，并说明二者与"关闭通知渠道"的区别
- 能描述告警从评估到送达 receiver 经过的管道顺序
- 能用双实例 + gossip 部署 Alertmanager 高可用并解释其一致性模型

## 1. 链路总览：谁负责什么

```
┌─ Prometheus server ─────────┐        ┌─ Alertmanager ──────────────────┐
│ alerting rule 按 group 的    │  HTTP  │ 1. 去重（相同 fingerprint 只留一）│
│ interval 周期评估 expr       │ ─────> │ 2. 路由树匹配 → 进入分组        │
│ 为真 → 生成 alert 对象       │ /api/  │ 3. group_wait 攒批             │
│ （这一步叫"评估"，不叫"通知"）│ v2/    │ 4. inhibition 抑制过滤          │
└─────────────────────────────┘ alerts │ 5. silence 静默过滤             │
                                       │ 6. 限流/重试 → receiver          │
                                       └─────────────────────────────────┘
```

分界线是考试高频：**expr 的求值与状态机在 Prometheus，去重/分组/抑制/静默/重发全在 Alertmanager**。两边各有配置文件（rules vs alertmanager.yml），互不知道对方细节，只靠 HTTP API 和告警身上的 labels 沟通。

## 2. alerting rules：for 与状态机

### 2.1 规则语法

```yaml
# [master] /etc/prometheus/rules/instance-down.yml
groups:
  - name: availability
    interval: 30s            # 该组评估间隔（不写用 global evaluation_interval）
    rules:
      - alert: InstanceDown
        expr: up == 0
        for: 1m              # 连续为真满 1m 才 firing
        labels:
          severity: critical # 追加到告警的 label，参与路由与分组
        annotations:
          summary: "{{ $labels.instance }} 抓取失败（job={{ $labels.job }}）"
          description: "已持续 {{ $value | humanize }} 个抓取周期不可达"
```

模板变量：`$labels.<name>`（规则命中序列的所有 label）、`$value`（expr 的当前值）。规则文件可用 `promtool check rules` 校验（见 03 文件 9 节）。

### 2.2 for 状态机

```
                 expr 为 true
     ┌───────────────────────────┐
     │                           ▼
┌───────────┐   未满 for   ┌───────────┐   持续为真满 for   ┌────────┐
│ inactive  │ ──────────> │  pending  │ ────────────────> │ firing │
└───────────┘             └───────────┘                    └────────┘
     ▲                       │                                  │
     │    expr 变 false       │                                  │ expr 变 false
     └───────────────────────┘                                  │
     ▲                                                          │
     └──────────────────── 发一次 resolved 通知后 ←──────────────┘
```

- **pending**：条件已为真但 for 还没熬满——已在 `/alerts` 页可见，尚未发给 Alertmanager。for 的作用就是过滤瞬时抖动（一次抓取超时不应触发 page）
- **firing**：真正推给 Alertmanager，进入通知管道
- 评估中断的影响：Prometheus 重启会中断 for 计时（2.x 会周期性持久化规则组状态，重启后尽力恢复，以官方文档为准）；scrape 断点让 expr 短暂变假也会重置 pending——这就是 03 文件强调"rate 窗口 ≥ 4×抓取间隔"的告警侧原因
- 不写 for：expr 为真即在第一次评估时直接 firing
- 2.42+ 另有 `keep_firing_for`：条件转假后让告警多保持一段 firing，防止 flapping 告警反复 resolved

### 2.3 在 PromQL 里看告警本身

```promql
# [Prometheus Web UI] 每条活跃告警生成一条 ALERTS 序列（值恒为 1）
ALERTS{alertname="InstanceDown", alertstate="firing"}

# [Prometheus Web UI] for 计时的起点存于 ALERTS_FOR_STATE（Unix 时间戳）
ALERTS_FOR_STATE{alertname="InstanceDown"}
```

`ALERTS` 是普通时序，可以对它做聚合（如 `count by (alertname)(ALERTS{alertstate="firing"})` 做"活跃告警数"面板）。

### 2.4 在 kube-prometheus-stack 里提交规则

```yaml
# [master] kubectl apply -f grafana-down-rule.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: grafana-down
  namespace: monitoring
  labels:
    release: prom-stack       # operator 靠它选择规则，名字不匹配就不生效
spec:
  groups:
    - name: availability
      interval: 30s
      rules:
        - alert: GrafanaDown
          expr: up{job=~"grafana.*"} == 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "Grafana 已不可抓取"
```

## 3. Alertmanager 路由树

### 3.1 配置骨架

```yaml
# [master] alertmanager.yml 骨架（kube-prometheus-stack 里改 secret，见实战演练）
route:
  receiver: default            # 根路由必须兜底：任何告警都能落进一个 receiver
  group_by: [alertname, cluster]
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - matchers: [severity="critical"]
      receiver: oncall
    - matchers: [team="db"]
      receiver: db-team
      group_wait: 10s          # 子路由可覆盖根设置
    - matchers: [alertname="Watchdog"]
      receiver: noop
receivers:
  - name: default
  - name: oncall
  - name: db-team
  - name: noop
inhibit_rules:
  - source_matchers: [severity="critical"]
    target_matchers: [severity~"warning|info"]
    equal: [instance]
```

要点：

- **根路由是兜底**：不能带 matcher（必须匹配一切告警），未被子路由接住的告警都走根的 receiver
- 子路由自上而下匹配，命中一条即停（`continue: false` 默认）；要"同时进两个 receiver"需 `continue: true`
- `matchers` 是 0.22+ 的新语法（等价老写法 `match`/`match_re`，考题可能两种都出现）
- receiver 支持的集成：email、webhook、slack、pagerduty、opsgenie、victorops、wechat 等，每种一段 `*_configs`，同一 receiver 可叠多个渠道

### 3.2 分组四参数语义表（必背）

| 参数 | 作用对象 | 语义 | 默认值 |
| --- | --- | --- | --- |
| group_by | 告警集合 | 标签值**完全相同**的告警合并进同一封通知（列出的标签从分组键中移除比较——准确说：按列出标签的取值分组） | 不可省，必须显式 |
| group_wait | 新分组 | 分组**第一次**通知前的等待，给后续告警留汇合时间 | 30s |
| group_interval | 已通知过的分组 | 该分组**两次通知之间**的最小间隔：新告警加入已发过的组，要等满它才补发 | 5m |
| repeat_interval | 单条内容 | 同样内容**成功通知后**多久重发一遍（提醒"还没处理"） | 4h |

注意两点：group_by 列出的是"用于分组的标签"，即**这些标签取值相同的告警合为一组**（`group_by: [alertname]` = 同名告警合一封）；repeat_interval 实际按 group_interval 的节拍对齐生效，官方建议设为 group_interval 的整数倍。

### 3.3 时间线推演（考试就考这种题）

设 group_wait=30s、group_interval=5m、repeat_interval=4h，某组在 T0 收到告警 A：

```
T0        A 到达，新组开始攒批（pending）
T0+30s    group_wait 到点 → 发出第 1 封通知（含 A）
T0+2m     B 到达，属于同组 → 内容有更新，但不立即发
T0+5m30s  距上封通知已满 group_interval → 发第 2 封（A+B）
T0+5m30s 之后无任何变化、且已成功送达
T0+4h30s  repeat_interval 到点 → 重发同样的（A+B）提醒
```

若 B 是在 T0+29s 到达（group_wait 之内），第 1 封就直接含 A+B——group_wait 的存在意义就是这 30 秒的"顺路捎带"。

## 4. inhibition：上游压制下游

inhibition 规则的语义：当 **source** 告警（满足 source_matchers）存在时，抑制 **target** 告警（满足 target_matchers 且 `equal` 列出的标签取值相同）的通知。

```yaml
# [master] alertmanager.yml 片段：节点挂了就别再喊该节点上的容器告警
inhibit_rules:
  - source_matchers: [alertname="NodeDown"]
    target_matchers: [severity="warning"]
    equal: [instance]
```

经典用例：NodeDown（critical）抑制同 instance 的全部 warning；主库挂了抑制从库的复制延迟告警。inhibition 只影响**通知**，被抑制的告警仍出现在 AM UI 上（带 inhibited 标记）。

## 5. silence：临时静音

silence 是带过期时间的一组 matcher：匹配的告警在有效期内不通知（UI 仍可见）。适用场景：维护窗口、已知问题待修。两种操作方式：

```bash
# [master] UI 方式：port-forward 后打开 http://localhost:9093/#/silences 手工创建
kubectl -n monitoring port-forward svc/prom-stack-kube-prom-alertmanager 9093:9093
```

```bash
# [master] amtool 方式（AM 容器里自带 amtool）
kubectl -n monitoring exec -it alertmanager-prom-stack-kube-prom-alertmanager-0 -- \
  amtool --alertmanager.url=http://localhost:9093 silence add \
  alertname=GrafanaDown --duration=30m \
  --author=cka0007 --comment="维护窗口 30 分钟"
# 查看与过期
kubectl -n monitoring exec -it alertmanager-prom-stack-kube-prom-alertmanager-0 -- \
  amtool --alertmanager.url=http://localhost:9093 silence ls
```

辨析：silence 是"临时、会过期、按 matcher 挡通知"；inhibition 是"常驻规则、由另一条告警的存在触发"；把 receiver 注释掉则是"永久失聪"，几乎总不是正确答案。

## 6. 通知管道与集群 HA

### 6.1 管道顺序

```
POST /api/v2/alerts
   → 去重（fingerprint = 标签集哈希；双 Prometheus 发来的同一告警在此合一）
   → 路由树匹配（决定 receiver 与分组参数）
   → group_wait / group_interval 排程
   → inhibition 过滤
   → silence 过滤
   → 通知集成（失败重试、限流、nflog 记录已发内容与时间）
```

去重在第一步，这正是 02 文件"双 Prometheus HA + 单 AM 集群 = 告警只响一次"的实现位置。nflog（通知日志）是 repeat_interval 判断"已成功发过"的依据。

### 6.2 集群 gossip

Alertmanager 原生支持多实例组网，通过 **gossip 协议**（默认端口 9094，TCP/UDP 同端口）在实例间复制 silences 与 nflog，并协调"由谁发通知"：

```bash
# [任意 Ubuntu VM] 最小双实例实验
mkdir -p /opt/am && printf 'route:\n  receiver: default\nreceivers:\n  - name: default\n' > /opt/am/am.yml
docker network create amnet
docker run -d --name am1 --network amnet -p 9093:9093 \
  -v /opt/am/am.yml:/etc/alertmanager/alertmanager.yml \
  quay.io/prometheus/alertmanager \
  --cluster.listen-address=0.0.0.0:9094 --cluster.peer=am2:9094
docker run -d --name am2 --network amnet -p 9096:9093 \
  -v /opt/am/am.yml:/etc/alertmanager/alertmanager.yml \
  quay.io/prometheus/alertmanager \
  --cluster.listen-address=0.0.0.0:9094 --cluster.peer=am1:9094
curl -s http://127.0.0.1:9093/api/v2/status | grep -o '"status":"[^"]*"'
```

预期：两个实例 `/api/v2/status` 的 cluster status 均为 ready；在 am1 上创建的 silence 会出现在 am2 上。生产形态是 2~3 实例 + 负载均衡，Prometheus 的 alertmanagers 配置指向 LB；**告警发送由集群协商去重**，两个实例不会各发一遍。注意其一致性是最终一致：分区瞬间双实例可能都发一次（gossip 反熵收敛前），这是已知权衡。

## 实战演练：走通一条告警的生命周期

环境：kubeadm 集群 + kube-prometheus-stack（01 文件安装）。

```bash
# [master] Step1 提交 2.4 节的 PrometheusRule，确认已加载
kubectl apply -f grafana-down-rule.yaml
kubectl -n monitoring port-forward svc/prom-stack-kube-prom-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/rules | grep -o '"name":"GrafanaDown"'
```

```bash
# [master] Step2 制造故障：把 Grafana 缩为 0
kubectl -n monitoring scale deployment/prom-stack-grafana --replicas=0
```

浏览器 <http://localhost:9090/alerts>：约一个评估周期后 GrafanaDown 变为 **Pending**（橙色，显示 for 进度）；再等满 1 分钟变 **Firing**（红色）。

```bash
# [master] Step3 在 Alertmanager 侧观察分组与路由
kubectl -n monitoring port-forward svc/prom-stack-kube-prom-alertmanager 9093:9093 &
```

打开 <http://localhost:9093/#/alerts>：能看到告警按 group_by 分组、标注了 receiver；展开可见 annotations 渲染结果。

```bash
# [master] Step4 用 amtool 静音 30 分钟（5 节命令），回到 AM UI 确认显示 silenced
# [master] Step5 恢复并观察 resolved
kubectl -n monitoring scale deployment/prom-stack-grafana --replicas=1
```

恢复后：Prometheus /alerts 页该告警消失，AM 收到 EndsAt 并展示绿色 resolved（或在过期后清掉）。最后删除实验 silence（amtool silence expire 或 UI），保留 PrometheusRule 供后续复习。

预期全程：Pending 出现于故障后 ≤1 个评估周期，Firing 在其后 1m，静音立即生效，恢复后 resolved 一次。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- |---|
| 告警一直在 pending 不 firing | for 太长或 expr 反复真假（rate 断点、抖动） | 缩 for；先修数据断点（窗口 ≥ 4×间隔） |
| PrometheusRule 死活不生效 | 缺 release 标签 / 放错 namespace | 加 `release: prom-stack`，放 monitoring |
| 同一故障收到两封 | 两条规则重复定义，或 AM 双实例没组网 | 合并规则；检查 --cluster.peer 与 gossip |
| 值班告警风暴，一屏同种告警 | group_by 没含区分维度或 group_wait 太短 | group_by 用 alertname+关键维度；group_wait 给足 |
| 修完了还收到旧告警重发 | repeat_interval 内的例行重发是设计行为 | 处理或静默；不要靠重启消音 |
| silence 了还收到 | matcher 没匹配上（label 名或正则不符） | amtool silence ls 核对 matcher 与告警实际标签 |
| inhibition 不生效 | equal 标签在两条告警上取值不同 | 检查两边 label 是否真的一致（instance 大小写/含端口） |
| AM 配置改了不生效 | operator 从 secret 生成配置，直接改文件被覆盖 | 改 `alertmanager-prom-stack-kube-prom-alertmanager` secret 后重启 StatefulSet |

## 自测

1. for: 5m 的告警在条件为真 3 分钟后 Prometheus 重启。重启后它会立刻 firing 吗？
<details><summary>答案</summary>

不会。规则状态会随重启受影响，for 计时基于持续为真的评估历史，中断后从头再攒（2.x 有周期性落盘尽力恢复，但不保证精确续算）。这正是 flapping 环境下告警"起不来"的原因之一，也是 keep_firing_for 出现的背景。
</details>

2. group_wait=0 会怎样？什么时候可以接受？
<details><summary>答案</summary>

每个新分组的第一条告警立即发送，失去"顺路捎带"能力，告警风暴时逐条轰炸。只在告警本身就低频、且要求最低延迟（如 Watchdog 心跳、磁满保护）时可接受；一般保留默认 30s。
</details>

3. 为什么 repeat_interval 建议是 group_interval 的整数倍？
<details><summary>答案</summary>

重发发生在分组的通知节拍上：AM 只在 group_interval 边界检查是否有待发内容，repeat_interval 不对齐时实际重发时间会漂移到下一个边界，行为难以推理。对齐后"4h 重发一次"就是确定的。
</details>

4. inhibition 与 silence 都能少收通知，给出一个"只能用 inhibition"的场景和一个"只能用 silence"的场景。
<details><summary>答案</summary>

只能 inhibition：根因联动是长期稳定的拓扑关系——NodeDown 压制同节点所有容器告警，这要求"只要根因在就自动生效"，silence 做不到自动关联。只能 silence：一次性、提前可知的维护窗口（周六 02:00-02:30 升级 DB），没有"上游告警"可作抑制源，也不该为临时窗口改常驻配置。
</details>

5. 双 Prometheus + 双 Alertmanager 的组合里，"只通知一次"由哪层保证？哪一环节仍可能重复？
<details><summary>答案</summary>

双 Prometheus 的相同告警由 AM 的 fingerprint 去重合一；双 AM 之间由 gossip 协商通知归属（nflog 复制），正常情况只发一次。仍可能重复的环节：网络分区把两个 AM 隔开且各自都认为该自己发（收敛前窗口），这是最终一致系统的固有权衡。
</details>

6. 告警 annotations 里写 `{{ $value }}` 显示 0.3333333333333333。怎么修？
<details><summary>答案</summary>

模板里格式化：`{{ printf "%.2f" $value }}` 或管道 `{{ $value | humanize }}`（后者自动带单位缩放）。annotations 是 Go template，可用全部标准函数与 Prometheus 提供的扩展模板函数。
</details>

## 延伸阅读

- 告警规则语法：<https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
- Alertmanager 概念（分组/抑制/静默/HA）：<https://prometheus.io/docs/alerting/latest/overview/>
- Alertmanager 配置参考（路由树全字段）：<https://prometheus.io/docs/alerting/latest/configuration/>
- 告警实践（for、rate 窗口、通知策略）：<https://prometheus.io/docs/practices/alerting/>
- amtool 文档：<https://github.com/prometheus/alertmanager/blob/main/docs/amtool.md>
