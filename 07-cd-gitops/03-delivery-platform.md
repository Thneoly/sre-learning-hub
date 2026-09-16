# 03 · 端到端交付平台：全链路总装

> 模块：07-cd-gitops ｜ 建议时长：6 小时 ｜ 关联认证：—（无直接考点，本模块毕业章：把 CI、GitOps、供应链闸门与观测缝成一条链）

本章约定：**VM** 指那台装了 Docker 的 Ubuntu（沿用 02 章，以 `192.168.56.10` 指代，docker.io/ghcr 走已配代理）；**集群** 指练习用 kubeadm 集群（master `172.30.30.21`）。Harbor 与 SonarQube 的安装和系统教学见同批补齐的 ../06-ci-cd/05-harbor.md、../06-ci-cd/04-sonarqube.md，本章只做总装。

## 学习目标

- 能对着全链路总图说出每段的职责、工具与对应章节，解释"代码 → 镜像 → Git 晋升 → 集群 → 告警"的数据流
- 能设计多环境模型（overlays + 命名空间 vs 独立集群），给出配置分层与漂移控制的完整防线
- 能权衡 PR-based 晋升与 ArgoCD Image Updater 自动跟新，写出两者的组合策略
- 能编写 PR 触发的 GitLab 流水线（MR 走质量门禁，merge 走构建+签名+扫描+晋升），并落地通知分级与 Grafana 面板聚合，识别四类交付平台反模式

## 1. 全链路总图（本模块毕业图）

前十章各管一段：Git（01）、CI（02/03）、CD（04）、环境代码化（05/06）、manifest 管理（07/08）。本章把它们缝成一条链，每个环节都是前面某章的产物，缺一段链就断（理念版见 00 章第 6 节）：

```
 开发者
   │ ① 提 MR（分支纪律 ── 01 章）
   ▼
 GitLab CI（runner 跑在 VM 上 ── 02 章）
   ├─ ② MR 流水线：lint + test + SonarQube 质量门禁（10 章），红灯挡合并
   │ ③ merge 到 main，主干流水线：docker build → push → ④ Harbor（09 章）
   │      → cosign 签名（09-cks/04 章，签名作为制品存回 Harbor）
   │      → trivy 扫描，CRITICAL/HIGH 即失败（09-cks/04 第 2 节）
   ▼ 全绿
 ⑤ GitOps 晋升：把新 tag 写进某 overlay 的 images.newTag（07 章 3.3 节）
 │      test 由 CI 自动提交，prod 走人工 MR（取舍见 §3）
 ▼
 ⑥ ArgoCD 调和循环（04 章）：拉 Git → kustomize 渲染 → apply 进目标环境（§2）
 │      回滚 = git revert 那次晋升提交
 ▼
 ⑦ 运行时：Prometheus 采集 k8s 与 argocd/jenkins/harbor/sonar 指标（§7），Grafana 统一面板（10-pca/06 章）
 ▼
 ⑧ 通知：CI 失败直报 + Alertmanager 按分级进飞书（§6）；手改集群必须回写 Git，否则被 selfHeal 打回（04 章前提）
 （底层：集群/节点由 05-ansible/06-terraform 供给，ArgoCD 与监控栈自身走 App of Apps 进 Git——04 章 4.2 节）
```

## 2. 多环境模型：环境 = overlays + 命名空间

环境数量增长时，GitOps 的组织只有两个变量：**overlay 目录数** 与 **集群数**。练习集群的模型（新增一个环境 = 提交一个 overlay 目录 + 一个 Application YAML，不碰集群）：

```
 deploy-repo（唯一真相）
 ├─ apps/                      # Application 清单也进 Git（App of Apps，04 章 4.2 节）
 │   ├─ test-app.yaml     → overlays/test    → 集群 ns demo-test    （replicas 1，debug 配置）
 │   ├─ staging-app.yaml  → overlays/staging → 集群 ns demo-staging （贴 prod 的值）
 │   └─ prod-app.yaml     → overlays/prod    → 集群 ns demo-prod    （replicas 3，独立配额与网络策略）
 └─ manifests/{base, overlays/{test,staging,prod}}/   # base=公共部分（07 章实战演练步骤 1 的产物）
```

### 2.1 同集群命名空间 vs 独立集群

| 维度 | overlays + 命名空间（同集群） | 每环境独立集群 |
|---|---|---|
| 隔离强度 | 软隔离：必须补齐 RBAC、ResourceQuota/LimitRange、NetworkPolicy（04-k8s-fundamentals 10/11/12 章） | 硬隔离：控制面、etcd、节点全分开 |
| 爆炸半径 | 共享控制面与节点，test 的资源压力能波及 prod | test 再炸也炸不到 prod |
| 成本 | 一套集群最省（练习环境唯一可行） | N 套控制面与节点，靠 Terraform 供给（06 章） |
| 差异表达 | 一个 overlay 目录，差异显式可 review（07 章选型理由） | 每集群一份 Application，可指向同一 overlay |
| 晋升 | 一个 ArgoCD 实例管多个 Application | ArgoCD 多 destination（`destination.server` 指注册的外部集群） |
| 适用 | test/staging；隔离三件套补齐后的 prod | 合规硬隔离、prod 独立故障域的大团队 |

演进路径：**先同集群把流程跑通**（隔离靠配额+网络策略+RBAC 三件套），prod 独立集群是组织成熟后的升级项，不是起步门槛。

### 2.2 配置分层与漂移控制

| 层 | 载体 | 变更入口 | 漂移防线 |
|---|---|---|---|
| 基础设施（节点/集群） | Terraform（06 章）/ Ansible（05 章） | IaC 仓库 PR | nightly `plan -detailed-exitcode`，exit 2 即告警（06 章第 5 节） |
| 业务 manifest | base + overlays（07 章） | 晋升 MR | selfHeal + 定期 `argocd app diff` 巡检 |
| 应用配置 | configMap/secretGenerator（07 章第 4 节） | overlay 提交 | hash 后缀自动触发滚动，配置漂移无处藏 |
| 镜像版本 | overlays 的 `images.newTag`（07 章 3.3 节） | CI 自动（test）或 MR（prod） | 本章 §3 |
| 密钥 | CI Variables 四件套（02 章 5 节）+ Harbor robot（09 章） | 变量面板，不进 Git | masked/protected + 定期轮换 |

三条纪律（都源自 04 章前提）：只通过改 Git 改集群；巡检发现差异先 `argocd app diff` 看真差异（默认值差异配 `ignoreDifferences`）；应急手改后必须回写 Git。

## 3. 晋升策略：PR-based vs 自动跟新

04 章第 5 节给过结论：CI 改 manifest 有两条路——流水线里 `yq` 改 `newTag` 后提交，或让 ArgoCD Image Updater 自己回写。展开对比：

| 维度 | PR-based 晋升（merge 改 tag 即晋升） | ArgoCD Image Updater |
|---|---|---|
| 谁改 Git | CI 机器人（test）或人（prod MR） | 常驻进程盯着 registry |
| 审计轨迹 | MR 评审 + git log，"谁在何时放的行"完整可查 | 机器提交有 log 无评审，出事只能事后看 |
| 时延 | MR 合并 + 调和，分钟级 | 镜像一 push 即被发现 |
| 可控性 | 保护分支、审批、CODEOWNERS 全套可用 | 靠 allow-list/semver 约束，写错=自动事故直达环境 |
| 失败模式 | 慢一点、多一次点击 | 坏镜像自动铺满环境；与人工提交互相覆盖 |
| 适用 | prod 及一切要审批的环境 | dev/test 高频跟新、预览环境 |

组合实践（业界常见形态）：

- **test**：主干流水线末尾自动改 `overlays/test`（§4 的 promote-test job）——merge 本身已是评审
- **prod**：只认人工 MR，且把 `newTag` 换成 **digest**（`digest: sha256:...`，原理见 09-cks/04 第 3 节），评审时确认"跑的就是扫描过的那个"
- **tag 规范**：CI 产出用 commit SHA（不可变、唯一），语义化版本留给 release；任何环境禁止 `latest`
- 给 dev/test 上 Image Updater：只授权写 `overlays/dev`（prod 绝不进其 write-back 范围），tag 过滤用精确前缀；该项目近年处于维护状态（官方讨论过归档/交接，以仓库公告为准），自动跟新的收益以"工具可长期运维"为前提

## 4. PR 触发流水线：完整 rules 示例

设计目标：**MR 流水线 = lint + test + sonar 门禁（轻、快、挡合并）；主干流水线 = build + push + sign + scan + 晋升 test（重、一次）**。示例仓库 `demo-api` 为 Go 小服务，其他语言换等价 script，结构不变。

```yaml
# [文件 .gitlab-ci.yml] demo-api 仓库根目录
stages: [verify, package, publish, notify]

workflow:                          # 只保留 MR 与主干两类流水线（根治 02 章坑表"重复跑"）
  rules:
    - if: '$CI_PIPELINE_SOURCE == "merge_request_event"'
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'

variables:
  IMAGE_REPO: "192.168.56.10/demo/demo-api"    # Harbor 项目 demo（09 章）
  SONAR_HOST_URL: "http://192.168.56.10:9000"  # SonarQube（10 章）

default:
  tags: [docker]                   # 02 章注册的 runner

lint-and-test:                     # MR：lint + test，不碰镜像
  stage: verify
  image: golang:1.23-alpine
  rules: [{if: '$CI_PIPELINE_SOURCE == "merge_request_event"'}]
  script:
    - test -z "$(gofmt -l .)" || { gofmt -l .; exit 1; }
    - go test ./...

sonar-qualitygate:                 # MR：质量门禁，红灯挡合并（门禁标准见 10 章 4.1/4.3）
  stage: verify
  image: sonarsource/sonar-scanner-cli:5.0     # tag 以官方镜像当前版本为准
  rules: [{if: '$CI_PIPELINE_SOURCE == "merge_request_event"'}]
  script:
    # PR/多分支分析参数（sonar.pullrequest.*）需 Developer Edition 以上；本章/10 章用的
    # Community Build 带 PR 参数会直接报错，故走无 PR 参数的阻塞形态（wait=true 挡住合并）
    - sonar-scanner -Dsonar.projectKey=demo-api -Dsonar.sources=. -Dsonar.qualitygate.wait=true

docker-build:                      # 主干：构建并推送，把 IMAGE/DIGEST 传给下游
  stage: package
  image: docker:27
  rules: [{if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'}]
  script:
    - export IMAGE="${IMAGE_REPO}:${CI_COMMIT_SHORT_SHA}"
    - echo "$HARBOR_PASS" | docker login 192.168.56.10 -u "$HARBOR_USER" --password-stdin
    - docker build -t "$IMAGE" . && docker push "$IMAGE"
    - printf 'IMAGE=%s\nDIGEST=%s\n' "$IMAGE" "${IMAGE_REPO}@$(docker inspect --format '{{index .RepoDigests 0}}' "$IMAGE" | cut -d@ -f2)" >> build.env
  artifacts:
    reports: { dotenv: build.env }    # 下游 needs 后自动注入 IMAGE/DIGEST

cosign-sign:                       # 主干：按 digest 签名（tag 可覆盖、digest 不可），密钥生成见 09-cks/04 第 4 节
  stage: package
  image: docker:27
  needs: [docker-build]            # 与 trivy 并行，互不等待（needs 见 02 章）
  rules: [{if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'}]
  script:
    - >
      docker run --rm -e COSIGN_PASSWORD="$COSIGN_PASSWORD"
      -v "$COSIGN_PRIVATE_KEY":/cosign.key ghcr.io/sigstore/cosign/cosign:v2.4.3 sign --yes
      --allow-insecure-registry --key /cosign.key
      --registry-username "$HARBOR_USER" --registry-password "$HARBOR_PASS" "$DIGEST"
# 练习 Harbor 为 http 故加 --allow-insecure-registry，生产 TLS 后去掉
trivy-scan:                        # 主干：漏洞闸门，有 CRITICAL/HIGH 即失败（ignore-unfixed 降噪，语义见 09-cks/04 第 2 节）
  stage: package
  image: docker:27
  needs: [docker-build]
  rules: [{if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'}]
  script:
    - >
      docker run --rm -e TRIVY_USERNAME="$HARBOR_USER" -e TRIVY_PASSWORD="$HARBOR_PASS"
      aquasec/trivy:latest image --insecure --exit-code 1
      --severity CRITICAL,HIGH --ignore-unfixed "$DIGEST"
promote-test:                      # 主干：两道闸门全绿，自动晋升 test（§3）
  stage: publish
  image: alpine:3.20
  needs: [cosign-sign, trivy-scan]
  rules: [{if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'}]
  script:
    - apk add --no-cache git yq
    - git clone "http://oauth2:${DEPLOY_TOKEN}@192.168.56.10:8080/platform/deploy-repo.git" && cd deploy-repo   # 02 章 GitLab 为 http；生产 GitLab 走 https
    - TAG="${CI_COMMIT_SHORT_SHA}" yq -i '.images[0].newTag = strenv(TAG)' overlays/test/kustomization.yaml
    - git config user.name ci-bot && git config user.email ci-bot@192.168.56.10
    - git commit -am "promote: demo-api:${CI_COMMIT_SHORT_SHA} -> test"
    - git push -o ci.skip origin main   # deploy-repo 自身不触发流水线

notify:                            # CI 状态通知：只报失败（§6）
  stage: notify
  image: alpine:3.20
  rules:
    - {if: '$CI_PIPELINE_SOURCE == "merge_request_event"', when: on_failure}
    - {if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH', when: on_failure}
  script:
    - >
      PAYLOAD=$(printf '{"msg_type":"text","content":{"text":"CI 失败: %s\nref: %s\npipeline: %s\ncommit: %s"}}'
      "$CI_PROJECT_NAME" "$CI_COMMIT_REF_NAME" "$CI_PIPELINE_URL" "$CI_COMMIT_SHORT_SHA")
      && wget -qO- --header='Content-Type: application/json' --post-data="$PAYLOAD" "$FEISHU_WEBHOOK"
```

需要配的 CI Variables（Settings → CI/CD → Variables，勾选项语义见 02 章 4.3 节）：

| Key | 值 | 勾选 | 用途 |
|---|---|---|---|
| `HARBOR_USER` / `HARBOR_PASS` | Harbor robot 账号（09 章） | masked | 推送镜像 |
| `DEPLOY_TOKEN` | deploy-repo 的 project access token（write_repository） | masked, protected | 晋升提交 |
| `COSIGN_PRIVATE_KEY` + `COSIGN_PASSWORD` | cosign 私钥（File 类型）+ 口令 | protected / masked | 签名 |
| `SONAR_TOKEN` / `FEISHU_WEBHOOK` | SonarQube token（10 章）/ 群机器人地址 | masked | 门禁 / 通知 |

三个设计要点：MR 流水线刻意不做 docker build（反馈要快，重活留给 merge 后一次）；`sonar.qualitygate.wait=true` 是门禁而非报告；prod 晋升没有 job——那就是一次人工 MR（§3）。

## 5. 供应链三道门的放置位置

| 门 | 检查什么 | CI 内形态 | 部署侧（admission）形态 | 放置建议 |
|---|---|---|---|---|
| 质量门禁 | 代码质量/覆盖率/技术债 | sonar-qualitygate job（§4） | 无对应物——质量是代码属性，不是运行时属性 | 只放 CI |
| 签名验证 | 镜像确实出自持私钥者 | CI 内 `cosign verify` 自检 | Kyverno `verifyImages` / sigstore policy-controller 在 Pod 创建时验签（09-cks/04 准入链、labs/09） | CI 快速失败 + prod admission 强制 |
| 漏洞闸门 | 已知 CVE | trivy `--exit-code 1`（§4） | Harbor 入库后定时重扫（09 章）+ `trivy k8s` 运行时巡检 | CI 入库阻断 + 仓库重扫兜底；admission 拦漏洞慎用 |

trade-off 的三条底层逻辑：

1. **CI 门是约定，admission 门是强制**。CI 只约束"走流水线的人"——手 `kubectl apply` 一个野镜像，CI 门全不设防；admission 拦在 apiserver 创建 Pod 的必经之路上，对一切路径生效（含人为失误）。所以"确认身份"（签名）这种不容例外的规则适合下沉 admission。
2. **admission 的代价是它成了集群关键路径**。webhook 不可达时 fail-closed 拒绝一切 Pod 创建（09-cks 经典坑：全集群建不了 Pod），验签还要拉镜像清单增加调度延迟；检测型检查（质量、风格）放进来只会放大故障面，收益为零。
3. **漏洞是移动靶**。今天扫描干净的镜像，明天新 CVE 一出就不干净——正确形态是"入库时阻断 + 仓库侧持续重扫 + 运行时巡检告警"三层时态，而非 admission 一次性判定（真要拦就得配套 exception/宽限期体系，成本常高于收益）。

prod 侧验签的最小示例（Kyverno；与 ImagePolicyWebhook 的对照见 09-cks/04 与 labs/09）：

```yaml
# [文件 verify-image-policy.yaml] 只允许带有效 cosign 签名的镜像进 demo-prod
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-demo-api-signature
spec:
  validationFailureAction: Enforce    # 字段名随 Kyverno 版本演进，以官方文档为准
  rules:
    - name: verify-cosign
      match: { any: [{ resources: { kinds: [Pod], namespaces: [demo-prod] } }] }
      verifyImages:
        - imageReferences: ["192.168.56.10/demo/*"]
          attestors:
            - entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      （此处粘贴 cosign.pub 内容，生成见 09-cks/04 第 4 节）
                      -----END PUBLIC KEY-----
```

## 6. 通知体系：Alertmanager → 飞书，以及分级

### 6.1 为什么中间必须有个适配器

Alertmanager 的 `webhook_configs` 只会发**自家固定结构**（version/status/groupLabels/alerts 数组），不支持自定义 body 模板；飞书机器人要求 `msg_type` 结构。两者之间需要一个几十行的转换层（开源的 PrometheusAlert 本质就是它）：

```python
# [文件 feishu-adapter.py] 最小适配器：结构转换 + 飞书签名 + 超时兜底
import json, os, hmac, hashlib, base64, time, urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler

WEB, SEC = os.environ["FEISHU_WEBHOOK"], os.environ.get("FEISHU_SECRET", "")  # SEC：机器人开启签名校验时必填

def sign(ts):    # 飞书签名：HMAC-SHA256(key=ts+"\n"+secret, message 为空)
    return base64.b64encode(hmac.new(f"{ts}\n{SEC}".encode(), digestmod=hashlib.sha256).digest()).decode()

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        lines = ["[%s] %s" % (body.get("status", "firing").upper(),
                              body.get("groupLabels", {}).get("alertname", "alerts"))]
        for a in body.get("alerts", [])[:10]:          # 每条通知最多 10 条告警，防超长
            lines.append("- %s [%s] %s" % (a["labels"].get("alertname"),
                         a["labels"].get("severity", ""), a.get("annotations", {}).get("summary", "")))
        payload = {"msg_type": "text", "content": {"text": "\n".join(lines)}}
        if SEC:
            ts = str(int(time.time()))
            payload.update(timestamp=ts, sign=sign(ts))
        urllib.request.urlopen(urllib.request.Request(          # 慢/挂不拖垮告警链路
            WEB, data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"}), timeout=5)
        self.send_response(200); self.end_headers()

HTTPServer(("0.0.0.0", int(os.environ.get("PORT", "9094"))), Handler).serve_forever()
```
```bash
# [任意Ubuntu] 常驻运行（先在飞书群里建"自定义机器人"拿到 webhook 地址）
docker run -d --name feishu-am-adapter --restart always -p 9094:9094 \
  -e FEISHU_WEBHOOK="https://open.feishu.cn/open-apis/bot/v2/hook/<你的机器人token>" \
  -e FEISHU_SECRET="<签名密钥，未开启签名则传空>" \
  -v "$PWD/feishu-adapter.py":/app/feishu-adapter.py -w /app python:3.12-alpine python feishu-adapter.py
# 联调：投递一条最小告警——这个 JSON 就是 Alertmanager 发出的固定结构
curl -s -X POST -H 'Content-Type: application/json' http://127.0.0.1:9094/ -d @- <<'EOF'
{"version":"4","status":"firing","groupLabels":{"alertname":"KubePodCrashLooping"},
 "alerts":[{"labels":{"alertname":"KubePodCrashLooping","severity":"critical"},
            "annotations":{"summary":"Pod 重启 12 次"}}]}
EOF
# 群里应收到：[FIRING] KubePodCrashLooping / - KubePodCrashLooping [critical] Pod 重启 12 次
```

### 6.2 飞书两种消息形态

```bash
# [任意Ubuntu] text：最朴素，适合 CI 状态类短消息（14 章巡检脚本同款；@全体在 text 里写 <at user_id="all">）
curl -s -X POST -H 'Content-Type: application/json' "$FEISHU_WEBHOOK" -d @- <<'EOF'
{"msg_type":"text",
 "content": {"text": "[P1] demo-api 主干流水线失败\npipeline: http://192.168.56.10:8080/root/demo-api/-/pipelines/42"}}
EOF
```
```bash
# [任意Ubuntu] interactive 卡片：告警详情 + 动作按钮，把"看到→处置"压成一跳
curl -s -X POST -H 'Content-Type: application/json' "$FEISHU_WEBHOOK" -d @- <<'EOF'
{"msg_type":"interactive",
 "card": {
   "header": {"template": "red",
              "title": {"tag": "plain_text", "content": "[FIRING] KubePodCrashLooping · demo-prod"}},
   "elements": [
     {"tag": "div", "text": {"tag": "lark_md",
        "content": "**severity**: critical\n**namespace**: demo-prod\n**summary**: Pod 重启 12 次"}},
     {"tag": "action", "actions": [
        {"tag": "button", "type": "primary", "url": "https://grafana.example.com/d/demo-api",
         "text": {"tag": "plain_text", "content": "查看面板"}}]}]}}
EOF
# 卡片字段/按钮/签名与频率限制以飞书开放平台文档为准
```

### 6.3 分级路由与通知治理

```yaml
# [文件 am-route-feishu.yaml] Alertmanager 路由片段（grouping 语义见 10-pca/05；amtool check-config 可校验）
route:
  receiver: feishu
  group_by: [alertname, namespace]
  group_wait: 30s
  repeat_interval: 4h
  routes:
    - matchers: [ 'severity = "critical"' ]   # P1 加密重复提醒
      receiver: feishu
      repeat_interval: 30m
receivers:
  - name: feishu
    webhook_configs:
      - url: http://192.168.56.10:9094/
        send_resolved: true                    # 恢复也通知，值班才敢放手
```

| 级别 | 通道 | 触发 | 期望 |
|---|---|---|---|
| P0 | 电话/值班系统（PagerDuty 等） | critical 且影响 SLO | 任何时刻 5 分钟内响应 |
| P1 | 飞书群 + @值班 | severity=critical | 工作时间即时响应 |
| P2 | 飞书群不@ | severity=warning | 当天处理 |
| P3 | 日报汇总 | 趋势类指标 | 周会回顾 |

治理三件套缺一不可：**分级路由**（上表）、**grouping/inhibit**（group_wait 攒批、上游故障抑制下游风暴，10-pca/05）、**静默窗口**（变更窗口主动闭嘴）。只靠脚本级去重窗口（02-programming/04 的极简方案）挡不住跨值班周期的风暴。CI 通知只报失败不报成功——成功是常态，报了就是噪音。

## 7. 面板聚合：Grafana 统一入口的数据源清单

链路上每个组件都吐指标，Grafana 是共同的读视图（它不存数据，10-pca/06 第 1 节）；监控栈用 `scripts/setup/install-prom-stack.sh` 装（kube-prometheus-stack，release 名 `prom`）：

| 数据源 | Grafana 类型 | 采集/接入路径 | 面板回答 |
|---|---|---|---|
| k8s 本身 | Prometheus（装完自带） | cadvisor / kube-state-metrics / node-exporter | 节点、容器、工作负载健康；发布后错误率 |
| ArgoCD | 同一 Prometheus | ServiceMonitor 抓三个 metrics 口：application-controller 8082、server 8083、repo-server 8084（以官方 metrics 文档为准） | OutOfSync 持续时长、同步失败、调和延迟 |
| Jenkins | 同一 Prometheus | 装 Prometheus metrics 插件暴露 `/prometheus`，追加抓取 job（写法同下，HTTP 端点直抓） | 构建时长/失败率——DORA 原料（00 章第 7 节） |
| Harbor | 同一 Prometheus | `harbor.yml` 开 `metric.enabled`，`/metrics` 默认 9090，basic auth 抓取（细节见 09 章） | push/pull/扫描计数、组件健康 |
| SonarQube | JSON API 插件 | 无原生 `/metrics`：Grafana 装 JSON API 数据源调 `/api/measures/component?metricKeys=coverage,bugs,vulnerabilities`（或社区 exporter 转 Prometheus） | 覆盖率、漏洞数、技术债趋势 |

```yaml
# [文件 argocd-servicemonitor.yaml] 把 ArgoCD 纳入集群 Prometheus（先 kubectl -n argocd get svc --show-labels 核对标签）
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-metrics
  namespace: monitoring
  labels:
    release: prom                # 必须命中 Prometheus 的 serviceMonitorSelector，以实际安装为准
spec:
  namespaceSelector: { matchNames: [argocd] }
  selector: { matchLabels: { app.kubernetes.io/name: argocd-metrics } }
  endpoints: [{port: metrics}]
```

面板组织建议：一张"交付健康"总览（发布频率、流水线成功率、时长、变更失败率——DORA 四指标的可视化，00 章第 7 节），下钻分环境；dashboard as-code 进 Git（10-pca/06 第 5 节的 ConfigMap + sidecar 套路）；告警区间用 Alertmanager 数据源叠成 annotation（10-pca/06 的用法）。

## 实战演练：全链路演练剧本

对应 `labs/07-environment-promotion`（建新环境 + ArgoCD 晋升 + 飞书通知），判分以该 lab 的 check.sh 为准。内存预算：GitLab（约 3G）+ Harbor（约 3.5~4G，与 09 章"全家桶吃 4G 左右"及 lab 04 的 4G 前置同口径）+ SonarQube（约 2G）+ runner 同跑约 9~9.5G，10G 的 VM 极限同跑且要停掉无关服务——压 Harbor 到 2G 会踩 09 章坑表的"core 反复重启/内存不足"，不建议。更稳的是分两阶段：先完成步骤 2~5 的 GitLab+Sonar+MR 验证（此时 Harbor 未起，内存充裕），merge 前再拉起 Harbor 与集群侧 registry 信任。

| # | 动作 | 在哪章学过 | 验证 |
|---|---|---|---|
| 1 | VM 起 Harbor（离线包约 700MB 走代理），建项目 `demo` 与 robot 账号；runner 宿主 dockerd 与集群节点 containerd 信任该 http registry | 09 章 + 03-docker/labs/08 | `curl -s http://192.168.56.10/api/v2.0/health` healthy；节点 `crictl pull` 成功（见下方 hosts.toml） |
| 2 | VM 起 SonarQube，建项目 `demo-api`、发 token | 10 章 | `curl -s http://192.168.56.10:9000/api/system/status` |
| 3 | 起 GitLab + runner（tags: docker），建 `root/demo-api` 与 `platform/deploy-repo` 两仓库；deploy-repo 放 base + overlays（test/staging/prod）与 `apps/`，ArgoCD 装 root-app | 02 章 3/4 节 + 07 章实战 + 04 章 4.2 节 | runner 在线；`argocd app list` 三环境 App 均 Synced |
| 4 | 生成 cosign 密钥对，公钥存档；把 §4 的 `.gitlab-ci.yml`、Dockerfile 与 Variables 配进 demo-api | 09-cks/04 第 4 节 + 本章 §4 | 本地手签一次 `cosign verify` 通过；pipeline 配置无错 |
| 5 | 提交一个带格式错误的 MR，修掉后 merge 到 main | 本章 §4 + 10 章 | 先看到 gofmt 红灯挡住合并；merge 后 build→sign→scan 全绿，Harbor UI 出现 SHA tag 与 `sha256-*.sig` 签名 tag |
| 6 | 观察 CI 自动改 `overlays/test` 的 newTag，等 ArgoCD 调和（默认约 3 分钟，或 UI 点 Refresh） | 本章 §3/§4 + 04 章 | `kubectl -n demo-test get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}'` 为新 SHA |
| 7 | prod 晋升：人工 MR 改 `overlays/prod`（建议 digest 形式）；漂移实验：`kubectl -n demo-prod scale deploy demo-api --replicas=9` | 本章 §3 + 04 章实测 | merge 后 demo-prod 镜像更新、MR 留审计；selfHeal 拉回 3 |
| 8 | 部署 feishu-adapter + Alertmanager 路由，跑模拟告警 curl | 本章 §6 | 飞书群收到 [FIRING]，再改造成卡片版 |
| 9 | Grafana 加 ArgoCD/Harbor/Jenkins/Sonar 数据源，建"交付健康"面板 | 本章 §7 + 10-pca/06 | 四类数据上图；`labs/07` check.sh 通过 |

```toml
# [文件 /etc/containerd/certs.d/192.168.56.10/hosts.toml]（集群各节点；config.toml 的 registry config_path 指向 certs.d，细节以 09 章/containerd 官方文档为准）
server = "https://192.168.56.10"
[host."http://192.168.56.10"]
  capabilities = ["pull", "resolve"]
  skip_verify = true
```

## 常见坑（交付平台反模式清单）

| 反模式 | 为什么危险 | 纠正 |
|---|---|---|
| 环境靠手工 kubectl 改 | 单一真相名存实亡，回滚无从谈起 | 一切变更走 Git；应急手改后必须回写（04 章纪律），selfHeal 兜底 |
| 晋升靠复制粘贴 YAML 到"生产目录" | 差异不可 review、无审计，漂移指数增长 | base+overlays + 晋升 MR（07 章 + §3） |
| 门禁只在 CI，部署侧裸奔 | 绕过流水线的路径不受约束，门禁形同虚设 | 签名验证下沉 prod admission（§5），CI 门负责快速反馈 |
| 通知风暴无分级 | 群被刷屏→值班麻木→真告警被淹没 | 分级路由 + grouping/inhibit + 静默三件套（§6.3） |
| Image Updater 与人工提交互相覆盖 | 自动跟新覆盖评审结论，"谁放的行"说不清 | 自动跟新只授权 dev/test 目录，prod 只认 MR（§3） |
| 镜像引用浮动 tag（latest） | 不可复现、回滚失效、扫的不是跑的 | CI 用 SHA tag，prod 钉 digest（09-cks/04 第 3 节） |
| CI/CD/观测各自为政、无统一入口 | 出事时在五个页面间跳，MTTR 被导航吃掉 | Grafana 数据源清单 + 卡片带直达链接（§6/§7） |

## 自测

<details><summary>1. 同集群多命名空间的"环境隔离"为什么必须补齐 ResourceQuota 与 NetworkPolicy 才算成立？</summary>

namespace 只提供名字与管理边界（RBAC 作用域、对象名不冲突），不提供资源与网络的任何隔离：没有 ResourceQuota/LimitRange，test 一次内存泄漏就能把共享节点上的 prod Pod 挤死（§2.1 的爆炸半径重叠）；没有 NetworkPolicy，任何 Pod 都能直连 prod 数据库端口。"同集群多环境"的隔离是策略拼出来的（配额+网络策略+RBAC），这正是独立集群存在的理由——硬隔离不依赖配置纪律。
</details>

<details><summary>2. PR-based 晋升比自动跟新慢几分钟，为什么生产仍选它？什么前提下可以切到自动？</summary>

生产变更的核心成本不是那几分钟，而是坏变更的排查与恢复。PR-based 的 MR 记录了"谁、何时、为什么放这个版本"——出事时 git log 即审计链，回滚即 revert；自动跟新把评审换成"allow-list 正则写对了"，写错时坏镜像直达生产且无人工痕迹。切换前提：变更已高度例行化，且有独立于评审的兜底（admission 验签 + 漏洞闸门 + 分钟级监控发现 + 快速回滚）。满足的通常是 dev/staging，prod 极少满足。
</details>

<details><summary>3. 三道门里，为什么签名验证适合下沉 admission 而质量门禁不适合？漏洞闸门为什么两头都要放？</summary>

签名验证是身份判定：规则确定、无例外、必须覆盖一切创建 Pod 的路径（含绕过 CI 的手 kubectl），恰好匹配 admission 语义；误伤面小（合法发布一定带签名）。质量门禁是代码属性检测，与运行时无关，放 admission 无从检查也零收益，只会把 CI 阶段的问题延迟到部署时爆炸。漏洞是移动靶：扫描合格只是"当时合格"，新 CVE 随时让昨天的镜像失效——所以入库时 CI 阻断（快）、仓库侧持续重扫（管存量）、运行时巡检（管在线），单一位置都留时间窗。
</details>

<details><summary>4. Alertmanager 不能直连飞书机器人，根因是什么？适配器除了格式转换还必须承担哪些责任？</summary>

根因是协议不对称且 `webhook_configs` 不支持模板化：Alertmanager 只发自家固定 schema（version/alerts 数组），飞书要 msg_type 结构。适配器还必须承担：飞书签名计算（timestamp+HMAC，开启校验后缺签名直接 403）、超时与限频兜底（飞书机器人有频率限制，适配器挂了不能反压通知管线）、告警条数截断与字段裁剪（一条通知塞五十个告警既超长又不可读）、恢复通知的语义转换（send_resolved 的 status=resolved 要翻译成"已恢复"）。生产级适配器（如 PrometheusAlert）再叠加分级路由与多后端。
</details>

<details><summary>5. "分级路由、grouping、静默"分别消灭哪种噪音？只用脚本级去重窗口会漏掉什么？</summary>

分级路由消灭重要度错配：P2 刷屏挤占 P1 注意力，让人对频道整体脱敏。grouping 消灭同源并发：一个节点 NotReady 派生的几十条告警应是一条通知（group_wait 攒批 + inhibit 抑制下游症状）。静默消灭已知变更噪音：计划内维护窗口提前闭嘴，而不是靠"群里先无视"的纪律。脚本级去重窗口只挡"完全相同文案的短时重复"：挡不住不同指纹的同源风暴（窗口一过又来一轮）、没有恢复通知、没有跨告警抑制关系、窗口本身还会吞掉"恢复后又复发"的真信号。
</details>

## 延伸阅读

- GitLab MR 流水线与 workflow rules：<https://docs.gitlab.com/ee/ci/pipelines/merge_request_pipelines.html>
- ArgoCD Image Updater（项目状态以仓库公告为准）与 ArgoCD 指标暴露：<https://argocd-image-updater.readthedocs.io/en/stable/> 、<https://argo-cd.readthedocs.io/en/stable/operator-manual/metrics/>
- cosign 与 Trivy：<https://docs.sigstore.dev/> 、<https://trivy.dev/latest/docs/>
- Kyverno 镜像验签：<https://kyverno.io/docs/writing-policies/verify-images/>
- Alertmanager webhook_config 字段：<https://prometheus.io/docs/alerting/latest/configuration/#webhook_config>
- 飞书开放平台·自定义机器人（消息形态/签名/频率限制，以文档为准）：<https://open.feishu.cn/document/client-docs/bot-v3/add-custom-bot>
- Jenkins Prometheus 插件与 Grafana JSON API 插件：<https://plugins.jenkins.io/prometheus/> 、<https://grafana.com/grafana/plugins/marcusolsson-json-datasource/>
