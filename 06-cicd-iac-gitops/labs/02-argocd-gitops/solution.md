# Lab 02 · 解答：ArgoCD GitOps

> 配套 task.md 使用。环境：kubeadm 单 master 集群（master IP 以 `172.30.30.21` 为例，下同，替换成你的实际 IP），CNI 为 Calico，master 可访问外网拉镜像。

## 第 0 步：理解设计

ArgoCD 的核心是"**Git 是事实源、控制器不断纠偏**"，和控制循环是同一套思想：

```
 ┌──────────────┐  pull (每~3min)  ┌──────────────────┐   diff    ┌──────────────┐
 │  git daemon  │ ◄─────────────── │ argocd-repo-server│ ◄──────  │ argocd-app-  │
 │ /srv/git/... │                  └──────────────────┘           │ controller   │
 └──────┬───────┘                                                 └──────┬───────┘
        │ push（人改仓库）                                           apply/prune/selfHeal
        ▼                                                            ▼
   改 replicas 2/3                                          ┌──────────────────┐
                                                            │  k8s: ns/demo    │
   kubectl scale 5（人为漂移）──selfHeal 改回─────────────►  │ deploy/pod/svc   │
                                                            └──────────────────┘
```

三个方向的偏差对应三个开关：auto-sync（Git 新增/更新 → apply）、`prune`（Git 删除 → 删集群资源）、`selfHeal`（集群被手改 → 改回 Git 值）。

## 第 1 步：安装 ArgoCD

```bash
# [master]
kubectl create namespace argocd
# --server-side：ArgoCD 3.x 的 applicationsets CRD 太大，客户端 apply 会被
# "metadata.annotations: Too long: may not be more than 262144 bytes" 拒掉
kubectl apply --server-side --force-conflicts -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd get pods -w
# 等 7 个左右的 Pod 全部 Running（redis、repo-server、app-controller、dex、server 及其对应的小工具容器）
kubectl -n argocd rollout status deploy/argocd-server
# 预期：deployment "argocd-server" successfully rolled out
```

取出初始 admin 密码（ArgoCD 1.9+ 存在 secret 里）：

```bash
# [master]
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

## 第 2 步：自建 Git 仓库并启动 git daemon

```bash
# [master]
sudo mkdir -p /srv/git
sudo git init --bare --initial-branch=master /srv/git/demo-app.git
sudo chown -R "$(id -u):$(id -g)" /srv/git     # 当前用户能 push
```

写工作副本（清单放仓库根目录，与 task 约定的 `path: .` 一致；真实项目里常见 `deploy/` 子目录 + `path: deploy`，效果相同）：

```bash
# [master]
mkdir -p ~/labs/gitops-demo && cd ~/labs/gitops-demo
```

`nginx.yaml`：

```yaml
# 文件: ~/labs/gitops-demo/nginx.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: demo
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          ports:
            - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
  namespace: demo
spec:
  selector:
    app: nginx
  ports:
    - port: 80
      targetPort: 80
```

commit 并 push 到裸仓库，然后启动 daemon：

```bash
# [master]
cd ~/labs/gitops-demo
git init --initial-branch=master
git add -A && git commit -m "init: nginx deploy/svc replicas=3"
git remote add origin git://172.30.30.21/demo-app.git
git push -u origin master
# 预期：To git://172.30.30.21/demo-app.git  * [new branch] master -> master

# git daemon：base-path 映射 URL，receive-pack 允许匿名 push（仅练习环境！生产禁止）
git daemon --base-path=/srv/git --export-all --enable=receive-pack --detach --reuseaddr
ss -lntp | grep 9418    # 预期看到 git-daemon 在 *:9418 监听
```

为什么用 git daemon：GitOps 的学习必须包含"改仓库 → 集群变"，纯 https 只读仓库做不到 push；git:// 匿名协议零凭据配置，ArgoCD 直接可读。生产环境请换成带认证的 https/ssh，且 push 走 MR 流程。

## 第 3 步：创建 Application

`application.yaml`：

```yaml
# 文件: ~/labs/gitops-demo/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git://172.30.30.21/demo-app.git
    targetRevision: master
    path: .
  destination:
    server: https://kubernetes.default.svc
    namespace: demo
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

字段解释：`destination.server` 用集群内 API 地址（Application 所在集群即 in-cluster）；`path: .` 指向仓库里的清单目录（这里是根目录）；`CreateNamespace=true` 让 ArgoCD 自动创建 `demo`，省掉手工 `kubectl create ns`。

```bash
# [master]
kubectl apply -f ~/labs/gitops-demo/application.yaml
sleep 20
kubectl -n argocd get application.argoproj.io demo-app \
  -o jsonpath="{.status.health.status}{'\n'}{.status.sync.status}{'\n'}"
# 预期输出两行：Healthy / Synced
kubectl -n demo get deploy,svc
# 预期：deployment.apps/nginx   3/3   3   3   ...
#       service/nginx   ClusterIP   10.x.x.x   <none>   80/TCP
```

此刻你没有 `kubectl apply` 过任何业务清单——所有对象都是 ArgoCD 依据 Git 创建的，这就是"pull 模式交付"。

## 第 4 步：改仓库，观察自动同步（replicas 3 → 2 → 3）

```bash
# [master]
cd ~/labs/gitops-demo
sed -i 's/replicas: 3/replicas: 2/' nginx.yaml
git add -A && git commit -m "scale: replicas 3 -> 2" && git push
```

ArgoCD 默认约 3 分钟轮询一次；等不及就刷新：

```bash
# [master]
# 可选：装 argocd CLI 后强制刷新（不装也行，等 3 分钟）
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd /usr/local/bin/argocd && rm argocd
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
argocd login localhost:8080 --username admin --insecure --grpc-web
#   密码粘贴第 1 步取出的初始密码
argocd app get demo-app --refresh
```

验证副本数变成 2：

```bash
# [master]
kubectl -n demo get deploy nginx
# 预期：nginx   2/2   2   2 ...
# 把仓库改回 3 并 push（保证终态）
sed -i 's/replicas: 2/replicas: 3/' nginx.yaml
git add -A && git commit -m "scale: back to 3" && git push
```

## 第 5 步：制造漂移，观察 selfHeal 自愈

```bash
# [master]
kubectl -n demo scale deploy nginx --replicas=5
kubectl -n demo get deploy nginx      # 短暂看到 5/5，这是"漂移中的状态"
# 等 ArgoCD 下一轮 reconcile（最多约 3 分钟，或 argocd app get demo-app --refresh）
kubectl -n demo get deploy nginx      # 预期回到 3/3
kubectl -n argocd logs deploy/argocd-application-controller | grep -i "replicas" | tail
# 日志里能看到 patched deployment ... replicas 的证据
```

原理：`selfHeal: true` 时 app-controller 在每轮对比中发现 live state 与 target state 不一致（即使 Git 没变），会主动把 live 改回 target。若不开 selfHeal，这次 scale 只会让 Application 显示 OutOfSync 而不动手纠正——"显示漂移"和"纠正漂移"是两回事。

顺带验证 prune（选做）：

```bash
# [master]
cd ~/labs/gitops-demo
# 把 Service 段从 nginx.yaml 中删掉后 commit+push，观察 svc/nginx 被自动删除；
# 然后恢复文件再 push，Service 回来（记得保证终态 replicas: 3 + Service 存在，否则判分不过）。
```

## 第 6 步（可选）：Web UI 直观确认

```bash
# [master]
kubectl -n argocd port-forward svc/argocd-server 8443:443
# 浏览器（或 SSH 隧道）访问 https://<master-IP>:8443，用户 admin + 初始密码
```

UI 上点开 demo-app：能看到 Deployment 的 live/target/diff 三栏，漂移发生时 diff 有内容、自愈后清空。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| `apply` 报 `The CustomResourceDefinition "applicationsets.argoproj.io" is invalid: metadata.annotations: Too long` | 客户端 apply 把 last-applied-configuration 注解写进 CRD，超过 256KB 上限（ArgoCD 3.x 的 applicationsets CRD 很大） | 改用 `kubectl apply --server-side --force-conflicts`（见第 1 步）；只影响 applicationsets，`applications` CRD 不受影响 |
| Application 一直 `ComparisonError`/连不上 repo | repoURL 写成 localhost 或 127.0.0.1 | repo-server 在 Pod 网络里访问，必须写 master 节点 IP（如 172.30.30.21）；Calico 下 Pod→节点 IP 默认可达 |
| push 报 `receive-pack: no such service` | git daemon 没开写权限 | 启动时加 `--enable=receive-pack`（见第 2 步完整命令） |
| Sync 报 namespace 不存在 / 资源创建失败 | 目标 ns demo 未建 | syncOptions 加 `CreateNamespace=true` |
| 手改集群后一直 OutOfSync 但不纠正 | 没开 selfHeal | `spec.syncPolicy.automated.selfHeal: true` |
| Git 删了资源但集群里还在 | 没开 prune | `prune: true`（注意生产上删除是危险动作，团队要先约定） |
| 改完仓库等了 1 分钟没反应 | 正常 | 轮询默认约 3 分钟（`timeout.reconciliation`，以官方文档为准）；UI 点 Refresh 或 CLI `--refresh` 立即触发 |

## 判分脚本结果

```text
# [master]
$ ./check.sh
PASS: argocd 命名空间存在
PASS: argocd-server Deployment 处于 Available
PASS: Application demo-app 存在
PASS: Application 健康状态为 Healthy
PASS: Application 同步状态为 Synced
PASS: source.repoURL 指向 demo-app.git
PASS: syncPolicy 开启 selfHeal
PASS: syncPolicy 开启 prune
PASS: destination.namespace 为 demo
PASS: demo/nginx Deployment 期望 replicas 为 3
PASS: demo/nginx Deployment readyReplicas 为 3
PASS: demo 命名空间存在 nginx Service

SCORE: 12/12
```

## 延伸阅读

- ArgoCD 官方文档（Getting Started / Application spec）：https://argo-cd.readthedocs.io/en/stable/
- ArgoCD Application CRD 字段说明：https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/
- OpenGitOps 四原则（声明式/拉取/持续/可回滚）：https://opengitops.dev/
- git daemon 官方文档：https://git-scm.com/docs/git-daemon
