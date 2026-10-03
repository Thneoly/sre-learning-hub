---
title_juejin: 一次 rebalance，全组停摆：Kafka lag 从 0 到百万的事故复盘
title_zhihu: 一次 rebalance，全组停摆：Kafka lag 从 0 到百万的事故复盘
description: Kafka rebalance 事故复盘：GC 停顿踢一人、停摆收全组，lag 冲到百万。拆四个触发面、poison pill 死循环，给静态成员、增量再平衡与增速告警的落地配置。
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686472562230312970"
---

# 一次 rebalance，全组停摆：Kafka lag 从 0 到百万的事故复盘

> 周五 22:14，支付回调组 pay-notify 的 lag 从 0 开始爬，23:40 破百万。86 分钟里 broker 零故障、生产零失败——摁停整条管道的，是消费者组自己的 rebalance 风暴。案情为构造典型案例，参数按 Kafka 3.x 口径。

## 一、时间线：broker 全绿，组瘫了

背景：12 分区 topic、3 个消费者实例、单条处理约 200ms，全部默认参数（max.poll.records=500、max.poll.interval=5min、session.timeout=45s）【官方，Kafka 3.x 默认值】。当晚批处理把写入顶到 2000 条/s。

| 时间 | 事件 | 当时的判断 |
| --- | --- | --- |
| 22:14 | 实例-2 Full GC 47s，心跳同停，超 session.timeout 被踢 | 无告警 |
| 22:15 | 整组 rebalance，全组停摆，lag 陡涨 | 误判一：MySQL 慢，扩连接池 |
| 22:17 | 实例-2 回归入组，再触发一轮 rebalance | 误判二：重启消费者 |
| 22:21 | 幸存实例 poll 到异常消息，单批超 5 分钟被踢 | 误判三：加消费线程 |
| 22:26~23:00 | 陷入 rebalance → 超时 → 再 rebalance 死循环 | —— |
| 23:12 | grep 日志关键词 + consumer-groups describe | 定位 |
| 23:40 | 隔离异常消息、整组重启 | 恢复 |

算账：2000 条/s × 停摆累计约 8 分半 ≈ 102 万。**百万 lag 不需要灾难，十来分钟全组停摆就够了。**

那晚最贵的教训：lag 是体温，日志关键词才是病灶——三个误判全是拿体温计开药。

## 二、rebalance 是 stop-the-world：修一个成员，全组买单

我维护的学习库里，消费端配置表写得直白：新组用 cooperative-sticky，"rebalance 不再全组停摆"。反着读就是结论：默认的 eager 再平衡是全组停摆——成员交回分区、重新入组、重算分配，期间整组不消费【从业者判断：eager 协议细节为经验补充】。

rebalance 不是 bug，是自愈机制；问题在计费：一个成员出事，账单由全组停摆来付。触发面四个，各有日志指纹：

| 触发面 | 判定机制（默认值） | 日志指纹 |
| --- | --- | --- |
| 心跳超时 | 心跳由后台线程负责；GC 长停顿或网络抖动超 45s 判死 | Attempt to heartbeat failed |
| poll 间隔超时 | 单批处理超 5 分钟没回到 poll，主动被踢 | max.poll.interval.ms 超时被踢 |
| 成员进出 | 滚动发布属正常；反复进出多因宿主机负载、DNS 慢、CPU limit 打满 | left group |
| 分区再分配 / 协调者切换 | 扩分区触发重分配【从业者判断】；协调者 broker 抖动，组集体迁移 | Rebalance 成群出现 |

两道闸门盯的不同：session.timeout 问"心跳还在吗"，max.poll.interval 问"主循环还在转吗"。GC 停顿两道全踩。

连带账单：rebalance 时分区转给别的实例，原实例 commitSync 被拒（generation 已变，即 IllegalGeneration），新实例从旧位移接手，这批消息重复处理。at-least-once 下重复不可消除，业务侧用幂等键兜底。

**rebalance 的代价不是"重新分配"，是"全组不消费"。**

## 三、雪崩链：一次 GC 停顿怎么演变成全组瘫痪

```text
Full GC 47s（实例-2）
  → 心跳停超 session.timeout=45s → 被踢
  → 整组 rebalance：全组停摆，lag 陡涨
  → 实例-2 回归 → 再一轮 rebalance
  → 幸存者接管更多分区，撞上毒丸
  → 单批超 max.poll.interval=5min → 又被踢 → 循环
```

雪崩要两个放大器。其一，stop-the-world：被踢一台，停摆全组。其二，重入：GC 结束的实例不是悄悄归队，是触发下一轮 rebalance——排障表点名的宿主机负载、DNS 慢、CPU limit 打满，都是同一模式：一个不稳定成员，全组反复付账。

更糟的是正反馈：毒丸不挑宿主，每轮 rebalance 把分区连同毒丸一起换人接手；组里人越少、摊到的分区越多，下一个撞上的概率越高。**故障中的组会变得更脆弱——这不是线性恶化，是自我加强。**

## 四、poison pill：一条消息卡死一个组

那条 22:21 的异常消息：新版改了字段结构，旧逻辑反序列化抛异常，原地重试。offset 推不过它，每次 rebalance 后新接管的实例从旧位移拉起，再撞一次。**一条消息，让一个组无限次重启自己。**

消费停滞告警的注释里有个词组："rebalance 死锁/下游卡死"。毒丸正是两病合体：处理卡死导致 poll 超时，poll 超时导致 rebalance，rebalance 让毒丸换宿主再来一遍。

末端处置与源头判断【从业者判断】：单条 catch、失败消息进死信 topic、offset 照常推进；源头治理更划算——毒丸最常见来源是 schema 不兼容，两条纪律直接可用：加字段配默认值、删字段三思（Registry 默认 BACKWARD）。

毒丸的杀伤不在消息本身，在于它让 offset 永远推不过去。

## 五、缓解：顺序比清单重要

第一步修 GC。排障表里的原话："修 GC（堆/算法）、查网络重传"。参数救不了停顿 47 秒的 JVM——**参数是止血带，不是疫苗。**

第二步配置卫生。公式原样照抄："单批处理耗时 = 条数 × 单条耗时，必须 < max.poll.interval.ms"。500 条 × 200ms = 100s 看着安全；下游一抖单条 700ms，单批 350s，就越过红线了。方向：调小 max.poll.records、调大 max.poll.interval.ms，两者配合，慢作业再异步化。

```properties
# 消费端缓解四件套（数值注释为 Kafka 3.x 默认值）
max.poll.records=100          # 500
max.poll.interval.ms=600000   # 300000
session.timeout.ms=45000      # 45000；先修GC再动它
partition.assignment.strategies=org.apache.kafka.clients.consumer.CooperativeStickyAssignor
group.instance.id=pay-notify-0  # 静态成员：每实例固定一个
```

第三步机制两件套。static membership（group.instance.id）：滚动发布不触发 rebalance，约束是重启窗口必须落在 session.timeout 内。

cooperative-sticky：增量再平衡只挪必须挪的分区，"rebalance 不再全组停摆"；3.x 默认列表是 [RangeAssignor, CooperativeStickyAssignor]，要增量语义就显式只配后者，存量组迁移需全员同步换【从业者判断】。

session.timeout 取舍【从业者判断】：调大抗抖动、误踢少，代价是真宕机的分区接管变慢；调小反之。在线业务通常更怕误踢连锁——宁可检测慢些，也要把 GC 修到停顿远小于 45s。

static membership 治发布，cooperative-sticky 治停摆，修 GC 治根本——顺序反了都是白折腾。

## 六、lag 监控的正确口径：增速，不是绝对值

一道自测题：组 A lag 常年 5 万不涨，组 B 只有 200 但每分钟涨 5 万，谁该告警？B——A 收支平衡，B 消费停滞。绝对值必须换算成消化时间："10 万条对 5 万条/秒的组是 2 秒的事，对 10 条/秒的组是灾难。"锚点取「15 分钟可消化的量」，别抄整数。

kafka_exporter 不直接吐 lag，用两条同标签指标相减；增速看 rate(kafka_consumergroup_current_offset[5m])。落到 PrometheusRule：

```yaml
# [master] kubectl apply -f kafka-lag-rules.yaml（骨架，expr 上线前先实测）
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: kafka-lag-rules
  namespace: monitoring
  labels:
    release: prometheus   # operator 靠它选规则，写错是"不生效"头号原因
spec:
  groups:
    - name: kafka-lag
      rules:
        # lag 绝对值：warning，阈值按消化时间换算，10 万仅格式示例
        - alert: KafkaConsumerLagHigh
          expr: kafka_consumergroup_log_offset - kafka_consumergroup_current_offset > 100000
          for: 10m
          labels: {severity: warning}
        # 消费停滞：LEO 在涨、位移不动，比绝对值更早发现
        - alert: KafkaConsumerStalled
          expr: >
            (increase(kafka_consumergroup_log_offset[15m]) > 100)
            unless (increase(kafka_consumergroup_current_offset[15m]) > 0)
          for: 15m
          labels: {severity: critical}
        # 另一条线：under-replicated 与 broker 数也配 critical，完整四条见文末学习库
```

拿本案套一遍：第一轮死循环里，停滞告警就该升 critical——它认的是「LEO 在涨、位移不动」这个事实，不赌 lag 阈值换算得对不对。

第三道防线放日志【从业者判断】：Rebalance、Attempt to heartbeat failed、left group、IllegalGeneration 四个指纹配进日志告警——火苗在 lag 烧起来之前就能看到。

```bash
# [任意节点] 组的实时 lag（只读）
/opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 \
  --describe --group pay-notify
# 预期：12 行，LAG 列合计即全组积压

# 消费端日志三关键词
grep -E "Attempt to heartbeat failed|max.poll.interval|IllegalGeneration" app.log | tail -20
# 预期：heartbeat failed→GC/网络；max.poll.interval→处理慢；IllegalGeneration→被踢后还在提交
```

**lag 的绝对值是身高，增速才是心电图。**

## 七、预答三个反方

"session.timeout 调到两分钟不就完了？"误踢变少，但真宕机的接管也要等两分钟。47 秒的 GC 是病，阈值只是裤腰带。

"lag 绝对值告警简单直接。"常见坑表第一行就是下场：阈值 10 万、天天误报，两周后被全员静音。

"重启消费者最省事。"重启即成员进出，即再触发一轮 rebalance——递柴火。先 grep 分清离组类型，再下药。

## 八、30 秒自检

| 检查项 | 过关标准 |
| --- | --- |
| max.poll.records × 单条耗时 | 显著小于 max.poll.interval.ms |
| GC 停顿 P99 | 远小于 45s，否则随时被误踢 |
| 滚动发布 | 已配 group.instance.id，重启窗口 < session.timeout |
| 分配策略 | 显式 CooperativeStickyAssignor |
| 告警 | 有速率/停滞告警，绝对值按消化时间换算 |

现在就能做的三件事：

1. grep 那三个关键词，看 24 小时内有没有被静默踢组；
2. 用公式算最慢的组，离 5 分钟红线还有多远；
3. 跑一遍 consumer-groups --describe，把"lag 高但不涨"的组从 critical 里摘出来。

你最近一次半夜被 lag 告警叫醒，查明是四个触发面里的哪个？评论区对号入座。

## 写在最后

复盘会上有人问：Kafka 不靠谱？反了。broker 86 分钟零故障，说明协议在忠实执行；不可靠的是交给它的成员——一台 GC 失控的 JVM、一条没人管的毒丸、一组没人算过的默认参数。rebalance 风暴不是 Kafka 的故障，是它对"你不健康"的如实汇报。

时间线、配置清单与告警骨架整理在我维护的开源学习库——GitHub 搜 sre-learning-hub，Kafka 章节实验全部可在 Docker 环境复现；告警可直接抄，expr 上线前先在自己的 Prometheus 里查一次。
