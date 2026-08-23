# 14 · 可观测性：metrics-server、三层日志、Events 与 audit

> 模块：04-k8s-fundamentals ｜ 建议时长：2.5 小时 ｜ 关联认证：CKA-故障排查 / PCA-指标与监控 / CKS-audit

## 学习目标

- 能解释 kubectl top 的完整数据链路（metrics-server → kubelet → cAdvisor → 聚合 API），并独立部署与排障 metrics-server
- 能说出容器日志的三层落地（stdout → 节点文件 → 代理采集）并直接在节点上找到某个 Pod 的日志文件
- 能区分 Events 与 audit log 记录的是"两本不同的账"，并开启最小的 audit 策略
- 能按"现象 → 第一入口命令 → 深挖命令"的矩阵选择正确的排障路径
- 能说出 metrics-server 的局限，解释为什么生产监控要换成 Prometheus（衔接 PCA 模块）

## 1. metrics-server 与资源指标 API

`kubectl top` 的数据不来自 apiserver 本身，而来自一条独立的采集链：

```
# [图] kubectl top 的数据链路
 kubectl top pod / node
   └─► kube-apiserver  /apis/metrics.k8s.io/v1beta1/...      ← 聚合 API(APIService)
         └─► 路由到 metrics-server(kube-system 里的普通 Deployment)
               └─► metrics-server 周期抓取(默认约 15s)各节点 kubelet :10250
                     └─► kubelet 汇总内嵌 cAdvisor 的容器/节点指标
                           (端点 /metrics/resource, 兼容 /stats/summary)
 注意: metrics-server 只有内存态瞬时值, 没有历史 —— 它不是 Prometheus
```

三个关键认知：

- `metrics.k8s.io` 是**聚合 API**：apiserver 收到该组的请求后转发给 metrics-server。metrics-server 挂了，`kubectl top` 报 `error: Metrics API not available`，但集群其他功能完全正常；
- **kubeadm 默认不装 metrics-server**，需要自己部署；
- 它的消费方是 HPA（resource metrics 型自动扩缩）和 kubectl top / dashboard 这类"看当前值"的场景。想知道"昨天下午 CPU 多少"它做不到——那是 Prometheus 的活（第 5 节）。

```bash
# [master] 1. 部署(固定版本便于复现, 最新 tag 见 releases 页)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# [master] 2. 练习集群的 kubelet 用自签服务端证书, metrics-server 校验会失败,
#           给它追加 --kubelet-insecure-tls(仅实验环境, 生产应配 CA 校验)
kubectl -n kube-system patch deployment metrics-server --type='json' \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s
# 预期: deployment "metrics-server" successfully rolled out

# [master] 3. 验证链路每一环
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/kube-system/pods | head -c 200; echo
kubectl top nodes
kubectl top pods -A --sort-by=memory | head -5
# 预期: 每节点一行 CPU(m)/MEMORY(Mi); pods 按内存降序
```

metrics-server 本身的排障顺序：Pod 是否 Running → `kubectl -n kube-system logs deployment/metrics-server`（TLS / kubelet 连不通报错都在这）→ `kubectl get apiservice v1beta1.metrics.k8s.io`（Available 是否 True）。

## 2. 日志三层：stdout → 节点文件 → 代理

K8s 的约定是**应用只写 stdout/stderr**，剩下的旅程由平台接管：

```
# [图] 一行日志的旅程
 ① 应用层: 进程写 stdout/stderr(12-factor 约定, 不写本地文件)
        │  containerd shim 接管容器标准流
        ▼
 ② 节点层: /var/log/pods/<ns>_<pod>_<uid>/<container>/0.log   ← 真身(JSON 行格式)
           /var/log/containers/<pod>_<ns>_<container>-<id>.log ← 软链, 给日志代理用
           kubelet 负责轮转: containerLogMaxSize 默认 10Mi × containerLogMaxFiles 默认 5
        │
        ▼
 ③ 代理层: DaemonSet(Fluent Bit/Fluentd/Promtail) tail 节点文件
           → 中心存储(Loki/ELK/Kafka) → 检索/告警/留存

 kubectl logs 的路径: apiserver → 该 Pod 所在节点 kubelet:10250 → 读 ② 的文件
```

| 层 | 内容 | 典型工具 | 留存 |
| --- | --- | --- | --- |
| ① 应用 | 业务日志、结构化输出 | 你自己的代码 | 无 |
| ② 节点 | 容器日志文件、kubelet/containerd 的 journal | `kubectl logs`、ssh + tail | 单机轮转（默认 10Mi×5 个文件），节点没了日志也没了 |
| ③ 中心 | 全集群聚合、检索、告警 | Fluent Bit + Loki / ELK / Promtail + Grafana | 按中心存储策略，可数月 |

排障时 ②③ 都通：实时看单容器用 `kubectl logs`；要 grep 全量历史或审计留存就得有 ③。采集架构有两种——**DaemonSet 每节点一个**（标准做法，读 /var/log/containers 软链）或 **sidecar 每 Pod 一个**（只读单 Pod，开销大，仅特殊需求用）。

```bash
# [master] kubectl logs 家族(先取一个具体 Pod 名, 后面复用)
POD=$(kubectl -n kube-system get pod -l component=kube-scheduler \
  -o jsonpath='{.items[0].metadata.name}')
kubectl logs -n kube-system -l component=kube-scheduler --tail=20   # 按标签聚合
kubectl logs -n kube-system "$POD" --tail=50
kubectl logs -n kube-system "$POD" --previous                       # 上一次崩溃的容器(CrashLoop 必看)
kubectl logs -n kube-system "$POD" -f --since=10m                   # 追最近 10 分钟
kubectl logs observable -c logger --tail=50                         # 多容器 Pod 用 -c 指定容器(见实战演练)

# [任意节点] 绕过 kubectl, 直接看节点上的文件(apiserver 不可用时的救命通道)
sudo ls /var/log/pods/ | head -5                        # 目录名格式: ns_pod-name_uid
sudo ls -l /var/log/containers/ | head -3               # 软链指向 /var/log/pods/...
sudo tail -n 3 "$(sudo find /var/log/pods -name '0.log' | head -1)"

# [任意节点] 系统组件日志(它们不在 /var/log/pods, 在 journald)
sudo journalctl -u kubelet -n 20 --no-pager
sudo journalctl -u containerd -n 20 --no-pager
```

## 3. Events 与 audit：两本不同的账

两者都常被翻译成"事件"，但完全不是一回事：

| 维度 | Events | Audit |
| --- | --- | --- |
| 记什么 | **对象发生了什么**：调度失败、拉镜像失败、探针失败、FailedMount | **谁对 API 做了什么**：哪个用户/SA 在何时对哪个资源执行了什么请求 |
| 谁写 | scheduler / kubelet / 各控制器主动发到 apiserver | apiserver 在请求处理链上自动记录 |
| 视角 | 运维排障："这个 Pod 为什么不行" | 安全审计："谁删了 Namespace、谁改了 RBAC" |
| 存储 | etcd 里的普通对象（有 namespace） | 文件 / webhook 后端，由策略决定 |
| 留存 | 默认 1 小时（apiserver `--event-ttl=1h`） | 按后端与外部策略，可长期 |
| 查询 | `kubectl get events` / `describe` 里的 Events 段 | grep audit.log 或投递到 SIEM |
| 默认状态 | 开 | **关**（需显式配置） |

```bash
# [master] Events 三板斧
kubectl get events -n default --sort-by=.lastTimestamp | tail -8
kubectl get events -A --field-selector type=Warning | tail -8
kubectl -n kube-system describe pod -l component=kube-scheduler | tail -15
# 预期: 末尾 Events 段按时间线给出该 Pod 的因果链
```

audit 的开启方式：给 kube-apiserver 静态 Pod 加参数与挂载（静态 Pod 机制见第 13 章第 3 节），策略文件先落地：

```bash
# [master] 1. 写一个最小策略: RBAC 变更记全量, 删除类记元数据, 其余记元数据
sudo tee /etc/kubernetes/audit-policy.yaml >/dev/null <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
omitStages:
- RequestReceived
rules:
- level: RequestResponse
  resources:
  - group: "rbac.authorization.k8s.io"
    resources: ["roles", "rolebindings", "clusterroles", "clusterrolebindings"]
- level: Metadata
  verbs: ["delete", "deletecollection"]
- level: Metadata
EOF
sudo mkdir -p /var/log/audit
```

```yaml
# [master] 2. 编辑 /etc/kubernetes/manifests/kube-apiserver.yaml, 追加三行参数
#    (command 列表内, 缩进对齐既有条目; 保存后静态 Pod 自动重启)
    - --audit-policy-file=/etc/kubernetes/audit-policy.yaml
    - --audit-log-path=/var/log/audit/audit.log
    - --audit-log-maxage=7
```

```yaml
# [master] 3. 同一文件的 volumeMounts 与 volumes 各追加两段(hostPath 打通宿主机)
    volumeMounts:
    - mountPath: /etc/kubernetes/audit-policy.yaml
      name: audit-policy
      readOnly: true
    - mountPath: /var/log/audit
      name: audit-log
  volumes:
  - hostPath:
      path: /etc/kubernetes/audit-policy.yaml
      type: File
    name: audit-policy
  - hostPath:
      path: /var/log/audit
      type: DirectoryOrCreate
    name: audit-log
```

```bash
# [master] 4. 验证: 随便做一次操作, 再看审计记录
kubectl -n kube-system get secrets >/dev/null
sleep 3 && sudo tail -n 1 /var/log/audit/audit.log | python3 -m json.tool | head -20
# 预期: 一条 JSON, 含 level/auditID/stage/user(kubernetes-admin)/verb/list/resource/secrets
```

记录级别四档由细到粗：`None`（不记）、`Metadata`（只记谁做了什么，不含请求体）、`Request`（含请求体）、`RequestResponse`（含响应体）。策略要点：默认放行一条兜底规则，对高频低价值流量（kube-proxy 的 endpoints 更新等）用 `None` 降噪。完整演练在 `07-cks/labs/06-audit-policy/`。

## 4. kubectl 排障命令矩阵

排障的第一难点是"什么现象用什么命令"。按 Pod 生命周期 + 集群分层组织：

| 现象 | 第一入口 | 深挖命令 |
| --- | --- | --- |
| Pod 一直 `Pending` | `kubectl describe pod`（看 Events） | Events 里 `FailedScheduling` 自带原因；`kubectl describe node` 看资源与污点 |
| `ImagePullBackOff` | `kubectl describe pod` | Events 有镜像名/认证报错；上节点 `sudo crictl pull <image>` 复现 |
| `CrashLoopBackOff` | `kubectl logs <pod> --previous` | 退出码（137=OOM/SIGKILL）、describe 看探针与 restartCount |
| 状态 `Running` 但没流量 | `kubectl get endpoints <svc>` | endpoints 空 → selector 与 Pod label 对不上或 readiness 没过 |
| Service 域名解析失败 | `kubectl run dnstest --rm -it --restart=Never --image=busybox:1.36 -- nslookup <svc>.<ns>.svc.cluster.local` | CoreDNS Pod 日志、`kubectl -n kube-system get cm coredns -o yaml` |
| 节点 `NotReady` | `kubectl describe node` | 看 Conditions；节点上 `sudo journalctl -u kubelet -n 50`、`sudo crictl ps` |
| `403 Forbidden` | `kubectl auth can-i <verb> <res> -n <ns> --as=<身份>` | 第 12 章五要素拆解 |
| kubectl 连不上 apiserver | `curl -k https://127.0.0.1:6443/healthz`（master 上） | `sudo crictl ps | grep apiserver`、证书有效期（第 13 章） |
| 疑似资源耗尽 / OOM | `kubectl top pods -A --sort-by=memory` | `kubectl get pod <p> -o jsonpath='{.status.containerStatuses[0].lastState}'` |
| HPA 不动作 | `kubectl describe hpa` | 看 Conditions 的 Metrics 报错 → `kubectl -n kube-system logs deployment/metrics-server` |
| 全集群没有指标 | `kubectl top nodes` | `kubectl get apiservice v1beta1.metrics.k8s.io`、metrics-server Pod |
| 想知道"谁刚删了对象" | Events 最多给出结果 | audit log（第 3 节，Events 一般不含操作者身份） |

通用心法：**先 `kubectl get` 看状态，再 `kubectl describe` 看因果（Events），最后 `kubectl logs` / `kubectl exec` 进现场**；节点层问题直接 ssh 看 journal 与 /var/log/pods。

## 5. 下一步：从 metrics-server 到 Prometheus（PCA 预告）

metrics-server 的三个先天局限：**只有瞬时值**（内存态，重启归零）、**只覆盖 CPU/内存**（没有网络、磁盘、业务指标）、**不能查询**（没有历史就没有 PromQL 这类语言）。生产的完整可观测栈是 Prometheus 全家桶——数据同源（cAdvisor、kubelet、apiserver 的 /metrics 端点）但架构完全不同：pull 模型 + TSDB 历史存储 + PromQL + Alertmanager + Grafana。

```promql
# [master] Prometheus/Grafana 中执行 —— 先尝两口 PromQL(08-pca 展开)
# 节点 CPU 利用率(%): 空闲率取反
100 * (1 - avg by (instance) (rate(node_cpu_seconds_total{mode="idle"}[5m])))

# 每个 Pod 的 CPU 使用(核), 排除 pause 容器与空容器
sum by (namespace, pod) (
  rate(container_cpu_usage_seconds_total{container!="", container!="POD"}[5m])
)
```

学习路径与 PCA 认证对齐：`08-pca/01-observability-concepts`（指标/日志/追踪三支柱）→ `02-prometheus-architecture`（TSDB、抓取、服务发现）→ `03-promql-guide`（rate/聚合/直方图）→ `04-instrumentation-exporters`（exporter 与埋点）→ `05-alerting-alertmanager`（告警路由与抑制）→ `06-grafana-dashboards`（面板）。练习集群可用 `scripts/setup/install-prom-stack.sh` 一键装 kube-prometheus-stack，届时回来对照本章第 1 节的链路图，能看到两条并行的数据链路各自服务谁。

## 实战演练

一个 Pod 同时做三件事：烧 CPU（喂给 metrics-server）、产日志（走三层）、生成 Events。在 master 上执行：

```bash
# [master] 前置: 按第 1 节装好 metrics-server
kubectl -n kube-system get deployment metrics-server
```

```yaml
# [master] kubectl apply -f - <<'EOF' —— 双容器观测样本
apiVersion: v1
kind: Pod
metadata:
  name: observable
  labels:
    app: observable
spec:
  containers:
  - name: burner
    image: busybox:1.36
    command: ["sh", "-c", "while true; do :; done"]
  - name: logger
    image: busybox:1.36
    command: ["sh", "-c", "i=0; while true; do i=$((i+1)); echo tick $i; sleep 1; done"]
EOF
```

```bash
# [master] 1. 指标链路: 等约 30s 让 metrics-server 抓到第一轮
sleep 30 && kubectl top pod observable
# 预期: CPU 接近 1000m(burner 单核打满), MEMORY 几个 Mi
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/default/pods/observable | head -c 200; echo
# 预期: JSON 里两个容器各一条 usage

# [master] 2. 日志链路第一/三层: kubectl 读到的是节点文件
kubectl logs observable -c logger --tail=3
# 预期: tick N 连续三行

# [worker1] 3. 日志链路第二层: 直接找到同一份文件(先确认 Pod 落在哪个节点)
#   kubectl get pod observable -o wide   ← 在 master 查, 然后到对应节点执行:
sudo ls -d /var/log/pods/default_observable_*
sudo tail -n 3 /var/log/pods/default_observable_*/logger/0.log
ls -l /var/log/containers/ | grep observable
# 预期: tail 输出与 kubectl logs 相同(kubectl 读的就是它); containers 下是软链

# [master] 4. Events 与审计
kubectl get events -n default --sort-by=.lastTimestamp | tail -5
kubectl delete pod observable
kubectl get events -n default --field-selector reason=Killing --sort-by=.lastTimestamp | tail -3
# 预期: 能看到 Pulling/Created/Started 与 Killing 的时间线; Events 里没有"是谁删的"

# [master] 5. 清理(如装了 audit, 可在审计日志里找到这次 delete 的操作者)
sudo grep -c '"verb":"delete"' /var/log/audit/audit.log 2>/dev/null || echo "(未开启 audit, 见第 3 节)"
```

验证标准即各步"预期"。若步骤 1 无输出，按第 1 节末尾的顺序查 metrics-server。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| `kubectl top` 报 `Metrics API not available` | metrics-server 未部署或挂了 | 装齐并看其 Pod 日志；`kubectl get apiservice v1beta1.metrics.k8s.io` |
| metrics-server 起不来，日志报 x509 错误 | kubelet 服务端证书自签，校验失败 | 实验集群加 `--kubelet-insecure-tls`；生产给 kubelet 配 CA 背书证书 |
| metrics-server 正常但部分节点无数据 | 到 kubelet:10250 不通（CNI/防火墙/地址类型） | 看其日志的节点地址；检查 `--kubelet-preferred-address-types` 与节点间连通性 |
| `kubectl logs` 报 `previous container ... not found` | 容器还没崩溃过或已被 GC | 直接看当前日志；describe 看 restartCount 判断是否真崩过 |
| 节点上找不到某 Pod 的日志目录 | Pod 不在该节点或已被清理 | `kubectl get pod -o wide` 定位节点；删除后目录很快清空，中心化日志才有留存 |
| 想查 2 小时前的 Events 一无所获 | `--event-ttl` 默认 1 小时 | 依赖中心化事件采集或改 apiserver 参数；历史诉求走 audit/日志系统 |
| 加了 audit 参数后 apiserver 起不来 | policy 文件路径/挂载错误导致静态 Pod 崩溃循环 | 节点上核对文件与 volume 挂载，看 `journalctl -u kubelet` 与 `crictl logs` |
| `kubectl logs` 卡住或超时 | apiserver → kubelet:10250 链路问题 | 查安全组/证书；绕过用节点文件直读（第 2 节） |

## 自测

1. metrics-server 和 Prometheus 都从 kubelet/cAdvisor 拿数据，为什么还要两个系统并存？

<details><summary>答案</summary>

定位不同。metrics-server 是集群内置资源指标管道：瞬时值、内存态、通过聚合 API 暴露，专供 HPA 与 kubectl top 这类"当下值"消费方，零额外基础设施。Prometheus 是通用时序监控：TSDB 存历史、PromQL 任意查询、覆盖网络/磁盘/业务等一切能暴露 /metrics 的目标，还带告警。前者解决"控制面自动扩缩要实时数据"，后者解决"人要看趋势、要告警、要做容量规划"。
</details>

2. `kubectl logs` 的数据完整路径是什么？为什么它回答不了"昨天 22 点的日志"？

<details><summary>答案</summary>

kubectl → apiserver → Pod 所在节点的 kubelet:10250 → kubelet 读节点文件 /var/log/pods/.../0.log 返回。它读的是节点本地文件：被 kubelet 轮转（默认 10Mi×5 个文件）覆盖、Pod 被删/节点丢失后即消失，且 apiserver 只代理"读文件"这个动作，没有留存。历史日志必须靠第 2 节第 ③ 层：节点上的日志代理把文件送进 Loki/ELK 等中心存储。
</details>

3. 线上有人误删了一个 Namespace，事后你要查"是谁删的、什么时候删的"。Events 能回答吗？audit 要怎么配才能保证下次能回答？

<details><summary>答案</summary>

Events 通常只记录对象层面的结果（namespace 被标记 deleting），不带操作者身份，回答不了。audit 在请求链上记录 user/verb/resource/sourceIP/时间戳：策略里对 namespaces 的 delete（至少 Metadata 级）落日志，且日志文件留存周期要覆盖追溯窗口（--audit-log-maxage 或外发 SIEM）。注意 audit 默认关闭——出事后再开就晚了。
</details>

4. metrics-server 为什么必须经历 apiserver 的聚合层（APIService + front-proxy）而不是像 Prometheus 那样被直接抓取？

<details><summary>答案</summary>

因为它要"伪装"成 K8s API 的一部分：kubectl/HPA 用统一的 /apis/metrics.k8s.io 路径访问，apiserver 把请求代理给 metrics-server，并用 front-proxy 客户端证书把"已认证的最终用户身份"透传过去——这样 metrics-server 无需自己管认证，且能按调用方身份做权限判断。Prometheus 是外部系统，主动 pull 各目标 /metrics，不需要也没必要进聚合层。
</details>

5. Pod 状态 Running、Service 也在，但 upstream 一直 503。给出一条不超过四步的排查序列。

<details><summary>答案</summary>

① `kubectl get endpoints <svc>`——空则查 selector 与 Pod label、readiness 探针（describe pod 看 Events）；② endpoints 正常则 `kubectl exec` 进同 ns 的调试 Pod `wget -qO- http://<endpointIP>:<port>` 验证容器本身；③ 再 `wget http://<clusterIP>:<port>` 区分"端点坏"还是"Service 坏"；④ 域名访问失败才查 DNS（nslookup）。顺序原则：先两端（endpoints/容器）后中间（Service/DNS）。
</details>

## 延伸阅读

- Resource metrics pipeline（kubectl top 链路）：https://kubernetes.io/docs/tasks/debug/debug-cluster/resource-metrics-pipeline/
- metrics-server 仓库（部署与参数）：https://github.com/kubernetes-sigs/metrics-server
- Logging architecture（三层日志）：https://kubernetes.io/docs/concepts/cluster-administration/logging/
- Events API：https://kubernetes.io/docs/reference/kubernetes-api/cluster-resources/event-v1/
- Auditing（策略与级别）：https://kubernetes.io/docs/tasks/debug/debug-cluster/audit/
- 集群排障工具大全：https://kubernetes.io/docs/tasks/debug/
