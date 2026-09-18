# 学习路线图 v2：29 周 · 10 阶段 · 10 个贯穿闭环

> 每周投入 8~10 小时。结构依据两份市场调研（`_meta/research-2026-08-*.md`）：
> ① 学习顺序对齐社区路线图共识（地基→容器→编排→工程化→可观测→方法论）；
> ② 每阶段带一个**贯穿闭环**（MVP 迭代式，来自 dynamic-devops-roadmap 的反线性建议）——
> 不做"学完 A 再学 B"的串行刷课，而是每阶段都完整走一遍"**构建→部署→观测→破坏→修复→复盘**"。

## 阶段总览

```
阶段 0  地基       周 1-4    01-linux + 02-programming
阶段 1  容器       周 5-6    03-docker
阶段 2  编排+考证   周 7-10   04-k8s-fundamentals + 05-cka → ★考 CKA
阶段 3  工程化     周 11-13  06-ci-cd + 07-cd-gitops + 08-iac（CI/CD→GitOps 交付→IaC）
阶段 4  安全+考证   周 14-15  09-cks → ★考 CKS
阶段 5  可观测+考证 周 16-19  10-pca → ★考 PCA；11-otel；12-logging
阶段 6  数据组件    周 20-23  13-middleware + 14-data-streaming + 18-bigdata
阶段 7  方法论+理论 周 24-27  15-sre-methodology + 19-distributed（分布式理论是方法论的技术底座，大厂终面深水区）
阶段 8  云         周 28     16-cloud
阶段 9  差异化     周 29     17-aiops-llm（+补 02/05 的 Go 选学）
阶段 R  参考（穿插使用）      20-lifecycles——全组件生命周期图鉴
```

## 每周计划与闭环

### 阶段 0 · 地基（周 1-4）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 1 | `01-linux/01-03`（启动/文件系统/内存）+ lab 01 | 能讲清 buffer vs cache、OOM 选受害者逻辑 |
| 2 | `01-linux/04-06`（进程/内核网络栈/性能分析）+ lab 02 | 能 60 秒内定位 CPU 高/内存涨/磁盘满 |
| 3 | `02-programming/01-02`（Shell 基础/运维模式）+ lab 01 | 交付 batch-inspect.sh 巡检脚本 |
| 4 | `02-programming/03-04`（Python）+ lab 02（05 Go 与 06 Celery 选学） | 交付一个自定义 exporter |

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

### 阶段 3 · 工程化：CI/CD + GitOps + IaC（周 11-13）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 11 | `06-ci-cd/00-03`（DevOps 概念/Git/GitLab CI/Jenkins+GHA）+ lab 01 | 一条完整的 lint→build→镜像 pipeline |
| 12 | `06-ci-cd/04-05`（SonarQube/Harbor）+ labs 02-03 → `07-cd-gitops/00-01`（ArgoCD/Kustomize）+ lab 01 | 质量门禁挡住一次坏提交；镜像进私有仓库；Application Healthy/Synced；base/overlays 双环境渲染成功 |
| 13 | `07-cd-gitops/02-03`（Helm/交付平台）+ labs 02-04 → `08-iac` 全部（Ansible/Terraform + labs 01-02） | Helm chart 完成一次坏升级回滚；playbook 批量部署跑通；terraform plan/apply 与漂移检测闭环 |

**🔁 闭环 3**：完整 GitOps 链路——改代码 → GitLab CI 出镜像（SonarQube 门禁 + Harbor 入仓）→ Git 改 tag → ArgoCD 自动同步到集群；集群与虚机环境全部由 Ansible/Terraform 可重建。这是简历上"CI/CD+GitOps 落地"的实证。

**进阶 capstone（选学，第一遍赶进度可后置）**：`07-cd-gitops/03`（交付平台）+ `07-cd-gitops/labs 03-04`（供应链闸门/多环境晋升）——把闭环 3 升级为带镜像签名（cosign）与漏洞闸门（Trivy 阈值）、多环境晋升、飞书通知和面板聚合的**企业级交付平台**；第二遍或求职冲刺期做。

### 阶段 4 · 安全 + CKS（周 14-15）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 14 | `09-cks/00-03` + labs 01-04 | CIS/PSA/容器层加固全实操 |
| 15 | `09-cks/04-06` + labs 05-10 + killer.sh CKS → **★ 考 CKS** | audit/Falco/加密全真装过 |

**🔁 闭环 4**：给闭环 2 部署到 K8s 的应用做一次安全加固——Pod Security restricted、非 root + cap-drop、seccompProfile，并把 Trivy 镜像扫描卡点接进 CI；最后用 audit policy + Falco 规则实际检出一次"违规行为"告警。

### 阶段 5 · 可观测 + PCA（周 16-19）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 16 | `10-pca/00-03`（PromQL 花最多时间）+ 练习题前 40 | PromQL 正确率 90%+ |
| 17 | `10-pca/04-06` + 剩余题 + portal 测验 → **★ 考 PCA** | 75%+ |
| 18 | `11-otel/00-03` + labs 01-02 | Collector 部署 + 零代码注入 |
| 19 | `11-otel/04-05` + `12-logging`（4 章 + lab） | Astronomy Shop 起 + Loki 日志查询 |

**🔁 闭环 5**：给闭环 3 的应用接齐三支柱——metrics(Prometheus)+logs(Loki)+traces(OTel→Jaeger)，在 Grafana 同屏看全。

### 阶段 6 · 数据组件（周 20-23）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 20 | `13-middleware/nginx` + `mysql` + 两个 lab | 独立定位 502/504；主从搭建 |
| 21 | `13-middleware/redis` + `mongodb` + 两个 lab（`rabbitmq` 3 章 + lab 选学，六件套补位） | 讲清哨兵 failover 与副本集选举 |
| 22 | `14-data-streaming/kafka` + `flink` + labs | 解释 ISR/KRaft；定位一次反压 |
| 23 | `18-bigdata/00-03`（全景/HDFS/YARN/Hive）+ labs 01 | 讲清副本放置与 safemode；伪分布式 HDFS 跑通 |

**🔁 闭环 6**：给业务加 MySQL+Redis 后端（Deployment+PVC+Service），exporter 接入 Prometheus，注入一次缓存雪崩场景排障。

### 阶段 6 进阶选学 · 大数据深化（主线第 23 周之外的内容）

| 材料 | 里程碑 |
|---|---|
| `18-bigdata/04-06`（Spark/OLAP/ZooKeeper）+ labs 02-03 | 跑一次数据倾斜加盐实验；Doris 建表导入查询 |
| `18-bigdata/07`（湖仓表格式深讲）+ lab 04 | Flink→Paimon 入湖闭环，亲眼看清 snapshot/manifest 元数据树 |
| `13-middleware/postgresql`（3 章）+ `18-bigdata/08`（ClickHouse）+ 各 lab | PG 流复制与 Patroni 讲得清；CH 分布式表跑通 |

> 大数据模块按 JD 调研定位为"大数据运维专线岗画像"（百度 20-30K·16薪一类岗位），非主线路径；目标这类岗位的学员把第 23 周展开成两周学完。

### 阶段 7 · 方法论+理论（周 24-27）

| 周 | 材料 | 里程碑 |
|---|---|---|
| 24 | `15-sre/01-02`（SRE 基础/SLO）+ lab 01 | 燃烧率告警上线 |
| 25 | `15-sre/03-05` + lab 02 | 一次完整混沌演练 + 无责复盘 |
| 26 | `19-distributed/00-03`（故障模型/一致性/共识）+ lab 01 | 白板讲清 Raft 选举日志复制全流程；etcd kill-leader 亲测选举耗时 |
| 26+ | `19-distributed/08-11`（经典问题/Paxos/CRDT/协调工具）+ lab 03 | 两将军/拜占庭/FLP 能讲工程后果；Paxos vs Raft 选型一句话；Consul 服务发现跑通 |
| 27 | `19-distributed/04-07`（事务/分片/Gossip/排障）+ lab 02 | 拆穿"恰好一次"的真相；分布式锁的三个坑能各举一例 |

**🔁 闭环 7（毕业演练）**：定 SLO → 注入故障 → 验证稳态假设 → 修复 → 写 postmortem → 沉淀 runbook。这一套讲出来就是高级 SRE 面试的答案。

### 阶段 8 · 云（周 28）

`16-cloud/01-03` + VPC 设计 lab；有阿里云账号就实操，没有做纸面设计。可顺手报名阿里云 ACP。

**🔁 闭环 8**：把前面闭环产出的整套系统做一次"上云设计"——VPC/交换机/安全组规划、节点与存储选型、估算一份月账单（按量 vs 包年包月的临界点），输出一页架构图 + 成本测算；有账号就在云上真实拉起最小可用版。

### 阶段 9 · 差异化（周 29）

`17-aiops-llm/` 全部 + lab；补 `02-programming/05`（Go）。
**🔁 闭环 9**：用 LLM 辅助排障一次注入故障（完整记录对话与验证），修复后把复盘沉淀进知识库——这就是"运维 LLM 化"的个人实证。

## 与现有资产的配合

- **题库手册**（`05-cka/question-bank-manual-v1.35.md`）：第 9 周集中刷，每题先读对应原理章
- **VMware 练习集群**：所有 lab/fault 的靶场；坏了就 `scripts/setup/reset-cluster.sh` + `kubeadm-single-node.sh` 重建
- **killer.sh**：报名送的 2 次 session 留给第 10/15 周
- **portal**：每周日更新进度勾选 + 做模块测验

## 三条纪律

1. **动手 > 阅读**：每 1 小时阅读配至少 1 小时终端操作
2. **每章自测合上材料回答**，答不出回去重读
3. **模拟考只开 kubernetes.io**——对齐考场约束；但阶段 9 的 LLM 排障练习除外，那是练"人机协同"
