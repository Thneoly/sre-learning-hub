# 04 · 供应链安全：trivy、digest 固定、cosign 与准入控制全链路

> 模块：CKS 备考 ｜ 建议时长：4 小时 ｜ 关联认证：CKS-Supply Chain Security / Docker-安全实践

## 学习目标

- 能安装 trivy，按严重级别扫描镜像，并用 `--exit-code` 在 CI 里做成质量门禁
- 能解释 tag 可变与 digest 不可变的差别，把工作负载固定到 digest
- 能用 cosign 完成 key pair 生成、镜像签名与验证
- 能部署 ImagePolicyWebhook 的完整配置链（AdmissionConfiguration、kubeconfig、apiserver flags），并理解 ValidatingWebhookConfiguration 的字段语义
- 能写出 distroless/scratch 多阶段构建的最小镜像并掌握其调试方法

## 1. 供应链视角：四个环节四个威胁

```
源码 ──> 构建（CI）──> 镜像仓库 ──> 部署（admission）──> 运行
  │          │             │              │
  └依赖投毒  └构建机被黑   └tag 被覆盖    └任意镜像入库
             └带毒依赖     └无签名校验    └latest 漂移
对应手段: SBOM/锁文件  漏洞扫描      digest 固定      镜像策略准入
         静态分析      构建环境隔离   cosign 签名      ImagePolicyWebhook
```

CKS 考的是后三段：扫描（trivy）、固定（digest）、准入（admission 链）、最小化（distroless/scratch）。

## 2. trivy：扫描与 CI 门禁

### 2.1 安装与基本扫描

```bash
# [任意节点]（Ubuntu 22.04/24.04，官方 apt 仓库）
sudo apt-get install -y wget gnupg
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update && sudo apt-get install -y trivy
trivy --version
```

```bash
# [任意节点] 全量扫描（首次会下载漏洞库，需要外网）
trivy image nginx:1.27

# 只看高危及以上
trivy image --severity HIGH,CRITICAL nginx:1.27

# 过滤"无修复版本"的漏洞，降噪
trivy image --severity CRITICAL --ignore-unfixed nginx:1.27
```

输出按镜像分层列出 CVE：Library/OS 包名、漏洞 ID、 severity、固定版本。扫描的是镜像内的 OS 包与语言依赖（node/python/go modules 等）。

### 2.2 CI 门禁：`--exit-code` 的用法

trivy 默认无论发现多少漏洞都 exit 0；CI 中要把"发现高危"变成流水线失败：

```bash
# [任意节点] 有 CRITICAL 就失败（exit 1 阻断流水线）
trivy image --severity CRITICAL --exit-code 1 --ignore-unfixed nginx:1.27
echo "exit=$?"
```

```yaml
# [CI runner] GitLab CI 片段：阻断带 CRITICAL 的镜像入库
scan:
  stage: test
  script:
    - trivy image --severity CRITICAL --exit-code 1 --ignore-unfixed $CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA
```

其他高频子命令：

```bash
# [任意节点] 扫源码目录/IaC（Dockerfile、K8s manifest 的错误配置）
trivy fs --scanners misconfig,secret /path/to/repo

# [任意节点] 扫运行中的集群（漏扫 + 错误配置，只读）
trivy k8s --report summary all

# [任意节点] 导出 SBOM（软件物料清单）
trivy image --format cyclonedx --output sbom.json nginx:1.27
```

## 3. digest 固定 vs tag

tag（如 `nginx:1.27`）是**可变的指针**：仓库侧可以随时把同一 tag 指向另一个 manifest。攻击场景：构建机被黑后推送同名 tag，或上游把 tag 复用为旧版本。digest 是镜像 manifest 的 sha256 内容哈希，**不可变**，内容变则 digest 变。

```bash
# [任意节点] 获取 digest 的三种方式
docker pull nginx:1.27 > /dev/null
docker images --digests nginx
# 预期: REPOSITORY TAG DIGEST ...，形如 sha256:6af79ae...

docker buildx imagetools inspect nginx:1.27 | grep -i digest
```

在 K8s 里固定：

```yaml
# [master] kubectl apply 后创建（digest 以上一步实际输出为准）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-pinned
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx-pinned
  template:
    metadata:
      labels:
        app: nginx-pinned
    spec:
      containers:
        - name: nginx
          image: nginx@sha256:6af79ae5b40f2e90fa9c4bf9c351842568a607de5b2f2e5b1ff6b335950ab4a4
```

两点注意：

- 多架构镜像的 tag 解析到的是 **manifest list** 的 digest；若节点架构单一，也可固定到平台特定 manifest 的 digest，二者都不可变，前者更通用
- digest 固定后升级＝改 digest，可配合 CI 自动 bump（查新 tag 的 digest → 提 PR），安全性与便利性兼得

## 4. cosign：签名与验证

cosign（sigstore 项目）把签名作为"附带制品"存进镜像仓库：签名写成 `<repo>:sha256-<digest>.sig` 这样的 tag。验证方持公钥即可校验"该 digest 确实被持私钥者签过"。

```bash
# [任意节点] 安装（二选一；需要 go 环境用第一条）
go install github.com/sigstore/cosign/v2/cmd/cosign@latest
# 或从 https://github.com/sigstore/cosign/releases 下载对应架构 tar.gz 解压到 /usr/local/bin
cosign version
```

练习用本地 registry 避免污染公共仓库：

```bash
# [任意节点]（装有 Docker 的 Ubuntu VM）起本地仓库
docker run -d -p 5000:5000 --name registry registry:2

# 本地 http registry 需让 docker 信任（写入后重启 docker）
sudo tee /etc/docker/daemon.json > /dev/null <<'EOF'
{ "insecure-registries": ["127.0.0.1:5000"] }
EOF
sudo systemctl restart docker && docker start registry

docker pull nginx:1.27
docker tag nginx:1.27 127.0.0.1:5000/nginx:1.27
docker push 127.0.0.1:5000/nginx:1.27
```

生成 key pair（私钥口令走环境变量，免交互）并签名/验证：

```bash
# [任意节点]
export COSIGN_PASSWORD='PracticePass123!'
cosign generate-key-pair
# 生成 cosign.pem 私钥与 cosign.pub 公钥

cosign sign --key cosign.key 127.0.0.1:5000/nginx:1.27
# 签名被写成 127.0.0.1:5000/nginx:sha256-<digest>.sig

cosign verify --key cosign.pub 127.0.0.1:5000/nginx:1.27
# 预期: 输出 Verified OK 及签名/证书内容

# tag 被换内容后验证应失败：push 一个不同内容同 tag 的镜像再 verify 即可观察
```

说明：

- 生产推荐 **keyless** 模式（OIDC 身份签名，证书与签名记录进 Rekor 公共审计日志），CI 里最常用；key pair 模式适合离线/内网环境
- "签名验证发生在部署时"需要集群侧配合：sigstore policy-controller、Kyverno 或 OPA Gatekeeper 做准入校验；Kubernetes 内置的 ImagePolicyWebhook 只负责把 ImageReview 转发给后端策略服务（见下节）

## 5. 准入控制全链路

### 5.1 两条路线

| 路线 | 机制 | 特点 |
| --- | --- | --- |
| 动态准入 | ValidatingWebhookConfiguration → 你部署的 HTTPS webhook | 通用：可校验任意字段（镜像来源、签名、标签），规则写在你自己的服务里 |
| 内置插件 | ImagePolicyWebhook → 后端策略服务（收发 ImageReview 对象） | 镜像专用：apiserver 以 ImageReview 格式问后端"这个镜像能不能跑" |

### 5.2 ImagePolicyWebhook 完整配置链（CKS 高频）

**Step 1：给后端连接准备的 kubeconfig。** apiserver 与 webhook 后端间走 TLS，后端地址与客户端证书写在 kubeconfig 里：

```yaml
# [master] /etc/kubernetes/admission/webhook-kubeconfig.yaml
clusters:
  - name: imagepolicy-backend
    cluster:
      certificate-authority: /etc/kubernetes/admission/ca.pem   # 校验后端 serving 证书的 CA
      server: https://imagepolicy-backend.example:8443/policy  # 后端必须 https
users:
  - name: kube-apiserver
    user:
      client-certificate: /etc/kubernetes/admission/client.pem # apiserver 出示的客户端证书
      client-key: /etc/kubernetes/admission/client-key.pem
```

**Step 2：AdmissionConfiguration（插件配置）。** `path:` 方式引用独立文件，或直接内嵌 `configuration:`（这里用官方文档的嵌入格式）：

```yaml
# [master] /etc/kubernetes/admission/admission-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: ImagePolicyWebhook
    configuration:
      imagePolicy:
        kubeConfigFile: /etc/kubernetes/admission/webhook-kubeconfig.yaml
        allowTTL: 50        # 允许决定的缓存秒数
        denyTTL: 50         # 拒绝决定的缓存秒数
        retryBackoff: 500   # 重试间隔毫秒
        defaultAllow: false # 后端不可达时的兜底行为：false=全部拒绝（Fail closed）
```

**Step 3：apiserver 开启插件并挂载文件。** 编辑 `/etc/kubernetes/manifests/kube-apiserver.yaml`：

```yaml
# [master] command 段追加
    - --enable-admission-plugins=NodeRestriction,ImagePolicyWebhook
    - --admission-control-config-file=/etc/kubernetes/admission/admission-config.yaml
    - --runtime-config=imagepolicy.k8s.io/v1alpha1=true
```

```yaml
# [master] 同文件 volumeMounts 段追加
      - mountPath: /etc/kubernetes/admission/
        name: admission-config
        readOnly: true
```

```yaml
# [master] 同文件 volumes 段追加
    - name: admission-config
      hostPath:
        path: /etc/kubernetes/admission/
        type: DirectoryOrCreate
```

**Step 4：验证与理解失败模式。** 后端没部署时（当前 defaultAllow=false），任何 Pod 创建都会被拒：

```bash
# [master]
kubectl run test --image=nginx:1.27 --restart=Never
# 预期: Error from server (Forbidden): ... admission webhook "imagepolicywebhook.image-policy.k8s.io" denied the request
```

这正是"fail closed"的含义：策略服务挂了宁可拒绝业务也不放行未评估的镜像。若业务可用性优先，把 `defaultAllow` 设为 true（fail open），但等于留了后门。后端策略服务（任何实现 ImageReview 收发的 HTTPS 服务，例如对接 trivy/cosign 的自研策略服务）部署后，`allowed: true/false` 的判定会按 allowTTL/denyTTL 缓存。

### 5.3 ValidatingWebhookConfiguration 字段语义

与 ImagePolicyWebhook 的"内置插件+静态文件"不同，这是 API 对象，动态创建：

```yaml
# [master] kubectl apply -f（caBundle 填你 webhook serving 证书的 CA，base64 单行）
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: image-policy
webhooks:
  - name: image-policy.example.com
    admissionReviewVersions: ["v1"]      # 协商 AdmissionReview 版本
    sideEffects: None                    # 声明无副作用（无副作用时可被 dry-run 调用）
    failurePolicy: Fail                  # webhook 不可达时：Fail=拒绝请求，Ignore=放行
    timeoutSeconds: 5                    # 超时上限（1-30s）
    clientConfig:
      service:
        name: image-policy-svc
        namespace: admission
        path: /validate
      caBundle: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUM...
    rules:
      - operations: ["CREATE", "UPDATE"]
        apiGroups: [""]
        apiVersions: ["v1"]
        resources: ["pods"]
    namespaceSelector:                   # 只在打了此 label 的 namespace 生效
      matchLabels:
        image-policy: enforced
```

```bash
# [master] 生成 caBundle 的办法
cat ca.crt | base64 -w 0
```

排障入口：`kubectl get validatingwebhookconfigurations image-policy -o yaml`、apiserver 日志里搜 webhook 名。若把集群"锁死"在 webhook 上（删不掉任何对象），先用 `kubectl patch validatingwebhookconfigurations image-policy -p '{"webhooks":[{"name":"image-policy.example.com","failurePolicy":"Ignore"}]}'` 降级再排障。

## 6. distroless 与 scratch：最小化基础镜像

基础镜像里每多一个 shell、包管理器、工具集，就多一批 CVE 与攻击工具。三级最小化：

| 方案 | 内容 | 典型体积 | 有 shell? | 有包管理器? |
| --- | --- | --- | --- | --- |
| `ubuntu:24.04` / `debian:12` | 完整发行版 | ~30-80MB | 有 | apt |
| `alpine:3.20` | busybox + musl | ~5MB | busybox sh | apk |
| `gcr.io/distroless/static-debian12` | 仅运行时静态二进制的支撑文件 | ~2MB | 无 | 无 |
| `scratch` | 空白（只有你 COPY 进去的东西） | 0（不占基础层） | 无 | 无 |

多阶段构建＋distroless（Go 静态程序的标准姿势，`:nonroot` 变体自带非 root 用户）：

```dockerfile
# [任意节点]（装有 Docker 的 Ubuntu VM）Dockerfile.distroless
FROM golang:1.23 AS build
WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /app main.go

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /app /app
USER nonroot:nonroot
ENTRYPOINT ["/app"]
```

```go
// [任意节点] 配套 main.go（构建最小可验证制品）
package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "hello from distroless\n")
	})
	fmt.Println("listening on :8080")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		os.Exit(1)
	}
}
```

```bash
# [任意节点]
docker build -t 127.0.0.1:5000/hello:distroless -f Dockerfile.distroless .
docker run --rm 127.0.0.1:5000/hello:distroless & sleep 2; curl -s localhost:8080; kill %1
```

scratch 变体（把 FROM 行换成 `FROM scratch` 即可，其余不变）连 distroless 的支撑文件都省掉，只适合完全静态的二进制。

**distroless 没有(shell|ls|cat)，怎么调试？** 用临时容器（ephemeral container）挂上去看：

```bash
# [master] 部署进集群后（镜像先 push 到可达 registry）
kubectl run hello --image=127.0.0.1:5000/hello:distroless --restart=Never
kubectl wait --for=condition=ready pod/hello --timeout=120s
kubectl debug -it hello --image=busybox:1.36 --target=hello
# 在调试容器里: ps aux（看到的是共享进程命名空间里的 app 进程）、ls /app
```

Java/Node 等运行时语言用对应 distroless 变体（`gcr.io/distroless/java21-debian12`、`gcr.io/distroless/nodejs22-debian12`）；需要 ca-certificates、tzdata 的场景选 distroless 而不是 scratch。

## 实战演练：扫描—固定—签名—准入四连

环境：kubeadm 集群（master）＋ 一台带 Docker 的 Ubuntu VM（做镜像侧操作）。

```bash
# [任意节点] 1. 扫描两个候选基础镜像，选 CRITICAL 少的
trivy image --severity CRITICAL --exit-code 0 nginx:1.27
trivy image --severity CRITICAL --ignore-unfixed --exit-code 0 nginx:1.27-alpine

# [任意节点] 2. 取 digest 并生成 pinned 部署清单（nginx@sha256:...），apply 到集群

# [任意节点] 3. 本地 registry + cosign 签名（见第 4 节命令），verify 通过

# [master] 4. 按 5.2 配置 ImagePolicyWebhook 链，先不部署后端，验证 fail-closed 拦截
kubectl run probe --image=nginx:1.27 --restart=Never 2>&1 | head -2
# 预期: Forbidden ... imagepolicywebhook 拒绝

# [master] 5. 实验完关闭插件回滚（删除 command 里三个 flag 与挂载，或恢复备份 manifest）
```

回滚务必执行：`defaultAllow=false` 且无后端时集群将无法创建任何新 Pod。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| trivy 首次扫描卡在下载漏洞库 | 环境无外网 | 提前在有网环境 `trivy image` 预热缓存（~/.cache/trivy），或用 `--skip-db-update`＋离线库 |
| CI 里 `--exit-code 1` 把流水线全打红 | 未过滤 unfixed，历史镜像无修复版本的一起算 | 加 `--ignore-unfixed`；配 `.trivyignore` 列例外 CVE |
| cosign verify 报 "no signatures found" / TLS 错误 | 用 tag 签名但后 push 覆盖了 tag；本地 http registry 未被信任 | 固定用 `image@sha256:` 签名；daemon.json 配 insecure-registries 后重启 docker |
| ImagePolicyWebhook 配置后 apiserver 起不来 | admission-config.yaml 路径/缩进错，或 kubeconfig 缺 CA 文件 | 恢复备份 manifest；`crictl logs` 看 kube-apiserver 报错行；文件路径必须与 volumeMount 一致 |
| 配了 webhook 后全集群创建不了 Pod | fail-closed（defaultAllow=false）且后端不可达 | 部署后端，或临时 defaultAllow=true；实验后立即回滚插件 |
| distroless 镜像 Pod CrashLoop 且无从排查 | 无 shell，`kubectl exec` 报容器内无 sh | `kubectl debug` 临时容器进共享进程命名空间；构建前用普通镜像自测 |
| 固定 digest 后 imagePullBackOff | digest 抄错一位，或跨架构不匹配 | `docker buildx imagetools inspect` 复制完整 sha256；多架构集群固定 manifest list digest |

## 自测

1. 为什么"用 digest 固定镜像"防不住"构建阶段引入的漏洞"？它和 trivy、cosign 分别覆盖供应链哪一段？

<details><summary>答案</summary>

digest 保证的是"部署的内容＝你验证过的内容"（防仓库侧替换/漂移），不改变内容本身是否有毒。构建阶段引入漏洞要靠 trivy 扫描（发现）＋SBOM/依赖锁（溯源）阻断；"确认发布者身份"靠 cosign 签名验证。三者互补：扫得干净、签得可信、部署不漂移。
</details>

2. `--exit-code 1 --severity CRITICAL --ignore-unfixed` 各自解决什么问题？去掉 `--ignore-unfixed` 会发生什么？

<details><summary>答案</summary>

`--exit-code 1` 把"发现匹配漏洞"变成非零退出码，CI 才会失败；`--severity` 划定门禁红线；`--ignore-unfixed` 排除官方尚无修复版本的 CVE，避免"修不了也得修"的死锁。去掉后者后，历史基础镜像里大量无修复 CVE 会把门禁变成永远红灯，团队最终会学会绕过门禁。
</details>

3. ImagePolicyWebhook 的 `defaultAllow: false` 在安全上为什么重要？它的代价是什么？

<details><summary>答案</summary>

它是 fail-closed 语义：策略后端故障时拒绝未评估的镜像，攻击者不能靠"把 webhook 打挂"来放行恶意镜像。代价是可用性——后端故障期间所有新 Pod 无法创建，所以后端要高可用，且 allowTTL/denyTTL 缓存要能扛短暂抖动。
</details>

4. ValidatingWebhookConfiguration 里 `failurePolicy: Fail` 与 `namespaceSelector` 怎么组合才能既安全又不把集群锁死？

<details><summary>答案</summary>

核心系统 namespace（kube-system 等）用 namespaceSelector 排除在 webhook 之外（不打 image-policy label），业务 namespace 打 label 且 failurePolicy=Fail。这样 webhook 故障只影响业务命名空间的新建操作，控制面与 CNI 等组件不受牵连。
</details>

5. `scratch` 与 `distroless/static` 都是"无 shell"，什么情况下必须选 distroless？

<details><summary>答案</summary>

程序需要 ca-certificates（发 HTTPS 请求）、tzdata（时区）或非 root 用户定义时，distroless 已内置这些支撑文件；scratch 需要自己 COPY 且极易漏。另外动态链接程序两个都不行，必须 CGO_ENABLED=0 静态编译或换带 libc 的 distroless 变体。
</details>

## 延伸阅读

- trivy 官方文档（安装/CLI/CI 集成）：<https://trivy.dev/latest/>
- cosign 官方仓库：<https://github.com/sigstore/cosign>
- sigstore 官方文档（cosign 密钥/签名/验证）：<https://docs.sigstore.dev/>
- ImagePolicyWebhook 与 ImageReview API：<https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#imagepolicywebhook>
- 动态准入控制：<https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/>
- distroless 官方仓库：<https://github.com/GoogleContainerTools/distroless>
- Verify Signed Kubernetes Artifacts：<https://kubernetes.io/docs/tasks/administer-cluster/verify-signed-artifacts/>
