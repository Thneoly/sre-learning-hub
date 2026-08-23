# 04 · 工作负载控制器：Deployment、HPA、StatefulSet、DaemonSet 与 Job

> 模块：04-k8s-fundamentals ｜ 建议时长：3 小时 ｜ 关联认证：CKA-应用管理（考试占比最大的一块）

## 学习目标

- 能画出 Deployment→ReplicaSet→Pod 的属主链，并解释滚动更新过程中三层数量的变化
- 能根据可用性要求计算并配置 maxSurge / maxUnavailable，预测滚动的每一步
- 能解释 rollout undo 能回滚的根本原因（旧 RS 保留）以及 revisionHistoryLimit 的代价
- 能解释 HPA 的指标来源与稳定窗口，避免它和手动扩缩容打架
- 能为有状态、节点级、批处理负载分别选择 StatefulSet / DaemonSet / Job 并配置关键字段

## 1. 为什么要控制器

裸 Pod 唯一的"自愈"是 kubelet 在**同节点**按 restartPolicy 重启；节点一挂或进程反复崩溃耗尽退避，Pod 就没了。控制器 = 第 01 章的 reconcile 循环 + Pod 模板：把"运行 N 个副本"变成持续维护的期望状态，Pod 变成可丢弃的消耗品。

## 2. Deployment → ReplicaSet → Pod：属主链

Deployment 不直接管理 Pod。分层：**Deployment 管"要什么版本的多少副本"（通过 RS），ReplicaSet 管"维持副本数"，Pod 是消耗品**。

```
# [图] 属主链与一次滚动更新中三层的数量变化
Deployment(web)  spec.replicas=4, template(nginx:1.27)
   │ 创建/缩放 RS (每个"模板版本"对应一个 RS)
   ├──► ReplicaSet(web-6b8f74c95b)  template(nginx:1.27)  4 → 0   ← 旧 RS: 缩到 0 但保留
   └──► ReplicaSet(web-77d48f8f5d)  template(nginx:1.29)  0 → 4   ← 新 RS: 滚动期间创建
              │ 每个 RS 按自己 template 的 hash 生成
              └──► Pod ×4 (labels 里带 pod-template-hash, owner=RS)
```

- RS 用 `pod-template-hash` 标签区分"我"的 Pod 和别的 RS 的 Pod（即便 label 选择器看起来一样）；
- 每个 RS 的名字后缀就是模板 hash，`rollout undo` 能秒回滚的秘密全在这里（第 4 节）。

```bash
# [master] 观察属主链
kubectl create deployment web --image=nginx:1.27 --replicas=4
kubectl get rs -l app=web -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas
kubectl get pod -l app=web -o jsonpath='{.items[0].metadata.name}{"\n"}'   # 名字前缀 = RS 名
```

## 3. 滚动更新：maxSurge / maxUnavailable 图解

strategy 有两种：`Recreate`（先全杀再建，有停机窗口）和 `RollingUpdate`（默认）。后者用两个旋钮控制节奏：

- `maxSurge`：允许**超出**期望副本数的上限（百分比向上取整，如 4×25%=1）
- `maxUnavailable`：允许**不可用**副本数的上限（百分比向下取整，4×25%=1）

滚动期间恒定的约束：`总副本 ≤ replicas + maxSurge` 且 `可用副本 ≥ replicas − maxUnavailable`。

```
# [图] replicas=4, maxSurge=25%(=1), maxUnavailable=25%(=1) 的完整滚动
时间  旧RS(web-6b8f)  新RS(web-77d4)  总数  可用  说明
t0        4               0            4     4    set image 触发
t1        4               1(启动中)     5     4    新建第 1 个新 Pod(surge 用满)
t2        3               2            5     4    新 Pod Ready → 删 1 旧 Pod
t3        3               3            5~6   4    每一轮: +1 新(等 Ready) → −1 旧
t4        1               4            5     4    ...
t5        0               4            4     4    旧 RS 缩到 0, 滚动完成
```

三个实战推论：

- `maxUnavailable=0` 且 `maxSurge=1`：永不缩容，零中断，但副本数要能腾出 surge 余量（资源冗余换可用性）；
- `maxSurge=0` 且 `maxUnavailable=1`：不占额外资源，但每一步都少一个可用副本（省资源换可用性）；
- 新 Pod 必须**通过 readiness 且待满 `minReadySeconds`** 才算可用、才允许删下一个旧的——readiness 配错，滚动要么龟速要么掉流量（呼应第 03 章）。

```yaml
# [master] 保存为 web-roll.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  labels:
    app: web
spec:
  replicas: 4
  minReadySeconds: 10
  revisionHistoryLimit: 5
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%
      maxUnavailable: 25%
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        resources:
          requests: {cpu: 100m, memory: 128Mi}   # HPA 利用率百分比依赖 requests
          limits: {memory: 256Mi}
```

```bash
# [master] 终端 A 先挂上观察, 终端 B 触发滚动
kubectl apply -f web-roll.yaml
kubectl annotate deployment web kubernetes.io/change-cause="init 1.27" --overwrite
# 终端 A: kubectl get rs -l app=web -w    (看两个 RS 的 DESIRED 此消彼长)
# 终端 B: 触发更新并记录原因
kubectl set image deployment/web nginx=nginx:1.29
kubectl annotate deployment web kubernetes.io/change-cause="upgrade to 1.29" --overwrite
kubectl rollout status deployment/web
kubectl get rs -l app=web -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas
# 预期: 旧 RS DESIRED=0 仍存在, 新 RS DESIRED=4

# [master] 暂停/恢复: 批量改多项配置只触发一次滚动
kubectl rollout pause deployment/web
kubectl set resources deployment/web -c=nginx --limits=memory=256Mi
kubectl set image deployment/web nginx=nginx:1.29-alpine
kubectl rollout resume deployment/web     # resume 后才真正开始滚
```

## 4. rollout undo：为什么旧 RS 能救你

Deployment 的每个"模板版本"都是一个 RS 对象，历史版本 = 被缩到 0 的旧 RS 列表。`rollout undo` **不是重新拉取旧配置文件，而是把旧 RS 重新扩容到目标副本数、把新 RS 缩到 0**——一次反向滚动更新。所以回滚速度只取决于旧镜像在节点上的本地缓存，秒级完成。

```bash
# [master] 版本历史与回滚
kubectl rollout history deployment/web          # 靠 change-cause 注解区分版本
kubectl rollout history deployment/web --revision=2
kubectl rollout undo deployment/web             # 回到上一版
kubectl rollout undo deployment/web --to-revision=2
kubectl rollout status deployment/web
```

代价与边界：`revisionHistoryLimit`（默认 10，本实验设 5）控制保留多少个旧 RS；被淘汰的版本无法 undo，只能重新 apply 旧 YAML。另外 undo 回滚的是**模板**，`replicas` 维持当前值。

## 5. HPA：指标源与稳定窗口

HPA（HorizontalPodAutoscaler）= 第 01 章循环的又一个实例：**读取指标 → 改 Deployment 的 spec.replicas**。核心公式：

```
# [公式] HPA 核心算法
期望副本 = ceil( 当前副本 × 当前指标值 / 期望指标值 )
(带 10% 容差: 变化在容差内不动, 防抖; 指标缺失/为 0 时不缩)
```

指标源是重点。HPA 通过 metrics.k8s.io / custom.metrics.k8s.io / external.metrics.k8s.io 三组聚合 API 取数：

| 指标源（metrics[].type） | 数据来自 | 典型用法 |
| --- | --- | --- |
| Resource（cpu/memory） | **metrics-server** 聚合 kubelet 的 cAdvisor 数据（必须先装） | CPU 利用率 60% 扩容 |
| Pods（每 Pod 自定义指标） | custom.metrics API（Prometheus Adapter / KEDA 等） | 每秒处理消息数 |
| External（集群外指标） | external.metrics API | 队列长度（SQS/Kafka lag） |
| Object / ContainerResource | 同上 / metrics-server | 按 Ingress QPS；单容器维度 |

behavior 的稳定窗口（stabilization window）解决"抖动来回打摆"：缩容时回看窗口期内（默认 300s）出现的**最小**建议值，只用最保守的那个；扩容默认无窗口、快速响应。

```yaml
# [master] 保存为 web-hpa.yaml（autoscaling/v2）
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web
  minReplicas: 2
  maxReplicas: 10
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - {type: Percent, value: 100, periodSeconds: 15}   # 每 15s 最多翻倍
      - {type: Pods, value: 4, periodSeconds: 15}
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 300                     # 缩容先冷静 5 分钟
      policies:
      - {type: Percent, value: 25, periodSeconds: 60}     # 每 60s 最多缩 25%
```

```bash
# [master] 前置: 装 metrics-server(kubeadm 的 kubelet 服务端证书是自签的, 追加参数)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl patch deployment -n kube-system metrics-server --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s
kubectl top nodes    # 能出数即 OK

# [master] 启用 HPA 并压测观察(前置: web 滚动实验的资源 requests 已配, 见 web-roll.yaml)
kubectl expose deployment web --port=80
kubectl apply -f web-hpa.yaml
kubectl run loadgen --image=busybox:1.36 --rm -it --restart=Never -- \
  sh -c 'for i in 1 2 3 4 5 6 7 8; do (while true; do wget -qO- http://web >/dev/null 2>&1; done) & done; wait'
# 另一终端: kubectl get hpa web -w
# 预期: TARGETS 从 3%/60% 一路上涨, REPLICAS 随之 4→5→…; Ctrl-C 停止压测后
# 缩容要等满 300s 稳定窗口才发生(正好验证 stabilizationWindowSeconds)
# 若 TARGETS 显示 <unknown>/60% 说明指标链路没通(见下方常见坑)
kubectl delete hpa web
kubectl delete svc web
```

铁律：HPA 接管 `spec.replicas` 后，**手动 `kubectl scale` 会被下一轮 HPA 计算覆盖**；同时配 HPA 与 VPA（同资源同维度）也会互相打架。GitOps 场景下 replicas 字段要么交给 HPA 全权管理，要么从 Git 中移除。

## 6. StatefulSet：身份、存储与顺序

Deployment 的副本是完全等价的"牲口"；StatefulSet（STS）的副本是有名字、有存储、有顺序的"宠物"。三个不可替代的能力：

1. **稳定网络标识**：必须配一个 headless Service（`clusterIP: None`）。每个 Pod 得到唯一 DNS 名 `<pod-name>.<service-name>.<namespace>.svc.cluster.local`，重启后名字与解析记录不变（Deployment 的 Pod 只有 Service 级轮询名，Pod 名每次都变）。
2. **独立存储**：`volumeClaimTemplates` 为**每个序号**生成专属 PVC（`data-pg-0`、`data-pg-1`…），Pod 重调度后**重新绑回原来的 PVC**——数据跟着序号走。注意：删除 STS 默认**不删** PVC。
3. **有序性**：默认 `podManagementPolicy: OrderedReady`，从 0 到 N−1 依次创建（前一个 Ready 才建下一个），删除/缩容按 N−1 到 0 **逆序**。`Parallel` 策略可关掉启动等待（DNS/存储身份不变）。

```yaml
# [master] 保存为 pg-sts.yaml（headless Service + StatefulSet + PVC 模板）
apiVersion: v1
kind: Service
metadata:
  name: db
spec:
  clusterIP: None          # headless: DNS 直接解析到各 Pod IP
  selector:
    app: pg
  ports:
  - port: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: pg
spec:
  serviceName: db          # 必须指向 headless Service
  replicas: 3
  selector:
    matchLabels:
      app: pg
  template:
    metadata:
      labels:
        app: pg
    spec:
      containers:
      - name: pg
        image: postgres:16
        env:
        - {name: POSTGRES_PASSWORD, value: "pgpass"}
        ports:
        - containerPort: 5432
  volumeClaimTemplates:
  - metadata:
      name: data           # PVC 名 = data-pg-<序号>
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
```

```bash
# [master] 观察有序创建与稳定标识
kubectl apply -f pg-sts.yaml
kubectl get pods -l app=pg -w          # 预期: pg-0 Running → pg-1 → pg-2 严格依次
kubectl get pvc                        # 预期: data-pg-0/1/2 三个独立 PVC
kubectl delete pod pg-1                # 预期: 新 Pod 仍叫 pg-1, 绑回 data-pg-1
kubectl run dnstest --image=busybox:1.36 --rm -it --restart=Never -- \
  nslookup pg-1.db.default.svc.cluster.local
kubectl scale sts pg --replicas=1      # 缩容: pg-2 → pg-1 逆序删除(pg-2 的 PVC 保留)
kubectl delete sts pg --wait=false     # 删除 STS 不删 PVC(数据安全设计), 需显式清理:
kubectl delete pvc data-pg-0 data-pg-1 data-pg-2
```

灰度技巧：`updateStrategy.rollingUpdate.partition: N` 表示"序号 ≥ N 的才更新"，先把 2 号当金丝雀。前提提醒：本实验环境需要默认 StorageClass，kubeadm 裸集群没有 CSI，需先装 local-path-provisioner（`kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml` 后把 local-path 设为默认），否则 PVC 一直 Pending、Pod 卡在 ContainerCreating/Pending。

## 7. DaemonSet：每节点一个

DaemonSet 保证"每个（符合条件的）节点恰一个副本"。典型用户：CNI（Calico）、kube-proxy、监控/日志 agent（node-exporter、filebeat）。要点：

- 新节点加入 → 自动补一个 Pod；节点移除 → Pod 被回收；不归 scheduler 的"配额"管，是按节点拓扑来的；
- 控制面节点默认有 `node-role.kubernetes.io/control-plane:NoSchedule` 污点，DaemonSet **不会自动容忍**，要在 spec 里显式写 tolerations 才能上 master；
- 更新策略与 Deployment 类似（RollingUpdate 支持 maxUnavailable/maxSurge）。

```yaml
# [master] 保存为 node-tools-ds.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-tools
spec:
  selector:
    matchLabels:
      app: node-tools
  template:
    metadata:
      labels:
        app: node-tools
    spec:
      tolerations:                       # 不写它, 单 master 集群上 master 不会有副本
      - key: node-role.kubernetes.io/control-plane
        operator: Exists
        effect: NoSchedule
      containers:
      - name: tools
        image: busybox:1.36
        command: ['sh', '-c', 'sleep infinity']
```

```bash
# [master] 验证
kubectl apply -f node-tools-ds.yaml
kubectl get pods -l app=node-tools -o wide    # 预期: 每个节点一行(含 master)
kubectl delete ds node-tools                  # 清理
```

## 8. Job 与 CronJob：跑完就退的负载

Job 的语义是"跑到成功为止"，与常驻服务相反：Pod 模板必须 `restartPolicy: OnFailure` 或 `Never`（禁止 Always）。四个关键参数：

| 参数 | 含义 | 场景 |
| --- | --- | --- |
| completions | 总共要成功几个 Pod（默认 1） | 固定总量 |
| parallelism | 最多同时跑几个（默认 1） | 并发度 |
| backoffLimit | 失败重试预算（默认 6，Pod 失败次数累计） | 挤掉坏任务 |
| activeDeadlineSeconds / ttlSecondsAfterFinished | 总时长上限 / 结束后自动清理 | 防挂死、防对象堆积 |

三种典型形态：非并行（completions=1）、固定并行（completions=N, parallelism=M）、工作队列（不设 completions，只设 parallelism，Pod 成功一个补一个直到达成）。

```yaml
# [master] 保存为 job-demo.yaml: 6 个任务、2 并发、失败重试 4 次、完成 2 分钟后自动清理
apiVersion: batch/v1
kind: Job
metadata:
  name: batch-demo
spec:
  completions: 6
  parallelism: 2
  backoffLimit: 4
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      containers:
      - name: work
        image: busybox:1.36
        command: ['sh', '-c', 'echo "job item done"; sleep 5']
```

```bash
# [master] 观察: 同一时刻至多 2 个 Pod, 共 6 个 Completed
kubectl apply -f job-demo.yaml
kubectl get jobs
kubectl get pods -l job-name=batch-demo -w
kubectl delete job batch-demo
```

CronJob = 按 crontab 格式定时生成 Job。关键差异项：`concurrencyPolicy`（Allow 默认 / Forbid 跳过重叠 / Replace 杀掉旧的再跑）、`startingDeadlineSeconds`（错过多久内还补跑）、历史保留（successfulJobsHistoryLimit 默认 3、failed 默认 1）。坑：schedule 按 **kube-controller-manager 所在主机时区**解释，且 cron 精度到分钟，任务可能晚几十秒才起。

```yaml
# [master] 保存为 cron-demo.yaml: 每 2 分钟一次, 禁止重叠
apiVersion: batch/v1
kind: CronJob
metadata:
  name: minute-report
spec:
  schedule: "*/2 * * * *"
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: report
            image: busybox:1.36
            command: ['sh', '-c', 'date; echo report done']
```

```bash
# [master] 验证后清理
kubectl apply -f cron-demo.yaml
kubectl get cronjobs
kubectl delete cronjob minute-report
```

## 实战演练

一次跑完五类控制器的核心行为（各对象定义详见对应小节的 YAML）：

```bash
# [master] 1) Deployment 属主链与滚动（第 2/3 节 web-roll.yaml）
kubectl apply -f web-roll.yaml
kubectl annotate deployment web kubernetes.io/change-cause="init 1.27" --overwrite
kubectl set image deployment/web nginx=nginx:1.29
kubectl annotate deployment web kubernetes.io/change-cause="upgrade to 1.29" --overwrite
kubectl rollout status deployment/web
kubectl get rs -l app=web -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas
# 预期: 旧 RS DESIRED=0 仍保留，新 RS DESIRED=4 —— 属主链与"undo 的本钱"一次看清

# [master] 2) 版本历史与回滚（第 4 节）
kubectl rollout history deployment/web
kubectl rollout undo deployment/web
kubectl rollout status deployment/web
kubectl get deployment web -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# 预期: 回到 nginx:1.27，秒级完成（旧 RS 只是重新扩容）

# [master] 3) Job 并发与完成计数（第 8 节 job-demo.yaml）
kubectl apply -f job-demo.yaml
kubectl get pods -l job-name=batch-demo -w
# 预期: 同一时刻至多 2 个 Pod 在跑，最终 6 个 Completed（Ctrl-C 退出 watch）
kubectl delete job batch-demo

# [master] 4) DaemonSet 覆盖全部节点（第 7 节 node-tools-ds.yaml）
kubectl apply -f node-tools-ds.yaml
kubectl get pods -l app=node-tools -o wide
# 预期: 每个节点一行（含 master，因为有 control-plane toleration）
kubectl delete ds node-tools

# [master] 5) HPA 与滚动实验的资源清理
kubectl delete hpa web --ignore-not-found
kubectl delete svc web --ignore-not-found
kubectl delete deployment web --wait=false
```

StatefulSet 的有序性验证（前置：默认 StorageClass，见第 6 节）可按需追加 `pg-sts.yaml` 的 apply/scale/delete 循环。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| HPA TARGETS 显示 `<unknown>/60%` | metrics-server 没装/没通（证书、地址） | 见第 5 节安装步骤；`kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes` 验证 |
| 手动 scale 后副本又变回去 | HPA 每十几秒重算并覆盖 spec.replicas | 要么删 HPA，要么所有变更只改 HPA 参数 |
| StatefulSet Pod 卡 Pending/ContainerCreating | 没有默认 StorageClass，PVC 未绑定 | 装 local-path-provisioner 或接真实 CSI |
| 删了 STS 重建，数据"丢了" | PVC 故意保留（数据安全设计），新 Pod 未复用同序号 PVC | 确认 PVC 名与序号对应；不要的旧数据手动删 PVC |
| DaemonSet 在 master 上没有副本 | 未容忍 control-plane 污点 | 显式写 tolerations |
| Job 一直不 Complete | 命令退出码非 0 且重试预算没耗尽；或 sidecar 不退出（旧版本） | `kubectl logs` 查退出码；1.29+ 用原生 sidecar |
| CronJob 不触发 | 时区/startingDeadlineSeconds 错过 | 对照 controller-manager 主机时间；describe cronjob 看 LastScheduleTime |
| rollout undo 提示没有历史 | revisionHistoryLimit 太小或做过 --cascade=orphan 删除 | 保留足够 revision；真正兜底是 Git 里的旧 YAML |

## 自测

1. replicas=4、maxSurge=25%、maxUnavailable=25% 的滚动中，任意时刻 Pod 总数与可用数的边界分别是多少？若把两者都改成 0 会怎样？

<details><summary>答案</summary>

总数上限 = 4+1=5，可用下限 = 4−1=3。maxSurge=0 且 maxUnavailable=0 在数学上意味着"不能多也不能少"，滚动无法推进，新 Pod 永远建不出来（旧的不敢删）； apiserver 校验层面 RollingUpdate 也要求两者不能同时为 0。
</details>

2. 为什么 `rollout undo` 通常比重新 `kubectl apply` 旧 YAML 快且稳？什么情况下 undo 无能为力？

<details><summary>答案</summary>

undo 只是把已存在的旧 RS 从 0 扩到目标副本数：镜像层大概率还在节点本地缓存、无需重新拉取，且模板对象是现成的。重新 apply 要走完整的校验/准入/建 RS/拉镜像链路。undo 无能为力的场景：旧 RS 被 revisionHistoryLimit 淘汰、Deployment 被 cascade 删除重建过、或想回滚的不是模板而是 replicas/HPA 等其他字段。
</details>

3. HPA 显示 CPU `<unknown>`，Deployment 一动不动。给出至少三个可能的根因和对应验证命令。

<details><summary>答案</summary>

(1) metrics-server 未部署或 CrashLoop：`kubectl -n kube-system get pod -l k8s-app=metrics-server`；(2) kubelet 10250 证书校验失败（自签证书）：metrics-server 日志报 x509，加 `--kubelet-insecure-tls`；(3) Pod 没有定义 resources.requests.cpu（利用率百分比无从计算）：`kubectl get pod -o jsonpath` 检查 resources；(4) 聚合 API 不通：`kubectl get --raw /apis/metrics.k8s.io/v1beta1/nodes`。
</details>

4. 为什么 StatefulSet 必须配 headless Service？普通 ClusterIP Service 会破坏它的哪个承诺？

<details><summary>答案</summary>

STS 的网络身份承诺是"每个序号有独立、稳定的 DNS 名"。headless Service（clusterIP: None）让 DNS 查询直接返回各 Pod 的 A 记录（pg-0.db、pg-1.db…）；普通 Service 的 DNS 只解析到 ClusterIP 并做负载均衡，客户端无法寻址"具体的那个副本"，主从选举、按节点寻址（如 MongoDB/ES 集群）都做不了。
</details>

5. completions=6、parallelism=2 的 Job，其中 1 个任务连续失败。Job 的终局是什么？backoffLimit 计的是什么数？

<details><summary>答案</summary>

backoffLimit 统计的是**失败的 Pod 总数**（重启消耗重试预算的语义与 restartPolicy 有关：Never 下每次新建 Pod 计一次失败，OnFailure 下容器级重试累计到一定次数也算）。当失败累计超过 4（本例配置），Job 控制器停止补位，Job 进入 Failed，`kubectl describe job` 的 Events 可见 `Job has reached the specified backoff limit`。
</details>

## 延伸阅读

- Deployment（含滚动策略与 rollback）：https://kubernetes.io/docs/concepts/workloads/controllers/deployment/
- ReplicaSet：https://kubernetes.io/docs/concepts/workloads/controllers/replicaset/
- HPA 与 autoscaling/v2 行为配置：https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale/
- StatefulSet：https://kubernetes.io/docs/concepts/workloads/controllers/statefulset/
- DaemonSet：https://kubernetes.io/docs/concepts/workloads/controllers/daemonset/
- Jobs 与 CronJobs：https://kubernetes.io/docs/concepts/workloads/controllers/job/
