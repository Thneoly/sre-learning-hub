# Learning Hub — 云原生 SRE 学习中心（15 模块）

一套自包含的**学习材料 + 学习平台 + 练习平台**，专为以下情况设计：

- 有网络/运维背景，正从传统运维转向云原生 SRE
- 有一套 VMware 练习环境（新建独立 kubeadm 集群，可随时重build）
- 目标：系统掌握地基 → 容器 → K8s → 工程化 → 可观测 → 数据组件 → 方法论，拿下 CKA / CKS / PCA 三证

> 模块顺序依据两份市场调研（`_meta/research-2026-08-*.md`）：社区路线图 + 招聘平台 JD 双向验证。

## 公开仓说明

- **`05-cka/question-bank-manual-v1.35.md` 不入库**（来自付费资料，版权原因）；部分 CKA 章节会引用它，请自行将你手里的题库手册放到该路径
- 证书备考与三视图（学习顺序/能力支柱/场景索引）见 `ROADMAP.md`、`SCENARIOS.md`
- 许可：代码 MIT，文档 CC BY-NC-SA 4.0（见 LICENSE）

## 15 个模块

| # | 目录 | 内容 | 定位 |
|---|---|---|---|
| 01 | `01-linux/` | 6 章 + 2 labs | **地基**：启动/systemd、文件系统、内存、CFS、**内核网络栈**（网络背景变现）、性能分析 60 秒 |
| 02 | `02-programming/` | 5 章 + 2 labs | **地基**：Shell → Python → Go(选)；产出巡检脚本/exporter |
| 03 | `03-docker/` | 7 章 + 8 labs | 容器原理：namespace/cgroup/镜像分层/网络/安全/运行时生态 |
| 04 | `04-k8s-fundamentals/` | 14 章 | **原理层**：架构与控制循环、Pod、网络、存储、调度、RBAC、etcd |
| 05 | `05-cka/` | 7 章 + 20 labs + 题库手册 | CKA 备考：缺口补全（RBAC/kubeadm/etcd 备份）+ 考试策略 |
| 06 | `06-cicd-iac-gitops/` | 9 章 + 3 labs | **工程化**：DevOps 概念、Git、GitLab CI、Jenkins/GHA、ArgoCD、Ansible+Jinja2、Terraform、Kustomize、Helm |
| 07 | `07-cks/` | 7 章 + 10 labs | CKS 备考：加固、审计、Falco/Trivy/AppArmor/gVisor/加密 |
| 08 | `08-pca/` | 7 章 + 2 题集 | PCA 备考：Prometheus 架构、PromQL(28%)、告警、Grafana |
| 09 | `09-otel/` | 6 章 + 3 labs | OpenTelemetry(1.x 行业事实标准)：三信号、Collector、K8s 自动注入 |
| 10 | `10-logging/` | 4 章 + 1 lab | 日志支柱：ELK（面试高频）+ Loki（云原生主流）+ K8s 日志 |
| 11 | `11-middleware/` | 四件套各 3 章 + lab | nginx/MySQL/Redis/MongoDB：SRE 运维视角全覆盖 |
| 12 | `12-data-streaming/` | Kafka 3 章 + Flink 2 章 + labs | 日志模型、ISR/KRaft、流处理、exactly-once、反压 |
| 13 | `13-sre-methodology/` | 5 章 + 2 labs | **中级→高级分水岭**：SLO/错误预算、On-call、无责复盘、混沌工程 |
| 14 | `14-cloud/` | 3 章 + 1 lab | 云平台：阿里云实操 + AWS 对照 + 认证路径 |
| 15 | `15-aiops-llm/` | 4 章 + 1 lab | **差异化选修**：LLM 辅助排障、RAG 知识库、Agent skill、安全护栏 |

## 能力支柱视图（"我是谁 / 补哪块"的叙事层）

同一套模块的三种看法：**编号 = 学习顺序**（下面这个表 = 能力画像），排障速查见 `SCENARIOS.md`（场景索引）。

| 支柱 | 回答的岗位画像 | 覆盖模块 | 支柱的"一句话" |
|---|---|---|---|
| **云原生平台域** | 云原生运维 / 容器平台工程师 | 01-linux · 02-programming · 03-docker · 04-k8s · 05-cka · 07-cks · 11-middleware · 12-data-streaming · 14-cloud | 以容器为中心的平台栈：从内核底座到数据面组件 |
| **DevOps 工程域** | DevOps 工程师 / 交付效率方向 | 06-cicd-iac-gitops（DevOps 概念/Git/GitLab CI/Jenkins/ArgoCD/Ansible/Terraform） | 优化软件交付流程：流动、反馈、持续学习（三步工作法） |
| **可观测与 SRE 域** | SRE / 稳定性方向 | 08-pca · 09-otel · 10-logging · 13-sre-methodology | 优化系统可用性：指标/日志/追踪 + SLO/错误预算/混沌 |
| **AIOps 智能域**（增值） | 智能运维 / AIOps 工程师 | 15-aiops-llm + scripts/faults 靶场 | 用 LLM 增强判断：辅助排障、RAG 知识库、Agent 护栏 |

三支柱的关系（也是面试的标准答法）：DevOps 优化**工程流程**，SRE 优化**系统可用性**，云原生是两者的**平台底座**，AIOps 是叠加在三者上的**能力倍增器**。

## 怎么用（三种方式）

### 1. 学习平台（浏览器打开）

双击 `portal/index.html`——无需服务器、无需联网。含：15 模块进度追踪（自动存本地）、内置题库测验、CKA 考试计时器、kubectl/vim/PromQL 速查。
（如需站内阅读 markdown，先在 portal/ 下运行 `build-content.ps1` 生成 content.js。）

### 2. 系统学习（按 ROADMAP.md 的阶段与闭环推进）

见 [ROADMAP.md](ROADMAP.md)：25 周、9 个阶段、每个阶段一个贯穿闭环（代码→镜像→IaC→CI/CD→监控→注故障→排查→复盘）。
`05-cka/question-bank-manual-v1.35.md` 是你原来的题库操作手册，与基础章节 1:1 互补：先读原理章 → 再做题库题 → 最后 lab 巩固。

### 3. 练习平台（在 Ubuntu VM 上跑）

```
scripts/
├── setup/    环境初始化：装 Docker、kubeadm 单节点集群、Prometheus 栈、重置
├── faults/   12 个故障注入脚本（支持 --restore 恢复）+ FIXES.md（答案）
├── labctl.sh 练习平台 CLI：list/show/check/scores/solution/fault/drill/timer
└── lib/      公共函数库
```

lab 统一入口：`bash scripts/labctl.sh list`（`check` 判分记分、`fault` 注故障、`drill` 靶场抽卡，详见 `scripts/README.md` 的"labctl 练习平台"）。

每个 lab 含三件套：`task.md`（题目）、`check.sh`（自动判分 SCORE: X/Y）、`solution.md`（详解）。
推荐闭环：**读章节 → 做 lab → 跑 check.sh 判分 → 注入一个 fault 限时排障**。

## 环境约定

- 命令标注运行位置：`[master]` `[worker1]` `[任意节点]` `[本地Windows]`
- `check.sh` 可独立运行（内嵌判分逻辑），在 Ubuntu VM 上执行
- 故障注入脚本仅用于**练习集群**，永远不要对生产环境执行
