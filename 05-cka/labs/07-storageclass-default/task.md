# Lab 07 · 默认 StorageClass 与延迟绑定

> 难度：★★★ ｜ 考点：CKA-存储（StorageClass/默认 SC/绑定模式） ｜ 前置：lab 06 ｜ 预计 30~40 分钟

## 场景

集群当前的默认 SC 是 local-path（scripts/setup 安装）。存储组要推行一套新的"手工本地卷"规范，在不动 local-path 的前提下做一次切换演练：

- 新建 StorageClass `manual-local`：provisioner `kubernetes.io/no-provisioner`（不自动造 PV），`volumeBindingMode: WaitForFirstConsumer`；
- 把 `manual-local` 设为**唯一**的默认 SC（local-path 若带默认注解需摘掉）；
- 预置一块 5Gi 的 PV `pv-fast-001`（hostPath `/mnt/lab07/fast`，SC 名必须是 `manual-local`，回收策略 Retain）；
- 开发随后在 `lab07-default-sc` namespace 创建一个**不指定** storageClassName 的 PVC `pvc-fast`（2Gi，RWO），由 Pod `cache-node`（nginx:1.27）挂载到 `/usr/share/nginx/html`；
- 验收关注两点：PVC 是否自动落到默认 SC `manual-local`；`WaitForFirstConsumer` 下 PVC 是否等到 Pod 出现才完成与 PV 的绑定。

## 任务清单

1. 创建 namespace `lab07-default-sc`。
2. 创建 SC `manual-local`（如上规格）。
3. 调整默认 SC：确保 `manual-local` 带 `storageclass.kubernetes.io/is-default-class: "true"`，且集群中**只有一个**默认 SC。
4. 创建 PV `pv-fast-001`（5Gi，RWO，Retain，hostPath `/mnt/lab07/fast` type DirectoryOrCreate，storageClassName `manual-local`）。
5. 创建 PVC `pvc-fast`：2Gi、RWO、**不写** storageClassName 字段。观察它此时是否 Pending（答案应是 Pending，且 `describe` 里 volumeName 为空——这就是 WFFC）。
6. 创建 Pod `cache-node` 挂载 PVC，等待 PVC 变 Bound、Pod Running。

## 验收标准

- `kubectl get sc manual-local` 带默认注解；`kubectl get sc` 全表只有 `manual-local` 带 `(default)` 标记
- 创建 Pod 之前：`kubectl -n lab07-default-sc get pvc pvc-fast` 为 `Pending`
- 创建 Pod 之后：`pvc-fast` 为 `Bound`，VOLUME 列 `pv-fast-001`，且 `spec.storageClassName` 解析为 `manual-local`
- Pod `cache-node` Running

运行判分脚本：

```bash
# [master]
cd 05-cka/labs/07-storageclass-default
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：设置/取消默认 SC 的注解</summary>

```bash
# [master]
kubectl annotate sc manual-local storageclass.kubernetes.io/is-default-class=true --overwrite
kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class- 2>/dev/null
```
注解末尾加 `-` 表示删除该注解。老注解 `storageclass.beta.kubernetes.io/is-default-class` 已废弃，统一用前者。
</details>

<details><summary>提示 2：为什么 PVC 创建时不绑定</summary>

`volumeBindingMode: WaitForFirstConsumer` 告诉 controller：先别替 PVC 挑 PV，等第一个使用它的 Pod 被调度后，再在 Pod 所在节点可用的 PV 里挑。目的是避免"PVC 绑到了 A 节点的卷，Pod 却只能调度到 B 节点"的死锁。
</details>

<details><summary>提示 3：两个 SC 同名 provisioner 会冲突吗</summary>

本 lab 的 `kubernetes.io/no-provisioner` 只是个标记（表示该 SC 永不动态供给），不会真的去调 provisioner，PV 与 SC 的匹配靠的是 `storageClassName` 字符串相等。所以 `pvc-fast` 只会绑 `manual-local` 名下的 PV。
</details>
