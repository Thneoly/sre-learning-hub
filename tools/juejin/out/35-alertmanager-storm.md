---
title_juejin: '告警风暴那 10 分钟：Alertmanager 怎么把 500 条告警收敛成 1 通电话'
title_zhihu: '告警风暴那 10 分钟：Alertmanager 怎么把 500 条告警收敛成 1 通电话'
description: '机房抖动10分钟炸出500条告警，值班只接1通电话：route树分流、分组四旋钮时序推演、inhibition误配翻车点、silence纪律与工单号、gossip协商去重，附过度分组反方。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686472562230312970"
---

# 告警风暴那 10 分钟：Alertmanager 怎么把 500 条告警收敛成 1 通电话

> 凌晨 03:00，机房核心交换机抖了 10 分钟，500 条告警灌进通知管道，值班只接到 1 通电话和十几条 IM。收敛不是运气，是六道工序各干各的活。案情为构造典型案例，参数以官方文档为准。

## 一、风暴现场：500 条进管道，1 通电话出来

背景：双 Prometheus HA + 3 节点 AM 集群，group_by: [alertname, cluster]（分组键无默认值，必须显式），group_wait 30s / group_interval 5m / repeat_interval 4h 为官方默认值【官方，Alertmanager 默认值】。

| 时间 | 事件 | 管道动作 |
| --- | --- | --- |
| 03:01 | 抖动满 1 分钟，200 目标失联，InstanceDown（for: 1m）熬满 firing，双 Prom 各发一份 | fingerprint 去重，双份折一（本行 400 折回 200；其余告警陆续到达，全程 1000 折回 500） |
| 03:01:30 | InstanceDown 组 group_wait 到点 | 第 1 封 critical 通知 → 值班电话 |
| 03:02~03:05 | 其余告警各自成组攒 30s；NodeDown 压同节点 warning | 约 10 条 IM，被抑制的 UI 仍可见 |
| 03:10 | 交换机恢复 | 各组各发一次 resolved |

结果：全程 1 通电话 + 约 10 条 IM，500 条一条不丢。反过来配错就是坑表里的「一屏同种告警」：group_wait 设 0、group_by 缺维度，500 条逐条轰炸，手机变震动马达。

**500 条变 1 通电话，发生在 AM 的六道工序里，一步都省不得。**

## 二、先划清分界线：谁管「要不要喊」，谁管「怎么喊」

高频踩的分界线：expr 求值与 for 状态机在 Prometheus；去重、分组、抑制、静默、重发全在 Alertmanager。两边只靠 HTTP API 和告警身上的 labels 沟通。

AM 内部管道：去重（fingerprint = 标签集哈希）→ 路由树 → group_wait / group_interval 排程 → inhibition → silence → 通知集成（重试、限流，nflog 记账）。

for 也算半道收敛：for: 1m 过滤瞬时抖动，一次抓取超时不该触发 page。但 scrape 断点让 expr 短暂变假会重置 pending 计时——坑表「一直在 pending 不 firing」的常见原因之一（另一个是 for 设得太长）。

**Prometheus 过滤不值得喊的，AM 折叠值得一喊的。**

## 三、route 树：根兜底、自上而下、命中即停

分流语义三句话：根路由不能带 matcher，必须接住一切告警；子路由自上而下匹配，命中一条即停（continue 默认 false）；要「同时进两个 receiver」必须显式 continue: true。

```yaml
# alertmanager.yml 骨架（kube-prometheus-stack 里改 secret，直接改文件会被 operator 覆盖）
route:
  receiver: default            # 根路由兜底：没被子路由接住的都走这
  group_by: [alertname, cluster]
  # 另三旋钮也配在根上，见下节
  routes:
    - matchers: [severity="critical"]
      receiver: oncall         # 电话值班
receivers:
  - name: default
  - name: oncall
```

补两个细节：matchers 是 0.22+ 新语法，等价老写法 match / match_re；子路由能覆盖根的分组参数——比如给 db 团队 10s 的 group_wait，拿更快首响换更差合并。

**分流的全部语义：自上而下，命中即停，根上兜底。**

## 四、四旋钮：第一次等多久、合并窗口多长、重发多勤

| 旋钮 | 语义与默认 |
| --- | --- |
| group_by | 列出的标签取值相同 → 同一组；必须显式 |
| group_wait | 新组第一封通知前等多久；默认 30s |
| group_interval | 已发组两封通知的最小间隔；默认 5m |
| repeat_interval | 同样内容成功通知后多久重发；默认 4h |

考试就考时间线推演。设 group_wait=30s、group_interval=5m、repeat_interval=4h，T0 收到告警 A：

```text
T0        A 到达，新组开始攒批
T0+30s    group_wait 到点 → 发第 1 封（含 A）
T0+2m     B 到达同组 → 内容更新，但不立即发
T0+5m30s  距上封满 group_interval → 发第 2 封（A+B）
T0+4h30s  repeat_interval 到点 → 原样重发（A+B）
```

两个细节，决定你敢不敢自称熟悉 AM。其一，若 B 在 T0+29s 到达（group_wait 之内），第 1 封直接含 A+B——group_wait 的存在意义就是这 30 秒的顺路捎带。

其二，repeat_interval 按 group_interval 的节拍对齐生效，官方建议设为整数倍，重发依据是 nflog 记下的「已成功发过」；不对齐时重发漂移到下一个边界，没法推理。

group_wait=0？新分组第一条立即发送，风暴时逐条轰炸；只有 Watchdog 心跳这类低频低延迟场景可接受。

**合并窗口有两个：头一封 30 秒，往后每封 5 分钟。**

## 五、拿风暴套一遍：500 条的折叠账

第一折，去重。fingerprint 是标签集的哈希，双 Prom 发来的同一告警在此合一：1000 折回 500——「双 Prom HA + 单 AM 集群 = 只响一次」就在这步实现。

第二折，分组。group_by [alertname, cluster] 下，200 条 InstanceDown 的分组键取值相同（alertname 同名、cluster 同值；各条 instance 并不相同，但它不在分组键里、不参与比较），折成 1 组 1 封——值班电话那通就是它。其余 300 条分属约 10 个组，各攒各的 30s，走 IM 不打电话。

第三折，抑制。NodeDown 压住同 instance 的 warning：被压的不发、UI 仍可见。排查时别因为「没收到」就以为没发生。

第四折，恢复。交换机回稳，AM 收到 EndsAt 展示 resolved。「修完了还收到旧告警」是 repeat_interval 的例行重发，设计行为，别靠重启 AM 消音。

**一次故障一次唤醒，而不是一条告警一条短信。**

## 六、inhibition：critical 压 warning，翻车都翻在 equal 上

语义一句话：source 告警存在时，抑制 target 告警（且 equal 列出的标签取值相同）的通知。经典用例：节点挂了就别再喊该节点上的容器告警；主库挂了压掉从库的复制延迟——根因在场，症状告警没有说话的资格。

```yaml
# alertmanager.yml：NodeDown 压同节点全部 warning
inhibit_rules:
  - source_matchers: [alertname="NodeDown"]
    target_matchers: [severity="warning"]
    equal: [instance]
```

误配风险三连：

- equal 的标签在两条告警上取值不同，抑制悄悄失效——最典型是 instance 一边带端口一边不带、大小写不一。排查：并排对照两条告警的实际 label。
- source / target 方向写反，warning 抑制 critical，电话永远不响【从业者判断】。
- 只按 severity 配抑制、不拿 equal 限定，任一 critical 出现，全机房 warning 集体闭嘴【从业者判断】。

**inhibition 是上游压下游，equal 是那条安全带。**

## 七、silence 纪律：会过期的静音才敢用

先辨析三兄弟：silence 是「临时、会过期、按 matcher 挡通知」；inhibition 是「常驻规则、由另一条告警的存在触发」；把 receiver 注释掉则是「永久失聪」，几乎总不是正确答案。

```bash
# amtool（AM 容器里自带）封装成函数，省得每次敲全名
am() { kubectl -n monitoring exec -it alertmanager-prom-stack-kube-prom-alertmanager-0 -- \
  amtool --alertmanager.url=http://localhost:9093 "$@"; }
am silence add alertname=GrafanaDown --duration=30m \
  --author=cka0007 --comment="维护窗口 30 分钟，工单号 OPS-2103"
am silence ls   # 查看在途静默；过期用 am silence expire <id>
```

纪律三条【从业者判断】：谁有权——值班只能静默自己已认领的告警，越范围走审批；多久——上限一个班次，到期自动恢复响铃，永久静默是「注释 receiver」的文明版；凭据——comment 必须带工单号，没有工单号的静默等于把问题塞进抽屉，下个值班翻不到来龙去脉。

高频坑：silence 了还收到——matcher 没匹配上（label 名或正则不符），拿 silence ls 的 matcher 对照告警实际标签。

**静默的全部价值在于它会过期。**

## 八、AM 自己别成单点：gossip 复制与「只发一次」

双 Prom 保住评估侧，AM 挂了照样全员失聪。生产形态 2~3 实例 + LB，Prometheus 的 alertmanagers 指过去；实例间靠 gossip（默认 9094，TCP/UDP 同端口）复制 silences 与 nflog，协商由谁发通知——不会各发一遍。

最小双实例实验（完整脚本在文末学习库，Docker 环境 20 分钟能跑完）：给两个容器挂同一份只有 route + receiver 的最小配置，各自声明 --cluster.listen-address=0.0.0.0:9094 并用 --cluster.peer 指向对方。

起来后查 /api/v2/status，两实例 cluster status 均为 ready，在 am1 上建的 silence 会出现在 am2 上。值得亲手跑一次——「silence 同步了」见过一次，就不会再怀疑 gossip 在干活。

边界要诚实：gossip 是最终一致，分区瞬间两个 AM 可能都认为该自己发——收敛前各发一次，已知权衡不是 bug。坑表「同一故障收到两封」：先查规则重复定义，再查双实例是否组网。

**AM 的去重是协商去重，不是绝对不重。**

## 九、反方：过度分组把真问题藏进抽屉

上面全是收敛的好处，现在自己拆台。

其一，group_by 太粗。坑表说 group_by 没含区分维度会风暴；反过来 [alertname] 一把梭、全机房合一封，那条「磁盘 92%」埋在 200 行告警列表的中段没人看见——风暴的解药不是把信封做大，是带上 cluster、namespace 关键维度【从业者判断】。

其二，repeat_interval 长 + 分组粗，持续恶化的告警 4 小时才露脸一次，值班对「还在涨」失去时间感【从业者判断】。

其三，inhibition 按 severity 全局压制，NodeDown 期间同节点的磁盘满被遮蔽整整一个故障窗口——根因压得住症状，压不住症状自己在长大【从业者判断】。

**收敛的终点不是通知最少，是每一次响都值得起。**

## 十、30 秒自检

| 检查项 | 过关标准 |
| --- | --- |
| group_by | alertname + 关键区分维度 |
| repeat_interval | 是 group_interval 的整数倍 |
| group_wait | 30s 起步，别为 0 |
| inhibit_rules | 每条带 equal 且方向对 |
| silence | 带工单号，无永久静默 |
| AM 集群 | 至少 2 实例组网，status ready |

**自检表上挂掉的每一行，都是下一次风暴的预演。**

现在就能做的两件事：用 amtool silence ls 揪出没带工单号的静默；把 repeat_interval 除以 group_interval，不是整数就改。做完来评论区晒数：你见过最猛的告警风暴是多少条、最后收敛成了几条通知？「一条都没收敛」的优先围观。

## 写在最后

复盘会上有人问：500 条告警，该不该先治理规则？该，for、阈值、重复定义都是源头活。但规则治理是慢功夫，收敛管道是当晚救命的快功夫【从业者判断】。六道工序不会让问题变少，只保证：问题成群来时，值班只被叫醒一次。

时间线推演、route / inhibit / silence 全套配置和双实例 gossip 实验，整理在我维护的开源学习库——GitHub 搜 sre-learning-hub，告警章节的实验在 Docker 环境 20 分钟能复现，配置可直接抄，抄前记得过一遍自己的标签。
