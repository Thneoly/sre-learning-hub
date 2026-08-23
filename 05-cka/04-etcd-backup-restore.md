# 04 · etcd 备份与恢复实操

> 模块：05-cka ｜ 建议时长：2.5 小时 ｜ 关联认证：CKA-Cluster Architecture（"implement etcd backup and restore" 是明列考点）

## 学习目标

- 能用完整 TLS 参数组合执行 `etcdctl snapshot save`，并说出每个参数取值的依据
- 能完成"恢复到新目录 → 改静态 Pod dataDir → 集群读回旧数据"的全流程
- 能用 `snapshot status`、`endpoint health`、`member list`、`get --prefix` 四种方式验证备份与恢复
- 能应对考题变体：换 etcd 版本、etcdctl 不在本机、多 control plane 集群

## 1. 前置：认识考场的 etcd

kubeadm 集群的 etcd 是**静态 Pod**（stacked etcd），跑在 master 上：

```bash
# [master] 确认 etcd Pod 与镜像版本
kubectl -n kube-system get pod -o wide | grep etcd
kubectl -n kube-system get pod etcd-master -o jsonpath='{.spec.containers[0].image}'; echo

# [master] 静态 Pod 清单：一切参数都在这里
sudo grep -e --data-dir -e --cert-file -e --listen-client-urls /etc/kubernetes/manifests/etcd.yaml
```

关键路径（kubeadm 默认，考场直接用）：

| 路径 | 内容 |
| --- | --- |
| `/var/lib/etcd` | etcd 数据目录（`--data-dir`） |
| `/etc/kubernetes/pki/etcd/ca.crt` | etcd 自己的 CA |
| `/etc/kubernetes/pki/etcd/server.crt` / `server.key` | etcd 服务端证书，兼作本机 client 证书（kubeadm 生成的这对证书带 client auth 用途，SAN 含 localhost） |
| `/etc/kubernetes/pki/etcd/apiserver-etcd-client.crt` / `.key` | apiserver 连 etcd 的客户端证书 |
| `/etc/kubernetes/manifests/etcd.yaml` | etcd 静态 Pod 定义（恢复时必改） |

etcdctl 的来源三选一：

```bash
# [master] 方式 1：本机已安装（apt 包 etcd-client；多数考场如此）
etcdctl version

# [master] 方式 2：直接借 etcd Pod 里的二进制（本机没有 etcdctl 时）
kubectl -n kube-system exec etcd-master -- etcdctl version

# [master] 方式 3：apt 安装（仅练习环境，考场装包受限时用方式 2）
sudo apt-get install -y etcd-client
```

## 2. snapshot save：全参数解析

### 2.1 完整命令

```bash
# [master] 建备份目录并执行快照
sudo mkdir -p /opt/etcd-backup

sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/etcd-backup/etcd-snapshot-$(date +%Y%m%d-%H%M).db
```

参数逐个说清：

| 参数 | 作用 | 取值依据 |
| --- | --- | --- |
| `ETCDCTL_API=3` | 强制 etcdctl 走 v3 API | 显式设置永远正确；旧版本 etcdctl 不设会落到 v2，`snapshot` 子命令直接不存在 |
| `--endpoints` | etcd 客户端端口 | 单机 stacked etcd 固定 `https://127.0.0.1:2379`，与 etcd.yaml 的 `--listen-client-urls` 一致 |
| `--cacert` | 校验 etcd 服务端证书的 CA | `/etc/kubernetes/pki/etcd/ca.crt`（etcd 专用 CA，不是集群根 CA） |
| `--cert` / `--key` | 客户端证书与私钥 | 本机操作可用 `server.crt`/`server.key`；语义更规范的是 `apiserver-etcd-client.crt`/`.key`，两者考场都接受 |
| `snapshot save <file>` | 写快照到文件 | 题目指定路径就照抄，常见 `/opt/...`（目录要先存在） |

建议开场就把长参数做成 alias（考场可写进 `~/.bashrc`）：

```bash
# [master] 一劳永逸的 alias
cat >> ~/.bashrc <<'EOF'
alias ectl='etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key'
EOF
source ~/.bashrc
# 之后：ETCDCTL_API=3 ectl endpoint health
```

### 2.2 通过 exec 执行（etcdctl 不在本机时的变体）

```bash
# [master] 在 Pod 内做快照，再拷出来
kubectl -n kube-system exec etcd-master -- sh -c \
  "ETCDCTL_API=3 etcdctl \
     --endpoints=https://127.0.0.1:2379 \
     --cacert=/etc/kubernetes/pki/etcd/ca.crt \
     --cert=/etc/kubernetes/pki/etcd/server.crt \
     --key=/etc/kubernetes/pki/etcd/server.key \
     snapshot save /tmp/etcd-snapshot.db"

kubectl -n kube-system cp etcd-master:/tmp/etcd-snapshot.db /opt/etcd-backup/etcd-snapshot.db
```

静态 Pod 的 manifest 以 hostPath 挂载了 `/etc/kubernetes/pki/etcd`，Pod 内路径与宿主机一致，参数不用改。

### 2.3 备份三连验证

```bash
# [master] 1. 文件存在且非空（正常几十 MB 起）
sudo ls -lh /opt/etcd-backup/

# [master] 2. 快照元数据可读（status 只需要文件，不需要连 etcd）
sudo ETCDCTL_API=3 etcdctl snapshot status /opt/etcd-backup/etcd-snapshot-*.db --write-out=table
# 输出列：HASH（校验值）/ REVISION / TOTAL KEYS / TOTAL SIZE
# TOTAL KEYS 为 0 或文件只有几 KB = 快照是坏的

# [master] 3. etcd 活着且可读
ETCDCTL_API=3 ectl endpoint health
# 输出 https://127.0.0.1:2379 is healthy
ETCDCTL_API=3 ectl member list --write-out=table
ETCDCTL_API=3 ectl get / --prefix --keys-only --limit=5
```

## 3. 恢复：snapshot restore 到新目录 + 改静态 Pod

考题标准题面："给定快照文件 `/var/lib/etcd-snapshot-previous.db`，把集群恢复到该快照状态。" 完整流程：

```
# [图] etcd 恢复流程（单 master、stacked etcd）
┌────────────────┐   ┌──────────────────────┐   ┌──────────────────────────┐
│ 1. 确认快照可用 │──►│ 2. restore 到新目录   │──►│ 3. 改 etcd.yaml 两处      │
│ snapshot status│   │ --data-dir=           │   │  --data-dir=/var/lib/... │
│                │   │ /var/lib/etcd-restore │   │  hostPath→同一路径        │
└────────────────┘   └──────────────────────┘   └──────────┬───────────────┘
                     kubelet 检测 manifest 变化 → 重建 etcd Pod
                                                          ▼
                                   ┌──────────────────────────────────┐
                                   │ 4. 验证：get nodes / 测试对象回归 │
                                   └──────────────────────────────────┘
```

### 3.1 第一步：restore 到新目录

```bash
# [master] 目标目录必须为空或不存在（restore 不覆盖已有数据）
sudo ls /var/lib/etcd-restore 2>/dev/null && sudo rm -rf /var/lib/etcd-restore

# [master] 从快照重建数据目录
sudo ETCDCTL_API=3 etcdctl \
  --data-dir=/var/lib/etcd-restore \
  snapshot restore /var/lib/etcd-snapshot-previous.db

# [master] 检查产物：member/snap 两个子目录
sudo ls -R /var/lib/etcd-restore | head
```

restore 只操作文件、不连任何 etcd——所以这一步**不需要** `--endpoints/--cacert` 那套参数。多成员集群如果需要改成员信息，另加 `--name/--initial-cluster/--initial-advertise-peer-urls`（见第 5 节变体）；单 master 默认值即可。

### 3.2 第二步：改静态 Pod 指向新目录

```bash
# [master] 编辑 etcd 静态 Pod（两处都指向新目录）
sudo vim /etc/kubernetes/manifests/etcd.yaml
```

要改的两处：

```yaml
# [master] /etc/kubernetes/manifests/etcd.yaml（节选，只列改动行）
spec:
  containers:
  - command:
    - etcd
    - --data-dir=/var/lib/etcd-restore        # 改动 1：command 里的 data-dir
    # ...其余参数不动...
    volumeMounts:
    - mountPath: /var/lib/etcd-restore        # 改动 2a：挂载点跟随（与 data-dir 同路径）
      name: etcd-data
  volumes:
  - hostPath:
      path: /var/lib/etcd-restore             # 改动 2b：hostPath 指向新目录
      type: DirectoryOrCreate
    name: etcd-data
```

保存即生效：kubelet 监视 manifests 目录，会自动用新定义重建 etcd Pod，无需手动 restart。

```bash
# [master] 等待重建完成
watch crictl ps --name etcd        # 新容器 Running、旧容器 Exited

# [master] apiserver 重连后验证
kubectl -n kube-system get pod | grep etcd
kubectl get nodes
```

### 3.3 第三步：验证恢复结果

```bash
# [master] 1. etcd 健康（此时读的是新目录）
ETCDCTL_API=3 ectl endpoint health

# [master] 2. 数据回到快照点：快照后创建的对象应消失，快照前的应在
kubectl get ns
kubectl get deploy,po,cm -A | head -20

# [master] 3. 写入也正常（恢复后不是只读）
kubectl create cm restore-check --from-literal=t=$(date +%s)
kubectl get cm restore-check -o yaml | grep t:

# [master] 4. （可选）留着旧目录保险，确认稳定后再删
sudo mv /var/lib/etcd /var/lib/etcd.bak.$(date +%s)
```

考场时间紧时，第 2 步验证选"题目里提到的那个对象"查一下即可，比如题面说"快照里应有 namespace `x`"，就 `kubectl get ns x`。

## 4. 常见考题变体

### 4.1 换 etcd 版本 / ETCDCTL_API 行为

题面可能给出 `ETCDCTL_API=3` 提示或让你自己判断。判据很简单：**任何时候显式带上 `ETCDCTL_API=3` 都不会错**；不带时旧版 etcdctl（匹配 etcd 3.3 及更早）默认走 v2 API，执行 `snapshot save` 会报子命令不存在。etcd 版本可以查证：

```bash
# [master] etcd 镜像版本（题面若说"etcd 版本为 3.5.x"，对应参数习惯不变）
kubectl -n kube-system get pod etcd-master -o jsonpath='{.spec.containers[0].image}'; echo
ETCDCTL_API=3 ectl version
```

### 4.2 etcdctl 不在 PATH

用 2.2 的 exec 方式在 Pod 内执行；恢复同理——但 restore 要写文件到宿主机目录时，exec 进 Pod 更麻烦（Pod 内挂的只有 `/etc/kubernetes/pki` 与 data 目录）。考场最省事的组合：**save 用 exec、restore 在宿主机**（若宿主机没有 etcdctl，可用 Pod 内挂载路径做 restore 目标后再调 hostPath——极少这么出题；标准考题都会保证宿主机有 etcdctl 或提供获取方式）。

### 4.3 多 control plane（stacked etcd 三节点）

多成员恢复的考点是"**只在其中一个成员上 restore，其余成员重新加入**"：

```bash
# [master] 1. 选定恢复节点，restore 时显式给出集群拓扑（成员名与 PeerURL 按实际改）
sudo ETCDCTL_API=3 etcdctl \
  --data-dir=/var/lib/etcd-restore \
  --name=master \
  --initial-cluster=master=https://172.30.30.21:2380,master2=https://172.30.30.22:2380,master3=https://172.30.30.23:2380 \
  --initial-advertise-peer-urls=https://172.30.30.21:2380 \
  snapshot restore /var/lib/etcd-snapshot-previous.db

# [master2/master3] 2. 其余成员：停掉 etcd（移走 manifest）、清空旧数据目录
sudo mv /etc/kubernetes/manifests/etcd.yaml /etc/kubernetes/etcd.yaml.bak
sudo rm -rf /var/lib/etcd/*

# 恢复节点先起（改 manifest 指向 /var/lib/etcd-restore），
# 其余成员再把 manifest 改回并用原参数加入（kubeadm 集群通常直接复用原 etcd.yaml，
# 指向各自清空后的 /var/lib/etcd，由恢复节点同步数据）
```

细节（token、learner 流程）以 etcd 官方 disaster recovery 文档为准，考场极少展开到这个深度；**单 master 恢复流程必须做到 5 分钟内无提示完成**，多 master 记住"单点恢复 + 其余成员重新加入"的原则即可。

### 4.4 其他常见小变体

| 变体 | 要点 |
| --- | --- |
| 快照路径在题目给定目录 | 先 `mkdir -p`；`snapshot save` 的路径照抄题面 |
| 恢复到"原路径" | 也走新目录流程更稳：restore 到 `/var/lib/etcd-restore` 后把原 `/var/lib/etcd` 移走，避免覆盖失败半途而废 |
| 题面给了 `--endpoints` 为其他 IP | 照抄题面；只要证书与 keys 匹配即可连上 |
| 恢复后 apiserver 起不来 | 多半 etcd.yaml 只改了一处（data-dir 与 hostPath 不一致），`crictl ps -a` 看 etcd 容器是否 CrashLoop，`crictl logs` 定位 |

## 5. 实战演练：在练习集群完整走一遍

目标：亲手验证"快照能救回数据"。

```bash
# [master] 1. 造一个"只能靠快照找回"的对象
kubectl create ns etcd-drill
kubectl -n etcd-drill create configmap precious --from-literal=data=before-snapshot

# [master] 2. 快照（2.1 完整命令）
sudo mkdir -p /opt/etcd-backup
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /opt/etcd-backup/drill.db

# [master] 3. 快照之后"误删"
kubectl delete ns etcd-drill --wait=false
kubectl get ns etcd-drill      # NotFound

# [master] 4. 恢复（第 3 节三步）
sudo ETCDCTL_API=3 etcdctl --data-dir=/var/lib/etcd-restore \
  snapshot restore /opt/etcd-backup/drill.db
sudo vim /etc/kubernetes/manifests/etcd.yaml        # 两处指向 /var/lib/etcd-restore

# [master] 5. 验证数据复活
kubectl -n etcd-drill get cm precious               # data=before-snapshot 回来了

# [master] 6. 收尾：恢复实验现场（把 manifest 指回 /var/lib/etcd，删临时目录）
sudo vim /etc/kubernetes/manifests/etcd.yaml        # 改回 /var/lib/etcd
sudo rm -rf /var/lib/etcd-restore
kubectl -n etcd-drill delete cm precious && kubectl delete ns etcd-drill
```

全程约 20 分钟。做完对这个流程的理解会超过背 10 遍命令：**etcd 恢复 = 文件级重建 + 让 etcd 进程改读新目录**，apiserver 只是被动地跟着重连。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| `snapshot save` 报 `snapshot: command not found` 之类 | 未设 `ETCDCTL_API=3`，etcdctl 落在 v2 API | 命令前显式加 `ETCDCTL_API=3` |
| `connect: connection refused` 到 2379 | endpoints 写错（写了 2380 peer 端口）或 etcd 未跑 | client 端口是 2379；`kubectl -n kube-system get pod | grep etcd` 确认 |
| `certificate is valid for ...` 报错 | `--cacert` 用了集群根 CA（`pki/ca.crt`）而非 etcd CA | 改用 `/etc/kubernetes/pki/etcd/ca.crt` |
| restore 报目标目录已存在数据 | `--data-dir` 指向了非空目录 | 目标目录必须为空或不存在，先 `rm -rf` 重建 |
| 恢复后数据没变 | 只改了 command 的 `--data-dir`，hostPath 还挂在 `/var/lib/etcd`；或反之 | etcd.yaml 两处（command + hostPath/mountPath）必须一起改 |
| 恢复后 apiserver CrashLoop | etcd 起了但 apiserver 等待超时窗口内没连上，或 etcd 证书参数被动过 | `crictl logs <etcd容器>`、`crictl logs <apiserver容器>` 分别看；确认 manifest 只改了 data-dir 相关行 |
| `snapshot status` 报文件损坏 | save 时中途 Ctrl+C / 磁盘满 | 重做一次 save；检查 `df -h` |
| 恢复完成忘了收尾，下次实验数据错乱 | 静态 Pod 还指着 restore 目录 | 演练结束把 manifest 指回并删临时目录（实战演练第 6 步） |

## 自测

1. `snapshot save` 需要全套 TLS 参数，`snapshot restore` 一个都不需要。为什么？

<details><summary>答案</summary>

save 是在线操作：etcdctl 作为客户端连到运行中的 etcd（2379），要走 mTLS 认证与加密，所以需要 endpoints + cacert + cert + key。restore 是离线文件操作：直接从快照文件重建一个数据目录，全程不接触任何 etcd 进程，自然不需要连接参数——它需要的是 `--data-dir` 与（多成员时）集群拓扑参数。
</details>

2. 恢复时 etcd.yaml 里的 `--data-dir` 改成了 `/var/lib/etcd-restore`，但 hostPath 仍指 `/var/lib/etcd`。会发生什么？

<details><summary>答案</summary>

etcd 容器把旧目录（hostPath `/var/lib/etcd`）挂到 `/var/lib/etcd-restore` 路径上，etcd 进程从"挂载进来的旧数据"启动——集群表现和没恢复一样，快照数据根本没被读到。这是最典型的"恢复不生效"错误，排查口诀：command 与 hostPath 两处必须指向同一路径。
</details>

3. 三个 control-plane 节点的 stacked etcd 集群要做灾难恢复，为什么不能在每个成员上都独立执行 `snapshot restore`？

<details><summary>答案</summary>

每个成员独立 restore 会得到三份 cluster ID / 成员 ID 各不相同的数据目录，成员间无法组成一个集群（raft 身份对不上）。正确做法是选一个成员 restore（restore 时给出完整 initial-cluster 拓扑），其余成员清空数据后作为成员重新加入，由恢复节点同步数据。
</details>

4. `snapshot status` 显示 TOTAL KEYS 为 0 但文件有 2MB。快照还能用吗？给出判断与验证方法。

<details><summary>答案</summary>

TOTAL KEYS 为 0 基本等于空快照（正常 kubeadm 集群几千到上万 key），不能用。验证：另做一次 save 并 status 对比（排除文件传输损坏）；确认 save 时连的是目标集群的 2379（endpoints 错连到别的 etcd 会导出别的数据）；`--cert/--key` 用错也可能连到了匿名实例。考场上 2MB 级的"小文件快照"要立刻重做，别赌。
</details>

5. 考题要求"把集群恢复到快照，且保留当前 `/var/lib/etcd` 的数据以便事后比对"。你的操作顺序应该怎么安排？

<details><summary>答案</summary>

restore 到新目录（不动原目录）→ 改 etcd.yaml 指向新目录 → 验证恢复效果 → 原目录原样保留（或改名 `mv /var/lib/etcd /var/lib/etcd.pre-restore` 以免混淆）。事后要切回时再把 manifest 指回原目录。核心原则：restore 是"加目录"而不是"覆盖目录"，保留回滚路径成本为零。
</details>

## 延伸阅读

- Kubernetes 官方 etcd 备份操作（考场可直接打开）：https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
- etcd 官方灾难恢复文档（多成员细节的权威出处）：https://etcd.io/docs/v3.5/op-guide/recovery/
- etcdctl 命令总览：https://etcd.io/docs/v3.5/dev-guide/interacting_v3/
- kubeadm 静态 Pod 说明：https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/ 与 https://kubernetes.io/docs/concepts/workloads/pods/#static-pods
- 本模块配套练习：labs 13-etcd-snapshot-restore、20-cluster-recovery-drill
