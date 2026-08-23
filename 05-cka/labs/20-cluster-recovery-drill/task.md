# Lab 20 · 综合恢复演练：三重故障
> 难度：★★★ ｜ 考点：CKA-综合（DNS / kubelet / RBAC 联合排障） ｜ 前置：lab 12、13、16、17 ｜ 预计 50 分钟
> 运行位置：kubectl 在 [master]；故障 2 的恢复需 ssh 到 **master 节点**（单节点集群，kubelet 就在 master 上）

## 场景

月度演练日。值班同事半夜留了一条交接记录："做完变更后集群怪怪的——DNS 时好时坏，监控 SA 的 can-i 变 no 了，节点还闪过一次 NotReady。" 你的任务：先搭好演练资产并记录基线，再一次性注入三个故障，然后**按 check-list 逐个诊断、恢复、验证**，最后全绿收工。

## Phase 0：搭建基线（约 5 分钟）

1. 创建 namespace `cka-drill`，部署以下资产并确认全部健康：

```bash
# [master]
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: monitor
  namespace: cka-drill
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: drill-pod-reader
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
---
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
---
apiVersion: v1
kind: Pod
metadata:
  name: dnsutils
  namespace: cka-drill
spec:
  containers:
  - name: dnsutils
    image: registry.k8s.io/e2e-test-images/jessie-dnsutils:1.3
    command: ["sleep", "infinity"]
EOF
```

2. 记录三条基线（每条都应通过）：

```bash
# [master]
kubectl -n cka-drill exec dnsutils -- nslookup kubernetes.default   # 能解析
kubectl auth can-i get pods --as=system:serviceaccount:cka-drill:monitor   # yes
kubectl get nodes                                                     # Ready
```

## Phase 1：注入故障（一次性注入，顺序执行）

```bash
# [master] 故障 A: CoreDNS 上游被改坏(等效 scripts/faults/break-dns-config.sh)
kubectl -n kube-system get cm coredns -o json \
  | sed 's|forward \. /etc/resolv.conf|forward . 127.0.0.1|' \
  | kubectl apply -f -

# [master] 故障 B: kubelet 被停(等效 scripts/faults/break-kubelet.sh)
sudo systemctl stop kubelet

# [master] 故障 C: 监控 SA 的授权被误删(等效 scripts/faults/break-rbac.sh)
kubectl delete clusterrolebinding drill-monitor-pods
```

注入后等待约 1 分钟（CoreDNS reload 生效 + node lifecycle 探测周期），再开始 Phase 2。**不要**在注入前背答案——先看症状再查。

## Phase 2：check-list 式诊断恢复

对每个症状，按"现象 → 证据 → 恢复 → 验证"四步处理：

- [ ] 症状 1：`nslookup kubernetes.default` 失败
      证据：`kubectl -n kube-system logs deploy/coredns`（注意报错域名是**外部域名**转发失败还是集群域失败，决定你查 Corefile 的哪一行）；`kubectl -n kube-system get cm coredns -o yaml`
      恢复：把 Corefile 的 forward 行改回 `forward . /etc/resolv.conf`
      验证：nslookup 恢复正常（reload 生效最长约 1 分钟，等不到就 `kubectl -n kube-system rollout restart deploy coredns`）
- [ ] 症状 2：节点 NotReady / Pod Unknown
      证据：`systemctl status kubelet`、`sudo journalctl -u kubelet -n 50 --no-pager`（ssh 到 master）
      恢复：`sudo systemctl start kubelet`
      验证：`kubectl get nodes` 回到 Ready
- [ ] 症状 3：`can-i` 变 no
      证据：`kubectl get clusterrolebinding | grep drill`（空的）；`kubectl auth can-i --list --as=system:serviceaccount:cka-drill:monitor`
      恢复：重建 Phase 0 的 ClusterRoleBinding（注意 ClusterRole `drill-pod-reader` 还在，只需恢复绑定）
      验证：can-i 回到 yes

## Phase 3：全量验证

```bash
# [master]
kubectl -n cka-drill exec dnsutils -- nslookup kubernetes.default
kubectl auth can-i get pods --as=system:serviceaccount:cka-drill:monitor
kubectl get nodes
kubectl -n kube-system get pods -l k8s-app=kube-dns
```

四条全部通过即演练结束。

## 验收标准

- CoreDNS 的 Corefile 恢复为 `forward . /etc/resolv.conf`，CoreDNS Pod Running。
- kubelet active，节点 Ready。
- `drill-monitor-pods` ClusterRoleBinding 重建，can-i 为 yes。
- dnsutils 内 nslookup 正常解析 kubernetes.default。

## 提示（卡住再看）

<details><summary>提示 1：症状 1 为什么"时好时坏"</summary>

集群域（cluster.local）由 kubernetes 插件直接在内存里应答，不走 forward；只有外部域名才走 forward。上游改成 127.0.0.1 后，`nslookup kubernetes.default` 应该仍通——如果它不通，说明还有别的故障叠加（想想症状 2：kubelet 停了会影响什么）。演练里两个故障会互相掩盖，这也是真实事故的常态。所以排障要**分层**：Pod 侧 resolv.conf -> kube-dns Service -> CoreDNS Pod -> Corefile。

</details>

<details><summary>提示 2：改回 Corefile 的命令</summary>

```bash
# [master]
kubectl -n kube-system get cm coredns -o json \
  | sed 's|forward \. 127.0.0.1|forward . /etc/resolv.conf|' \
  | kubectl apply -f -
```

改完看 CoreDNS 日志等 reload，或直接 rollout restart。

</details>

<details><summary>提示 3：重建 ClusterRoleBinding</summary>

把 Phase 0 YAML 里 ClusterRoleBinding 那一段重新 apply 即可。删除 ClusterRoleBinding 不会删 ClusterRole，也不影响 SA 本身——RBAC 三件套各自独立存活，绑定断了权限即失效。

</details>
