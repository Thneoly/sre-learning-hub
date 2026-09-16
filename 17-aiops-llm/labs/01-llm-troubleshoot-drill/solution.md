# Lab 01 · 解答：LLM 辅助排障实战演练（以选项 1 break-imagepull 为例）

> 运行位置：除特别标注外，命令都在 master 上执行；本 lab 目录（含 `report.md`、`kb/`）假设在 master 的 `~/01-llm-troubleshoot-drill/`。
> 重要：本文展示的"AI 建议"是示范样本。你交作业时，`report.md` 里的 AI 输出必须是你自己会话的真实记录——用自己的现象、自己的验证输出，这也是本 lab 的训练点本身。

## Step 0 · 前置确认

```bash
# [master] 集群健康、靶场脚本就位
kubectl get nodes
ls ~/learning-hub/scripts/faults/break-imagepull.sh
```

预期：单 master（可含 worker）全部 `Ready`；脚本能列出来。

## Step 1 · 注入故障，进入盲测

```bash
# [master] 注入镜像拉取故障
sudo bash ~/learning-hub/scripts/faults/break-imagepull.sh
```

脚本末尾打印"告警现象"。此时不要打开 FIXES.md 的故障 10 章节，把现象原文抄进 `report.md` 第 1 节。

## Step 2 · 采集第一手证据

```bash
# [master] Pod 状态
kubectl -n fault-imagepull get pods -o wide
```

预期输出：

```
NAME                       READY   STATUS         RESTARTS   AGE   IP       NODE
fault-web-9b7d8f6c5-x2p4b  0/1     ErrImagePull   0          40s   <none>   worker1
```

```bash
# [master] describe 的 Events 段（核心证据）
kubectl -n fault-imagepull describe pod -l app=fault-web | sed -n '/Events:/,$p'
```

预期输出（节选）：

```
Events:
  Type     Reason     Age                From               Message
  ----     ------     ----               ----               -------
  Normal   Scheduled  2m                 default-scheduler  Successfully assigned fault-imagepull/fault-web-9b7d8f6c5-x2p4b to worker1
  Normal   Pulling    98s (x4 over 2m)   kubelet            Pulling image "nginx:1.27.99-notexist"
  Warning  Failed     96s (x4 over 2m)   kubelet            Failed to pull image "nginx:1.27.99-notexist": manifest for nginx:1.27.99-notexist not found
  Normal   BackOff    88s (x5 over 2m)   kubelet            Back-off pulling image "nginx:1.27.99-notexist"
```

## Step 3 · 用 T1 模板提问（四要素齐全）

以下 prompt 整体提交给你可用的 LLM：

```
# [任意] 第一轮排障提问（原文记入 report.md 第 2 节）
【角色】你是 Kubernetes 值班工程师的助手，只做分析和给验证命令。
【现象】
$ kubectl -n fault-imagepull get pods
NAME                       READY   STATUS         RESTARTS   AGE
fault-web-9b7d8f6c5-x2p4b  0/1     ErrImagePull   0          40s

$ kubectl -n fault-imagepull describe pod -l app=fault-web | sed -n '/Events:/,$p'
（粘贴 Step 2 的 Events 原文）
【环境】kubeadm v1.29 单 master + Calico，节点全部 Ready；
该 deployment 约 1 小时前刚做过一次镜像变更；其他命名空间 Pod 正常。
【已尝试】只看了 pods 和 describe，尚未验证镜像 tag 是否存在。
【约束】不能删除 namespace 重建；修复动作需要我人工执行并留痕。
【要求】1. 复述你理解的问题；2. 按可能性排序的 Top3 假设；
3. 每个假设配一条只读验证命令；4. 标注你还需要我补充什么。
禁止给出变更类命令。
```

## Step 4 · 验证 AI 的每条建议

典型 AI 回复（样本，措辞会不同）：

> 1. 问题复述：新命名空间的 Pod 因容器镜像拉取失败无法启动，kubelet 在重试后退避。
> 2. Top3 假设：① 镜像 tag 不存在/拼写错误（Events 报 `manifest ... not found`，直接支持）；② registry 不可达或限流（但报错不是 timeout/toomanyrequests，支持弱）；③ 缺 imagePullSecrets（公共镜像一般不需要，且无 unauthorized 报错，支持弱）。
> 3. 验证命令：`kubectl -n fault-imagepull get deploy fault-web -o jsonpath='{.spec.template.spec.containers[0].image}'`；并在节点上确认候选 tag 存在。

逐条验证（输出全部记入 `report.md` 第 4 节）：

```bash
# [master] 验证假设 1 前半：当前镜像 tag
kubectl -n fault-imagepull get deployment fault-web -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

预期输出：

```
nginx:1.27.99-notexist
```

```bash
# [worker1] 验证假设 1 后半：候选 tag 在 registry 是否存在（能拉下即存在）
sudo crictl pull nginx:1.27-alpine
```

预期输出形如 `Image is up to date for sha256:...`。

```bash
# [master] 验证假设 2/3：失败原因是 not found（非 timeout/unauthorized）
kubectl -n fault-imagepull describe pod -l app=fault-web | grep -E 'Failed to pull|secret'
```

结论：假设 1 成立，假设 2/3 被原始报错排除——这段"排除推理"也要写进报告，它是"验证后执行"纪律的证据。

## Step 5 · 修复（人工重写命令）并验证恢复

```bash
# [master] 修复：镜像指回已验证存在的 tag
kubectl -n fault-imagepull set image deployment/fault-web fault-web=nginx:1.27-alpine
kubectl -n fault-imagepull rollout status deployment/fault-web --timeout=120s
kubectl -n fault-imagepull get pods
```

预期：rollout 输出 `deployment "fault-web" successfully rolled out`，Pod `Running 1/1`。

## Step 6 · report.md 完整示范

按七个章节写（这份示范可通过 check.sh 全部检查）：

```
# [任意] 文件 ~/01-llm-troubleshoot-drill/report.md 的内容
# LLM 辅助排障报告 · 2026-08-22 · 值班：本人 · 故障：break-imagepull

## 1. 现象记录
22:40 工单：fault-imagepull 命名空间 fault-web 服务不可用。
kubectl -n fault-imagepull get pods：fault-web-9b7d8f6c5-x2p4b  0/1  ErrImagePull。
其他命名空间正常，节点全部 Ready。

## 2. 提问过程
（Step 3 的完整 prompt 原文，含四要素，直接粘贴）
第二轮追问：贴上 jsonpath 输出后，问"tag 确认不存在，如何确认正确 tag 应该是什么，
修复前还需要验证什么"。

## 3. AI 建议
假设1（高）：镜像 tag 不存在/拼写错误。
假设2（中）：registry 不可达或限流。
假设3（低）：缺 imagePullSecrets。
AI 同时给出：确认正确 tag 后再变更、变更命令由我人工执行。

## 4. 验证证据
$ kubectl -n fault-imagepull get deployment fault-web -o jsonpath='{.spec.template.spec.containers[0].image}'
nginx:1.27.99-notexist
$ sudo crictl pull nginx:1.27-alpine        # [worker1]
Image is up to date for sha256:...（候选 tag 存在）
$ kubectl -n fault-imagepull describe pod -l app=fault-web | grep -E 'Failed to pull|secret'
Failed to pull image "nginx:1.27.99-notexist": manifest ... not found（无 unauthorized/timeout）
排除：假设2、假设3 与原始报错矛盾。

## 5. 根因分析
deployment 的镜像被改成不存在的 tag（nginx:1.27.99-notexist），
kubelet 拉取失败进入 ImagePullBackOff。证据链：jsonpath 当前值 +
Events 的 manifest not found + crictl pull 证明好 tag 存在。

## 6. 修复与恢复验证
$ kubectl -n fault-imagepull set image deployment/fault-web fault-web=nginx:1.27-alpine
$ kubectl -n fault-imagepull rollout status deployment/fault-web --timeout=120s
deployment "fault-web" successfully rolled out
$ kubectl -n fault-imagepull get pods    → Running 1/1

## 7. 复盘与知识沉淀
时间线：22:40 接警 → 22:52 完成 T1 提问 → 23:02 假设验证完毕 → 23:10 恢复。
MTTA≈30min，主要耗时在采集证据环节。
改进：镜像变更接入 CI 的 tag 存在性校验（owner：本人，deadline：本周）。
知识条目：kb/runbook-k8s-imagepull-backoff.md
```

## Step 7 · 知识库条目示范

```
# [任意] 文件 ~/01-llm-troubleshoot-drill/kb/runbook-k8s-imagepull-backoff.md 的内容
---
id: runbook-k8s-imagepull-backoff
title: Pod ImagePullBackOff / ErrImagePull 处理
source: runbook
severity: P3
tags: [kubernetes, image, kubelet]
last_reviewed: 2026-08-22
owner: sre-team
---

## 现象
Pod 状态 ErrImagePull 或 ImagePullBackOff，describe Events 有 Failed to pull image。

## 定位命令（只读）
kubectl -n <ns> describe pod <pod> | sed -n '/Events:/,$p'
kubectl -n <ns> get deploy <dep> -o jsonpath='{.spec.template.spec.containers[*].image}'
节点侧确认 tag 存在：sudo crictl pull <image:tag>

## 常见根因
1. tag 不存在/拼写错误（Events: manifest ... not found）
2. registry 不可达或限流（Events: timeout / toomanyrequests）
3. 私有仓库缺 imagePullSecrets（Events: unauthorized）

## 修复
kubectl -n <ns> set image deployment/<dep> <container>=<存在且验证过的 image:tag>
验证：kubectl -n <ns> rollout status deployment/<dep> --timeout=120s

## 关联
本次复盘见 report.md（2026-08-22 值班记录）
```

## Step 8 · 运行判分

```bash
# [master] 在 lab 目录内运行（先从仓库同步 check.sh 到该目录）
chmod +x check.sh && ./check.sh
```

预期结果（本机无 kubectl 时第 9 项会 FAIL，需在有 kubeconfig 的机器上跑）：

```
PASS: report.md 存在（路径：~/01-llm-troubleshoot-drill/report.md）
PASS: 七个必需章节齐全
PASS: 「现象记录」有实质内容（非空行 4 行，需 >=2）
PASS: 「提问过程」记录了实际提问（非空行 8 行，需 >=5）
PASS: 「AI 建议」记录了模型输出（非空行 4 行，需 >=3）
PASS: 「验证证据」包含至少一条真实命令（kubectl/journalctl/crictl/nslookup 等）
PASS: 「根因分析」有实质内容（非空行 3 行，需 >=2）
PASS: 「修复与恢复验证」包含修复命令与验证（非空行 4 行）
PASS: 集群无残留故障（非 Running Pod 检查）
PASS: kb/ 下有 1 条知识条目且被 report.md 引用

SCORE: 10/10
```

## Step 9 · 核对标准答案并清理

```bash
# [master] 手工修复后用 --restore 核对（此时幂等：镜像已是好 tag，restore 不会改坏）
sudo bash ~/learning-hub/scripts/faults/break-imagepull.sh --restore
kubectl delete ns fault-imagepull
```

最后打开 `scripts/faults/FIXES.md` 的故障 10 章节对照：你的排障路径与标准路径差在哪一步、哪一步 LLM 帮你加速了、哪一步它的建议是无效的——把这三问的答案补进报告第 7 节，这个 lab 的训练价值才算吃满。

## 换个故障再来一次

选项 2（break-dns-config）与选项 3（break-endpoints）的流程完全一致，差异只在证据采集重点：

- 选项 2 关键证据：`kubectl -n fault-dns exec deploy/fault-dns-client -- cat /etc/resolv.conf`（第一个 nameserver 不是 10.96.0.10 就是突破口）；验证恢复用 `nslookup kubernetes.default`。
- 选项 3 关键证据：`kubectl -n fault-ep get endpoints fault-web-svc`（ENDPOINTS 为 `<none>`）；验证恢复用 Pod IP 直连对比 Service VIP。

做完三个选项，你就拥有了一份可以直接放进简历作品集的"LLM 辅助排障留痕集"——第 01 章第 4 节的 JD 拆解里，这正是面试官想看的东西。
