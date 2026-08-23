# Lab 01 · 解答：Loki 日志管道（采集、入库、LogQL 查询）

目标拓扑：

```
┌ 每个节点 ────────────────────────────────────────────────┐
│ /var/log/pods/<ns>_<pod>_<uid>/<ctr>/0.log               │
│    │  (hostPath 只读挂载)                                 │
│ promtail DaemonSet                                       │
│   kubernetes_sd_configs(role: pod) ──发现──► relabel 打标签│
│   pipeline_stages: cri ──剥掉 CRI 外壳──► push            │
└────────────┬──────────────────────────────────────────────┘
             │ http://loki.logging-lab.svc.cluster.local:3100/loki/api/v1/push
             ▼
      deploy/loki（single binary，tsdb v13，filesystem）── svc/loki NodePort 30100
      deploy/grafana（数据源预置）────────────────────── svc/grafana NodePort 30300
      deploy/logger（default ns，JSON 日志）──stdout──► 落节点文件，被 promtail 收走
```

镜像 tag 以官方 release 为准，本文用 `grafana/loki:3.4.2`、`grafana/promtail:3.4.2`（Promtail 已进入维护模式，教学与存量仍大量使用）、`grafana/grafana:11.5.2`。

## 步骤 1：namespace

```bash
# [master]
kubectl create namespace logging-lab
```

预期输出：`namespace/logging-lab created`。

## 步骤 2：Loki（ConfigMap + Deployment + Service）

为什么这么配：实验用 single binary 模式（所有组件一个进程），`auth_enabled: false` 免租户头；TSDB schema v13 是 3.x 的默认索引形态；filesystem 存储免去对象存储依赖（生产换 S3/MinIO 只需改 `common.storage` 一段）。

```bash
# [master]
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: logging-lab
data:
  config.yaml: |
    auth_enabled: false

    server:
      http_listen_port: 3100

    common:
      instance_addr: 127.0.0.1
      path_prefix: /loki
      storage:
        filesystem:
          chunks_directory: /loki/chunks
          rules_directory: /loki/rules
      replication_factor: 1
      ring:
        kvstore:
          store: inmemory

    schema_config:
      configs:
        - from: 2024-01-01
          store: tsdb
          object_store: filesystem
          schema: v13
          index:
            prefix: index_
            period: 24h

    limits_config:
      reject_old_samples: true
      reject_old_samples_max_age: 168h
      allow_structured_metadata: true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki
  namespace: logging-lab
  labels:
    app: loki
spec:
  replicas: 1
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
    spec:
      containers:
        - name: loki
          image: grafana/loki:3.4.2
          args: ["-config.file=/etc/loki/config.yaml"]
          ports:
            - containerPort: 3100
              name: http
          readinessProbe:
            httpGet:
              path: /ready
              port: 3100
            initialDelaySeconds: 15
            periodSeconds: 5
          volumeMounts:
            - name: config
              mountPath: /etc/loki
            - name: data
              mountPath: /loki
      volumes:
        - name: config
          configMap:
            name: loki-config
        - name: data
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: logging-lab
spec:
  type: NodePort
  selector:
    app: loki
  ports:
    - port: 3100
      targetPort: 3100
      nodePort: 30100
EOF
kubectl -n logging-lab rollout status deploy/loki --timeout=180s
```

预期输出：`deployment "loki" successfully rolled out`。验证：

```bash
# [master]
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
echo "$NODE_IP"
curl -s "http://$NODE_IP:30100/ready"
```

预期输出：`ready`（首次启动要建 TSDB 索引，多等十几秒）。

## 步骤 3：Promtail（RBAC + ConfigMap + DaemonSet）

三个设计点：positions 放 hostPath（Pod 重建不丢读取位置，日志不重收）；只读挂 `/var/log/pods`（真实文件所在，软链接层可不必挂）；relabel 只出低基数标签（namespace/pod/container/node_name/app——第 3 章的标签设计原则）。

```bash
# [master]
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: promtail
  namespace: logging-lab
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: promtail-logging-lab
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes", "namespaces"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: promtail-logging-lab
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: promtail-logging-lab
subjects:
  - kind: ServiceAccount
    name: promtail
    namespace: logging-lab
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: logging-lab
data:
  config.yaml: |
    server:
      http_listen_port: 9080
      grpc_listen_port: 0

    positions:
      filename: /run/promtail/positions.yaml

    clients:
      - url: http://loki.logging-lab.svc.cluster.local:3100/loki/api/v1/push

    scrape_configs:
      - job_name: kubernetes
        kubernetes_sd_configs:
          - role: pod
        relabel_configs:
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          - source_labels: [__meta_kubernetes_pod_container_name]
            target_label: container
          - source_labels: [__meta_kubernetes_pod_node_name]
            target_label: node_name
          - source_labels: [__meta_kubernetes_pod_label_app]
            target_label: app
        pipeline_stages:
          - cri: {}
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: promtail
  namespace: logging-lab
  labels:
    app: promtail
spec:
  selector:
    matchLabels:
      app: promtail
  template:
    metadata:
      labels:
        app: promtail
    spec:
      serviceAccountName: promtail
      containers:
        - name: promtail
          image: grafana/promtail:3.4.2
          args: ["-config.file=/etc/promtail/config.yaml"]
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
          volumeMounts:
            - name: config
              mountPath: /etc/promtail
            - name: run
              mountPath: /run/promtail
            - name: varlogpods
              mountPath: /var/log/pods
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: promtail-config
        - name: run
          hostPath:
            path: /var/log/promtail-run
            type: DirectoryOrCreate
        - name: varlogpods
          hostPath:
            path: /var/log/pods
EOF
kubectl -n logging-lab rollout status ds/promtail --timeout=180s
```

预期输出：`daemon set "promtail" successfully rolled out`。此时看一眼它自己的日志确认无报错：

```bash
# [master]
kubectl -n logging-lab logs ds/promtail --tail=10
```

预期：无 `error`/`permission denied` 字样；K8s 发现开始工作后能看到 targets 信息。

## 步骤 4：Grafana（预置数据源）

数据源用 provisioning 文件预置：容器一启动就带 Loki，不开 UI 手工配——这是 GitOps 友好的标准做法。

```bash
# [master]
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-datasources
  namespace: logging-lab
data:
  loki.yaml: |
    apiVersion: 1
    datasources:
      - name: Loki
        type: loki
        access: proxy
        url: http://loki.logging-lab.svc.cluster.local:3100
        isDefault: true
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: logging-lab
  labels:
    app: grafana
spec:
  replicas: 1
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      containers:
        - name: grafana
          image: grafana/grafana:11.5.2
          env:
            - name: GF_SECURITY_ADMIN_PASSWORD
              value: admin
          ports:
            - containerPort: 3000
              name: http
          readinessProbe:
            httpGet:
              path: /api/health
              port: 3000
            initialDelaySeconds: 10
            periodSeconds: 5
          volumeMounts:
            - name: datasources
              mountPath: /etc/grafana/provisioning/datasources
      volumes:
        - name: datasources
          configMap:
            name: grafana-datasources
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: logging-lab
spec:
  type: NodePort
  selector:
    app: grafana
  ports:
    - port: 3000
      targetPort: 3000
      nodePort: 30300
EOF
kubectl -n logging-lab rollout status deploy/grafana --timeout=180s
```

浏览器打开 `http://$NODE_IP:30300`（admin/admin）→ Explore → 选 Loki → 输入 `{namespace="logging-lab"}` 应能看到 promtail/loki 自己的日志。

## 步骤 5：logger 应用（JSON 日志源）

```bash
# [master]
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: logger
  namespace: default
  labels:
    app: logger
spec:
  replicas: 1
  selector:
    matchLabels:
      app: logger
  template:
    metadata:
      labels:
        app: logger
    spec:
      containers:
        - name: logger
          image: busybox:1.36
          command: ["/bin/sh", "-c"]
          args:
            - |
              i=0
              while true; do
                i=$((i+1))
                lvl=info
                if [ $((i % 10)) -eq 0 ]; then lvl=error; fi
                echo "{\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"level\":\"$lvl\",\"service\":\"logger\",\"msg\":\"tick $i\"}"
                sleep 0.1
              done
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
EOF
sleep 20
kubectl -n default logs deploy/logger --tail=3
```

预期输出：3 行 JSON，其中每 10 行出现一次 `"level":"error"`。等约 30 秒让 promtail 采集，然后确认标签已经打上：

```bash
# [master]
curl -sG "http://$NODE_IP:30100/loki/api/v1/labels" | jq -r '.data[]' | sort | head -12
```

预期：能看到 `app`、`container`、`namespace`、`node_name`、`pod` 等——这一步证明 K8s 发现 + relabel + push 全链路生效。

## 步骤 6：四个 LogQL 查询并保存结果

准备结果目录与公共变量：

```bash
# [master]
mkdir -p results
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
NOW=$(date +%s); START=$((NOW-3600)); END_TS="${NOW}000000000"; START_TS="${START}000000000"
```

**q1 流选择器**——按标签直接捞流（最便宜的一类查询，索引直接命中）：

```bash
# [master]
curl -sG "http://$NODE_IP:30100/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="default", app="logger"}' \
  --data-urlencode "start=$START_TS" \
  --data-urlencode "end=$END_TS" \
  --data-urlencode 'limit=5' > results/q1.txt
jq -r '.data.result[].values[] | .[1]' results/q1.txt | head -3
```

预期：3 行 JSON 日志（`{"ts":...,"level":"info","service":"logger","msg":"tick N"}`），外层包着 Loki 的响应结构（`"status":"success"`）。

**q2 解析过滤 + 输出格式化**——`| json` 把正文提取成临时字段再过滤（第 3 章"高基数字段留正文"的查询侧用法）：

```bash
# [master]
curl -sG "http://$NODE_IP:30100/loki/api/v1/query_range" \
  --data-urlencode 'query={namespace="default"} | json | level="error" | line_format "{{.service}} {{.msg}}"' \
  --data-urlencode "start=$START_TS" \
  --data-urlencode "end=$END_TS" \
  --data-urlencode 'limit=10' > results/q2.txt
jq -r '.data.result[].values[] | .[1]' results/q2.txt | head -5
```

预期：若干行 `logger tick 10`、`logger tick 20`……（error 行的序号是 10 的倍数）。

**q3 度量聚合**——日志行数按 level 聚合成时序（走 instant 端点 `/query`，注意不是 query_range）：

```bash
# [master]
curl -sG "http://$NODE_IP:30100/loki/api/v1/query" \
  --data-urlencode 'query=sum by (level) (count_over_time({namespace="default", app="logger"} | json [30m]))' \
  > results/q3.txt
jq -c '.data.result[] | {labels: .metric, lines: .value[1]}' results/q3.txt
```

预期：两行输出，形如 `{"labels":{"app":"logger","level":"info","namespace":"default"},"lines":"261"}` 与 `{"labels":{...,"level":"error"},"lines":"29"}`（数量以实际为准，info:error ≈ 9:1）。

**q4 按节点看日志速率**——kube-system 是集群里永远在说话的 namespace，正好用来演示运维视角的"哪台节点日志量异常"：

```bash
# [master]
curl -sG "http://$NODE_IP:30100/loki/api/v1/query" \
  --data-urlencode 'query=sum by (node_name) (rate({namespace="kube-system"}[5m]))' \
  > results/q4.txt
jq -c '.data.result[] | {node: .metric.node_name, lines_per_sec: .value[1]}' results/q4.txt
```

预期：每个节点一条，如 `{"node":"master1","lines_per_sec":"8.3"}`。

## 步骤 7：跑分

```bash
# [master]
chmod +x check.sh && ./check.sh
```

预期输出：

```
PASS: namespace logging-lab 存在
PASS: deployment/loki Ready 副本 >= 1（当前 1）
PASS: daemonset/promtail 全部 Ready（1/1）
PASS: deployment/grafana Ready 副本 >= 1（当前 1）
PASS: svc/loki 暴露 3100 端口
PASS: cm/loki-config 含 schema_config/tsdb/filesystem 存储（tsdb v13）
PASS: cm/promtail-config 含 K8s 发现、Loki push 地址与 cri 解析
PASS: cm/grafana-datasources 预置了 Loki 数据源
PASS: default/deployment logger Ready 副本 >= 1（当前 1）
PASS: q1 流选择器查询成功（q1.txt 含 tick 日志）
PASS: q2 解析过滤查询成功（q2.txt 含 line_format 后的 tick 行）
PASS: q3 度量聚合查询成功（q3.txt 含 info/error 计数）
PASS: q4 按节点速率查询成功（q4.txt 含 node_name 序列）

SCORE: 13/13
```

## 常见排障

| 症状 | 排查 |
|---|---|
| `curl :30100/ready` 一直 not ready | `kubectl -n logging-lab logs deploy/loki --tail=30` 看配置报错（多为 YAML 缩进）；首次建索引要等 |
| promtail 日志里 `permission denied` | 确认 `/var/log/pods` 是 readOnly 挂载且节点上该目录可读；SELinux/AppArmor 环境见 04 章坑表 |
| `labels` 接口查不到 `namespace` 标签 | RBAC 没生效（ClusterRoleBinding 的 subjects namespace 写错）或 relabel 段漏配 |
| q1 结果为空 | 时间窗：确认 `date +%s` 是 master 当前时间、logger 已跑够 30 秒；再用 `{namespace="default"}`（去掉 app）放宽条件定位 |
| q3 报 `parse error` | LogQL 里 `[30m]` 必须在过滤器之后紧跟（`| json [30m]`）；检查 curl 是否用了 `--data-urlencode` |
| Grafana Explore 报 "no data" | 数据源 URL 是否用集群内 FQDN；时间窗是否选了 Last 5 minutes |

## 替代验证方式（Docker Compose 单机）

没有 k8s 集群、只有装 Docker 的 Ubuntu VM 时，用下面的 compose 起等价栈（功能一致，`check.sh` 的集群项不适用，查询结果可用同名文件保存在 compose 文件同目录的 `results/` 下自查）：

```bash
# [装Docker的Ubuntu VM]
mkdir -p /opt/loki-compose/results /opt/loki-compose/data
cat > /opt/loki-compose/loki-config.yaml <<'EOF'
auth_enabled: false
server:
  http_listen_port: 3100
common:
  instance_addr: 127.0.0.1
  path_prefix: /loki
  storage:
    filesystem:
      chunks_directory: /loki/chunks
      rules_directory: /loki/rules
  replication_factor: 1
  ring:
    kvstore:
      store: inmemory
schema_config:
  configs:
    - from: 2024-01-01
      store: tsdb
      object_store: filesystem
      schema: v13
      index:
        prefix: index_
        period: 24h
limits_config:
  reject_old_samples: true
  reject_old_samples_max_age: 168h
  allow_structured_metadata: true
EOF
cat > /opt/loki-compose/promtail-config.yaml <<'EOF'
server:
  http_listen_port: 9080
positions:
  filename: /tmp/positions.yaml
clients:
  - url: http://loki:3100/loki/api/v1/push
scrape_configs:
  - job_name: local
    static_configs:
      - targets: [localhost]
        labels:
          job: logger
          env: compose
          __path__: /var/log/app.log
    pipeline_stages:
      - json:
          expressions:
            level: level
            service: service
      - labels:
          level:
          service:
EOF
cat > /opt/loki-compose/docker-compose.yml <<'EOF'
services:
  loki:
    image: grafana/loki:3.4.2
    command: -config.file=/etc/loki/local-config.yaml
    ports:
      - "3100:3100"
    volumes:
      - ./loki-config.yaml:/etc/loki/local-config.yaml:ro
      - ./data:/loki
  promtail:
    image: grafana/promtail:3.4.2
    command: -config.file=/etc/promtail/config.yaml
    volumes:
      - ./promtail-config.yaml:/etc/promtail/config.yaml:ro
      - ./app.log:/var/log/app.log:ro
    depends_on:
      - loki
  grafana:
    image: grafana/grafana:11.5.2
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin
    ports:
      - "3000:3000"
    volumes:
      - ./grafana-datasources:/etc/grafana/provisioning/datasources:ro
    depends_on:
      - loki
EOF
mkdir -p /opt/loki-compose/grafana-datasources
cat > /opt/loki-compose/grafana-datasources/loki.yaml <<'EOF'
apiVersion: 1
datasources:
  - name: Loki
    type: loki
    access: proxy
    url: http://loki:3100
    isDefault: true
EOF
# 生成与 k8s 版一致的 JSON 日志
for i in $(seq 1 300); do
  lvl=info; [ $((i % 10)) -eq 0 ] && lvl=error
  printf '{"ts":"%s","level":"%s","service":"logger","msg":"tick %d"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lvl" "$i" >> /opt/loki-compose/app.log
  sleep 0.01
done
cd /opt/loki-compose && docker compose up -d && sleep 15
```

查询（等价于 q1~q3，标签换成 compose 版）：

```bash
# [装Docker的Ubuntu VM]
cd /opt/loki-compose
curl -sG "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="logger"} |= "error"' \
  --data-urlencode 'since=1h' --data-urlencode 'limit=5' > results/q1.txt
curl -sG "http://localhost:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="logger"} | json | level="error" | line_format "{{.service}} {{.msg}}"' \
  --data-urlencode 'since=1h' --data-urlencode 'limit=10' > results/q2.txt
curl -sG "http://localhost:3100/loki/api/v1/query" \
  --data-urlencode 'query=sum by (level) (count_over_time({job="logger"} | json [30m]))' > results/q3.txt
jq -c '.data.result[] | {labels: .metric, lines: .value[1]}' results/q3.txt
```

Grafana 在 `http://<VM_IP>:3000`（admin/admin）。清理：`docker compose down && sudo rm -rf /opt/loki-compose`。回到集群路径的清理：

```bash
# [master]
kubectl delete ns logging-lab
kubectl -n default delete deploy logger
```
