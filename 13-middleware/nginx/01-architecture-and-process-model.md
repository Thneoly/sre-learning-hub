# 01 · Nginx 架构与进程模型

> 模块：07-中间件/nginx ｜ 建议时长：2 小时 ｜ 关联认证：—（CKA/CKS 无直接考点，但它是 ingress-nginx、各类 API 网关排障的地基）

## 学习目标

- 能解释 master-worker 多进程模型相对多线程模型的取舍（隔离性、锁、CPU 亲和）
- 能描述 epoll 事件驱动 + 非阻塞 IO 如何让一个 worker 服务上万连接
- 能画出一条 HTTP 请求在 nginx 内部经过的 phase 流水线，并说出每个 phase 的典型指令
- 能操作进程层运维动作：调整 worker 数量、reload、reopen 日志、观察 worker 崩溃自愈
- 能区分静态模块与动态模块（.so），并正确用 `load_module` 加载

## 1. 全景：一台反向代理服务器里发生了什么

先建立整体图景，再逐层拆。nginx 启动后，机器上是一个 master 进程加 N 个 worker 进程（N 通常等于 CPU 核数），所有真正干活的是 worker：

```
                    ┌────────────────────────────────────────────┐
   客户端 ──HTTP──▶ │  worker-0   worker-1   worker-2   worker-3 │ ──▶ upstream(后端)
                    │  (nginx)    (nginx)    (nginx)    (nginx)  │
                    └───────▲──────────▲─────────▲─────────▲────┘
                            │  fork/监控/回收      │
                    ┌───────┴──────────┴─────────┴─────────┴────┐
                    │            master（root，读配置、绑端口）   │
                    └────────────────────────────────────────────┘
                     共享内存：upstream zone / limit_req zone / cache 元数据
```

三个关键分工：

- **master**：以 root 运行（为了绑定 80/443 这类特权端口），负责解析 nginx.conf、创建 listen socket、fork 出 worker、接收信号（reload、日志重开、二进制升级），并把 worker 降权为普通用户（默认 `nginx` 或 `www-data`）。
- **worker**：以普通用户运行，各自持有一个事件循环（event loop），独立 accept 连接、处理请求、转发到 upstream。worker 之间不共享请求状态，只通过 master 预置的共享内存区（shared memory zone）交换少量数据。
- **cache manager / cache loader**（可选）：仅在开启 `proxy_cache` 时由 master fork 出来，负责缓存目录的清理与预热，平时不参与请求处理。

## 2. master-worker：为什么是多进程而不是多线程

### 2.1 设计动机

nginx 诞生的核心目标是用一台机器扛住几万条并发连接（C10K 问题）。它选择"每个 CPU 核一个进程、每个进程一个事件循环"，而不是"一个进程、几百个线程"，理由集中在四点：

| 维度 | 多进程（master-worker） | 多线程（如传统 Apache worker MPM） |
|---|---|---|
| 故障隔离 | 一个 worker 段错误，master 秒级重新 fork 一个，其余 worker 不受影响，服务"掉一格"但不停 | 一个线程崩溃通常带崩整个进程，所有连接一起死 |
| 锁竞争 | worker 之间无共享可变状态，事件循环里几乎不需要锁 | 连接表、计数器等需加锁，核越多锁越热 |
| 模块生态 | 第三方 C 模块不需要线程安全，开发门槛低 | 所有模块必须线程安全，生态做不起来 |
| CPU 亲和 | `worker_processes` + `worker_cpu_affinity` 把每个 worker 钉在一颗核上，cache 命中率高 | 线程在核间漂移，需要额外调优 |

代价也要认账：进程比线程更吃内存（每个 worker 一份独立地址空间，靠 fork 时的 copy-on-write 缓解）；worker 之间要共享计数器、限流状态，必须显式开共享内存 zone（`limit_req_zone`、`upstream zone`）。

### 2.2 信号速查表

运维 nginx 本质上是给 master 发信号：

| 信号 | 等价命令 | 行为 |
|---|---|---|
| TERM / INT | `nginx -s stop` | 快速关闭：worker 立即断开所有连接退出 |
| QUIT | `nginx -s quit` | 优雅关闭：worker 处理完当前请求再退出 |
| HUP | `nginx -s reload` | 重载配置（见下） |
| USR1 | `nginx -s reopen` | 重新打开日志文件（日志切割后必须做） |
| USR2 + WINCH | — | 二进制热升级：USR2 启动新 master，WINCH 优雅停掉旧 master 的 worker |

`reload` 的完整时序，这是面试和排障高频点：

```
master 收到 HUP
  ├─ 1. 重新解析 nginx.conf ──语法/语义错误则报错，旧 worker 继续跑（这就是 reload 不中断服务的底气）
  ├─ 2. 重新打开日志文件、按需新建 listen socket
  ├─ 3. fork 一批新 worker（新配置）
  └─ 4. 向所有旧 worker 发 QUIT ──旧 worker 处理完手头请求才退出
```

推论：**长连接（WebSocket、gRPC、SSE）会拖住旧 worker 不退出**。`ps` 里看到"两代 worker 并存"是正常现象，不是 bug；确认方式见实战演练第 5 步。

## 3. epoll 事件驱动与非阻塞 IO

### 3.1 事件循环

每个 worker 的主循环可以简化为：

```
while (true) {
    events = epoll_wait(epfd, timeout);   // 有事的 fd 才返回，无事则睡眠
    for (ev in events) {
        ev.handler(ev);                   // 回调：可读→读，可写→写，定时器到点→处理超时
    }
    处理超时队列 / post 事件;
}
```

连接的 socket 全部设为**非阻塞**。读不满/写不出时不会卡在 `read()`/`write()` 上，而是注册兴趣事件、切换去服务别的连接，事件就绪后再回来继续。于是"1 个线程 1 条连接阻塞式"变成了"1 个进程几万条连接事件式"：

| 模型 | 等待就绪的代价 | 适合 |
|---|---|---|
| BIO（一连接一进程/线程） | 内存与上下文切换随连接数线性涨 | 几百连接 |
| select/poll | 每次都要把全部 fd 拷进内核再线性扫描，O(n) | 几千连接 |
| epoll（nginx/Redis 同路线） | 回调注册 + 只返回就绪 fd，O(活跃数) | 几十万连接 |

两个进阶细节：

- nginx 使用 epoll 的**边缘触发（ET）**模式：事件只提醒一次，handler 必须循环读/写到 `EAGAIN` 为止，否则剩余数据可能永远无人处理。
- 多个 worker 监听同一端口会产生"惊群"问题。现代内核用 `EPOLLEXCLUSIVE` 缓解；nginx 也可在每个 `listen` 上加 `reuseport` 参数，让每个 worker 独立绑定一个 socket（内核侧直接分流，避免锁竞争，适合高连接速率场景，具体行为以官方文档为准）。

### 3.2 一条请求占了几个"连接额度"

worker 做反向代理时，一个客户端请求会占用 worker 连接表里的**两个槽位**：客户端侧一条 + upstream 侧一条。所以容量估算时要按 `worker_connections / 2` 算并发代理请求数，这个坑在第 3 章展开。

## 4. 一条请求的流水线：phase 与模块链

nginx 把一次 HTTP 处理切成 11 个 phase，每个 HTTP 模块可以把自己的 handler 挂到某些 phase 上。请求按序流过，像流水线上的工位：

```
客户端请求
  │
  ▼
POST_READ ──▶ SERVER_REWRITE ──▶ FIND_CONFIG ──▶ REWRITE ──▶ POST_REWRITE
(realip)      (server 级 rewrite)  (选 location)  (location 级 rewrite)   │
                                                                      │ internal redirect
ACCESS ◀── PREACCESS ◀───────────────────────────────────────────────────┘
(auth_basic/   (limit_req/
 deny/allow     limit_conn)
 auth_request)
  │
  ▼
PRECONTENT ──▶ CONTENT ──▶ LOG
(try_files/    (proxy_pass /   (access_log，
 mirror)       static / echo…)  必然执行)
```

| Phase | 典型模块/指令 | 运维要点 |
|---|---|---|
| POST_READ | `realip`（还原真实客户端 IP） | 挂在最前，保证后续日志/限流看到的是真 IP |
| SERVER_REWRITE | server 级 `set`/`if`/`return` | 在选 location 之前执行 |
| FIND_CONFIG | 核心模块选 location | 无业务指令，纯内部 |
| REWRITE | location 级 `rewrite`/`set` | `rewrite ... last` 会触发 internal redirect，回到 FIND_CONFIG 重选 location，最多循环 10 次，超了报 500 |
| PREACCESS | `limit_req`、`limit_conn` | 限流在鉴权前，先把明显超量的流量挡掉 |
| ACCESS | `allow`/`deny`、`auth_basic`、`auth_request` | `satisfy all`（默认）要求全部通过 |
| PRECONTENT | `try_files`、`mirror` | mirror 在这里复制流量做灰度/审计 |
| CONTENT | `proxy_pass`/`fastcgi_pass`/静态文件 | **每个 location 只有一个 content handler 胜出**，`proxy_pass` 和静态文件不会叠加执行 |
| LOG | `access_log` | 即使上游返回 4xx/5xx 也会记录 |

排障视角的价值：看到某个行为就能反推它发生在哪个 phase。比如"限流返回 503 但 access_log 里有记录"（LOG phase 必然执行）、"`rewrite ... last` 改写了 location 导致 limit_req 没生效"（重选 location 后重新过 phase）。

## 5. 连接与内存池

### 5.1 连接是预分配的

worker 启动时按 `worker_connections` 一次性预分配 `ngx_connection_t` 数组和配套的 read/write event 结构（每 slot 合计几百字节，几万连接也就几十 MB 用户态内存，真正的大头是内核侧 socket 缓冲区）。fd 通过数组直接映射到 connection 槽位，没有运行期 malloc。连接耗尽时 error.log 出现 `worker_connections are not enough`，这是容量问题的一级警报。

### 5.2 每请求一个内存池

处理请求时要分配几十上百个小对象（header 解析结果、变量、upstream 结构……）。nginx 的做法：

```
请求开始
  └─ 创建 ngx_pool_t（按页申请小块内存，palloc 从池里指针递增式切分）
       ├─ 小对象：池内分配，不单独 free
       ├─ 大对象（> 池单块上限）：单独 malloc，挂到池的大块链表
       └─ 请求结束：整池销毁，一次 munmap/free 全部归还
```

收益：O(1) 的分配、零碎片、绝无"忘 free"导致的泄漏（请求一结束池整体回收）。代价：内存生命周期只能以请求为粒度，想跨请求复用必须用共享内存 zone 或缓存显式管理。

## 6. 模块体系与动态模块

nginx 的一切功能都是模块。按挂载位置分五类：

| 类型 | 职责 | 例子 |
|---|---|---|
| core | 进程/事件框架，main 上下文指令 | `events`、`http` 块本身 |
| event | 事件驱动后端（编译时选一个） | `ngx_epoll_module` |
| HTTP | 挂到各 phase 的业务模块 | `ngx_http_proxy_module`、`ngx_http_rewrite_module` |
| mail | 四层邮件代理 | smtp/pop3/imap |
| stream | 四层 TCP/UDP 代理 | `ngx_stream_proxy_module`（MySQL/Redis 前置代理就用它） |

发行版 nginx 把常用模块**静态编译**进二进制；其余可以编译成 `.so` 动态模块，用 `load_module` 加载：

```bash
# [任意节点] 查看当前二进制里静态编译了哪些模块、编译参数
nginx -V 2>&1
```

```nginx
# nginx.conf 最顶部（main 上下文，必须位于 events/http 之前）
load_module modules/ngx_stream_module.so;

events { }
http { ... }
```

规则：`.so` 必须与 nginx 主程序**同一版本、同一编译参数**编译（`nginx -V` 的 `--add-dynamic-module=` 产物），版本不匹配加载直接失败；`load_module` 只能出现在 main 上下文最前面。

## 实战演练

环境：一台装有 Docker 的 Ubuntu 22.04/24.04 VM。用官方镜像观察进程模型，全程不改宿主机。

```bash
# [Ubuntu VM] 启动官方镜像，宿主机 8080 -> 容器 80
docker run -d --name ngx1 -p 8080:80 nginx:1.27
```

**第 1 步：看清进程树。**

```bash
# [Ubuntu VM] master 是 root，worker 是 nginx 用户
docker top ngx1 -o pid,ppid,user,cmd
```

预期输出形态（worker 数 = 容器看到的 CPU 核数，`worker_processes auto;` 是官方镜像默认值）：

```
PID    PPID   USER    CMD
3100   2070   root    nginx: master process nginx -g daemon off;
3101   3100   nginx   nginx: worker process
3102   3100   nginx   nginx: worker process
```

```bash
# [Ubuntu VM] 容器里看到的核数
docker exec ngx1 nproc
```

注意：容器内 `nproc` 显示的是**宿主机核数**（默认没有 CPU 限制），在 64 栁宿主机上会 fork 出 64 个 worker。生产容器里要么显式 `worker_processes 2;`，要么用 cgroup 限核。

**第 2 步：改 worker 数并 reload。**

```bash
# [Ubuntu VM] auto 改成 2，语法检查通过后 reload
docker exec ngx1 sh -c \
  "sed -i 's/^worker_processes  auto;/worker_processes  2;/' /etc/nginx/nginx.conf && nginx -t && nginx -s reload"
docker top ngx1 -o pid,ppid,user,cmd
```

预期：worker 只剩 2 个，且 PID 是新的——reload = 换一代 worker。

**第 3 步：worker 崩溃自愈。**

```bash
# [Ubuntu VM] 列出容器内所有 nginx 进程（PID 1 是 master，其余是 worker）
docker exec ngx1 sh -c 'for d in /proc/[0-9]*; do printf "%s %s\n" "${d#/proc/}" "$(cat "$d/comm")"; done'
# [Ubuntu VM] 杀掉一个 worker（把 38 换成上一步看到的某个 worker PID）
docker exec ngx1 sh -c 'kill -9 38'
# [Ubuntu VM] 再看一眼：新 worker 已顶上，并确认服务未中断
docker exec ngx1 sh -c 'for d in /proc/[0-9]*; do printf "%s %s\n" "${d#/proc/}" "$(cat "$d/comm")"; done'
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/
# [Ubuntu VM] error.log 里有退出与重启记录
docker exec ngx1 tail -n 4 /var/log/nginx/error.log
```

预期 error.log 形如 `worker process 38 exited on signal 9` 随后 `start worker process 41`。这就是多进程隔离的价值：单个 worker 挂了，master 立即补位。

**第 4 步：reopen 日志（切割日志后必做）。**

```bash
# [Ubuntu VM] 模拟切割：改名后 inode 未变，必须 reopen 才会写新文件
docker exec ngx1 sh -c 'mv /var/log/nginx/access.log /var/log/nginx/access.log.1 && nginx -s reopen'
curl -s -o /dev/null http://127.0.0.1:8080/
docker exec ngx1 ls -l /var/log/nginx/
```

预期：新的 `access.log` 重新出现且持续增长。

**第 5 步：观察"两代 worker 并存"。**

```bash
# [Ubuntu VM] 先建一条长连接占住一个旧 worker（30 秒超时）
curl -s --max-time 30 -H 'Connection: keep-alive' http://127.0.0.1:8080/ >/dev/null &
sleep 1
docker exec ngx1 sh -c "sed -i 's/^worker_processes  2;/worker_processes  1;/' /etc/nginx/nginx.conf && nginx -s reload"
sleep 2
docker top ngx1 -o pid,ppid,user,cmd
```

预期：短时间内能看到 2 个 worker（旧配置的等连接结束 + 新配置的）；长连接结束后旧 worker 消失。排障时见到双代 worker 不要误判为"reload 失败"。

**第 6 步（选做）：开 stub_status 预览连接数。**

```bash
# [Ubuntu VM] 加一个 server 片段暴露 /stub_status
docker exec ngx1 sh -c 'printf "server {\n listen 80;\n location = /stub_status { stub_status; }\n}\n" > /etc/nginx/conf.d/stub.conf && nginx -t && nginx -s reload'
curl -s http://127.0.0.1:8080/stub_status
```

输出六项指标（Active connections / accepts / handled / requests / Reading / Writing / Waiting）的含义与监控接入在第 3 章详解。用完清理：

```bash
# [Ubuntu VM]
docker rm -f ngx1
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| error.log 出现 `24: Too many open files` | 进程 fd 上限低于并发连接数 | `worker_rlimit_nofile` 调大并同步 systemd `LimitNOFILE`（见第 3 章） |
| error.log 出现 `worker_connections are not enough` | worker 连接槽耗尽（代理场景每个请求占 2 个槽） | 调大 `worker_connections`，同时核对 ulimit |
| reload 后"配置没生效" | 旧 worker 在等长连接结束；或新连接命中了旧 worker | 新建连接验证；`docker top`/`ps` 确认旧 worker 是否滞留 |
| 容器里 worker 数等于宿主机核数 | `auto` 读到宿主 CPU | 显式 `worker_processes N` 或给容器限核 |
| `load_module` 报 `is not allowed here` | 指令写进了 events/http 块内 | 必须放 nginx.conf 最顶部的 main 上下文 |
| .so 加载失败 `module ... version mismatch` | 模块与主程序版本/编译参数不一致 | 用 `nginx -V` 的 configure 参数重新编译模块 |
| 日志切割后磁盘没释放、新日志没写入 | 进程仍握着旧 fd | 切割后立刻 `nginx -s reopen`（USR1） |

## 自测

<details><summary>1. 为什么 nginx 选多进程而不是多线程？如果一个 worker 因第三方模块 bug 段错误，整个服务会怎样？</summary>

多进程带来故障隔离、无锁的事件循环、模块无需线程安全、易做 CPU 亲和；代价是内存占用更高、跨 worker 状态要显式放共享内存。worker 段错误退出后，master 检测到子进程死亡会立即 fork 新 worker 接管后续连接，其余 worker 与存量连接完全不受影响，服务表现为"容量掉一格"而不是宕机。多线程模型下线程崩溃通常使整个进程终止，所有连接同死。
</details>

<details><summary>2. epoll 边缘触发（ET）模式下，读 socket 为什么要循环读到 EAGAIN？不循环会怎样？</summary>

ET 模式只在状态发生变化时通知一次（如从无数据变为有数据），之后同一批数据不会再触发事件。如果只读一次就返回，缓冲区剩余数据将永远没有下一次通知，连接会"卡死"到超时。所以 nginx 的读回调固定循环 read 直到返回 EAGAIN（非阻塞下表示暂时无数据），写同理循环到 EAGAIN 再注册可写事件。
</details>

<details><summary>3. FIND_CONFIG_PHASE 为什么排在 SERVER_REWRITE 之后？`rewrite ... last` 触发内部重定向时 phase 如何回退？</summary>

server 级 rewrite 需要先有机会改写 URI，然后 FIND_CONFIG 才能基于"改写后的 URI"选择 location。location 内的 `rewrite ... last` 会触发 internal redirect：请求带着新 URI 回到 FIND_CONFIG 重新选 location，再次流过后续 phase。该循环上限为 10 次，防止两条 rewrite 规则互相踢皮球，超限返回 500。
</details>

<details><summary>4. 每请求内存池如何避免内存泄漏和碎片？代价是什么？</summary>

池内分配是指针递增切分，请求结束时整池销毁，不存在"忘记 free"的路径，因此无泄漏；小对象都来自按页对齐的池块，也不会产生全局堆碎片。代价是生命周期只能绑定请求——请求结束前申请的内存即使很早不用也会占用到最后；跨请求复用必须改用共享内存 zone 或 cache 这类显式机制。
</details>

<details><summary>5. graceful reload（HUP）时，一条已建立的 WebSocket 连接会发生什么？生产上怎么处理？</summary>

旧 worker 收到 QUIT 后会等所有存量请求/连接结束才退出，WebSocket 是长连接，可能"永远等不到结束"，于是旧 worker 长期滞留（占用旧配置与内存）。处理方式：给 reload 设置配套的连接 draining 策略，如 `worker_shutdown_timeout`（到时强制断开滞留连接），或在架构层让客户端具备断线重连、把会话状态外置，避免依赖单条连接的生命周期。
</details>

<details><summary>6. stub_status 里 Waiting 通常远大于 Writing，这说明什么？什么时候该警惕？</summary>

Waiting = 空闲等待中的 keepalive 连接数：请求已回完，客户端连接留着待复用。绝大多数时间连接处于两次请求之间的空闲态，所以 Waiting 大是常态，说明 keepalive 在正常复用。需要警惕的是 Active connections 持续逼近 `worker_processes × worker_connections`、或 Reading/Writing 持续走高不回落——那是容量或后端慢的信号（第 3 章展开）。
</details>

## 延伸阅读

- nginx 官方 Beginner's Guide：https://nginx.org/en/docs/beginners_guide.html
- HTTP 请求处理（server/location 选择官方说明）：https://nginx.org/en/docs/http/request_processing.html
- `nginx -V`、信号与 reload 行为：https://nginx.org/en/docs/control.html
- 动态模块加载 `load_module`：https://nginx.org/en/docs/ngx_core_module.html#load_module
- epoll(7) 手册（Linux 事件通知机制）：https://man7.org/linux/man-pages/man7/epoll.7.html
