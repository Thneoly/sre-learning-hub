# Lab 07 · Falco：运行时检测读 /etc/shadow 的容器

> 难度：★★★ ｜ 考点：CKS-监控/运行时安全（Falco） ｜ 前置：无 ｜ 预计 40~50 分钟

## 前置安装（环境不具备时的替代验证方式见本节末尾）

完整体验需要能出网安装 helm chart 与内核头文件。在 master 上执行：

```bash
# [master] 安装 helm（已有可跳过）
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# [master] 以 DaemonSet 方式安装 Falco（modern_ebpf 驱动无需内核头文件）
helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true \
  --set falco.json_output=false
```

安装后确认 Falco 就绪（Pod Running 且日志无 error）：

```bash
# [master]
kubectl -n falco get pods
kubectl -n falco logs daemonset/falco --tail=20
```

**环境不具备时（无法出网/内核不支持 eBPF 探针）的替代验证方式**：改用"主机直装 + 手动规则检查"路径——`apt install falco`（falcosecurity deb 源）或直接运行官方容器 `docker run --rm -i --name falco-test -v /var/run/docker.sock:/host/var/run/docker.sock -v /:/host:ro falcosecurity/falco-no-driver:latest` 观察规则加载；判分脚本在 Falco 未以 DaemonSet 部署时改为验证：falco 的 ConfigMap 中包含 `Read sensitive file` 相关规则文本（模拟部署证据），同样输出 SCORE。

## 场景

凌晨两点，一只有漏洞的 Pod 被入侵，攻击者在容器里 `cat /etc/shadow` 尝试离线破解。Falco 的默认规则集里有现成的敏感文件读取检测：**新版规则库（2024+）中容器读 shadow 触发 `Read sensitive file untrusted`，日志消息文本为 `Sensitive file opened for reading by non-trusted program`**；老版规则库中对应 `Read sensitive file trusted after startup`（仅对 nginx 等 server 进程生效）与 `Read sensitive file untrusted`。你要部署 Falco、触发默认规则、再为它定制一条**专打 /etc/shadow** 的自定义规则，最后用 `kubectl logs` 完成一次完整的"检测→取证"闭环。

## 任务清单

1. 按文首命令以 DaemonSet 部署 Falco，确认 `falco` Pod 在运行。
2. 创建 namespace `cks-lab07`，在其中运行"攻击模拟"Pod：`shadow-reader`（alpine:3.20，`sleep 15` 后 `cat /etc/shadow`），或直接 exec 进任意业务 Pod 执行 `cat /etc/shadow`。
3. 在 Falco 输出中找到被触发的默认规则告警（关键字 `Sensitive file opened for reading`，老版规则库为 `Read sensitive file`），记录其字段：`container.name`、`user.name`、`proc.cmdline`。
4. 写自定义规则 ConfigMap `falco-custom-rules`（挂载给 Falco，或本地 `rules.d` 方式）：宏 + 规则，condition 匹配"容器内 open_read 且 fd.name=/etc/shadow"，`output` 字段包含 namespace、容器名、进程名与命令行，级别 `WARNING`。
5. 重启 Falco 加载新规则，再次触发，确认新规则的事件出现且字段完整。

## 验收标准

- `kubectl -n falco get ds falco` 的 DESIRED/CURRENT/READY 一致
- Falco 日志中存在敏感文件读取告警（`Sensitive file opened for reading` 或 `Read sensitive file`），且 `proc.cmdline` 含 `cat /etc/shadow`
- 自定义规则文件/ConfigMap 存在，内容含 `macro`/`rule` 定义与 `/etc/shadow`
- （模拟路径）falco ConfigMap 存在且包含敏感文件读取规则的文本

运行判分脚本（触发事件后尽快运行，脚本会检索 Falco 全量日志）：

```bash
# [master]
cd 07-cks/labs/07-falco-detection
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：Falco 怎么"看见"容器里的 syscall</summary>

Falco 以驱动（内核模块/eBPF 探针）拿 syscall 事件流，再叠加容器运行时元数据（哪个 Pod、哪个镜像），最后用规则引擎匹配。因此它不需要改应用代码，也监控不到没有驱动时的事件——driver 装不上就什么都检测不到。
</details>

<details><summary>提示 2：默认规则叫什么、怎么验证触发</summary>

新版规则库中，容器（或宿主机上非可信程序）读敏感文件触发的规则是 `Read sensitive file untrusted`，日志消息文本为 `Sensitive file opened for reading by non-trusted program`（规则名不出现在默认输出里）；`/etc/shadow` 在其 `sensitive_files` 名单里。老版规则库另有 `Read sensitive file trusted after startup`（仅对 nginx/apache 等 server 进程生效）。触发后 `kubectl -n falco logs ds/falco --tail=50 | grep -A2 'sensitive file'`。若 Pod 已退出 15 秒后才查日志也没关系——事件是实时打印的，不随 Pod 消失。
</details>

<details><summary>提示 3：自定义规则的最小骨架</summary>

```yaml
- macro: container_shadow_read
  condition: (open_read and fd.name=/etc/shadow and evt.type in (open,openat,openat2))

- rule: Read etc shadow in container
  desc: 容器内读取 /etc/shadow
  condition: container_shadow_read and container.id != host
  output: "Shadow read (ns=%k8s.ns.name pod=%k8s.pod.name container=%container.name proc=%proc.name cmdline=%proc.cmdline)"
  priority: WARNING
```

`open_read` 是官方规则库自带的宏（open 且 read 标志）。注意 `%k8s.ns` 在当前版本不是合法字段（会报 `unknown filter` 使规则加载失败退出），要用 `%k8s.ns.name`；`%k8s.*` 字段取不到时会显示 `<NA>`，可退而用 `%container.name`。
</details>
