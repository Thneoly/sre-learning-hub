# 02 · LLM 辅助排障方法论

> 模块：AIOps/LLM 运维（15）｜ 建议时长：2 小时 ｜ 前置：01 章 + 靶场 scripts/faults 可用 ｜ 关联认证：CKA-故障排除（方法论叠加项）

## 学习目标

- 能解释"把 LLM 当初级同事"这个心智模型，以及由它推出的三条使用纪律
- 能默写排障提问四要素模板（现象/环境/已尝试/约束），并说明缺每一项会发生什么
- 能把 LLM 辅助排障与故障注入靶场结合，走完"注入→盲测→提问→验证→修复→复盘"的完整闭环
- 能在真实排障中执行"AI 建议必须验证后执行"的纪律，区分可直接执行的只读命令与必须人工重写的变更命令
- 能从 prompt 模板库（T1~T6）里选出适配当前排障阶段的那一个

## 1. 心法：把 LLM 当"初级同事"

对 LLM 最贴切的心智模型：一个**读遍了所有公开文档、但从来没碰过你这套环境的初级同事**。它有三个特征，每个特征推出一条纪律：

```
初级同事的特征                使用纪律
─────────────────────────    ─────────────────────────
读过所有文档，但没见过       → 给足上下文：现象、环境、
你的内网和这套系统的怪癖       版本、已尝试的事，一样不能少

很会说话，永远语气自信       → 要求它给"验证命令"而不是
（哪怕在编）                  "结论"：能验证的才采信

不会为结果负任何责任         → 你验证、你决策、你执行：
                              变更命令必须人工重写后再敲
```

分工因此非常清楚：你是现场指挥，它是查资料快、写初稿快、不知疲倦的助理。

一个反例和正例的对比（同一个故障，两种问法）：

```
反例提问（把 LLM 当搜索引擎）：
  "Pod 起不来怎么办"

结果：得到一篇通用教程，列出 15 种可能，你逐条试，比不用还慢。

正例提问（把 LLM 当初级同事）：
  "kubectl get pods 输出如下（粘贴）。
   describe 的 Events 段如下（粘贴）。
   这是 kubeadm v1.29 + Calico 单 master 集群。
   已确认：节点 Ready、镜像 tag 在 registry 存在、其他 ns 的 Pod 正常。
   约束：我不能重启节点。
   请给出按概率排序的 Top3 假设，每个假设配一条只读验证命令。"

结果：第一轮就收敛到 2~3 个可验证假设。
```

## 2. 排障提问四要素模板

四要素：**现象（Symptom）/ 环境（Environment）/ 已尝试（Tried）/ 约束（Constraint）**。

```
# [任意] 提交给 LLM 的排障初诊 prompt 模板（T1）
【角色】你是 Kubernetes 值班工程师的助手，只做分析和给验证命令。
【现象】<看到的告警/输出原文，粘贴命令输出而不是转述>
【环境】<集群形态：kubeadm v1.29 单 master + Calico；应用语言/中间件；
        变更背景：最近 2 小时是否有发布/配置改动>
【已尝试】<已经查过什么、结果是什么；这一栏专门防止 AI 重复给你查过的方向>
【约束】<不能重启节点 / 必须在 30 分钟内恢复 / 不能影响其他租户……>
【要求】1. 用一段话复述你理解的问题（确认我们没有理解偏差）；
        2. 给出按可能性排序的 Top3 假设；
        3. 每个假设配一条只读验证命令；
        4. 明确标注哪些信息是你不知道、需要我补充的。
        禁止给出变更类命令。
```

为什么每一项都不能省：

| 缺失要素 | 典型后果 |
|---|---|
| 现象只转述不贴原文 | 你的转述已经带了你的预判，AI 顺着你的预判跑偏 |
| 环境（版本/CNI/变更背景） | 它按默认环境回答；CNI 是 Calico 还是 Flannel，排网络故障的命令完全不同 |
| 已尝试 | 每一轮都把查过的方向重新建议一遍，对话在原地打转 |
| 约束 | 给出"重启节点"这种对你当前完全不可接受的方案，浪费一轮 |

另外两条通用规则：

- **贴输出，不贴截图描述**。命令的原始输出（`kubectl describe` 的 Events 段、日志原文）信息密度远高于你的总结。
- **一次对话只处理一个故障**。多个故障混在一个 prompt 里，模型的假设会互相污染。

## 3. 与故障注入靶场结合的实战流程

靶场（`scripts/faults/`，12 个 `break-*.sh`）是练这套方法论的完美陪练：故障可重复注入、可随时恢复、有标准答案（FIXES.md）可对照。完整流程：

```
注入故障 → 盲测 → 证据采集 → T1 提问 → 验证循环 → 根因 → 修复 → 复盘 → 知识沉淀
   │         │        │          │          │
 sudo bash  只看脚本  get/      填四要素   AI 的每条假设
 break-xx   打印的   describe/  模板，    都配一条命令，
           "告警    logs/      贴原始    你跑命令拿真实
           现象"    events     输出      输出回填再问
```

两个靶场特有的纪律：

1. **盲测**：注入后只看脚本打印的"告警现象"，不要把 FIXES.md 对应章节贴给 LLM——否则你练的是复制粘贴。FIXES.md 用来在事后对照"你的排障路径 vs 标准路径"差在哪。
2. **修复不用 `--restore` 交作业**：`--restore` 是保险丝，不是答案。正确顺序是手工定位→手工修复→再用 `--restore` 核对你的修复是否等价。

## 4. "AI 建议必须验证后执行"的纪律

这条纪律落到操作层面是一个两列清单，值班时照着分拣：

| AI 给出的命令类型 | 处理方式 |
|---|---|
| 只读查询：`kubectl get/describe/logs/top`、`journalctl`、`cat`、`ss`、`tcpdump`（观察模式） | 核对语法后可直接执行；对生产环境的 tcpdump 注意加 `-c` 限包数和 `-i` 限接口 |
| 诊断执行：`kubectl exec` 进容器看状态 | 审查命令内容后再执行；exec 本身有副作用风险 |
| 一切变更：`delete/patch/scale/set image/apply`、`systemctl restart`、改内核参数 | **禁止复制粘贴**。理解它为什么这么改→自己重写→走变更流程→执行 |

为什么"人工重写"而不是"人工看一眼"？因为重写迫使你逐字理解每个参数。看一眼就粘贴，等于把决策权交还给了一个不为结果负责的东西——第 1 章第 3 节的红线就是这么被突破的。

警惕幻觉的三个高发点：**编造不存在的字段/参数**（如 `kubectl get pods --output=wideplus`）、**编造不存在的镜像 tag 或 Helm chart 版本**、**引用过时的机制**（比如按已被移除的参数给排障建议）。对策统一：涉及版本相关的结论，让它标注"这个结论适用的版本范围"，再对照官方文档。

## 5. Prompt 模板库

六个模板覆盖排障全生命周期。占位符用 `<>` 标出，用的时候删掉尖括号填实。

```
# [任意] T2 · 事件/日志解读：把原始输出变成结构化线索
【角色】你是 Kubernetes 排障助手。
【输入】以下是 kubectl describe 的 Events 段（或容器日志原文）：
<paste>
【要求】1. 逐条解读每个事件说明什么、是否异常；
        2. 按时间线给出"故事线"：先发生了什么、后发生了什么；
        3. 指出最可疑的 1~2 条并说明理由；
        4. 列出你还缺哪些信息。不要给修复建议，先看清事实。
```

```
# [任意] T3 · 假设排序：把可能性变成可执行的排查计划
【背景】<一句话故障描述 + 关键证据摘要>
【要求】列出 Top5 假设，用表格输出，列：
        假设 | 支持证据 | 反对证据 | 验证命令（只读） | 验证成本(低/中/高)
        没有证据支持的假设也要列出，但证据列写"无"。
```

```
# [任意] T4 · 修复方案评审：执行前让 AI 当红队
【背景】<根因 + 我打算执行的修复命令>
【要求】1. 这个修复是否直达根因，还是只是掩盖症状；
        2. 列出 3 个可能被这个修复破坏的东西；
        3. 给出验证修复成功的命令；
        4. 给出回滚方案（具体命令）；
        5. 如果有更保守的替代方案，写出来。
```

```
# [任意] T5 · 复盘草稿：故障处理完的 10 分钟内生成初稿
【输入】故障时间线：<我做了什么，几点几分>
        根因：<一句话>
        影响：<持续时长/受影响面>
【要求】按无指责复盘模板输出：摘要/时间线/根因/触发条件/
        做得好的/待改进/行动项（每条有 owner 和 deadline）。
        行动项里必须包含一条知识沉淀项。
```

```
# [任意] T6 · 反向考核：让 LLM 出题考你（备考期最好用）
【角色】你是 Kubernetes 故障出题官。
【环境】kubeadm 单 master + Calico，Ubuntu 22.04。
【要求】出一道 <网络/调度/存储/证书> 方向的排障题：
        只给"值班现象"，不给原因。我给出排查思路后，
        你只判断方向对错并给下一步提示，不要直接给答案。
```

## 实战演练：一次完整的 LLM 辅助排障

用 `break-imagepull.sh` 完整走一遍。假设靶场脚本在 master 的 `~/learning-hub/scripts/faults/`（其他路径自行替换）。

**Step 1 注入，进入盲测。**

```bash
# [master] 注入镜像拉取故障
sudo bash ~/learning-hub/scripts/faults/break-imagepull.sh
```

脚本最后只打印"告警现象"（Pod 拉镜像失败相关的现象描述），此时不要打开 FIXES.md 的对应章节。

**Step 2 采集证据（先自己看一眼，别急着问）。**

```bash
# [master] 值班第一眼：看到什么记什么
kubectl -n fault-imagepull get pods -o wide
```

预期输出：

```
NAME                        READY   STATUS         RESTARTS   AGE   IP       NODE      ...
fault-web-9b7d8f6c5-x2p4b   0/1     ErrImagePull   0          40s   <none>   worker1   ...
```

```bash
# [master] 采集 describe 的 Events 段（喂给 LLM 的核心证据）
kubectl -n fault-imagepull describe pod -l app=fault-web | sed -n '/Events:/,$p'
```

预期输出（节选）：

```
Events:
  Type     Reason     Age                From               Message
  ----     ------     ----               ----               -------
  Normal   Scheduled  2m                 default-scheduler  Successfully assigned fault-imagepull/fault-web-9b7d8f6c5-x2p4b to worker1
  Normal   Pulling    98s (x4 over 2m)   kubelet            Pulling image "nginx:1.27.99-notexist"
  Warning  Failed     96s (x4 over 2m)   kubelet            Failed to pull image "nginx:1.27.99-notexist": manifest for nginx:1.27.99-notexist not found
  Normal   BackOff    88s (x5 over 2m)   kubelet            Back-off pulling image "nginx:1.27.99-notexist"
  Warning  Failed     88s (x5 over 2m)   kubelet            Error: ImagePullBackOff
```

**Step 3 用 T1 模板提问。** 把上面两段输出填进四要素模板（环境填"kubeadm v1.29 + Calico 单 master；该 deployment 1 小时前刚做过一次镜像变更；约束：不许删 namespace 重建"），整段提交给你可用的 LLM。

**Step 4 验证 AI 的假设。** 以下是一份典型的 AI 回复（示例输出，你实际得到的措辞会不同，验证动作一致）：

> 假设 1（高）：镜像 tag 不存在或拼写错误。验证：`kubectl -n fault-imagepull get deploy fault-web -o jsonpath='{.spec.template.spec.containers[0].image}'`，并确认该 tag 在 registry 中存在。
> 假设 2（中）：registry 网络不通或限流。验证：看 Events 里失败原因是 `not found` 还是 `timeout/refused`，前者不是网络问题。
> 假设 3（低）：缺少 imagePullSecrets。验证：`kubectl -n fault-imagepull describe pod` 里是否有 `pull secrets` 相关告警；公共 Docker Hub 镜像通常不需要。

逐条执行验证：

```bash
# [master] 验证假设 1：当前镜像 tag 到底是什么
kubectl -n fault-imagepull get deployment fault-web -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

预期输出：

```
nginx:1.27.99-notexist
```

```bash
# [worker1] 验证假设 1 后半段：候选 tag 在 registry 里到底存不存在
sudo crictl pull nginx:1.27-alpine
```

预期输出（存在则能拉下来，形如 `Image is up to date for sha256:...`）：

```bash
# [master] 验证假设 2/3：失败原因是 not found，不是 timeout，也不是 Unauthorized
kubectl -n fault-imagepull describe pod -l app=fault-web | grep -E 'Failed|secret'
```

结论：假设 1 成立、假设 2/3 被证据排除——这一步的每条命令输出，就是第 1 章说的"验证留痕"。

**Step 5 修复（人工重写，走 T4 评审更稳）。**

```bash
# [master] 修复：把镜像指回验证过存在的 tag（crictl pull 已证明其存在）
kubectl -n fault-imagepull set image deployment/fault-web fault-web=nginx:1.27-alpine
kubectl -n fault-imagepull rollout status deployment/fault-web --timeout=120s
kubectl -n fault-imagepull get pods
```

预期输出：rollout 提示 `deployment "fault-web" successfully rolled out`，Pod 变为 `Running 1/1`。

**Step 6 核对与收尾。**

```bash
# [master] 用 --restore 核对自己的修复与标准答案是否等价（此时幂等，不会再改坏）
sudo bash ~/learning-hub/scripts/faults/break-imagepull.sh --restore
kubectl delete ns fault-imagepull
```

最后用 T5 模板让 LLM 出复盘初稿，自己改定稿。整套流程做成可留痕的完整报告，就是本模块 lab 的作业形态。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 每轮对话 AI 都重复建议已查过的方向 | prompt 里没有"已尝试"栏 | 四要素一个不省；长对话每隔 3~4 轮把最新状态重新总结进 prompt |
| AI 给的 kubectl 参数报错 unrecognized | 编造参数/跨版本混用 | 把 `kubectl version` 的 Client/Server 版本写进"环境"栏；报错原文回贴让它自纠 |
| AI 一口咬定某个根因，语气非常肯定 | LLM 按语言概率生成，"自信"与"正确"无关 | 永远要求配验证命令；没有验证输出的结论当假设处理 |
| 从聊天窗口复制变更命令直接执行 | 没有分拣纪律 | 用第 4 节两列清单分拣；变更类一律重写+走流程 |
| 一次 prompt 塞了三个故障 | 想省 token | 一个故障一个会话；上下文污染后宁可重开 |
| 把 FIXES.md 答案贴给 LLM 让它"讲解" | 练习走了捷径 | 靶场训练必须盲测；FIXES.md 只做事后对照 |

## 自测

1. 为什么"贴命令原始输出"比"转述现象"效果好得多？转述会引入哪类系统性偏差？

<details><summary>答案</summary>

转述是人的预判过滤器：你决定贴什么、怎么描述时，已经隐含了"我觉得问题在哪"。LLM 会顺着你的框架补全，你的偏见被它的流利文笔放大。原始输出没有这个过滤器，还能提供转述时容易丢弃的细节（时间戳、重复次数、事件顺序）。
</details>

2. "已尝试"栏在多轮长对话里有衰减问题吗？怎么处理？

<details><summary>答案</summary>

有。模型对长上下文开头/结尾之外的内容注意力弱，早期写过的"已尝试"到第 6 轮可能被忽略，出现重复建议。处理：每隔几轮把"当前已知事实 + 已排除假设"重新汇总成一段贴进新 prompt（或干脆重开会话），把状态压缩进上下文的高权重位置。
</details>

3. AI 建议你 `kubectl delete pod` 让它重建，这属于两列清单的哪一列？什么前提下它可以被接受？

<details><summary>答案</summary>

变更列，禁止直接复制执行。它可能直达根因（Pod 级异常状态），也可能只是踢开症状（如果异常由 deployment/controller 的错误定义驱动，重建后立刻复发）。可接受的前提：你已确认根因在 Pod 实例层而非控制面定义层、理解删除会带来的影响（如短暂不可用）、且按变更纪律人工执行并准备验证输出。
</details>

4. 同一个故障，一次用 T1+验证循环，一次把 FIXES.md 答案贴给 AI 让它"给命令"。两次都能"修好"，训练价值差在哪？

<details><summary>答案</summary>

前者训练的是证据→假设→验证的推理链（可迁移到任何未知故障），后者训练的是文档复述（只对已知故障有效）。靶场的价值在于可重复制造"你不知道答案"的状态，把答案喂回去等于自己拆掉这个前提。
</details>

5. 如果团队要统计"LLM 辅助排障的效果"，你会提哪两个度量指标？为什么不用"AI 答对率"？

<details><summary>答案</summary>

建议：MTTA（从告警到形成正确假设的时间）和首轮假设命中率（Top3 假设包含真因的比例）。"AI 答对率"无法定义与测量——AI 输出是开放文本，且最终对错取决于人的验证与决策；而这两个指标落在排障过程本身，可从留痕报告里客观统计。
</details>

## 延伸阅读

- Kubernetes 官方·排障任务总入口（Troubleshooting Clusters）：<https://kubernetes.io/docs/tasks/debug/debug-cluster/>
- Kubernetes 官方·应用排障（Pod 状态与事件解读）：<https://kubernetes.io/docs/tasks/debug/debug-application/>
- Google SRE 书籍·紧急事件响应（验证纪律的来源场景）：<https://sre.google/sre-book/emergency-response/>
- 本仓库 `scripts/faults/FIXES.md`（靶场 12 种故障的标准排障路径，盲测后再看）
