# Lab 09 · Terraform local provider：状态、双环境、漂移与强制重建

> 难度：★★☆ ｜ 考点：state 三角模型 / plan-apply 生命周期 / tfvars 与 workspace 多环境 / 漂移检测 / taint 强制重建 ｜ 前置：第 06 章（01-terraform，实战演练读过即可）、VM 上已装 terraform（≥1.6，安装命令见该章第 4 节） ｜ 预计 40~60 分钟

## 场景

你要给团队做一次 IaC 内训，但培训机没有云凭据。用 `hashicorp/local` provider 在本地目录上演练 Terraform 的完整心智模型：**期望状态（.tf 代码）/ state / 真实资源（磁盘文件）三角关系**——多环境参数（呼应 kustomize overlay 的 dev/staging 分层）、有人"手改生产"造成的漂移如何被 plan 抓出来、以及 taint 如何强制重建单个资源。全部动作在本机目录完成，零云资源、零费用。

约定（判分脚本按此检查）：

- 工作目录 `~/labs/terraform-local`，产物目录 `out/<env>/`，存档目录 `artifacts/`；
- `main.tf` 定义 **3 个 `local_file` 资源**：`env_cfg`（env.yaml）、`motd`（motd.txt）、`runbook`（runbook.md），内容由变量驱动（`filemd5` 在演练中用于验证"内容变化才触发变更"）；
- 双环境：workspace `dev` + `dev.tfvars`（log_level=debug、replica_hint=1）、workspace `prod` + `prod.tfvars`（log_level=warn、replica_hint=3），产物分别落 `out/dev/` 与 `out/prod/`；
- **判分时机：完成第 7 步（taint 重建）之后、第 8 步（destroy）之前运行 check.sh**——destroy 会清掉产物与 state。

## 任务清单

1. 写 `main.tf`：terraform 块钉 local provider（`hashicorp/local`，`~> 2.5`）；变量 `env_name`/`log_level`/`replica_hint`/`maintainer`；locals 拼出输出目录与文件内容；3 个 `local_file` 资源写到 `out/${var.env_name}/` 下；输出 `out_dir`。`terraform init`（拉 provider 走 Registry，慢可设 `HTTPS_PROXY` 用本环境代理）→ `terraform validate`。
2. 在默认参数或 dev.tfvars 下 `terraform plan`（看到 3 个 `+`）→ `terraform apply`，确认 3 个文件落盘；`terraform state list` 与 `terraform state show local_file.env_cfg`（把 state list 输出存档到 `artifacts/state-list.txt`）。
3. 写 `dev.tfvars` 与 `prod.tfvars`（同名变量、不同值）。建 workspace `dev` 与 `prod`，分别在各自 workspace 用对应 tfvars apply；验证 `out/dev/` 与 `out/prod/` 的 env.yaml 内容不同（dev 是 debug/1，prod 是 warn/3），两个 workspace 的 state 互不可见（各自 `state list` 都只有 3 个资源）。
4. 内容变化检测：改 `dev.tfvars` 的 `log_level`（debug→info），plan 应只影响内容嵌入了 log_level 的资源——`env_cfg` 与 `runbook` 都出现 `-/+ must be replaced`（`local_file` 的 `content` 是 ForceNew，内容变化=重建文件；runbook 模板里也有 log_level 行），`motd` 不动；apply 后用 `filemd5` 验证（`echo 'filemd5("out/dev/env.yaml")' | terraform console -var-file=dev.tfvars` 在改前改后各取一次，hash 变化而文件路径不变）。
5. **漂移实验**：在 dev workspace 手动删掉 `out/dev/motd.txt`（模拟"有人绕过 Terraform 手改"），`terraform plan -detailed-exitcode` 应退出码 2。注意 `hashicorp/local` 的 Read 对不存在的文件按"已删除"处理：refresh 阶段就把这条资源移出 state，计划是**纯新建**（`+ local_file.motd will be created`、`Plan: 1 to add, 0 to change, 0 to destroy.`），没有 `-/+` 也没有 destroy 计数。把这份 plan 输出存档到 `artifacts/drift-plan.txt`（须包含 `1 to add` 字样）；随后 `terraform apply` 收编修复，确认文件恢复。
6. `terraform taint local_file.runbook`（dev workspace），plan 出现 `must be replaced`（destroy + create），存档到 `artifacts/taint-plan.txt`；apply 后 runbook.md 被重建（filemd5 与重建前相同——内容没变，重建只是重写）。
7. 终态自查：out/dev 三个文件齐全、out/prod 存在、三份存档齐全。运行 check.sh 判分。
8. **清理（判分之后）**：分别在 dev 与 prod workspace `terraform destroy`，确认 out/ 下文件被删除、`terraform workspace select default` 后可删除多余 workspace。

## 验收标准

判分时点的终态（文件只读可验证，无需 terraform 命令）：

- `out/dev/env.yaml`、`out/dev/motd.txt`、`out/dev/runbook.md` 都存在，motd.txt 内容含 `welcome to dev`；
- `out/prod/env.yaml` 存在；dev 与 prod 的 env.yaml 分别含 `log_level: debug` 与 `log_level: warn`；
- `artifacts/state-list.txt` 存在且含 3 行 `local_file.` 开头的资源；
- `artifacts/drift-plan.txt` 存在且含 `1 to add`（漂移被抓到后的纯新建计划证据）；
- `artifacts/taint-plan.txt` 存在且含 `must be replaced`（强制重建的计划证据）；
- `terraform.tfstate.d/dev` 与 `terraform.tfstate.d/prod` 目录存在（双 workspace）。

完成后运行判分脚本（与 task.md 同目录）：

```bash
# [VM]
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：workspace 和 tfvars 不是二选一吗？为什么两个都用？</summary>

它们解决多环境的不同侧面：tfvars 区分**参数**（同名变量喂不同值），workspace 区分 **state**（同一份代码各自记账，爆炸半径隔离）。只用 tfvars 不换 workspace 的话，dev 与 prod 会共用一个 state——apply prod 会把 dev 的资源替换掉（filename 变了就是 destroy+create）。本 lab 用 `filename = ".../out/${var.env_name}/..."` 加双 workspace，两个环境的文件与 state 才能并存。对应第 06 章第 6 节"`live/` 每环境独立 state"的纪律。

</details>

<details><summary>提示 2：漂移实验里 plan 为什么显示的是纯粹的"+"而不是"-/+"？</summary>

`hashicorp/local` 的 Read 实现对不存在的文件按"已删除"处理（os.IsNotExist → 视为资源消失，hashicorp/local issue #262 有记载）：refresh 阶段发现 `out/dev/motd.txt` 没了，会把这条资源从 state 里**移除**；而代码仍声明它要存在，于是差异是一次纯新建——`+ local_file.motd will be created`，汇总行为 `Plan: 1 to add, 0 to change, 0 to destroy.`。`-/+ must be replaced` 只出现在 ForceNew 属性变更或 taint 之后（对比第 6 步的 runbook）。两种形态 exit code 都是 2（有差异即告警），存档里 grep `1 to add` 就是这个依据。

</details>

<details><summary>提示 3：taint 之后 runbook.md 的 filemd5 为什么不变？</summary>

taint 只是把资源标记为"下轮 apply 强制重建"；`local_file` 重建的动作是用同样的 content 重写文件——内容一样，md5 自然一样。它对应真实云场景里的"资源出问题但代码没变，强制换一台"（如磁盘坏掉的 ECS）。

</details>

<details><summary>提示 4：terraform init 拉 provider 超时怎么办？</summary>

Registry（registry.terraform.io）从国内直连通常可达但慢。走本环境代理：`export HTTPS_PROXY=http://172.30.30.1:7897` 后再 init；或按第 06 章常见坑配镜像/`-plugin-dir` 离线包。init 成功后记得 `unset HTTPS_PROXY`（后续 plan/apply 只读写本地，无需代理）。

</details>

<details><summary>提示 5：在 workspace 之间切换时忘了带 -var-file 会怎样？</summary>

变量回落到默认值（env_name 默认 dev），在 prod workspace 里忘带 `prod.tfvars` 会把 dev 内容写进 prod 的 state——文件路径变成 out/dev/，造成"环境串台"。习惯写成一条：`terraform workspace select prod && terraform plan -var-file=prod.tfvars`，或直接把 `-var-file` 写进 `terraform.tfvars` 之外的环境专用文件名（TF_VAR_ 环境变量也行）。

</details>
