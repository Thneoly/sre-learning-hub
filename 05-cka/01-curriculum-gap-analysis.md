# 01 · CKA 大纲 × 题库缺口分析

> 模块：05-cka ｜ 建议时长：1 小时 ｜ 关联认证：CKA（规划篇，先于 02~06 章阅读）

## 学习目标

- 能把题库 16 题逐一映射到 CKA 大纲域，并说出每题的覆盖程度（全/部分/边缘）
- 能对照五个大纲域的细分考点清单，逐条勾出自己"能闭眼做"与"没练过"的项
- 能指出题库在六大考点上的缺口：RBAC、kubeadm 升级、etcd 备份、Secret、证书、节点维护
- 能按"权重 × 缺口"排出自己的补习优先级，而不是平均用力
- 能为每个缺口指定对应章节与 lab 编号，并在复习中周期性重跑缺口自评

## 1. 分析对象与方法

分析对象两个：

1. **大纲**：CKA 现行考试域与权重（Troubleshooting 30%、Cluster Architecture/Installation/Configuration 25%、Services & Networking 20%、Workloads & Scheduling 15%、Storage 10%），以 cncf.io 公布的 Curriculum 为准。
2. **题库**：本仓库 `05-cka/question-bank-manual-v1.35.md`，共 16 道操作题 + 1 个集群恢复排错场景。

方法：每道题标注它实际练习到的大纲考点与覆盖程度，然后反查"大纲有而题库没有"的考点。覆盖程度分三档：

| 档位 | 判定 |
| --- | --- |
| 全覆盖 | 该考点的主干操作在题库里完整走过一遍，考场重现时可直接迁移 |
| 部分覆盖 | 只练到考点的一个侧面（如只排错没备份），另一侧仍是盲区 |
| 零覆盖 / 边缘 | 题库完全没有，或只属于"顺带摸到"的水平 |

## 2. 大纲域 × 题库 16 题映射表

| 题号 | 题库主题 | 大纲域 | 覆盖度 | 说明与指向 |
| --- | --- | --- | --- | --- |
| 1 | HPA 自动扩缩 + scaleDown 行为 | Workloads & Scheduling（scale applications） | 全覆盖 | lab 02；注意 `--cpu` 是 v1.35 语法，旧版叫 `--cpu-percent` |
| 2 | Ingress（ingressClassName / pathType / rewrite） | Services & Networking（Ingress） | 全覆盖 | lab 04 |
| 3 | Sidecar 日志容器（emptyDir 共享） | Troubleshooting（manage application logs）+ Workloads（多容器原语） | 全覆盖 | lab 09；logs 排错链再由 06 章补全 |
| 4 | StorageClass 设默认（is-default-class 注解） | Storage | 全覆盖 | lab 07 |
| 5 | Service NodePort（port/target-port 关系） | Services & Networking | 全覆盖 | lab 03 |
| 6 | PriorityClass 与抢占 | Workloads & Scheduling（调度） | 全覆盖 | lab 08；大纲原文是"资源限制如何影响调度"，优先级是其延伸 |
| 7 | Argo CD / Helm 部署 | Workloads & Scheduling（"manifest 管理与常见模板工具"的 awareness 层） | 边缘 | CKA 只要求"听说过、会读 chart"，不考 helm install 细节；无对应 lab，低优先 |
| 8 | PVC（accessModes / storageClassName） | Storage | 全覆盖 | lab 06；PV 静态绑定与回收策略要靠 lab 补 |
| 9 | Gateway API（Gateway/HTTPRoute） | Services & Networking（Ingress 的下一代，考纲目前只写 Ingress） | 边缘 | lab 10；当扩展题练，考纲内仍是 Ingress 优先 |
| 10 | NetworkPolicy（选择器组合逻辑） | Services & Networking | 全覆盖 | lab 05；"同组 AND、异组 OR"是题眼 |
| 11 | CRD 浏览 + kubectl explain | 超纲（CKA 不考 CRD 定义）；explain 是通用工具技能 | 边缘 | 无 lab；把 `kubectl explain` 当考场工具练熟即可（见 00 章 4.3） |
| 12 | ConfigMap（immutable / rollout restart） | Workloads & Scheduling（"用 ConfigMaps **和 Secrets** 配置应用"） | 部分覆盖 | 只练了 ConfigMap 一半，Secret 一半是缺口 → 05 章 |
| 13 | Calico CNI 迁移（CIDR 一致性） | Cluster Architecture（provision infrastructure / CNI） | 部分覆盖 | 练的是"换 CNI"，但 kubeadm init 本体没练 → 03 章 |
| 14 | 资源管理（Capacity/Allocatable/requests/scale） | Workloads & Scheduling + Troubleshooting（monitor metrics） | 部分覆盖 | lab 19；metrics-server 链路（kubectl top）题库未涉及 → 06 章 |
| 15 | etcd 排错 + 静态 Pod 修复 | Troubleshooting（cluster components） | 部分覆盖 | lab 15；etcd **备份/恢复**完全没练 → 04 章 + labs 13/20 |
| 16 | cri-dockerd + 内核参数 | Cluster Architecture（容器运行时与基础设施） | 部分覆盖 | runtime 从 Docker 迁到 containerd 的完整安装链没练 → 03 章 |

题库附带的"集群恢复排错场景"对应 Troubleshooting 域的节点/组件排错主线，由 06 章的方法论收编。

结构性结论：题库 16 题里 12 题集中在 Workloads / Storage / Services & Networking 三个域（合计权重 45%），而权重最高的两个域 Troubleshooting（30%）+ Cluster Architecture（25%）合计 55%，题库只有题 13/14/15/16 四题擦边、且都停在"部分覆盖"。**照题库顺序刷完就去考试，一半的分暴露在盲区里。**

用 ASCII 热力图直观一点（每格 ≈ 5% 权重）：

```
大纲域权重 vs 题库覆盖
Troubleshooting      30% ██████ ░ ░ ░ ░ ░ ░   题库: 3/6 格部分覆盖
Cluster Architecture 25% █████ ░ ░ ░ ░ ░ ░ ░   题库: 2/5 格部分覆盖(全在 P0 缺口)
Services & Networking 20% ████ ████            题库: 全覆盖(仅 Gateway/Ingress 边缘)
Workloads & Scheduling 15% ███                题库: 覆盖好(Secret 缺一角)
Storage              10% ██                  题库: 全覆盖
                     越靠左的格子越需要本模块 02~06 章补
```

## 3. 五个大纲域的细分考点清单

映射表回答"题库练了什么"，这一节回答"大纲到底要什么"。逐条自查：能闭眼操作打勾，想不起命令打叉——打叉的行就是你的私人缺口表。

### 3.1 Cluster Architecture, Installation & Configuration（25%，P0 缺口集中地）

| 大纲细分考点 | 题库覆盖 | 补习位置 |
| --- | --- | --- |
| manage RBAC（Role/ClusterRole/绑定） | 无 | 02 章 + labs 11、12 |
| use Kubeadm to install a cluster（含 HA 概念） | 题 13/16 只碰前置 | 03 章 |
| provision underlying infrastructure（runtime/内核参数/CNI） | 题 16 部分 | 03 章 1.1~1.4 |
| perform a version upgrade using Kubeadm | 无 | 03 章 4 节 + lab 14 |
| implement etcd backup and restore | 无 | 04 章 + labs 13、20 |
| manage a highly-available cluster（多 control-plane 概念） | 无 | 03 章 3.2、04 章 4.3 |

### 3.2 Troubleshooting（30%，权重最大）

| 大纲细分考点 | 题库覆盖 | 补习位置 |
| --- | --- | --- |
| evaluate cluster and node troubleshooting | 题 15 排错场景部分 | 06 章决策树 + labs 16、20 |
| troubleshoot cluster components（apiserver/etcd/scheduler） | 题 15（静态 Pod 修复） | 06 章速查表 #8/#9 + lab 15 |
| monitor cluster and application metrics | 题 14 只用 describe node | 06 章 L2/L5 + lab 19 |
| manage application logs（多容器/sidecar/previous） | 题 3 全覆盖 | lab 09 + 06 章 2.2 |
| 证书相关故障（隐含在组件排错里） | 无 | 05 章 |

### 3.3 Services & Networking（20%，覆盖最好）

| 大纲细分考点 | 题库覆盖 | 补习位置 |
| --- | --- | --- |
| understand Services（ClusterIP/NodePort/endpoints） | 题 5 全覆盖 | lab 03 |
| configure and use Ingress | 题 2 全覆盖 | lab 04 + 05 章 TLS |
| NetworkPolicies | 题 10 全覆盖 | lab 05 |
| CoreDNS / service discovery | 无 | 06 章速查表 #7 + lab 17 |
| host networking 基础（kube-proxy/端口转发） | 边缘 | 04-k8s-fundamentals 10 章 |

### 3.4 Workloads & Scheduling（15%）

| 大纲细分考点 | 题库覆盖 | 补习位置 |
| --- | --- | --- |
| Deployments 滚动更新与回滚 | 题 7 间接 | lab 01 |
| ConfigMaps and Secrets 配置应用 | 题 12（只有 ConfigMap） | 05 章 1 节 |
| scale applications | 题 1/14 全覆盖 | lab 02 |
| 自愈分布式原语（Job/CronJob/probes） | 部分 | 04-k8s-fundamentals 03/04 章 |
| resource limits 影响 Pod 调度 | 题 6/14 全覆盖 | lab 08 |
| manifest 管理与模板工具 awareness | 题 7（Helm） | 背 3 条 helm 命令即可 |

### 3.5 Storage（10%，题库最扎实）

| 大纲细分考点 | 题库覆盖 | 补习位置 |
| --- | --- | --- |
| PVC/PV 绑定、access modes、reclaim policy | 题 8 全覆盖 | lab 06 |
| StorageClass 与动态供给 | 题 4 全覆盖 | lab 07 |
| volume 类型（emptyDir/hostPath/configmap/secret） | 题 3/12 部分 | 05 章 1.4 + lab 09 |

## 4. 缺口清单：按"权重 × 缺口"排序

| 优先级 | 缺口考点 | 所在大纲域 | 题库现状 | 补齐位置 |
| --- | --- | --- | --- | --- |
| P0 | **RBAC**：Role/ClusterRole、RoleBinding、SA、can-i 验证 | Cluster Architecture（25%，明列考点） | 0 题 | 02 章 + labs 11、12 |
| P0 | **etcd 备份与恢复**：snapshot save/restore | Cluster Architecture（25%，明列考点） | 0 题（题 15 只做排错） | 04 章 + labs 13、20 |
| P0 | **kubeadm 版本升级**：plan/apply/drain/kubelet 升级 | Cluster Architecture（25%，明列考点） | 0 题 | 03 章 + lab 14 |
| P1 | **证书排错**：check-expiration、renew、x509 过期症状 | Troubleshooting + Cluster Architecture | 0 题 | 05 章 |
| P1 | **节点维护**：cordon/drain/uncordon 语义与参数 | Troubleshooting + Cluster Architecture（升级流程的一环） | 0 题 | 06 章 + lab 14 |
| P1 | **Secret**：三种创建方式、TLS secret + Ingress | Workloads & Scheduling（15%，与 ConfigMap 并列明列） | 题 12 只覆盖 ConfigMap | 05 章 |
| P1 | **集群监控**：metrics-server、kubectl top、日志定位 | Troubleshooting（30%，monitor metrics 明列） | 题 14 只用 describe node | 06 章 + lab 19 |
| P2 | **kubeadm 从零安装**：init 参数、join 流程 | Cluster Architecture（明列"用 kubeadm 安装集群"） | 题 13/16 只碰前置条件 | 03 章 |
| P2 | **CoreDNS 排错**：解析失败定位链 | Services & Networking（20%） | 0 题 | 06 章 + lab 17 |
| P2 | **Deployment 滚动更新/回滚** | Workloads & Scheduling | 题 7 间接涉及 | lab 01 |

## 5. 补齐路线图

假设你已刷完 04-k8s-fundamentals（概念层）与题库 16 题（应用层手感），下面是 05-cka 模块内部的执行顺序，每步"章节 → lab → 自测通过标准"：

| 步 | 内容 | 章节 / lab | 通过标准 | 时间预算 |
| --- | --- | --- | --- | --- |
| 1 | RBAC 三件套与 can-i 验证，5 道自编练习全对 | 02 章 → labs 11、12 | `auth can-i --as` 全部 yes；labs check.sh SCORE: 满分 | 3 h |
| 2 | kubeadm 从零 init + join + Calico，集群能重装 | 03 章（实战演练节） | 新装集群 `get nodes` 全 Ready、CoreDNS Running | 3 h |
| 3 | 升级演练：minor 版本原地升一遍 | 03 章 → lab 14 | 升级后版本号正确、节点全部 Ready、`get pod -A` 无异常 | 2.5 h |
| 4 | etcd snapshot 保存 + 恢复到新目录 + 静态 Pod 改 dataDir | 04 章 → labs 13、20 | 恢复后集群可读写、旧数据消失（或按题意保留） | 2.5 h |
| 5 | Secret 三种创建 + TLS secret 挂 Ingress | 05 章实战 | `curl -k` 经 Ingress 出证书即为 secret 里的那张 | 2 h |
| 6 | `kubeadm certs check-expiration` + 六张证书职责背熟 | 05 章 | 能默画 /etc/kubernetes/pki 树并说清六张证书各自服务谁 | 1.5 h |
| 7 | drain 维护全流程 + 排错决策树 + 10 大故障速查 | 06 章 → labs 16、18、19 | 决策树五层每层至少亲手跑过一次命令 | 3.5 h |

合计约 18 小时（不含 lab 重做）。建议与 labs 目录交叉进行——先读章节再进 lab，lab 卡住回章节"常见坑"表对号入座；每完成一步回到第 6 节自评表把对应行打勾。

## 6. 30 分钟缺口自评（可周期性重跑）

做完一轮补习后，按下面清单逐条实操（不是口头回答），完成的打勾。全部打勾 = 大纲域上无死角，可以进入全真模拟。

```bash
# [master] 自评脚本：每行独立执行，能一次做对才算过
# 1. RBAC：60 秒内完成"Role + RoleBinding + can-i 正反验证"
kubectl -n selftest create sa t1
kubectl -n selftest create role r1 --verb=list --resource=pods
kubectl -n selftest create rolebinding b1 --role=r1 --serviceaccount=selftest:t1
kubectl auth can-i list pods -n selftest --as=system:serviceaccount:selftest:t1   # yes

# 2. etcd：不看文档写出 snapshot save 全参数
sudo mkdir -p /opt/etcd-backup
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/etcd-backup/selftest.db
sudo ETCDCTL_API=3 etcdctl snapshot status /opt/etcd-backup/selftest.db --write-out=table
```

| 自评项（脱离文档完成） | 关联 | 通过标准 |
| --- | --- | --- |
| RBAC 三步模板 + can-i 正反验证 | 02 章 | 全部 yes/no 符合预期 |
| 从内存写出 etcd save 全参数并成功出快照 | 04 章 | snapshot status 有非零 TOTAL KEYS |
| 恢复快照到新目录并改 etcd.yaml 两处 | 04 章 | 测试对象随快照回归 |
| drain 三参数各放行什么，口述 + 实操一次 | 06 章 | drain 卡住时能 30 秒内说出原因 |
| `kubeadm upgrade plan` 输出能读懂 | 03 章 | 指出可升版本与 etcd 目标版本 |
| 升级 worker 的六步顺序默写 | 03 章 | 与 4.4 步骤表一致 |
| Secret 三种创建 + TLS 挂 Ingress | 05 章 | curl -kv 看到 SAN 为自己的域名 |
| `check-expiration` 输出对应到六张证书 | 05 章 | 每行说出"谁连谁" |
| 十大故障现象的"第一检查命令" | 06 章 | 抽 3 条能秒答 |
| 03 章 1.1~1.4 前置从空 VM 跑一遍 | 03 章 | init 出 Ready 单节点集群 |

## 7. 题库本身的使用建议

1. **全覆盖题不必重做三遍**。题 1/2/3/4/5/8/10 已达"考场可迁移"水平，考前各花 5 分钟复述解法即可；时间应该砸给 02~06 章的缺口。
2. **部分覆盖题要补另一半**。题 15 的 etcd 排错值得保留，但必须补做 04 章的备份恢复；题 12 之后立刻做 05 章 Secret 实战，两者在考纲里是同一句话。
3. **边缘题降级处理**。题 7（Helm/Argo CD）、题 9（Gateway API）、题 11（CRD）超出 CKA 考纲主干：题 7 背 `helm template/install/repo` 三条命令足矣，题 9 在 Ingress 熟练后一天内可迁移，题 11 只留 `kubectl explain` 工具用法。
4. **题库环境即考场环境的近似**。`ssh cka0000XX` 到独立节点做题的习惯很好——CKA 考场就是"给你一台终端 + 独立集群"，保留"读题提取四要素 → 做题 → 验证"的肌肉记忆（四要素：context / namespace / 资源名 / 验收条件，见 00 章 3.3）。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 刷了两遍题库仍然心里没底 | 把"做过"当"会了"：题库只覆盖 45% 权重的域 | 用第 6 节自评表检验，缺口按第 5 节路线图补 |
| 复习时间全花在 Deployment/Service | 熟悉区舒适感：应用侧题"顺手"，运维侧题"麻烦" | 给 55% 权重的两大域强制排日历（P0 三项优先） |
| 边缘题（Helm/Gateway/CRD）挤占主力时间 | 误把题库当考纲 | 大纲域权重才是唯一依据；边缘题按第 7 节降级 |
| lab 做完不回顾，两周后归零 | 只有输入没有复盘闭环 | 每个 lab 结束对着 task.md 口述解法一遍；错题记进自评表 |
| 补习顺序乱（先做 6 章再回 2 章） | 章节间有依赖：升级依赖 drain，恢复依赖静态 Pod | 按 02→03→04→05→06 顺序，或按第 5 节表逐步走 |

## 自测

1. 题 15 练了 etcd 排错（改 `--etcd-servers` 地址），为什么它对"etcd 备份恢复"这个考点仍然算零覆盖？

<details><summary>答案</summary>

排错题练的是"apiserver 连不上 etcd 时改静态 Pod 参数"，考察路径是 `/etc/kubernetes/manifests/kube-apiserver.yaml`；备份恢复考点要求 `etcdctl snapshot save`（带一整套 TLS 参数）与 `snapshot restore --data-dir`（新目录 + 改 etcd 静态 Pod 的 hostPath/dataDir + 让 apiserver 读到旧数据）。两者共享"静态 Pod"这个背景知识，但操作对象、命令集、风险等级完全不同。见 04 章。
</details>

2. Cluster Architecture 域占 25%，题库里只有题 13 和 16 擦边。列出这个域在大纲里明列、而题库没覆盖的三个考点。

<details><summary>答案</summary>

（1）RBAC（manage role based access control）；（2）kubeadm 安装与版本升级（use Kubeadm to install a cluster / perform a version upgrade using Kubeadm）；（3）etcd 备份与恢复（implement etcd backup and restore）。三者恰好都是 P0 缺口，对应 02、03、04 章。
</details>

3. 为什么本题库把 Storage（10%）练得最扎实，反而建议在它上面花的时间最少？

<details><summary>答案</summary>

边际收益：Storage 两道题（题 4 StorageClass、题 8 PVC）已全覆盖该域全部明列考点（PVC/PV/SC/access modes/reclaim），再刷一遍收益趋近于零；而 55% 权重的两大域还有整块空白。备考时间的分配应服从"权重 × 缺口"而不是"哪块顺手续哪块"。
</details>

4. 你计划三周后考试，每周只有两个晚上（各 3 小时）。基于缺口分析给出排期原则，并写出第一周做什么。

<details><summary>答案</summary>

原则：P0 先行、章节与 lab 交替、最后一周留全真模拟（00 章时间轴 + 限时 120 分钟做混合题）。第一周（6 小时）：02 章 RBAC 通读 + 5 道自编练习（约 2.5h），lab 11 + lab 12（约 2h），04 章 etcd 备份恢复通读（1.5h，为第二周 lab 13/20 做铺垫）。
</details>

5. 考纲里 Workloads & Scheduling 的原文是"understand the use of ConfigMaps **and Secrets** to configure applications"。题 12 练完 ConfigMap 后，Secret 侧最少要补哪三个操作？

<details><summary>答案</summary>

（1）`kubectl create secret generic --from-literal/--from-file` 与 YAML（stringData）两种创建；（2）以环境变量与 volume 两种方式注入 Pod；（3）`kubectl create secret tls --cert/--key` 生成 TLS secret 并挂到 Ingress 的 `tls:` 段验证。全部在 05 章实战演练里。
</details>

## 延伸阅读

- CKA 考试域与权重（以官方 Curriculum PDF 为准）：https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/
- 题库文件（本仓库）：`05-cka/question-bank-manual-v1.35.md`
- 本模块 lab 清单与编号：`_meta/PLAN.md` 中 `05-cka/labs/` 一节
- kubeadm 升级官方文档（P0 缺口的权威参考）：https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
