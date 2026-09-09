# Lab 08 · 解答：Helm chart 全生命周期

> 配套 task.md 使用。环境：candidate VM（即练习集群 master，kubectl、helm、docker 可用）。本 lab 是第 08 章实战演练的可判分版：步骤同构，但命名、终态与证据路径都固定下来供 check.sh 核查；第 08 章踩过的坑（出厂 `resources: {}` 重复键、nindent 缩进）在这里直接继承处理。

## 第 1 步：前置——本地 registry 就位

```bash
# [VM] 复用 03-docker/labs/08 的 registry；不在了就按该 lab 的方式重启
docker ps --filter name=lab08-registry --format '{{.Names}}'
# 若输出为空：
docker volume create lab08-data
docker run -d --name lab08-registry --restart always \
  -p 5000:5000 -v lab08-data:/var/lib/registry registry:2
curl -s http://localhost:5000/v2/    # 预期：{}
helm version --short                 # 预期：v3.8+（OCI 功能需要）
```

为什么复用它而不是新起一个：registry 数据在 volume `lab08-data` 里持久化，03-docker/labs/08 已经推过 `lab/nginx`；同一个仓库既存镜像又存 chart（OCI artifact），正是"内部制品库"的最小形态（生产形态见第 09 章 Harbor）。

## 第 2 步：helm create 与出厂改造

```bash
# [VM]
mkdir -p ~/labs/helm-chart && cd ~/labs/helm-chart
helm create demo-app
find demo-app -type f | sort
```

按第 08 章实战步骤 3 改造。先处理重复键坑——出厂 `values.yaml` 自带 `resources: {}`，直接追加第二个 `resources:` 顶层键会报 `mapping key ... already defined`，必须先删再追加：

```bash
# [VM] 出厂 values.yaml 除 resources: {} 外，还自带 livenessProbe/readinessProbe 默认块——
#      不删的话工厂模板的 with 块照样渲染，probes.enabled=false 时探针不会消失，且渲染产物出现重复键
sed -i '/^resources: {}/d' demo-app/values.yaml
sed -i '/^livenessProbe:/,+7d' demo-app/values.yaml
cat >> demo-app/values.yaml <<'EOF'
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
```

在 `demo-app/templates/deployment.yaml` 的容器段（`imagePullPolicy` 之后、`resources:` 之前，同级缩进）插入条件探针块：

```yaml
# 文件: ~/labs/helm-chart/demo-app/templates/deployment.yaml 容器段插入
          {{- if .Values.probes.enabled }}
          livenessProbe:
            httpGet:
              path: {{ .Values.probes.path | quote }}
              port: http
          readinessProbe:
            httpGet:
              path: {{ .Values.probes.path | quote }}
              port: http
          {{- end }}
```

`port: http` 引用出厂模板给容器端口起的名字；探针路径用 `| quote` 包成字符串。改模板必 `helm template` 肉眼过缩进（第 08 章 nindent 一节的第一杀手警告）。

## 第 3 步：lint 与渲染验证

```bash
# [VM]
helm lint demo-app
# 预期：1 chart(s) linted, 0 chart(s) failed
helm template demo demo-app | grep -B1 -A4 'livenessProbe'
helm template demo demo-app | grep -A4 'resources:'
# 预期：requests(cpu 50m/memory 64Mi) 与 limits(128Mi) 以正确嵌套缩进出现在 resources: 下
helm template demo demo-app --set probes.enabled=false | grep -c livenessProbe
# 预期：0（参数化开关生效）
```

## 第 4 步：安装并观察 release Secret（revision 1）

```bash
# [VM]
cd ~/labs/helm-chart
helm package demo-app                    # 产出 demo-app-0.1.0.tgz（出厂 version 0.1.0）
helm upgrade --install demo-app demo-app-0.1.0.tgz \
  -n helm-lab08 --create-namespace --wait
# 预期：STATUS: deployed，REVISION: 1
kubectl -n helm-lab08 get secret | grep sh.helm
# 预期：sh.helm.release.v1.demo-app.v1 —— 第 08 章第 5 节讲的 release 元数据
kubectl -n helm-lab08 get secret sh.helm.release.v1.demo-app.v1 \
  --show-labels -o name
# 预期 labels：name=demo-app  owner=helm  status=deployed  version=1
kubectl -n helm-lab08 get deploy,pod
# 预期：deployment/demo-app 1/1（release 名与 chart 名一致时，fullname 模板直接用 release 名）
```

release Secret 就是回滚的数据来源：整个 release（chart + values + 渲染产物）gzip + base64 后存在目标命名空间里，每次升级追加一个 `vN`。

## 第 5 步：正常升级 replicaCount 1→2（revision 2）

```bash
# [VM]
sed -i 's/^replicaCount: 1/replicaCount: 2/' demo-app/values.yaml
helm upgrade demo-app demo-app -n helm-lab08 --wait
helm history demo-app -n helm-lab08
# 预期：rev1 deployed / rev2 deployed
kubectl -n helm-lab08 get deploy demo-app    # 预期：2/2
```

## 第 6 步：坏升级——没有 --wait 的假成功（revision 3）

```bash
# [VM] 镜像 tag 不存在，且不带任何保底参数
helm upgrade demo-app demo-app -n helm-lab08 --set image.tag=this-tag-does-not-exist
# 命令正常返回，甚至打印 deployed —— 但它只保证"apply 完成"
kubectl -n helm-lab08 get pods
# 预期：新 Pod ErrImagePull / ImagePullBackOff，READY 0/1
helm history demo-app -n helm-lab08
# 预期：rev3 仍标 deployed —— "成功"与"健康"是两回事（第 08 章自测第 3 题）
kubectl -n helm-lab08 describe pod -l app.kubernetes.io/instance=demo-app | grep -A2 Events | tail
# Events 里能看到 pull 访问 docker.io 的失败记录
```

## 第 7 步：手动 rollback（revision 4）

```bash
# [VM]
helm rollback demo-app 2 -n helm-lab08
kubectl -n helm-lab08 get pods           # 预期：全部 Running，2/2
helm history demo-app -n helm-lab08
# 预期：rev4 类型为 Rollback，状态 deployed；revision 只增不减
```

## 第 8 步：--atomic 自动回退（revision 5/6）

```bash
# [VM] 同样的坏值，这次带保底；非零退出码是预期行为
helm upgrade demo-app demo-app -n helm-lab08 \
  --set image.tag=this-tag-does-not-exist --atomic --timeout 2m \
  || echo "预期失败：--atomic 已自动回退，exit code=$?"
helm history demo-app -n helm-lab08
# 预期：末尾多出一条 failed（pending 升级超时）与一条自动回滚后的 deployed
kubectl -n helm-lab08 get deploy demo-app    # 预期：仍是健康版本 2/2
```

`--atomic` 隐含 `--wait`：等到 Deployment available 或超时，失败即自动 rollback——把第 7 步的"人发现、人回滚"窗口压缩到零。

## 第 9 步：发布到 OCI registry 并拉回验证

```bash
# [VM]
sed -i 's/^version: 0.1.0/version: 0.2.0/' demo-app/Chart.yaml
helm package demo-app                          # 产出 demo-app-0.2.0.tgz
helm push demo-app-0.2.0.tgz oci://localhost:5000/charts --plain-http
# 预期：Pushed: localhost:5000/charts/demo-app:0.2.0（Digest: sha256:...）
curl -s http://localhost:5000/v2/_catalog
# 预期：{"repositories":["lab/nginx","charts/demo-app"]}（若做过 03-docker lab 08）
curl -s http://localhost:5000/v2/charts/demo-app/tags/list
# 预期：{"name":"charts/demo-app","tags":["0.2.0"]}

helm show chart oci://localhost:5000/charts/demo-app --version 0.2.0 --plain-http
# 预期：打印 name/demo-app、version 0.2.0 等元数据——装前先看，供应链习惯
mkdir -p pulled && helm pull oci://localhost:5000/charts/demo-app \
  --version 0.2.0 --destination pulled --plain-http
tar -xOzf pulled/demo-app-0.2.0.tgz demo-app/Chart.yaml | grep -E 'name:|version:'
# 预期：name: demo-app / version: 0.2.0 —— push/pull 闭环完好
```

localhost 免证书但仍需 `--plain-http` 的原因见 task.md 提示 3；换成对外 IP 需配 insecure 或上证书，生产用 Harbor（第 09 章）。

## 收尾（判分之后）

```bash
# [VM] check.sh 通过后再清理
helm uninstall demo-app -n helm-lab08
kubectl delete ns helm-lab08 --ignore-not-found
# lab08-registry 建议保留（数据在 volume 里），确要删除：
# docker rm -f lab08-registry && docker volume rm lab08-data
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 追加 values 后报 `mapping key "resources" already defined` | 出厂 values.yaml 已有 `resources: {}`，同顶层键出现两次（第 08 章实战踩过） | 先 `sed -i '/^resources: {}/d'` 再追加（第 2 步） |
| 渲染产物 `resources: limits:...` 挤在一行或 YAML 解析错误 | `toYaml` 后用 `indent` 而非 `nindent`，或缩进数字错 | 改 `\| nindent N`；改完必 `helm template` 核对 |
| 坏升级后 `helm upgrade` 报 `has no deployed releases` | 前一次失败 revision 留在 history | 先 `helm rollback demo-app <最近的 deployed 序号>` 再升（本 lab 第 7/8 步正是这个动作） |
| `--atomic` 一步等了 5 分钟才返回 | 默认 timeout 5m | 显式 `--timeout 2m` 控制演练节奏 |
| `helm push` 报 `unauthorized` 或连接拒绝 | registry 没起 / 端口写错 / 用了非 localhost 地址 | 回到第 1 步；非 localhost 需配 insecure/TLS |
| `helm push/pull/show` 报 `blob upload Location ... downgrades scheme from https` | 明文 HTTP registry 未加 `--plain-http`（新 helm 不再对 localhost 自动降级 http） | push/show/pull 命令末尾加 `--plain-http`（`helm upgrade --install oci://...` 同理） |
| `--set probes.enabled=false` 后渲染产物仍有 livenessProbe | 出厂 values.yaml 自带 livenessProbe/readinessProbe 默认块，工厂模板 `with` 块照样渲染 | 第 2 步的 `sed -i '/^livenessProbe:/,+7d'` 一并删掉出厂探针块 |
| Deployment 名不是 `demo-app-demo-app` | fullname 模板：release 名包含 chart 名时直接用 release 名 | 正常现象，`demo-app` 就是fullname（第 4 步注释） |
| `helm pull` 拉不到 | 忘了 `--version 0.2.0` 或 registry 中 tag 不符 | 先 `curl tags/list` 核对再拉 |

## 判分脚本结果

```text
# [VM]
$ ./check.sh
PASS: 存在 sh.helm.release.v1.demo-app.v* 命名的 Secret
PASS: release revision 数 >= 4
PASS: 存在 status=deployed 的 release Secret
PASS: Deployment demo-app 处于 Available
PASS: Deployment demo-app 期望副本数为 2
PASS: Deployment demo-app 就绪副本数为 2
PASS: 容器配置了 livenessProbe
PASS: resources.requests.memory 为 64Mi
PASS: 当前镜像不含坏 tag
PASS: registry catalog 含 charts/demo-app
PASS: chart 0.2.0 tag 已在 registry
PASS: helm pull 回来的 demo-app-0.2.0.tgz 存在

SCORE: 12/12
```

## 延伸阅读

- Helm 官方文档（chart 开发 / release 管理）：<https://helm.sh/docs/>
- OCI registry 用法（push/show/pull）：<https://helm.sh/docs/topics/registries/>
- helm-diff 插件（升级前的最后一道 review）：<https://github.com/databus23/helm-diff>
- Docker Registry HTTP API v2（catalog/tags 接口）：<https://distribution.github.io/distribution/spec/api/>
