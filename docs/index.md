---
layout: home

hero:
  name: Learning Hub
  text: 云原生 SRE 学习中心
  tagline: 17 个模块 · 250 篇文档 · 65 套实测 lab——从 Linux 内核底座一路打到 AIOps，面向 CKA / CKS / PCA 三证的系统化自学路线。
  actions:
    - theme: brand
      text: 开始学习（27 周路线图）
      link: /ROADMAP.html
    - theme: alt
      text: 故障场景速查
      link: /SCENARIOS.html
    - theme: alt
      text: GitHub 仓库
      link: https://github.com/Thneoly/sre-learning-hub

features:
  - icon: ☸️
    title: 云原生平台域
    details: 以容器为中心的平台栈：从内核底座到数据面组件。覆盖 01-linux · 02-programming · 03-docker · 04-k8s · 05-cka · 07-cks · 11-middleware · 12-data-streaming · 14-cloud · 16-bigdata · 17-distributed。
    link: /04-k8s-fundamentals/01-why-kubernetes.html
    linkText: 从 Kubernetes 原理开始
  - icon: 🚀
    title: DevOps 工程域
    details: 优化软件交付流程：流动、反馈、持续学习（三步工作法）。覆盖 06-cicd-iac-gitops：Git / GitLab CI / Jenkins & GHA / ArgoCD / Ansible / Terraform / Kustomize / Helm。
    link: /06-cicd-iac-gitops/00-devops-concepts.html
    linkText: 从 DevOps 概念开始
  - icon: 🔭
    title: 可观测与 SRE 域
    details: 优化系统可用性：指标 / 日志 / 追踪三支柱 + SLO、错误预算与混沌工程。覆盖 08-pca · 09-otel · 10-logging · 13-sre-methodology。
    link: /08-pca/00-exam-overview.html
    linkText: 从可观测概念开始
  - icon: 🤖
    title: AIOps 智能域（增值）
    details: 用 LLM 增强判断：辅助排障、RAG 知识库、Agent 护栏。覆盖 15-aiops-llm 与 scripts/faults 故障靶场。
    link: /15-aiops-llm/01-aiops-landscape.html
    linkText: 从 AIOps 全景开始
---

四支柱的关系（也是面试的标准答法）：**DevOps 优化工程流程，SRE 优化系统可用性，云原生是两者的平台底座，AIOps 是叠加在三者之上的能力倍增器。** 模块编号 = 建议学习顺序，能力支柱 = 「我是谁 / 补哪块」的自查画像——同一套材料的两种读法。

## 如何使用本站

- 系统学习：按 [学习路线图](/ROADMAP.html)（27 周 · 10 阶段 · 每阶段一个贯穿闭环）推进；每一章都建议配合对应 lab 动手。
- 排障速查：出故障时先翻 [场景速查](/SCENARIOS.html)，按「症状 → 定位命令 → 对应章节」找到入口。
- 顶部导航按**能力支柱**分组进入 17 个模块；每个模块的侧栏包含「章节」与「Labs」两组，lab 的**题目（task）与解答（solution）分开成页**，方便先做后对答案。

## Labs 需要练习集群

本站只提供**阅读视图**。所有 lab 的 `check.sh` 自动判分、故障注入靶场（`scripts/faults`）都需要在一套 **Ubuntu 练习集群**（VMware 里的 kubeadm 单节点即可，坏了就重建）上运行。环境搭建见 [仓库 README](/README.html) 与 `scripts/setup/`。

> 故障注入脚本仅用于练习集群，永远不要对生产环境执行。

## portal 是另一个入口

仓库里的 `portal/index.html` 是一个**免服务器、免联网**的学习平台：17 模块进度追踪、内置题库测验、CKA 考试计时器、kubectl / vim / PromQL 速查。与本书站互补——系统阅读用这里，自测与进度管理用 portal。
