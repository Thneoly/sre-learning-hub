# 00 · CKS 考试概览与备考策略

> 模块：CKS 备考 ｜ 建议时长：1 小时（通读）＋ 持续备考参考 ｜ 关联认证：CKS（前置 CKA）

## 学习目标

- 能说出 CKS 的报名前置条件、考试形式、题型与及格标准
- 能列出官方大纲六个域及权重，折算成题量预算并映射到本模块 7 篇文件的对应小节
- 能准确描述考试允许查阅的资料范围，避免因违规判零分
- 能针对"题面长、多子任务"的特点建立一套审题与做题流程

## 1. CKS 是什么，前置条件是什么

CKS（Certified Kubernetes Security Specialist）是 CNCF/Linux Foundation 的 Kubernetes 安全专家认证。它不是入门考试，官方明确要求：

> CKS 考生必须**先通过 CKA**（Certified Kubernetes Administrator）才能参加 CKS。

也就是说 CKA 是硬性前置（官方原文：candidates must have taken and passed the CKA exam prior to attempting the CKS exam）。如果你 CKA 已过、还在有效期内，就可以直接报名 CKS。

报名后你会获得两个资源，备考价值极高：

- **Killer.sh 模拟器**：2 次使用机会，每次激活后 36 小时有效，15~25 道题，与真实考试界面和难度高度一致，做完给评分
- 官方 Curriculum（域权重清单，见下节）

费用、补考次数、证书有效期（近年有从 24 个月延长到 36 个月的调整）这类商务条款会变动，一律以官方页面为准：<https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist-cks/>

## 2. 考试形式

| 项目 | 说明 |
| --- | --- |
| 形式 | 线上考试，PSI 远程监考（摄像头＋屏幕共享＋房间检查），需要政府签发带照片证件 |
| 时长 | 2 小时 |
| 题型 | 全部为实操性能题（performance-based），在浏览器内嵌终端里操作真实集群 |
| 题量 | 通常 15~20 题，每题按子任务数分值不等，部分分是可以拿到的 |
| 集群 | 题目分布在一个或多个集群/context 上，可用 `kubectl config get-contexts` 查看 |
| 计分 | 题目内部按子任务给分；总及格线约 67%（以官方最新说明为准） |
| 出分 | 考后 24 小时内在 LF 账户出结果 |
| 环境 | 集群一般为 kubeadm 部署；可通过 SSH 登录节点操作文件（如 static Pod manifest、kubelet 配置）；题目所需的工具与文件（trivy、apparmor_parser、falco 的安装包、示例 yaml 等）通常已在节点上备好或可从考试环境内获取，先找现成的再考虑自己安装 |

与 CKA 最大的区别：CKS 题目经常要求改**控制面组件参数**（kube-apiserver/kubelet 配置）、**节点层安全**（AppArmor/seccomp/sysctl）和**安全工具**（kube-bench/trivy/Falco/audit log）。换句话说，CKS 把你从"集群管理员"推到"集群安全工程师"的位置，SSH 到节点上改文件是家常便饭。

## 3. 官方大纲与本模块文件的映射

以下权重来自官方 Domains & Competencies（以官网与 github.com/cncf/curriculum 的最新版为准）：

| 域 | 权重 | 核心考点 → 正文落点 |
| --- | --- | --- |
| Cluster Setup | 10% | CIS 基准/kube-bench → 01 §1；Ingress TLS → 01 §6；校验平台二进制（sha256sum）→ 01 §5；NetworkPolicy 限制集群访问 → 03 §5；保护节点 metadata → 01 §5 |
| Cluster Hardening | 15% | RBAC 最小化 → 03 §3；ServiceAccount 谨慎使用 → 03 §4；收紧认证授权（apiserver/kubelet）→ 01 §2、§4；升级避免漏洞 → `05-cka/03-kubeadm-install-upgrade.md`（升级流程复用 CKA 模块） |
| System Hardening | 15% | 最小化主机攻击面 → 01 §5；AppArmor → 02 §3；seccomp → 02 §2；gVisor/Kata 沙箱 → 02 §4；内核加固参数 → 02 §5；最小权限 IAM 属云平台侧话题，本模块不展开 |
| Minimize Microservice Vulnerabilities | 20% | Pod Security Standards → 03 §2；管理 Secrets（静态加密/轮换）→ 06 全篇；沙箱隔离 → 02 §4；Pod 间加密（mTLS 概念）→ 03 §6；NetworkPolicy 分层 → 03 §5 |
| Supply Chain Security | 20% | 最小化基础镜像 → 04 §6；供应链视角/SBOM → 04 §1；镜像扫描（trivy）→ 04 §2；digest 固定 → 04 §3；cosign 签名校验 → 04 §4；允许仓库/准入链 → 04 §5；静态分析（kubesec）→ 04 §7 |
| Monitoring, Logging and Runtime Security | 20% | audit log → 05 §1；Falco 行为检测 → 05 §2；攻击链调查/容器逃逸 → 05 §3；容器不可变性 → 05 §4 |

### 3.1 权重折算成题量

按 15~20 题的中位（约 17 题）折算，复习预算这样分配（估算值，不是官方承诺）：

| 域 | 权重 | 约合题量 | 高频题型 |
| --- | --- | --- | --- |
| Minimize Microservice Vulnerabilities | 20% | ~3.5 题 | PSA label、关 SA token 自动挂载、NetworkPolicy 白名单 |
| Supply Chain Security | 20% | ~3.5 题 | trivy 扫描并阻断、digest 固定、ImagePolicyWebhook 配置链 |
| Monitoring, Logging and Runtime Security | 20% | ~3.5 题 | audit policy 编写挂载、Falco 规则命中、日志取证 |
| Cluster Hardening | 15% | ~2.5 题 | RBAC 收敛、apiserver/kubelet 安全 flag |
| System Hardening | 15% | ~2.5 题 | AppArmor profile 加载、seccomp、RuntimeClass |
| Cluster Setup | 10% | ~1.5 题 | Ingress TLS Secret、kube-bench 定位 FAIL、sha256 校验 |

结构性结论：三个 20% 域合计 60%，恰好对应本模块 03/04/05 三篇——它们应拿走你六成的动手练习时间；01/02 是所有题的"节点操作地基"；06 篇成题概率高（加密流程长、步骤可判分），不可漏。

这套权重出自 2024 年的大纲修订（此前 Cluster Setup 15%、Monitoring 15%）。不少备考资料仍按旧权重讲述，或把 Cluster Setup 并进其他域、报成"五域且监控占 30%"——那都不是当前官方口径，报名页与 cncf/curriculum 仓库为准。

本模块七篇文件的分工：

```
00-exam-overview            你在这里
01-cluster-hardening        CIS/kube-bench + 控制面组件加固 + 最小化节点 + Ingress TLS
02-system-hardening         seccomp / AppArmor / gVisor 与 Kata / 内核参数
03-microservice-vulnerabilities  PSA / RBAC 收权 / SA token / NetworkPolicy 分层 / mTLS 概念
04-supply-chain-security    trivy / digest 固定 / cosign / 准入链 / 最小镜像 / 静态分析
05-monitoring-auditing-runtime   audit policy / audit log / Falco / 容器逃逸
06-secret-encryption        etcd 静态加密 / 密钥轮换 / 验证与排坑
```

## 4. 允许查阅的资料范围

CKS 是"受限开卷"考试。基本原则：

- **允许**：kubernetes.io 域内的文档（/docs/ 及相关子页面、部分版本还开放 blog）；少量官方 GitHub 仓库及其文档（如 kubernetes、falcosecurity、aquasecurity 等项目仓库）
- **不允许**：Google/搜索引擎、Stack Overflow、任何论坛、博客、你自己的笔记、本地文件、聊天工具

两点提醒：

1. 允许清单会调整，考试系统内的 Important Information 页面展示的清单才是唯一标准
2. 允许 ≠ 来得及查。2 小时内要完成十几道实操题，凡是需要查文档才能写的配置，基本等于丢分。正确姿势是：常用配置（audit policy、EncryptionConfiguration、AppArmor annotation、PSA label、NetworkPolicy）练到能默写，文档只用来核对字段名或冷门语法

## 5. 题面长的特点与审题策略

CKS 的题干普遍 10~20 行，一题里常塞 4~6 个子任务，且**子任务之间有依赖**（例如：先建 SA 并禁 token 自动挂载，再写 NetworkPolicy，最后验证）。漏读一个限定词（namespace 名、label、端口号）整题报废。推荐流程：

```
第一遍（5 分钟）：把所有题快速读一遍
  ├─ 标出每题的 context / namespace / 集群
  ├─ 标出"可独立完成、分值高"的题，作为优先目标
  └─ 标出有破坏性风险的题（改 apiserver 参数、装 AppArmor），留到后半场

第二遍（按题做题，每题四步）：
  1. 通读题干，划出所有名词：资源名、namespace、label、端口、用户名
  2. 先看环境现状：kubectl get -n <ns> / ssh 节点 cat 配置，别急着改
  3. 逐条完成子任务，每条立即验证（kubectl get、curl、读日志）
  4. 题干最后一句通常是"验证 XX 生效"，照做一遍再翻下一题
```

其他实战要点：

- **先切 context 再做题**。题目会写明"On cluster2"，忘了切 context 的所有操作都会打到错误集群
- **别把破坏性改动放在前 30 分钟**。改坏 kube-apiserver 会导致后续所有 kubectl 题无法做，留出恢复时间
- **改 static Pod manifest 前先备份**：`cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/`，改坏了 30 秒内能回滚
- **善用题目自带的文件**。很多题在节点上放好了 yaml/二进制（如 falco 的 deb 包、sysctl 配置文件），先找到它们再用
- **分数是按子任务算的**。一题做不完，把能拿的子任务先拿满

## 6. 样题三道：把审题策略走一遍

样题为本模块自编，题型与颗粒度对齐 Killer.sh/真题（多子任务、末句可验收），解法只依赖本模块正文。建议每题限时 8 分钟自己先做，再展开解题思路对照。

### 样题 1（微服务漏洞域）

```text
Context: cluster1。namespace frontend 里的 Deployment web-app（镜像 nginx:1.27）：
1. 新建 ServiceAccount frontend-sa，且使用它的 Pod 不自动挂载 API 凭证
2. web-app 改用 frontend-sa 并完成滚动
3. 仅允许 namespace frontend 内部访问 web-app Pod 的 80 端口，
   其余 ingress 一律拒绝（含其他 namespace 与集群外）
```

<details><summary>解题思路</summary>

子任务有依赖，顺序 SA → Deployment → NetworkPolicy。

1. `kubectl create sa frontend-sa -n frontend`，再 `kubectl patch sa frontend-sa -n frontend -p '{"automountServiceAccountToken": false}'`
2. `kubectl set serviceaccount deployment/web-app frontend-sa -n frontend && kubectl rollout status deployment/web-app -n frontend`
3. NetworkPolicy 两条合一：default-deny（`podSelector: {}`、`policyTypes: [Ingress]`）＋ allow-same-ns-80（`from: podSelector: {}`、port 80）
4. 验证：别的 namespace 里 `nc -zv -w3 web-app.frontend.svc.cluster.local 80` 应超时，同 namespace 应通
5. 易错点：本题"仅同 namespace"用 from 里的 podSelector 即可；把 namespaceSelector 与 podSelector 并列成两个条目会变成"或"，范围放大
</details>

### 样题 2（供应链域）

```text
Context: cluster1。评估镜像 nginx:1.19 与 nginx:1.27：
1. 用节点上已安装的 trivy 分别扫描，只统计 CRITICAL
2. 将存在 CRITICAL 漏洞的镜像名写入 ConfigMap blocked-images（namespace default）
3. 将无 CRITICAL 漏洞的镜像以 digest 固定方式部署为 Deployment clean-web
   （namespace default，1 副本，容器名 web）
```

<details><summary>解题思路</summary>

1. `trivy image --severity CRITICAL nginx:1.19` 与 `... nginx:1.27`；老版本必然带 CRITICAL，新 tag 基本干净
2. `kubectl create configmap blocked-images --from-literal=image=nginx:1.19`
3. 取 digest（`docker buildx imagetools inspect nginx:1.27` 或 trivy 输出中的 digest），Deployment 写 `image: nginx@sha256:<完整哈希>`
4. 验证：`kubectl get deployment clean-web -o jsonpath='{.spec.template.spec.containers[0].image}'` 为 digest 形式且 Pod Running
5. 易错点：digest 必须完整复制（sha256: 加 64 位十六进制），抄断一位就是 ImagePullBackOff；tag 与 digest 之间是 `@` 不是 `:`
</details>

### 样题 3（监控与审计域）

```text
Context: cluster1。为 apiserver 配置审计：
1. Secret 的读写以 Metadata 级别记录
2. 已知健康的 GET /healthz*、/version* 不记录，其余请求以 Minimal 记录
3. policy 放 /etc/kubernetes/audit-policy.yaml，日志落 /var/log/kubernetes/audit.log，
   单文件 100MB、最多保留 5 个
4. 生效后确认能看到自己 create secret 的记录
```

<details><summary>解题思路</summary>

1. 写 policy：规则一 resources `["secrets"]`、全部读写 verbs、level Metadata；规则二 nonResourceURLs `["/healthz*","/version*"]`、level None；规则三兜底 `- level: Minimal`（无 resources/verbs 限定的 catch-all 放最后）
2. 备份后编辑 /etc/kubernetes/manifests/kube-apiserver.yaml：追加 `--audit-policy-file=/etc/kubernetes/audit-policy.yaml`、`--audit-log-path=/var/log/kubernetes/audit.log`、`--audit-log-maxsize=100`、`--audit-log-maxbackup=5`，并给 static Pod 挂载 hostPath（文件与日志目录）
3. 等 apiserver 重建（`crictl ps` 观察），`kubectl create secret generic probe --from-literal=k=v` 后 `grep '"resource":"secrets"' /var/log/kubernetes/audit.log | tail -1`，其 level 应为 Metadata
4. 易错点：日志目录不存在时 apiserver 起不来（先 mkdir）；忘了挂载 policy 文件会直接启动失败——这正是要先备份 manifest 的原因
</details>

## 7. 与 CKA 备考的衔接

如果你刚过 CKA（参见 `05-cka/00-exam-overview.md`），CKS 新增的能力面主要是四块：

1. 读安全基准并落地（kube-bench/CIS → 改参数）
2. 节点层加固（AppArmor/seccomp/sysctl/最小镜像）
3. 准入与策略（PSA、admission webhook、镜像策略）
4. 检测与响应（audit、Falco、逃逸排查）

建议顺序：先做 01/02（改的是"基础设施"），再做 03/04（改的是"策略"），最后 05/06（观测与数据安全）。每篇的"实战演练"都设计在单 master kubeadm 集群（Ubuntu 22.04/24.04 + Calico）或带 Docker 的 Ubuntu VM 上可直接执行。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 考试被监考员终止 | 打开了允许清单外的网页/窗口 | 只用考试内置浏览器标签，文档在指定域内查 |
| 改完 apiserver 参数后全集群不可用 | static Pod manifest 改错（缩进/非法 flag） | 改前备份；apiserver 起不来时回滚备份文件即可，kubelet 会自动重建 |
| 题目做对了却不得分 | 操作落在错误的 context/namespace | 每题开头 `kubectl config current-context` 确认；namespace 全程显式 `-n` |
| 时间不够 | 在一道低分题上死磕 | 第一遍通读时就排好优先级；2 小时到点前确保易题全部完成 |
| 本地练得好，考试环境抓瞎 | 平时习惯了 minikube/云托管，不熟悉 kubeadm 文件布局 | 备考一律用 kubeadm 集群练习：/etc/kubernetes/manifests、/var/lib/kubelet/config.yaml、kubeadm pki 目录 |

## 自测

1. 为什么 CKS 的备考策略必须包含"SSH 到节点改文件"的练习，而 CKA 相对不需要？

<details><summary>答案</summary>

CKA 大部分任务在 kubectl 层完成；CKS 的考点天然落在节点层：kube-apiserver 是 static Pod（要改 /etc/kubernetes/manifests），kubelet 配置在 /var/lib/kubelet/config.yaml，AppArmor profile 加载在节点上，Falco/kube-bench 安装在节点上。不熟悉节点文件布局，等于一半考点够不着。
</details>

2. 允许查阅 kubernetes.io 文档，为什么仍要求把 audit policy 等配置练到能默写？

<details><summary>答案</summary>

时间成本。2 小时内完成 15~20 道多子任务实操题，平均每题只有 6~8 分钟；从文档里翻字段、对缩进会耗掉做题时间。文档应只用于冷门字段核对，核心模板必须形成肌肉记忆。
</details>

3. 题干写着 "On cluster2, in namespace sec-ns, create a pod that..."，你漏看了 cluster2，在默认 context 完成了全部操作。会得多少分？

<details><summary>答案</summary>

通常 0 分。判分脚本在指定集群/namespace 下检查终态，资源建错了位置就检不到。个别按"资源配置正确性"给部分分的题也可能因 namespace 错误失分。所以第一步永远是切 context、第二步永远显式指定 namespace。
</details>

4. 一道题要求"确保 kubelet 10255 端口不再暴露"，你打算怎么验证而不是猜？

<details><summary>答案</summary>

SSH 到目标节点执行 `ss -tlnp | grep 10255`（或 `curl -s localhost:10255/pods`），确认端口未监听；再对照 /var/lib/kubelet/config.yaml 里 `readOnlyPort: 0`。"验证终态"是 CKS 给分的关键动作。
</details>

5. 考试前一周，你的复习清单应该围绕什么组织：知识点清单还是操作清单？

<details><summary>答案</summary>

操作清单。CKS 全是实操题，有效的复习单位是"5 分钟能做完的一组命令＋验证"：写 PSA label、改 apiserver flag 并重启、生成加密 key 并挂载、装 Falco 并触发规则等。把每篇文件的"实战演练"压缩成不看书写出来的程度即可。
</details>

## 延伸阅读

- CKS 官方页面（报名、大纲、允许资料说明）：<https://training.linuxfoundation.org/certification/certified-kubernetes-security-specialist-cks/>
- CNCF 官方 Curriculum 仓库：<https://github.com/cncf/curriculum>
- Kubernetes 安全文档总入口：<https://kubernetes.io/docs/concepts/security/>
- 官方模拟器 Killer.sh（报名后激活）：<https://killer.sh/cks>
