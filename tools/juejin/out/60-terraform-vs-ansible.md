---
title_juejin: 'Terraform 和 Ansible 二选一，从出题就错了'
title_zhihu: 'Terraform 和 Ansible 二选一是道错题：state 账本与幂等收敛各管一层'
description: '可变与不可变分野、state账本与plan/apply、幂等收敛、state丢失与远端backend锁、TF供给加Ansible装配置、provider版本与变量优先级坑、IaC入门最小路径。'
category_id: "6809637769959178254"
tags: "后端,运维"
column_id: "7686472562230312970"
---

# Terraform 和 Ansible 不是竞品：一个造机房，一个装机房

周会上吵了一小时"Terraform 换掉 Ansible"，散会前实习生怯生生问了句："那个 terraform.tfstate 看着像缓存文件，能删吗？"会议室瞬间安静——这一句比前面一小时都接近要害。（案例为构造，问题是真的。）

先把结论拍在桌上：**拿这两个工具二选一，题目从出题那天起就是错的**。它们都是声明式——你宣告期望状态，工具负责到达——但一个管云资源的生死，一个管机器里的配置，不在同一层竞争。

真正该搞懂的是三个问题：state 这本账为什么必须存在；Ansible 凭什么敢没有它；两者怎么组合才不打架。

## 一、分野的根：可变与不可变

Ansible 的动作对象是"一台已经开好的机器"：SSH 进去，装包、改配置、起服务，改完还是原来那台机器。机器有连续的身份，配置在原地演进——这是可变基础设施：机器像宠物，养它、修它。

Terraform 正相反。改了不可更新的字段（VPC 的 cidr_block、ECS 换镜像），它的答案不是改，是删了重建——plan 输出里的 `-/+` 就是判决书，生产上等于先删后建。这是不可变的姿势：机器像牲口，不修，换。

【从业者判断】"可变 vs 不可变"与"宠物/牲口"是业界通用解读框架，不在工具文档里，但统摄两者差异最省力。

一句话记住分野：**可变世界修机器，不可变世界换机器**。

## 二、Terraform：state 是计划与现实的对照账本

Terraform 的世界里永远有三个东西：期望状态（你的 .tf 代码）、state 文件、真实资源（云上）。state 是代码与资源之间的账本。

账本记的是"代码里的 alicloud_vpc.main 就是云上的 vpc-0xi9kxxx"——名字到资源 ID 的映射，加上属性快照。云资源创建后返回全局唯一 ID，创建销毁既花钱又有副作用，没有这本账，Terraform 不知道哪个 VPC 是"我的"，只能重复创建。

先算后改，落在两个命令上：

```bash
terraform plan
# 读 state + 刷新云上真实状态 + 与代码比对，输出"将要做什么"
terraform apply
# 按 plan 执行；默认会先重算一次 plan 并要求确认（除非传入保存的 plan 文件）
```

plan 的动作符号必须背：`+` 新建、`~` 原地更新、`-/+` 删除重建、`-` 删除。**apply 前必看 plan，重点盯 `-/+`**——那是"看起来只改一个参数，实际是先删后建"的陷阱高发区。

顺带一个认知：变量变了，资源就被替换——`terraform apply -var env_name=prod` 不会原地改 env-test.yaml，而是先删旧文件、再写 env-prod.yaml（`-/+` 先删后建）。对 local_file 这类字段不可原地更新的资源，没有"改文件"，只有换一个。

两个推论同样要背：**state 丢了等于失联**（资源还在云上跑、还在计费，但 Terraform 管不了了）；**state 里有明文敏感值**（数据库密码这类），必须当密钥保管。

## 三、Ansible：没有账本，靠幂等每次全量收敛

Ansible 不记账。控制节点通过 SSH 把模块（一段小程序）推到远端执行，拿回 JSON 结果，**远端不留任何东西**——无 agent、无常驻进程、无额外端口。

它敢不记账，是因为对象不同：Ansible 管操作系统现状，每次连接现查——服务起没起、文件在不在——期望与现实直接比对，无需留档。云资源必须记账，因为资源有 ID、要花钱；配置的现状就在机器上，现查就行。

支撑这一切的是幂等：同一 playbook 跑 N 遍，结果与跑 1 遍相同。`apt: state=present` 第二次跑显示 ok 而不是重装：

```bash
ansible-playbook site.yml
# cka000022 : ok=4 changed=3 unreachable=0 failed=0
ansible-playbook site.yml
# changed=0 —— 第二次全部 ok，这就是幂等
```

**幂等是"批量改生产"的安全底线**：失败修复后从头再跑即可——批量 shell 脚本做不到这一点，跑第二遍就是事故。

代价也明码标价：无 agent 意味着没有主动上报，配置有没有被手改漂移，得自己定时跑（cron 或 CI）才能发现。Terraform 检测漂移同样要定时跑，别指望谁替你盯着——区别是 state 这本对照账让它一个退出码就能机器判定，下一节展开。

## 四、state 的事故面：丢了是失联，手改是毒药

state 是单点，三种典型事故：

**事故一：state 文件丢了**。资源仍在云上正常计费运行，但映射没了。恢复只有一条路：把每个资源的 ID 重新 import 回 state（写 import block，或用 `terraform import` 命令），再补齐代码属性直到 plan 无差异。"代码即真相"离开 state，对不上任何存量资源。

**事故二：手改 state**。为了消除漂移告警直接编辑 state 文件，等于伪造账本——账面平了，云上该错的还错着。处置漂移的正解：能收编的把控制台变更写回 .tf 再 apply；不该存在的，直接 apply 让 Terraform 改回去。严禁手改 state。

**事故三：多人同时 apply，state 报锁**。这不是故障，是救命的机制——没有锁，两条流水线并发写 state，账本直接写坏。真被锁卡住，先确认没有 apply 在跑，再 `terraform force-unlock`（慎用）。

解药是远端 backend：阿里云用 OSS 存 state + Tablestore 加锁，AWS 同理 S3 + DynamoDB，一次解决共享、加锁、版本化三件事：

```hcl
# [文件 backend.tf] 节选：apply 期间加锁，防并发写坏 state
terraform {
  backend "oss" {
    bucket = "my-company-tfstate"
    prefix = "demo/networking"
    table  = "my-tflock-table"
  }
}
```

再加两条纪律：state 历史靠 bucket 版本控制兜底；**任何人不得在本地模式下 apply 生产**，CI 是唯一入口。

漂移检测一行命令，CI 里每晚跑：

```bash
terraform plan -detailed-exitcode
# exit 0 = 无差异（代码=state=真实）
# exit 2 = 有差异（漂移或待 apply 的变更）——有人手改生产，告警
# exit 1 = 出错
```

## 五、组合才是正解：TF 供给 infra，Ansible 装配置

把两个工具放进同一张表，几乎没有重叠的格：

| 维度 | Terraform | Ansible |
|---|---|---|
| 管什么 | VPC/ECS/RDS/安全组 | 装包、改配置、起服务、发版 |
| 执行模型 | 有状态：plan 先算差异再 apply | 无状态：现看现状，靠幂等 |
| 删除语义 | destroy 整栈精确回收 | 默认不删，要写 task 显式删 |
| 并发防护 | backend 锁，天然串行化 | 无内建锁，forks 并行 |

最常见的企业流水线就三步，output 把 ID 传下去：

```bash
terraform apply -auto-approve
terraform output          # 接出 VPC ID、节点 IP，生成 Ansible inventory
ansible-playbook site.yml # 拿着新机器的 IP 去装配置
```

一句话选型：**Terraform 造机房，Ansible 装机房**，顺序上 Terraform 先行。【从业者判断】反过来用 Ansible 开云资源、用 Terraform 装软件，不是不行，是各自都用在了自己最弱的一面。

## 六、入门踩坑清单

坑一：provider 版本漂移。没锁版本，某天 `terraform init` 拉了新 provider，默认行为变了，plan 莫名其妙巨变。解法：`required_providers` 里锁 `~> 1.235` 这类约束，`.terraform.lock.hcl` 提交进仓库。

坑二：假设幂等，实则重复。`command`/`shell` 模块天然不幂等，每次都执行且永远报 changed——既冒"跑第二遍变事故"的风险，又失去 changed 计数这个审计信号。口诀：**有专用模块就不用 command**，实在要用加 `creates: /path/to/file` 兜底。

坑三：变量优先级地狱。Ansible 的变量落点至少三层：group_vars（组共享）→ host_vars（单机差异）→ 命令行 `-e`（优先级最高）；role 内部还分 defaults（低，暴露给使用者）和 vars（高）。排查"为什么值不对"，先看是不是被更高优先级覆盖。

Terraform 侧的对应纪律：凭据绝不写进代码，走环境变量或 CI secrets，敏感 tfvars 进 .gitignore。

坑四（送一个）：handler 没触发。notify 的名字与 handler 名不一致（必须完全相同），或 task 根本没发生变更。`ansible-playbook --list-tasks` 双向检查。

handler 是好设计：N 个 task notify 只 reload 一次，且统一在 play 收尾——避免配置改一半服务就重启。

## 七、第一个 IaC 项目的最小路径

别一上来就动生产云。两步离线练，一步真云，是最小路径。

第一步，用 local provider 在本机把 state、plan、apply、漂移全流程跑通，零成本：

```bash
mkdir -p ~/tf-lab && cd ~/tf-lab
# 放一个声明 local_file 资源的 main.tf（provider 用 hashicorp/local）
terraform init
terraform plan
terraform apply -auto-approve
# Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
terraform state list
# local_file.env_cfg
# 漂移实验：手工"手改生产"
rm out/env-test.yaml
terraform plan -detailed-exitcode; echo "exit=$?"
# exit=2 —— 这就是漂移检测
terraform destroy -auto-approve   # 实验完回收
```

第二步，Ansible 找两台能 SSH 的机器，打通免密后先干跑再真跑：

```bash
ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
ssh-copy-id cka@172.30.30.22
ansible webservers -m ping
# cka000022 | SUCCESS => {"ping": "pong"}  ← 远端 python3 返回的
ansible-playbook site.yml --check --diff   # 干跑 + 差异预览
ansible-playbook site.yml                  # 预览确认后执行
```

第三步才是真云，从测试环境开始：Terraform 建 VPC 和安全组，output 接出节点 IP，Ansible 装 nginx——把第五节的流水线亲手走一遍，比读十篇对比文章有用。

## 现在就能做的事

第一，查你们生产的 state 放在哪。还是本地文件就标 P0：本周迁远端 backend（OSS/S3 + 锁），共享、加锁、版本化一次解决。

第二，把你最常跑的 playbook 连跑两遍。changed 不归零就揪出那个不幂等的 task——多半是 command 或 shell 在顶替专用模块。

第三，盘点谁还有云控制台的写权限。Terraform 管的资源把写权限收归 CI 服务账号——手改的口子不关，漂移永远治理不完。

完整的 HCL 模板、playbook 示例、分工表和踩坑解法，都在我的学习仓库：GitHub 搜 sre-learning-hub。

评论区聊聊：你们是"TF + Ansible 双引擎"，还是单个工具硬扛全部？如果是后者，谁在替它干另一层的活？
