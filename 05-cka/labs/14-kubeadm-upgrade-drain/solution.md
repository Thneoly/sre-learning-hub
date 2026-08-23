# Lab 14 · 解答：kubeadm 升级演练

## 第 1 步：部署演练用工作负载

```bash
# [master]
kubectl create deployment lab14-nginx --image=nginx:1.27-alpine --replicas=2
```

等 2/2：

```bash
# [master]
kubectl get deploy lab14-nginx -w
```

预期 `lab14-nginx   2/2   2   2   <age>` 后 Ctrl-C。

## 第 2 步：cordon 封调度

```bash
# [master]
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
kubectl cordon "$NODE"
kubectl get nodes
```

预期：

```
NAME        STATUS                     ROLES           AGE   VERSION
cka-node1   Ready,SchedulingDisabled   control-plane   10d   v1.31.1
```

原理：cordon 只把 `node.spec.unschedulable` 置为 true，scheduler 从此跳过该节点；已有 Pod 不受影响。

## 第 3 步：drain 驱逐

```bash
# [master]
kubectl drain "$NODE" --ignore-daemonsets --delete-emptydir-data
```

典型过程输出：

```
node/cka-node1 cordoned
evicting pod default/lab14-nginx-5d8f7c6b4-x2p9q
pod/lab14-nginx-5d8f7c6b4-x2p9q evicted
```

不加 flag 时会遇到的报错（这也是考点）：

```
error: unable to drain node "cka-node1" due to error:
cannot delete DaemonSet-managed Pods ... (use --ignore-daemonsets to ignore)
cannot delete Pods with local storage ... (use --delete-emptydir-data to empty emptyDir volumes)
```

master 上的 `kube-apiserver-<node>` 等 mirror pod 会被自动跳过（`ignoring mirror pod`），不需要 `--force`。

单节点集群上被驱逐的 Pod 无处可去：

```bash
# [master]
kubectl get pods -l app=lab14-nginx
```

预期 `Pending`（describe 里 `Events: ... FailedScheduling ... node(s) ... SchedulingDisabled`——这正是"封调度生效"的证据）。

## 第 4 步：uncordon 恢复

```bash
# [master]
kubectl uncordon "$NODE"
kubectl rollout status deployment/lab14-nginx --timeout=120s
```

预期 `deployment "lab14-nginx" successfully rolled out`，`kubectl get pods -l app=lab14-nginx` 两个 `Running`。

## 第 5 步：kubeadm upgrade plan

```bash
# [master]
sudo kubeadm upgrade plan | tee /tmp/lab14-plan.txt
```

输出结构解读（版本号以你集群实际为准）：

```
[upgrade/config] ...                     # 读取集群配置(kubeadm-config ConfigMap)
[upgrade/versions] v1.31.1 -> v1.31.4    # 当前版本 -> 可用的最新 PATCH 版本
Components that must be upgraded manually after you have upgraded the control plane:
  COMPONENT   CURRENT    TARGET
  kubelet     v1.31.1    v1.31.4        # kubeadm 不会碰 kubelet!
Upgrade to the latest version in the v1.31 series:
COMPONENT                 CURRENT    TARGET
API Server                v1.31.1    v1.31.4    # 这些由 kubeadm upgrade apply 完成
Controller Manager        v1.31.1    v1.31.4
Scheduler                 v1.31.1    v1.31.4
Kube Proxy                v1.31.1    v1.31.4
CoreDNS                   v1.11.1    v1.11.3
etcd                      3.5.15     3.5.15
You can now apply the upgrade by executing the following command:
  kubeadm upgrade apply v1.31.4
```

关键读法：

- 第一段标题是 **"must be upgraded manually"**——kubelet 和容器运行时（containerd）永远要你在**每个节点上手工**用 apt 升级。
- 中间表格是 `kubeadm upgrade apply` 会替你升级的 control plane 组件与 CoreDNS/kube-proxy。
- 跨 minor（如 1.30 -> 1.32）不允许跳版，必须 1.30 -> 1.31 -> 1.32 逐版 apply。

## 第 6 步：写 answers 文件

```bash
# [master]
cat >/tmp/lab14-answers.txt <<'EOF'
CURRENT=v1.31.1
TARGET=v1.31.4
MANUAL=kubelet 与容器运行时(containerd)需在每个节点手工升级, kubeadm 不会自动处理
EOF
```

CURRENT 取自 `kubectl get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}'`（或 plan 输出的 `[upgrade/versions]` 行），TARGET 取自 `Upgrade to the latest version in the vXX series` 段。

## 附：真正的升级顺序（供复习，本 lab 不执行）

```
1. kubeadm upgrade apply v1.31.4            # master: 升 control plane 组件
2. apt install kubelet=1.31.4-... && systemctl restart kubelet   # master: 升 kubelet
3. 逐个 worker: drain -> apt 升 kubeadm/kubelet
   -> kubeadm upgrade node -> systemctl restart kubelet -> uncordon
```

顺序口诀：**先 master 后 worker；先 kubeadm 后 kubelet；worker 动手前必 drain**。

## 常见错误回顾

| 经常踩的坑 | 后果 | 正确姿势 |
| --- | --- | --- |
| drain 后忘 uncordon | 新 Pod 永远 Pending | 维护结束立刻 uncordon |
| drain master 不加 `--ignore-daemonsets` | 命令直接报错拒绝执行 | 按报错加 flag |
| 用 `--force` 图省事 | 裸 Pod（不属于控制器的 Pod）被直接删除且不重建 | 先搞清裸 Pod 归属 |
| 跨 minor 直接 apply | kubeadm 拒绝或集群状态异常 | 逐 minor 升级 |
| 只升 kubeadm 不升 kubelet | `kubectl get nodes` 版本列不一致，Scheduling 可能出问题 | plan 的 MANUAL 段逐节点处理 |

## 延伸阅读

- https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- https://kubernetes.io/docs/tasks/administer-cluster/safely-drain-node/

## check.sh 运行结果

```bash
# [master]
chmod 755 check.sh && ./check.sh
```

预期：

```
PASS: 节点 cka-node1 为 Ready
PASS: 节点 cka-node1 已解除 cordon(可调度)
PASS: Deployment lab14-nginx 存在
PASS: lab14-nginx availableReplicas=2
PASS: lab14-nginx 两个 Pod 均 Running
PASS: plan 存档存在且包含 'kubeadm upgrade apply' 提示行
PASS: answers 的 CURRENT=v1.31.1 与 kubelet 版本一致
PASS: answers 的 TARGET=v1.31.4 出现在 plan 输出中
PASS: answers 包含 MANUAL= 组件说明行

SCORE: 9/9
```
