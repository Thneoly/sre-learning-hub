# 13 · 集群管理与 etcd：kubeadm 产物、静态 Pod、升级与证书

> 模块：04-k8s-fundamentals ｜ 建议时长：3.5 小时 ｜ 关联认证：CKA-集群管理·etcd 备份恢复 / CKS-证书与集群加固

## 学习目标

- 能列出 kubeadm 部署后 master 上的全部产物（证书/kubeconfig/manifest/数据目录）并说出各自用途
- 能解释 etcd RAFT 写入路径与两种读路径（串行读/线性读）的区别，并独立完成 compact + defrag 空间回收
- 能解释静态 Pod"改 manifest 即生效"的机制与边界，并安全地修改控制面组件参数
- 能按版本偏差规则规划升级顺序，执行 kubeadm upgrade 全流程（控制面 + 工作节点）
- 能检查所有证书有效期并完成轮换（kubeadm certs check-expiration / renew / kubelet 自动轮换）

## 1. kubeadm 产物全景

`kubeadm init` 结束后，master 上多出来的东西一共四类：静态 Pod manifests、证书树、kubeconfig 文件、数据目录。排障前先有这张地图：

```
# [图] kubeadm 集群 master 文件全景
/etc/kubernetes/
├── manifests/                        ← 静态 Pod 目录(kubelet 监视, 改这里即生效)
│   ├── etcd.yaml
│   ├── kube-apiserver.yaml
│   ├── kube-controller-manager.yaml
│   └── kube-scheduler.yaml
├── pki/                              ← 证书树
│   ├── ca.crt / ca.key               ← 集群根 CA(10 年)
│   ├── apiserver.crt / apiserver.key
│   ├── apiserver-kubelet-client.crt / .key
│   ├── front-proxy-ca.crt / .key
│   ├── front-proxy-client.crt / .key
│   ├── sa.pub / sa.key               ← 签发 SA token 的密钥对(非证书)
│   └── etcd/                         ← etcd 用独立 CA
│       ├── ca.crt / ca.key
│       ├── server.crt / server.key
│       ├── peer.crt / peer.key
│       └── healthcheck-client.crt / .key
├── admin.conf               ← kubectl 管理员身份(system:masters)
├── kubelet.conf             ← kubelet 引导身份(之后切到轮换证书)
├── controller-manager.conf  ← 各组件的客户端 kubeconfig
└── scheduler.conf

/var/lib/kubelet/config.yaml          ← 本节点 kubelet 配置(含 staticPodPath)
/var/lib/kubelet/pki/                 ← kubelet 自己的证书(自动轮换)
/etc/systemd/system/kubelet.service.d/10-kubeadm.conf  ← kubelet systemd 参数
/var/lib/etcd/                        ← etcd 数据目录(默认)
```

### 1.1 证书清单与用途

| 证书 | 用途 | 签发者 | 默认有效期 |
| --- | --- | --- | --- |
| `ca.crt` | 集群信任锚：apiserver 服务端证书、各组件客户端证书都由它签 | 自签 | 10 年 |
| `apiserver.crt` | apiserver 服务端证书（6443），SAN 含节点 IP / 10.96.0.1 / kubernetes.default | ca | 1 年 |
| `apiserver-kubelet-client.crt` | apiserver 作为**客户端**连 kubelet:10250（exec/logs/probe 代理） | ca | 1 年 |
| `apiserver-etcd-client.crt` | apiserver 连 etcd:2379 的客户端证书 | etcd/ca | 1 年 |
| `etcd/server.crt` | etcd 对客户端提供服务（2379） | etcd/ca | 1 年 |
| `etcd/peer.crt` | etcd 成员间 RAFT 复制（2380，mTLS） | etcd/ca | 1 年 |
| `etcd/healthcheck-client.crt` | 健康检查客户端 | etcd/ca | 1 年 |
| `front-proxy-ca.crt` / `front-proxy-client.crt` | 聚合层代理认证：apiserver 用它向 metrics-server 等扩展 API 证明"我已认证过用户"（front-proxy 身份链，见第 14 章） | front-proxy-ca | 10 年 / 1 年 |
| `sa.key` / `sa.pub` | 签发 / 校验 ServiceAccount token | — | 非证书，无有效期 |
| `/var/lib/kubelet/pki/kubelet-client-current.pem` | kubelet → apiserver 的客户端身份，kubelet 自动轮换 | ca | 1 年（自动续） |

记忆法：**每条通信链路两份证书**——客户端证书证身份，服务端证书管加密防冒充；etcd 与 front-proxy 各有独立小 CA，互不连坐（第 02 章有完整认证链路图）。

### 1.2 配置文件位置速查

| 位置 | 内容 | 谁消费 |
| --- | --- | --- |
| `/etc/kubernetes/manifests/*.yaml` | 控制面组件启动参数的**唯一真身** | kubelet |
| ConfigMap `kube-system/kubeadm-config` | kubeadm 记录的集群配置（upgrade 时读） | kubeadm |
| ConfigMap `kube-system/kubelet-config` | 全集群 kubelet 基线配置 | kubeadm 下发到各节点 |
| `/var/lib/kubelet/config.yaml` | 本节点 kubelet 配置（staticPodPath、rotateCertificates 等） | kubelet |
| `/etc/systemd/system/kubelet.service.d/10-kubeadm.conf` | kubelet 启动参数（容器运行时端点等） | systemd |
| `/etc/containerd/config.toml` | 容器运行时配置 | containerd |

```bash
# [master] 找回 kubeadm 的集群配置(init 时的参数都在)
kubectl -n kube-system get cm kubeadm-config \
  -o jsonpath='{.data.ClusterConfiguration}' | grep -E 'kubernetesVersion|podSubnet|serviceSubnet'
# 预期: kubernetesVersion: v1.xx.x 等三行
```

## 2. etcd：读写路径、多数派与性能运维

第 02 章讲过多数派表，本章补读写路径与日常运维。

### 2.1 写路径与读路径

```
# [图] etcd 一次写(a=客户端, L=leader, F=follower, 3 成员为例)
 a ──PUT /registry/pods/default/x──► 任意成员
        │  非 leader 收到 → 转发给 leader
        ▼
 L ① 本地 WAL 追加(先落盘, 未提交)
        │ ② 并行 AppendEntries ──► F1、F2 各自落盘 WAL
        ▼ ③ 多数派(N/2+1=2, 含 L 自己)确认
 L ④ commit → apply 到 MVCC 存储(全局 revision +1)
        │ ⑤ 应答客户端; follower 随后 apply 追上
        ▼
 客户端拿到成功 = 该写已持久化到多数成员

 读路径两种:
   串行读(serializable): 直接读本成员 KV, 无需多数派确认 —— 快, 可能读到旧值
   线性读(linearizable, 默认): 先经 ReadIndex 与多数派确认"我还是 leader",
                              再返回 —— 强一致, 多一次往返
```

这就是"写走 leader、提交看多数派、读默认线性"的三句话。K8s 的 list-watch 大量依赖 etcd 的 watch 与 MVCC revision（即 resourceVersion，第 02 章 6.2 节）。

### 2.2 日常运维三件事：status、空间、性能

先给 etcdctl 做个包装（kubeadm 的 etcd 监听 127.0.0.1:2379，证书在 Pod 内）：

```bash
# [master] 定义包装函数(仅当前 shell 有效, 本章复用)
ectl() {
  kubectl -n kube-system exec etcd-"$(hostname)" -- sh -c \
    "ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key \
--endpoints=https://127.0.0.1:2379 $*"
}

ectl endpoint status -w table
# 预期: 一行成员, 含 DB SIZE / RAFT INDEX / IS LEADER 等列
ectl endpoint health
# 预期: ... is healthy: successfully committed proposal
ectl member list -w table
```

**空间回收**：etcd 的每次修改都产生新 revision（旧版本留给 watch 追赶），磁盘只增不减是常态。回收两步走，顺序不能反：

1. `compact`：指定一个 revision，之前的**历史版本**从此可删（不可逆，compact 之后客户端无法再读/订阅更老的 revision，会拿 410）；
2. `defrag`：把 compact 释放出的内部空洞真正归还给文件系统（在线操作，逐成员做）。

```bash
# [master] 压缩到当前 revision(保留现值, 历史全部可回收)
REV=$(ectl endpoint status -w json | grep -o '"revision":[0-9]*' | head -1 | grep -o '[0-9]*')
ectl compact "$REV"
# 预期: compacted revision xxx

# [master] 碎片整理(单成员集群一条命令; 多成员集群务必逐个 endpoint 做,
# 避免多个成员同时 defrag 造成集群抖动)
ectl defrag
# 预期: Finished defragmenting etcd member[...]

# [master] 复核 DB SIZE 是否下降
ectl endpoint status -w table
```

**性能与容量建议**：

| 建议 | 原因 |
| --- | --- |
| etcd 独占一块低延迟磁盘（SSD/NVMe），不与日志、容器镜像共用 | WAL fsync 延迟直接决定写吞吐；fsync 慢 = 整个集群慢 |
| 别存大 value / 用 etcd 当通用数据库 | 单 key 建议 <100KB 级；大对象序列化拖垮 apiserver 与 etcd 双方 |
| 关注 DB SIZE 与 alarm | backend 配额默认约 2GB，超限触发 `alarm NOSPACE`，etcd 转为只读 |
| 定期 `snapshot save` 备份 | 灾备唯一正解，详见 `05-cka/04-etcd-backup-restore.md` |
| 大历史版本场景配 auto-compaction | 由 etcd 静态 Pod 参数 `--auto-compaction-retention` 控制（看 manifest 确认当前值） |

```bash
# [master] 备份与查看快照(升级/维护前的标准动作)
ectl snapshot save /tmp/snap-$(date +%F).db
ectl snapshot status /tmp/snap-$(date +%F).db -w table
# 预期: HASH / REVISION / TOTAL KEYS / TOTAL SIZE

# [master] 若遇到 NOSPACE 只读: 先回收再解除告警
ectl alarm list
ectl alarm disarm
```

## 3. 静态 Pod：改 manifest 即生效

```
# [图] 普通 Pod 与静态 Pod 的控制回路对比
 普通 Pod: kubectl ──► apiserver/etcd ──watch──► kubelet ──► CRI 起容器
 静态 Pod: 本地文件 /etc/kubernetes/manifests/etcd.yaml
              └── kubelet 持续监视该目录 → 文件变化即创建/更新/删除对应容器
                  └── apiserver 里只留一个只读 mirror pod(可见性用)
```

机制要点：

- kubelet 监视 `staticPodPath`（kubeadm 默认 `/etc/kubernetes/manifests`），**目录内文件的新增/修改/删除直接映射为 Pod 的创建/更新/删除**，全程不经 apiserver 的写路径，也不需要重启 kubelet；
- 这是 kubeadm 让 apiserver"自己拉起自己"的鸡生蛋解法：控制面四组件都是静态 Pod；
- 由此推出三条边界：`kubectl edit` 改静态 Pod 的 mirror pod 会被 kubelet 覆盖回来（真正的 spec 在本地文件）；`kubectl delete` 删掉的只是 mirror pod，容器照跑（排障干扰项）；**删除静态 Pod 的唯一方式是把 manifest 文件移走**；
- manifest 写错（YAML 语法/非法字段）时 kubelet 拒绝加载且**不产生任何 apiserver 层面的事件**，只能看 kubelet 日志。

```bash
# [master] 步骤 1: 备份后给 kube-scheduler 加 --v=4(任选一个无害参数做实验)
sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml /tmp/
sudo vi /etc/kubernetes/manifests/kube-scheduler.yaml
# 在 command: 的参数列表末尾追加一行(注意缩进对齐既有条目):
#     - --v=4

# [master] 步骤 2: 保存后 10~30 秒内观察自动重建
kubectl -n kube-system get pod -l component=kube-scheduler -w
# 预期: 老 Pod Terminating → 新 Pod ContainerCreating → Running

# [master] 步骤 3: 确认新参数进了 mirror pod(即进了真实 spec)
kubectl -n kube-system get pod -l component=kube-scheduler \
  -o jsonpath='{.items[0].spec.containers[0].command}' | tr ',' '\n' | grep v=
# 预期: --v=4

# [master] 步骤 4: 恢复原状(把备份拷回去, 同样秒级生效)
sudo cp /tmp/kube-scheduler.yaml /etc/kubernetes/manifests/kube-scheduler.yaml
```

## 4. 升级：kubeadm upgrade 与版本偏差规则

### 4.1 版本偏差（Version Skew）现行规则

升级前先懂规则，否则"先升节点后升控制面"这类顺序错误会让集群进不支持状态。以下为撰写时的现行规则，**具体以官方 Version Skew Policy 页面为准**：

| 组件 | 与 kube-apiserver 的允许偏差 |
| --- | --- |
| kube-apiserver 自身（多实例 HA） | 实例之间最新与最旧相差 ≤ 1 个 minor |
| kubelet | **不得比 apiserver 新**；可以比它旧，最多 3 个 minor（n-3） |
| kube-controller-manager / kube-scheduler / cloud-controller-manager | 不得比 apiserver 新；可以旧，现行规则同样为 n-3（早期版本曾为 n-2，升级老集群时查官方页确认） |
| kubectl | 可以比 apiserver 新或旧 1 个 minor |

再加一条 kubeadm 的硬约束：**`kubeadm upgrade` 一次只能升一个 minor，不能跳级**（v1.30 → v1.32 必须经过 v1.31），也不支持降级回退。由此得出升级顺序铁律：**kubeadm → 控制面（apiserver 先于其他组件，kubeadm 自动处理）→ master 的 kubelet → 逐台 worker（drain → 升级 → uncordon）**，全程 kubelet 永不领先于 apiserver。

```
# [图] kubeadm 升级全流程(1 master + N worker)
 ① 备份: etcd snapshot + 检查证书
 ② master: apt 装 kubeadm 新版 → kubeadm upgrade plan(看可行性)
 ③ master: kubeadm upgrade apply v1.XX.x     ← 升级四个静态 Pod(不动 kubelet)
 ④ master: 装 kubelet/kubectl 新版 → daemon-reload → restart kubelet
 ⑤ 逐台 worker: drain → 装 kubeadm → kubeadm upgrade node
      → 装 kubelet 新版 → restart → uncordon
 ⑥ kubectl get nodes 逐台核对 VERSION
```

### 4.2 实操命令

```bash
# [master] 步骤 0: 升级前检查(版本号以 plan 输出为准, 勿照抄本文)
ectl() { kubectl -n kube-system exec etcd-"$(hostname)" -- sh -c \
  "ETCDCTL_API=3 etcdctl --cacert=/etc/kubernetes/pki/etcd/ca.crt \
--cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key \
--endpoints=https://127.0.0.1:2379 $*"; }
ectl snapshot save /tmp/pre-upgrade.db
sudo kubeadm certs check-expiration | head -8

# [master] 步骤 1: 升级 kubeadm 本体
sudo apt-mark unhold kubeadm kubelet kubectl 2>/dev/null
sudo apt-get update
sudo apt-get install -y kubeadm=1.31.4-1.1   # 版本号换成 plan 给出的目标
kubeadm version
kubeadm upgrade plan
# 预期: 显示当前版本、目标版本、组件升级表与"upgrade is feasible"

# [master] 步骤 2: 升级控制面(静态 Pod 逐个滚动重启)
sudo kubeadm upgrade apply v1.31.4
# 预期: 末尾 [upgrade/successful] SUCCESS! Your cluster was upgraded

# [master] 步骤 3: 升级本机 kubelet(此刻它仍是旧版, 合规: 旧 ≤ n-3)
sudo apt-get install -y kubelet=1.31.4-1.1 kubectl=1.31.4-1.1
sudo systemctl daemon-reload && sudo systemctl restart kubelet
```

```bash
# [master] 步骤 4: 逐台处理 worker(先驱逐)
kubectl drain worker1 --ignore-daemonsets --delete-emptydir-data
# 预期: node/worker1 cordoned + evicting pods

# [worker1] 步骤 5: 升级 worker
sudo apt-mark unhold kubeadm kubelet 2>/dev/null
sudo apt-get update && sudo apt-get install -y kubeadm=1.31.4-1.1
sudo kubeadm upgrade node          # 更新本机 kubelet 配置与证书(不动容器)
sudo apt-get install -y kubelet=1.31.4-1.1
sudo systemctl daemon-reload && sudo systemctl restart kubelet

# [master] 步骤 6: 放回节点并复核
kubectl uncordon worker1
kubectl get nodes -o wide
# 预期: 所有节点 VERSION 逐步变为 v1.31.4, STATUS Ready
sudo apt-mark hold kubeadm kubelet kubectl   # 防误升级(可选, 按团队习惯)
```

## 5. 证书查看与轮换

```bash
# [master] 1. 集中体检: 所有证书的到期表
sudo kubeadm certs check-expiration
# 输出列: CERTIFICATE / EXPIRES / RESIDUAL / CERTIFICATE AUTHORITY
# 末尾另列 CA 证书(10 年)与 kubelet 轮换证书状态

# [master] 2. 单张证书细看(主题/SAN/到期日)
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -subject -enddate
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text \
  | grep -A1 'Subject Alternative Name'

# [master] 3. 全部续期(用原 CA 重签, CA 与 sa.key 不动)
sudo kubeadm certs renew all
sudo kubeadm certs check-expiration | head -8   # 复核 RESIDUAL 回到 ~365d
```

**renew 之后必须重启控制面静态 Pod 才会加载新证书**（kubeadm 不会代劳）。单 master 实验集群逐个来：

```bash
# [master] 4. 逐个"移出-移回"manifest 触发静态 Pod 重启(每次约 30 秒)
cd /etc/kubernetes/manifests
for m in kube-apiserver kube-controller-manager kube-scheduler etcd; do
  sudo mv "$m.yaml" /tmp/ && sleep 30 && sudo mv "/tmp/$m.yaml" .
  echo "== $m restarted =="
done
kubectl -n kube-system get pods | grep -E 'apiserver|controller|scheduler|etcd'
# 预期: 四个控制面 Pod 全部 Running, AGE 归零
```

三个收尾细节：

- `~/.kube/config` 里嵌的是 admin 证书的**副本**，renew 后要重新拷：`sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config`；
- **kubelet 的客户端证书是自动轮换的**（`rotateCertificates: true`，产物即 `/var/lib/kubelet/pki/kubelet-client-current.pem` 软链），前提是 apiserver 可达；apiserver 长期挂掉时 kubelet 证书到期无人续，恢复后节点会反复 NotReady，重启 kubelet 即可重新触发轮换——这是经典考题场景；
- 若想延长默认 1 年有效期，需在 `kubeadm init` 时给证书指定自定义时长（`--certificate-key` 相关扩展配置），老集群更简单的办法是定时任务里跑 `kubeadm certs renew all`。

## 实战演练

在 master 上完成一次"产物盘点 + etcd 运维 + 静态 Pod 实验 + 证书体检"。

```bash
# [master] 1. 产物盘点: 文件与证书各就各位?
ls /etc/kubernetes/manifests
ls /etc/kubernetes/pki /etc/kubernetes/pki/etcd
sudo ls /var/lib/kubelet/pki/
kubectl -n kube-system get cm kubeadm-config \
  -o jsonpath='{.data.ClusterConfiguration}{.data.NodeRegistration}' | grep -E 'kubernetesVersion|name'

# [master] 2. etcd 三查(健康/成员/端点)
ectl endpoint health && ectl member list -w table && ectl endpoint status -w table
# 预期: healthy; 单成员 started; DB SIZE 通常 < 100MB(实验集群)

# [master] 3. 空间回收闭环: compact → defrag → 复核
REV=$(ectl endpoint status -w json | grep -o '"revision":[0-9]*' | head -1 | grep -o '[0-9]*')
ectl compact "$REV" && ectl defrag && ectl endpoint status -w table

# [master] 4. 静态 Pod 即改即生效(第 3 节的 --v=4 实验完整跑一遍后恢复)

# [master] 5. 证书体检
sudo kubeadm certs check-expiration
# 预期: 所有 RESIDUAL > 300d(新装集群); 出现红字 RESIDUAL < 30d 就该 renew
```

验证：每步"预期"即标准；升级全流程（4.2 节）建议在快照恢复的克隆集群上演练，`05-cka/labs/14-kubeadm-upgrade-drain/` 有完整 lab。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 所有组件同时失联，kubectl 报 `x509: certificate has expired` | kubeadm 叶子证书默认 1 年 | `kubeadm certs renew all` + 重启静态 Pod + 重拷 admin.conf |
| renew 后 kubectl 仍报证书过期 | kubeconfig 里是旧证书副本 | 重新拷 `/etc/kubernetes/admin.conf` 到 `~/.kube/config` |
| defrag 做完 DB SIZE 没变 | 只 compact 没 defrag，或顺序颠倒 | 先 compact 再 defrag，复核 endpoint status |
| etcd 只读，日志见 `alarm NOSPACE` | backend 配额(默认约 2GB)打满 | `alarm list` → compact + defrag → `alarm disarm` |
| 静态 Pod 改了 `kubectl edit` 又被改回 / 删了又出现 | mirror pod 是只读投影 | 改 `/etc/kubernetes/manifests/` 下的文件才是真修改 |
| manifest 改完 Pod 毫无反应 | YAML 语法错，kubelet 拒载且无事件 | `sudo journalctl -u kubelet -n 50 --no-pager | grep -i manifest` |
| 升级想从 v1.30 直升 v1.32 | kubeadm 不允许跳级 | 逐 minor 升级 |
| 先升 worker 的 kubelet 再升控制面 | 违反偏差规则(kubelet 不得比 apiserver 新) | 永远控制面先行 |
| apiserver 挂了一段时间后节点 NotReady 循环 | kubelet 客户端证书到期无法自动轮换 | apiserver 恢复后重启 kubelet 触发轮换 |

## 自测

1. 为什么 `defrag` 之前要先 `compact`？只执行 defrag 会发生什么？

<details><summary>答案</summary>

compact 负责声明"某 revision 之前的历史版本不再需要"，defrag 负责把这些已死版本占用的存储块归还给文件系统。只 defrag 不 compact，b+tree 后端里几乎没有可回收的空洞，DB SIZE 基本不变；只 compact 不 defrag，空间被标记释放但磁盘占用不下降。两者是"记账"与"还钱"的关系，顺序必须先记账后还钱。
</details>

2. 单成员 etcd（kubeadm 默认）里 RAFT 还有意义吗？此时"多数派"是多少？

<details><summary>答案</summary>

有意义。RAFT 在单成员下仍执行完整流程：写请求走 WAL 先落盘、quorum=1（自己确认即提交）、每个写依然获得全局单调 revision。失去的是容错（容忍 0 个成员故障）而非一致性保证。也正因 quorum=1，单成员 etcd 不存在"丢多数派"问题，但磁盘损坏即数据全失——所以单 master 更要勤做 snapshot。
</details>

3. `kubeadm certs renew all` 之后集群会自动恢复吗？请说出至少两个必须手工处理的点。

<details><summary>答案</summary>

不会自动恢复。必做：① 重启四个控制面静态 Pod（manifest 移出移回或重启容器），进程不重启就还攥着旧证书；② 重拷 admin.conf 到 `~/.kube/config`（kubectl 用的是副本）；多实例 HA 场景还要确认各组件 kubeconfig（scheduler.conf 等）被对应进程重新加载。
</details>

4. 为什么 kubeadm 的升级顺序是"kubeadm 二进制 → 控制面静态 Pod → kubelet"，而不能反过来？

<details><summary>答案</summary>

版本偏差规则禁止 kubelet 比 kube-apiserver 新。若先升 kubelet，apiserver 还是旧版，集群立刻进入不支持状态（API 兼容性未验证）。而控制面先升、kubelet 落后是明确支持的（最多旧 3 个 minor），窗口期内集群功能完好。kubeadm 本体只是工具，先换工具再改集群，还能在 plan 阶段拦截不合规操作。
</details>

5. apiserver 完全起不来（比如 manifest 被改坏），此时 kubectl 已不可用。你怎么把集群修好？这说明静态 Pod 设计解决了什么问题？

<details><summary>答案</summary>

直接登录节点修 `/etc/kubernetes/manifests/kube-apiserver.yaml`（或把备份拷回），kubelet 检测到文件变化即重建容器——全程不需要 apiserver 参与。这说明静态 Pod 让控制面的"最后修复路径"独立于 API 本身：哪怕 apiserver 死了，"让 apiserver 活过来"的手段仍然存在。这也是考题里"apiserver 故障只能节点侧修复"的原理依据。
</details>

## 延伸阅读

- kubeadm 产物细节：https://kubernetes.io/docs/reference/setup-tools/kubeadm/implementation-details/
- 证书管理（check-expiration / renew）：https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-certs/
- kubeadm 升级：https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- 版本偏差策略（升级前必读）：https://kubernetes.io/docs/setup/release/version-skew-policy/
- etcd 维护（compact/defrag/snapshot）：https://etcd.io/docs/v3.5/op-guide/maintenance/
- etcd 硬件建议：https://etcd.io/docs/v3.5/op-guide/hardware/
