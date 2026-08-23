# Lab 03 · 解答与讲解

> 前置：Ubuntu VM 已装 Docker；本机 80 端口未被占用（host 模式实验要用）。

## 第 1 步：自定义 bridge + 容器 DNS

```bash
# [Ubuntu VM]
docker network create --driver bridge --subnet 172.28.0.0/24 lab03net
docker run -d --name c1 --network lab03net alpine sleep infinity
docker run -d --name c2 --network lab03net alpine sleep infinity
docker exec c1 ping -c 2 c2
docker exec c1 ip -4 addr show eth0 | grep inet
```

预期：`ping c2` 解析到 `172.28.0.x` 并通。解析来自 embedded DNS（容器内 `/etc/resolv.conf` 指向 `127.0.0.11`）：

```bash
# [Ubuntu VM]
docker exec c1 cat /etc/resolv.conf
```

宿主机侧的变化：多了网桥 `br-<id>`（对应 lab03net）和 veth pair——容器 eth0 一端在容器 netns，另一端挂在网桥上：

```
   c1 netns                宿主机 network namespace
  ┌──────────┐   veth   ┌──────────────────────────┐
  │ eth0 ────┼──────────┼──▶ br-xxxx (lab03net)    │──▶ enp0s3 (默认路由出网)
  │ 172.28.0.2          │   172.28.0.1 (网关+DNS代理)│
  └──────────┘          └──────────────────────────┘
   c2 eth0 172.28.0.3 也挂在同一个 br-xxxx 上 → 二层直通
```

```bash
# [Ubuntu VM]
docker network inspect lab03net --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'
```

## 第 2 步：默认 bridge 的"灵异现象"

```bash
# [Ubuntu VM]
docker run -d --name d1 alpine sleep infinity
docker run -d --name d2 alpine sleep infinity
docker exec d1 ping -c 1 -W 2 d2 || echo "按名 ping 失败（预期）"
docker exec d1 ping -c 1 -W 2 "$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' d2)"
```

预期：按名失败（`bad address`），按 IP 成功。默认 bridge 没有 embedded DNS。把 d1 接入 lab03net 后：

> 两个环境相关的新情况（实测 Docker 29）：
> 1. 新版 Docker 的默认 bridge 容器 `/etc/resolv.conf` 里也会出现 `nameserver 127.0.0.11`——但它只是**转发式**解析（不带本网络容器名记录），`d2` 这类容器名依然查不到、会被继续抛给上游 DNS；
> 2. 若宿主机上游是"泛解析"DNS（如代理的 fake-ip 模式，把任何名字都解析成 `198.18.x.x`），`ping d2` 可能"意外成功"——看返回的 IP 不是 `172.17.0.x` 就知道解析到的是假地址，教学结论不变：**默认 bridge 上容器名拿不到容器的真实 IP**。

```bash
# [Ubuntu VM]
docker network connect lab03net d1
docker network connect lab03net d2
docker exec d1 ping -c 1 -W 2 d2
```

现在按名能通了（同一用户自定义网络内）。要点：**DNS 解析的范围是"同一个自定义网络"**——这与 Kubernetes NetworkPolicy / namespace-scoped Service DNS 的思路类似，网络边界即名字边界。

## 第 3 步：none 模式

```bash
# [Ubuntu VM]
docker run -d --name n1 --network none alpine sleep infinity
docker exec n1 ip addr
docker exec n1 ip route || echo "无路由表（预期）"
docker exec n1 ping -c 1 -W 2 172.28.0.1 || echo "ping 失败（预期）"
```

预期输出只有 `lo: <LOOPBACK,UP,...> mtu 65536`，没有 eth0；route 表为空；ping 失败。none 模式 = 完全网络隔离，适合跑离线批处理或安全审计场景（CKS 思路：不需要网络的容器就不给网络）。

## 第 4 步：host 模式

```bash
# [Ubuntu VM]
docker run -d --name h1 --network host nginx:alpine
docker exec h1 ip -4 addr show eth0 | grep inet   # 与宿主机 eth0 完全相同
ss -ltnp | grep ':80 '                            # 宿主机直接看到 nginx 占用 80
curl -sI http://localhost/ | head -1
```

预期 `HTTP/1.1 200 OK`。host 模式下容器与宿主机**共享同一个 netns**：没有 veth、没有 NAT、性能无损，但端口冲突要自己管。Calico 的 `calico-node`、Prometheus node-exporter 常用 host 或 hostNetwork 方式跑，原因相同。

## 第 5 步：container 模式（共享 netns）

```bash
# [Ubuntu VM]
docker run -d --name k1 --network container:c1 alpine sleep infinity
docker exec c1 hostname
docker exec k1 hostname        # 与 c1 相同
docker exec c1 ip -4 addr show eth0 | grep inet
docker exec k1 ip -4 addr show eth0 | grep inet   # 与 c1 相同的 IP
docker exec k1 wget -qO- -T 3 http://127.0.0.1:80 || echo "c1 上没有 80 服务（预期，仅验证 localhost 互通需先起服务）"
```

container 模式 = 新容器直接加入已有容器的 netns（Kubernetes Pod 正是这个机制：pause 容器先建 netns，业务容器全部 `--network container:<pause>`，所以一个 Pod 内所有容器共享 IP，端口不能冲突，`localhost` 互通）。

## 第 6 步：端口映射与 iptables 链路

```bash
# [Ubuntu VM]
docker run -d --name p1 --network lab03net -p 8083:80 nginx:alpine
curl -sI http://localhost:8083/ | head -1
```

现在把转发路径挖出来：

```bash
# [Ubuntu VM]
sudo iptables -t nat -S DOCKER
sudo iptables -t nat -L PREROUTING -n --line-numbers | head -5
sudo iptables -t nat -L OUTPUT -n --line-numbers | head -5
sudo iptables -L DOCKER-USER -n
```

`-S DOCKER` 里找 8083，预期看到类似：

```
-A DOCKER ! -i br-xxxxxxxx -p tcp -m tcp --dport 8083 -j DNAT --to-destination 172.28.0.4:80
```

完整路径（外部客户端访问 VM:8083）：

```
外部 client ──▶ VM eth0 :8083
                   │
                   ▼ (PREROUTING nat 表)
              DNAT → 172.28.0.4:80
                   │
                   ▼ (FORWARD filter 表, 先过 DOCKER-USER)
              br-xxxx → p1 eth0 (172.28.0.4)
                   │
                   ▼
              nginx 响应，源 IP 172.28.0.4
                   │
                   ▼ (POSTROUTING nat 表, MASQUERADE/SNAT)
              源地址改写回 VM IP:8083 ──▶ client
```

三个关键点（对 K8s 的映射）：

1. `DOCKER-USER` 链在所有 Docker 规则**之前**被 FORWARD 命中——外部防火墙策略写在这里，不会被 `docker run` 覆盖（类比 Calico 的 host-endpoints / iptables 规则优先级之争）。
2. `! -i br-xxxx` 防止同网桥容器间通信被 DNAT 改写——容器互访走的是二层直通，根本不进 nat 表。
3. 本机 `curl localhost:8083` 走的是 `OUTPUT` 链的 DNAT（localhost 不是从网卡进来的，不经过 PREROUTING 的外部路径）——所以仅绑定容器端口也能本机访问。

## 第 7 步：netns 与路由的收尾验证（选做）

```bash
# [Ubuntu VM]
docker exec c1 ip route
docker exec c1 cat /proc/sys/net/ipv4/ip_forward   # 容器内通常为 1 的宿主机全局值不可见，实际转发发生在宿主机
sysctl net.ipv4.ip_forward                          # 宿主机必须为 1，否则 -p 端口映射不通
```

`ip_forward=0` 是"容器能 ping 网关但宿主机外部访问 `-p` 端口不通"的经典原因之一（学习中心 scripts 里的 `break-ipforward.sh` 制造的就是这个故障）。

## 判分脚本结果

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

预期输出：

```
PASS: 网络 lab03net 存在且 driver 为 bridge
PASS: lab03net subnet 为 172.28.0.0/24
PASS: c1 运行中且接入 lab03net
PASS: c2 运行中且接入 lab03net
PASS: c1 可按名 ping 通 c2
PASS: h1 运行中且 NetworkMode 为 host
PASS: p1 运行中且发布 8083->80
PASS: curl http://localhost:8083 返回 nginx 页面
PASS: n1 存在且 NetworkMode 为 none

SCORE: 9/9
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| 默认 bridge 上容器名不通 | 默认 bridge 无 embedded DNS | 用自定义网络，或 `docker network connect` |
| `-p` 后外部访问超时 | 宿主机 `ip_forward=0` 或云安全组没放行 | `sysctl -w net.ipv4.ip_forward=1`；检查安全组/iptables DOCKER-USER |
| host 模式起不来 nginx | 宿主机 80 已被占用 | 换端口或停掉占用者；host 模式无端口映射可言 |
| 容器访问外网失败 | bridge 网络的 MASQUERADE 规则缺失或 UDP checksum 问题 | 重建 docker0 / 重启 daemon；避免在 VM 里嵌套虚拟化网段与 172.28 冲突 |
| subnet 冲突报错 `Pool overlaps with other one` | 172.28.0.0/24 已被占用 | `docker network ls` + `docker network inspect` 排查后删除，或换网段 |

## 清理（保留 lab03net 供复查，彻底清理用）

```bash
# [Ubuntu VM]
docker rm -f k1 d1 d2 n1 h1
# docker rm -f c1 c2 p1 && docker network rm lab03net
```

## 延伸阅读

- Docker 容器网络：https://docs.docker.com/engine/network/
- iptables 的 nat 表与 DNAT：https://netfilter.org/documentation/HOWTO/NAT-HOWTO.html
