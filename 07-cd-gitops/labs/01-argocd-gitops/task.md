# Lab 02 · ArgoCD GitOps：自动同步与漂移自愈

> 难度：★★☆ ｜ 考点：GitOps 声明式交付 / ArgoCD Application 与 syncPolicy ｜ 前置：05-cka 的 lab 01、11（deployment 与 namespace 基本操作） ｜ 预计 40~60 分钟

## 场景

你的 kubeadm 练习集群（单 master，CNI 为 Calico）上，demo 业务的 YAML 目前靠人手 `kubectl apply`，谁改了什么没有记录。团队决定改为 GitOps：**Git 仓库是唯一事实源**，ArgoCD 持续把仓库里的清单同步进集群；有人绕过 Git 直接改集群（漂移），ArgoCD 要能自动纠正回来。

因为练习环境可能没有外网 GitHub 写权限，本 lab 用 master 节点上**自建的裸 git 仓库 + git daemon（git:// 9418 端口）**当"远端仓库"，ArgoCD 从它 pull。这最接近真实用法（push 代码 → 集群自动变化），又完全离线可复现。

## 任务清单

约定（判分脚本按此检查）：ArgoCD 装在 `argocd` 命名空间；Application 名为 `demo-app`；Git 仓库 `demo-app.git`；目标命名空间 `demo`；工作负载是 `nginx` Deployment，**终态 replicas 为 3**。

1. 在 `argocd` 命名空间安装 ArgoCD（官方 stable manifest），确认 `argocd-server` 等 Deployment 全部 Available；取出 `argocd-initial-admin-secret` 里的初始 admin 密码。
2. 在 master 上创建裸仓库 `/srv/git/demo-app.git`，写一个工作副本（deployment + service 的 K8s 清单，nginx，replicas: 3），push 到裸仓库；启动 `git daemon` 监听 9418 且允许 push（`--enable=receive-pack`）。
3. 创建 Application `demo-app`：source 指向 `git://<master-IP>/demo-app.git`、path `.`；destination 为集群内 `demo` 命名空间；`syncPolicy.automated` 同时打开 `prune: true` 与 `selfHeal: true`，并用 `CreateNamespace=true` 的 syncOption 让 ArgoCD 自建命名空间。
4. 等待并验证：不手动 apply 任何东西，`demo` 命名空间里出现 Deployment 和 Service；Application 状态变为 `Healthy` + `Synced`。
5. 修改仓库（replicas 3 → 2），commit + push，在约 3 分钟内观察 ArgoCD 自动同步、副本数变成 2；随后把仓库改回 3 并 push（保证终态）。
6. 人为制造漂移：`kubectl -n demo scale deploy nginx --replicas=5`，观察 ArgoCD 的 selfHeal 把它改回 3；在 UI 或 `argocd app diff` 里确认漂移被纠正的证据。
7. （可选）`kubectl port-forward` 访问 ArgoCD Web UI，用初始密码登录，直观看到 sync/health 状态。

## 验收标准

终态要求（kubectl 只读可验证）：

- `argocd` 命名空间的 `argocd-server` Deployment Available；
- `argocd` 命名空间存在名为 `demo-app` 的 Application，`health.status` 为 `Healthy`、`sync.status` 为 `Synced`；
- 该 Application 的 `syncPolicy.automated.selfHeal` 与 `prune` 均为 `true`，destination namespace 为 `demo`；
- `demo` 命名空间的 `nginx` Deployment replicas 为 3 且 readyReplicas 为 3，并有同名 Service；
- 漂移实验后（scale 到 5）能自动回到 3。

完成后运行判分脚本（与 task.md 同目录）：

```bash
# [master]
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：git daemon 怎么让 git:// 可读也可写？</summary>

只读不需要额外参数，**可写**必须加 `--enable=receive-pack`；`--export-all` 让没有 `git-daemon-export-ok` 标记的目录也能被读；`--base-path=/srv/git` 把 URL 映射到目录（URL `git://IP/demo-app.git` 即 `/srv/git/demo-app.git`）。完整命令：`git daemon --base-path=/srv/git --export-all --enable=receive-pack --detach --reuseaddr`。防火墙要放行 9418/tcp。
</details>

<details><summary>提示 2：Application 里 repoURL 怎么写，ArgoCD 侧还要注册仓库吗？</summary>

`git://` 是匿名只读协议，ArgoCD 可以直接访问，不需要 `argocd repo add` 凭据（那一步只在私有 https/ssh 仓库时需要）。注意写**master 节点的 IP**（如 `172.30.30.21`）而不是 localhost——真正去 clone 的是 argocd-repo-server 的 Pod，它跑在集群网络里。Calico 下 Pod 访问节点 IP 的 9418 端口是通的。
</details>

<details><summary>提示 3：目标命名空间 demo 还不存在，会不会卡在 Synced/OutOfSync？</summary>

会报缺 namespace 或创建失败。两种解法：提前 `kubectl create ns demo`，或者在 Application 的 `syncOptions` 里加 `CreateNamespace=true` 让 ArgoCD 自己建（本 lab 要求用后者，这也是生产常用做法）。
</details>

<details><summary>提示 4：selfHeal 和 prune 分别管什么？</summary>

`automated.sync`（默认开启的 auto-sync）只管"Git 里有而集群里没有/版本不对"的资源；`selfHeal: true` 才会把**集群侧被人手改掉的字段**（比如 kubectl scale 改的 replicas）改回 Git 声明的值；`prune: true` 负责"Git 里删掉了、集群里还在"的资源删除。三个开关各管一个方向的偏差，GitOps 的"唯一事实源"要靠 selfHeal+prune 才完整。
</details>

<details><summary>提示 5：改了仓库怎么立刻生效，不想等 3 分钟？</summary>

ArgoCD 默认每 3 分钟轮询一次 repo（timeout.reconciliation，以官方文档为准）。等不及可以强制刷新：UI 上点 Refresh，或 CLI `argocd app get demo-app --refresh`，或者干脆 `kubectl -n argocd rollout restart deploy argocd-repo-server` 之外的正规途径——前者最简单。
</details>
