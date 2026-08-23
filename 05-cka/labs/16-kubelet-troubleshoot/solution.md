# Lab 16 · 解答：kubelet 排错

## 排错思路总览

```
kubectl get nodes: NotReady
   │ 谁负责上报 Ready? kubelet
   ▼
节点上: systemctl status kubelet   ──> inactive/dead = 本案
   │ 若 active 但报错, 则:
   ▼
journalctl -u kubelet -n 50        ──> 看 cert / config / runtime 报错
   ▼
修因 -> start/enable -> 观察 -f 直到 "Successfully registered node"
```

## 第 1 步：确认症状（API 侧）

```bash
# [master]
kubectl get nodes
```

预期：

```
NAME        STATUS     ROLES           AGE   VERSION
cka-node1   NotReady   control-plane   10d   v1.31.1
```

```bash
# [master]
kubectl get pods -A | head
```

预期：业务 Pod `Unknown`（kubelet 停止上报后，controller 把它们标记为 Unknown；DaemonSet 与静态 Pod 因由各自机制兜底，显示可能仍是 Running/Unknown 混合）。API Server 是静态 Pod，容器还活着，所以 kubectl 仍可用——这就是"控制面可用但节点失联"的典型形态。

## 第 2 步：systemctl 定位服务状态

```bash
# [master]
systemctl status kubelet
```

预期关键行：

```
● kubelet.service - Kubernetes Kubelet
     Loaded: loaded (/lib/systemd/system/kubelet.service; enabled; ...)
     Active: inactive (dead) since ... ; 3min ago
```

`inactive (dead)` 且有 `since` 时间——服务被人为/异常停止。这就是直接证据。

## 第 3 步：journalctl 取证

```bash
# [master]
sudo journalctl -u kubelet -n 50 --no-pager
```

关注最后几条与 systemd 生命周期事件：

```
... kubelet.service: Deactivated successfully.
... Stopped Kubernetes Kubelet.
```

没有 crash 循环、没有 cert/config 报错，只有一次干净的 Stop——说明不是配置坏了，而是服务没在跑。取证完毕（真实事故里这一步才是分水岭：日志若是 `server certificate expired` 或 `failed to load Kubelet config file`，修法完全不同）。

## 第 4 步：恢复并验证

```bash
# [master]
sudo systemctl start kubelet
sudo systemctl enable kubelet   # 确保重启后自启(通常已 enabled)
sudo journalctl -u kubelet -f
```

跟踪日志直到出现（按 Ctrl-C 退出）：

```
... "Successfully registered node" node="cka-node1"
```

验证：

```bash
# [master]
systemctl is-active kubelet     # active
kubectl get nodes               # Ready
kubectl run lab16-check --image=nginx:1.27-alpine --restart=Never
kubectl wait --for=condition=Ready pod/lab16-check --timeout=90s
kubectl delete pod lab16-check
```

`lab16-check` 能被调度并 Ready，说明节点不只是状态翻绿，调度链路也真正恢复。

## 第 5 步：思考题答案

**如果 journalctl 显示 `failed to load Kubelet config file /var/lib/kubelet/config.yaml`？**

1. 检查 `/var/lib/kubelet/config.yaml` 本身：文件是否存在、YAML 是否被改坏（`sudo cat` + 逐行核对）。kubelet 的配置由 kubelet-config ConfigMap 下发，改坏一个缩进就会出现这个报错。
2. 检查文件来源与权限：若是 kubeadm 集群，对比 `kubectl -n kube-system get cm kubelet-config -o yaml` 的内容，把正确配置写回；同时确认 kubelet 的 drop-in `/etc/systemd.d/kubelet.conf.d/**`（或 10-kubeadm.conf）没有被改动——配置改完要 `sudo systemctl daemon-reload && sudo systemctl restart kubelet`。

## kubelet 常见故障速查

| journalctl 关键字 | 根因 | 修法 |
| --- | --- | --- |
| `inactive (dead)`，无报错 | 服务被 stop | `systemctl start kubelet` |
| `server certificate expired` | 节点 client cert 过期（kubeadm 集群一年） | `kubeadm certs renew` 相应证书后重启 kubelet |
| `failed to load Kubelet config file` | config.yaml 缺失/坏 | 对比 kubelet-config ConfigMap 恢复 |
| `failed to get container info ... containerd` | 容器运行时挂了/sock 路径不对 | `systemctl status containerd`，修 runtime |
| `nodes "cka-node1" not found` | 节点对象被删过 | 核对 kubelet 的 node-name 与 API 里对象 |
| cgroup driver 不匹配 | kubelet 与 runtime 的 cgroupdriver 不一致 | 两端统一为 systemd |

## 延伸阅读

- https://kubernetes.io/docs/tasks/administer-cluster/kubelet-config-file/
- https://kubernetes.io/docs/concepts/architecture/nodes/#condition

## check.sh 运行结果

```bash
# [master]
chmod 755 check.sh && ./check.sh
```

预期：

```
PASS: kubelet 服务为 active
PASS: kubelet 未被 mask
PASS: 节点 cka-node1 为 Ready
PASS: kube-system 所有 Pod 均 Running
PASS: 业务 namespace 至少 1 个 Pod Running(调度能力已恢复)

SCORE: 5/5
```
