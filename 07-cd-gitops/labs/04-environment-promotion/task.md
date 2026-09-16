# Lab 07 · 多环境晋升：Kustomize overlay + ArgoCD 分级同步 + 飞书通知

> 难度：★★★ ｜ 考点：Kustomize 多环境 overlay / ArgoCD 自动与手动同步策略 / 镜像晋升留痕 / Image Updater write-back ｜ 前置：本模块 lab 02（ArgoCD 已装在 argocd 命名空间、git daemon 可用）、第 07 章（kustomize）、第 04 章（Application 与 syncPolicy） ｜ 预计 60~80 分钟

## 资源前置（先读再动手）

- 本 lab 不新增重组件：主要内存开销是前置 lab 02 装好的 ArgoCD 栈（argocd 命名空间，约 1~1.5G）；新增负载只有两个命名空间里的 nginx Pod（dev 1 副本 + staging 2 副本，requests 合计约 150m/192Mi）与一个纯 python echo 服务（内存可忽略）。动手前 `kubectl -n argocd get pods` 与 `free -h` 确认 ArgoCD 存活、没有别的组件在抢内存。
- **收尾要求**：跑完 check.sh 并确认得分后再清理——**先判分再清理**（check.sh 依赖两个 Application、两个命名空间的 Deployment、git log 与通知落盘文件在线）。回收步骤见 solution 末尾：kill echo 服务、删除两个 ArgoCD Application（连带 demo-dev/demo-staging 命名空间资源）、删裸仓库 `/srv/git/promo-app.git`。

## 场景

demo-api 业务目前在 dev 环境靠 kustomize overlay 交付（第 07 章的 base + overlays 形态）。团队决定引入 staging 环境：dev 对应开发联调，谁提交了镜像 tag 就自动部署；staging 对应验收，**镜像 tag 的晋升必须有人明确按下按钮并留下 Git 记录**。发布成功后要往飞书群发一条通知——练习环境没有真实飞书 webhook，用本地 echo 服务落盘代替。

约定（判分脚本按此检查）：

- 工作目录 `~/labs/env-promotion`，裸仓库 `/srv/git/promo-app.git`（git daemon 复用 lab 02 的 9418）；
- base 镜像 `nginx:1.27`，Deployment 名 `demo-api`；`overlays/dev` 与 `overlays/staging` 各自生成 `demo-config`；
- 两个 Application：`demo-app-dev`（automated：prune + selfHeal）与 `demo-app-staging`（无 automated，手动 sync），均在 `argocd` 命名空间；
- 目标命名空间 `demo-dev` / `demo-staging`（用 `CreateNamespace=true` 让 ArgoCD 自建）；
- 终态镜像：两环境都晋升到 `nginx:1.27.4-alpine`；staging 副本数 2、资源请求高于 dev。

## 任务清单

1. 按第 07 章实战的形态建仓库：`base/`（deployment + service + kustomization，引用但不生成 `demo-config`）与 `overlays/dev/`（namespace demo-dev、replicas 1、resources 50m/64Mi、镜像 newTag `1.27-alpine`、configMapGenerator LOG_LEVEL=debug），`kubectl kustomize overlays/dev` 渲染验证。
2. **新建一个环境**：`overlays/staging/kustomization.yaml`——namespace demo-staging、replicas **2**、resources 请求 **100m/128Mi**（高于 dev）、镜像 newTag 先与 dev 相同（`1.27-alpine`）、LOG_LEVEL=info；渲染并核对四类差异都生效。
3. 建裸仓库 `/srv/git/promo-app.git` 并 push（git daemon 若未运行则按 lab 02 的方式启动）。
4. 写 `apps/demo-app-dev.yaml` 与 `apps/demo-app-staging.yaml` 并 `kubectl apply`：dev 开 automated（prune + selfHeal），staging **不配 automated**；注意 staging 首次部署也要手动触发一次 sync，两个 Application 终态 Synced + Healthy。
5. 晋升演练：把 dev overlay 的 newTag 改成 `1.27.4-alpine` 并提交 push，等（或刷新）dev 自动同步、Pod 换镜像；随后把同一个 tag 复制进 staging overlay，提交信息带 `promote` 字样（如 `promote: nginx 1.27.4-alpine dev -> staging`）并 push，确认 staging 变 OutOfSync 后手动 sync；`git log` 里能看到这次晋升记录。
6. 为 `apps/demo-app-dev.yaml` 生成 ArgoCD Image Updater 的完整注解配置（image-list、update-strategy、write-back-method 为 git、write-back-target 指向 overlays/dev 的 kustomization），重新 apply。本项只做**文档级验证**：注解字段正确写入文件与集群，不需要真的安装/运行 image-updater controller。
7. 飞书通知演练：在 `notify/` 下写一个 python echo 服务（监听 18761，把收到的 POST body 原样落盘到 `notify/feishu-webhook.log`），后台启动；用 curl 按飞书自定义机器人 text 消息格式（`{"msg_type":"text","content":{"text":"..."}}`，第 11 章交付平台与 16-cloud/02 余额告警同款模板）POST 一次晋升通知，验证落盘文件含 `msg_type`。

## 验收标准

终态（kubectl 与文件只读可验证）：

- `~/labs/env-promotion/overlays/staging/kustomization.yaml` 存在且含 namespace demo-staging、count 2、128Mi 资源差异；
- Application `demo-app-dev`：Healthy + Synced，`spec.syncPolicy.automated` 存在；Application `demo-app-staging`：Healthy + Synced，`automated` 为空（手动同步）；
- `demo-dev` 与 `demo-staging` 两个命名空间的 `demo-api` Deployment 镜像均为 `nginx:1.27.4-alpine`，staging 副本 2/2 就绪；
- `apps/demo-app-dev.yaml` 含 `argocd-image-updater.argoproj.io/image-list`、`write-back-method: git`、`write-back-target: kustomization:overlays/dev` 三个注解，且集群内 Application 已带 image-list 注解；
- `notify/feishu-webhook.log` 存在且内容含 `msg_type`；
- `git log` 含带 `promote` 字样的晋升提交。

完成后运行判分脚本（与 task.md 同目录）：

```bash
# [VM]
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：staging 的"新建环境"到底要改哪几处？</summary>

对照第 07 章 3.3 节的专用 transformer：`namespace`（demo-staging）、`replicas`（count: 2）、strategic merge 补丁（resources 100m/128Mi）、`images.newTag`（先与 dev 相同）、`configMapGenerator`（LOG_LEVEL=info）。改完先 `kubectl kustomize overlays/staging | grep -E 'namespace:|replicas:|image:|cpu:|memory:'` 逐项核对，再提交——这是第 07 章常见坑"patch 不生效静默失败"的标准防法。`namespace:` 不会创建命名空间，但本 lab 用 `CreateNamespace=true` 的 syncOption 交给 ArgoCD 建。

</details>

<details><summary>提示 2：没有 automated 的 Application 创建后是什么状态？怎么"手动 sync"？</summary>

没有 `syncPolicy.automated` 的 Application 只对比不施加：状态停在 OutOfSync（首次是 Missing）。手动触发有三种方式：UI 上点 Sync 按钮；装了 argocd CLI 用 `argocd app sync demo-app-staging`；或用 kubectl 触发一次 sync 操作：`kubectl -n argocd patch application demo-app-staging --type merge -p '{"operation":{"sync":{"syncOptions":["CreateNamespace=true"]}}}'`。三种等价，任选其一。

</details>

<details><summary>提示 3：晋升时想让 dev 立刻同步，不想等 3 分钟怎么办？</summary>

ArgoCD 默认约 3 分钟轮询一次仓库（第 04 章常见坑）。立刻生效：UI 点 Refresh，或 `argocd app get demo-app-dev --refresh`（CLI 需先 port-forward + login，做法同 lab 02）。

</details>

<details><summary>提示 4：Image Updater 的 write-back-method 为什么选 git 而不是默认的 argocd？</summary>

默认 `argocd` 方法是把新镜像写进 Application 的 Helm parameters 覆写——只对 Helm 型 source 有效。本 lab 的 source 是 kustomize 目录，必须用 `write-back-method: git`：更新器直接提交 Git。配 `write-back-target: kustomization:overlays/dev` 时它改的是该 kustomization.yaml 的 `images` 字段；不指定 target 则默认在 Application path 旁生成 `.argocd-source-<app名>.yaml`。注解键名与语义随版本演进，以官方文档为准。

</details>

<details><summary>提示 5：echo 服务收不到请求怎么排查？</summary>

先 `ss -lntp | grep 18761` 确认在监听；再 `curl -v http://127.0.0.1:18761/` 看连接是否建立（GET 会 501，正常，handler 只实现了 do_POST）；最后看服务是不是以前台方式被 nohup 掉了、以及 `Content-Type` 头是否带上。python3 用 `python3 -V` 确认存在（Ubuntu 出厂自带）。

</details>
