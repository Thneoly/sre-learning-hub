# 04 · 无责复盘与 Runbook：把故障变成资产

> 模块：13-sre-methodology ｜ 建议时长：4 小时 ｜ 关联认证：PCA-告警（runbook_url 注解联动）/ —（方法论本身无考点，SRE 岗位面试必问）

## 学习目标

- 能解释 blameless 原则的认知科学依据，并区分"无责"与"无问责"
- 能独立产出一份含时间线、根因、促发因素、行动项的合格 postmortem
- 能按 SMART 标准拆分和跟踪行动项，识别"加强监控"这类伪行动项
- 能按七要素写一份可通过"凌晨 3 点测试"的 runbook，并与告警双向链接
- 能画出 alert → runbook → drill → postmortem → action item 的知识沉淀闭环

## 1. 无责复盘（blameless postmortem）

### 1.1 为什么"不怪人"反而更快逼近真相

复盘的首要目标是**改进系统**，不是追责。人有合理的自保本能：一旦预感被追责，信息输出会立刻收敛——"当时我以为""我不确定是我改的"。根因藏在被隐藏的细节里，复盘就退化成表演。

Blameless 的两条默认假设要公开写进复盘制度：

1. **每个当事人都基于当时可得的信息，做了在其职责范围内合理的选择**。换成你在那把椅子上、带着那个监控水平和那个交付压力，大概率做同样的事。
2.**要问"系统为什么允许这个错误造成故障"**，而不是"谁犯了错"。人总会犯错，可靠系统在设计上就假定这一点（这正是第 5 章混沌工程的前提）。

注意分辨：**blameless ≠ accountability-free**。行动项必须有明确 owner 和期限（第 3 节），失职的线在"是否遵守了流程"，不在"是否犯了技术错误"。SRE Book 第 15 章的原话大意：无责复盘让人愿意提供"对预防复发至关重要的细节"。

### 1.2 触发与时限

| 触发条件（满足其一） | 时限 |
|---------------------|------|
| 用户可见的 SEV1/SEV2 事件 | 72 小时内开会，5 个工作日内出报告 |
| 错误预算单日烧掉 ≥ 10% | 同上 |
| page 响应超时 / 升级链断裂（流程事故） | 同上 |
| near-miss：靠运气没变成故障 | 鼓励自愿复盘，同样 blameless |
| 例行变更失败但有惊无险 | 低成本轻量复盘（模板可裁剪） |

near-miss 是性价比最高的复盘素材：故障的学费已经预付，只是没发货。一个团队复盘会的数量里，near-miss 占比高是好信号。

## 2. 复盘模板与时间线写法

### 2.1 模板

````markdown
<!-- [任意节点] 存放于 git 仓库 docs/postmortems/，一事件一文件 -->
# Postmortem · INC-1024 Service 无后端导致访问失败

- 日期：2026-08-20 ｜ 撰写人：值班 SRE ｜ 状态：草稿/评审中/已结项
- 级别：SEV2 ｜ 持续：40 分钟（14:05–14:47）｜ 影响：fault-ep 命名空间 100% 流量

## 影响与 SLI 结算
- 用户影响：约 30% 门户请求失败
- SLI 口径：fault-web 非错误响应占比（5m 窗口）
- SLO 结算：当日错误预算消耗 11.2%（阈值 1%/日），触发发版双人评审

## 时间线（只记事实与时间戳）
| 时间 | 事件 | 来源 |
|------|------|------|
| 13:58 | 变更：fault-web-svc 的 selector 被误改（事后从审计日志确认） | audit log |
| 14:05 | 监控：SLI 跌至 0，快火燃烧率告警 Firing | Prometheus |
| 14:07 | primary ack，定级 SEV2，IC 认领 | 值班频道 |
| 14:12 | OL 复现：curl 000，Pod 全部 Ready | 演练记录 |
| 14:21 | 定位：svc selector 与 pod label 不匹配（describe 对比） | 排障记录 |
| 14:32 | 修复：selector 改回 app: fault-web | 变更记录 |
| 14:45 | 验证：SLI 回 100%，观察 2 分钟无复发 → 关闭 | Grafana |

## 根因（root cause）
Service selector 值被打错（fault-web-typo），Endpoints 为空，
流量无后端可转发。变更未经 CI 校验直接 kubectl apply。

## 促发因素（contributing factors，通常 2~4 条）
1. svc 变更走人工 kubectl，无流水线校验 selector 合法性
2. Endpoints 空值没有专门的告警，探测靠用户路径的 SLI（MTTD 7 分钟尚可）
3. 演练环境与生产共用同一套 YAML 手改习惯

## 做得好的
- 燃烧率告警 2 分钟内 page，无人工发现延迟
- IC/OL 分工保持，时间线完整

## 做得差的
- 定位耗时 14 分钟，其中 9 分钟在看 Pod 自身（先怀疑应用后怀疑接线）
- 变更无回滚预案，靠现场推理修复

## 行动项（见第 3 节跟踪表，此处引用编号 A1–A3）
````

### 2.2 时间线写法与 MTTR 分解

时间线只写"何时发生了什么"，不写"为什么"、不写评价。据此分解出可对比的指标：

```
故障全程                 ────────────────────────────────────
  MTTD          MTTA         定位               修复          验证
  ├────────────├────────────┼──────────────────┼─────────────┤
  T0        SLI告警Firing  ack              根因确认       止血完成     恢复确认
（本例）    +7min          +2min            +9min          +11min        +13min
```

- **MTTD**（Mean Time To Detect）：探测体系的成绩，第 2 章 SLI/告警直接决定
- **MTTA**（Ack）：值班体系的成绩，第 3 章升级阶梯直接决定
- **定位 + 修复**：runbook 与自动化水平的成绩，本章的正题

每次复盘把三段耗时记进表格，季度横比——这是"可靠性工程有没有进步"的最诚实答案。

## 3. 行动项跟踪

合格行动项的四条硬标准（SMART 的运维版）：

1. **单一 owner**：一个人名，不是"我们组"
2. **有期限**：具体到日期，"尽快"等于没有
3. **可验证**：完成后能用命令/看板/流程证明，"加强监控"不可验证
4. **分层投放**：P0 立即做（本周）、P1 本季度、P2 进 backlog 定期重审

按防御层次归类投放，避免全部堆在"预防"：

| 层次 | 问的问题 | 例 |
|------|----------|-----|
| Prevent 预防 | 怎么让诱因不再发生 | svc 变更进 CI，流水线校验 selector 必须命中现存 label |
| Detect 探测 | 再发生怎么更快发现 | 增加 `kube_endpoint_address_available == 0` 告警（A2） |
| Mitigate 止血 | 发现后怎么少伤人 | runbook 把修复压到 3 分钟；一键回滚脚本 |

跟踪机制（缺一不可）：

- 行动项进 issue tracker 打 `postmortem` label，postmortem 文档只引用编号
- 每季度一次"复盘行动项清点会"：过期未完成的当场重新排期或明示放弃并写理由
- 结项判据 = 验证命令的输出，不是 owner 说"做完了"

伪行动项对照：

| 伪 | 真 |
|----|----|
| 加强监控 | A2：增加 Endpoints 空告警，owner 张三，8/27 前，验证 expr 返回 0 条活跃 |
| 提高大家意识 | A3：9 月 onboarding 培训加入 svc 变更案例 15 分钟，课件链接入库 |
| 增加人手 | 拆成具体的自动化项（A1）后再谈人力 |

## 4. Runbook 写作规范

Runbook（操作手册）是"告警响起时照着做就能活"的文档。七要素齐全才算合格：

```text
<!-- runbook 骨架，七要素齐全才算合格 -->
1. 触发条件   哪条告警/什么症状（写告警名与现象原文）
2. 影响       不处理会怎样、影响谁、SLO 关联
3. 前置       需要什么权限、在哪台机器、依赖什么工具
4. 诊断步骤   编号命令 + 每步"预期输出"与"不符合时跳哪"
5. 修复步骤   编号命令，幂等可重复
6. 验证       怎么确认修好了（具体命令与期望值）
7. 回退       修复无效或恶化时怎么退回安全态
（外加）升级路径：卡在第 N 步超过 X 分钟 → 找谁
```

三条写作纪律：

1. **凌晨 3 点测试**：想象值班者刚被叫醒、认知能力减半，文档必须让他不需要"理解"只需要"执行"——凡是"结合实际情况灵活判断"的措辞都是失败。
2. **命令可复制**：真实可执行的命令 + 预期输出，占位符用尖括号并在开头解释（如 `<pod-name>`）。写完自己在干净终端逐条粘贴跑一遍。
3. **与告警双向链接**：告警注解带 `runbook_url`，runbook 首行写触发它的告警名——半夜被叫醒的人从任何一端都能找到另一端。

## 5. 知识沉淀闭环

```
        ┌─────────────────────────────────────────────────────┐
        │                                                     │
        ▼                                                     │
  告警(page) ──runbook_url──→ runbook ──演练验证──→ 熟练度     │
        │                         │                          │
        │ 触发                     │ 沉淀新步骤/修正           │
        ▼                         ▼                          │
     事件处置 ──────────────→ postmortem ──行动项──→ tracker ─┘
                                   │
                                   └──高频手工步骤──→ 自动化脚本（toil 治理，第 1 章）
```

闭环里每条边都会断，防腐机制：

| 断点 | 防腐 |
|------|------|
| 告警没有挂 runbook | 新告警上线 checklist 必含 runbook_url 非空 |
| runbook 过期（命令已失效） | 每个 runbook 头部带 `owner` 与 `reviewed_at`；季度演练时顺带 review，跑不通就修 |
| postmortem 写完没人看 | 新人 onboarding 必读近 10 篇；季度清点会通读未结项 |
| 行动项烂尾 | 第 3 节跟踪机制 |
| 知识只在个人脑中 | 晋升/述职材料要求引用自己沉淀的 runbook/自动化 |

靶场的 `FIXES.md` 就是这套闭环的半成品样本：现象 → 排查路径 → 根因 → 修复命令，只缺 owner/reviewed_at 和 tracker 编号——本课实战演练会把它补全。

## 实战演练：把第 3 章的演练变成资产

承接第 3 章的 break-endpoints 演练，产出两份资产并挂上告警。环境：kubeadm 集群 + 靶场。

### Step 1 写 runbook（对照 FIXES.md 前 自己先写）

```bash
# [master] 建目录并撰写（内容见下方模板，先自己排障时记录的步骤填进去）
mkdir -p ~/learning-hub/runbooks
vim ~/learning-hub/runbooks/service-endpoints-empty.md
```

````markdown
<!-- [任意节点] ~/learning-hub/runbooks/service-endpoints-empty.md -->
# Runbook · Service 有 Pod 却无后端（Endpoints 为空）

- owner: 平台组 ｜ reviewed_at: 2026-08-22 ｜ 触发告警: ServiceEndpointsEmpty

## 1. 触发条件
- 告警 `ServiceEndpointsEmpty` Firing；或现象：curl ClusterIP 返回
  connection refused / 超时，但 `kubectl get pods` 全部 Running/Ready。

## 2. 影响
该 Service 的全部流量无后端可转发，用户侧 100% 失败；
SLI（非错误响应占比）跌至 0，快火燃烧率告警会随后触发。

## 3. 前置
- [master] 或任何有 kubeconfig 的节点；kubectl 读权限 + svc 编辑权限。

## 4. 诊断步骤
1. 确认 Endpoints 状态（预期有地址；为空即本 runbook 场景）：
   kubectl -n <namespace> get endpoints <svc-name>
2. 对比 selector 与 Pod label（90% 的空 Endpoints 是这两行对不上）：
   kubectl -n <namespace> describe svc <svc-name> | grep -A2 Selector
   kubectl -n <namespace> get pods --show-labels
   - 预期：selector 的 k=v 能在 Pod 的 labels 里原样找到
   - 不符合 → 跳修复步骤 1
3. 若 label 匹配仍为空 → 检查 readinessProbe 是否一直失败：
   kubectl -n <namespace> describe pod <pod-name> | grep -A5 Readiness
   - 不符合 → 本 runbook 不覆盖，转 runbook pod-not-ready

## 5. 修复步骤
1. 用 label 实际值修正 selector（幂等，可重复执行）：
   kubectl -n <namespace> patch svc <svc-name> -p \
     '{"spec":{"selector":{"app":"<真实label值>"}}}'

## 6. 验证
1. kubectl -n <namespace> get endpoints <svc-name>   # 预期出现 Pod IP 列表
2. kubectl -n <namespace> run verify --image=curlimages/curl:8.10.1 \
     --restart=Never --rm -it -- curl -s -o /dev/null -w '%{http_code}\n' \
     http://<svc-name>.<namespace>.svc.cluster.local/    # 预期 200
3. Grafana SLI 回 100% 并保持 5 分钟。

## 7. 回退
patch 后仍不通或影响扩大：恢复 selector 原值（变更前从
`kubectl get svc -o yaml` 备份），然后按升级路径找人，不要连续盲试。

## 升级路径
诊断步骤 2 卡住超过 10 分钟 → page 二线；影响面跨命名空间 → 升 SEV1。
````

写完执行"凌晨 3 点测试"：把集群注入 `sudo bash scripts/faults/break-endpoints.sh`，只看这份 runbook 从头走到尾，任何一步让你犹豫就在文档里补预期输出。

### Step 2 用演练数据填 postmortem

把第 3 章 Step 3 的时间线与 Step 4 的 5 问答案，填进第 2.1 节模板，另存为 `~/learning-hub/docs/postmortems/INC-<日期>-endpoints.md`。硬性检查三处：时间线是否只有事实；根因是否落在"系统为什么允许"（selector 变更无校验）而不是"谁改的"；行动项是否全部有 owner/期限/验证命令。

### Step 3 给告警挂上 runbook_url

```yaml
# [master] endpoints-empty-rule.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: endpoints-empty
  namespace: monitoring
  labels:
    release: prom
spec:
  groups:
    - name: service-endpoints
      interval: 30s
      rules:
        - alert: ServiceEndpointsEmpty
          expr: kube_endpoint_address_available{namespace="fault-ep"} == 0
          for: 1m
          labels:
            severity: critical
          annotations:
            summary: "{{ $labels.endpoint }} 的 Endpoints 为空"
            runbook_url: "file:///root/learning-hub/runbooks/service-endpoints-empty.md"
```

```bash
# [master] 应用后重新注入验证全链路
kubectl apply -f endpoints-empty-rule.yaml
sudo bash scripts/faults/break-endpoints.sh
kubectl -n monitoring port-forward svc/prom-kube-prometheus-stack-prometheus 9090:9090 &
sleep 150 && curl -s http://localhost:9090/api/v1/alerts | grep -o '"runbook_url":"[^"]*"'
sudo bash scripts/faults/break-endpoints.sh --restore
```

预期：告警 Firing 且 annotations 里带着 runbook 链接（练习环境用 file:// 指向本地文件；生产中应为 wiki/git 的 http 地址）。`kube_endpoint_address_available` 来自 kube-prometheus-stack 自带的 kube-state-metrics，无需额外部署。

### Step 4 收尾

三份产物入库（runbook、postmortem、PrometheusRule yaml），行动项登记进你的 tracker 并设一个 7 天后的清点提醒。至此第 3 章"事件响应"的产出完成了向资产的转化。

## 常见坑

| 症状 | 原因 | 解法 |
|------|------|------|
| 复盘会变成追责大会 | 没有公开的 blameless 制度，或高层旁听施压 | 主持人开场宣读两条默认假设；管理层看报告不进会场 |
| 根因永远写着"人为失误" | 停在第一层追问 | 连问"系统为什么允许"：为什么变更能绕过校验？为什么探测要 7 分钟？ |
| 行动项 3 个月后全部过期 | 无清点机制 | 季度清点会 + tracker label，过期必须重排期或明示放弃 |
| runbook 写完没人用 | 通篇概念无命令，或命令过期 | 凌晨 3 点测试；季度演练时顺带 review；带 reviewed_at 字段 |
| 告警响了找不到文档 | 缺 runbook_url 双向链接 | 新告警 checklist 含 runbook_url 非空；runbook 首行写告警名 |
| 同类故障反复发生，复盘结论相同 | 行动项只堆"预防"层 | 三层投放：prevent/detect/mitigate 至少各一条 |

## 自测

<details><summary>1. "无责"复盘里，一个工程师确实违反了变更流程（跳过了审批直接 apply）。复盘该怎么写？</summary>

分两层写。技术层照常 blameless：把"流程可被绕过"作为系统缺陷写进促发因素，行动项指向让绕过变难或变显眼（准入控制、审计告警）。纪律层不进复盘文档：是否违规、如何处理是管理动作，走单独渠道。混在复盘里会导致两个坏结果——当事人防御性沉默，以及团队把复盘会等同于问责会。blameless 针对的是"诚实的错误"，不是"故意的违章"，但后者的处理也不该占用改进系统的复盘。
</details>

<details><summary>2. 为什么行动项要求 prevent/detect/mitigate 三层投放，而不是全力预防？</summary>

预防成本边际递增且永远不完美（第 5 章混沌工程的前提就是故障必然发生）。只做预防的清单一旦漏防就全裸奔；detect 层保证漏防的故障被快速看见（压 MTTD），mitigate 层保证看见后伤害可控（压 MTTR）。三层组合是用工程手段对冲"下一个故障一定出乎预料"这个事实。
</details>

<details><summary>3. runbook 的"凌晨 3 点测试"具体怎么执行？合格的判据是什么？</summary>

在认知降级的模拟条件下走文档：可以是深夜值班时的真实使用，也可以是让一个不熟悉该组件的同事只凭文档处置（不给口头提示）。合格判据：全程不需要向文档外的人提问；每条命令粘贴即执行；每个分叉点（预期输出不符合时跳哪）都有明确指引；结束时能独立完成验证小节。任何一步产生"这里该怎么办"的犹豫，就是文档要补的地方。
</details>

<details><summary>4. FIXES.md 与 runbook 的差别是什么？把 FIXES.md 直接当 runbook 用有什么问题？</summary>

FIXES.md 是面向"学习排障"的教材：按故障类型展开排查路径，教的是定位方法论；runbook 是面向"止血"的作战卡：按告警触发，要求幂等修复命令、回退与升级路径俱全、有时限约束。直接拿教材当作战卡，值班者会去"理解原理"而不是"执行动作"，MTTR 拉长；而且 FIXES.md 没有 owner/reviewed_at/告警双向链接，不满足沉淀闭环的防腐要求。正确关系：FIXES.md 是原料，runbook 是从中裁出的作战卡。
</details>

<details><summary>5. 一个 near-miss（差点成灾）值不值得开复盘？成本怎么控制？</summary>

值得，且往往性价比高于真实故障复盘：故障的根因链已经完整暴露，只是最后没有击中用户。成本控制靠轻量形态：30 分钟会、模板裁剪到时间线+根因+行动项三节、不强制 Scribe。判断标准不是"有没有用户受影响"，而是"同样的链路下次还会不会出现"——出现了且击中用户就是 SEV1。团队若只在真实故障后复盘，等于只从学费全款支付的课程学习。
</details>

## 靶场联动：靶场是这些方法论的练习场

`scripts/faults/FIXES.md` 的 12 个故障就是 12 道 runbook 习题：随机抽一个注入，先自己排障并随手记时间线，然后照第 4 节七要素把它写成 runbook，最后与 FIXES.md 对应章节 diff——**差异处就是你的知识缺口，也是你 runbook 里该补的预期输出**。进阶玩法：给每个 runbook 标 reviewed_at，隔一个季度重注入一遍做"文档防腐测试"，跑不通的命令当场修。第 5 章会把这套"注入 → 验证文档"的循环自动化、体系化。

## 延伸阅读

- SRE Book 第 15 章 Postmortem Culture：https://sre.google/sre-book/postmortem-culture/
- SRE Workbook · Postmortem Culture（含模板）：https://sre.google/workbook/postmortem-culture/
- Google 官方 Postmortem 模板：https://sre.google/sre-book/postmortem-culture/#example-postmortem
- kube-state-metrics 指标参考（Endpoints 类指标）：https://github.com/kubernetes/kube-state-metrics/tree/master/docs
