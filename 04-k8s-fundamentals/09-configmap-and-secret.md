# 09 · ConfigMap 与 Secret：注入方式、原子更新与"base64 不是加密"

> 模块：04-k8s-fundamentals ｜ 建议时长：3 小时 ｜ 关联认证：CKA-配置管理 / CKS-Secret 安全实践

## 学习目标

- 能操作 ConfigMap/Secret 的三种注入方式（env / envFrom / volume + subPath），并说清每种方式的更新行为
- 能解释卷挂载的 tmpfs + symlink 原子更新机制：为什么 ConfigMap 改了、Pod 里的文件会"慢慢变"，而 subPath 永远不变
- 能解释 Secret 只是 base64 编码而非加密，并在 etcd 层面亲手验证
- 能操作 immutable ConfigMap/Secret 及配置更新后的 `kubectl rollout restart`
- 能排查 CreateContainerConfigError、"改了配置不生效"两类故障

## 1. 为什么配置要和镜像分离

同一个 `app:1.4` 镜像要跑过 dev/staging/prod 三套环境，唯一的变量是配置。把配置打进镜像会导致：每个环境一个镜像（违反"一次构建，到处部署"）、改一行配置要重新走 CI（分钟级变小时级）、数据库口令被烧进镜像层（永远删不掉）。K8s 的解法是两个 API 对象：ConfigMap 存非敏感配置，Secret 存敏感数据，由 kubelet 在容器启动时注入。

两者本质几乎相同（key-value 集合），差别在语义与处理路径：Secret 的 value 走 base64、默认挂 tmpfs 不落盘、通常配合 RBAC 单独管控。它们都受 etcd 单对象约 1MiB 的限制。

## 2. 三种注入方式与各自的更新行为

先创建一个实验用的 ConfigMap：

```bash
# [master] 用字面量创建
kubectl create configmap demo-cm \
  --from-literal=APP_MODE=debug \
  --from-literal=app.conf='mode=debug
loglevel=info'
kubectl get configmap demo-cm -o yaml
```

### 2.1 env：单个 key 注入环境变量

```yaml
# [master] 保存为 inject-demo.yaml
apiVersion: v1
kind: Pod
metadata:
  name: cm-inject
spec:
  containers:
  - name: main
    image: busybox:1.36
    command: ["sh", "-c", "env | grep -E 'APP_MODE|MODE_ENV'; echo ---; cat /etc/conf/app.conf; echo ---; cat /mnt/single/app.conf; sleep 3600"]
    env:
    - name: MODE_ENV                 # 容器内的变量名，可以和 key 不同名
      valueFrom:
        configMapKeyRef:
          name: demo-cm
          key: APP_MODE
    envFrom:
    - configMapRef:
        name: demo-cm                # 整个 ConfigMap 展开成环境变量
      prefix: CM_                    # 可选：变量名统一加前缀，避免冲突
    volumeMounts:
    - name: conf
      mountPath: /etc/conf           # 整卷挂载：目录下的每个 key 一个文件
    - name: conf
      mountPath: /mnt/single/app.conf
      subPath: app.conf              # subPath：只挂卷里的一个文件
  volumes:
  - name: conf
    configMap:
      name: demo-cm
      defaultMode: 0644
```

```bash
# [master] 三种方式一次看全
kubectl apply -f inject-demo.yaml
kubectl logs cm-inject | head -8
# 预期输出：
#   CM_APP_MODE=debug            ← envFrom（带前缀）
#   MODE_ENV=debug               ← env 单 key
#   ---
#   mode=debug
#   loglevel=info                ← volume 整挂
#   ---
#   mode=debug
#   loglevel=info                ← subPath 单文件
```

### 2.2 更新行为对照表（本章核心，必须背下来）

| 注入方式 | ConfigMap 更新后，容器内 | 原因 |
| --- | --- | --- |
| env（valueFrom） | **永远不变** | 环境变量在容器进程启动时注入，进程环境随后不可变 |
| envFrom | **永远不变** | 同上 |
| volume 整卷挂载 | **约 1 分钟内变成新内容** | kubelet 周期同步 + symlink 原子替换（见第 3 节） |
| volume + subPath | **永远不变** | bind mount 在创建时解析一次目标，之后不参与热更新 |

### 2.3 引用不存在的对象会怎样

引用的 ConfigMap/Secret 或 key 不存在时，Pod 卡在 `CreateContainerConfigError` 状态，事件里能看到 `configmap "xxx" not found` 或 `secret "xxx" not found`。卷方式可以把 `configMap` 下的 `optional: true` 设为允许缺失；env 方式同样支持 `configMapKeyRef.optional`。排障命令：`kubectl describe pod <p> | grep -A3 Events`。

### 2.4 写 ConfigMap 时的 YAML 陷阱

配置文件是 YAML 的重灾区，四类错误占了实际事故的大头：

| 陷阱 | 现象 | 解法 |
| --- | --- | --- |
| 挪威问题（Norway Problem） | `value: NO` 被解析为布尔 `false`（`no/yes/on/off/true/false` 及大小写变体同理） | 字符串一律加引号：`value: "NO"` |
| 保留字作 key | ConfigMap 里 `on: "yes"`、`True: "1"` 这类 key 触发解析歧义或报错 | key 避开 y/N/true/on 等保留字 |
| 数字被转类型 | `value: 1.10` 变成浮点 `1.1`，版本号悄悄丢零 | 引号包住：`value: "1.10"` |
| 多行内容用错标量 | `>` 折叠换行、`|` 保留换行，配置文件常被折成一行 | 挂载为文件的配置用 `|`（或 `|-` 去掉末尾换行） |

```yaml
# [文件 multi-line-demo.yaml] 多行块标量对照（| 保留换行，是挂配置文件的正解）
apiVersion: v1
kind: ConfigMap
metadata:
  name: multiline-demo
data:
  nginx.conf: |
    server {
      listen 80;
    }
  summary: >
    折叠成一行
    的说明文字
```

```bash
# [master] 验证
kubectl apply -f multi-line-demo.yaml
kubectl get cm multiline-demo -o jsonpath='{.data.nginx\.conf}'
# 预期：三行原样保留（含换行）；summary 则是折成一行的句子
```

## 3. 卷挂载的 tmpfs + symlink 原子更新机制

### 3.1 挂载点里到底有什么

ConfigMap 卷在节点上是 tmpfs（内存盘），kubelet 用一个"版本目录 + 软链"的结构实现原子更新：

```
# [图] /etc/conf 的真实结构（ls -la 可见）
/etc/conf/                                   ← Pod 内挂载点（tmpfs）
├── ..2026_08-22_10-00-05.123456789/        ← 版本目录：一次同步的完整快照
│   ├── APP_MODE
│   └── app.conf
├── ..data -> ..2026-08-22_10-00-05.123456789   ← 指向"当前版本"的软链
├── APP_MODE -> ..data/APP_MODE              ← 每个文件都是软链
└── app.conf  -> ..data/app.conf
```

```bash
# [master] 亲手看一眼
kubectl exec cm-inject -- ls -la /etc/conf
```

### 3.2 更新的两个环节

```
# [图] ConfigMap 修改后发生的事
kubectl edit configmap demo-cm
   │
   │ 环节 1（延迟来源）：kubelet 对挂载的 ConfigMap 做周期性同步
   │                  （默认约 1 分钟一轮；支持 watch 加速，仍非即时）
   ▼
kubelet 发现内容变化：
   a. 新建 ..<新时间戳>/ 目录，写入全部新文件        ← 旧文件原封不动
   b. 用 rename 系统调用原子地把 ..data 指向新目录     ← 一步切换，无中间态
   c. 延迟删除旧版本目录
   ▼
进程视角：
   - 每次 open("/etc/conf/app.conf") 都会解析软链 → 读到新内容
   - 但"已经打开的文件描述符（fd）"仍指向旧 inode → 读到旧内容
```

现在能精确回答"为什么 ConfigMap 改了，Pod 里的文件会慢慢变"：

| 现象 | 机制 |
| --- | --- |
| 不是立即变 | kubelet 同步是周期性的，典型延迟几十秒到一分钟 |
| 不是所有进程同时变 | 每个进程在**下一次 open 时**才看到新内容；持有旧 fd 的长连接进程继续读旧文件 |
| 不会出现"半个文件" | 新内容整目录写入 + 软链一步切换（原子），绝不会读到写了一半的文件 |

### 3.3 subPath 为什么不更新（高频坑，讲透）

subPath 挂载的原理：kubelet 不是把卷挂到 `/mnt/single/app.conf`，而是把**卷内子路径** `app.conf`（此时解析软链得到真实文件）以 **bind mount** 的形式挂进容器。bind mount 建立的瞬间，源和目标的绑定关系就固定了——之后 kubelet 的热更新只替换卷根部的 `..data` 软链，而 bind mount 指向的是旧版本目录里的那个具体文件，两者从此再无关系。

```bash
# [master] 验证：改掉 ConfigMap，等 90 秒，对比两种挂载
kubectl patch configmap demo-cm --type merge \
  -p '{"data":{"APP_MODE":"prod","app.conf":"mode=prod\nloglevel=warn\n"}}'
sleep 90
kubectl exec cm-inject -- sh -c 'cat /etc/conf/app.conf; echo ---; cat /mnt/single/app.conf; env | grep MODE'
# 预期输出：
#   mode=prod          ← 整卷挂载：已更新
#   loglevel=warn
#   ---
#   mode=debug         ← subPath：仍是旧内容，且永远不会变
#   loglevel=info
#   MODE_ENV=debug     ← env：仍是旧值，永远不会变
```

这就是"Nginx 用 subPath 挂 nginx.conf，改了 ConfigMap、reload 也没用"的根因。结论与选型：

- 需要热更新 + 应用支持自动 reload：整卷挂目录，别用 subPath
- 用了 subPath 或 env：改配置后必须 `kubectl rollout restart`
- 应用靠 inotify watch 文件变更的要小心：软链切换方式对多数 inotify watch 不友好（watch 的是旧 inode 的路径事件），常见做法是 watch `..data` 这个软链本身，或干脆轮询

### 3.4 immutable：不可变配置的性能红利

```yaml
# [master] 保存为 immutable-cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: immutable-cm
immutable: true
data:
  app.conf: |
    mode=prod
    loglevel=warn
```

标记 immutable 后该对象不可更新（只能删除重建），换来两层收益：kube-apiserver 不再为它维护变更传播（watch 缓存开销显著下降），kubelet 也不再对挂载它的卷做周期同步——两者相乘，在"大量 ConfigMap/Secret 挂载很多 Pod"的集群里开销下降非常可观。代价是更新 = 删 + 建（名字相同即可原地替换引用，但挂载它的 Pod 需要重启才能拿到新版本）。证书类、不常变的配置建议默认 immutable。

## 4. Secret：类型、stringData 与"base64 不是加密"

### 4.1 内置类型

```bash
# [master] 最常用的三种
kubectl create secret generic db-cred \
  --from-literal=username=admin --from-literal=password='S3cr3t!'
kubectl create secret tls my-tls --cert=tls.crt --key=tls.key
kubectl create secret docker-registry reg-cred \
  --docker-server=registry.example.com --docker-username=puller \
  --docker-password='hunter2' --docker-email=ops@example.com
```

| type | 用途 | 关键字段 |
| --- | --- | --- |
| Opaque | 通用敏感数据（默认） | 任意 key |
| kubernetes.io/tls | Ingress/Server TLS | tls.crt、tls.key |
| kubernetes.io/dockerconfigjson | 拉私有镜像 | .dockerconfigjson |
| kubernetes.io/basic-auth / ssh-auth | 口令/私钥 | username/password 或 ssh-privatekey |
| kubernetes.io/service-account-token | SA 令牌 | 由控制器管理 |

### 4.2 data 与 stringData

`data` 里必须是 base64；`stringData` 是只写便捷字段——提交明文，apiserver 自动编码进 `data`，读回时只显示 `data`：

```yaml
# [master] 保存为 secret-demo.yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-cred
type: Opaque
stringData:
  username: admin
  password: "S3cr3t!"
---
apiVersion: v1
kind: Pod
metadata:
  name: use-secret
spec:
  containers:
  - name: main
    image: busybox:1.36
    command: ["sh", "-c", "cat /etc/db/password; sleep 3600"]
    volumeMounts:
    - name: db
      mountPath: /etc/db
      readOnly: true
  volumes:
  - name: db
    secret:
      secretName: db-cred
      defaultMode: 0400        # Secret 默认 0644，建议收紧到 0400
```

```bash
# [master] base64 一层窗户纸：谁都解得开
kubectl apply -f secret-demo.yaml
kubectl get secret db-cred -o jsonpath='{.data.password}' | base64 -d; echo
# 预期输出：S3cr3t!
```

### 4.3 在 etcd 层面验证"没加密"

```bash
# [master] 直接读 etcd 里的原始存储（kubeadm 集群，etcd 为 static pod）
kubectl -n kube-system exec etcd-$(hostname) -- env ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/db-cred | grep -ao '"username":"[^"]*"\|"password":"[^"]*"'
# 预期输出（value 仍是 base64，任何人拿到 etcd 备份都能解出明文）：
#   "username":"YWRtaW4="
#   "password":"UzNjM3QhIQ=="
```

结论：base64 是编码不是加密。真正的防线有三道：etcd 静态加密（EncryptionConfiguration，aescbc/kms provider，CKS 重点，见第 07-cks 模块）、RBAC（谁能 get/list secrets）、以及尽量少把口令放 env（`/proc/1/environ` 全程可读、易被打进日志）而用卷挂载。

节点侧的兜底：kubelet 把 Secret 挂为 tmpfs，不写入节点磁盘；Pod 删除后随之消失（镜像拉取用的 dockerconfigjson 除外，运行时会写临时文件）。

## 5. 配置更新后如何让应用感知

绝大多数应用不 watch 文件，所以流程收口到一个动作：让控制器重建 Pod。

```bash
# [master] 方法一：rollout restart（原理是给 Pod 模板打 restartedAt 注释，触发滚动更新）
kubectl create deployment web-cm --image=nginx:1.27 --replicas=2
# 给 Deployment 挂上 demo-cm（strategic patch：containers 列表按 name 合并）
kubectl patch deployment web-cm --type strategic -p \
  '{"spec":{"template":{"spec":{"volumes":[{"name":"conf","configMap":{"name":"demo-cm"}}],"containers":[{"name":"web-cm","volumeMounts":[{"name":"conf","mountPath":"/etc/conf"}]}]}}}}'
kubectl patch configmap demo-cm --type merge -p '{"data":{"app.conf":"mode=canary\n"}}'
kubectl rollout restart deployment/web-cm
kubectl rollout status deployment/web-cm
kubectl get deployment web-cm -o jsonpath='{.spec.template.metadata.annotations.kubectl\.kubernetes\.io/restartedAt}'
# 预期输出：类似 2026-08-22T10:30:00Z 的时间戳
```

方法二（Helm 等 templating 场景）：把配置内容的哈希写进 Pod 模板注释（如 `checksum/config: {{ include ... }}`），配置一变哈希就变，等价于模板变更，自动滚动。方法三：应用内置 watch/reload 逻辑（consul-template、envoy hot restart 等），配合整卷挂载。三条路共同点：**K8s 本身不会因为 ConfigMap 变化自动重启任何 Pod**。

## 实战演练

环境：kubeadm 单 master 集群。本演练 2.1 节的 Pod 已作为基础，按顺序做：

```bash
# [master] 步骤 1：观察原子更新的中间结构（脚本循环抓 ..data 指向）
kubectl exec cm-inject -- ls -la /etc/conf | grep '\.\.data'
kubectl patch configmap demo-cm --type merge -p '{"data":{"app.conf":"mode=v2\n"}}'
for i in 1 2 3 4 5 6; do
  kubectl exec cm-inject -- sh -c 'ls -la /etc/conf | grep "\.\.data"' ; sleep 15
done
# 预期：约 1 分钟内 ..data -> ..<新时间戳>/，再 cat /etc/conf/app.conf 已是 mode=v2
```

```bash
# [master] 步骤 2：验证 subPath 与 env 不更新（见 3.3 节命令与预期输出）
```

```bash
# [master] 步骤 3：验证 immutable 的不可变性
kubectl apply -f immutable-cm.yaml
kubectl patch configmap immutable-cm --type merge -p '{"data":{"app.conf":"mode=x\n"}}'
# 预期报错： ConfigMap "immutable-cm" is invalid: data: Forbidden: field is immutable when `immutable` is set
kubectl delete configmap immutable-cm
```

```bash
# [master] 步骤 4：Secret 的完整闭环
kubectl apply -f secret-demo.yaml
kubectl exec use-secret -- cat /etc/db/password     # S3cr3t!
kubectl exec use-secret -- ls -l /etc/db           # 权限 0400
kubectl get secret db-cred -o jsonpath='{.data.password}' | base64 -d; echo
```

```bash
# [master] 清理
kubectl delete pod cm-inject use-secret; kubectl delete configmap demo-cm
kubectl delete secret db-cred; kubectl delete deployment web-cm
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 改了 ConfigMap，容器里 env 没变 | env 只在进程启动时注入，之后不可变 | 改用卷挂载，或 rollout restart |
| subPath 挂的单文件改不动 | bind mount 建立后不参与热更新 | rollout restart；或改成挂整个目录 |
| Pod 卡在 CreateContainerConfigError | 引用的 ConfigMap/Secret/key 不存在 | 先建对象；确属可选则 `optional: true` |
| ConfigMap 里带二进制/大文件失败 | etcd 单对象约 1MiB 限制 | 大文件走对象存储/PVC，只挂引用 |
| key 做文件名时报非法字符 | 用作路径的 key 只能含 `[-._a-zA-Z0-9]` | 改 key 或用 volume.items 的 path 改名 |
| 改 Secret 后 Pod 里还是旧口令 | 同 ConfigMap 的更新语义 | 卷挂载等同步；env/subPath 需重启 |
| "Secret 反正 base64 了很安全" | base64 秒解；etcd 里就是明文 | 静态加密 + RBAC 收口 + 避免注入 env |
| immutable 对象想改 | 设计如此 | 删除后同名重建，再重启消费方 |

## 自测

1. 为什么 ConfigMap 卷的更新"不会让进程读到写了一半的文件"？说出保证这一点的两步操作。

<details><summary>答案</summary>

kubelet 不原地改文件，而是：先在新的时间戳目录里把所有 key 完整写好；再用 rename 原子地把 `..data` 软链切到新目录。读者要么完全看到旧目录、要么完全看到新目录，不存在中间态。
</details>

2. 同一个 Nginx：A 用 `mountPath: /etc/nginx/nginx.conf` + `subPath: nginx.conf`，B 把配置放目录整卷挂到 `/etc/nginx/conf.d/`。改完 ConfigMap 都执行了 `nginx -s reload`，为什么 A 没生效、B 生效了？

<details><summary>答案</summary>

B 的目录里文件是软链，kubelet 热更新后 open 到新内容，reload 加载的就是新配置。A 的 subPath 是 bind mount，建立时已解析到旧版本目录中的具体文件，热更新替换 `..data` 不影响它，reload 加载的还是旧文件。A 必须重启 Pod（重新建立 bind mount）才能拿到新配置。
</details>

3. 应用用 inotify watch `/etc/conf/app.conf` 却收不到更新事件，为什么？

<details><summary>答案</summary>

原子更新改的是 `..data` 软链的指向（不同目录、不同 inode），inotify watch 绑定的是具体 inode 的路径事件，软链切换不触发它。可行做法：watch `/etc/conf` 目录并关注 `..data` 的变更事件（目录事件），或退化为轮询 stat。
</details>

4. 为什么大量 ConfigMap/Secret 标记 immutable 能给 kube-apiserver 和 kubelet 同时减负？代价是什么？

<details><summary>答案</summary>

apiserver 侧：不可变对象无需参与 watch 变更传播与相应缓存失效逻辑，大量对象的 watch 开销显著下降；kubelet 侧：挂载它的卷不再需要周期性同步对比。代价：内容只能删除重建（immutable 字段与 data 都不可改），消费方 Pod 要重启才能换到新版本，绕不过"配置即版本"的运维成本。
</details>

5. 既然 Secret 不加密，它与 ConfigMap 的本质差别还剩什么？说出至少三条有运维意义的差异。

<details><summary>答案</summary>

（任三条即可）默认挂载 tmpfs 不落节点磁盘；有独立类型体系与 apiserver 校验（tls/dockerconfigjson 等）；审计与 RBAC 可以按资源类别单独收紧（谁能在哪些 namespace 读 Secret）；可启用静态加密/KMS 而不影响 ConfigMap；镜像拉取凭证只能用 Secret；kubelet 对其同步与投影方式（如 SA token 的 audience/过期投影）有专门逻辑。
</details>

## 延伸阅读

- ConfigMap：https://kubernetes.io/docs/concepts/configuration/configmap/
- Secret 与类型说明：https://kubernetes.io/docs/concepts/configuration/secret/
- 卷挂载的更新机制与 subPath 限制：https://kubernetes.io/docs/tasks/configure-pod-container/configure-pod-configmap/
- Secret 安全实践（CKS 重点）：https://kubernetes.io/docs/concepts/security/secrets-good-practices/
- etcd 静态加密：https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
- kubelet 对 ConfigMap/Secret 的同步策略（kubelet 配置参考）：https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/
