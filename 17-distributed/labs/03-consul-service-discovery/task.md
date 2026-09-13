# Lab 03 · Consul 服务发现与健康检测：注册、摘除、DNS 与一次杀 Leader

> 难度：★★☆ ｜ 考点：分布式理论-服务发现/成员管理与健康检测（对应模块第 06 章 gossip 与成员管理，Raft 部分对应第 03 章）｜ 前置：本模块 Lab 01（etcd Raft 观测）、装有 Docker 与 docker compose 的 Ubuntu VM（`[任意节点]`）；宿主需 curl（必装）与 dig（没有就 `sudo apt-get install -y dnsutils`）｜ 预计 45~60 分钟

## 场景

你是接入平台的 SRE。新业务的服务发现走 Consul：实例上线时把"名字 + 地址 + 端口 + 健康检查"注册进去，消费方用 DNS（`web.service.consul`）或 HTTP API 取地址——**只有健康检查 passing 的实例会被返回**。半夜的告警往往是"web 变 critical 了"：你要能立刻分清是进程挂了、节点挂了还是 Consul 自己脑补，而这就要求你亲手把整条链路走过一遍：注册 → passing → kill 进程变 critical → 恢复变 passing → DNS 随之摘/挂地址。

理论对应关系先摆清楚（都在本模块讲过，本 lab 是它们的现场版）：

- Consul 是**双平面架构**：成员关系（谁在线）走 LAN gossip（SWIM/serf 家族），服务目录与 KV 走 Raft 强一致——正是第 06 章"gossip 负责知情，quorum 负责定罪"的双层结构（`../../06-gossip-membership-fencing.md` 第 1 节拿 Redis Cluster 讲了同一个模式）；Consul 内嵌 Raft 这件事第 03 章第 6 节点过名，本 lab 第 8 步把它当 etcd 的"换词汇表版"再杀一次 Leader。
- 健康检查失败 = 第 01 章的遗漏故障判定：HTTP 探测超时只说明"期限内没应答"， Consul 据此把实例标 critical——不是"确认死亡"，是"不再向消费方推荐它"。
- agent 与 catalog 之间的对账机制就叫反熵（anti-entropy，`../../02-consistency-models.md` 第 4 节的术语）。

一个必须先说清的坑（也是本 lab 用 agent API 而不是 catalog API 注册的原因）：**`PUT /v1/catalog/register` 里带的 Check 字段只是往目录里写了一条静态健康记录，任何 agent 都不会去执行它**——HTTP/Interval 填了也白填，状态永远停在初始值。官方文档原话：要真正启用检查，必须走 agent 配置或 agent 端点（以官方文档为准：https://developer.hashicorp.com/consul/api-docs/catalog ）。所以本 lab 的注册走 `PUT /v1/agent/service/register`（同样是 JSON），注册到 dist-consul-1 这个 agent 上，由它每 2 秒探测一次假服务。

网络与命名约定（check.sh 依赖，请严格使用）：

| 对象 | 名字 | 说明 |
|---|---|---|
| compose 项目 | `dist-consul` | `docker compose -p dist-consul` |
| docker 网络 | `dist-consul-net`（172.29.1.0/24） | 独立 bridge，避开 dist-etcd-net（172.29.0.0/24）与 redis-ha-lab（172.28.0.0/24） |
| Consul 容器 | `dist-consul-1` / `dist-consul-2` / `dist-consul-3` | hashicorp/consul:1.x，server 模式；`-1` 发布 8500/8600 到宿主 |
| 假健康服务容器 | `dist-web-1` | python:3.12-alpine，`python3 -m http.server 8080`，`/health` 返回 200 |
| KV 键 | `service/config/nginx/port`（值 8080）、`dist/lab/owner` | 前者 check.sh 判分 |
| 注册的服务 | 服务名 `web`，Service ID `web-1`，CheckID `web-1-http` | 检查间隔 2s |
| 工作目录 | `~/dist-consul/` | compose.yaml、web.json 与全部实验记录 |

实验记录文件（check.sh 要检查，一个都不能少）：

| 文件 | 内容 |
|---|---|
| `~/dist-consul/kv.txt` | 两个键的 `consul kv get` 回读输出（含 `8080`） |
| `~/dist-consul/health-passing.txt` | 服务健康时 `/v1/health/service/web` 的 Status 摘要（含 passing） |
| `~/dist-consul/health-critical.txt` | kill 假服务后的同一摘要（含 critical） |
| `~/dist-consul/dns.txt` | `dig @127.0.0.1 -p 8600 web.service.consul` 全量输出（ANSWER 段有 A 记录） |
| `~/dist-consul/leader-elect.txt` | （可选任务，不判分）杀 Leader 后的新 Leader 选举耗时毫秒数 |

## 任务清单

1. 创建 `~/dist-consul/compose.yaml`（内容见提示 1），`docker compose -p dist-consul up -d` 启动 3 个 Consul server 与 1 个假服务容器；等约 10~15 秒让三节点通过 LAN gossip 汇合、bootstrap 完成
2. **集群状态验证**：`docker exec dist-consul-1 consul members` 应有 3 行 alive/server；`docker exec dist-consul-1 consul operator raft list-peers` 应恰好一个 leader；宿主 `curl -s http://127.0.0.1:8500/v1/status/leader` 应返回非空地址
3. **KV 存取**：`consul kv put` 写入 `service/config/nginx/port=8080` 与 `dist/lab/owner=<你的名字>`（在任一 server 容器内执行），`kv get` 回读并把两次输出存入 `~/dist-consul/kv.txt`
4. **注册 web 服务**：写 `~/dist-consul/web.json`（内容见提示 2，服务地址填 dist-web-1 的**容器 IP**+8080——填主机名 DNS 就拿不到 A 记录，原因见提示 2；Check 为 HTTP `http://dist-web-1:8080/health`、间隔 2s），`curl -X PUT --data-binary @web.json` 到 `http://127.0.0.1:8500/v1/agent/service/register`，用 `consul catalog services` 确认 `web` 已入目录
5. **验证 passing**：轮询 `/v1/health/service/web` 直到 `web-1-http` 为 passing（提示 3；注册后到首次探测成功前有一个短暂的初始 critical 窗口，正常），把 Status 摘要存入 `health-passing.txt`——注意里面应有**两条**检查：`serfHealth`（gossip 成员检查，节点级）与 `web-1-http`（服务级）
6. **DNS 查询**：宿主执行 `dig @127.0.0.1 -p 8600 web.service.consul | tee ~/dist-consul/dns.txt`，ANSWER 段的 A 记录 IP 应等于 web.json 里注册的 `Address`（即 `docker inspect` 查到的 dist-web-1 容器 IP）
7. **kill 假服务 → critical**：`docker kill dist-web-1`（SIGKILL，进程没了容器还在 Exited），轮询等 `web-1-http` 变 critical（间隔 2s，预计 10 秒内），摘要存入 `health-critical.txt`；再 dig 一次看 ANSWER 段变空（不判分，但要看——这就是"健康检查不通过 = DNS 摘流量"）
8. **恢复 → passing**：`docker start dist-web-1`，轮询确认 `web-1-http` 回到 passing——check.sh 运行时必须处于这个终态
9. **（可选）杀 Leader**：用 `raft list-peers` 找到 leader 容器，`docker kill` 前后计时，轮询幸存者直到出现新 leader，把耗时毫秒数存入 `leader-elect.txt`，然后 `docker start` 恢复该节点（与 Lab 01 的 etcd 数字对照着看）
10. 运行 check.sh，`SCORE: 12/12` 后再执行提示 5 的清理（集群留着跑 check，别提前拆）

## 验收标准

- `dist-consul-1/2/3` 与 `dist-web-1` 四个容器全部 Running；`consul members` 3 个 alive server；leader 存在且唯一
- `service/config/nginx/port` 读回 `8080`
- `consul catalog services` 列出 `web`；live 状态 `/v1/health/service/web` 中 `web-1-http` 为 passing（已恢复）
- `health-passing.txt` 含 passing、`health-critical.txt` 含 critical——双态证据齐全
- `dns.txt` 的 ANSWER 段有 `web.service.consul` 的 A 记录（IP 即注册进 web.json 的容器 IP，而非 CNAME）

## 提示（卡住再看）

<details><summary>提示 1：compose.yaml（dev 风格的最小三节点 server 集群）</summary>

`consul agent -dev` 是**单 agent、纯内存**模式，没法三节点组网，官方定位就是快速体验（生产勿用，以官方文档为准：https://developer.hashicorp.com/consul/docs/agent/config/cli-files ）。三节点用 server agent 的最小配置等价替代：不挂数据卷（重启即清空，仅练习）、无 TLS/ACL，行为与 dev 一样轻。镜像 tag 以官方 Docker Hub 发布为准（1.x 任意近版均可，命令参数一致）。

```yaml
# [任意节点] ~/dist-consul/compose.yaml
x-consul-common: &consul-common
  image: ${CONSUL_IMAGE:-hashicorp/consul:1.20}   # tag 以官方发布为准
  networks: [consul-net]

services:
  consul1:
    <<: *consul-common
    container_name: dist-consul-1
    ports:
      - "8500:8500"        # HTTP API / UI，宿主 curl 用
      - "8600:8600/tcp"    # DNS，宿主 dig 用
      - "8600:8600/udp"
    command:
      - agent
      - -server
      - -bootstrap-expect=3
      - -node=dist-consul-1
      - -client=0.0.0.0
      - -ui
  consul2:
    <<: *consul-common
    container_name: dist-consul-2
    command:
      - agent
      - -server
      - -bootstrap-expect=3
      - -node=dist-consul-2
      - -client=0.0.0.0
      - -retry-join=dist-consul-1
  consul3:
    <<: *consul-common
    container_name: dist-consul-3
    command:
      - agent
      - -server
      - -bootstrap-expect=3
      - -node=dist-consul-3
      - -client=0.0.0.0
      - -retry-join=dist-consul-1
  web:
    image: python:3.12-alpine
    container_name: dist-web-1
    networks: [consul-net]
    command:
      - sh
      - -c
      - mkdir -p /srv && echo ok-health > /srv/health && exec python3 -m http.server 8080 --directory /srv

networks:
  consul-net:
    name: dist-consul-net
    driver: bridge
    ipam:
      config:
        - subnet: 172.29.1.0/24
```

`--directory` 让 `/health` 直接命中 `/srv/health` 文件返回 200。`-bootstrap-expect=3` 表示凑齐 3 个 server 才选 leader（少一个就无主——第 03 章的 quorum 账）。浏览器开 `http://<VM-IP>:8500/ui` 能看界面（可选）。
</details>

<details><summary>提示 2：web.json 与注册命令</summary>

`~/dist-consul/web.json` —— 注册到【agent】，不是 catalog。**`Address` 必须填容器 IP，不能填主机名**：Consul 的 DNS 接口对非 IP 的 Service.Address 只会返回 CNAME（`web.service.consul. 0 IN CNAME dist-web-1.`），永远不会为 `web.service.consul` 本身返回 A 记录——任务 6 的 dig 就白做了。健康检查的 `HTTP` URL 倒是可以继续用主机名 `http://dist-web-1:8080/health`（执行检查的 agent 走容器 DNS 能解析它）。

```bash
# [任意节点] 先取容器 IP，再用它生成 web.json（与 11 章 Redis 演练取容器 IP 同一姿势）
WEB1=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' dist-web-1)
cat > ~/dist-consul/web.json <<EOF
{
  "ID": "web-1",
  "Name": "web",
  "Tags": ["dist-lab"],
  "Address": "$WEB1",
  "Port": 8080,
  "Meta": { "lab": "17-distributed-03" },
  "Checks": [
    {
      "CheckID": "web-1-http",
      "Name": "web-1 /health",
      "Notes": "python http.server on dist-web-1",
      "HTTP": "http://dist-web-1:8080/health",
      "Interval": "2s",
      "Timeout": "1s"
    }
  ]
}
EOF

# 注册 + 确认
curl -s -X PUT -H 'Content-Type: application/json' \
     --data-binary @$HOME/dist-consul/web.json \
     http://127.0.0.1:8500/v1/agent/service/register
docker exec dist-consul-1 consul catalog services   # 预期两行：consul / web
```

字段语义：`Name` 是消费方查询的名字（DNS 里的 `web.service.consul`）；`Address`+`Port` 是实例真实地址（必须是 IP——DNS 的 A 记录从它来；可以与注册它的 agent 不在一台机器上——本 lab 正是这样：注册在 dist-consul-1，服务在 dist-web-1）；`Checks` 数组允许一个服务挂多个检查，全部 passing 服务才 passing。
</details>

<details><summary>提示 3：轮询等状态翻转（passing / critical 通用）</summary>

```bash
# [任意节点] 通用轮询：第一个参数是期望状态（passing 或 critical），最多等 30s
wait_status() {
  for i in $(seq 30); do
    ST=$(curl -s http://127.0.0.1:8500/v1/health/service/web \
         | grep -o '"CheckID":"web-1-http"[^}]*' | grep -o '"Status":"[a-z]*"')
    echo "t=${i}s $ST"
    echo "$ST" | grep -q "\"$1\"" && return 0
    sleep 1
  done
  return 1
}
wait_status passing    # 注册后等首次探测成功
# 存证据：注意会打印两条检查（serfHealth 与 web-1-http）
curl -s http://127.0.0.1:8500/v1/health/service/web \
  | grep -o '"Status":"[a-z]*"' | tee ~/dist-consul/health-passing.txt

docker kill dist-web-1
wait_status critical   # 预期 10s 内翻转（间隔 2s + 超时 1s）
curl -s http://127.0.0.1:8500/v1/health/service/web \
  | grep -o '"Status":"[a-z]*"' | tee ~/dist-consul/health-critical.txt

# 关键时刻对照：critical 期间 DNS 不再有 A 记录
dig @127.0.0.1 -p 8600 web.service.consul +short    # 预期：空输出

docker start dist-web-1
wait_status passing    # 恢复
```
</details>

<details><summary>提示 4：（可选）杀 Leader 并计时</summary>

```bash
# [任意节点] 找 State 列为 leader 的行，反推容器名（node 名与容器名一致）
docker exec dist-consul-1 consul operator raft list-peers
LEADER_NODE=$(docker exec dist-consul-1 consul operator raft list-peers \
              | awk '$4=="leader"{print $1}')
START=$(date +%s%3N)
docker kill "$LEADER_NODE"

NEW=""
while [ -z "$NEW" ]; do          # 只探测幸存者；无主窗口内 list-peers 可能报错，正好当作"还没选出来"
  for c in dist-consul-2 dist-consul-3; do
    [ "$c" = "$LEADER_NODE" ] && continue
    NEW=$(docker exec "$c" consul operator raft list-peers 2>/dev/null \
          | awk '$4=="leader"{print $1}')
    [ -n "$NEW" ] && break
  done
  [ -z "$NEW" ] && sleep 0.2
done
END=$(date +%s%3N)
printf '%s\n%s\n' "$((END - START))" "$NEW" | tee ~/dist-consul/leader-elect.txt

docker start "$LEADER_NODE"      # 恢复三节点，留给 check.sh 一个完整集群
sleep 8                          # 等它通过 gossip 重新入席
docker exec dist-consul-1 consul members
```

预期耗时几百毫秒到几秒量级（Consul 的 Raft 选举超时与 etcd 同一量级，具体默认值以官方文档为准）。与 Lab 01 的 etcd 数字放一起，就是"Raft 是同一套东西"的实测注脚。
</details>

<details><summary>提示 5：清理</summary>

```bash
# [任意节点] check 通过后再执行
cd ~/dist-consul && docker compose -p dist-consul down -v --remove-orphans
docker network rm dist-consul-net 2>/dev/null
```

数据随容器销毁；记录文件留在 `~/dist-consul/` 无妨，重做 lab 前先删掉旧记录避免误判。
</details>

## 关联阅读

- 本模块理论对应章：gossip 与成员管理、双层结构（gossip 管知情 / quorum 管定罪）：`../../06-gossip-membership-fencing.md` 第 1/3 节；Raft 选举与 quorum：`../../03-consensus-and-replication.md` 第 2/4 节
- 超时判定 = 遗漏故障模型（健康检查 critical 的理论出身）：`../../01-failure-models-and-time.md` 第 1 节；最终一致的持续对账（anti-entropy）：`../../02-consistency-models.md` 第 4 节（§4.1 收敛靠什么：反熵机制）
- 同一套 Raft 在 etcd 上的完整故障注入版：`../01-etcd-raft-observation/task.md`
- "为什么 K8s 不用 Consul 这类注册中心管 Pod"（list-watch 与唯一写入口的理由）：`../../06-gossip-membership-fencing.md` 第 2 节
- Consul 官方文档（架构与 API，版本敏感处一律以此为准）：https://developer.hashicorp.com/consul/docs
