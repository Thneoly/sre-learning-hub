# Lab 09 · 解答 —— ImagePolicyWebhook：镜像准入后端模拟

## 背景：整条链路涉及的四样东西

```
(1) 证书: server.crt/server.key        后端 TLS 身份（apiserver 强制 https）
(2) kubeconfig: 后端的地址+CA           apiserver 怎么连后端
(3) AdmissionConfiguration: 插件参数    kubeConfigFile/allowTTL/denyTTL/defaultAllow
(4) apiserver flags:                    启用插件、指向配置、开 v1alpha1 API
```

与 Mutating/ValidatingAdmissionWebhook（动态、注册在 API 里）不同，ImagePolicyWebhook 是**静态配置**的内置插件：改的是文件与 apiserver 参数，不是 `ValidatingWebhookConfiguration` 对象。CKS 考试两者都可能考，别混。

## 步骤 1：生成自签证书

```bash
# [master]
sudo mkdir -p /etc/kubernetes/imagepolicy
sudo openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -keyout /etc/kubernetes/imagepolicy/server.key \
  -out /etc/kubernetes/imagepolicy/server.crt \
  -subj "/CN=imagepolicy.cks.local" \
  -addext "subjectAltName=DNS:imagepolicy.cks.local,IP:127.0.0.1"
```

> 后端地址用的是 `https://127.0.0.1:8899`，所以证书**必须带 `IP:127.0.0.1` 的 SAN**。只写 CN 的话，curl `--cacert` 会因主机名不匹配握手失败（`-s` 下表现为静默返回空），apiserver 的 webhook 客户端同样连不上。

## 步骤 2：编写并运行 mock 后端

```bash
# [master]
sudo tee /usr/local/bin/imagepolicy-webhook.py >/dev/null <<'EOF'
#!/usr/bin/env python3
"""模拟 ImagePolicyWebhook 后端：允许名单镜像，其余拒绝。"""
import json
import ssl
from http.server import BaseHTTPRequestHandler, HTTPServer

ALLOWED_PREFIXES = ("nginx:1.27", "busybox:1.36", "registry.k8s.io/")

class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length) if length else b"{}"
        body = json.loads(raw)
        spec = body.get("spec", {})
        images = [c.get("image", "") for c in spec.get("containers", [])]
        allowed = all(img.startswith(ALLOWED_PREFIXES) for img in images)
        reason = "image in allowlist" if allowed else "image not allowed: " + ",".join(images)
        resp = {
            "apiVersion": "imagepolicy.k8s.io/v1alpha1",
            "kind": "ImageReview",
            "status": {"allowed": allowed, "reason": reason},
        }
        payload = json.dumps(resp).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        print("imagepolicy-webhook: %s - %s" % (self.address_string(), fmt % args), flush=True)

if __name__ == "__main__":
    httpd = HTTPServer(("127.0.0.1", 8899), Handler)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain("/etc/kubernetes/imagepolicy/server.crt",
                        "/etc/kubernetes/imagepolicy/server.key")
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
    print("imagepolicy-webhook listening on https://127.0.0.1:8899", flush=True)
    httpd.serve_forever()
EOF
sudo chmod +x /usr/local/bin/imagepolicy-webhook.py
```

先手工跑起来并用 curl 验证：

```bash
# [master]
sudo /usr/local/bin/imagepolicy-webhook.py &   # 实验阶段前台/后台皆可

# deny 用例
curl -s --cacert /etc/kubernetes/imagepolicy/server.crt -X POST https://127.0.0.1:8899 \
  -d '{"apiVersion":"imagepolicy.k8s.io/v1alpha1","kind":"ImageReview","spec":{"containers":[{"image":"nginx:1.16"}],"namespace":"cks-lab09"}}'
# {"apiVersion": "imagepolicy.k8s.io/v1alpha1", "kind": "ImageReview",
#  "status": {"allowed": false, "reason": "image not allowed: nginx:1.16"}}

# allow 用例
curl -s --cacert /etc/kubernetes/imagepolicy/server.crt -X POST https://127.0.0.1:8899 \
  -d '{"apiVersion":"imagepolicy.k8s.io/v1alpha1","kind":"ImageReview","spec":{"containers":[{"image":"nginx:1.27"}],"namespace":"cks-lab09"}}'
# {"status": {"allowed": true, "reason": "image in allowlist"}, ...}
```

## 步骤 3：编写 kubeconfig（apiserver 视角）

```bash
# [master]
sudo tee /etc/kubernetes/imagepolicy/kubeconfig >/dev/null <<'EOF'
apiVersion: v1
kind: Config
clusters:
  - name: imagepolicy-backend
    cluster:
      certificate-authority: /etc/kubernetes/imagepolicy/server.crt
      server: https://127.0.0.1:8899
users:
  - name: apiserver-imagepolicy
    user: {}
contexts:
  - name: imagepolicy
    context:
      cluster: imagepolicy-backend
      user: apiserver-imagepolicy
current-context: imagepolicy
EOF
```

`users` 留空是因为 mock 后端不做客户端证书校验；生产上会配 `client-certificate`/`client-key` 做 mTLS。

## 步骤 4：AdmissionConfiguration

```bash
# [master]
sudo tee /etc/kubernetes/admission-imagepolicy.yaml >/dev/null <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: ImagePolicyWebhook
    configuration:
      imagePolicy:
        kubeConfigFile: /etc/kubernetes/imagepolicy/kubeconfig
        allowTTL: 50
        denyTTL: 50
        retryBackoff: 500
        defaultAllow: false
EOF
```

字段语义（官方文档）：

| 字段 | 作用 |
|---|---|
| `kubeConfigFile` | 指向上面这份 kubeconfig |
| `allowTTL` / `denyTTL` | 允许/拒绝结论的缓存秒数（减小后端压力） |
| `retryBackoff` | 后端失败重试间隔（毫秒） |
| `defaultAllow: false` | **fail-closed**：后端不可用时拒绝所有镜像 |

## 步骤 5（实战项）：接入 apiserver 并验证

建议先给 mock 后端做个 systemd 服务（保证 apiserver 起来时后端已就绪，避免 fail-closed 卡死整个部署）：

```bash
# [master]
sudo tee /etc/systemd/system/imagepolicy-webhook.service >/dev/null <<'EOF'
[Unit]
Description=Mock ImagePolicyWebhook backend
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/imagepolicy-webhook.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now imagepolicy-webhook
sudo systemctl status imagepolicy-webhook --no-pager | head -5
```

改 manifest（已备份）。编辑 `/etc/kubernetes/manifests/kube-apiserver.yaml`：

1. 找到现有的 `--enable-admission-plugins=NodeRestriction` 一行，改为：

```yaml
    - --enable-admission-plugins=NodeRestriction,ImagePolicyWebhook
```

2. 追加：

```yaml
    - --admission-control-config-file=/etc/kubernetes/admission-imagepolicy.yaml
    - --runtime-config=imagepolicy.k8s.io/v1alpha1=true
```

3. `volumeMounts` 与 `volumes` 追加（两个目录合并挂载也行，分开更清晰）：

```yaml
    - mountPath: /etc/kubernetes/imagepolicy
      name: imagepolicy-config
      readOnly: true
    - mountPath: /etc/kubernetes/admission-imagepolicy.yaml
      name: admission-imagepolicy
      readOnly: true
```

```yaml
  - hostPath:
      path: /etc/kubernetes/imagepolicy
      type: Directory
    name: imagepolicy-config
  - hostPath:
      path: /etc/kubernetes/admission-imagepolicy.yaml
      type: File
    name: admission-imagepolicy
```

验证：

```bash
# [master]
kubectl -n kube-system wait --for=condition=Ready pod -l component=kube-apiserver --timeout=300s

kubectl create ns cks-lab09
kubectl -n cks-lab09 run ok --image=nginx:1.27 --restart=Never   # 创建成功
kubectl -n cks-lab09 run bad --image=nginx:1.16 --restart=Never
# Error from server (Forbidden): pods "bad" is forbidden: image policy webhook backend denied one or more images: image not allowed: nginx:1.16
```

拒绝原因是后端回填的 `status.reason`——这是排障时判断"是插件拦的还是别的"的关键。

**验证完务必回滚**（模拟环境收尾）：

```bash
# [master]
sudo cp /etc/kubernetes/kube-apiserver.yaml.bak /etc/kubernetes/manifests/kube-apiserver.yaml
kubectl -n kube-system wait --for=condition=Ready pod -l component=kube-apiserver --timeout=300s
sudo systemctl disable --now imagepolicy-webhook   # 不再需要后端保活
```

## 模拟路径（不动 apiserver 时）

完成步骤 1~4 + 后端进程保持运行即可。判分脚本识别到 manifest 未启用插件时输出 `SIMULATED`，按证书/kubeconfig/AdmissionConfiguration/curl 行为给分。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 所有 Pod 创建被拒（包括系统组件） | fail-closed 且后端没起/证书不对 | 先修后端（systemd 保活），apiserver 会自动恢复；紧急时用备份 manifest 回滚 |
| curl 报证书校验失败 | 没带 `--cacert` 或证书 CN 不匹配 | 始终 `--cacert /etc/kubernetes/imagepolicy/server.crt` |
| apiserver 起不来 | flags 写错/挂载路径不存在 | 备份回滚；逐项核对 mountPath 与 hostPath |
| 改了 AdmissionConfiguration 不生效 | 该文件只在 apiserver 启动时读取 | 重启 apiserver 静态 Pod |
| deny 有缓存延迟 | denyTTL 缓存 | 实验把 TTL 调小（如 5）观察 |

## 判分结果

```bash
# [master]
cd 07-cks/labs/09-imagepolicy-webhook
chmod +x check.sh
./check.sh
```

实战模式（未回滚、后端运行中）：

```
MODE: full（apiserver 已启用 ImagePolicyWebhook）
PASS: 自签证书 server.crt/server.key 存在
PASS: server.crt 为合法证书（openssl 可解析）
PASS: kubeconfig 存在且 server 为 https://127.0.0.1:8899
PASS: kubeconfig 指定 certificate-authority
PASS: admission-imagepolicy.yaml 存在
PASS: AdmissionConfiguration 含 ImagePolicyWebhook 插件与 kubeConfigFile
PASS: imagePolicy 含 defaultAllow 与 TTL 配置
PASS: 后端拒绝 nginx:1.16（allowed:false）
PASS: 后端放行 nginx:1.27（allowed:true）
PASS: apiserver manifest 含 --enable-admission-plugins 且带 ImagePolicyWebhook
PASS: apiserver manifest 含 --runtime-config=imagepolicy.k8s.io/v1alpha1=true
PASS: kube-apiserver 静态 Pod 为 Running

SCORE: 12/12
```

模拟路径：

```
MODE: simulated（apiserver 未启用该插件，验证配置结构）
PASS: 自签证书 server.crt/server.key 存在
PASS: server.crt 为合法证书（openssl 可解析）
PASS: kubeconfig 存在且 server 为 https://127.0.0.1:8899
PASS: kubeconfig 指定 certificate-authority
PASS: admission-imagepolicy.yaml 存在
PASS: AdmissionConfiguration 含 ImagePolicyWebhook 插件与 kubeConfigFile
PASS: imagePolicy 含 defaultAllow 与 TTL 配置
PASS: 后端拒绝 nginx:1.16（allowed:false）
PASS: 后端放行 nginx:1.27（allowed:true）
SIMULATED: apiserver 未启用插件（替代验证路径），跳过 apiserver flags 检查
PASS: 模拟模式：证书/kubeconfig/AdmissionConfiguration/mock 后端结构完整

SCORE: 10/10
```

## 延伸阅读

- ImagePolicyWebhook 官方文档: https://kubernetes.io/zh-cn/docs/reference/access-authn-authz/admission-controllers/#imagepolicywebhook
- Admission controllers 概览: https://kubernetes.io/zh-cn/docs/reference/access-authn-authz/admission-controllers/
