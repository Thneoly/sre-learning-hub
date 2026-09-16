# Lab 01 · 在 K8s 上用 Flink Operator 跑作业：checkpoint、反压与 savepoint 恢复

> 难度：★★★ ｜ 考点：—（CKA 的 Deployment/Service/持久化思路直接复用；Flink 运维核心链路） ｜ 前置：本模块 01、02 两章 ｜ 预计 60~90 分钟

## 场景

团队决定把实时词频统计从一台 VM 迁到 kubeadm 练习集群上，要求：用 Flink Kubernetes Operator 以 Application 模式部署，checkpoint 必须真实落盘；值班同学要能在数据高峰（热点词刷屏）时从 Web UI 指出反压瓶颈在哪；发布新版本时必须走 savepoint 升级，状态不许丢。你手里只有：单 master 的 kubeadm 集群（Calico CNI）、一台能 kubectl 的操作机，以及本模块第 2 章的知识。

## 任务清单

1. 安装 helm（若无）与 Flink Kubernetes Operator（写作时最新 1.13.0），确认 operator Pod 在 `flink-operator` namespace 里 Running。
2. 在 master 上准备状态目录：`/var/flink-state/{checkpoints,savepoints,ha}`，属主改为 9999:9999（flink 官方镜像内运行用户的 uid）。
3. 创建 namespace `flink-lab`，部署"词源"服务 `wordsrv`：busybox Deployment 2 副本 + 同名 Service（端口 9000），每个 Pod 用 `nc -l -p 9000` 对外供数，且带环境变量 `FLOOD`（`0` 正常速率，`1` 用 `yes hello` 刷屏制造热点 key）。正常模式下持续输出 `hello` / `flink` / `word<N>` 三种词。
4. 编写并 apply `FlinkDeployment`（名字 `wordcount`，namespace `flink-lab`）：镜像 `flink:1.19`、`flinkVersion: v1_19`、Application 模式运行自带示例 `SocketWindowWordCount`（entryClass `org.apache.flink.streaming.examples.socket.SocketWindowWordCount`，args 指向 `wordsrv:9000`，窗口 10 秒），并行度 2，checkpoint 间隔 10s，checkpoints/savepoints 目录挂 hostPath `/var/flink-state`，重启策略 fixed-delay（attempts 10，delay 5s）。注意：挂载卷必须走 `podTemplate` 且其中的容器名必须是 `flink-main-container`（见提示 6）；operator 默认用 `flink` ServiceAccount 跑作业，需提前在 `flink-lab` 建 SA 与 RoleBinding（见提示 7）。
5. 验证：CR 状态 RUNNING；通过 `wordcount-rest` Service（REST 8081）确认至少 1 个 TaskManager 注册、作业 state=RUNNING、存在 completed≥1 的 checkpoint；在 TaskManager 日志里看到每 10 秒一批窗口计数输出。
6. 把 `wordsrv` 切到 `FLOOD=1`，等约 1 分钟，从 Web UI 的 Backpressure 页与 `busy/backPressured/idleTimeMsPerSecond` 指标确认：source 被反压（backPressured 顶满），窗口算子只有一个 subtask 忙、另一个 idle（热点 key 倾斜）。记录你认定的瓶颈算子。
7. 观察完毕把 `FLOOD` 切回 `0`。
8. 用 `savepointTriggerNonce` 触发一次 savepoint，从 `FlinkStateSnapshot` CR 的 `.status.path`（或直接 `ls /var/flink-state/savepoints/`）拿到实际路径。
9. patch 该 CR：`initialSavepointPath` 指向上一步路径，同时把并行度从 2 改为 1，让 operator 完成"savepoint 停止 → 按新并行度恢复"（示例 jar 未给算子设 uid，缩并行恢复需允许跳过映射不上的状态，见提示 4）。
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

<details><summary>提示 4：savepoint 触发、路径获取与恢复</summary>

`kubectl -n flink-lab patch flinkdeployment wordcount --type merge -p '{"spec":{"job":{"savepointTriggerNonce":1}}}'`（nonce 值变化即触发）。1.10+ 的 operator 把手动 savepoint 记录在 `FlinkStateSnapshot` CR 里（`.status.jobStatus.savepointPath` 字段已不存在）：`kubectl -n flink-lab get flinkstatesnapshot -o custom-columns='NAME:.metadata.name,STATE:.status.state,PATH:.status.path'`，或直接 `ls /var/flink-state/savepoints/`。恢复用的字段是 `spec.job.initialSavepointPath`（旧文档里的 `fromSavepoint` 已废弃，会被 CRD 静默丢弃）。缩并行恢复时若报 `Cannot map checkpoint/savepoint state ... operator is not available in the new program`，是因为示例 jar 没给算子设 uid：在 `flinkConfiguration` 加 `execution.savepoint.ignore-unclaimed-state: "true"`（或 `spec.job.allowNonRestoredState: true`）跳过映射不上的算子状态；真实业务应给关键算子显式 `.uid()`。
</details>

<details><summary>提示 5：SocketWindowWordCount 连不上 wordsrv？作业为什么变成 FINISHED？</summary>

Service DNS 名是 `wordsrv`（同 namespace 内直接用短名）；确认 Service 的 selector 与 Pod label 匹配、`kubectl -n flink-lab get endpoints wordsrv` 有地址。**连接失败**（nc 还没监听上）才算失败，由重启策略拉起；但**连接被对端正常关闭**（EOF，比如 `set env` 切 FLOOD 滚动重启 wordsrv）时，socket source 会正常结束——作业直接变 FINISHED，重启策略不管"正常结束"。此时最干净的复活方式是删掉 CR 重新 apply（hostPath 上的状态不受影响）；不要用 `restartNonce`：savepoint 升级模式下 operator 会引用已随作业结束被清理的最后一个 checkpoint（`upgradeSavepointPath` 指向不存在的 chk-N），JM 会持续 FileNotFoundException。
</details>

<details><summary>提示 6：挂 hostPath 为什么必须用 podTemplate，容器名为什么必须是 flink-main-container？</summary>

FlinkDeployment 的 CRD 里**没有** `spec.volumes` / `spec.jobManager.volumeMounts` 这类顶层挂载字段（jobManager/taskManager 下只有 `podTemplate`、`replicas`、`resource`），写上去会被 API Server 以 `strict decoding error: unknown field` 直接拒绝。正确做法是把 volumes 和 volumeMounts 写进 `spec.jobManager.podTemplate` / `spec.taskManager.podTemplate`。podTemplate 里的容器名**必须**叫 `flink-main-container`：operator 是按容器名把你的配置（镜像、挂载、env）合并进它自己生成的主容器的——起了别的名字（如 `flink-job-manager`），operator 不会认领，而是把它当成一个多余的 sidecar 原样保留；这个 sidecar 没有 command，flink 镜像入口只打印 usage 就退出——于是 Pod 里同时挂着"真正的主容器 + 一个秒退的 sidecar"，表现为 0/2 CrashLoopBackOff。JobManager 和 TaskManager 两个 podTemplate 里都遵守同一约定。
</details>

<details><summary>提示 7：JobManager 起不来，日志里 Received 403 on websocket？</summary>

operator 默认让 FlinkDeployment 用名为 `flink` 的 ServiceAccount 运行（也可以用 `spec.serviceAccount` 显式指定）。helm 只在 `flink-operator` namespace 里为 operator 自己建了 RBAC，作业 namespace 里必须自建：`serviceaccount/flink` + 一个绑到 ClusterRole `flink-operator` 的 RoleBinding。缺了它 JobManager 在 watch TaskManager Pod 时就会被 403 Forbidden 拒绝并退出（容器反复重启、退出码 239）。
</details>
