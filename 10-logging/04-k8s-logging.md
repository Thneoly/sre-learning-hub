# 04 · Kubernetes 日志：路径、采集模式与管道衔接

> 模块：日志（10-logging）｜ 建议时长：3 小时 ｜ 前置：01~03 章、09-otel/03 Collector（推荐）｜ 关联认证：CKA 故障排查（日志相关操作）

## 学习目标

- 能说出容器 stdout/stderr 在节点上的确切文件路径、`/var/log/containers` 软链接的指向、CRI 行格式中 F/P 标记的含义
- 能解释 `kubectl logs` 的完整取数路径（apiserver → kubelet → CRI）
- 能对比三种采集模式（节点 DaemonSet / sidecar / 中心化）并按场景选型
- 能配置 kubelet 的日志轮转参数，并说明轮转对采集端"不重不漏"的影响
- 能搭建 OTel Collector 的 filelog 日志管道（解析 CRI、富化 K8s 元数据、对接 Loki）
- 能设计多租户隔离与保留策略（Loki tenant / ES ILM）

## 1. 容器日志到底落在哪

K8s 对"应用日志"只有一个硬性约定：**写 stdout/stderr**。之后的事不归应用管：

```
容器进程 write(1, "hello\n")
      │  stdout/stderr 由容器运行时接管
      ▼
节点文件系统（CRI 容器运行时落盘）：
  /var/log/pods/<namespace>_<pod-name>_<pod-uid>/<container-name>/<N>.log
      │  软链接（兼容既有采集器）
      ▼
  /var/log/containers/<pod-name>_<namespace>_<container-name>-<container-id>.log
      │  指向 ↑ 上面那个真实文件
```

两处路径的规则要背：

- 真实文件：`/var/log/pods/default_demo_9f0f.../demo/0.log`——namespace_podname_poduid/容器名/重启序号。**容器重启，序号 +1**（`1.log`、`2.log`……），旧文件保留到被轮转清理。
- 软链接：`/var/log/containers/...` 里是 `..` 回指 `/var/log/pods` 的同名文件，纯粹是为了照顾 Docker 时代 `json-file` 驱动的采集习惯。

`kubectl logs` 的取数路径（面试/CKA 排查都要会）：

```
kubectl logs demo
  → apiserver 收到 /api/v1/namespaces/default/pods/demo/log
  → apiserver 向 Pod 所在节点的 kubelet 发 /containerLogs/... 请求
  → kubelet 调 CRI（containerd）的 ReadFilelogs/接口读上述文件
  → 原样返回（kubectl 不经过任何中心化日志系统）
```

推论：`kubectl logs` 能看到的日志，节点上那个文件一定存在；反之，Pod 被删除后其 `/var/log/pods/<uid>` 目录也随 CRI 清理而消失（`kubelet` 的垃圾回收）——**"Pod 删了日志就没了"不是 bug，是设计**，这正是中心化日志系统存在的理由。

## 2. CRI 日志格式与驱动

containerd 实现 CRI 时，每行的落盘格式（注意与 Docker `json-file` 不同）：

```
2026-08-22T08:15:04.123456789Z stdout F {"level":"info","msg":"hello"}
└──────────── 时间(RFC3339Nano) ─────────┘ └ stream ┘└tag┘└──── 正文 ────┘
```

- **stream**：`stdout` 或 `stderr`（很多采集器会把 stderr 行自动当 error 级别）。
- **tag**：`F` = full（完整行），`P` = partial（被运行时按最大行长截断的**续行**，下一行接续）。采集器解析时必须按 F/P 重组，否则超长行（比如整段 JSON 被截）会碎成多条伪日志。默认单行上限由运行时决定（containerd 默认 16 KB）。

Docker（若仍用 dockershim 时代遗产）则是 `json-file` 格式：`{"log":"...\n","stream":"stdout","time":"..."}`。采集器要同时兼容两种格式（Fluent Bit 的 `docker` parser、OTel 的 router 按 body 形态分流）。

**轮转**由两层控制：

- **kubelet 侧（推荐、声明式）**：KubeletConfiguration 的 `containerLogMaxSize`（默认 10Mi）与 `containerLogMaxFiles`（默认 5）。CRI 运行时据此对 `/var/log/pods` 文件滚动。kubeadm 集群里改这里：

```yaml
# kubelet 配置片段（kubeadm: ConfigMap kube-system/kubelet-config，改后重启 kubelet）
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
containerLogMaxSize: "10Mi"
containerLogMaxFiles: 5
```

- **运行时侧**：containerd 的 CRI 插件还有 `max_container_log_line_size`（截断行长）等更细的参数，位于 `/etc/containerd/config.toml` 的 `plugins."io.containerd.grpc.v1.cri"` 下，字段名随版本演进，**以官方文档为准**。

轮转对采集端是核心考验：文件会被 rename（`0.log` → `0.log.1`）再截断重建，采集器靠"记住 offset + 监听 rename + inode 追踪"保证不重不漏（Filebeat 的 registry、promtail 的 positions、filelog receiver 都实现了这套）。这也是 positions 文件必须放持久卷的原因（第 1 章坑表）。

## 3. 三种采集模式

```
模式 A：节点 agent（DaemonSet，默认选择）
┌ node ──────────────────────────────┐
│ /var/log/pods/*/*/*.log            │
│        │                           │
│   daemonset: fluent-bit/promtail/  │
│             otel-collector(agent)  │──► Loki / ES / Kafka
└────────────────────────────────────┘
一个节点一份开销；标签靠 K8s SD + 元数据补齐

模式 B：sidecar（特例）
┌ Pod ───────────────────────────────┐
│ app ─stdout→ 文件(Volume)           │
│ sidecar agent ──读该文件──────────► │ 后端
└────────────────────────────────────┘
变体：streaming sidecar——两个容器挂同一个 emptyDir，
app 写 /logs/app.log，sidecar tail -F 转发到 stdout

模式 C：中心化（push 或两级管道）
app/SDK ──OTLP──► 中心 Collector（Deployment/gateway）──► 后端
节点 agent ──────►（富化、脱敏、路由、限流集中做）
```

| | DaemonSet（A） | sidecar（B） | 中心化（C） |
|---|---|---|---|
| 资源开销 | 与 Pod 数解耦，最省 | 每 Pod 一份，贵 | 无节点开销，但要养网关 |
| 部署侵入 | 集群级一次部署 | 要改每个 Workload | 改应用或配统一接入 |
| 标签/元数据 | K8s SD 自动补 | 天然同 Pod，最准 | 依赖传递的 Resource 属性 |
| 适用 | 所有写 stdout 的负载 | 应用写自有文件、多行按文件分路、按 Pod 精细控制 | 统一治理（脱敏/路由/多后端）、SDK 直推 |
| 典型坑 | 节点文件权限、rotation | 容器重启序号变化、资源预算 | 网关单点、应用耦合 |

经验法则：**A 打底，B 兜特例，C 做治理层**。C 与 09-otel/03 的三种 Collector 部署模式一节完全同构（agent/gateway 两级是生产标配）。

## 4. 与 OTel Collector 的日志管道衔接

09-otel 模块（见 [09-otel/03-collector.md](../09-otel/03-collector.md)）讲过 Collector 的 receivers → processors → exporters 管道。日志腿的标准配方是 **filelog receiver + k8sattributes processor + otlphttp exporter 到 Loki**（Loki 3.x 原生接收 OTLP HTTP）：

```yaml
# OTel Collector 配置片段（DaemonSet 方式部署，每节点一个）
receivers:
  filelog:
    include:
      - /var/log/pods/*/*/*.log
    exclude:
      - /var/log/pods/logging-lab_*/*/*.log    # 不收自己，防循环
    start_at: end
    include_file_path: true
    include_file_name: false
    operators:
      # 1) 从文件路径提取 K8s 元数据（/var/log/pods/<ns>_<pod>_<uid>/<ctr>/0.log）
      - id: extract-metadata
        type: regex_parser
        regex: '^.*pods/(?P<namespace>[^_]+)_(?P<pod>[^_]+)_(?P<uid>[a-f0-9-]{36})/(?P<container>[^/]+)/.*$'
        parse_from: attributes["log.file.path"]
      # 2) 解析 CRI 行格式（时间 stream tag 正文）
      - id: parse-cri
        type: regex_parser
        regex: '^(?P<timestamp>\d{4}-\d{2}-\d{2}T[^ ]+) (?P<stream>stdout|stderr) (?P<tag>[FP]) (?P<content>.*)$'
      - type: move
        from: attributes.content
        to: body
      - type: time_parser
        parse_from: attributes.timestamp
        layout_type: gotime
        layout: '2006-01-02T15:04:05.999999999Z07:00'

processors:
  batch:
    send_batch_size: 512
  k8sattributes:
    extract:
      metadata:
        - k8s.namespace.name
        - k8s.pod.name
        - k8s.node.name
    podassociation:
      - sources:
          - from: resource_attribute
            name: k8s.pod.name

exporters:
  otlphttp/loki:
    endpoint: http://loki.logging-lab.svc.cluster.local:3100/otlp
    tls:
      insecure: true

service:
  pipelines:
    logs:
      receivers: [filelog]
      processors: [batch, k8sattributes]
      exporters: [otlphttp/loki]
```

这套配置里的三个要点：

1. **filelog 的 operators 就是一条小 pipeline**：路径正则提出 namespace/pod/container（成为后续标签的来源），CRI 正则剥掉时间/stream/tag 壳，`move` 把正文归位到 body——等价于 promtail 的 `cri: {}` pipeline stage + relabel。
2. **F/P 续行**要靠 `recombine` operator 合并（`if: attributes.tag == 'P'`，配合 `combine_with`/`is_last_entry`），超长 JSON 行多时必须配，否则下游解析失败。
3. DaemonSet 部署时的挂载与 promtail 相同：`/var/log/pods` 只读挂载 + positions 存储（filelog 的 `storage` 扩展接 file_storage），RBAC 给 k8sattributes 用（Pod 列表只读）。

与 promtail 的取舍：promtail 对接 Loki 是"零胶水"（K8s 发现、CRI 解析、标签 relabel 全内置）；OTel Collector 的日志管道要自己拼 operators，但换来三信号统一采集与厂商中立。存量 Promtail、新建 OTel/Alloy，是当下常见的迁移方向。

## 5. 多租户与保留策略

**多租户**要回答"谁的日志、谁能看、花谁的额度"：

- **Loki**：原生多租户由 `X-Scope-OrgID` 请求头实现。`auth_enabled: true` 时，push 与查询都带这个头，不同租户的数据在索引与对象存储里前缀隔离（`fake/<tenant>/...`），配额（每租户 ingestion/query 速率、保留期）在 `limits_config.per_tenant_override_config` 里按租户覆盖。网关（或 OTel Collector 的 headers 设置换）负责注入租户头，用户不直接碰它。
- **ES**：用独立 index 嶒（`logs-<tenant>-*`）+ Kibana Space 做 UI 隔离，配额靠 ILM 与分租户 rollover 策略。
- **K8s 层**：RBAC 只能管 `kubectl logs`（Pod logs 的子资源权限），管不了中心化日志系统内的数据——别把两者混为一谈（CKS 思维：`logs` 子资源权限给到即等于能读容器日志）。

**保留策略**的两个驱动：成本（越老越冷越便宜）与合规（审计日志法定保留期反而更长）。落地形态：

```yaml
# Loki：按租户差异化保留（compactor 必须开 retention）
# loki-config.yaml 片段
compactor:
  working_directory: /loki/compactor
  retention_enabled: true
limits_config:
  retention_period: 720h          # 全局默认 30 天
# overrides.yaml（per_tenant_override_config 指向的文件）
overrides:
  audit-team:
    retention_period: 2190h       # 审计租户保 90 天
  dev-team:
    retention_period: 72h         # 开发租户保 3 天
```

ES 侧对应物是 ILM（第 2 章第 8 节）：hot→warm→cold→delete 的分阶段保留，delete 阶段即到期物理删除。设计清单：每类日志定保留期（infra 14~30 天、业务 30~90 天、安全审计按合规）、到期方式（物理删除 vs 降级到对象存储冷层）、删除是后台异步任务（compactor 周期执行，别指望删完立即释放存储额度对账）。

## 实战演练：在练习集群上摸清日志的物理位置

环境：kubeadm 单 master + Calico 练习集群（Pod 可能调度在 master 上，下面用 `-o wide` 确认节点后在对应节点操作）。

**1. 制造一个会持续打日志的 Pod**

```bash
# [master]
kubectl -n default run demo --image=busybox:1.36 --restart=Never -- sh -c \
  'while true; do echo "{\"ts\":\"$(date -u +%FT%TZ)\",\"level\":\"info\",\"msg\":\"tick from demo\"}"; sleep 2; done'
sleep 5
kubectl -n default get pod demo -o wide
kubectl -n default logs demo --tail=3 --timestamps
```

预期输出：`--timestamps` 前缀 + 3 行 JSON（kubelet 附的时间戳在行首，注意它与正文里的 `ts` 字段是两回事）。

**2. 找到并检查节点上的真实文件**

```bash
# [master]
POD_UID=$(kubectl -n default get pod demo -o jsonpath='{.metadata.uid}')
NODE=$(kubectl -n default get pod demo -o jsonpath='{.spec.nodeName}')
echo "uid=$POD_UID node=$NODE"
```

```bash
# [demo 所在节点]
ls /var/log/pods/default_demo_${POD_UID}/demo/
head -2 /var/log/pods/default_demo_${POD_UID}/demo/0.log
ls -l /var/log/containers/ | grep demo
```

预期输出：目录里有 `0.log`；head 出来的每行形如 `2026-08-22T08:15:04.123456789Z stdout F {"ts":...}`——**CRI 外壳**清晰可见（时间 + stream + F/P + 正文）；`/var/log/containers/default_demo_<ns>_demo-<id>.log -> /var/log/pods/.../0.log` 的软链接指向。

**3. 验证 kubectl logs 与文件的一致性 + 轮转参数**

```bash
# [master]
kubectl -n kube-system get cm kubelet-config -o yaml | grep -iE 'containerLog' || echo "未显式配置（用默认值 10Mi/5）"
kubectl -n default logs demo --since=10s | wc -l
```

```bash
# [demo 所在节点]
tail -5 /var/log/pods/default_demo_${POD_UID}/demo/0.log | wc -l
```

预期：两边行数量级一致（约每 2 秒 1 行）。没有中心化系统时，"`kubectl logs` 看一眼"与"节点上 tail 文件"是同一个数据源的两种读法。

**4. 感受"Pod 删除即日志消失"**

```bash
# [master]
kubectl -n default delete pod demo --wait=false
sleep 10
```

```bash
# [demo 所在节点]
ls /var/log/pods/ | grep -c demo || true
```

预期：短暂延迟后（kubelet GC/CRI 清理）目录消失。这就是第 1 章说的"为什么需要采集管道"的现场证据。清理完成。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 采集器抓不到某个 Pod 的日志 | 应用写了自己的文件而非 stdout | 改写 stdout，或加 sidecar 采集该文件（模式 B） |
| 日志行被截断、JSON 解析失败 | 超过运行时最大行长被切，F/P 未重组 | 采集端配 multiline/recombine 按 F 合并；或调大 max_container_log_line_size |
| 每次发布后日志流"断流"又出现 | Pod 名进标签，重建即新流 | 标签用 deployment 名而非 pod 名（低基数原则，第 3 章） |
| DaemonSet 起了但读不到文件 | 未挂 /var/log/pods 或 SELinux/AppArmor 拦截 | 只读挂载该路径；检查安全模块审计日志 |
| `kubectl logs` 报 "previous container not found" | 容器重启后旧容器日志已被清 | 排查要快，或提前接中心化系统（`--previous` 只在旧文件还在时有效） |
| 节点磁盘被 /var/log 吃满 | chatty 应用 + 轮转参数过松 | 收紧 containerLogMaxSize/MaxFiles，同时对源头限流（结构化分级） |

## 自测

1. `/var/log/pods/.../demo/1.log` 里的 `1` 是什么意思？采集器要怎么对待这些序号？

<details><summary>答案</summary>

容器重启序号：`0.log` 是第一次运行，`1.log` 是重启后的新文件。采集器要同时扫描该目录下所有序号的文件（不能只盯 `0.log`），并在文件轮转（rename 为 `.log.1` 等）时靠 positions/inode 续读保证不重不漏；Pod 级重建（新 uid）则是全新目录，靠采集器的 K8s 发现重新跟踪。
</details>

2. `kubectl logs` 拿日志的完整路径是什么？它和中心化日志系统是什么关系？

<details><summary>答案</summary>

kubectl → apiserver（`/api/v1/namespaces/<ns>/pods/<pod>/log`）→ kubelet（`/containerLogs/...`）→ CRI 运行时读 `/var/log/pods` 下的文件返回。它是一次性、实时、无历史的读取：Pod 删除后数据源消失，apiserver 不存储任何日志。所以它是排查入口而非归档系统；RBAC 上它对应 pods/log 子资源权限（CKS 关键字）。
</details>

3. 什么样的应用让你"只能"选 sidecar 模式采集？

<details><summary>答案</summary>

应用框架强制写自己的日志文件（且改不了配置）；一个 Pod 里多个容器/多个文件需要分开路由（访问日志与错误日志去不同后端）；多行日志必须按文件边界重组，跨节点统一重组不可靠；安全要求日志不落在节点盘（sidecar 直接收走）。其余场景 DaemonSet 都是更省的选择。
</details>

4. CRI 行里的 `P` 标记被采集器忽略会发生什么？怎么修？

<details><summary>答案</summary>

被运行时截断的长行会作为多条独立日志入库：JSON 正文碎裂导致 `| json` 解析失败（出现 `__error__="json_parse_error"`），堆栈被拆散。修法：采集端按 tag 重组——promtail 用 multiline stage，OTel filelog 用 recombine operator（`if: attributes.tag == 'P'`），并确认重组发生在解析之前。
</details>

5. 多租户 Loki 里"隔离"发生在哪一层？用户请求是怎么被归到租户的？

<details><summary>答案</summary>

发生在 Loki 存储层：`auth_enabled: true` 时每条 push/查询必须带 `X-Scope-OrgID`，不同租户的索引与 chunk 在对象存储里按租户前缀隔离，配额（速率、流数、保留期）可按租户 override。租户头由前置网关或采集端（OTel Collector 的 exporter headers）注入并鉴权，终端用户不直接提供——否则等于自报家门。K8s 的 RBAC 只能管 `kubectl logs`，管不到 Loki 里的数据。
</details>

## 延伸阅读

- Kubernetes 官方：Logging Architecture（节点日志路径与采集模式） — <https://kubernetes.io/docs/concepts/cluster-administration/logging/>
- Kubernetes 官方：KubeletConfiguration（containerLogMaxSize/MaxFiles） — <https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/>
- OTel Collector filelog receiver 与 operators — <https://opentelemetry.io/docs/specs/otel/logs/>
- Loki 多租户与保留 — <https://grafana.com/docs/loki/latest/operations/multi-tenancy/>
- 动手：[labs/01-loki-pipeline](labs/01-loki-pipeline/task.md)（把本章的 DaemonSet 采集 + LogQL 查询完整跑一遍）
