# 01 · 云基础：从自建机房到公有云

> 模块：14-cloud ｜ 建议时长：3 小时 ｜ 关联认证：CKA-网络 / CKS-网络策略 / —（云本身无直接考点，但 ACK/EKS 是 k8s 的生产形态）

## 学习目标

- 能解释 IaaS/PaaS/SaaS 的责任边界差异，并判断某故障该由谁修
- 能说明 Region（地域）与 Available Zone（可用区）的层级关系，以及多 AZ 部署为什么能抗机房级故障
- 能对比按量付费/包年包月/预留实例的计费逻辑与适用场景
- 能把 VPC、vSwitch、安全组、NACL、路由表一一映射到自己熟悉的机房设备（交换机/ACL/网关），并说出云计算网络与物理网络的三点核心差异

## 1. 云是什么：一台"别人的机房"里的资源超市

你已经在机房里干过这些事：上架服务器、插网线进交换机、配 VLAN、在防火墙上开 ACL、找 IDC 报修硬盘。公有云把这套流程变成了 API：

- 装系统 → 调 API 创建一台 ECS/EC2 实例（60 秒返回 IP 和 root 密码）
- 接交换机 → 创建 vSwitch（虚拟交换机）并划 CIDR
- 配防火墙 ACL → 写安全组（Security Group）规则
- 报修硬盘 → 块存储本身是多副本的，坏盘由云厂商处理，你无感知

理解云的正确姿势：**不是学一堆新概念，而是把你脑子里的机房拓扑逐层"翻译"成云上的对象**。第 5 节做完整翻译表。

### 1.1 IaaS / PaaS / SaaS：责任分界线

经典披萨比喻不如一张责任矩阵好使。以"数据库跑在谁家"为例：

| 层级 | 你拿到什么 | 你管什么 | 云厂商管什么 | 典型例子 |
|------|-----------|---------|-------------|---------|
| On-Premise | 一间机房 | 硬件、虚拟化、OS、中间件、应用、数据 | — | 自建 IDC |
| IaaS | 一台 VM（或裸金属） | OS 补丁、中间件、应用、数据 | 宿主机、网络、存储底层 | ECS、EC2 |
| PaaS | 一个运行时/服务端点 | 应用代码、数据 | OS、中间件、补丁、备份 | RDS、函数计算、Cloud Run |
| SaaS | 一个网页/账号 | 业务数据、账号权限 | 其他一切 | 钉钉、Gmail |

对排障的意义：**先判断层级，再判断责任**。

- RDS 实例里 MySQL 崩了 → 大概率是你（慢 SQL、连接数打满），因为 PaaS 里"数据库的使用方式"仍归你
- RDS 底层宿主机磁盘故障 → 云厂商，你最多看到了一次主备切换（分钟级）
- ECS 网卡丢包 → 可能是你的安全组/路由配错，也可能是宿主机网络问题，开工单前先自己把链路 ping/traceroute 一遍

经验法则：**越往下层（IaaS）自由度越高、责任越大；越往上（SaaS）你只剩配置和数据**。K8s 恰好在中间：ACK/EKS 把控制面做成 PaaS（厂商管 etcd/apiserver），你的责任从 node 进程往上开始。

## 2. Region 与可用区：故障域的层级设计

### 2.1 三级故障域

```
Region（地域）         例如 cn-hangzhou / ap-northeast-1
 └── 可用区 AZ         例如 cn-hangzhou-a / -b / -h
      └── 物理机/机架  同一 AZ 内仍在不同故障域（不同机架、不同供电回路）
```

- **Region**：地理上的独立城市级部署，Region 之间物理网络隔离（专线/公网互联，延迟大、带宽贵）。选 Region 的第一因素是**用户在哪**（延迟），第二是**合规**（数据不出境）。
- **AZ（Available Zone）**：同一城市内电力、网络、制冷相互独立的机房（或同一机房内独立故障域）。AZ 之间用低延迟光纤互联（通常 1~3ms），**同 Region 跨 AZ 的内网流量免费或低价（以厂商文档为准），跨 Region 一定收费且贵**。

### 2.2 为什么多 AZ

单 AZ = 单机房 = 单点。机房级故障真实发生：市电+UPS 双挂、光缆被挖断、水冷泄漏。多 AZ 部署的本质是**用 2~3 倍的最低资源冗余，换掉"整个机房"这个单点**。

对一个 Web 服务的最小多 AZ 形态：

```
            SLB / ALB（Anycast 或多 AZ 接入）
              │
      ┌───────┴────────┐
   ECS ×2 (AZ-a)    ECS ×2 (AZ-b)     ← 无状态，双 AZ 各留容量
      └───────┬────────┘
         RDS 主 / 备（AZ-a → AZ-b）    ← 主备跨 AZ 同步复制
```

代价与边界：

- 多 AZ 只防"机房级"故障，不防 Region 级故障（地震、骨干网瘫痪）。要抗 Region 级需要多 Region 异步容灾，成本和复杂度上一个数量级，通常只有核心业务做。
- 主备数据库跨 AZ 复制写延迟增加 1~2ms，对绝大多数业务无感。
- 应用必须"无状态 + 健康检查"才能被均匀打散到多 AZ，否则切换时会整体抖动。这正好和 K8s 的 `topologySpreadConstraints` 是同一套思想。

### 2.3 与 K8s 拓扑的类比

| 传统/K8s 概念 | 云上对应 |
|--------------|---------|
| node（一台物理机故障域） | AZ 内的一台宿主机 |
| `kubernetes.io/hostname` 级反亲和 | 同 AZ 内打散到不同宿主机（宿主机亲和组） |
| `topology.kubernetes.io/zone` | AZ |
| cluster（整体） | Region |
| 多 cluster / 集群联邦 | 多 Region 容灾 |

你在 CKA 里学的"Pod 打散"，与云上"ECS 分布在多 AZ"，是同一个问题在不同层级的解法。

## 3. 计费模型：按量、包年包月、预留、抢占

### 3.1 四种主要计费方式

| 计费方式 | 计价粒度 | 单价水平 | 何时收费/释放 | 典型用途 |
|---------|---------|---------|--------------|---------|
| 按量付费（Pay-As-You-Go / On-Demand） | 秒级，按小时出账 | 最高（约为包月折算价的 3~4 倍） | 释放即停止计费 | 压测、临时扩容、CI runner |
| 包年包月（Subscription / Reserved 的一种） | 月/年 | 低 | 预付，到期前不退 | 稳态长期业务 |
| 预留实例券 RI / 节省计划 SP | 承诺 1~3 年用量 | 最低（再降 30~60%） | 承诺即扣 | 长期稳定的基线容量 |
| 抢占式实例（Spot / Preemptible） | 秒级 | 最低（约为按量 10%~30%） | 随时被回收（5 分钟前通知） | 无状态、可重算任务 |

关键认知：**同一台 4C16G 的 VM，四种方式买价格差可达 10 倍，机器本身一模一样**。省钱的本质是"用确定性换折扣"——你能承诺用 3 年，厂商就能放心采购硬件。

### 3.2 抢占式实例与 K8s 的配合

Spot 实例被回收时云厂商会发出事件（如阿里云的"实例回收通知"5 分钟前到达）。在 ACK/EKS 里的标准姿势：

1. 无状态 deployment 用 Spot nodepool 打标（如 `node.kubernetes.io/spot=true`）
2. 监听回收事件（或依赖云厂商提供的 node 自动排水 controller）
3. Pod 设置 `terminationGracePeriodSeconds` + PDB，保证滚动重建不中断服务

不适合：MySQL 主库、Redis 单机、需要本地盘持久写入的任务。

### 3.3 成本视角的选型决策

```
这个负载未来 7×24 跑 1 年以上吗？
 ├─ 是 → 基线部分包年包月/RI，预留 20%~30% 弹性空间用按量
 └─ 否 → 任意时刻可中断吗？
      ├─ 是 → Spot（CI、批处理、压测 minion）
      └─ 否 → 按量付费（临时扩容、演示环境，用完立刻删）
```

记住一个数字直觉：按量跑满一个月 ≈ 包月价的 3 倍以上。**忘记删除的按量实例是账单爆炸的头号原因**，第 2 章会配费用告警。

## 4. 账号与资源组织：多账号、资源组、标签

### 4.1 为什么要多账号

单账号里测试环境和生产环境混着，一次误操作（删库、删安全组）就是事故。多账号（阿里云"资源目录 RD"/AWS Organizations）按环境或业务线拆分：

```
企业主账号（只管记账和根权限，不跑业务）
 ├── 主账号-prod        ← 生产，权限最严，双人复核
 ├── 主账号-staging     ← 预发
 ├── 主账号-dev         ← 开发，预算封顶
 └── 共享服务账号       ← 监控、镜像仓库、日志（跨账号只读共享）
```

好处：**爆炸半径隔离**（dev 的 AK 泄漏摸不到 prod）、**账单天然分账**、**配额独立**（dev 压测不会打满 prod 的 vCPU 配额）。

### 4.2 资源组与标签

账号内再分两层：

- **资源组（Resource Group / AWS 称 Resource Group，阿里云称资源组）**：创建资源时必须归属，权限可以按资源组授予（如"只让 A 团队看到支付业务的 ECS"）
- **标签（Tag）**：key-value，贴在任何资源上，是**成本分账和自动化筛选**的主要手段

最小可行标签规范（FinOps 的地基，第 3 章展开）：

| Tag Key | 示例值 | 用途 |
|---------|-------|------|
| `team` | `payment` | 成本按团队分摊 |
| `env` | `prod` / `staging` / `dev` | 区分环境，批量清理 dev |
| `service` | `order-api` | 按服务看账单 |
| `managed-by` | `terraform` | 标记 IaC 管理，防止手工改动 |

## 5. 云网络与机房网络的映射（网络功底的用武之地）

这一节是你的主场。你已经懂 VLAN、三层网关、ACL、NAT，云网络只是换了一套名词加一个"软件定义"的壳。

### 5.1 核心翻译表

| 你在机房的 | 云上对应 | 差异要点 |
|-----------|---------|---------|
| 一间独立机房（内网整体） | VPC（Virtual Private Cloud） | 逻辑隔离的私有网络，一个 CIDR 块（如 192.168.0.0/16） |
| 接入交换机 + VLAN 划分 | vSwitch（阿里云）/ Subnet（AWS） | 每个 vSwitch 是 VPC CIDR 的一个子段，且**绑定到某个 AZ** |
| 三层网关/核心交换机上的 SVI | vSwitch 的网关（云厂商托管） | 你配不了网关 IP，只能在创建时选网段 |
| 出口路由器 + 静态路由 | VPC 路由表（Route Table） | 默认有条 `0.0.0.0/0 → IGW（公网网关）`；自定义路由指向 NAT 网关/专线网关 |
| 出口 NAT 设备 | NAT Gateway（SNAT）/ EIP 绑定（DNAT） | NAT 网关按 GB 计费，比自建 NAT VM 稳定 |
| 机房入口的负载均衡器（F5/硬件 SLB） | SLB/CLB/ALB/NLB | 四层（NLB/CLB）与七层（ALB）分开的产品线 |
| 防火墙 ACL（五元组规则） | 安全组 Security Group | **作用在实例网卡上、有状态**；NACL 作用在子网上、无状态 |
| 堡垒机跳板 | 跳板机 ECS（公网层唯一入口）+ 安全组只放 22 端口 | 同思想，云上更容易标准化 |
| 专线接入运营商 | 专线接入（高速通道/Express Connect/Direct Connect） | 物理专线 + 虚拟通道（VBR/DX gateway）两层 |
| VPN 拨入内网 | IPsec VPN 网关 | 同协议，云上托管配置 |

### 5.2 三个必须扭转的机房直觉

**直觉一：交换机是自学习二层的，vSwitch 是"全连通白名单三层"**。
物理交换机接上网线就在一个广播域里互通；vSwitch 之间**默认不通**，哪怕两个子网在同 VPC——必须靠 VPC 路由表放行，而同 VPC 内系统路由默认互通，跨 VPC 则要显式建对等连接（VPC Peering）或云企业网。记住：**同 VPC 子网间默认互通；跨 VPC 默认隔离**。

**直觉二：安全组是有状态的，且规则只写"允许"**。
机房防火墙 ACL 常常要写双向规则（去程放行 80、回程放行高位端口）；安全组有状态跟踪——你放行入站 80 后，响应包自动放行，**不需要写回程规则**。且安全组默认全拒绝（deny all inbound），没有"默认允许"一说。它不是 iptables 的一条链，而是分布式部署在每台宿主机 hypervisor 网卡层的过滤（对实例表现为 iptables 规则，见实战）。

**直觉三：网关和路由你控制的是"意图"不是"转发面"**。
机房里你在交换机上敲 `ip route`，云上你在控制台上配路由表条目，真正的转发在厂商的 SDN 控制器（如基于 VXLAN/GENEVE 的 overlay）里完成。排障手段因此变化：抓包仍可用（实例内 tcpdump），但"看交换机 CAM 表"变成了"看 VPC 流日志（Flow Log）"。

### 5.3 一张对照拓扑图

```
           机房世界观                          云上世界观
   ┌─────────────────────┐            ┌──────────────────────────┐
   │  Internet           │            │  Internet                │
   │    │ 出口路由器      │            │    │ IGW(公网网关)        │
   │    │  ┌─ACL─┐       │            │    │  ┌─路由表─┐          │
   │  核心交换机(SVI网关) │   ═══>     │   VPC 192.168.0.0/16     │
   │   ├─ VLAN10 web    │            │   ├─ vSwitch A (AZ-a)     │
   │   ├─ VLAN20 app    │            │   │   192.168.10.0/24     │
   │   └─ VLAN30 db     │            │   │   192.168.20.0/24     │
   │  接入交换机×N       │            │   ├─ vSwitch B (AZ-b)     │
   │  服务器×N           │            │   │   192.168.30.0/24     │
   │  F5 负载均衡        │            │   └─ SLB + 安全组×N       │
   └─────────────────────┘            └──────────────────────────┘
```

## 实战演练

环境：任意一台装有 Docker 的 Ubuntu VM 或 kubeadm 集群的 worker 节点。目标：用本机手段"摸到"云网络的两个机制——子网划分与有状态安全组。

### 演练 1：手工做一次三层子网规划（纸面，10 分钟）

用 python3 验证把 192.168.0.0/16 切成 3 组子网（公网/应用/数据层，各 2 个 AZ）：

```bash
# [任意节点]
python3 - <<'EOF'
import ipaddress
net = ipaddress.ip_network('192.168.0.0/16')
# 按 /24 切分，取 6 个：web-az-a/web-az-b/app-az-a/app-az-b/db-az-a/db-az-b
subnets = list(net.subnets(new_prefix=24))[:6]
names = ['web-az-a','web-az-b','app-az-a','app-az-b','db-az-a','db-az-b']
for n, s in zip(names, subnets):
    print(f"{n:10s} {s}  网关建议 {s.network_address + 1}  可用 {s.num_addresses - 3}")
# 检查任意两个子网是否冲突（是否互为包含）
a, b = subnets[0], subnets[3]
print('overlap:', a.overlaps(b))
EOF
```

预期输出：6 行子网信息 + `overlap: False`。这就是第 2 章 VPC 实操和 lab 01 的 CIDR 规划基础。

### 演练 2：用 iptables 体验"有状态"安全组（5 分钟）

```bash
# [任意节点] 确认本机 8080 有个监听（没有就用 python3 起一个）
python3 -m http.server 8080 >/dev/null 2>&1 &

# 在另一台节点/本机另一个终端先验证可达（任选可达的一台做客户端）
curl -m 2 -s -o /dev/null -w '%{http_code}\n' http://<本机IP>:8080
```

现在模拟 NACL（无状态）与安全组（有状态）的差异：

```bash
# [任意节点] 模拟"只允许入站 8080"的无状态 ACL：没有回程规则时连接挂起
sudo iptables -I INPUT -p tcp --dport 8080 -j ACCEPT
sudo iptables -I INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT   # 有状态回程（安全组行为）
# 删掉回程规则，模拟纯无状态 NACL：
sudo iptables -D INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
# 此时再 curl：SYN 能到，但响应包被丢，curl 超时 —— 这就是 NACL 需要写回程规则的原因
sudo iptables -D INPUT -p tcp --dport 8080 -j ACCEPT   # 清理
kill %1
```

验证：加上 ESTABLISHED 规则时 curl 返回 200；删掉后 curl 超时（`000`）。安全组 = 内置了那条 ESTABLISHED 规则的分布式 ACL。

### 演练 3：把本机路由表读成"VPC 路由表"（3 分钟）

```bash
# [任意节点]
ip route show
# 关注 default via <网关> dev <网卡> —— 相当于 VPC 路由表里的 0.0.0.0/0 → IGW
# 关注 192.168.x.0/24 dev ... —— 相当于同 VPC 系统路由（子网互通）
```

## 常见坑

| 症状 | 原因 | 解法 |
|------|------|------|
| 两台同 VPC 不同子网的 ECS ping 不通 | 没走系统路由的场景极少见；通常是安全组没放行 ICMP 或 ECS 内 firewall（如 ufw/iptables 残留规则） | 先查安全组入方向 ICMP，再在实例内 `iptables -L -n` |
| 安全组放了 80 仍访问不通 | 实例内服务只监听 127.0.0.1；或经典网络与 VPC 混用（老账号遗留） | `ss -lntp` 确认监听 0.0.0.0；新资源一律 VPC |
| 跨 AZ 延迟居然 20ms+ | 两台机器不在同一 Region 却看成"同城" | 控制台核对 Region ID 与 AZ ID；跨 Region 流量走公网 |
| 账单突然翻倍 | 忘删的按量实例/NAT 网关处理费/跨 Region 流量 | 配费用告警（第 2 章），按量资源打 `ttl` 标签定期巡检 |
| vSwitch 里 IP 不够 | 创建时给了 /26（62 个地址），Pod/节点增长后不够 | vSwitch 网段创建后**不能改**，只能新建 vSwitch 换段——规划时留 50% 余量 |
| 多 AZ 部署了仍整体宕机 | SLB 后端只挂了单 AZ 的 ECS，或后端健康检查失败后未摘除 | 后端按 AZ 各挂一半，压测验证摘除单 AZ 流量不中断 |

## 自测

1. RDS（PaaS）上你的 MySQL 每天凌晨 3 点慢查询堆积，云厂商有责任吗？如果换成 ECS 上自建 MySQL，责任边界有什么变化？
<details><summary>答案</summary>

PaaS 下"数据库软件层"的运维（补丁、备份、高可用切换）归厂商，但**慢 SQL 本身是你的应用与数据问题**，厂商无责；你该做的是看慢日志、加索引、扩规格。换成 ECS 自建后，OS、MySQL 安装、主备复制、备份策略全部归你，厂商只保底"这台 VM 重启成功、磁盘不丢"。这正是很多团队从自建迁移到 RDS 的动机：把"数据库专家"这个岗位外包给厂商。
</details>

2. 为什么说"多 AZ 是性价比最高的容灾，多 Region 是最贵的容灾"？各举一个只能靠对方解决的故障场景。
<details><summary>答案</summary>

多 AZ 复制延迟 1~3ms、内网带宽近乎免费、架构改动小（同一个 VPC 里加 vSwitch），所以便宜；多 Region 要解决数据异步复制、DNS 切换、双写冲突，成本高。机房断电/光缆挖断 → 多 AZ 可解。Region 级骨干网故障、区域级合规要求数据异地 → 只能多 Region。地震台风这类可能同时打掉同城多 AZ 的场景也需要多 Region（所以多 AZ 常选地理上有距离的机房，但同 Region 距离有限）。
</details>

3. 你们有一批 nightly 构建的 CI runner（每晚跑 2 小时，可中断重试）和一个 7×24 的生产 API 集群，怎么组合四种计费方式最省钱？
<details><summary>答案</summary>

CI runner：Spot/抢占式实例 + 定时伸缩（晚上创建、跑完销毁），单价约为按量的 1/5~1/3，且可中断无所谓。生产 API：历史用量稳定的基线部分买包年包月或 RI/节省计划锁 3 年折扣，预留 20%~30% 容量余量用按量承接高峰（大促时再加 Spot 做 batch 型扩容）。核心是"稳定性换折扣、不确定性买弹性"。
</details>

4. 安全组和 NACL 都能过滤流量，为什么生产上通常"安全组做白名单、NACL 几乎不动"？
<details><summary>答案</summary>

安全组作用在**实例网卡**层、有状态、只支持允许规则，且可以挂给多台实例复用，粒度贴合"角色"（web-sg、db-sg）；NACL 作用在**子网**层、无状态、要编号维护顺序且必须写回程规则，规则稍多就难以维护。所以实践中安全组承担 95% 的访问控制，NACL 只在需要"整个子网一刀切"（如封禁某个恶意源网段）时使用。这和机房里"核心交换机 ACL 少而精、服务器前置防火墙细而全"是同一个分层思想。
</details>

5. 如果把 VPC 的 192.168.0.0/16 和公司机房的 192.168.0.0/16 通过专线打通，会发生什么？该怎么在设计阶段避免？
<details><summary>答案</summary>

两端同网段，路由无法收敛：路由表里 192.168.10.0/24 一边指向本地 vSwitch、一边指向专线网关，冲突或黑洞，ping 丢包看运气。设计阶段就要做**网段登记与规划**：比如公司机房统一用 10.0.0.0/8，云上 VPC 统一用 172.16.0.0/12 或从公司 IPAM 申请独立段；已建成的 VPC 只能用"云企业网 + 网段冲突时的 NAT 转换"这种别扭方案补救。这是网络工程师做云设计时最高频的"提前一美元"决策。
</details>

## 延伸阅读

- 阿里云 VPC 产品文档（网络节点与路由机制）：https://www.alibabacloud.com/help/zh/vpc/
- AWS VPC 官方文档（子网/路由表/安全组概念，与阿里云高度同构）：https://docs.aws.amazon.com/vpc/
- AWS Well-Architected Framework - Reliability Pillar（多 AZ/多 Region 设计准则）：https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/
- 阿里云抢占式实例（Spot）生命周期与事件：https://www.alibabacloud.com/help/zh/ecs/spot-instances
- FinOps Foundation（成本优化框架，第 3 章展开）：https://www.finops.org/framework/
