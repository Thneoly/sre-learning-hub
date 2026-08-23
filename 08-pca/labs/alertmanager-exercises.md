# Alertmanager 练习题 15 道

> 模块：08-pca ｜ 建议时长：每题 10~20 分钟，全部完成约 4~5 小时 ｜ 关联认证：PCA-Alerting（核心） / PCA-PromQL（for 语义部分）
>
> 本文按 `_meta/STYLE.md` 的"题库文件模板"（Lab 三件套的豁免形态，仅限 08-pca）组织：配置类题目用下方"通用验证手段"里的 `amtool check-config` / `amtool config routes test` 等只读校验自查。

## 0. 环境准备与验证方式

两种实验环境，按题选用：

**方式 A：练习集群里的 kube-prometheus-stack Alertmanager（A1~A11）**

```bash
# [master] 暴露 Alertmanager UI 与 API
kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093:9093 --address 0.0.0.0 &
# 浏览器访问 http://<master IP>:9093
```

**方式 B：装有 Docker 的 Ubuntu VM 跑独立 Alertmanager（A12~A15，HA 实验推荐）**

方式 B 的启动脚本在 A14 里给出（两个容器 + gossip 组网），先在宿主机装好 `amtool`（A10/A11 也要用）：

```bash
# [Ubuntu VM] 安装 amtool（版本以 GitHub releases 实际为准）
curl -LO https://github.com/prometheus/alertmanager/releases/download/v0.27.0/alertmanager-0.27.0.linux-amd64.tar.gz
tar xzf alertmanager-0.27.0.linux-amd64.tar.gz
sudo install -m 0755 alertmanager-0.27.0.linux-amd64/amtool /usr/local/bin/amtool
amtool --version
```

**通用验证手段**（本文件反复用到）：

- `amtool check-config <file>`：改完配置先跑它，语法不过 reload 会被拒绝；
- `amtool config routes test --config.file=<file> k=v ...`：给定标签组合，打印命中的 receiver，是调试路由树最省事的工具；
- `curl http://127.0.0.1:9093/api/v2/status`、`/api/v2/silences`：无 UI 也能看状态。

每题先自己写配置/命令，再展开答案。答案含"解析"与"常见错误"对比。

---

## 第一组 · 路由树设计（A1~A3）

### A1. 按 severity 与团队分流的基础路由树

**场景**：告警统一进 Alertmanager，要求：`severity=critical` 发 PagerDuty（值班电话）；`severity=warning` 发 Slack 的 `#alerts-warn`；`team=network` 的告警（无论级别）走网络组自己的接收器 `net-ops`；其余全部进兜底 `default`。
**要求**：写一份完整的 alertmanager.yml 全局配置（含 receivers 骨架与 group 默认参数），并画出路由树。
**预期输出**：`amtool check-config` 通过；用 A3 的 `config routes test` 能验证各标签组合命中正确 receiver。

<details><summary>答案</summary>

```yaml
# [master 或 Ubuntu VM，保存为 alertmanager.yml]
global:
  resolve_timeout: 5m

route:
  receiver: default
  group_by: ['alertname', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - matchers:
        - severity = "critical"
      receiver: pagerduty
      continue: false
    - matchers:
        - team = "network"
      receiver: net-ops
      continue: false
    - matchers:
        - severity = "warning"
      receiver: slack-warn
      continue: false

receivers:
  - name: default
  - name: pagerduty
    # webhook_configs / pagerduty_configs 按实际填写，骨架从略结构上如：
    # pagerduty_configs:
    #   - routing_key_file: /etc/alertmanager/pd.key
  - name: net-ops
  - name: slack-warn
    # slack_configs:
    #   - api_url_file: /etc/alertmanager/slack.url
    #     channel: '#alerts-warn'
```

路由树结构：

```
                   ┌────────────────────┐
 进来的告警 ──────▶ │ root (default)     │
                   └─────────┬──────────┘
                 ┌───────────┼─────────────┐
                 ▼           ▼             ▼
         severity=critical  team=network  severity=warning
           → pagerduty       → net-ops     → slack-warn
```

**解析**：三个要点。(1) 根路由的 `receiver: default` 是**兜底**，没有任何子路由命中的告警走这里；(2) 子路由**自上而下匹配，命中第一个即停**（除非该分支写了 `continue: true`），所以顺序就是优先级——critical 放最前，避免一条 critical 告警同时带 `team=network` 标签时被下面的分支抢走；(3) matchers 用的是新式标签匹配语法（`severity = "critical"`），旧式 `match: {severity: critical}` 已废弃，新配置一律用 matchers。

**常见错误**：把 `severity=warning` 分支写在 `team=network` 之前（网络组的 warning 告警会被 Slack 分支截走）；忘写根 receiver，`amtool check-config` 直接报错。

</details>

### A2. `continue: true`——一条告警进多个接收器

**场景**：安全团队要求：**所有** `severity=critical` 的告警除走正常值班通道外，还要抄送一份到 `security-audit` 接收器做归档。
**要求**：在 A1 的树上加一条"命中后继续往下匹配"的分支，实现 critical 告警双投递。
**预期输出**：critical 告警同时出现在 `pagerduty` 和 `security-audit` 两个 receiver。

<details><summary>答案</summary>

```yaml
# [master 或 Ubuntu VM，alertmanager.yml 的 route 段]
route:
  receiver: default
  group_by: ['alertname', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - matchers:
        - severity = "critical"
      receiver: security-audit
      continue: true          # 命中后继续尝试下面的兄弟分支
    - matchers:
        - severity = "critical"
      receiver: pagerduty
      continue: false
    - matchers:
        - team = "network"
      receiver: net-ops
    - matchers:
        - severity = "warning"
      receiver: slack-warn

receivers:
  - name: default
  - name: security-audit
  - name: pagerduty
  - name: net-ops
  - name: slack-warn
```

**解析**：默认行为是"命中即停"；`continue: true` 让当前告警在**同一层**继续向下一个兄弟分支匹配。注意 continue 只影响**同级**的后续分支，不影响"命中父分支后进入子分支"的语义。双投递的每一份都独立走 receiver 的 group 逻辑（分组、去重按 receiver 分别计算）。

**常见错误**：以为在 pagerduty 分支上加 `continue: true` 就够了——那会继续匹配到 `team=network` 或 `warning` 分支，而不是"再抄送一份"；continue 是"继续找下一个能匹配的兄弟"，不是"再发一份给指定的人"，所以必须把抄送分支单独列在前面。

</details>

### A3. 用 `amtool config routes test` 验证路由命中

**场景**：A1 的配置改了三轮，你不再相信肉眼。
**要求**：分别验证三组标签：`severity=critical team=network`、`severity=warning team=network`、`severity=info`，说出各自命中哪个 receiver（基于 A2 的配置）。
**预期输出**：三条命令各打印一个（或多个）receiver 名。

<details><summary>答案</summary>

```bash
# [master 或 Ubuntu VM]
amtool config routes test --config.file=alertmanager.yml severity=critical team=network
# → security-audit, pagerduty（continue 双投递）

amtool config routes test --config.file=alertmanager.yml severity=warning team=network
# → net-ops（team 分支在 warning 分支之前）

amtool config routes test --config.file=alertmanager.yml severity=info
# → default（无分支命中，走根 receiver）
```

**解析**：`config routes test` 把给定标签喂给路由树，打印最终 receiver，是路由配置 CI 里也常用的自检命令（可以写进脚本对拍预期输出）。从输出反推规则：匹配是**顺序敏感**的——第二组若把 warning 分支挪到 team 之前，结果就变成 slack-warn。

**常见错误**：标签参数写成 `severity="critical"`（shell 会带引号进 amtool，匹配失败，应写 `severity=critical`）；测试用的标签集与真实告警不一致（真实告警常带 `alertname`、`namespace` 等，可能改变 group_by 分组结果——分组不影响命中，但影响聚合行为）。

</details>

---

## 第二组 · group 参数语义（A4~A7）

### A4. `group_by`：分组键选多细

**场景**：`KubePodCrashLooping` 告警把 `pod` 放进了 group_by，结果一次网络抖动触发 40 个 pod 告警，Slack 收到 40 条独立消息，值班被刷屏。
**要求**：调整 group_by，让"同类告警聚成一条消息"；并说明 `group_by: ['']` 的特殊含义。
**预期输出**：修改后的 route 段 + 概念说明。

<details><summary>答案</summary>

```yaml
# [master 或 Ubuntu VM，alertmanager.yml 的 route 段]
route:
  receiver: default
  group_by: ['alertname', 'namespace']   # 去掉 pod / instance 这类高基数标签
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
```

**解析**：分组键 = "取这些标签值相同的告警合并成一条通知"。`group_by: ['alertname', 'namespace']` 意味着同一 namespace 里同名的告警（不管哪个 pod）合成一封，消息里列出各 pod 明细。反方向的极端是特殊值 `group_by: ['...']`（三个点作为唯一元素）：按**所有**标签分组，等于完全禁用聚合，每条告警单独发——只适合告警量极低或上游系统自带合并的场景。经验法则：group_by 里只放"你想在通知标题层面区分"的维度，pod/instance 这类放在消息正文里。

**常见错误**：把高基数标签（pod、instance、device）放进 group_by 后抱怨"分组没生效"；以为 group_by 支持正则——它是**精确的标签名列表**，标签值的正则要在 matchers 里做。

</details>

### A5. `group_wait`：第一波通知前等多久

**场景**：现在的 `group_wait: 30s` 让值班的 PagerDuty 总要比故障晚半分钟响；但改成 0s 后，一次 apiserver 抖动会连着发 5 条独立 critical（同组的后续告警还没来得及合并）。
**要求**：解释 group_wait 的准确语义，给出"重要通道快、次要通道稳"的双通道取值建议。
**预期输出**：概念 + 两段参数。

<details><summary>答案</summary>

`group_wait` 语义：**一个新分组的第一条告警到达后，先等 group_wait 再发首波通知**，等待期间到达的同组告警合并进这波。它只作用于"组的第一次通知"。

```yaml
# [master 或 Ubuntu VM，双通道不同节奏]
route:
  receiver: default
  group_by: ['alertname', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h
  routes:
    - matchers:
        - severity = "critical"
      receiver: pagerduty
      group_wait: 0s        # critical 立即响，牺牲合并度换速度
    - matchers:
        - severity = "warning"
      receiver: slack-warn
      group_wait: 2m        # warning 不急，多等一会聚齐再发一条
```

**解析**：group_wait 是"通知延迟"与"合并率"之间的旋钮：值越大，一条消息装的告警越多、消息越少，但首告警越晚。注意继承规则：子路由未设置 group_wait/group_interval/repeat_interval 时**继承父路由的值**（官方文档对三个字段都明确写了 "If omitted, child routes inherit..."）——本例 critical 分支显式写 `group_wait: 0s` 覆盖根路由的 30s，warning 分支写 2m 同理，什么都不写的分支沿用 30s。想全树统一就在根路由改一处。

**常见错误**：以为 group_wait 也作用于"组的后续通知"——那是 group_interval 的事（A6）；在根路由调小 group_wait 期待只加速 critical——会拖垮所有告警的合并率。

</details>

### A6. `group_interval`：同组第二波通知的最小间隔

**场景**：一条 warning 聚合通知发出后 1 分钟，同组又来了新告警，值班又收到一条——你希望同组通知至少间隔 5 分钟。
**要求**：解释 group_interval 语义并配置；说明"新告警在 group_interval 内到达"与"在 group_interval 之外到达"分别什么时候发通知。
**预期输出**：配置 + 时间线说明。

<details><summary>答案</summary>

```yaml
# [master 或 Ubuntu VM]
route:
  receiver: default
  group_by: ['alertname', 'namespace']
  group_wait: 30s
  group_interval: 5m     # 同一组的两次通知之间至少隔 5 分钟
  repeat_interval: 4h
```

时间线（首波通知在 T0 发出）：

```
T0        首波通知（group_wait 之后）
T0+2m     新告警 A 加入该组 ──▶ 不立即发，进入待发
T0+5m     到达 group_interval ──▶ 发出包含 A 的第二波
T0+7m     新告警 B 加入 ──▶ 下一次发送不早于 T0+10m（对第二波再计 5m）
```

**解析**：`group_interval` 是**同一分组两次通知之间的最小间隔**，在首波通知发出后开始计时；期间加入的新告警会攒着，到点一起发。它防刷屏，代价是新告警最多被压 group_interval 才可见——这也是为什么 critical 通道常配小的 group_interval。

**常见错误**：把 group_interval 当"重复提醒间隔"用（那是 repeat_interval，A7）；配置 `repeat_interval` 小于 `group_interval`——repeat 只能在 group_interval 的节拍上被检查，不足一个节拍的 repeat_interval 会被**向上取整到 group_interval 的下一个整数倍**（官方文档明确说明），写小了没有效果。

</details>

### A7. `repeat_interval`：同一批告警多久重发一次

**场景**：夜里一条 critical 一直没人处理，PagerDuty 只响一次不够；改成 `repeat_interval: 5m` 后值班每 5 分钟被同一个问题轰炸一次。
**要求**：解释 repeat_interval 语义、它与 group_interval 的关系、以及"什么情况下不会重发"。
**预期输出**：概念 + 推荐配置。

<details><summary>答案</summary>

```yaml
# [master 或 Ubuntu VM]
route:
  receiver: default
  group_by: ['alertname', 'namespace']
  group_wait: 30s
  group_interval: 5m
  repeat_interval: 4h    # 4 小时没恢复、没人处理，再提醒一次
```

**解析**：`repeat_interval` 针对的是**已经通知过、且仍在 firing 的告警**：距上一次通知超过 repeat_interval 后，把这组当前仍活跃的告警再发一遍。三个关键细节（均来自官方 configuration 文档）：(1) repeat 只在**每个 group_interval 节拍**被检查，所以 repeat_interval 应设为 group_interval 的整数倍，不是整数倍时会被**向上取整**到 group_interval 的整数倍；(2) 距上次通知后**如果有新告警触发或有旧告警恢复**，按新通知处理（走 group_interval 逻辑），repeat 计时不启动——即"有变化的组优先按变化通知，没变化的组才按 repeat 提醒"；(3) 告警被 inhibit 或 silence 挡住时本来就不发通知，更谈不上重发。经验值：critical 通道 1h~2h，warning 通道 4h 以上，且为 group_interval 的整数倍。

**常见错误**：想用 repeat_interval 实现"更快的第二波通知"——那是 group_interval；设 `repeat_interval` 小于 `group_interval`（被向上取整，等于没设小）；以为改 repeat_interval 会影响已发出的通知节奏——只影响之后的重发。

</details>

---

## 第三组 · inhibition 抑制（A8~A9）

### A8. critical 抑制同名的 warning

**场景**：Prometheus 规则库里同一个问题常常同时配了 critical 和 warning 两档（表达式相同、severity 不同），结果值班一次收到两条几乎一样的告警。
**要求**：写 inhibit_rules：当同 `alertname`、同 `namespace` 存在 `severity=critical` 时，抑制 `severity=warning` 的告警。
**预期输出**：inhibit_rules 片段 + 验证方法。

<details><summary>答案</summary>

```yaml
# [master 或 Ubuntu VM，alertmanager.yml]
route:
  receiver: default
  group_by: ['alertname', 'namespace']
  routes: []

inhibit_rules:
  - source_matchers:
      - severity = "critical"
    target_matchers:
      - severity = "warning"
    equal: ['alertname', 'namespace']

receivers:
  - name: default
```

验证：向 Alertmanager API 投递两条只差 severity 的告警，然后查 suppressed：

```bash
# [Ubuntu VM 或 port-forward 后的 master]
curl -s -X POST http://127.0.0.1:9093/api/v2/alerts -H 'Content-Type: application/json' -d '[
  {
    "labels": {"alertname": "HighMemory", "namespace": "prod", "severity": "critical"},
    "annotations": {"summary": "mem high"}
  },
  {
    "labels": {"alertname": "HighMemory", "namespace": "prod", "severity": "warning"},
    "annotations": {"summary": "mem high"}
  }
]'
sleep 2
curl -s http://127.0.0.1:9093/api/v2/alerts | python3 -m json.tool | grep -A3 '"status"'
# warning 那条的 status 里应出现 "state": "suppressedBy"
```

（不同版本 API 对 inhibited 的展示字段略有差异，以你版本的 HTTP API 文档为准；UI 上则是 warning 告警带 inhibited 标记。）

**解析**：inhibition 三要素：`source_matchers`（谁有权抑制）、`target_matchers`（谁会被抑制）、`equal`（两边**必须相等**的标签——不等就抑制不了，防止 A 机器的 critical 把 B 机器的 warning 也压掉）。注意抑制只作用于**通知**，被抑制的告警仍然存在于 alert 列表里，只是不发通知。

**常见错误**：忘了写 `equal: ['alertname']`，导致任何 critical 出现时全集群所有 warning 全部静默；把抑制方向写反（target 写成 critical）。

</details>

### A9. 节点宕机时抑制该节点上的所有告警

**场景**：节点 `172.30.30.22` 宕机瞬间，会同时爆出 NodeDown、KubeletDown、PodDown、ContainerCPUHigh……几十条。其实值班只需要知道"这台机器挂了"。
**要求**：写 inhibit_rules：`NodeDown`（severity=critical）存在时，抑制**同一节点**上其余 severity 更低的告警。
**预期输出**：inhibit_rules 片段 + 设计要点。

<details><summary>答案</summary>

```yaml
# [master 或 Ubuntu VM，alertmanager.yml]
inhibit_rules:
  - source_matchers:
      - alertname = "KubeNodeDown"
      - severity = "critical"
    target_matchers:
      - severity =~ "warning|info"
    equal: ['node']        # 两边的告警都必须带 node 标签且取值相同
```

**解析**：与 A8 的差别是**source 和 target 是不同的 alertname**，所以 equal 里绝不能放 `alertname`（放了就永远不等，规则失效），取而代之用 `node` 作为"同一台机器"的关联键。前提是你的告警标签里有 `node`（kube-prometheus 的默认规则基本都有；自制规则要在 alerting rule 的 labels 里补）。级联抑制（A 抑 B、B 抑 C）不会传递：inhibition 只按规则一次生效。

**常见错误**：equal 用 `instance`——NodeDown 的 instance 是 node-exporter 的 `IP:9100`，而 pod 类告警的 instance 是 pod 名，永远对不上；以为"target 告警缺 node 标签规则就整体跳过"——官方文档明确：**缺失标签与空值标签语义相同**，若 source 与 target **都缺** equal 里的标签（空=空），抑制规则反而会生效，可能把不相干告警一并压掉。所以 equal 的标签必须挑 source 和 target **都必然存在**的标签，只在一侧存在的标签只会让规则失效。

</details>

---

## 第四组 · silence 静默（A10~A11）

### A10. 用 amtool 开一个维护窗口的 silence

**场景**：今晚 22:00~24:00 要重启 worker2 的 kubelet 和一批 pod，预计会触发一串告警。你不想手工等它们来了再逐条处理。
**要求**：用 amtool 提前创建一个 2 小时的 silence，覆盖 `node="worker2"` 的所有告警，注明作者与原因；并验证它已生效。
**预期输出**：命令 + silence ID 返回 + 查询确认。

<details><summary>答案</summary>

```bash
# [master 或 Ubuntu VM，Alertmanager 已 port-forward 到 127.0.0.1:9093]
amtool --url=http://127.0.0.1:9093 silence add \
  --author="cka000001" \
  --comment="维护窗口：worker2 kubelet 升级，预计 2h" \
  --duration=2h \
  node="worker2"

# 返回形如：9e3b1c8f-....  即 silence ID

# 验证：列出当前 silences
amtool --url=http://127.0.0.1:9093 silence query
```

**解析**：silence 的 matcher 语义与告警标签匹配一致：`node="worker2"` 会静默所有带 `node="worker2"` 标签的告警，**不限 alertname**。`--duration=2h` 从创建时刻起算，到期自动失效（不需要人去关，这是它比注释掉告警规则优雅的地方）。作者和注释是硬性好习惯：所有 AM 都要求非空 comment，否则命令直接被拒绝。

**常见错误**：写成 `amtool silence add` 忘了 `--url`（amtool 没有服务端可连，报错退出）；matcher 写成 `node=worker2` 不带引号在某些 shell 下被拆词（建议始终 `key="value"`）；维护结束想提前解除见 A11。

</details>

### A11. silence 的查询、解除与匹配语义

**场景**：维护提前结束了，要把 A10 的 silence 提前干掉；另外你想静默所有 `job="batch-oneoff"` 且 pod 名以 `oneoff-` 开头的告警。
**要求**：给出解除指定 silence 的命令、带正则的创建命令，并解释"silence 匹配是子集匹配"的含义。
**预期输出**：三条命令 + 概念说明。

<details><summary>答案</summary>

```bash
# [master 或 Ubuntu VM] 1) 按 ID 提前过期（解除）silence
amtool --url=http://127.0.0.1:9093 silence expire 9e3b1c8f-....

# [master 或 Ubuntu VM] 2) 带正则的 silence
amtool --url=http://127.0.0.1:9093 silence add \
  --author="cka000001" \
  --comment="一次性批任务，告警无意义" \
  --duration=8h \
  job="batch-oneoff" pod=~"oneoff-.*"

# [master 或 Ubuntu VM] 3) 查询（可按 matcher 过滤）
amtool --url=http://127.0.0.1:9093 silence query pod=~"oneoff-.*"
```

**解析**："子集匹配"指：**silence 的每个 matcher 都必须能在告警标签上匹配成功**，但告警可以携带 silence 没提的额外标签。即 `node="worker2"` 静默的是"所有标签里 node=worker2 的告警"，不管它还有什么别的标签。正则 matcher 用 `=~`，与 PromQL 一样是全锚定正则（`oneoff-.*` 自动当 `^oneoff-.*$` 处理）。expire 不是删除而是**立即过期**，历史记录保留可审计。

**常见错误**：以为 silence 与 inhibition 是一回事——inhibition 是配置驱动的**自动**抑制（只要 source 告警在就生效），silence 是**人工、有时间窗**的静默；以为正则不用 `.*` 也能做前缀匹配（`=~"oneoff-"` 等价 `^oneoff-$`，只匹配恰好等于这个字符串的标签值）；一个 silence 里塞多个不相干 matcher 想表达"或"——多个 matcher 之间是**与**，想要"或"就开两个 silence。

</details>

---

## 第五组 · `for` 语义辨析（A12~A13）

### A12. 没有与有 `for: 5m` 的行为差异

**场景**：同一条内存告警，两个版本：`for` 缺省（等于 0）与 `for: 5m`。值班反馈前者半夜频繁响（很多是瞬时毛刺），后者偶尔漏报短促故障。
**要求**：写两条对比规则，解释 pending→firing 状态机、以及 Prometheus 重启对两者的影响。
**预期输出**：规则 YAML + 状态机说明。

<details><summary>答案</summary>

```yaml
# [master，PrometheusRule / 规则文件片段]
groups:
  - name: mem
    interval: 30s
    rules:
      - alert: HighMemNoFor
        expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.1
        labels:
          severity: warning
      - alert: HighMemFor5m
        expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.1
        for: 5m
        labels:
          severity: warning
```

状态机：

```
expr 为真 ──▶ pending（活跃但未达 for 时长）──▶ 持续为真满 for ──▶ firing ──▶ AM 发通知
   ▲                                                      │
   └──────────── expr 在 for 未满时变假 ◀──────────────────┘        expr 变假 → resolved
```

观察两个状态：

```promql
# [Prometheus UI]
ALERTS{alertname="HighMemFor5m", alertstate="pending"}
ALERTS{alertname="HighMemFor5m", alertstate="firing"}
```

**解析**：`for` 是 PromQL 条件必须**连续为真**的时长，作用是把"毛刺"过滤成"持续问题"——代价是所有真故障也至少延迟 for 才通知。注意两点：(1) "连续"是以**每次规则求值**为准，求值之间条件短暂回落后再次为真，计时器**清零重算**；(2) pending 状态**不持久化**——Prometheus 重启后所有 pending 计时归零，正在 pending 的告警要重新攒满 for；firing 状态重启后由 expr 立即重算恢复（条件仍真则马上回到 firing，不发重复通知的保证较弱，这是 A14 HA 要处理的问题）。

**常见错误**：把 `for` 写在 `labels:` 同级时缩进错位（它是 rule 的顶级字段，与 expr/labels 平级）；以为 `for: 5m` 能消除"重启毛刺告警"——它只能过滤短于 5m 的持续毛刺，节点真抖 6 分钟照样响。

</details>

### A13. `for` 的实际等待时间与 `keep_firing_for`

**场景**：规则组 `interval: 30s`、`for: 5m`。值班测得从"条件变真"到"收到通知"实际等了 5m40s，质疑 for 不准。另外有个告警的条件每 4 分钟真假翻转一次，永远凑不满 for，问题实际很严重。
**要求**：解释 5m40s 的来源；用 `keep_firing_for` 让间歇满足的条件也能触发（Prometheus 2.42+）。
**预期输出**：解释 + 规则片段。

<details><summary>答案</summary>

等待时间的组成：

```
条件变真 ──(≤ interval)──▶ 第一次求值为真 ──(for=5m，跨 10 次求值)──▶ 达标 ──(≤ interval)──▶ 下一次求值转为 firing
实际延迟 ∈ [for, for + 2*interval]，30s 间隔下最大 6m
```

```yaml
# [master，Prometheus 2.42+ 支持 keep_firing_for]
groups:
  - name: flapping
    interval: 30s
    rules:
      - alert: IntermittentHighMem
        expr: node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes < 0.1
        for: 10m
        keep_firing_for: 30m
        labels:
          severity: warning
```

**解析**：(1) `for` 计时锚定在**求值时刻**而不是条件物理上变真的时刻，所以从"条件变真"到"firing"的延迟是 for 加上最多两个求值间隔（首个捕获 + 达标后转 firing 各一次）。想让 for 更精确就调小规则组 `interval`，代价是求值开销。(2) `keep_firing_for: 30m` 的语义：条件曾经满足并触发过一次 firing 后，**接下来 30m 内条件即使间歇性为假，告警也保持 firing 不发 resolved**——专治"永远凑不满 for / 反复 resolve 又 firing"的振荡型故障。字段名以前叫 `x_for`? 不——它自 2.42 引入就叫 keep_firing_for，老版本无此功能（以你版本 release notes 为准）。

**常见错误**：拿秒表量 for 发现多了几十秒就怀疑是 bug；用 `for: 30m` 想覆盖间歇故障——for 要求**连续**为真，间歇型永远触发不了，必须换 keep_firing_for 思路或改表达式（如用 `max_over_time(...[30m])` 把条件先摊平）。

</details>

---

## 第六组 · 高可用（A14~A15）

### A14. 用 Docker 起两个 Alertmanager 组成 gossip 集群

**场景**：单点 Alertmanager 挂了告警就断送，你要在 Ubuntu VM 上验证两节点的 AM 集群怎么建、怎么确认它们互相认识。
**要求**：docker 起两个 AM（同一最小配置），用 `--cluster.peer` 组网，通过 API 确认集群 ready 且互为 peer。
**预期输出**：两个容器 Up，`/api/v2/status` 显示 peers 数为 2。

<details><summary>答案</summary>

```bash
# [Ubuntu VM] 1) 最小配置
mkdir -p /tmp/am
cat > /tmp/am/alertmanager.yml <<'EOF'
route:
  receiver: default
  group_by: ['alertname']
  group_wait: 10s
  group_interval: 1m
  repeat_interval: 2h
receivers:
  - name: default
EOF
amtool check-config /tmp/am/alertmanager.yml

# [Ubuntu VM] 2) 组网启动
docker network create amnet
docker run -d --name am1 --network amnet \
  -v /tmp/am/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro \
  -p 9093:9093 prom/alertmanager:v0.27.0 \
  --cluster.listen-address=0.0.0.0:9094

docker run -d --name am2 --network amnet \
  -v /tmp/am/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro \
  -p 9095:9093 prom/alertmanager:v0.27.0 \
  --cluster.listen-address=0.0.0.0:9094 \
  --cluster.peer=am1:9094

# [Ubuntu VM] 3) 验证集群状态
sleep 5
curl -s http://127.0.0.1:9093/api/v2/status | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d['cluster']['status'], len(d['cluster']['peers']))"
# 期望输出: ready 2
curl -s http://127.0.0.1:9095/api/v2/status | python3 -c \
  "import json,sys; d=json.load(sys.stdin); print(d['cluster']['status'], len(d['cluster']['peers']))"
# 期望输出: ready 2
```

**解析**：AM 的 HA 靠** gossip 协议**（默认 TCP+UDP 9094）同步两类状态：silences 和 **notification log**（谁已经发过什么通知）。每个节点都完整持有这些状态，任何一台存活就能继续工作。`--cluster.listen-address` 指定本节点的 gossip 监听地址，`--cluster.peer` 指定初始伙伴（只需指向至少一个已在集群中的节点，其余拓扑靠 gossip 自行传播）。生产上的 kube-prometheus-stack 用 StatefulSet + headless service 自动生成 peer 列表，原理相同。

**常见错误**：两个容器都映射宿主机 9094（冲突）；只给 am2 配 peer、am1 却把 gossip 端口监听在 127.0.0.1（对方连不进来，集群永远 1 节点）；在容器间用宿主机 IP 互指（同一 docker network 内应直接用容器名）。

</details>

### A15. 双 AM 下的重复通知从哪来

**场景**：你在 Prometheus 里配了两个 alertmanager target（am1、am2）。问题：Prometheus 会不会把同一告警发两遍？什么时候真的会收到两条一样的通知？
**要求**：给出 Prometheus 的 alerting 配置；解释去重机制与失效场景；用 A14 的环境实际制造一次"gossip 断裂"并观察。
**预期输出**：配置 + 实验 + 结论。

<details><summary>答案</summary>

```yaml
# [Ubuntu VM，prometheus.yml 片段]
alerting:
  alertmanagers:
    - static_configs:
        - targets: ['am1:9093', 'am2:9093']
```

（跑在 Docker 里的 Prometheus 用容器名；混合环境改成对应 IP:9093 / IP:9095。）

去重机制与失效场景：

```
Prometheus ──同一告警──▶ am1 ─┐
           ──同一告警──▶ am2 ─┴─▶ 谁先记录 notification log 并 gossip 同步，
                                 另一台发现自己"已发过"就不再发
gossip 正常:  收到 1 份
gossip 断裂:  am1、am2 各自都认为该自己发 ──▶ 收到 2 份（重复）
```

实验——制造 gossip 断裂再投递告警：

```bash
# [Ubuntu VM] 1) 切断 am1<->am2 的 gossip（用 iptables 在网络命名空间外简单粗暴地暂停一个节点再恢复也行，这里直接停掉 am2 再改网络）
docker network disconnect amnet am1

# [Ubuntu VM] 2) 分别向两台投同一条告警（模拟两边都收到）
curl -s -X POST http://127.0.0.1:9093/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"HADupTest","severity":"critical"}}]'
curl -s -X POST http://127.0.0.1:9095/api/v2/alerts -H 'Content-Type: application/json' \
  -d '[{"labels":{"alertname":"HADupTest","severity":"critical"}}]'

# [Ubuntu VM] 3) 恢复网络，观察两台的状态合并
docker network connect amnet am1
sleep 10
curl -s http://127.0.0.1:9093/api/v2/status | python3 -c \
  "import json,sys; print(json.load(sys.stdin)['cluster']['status'])"
```

**解析**：Prometheus 确实把**每个 firing 告警都推给所有**配置的 AM——去重不做在发送侧，而做在 AM 集群内部（notification log 经 gossip 复制，"这条通知已由某节点发出"是全局共识）。因此 HA 的正确形态是：N 台 AM 对等部署，Prometheus 全部指向；偶发脑裂/分区时可能双发，需要接收端（PagerDuty、Slack 等）自身的去重能力兜底，这是官方文档明确说明的已知特性而非 bug。元监控建议盯 `amcluster_members_running`? 实际指标名以 `/metrics` 输出为准（`grep amcluster /metrics`），成员数长期小于部署数说明 gossip 异常。

**常见错误**：在 Prometheus 前面再套一层 VIP/负载均衡把 AM"主备化"——违背设计，AM 集群本身就是全活架构，LB 反而制造单点；以为重复通知说明 HA 配错了就改回单节点——正确处置是接收端兜底 + 监控 gossip 健康度。

</details>

---

## 收尾自查

1. 告警从"条件变真"到"值班手机响"，中间经过哪几个组件、各承担什么延迟？
<details><summary>参考</summary>Prometheus 规则求值（规则组 interval）→ for 计时 → firing 后经Push推送到所有 AM → AM 路由匹配 + group_wait → receiver 投递。总延迟 = 求值间隔 + for + group_wait + 传输，调 SLA 时四个旋钮都要看。</details>

2. inhibition、silence、路由不匹配，三者都能让告警"不发通知"，区别是什么？
<details><summary>参考</summary>路由不匹配=这条告警不属于这个接收器（可能走别的接收器）；inhibition=配置驱动的自动抑制，source 消失即解除；silence=人工创建、带过期时间的全局静默。排错时先分清是哪一种在起作用（UI 上分别显示不同状态）。</details>

3. 为什么 `equal` 里放一个 target 告警没有的标签，抑制规则会整体失效？
<details><summary>参考</summary>equal 要求该标签在 source 和 target 上都存在且相等；缺失即不相等，规则保守地不抑制——宁可漏抑制也不错杀。</details>

4. group_wait / group_interval / repeat_interval 分别治理哪种"多通知"？
<details><summary>参考</summary>group_wait 治"同组首波能不能再等更多告警加入"；group_interval 治"同组第二波别太快"；repeat_interval 治"没人处理的告警多久再提醒"。</details>

5. AM 集群脑裂时的正确心理预期是什么？
<details><summary>参考</summary>可能收到重复通知（notification log 无法达成共识），接收端需具备去重能力；这是官方文档写明的已知行为，不是配置错误。</details>

## 延伸阅读

- Alertmanager 配置（路由/group/inhibit/silence 全字段）：<https://prometheus.io/docs/alerting/latest/configuration/>
- Notification pipeline（group_wait/interval/repeat 时序）：<https://prometheus.io/docs/alerting/latest/notifications/>
- amtool 命令行：<https://prometheus.io/docs/alerting/latest/amtool/>
- Alertmanager clustering 设计文档：<https://github.com/prometheus/alertmanager/blob/main/docs/high-availability.md>
- 告警规则里的 for 与 keep_firing_for：<https://prometheus.io/docs/prometheus/latest/configuration/alerting_rules/>
