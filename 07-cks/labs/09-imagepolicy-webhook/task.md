# Lab 09 · ImagePolicyWebhook：镜像准入后端模拟

> 难度：★★★ ｜ 考点：CKS-供应链安全（ImagePolicyWebhook） ｜ 前置：无 ｜ 预计 40~50 分钟

## 前置安装（环境不具备时的替代验证方式见本节末尾）

本 lab 的 apiserver 集成部分需要：节点装有 `python3`（模拟后端）、`openssl`（自签证书）、可重启 kube-apiserver 静态 Pod 的 kubeadm 集群。安装检查：

```bash
# [master]
python3 --version && openssl version
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /etc/kubernetes/kube-apiserver.yaml.bak
```

**环境不具备时（不允许动 apiserver）的替代验证方式**：完成任务清单 1~4（证书、mock 后端、kubeconfig、AdmissionConfiguration 文件），跳过第 5 步的 manifest 修改；判分脚本检测到 apiserver 未启用该插件时，按"配置结构完整"给分并输出 `SIMULATED`。

## 场景

公司要求所有部署镜像必须经内部策略服务审批（允许名单内的镜像才准入）。K8s 原生机制是 `ImagePolicyWebhook` admission 插件：apiserver 对每个含镜像的 Pod 发起 `ImageReview` 请求给后端，按响应决定放行与否。你要搭一套最小可用的模拟环境——一个 Python 写的 HTTPS 后端 + 完整的插件配置链路，并搞懂它的失败语义（`defaultAllow`）：

```
kubectl run(pod with image)
   |
   v
apiserver --ImageReview(imagepolicy.k8s.io/v1alpha1)--> https://127.0.0.1:8899 (mock 后端)
   |                                                        | spec.containers[].image
   |<--------- {status: {allowed: true/false, reason}} ------+
   +-- false --> 拒绝创建（Forbidden: image ...）
```

## 任务清单

1. 生成自签证书（`/etc/kubernetes/imagepolicy/` 下 `server.crt` / `server.key`，CN=imagepolicy.cks.local，**必须带 `subjectAltName=DNS:imagepolicy.cks.local,IP:127.0.0.1`**——不带 IP SAN 时 curl `--cacert` 与 apiserver 的 webhook 客户端都会因主机名不匹配而握手失败，表现为 curl 静默返回空）。
2. 编写并运行 mock 后端 `/usr/local/bin/imagepolicy-webhook.py`：HTTPS 监听 127.0.0.1:8899，允许名单 `nginx:1.27`、`busybox:1.36`、`registry.k8s.io/` 前缀，其余返回 `allowed: false`。用 curl 验证 allow 与 deny 两种响应。
3. 编写 apiserver 侧 kubeconfig `/etc/kubernetes/imagepolicy/kubeconfig`：`certificate-authority` 指向上步证书，`server: https://127.0.0.1:8899`。
4. 编写 `/etc/kubernetes/admission-imagepolicy.yaml`（`kind: AdmissionConfiguration`，插件 `ImagePolicyWebhook` 内嵌 `imagePolicy` 配置：`kubeConfigFile`、`allowTTL/denyTTL/retryBackoff`、`defaultAllow: false`）。
5. （实战项）把 `--enable-admission-plugins=NodeRestriction,ImagePolicyWebhook`、`--admission-control-config-file=/etc/kubernetes/admission-imagepolicy.yaml`、`--runtime-config=imagepolicy.k8s.io/v1alpha1=true` 写入 apiserver 静态 Pod manifest 并挂载配置目录，重启后验证：`nginx:1.27` Pod 可创建、`nginx:1.16` Pod 被拒（错误含 image policy 拒绝原因）；**验证后按备份回滚**。

## 验收标准

- 三个配置文件（证书、kubeconfig、AdmissionConfiguration）结构完整、字段名正确
- mock 后端在 8899 端口可用：curl 测试 `nginx:1.16` 返回 `"allowed": false`，`nginx:1.27` 返回 `"allowed": true`
- 实战项完成时：apiserver manifest 含 `--admission-control-config-file` 且 apiserver Running；（模拟路径）manifest 未改动，check.sh 输出 SIMULATED

运行判分脚本（保持 mock 后端运行）：

```bash
# [master]
cd 07-cks/labs/09-imagepolicy-webhook
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：为什么必须 HTTPS</summary>

ImagePolicyWebhook 的 kubeconfig 强制 `https://` scheme（文档明说 backend 必须走 TLS），所以自签证书 + `certificate-authority` 指向该证书是最小配置。apiserver 侧可以不配客户端证书（后端不做 mTLS 校验），这也是本实验 mock 的简化点。
</details>

<details><summary>提示 2：defaultAllow 的语义</summary>

`defaultAllow: false` = fail-closed：后端挂了/超时，所有带镜像的 Pod 一律拒绝。生产上敢 fail-closed 的前提是后端高可用；本实验先启动 systemd 服务再改 apiserver，并在实验结束时回滚，避免后端一停整个集群无法部署。
</details>

<details><summary>提示 3：ImageReview 请求长什么样</summary>

apiserver POST 的 body 是 `{"apiVersion":"imagepolicy.k8s.io/v1alpha1","kind":"ImageReview","spec":{"containers":[{"image":"..."}],"namespace":"..."}}`；后端只需填 `status.allowed` 和可选 `status.reason` 回填同一对象。Pod 上 `*.image-policy.k8s.io/*` 注解会透传到 `spec.annotations`，可用于实现 break-glass。
</details>

<details><summary>提示 4：改 apiserver 前的保险</summary>

静态 Pod 改错会让集群不可用。务必先 `cp` 备份 manifest；实验后用 `sudo cp 备份 /etc/kubernetes/manifests/kube-apiserver.yaml` 回滚，等 Pod Running 再收工。
</details>
