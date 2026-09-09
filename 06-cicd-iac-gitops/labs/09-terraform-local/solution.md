# Lab 09 · 解答：Terraform local provider 全流程

> 配套 task.md 使用。环境：candidate VM（Ubuntu，terraform ≥1.6 已装）。第 06 章实战演练用单个 `local_file` 演示过 plan/apply/漂移的最小闭环；本 lab 把它扩展成可判分的完整演练：3 个资源、tfvars+workspace 双环境、漂移与 taint 的存档证据。全程无云凭据。

## 第 0 步：理解设计

```
 期望状态 main.tf（变量驱动 3 个文件）          真实资源：out/<env>/ 下的文件
        │    ▲                                        ▲   │
        │    │ plan 读差异（refresh 后比对）            │   │ apply 写文件
        ▼    │                                        │   ▼
      ┌──────────────────────────────────────────────────────┐
      │  state：terraform.tfstate.d/<workspace>/terraform.tfstate │
      │  （每个 workspace 一本账，dev 与 prod 互不可见）          │
      └──────────────────────────────────────────────────────┘
 漂移 = 有人 rm 了 out/dev/motd.txt（绕过 Terraform 改"生产"）
 taint = 人为把 runbook 标记为坏，强制下轮 apply 重建
```

第 06 章第 1 节的三角模型在本地文件上照样成立——这正是选 local provider 做内训的原因：语义一分不差，成本为零。

## 第 1 步：main.tf 与 init

```bash
# [VM]
mkdir -p ~/labs/terraform-local/artifacts && cd ~/labs/terraform-local
```

```hcl
# 文件: ~/labs/terraform-local/main.tf
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
  type        = string
  default     = "dev"
  description = "环境名，决定输出目录与环境语义"
}

variable "log_level" {
  type    = string
  default = "info"
}

variable "replica_hint" {
  type    = number
  default = 1
  description = "写入 env.yaml 的容量提示（呼应 kustomize overlay 的 replicas 差异）"
}

variable "maintainer" {
  type    = string
  default = "sre-team"
}

locals {
  out_dir  = "${path.module}/out/${var.env_name}"
  env_body = "environment: ${var.env_name}\nlog_level: ${var.log_level}\nreplica_hint: ${var.replica_hint}\nmanaged-by: terraform\n"
}

resource "local_file" "env_cfg" {
  content  = local.env_body
  filename = "${local.out_dir}/env.yaml"
}

resource "local_file" "motd" {
  content  = "welcome to ${var.env_name}, maintained by ${var.maintainer}\n"
  filename = "${local.out_dir}/motd.txt"
}

resource "local_file" "runbook" {
  content  = <<-EOT
    # runbook for ${var.env_name}
    log_level: ${var.log_level}
    replica_hint: ${var.replica_hint}
    漂移处理：terraform plan 发现差异（+ 或 -/+）先确认是否人为改动，再 apply 收编；严禁手改 state。
  EOT
  filename = "${local.out_dir}/runbook.md"
}

output "out_dir" {
  value = local.out_dir
}
```

注意：**不要**把 `filemd5()` 写进根 output 去引用被管理的文件——漂移实验删文件的那一步，plan 阶段求值 `filemd5(<不存在的文件>)` 会直接报错，把本该显示的漂移计划炸掉。filemd5 的用法见第 4 步（terraform console 手动取值）。

```bash
# [VM] init（provider 走 Registry；慢则挂代理）
export HTTPS_PROXY=http://172.30.30.1:7897
terraform init
unset HTTPS_PROXY
terraform validate
# 预期：Success! The configuration is valid.
```

## 第 2 步：首次 apply 与 state 观察

```bash
# [VM] 先在 default workspace 用 dev.tfvars 之外的默认值跑首轮（此时还没建 workspace）
terraform plan | grep -E 'local_file\.|# '
# 预期：3 个 + local_file.env_cfg / motd / runbook will be created
terraform apply -auto-approve
# 预期：Apply complete! Resources: 3 added, 0 changed, 0 destroyed.
ls out/dev/          # 预期：env.yaml  motd.txt  runbook.md（env_name 默认 dev）

terraform state list | tee artifacts/state-list.txt
# 预期（存档内容）：
# local_file.env_cfg
# local_file.motd
# local_file.runbook
terraform state show local_file.env_cfg | head -8
# 预期：能看到 filename 与 content 的完整快照——state 是"账本"的直观证据
```

## 第 3 步：tfvars + workspace 双环境

```bash
# [VM]
cat > dev.tfvars <<'EOF'
env_name    = "dev"
log_level   = "debug"
replica_hint = 1
maintainer  = "sre-team"
EOF
cat > prod.tfvars <<'EOF'
env_name    = "prod"
log_level   = "warn"
replica_hint = 3
maintainer  = "sre-team"
EOF
```

首轮 default workspace 的 state 与将建的 dev workspace 是两本账；为了产物干净，把 default 的资源先迁到 dev workspace——最省事的做法是直接把 default 的 state 文件挪过去（本地 backend 允许）：

```bash
# [VM] default -> dev 迁移（本地 state 文件移动即可，云 backend 不适用此法）
mkdir -p terraform.tfstate.d/dev
mv terraform.tfstate terraform.tfstate.d/dev/terraform.tfstate
terraform workspace select dev        # 预期：Switched to workspace "dev"
terraform state list                  # 预期：3 个 local_file 依旧可见

terraform workspace new prod
terraform plan -var-file=prod.tfvars | grep -E 'local_file\.'
# 预期：3 个 +（prod 是空账本，全新建）
terraform apply -auto-approve -var-file=prod.tfvars
ls out/prod/                          # 预期：env.yaml  motd.txt  runbook.md
diff out/dev/env.yaml out/prod/env.yaml
# 预期差异：environment / log_level（debug vs warn）/ replica_hint（1 vs 3）
terraform workspace select dev && terraform state list | wc -l    # 预期：3（互不可见）
```

双环境落在两个坐标上：tfvars 决定**参数**（文件内容），workspace 决定 **state**（谁记账）。这与 kustomize overlay 的 dev/staging 分层（第 07 章）是同构思想：差异显式、爆炸半径隔离。

## 第 4 步：内容变化检测（`~` 与 filemd5）

```bash
# [VM] dev workspace 下操作
terraform workspace select dev
echo 'filemd5("out/dev/env.yaml")' | terraform console -var-file=dev.tfvars
# 记下这个 md5（例：a1b2c3...）

sed -i 's/log_level   = "debug"/log_level   = "info"/' dev.tfvars
terraform plan -var-file=dev.tfvars -no-color | grep -E '# local_file'
# 预期：# local_file.env_cfg must be replaced 与 # local_file.runbook must be replaced
#       （-/+，两者内容都嵌入了 log_level；motd 不出现）
#       注意：local_file 的 content 在 local provider 2.x 是 ForceNew——内容变化不是 ~ 原地更新，
#       而是 destroy+create 重建文件；Terraform 比对的是 state 里的 content（内容 hash），
#       路径不变、内容不变就完全不动
terraform apply -auto-approve -var-file=dev.tfvars
echo 'filemd5("out/dev/env.yaml")' | terraform console -var-file=dev.tfvars
# 预期：md5 已变化，而文件路径没变——内容变了才触发重建，路径不变不重建
sed -i 's/log_level   = "info"/log_level   = "debug"/' dev.tfvars
terraform apply -auto-approve -var-file=dev.tfvars    # 改回 debug，保证判分终态
```

## 第 5 步：漂移实验（删文件 → plan 存档 → apply 收编）

```bash
# [VM] 模拟"有人绕过 Terraform 手改生产"
rm out/dev/motd.txt
terraform plan -var-file=dev.tfvars -detailed-exitcode \
  > artifacts/drift-plan.txt 2>&1; echo "exit=$?"
# 预期：exit=2（有差异）
grep -E '\+ local_file|# local_file|Plan:' artifacts/drift-plan.txt
# 预期含：+ local_file.motd ...（纯新建——见下方机制说明）
#         # local_file.motd will be created
#         Plan: 1 to add, 0 to change, 0 to destroy.

terraform apply -auto-approve -var-file=dev.tfvars
# 预期：Resources: 1 added, 0 changed, 0 destroyed.（收编：按代码重建）
cat out/dev/motd.txt    # 预期：welcome to dev, maintained by sre-team —— 文件恢复
```

为什么是纯 `+` 而不是 `-/+`：`hashicorp/local` 的 Read 实现对不存在的文件按"已删除"处理（os.IsNotExist → 视为资源消失，hashicorp/local issue #262 有记载）——refresh 阶段发现 `motd.txt` 没了，就把这条资源从 state 里**移除**；而代码仍声明它要存在，于是差异是一次纯新建（`1 to add, 0 to destroy`），没有 `-/+` 也没有 destroy 计数。`-/+ must be replaced` 只出现在 ForceNew 属性变更或 taint 之后（第 6 步就是对照样本）。这正是 `+` 与 `-/+` 的辨析点：前者是"账本里没有、要新建"，后者是"账本里有、但要先销毁再建"。

这正是第 06 章第 5 节的处置原则：不手改 state、不把改动默默接受，让 apply 把真实世界拉回代码声明。CI 里 nightly 跑 `-detailed-exitcode`，exit 2 即告警。apply 执行的就是与存档一致的计划（本地单机无并发缝隙；团队协作要用 `plan -out` 固化，见第 06 章自测第 2 题）。

## 第 6 步：taint 强制重建

```bash
# [VM]
terraform taint local_file.runbook
terraform plan -var-file=dev.tfvars > artifacts/taint-plan.txt 2>&1
grep -Ei 'must be replaced|Plan:' artifacts/taint-plan.txt
# 预期含：# local_file.runbook must be replaced
#         -/+ local_file.runbook ...
#         Plan: 1 to add, 0 to change, 1 to destroy.
terraform apply -auto-approve -var-file=dev.tfvars
ls -l out/dev/runbook.md    # 预期：文件时间戳更新（被重写），内容不变
```

对应云场景：资源行为异常但代码没变（磁盘坏、实例僵死），`taint` 标记"下轮强制换新"。注意 taint 的重建是 destroy+create——对有状态云资源意味着数据随资源一起消失，生产上慎用。

## 第 7 步：终态自查与判分

```bash
# [VM]
ls out/dev/ out/prod/ artifacts/
# 预期：dev 3 个文件、prod 3 个文件、artifacts 三份存档
chmod +x check.sh && ./check.sh
```

## 第 8 步：清理（判分之后）

```bash
# [VM]
terraform workspace select prod
terraform destroy -auto-approve -var-file=prod.tfvars
terraform workspace select dev
terraform destroy -auto-approve -var-file=dev.tfvars
terraform workspace select default
terraform workspace delete dev && terraform workspace delete prod
ls out/    # 预期：目录为空（local provider 的 destroy 会删除它管理的文件）
```

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| plan 阶段报 `no such file`（函数求值失败） | 把 `filemd5()` 写进了引用被管理文件的 output，漂移删文件时 plan 直接炸 | filemd5 只在 console/临时查询用（第 1 步的警告） |
| 在 prod workspace 忘带 `-var-file=prod.tfvars` | 变量回落默认值（env_name=dev），prod 的账本里记下 dev 的文件——环境串台 | 切 workspace 与传 tfvars 绑定写成一条命令；跑完 `terraform plan` 先看 filename |
| apply prod 后 dev 的文件"没了" | 没用 workspace，两个环境共用一个 state：filename 变化触发 ForceNew 替换 | 双 workspace（本 lab 方案）或第 06 章第 6 节的 live/ 目录隔离 |
| `terraform workspace delete dev` 失败 | 不能删除当前所在的 workspace | 先 `select default` 再 delete |
| init 拉 provider 超时 | Registry 直连慢 | `export HTTPS_PROXY=http://172.30.30.1:7897` 后 init，完成后 unset（第 06 章常见坑的镜像/离线方案亦可） |
| destroy 后 out/ 里还有文件 | 那些文件不是 Terraform 管的（比如手工建的） | 确认没有手工往 out/ 放过东西；IaC 纪律：目录只由 Terraform 写 |
| drift-plan.txt 里没有 `1 to add` | 存档的是 refresh 报错而不是计划（常见于 filemd5 写进 output） | 按第 1 步检查 main.tf；重新 plan 存档 |

## 判分脚本结果

```text
# [VM]
$ ./check.sh
PASS: out/dev/env.yaml 存在
PASS: out/dev/motd.txt 存在（漂移修复后恢复）
PASS: out/dev/runbook.md 存在（taint 重建后恢复）
PASS: motd.txt 内容含 welcome to dev
PASS: out/prod/env.yaml 存在（双环境产物）
PASS: dev 的 env.yaml 含 log_level: debug
PASS: prod 的 env.yaml 含 log_level: warn
PASS: artifacts/state-list.txt 存在且含 3 个 local_file 资源
PASS: drift-plan.txt 存在且含 1 to add（漂移被抓到的纯新建计划）
PASS: taint-plan.txt 存在且含 must be replaced（强制重建计划）
PASS: workspace 目录 terraform.tfstate.d/dev 存在
PASS: workspace 目录 terraform.tfstate.d/prod 存在

SCORE: 12/12
```

## 延伸阅读

- Terraform 官方文档（HCL 语言与命令）：<https://developer.hashicorp.com/terraform/language>
- local provider：<https://registry.terraform.io/providers/hashicorp/local/latest/docs>
- terraform taint / replace（官方 CLI 参考）：<https://developer.hashicorp.com/terraform/cli/commands/taint>
- Workspaces：<https://developer.hashicorp.com/terraform/language/state/workspaces>
