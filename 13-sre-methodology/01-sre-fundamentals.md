# 01 · SRE 基础：把运维当软件问题来解

> 模块：13-sre-methodology ｜ 建议时长：3 小时 ｜ 关联认证：—（无直接考点；为 CKA/CKS/PCA 提供"为什么"的框架，也是 JD 报告里中级到高级的分水岭）

## 学习目标

- 能复述 Google SRE 的起源背景，并解释"让软件工程师设计运维职能"这句话的含义
- 能从定位、日常、成功标准三个维度对比 SRE / 传统运维 / 运维开发
- 能说明 50% 工程时间上限的运作机制，以及它与错误预算的联动
- 能用 Toil 六特征判定一项工作是否算琐事，并完成一次 toil 审计
- 能把一条重复的运维任务改造成脚本（消除 toil 的最小闭环）

## 1. 起源：2003 年 Google 的一个算术问题

2003 年，Ben Treynor Sloss 在 Google 接手一个 7 人运维团队时面对的矛盾可以画成一张图：

```
系统规模（用户量/机器数/变更频率）
   │                                          /
   │                                        /
   │                                      /        业务价值
   │                                    /
   │                                  /
   │                                /
   │          人工运维成本（线性于规模）╱ ←── 招人只是延缓，不是解
   │                           ╱╱╱
   │                    ╱╱╱╱╱
   │             ╱╱╱╱╱╱
   │      ╱╱╱╱╱╱
   └────────────────────────────────────────────→ 时间
```

如果运维靠人堆，机器翻一倍人也要翻一倍，成本最终吃掉业务。Treynor 的解法后来被他总结成一句话（SRE Book 第 1 章原文）：

> "SRE is what happens when you ask a software engineer to design an operations function instead of a sysadmin."
> （SRE 就是当你让软件工程师——而不是系统管理员——去设计一个运维职能时所发生的事。）

三个由此派生的核心主张：

1. **运维问题应当主要用软件解**：重复的手工操作写成自动化，不稳定的人为流程改成代码 + 流水线。
2. **可靠性是产品特性，可以被量化与谈判**：不是"越稳越好"，而是"稳到用户满意的那个程度"，用第 2 章的 SLO/错误预算来定价。
3. **工程师的时间是稀缺资源，要设硬上限**：这就是 50% 规则（第 3 节）。

2016 年 Google 把这套实践公开成《Site Reliability Engineering》一书（sre.google/books 可免费在线阅读），SRE 从 Google 内部职位名变成行业方法论。

## 2. 三种角色对照：SRE / 传统运维 / 运维开发

| 维度 | 传统运维（Ops） | 运维开发（工具链/平台） | SRE |
|------|----------------|------------------------|-----|
| 定位 | 系统的管理员，守着机器 | 给运维造工具的研发 | 用工程手段对可靠性负责的工程师 |
| 日常 | 工单驱动：部署、扩容、审批、救火 | 开发平台/CI/CD/监控系统 | 50% 工程（自动化/优化）+ 50% 运维（含 on-call） |
| 成功标准 | 系统不挂、变更不出错 | 工具交付与采用率 | SLO 达成 + toil 占比受控 |
| 对故障 | 谁惹的谁修，怕变更 | 不直接背锅，修的是工具 | 故障是数据：复盘产出自动化与设计改进 |
| 典型产出 | 操作记录、巡检报告 | 平台、SDK、流水线模板 | 自动化系统、SLO 体系、runbook、复盘报告 |
| 风险倾向 | 求稳，抗拒变更 | 求新，可能脱离一线 | 用错误预算给"快"和"稳"定价 |

与 DevOps 的关系常被问：**DevOps 是一套文化与方法论（打破 dev/ops 部门墙），SRE 是它的一种具体组织实现**。SRE Workbook 里的说法是 "class SRE implements interface DevOps"——SRE 用错误预算、平台化、无责复盘等机制，把 DevOps 的理念落成了可执行的日常。

国内 JD 语境提醒：招聘网站上"SRE"经常是"运维开发 + 稳定性保障 + 值班"的混合岗。判断一个岗位离 Google 语义的 SRE 有多近，看两条硬指标：**是否用 SLO/错误预算管理可靠性**、**是否有强制性的自动化/toil 治理时间**。

## 3. 50% 上限：一个有牙齿的数字

Google SRE 的硬规矩：**每个 SRE 投在运维性工作（on-call、工单、救火等 toil）上的时间不得超过 50%**。剩下至少 50% 必须用于工程工作：写自动化、改架构、做监控。

它不是口号，而是一个带触发条件的控制回路：

```
        测量本季度 toil 占比
                 │
        ┌────────▼────────┐
        │  toil ≤ 50% ？  │
        └───┬─────────┬───┘
          是│         │否
            │         │
   正常节奏继续   ┌──▼────────────────────────────┐
   （工程:运维    │ 1. 团队只做可靠性工程，暂停     │
    ≥ 50:50）    │    接新的运维性工作             │
                 │ 2. 把 toil 顶回产品/来源团队     │
                 │ 3. 招人或内部转岗补工程力量      │
                 │ 4. 治理到回到 50% 线以下才恢复   │
                 └────────────────────────────────┘
```

为什么上限是 50% 而不是更低：on-call 和必要的运维是**生产知识的来源**，完全不碰生产的 SRE 会脱离实际；50% 是"既在场、又不被淹没"的平衡点。

它和第 2 章错误预算是一对互补的阀门：**错误预算管"系统允许多不稳定"（对外），50% 上限管"团队允许多少被运维消耗"（对内）**。预算烧穿冻结的是发布；toil 超标冻结的是新接运维工作。

## 4. Toil：识别与治理

### 4.1 定义与六特征

Google SRE Book 给出 toil（琐事）的判定特征，一条工作命中越多，越算 toil：

| 特征 | 中文解释 | 例 |
|------|---------|----|
| Manual | 手工执行 | 每次扩容都手工 `kubectl scale` 再肉眼盯 |
| Repetitive | 下次还这么做 | 每周清一次磁盘日志 |
| Automatable | 机器能做 | 判断逻辑固定、输入输出明确 |
| Tactical | 被动响应，中断型 | 半夜被告警叫起来重启服务 |
| No enduring value | 做完不留下资产 | 修完不留文档、不留代码 |
| Scales with service growth | 随规模线性增长 | 机器从 10 台到 100 台，巡检时间 ×10 |

判定树：

```
这项工作是否手工 + 重复？
 ├── 否 ──────────────→ 不是 toil（设计评审、架构讨论、教学属正常工程）
 └── 是 ──→ 做完是否留下可复用资产（代码/文档/配置）？
      ├── 是 → 半 toil：保留，但把"手工部分"继续压缩
      └── 否 ──→ 是否随服务规模线性增长？
            ├── 是 → 典型 toil，高优先治理
            └── 否 → 轻度 toil，记账观察
```

容易误判的两类：

- **on-call 响应本身不全是 toil**：少量高质量的 page + 修复是必要的生产接触；toil 的是那些**每次都以同样手工方式重复**的响应。
- **写自动化不是 toil**：哪怕它看起来在"做运维的事"，它有 enduring value。

### 4.2 治理四步

1. **记账**：所有 toil 按分钟数记入账本（本课实战演练会搭这个账本）。
2. **度量**：按类别汇总，算出 toil 占团队总工时比例——没有数字，50% 上限无从谈起。
3. **排序自动化**：优先治理"频率 × 单次耗时"最大、且 Automatable 特征明显的项。
4. **防复发**：新需求进来先问"能不能自服务化/自动触发"，把 toil 挡在源头，而不是招人消化。

## 5. SRE 的 identity：从"会修"到"让它不再需要修"

JD 报告把本模块定位为中级到高级的分水岭，分水岭两侧的差别正是 identity 的差别：

| | 中级（执行者视角） | 高级（SRE 视角） |
|---|---|---|
| 遇到故障 | 定位并修好，结束 | 定位并修好 → 追问：探测为什么没更早？修复为什么需要人？ |
| 稳定性 | 靠小心谨慎 | 靠 SLO + 错误预算 + 自动化护栏 |
| 知识 | 在个人脑子里 | 在 runbook、监控、复盘和代码里 |
| 成长方向 | 更熟练地修更多种故障 | 让同一类故障不再需要人修 |

三条身份认同，面试和实践中都经得起追问：

1. **软件工程是第一技能**：shell/Python/Go、API、数据结构，与写业务代码的人同侪。
2. **可靠性是被设计出来的特性**：像对待 feature 一样对待它——有需求（SLO）、有测试（混沌工程）、有迭代（复盘行动项）。
3. **服务用户而非服务机器**：一切指标最终要换算成用户体验（第 2 章 SLI 的选择会反复回到这一点）。

## 实战演练：一次 Toil 审计 + 最小自动化闭环

环境：kubeadm 单 master 练习集群（`scripts/setup/kubeadm-single-node.sh` 建好的那套），或任何装有 kubectl 的 Ubuntu VM。

### Step 1 建账本与记录脚本

```bash
# [master] 建目录与记录脚本
mkdir -p ~/bin
cat > ~/bin/toil-log.sh <<'EOF'
#!/usr/bin/env bash
# toil-log.sh —— 记一条 toil 到账本（CSV）
# 用法: toil-log.sh <分钟数> <类别> <描述>
# 类别: deploy | alert-fix | ticket | backup | capacity | drill | other
set -euo pipefail
LEDGER="${HOME}/toil-ledger.csv"
[[ $# -eq 3 ]] || { printf '用法: toil-log.sh <分钟数> <类别> <描述>\n' >&2; exit 1; }
[[ -f "${LEDGER}" ]] || printf 'date,minutes,category,task\n' > "${LEDGER}"
printf '%s,%s,%s,%s\n' "$(date '+%F')" "$1" "$2" "$3" >> "${LEDGER}"
printf '已记录: %s 分钟 [%s] %s\n' "$1" "$2" "$3"
EOF
chmod +x ~/bin/toil-log.sh
bash -n ~/bin/toil-log.sh && echo "语法 OK"
```

注意：描述里**不要带逗号**（CSV 约束）。真实使用时把 `~/bin` 加进 PATH（`export PATH="$HOME/bin:$PATH"` 写入 `~/.bashrc`）。

### Step 2 汇总脚本 + 灌入演示数据

```bash
# [master] 汇总脚本：按类别出分钟数与占比
cat > ~/bin/toil-report.sh <<'EOF'
#!/usr/bin/env bash
# toil-report.sh —— 汇总 toil 账本（无排序依赖，mawk 可用）
set -euo pipefail
LEDGER="${HOME}/toil-ledger.csv"
[[ -f "${LEDGER}" ]] || { printf '账本不存在: %s\n' "${LEDGER}" >&2; exit 1; }
awk -F, 'NR>1 { m[$3]+=$2; t+=$2 }
END {
  printf "%-12s %8s %7s\n", "category", "minutes", "pct";
  for (c in m) printf "%-12s %8d %6.1f%%\n", c, m[c], m[c]*100/t;
  printf "%-12s %8d %6.1f%%\n", "TOTAL", t, 100.0;
}' "${LEDGER}"
EOF
chmod +x ~/bin/toil-report.sh

# 灌入一周演示数据（体验流程用；真实审计请删掉这段，用自己的记录）
~/bin/toil-log.sh 35 deploy 手工执行3次发版并逐个目测验证
~/bin/toil-log.sh 25 alert-fix 处理磁盘告警手工清日志
~/bin/toil-log.sh 40 ticket 转发审批开通权限工单
~/bin/toil-log.sh 20 backup 手工备份etcd并scp到备份机
~/bin/toil-log.sh 30 drill 靶场排障训练break-coredns
~/bin/toil-log.sh 15 alert-fix 重启异常业务Pod
~/bin/toil-log.sh 25 deploy 手工扩容并改HPA参数
```

### Step 3 看数字，选目标

```bash
# [master] 输出类似（for 顺序不定）：
# category    minutes    pct
# deploy            60   24.0%
# alert-fix         40   16.0%
# ...
~/bin/toil-report.sh
```

按"频率 × 单次耗时 × 可自动化程度"排序，本演示数据里 `deploy`（手工发版 + 目测验证）是第一治理目标。

### Step 4 最小自动化闭环

把"目测验证"环节自动化——发版后逐个 ns 看 Pod 状态是典型手工活，脚本化成一条命令：

```bash
# [master] 全集群非 Running Pod + 重启 Top10 一屏出
cat > ~/bin/cluster-glance.sh <<'EOF'
#!/usr/bin/env bash
# cluster-glance.sh —— 发版后的例行目测自动化
set -euo pipefail
printf '== 异常状态的 Pod（Pending/CrashLoopBackOff/Evicted 等）==\n'
kubectl get pods -A | awk 'NR==1 || ($4 != "Running" && $4 != "Completed")'
printf '\n== 重启次数 Top10 ==\n'
kubectl get pods -A -o jsonpath=\
'{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{.status.containerStatuses[*].restartCount}{"\n"}{end}' \
| awk '{ n=0; for (i=2; i<=NF; i++) n+=$i; if (n>0) print n, $1 }' \
| sort -nr | head -10 | awk '{ printf "%6s  %s\n", $1, $2 }'
EOF
chmod +x ~/bin/cluster-glance.sh
bash -n ~/bin/cluster-glance.sh && ~/bin/cluster-glance.sh
```

验证闭环三问：原来 10 分钟的目测现在多少秒？（计时对比）脚本能进 git 吗？下次发版它会被自动执行吗（比如挂进 CI 的 post-deploy 步骤）？——能回答"会"，toil 才算真的消除，而不是换了个地方手工。

## 常见坑

| 症状 | 原因 | 解法 |
|------|------|------|
| "我们也在做 SRE，就是天天救火" | 只有名字没有机制：无 SLO、无 toil 度量 | 先搭账本 + 定一个 SLI，机制先于头衔 |
| toil 记录三天就荒废 | 记录成本太高 | 把记账脚本做到 10 秒内完成一条；或从 CI/工单系统自动导入 |
| 自动化做完没人敢用 | 脚本无验证、无回退 | 自动化必须带 dry-run 与幂等设计（参考 scripts/faults 的 --restore 思路） |
| 把所有运维都当 toil 消灭 | 误伤生产接触 | 保留必要 on-call 与演练（drill 类），消灭的是"重复且无资产沉淀"的部分 |
| 50% 上限形同虚设 | 没有季度复盘 toil 数字 | 把 toil 报告放进季度回顾议程，超标即触发第 3 节的控制动作 |

## 自测

<details><summary>1. 如果一个团队 toil 占比长期 80%，直接招 5 个新人做运维，问题解决了吗？</summary>

没解决。toil 的定义里有一条 "scales with service growth"：随规模线性增长的手工工作，加人只是把曲线斜率不变地平移，下个季度又超标。正确动作是触发控制回路：暂停接新运维性工作，把工程时间集中投向自动化，把 toil 顶回来源团队（让制造 toil 的流程自服务化），人只补工程角色。
</details>

<details><summary>2. "每次告警后都要手工执行同一个 5 步修复流程"——它命中了六特征中的哪几条？</summary>

至少四条：Manual（手工）、Repetitive（每次相同）、Automatable（步骤固定可编码）、Tactical（被告警中断驱动）。若修复后不留文档/代码，还命中 No enduring value。这是教科书级的 toil，正确出路是：流程写成 runbook（第 4 章），再升级为脚本或自动修复，告警注解直接挂 runbook 链接。
</details>

<details><summary>3. 为什么 50% 上限不设成 0%——让 SRE 彻底不碰生产不是更纯粹吗？</summary>

会失去两样东西：一是生产知识，不碰生产的可靠性工程会脱离真实约束，做出用不上的自动化；二是反馈回路，on-call 中亲历的痛点是排序自动化需求的最可靠信号。50% 是"在场但不被淹没"的设计值。
</details>

<details><summary>4. DevOps 说"你构建，你运行（you build it, you run it）"，那还需要专职 SRE 吗？</summary>

两者是互补而非替代。DevOps 模式把运行责任交回产品团队；SRE 在此之上提供平台与专业方法论（SLO 体系、on-call 训练、混沌工程、复盘文化），常常以"平台团队 + 嵌入式顾问"形态存在。判断标准是组织规模与专业深度：小团队 DevOps 足够，规模大到需要专门的可靠性工程能力时，SRE 职能（不一定是这个头衔）就会出现。
</details>

<details><summary>5. 面试官问"你们团队 toil 占比多少"，你答不上来的根因是什么？</summary>

根因是缺度量机制而非记性：没有账本/标签/工单归类，任何"占比"都是感觉。改造路径：把运维性工作打上统一 label（工单系统或本课的 CSV 账本），按周/月出报表，让这个数字成为季度回顾的固定输入。答不上这个数字的团队，50% 上限必然形同虚设。
</details>

## 靶场联动：靶场是这些方法论的练习场

`scripts/faults/` 的 12 个 break 脚本是双面教材：作为**练习**，它们逼你走完"现象 → 定位 → 修复"的完整链条，积累生产直觉；作为**toil 标本**，每一次手工排障都在提醒你——同一类故障第二次还需要人从零开始查，就是 toil。训练姿势：每做完一轮靶场排障，往账本里记一条 drill，并回答"这次排障的哪一步下次可以脚本化"。`FIXES.md` 就是别人替你沉淀好的 runbook 集，你的长期目标是逐步把其中高频条目变成自己的自动诊断脚本。

## 延伸阅读

- Google SRE Book（在线免费）：https://sre.google/books/
- SRE Book 第 1 章 Introduction：https://sre.google/sre-book/introduction/
- SRE Book 第 5 章 Eliminating Toil：https://sre.google/sre-book/eliminating-toil/
- SRE Workbook · How SRE Relates to DevOps：https://sre.google/workbook/how-sre-relates/
