# 04 · ArgoCD 与 GitOps：拉模式交付

> 模块：06-cicd-iac-gitops ｜ 建议时长：5 小时 ｜ 关联认证：CKS-镜像与供应链（辅助理解）/ —（无直接考点，云原生交付事实标准）

## 学习目标

- 能解释 GitOps 四原则（声明式、版本化、自动拉取、持续调和），以及拉模式相对 push 模式的安全收益
- 能解释 ArgoCD 架构（api-server / repo-server / application-controller / redis）各自职责
- 能操作在 kubeadm 集群上安装 ArgoCD、创建 Application CR 并验证自动同步与自愈
- 能设计多环境仓库布局（kustomize overlay）与 App of Apps，并解释 CI 与 CD 的职责边界
- 能排查 OutOfSync 不收敛、镜像字段不生效、私有仓库拉不到三类高频故障

## 1. GitOps 原理：Git 是唯一真相

OpenGitOps 社区定义的四原则：

1. **声明式**：系统期望状态以声明式描述（K8s YAML/kustomize/Helm）
2. **版本化且不可变**：期望状态存在 Git，有完整历史与审计
3. **自动拉取**：部署侧 agent 自己从 Git 拉取，而不是被 CI 推着走
4. **持续调和**：实际状态与期望状态持续比对，偏了就拉回（reconcile）

```
push 模式（传统 CI/CD）：                拉模式（GitOps）：
  开发 ──▶ CI ──▶ kubectl apply ──▶ 集群    开发 ──▶ CI（构建镜像+改 manifest）──▶ Git 仓库
              │                              Git 仓库 ◀──持续拉取── ArgoCD(in 集群)
              └ CI 持有集群凭据(高危)                    └──▶ 自动 apply 到本集群
                                            凭据不出集群，审计=git log
```

拉模式的三个决定性优势：

- **凭据倒置**：CI 不再持有生产 kubeconfig；ArgoCD 在集群内，不需要对外暴露入口
- **单一真相**："集群里跑什么"的回答只有一个——去 Git 看。回滚 = git revert
- **自愈**：有人手滑 kubectl 改了副本数、删了 Deployment，调和循环会自动纠正

前提纪律：**只能通过改 Git 来改集群**。如果还保留"紧急时 kubectl 手改"的后门，单一真相就名存实亡——应急改动之后必须回写 Git。

## 2. ArgoCD 架构与安装

### 2.1 架构

```
                 ┌─────────────────── argocd namespace ───────────────────┐
   浏览器/argocd CLI │                                                        │
      ──HTTPS──▶ │ argocd-server(API/UI) ── argocd-repo-server              │
                 │        │                     （渲染工具：git 拉取 +        │
                 │        │                      kustomize/helm 渲染出最终   │
                 │        ▼                      YAML，带缓存）             │
                 │ argocd-application-controller ◀────────────────────────┘
                 │   （调和循环：Git 渲染结果 vs 集群实际状态，
                 │     差异 → OutOfSync；sync → server-side apply/create）
                 │        │
                 └────────┼───────────────────────────────────────────────┘
                          ▼
                 目标集群（本集群或外部集群） + argocd-dex(SSO,可选) + argocd-redis(缓存)
```

| 组件 | 职责 | 排查入口 |
|---|---|---|
| argocd-server | API/UI/CLI 入口、用户与 RBAC | `kubectl -n argocd logs deploy/argocd-server` |
| argocd-repo-server | 连 Git、渲染 kustomize/helm | `deploy/argocd-repo-server`（私有仓库凭据也在这配） |
| argocd-application-controller | 调和循环、健康评估、状态机 | `deploy/argocd-application-controller` |
| argocd-redis | 渲染结果缓存 | 一般不用动 |
| applicationset-controller | 批量生成 Application | 用到 ApplicationSet 再关注 |

### 2.2 安装（kubeadm 集群，Calico CNI）

```bash
# [master] 安装稳定版（组件镜像需从 quay.io/docker.io 拉取，国内网络需可达）
kubectl create namespace argocd
kubectl apply -n argocd -f \
  https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# [master] 等全部 Running（约 1~3 分钟，取决于拉镜像速度）
kubectl get pods -n argocd -w
# NAME                                               READY   STATUS    RESTARTS
# argocd-application-controller-0                   1/1     Running
# argocd-dex-server-xxx                              1/1     Running
# argocd-redis-xxx                                   1/1     Running
# argocd-repo-server-xxx                             1/1     Running
# argocd-server-xxx                                  1/1     Running
```

```bash
# [master] 装 CLI（从 GitHub releases 取最新版资产）
curl -fsSL -o /usr/local/bin/argocd \
  https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x /usr/local/bin/argocd && argocd version --short

# [master] 取初始 admin 密码（3.x 若 secret 改名，用第一条命令先看实际名称）
kubectl -n argocd get secret | grep argocd-initial
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo

# [master] 暴露 UI：端口转发（--address 让 Windows 浏览器能访问 master IP）
kubectl port-forward svc/argocd-server -n argocd 8443:443 --address=0.0.0.0 &
# [本地Windows] 浏览器打开 https://<master-IP>:8443（自签证书告警选继续）
# 用户名 admin，密码为上面取到的字符串
```

```bash
# [master] CLI 登录并改掉初始密码（新密码示例，自行替换）
argocd login 127.0.0.1:8443 --grpc-web --insecure \
  --username admin --password '<初始密码>'
argocd account update-password --current-password '<初始密码>' --new-password 'Argo!Passw0rd'
```

## 3. Application CR：GitOps 的最小单元

```yaml
# [文件 application-demo.yaml] 一个"看着 Git 目录、同步进集群"的声明
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-guestbook
  namespace: argocd            # Application 必须建在 argocd 能 watch 的 namespace
spec:
  project: default             # ArgoCD 项目：权限与资源边界（AppProject CR）
  source:                      # 从哪读：仓库 + 路径 + 版本
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook            # 该目录下的 YAML/kustomization 会被渲染
  destination:                 # 同步到哪：集群 + namespace
    server: https://kubernetes.default.svc   # 本集群
    namespace: demo
  syncPolicy:
    automated:                 # 自动同步三开关
      prune: true              # Git 里删了资源，集群里也删
      selfHeal: true           # 有人手改集群资源，拉回 Git 版本
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true   # 自动建目标 namespace
    retry:                     # 失败自动重试
      limit: 3
      backoff: {duration: 30s, factor: 2}
```

状态机（UI/CLI 上看到的四个字段）：

```
Synced ──(Git 变化/集群手改)──▶ OutOfSync ──(自动或手动 sync)──▶ Syncing ──▶ Synced
   │                                          │
   └── 健康度独立评估：Healthy / Progressing / Degraded / Suspended
       例：Synced+Degraded = YAML 都 apply 了，但 Pod 起不来（CrashLoopBackOff）
```

```bash
# [master] 部署上面的 Application
kubectl apply -f application-demo.yaml
argocd app list
# NAME            CLUSTER                         NAMESPACE  STATUS   HEALTH  SYNCPOLICY
# demo-guestbook  https://kubernetes.default.svc  demo       Synced   Healthy Auto

kubectl -n demo get deploy,svc
# NAME                          READY   UP-TO-DATE
# deployment.apps/guestbook-ui  1/1     1
```

## 实战演练：自动同步与自愈实测

这是 GitOps 最值得亲手做一次的实验——理解"Git 是唯一真相"不是口号：

```bash
# [master] 实验 1：手改副本数，观察 selfHeal 拉回
kubectl -n demo scale deploy guestbook-ui --replicas=4
kubectl -n demo get deploy guestbook-ui    # 此刻 4
sleep 60 && kubectl -n demo get deploy guestbook-ui
# ArgoCD 调和后回到 1（与 Git 一致）；UI 上该事件被记录为 "Update ... from Git"

# [master] 实验 2：直接删资源，观察自动重建
kubectl -n demo delete deploy guestbook-ui
sleep 60 && kubectl -n demo get deploy guestbook-ui   # 重新出现

# [master] 实验 3：prune——把 Git 里的资源删掉，集群里也消失（用自己仓库才好演示）
# 在 Git 中删除某个 manifest 并提交，ArgoCD 会在下个调和周期删除集群内对应资源
```

两个必须懂的边界：

- `selfHeal` 默认只纠 **spec 级**改动（副本数、镜像、env）。`kubectl scale` 这种命令式改动能被纠正，前提是 spec 与 Git 渲染结果不同
- `prune: true` 是双刃剑：Git 误删文件 = 生产资源被删。生产环境常见配置是 `automated: {selfHeal: true, prune: false}`，删除动作走人工确认

## 4. 多环境与 App of Apps

### 4.1 仓库布局（kustomize overlay）

```
deploy-repo/
├── apps/                      # 各环境的 Application 清单（见 4.2）
│   ├── test-app.yaml
│   └── prod-app.yaml
└── manifests/
    ├── base/                  # 公共部分
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   └── kustomization.yaml
    └── overlays/
        ├── test/
        │   └── kustomization.yaml     # 改 replicas=1、镜像 tag=test 版
        └── prod/
            └── kustomization.yaml     # 改 replicas=3、镜像 tag=prod 版
```

```yaml
# [文件 manifests/overlays/prod/kustomization.yaml]
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base
replicas:
  - name: demo-api
    count: 3
images:
  - name: registry.example.com/demo/api   # base 里的镜像名
    newTag: v1.2.0                         # CI 改这里触发发布
```

test 与 prod 是**同一个 base 的两个 overlay**：差异显式、可 review；版本升级 = 改一个 `newTag` 提 PR。kustomization 的字段语义（patches 写法、生成器、与 Helm 混用）见本模块第 07 章。

### 4.2 App of Apps：用一个 Application 管一串 Application

环境多了以后，"每个环境手工建一次 Application"本身就是漂移源。把 Application 清单也放进 Git，再用一个"根 Application"指向 `apps/` 目录：

```
root-app (Application)
   └── source: <repo>/apps 目录
        ├── test-app.yaml ──┐
        └── prod-app.yaml ──┼──▶ 这些 YAML 本身也是 Application，
                             │     ArgoCD 会把它们"同步"进集群
                             ▼
              test-app → overlays/test    prod-app → overlays/prod
```

```yaml
# [文件 apps/root-app.yaml] 根应用：只负责把 apps/ 下的 Application 部署出来
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://gitlab.example.com/platform/deploy-repo.git
    targetRevision: main
    path: apps
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

收益：新增环境 = 提交一个 YAML；ArgoCD 自身的配置也在 Git 里（自举）。规模化再进一步用 **ApplicationSet**（git generator 按 目录/集群矩阵 批量生成 Application），思想一致。

## 5. CI 与 CD 的边界

一句话分工：**CI 产出镜像并"告诉" Git，CD 由 Git 驱动集群**。

```
开发 push 代码
   │
   ▼
CI(GitLab CI)：build → test → docker build/push(registry) → 改 deploy-repo 的
   │                                              image tag，git commit+push
   │ 不持有 kubeconfig！                            │
   ▼                                              ▼
registry（存镜像）                        deploy-repo（存期望状态）
                                                 │ 拉取
                                                 ▼
                                       ArgoCD → kubeadm 集群
```

| 关注点 | CI（GitLab CI/Jenkins/GHA） | CD（ArgoCD） |
|---|---|---|
| 输入 | 源代码 | Git 中的声明式 manifest |
| 输出 | 镜像、测试报告、**对 manifest 仓库的一次提交** | 集群实际状态 |
| 持有的凭据 | registry 凭据、manifest 仓库的写 token | 集群内自带，无需外部入口 |
| 回滚 | 重新跑旧 commit（慢） | `git revert` 后自动收敛（快） |
| 判断标准 | "这个 commit 能不能产出可用镜像" | "集群是不是和 Git 长得一模一样" |

CI 改 manifest 的方式：流水线里用 `sed`/`yq` 改 overlay 的 `newTag` 后 commit，或用 ArgoCD Image Updater 让 ArgoCD 自己把新 tag 回写 Git——两者都保持"Git 单一真相"，区别只是谁来提交。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 一直 OutOfSync 但内容看着一样 | 字段默认值差异：namespace、最后的 `.spec.clusterIP`、labels、CRD status 等 | `argocd app diff` 看真实差异；用 `ignoreDifferences` 忽略不可控字段 |
| 改了 Git 半天不生效 | 默认每 3 分钟才 refresh 一次 repo；或 webhook 未配 | UI 点 Refresh/Hard Refresh；给 GitLab/GitHub 配 webhook 调 ArgoCD 的 `/api/webhook` |
| 手动 kubectl 改动一直不回滚 | `automated.selfHeal` 未开，只有 sync 没有自愈 | 开 selfHeal；确认改的是 spec 字段 |
| sync 报 immutable field / 冲突 | 修改了集群不可变字段（Service clusterIP、Deployment selector 等） | 删除重建资源，或改用可变字段；selector 类错误必须改清单设计 |
| repo 连接失败 | 私有仓库没配凭据 / deploy key 权限不足 | UI Settings → Repositories 添加凭据（HTTPS token 或 SSH key），连通性立即可测 |
| Application 建在了业务 namespace | ArgoCD 只 watch 配置的 namespace（默认 argocd） | 移回 argocd namespace，或调整 `--application-namespaces` 启动参数 |

## 自测

<details><summary>1. push 模式的 CI 需要持有集群 admin kubeconfig，为什么这在拉模式里消失了？凭据去了哪里？</summary>

push 模式：CI 引擎必须能连 API Server 并 apply，所以集群入口凭据存在 CI 系统里，CI 被攻破=集群被攻破。拉模式：ArgoCD 部署在目标集群内部，通过 ServiceAccount 直接调本集群 API Server，不需要任何外部可达入口；它唯一的外部依赖是读 Git 仓库的凭据（只读 deploy key 即可）。攻击面从"能改集群一切"缩小到"能读一个 Git 仓库"，且所有变更都有 git 审计。
</details>

<details><summary>2. Synced 和 Healthy 是两个独立状态，请构造一个"Synced 但 Degraded"的例子并说明排查方向。</summary>

例：manifest 里镜像 tag 写错（镜像不存在）。ArgoCD 把 YAML 原样 apply 成功（Synced），但 Pod ImagePullBackOff → Deployment Degraded。排查方向在"运行时"而不是"同步"：看 Pod events、镜像名拼写、registry 凭据 imagePullSecrets。反过来 Progressing 长时间不转 Healthy 则要看 readinessProbe 与滚动策略。GitOps 保证"部署了声明的东西"，不保证"声明的东西能跑"。
</details>

<details><summary>3. prune 和 selfHeal 分别纠正哪类偏差？为什么生产上常开 selfHeal 而关 prune？</summary>

prune 纠正"Git 里没有了"（资源应删除）；selfHeal 纠正"Git 里变了/集群被手改"（资源应更新回 Git 版本）。误删 Git 文件（如一次错误 rebase、目录移动）在 prune 开启时会被忠实执行成生产删除事故；而 selfHeal 只是把参数改回去，风险小得多。所以生产常见组合：selfHeal=true 自动恢复配置漂移，prune=false 让删除类操作必须人工确认。
</details>

<details><summary>4. 为什么 Application 清单本身也该进 Git（App of Apps）？不用它会缺什么？</summary>

不用 App of Apps 时，"ArgoCD 里有哪些应用"这件事只存在数据库里，新环境要人手工点 UI——这本身是漂移源，且无法 review/回滚。把 Application YAML 放进 Git 并用一个根应用管理后：新增/修改环境走 PR，历史可审计，灾备重建 ArgoCD 只需 apply 一个根应用即可自举。缺的代价是多一层间接性，调试时要知道问题出在哪一层（根应用没同步 vs 子应用 OutOfSync）。
</details>

<details><summary>5. 如果集群与 Git 断连（网络隔离），ArgoCD 的行为边界是什么？这对应急意味着什么？</summary>

ArgoCD 拉不到 Git 时调和循环失去"期望状态"来源：已部署资源继续运行（集群不依赖 Git 存活——期望状态的最后渲染结果缓存在本地，且 Kubernetes 本身自治），但无法进行新的同步/自愈更新，UI 报连接错误。应急含义：Git/网络故障不会"击落"在线业务；但如果此时需要紧急变更，只能 kubectl 手改（打破单一真相），恢复后必须把改动回写 Git，否则会被 selfHeal 回滚掉。
</details>

## 延伸阅读

- OpenGitOps 原则：<https://opengitops.dev/>
- ArgoCD 官方文档（架构/入门）：<https://argo-cd.readthedocs.io/en/stable/>
- Application CR 字段参考：<https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/>
- ArgoCD Image Updater（CI 推镜像后自动改 Git 里的 tag/digest，补全发布闭环）：<https://argocd-image-updater.readthedocs.io/en/stable/>
- kustomize 官方文档：<https://kubectl.docs.kubernetes.io/>
