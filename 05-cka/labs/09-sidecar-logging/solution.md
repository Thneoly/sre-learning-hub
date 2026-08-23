# Lab 09 · 解答：Sidecar 容器接管日志输出

## 步骤 1：namespace 与双容器 Deployment

```bash
# [master]
kubectl create namespace lab09-sidecar
```

```yaml
# [master] cat > ticket-app.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ticket-app
  namespace: lab09-sidecar
  labels:
    app: ticket-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ticket-app
  template:
    metadata:
      labels:
        app: ticket-app
    spec:
      containers:
      - name: ticket-app
        image: busybox:1.36
        command: ["sh", "-c"]
        args:
        - while true; do
            echo "TICKET $(date '+%Y-%m-%dT%H:%M:%S') event received" >> /var/log/ticket/events.log;
            sleep 5;
          done
        volumeMounts:
        - name: ticket-logs
          mountPath: /var/log/ticket
      - name: log-shipper
        image: busybox:1.36
        command: ["sh", "-c", "tail -n+1 -f /var/log/ticket/events.log"]
        volumeMounts:
        - name: ticket-logs
          mountPath: /var/log/ticket
      volumes:
      - name: ticket-logs
        emptyDir: {}
EOF
kubectl apply -f ticket-app.yaml
```

设计要点：

- 业务容器只负责把日志追加到文件；sidecar 容器 `tail -f` 同一文件，把内容"搬运"到自己的 stdout；
- `date '+%Y-%m-%dT%H:%M:%S'`：busybox 的 date 支持 `+` 格式串，注意单引号在 heredoc 内不会被打散（heredoc 定界符加了引号 `'EOF'`，`$()` 原样进入容器）；
- 同一个 Pod 内容器共享 network namespace（可互相 localhost 通信）和 volumes（这里唯一交换通道）；文件挂载点两边一致，便于对照。

## 步骤 2：验证三层数据链路

链路图：

```text
ticket-app 容器                log-shipper 容器
   while+echo --写-->  emptyDir:/var/log/ticket/events.log  --tail -f 读-->  sidecar stdout
                                                                            |
                                                    kubelet 收集 stdout 落盘 v
                                             kubectl logs -c log-shipper / fluent-bit
```

第一层——文件确实在被写：

```bash
# [master]
POD=$(kubectl -n lab09-sidecar get pod -l app=ticket-app -o jsonpath='{.items[0].metadata.name}')
kubectl -n lab09-sidecar exec "$POD" -c ticket-app -- tail -3 /var/log/ticket/events.log
```

```text
TICKET 2026-08-22T10:11:35 event received
TICKET 2026-08-22T10:11:40 event received
TICKET 2026-08-22T10:11:45 event received
```

第二层——sidecar 的 stdout（平台真正采集的口）：

```bash
# [master]
kubectl -n lab09-sidecar logs "$POD" -c log-shipper --tail=3
```

```text
TICKET 2026-08-22T10:11:35 event received
TICKET 2026-08-22T10:11:40 event received
TICKET 2026-08-22T10:11:45 event received
```

第三层——主容器 stdout 保持干净：

```bash
# [master]
kubectl -n lab09-sidecar logs "$POD" -c ticket-app --tail=3
# 无输出（业务日志只走文件）
```

READY 列为 `2/2`，说明两个容器都活着：

```text
# [master]
$ kubectl -n lab09-sidecar get pods
NAME                          READY   STATUS    RESTARTS   AGE
ticket-app-7c6d9f8b5-x2m4q    2/2     Running   0          60s
```

## 步骤 3：体验 sidecar 的运维价值（可选）

sidecar 崩了业务不死、业务重启日志不丢——各容器独立重启：

```bash
# [master]
kubectl -n lab09-sidecar exec "$POD" -c log-shipper -- kill 1 2>/dev/null
sleep 8
kubectl -n lab09-sidecar get pod "$POD"
# RESTARTS 变为 1，READY 一度 1/2 后恢复 2/2
kubectl -n lab09-sidecar logs "$POD" -c log-shipper --tail=2
# tail 重启后从头读取（-n+1），历史 TICKET 行仍可见
```

清理实验环境时注意：emptyDir 随 Pod 删除即消失，别把它当持久化方案——这正是 lab 06/07 PVC 的适用场景。

## 步骤 4：运行判分脚本

```bash
# [master]
cd 05-cka/labs/09-sidecar-logging
chmod +x check.sh
./check.sh
```

通过结果：

```text
PASS: namespace lab09-sidecar 存在且 Active
PASS: deployment ticket-app 期望副本数为 1
PASS: deployment ticket-app readyReplicas 为 1
PASS: 容器为 ticket-app 与 log-shipper
PASS: pod ticket-app-7c6d9f8b5-x2m4q 为 Running
PASS: 两个容器均 ready
PASS: 卷名为 ticket-logs
PASS: 卷类型为 emptyDir
PASS: ticket-app 在写 /var/log/ticket/events.log（含 TICKET 行）
PASS: kubectl logs -c log-shipper 输出 TICKET 日志
PASS: ticket-app 的 stdout 无 TICKET 输出（职责已移交 sidecar）

SCORE: 11/11
```

## 常见坑速查

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| log-shipper CrashLoopBackOff | `tail -f` 的文件尚不存在，busybox tail 会立刻退出 | 业务容器先 `touch /var/log/ticket/events.log` 再进循环；或 sidecar 改成 `sh -c 'while [ ! -f ... ]; do sleep 1; done; tail -n+1 -f ...'`（本 lab 里 echo 追加建文件的速度通常够快，若偶发崩溃用此法加固） |
| READY 一直 0/2 | 命令引号嵌套错，容器入口没跑起来 | `kubectl logs`/`describe pod` 看具体报错；command/args 分开写易排查 |
| 两个容器各写各的 | 卷只挂了一个容器，或挂载 mountPath 不一致 | 检查两个 volumeMounts 指向同一卷名 |
| exec 进错容器 | 多容器 Pod 里 `kubectl exec` 默认第一个容器 | 加 `-c` 指定 |

## 考点回顾

- Pod 是"容器调度共享单位"：共享 network/IPC/UTS 与 volumes，但文件系统（rootfs）与 PID 默认隔离（shareProcessNamespace 可开 PID 共享，超纲了解即可）。
- kubelet 只轮转 stdout/stderr 日志（/var/log/pods 与 /var/log/containers 软链）；写文件的日志必须靠 sidecar 或节点级 agent 打捞。
- sidecar 模式的通用形态：日志代理、网络代理（service mesh 的 envoy）、配置热加载。K8s 1.28+ 还有原生 initContainers 的 sidecar 语义（restartPolicy: Always），考试以经典写法为准。
