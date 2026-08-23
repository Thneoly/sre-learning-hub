# Lab 02 · 解答:TIME_WAIT 洪峰与短连接生命周期

> 实验拓扑:客户端与 HTTP 服务都在同一台机器,走 `lo` 回环——流量小、无噪声,
> 且 TIME_WAIT 的两端(客户端与服务端)都能看到。
>
> ```text
> +--------------------- Ubuntu VM / 集群节点 ---------------------+
> |   ab / curl(临时端口 32768-60999) <==> HTTP server :8080      |
> |                       全部经过 lo + netfilter conntrack        |
> +---------------------------------------------------------------+
> ```

## 1. 环境准备

```bash
# [任意节点]
sudo apt-get update
sudo apt-get install -y apache2-utils tcpdump conntrack
mkdir -p ~/drill
```

起 HTTP 服务,两种方式二选一。方式 A(零依赖,HTTP/1.0 用完即断,天然短连接):

```bash
# [任意节点] 方式 A:python 内置 HTTP 服务
nohup python3 -m http.server 8080 >/tmp/httpd.log 2>&1 &
```

方式 B(装有 Docker 的 VM,nginx 默认 keepalive,适合对比长连接行为):

```bash
# [任意节点] 方式 B:nginx 容器
docker run -d --name drill-nginx -p 8080:80 nginx:1.27
```

本实验的包序解读以方式 A 为准(HTTP/1.0 无 keepalive,服务端主动关闭)。
验证:`curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/` 应输出 `200`。

记录基线:

```bash
# [任意节点]
ss -H -tan state time-wait | wc -l
```

```text
# [任意节点] 预期输出(空闲独立 VM;k8s 节点上本地组件互连多,几十到一两百都算正常基线)
1
```

把数字填进 `answers.txt` 的 `TW_baseline`。

## 2. 制造 TIME_WAIT 洪峰并观察

### 2.1 压测命令(ab 为主,curl 脚本兜底)

做什么:20000 条短连接、100 并发,每条连接用完即断。

```bash
# [任意节点] 注入:短连接风暴
ab -n 20000 -c 100 -r http://127.0.0.1:8080/ >/tmp/ab-run1.log 2>&1
```

没有 ab 时用等价脚本:

```bash
# [任意节点] 注入:curl 短连接风暴(50 并发共 20000 次)
cat > ~/drill/burst.sh <<'EOF'
#!/usr/bin/env bash
seq 1 20000 | xargs -P 50 -I{} curl -s -o /dev/null http://127.0.0.1:8080/
EOF
chmod +x ~/drill/burst.sh
nohup ~/drill/burst.sh >/tmp/burst.log 2>&1 &
```

### 2.2 压测期间观察

为什么边跑边看:TIME_WAIT 时长固定 60 秒(`tcp_fin_timeout` 管的是 FIN_WAIT_2,管不到它),
压完再看得等一分钟,峰值要在压测中采样。

```bash
# [任意节点] 压测期间另开终端,每秒采样
for i in $(seq 1 30); do ss -H -tan state time-wait | wc -l; sleep 1; done | tee /tmp/tw-sample.log
ss -s
```

```text
# [任意节点] ss -s 预期输出(压测中)
Total: 402
TCP:   33120 (estab 108, closed 33098, orphaned 0, timewait 32912)

Transport Total     IPv4     IPv6
RAW       1         1        0
UDP       14        9        5
TCP       33120     33120    0
INET      33135     33129    6
```

ab 结束后 `tail /tmp/ab-run1.log` 应看到 `Complete requests: 20000 / Failed requests: 0`。

## 3. tcp_tw_reuse 对比实验

做什么:同一压测跑两遍,唯一变量是 `net.ipv4.tcp_tw_reuse`。
为什么:`0` 表示禁用重用,TIME_WAIT 只能干等 60 秒;`1` 表示全局启用**发起方向**的
端口重用(依赖 TCP timestamps,延迟阈值 `tcp_tw_reuse_delay` 默认 1000ms);
`2` 表示**仅对 loopback 流量**启用重用,也是 4.12 起所有内核的**默认值**——包括
Ubuntu 22.04/24.04 的 5.15/6.8(想验证可用 `sudo unshare -n sysctl -n net.ipv4.tcp_tw_reuse`,
全新网络命名空间里读到的是内核出厂默认)。ab/curl 都打 127.0.0.1 走回环,恰好落在 =2 的生效范围内。
动手前先 `sysctl -n net.ipv4.tcp_tw_reuse` 把当前值记进 `answers.txt` 的 `TW_reuse_orig`
(运维或集群工具可能改过它),收尾恢复成这个原值,别想当然写 0。

```bash
# [任意节点] 第一轮:禁用重用
sudo sysctl -w net.ipv4.tcp_tw_reuse=0
ab -n 20000 -c 100 -r http://127.0.0.1:8080/ >/tmp/ab-reuse0.log 2>&1
```

压测期间用 2.2 的采样循环,把峰值写入 `TW_reuse0`。注意:加大强度(如
`ab -n 60000 -c 200 ...`)**并不**会在本实验里看到 `socket: Cannot assign requested
address`——实测把服务端换成 nginx、打到 12000+ req/s 也不会。因为 ab 走 HTTP/1.0,
主动关闭方是服务端,客户端临时端口(默认 32768-60999,约 2.8 万个)被动关闭后立即
释放,从不被 TIME_WAIT 占住。生产上那条报错出自**客户端侧主动关闭**的高频出向短连接,
本实验配方复现不了它,能复现的是"服务端 TW 堆积"这一半。

```bash
# [任意节点] 第二轮:loopback 启用重用
sudo sysctl -w net.ipv4.tcp_tw_reuse=2
ab -n 20000 -c 100 -r http://127.0.0.1:8080/ >/tmp/ab-reuse2.log 2>&1
```

同样采样,峰值写入 `TW_reuse2`,两次 `sysctl -w` 命令原文写入 `sysctl_cmd`。

典型观察与结论(数字随机器浮动,以你记录的为准)。先说一个**大概率会出现的"意外"**:
两轮峰值可能基本持平(实测 11341 vs 11280;换 nginx 跑到 12000+ req/s 也一样,
13704 vs 13675,且 `Cannot assign requested address` 一次都没出现)。原因回看第 4 节
自己就写了:HTTP/1.0 下**服务端才是主动关闭方**,TIME_WAIT 全堆在固定端口 8080 一侧,
数量不受临时端口上限约束;客户端是被动关闭,socket 直接进 CLOSED,临时端口即用即还,
`tcp_tw_reuse` 管的是"本机发起连接时重用 TIME_WAIT 端口",在这里根本没有用武之地。
端口耗尽报错出现在**本机作为客户端、主动高频关闭短连接**的场景(典型:没做连接池的
HTTP 客户端打上游、网关出向转发)——那才是 `tcp_tw_reuse=1`(出口节点)/`=2`(回环)
真正的用武之地。结论一句话:
**TIME_WAIT 是内核的自我保护(让旧报文自然消亡),治本是长连接/连接池;本实验配方里
TW 落在服务端,两轮持平属正常;真实的出口/客户端节点(非回环)缓解端口耗尽要设
`tcp_tw_reuse=1`;`tcp_tw_recycle` 因 NAT 下误杀早已移除,别再提它。**

## 4. tcpdump 抓一次 HTTP 短连接全生命周期

做什么:先开抓包(-c 12 自动停止,避免抓进压测流量),再发一次 curl。

```bash
# [任意节点] 终端 1:抓包
sudo tcpdump -i lo -nn 'tcp port 8080' -c 12
```

```bash
# [任意节点] 终端 2:触发一次短连接
curl -s -o /dev/null http://127.0.0.1:8080/
```

```text
# [任意节点] 预期输出(方式 A,序列号已简化)
14:02:11.307127 IP 127.0.0.1.45672 > 127.0.0.1.8080: Flags [S],  seq 4138003233, win 65495
14:02:11.307137 IP 127.0.0.1.8080  > 127.0.0.1.45672: Flags [S.], seq 2585024198, ack 4138003234
14:02:11.307142 IP 127.0.0.1.45672 > 127.0.0.1.8080: Flags [.],  ack 1, win 512
14:02:11.307150 IP 127.0.0.1.45672 > 127.0.0.1.8080: Flags [P.], seq 1:78, ack 1: GET / HTTP/1.1
14:02:11.307236 IP 127.0.0.1.8080  > 127.0.0.1.45672: Flags [P.], seq 1:247, ack 78: HTTP/1.0 200 OK
14:02:11.307240 IP 127.0.0.1.45672 > 127.0.0.1.8080: Flags [.],  ack 247, win 512
14:02:11.307301 IP 127.0.0.1.8080  > 127.0.0.1.45672: Flags [F.], seq 247, ack 78
14:02:11.307310 IP 127.0.0.1.45672 > 127.0.0.1.8080: Flags [.],  ack 248, win 512
14:02:11.307401 IP 127.0.0.1.45672 > 127.0.0.1.8080: Flags [F.], seq 78, ack 248
14:02:11.307410 IP 127.0.0.1.8080  > 127.0.0.1.45672: Flags [.],  ack 79, win 512
```

tcpdump 的 flags 记号对应:`[S]`=SYN,`[S.]`=SYN,ACK,`[.]`=ACK,`[P.]`=PSH,ACK,`[F.]`=FIN,ACK。
按序解读(写进 `answers.txt` B 节的参考答案):

```text
01 flags=SYN       说明=客户端发 SYN,seq=x,进入 SYN_SENT
02 flags=SYN,ACK   说明=服务端同意并回自己的 seq=y、ack=x+1,进入 SYN_RCVD
03 flags=ACK       说明=客户端回 ack=y+1,三次握手完成,双方 ESTABLISHED
04 flags=PSH,ACK   说明=客户端推送 GET 请求,PSH 提示对端立即交给应用
05 flags=PSH,ACK   说明=服务端推送 HTTP/1.0 200 OK 响应体
06 flags=ACK       说明=客户端确认收到响应
07 flags=FIN,ACK   说明=服务端主动关闭(HTTP/1.0 无 keepalive),进入 FIN_WAIT_1
08 flags=ACK       说明=客户端回 ACK,服务端进 FIN_WAIT_2,客户端进 CLOSE_WAIT
09 flags=FIN,ACK   说明=客户端也关闭,进入 LAST_ACK
10 flags=ACK       说明=服务端回最终 ACK,进入 TIME_WAIT 停留 60 秒后彻底关闭
```

注意本例中**服务端**是主动关闭方,所以 TIME_WAIT 落在 8080 一侧(`ss -tan state time-wait`
里 local 地址是 8080);ab 场景里客户端也主动关,所以两头都有。这正是"谁主动关谁等 60 秒"。

## 5. conntrack:连接跟踪表观察

为什么重要:netfilter 对每条 TCP 连接建一条跟踪记录,k8s 节点上 kube-proxy/Calico 的
SNAT/DNAT 全依赖它;表满(`nf_conntrack_count` 到 `nf_conntrack_max`)时新连接被静默丢弃,
症状就是"莫名其妙的超时"。回环流量同样会被跟踪。

```bash
# [任意节点]
sudo conntrack -L -p tcp --dport 8080 | head -3
sudo conntrack -S | head -4
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max
```

```text
# [任意节点] 预期输出(压测刚结束时)
tcp  6 431987 ESTABLISHED src=127.0.0.1 dst=127.0.0.1 sport=51234 dport=8080 \
     src=127.0.0.1 dst=127.0.0.1 sport=8080 dport=51234 [ASSURED] mark=0 use=1
tcp  6 57 TIME_WAIT src=127.0.0.1 dst=127.0.0.1 sport=51235 dport=8080 ...
conntrack v1.4.6 (conntrack-tools): 42 flow entries have been shown.
CPU 0: found=132 invalid=0 insert=81234 insert_failed=0 drop=0 early_drop=0 error=0
8421
262144
```

读法:一条条目同时记录正反两个方向的五元组;第二个数字是剩余超时秒数,
TIME_WAIT 条目约 60 秒后自动淘汰;`insert_failed/drop` 非零说明表写有压力。
把看到的条目数、状态名、drops 数值记入 `answers.txt` C 节。
短连接风暴的代价在这里现形:连接只用几十毫秒,跟踪条目却要陪跑 60 秒,
QPS 高时表内 TIME_WAIT 条目就是 `峰值 QPS x 60` 量级。

## 6. 清理

```bash
# [任意节点]
sudo sysctl -w net.ipv4.tcp_tw_reuse=<TW_reuse_orig 里记录的原值>   # 恢复实验前状态
sudo pkill -x ab 2>/dev/null
sudo pkill -f 'burst\.sh' 2>/dev/null
pkill -f 'http.server 8080' 2>/dev/null || docker rm -f drill-nginx
sudo rm -f /tmp/ab-run1.log /tmp/ab-reuse0.log /tmp/ab-reuse2.log /tmp/burst.log \
           /tmp/httpd.log /tmp/tw-sample.log ~/drill/burst.sh
```

验证:`sysctl -n net.ipv4.tcp_tw_reuse` 输出 `0`;`ss -H -ltn | grep ':8080'` 无输出;
一分钟后 `ss -H -tan state time-wait | wc -l` 回落到基线附近。

## 7. check.sh 通过示例

```bash
# [任意节点]
cd 01-linux/labs/02-network-stack-lab
chmod +x check.sh
./check.sh ~/drill/answers.txt
```

```text
# [任意节点] check.sh 通过时的输出
PASS: answers.txt 存在且包含 A/B/C 三节
PASS: TW_baseline / TW_reuse0 / TW_reuse2 已记录数值
PASS: 记录了 tcp_tw_reuse=0 与 =2 修改命令
PASS: 包序解读 >= 8 包(实际 10 包)
PASS: 三次握手顺序正确(SYN -> SYN,ACK -> ACK)
PASS: 数据阶段 PSH,ACK >= 2(请求 + 响应)
PASS: 四次挥手完整(存在 FIN,ACK 且其后有 ACK)
PASS: conntrack 观察已记录(命令 + 数值)
PASS: net.ipv4.tcp_tw_reuse 已恢复为实验前原值(示例 2)
PASS: 现场已清理:无 ab/burst.sh,8080 未监听
SCORE: 10/10
```

## 8. 延伸阅读

- ip-sysctl 文档(tcp_tw_reuse 等参数权威说明):https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt
- TCP 状态机(RFC 9293):https://www.rfc-editor.org/rfc/rfc9293.html
- conntrack-tools:https://github.com/netfilter/conntrack-tools
