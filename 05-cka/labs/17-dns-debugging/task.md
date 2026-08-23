# Lab 17 · 集群内 DNS 排查
> 难度：★★ ｜ 考点：CKA-排错（Service DNS / CoreDNS） ｜ 前置：kubeadm 集群（CoreDNS）已就绪 ｜ 预计 35 分钟
> 运行位置：kubectl 操作在 [master]；所有验证都在集群内的调试 Pod 里完成

## 场景

业务方反馈："在 Pod 里用服务名互访时好时坏，现在干脆 `curl web-svc` 直接报 `Name or service not known`。" 你需要用标准的 dnsutils 调试 Pod 验证 Service DNS 解析链路，逐层确认：Service 名解析、FQDN 解析、Pod 级解析，以及 CoreDNS 自身的健康与配置。

## 任务清单

1. 创建 namespace `cka-dns`，并在其中创建调试 Pod `dnsutils`（用下面这份 YAML，镜像 `registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3`，`sleep infinity` 常驻）：

```yaml
# [master] kubectl apply -n cka-dns -f dnsutils.yaml
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
```

2. 在 dnsutils 里解析**系统 Service**：`nslookup kubernetes.default` 与 `nslookup kubernetes.default.svc.cluster.local`，两者都应返回 `kubernetes` Service 的 ClusterIP（自己核对 `kubectl get svc kubernetes`）。
3. 部署业务测试对象：Deployment `web`（image `nginx:1.27-alpine`，1 replica）+ 同名 Service `web-svc`（port 80，selector 自配），然后在 dnsutils 里 `nslookup web-svc` 与 `nslookup web-svc.cka-dns.svc.cluster.local`，应返回 web-svc 的 ClusterIP。
4. 做**Pod 级解析**：取 web Pod 的 IP（如 `10.244.0.15`），在 dnsutils 里 `nslookup 10-244-0-15.cka-dns.pod.cluster.local`，应返回该 Pod IP（注意 IP 中的 `.` 要换成 `-`）。
5. 检查 CoreDNS 本身：`kube-system` 里 `k8s-app=kube-dns` 的 Pod 是否 Running；读取 Corefile（`kubectl -n kube-system get cm coredns -o yaml`），找到 `kubernetes cluster.local` 声明块和上游 `forward` 行；最后在 dnsutils 里 `cat /etc/resolv.conf`，确认 search 域包含 `cka-dns.svc.cluster.local svc.cluster.local cluster.local` 且有 `ndots:5`。
6. 回答：为什么短名 `web-svc` 能解析而 `web`（Deployment 名）不能？（solution 有答案）

## 验收标准

- dnsutils Pod `Running`，web Deployment `1/1`。
- `nslookup kubernetes.default.svc.cluster.local` 返回 kubernetes Service 的 ClusterIP。
- `nslookup web-svc.cka-dns.svc.cluster.local` 返回 web-svc 的 ClusterIP。
- 能解释 Pod /etc/resolv.conf 的 search 域与 CoreDNS 的关系。

## 提示（卡住再看）

<details><summary>提示 1：镜像拉不动</summary>

`registry.k8s.io` 在部分网络环境较慢，可先在节点上预拉：`sudo crictl pull registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3`。若仍不可达，换用任一含 `nslookup` 的镜像（如 `nicolaka/netshoot`）等价完成本 lab。

</details>

<details><summary>提示 2：Pod DNS 的两种记录</summary>

- Service：`<svc>.<ns>.svc.cluster.local` → ClusterIP
- Pod：`<ip 把 . 换成 ->.<ns>.pod.cluster.local` → Pod IP

短名能省略的只有同 namespace 内的 Service 名（靠 search 域补全），Deployment 名根本没有 DNS 记录。

</details>

<details><summary>提示 3：解析失败时的分层排查</summary>

```
Pod resolv.conf 指向的是 kube-dns Service(10.96.0.10)
   ├── kubectl -n kube-system get pods -l k8s-app=kube-dns   # CoreDNS 活着吗
   ├── kubectl get svc kube-dns -n kube-system               # Service 有 ClusterIP 吗
   ├── kubectl -n kube-system get endpoints kube-dns         # 有后端地址吗
   └── kubectl -n kube-system logs deploy/coredns            # 查询报错在哪一层
```

</details>
