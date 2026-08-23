# 03 · 性能调优与故障定位

> 模块：07-中间件/nginx ｜ 建议时长：3 小时 ｜ 关联认证：PCA-监控（exporter/PromQL）/ CKA-网络（ingress-nginx 排障）

## 学习目标

- 能根据业务 QPS/RT 用 Little's Law 估算 worker_connections、文件描述符与内存预算
- 能配置两级 keepalive（客户端侧 + upstream 复用）并用 TIME_WAIT 计数验证
- 能按决策树把 502/504/499 定位到"客户端、nginx、upstream"中的具体一段
- 能用 awk 从 access_log 快速产出 Top IP/状态码/耗时分布
- 能列出压测前的内核参数清单，并把 stub_status 指标接入 Prometheus

## 1. 容量估算：三个数字决定一台 nginx 能扛多少

### 1.1 估算链条

```
目标 QPS ──(Little's Law: 并发 = QPS × RT)──▶ 在途请求数
              ──▶ 反代场景连接槽 = 在途 × 2（客户端侧 + upstream 侧各一条）
              ──▶ worker_connections ≥ 连接槽 / worker_processes
              ──▶ fd 上限 ≥ worker_processes × worker_connections（+少量 listen socket）
              ──▶ 内存 ≈ 每连接槽 <1KB 用户态 + socket 内核缓冲 × 数量 + 缓冲区配置
```

例：目标 5000 QPS、平均 RT 40ms → 在途 200 个请求 → 400 个连接槽 → 4 worker × `worker_connections 1024` 已够（4096 槽）。**反代场景每请求占 2 个槽是最大坑**，纯静态服务则 1 槽 1 连接。

### 1.2 对应的配置与两条报错

```nginx
user  nginx;
worker_processes  auto;          # 一般 = CPU 核数；容器内注意读到宿主机核数
worker_rlimit_nofile  65535;     # master 为 worker setrlimit，优先级高于启动时的 ulimit

events {
    worker_connections  8192;    # 每 worker 的连接槽总数
    multi_accept on;             # 一次惊醒尽量多 accept（高突发连接时开）
}
```

| error.log 关键字 | 含义 | 第一动作 |
|---|---|---|
| `worker_connections are not enough` | 连接槽耗尽 | 调大 worker_connections（代理场景记得除以 2） |
| `24: Too many open files` | 进程 fd 到顶 | `worker_rlimit_nofile`，容器加 `--ulimit nofile=65535:65535`，包安装改 systemd `LimitNOFILE` |

经验：CPU 饱和（worker 各占满一核）时加核/加机器比调大 worker 数有效；事件驱动模型下 `worker_processes` 超过核数收益很有限。

## 2. 两级 keepalive：省掉一半 TCP 握手

### 2.1 客户端侧

```nginx
http {
    keepalive_timeout   65;    # 空闲连接保多久（0 = 关闭 keepalive）
    keepalive_requests  1000;  # 一条连接最多跑多少个请求后换新（防内存/状态累积）
}
```

浏览器/App 复用连接省的是 RTT 与拥塞窗口预热；HTTP/2 更进一步多路复用（一条连接并发多流）。

### 2.2 upstream 侧（默认不开，必须显式配）

```nginx
upstream webpool {
    server app1:80 max_fails=2 fail_timeout=10s;
    server app2:80 max_fails=2 fail_timeout=10s;
    keepalive 32;              # 每个 worker 缓存的空闲后端连接数
    keepalive_requests 1000;
    keepalive_timeout 60s;     # 空闲连接保留时长，务必 <= 后端自己的 keepalive 空闲超时
}

server {
    location / {
        proxy_http_version 1.1;          # 关键 1：默认 1.0，每个请求后自动 Connection: close
        proxy_set_header Connection "";  # 关键 2：清掉从客户端透传来的 close 头
        proxy_pass http://webpool;
    }
}
```

不配的后果链：每个请求新建一条到后端的 TCP → nginx 侧主动关闭产生 TIME_WAIT → 高 QPS 下 ephemeral port（默认 `ip_local_port_range`）耗尽 → error.log 出现 `Cannot assign requested address`，表现为**偶发 502**。这是压测必现、生产偶发的经典故障（实战演练验证）。

反向约束：`keepalive_timeout`（nginx 侧空闲保留）如果比后端的长，会拿到后端已经单方面关闭的"半死连接"，首次复用报 `upstream prematurely closed connection`——要么调短，要么让后端调长。

## 3. 502 / 504 / 499：链路定位决策树

先记本质：**4xx/5xx 的语义边界在 nginx 眼里是谁先违约**。日志里配好 `$upstream_addr`（ua）、`$upstream_status`、`$upstream_response_time`（urt）、`$request_time`（rt）四个变量，决策树就能跑：

```
日志 $status
├─ 499  客户端在 nginx 应答前主动断开（nginx 独有，RFC 里没有）
│   ├─ urt 高（接近客户端超时）──▶ 后端慢，客户端超时先到：查后端 RT、客户端 timeout
│   └─ urt 低 ──▶ 用户刷新/关页面/CDN 提前掐：抓包确认，通常无害但集中出现=前端超时配短了
├─ 502  upstream 连不上或给了无效响应
│   ├─ error.log: connection refused ──▶ 后端没监听/端口写错/容器没起
│   ├─ error.log: upstream prematurely closed ──▶ 后端 crash 或 keepalive 半死连接（见上节）
│   ├─ error.log: no live upstreams ──▶ 全部 server 被 max_fails 摘除，等 fail_timeout 恢复
│   ├─ error.log: Cannot assign requested address ──▶ 本机 ephemeral port 耗尽（upstream keepalive）
│   └─ error.log: SSL_do_handshake 失败类 ──▶ 证书/协议/SNI 配错
├─ 504  upstream 活着但超时（默认 60s）
│   ├─ (110: Connection timed out) while connecting ──▶ proxy_connect_timeout：后端过载/队列满/防火墙丢包
│   └─ while reading response header ──▶ proxy_read_timeout：应用慢查询/下游阻塞，去后端看 RT
└─ rt vs urt 对比
    ├─ rt ≈ urt ──▶ 时间都花在等后端，问题在 upstream
    └─ rt >> urt ──▶ 时间花在 nginx 本地（限流排队、buffer 落盘、CPU 打满）或网络接收
```

定位三板斧（顺序固定）：① 取 error.log 同时间戳条目看英文原话；② access_log 里看 ua/urt 判断是否所有 upstream 都慢；③ 在 nginx 所在机器直接 `curl` 后端端口，绕开 nginx 复现与否。

```nginx
log_format perf '$remote_addr [$time_local] "$request" $status '
               'rt=$request_time urt=$upstream_response_time '
               'us=$upstream_status ua="$upstream_addr"';
```

## 4. access_log 的 awk 一行流

前提：log_format 用 `perf`（上一节），示例行：

```
172.17.0.1 [22/Aug/2026:10:00:03 +0000] "GET /api/user HTTP/1.1" 200 612 rt=0.014 urt=0.011 us=200 ua="192.168.16.3:80"
```

字段位次：`$1`=IP、`$6`=URI、`$8`=status、`$9`=bytes（`$3/$4` 是时间、`$5~$7` 是请求行）。

```bash
# [Ubuntu VM] Top 10 客户端 IP
awk '{print $1}' access.log | sort | uniq -c | sort -rn | head
# [Ubuntu VM] 状态码分布
awk '{print $8}' access.log | sort | uniq -c | sort -rn
# [Ubuntu VM] 5xx 都发生在哪些 upstream（ua 字段）
awk '$8>=500 {print $12}' access.log | sort | uniq -c | sort -rn
# [Ubuntu VM] 499 集中在哪些 IP（配合客户端侧超时设置排查）
awk '$8==499 {print $1}' access.log | sort | uniq -c | sort -rn | head
# [Ubuntu VM] 平均/最大上游耗时
awk '{if(match($0,/urt=[0-9.]+/)){u=substr($0,RSTART+4,RLENGTH-4)+0;s+=u;n++;if(u>m)m=u}}
     END{if(n)printf "cnt=%d avg=%.3f max=%.3f\n",n,s/n,m}' access.log
# [Ubuntu VM] P95 上游耗时
awk '{if(match($0,/urt=[0-9.]+/))print substr($0,RSTART+4,RLENGTH-4)+0}' access.log \
  | sort -n | awk '{v[NR]=$1} END{print "p95="v[int(NR*0.95)]}'
# [Ubuntu VM] 按"总上游耗时"排序的 Top 10 URL（优化优先级清单）
awk '{if(match($0,/urt=[0-9.]+/)){t=substr($0,RSTART+4,RLENGTH-4)+0;sum[$6]+=t;cnt[$6]++}}
     END{for(u in sum)printf "%9.3fs %6d req %s\n",sum[u],cnt[u],u}' access.log | sort -rn | head
```

注意：URL 若恰含 `urt=` 会误伤锚点（换字段名规避）；失败重试时 `$upstream_response_time` 是逗号分隔多值，精确统计先 `tr ',' ' '` 展开。

## 5. 内核参数清单

```bash
# [Ubuntu VM] 写入 /etc/sysctl.d/99-nginx.conf
sudo tee /etc/sysctl.d/99-nginx.conf >/dev/null <<'EOF'
# accept 队列上限 = min(somaxconn, 应用 listen backlog)；默认 128(4096) 在突发连接下必丢
net.core.somaxconn = 8192
# 收包 backlog，高 pps 场景同步调大
net.core.netdev_max_backlog = 16384
# nginx 作为"客户端"连 upstream 时的源端口池，默认 32768~60999 不够高 QPS 用
net.ipv4.ip_local_port_range = 1024 65535
# 仅对"主动发起连接"的方向复用 TIME_WAIT，正好覆盖 nginx->upstream
net.ipv4.tcp_tw_reuse = 1
# 系统级 fd 总量
fs.file-max = 1048576
EOF
sudo sysctl --system
```

配套两件事：nginx 的 `listen 80 backlog=8192;`（nginx 在 Linux 上默认 backlog 511，会把调大的 somaxconn 架空）；改完 somaxconn 要**重启 nginx**（accept 队列长度在 listen() 创建 socket 时生效，reload 对已存在的监听 socket 不一定重建）。验证：

```bash
# [Ubuntu VM] Send-Q 列就是该监听端口的 backlog 上限
ss -lnt | grep -E '(:80|:443)\b'
```

## 6. ingress-nginx 就是 nginx

K8s 里的 Ingress（第 2 章学的所有东西直接适用）：controller 只是"翻译器 + 配置管理器"，数据面仍是那个 master-worker：

```
kubectl apply 的 Ingress/Service/YAML
        │ watch
        ▼
ingress-nginx-controller Pod（含 nginx 进程 + Lua 动态 upstream）
        │ 生成 nginx.conf → nginx -t 校验 → reload
        ▼
容器内 /etc/nginx/nginx.conf ──▶ worker ──▶ Endpoints 里的各业务 Pod
```

排障时把第 3 章工具箱平移过来：

```bash
# [master] 看 controller 实际生成的完整配置（定位 location/rewrite 问题的终极手段）
kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- nginx -T | less
# [master] 看 error.log（502/504 的第一现场，报错关键字与本章决策树完全一致）
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=50 | grep -E 'upstream|error'
```

YAML 到 nginx 语义的映射要点：`pathType: Exact` 生成 `location = /path`，`Prefix` 生成前缀 location，正则路径用 `rewrite-target` + 捕获组（此时生成正则 location，优先级规则同第 2 章）；upstream 不再是静态 server 列表而是 Endpoints 动态注入，"被动健康检查"的角色由 Pod 的 readiness probe 接管——**K8s 里后端摘流靠探针，不靠 max_fails**。常用注解即本章指令的换皮：`proxy-read-timeout`→`proxy_read_timeout`、`limit-rps`→`limit_req`、`proxy-body-size`→`client_max_body_size`、`whitelist-source-range`→`allow/deny`。

## 7. nginx 指标接入 Prometheus

### 7.1 stub_status：内建但不是 Prometheus 格式

```nginx
server {
    listen 80;
    location = /stub_status {
        stub_status;
        allow 127.0.0.1;   # 只给本机与 exporter
    }
}
```

```
Active connections: 15
server accepts handled requests
 8456 8456 32891
Reading: 0 Writing: 1 Waiting: 14
```

### 7.2 nginx-prometheus-exporter 转格式

```bash
# [Ubuntu VM] exporter 抓 stub_status，暴露 9113/metrics
docker run -d --name ngx-exporter --network lbnet -p 9113:9113 \
  nginx/nginx-prometheus-exporter:1.3.0 \
  --nginx.scrape-uri=http://ngx3:80/stub_status
curl -s http://127.0.0.1:9113/metrics | grep '^nginx_'
```

核心指标：`nginx_connections_active/reading/writing/waiting`（gauge）、`nginx_connections_accepted/handled`（counter）、`nginx_http_requests_total`（counter）。Prometheus 侧抓取与告警规则：

```yaml
# prometheus.yml 追加（<VM_IP> 换成实际地址）
scrape_configs:
  - job_name: nginx
    static_configs:
      - targets: ['<VM_IP>:9113']
```

```yaml
# rules/nginx.yml
groups:
  - name: nginx
    rules:
      - record: nginx:qps:rate5m
        expr: sum(rate(nginx_http_requests_total[5m]))
      - alert: NginxTrafficZero
        expr: sum(rate(nginx_http_requests_total[10m])) == 0
        for: 15m
        labels:
          severity: critical
        annotations:
          summary: 'nginx 最近 15 分钟无任何请求'
```

ingress-nginx 不需要额外 exporter：controller 自带 `/metrics`（默认 10254 端口），且带 label 维度，最常用的是按状态码算错误率（PCA 高频考点）：

```promql
# ingress 5xx 比例（按 ingress/class 还能加 by (...) 维度）
sum(rate(nginx_ingress_controller_requests{status=~"5.."}[5m]))
/
sum(rate(nginx_ingress_controller_requests[5m]))
```

## 实战演练

环境：装有 Docker 的 Ubuntu VM。拓扑：nginx（ngx3）反代 app1/app2，另有一个 65 秒才响应的 slow 后端用于制造 504/499。

**第 1 步：起全栈。**

```bash
# [Ubuntu VM]
sudo apt-get update && sudo apt-get install -y apache2-utils   # 提供 ab
docker network create perfnet
docker run -d --name app1 --network perfnet hashicorp/http-echo -text=app1 -listen=:80
docker run -d --name app2 --network perfnet hashicorp/http-echo -text=app2 -listen=:80
mkdir -p /opt/nginx-perf

cat > /opt/nginx-perf/slow.py <<'EOF'
import http.server, os, time

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(float(os.environ.get("SLEEP", "65")))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"slow response\n")

http.server.HTTPServer(("0.0.0.0", 80), H).serve_forever()
EOF
docker run -d --name slow --network perfnet -v /opt/nginx-perf/slow.py:/slow.py:ro \
  -e SLEEP=65 python:3.12-alpine python /slow.py
```

```bash
# [Ubuntu VM] nginx 配置：upstream keepalive + stub_status + 慢后端路由
cat > /opt/nginx-perf/nginx.conf <<'EOF'
user  nginx;
worker_processes  2;
worker_rlimit_nofile 65535;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;
events { worker_connections 8192; }
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format perf '$remote_addr [$time_local] "$request" $status '
                    'rt=$request_time urt=$upstream_response_time '
                    'us=$upstream_status ua="$upstream_addr"';
    access_log /var/log/nginx/access.log perf;
    keepalive_timeout 65;

    upstream webpool {
        server app1:80 max_fails=2 fail_timeout=10s;
        server app2:80 max_fails=2 fail_timeout=10s;
        keepalive 32;
        keepalive_requests 1000;
        keepalive_timeout 60s;
    }
    server {
        listen 80;
        location = /stub_status { stub_status; allow 127.0.0.1; }
        location / {
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_pass http://webpool;
        }
        location /slow {
            proxy_connect_timeout 3s;
            proxy_read_timeout 5s;     # 5 秒读不到响应头就 504
            proxy_pass http://slow;
        }
    }
}
EOF

docker run -d --name ngx3 --network perfnet -p 8089:80 \
  -v /opt/nginx-perf/nginx.conf:/etc/nginx/nginx.conf:ro \
  nginx:1.27
docker exec ngx3 nginx -t
```

**第 2 步：验证 upstream keepalive 的收益。** 先把 keepalive 三件套注释掉，制造"每请求新建 TCP"：

```bash
# [Ubuntu VM] 注释掉 keepalive 相关行并 reload
sed -i -e 's/^    keepalive 32;/    #keepalive 32;/' \
       -e 's/^    keepalive_requests 1000;/    #keepalive_requests 1000;/' \
       -e 's/^    keepalive_timeout 60s;/    #keepalive_timeout 60s;/' \
       -e 's/^        proxy_http_version 1.1;/        #proxy_http_version 1.1;/' \
       -e 's/^        proxy_set_header Connection "";/        #proxy_set_header Connection "";/' \
       /opt/nginx-perf/nginx.conf
docker exec ngx3 nginx -t && docker exec ngx3 nginx -s reload
ab -n 3000 -c 20 -q http://127.0.0.1:8089/ | grep -E 'Requests per second|Time per request'
# [Ubuntu VM] 统计 nginx 网络命名空间里的 TIME_WAIT（/proc/net/tcp 第 4 列 06 = TIME_WAIT）
docker exec ngx3 sh -c 'cat /proc/net/tcp | grep -c " 06 "'
```

预期：Requests/s 较低，TIME_WAIT 计数达数百。恢复配置再压一次对比：

```bash
# [Ubuntu VM] 去掉注释（reload 生效）后复测
sed -i -e 's/^    #keepalive /    keepalive /' \
       -e 's/^        #proxy_http_version/        proxy_http_version/' \
       -e 's/^        #proxy_set_header Connection/        proxy_set_header Connection/' \
       /opt/nginx-perf/nginx.conf
docker exec ngx3 nginx -t && docker exec ngx3 nginx -s reload
ab -n 3000 -c 20 -q http://127.0.0.1:8089/ | grep -E 'Requests per second|Time per request'
docker exec ngx3 sh -c 'cat /proc/net/tcp | grep -c " 06 "'
```

预期：吞吐上升、TIME_WAIT 接近个位数——upstream 连接被复用了。

**第 3 步：制造 504 与 499。**

```bash
# [Ubuntu VM] slow 后端 65s 才回，proxy_read_timeout 5s -> 504
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8089/slow
# [Ubuntu VM] 客户端 2 秒先断开 -> nginx 记 499（对照 504 理解"谁先违约"）
curl -s -o /dev/null --max-time 2 -w '%{http_code}\n' http://127.0.0.1:8089/slow || true
docker exec ngx3 tail -n 2 /var/log/nginx/access.log
docker exec ngx3 tail -n 2 /var/log/nginx/error.log
```

access.log 预期：一条 `504 ... rt=5.001 urt=5.001`、一条 `499 ... rt=2.00x`；error.log 预期：`upstream timed out (110: Connection timed out) while reading response header`。

**第 4 步：用 awk 复盘日志。**

```bash
# [Ubuntu VM] 把日志拷出来跑第 4 节的一行流
docker cp ngx3:/var/log/nginx/access.log /tmp/access.log
awk '{print $8}' /tmp/access.log | sort | uniq -c | sort -rn
awk '{if(match($0,/urt=[0-9.]+/)){u=substr($0,RSTART+4,RLENGTH-4)+0;s+=u;n++;if(u>m)m=u}}
     END{if(n)printf "cnt=%d avg=%.3f max=%.3f\n",n,s/n,m}' /tmp/access.log
```

**第 5 步：指标接入 exporter。**

```bash
# [Ubuntu VM]
docker run -d --name ngx-exporter --network perfnet -p 9113:9113 \
  nginx/nginx-prometheus-exporter:1.3.0 \
  --nginx.scrape-uri=http://ngx3:80/stub_status
ab -n 2000 -c 10 -q http://127.0.0.1:8089/ >/dev/null
curl -s http://127.0.0.1:9113/metrics | grep '^nginx_connections\|^nginx_http_requests_total'
```

预期输出形如 `nginx_connections_active 10`、`nginx_http_requests_total 5xxx`（counter 随压测增长，`rate()` 后即 QPS）。

```bash
# [Ubuntu VM] 清理
docker rm -f ngx3 ngx-exporter app1 app2 slow && docker network rm perfnet
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 压测偶发 502，error.log `Cannot assign requested address` | upstream 未配 keepalive，TIME_WAIT 耗尽源端口 | upstream `keepalive` + `proxy_http_version 1.1` + `Connection ""`，扩 `ip_local_port_range` |
| 少量 `upstream prematurely closed connection` | 后端 keepalive 空闲超时比 nginx 短，拿到半死连接 | nginx `keepalive_timeout` 调短于后端，或后端调长 |
| 调大 somaxconn 无效 | listen backlog（默认 511）更小，或没重启 nginx | `listen ... backlog=8192`，改完重启 |
| 压测机打了 499 | ab/curl 自身超时先于 proxy_read_timeout | 区分"客户端放弃"与"后端超时"，看 urt 与 error.log |
| `24: Too many open files` | fd 上限没跟上连接数 | `worker_rlimit_nofile` + 容器 `--ulimit` / systemd `LimitNOFILE` |
| reload 后连接数没释放 | 长连接被旧 worker 持有 | `worker_shutdown_timeout` 强制 draining |
| exporter 抓不到 stub_status | allow 列表没放行 exporter 来源 | allow 加 exporter 网段，或 exporter 与 nginx 同网络/走 127.0.0.1 |

## 自测

<details><summary>1. 目标 8000 QPS、RT 100ms，worker_processes=4 时 worker_connections 至少多少？还要同步核对什么？</summary>

在途请求 = 8000 × 0.1 = 800；反代占 2 槽 → 1600 槽；4 worker 平摊每个 400，再留峰值余量（2~3 倍）建议 `worker_connections 2048` 起步。同步核对：fd 上限 ≥ 4×2048（worker_rlimit_nofile/ulimit）、内核 somaxconn 与 listen backlog、upstream keepalive 是否开启（否则源端口先爆）、内存（每槽用户态几百字节 + socket 缓冲）。最后用压测验证而非纸面推演。
</details>

<details><summary>2. upstream keepalive 为什么必须同时配 `proxy_http_version 1.1` 和 `proxy_set_header Connection ""`？少一个会怎样？</summary>

默认的 HTTP/1.0 转发没有 keepalive 语义，nginx 每请求结束就关连接，`keepalive` 池形同虚设；而即使升到 1.1，客户端传来的 `Connection: close` 头会被原样透传给后端，后端照样单请求即关。所以一个解决协议版本、一个清掉干扰头，缺一不可。另外注意 `proxy_set_header` 存在会使该 location 的继承断链，其他需要的头要一并显式写。
</details>

<details><summary>3. 499 和 504 都"表现为客户端没拿到响应"，本质区别是什么？一条请求可能先 499 后 504 吗？</summary>

499 是客户端主动断开时 nginx 记录的状态（nginx 对外的账），504 是 nginx 等后端超时后准备回给客户端的状态。同一条请求里客户端 2 秒断开、nginx 5 秒才等到超时，最终 access_log 记 499（客户端先违约，504 的响应无人接收）；nginx 侧的 upstream 请求通常还会继续等到 read timeout 或被中断。所以排查时 499 看"客户端为什么急"，504 看"后端为什么慢"。
</details>

<details><summary>4. `rt=5.2 urt=0.03` 说明什么？反过来的 `rt=0.05 urt=0.04` 但用户抱怨慢又说明什么？</summary>

前者：时间几乎都花在 nginx 等待之外——urt 只计 upstream 响应耗时，rt 是全请求耗时，巨大差值指向 limit_req 排队、buffer 落盘、CPU 打满或客户端到 nginx 的网络慢。后者：nginx 全链路很快，慢在客户端自己的网络或前端渲染，应去 CDN/客户端侧排查，加 nginx 机器无益。
</details>

<details><summary>5. 为什么 ingress-nginx 里找不到 max_fails/fail_timeout 的身影？摘除故障 Pod 靠什么机制？</summary>

controller 的 upstream 是用 Lua 从 Endpoints 动态生成的，K8s 的责任边界是：readiness probe 失败 → Endpoints Controller 把 Pod IP 从 EndpointSlice 摘除 → controller 感知并更新 upstream。健康检查下沉给了控制面，nginx 数据面只负责转发，所以无需（也基本无法）用被动计数摘流。相应地，排查 K8s 里的 502 要先看 Endpoints 是否为空，而不是后端进程本身。
</details>

<details><summary>6. stub_status 接入 Prometheus 后能做哪些告警？做不了哪些？补齐维度靠什么？</summary>

能做：QPS 突降（`rate(nginx_http_requests_total[5m])`）、连接饱和（`nginx_connections_active` 接近 workers×worker_connections）、读写堆积。做不了：按 URL/状态码/upstream 维度拆分——stub_status 是全局聚合值。补齐维度用 NGINX Plus API、带维度的模块，或在 ingress-nginx 上用自带 label 的 `nginx_ingress_controller_requests`（见第 7 节末尾的 PromQL）。
</details>

## 延伸阅读

- 内核参数与 socket 调优官方指南：https://nginx.org/en/docs/http/ngx_http_core_module.html#listen
- upstream keepalive 官方示例：https://nginx.org/en/docs/http/ngx_http_upstream_module.html#keepalive
- stub_status 模块：https://nginx.org/en/docs/http/ngx_http_stub_status_module.html
- nginx-prometheus-exporter（官方仓库）：https://github.com/nginxinc/nginx-prometheus-exporter
- ingress-nginx controller（含 /metrics 与注解手册）：https://github.com/kubernetes/ingress-nginx
- Linux ip(7)（ip_local_port_range/端口耗尽）：https://man7.org/linux/man-pages/man7/ip.7.html
