---
title_juejin: '在职两个月过 CKA：一半的分，不在你刷的题里'
title_zhihu: '在职两个月过 CKA：一份诚实的备考清单'
description: 'CKA 纯实操 2 小时、66% 过线、只允许开官方文档。排错与集群架构合计 55% 权重，RBAC、etcd 备份、升级是题库零覆盖缺口。附 8 周在职计划表、考场工程技巧与按域易错清单。'
category_id: "6809637769959178254"
tags: "后端,程序员"
column_id: "7686346277555716146"
---

# 在职两个月过 CKA：一份诚实的备考清单

CKA 没有选择题。120 分钟，一个真实集群，15~20 道操作题，评分脚本只看你最后留下的集群终态——过程命令一概不看。

这句话决定了整份清单的形状：能背的东西极少，能练的东西很多。下面按"考什么、什么形式、每周练什么、考场怎么抢时间、哪里最容易翻车"展开，全部对齐官方大纲权重，最后划一条诚实边界：为什么背题库的人大概率过不了。

先亮全文最重要的判断：**排错+集群架构占 55% 的分**，多数人的复习时间却花在另外 45% 上。

## 一、考什么：权重就是复习预算

CKA 现行大纲五个域（权重以官方 Curriculum 为准【官方】；折算题量是估算，不是官方承诺）：

| 大纲域 | 权重 | 题型风格（按约 17 题场次折算） |
|---|---|---|
| Troubleshooting | 30% | 约 5 题：节点 NotReady、控制面组件排错、Pod 故障、日志分析——给你一个坏掉的现场，修到可用 |
| Cluster Architecture, Installation & Configuration | 25% | 约 4 题：RBAC、kubeadm 安装/升级、etcd 备份恢复——集群生命周期管理 |
| Services & Networking | 20% | 约 3 题：Service、Ingress、NetworkPolicy、CoreDNS |
| Workloads & Scheduling | 15% | 约 3 题：Deployment 滚动更新、ConfigMap/Secret、扩缩与调度 |
| Storage | 10% | 约 2 题：PVC/StorageClass/PV 绑定 |

这张表藏着 CKA 备考最大的信息差：**一半以上的分在"运维侧"**。Troubleshooting 加 Cluster Architecture 合计 55%，而"应用侧"——Deployment、Service、Ingress 这些大家练得最欢的东西——只占 45%。

拿一套题库做过逐题映射：16 道题里 12 道集中在应用侧三个域，权重最高的两个域只有 4 道擦边、且都停在部分覆盖；RBAC、etcd 备份恢复、kubeadm 升级三个考点明晃晃写在大纲里，题库覆盖为零【平台样本，题库 16 题逐题映射】。照题库顺序刷完就去考试，一半的分暴露在盲区里。

把权重和覆盖画到一张图上更刺眼：Storage 两格全是实心，排错六格里三格是空的——复习火力该往哪打，图比直觉诚实。

所以复习预算的第一原则：**跟着权重走，不跟着熟悉感走**。排错一个域等于 Storage 三个域，先补哪块，答案写在权重表上。

## 二、考试形式与环境：硬事实决定打法

先列硬事实（官方口径【官方】）：

- **纯实操**（performance-based）：在远程考试环境里操作真实集群，无选择题
- **2 小时**，开考后倒计时不可暂停；每场 15~20 题浮动，往期考生反馈多数约 17 题【第三方转引，场次反馈】
- **通过线 66%**，题目分值不等，按加权总分计算
- 环境：Linux 桌面 + 终端 + 一个受控浏览器，里面是现成的 kubeadm 集群（常见 2 个 context）
- 允许资源：仅 Kubernetes 官方文档域（docs、blog 及其子域）；文档页里指向的外部站点——代码托管平台、问答社区——一律不能点；自己的笔记、本地文件也不能开
- 监考：PSI 在线监考，证件核验、房间 360 度全景检查、全程摄像头与屏幕监控
- 成绩考后约 24 小时邮件通知（官方口径 36 小时内）；价格与补考政策以官方页面当前版本为准，不依赖二手转述

考试日流程也有几个卡点：比预约时间提前 15 分钟启动监考浏览器，留足身份核验时间；证件要政府签发、带照片、姓名与报名完全一致；房间用摄像头环拍 360 度，桌面清空、房内无人。

中断处理最值得知道的一条：断网断电不会立即判死，重新连接后监考员会恢复会话，但考试机时间仍在流逝——先把网络恢复手段备好。流程细节以报名确认邮件和官方 FAQ 为准，考前一周自己读一遍，不依赖二手转述。

其中最常被低估的是两条，直接改变打法。

**只开官方文档**。备考时就要练"只用官方文档答题"的习惯——比如 RBAC 题，`kubectl create role --help` 加官方 RBAC 文档页足以覆盖全部题型，考场上不需要、也不允许翻论坛。

**评分只看终态**。过程命令不做要求，评分脚本检查集群里的对象与配置。这意味着任何顺序、任何方式（命令行或 YAML）达到要求都算数；也意味着"做完不验证"等于裸奔。

终端环境补几句细节：编辑器只有 vim，shell 是 bash。喜欢分屏的可以试 tmux，环境里通常可用，但别把打法建立在它身上——开场检查时验证一下，不可用就退回单终端加浏览器标签页【从业者判断】。vim 和 bash 的配置代码放在第四节，两分钟换全程十五分钟。

## 三、在职 8 周计划表：从 RBAC 打到故障排查

设定先说清：每周两个晚上、各 3 小时，8 周约 48 小时；其中补齐权重缺口的核心路径约 18 小时（章节加 lab，不含重做），其余给应用域复述、全真模拟和错题回炉。前提是你已经用过 K8s，Pod/Deployment/Service 概念层不再讲。

排期服从两个原则：**P0 缺口先行**（RBAC、etcd 备份、kubeadm 升级，三个零覆盖考点优先），**章节按依赖走**（升级依赖 drain，etcd 恢复依赖静态 Pod，乱序会卡死）。

| 周 | 模块 | 动手 lab | 通过标准 |
|---|---|---|---|
| 1 | 摸底：考试规则 + 大纲缺口自评 | 跑 7 组验收命令建个人缺口表 | 每行能标出"闭眼能做"还是"没练过" |
| 2 | RBAC：Role/ClusterRole/RoleBinding/SA | RBAC 三件套 + can-i 验证 | `auth can-i --as` 正反验证符合预期 |
| 3 | kubeadm 从零安装：init/join/CNI | 从空虚拟机装出单节点集群 | `get nodes` 全 Ready、CoreDNS Running |
| 4 | 版本升级 + 节点维护：plan/apply/drain | minor 版本原地升一遍 | 版本正确、全 Ready、无 SchedulingDisabled |
| 5 | etcd 备份恢复：snapshot save/restore | 恢复到新目录 + 改静态 Pod | 恢复后快照内对象回归、集群可读写 |
| 6 | Secret + 证书：三种创建、TLS 挂 Ingress、check-expiration | TLS secret 全链路 | `curl -kv` 出示的证书 SAN 是自己的域名 |
| 7 | 排错总攻（30% 域）：决策树、组件、CoreDNS、监控链路 | 十大故障逐条跑第一检查命令 | 随机抽 3 条现象，30 秒说出第一条命令 |
| 8 | 全真模拟 ×2 + 终检演练 | 120 分钟限时混合题 | 限时内做完、终检清单走完、错题记回缺口表 |

三个执行细节。lab 卡住先回章节的"常见坑"表对号入座，不要换教程；每个 lab 结束对着任务清单口述一遍解法，只有输入没有复盘，两周后归零；应用侧已覆盖的题不必重做三遍，考前各花 5 分钟复述解法即可，时间全部砸给缺口。

## 四、考场工程技巧：省下的都是分

### 4.1 开场 8 分钟：配置一次，全程受益

```bash
# [考试终端] kubectl 自动补全 + k 缩写 + 两个变量
cat >> ~/.bashrc <<'EOF'
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
export do="--dry-run=client -o yaml"
export now="--force --grace-period 0"
EOF
source ~/.bashrc
```

`$do` 生成 YAML 骨架而不真正创建，改两笔再 apply，比手写快且不易错：

```bash
# [考试终端] $do 三连：Pod / Deployment / Job 骨架
k run nginx --image=nginx:1.29 $do > pod.yaml
k create deployment web --image=nginx:1.29 --replicas=3 $do > dep.yaml
k create job pi --image=busybox:1.36 $do -- sh -c 'echo 3.14 > /tmp/x' > job.yaml

# [考试终端] $now：立即删除，跳过 30s 优雅期（清理做错的实验对象）
k delete pod bad-pod $now
```

为什么用环境变量不用 alias：bash 只在命令位置（行首词）展开 alias，参数位置不替换；变量在任意位置用 `$do` 引用都会展开。写成 alias 会把 `do` 当成一个普通词传给 kubectl，直接报错。

vim 两分钟同款：

```bash
# [考试终端] 写入 ~/.vimrc
cat >> ~/.vimrc <<'EOF'
set number
set expandtab
set tabstop=2
set shiftwidth=2
syntax on
EOF
```

粘贴大段 YAML 前先 `:set paste`，粘贴完 `:set nopaste`，否则自动缩进会把 YAML 搅成一锅。

### 4.2 每题第一步：切 context

考试环境常见两个集群（比如 `k8s` 和 `hk8s`），题目第一行通常写着 "Use context: k8s"。忘切的后果是在错误集群里创建对象——验收脚本在另一个集群找不到资源，直接 0 分，你做的"错题"还会污染那个集群。

```bash
# [考试终端] 每题第一步，三个动作
kubectl config get-contexts        # 看可用 context，星号是当前
kubectl config use-context k8s     # 切到题目指定的
kubectl config current-context     # 动手前再确认一次
```

嫌切换麻烦可以每条命令显式指定，效果等价：`kubectl --context hk8s -n app-space get pod`。

### 4.3 explain 优先，浏览器留给长文档

```bash
# [考试终端] 忘字段名时，比翻浏览器快
k explain ingress.spec
k explain pvc.spec --recursive | less
```

explain 直接反映当前集群版本的 API 字段，零跳转零加载；浏览器留给它给不出的东西——完整示例 YAML、NetworkPolicy 这类要读长文语义的题。

### 4.4 时间分配：8 / 70 / 30 / 12

```text
|--8'--|-------------------70'-------------------|------30'------|--12'--|
 开场    第一遍：只做 5 分钟内拿得下的题           第二遍：         终检
 检查    卡住立即标记跳过                         攻坚难题
```

- 0~8 分钟：走完开场检查（context、集群健康、bashrc/vimrc、namespace 列表）
- 8~78 分钟：顺序过题，任何一题预计超 5 分钟就标记跳过
- 78~108 分钟：回头做标记的难题，分值高、把握大的先做
- 108~120 分钟：逐题复查终态，尤其题目指定的 namespace 和资源名

按 17 题与 66% 的账：稳拿 12 题以上基本越线，**允许放弃 4~5 道难题**。与其在一道 3% 的题上耗 20 分钟，不如把 5 道验证做到位。

终检 12 分钟固定做四件事：逐题对照四要素复查终态；删掉自己创建的临时调试 Pod（题目没要求、又可能干扰评分对象的）；检查有没有 drain/cordon 未复位的节点；还有时间，就做被跳过题里最便宜的"部分给分"动作——先把对象骨架建出来。

再加一条铁律：**一题一闭环**。读题 30 秒提取四要素（context / namespace / 资源名 / 验收条件）→ 切 context → 动手 → 按题目给的验收方式自测 → 通过才翻下一题。考试集群多题共用，一道题遗留的破坏（节点被 drain、CNI 被删）会让后面几题在错误的地基上做题，越晚发现波及面越大。

## 五、易错清单：按域分，考前过一遍

全局三条先立住：没切 context（对象建错集群）、粘贴 YAML 缩进乱（忘 `:set paste`）、做完不验证（评分只看终态）。剩下的按域：

| 域 | 易错点 | 修正 |
|---|---|---|
| Cluster Architecture | RBAC 只做正向验证 | `can-i` 加否定动作反向验证，期望 no 才算边界正确 |
| Cluster Architecture | etcd 恢复只改 manifest 一处 | `--data-dir` 与 hostPath 两处一起改，只改一处表现为"恢复没生效" |
| Cluster Architecture | 升级题 drain 后忘 `uncordon`、kubelet 忘升 | 终检 `get nodes` 全 Ready 且无 SchedulingDisabled |
| Troubleshooting | 前面题遗留 NotReady，拖挂后面依赖节点数的题 | 每题即验证；破坏性操作前想清楚影响面 |
| Troubleshooting | `kubectl top` 报错只盯着 Pod 看 | 四步定位：Pod → logs → APIService → raw metrics 链路 |
| Services & Networking | NetworkPolicy 选择器逻辑写反 | 题眼是"同组 AND、异组 OR"：同一 from 内是 AND，多个 from 之间是 OR |
| Services & Networking | Service 的 port 与 targetPort 混淆 | port 是 Service 自己的端口，targetPort 才落到容器 |
| Workloads | 只练了 ConfigMap，Secret 整块空白 | 大纲原文两者并列明列；三种创建方式都要练 |
| Workloads | HPA 参数新旧语法混淆 | `--cpu` 是新版语法，旧版叫 `--cpu-percent`，以考场版本的 --help 为准 |
| Storage | StorageClass 设默认用错方法 | 打 `is-default-class` 注解；PVC 判定先看 accessModes 与 storageClassName |

## 六、模拟环境与练习策略

练习环境的第一要求是**近似考场**：一台终端、一个独立集群、一个只开官方文档的浏览器。ssh 到独立节点做题的习惯值得保留——CKA 考场就是"给你一台终端加独立集群"，要练的肌肉记忆是"读题提取四要素 → 做题 → 验证"这条流水线，不是某个具体界面。

三条策略：

1. **限时训练进日历**。第 8 周至少两套 120 分钟混合题限时做。不限时的练习会高估实战水平——时间压力下的 context 切换、跳题决策，才是真正被考的东西。模拟稳定在 75% 以上再约考试：66% 是及格线，不是安全线【从业者判断】。
2. **全覆盖题降级，缺口题加权**。应用侧已达"可迁移"水平的题，考前 5 分钟复述解法即可；时间全部砸给 RBAC、etcd、升级、排错四块。
3. **考前 48 小时收口**。只重跑验收命令组和错题行，不引入新内容。新知识救不了临场，熟练度才能。

那 7 组验收命令——RBAC 三步、etcd snapshot 全参数、upgrade plan 读懂、drain 三参数、证书对号、TLS secret 全链路、top 双可用——值得每周跑一遍，哪组卡壳回对应周补。它们就是这份计划表的自检表。

## 七、诚实边界：背题库过不了，动手才是纲

把丑话说在最后。

CKA 纯实操、评分看终态、每场题量在 15~20 间浮动、题目分值不等——四个事实合起来，意味着"背"没有一个可以落地的载体：你背下的命令序列，换一个坏法、换一个 context 名、换一个 namespace，就是一道新题。

题库映射也印证了这一点：16 题里 12 题挤在 45% 权重的应用域，55% 的运维侧只有 4 题擦边【平台样本，题库 16 题逐题映射】。刷两遍题库仍然心里没底，不是题不够多，是把"做过"当成了"会了"。

考试环境与题型还在持续调整，二手题库与真题的重合度不可依赖【从业者判断】。可依赖的只有两样：大纲权重，决定复习预算；你的手，决定集群终态。

两个月的在职备考，本质是把 18 小时的缺口路径摊进 8 周，再把剩下的时间全部换成限时动手。这条路线慢吗？不慢——权重、缺口、限时，三本账都摊在上面了。

给你一个今晚就能做的挑战：不开任何资料，60 秒完成 RBAC 三步——

```bash
# [练习集群] 60 秒 RBAC 三步 + 正反验证
kubectl create ns selftest
kubectl -n selftest create sa t1
kubectl -n selftest create role r1 --verb=list --resource=pods
kubectl -n selftest create rolebinding b1 --role=r1 --serviceaccount=selftest:t1
kubectl auth can-i list pods -n selftest --as=system:serviceaccount:selftest:t1
# yes
kubectl auth can-i delete pods -n selftest --as=system:serviceaccount:selftest:t1
# no —— 反向验证也是考点
```

做出来了，第 2 周对你就是复习；卡住了，恭喜，你刚找到自己缺口表的第一行。

完整的章节、lab 靶场和验收命令组，我持续整理在开源仓库里，GitHub 搜 sre-learning-hub 可以找到，05-cka 模块就是这套 8 周计划的全部素材。考完回来评论区晒个成绩单，让我看看这份清单诚实得对不对。
