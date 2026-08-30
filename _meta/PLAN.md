# learning-hub 文件清单（v2 · 15 模块版，验证以此为准）

所有路径相对于 `D:\SRE\chat\learning-hub\`。标注 [手工] 的由主会话负责，[已生成] 表示 v1 已完成，其余由对应 owner 生成。

```
README.md                                    [手工]
ROADMAP.md                                   [手工]
_meta/STYLE.md                               [手工]
_meta/PLAN.md                                [手工]
_meta/research-2026-08-community-github.md   [手工：调研存档]
_meta/research-2026-08-jd-platforms.md       [手工：调研存档]

portal/index.html                            [portal·已生成]
portal/build-content.ps1                     [portal·已生成]
portal/quiz-data.js                          [quiz·已生成]
portal/content.js                            [构建产物：由 build-content.ps1 生成，验证时无需检查]

01-linux/01-boot-and-systemd.md              [linux-materials]
01-linux/02-filesystem-and-io.md             [linux-materials]
01-linux/03-memory-deep-dive.md              [linux-materials]
01-linux/04-processes-and-cfs.md             [linux-materials]
01-linux/05-network-stack-internals.md       [linux-materials]
01-linux/06-performance-analysis.md          [linux-materials]
01-linux/labs/01-sixty-second-drill/{task.md,check.sh,solution.md}      [linux-labs]
01-linux/labs/02-network-stack-lab/{task.md,check.sh,solution.md}       [linux-labs]

02-programming/01-shell-fundamentals.md      [programming-materials]
02-programming/02-shell-ops-patterns.md      [programming-materials]
02-programming/03-python-for-ops.md          [programming-materials]
02-programming/04-python-ops-toolkit.md      [programming-materials]
02-programming/05-go-for-sre.md              [programming-materials]
02-programming/labs/01-shell-inspection/{task.md,check.sh,solution.md}  [programming-labs]
02-programming/labs/02-python-exporter/{task.md,check.sh,solution.md}   [programming-labs]

03-docker/01~07 章                           [docker-basics/advanced·已生成]
03-docker/labs/01-08                         [docker-labs·已生成]

04-k8s-fundamentals/01~14 章                 [k8s-core/net/sched/sec·已生成]

05-cka/00~06 章                              [cka-materials·已生成]
05-cka/question-bank-manual-v1.35.md         [手工：复制自 D:\Users\45110\cka-study-guide.md]
05-cka/labs/01-10（应用面）                   [cka-labs-app·已生成]
05-cka/labs/11-20（集群面）                   [cka-labs-ops·已生成]

06-cicd-iac-gitops/00-devops-concepts.md [devops-concepts·新补]
06-cicd-iac-gitops/01-git-deep-dive.md                    [cicd-materials]
06-cicd-iac-gitops/02-gitlab-ci.md                       [cicd-materials]
06-cicd-iac-gitops/03-jenkins-and-github-actions.md      [cicd-materials]
06-cicd-iac-gitops/04-argocd-gitops.md                   [cicd-materials]
06-cicd-iac-gitops/05-ansible.md                         [cicd-materials]
06-cicd-iac-gitops/06-terraform.md                       [cicd-materials]
06-cicd-iac-gitops/07-kustomize.md                       [教材对比补缺·已生成：base/overlays/patches/生成器/与 Helm 对比混用]
06-cicd-iac-gitops/08-helm.md                            [helm·新补]
06-cicd-iac-gitops/labs/01-gitlab-ci-pipeline/{task.md,check.sh,solution.md}   [cicd-labs]
06-cicd-iac-gitops/labs/02-argocd-gitops/{task.md,check.sh,solution.md}        [cicd-labs]
06-cicd-iac-gitops/labs/03-ansible-playbook/{task.md,check.sh,solution.md}     [cicd-labs]

07-cks/00~06 章 + labs/01-10                 [cks·已生成]

08-pca/00~06 章                              [pca-materials·已生成]
08-pca/labs/promql-exercises.md              [pca-labs·已生成·题库形态]
08-pca/labs/alertmanager-exercises.md        [pca-labs·已生成·题库形态]

09-otel/00~05 章 + labs/01-03                [otel·已生成]

10-logging/01-logging-concepts.md            [logging]
10-logging/02-elk-stack.md                   [logging]
10-logging/03-loki-stack.md                  [logging]
10-logging/04-k8s-logging.md                 [logging]
10-logging/labs/01-loki-pipeline/{task.md,check.sh,solution.md}          [logging]

11-middleware/nginx（3章+lab）                [mw-nginx·已生成]
11-middleware/mysql（3章+lab）                [mw-mysql·已生成]
11-middleware/redis（3章+lab）                [mw-redis·已生成]
11-middleware/mongodb（3章+lab）              [mw-mongo·已生成·待复核]

12-data-streaming/kafka（3章+lab）            [bd-kafka·已生成]
12-data-streaming/flink（2章+lab）            [bd-flink·已生成]

13-sre-methodology/01-sre-fundamentals.md                [sre-materials]
13-sre-methodology/02-sli-slo-error-budget.md           [sre-materials]
13-sre-methodology/03-oncall-incident-management.md     [sre-materials]
13-sre-methodology/04-postmortem-runbook.md             [sre-materials]
13-sre-methodology/05-chaos-engineering.md              [sre-materials]
13-sre-methodology/labs/01-slo-workshop/{task.md,check.sh,solution.md}          [sre-labs]
13-sre-methodology/labs/02-chaos-drill/{task.md,check.sh,solution.md}           [sre-labs]

14-cloud/01-cloud-fundamentals.md            [cloud]
14-cloud/02-aliyun-practice.md               [cloud]
14-cloud/03-aws-mapping-and-certs.md         [cloud]
14-cloud/labs/01-vpc-design/{task.md,check.sh,solution.md}                 [cloud]

15-aiops-llm/01-aiops-landscape.md           [aiops]
15-aiops-llm/02-llm-assisted-troubleshooting.md   [aiops]
15-aiops-llm/03-knowledge-base-and-rag.md    [aiops]
15-aiops-llm/04-agent-runbook-automation.md  [aiops]
15-aiops-llm/labs/01-llm-troubleshoot-drill/{task.md,check.sh,solution.md}     [aiops]

16-bigdata/00-bigdata-overview.md            [bd-mat-storage]
16-bigdata/01-hdfs.md                        [bd-mat-storage]
16-bigdata/02-yarn.md                        [bd-mat-storage]
16-bigdata/03-hive-warehouse.md              [bd-mat-compute]
16-bigdata/04-spark.md                       [bd-mat-compute]
16-bigdata/05-olap-doris-starrocks.md        [bd-mat-olap]
16-bigdata/06-zookeeper.md                   [bd-mat-olap]
16-bigdata/07-lakehouse-table-formats.md     [lakehouse·新补：Iceberg/Hudi/Paimon 深讲+湖仓运维专题]
16-bigdata/labs/04-lakehouse-flink-paimon/{task.md,check.sh,solution.md}    [lakehouse·新补]

17-distributed/00-distributed-overview.md            [dist-mat-a]
17-distributed/01-failure-models-and-time.md         [dist-mat-a]
17-distributed/02-consistency-models.md              [dist-mat-a]
17-distributed/03-consensus-and-replication.md       [dist-mat-a]
17-distributed/04-distributed-transactions.md        [dist-mat-b]
17-distributed/05-sharding-and-rebalancing.md        [dist-mat-b]
17-distributed/06-gossip-membership-fencing.md       [dist-mat-b]
17-distributed/07-distributed-troubleshooting.md     [dist-mat-b]
17-distributed/labs/01-etcd-raft-observation/{task.md,check.sh,solution.md}      [dist-labs]
17-distributed/labs/02-distributed-lock-idempotency/{task.md,check.sh,solution.md} [dist-labs]
16-bigdata/labs/01-hdfs-pseudo/{task.md,check.sh,solution.md}            [bd-labs]
16-bigdata/labs/02-spark-local/{task.md,check.sh,solution.md}            [bd-labs]
16-bigdata/labs/03-doris-quickstart/{task.md,check.sh,solution.md}       [bd-labs]

scripts/README.md + lib/common.sh            [scripts-setup·已生成]
scripts/setup/（5 个文件）                    [scripts-setup·已生成]
scripts/faults/（12 个 break-*.sh + FIXES.md）[scripts-faults·已生成]
```

## 形态说明

- 实操型模块（01/02/03/05/06/07/09/10/11/12/13/14/15）lab 一律三件套（task.md/check.sh/solution.md）
- 08-pca 允许"题库形态"单文件（见 STYLE.md 的题库文件模板节）
- 模块学习顺序依据 `_meta/research-2026-08-*.md` 两份调研：地基(Linux/编程) → 容器 → K8s → 工程化 → 安全 → 可观测 → 数据组件 → 方法论 → 云 → AIOps
