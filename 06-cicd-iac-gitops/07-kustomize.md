# 07 · Kustomize：无模板的多环境 Manifest 管理

> 模块：06-cicd-iac-gitops ｜ 建议时长：4 小时 ｜ 关联认证：CKA-应用管理（考纲 awareness 层的"manifest 管理与模板工具"）/ —（无直接考点，多环境交付的事实标准）

## 学习目标

- 能解释"模板"与"覆写"两种应用定义思路的差异，并给一个团队讲清楚什么时候选 Helm、什么时候选 Kustomize
- 能搭建 base/overlays 目录结构，用 patches（strategic merge 与 JSON6902）、replicas、images 字段表达环境差异
- 能用 configMapGenerator / secretGenerator 从文件与字面量生成配置，并解释 hash 后缀如何联动滚动更新
- 能在 kustomization.yaml 里以 helmCharts 方式引入第三方 chart，说出它与 `helm install` 的本质区别，并排查 patches 不命中、hash 后缀、patchesStrategicMerge 报错三类高频故障

## 1. 问题：三份 90% 相同的 YAML

第 04 章（ArgoCD）的多环境仓库布局里，test 与 prod 各有一套 manifest。最朴素的实现是每个环境复制一份 YAML 再改几行——两环境还行，五环境就是灾难：改一个探针路径要改五处，漏改一处就是"环境间配置漂移"，这正是 GitOps 想消灭的东西。业界的两条路线：

| 路线 | 思路 | 代表 |
| --- | --- | --- |
| 模板 | 写一份带变量的模板，每个环境喂一组值渲染出 manifest | Helm |
| 覆写 | 写一份完整的通用 manifest（base），每个环境用补丁声明差异 | Kustomize |

Kustomize 由 Kubernetes 团队开发，**直接内置在 kubectl 里**（无需装额外 CLI），这是它落地成本极低的原因：

```bash
# [master] kubectl 里的 kustomize 命令族（-k 后面是目录，不是文件）
kubectl kustomize overlays/prod      # 只渲染，打印最终 manifest
kubectl diff -k overlays/prod        # 渲染结果与集群现状做 diff
kubectl apply -k overlays/prod       # 渲染并应用
kubectl delete -k overlays/prod      # 按渲染结果删除
```

## 2. base + overlays：差异即目录

```
base/                    ┌─ overlays/test/kustomization.yaml ─┐
├─ deployment.yaml       │ resources: [../../base]            │
├─ service.yaml          │ namespace/replicas/images/生成器    │──┐
└─ kustomization.yaml    └────────────────────────────────────┘  │
                         ┌─ overlays/prod/kustomization.yaml ─┐  │
                         │ resources: [../../base]            │  │
                         │ replicas/patches/生成器             │──┤
                         └────────────────────────────────────┘  ▼
                                                kustomize build（纯本地计算，无模板引擎）
                                                                 ▼
                              一份完整、可读、可直接 apply 的 K8s manifest
```

关键认知：**overlay 不产生"新资源"，它只是 base 的一个有序变换（transform）序列**。`kustomize build` 是纯函数——输入目录 + Git 提交，输出唯一确定的 manifest，这也是它天然适配 GitOps 的原因（ArgoCD 的 repo-server 内部就是调它渲染，见第 04 章 4.1 节）。对应关系是多对多：一个 base 可被 N 个 overlay 引用，overlay 的 `resources` 也能引用远程 URL（`github.com/org/repo/manifests/base?ref=v1.2.0`），跨团队复用由此而来。

## 3. patches：环境差异的三种写法

### 3.1 strategic merge：按 merge key 合并

补丁文件本身是一个"残缺的 K8s 对象"——只要有 apiVersion / kind / metadata.name 就合法：

```yaml
# [文件 overlays/test/patch-resources.yaml]
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-api
spec:
  template:
    spec:
      containers:
      - name: api                 # 关键：列表按 name 这个 merge key 合并
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
```

最容易误解的点：`containers` 是列表，但 strategic merge **不会整表替换**，而是按 `name`（该字段的 patch merge key，来自 K8s OpenAPI 定义）逐元素深合并——base 里 api 容器的其他字段（image、ports）原样保留。想删掉 base 里的某个字段，strategic merge 做不到，得用 3.2 的 JSON6902 `remove`。

### 3.2 JSON6902：按路径精确操作

改数组下标、删字段这类"合并语义表达不了"的操作用 JSON6902 补丁（RFC 6902 的 add/replace/remove）：

```yaml
# [文件 overlays/prod/kustomization.yaml 片段]
patches:
  - target:                        # 先声明补丁打到谁（精确匹配）
      group: apps
      version: v1
      kind: Deployment
      name: demo-api
    patch: |-                      # 再声明操作序列（YAML 或 JSON 均可）
      - op: replace
        path: /spec/template/spec/containers/0/image
        value: nginx:1.27-perl
```

两个坑提前说：`path` 里数组下标从 0 开始；`add` 一个子路径时父对象必须已存在（比如往 `/metadata/annotations/env` add，而 `annotations` 本身不存在时会报错——先加 `/metadata/annotations` 这个空对象，或改用 strategic merge）。选型经验：**能用 strategic merge 就用它**（像写普通 YAML、按 name 定位不惧顺序变化）；只在删除字段、或列表元素没有 merge key 可依、或要按 labelSelector 批量打补丁时用 JSON6902。

### 3.3 专用 transformer：replicas / images / namespace

这三类差异太常见，Kustomize 给了专用字段，比写补丁更短且自带语义：

```yaml
# [文件 overlays/test/kustomization.yaml 片段]
namespace: demo-test          # 给渲染出的所有资源统一改写 metadata.namespace
replicas:
  - name: demo-api            # 注意：不会自动创建该 namespace，见常见坑
    count: 1
images:
  - name: nginx               # base 里的镜像名（不含 tag）
    newTag: "1.27-alpine"     # CI 改这一行提 PR，就是一次发布
```

`images.newTag` 与 GitOps 的衔接是重点：CI 构建出新镜像后，**唯一动作是把 overlay 里的 newTag（或 digest）改成新值并提交**，ArgoCD 检测到 Git 变化后拉取渲染、apply——第 04 章的发布闭环在这里落到一个具体字段上。此外还有 `namePrefix/nameSuffix`（批量改资源名防撞名）等 transformer，用到时查官方 reference。

## 4. 生成器：配置即代码 + 自动滚动

配置散落在 YAML 字符串里难维护，Kustomize 提供从文件/字面量生成 ConfigMap 与 Secret 的能力：

```yaml
# [文件 overlays/test/kustomization.yaml 片段]
configMapGenerator:
  - name: demo-config
    literals:
      - LOG_LEVEL=debug
      - OPTION=A
    files:
      - app.conf=conf/app-test.conf   # key=文件路径，文件内容即 value
secretGenerator:
  - name: demo-secret
    envs:
      - secret.env                     # 文件内容是 KEY=VALUE 行，避免凭据进 Git 明文
```

生成出来的对象名不是 `demo-config`，而是 `demo-config-<hash>`，hash 由内容算出。这个后缀是设计核心：

```
改 literals 里的 LOG_LEVEL
   → 内容变 → hash 变 → ConfigMap 名字变成 demo-config-h2
   → Deployment 模板里对 demo-config 的引用被自动改写成 demo-config-h2
   → Pod 模板变 → 触发滚动更新
```

也就是说**配置变更自动驱动发布**，不需要手动 `kubectl rollout restart`。代价是：任何按固定名字引用这个 ConfigMap 的**集群外系统**（别的仓库硬编码、监控面板写死名字）都会失效——这种场景用 `generatorOptions.disableNameSuffixHash: true` 关掉后缀，同时也就放弃了自动滚动。业务镜像的 Secret 建议 hash（`env` 形式还避免把明文提交进 Git）；跨系统共享的基础配置才考虑关。

## 5. 与 Helm 的对比和混用

### 5.1 一张表选型

| 维度 | Kustomize | Helm |
| --- | --- | --- |
| 心智模型 | 覆写：base 是真实对象，overlay 改字段 | 模板：chart 是模板，values 喂变量 |
| 参数自由度 | 任意字段都能覆写 | 只能改 chart 作者暴露的 values 键 |
| 学习成本 | 低（会 K8s YAML 就会大半） | 中（模板语法、内置对象、hooks、依赖） |
| 多环境 | overlays 目录，差异即文件 | 每环境一份 values-<env>.yaml |
| 分发 | Git 仓库/目录 | chart 仓库与 OCI registry，版本化成熟 |
| 生态 | 内置 kubectl，无中心仓库 | Artifact Hub 海量第三方 chart |
| 适用 | 自家业务应用、环境差异为主的场景 | 分发/安装第三方软件、版本升级管理 |

一句话分工（也是业界的常见格局）：**自家业务用 Kustomize 管 base/overlays，第三方中间件用社区 Helm chart 装**——前者要"任何字段都能改、差异显式可 review"，后者要"别人维护的版本化安装包"。

Helm 的系统教学见下一章 08-helm.md，这里先给后续章节（中间件、可观测性 labs 里大量 `helm install`）够用的最小集：

```bash
# [master] chart=安装包，values=参数，release=一次安装实例
helm upgrade --install demo ./chart -n demo --create-namespace -f values-prod.yaml  # 幂等安装/升级
helm rollback demo 1                  # 回滚；helm template ./chart -f v.yaml 只渲染不安装
```

### 5.2 helmCharts：在 kustomization 里混用 chart

第三方的部分不必另开一套流程，直接在 overlay 里声明：

```yaml
# [文件 overlays/prod/kustomization.yaml 片段]
helmCharts:
  - name: redis
    repo: oci://registry-1.docker.io/bitnamicharts   # OCI 形式的 chart 仓库
    version: 20.6.0        # 示例占位：以 bitnami chart 页面当前版本为准再替换
    releaseName: redis
    namespace: middleware
    valuesInline:          # 等价于 -f/--set 的内联覆写
      architecture: standalone
```

它与 `helm install` 的本质区别是**"渲染"而非"安装"**：

| 维度 | `helm install` | kustomization `helmCharts` |
| --- | --- | --- |
| 产物 | release 记录（集群里的 Secret `sh.helm.release.v1.*`）+ 资源 | 仅资源，无 release 概念 |
| 生命周期 | `helm upgrade/rollback/uninstall` 管理 | `kubectl apply/delete -k` 管理，回滚靠 Git revert |
| hooks | pre-install/post-install 等 hook 会真的执行 | 没有 helm 生命周期，hook 类注解没有执行者 |

混用前务必 `kubectl kustomize overlays/prod` 过一遍渲染产物——尤其是带 hooks 的 chart，确认你需要的资源确实出现在输出里。ArgoCD 2.6+ 还支持多源 Application（chart 一个 source、kustomize 补丁另一个 source），是"用社区 chart + 打自己的补丁"的另一种不落盘写法，取舍见官方文档。

## 实战演练

### 步骤 1：搭 base

```bash
# [master]
mkdir -p ~/kustomize-demo/{base,overlays/test/conf,overlays/prod} && cd ~/kustomize-demo
cat > base/deployment.yaml <<'EOF'
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
            name: demo-config       # base 只留引用，配置由各 overlay 生成
EOF
cat > base/service.yaml <<'EOF'
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
EOF
cat > base/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - deployment.yaml
  - service.yaml
EOF
kubectl kustomize base        # 预期：打印出 Deployment+Service，镜像是 nginx:1.27
```

注意 base 里**只有引用 `demo-config`，没有生成它**——每个环境自己生成内容不同的同名配置，这是标准模式。

### 步骤 2：test overlay（strategic merge + transformer + 生成器）

```bash
# [master]
cat > overlays/test/conf/app-test.conf <<'EOF'
mode=debug
timeout=5s
EOF
cat > overlays/test/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: demo-test
resources:
  - ../../base
patches:
  - patch: |-                   # 内联 strategic merge（与 3.1 的 path 文件形式等价）
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
    files:
      - app.conf=conf/app-test.conf
EOF
kubectl create namespace demo-test
kubectl diff -k overlays/test   # 预期：将要创建 demo-api 等 4 类资源（diff 对不存在资源显示 create）
kubectl apply -k overlays/test
kubectl get deploy,po,cm -n demo-test
# 预期：demo-api-xxxxx-xxxx 1/1 Running；cm 名字是 demo-config-<hash> 而非 demo-config
```

### 步骤 3：验证 hash 联动滚动

```bash
# [master]
kubectl get cm -n demo-test -o name          # 记下 demo-config-<hash1>
sed -i 's/LOG_LEVEL=debug/LOG_LEVEL=info/' overlays/test/kustomization.yaml
kubectl kustomize overlays/test | grep 'name: demo-config-'   # 预期：hash 已变（hash2）
kubectl apply -k overlays/test
kubectl rollout status deployment/demo-api -n demo-test   # 预期：新 Pod 滚动起来
# Deployment 里对 demo-config 的引用已被自动改写成 hash2，Pod 模板变化才触发了滚动
```

### 步骤 4：prod overlay（JSON6902 改镜像）

```bash
# [master]
cat > overlays/prod/kustomization.yaml <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: demo-prod
resources:
  - ../../base
replicas:
  - name: demo-api
    count: 3
patches:
  - target:
      group: apps
      version: v1
      kind: Deployment
      name: demo-api
    patch: |-
      - op: replace
        path: /spec/template/spec/containers/0/image
        value: nginx:1.27-perl
configMapGenerator:
  - name: demo-config
    literals:
      - LOG_LEVEL=warn
EOF
kubectl create namespace demo-prod
kubectl kustomize overlays/prod | grep -E 'image:|replicas:|name: demo-config-'
# 预期：镜像 nginx:1.27-perl（JSON6902 改写生效）、replicas 3、配置 hash 与 test 环境不同
kubectl apply -k overlays/prod && kubectl get deploy -n demo-prod
```

### 步骤 5：helmCharts 混用 + 清理

```bash
# [master] 前置：渲染机要有 helm（官方安装脚本）
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
# 把 5.2 节的 helmCharts 片段追加进 overlays/prod/kustomization.yaml 后：
kubectl kustomize overlays/prod | head -40
# 预期：开头是 chart 渲染出的 redis 资源，后面是 demo-api——体会两种产物合流成一份 manifest
# 练习集群资源紧张就停在渲染，不必 apply；实验完统一清理：
kubectl delete -k overlays/prod --ignore-not-found
kubectl delete -k overlays/test --ignore-not-found
kubectl delete ns demo-test demo-prod --ignore-not-found
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| `error: ... field "patchesStrategicMerge" not found` | kubectl 1.27 起内置 kustomize v5，已移除该顶层字段（旧版本只是废弃警告） | 迁移为 `patches: - path: xxx.yaml`，语义不变 |
| patch 写了但不生效，也无报错 | strategic merge 补丁缺 `metadata.name` 或 kind 拼错，静默不命中 | 先 `kubectl kustomize <dir>` 看产物，逐字段核对 apiVersion/kind/name |
| `kubectl apply -k` 报 namespace 不存在 | `namespace:` 字段只改写资源的命名空间，不创建它 | 事先 `kubectl create namespace <ns>` |
| 外部系统按固定名引用 ConfigMap 失败 | 生成器自动追加 `-<hash>` 后缀 | 引用在渲染内会被自动改写；集群外系统才需要 `disableNameSuffixHash: true` |
| helmCharts 渲染报 `helm` not found | 本地渲染时 kustomize 要调 helm 二进制 | 装 helm，或交给 ArgoCD repo-server 渲染 |
| 改了 base 后 apply 还是旧值 | 渲染目录与修改目录不一致，或补丁把改动又覆写回去了 | 永远先 `kubectl kustomize <dir>` 确认产物再 apply |
| 两个环境各多出一份同名 ConfigMap | base 和 overlay 都声明了同名生成器，hash 不同成为两个对象 | 生成器只放 overlay（或只放 base），别两边都放 |

## 自测

<details><summary>1. Helm 用 values 参数化，Kustomize 用 overlay 覆写，两者把"环境差异"分别放在哪里？各自牺牲了什么？</summary>

Helm 把差异放在 chart 外部的 values 文件里，chart 内部是模板——收益是分发方便（chart 仓库版本化），代价是**只有 chart 作者暴露的键才能改**，没暴露的字段要么改 chart（fork）要么放弃。Kustomize 把差异放在 overlay 目录的补丁里，base 始终是完整真实对象——收益是**任何字段都能覆写且差异显式可 review**，代价是没有模板变量就没有"一份产物服务所有安装方"的分发能力，强依赖目录结构。
</details>

<details><summary>2. configMapGenerator 的 hash 后缀解决了什么问题？禁用它失去什么？</summary>

解决"配置变了但没人知道"的问题：内容变→hash 变→对象名变→引用方（Pod 模板）变→自动触发滚动更新，配置发布像镜像发布一样有明确的传播链路。禁用后名称稳定，外部系统可以固定引用，但配置更新不再驱动滚动，需要自己 rollout restart，且无法从对象名分辨配置版本。
</details>

<details><summary>3. strategic merge patch 里 containers 列表为什么不会被整表替换？这个行为的依据是什么？</summary>

因为 K8s 的 OpenAPI schema 为 containers 字段声明了 patch merge key（`name`），strategic merge 对带 merge key 的列表按元素深合并而非替换。这也解释了它和 JSON6902 的分工：前者"按名字找到元素合并进去"，后者"按数组下标做纯路径操作"——顺序变化时 JSON6902 会错位，strategic merge 不会。
</details>

<details><summary>4. 同一个 bitnami redis chart，用 helmCharts 渲染部署和用 helm install 部署，一年后的运维差异是什么？</summary>

helm install 的集群里存在 release Secret，升级/回滚/卸载走 `helm upgrade/rollback/uninstall`，hooks 在生命周期节点执行。helmCharts 只是渲染：没有 release 记录，回滚靠 Git revert 再 apply，卸载靠 `kubectl delete -k`，hooks 类资源没有执行者（是否出现在产物里要渲染确认）。GitOps 语境下后者更纯粹——Git 是唯一真相；但你也失去了 helm 的版本管理和 hook 能力，属于有意取舍。
</details>

<details><summary>5. 团队业务应用用 Kustomize 管理，现在要加一个社区 redis chart，有哪几种组织方式？各适合什么情况？</summary>

三种：a) overlay 的 `helmCharts` 声明——chart 与业务同仓库同渲染，环境一致性最好，适合中间件随环境走的场景；b) 独立 Application 指向 chart 仓库——中间件生命周期与业务解耦，升级单独 review，适合平台组件；c) ArgoCD 多源 Application——chart 一个 source、自己的 kustomize 补丁一个 source，免 fork chart 又能打补丁，适合需要对 chart 做少量不可配置修改的场景。共同原则：不要把 chart 内容复制进自己的仓库。
</details>

## 延伸阅读

- Kustomization 字段完整参考：<https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/>
- Kubernetes 官方 Kustomize 教程：<https://kubernetes.io/docs/tasks/manage-kubernetes-objects/kustomization/>
- Helm 官方文档（chart 结构 / values / hooks）：<https://helm.sh/docs/>
- ArgoCD 多源 Application：<https://argo-cd.readthedocs.io/en/stable/user-guide/multiple_sources/>
- devops-advanced-camp 训练营配套仓库（完整的 Helm/Kustomize 多环境实战代码，本模块场景的扩大版）：<https://github.com/devops-advanced-camp/code>
