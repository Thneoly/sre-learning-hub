---
title_juejin: 'acks=all 就不丢？配错这参数只是安慰剂'
title_zhihu: '把 acks=all 当免死金牌，是 Kafka 丢数事故里最常见的误会'
description: 'acks三档丢数窗口、ISR收缩动态、min.insync.replicas=2为何是底线、伪可靠陷阱、unclean选举风险、幂等重试与乱序窗口、buffer静默丢失、延迟与可用性代价矩阵。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686472562230312970"
---

# acks=all 就不丢？配错这参数只是安慰剂

> 周三 02:47，计费管道丢了 11 分钟数据（构造典型案例）。配置单上写着 acks=all。
>
> 复盘真相：两台 follower 因慢盘早被移出 ISR，min.insync.replicas=1 让写入继续——ISR 只剩 leader 的 acks=all 早已退化成 acks=1；leader 盘坏，账一次还清。

## 一、acks 三档：每档都有名有姓的丢数窗口

先给总判断：**acks 三档没有一档叫"不丢"，只有"丢在哪个窗口"。**

acks 决定 broker 何时回 ACK；topic 级 min.insync.replicas 决定 ISR 至少几个副本才允许写。凑齐才构成语义，只盯 acks 是半张合同。设 RF=3（"挂 N 台"指同时不可用）：

| 组合 | 语义 | 挂 1 台 | 挂 2 台 | 适用 |
| --- | --- | --- | --- | --- |
| acks=0 | 发出去就算成功 | 可能丢 | 可能丢 | 采样/指标，丢了无所谓 |
| acks=1 | leader 落盘即 ACK | leader 挂且未同步 → 丢 | 丢 | 日志类，容忍少量丢失 |
| acks=all, min=1 | ISR 收缩到 1 后退化为 acks=1 | 可能丢 | 可能丢 | 名义 all，实际不可靠 |
| acks=all, min=2 | ISR<2 拒绝写入 | 不丢已确认数据 | 不可写，恢复后自动可写 | 计费、订单、多数业务管道 |

窗口一句话：acks=0 丢在"发出"到"落盘"的缝隙；acks=1 丢在 leader 落盘到副本追上的间隙；acks=all 的窗口由 ISR 定义——"全体"是谁？下一节展开。

评审必抓：min.insync.replicas 只约束 acks=all 的写入，acks=0/1 不受它影响——想靠它兜日志流，兜不住。

## 二、ISR：acks=all 等的是"跟得上的人"，不是"所有人"

ISR = leader + 所有"跟得上"的 follower，判定只看一条：replica.lag.time.max.ms（默认 30 秒）内有没有追上 leader 的日志末端【官方，Kafka 3.x 默认值】。判时间不判条数：落后再多，窗口内追上 leader 日志末端就留（GC 停顿恢复期 30 秒内追平照样留在 ISR）；彻底断连的立刻出局。

收缩/扩张是常态：follower 超时被移出、追平再加回，broker 日志的 shrink/expand ISR 就是 HW 变动现场。而 acks=all 只等 ISR 成员——"ISR 内全体确认"，不是固定多数派。推论：**ISR 收缩到 1，acks=all 退化成 acks=1。**

集群健康时"all"等 3 个副本，慢盘时等 2 个，故障时只等 1 个——**acks=all 的"all"，每天都是不同的数字。**

Isr 列（第七节 describe）比 Replicas 短即有副本被踢；UnderReplicatedPartitions 统计 isr 数 < 副本数的分区，监控第一入口。

## 三、伪可靠：min.insync.replicas=1 的 acks=all，穿着盔甲的 acks=1

把事故翻成参数：RF=3、min=1、acks=all，两台 follower 长时间掉线，ISR 只剩 leader，写入继续——生产者零告警、指标全绿。leader 再挂，未同步数据全部丢失。这就是"名义 all、实际 acks=1"，三个参数必须一起评审。

min.insync.replicas=2 的作用不是"稳一点"，是改写语义：ISR 不足 2，broker 拒绝写入，生产端持续抛 NotEnoughReplicasException；消费者不受影响，HW 之前的消息照常可读。

**这是拿可用性换不丢数据的一笔明账**：挂 2 台写不进但一条不丢，恢复后自动可写。

坑也直白：大量 NotEnoughReplicasException 时先救 ISR（多为某 broker 掉线或慢盘），别为恢复写入调小 min.insync.replicas——那等于把保险丝换成铜丝。

## 四、unclean 选举：把"拒绝写入"换成"接受丢失"

min=2 守的是 ISR 下限，极端情况会走到 ISR 一个活口都没有。默认 unclean.leader.election.enable=false 的选择是宁可分区不可用（无 leader），也不让 ISR 外的落后副本当选。原因一句话：**旧副本当主，它没有的那段消息会被整段截掉。**

开启 true 则从非 ISR 副本里选 leader，尽快恢复读写，代价是上一次 HW 之后、旧 leader 上已确认的数据直接丢失，丢多少不可预知。可开场景：纯日志/埋点流，业务明确"可用性 > 完整性"；或三副本全宕的极端救援。

但改它等于改产品语义，必须业务方签字【从业者判断：最危险的姿势是故障夜顺手打开"先恢复业务"、事后没人记得关——它必须跟变更单走、有回滚期限】。

## 五、生产端连环坑：重试、幂等、乱序与 buffer 的静默丢失

broker 端配齐，客户端还有一层坑（均【从业者判断】，Kafka 3.x 口径，2026-10）。

第一坑，重试的重复与乱序。3.x 默认无限重试，由 delivery.timeout.ms（默认 120 秒）兜底。重试治"没送到"，但 broker 已落盘、ACK 却丢了，重试出来的就是重复。

乱序更隐蔽：max.in.flight 默认 5，第一批失败重试、第二批已落盘——没有幂等，重试与在途并存就是乱序。解法 enable.idempotence=true：按 PID+序号去重，in-flight≤5 时保序。注意 3.0+ 默认已开幂等，但生产端显式配 acks=1 会连带把它禁掉——评审时要确认幂等真的生效，而不是"没配就当没有"。

第二坑，buffer 与超时的静默丢失。send() 异步：消息先进 buffer.memory（默认 32MB）再由 sender 发。两个失血点：buffer 满且阻塞超 max.block.ms（默认 60 秒）抛异常；delivery.timeout 到期放弃，异常只走回调。

回调空实现、或只打一行 warn，丢了几乎无声。**Kafka 只承诺把异常交到你手上，不承诺替你处理**——回调必须记日志、进指标。

一句话收拢：**重试治丢数，幂等治重复乱序，回调治"静默"。**三件缺一，坑换个形状还在。

## 六、反方：不是所有业务都配 acks=all

延迟账：acks=all 下，生产到可见 = 生产 + ISR 全部落盘 + HW 推进；HW 靠下一轮 Fetch 才推进、天然滞后一个 RPC 周期，跨机房明显放大。同机房毫秒级，跨机房几十毫秒起步【从业者判断，量级估计】。acks=1 省的正是这段同步等待。

可用性账：min=2 挂 2 台不可写；min=3 一台都不能挂，把 RF=3 可用性降为零，几乎没人用。计费、订单接受"宁停不丢"；埋点、指标类相反——可用性与成本排在完整性前面，归宿是 acks=0 或 1。

推荐基线（RF=3 + min.insync.replicas=2 + acks=all + enable.idempotence=true + unclean=false："容忍单机故障、不丢已确认消息、不静默降级"）服务的是大多数业务管道，不是全部流量。**先问业务丢一条值多少钱，再抄参数。**

## 七、15 分钟复现：亲眼看 ISR 收缩与拒写

单 broker 看不出 ISR 行为。环境：三节点 KRaft（apache/kafka:3.9.0，容器 kafka1/2/3，replica.lag.time.max.ms 压到 10 秒）。docker pause 模拟"活着但不干活"的半死，比 stop 更真实：

```bash
# 建 topic：1 分区 3 副本，min.insync.replicas=2
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka1:9092 \
  --create --topic pay --partitions 1 --replication-factor 3 --config min.insync.replicas=2

docker exec kafka1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka1:9092 --describe --topic pay
# 预期：Leader: 1  Replicas: 1,2,3  Isr: 1,2,3（确认 leader 不是 kafka3 再 pause）

# pause 一台（副本半死）→ ISR 收缩，min=2 下仍可写
docker pause kafka3 && sleep 15
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka1:9092 --describe --topic pay
# 预期：Isr: 1,2   ← kafka3 被移出 ISR，写入不受影响

# 再 pause 一台：ISR=1 < min=2，acks=all 写入被拒
docker pause kafka2 && sleep 15
docker exec kafka1 bash -c 'echo should-fail | /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server kafka1:9092 --topic pay --producer-property acks=all 2>&1 | tail -5'
# 预期：org.apache.kafka.common.errors.NotEnoughReplicasException:
#       The number of insync replicas for [pay,0] is [1], short of required [2]

# 恢复后 Isr 回满、写入自动恢复；确认 unclean 默认关闭
docker unpause kafka2 kafka3 && sleep 20
docker exec kafka1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka1:9092 --describe --topic pay
# 预期：Isr: 1,2,3（回满，写入自动恢复）

docker exec kafka1 /opt/kafka/bin/kafka-configs.sh --bootstrap-server kafka1:9092 \
  --entity-type brokers --entity-name 1 --all 2>/dev/null | grep unclean
# 预期：unclean.leader.election.enable=false
```

验证口径：Isr 3 → 2 → 回 3，与异常的出现/消失一一对应。

## 八、30 秒自检

| 检查项 | 过关标准 |
| --- | --- |
| acks × min 组合 | acks=all 必配 min.insync.replicas=2（RF=3） |
| min=1 存量 topic | 改掉，或拿到业务"接受伪可靠"的确认 |
| unclean 选举 | false；开过必须有业务签字与回滚期限 |
| enable.idempotence | true，且 in-flight 不超过 5 |
| 发送回调 | 记日志、进指标，不是空实现 |

现在做三件事：拉各 topic 的 min.insync.replicas × 生产端 acks 交叉表，揪出"名义 all"；查 Isr 长期短于 Replicas 的分区，治好慢盘；grep 生产代码的 send 回调，确认异常有人接。你见过最离谱的"伪可靠"配置是哪一组？评论区对暗号。

## 写在最后

acks=all 就不丢消息了吗——**它承诺"ISR 全体确认"，不承诺"ISR 永远有全体"。**

可靠性不是单参数，是一组合同：RF 出冗余，min.insync.replicas 出下限，unclean=false 出"不静默降级"，幂等出"不重复不乱序"，回调出"丢了知道丢"。五份都签了，"不丢已确认消息"才成立。

组合矩阵与三节点 compose 文件在我维护的开源学习库——GitHub 搜 sre-learning-hub，ISR 收缩实验可在 Docker 完整复现。
