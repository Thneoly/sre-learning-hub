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

- `nc -l -p 9000` 每次只接受一条 TCP 连接，外层 `while true; sleep 1` 保证断开后 1 秒内重新监听——配合作业的重启策略，socket 抖动可以自愈；
- 2 副本对应 Flink 作业的 source 并行度 2：Service 把两条连接分别落到两个 Pod，各自独立供数；
- `FLOOD=1` 时改喂 `yes hello`：全量单一热点词 `hello`，制造"热点 key + 高流速"两个现象。

## 第 4 步：部署 FlinkDeployment（Application 模式）

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
  flinkConfiguration:
    execution.checkpointing.interval: 10s
    execution.checkpointing.externalized-checkpoint-retention: RETAIN_ON_CANCELLATION
    state.checkpoints.dir: file:///opt/flink/state/checkpoints
    state.savepoints.dir: file:///opt/flink/state/savepoints
    restart-strategy: fixed-delay
    restart-strategy.fixed-delay.attempts: "10"
    restart-strategy.fixed-delay.delay: 5s
    taskmanager.numberOfTaskSlots: "2"
  volumes:
    - name: flink-state
      hostPath:
        path: /var/flink-state
        type: Directory
  jobManager:
    resource:
      memory: 1024m
      cpu: 0.5
    volumeMounts:
      - name: flink-state
        mountPath: /opt/flink/state
  taskManager:
    resource:
      memory: 1024m
      cpu: 1
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
# 预期几分钟后: NAME       PHASE     STATUS   AGE
#               wordcount  RUNNING   RUNNING  2m
```

关键点：

- `spec.job` 存在即为 Application 模式：main() 在 JobManager 里跑，集群随作业而生；
- checkpoint 间隔 10s + `state.checkpoints.dir` 落 hostPath —— 状态在 Pod 重建后仍在；
- `upgradeMode: savepoint` 决定后面每次升级先做 savepoint 再停；
- 示例 jar 用 processing time 滚动窗口（`TumblingProcessingTimeWindows`），无需 watermark 即可出结果，适合当部署练手件。

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

## 第 7 步：触发 savepoint

```bash
# [master]
kubectl -n flink-lab patch flinkdeployment wordcount --type merge \
  -p '{"spec":{"job":{"savepointTriggerNonce":1}}}'
kubectl -n flink-lab get flinkdeployment wordcount \
  -o jsonpath='{.status.jobStatus.savepointPath}'; echo
# 预期: file:///opt/flink/state/savepoints/savepoint-1a2b3c-4d5e6f
sudo ls /var/flink-state/savepoints/
# 预期: savepoint-1a2b3c-4d5e6f   （nonce 递增可重复触发: 2, 3, ...）
```

savepoint 由 TaskManager 执行写入挂载的 hostPath；CR 的 status 字段与目录两边互相印证。

## 第 8 步：从 savepoint 恢复并把并行度改为 1

```bash
# [master] 路径换成上一步的实际输出
kubectl -n flink-lab patch flinkdeployment wordcount --type merge \
  -p '{"spec":{"job":{"parallelism":1,"fromSavepoint":"file:///opt/flink/state/savepoints/savepoint-1a2b3c-4d5e6f"}}}'
kubectl -n flink-lab get flinkdeployment wordcount -w
# 预期经历 SAVEPOINT/升级 过程后回到: PHASE RUNNING, jobStatus.state RUNNING
```

发生了什么：`upgradeMode: savepoint` 让 operator 先做一次 savepoint 停旧作业，再按新 spec（parallelism 1）拉起新执行，并从 `fromSavepoint` 指定的快照恢复状态——keyed state 按 key group 从 2 个 subtask 迁移合并到 1 个。

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
