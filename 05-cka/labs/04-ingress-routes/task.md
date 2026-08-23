# Lab 04 · Ingress 按域名和路径路由

> 难度：★★☆ ｜ 考点：CKA-网络（Ingress） ｜ 前置：lab 03 ｜ 预计 25~40 分钟

## 场景

商城中台准备把两个内部服务挂到同一个域名 `shop.example.com` 下：

- 前端页面：Deployment `shop-web`（镜像 `nginxdemos/hello:plain-text`，会返回文本形式的服务器信息，2 副本）
- 订单接口：Deployment `shop-api`（镜像 `traefik/whoami`，同样返回文本自描述信息，2 副本）

要求通过 ingress-nginx 统一入口：

- 访问 `http://shop.example.com/` 命中 `shop-web`；
- 访问 `http://shop.example.com/api` 命中 `shop-api`；
- Ingress 名为 `shop-ingress`，使用 `ingressClassName: nginx`，两条 path 都用 `pathType: Prefix`；
- 两个后端 Service 同名（`shop-web`、`shop-api`），port 80。

集群已由 scripts/setup 装好 ingress-nginx（controller 在 `ingress-nginx` namespace，Service `ingress-nginx-controller` 为 NodePort）。

## 任务清单

1. 创建 namespace `lab04-ingress`。
2. 创建 Deployment `shop-web`（labels `app=shop-web`）和 Deployment `shop-api`（labels `app=shop-api`），各 2 副本，containerPort 80。
3. 为两者分别创建 ClusterIP Service（port 80 → targetPort 80）。
4. 创建 Ingress `shop-ingress`：
   - `ingressClassName: nginx`
   - host `shop.example.com`
   - `/api`（Prefix）→ `shop-api:80`；`/`（Prefix）→ `shop-web:80`
5. 验证：拿到 ingress-nginx 的 NodePort，用 `curl -H 'Host: shop.example.com'` 分别请求 `/` 和 `/api`，确认响应来自不同后端（看返回文本的特征字段）。

## 验收标准

- `kubectl -n lab04-ingress get ingress shop-ingress` 的 HOSTS 列为 `shop.example.com`，ADDRESS 列有值（controller 已 admit）
- `curl -H 'Host: shop.example.com' http://<节点IP>:<ingress-nodePort>/` 返回文本含 `Server name`（hello 镜像）
- `curl ... /api` 返回文本含 `hostname`（whoami 镜像；新版返回 JSON，字段为 `"hostname"`），且多次请求 hostname 变化（负载均衡生效）

运行判分脚本：

```bash
# [master]
cd 05-cka/labs/04-ingress-routes
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：Ingress YAML 骨架</summary>

关键字段：`spec.ingressClassName`、`spec.rules[].host`、`spec.rules[].http.paths[]`（path / pathType / backend.service.name / backend.service.port.number）。`/api` 要写在 `/` 前面（ingress-nginx 按最长前缀匹配，顺序其实不强制，但写清楚更易读）。
</details>

<details><summary>提示 2：怎么找到入口地址</summary>

```bash
# [master]
kubectl -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}{"\n"}'
```
拿到的端口配合任意节点 IP 即可访问。测试环境没有 DNS，用 `-H 'Host: ...'` 头模拟域名解析即可。
</details>
