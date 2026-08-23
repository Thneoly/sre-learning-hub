# 06 · Secret 静态加密：EncryptionConfiguration 落地、密钥轮换与验证

> 模块：CKS 备考 ｜ 建议时长：3 小时 ｜ 关联认证：CKS-Minimize Microservice Vulnerabilities（Manage Kubernetes secrets）/ CKA-etcd

## 学习目标

- 能解释 apiserver 的静态加密层在哪、各 provider 的差异与 key 顺序语义
- 能生成合规 key、写出 EncryptionConfiguration 并挂载到 kube-apiserver static Pod
- 能用 etcdctl 直接验证 etcd 里的 Secret 已被加密
- 能对存量 Secret 全量重加密，并完成一次标准的 key 轮换
- 能避开密钥顺序与重启顺序的经典坑

## 1. 为什么需要静态加密

默认情况下，Secret 在 etcd 里只是 base64 编码的明文——拿到 etcd 快照或 etcd 访问权的人可以直接读走全部凭证。静态加密在 **kube-apiserver 的存储层**生效：

```
kubectl create secret ──> kube-apiserver
                            │  写入前：用 EncryptionConfiguration 的 provider 加密
                            v
                          etcd     <== 落盘内容形如 k8s:enc:aescbc:v1:key1:G3xN...
                            ^
                            │  读出时：按 keys 列表逐个尝试解密
kubectl get secret   <──────┘  返回明文，应用无感知
```

三个推论：

1. 加解密对上层完全透明，业务与 kubectl 行为不变
2. **只对新写入生效**：开启前已存在的 Secret 仍是明文，必须重写（见第 5 节）
3. 密钥就放在 apiserver 能读到的本地文件里——它防的是"etcd 被拖库"，防不了拿到 master 主机 root 的人；更强的方案是 kms provider（密钥放外部 KMS/HSM）

## 2. Provider 与 key 规则

| provider | 算法 | key 要求 | 说明 |
| --- | --- | --- | --- |
| `identity` | 无（明文） | —— | 不加密；迁移/回退时使用，放在列表末尾兜底 |
| `aescbc` | AES-CBC + PKCS#7 padding | base64 的 16/24/32 字节 | CKS 最常考；实现简单 |
| `secretbox` | XSalsa20-Poly1305 | base64 的**恰好 32** 字节 | 官方推荐的内置高强度选择 |
| `aesgcm` | AES-GCM | base64 的 16/24/32 字节 | 快，但密钥使用有上限要求，高频写需勤轮换 |
| `kms` | 信封加密（KEK 在外部 KMS） | 需运行 kms plugin | v2 API 已 GA，生产首选 |

**key 顺序语义（本篇最重要的一句话）**：`keys` 列表里**第一个 key 用于加密新数据；所有 key 按顺序尝试解密**。轮换 = 把新 key 插到第一位，旧 key 保留用于解密，直到全部数据重写后才能删除旧 key。

生成 key：

```bash
# [master] 32 字节随机数的 base64（secretbox 必须 32 字节；aescbc 也可用）
head -c 32 /dev/urandom | base64
# 输出示例（每次不同）: r3fZK5wQ1cVbN8mH2xT9sLpQ7yD4eF6aU1iO0pJ3kMw=
```

## 3. EncryptionConfiguration 完整示例

下面这份同时演示 aescbc 与 secretbox 两种写法（实际部署选一种即可），并带 identity 兜底：

```yaml
# [master] /etc/kubernetes/encryption/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:            # 哪些资源类型要加密（一般只加密 secrets）
      - secrets
    providers:
      # 第一个 provider 用新 key 加密（此处以 aescbc 为例）
      - aescbc:
          keys:
            - name: key2                 # 新 key 放第一位：加密用它
              secret: r3fZK5wQ1cVbN8mH2xT9sLpQ7yD4eF6aU1iO0pJ3kMw=
            - name: key1                 # 旧 key 保留：解密历史数据
              secret: 5YbbD0pQ1cVbN8mH2xT9sLpQ7yD4eF6aU1iO0pJ3kMw=
      # 也可换用 secretbox（要求 key 恰好 32 字节）：
      # - secretbox:
      #     keys:
      #       - name: key2
      #         secret: r3fZK5wQ1cVbN8mH2xT9sLpQ7yD4eF6aU1iO0pJ3kMw=
      - identity: {}      # 末位兜底：都不是加密数据时按明文读（迁移期必需）
```

首次启用（没有历史 key）时，keys 里放一个即可；identity 必须放最后——放在第一位等于"新数据不加密"。

密钥文件权限收紧：

```bash
# [master]
sudo mkdir -p /etc/kubernetes/encryption
sudo chmod 600 /etc/kubernetes/encryption/encryption-config.yaml
```

## 4. 挂载到 kube-apiserver static Pod（完整步骤）

编辑 `/etc/kubernetes/manifests/kube-apiserver.yaml`：

**Step 1：command 加 flag。**

```yaml
# [master] spec.containers[0].command 列表追加
    - --encryption-provider-config=/etc/kubernetes/encryption/encryption-config.yaml
```

**Step 2：volumeMounts 挂进容器。**

```yaml
# [master] 同文件 spec.containers[0].volumeMounts 追加
      - name: encryption-config
        mountPath: /etc/kubernetes/encryption/encryption-config.yaml
        readOnly: true
        subPath: encryption-config.yaml
```

**Step 3：volumes 指向宿主机文件。**

```yaml
# [master] 同文件 spec.volumes 追加
    - name: encryption-config
      hostPath:
        path: /etc/kubernetes/encryption/encryption-config.yaml
        type: File
```

**Step 4：等待 kubelet 自动重建 apiserver。**

```bash
# [master] 保存 manifest 后约 30~60 秒
kubectl -n kube-system get pods | grep kube-apiserver
# 预期: Running（若 CrashLoopBackOff，见常见坑）
```

## 5. 存量 Secret 重加密与 etcdctl 验证

**安装 etcd 客户端（验证用）：**

```bash
# [master]
sudo apt-get update && sudo apt-get install -y etcd-client
```

**验证一：新建的 Secret 已加密。**

```bash
# [master] 建一个测试 Secret
kubectl create secret generic db-cred -n default --from-literal=password='S3cr3t!'

# 用 etcd 的服务端证书直接读 etcd（kubeadm 默认本地 etcd）
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/db-cred --print-value-only | hexdump -C | head -3
# 预期: 首行出现 k8s:enc:aescbc:v1:key2: 开头的前缀，后跟密文（不再是可读的 base64 JSON）
```

前缀格式 `k8s:enc:<provider>:<version>:<keyname>:` 直接告诉你用了哪个 provider 和哪个 key——这也是排错时最快的定位手段（比如意外显示 `k8s:enc:aescbc:v1:key1:`，说明新 key 没排到第一位）。

**验证二：开启加密前已存在的 Secret 仍是明文。**

```bash
# [master] 老 Secret 的 etcd 内容仍可读出 "password" 字样，需要重写
OLD_SECRET=plain-demo   # 换成开启加密前已存在的 Secret 名
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/$OLD_SECRET --print-value-only | strings | grep -m1 password
```

**存量全量重加密：** 让 apiserver 读出再写回（读时解密/兼容明文，写时用新 key 加密）：

```bash
# [master] 官方推荐的一行式（读全部 Secret 并 replace 重写）
kubectl get secrets --all-namespaces -o json | kubectl replace -f -

# 大集群报 "request too large" 时按 namespace 分批
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  echo "rewriting $ns"
  kubectl get secrets -n "$ns" -o json | kubectl replace -f -
done

# 复验：老 Secret 现在也应带 k8s:enc:aescbc:v1:key2: 前缀
```

`kubectl get secrets -A` 正常返回、且 etcd 里全部带 enc 前缀，即重加密完成。

## 6. 标准密钥轮换流程（背下来）

```
备份 etcd ──> 新 key 插到 keys 第一位 ──> 重启 apiserver
        ──> 全量重写 Secret ──> 删除旧 key ──> 再重启 apiserver ──> 复验
```

```bash
# [master] Step0 备份（任何轮换前必做）
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /root/etcd-snapshot-$(date +%F).db

# Step1 生成新 key 并编辑 encryption-config.yaml，新 key 放到 keys[0]（见第 3 节文件结构）

# Step2 static Pod 已随文件挂载，但内容变了要让 apiserver 重新读取：
#       touch manifest 触发 kubelet 重建
sudo touch /etc/kubernetes/manifests/kube-apiserver.yaml
kubectl -n kube-system get pods | grep kube-apiserver   # 等 Running

# Step3 全量重写（第 5 节命令）

# Step4 确认所有 Secret 的 etcd 前缀都是新 key 名（key2）后，
#       编辑 config 删掉旧 key1，再次 touch manifest 重启

# Step5 复验 kubectl 正常 + etcd 前缀正确
kubectl get secrets -A | wc -l
```

危险动作是 Step4 抢跑：旧 key 没解密完所有存量数据就删除，那些 Secret 将**永久不可读**（只有靠 Step0 的快照恢复）。

## 7. kms provider 一瞥

生产上更推荐把根密钥交给外部 KMS（信封加密：KMS 只保管 KEK，本地生成 DEK）：

```yaml
# [master] providers 里替换/追加（需要先部署对应的 kms plugin 进程）
      - kms:
          apiVersion: v2
          name: my-kms-provider
          endpoint: unix:///var/run/kms/kms.sock
          timeout: 3s
```

考点仍以 aescbc/secretbox 为主，kms 记住三点即可：plugin 必须先于 apiserver 可用、endpoint 是 unix socket、v2 API 已 GA。

## 实战演练：从明文到加密再到轮换

环境：kubeadm 单 master 集群。全程约 30 分钟。

```bash
# [master] 1. 演示"默认明文"：开加密前建一个 Secret 并看 etcd
kubectl create secret generic plain-demo -n default --from-literal=pw=plain
sudo apt-get install -y etcd-client
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/plain-demo --print-value-only | strings | grep -m1 plain
# 预期: 能看到明文片段 —— 这就是风险

# [master] 2. 生成 key、落盘 config（第 2、3 节）、挂载（第 4 节）

# [master] 3. 新建 Secret 验证前缀；再全量重写，复验 plain-demo 也变成 k8s:enc:（第 5 节）

# [master] 4. 再生成一个新 key 做一次完整轮换（第 6 节五步）

# [master] 5. 清理与回滚练习
kubectl delete secret db-cred plain-demo -n default
# 回滚=把 providers 改成只有 identity: {}（放第一位），touch manifest，再全量重写即恢复明文存储
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| apiserver CrashLoopBackOff | config YAML 缩进错误；secret 不是合法 base64；secretbox key 不是 32 字节 | `crictl logs <apiserver容器>` 看报错行；`base64 -d` 自检 key；恢复备份 manifest 先救活 apiserver |
| etcd 里看到 `k8s:enc:aescbc:v1:key1:` 而不是新 key | 新 key 没放到 keys 列表第一位 | 加密永远用 keys[0]；调整顺序后 touch manifest 重启 |
| 轮换后部分 Secret 读不出：`rpc error ... unable to decrypt` | 旧 key 被删早了，还有数据只被旧 key 加密过 | 用 etcd 快照恢复；流程上必须"重写完成→验证前缀→再删旧 key" |
| 开启加密后老 Secret 在 etcd 里还是明文 | 加密只对**新写入**生效 | `kubectl get secrets --all-namespaces -o json | kubectl replace -f -` 全量重写 |
| `kubectl get secrets -A -o json` 报 request too large | 集群 Secret 太多，单请求超限 | 按 namespace 分批重写（第 5 节循环） |
| etcdctl 报 connection refused / 证书错误 | endpoints 写错（应为 127.0.0.1:2379）或证书路径不对；外部 etcd 时证书在别处 | kubeadm 本地 etcd 用 /etc/kubernetes/pki/etcd/ 三件套；`ss -tlnp | grep 2379` 确认端口 |
| 改了 config 但行为没变 | apiserver 没有重启（hostPath File 内容变化不一定触发 kubelet 重建） | `touch` static Pod manifest 强制重建；确认 pod age 已刷新 |

## 自测

1. 拿到 etcd 快照的攻击者分别面对"默认存储""aescbc 加密""kms 加密"三种情况，风险有何不同？

<details><summary>答案</summary>

默认：直接读出全部 Secret 明文。aescbc：密文不可读，但加密 key 在 master 的 encryption-config.yaml 里，若连主机/root 或备份一起泄露则照样解密。kms：KEK 在外部 KMS，快照＋主机文件都拿不到密钥，安全边界最大——这就是"防拖库"与"防主机沦陷"的差别。
</details>

2. providers 列表把 `identity: {}` 放在第一位会发生什么？放在最后一位又是什么语义？

<details><summary>答案</summary>

第一位：identity 是第一个"可写"provider，所有新写入都不加密（等于没开加密），但能读历史明文与旧密文之外的任何数据——这是过渡回退的用法。最后一位：新数据用前面的加密 provider 写，读的时候最后才按明文兜底，保证开启加密初期未重写的存量 Secret 仍可读——这是推荐位置。
</details>

3. 为什么轮换流程必须在"删除旧 key"之前"全量重写"并验证 etcd 前缀？

<details><summary>答案</summary>

解密是按 keys 列表逐个尝试。删旧 key 前若仍有数据只被旧 key 加密过，这些数据从此不可解（apiserver 读不出来，Secret 报错）。全量重写保证所有数据都改用 keys[0]（新 key）加密，验证 etcd 前缀全部是 `...:v1:<新key名>:` 才证明没有漏网数据。
</details>

4. `kubectl get secrets --all-namespaces -o json | kubectl replace -f -` 这条命令如何完成"重加密"？它没有指定任何 key。

<details><summary>答案</summary>

replace 会把每个 Secret 以"写"方式提交给 apiserver；apiserver 读出旧值（此时才需要解密或按明文读），再按当前 EncryptionConfiguration 的 keys[0] 重新加密落盘。key 的选择完全由 apiserver 侧配置决定，kubectl 只负责触发读改写。
</details>

5. 同一集群里 ConfigMap 需要加密吗？EncryptionConfiguration 的 resources 列表还可以写什么？

<details><summary>答案</summary>

ConfigMap 通常不含密文（且体积大、写频繁，加密得不偿失），只加密 secrets 是默认实践。resources 列表技术上可写任意资源（如 configmaps、pods），个别合规场景会连同 CRD 里的敏感字段一起加密，但要评估 apiserver 的加解密开销。
</details>

## 延伸阅读

- Encrypting Confidential Data at Rest（官方操作文档）：<https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/>
- Decrypt Data that is Already Encrypted（回退流程）：<https://kubernetes.io/docs/tasks/administer-cluster/decrypt-data/>
- Using a KMS provider for data encryption：<https://kubernetes.io/docs/tasks/administer-cluster/kms-provider/>
- etcd 运维（快照与恢复）：<https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/>
- Good practices for Kubernetes Secrets：<https://kubernetes.io/docs/concepts/security/secrets-good-practices/>
