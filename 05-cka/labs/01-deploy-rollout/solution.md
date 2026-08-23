# Lab 01 · 解答：Deployment 滚动发布与回滚

## 步骤 1：创建 namespace 与基线 Deployment

做什么：建立发布基线，稳定版镜像 + 3 副本。

```bash
# [master]
kubectl create namespace lab01-rollout
kubectl create deployment web-app \
  --image=nginx:1.27 \
  --replicas=3 \
  -n lab01-rollout
kubectl -n lab01-rollout annotate deployment web-app kubernetes.io/change-cause='init deploy'
```

为什么：用 `kubectl create deployment` 快速建出最小可用的 Deployment；change-cause 注解会出现在 `rollout history` 里，考场上方便确认 revision 对应的操作。

验证输出：

```text
# [master]
$ kubectl -n lab01-rollout get deploy web-app
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
web-app   3/3     3            3           20s
```

## 步骤 2：滚动升级到 nginx:1.29

做什么：只改镜像，控制器负责按 RollingUpdate 策略逐个替换 Pod。

```bash
# [master]
kubectl -n lab01-rollout set image deployment/web-app nginx=nginx:1.29
kubectl -n lab01-rollout annotate deployment web-app \
  kubernetes.io/change-cause='upgrade to 1.29' --overwrite
kubectl -n lab01-rollout rollout status deployment/web-app
```

预期输出最后一行：

```text
deployment "web-app" successfully rolled out
```

为什么：`set image` 修改 `spec.template`，template 任何字段变化都会触发一次 rollout；Deployment 会为每个 template 版本维护一个 ReplicaSet，旧 RS 缩到 0 但保留，这就是回滚能"秒级"完成的原因（只是改两个 RS 的副本数）。

另开窗口观察滚动过程：

```bash
# [master]
kubectl -n lab01-rollout get pods -w
```

会看到 `web-app-<new-rs>-xxxxx` 的新 Pod 逐渐创建、`web-app-<old-rs>-xxxxx` 的旧 Pod 逐渐删除，交错进行。

确认镜像已更新：

```bash
# [master]
kubectl -n lab01-rollout get deploy web-app -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# nginx:1.29
```

## 步骤 3：回滚到上一个版本

```bash
# [master]
kubectl -n lab01-rollout rollout undo deployment/web-app
kubectl -n lab01-rollout annotate deployment web-app \
  kubernetes.io/change-cause='rollback to previous' --overwrite
kubectl -n lab01-rollout rollout status deployment/web-app
```

为什么：`rollout undo` 不带参数就是回到 revision N-1。回滚会生成一个**新的 revision**（例如 1→2 升级、2 回滚生成 3），所以历史里 revision 号只增不减。

验证镜像已回退：

```bash
# [master]
kubectl -n lab01-rollout get deploy web-app -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
# nginx:1.27
```

查看历史（change-ause 一列对应每次操作）：

```bash
# [master]
kubectl -n lab01-rollout rollout history deployment/web-app
```

```text
deployment.apps/web-app
REVISION  CHANGE-CAUSE
1         init deploy
2         upgrade to 1.29
3         rollback to previous
```

## 步骤 4：扩容到 6 副本

```bash
# [master]
kubectl -n lab01-rollout scale deployment/web-app --replicas=6
kubectl -n lab01-rollout rollout status deployment/web-app
```

为什么：`scale` 只改 `spec.replicas`，不修改 template，因此不会产生新 revision，也不会触发滚动。

终态验证：

```bash
# [master]
kubectl -n lab01-rollout get deploy,pods
```

```text
NAME                      READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/web-app   6/6     6            6           5m

NAME                           READY   STATUS    RESTARTS   AGE
web-app-866c5d9f55-2q7vf       1/1     Running   0          5m
web-app-866c5d9f55-5k9bd       1/1     Running   0          5m
...
```

## 步骤 5：运行判分脚本

```bash
# [master]
cd 05-cka/labs/01-deploy-rollout
chmod +x check.sh
./check.sh
```

通过结果：

```text
PASS: namespace lab01-rollout 存在且 Active
PASS: deployment web-app 存在
PASS: 镜像为 nginx:1.27（已回滚）
PASS: spec.replicas 为 6
PASS: readyReplicas 为 6
PASS: revision >= 3（经历过升级与回滚，当前 3）
PASS: availableReplicas 为 6（rollout 已收敛）

SCORE: 7/7
```

## 考点回顾

- `set image` / `rollout status` / `rollout history` / `rollout undo` / `scale` 是 CKA 应用发布的一套组合拳，考题常要求"升级后回滚到指定 revision 并保持副本数"。
- 回滚的本质是模板版本的切换（RS 伸缩），不是重新拉镜像，所以很快；但如果旧 RS 被删（`revisionHistoryLimit` 太小或手动删除），就只能改 YAML 重发。
- `kubectl rollout restart` 会给 template 打一个 `kubectl.kubernetes.io/restartedAt` 注解强制滚动，常用于"只重启不动配置"的题目。
