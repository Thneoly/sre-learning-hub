# 06 · Ingress 与 Gateway API：七层入口的资源模型与角色分离

> 模块：04-k8s-fundamentals ｜ 建议时长：4 小时 ｜ 关联认证：CKA-服务与网络（Ingress 是常客）/ —（Gateway API 暂无直接考点，属于新项目选型必备）

## 学习目标

- 能解释 Ingress 资源与 Ingress 控制器的分工：资源只是数据，控制器才是配置生成器与数据面
- 能操作 ingressClassName、pathType 三种语义、rewrite-target、TLS，并预测每个配置下的实际转发行为
- 能画出 Gateway API 的三层模型（GatewayClass / Gateway / HTTPRoute），解释它如何实现平台团队与应用团队的角色分离
- 能用 backendRefs 权重做流量拆分并实测比例
- 能对比 Ingress 与 Gateway API 的能力边界，为给定场景选型

## 1. Ingress 资源与控制器：资源只是数据

Service 解决的是四层稳定寻址，但生产入口几乎都是七层需求：按域名/路径路由、TLS 终止、重写、限流。Ingress 的设计哲学与 Service 一脉相承——**API 对象只声明"想要什么"，真正干活的是独立部署的控制器**：

```
┌── 数据（你写的） ─────────────────────────────────────────────┐
│ Ingress(host/path → Service) + IngressClass + TLS Secret      │
│              ▲ 创建/变更                                        │
└──────────────┼────────────────────────────────────────────────┘
               │ watch
┌──────────────┴────────────────────────────────────────────────┐
│ Ingress 控制器（Deployment，如 ingress-nginx）                 │
│  - 按 ingressClassName 过滤属于自己的 Ingress                   │
│  - 读取 Ingress + Endpoints + Secret → 生成 nginx.conf        │
│  - reload nginx（部分配置走 lua 动态生效）                       │
└──────────────┬────────────────────────────────────────────────┘
               │ 数据面
        客户端 ──► 控制器 Pod 的 80/443 ──► 按规则代理 ──► 后端 Pod
        （注意：Ingress 流量真的经过一个代理进程，与 Service 的 DNAT 本质不同）
```

推论：

- **没有控制器，Ingress 对象毫无作用**。`kubectl apply` 一个 Ingress 成功只说明 API server 收下了数据；`kubectl get ingress` 的 `ADDRESS` 列为空就代表没人认领。
- 控制器自己是"Deployment + Service"，外部流量先进控制器的 Service（NodePort/LoadBalancer/hostNetwork），再由 nginx 转发到后端 Service。
- Ingress 是**非命名空间级的集群行为**与命名空间资源的折中：对象在 ns 里，但它引用的 Service 必须同 ns。

```bash
# [master] 裸金属 kubeadm 安装 ingress-nginx（NodePort 模式）
# 版本号以官方 Installation 文档为准：https://kubernetes.github.io/ingress-nginx/deploy/
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.12.1/deploy/static/provider/baremetal/deploy.yaml
kubectl -n ingress-nginx wait --for=condition=Available deployment/ingress-nginx-controller --timeout=300s
kubectl -n ingress-nginx get svc,ingressclass
# NAME                       TYPE       CLUSTER-IP     PORT(S)                      AGE
# ingress-nginx-controller   NodePort   10.96.x.x      80:31xxx/TCP,443:32xxx/TCP   ...
# NAME                                          CONTROLLERS
# ingressclasses.networking.k8s.io/nginx        k8s.io/ingress-nginx
```

### 1.1 ingressClassName：把资源路由给正确的控制器

一个集群可以同时跑多个控制器（nginx、traefik、istio……）。匹配机制有两层：

- **IngressClass 对象**（集群级）：声明"这类入口由哪个控制器实现"，例如 `controller: k8s.io/ingress-nginx`。
- **Ingress 的 `spec.ingressClassName`**：指向某个 IngressClass。控制器只 watch 引用自己类的 Ingress。
- 旧写法 `kubernetes.io/ingress.class` 注解自 1.18 起被字段取代（已废弃），新代码不要再用。
- `ingressClassName` 留空时，控制器只认"带 `ingressclass.kubernetes.io/is-default-class: "true"` 注解的默认类"。

```bash
# [master] 实验后端：两个版本各 3 副本（http-echo 把 -text 参数原样返回, 便于区分流量落点）
kubectl create deployment echo-v1 --image=hashicorp/http-echo:1.0.0 --replicas=3 -- -text=hello-from-v1 -listen=:80
kubectl expose deployment echo-v1 --port=80 --target-port=80
kubectl create deployment echo-v2 --image=hashicorp/http-echo:1.0.0 --replicas=3 -- -text=hello-from-v2 -listen=:80
kubectl expose deployment echo-v2 --port=80 --target-port=80
kubectl wait --for=condition=Available deployment/echo-v1 deployment/echo-v2 --timeout=120s
kubectl get svc | grep echo
```

## 2. pathType 的三种语义与陷阱

v1 API 中 `pathType` 是**必填**字段。三种语义：

| pathType | 语义 | `/foo` 这条规则会匹配 | 不会匹配 |
|---|---|---|---|
| Exact | 完全相等（大小写敏感） | `/foo` | `/foo/`、`/foo/bar`、`/Foo` |
| Prefix | 按**路径段**前缀匹配 | `/foo`、`/foo/`、`/foo/bar` | `/foobar`（最后一段是子串不算）、`/fo` |
| ImplementationSpecific | 交给控制器解释 | ingress-nginx：配合 `use-regex: "true"` 时按 POSIX 正则解释 | — |

两条官方裁决规则：请求同时命中多条规则时，**Exact 优先于 Prefix**；同为 Prefix 时**路径更长的赢**（与规则创建顺序无关）。

陷阱清单：

- **Prefix 不是字符串前缀**。`/foo` 不会吃掉 `/foobar`——按段（`/` 分隔）比较。反过来，`/`（根 Prefix）匹配一切，catch-all 一定放最后、路径最短，自然优先级最低，不用排序技巧。
- **Exact 不管尾斜杠**。`/healthz` 配 Exact 时，负载均衡器发 `/healthz/` 会被拒；两者要想都通就写两条规则。
- **ImplementationSpecific 是逃生舱不是默认值**。只有需要正则（如 rewrite 捕获组、`~*` 大小写不敏感）时才用它；用了它，配置在 nginx/traefik/istio 之间不可移植。
- 匹配优先级靠语义不靠书写顺序，但同一规则内多个 path 的重叠要自己保证意图清晰。

```bash
# [master] 取 NodePort 备用
HTTP_NP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')
HTTPS_NP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}')
NODEIP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
```

```yaml
# [master] kubectl apply -f - <<'EOF' —— pathType 行为对照
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo-paths
  namespace: default
spec:
  ingressClassName: nginx
  rules:
  - host: echo.example.com
    http:
      paths:
      - path: /v1
        pathType: Prefix
        backend:
          service: {name: echo-v1, port: {number: 80}}
      - path: /exact
        pathType: Exact
        backend:
          service: {name: echo-v1, port: {number: 80}}
      - path: /
        pathType: Prefix
        backend:
          service: {name: echo-v2, port: {number: 80}}
EOF
```

```bash
# [master] 逐条验证语义（--resolve 让 curl 把域名解析到本节点 NodePort）
curl -s --resolve echo.example.com:$HTTP_NP:$NODEIP http://echo.example.com:$HTTP_NP/            # v2（/ 兜底）
curl -s --resolve echo.example.com:$HTTP_NP:$NODEIP http://echo.example.com:$HTTP_NP/v1          # v1（Prefix）
curl -s --resolve echo.example.com:$HTTP_NP:$NODEIP http://echo.example.com:$HTTP_NP/v1/sub      # v1（子路径）
curl -s --resolve echo.example.com:$HTTP_NP:$NODEIP http://echo.example.com:$HTTP_NP/v10        # v2！（不是 /v1 的子串）
curl -s -o /dev/null -w '%{http_code}\n' --resolve echo.example.com:$HTTP_NP:$NODEIP \
  http://echo.example.com:$HTTP_NP/exact/                                                       # 404（Exact 不带尾斜杠）
```

## 3. rewrite-target 与路径改写

后端往往不知道自己被挂在了子路径下：`/app` 转发到后端时，后端期待的路径是 `/`。ingress-nginx 用注解 + 捕获组解决：

```yaml
# [master] kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo-rewrite
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2   # 用第 2 个捕获组替换整个路径
spec:
  ingressClassName: nginx
  rules:
  - host: rewrite.example.com
    http:
      paths:
      - path: /app(/|$)(.*)          # 第 1 组: /app 或 /app 结束边界; 第 2 组: 其余部分
        pathType: ImplementationSpecific   # 路径含正则元字符, 必须声明为控制器私有语义
        backend:
          service: {name: echo-v1, port: {number: 80}}
EOF
```

```bash
# [master] 验证改写：后端收到的 URI 已从 /app/... 变成 /...
curl -s --resolve rewrite.example.com:$HTTP_NP:$NODEIP http://rewrite.example.com:$HTTP_NP/app/foo
curl -s --resolve rewrite.example.com:$HTTP_NP:$NODEIP http://rewrite.example.com:$HTTP_NP/app
# /app 匹配 (/|$) 的 "$" 分支, $2 为空 → 后端收到 /
```

要点与陷阱：

- `rewrite-target` 是 **ingress-nginx 的注解**，不是 Ingress 标准字段——这就是"标注蔓延"问题的典型样本，也是 Gateway API 要标准化它的原因之一。
- 捕获组编号按 path 里的括号顺序数。path 含正则时 `pathType` 必须写 `ImplementationSpecific`（或额外加 `use-regex: "true"` 注解），否则校验/匹配行为不保证。
- 只想改"进入目录"的行为时，`configuration-snippet`/`app-root`（`/` → 301 到 `/app/`）比 rewrite 更贴切；rewrite 影响所有匹配请求。
- 改写后后端生成的绝对链接（重定向、静态资源引用）仍会指向旧路径——应用侧需支持子路径部署（`X-Forwarded-Prefix` 头可辅助）。

## 4. TLS：终止在控制器，后端走 HTTP

Ingress 的 TLS 是"终止"语义：客户端 HTTPS → 控制器解密 → 控制器到后端 Service 仍是 HTTP（要端到端加密需后端本身支持 TLS 或用 mTLS 方案）。

```bash
# [master] 自签证书 + Secret（type 必须是 kubernetes.io/tls，字段名 tls.crt/tls.key）
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /tmp/echo-tls.key -out /tmp/echo-tls.crt \
  -subj "/CN=echo.example.com"
kubectl create secret tls echo-tls --key /tmp/echo-tls.key --cert /tmp/echo-tls.crt
rm -f /tmp/echo-tls.key /tmp/echo-tls.crt
```

```yaml
# [master] kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo-tls
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"   # HTTP 强制 301 到 HTTPS
spec:
  ingressClassName: nginx
  tls:
  - hosts: [echo.example.com]
    secretName: echo-tls          # 必须与 Ingress 同 namespace
  rules:
  - host: echo.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service: {name: echo-v1, port: {number: 80}}
EOF
```

```bash
# [master] 验证证书与重定向
curl -sI --resolve echo.example.com:$HTTP_NP:$NODEIP http://echo.example.com:$HTTP_NP/ | head -3   # 301
curl -sk --resolve echo.example.com:$HTTPS_NP:$NODEIP https://echo.example.com:$HTTPS_NP/          # hello-from-v1
openssl s_client -connect "$NODEIP:$HTTPS_NP" -servername echo.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -enddate
# subject=CN = echo.example.com
```

未配置 TLS 的 Ingress 走控制器的默认自签证书（Kubernetes Ingress Controller Fake Certificate），浏览器告警但能握手——看到这张假证书通常说明 SNI/hosts 没匹配上。

## 5. Gateway API：三层模型与角色分离

Ingress 的两个结构性缺陷：能力被注解放大得面目全非（rewrite、canary、超时全是各家私有注解）；且"入口地址/证书"和"路由规则"捏在同一资源里，平台团队和应用团队被迫共享一个对象的读写权。Gateway API 用**三层对象**重新切分：

```
┌───────────────────────────────────────────────────────────────────┐
│ GatewayClass（集群级，平台/基础设施团队定义）                         │
│   controller: gateway.envoyproxy.io/gatewayclass-controller        │
│   说明"实现这类入口的是哪个控制器"，相当于驱动注册表                  │
└────────────▲──────────────────────────────────────────────────────┘
             │ spec.gatewayClassName（引用）
┌────────────┴──────────────────────────────────────────────────────┐
│ Gateway（命名空间级，平台团队创建）                                  │
│   listeners: 80/HTTP、443/TLS(引用证书 Secret)                      │
│   allowedRoutes: 哪些 namespace 的 Route 可以挂上来                 │
│   status.addresses: 控制器产出的真实 IP/端口（LB 由它申请）           │
└────────────▲──────────────────────────────────────────────────────┘
             │ HTTPRoute 的 spec.parentRefs（引用 + 逐条 status 审批）
┌────────────┴──────────────────────────────────────────────────────┐
│ HTTPRoute（命名空间级，应用团队创建）                                │
│   hostnames + matches(host/path/header) + backendRefs(自己的 SVC)  │
└───────────────────────────────────────────────────────────────────┘
```

角色分离落在三个机制上：

1. **谁拥有什么**：平台团队持有 GatewayClass/Gateway 的 RBAC（管 IP、证书、全局策略）；应用团队在自己 namespace 里创建 HTTPRoute（只管路由），互相看不见对方对象。
2. **跨 namespace 的显式授权**：HTTPRoute 挂到别的 ns 的 Gateway，需要 Gateway 的 `allowedRoutes` 放行；HTTPRoute 引用别的 ns 的 Service 作后端，需要对方 ns 里的 `ReferenceGrant` 放行。默认全部拒绝。
3. **双向 status**：HTTPRoute 的 `parentRefs` 有 Accepted/ResolvedRefs 条件，Gateway 是否接纳一眼可见——不像 Ingress 那样"创建了但不通只能翻控制器日志"。

```bash
# [master] 安装 Gateway API CRDs 与 Envoy Gateway（版本以官方 Quickstart 为准）
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.1/standard-install.yaml
kubectl apply --server-side -f https://github.com/envoyproxy/gateway/releases/download/v1.2.4/install.yaml
kubectl -n envoy-gateway-system wait --for=condition=Available deploy --all --timeout=300s
kubectl get gatewayclass   # eg 已就绪
```

```yaml
# [master] kubectl apply -f - <<'EOF' —— 平台团队视角：Gateway
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: lab-gw
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: SameNamespace      # 只允许本 ns 的 Route 挂载；AllNamespaces 需显式放开
EOF
```

```yaml
# [master] kubectl apply -f - <<'EOF' —— 应用团队视角：HTTPRoute
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo-route
  namespace: default
spec:
  parentRefs:
  - name: lab-gw                 # 挂到哪个 Gateway
  hostnames: ["gw.example.com"]
  rules:
  - matches:
    - path:
        type: PathPrefix          # Gateway API 用枚举, 不再有 ImplementationSpecific
        value: /
    backendRefs:
    - name: echo-v1
      port: 80
EOF
```

```bash
# [master] 裸金属：Envoy 的 Service 默认 LoadBalancer，改成 NodePort 访问
ENVOY_SVC=$(kubectl -n default get svc -l gateway.envoyproxy.io/owning-gateway-name=lab-gw -o jsonpath='{.items[0].metadata.name}')
kubectl -n default patch svc "$ENVOY_SVC" -p '{"spec":{"type":"NodePort"}}'
GW_PORT=$(kubectl -n default get svc "$ENVOY_SVC" -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
curl -s -H 'Host: gw.example.com' "http://$NODEIP:$GW_PORT/"        # hello-from-v1
kubectl get httproute echo-route -o jsonpath='{.status.parents[0].conditions}' | head -c 300; echo
# type=Accepted status=True：Gateway 已接纳（角色分离下的"验收回执"）
```

## 6. backendRefs 权重：标准化的流量拆分

Gateway API 把灰度/金丝雀做进了核心规范：同一条 rule 里多个 backendRefs 按 `weight` 相对值分流（缺省 1，`0` 表示不接新流量但保留在池里）。

```yaml
# [master] kubectl apply -f - <<'EOF' —— 90/10 灰度
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo-split
  namespace: default
spec:
  parentRefs:
  - name: lab-gw
  hostnames: ["gw.example.com"]
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: echo-v1
      port: 80
      weight: 90
    - name: echo-v2
      port: 80
      weight: 10
EOF
```

```bash
# [master] 实测比例（期望约 90/10）
for i in $(seq 1 40); do
  curl -s -H 'Host: gw.example.com' "http://$NODEIP:$GW_PORT/"
done | sort | uniq -c
# 36 hello-from-v1
#  4 hello-from-v2

# 全量切流：把 v1 的 weight 改成 0（保留规则, 可秒级回切）
kubectl patch httproute echo-split --type=json \
  -p='[{"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":0}]'
for i in $(seq 1 10); do curl -s -H 'Host: gw.example.com' "http://$NODEIP:$GW_PORT/"; done | sort | uniq -c
# 10 hello-from-v2
```

对照：Ingress 体系里同样的事要靠 ingress-nginx 的 `canary` 注解（`canary-weight: 10` + 独立的 canary Ingress），属于单控制器私有扩展；Gateway API 的权重是跨实现一致的规范行为。

## 7. Ingress vs Gateway API 对比

| 维度 | Ingress | Gateway API |
|---|---|---|
| 协议 | 基本只有 HTTP(S)；TCP/UDP/QUIC 要靠私有注解或别的方法 | HTTPRoute/GRPCRoute/TLSRoute/TCPRoute/UDPRoute 统一建模 |
| 扩展方式 | 控制器私有 annotation（不可移植） | 规范字段 + 标准化扩展点（policy attachment） |
| 角色分离 | 无：入口与路由在同一对象 | 三层对象 + allowedRoutes/ReferenceGrant 显式授权 |
| 流量管理 | 基本路由 + 各家私有 canary | 权重拆分、header/path 匹配、超时重试进规范 |
| 跨 namespace | 不支持（Service 必须同 ns） | parentRefs/backendRefs 均可跨 ns，需授权 |
| 状态反馈 | 无（ADDRESS 列而已） | Route/Gateway 分层 conditions |
| API 稳定性 | networking.k8s.io/v1，GA 多年 | Gateway/GatewayClass/HTTPRoute v1（GA）；其余渐进 |
| 生态现状 | 存量巨大，所有控制器都支持 | 主流控制器（Envoy Gateway、NGINX Gateway Fabric、Istio、Traefik、Cilium）均已实现 |

选型建议：存量维护与考试（CKA）以 Ingress 为准；新项目/多团队共享平台优先 Gateway API；同一集群两者可并存（各占各的端口/IP）。

```bash
# [master] 清理本章实验
kubectl delete ingress echo-paths echo-rewrite echo-tls --ignore-not-found
kubectl delete httproute echo-route echo-split --ignore-not-found
kubectl delete gateway lab-gw --ignore-not-found
kubectl delete deploy echo-v1 echo-v2 --ignore-not-found
kubectl delete svc echo-v1 echo-v2 --ignore-not-found
kubectl delete secret echo-tls --ignore-not-found
```

## 实战演练

各节动手内容串成一条完整实验流（前置：节点能拉取 quay.io / registry.k8s.io / Docker Hub 镜像）：

1. 部署 ingress-nginx（NodePort）与两个 echo 后端 → 第 1 节
2. 创建 pathType 对照 Ingress，用 5 条 curl 验证 Prefix/Exact/兜底的裁决规则 → 第 2 节
3. 加 rewrite Ingress，验证 `/app/foo` 被后端收到时已是 `/foo` → 第 3 节
4. 自签证书建 TLS Ingress，验证 HTTP 301 跳转与 SNI 命中的证书 → 第 4 节
5. 安装 Gateway API CRDs + Envoy Gateway，建 Gateway/HTTPRoute，Service 改 NodePort 后 curl 通，检查 `status.parents.conditions` 为 Accepted → 第 5 节
6. 权重 90:10 灰度，40 次请求统计比例约 36:4；再 patch `weight=0` 全量切到 v2 并秒级回切 → 第 6 节
7. 对照第 7 节表格回答"自家集群该选哪个"，最后执行第 7 节末尾的清理

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| Ingress 创建成功但 `ADDRESS` 为空、完全不通 | 没装控制器，或 `ingressClassName` 与控制器不匹配 | `kubectl get ingressclass`；核对 spec.ingressClassName |
| 预期 `/v1` 会接住 `/v10`（或反之担心误匹配） | 误以为 Prefix 是字符串前缀 | 实际按段匹配，`/v1` 本就不匹配 `/v10`；确要匹配数字编号就写正则（ImplementationSpecific） |
| rewrite 后后端 404 | 捕获组编号算错，或 pathType 不是 ImplementationSpecific | 用 `/app(/|$)(.*)` + `/$2` 模板；对照控制器日志里 rewrite 后的 URI |
| TLS 握手拿到 "Fake Certificate" | tls.hosts 与请求 Host/SNI 不一致，或 secretName 拼错 | `openssl s_client -servername` 复现；确认 Secret 与 Ingress 同 ns 且类型为 kubernetes.io/tls |
| Gateway 一直无地址/status Programmed=False | GatewayClass 没有控制器认领（CRD 装了没装实现） | `kubectl get gatewayclass -o wide` 看 CONTROLLER；先装实现（如 Envoy Gateway） |
| HTTPRoute 创建成功但不生效 | parentRefs 指错 Gateway；或目标 ns 被 `allowedRoutes` 拒绝 | 看 `kubectl get httproute -o yaml` 的 status.parents.conditions（Accepted/ResolvedRefs） |
| 裸金属上 Envoy/Gateway 的 Service 一直 pending | 默认 LoadBalancer 类型，无云控制器 | patch 成 NodePort（或装 MetalLB） |
| 老集群升级后 annotation 版 Ingress 告警 | `kubernetes.io/ingress.class` 注解已废弃 | 迁移到 `spec.ingressClassName` |

## 自测

<details><summary>1. 没有安装任何 Ingress 控制器的集群里创建 Ingress 对象会发生什么？为什么 kubectl 不报错？</summary>

创建会成功——Ingress 只是 API server 里的一份数据，校验器只检查字段合法性，不检查有没有消费者。后果是对象静静躺着：`kubectl get ingress` 的 ADDRESS 为空、没有任何规则被下发。这体现了"资源与控制器解耦"的设计：API 是双方之间的契约，控制器是可选的、可替换的实现。排障第一步永远是确认"谁在消费这个对象"。
</details>

<details><summary>2. 同时定义了 `/foo`（Prefix，指向 A）和 `/foo/bar`（Prefix，指向 B）。请求 `/foo/bar/x` 打到谁？请求 `/foo/barbaz` 呢？</summary>

`/foo/bar/x` 命中两条 Prefix，按"最长路径优先"裁决，走 B。`/foo/barbaz` 按**段**比较：请求的段是 `foo`、`barbaz`，`/foo/bar` 的段是 `foo`、`bar`，`barbaz != bar`，所以只匹配 `/foo`，走 A。两个答案都与规则书写顺序无关，这正是 pathType 语义标准化（相对 Ingress 时代的各自为政）的意义。
</details>

<details><summary>3. 为什么 rewrite-target 配正则捕获时 pathType 必须是 ImplementationSpecific？把这段配置从 nginx 迁到 traefik 会发生什么？</summary>

因为 `(/|$)(.*)` 不是合法的"Exact/Prefix"语义——标准只认字面路径段，含正则元字符的 path 超出了规范能表达的范围，只能交给控制器私有解释。迁移后果：traefik 对 ImplementationSpecific 的实现（字符串前缀 + 自己的 Match/Rule 语法体系）与 nginx 的 POSIX 正则不同，同一段配置转发行为会变。可移植的写法是只用 Exact/Prefix + 各家标准的 header/path 匹配，正则只作为最后手段。
</details>

<details><summary>4. 应用团队在自己 ns 里建的 HTTPRoute 要挂到平台 ns 的 Gateway 上，需要哪些授权？反向的 backendRefs 跨 ns 又需要什么？</summary>

挂载方向：HTTPRoute.spec.parentRefs 指向那个 Gateway，同时 Gateway 的 listener 必须用 allowedRoutes 放行应用 ns（namespaces.from: Selector/AllNamespaces + from: SameNamespace 默认拒绝）。后端方向：HTTPRoute 引用别的 ns 的 Service 时，那个 ns 里必须存在对应的 ReferenceGrant（允许 from 应用 ns 的 HTTPRoute to Services）。两边都是"资源可以建，但效果要被显式批准"，且批准结果体现在 HTTPRoute 的 status.conditions 里。
</details>

<details><summary>5. 权重 90:10 的灰度跑了一天后要全量切到 v2 但保留秒级回切能力，怎么做最稳？为什么不用改 Service 的 selector？</summary>

把 v1 的 backendRefs.weight 从 90 patch 成 0（保留 v2 的 10 或提额均可）：v1 不再接新流量但规则还在，回切就是把数字改回去，一次 API 调用生效。不推荐改 Service selector 来摘 Pod：那是"销毁后端"而非"切流"，滚动窗口里的存量连接处理、脚本化程度、审计粒度都差；且 selector 改动影响所有引用该 Service 的对象，不只这一条路由。
</details>

<details><summary>6. Ingress 和 Service 都叫"入口"，数据面的本质区别是什么？</summary>

Service 是 netfilter 规则做的四层 DNAT（1:1 改写，没有进程在路径上，客户端源 IP 保留）；Ingress 控制器（以及 Gateway 的数据面）是真实的七层代理进程——连接在它这里终结再重建，能看到并改写 HTTP 语义（host/path/header/重定向/压缩），也因此客户端看到的源 IP 是控制器 Pod，需要 X-Forwarded-For 之类头部传递真实来源。理解这一层区别，"为什么七层功能做不到 Service 上"就不言自明了。
</details>

## 延伸阅读

- Ingress 官方概念：https://kubernetes.io/docs/concepts/services-networking/ingress/
- IngressClass 与 ingressClassName：https://kubernetes.io/docs/concepts/services-networking/ingress/#ingress-class
- ingress-nginx 用户指南（annotations 全表）：https://kubernetes.github.io/ingress-nginx/
- rewrite-target 示例：https://kubernetes.github.io/ingress-nginx/examples/rewrite/
- Gateway API 官方站（规范与实现列表）：https://gateway-api.sigs.k8s.io/
- Envoy Gateway Quickstart：https://gateway.envoyproxy.io/docs/latest/tasks/quickstart/
- Gateway API 角色与安全模型：https://gateway-api.sigs.k8s.io/concepts/security-model/
