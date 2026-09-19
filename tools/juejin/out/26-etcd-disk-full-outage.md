---
title_juejin: etcd 磁盘写满的那 6 分钟：控制面是怎么一步步瘫的
title_zhihu: etcd 磁盘写满的那 6 分钟：控制面是怎么一步步瘫的
description: etcd配额2GB打满即触发NOSPACE转只读：apiserver拒写、kubectl超时、CI卡死，已有Pod却照常服务。拆解6分钟瘫痪连锁，附defrag姿势与水位告警。
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686472562230312970"
---

# etcd 磁盘写满的那 6 分钟：控制面是怎么一步步瘫的

> 周五 16:52，一条没人订阅的日志在 etcd 里响起：`message exceeded backend quota; raising alarm`。六分钟后控制面全面瘫痪——kubectl 超时、CI 卡死、扩缩容失灵。业务侧的反馈却是：Pod 一个没死，流量正常。

## 一、时间线：16:52 拉响，16:58 瘫完

3 master 的 kubeadm 集群，etcd 数据盘 50GB，backend 配额还是默认 2GB。新上线的自愈 Agent 每逢探活失败，就把含堆栈上下文的大段报文整段写进 CRD 的 status——常态每天数百次、探活失败风暴时阵发冲到每分钟数十次，上线不到一周就把配额吃贴；审计与容器日志还挤在同一块盘上涨。

| 时间 | 事件 | 当时的判断 |
| --- | --- | --- |
| 16:52 | etcd 日志 `exceeded backend quota; raising alarm`（NOSPACE），拒写 | 无人在看——告警打的是 apiserver 超时 |
| 16:54 | `kubectl get` 变慢，apply 大面积超时，CI 卡死 | 误判一：当 apiserver 挂了，提议重启 |
| 16:58 | 重启无效；已有 Pod 正常，但无法扩缩容/新建 | 误判二：当网络问题，查 LB/防火墙 |
| 17:10 | `alarm list` 返回 NOSPACE；`df` 91% | 定位：配额+磁盘双重打满 |
| 17:25-17:40 | compact → 逐成员 defrag → disarm；写入恢复，CI 排空 | 恢复 |

从 16:52 到 16:58，六分钟，控制面从一声没人听的告警走到全面瘫痪；`alarm list` 一锤定音则是 17:10——瘫痪 6 分钟，认清病因 18 分钟，中间 12 分钟都在给错误的对象做心肺复苏。

## 二、连锁：一根保险丝烧断整条街

### 先分清两把尺子

| 尺子 | 量什么（上限） | 当时读数 |
| --- | --- | --- |
| DB SIZE（`endpoint status`） | bbolt 数据文件，配额默认 2GB（以官方文档为准） | 贴着 2.0GB |
| `df` | 整块数据盘，50GB | 91% |

账很好算：1.8MB 的 status × 每天数百次 ≈ 每天几百 MB 的后端增长；历史 revision 不清理就无限累积——复盘原话："defrag/compact 从未纳入例行运维，历史 revision 无限累积"。旧版本为何保留属 MVCC 行为，不展开（【从业者判断】）。

配额盯的是 DB SIZE 这把尺子，所以它在磁盘还剩几 GB 时就先爆了——这正是第五节要补的盲区：只盯 `df` 不盯 DB SIZE。

### NOSPACE：烧的是保险丝，不是发动机

配额超限，etcd 干净利落：拉响 NOSPACE alarm，拒绝一切写入，整体转只读。alarm 经 Raft 复制，三个成员一起只读——证据：`alarm disarm` 要走一次 Raft 写，所以复盘里特意提醒"确认多数派健康后再做"。这是 etcd 的自我保护：宁可拒写，也不让数据文件无界增长——烧保险丝，是为了救线路。

### apiserver 拒写：变更能力集体归零

控制面的"变更能力"全靠写 etcd：create/apply、scheduler 绑节点、controller 更新 status、kubelet 报心跳，全是写。etcd 一只读，同时归零——时间线里的结论：调度、扩缩容、自愈全部停摆。

最讽刺的也在复盘记录里：连"自愈 Agent"都还在往害它的方向写——探活失败、写报文、写不进、重试、加剧瘫痪、更多探活失败，一个死亡螺旋。

### 为什么连 kubectl get 都超时

写命令死得最透，好理解；怪的是读也变慢——复盘记录实锤：`kubectl -v=8` 显示请求卡在 apiserver 到 etcd 的调用上。机制两层（【从业者判断】，复盘只记录了现象）：etcd 默认线性读，每次读先与多数派确认再返回；各组件的写请求失败后超时重试，重试风暴占着 apiserver 的处理能力，读跟着排队。

重启 apiserver 为什么无效？它没病，病在它的存储——重启健康组件是控制面故障最常见的无效动作，本案里值 4 分钟。

### 为什么一个业务 Pod 都没掉

数据面不依赖控制面实时可写：kube-proxy 的转发规则、容器运行时、CNI 都在节点本地照常工作。于是故障指纹出炉：**已有 Pod 正常 + kubectl 卡死 = 控制面问题，etcd 第一嫌疑人**——这条指纹值两次误判。

## 三、定位只要三条命令

```bash
# [master] kubeadm 默认证书路径
export ETCDCTL_API=3
E="--cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt \
--key=/etc/kubernetes/pki/etcd/server.key --endpoints=https://127.0.0.1:2379"

etcdctl $E endpoint status -w table   # DB SIZE：1.9~2.0GB，贴着配额
etcdctl $E alarm list                 # alarm:NOSPACE，一锤定音
df -h /var/lib/etcd                   # 91%，第二把尺子也快满
```

找写入大户靠的也是 `endpoint status`：RAFT INDEX 与 revision 都随写入同步增长，两次采样一减，即每分钟写入次数——风暴窗口里 revision 每分钟 +40，直接锁定那个 Agent；要拿精确 revision，用 `-w json` 输出里的 revision 字段（第四节 compact 取的就是它）——定位从不缺工具，缺的是想到去看。

## 四、恢复：顺序不能乱，defrag 会咬人

compact 没有撤销键，动手前先拍快照（复盘未记录此步，属笔者的保命建议）：

```bash
# E 见第三节
sudo mkdir -p /opt/etcd-backup
sudo etcdctl $E snapshot save /opt/etcd-backup/pre-compact-$(date +%H%M).db
# snapshot status 验：TOTAL KEYS 为 0 = 坏快照，重做
```

然后是恢复三步，顺序写死：

```bash
rev=$(etcdctl $E endpoint status -w json | grep -o '"revision":[0-9]*' | head -1 | cut -d: -f2)
etcdctl $E compact "$rev"     # 1 压缩历史 revision
etcdctl $E defrag             # 2 逐成员串行：换 --endpoints 再跑，别三台同时
etcdctl $E alarm disarm       # 3 确认多数派健康后再解除
```

同时下线 Agent 的大对象写入（改投 Kafka）、清理同盘日志——不做这两件，只是把爆炸日推后。

**defrag 为什么危险**：它在成员本地重建数据文件，进行期间该成员无法正常服务请求——三台同时 defrag 等于人为制造一次全集群不可用（【从业者判断】）。正确姿势：逐台做、做完一台 `endpoint health` 确认一台、避开高峰。defrag 落新文件还要磁盘余量，本案磁盘已 91%，先清日志再 defrag（【从业者判断】）。

**为什么 compact 完 DB SIZE 不动**：compact 只是把旧 revision 标记为可回收，bbolt 的空闲页还在文件内部，文件不会自己缩；把空间真正还给文件系统的是 defrag（【从业者判断】）。两步缺一不可：只 compact，配额依然贴顶；只 defrag，没有空洞可收。disarm 要放在腾出空间之后——空间没腾就解除，写请求涌回来等于原地再爆（【从业者判断】）。

长期治理：例行 compact（低峰定时）+ defrag（逐成员、避开高峰）纳入 runbook；etcd 不存大对象，大报文走消息系统只留索引；审计日志、容器日志与 etcd 分盘。

## 五、布防：两把尺子各自告警，阈值 70%

复盘最扎心的一句：磁盘告警阈值 90%，而 2GB 配额在 50GB 盘上永远先触发——若盘上只有 etcd 数据，配额爆表时磁盘占用才 4% 上下；本案磁盘之所以也被推高，是审计/容器日志同盘增长的结果（即便如此，配额仍先一步触发）。只盯 `df` 不盯 DB SIZE，等于给最重要的组件留盲区。

```yaml
# [master] kubectl apply -f etcd-capacity-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: etcd-capacity
  namespace: monitoring
  labels:
    release: prom-stack    # operator 靠它选规则
spec:
  groups:
  - name: etcd-capacity
    interval: 30s
    rules:
    - alert: EtcdDBSizeNearQuota
      # etcd >= 3.5 只导出新名 etcd_mvcc_db_total_size_in_bytes（旧名已移除）；
      # 仅 3.4 及更早用 etcd_debugging_mvcc_db_total_size_in_bytes（后期 3.4 两名并存）。
      # 上线前先在自己的 etcd /metrics 里实测选定指标名，照抄抄错会一条序列都匹配不到
      expr: etcd_mvcc_db_total_size_in_bytes > 1.5e9   # 配额 2GB 的 70%
      for: 5m
      labels:
        severity: critical
    - alert: EtcdDiskNearFull
      expr: node_filesystem_avail_bytes{mountpoint="/var/lib/etcd"}
            / node_filesystem_size_bytes{mountpoint="/var/lib/etcd"} < 0.3
      # for/labels 同上一条
```

两个细节别省：`for: 5m` 要求持续为真满五分钟才 firing，过滤抖动——为抢时效去掉它，换来的是一条很快被无视的狼来了；`release` 标签写错是 PrometheusRule"死活不生效"的头号原因。

第三道防线：把日志关键字 `exceeded backend quota` 配进日志告警——etcd 3.4/3.5 拉响 NOSPACE alarm 时打出的结构化日志是 `message exceeded backend quota; raising alarm`（3.3 及更早文案不同，以官方文档/实测为准）。建议在 apiserver 侧加配一条 `database space exceeded`——那是 etcd 拒写时返回给客户端的 NOSPACE 错误串，两边互相印证。水位告警是提前量，这条是最后通牒——它出现时，留给你的时间已按分钟计。

## 六、预答两个反方

**"把配额调大不就完了？"**（`--quota-backend-bytes`，以官方文档为准）保险丝换粗不等于线路修好：每天几百 MB 的增长速度不变，8GB 也只是把爆炸日从一周内推到两周左右。正解是 CRD 评审加单对象大小与更新频率红线，大报文走 Kafka、etcd 只留索引。

**"已有 Pod 都正常，不痛不痒。"** 控制面只读等于变更冻结：发不了版、扩不了容。此时再倒一台节点，连驱逐重建都做不了——调度也停了。控制面瘫痪不是"不影响业务"，是"业务从此不许变化"。

## 七、教训与 30 秒自检

| 要点 | 一句话 |
| --- | --- |
| 故障指纹 | 数据面无恙 + kubectl 卡死 = 控制面问题，etcd 第一嫌疑人 |
| 两把尺子 | DB SIZE 对配额、df 对磁盘，各自告警，阈值各 70% |
| 恢复与 defrag | compact → defrag → disarm；逐成员串行、避开高峰、先留磁盘余量 |
| 源头治理 | 每次写入都问一句"这东西配进 etcd 吗" |

现在就能做：登录 master，跑第三节那三条命令。DB SIZE 已在配额七成以上的，别等你的周五 16:52，今天就排 compact。

## 写在最后

最该记住的不是恢复命令，而是一个不对称：瘫痪 6 分钟，认清病因 18 分钟——不是值班不专业，而是控制面故障里人的直觉总是先怀疑组件、再怀疑网络、最后才怀疑存储。两条水位告警加一条日志关键字告警就能抹平它：让那声 NOSPACE 提前几天出现在值班群里。

时间线、恢复脚本与告警规则整理自我维护的开源学习库——GitHub 搜 sre-learning-hub，etcd 空间治理章节经真机验证；告警规则的骨架可直接抄进 runbook，但 expr 请先在自己的 Prometheus 里查一次再上线。
