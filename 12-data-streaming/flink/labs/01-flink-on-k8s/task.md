# Lab 01 · 在 K8s 上用 Flink Operator 跑作业：checkpoint、反压与 savepoint 恢复

> 难度：★★★ ｜ 考点：—（CKA 的 Deployment/Service/持久化思路直接复用；Flink 运维核心链路） ｜ 前置：本模块 01、02 两章 ｜ 预计 60~90 分钟

## 场景

团队决定把实时词频统计从一台 VM 迁到 kubeadm 练习集群上，要求：用 Flink Kubernetes Operator 以 Application 模式部署，checkpoint 必须真实落盘；值班同学要能在数据高峰（热点词刷屏）时从 Web UI 指出反压瓶颈在哪；发布新版本时必须走 savepoint 升级，状态不许丢。你手里只有：单 master 的 kubeadm 集群（Calico CNI）、一台能 kubectl 的操作机，以及本模块第 2 章的知识。

## 任务清单

1. 安装 helm（若无）与 Flink Kubernetes Operator（写作时最新 1.13.0），确认 operator Pod 在 `flink-operator` namespace 里 Running。
2. 在 master 上准备状态目录：`/var/flink-state/{checkpoints,savepoints,ha}`，属主改为 9999:9999（flink 官方镜像内运行用户的 uid）。
3. 创建 namespace `flink-lab`，部署"词源"服务 `wordsrv`：busybox Deployment 2 副本 + 同名 Service（端口 9000），每个 Pod 用 `nc -l -p 9000` 对外供数，且带环境变量 `FLOOD`（`0` 正常速率，`1` 用 `yes hello` 刷屏制造热点 key）。正常模式下持续输出 `hello` / `flink` / `word<N>` 三种词。
4. 编写并 apply `FlinkDeployment`（名字 `wordcount`，namespace `flink-lab`）：镜像 `flink:1.19`、`flinkVersion: v1_19`、Application 模式运行自带示例 `SocketWindowWordCount`（entryClass `org.apache.flink.streaming.examples.socket.SocketWindowWordCount`，args 指向 `wordsrv:9000`，窗口 10 秒），并行度 2，checkpoint 间隔 10s，checkpoints/savepoints 目录挂 hostPath `/var/flink-state`，重启策略 fixed-delay（attempts 10，delay 5s）。
5. 验证：CR 状态 RUNNING；通过 `wordcount-rest` Service（REST 8081）确认至少 1 个 TaskManager 注册、作业 state=RUNNING、存在 completed≥1 的 checkpoint；在 TaskManager 日志里看到每 10 秒一批窗口计数输出。
6. 把 `wordsrv` 切到 `FLOOD=1`，等约 1 分钟，从 Web UI 的 Backpressure 页与 `busy/backPressured/idleTimeMsPerSecond` 指标确认：source 被反压（backPressured 顶满），窗口算子只有一个 subtask 忙、另一个 idle（热点 key 倾斜）。记录你认定的瓶颈算子。
7. 观察完毕把 `FLOOD` 切回 `0`。
8. 用 `savepointTriggerNonce` 触发一次 savepoint，从 CR 的 `.status.jobStatus.savepointPath`（或 `/var/flink-state/savepoints/`）拿到实际路径。
9. patch 该 CR：`fromSavepoint` 指向上一步路径，同时把并行度从 2 改为 1，让 operator 完成"savepoint 停止 → 按新并行度恢复"。
10. 验证恢复成功：作业重新 RUNNING，REST checkpoints 里 `restored` 计数 ≥ 1。

## 验收标准

- `kubectl get pods -n flink-lab` 能看到 Flink 的 JobManager、TaskManager Pod 与两个 wordsrv Pod 全部 Running；
- REST（`wordcount-rest:8081`）上：作业 state=RUNNING、`counts.completed >= 1`、`counts.restored >= 1`；
- master 的 `/var/flink-state/savepoints/` 下存在 `savepoint-*` 目录；
- wordsrv 的 `FLOOD` 回到 `0`。

完成后运行判分脚本（在 master 上）：

```bash
# [master]
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：operator 装好后没有任何反应？</summary>

operator 只是把 CRD 与控制器装好（`kubectl get crd | grep flink`），不会自己跑作业；要 apply 一个 `FlinkDeployment`（Application 模式带 `spec.job`）它才会建 JM/TM Deployment 和 `<name>`、`<name>-rest` 两个 Service。helm 安装命令参考第 2 章：`helm repo add flink-operator-repo https://downloads.apache.org/flink/flink-kubernetes-operator-1.13.0/`。
</details>

<details><summary>提示 2：Pod 起不来，日志报 /var/flink-state Permission denied</summary>

hostPath 目录默认 root 属主，而 flink 镜像里进程以 uid 9999 运行。提前 `sudo mkdir -p /var/flink-state/{checkpoints,savepoints,ha} && sudo chown -R 9999:9999 /var/flink-state`。hostPath 也决定了本 lab 只适合单节点集群（或把 Flink Pod 都钉在同一节点）。
</details>

<details><summary>提示 3：REST 怎么访问？UI 怎么看反压？</summary>

`kubectl -n flink-lab port-forward svc/wordcount-rest 8081:8081`，然后 `curl http://localhost:8081/jobs/overview`；浏览器开 `http://localhost:8081`，进入作业的 Operators 页签看 Backpressure 采样颜色，Metrics 页签按 vertex 选择 `busyTimeMsPerSecond` / `backPressuredTimeMsPerSecond` / `idleTimeMsPerSecond`。判读口诀：沿数据流找第一个 backPressured≈0 且 busy≈1000 的算子即瓶颈。
</details>

<details><summary>提示 4：savepoint 触发与路径获取</summary>

`kubectl -n flink-lab patch flinkdeployment wordcount --type merge -p '{"spec":{"job":{"savepointTriggerNonce":1}}}'`（nonce 值变化即触发）。路径用 `kubectl -n flink-lab get flinkdeployment wordcount -o jsonpath='{.status.jobStatus.savepointPath}'`，或直接 `ls /var/flink-state/savepoints/`。恢复时 patch `spec.job.fromSavepoint`。
</details>

<details><summary>提示 5：SocketWindowWordCount 连不上 wordsrv？</summary>

Service DNS 名是 `wordsrv`（同 namespace 内直接用短名）；确认 Service 的 selector 与 Pod label 匹配、`kubectl -n flink-lab get endpoints wordsrv` 有地址。该示例的 socket source 断线后会重试/由重启策略拉起，wordsrv 内层 `while true` 会重新 `nc -l` 监听。
</details>
