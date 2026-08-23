# Lab 08 · 解答 —— Secret 落盘加密全流程

## 步骤 1：生成密钥并编写 EncryptionConfiguration

```bash
# [master]
sudo mkdir -p /etc/kubernetes/enc
KEY=$(head -c 32 /dev/urandom | base64)
echo "KEY=$KEY" | sudo tee /root/cks-lab08-key.bak   # 实验留存；生产请进密钥管理系统
```

```bash
# [master]
sudo tee /etc/kubernetes/enc/encryption-config.yaml >/dev/null <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${KEY}
      - identity: {}
EOF
sudo chmod 600 /etc/kubernetes/enc/encryption-config.yaml
```

要点：

- provider 列表是**有序**的：第一个用于写入加密，其余用于读取解密。`identity` 放末位 = "新数据全加密，老数据还能读"；
- 若把 `identity` 放首位，写入不再加密（读旧数据倒是正常）——考题爱挖这个坑；
- 常用 provider 对比：`aescbc`（快、CKS 常考）、`secretbox`（强度好、无硬件依赖）、`kms`（v2，对接外部 KMS，每对象独立 DEK，企业首选）。

## 步骤 2：打包为 kube-system Secret（存档/判分用）

```bash
# [master]
kubectl -n kube-system create secret generic encryption-configuration \
  --from-file=/etc/kubernetes/enc/encryption-config.yaml
```

Secret 名为 `encryption-configuration`，data key 自动取文件名 `encryption-config.yaml`（后面 go-template 取值要用）。它作为配置的分发与审计存档；**真正挂给 apiserver 的必须是宿主机上的文件**（见下一步的坑）。

## 步骤 3：修改 apiserver 静态 Pod

先备份：

```bash
# [master]
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/kube-apiserver.yaml.bak
sudo cp /etc/kubernetes/enc/encryption-config.yaml /etc/kubernetes/encryption-config.yaml
sudo chmod 600 /etc/kubernetes/encryption-config.yaml
```

编辑 `/etc/kubernetes/manifests/kube-apiserver.yaml`，三处：

1. `command` 追加：

```yaml
    - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml
```

2. `volumeMounts` 追加：

```yaml
    - name: encryption-config
      mountPath: /etc/kubernetes/encryption-config.yaml
      readOnly: true
```

3. `volumes` 追加（hostPath，静态 Pod 唯一合法的本地挂载方式）：

```yaml
  - hostPath:
      path: /etc/kubernetes/encryption-config.yaml
      type: File
    name: encryption-config
```

> **大坑**：不要把 `encryption-configuration` Secret 用 secret/projected 卷挂给 apiserver——kubelet 对静态 Pod 有硬校验，会直接拒绝整个 manifest 并在日志里刷 `Could not process manifest file ... static pods may not reference secrets`，同时把旧 apiserver 容器杀掉，单 master 集群 API 当场瘫掉（实测 v1.35）。恢复方法：用备份 manifest 覆盖回去，kubelet 下一个轮询周期就会重新拉起 apiserver。托管集群的 Secret 挂载写法只适用于 apiserver 不是静态 Pod 的环境。

等 apiserver 重建就绪：

```bash
# [master]
kubectl -n kube-system wait --for=condition=Ready pod -l component=kube-apiserver --timeout=300s
```

起不来的两大原因：挂载路径与 flag 不一致；EncryptionConfiguration YAML 语法错（缩进/密钥长度）。恢复：`sudo cp /etc/kubernetes/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml`。

## 步骤 4：创建测试 Secret

```bash
# [master]
kubectl create ns cks-lab08
kubectl -n cks-lab08 create secret generic credit-card \
  --from-literal=number=4111111111111111
```

## 步骤 5：etcd 侧验证

```bash
# [master]（若没有 etcdctl：sudo apt-get install -y etcd-client）
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/cks-lab08/credit-card \
  | grep -ao 'k8s:enc:aescbc:v1:[^ ]*' | head -1
# k8s:enc:aescbc:v1:key1:（后面是一串二进制密文）
```

确认无明文。注意一个细节：**即使不加密**，etcd 里的 Secret 对象也是 base64 编码的（`data.number` 字段本来就是 base64）——base64 不是加密。所以探测"是否泄露"要搜卡号的 base64 形式：

```bash
# [master]
# 未加密时会命中；加密后应为空
ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/cks-lab08/credit-card | grep -ac 'NDExMTExMTExMTExMTEx'
# 0
```

`NDExMTExMTExMTExMTEx...` 即 base64("4111111111111111")。业务侧读回验证解密正常：

```bash
# [master]
kubectl -n cks-lab08 get secret credit-card -o jsonpath='{.data.number}' | base64 -d; echo
# 4111111111111111
```

## 步骤 6：密钥轮换（理解 + 演练）

场景：`key1` 疑似泄露，换 `key2`。顺序错了会读不出数据：

```yaml
# 修改后的 providers（key2 在前用于写入；key1 保留用于读旧数据）
providers:
  - aescbc:
      keys:
        - name: key2
          secret: <新32字节base64>
        - name: key1
          secret: <旧key>
  - identity: {}
```

流程：

1. 更新 EncryptionConfiguration（新 key 在首位，旧 key 保留）；
2. 用新 Secret 更新 `kubectl -n kube-system create secret ... --dry-run=client -o yaml | kubectl replace -f -`，等 apiserver 重启；
3. 触发全量重写，让所有 Secret 换成 key2 加密：

```bash
# [master]（小集群专用，生产分批）
kubectl get secrets --all-namespaces -o json | kubectl replace -f -
```

4. 确认 etcd 全部变为 `k8s:enc:aescbc:v1:key2:` 后，再把 key1 从配置中删除（再重启一次 apiserver）。

存量数据不会自动重新加密——这就是第 3 步存在的原因，也是面试/考试的高频追问点。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| apiserver 容器被杀后不再创建，`journalctl -u kubelet` 刷 `static pods may not reference secrets` | 给静态 Pod 挂了 Secret/ConfigMap 卷（照抄了托管集群文档） | 用备份 manifest 恢复；改用 hostPath `type: File` 挂载配置文件 |
| apiserver 起不来 | 配置文件路径/挂载/语法错 | 用备份恢复；`describe` 看 Events |
| Secret 读回报 `decryption failed` | 密钥对不上（轮换时旧 key 被提前删掉） | 把旧 key 加回 providers 列表即可恢复读取 |
| etcd 里还是明文（base64） | Secret 创建早于 apiserver 启用加密 | 重新 `kubectl replace` 触发重写 |
| etcdctl 报 connection refused | endpoint 写成 localhost | kubeadm 默认监听 127.0.0.1:2379，确认 `--endpoints=https://127.0.0.1:2379` 与证书路径 |
| 只想加密部分资源 | resources 列表可多组 | 可分别对 secrets / configmaps 配不同 provider |

## 判分结果

```bash
# [master]
cd 07-cks/labs/08-encryption-at-rest
chmod +x check.sh
./check.sh
```

预期输出：

```
PASS: Secret encryption-configuration 存在于 kube-system
PASS: Secret 内容解码后含 aescbc provider
PASS: Secret 内容含 identity 兜底 provider
PASS: apiserver manifest 含 --encryption-provider-config
PASS: kube-apiserver 静态 Pod 为 Running
PASS: namespace cks-lab08 与 Secret credit-card 存在
PASS: apiserver 解密正常（读出明文卡号）
PASS: etcd 中该 key 为 aescbc 密文（k8s:enc:aescbc:v1:）
PASS: etcd 原始值中找不到卡号数据（base64 形式）

SCORE: 9/9
```

## 延伸阅读

- 加密 etcd 数据（官方）: https://kubernetes.io/zh-cn/docs/tasks/administer-cluster/encrypt-data/
- EncryptionConfiguration API: https://kubernetes.io/zh-cn/docs/reference/config-api/apiserver-encryption.v1/
