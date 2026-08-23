# Lab 06 · 静态 PV 与 PVC 手工绑定

> 难度：★★☆ ｜ 考点：CKA-存储（PV/PVC 静态供给） ｜ 前置：无 ｜ 预计 25~35 分钟

## 场景

测试环境没有共享存储，团队决定用节点本地目录给内部文件服务 `file-server` 提供一块"静态卷"：

- 节点目录 `/mnt/lab06/data`（单 master 集群，hostPath 即可）；
- 卷容量标称 `1Gi`，访问模式 `ReadWriteOnce`，回收策略 `Retain`；
- 该卷**不走任何 StorageClass 动态供给**，由管理员手工创建 PV `pv-data-001`，再由开发用 PVC `data-claim` 去绑定；
- Pod `file-server`（nginx:1.27）把该 PVC 挂到 `/usr/share/nginx/html`，并把首页改写为 `hello from pv-data-001`，证明写入落在 PV 上。

集群已装有 local-path StorageClass 且可能被设为默认——所以静态绑定的 YAML 必须显式绕开默认 SC。

## 任务清单

1. 创建 namespace `lab06-static-pv`。
2. 创建 PV `pv-data-001`：
   - capacity 1Gi、accessModes [ReadWriteOnce]、persistentVolumeReclaimPolicy Retain
   - hostPath `/mnt/lab06/data`（type `DirectoryOrCreate`）
   - `storageClassName: ""`（空字符串，禁止默认 SC 介入）
3. 创建 PVC `data-claim`：请求 1Gi、RWO，同样 `storageClassName: ""`。
4. 创建 Pod `file-server`（nginx:1.27），把 PVC 挂载到 `/usr/share/nginx/html`。
5. 验证：PVC Bound 到 `pv-data-001`；`kubectl exec` 写入首页文件后，在节点 `/mnt/lab06/data` 下能看到同名文件。

## 验收标准

- `kubectl get pv pv-data-001`：STATUS `Bound`，CAPACITY `1Gi`，CLAIM 指向 `lab06-static-pv/data-claim`，RECLAIM POLICY `Retain`
- `kubectl -n lab06-static-pv get pvc data-claim`：STATUS `Bound`，VOLUME 列 `pv-data-001`
- 节点上 `ls /mnt/lab06/data` 出现 Pod 内写入的文件

运行判分脚本：

```bash
# [master]
cd 05-cka/labs/06-pvc-static-binding
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：为什么 storageClassName 要写空字符串</summary>

PVC 不写 `storageClassName` 时会默认使用集群默认 SC 发起动态供给；写 `storageClassName: ""` 是显式声明"我要静态绑定，别找 provisioner"。PV 侧同理——PV 的 SC 名必须和 PVC 的完全一致（同为空）才允许匹配。
</details>

<details><summary>提示 2：绑定的匹配条件有哪些</summary>

PVC 与 PV 能否绑定看四件事：容量（PVC request ≤ PV capacity）、accessModes 交集、storageClassName 相等、以及 PV 处于 Available 状态。任何一项不满足就 `Pending`。
</details>

<details><summary>提示 3：hostPath type 用哪个</summary>

`DirectoryOrCreate`：目录不存在则由 kubelet 创建（父目录需存在）；`Directory` 要求必须已存在，否则 Pod 起不来。练习环境用前者省事。
</details>
