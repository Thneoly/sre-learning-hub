# Lab 01 · 解答：反向代理高可用

> 每一步按"做什么 + 为什么 + 验证输出"组织。命令全部在 Ubuntu VM（装有 Docker）上执行。

## 第 1 步：部署栈并确认基线

做什么：按 task.md 部署 `lbnet` 网络、两个 `hashicorp/http-echo` 后端和挂载配置的 `lb-nginx`。

为什么：两个后端 body 分别固定为 `app1`/`app2`，让"请求打到了谁"可以直接从响应体看出来，不需要进容器看日志；nginx 配置用 volume 挂进去，后续 `sed` 改文件 + reload 即可迭代。

```bash
# [Ubuntu VM]
docker ps --format '{{.Names}}\t{{.Status}}' | grep lb-
curl -s http://127.0.0.1:8088/
curl -s -D - -o /dev/null http://127.0.0.1:8088/ | grep -i x-upstream
```

验证输出（每次 curl 的 body 会轮流变化）：

```
lb-app1   Up 10 seconds
lb-app2   Up 9 seconds
lb-nginx  Up 8 seconds
app1
X-Upstream: 172.18.0.2:80
```

## 第 2 步：验证加权轮询

做什么：连续 40 次请求并统计。

```bash
# [Ubuntu VM]
for i in $(seq 40); do curl -s http://127.0.0.1:8088/; done | sort | uniq -c
```

验证输出：

```
     30 app1
     10 app2
```

为什么恰好 30:10：nginx 用的是**平滑加权轮询**（smooth weighted RR），不是"攒够一批再切换"。每选一次后端就按权重更新各家当前权重，所以 3:1 会交错分布（app1,app1,app2,app1...），任意连续 40 次的统计都严格落在 30:10 附近——这正是判分脚本敢把区间卡在 24~36/4~16 的原因。注意统计是**逐 worker 各自轮询**的，两个 worker 的计数合起来比例不变。

## 第 3 步：确认 X-Upstream 头

做什么：`curl -D -` 看响应头。

为什么：`add_header X-Upstream $upstream_addr always;` 写在 server 层，`always` 保证 4xx/5xx 时也输出——排障时恰恰最需要失败请求的 upstream 地址。这里有个第 2 章讲过的继承细节：location 里写了 `proxy_set_header` 不影响 `add_header` 的继承（不同指令族），所以 `/`、`/api/`、`/report/` 都能拿到这个头。

## 第 4 步：故障演练一——挂 lb-app2，观察 failover

```bash
# [Ubuntu VM]
docker stop lb-app2
for i in $(seq 20); do curl -s http://127.0.0.1:8088/; done | sort | uniq -c
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8088/
docker logs lb-nginx 2>&1 | grep '\[error\]' | tail -n 3
```

验证输出：

```
     20 app1        <- 全部落到 app1，客户端全程 200
200
2026/08/22 09:14:03 [error] 31#31: *57 connect() failed (111: Connection refused) while connecting to upstream, ...
```

为什么客户端无感：`proxy_next_upstream` 默认含 `error`，连接 lb-app2 失败后 nginx 立刻把请求重投给 lb-app1；同时 `max_fails=2 fail_timeout=10s` 在 10 秒窗口内累计 2 次失败后把 lb-app2 摘除 10 秒，这段时间新请求直接跳过它，连"试错的一次 RTT"都省了。

## 第 5 步：故障演练二——全灭 502 与恢复

```bash
# [Ubuntu VM] 两台全灭 -> 无处可转（curl 不带 -m 等它出结果，两台各等一次连接超时，十几秒后回 502）
docker stop lb-app1
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8088/
docker logs lb-nginx 2>&1 | grep '\[error\]' | tail -n 2

# 恢复 lb-app2（注意 fail_timeout 惩罚期，最多等 10 秒）
docker start lb-app2
sleep 11
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8088/

# 恢复 lb-app1，再看单后端直连路径
docker start lb-app1
sleep 2
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8088/report/metrics
```

验证输出依次为：

```
502                     <- 两台都挂，nginx 回 502 Bad Gateway
（error.log 出现 no live upstreams 或两条 connection refused）
200                     <- lb-app2 起来 + 惩罚期过后，/ 恢复
502 或 200              <- 见下文 DNS 坑
```

为什么 `/report/` 可能还是 502：`proxy_pass http://lb-app1:80/;` 里的域名在 nginx **启动或 reload 时**解析一次成 IP 并缓存。容器停起一轮后 Docker 网络重新分配的 IP 可能变化，nginx 还在连旧 IP（error.log 是 `connection refused` 或超时）。最小修复是让 nginx 重新解析：

```bash
# [Ubuntu VM]
docker exec lb-nginx nginx -t && docker exec lb-nginx nginx -s reload
sleep 1
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8088/report/metrics   # -> 200
```

这一步就是 K8s 里 "Pod 重建 IP 变化" 的微缩版：长效解法是 `proxy_pass http://$backend;` + `resolver`（运行时按 DNS TTL 重解析），或干脆让 upstream 由控制面动态维护（ingress-nginx 的做法）。

## 第 6 步：修复 location 优先级陷阱

先复现并定位（如果第 1 步时还没注意到）：

```bash
# [Ubuntu VM] 现象：API 路径拿到了静态资源的内容
curl -s http://127.0.0.1:8088/api/v1/data.json
curl -s http://127.0.0.1:8088/assets/app.js
docker logs lb-nginx 2>&1 | grep 'data.json' | tail -n 2
```

```
static-asset
static-asset
172.18.0.1 "GET /api/v1/data.json HTTP/1.1" 200 ua="-" rt=0.000
```

定位推理：`ua="-"`、`rt=0.000`——请求根本没出 nginx，是本地 `return` 掉的；第 2 章 2.1 节的顺序里，普通前缀 `location /api/` 即使是最长前缀，之后**仍要按配置顺序查正则**，`~* \.(js|css|json)$` 命中了 `.json` 结尾，把请求抢走了。

修复：给 `/api/` 加 `^~`，让它作为最长前缀时直接压制正则：

```bash
# [Ubuntu VM] 注意：不要用 sed -i！它会把文件替换成新 inode，而单文件 bind mount 绑的是旧 inode，
# 容器里永远看不到修改（nginx -t 照样通过，但 reload 无效）。要用"重定向覆盖"保住 inode：
sed 's|^        location /api/ {|        location ^~ /api/ {|' /opt/nginx-lab/nginx.conf > /tmp/nginx.conf.new
cat /tmp/nginx.conf.new > /opt/nginx-lab/nginx.conf
docker exec lb-nginx grep -n 'location' /etc/nginx/nginx.conf   # 确认容器里已看到 ^~
docker exec lb-nginx nginx -t && docker exec lb-nginx nginx -s reload
```

如果已经不小心用过 `sed -i`，宿主机路径已指向新文件，只能 `docker restart lb-nginx` 让 mount 按路径重新解析。

双向验证（修复生效 + 静态规则未被误伤）：

```bash
# [Ubuntu VM]
curl -s http://127.0.0.1:8088/api/v1/data.json   # -> app1 或 app2（正则被 ^~ 压制）
curl -s http://127.0.0.1:8088/assets/app.js      # -> static-asset（没有更长的 ^~ 前缀，正则照常命中）
curl -s http://127.0.0.1:8088/api/user           # -> app1/app2，路径改写不受影响
```

`/api/user` 仍能正常代理说明只改了"匹配方式"，`proxy_pass http://webpool/;` 的前缀替换语义分毫未动（第 2 章第 4 节的对照表：带 URI 时 `/api/user` → 后端 `/user`）。

## 第 7 步：终态自查与判分

```bash
# [Ubuntu VM] 确认演练终态：三个容器都在跑
docker ps --format '{{.Names}}\t{{.Status}}' | grep lb-
for p in / /api/user /api/v1/data.json /assets/app.js /report/metrics; do
  printf '%-22s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8088$p)"
done
```

```
/                     200
/api/user             200
/api/v1/data.json     200
/assets/app.js        200
/report/metrics       200
```

运行判分脚本（拷贝到 VM 后先赋可执行权限）：

```bash
# [Ubuntu VM] 假设脚本放在 ~/check.sh
chmod +x ~/check.sh && ~/check.sh
```

通过结果：

```
== Lab 01 reverse-proxy-ha 检查 ==
PASS: 容器 lb-nginx 处于运行状态
PASS: 容器 lb-app1 与 lb-app2 均处于运行状态
PASS: GET / 返回 HTTP 200
PASS: GET / 响应体来自后端(app1/app2)
PASS: 响应头包含 X-Upstream
PASS: X-Upstream 值为实际命中的后端地址(IP:80)
PASS: GET /api/user 返回 200 且来自后端
PASS: 加权轮询分布接近 3:1(40 次请求)
  -> 实测分布: app1=30 app2=10 (共 40 次)
PASS: 陷阱已修复：/api/v1/data.json 由后端响应
PASS: 静态规则仍生效：/assets/app.js 返回 static-asset
PASS: /report/ 指向 app1 且已恢复(200)
PASS: 配置中 /api/ 已使用 ^~ 修饰符
PASS: 配置中保留 weight=3 / weight=1 加权定义

SCORE: 13/13
```

exit code 为 0。实验完成后如需释放资源：

```bash
# [Ubuntu VM]
docker rm -f lb-nginx lb-app1 lb-app2 && docker network rm lbnet
```

## 常见卡点回顾

| 卡点 | 原因 | 处理 |
|---|---|---|
| 40 次统计不是 30:10 | 删过 weight、或还有别的 location 抢走了 `/` 的流量 | 核对 upstream 与 `location /`；确认 http-echo 后端 body 没改 |
| 挂 lb-app2 时偶见一次慢响应 | 第一次失败发生在重投前（试错成本） | 正常现象；`max_fails` 摘除后就不再试错 |
| 恢复后 `/` 仍 502 一小会 | fail_timeout 惩罚期未过（10s） | `sleep 11` 再验，理解这是被动检查的固有延迟 |
| `/report/` 恢复后仍 502 | nginx 缓存了 lb-app1 的旧 IP | `nginx -s reload` 重新解析；生产用 resolver + 变量 |
| 改了 `^~` 但 `data.json` 还是 static-asset | 用了 `sed -i`：文件换了 inode，单文件挂载里的容器看不到修改；或忘了 reload | 改用 `sed ... > 新文件 && cat 新文件 > 原文件`（重定向覆盖保 inode），`docker exec lb-nginx grep -n location /etc/nginx/nginx.conf` 确认容器里已变更，再 `nginx -t` + reload；已中招则 `docker restart lb-nginx` |
