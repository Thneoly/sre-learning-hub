# 02 · 反向代理与负载均衡：核心配置

> 模块：07-中间件/nginx ｜ 建议时长：3 小时 ｜ 关联认证：CKA-网络（Ingress 的底层就是这套机制）/ —

## 学习目标

- 能默写 location 匹配优先级的完整顺序，并用 curl 实验验证
- 能为 upstream 选择正确的负载策略（轮询/weight/ip_hash/least_conn/random）并说明取舍
- 能预测 `proxy_pass` 带/不带 URI 时后端实际收到的路径
- 能配置被动健康检查（max_fails/fail_timeout）、TLS 终止、limit_req/limit_conn

## 1. 指令上下文：先搞清"指令能写在哪儿"

排障一半的错误是"指令放错了上下文"。nginx 的配置是一棵树：

```
main      # worker_processes / load_module / error_log
├─ events   # worker_connections / use epoll
├─ http     # 上面所有全局性指令: log_format / limit_req_zone / upstream / map
│  ├─ server      # listen / server_name / ssl_certificate
│  │  ├─ location   # proxy_pass / root / return ...
│  │  └─ location
│  └─ upstream    # server / keepalive / zone ...
└─ stream   # 四层代理
```

三条高频规则：

- `limit_req_zone`、`upstream`、`log_format`、`map` 只能写在 **http 层**，`limit_req` 才是 location 层的"开关"。
- 同名指令的继承：子级不写就继承父级；**子级一旦写了同族指令（最典型是 `add_header` 与 `proxy_set_header`），父级配置全部作废**，不会合并。
- 改完配置先 `nginx -t` 再 `nginx -s reload`，`reload` 失败不影响存量连接（原理见第 1 章）。

## 2. location 匹配优先级：完整顺序与验证

### 2.1 匹配算法

nginx 收到请求后按下面顺序决策（匹配对象是解码、归一化后的 URI，**不含 query string**）：

```
1. 精确匹配 location = /uri            ──命中──▶ 直接用，结束
2. 记住"最长前缀匹配"（含 ^~ 与普通前缀都参与比较）
   └─ 若这个最长前缀是 ^~ 修饰的        ──────▶ 跳过正则，直接用它
3. 按配置文件出现顺序逐个试正则：
   ~   区分大小写
   ~*  不区分大小写                     ──命中──▶ 用第一个命中的正则
4. 所有正则都不命中                      ──────▶ 用第 2 步记住的最长前缀
5. 命名 location @fallback 不参与 URI 匹配，只能被 try_files / error_page 内部跳转
```

| 优先级 | 修饰符 | 含义 | 特性 |
|---|---|---|---|
| 1 | `=` | 精确等于 | 命中后不再看任何其他 location，最快 |
| 2 | `^~` | 前缀匹配 | "信任前缀"：若是**最长**前缀，则不再查正则 |
| 3 | `~` | 正则，区分大小写 | 按配置顺序，先到先得 |
| 3 | `~*` | 正则，不区分大小写 | 与 `~` 同级，同样按顺序 |
| 4 | 无 | 普通前缀 | 取最长者；`location /` 是它的一种，兜底 |

最容易被忽略的两点：**`^~` 并不比正则"优先级高"**——它必须同时是"最长前缀"才能压制正则；**正则之间没有"谁更精确"，只有谁写在前面**。

### 2.2 验证方法（见实战演练第 3 步）

标准做法：给每个 location 一个唯一的 `return 200 "标签"` 或 `add_header X-Loc`，然后用 `curl -s`（配合 `-D-` 看 header）逐个 URI 打过去，看返回的标签。任何 location 疑难问题都能用这个 5 分钟实验定论，不要靠背规则赌。

## 3. upstream 负载策略

| 策略 | 配置 | 选后端规则 | 适用/坑 |
|---|---|---|---|
| 轮询（默认） | `server a; server b;` | 依次轮流 | 无状态服务默认选择 |
| 加权轮询 | `server a weight=3;` | 按权重比例，平滑加权（连续请求也会按 3:1 交错打散，不是攒够一批再切） | 后端机器配置不均 |
| ip_hash | `ip_hash;` | 按 `$remote_addr`（IPv4 取前 24 位，IPv6 取全部）hash 定向后端，落点同时考虑权重 | 无 session 共享时的粘性；扩容/缩容会大面积换后端，分布不均 |
| least_conn | `least_conn;` | 活跃连接数/权重 最小者 | 请求耗时差异大的场景（部分慢请求不至于全压一台） |
| random | `random two least_conn;` | 随机取 2 台再按 least_conn 挑 1 | 高 QPS 下减少多 worker 争用（配合共享 zone） |
| hash | `hash $request_uri consistent;` | 一致性 hash | 缓存命中场景；`consistent` 减少节点变动时的 key 迁移 |

被动健康检查写在 server 行上（开源版只有被动，主动探活是 NGINX Plus 的 `health_check` 能力）：

```nginx
upstream webpool {
    # 10 秒窗口内失败 2 次 -> 标记为 down，持续 10 秒内不再派新请求
    server app1:80 weight=3 max_fails=2 fail_timeout=10s;
    server app2:80 weight=1 max_fails=2 fail_timeout=10s;
    server app3:80 backup;          # 全挂了才启用的备胎
}
```

- **fail_timeout 是双重含义**：既是"统计失败的窗口"，又是"判定 down 之后的惩罚时长"。默认 `max_fails=1`、`fail_timeout=10s`；`max_fails=0` 表示永不参与统计。
- **什么算失败**由 `proxy_next_upstream` 决定（默认 `error timeout`：连接失败/超时；HTTP 5xx 默认不算，需要显式加 `http_500 http_502` 等）。
- upstream 里加 `zone webpool 64k;`（共享内存）后，各 worker 共享同一份失败计数；不加则每个 worker 各记各的，判定会有短暂不一致。

## 4. proxy_pass 的路径改写坑

**规则一句话：`proxy_pass` 带 URI（即写了 `/` 或路径）就把 location 匹配到的那段前缀替换掉；不带 URI 就把原始 URI 原样透传。**

| # | location | proxy_pass | 请求 URI | 后端收到 | 说明 |
|---|---|---|---|---|---|
| 1 | `location /api/` | `http://webpool` | `/api/user` | `/api/user` | 无 URI，原样透传 |
| 2 | `location /api/` | `http://webpool/` | `/api/user` | `/user` | 前缀 `/api/` 被替换为 `/` |
| 3 | `location /api` | `http://webpool/` | `/api/user` | `//user` | 经典双斜杠坑：location 少写尾斜杠 |
| 4 | `location /api/` | `http://webpool/v1/` | `/api/user` | `/v1/user` | 换前缀顺便改写版本路径 |
| 5 | `location ~ ^/api/` | `http://webpool/` | — | — | 启动即报错：正则 location 禁止带 URI |
| 6 | `location ~ ^/api/(.*)$` | `http://webpool/$1$is_args$args` | `/api/user?id=1` | `/user?id=1` | 正则 + 变量自己拼，query string 要手动接 |
| 7 | `location /api/` | `http://$upstream_host$uri` | `/api/user` | `/api/user` | 变量模式：自动改写整体关闭，全手工 |

第 5 行报错信息为 `proxy_pass cannot have URI part in location given by regular expression`，`nginx -t` 阶段就能拦住。第 7 行用变量时，变量里若是域名而非 upstream 名，还需要 `resolver` 指令做运行时 DNS 解析（容器/云环境常见坑）。

## 5. proxy_buffering：慢客户端不许拖住后端

默认 `proxy_buffering on`。nginx 用最快的速度把 upstream 响应读进自己的缓冲区（`proxy_buffer_size` 放响应头第一段，`proxy_buffers` 放 body，溢出时落临时文件，上限 `proxy_max_temp_file_size` 默认 1g），再按客户端自己的网速慢慢发：

```
proxy_buffering on（默认）
  upstream ═══▶ [nginx 缓冲区/临时文件] ──▶ 慢客户端
                后端连接早早释放，worker 不被慢客户端占住

proxy_buffering off
  upstream ────────▶ 客户端（同步转发，来一字节转一字节）
```

运维要点：

- **off 的正当场景**：SSE/流式响应（`text/event-stream` 类响应需要实时推给客户端）、大文件想省 nginx 磁盘。后端也可用响应头 `X-Accel-Buffering: no` 精细控制单接口。
- **on 的排障推论**：一旦 nginx 已把部分响应字节发还客户端，`proxy_next_upstream` 的失败转移就失效了——重试意味着响应内容前后拼接出错。所以"偶发截断 + 无重试"要看 buffering 与超时的配合。
- 缓冲占用的是 worker 内存，`proxy_buffers` 不要无脑调大；高并发大响应才需要动。

## 6. TLS 终止

架构：客户端 --TLS--> nginx --明文 HTTP--> 后端。证书只管到 nginx，后端不发热点：

```
[Client] ==TLS1.3==> [nginx :443  解密/验牌/限流] --HTTP--> [app:8080]
                     证书在这里                    加 X-Forwarded-* 头
```

```nginx
# http 层统一参数
limit_req_zone $binary_remote_addr zone=reqperip:10m rate=5r/s;

server {
    listen 443 ssl;
    server_name demo.local;

    ssl_certificate     /etc/nginx/certs/tls.crt;
    ssl_certificate_key /etc/nginx/certs/tls.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;   # 跨 worker 共享会话，减少 full handshake
    ssl_session_timeout 10m;

    location / {
        proxy_pass http://webpool;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;  # 逐跳追加，保留链路
        proxy_set_header X-Forwarded-Proto https;   # 后端据此生成 https 的外链/重定向
    }
}
```

注意 `http2 on;` 是 1.25.1+ 的新写法，老版本要写在 `listen 443 ssl http2;` 里。真实 IP 链路：如果 nginx 前面还有 LB，需要 `real_ip_header X-Forwarded-For` + `set_real_ip_from` 还原，否则日志与限流看到的都是 LB 的 IP。

## 7. 限流：limit_req 与 limit_conn

```nginx
# http 层声明（zone 大小决定能记住多少个 key，耗尽时淘汰最久未用的状态）
limit_req_zone  $binary_remote_addr zone=reqperip:10m rate=5r/s;   # 令牌桶：每秒补 5 个令牌
limit_conn_zone $binary_remote_addr zone=connperip:10m;

server {
    listen 80;
    location /api/ {
        limit_req zone=reqperip burst=10 nodelay;
        limit_req_status 429;                 # 默认 503，改 429 更语义化
        limit_conn connperip 10;              # 每 IP 最多 10 条并发连接
        proxy_pass http://webpool/;
    }
}
```

- **limit_req 是令牌桶**：`rate` 是补充速率；`burst` 是桶深度（排队额度）；`nodelay` 表示突发请求立即处理、不排队但消耗额度。瞬时打来 50 个请求（rate=5、burst=10、nodelay）：前 11 个左右立即通过，其余直接 429。**不带 `nodelay` 时超额请求会排队等令牌**，表现为"请求变慢"而不是"被拒"。
- **limit_conn 数的是并发连接数**，防的是单 IP 挂着连接不干活；key 同样建议用 `$binary_remote_addr`（比字符串地址省一半内存）。
- key 选 `$remote_addr` 的前提是 nginx 就是流量的第一跳；前面有 LB 时要换成 realip 还原后的变量或 `X-Forwarded-For` 的第一个值，否则限的是"整个 LB"。

## 实战演练

环境：装有 Docker 的 Ubuntu VM。拓扑：nginx 反代三个后端（app1/app2 用于加权轮询，whoami 用于观察路径改写）。

**第 1 步：起后端与网络。**

```bash
# [Ubuntu VM]
docker network create lbnet
docker run -d --name app1 --network lbnet hashicorp/http-echo -text=app1 -listen=:80
docker run -d --name app2 --network lbnet hashicorp/http-echo -text=app2 -listen=:80
docker run -d --name whoami --network lbnet traefik/whoami
```

**第 2 步：写配置并启动 nginx。**

```bash
# [Ubuntu VM]
mkdir -p /opt/nginx-demo/certs
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /opt/nginx-demo/certs/tls.key -out /opt/nginx-demo/certs/tls.crt \
  -subj "/CN=demo.local" -addext "subjectAltName=DNS:demo.local"
```

```bash
# [Ubuntu VM] 写入 /opt/nginx-demo/nginx.conf（heredoc 加引号避免 $ 变量被 shell 展开）
cat > /opt/nginx-demo/nginx.conf <<'EOF'
user  nginx;
worker_processes  2;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

events { worker_connections 1024; }

http {
    include      /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format main '$remote_addr [$time_local] "$request" $status '
                    'up=$upstream_addr rt=$request_time urt=$upstream_response_time';
    access_log /var/log/nginx/access.log main;
    sendfile on;
    keepalive_timeout 65;

    limit_req_zone $binary_remote_addr zone=reqperip:10m rate=5r/s;

    upstream webpool {
        server app1:80 weight=3 max_fails=2 fail_timeout=10s;
        server app2:80 weight=1 max_fails=2 fail_timeout=10s;
    }

    # 80：反代 + 路径改写 + 限流
    server {
        listen 80;
        add_header X-Upstream $upstream_addr always;
        location / {
            proxy_pass http://webpool;
            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
        location /api/ {
            limit_req zone=reqperip burst=10 nodelay;
            limit_req_status 429;
            proxy_pass http://whoami/;     # 带 URI：/api/user -> whoami:/user
            proxy_set_header Host $host;
        }
    }

    # 8081：location 匹配练习
    server {
        listen 8081;
        default_type text/plain;
        location = /exact            { return 200 "A: = /exact\n"; }
        location ^~ /prefix/         { return 200 "B: ^~ /prefix/\n"; }
        location /prefix/preflong/   { return 200 "C: /prefix/preflong/\n"; }
        location ~ ^/prefix/.*\.jpg$ { return 200 "D: ~ jpg regex\n"; }
        location ~* \.(js|css)$      { return 200 "E: ~* js|css\n"; }
        location /                   { return 200 "F: /\n"; }
    }

    # 443：TLS 终止
    server {
        listen 443 ssl;
        server_name demo.local;
        ssl_certificate     /etc/nginx/certs/tls.crt;
        ssl_certificate_key /etc/nginx/certs/tls.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_cache shared:SSL:10m;
        location / {
            proxy_pass http://webpool;
            proxy_set_header X-Forwarded-Proto https;
        }
    }
}
EOF

docker run -d --name ngx2 --network lbnet \
  -p 8088:80 -p 8081:8081 -p 8443:443 \
  -v /opt/nginx-demo/nginx.conf:/etc/nginx/nginx.conf:ro \
  -v /opt/nginx-demo/certs:/etc/nginx/certs:ro \
  nginx:1.27
docker exec ngx2 nginx -t
```

**第 3 步：验证 location 优先级。**

```bash
# [Ubuntu VM] 逐条打 URI，核对返回标签
for uri in /exact /prefix/a.js /prefix/preflong/x.js /prefix/preflong/x.jpg \
           /prefix/preflong/other /foo.css /anything; do
  printf '%-24s -> %s' "$uri" "$(curl -s http://127.0.0.1:8081$uri)"
done
```

预期（对照第 2.1 节算法逐条推一遍）：

```
/exact                  -> A: = /exact          （精确命中，结束）
/prefix/a.js            -> B: ^~ /prefix/       （最长前缀就是 ^~，正则被压制）
/prefix/preflong/x.js   -> E: ~* js|css         （最长前缀是普通前缀 C，仍要查正则）
/prefix/preflong/x.jpg  -> D: ~ jpg regex       （正则按顺序，D 写在 E 前面）
/prefix/preflong/other  -> C: /prefix/preflong/ （正则全不中，回退最长前缀）
/foo.css                -> E: ~* js|css
/anything               -> F: /                 （兜底）
```

**第 4 步：验证加权轮询。**

```bash
# [Ubuntu VM] 连续 40 个请求统计归属
for i in $(seq 40); do curl -s http://127.0.0.1:8088/; done | sort | uniq -c
# 预期（平滑加权轮询）：app1 30 次、app2 10 次
curl -s -D - -o /dev/null http://127.0.0.1:8088/ | grep -i x-upstream   # 看实际命中哪个后端
```

**第 5 步：验证路径改写。**

```bash
# [Ubuntu VM] whoami 会把收到的请求行原样吐回来
curl -s http://127.0.0.1:8088/api/user | grep '^GET'
# 预期：GET /user HTTP/1.1    （/api/ 被替换为 /）
```

把 `proxy_pass http://whoami/;` 的尾斜杠删掉、reload 再试，`GET` 行会变成 `/api/user`——带/不带 URI 的差异一目了然：

```bash
# [Ubuntu VM]
sed -i 's|proxy_pass http://whoami/;|proxy_pass http://whoami;|' /opt/nginx-demo/nginx.conf
docker exec ngx2 nginx -t && docker exec ngx2 nginx -s reload
curl -s http://127.0.0.1:8088/api/user | grep '^GET'
```

**第 6 步：验证限流。**

```bash
# [Ubuntu VM] 快速打 15 发（rate=5/s burst=10 nodelay：前 11 个左右 200，其余 429）
for i in $(seq 15); do curl -s -o /dev/null -w '%{http_code} ' http://127.0.0.1:8088/api/burst; done; echo
```

**第 7 步：被动健康检查——挂后端与恢复。**

```bash
# [Ubuntu VM] 挂掉 app2：请求全部由 app1 兜住，客户端无感知（失败转移到另一台）
docker stop app2
for i in $(seq 6); do curl -s http://127.0.0.1:8088/; done | sort | uniq -c
docker exec ngx2 tail -n 5 /var/log/nginx/error.log   # connect() failed (111: Connection refused)

# 再挂掉 app1：两台全灭，nginx 无处可转 -> 502
docker stop app1
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8088/

# 恢复：max_fails 已把它们标记 down，最迟 fail_timeout(10s) 后自动重新纳入
docker start app2 app1
sleep 11
for i in $(seq 40); do curl -s http://127.0.0.1:8088/; done | sort | uniq -c
```

**第 8 步：TLS 终止验证。**

```bash
# [Ubuntu VM] --resolve 把 demo.local 指到本机，模拟真实域名访问（证书是自签的，所以要 -k）
curl -sk --resolve demo.local:8443:127.0.0.1 https://demo.local:8443/
curl -sk -D - -o /dev/null --resolve demo.local:8443:127.0.0.1 https://demo.local:8443/ | head -n 3
```

预期：正文是 app1/app2，响应头 `HTTP/1.1 200 OK` 且 `Server: nginx`；`docker exec ngx2 tail /var/log/nginx/access.log` 中 `/` 的请求来自 TLS server 块。

```bash
# [Ubuntu VM] 用完清理
docker rm -f ngx2 app1 app2 whoami && docker network rm lbnet
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 后端收到的路径多/少一段（`//user`、`v1//x`） | location 与 proxy_pass 的尾斜杠组合错误（对照第 4 节表） | 用 whoami 这类回显后端实测，两边斜杠要么都有要么都没有 |
| `nginx -t` 报 `proxy_pass cannot have URI part...` | 正则 location 里 proxy_pass 带了 URI | 改用变量拼 `$1`，或把前缀改成普通/`^~` location |
| 某接口 429/503 超预期 | `limit_req` 无 burst，页面一次拉十几个资源直接超桶 | 加 `burst=N nodelay`，key 按接口分开建 zone |
| 限流把全网限成一个人 | nginx 前有 LB，`$remote_addr` 是 LB IP | realip 模块还原，或按 XFF 第一跳建 key |
| 加了 `add_header` 后外层 header 消失 | add_header 族继承断裂：location 里一写，server 层全作废 | 在 location 里把需要的 header 重写一遍 |
| ip_hash 扩容后大量会话漂移 | hash 环重排 | 换 `hash key consistent`，或做 session 外置（Redis） |
| 后端重定向跳到 `http://` 被浏览器拦 | nginx TLS 终止后没传 `X-Forwarded-Proto` | proxy_set_header X-Forwarded-Proto https，后端框架读取该头 |
| 5xx 时 nginx 不切换后端 | 默认 `proxy_next_upstream error timeout` 不含 http_5xx | 按需追加 `http_500 http_502 http_503`（注意 5xx 重试可能放大后端压力） |
| upstream 疑似"没探活" | 开源版只有被动检查，失败窗口内请求仍会被派给已 down 的 server（各 worker 计数独立） | 调小 fail_timeout、加共享 zone、用 curl 主动拨测补充 |

## 自测

<details><summary>1. URI `/prefix/preflong/photo.jpg` 会进入上面 8081 server 的哪个 location？逐步说出判定过程。</summary>

第 1 步 `=` 不命中。第 2 步找最长前缀：候选 `/prefix/`（^~）与 `/prefix/preflong/`（普通），最长是 `/prefix/preflong/`，但它不是 `^~`，不能压制正则。第 3 步按顺序查正则：`~ ^/prefix/.*\.jpg$` 命中 → 进入 D。若把 `/prefix/preflong/` 改成 `^~`，则第 2 步直接终结，进入 C——这就是"^~ 必须同时是最长前缀才生效"的反例。
</details>

<details><summary>2. `location /api/ { proxy_pass http://webpool/v1/; }` 收到 `/api/user?id=7`，后端收到什么？</summary>

前缀 `/api/` 被替换为 `/v1/`，后端收到 `/v1/user?id=7`。query string 不参与 location 匹配也不参与替换，会被原样保留并追加；若用变量拼 URI，则需要自己补 `$is_args$args`，否则 query string 会丢。
</details>

<details><summary>3. 为什么有时 upstream 一台挂了，nginx 却没有把请求转给另一台？</summary>

三种常见原因：失败不在 `proxy_next_upstream` 定义的类型里（默认只有 error/timeout，HTTP 5xx 不算）；nginx 已经向客户端发送了部分响应字节（通常与 buffering 配合后发生在响应中途），此时重试会导致内容错乱，nginx 拒绝重试；`proxy_next_upstream_tries/time` 把重试次数或总时长限制死了。
</details>

<details><summary>4. `max_fails=3 fail_timeout=30s` 的确切行为是什么？`max_fails=0` 又是什么意思？</summary>

30 秒滑动窗口内与该 server 的通信失败达到 3 次（失败类型由 proxy_next_upstream 定义），则把它标记为不可用 30 秒，30 秒内不派新请求，期满后恢复候选。`max_fails=0` 关闭统计，即"永不因失败被剔除"，常配合 backup 或纯探活型 server 使用。
</details>

<details><summary>5. `rate=10r/s burst=20` 加与不加 `nodelay`，瞬时 50 个请求的体验分别是什么？</summary>

不加 nodelay：桶内 20 个排队等令牌，每秒放行 10 个，客户端感受是请求成功但变慢（最久等约 2 秒），多余 30 个被拒；加 nodelay：20 个额度立即放行，多余 30 个立即被拒，客户端感受是"前面一批秒回、后面一批直接 429"。对外 API 通常用 nodelay 保护后端，对内排队削峰可以不加。
</details>

<details><summary>6. TLS 终止后，后端如何重建"客户端真实视角"？少传 X-Forwarded-For 或 X-Forwarded-Proto 分别造成什么现象？</summary>

后端信任 nginx 加的头：X-Forwarded-For（逐跳追加的 IP 链）、X-Real-IP（最近一跳的客户端 IP）、X-Forwarded-Proto（原始协议）。少 XFF：后端日志、风控、限流看到的都是 nginx IP，按 IP 的封禁会误杀全量。少 X-Forwarded-Proto：框架生成的绝对跳转、cookie 的 Secure 属性、OAuth 回调 URL 会退化成 http，浏览器报混合内容或重定向循环。
</details>

## 延伸阅读

- location 匹配官方说明：https://nginx.org/en/docs/http/ngx_http_core_module.html#location
- upstream 模块（策略与 server 参数）：https://nginx.org/en/docs/http/ngx_http_upstream_module.html
- proxy 模块（proxy_pass/proxy_buffering/proxy_next_upstream）：https://nginx.org/en/docs/http/ngx_http_proxy_module.html
- limit_req / limit_conn：https://nginx.org/en/docs/http/ngx_http_limit_req_module.html
- TLS 配置与 ssl_param：https://nginx.org/en/docs/http/ngx_http_ssl_module.html
