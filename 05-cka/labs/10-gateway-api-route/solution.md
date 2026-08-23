# Lab 10 · 解答：Gateway API（Gateway + HTTPRoute）

## 步骤 0：安装 Gateway API 与 NGINX Gateway Fabric

（命令见 task.md"前置安装"，逐条执行并等 controller Available。）

安装产物对照：

```bash
# [master]
kubectl -n nginx-gateway get pods,gatewayclass
kubectl get crd | grep gateway.networking.k8s.io
```

- CRD 五件套：`gateways` / `httproutes` / `gatewayclasses` / `grpcroutes` / `referencegrants`（standard channel）；
- `GatewayClass/nginx` 由 deploy.yaml 创建——它声明"这个集群里 Gateway API 由 NGF 实现"。

架构图：

```text
                 GatewayClass(nginx)  <-- 谁来实现（NGF controller，ns nginx-gateway）
                        |
   Gateway web-gateway  |  listener http/80     <-- 一个入口实例（触发 NGF 部署数据面）
                        |
   HTTPRoute portal-route                      <-- 路由规则（host + path -> backend）
        |            |
   svc portal-web  svc portal-api
```

## 步骤 1：namespace 与两个后端

```bash
# [master]
kubectl create namespace lab10-gateway
```

```yaml
# [master] cat > portal-apps.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portal-web
  namespace: lab10-gateway
  labels:
    app: portal-web
spec:
  replicas: 2
  selector:
    matchLabels:
      app: portal-web
  template:
    metadata:
      labels:
        app: portal-web
    spec:
      containers:
      - name: portal-web
        image: nginxdemos/hello:plain-text
        ports:
        - containerPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: portal-api
  namespace: lab10-gateway
  labels:
    app: portal-api
spec:
  replicas: 2
  selector:
    matchLabels:
      app: portal-api
  template:
    metadata:
      labels:
        app: portal-api
    spec:
      containers:
      - name: portal-api
        image: traefik/whoami
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: portal-web
  namespace: lab10-gateway
spec:
  type: ClusterIP
  selector:
    app: portal-web
  ports:
  - port: 80
    targetPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: portal-api
  namespace: lab10-gateway
spec:
  type: ClusterIP
  selector:
    app: portal-api
  ports:
  - port: 80
    targetPort: 80
EOF
kubectl apply -f portal-apps.yaml
```

与 lab 04 的后端一致（换了名字）：hello 返回 `Server name: ...`，whoami 返回 `Hostname: ...`，用于肉眼区分路由命中。

## 步骤 2：Gateway

```yaml
# [master] cat > web-gateway.yaml <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gateway
  namespace: lab10-gateway
spec:
  gatewayClassName: nginx
  listeners:
  - name: http
    port: 80
    protocol: HTTP
EOF
kubectl apply -f web-gateway.yaml
```

创建后 NGF 立刻行动：为这个 Gateway 拉起数据面 Deployment `web-gateway-nginx` 和 Service `web-gateway-nginx`（nodeport 变体下类型为 NodePort）。等状态就绪：

```bash
# [master]
kubectl -n lab10-gateway wait gateway/web-gateway \
  --for=condition=Programmed --timeout=120s 2>/dev/null \
  || kubectl -n lab10-gateway describe gateway web-gateway
kubectl -n lab10-gateway get deploy,svc
```

```text
NAME                          READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/portal-api    2/2     2            2           3m
deployment.apps/portal-web    2/2     2            2           3m
deployment.apps/web-gateway-nginx   1/1     1            1           40s

NAME                       TYPE       CLUSTER-IP      PORT(S)        AGE
service/portal-api         ClusterIP  10.96.214.30    80/TCP         3m
service/portal-web         ClusterIP  10.96.150.194   80/TCP         3m
service/web-gateway-nginx  NodePort   10.96.233.104   80:31789/TCP   40s
```

## 步骤 3：HTTPRoute

```yaml
# [master] cat > portal-route.yaml <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: portal-route
  namespace: lab10-gateway
spec:
  parentRefs:
  - name: web-gateway
  hostnames:
  - portal.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /api
    backendRefs:
    - name: portal-api
      port: 80
  - backendRefs:
    - name: portal-web
      port: 80
EOF
kubectl apply -f portal-route.yaml
```

规则语义：

- 第一条 rule 带 `matches`（PathPrefix `/api`），优先匹配；
- 第二条 rule 不写 `matches` = 全匹配（兜底），流量进 `portal-web`——与 Ingress 里 `/` 的角色相同，但表达力更强（match 可按 header/query/method 组合）；
- `parentRefs` 把规则"附着"到 Gateway；一个 HTTPRoute 可挂多个 parent，一个 Gateway 也可承载多条 Route（多对多）。

验证 attach 与解析：

```bash
# [master]
kubectl -n lab10-gateway get httproute portal-route
```

```text
NAME            HOSTNAMES              AGE
portal-route    ["portal.example.com"] 30s
```

`describe httproute` 的 Conditions 里 `AttachedToParents: True`、`ResolvedRefs: True` 表示 parent 与 backend 都解析成功；如果 backendRef 写错名字，ResolvedRefs 会变 False 并给出原因。

## 步骤 4：端到端验证

取 nodePort 与节点 IP：

```bash
# [master]
NP=$(kubectl -n lab10-gateway get svc web-gateway-nginx \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
NODE=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "http://${NODE}:${NP}"
```

请求：

```bash
# [master]
curl -s -H 'Host: portal.example.com' "http://${NODE}:${NP}/"
```

```text
Server address: 10.244.0.51:80
Server name: portal-web-6f8c9d7b4-t9wqz
URI: /
```

```bash
# [master]
curl -s -H 'Host: portal.example.com' "http://${NODE}:${NP}/api"
```

```text
{"hostname":"portal-api-7d4b8c5f6-p3v7k","ip":["127.0.0.1","::1","10.244.0.53"],"headers":{...,"X-Forwarded-Host":["portal.example.com"],...},"url":"/api","host":"portal.example.com","method":"GET","remoteAddr":"10.244.0.1:41230"}
```

注：whoami 新版镜像返回单行 JSON（`"hostname"` 字段）；旧版返回多行纯文本（`Hostname: ...`），两种都说明请求打到了 portal-api。

两条规则各自命中，多次请求 `hostname`/`Server name` 在两个副本间轮换。对照 lab 04：同样的拓扑（域名+路径 → Service），Ingress 用一条对象表达，Gateway API 拆成 Gateway（基础设施角色）与 HTTPRoute（应用角色），这正是它"角色分离"的设计目标——平台团队管 Gateway，业务团队管 HTTPRoute，互不踩脚。

## 步骤 5：运行判分脚本

```bash
# [master]
cd 05-cka/labs/10-gateway-api-route
chmod +x check.sh
./check.sh
```

通过结果：

```text
PASS: crd httproutes.gateway.networking.k8s.io 已安装
PASS: namespace lab10-gateway 存在且 Active
PASS: deployment portal-web 期望副本数为 2
PASS: deployment portal-web readyReplicas 为 2
PASS: deployment portal-api 期望副本数为 2
PASS: deployment portal-api readyReplicas 为 2
PASS: gateway web-gateway 存在
PASS: gatewayClassName 为 nginx
PASS: listener 端口为 80
PASS: listener 协议为 HTTP
PASS: gateway Accepted 条件为 True
PASS: httproute portal-route 存在
PASS: parentRef 指向 gateway web-gateway
PASS: hostname 为 portal.example.com
PASS: match 路径前缀为 /api
PASS: backendRefs 为 portal-api 与 portal-web
PASS: backend 端口均为 80
PASS: 数据面 service web-gateway-nginx 在 80 端口有 nodePort(31789)
PASS: curl / 命中 portal-web
PASS: curl /api 命中 portal-api

SCORE: 20/20
```

## 常见坑速查

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| Gateway 一直无 status | controller 没起来 / GatewayClass 名不符 | `kubectl -n nginx-gateway get pods`；确认 `gatewayClassName: nginx` |
| HTTPRoute 20 秒后仍不生效 | backendRef 的 Service 名/端口写错 | `describe httproute` 看 ResolvedRefs |
| curl 返回 404 | Host 头缺失或 hostnames 拼错 | `-H 'Host: portal.example.com'` |
| Service `web-gateway-nginx` 没出现 | Gateway 未提交成功（YAML 字段拼错） | `kubectl -n lab10-gateway get gateway -o yaml` 逐字段核对 |

## 考点回顾

- CKA 当前考纲仍以 Ingress 为主，Gateway API 是加分的视野项；核心记忆点是三类对象的职责分层与 parentRefs/backendRefs 的绑定关系。
- 跨 namespace 引用 Service 需要 ReferenceGrant；同 namespace 无需（本 lab 情形）。
- Gateway API 版本演进快（v1.0 GA 后 CRD 按 release channel 发布），实验前以官方文档核对版本：<https://gateway-api.sigs.k8s.io/> 与 <https://docs.nginx.com/nginx-gateway-fabric/>。
