# Lab 04 · 解答：Ingress 按域名和路径路由

## 步骤 1：namespace 与两个后端

```bash
# [master]
kubectl create namespace lab04-ingress
```

```yaml
# [master] cat > shop-apps.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-web
  namespace: lab04-ingress
  labels:
    app: shop-web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: shop-web
  template:
    metadata:
      labels:
        app: shop-web
    spec:
      containers:
      - name: shop-web
        image: nginxdemos/hello:plain-text
        ports:
        - containerPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: shop-api
  namespace: lab04-ingress
  labels:
    app: shop-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: shop-api
  template:
    metadata:
      labels:
        app: shop-api
    spec:
      containers:
      - name: shop-api
        image: traefik/whoami
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: shop-web
  namespace: lab04-ingress
spec:
  type: ClusterIP
  selector:
    app: shop-web
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: shop-api
  namespace: lab04-ingress
spec:
  type: ClusterIP
  selector:
    app: shop-api
  ports:
  - port: 80
    targetPort: 80
EOF
kubectl apply -f shop-apps.yaml
```

为什么选这两个镜像：都监听 80 且返回"我是谁"（主机名/URI 等）的纯文本，一眼能看出请求最终落在哪个后端，是验证路由的利器。

验证：

```text
# [master]
$ kubectl -n lab04-ingress get deploy,svc
NAME                       READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/shop-api   2/2     2            2           30s
deployment.apps/shop-web   2/2     2            2           30s

NAME               TYPE        CLUSTER-IP      PORT(S)   AGE
service/shop-api   ClusterIP   10.96.201.11    80/TCP    30s
service/shop-web   ClusterIP   10.96.202.35    80/TCP    30s
```

## 步骤 2：Ingress

```yaml
# [master] cat > shop-ingress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop-ingress
  namespace: lab04-ingress
spec:
  ingressClassName: nginx
  rules:
  - host: shop.example.com
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: shop-api
            port:
              number: 80
      - path: /
        pathType: Prefix
        backend:
          service:
            name: shop-web
            port:
              number: 80
EOF
kubectl apply -f shop-ingress.yaml
```

为什么：

- `ingressClassName` 取代了旧注解 `kubernetes.io/ingress.class`，controller 只处理 class 匹配自己的 Ingress；
- `pathType: Prefix` 表示 `/api` 也匹配 `/api/v1`、`/api?x=1`；`ImplementationSpecific` 在 ingress-nginx 里行为同 Prefix；`Exact` 只匹配完整路径；
- ingress-nginx 匹配规则：先 host，再最长 path 前缀，所以 `/api` 优先于 `/`。

验证 controller 已 admit：

```text
# [master]
$ kubectl -n lab04-ingress get ingress shop-ingress
NAME           CLASS   HOSTS               ADDRESS         PORTS   AGE
shop-ingress   nginx   shop.example.com    172.30.30.21    80      20s
```

## 步骤 3：从集群外验证路由

找入口端口：

```bash
# [master]
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}{"\n"}'
# 例如输出 31080
```

请求验证（无 DNS，用 Host 头模拟）：

```bash
# [master]
curl -s -H 'Host: shop.example.com' http://127.0.0.1:31080/
```

```text
Server address: 10.244.0.21:80
Server name: shop-web-7d9b8c6f4-kv2mz
Date: 2026/08/22 02:11:03
URI: /
```

```bash
# [master]
curl -s -H 'Host: shop.example.com' http://127.0.0.1:31080/api
```

```text
{"hostname":"shop-api-6b7f9d8c5-t8p4l","ip":["127.0.0.1","::1","10.244.0.23"],"headers":{...,"X-Forwarded-Host":["shop.example.com"],...},"url":"/api","host":"shop.example.com","method":"GET","remoteAddr":"10.244.0.1:43210"}
```

注：whoami 新版镜像返回单行 JSON（`"hostname"` 字段）；旧版返回多行纯文本（`Hostname: ...`），两种都说明请求打到了 shop-api。

连续多次 curl `/api`，`hostname` 会在两个 shop-api Pod 间变化，说明 controller 到 Service 的负载均衡生效。

请求转发链路：

```text
curl -H Host ──> NodePort(31080) ──> ingress-nginx Pod
                  按 host/path 挑 backend ──> Service shop-api/shop-web ──> Pod
```

## 步骤 4：运行判分脚本

```bash
# [master]
cd 05-cka/labs/04-ingress-routes
chmod +x check.sh
./check.sh
```

通过结果：

```text
PASS: namespace lab04-ingress 存在且 Active
PASS: deployment shop-web 期望副本数为 2
PASS: deployment shop-web readyReplicas 为 2
PASS: deployment shop-api 期望副本数为 2
PASS: deployment shop-api readyReplicas 为 2
PASS: service shop-web 存在且 port 80
PASS: service shop-api 存在且 port 80
PASS: ingress shop-ingress 使用 ingressClassName nginx
PASS: host 为 shop.example.com
PASS: paths 为 /api 与 /
PASS: backend 顺序为 shop-api 与 shop-web
PASS: backend 端口均为 80
PASS: curl / 命中 shop-web（hello 镜像响应）
PASS: curl /api 命中 shop-api（whoami 镜像响应）

SCORE: 14/14
```

## 常见坑速查

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| `kubectl get ing` ADDRESS 为空 | class 不匹配 / controller 未运行 | 确认 `ingressClassName: nginx`；查 ingress-nginx Pod 日志 |
| curl 返回 404 default backend | host 头没带或 host 拼错 | `-H 'Host: shop.example.com'` |
| curl 返回 503 | backend Service 选不到 Pod | 查 `kubectl -n lab04-ingress get endpoints` |
| `/api` 也打到 shop-web | path 写成 `/api/` 或漏配 pathType 导致匹配差异 | 用 Prefix 且路径书写与验收一致 |

## 考点回顾

- Ingress 是七层路由规则，本身不做转发，真正干活的是 ingress controller；考试环境一般预装 controller，只需正确写 Ingress。
- 命名空间隔离：Ingress 与 backend Service 必须同 namespace（跨 ns 需要更复杂的手段，超出考试范围）。
- `kubectl -n <ns> describe ingress` 会打印 controller 生成的 nginx 配置片段摘要，排障首选。
