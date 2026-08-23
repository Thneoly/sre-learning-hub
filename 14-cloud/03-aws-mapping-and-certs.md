# 03 · AWS 对照与认证：一套技能、两朵云

> 模块：14-cloud ｜ 建议时长：4 小时 ｜ 关联认证：AWS SAA / 阿里云 ACP / CKA+CKS（云原生叠加） ｜ 前置：第 01、02 章

## 学习目标

- 能在 EC2/VPC/ELB/S3/RDS/EKS/IAM 与 ECS/VPC/SLB/OSS/RDS/ACK/RAM 之间双向翻译，拿到其中一家的方案能立刻说出另一家的等价形态
- 能说出两家在 CLI 风格、计费、认证体系上的实质差异（不只是名字不同）
- 能规划"CKA/CKS/PCA + 一朵云的架构师认证"的组合路径并制定 4 周备考计划
- 能落地 FinOps 三板斧：标签分账、闲置资源清理、Spot/RI 组合采购

## 1. 概念对照总表

你已经会用阿里云的语汇，下面这张表是"字典"。先纵读一遍，后面小节挑差异大的展开。

| 领域 | 阿里云 | AWS | 备注 |
|------|--------|-----|------|
| 虚拟机 | ECS | EC2 | 规格族命名不同：ecs.g7.xlarge ≈ m5.xlarge（通用型 4C16G） |
| 私有网络 | VPC | VPC | 概念完全同构 |
| 子网 | vSwitch | Subnet | AWS Subnet 必须绑定单 AZ，vSwitch 也是 |
| 有状态网卡 ACL | Security Group | Security Group | 都默认拒绝、只写 allow |
| 无状态子网 ACL | 网络 ACL | Network ACL | 都要写回程规则 |
| 弹性公网 IP | EIP | Elastic IP | AWS 的 EIP 现在与实例绑定与否均计费（策略以官网为准） |
| SNAT 出口 | NAT 网关 | NAT Gateway | 都按 GB 收处理费，都是账单刺客 |
| 四层 LB | NLB / CLB | Network Load Balancer | CLB 为老一代，兼容经典网络 |
| 七层 LB | ALB | Application Load Balancer | ALB 按LCU计费，规则/路由能力强 |
| 对象存储 | OSS | S3 | API 高度相似（签名版本不同） |
| 块存储 | 云盘 ESSD | EBS | ESSD PL0~PL3 ≈ gp3~io2 的分层 |
| 文件存储 | NAS | EFS | 都支持 NFS |
| 托管关系库 | RDS / PolarDB | RDS / Aurora | PolarDB 与 Aurora 同为"云原生分离架构"竞品 |
| 缓存 | Tair / Redis 版 | ElastiCache | — |
| K8s 托管 | ACK | EKS | ACK Basic 免集群费，EKS 控制面按小时计费（约 $0.10/h） |
| Serverless 容器 | ECI / ASK / SAE | Fargate | 不管 node，按 Pod 计费 |
| 身份权限 | RAM | IAM | 阿里云"RAM 角色"/AWS"IAM Role"同概念 |
| 多账号组织 | 资源目录 RD | Organizations | 都有 SCP/管控策略 |
| 监控 | 云监控 Cloud Monitor | CloudWatch | 采集→指标→告警→dashboard 四件套同构 |
| IaC | ROS / Terraform | CloudFormation / Terraform | 两家都被 Terraform 支持 |
| 运维代理 | 云助手 | SSM（Run Command/Session Manager） | Session Manager 可替代 SSH 免开 22 端口 |
| 计费 API | BSS OpenAPI | Cost Explorer API / CUR | CUR=成本使用报告，分账报表的原始数据 |

### 1.1 CLI 风格差异

```text
阿里云（RPC 风格，PascalCase 参数）           AWS（REST+JSON，kebab-case 参数）
aliyun ecs RunInstances \                     aws ec2 run-instances \
  --InstanceType ecs.e-c1m2.large \             --instance-type t3.medium \
  --SecurityGroupId sg-xxx \                    --security-group-ids sg-xxx \
  --VSwitchId vsw-xxx                           --subnet-id subnet-xxx
```

记忆法：阿里云是"动词+大驼峰"（`DescribeInstances`、`CreateVswitch`），AWS 是"名词短语+连字符"（`describe-instances`、`create-subnet`）。AWS 输出默认 YAML（加 `--output json` 改 JSON），阿里云默认 JSON。

### 1.2 术语避坑

- "账号"：AWS 说 account（12 位数字 ID），阿里云说主账号/UID，RAM/IAM 里的"用户"都是子账号。
- "Region 命名"：`cn-hangzhou` vs `ap-northeast-1`，同一城市东京是 `ap-northeast-1`（AWS）/`ap-northeast-1`（阿里云，命名规则一致但前缀体系不同），抄 Region ID 时别混用两家文档。
- "VPC 内 DNS"：AWS VPC 有 enableDnsSupport/enableDnsHostnames 两个开关，阿里云对应 VPC 的 DNS 相关属性，跨云迁移时自建服务发现的解析行为要先验证。

## 2. EKS vs ACK：你 CKA 技能的跨云迁移

控制面都是厂商管，你管 node 与工作负载。差异集中在三处：

| 维度 | ACK | EKS |
|------|-----|-----|
| Pod 网络 | Flannel 或 **Terway**（ENI 直通 VPC） | **AWS VPC CNI**（ENI 直通，默认只有这种） |
| 节点管理 | 节点池 NodePool + 自动伸缩 | 托管节点组 Managed Node Group + ASG |
| Pod 级 IAM | **RRSA**（RAM Roles for Service Accounts） | **IRSA**（IAM Roles for Service Accounts） |

VPC CNI/Terway 的含义你已经懂：Pod IP 就是 VPC 里的 IP，安全组、流日志、RDS 白名单都能落到 Pod 粒度。代价是 Pod 密度受 ENI/IP 配额限制（一个 c5.xlarge 的 ENI 辅助 IP 数量有限），大规模集群要规划 secondary CIDR 或用 egress 优化方案。

IRSA/RRSA 的含义：把"某个 ServiceAccount 的 Pod"映射为一个云角色，Pod 内 SDK 自动拿到临时凭证——不再需要把 AK 塞进 Secret。这是 CKS 思维在云上的延伸：**凭证的作用域缩到 SA 级**。写法对照：

```yaml
# [任意节点] 两家共用同一段 workload 定义，只有注解不同
apiVersion: v1
kind: ServiceAccount
metadata:
  name: oss-reader
  namespace: demo
  annotations:
    # 阿里云 RRSA
    alibabacloud.com/role-name: arn:acs:ram::1234567890:role/oss-reader
    # AWS IRSA（EKS 上由 eksctl 自动生成信任关系）
    # eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/s3-reader
```

## 3. 认证路径与考试策略

> 认证的题型、分数线、价格随时调整，报名前一律以官网为准：AWS https://aws.amazon.com/certification/ ；阿里云 https://edu.aliyun.com/certification/ 。

### 3.1 两家的体系层级

| 层级 | 阿里云 | AWS |
|------|--------|-----|
| 入门 | ACA（助理工程师） | Cloud Practitioner（CLF） |
| 中级（主力） | **ACP**（高级工程师：云计算/云安全/云原生等方向） | **SAA**（Solutions Architect – Associate）、DVA、DEA 等多个 Associate |
| 高级 | **ACE**（架构师/专家，含面试环节） | Professional：SAP（架构师 Pro）、DOP（DevOps Pro） |
| 特定领域 | ACP 云安全等方向 | Specialty：Security、Networking、Data 等 |

### 3.2 给你的组合建议（网络/运维背景 + CKA/CKS/PCA 在手）

```
国内路线：CKA → CKS → PCA → ACP 云计算/云原生 → ACE（要项目积累，缓）
海外/外企：CKA → CKS → SAA → （安全岗再加 AWS Security Specialty）
SRE 平台岗：CKA + SAA/ACP + Terraform 实操 > 刷更多证
```

理由：CKA/CKS 证明你会 K8s 本体，ACP/SAA 证明你懂"K8s 跑在云上"的那半圈（VPC、IAM、成本）。两者叠加正好是"云原生 SRE"简历的完整拼图，比连刷多朵云的同类认证性价比高。

### 3.3 SAA 备考要点（4 周计划）

SAA 的题干是场景题："某公司要……要求**最省成本/最高可用/最小改动**的方案"。考察的不是背参数，而是方案权衡。高频权重（按新考纲，以官方 exam guide 为准）：安全合规、高可用与多 AZ/多 Region 设计、存储选型（S3 族/EBS 族）、网络（VPC endpoints、PrivateLink、Direct Connect vs VPN）、成本优化（Spot/RI/Savings Plans/生命周期策略）。

| 周 | 内容 |
|----|------|
| 1 | 官方 Exam Guide + Skill Builder 免费数字课程过一遍；建免费账号把第 2 章映射操作在 AWS 上重做（用免费层：1 个 t3.micro、1 个 VPC） |
| 2 | 专题突破：VPC/子网/安全组/NAT/endpoint 画图默写；S3 存储类与生命周期；EC2 计费四件套 |
| 3 | 刷题（每题四个选项都要说出"为什么不选另外三个"）；错题归档成"权衡矩阵" |
| 4 | 模拟考 ×2（计时 130 分钟）；复习错题矩阵；预约考试 |

答题口诀：看到 "cost-effective" 优先想 managed/serverless/Spot；看到 "highly available" 必须跨 AZ；看到 "least operational overhead" 优先托管服务而不是自建；看到 "most secure" 优先最小权限 + 私网 + 加密选项。**排除法比直选法可靠**：两个选项技术上都对时，选更贴合题干限定词的那个。

### 3.4 ACP 备考要点

ACP 中文考试，风格与 AWS 明显不同：更贴产品功能细节（控制台字段、API 行为、配额默认值），多选题比重大。策略：以官方认证课程 + 官方产品文档为纲（VPC/ECS/SLB/OSS/RDS/RAM 六条线），把第 02 章的实操命令各敲一遍比背题库有效。ACE 在 ACP 之上加架构设计与答辩，建议有 1~2 个真实上云项目再考。

## 4. FinOps：成本优化三板斧

FinOps 的闭环是 **Inform（看得见）→ Optimize（优化）→ Operate（制度化）**。三板斧对应前两步：

### 4.1 标签分账（Inform）

没有标签，一切成本优化都是玄学。最小标签集（第 01 章 4.2 的三件套）+ 落地动作：

```bash
# [任意节点] 阿里云：给已有 ECS 打标签（team/env/service）
aliyun ecs TagResources --RegionId cn-hangzhou --ResourceType instance \
  --ResourceId.1 i-xxxx --Tag.1.Key team --Tag.1.Value payment \
  --Tag.2.Key env --Tag.2.Value prod
# 控制台"费用中心 → 分账"启用标签分账后，账单才能按标签维度出报表

# [任意节点] AWS：同样动作 + 必须先在 Billing 激活用户标签为"成本分配标签"（约 24h 生效）
aws ec2 create-tags --resources i-xxxxxxxxx --tags Key=team,Value=payment Key=env,Value=prod
aws ce get-cost-and-usage --time-period Start=2026-08-01,End=2026-09-01 --granularity MONTHLY \
  --metrics "UnblendedCost" --group-by Type=TAG,Key=team
```

制度化手段：**标签不齐 = 不允许创建**。用 Terraform 的 `validation` 块或云厂商的"不合规即拒绝"策略（阿里云资源目录管控策略 / AWS SCP + Tag Policy）兜底。

### 4.2 闲置资源清理（Optimize）

账单里最常见的"白花钱"清单，按出现频率排序：

| 资源 | 症状 | 清理动作 |
|------|------|---------|
| 未挂载云盘/EBS | 实例删了盘没删 | `aliyun ecs DescribeDisks --Status Available`；`aws ec2 describe-volumes --filters Name=status,Values=available` |
| 未绑定的 EIP | 实例删了 IP 没释放 | 两家都按"持有但未绑定"计费 |
| 快照/AMR 老备份 | 快照只增不减 | 设置保留策略，定期删除超期快照 |
| 空转的低负载 ECS/EC2 | CPU 平均 <5% 持续 2 周 | 降配（resize）或改按需启动 |
| NAT 网关处理费 | 大流量走 NAT 去同云服务 | 改走 VPC endpoint / 私网地址 |
| 超大规格的 dev 库 | dev 用 prod 同规格 | dev 库降配 + 定时启停 |

巡检脚本骨架（阿里云版，AWS 换 CLI 即可，逻辑同构）：

```bash
# [任意节点] /usr/local/bin/aliyun-idle-scan.sh —— 只读巡检，输出可清理清单
#!/usr/bin/env bash
set -u
R=cn-hangzhou
echo "== 未挂载云盘 =="
aliyun ecs DescribeDisks --RegionId $R --Status Available --PageSize 100 \
  | jq -r '.Disks.Disk[] | [.DiskId, .DiskName, .Size, (.Tags.Tag|map(.Value)|join("/"))] | @tsv'
echo "== 未绑定 EIP =="
aliyun vpc DescribeEipAddresses --RegionId $R --Status Available \
  | jq -r '.EipAddresses.EipAddress[] | [.AllocationId, .IpAddress] | @tsv'
echo "== 低 CPU 实例（最近 7 天平均，需云监控权限）=="
for ID in $(aliyun ecs DescribeInstances --RegionId $R --InstanceName demo- --PageSize 100 \
            | jq -r '.Instances.Instance[].InstanceId'); do
  AVG=$(aliyun cms QueryMetricLast --Project acs_ecs_dashboard --Metric CPUUtil_Average \
        --Period 604800 --StartTime "$(date -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
        --EndTime "$(date +%Y-%m-%dT%H:%M:%SZ)" --Dimensions "{\"instanceId\":\"$ID\"}" \
        2>/dev/null | jq -r '.Datapoints[0].Average // "n/a"')
  echo -e "$ID\tCPU平均(7d): $AVG"
done
```

### 4.3 采购组合（Optimize）

沿用第 01 章 3.3 的决策树，落到数字上的常用组合：

- 基线（7×24 稳定负载）：包年包月 / RI / Savings Plans，折扣 30%~60%
- 弹性高峰：按量 + 自动伸缩（ESS/ASG），峰值结束自动缩容
- 可中断批处理/CI：Spot（约按量 1~5 折），必须配"中断兜底"：检查点续跑或 K8s 多副本打散
- 存储分层：S3/OSS 生命周期规则把 30 天以上日志自动转低频/归档，单价降一个量级

一个务实的目标：**每季度把"单位业务成本"降 5%~10%**（如每千次订单 API 成本），而不是追求绝对最低。

## 实战演练：用 LocalStack 在本机"摸"AWS

没有 AWS 账号也能把第 2 章的操作在 AWS 语法下重做一遍——LocalStack 在本机 Docker 里模拟 AWS API（社区版覆盖 EC2/VPC/S3/IAM 核心 API，行为与真云略有差异，但命令语法完全一致，迁移到真云只改 endpoint）。

```bash
# [任意节点] 1) 安装 aws cli v2
curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
(cd /tmp && unzip -q -o awscliv2.zip && sudo /tmp/aws/install)
aws --version

# 2) 起 LocalStack 并配置假凭证（LocalStack 不校验，任意值即可）
docker run -d --name localstack -p 4566:4566 localstack/localstack:latest
aws configure set aws_access_key_id test
aws configure set aws_secret_access_key test
aws configure set region ap-southeast-1
export AWS_ENDPOINT=http://localhost:4566
```

把第 02 章的阿里云命令逐条翻译成 AWS（感受 1.1 的风格差异）：

```bash
# [任意节点] VPC + 子网 + 安全组（对照：CreateVpc/CreateVswitch/CreateSecurityGroup）
VPC_ID=$(aws --endpoint-url=$AWS_ENDPOINT ec2 create-vpc \
  --cidr-block 192.168.0.0/16 --tag-specifications 'ResourceType=vpc,Tags=[{Key=Name,Value=demo-vpc}]' \
  | jq -r .Vpc.VpcId)
SUBNET_ID=$(aws --endpoint-url=$AWS_ENDPOINT ec2 create-subnet --vpc-id $VPC_ID \
  --cidr-block 192.168.10.0/24 --availability-zone ap-southeast-1a | jq -r .Subnet.SubnetId)
SG_ID=$(aws --endpoint-url=$AWS_ENDPOINT ec2 create-security-group --group-name sg-web \
  --description "web tier" --vpc-id $VPC_ID | jq -r .GroupId)
aws --endpoint-url=$AWS_ENDPOINT ec2 authorize-security-group-ingress --group-id $SG_ID \
  --protocol tcp --port 80 --cidr 0.0.0.0/0

# [任意节点] 起一台 EC2（对照：RunInstances，AMI 用假 ID 即可，LocalStack 会模拟状态）
INS_ID=$(aws --endpoint-url=$AWS_ENDPOINT ec2 run-instances --image-id ami-000000000001 \
  --count 1 --instance-type t3.medium --subnet-id $SUBNET_ID --security-group-ids $SG_ID \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=env,Value=dev}]' \
  | jq -r '.Instances[0].InstanceId')
aws --endpoint-url=$AWS_ENDPOINT ec2 describe-instances --instance-ids $INS_ID \
  | jq -r '.Reservations[0].Instances[0] | [.InstanceId, .State.Name, .PrivateIpAddress] | @tsv'

# [任意节点] S3 与 IAM（对照：oss mb/cp、CreateUser/AttachPolicyToUser）
aws --endpoint-url=$AWS_ENDPOINT s3 mb s3://demo-hub-local
aws --endpoint-url=$AWS_ENDPOINT s3 cp /etc/hostname s3://demo-hub-local/lab/
aws --endpoint-url=$AWS_ENDPOINT s3 ls s3://demo-hub-local/lab/
cat > /tmp/one-bucket.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:GetObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::demo-hub-local", "arn:aws:s3:::demo-hub-local/*"]
    }
  ]
}
EOF
aws --endpoint-url=$AWS_ENDPOINT iam create-user --user-name ci-deployer
POLICY_ARN=$(aws --endpoint-url=$AWS_ENDPOINT iam create-policy --policy-name one-bucket \
  --policy-document file:///tmp/one-bucket.json | jq -r .Policy.Arn)
aws --endpoint-url=$AWS_ENDPOINT iam attach-user-policy --user-name ci-deployer --policy-arn $POLICY_ARN
aws --endpoint-url=$AWS_ENDPOINT iam list-attached-user-policies --user-name ci-deployer

# [任意节点] 收尾
docker rm -f localstack
```

验证点：`s3 ls` 能列出上传的 hostname；`list-attached-user-policies` 显示 one-bucket。做完这节，你已经在语义层面"双云双语"了——面试问"这两家云有什么区别"时，你有的是亲手对照过的细节（参数风格、默认输出格式、IAM 策略的 Version 差异：`2012-10-17` vs `1`）。

## 常见坑

| 症状 | 原因 | 解法 |
|------|------|------|
| `aws` 命令报 `Unable to locate credentials` | 没配 `aws configure` 或用了错误的 profile | `aws configure list` 检查；多账号用 `--profile` |
| LocalStack 里 EC2 一直 pending | 社区版只模拟状态机部分行为 | 属预期，用 `describe-instances` 看状态即可；真云验证再走免费层 |
| AWS 账单里出现 "NAT Gateway-Bytes" 大额 | 同云服务流量走了 NAT 公网绕行 | 加 VPC endpoint（S3/DynamoDB 等）走内网 |
| 成本标签报表里看不到自己的 Tag | 用户标签未激活为成本分配标签（AWS 需手动激活且延迟约 24h；阿里云需在分账设置里启用） | Billing → Cost allocation tags → Activate |
| SAA 刷题正确率高但模考差 | 刷题记答案，场景题换皮就错 | 每题强制写"三个错误选项为什么错"；按考纲域做弱项统计 |
| ACP 考试遇到大量控制台细节题 | 只看视频没上手 | 按第 02 章把 VPC/ECS/SLB/OSS/RDS/RAM 各实操一遍 |
| Spot 节点上的任务莫名消失 | Spot 被回收且任务无检查点 | 任务加 checkpoint；K8s 里配 PDB + 多副本跨 node 打散 |

## 自测

1. 同样是"Pod 拿到云凭证"，把 AK 写进 Secret 与 IRSA/RRSA 的本质区别是什么？为什么后者是 CKS 思维的延伸？
<details><summary>答案</summary>

Secret 里的 AK 是长期有效的静态凭证，任何能读 Secret 的人/工作负载（包括被攻破的镜像里的进程）都能拿走并在任意地方使用，作用域=整个 RAM 用户/IAM 用户。IRSA/RRSA 通过 OIDC 信任把"某个 ServiceAccount 下的 Pod"映射为角色，SDK 拿到的是**短期自动轮换的 STS 凭证**，作用域=SA 级、时间窗有限。这正是 CKS 里"最小权限+凭证生命周期"原则在云上的实现，也顺带满足了审计要求（谁在何时用了哪个角色有 trace）。
</details>

2. 为什么 AWS VPC CNI 的集群里，一个 t3.medium（3 ENI，每 ENI 6 IP）能跑的 Pod 数量有上限？ack Terway 是否同样受限？
<details><summary>答案</summary>

VPC CNI 给每个 Pod 分配 ENI 上的辅助 IP：可用 Pod 数 ≈ (ENI 数 × 每 ENI IP 数) − 主网卡占用 ≈ 3×6−几个保留 ≈ 17 个左右，再想加密度的 Pod 就要 secondary CIDR/前缀委托等手段。Terway 默认也走 ENI/IP 模式受类似配额约束，但提供 vSwitch 共享模式（Pod 与 ECS 共享 IP 池）等变体缓解。根源是"Pod IP 是 VPC 真 IP"这一设计的代价——这正是第 01 章说的"云网络是白名单三层的"，IP 是受管配额资源。
</details>

3. 题干同时出现 "most cost-effective" 与 "highly available"，两个方案一个单 AZ 一个多 AZ，怎么选？
<details><summary>答案</summary>

选多 AZ。SAA 题干的限定词有优先级：安全/可用性类硬性要求通常是业务约束（不满足=错误方案），成本是满足约束后的优化目标。"最省钱的可用方案"而不是"最便宜的方案"。反过来如果题干只说 cost-effective 且没提可用性，单 AZ/Spot/更小规格就是正解。练习时把错题按"限定词→排除逻辑"整理，比记题答案有效。
</details>

4. 你们月账单 10 万，CTO 要求降 20%。给出你的排查顺序和最容易见效的三刀。
<details><summary>答案</summary>

顺序：先 Inform——拉 3 个月分维度账单（按产品/按标签/按账号），找到 top5 大头；再对每块做"要不要、要不要这个规格、要不要这个价格模式"三问。最容易的三刀：a) 闲置清理（未挂载盘/未绑定 EIP/超期快照/dev 空转实例），零风险立竿见影；b) 长期稳定负载转包月/RI/SP，纯采购动作省 30%+；c) 网络费治理（NAT 换 VPC endpoint、跨 Region 复制收敛、OSS 生命周期分层）。存储和流量优化见效比压计算资源更稳，因为不影响业务性能。
</details>

5. 一家国内公司同时用阿里云（主站）和 AWS（海外），你作为唯一 SRE 怎么设计标签与账号体系，避免双云治理两套皮？
<details><summary>答案</summary>

统一元数据规范：同一套标签键值（team/env/service/managed-by）写进两家的 Tag Policy/管控策略；账号结构对齐（阿里云资源目录与 AWS Organizations 的 OU 一一对应：prod/staging/dev/共享服务）；基础设施全部 Terraform 化，module 双云共享变量（环境名、网段规划）只换 provider；分账报表落到同一个数据仓（比如各自导出到自建 ClickHouse/Grafana）统一看板。原则：**治理层（账号/标签/IaC/成本）统一，执行层（各家 API）分治**。
</details>

## 延伸阅读

- AWS Certification 官方（考纲、样题、Skill Builder）：https://aws.amazon.com/certification/
- 阿里云认证（ACA/ACP/ACE 大纲与报名）：https://edu.aliyun.com/certification/
- AWS VPC 官方文档（与阿里云 VPC 对照阅读）：https://docs.aws.amazon.com/vpc/
- EKS 网络与 IRSA：https://docs.aws.amazon.com/eks/latest/userguide/pod-networking.html
- AWS Cost Explorer 与成本分配标签：https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/cost-alloc-tags.html
- FinOps Framework（Inform/Optimize/Operate）：https://www.finops.org/framework/
- LocalStack（本机模拟 AWS API）：https://docs.localstack.cloud/
