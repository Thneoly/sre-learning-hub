# 02 · ELK 栈：Elasticsearch 原理与日志管道

> 模块：日志（10-logging）｜ 建议时长：4 小时 ｜ 前置：01-logging-concepts.md ｜ 关联认证：—（无直接考点；SRE 日志岗面试高频）

## 学习目标

- 能解释 Elasticsearch 倒排索引的构造（分词 → term → posting list）与 segment 的不可变性、refresh/merge 对读写延迟的影响
- 能给出分片与副本的容量设计步骤，说清"主分片数建后不可改、副本数可随时改"背后的路由公式
- 能画出写入路径（buffer → translog → refresh → segment → flush/merge）与查询路径（scatter-gather 两阶段）
- 能讲清 pre-7.0 的 `minimum_master_nodes` 与 7.x Zen2 自动 quorum 的演进（脑裂防治，面试真题）
- 能配置 Filebeat→Logstash→ES 的三段管道，并用 Kibana 完成索引模式与检索

## 1. 栈概览与数据流

ELK 是三个项目的首字母缩写，现在官方叫 Elastic Stack（加了 Beats）：

```
┌─────────┐    ┌──────────┐    ┌────────────┐    ┌───────────────┐    ┌────────┐
│ 日志源   │ →  │ Filebeat │ →  │ Logstash   │ →  │ Elasticsearch │ →  │ Kibana │
│ 文件/   │    │ shipper  │    │ filter/    │    │  存储+倒排索引 │    │ 可视化 │
│ stdout  │    │ 轻、只采 │    │ 富化/路由  │    │               │    │ 检索   │
└─────────┘    └──────────┘    └────────────┘    └───────────────┘    └────────┘
                     │                                                    ↑
                     └──── 小规模可以直连 ES（跳过 Logstash） ─────────────┘
```

- **Filebeat（Beats 家族）**：装在节点上的轻量 shipper，只负责"可靠地读文件、扛住背压"，不做重处理。
- **Logstash**：JVM 数据处理管道，input→filter→output 三段，干解析（grok）、富化、路由这类重活。小规模常省略，由 Filebeat 直写 ES。
- **Elasticsearch**：分布式搜索与分析引擎，本栈的存储与索引核心，本文重点。
- **Kibana**：索引模式、Discover 检索、仪表盘。

## 2. 倒排索引：为什么"搜日志"这么快

正排索引回答"文档 1 包含哪些词"；倒排索引回答"包含词 error 的是哪些文档"。搜索是后者，所以 ES 为每个 text 字段建倒排：

```
文档1: "connection refused from 10.1.2.3"
文档2: "connection timeout to database"

分词（analysis）链：character filter → tokenizer → token filter
   "Connection REFUSED!" --lowercase--> [connection, refused]

倒排（一个 segment 内）：
  term          posting list（文档号 + 词频 + 位置）
  connection -> [1, 2]
  refused    -> [1]
  timeout    -> [2]
  10.1.2.3   -> [1]        （standard 分词会把 IP 拆开，实际需专门 analyzer）
```

三个面试必答的机制细节：

1. **analysis 是可插拔的**。`standard`（默认，按词切+小写）、`keyword`（整个值当一个 term，不分词）、`english`（去词干）。数字、IP、版本号这类"不该拆的东西"必须用 `keyword` 类型或专门的 pattern tokenizer，否则 `10.1.2.3` 被拆成 `10`、`1`、`2`、`3`，精确匹配直接失效。这就是 mapping 里 `text` vs `keyword` 的取舍：`text` 分词做全文检索，`keyword` 不分词做精确过滤/聚合——K8s 的 namespace、pod 名都应该映射成 `keyword`。

2. **segment 不可变**。倒排索引被切成一个个只读的 segment，文档删除只是标记（.del 位图），更新 = 标删 + 新写。不可变带来：无锁读、OS 页缓存友好、压缩率高；代价是删除不释放空间，空间靠 merge 回收。

3. **refresh 决定可见延迟**。写入先进 index buffer（内存）+ translog（磁盘事务日志）；refresh（默认 1 秒）把 buffer 生成新 segment 进入文件系统页缓存即可被搜到——这就是 ES"近实时（NRT）"的来源。flush 才把 segment fsync 到磁盘并清空 translog。小 segment 太多会拖慢查询（每个都要打开），后台按策略 merge 成大 segment。

```
写入路径（单文档视角）：

  write ──► index buffer ──refresh(1s)──► 新 segment(页缓存,可搜索) ──flush──► fsync 到盘
              │                                                        │
              └──────► translog（每次写都落盘，崩溃恢复用） ──flush 时截断◄──┘

  段多了 ──► 后台 merge（合并大段、物理清除已删除文档）
```

## 3. 分片与副本设计

索引被水平切成 N 个主分片（primary shard），每个主分片可有 R 个副本（replica）：

```
索引 logs-2026.08 (5 primary × 1 replica)，3 节点：

 node1: [P0] [P1] [R2]
 node2: [P2] [R0] [R3]      主分片散得开，副本永远不与主分片同节点
 node3: [P3] [P4] [R1]
```

**路由公式（面试高频）**：文档落到哪个主分片由 `shard = hash(routing) % number_of_primary_shards` 决定，routing 缺省是文档 `_id`。这直接推出两条铁律：

- 主分片数一旦建索引就不能改（改了路由结果全变，旧文档全部失联）；副本数可以随时 `PUT .../_settings` 调整。
- 容量估错主分片数，唯一正解是 **alias + reindex/rollover**：索引用别名对外服务，容量不够时 rollover 出新索引（新分片数），别名切过去。

设计步骤（以日志场景为例）：

1. 估日增量：如 200 GB/天（含副本前）。
2. 定保留期与单分片大小：官方经验单 shard 10~50 GB（日志场景偏上限），太大 merge/恢复慢，太小开销项多。
3. 算主分片数：200 GB ÷ 40 GB ≈ 5 个主分片；副本 1 份 → 实际磁盘 400 GB/天。
4. 副本的作用是**读扩展与容灾，不是写扩展**：写要主+全部副本都成功才返回，副本越多写越慢；查询可以打任意一份拷贝，副本多读吞吐高。
5. 日索引/rollover 按 `logs-{now/d}` 或大小阈值滚动，配 ILM 做热→温→冷→删除（第 8 节）。

## 4. 写入与查询路径

**写入路径（跨节点）**：

```
client ──► coordinating node（任意节点，按路由公式算出目标分片）
              ├──► 主分片所在节点：写 buffer + translog
              └──► 并行转发给所有副本分片节点：同样写
          全部成功（wait_for_active_shards 默认 1）才向 client 返回 201
```

批量是性能生命线：bulk 每批 5~15 MB、客户端多线程，比逐条写高一个数量级。写 Hang 时优先查 refresh_interval（可以设 -1 换写入吞吐）、副本数、merge 风暴与 translog fsync 策略。

**查询路径（两阶段）**：

```
client ──► coordinating node
             ① query 阶段：把请求扇出（scatter）给涉及的所有分片（主或副本）
                每个分片本地查倒排，返回 doc id + 排序值（top-N）
             ② fetch 阶段：coordinating 汇总排序，再去对应分片取 _source
          ◄── 合并后的结果集（gather）
```

推论：一次查询的延迟 ∝ 最慢的那个分片；分片数不是越多越好（每个分片都是一次扇出 + 一个打开的 segment 集）。深分页（from+size 很大）会让每个分片返回巨量候选，所以 ES 有 `index.max_result_window` 默认 10000 的限制，日志翻页用 `search_after` 或时间过滤。

## 5. Master 选举与脑裂防治（面试高频）

**什么是脑裂**：网络分区时两侧行政区各自选举出 master，各自接受写入，分区恢复后同一分片出现两份分叉的数据，只能丢一边。防治思路从始至终是一句话：**候选 master 的多数派（quorum）同意才能当选**。演进分两段：

**pre-7.0（ZenDiscovery）**：quorum 需要人工声明——

```yaml
# 6.x 集群配置：3 个 master eligible 节点时
discovery.zen.ping.unicast.hosts: ["es01","es02","es03"]
discovery.zen.minimum_master_nodes: 2      # = master_eligible / 2 + 1
```

`minimum_master_nodes` 配错是那个时代脑裂的第一原因：配 1（默认），网络一抖，两侧行政区都觉得自己凑齐了法定人数。运维要点：节点数变动（扩缩 master 节点）时要同步改这个值——`minimum_master_nodes` 可动态更新，属于高危手工步骤。

**7.0+（Zen2）**：quorum 由集群自行维护，不再人工设置——

```yaml
# 7.x+：只在"第一次组建集群"时声明一次
cluster.initial_master_nodes: ["es01","es02","es03"]   # bootstrap 后应从配置中移除
discovery.seed_hosts: ["es01","es02","es03"]
```

机制变化：每个节点持久化一个 voting configuration（投票成员表），选举按该表自动取多数派，`minimum_master_nodes` 配置被移除（设了直接报错拒绝启动）。网络分区时少数派一侧永远无法过半，只会空转等待，脑裂在协议层面被消除。

面试加分点：

- 生产集群 3 个专用 master 节点（低配、不存数据、`node.roles: [master]`），quorum=2，挂 1 个不影响。
- `cluster.initial_master_nodes` 的残留风险：某节点数据目录被清空后带着这条配置重启，会**重新 bootstrap 出第二个集群**，把节点骗走——所以"集群成型后从配置里删掉它"是运维规范。
- 脑裂的后果最终落在分片层：两边都当过主分片接受写入，恢复后以一边为准，另一边的写入丢失。

## 6. Filebeat 与 Logstash 管道

**Filebeat** 的关键构件：

```
harvester（每个文件一个，逐行读）
   └─► spooler（事件聚合，spool.threshold 大小/条数触发）
         └─► output（ES/Logstash/Kafka），背压时 harvest 减速
registry 文件记录每个文件的 offset —— 重启后从断点续读，这是"不重不漏"的根据
```

**Logstash** 三段管道：

```
input ──► filter ──► output（可多路）
(beats/   (grok 解析、  (ES/Kafka/
 kafka/    mutate 改字段、 email/...)
 file)     date 覆盖时间戳)
```

两个最常用的 filter 片段（语法可直接用）：

```ruby
# Logstash filter 段：解析非结构化访问日志并覆盖 @timestamp
filter {
  grok {
    match => { "message" => "%{IP:client_ip} %{WORD:method} %{URIPATHPARAM:uri} %{NUMBER:duration_ms:int} %{LOGLEVEL:level}" }
  }
  date {
    match => [ "log_time", "yyyy-MM-dd'T'HH:mm:ssZ" ]
    target => "@timestamp"        # 用事件自身的时间覆盖采集时间
  }
}
```

```ruby
# Logstash：Java 堆栈多行合并（在 input 段配合 multiline codec，或转给 Filebeat 处理）
input {
  beats { port => 5044
          codec => multiline {
            pattern => "^\s"              # 以空白开头的行视为上一行的续行
            what => "previous"
          } }
}
```

多行日志（异常堆栈）在 Filebeat 侧也有等价物（filestream input 的 `parsers: - multiline:`），原则一致：**多行合并越靠近源做越好**，中心化合并要靠"顺序到达"这个不可靠假设。

选型规则：Filebeat 直写 ES 适合结构化已就绪的日志；需要 grok/富化/复杂路由才上 Logstash；Logstash 是 JVM、有 GC 停顿风险，资源规划按 1~2 vCPU/百 MB/s 量级估，别把它塞进每台业务节点。

## 7. Kibana 的最小工作流

1. 建索引模式（Stack Management → Index Patterns / Data Views）：模式如 `logs-*`，时间字段选 `@timestamp`——没有时间字段整个 Discover 的时间轴就废了。
2. Discover：时间窗 + 查询。KQL 示例：`level:error and service:payment and not kubernetes.pod.name:*canary*`。
3. 保存检索、做仪表盘、配告警（栈内 alerting）。

生产注意：给用户的是"带通配符的数据视图"，别给整库 `*` 模式——它会把系统索引也扇出进查询。

## 8. 面试真题形态：海量日志的架构演进

题目通常长这样："日增 200 GB，要 30 天可查、7 天内高频查询，怎么设计与演进？"答题骨架（逐层加码）：

```
阶段0 单节点 ES                阶段1 分层+生命周期           阶段2 加缓冲削峰
┌────────┐                  ┌──────────────────────┐    ┌────────────────────┐
│ ES 一台 │                  │ hot:  SSD, 副本1, 3天 │    │ Filebeat ──► Kafka │
│ 全装    │                  │ warm: HDD, 副本0, 7天 │    │   (保留12h)        │
└────────┘                  │ cold: 快照到对象存储   │    │   └─► Logstash 消费 │
容量/单点                   └──────────────────────┘    │       └─► ES       │
先撞墙                       ILM 自动 rollover/迁移      └────────────────────┘
                             shrink/删除                ES 故障不再反压采集端
```

逐条展开（面试按此顺序说）：

1. **索引滚动**：按天或按大小 rollover（`logs-000001` → `logs-000002`），别名 `logs-write` 永远指向可写索引——主分片数估错的唯一补救通道。
2. **ILM 生命周期**：hot（SSD、副本 1、接受写入）→ warm（只读、force merge 成单 segment、可 shrink、副本降 0）→ cold（searchable snapshot 挂对象存储）→ delete（30 天到期物理删除）。成本能降数倍。
3. **引入 Kafka 缓冲**：当 ES 维护/故障会造成 Filebeat 背压甚至丢数据时，采集端先写 Kafka（保留 12~24h），Logstash/ES 按能力消费——把"存储故障"从"数据丢失风险"降级为"延迟入库"。
4. **降载**：采样（debug 丢 99%）、丢健康检查日志、按 team 路由到不同保留期——不是所有日志都值同样的钱。
5. **演进到混合**：全文检索的需求集中在一小撮日志（业务审计、安全）时，把大规模基础设施日志切去 Loki（第 3 章），ES 只留需要全文索引与复杂聚合的部分——这是当下最流行的成本答案。

## 实战演练：单节点 ELK 收 JSON 日志

环境：装有 Docker 的 Ubuntu 22.04/24.04 VM，内存 ≥ 4 GB（ES heap 512m + Kibana）。镜像 tag 以官方 release 为准，本文用 8.17.0。

**1. 起 Elasticsearch 与 Kibana**

```bash
# [装Docker的Ubuntu VM]
docker network create elk-lab
docker run -d --name es --network elk-lab -p 9200:9200 \
  -e discovery.type=single-node \
  -e xpack.security.enabled=false \
  -e xpack.ml.enabled=false \
  -e ES_JAVA_OPTS="-Xms512m -Xmx512m" \
  docker.elastic.co/elasticsearch/elasticsearch:8.17.0
sleep 30 && curl -s http://localhost:9200 | head -5
```

预期输出：JSON 里含 `"version" : { "number" : "8.17.0"` 与 `"tagline"`。安全关闭仅限实验环境。

```bash
# [装Docker的Ubuntu VM]
docker run -d --name kibana --network elk-lab -p 5601:5601 \
  -e ELASTICSEARCH_HOSTS=http://es:9200 \
  -e XPACK_SECURITY_ENABLED=false \
  docker.elastic.co/kibana/kibana:8.17.0
```

**2. 亲眼看看"分词"**

```bash
# [装Docker的Ubuntu VM]
curl -s -X GET "http://localhost:9200/_analyze" -H 'Content-Type: application/json' \
  -d '{"analyzer":"standard","text":"Connection REFUSED from 10.1.2.3"}' | jq -c '.tokens[] | {t:.token, p:.start_offset}'
```

预期输出：`{"t":"connection","p":0}`、`{"t":"refused","p":11}`、`{"t":"from","p":19}`、`{"t":"10","p":24}`、`{"t":"1","p":27}`……——IP 被切碎正是第 2 节说的坑。

**3. 观察近实时：写入→立刻查 vs refresh 后查**

```bash
# [装Docker的Ubuntu VM]
curl -s -X POST "http://localhost:9200/elk-lab-000001/_doc" \
  -H 'Content-Type: application/json' \
  -d '{"@timestamp":"2026-08-22T03:00:00Z","level":"error","service":"payment","msg":"connection refused"}' >/dev/null
echo "--- 未 refresh 立即查（大概率 0 hits 或偶发可见）---"
curl -s "http://localhost:9200/elk-lab-000001/_search?q=refused" | jq '.hits.total'
curl -s -X POST "http://localhost:9200/elk-lab-000001/_refresh" >/dev/null
echo "--- refresh 后查 ---"
curl -s "http://localhost:9200/elk-lab-000001/_search?q=refused" | jq '.hits.total'
```

预期输出：第一次 `{"value":0}`（buffer 里的文档还没生成 segment），refresh 后 `{"value":1}`。

**4. Filebeat 把文件日志送进 ES**

```bash
# [装Docker的Ubuntu VM]
mkdir -p /opt/elk-lab
for i in $(seq 1 50); do
  lvl=info; [ $((i % 10)) -eq 0 ] && lvl=error
  printf '{"ts":"%s","level":"%s","service":"payment","msg":"order %d done"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$lvl" "$i" >> /opt/elk-lab/app.log
done
cat > /opt/elk-lab/filebeat.yml <<'EOF'
filebeat.inputs:
  - type: filestream
    id: elk-lab-app
    paths:
      - /var/log/app.log
    parsers:
      - ndjson:
          keys_under_root: true
          add_error_key: true
    fields_under_root: true
    fields:
      env: lab
output.elasticsearch:
  hosts: ["http://es:9200"]
  index: "elk-lab-app"
setup.template.name: "elk-lab-app"
setup.template.pattern: "elk-lab-app"
setup.ilm.enabled: false
EOF
docker run -d --name filebeat --network elk-lab --user root \
  -v /opt/elk-lab/app.log:/var/log/app.log:ro \
  -v /opt/elk-lab/filebeat.yml:/usr/share/filebeat/filebeat.yml:ro \
  docker.elastic.co/beats/filebeat:8.17.0 filebeat -e --strict.perms=false -c /usr/share/filebeat/filebeat.yml
sleep 15
curl -s "http://localhost:9200/_cat/indices/elk-lab-app?v&h=index,docs.count,store.size"
curl -s "http://localhost:9200/elk-lab-app/_search?q=level:error&size=1" | jq '.hits.hits[0]._source'
```

预期输出：`_cat/indices` 显示 docs.count 约 50；第二条返回 `_source` 里带 `"level":"error"` 与 `error.message` 字段不出现（ndjson 解析成功时无 `add_error_key` 标记）。

**5. Kibana 收尾**

浏览器开 `http://<VM_IP>:5601`（免登录）。Stack Management → Data Views → Create：模式 `elk-lab-app`，时间字段选 `ts`（若下拉里没有就选不设时间字段、Discover 用实时窗）。然后 Discover 里输入 KQL `level:error`，应看到 5 条左右命中。清理：`docker rm -f es kibana filebeat && docker network rm elk-lab`。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 明明写入了，Kibana 搜不到 | refresh 未发生 / 索引模式时间字段选错 / 时间窗不含事件时间 | 手动 `_refresh` 排除第一项；检查 data view 的时间字段与浏览器时间窗 |
| IP/版本号/邮件精确匹配搜不到 | `text` 字段被 standard 分词拆碎 | mapping 改 `keyword`（或 `fields` 双映射），重建索引用 reindex |
| 磁盘水位 85%+ 后整索引变只读 | ES flood_stage 磁盘水位保护 | 清理/扩容后 `PUT index/_settings {"index.blocks.read_only_allow_delete": null}` |
| Filebeat 重启后日志重发或漏读 | registry 文件丢失（容器重建）或日志轮转改名未跟踪 | registry 挂持久卷；轮转用 copytruncate 要配 `close_renamed`/inode 策略 |
| CPU 被 grok 吃满 | 非结构化日志 + 复杂正则 | 应用改输出 JSON；或把解析下推到 ES 的 ingest pipeline |
| 堆栈异常被拆成多行日志 | 每行当独立事件 | 采集端 multiline 合并（越靠近源越好） |

## 自测

1. 文档写入后为什么默认要等约 1 秒才可搜？断电时这 1 秒的数据会丢吗？

<details><summary>答案</summary>

写入先进内存 index buffer，refresh（默认 1s）才生成可搜索的 segment，所以有约 1 秒的可见延迟。不会丢：每次写同时追加 translog（磁盘事务日志，默认每请求 fsync），崩溃重启时 ES 重放 translog 恢复未 refresh 的写入。丢数据的风险点在 translog 的 fsync 策略被调成异步且掉电，而不是 refresh 本身。
</details>

2. 为什么主分片数建后不可改而副本数可随时改？容量估错了怎么办？

<details><summary>答案</summary>

文档路由公式 `shard = hash(routing) % number_of_primary_shards` 依赖主分片数：改了它，所有旧文档的路由结果全变，等于全部失联。副本不参与路由取模（按主分片位置复制），所以可动态调整。容量估错的正解：索引走 rollover（按大小/天数滚动出新索引、新分片数），对外用 alias 切换；旧数据要改分片数只能 reindex 到新索引。
</details>

3. pre-7.0 的 `minimum_master_nodes` 防的是什么事故？7.0 之后为什么可以不配了？

<details><summary>答案</summary>

防脑裂：网络分区后两侧行政区各自选主、各自接受写入，恢复后同分片两份分叉数据。pre-7.0 要求人工设 `master_eligible/2+1`，多数派同意才能当选，配成 1 或忘记随扩容调整是当年脑裂主因。7.0 Zen2 把投票成员表持久化在集群状态里，quorum 由集群自动维护，该配置被移除（设置了反而拒绝启动）；`cluster.initial_master_nodes` 只用于首次 bootstrap，成型后应从配置移除，否则某节点数据目录被清空后会二次 bootstrap 出平行集群。
</details>

4. 日增 200 GB、保留 30 天，你按什么步骤定分片数？哪些层用什么硬件？

<details><summary>答案</summary>

单 shard 目标 10~50 GB，取 40 GB → 5 个主分片；副本 1 → 日磁盘 400 GB，30 天 12 TB。hot 层（0~3 天，SSD，副本 1，承担写入与高频查询）→ warm（只读、force merge、可降副本 0、HDD）→ cold（searchable snapshot 放对象存储）→ 到期 ILM delete。索引按天/大小 rollover + 别名切换，保证主分片数可按代际修正。
</details>

5. 什么时候该在 Filebeat 和 ES 之间加 Kafka？它解决什么、又引入什么？

<details><summary>答案</summary>

当 ES 停机维护或故障时采集端会被背压、可能丢数据或拖垮业务节点 IO 时加 Kafka：采集端只对 Kafka 负责（本地保留 12~24h），消费端按 ES 能力拉平峰值，把"存储故障"降级为"延迟入库"。引入的代价：链路多一跳（延迟、运维 Kafka 本身的成本）、端到端监控要从"采集→ES"改成分段、消息重复/顺序问题（多分区）需要下游按 `@timestamp` 与文档 id 幂等兜底。
</details>

## 延伸阅读

- Elasticsearch 官方：Inverted index 与 Analysis — <https://www.elastic.co/guide/en/elasticsearch/reference/current/analysis-overview.html>
- Elasticsearch 官方：Shard sizing 建议 — <https://www.elastic.co/guide/en/elasticsearch/reference/current/size-your-shards.html>
- Elasticsearch 官方：Zen2 与 voting configuration — <https://www.elastic.co/guide/en/elasticsearch/reference/current/modules-discovery-voting.html>
- Filebeat 官方配置 — <https://www.elastic.co/guide/en/beats/filebeat/current/configuring-howto-filebeat.html>
- 下一章：[03-loki-stack.md](03-loki-stack.md)（"索引标签不索引全文"的另一条路线）
