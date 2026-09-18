# 05 · 私有化 LLM 端点部署：Ollama、vLLM 与 OpenAI 兼容 API

> 模块：AIOps/LLM 运维（17）｜ 建议时长：2.5 小时 ｜ 前置：04 章（实战要用它的 mini_agent.py 做验收；02/03 章建议先读） ｜ 关联认证：—（无直接考点，AIOps 岗位工程技能）

## 学习目标

- 能用"参数量 × 每参数字节数"粗算一个模型在不同精度下的显存占用，判断手头一块卡能跑哪个模型
- 能分别用 Ollama 与 vLLM 部署一个本地 LLM 端点，并说清两者定位差异（个人快速路径 vs 高并发生产路径）
- 能用 curl 验证 OpenAI 兼容 API（/v1/models、/v1/chat/completions），解释这层兼容换来了什么
- 能把端点接到第 4 章的 mini_agent.py 上跑通完整 Agent 循环（LLM_BASE_URL / LLM_MODEL 就位）
- 能按"数据不出域"要求收口端点的暴露面（监听地址、API key、模型文件与服务日志）

## 1. 为什么要自己部署一个端点

前四章的 LLM 都是"你可用的任意模型"——网页版、CLI、内网服务。要把它变成工程系统，第一步是有一个**可控的推理端点**：

| 动机 | 说明 |
|---|---|
| 数据不出域 | 03 章的知识库、02 章的排障 prompt 里有内网拓扑与配置；公网 API 意味着这些数据离开你的边界 |
| 可用性自主 | 值班场景不能拿"上游限流/停服"当故障理由；内网端点的 SLA 你自己说了算 |
| 成本可控 | Agent 一次诊断要多轮工具调用，按 token 计费很快失控；自部署是固定成本 |
| 可复现 | prompt 评测（02 章的评测集）要求同一模型版本长期可复现；云模型会静默升级换行为 |

本章的目标非常具体：把第 4 章 mini_agent.py 里的两个默认值变成真实可用的服务：

```python
# [任意节点] 第 4 章代码的默认端点（本章结束时它们应当能跑通）
BASE = os.environ.get("LLM_BASE_URL", "http://127.0.0.1:8000/v1")
MODEL = os.environ.get("LLM_MODEL", "qwen2.5-7b-instruct")
```

即：本机 8000 端口上跑一个 OpenAI 兼容服务，对外模型名叫 qwen2.5-7b-instruct。vLLM 的默认端口恰好是 8000——不是巧合，第 4 章就是按本章的部署方式写死的。

## 2. 显存粗算：参数量 × 精度

选型的第一道硬约束是显存。粗算公式（误差够用，目的是排除"明显跑不动"的选项）：

```
显存占用 ≈ 参数量 × 每参数字节数            ← 权重，占大头，只跟模型和精度有关
           + KV cache                      ← 随上下文长度与并发数线性增长
           + 10%~20% 运行开销               ← 激活值/CUDA 上下文，经验值
```

权重部分一张表搞定（"B" = billion 参数）：

| 精度 | 每参数字节 | 7B | 14B | 32B |
|---|---|---|---|---|
| FP16 / BF16 | 2 | 约 14 GB | 约 28 GB | 约 64 GB |
| INT8 | 1 | 约 7 GB | 约 14 GB | 约 32 GB |
| INT4（GPTQ / AWQ / GGUF q4） | 0.5 | 约 4~5 GB | 约 8~9 GB | 约 17~20 GB |

INT4 实际占用略高于"参数量 × 0.5 字节"：量化元数据与少量不量化的层有额外开销，所以给区间。

KV cache 是"上下文越长越贵、并发越高越贵"的来源，粗算式：

```
KV cache 字节 ≈ 2(K和V) × 层数 × KV头数 × 头维度 × 每元素字节数 × 序列长度 × 并发数

以 Qwen2.5-7B 为例（28 层、4 个 KV 头、头维度 128、FP16；具体以模型卡为准）：
  每 token ≈ 2 × 28 × 4 × 128 × 2 ≈ 56 KB
  4k 上下文  ≈ 0.22 GB / 请求
  32k 上下文 ≈ 1.8 GB / 请求
  10 个并发 × 8k 上下文 ≈ 4.5 GB —— 并发上来后这部分能反超权重
```

（Qwen2.5 用 GQA 把 KV 头压到 4 个，就是为了让这份开销可控。）

结论速查（值班助手场景，7B 级模型）：

| 硬件 | 建议部署 |
|---|---|
| 无独显 / ≤8GB 显存 | Ollama + INT4 量化，或降到 1.5B（CPU 能跑，慢但可用） |
| 16GB（T4 / 4060Ti 16G） | INT8；或 FP16 + 短上下文 |
| 24GB（3090 / 4090 / A10） | FP16 全精度 + 富余上下文——本章默认配置 |
| 48GB+ / 多卡 | 14B~32B，换更强的诊断与工具调用能力 |

## 3. 路线一：Ollama，十分钟上手

定位：个人与小团队的最快路径。GGUF 量化格式、CPU/GPU 自适应、单命令管理模型；代价是并发吞吐一般，不适合团队共用的高峰负载。

```bash
# [任意 Linux 节点] 安装（官方脚本；Windows/macOS 用官网安装包）
curl -fsSL https://ollama.com/install.sh | sh

# [任意节点] 拉取模型（7B 默认 Q4 量化，约 4.7GB 下载；先 df -h 确认磁盘）
ollama pull qwen2.5:7b

# [任意节点] 冒烟测试：直接对话
ollama run qwen2.5:7b "用一句话解释 ImagePullBackOff"
```

Ollama 原生暴露 OpenAI 兼容端点，默认只监听 127.0.0.1:11434，API key 任意非空即可：

```bash
# [任意节点] 验证 OpenAI 兼容接口
curl -s http://127.0.0.1:11434/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5:7b","messages":[{"role":"user","content":"用一句话解释 CrashLoopBackOff"}]}' \
  | jq -r '.choices[0].message.content'
```

接第 4 章 Agent 时改两个环境变量（模型名换成 Ollama 的 tag）：

```bash
# [任意节点] 让 mini_agent 指向 Ollama
export LLM_BASE_URL=http://127.0.0.1:11434/v1
export LLM_MODEL=qwen2.5:7b
python3 mini_agent.py "集群里有没有不健康的 Pod？"
```

## 4. 路线二：vLLM，为并发而生

定位：生产路径。PagedAttention + continuous batching 把高并发吞吐做到开源推理栈的第一梯队，是团队共享 GPU 服务器、K8s GPU 节点上跑推理服务的主流选择；代价是要求 NVIDIA GPU，部署比 Ollama 重。

```bash
# [任意有 NVIDIA GPU 的节点] 安装并启动（官方 quickstart；建议独立 venv/conda 环境）
pip install vllm
vllm serve Qwen/Qwen2.5-7B-Instruct \
  --host 127.0.0.1 --port 8000 \
  --served-model-name qwen2.5-7b-instruct \
  --enable-auto-tool-choice --tool-call-parser hermes
```

三个关键参数：`--served-model-name qwen2.5-7b-instruct` 让对外模型名与第 4 章 mini_agent 的默认值对齐（Agent 代码一行不改）；`--enable-auto-tool-choice --tool-call-parser hermes` 开启工具调用解析（Qwen 系列用 hermes parser，第 4 章 Agent 的 `tool_calls` 依赖它，参数名以官方文档为准）；`--host 127.0.0.1` 显式绑定回环地址——不加时监听行为随版本而异，内网共享绝不能裸奔（见第 7 节）。

权重首次从 HuggingFace 拉取约 15GB（国内网络可配置镜像加速或改用 ModelScope 下载，以官方文档为准）。逐项验证：

```bash
# [任意节点] 第一步：模型列表里应该出现 served-model-name
curl -s http://127.0.0.1:8000/v1/models | jq -r '.data[].id'
# 预期输出: qwen2.5-7b-instruct

# [任意节点] 第二步：一次对话请求
curl -s http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-7b-instruct","messages":[{"role":"user","content":"用一句话解释 CrashLoopBackOff"}]}' \
  | jq -r '.choices[0].message.content'
```

两条路线怎么选：

| 维度 | Ollama | vLLM |
|---|---|---|
| 上手成本 | 一条命令 | venv + GPU 驱动 + 参数调优 |
| 并发吞吐 | 单请求友好，并发一般 | continuous batching，高并发首选 |
| 硬件 | CPU 可跑 | NVIDIA GPU |
| 典型位置 | 个人桌面、跳板机 | 团队 GPU 服务器、K8s GPU 节点（Deployment + GPU Operator） |

实践节奏：先用 Ollama 把 02 章模板评测、03 章 RAG 拼接全流程走通，用量起来再迁 vLLM——OpenAI 兼容层保证迁移只是改 `LLM_BASE_URL` 和 `LLM_MODEL` 两个值。

## 5. 模型选型：为什么默认 Qwen2.5-7B

| 参数量 | 显存（INT4 / FP16） | 运维场景定位 |
|---|---|---|
| 0.5B~3B | 约 1~2GB / 1~6GB | 摘要、格式转换；CPU 可跑 |
| 7B~9B | 约 4~6GB / 14~18GB | 值班助手主力：排障假设、RAG 问答、工具调用（第 4 章） |
| 14B~32B | 约 8~20GB / 28~64GB | 复杂根因推理、长 runbook 理解；需要较好的 GPU |
| 72B+ | 40GB+ / 144GB+ | 多卡多机，运维场景性价比急剧下降 |

选 Qwen2.5-7B-Instruct 当本模块默认的四个理由：

1. **中文强**：运维知识库、告警、复盘大多是中国团队的中文语料；
2. **许可干净**：7B 档为 Apache-2.0，内网商用无障碍（个别档位许可不同，以模型卡为准）；
3. **支持 Function Calling**：第 4 章 Agent 的工具调用直接依赖；
4. **尺寸合适**：7B 是"单张 24GB 卡能全精度跑完还有 KV cache 富余"的最大档，也是工具调用可靠性开始稳定的档位。

提醒：开源模型迭代极快（Qwen3、DeepSeek、Llama 轮番出新），本章的方法论不随版本过期——显存粗算、OpenAI 兼容、评测集回归（02 章）这三件事，比"追最新模型"重要得多。

## 6. OpenAI 兼容 API：换模型不换代码

两条路线最终都落到同一套接口上，这不是偶然——OpenAI 的 chat/completions 已是事实标准，Ollama、vLLM、llama.cpp、各类商业服务几乎全部兼容：

| 端点 | 用途 | mini_agent 用到的位置 |
|---|---|---|
| `GET /v1/models` | 列出可用模型（核对 served-model-name） | 部署后人工验证 |
| `POST /v1/chat/completions` | 对话 + 工具调用（tools/tool_calls 字段） | 每轮循环的核心请求 |

这层兼容换来的工程性质：**切换成本趋近于零**（换模型、换引擎、从本地迁到内网 GPU 集群，代码只动 `LLM_BASE_URL`/`LLM_MODEL`/`LLM_API_KEY` 三个环境变量）；**生态即插即用**（OpenAI SDK、LangChain、各类 Agent 框架无需改造直连本地端点）；**评测可对照**（同一份 02 章评测集跑在不同端点上横向比较）。也要知道"兼容 ≠ 全等"：各引擎对参数与工具调用细节的支持不一，引擎或模型变更后务必回归评测集。

## 7. 安全收口：端点也是运维对象

私有化部署解决"数据不出域"，但端点自己成了新的敏感资产，收口三件事：

1. **监听地址**：个人用一律绑 127.0.0.1（两条路线本章的默认写法）；团队共享时不要直接 `0.0.0.0` 裸奔，前置一层带认证的反向代理（nginx basic auth / 网关）。
2. **API key**：vLLM 用 `--api-key` 设置（或环境变量 `VLLM_API_KEY`），正好对接 mini_agent 的 `LLM_API_KEY`；Ollama 内网单机可免，暴露即加。
3. **数据残留**：模型权重本身可以带走你微调过的私有语料（本模块不微调，风险低）；真正的残留热点是**服务日志**——请求全文可能落盘，日志要进 12-logging 的轮转与脱敏体系。

## 实战演练：端到端跑通"本地模型 + Agent"

目标：完成 部署 → 验证 → 接 Agent → 收口 四步。有 NVIDIA GPU 走 A 路线（与第 4 章默认值严格对齐），无 GPU 走 B 路线（降级验证流程）。

A 路线（GPU，vLLM）：

```bash
# [任意有 NVIDIA GPU 的节点] 启动服务（第 4 节的完整命令）
vllm serve Qwen/Qwen2.5-7B-Instruct \
  --host 127.0.0.1 --port 8000 \
  --served-model-name qwen2.5-7b-instruct \
  --enable-auto-tool-choice --tool-call-parser hermes
```

B 路线（无 GPU，Ollama + 小模型，验证流程用）：

```bash
# [任意节点] 用 1.5B 走通全流程（CPU 十几秒级响应，工具调用能力弱于 7B）
ollama pull qwen2.5:1.5b
export LLM_BASE_URL=http://127.0.0.1:11434/v1
export LLM_MODEL=qwen2.5:1.5b
```

四步验收（两条路线通用；B 路线已 export 过则跳过对应步）：

```bash
# [任意节点] 1) 端点活着，模型名正确
curl -s http://127.0.0.1:8000/v1/models | jq -r '.data[].id'   # A 路线
curl -s http://127.0.0.1:11434/v1/models | jq -r '.data[].id'  # B 路线

# [任意节点] 2) 能对话（A 路线示例；B 路线改端口与模型名）
curl -s http://127.0.0.1:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen2.5-7b-instruct","messages":[{"role":"user","content":"kubectl 里查看 Pod 事件的命令是什么？只回答命令"}]}' \
  | jq -r '.choices[0].message.content'

# [任意节点] 3) 第 4 章的 Agent 零改动直连（A 路线无需 export，默认值即本章部署）
python3 mini_agent.py "集群里有没有不健康的 Pod？只做只读诊断。"

# [任意节点] 4) 暴露面收口：确认只监听回环地址
ss -tlnp | grep -E '8000|11434'
# 预期：127.0.0.1:8000（或 127.0.0.1:11434），不应出现 0.0.0.0 / [::]
```

第 3 步跑通的标准：Agent 能发起 `k8s_diag` 的 tool_call、拿到白名单内的 kubectl 输出、最终给出带证据的结论——第 4 章画的循环在你自己的端点上转起来了；跑不通先对照第 4 章与本章的常见坑。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| vLLM 启动即 CUDA OOM | 显存只算了权重，漏了 KV cache 与开销；或卡上还跑着别的进程 | 用第 2 节公式重算；换 INT4 量化权重/降并发上下文；`nvidia-smi` 清理占用 |
| curl 报 connection refused / 404 | BASE 少了 `/v1`，或端口搞错（vLLM 8000、Ollama 11434） | `LLM_BASE_URL` 必须带 `/v1`；按引擎核对端口 |
| 请求返回 model not found | served-model-name/tag 与请求里的 model 不一致 | vLLM 加 `--served-model-name`；Ollama 用 `ollama list` 核对 tag |
| Agent 发不出 tool_calls | vLLM 没开 `--enable-auto-tool-choice`，或模型太小不支持 | 补参数（Qwen 用 hermes parser）；换 7B 及以上档 |
| 磁盘被模型塞满 | 多个 5~15GB 权重堆叠 | `ollama rm` / 清理 HF 缓存；定一个团队默认模型 |
| 换端点后效果明显变差 | 模型/精度/引擎变了没回归 | 任何模型侧变更都跑一遍 02 章评测集再上线 |

## 自测

1. 一张 24GB 卡想跑 Qwen2.5-14B INT4 并留 16k 上下文，粗算是否可行？为什么高并发时 KV cache 的显存可能反超权重，vLLM 用什么缓解？

<details><summary>答案</summary>

14B × 0.5 字节 ≈ 8~9GB（含量化开销）；KV cache 按 14B 的配置粗算（48 层、8 个 KV 头，约 192KB/token），16k ≈ 3GB。合计约 12GB，加 10%~20% 开销仍在 24GB 内，可行但余量不多，瓶颈在固定占 8~9GB 的权重——KV cache 可以靠限制上下文与并发压缩，权重压不掉。KV cache 总量 = 每 token 占用 × 序列长度 × 并发数，三项都随负载线性增长，高并发长上下文时会反超权重；vLLM 用 PagedAttention 把 KV cache 按页分配、减少碎片，用 continuous batching 让新请求持续填满 GPU——同样显存服务更多并发。
</details>

2. OpenAI 兼容层让你在"换模型"时省了什么、省不了什么？举一个省不了的例子。

<details><summary>答案</summary>

省了：接口协议层——请求/响应结构、SDK、Agent 的工具调用循环全部复用，切换只是改环境变量。省不了：行为差异——不同模型/精度的指令遵循能力、工具调用可靠性、中文表现都不同，必须用评测集回归；此外各引擎对参数与字段的支持也不完全一致。例子：把 7B 换成 1.5B 后接口全通，但 tool_calls 可能经常发不出来——协议兼容不等于能力等价。
</details>

3. 端点为什么默认绑 127.0.0.1？团队三个人都要用，正确的做法是什么？

<details><summary>答案</summary>

绑回环地址意味着只有本机进程能访问——LLM 端点没有认证、没有限流、收到什么 prompt 就处理什么，暴露在内网等于给所有人一个免费算你的运维数据的入口。多人共用的正确做法：绑定内网地址并前置带认证的反向代理（或 vLLM `--api-key`），配合审计日志；而不是图省事 `--host 0.0.0.0` 裸奔。
</details>

4. 第 3 章 RAG + 本章本地端点组合后，数据边界变成了什么样？还有哪些残留风险？

<details><summary>答案</summary>

知识库内容与排障 prompt 全程留在本机/内网：检索本地完成，生成在本地端点完成，公网零流出。残留风险：端点服务的日志可能记录请求全文（含知识库片段），需要轮转与脱敏；模型权重与 ops-kb 目录本身要进备份与权限管理；若未来用内网语料微调，权重也会携带私有信息。边界是"缩小了"，不是"消失了"。
</details>

## 延伸阅读

- vLLM 官方文档（quickstart、OpenAI 兼容服务、工具调用参数）：<https://docs.vllm.ai/>
- Ollama 官方仓库（安装、模型库、OpenAI 兼容说明）：<https://github.com/ollama/ollama>
- Qwen2.5 官方仓库（模型卡、许可、各档位配置）：<https://github.com/QwenLM/Qwen2.5>
- OpenAI API 参考（chat/completions 与 tools 字段的事实标准定义）：<https://platform.openai.com/docs/api-reference>
