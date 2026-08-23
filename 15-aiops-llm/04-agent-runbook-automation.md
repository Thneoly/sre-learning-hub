# 04 · Agent 与 Runbook 自动化

> 模块：AIOps/LLM 运维（15）｜ 建议时长：2.5 小时 ｜ 前置：01~03 章 ｜ 关联认证：CKS-RBAC/审计（护栏部分直接相关）

## 学习目标

- 能画出 Agent 的核心循环（目标→tool call→执行→回填→继续），并解释"LLM 从不执行任何东西"这句话
- 能按三原则（单一职责/读写分离/输出结构化）把运维原子操作封装成 Agent 可调用的 skill
- 能说清 MCP 解决的问题（工具生态的 N×M 问题），以及现阶段先吃透 Function Calling 再看 MCP 的理由
- 能设计一个分级响应的 AI 值班助手原型（只读自动/诊断报告/变更需审批/人接管）
- 能落地三层安全护栏（RBAC 只读身份、白名单工具、审计日志）并在集群上验证 deny-by-default

## 1. 从 Chat 到 Agent：工具调用原理

第 2 章的用法里，人是"搬运工"：把命令输出复制给 LLM，再把 LLM 的命令复制回终端。Agent 做的事情就是把这个人肉循环自动化：

```
              ┌────────────────────────────────────────┐
              │                Agent 循环               │
              │                                        │
  用户目标 ──►│  LLM 思考 ──► 产出 tool_call(JSON)      │
 "查一下集群  │     ▲              │                    │
  哪些 Pod    │     │              ▼                    │
  不健康"     │  结果回填        你的代码解析 JSON，     │
              │  (作为 tool     真正执行工具，拿到输出   │
              │   消息追加       （kubectl/脚本/API）    │
              │  进对话)              │                 │
              │     └─────────────────┘                 │
              │  循环直到 LLM 给出最终文本回答，或达到    │
              │  步数上限（必须有，防失控烧钱）           │
              └────────────────────────────────────────┘
```

必须刻在脑子里的认知：**LLM 只会输出文本。它说"我要调用 kubectl_get"时，只是在响应里生成了一个结构化的"我想调用这个工具"的 JSON；真正去执行的永远是你的代码（执行器），再把输出作为 tool 消息回填给它。** 这个认知直接推出实战演练一节的护栏设计：既然执行权在你的代码手里，管控点就在执行器，而不在模型。

Function Calling 的一次交互长什么样（OpenAI 兼容接口的请求/响应骨架）：

```json
{
  "model": "qwen2.5-7b-instruct",
  "messages": [
    {"role": "user", "content": "集群里有哪些不健康的 Pod？只做只读诊断。"}
  ],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "k8s_diag",
        "description": "运行白名单内的 kubectl 只读命令，返回文本输出",
        "parameters": {
          "type": "object",
          "properties": {
            "cmd": {"type": "string", "description": "完整的 kubectl 只读命令，例如 kubectl get pods -A"}
          },
          "required": ["cmd"]
        }
      }
    }
  ]
}
```

模型不直接执行，而是在响应里给出 `tool_calls: [{function: {name: "k8s_diag", arguments: "{\"cmd\": \"kubectl get pods -A\"}"}}]`；你的代码执行后，把输出以 `role: "tool"` 消息追加，再次请求，直到模型输出普通文本。

## 2. 运维"skill"封装：把原子操作包装成可调用能力

本学习中心的设计理念是"人按 skill 学，一个 skill 解决一类问题"；Agent 的工具层是同一个理念的自动化镜像：**一个 skill = 一个原子操作 + 明确的输入输出 + 明确的权限边界**。人读的 skill 和机器调的 skill，分界线完全一致。

工具设计三原则：

| 原则 | 含义 | 反例 |
|---|---|---|
| 单一职责 | 一个工具只做一件事，名字就是这件事 | `fix_cluster()`——名字就说明它管得太宽 |
| 读写分离 | 只读与变更是不同工具，不同权限，不同审批 | 一个 `kubectl_all()` 同时能 get 和 delete |
| 输出结构化 | 返回 JSON/表格，别让下一个工具去解析自然语言 | 工具返回"看起来挺健康的" |

一套值班助手的 skill 清单起点：

| 工具名 | 类型 | 包装的原子操作 | 权限 |
|---|---|---|---|
| `k8s_get` / `k8s_describe` | 只读 | kubectl get/describe 任意对象 | 只读 SA |
| `k8s_logs` / `k8s_events` | 只读 | 容器日志、事件查询 | 只读 SA |
| `node_diag` | 只读 | 节点上白名单命令（systemctl status/journalctl/ss） | 只读 SA + 审计 |
| `metric_query` | 只读 | PromQL 查询（08 模块的能力） | Prometheus 只读 |
| `kb_search` | 只读 | 第 3 章的知识库检索 | 无集群权限 |
| `draft_change` | 变更（草稿） | 生成变更工单草稿，不执行任何命令 | 无 |
| `submit_change` | 变更 | 把草稿提为审批流工单 | 审批流权限 |

白名单执行器是工具层的核心组件——`k8s_get` 们最终都经由它落地（deny-by-default：不在白名单的一律拒绝）：

```bash
# [master] 文件 /usr/local/bin/k8s_diag —— Agent 执行器调用的白名单只读工具
#!/usr/bin/env bash
# 用法: k8s_diag "kubectl get pods -A"
# 设计: deny-by-default + 双重检查 + 审计日志
set -u

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }
AUDIT=/var/log/k8s_diag.log

if [ $# -ne 1 ]; then
  echo "用法: k8s_diag \"<kubectl 只读命令>\"" >&2
  exit 2
fi
CMD="$1"

# 检查 1：拒绝 shell 元字符（防止 "kubectl get pods; rm -rf /" 这类注入）
if printf '%s\n' "$CMD" | grep -qE '[;|&<>`$]'; then
  log "DENIED(元字符): $CMD" >> "$AUDIT" 2>/dev/null
  echo "DENIED: 命令含 shell 元字符" >&2
  exit 3
fi

# 检查 2：前两个词必须命中白名单
read -r -a A <<< "$CMD"
case "${A[0]:-} ${A[1]:-}" in
  "kubectl get"|"kubectl describe"|"kubectl logs"|"kubectl top"|"kubectl auth"|"kubectl version"|"kubectl cluster-info") ;;
  *)
    log "DENIED(白名单外): $CMD" >> "$AUDIT" 2>/dev/null
    echo "DENIED: 命令前缀不在白名单" >&2
    exit 3 ;;
esac

# 检查 3：整体拒绝变更/执行类子命令（纵深防御）
case "$CMD" in
  *delete*|*apply*|*create*|*patch*|*edit*|*scale*|*drain*|*cordon*|*taint*|*exec*|*attach*|*port-forward*|"set "*)
    log "DENIED(变更类): $CMD" >> "$AUDIT" 2>/dev/null
    echo "DENIED: 检测到变更/执行类子命令" >&2
    exit 3 ;;
esac

log "ALLOW: $CMD" >> "$AUDIT" 2>/dev/null
exec "${A[@]}"
```

一个配得上"最小但完整"称号的 Agent 循环（把工具接到模型上；LLM 端点任意 OpenAI 兼容服务，内网 vLLM/Ollama 均可）：

```python
# [任意节点或本地，需 python3 + requests + 可访问的 LLM 端点] 文件 mini_agent.py
"""最小工具循环：只注册一个白名单只读工具 k8s_diag，步数上限 5。"""
import json
import os
import subprocess
import sys

import requests

BASE = os.environ.get("LLM_BASE_URL", "http://127.0.0.1:8000/v1")
KEY = os.environ.get("LLM_API_KEY", "dummy")
MODEL = os.environ.get("LLM_MODEL", "qwen2.5-7b-instruct")
MAX_STEPS = 5

TOOLS = [{
    "type": "function",
    "function": {
        "name": "k8s_diag",
        "description": "运行白名单内的 kubectl 只读命令，返回文本输出",
        "parameters": {
            "type": "object",
            "properties": {"cmd": {"type": "string",
                                   "description": "完整的 kubectl 只读命令，如 kubectl get pods -A"}},
            "required": ["cmd"],
        },
    },
}]


def chat(messages):
    r = requests.post(f"{BASE}/chat/completions",
                      json={"model": MODEL, "messages": messages, "tools": TOOLS},
                      headers={"Authorization": f"Bearer {KEY}"}, timeout=60)
    r.raise_for_status()
    return r.json()["choices"][0]["message"]


def run_tool(name, args):
    if name != "k8s_diag":
        return "错误：工具未注册"
    p = subprocess.run(["k8s_diag", args["cmd"]], capture_output=True, text=True, timeout=60)
    return (p.stdout + p.stderr)[:4000]   # 截断，防止撑爆上下文


messages = [{"role": "user", "content": sys.argv[1] if len(sys.argv) > 1 else
             "集群里有没有不健康的 Pod？只做只读诊断，给出结论和证据。"}]

for _ in range(MAX_STEPS):
    msg = chat(messages)
    messages.append(msg)
    if not msg.get("tool_calls"):
        print(msg["content"])
        sys.exit(0)
    for tc in msg["tool_calls"]:
        result = run_tool(tc["function"]["name"], json.loads(tc["function"]["arguments"]))
        messages.append({"role": "tool", "tool_call_id": tc["id"], "content": result})

print("（达到步数上限，强制停止）")
```

注意 `MAX_STEPS` 这个不起眼的上限：它是 Agent 与"死循环烧钱脚本"之间唯一的区别，任何线上 Agent 都必须有。

## 3. MCP：把工具生态标准化

Function Calling 的问题是每个应用各自实现"工具注册/发现/执行"。假如 10 个运维应用（值班助手、巡检平台、工单系统）都要接 10 种数据源（K8s、Prometheus、Loki、Jira……），就是 100 份重复胶水代码（N×M 问题）。

MCP（Model Context Protocol）把这个关系变成 N+M：数据源/原子能力做成 **MCP Server**（对外声明自己提供哪些 tools/resources/prompts），任何支持 MCP 的应用（MCP Host/Client）都能即插即用：

```
   MCP Host（值班助手应用，内含 MCP Client）
      │  ┌──────────────┼──────────────┐
      ▼  ▼              ▼              ▼
  MCP Server        MCP Server      MCP Server
  （K8s 只读诊断）   （PromQL 查询）  （ops-kb 知识库检索）
  暴露 tools:        暴露 tools:     暴露 tools+resources:
  k8s_get/describe   metric_query    kb_search / runbook 原文
```

现成的类比：**USB-C for AI 应用**——接口标准统一后，外设（工具）生态可以独立于主机（应用）生长。

务实建议：MCP 仍在快速演进期，概念先行、生态未稳。学习顺序上，先把 Function Calling 的循环亲手写一遍（第 2 节的 mini_agent）——MCP 在协议层解决的就是这层的事，不懂循环就看不懂 MCP 的价值；团队内部先用第 2 节的方式封装 skill，等标准与生态稳定再迁移，迁移成本只是一层协议适配。

## 4. AI 值班助手原型设计

设计目标不是"AI 自动修故障"，而是把值班从"读告警+拼上下文"里解放出来。分级响应是整个设计的骨架：

```
告警触发
   │
   ▼
┌─────────────── 告警分级路由 ───────────────┐
│ P3 低危（自动恢复类） ──► L0: 只读巡检+记录，次日汇总    │
│ P2 中危 ──────────────► L1: 自动诊断，产出报告到 IM，人决策│
│ P1 高危 ──────────────► L2: 诊断报告+变更建议，           │
│                          变更走 GitOps PR 审批后由 CI 执行 │
│ P0 核心事故 ───────────► L3: 人全程主导，Agent 只做       │
│                          会议纪要与时间线整理（13 模块 03 章）│
└──────────────────────────────────────────┘

L1 的自动诊断（全程只读，无审批即可跑）:
  告警 → Agent 调 k8s_get/describe/logs + kb_search
       → 产出：现象摘要 + 证据链 + Top3 假设 + 建议的 runbook 条目
       → 推送到值班 IM，@值班人

L2 的变更（关键设计：Agent 永远不直接执行变更）:
  Agent 产出变更草稿（YAML diff / kubectl 命令 + 理由 + 回滚方案）
       → 提交 GitOps PR（Argo CD，06 模块）
       → 人审批 PR → 合并 → CI/CD 应用到集群
       → Agent 验证结果并回填到工单
```

为什么 L2 的变更必须走 GitOps PR，而不是"IM 里点个批准按钮"？因为 PR 天然带齐了变更安全的三件套：**评审记录**（谁批的、看没看 diff）、**版本历史**（回滚就是 revert）、**审计线索**（什么时间改了什么）。这三个能力自己造一遍成本极高，复用现成流程是工程上最便宜的安全护栏。

这个分级表本身就是给管理层的沟通工具——它明示了"哪些事 AI 自动做（全是只读），哪些事 AI 只起草（所有变更），哪些事人主导"。

## 实战演练：安全护栏落地（deny-by-default、只读优先、审计日志）

三层护栏，每层假设上一层会失效：

| 层 | 护栏 | 防的是什么 |
|---|---|---|
| 身份层 | 专用只读 ServiceAccount（RBAC） | 工具被诱导执行变更命令 |
| 工具层 | 白名单执行器 + 元字符检查 | prompt 注入与命令拼接 |
| 流程层 | 变更走 PR 审批 + 审计日志 | 变更事故无法回溯与定责 |

实战：给 Agent 建一个连 secrets 都读不到的只读身份。

```yaml
# [master] 文件 ai-oncall-rbac.yaml —— Agent 专用只读身份（复用内置 view ClusterRole）
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ai-oncall
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ai-oncall-readonly
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
subjects:
- kind: ServiceAccount
  name: ai-oncall
  namespace: kube-system
```

```bash
# [master] 应用并验证 deny-by-default
kubectl apply -f ai-oncall-rbac.yaml
kubectl auth can-i get pods --as=system:serviceaccount:kube-system:ai-oncall
kubectl auth can-i delete pods --as=system:serviceaccount:kube-system:ai-oncall
kubectl auth can-i get secrets --as=system:serviceaccount:kube-system:ai-oncall
```

预期输出依次为 `yes` / `no` / `no`——最后一条就是选 `view` 而不是 `view+secrets` 的理由：Agent 的身份边界要按"它的工作需要什么"而不是"它可能会需要什么"来划。

第三层：审计日志。让 Agent 的每个请求都可回溯：

```yaml
# [master] 文件 /etc/kubernetes/audit-policy.yaml —— Agent 身份全量记录
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages: ["RequestReceived"]
rules:
- level: RequestResponse
  users: ["system:serviceaccount:kube-system:ai-oncall"]
  verbs: ["get", "list", "watch"]
- level: Metadata
  users: ["system:serviceaccount:kube-system:ai-oncall"]
- level: None
  users: ["system:kube-proxy"]
  resources:
  - group: ""
    resources: ["endpoints", "services", "nodes"]
```

启用审计需要在 kube-apiserver 静态 Pod 上挂载策略文件（kubeadm 集群改 `/etc/kubernetes/manifests/kube-apiserver.yaml`，追加参数与 volume，kubelet 会自动重启 apiserver；具体字段以官方文档为准）：

```yaml
# [master] /etc/kubernetes/manifests/kube-apiserver.yaml 需要追加的部分（节选，与现有字段合并）
spec:
  containers:
  - command:
    - kube-apiserver
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/kubernetes/audit.log
    volumeMounts:
    - name: audit-policy
      mountPath: /etc/kubernetes/audit-policy.yaml
      readOnly: true
    - name: audit-log
      mountPath: /var/log/kubernetes
  volumes:
  - name: audit-policy
    hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
  - name: audit-log
    hostPath:
      path: /var/log/kubernetes
      type: DirectoryOrCreate
```

```bash
# [master] apiserver 自愈后验证审计日志在生长
kubectl -n kube-system get pods -l component=kube-apiserver
sudo tail -1 /var/log/kubernetes/audit.log | jq -r '[.user.username, .verb, (.objectRef.resource // "-")] | @tsv'
```

## 5. 现实边界与落地建议

2026 年能落地与不该急的清单：

| 可以放手做（只读，出错的代价是浪费时间） | 别急（变更类，出错的代价是事故） |
|---|---|
| 告警/事件摘要与聚合（第 1 章） | AI 直接执行任何变更命令 |
| 诊断报告与假设排序（第 2 章方法论自动化） | AI 自动决策扩缩容/切换流量 |
| 知识库问答（第 3 章 RAG） | AI 自动闭环"修复→验证→再修复"循环 |
| 复盘初稿、runbook 草稿 | 把 Agent 的输出直接写回权威数据源 |

落地节奏（每一步都为下一步铺路，跳步的都在返工）：

1. **第 1 步（1 周）**：知识库整理 + RAG 问答（第 3 章全套）——零风险，且立刻缓解"新人不会查"。
2. **第 2 步（2~4 周）**：把第 2 章方法论固化成团队 prompt 模板，用靶场做回归评测——这一步产出的是"效果可度量"的证据（首轮假设命中率）。
3. **第 3 步（1~2 月）**：只读 Agent（本章第 2 节与实战演练），值班 IM 里能 @助手 问诊断。
4. **第 4 步（按需）**：变更草稿 + GitOps 审批（第 4 节 L2）。走到这步的前提是前三步的度量数据都达标。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| Agent 一轮对话调了几十次工具 | 没有步数上限，或在兜圈子 | MAX_STEPS 硬上限 + 每步截断输出 |
| 工具输出把上下文撑爆（或费用失控） | `kubectl describe` 全量输出直接回填 | 执行器里截断 + 筛选关键字段再回填 |
| Agent 被"日志里的注入话术"带偏（日志里出现"忽略之前指令"） | prompt 注入：工具输出也是不可信输入 | 工具输出包在明确的定界符里；敏感动作（变更）永远不经模型之手 |
| 给了 Agent admin 权限"图省事" | 权限按"可能需要"而不是"工作需要"划分 | deny-by-default；按实战演练一节用 view 起步 |
| 白名单工具被 `kubectl get -o yaml; rm` 打穿 | 执行器用了 `bash -c "$cmd"` | 用参数数组 exec + 元字符检查（本章 k8s_diag 的做法） |
| 审计日志只记录成功请求 | 审计策略漏了 denied 事件 | level: Metadata 兜底规则覆盖该身份全部请求 |

## 自测

1. "LLM 从不执行任何东西"——既然如此，Agent 的安全管控点为什么必然在执行器而不在模型侧？

<details><summary>答案</summary>

因为模型对集群的全部影响力都经由执行器这一个咽喉：模型只能"请求"调用某工具，真正去跑 kubectl 的是你写的代码。在咽喉处设卡（白名单、只读身份、审计），无论模型被诱导成什么样，它拿不到白名单之外的能力。反过来想在模型侧防御（prompt 里写"不许执行危险命令"）只是建议，不是边界。
</details>

2. 第 4 节的 L2 为什么坚持"变更走 GitOps PR"而不是"IM 审批按钮"？说出 PR 自带的三件套。

<details><summary>答案</summary>

三件套：评审记录（谁在何时看过并批准了 diff）、版本历史（回滚即 revert，可追溯到任意版本）、审计线索（变更内容/时间/操作者完整可查）。自建审批按钮要把这三件都重新造一遍，而 Git 平台现成、团队已会用——安全护栏的最好形态是"复用大家已经在用的流程"。
</details>

3. `k8s_diag` 的白名单里有 `kubectl auth`（`kubectl auth can-i`）。这会不会构成提权风险？为什么？

<details><summary>答案</summary>

`kubectl auth can-i` 只做权限自查（它还有一个 impersonation 变体 `--as`，可查"某用户能不能做某事"），本身不改变任何权限，属于只读操作。真正的风险是 `--as` 可能被用来探测他人权限边界——信息泄露层面的小风险，可接受；若要收紧，可在执行器里拒绝 `--as` 参数。它不构成提权：提权需要写操作，而写操作在白名单外。
</details>

4. 如果 `view` ClusterRole 之外，团队还要求 Agent 能读 Prometheus 指标，你会怎么扩展实战演练一节的 RBAC？为什么不给它集群 admin？

<details><summary>答案</summary>

按"工作需要"精确放行：Prometheus 数据通常经由 API/查询服务暴露，给 Agent 的查询服务加只读 API key 或独立只读账号即可，集群 RBAC 不动（若必须直连 Prometheus 的 Pod/Service，可再加一个只允许 get/list 对 monitoring namespace 指定资源的 Role）。不给 admin 是因为 Agent 的故障半径取决于身份权限：admin 意味着一次成功的 prompt 注入就能删掉整个集群。
</details>

5. 团队想让 Agent "自动闭环修复"（检测→修复→验证→若失败换方案再修）。用本章的分级框架评估：至少要补哪些机制才配讨论这件事？

<details><summary>答案</summary>

至少补：每个候选修复方案的爆炸半径评估与预审批（哪些动作在白名单内）；修复失败计数上限与自动熔断（防止连续错误变更）；全链路审计与一键回滚（GitOps revert）；变更窗口约束（避开业务高峰）。即便补齐，P0/P1 场景仍应人主导——自动闭环的适用面是低危、可逆、白名单内的修复动作，不是全部故障。
</details>

## 延伸阅读

- Kubernetes 官方·RBAC（view ClusterRole 与授权检查）：<https://kubernetes.io/docs/reference/access-authn-authz/rbac/>
- Kubernetes 官方·审计（Audit Policy 字段与启用步骤）：<https://kubernetes.io/docs/tasks/debug/debug-cluster/audit-trail/>
- MCP（Model Context Protocol）官方文档与规范：<https://modelcontextprotocol.io>
- OpenAI·Function Calling 指南（工具调用接口的通用范式）：<https://platform.openai.com/docs/guides/function-calling>
- Argo CD 官方文档（GitOps 审批与回滚流程）：<https://argo-cd.readthedocs.io/en/stable/>
