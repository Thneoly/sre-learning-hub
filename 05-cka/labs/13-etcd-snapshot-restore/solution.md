# Lab 13 · 解答：etcd 快照与模拟恢复

## 背景：为什么是 etcdctl snapshot

etcd 是集群唯一的有状态组件——所有 Pod/Service/Secret 的期望状态都存在里面。kubeadm 把 etcd 作为 static Pod 跑在 master 上（`/etc/kubernetes/manifests/etcd.yaml`），数据目录默认 `/var/lib/etcd`。备份 etcd 等于备份整个集群的逻辑状态。

```
API Server ──写──> etcd(2379 client / 2380 peer, 全部 TLS)
                        │
      snapshot save <───┘  读一致性视图 -> 单文件 .db
      snapshot restore ──> 本地展开成新 data-dir(不连网)
```

## 第 1 步：确认 etcdctl 可用

```bash
# [master]
etcdctl version 2>/dev/null || sudo apt-get update && sudo apt-get install -y etcd-client
```

Ubuntu 22.04 的 `etcd-client` 是 3.3 版，`ETCDCTL_API=3` 下 save/restore/status 命令齐全，够用；考场上如果 `etcdctl` 不在 PATH，也可以从 etcd 的 static Pod 容器里借：

```bash
# [master] 备选: 借用 etcd Pod 里的 etcdctl
ETCDPOD=$(sudo crictl ps --name etcd -q | head -1)
sudo crictl exec "$ETCDPOD" etcdctl version
```

## 第 2 步：健康检查 + snapshot save

先确认 endpoint 健康（证书参数一次配好，后面复用）：

```bash
# [master]
sudo mkdir -p /var/lib/etcd-snapshot
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health
```

预期输出：

```
https://127.0.0.1:2379 is healthy: successfully committed proposal: took = 10ms
```

执行快照：

```bash
# [master]
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd-snapshot/lab13.db
```

预期输出最后两行：

```
Snapshot saved at /var/lib/etcd-snapshot/lab13.db
{"level":"info","msg":"fetching snapshot","took":"..."}
```

## 第 3 步：snapshot status 校验

```bash
# [master]
sudo ETCDCTL_API=3 etcdctl snapshot status /var/lib/etcd-snapshot/lab13.db --write-out=table
```

预期输出（数值随集群状态不同）：

```
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| 0x3f2... |     1024 |       1234 |     3.4 MB |
+----------+----------+------------+------------+
```

- HASH：内容校验值，恢复时会重算比对。
- TOTAL KEYS：集群对象数（含系统 key）。
- 文件损坏/为空时该命令直接报错，这是巡检脚本判断快照可用的标准手段。

## 第 4 步：模拟恢复到临时目录

```bash
# [master]
sudo ETCDCTL_API=3 etcdctl snapshot restore \
  /var/lib/etcd-snapshot/lab13.db \
  --data-dir /tmp/lab13-restore
```

预期输出若干 `"level":"info"` 日志，提到 creating directories 与 restoring snapshot。

验证产物结构：

```bash
# [master]
sudo find /tmp/lab13-restore -maxdepth 3 -type d
```

预期关键目录：

```
/tmp/lab13-restore
/tmp/lab13-restore/member
/tmp/lab13-restore/member/snap
/tmp/lab13-restore/member/wal
```

`snap/db` 是压缩后的状态机数据，`wal/` 是预写日志。最后确认集群无恙：

```bash
# [master]
kubectl get nodes
```

节点仍为 `Ready`——因为我们没有碰 `/var/lib/etcd`，也没有动 etcd static Pod。

## 第 5 步：两个问题的答案

**Q1：为什么 restore 必须指定新的 `--data-dir`？**
`snapshot restore` 是纯本地操作：把快照展开成一套**新的** member 数据目录（生成新的 cluster/wal 元数据）。如果指向已有数据的目录，旧 WAL 与恢复出的状态机会不一致，etcd 起来要么拒绝要么数据错乱。所以流程永远是"恢复到新目录，再把 etcd 指过去"，而不是原地覆盖。

**Q2：真实恢复还要做什么（本 lab 不执行）？**
kubeadm 集群标准流程（单 master etcd）：

```bash
# [master] 仅供参考, 本 lab 不要执行
sudo mv /etc/kubernetes/manifests/etcd.yaml /tmp/          # 停 etcd static Pod
sudo mv /var/lib/etcd /var/lib/etcd.bak
sudo ETCDCTL_API=3 etcdctl snapshot restore /var/lib/etcd-snapshot/lab13.db --data-dir /var/lib/etcd
sudo mv /tmp/etcd.yaml /etc/kubernetes/manifests/          # kubelet 拉起 etcd
# 随后逐个重启 control plane static Pod(apiserver/controller/scheduler),或直接:
sudo systemctl restart kubelet
```

关键认知：静态 Pod 的生命周期由 kubelet 管理，把 manifest 挪出 `/etc/kubernetes/manifests` 就是"停服务"，挪回来就是"起服务"。

## 常见错误回顾

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| `connection refused` | endpoint 写成了 2380（peer 口）或没加 https | client 口是 2379，且必须 `https://127.0.0.1:2379` |
| `context deadline exceeded` | 证书路径错/没加 cacert | 核对 `/etc/kubernetes/pki/etcd/` 三个文件 |
| snapshot save 报 `permission denied` | 普通用户读不了 pki 私钥 | 命令前加 `sudo` |
| restore 报 `data-dir "..." not empty` | 目录里有旧产物 | 换空目录或 `rm -rf` 后重来 |
| snapshot status 报 `snapshot file is empty` | save 时 etcd 不可达但文件被创建 | 先 `endpoint health` 再 save |

## 延伸阅读

- https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#backing-up-an-etcd-cluster
- https://etcd.io/docs/v3.5/op-guide/recovery/

## check.sh 运行结果

```bash
# [master]
chmod 755 check.sh && sudo ./check.sh
```

预期：

```
PASS: 当前节点是 master(存在 /etc/kubernetes/pki/etcd)
PASS: 快照文件 /var/lib/etcd-snapshot/lab13.db 存在
PASS: 快照大小 3481600 字节(>1MB, 非空文件)
PASS: etcdctl snapshot status 可正常解析快照
PASS: 恢复产物 /tmp/lab13-restore/member/snap/db 存在
PASS: 恢复的 member/snap/db 大小 2588672 字节(>0)
PASS: 集群 API 正常(演练未破坏现有 etcd)

SCORE: 7/7
```
