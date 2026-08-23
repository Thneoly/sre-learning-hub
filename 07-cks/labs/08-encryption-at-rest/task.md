# Lab 08 · EncryptionConfiguration：Secret 落盘加密全流程

> 难度：★★★ ｜ 考点：CKS-Secret 加密（Encryption at Rest） ｜ 前置：无 ｜ 预计 40~50 分钟

## 场景

安全审计发现：直接读 etcd 就能看到所有 Secret 的明文——因为 kubeadm 集群默认不加密。整改要求：apiserver 写入 etcd 的 Secret 必须用 aescbc 加密，且要"眼见为实"地证明 etcd 里没有明文。你要完成从生成密钥、下发 EncryptionConfiguration、改 apiserver、到 etcd 验证的全流程，并知道如何安全地轮换密钥与回滚。

```
kubectl create secret --> apiserver: 按 EncryptionConfiguration 用 provider 加密
                              |
                              v
                     etcd 存储: k8s:enc:aescbc:v1:key1:<密文>
                              |
kubectl get secret  <-- apiserver: 解密后返回  <-- 拿到配置里同一个 key
```

provider 的 `identity` 条目必须保留在列表**末位**：它让 apiserver 还能读取历史上未加密的数据（读旧数据 + 写新数据都加密）。

## 任务清单

1. 生成 32 字节随机密钥并 base64；编写 `/etc/kubernetes/encryption-config.yaml`（`kind: EncryptionConfiguration`，资源覆盖 `secrets`，provider 顺序 `aescbc` → `identity`）。
2. 将该文件打包成 `kube-system` 里的 Secret `encryption-configuration`（key 为文件名），作为配置的分发与存档载体（判分依据之一）。
3. 修改 `/etc/kubernetes/manifests/kube-apiserver.yaml`：`command` 追加 `--encryption-provider-config=/etc/kubernetes/encryption-config.yaml`；新增 **hostPath** volume 把该文件挂载到这个路径。等待 apiserver 重启就绪。

> ⚠️ 千万不要用 Secret/ConfigMap 卷去挂 apiserver 静态 Pod 的这个文件：kubelet 对静态 Pod 有硬校验，日志会报 `Could not process manifest file ... static pods may not reference secrets` 并直接丢弃 manifest——apiserver 被杀掉后新 Pod 起不来，单 master 集群当场瘫 API。托管集群（GKE 等）能这么干是因为它们的 apiserver 不是 kubelet 管的静态 Pod。
4. 创建 namespace `cks-lab08` 与 Secret `credit-card`（`--from-literal=number=4111111111111111`）。
5. 用 `etcdctl` 直接读 `/registry/secrets/cks-lab08/credit-card`：确认密文含 `k8s:enc:aescbc:v1:` 前缀且不含明文卡号。
6. （理解项）说明密钥轮换的步骤与顺序，写在你的实验笔记或 solution 对照。

## 验收标准

- `kubectl -n kube-system get secret encryption-configuration` 存在，解码后含 `aescbc`
- apiserver manifest 含 `--encryption-provider-config` flag，静态 Pod Running
- `kubectl -n cks-lab08 get secret credit-card -o jsonpath='{.data.number}' | base64 -d` 仍能读出明文（apiserver 解密正常）
- etcd 中该 key 的值以 `k8s:enc:aescbc:v1:key1:` 开头，且 grep 不到卡号数据（注意：Secret 对象在 etcd 里本就是 base64 编码，探测串用 `NDExMTExMTExMTExMTEx` 即 base64("4111111111111111") 的前缀）

运行判分脚本：

```bash
# [master]
cd 07-cks/labs/08-encryption-at-rest
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：密钥怎么生成</summary>

`head -c 32 /dev/urandom | base64`。32 字节是官方推荐的 key 长度；base64 后填进 `secret: <value>`。密钥泄露等于所有 Secret 泄露，文件权限收紧到 600，不要进 git。
</details>

<details><summary>提示 2：apiserver 怎么拿到这个配置</summary>

kubeadm 集群里 apiserver 是 kubelet 管理的静态 Pod，只能用 **hostPath 直接挂文件**（`type: File`）。可以另做一份 kube-system Secret 存档配置（审计/判分用），但不要把它挂进静态 Pod——kubelet 会以 `static pods may not reference secrets` 拒绝整个 manifest，apiserver 起不来。托管集群（GKE 等）文档里的 Secret 挂载写法不适用于自建 kubeadm。
</details>

<details><summary>提示 3：为什么已有 Secret 不会自动变密文</summary>

EncryptionConfiguration 只对**写入时**生效。存量 Secret 要重新加密：`kubectl get secrets -A -o json | kubectl replace -f -` 触发全量重写（运维窗口做，大集群会打满 apiserver）。
</details>

<details><summary>提示 4：etcdctl 怎么读单个 key</summary>

kubeadm 的 etcd 证书在 `/etc/kubernetes/pki/etcd/`：`ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key get /registry/secrets/cks-lab08/credit-card`。输出是二进制混排，管道给 `grep -a` 或 `strings` 看。
</details>
