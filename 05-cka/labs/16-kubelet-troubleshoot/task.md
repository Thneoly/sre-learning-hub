# Lab 16 · kubelet 排错：NotReady 节点
> 难度：★★ ｜ 考点：CKA-排错（节点故障 / systemd / journalctl） ｜ 前置：kubeadm 集群已就绪 ｜ 预计 25 分钟
> 运行位置：需要 ssh 到 **master 节点**（练习环境为单节点集群，故障就注入在该节点）

## 场景（故障说明）

早上收到告警：

```
Node cka-node1 status is NotReady
```

`kubectl get pods -o wide` 里业务 Pod 显示 `Unknown`，但 API Server 本身还活着（你还能用 kubectl）。到节点上看，容器进程似乎都还在（`ps aux | grep containerd` 有输出），说明问题不在容器运行时。**你需要用 journalctl 找出 kubelet 到底怎么了，并恢复节点到 Ready。**

## 故障注入（练习前在 master 上执行）

```bash
# [master]
sudo systemctl stop kubelet
```

> 若你使用仓库的故障脚本，等效命令为 `scripts/faults/break-kubelet.sh`。注入后等 1 分钟（node-lifecycle-controller 的默认探测周期是 40s + pod-eviction-timeout 相关延迟），再开始排错。

## 任务清单

1. 从 kubectl 侧确认症状：`kubectl get nodes` 的 STATUS 与 `kubectl get pods -A` 里的异常状态各是什么？
2. 在节点上确认 kubelet 服务状态：`systemctl status kubelet`，记录 Active 一行与最近几条日志。
3. 用 journalctl 查看 kubelet 最近 50 行日志，找出**停止/异常的直接证据**（例如 "Started/Stopped Kubernetes API Server" 类 systemd 事件、cert 报错或 config 报错——本次注入的故障应显示服务被停止）。
4. 恢复 kubelet，并验证节点回到 `Ready`、业务 Pod 回到 `Running`。
5. 回答：如果 journalctl 里显示的是 `failed to load Kubelet config file /var/lib/kubelet/config.yaml` 类错误，你接下来会检查哪两个东西？（solution 有答案）

## 验收标准

- `kubectl get nodes` 唯一节点为 `Ready`。
- `systemctl is-active kubelet` 输出 `active`。
- 任意一个非 DaemonSet 业务 Pod（可用 `kubectl run lab16-check --image=nginx:1.27-alpine --restart=Never` 事后自测再删掉）能调度并 Running——证明节点真的回来了，不只是状态翻绿。

## 提示（卡住再看）

<details><summary>提示 1：NotReady 的判定链</summary>

节点 Ready/NotReady 由 **kubelet 定期上报的 Lease/Status** 决定。kubelet 挂了 → 上报停止 → node-lifecycle-controller 超过 `node-monitor-grace-period`（默认 40s）收不到心跳 → 把 Ready condition 翻成 `Unknown`（kubectl 显示 NotReady）。所以"API 还能用但节点 NotReady"的第一个怀疑对象永远是该节点上的 kubelet。

</details>

<details><summary>提示 2：journalctl 的实用姿势</summary>

```bash
# [master]
sudo journalctl -u kubelet -n 50 --no-pager      # 最近 50 行
sudo journalctl -u kubelet --since "15 min ago"  # 时间窗过滤
sudo journalctl -u kubelet -p err -n 30          # 只看 error 级别
sudo journalctl -u kubelet -f                    # 跟踪实时输出(修好后观察)
```

</details>

<details><summary>提示 3：恢复后节点多久变 Ready</summary>

`systemctl start kubelet` 后 kubelet 要重新向 API Server 上报节点状态（默认 `nodeStatusUpdateFrequency` 10s 一次），通常十几秒内翻回 Ready；Pod 状态恢复再晚一点。

</details>
