# Lab 06 · Audit Policy：让 apiserver 记下谁动了什么

> 难度：★★★ ｜ 考点：CKS-监控/审计（Audit Logging） ｜ 前置：无 ｜ 预计 30~45 分钟

## 场景

等保审计要求：对 apiserver 的写操作必须留痕——特别是 Secret 的读取行为要能追溯到人，常规 Pod 变更要记录请求与响应体，而 kube-proxy 之类的高频只读操作不能把日志盘打爆。你要在 kubeadm 集群里：

1. 写一份分层节流的 audit policy（`None` / `Metadata` / `RequestResponse` 组合）；
2. 通过 kube-apiserver 静态 Pod manifest 挂载生效；
3. 制造几起"事件"（创建/删除 Secret、创建 Pod），再从审计日志里把它们逐条捞出来。

```
kube-apiserver --audit-policy-file --> 按规则给每个请求定级别
                   |                     None         不记录
                   |                     Metadata     只记录 who/when/what(不含内容)
                   |                     Request      记录请求体
                   |                     RequestResponse 记录请求+响应体
                   +--> --audit-log-path --> /var/log/kubernetes/audit.log (JSON lines)
```

## 任务清单

1. 编写 `/etc/kubernetes/audit-policy.yaml`，至少包含：`omitStages: ["RequestReceived"]`；对 `system:kube-proxy` 的 endpoints/services 只读流量 `level: None`；对 pods 的 create/delete 记 `RequestResponse`；对 secrets/configmaps 记 `Metadata`；兜底规则 `Metadata`。
2. 创建日志目录 `/var/log/kubernetes/`，编辑 `/etc/kubernetes/manifests/kube-apiserver.yaml`：追加 `--audit-policy-file=/etc/kubernetes/audit-policy.yaml` 与 `--audit-log-path=-` 之外的文件路径 `/var/log/kubernetes/audit.log`，并添加对应 hostPath volume 与 volumeMounts。
3. 等待 apiserver 静态 Pod 自动重启并就绪（`kubectl -n kube-system get pods -l component=kube-apiserver`）。
4. 制造事件：创建 namespace `cks-lab06`；在其中创建 Secret `db-password`、创建 Pod `victim`（busybox sleep）、删除 Pod `victim`。
5. 从 `/var/log/kubernetes/audit.log` 验证：能按 `cks-lab06` 过滤出 Secret 创建的 Metadata 事件、Pod create/delete 的 RequestResponse 事件；且日志中不含 kube-proxy 的 endpoints watch 噪音。

## 验收标准

- `kubectl -n kube-system get pods -l component=kube-apiserver` 为 Running
- `/var/log/kubernetes/audit.log` 存在且非空，每行是合法 JSON
- 日志里能查到 `objectRef.name=db-password`、`verb=create`、`objectRef.namespace=cks-lab06` 的记录
- 日志里 Pod `victim` 的 create 记录带 `requestObject`（RequestResponse 级别生效）
- `system:kube-proxy` 的 endpoints watch 不出现在日志中

运行判分脚本：

```bash
# [master]
cd 07-cks/labs/06-audit-policy
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：规则匹配顺序</summary>

policy 的 `rules` 是**从上到下首个命中生效**。所以最具体的规则（按 user/verb/resource 收紧的 None、RequestResponse）必须放前面，宽泛的兜底 `level: Metadata` 放最后。`omitStages: ["RequestReceived"]` 全局丢弃 RequestReceived 阶段，几乎是无脑必加（同一请求会减少一半日志量）。
</details>

<details><summary>提示 2：静态 Pod 怎么加参数</summary>

kubeadm 集群的 apiserver 是 `/etc/kubernetes/manifests/kube-apiserver.yaml` 里的静态 Pod：直接编辑该文件，kubelet 检测到变化会自动重建容器。新增 flag 加在 `command` 的 `- --` 参数列表里，hostPath 挂载要同时在 `volumeMounts`（container 级）和 `volumes`（Pod 级）声明。改坏了 apiserver 起不来时，用备份文件恢复即可（改前先 `cp` 备份）。
</details>

<details><summary>提示 3：日志文件权限</summary>

apiserver 以 root 运行但日志目录需要提前创建：`mkdir -p /var/log/kubernetes`。audit log 是 JSON lines 格式，一行一个事件，用 `jq` 或 `grep`+`python3 -m json.tool` 解析。
</details>
