# 02 · 阿里云实操：把一套小业务搬上云

> 模块：14-cloud ｜ 建议时长：5 小时（含开通资源） ｜ 关联认证：CKA-网络 / PCA-告警（费用告警一节） ｜ 前置：第 01 章

## 学习目标

- 能用 aliyun CLI 完成"VPC → vSwitch → 安全组 → ECS → SLB → RDS → OSS"的完整建站链路，而不是只在控制台点按钮
- 能说出阿里云 VPC/安全组/SLB 与第 01 章机房概念的逐项映射
- 能为 CI 与同事创建 RAM 子账号并按最小权限授权（自定义策略 JSON）
- 能配置可用额度预警 + 自建费用巡检脚本，防止按量资源跑飞账单

## 1. CLI 开通与配置

### 1.1 安装 aliyun CLI

```bash
# [任意节点] Ubuntu 22.04/24.04
curl -sSL -o /tmp/aliyun-cli.tgz https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz
tar -xzf /tmp/aliyun-cli.tgz -C /tmp
sudo cp /tmp/aliyun /usr/local/bin/ && sudo chmod +x /usr/local/bin/aliyun
aliyun version
sudo apt-get install -y jq   # 后文解析 JSON 用
```

Windows 端可下载 `aliyun-cli-windows-latest-amd64.zip` 解压后把 `aliyun.exe` 放入 PATH（同上官方下载页）。

### 1.2 准备一个 RAM 子账号的 AK（不要用主账号 AK）

控制台路径：RAM 访问控制 → 用户 → 创建用户（勾选 "OpenAPI 调用"）→ 为其附加系统策略 `AliyunECSFullAccess`、`AliyunVPCFullAccess`（练习用，生产要收紧到自定义策略，见第 7 节）→ 创建 AccessKey（**Secret 只显示一次**）。

```bash
# [任意节点] 配置凭证，AK 换成你自己的
aliyun configure set --profile demo --mode AK --region cn-hangzhou \
  --access-key-id <你的AccessKeyId> --access-key-secret <你的AccessKeySecret>
aliyun configure list
```

日常用 `--profile demo` 切换多套身份；所有命令通用形态是 `aliyun <产品> <Action> --参数 值`，输出 JSON。加 `--dryrun` 只看请求不发（部分 Action 支持）。

## 2. VPC 组网：交换机、路由表、安全组

### 2.1 建三件套

沿用第 01 章的映射：VPC=机房、vSwitch=交换机/VLAN、安全组=网卡 ACL。

```bash
# [任意节点] 建 VPC 与两个 AZ 的 vSwitch
VPC_ID=$(aliyun vpc CreateVpc --RegionId cn-hangzhou --CidrBlock 192.168.0.0/16 \
  --VpcName demo-vpc --Description "lab vpc" | jq -r .VpcId)
echo "VPC_ID=$VPC_ID"

VSW_A=$(aliyun vpc CreateVswitch --VpcId $VPC_ID --ZoneId cn-hangzhou-a \
  --CidrBlock 192.168.10.0/24 --VSwitchName web-a | jq -r .VSwitchId)
VSW_B=$(aliyun vpc CreateVswitch --VpcId $VPC_ID --ZoneId cn-hangzhou-i \
  --CidrBlock 192.168.20.0/24 --VSwitchName app-b | jq -r .VSwitchId)
echo "VSW_A=$VSW_A  VSW_B=$VSW_B"
```

查系统路由表（对照第 01 章"VPC 路由表"概念）：

```bash
# [任意节点]
aliyun vpc DescribeRouteTables --VRouterId $(aliyun vpc DescribeVpcs --VpcId $VPC_ID | jq -r '.Vpcs.Vpc[0].VRouterId') \
  | jq -r '.RouteTables.RouteTable[0].RouteEntries.RouteEntry[] | [.DestinationCidrBlock, .NextHopType, .Type] | @tsv'
# 预期两条系统路由：192.168.0.0/16(本地) 与 0.0.0.0/0(IGW，若 VPC 开了公网网关能力)
```

### 2.2 安全组：白名单式、有状态

```bash
# [任意节点] 建安全组：web 层放 80/443/22，db 层只放 3306 来自 app 段
SG_WEB=$(aliyun ecs CreateSecurityGroup --RegionId cn-hangzhou --VpcId $VPC_ID \
  --SecurityGroupName sg-web --Description "web tier" | jq -r .SecurityGroupId)
SG_DB=$(aliyun ecs CreateSecurityGroup --RegionId cn-hangzhou --VpcId $VPC_ID \
  --SecurityGroupName sg-db --Description "db tier" | jq -r .SecurityGroupId)

aliyun ecs AuthorizeSecurityGroup --SecurityGroupId $SG_WEB --RegionId cn-hangzhou \
  --IpProtocol tcp --PortRange 80/80 --SourceCidrIp 0.0.0.0/0 --Priority 1 --Description "http"
aliyun ecs AuthorizeSecurityGroup --SecurityGroupId $SG_WEB --RegionId cn-hangzhou \
  --IpProtocol tcp --PortRange 443/443 --SourceCidrIp 0.0.0.0/0 --Priority 1 --Description "https"
aliyun ecs AuthorizeSecurityGroup --SecurityGroupId $SG_WEB --RegionId cn-hangzhou \
  --IpProtocol tcp --PortRange 22/22 --SourceCidrIp $(curl -s https://ifconfig.me)/32 --Priority 1 --Description "ssh from office"
aliyun ecs AuthorizeSecurityGroup --SecurityGroupId $SG_DB --RegionId cn-hangzhou \
  --IpProtocol tcp --PortRange 3306/3306 --SourceCidrIp 192.168.0.0/16 --Priority 1 --Description "mysql from vpc"

aliyun ecs DescribeSecurityGroupAttribute --SecurityGroupId $SG_WEB --RegionId cn-hangzhou --Direction all \
  | jq -r '.Permissions.Permission[] | [.IpProtocol, .PortRange, .SourceCidrIp, .Description] | @tsv'
```

要点（对照第 01 章直觉二）：只写"允许"，回程由状态跟踪自动放行；22 端口收敛到办公网出口 IP 而不是 `0.0.0.0/0`。

## 3. ECS：创建、登录、执行命令

```bash
# [任意节点] 查一个当前可用的 Ubuntu 22.04 镜像 ID
IMAGE=$(aliyun ecs DescribeImages --RegionId cn-hangzhou --ImageOwnerAlias system \
  --OSType linux --PageSize 100 --fetch-all \
  | jq -r '.Images.Image[] | select(.ImageName|test("ubuntu_22")) | .ImageId' | head -1)
echo "IMAGE=$IMAGE"

# [任意节点] 在两个 AZ 各起一台（按量付费，用完即删）
INS_IDS=$(aliyun ecs RunInstances --RegionId cn-hangzhou --ImageId $IMAGE \
  --InstanceType ecs.e-c1m2.large --SecurityGroupId $SG_WEB --VSwitchId $VSW_A \
  --InstanceName demo-web-a --HostName demo-web-a --Password 'Lab@ECs001' \
  --InstanceChargeType PostPaid --SystemDisk.Category cloud_essd --SystemDisk.Size 40 \
  --InternetMaxBandwidthOut 5 --Amount 1 | jq -r '.InstanceIdSets.InstanceIdSet[]')
INS_ID_B=$(aliyun ecs RunInstances --RegionId cn-hangzhou --ImageId $IMAGE \
  --InstanceType ecs.e-c1m2.large --SecurityGroupId $SG_WEB --VSwitchId $VSW_B \
  --InstanceName demo-web-b --HostName demo-web-b --Password 'Lab@ECs001' \
  --InstanceChargeType PostPaid --SystemDisk.Category cloud_essd --SystemDisk.Size 40 \
  --InternetMaxBandwidthOut 5 --Amount 1 | jq -r '.InstanceIdSets.InstanceIdSet[]')
echo "INS_IDS=$INS_IDS $INS_ID_B"

# [任意节点] 等待 Running 并列出公/私网 IP
for i in $(seq 1 30); do
  ST=$(aliyun ecs DescribeInstanceStatus --RegionId cn-hangzhou --InstanceId.1 $INS_IDS | jq -r '.InstanceStatuses.InstanceStatus[0].Status')
  [ "$ST" = "Running" ] && break; sleep 5
done
aliyun ecs DescribeInstances --RegionId cn-hangzhou --InstanceName demo-web \
  | jq -r '.Instances.Instance[] | [.InstanceId, .Status, (.PublicIpAddress.IpAddress[0] // "-"), .VpcAttributes.PrivateIpAddress.IpAddress[0]] | @tsv'
```

`InternetMaxBandwidthOut 5` 会让按量实例自动分配一个公网 IP（按流量计费）。SSH 登录 `ssh root@<公网IP>`（密码 `Lab@ECs001`，练习环境用后即改）。

### 云助手：不进机器也能执行命令

相当于给每台 ECS 预装了一个"跳板上的 ansible"：

```bash
# [任意节点] 在两台实例上装 nginx（云助手 RunCommand，幂等地重复执行）
CMD_ID=$(aliyun ecs RunCommand --RegionId cn-hangzhou --Type RunShellScript \
  --CommandContent 'apt-get update -qq && apt-get install -y -qq nginx && systemctl enable --now nginx' \
  --TimeoutPeriod 300 --InstanceId.1 $INS_IDS --InstanceId.2 $INS_ID_B | jq -r .CommandId)
aliyun ecs DescribeInvocations --RegionId cn-hangzhou --CommandId $CMD_ID \
  | jq -r '.Invocations.Invocation[].InvocationResults.InvocationResult[] | [.InstanceId, .InvocationStatus] | @tsv'
```

## 4. SLB：把两台 ECS 挂到负载均衡后端

```bash
# [任意节点] 建一个公网四层+七层混用的 CLB（原 SLB）
LB_ID=$(aliyun slb CreateLoadBalancer --RegionId cn-hangzhou --LoadBalancerName demo-slb \
  --AddressType internet --InternetChargeType paybytraffic --Bandwidth 10 | jq -r .LoadBalancerId)
echo "LB_ID=$LB_ID  地址稍后由 DescribeLoadBalancers 查询"

# [任意节点] 创建后端服务器组（vServerGroup）
VSG_ID=$(aliyun slb CreateVServerGroup --LoadBalancerId $LB_ID --VServerGroupName web-group \
  --BackendServers "[{\"ServerId\":\"$INS_IDS\",\"Weight\":100,\"Port\":80,\"Type\":\"ecs\"},{\"ServerId\":\"$INS_ID_B\",\"Weight\":100,\"Port\":80,\"Type\":\"ecs\"}]" \
  | jq -r .VServerGroupId)

# [任意节点] 建 80 监听并启动（HTTP 监听强制开健康检查）
aliyun slb CreateLoadBalancerHTTPListener --LoadBalancerId $LB_ID --ListenerPort 80 \
  --VServerGroupId $VSG_ID --HealthCheck on --HealthCheckURI / --HealthCheckTimeout 5 \
  --HealthCheckInterval 10 --HealthyThreshold 3 --UnhealthyThreshold 3
aliyun slb StartLoadBalancerListener --LoadBalancerId $LB_ID --ListenerPort 80

# [任意节点] 取 SLB 公网 IP 并验证
LB_IP=$(aliyun slb DescribeLoadBalancers --RegionId cn-hangzhou --LoadBalancerId $LB_ID | jq -r '.LoadBalancers.LoadBalancer[0].Address')
for i in 1 2 3; do curl -s -o /dev/null -w "attempt$i: %{http_code}\n" http://$LB_IP/; done
```

三次都应返回 200；在两台 ECS 上分别 `echo "<主机名>" > /var/www/html/index.html`（可用云助手），再多次 curl 能看到内容轮换——这就是"负载均衡 + 无状态"的最小验证。

## 5. OSS：对象存储当"无限大网盘"

```bash
# [任意节点] bucket 名全局唯一，加个自己的后缀
BUCKET=demo-hub-$(date +%s)
aliyun oss mb oss://$BUCKET --endpoint oss-cn-hangzhou.aliyuncs.com
aliyun oss cp /etc/hostname oss://$BUCKET/lab/ --endpoint oss-cn-hangzhou.aliyuncs.com
aliyun oss ls oss://$BUCKET/lab/ --endpoint oss-cn-hangzhou.aliyuncs.com
aliyun oss stat oss://$BUCKET/lab/hostname --endpoint oss-cn-hangzhou.aliyuncs.com | head -5
aliyun oss rm oss://$BUCKET/lab/hostname --endpoint oss-cn-hangzhou.aliyuncs.com
aliyun oss rm oss://$BUCKET/ --endpoint oss-cn-hangzhou.aliyuncs.com -rf   # 清空并删 bucket（练习收尾用）
```

运维视角三个记忆点：OSS 是 **HTTP REST 存取**（不是块设备，不能 `mount` 当磁盘用，要当磁盘用得选 NAS/云盘）；**bucket 私有 + 签名 URL 临时授权**是安全基线；**跨 Region 复制和公网下行流量都收费**，备份放同 Region 的另一个 bucket 最便宜。

## 6. RDS：托管 MySQL

```bash
# [任意节点] 创建按量付费的 MySQL 8.0（规格/存储以售卖页为准）
DB_ID=$(aliyun rds CreateDBInstance --RegionId cn-hangzhou --Engine MySQL --EngineVersion 8.0 \
  --DBInstanceClass mysql.n2.medium.1 --DBInstanceStorage 40 --DBInstanceNetType Intranet \
  --VPCId $VPC_ID --VSwitchId $VSW_A --PayType Postpaid --DBInstanceDescription demo-db | jq -r .DBInstanceId)
echo "DB_ID=$DB_ID"

# [任意节点] RDS 创建要几分钟，轮询到 Running
for i in $(seq 1 60); do
  ST=$(aliyun rds DescribeDBInstances --RegionId cn-hangzhou --DBInstanceId $DB_ID | jq -r '.Items.DBInstance[0].DBInstanceStatus')
  echo "rds status: $ST"; [ "$ST" = "Running" ] && break; sleep 10
done

# [任意节点] 建库、建账号并授权
aliyun rds CreateAccount --DBInstanceId $DB_ID --AccountName appuser --AccountPassword 'Db@Lab002' --AccountType Normal
aliyun rds CreateDatabase --DBInstanceId $DB_ID --DBName orders --CharacterSetName utf8mb4 \
  --AccountName appuser --AccountPrivilege ReadWrite

# [任意节点] 取内网连接串（ECS 同 VPC 内可达，公网默认不通=天然安全）
CONN=$(aliyun rds DescribeDBInstanceNetInfo --DBInstanceId $DB_ID | jq -r '.DBInstanceNetInfos.DBInstanceNetInfo[0].ConnectionString')
echo "conn=$CONN  # 在 ECS 上: mysql -h $CONN -u appuser -p"
```

与自建 MySQL 的排障差异：没有 root 超级权限与主机 SSH，`super` 级参数（如 `innodb_buffer_pool_size`）改用控制台参数模板；备份/主备切换/慢日志采集都产品化。你在 11-middleware/MySQL 章里学的 `SHOW PROCESSLIST`、慢日志分析照样适用。

## 7. RAM 权限体系：最小权限落地

### 7.1 概念速览

| 概念 | 是什么 | 类比 |
|------|--------|------|
| 主账号 | root，AK 泄漏=灾难 | Linux root |
| RAM 用户 | 长期子账号（人/程序） | 普通用户 |
| RAM 角色 | 临时凭证，可被assume | sudo -u / STS token |
| 策略 Policy | JSON 权限声明 | iptables 规则集 |
| 用户组 | 用户的集合，策略挂组 | Unix group |

### 7.2 给 CI 建一个"只能读写某个 bucket"的身份

```bash
# [任意节点] 1) 建用户并生成 AK
aliyun ram CreateUser --UserName ci-deployer --DisplayName "CI deployer" --Comments "gitlab-ci only"
aliyun ram CreateAccessKey --UserName ci-deployer   # 输出的 Secret 立刻存入密码管理器

# 2) 写自定义策略（最小权限：仅这个 bucket）
cat > /tmp/oss-one-bucket.json <<'EOF'
{
  "Version": "1",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["oss:ListBuckets", "oss:GetBucketInfo"],
      "Resource": "acs:oss:*:*:*"
    },
    {
      "Effect": "Allow",
      "Action": ["oss:PutObject", "oss:GetObject", "oss:DeleteObject", "oss:ListObjects"],
      "Resource": ["acs:oss:*:*:demo-hub-*", "acs:oss:*:*:demo-hub-*/*"]
    }
  ]
}
EOF
aliyun ram CreatePolicy --PolicyName oss-ci-one-bucket --PolicyDocument file:///tmp/oss-one-bucket.json

# 3) 挂到用户
aliyun ram AttachPolicyToUser --PolicyType Custom --PolicyName oss-ci-one-bucket --UserName ci-deployer

# 4) 验证：用该 AK 建新 profile，尝试列出 ECS（应被拒绝）
aliyun configure set --profile ci --mode AK --region cn-hangzhou \
  --access-key-id <ci的AK> --access-key-secret <ci的Secret>
aliyun ecs DescribeInstances --profile ci   # 预期 Forbidden.RAM 错误
```

策略结构记住三层：`Effect`(Allow/Deny) + `Action`(产品:动作) + `Resource`(acs:产品:Region:账号ID:资源)，Deny 永远压过 Allow。

## 8. ACK 容器服务：k8s 的云上形态

ACK = 厂商托管控制面（apiserver/etcd/scheduler 由阿里云维护）+ 你管理的 nodepool。你 CKA 学的东西全部适用，多出来的三件事：

1. **网络选型**：Flannel（简单，Pod 网段与 VPC 无关）或 **Terway**（Pod 直接占用 VPC 内 vSwitch 的 ENI/IP，网络性能好、能与 VPC 内 RDS/ECS 互做安全组）。生产建议 Terway。
2. **节点池分层**：常态节点用包年包月，弹性节点池用抢占式实例 + `kubectl drain` 自动化，对应第 01 章计费组合。
3. **对接方式**：拿 kubeconfig 后一切照旧。

```bash
# [任意节点] 已在控制台创建 ACK 集群（Basic 版无集群管理费、Pro 版按量，以官网为准）后：
CLUSTER_ID=c-xxxxxxx   # 控制台 ACK 列表页可见
aliyun cs DescribeClusterUserKubeconfig --ClusterId $CLUSTER_ID | jq -r .config > /tmp/ack-kubeconfig
KUBECONFIG=/tmp/ack-kubeconfig kubectl get nodes -o wide
KUBECONFIG=/tmp/ack-kubeconfig kubectl get pods -A | head
```

安全组在 ACK 里的角色：node 的安全组决定了 Pod（Terway 模式下直接是 ENI）的入站能力；如果你发现 Service NodePort 外部不通，第一嫌疑就是 node 安全组没放行 30000-32767——这正是第 01 章"安全组=网卡 ACL"映射的直接应用。

## 实战演练：费用告警两层防线

**第一层（控制台，5 分钟）**：费用中心 → 预算管理 → 创建预算 → 月度预算填入你的额度，勾选"实际消费达到 80% 告警"，接收人填自己。同时开启"可用额度预警"。

**第二层（自建巡检脚本）**：放一台常开的 Ubuntu 上每天跑，把余额推到 webhook（演示用飞书/钉钉群机器人格式）：

```bash
# [任意节点] sudo tee /usr/local/bin/aliyun-balance-watch.sh
#!/usr/bin/env bash
set -u
THRESHOLD="${1:-100}"          # 告警阈值（元），用法: aliyun-balance-watch.sh 100
WEBHOOK="${ALERT_WEBHOOK:-}"   # 可选：飞书群机器人地址
BAL=$(aliyun bssopenapi QueryAccountBalance --profile demo | jq -r '.Data.AvailableAmount')
TS=$(date '+%F %T')
if awk -v b="$BAL" -v t="$THRESHOLD" 'BEGIN{exit !(b<t)}'; then
  echo "$TS ALERT available_amount=${BAL}CNY < ${THRESHOLD}CNY"
  [ -n "$WEBHOOK" ] && curl -s -X POST -H 'Content-Type: application/json' \
    -d "{\"msg_type\":\"text\",\"content\":{\"text\":\"阿里云余额告警: ${BAL} 元，低于阈值 ${THRESHOLD}\"}}" "$WEBHOOK"
else
  echo "$TS OK available_amount=${BAL}CNY"
fi

# [任意节点] 加 cron：每天 09:05 检查
# (crontab -l 2>/dev/null; echo '5 9 * * * /usr/local/bin/aliyun-balance-watch.sh 100 >> /var/log/aliyun-balance.log 2>&1') | crontab -
```

按量资源的清尾习惯：给临时资源打 `ttl=2h` 标签 + `--InstanceName demo-*` 统一前缀，收工时一条命令销毁：

```bash
# [任意节点] 练习收尾：删除本章创建的所有按量资源（顺序：SLB→ECS→RDS→安全组→vSwitch→VPC→OSS）
aliyun slb DeleteLoadBalancer --LoadBalancerId $LB_ID
aliyun ecs DeleteInstance --InstanceId $INS_IDS --Force true
aliyun ecs DeleteInstance --InstanceId $INS_ID_B --Force true
aliyun rds DeleteDBInstance --DBInstanceId $DB_ID
aliyun ecs DeleteSecurityGroup --SecurityGroupId $SG_WEB --RegionId cn-hangzhou
aliyun ecs DeleteSecurityGroup --SecurityGroupId $SG_DB --RegionId cn-hangzhou
aliyun vpc DeleteVswitch --VSwitchId $VSW_A && aliyun vpc DeleteVswitch --VSwitchId $VSW_B
aliyun vpc DeleteVpc --VpcId $VPC_ID
```

## 常见坑

| 症状 | 原因 | 解法 |
|------|------|------|
| CLI 报 `InvalidAccessKeyId.NotFound` | AK 输错或用户被禁用 | `aliyun configure list` 检查 profile；RAM 控制台确认用户状态 |
| RunInstances 报 `InvalidZoneId.NotFound` | 该 AZ 无此规格库存 | 换 AZ（如 -a→-i）或换 InstanceType；`aliyun ecs DescribeAvailableResource` 可查 |
| CreateVswitch 报 `InvalidVpcScope` | 子网 CIDR 不在 VPC 网段内或与已有 vSwitch 重叠 | 对照第 01 章演练 1 用 python3 预先算好不重叠段 |
| SLB 健康检查一直 failed | 后端安全组没放行 100.64.0.0/10（健康检查源网段）或服务只听 127.0.0.1 | 安全组入方向放行 `tcp 80 from 100.64.0.0/10`；`ss -lntp` 确认 0.0.0.0 监听 |
| ECS 公网通、RDS 连不上 | RDS 默认无公网地址（Intranet） | 练习用同 VPC 的 ECS 连；要公网需显式 Apply 公网连接串并加白名单 |
| 删除 VPC 失败 `DependencyViolation` | 还有 vSwitch/安全组/实例没删 | 先删 ECS/RDS/SLB 再删安全组和 vSwitch，最后删 VPC |
| 删 bucket 失败 | bucket 非空 | `aliyun oss rm oss://bucket/ -rf` 先清空（注意不可恢复） |
| ACK NodePort 外部不通 | node 安全组未放行 30000-32767 | 给 node 安全组加 `tcp 30000/32767 from 0.0.0.0/0`（或收敛到 SLB 网段） |

## 自测

1. 为什么安全组放行了 80 端口，SLB 后端健康检查还是失败？给出至少两个排查点。
<details><summary>答案</summary>

排查点：a) 健康检查流量来自 100.64.0.0/10 保留网段，安全组若只放行了 0.0.0.0/0 的 80 通常没问题，但若配成了特定网段就会拦截——需显式放行该段；b) 后端 nginx 只监听 127.0.0.1；c) 健康检查 URI 配置错误（如配了 /healthz 但应用没有该路径）返回 404 被判失败；d) vServerGroup 里 Port 与实际监听端口不一致。顺序：`ss -lntp` → 查健康检查配置 → 查安全组。
</details>

2. 同 VPC 两个 vSwitch 里的 ECS 互通靠什么？如果换成两个不同 VPC，默认还能通吗？
<details><summary>答案</summary>

同 VPC 靠系统路由表里 VPC 大段指向本地的条目，配合默认互通策略，无需配置。不同 VPC 默认完全隔离（即使网段不重叠），必须建 VPC Peering 连接或加入云企业网 CEN 并配路由，再由安全组放行。这印证第 01 章"同 VPC 默认互通、跨 VPC 默认隔离"。
</details>

3. 你在 RAM 里给了 CI 一个 `AliyunOSSFullAccess`，后来 AK 泄漏，最坏损失是什么？如何把爆炸半径缩到最小？
<details><summary>答案</summary>

FullAccess 意味着可以删除账号下**所有** bucket 的所有对象（含生产备份），甚至改 bucket ACL 公开。缩小办法：自定义策略限定到单个 bucket 的 ARN（`acs:oss:*:*:name`）；AK 定期轮换；更彻底的是不用长期 AK，改用 RAM 角色 + STS 临时凭证（15 分钟~12 小时过期）。
</details>

4. 按量 ECS `StopInstance` 之后账单还涨吗？怎么做才真正省钱？
<details><summary>答案</summary>

涨。按量实例停止后仍计算计算资源费（vCPU/内存），只有**释放（DeleteInstance/AutoRelease）**才停止计费；若是"节省停机模式"则不再收计算费只收磁盘费，但实例规格不再保留。真正省钱：临时任务用完即删、配自动释放时间（`--AutoReleaseTime`）、Spot 跑可中断负载、长期负载转包月。
</details>

5. ACK 里选 Terway 而不是 Flannel，对你这个网络背景的人意味着什么？
<details><summary>答案</summary>

Terway 下 Pod 网络直接使用 VPC 的 ENI/辅助 IP，Pod IP 是 VPC 内"真 IP"：安全组可以直接作用于 Pod、RDS 白名单可以精确到 Pod 网段、VPC FlowLog 能看到 Pod 级流量、性能少一层 overlay 封装。Flannel 是 VXLAN overlay，Pod IP 与 VPC 无关，一切跨平面访问都要过 node 的 SNAT。你已经懂 ENI 和 overlay，Terway 相当于"把 K8s 网络平面合并进 VPC"，排障时可以直接用 VPC 工具链。
</details>

## 延伸阅读

- aliyun CLI 官方文档（安装/配置/file:// 用法）：https://www.alibabacloud.com/help/zh/cli/
- VPC 操作指南（vSwitch/路由表/安全组最佳实践）：https://www.alibabacloud.com/help/zh/vpc/
- SLB/CLB 健康检查原理（含 100.64.0.0/10 说明）：https://www.alibabacloud.com/help/zh/slb/
- RAM 策略语言（Policy 语法与 Deny 优先）：https://www.alibabacloud.com/help/zh/ram/
- ACK 网络方案（Terway 与 Flannel 对比）：https://www.alibabacloud.com/help/zh/ack/
- 费用中心预算与可用额度预警：https://www.alibabacloud.com/help/zh/cost-management/
