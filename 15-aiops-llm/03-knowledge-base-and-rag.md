# 03 · 运维知识库与 RAG

> 模块：AIOps/LLM 运维（15）｜ 建议时长：2 小时 ｜ 前置：01/02 章 ｜ 关联认证：—（无直接考点，AIOps 岗位核心技能）

## 学习目标

- 能解释通用 LLM 为什么"不懂你的内网"（训练数据、时效、私有上下文三个原因）
- 能画出 RAG 的离线/在线两条链路（分块→embedding→检索→生成），并说明每个环节做什么
- 能按统一 front-matter 规范整理四类运维知识源（runbook/复盘/变更记录/告警历史）
- 能部署并使用一个不依赖任何云服务的最小检索系统（BM25 + 本地文件），并把检索结果拼成 RAG prompt
- 能解释知识沉淀飞轮的运转条件，以及为什么复盘模板里必须强制"知识条目"一节

## 1. 为什么通用 LLM 不懂你的内网

问通用 LLM"订单库连不上怎么办"，它会给你一篇正确的通用教程：检查网络、检查连接数、看慢日志。但你真正需要的是：

- "订单库是 `10.30.1.21:3306` 那个 MySQL 集群，主从切换工单要走 DBA 平台"
- "上个月扩容后 max_connections 调过，当时踩过 DNS 缓存的坑"
- "这套系统的连接池配置在 Apollo 的 `order-db` 命名空间"

通用模型给不出后三句，原因有三个，每个都无法靠"更强的模型"解决：

| 原因 | 说明 | 后果 |
|---|---|---|
| 训练数据里没有你的内网 | 内网 IP、主机命名、内部平台名从未出现在公开语料 | 问了也是编 |
| 训练有截止时间 | 你的 K8s 版本、中间件版本、上周的变更 | 版本相关的问题按旧版本答 |
| 私有上下文不公开 | 命名规范、拓扑约定、"哪个告警可以忽略"的团队共识 | 这些知识只存在于老员工脑子和 IM 记录里 |

把私有知识补进模型的办法有两种：

| 维度 | 微调（fine-tuning） | RAG（检索增强生成） |
|---|---|---|
| 原理 | 用领域数据继续训练，改模型参数 | 推理时检索相关知识，塞进 prompt |
| 知识更新 | 重新训练（天级/万元级） | 改文档（分钟级/零成本） |
| 可溯源 | 无法回答"依据是什么" | 每个回答能指回具体文档 |
| 适合 | 固定的风格/术语/输出格式 | 频繁更新的运维事实 |
| 运维场景结论 | 几乎不用 | **首选**：故障知识天天新增，回答必须可审计 |

## 2. RAG 原理通俗图解

RAG（Retrieval-Augmented Generation）的本质：**先查资料，再回答，并把资料原文摆在模型眼前**。两条链路：

```
离线索引（每次知识库更新后跑一次）
────────────────────────────────────────────────────────
  运维文档(md)      分块              向量索引/倒排索引
  runbook.md  ──►  按标题切成  ──►   每块算出 embedding  ──►  存入库
  复盘-xxx.md       300~500 字块     (一串数字/坐标)          (可搜索)

在线问答（值班提问时）
────────────────────────────────────────────────────────
  提问:"Pod 一直        问题也算          取相似度            拼进 prompt:
  ImagePullBackOff" ──► embedding ──►  TopK 块 ──►  "只依据以下资料回答"
                         ↓              (K=3)         + 资料原文 + 问题
                                                            │
                                                            ▼
                                                    LLM 生成回答
                                                  (回答里能引用资料来源)
```

四个环节逐个说：

1. **分块（chunking）**：文档不能整篇塞进 prompt（超长且噪声大），要切成块。运维 runbook 的最佳分块单位是**二级标题的一节**——一节讲一个完整动作，天然自包含；每块带上标题路径（如 `镜像排障 > tag 不存在`）作为元数据。
2. **embedding**：把文本变成一个高维向量（可以理解成坐标），语义相近的文本坐标相近。"Pod 拉不到镜像"和"ImagePullBackOff"坐标很近，虽然它们没有一个共同的词——这就是它比关键词匹配强的地方。
3. **检索（retrieval）**：把提问也变成向量，在库里找坐标最近的 K 块。生产系统常用**混合检索**：向量（语义）+ BM25（关键词，对精确术语如 `ImagePullBackOff`、`PLEG` 更准）。
4. **生成（generation）**：把检索到的原文 + 问题 + "只依据资料回答，资料没有就说不知道"一起交给 LLM。最后这句约束是防幻觉的关键一环。

一条铁律：**检索质量决定生成质量**。检索没召回正确的知识块，模型只能对着错误资料流利地胡说。所以运维 RAG 项目的实际工作量分布是：知识整理 70%、检索调优 20%、prompt 工程 10%。

## 3. 运维知识源的整理规范

四类知识源，各自的整理要点：

| 知识源 | 内容 | 更新频率 | 整理要点 |
|---|---|---|---|
| runbook | 告警/故障的标准处理步骤 | 每次新告警规则上线 | 一告警一条；步骤可直接复制执行；区分只读/变更步骤 |
| 复盘（postmortem） | 时间线、根因、行动项 | 每次故障后 | 无指责文化（13 模块 04 章）；根因一段话可被检索命中 |
| 变更记录 | 谁在何时改了什么 | 每次变更 | 排障时第一反应就是"最近改了什么"；保留变更前后值 |
| 告警历史 | 告警何时触发、何时恢复、谁处理 | 自动沉淀 | 统计"高频告警"驱动降噪；关联到对应 runbook |

统一目录结构与 front-matter 规范（front-matter 是给检索和统计用的，不是装饰）：

```
# [任意节点] 知识库目录结构示例
ops-kb/
├── runbook/
│   ├── k8s-imagepull-backoff.md
│   ├── k8s-pod-pending.md
│   └── node-notready.md
├── postmortem/
│   └── 2026-08-11-order-db-timeout.md
├── change/
│   └── 2026-08-15-mysql-maxconnections.md
└── alert-history/
    └── 2026-08.md            # 按月归档，脚本自动追加
```

一个 runbook 条目的完整样例（front-matter 字段是规范核心）：

```
# [任意节点] 文件 ops-kb/runbook/k8s-imagepull-backoff.md 的内容
---
id: runbook-k8s-imagepull-backoff
title: Pod ImagePullBackOff / ErrImagePull 处理
source: runbook
severity: P3
tags: [kubernetes, image, kubelet]
last_reviewed: 2026-08-20
owner: sre-team
---

## 现象
Pod 状态 ErrImagePull 或 ImagePullBackOff，describe 的 Events 段有
Failed to pull image ... 报错。

## 定位命令（只读）
kubectl -n <ns> describe pod <pod> | sed -n '/Events:/,$p'
kubectl -n <ns> get deploy <dep> -o jsonpath='{.spec.template.spec.containers[*].image}'

## 常见根因
1. tag 不存在/拼写错误（Events 报 manifest ... not found）
2. registry 不可达或限流（Events 报 timeout / toomanyrequests）
3. 私有仓库缺 imagePullSecrets（Events 报 unauthorized）

## 修复
把镜像指回确认存在的 tag：kubectl -n <ns> set image deployment/<dep> <container>=<image>
变更后验证：kubectl -n <ns> rollout status deployment/<dep>

## 关联
复盘：postmortem/2026-08-11-order-db-timeout.md（同周镜像变更事故）
```

三条整理纪律：

1. **去敏规范**：入库前替换真实公网 IP（内网保留段可留）、凭据/token 一律不落库、手机号/工号脱敏。知识库会被整段塞进 prompt——它流向哪里，取决于你的 LLM 部署在哪里。
2. **可检索优先**：标题写"故障的关键词"（`Pod ImagePullBackOff 处理`），不要写"关于某个问题的说明"。
3. **last_reviewed 必填**：超过一个季度没复审的条目在检索结果里降权——过时的 runbook 比没有更危险。

## 实战演练：最小 RAG 问答系统（零云服务依赖）

设计目标：一台有 python3 的机器 + 一个目录的 markdown，不装数据库、不调云 API。检索层用 BM25（关键词打分）起步，理由：零依赖、可解释、对运维场景里的精确术语（错误码、资源名）反而比向量检索更准；embedding 之后作为升级路径。

BM25 一句话原理：一个词在某文档出现越多、在整个库里越罕见，该文档与查询的相关度得分越高。这正是经典搜索引擎的打分法，离线部分退化成"建倒排索引"，用纯 Python 标准库就能写。

```python
# [任意节点或本地] 文件 retriever.py —— 最小 BM25 检索器（仅标准库，支持中文）
#!/usr/bin/env python3
"""用法: python3 retriever.py <kb目录> <查询词...>
输出按相关度排序的 Top3 条目路径与得分。"""
import math
import re
import sys
from collections import Counter
from pathlib import Path


def tokenize(text: str) -> list:
    text = text.lower()
    tokens = re.findall(r"[a-z0-9]+", text)          # 英文/数字按词
    cjk = [ch for ch in text if "一" <= ch <= "鿿"]
    tokens += cjk                                     # 中文按单字
    tokens += [a + b for a, b in zip(cjk, cjk[1:])]   # 加中文二元组提高区分度
    return tokens


class BM25:
    def __init__(self, docs, k1=1.5, b=0.75):
        self.k1, self.b = k1, b
        self.docs = docs
        self.tf = [Counter(tokenize(d["text"])) for d in docs]
        self.dl = [len(t) for t in self.tf]
        self.avgdl = (sum(self.dl) / len(self.dl)) if self.dl else 1.0
        self.n = len(docs)
        df = Counter()
        for t in self.tf:
            df.update(t.keys())
        self.df = df

    def idf(self, w):
        n_w = self.df.get(w, 0)
        return math.log((self.n - n_w + 0.5) / (n_w + 0.5) + 1.0)

    def search(self, query, top_k=3):
        q = tokenize(query)
        scored = []
        for i in range(self.n):
            s = 0.0
            for w in q:
                f = self.tf[i].get(w, 0)
                if f == 0:
                    continue
                norm = 1.0 - self.b + self.b * self.dl[i] / self.avgdl
                s += self.idf(w) * f * (self.k1 + 1.0) / (f + self.k1 * norm)
            scored.append((s, i))
        scored.sort(key=lambda x: (-x[0], x[1]))
        return [(self.docs[i], s) for s, i in scored[:top_k] if s > 0]


def main():
    if len(sys.argv) < 3:
        sys.exit("用法: python3 retriever.py <kb目录> <查询词...>")
    root = Path(sys.argv[1])
    docs = [{"path": str(p), "text": p.read_text(encoding="utf-8")}
            for p in sorted(root.rglob("*.md"))]
    if not docs:
        sys.exit(f"错误: {root} 下没有找到 .md 文件")
    bm = BM25(docs)
    query = " ".join(sys.argv[2:])
    hits = bm.search(query)
    if not hits:
        print("（无命中条目）")
        return
    for rank, (d, s) in enumerate(hits, 1):
        title = next((l for l in d["text"].splitlines() if l.startswith("# ")), "")
        print(f"{rank}. score={s:.2f}\t{d['path']}\t{title.strip('# ').strip()}")


if __name__ == "__main__":
    main()
```

实战部署：

```bash
# [任意节点] 建知识库并放入条目（内容用上一节的样例）
mkdir -p ~/ops-kb/runbook ~/ops-kb/postmortem ~/ops-kb/change
# 把 retriever.py 与第 3 节的 runbook 样例保存到对应路径后：
python3 retriever.py ~/ops-kb Pod 一直 ImagePullBackOff
```

预期输出（score 因库内容而异）：

```
1. score=18.42  /root/ops-kb/runbook/k8s-imagepull-backoff.md   Pod ImagePullBackOff / ErrImagePull 处理
2. score=6.10   /root/ops-kb/runbook/k8s-pod-pending.md          Pod 一直 Pending 处理
3. score=2.87   /root/ops-kb/postmortem/2026-08-11-order-db-timeout.md  订单库超时故障复盘
```

把 Top1 条目拼进 RAG prompt：

```bash
# [任意节点] 检索 + 拼接，生成最终提交给 LLM 的完整 prompt
TOP1=$(python3 retriever.py ~/ops-kb ImagePullBackOff | awk 'NR==1{print $3}')
{
  echo "你是运维知识库问答助手。只依据下面给出的知识条目回答问题；"
  echo "条目没写的内容必须回答'知识库中无此信息'，禁止编造。回答末尾注明依据的条目路径。"
  echo "问题：新部署的 Pod 一直 ImagePullBackOff，怎么排查？"
  echo "----知识条目 ${TOP1} ----"
  cat "${TOP1}"
} > /tmp/rag-prompt.txt
head -4 /tmp/rag-prompt.txt
```

把 `/tmp/rag-prompt.txt` 内容交给任意 LLM。对比实验（感受检索的价值）：同一个问题不带知识条目再问一次——通用回答正是第 1 节说的"正确但没用"的教程。

升级路径（每一步都在现有结构上替换，不动整体设计）：

| 阶段 | 检索层 | 收益 | 成本 |
|---|---|---|---|
| 起步（本节） | BM25 关键词 | 零依赖、当天可用 | 半天 |
| 二期 | 本地 embedding 模型 + 向量库（Chroma/Qdrant） | 语义泛化："拉不到镜像"能命中 ImagePullBackOff | 需跑模型的服务器 |
| 三期 | 混合检索 + rerank | 精确术语与语义泛化兼得 | 调参与评测集维护 |

## 4. 知识沉淀的飞轮

```
        ┌──────────────────────────────────────────────┐
        │                                              │
        ▼                                              │
   排障发生 ──► 复盘(T5模板) ──► 知识条目入kb ──► RAG检索命中 │
        │                                              │
        │                                              │
        ▼                                              │
   下次同类故障 MTTA 更短 ──► 值班更有余量 ──► 更认真复盘 ──┘
```

飞轮能转起来的前提只有两个，但都很硬：

1. **复盘模板里强制"知识沉淀"一节**。第 2 章 T5 模板要求行动项必须含知识沉淀项——不是巧合。没有强制，条目永远"下次再补"，飞轮停在第一圈。
2. **写入路径足够短**。从"复盘写完"到"条目可被检索"超过 5 分钟，人就会绕开它。本节的实现里这就是一条 `cp` 或一次 `git commit`。

反过来度量飞轮是否在转：月度统计"故障处理过程中知识库命中率"（排障时检索并采用了条目的故障占比）和"条目复用次数"。命中率持续上升，说明飞轮在加速；大量故障检索不中，说明第 3 节的整理欠账。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 检索命中了条目，回答仍然错 | 条目本身过时（版本变了命令没变） | last_reviewed 制度 + 超期降权/复审 |
| 向量检索找不到精确术语（如 PLEG） | 术语在语义空间里没有邻居 | 混合检索：BM25 兜住精确匹配 |
| 整篇 runbook 作为一个块 | 分块过大，检索命中后塞进 prompt 的噪声多 | 按二级标题分节，300~500 字一块 |
| 知识库建了三个月只有 5 条 | 写入靠自觉 | 复盘模板强制知识条目；值班交接检查 |
| 回答"看起来有依据"但引用了不存在的文档 | 模型把"注明来源"理解成了生成一个像样的路径 | 让模型只能从检索结果给的路径列表中选择，而不是自由生成 |
| 内网凭据进了知识库被拼进 prompt 发往外部 LLM | 去敏规范没执行 | 入库脱敏 + 优先本地部署模型 + 定期 grep 扫描敏感模式 |

## 自测

1. 你的 K8s 上周刚升级到 v1.31，问 LLM 某个新参数的行为，它给了 v1.24 已移除的旧参数解释。这是三个"不懂内网"原因里的哪一个？RAG 怎么修？

<details><summary>答案</summary>

训练时效问题。RAG 的修法：知识库里放版本相关的事实条目（"本集群 v1.31，参数 X 已由 Y 取代"），检索后让模型"只依据条目回答"。注意 RAG 修的是"你们环境的现状"，模型本身的版本知识截止仍需靠升级模型或换新版本模型解决。
</details>

2. 为什么运维场景选 RAG 而不是微调？给出一个微调更合适的运维子场景。

<details><summary>答案</summary>

运维事实更新频繁（周级），微调更新成本是天级/万元级；且排障回答要求可溯源（能指回 runbook），微调做不到。微调更合适的子场景：固定输出格式（如让模型把任意告警原文解析成统一的 JSON 事件 schema）——风格与格式是模型的稳定能力，不随时间变化。
</details>

3. "检索质量决定生成质量"——如果 Top3 里混进了一条完全不相关的条目，会发生什么？如何在系统层面降低这种伤害？

<details><summary>答案</summary>

模型可能被无关条目带偏（把两个问题强行关联），或在回答里引用它造成误导。缓解：控制召回数量（K 不要贪大）；prompt 明确"资料与问题无关时可忽略"；检索层加相似度阈值过滤（本节实现的 `s > 0` 就是最朴素的阈值）。
</details>

4. 为什么说"过时的 runbook 比没有更危险"？

<details><summary>答案</summary>

没有 runbook 时人会谨慎地现场验证；过时 runbook 自带权威感，值班在凌晨三点倾向直接照抄——而它的命令可能是针对旧版本/旧拓扑的，照抄即事故。这就是 last_reviewed 与超期降权存在的原因。
</details>

5. 本节的 BM25 实现里，为什么要给中文加"二元组"（相邻两字组合）而不只用单字？

<details><summary>答案</summary>

单字的区分度太低："库"在几乎每篇运维文档里都出现，IDF 趋近于 0，等于没有信号；"镜像/""拉取/"这类二元组才能把相关文档和无关文档的分数拉开。英文词天然有边界所以不需要，这体现的是：分块与分词策略必须匹配语言与领域。
</details>

## 延伸阅读

- Chroma（本地优先的向量数据库，官方仓库）：<https://github.com/chroma-core/chroma>
- Qdrant（向量搜索引擎，官方仓库）：<https://github.com/qdrant/qdrant>
- FAISS（Meta 开源向量检索库）：<https://github.com/facebookresearch/faiss>
- Google SRE 书籍·postmortem 文化（知识沉淀飞轮的制度底座）：<https://sre.google/sre-book/postmortem-culture/>
