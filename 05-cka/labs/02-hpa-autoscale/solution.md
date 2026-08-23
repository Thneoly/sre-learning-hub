# Lab 02 · 解答：HPA 基于 CPU 的自动扩缩容

## 步骤 1：namespace + Deployment（关键是 resources.requests）

```bash
# [master]
kubectl create namespace lab02-autoscale
```

```yaml
# [master] cat > api-front.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api-front
  namespace: lab02-autoscale
  labels:
    app: api-front
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api-front
  template:
    metadata:
      labels:
        app: api-front
    spec:
      containers:
      - name: api-front
        image: nginx:1.27
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
EOF
kubectl apply -f api-front.yaml
```

为什么：HPA 的 utilization 分母取自容器的 `resources.requests.cpu`（100m）。nginx 空载时用量远低于 10m，所以 2 个副本就是稳态；一旦压测，CPU 上冲，HPA 按公式扩容：

```text
期望副本数 = ceil(当前副本数 × 当前CPU% / 目标CPU%)
```

验证输出：

```text
# [master]
$ kubectl -n lab02-autoscale get deploy api-front
NAME        READY   UP-TO-DATE   AVAILABLE   AGE
api-front   2/2     2            2           15s
```

## 步骤 2：Service 供压测访问

```yaml
# [master] cat > api-front-svc.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: api-front
  namespace: lab02-autoscale
spec:
  type: ClusterIP
  selector:
    app: api-front
  ports:
  - port: 80
    targetPort: 80
EOF
kubectl apply -f api-front-svc.yaml
```

为什么：HPA 只看指标不关心 Service，但压测 Pod 需要一个稳定入口，Service 的负载均衡还能让流量摊到所有副本上。

## 步骤 3：创建 HPA

方式一（命令行）：

```bash
# [master]
kubectl -n lab02-autoscale autoscale deployment api-front --min=2 --max=6 --cpu-percent=50
```

方式二（YAML，`autoscaling/v2`，考场建议会写）：

```yaml
# [master] cat > api-front-hpa.yaml <<'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-front
  namespace: lab02-autoscale
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api-front
  minReplicas: 2
  maxReplicas: 6
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
EOF
kubectl apply -f api-front-hpa.yaml
```

验证：

```bash
# [master]
kubectl -n lab02-autoscale describe hpa api-front
```

```text
Name:                                                  api-front
Namespace:                                             lab02-autoscale
Reference:                                             Deployment/api-front
Metrics:                                               ( current / target )
  resource cpu on pods  (as a percentage of request):  3% / 50%
Min replicas:                                          2
Max replicas:                                          6
Deployment pods:                                       2 current / 2 desired
Conditions:
  Type            Status  Reason            Message
  ----            ------  ------            -------
  AbleToScale     True    ReadyForNewScale  recommended size matches current scale
  ScalingActive   True    ValidMetricFound  the HPA was able to successfully calculate a replica count
```

`ScalingActive=True` 且 cpu 显示 `3% / 50%`，说明 metrics-server 数据链路通了；如果显示 `<unknown>/50%`，先查 requests 有没有写、再查 metrics-server。

## 步骤 4：压测验证扩缩容（可选）

```bash
# [master]
kubectl -n lab02-autoscale run load-gen --image=curlimages/curl:8.8.0 --restart=Never -- \
  sh -c 'while true; do curl -s http://api-front/ >/dev/null; done'

kubectl -n lab02-autoscale get hpa -w
```

预期（数值因机器而异）：

```text
NAME        REFERENCE              TARGETS   MINPODS   MAXPODS   REPLICAS
api-front   Deployment/api-front   95%/50%   2         6         2
api-front   Deployment/api-front   210%/50%  2         6         4
api-front   Deployment/api-front   60%/50%   2         6         5
```

缩容慢是刻意设计：默认 `scaleDown` 有 300 秒稳定窗口，避免流量抖动时副本数反复横跳。观察完清理：

```bash
# [master]
kubectl -n lab02-autoscale delete pod load-gen
```

注意：`load-gen` 这种循环单连接 curl 的压测强度有限；如果 REPLICAS 始终不涨，可以多开几个 load-gen（`load-gen2`、`load-gen3`）或改用 `ab`/`wrk` 镜像。

## 步骤 5：运行判分脚本

```bash
# [master]
cd 05-cka/labs/02-hpa-autoscale
chmod +x check.sh
./check.sh
```

通过结果：

```text
PASS: namespace lab02-autoscale 存在且 Active
PASS: deployment api-front 存在
PASS: 容器 resources.requests.cpu 为 100m
PASS: 容器 resources.requests.memory 为 128Mi
PASS: service api-front 存在且 port 80
PASS: hpa api-front 存在且 scaleTargetRef 指向 api-front
PASS: scaleTargetRef.kind 为 Deployment
PASS: minReplicas 为 2
PASS: maxReplicas 为 6
PASS: CPU target averageUtilization 为 50
PASS: 指标资源名为 cpu
PASS: HPA ScalingActive 条件为 True（metrics-server 正常）

SCORE: 12/12
```

## 考点回顾

- HPA 不会把副本数改写成超出 min/max 的值；手动 `scale` 到范围外后，下一次同步会被 HPA 拉回来。
- `kubectl top pods` 与 HPA 用的是同一个 metrics API（`metrics.k8s.io`），两者一起排障。
- HPA 只能改副本数；Pod 内的垂直资源调整要 VPA，超出本考试范围但面试常问。
