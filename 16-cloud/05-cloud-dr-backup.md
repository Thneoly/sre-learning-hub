# 05 · 云上容灾与备份：跨 Region、跨账号与恢复演练

> 模块：16-cloud ｜ 建议时长：3 小时 ｜ 关联认证：—（无直接考点；与 05-cka etcd 备份、15-sre-methodology 第 7 章联动） ｜ 前置：第 01、04 章

## 学习目标

- 能设计一套跨 Region 异步容灾方案（数据复制、容灾站最小可用集、DNS 切换三件套），标注每件的 RPO/RTO 贡献
- 能说清快照与备份的关系（增量链、一致性组），以及"跨账号备份"防的具体故障
- 能组织一次云上恢复演练：快照建盘拉起临时环境、跨 Region 副本拉回验证、演练后清场
- 能把云监控/CloudWatch 指标 remote write 接入自建 Prometheus，统一告警体系
- 能给关键配额（vCPU、快照数、带宽）配告警，不让"扩容时刻"变成"配额打满时刻"

## 1. 跨 Region 异步容灾：多 AZ 之上的最后一层

第 01 章已论证：多 AZ 抗机房级故障，性价比最高；但 Region 级灾难（骨干网瘫痪、区域级服务故障、合规要求数据异地）只能靠跨 Region。云上的跨 Region 容灾有三件套：

```
  主 Region（cn-hangzhou）                容灾 Region（cn-shanghai）
┌──────────────────────┐   异步复制      ┌──────────────────────────┐
│ OSS/S3 主桶          │ ═══RPO 分钟级══►│ 副本桶（跨区域复制 CRR）  │
│ RDS 主库             │ ══跨Region备份═►│ 备份集/只读副本           │
│ ACK/ECS 全量承载     │                │ 最小可用集（IaC 按需拉起） │
└──────────┬───────────┘                └────────────┬─────────────┘
           │                                         │ 切换是人工决策：
      全局 DNS / GTM ────健康检查───────►  故障时改解析指向容灾站（15 模块 07 章的
                                              "异地切换必须人拍板"：异步复制=切过去要丢数据）
```

三件套的分工与代价：

| 组件 | 手段 | RPO 贡献 | RTO 贡献 | 成本 |
|------|------|---------|---------|------|
| 数据 | OSS/S3 跨区域复制、RDS 跨 Region 备份、DTS/同步工具（自建库） | 分钟级（复制延迟） | — | 复制流量费+存储费 |
| 计算 | 容灾站最小可用集：IaC 模板按需拉起（冷）/ 常备小规模（热） | — | 小时级（冷）/ 分钟级（热） | 冷≈0，热≈10%~30% 生产 |
| 入口 | GTM/Route53 健康检查 + 解析切换 | — | 分钟级（TTL 生效） | 低 |

设计要点三条：**数据先行**——先保证"数据在异地且可用"，再谈拉起（没有数据副本的计算层是装饰）；**最小可用集**——容灾站只保"核心链路能收款"，报表、后台、全量副本不进第一梯队（15 模块 07 章的分层思想）；**演练切换**——DNS 切换、跨 Region 数据校验必须演练过，否则与没有无异。

## 2. 快照与跨账号备份：防"连生产一起死"的最后一道

### 2.1 云盘快照的正确打开方式

快照是块存储某个时刻的整盘镜像（首次全量、后续增量链）。两个必须懂的性质：**一致性靠你自己**——裸拍快照拿到的是"崩溃一致性"（像断电），数据库类要先用应用层手段冻结写入（fsfreeze、FLUSH TABLES WITH READ LOCK，或直接用厂商的"应用一致性快照"功能，以文档为准）；**增量链依赖前序**——删除被依赖的早期快照会触发合并，不会丢数据但计费与删除策略要理解（保留 N 份的含义是"时间窗"不是"N 个独立文件"）。

### 2.2 跨账号：备份的"第二身份"

生产账号被勒索软件攻陷时，攻击者拿到的是生产账号凭据——**与生产同账号的备份会被一起加密/删除**。跨账号备份让备份拥有独立身份：

```text
生产账号（只能"推"备份，读不回删不了备份桶）
   │  跨账号复制（备份账号的桶授权生产账号写入）
   ▼
备份账号（专用，平时无人登录，MFA+审计，只读放行给恢复流程）
   └─ 对象存储：版本化 + WORM/合规保留（改不了删不掉，锁一段时间）
```

- **版本化（versioning）**：误删/覆盖变成"新增一个版本"，随时回滚——对象存储侧的免费后悔药。
- **WORM/合规保留**（S3 Object Lock / OSS 的合规保留策略）：在保留期内连桶主都删不掉，勒索软件也无可奈何。
- **权限不对称**：生产账号对备份桶只有写权限；恢复演练账号单独授权。这与 01 章 §4 多账号"爆炸半径隔离"一脉相承。

### 2.3 数据分层备份菜单

| 数据 | 云侧手段 | RPO | 防什么 |
|------|---------|-----|--------|
| 对象存储 | 跨区域复制 + 版本化 + 跨账号副本 | 分钟级 | Region 故障、误删、勒索 |
| 数据库（托管） | 自动备份 + 跨 Region 备份复制 + binlog | 秒~分钟级（PITR） | 误操作（回到指定位点，位点机制见 [mysql/02 章](../13-middleware/mysql/02-backup-replication.md)） |
| 云盘/文件系统 | 快照（定时策略）+ 快照跨 Region 复制 | 小时级 | 宿主级故障、误配置 |
| K8s 控制面 | etcd snapshot（[05-cka/04 章](../05-cka/04-etcd-backup-restore.md)）异地存放 | 依赖快照频率 | 集群级故障 |
| 配置/IaC | git 远端 + state 的版本化后端 | 即时 | "谁改的、改回去" |

## 3. 恢复演练：云侧的 drill

[15-sre-methodology/07 章](../15-sre-methodology/07-dr-business-continuity.md) 定义了 drill 的通用纪律（找得到/读得出/恢复得了/恢复得对）。云侧特有的四个动作：

1. **快照→新盘→临时机验证**：在隔离 VPC 用快照建盘、拉起临时 ECS，跑校验脚本——不要在生产网内"就地恢复"（二次伤害风险）。
2. **跨 Region 副本对账**：列两个桶的对象清单比对（数量+ETag 抽样），别等灾难时才发现复制规则上个月就被改坏了。
3. **RDS 从跨 Region 备份拉临时实例**：验证的不只是"能恢复"，还有"恢复出的账号/白名单/参数组在容灾站网络里真的连得上"。
4. **清场计费**：演练拉起的按量资源用完即删，演练清单里写明销毁步骤与预计费用上限——忘记删除的按量实例是账单爆炸头号原因（01 章 §3）。

频率建议：对象对账月度自动化、快照恢复季度一次、全链路切换（含 DNS）年度 GameDay 并测出实测 RTO/RPO。

## 4. 云监控接入要点：统一观测与配额告警（小节）

### 4.1 remote write：把云指标接进自建 Prometheus

自建 Prometheus + Grafana + Alertmanager（10-pca 体系）已是统一告警入口，云资源指标（RDS 连接数、SLB 后端健康、ECS 水位）也应汇进来，避免"一半告警在云监控、一半在 Alertmanager"的双体系漂移。接入方向有两条：

```yaml
# [文件 prometheus-extra.yaml 片段] 方向一：云监控 → 自建 Prometheus（接收端）
# 自建 Prometheus 要先打开接收能力（Prometheus CR 的 enableRemoteWriteReceiver），
# 云侧（阿里云云监控企业版 / AWS CloudWatch Metric Streams + 转换器）把指标推过来；
# 入口与限制以两家官方文档为准
spec:
  enableRemoteWriteReceiver: true
```

```yaml
# [文件 prometheus-extra.yaml 片段] 方向二：自建 Prometheus → 云端（发送端）
# 把自建指标也存一份到托管存储（阿里云 ARMS Prometheus / Amazon Managed Service
# for Prometheus），跨集群聚合时常用
remoteWrite:
  - url: https://<托管存储的远程写端点>/api/v1/write
```

要点：接收端要显式开启（Prometheus 默认只是发送方）；跨账号/跨网要打通网络与鉴权（云厂商通常给专门的接入端点）；**接入后就该裁剪**——只留会进告警与面板的指标，全量搬运是流量与存储的双重浪费。

### 4.2 配额告警：扩容时刻的隐形天花板

弹性伸缩（第 04 章）把"加资源"变成自动动作，但配额不会跟着伸：按量 vCPU 配额、快照数量、ENI/公网带宽、API 速率限制——**伸缩组最卖力的时刻恰恰是配额打满的高发时刻**。三道防线：

- 配额中心集中看板：阿里云配额中心 / AWS Service Quotas + Trusted Advisor。
- 阈值告警：配额使用率 > 80% 告警（两家配额产品都支持，入口以文档为准）。
- 巡检兜底（CLI 定期查询，结果推给 12 章的日志通道）：

```bash
# [任意节点] 阿里云：查询 ECS 配额（产品与 API 以配额中心文档为准）
aliyun quota ListProductQuotas --ProductCode ecs | jq '.quotas[] | select(.quotaArn!=null) | {name, value, used}'
# AWS：查 EC2 配额（记得先 aws configure）
aws service-quotas list-service-quotas --service-code ec2 --query 'Quotas[?UsageMetric].{name:QuotaName,value:Value}' --output table
```

大促/重保前的容量评审（21 章的方法）里，配额单必须与压测报告一起过——压测打满的是测试环境配额，生产配额要单独确认。

## 实战演练

环境：kubeadm 集群 + kube-prometheus-stack（演练 A）；演练 B 纸面；演练 C 需云账号（可选）。

### 演练 A：给自建 Prometheus 打开 remote write 接收（10 分钟）

```bash
# [master] 找到 Prometheus CR 并打开接收端（operator 会调和出 --web.enable-remote-write-receiver）
PROM_CR=$(kubectl -n monitoring get prometheus -o jsonpath='{.items[0].metadata.name}')
kubectl -n monitoring patch prometheus "$PROM_CR" --type merge -p '{"spec":{"enableRemoteWriteReceiver":true}}'
kubectl -n monitoring get prometheus "$PROM_CR" -o jsonpath='{.spec.enableRemoteWriteReceiver}'; echo
```

```bash
# [master] 验证接收端已生效：POST 一个空报文，开启时是 400（报文非法），未开启是 404
kubectl -n monitoring port-forward svc/prom-kube-prometheus-stack-prometheus 9090:9090 &
sleep 5
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:9090/api/v1/write
kill %1
```

预期输出 `true` 与 `400`。这个端口就是后续云监控/CloudWatch 指标流的落点；恢复现场可把 `enableRemoteWriteReceiver` 改回 `false`（或保留，接收端本身无风险）。

### 演练 B：纸面设计——给"学习中心门户"配云上容灾（20 分钟）

按第 1、2 节的菜单填这张表（参数写依据，画不出依据就写"待压测/待确认"）：

```text
资产            复制/备份手段                RPO    RTO     跨账号？
静态资源(OSS)   跨区域复制+版本化            ?      ?       ?
数据库          自动备份+binlog+跨Region复制  ?      ?       ?
镜像/Chart      仓库双活/异地副本            ?      ?       ?
K8s 清单        git 远端（07-cd-gitops）     即时    分钟    —
入口            GTM 健康检查切换             —      ?       —
```

自检三问：切到容灾站时丢多少数据（把复制延迟×写入速率换算成"条数"而不是"分钟"）？恢复演练上次是什么时候、报告在哪？备份账号的凭证现在放在哪、谁能用？

### 演练 C（可选，有云账号）：一次最小的跨 Region 对账（15 分钟）

```bash
# [任意节点] 在两个 Region 各建一个桶、上传对象、开跨区域复制规则后对账
# 建桶与上传沿用 02 章 §5 的手法；跨区域复制规则的创建入口在 OSS 控制台"数据复制"
# 或 PutBucketReplication API（参数以 oss 官方文档为准）
SRC=demo-hub-src-$(date +%s)
aliyun oss mb oss://$SRC --endpoint oss-cn-hangzhou.aliyuncs.com
aliyun oss cp /etc/hostname oss://$SRC/ --endpoint oss-cn-hangzhou.aliyuncs.com
# ……配置复制规则（源桶 → 目标桶 cn-shanghai），等 1~2 分钟后比对两侧行数
aliyun oss ls oss://$SRC/ --endpoint oss-cn-hangzhou.aliyuncs.com | wc -l
aliyun oss ls oss://<目标桶>/ --endpoint oss-cn-shanghai.aliyuncs.com | wc -l
```

预期：两行计数一致（复制有延迟，等 1~2 分钟）。收尾：删除两个桶（`aliyun oss rm oss://<桶>/ -rf`，跨 Region 复制的流量费与目标桶存储费在删除后停止）。

## 常见坑

| 症状 | 原因 | 解法 |
|------|------|------|
| 灾难时才发现跨区域复制规则早已失效 | 复制是"配置后无人看"的状态，规则被改/目标桶删了都没告警 | 月度对账自动化（清单数量+抽样 ETag）+ 复制失败事件的告警 |
| 从快照恢复的数据库起不来/丢事务 | 快照只保证崩溃一致，裸拍时写入未冻结 | 数据库用应用一致性快照/托管备份；自建先 FLUSH+fsfreeze |
| 勒索事件中备份和生产一起被加密 | 备份与生产同账号同凭据，"只读"没落实 | 跨账号+版本化+WORM；生产账号对备份桶只有写权限 |
| 容灾演练一次后环境没删，月底账单翻倍 | 演练拉起的按量资源（ECS/带宽/临时 RDS）遗忘 | 演练清单含销毁步骤与费用上限；ttl 标签巡检（02 章） |
| 云监控告警与 Alertmanager 各报各的 | 双体系：阈值、值班、静默互不知晓 | 单一告警入口（remote write 汇聚到自建体系或全托管二选一） |
| 大促扩容失败：配额打满 | 伸缩组在洪峰时刻撞上按量 vCPU/快照数配额墙 | 配额使用率 80% 告警 + 容量评审过配额单（4.2 节） |
| 切到容灾站后连不上数据库 | 白名单/安全组/参数组没有跟着"异地"重建 | 演练覆盖"容灾站网络可达性"，不是只验数据存在 |

## 自测

1. 跨 Region 复制给了你 RPO=5 分钟的承诺，切站时为什么可能仍丢 20 分钟数据？
<details><summary>答案</summary>

复制延迟 5 分钟是"稳态"数字。故障发生前的大流量写入会把复制积压拉长（异步复制按带宽追赶）；复制链路本身抖动、目标端限流时延迟还会进一步放大。切站丢的数据量=切换时刻的**实际复制延迟**，不是标称值。工程上要以"复制延迟"为监控项（15 模块 02 章的领先指标思想），延迟超阈值就告警——它就是你的真实 RPO。
</details>

2. 为什么"备份在生产账号里设置了只读权限"不算防勒索，而跨账号+WORM 算？
<details><summary>答案</summary>

攻击者拿到的是账号级凭据（AK 或 RAM 身份），账号内的"只读"只是权限语句——同一账号的管理员/root 权限或权限提升路径仍可改桶策略、开删除、直接加密对象。"只读"防的是善意误操作，防不了持钥匙的人。跨账号把钥匙分开（备份桶主只有备份账号的 IAM 能操作，生产侧凭据拿不到删除权），WORM 再补一刀：保留期内**任何身份**（包括桶主）都无法删除/覆盖。纵深防御的层次：权限分离挡"拿错钥匙"，不可变存储挡"拿了钥匙也毁不了"。
</details>

3. 容灾站选"冷备（IaC 按需拉起）"还是"热备（常跑最小可用集）"，怎么量化决策？
<details><summary>答案</summary>

三个变量：RTO 要求（冷备=小时级：拉起+数据挂载+预热；热备=分钟级：只切流量）、成本差（热备≈生产 10%~30% 常年烧着，冷备≈0+演练成本）、恢复可靠度（热备持续在跑=持续被验证，冷备的 IaC 与镜像会腐烂，必须靠更频繁的演练维持）。量化法：热备年成本 vs (故障概率×冷备 RTO 拉长期间的损失)。核心链路（收款、下单）几乎总是值热备；长尾系统用冷备+每年演练。
</details>

4. 云监控的指标已经在云厂商控制台能看了，为什么还要 remote write 进自建 Prometheus？
<details><summary>答案</summary>

看是能看，但告警体系分裂了：自建侧的燃烧率告警、值班路由、静默策略（10-pca 的 Alertmanager 体系）管不到云监控里的告警，反之亦然——两套阈值、两组值班、两次静默，事故时互相打扰或互相指望。汇聚到一处后：统一面板（业务 SLI 与 RDS 连接数同屏）、统一告警分级与路由、统一记录（告警历史可进复盘）。代价是指标裁剪与网络打通的成本——所以决策标准是"这些指标要不要进告警/面板"，要就接，不要就别搬。
</details>

5. 你的伸缩组在早高峰报 "Instance Limit Exceeded"，扩容失败。复盘要查哪几层？
<details><summary>答案</summary>

四层：①账号/Region 的按量 vCPU 配额是否打满（4.2 节的配额告警缺失是根因候选）；②所选机型在该 AZ 是否有按量库存（换 AZ 或机型，01 章 §2 的多 AZ 设计此时兑现）；③伸缩组 MaxSize 是否设小了（组级上限常被遗忘）；④是否人为冻结/暂停了伸缩活动（重保期常见）。修复后补防线：配额 80% 告警、库存不足事件的自动换型（Karpenter/多机型节点池）、MaxSize 与容量评审联动。
</details>

## 延伸阅读

- S3 跨区域复制与多 Region 官方指南：https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication.html
- OSS 产品文档（跨区域复制/版本化/合规保留，目录内检索对应主题）：https://www.alibabacloud.com/help/zh/oss/
- AWS Backup 跨账号备份（备份账户架构官方做法）：https://docs.aws.amazon.com/aws-backup/latest/devguide/cross-account-backup.html
- Kubernetes 官方 · Monitoring Architecture（remote write 的协议位置）：https://kubernetes.io/docs/concepts/cluster-administration/monitoring/
- Prometheus 官方 · remote write receiver 与配置：https://prometheus.io/docs/prometheus/latest/configuration/configuration/#remote_write
- AWS Service Quotas / 阿里云配额中心：https://docs.aws.amazon.com/servicequotas/latest/userguide/ ｜ https://www.alibabacloud.com/help/zh/quota/
