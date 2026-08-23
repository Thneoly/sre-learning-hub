# Lab 17 · 解答：集群内 DNS 排查

## 机制回顾

```
Pod(dnsutils)                                 CoreDNS
  /etc/resolv.conf                              ├── kubernetes 插件: cluster.local 域
    nameserver 10.96.0.10   ─────────────────> │   (watch Service/Endpoint, 内存里出答案)
    search cka-dns.svc.cluster.local            └── forward . /etc/resolv.conf
            svc.cluster.local                       (集群外域名转发给节点上游)
            cluster.local
    options ndots:5
```

短名 `web-svc` 的解析过程：CoreDNS 依次用 search 域补全——`web-svc.cka-dns.svc.cluster.local` 先命中。所以"短名能用"依赖的是 **Pod 所在 namespace 与 search 域的第一条**。

## 第 1 步：部署 dnsutils 调试 Pod

```bash
# [master]
kubectl create namespace cka-dns
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: dnsutils
  namespace: cka-dns
spec:
  containers:
  - name: dnsutils
    image: registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3
    command: ["sleep", "infinity"]
EOF
kubectl -n cka-dns wait --for=condition=Ready pod/dnsutils --timeout=180s
```

镜像拉不动时见 task 提示 1（预拉或换 netshoot 镜像）。

## 第 2 步：解析系统 Service（基线）

```bash
# [master]
kubectl -n cka-dns exec dnsutils -- nslookup kubernetes.default
kubectl -n cka-dns exec dnsutils -- nslookup kubernetes.default.svc.cluster.local
kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}{"\n"}'
```

nslookup 预期输出：

```
Name:    kubernetes.default.svc.cluster.local
Address: 10.96.0.1
```

三者 ClusterIP 一致即基线通过——说明 kube-dns Service、CoreDNS、search 域补全全部正常。业务里的"服务名解析失败"若基线也挂，问题在 CoreDNS 层，直接跳第 5 步。

## 第 3 步：部署 web + web-svc 并解析

```bash
# [master]
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: cka-dns
spec:
  replicas: 1
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.27-alpine
---
apiVersion: v1
kind: Service
metadata:
  name: web-svc
  namespace: cka-dns
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
EOF
```

验证解析：

```bash
# [master]
kubectl -n cka-dns exec dnsutils -- nslookup web-svc
kubectl -n cka-dns exec dnsutils -- nslookup web-svc.cka-dns.svc.cluster.local
kubectl -n cka-dns get svc web-svc -o jsonpath='{.spec.clusterIP}{"\n"}'
```

预期两个 nslookup 都返回 web-svc 的 ClusterIP（如 `10.96.184.42`）。**若 FQDN 能解析而短名不能**，查 Pod 的 `/etc/resolv.conf`（第 5 步）；**若两者都不能**，查 web-svc 是否真的建出来了（名字拼错是最常见原因）。

## 第 4 步：Pod 级解析

```bash
# [master]
PODIP=$(kubectl -n cka-dns get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
echo "$PODIP"
kubectl -n cka-dns exec dnsutils -- nslookup "$(echo "$PODIP" | tr '.' '-').cka-dns.pod.cluster.local"
```

例如 Pod IP 为 `10.244.0.15` 时查询 `10-244-0-15.cka-dns.pod.cluster.local`，预期：

```
Name:    10-244-0-15.cka-dns.pod.cluster.local
Address: 10.244.0.15
```

注意 Pod 记录的域是 `pod.cluster.local`（不是 `svc`），且 IP 中 `.` 换 `-`。

## 第 5 步：检查 CoreDNS 与 resolv.conf

```bash
# [master]
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl get svc -n kube-system kube-dns
kubectl -n kube-system get endpoints kube-dns
kubectl -n kube-system get cm coredns -o yaml | less
```

Corefile 关键两块：

```
.:53 {
    errors
    health
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {   # 集群域由它接管
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
    }
    prometheus :9153
    forward . /etc/resolv.conf {                       # 其他域名转给节点上游
       max_concurrent 1000
    }
    cache 30
    loop
    reload
    loadbalance
}
```

`reload` 让改 Corefile 后无需删 Pod 即可生效（约 30s~1min）。再看 Pod 侧：

```bash
# [master]
kubectl -n cka-dns exec dnsutils -- cat /etc/resolv.conf
```

预期：

```
search cka-dns.svc.cluster.local svc.cluster.local cluster.local
nameserver 10.96.0.10
options ndots:5
```

`nameserver` 就是 kube-dns Service 的 ClusterIP；`ndots:5` 意味着名字里少于 5 个点的查询都会先走 search 域补全。

## 第 6 步：思考题答案

**为什么 `web-svc` 能解析而 `web` 不能？**
DNS 记录是为 **Service**（和 Pod IP）创建的，Deployment 只是控制器，不拥有任何 DNS 身份。`web` 查询会被 search 域补成 `web.cka-dns.svc.cluster.local`，CoreDNS 的 kubernetes 插件查无此 Service，遂 NXDOMAIN。访问 Deployment 的正确方式永远是"为它配一个 Service，再访问 Service 名"。

## DNS 故障速查

| 症状 | 常见原因 | 修法 |
| --- | --- | --- |
| nslookup 全部超时 | CoreDNS Pod 挂了 / kube-dns Service 无 endpoints | 看 Pod 日志与 endpoints，恢复 CoreDNS |
| FQDN 通、短名不通 | search 域异常（Pod dnsConfig 被改） | 恢复默认 dnsPolicy: ClusterFirst |
| 只有 pod.cluster.local 不通 | Corefile 的 `pods insecure` 被删/改 | 恢复 Corefile，靠 reload 生效 |
| 解析外部域名失败 | `forward . /etc/resolv.conf` 被改成坏上游 | 改回节点 resolv.conf 或指定可靠上游 |
| Service 有 IP 但解析不到 | Corefile 缺 `kubernetes cluster.local` 块 | 恢复 Corefile，删 Pod 让其重载 |

## 延伸阅读

- https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- https://kubernetes.io/docs/concepts/services-networking/dns-pod-service/

## check.sh 运行结果

```bash
# [master]
chmod 755 check.sh && ./check.sh
```

预期：

```
PASS: namespace cka-dns 存在
PASS: dnsutils Pod 为 Running
PASS: web Deployment availableReplicas=1
PASS: Service web-svc 有 ClusterIP(10.96.184.42)
PASS: nslookup kubernetes.default.svc.cluster.local 返回正确 ClusterIP(10.96.0.1)
PASS: nslookup web-svc.cka-dns.svc.cluster.local 返回正确 ClusterIP(10.96.184.42)
PASS: Pod 级解析 10-244-0-15.cka-dns.pod.cluster.local 返回 Pod IP
PASS: CoreDNS Pod(1 个)全部 Running
PASS: dnsutils 的 /etc/resolv.conf search 域包含 cka-dns.svc.cluster.local

SCORE: 9/9
```
