# Lab 13 · etcd 快照与模拟恢复
> 难度：★★ ｜ 考点：CKA-集群运维（etcd backup/restore） ｜ 前置：kubeadm 集群已就绪 ｜ 预计 30 分钟
> 运行位置：需要 ssh 到 **master 节点**（etcd 以 static Pod 运行在 master 上，证书在 `/etc/kubernetes/pki/etcd/`）

## 场景

审计要求：所有 kubeadm 集群必须每夜做 etcd 快照，且恢复流程要演练过。你今天的任务是在 master 上完成两件事：

1. 用 `etcdctl snapshot save` 把集群当前状态备份到 **`/var/lib/etcd-snapshot/lab13.db`**（路径会被自动巡检，别改）。
2. 不破坏现有集群的前提下**演练恢复**：把快照恢复到临时目录 `/tmp/lab13-restore`，确认恢复产物结构完整。这一步绝不替换 `/var/lib/etcd`——生产上的真实恢复流程会替换它并重启 static Pod，但演练只到临时目录为止。

## 任务清单

1. 确认 `etcdctl` 可用；没有就装 `etcd-client`（Ubuntu 22.04/24.04 的 apt 包）。
2. 用 TLS 证书参数对本地 etcd 执行 `snapshot save`，输出文件必须是 `/var/lib/etcd-snapshot/lab13.db`。
3. 用 `etcdctl snapshot status` 检查快照（输出 total size / revision 等字段），确认快照有效。
4. 执行模拟恢复：`snapshot restore` 到 `--data-dir /tmp/lab13-restore`，并验证目录里出现了 `member/snap/db`。
5. 回答两个问题（写在你的笔记里，solution.md 有解释）：
   - 为什么 restore 必须指定新的 `--data-dir`，而不是原地恢复？
   - kubeadm 集群做真实恢复时，替换数据目录后还要做什么？（本 lab 不执行）

## 验收标准

- `/var/lib/etcd-snapshot/lab13.db` 存在且大小大于 0。
- `etcdctl snapshot status` 能解析该文件并输出统计信息（HASH、revision、total size）。
- `/tmp/lab13-restore/member/snap/db` 存在（模拟恢复产物），且现有集群未受影响（`kubectl get nodes` 正常）。

## 提示（卡住再看）

<details><summary>提示 1：etcdctl 的 TLS 参数</summary>

```bash
# [master]
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health
```

先跑 `endpoint health` 确认连通，再 `snapshot save`。证书路径是 kubeadm 的默认位置；`/var/lib/etcd-snapshot/` 目录需要先创建。读写系统目录记得 `sudo`。

</details>

<details><summary>提示 2：snapshot status 校验</summary>

```bash
# [master]
sudo ETCDCTL_API=3 etcdctl snapshot status /var/lib/etcd-snapshot/lab13.db --write-out=table
```

如果输出显示 HASH 或 total size，说明文件可用；对空/坏文件该命令会直接报错。

</details>

<details><summary>提示 3：restore 的本质</summary>

`snapshot restore` 不连任何 etcd——它在**本地**把快照文件展开成一套新的 data-dir（含 member/snap/db 与 WAL）。所以它不需要证书参数，但必须给一个空的 `--data-dir`，否则旧数据会和恢复产物冲突。

</details>
