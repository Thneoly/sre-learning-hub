# 08 · Helm：Chart 打包、Release 生命周期与生产纪律

> 模块：06-cicd-iac-gitops ｜ 建议时长：4 小时 ｜ 关联认证：CKA-应用管理（考纲 awareness 层"manifest 管理与模板工具"）/ —（无直接考点，第三方 K8s 软件分发的事实标准）

## 学习目标

- 能解释 Chart / Release / Repository 各自解决什么问题，说出 Helm"模板"路线与 07 章 Kustomize"覆写"路线的分工边界
- 能解剖 `helm create` 生成的 chart：改模板加 probes/resources，正确使用 `.Values/.Release/.Chart` 与 toYaml/default/nindent/required
- 能用 dependencies/alias/global 组装父子 chart，说明 values 的传递与覆盖顺序
- 能说出八种 hook 的执行时机与 hook 和 Job 的关系，排查"安装卡在 hook"的故障
- 能解释 release Secret 存储与升级的三方合并，用 `--atomic/--wait/--timeout` 与 `helm rollback` 完成一次带保底的发布

## 1. 心智模型：Chart、Release、Repository

07 章结尾给过 Helm 的"最小可用集"，本章把它展开成完整体系。三个核心名词先立住：

| 概念 | 是什么 | 类比 |
| --- | --- | --- |
| Chart | 一套带模板的 K8s 应用打包格式：模板 + 默认参数 + 版本号 | 软件安装包（.deb/.rpm） |
| Release | chart + 一组 values 在某命名空间安装出来的**一次实例** | 一次"安装事件"：可升级、可回滚、可卸载 |
| Repository | chart 的分发渠道：HTTP 仓库（`helm repo add`）或 OCI registry（`oci://`） | apt/yum 源、镜像仓库 |

```
 chart（模板 + 默认 values）                release = chart + values + namespace + revision
 ┌────────────────────┐   -f values-prod.yaml   ┌─────────────────────────────────┐
 │ Chart.yaml         │ ────客户端渲染─────────► │ 集群里的资源                     │
 │ values.yaml        │   --set k=v             │ + Secret: sh.helm.release.v1.*  │
 │ templates/*.yaml   │                         │   （版本历史，回滚的数据来源）    │
 └────────────────────┘                         └─────────────────────────────────┘
```

两句话记住机制：**渲染发生在客户端**（`helm template` 不碰集群就能看到全部产物）；**安装是声明式的**（helm 计算差异后 patch，而不是删了重建）。与 Kustomize 的分工沿用 07 章 5.1 节对比表的结论：**自家业务应用用 Kustomize 管 base/overlays——任何字段都能覆写、差异显式可 review；第三方软件用社区 Helm chart 装——别人维护、版本化、可升级**。本学习中心 09-otel、12-data-streaming 的 labs 与 scripts/setup/install-prom-stack.sh 里的 `helm install` 走的都是第二条路。

## 2. Chart 解剖：helm create 的默认结构

### 2.1 目录结构逐个讲

```bash
# [master] helm create demo-chart 之后的结构（find demo-chart -type f | sort）
demo-chart/
├── Chart.yaml            # chart 的身份证：名字、版本、类型、依赖
├── values.yaml           # 默认参数，用户用 -f/--set 覆盖
├── .helmignore           # 打包时排除哪些文件（类似 .gitignore）
├── charts/               # 依赖的子 chart 存放处（helm dependency update 生成）
└── templates/
    ├── _helpers.tpl      # 命名模板（define + include），本身不产出资源
    ├── deployment.yaml   # 业务资源模板（出厂还有 service/ingress/hpa/serviceaccount）
    ├── NOTES.txt         # 安装后打印的使用说明（不进集群，helm status 也会显示）
    └── tests/
        └── test-connection.yaml   # helm test 用的测试 hook
```

Chart.yaml 关键字段：

| 字段 | 含义 | 注意 |
| --- | --- | --- |
| `version` | chart 自己的版本（SemVer），改模板必 bump | 与 appVersion 无关，`--version` 钉的是它 |
| `appVersion` | 装的应用版本（如 nginx 1.27） | 说明性字符串，可被模板 `default` 引用 |
| `type` | application（装应用）/ library（只提供命名模板不产资源） | 复用片段做成 library chart |
| `dependencies` | 子 chart 清单（第 3 节） | |

### 2.2 values 与模板的渲染关系

values.yaml 提供数据，templates/*.yaml 是 Go template（Sprig 函数库全可用），安装前客户端渲染成最终 manifest：

```yaml
# [文件 demo-chart/values.yaml 片段（helm create 出厂内容）]
replicaCount: 1
image:
  repository: nginx
  pullPolicy: IfNotPresent
  tag: ""                  # 留空则回落到 appVersion
resources: {}              # 默认不设，生产必须覆盖
```

```yaml
# [文件 demo-chart/templates/deployment.yaml 对应片段]
  replicas: {{ .Values.replicaCount }}
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
```

覆盖优先级（低 → 高）：chart 内 values.yaml 默认值 → `-f` 文件（多个时后者覆盖前者同名键）→ `--set`。`helm get values <release>` 查看最终生效的用户值。

### 2.3 内置对象：模板里能读什么

| 对象 | 常用字段 | 用途 |
| --- | --- | --- |
| `.Release` | .Name/.Namespace/.Revision/.IsUpgrade/.IsInstall | release 名进资源名与标签，实现"同 chart 多实例不撞名" |
| `.Values` | values.yaml + -f + --set 的合成结果 | 参数化的一切来源 |
| `.Chart` | .Name/.Version/.AppVersion | chart 元信息（镜像 tag 回落等） |
| `.Capabilities` | .KubeVersion/.APIVersions | 按集群版本/可用 API 条件渲染 |
| `.Files` / `.Template` | .Files.Get 等 | 读 chart 内文件、模板自身路径 |

### 2.4 常用函数与管道

`|` 把左侧结果作为右侧函数的最后一个参数。日常高频四个：

```yaml
# [文件 模板片段]
# default：值为空（""/nil/false）时给默认
image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"

# required：值为空直接让渲染失败并报人话——比装到一半才炸强得多
storageClass: {{ required "storageClass 必须显式指定" .Values.storageClass }}

# toYaml + nindent：把 values 里的结构体渲染成缩进正确的 YAML 块
resources:
  {{- toYaml .Values.resources | nindent 12 }}

# include：调用 _helpers.tpl 的命名模板并继续接管道（template 指令不能接管道）
metadata:
  labels:
    {{- include "demo-chart.labels" . | nindent 4 }}
```

`nindent` 是新人第一杀手：`toYaml` 的输出顶格，必须**先换行再整体右移**才能挂到父键下面。`indent` 只缩进不换行：

```
 resources: limits:...        ← indent：产出挤在同一行，非法 YAML，安装直接报解析错误
 resources:
   limits: ...                ← nindent（= 换行 + indent）：正确
```

`{{-` 与 `-}}` 负责吃掉多余空白；渲染产物空行、缩进异常时，先查它们与 nindent 的数字。

## 3. 依赖与子 chart

应用常带伴生组件（缓存、DB）。把第三方 chart 声明为依赖，由 Helm 拼装成一体：

```yaml
# [文件 demo-chart/Chart.yaml 片段]
dependencies:
  - name: redis
    version: 20.x.x                          # 示例占位：装前查 chart 页面当前版本
    repository: oci://registry-1.docker.io/bitnamicharts
    alias: cache                             # 起别名：同一子 chart 可装多份（cache/cache2）
    condition: cache.enabled                 # 父 values 里这个键为 false 就跳过该子 chart
```

```bash
# [master] 拉取依赖到 charts/ 子目录（.tgz 提交进 Git，安装时不再依赖外网）
helm dependency update demo-chart
```

values 传递两条路：

- **父改子**：父 values 里以子 chart 名（或 alias）为键——`cache: { architecture: standalone }`；
- **全局注入**：`global` 键会自动出现在**所有**子 chart 的 `.Values.global` 里，放镜像仓库地址、拉取凭据这类"人人都要"的值。

完整覆盖顺序：子 chart 自己的 values.yaml < 父 values 里的子 chart 段 < `-f`/`--set`。子 chart 没暴露的键，父 chart 改不了——这是模板路线的固有边界（自测第 5 题）。

## 4. Hooks：八种执行时机

生命周期动作（install/upgrade/rollback/delete）前后插入一次性动作。注解写在任意资源的 metadata 上：

| Hook | 执行时机 | 典型用途 |
| --- | --- | --- |
| pre-install | chart 已渲染、资源创建**之前** | 建外部依赖、初始化 |
| post-install | 主资源创建之后 | 冒烟验证、服务注册 |
| pre-upgrade / post-upgrade | 升级 apply 前 / 后 | DB schema 迁移 / 迁移后校验 |
| pre-rollback / post-rollback | 回滚前 / 后 | 逆迁移 |
| pre-delete / post-delete | uninstall 前 / 后 | 备份 / 清理 |

```yaml
# [文件 demo-chart/templates/migrate-job.yaml] 注解把普通 Job 标记为"pre-upgrade 时机执行"
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ .Release.Name }}-migrate
  annotations:
    "helm.sh/hook": pre-upgrade
    "helm.sh/hook-weight": "-5"                  # 数字小先执行，可为负
    "helm.sh/hook-delete-policy": hook-succeeded # 成功即删（默认执行后保留）
spec: ...
```

**与 Job 的关系**：注解只是"时机"标记，资源类型任选，但迁移类 hook 几乎总用 Job——因为 Helm 判定 hook"完成"的依据正是 **Job 跑到成功（Pod 则看 Ready）**，与"跑一次直到成功"的迁移语义吻合；Deployment 没有终点，做 hook 永远等不完。CronJob 不能当 hook。删除策略：Helm 3 默认在下次执行前先删同名旧 hook（before-hook-creation 语义）；`hook-succeeded`/`hook-failed` 控制执行后去留——排障时想让失败的 hook 留在现场，就别设 succeeded 删除。另外 `helm test` 走的是独立的 test 类 hook（出厂的 test-connection.yaml 就是）。

## 5. Release 机制：升级、回滚与保底

```
 helm install / upgrade
   1. 客户端渲染出完整 manifest
   2. 逐资源三方合并：旧 manifest × 集群现状 × 新 manifest → patch（不是删了重建）
   3. 整个 release（chart + values + 渲染产物）gzip + base64 存入 Secret：
      sh.helm.release.v1.<release>.v<N>（所在命名空间，type=helm.sh/release.v1）
   4. <N> 自增——回滚 = 把某旧 revision 重新应用一遍，同样记为新 revision
```

由此解释几个日常现象：`kubectl get secret` 能看到 release 历史（元数据就存在业务命名空间里）；`helm get manifest/values <release>` 能还原"当时到底装了什么"；`helm rollback` 之后 revision 号不倒退，只是新增一条指向旧内容的记录。

四个生产参数（本中心 scripts/setup/install-prom-stack.sh 用的就是 `upgrade --install` 套路）：

- `helm upgrade --install`：不存在则装、存在则升，幂等——CI 里固定这么写；
- `--wait`：等到 Deployment available / PVC bound / Job complete 才返回。没有它，"apply 完成"就算成功，Pod 崩了 Helm 根本不看；
- `--atomic`：失败自动 rollback（隐含 --wait），坏版本落地即回退；
- `--timeout`：等待上限，默认 5m，大 chart 显式给足（如 `--timeout 10m`）。

## 6. 生产纪律

- **钉版本**：`--version 61.9.1`，永远别浮动 latest——今天能装的 chart 明天可能升大版本换 CRD、改 values 键。"repo add → repo update → install --version"三连写进脚本。
- **values 分层**：`-f values-base.yaml -f values-prod.yaml`（后者覆盖同名键），不要养一个巨型 values 文件——环境差异显式可见才可 review。
- **先 diff 再上**：helm-diff 插件把将要发生的 patch 打出来，作为上生产前的最后一道 review 与 CI 门禁（安装见实战演练后的说明）。
- **GitOps 管的 release 禁止 helm 手改**：ArgoCD 以 Git 为唯一真相（04 章第 1 节），绕过 Git 的 `helm upgrade` 要么被自愈打回，要么应用永远 OutOfSync。要改就改 Git 里的 values 或 Application 参数；应急手改后必须回写 Git。
- **chart 也是供应链**：装第三方 chart 前至少 `helm template` 通读一遍产物（../07-cks/04-supply-chain-security.md 的习惯）；values schema 报错先怀疑 chart 版本与文档不匹配。

## 实战演练

### 步骤 0：helm 就位

```bash
# [master]
helm version --short 2>/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version --short       # 预期：v3.8+（OCI 功能需要）
```

### 步骤 1：helm create 并解剖

```bash
# [master]
helm create demo-chart
find demo-chart -type f | sort
cat demo-chart/Chart.yaml                       # 关注 version 与 appVersion 的分工
grep -n 'nindent\|toYaml\|default\|include' demo-chart/templates/deployment.yaml
# 预期：2.4 节讲的函数在出厂模板里都有真实使用
```

### 步骤 2：本地渲染验证（不碰集群）

```bash
# [master]
helm lint demo-chart                           # 预期：1 chart passed
helm template demo demo-chart | grep 'kind:' | sort -u
# 预期：ServiceAccount / Service / Deployment（ingress/hpa 默认关闭不渲染）；
#       image 行是 nginx:<appVersion>（default 回落的成果）
```

### 步骤 3：values 驱动加 probes/resources

```bash
# [master] 1) 出厂 values.yaml 自带 resources: {}，重复键会让 helm 直接报错，先删再追加
sed -i '/^resources: {}/d' demo-chart/values.yaml
cat >> demo-chart/values.yaml <<'EOF'
probes:
  enabled: true
  path: /
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    memory: 128Mi
EOF
# 2) 在 deployment.yaml 容器段（imagePullPolicy 之后、resources: 之前，同级缩进）插入探针块
```

```yaml
# [文件 demo-chart/templates/deployment.yaml 容器段插入]
          {{- if .Values.probes.enabled }}
          livenessProbe:
            httpGet:
              path: {{ .Values.probes.path | quote }}
              port: http                  # 出厂模板把容器端口命名为 http
          readinessProbe:
            httpGet:
              path: {{ .Values.probes.path | quote }}
              port: http
          {{- end }}
```

```bash
# [master] 3) 渲染验证
helm template demo demo-chart | sed -n '/livenessProbe/,/readinessProbe/p'
helm template demo demo-chart | grep -A4 'resources:'
# 预期：requests/limits 以正确的嵌套缩进出现在 resources: 下（toYaml+nindent 的成果）
helm template demo demo-chart --set probes.enabled=false | grep -c livenessProbe   # 预期：0
```

### 步骤 4：安装并看清 release 存储

```bash
# [master]
helm upgrade --install demo demo-chart -n helm-demo --create-namespace --wait
kubectl get secret -n helm-demo | grep sh.helm
# 预期：sh.helm.release.v1.demo.v1 —— 第 5 节讲的 release 元数据就在这
kubectl get deploy,pod -n helm-demo           # 预期：demo-demo-chart 1/1 Running
helm get manifest demo -n helm-demo | grep -A2 livenessProbe   # 集群里实际应用的产物
helm test demo -n helm-demo                   # 跑出厂的 test-connection（test 类 hook）
```

### 步骤 5：升级 → 坏升级 → 回滚 → atomic 保底

```bash
# [master] 1) 正常升级：副本 1→2，revision 1→2
sed -i 's/^replicaCount: 1/replicaCount: 2/' demo-chart/values.yaml
helm upgrade demo demo-chart -n helm-demo --wait
helm history demo -n helm-demo                # 预期：rev2 deployed
kubectl get deploy demo-demo-chart -n helm-demo   # 预期：READY 2/2

# 2) 坏升级（无任何保底参数）：探针指向不存在的路径
helm upgrade demo demo-chart -n helm-demo --set probes.path=/nope
# 命令"成功"返回——但没有 --wait，Pod 起不来 Helm 也不管：
kubectl get pods -n helm-demo    # 预期：新 Pod 0/1 NotReady、RESTARTS 攀升（liveness 反复重启）
helm history demo -n helm-demo   # rev3 仍标 deployed

# 3) 手动回滚
helm rollback demo 2 -n helm-demo
helm history demo -n helm-demo   # 预期：rev4 = rollback，状态 deployed（revision 只增不减）
kubectl get pods -n helm-demo    # 预期：全部 1/1 Running
```

```bash
# [master] 4) --atomic 演练：同样的坏值，失败自动回退
helm upgrade demo demo-chart -n helm-demo --set probes.path=/nope --atomic --timeout 2m
# 预期：等待超时 → upgrade 失败 → 自动 rollback → 命令以非零退出码返回
helm history demo -n helm-demo   # 预期：末尾多出一条 failed 与一条自动回滚后的 deployed
kubectl get pods -n helm-demo    # 预期：仍是健康版本
```

### 步骤 6：推送到 OCI registry 并从它安装

```bash
# [master] 起本地 registry（做法同 ../03-docker/labs/08-local-registry/，helm 3.8+ OCI 已 GA）
docker run -d --name chart-registry --restart always -p 5000:5000 -v chart-reg:/var/lib/registry registry:2
curl -s http://localhost:5000/v2/               # 预期：{}

sed -i 's/^version: 0.1.0/version: 0.2.0/' demo-chart/Chart.yaml   # bump chart 版本
helm package demo-chart                          # 预期：产出 demo-chart-0.2.0.tgz
helm push demo-chart-0.2.0.tgz oci://localhost:5000/charts
curl -s http://localhost:5000/v2/charts/demo-chart/tags/list   # 预期：{"tags":["0.2.0"]}

helm show chart oci://localhost:5000/charts/demo-chart --version 0.2.0   # 装前先看元数据
helm upgrade --install demo2 oci://localhost:5000/charts/demo-chart --version 0.2.0 -n helm-demo --wait
helm list -n helm-demo                           # 预期：demo 与 demo2 两个 release
```

说明：registry 只在 master 本机可达（localhost 被视为 insecure，免 TLS 配置）；要从其他节点拉需换 master IP 并配 insecure registry，见 03-docker/labs/08 的提示 1。生产上的 `helm diff` 插件另装：`helm plugin install https://github.com/databus23/helm-diff`，然后 `helm diff upgrade demo ./demo-chart -n helm-demo` 先看 patch 再动手。

### 步骤 7：清理

```bash
# [master]
helm uninstall demo demo2 -n helm-demo
kubectl delete ns helm-demo --ignore-not-found
docker rm -f chart-registry && docker volume rm chart-reg
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 安装报 YAML 解析错误，或渲染产物里 `labels: app: demo` 挤在一行 | `toYaml` 后用了 `indent`（不换行）或漏了缩进参数 | 用 `\| nindent N`（先换行再缩进）；改完必 `helm template` 肉眼过产物 |
| 报 "cannot convert string to int64"（port/replicas 类字段） | values 里数字加了引号成字符串，或 `--set` 传的就是字符串 | 数字不加引号；结构化值走 `-f` 而非 `--set` |
| `helm install/upgrade` 卡住很久最后超时 | pre-install/pre-upgrade hook 的 Job 没跑成（镜像拉不动、命令失败），Helm 在等它完成 | 另开终端 `kubectl get jobs,pods` 看 hook 资源与日志；按 hook-delete-policy 清理后重试 |
| `helm uninstall` 后 CRD 还在，老集群装新版报 "no matches for kind" | Helm 3 默认不删 CRD（防止删掉仍在用的资源） | CRD 的增删单独管理（专用 release 或 GitOps）；确认无依赖后手动 `kubectl delete crd` |
| `helm upgrade` 报 "has no deployed releases" | 上次失败的 revision 留在 history，Helm 拒绝在失败态上继续 | `helm history` 找最近的 deployed，`helm rollback <rel> <n>` 恢复后再升；或确认后 uninstall 重装 |
| 追加 values 后报 "mapping key ... already defined" | 同一个顶层键（如 resources）在 values.yaml 里出现两次 | 改前先删旧键；values 分层靠多个 `-f`，不是往一个文件里堆 |
| `--set` 传的值带逗号被拆开 / 布尔变字符串 | `--set` 是简易解析器：逗号分列表、点号开路径、值一律按字面处理 | 复杂值改 `-f` 文件；逗号转义 `\,`；`--set-string` 显式定字符串 |
| 改了 values 但 release 行为没变 | 覆盖优先级没弄清：`-f` 按顺序后者覆盖前者，`--set` 最高 | `helm get values <rel>` 看实际生效值；分层文件按固定顺序传 |
| ArgoCD 里应用永远 OutOfSync | 有人绕过 Git 用 helm 改了 GitOps 管的 release | 改动回写 Git（values/Application 参数）；应急手改后必须同步回 Git（04 章自愈实测） |

## 自测

<details><summary>1. Helm 3 为什么把 release 元数据存在目标命名空间的 Secret 里，而不是本地文件或单独数据库？这带来什么收益与限制？</summary>

收益：状态跟着集群和命名空间走——`kubectl get secret` 就能审计装了什么，不需要额外部件（Helm 2 的 Tiller 就是一个要维护权限的单点）；release 的存在性由 K8s 的 RBAC/namespace 隔离自然保护。限制：Secret 里的内容是 gzip+base64 的完整产物，谁有 namespace 的 secret 读权限谁就能看到全部渲染值（含敏感 values）；卸载 release 即删历史，回滚能力随之消失；etcd 的对象大小限制也约束超大 chart。运维上意味着：release Secret 要纳入备份与权限收敛的范围。
</details>

<details><summary>2. `indent` 与 `nindent` 只差一个换行，解释这个换行为什么是合法与非法 YAML 的分界？nindent 数字给错时症状是什么？</summary>

`toYaml` 输出顶格（第一行没有前导空格），要挂进父键就必须另起一行且整体右移到父键的子级缩进。`indent` 只加缩进不加换行，产出 `resources: limits:...` 挤在一行——YAML 里这是把整个块当成标量解析，直接报错。`nindent = 换行 + indent`。数字给错（如模板里父键在第 10 列却写 nindent 8）时 YAML 仍可能"合法"但结构错了——子键缩进不足会跑出到父键外面，渲染成功却装出错误对象，这比报错更隐蔽，所以改模板后必须 `helm template` 逐行核对缩进。
</details>

<details><summary>3. 为什么说没有 --wait 的 upgrade 的"成功"可能毫无意义？--atomic 在此之上又补了什么？</summary>

Helm 默认只保证"资源已 apply"，不保证它们健康：镜像拉不动、探针失败、Job 卡住，命令照样返回成功。`--wait` 把"成功"的定义改成 Deployment available / PVC bound / Job complete，才与"这次发布是好的"对齐。`--atomic = --wait + 失败自动 rollback`：坏版本一落地就回退到上一个 deployed revision，把"人工发现故障再手动回滚"的窗口压缩到零。注意它不能替代流水线里的测试——它只看 K8s 层面的健康信号。
</details>

<details><summary>4. hook 和普通 Job 的区别是什么？为什么迁移类 hook 几乎总用 Job？hook 失败时整个安装会发生什么？</summary>

普通 Job 只是 chart 里的一个资源，install 时被 apply，Helm 不等它，生命周期完全交给 K8s；hook 是带 `helm.sh/hook` 注解的资源，Helm 在指定生命周期时机创建它并**等待其完成**（Job 看成功完成，Pod 看 Ready）才继续主流程。迁移用 Job 是因为语义吻合：跑一次、以成功为终点，且失败可由 K8s 按 backoffLimit 重试。hook 失败（或等待超时）会让整个 install/upgrade 以失败告终，主资源不会被创建/更新——这正是"pre-upgrade 迁移没成功就不动应用"的保护逻辑，也是"安装卡住"排障时最先要看 jobs/pods 的原因。
</details>

<details><summary>5. 子 chart 没暴露的 values 键，父 chart 改不了——这个限制换来的是什么？结合 07 章对比表说明两条路线各自的适用面。</summary>

换来的是**可分发性**：chart 作者只维护一份模板和一组受控参数，就能服务所有安装方；参数面即契约，升级 chart 时作者保证契约内的兼容。代价是不在契约内的需求只能 fork chart 或放弃。Kustomize 相反：任何字段都能覆写（契约是完整的 base），但没有参数化就没有"一份产物服务所有安装方"的能力。所以适用面是：要分发给别人/复用社区成果的第三方软件走 Helm；自家业务、差异以环境为主、要求每个改动显式可 review 的走 Kustomize——两者常在同一个平台里并存（07 章 5.2 节的 helmCharts 混用）。
</details>

## 延伸阅读

- Helm 官方文档（本章全部内容的权威出处）：<https://helm.sh/docs/>
- Chart 模板开发指南（内置对象、函数、Sprig 清单）：<https://helm.sh/docs/chart_template_guide/>
- Hooks 与删除策略详解：<https://helm.sh/docs/charts_hooks/>
- OCI registry 用法（helm push/show/pull）：<https://helm.sh/docs/topics/registries/>
- helm-diff 插件：<https://github.com/databus23/helm-diff>
