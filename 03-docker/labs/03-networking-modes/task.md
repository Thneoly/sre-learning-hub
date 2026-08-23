# Lab 03 · 四种网络模式与端口映射的 iptables 真相

> 难度：★★☆ ｜ 考点：CKA-网络（bridge/none/host 模式、容器 DNS、DNAT） ｜ 前置：lab 01 ｜ 预计 30~40 分钟

## 场景

作为网络工程师出身的你，接手一台 Docker VM 后被两个"灵异现象"困扰过：同一主机的两个容器有时能用名字互 ping、有时不能；`-p 8083:80` 明明没改 nginx 配置，外部就能访问了。这次你要把 Docker 的四种网络模式（bridge / host / none / container）逐一跑一遍，并顺着 `iptables -t nat` 把端口映射的转发链路亲手找出来——这条 DNAT 链路和 Kubernetes 的 kube-proxy userspace 模式、Calico 的 nat-outgoing 是同一套内核机制。

## 任务清单

1. 创建自定义 bridge 网络 `lab03net`（subnet `172.28.0.0/24`），启动 `c1`、`c2` 两个 `alpine` 容器（`sleep infinity`）接入该网络；在 `c1` 内分别用容器名和 IP ping 通 `c2`。
2. 在默认 bridge（`bridge` 网络）上启动 `d1`、`d2`，验证：IP 互通，但**容器名不解析**（对比自定义网络的 embedded DNS）；再给它们 `docker network connect` 到 `lab03net`，验证名字开始可解析。
3. 启动 `n1`（`--network none`），验证它只有 `lo`，无默认路由，ping 任何外部地址失败。
4. 启动 `h1`（`--network host`，跑 `nginx:alpine`），验证它直接占用宿主机 80 端口，无 `-p`、无独立 IP。
5. 启动 `k1`（`--network container:c1`），验证它与 `c1` 共享 network namespace：`hostname`、`ip addr` 完全一致，`localhost` 互通。
6. 在 `lab03net` 上启动 `p1`（`nginx:alpine`，`-p 8083:80`），宿主机 curl 验证；然后用 `sudo iptables -t nat -S DOCKER` 找到 8083 的 DNAT 规则，画出完整转发路径。

## 验收标准

- 网络 `lab03net` 存在（driver bridge，subnet 172.28.0.0/24），`c1`/`c2` 均接入且运行中；
- `docker exec c1 ping -c1 c2` 按名解析成功；
- `h1` 以 host 模式运行，宿主机 `curl localhost` 直接返回 nginx 页面；
- `p1` 运行中且发布 `8083->80`，宿主机 curl 通；
- `n1` 存在且为 none 模式。

完成后运行判分脚本：

```bash
# [Ubuntu VM]
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：为什么默认 bridge 不解析容器名？</summary>

embedded DNS server（127.0.0.11）只挂在**用户自定义网络**上；默认 bridge 是历史遗留行为，只有 `--link`（已废弃）或手写 `extra_hosts`。Kubernetes 里每个 Pod 独立 netns + 集群 DNS，不存在这个问题。
</details>

<details><summary>提示 2：DNAT 规则长什么样？</summary>

`sudo iptables -t nat -S DOCKER` 里有形如 `-A DOCKER ! -i lab03net -p tcp -m tcp --dport 8083 -j DNAT --to-destination 172.28.0.x:80` 的规则。注意 `! -i lab03net`：来自该 bridge 自身的流量不做 DNAT，避免容器间通信被二次改写。
</details>

<details><summary>提示 3：host 模式下 -p 会怎样？</summary>

host 模式没有 namespace 隔离，`-p` 被忽略并打印警告；端口冲突直接体现在宿主机上。生产上 host 模式常用于高性能转发（如 node-exporter、Calico 组件）。
</details>
