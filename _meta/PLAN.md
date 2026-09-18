# learning-hub 文件清单（v2 · 22 模块版，验证以此为准）

所有路径相对于 `D:\SRE\chat\learning-hub\`。标注 [手工] 的由主会话负责，[已生成] 表示 v1 已完成，其余由对应 owner 生成。

```
README.md                                    [手工]
ROADMAP.md                                   [手工]
SCENARIOS.md                                 [手工：排障场景速查，portal 与卡片生成器共同消费]
LICENSE / .gitignore / package.json          [手工：基础设施]
.github/workflows/deploy-pages.yml           [手工：GitHub Pages 发布（npm run docs:build 产物）]
_meta/STYLE.md                               [手工]
_meta/PLAN.md                                [手工]
_meta/research-2026-08-community-github.md   [手工：调研存档]
_meta/research-2026-08-jd-platforms.md       [手工：调研存档]
_meta/labtest-brief.md                       [手工：内部实测简报（含环境凭据），gitignore 排除、不入库]
_meta/ref-pdfs/                              [手工：参考资料 PDF，gitignore 排除、不入库]
_meta/skill-cards.json                       [构建产物：由 gen-skill-cards.mjs 生成]
_meta/skill-cards-anki.csv                   [构建产物：由 gen-skill-cards.mjs 生成（Anki 导出）]
_meta/audit-2026-09-18.json                  [手工：全量体检报告存档（断链/题库分布/薄章节/缺话题），本轮修复依据]

docs/（VitePress 书站：index.md + .vitepress/config.mts）  [docs·已生成]
docs/.vitepress/dist/                        [构建产物：npm run docs:build 生成，发布到 GitHub Pages]
scripts/gen-vitepress-nav.mjs                [docs·已生成：书站侧栏/导航生成器，docs:build 前自动执行]

portal/index.html                            [portal·已生成]
portal/build-content.ps1                     [portal·已生成]
portal/quiz-data.js                          [quiz·已生成]
portal/cards-data.js                         [构建产物：由 gen-skill-cards.mjs 生成，portal 运行时依赖]
portal/content.js                            [构建产物：由 build-content.ps1 生成，验证时无需检查]
scripts/gen-skill-cards.mjs                  [cards·已生成：技能卡生成器，产出上述三份卡库文件]

public/quiz.html                             [quiz·已生成：书站在线测验页（手机可用，零依赖纯静态）]
public/quiz-data.js                          [构建产物：gen-vitepress-nav.mjs 从 portal/quiz-data.js 拷贝的书站副本，gitignore 排除、勿手改]
scripts/verify-scenarios.js                  [手工：SCENARIOS.md 分类计数/路径/锚点与 portal SCN_CATS 对账校验器]

tools/juejin/（目录级：column-map.json + out/）   [手工：掘金专栏发布工具与产物——column-map.json 为专栏↔slug 映射；out/ 下 18 篇文章 md + 2 个 .meta.md + 4 张 png；.juejin.env（cookie）gitignore 排除、不入库]

01-linux/01-boot-and-systemd.md              [linux-materials]
01-linux/02-filesystem-and-io.md             [linux-materials]
01-linux/03-memory-deep-dive.md              [linux-materials]
01-linux/04-processes-and-cfs.md             [linux-materials]
01-linux/05-network-stack-internals.md       [linux-materials]
01-linux/06-performance-analysis.md          [linux-materials]
01-linux/07-users-and-permissions.md         [体检补缺·新补：凭证/sudo/SUID 与 capabilities 最小权限（衔接 CKS 加固）]
01-linux/labs/01-sixty-second-drill/{task.md,check.sh,solution.md}      [linux-labs]
01-linux/labs/02-network-stack-lab/{task.md,check.sh,solution.md}       [linux-labs]

02-programming/01-shell-fundamentals.md      [programming-materials]
02-programming/02-shell-ops-patterns.md      [programming-materials]
02-programming/03-python-for-ops.md          [programming-materials]
02-programming/04-python-ops-toolkit.md      [programming-materials]
02-programming/05-go-for-sre.md              [programming-materials]
02-programming/labs/01-shell-inspection/{task.md,check.sh,solution.md}  [programming-labs]
02-programming/labs/02-python-exporter/{task.md,check.sh,solution.md}   [programming-labs]
02-programming/06-celery-task-queue.md            [celery·新补：broker 选型/worker 模型/积压监控/幂等]
02-programming/07-operator-development.md         [体检补缺·新补：CRD 与 Operator 开发——把 04-k8s 控制循环亲手实现一遍]
02-programming/labs/03-celery-tasks/{task.md,check.sh,solution.md}      [celery·新补]

03-docker/01~07 章                           [docker-basics/advanced·已生成]
03-docker/labs/01-08                         [docker-labs·已生成]

04-k8s-fundamentals/01~14 章                 [k8s-core/net/sched/sec·已生成]
04-k8s-fundamentals/15-extension-model.md    [体检补缺·新补：K8s 扩展模型——CRD/自定义控制器/聚合 API/准入扩展]

05-cka/00~06 章                              [cka-materials·已生成]
05-cka/question-bank-manual-v1.35.md         [手工：复制自 D:\Users\45110\cka-study-guide.md]
05-cka/labs/01-10（应用面）                   [cka-labs-app·已生成]
05-cka/labs/11-20（集群面）                   [cka-labs-ops·已生成]

06-ci-cd/00-devops-concepts.md               [devops-concepts·新补（原 06 模块 00 章，拆分迁入）]
06-ci-cd/01-git-deep-dive.md                 [cicd-materials（原 06 模块 01 章，拆分迁入）]
06-ci-cd/02-gitlab-ci.md                     [cicd-materials（原 06 模块 02 章，拆分迁入）]
06-ci-cd/03-jenkins-and-github-actions.md    [cicd-materials（原 06 模块 03 章，拆分迁入）]
06-ci-cd/04-sonarqube.md                     [cicd-capstone·新补：质量门禁/重复代码/技术债/CI 集成（原 10 章）]
06-ci-cd/05-harbor.md                        [cicd-capstone·新补：企业镜像仓库/项目权限/复制/扫描/签名（原 09 章）]
06-ci-cd/labs/01-gitlab-ci-pipeline/{task.md,check.sh,solution.md}      [cicd-labs]
06-ci-cd/labs/02-sonarqube-gate/{task.md,check.sh,solution.md}          [cicd-capstone·新补（原 labs/05）]
06-ci-cd/labs/03-harbor-registry/{task.md,check.sh,solution.md}         [cicd-capstone·新补（原 labs/04）]

07-cd-gitops/00-argocd-gitops.md             [cicd-materials（原 06 模块 04 章，拆分迁入）]
07-cd-gitops/01-kustomize.md                 [教材对比补缺·已生成：base/overlays/patches/生成器/与 Helm 对比混用（原 07 章）]
07-cd-gitops/02-helm.md                      [helm·新补（原 08 章）]
07-cd-gitops/03-delivery-platform.md         [cicd-capstone·新补：多环境晋升/PR 流水线/供应链闸门/通知/面板聚合（原 11 章）]
07-cd-gitops/labs/01-argocd-gitops/{task.md,check.sh,solution.md}       [cicd-labs（原 labs/02）]
07-cd-gitops/labs/02-helm-chart/{task.md,check.sh,solution.md}          [cicd-capstone·新补：落实 Helm 章实战（原 labs/08）]
07-cd-gitops/labs/03-supply-chain-gates/{task.md,check.sh,solution.md}  [cicd-capstone·新补：cosign 签名闸门+Trivy 漏洞闸门（原 labs/06）]
07-cd-gitops/labs/04-environment-promotion/{task.md,check.sh,solution.md} [cicd-capstone·新补：建新环境+ArgoCD 晋升+飞书通知（原 labs/07）]

08-iac/00-ansible.md                         [cicd-materials（原 06 模块 05 章，拆分迁入）]
08-iac/01-terraform.md                       [cicd-materials（原 06 模块 06 章，拆分迁入）]
08-iac/labs/01-ansible-playbook/{task.md,check.sh,solution.md}           [cicd-labs（原 labs/03）]
08-iac/labs/02-terraform-local/{task.md,check.sh,solution.md}            [cicd-capstone·新补：local provider+多环境 tfvars+漂移（原 labs/09）]

09-cks/00~06 章 + labs/01-10                 [cks·已生成]

10-pca/00~06 章                              [pca-materials·已生成]
10-pca/labs/promql-exercises.md              [pca-labs·已生成·题库形态]
10-pca/labs/alertmanager-exercises.md        [pca-labs·已生成·题库形态]

11-otel/00~05 章 + labs/01-03                [otel·已生成]

12-logging/01-logging-concepts.md            [logging]
12-logging/02-elk-stack.md                   [logging]
12-logging/03-loki-stack.md                  [logging]
12-logging/04-k8s-logging.md                 [logging]
12-logging/labs/01-loki-pipeline/{task.md,check.sh,solution.md}          [logging]

13-middleware/nginx（3章+lab）                [mw-nginx·已生成]
13-middleware/mysql（3章+lab）                [mw-mysql·已生成]
13-middleware/redis（3章+lab）                [mw-redis·已生成]
13-middleware/mongodb（3章+lab）              [mw-mongo·已生成·待复核]
13-middleware/postgresql/01-architecture-and-mvcc.md   [pg-mat·新补：进程模型/WAL/MVCC vs InnoDB/vacuum]
13-middleware/postgresql/02-replication-and-ha.md      [pg-mat·新补：流复制/逻辑复制/Patroni/pgbouncer]
13-middleware/postgresql/03-tuning-troubleshooting.md  [pg-mat·新补：EXPLAIN/连接打满/bloat/备份/exporter]
13-middleware/postgresql/labs/01-streaming-replication/{task.md,check.sh,solution.md}  [pg-lab·新补]
13-middleware/rabbitmq/01-amqp-model.md      [rmq·新补：AMQP 四层模型/四种交换机/可靠性三道闸/与 Kafka·Redis pubsub 对比]
13-middleware/rabbitmq/02-ha-and-clustering.md  [rmq·新补：集群复制边界/仲裁队列 vs 镜像队列/网络分区/Shovel·Federation/Cluster Operator]
13-middleware/rabbitmq/03-operations-troubleshooting.md  [rmq·新补：Prometheus 指标/DLX 与延迟队列/四类高频故障/积压处置]
13-middleware/rabbitmq/labs/01-rabbitmq-quickstart/{task.md,check.sh,solution.md}  [rmq-lab·新补]

14-data-streaming/kafka（3章+lab）            [bd-kafka·已生成]
14-data-streaming/flink（3章+lab）            [bd-flink·已生成；03 章（运维与状态）为体检补缺·新补：算子 UID/rescale/内存模型/checkpoint 排障/CDC 入湖]

15-sre-methodology/01-sre-fundamentals.md                [sre-materials]
15-sre-methodology/02-sli-slo-error-budget.md           [sre-materials]
15-sre-methodology/03-oncall-incident-management.md     [sre-materials]
15-sre-methodology/04-postmortem-runbook.md             [sre-materials]
15-sre-methodology/05-chaos-engineering.md              [sre-materials]
15-sre-methodology/06-release-engineering.md            [体检补缺·新补：发布工程与变更管理——灰度/回滚/变更冻结]
15-sre-methodology/07-dr-business-continuity.md         [体检补缺·新补：灾备与业务连续性——RTO/RPO 与"备份 ≠ 可恢复"]
15-sre-methodology/labs/01-slo-workshop/{task.md,check.sh,solution.md}          [sre-labs]
15-sre-methodology/labs/02-chaos-drill/{task.md,check.sh,solution.md}           [sre-labs]

16-cloud/01-cloud-fundamentals.md            [cloud]
16-cloud/02-aliyun-practice.md               [cloud]
16-cloud/03-aws-mapping-and-certs.md         [cloud]
16-cloud/04-elastic-scaling.md               [体检补缺·新补：弹性伸缩——ESS/ASG 到 K8s 三层伸缩（HPA/VPA/KEDA）]
16-cloud/05-cloud-dr-backup.md               [体检补缺·新补：云上容灾与备份——跨 Region/跨账号/恢复演练]
16-cloud/labs/01-vpc-design/{task.md,check.sh,solution.md}                 [cloud]

17-aiops-llm/01-aiops-landscape.md           [aiops]
17-aiops-llm/02-llm-assisted-troubleshooting.md   [aiops]
17-aiops-llm/03-knowledge-base-and-rag.md    [aiops]
17-aiops-llm/04-agent-runbook-automation.md  [aiops]
17-aiops-llm/05-private-llm-deployment.md    [体检补缺·新补：私有化 LLM 端点——Ollama/vLLM/OpenAI 兼容 API]
17-aiops-llm/labs/01-llm-troubleshoot-drill/{task.md,check.sh,solution.md}     [aiops]

18-bigdata/00-bigdata-overview.md            [bd-mat-storage]
18-bigdata/01-hdfs.md                        [bd-mat-storage]
18-bigdata/02-yarn.md                        [bd-mat-storage]
18-bigdata/03-hive-warehouse.md              [bd-mat-compute]
18-bigdata/04-spark.md                       [bd-mat-compute]
18-bigdata/05-olap-doris-starrocks.md        [bd-mat-olap]
18-bigdata/06-zookeeper.md                   [bd-mat-olap]
18-bigdata/07-lakehouse-table-formats.md     [lakehouse·新补：Iceberg/Hudi/Paimon 深讲+湖仓运维专题]
18-bigdata/labs/01-hdfs-pseudo/{task.md,check.sh,solution.md}            [bd-labs]
18-bigdata/labs/02-spark-local/{task.md,check.sh,solution.md}            [bd-labs]
18-bigdata/labs/03-doris-quickstart/{task.md,check.sh,solution.md}       [bd-labs]
18-bigdata/labs/04-lakehouse-flink-paimon/{task.md,check.sh,solution.md}    [lakehouse·新补]
18-bigdata/08-clickhouse.md                      [ch·新补：列存/MergeTree/副本分布式表/merge/物化视图；07 章内加 Arrow 一节]
18-bigdata/labs/05-clickhouse-cluster/{task.md,check.sh,solution.md}        [ch·新补]

19-distributed/00-distributed-overview.md            [dist-mat-a]
19-distributed/01-failure-models-and-time.md         [dist-mat-a]
19-distributed/02-consistency-models.md              [dist-mat-a]
19-distributed/03-consensus-and-replication.md       [dist-mat-a]
19-distributed/04-distributed-transactions.md        [dist-mat-b]
19-distributed/05-sharding-and-rebalancing.md        [dist-mat-b]
19-distributed/06-gossip-membership-fencing.md       [dist-mat-b]
19-distributed/07-distributed-troubleshooting.md     [dist-mat-b]
19-distributed/08-classic-problems.md           [dist-mat-c·新补：两将军/拜占庭将军/FLP/分布式快照理论]
19-distributed/09-paxos-deep-dive.md            [dist-mat-c·新补：Basic→Multi-Paxos/Raft ZAB 语义对比]
19-distributed/10-crdt-and-convergence.md       [dist-mat-c·新补：CRDT/协同编辑/Redis CRDT/Gossip 数据层]
19-distributed/11-coordination-tools.md         [dist-mat-c·新补：etcd vs Consul vs Nacos/服务发现/选型]
19-distributed/labs/01-etcd-raft-observation/{task.md,check.sh,solution.md}      [dist-labs]
19-distributed/labs/03-consul-service-discovery/{task.md,check.sh,solution.md}   [dist-c·新补]
19-distributed/labs/02-distributed-lock-idempotency/{task.md,check.sh,solution.md} [dist-labs]

20-lifecycles/01-k8s-resource-lifecycles.md      [lifecycle·新补：K8s 八类资源 ASCII 状态图鉴（Pod/Deployment/Service/PVC/Node/HPA/Job/kubeadm 证书）+ 卡住场景]
20-lifecycles/02-data-component-lifecycles.md    [lifecycle·新补：etcd/Kafka/Redis/Sentinel/MySQL/PG·Patroni/RabbitMQ/Flink 八条状态机与 RTO/RPO 映射]

21-perf-testing/01-load-testing-tools.md     [perf·新补：性能压测工具与方法——k6/wrk/JMeter 与实战演练]
21-perf-testing/02-capacity-planning.md      [perf·新补：容量规划——从压测拐点到扩容决策（外推/N-1 验证/中间件基线）]

22-incident-stories/01-classic-incidents.md  [stories·新补：经典故障复盘故事集——四个故事 + 章末靶场演练路径（套 15-sre/04 复盘模板）]

scripts/README.md + lib/common.sh            [scripts-setup·已生成]
scripts/labctl.sh                            [scripts-setup·已生成：练习平台 CLI（list/show/check/scores/solution/fault/drill/timer）]
scripts/setup/（5 个文件）                    [scripts-setup·已生成]
scripts/faults/（12 个 break-*.sh + FIXES.md）[scripts-faults·已生成]
```

## 形态说明

- 实操型模块（01/02/03/05/06/07/08/09/11/12/13/14/15/16/17/18/19）lab 一律三件套（task.md/check.sh/solution.md）
- 10-pca 允许"题库形态"单文件（见 STYLE.md 的题库文件模板节）
- 20-lifecycles / 21-perf-testing / 22-incident-stories 为"图鉴/专题形态"模块，不带 labs 三件套：21 章内嵌"实战演练"、22 章内嵌"靶场演练路径"
- 模块学习顺序依据 `_meta/research-2026-08-*.md` 两份调研：地基(Linux/编程) → 容器 → K8s → 工程化（CI/CD→GitOps 交付→IaC）→ 安全 → 可观测 → 数据组件 → 方法论 → 云 → AIOps
- 原 `06-cicd-iac-gitops`（12 章 + 9 labs）已拆分为三个模块：`06-ci-cd`（CI 持续集成，6 章 + 3 labs）、`07-cd-gitops`（CD/GitOps 交付，4 章 + 4 labs）、`08-iac`（基础设施即代码，2 章 + 2 labs）；章节与 lab 按"06→07→08"学习顺序重新编号迁入，后续模块编号整体 +2
