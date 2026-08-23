# Lab 10 · 解答 —— Namespace 间网络分段：默认拒绝 + 按需放开端口

## 背景：目标拓扑与策略叠加语义

```
                    (放行: TCP 80)          (放行: TCP 80)
 fe-client  ───────────────>  backend  ───────────────>  db
 [cks-lab10-frontend]        [cks-lab10-backend]        [cks-lab10-db]
      |  DNS 53 --> kube-dns (kube-system)  <-- 三条 allow-dns
      |  其余出站: 全拒（含外网 1.1.1.1）
      +-- frontend -> db: 无规则 --> 被拒
```

NetworkPolicy 两条铁律：

1. **选中即白名单**：Pod 一旦被任何策略选中，未写明的方向/流量默认拒绝；
2. **策略叠加取并集**：多条策略对同一 Pod 的放行规则合并，default-deny 不会"抵消"其他策略的 allow——因此"先全拒、再补 allow"的标准做法是安全的。

## 步骤 1：创建 namespace 与工作负载

```bash
# [master]
kubectl create ns cks-lab10-frontend
kubectl create ns cks-lab10-backend
kubectl create ns cks-lab10-db

kubectl -n cks-lab10-backend run backend --image=nginx:1.27 --restart=Never
kubectl -n cks-lab10-backend expose pod backend --port=80 --target-port=80

kubectl -n cks-lab10-db run db --image=nginx:1.27 --restart=Never
kubectl -n cks-lab10-db expose pod db --port=80 --target-port=80

kubectl -n cks-lab10-frontend run fe-client --image=busybox:1.36 --restart=Never -- sleep 3600

kubectl -n cks-lab10-backend get pod,svc
kubectl -n cks-lab10-db get pod,svc
```

等三个 Pod 都 Running 再进下一步。

## 步骤 2：default-deny-all（三个 ns 各一份）

```yaml
# [master] default-deny-all.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: cks-lab10-frontend   # 依次换成 backend / db，共 apply 三次
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
```

`podSelector: {}` = 选中 ns 内**全部** Pod；没有 `ingress`/`egress` 字段 = 两个方向什么都不放行。

```bash
# [master]
for NS in cks-lab10-frontend cks-lab10-backend cks-lab10-db; do
  sed "s/cks-lab10-frontend/$NS/" default-deny-all.yaml | kubectl apply -f -
done
kubectl -n cks-lab10-frontend get networkpolicy
```

此刻业务全断（连 DNS 都不通）——这就是下一步必须先做 DNS 的原因。

## 步骤 3：allow-dns（三个 ns 各一份）

```yaml
# [master] allow-dns.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns
  namespace: cks-lab10-frontend   # 依次换成 backend / db
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
          podSelector:
            matchLabels:
              k8s-app: kube-dns
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

```bash
# [master]
for NS in cks-lab10-frontend cks-lab10-backend cks-lab10-db; do
  sed "s/cks-lab10-frontend/$NS/" allow-dns.yaml | kubectl apply -f -
done
```

两个细节：

- `namespaceSelector` 与 `podSelector` 写在**同一个** `to` 元素里是与关系（kube-system 里且标签为 kube-dns）；拆成两个元素是或关系，会放开整个 kube-system；
- TCP 53 也要放：UDP 53 丢包时 DNS 客户端会回落 TCP，漏掉会造成偶发解析失败。

## 步骤 4：调用链放行

放行是**双向配合**的：入站策略写在接受方，出站策略写在发起方（default-deny Egress 后两端都要有规则才通）。

backend ns 侧（入站）：

```yaml
# [master] allow-frontend-to-backend.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
  namespace: cks-lab10-backend
spec:
  podSelector:
    matchLabels:
      run: backend            # kubectl run 自动打的标签
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: cks-lab10-frontend
      ports:
        - protocol: TCP
          port: 80
```

frontend ns 侧（出站）：

```yaml
# [master] allow-egress-to-backend.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-backend
  namespace: cks-lab10-frontend
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: cks-lab10-backend
      ports:
        - protocol: TCP
          port: 80
```

db 侧（入站）与 backend 侧（出站）同理：

```yaml
# [master] allow-backend-to-db.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-backend-to-db
  namespace: cks-lab10-db
spec:
  podSelector:
    matchLabels:
      run: db
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: cks-lab10-backend
      ports:
        - protocol: TCP
          port: 80
```

```yaml
# [master] allow-egress-to-db.yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-egress-to-db
  namespace: cks-lab10-backend
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: cks-lab10-db
      ports:
        - protocol: TCP
          port: 80
```

```bash
# [master]
kubectl apply -f allow-frontend-to-backend.yaml -f allow-egress-to-backend.yaml \
              -f allow-backend-to-db.yaml -f allow-egress-to-db.yaml
```

## 步骤 5：连通性矩阵验证

```bash
# [master]
# 1) 放行链路通
kubectl -n cks-lab10-frontend exec fe-client -- \
  wget -q -T 5 -O- http://backend.cks-lab10-backend.svc.cluster.local | head -3
# 注意：nginx 镜像里没有 wget（只有 curl），backend 侧用 curl 探测
kubectl -n cks-lab10-backend exec backend -- \
  curl -s -m 5 http://db.cks-lab10-db.svc.cluster.local | head -3

# 2) 横向越权被拒（约 5 秒超时后退出码非 0）
kubectl -n cks-lab10-frontend exec fe-client -- \
  wget -q -T 5 -O /dev/null http://db.cks-lab10-db.svc.cluster.local
# wget: download timed out

# 3) 出站外网被拒
kubectl -n cks-lab10-frontend exec fe-client -- wget -q -T 5 -O /dev/null http://1.1.1.1
# wget: download timed out
```

四组结果与验收标准一一对应：default-deny（3+4 项证明）、DNS 放行（第 1 项能解析出 Service 名证明）、按链路放行（第 1 项）、无规则即不通（2、3 项）。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 全部 wget 报 bad address | Egress 收口后 DNS 被误伤 | 补 allow-dns（UDP+TCP 53） |
| 加了 allow 还是通不了 | 发起方在 default-deny Egress 下没出站规则 | 双端都要写：入站在接受方、出站在发起方 |
| namespaceSelector 不生效 | 手写 ns 标签拼错 | 用自动标签 `kubernetes.io/metadata.name` |
| 把 namespaceSelector/podSelector 写成两个 from 元素 | 变成"或"，放行范围过大 | 合并进同一个 from/to 元素 |
| 删了策略还是不通 | Calico 规则同步延迟或 Pod 需重连 | 等 5~10 秒重试；`calicoctl` 不在本 lab 范围 |
| 想限制只到某端口仍全通 | ports 写在 `to` 同级的位置错 | ports 必须和 `to` 并列在同一个 egress 规则里 |

## 清理（可选）

```bash
# [master]
kubectl delete ns cks-lab10-frontend cks-lab10-backend cks-lab10-db
```

## 判分结果

```bash
# [master]
cd 07-cks/labs/10-network-segmentation
chmod +x check.sh
./check.sh
```

预期输出：

```
PASS: namespace cks-lab10-frontend 存在
PASS: namespace cks-lab10-backend 存在
PASS: namespace cks-lab10-db 存在
PASS: Pod fe-client 为 Running
PASS: Pod backend 为 Running 且 Service 存在
PASS: Pod db 为 Running 且 Service 存在
PASS: cks-lab10-frontend 有 default-deny-all（Ingress+Egress）
PASS: cks-lab10-backend 有 default-deny-all（Ingress+Egress）
PASS: cks-lab10-db 有 default-deny-all（Ingress+Egress）
PASS: cks-lab10-frontend 有 allow-dns（53 端口出站到 kube-dns）
PASS: cks-lab10-backend 有 allow-dns（53 端口出站到 kube-dns）
PASS: cks-lab10-db 有 allow-dns（53 端口出站到 kube-dns）
PASS: backend ns 有 allow-frontend-to-backend（TCP 80）
PASS: db ns 有 allow-backend-to-db（TCP 80）
PASS: frontend -> backend:80 放行
PASS: backend -> db:80 放行
PASS: frontend -> db:80 被拒（超时）
PASS: frontend -> 外网 1.1.1.1:80 被拒（超时）

SCORE: 18/18
```

## 延伸阅读

- NetworkPolicy 官方文档: https://kubernetes.io/zh-cn/docs/concepts/services-networking/network-policies/
- 默认拒绝策略声明: https://kubernetes.io/zh-cn/docs/concepts/services-networking/network-policies/#default-deny-all-ingress-and-all-egress-traffic
- Calico 策略（GlobalNetworkPolicy 等）: https://docs.tigera.io/calico/latest/network-policy
