# 01 · 性能压测工具与方法：k6、wrk 与 JMeter

> 模块：21-perf-testing ｜ 建议时长：3 小时 ｜ 关联认证：—（无直接考点，与 PCA-PromQL、CKA-资源管理联动）

## 学习目标

- 能解释压测的真正产出是"吞吐-延迟曲线及其拐点"，而不是一句"扛住了 N 并发"
- 能操作 k6 完成脚本编写、场景设计（开环/闭环）、阈值断言与 HTML 报告生成
- 能用 wrk 三分钟拿到一条基线，并能用 Lua 脚本扩展出读写混合流量
- 能根据 p50/p95/p99 与扇出放大效应选择正确的 SLO 指标，并说清"平均值为什么骗人"
- 能避开四个高频陷阱：闭环压测失真、不做预热、只测读不测写、把并发数当 RPS

## 1. 为什么压测：找到瓶颈出现的位置

新手对压测的想象是"加到 1000 并发，没挂，通过"。这句话在工程上接近废话：**"没挂"只说明负载没到瓶颈，而你没记录瓶颈在哪，等于测试白做**。压测的真正产出是一张**吞吐-延迟曲线**，以及曲线上那个拐点（knee）：

```
 吞吐 / 延迟
   │                          吞吐 ──●───●───╮ ← 平台期：某资源打满，RPS 加不动了
   │                 ●────●──●            ╰─● ╰● ← 过载区：队列堆积，吞吐反降
   │           ●───●       p99 ─────────●●●  ← 拐点后指数式抬升
   │       ●──╯      p99 ──●──●
   │  ●╋── p50 ──●─●──●──●──●──●──●─────────  ← 线性区：延迟平稳
   └───┼──┼────┼────┼────┼────┼────┼────→ 负载（RPS）
     线性区    拐点(knee)    平台期      过载区
```

| 区域 | 特征 | 此时要回答的问题 |
| --- | --- | --- |
| 线性区 | RPS 涨、p99 基本不动 | 正常余量，日常容量规划用（见本模块第 2 章） |
| 拐点 | p99 开始快速抬升、吞吐增速放缓 | **瓶颈是什么资源？** 这是压测最值钱的一段 |
| 平台/过载区 | 吞吐封顶甚至下降、错误率上升 | 退化行为：限流该不该接、超时级联会不会发生 |

压测报告的核心不是"支持了 N 并发"，而是：**拐点出现在多少 RPS，当时第一个饱和的资源是什么**（CPU？连接池？下游 RTT？）。第 2 章的容量规划全部建立在这两个数字上。

## 2. k6 入门与实战

k6（Grafana 出品）用 JavaScript 写脚本，单机就能打出数万 RPS，脚本即代码可进 git 走 CI。

### 2.1 安装与第一个脚本

```bash
# [master] Debian/Ubuntu：官方 apt 仓库（命令以 grafana.com/docs/k6 安装页为准）
curl -fsSL https://dl.k6.io/key.gpg | sudo gpg --dearmor -o /usr/share/keyrings/k6-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/k6-archive-keyring.gpg] https://dl.k6.io/deb stable main" | sudo tee /etc/apt/sources.list.d/k6.list
sudo apt-get update && sudo apt-get install k6 && k6 version
# [本地Windows] 三选一（以官方文档为准）：MSI 安装包 / choco install k6 / winget install k6 --source winget
```

```javascript
// [master] 保存为 smoke.js —— 最小可跑脚本
import http from 'k6/http';
import { check, sleep } from 'k6';
export const options = { vus: 5, duration: '30s' };
export default function () {
  const res = http.get('http://127.0.0.1:80/');
  check(res, { '状态码 200': (r) => r.status === 200 });
  sleep(1);   // 每个 VU 每秒 1 个请求 → 约 5 RPS；sleep 是并发数与 RPS 解耦的关键
}
```

脚本分两层：**init 上下文**（import、`options`，只执行一次）与 **VU 代码**（`default` 函数，被每个 VU 反复执行）。

### 2.2 场景设计：executor 决定流量模型

`options.scenarios` 选错，后面全错：

| executor | 模型 | 控制什么 | 典型用途 |
| --- | --- | --- | --- |
| shared-iterations（默认） | 闭环 | 总迭代数在 VU 间分摊 | 冒烟测试 |
| constant-vus / ramping-vus | 闭环 | 固定/阶梯并发数 | 模拟"在线用户数" |
| constant-arrival-rate | **开环** | 固定 RPS | 精确复现生产流量水位 |
| ramping-arrival-rate | **开环** | 阶梯 RPS | 找拐点（实战演练用它） |

闭环固定"多少人"，系统变慢时这些"人"自动放慢发请求，**拐点被抹平**；开环固定"每秒来多少"，系统慢了请求照样涌进来、延迟直接爆表，**饱和点无处可藏**。用户会话型业务看闭环，秒杀/推送型看开环（机理见第 6 节第 1 条）。

### 2.3 完整实战脚本：预热 + 阶梯 + 读写混合 + 阈值断言

阈值（thresholds）是 k6 的灵魂——不达标退出码非 0，可直接接 CI。注意 `check` 失败默认**只记数不失败**，必须配 `checks` 阈值才生效，这是"测试绿了但 check 全挂"的元凶。

```javascript
// [master] 保存为 mixload.js —— 预热段与度量段分离，读写 9:1 混合
// 运行：BASE_URL=http://<目标> k6 run mixload.js
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.BASE_URL || 'http://127.0.0.1';
const GET_OPT = { headers: { 'Accept-Encoding': 'gzip' } };  // 让 nginx 真的走 gzip 路径

export const options = {
  scenarios: {
    warmup: {                          // 预热：JIT/连接池/页缓存/CPU 频率就位，数据不用于评估
      executor: 'ramping-arrival-rate', exec: 'browse',
      startRate: 5, timeUnit: '1s', preAllocatedVUs: 10, maxVUs: 30,
      stages: [{ target: 20, duration: '30s' }, { target: 20, duration: '1m' }],
    },
    load: {                            // 度量：开环阶梯加压找拐点
      executor: 'ramping-arrival-rate', exec: 'browse',
      startRate: 5, timeUnit: '1s', preAllocatedVUs: 20, maxVUs: 300,
      startTime: '90s',                // 等 warmup 跑完
      stages: [{ target: 100, duration: '1m' }, { target: 200, duration: '1m' },
               { target: 400, duration: '1m' }, { target: 800, duration: '1m' }],
    },
  },
  thresholds: {
    'http_req_duration{scenario:load}': ['p(95)<400', 'p(99)<1000'],  // 阈值可按 tag 过滤到具体场景
    'http_req_failed{scenario:load}':   ['rate<0.01'],                 // 错误率 < 1%
    checks: ['rate>0.99'],                                            // check 通过率也做成门禁
  },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],          // 终端摘要多显示 p99
};

export function browse() {
  // 读写 9:1：写路径才暴露锁、fsync、复制延迟，纯读测出的是缓存性能
  if (__ITER % 10 === 9) {
    const w = http.post(`${BASE}/post`, JSON.stringify({ sku: __ITER, n: 1 }),
      { headers: { 'Content-Type': 'application/json' } });
    check(w, { '写请求 2xx': (r) => r.status >= 200 && r.status < 300 });
  } else {
    const r = http.get(`${BASE}/big.txt`, GET_OPT);
    check(r, { '读请求 200': (x) => x.status === 200 });
  }
  sleep(Math.random() * 0.3 + 0.1);   // 思考时间 0.1~0.4s
}
```

### 2.4 看结果：终端摘要、JSON 与 Web 报告

```bash
# [master] 落全量指标（JSON 可回放/二次分析）
BASE_URL=http://10.0.0.12:30888 k6 run --out json=mix.json mixload.js
# [master] 自带 Web 报告：v0.51 起为 --out web-dashboard，旧版本为 --out experimental-web-dashboard（以官方文档为准）
# 浏览器打开 http://localhost:5665 实时看曲线
BASE_URL=http://10.0.0.12:30888 k6 run --out web-dashboard mixload.js
```

终端摘要长这样（数值为示意）：

```
     ✓ '读请求 200' ............. 100.00%  ✓ 43810  ✗ 0
     http_req_duration..............: avg=42.1ms  med=18.7ms  p(95)=180.4ms  p(99)=512.7ms
       { scenario:load }............: avg=44.0ms  p(95)=186.1ms  p(99)=530.2ms
     http_req_failed................: 0.00%   ✓ 0  ✗ 43810
     http_reqs......................: 43810   145.2/s
```

判读顺序：先看 `http_req_failed`（有错先定性），再对照 `{ scenario:load }` 分组的 p95/p99 与各级阶梯 RPS——p99 从哪一级开始跳档，拐点就在哪一级；Web 报告里切到该级时间段，确认延迟抬升与 RPS 爬坡同步。

## 3. wrk 快速压测

```bash
# [master] 安装（源码编译见 github.com/wg/wrk），30 秒基线：2 线程、100 并发连接
sudo apt-get install -y wrk
wrk -t2 -c100 -d30s --latency --timeout 2s http://10.0.0.12:30888/big.txt
```

常用参数：`-t` 线程数（建议 ≈ CPU 核数）、`-c` 并发连接总数（须 ≥ 线程数）、`-d` 时长、`-H` 请求头、`-s` Lua 脚本、`--latency` 打印分位数、`--timeout` 单请求超时。

```
Running 30s test @ http://10.0.0.12:30888/big.txt
  2 threads and 100 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    14.32ms   6.81ms  210.44ms   92.10%
  Latency Distribution        ← 由 --latency 触发，重点看这
     50%   12.87ms
     75%   16.02ms
     90%   19.55ms
     99%   35.40ms
  30215 requests in 30.01s, 240.12MB read
Requests/sec:   1006.71       ← 闭环吞吐：受"延迟变差→发得更慢"制约
Socket Errors: connect 0, read 0, write 0, timeout 3
```

（数值为示意。）判读三条：`Latency Distribution` 的 99% 是主线；`Socket Errors` 非零说明连接层先崩（backlog、端口耗尽，见 01-linux/05-network-stack-internals.md 常见坑）；出现 `Non-2xx or 3xx responses` 说明压到了应用层拒绝。

Lua 脚本可以补上"路径混合、POST、状态码统计"三块短板：

```lua
-- [master] 保存为 mixed.lua：路径轮询 + 10% POST + 状态码统计
local paths = { '/', '/big.txt' }
local i, stats = 0, {}

function request()
  i = i + 1
  if i % 10 == 0 then   -- 十分之一走写路径
    return wrk.format('POST', '/post', { ['Content-Type'] = 'application/json' }, '{"sku":1}')
  end
  return wrk.format('GET', paths[(i % #paths) + 1])   -- 其余轮询读路径
end

function response(status)  -- 每个响应回调一次
  stats[status] = (stats[status] or 0) + 1
end

function done()            -- 收尾打印自定义计数
  for code, n in pairs(stats) do print(string.format('HTTP %d: %d', code, n)) end
end
```

```bash
# [master] 挂脚本运行
wrk -t2 -c100 -d30s --latency -s mixed.lua http://10.0.0.12:30888
```

wrk 的边界：**闭环**模型（`-c` 个连接固定）、只支持 HTTP/1.1（无 HTTP/2）、没有断言/门禁概念。定位就是"快"——验证一个改动、拉一条对比基线；正经场景设计交给 k6。

## 4. JMeter 何时用（定位介绍）

| 维度 | JMeter 的位置 |
| --- | --- |
| 交互 | GUI 画测试计划（Thread Group → Sampler → 断言 → Listener）；**压测必须用非 GUI 模式**：`jmeter -n -t plan.jmx -l out.jtl -e -o report/` |
| 场景 | 复杂多步事务（登录→浏览→下单→支付）、CSV 数据参数化、定时器控制节奏 |
| 协议 | HTTP 之外原生支持 JDBC、JMS、LDAP、TCP 等 Sampler |
| 分布式 | Master/Agent（RMI，默认 1099 端口）把压测机堆成集群，单机打不出足够流量时用 |

选型口径：**已有 JMeter 资产、需要 GUI 协作或非 HTTP 协议 → JMeter；新项目、脚本进 CI、需要开环模型 → k6；只要一条快速基线 → wrk**（.jmx 是 XML、对 diff 不友好，是 k6 党最常见的吐槽）。本章不展开 JMeter 操作细节，用到时以 jmeter.apache.org 官方文档为准。

## 5. 读结果的正确姿势：p50/p95/p99

分位数定义：pN = "N% 的请求快于这个值"。p50 是中位数（典型体验），p95 是"20 个用户里最慢的那个"，p99 是"100 个用户里最慢的那个"。

**平均值为什么骗人**：设 100 个请求，99 个 10ms、1 个 1010ms——平均值 20ms 看起来很健康，但 p99=1010ms。更狠的是双峰分布：一半请求 10ms、一半 1010ms，平均值 510ms，**落在没有任何真实请求经历的"山谷"里**，p50 与 p99 才是两个真实的峰。

**尾部延迟的放大效应**：一个页面聚合 50 次后端调用，单次调用有 1% 概率慢，则页面至少撞上一次慢调用的概率是 `1 - 0.99^50 ≈ 39.5%`——单接口 p99 看着能接受，页面级体验已经烂了。链路越长，尾部越重要。

| 场景 | 用什么分位 | 理由 |
| --- | --- | --- |
| 在线 API 的 SLO | p95 起步，核心链路 p99 | 尾部决定"最倒霉的那批用户"的体验 |
| 批处理/离线管道 | 均值/总时长可用 | 关心总吞吐，不关心单请求 |
| 监控图表 | 分位数曲线，别只画 avg | avg 抹平尖刺，同上 |

两个工程细节：**分位数不可相加平均**——多实例聚合必须先合并 histogram 桶再求分位（PromQL 里是 `histogram_quantile` 套 `sum by (le)(rate(...))`，实操见 10-pca 题库）；**样本量要够**——每级阶梯至少数千请求，200 个请求算出的 p99 是噪声。

## 6. 常见压测陷阱

| # | 陷阱 | 症状 | 解法 |
| --- | --- | --- | --- |
| 1 | 闭环模型找拐点 | 加大"并发数"延迟却几乎不涨，拐点被抹平 | 换开环 arrival-rate executor（2.2 表） |
| 2 | 不做预热 | 第一分钟 p99 奇高后回落，两轮数据没法比 | 场景加 warmup 段（2.3 脚本），评估只看度量段 |
| 3 | 只测 GET | 压测全绿，上线一写就抖——锁、fsync、复制、缓冲池全没测到 | 按生产读写比混合（如 9:1），读写分开打 tag |
| 4 | 并发数当 RPS | "压了 200 并发"没人知道是多少 RPS | Little 定律：RPS ≈ 并发数 ÷ 平均响应时间；报告以 RPS 为准 |

第 1 条的机理：闭环钉死"在系统里的请求数"（Little 定律 L=λW 的 L），系统变慢时到达率 λ 自动下降，**饱和被负载发生器自我消化**；开环钉死 λ，系统慢了就排队，队列暴露真实饱和点。第 4 条的换算例：100 VU、平均响应 200ms → 约 500 RPS；响应恶化到 1s 后同样 100 VU 只剩 100 RPS——并发数根本不是稳定的负载刻度。

## 实战演练：压 nginx 看 p99 拐点，压 Redis 看管道威力

靶场：kubeadm 练习集群。部署一个带 gzip 大页面的 nginx，用 k6 开环阶梯压它；再把 CPU limit 掐到 100m 复压，亲眼看 p99 抬升与 CFS 节流的对应关系；最后用 redis-benchmark 对比普通与管道模式。

### 演练 A：部署靶标

```bash
# [master] 生成 128KB 可压缩文本页 + 开 gzip 的 nginx 配置
yes 'performance testing line for gzip benchmark ' | head -c 131072 > /tmp/big.txt
kubectl create configmap nginx-bench-page --from-file=big.txt=/tmp/big.txt
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata: { name: nginx-bench-conf }
data:
  default.conf: |
    server {
      listen 80; gzip on; gzip_min_length 1024; gzip_types text/plain;
      location / { root /usr/share/nginx/html; }
      location /post { return 204; }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: nginx-bench }
spec:
  replicas: 1
  selector: { matchLabels: { app: nginx-bench } }
  template:
    metadata: { labels: { app: nginx-bench } }
    spec:
      containers:
      - name: nginx
        image: nginx:1.27
        ports: [{ containerPort: 80 }]
        volumeMounts:
        - { name: conf, mountPath: /etc/nginx/conf.d }
        - { name: page, mountPath: /usr/share/nginx/html/big.txt, subPath: big.txt }
        resources: { requests: { cpu: 200m, memory: 64Mi },
                     limits: { cpu: 1000m, memory: 128Mi } }
      volumes:
      - { name: conf, configMap: { name: nginx-bench-conf } }
      - { name: page, configMap: { name: nginx-bench-page } }
---
apiVersion: v1
kind: Service
metadata: { name: nginx-bench-np }
spec:
  selector: { app: nginx-bench }
  type: NodePort
  ports: [{ port: 80, targetPort: 80 }]
EOF
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}')
NODE_PORT=$(kubectl get svc nginx-bench-np -o jsonpath='{.spec.ports[0].nodePort}')
curl -s -o /dev/null -w '%{http_code} %{size_download}B\n' -H 'Accept-Encoding: gzip' "http://$NODE_IP:$NODE_PORT/big.txt"
# 预期输出：200 3010B   ← 128KB 压到约 3KB，gzip 生效（数字随文本浮动）；http://$NODE_IP:$NODE_PORT 就是 BASE_URL
```

### 演练 B：k6 阶梯加压，找拐点

```bash
# [master] 用 2.3 的 mixload.js；另开窗口实时看容器 CPU
BASE_URL="http://$NODE_IP:$NODE_PORT" k6 run --out web-dashboard mixload.js
kubectl top pod -l app=nginx-bench --containers --watch
```

观察三条线：RPS 每级翻倍时 p50 几乎不动、p99 从某一级开始数倍跳档——那一级就是拐点；同时容器 CPU 逼近 limit（1000m）。把"拐点 RPS、当时的 p95/p99、CPU 用量"记下来，第 2 章容量规划直接引用。

### 演练 C：把 limit 掐到 100m，看 p99 与 nr_throttled 联动

```bash
# [master] 压缩 CPU 上限后复压（CFS 节流原理见 04-k8s-fundamentals/11-resources-and-qos.md 第 2 节）
kubectl set resources deploy/nginx-bench --limits=cpu=100m,memory=128Mi
kubectl rollout status deploy/nginx-bench --timeout=60s
kubectl exec deploy/nginx-bench -- cat /sys/fs/cgroup/cpu.stat | head -3   # 记下 nr_throttled 基线
# 复跑演练 B 同一条命令，预期：拐点大幅提前，p99 周期性尖刺。压测中再取一次证：
kubectl exec deploy/nginx-bench -- cat /sys/fs/cgroup/cpu.stat
#   nr_throttled 快速增长  ← "CPU 用量不高但 p99 尖刺"的节流实锤
kubectl set resources deploy/nginx-bench --limits=cpu=1000m,memory=128Mi   # 还原
```

### 演练 D：redis-benchmark 看连接数与管道对 p99 的影响

k6 是 HTTP 工具，压 Redis 这类私有协议应使用专用基准器（同理 MySQL 用 sysbench 类工具）。

```bash
# [master] 装工具；集群里起一个无持久化的 Redis 并暴露 NodePort
sudo apt-get install -y redis-tools      # 提供 redis-cli 与 redis-benchmark
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: redis-bench }
spec:
  replicas: 1
  selector: { matchLabels: { app: redis-bench } }
  template:
    metadata: { labels: { app: redis-bench } }
    spec:
      containers:
      - name: redis
        image: redis:7.2
        args: ["--save", "", "--appendonly", "no"]   # 关持久化：先测纯内存基线
        ports: [{ containerPort: 6379 }]
---
apiVersion: v1
kind: Service
metadata: { name: redis-bench-np }
spec:
  selector: { app: redis-bench }
  type: NodePort
  ports: [{ port: 6379, targetPort: 6379 }]
EOF
RPORT=$(kubectl get svc redis-bench-np -o jsonpath='{.spec.ports[0].nodePort}')
redis-benchmark -h "$NODE_IP" -p "$RPORT" -t set,get -n 200000 -c 50  -d 64        # 1) 基线
redis-benchmark -h "$NODE_IP" -p "$RPORT" -t set,get -n 200000 -c 500 -d 64       # 2) 连接 ×10，对比 p99
redis-benchmark -h "$NODE_IP" -p "$RPORT" -t set,get -n 200000 -c 50  -d 64 -P 16 # 3) 管道 16
```

```
（示例输出，数值随机器浮动）====== SET ======
Latency by percentile distribution:
50.000% <=  0.335 milliseconds
99.000% <=  1.191 milliseconds
Summary:
 throughput summary: 86580.08 requests per second
 latency summary (msec):  avg 0.343  min 0.080  p50 0.335  p95 0.479  p99 1.191  max 4.095
```

预期对比：`-P 16` 后吞吐约翻一个量级、p99 明显下降——瓶颈从"每命令一次 RTT"迁移到"CPU 每秒能处理多少条命令"；连接 50→500 时 p99 抬升但未必崩。留一个实验：把 `--save ""` 换成默认 RDB 或打开 AOF `everysec`，复测 SET 的 p99——持久化对写路径的代价一目了然（机制见 13-middleware/redis/02-persistence-and-ha.md）。

```bash
# [master] 清理靶场
kubectl delete deploy/nginx-bench redis-bench svc/nginx-bench-np redis-bench-np cm/nginx-bench-conf nginx-bench-page
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 压测机自己先满（CPU 100%，RPS 上不去） | 负载发生器与被压系统抢资源，或 wrk 线程开太多 | 压测机单独一台；`-t` ≈ 核数；再不够上 k6 多机分布式 |
| k6 报 `dropped iteration` / `insufficient VUs` | 开环速率超过 maxVUs 的消化能力（响应变慢，VU 周转不过来） | 这本身就是拐点信号：加大 `maxVUs` 确认拐点，或接受这就是容量上限 |
| 两轮压测结果差 3 倍 | 没预热 / 碰上 RDB 快照 / 其他 Pod 抢资源 | 固定流程：warmup → 观察基线 → 单变量改动复测 |
| 压测绿但上线即抖 | 只测读缓存路径，写路径、连接池上限、下游配额没测 | 按生产读写比混合；压测端配置对齐生产（连接池、超时、重试） |
| p99 曲线锯齿巨大 | 每级阶梯样本太少，或 GC/快照周期性干扰 | 每级至少数千样本，阶梯拉长到 1 分钟以上 |

## 自测

<details><summary>1. 为什么"系统扛住了 1000 并发"在容量规划上几乎不可用？给出两个理由并各配一个改进口径。</summary>

理由一：并发数不是稳定的负载刻度——按 Little 定律 RPS ≈ 并发数 ÷ 平均响应时间，响应从 200ms 恶化到 1s，同样 1000 并发的真实流量从 5000 RPS 掉到 1000 RPS，同一句话描述的是完全不同的负载；改以 RPS（开环 arrival-rate）为横轴。理由二：没描述拐点与瓶颈——"扛住"只说明没到饱和，规划需要"拐点在多少 RPS、第一个饱和的资源是什么"；改成报告吞吐-延迟曲线 + 拐点时的资源快照。
</details>

<details><summary>2. 同一服务，k6 constant-vus=100 测得 p99=50ms，换 constant-arrival-rate=2000/s 测得 p99=800ms。哪个可信？为什么差这么多？</summary>

可信度取决于哪个模型贴近生产流量。闭环钉死并发数 L：系统变慢时每个 VU 发请求频率自动下降（λ=L/W），饱和被负载发生器消化，延迟永远"体面"；开环钉死 λ=2000/s：消化不了就排队，队列延迟直接进 p99。差 16 倍说明 2000 RPS 已逼近或越过拐点——这本身就是重要发现，下一步是找瓶颈资源，而不是争论哪个数字"对"。
</details>

<details><summary>3. p50 很稳但 p99 周期性尖刺、约每 100ms 一次，你第一个要查的计数器是什么？</summary>

cgroup CFS 节流：CPU 用量不高但 p99 按 100ms 周期出尖刺是 limit 节流的典型指纹（CFS 带宽控制默认每 100ms 周期发一次配额，用完即挂起到下个周期）。查 `/sys/fs/cgroup/cpu.stat` 的 `nr_throttled`/`throttled_usec` 是否随尖刺增长；是则提高 limit 或查代码热点（见 04-k8s-fundamentals/11-resources-and-qos.md 第 2 节与本模块演练 C）。
</details>

<details><summary>4. 为什么跨实例聚合延迟时不能把各实例的 p99 求平均？正确做法是什么？</summary>

分位数不可平均：两实例 p99 分别 100ms 与 200ms，平均 150ms 不等于全局 p99——全局分位数取决于两边样本量加权与分布形状（极端例：双峰分布下各实例 p99 相同，全局 p99 仍可能完全不同）。正确做法：上报 histogram 桶计数而非算好的分位数，聚合端先 `sum by (le)` 合并桶再用 `histogram_quantile` 求全局分位数（PromQL 实操见 10-pca 题库）。
</details>

<details><summary>5. redis-benchmark 加 `-P 16` 后吞吐涨约 10 倍、p99 反而降了。这违背"压力更大延迟更差"的直觉吗？瓶颈发生了什么迁移？</summary>

不违背。`-P 16` 不是加压，是改变投递方式：16 条命令打包一次网络往返，每命令均摊 RTT 降到 1/16，单命令排队时间（延迟的主要成分）随之下降；吞吐上限从"每秒能完成多少次往返"迁移到"CPU 每秒能处理多少条命令"。延迟-吞吐不是单变量关系，投递方式（管道/批大小/连接复用）是第三变量——所以压测报告必须写清负载发生器全部参数，否则结果不可复现。
</details>

## 延伸阅读

- k6 官方文档（脚本、场景、阈值、Web 报告）：<https://grafana.com/docs/k6/latest/>
- k6 Scenarios（executors 与开环/闭环模型）：<https://grafana.com/docs/k6/latest/using-k6/scenarios/>
- wrk 仓库（含 Lua API README）：<https://github.com/wg/wrk>
- Apache JMeter 用户手册：<https://jmeter.apache.org/usermanual/index.html>
- Redis 官方基准指南（redis-benchmark 与注意事项）：<https://redis.io/docs/latest/operate/oss_and_stack/management/optimization/benchmarks/>
