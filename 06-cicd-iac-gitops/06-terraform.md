# 06 · Terraform：有状态的资源编排

> 模块：06-cicd-iac-gitops ｜ 建议时长：5 小时 ｜ 关联认证：—（无直接考点，云上 IaC 标配，与 Ansible 搭配构成资源/配置双引擎）

## 学习目标

- 能解释 IaC 的"期望状态 / state / 真实资源"三角关系，说明 state 为什么必须存在且必须保护
- 能读写 HCL：provider / resource / variable / output / locals，理解 plan→apply 生命周期
- 能操作远程 Backend（以阿里云 OSS 为例）实现 state 共享与加锁，并做漂移检测
- 能组织 module 化工程，理解 `terraform import` 与 import block 导入存量资源的流程
- 能根据"Ansible 管配置 / Terraform 管资源"分工表为一家公司设计工具边界

## 1. IaC 与状态理念：三角模型

Terraform 的世界里永远有三个东西：

```
   期望状态(你的 .tf 代码)          真实资源(云上)
        │    ▲                        ▲   │
        │    │ plan 读差异             │   │ apply 改资源
        ▼    │                        │   ▼
      ┌──────────────┐  refresh(刷新) ─┘
      │  state 文件   │ ────────────▶ 记录"我上次建成什么样、资源 ID 是什么"
      └──────────────┘
```

- **state 是代码与资源之间的账本**：云资源创建后返回 ID（实例 ID、VPC ID），Terraform 把 ID 与代码里的资源名对上，下次才能精确更新而不是重建
- **plan = 读 state + 刷新真实状态 + 与代码比对**，输出"将要做什么"；**apply = 按 plan 执行**
- 没有 state（如 Ansible）：每次都是"我宣告期望，工具自己看现状"——对配置可行，对付费云资源不行：不知道"哪个 VPC 是我的"，就只能重复创建
- 推论一：**state 丢了 = 失联**（资源还在但管不了，只能 import 回来）；推论二：**state 里有明文敏感值**（数据库密码等），必须当密钥保管

## 2. HCL 语法骨架

```hcl
# [文件 main.tf] HCL = 块(类型 "标签") { 参数 = 值 }
terraform {                          # terraform 块：版本与 provider 声明
  required_version = ">= 1.6.0"
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"    # 命名空间/名称，从 Registry 拉取
      version = "~> 1.235"           # 允许 1.235.x，锁主版本防破坏性变更
    }
  }
}

provider "alicloud" {                # provider 块：跟哪家云对话
  region = var.region                # 凭据从环境变量 ALICLOUD_ACCESS_KEY /
}                                    #   ALICLOUD_SECRET_KEY 读取，绝不写进代码

variable "region" {                  # variable：输入参数
  type        = string
  default     = "cn-hangzhou"
  description = "部署区域"
}

variable "vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

locals {                             # locals：本地计算的中间变量
  name_prefix = "tf-demo"
}

resource "alicloud_vpc" "main" {     # resource "类型" "本工程内名字"
  vpc_name   = "${local.name_prefix}-vpc"
  cidr_block = var.vpc_cidr          # 引用变量
}

output "vpc_id" {                    # output：暴露给别人/CI 读取的值
  value = alicloud_vpc.main.id       # 引用资源属性
}
```

引用语法速记：`var.x`（变量）、`local.x`（locals）、`资源类型.名字.属性`（资源属性）、`module.名字.输出`（模块输出）。

## 3. state 语义与远程 Backend

state 默认是本地 `terraform.tfstate`（JSON），团队协作必须搬远程：**共享 + 加锁 + 版本化**。阿里云方案是 OSS + Tablestore：

```hcl
# [文件 backend.tf] 远程 Backend（需先在控制台开好 OSS bucket 与 Tablestore 实例）
terraform {
  backend "oss" {
    bucket = "my-company-tfstate"     # 存 state 的 bucket
    prefix = "demo/networking"        # 对象前缀，按工程/目录隔离
    region = "cn-hangzhou"
    table  = "my-tflock-table"        # Tablestore 表：apply 期间加锁，防并发写坏 state
  }
}
```

字段以官方 backend 文档为准（<https://developer.hashicorp.com/terraform/language/backend/oss>）。工程纪律：

- `terraform init` 时通过 `terraform init -backend-config=backend.hcl` 或命令行传凭据，避免 AK 写死在 backend.tf
- **任何人不得在本地模式下 apply 生产**：锁定协作规则 + bucket 权限 + CI 唯一入口
- state 的历史版本靠 bucket 版本控制兜底（误 apply 后可回滚 state，但更推荐靠代码回滚再 apply）
- 同理适用 AWS（`backend "s3"` + DynamoDB 锁）、自建（consul/http，自担风险）

## 4. 生命周期：init → plan → apply → destroy

```bash
# [任意Ubuntu] 安装：版本号用官网 releases 页的最新稳定版替换（下方为示例占位，勿照抄旧号）
#   https://developer.hashicorp.com/terraform/downloads  ← 查当前版本
VER=<填入当前最新稳定版，如 1.x.y>
curl -fsSL -o /tmp/terraform.zip \
  "https://releases.hashicorp.com/terraform/${VER}/terraform_${VER}_linux_amd64.zip"
sudo apt-get install -y unzip && unzip -d /usr/local/bin /tmp/terraform.zip
terraform -version
# 国内网络慢可走代理或镜像；OpenTofu 用户把 URL 换成
#   https://github.com/opentofu/opentofu/releases（语法与 Terraform 兼容，见下方许可证小节）
```

### 许可证与 OpenTofu：选型前该知道的行业事实

- 2023 年 HashiCorp 把 Terraform 从 MPL 2.0 改为 **BUSL 1.1**（非 OSI 开源许可，对与 HashiCorp 竞争的厂商有限制），社区随即在 Linux 基金会下分叉出 **OpenTofu**（CNCF 托管，MPL 2.0）；
- 2025 年 **IBM 完成收购 HashiCorp**，Terraform 继续作为商业核心产品演进；
- 两者 HCL 语法与 provider 生态高度兼容（`terraform` 与 `tofu` 命令可互换大部分场景），OpenTofu 还先行实现了部分社区特性（如 state 加密）；
- **选型建议**：个人学习用哪个都行（本教程命令两者通用）；企业选型看法务对 BUSL 的接受度与供应链策略——这本身就是面试里"IaC 工具选型"的高频考点。

| 命令 | 作用 | 工程习惯 |
|---|---|---|
| `terraform init` | 下载 provider、配置 backend | 换 backend/provider 后必须重跑 |
| `terraform validate` | 本地语法检查 | 不联网，CI 第一道门 |
| `terraform fmt -check` | 格式检查 | 提交前 `terraform fmt` |
| `terraform plan` | 计算差异并展示 | **apply 前必看**，重点盯 `~` 与 `-/+`（会重建） |
| `terraform apply` | 执行（可加 `-auto-approve`，CI 用） | apply 前会再 plan 一次要求确认 |
| `terraform destroy` | 按 state 全量删除 | 生产慎用；先 `plan -destroy` 预览 |
| `terraform state list` | 列出 state 里的资源 | 排查"到底管了什么" |
| `terraform output` | 打印输出 | CI 里传给下游（如 VPC ID 给 Ansible） |

plan 输出的三种动作符号：`+` 新建、`~` 原地更新、`-/+` 与 `-` 删除重建/删除。**看到 `-/+` 一定想清楚**：改了不可更新字段（如 VPC 的 cidr_block、ECS 换镜像）就是重建，生产上等于先删后建。

## 5. 漂移检测：state 说的和云上不一致

漂移（drift）= 有人绕过 Terraform 在控制台手改了资源。检测手段：

```bash
# [任意Ubuntu]
terraform plan -detailed-exitcode
# exit 0 = 无差异（代码=state=真实）
# exit 2 = 有差异（漂移或待_apply 的变更）
# exit 1 = 出错
# CI 里 nightly 跑一次，exit 2 即告警——"有人手改生产"
```

处置原则：能改回代码的把控制台变更"收编"进 .tf 再 apply；不该存在的手改，直接 apply 让 Terraform 改回去。**严禁**为了消除告警手改 state。`terraform plan -refresh-only` 可以只刷新 state 不动资源，适合先看清现场。

## 6. 模块化

module = 带输入输出的目录，把"一套 VPC + 交换机 + 安全组"封装成可复用积木：

```
live/                         # 使用方
├── prod/
│   └── main.tf               # module "net" { source = "../../modules/vpc" ... }
└── test/
    └── main.tf
modules/
└── vpc/
    ├── main.tf               # variables.tf（输入）/ outputs.tf（输出）/ versions.tf
    ├── variables.tf
    └── outputs.tf
```

```hcl
# [文件 live/prod/main.tf] 调模块
module "net" {
  source      = "../../modules/vpc"      # 本地路径；Registry 模块写 "registry.terraform.io/..."
  cidr        = "10.20.0.0/16"
  name_prefix = "prod"
}

resource "alicloud_security_group" "web" {
  name   = "prod-web-sg"
  vpc_id = module.net.vpc_id             # 模块输出接入下游
}
```

规矩：模块只通过 variables/outputs 对外交互（不要反向引用调用方的资源）；源用 Registry 或 git tag 固定版本（`ref=v1.2.0`）；`live/` 每个环境独立 state，天然隔离爆炸半径。

## 7. 阿里云 provider 完整示例

```hcl
# [文件 main.tf] 网络三件套：VPC + 交换机 + 安全组
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    alicloud = {
      source  = "aliyun/alicloud"
      version = "~> 1.235"
    }
  }
}

variable "region" {
  type    = string
  default = "cn-hangzhou"
}

variable "vpc_cidr" {
  type    = string
  default = "10.10.0.0/16"
}

provider "alicloud" {
  region = var.region
}

resource "alicloud_vpc" "main" {
  vpc_name   = "tf-demo-vpc"
  cidr_block = var.vpc_cidr
}

resource "alicloud_vswitch" "az_a" {
  vpc_id       = alicloud_vpc.main.id
  zone_id      = "cn-hangzhou-i"
  cidr_block   = cidrsubnet(var.vpc_cidr, 8, 1)   # 内置函数：切出 10.10.1.0/24
  vswitch_name = "tf-demo-vsw-a"
}

resource "alicloud_security_group" "web" {
  name   = "tf-demo-sg"
  vpc_id = alicloud_vpc.main.id
}

resource "alicloud_security_group_rule" "allow_http" {
  type              = "ingress"
  ip_protocol       = "tcp"
  port_range        = "80/80"
  security_group_id = alicloud_security_group.web.id
  cidr_ip           = "0.0.0.0/0"
}

output "vpc_id" {
  value = alicloud_vpc.main.id
}

output "vswitch_id" {
  value = alicloud_vswitch.az_a.id
}
```

```bash
# [任意Ubuntu] 凭据走环境变量（子账号只授目标资源权限，遵循最小权限）
export ALICLOUD_ACCESS_KEY="<你的AccessKeyId>"
export ALICLOUD_SECRET_KEY="<你的AccessKeySecret>"

terraform init          # 拉 alicloud provider（Registry 国内可直连）
terraform plan
terraform apply         # 输出 vpc_id / vswitch_id
terraform destroy       # 实验完回收，避免留计费资源
```

## 8. 导入存量资源

公司早就有手工开好的 VPC/数据库，Terraform 要"接盘"而不是推倒重来：

```bash
# [任意Ubuntu] 方式一：CLI import——资源先进 state，代码要自己补齐对齐
terraform import alicloud_vpc.main vpc-0xi9kxxxx
terraform plan          # 此时会显示大量 diff：说明代码与真实配置还没对齐
# 手工把属性补进 resource 块，直到 plan 无差异，收编完成
```

```hcl
# [文件 imports.tf] 方式二（1.5+）：import block——先写代码再 plan 生成绑定
import {
  to = alicloud_vpc.main
  id = "vpc-0xi9kxxxx"
}
# terraform plan 会给出"建议的 resource 块"，确认后 apply 完成导入
```

流程本质是**让代码、state、真实三者对齐**，diff 归零才算导入完成。大批量接盘按资源类型分批做，先非核心后核心。

## 9. Ansible 管配置 / Terraform 管资源：分工表

| 维度 | Terraform | Ansible |
|---|---|---|
| 管什么 | 云资源：VPC/ECS/RDS/安全组/K8s 集群 | OS 与应用层：装包、改配置、起服务、发布 |
| 执行模型 | 有状态：plan 先算差异再 apply | 无状态：每轮现看现状，靠模块幂等 |
| 删除语义 | `destroy` 可精确整栈回收 | 默认不删（要写 task 显式删） |
| 并发防护 | backend 锁，天然串行化 apply | 无内建锁（forks 并行执行任务） |
| 变更节奏 | 低频（网络/算力拓扑） | 高频（配置迭代、发版） |
| 失败影响 | 资源半建（靠重跑收敛） | 配置半推（靠幂等重跑收敛） |
| 典型联动 | 产出 VPC ID、节点 IP | `terraform output` 接进 inventory 继续配机器 |

一句话选型：**Terraform 造机房（买机器搭网络），Ansible 装机房（配机器上的东西）**；顺序上 Terraform 先行，其 output 动态生成 Ansible inventory，流水线里 `terraform apply → 生成 inventory → ansible-playbook` 是最常见的企业组合。

## 实战演练：离线跑通完整生命周期（local provider）

不花钱不动云，用 `hashicorp/local` 在本机体验 state/plan/apply/漂移全流程。

```hcl
# [文件 main.tf] 目录 ~/tf-lab
terraform {
  required_version = ">= 1.6.0"
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

variable "env_name" {
  type    = string
  default = "test"
}

locals {
  content = "environment: ${var.env_name}\nmanaged-by: terraform\n"
}

resource "local_file" "env_cfg" {
  content  = local.content
  filename = "${path.module}/out/env-${var.env_name}.yaml"
}

output "config_path" {
  value = local_file.env_cfg.filename
}
```

```bash
# [任意Ubuntu]
mkdir -p ~/tf-lab && cd ~/tf-lab          # 放入上面 main.tf
terraform init                            # 从 Registry 拉 local provider
terraform validate                        # Success! The configuration is valid.

terraform plan
# OpenTofu/Terraform will perform the following actions:
#   + local_file.env_cfg will be created
terraform apply -auto-approve
# Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
cat out/env-test.yaml                     # environment: test ...
terraform state list                      # local_file.env_cfg

# —— 漂移实验：手工"手改生产" ——
rm out/env-test.yaml
terraform plan -detailed-exitcode; echo "exit=$?"
# 显示 -/+ (local_file.env_cfg 会重建)，exit=2 —— 这就是漂移检测
terraform apply -auto-approve             # 收编：重新写回，回到一致

# —— 变量实验 ——
terraform apply -auto-approve -var env_name=prod
ls out/                                   # env-prod.yaml 与 env-test.yaml 并存（两次资源）

terraform destroy -auto-approve           # 全部回收
```

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| plan 显示 `-/+` 资源要重建 | 改了不可更新字段（cidr、镜像、可用区） | 评估停机影响；能换字段就换，必须重建就分批迁移 |
| 多人同时 apply，state 报锁 | 本地 backend 无锁 / 未等锁释放 | 上远程 backend（OSS/S3 带锁）；确认无人 apply 后 `terraform force-unlock <id>`（慎用） |
| state 里有数据库明文密码 | state 明文存储敏感属性 | state 文件按密文管理；敏感值用变量注入、标记 `sensitive = true`（只隐藏输出不加密 state） |
| apply 后 AK 泄露在 CI 日志 | 凭据写进了代码或 backend 配置 | 环境变量/CI secrets 注入；`.gitignore` 掉 `*.tfvars` 敏感文件与 `.terraform/` |
| `terraform init` 拉 provider 超时 | Registry 访问慢 | 配置镜像源（`terraform init -plugin-dir` 离线包，或企业自建镜像），来源要可信 |
| 换了 provider 版本后 plan 巨变 | 未锁版本，新版本改了默认行为 | `required_providers` 锁 `~> x.y`；提交 `.terraform.lock.hcl` |
| import 后 plan 一堆 diff | 只导入了 state，代码没对齐属性 | 按真实属性补齐 resource 块至 diff 归零 |
| `Error: Acquiring state lock` 卡死后不敢动 | 上次 apply 异常退出未释放锁 | `terraform force-unlock` 前，先确认没有 apply 在跑 |

## 自测

<details><summary>1. 为什么 Ansible 可以没有 state 而 Terraform 必须有？从"资源有 ID 且要花钱"推导。</summary>

Ansible 的对象是操作系统现状：每次连接现查（服务起没起、文件在不在），期望与现实可直接比对，比对结果无需留档。Terraform 的对象是云端资源：创建后获得全局唯一 ID，且创建/销毁既花钱又有副作用——必须有个账本记录"代码里的 alicloud_vpc.main 就是云上的 vpc-0xi9kxxx"，否则下次只能重复创建。state 本质是把"名字到 ID 的映射 + 上次的属性快照"持久化，让增量更新成为可能。
</details>

<details><summary>2. plan 和 apply 之间有人改了云资源，apply 执行的是谁的意图？这个缝隙说明什么工程要求？</summary>

apply 默认会先重新 refresh + 生成新 plan 再执行（除非用保存的 plan 文件），所以执行的是"apply 时刻的新计算结果"，可能与你看过的那份 plan 不同——缝隙意味着"看 plan 的那个人"和"按 apply 的人"之间没有强一致保证。工程要求：CI 中用 `terraform plan -out=tfplan` 固化计划再 `terraform apply tfplan`（保证所见即所执行），同时 backend 锁保证同一时刻只有一条流水线在操作。
</details>

<details><summary>3. 误删了 terraform.tfstate 且无备份，代码还在。资源怎么办？这个过程暴露了什么风险？</summary>

资源仍在云上正常计费运行，但 Terraform 失去映射。恢复路径：对每个资源写 import block（或 CLI import）把 ID 重新绑回 state，再补齐属性到 diff 归零。暴露的风险：state 是单点，必须远程 backend + 对象存储版本化 + 限制写权限；同时说明"代码即真相"并不完整——没有 state 配合，代码无法直接对上存量资源。
</details>

<details><summary>4. nightly 的 terraform plan -detailed-exitcode 返回 2，但你确定没人改代码也没人动云。还有哪些可能原因？</summary>

典型：provider 版本未锁导致默认行为变化（升级后字段计算方式变了）；云厂商 API 返回的属性出现抖动（如一些只在控制台可见的默认项）；模块上游 tag 被移动；还有真实漂移——别人在控制台改了。排查顺序：看 plan 的具体 diff 内容 → 锁 provider 版本重跑 → 若是厂商默认值类字段用 `lifecycle { ignore_changes = [...] }` 显式忽略并注释原因。
</details>

<details><summary>5. 公司既有 300 台手工开的 ECS 又想上 Terraform，且应用配置目前靠人 SSH 改。给出迁移与分工方案。</summary>

分工：Terraform 管"造机器"（VPC/安全组/ECS/磁盘），Ansible 管"配机器"（系统调优、装 agent、发应用），Terraform output 生成 Ansible inventory。迁移：新资源直接 Terraform 创建；存量 300 台分批 import（先非核心业务），用 import block + plan 建议补齐代码；应用配置层先用 Ansible 跑一遍"现状收编"（把手工状态固化为 playbook），再谈规范化。节奏上冻结"手工开机器"的口子（RAM 权限收归 CI 服务账号）比工具选型更关键——否则漂移永远治理不完。
</details>

## 延伸阅读

- Terraform 官方文档（HCL 语言）：<https://developer.hashicorp.com/terraform/language>
- 阿里云 provider：<https://registry.terraform.io/providers/aliyun/alicloud/latest/docs>
- OSS backend：<https://developer.hashicorp.com/terraform/language/backend/oss>
- import 与 import block：<https://developer.hashicorp.com/terraform/cli/import>
