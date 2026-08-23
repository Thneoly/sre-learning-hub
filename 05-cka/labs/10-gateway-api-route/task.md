# Lab 10 · Gateway API：Gateway + HTTPRoute 路由

> 难度：★★★ ｜ 考点：CKA-网络（Gateway API 概念加分项 / 对照 Ingress） ｜ 前置：lab 04 ｜ 预计 35~50 分钟

## 场景

团队准备评估 Ingress 的下一代标准 Gateway API。测试集群要用 NGINX Gateway Fabric（NGINX 官方的 Gateway API 实现）搭一条最小可用链路：

- 门户站点 `portal-web`（镜像 `nginxdemos/hello:plain-text`，2 副本）：承接 `http://portal.example.com/`；
- 接口服务 `portal-api`（镜像 `traefik/whoami`，2 副本）：承接 `http://portal.example.com/api`；
- 入口由一个 `Gateway`（listener HTTP/80，gatewayClassName `nginx`）承担，路由规则写在 `HTTPRoute`（host `portal.example.com`）里；
- 最终用 `curl -H 'Host: portal.example.com' http://<节点IP>:<nodePort>/` 与 `/api` 验证两条规则分别命中。

## 前置安装（本 lab 需要额外组件，先执行）

集群默认没装 Gateway API。以下命令安装 Gateway API CRDs（standard channel）与 NGINX Gateway Fabric v2.5.1（含 NodePort 数据面变体，适配无 LoadBalancer 的练习集群）。版本号以官方文档为准：<https://docs.nginx.com/nginx-gateway-fabric/install/manifests/open-source/>

```bash
# [master] 1) Gateway API CRDs（约 1 分钟）
kubectl kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v2.5.1" | kubectl apply -f -

# [master] 2) NGINX Gateway Fabric 自身 CRDs
kubectl apply --server-side -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.5.1/deploy/crds.yaml

# [master] 3) 部署 controller（nodeport 变体：数据面 Service 默认 NodePort）
kubectl apply -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.5.1/deploy/nodeport/deploy.yaml

# [master] 4) 等待 controller 就绪
kubectl -n nginx-gateway wait deployment/nginx-gateway --for=condition=Available --timeout=120s
```

卸载（做完实验想清理时）：

```bash
# [master]
kubectl delete -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.5.1/deploy/nodeport/deploy.yaml
kubectl delete -f https://raw.githubusercontent.com/nginx/nginx-gateway-fabric/v2.5.1/deploy/crds.yaml
kubectl kustomize "https://github.com/nginx/nginx-gateway-fabric/config/crd/gateway-api/standard?ref=v2.5.1" | kubectl delete -f -
```

## 任务清单

1. 创建 namespace `lab10-gateway`。
2. 创建 Deployment+Service `portal-web`（2 副本，port 80）与 `portal-api`（2 副本，port 80）。
3. 创建 Gateway `web-gateway`（namespace `lab10-gateway`）：
   - `gatewayClassName: nginx`
   - 一个 listener：name `http`，port `80`，protocol `HTTP`
4. 创建 HTTPRoute `portal-route`（namespace `lab10-gateway`）：
   - `parentRefs` 指向上面这个 Gateway
   - hostnames：`portal.example.com`
   - 规则一：匹配 path 前缀 `/api`，backendRef `portal-api:80`
   - 规则二：默认规则（无 match，匹配全部），backendRef `portal-web:80`
5. 验证：Gateway 数据面 Service（`web-gateway-nginx`，NodePort）拿到 80 对应 nodePort 后，curl 验证两条路由。

## 验收标准

- `kubectl -n lab10-gateway get gateway web-gateway`：Programmed/Accepted 状态为 `True`（`kubectl describe` 看 conditions）
- `kubectl -n lab10-gateway get httproute portal-route` 已 attach 到 Gateway
- `curl -s -H 'Host: portal.example.com' http://<节点IP>:<nodePort>/` 返回含 `Server name` 的文本
- `curl -s -H 'Host: portal.example.com' http://<节点IP>:<nodePort>/api` 返回含 `hostname` 的文本（whoami 新版返回 JSON，字段为 `"hostname"`）

运行判分脚本：

```bash
# [master]
cd 05-cka/labs/10-gateway-api-route
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：Gateway / GatewayClass / HTTPRoute 三者关系</summary>

GatewayClass 描述"谁实现"（由 controller 安装时创建，本环境名 `nginx`）；Gateway 是"一个入口实例"（listener 定义监听端口与协议）；HTTPRoute 描述"路由规则"，通过 parentRefs 绑到某个 Gateway。对照 Ingress：Gateway ≈ controller 的 Service+实例，HTTPRoute ≈ Ingress 规则本体。
</details>

<details><summary>提示 2：parentRefs 怎么写</summary>

同 namespace 下只需 `group: gateway.networking.k8s.io`、`kind: Gateway`、`name: web-gateway`。HTTPRoute 与 backend Service 必须同 namespace（除非用 ReferenceGrant 跨 namespace 引用，本 lab 不需要）。
</details>

<details><summary>提示 3：入口地址在哪</summary>

创建 Gateway 后，NGINX Gateway Fabric 会为它生成数据面：Deployment `web-gateway-nginx` 与 Service `web-gateway-nginx`（nodeport 变体下 type NodePort）。80 端口对应的 nodePort 用：

```bash
# [master]
kubectl -n lab10-gateway get svc web-gateway-nginx \
  -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}{"\n"}'
```
</details>
