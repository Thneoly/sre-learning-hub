---
title_juejin: Flink Operator 的隐藏陷阱：容器名不是你以为的那个
title_zhihu: Flink Operator 的隐藏陷阱：容器名不是你以为的那个
description: Flink Operator的隐藏陷阱：容器名必须是flink-main-container。改错名变秒退sidecar导致0/2 CrashLoop，加上SA缺RBAC的exit 239双层根因。
category_id: "6809637769959178254"
tags: "Kubernetes,安全"
column_id: "7686472562230312970"
---

<!-- 封面与配图建议（HTML 注释，掘金渲染时不显示；发布前处理）：
封面二选一：
1. 实拍 kubectl get pods 里 0/2 CrashLoopBackOff、RESTARTS 暴涨的那一行，红框圈住 READY 与 RESTARTS 两列；
2. 把第五节「排障速查图」画成流程图，终端深底配色。
正文配图：第一节末尾的 describe 节选可直接截图，比文字转述更有现场压迫感。 -->

# Flink Operator 容器名是接口不是注释：一个名字放倒整个 Pod

YAML 我检查了三遍：镜像拉得动、events 干净、资源没超限，可 FlinkDeployment 拉起来的 Pod 就是稳稳挂在 0/2 CrashLoopBackOff。

describe 完更懵：有个容器的日志只剩一段 usage 帮助文本，退得比我看日志的手速还快；另一个容器的退出码，在 K8s 常见退出码对照表里压根查不到。

根因有两层，而且互相打掩护：修好一层，下一层才露头，按下葫芦浮起瓢。这篇把它们一层层扒出来——三步定位第一层，一条命令识破第二层，文末附可以直接抄的完整 YAML，还有一条 10 秒扫完整个集群的自检命令。

## 一、现场：一个"怎么看都没毛病"的部署

场景很典型：helm 装好 Flink Kubernetes Operator，apply 一个 FlinkDeployment，Application 模式跑镜像自带的 SocketWindowWordCount，词频统计。

需求很朴素：checkpoint 每 10 秒一次，状态落在宿主机 `/var/flink-state`，Pod 重建不丢。

补一句链路背景：operator 盯着 FlinkDeployment 这个 CR，你 apply 之后，它负责生成 JM 的 Deployment 和两个 Service（TM Pod 不由它直接创建，而是 JobManager 运行时按需拉起），再把 flinkConfiguration 注进去。听起来全自动，实际上每一层都留了"要你自己接线"的口子。

写过 Deployment 的肌肉记忆直接上：挂卷，volumes 加 volumeMounts；容器名顺手起个语义化的 `flink-job-manager`。就是这两下"手感"，埋了一颗雷——雷不在挂卷（直觉写法里挂载位置恰恰写对了），在容器名。直觉写法（节选）：

```yaml
apiVersion: flink.apache.org/v1beta1
kind: FlinkDeployment
metadata:
  name: wordcount
  namespace: flink-lab
spec:
  image: flink:1.19
  flinkVersion: v1_19
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
          - name: flink-job-manager    # 雷就在这一行
            image: flink:1.19
            volumeMounts:
              - name: flink-state
                mountPath: /opt/flink/state
```

看着没毛病对吧？在 K8s 里容器名不就是个标签么，起成 `nginx`、`app`、`main` 都一样跑。Deployment 的世界里这是常识；但在 operator 的世界里，**容器名是接口，不是注释**——operator 按这个名字"调用"你写的配置，名字对不上，你的挂载、镜像、env 就永远没人认领。

apply 完不到一分钟，现场是这样的（describe 节选）：

```text
$ kubectl -n flink-lab describe pod wordcount-7d9c8f6b5-x2k4j
Containers:
  flink-job-manager:
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Exit Code:    0
  flink-main-container:
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Exit Code:    239
Events:
  Back-off restarting failed container
```

两个问号当场砸在脸上：`flink-main-container` 是谁？我没写过这个名字。`Exit Code: 239` 又是什么码？——先按住，从最浅的雷拆起。

## 二、明雷：apply 就被拒的 strict decoding

先说个明雷。挂载写成 `spec.volumes` 或 `spec.jobManager.volumeMounts`，apply 直接被 API Server 拒绝：

```text
strict decoding error: unknown field "spec.volumes"
```

原因很硬：FlinkDeployment 的 CRD 里没有这些顶层字段，`jobManager`/`taskManager` 底下只有 `podTemplate`、`replicas`、`resource` 这几样。

挂载必须写进 `spec.jobManager.podTemplate` 或 `spec.taskManager.podTemplate`。这颗雷 apply 就炸，坑不到人，真正坑人的在下一层。

顺带一提：报错里的 strict decoding 是 API Server 的严格解码在起作用，专门拦"CRD 里不存在的字段"。它凶归凶，却是这组坑里唯一一个把话说清楚的。

## 三、第一层：容器名是"合并锚点"，不是给你起语义的

挂载挪进 podTemplate，apply 成功，Pod 也出来了——然后撞上开头那一幕：CrashLoopBackOff。

先解释 READY 列在说什么：斜杠后面的数字是这个 Pod 里容器的总数，前面的是 READY 数。看到 CrashLoop，第一反应不该是"服务挂了"，而该是先数容器——你只想要一个 JM，哪来的两个容器？

### 机制：operator 按名字找配置

JM Pod 由 operator 生成、TM Pod 由 JobManager 运行时按需创建，但两边同一套逻辑：默认自带一个主容器，再**按容器名**在 podTemplate 里找同名容器，把你写的镜像、挂载、env 合并进那个主容器。

约定的名字叫 `flink-main-container`。它不是命名风格，是接口约定，operator 就认这一个名字（官方文档把这套机制叫 Pod Template 覆盖，见 [Pod Template](https://nightlies.apache.org/flink/flink-kubernetes-operator-docs-main/docs/custom-resource/pod-template/)）。

你写 `flink-job-manager`，operator 找不到锚点，不报错也不认领，把它当成普通额外容器——sidecar——原样保留进 Pod。

坏在：这个 sidecar 没有 command，flink 官方镜像的入口脚本发现没参数，打印一段 usage 就退出。

于是 Pod 里同时挂着"operator 生成的真主容器 + 一个秒退的假容器"。这里要校正一个我当时的想当然：我把 0/2 全记在这颗雷头上，其实单是容器名错这一层，Pod 显示的是 **1/2**——默认模板里没有 readiness 探针，主容器自己的 REST 起来之后就算 Ready，永远凑不齐 READY 的只是那个秒退的假容器。我当时看到的是 0/2，说明主容器自己也没起来——第二层坑当时已经在场，只是被满屏 Back-off 掩护得严严实实（第五节展开）。

| podTemplate 里写的 | operator 的理解 | 实际结果 |
| --- | --- | --- |
| name: flink-main-container | 主容器配置，合并镜像/挂载/env | 挂载生效，一切正常 |
| name: flink-job-manager | 一个额外的 sidecar 容器 | 没 command，秒退；主容器自身正常时是 1/2 CrashLoop |

### 为什么 operator 要这样设计

podTemplate 本意是一个口子干两件事：

- 改主容器：镜像、挂载、env，全部合并进默认生成的主容器，锚点就是 `flink-main-container`；
- 加 sidecar：日志采集、监控 agent 这类伴生容器，名字随便起，operator 原样保留。

问题就在这：operator 没法区分"你想加 sidecar"和"你把主容器名写错了"。对陌生容器名它只能选择保留——毕竟把人家的日志采集器砍了，责任更大。

这份"宽容"对老手是功能，对新手就是坑：CRD 校验拦不住，运行时也不报错，唯一表现就是 Pod 起不来。

这类 CrashLoop 的指纹其实很明显：重启次数疯狂上涨、日志极短只剩 usage、**退出码 0**。对，秒退容器的退出码是 0 不是 1——它没崩，是压根没被赋予使命，打完 usage 就"功成身退"；但 `restartPolicy: Always` 不接受这种退场，退出码 0 照样进 CrashLoopBackOff。看到"重启暴涨 + 日志只有 usage + 退出码 0"这个组合，基本可以直奔容器名去。

### 三步定位

第一步，看这个 Pod 里到底有几个容器、都叫啥：

```bash
kubectl -n flink-lab get pods \
  -o custom-columns='NAME:.metadata.name,CONTAINERS:.spec.containers[*].name'
```

wordcount 的 Pod 会列出两个容器名：正常应该只有 operator 生成的那个主容器，这时却多出一个你亲手写进去的名字，真相大白一半。第二步，单独看那个多余容器的日志：

```bash
JM_POD=$(kubectl -n flink-lab get pods -o name \
  | grep wordcount | grep -v taskmanager | head -1)
kubectl -n flink-lab logs ${JM_POD} -c flink-job-manager --previous
```

输出基本是一段 usage 文本，describe 里对应 Exit Code 0。第三步，改名：

```text
- name: flink-job-manager
+ name: flink-main-container
```

提醒一句：JobManager 和 TaskManager 两个 podTemplate 是同一套约定，两边都得改。只改 JM 那边，TM 会用一模一样的方式再坑你一次。

## 四、第二层：Exit Code 239，Flink 的致命退出码

名字改完，sidecar 消失，Pod 里只剩主容器一个，总算能 Running 了吧？不，它换了个死法：0/1 CrashLoop，重启次数继续涨，退避间隔越拉越长，Events 里全是 Back-off。唯一的"好转"是噪音没了——主容器自己的死因，终于看得清了。

describe 里是这副面孔：

```text
Last State:  Terminated
  Exit Code: 239
```

239 在 K8s 的常见退出码对照表里查不到，但它不是无名氏：这是 **Flink 自己的 FatalExitExceptionHandler 留下的固定退出码**，含义是"执行线程发生了未捕获的致命异常"。OOM、HA 初始化失败、本篇的 403——任何致命错误最后都以 239 收场。换句话说，239 不指向具体病因，它只宣布"进程死于非命"，死因得回日志里找。你第一次撞到 239 时，日志里的致命异常是哪一个？评论区可以对个暗号。

所以别查表了，看主容器日志：

```bash
JM_POD=$(kubectl -n flink-lab get pods -o name \
  | grep wordcount | grep -v taskmanager | head -1)
kubectl -n flink-lab logs ${JM_POD} --tail=50 | grep -i forbidden
```

关键一行：

```text
Received 403 on websocket ... Forbidden
```

注意这行的主语是 websocket：JM 通过长连接 watch Pod 变化，API Server 在握手阶段就把权限校验做了。所以故障发生在 JM 启动早期，作业连提交都还没轮到。

### 这个 403 是哪来的

链路拆开看：

1. 不写 `spec.serviceAccount` 时，作业不是没有 SA，而是用命名空间里名为 `default` 的 SA 跑（Flink 的 `kubernetes.jobmanager.service-account` 默认值就是 default）——它同样什么权限都没有；想用自建 SA，必须在 CR 里显式写 `serviceAccount: flink`；
2. helm 装 operator 时，给 operator 自己建的是**集群级**的 ClusterRole `flink-operator` 加 ClusterRoleBinding，默认全命名空间生效——operator 自己的权限并不缺；
3. 真正裸的是**跑作业的那个 SA**：default 也好、自建的 flink 也好，在作业 namespace 里从头到尾没有任何绑定。

JobManager 的 KubernetesResourceManager 要 watch TaskManager Pod，API Server 回 403，JM 进程随即以 239 退场——呈现出来就是反复重启。

修之前，可以先用一条命令确认权限确实缺失（impersonation 只读，不动集群）：

```bash
kubectl -n flink-lab auth can-i list pods \
  --as=system:serviceaccount:flink-lab:flink
```

注意这里验证的是 `flink`——修复之后将使用的那个 SA；最初那份没写 serviceAccount 的 YAML，实际在用的是 `flink-lab:default`，把它换进 `--as` 里跑一遍，会看到同一个 `no`。修法：在作业 namespace 自建 SA 加 RoleBinding。

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: flink
  namespace: flink-lab
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: flink-role-binding
  namespace: flink-lab
subjects:
- kind: ServiceAccount
  name: flink
  namespace: flink-lab
roleRef:
  kind: ClusterRole
  name: flink-operator
  apiGroup: rbac.authorization.k8s.io
```

两个细节：

- RoleBinding 引用的 ClusterRole `flink-operator` 就是 helm 装 operator 时建好的那个集群级角色，直接复用；
- RoleBinding 引 ClusterRole，权限仍只作用于本 namespace——JM 要在作业 namespace 里 watch/create/delete Pod（开 HA 还要操作 ConfigMap），没必要给全局权限。

建完再跑一遍上面的 `auth can-i`，输出变成 `yes`。但还差半步：如果 CR 里没写 `serviceAccount: flink`，作业仍然在用 default SA 跑，403 不会消失——把 CR 补上这一行，operator 检测到 spec 变化会自动滚动重建，新 Pod 才真正用上这份权限。第六节的完整版 YAML 已经写好了这行。

### 为什么 helm 不顺手把作业的 RBAC 建好

因为 helm 不知道你的作业会跑在哪个 namespace、用哪个 SA。operator 自己的权限是集群级的 ClusterRole + ClusterRoleBinding，watch 全命名空间；作业 SA 的绑定属于业务方的地盘，chart 不会替你越界。这个设计合理，坑就坑在报错方式：不是 apply 时拒绝，而是运行时一个 403 加一个 K8s 字典里查不到的退出码。想知道这个 ClusterRole 里到底有什么，一条命令：

```bash
kubectl get clusterrole flink-operator -o yaml
```

## 五、这两层坑为什么互相掩护

回头看，这组故障最阴的地方是**信号淹没**。

sidecar 秒退时，describe Pod 满屏都是它的 Back-off 和 restarting 记录，你很难想到逐容器看日志。JM 主容器那行 403，就埋在噪音底下。

当时我看到的 describe 大概长这样（节选）：

```text
flink-job-manager:
  State: Waiting
    Reason: CrashLoopBackOff
  Last State: Terminated
    Exit Code: 0
Events:
  Back-off restarting failed container
```

满屏 Back-off 全指向这个秒退容器，注意力也全被它吸走——这正是第二层坑最喜欢的掩护环境。

修掉容器名，掩护才撤掉：Pod 从 0/2 变成 0/1，第二层露头。不少人到这步会怀疑"是不是改错了"，又把名字改回去，一晚上就这么交代了。

更普适的规律是：这几个坑在时间线上层层后置，每个坑只在自己的阶段露面——

- apply 阶段：strict decoding 拦下顶层挂载；
- Pod 创建后：容器名错，多出的容器秒退；
- JM 启动后：403 撞上，239 退场；
- 第一次写 checkpoint：hostPath 属主爆雷。

修一个冒一个，按下葫芦浮起瓢。心里有这张地图，就不容易被带偏。

第三层（hostPath）的现场顺手补齐，免得你第一次听说它是在汇总表里：前两层修完、作业 RUNNING 之后，TaskManager 日志里突然冒出 `Permission denied: '/opt/flink/state/checkpoints/...'`——宿主机目录是 root 的，镜像里进程以 uid 9999 跑。修法一条命令：`sudo chown -R 9999:9999 /var/flink-state`（第六节开头已备好）。这个坑的完整排查值得单独写一篇，这里只交代到能对号入座。

排障顺序建议：

1. 先 `get pods -o custom-columns` 核对容器数量和名字，对不上先怀疑模板；
2. 再逐容器 `logs -c`，一个一个看，别只盯 events；
3. 撞到 239 别翻 K8s 退出码表，回 Flink 日志找那个致命异常：403 查 RBAC，404 查对象存在性；
4. 三者都正常但状态不落盘，查 hostPath 属主和 uid。

整个排障路径浓缩成一张速查图，下次直接对号入座：

```text
apply 阶段就被拒？
└─ unknown field "spec.volumes" → 挂载挪进 podTemplate

Pod CrashLoop？
├─ 先数容器（get pods -o custom-columns）
│   ├─ 多出一个陌生名字的容器
│   │   ├─ 1/2：主容器 Ready → 只有容器名这一层，改名 flink-main-container
│   │   └─ 0/2：主容器也没 Ready → 两层并存，逐容器看日志
│   └─ 容器数正常 → 直接看主容器日志
│       └─ 日志里有 403 Forbidden → 建 SA + RoleBinding
│                                  → 并在 CR 显式写 serviceAccount: flink

全部 Running，写 checkpoint 报 Permission denied？
└─ hostPath 属主是 root → chown -R 9999:9999
```

一张表收走这组坑：

| 症状 | 根因 | 一句话修法 |
| --- | --- | --- |
| apply 被拒：unknown field "spec.volumes" | CRD 没有顶层挂载字段 | 挂载写进 podTemplate |
| 多出一个陌生容器名，其日志只剩 usage、Exit Code 0、重启暴涨；主容器 Ready 时是 1/2 | 容器名不是 flink-main-container，被当 sidecar 秒退 | 改名，JM/TM 都改 |
| 0/2 CrashLoop：两个容器都没 Ready，主容器日志 403 | 容器名 + RBAC 两层并存 | 改名，再补 RBAC，CR 显式写 serviceAccount: flink |
| 全部 Running 后写 checkpoint 报 Permission denied | hostPath 属主是 root，镜像内 uid 是 9999 | chown -R 9999:9999 |

## 六、修复后的完整版，可以直接抄

先给导读：修复清单总共三样——宿主机状态目录、作业 RBAC、一份改对的 CR。主角先行，配套的词源服务放到文末附录 A，不打算复现 socket 作业的读者可以直接跳过附录。

宿主机备好状态目录（hostPath 只适合单节点集群，多节点换 PVC 加 StorageClass）。这里的 chown 9999 就是在给第三层坑打预防针：

```bash
sudo mkdir -p /var/flink-state/{checkpoints,savepoints,ha}
sudo chown -R 9999:9999 /var/flink-state
kubectl create namespace flink-lab
```

RBAC 用第四节那份清单，apply 进 flink-lab。然后是主角，修正版 FlinkDeployment：

```yaml
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
    # 这个示例 jar 只认 --hostname/--port；窗口是代码里写死的 5 秒滚动
    args: ["--hostname", "wordsrv", "--port", "9000"]
    parallelism: 2
    upgradeMode: savepoint
```

args 里只传 hostname 和 port，是有意的：这个示例 jar 就只认这两个参数，窗口硬编码为 5 秒滚动，传 `--window`/`--slide` 会被静默忽略，别被网上的老示例带偏。

对照直觉版，差异就三处：挂载进 podTemplate；容器名改 `flink-main-container`（两边都是）；显式写 `serviceAccount: flink`——第三处正是第四节说的那半步，不写的话作业用的还是 default SA。

flinkConfiguration 也值得扫一眼，每个键都对应一个运维诉求：

| 配置 | 作用 |
| --- | --- |
| execution.checkpointing.interval: 10s | 每 10 秒做一次 checkpoint |
| state.checkpoints.dir / state.savepoints.dir | 状态目录，指向挂载点 |
| externalized-checkpoint-retention | 作业取消后 checkpoint 保留 |
| restart-strategy: fixed-delay | 失败固定延迟重启，最多 10 次 |
| taskmanager.numberOfTaskSlots | 每 TM 的槽数 |

还有个容易忽略的点：两个 podTemplate 长得几乎一模一样，复制粘贴时注意别只改了一边——漏改的那边会原样再崩一次，日志都懒得换。

apply 时先上词源（文末附录 A）再上主角；socket source 连不上会自己走重启策略重连，先后顺序其实不敏感：

```bash
kubectl -n flink-lab apply -f wordsrv.yaml
kubectl -n flink-lab apply -f flinkdeployment-wordcount.yaml
kubectl -n flink-lab get flinkdeployment wordcount -w
```

等到这行输出就成了：

```text
NAME        JOB STATUS   LIFECYCLE STATE
wordcount   RUNNING      STABLE
```

## 七、验收：确认整条链路真的通了

先看 Pod：

```bash
kubectl -n flink-lab get pods
```

预期 JM、TM 加两个词源 Pod 全部 Running，而且每个 Flink Pod 里只有 `flink-main-container` 一个容器——可以再用第三节那条 custom-columns 命令扫一眼。

再从 REST 侧确认。解释下 `wordcount-rest`：operator 会给每个 FlinkDeployment 建两个 Service，一个管集群内部通信，一个专门暴露 REST 和 Web UI，名字固定是 `<CR 名>-rest`：

```bash
kubectl -n flink-lab port-forward svc/wordcount-rest 8081:8081 &
curl -s http://localhost:8081/jobs/overview | grep -o '"state":"[A-Z]*"'
```

预期输出 `"state":"RUNNING"`。最后看 checkpoint 是否真落盘：

```bash
JOB_ID=$(curl -s http://localhost:8081/jobs/overview \
  | grep -o '"jid":"[0-9a-f]*"' | head -1 | cut -d'"' -f4)
curl -s http://localhost:8081/jobs/$JOB_ID/checkpoints | grep -o '"counts":{[^}]*}'
```

预期 completed 在涨、failed 为 0（total 是累计总数，in_progress 是当下正在做的那个）：

```text
"counts":{"restored":0,"total":7,"in_progress":0,"completed":7,"failed":0}
```

宿主机侧也能互相印证，目录里按作业 ID 分层，`chk-N` 每 10 秒多一个：

```bash
sudo ls -R /var/flink-state/checkpoints | head -20
```

窗口的计算结果会打进 TaskManager 日志，每 5 秒集中一批。数能对上账：词源每 0.2 秒吐 3 行，5 秒窗口 ≈ 75 行，hello/flink 各占约 25。注意：这个示例 jar 的 print sink 并行度是 1，两个 TM 只有一个有输出——下面这条命令抓的 TM 要是一条都看不到，换另一个 TM 再抓：

```bash
kubectl -n flink-lab logs $(kubectl -n flink-lab get pods -o name \
  | grep taskmanager | head -1) --tail=8
```

```text
(hello,25)
(flink,25)
(word3,2)
```

到这里，最初那个 0/2 的 Pod 已经面目全非：单容器、Running、REST 可查、状态落盘。回头看，排障的每一步其实都在回答同一个问题——"operator 到底认不认你写的东西"。

completed 在涨、宿主机目录在长、窗口结果在出——说明容器名、RBAC、hostPath 权限整条链路全通了。

## 八、几个追问

**TM 侧也叫这个名？** 叫。JM/TM 两个 podTemplate 同一套约定，按容器名合并的逻辑对两边一样生效。

**那想挂真正的 sidecar 呢？** 在 podTemplate 的 containers 里再加一项，名字随意——operator 原样保留，这正是这套设计本来的用途。只是你的挂载、镜像定制要落在 `flink-main-container` 上，别落错地方。

**TM 不挂载行不行？** 不行。checkpoint 和 savepoint 都由 TaskManager 写盘，TM 必挂。实验里 JM 也挂了，HA 目录在同一个 hostPath 下。

**podTemplate 里写了 image，spec.image 也写了？** 不一致时，podTemplate 里写的会覆盖 `spec.image`——所以最好保持一致，别给自己留一个"到底哪个生效"的悬念。

**改完 RBAC 要重启什么吗？** 权限在 API Server 侧即时生效，不用重启任何东西——前提是 CR 里已经写了 `serviceAccount: flink`，这样正在 CrashLoop 的 JM 下一次重启就带着新权限；CR 里还没写的，先补这行，operator 会滚动重建。嫌退避等得久，可以删掉 JM Pod，让 operator 立刻拉新的。

**Session 集群也这么玩？** Session 集群就是不写 `spec.job` 的 FlinkDeployment，往它上面提交作业用的是另一个 CR：FlinkSessionJob。podTemplate 同一套约定，容器名照样得是 `flink-main-container`。

最后说句心法：StatefulSet、Job 这些内置资源里，容器名真的只是个名字；但 operator 类 CRD 里，它可能是接口。遇到新的 operator，先翻文档里 pod template 那一节，找到"锚点容器名"再动手，比事后排障便宜得多。

## 九、带走这份 checklist

如果只能记一句话：**Flink Operator 的 podTemplate 里，容器名是接口，不是注释**。剩下的条目都是这句话的推论。

- podTemplate 容器名必须是 `flink-main-container`，JM/TM 同一约定；
- 作业 namespace 自建 `flink` SA 加 RoleBinding，绑集群级 ClusterRole `flink-operator`，并在 CR 显式写 `serviceAccount: flink`——不写的话作业用 default SA 跑，一样没权限；
- 挂载只能走 podTemplate，顶层 volumes 会被 strict decoding 拒掉；
- hostPath 提前 chown 9999:9999；
- 秒退容器先查名字（退出码 0 也照样进 CrashLoop 的那种）；Exit Code 239 先回 Flink 日志找致命异常，403 查作业 SA 的 RBAC；
- 字段名随版本会变（比如手动触发的 savepoint 已改由 FlinkStateSnapshot 这套 CR 记录，旧博客里的 `.status.jobStatus.savepointPath` 已经查不到），以官方文档为准。

## 十、先花 10 秒自查你的集群

如果你环境里已有 FlinkDeployment，别等事故，现在就审计一遍容器名（整行复制，反斜杠是续行符）：

```bash
kubectl get flinkdeployments -A \
  -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,JM_CONTAINERS:.spec.jobManager.podTemplate.spec.containers[*].name'
```

没写 podTemplate 的部署 JM_CONTAINERS 列为空，正常；输出里出现 `flink-main-container` 之外的名字，就说明集群里躺着一个秒退 sidecar——它此刻可能正被别的症状掩护着。顺手再看眼 RBAC：

```bash
kubectl get sa,rolebinding -A | grep flink
```

作业 namespace 里查不到绑定，第二层坑就在排队。

## 十一、写在最后

这套实验出自我整理的 SRE 学习仓库 [sre-learning-hub](https://github.com/Thneoly/sre-learning-hub)，从 operator 安装、反压定位到 savepoint 升级恢复，每个坑都配了可复现的实验环境和验收命令，跑一遍就能确认自己真的会了，感兴趣可以翻翻。

觉得有用就点个收藏，顺手留个言：你在 Flink on K8s 上被哪个退出码坑得最久？评论区对暗号——下次再遇到 0/2，至少能少走一晚弯路。

## 环境说明

本文基于 Flink Kubernetes Operator 1.13.0、flink:1.19 镜像、kubeadm 单节点集群验证。截至发表，operator 已迭代到 1.16.x，字段与细节可能有出入，但这两个坑的机制是通用的。

## 附录 A：词源服务 wordsrv

socket source 得有东西喂数据。词源就是一个普通的 Deployment + Service：busybox 每 0.2 秒吐一轮三行——hello / flink / wordN，两个副本：

```yaml
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
          command: ["sh", "-c"]
          args:
            - |
              while true; do
                while :; do echo hello; echo flink; echo "word$((RANDOM % 10))"; sleep 0.2; done | nc -l -p 9000
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
```

仓库版词源还带一个 FLOOD 压测开关（切成 `yes hello` 刷屏，用来制造热点 key 观察反压），本文用不上，这里略去。
