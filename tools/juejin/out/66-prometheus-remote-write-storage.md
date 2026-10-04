---
title_juejin: 'Prometheus 只留 15 天？是分工不是缺陷'
title_zhihu: 'Prometheus 只留 15 天不是缺陷是分工：remote write 与长期存储三条路怎么选'
description: 'Prometheus 只留 15 天是分工不是缺陷。硬调 retention 的代价、remote write 四个坑、Thanos/VictoriaMetrics/Mimir 三条路，一篇算清。'
category_id: "6809637769959178254"
tags: "后端,运维"
column_id: "7686472562230312970"
---

# Prometheus 只留 15 天？是分工不是缺陷

一个典型案例：审计要查三个月前的容量数据，Grafana 一片空白。新同事当天把 --storage.tsdb.retention.time 从 15d 改成 400d。两周后磁盘告警，一个跨 30 天的面板查询把内存顶到重启——旧问题没解决，添了新事故。

他错在把「数据不够久」当成 retention 参数的问题。**Prometheus 只留 15 天不是缺陷，是分工。**本地 TSDB 只负责「最近的、热的、单机的」；要一年，走 remote write，交给专门的长期存储。

这篇算清四件事：别硬调 retention 的理由、remote write 的代价、三条路的赌注、最小方案。

## 一、15 天是设计出来的：TSDB 的账本

先看写入路径：样本先进内存中的 head block（2h 一个窗口），同时顺序追加写 WAL；每 2h 截断，head 持久化为磁盘上不可变的 block；后台 compaction 合并相邻小块；retention 到期，整块删除——默认 15d。

三个设计决定，每一个都指向短保留：

第一，**索引住在内存里**。样本数据能随 chunk 落盘，倒排索引没有这个待遇——时序越多索引越大，而且常驻内存。

第二，**删除只到块级**。没有「只删某 10 分钟数据」这种粒度，想例外只能开 admin API 写 tombstone。

第三，**块大小跟着 retention 走**。compaction 合并的上限受 --storage.tsdb.max-block-duration 约束，默认取 31d 与 retention 的 10% 中较小者（以 --help 输出为准）。

retention 改 400d，10% 算出 40d，但被 31d 封顶——块照样长到一个月，查询一次扫一大块，峰值内存和耗时不商量。

所以调大 retention 不是「多留几天」这么轻：磁盘线性涨、块变大、查询变贵。【从业者判断】大块查询时的索引加载还会拉高峰值内存——正是开头那类重启的机制。

更根本的一条：Prometheus server 不集群化，两个实例互不知道对方。HA 的标准姿势是双实例同抓、Alertmanager 按指纹去重，代价是样本量翻倍。数据层复制与容灾，官方从没打算做进 server。**单机 Prometheus 是采集加短期缓存，不是数据库。**

看自己环境的真实值：

```bash
# 看 Prometheus 实际生效的 retention 与 TSDB 参数
kubectl -n monitoring port-forward svc/prom-stack-kube-prom-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/status/flags | python3 -m json.tool | grep -iE 'retention|storage.tsdb'
# 预期：storage.tsdb.retention.time 当前值（chart 默认与官方 15d 不同，以 flags 输出为准）
```

## 二、remote write：机制一句话，代价四个坑

机制：抓取与本地存储照旧，同时每个样本进 remote write 队列攒批外发。

```yaml
# prometheus.yml 片段：样本转发到远端接收端
remote_write:
  - url: http://thanos-receive:19291/api/v1/receive
    queue_config:
      max_samples_per_send: 5000
```

代价才是重点，按疼的程度排：

**坑一：写放大。**本地已经 WAL、head、block 写足一套，remote write 再把样本读出来外发一遍。【从业者判断】落盘一份、外发一份，磁盘 IO 与 CPU 在原有基础上加码。

**坑二：队列住在内存。**样本等待发送的每一秒都占内存。【从业者判断】样本洪峰叠加远端变慢，队列堆高——内存压力曲线和高基数事故是同一条，head series 高的集群先顶不住。

**坑三：丢数据窗口。**【从业者判断】队列是内存缓冲不是磁盘保险箱：远端持续不可用、队列堆满之后，新样本直接丢，而且没有断点续传——对象存储一次 20 分钟故障，可能换来永远补不回来的窟窿。持久化队列能把缓冲挪到磁盘。

**坑四：分片。**远端是集群时写要摊开。抓取侧的老办法是 relabel 的 hashmod；【从业者判断】shuffle sharding 是接收侧更细的分法：每个发送方只看见远端的一个子集，坏一个分片只伤一部分数据。中小规模先知道名字即可。

两条自监控查询建议进大盘（【从业者判断】，以实际 /metrics 为准）：

```promql
# 队列中等待发送的样本数（内存压力信号）
prometheus_remote_storage_samples_pending

# 发送失败样本速率（网络与远端问题的第一信号）
rate(prometheus_remote_storage_samples_failed_total[5m])
```

**队列一满，丢的是数据，不是背压。**remote write 的一切调参，都是在缩这个窗口。

## 三、三条路：Thanos、VM、Mimir 各押一个赌注

### Thanos：押对象存储是终点

【从业者判断】标准形态：sidecar 挂在 Prometheus 旁，把每 2h 落盘的 block 原样上传对象存储；查询经 Query 聚合本地与远端；Store Gateway 从对象存储读块。

先立两条硬事实：其一，**降采样是 Thanos 的特性**——核心 Prometheus 的 compaction 只合并不降采样；其二，Thanos Receive 是 remote write 的合法接收端。

降采样是它最值钱的牌：远期数据预聚合成粗粒度，查一年趋势不用扫原始样本。

赌注：把「一年」外包给对象存储，代价是组件多、要人养。sidecar 模式经本地块再上传；receive 模式换成推送链路，接收集群又成了运维对象。【从业者判断】

### VictoriaMetrics：押换引擎就够

【从业者判断】不动抓取层，remote_write 指过去，它作为替换存储引擎收全量样本，PromQL 兼容。卖点是压缩率、单机可撑的规模、以及写入侧去重——双实例 HA 的两份数据写时就合成一份存。

赌注：不搞组件拼装，一个更强的引擎吃下全部。代价是生态位偏存储而非平台，多租户的大规模故事不如 Mimir 完整。【从业者判断】

### Mimir：押读写分离的分布式

【从业者判断】Grafana 系后端，读写路径分离、组件各自扩缩，接收 remote write，对象存储兜底，查询前端带缓存与拆分。

赌注：为多集群多租户的规模预制架构。代价是组件数量——给几十个集群的场景设计，小团队上 Mimir 是拿航母钓鱼。【从业者判断】

| | Thanos | VictoriaMetrics | Mimir |
| --- | --- | --- | --- |
| 核心动作 | 块上传对象存储 | 换存储引擎 | 读写分离分布式 |
| 独门特性 | 降采样 | 写入去重、高压缩 | 多租户、查询前端 |
| 起步复杂度 | 中（三组件起） | 低（单实例） | 高 |

注：双实例去重三条路都管（Thanos Query / Mimir / VictoriaMetrics 的 dedup）。

**三条路的共同点：别让单机 Prometheus 干它不擅长的事。**

## 四、federation 和 remote read：两条用错就穿帮的旧路

federation 的语义先背死：下游 Prometheus 拉上游 /federate 端点，每次只取每个序列的**当前值**（instant），match[] 指定要哪些序列，成本极低。

```yaml
# federation：全局 Prometheus 只收各团队聚合结果
scrape_configs:
  - job_name: federate
    honor_labels: true            # 保留上游 job/instance 等标签
    metrics_path: /federate
    params:
      'match[]':
        - '{job="demo-app"}'
        - '{__name__=~"job:.*"}'  # recording rule 的命名惯例
    static_configs:
      - targets: ['team-a-prom:9090', 'team-b-prom:9090']
```

死穴同样明确：只传 instant 值、依赖下游持续在线、**不能补历史**。上游挂 10 分钟，那 10 分钟在全局库里永远缺。

经典对照：三个机房各一套 Prometheus，公司要「QPS、错误率、P99」的全局大盘——federation 拉 recording rule 结果，每 15s 几个 instant 值，成本几乎为零；换成「近一年数据可查」的审计——remote write 逐条转发。两者成本差数个量级。

remote read 是另一个方向：查询时把远端存储当本地的延伸。【从业者判断】它只把查询里的 selector 下推到远端、拉回匹配的原始序列，PromQL 求值仍在本地；延迟不可控、边界语义有出入，实践中很少当主路径。

**federation 是汇报，remote write 是搬家。**用汇报干搬家的活，一定在断网那天穿帮。

## 五、成本账：便宜和方便不在同一侧

**对象存储省在每 GB，贵在每次查询。**【从业者判断】单 GB 月成本比 SSD 低一个数量级，但查一个月前的数据要把块拉回来解压——缓存一冷，面板等几十秒。降采样救远期，近一个月的原始粒度仍是热路径。

**双实例 HA，远端存双份。**样本量翻倍，两份有细微时间差，全局视图靠 dedup——写入时还是查询时去重，账单差一截：VM 押前者，Thanos/Mimir 押后者。【从业者判断】

全量迁移的隐性成本清单（【从业者判断】）：

```text
1. 出口带宽：全量样本再推一遍，跨机房时尤其疼
2. 接收端资源：远端收、存、查都要算力，不是免费的
3. 查询习惯：Grafana 数据源逐个换，面板逐个验证
4. 过渡期双跑：新旧并行阶段，两边的钱都在花
5. recording rule 去哪算：本地算完转发或远端重算，基数与语义都会变
```

**只算对象存储单价的人，最后都在查询超时那天补课。**retention 的账在本地盘上，remote write 的账在链路两端。

## 六、中小规模：四道判断题选出最小方案

按顺序问，问到一个就停：

第一题：过去 90 天，真有人查过 15 天以前的数据吗？【从业者判断】多数团队答案接近零——要治的是「万一要查」的焦虑，不是存储。补好 recording rule 和告警便宜两个数量级。什么都不做，也是方案。

第二题：要长期的是全量还是十几个聚合指标？只要后者：federation 拉聚合值到一个全局 Prometheus，给这台开长 retention——【从业者判断】量小，单机扛得住。要全量回溯：remote write。

第三题：单集群还是多集群？单集群、几百个 target 量级：Thanos sidecar（已有对象存储则顺理成章）或单机 VictoriaMetrics，一天就能起步。【从业者判断】

第四题：有没有专人长期养它？没有：组件越少越好，单实例 VM 是底线方案；Thanos 全家桶要人，Mimir 更要人。【从业者判断】有人担心 VM 单机是单点——是，但远端挂掉伤的是历史数据，实时抓取、本地 15 天与告警都还在本地实例上，故障半径不同。

**先问「谁会在第 16 天查数据」，再问「用哪家存」。**顺序反了，就是给不存在的需求付钱。

## 现在就能做的三件事

第一，确认你此刻的真实 retention 与块参数（很多人从没看过）：

```bash
kubectl -n monitoring port-forward svc/prom-stack-kube-prom-prometheus 9090:9090 &
curl -s http://localhost:9090/api/v1/status/flags | python3 -m json.tool | grep -iE 'retention|storage.tsdb'
# 预期：storage.tsdb.retention.time 的当前值；max-block-duration 若显示 0s
# 表示未显式设置（自动取 min(31d, retention 的 10%)，见第一节公式）
```

第二，算出日样本量，这是任何长期存储方案的入参：

```promql
# 每秒入库样本数，乘 86400 即日样本量；再乘单样本字节数即日增量
rate(prometheus_tsdb_head_samples_appended_total[5m])
```

第三，把第六节的四道判断题带进周会，尤其第一题——让每个说「要长期存储」的人报一个真查过 15 天前数据的场景。

federation 与 remote_write 的对照表、TSDB 从 WAL 到 block 的生命周期、HA 两层去重的完整推导，都在我的学习仓库：GitHub 搜 sre-learning-hub。

评论区报个数：你们的 retention 是几天、上了哪条路？我想验证一个判断——口口声声「需要一年数据」的团队，真查过第 16 天数据的不到一成。
