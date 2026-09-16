# 04 · 埋点与 Exporter：指标类型选型、三大采集器与 Pushgateway

> 模块：PCA 备考 ｜ 建议时长：4 小时 ｜ 关联认证：PCA-埋点与 Exporter（20%）

## 学习目标

- 能根据"要回答的问题"为 counter/gauge/histogram/summary 做出正确选型
- 能用 client 库给一个应用加上最小可用的 /metrics 端点并验证
- 能准确区分 node_exporter、kube-state-metrics、cAdvisor 三者的数据来源与职责（必考）
- 能说出 Pushgateway 的适用边界与两大陷阱，并给出规避做法
- 能在 code review 中识别会导致高基数的 label 设计

## 1. 四种指标类型与选型决策

### 1.1 类型速览

| 类型 | 行为 | 导出形态（以 `x` 为名） | PromQL 用法 |
| --- | --- | --- | --- |
| Counter | 只增（重启归零） | `x_total` | rate/increase |
| Gauge | 可升可降 | `x` | 直接读、over_time 家族 |
| Histogram | 观测值装桶 | `x_bucket{le=...}` + `x_sum` + `x_count` | histogram_quantile、求和后聚合 |
| Summary | 客户端算分位数 | `x{quantile=...}` + `x_sum` + `x_count` | 直接读、不可聚合 |

### 1.2 选型决策表（按问题驱动）

| 你要回答的问题 | 选型 | 反例（为什么不行） |
| --- | --- | --- |
| "每秒发生多少次 / 共发生了多少" | counter + rate | gauge 算不出速率（升降无从区分） |
| "现在是多少（温度、队列深、内存、在线数）" | gauge | counter 表达不了下降 |
| "请求耗时的分布、P95/P99，且要多实例聚合" | histogram | summary 的分位数不能跨实例聚合 |
| "只想看单实例分位数、不能改桶" | summary | histogram 需要埋点时定桶 |
| "一个事件的成功/失败（可重试）" | counter 带 code label，而非多指标 | 多个独立指标没法做比值 SLI |
| "当前版本/角色等元信息" | gauge 恒为 1 + label（`x_info` 惯例） | label 换一次值等于换一条时序 |

经验法则：**默认 counter + histogram**（都可聚合、可回溯重算口径）；summary 与 gauge 各有专属场景。所有"版本号、状态码、方法"进 label，所有"取值无界"的东西（id、路径参数）不进。

## 2. 客户端埋点：最小可用示例

### 2.1 Python

```python
# [任意 Ubuntu 节点/VM] /opt/mon/app/app.py
#!/usr/bin/env python3
"""最小埋点：counter + gauge + histogram，暴露在 :8000/metrics"""
import random
import time

from prometheus_client import Counter, Gauge, Histogram, start_http_server

REQUESTS = Counter(
    "demo_requests_total", "Total demo requests", ["method", "code"]
)
LATENCY = Histogram(
    "demo_request_latency_seconds", "Demo request latency in seconds",
    buckets=(0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)
QUEUE = Gauge("demo_queue_size", "Simulated queue depth")


def handle_request() -> None:
    QUEUE.inc()
    start = time.monotonic()
    time.sleep(random.choice((0.02, 0.06, 0.2, 0.45, 0.9)))
    LATENCY.observe(time.monotonic() - start)
    code = random.choices(("200", "500"), weights=(95, 5))[0]
    REQUESTS.labels(method="GET", code=code).inc()
    QUEUE.dec()


if __name__ == "__main__":
    start_http_server(8000)
    print("serving /metrics on :8000")
    while True:
        handle_request()
```

要点：Counter 名以 `_total` 结尾（client 会自动保证）；Histogram 只需 `observe(值)`，桶与 `_sum/_count` 自动维护；label 通过 `.labels(...)` 取子计数器。

```bash
# [任意 Ubuntu 节点/VM] 用 venv 运行（避免系统 pip 的 externally-managed 限制）
sudo apt-get update && sudo apt-get install -y python3-venv
python3 -m venv /opt/mon/venv
/opt/mon/venv/bin/pip install prometheus_client
/opt/mon/venv/bin/python /opt/mon/app/app.py &
curl -s http://127.0.0.1:8000/metrics | grep -E '^demo_' | head
```

预期输出包含 `demo_requests_total{code="200",method="GET"} 12`、`demo_request_latency_seconds_bucket{le="0.5"} ...`、`demo_queue_size 0` 等行。

### 2.2 Go（对照）

```go
// [任意 Ubuntu 节点/VM] main.go：零业务指标也有进程默认指标
package main

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
	http.Handle("/metrics", promhttp.Handler())
	http.ListenAndServe(":8080", nil)
}
```

两个客户端都自动附带进程与 Go 运行时指标（`process_*`、`go_*`）——这就是为什么 02 文件的 metric_relabel 示例喜欢 drop `go_*`。

## 3. Exporter 体系：三种典型

Exporter 是"把第三方系统翻译成 /metrics"的适配器。官方列表见 <https://prometheus.io/docs/instrumenting/exporters/>。三个代表必须掌握：

### 3.1 node_exporter：机器本体

- **数据来源**：Linux 的 /proc 与 /sys（以及内核模块如 textfile、systemd collector）
- **部署形态**：每台机器一个（K8s 里是 DaemonSet，hostPID/rootfs 挂载）
- **关键指标**：`node_cpu_seconds_total`、`node_load1`、`node_memory_MemAvailable_bytes`、`node_filesystem_avail_bytes`、`node_network_receive_bytes_total`、`node_boot_time_seconds`
- **特有机制**：textfile collector——脚本周期性把自定义指标写成 .prom 文本，node_exporter 一并暴露（cron 任务的指标出口）：

```bash
# [任意节点] 启用 textfile collector 的方式（以 systemd 部署为例）
# ExecStart 中加： --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
echo 'db_backup_success 1' > /var/lib/node_exporter/textfile_collector/backup.prom
curl -s http://127.0.0.1:9100/metrics | grep db_backup_success
```

### 3.2 blackbox exporter：从外部探测

- **数据来源**：自己发起 http/https/tcp/icmp/dns 探测（probe），测的是"用户视角是否可达"
- **形态**：集中部署少量实例；Prometheus 把"探测谁"作为参数传给 `/probe` 端点：

```yaml
# [master] prometheus.yml 片段：blackbox 探测 HTTP 可用性（官方标准写法）
  - job_name: blackbox-http
    metrics_path: /probe
    params:
      module: [http_2xx]
    static_configs:
      - targets:
          - https://prometheus.io
          - http://172.30.30.21:8000
    relabel_configs:
      - source_labels: [__address__]     # 把目标塞进 ?target= 参数
        target_label: __param_target
      - source_labels: [__param_target]  # 用目标地址当 instance 展示
        target_label: instance
      - target_label: __address__        # 真正抓取的地址是 blackbox 本身
        replacement: 127.0.0.1:9115
```

读结果：`probe_success`（0/1）、`probe_duration_seconds`、`probe_http_status_code`。注意 up 衡量"blackbox 活着"，**probe_success 才是目标活着**——高频辨析点。

### 3.3 mysqld exporter：数据库翻译器

- **数据来源**：连上 MySQL 执行 `SHOW GLOBAL STATUS`/`SHOW GLOBAL VARIABLES` 等查询并翻成指标（`mysql_global_status_threads_connected` 等）
- **形态**：每个被监控实例一个 exporter 进程，凭 `.my.cnf` 里的账号连接
- 代表了一类 exporter 模式："问询式翻译"（区别于 node_exporter 的"读文件"与 blackbox 的"主动探测"）

## 4. 必考辨析：node_exporter vs kube-state-metrics vs cAdvisor

| | node_exporter | cAdvisor | kube-state-metrics |
| --- | --- | --- | --- |
| 回答的问题 | 机器健康吗 | 容器用了多少资源 | K8s 对象处于什么状态 |
| 数据来源 | /proc、/sys（节点 OS） | kubelet 内嵌的 cAdvisor（cgroup/运行时） | watch kube-apiserver |
| 视角 | 节点 | 容器（runtime） | Kubernetes 对象 |
| 典型指标 | node_cpu_seconds_total、node_memory_MemAvailable_bytes | container_cpu_usage_seconds_total、container_memory_working_set_bytes | kube_pod_status_phase、kube_deployment_status_replicas_available、kube_node_status_condition |
| 部署形态 | DaemonSet（host 挂载） | kubelet 自带（/metrics/cadvisor，无需单独装） | 单副本 Deployment（仅读 API） |
| 时效性 | 实时采样 | 实时采样 | 随 API 对象更新，天然有滞后 |
| 盲区 | 看不到容器/对象 | 看不到对象语义（desired 副本数） | 不测量任何"性能"，只反映声明状态 |

三句话记忆：**node_exporter 管"机器"，cAdvisor 管"容器跑了多少资源"，KSM 管"对象应该是什么状态、实际是什么状态"**。考题变形："Pod 反复重启次数找谁"——KSM 的 `kube_pod_container_status_restarts_total`；"容器 OOM 前工作集内存"——cAdvisor 的 `container_memory_working_set_bytes`（OOM killer 依据的就是它）；"节点磁盘快满了"——node_exporter 的 `node_filesystem_avail_bytes`。

## 5. Pushgateway：短命任务的中转站

### 5.1 场景

pull 模型抓不到"活不过一个抓取间隔"的进程（cron、批处理、CI 任务）。Pushgateway 的位置：

```
短命 job ──push（结束前推一把）──> Pushgateway ──pull──> Prometheus
```

作业结束时把最终指标（成功次数、耗时、产物大小）推上去，Prometheus 照常拉取。**只该用于短命任务**；长驻服务直推 Pushgateway 是反模式（丢掉了 pull 的健康检查语义，还把所有服务的容量风险集中到一个网关）。

### 5.2 两大陷阱

**陷阱一：指标不会随时间衰减。** Pushgateway 常驻，永远抓得到，于是其上的序列**不会被标记 stale**——凌晨备份任务推的 `backup_success 1`，到第二天中午仍然显示"成功"。监控方看到的是"最后一次推送时"的快照，而不是"现在"。配套必须监控推送新鲜度：

```promql
# [Prometheus Web UI] 各 job 距最近一次推送过了多久秒
time() - push_time_seconds
```

对它设告警（如 `time() - push_time_seconds > 900`）才能把"静态快照"变回"活监控"。

**陷阱二：不清理导致序列无限堆积。** 推送的分组由 `job` 与 `instance`（或自定义 grouping key）决定；同样的 key 推送是**覆盖**，key 变了就是**新增**：

```bash
# [任意节点] 好的做法：固定 key，每次覆盖，序列数恒定
echo 'backup_duration_seconds 42' | curl --data-binary @- \
  http://pushgateway:9091/metrics/job/backup/instance/nightly

# [任意节点] 坏的做法：key 里带时间戳/流水号，每次都是新序列，永不回收
# http://pushgateway:9091/metrics/job/backup/instance/run-20260822-001
```

必须配套清理策略：作业开始前 `DELETE /metrics/job/<job>` 清旧值（幂等重跑尤其需要），或按周期调管理 API 清理孤儿分组。

### 5.3 正确用法清单

- 只接短命任务；长驻服务一律自己暴露 /metrics
- grouping key 固定且最小（job + 一个稳定 instance）
- 用 `time() - push_time_seconds` 告警推送超期
- 重跑型任务先 DELETE 旧分组再推
- Pushgateway 自身要 HA 时注意：它不复制数据，双实例前需外部负载均衡把同一 key 的推送固定路由到同一实例（官方文档明确其 HA 局限）

## 6. label 设计原则：把高基数挡在合码前

1. **有界才进 label**：取值集合随流量/用户增长的（user_id、request_id、url 带参数）一律不进，放日志；要关联 trace 用 exemplar
2. **维度最小化**：每个 label 都应当出现在至少一条常用查询的 by 里；没人 group by 的 label 就是纯基数开销
3. **别复用一个 label 表达复合信息**：`env_region="prod-cn"` 会让按 env 聚合变成正则；拆成两个 label
4. **单位进名字、用基础单位**：`_seconds`、`_bytes`、`ratio`（0~1），避免 ms/KB 混用导致换算错误
5. **保留后缀语义**：`_total`（counter）、`_bucket/_sum/_count`（histogram）、`_info`（元信息）不要挪作他用
6. **上线前算一遍基数**：序列数 ≈ 各 label 取值数的乘积 × 目标数；上量后再用 `topk(10, count by (__name__)({__name__=~".+"}))` 验尸

## 实战演练：VM 上跑通一条完整埋点链路

环境：装有 Docker 的 Ubuntu VM（以 172.30.30.21 为例，替换成你的 IP）。

```bash
# [任意 Ubuntu VM] 准备目录与文件（app.py 用 2.1 节内容）
sudo mkdir -p /opt/mon/app && sudo chown -R "$USER" /opt/mon
# 把 2.1 节 app.py 放到 /opt/mon/app/app.py
```

```dockerfile
# [任意 Ubuntu VM] /opt/mon/app/Dockerfile
FROM python:3.12-slim
RUN pip install --no-cache-dir prometheus_client
COPY app.py /app/app.py
CMD ["python", "/app/app.py"]
```

```yaml
# [任意 Ubuntu VM] /opt/mon/prometheus.yml
global:
  scrape_interval: 15s
scrape_configs:
  - job_name: demo-app
    static_configs:
      - targets: ["demo-app:8000"]
  - job_name: node
    static_configs:
      - targets: ["172.30.30.21:9100"]
```

```bash
# [任意 Ubuntu VM] 构建并启动三个组件
docker build -t demo-app /opt/mon/app
docker network create mon
docker run -d --name demo-app --network mon demo-app
docker run -d --name node-exporter --net=host --pid=host \
  -v /:/host:ro,rslave quay.io/prometheus/node-exporter:latest --path.rootfs=/host
docker run -d --name prom --network mon -p 9090:9090 \
  -v /opt/mon/prometheus.yml:/etc/prometheus/prometheus.yml prom/prometheus
```

验证三步：

```bash
# [任意 Ubuntu VM] 1. 应用端点直接可见原始 exposition
curl -s http://127.0.0.1:8000/metrics | grep -c '^demo_'

# [任意 Ubuntu VM] 2. Prometheus 能抓到（等 30s）
curl -s 'http://127.0.0.1:9090/api/v1/query?query=up' | grep -o '"value":[1-9.,]*'

# [任意 Ubuntu VM] 3. node_exporter 的 textfile collector 实验一次
docker exec node-exporter sh -c 'mkdir -p /host/tmp/tf && echo "lab_marker 1" > /host/tmp/tf/lab.prom'
```

第 3 步把文件写进挂载的宿主 /tmp/tf（默认 textfile 目录未启用时，需给容器加 `--collector.textfile.directory=/host/tmp/tf` 参数重启后生效）。浏览器打开 `http://<VM-IP>:9090` 执行：

```promql
# [Prometheus Web UI] 验证埋点三类指标都可查
rate(demo_requests_total[1m])
demo_queue_size
histogram_quantile(0.95, sum by (le) (rate(demo_request_latency_seconds_bucket[5m])))
sum by (code) (increase(demo_requests_total[5m]))
```

预期：错误率约 5%（代码里 500 权重）；P95 随延迟档位落在 0.5~1s 区间；`increase` 返回带小数的估算值（03 文件 6.3 节）。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 对 gauge 用 rate，曲线乱跳 | gauge 可降，被当 reset 补偿成暴涨 | gauge 用 over_time 家族或直接读 |
| summary 多实例求 avg 当"整体 P99" | 分位数不可聚合 | 改 histogram：sum by (le) 后 histogram_quantile |
| blackbox 一切正常但目标其实挂了 | 看了 up 而非 probe_success（up 只代表 exporter 本身活着） | 告警 probe_success == 0 |
| 想知道"Deployment 期望副本数"去查 node_exporter | 职责错位：这是 API 对象状态 | 用 kube-state-metrics 的 kube_deployment_spec_replicas |
| 备份"永远成功" | Pushgateway 指标不衰减 | 监控 time() - push_time_seconds 并告警 |
| Pushgateway 序列数持续增长 | grouping key 带了随机成分 | 固定 key；重跑前 DELETE 旧分组 |
| Prometheus 内存缓慢上涨 | 新 label 或新取值悄悄混进埋点 | 按第 6 节清单 review diff；topk 时序数巡检 |
| demo 应用抓不到 | 容器网络与 static targets 地址不一致（容器名 vs localhost） | 同 network 用容器名，跨网络用宿主 IP |

## 自测

1. 为什么"统计接口耗时"几乎总该选 histogram，即使部署时多花了几条序列？
<details><summary>答案</summary>

耗时是分布，运营要的是分位数（P95/P99）且口径常变。histogram 把观测装桶，查询时任意 φ 可算、sum by (le) 可跨实例聚合、还能算平均与 Apdex；多花的序列数 = 桶数 × 维度，是有界的。summary 省序列但锁死分位数、不可聚合，一旦服务多副本就废。
</details>

2. node_exporter、cAdvisor、kube-state-metrics 分别能看到"Pod 内存"吗？各自看到的是什么？
<details><summary>答案</summary>

node_exporter：看不到 Pod 维度，只有机器总量级（node_memory_*）；cAdvisor：能，container_memory_working_set_bytes 按 container/pod 标签给出工作集（OOM 依据）；KSM：没有内存"测量值"，但有 kube_pod_container_resource_limits 之类的对象声明值。测量与声明是两回事。
</details>

3. 一个 5 分钟一次的 cron 同步任务要监控成功/失败与耗时。为什么不能靠应用自己的 /metrics？给出完整方案。
<details><summary>答案</summary>

进程只活几秒，抓取间隔（15s~1m）内大概率错过它存在的窗口，up 长期为 0。方案：任务结束前把结果 push 到 Pushgateway（固定 grouping key：job=sync, instance=cron-host），Prometheus 抓 Pushgateway；同时用 time() - push_time_seconds 告警"超过 10 分钟没推"；重跑前先 DELETE 旧分组避免旧数据残留。
</details>

4. 埋点加了 label `path`（原始 URL 含查询参数）。上线一周后会发生什么？
<details><summary>答案</summary>

每个不同的 URL（含参数排列组合）生成一条时序，基数爆炸：head 内存上涨、scrape 超时、查询变慢。修法：路由归一化（/user/123 → /user/:id 再进 label）或 path 干脆不进 label、只进日志/trace。
</details>

5. probe_success 与 up 的区别，用一个事故说明为什么混淆会出大事。
<details><summary>答案</summary>

up=1 只说明"Prometheus 成功抓到了 blackbox exporter 的 /metrics"；probe_success=0 才表示"目标探测失败"。混淆者把告警设在 up 上，于是在"所有目标全挂但 exporter 活着"的事故里监控系统一片绿灯——探测失败的信号生成了，却没人消费。
</details>

6. 为什么 client 库要自动附带 go_*/process_* 指标，而生产环境又常常把它们 drop 掉？
<details><summary>答案</summary>

附带是为了零成本获得运行时可见性（内存、GC、句柄、启动时长），小规模时很有用。规模大了以后每个进程几十条 go_* 序列乘上千实例成为纯基数开销，且团队很少看它们——于是经 metric_relabel_configs 在入库前丢弃（抓取仍发生，只是不存）。
</details>

## 延伸阅读

- Exporter 官方列表与编写指南：<https://prometheus.io/docs/instrumenting/exporters/>
- client 库列表（Go/Python/Java/Rust 等）：<https://prometheus.io/docs/instrumenting/clientlibs/>
- Pushgateway 文档（含删除 API 与分组语义）：<https://github.com/prometheus/pushgateway>
- node_exporter 文档（enabled collectors、textfile）：<https://github.com/prometheus/node_exporter>
- kube-state-metrics 文档（指标清单）：<https://github.com/kubernetes/kube-state-metrics/tree/main/docs>
- 命名与最佳实践：<https://prometheus.io/docs/practices/naming/>
