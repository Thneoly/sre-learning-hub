# 05 · Secret 实操与集群证书排错

> 模块：05-cka ｜ 建议时长：2.5 小时 ｜ 关联认证：CKA-Workloads（ConfigMaps and Secrets）/ Troubleshooting（证书排错）

## 学习目标

- 能用三种方式创建 Secret（`--from-literal`、`--from-file`、YAML 的 `stringData`）并说清 base64 与 1MiB 限制
- 能生成自签证书、创建 `tls` 类型 Secret、挂到 Ingress 并用 curl 验证 TLS 生效
- 能背出与 kube-apiserver 相关的六张证书各自的用途与签发 CA
- 能用 `kubeadm certs check-expiration` 与 `openssl` 双路检查证书，执行 `certs renew` 并重启控制面
- 能根据症状（连接拒绝 / Unauthorized / NotReady / x509 expired）判断是哪张证书过期

## 1. Secret 三种创建方式

Secret 与 ConfigMap 同源（key-value 注入），差异只有三点：值要 base64、单对象上限 1MiB、可以配 `type` 控制语义校验。考纲原文把"ConfigMaps **and Secrets**"并列，题库只练了前者——这一节补齐另一半。

### 1.1 方式一：命令行 --from-literal（考场最快）

```bash
# [master] 键值对直接给（多个 --from-literal 可叠加）
kubectl -n web create secret generic db-cred \
  --from-literal=username=admin \
  --from-literal=password='S3cr3t!'

# [master] 验证：值自动 base64
kubectl -n web get secret db-cred -o jsonpath='{.data.password}'; echo
echo 'UzNjcjN0IQ==' | base64 -d      # 解码回 S3cr3t!
```

### 1.2 方式二：--from-file / --from-env-file

```bash
# [master] 从文件读：key 默认是文件名
echo -n 'admin' > username.txt
echo -n 'S3cr3t!' > password.txt
kubectl -n web create secret generic db-cred-file \
  --from-file=./username.txt --from-file=./password.txt

# [master] 也可以自定义 key：--from-file=<key>=<路径>
kubectl -n web create secret generic db-cred-kv \
  --from-file=user=./username.txt --from-file=pass=./password.txt

# [master] env 文件一次导入多对（每行 KEY=VALUE）
cat > db.env <<'EOF'
username=admin
password=S3cr3t!
EOF
kubectl -n web create secret generic db-cred-env --from-env-file=db.env
```

### 1.3 方式三：YAML（stringData 明文写入，服务端转 base64）

```yaml
# [master] secret.yaml：kubectl apply -f secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-cred-yaml
  namespace: web
type: Opaque
stringData:              # 明文写，API Server 落盘时自动编码为 data
  username: admin
  password: "S3cr3t!"
---
# 手写 data 的等价形式（必须自己 base64，考试不推荐，容易错）
apiVersion: v1
kind: Secret
metadata:
  name: db-cred-b64
  namespace: web
type: Opaque
data:
  username: YWRtaW4=
  password: UzNjcjN0IQ==
```

考场默认用 `stringData`：不用手工编码、不易出错；`data` 与 `stringData` 同 key 时 `stringData` 生效。

### 1.4 注入 Pod 的两种姿势

```yaml
# [master] use-secret.yaml：kubectl apply -f use-secret.yaml
apiVersion: v1
kind: Pod
metadata:
  name: app
  namespace: web
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ["sh", "-c", "env | grep DB_; sleep 3600"]
    env:                                   # 姿势 1：按 key 取单项
    - name: DB_USER
      valueFrom:
        secretKeyRef:
          name: db-cred
          key: username
    envFrom:                               # 姿势 2：整个 Secret 灌成环境变量
    - secretRef:
        name: db-cred
    volumeMounts:                          # 姿势 3（文件形式）：挂成文件
    - name: cred
      mountPath: /etc/cred
      readOnly: true
  volumes:
  - name: cred
    secret:
      secretName: db-cred
```

```bash
# [master] 验证
kubectl -n web exec app -- env | grep DB_
kubectl -n web exec app -- cat /etc/cred/username
```

限制与注意：单 Secret ≤ 1MiB（etcd 单对象上限）；volume 方式挂出的文件会随 Secret 更新自动刷新（用 subPath 挂载则不会）；Secret 默认在 etcd 里只是 base64 **不是加密**——静态加密属于 CKS 范畴，这里知道边界即可。

## 2. TLS Secret 与 Ingress

这是"Secret + Ingress"的复合考法：生成证书 → 建 `tls` Secret → Ingress 引用 → curl 验证。

### 2.1 生成自签证书并创建 TLS Secret

```bash
# [master] 一条 openssl 生成证书与私钥（SAN 必须覆盖访问域名）
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=web.k8s.local" \
  -addext "subjectAltName=DNS:web.k8s.local"

# [master] 建 tls 类型 Secret（字段名固定为 tls.crt / tls.key，由类型校验）
kubectl -n web create secret tls web-tls --cert=tls.crt --key=tls.key
kubectl -n web get secret web-tls -o jsonpath='{.type}'; echo    # kubernetes.io/tls
```

### 2.2 Ingress 挂 TLS

```yaml
# [master] ingress-tls.yaml：kubectl apply -f ingress-tls.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: web-tls
  namespace: web
spec:
  ingressClassName: nginx
  tls:                              # 关键段：host 与 secretName
  - hosts:
    - web.k8s.local
    secretName: web-tls
  rules:
  - host: web.k8s.local
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web
            port:
              number: 80
```

### 2.3 验证

```bash
# [master] 1. Ingress 就绪且 controller 没有证书报错
kubectl -n web get ingress web-tls
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=20 | grep -i tls

# [master] 2. 实际握手：-v 看到的 server certificate 应是 web.k8s.local（自签所以加 -k）
curl -kv https://web.k8s.local --resolve web.k8s.local:443:172.30.30.21 2>&1 | \
  grep -E 'subject|issuer|SSL connection'

# [master] 3. 对照：确认返回的就是 Secret 里那张
openssl x509 -in tls.crt -noout -subject -enddate
```

常见故障：`tls:` 段的 secretName 写错或 Secret 在别的 ns（Ingress 只能引用**同 namespace** 的 Secret），controller 日志会报 `secret not found` 并回退到默认证书。

## 3. kubeadm 证书体系：六张 apiserver 相关证书

kubeadm 的证书都在 `/etc/kubernetes/pki/`，由三张 CA 分别签发。先看布局：

```
# [图] /etc/kubernetes/pki 布局（粗体为三张 CA）
pki/
├── ca.crt ca.key                        # 根 CA：签 apiserver、apiserver-kubelet-client
│                                          （并作为各 kubeconfig 的信任锚）
├── apiserver.crt apiserver.key          # 1. apiserver 服务端证书
├── apiserver-kubelet-client.crt .key    # 2. apiserver → kubelet 的客户端证书
├── etcd/
│   ├── ca.crt ca.key                    # etcd CA：签 etcd 三对证书与 apiserver-etcd-client
│   ├── server.crt server.key            # 4. etcd 服务端证书
│   ├── peer.crt peer.key                # 5. etcd 成员间证书
│   └── healthcheck-client.crt .key      #    （etcd Pod liveness 探针用）
├── apiserver-etcd-client.crt .key       # 3. apiserver → etcd 的客户端证书
├── front-proxy-ca.crt .key              # front-proxy CA：签 front-proxy-client
└── front-proxy-client.crt .key          # 6. apiserver → 扩展 API server 的客户端证书
```

六张证书的用途速查（背这张表，排错题直接定位）：

| # | 证书 | 谁用、连谁 | 过期时的典型症状 |
| --- | --- | --- | --- |
| 1 | `apiserver.crt` | kube-apiserver 的服务端身份，SAN 含节点名、`kubernetes`、`kubernetes.default`、service IP、节点 IP | 所有客户端报 `x509: certificate has expired`；kubectl 连接报 Unable to connect / tls failed |
| 2 | `apiserver-kubelet-client.crt` | apiserver 作为**客户端**连各节点 kubelet（10250）：logs / exec / top | Pod 正常但 `kubectl logs`、`kubectl exec` 报 401/403 或 x509 过期 |
| 3 | `apiserver-etcd-client.crt` | apiserver 作为客户端连 etcd（2379） | apiserver CrashLoop，日志报 `etcdserver: request timed out` / x509；集群整体只读或不可用 |
| 4 | `etcd/server.crt` | etcd 服务端（2379），同时带 client/server 两种用途 | etcd Pod 起不来；etcdctl 连 2379 报证书过期 |
| 5 | `etcd/peer.crt` | etcd 成员之间 raft 复制（2380） | 多 master 下成员互相发现失败、etcd 集群分裂 |
| 6 | `front-proxy-client.crt` | apiserver 代理访问 aggregated API server（metrics-server 等）时的身份 | metrics-server / 扩展 API 相关调用失败，`kubectl top` 不可用 |

kubelet 自身的客户端证书不在这棵树里：它在 `/var/lib/kubelet/pki/`，由 kubelet 自动轮换（这是"节点 NotReady 但 apiserver 正常"时优先怀疑的对象，见第 5 节与 06 章）。

## 4. 检查与续期：kubeadm certs

### 4.1 check-expiration

```bash
# [master] 一张表看全部证书（需要 root 读 pki）
sudo kubeadm certs check-expiration
```

输出分三段：`CERTIFICATE` 表（各证书的到期日与剩余天数，含 admin.conf 等 kubeconfig 内嵌证书）、`CERTIFICATE AUTHORITY` 表（三张 CA 的有效期，CA 默认 10 年）、以及 `kubeadm` 提示。判读规则：**剩余天数 < 30 就该续**；`check-expiration` 同时会提示该用哪个版本语法。

单张证书的精查（不依赖 kubeadm，考场任何环境都能跑）：

```bash
# [master] 到期时间 + 主体
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -enddate -subject
# notAfter=Nov  6 09:00:00 2026 GMT

# [master] SAN 是否覆盖访问名（apiserver 证书必须含 kubernetes.default 等）
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A1 'Subject Alternative Name'

# [master] 证书与私钥是否配对（两条命令的 modulus 应一致）
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -modulus | openssl md5
sudo openssl rsa -in /etc/kubernetes/pki/apiserver.key -noout -modulus | openssl md5
```

### 4.2 renew 与控制面重启

```bash
# [master] 续全部（也可单张：kubeadm certs renew apiserver 等）
sudo kubeadm certs renew all

# [master] 确认新到期日
sudo kubeadm certs check-expiration | head -15

# [master] 关键一步：静态 Pod 不会自动加载新证书，必须重启（kubelet 会立刻重建）
crictl ps --name kube-apiserver -q | xargs -r sudo crictl stop
crictl ps --name etcd -q        | xargs -r sudo crictl stop
crictl ps --name kube-controller-manager -q | xargs -r sudo crictl stop
crictl ps --name kube-scheduler -q | xargs -r sudo crictl stop

# [master] 等待重建后验证
watch -n2 'crictl ps --name kube-apiserver'   # 重新 Running
kubectl get nodes
```

`renew` 只改文件不重启进程——漏了 `crictl stop` 这步会看到"证书明明续了但症状依旧"，是本考点第一大坑。CA 证书不能用 `renew` 续（只能重签集群，超出考试范围）。

## 5. 证书过期典型症状速查

| 症状 | 先查哪里 | 多半是哪张 |
| --- | --- | --- |
| `kubectl` 一切命令报 `connection refused` / apiserver 起不来 | `crictl ps -a` 看 apiserver 容器，`crictl logs` 搜 `x509: certificate has expired` | `apiserver.crt`（服务端）或 `apiserver-etcd-client.crt`（连不上 etcd 导致 CrashLoop） |
| apiserver 日志刷 `etcdserver: request timed out` + x509 | `crictl logs <apiserver容器>`；`openssl` 查 `apiserver-etcd-client.crt` | `apiserver-etcd-client.crt` |
| `kubectl get pods` 正常，`kubectl logs/exec/top` 报 Unauthorized | 查 `apiserver-kubelet-client.crt` 到期日 | `apiserver-kubelet-client.crt` |
| 单节点 NotReady、其余正常，kubelet 日志报 `x509 ... certificate expired` | 节点上 `journalctl -u kubelet -S -1h \| grep -i x509`；看 `/var/lib/kubelet/pki/` | kubelet 客户端证书（自动轮换失败时手动处理） |
| etcd Pod CrashLoop，日志报 `remote error: tls: bad certificate` | `openssl` 查 `etcd/server.crt`、`etcd/peer.crt` | etcd 两张 |
| `kubectl top node` 一直 error，metrics-server 正常 | `front-proxy-client.crt` 到期日 | `front-proxy-client.crt` |
| 重启后集群起不来，且时间明显跳变过 | `date` 对比证书 `notBefore`：证书"未生效"也是同类错 | 全部（系统时钟漂移） |

排错顺序建议固定成一条链：`kubectl get nodes`（还活着吗）→ `crictl ps -a`（哪个控制面容器挂了）→ `crictl logs` 搜 x509 → `kubeadm certs check-expiration`（哪张到期）→ 对症 renew + `crictl stop`。与 06 章的决策树同一骨架。

## 实战演练

```bash
# [master] 1. Secret 三连：literal / file / stringData 各建一个并比对
kubectl create ns sec-drill
kubectl -n sec-drill create secret generic s1 --from-literal=k1=v1
echo -n v2 > /tmp/k2.txt
kubectl -n sec-drill create secret generic s2 --from-file=k2=/tmp/k2.txt
kubectl -n sec-drill apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata: {name: s3, namespace: sec-drill}
type: Opaque
stringData: {k3: v3}
EOF
kubectl -n sec-drill get secret s1 s2 s3 -o custom-columns='NAME:.metadata.name,KEYS:.data'

# [master] 2. TLS secret + Ingress（第 2 节全流程，域名换成 sec-drill 可访问的）
# [master] 3. 证书体检：check-expiration + 单张 openssl 精查 apiserver 证书 SAN
sudo kubeadm certs check-expiration | tail -n +2 | head -12
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | grep -A1 'Subject Alternative Name'

# [master] 4. 收尾
kubectl delete ns sec-drill
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| `create secret tls` 报错 key/cert 不匹配 | 证书与私钥不是同一对 | `openssl x509/-rsa` 对 modulus（4.1）确认后重做 |
| Ingress 回退默认证书，浏览器仍拿到假证书 | secretName 写错 / Secret 不在 Ingress 同一 ns | Ingress 只能引用同 ns 的 Secret；看 ingress-controller 日志确认 |
| YAML 手写 `data` 后 Pod 读出来乱码 | base64 编错了或带了换行 | 用 `stringData`；或 `base64 -w0` 生成无换行编码 |
| Secret 更新了但容器里文件不变 | volumeMount 用了 subPath（不会热更） | 去掉 subPath，或滚动重启 `rollout restart` |
| `certs renew all` 之后症状没变 | 静态 Pod 没重启，进程还在用旧证书 | `crictl stop` 四个控制面容器让 kubelet 重建（4.2） |
| `check-expiration` 显示 CA 过期 | CA 默认 10 年，到期不能 renew | 考试不会出；生产需重新签发整个集群 |
| 节点 NotReady 但控制面证书都新 | kubelet 客户端证书在 `/var/lib/kubelet/pki`，kubeadm renew 不覆盖 | `journalctl -u kubelet` 搜 x509；确认 kubelet 轮换配置 |
| Secret 超 1MiB 创建失败 | 单对象 etcd 限制 | 拆分或改用外部存储/挂载方式 |

## 自测

1. Secret 的 `data` 与 `stringData` 同时出现同名 key，最终存的是哪个？为什么考场推荐 `stringData`？

<details><summary>答案</summary>

`stringData` 生效——API Server 写入时会把 `stringData` 编码进 `data`。推荐它因为不需要手工 base64：手工编码容易带换行（`base64` 默认 76 列折行）导致值被污染，而 `stringData` 由服务端一次性处理。
</details>

2. `kubectl get pods` 正常返回，但 `kubectl logs` 报 401 Unauthorized。哪张证书过期？为什么 get pods 不受影响？

<details><summary>答案</summary>

`apiserver-kubelet-client.crt`。`get pods` 的请求由 kube-apiserver 从 etcd 读数据直接应答，不触碰 kubelet；而 `logs/exec/top` 是 apiserver 作为**客户端**去连目标节点的 kubelet:10250，用的正是这张客户端证书，过期后 kubelet 拒绝其身份。
</details>

3. Ingress 的 `tls.secretName` 指向 default ns 里明明存在的 Secret，为什么 controller 还是报找不到？

<details><summary>答案</summary>

Ingress 是 namespace 级资源，只能引用**同 namespace** 的 Secret——这是设计如此（ns 是信任边界）。解法：在 Ingress 所在 ns 里重建同名 Secret。
</details>

4. `kubeadm certs renew all` 执行完，`check-expiration` 显示新日期，但 apiserver 依然 CrashLoop 报证书过期。缺了哪一步？原理是什么？

<details><summary>答案</summary>

缺"重启静态 Pod"。`renew` 只替换磁盘上的证书文件；apiserver 进程在启动时把证书加载进内存，之后不再读文件。静态 Pod 由 kubelet 监视 manifest 管理，文件变化不触发容器重启，必须 `crictl stop` 让 kubelet 以新容器（重新加载证书）拉起。
</details>

5. etcd 的 `server.crt` 既能给 etcd 当服务端证书，又能给 etcdctl 当客户端证书连本机 2379。为什么可以"一证两用"？

<details><summary>答案</summary>

kubeadm 签发 etcd server 证书时同时写入了 `Server Auth` 与 `Client Auth` 两个 extended key usage，且 SAN 包含 localhost/127.0.0.1/节点名。mTLS 双向校验时，etcd 作为服务端验证它（Server Auth），etcdctl 作为客户端出示它（Client Auth）都满足校验条件。这也是 04 章 snapshot save 用 `--cert=server.crt` 能成功的原因。
</details>

## 延伸阅读

- Secret 概念与类型：https://kubernetes.io/docs/concepts/configuration/secret/
- 以文件/环境变量方式注入 Secret：https://kubernetes.io/docs/tasks/inject-data-application/distribute-credentials-secure/
- Ingress 配置 TLS：https://kubernetes.io/docs/concepts/services-networking/ingress/#tls
- 证书管理与 kubeadm certs：https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- PKI 证书与要求（六张证书的权威说明）：https://kubernetes.io/docs/setup/best-practices/certificates/
- 本模块配套练习：labs 12-sa-token-permissions（Secret 形式的 SA token）、04-ingress-routes
