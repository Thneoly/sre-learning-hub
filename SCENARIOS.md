# 场景速查（排障与任务索引）

> 按【故障现象 / 运维任务】组织的全站随机访问索引——出事时从这里的"现象"进门，3 秒找到"先查什么"和"去哪本书看"。
> 与 [ROADMAP.md](ROADMAP.md)（按学习顺序）互补：ROADMAP 回答"接下来学什么"，本文件回答"现在挂了去哪查"。
> 条目格式：`现象 → 先查 → 详见`。标【靶场】的条目有对应的故障注入脚本（`scripts/faults/break-*.sh`），可直接做限时演练（见文末使用说明）。
> 纪律：本文件只索引学习中心已有内容，不新编知识；所有路径与小节名均核对过原文。

---

## 1 集群与控制面（kubectl 不通 / 节点 NotReady / 组件挂 / 证书 / etcd / 升级）

- **现象**：不知从哪下手排集群故障 → 先查：`kubectl get nodes` 通不通，按"五层定位法"选层（集群→对象→容器→节点服务→系统） → 详见：05-cka/06-node-maintenance-troubleshooting.md#2. 排错决策树：五层定位法
- **现象**：十大高频故障想直接查表（NotReady/Pending/CrashLoop/drain 卡住…） → 先查：`## 3` 速查表第一列对号入座 → 详见：05-cka/06-node-maintenance-troubleshooting.md#3. 十大高频故障现象速查表
- 【靶场】**现象**：kubectl 任意命令 connection refused，已有业务 Pod 正常 → 先查：`ss -lntp | grep -E '6443|6444'`——6444 有人听说明"端口飞了" → 详见：scripts/faults/FIXES.md#11. break-apiserver-port
- 【靶场】**现象**：kubectl 全 refused，且 apiserver 容器反复重启（crash loop） → 先查：`crictl logs` 看崩溃容器连不上的地址 → 详见：scripts/faults/FIXES.md#3. break-etcd-endpoint
- 【靶场】**现象**：某节点 40~60 秒变 NotReady，已有 Pod 继续跑但无法新建/删除 → 先查：`systemctl status kubelet` 是否 activating (auto-restart) → 详见：scripts/faults/FIXES.md#2. break-kubelet
- 【靶场】**现象**：节点约 1 分钟变 NotReady，Conditions 点名 NetworkPluginNotReady，新 Pod 卡 ContainerCreating → 先查：`kubectl get ds -A | grep calico` 是否还有 agent → 详见：scripts/faults/FIXES.md#4. break-cni
- **现象**：节点 NotReady，kubelet 日志刷 `pleg is not healthy` → 先查：`systemctl status containerd`（relist 超时） → 详见：04-k8s-fundamentals/02-architecture-and-control-loop.md#常见坑
- 【靶场】**现象**：kube-scheduler Pod 直接消失（非 CrashLoop），新 Deployment 的 Pod 永远 Pending → 先查：`ls -l /etc/kubernetes/manifests/` 少了谁 → 详见：scripts/faults/FIXES.md#5. break-static-pod
- **现象**：所有组件同时失联，报 `x509: certificate has expired` → 先查：`kubeadm certs check-expiration`，再按"症状→证书"表定位 → 详见：05-cka/05-secrets-and-cert-troubleshooting.md#5. 证书过期典型症状速查
- **现象**：`get pods` 正常但 logs/exec/top 报 401/403 → 先查：apiserver-kubelet-client 证书过期（六张证书用途表） → 详见：05-cka/05-secrets-and-cert-troubleshooting.md#3. kubeadm 证书体系：六张 apiserver 相关证书
- **现象**：`certs renew all` 后症状没变 / kubectl 仍报证书过期 → 先查：静态 Pod 没重启（需 `crictl stop` 重建）+ kubeconfig 里是旧证书副本需重拷 admin.conf → 详见：04-k8s-fundamentals/13-cluster-admin-and-etcd.md#常见坑
- **现象**：集群只读、大面积超时，etcd 日志 `alarm NOSPACE` → 先查：`etcdctl alarm list`（backend 配额打满） → 详见：04-k8s-fundamentals/13-cluster-admin-and-etcd.md#常见坑
- **现象**：etcdctl snapshot 报 command not found / connection refused / certificate is valid for → 先查：`ETCDCTL_API=3` + client 口 2379（非 2380）+ etcd 自己的 CA 三件套 → 详见：05-cka/04-etcd-backup-restore.md#常见坑
- **现象**：kube-system 控制 Pod 删了又出现、edit 被改回，或 apiserver 反复重启（manifest 改坏） → 先查：静态 Pod 只认 `/etc/kubernetes/manifests/` 下的文件，恢复备份 + `crictl logs` 看退出原因 → 详见：04-k8s-fundamentals/13-cluster-admin-and-etcd.md#常见坑（另见 07-cks/01-cluster-hardening.md#常见坑）
- **现象**：drain 卡住不动 / init 后节点 NotReady / join 报 token 过期 → 先查：`--ignore-daemonsets --delete-emptydir-data`；CNI cidr 是否与 pod-network-cidr 一致；master 上 `kubeadm token create --print-join-command` → 详见：05-cka/03-kubeadm-install-upgrade.md#常见坑
- **现象**：kubectl 连不上 apiserver，想先确认服务本身死活 → 先查：master 上 `curl 127.0.0.1:6443/healthz` + `crictl ps` 查 apiserver → 详见：04-k8s-fundamentals/14-observability.md#4. kubectl 排障命令矩阵

## 2 网络与 DNS（Pod 不通 / Service 无后端 / 域名解析 / 502 / 504）

- 【靶场】**现象**：全集群 Pod `nslookup baidu.com` SERVFAIL，业务日志大量 `lookup xxx ... no such host` → 先查：`kubectl -n kube-system logs deploy/coredns` 看 forward 报错（FQDN 还能解析别被误导） → 详见：scripts/faults/FIXES.md#1. break-coredns
- 【靶场】**现象**：只有某个 namespace 的 Pod 解析失败，其他正常 → 先查：`kubectl exec <pod> -- cat /etc/resolv.conf` 是否缺集群 DNS → 详见：scripts/faults/FIXES.md#12. break-dns-config
- 【靶场】**现象**：Service VIP 不通，后端 Pod 全 Running 且 Pod IP 直访是通的 → 先查：`kubectl get endpoints <svc>` 是否 `<none>` → 详见：scripts/faults/FIXES.md#7. break-endpoints
- 【靶场】**现象**：本节点 Pod 出网/跨节点全超时，节点互 ping 与 SSH 正常（"半边瘫"） → 先查：`sysctl net.ipv4.ip_forward` 必须为 1 → 详见：scripts/faults/FIXES.md#8. break-ipforward
- **现象**：Endpoints 为 `<none>`、curl 超时，要一套标准动作序 → 先查：五步法——describe svc → get pods -l → 比对 labels → 查 Ready → 查 targetPort 语义 → 详见：04-k8s-fundamentals/05-service-and-dns.md#5. Endpoints / EndpointSlice 与"五步排错法"
- **现象**：ping ClusterIP 不通但 curl 通 / 外部域名解析偶发秒级延迟 / LB Service 一直 `<pending>` → 先查：iptables 模式只对端口生效（ping 不通是预期）；ndots:5 search 展开；裸金属装 MetalLB → 详见：04-k8s-fundamentals/05-service-and-dns.md#常见坑
- **现象**：Ingress 创建成功但 ADDRESS 空、不通；或 HTTPRoute 不生效 → 先查：`kubectl get ingressclass` / `spec.ingressClassName`；HTTPRoute 看 status.parents.conditions → 详见：04-k8s-fundamentals/06-ingress-and-gateway-api.md#常见坑
- **现象**：TLS 握手拿到 Fake Certificate（默认证书回退） → 先查：`openssl s_client -servername` 复现，核对 tls.hosts 与同 ns 的 secretName → 详见：04-k8s-fundamentals/06-ingress-and-gateway-api.md#常见坑
- **现象**：装了 flannel 后 NetworkPolicy 完全不生效；或 default-deny 后 DNS 全挂 → 先查：flannel 未实现 NetworkPolicy；egress 白名单要放行 kube-dns 53 UDP/TCP → 详见：04-k8s-fundamentals/10-cni-and-pod-networking.md#常见坑
- **现象**：Pod 跨节点互 ping 不通但节点间正常 → 先查：underlay 防火墙是否拦 VXLAN UDP 4789 / IPIP 协议 4 → 详见：04-k8s-fundamentals/10-cni-and-pod-networking.md#常见坑
- **现象**：小包能通、大包或页面卡死 → 先查：`ping -M do -s` 定界 MTU（overlay 有 50 字节开销） → 详见：04-k8s-fundamentals/10-cni-and-pod-networking.md#常见坑
- **现象**：Calico 多网卡 VM 节点间不通 → 先查：IP_AUTODETECTION_METHOD 是否选错网卡 → 详见：04-k8s-fundamentals/10-cni-and-pod-networking.md#常见坑
- **现象**：endpoints 有值、Pod Running，但 Service 仍 curl 不通 → 先查：换层查——直连 Pod IP 二分定位 CNI/NetworkPolicy/目标端口 → 详见：05-cka/06-node-maintenance-troubleshooting.md#常见坑
- **现象**：nginx 报 502 / 504 / 499，要一套定位流程 → 先查：三板斧——error.log 同时间戳原文 → access_log 看 ua/urt → nginx 机上直接 curl 后端复现 → 详见：11-middleware/nginx/03-performance-troubleshooting.md#3. 502 / 504 / 499：链路定位决策树
- **现象**：高并发下报 `Cannot assign requested address` / `nf_conntrack: table full` → 先查：ephemeral 端口与 conntrack 表容量（TIME_WAIT 本身不是故障） → 详见：01-linux/05-network-stack-internals.md#常见坑
- **现象**：CLOSE_WAIT 持续堆积 → 先查：应用收 FIN 后不 close，改代码而非调内核参数 → 详见：01-linux/05-network-stack-internals.md#常见坑
- **现象**：云上 SLB 健康检查一直 failed / 同 VPC 子网间 ping 不通 → 先查：安全组放行 100.64.0.0/10 与 ICMP；服务是否只听 127.0.0.1 → 详见：14-cloud/02-aliyun-practice.md#常见坑（另见 14-cloud/01-cloud-fundamentals.md#常见坑）

## 3 工作负载（Pending / CrashLoop / ImagePullBackOff / 滚动更新卡住）

- 【靶场】**现象**：新 Pod ErrImagePull → ImagePullBackOff 按退避节奏反复重试 → 先查：`kubectl describe pod` 的 Events，区分 not found / authentication required / i/o timeout 三类 → 详见：scripts/faults/FIXES.md#10. break-imagepull
- 【靶场】**现象**：新 Pod 一直 Pending，事件 `FailedScheduling ... Insufficient cpu`，节点 Ready、组件正常 → 先查：`kubectl describe node | grep -A8 "Allocated resources"`，找吃 CPU 的大户 → 详见：scripts/faults/FIXES.md#9. break-scheduler-pod
- **现象**：RESTARTS 涨、CrashLoopBackOff，分不清应用退出/探针过严/OOM → 先查：三连——`kubectl logs --previous` → `describe`（exit 137=OOM）→ `get events --sort-by` → 详见：04-k8s-fundamentals/03-pods-deep-dive.md#6. restartPolicy 与 CrashLoopBackOff
- **现象**：滚动更新瞬间 5xx / 容器收 SIGTERM 不退 / Pod 删除等 30s 才停 → 先查：readinessProbe + preStop sleep；启动命令用 exec 形式别用 sh -c 包裹 → 详见：04-k8s-fundamentals/03-pods-deep-dive.md#常见坑
- **现象**：init 失败 Pod 卡 Pending；同 Pod 两容器抢 80 端口 → 先查：`kubectl logs -c <init容器>`；共享 network namespace 端口空间唯一 → 详见：04-k8s-fundamentals/03-pods-deep-dive.md#常见坑
- **现象**：HPA TARGETS 显示 `<unknown>`；或手动 scale 后副本数又变回去 → 先查：metrics-server 是否装好（`get --raw` 验证聚合 API）；replicas 被 HPA 周期性重算 → 详见：04-k8s-fundamentals/04-workload-controllers.md#常见坑
- **现象**：StatefulSet Pod 卡 Pending/ContainerCreating；DaemonSet 在 master 无副本 → 先查：无默认 StorageClass 导致 PVC 未绑定；DS 未容忍 control-plane 污点 → 详见：04-k8s-fundamentals/04-workload-controllers.md#常见坑
- **现象**：Job 一直不 Complete / CronJob 不触发 / rollout undo 说没有历史 → 先查：退出码与 sidecar；时区与 LastScheduleTime；revisionHistoryLimit → 详见：04-k8s-fundamentals/04-workload-controllers.md#常见坑
- **现象**：单节点集群 Pod 全 Pending（untolerated taint control-plane）；或扩容后部分副本永久 Pending → 先查：污点需 toleration；required 反亲和/spread 超过节点数改 preferred → 详见：04-k8s-fundamentals/08-scheduling.md#常见坑
- **现象**：分不清"调度失败"还是"被驱逐" → 先查：FailedScheduling 事件=没地方去（看 scheduler）；Evicted=待不下去了（看节点 kubelet 日志） → 详见：04-k8s-fundamentals/08-scheduling.md#6. 调度失败 vs 驱逐：两个不同组件的两种失败
- **现象**：delete pod 后又冒新的；Namespace/PVC 长期 Terminating；apply 成功但服务没起 → 先查：删控制器别跟 Pod 较劲；查 finalizer；apply 只写期望，rollout status + describe 看后续 → 详见：04-k8s-fundamentals/01-why-kubernetes.md#常见坑
- **现象**：Pod 卡 CreateContainerConfigError；改了 ConfigMap 容器内没变 → 先查：引用的 CM/Secret/key 是否存在；env 注入不热更，卷挂载或 rollout restart → 详见：04-k8s-fundamentals/09-configmap-and-secret.md#常见坑
- **现象**：Deployment YAML 有两处独立问题，修好第一处才暴露第二处（排障练习） → 先查：先 Events 定位镜像层故障，再排查第二处 → 详见：05-cka/labs/18-crashloop-triage/task.md
- **现象**：Pod 不 Ready 但看不出原因，需要完整 DNS/Service 链路排查演练 → 先查：dnsutils 调试 Pod 逐层验证 Service 名/FQDN/CoreDNS → 详见：05-cka/labs/17-dns-debugging/task.md（速查见同目录 solution.md 的"DNS 故障速查"节）

## 4 存储与中间件（PVC Pending / 主从延迟 / 哨兵切换 / 连接打满 / HDFS·YARN·Spark·Doris·湖仓）

- **现象**：PVC 一直 Pending / 有 SC 也绑不上 → 先查：`kubectl get sc` + `describe pvc` 看 Events；storageClassName 的 `""` 与省略语义不同；WFFC 要先建 Pod → 详见：04-k8s-fundamentals/07-storage.md#常见坑
- **现象**：Pod 卡 ContainerCreating 报 Multi-Attach error；Retain 的 PV 一直 Released；PVC 扩容报错 → 先查：RWO 卷未 detach（失联节点可强删 volumeattachment）；Released 需清 claimRef；SC 开 allowVolumeExpansion 且只升不降 → 详见：04-k8s-fundamentals/07-storage.md#常见坑
- **现象**：MySQL 报 1040 Too many connections、CPU 100% 或 metadata lock 排队 → 先查：`SHOW PROCESSLIST` 分型（连接池泄漏/DNS 反解析/慢 SQL 并发/DDL 阻塞），先留证据再 KILL → 详见：11-middleware/mysql/03-tuning-troubleshooting.md#4. 高频故障排障手册（连接打满）
- **现象**：MySQL 所在盘 `No space left on device` → 先查：df → du 找大头 → `PURGE BINARY LOGS`（严禁 rm 物理文件，ibdata/undo 删了实例即毁） → 详见：11-middleware/mysql/03-tuning-troubleshooting.md#4. 高频故障排障手册（磁盘满）
- **现象**：MySQL 主从延迟（Seconds_Behind_Source 增长），或复制中断报 1062/1032 → 先查：延迟先判型（平稳=单线程重放慢 / 阶梯=大事务）；1062/1032 用 GTID 空事务跳过，不一致重搭 → 详见：11-middleware/mysql/03-tuning-troubleshooting.md#4. 高频故障排障手册（主从延迟）；11-middleware/mysql/02-backup-replication.md#常见坑
- **现象**：MySQL EXPLAIN 看着没问题但就是慢；加了索引不走 → 先查：EXPLAIN ANALYZE 看真实耗时；统计信息过期/隐式类型转换/列上函数 → 详见：11-middleware/mysql/03-tuning-troubleshooting.md#常见坑
- **现象**：Redis 磁盘满后所有写报错；或每分钟固定点延迟尖刺 → 先查：`stop-writes-on-bgsave-error` 是保护先修磁盘；`latest_fork_usec` 监控 fork 耗时 → 详见：11-middleware/redis/02-persistence-and-ha.md#常见坑
- **现象**：Redis replica 闪断一次就全量同步；三哨兵挂俩不切换 → 先查：repl-backlog-size 按断线时长×写流量调大；哨兵需 ≥3 且奇数凑 majority → 详见：11-middleware/redis/02-persistence-and-ha.md#常见坑
- **现象**：Redis 突发超时但 SLOWLOG 是空的 → 先查：四类元凶按序过筛——慢命令 → fork 卡顿 → swap（碎片率<1）→ AOF fsync 慢 → 详见：11-middleware/redis/03-caching-patterns-troubleshooting.md#3. 阻塞点排查：单线程模型下的四类元凶
- **现象**：配了 volatile-lru 仍报 OOM；Redis 容器频繁 OOMKilled → 先查：没有 key 带 TTL 则 volatile 系无候选；limit 未给 fork COW 留余量（≥1.5×maxmemory） → 详见：11-middleware/redis/03-caching-patterns-troubleshooting.md#常见坑
- **现象**：MongoDB 两节点副本集挂一个，另一个不能写 → 先查：剩 1/2 不够多数派（防脑裂），至少 3 个投票成员 → 详见：11-middleware/mongodb/02-replicaset-and-sharding.md#常见坑
- **现象**：MongoDB 慢/超时，不知从哪查起 → 先查：四类对号入座——个别接口慢（索引）/整体抬升（cache）/qw 堆积（tickets）/连接暴涨（连接风暴） → 详见：11-middleware/mongodb/03-operations-troubleshooting.md#3. 排障套路：四类问题对号入座
- **现象**：MongoDB 一天多次无故切主（选举震荡）；连接数瞬间打满 → 先查：`rs.status()` 看心跳超时成因（网络/资源打满）；maxPoolSize 收敛与重连风暴 → 详见：11-middleware/mongodb/03-operations-troubleshooting.md#常见坑
- **现象**：Kafka 消费组频繁 rebalance / broker 磁盘满写入失败 / under-replicated 副本掉线 → 先查：三大排障表按日志关键词对号（max.poll.interval 超时、手动 rm segment、fetch 追不上） → 详见：12-data-streaming/kafka/03-operations-and-performance.md#5. 三大高频故障排障表
- **现象**：Kafka 大量 NotEnoughReplicasException 写入失败 → 先查：ISR 收缩到 min.insync.replicas 以下——先救 ISR，别调小 min.insync → 详见：12-data-streaming/kafka/02-replication-and-reliability.md#常见坑
- **现象**：Flink checkpoint 一直 timeout/failed，反压面板全红找不到瓶颈 → 先查：反压让 barrier 走不动；找第一个 busy≈1000 的算子（受害者不背锅） → 详见：12-data-streaming/flink/02-deployment-and-exactly-once.md#6. 反压：原理与定位
- **现象**：Flink Pod 重建后作业状态全丢；savepoint 恢复报 cannot map → 先查：状态目录别指向容器内 file:///tmp；算子要固定 .uid() → 详见：12-data-streaming/flink/02-deployment-and-exactly-once.md#常见坑
- **现象**：HDFS NameNode 重启后卡在 safemode 十几分钟，UI 显示 reported blocks 未达 0.999 → 先查：`hdfs dfsadmin -safemode get` + `-report` 看 Live Nodes 与块报告进度；手动 leave 的前提是 DN 全部在线 → 详见：16-bigdata/01-hdfs.md#6. 运维核心一：safemode 的语义与进出条件
- **现象**：NN UI 报 Missing/Corrupt Blocks > 0，用户读文件报 Could not obtain block → 先查：`hdfs fsck / -list-corruptfileblocks` 拿清单再按 runbook 走——先确认 DN 是否暂时离线（多数 missing 等 10~30 分钟自愈），严禁一见 missing 就 `-delete` → 详见：16-bigdata/01-hdfs.md#7. 运维核心二：丢失块 / 损坏块的处理流程
- **现象**：UnderReplicatedBlocks 暴涨，疑似 DN 批量故障 → 先查：DN 判死要约 10.5 分钟，机器重启/网络抖动属短暂离线——先等 DN 回来，多数自己落回去 → 详见：16-bigdata/01-hdfs.md#3. DataNode：心跳、块报告与"死"的判定
- **现象**：fsck 显示某文件的 3 副本全落在同一机架，单机架断电即丢数据 → 先查：`hdfs fsck /path -blocks -locations -racks`——没配机架感知全体落 /default-rack；存量数据要 setrep 触发重复制，Balancer 只搬量不纠拓扑 → 详见：16-bigdata/01-hdfs.md#4. 块模型：128MB 块、3 副本放置与纠删码
- **现象**：文件一直处于 `.tmp` 写不进去，或报 lease 相关错误 → 先查：writer 崩溃后租约未回收——`hdfs debug recoverLease -path <file>`，或等硬限自动回收 → 详见：16-bigdata/01-hdfs.md#常见坑
- **现象**：NN 频繁 Full GC、RPC p99 抖动，重启回放 edits 比预期长一倍 → 先查：小文件把堆吃满（每对象约 150B）+ checkpoint 失效 edits 无限增长——治理小文件与 checkpoint，短期加堆只买时间 → 详见：16-bigdata/01-hdfs.md#9. 小文件：量化危害与治理
- **现象**：新上线的 DataNode 磁盘利用率长期 5%，没人写它 → 先查：新节点空盘属预期——排 Balancer 计划，`-setBalancerBandwidth` 错峰跑（搬迁流量与业务读写抢盘和网卡） → 详见：16-bigdata/01-hdfs.md#8. 运维核心三：Balancer 与数据再平衡
- **现象**：YARN 作业一直 ACCEPTED，一个 container 都不动 → 先查：`yarn queue -status` + `yarn application -status`——队列满 / 单容器申请超 maximum-allocation / AM 被 am-percent 卡住 → 详见：16-bigdata/02-yarn.md#常见坑
- **现象**：container 报 `running beyond virtual memory limits` 被 NM 杀（最经典"假 OOM"） → 先查：vmem-pmem-ratio 默认 2.1 对 JVM 堆外过紧——`yarn.nodemanager.vmem-check-enabled=false`（物理内存检查保留） → 详见：16-bigdata/02-yarn.md#2. 资源模型：Container = memory + vcores
- **现象**：container 报 `running beyond physical memory limits`，退出码 137/143 → 先查：真超内存——executor/AM 的堆外按堆的 20~40% 预留，提高该角色 memory 配置 → 详见：16-bigdata/02-yarn.md#常见坑
- **现象**：大队列里几百个小应用全在 ACCEPTED，队列明明还有资源 → 先查：`maximum-am-resource-percent` 默认 0.1 被 AM 占满——按负载形态调大，或把 Spark Thrift Server 类常驻应用挪独立队列 → 详见：16-bigdata/02-yarn.md#1. 三个角色：RM 全局调度、NM 本地执行、每应用一个 AM
- **现象**：`yarn rmadmin -refreshQueues` 报错 → 先查：root 直接子队列 capacity 总和必须恒等于 100、不能删还有运行应用的队列（刷新失败不会弄挂 RM，放心改） → 详见：16-bigdata/02-yarn.md#6. 运维：队列配置热更新
- **现象**：RM 主备切换后所有运行中作业失败重提 → 先查：HA 开了 recovery 没开——`yarn.resourcemanager.recovery.enabled=true` + ZK StateStore，否则切换=全集群作业清零 → 详见：16-bigdata/02-yarn.md#7. RM HA 与重启恢复
- **现象**：beeline 卡在 `Connecting to jdbc:hive2://...` 数分钟，已建立的查询跟着变慢 → 先查：`ss -tn state established '( sport = :10000 )' | wc -l` 对比 max worker threads，HS2 Web UI Sessions 页查僵尸 session 与 idle 超时 → 详见：16-bigdata/03-hive-warehouse.md#8.2 HS2 连接打满排障
- **现象**：Hive metastore 首次启动报 schema 版本不匹配 → 先查：元数据库未初始化或版本不配——`schematool -dbType mysql -initSchema`（升级用 `-upgradeSchema`） → 详见：16-bigdata/03-hive-warehouse.md#常见坑
- **现象**：动态分区插入报 Dynamic partition strict mode → 先查：默认 strict 要求至少一个静态分区列——临时 `SET hive.exec.dynamic.partition.mode=nonstrict;`，长期在入仓脚本固定保留一级静态分区 → 详见：16-bigdata/03-hive-warehouse.md#常见坑
- **现象**：ACID 事务表越查越慢，表目录下 delta 目录越堆越多 → 先查：`SHOW COMPACTIONS` 与 compactor worker 是否在跑——例行 `ALTER TABLE ... COMPACT`，delta 堆积直接拖垮读性能 → 详见：16-bigdata/03-hive-warehouse.md#7. ACID 事务表的演进
- **现象**：查询明明带 dt 过滤却全表扫 → 先查：分区列被函数/别名包裹（如 `where dt=to_date(x)`）无法编译期常量折叠——`EXPLAIN` 看 Num rows 验证裁剪是否生效 → 详见：16-bigdata/03-hive-warehouse.md#常见坑
- **现象**：误删表后恢复 metastore 备份，业务仍报错 → 先查：MySQL 元数据与 HDFS 文件撕裂（孤儿目录/表定义"复活"）——恢复 runbook 写清以哪边为准 + SHOW TABLES 抽查与关键分区 count 比对 → 详见：16-bigdata/03-hive-warehouse.md#8.1 metastore 本质是一个 MySQL 库
- **现象**：Spark on YARN 报 `Container killed by YARN for exceeding memory limits`（K8s 上为 OOMKilled 137），executor 堆明明没用满 → 先查：RSS=堆+堆外超容器预算，netty 直接内存先膨胀——调 `spark.executor.memoryOverhead` 而不是盲目加大 -Xmx（容器上限 = memory + overhead） → 详见：16-bigdata/04-spark.md#7.3 高频故障表
- **现象**：一个 stage 99% 的 task 秒级完成，个别 task 跑几十分钟且 Spill (disk) 十几 GB → 先查：数据倾斜——`EXPLAIN` 定位倾斜的 Exchange；null/空 key 先拆出去，再按口诀选 broadcast/两阶段聚合/加盐，先让 AQE 试 → 详见：16-bigdata/04-spark.md#5. 数据倾斜三板斧
- **现象**：Spark 开了 dynamicAllocation 后 `FetchFailed` / `Map output lost` 反复出现，stage 反复重算 → 先查：executor 被回收后 shuffle 输出丢失——YARN 配 ESS（NM 常驻 7337），K8s 开 shuffleTracking → 详见：16-bigdata/04-spark.md#6. 动态资源分配与 external shuffle service
- **现象**：broadcast join 把 Driver 打挂 → 先查："小表"实际几百 MB——调低 autoBroadcastJoinThreshold 或去掉 broadcast 提示 → 详见：16-bigdata/04-spark.md#常见坑
- **现象**：Spark client 模式提交后关掉终端作业就死 → 先查：Driver 跑在提交机——生产用 cluster 模式（或 nohup/tmux 托管） → 详见：16-bigdata/04-spark.md#常见坑
- **现象**：Driver 报 `Total size of serialized results > spark.driver.maxResultSize` → 先查：collect/take 往 Driver 拉了太多数据——改为 write 落盘，别把结果收回 Driver → 详见：16-bigdata/04-spark.md#7.3 高频故障表
- **现象**：Spark 作业挂了却没有 4040 UI 可复盘（生产 Driver 一闪而过） → 先查：eventLog + History Server（18080）离线回放 stages/executors 全量页面——eventLog.dir 放 HDFS 并常驻 SHS → 详见：16-bigdata/04-spark.md#7.2 History Server 部署
- **现象**：Doris 建表报 not enough backends / 副本不足 → 先查：默认 `replication_num=3` 而可用 BE 不够——实验表显式 `"replication_num"="1"`；生产扩 BE 而不是降副本 → 详见：16-bigdata/05-olap-doris-starrocks.md#常见坑
- **现象**：Doris BE 注册后 `SHOW BACKENDS` 里 Alive=false → 先查：BE 日志——宿主机 `vm.max_map_count` 太低、ulimit 不够或 FE/BE 网络不通 → 详见：16-bigdata/05-olap-doris-starrocks.md#常见坑
- **现象**：Doris 导入报 too many versions，compaction score 持续升高 → 先查：高频小批量导入让版本数超过合并能力——攒大批次降导入频率；不治会一路串成 Flink 反压 → Kafka lag → 详见：16-bigdata/05-olap-doris-starrocks.md#6.2 BE 磁盘与 compaction
- **现象**：Doris FE Leader 宕机 30 秒，建表/导入提交全阻塞 → 先查：follower 多数派重选主期间元数据写阻塞是预期；FE 至少 3 个 FOLLOWER，OBSERVER 不参与 quorum 不算数 → 详见：16-bigdata/05-olap-doris-starrocks.md#6.1 FE 元数据与 Leader 选举
- **现象**：Doris Stream Load 经 FE 8030 报 307 或 401 → 先查：FE 重定向到 BE 而 curl 不透传 Authorization 头——直发 BE 8040，或 `curl --location-trusted` → 详见：16-bigdata/05-olap-doris-starrocks.md#常见坑
- **现象**：Flink 作业恢复重放后 Doris 大量 `Label Already Exists` → 先查：label 幂等 + 2PC 的正常表现，表里不会写两遍——核对 label 生成规则（前缀+checkpointId）即可，不要删 label → 详见：16-bigdata/05-olap-doris-starrocks.md#5. 导入通道：Stream Load 与 Flink Connector（串回 exactly-once）
- **现象**：Doris 一张大报表把线上小查询拖死 → 先查：大查询与线上查询共享 BE 无隔离——资源标签分组（物理隔离）/ workload group 限流，大回刷错峰 → 详见：16-bigdata/05-olap-doris-starrocks.md#6.3 查询排队与资源隔离
- **现象**：Doris FE 全部重启后起不来 → 先查：bdb 元数据损坏或过半丢失——从 image 检查点 + 备份恢复；FE 也要当有状态系统做备份（纪律同 etcd） → 详见：16-bigdata/05-olap-doris-starrocks.md#常见坑
- **现象**：Iceberg 并发写报 commit 冲突；或湖表越写越慢、计划阶段就耗时 → 先查：多 writer 争同一表的 catalog 锁 + 小文件/manifest 碎片化——减少并发 writer、按分区隔离写，`rewrite_data_files`/`rewrite_manifests` 定时跑 → 详见：16-bigdata/07-lakehouse-table-formats.md#常见坑
- **现象**：time travel 报 snapshot 不存在 → 先查：被 expire 清掉了——先查 `table.snapshots` 元数据表确认保留窗口，要长回溯调大 `history.expire.max-snapshot-age-ms` → 详见：16-bigdata/07-lakehouse-table-formats.md#常见坑
- **现象**：Hudi MOR 表查询越来越慢 → 先查：compaction 积压——看 timeline 上 compaction requested 是否长期未执行；调度独立 compaction，临时用 read_optimized 查询 → 详见：16-bigdata/07-lakehouse-table-formats.md#常见坑
- **现象**：Hudi 增量消费突然断流/丢数据 → 先查：cleaning 把保留窗口清得太狠——调大 `hoodie.cleaner.commits.retained`，按下游重放需求定 → 详见：16-bigdata/07-lakehouse-table-formats.md#常见坑
- **现象**：Flink 写湖恢复后疑似重复数据，湖上无主文件增多 → 先查：checkpoint 被关或间隔过长，sink 提交与 checkpoint 脱钩——恢复 checkpoint 配置；孤儿文件用 `remove_orphan_files` 清（先核对无长事务） → 详见：16-bigdata/07-lakehouse-table-formats.md#7. 与 12-data-streaming 的衔接：exactly-once 落到湖写入路径
- **现象**：Flink checkpoint 超时，第一嫌疑人是湖 commit / catalog 挂了写全阻塞 → 先查：对象存储限流（429/503）与 catalog 锁竞争——catalog 是湖表的 NameNode，HMS 路线的备份纪律等同 etcd → 详见：16-bigdata/07-lakehouse-table-formats.md#6.4 catalog 选型：HMS、REST catalog、Nessie
- **现象**：湖表 snapshot/manifest 膨胀想监控，却发现没有 exporter 可装 → 先查：表格式无常驻进程——读 Iceberg 只读元数据表（snapshots/files/manifests）巡检推 Pushgateway 变 gauge，接既有告警体系 → 详见：16-bigdata/07-lakehouse-table-formats.md#6.2 snapshot / manifest 膨胀监控（指标与告警思路）

## 5 性能与资源（CPU 高 / 内存涨 / OOM / 磁盘满 / 限流）

- **现象**：CPU 高，不知下一步看什么 → 先查：top 的 %Cpu(s) 行先分支——us/sy/wa/st 四路走法（用户态火焰图/内核态上下文切换/IO 等待/虚拟化窃取） → 详见：01-linux/06-performance-analysis.md#5. "CPU 高"完整排查决策树
- **现象**：load 很高但 CPU 大量 idle；kill -9 杀不死进程 → 先查：load 含 D 状态任务，`ps` 分 R/D 状态再下结论，/proc/PID/stack 看等待点 → 详见：01-linux/04-processes-and-cfs.md#常见坑
- **现象**：容器 CPU 使用率不高但响应周期性卡顿 → 先查：cgroup CFS 节流，看 cpu.stat 的 nr_throttled，提高 limit → 详见：04-k8s-fundamentals/11-resources-and-qos.md#常见坑
- **现象**：Pod 被 OOMKilled（exit code 137）；或按 100M 申请内存仍 OOM → 先查：对照 working_set_bytes 与 limit；M 是 10^6 比 Mi 少 4.9%，全集群统一 Mi/Gi → 详见：04-k8s-fundamentals/11-resources-and-qos.md#常见坑
- **现象**：Pod 被 Evicted；节点空闲却报 Insufficient cpu → 先查：evictionHard 阈值（nodefs/内存）；调度只看 Σrequests，查 Allocated resources 清僵尸负载 → 详见：04-k8s-fundamentals/11-resources-and-qos.md#常见坑
- **现象**：Go/Java 应用在 limit 1 核的容器里线程池开太大、周期性卡顿 → 先查：旧运行时读节点 CPU 数而非 cgroup 配额，显式设 GOMAXPROCS/automaxprocs → 详见：04-k8s-fundamentals/11-resources-and-qos.md#常见坑
- **现象**：df -h 有空间但报 No space；或 df 满、du 找不到大文件 → 先查：inode 耗尽用 df -i；被 rm 但进程仍打开用 `lsof +L1` → 详见：01-linux/02-filesystem-and-io.md#常见坑
- **现象**：free 很少被当内存不足告警 → 先查：buff/cache 可回收，看 available 列才是真实余量 → 详见：01-linux/03-memory-deep-dive.md#常见坑
- **现象**：iowait 低就排除 IO 问题；SSD %util 100% 当满载；VM 里 st 高调优无果 → 先查：CPU 一忙 wa 被挤掉，配 iostat await；%util 不度量并行度；st 高找宿主机资源方 → 详见：01-linux/06-performance-analysis.md#常见坑
- **现象**：kubelet 报 running with swap on；磁盘满后服务行为诡异 → 先查：swapoff -a 并注释 fstab；journald 写满 /var/log 用 --vacuum-size + SystemMaxUse → 详见：01-linux/01-boot-and-systemd.md#常见坑
- **现象**：nginx 报 Too many open files / worker_connections are not enough → 先查：worker_rlimit_nofile 与 systemd LimitNOFILE；反代每请求占 2 个连接槽 → 详见：11-middleware/nginx/01-architecture-and-process-model.md#常见坑
- **现象**：压测偶发 502 且报 Cannot assign requested address；调大 somaxconn 无效 → 先查：upstream 未配 keepalive 致源端口耗尽；listen backlog 默认 511 更小 → 详见：11-middleware/nginx/03-performance-troubleshooting.md#常见坑

## 6 交付流水线（CI 挂了 / ArgoCD 不同步 / 漂移 / Terraform state 锁）

- **现象**：git push 被拒 non-fast-forward；detached HEAD 上的提交切分支后不见 → 先查：先 `pull --rebase`；`git reflog` 找回 hash，慌的时候先 reflog 别乱 reset → 详见：06-cicd-iac-gitops/01-git-deep-dive.md#常见坑（救命操作见同文件 #5. 救命操作：stash 与 reflog）
- **现象**：GitLab CI job 一直 pending 提示 no runner；docker build 连不上 daemon → 先查：job tags 与 runner 标签匹配、`gitlab-runner verify`；dind 设 `DOCKER_TLS_CERTDIR=""` 或挂 socket → 详见：06-cicd-iac-gitops/02-gitlab-ci.md#常见坑
- **现象**：deploy-prod 阶段拿不到密码变量 → 先查：变量设了 protected 而 tag 不在 Protected tags → 详见：06-cicd-iac-gitops/02-gitlab-ci.md#常见坑
- **现象**：Jenkins agent 一直离线；job 排队不执行 → 先查：JNLP 50000 端口与 NTP；agent label 匹配与 executor 数 → 详见：06-cicd-iac-gitops/03-jenkins-and-github-actions.md#常见坑
- **现象**：ArgoCD 一直 OutOfSync 但资源看着一样；改了 Git 半天不生效 → 先查：`argocd app diff` 看默认值差异配 ignoreDifferences；默认 3 分钟才 refresh，配 webhook → 详见：06-cicd-iac-gitops/04-argocd-gitops.md#常见坑
- **现象**：手动 kubectl 改动后 ArgoCD 不回滚（漂移） → 先查：selfHeal 未开——sync 只管"Git 变了"，selfHeal 才管"集群被手改" → 详见：06-cicd-iac-gitops/04-argocd-gitops.md#常见坑
- **现象**：Ansible 报 UNREACHABLE Permission denied；handler 没触发；command 模块每次都 changed → 先查：ssh-copy-id 打通免密；notify 与 handler 名一致；command 天然不幂等换专用模块 → 详见：06-cicd-iac-gitops/05-ansible.md#常见坑
- **现象**：Terraform plan 显示 -/+ 要重建资源 → 先查：改了不可更新字段（cidr/镜像），评估停机或分批迁移 → 详见：06-cicd-iac-gitops/06-terraform.md#常见坑
- **现象**：apply 时卡在 Acquiring state lock → 先查：上次 apply 异常退出未释放锁，确认无 apply 在跑后 force-unlock → 详见：06-cicd-iac-gitops/06-terraform.md#常见坑
- **现象**：怀疑有人绕过 IaC 手改了云资源 → 先查：`terraform plan -detailed-exitcode`（exit 2=有漂移），nightly 跑 CI 告警 → 详见：06-cicd-iac-gitops/06-terraform.md#5. 漂移检测：state 说的和云上不一致
- **现象**：CI 里 kubectl/命令行为和本地不一样（cron/runner 环境） → 先查：cron 与 CI 的 PATH 极简，脚本内绝对路径或重设 PATH → 详见：02-programming/01-shell-fundamentals.md#常见坑
- **现象**：批量 ssh 脚本卡死在某台机器 → 先查：`-o ConnectTimeout=5 BatchMode=yes`（TCP 黑洞无超时） → 详见：02-programming/02-shell-ops-patterns.md#常见坑

## 7 可观测（指标缺失 / 告警风暴 / 日志查不到 / trace 断链）

- **现象**：不知道这个 K8s 故障该用什么命令查 → 先查：kubectl 排障命令矩阵——按"现象 | 第一入口 | 深挖命令"三列对号 → 详见：04-k8s-fundamentals/14-observability.md#4. kubectl 排障命令矩阵
- **现象**：kubectl top 报 Metrics API not available；metrics-server 日志报 x509；部分节点无指标 → 先查：metrics-server Pod 与 apiservice；实验集群加 --kubelet-insecure-tls；到 kubelet:10250 的连通性 → 详见：04-k8s-fundamentals/14-observability.md#常见坑
- **现象**：排障时证据拿不到——2 小时前的 Events 空了、logs --previous not found → 先查：--event-ttl 默认 1 小时；旧容器日志已被 GC，历史靠中心化采集 → 详见：04-k8s-fundamentals/14-observability.md#常见坑
- **现象**：PromQL 报 expected type range vector；正则 `=~"5"` 匹配不到 5xx → 先查：rate/over_time 要补 [5m] 窗口；正则全锚定需写 `5..` → 详见：08-pca/03-promql-guide.md#常见坑
- **现象**：histogram_quantile 输出怪值 / P99 曲线不动 / summary 多实例 avg 当整体 P99 → 先查：聚合别丢 le 标签；P99 落在过宽桶要埋点加窄桶；分位数不可平均改 histogram → 详见：08-pca/03-promql-guide.md#常见坑
- **现象**：告警一直 pending 不 firing；PrometheusRule 死活不生效 → 先查：for 太长或 expr 抖动（窗口≥4×抓取间隔）；规则缺 release 标签或放错 namespace → 详见：08-pca/05-alerting-alertmanager.md#常见坑
- **现象**：告警风暴一屏同种告警；同一故障收到两封；silence 了还收到 → 先查：group_by 加关键维度、group_wait 给足；规则重复定义；amtool silence ls 核对 matcher → 详见：08-pca/05-alerting-alertmanager.md#常见坑
- **现象**：blackbox 探测一切正常但目标明明挂了 → 先查：看的是 up 而非 probe_success，告警应盯 `probe_success == 0` → 详见：08-pca/04-instrumentation-exporters.md#常见坑
- **现象**：备份任务"永远成功"；Pushgateway 序列数持续增长 → 先查：指标不衰减的两大陷阱——监控 time() - push_time_seconds；grouping key 带随机成分 → 详见：08-pca/04-instrumentation-exporters.md#5.2 两大陷阱
- **现象**：链路在某跳断成两截（trace 断链） → 先查：对账 traceparent——该跳没装 propagator/代理剥头/异步丢 context → 详见：09-otel/01-signals-and-context-propagation.md#常见坑（断链高发区见同文件 #3.4 三种载体与断链高发区）
- **现象**：加了采样后链路断半截；Jaeger 里 service 名是 unknown_service → 先查：采样器用 parentbased 系列跟随根决策；显式设 OTEL_SERVICE_NAME → 详见：09-otel/02-instrumentation.md#常见坑
- **现象**：Collector 被 OOMKilled；改组件配置毫无变化 → 先查：memory_limiter 放 pipelines 首位且低于容器 limit 约 20%；组件需被 service.pipelines 引用 → 详见：09-otel/03-collector.md#常见坑
- **现象**：有 trace 但不会用它定位根因 → 先查：六步法（指标定层→trace 定点→属性定因→日志定据→K8s 验证→修复回归）+ 故障形态指纹表 → 详见：09-otel/05-otel-demo-astronomy-shop.md#实战演练三：故障注入与"从 trace 定位根因"
- **现象**：日志明明写入了 Kibana 搜不到；ES 磁盘 85% 后索引变只读 → 先查：手动 _refresh 排除、data view 时间窗；flood_stage 水位保护，清理后删 read_only 块 → 详见：10-logging/02-elk-stack.md#常见坑
- **现象**：Loki push 返回 429 / entry too far behind；`{job="app"}` 查询永远慢 → 先查：高基数标签撞每流速率限制；标签太宽扫的 chunk 太多，补收窄标签 → 详见：10-logging/03-loki-stack.md#常见坑
- **现象**：采集器抓不到某 Pod 日志；Pod 重建后日志从头再收 → 先查：应用写文件而非 stdout（加 sidecar）；positions 文件在容器可写层要挂 hostPath → 详见：10-logging/04-k8s-logging.md#常见坑
- **现象**：每班十几个 page 团队麻木；半夜 page 没人响应 → 先查：不可操作告警删或降级；时限驱动的升级阶梯（T+5 secondary、T+15 manager） → 详见：13-sre-methodology/03-oncall-incident-management.md#2. 告警分级与升级路径
- **现象**：面板查无数据（No data）；缩放时间范围后 rate 断点 → 先查：数据源 URL 别用 localhost；窗口 <4×抓取间隔会断，用 $__rate_interval → 详见：08-pca/06-grafana-dashboards.md#常见坑

## 8 安全（PSA 拒绝 / 证书过期 / 镜像高危 / 权限 403）

- 【靶场】**现象**：业务 Pod Running 但日志持续刷 Forbidden：SA cannot list pods → 先查：`kubectl auth can-i list pods --as=<报错里的 User>`，再查 Role 与 Binding 谁没了 → 详见：scripts/faults/FIXES.md#6. break-rbac
- **现象**：Pod 内调 API 报 403；1.24 后拿不到 SA 的 token Secret → 先查：default SA 零权限，专用 SA + RoleBinding；token 用 `kubectl create token`（短时） → 详见：04-k8s-fundamentals/12-rbac-and-service-accounts.md#常见坑
- **现象**：有 pods 读权限但 kubectl logs Forbidden；RoleBinding 绑 ClusterRole 却只在一个 ns 生效 → 先查：logs 走 pods/log 子资源；作用域由 Binding 决定，全集群要 ClusterRoleBinding → 详见：04-k8s-fundamentals/12-rbac-and-service-accounts.md#常见坑
- **现象**：PSA label 打了不生效；enforce=restricted 后大量 Pod 被拒 → 先查：label 必须打在 namespace 上；镜像默认 root，加 runAsNonRoot 与非 0 runAsUser → 详见：07-cks/03-microservice-vulnerabilities.md#常见坑
- **现象**：NetworkPolicy 似乎完全无效；改 automount 后 Pod 里还有 token → 先查：CNI 未就绪/不支持或 podSelector 不匹配；旧 Pod 滚动重启，删 Pod 级显式 true → 详见：07-cks/03-microservice-vulnerabilities.md#常见坑
- **现象**：CI 里 trivy --exit-code 1 全线打红；离线环境扫描卡住 → 先查：--ignore-unfixed 加 .trivyignore；预热度缓存或 --skip-db-update 配离线库 → 详见：07-cks/04-supply-chain-security.md#常见坑
- **现象**：配了 admission webhook 后全集群建不了 Pod，甚至 apiserver 起不来 → 先查：fail-closed 后端不可达——先 patch failurePolicy: Ignore 降级再排障，事后回滚 → 详见：07-cks/04-supply-chain-security.md#常见坑
- **现象**：distroless Pod CrashLoop 无从排查（exec 报无 sh） → 先查：kubectl debug 临时容器注入排障现场 → 详见：07-cks/04-supply-chain-security.md#常见坑
- **现象**：audit.log 一直是空文件；审计日志量爆炸打满磁盘 → 先查：policy 文件 flag + volumeMount 缺一不可；watch 用 None、Secret 记 Metadata 三限位 → 详见：07-cks/05-monitoring-auditing-runtime.md#常见坑
- **现象**：Falco 装完服务 failed；自定义规则不生效；k8s.pod.name 字段为空 → 先查：驱动不可用改 modern_eBPF；falco --validate 校验；只读挂 containerd.sock → 详见：07-cks/05-monitoring-auditing-runtime.md#常见坑
- **现象**：readOnlyRootFilesystem 后应用崩 → 先查：应用要写 /tmp、/var/log，emptyDir 挂必写路径，别回退只读 → 详见：07-cks/05-monitoring-auditing-runtime.md#常见坑
- **现象**：开启 Secret 加密后 apiserver CrashLoop；轮换后部分 Secret 解不开 → 先查：缩进/非 base64/key 非 32 字节；旧 key 删早了只能 etcd 快照恢复，按重写→验前缀→再删流程 → 详见：07-cks/06-secret-encryption.md#常见坑
- **现象**：开启加密后老 Secret 在 etcd 里仍明文 → 先查：加密只对新写入生效，全量重写（get -o json | replace），按 ns 分批 → 详见：07-cks/06-secret-encryption.md#常见坑
- **现象**：--cap-drop ALL 后 nginx 起不来；非 root 写 volume 报拒绝 → 先查：监听 80 需 NET_BIND_SERVICE（或改 8080）；卷初拷属主是 root，chown 后降权 → 详见：03-docker/06-security-best-practices.md#常见坑
- **现象**：seccomp/AppArmor/gVisor/Kata Pod 起不来（profile not found / cannot load / runsc 未注册） → 先查：profile 路径与节点放置；annotation 容器名精确匹配；RuntimeClass 键名与 handler 一致 → 详见：07-cks/02-system-hardening.md#常见坑

## 9 分布式与共识（ZK 脑旋 / 失 quorum / 脑裂双主 / 锁误删 / 时钟漂移）

- **现象**：ZK 的 `mntr`/`stat` 发过去没反应，`srvr` 却正常 → 先查：3.5+ 四字命令白名单默认只放行 `srvr`——配 `4lw.commands.whitelist`，或走 admin server 8080 的 HTTP JSON → 详见：16-bigdata/06-zookeeper.md#6.1 四字命令与 admin server
- **现象**：HBase/HDFS 频繁重新选主，ZK 的 Mode 频繁变化、latency 尖刺（脑旋） → 先查：JVM 长 GC / 事务日志盘 fsync 慢 / 网络抖动——dataLogDir 独立低延迟盘、堆给 3~4GB 缩 GC、对 Mode 变化做告警 → 详见：16-bigdata/06-zookeeper.md#6.3 脑旋与脑裂防护
- **现象**：ZK 加了一台节点，集群反而写不进了 → 先查：多数派从 2 变 3，滚动重启窗口凑不齐过半——一次只加一台、等它同步完成再动下一台；扩容走 3→5 跳过 4 → 详见：16-bigdata/06-zookeeper.md#6.5 扩容为什么必须逐台重启
- **现象**：业务报"锁丢了"但持有进程还活着 → 先查：会话被服务端判死（GC 停顿/网络分区），临时节点已删、新主已选出——会话超时按业务最长暂停调 + 下游 fencing token 拒绝旧持有者 → 详见：16-bigdata/06-zookeeper.md#4. watch 一次性触发与会话：最容易踩语义坑的地方
- **现象**：ZK watch 时灵时不灵，配置变更偶尔收不到通知 → 先查：watch 是一次性触发且会话过期后全部作废——收到事件立即"重注册+全量读"，或用 Curator Cache 类封装 → 详见：16-bigdata/06-zookeeper.md#4. watch 一次性触发与会话：最容易踩语义坑的地方
- **现象**：客户端写 >1MB 数据到 znode 报错，被误判为"ZK 不稳定" → 先查：`jute.maxbuffer` 默认 ~1MB 且客户端+全部服务端要同步调大；正确姿势是 ZK 只放指针、大内容放对象存储/DB → 详见：16-bigdata/06-zookeeper.md#6.2 jute.maxbuffer：大 znode 的坑
- **现象**：ZK 集群起不来，日志报无法过半（unable to form quorum） → 先查：`dataDir/myid` 与 zoo.cfg 的 `server.N` 是否一一对应、起来的节点是否够过半、端口是否通 → 详见：16-bigdata/06-zookeeper.md#常见坑
- **现象**："集群健康"（进程都在）却持续报错 → 先查：健康检查要区分"进程在"与"过半在"——看 ZK 的 Mode、etcd `endpoint health`（它本身就是一次提交提案的写探针） → 详见：17-distributed/00-distributed-overview.md#1.3 部分故障：集群健康不是 0/1
- **现象**：跨节点日志"应答的时间比请求还早"，事件顺序拼不出来 → 先查：三步对表法量出偏差量再读时间线；关键链路用 trace_id/offset/revision 串联，别用墙钟排序 → 详见：17-distributed/01-failure-models-and-time.md#5. 运维含义：日志时间戳对齐的坑
- **现象**：网络流量大盘突然出现尖刺，设备侧却无感知 → 先查：目标端时钟跳变让 rate() 的分母（样本时间戳差）错位——查 `node_timex_sync_status` 与 offset 斜率，排除后再谈容量 → 详见：17-distributed/01-failure-models-and-time.md#2.2 为什么监控看斜率、不看绝对差
- **现象**：节点反复"被判定宕机又回来"，依赖方跟着反复切主 → 先查：长 GC/慢盘造出的时序故障（ZK 脑旋元凶）——先治慢（缩 GC、独立日志盘），再谈调超时 → 详见：17-distributed/01-failure-models-and-time.md#常见坑
- **现象**：新节点加入集群被拒，报证书/授权失败 → 先查：该机时钟偏离导致证书校验不过——先修 NTP 再排证书链 → 详见：17-distributed/01-failure-models-and-time.md#常见坑
- **现象**："写完立刻读不到"工单被升级成集群故障 → 先查：五步排查先定性——读路径连的是谁（主/从/缓存）、什么一致性级别；串行读/本地读/读从库读到旧值是"按合同履约"不是故障 → 详见：17-distributed/02-consistency-models.md#5. 运维含义："读到了旧数据"先查一致性级别，再怀疑故障
- **现象**：把 ZK 当强一致读用，偶发读到旧配置 → 先查：ZK 默认本地读是顺序一致（可能旧值）——要"读己之写"先 `sync()`，或改走带版本号的 watch 通知 → 详见：17-distributed/02-consistency-models.md#3. 现实系统落位表
- **现象**：kubectl get 正常但 create/apply 全超时，apiserver 本身 Running → 先查：etcd 失 quorum（读走 watch cache 所以还通）——`etcdctl endpoint status` 数存活成员 vs quorum，先救一台别急重建 → 详见：17-distributed/03-consensus-and-replication.md#常见坑
- **现象**：控制面频繁切主、component 状态反复跳变，磁盘又没告警 → 先查：WAL fsync 慢 → 心跳/选举超时（脑旋）——etcd 独占低延迟盘、调大 election-timeout、对 leader 变化告警 → 详见：17-distributed/03-consensus-and-replication.md#常见坑
- **现象**：共识集群加了第 4 个成员，以为"更稳"了 → 先查：N=4 容错与 N=3 相同、确认成本反而更高——奇数原则，扩容走 3→5；etcd 先 `--learner` 追平再 promote → 详见：17-distributed/03-consensus-and-replication.md#2.2 N=3 容 1、N=5 容 2：两张账要分开算
- **现象**：消费者明明做了幂等还是出现重复订单 → 先查：只挡了"消息重投"，没挡"两个来源写同一业务键"（定时任务+消息并发）——最后一道防线永远在数据库唯一键约束上 → 详见：17-distributed/04-distributed-transactions.md#6. 幂等设计模式速查
- **现象**：Flink 作业频繁报事务超时 / 数据延迟可见 → 先查：`transaction.timeout.ms` ≤ checkpoint 间隔——调大事务超时或调小 checkpoint 间隔，且不超过 broker 的 `transaction.max.timeout.ms` → 详见：17-distributed/04-distributed-transactions.md#5.1 Flink：把 2PC 装进 checkpoint
- **现象**：版本号乐观锁用时间戳，偶发失效（旧写覆盖新写） → 先查：时钟回拨/漂移让版本回退——换单调递增整数或数据库自增，别用任何墙钟当版本 → 详见：17-distributed/04-distributed-transactions.md#常见坑
- **现象**：扩容后集群反而更慢/超时（Redis 迁槽、任何再平衡） → 先查：迁移流量撞业务高峰 + MIGRATE 大批次阻塞源节点单线程——低峰 + 小批量（10~100 key/批）+ 限速 + 可暂停 → 详见：17-distributed/05-sharding-and-rebalancing.md#4. 再平衡的运维代价与窗口选择
- **现象**：Redis 迁槽迁到一半放弃，整个集群写失败 → 先查：`cluster-require-full-coverage=yes` 下有槽无归属即整层拒写——要么完成要么显式 `SETSLOT` 归还，别留孤儿中间态 → 详见：17-distributed/05-sharding-and-rebalancing.md#常见坑
- **现象**：新加的 Kafka broker 空转，磁盘 0 增长 → 先查：分区是静态元数据，扩容不自动迁移老分区——KafkaRebalance（add-brokers）或 `kafka-reassign-partitions.sh` 显式搬 → 详见：17-distributed/05-sharding-and-rebalancing.md#常见坑
- **现象**："拿了 Redis/ZK 锁就认为绝对安全"，下游偶发重复扣款/发货 → 先查：zombie writer——旧持有者从长 GC 醒来继续写下游，quorum 管不到下游——下游加 fencing token 原子校验（只接受更大令牌） → 详见：17-distributed/06-gossip-membership-fencing.md#4.4 Fencing token：让旧主"写不进去"
- **现象**：SETNX 拿锁、释放时直接 DEL，删掉了别人的锁（双主开端） → 先查：自己已超时、锁已被新持有者接手——SET 带唯一 token + Lua 比对令牌再删 → 详见：17-distributed/06-gossip-membership-fencing.md#常见坑
- **现象**：lease 到期判定写在客户端本地时钟上，两侧同时认为自己持有 → 先查：NTP 步进/回拨——租约要服务端统一计时（etcd lease 模式）或单调钟；租约只能收窄僵尸窗口，清零靠 fencing → 详见：17-distributed/06-gossip-membership-fencing.md#4.3 租约 lease：有时限的授权
- **现象**：5 成员共识集群挂 3 台，同事提议"把剩下 2 台组成新集群继续写" → 先查：不可写≠丢数据——已提交条目在过半成员上大概率仍在；先抢修任一台，重组等于人为制造双写史 → 详见：17-distributed/07-distributed-troubleshooting.md#2. quorum 计算速查表
- **现象**：一半成员互相失联但各自"活着"，写超时集中在部分客户端（疑似脑裂） → 先查：从一台机器分别 ping/telnet 全部成员取分区证据；比对各成员 term/epoch 与 leader 认知（`endpoint status`/`srvr`/`rs.status()`） → 详见：17-distributed/07-distributed-troubleshooting.md#3.1 脑裂（分区两侧各自主）
- **现象**：etcd `proposals_failed_total` 持续上涨 / WAL fsync p99 抬高 → 先查：quorum 交互在失败（磁盘慢/网络/失多数派前兆）——`/metrics` 摘这两项，下一步 iostat await/util 查盘 → 详见：17-distributed/07-distributed-troubleshooting.md#1.1 写路径 = 协调者 → quorum 确认链

---

## 使用说明：配合 faults 靶场做限时演练

本索引与 `scripts/faults/`（12 个故障注入脚本，均支持 `--restore`）天然配套。标【靶场】的条目（共 12 条）都能还原成一次完整的"告警→定位→修复"演练。

### 单轮流程（每轮 15~20 分钟）

1. **随机挑一条**【靶场】条目（或直接 `ls scripts/faults/break-*.sh | shuf -n1`），**不看 FIXES.md 对应章节**。
2. **注入**：`sudo bash break-xxx.sh`（注入脚本会把原值备份到 /tmp，但演练时不允许靠 --restore 交作业）。
3. **只看现象排障**：计时开始，先说出"第一跳命令"（对照本索引的"先查"），再定位根因（指到具体对象/文件/参数），手工修复并验证。
4. **对照复盘**：展开 FIXES.md 对应故障章节，核对你的排查路径与标准路径的差异。
5. **恢复现场**：`sudo bash break-xxx.sh --restore`，然后 `kubectl get nodes && kubectl get pods -A | grep -Ev 'Running|Completed'` 确认全绿。

计分标准（满分 10）与进阶玩法（叠加注入、盲恢复、8 分钟限时、写 runbook、告警设计）见 `scripts/faults/FIXES.md#建议训练法：随机注入 + 限时排障`。

### 超出 12 个脚本的扩展演练

- **集群层综合**：`05-cka/labs/20-cluster-recovery-drill/task.md`——一次注入三重故障（DNS/RBAC/kubelet），按 check-list 逐个恢复。
- **应用层排障**：`05-cka/labs/15~19`（静态 Pod 修复 / kubelet NotReady / DNS / CrashLoop / 资源压力）。
- **中间件演练**：`11-middleware/*/labs/01-*`（MySQL 复制救援 / Redis 哨兵 failover / nginx 反代 HA / Mongo 副本集追平）。
- **可观测演练**：`09-otel/labs/03-demo-fault-tracing/task.md`（从 trace 定位注入的故障）。
- **方法论演练**：`13-sre-methodology/labs/02-chaos-drill/task.md`（完整混沌演练 + 无责复盘，路线 B 直接复用 break-dns-config.sh）。

### 日常使用姿势

- 值班/排障时：从分类目录跳到相近现象，先执行"先查"那条命令再决定下一步；命中后点开"详见"读完整推理。
- 复盘时：每处理一次真实故障，回来确认本索引是否已覆盖该现象；没有就回到对应章节的"常见坑"表补一行，再在本文件加条目（保持"只索引已验证内容"的纪律）。
- 学习时：与 ROADMAP.md 配合——ROADMAP 给"下一周学什么"，本文件给"学完后能处理什么现象"，两边的覆盖面应同步增长。

---

## 条目统计

| 分类 | 条目数 |
|---|---|
| 1 集群与控制面 | 16 |
| 2 网络与 DNS | 17 |
| 3 工作负载 | 14 |
| 4 存储与中间件 | 58 |
| 5 性能与资源 | 12 |
| 6 交付流水线 | 12 |
| 7 可观测 | 18 |
| 8 安全 | 15 |
| 9 分布式与共识 | 29 |
| **合计** | **191** |

其中标【靶场】（scripts/faults 可直接注入演练）的条目：12 条，与 FIXES.md 的 12 个故障一一对应。
