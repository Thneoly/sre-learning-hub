# Lab 20 · 解答：综合恢复演练

## 总览：三个故障的因果链

```
故障注入:
  A. Corefile: forward . 127.0.0.1   ──> 外部域名解析失败(集群域仍通!)
  B. systemctl stop kubelet          ──> 节点 NotReady, Pod 上报中断
  C. 删除 ClusterRoleBinding         ──> 监控 SA 的 can-i 变 no

恢复顺序建议: 先 B(API/节点稳定) -> 再 A(DNS) -> 最后 C(RBAC)
理由: B 影响"节点与 Pod 状态上报", 会给 A/C 的验证制造噪声(如 CoreDNS reload、dnsutils 状态)。
```

真实事故里多故障叠加的排障原则：**先恢复"承载面"（kubelet/网络），再恢复"功能面"（DNS/RBAC）**，每修一个就重新对基线验证一次。

## Phase 0：基线复核（要点）

```bash
# [master]
kubectl -n cka-drill exec dnsutils -- nslookup kubernetes.default
# Name: kubernetes.default.svc.cluster.local  Address: 10.96.0.1
kubectl auth can-i get pods --as=system:serviceaccount:cka-drill:monitor
# yes
kubectl get nodes
# NAME   Ready   control-plane   ...
```

三条基线是后面每一步的"回滚对照点"。

## 症状 1：DNS 解析失败

诊断（分四层走）：

```bash
# [master] Pod 侧 resolv.conf 正常吗
kubectl -n cka-drill exec dnsutils -- cat /etc/resolv.conf
# nameserver 10.96.0.10, search cka-drill.svc.cluster.local ... 正常

# [master] CoreDNS 活着吗
kubectl -n kube-system get pods -l k8s-app=kube-dns
# Running, 不是 Pod 的问题

# [master] CoreDNS 日志: 谁在报错
kubectl -n kube-system logs deploy/coredns --tail=20
```

关键观察：`nslookup kubernetes.default` **可能仍然成功**（集群域由 kubernetes 插件在进程内应答，不走 forward），而 `nslookup www.example.com` 失败。这就是交接记录里"时好时坏"的真相——不是抖动，是**两类域名走不同路径**。证据落盘：

```bash
# [master]
kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' | grep forward
# forward . 127.0.0.1    <-- 上游指向本机回环, 没有任何 DNS 服务在听
```

恢复：

```bash
# [master]
kubectl -n kube-system get cm coredns -o json \
  | sed 's|forward \. 127.0.0.1|forward . /etc/resolv.conf|' \
  | kubectl apply -f -
```

Corefile 里的 `reload` 插件会让配置在约 30s~1min 内热加载；等不及就强制：

```bash
# [master]
kubectl -n kube-system rollout restart deploy coredns
kubectl -n kube-system rollout status deploy coredns --timeout=120s
```

验证：

```bash
# [master]
kubectl -n cka-drill exec dnsutils -- nslookup kubernetes.default
kubectl -n cka-drill exec dnsutils -- nslookup www.example.com   # 外部域也恢复
```

## 症状 2：节点 NotReady

```bash
# [master]
kubectl get nodes
# NAME        NotReady   control-plane ...
systemctl status kubelet
# Active: inactive (dead)
sudo journalctl -u kubelet -n 50 --no-pager
# 只有 Stopped 记录, 无 cert/config 报错 -> 服务被停, 不是配置坏
```

恢复：

```bash
# [master]
sudo systemctl start kubelet
sudo journalctl -u kubelet -f     # 等到 Successfully registered node 后 Ctrl-C
```

验证：

```bash
# [master]
kubectl get nodes                 # Ready
kubectl -n kube-system get pods   # kube-apiserver 等 static Pod 仍 Running(容器没死过)
```

细节：kubelet 停止时 static Pod 的**容器**仍在运行（容器由 containerd 托管），受影响的是状态上报与新建容器能力——所以故障 B 期间 CoreDNS 的 reload 机制仍可能正常工作，这就是"故障互相掩盖"的例子。

## 症状 3：can-i 变 no

```bash
# [master]
kubectl get clusterrolebinding | grep drill
# (空) 绑定没了
kubectl get clusterrole drill-pod-reader
# 还在 -> 只需重建绑定, 不用重建 Role
kubectl -n cka-drill get sa monitor
# 还在
```

恢复（重放 Phase 0 的那段 YAML）：

```bash
# [master]
cat <<'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: drill-monitor-pods
subjects:
- kind: ServiceAccount
  name: monitor
  namespace: cka-drill
roleRef:
  kind: ClusterRole
  name: drill-pod-reader
  apiGroup: rbac.authorization.k8s.io
EOF
```

验证：

```bash
# [master]
kubectl auth can-i get pods --as=system:serviceaccount:cka-drill:monitor
# yes
kubectl auth can-i --list --as=system:serviceaccount:cka-drill:monitor | head -5
# 只有 pods get/list/watch, 无多余权限
```

## Phase 3：全量验证

```bash
# [master]
kubectl -n cka-drill exec dnsutils -- nslookup kubernetes.default   # 解析出 10.96.0.1
kubectl auth can-i get pods --as=system:serviceaccount:cka-drill:monitor   # yes
kubectl get nodes                                                    # Ready
kubectl -n kube-system get pods -l k8s-app=kube-dns                  # Running
```

## 复盘清单（照抄进你的演练报告）

| 故障 | 第一证据 | 恢复动作 | 验证 |
| --- | --- | --- | --- |
| A Corefile 上游坏 | `get cm coredns` 的 forward 行 / coredns logs 转发失败 | sed 改回 + reload/restart | 内外部域名均可解析 |
| B kubelet 停 | `systemctl status kubelet` inactive + journalctl 无配置错 | `systemctl start kubelet` | node Ready |
| C RBAC 绑定被删 | `get clusterrolebinding` 缺失而 ClusterRole 仍在 | 重 apply ClusterRoleBinding | can-i yes 且无多余权限 |

防复发建议：Corefile 纳入 GitOps 管理（改 ConfigMap 走 PR）；kubelet 与容器运行时配置做 systemd 单元与文件完整性监控；RBAC 变更开审计日志（CKS 模块会深入）。

## 延伸阅读

- https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/
- https://kubernetes.io/docs/reference/access-authn-authz/authorization/

## check.sh 运行结果

```bash
# [master]
chmod 755 check.sh && ./check.sh
```

预期：

```
PASS: namespace cka-drill 存在
PASS: dnsutils Pod 为 Running
PASS: Corefile 上游已恢复为 /etc/resolv.conf
PASS: Corefile 无坏上游残留
PASS: CoreDNS Pod(1 个)全部 Running
PASS: dnsutils 内 nslookup kubernetes.default 解析正确(10.96.0.1)
PASS: kubelet 服务为 active
PASS: 节点 cka-node1 为 Ready
PASS: ClusterRoleBinding drill-monitor-pods 存在
PASS: 绑定关系正确(SA cka-drill/monitor -> drill-pod-reader)
PASS: monitor SA can-i get pods = yes(授权已恢复)

SCORE: 11/11
```
