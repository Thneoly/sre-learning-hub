# 03 · Pod 深入：命名空间本质、生命周期、探针与优雅退出

> 模块：04-k8s-fundamentals ｜ 建议时长：3 小时 ｜ 关联认证：CKA-应用管理·故障排查 / CKS-Pod 安全上下文

## 学习目标

- 能解释 Pod 与容器的关系、pause 容器的作用，并在集群上验证容器间 localhost 互通与共享卷
- 能对照三层状态模型（phase / condition / container state）解释 kubectl 显示的 Init:0/2、CrashLoopBackOff、Terminating
- 能为同一个应用正确选择三种探针并准确预测每种探针失败后的系统行为
- 能用 1.29+ 的原生 sidecar（initContainers + restartPolicy: Always）替代"循环等待"式 sidecar
- 能排查滚动更新期间的流量丢失问题（readiness 延迟 / preStop / terminationGracePeriodSeconds）

## 1. Pod 的本质：一组共享命名空间的容器

Pod 不是"高级容器"，而是**调度与共享的最小单位**。同一 Pod 内的所有容器共享：network（同一个 IP、同一组端口空间）、IPC、UTS、hostname，以及 Pod 级 volumes；PID 命名空间默认隔离，可用 `shareProcessNamespace: true` 打开。

这份共享是靠 **pause 容器**（容器运行时视角叫 sandbox / infra 容器）实现的：kubelet 先让运行时创建 pause，它 hold 住 network namespace 等并成为"锚点"，业务容器全部加入这些已存在的 namespace。pause 几乎不耗资源（sleep + 收割僵尸进程），却解决了关键问题：**业务容器崩溃重启时，Pod IP 不变**——因为持有 IP 的不是它，是 pause。

```
# [图] Pod 内部视图（worker 节点上 crictl 看到的真实结构）
┌── Pod (10.244.1.15, 持有者: pause 容器) ──────────────────────┐
│  ┌──────────┐   ┌──────────┐   ┌───────────────────────────┐ │
│  │ pause    │   │ nginx    │   │ log-shipper              │ │
│  │ 持有 net/│◄──┤ 共享 net │◄──┤ 共享 net + /var/log/nginx │ │
│  │ IPC/UTS  │   │          │   │ (emptyDir 卷)             │ │
│  └──────────┘   └──────────┘   └───────────────────────────┘ │
│  nginx 崩了 → 只重建 nginx 容器, Pod IP/网络栈原封不动          │
└───────────────────────────────────────────────────────────────┘
```

推论：同 Pod 容器用 `localhost` 互访；同 Pod 容器**不能监听同一端口**（共享端口空间）；"把两个有亲和关系的进程放一个 Pod"不是为了省资源，是为了共享这套命名空间与生命周期。

```yaml
# [master] 保存为 pod-anatomy.yaml: 一个 Pod, 两个容器, 一块共享卷
apiVersion: v1
kind: Pod
metadata:
  name: pod-anatomy
spec:
  containers:
  - name: web
    image: nginx:1.27
    volumeMounts:
    - name: shared
      mountPath: /usr/share/nginx/html
  - name: writer
    image: busybox:1.36
    command: ['sh', '-c', 'while true; do echo "written at $(date)" >> /data/index.html; sleep 5; done']
    volumeMounts:
    - name: shared
      mountPath: /data
  volumes:
  - name: shared
    emptyDir: {}
```

```bash
# [master] 验证共享网络与共享卷
kubectl apply -f pod-anatomy.yaml
kubectl wait --for=condition=Ready pod/pod-anatomy --timeout=60s
# 1) writer 容器内用 localhost 访问 nginx(writer 里只有 wget)
kubectl exec pod-anatomy -c writer -- wget -qO- http://localhost:80 | head -2
# 预期: 输出 "written at ..." —— writer 写的文件经共享卷被 nginx 对外提供
# 2) 从节点层看 pause 容器
kubectl get pod pod-anatomy -o wide   # 记下所在节点, ssh 过去执行:
# [worker1] sudo crictl ps | grep -E 'pod-anatomy|Pause'
```

PID 命名空间共享演示（默认隔离，打开后互相可见进程）：

```yaml
# [master] 保存为 pid-share.yaml
apiVersion: v1
kind: Pod
metadata:
  name: pid-share
spec:
  shareProcessNamespace: true
  containers:
  - name: shell
    image: busybox:1.36
    command: ['sh', '-c', 'sleep 3600']
  - name: nginx
    image: nginx:1.27
```

```bash
# [master] shell 容器里能看到 nginx 容器的进程
kubectl exec pid-share -c shell -- ps aux | grep nginx | head -3
# 注意: 此时 PID 1 是 pause 而不是业务进程, 发信号的目标变了, 这是有意的设计
```

## 2. 生命周期：三层状态模型

kubectl 的 STATUS 列混装了三种不同层次的信息，排障前必须分清：

| 层次 | 字段 | 取值 | 谁写 |
| --- | --- | --- | --- |
| Pod phase | `status.phase` | Pending / Running / Succeeded / Failed / Unknown | apiserver/kubelet |
| Pod conditions | `status.conditions[]` | PodScheduled、PodReadyToStartContainers（1.29+ beta）、Initialized、ContainersReady、Ready 等 | kubelet / scheduler |
| 容器 state | `status.containerStatuses[].state` | Waiting（含 reason）/ Running / Terminated | kubelet |

要点：

- **phase 只有 5 个值**。`CrashLoopBackOff`、`Terminating`、`Init:0/2` 都**不是 phase**，是 kubectl 为了直觉加的"显示状态"（STATUS 列）。脚本判断状态请用 conditions 或 container state，别 grep 中文/显示串。
- conditions 里最有用的是 `Ready`（= 能否接流量，Service 只把 Ready 的 Pod 加入 Endpoints）和 `PodScheduled`（false 时说明调度失败，看 Events 里的 FailedScheduling）。
- 容器 Waiting 状态的 `reason` 是排障金矿：`ContainerCreating`（在拉镜像/挂卷）、`CrashLoopBackOff`（反复崩溃，在退避中）、`ImagePullBackOff`（拉镜像失败，在退避中）、`PodInitializing`（init 容器阶段）。

```
# [图] 一个 Pod 的典型生命线
创建 ─► Pending ──────────────┐ (scheduler 绑定节点, PodScheduled=True)
  phase=Pending               ▼
  ┌────────────── kubelet 接手 ─────────────────┐
  │ 建 sandbox(网络就绪, PodReadyToStartContainers │
  │ =True) → 依次跑 init 容器(Initialized=True)    │
  │ → 创建容器(Waiting) → Running → 探针通过       │
  │   (ContainersReady=True, Ready=True)          │
  └───────────────────────────────────────────────┘
                  │
     正常结束 ────┼──── 崩溃(restartPolicy 决定是否重启)
                  ▼
        Succeeded / Failed(终态)
        被删除 ─► Terminating(显示状态) → 优雅退出流程(第 5 节) → 对象消失
```

```bash
# [master] 一次看清三层状态
kubectl run demo --image=nginx:1.27
kubectl wait --for=condition=Ready pod/demo --timeout=60s
kubectl get pod demo -o jsonpath='{.status.phase}{"\n"}'
kubectl get pod demo -o jsonpath='{range .status.conditions[*]}{.type}={.status} {end}{"\n"}'
kubectl get pod demo -o jsonpath='{.status.containerStatuses[0].state}{"\n"}'
# 预期: 依次为 Running / PodScheduled=True ... Ready=True / {"running":{...}}
kubectl delete pod demo
```

## 3. 三种探针：语义差异与失败后果

探针由 **kubelet 在节点本地执行**（不经过 apiserver），语义按"回答的问题"区分：

| 探针 | 回答的问题 | 失败后果 | 典型配置对象 |
| --- | --- | --- | --- |
| startupProbe | 应用**启动完成了吗** | 失败 → 杀容器并按 restartPolicy 重启；成功前 **liveness/readiness 被暂停** | 启动很慢的 JVM/老应用 |
| livenessProbe | 应用**活着吗**（有无死锁） | 失败 → 杀容器并重启 | 进程在但不工作的软故障 |
| readinessProbe | 应用**能接流量吗** | 失败 → Pod IP 从所有匹配 Service 的 Endpoints 摘除；**不重启** | 预热、依赖暂时不可用、过载降流 |

三种机制（handler）：`httpGet`（2xx/3xx 算成功）、`tcpSocket`（能建立连接即成功，**不证明能处理请求**）、`exec`（退出码 0 即成功）、`grpc`。

常见默认值：`periodSeconds=10`（httpGet/tcpSocket/exec；grpc 为 10）、`timeoutSeconds=1`、`successThreshold=1`、`failureThreshold=3`；startupProbe 出厂默认 `failureThreshold=30 × periodSeconds=10`，即给应用 5 分钟启动预算。

```yaml
# [master] 保存为 probe-demo.yaml: 三种探针的完整示例
apiVersion: v1
kind: Pod
metadata:
  name: probe-demo
  labels:
    app: probe-demo
spec:
  containers:
  - name: app
    image: nginx:1.27
    ports:
    - containerPort: 80
    startupProbe:              # 先等它成功, 其他探针才开始
      httpGet:
        path: /
        port: 80
      failureThreshold: 30
      periodSeconds: 2
    readinessProbe:            # /ready 不存在 → 永远 NotReady
      httpGet:
        path: /ready
        port: 80
      periodSeconds: 5
    livenessProbe:             # /healthz 不存在 → 反复重启
      httpGet:
        path: /healthz
        port: 80
      periodSeconds: 10
      failureThreshold: 3
```

```bash
# [master] 观察两种失败后果的差异
kubectl apply -f probe-demo.yaml
kubectl expose pod probe-demo --port=80          # 建 Service 便于观察 Endpoints
kubectl get pod probe-demo -w                    # 预期: 0/1 Running, RESTARTS 缓慢增长
kubectl get endpoints probe-demo                 # 预期: <none> (readiness 失败被摘除)
kubectl describe pod probe-demo | grep -A4 'Liveness'
# 预期: Events 里出现 Liveness probe failed: HTTP probe failed with statuscode: 404
kubectl delete pod probe-demo; kubectl delete svc probe-demo
```

读数方法：RESTARTS 增长 = liveness 在杀容器；READY 0/1 但 RESTARTS 为 0 = readiness 在摘流量。两个都配错会看到"重启 + 摘除"叠加。

配置经验（避免连环事故）：

- liveness **宁松勿紧**：liveness 探到依赖服务（DB/下游）就重启，会放大故障——检查依赖是 readiness 的职责，重启解决不了"下游挂了"。
- 启动慢的应用用 startupProbe，而不是把 liveness 的 initialDelaySeconds 调到天荒地老：前者自适应，后者是拍脑袋定值。
- tcpSocket 只证明端口通。对"端口开但线程池满"的应用，用 httpGet。

## 4. init 容器与原生 sidecar

### 4.1 普通 init 容器

init 容器按定义顺序**串行执行，每个必须成功退出，全部完成后主容器才启动**。与主容器的差异：不支持 lifecycle 与三种探针（它的一生只有"成功/失败"）；Pod `restartPolicy: Always` 时 init 容器按 `OnFailure` 对待（失败重跑该 init，而不是放弃 Pod）；`restartPolicy: Never` 时 init 失败直接判定 Pod Failed。

用途：等依赖就绪（`until nslookup db; do sleep 2; done`）、用专用工具镜像做初始化（不给主镜像塞工具，CKS 攻击面更小）、给 Secret 做安全中转。

### 4.2 原生 sidecar（1.28 alpha / 1.29 beta 默认开启 / 1.33 GA）

老式 sidecar 是"普通容器 + 启动顺序玄学"（主容器可能比日志 sidecar 先起）。原生 sidecar 的写法：**写在 initContainers 里，但容器级 `restartPolicy: Always`**。语义：

- 启动顺序：与其他 init 容器一样**先于主容器**，但不会退出（Always）；
- 主容器在所有 sidecar **启动成功**（startupProbe 通过）后才开始；顺序 = initContainers 顺序 → containers 顺序；
- 终止顺序（1.29+ kubelet 保证）：**主容器先停，sidecar 最后停**，多个 sidecar 按定义的**逆序**停止——日志 sidecar 天然活到主容器退出之后，把最后几行日志发完；
- 忽略 Pod 级 restartPolicy：无论怎么退出都重启，即使 exit 0；
- Job 支持：Job 完成判定只看主容器，sidecar 不阻塞 Job 收尾（1.29 之前 sidecar 会把 Job 拖成永不完成）。

```yaml
# [master] 保存为 sidecar-demo.yaml: 日志 sidecar + 普通 init 容器
apiVersion: apps/v1
kind: Deployment
metadata:
  name: sidecar-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: sidecar-demo
  template:
    metadata:
      labels:
        app: sidecar-demo
    spec:
      initContainers:
      - name: welcome            # 普通 init: 跑完就退出
        image: busybox:1.36
        command: ['sh', '-c', 'echo "app initialized at $(date)" > /www/index.html']
        volumeMounts: [{name: www, mountPath: /www}]
      - name: log-shipper        # 原生 sidecar: 常驻, 主容器之前启动
        image: busybox:1.36
        restartPolicy: Always    # ← 这一行让它成为 sidecar
        command: ['sh', '-c', 'tail -F /var/log/nginx/access.log 2>&1']
        volumeMounts: [{name: logdir, mountPath: /var/log/nginx}]
      containers:
      - name: nginx
        image: nginx:1.27
        volumeMounts:
        - {name: www, mountPath: /usr/share/nginx/html}
        - {name: logdir, mountPath: /var/log/nginx}
      volumes:
      - name: www
        emptyDir: {}
      - name: logdir
        emptyDir: {}
```

```bash
# [master] 验证
kubectl apply -f sidecar-demo.yaml
kubectl get pods -l app=sidecar-demo
# 预期: 2/2 Running; describe 里可见 initContainers 两项, log-shipper 状态为常驻
kubectl exec deploy/sidecar-demo -c log-shipper -- tail -3 /var/log/nginx/access.log
# 触发一条访问日志再 tail 一次, 确认 sidecar 在持续工作
kubectl run curl1 --image=busybox:1.36 --rm -it --restart=Never -- \
  wget -qO- http://$(kubectl get pod -l app=sidecar-demo -o jsonpath='{.items[0].status.podIP}')
```

## 5. 优雅退出：terminationGracePeriodSeconds 与 preStop

删除 Pod 时的完整时序（依据官方文档的 Pod Termination Flow）：

```
# [图] 优雅退出时序（terminationGracePeriodSeconds = G，默认 30s）
kubectl delete pod ──► apiserver 给 Pod 打上 deletionTimestamp(G 秒后视为死亡)
                        │
   控制面(并发)          │ kubelet(节点上)
   Endpoints 控制器立刻   │ ① 若定义了 preStop 且 G≠0: 在容器内执行 hook
   把该 Pod 标记为        │    （hook 卡在退出中不结束 → G 耗尽后 kubelet 仅为
   terminating/ready=   │     preStop 追加一次 2 秒的宽限, 然后放弃等待）
   false → LB 摘流量      │ ② preStop 结束后, 运行时向每个容器的 PID 1 发 SIGTERM
   ReplicaSet 不再把它    │    （有 sidecar 时: 先主容器, 全停后再逆序停 sidecar）
   计入副本               │ ③ G 耗尽仍有进程活着 → SIGKILL
                        │ ④ kubelet 把 phase 置为终态(Succeeded/Failed)
                        │    并以 grace=0 强制移除 Pod 对象
```

四个高频细节：

- **preStop 与 SIGTERM 是先后关系**（preStop 完成后才发 TERM），但它们共享同一个 G。preStop 需要 40s 就把 G 设为 45+，否则 hook 会被掐断。
- **信号发给每个容器自己的 PID 1**（即容器入口进程）。若入口是 `sh -c '...'`，PID 1 是 sh，而 sh 默认不向子进程转发 TERM——这是"容器优雅退出不生效"的最常见根因。解法：command 用 exec 形式直接顶替 shell（如 `['sh','-c','exec nginx -g "daemon off;"']`）。另注意开启 `shareProcessNamespace` 后整个 Pod 的 PID 1 是 pause，信号语义随之变化。
- **kubelet 或运行时中途重启，整个优雅退出从头再来一遍，并重置完整的 G**。
- `kubectl delete --force --grace-period=0`：apiserver 立即删除对象不等节点确认，节点上的容器可能还在跑——这是最后手段，不是日常操作。

```yaml
# [master] 保存为 term-demo.yaml: 亲手测出时序
apiVersion: v1
kind: Pod
metadata:
  name: term-demo
spec:
  terminationGracePeriodSeconds: 40
  containers:
  - name: app
    image: busybox:1.36
    command: ['sh', '-c', 'trap "echo got-TERM; exit 0" TERM; while true; do sleep 1; done']
    lifecycle:
      preStop:
        exec:
          command: ['sh', '-c', 'echo preStop-start; sleep 15; echo preStop-done']
```

```bash
# [master] 计时删除: preStop 15s + TERM 处理 ≈ 总耗时 16s 左右(远小于 40s 上限)
kubectl apply -f term-demo.yaml
kubectl wait --for=condition=Ready pod/term-demo --timeout=30s
time kubectl delete pod term-demo
# real ≈ 16s; 把 preStop 的 sleep 15 改成 sleep 50 再测一次 → real ≈ 42s
# (G=40 耗尽 + 2s 追加宽限后被强杀), 两次实验验证"preStop 受 G 约束"

# [master] 滚动更新掉流量的经典组合拳(理解即可)
# Service 摘流量与 preStop 之间没有先后保证, 用 preStop sleep 几秒
# 等 Endpoints 生效、连接排空, 再让应用退出:
#   lifecycle:
#     preStop:
#       exec: {command: ['sh', '-c', 'sleep 10']}
```

## 6. restartPolicy 与 CrashLoopBackOff

| 退出码 | restartPolicy: Always | OnFailure | Never | sidecar（自带 Always） |
| --- | --- | --- | --- | --- |
| 0（成功） | 重启 | 不重启 | 不重启 | **重启** |
| 非 0（失败） | 重启 | 重启 | 不重启 | 重启 |

约束：Deployment/ReplicaSet/StatefulSet/DaemonSet 只允许 `Always`；Job 要用 `OnFailure` 或 `Never`。

重启退避：崩溃后立即重启第一次，随后指数退避 10s → 20s → 40s……上限 300s；稳定运行 10 分钟后计数清零。`CrashLoopBackOff` 显示的就是"正在退避等待下一次重启"的状态。排障三连：`kubectl logs --previous`（看上一次崩溃输出）、`kubectl describe`（看探针/OOM 事件，`OOMKilled` 的 exit code 是 137）、`kubectl get events --sort-by=.lastTimestamp`。

## 实战演练

15 分钟串起本章全部结论（各步骤的 YAML/输出详见对应小节）：

```bash
# [master] 1) 共享命名空间验证（第 1 节 pod-anatomy.yaml）
kubectl apply -f pod-anatomy.yaml
kubectl wait --for=condition=Ready pod/pod-anatomy --timeout=60s
kubectl exec pod-anatomy -c writer -- wget -qO- http://localhost:80 | head -1
# 预期: 输出 "written at ..."，证明 localhost 互通 + 共享卷

# [master] 2) 三层状态读取（第 2 节）
kubectl run demo --image=nginx:1.27
kubectl wait --for=condition=Ready pod/demo --timeout=60s
kubectl get pod demo -o jsonpath='{.status.phase}{"\n"}'
# 预期: Running

# [master] 3) 探针失败行为对照（第 3 节 probe-demo.yaml）
kubectl apply -f probe-demo.yaml
kubectl expose pod probe-demo --port=80
sleep 40 && kubectl get pod probe-demo && kubectl get endpoints probe-demo
# 预期: READY 0/1 且 RESTARTS 缓涨（liveness 在重启）；Endpoints 为 <none>（readiness 在摘流量）

# [master] 4) 原生 sidecar 启动顺序（第 4 节 sidecar-demo.yaml）
kubectl apply -f sidecar-demo.yaml
kubectl get pods -l app=sidecar-demo
# 预期: 2/2 Running，log-shipper 常驻不退出

# [master] 5) 优雅退出计时（第 5 节 term-demo.yaml）
kubectl apply -f term-demo.yaml
kubectl wait --for=condition=Ready pod/term-demo --timeout=30s
time kubectl delete pod term-demo
# 预期: real ≈ 16s（preStop 15s + TERM 处理），远小于 G=40s

# [master] 6) 清理
kubectl delete pod pod-anatomy demo probe-demo --force --grace-period=0 --wait=false
kubectl delete deploy sidecar-demo --wait=false
kubectl delete svc probe-demo --wait=false
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 滚动更新瞬间 5xx | 新 Pod 未 Ready 就接流量，或旧 Pod 摘流量与退出之间没缓冲 | readinessProbe + preStop sleep + 合理 G |
| 容器收到 SIGTERM 却不退出 | `sh -c` 包裹不转发信号给业务进程 | exec 形式启动，或镜像里用 exec 语法 |
| RESTARTS 一直涨、STATUS=CrashLoopBackOff | 崩溃退避中：应用退出 / liveness 过严 / OOM | `logs --previous` + describe 分清三类 |
| init 容器失败，Pod 卡 Pending | `restartPolicy: Always` 时 init 会一直重跑 | `kubectl logs <pod> -c <init 名>` 看它卡在哪 |
| 同 Pod 两容器抢 80 端口 | 共享 network namespace，端口空间唯一 | 错开端口或合并到一个容器 |
| readiness 检查 DB 连通性导致全集群摘流量 | 混淆"我能服务"与"依赖健康" | readiness 只测自身，依赖故障靠 liveness/超时与熔断处理 |
| preStop sleep 30 但 G 还是默认 30 | preStop 与 TERM 共享 G，先被掐断 | `terminationGracePeriodSeconds` > preStop 时长 + 退出耗时 |

## 自测

1. 为什么业务容器崩溃重启后 Pod IP 不变？如果 pause 容器被手动杀掉（节点上 `crictl stop`）会发生什么？

<details><summary>答案</summary>

IP 由 pause 容器持有的 network namespace 决定，业务容器重启只是在新沙盒里加入同一 netns，IP 不变。pause 被杀则整个 sandbox 被摧毁，kubelet 视为基础设施级事件：重建 sandbox（新 IP 可能变化），Pod 内所有容器重启；若是静态 Pod 场景外的普通 Pod，其 status 会反映容器重建。这也是"排障别乱动 pause"的原因。
</details>

2. startupProbe 存在时，livenessProbe 的 initialDelaySeconds 从什么时刻起算？三个探针的启用顺序是什么？

<details><summary>答案</summary>

启用顺序：startup → （成功后）liveness 与 readiness 并行开始。startupProbe 存在时，其他探针在它成功前完全不执行，因此 initialDelaySeconds 实际上从 startup 成功后才开始计时。这就是"用 startupProbe 替代巨大 initialDelaySeconds"能自适应启动时间的原因。
</details>

3. 一个应用读 liveness 失败被重启 5 次、每次都一样。如果把这个探针改成 readiness，行为有什么变化？哪种更合理？

<details><summary>答案</summary>

改成 readiness 后：容器不再重启，只是 Pod 从 Endpoints 摘除、不接流量。对"进程活着但不能服务"（依赖故障、缓存冷启动）的场景，readiness 更合理：重启不会修复外部依赖，反而制造重启风暴与连接抖动；摘流量即可让其他副本承接。只有"进程内部死锁、重启可恢复"才值得 liveness。
</details>

4. 同样是 `initContainers`，一条 `restartPolicy: Always` 带来了哪些语义变化？为什么说它顺带修复了 Job + sidecar 的死锁？

<details><summary>答案</summary>

变化：从"跑完即退"变成"常驻"；不受 Pod 级 restartPolicy 影响（无论退出码都重启）；主容器等待它 startup 成功才启动；Pod 终止时它最后（逆序）退出；支持全部三种探针与 lifecycle。Job 的完成判定要求所有容器进入终态，老式 sidecar 永不退出导致 Job 永不 Complete；原生 sidecar 被 Job 控制器特殊处理——主容器结束后 sidecar 被终止，Job 得以收尾。
</details>

5. preStop 里 sleep 50，terminationGracePeriodSeconds 默认 30。按官方时序，容器进程分别在什么时刻收到 SIGTERM 与 SIGKILL？

<details><summary>答案</summary>

preStop 从 0s 跑到 30s 仍未结束（G 耗尽），kubelet 仅追加一次 2 秒宽限到 32s；此时 preStop 未完成，运行时对 PID 1 发 SIGTERM（约 32s 处），应用若不理会，剩余宽限耗尽后 SIGKILL。结论：G 是硬预算，preStop + 退出耗时必须装进 G，否则 hook 会被拦腰截断。
</details>

## 延伸阅读

- Pod 生命周期（官方，含终止时序与探针语义）：https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/
- 配置 liveness/readiness/startup 探针：https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/
- init 容器：https://kubernetes.io/docs/concepts/workloads/pods/init-containers/
- sidecar 容器（原生）：https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
- 容器生命周期钩子：https://kubernetes.io/docs/concepts/containers/container-lifecycle-hooks/
- Pod 与容器排障（官方手册）：https://kubernetes.io/docs/tasks/debug/debug-application/debug-pods/
