# Lab 01 · 反向代理高可用：加权轮询、故障转移与 location 陷阱

> 难度：★★☆ ｜ 考点：nginx 反代/负载均衡/被动健康检查（K8s Ingress 排障的地基）｜ 前置：建议先读完本模块 01~03 章 ｜ 预计 40 分钟

## 场景

你接手了一套部署在 Ubuntu VM 上的小型服务：nginx 做统一入口，后面挂两台异构后端（`lb-app1` 机器好，扛 3 份流量；`lb-app2` 机器差，扛 1 份）。前任留下了一份"能跑"的 nginx 配置和交接说明：

- 入口 `http://<VM>:8088/`，加权轮询转发到两个后端，要求每个响应带 `X-Upstream` 头标明实际命中的后端；
- `/api/` 前缀的请求要转给后端集群（路径前缀改写为 `/`）；
- `/report/` 是单后端直连路径，只走 `lb-app1`（报表服务没有部署第二份）；
- `~* \.(js|css|json)$` 的静态资源规则是性能优化（前端构建产物含 json 清单），交接文档强调"不许删除"。

交接当天你就发现两件事：第一，业务方说后端偶尔会挂，你需要自己演练一遍"挂掉—502—恢复"的完整链路，弄清 nginx 在中间每个阶段的行为；第二，开发反馈 `/api/v1/data.json` 拿到的不是 API 数据而是 `static-asset` 字符串——但 `/api/` 明明配置了代理。你的任务是让这套东西达到验收标准。

初始配置（原样使用，除"任务 6"的修复外不许删改静态资源规则）：

```bash
# [Ubuntu VM] 目录与网络
docker network create lbnet
docker run -d --name lb-app1 --network lbnet -p 9001:80 hashicorp/http-echo -text=app1 -listen=:80
docker run -d --name lb-app2 --network lbnet -p 9002:80 hashicorp/http-echo -text=app2 -listen=:80
mkdir -p /opt/nginx-lab
```

```bash
# [Ubuntu VM] 前任的配置，写入 /opt/nginx-lab/nginx.conf
cat > /opt/nginx-lab/nginx.conf <<'EOF'
user  nginx;
worker_processes  2;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events { worker_connections 1024; }

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    log_format lab '$remote_addr "$request" $status ua="$upstream_addr" rt=$request_time';
    access_log /var/log/nginx/access.log lab;
    keepalive_timeout 65;

    upstream webpool {
        server lb-app1:80 weight=3 max_fails=2 fail_timeout=10s;
        server lb-app2:80 weight=1 max_fails=2 fail_timeout=10s;
    }

    server {
        listen 80;
        add_header X-Upstream $upstream_addr always;

        location / {
            proxy_pass http://webpool;
            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }

        location /api/ {
            proxy_pass http://webpool/;
            proxy_set_header Host $host;
        }

        location /report/ {
            proxy_pass http://lb-app1:80/;
        }

        location ~* \.(js|css|json)$ {
            default_type text/plain;
            return 200 "static-asset\n";
        }
    }
}
EOF

docker run -d --name lb-nginx --network lbnet -p 8088:80 \
  -v /opt/nginx-lab/nginx.conf:/etc/nginx/nginx.conf:ro nginx:1.27
docker exec lb-nginx nginx -t
```

## 任务清单

1. 部署上面的后端与 nginx，确认 `curl http://127.0.0.1:8088/` 能返回 `app1` 或 `app2`。
2. 连续请求 40 次并统计分布，验证加权轮询确实接近 3:1（记录数字，稍后判分脚本会复核）。
3. 确认所有经 `webpool` 的响应都带 `X-Upstream` 头，且值是实际命中的后端地址（IP:80）。
4. 故障演练一（failover）：`docker stop lb-app2` 后继续打 `/`，观察请求是否全部落在 app1 且客户端无感知；记录 `docker logs lb-nginx 2>&1 | grep '\[error\]'` 里的关键报错（官方镜像的 error.log/access.log 是指向 /dev/stderr、/dev/stdout 的符号链接，日志在 `docker logs` 里，不要对它们 `tail`，会挂住）。
5. 故障演练二（502 与恢复）：`docker stop lb-app1`（此时两台全灭）观察 `/` 返回 502；单独 `docker start lb-app2` 后确认 `/` 恢复 200；再把 `lb-app1` 拉起来，若 `/report/` 仍是 502，想办法让它恢复并记下原因。演练结束后保证两台后端都在运行、`/`、`/api/`、`/report/` 全部 200。
6. 修复 location 优先级陷阱：让 `/api/v1/data.json` 由后端 API 响应（body 为 `app1`/`app2`），同时**保留** `~* \.(js|css)$` 规则使 `/assets/app.js` 仍返回 `static-asset`。只允许改 `/api/` 那一个 location 的匹配方式，改完 `nginx -t` 通过并 reload。
7. 在 VM 上运行本目录 `check.sh`，得到 `SCORE: 13/13`。

## 验收标准

- 容器 `lb-nginx`、`lb-app1`、`lb-app2` 均处于运行状态（演练终态）。
- `GET /` 返回 200 且 body 为 `app1` 或 `app2`；40 次统计中 app1 占 24~36、app2 占 4~16。
- `/` 与 `/api/` 的响应带 `X-Upstream: <IP>:80` 头。
- `GET /api/v1/data.json` 返回 200 且 body 为后端内容（`app1`/`app2`），说明陷阱已修复；配置文件中 `/api/` location 使用了 `^~` 修饰符。
- `GET /assets/app.js` 仍返回 `static-asset`（静态规则未被删除/禁用）。
- `GET /report/metrics` 返回 200（app1 已恢复且 nginx 能连上它）。
- `check.sh` 输出 `SCORE: 13/13` 并以退出码 0 结束。

## 提示（卡住再看）

<details><summary>提示 1：加权分布怎么统计最省事</summary>

```bash
# [Ubuntu VM]
for i in $(seq 40); do curl -s http://127.0.0.1:8088/; done | sort | uniq -c
```

平滑加权轮询下 40 次的期望值是 30:10。若偏差巨大，检查 upstream 里 `weight` 是否写对、是否误删了 `weight=3`。
</details>

<details><summary>提示 2：/api/v1/data.json 为什么会被 static-asset 截走</summary>

复习第 2 章 2.1 节的匹配顺序：`location /api/` 是**普通前缀**，即使它是最长前缀，之后 nginx 仍会按顺序查正则；`~* \.(js|css|json)$` 是正则且 `/api/v1/data.json` 以 `.json` 结尾，于是正则抢走了请求。要让前缀压制正则，需要它成为带 `^~` 修饰的**最长前缀**——对 `/api/` 这个 location 的改动只有加两个字符。改完用 `curl http://127.0.0.1:8088/api/v1/data.json`（应回 `app1`/`app2`）和 `curl http://127.0.0.1:8088/assets/app.js`（应仍回 `static-asset`，证明正则规则还在干活）双向验证。
</details>

<details><summary>提示 3：两台后端都恢复后 /report/ 还是 502</summary>

`proxy_pass http://lb-app1:80/;` 里的域名是**启动/reload 时**一次性解析成 IP 的。容器重启后 Docker 网络分配的 IP 可能变化，nginx 还握着旧 IP。最小修复：恢复后端后执行 `docker exec lb-nginx nginx -s reload` 重新解析。这个坑在生产里的名字叫"K8s Pod 重建后 IP 变化"，解法是变量 + `resolver`，见第 2 章第 4 节第 7 行。
</details>
