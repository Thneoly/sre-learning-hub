# 学习路线图 v2：26 周 · 9 阶段 · 9 个贯穿闭环

> 每周投入 8~10 小时。结构依据两份市场调研（`_meta/research-2026-08-*.md`）：
> ① 学习顺序对齐社区路线图共识（地基→容器→编排→工程化→可观测→方法论）；
> ② 每阶段带一个**贯穿闭环**（MVP 迭代式，来自 dynamic-devops-roadmap 的反线性建议）——
> 不做"学完 A 再学 B"的串行刷课，而是每阶段都完整走一遍"**构建→部署→观测→破坏→修复→复盘**"。

## 阶段总览

```
阶段 0  地基       周 1-4    01-linux + 02-programming
阶段 1  容器       周 5-6    03-docker
阶段 2  编排+考证   周 7-10   04-k8s-fundamentals + 05-cka → ★考 CKA
阶段 3  工程化     周 11-12   06-cicd-iac-gitops
阶段 4  安全+考证   周 13-14   07-cks → ★考 CKS
阶段 5  可观测+考证 周 15-18   08-pca → ★考 PCA；09-otel；10-logging
阶段 6  数据组件    周 19-22   11-middleware + 12-data-streaming + 16-bigdata
阶段 7  方法论     周 23-24   13-sre-methodology
阶段 8  云         周 25      14-cloud
阶段 9  差异化     周 26      15-aiops-llm（+补 02/05 的 Go 选学）
```

## 每周计划与闭环

### 阶段 0 · 地基（周 1-4）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 1 | `01-linux/01-03`（启动/文件系统/内存）+ lab 01 | 能讲清 buffer vs cache、OOM 选受害者逻辑 |
| 2 | `01-linux/04-06`（进程/内核网络栈/性能分析）+ lab 02 | 能 60 秒内定位 CPU 高/内存涨/磁盘满 |
| 3 | `02-programming/01-02`（Shell 基础/运维模式）+ lab 01 | 交付 batch-inspect.sh 巡检脚本 |
| 4 | `02-programming/03-04`（Python）+ lab 02（05 Go 选学留到阶段 9） | 交付一个自定义 exporter |

**🔁 闭环 0**：用自己写的巡检脚本 + 性能分析方法，排查一次 lab 注入的故障（CPU/内存/磁盘三选一），写一份 20 行的排查记录。

### 阶段 1 · 容器（周 5-6）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 5 | `03-docker/01-04`（原理/镜像/网络/存储）+ labs 01-04 | 能解释容器=受限的进程，画出端口映射包路径 |
| 6 | `03-docker/05-07`（Compose/安全/运行时）+ labs 05-08 | 多阶段构建 + 镜像扫描 + cap-drop 加固 |

**🔁 闭环 1**：把闭环 0 的巡检脚本容器化——多阶段 Dockerfile + compose 跑起来 + Trivy 扫描通过 + 非 root 运行。

### 阶段 2 · 编排 + CKA（周 7-10）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 7 | `04-k8s/01-04`（控制循环/架构/Pod/控制器）| 能画出控制面组件图并解释 list-watch |
| 8 | `04-k8s/05-11`（Service/Ingress/存储/调度/CNI/资源）| 能追踪 ingress→pod 全链路 |
| 9 | `04-k8s/12-14` + `05-cka/00-06` + 题库手册 16 题 + labs 全部 | etcd 备份恢复独立完成；题库 <7 分钟/题 |
| 10 | killer.sh 全真模拟 2 次 → **★ 考 CKA** | 66%+ |

**🔁 闭环 2**：把闭环 1 的应用迁到 K8s（Deployment+Service+Ingress+PVC），注入 `scripts/faults` 任意 2 个故障并修复。

### 阶段 3 · 工程化（周 11-12）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 11 | `06-cicd/01-03`（Git/GitLab CI/Jenkins+GHA）+ labs 01 | 一条完整的 lint→build→镜像 pipeline |
| 12 | `06-cicd/04-07`（ArgoCD/Ansible/Terraform/Kustomize）+ labs 02-03 | Application Healthy/Synced；playbook 跑通；base/overlays 双环境渲染成功 |

**🔁 闭环 3**：完整 GitOps 链路——改代码 → GitLab CI 出镜像 → Git 改 tag → ArgoCD 自动同步到集群。这是简历上"CI/CD+GitOps 落地"的实证。

### 阶段 4 · 安全 + CKS（周 13-14）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 13 | `07-cks/00-03` + labs 01-04 | CIS/PSA/容器层加固全实操 |
| 14 | `07-cks/04-06` + labs 05-10 + killer.sh CKS → **★ 考 CKS** | audit/Falco/加密全真装过 |

### 阶段 5 · 可观测 + PCA（周 15-18）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 15 | `08-pca/00-03`（PromQL 花最多时间）+ 练习题前 40 | PromQL 正确率 90%+ |
| 16 | `08-pca/04-06` + 剩余题 + portal 测验 → **★ 考 PCA** | 75%+ |
| 17 | `09-otel/00-03` + labs 01-02 | Collector 部署 + 零代码注入 |
| 18 | `09-otel/04-05` + `10-logging`（4 章 + lab） | Astronomy Shop 起 + Loki 日志查询 |

**🔁 闭环 5**：给闭环 3 的应用接齐三支柱——metrics(Prometheus)+logs(Loki)+traces(OTel→Jaeger)，在 Grafana 同屏看全。

### 阶段 6 · 数据组件（周 19-21）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 19 | `11-middleware/nginx` + `mysql` + 两个 lab | 独立定位 502/504；主从搭建 |
| 20 | `11-middleware/redis` + `mongodb` + 两个 lab | 讲清哨兵 failover 与副本集选举 |
| 21 | `12-data-streaming/kafka` + `flink` + labs | 解释 ISR/KRaft；定位一次反压 |
| 22 | `16-bigdata/00-03`（全景/HDFS/YARN/Hive）+ labs 01 | 讲清副本放置与 safemode；伪分布式 HDFS 跑通 |

**🔁 闭环 6**：给业务加 MySQL+Redis 后端（Deployment+PVC+Service），exporter 接入 Prometheus，注入一次缓存雪崩场景排障。

### 阶段 6 补充 · 大数据（第 22 周并入上表；进阶选学）

| 材料 | 里程碑 |
|---|---|
| `16-bigdata/04-06`（Spark/OLAP/ZooKeeper）+ labs 02-03 | 跑一次数据倾斜加盐实验；Doris 建表导入查询 |

> 大数据模块按 JD 调研定位为"大数据运维专线岗画像"（百度 20-30K·16薪一类岗位），非主线路径；目标这类岗位的学员把第 22 周展开成两周学完。

### 阶段 7 · 方法论（周 22-23）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 22 | `13-sre/01-02`（SRE 基础/SLO）+ lab 01 | 燃烧率告警上线 |
| 23 | `13-sre/03-05` + lab 02 | 一次完整混沌演练 + 无责复盘 |

**🔁 闭环 7（毕业演练）**：定 SLO → 注入故障 → 验证稳态假设 → 修复 → 写 postmortem → 沉淀 runbook。这一套讲出来就是高级 SRE 面试的答案。

### 阶段 8 · 云（周 24）

`14-cloud/01-03` + VPC 设计 lab；有阿里云账号就实操，没有做纸面设计。可顺手报名阿里云 ACP。

### 阶段 9 · 差异化（周 25）

`15-aiops-llm/` 全部 + lab；补 `02-programming/05`（Go）。
**🔁 闭环 9**：用 LLM 辅助排障一次注入故障（完整记录对话与验证），修复后把复盘沉淀进知识库——这就是"运维 LLM 化"的个人实证。

## 与现有资产的配合

- **题库手册**（`05-cka/question-bank-manual-v1.35.md`）：第 9 周集中刷，每题先读对应原理章
- **VMware 练习集群**：所有 lab/fault 的靶场；坏了就 `scripts/setup/reset-cluster.sh` + `kubeadm-single-node.sh` 重建
- **killer.sh**：报名送的 2 次 session 留给第 10/14 周
- **portal**：每周日更新进度勾选 + 做模块测验

## 三条纪律

1. **动手 > 阅读**：每 1 小时阅读配至少 1 小时终端操作
2. **每章自测合上材料回答**，答不出回去重读
3. **模拟考只开 kubernetes.io**——对齐考场约束；但阶段 9 的 LLM 排障练习除外，那是练"人机协同"
