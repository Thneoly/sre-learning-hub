# Lab 01 · Deployment 滚动发布与回滚

> 难度：★☆☆ ｜ 考点：CKA-应用发布（Deployment / rollout） ｜ 前置：无 ｜ 预计 20~30 分钟

## 场景

你是公司官网的值班运维。团队今天要上线一版新的首页 `nginx:1.29`，流程如下：

1. 先按当前稳定版本 `nginx:1.27` 建立 Deployment 作为发布基线；
2. 滚动升级到 `nginx:1.29`；
3. 升级完成后监控发现新版有兼容性问题，需要立即回滚到上一个版本；
4. 回滚稳定后，为应对晚高峰把副本扩到 6 个。

要求整个过程中服务不中断（滚动更新，不能 `kubectl delete` 重建 Deployment）。

## 任务清单

1. 创建 namespace `lab01-rollout`。
2. 在该 namespace 创建 Deployment，要求：
   - 名称 `web-app`，labels `app=web-app`
   - 容器名 `nginx`（注意：kubectl create deployment 用镜像名作容器名，不是 Deployment 名——这是常见坑），镜像 `nginx:1.27`，containerPort `80`
   - 副本数 `3`
   - 创建时带 change-cause 注解（`--record` 或 `kubernetes.io/change-cause`），内容 `init deploy`
3. 确认 3 个副本 Ready 后，把镜像滚动升级为 `nginx:1.29`，change-cause 写 `upgrade to 1.29`。
4. 用 `kubectl rollout status` 确认升级完成后，回滚到上一个 revision（change-cause 写 `rollback to previous`）。
5. 确认镜像已回到 `nginx:1.27`（此时仍为 3 副本）；随后扩容到 `6` 副本并等待全部 Ready。

## 验收标准

终态（`kubectl -n lab01-rollout` 观察）：

- `get deploy web-app`：READY `6/6`，UP-TO-DATE `6`
- `get deploy web-app -o jsonpath='{.spec.template.spec.containers[0].image}'` 输出 `nginx:1.27`
- `kubectl rollout history deployment/web-app -n lab01-rollout` 至少能看到 revision 1/2/3 三条记录
- `kubectl rollout status deployment/web-app -n lab01-rollout` 输出 `successfully rolled out`
- 升级/回滚过程中 `kubectl get pods -w` 能看到新旧 Pod 交错创建删除（RollingUpdate 默认策略 maxSurge 25%、maxUnavailable 25%）

运行判分脚本（在 master 节点，`check.sh` 与 kubectl 同机）：

```bash
# [master]
cd 05-cka/labs/01-deploy-rollout
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：带 change-cause 的创建方式</summary>

```bash
# [master]
kubectl create deployment web-app --image=nginx:1.27 --replicas=3 -n lab01-rollout
kubectl -n lab01-rollout annotate deployment web-app kubernetes.io/change-cause='init deploy'
```
`--record` 已 deprecated（v1.27 起不再写 `kubernetes.io/change-cause` 以外的字段），用 `kubectl annotate` 或 `kubectl apply --record=false` 后手动补注解更可靠。
</details>

<details><summary>提示 2：升级与回滚</summary>

```bash
# [master]
kubectl -n lab01-rollout set image deployment/web-app nginx=nginx:1.29
kubectl -n lab01-rollout annotate deployment web-app kubernetes.io/change-cause='upgrade to 1.29' --overwrite
kubectl -n lab01-rollout rollout status deployment/web-app

kubectl -n lab01-rollout rollout undo deployment/web-app
kubectl -n lab01-rollout annotate deployment web-app kubernetes.io/change-cause='rollback to previous' --overwrite
```
`rollout undo` 默认回退到 revision N-1；`rollout undo --to-revision=1` 可指定具体版本。回滚本身也会生成一个新的 revision 号。
</details>

<details><summary>提示 3：扩容</summary>

```bash
# [master]
kubectl -n lab01-rollout scale deployment/web-app --replicas=6
```
注意：`scale` 只改 `spec.replicas`，不会增加新的 revision。
</details>
