# Lab 01 · Loki 日志管道：采集、入库与 LogQL 查询

> 难度：★★☆ ｜ 考点：日志采集拓扑 + LogQL（PCA 可观测性的日志腿动手版）｜ 前置：10-logging 第 3、4 章 ｜ 预计 45 分钟

## 前置条件与环境说明

- 一套可用的 kubeadm 练习集群（单 master + Calico 即可），节点能访问 `docker.io` 拉取 `grafana/loki`、`grafana/promtail`、`grafana/grafana`、`busybox` 镜像。
- 资源需求：Loki 约 256Mi 内存、Grafana 约 256Mi、每节点一个 Promtail 约 128Mi——单 master 小 VM 也能跑。
- master 节点上有 `curl` 与 `jq`（没有则 `sudo apt-get install -y curl jq`）。
- 本 lab 的目标拓扑：

```
┌ node（每个节点） ──────────────────────────────────┐
│ /var/log/pods/*/*/*.log                            │
│    │                                               │
│ promtail (DaemonSet, K8s 发现+打标签+CRI 解析)      │──push──► Loki (Deployment, 3100)
└────────────────────────────────────────────────────┘            │ NodePort 30100
logger (default ns, JSON 日志) ──stdout──► 同上                    ▼
                                                       Grafana (NodePort 30300, 数据源已预置)
```

- 环境不具备时的替代方式：只有装有 Docker 的 Ubuntu VM 时，按 solution.md 末尾"Docker Compose 替代路径"完成同等功能（采集 + 4 条查询），但 `check.sh` 的集群检查项以 k8s 路径为准。

## 场景

你是新到岗的运维工程师，团队决定用 Grafana Loki 替代即将到期的 ELK 许可。领导要求你先在练习集群上证明整条链路可用：集群里所有 Pod 的日志要能被采集、打上 K8s 标签并集中可查；同时团队里以后要写告警规则的人需要一份"如何用 LogQL 回答四类典型问题"的演示记录。你需要在 45 分钟内交付：

1. 一套跑在 `logging-lab` namespace 里的 Loki + Promtail + Grafana；
2. 一个持续输出 JSON 结构化日志的测试应用（`default` namespace 的 Deployment `logger`）；
3. 四个查询结果文件，分别演示"按标签捞日志、按解析字段过滤、按级别聚合计数、按节点看日志速率"。

Grafana 的 Loki 数据源必须预置好（开箱即查，不手工点 UI）；Loki 用 NodePort 暴露，master 上的 curl 能直接查询。

## 任务清单

1. 创建 namespace `logging-lab`。
2. 部署 Loki（Deployment，单副本，`grafana/loki:3.4.2`，配置放 ConfigMap：`auth_enabled: false`、TSDB schema v13、filesystem 存储、`replication_factor: 1`；数据 emptyDir；readinessProbe 打 `/ready`；Service `loki` 暴露 3100，NodePort 30100）。
3. 部署 Promtail（DaemonSet，配置含 `kubernetes_sd_configs: role: pod`、relabel 出 `namespace/pod/container/node_name/app` 五个标签、`pipeline_stages` 用 `cri: {}` 解析 CRI 外壳；push 地址指向 `http://loki.logging-lab.svc.cluster.local:3100/loki/api/v1/push`；挂载 `/var/log/pods` 只读、positions 落 hostPath；配 ServiceAccount + ClusterRole（pods/nodes/namespaces 只读）+ ClusterRoleBinding）。
4. 部署 Grafana（Deployment + Service NodePort 30300，admin 密码 `admin`），用 provisioning ConfigMap 预置 Loki 数据源（`type: loki`，URL 指向集群内 svc）。
5. 在 `default` 部署测试应用 `logger`（busybox，每 0.1 秒输出一行 JSON：`ts/level/service/msg`，每 10 行一条 `level=error`）。
6. 在 lab 目录下建 `results/` 目录，用 master 上的 curl 通过 NodePort 完成 4 条查询并分别存为 `results/q1.txt` ~ `results/q4.txt`：
   - q1（流选择器）：查 `default` namespace 中 `app="logger"` 的日志，limit 5；
   - q2（解析过滤）：`default` namespace 日志经 `| json` 解析后取 `level="error"` 的行，并用 `line_format` 只输出 `service` 与 `msg` 两个字段，limit 10；
   - q3（度量聚合）：`sum by (level) (count_over_time(...))` 统计 logger 最近 30 分钟各 level 的行数（instant 查询端点）；
   - q4（按节点速率）：`sum by (node_name) (rate(...))` 统计 `kube-system` 最近 5 分钟各节点日志速率（instant 查询端点）。

## 验收标准

- `kubectl -n logging-lab get deploy,ds,svc` 中：loki/grafana Ready 1/1，promtail DS desired=ready，svc loki 有 3100、grafana 有 3000；
- `curl http://<node-ip>:30100/ready` 返回 `ready`；
- `curl http://<node-ip>:30100/loki/api/v1/labels` 能看到 `namespace`、`app` 等标签，证明 Promtail 的 K8s 发现与打标签生效；
- `results/q1.txt` 含 logger 的 `tick` 日志行；`q2.txt` 是纯 `logger tick N` 形式的 error 行；`q3.txt` 的返回里 info/error 两个级别都有计数；`q4.txt` 至少含一个 `node_name` 指标序列；
- 浏览器打开 `http://<node-ip>:30300`（admin/admin），Explore 里选 Loki 后输入 `{namespace="default"}` 能直接出日志。
- 运行 `./check.sh` 输出 `SCORE: 13/13`。

## 提示（卡住再看）

<details><summary>提示 1：组件配置骨架</summary>

Loki 的最小可用配置四件套：`auth_enabled: false`（单租户）、`common.path_prefix` 与 filesystem 存储（chunks/rules 目录）、`replication_factor: 1` + inmemory ring、`schema_config.configs[0]`（`store: tsdb`、`object_store: filesystem`、`schema: v13`、`from: 2024-01-01`）。Promtail 的 K8s 采集核心是 `kubernetes_sd_configs: - role: pod` + `relabel_configs`（把 `__meta_kubernetes_*` 元数据转成最终标签）+ `pipeline_stages: - cri: {}`（剥掉 CRI 行的时间/stream/F-P 外壳）。第 3、4 章有完整片段可抄。
</details>

<details><summary>提示 2：Promtail 没抓到日志怎么排查</summary>

按顺序：`kubectl -n logging-lab logs ds/promtail --tail=50`（看 K8s 发现与 push 是否报错）；确认 DaemonSet 挂了 `/var/log/pods`；确认 push URL 是集群内 FQDN `http://loki.logging-lab.svc.cluster.local:3100/loki/api/v1/push`；然后查 Loki 侧 `curl http://<node-ip>:30100/loki/api/v1/labels` 是否已有标签。
</details>

<details><summary>提示 3：q3/q4 用哪个端点、时间参数怎么给</summary>

q1/q2 是"日志查询"走 `/loki/api/v1/query_range`（要 `query`、`start`、`end`、`limit`，start/end 用 epoch 纳秒：`$(date +%s)` 后拼 9 个 0）；q3/q4 是"度量查询"走 `/loki/api/v1/query`（instant，只要 `query`）。curl 记得 `-sG` + `--data-urlencode`，让 query 里的空格与竖线正确编码。
</details>
