# Lab 09 · Sidecar 容器接管日志输出

> 难度：★★☆ ｜ 考点：CKA-可观测/多容器（emptyDir + sidecar 日志代理） ｜ 前置：lab 01 ｜ 预计 25~35 分钟

## 场景

工单系统的网关 `ticket-app` 是个"老派"应用：日志不打印到 stdout，而是追加写 `/var/log/ticket/events.log` 文件。平台的日志采集（fluent-bit / kubectl logs）只认容器 stdout/stderr。

改造方案（不动应用代码）：在同一个 Pod 里加一个 sidecar 容器 `log-shipper`，通过共享卷读取该日志文件并转发到自己的 stdout，让平台的日志链路重新可用：

- Pod 内两个容器：`ticket-app`（业务）与 `log-shipper`（日志代理）；
- 共享卷：emptyDir，名 `ticket-logs`，两边都挂在 `/var/log/ticket`；
- `ticket-app`：busybox:1.36，每 5 秒向 `/var/log/ticket/events.log` 追加一行 `TICKET <时间戳> event received`；
- `log-shipper`：busybox:1.36，`tail -n+1 -f` 该文件，把内容持续输出到 stdout；
- 最终效果：`kubectl logs <pod> -c log-shipper` 能看到 TICKET 行源源不断，而 `kubectl logs <pod> -c ticket-app` 是空的——日志职责完整移交给 sidecar。

## 任务清单

1. 创建 namespace `lab09-sidecar`。
2. 创建 Deployment `ticket-app`：1 副本，labels `app=ticket-app`，按上述规格写两个容器和共享 emptyDir。
3. 验证：
   - 两个容器均 Running（READY 2/2）；
   - `kubectl exec <pod> -c ticket-app -- tail -3 /var/log/ticket/events.log` 能看到文件确实在被写；
   - `kubectl logs <pod> -c log-shipper --tail=3` 能看到同样的 TICKET 行；
   - `kubectl logs <pod> -c ticket-app` 无 TICKET 输出。

## 验收标准

- `kubectl -n lab09-sidecar get pods` 显示 READY `2/2`
- sidecar 的 stdout 有持续增长的 `TICKET ...` 行，主容器 stdout 没有
- 日志文件路径 `/var/log/ticket/events.log` 仅存在于共享卷上（emptyDir 生命周期与 Pod 一致）

运行判分脚本：

```bash
# [master]
cd 05-cka/labs/09-sidecar-logging
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：emptyDir 与容器共享</summary>

emptyDir 在 Pod 调度到节点时创建，Pod 内所有容器可挂同一个卷的不同或相同 mountPath。它随 Pod 删除而消失，不适合持久化，但天然适合"一个容器写、另一个容器读"的进程间交换。
</details>

<details><summary>提示 2：tail 的用法</summary>

`tail -n+1 -f /path` 表示"从头开始输出全部内容并持续 follow"。busybox 自带 tail，支持这两个参数。容器入口要写成 `["sh","-c","tail -n+1 -f /var/log/ticket/events.log"]` 才能通过 shell 展开。
</details>

<details><summary>提示 3：为什么 kubectl logs 默认只能看到一个容器</summary>

多容器 Pod 的 stdout/stderr 是按容器分桶落盘的（/var/log/pods/<ns>_<pod>_<uid>/<container>/），`kubectl logs` 默认取第一个容器，必须 `-c` 指定。这也是平台要求"日志进 stdout"的原因——kubelet 只自动回收 stdout/stderr 日志。
</details>
