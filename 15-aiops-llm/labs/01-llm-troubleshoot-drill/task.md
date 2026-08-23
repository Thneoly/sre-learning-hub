# Lab 01 · LLM 辅助排障实战演练

> 难度：★★☆ ｜ 考点：CKA-故障排除 × AIOps 方法论 ｜ 前置：15 模块第 02 章 + 靶场 scripts/faults 可用 ｜ 预计 60~90 分钟

## 场景

周三 22:40，你在值班。IM 弹出故障工单：某业务命名空间的服务异常。公司上个月刚推行"AI 辅助值班规范"，要求所有 LLM 参与的排障必须留痕：用了什么 prompt、AI 给了什么建议、每条建议如何验证、最终根因与修复——事后 SRE 负责人会抽查 `report.md`，没有验证证据的 AI 建议一律视为未发生。

你现在要做的：注入一个靶场故障模拟"告警来了"，按第 02 章的方法论用 LLM 辅助定位（盲测，不许先看 FIXES.md 对应章节），手工修复，然后完成复盘并把这次排障沉淀成知识库条目。使用的 LLM 不限（网页版 / CLI / 内网部署均可），但提问必须符合第 02 章的四要素模板（现象/环境/已尝试/约束）。

从下面三个故障中任选一个（难度递增，推荐首次做选 1）：

| 选项 | 注入脚本 | 值班拿到的现象摘要 |
|---|---|---|
| 1 | `break-imagepull.sh` | fault-imagepull 命名空间的 fault-web 服务 Pod 起不来，状态 ErrImagePull |
| 2 | `break-dns-config.sh` | 只有 fault-dns 命名空间的 Pod 域名解析失败，其他命名空间一切正常 |
| 3 | `break-endpoints.sh` | fault-ep 命名空间 Service VIP 不通，但后端 Pod 用 Pod IP 直连是通的 |

假设：kubeadm + Calico 单 master 集群；靶场脚本已同步到 master 的 `~/learning-hub/scripts/faults/`（其他路径自行替换）；本 lab 目录可写（`report.md`、`kb/` 都放在这里）。

## 任务清单

1. 注入所选故障（`sudo bash ~/learning-hub/scripts/faults/break-xxx.sh`），只记录脚本打印的"告警现象"，不打开 FIXES.md 对应章节。
2. 采集第一手证据：`kubectl get` / `describe` / `logs` / `events` 的原始输出（贴输出，不转述）。
3. 用第 02 章 T1 模板向 LLM 提问（四要素齐全），把完整 prompt 原文记入 `report.md`。
4. 把 AI 回复记入 `report.md`，对其每条建议执行验证：跑它给的只读命令（或等价命令），把命令与真实输出记入"验证证据"。
5. 手工修复（禁止用 `--restore` 交作业），验证业务恢复（Pod Running / 解析成功 / VIP 可达）。
6. 写复盘：时间线、根因（一句话 + 证据链）、影响、改进项。
7. 知识沉淀：在本 lab 目录 `kb/` 下写一条 runbook 知识条目（含 front-matter：title/source/tags/last_reviewed），格式参照 15 模块第 03 章第 3 节，并在 `report.md` 复盘一节引用该条目路径。

## 验收标准

- 本 lab 目录下存在 `report.md`，包含七个必需章节（用 `## N.` 编号标题）：
  `1. 现象记录` / `2. 提问过程` / `3. AI 建议` / `4. 验证证据` / `5. 根因分析` / `6. 修复与恢复验证` / `7. 复盘与知识沉淀`
- "验证证据"章节至少包含一条你真实执行过的命令及其输出（kubectl/journalctl/systemctl/crictl/nslookup/dig/curl 等）。
- "根因分析"和"修复与恢复验证"有实质内容，不是只有标题。
- 集群侧：三个候选故障命名空间（fault-imagepull/fault-dns/fault-ep）不存在或其中没有任何非 Running 状态的 Pod（即故障已恢复、无残留）。
- `kb/` 下至少有一个 `.md` 知识条目，且被 `report.md` 引用。
- 运行 `./check.sh` 得到 `SCORE: 10/10`。

## 提示（卡住再看）

<details><summary>提示 1：report.md 的结构总拿不准？</summary>

按验收标准的七个 `## ` 标题搭骨架，每个章节填真实过程即可。"提问过程"放你发给 LLM 的 prompt 原文（可多轮）；"AI 建议"放模型回复的关键部分；"验证证据"是你自己跑的命令和输出——注意后两章的内容必须对得上：AI 说了什么，你验了什么。
</details>

<details><summary>提示 2：LLM 的回复跑偏/太泛？</summary>

对照第 02 章四要素自查：现象是否贴了命令原始输出而不是转述？环境是否写了 kubeadm+Calico 和最近变更背景？"已尝试"是否列了排除项（比如"节点 Ready、其他命名空间正常"）？约束是否写明（不许删 namespace 重建）？缺哪项补哪项再问一轮。
</details>

<details><summary>提示 3：修复后怎么算"恢复验证"？</summary>

选项 1：Pod 变 `Running 1/1` 且 rollout status 成功；选项 2：`kubectl -n fault-dns exec deploy/fault-dns-client -- nslookup kubernetes.default` 返回正常地址；选项 3：`kubectl -n fault-ep run curl-test --rm -it --image=busybox:1.36 --restart=Never -- wget -qO- http://fault-web-svc` 能拿到响应。把命令和输出贴进第 6 节。
</details>
