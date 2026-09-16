# Lab 01 · 解答与讲解

> 前置：kubeadm 单 master 集群（Calico），master 可 kubectl、有 curl、能拉公网镜像。VM 建议 ≥4 GB 内存 / 2 核。

## 第 1 步：安装 helm 与 Flink Kubernetes Operator

```bash
# [master]
command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
helm version --short   # 预期 v3.x

helm repo add flink-operator-repo https://downloads.apache.org/flink/flink-kubernetes-operator-1.13.0/
helm install flink-kubernetes-operator flink-operator-repo/flink-kubernetes-operator \
  --namespace flink-operator --create-namespace
kubectl get pods -n flink-operator -w
# 预期 1~2 分钟后: flink-kubernetes-operator-xxxxxxx-xxxxx   1/1   Running
```

为什么先装 operator：它提供 `FlinkDeployment` / `FlinkSessionCluster` 两个 CRD 和一个控制器，后面"集群拉起、配置注入、savepoint 升级"全部声明式完成。验证：`kubectl get crd | grep flink.apache.org` 应列出 CRD。版本 1.13.0 是写作时的最新稳定版，以官方文档为准。

## 第 2 步：准备状态目录

```bash
# [master]
sudo mkdir -p /var/flink-state/checkpoints /var/flink-state/savepoints /var/flink-state/ha
sudo chown -R 9999:9999 /var/flink-state
```

为什么：flink 官方镜像里进程以 uid 9999（用户 flink）运行；hostPath 默认 root 属主会导致 checkpoint 写入 `Permission denied`，Pod 起不来。这也把本 lab 限定在单节点集群（多节点应换 PVC + StorageClass，思路同 CKA 存储章）。

## 第 3 步：词源服务 wordsrv（Deployment + Service）

```bash
# [master]
kubectl create namespace flink-lab
```

先补作业侧 RBAC：operator 默认用名为 `flink` 的 ServiceAccount 跑 FlinkDeployment，而 helm 只为 `flink-operator` namespace 里的 operator 自己建了权限，**作业 namespace 必须自建 SA + RoleBinding**（绑到 operator 的 ClusterRole `flink-operator`）。缺这一步 JobManager 会在 watch TaskManager Pod 时收到 403 Forbidden 然后退出，容器反复重启。

```bash
# [master]
kubectl -n flink-lab apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flink
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: flink-role-binding
subjects:
- kind: ServiceAccount
  name: flink
  namespace: flink-lab
roleRef:
  kind: ClusterRole
  name: flink-operator
  apiGroup: rbac.authorization.k8s.io
EOF
```

词源服务：

```bash
# [master]
cat > wordsrv.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wordsrv
  namespace: flink-lab
  labels:
    app: wordsrv
spec:
  replicas: 2
  selector:
    matchLabels:
      app: wordsrv
  template:
    metadata:
      labels:
        app: wordsrv
    spec:
      containers:
        - name: nc
          image: busybox:1.36
          env:
            - name: FLOOD
              value: "0"
          command: ["sh", "-c"]
          args:
            - |
              while true; do
                if [ "${FLOOD}" = "1" ]; then
                  yes hello | nc -l -p 9000
                else
                  while :; do echo hello; echo flink; echo "word$((RANDOM % 10))"; sleep 0.2; done | nc -l -p 9000
                fi
                sleep 1
              done
---
apiVersion: v1
kind: Service
metadata:
  name: wordsrv
  namespace: flink-lab
spec:
  selector:
    app: wordsrv
  ports:
    - port: 9000
      targetPort: 9000
EOF
kubectl apply -f wordsrv.yaml
kubectl -n flink-lab get pods -l app=wordsrv -w
# 预期: wordsrv-xxxxx-xxxxx 与 wordsrv-xxxxx-yyyyy 都 1/1 Running
kubectl -n flink-lab get endpoints wordsrv
# 预期: ENDPOINTS 列出两个 Pod IP
```

设计说明：

- `nc -l -p 9000` 每次只接受一条 TCP 连接，外层 `while true; sleep 1` 保证断开后 1 秒内重新监听——作业重启时若撞上这 1 秒空窗，source 连接失败会走重启策略自愈（但注意：连接被**正常关闭**是 EOF，作业会直接 FINISHED，见第 6 步的坑位提醒）；
- 2 副本对应 Flink 作业的 source 并行度 2：Service 把两条连接分别落到两个 Pod，各自独立供数；
- `FLOOD=1` 时改喂 `yes hello`：全量单一热点词 `hello`，制造"热点 key + 高流速"两个现象。

## 第 4 步：部署 FlinkDeployment（Application 模式）

两个最容易翻车的点先说清楚：

- **挂载必须走 podTemplate**：FlinkDeployment 的 CRD 里没有 `spec.volumes` / `spec.jobManager.volumeMounts` 这类顶层字段（`jobManager`/`taskManager` 下只有 `podTemplate`、`replicas`、`resource`），写上去 apply 时会被 API Server 以 `strict decoding error: unknown field "spec.volumes"` 直接拒绝。
- **podTemplate 里的容器名必须叫 `flink-main-container`**：operator 按"容器名"把 podTemplate 里的镜像/挂载/env 合并进**它自己生成的主容器**。起别的名字（比如 `flink-job-manager`），operator 不会把它当主容器，而是原样保留成一个多余的 sidecar——这个 sidecar 没有 command，flink 镜像入口打印 usage 后立即退出，Pod 进入 CrashLoopBackOff。JobManager 和 TaskManager 两侧遵守同一约定。

```bash
# [master]
cat > flinkdeployment-wordcount.yaml <<'EOF'
apiVersion: flink.apache.org/v1beta1
kind: FlinkDeployment
metadata:
  name: wordcount
  namespace: flink-lab
spec:
  image: flink:1.19
  flinkVersion: v1_19
  serviceAccount: flink
  flinkConfiguration:
    execution.checkpointing.interval: 10s
    execution.checkpointing.externalized-checkpoint-retention: RETAIN_ON_CANCELLATION
    state.checkpoints.dir: file:///opt/flink/state/checkpoints
    state.savepoints.dir: file:///opt/flink/state/savepoints
    restart-strategy: fixed-delay
    restart-strategy.fixed-delay.attempts: "10"
    restart-strategy.fixed-delay.delay: 5s
    taskmanager.numberOfTaskSlots: "2"
  jobManager:
    resource:
      memory: 1024m
      cpu: 0.5
    podTemplate:
      spec:
        volumes:
          - name: flink-state
            hostPath:
              path: /var/flink-state
              type: Directory
        containers:
          - name: flink-main-container
            image: flink:1.19
            volumeMounts:
              - name: flink-state
                mountPath: /opt/flink/state
  taskManager:
    resource:
      memory: 1024m
      cpu: 1
    podTemplate:
      spec:
        volumes:
          - name: flink-state
            hostPath:
              path: /var/flink-state
              type: Directory
        containers:
          - name: flink-main-container
            image: flink:1.19
            volumeMounts:
              - name: flink-state
                mountPath: /opt/flink/state
  job:
    jarURI: local:///opt/flink/examples/streaming/SocketWindowWordCount.jar
    entryClass: org.apache.flink.streaming.examples.socket.SocketWindowWordCount
    args: ["--hostname", "wordsrv", "--port", "9000", "--window", "10", "--slide", "10"]
    parallelism: 2
    upgradeMode: savepoint
EOF
kubectl apply -f flinkdeployment-wordcount.yaml
kubectl -n flink-lab get flinkdeployment wordcount -w
# 预期几分钟后: NAME       JOB STATUS   LIFECYCLE STATE
#               wordcount  RUNNING      STABLE
```

关键点：

- `spec.job` 存在即为 Application 模式：main() 在 JobManager 里跑，集群随作业而生；
- checkpoint 间隔 10s + `state.checkpoints.dir` 落 hostPath —— 状态在 Pod 重建后仍在；
- `upgradeMode: savepoint` 决定后面每次升级先做 savepoint 再停；
- 示例 jar 用 processing time 滚动窗口（`TumblingProcessingTimeWindows`），无需 watermark 即可出结果，适合当部署练手件；
- JobManager 若起不来：日志里 `Received 403 on websocket ... Forbidden` 是第 3 步的 RoleBinding 没建（SA 没权限 watch TM Pod）；容器里只有 usage 输出则是容器名没写对。

## 第 5 步：验证 RUNNING、checkpoint 与窗口输出

```bash
# [master] REST 经 port-forward 访问
kubectl -n flink-lab port-forward svc/wordcount-rest 8081:8081 &
sleep 5
curl -s http://localhost:8081/jobs/overview | grep -o '"state":"[A-Z]*"'
# 预期: "state":"RUNNING"

curl -s http://localhost:8081/taskmanagers | grep -o '"id":"[^"]*"' | head -2
# 预期: 至少一个 TaskManager 的 id

JOB_ID=$(curl -s http://localhost:8081/jobs/overview | grep -o '"jid":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
curl -s http://localhost:8081/jobs/$JOB_ID/checkpoints | grep -o '"counts":{[^}]*}'
# 预期（每 10s 增长）: "counts":{"restored":0,"completed":7,"total":0,"failed":0}

# 窗口结果在 TaskManager stdout（print sink）
kubectl -n flink-lab get pods
kubectl -n flink-lab logs $(kubectl -n flink-lab get pods -o name | grep taskmanager | head -1) --tail=8
# 预期: (hello,131) / (flink,129) / (word3,17) 之类，每 10 秒集中一批
```

浏览器开 `http://localhost:8081` 能看到同一信息（Running Jobs、作业 DAG、Checkpoint 统计曲线）。

## 第 6 步：制造热点 key，观察反压与倾斜

```bash
# [master] 切换词源到刷屏模式（触发两个 Pod 滚动重启）
kubectl -n flink-lab set env deployment/wordsrv FLOOD=1
kubectl -n flink-lab rollout status deployment/wordsrv
```

坑位提醒：wordsrv 滚动重启会把 socket 连接**正常关闭**（EOF），socket source 遇 EOF 是"正常结束"而不是失败——作业直接变 FINISHED，重启策略不会拉起它（它只管失败）。所以切完 FLOOD 后如果 `jobStatus.state` 变成了 FINISHED，把 CR 删掉重新 apply 即可（hostPath 状态不受影响；此时**不要**用 `restartNonce` 复活：savepoint 升级模式下 operator 会引用作业结束 时已被 Flink 清理的最后一个 checkpoint，`upgradeSavepointPath` 指向不存在的 `chk-N`，JobManager 会陷在 FileNotFoundException 里起不来）：

```bash
# [master] 作业 FINISHED 时的标准复活动作（没 FINISHED 就跳过）
kubectl -n flink-lab get flinkdeployment wordcount -o jsonpath='{.status.jobStatus.state}'; echo
kubectl -n flink-lab delete flinkdeployment wordcount --wait=false
sleep 15 && kubectl -n flink-lab delete deploy wordcount --ignore-not-found
kubectl -n flink-lab apply -f flinkdeployment-wordcount.yaml
watch -n5 'kubectl -n flink-lab get flinkdeployment wordcount -o wide'
# 等到 JOB STATUS=RUNNING、LIFECYCLE STATE=STABLE（Ctrl+C 退出）再进入下面的观察
```

等 1 分钟左右，任选一种方式观察（保持上一步的 port-forward）：

浏览器 `http://localhost:8081` → 进入作业 → Operators 页签 → Backpressure：Source 顶点会随采样变红（HIGH）；Metrics 页签把三个每子任务指标 `busyTimeMsPerSecond` / `backPressuredTimeMsPerSecond` / `idleTimeMsPerSecond` 打开后能看到两极分化。

```bash
# [master] 命令行等价观察（subtasks/metrics 按 subtask 逐个取）
JOB_ID=$(curl -s http://localhost:8081/jobs/overview | grep -o '"jid":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
for V in $(curl -s http://localhost:8081/jobs/$JOB_ID/plan | grep -o '"id":"[0-9a-f]*"' | cut -d'"' -f4); do
  echo "== vertex $V =="
  for S in 0 1; do
    curl -s "http://localhost:8081/jobs/$JOB_ID/vertices/$V/subtasks/$S/metrics?get=busyTimeMsPerSecond,backPressuredTimeMsPerSecond,idleTimeMsPerSecond"
    echo
  done
done
```

典型读数（数值为示例）：source 两个 subtask `backPressuredTimeMsPerSecond≈1000`（被卡）；窗口算子 subtask0 `busy≈1000, idle≈0`（热点 key `hello` 全落它），subtask1 `idle≈1000`（无活可干）。结论：瓶颈是窗口聚合算子上的热点 key，扩 source/窗口并行度救不了（key 仍哈希到同一 subtask），治法是加盐两阶段聚合或本地预聚合。这正是第 2 章"沿数据流找第一个 backPressured≈0 且 busy 顶满的算子"的实战版。

```bash
# [master] 观察完切回正常速率
kubectl -n flink-lab set env deployment/wordsrv FLOOD=0
kubectl -n flink-lab rollout status deployment/wordsrv
```

切回 FLOOD=0 同样会滚动重启 wordsrv、把当前作业送进 FINISHED——后面第 7~9 步（savepoint、恢复）都需要作业在 RUNNING，所以照上面"标准复活动作"再删一次 CR、重新 apply，等 RUNNING 后继续。

## 第 7 步：触发 savepoint

```bash
# [master]
kubectl -n flink-lab patch flinkdeployment wordcount --type merge \
  -p '{"spec":{"job":{"savepointTriggerNonce":1}}}'
```

1.10+ 的 operator 把手动触发的 savepoint 记录在专门的 `FlinkStateSnapshot` CR 里（旧文档里的 `.status.jobStatus.savepointPath` 字段已不存在，nonce 触发的不写进 `savepointInfo.savepointHistory`）：

```bash
# [master] 等 20 秒左右（savepoint 是异步的）
kubectl -n flink-lab get flinkstatesnapshot \
  -o custom-columns='NAME:.metadata.name,STATE:.status.state,PATH:.status.path'
# 预期: wordcount-savepoint-manual-xxxxx   COMPLETED   file:/opt/flink/state/savepoints/savepoint-1a2b3c-4d5e6f
sudo ls /var/flink-state/savepoints/
# 预期: savepoint-1a2b3c-4d5e6f   （nonce 递增可重复触发: 2, 3, ...）
```

savepoint 由 TaskManager 执行写入挂载的 hostPath；`FlinkStateSnapshot` 的 `status.path` 与目录两边互相印证。

## 第 8 步：从 savepoint 恢复并把并行度改为 1

恢复字段用 `spec.job.initialSavepointPath`（旧文档里的 `fromSavepoint` 在 1.13 的 CRD 里已不存在，apply/patch 时会被"unknown field"警告后**静默丢弃**，作业照常按无状态启动）。另外示例 jar 没给算子显式 `.uid()`，2→1 缩并行后算子 ID 对不上，会报 `Cannot map checkpoint/savepoint state ... operator is not available in the new program`——加 `execution.savepoint.ignore-unclaimed-state: "true"` 允许跳过映射不上的算子状态（等价于 CLI 的 `--allowNonRestoredState`；真实业务该给算子设 uid 而不是靠这个开关）。

一次性把并行度和恢复源 patch 进去：

```bash
# [master] 路径换成上一步的实际输出
kubectl -n flink-lab patch flinkdeployment wordcount --type merge -p '{
  "spec": {
    "flinkConfiguration": {"execution.savepoint.ignore-unclaimed-state": "true"},
    "job": {
      "parallelism": 1,
      "initialSavepointPath": "file:///opt/flink/state/savepoints/savepoint-1a2b3c-4d5e6f"
    }
  }}'
watch -n5 'kubectl -n flink-lab get flinkdeployment wordcount -o wide'
# 预期经历 SAVEPOINT/升级 过程后回到: JOB STATUS=RUNNING, LIFECYCLE STATE=STABLE
```

注意：如果 patch 时 JobManager 正好在重启风暴里（wordsrv 滚动后 source 反复重连失败），operator 可能一直停在"ready for upgrade with savepoint → Savepoint Error"，此时按第 6 步的"标准复活动作"删 CR，把 `parallelism: 1`、`initialSavepointPath`、`execution.savepoint.ignore-unclaimed-state` 直接写进 YAML 重新 apply 一次到位。

发生了什么：`upgradeMode: savepoint` 让 operator 先做一次 savepoint 停旧作业，再按新 spec（parallelism 1）拉起新执行，并从 `initialSavepointPath` 指定的快照恢复状态——keyed state 按 key group 从 2 个 subtask 迁移合并到 1 个（本例的窗口计数状态因无 uid 被跳过，恢复语义本身已验证：REST 里 `restored>=1`）。

## 第 9 步：验证恢复成功

```bash
# [master]（port-forward 若已断则重新建立）
NEW_ID=$(curl -s http://localhost:8081/jobs/overview | grep -o '"jid":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
curl -s http://localhost:8081/jobs/$NEW_ID/checkpoints | grep -o '"counts":{[^}]*}'
# 预期: "counts":{"restored":1,"completed":3,...}   ← restored=1 即成功从 savepoint 恢复
kubectl -n flink-lab get flinkdeployment wordcount -o jsonpath='{.status.jobStatus.state}'; echo
# 预期: RUNNING
```

清理（可选，验收前别做）：

```bash
# [master]
kubectl -n flink-lab delete flinkdeployment wordcount
kubectl -n flink-lab delete deployment,service wordsrv
helm uninstall flink-kubernetes-operator -n flink-operator
kubectl delete namespace flink-lab flink-operator
sudo rm -rf /var/flink-state
```

坑位提醒：卸载顺序很重要——如果 operator 先没了（卸载 helm 或删 ns）而 `FlinkDeployment`/`FlinkStateSnapshot` 还在，它们的 finalizer 没人摘，`flink-lab` 会卡在 Terminating；补救是手工清 finalizer：`kubectl -n flink-lab patch <资源> <名字> --type=merge -p '{"metadata":{"finalizers":[]}}'`。

## 附：check.sh 通过结果

```text
# [master]
$ chmod +x check.sh && ./check.sh
PASS: Flink Operator 在 flink-operator namespace 中 Available
PASS: namespace flink-lab 存在
PASS: wordsrv Deployment 2 副本全部 Available
PASS: Service wordsrv 存在且 endpoints 非空
PASS: FlinkDeployment wordcount 存在
PASS: FlinkDeployment jobStatus.state 为 RUNNING
PASS: Service wordcount-rest 存在且 endpoints 非空
PASS: flink-lab 内至少 4 个 Running Pod（JM+TM+2 个词源）
PASS: REST: 至少 1 个 TaskManager 已注册
PASS: REST: 存在 state=RUNNING 的作业
PASS: REST: 存在 checkpoint completed>=1 的作业
PASS: REST: 存在从 savepoint 恢复（restored>=1）的作业
PASS: master 上 /var/flink-state/savepoints 下存在 savepoint
PASS: wordsrv 的 FLOOD 已切回 0

SCORE: 14/14
```
