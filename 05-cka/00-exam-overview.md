# 00 · CKA 考试概览与考场策略

> 模块：05-cka ｜ 建议时长：1 小时 ｜ 关联认证：CKA（本模块总入口）

## 学习目标

- 能说出 CKA 的考试形式、通过线、允许资源等硬性事实，并知道去哪里核对最新政策
- 能制定一套 120 分钟的时间分配与做题顺序策略（先易后难、每题即验证）
- 能解释为什么"每题第一步先 `kubectl config use-context`"是最大的失分保险
- 能在开考前 10 分钟内完成终端环境配置（vim、completion、常用变量）
- 能列出考试日流程中容易导致中断或延误的环节及应对

## 1. 考试形式：硬性事实

| 项目 | 内容 |
| --- | --- |
| 考试名称 | Certified Kubernetes Administrator (CKA)，CNCF / Linux Foundation 主办 |
| 形式 | 纯实操（performance-based），在远程考试环境里操作真实集群，无选择题 |
| 时长 | 2 小时（120 分钟），开考后倒计时不可暂停 |
| 题量 | 每个场次在 15~20 题之间浮动，多数场次反馈约 17 题；本模块按 17 题规划节奏 |
| 通过线 | 66%（题目分值不等，按加权总分计算） |
| 考试环境 | Linux 桌面 + 终端 + 一个受控浏览器；环境里是现成的 kubeadm 集群（常见为 2 个 context） |
| 允许资源 | 仅 kubernetes.io 域内文档（docs、blog 及其子域）；不能开其他任何网站、笔记、本地文件 |
| 监考 | PSI 在线监考：证件核验、考场（房间）全景检查、全程摄像头与屏幕监控 |
| 结果 | 考后约 24 小时（官方口径 36 小时内）邮件通知，MyLF 账号查成绩单 |
| 报名与补考 | 价格与 retake 政策以 training.linuxfoundation.org 当前页面为准（以官方为准，不依赖记忆） |

两个常被低估的事实：

1. **只开 kubernetes.io**。kubernetes.io 文档页里指向的外部站点（github、博客园、Stack Overflow）一律不能点。备考时要练"只用官方文档答题"的习惯——比如 RBAC 的 `kubectl create role --help` 与 kubernetes.io RBAC 页面足以覆盖所有 RBAC 题。
2. **评分只看终态**。过程命令不做要求，评分脚本检查集群里的对象与配置。这意味着：可以用任何顺序、任何方式（命令行 / YAML 文件）达到要求，也意味着"做完不验证"等于裸奔。

## 2. 考试域与权重

| 大纲域 | 权重 | 典型题（按权重折算，约值） | 对应本模块章节 |
| --- | --- | --- | --- |
| Troubleshooting | 30% | ~5 题：节点 NotReady、控制面组件排错、Pod 故障、日志分析 | 05、06 章 + labs 15~20 |
| Cluster Architecture, Installation & Configuration | 25% | ~4 题：RBAC、kubeadm 安装/升级、etcd 备份恢复 | 01~04 章 + labs 11~14 |
| Services & Networking | 20% | ~3 题：Service、Ingress、NetworkPolicy、CoreDNS | 04-k8s-fundamentals 05/06/10 + labs 03~05、17 |
| Workloads & Scheduling | 15% | ~3 题：Deployment 滚动更新、ConfigMap/Secret、扩缩与调度 | 04-k8s-fundamentals 03/04/09 + labs 01、02、08 |
| Storage | 10% | ~2 题：PVC/StorageClass/PV 绑定 | 04-k8s-fundamentals 07 + labs 06、07 |

权重折算的题量是估算，不是官方承诺；但结构性结论很稳：**Troubleshooting + Cluster Architecture 合计 55%，一半以上的分在"运维侧"**，而很多考生的复习时间恰恰花在"应用侧"（Deployment/Service/Ingress）。本模块 01 章的缺口分析正是基于这个权重做的。

## 3. 时间分配策略

### 3.1 总体节奏

```
# [图] 120 分钟时间轴
|--8'--|---------------------70'------------------|---25'---|--12'--|
 开场    第一遍：只做 5 分钟内能拿下的题          第二遍：  终检
 检查    (创建类/修改类秒杀题, 卡住立即标记跳过)    攻坚难题
```

| 阶段 | 时间 | 动作 |
| --- | --- | --- |
| 开场检查 | 0~8 min | 完成第 5 节的环境检查清单（context、kubectl、alias、vimrc） |
| 第一遍 | 8~78 min | 顺序过题；任何一题预计超过 5 分钟就标记跳过；每题完成立即验证 |
| 第二遍 | 78~108 min | 回到标记的难题，按分值高、把握大的先做 |
| 终检 | 108~120 min | 按题目列表逐题复查终态（尤其每题指定的 namespace 和资源名） |

按 17 题估算，稳拿 12 题以上（对题分值不均时以"权重域全覆盖"为目标）基本越过 66%；也就是说**允许放弃 4~5 道难题**。与其在一道 3% 的题上耗 20 分钟，不如把 5 道验证做到位。

### 3.2 每题固定动作：先切 context

考试环境常见两个集群（例如 `k8s` 与 `hk8s`），题目第一行通常写着 "Use context: k8s"。**任何题目的第一步永远是：**

```bash
# [考试终端] 查看可用 context 与当前 context（星号所在行）
kubectl config get-contexts

# [考试终端] 切到题目指定的 context
kubectl config use-context k8s
```

忘切 context 的后果是在错误的集群里创建对象——题目验收脚本在另一个集群里找不到资源，直接 0 分，而且你做的"错题"还会污染另一个集群。两个保险习惯：

1. 终端里随时能回答"我现在在哪个集群、哪个 namespace"：`kubectl config current-context`。
2. 嫌切换麻烦可以每条命令显式指定，效果等价：`kubectl --context hk8s -n app-space get pod`。

### 3.3 每题即验证

做完全部 17 题再回头验证是高风险策略：中途某一题的破坏性操作可能影响后面多题。正确节奏是**一题一闭环**：

```
读题(30s 提取四要素: context / namespace / 资源名 / 验收条件)
  → 切 context → 动手 → 按题目给的验收方式自测 → 通过才翻下一题
```

典型验收对照：

| 题目类型 | 验收命令（示例） |
| --- | --- |
| 创建对象 | `kubectl -n <ns> get <kind>` 状态符合要求（Running / Bound / Ready） |
| RBAC | `kubectl auth can-i ... --as=system:serviceaccount:<ns>:<sa>` 返回 yes |
| Service/Ingress | `kubectl -n <ns> get svc/ing` + `curl` 实际访问 |
| 集群维护 | `kubectl get nodes` 全 Ready、版本正确 |
| etcd 恢复 | `kubectl get nodes` 正常返回、`etcdctl endpoint health` 为 true |

## 4. vim 与 alias 提速

考试环境只有终端和浏览器，编辑器就是 vim，命令行就是 bash。开场 8 分钟里值得花 2 分钟做下面的配置，全程能省下 15 分钟以上。

### 4.1 vim 配置

```bash
# [考试终端] 写入 ~/.vimrc（cat 到 EOF，避免手敲）
cat >> ~/.vimrc <<'EOF'
set number
set expandtab
set tabstop=2
set shiftwidth=2
syntax on
EOF
```

考场 vim 高频操作：

| 场景 | 按键 |
| --- | --- |
| 粘贴大段 YAML 前防缩进错乱 | 进入输入模式前 `:set paste`，粘贴完 `:set nopaste` |
| 找字段 | `/关键字` 回车，`n` 下一个 |
| 删整行 / 删到行尾 | `dd` / `d$` |
| 撤销 | `u` |
| 保存退出 / 放弃 | `:wq` / `:q!` |
| 跳到行首插入 / 行尾插入 | `I` / `A` |

### 4.2 kubectl 补全与缩写

```bash
# [考试终端] kubectl 自动补全 + k 缩写
cat >> ~/.bashrc <<'EOF'
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
export do="--dry-run=client -o yaml"
export now="--force --grace-period 0"
EOF
source ~/.bashrc
```

三件套的用法：

```bash
# [考试终端] $do：生成 YAML 而不真正创建，改两笔再 apply，比手写快且不易错
k run nginx --image=nginx:1.29 $do > pod.yaml
k create deployment web --image=nginx:1.29 --replicas=3 $do > dep.yaml
k create job pi --image=busybox:1.36 -- sh -c 'echo 3.14 > /tmp/x; sleep 5' $do > job.yaml

# [考试终端] $now：立即删除，跳过 30s 优雅期（清理做错的实验对象时用）
k delete pod bad-pod $now
```

注意 `$do` / `$now` 是**环境变量**（bash 的 alias 不会在参数位置展开，变量会），所以写法是 `k ... $do`，中间不加引号。

### 4.3 用 explain 替代查文档

```bash
# [考试终端] 忘字段名时，比翻浏览器快
k explain ingress.spec
k explain pvc.spec --recursive | less
k explain deployment.spec.template.spec.containers.resources
```

浏览器留给 explain 给不出的东西（完整示例 YAML、RBAC 章节的长文说明）。

## 5. 考试环境说明与开场检查清单

### 5.1 考试日流程要点

| 环节 | 要点 |
| --- | --- |
| 提前到场 | 比预约时间提前 15 分钟启动 PSI secure browser，留足身份核验时间 |
| 证件 | 政府签发带照片的证件（与报名姓名完全一致，拼音大小写差异一般可接受，以准考证邮件为准） |
| 房间检查 | 用摄像头环拍 360 度：桌面清空（只留证件）、墙壁、桌下；房间内不能有他人 |
| 考中 | 不得离开摄像头范围；去洗手间需要举手等待监考员许可并计时；不得念出声、不得遮挡嘴部 |
| 中断处理 | 断网/断电不会立即判死：重新连接后监考员会恢复会话；考试机时间仍在流逝，先把网络恢复手段备好（手机热点备用电源等政策内允许的方式，以考前邮件为准） |
| 政策核对 | 以上流程细节以报名确认邮件和官方 FAQ 为准，考前一周自己读一遍，不要依赖二手转述 |

### 5.2 开场 8 分钟检查清单

```bash
# [考试终端] 1. 我有哪些集群
kubectl config get-contexts

# [考试终端] 2. 默认 context 的集群活着吗
kubectl get nodes -o wide

# [考试终端] 3. kubectl 版本（顺手确认自动补全可用，按两次 Tab）
kubectl version --client

# [考试终端] 4. 写入 vimrc / bashrc（第 4 节内容）
# [考试终端] 5. 快速记忆每个 context 里 namespace 列表，后面做题少走弯路
kubectl get ns
```

清单走完，环境问题（kubectl 不在 PATH、集群 NotReady）要在第一时间举手报监考——**环境故障不是你的时间成本，但不报备就是**。

### 5.3 终检 12 分钟做什么

1. 逐题对照题面四要素（context/namespace/资源名/验收条件）复查终态。
2. 删掉自己创建的临时调试 Pod（题目没要求又可能干扰评分对象的）。
3. 检查是否留下 `drain`/`cordon` 未恢复的节点：`kubectl get nodes` 必须全部 Ready 且没有 SchedulingDisabled。
4. 有时间就做被跳过题里"部分给分"最便宜的动作（比如先创建出对象骨架）。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 做完一题发现对象建在另一个集群 | 没切 context | 每题第一步 `kubectl config use-context`；做题前 `kubectl config current-context` 再确认一次 |
| 粘贴 YAML 后缩进全乱 | vim 自动缩进干扰 | 粘贴前 `:set paste`；平时写好 `~/.vimrc` 也没问题，paste 临时覆盖 |
| `k` 补全不可用 / `$do` 不展开 | 配置写进了错误的 shell（如 zsh）或忘了 `source` | 考试桌面是 bash；写完后 `source ~/.bashrc` 立即生效 |
| 时间到了还有 3 题没看 | 在一道难题上耗 25 分钟 | 第一遍严格执行"5 分钟拿不下就标记跳过" |
| etcd/升级题把集群弄挂，殃及后续题 | 破坏性操作前无快照意识 | 大操作前先想"评分只看这题的对象"；涉及 etcd 恢复的题按 04 章流程做，一次到位 |
| 考中被判违规 | 摄像头视野里出现第二块屏/手机/他人；大声读题 | 考前清场；默读；需求 clarification 用聊天框问监考员 |

## 自测

1. 为什么说"每题完成立即验证"在 CKA 里比"最后统一检查"更优？从评分方式和故障传播两个角度回答。

<details><summary>答案</summary>

评分只看终态：早验证能在对象刚建好、记忆还新鲜时发现偏差，修正成本最低。故障传播角度：考试集群里多题共用一个集群（尤其 Troubleshooting 题），一道题遗留的破坏（比如节点被 drain、CNI 被删）会让后续题目在错误的地基上做题，越晚发现波及面越大。
</details>

2. 你在第 40 分钟遇到一道 2% 分值的 etcd 恢复题，命令敲了一半发现 snapshot 文件路径不对，集群还能用。按时间分配策略应该怎么做？

<details><summary>答案</summary>

立即停止、标记跳过，进入下一题。按 17 题与 66% 的账，2 分的题可以放弃；40 分钟处第一遍还有约 38 分钟，用它去拿 5 分钟级的创建题更划算。第二遍（78 分钟后）再回来用 04 章的标准流程做：题目会给出 snapshot 路径，重新读题提取四要素，而不是沿用自己记忆里的错误路径。
</details>

3. `$do` 为什么用环境变量而不是 `alias do="--dry-run=client -o yaml"`？

<details><summary>答案</summary>

bash 只在"命令位置"（行首词）展开 alias，参数位置的 `do` 不会被替换；而环境变量在任意位置用 `$do` 引用都会展开。所以 `k run x --image=nginx $do` 能生效，alias 版本会原样传一个词 `do` 给 kubectl 导致报错。
</details>

4. 考试允许打开 kubernetes.io/docs，为什么还建议优先用 `kubectl explain` 而不是浏览器？

<details><summary>答案</summary>

explain 直接反映当前集群版本的 API schema（字段名、类型、是否可选），零跳转、零加载时间；浏览器要经过搜索、翻页、适配版本三个环节。浏览器应保留给 explain 给不出的内容：完整示例清单、RBAC/NetworkPolicy 这类需要看长文档语义的题，以及复制官方示例 YAML。
</details>

5. 终检阶段发现 `kubectl get nodes` 里 worker1 显示 `NotReady,SchedulingDisabled`。可能对应哪类考题的遗留问题？怎么收尾？

<details><summary>答案</summary>

大概率是升级/节点维护题（03、06 章场景）：题目要求 drain 节点做维护，做完后忘了 `kubectl uncordon`；NotReady 部分可能是 kubelet 还没重启成功。收尾：`kubectl uncordon worker1`，再到节点上 `systemctl status kubelet` 确认 active，最后 `kubectl get nodes` 看 Ready。评分时一个 NotReady 节点可能同时挂掉该题与依赖节点数的其他题。
</details>

## 延伸阅读

- CKA 官方页面（课程大纲、政策、报名）：https://training.linuxfoundation.org/certification/certified-kubernetes-administrator-cka/
- CNCF 认证总览：https://www.cncf.io/training/certification/cka/
- kubectl Cheat Sheet（考场上最值得开的一个标签页）：https://kubernetes.io/docs/reference/kubectl/cheatsheet/
- 官方创建集群教程（考场集群就是它搭出来的，熟悉它的默认值）：https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/
