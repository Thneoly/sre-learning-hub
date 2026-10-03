---
title_juejin: '一个 502，十种病因：nginx 反代排障分诊树'
title_zhihu: '看见 502 就重启后端，是最贵的条件反射：十种病因一张分诊树'
description: '502语义边界、error_log逐字段读法、keepalive三件套、backlog打满、解析到错误地址、响应头超buffer、504与502分界，一张分诊树收拢十种病因与药方。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686472562230312970"
---

# 一个 502，十种病因：nginx 反代排障分诊树

（构造典型案例，细节已脱敏）周四 14:03，网关 502 告警炸群。值班同学肌肉记忆：重启后端。重启完 502 依旧——进程活着、端口在听、CPU 3%。三方甩锅 40 分钟，真凶是中间 LB 把 upstream keepalive 空闲连接悄悄回收，nginx 还攥着死连接发请求。

而答案第一分钟起就写在 error.log 里。这篇讲透 502 语义边界、十种病因、一张分诊树和 error_log 逐字段读法。总判断先行：**502 是 nginx 的求助信号，不是后端的死亡证明**。

## 一、先划边界：502 是谁在说话

502 由 nginx 生成，触发两类（【从业者判断】，素材实验只覆盖"后端全灭"）：建连就失败——被拒、被重置；或连上了但上游没说完——响应头读一半断、格式不合法。还有个伏笔：生成 502 的不一定是你的 nginx，也可能是链路上其他网关——你这层只是信使（第四节展开）。

最易混的是 504。分界一句话：**502 是"连不上或没说完"，504 是"一直等不来"**（【从业者判断】）。连接被拒是 502，连接超时是 504——errno 差一位，状态码差一类，混着治必开错药。

## 二、十种病因：先对号，再入座

| # | 病因 | error_log 指纹 | 一句话验证 |
| --- | --- | --- | --- |
| 1 | 后端进程挂，端口没人听 | connect() failed (111: refused) | nginx 机 curl 后端 |
| 2 | upstream 全体被摘除 | no live upstreams | 数活着的 server 数 |
| 3 | keepalive 被单方断开 | reset by peer / prematurely closed | 偶发 + 查三件套 |
| 4 | 后端 backlog 打满（多为 504） | timed out while connecting | ss 看 Recv-Q 顶格没 |
| 5 | 解析到错误地址 | 111，但 upstream 字段的 IP 不对 | 比对 DNS 与日志 IP |
| 6 | 响应头超过 buffer | upstream sent too big header | curl 直连后端量响应头 |
| 7 | 上游话没说完就断 | prematurely closed | 对后端日志的时间点 |
| 8 | 失败类型不触发切换 | 单台 502 直透，无切换痕迹 | 核对 proxy_next_upstream |
| 9 | worker 计数各自为政 | 边缘偶发，无稳定指纹 | upstream 加共享 zone |
| 10 | 其实是超时，吐 504 | upstream timed out | 看 while 后面的阶段 |

注：病因 1 实测自素材；2~10 文案与验证法为【从业者判断】。

十种里"后端真挂"只占一种，其余多数后端活得好好的——重启大法时灵时不灵，病根在此。

## 三、一张分诊树：从日志行到病因

```text
502 ──▶ tail error.log，找带 upstream 的 [error] 行
├─ connect() failed (111: Connection refused) → 端口没人听
│    ├─ 后端进程挂（病因 1）
│    └─ IP 拨错：DNS 旧 IP（病因 5）
├─ no live upstreams → 全员被 max_fails 摘除（病因 2）
├─ reset by peer / prematurely closed → 半途被掐
│    ├─ keepalive 池中死连接（病因 3）
│    └─ 后端处理中崩掉（病因 7）
├─ upstream sent too big header → 响应头超 buffer（病因 6）
├─ upstream timed out (110) → 504 而非 502（病因 10）
│    connecting=网络/backlog（病因 4）；reading header=后端慢
└─ error.log 干净 → 查 access.log 的 $upstream_addr
     502/200 交替 = 单点 + 未切换（病因 8/9）
```

入口只有一条：**502 排障第一步永远是读日志，不是重启**。

## 四、error_log 逐字段读法：一行日志一份病历

拆开素材实验里的一行（111 片段实测，时间与 IP 为示例）：

```text
2026/10/03 14:21:07 [error] connect() failed (111: Connection refused)
while connecting to upstream, client: 172.18.0.1, upstream: "http://172.18.0.2:80"
```

字段速查（字段语义为通用 nginx 行为，【从业者判断】；级别恒为 error，配 warn 即全收）：

- `14:21:07`——对齐发布/重启时间轴，偶发/持续一眼可辨
- `connect() failed (111: ...)`——系统调用 + errno，整行最硬的证据
- `while connecting to upstream`——阶段：connecting / sending / reading header，三阶段三族病
- `client:`——发起方 IP：LB 还是真用户，决定往哪边查
- `upstream:`——实际拨号地址，查"解析错地址"的金矿字段

errno 对应（111 实测自素材，余【从业者判断】）：111 refused=没人听→502；110 timed out=网络/backlog→504；104 reset=半途被掐→502。

error.log 干净不等于没病，用 access.log 交叉：配 $upstream_addr，顺手加 $upstream_status（以下判读法为【从业者判断】）。

判读两条：502 且 up 有地址、error.log 干净——502 是上游发的，你是信使，查 upstream 指向的那台；up 在 A/B 跳、status 200/502 交替——单点挂了没切换，直奔 8/9。

## 五、"后端明明活着"的 502：四类急救

### 病因 3：keepalive 三件套，缺一不可

现象：低频偶发 502，压测打不出，后端健康，重启 nginx 消停一阵——连接池被清空重建（【从业者判断】）。

机制：默认转发用 HTTP/1.0 语义、Connection 头带 close 意图，连接用完即关、根本进不了池；或后端/LB 按空闲超时先关，nginx 拿死连接发请求遭 RST。三件套（【从业者判断】）：

```nginx
upstream webpool { server app1:80; keepalive 32; }   # 件一：连接池
server {
    location / {
        proxy_pass http://webpool;
        proxy_http_version 1.1;           # 件二：长连接前提
        proxy_set_header Connection "";   # 件三：清掉 close 意图
    }
}
```

只写 keepalive 不写后两行，是这族的标准病灶。

连带两件事：proxy_set_header 族继承断裂，location 写了 Connection，父级 Host 等头全作废（素材坑表）；中间设备回收更快时，把 upstream 块的 keepalive_timeout（1.15.3+，默认 60s）调到低于对端空闲回收（【从业者判断】）。

### 病因 4：backlog 打满——活着，但接不过来

进程活着、端口在听，但 accept 队列满，新连接被丢，表现为建连超时——报出来多是 504，与 502 同属"后端活着但接不动"。验证（本节均【从业者判断】）：

```bash
ss -lnt | grep -E ':8080|:80 '
# LISTEN 128 128 ...  ← Recv-Q 贴着 Send-Q = 打满
netstat -s | grep -i overflowed   # 累计溢出，只增不减
```

药方在后端：调大 backlog 与 somaxconn，或扩容。队列满是"接不过来"，不是"接不了"。

### 病因 6：响应头超 buffer

职责分工出自素材：proxy_buffer_size 放响应头第一段；而"头超过它、nginx 判上游非法"这一步是【从业者判断】。典型触发：响应头塞了巨型 Cookie、JWT、灰度调试头。

```nginx
location /api/ { proxy_buffer_size 8k; proxy_pass http://webpool; }
# 头专用；proxy_buffers 管 body，两回事
```

### 病因 8/9：该切换没切换

素材判据：默认 proxy_next_upstream 是 error timeout——HTTP 5xx 不算失败，后端连着但吐 502，nginx 不切。不切换的三种原因（素材自测原题）：失败类型不在列表里；已发部分响应字节，重试会拼接出错；tries/time 限制死。

再补一刀：各 worker 的失败计数各自独立，判定还会抖——这正是下面 zone 那行的由来。

```nginx
upstream webpool {
    zone webpool 64k;    # 各 worker 共享失败计数
    server app1:80 max_fails=2 fail_timeout=10s;
    server app2:80 max_fails=2 fail_timeout=10s;
}
```

## 六、5 分钟复现一次 502

病因 1、2 的指纹跑一遍就长进肌肉记忆（素材第七步浓缩）：

```bash
# [Ubuntu VM]
docker network create lbnet
docker run -d --name app1 --network lbnet hashicorp/http-echo -text=app1 -listen=:80
docker run -d --name app2 --network lbnet hashicorp/http-echo -text=app2 -listen=:80
cat > /tmp/ngxc.conf <<'EOF'
events { worker_connections 1024; }
http {
    error_log /var/log/nginx/error.log warn;
    upstream webpool { server app1:80 max_fails=2 fail_timeout=10s;
                       server app2:80 max_fails=2 fail_timeout=10s; }
    server { listen 80; location / { proxy_pass http://webpool; } }
}
EOF
docker run -d --name ngx --network lbnet -p 8088:80 \
  -v /tmp/ngxc.conf:/etc/nginx/nginx.conf:ro nginx:1.27
docker exec ngx nginx -t   # 先 -t 再 reload
```

三幕：

```bash
docker stop app2
for i in $(seq 6); do curl -s http://127.0.0.1:8088/; done | sort | uniq -c
# 6 app1  ← 挂一台：失败转移，无感知
docker exec ngx tail -n 3 /var/log/nginx/error.log
# connect() failed (111: Connection refused) while connecting ...

docker stop app1
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8088/
# 502 ← 两台全灭，无处可转

docker start app2 app1 && sleep 11
# fail_timeout(10s) 后自动重新纳入（此前 max_fails 已摘除两台）
docker rm -f ngx app1 app2 && docker network rm lbnet
```

## 七、预答两个反方

**"502 嘛，重启后端总能消停一阵。"** 十种里多数不是重启后端能治的，keepalive 那类连后端都不用碰；更糟的是重启抹掉现场——崩溃瞬间的内存态与连接快照一重启就没了，事后无从取证。

**"加 http_502 自动换台，不就没有 502 了？"** 素材原文提醒：给 proxy_next_upstream 追加 http_5xx，可能放大后端压力。502 往往意味着后端正在垂死挣扎，无差别重试等于给重症病人加剂量。

重试只留给连接类失败（error timeout）——这正是默认值，不必再扩。

## 八、教训与 30 秒自检

| 要点 | 一句话 |
| --- | --- |
| 语义 | 502 是 nginx 拨不通或对方没说完，不等于后端挂 |
| 顺序 | 先 tail error_log 再动手，别用重启代替读日志 |
| 分界 | 被拒/被重置=502，等超时=504，errno 一位之差 |
| 信使 | error.log 干净时 502 可能是上游发的，查 $upstream_addr |
| keepalive | 三件套缺一不可，池中死连接是头号嫌疑人 |

现在做三件事：核对生产三件套——最常见的病灶就是只写 keepalive、漏了后两行；access_log 配 $upstream_addr、error_log 不高于 warn；测试环境跑第六节，亲眼看 111 → 502 → 自愈。

## 写在最后

十种病因背后是同一条纪律：**病历 nginx 已替你写好**——errno、阶段、真实拨号地址，全在 error.log 里。高手差距不在知道更多命令，而在动手前肯先读一行日志——先读后动，40 分钟的事 5 分钟收工。

分诊树、keepalive 三件套与实验脚本整理自我维护的开源学习库——GitHub 搜 sre-learning-hub，nginx 反代章节经真机验证。你遇过最诡异的 502 是哪一种？评论区对暗号。
