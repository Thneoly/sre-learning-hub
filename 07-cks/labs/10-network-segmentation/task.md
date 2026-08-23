# Lab 10 · Namespace 间网络分段：默认拒绝 + 按需放开端口

> 难度：★★★ ｜ 考点：CKS-微服务隔离（NetworkPolicy） ｜ 前置：无 ｜ 预计 35~45 分钟

## 场景

一套三层 Web 应用要按安全域隔离，CNI 是 Calico（kubeadm 练习集群）：

- `cks-lab10-frontend`：接入层（busybox 客户端 `fe-client`，发起调用）；
- `cks-lab10-backend`：业务层（nginx `backend`，Service 端口 80）；
- `cks-lab10-db`：数据层（nginx `db`，Service 端口 80，模拟数据库端口）。

零信任要求：

1. 三个 namespace **默认拒绝**全部入站与出站流量（Ingress+Egress default-deny）；
2. DNS 必须始终可用（允许到 `kube-system` 的 `kube-dns` 53 端口，UDP+TCP）；
3. 按调用链最小化放行：frontend → backend 的 TCP 80；backend → db 的 TCP 80；
4. frontend **不能**直接访问 db（横向越权要被掐断）；外部进入三个 ns 的流量也全部被 default-deny 拦截。

## 任务清单

1. 创建三个 namespace（无需额外标签，网络策略用 Kubernetes 自动打的 `kubernetes.io/metadata.name` 标签匹配 namespace）。
2. 部署：`backend` 与 `db` 为 nginx:1.27 Pod + 同名 ClusterIP Service（port 80）；`fe-client` 为 busybox:1.36（`sleep 3600`）。
3. 在三个 ns 各创建 `default-deny-all` NetworkPolicy：`podSelector: {}`、`policyTypes: [Ingress, Egress]`、无 ingress/egress 规则。
4. 在三个 ns 各创建 `allow-dns` 策略：出站允许到 `kube-system` ns 中 `k8s-app: kube-dns` 的 Pod、UDP/TCP 53。
5. 创建 `allow-frontend-to-backend`（作用于 backend ns，入站来自 frontend ns 的 TCP 80）与 frontend ns 侧的对应出站放行；创建 `allow-backend-to-db`（作用于 db ns，入站来自 backend ns 的 TCP 80）与 backend ns 侧的对应出站放行。
6. 验证四组连通性：frontend→backend 通；backend→db 通；frontend→db **不通**（超时）；frontend→外部任意 IP（如 1.1.1.1:80）**不通**。

## 验收标准

- `kubectl -n <ns> get networkpolicy` 每个 ns 至少 2 条（default-deny-all + allow-dns），backend/db 各多 1 条入站放行
- `kubectl -n cks-lab10-frontend exec fe-client -- wget -q -T 3 -O- http://backend.cks-lab10-backend.svc.cluster.local` 返回 nginx 页面
- backend 内 `curl -s http://db.cks-lab10-db.svc.cluster.local` 成功（nginx 镜像没有 wget，用自带的 curl）
- frontend 内 `wget -T 3 http://db.cks-lab10-db.svc.cluster.local` 超时失败；`wget -T 3 http://1.1.1.1` 超时失败

运行判分脚本：

```bash
# [master]
cd 07-cks/labs/10-network-segmentation
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：default-deny 为什么 Ingress 和 Egress 都要写</summary>

NetworkPolicy 是"选中即白名单"：Pod 被任一策略选中后，未在规则中出现的方向默认拒绝。只写 `policyTypes: [Ingress]` 时出站完全不受限——恶意 Pod 仍可自由外联（exfiltration）。零信任要求双向都收口，再按需放行。
</details>

<details><summary>提示 2：跨 namespace 的 from/to 怎么写</summary>

`namespaceSelector` 匹配目标/来源 namespace。K8s 1.21+ 自动给每个 ns 打 `kubernetes.io/metadata.name=<ns名>` 标签，直接用它最稳。若还想叠加"只允许特定 Pod"，把 `namespaceSelector` 与 `podSelector` 写在**同一个** `from`/`to` 元素里（与关系）；写成两个元素则变成或关系，这是最常见的语义坑。
</details>

<details><summary>提示 3：DNS 为什么会"莫名"挂掉</summary>

default-deny Egress 一旦生效，UDP 53 出站也被拒，所有域名解析失败，表现为"连 Service 都 wget 不通"。所以放行业务流量前必须先放行 DNS——注意 kube-dns 的 Pod 在 `kube-system`，规则要同时写 `namespaceSelector`（kube-system）和 `podSelector`（k8s-app: kube-dns）。
</details>

<details><summary>提示 4：busybox 的 wget 超时怎么写</summary>

busybox wget 的 `-T 3` 是 3 秒网络超时；被策略 DROP 的包表现为超时（exit code 1），DNS 拒答则报 "bad address"。两者都算"不通"，但含义不同：前者证明策略生效，后者说明 DNS 被误伤。
</details>
