# Lab 14 · kubeadm 升级演练：cordon/drain 与 upgrade plan
> 难度：★★★ ｜ 考点：CKA-集群运维（kubeadm upgrade / 节点维护） ｜ 前置：kubeadm 集群（单 master）已就绪 ｜ 预计 40 分钟
> 运行位置：kubectl 部分在 [master]；`kubeadm upgrade plan` 必须在 **master 节点**上以 root 运行。本 lab **不执行真正的升级**，只演练维护动作与计划解读（升级本身不可逆，脚本只检查可安全检查的部分）。

## 场景

周五要升级集群。变更方案评审时你被要求先交两份材料：

1. **节点维护动作演练记录**：对工作负载执行 cordon → drain → uncordon 完整循环，证明你会安全地把 Pod 驱逐出节点再放回调度，且最终集群回到健康状态。
2. **升级计划解读**：在 master 上跑 `kubeadm upgrade plan`，把输出存档，并回答三个问题——当前版本是什么、本次可升到哪个 PATCH 版本、哪些组件 kubeadm 不会自动升级。

## 任务清单

1. 在 `default` namespace 部署 Deployment `lab14-nginx`（image `nginx:1.27-alpine`，2 replicas）。
2. 找到集群唯一节点名（单 master 集群），执行 `kubectl cordon <node>`，验证节点出现 `SchedulingDisabled`。
3. 对该节点执行 drain（单 master 节点需要 `--ignore-daemonsets`，本地存储 Pod 需要额外 flag，自己想），观察 `lab14-nginx` 的 Pod 被驱逐（单节点集群上会变 `Pending`）。
4. 执行 `kubectl uncordon <node>`，等待 `lab14-nginx` 恢复 `2/2` Available。
5. 在 master 上执行 `kubeadm upgrade plan`，把完整输出保存到 `/tmp/lab14-plan.txt`。
6. 把两个答案写入 `/tmp/lab14-answers.txt`，**严格按下面的格式**（每行一个，大写开头）：
   ```
   CURRENT=<当前 kubeadm/kubelet 版本, 如 v1.31.1>
   TARGET=<plan 建议升级到的版本, 如 v1.31.4>
   ```
   另起一行用一句中文写出 plan 中"kubeadm 不会自动升级的组件"有哪些（写在 `MANUAL=` 后面）。

## 验收标准

- `kubectl get node <node>` 节点为 `Ready` 且**没有** `SchedulingDisabled`（uncordon 已做）。
- `lab14-nginx` 为 `2/2` Available，两个 Pod `Running`。
- `/tmp/lab14-plan.txt` 存在且包含 `kubeadm upgrade apply` 提示行。
- `/tmp/lab14-answers.txt` 的 `CURRENT` 值与节点 kubelet 版本一致，`TARGET` 值出现在 plan 文件中。

## 提示（卡住再看）

<details><summary>提示 1：drain 报错时读报错</summary>

drain 拒绝执行时会把原因打印出来，按提示加 flag：

```bash
# [master]
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
```

master 节点上的 static Pod（apiserver/etcd 等）是 mirror pod，drain 会自动跳过；`--ignore-daemonsets` 处理 Calico/kube-proxy 这类 DaemonSet；`--delete-emptydir-data` 处理带 emptyDir 的 Pod。

</details>

<details><summary>提示 2：cordon 与 drain 的关系</summary>

`drain` 内部会**先自动 cordon** 再驱逐。本 lab 要求你显式 cordon 并观察 `SchedulingDisabled`，是为了在 uncordon 之前 Pod 不会被调度回来，形成完整的"封调度 → 驱逐 → 观察 → 解封"闭环。uncordon 只改 `spec.unschedulable`，不会主动拉回 Pod，要等 controller 和 scheduler 重建。

</details>

<details><summary>提示 3：upgrade plan 需要什么身份</summary>

```bash
# [master]
sudo kubeadm upgrade plan | tee /tmp/lab14-plan.txt
```

root 权限 + 能连上 API Server（用 `/etc/kubernetes/admin.conf`）。若提示版本不可得，检查 apt 源是否锁定了 minor 版本（kubeadm 只建议同 minor 内升 PATCH，跨 minor 需逐版升）。

</details>
