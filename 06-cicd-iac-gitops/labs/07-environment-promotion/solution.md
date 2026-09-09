# Lab 07 · 解答：多环境晋升

> 配套 task.md 使用。环境：candidate VM（即练习集群 master，kubectl 与 docker 可用；镜像经已配代理拉取），master IP 以 `172.30.30.21` 为例，替换成你的实际 IP。前置：lab 02 已装好 ArgoCD（argocd 命名空间）并演示过 git daemon。

## 第 0 步：理解设计

本 lab 把第 04 章的多环境布局落到一个可操作的晋升流程上：

```
  CI/开发：改 overlays/dev 的 newTag ──commit+push──▶ /srv/git/promo-app.git (git://9418)
                                                        │
                              ┌─────────────────────────┴─────────────────────────┐
                              ▼                                                   ▼
                  Application demo-app-dev                              Application demo-app-staging
                  automated: prune+selfHeal                             无 automated（人工闸门）
                  path: overlays/dev                                    path: overlays/staging
                              ▼                                                   ▼
                    ns demo-dev（自动同步，~3min 轮询）                 ns demo-staging（OutOfSync → 手动 sync）
                                                        │
                              晋升 = 把 tag 复制进 staging overlay 并提交（git log 留痕）
                              通知 = curl POST 飞书 text 消息 → 本地 echo 服务落盘
```

关键认知：**"晋升"不是 kubectl set image，而是一次 Git 提交 + 一次手动 sync**。dev 与 staging 是同一个 base 的两个 overlay（第 07 章第 2 节），差异显式可 review；谁在什么时候把什么版本放进了 staging，`git log` 一目了然——这就是第 04 章"审计 = git log"的落地。

## 第 1 步：建 base + overlays/dev

```bash
# [VM]
mkdir -p ~/labs/env-promotion/{base,overlays/dev,overlays/staging,apps,notify} && cd ~/labs/env-promotion
```

base 与第 07 章实战同形态（只引用 `demo-config`，配置由各 overlay 生成）：

```yaml
# 文件: ~/labs/env-promotion/base/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: demo-api
  template:
    metadata:
      labels:
        app: demo-api
    spec:
      containers:
      - name: api
        image: nginx:1.27
        ports:
        - containerPort: 80
        envFrom:
        - configMapRef:
            name: demo-config
```

```yaml
# 文件: ~/labs/env-promotion/base/service.yaml
apiVersion: v1
kind: Service
metadata:
  name: demo-api
spec:
  selector:
    app: demo-api
  ports:
  - port: 80
    targetPort: 80
```

```yaml
# 文件: ~/labs/env-promotion/base/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
```

dev overlay（对应第 07 章 3.3 节的 transformer + strategic merge + 生成器三件套）：

```yaml
# 文件: ~/labs/env-promotion/overlays/dev/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: demo-dev
resources:
  - ../../base
patches:
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: demo-api
      spec:
        template:
          spec:
            containers:
            - name: api
              resources:
                requests:
                  cpu: 50m
                  memory: 64Mi
replicas:
  - name: demo-api
    count: 1
images:
  - name: nginx
    newTag: "1.27-alpine"
configMapGenerator:
  - name: demo-config
    literals:
      - LOG_LEVEL=debug
```

```bash
# [VM] 渲染验证（先看产物再提交，第 07 章常见坑的标准防法）
kubectl kustomize overlays/dev | grep -E 'namespace: demo-dev|replicas:|image: nginx|cpu:|memory:|name: demo-config-'
# 预期：namespace demo-dev、replicas 1、image nginx:1.27-alpine、50m/64Mi、demo-config-<hash>
```

## 第 2 步：新建 overlays/staging（本 lab 的核心动作）

"创建一个新环境"在 kustomize 里就是**新增一个目录**——写一份与 dev 同构但差异化的 kustomization.yaml：

```yaml
# 文件: ~/labs/env-promotion/overlays/staging/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: demo-staging
resources:
  - ../../base
patches:
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: demo-api
      spec:
        template:
          spec:
            containers:
            - name: api
              resources:
                requests:
                  cpu: 100m
                  memory: 128Mi
replicas:
  - name: demo-api
    count: 2
images:
  - name: nginx
    newTag: "1.27-alpine"
configMapGenerator:
  - name: demo-config
    literals:
      - LOG_LEVEL=info
```

与 dev 的四处差异：namespace、副本数 1→2、资源请求翻倍、LOG_LEVEL。镜像 tag 初始相同（晋升机制还没触发）。

```bash
# [VM] 渲染核对四类差异全部生效
kubectl kustomize overlays/staging | grep -E 'namespace: demo-staging|replicas: 2|image: nginx|cpu:|memory:|LOG_LEVEL'
# 预期：replicas 2、100m/128Mi、image nginx:1.27-alpine、LOG_LEVEL=info
```

## 第 3 步：裸仓库与 git daemon

```bash
# [VM] 若 lab 02 的 daemon 还在跑则只建新仓库；不在则一并启动
pgrep -f git-daemon >/dev/null || \
  git daemon --base-path=/srv/git --export-all --enable=receive-pack --detach --reuseaddr
sudo git init --bare --initial-branch=master /srv/git/promo-app.git
sudo chown -R "$(id -u):$(id -g)" /srv/git

cd ~/labs/env-promotion
git init --initial-branch=master
git add -A && git commit -m "init: demo-api base + overlays/dev + overlays/staging"
git remote add origin git://172.30.30.21/promo-app.git
git push -u origin master
# 预期：To git://172.30.30.21/promo-app.git  * [new branch] master -> master
```

repoURL 必须写 master 的 IP 而非 localhost——真正 clone 的是 argocd-repo-server 的 Pod（lab 02 提示 2 讲过原因）。

## 第 4 步：两个 Application，两种同步策略

```yaml
# 文件: ~/labs/env-promotion/apps/demo-app-dev.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git://172.30.30.21/promo-app.git
    targetRevision: master
    path: overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: demo-dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
    retry:
      limit: 3
      backoff: {duration: 30s, factor: 2}
```

```yaml
# 文件: ~/labs/env-promotion/apps/demo-app-staging.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: demo-app-staging
  namespace: argocd
spec:
  project: default
  source:
    repoURL: git://172.30.30.21/promo-app.git
    targetRevision: master
    path: overlays/staging
  destination:
    server: https://kubernetes.default.svc
    namespace: demo-staging
  syncPolicy:            # 故意不写 automated：晋升要过人工闸门
    syncOptions:
      - CreateNamespace=true
```

dev 的策略沿第 04 章的语义：`automated` 自动跟随 Git，`prune` 让 Git 删除传导到集群，`selfHeal` 纠正手改漂移；staging 全部拿掉，任何变化都停在 OutOfSync 等人确认。`CreateNamespace=true` 代替手工建 namespace（第 07 章"namespace transformer 不建 ns"的坑由此绕开）。

```bash
# [VM] 应用并观察
kubectl apply -f apps/demo-app-dev.yaml -f apps/demo-app-staging.yaml
sleep 30
kubectl -n argocd get application.argoproj.io \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
# 预期：demo-app-dev     Synced    Healthy
#       demo-app-staging OutOfSync Missing   ← 手动策略的首态，符合预期
```

staging 需要人为按一次闸门。三种方式等价：UI 点 Sync、argocd CLI、kubectl patch。这里用 kubectl（不依赖 CLI 安装）：

```bash
# [VM] 手动触发 staging 的首次 sync
kubectl -n argocd patch application demo-app-staging --type merge \
  -p '{"operation":{"sync":{"syncOptions":["CreateNamespace=true"]}}}'
sleep 30
kubectl -n demo-staging get deploy,svc
# 预期：demo-api  2/2  Running，svc/demo-api 已建
kubectl -n argocd get application.argoproj.io demo-app-staging \
  -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
# 预期：Synced / Healthy
```

## 第 5 步：晋升演练（tag 上行 + Git 留痕）

先让 dev 跟上新版本。为不等 3 分钟轮询，装 CLI 强制刷新（做法同 lab 02 第 4 步）：

```bash
# [VM] argocd CLI 就位（已装可跳过）并登录
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd /usr/local/bin/argocd && rm argocd
kubectl -n argocd port-forward svc/argocd-server 8080:443 &
INIT_PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
argocd login localhost:8080 --username admin --insecure --grpc-web --password "$INIT_PW"
```

```bash
# [VM] 1) dev：改 tag 提交 → 自动同步
cd ~/labs/env-promotion
sed -i 's/newTag: "1.27-alpine"/newTag: "1.27.4-alpine"/' overlays/dev/kustomization.yaml
git add -A && git commit -m "release: nginx 1.27.4-alpine to dev" && git push
argocd app get demo-app-dev --refresh >/dev/null; sleep 20
kubectl -n demo-dev get deploy demo-api \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# 预期：nginx:1.27.4-alpine（自动同步完成，没有任何手动 apply）
```

```bash
# [VM] 2) staging：复制同一个 tag 提交（晋升动作）→ 手动 sync
sed -i 's/newTag: "1.27-alpine"/newTag: "1.27.4-alpine"/' overlays/staging/kustomization.yaml
git add -A && git commit -m "promote: nginx 1.27.4-alpine dev -> staging" && git push
argocd app get demo-app-staging --refresh >/dev/null
kubectl -n argocd get application.argoproj.io demo-app-staging -o jsonpath='{.status.sync.status}{"\n"}'
# 预期：OutOfSync —— 手动策略不会自己动
argocd app sync demo-app-staging
sleep 30
kubectl -n demo-staging get deploy demo-api
# 预期：2/2  Running，镜像 nginx:1.27.4-alpine
git log --oneline
# 预期能看到：
#   xxxx promote: nginx 1.27.4-alpine dev -> staging
#   xxxx release: nginx 1.27.4-alpine to dev
#   xxxx init: demo-api base + overlays/dev + overlays/staging
```

为什么这就是"晋升"：staging 拿到的版本**只能来自把 dev 已验证的 tag 复制进 staging overlay 的那次提交**——版本一致性与审计记录同时成立。若 staging 也开 automated，任何人改 dev 就等于直接上了 staging，闸门形同虚设。

## 第 6 步：ArgoCD Image Updater 配置生成（文档级验证）

第 04 章第 5 节提过：CI 改 manifest 的另一种方式是让 ArgoCD Image Updater 自己把新 tag 回写 Git，Git 单一真相不破坏。给 dev 应用生成完整注解配置：

```yaml
# 文件: ~/labs/env-promotion/apps/demo-app-dev.yaml（metadata 段替换为下面内容，spec 不变）
metadata:
  name: demo-app-dev
  namespace: argocd
  annotations:
    argocd-image-updater.argoproj.io/image-list: demo-app=nginx
    argocd-image-updater.argoproj.io/demo-app.update-strategy: semver
    argocd-image-updater.argoproj.io/demo-app.allow-tags: 'regexp:^1\.\d+\.\d+-alpine$'
    argocd-image-updater.argoproj.io/write-back-method: git
    argocd-image-updater.argoproj.io/write-back-target: kustomization:overlays/dev
```

字段含义（以官方文档为准，注解键随版本演进）：

| 注解 | 作用 |
| --- | --- |
| `image-list: <alias>=<镜像>` | 管哪些镜像；alias 是后续按镜像配置的引用名 |
| `<alias>.update-strategy: semver` | 按语义化版本挑最新（还有 latest/name/hash 等策略） |
| `<alias>.allow-tags` | 只考虑匹配 `1.x.y-alpine` 的 tag，过滤掉无关 tag |
| `write-back-method: git` | 回写方式。默认 `argocd` 只写 Application 的 Helm parameters 覆写，对 kustomize source 无效，必须换 git（更新器直接提交仓库） |
| `write-back-target: kustomization:<path>` | 回写目标为该目录 kustomization.yaml 的 images 字段；不指定则默认生成 `.argocd-source-<app名>.yaml` |

```bash
# [VM] 应用注解（controller 未安装，注解只是数据，无副作用）
kubectl apply -f apps/demo-app-dev.yaml
kubectl -n argocd get application.argoproj.io demo-app-dev \
  -o jsonpath='{.metadata.annotations.argocd-image-updater\.argoproj\.io/write-back-method}{"\n"}'
# 预期：git
```

真跑 controller 的话：manifest 在 `https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/manifests/install.yaml`（装进 argocd 命名空间），且 git 回写需要给它配能 push 的 Git 凭据（生产走 deploy key + 分支保护）。本 lab 到文档级验证为止——判分脚本检查的是注解字段，不要求 controller 在跑。

## 第 7 步：飞书通知（echo 服务落盘）

```python
# 文件: ~/labs/env-promotion/notify/echo_server.py
#!/usr/bin/env python3
"""飞书 webhook echo 服务：把收到的 POST body 原样落盘，替代真实群机器人做演练。"""
import datetime
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG_PATH = sys.argv[1] if len(sys.argv) > 1 else "feishu-webhook.log"


class HookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write("[%s] POST %s\n%s\n" % (
                datetime.datetime.now().isoformat(timespec="seconds"), self.path, body))
        payload = b'{"StatusCode":0,"StatusMessage":"success"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):  # 关闭默认访问日志，避免刷屏
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 18761), HookHandler).serve_forever()
```

```bash
# [VM] 启动并发一条飞书 text 消息（与 14-cloud/02 余额告警、第 11 章交付平台同款模板）
cd ~/labs/env-promotion
nohup python3 notify/echo_server.py notify/feishu-webhook.log >/dev/null 2>&1 &
ss -lntp | grep 18761    # 预期：python3 在 *:18761 监听

curl -s -X POST -H 'Content-Type: application/json' \
  -d '{"msg_type":"text","content":{"text":"[晋升通知] demo-api nginx:1.27.4-alpine 已从 dev 晋升到 staging"}}' \
  http://127.0.0.1:18761/open-apis/bot/v2/hook/demo-token
echo    # 预期：{"StatusCode":0,"StatusMessage":"success"}

cat notify/feishu-webhook.log
# 预期：一行时间戳与路径，下一行是完整 JSON，含 "msg_type":"text"
```

真实环境里把 URL 换成飞书群机器人的 `https://open.feishu.cn/open-apis/bot/v2/hook/<token>`，消息体格式不变——CI 在晋升流水线末尾 `curl` 一次即可。

## 第 8 步：清理（判分之后）

check.sh 依赖两个 Application、命名空间里的 Deployment、git log 与通知落盘文件在线——**务必先判分再清理**。

```bash
# [VM] check.sh 通过后按需回收
# 1) 停掉 echo 服务（18761 端口常驻进程）
pkill -f echo_server.py
ss -lntp | grep 18761 || echo "echo 服务已停"

# 2) 删除两个 Application（ArgoCD 级联清理各自命名空间里的资源；ns 若残留再补删）
kubectl delete -f apps/demo-app-dev.yaml -f apps/demo-app-staging.yaml
kubectl delete ns demo-dev demo-staging --ignore-not-found

# 3) 删裸仓库（git daemon 还要给后续 lab 用则只删仓库不停 daemon）
sudo rm -rf /srv/git/promo-app.git

# 4) 本地工作目录 ~/labs/env-promotion 含判分证据（kustomization、apps、notify 落盘），建议保留；
#    确要删：rm -rf ~/labs/env-promotion
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| staging Application 一直 OutOfSync 不部署 | 手动策略本来就是"只对比不施加" | 手动 sync（UI/CLI/kubectl patch 三选一，见第 4 步）；这是设计而非故障 |
| kubectl patch 触发 sync 后状态没变 | operation 是一次性触发，需等 controller 处理 | `sleep 20` 后再看；`kubectl -n argocd get app demo-app-staging -w` 观察 |
| 渲染结果里 staging 差异没生效 | strategic merge 补丁缺 metadata.name/kind 拼错，静默不命中（第 07 章常见坑） | 永远先 `kubectl kustomize overlays/staging` 核对产物 |
| repo 连接失败 / ComparisonError | repoURL 写成 localhost | 写 master 节点 IP；确认 git daemon 在跑且 export-all |
| image-updater 注解 apply 后什么都没发生 | controller 没装或没配 Git 写凭据 | 本 lab 只做文档级验证；真跑按第 6 步末尾的安装说明 |
| Image Updater 语义与本文不符 | 注解与 write-back 行为随版本演进 | 以官方文档为准（argocd-image-updater.readthedocs.io） |
| curl 发送后落盘文件没内容 | 服务没监听 / 发的是 GET / 落盘路径写错 | `ss -lntp | grep 18761`；确认 `-X POST` 与 `Content-Type`；echo 服务以 notify/ 为相对路径启动时注意 cwd |
| dev 改了 tag 迟迟不更新 | 默认约 3 分钟轮询 | `argocd app get demo-app-dev --refresh` 立即触发（第 04 章常见坑） |

## 判分脚本结果

```text
# [VM]
$ ./check.sh
PASS: argocd-server Deployment 处于 Available
PASS: overlays/staging/kustomization.yaml 存在
PASS: staging overlay 声明 namespace demo-staging
PASS: staging overlay 副本数为 2
PASS: staging overlay 资源请求含 128Mi
PASS: Application demo-app-dev 存在且 Healthy
PASS: Application demo-app-dev 为 Synced
PASS: demo-app-dev 配置了 automated 自动同步
PASS: Application demo-app-staging 存在且 Healthy
PASS: Application demo-app-staging 为 Synced
PASS: demo-app-staging 未配置 automated（手动同步）
PASS: demo-dev 环境 demo-api 镜像为 nginx:1.27.4-alpine
PASS: demo-staging 环境 demo-api 镜像为 nginx:1.27.4-alpine
PASS: demo-staging 副本数为 2 且就绪 2
PASS: apps/demo-app-dev.yaml 含 image-list 注解（demo-app=nginx）
PASS: apps/demo-app-dev.yaml 含 write-back-method: git
PASS: apps/demo-app-dev.yaml 含 write-back-target kustomization:overlays/dev
PASS: 集群内 Application 已带 image-list 注解
PASS: 通知落盘文件 notify/feishu-webhook.log 存在
PASS: 落盘内容含 msg_type
PASS: 落盘内容为 text 类型消息
PASS: git log 含 promote 提交记录

SCORE: 22/22
```

## 延伸阅读

- ArgoCD Image Updater 官方文档（注解与 write-back）：<https://argocd-image-updater.readthedocs.io/en/stable/>
- ArgoCD 同步策略（automated/prune/selfHeal）：<https://argo-cd.readthedocs.io/en/stable/user-guide/sync-settings/>
- Kustomization 字段参考（overlays 差异字段）：<https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/>
- 飞书开放平台·自定义机器人：<https://open.feishu.cn/document/client-docs/bot-v3-add-custom-bot>
