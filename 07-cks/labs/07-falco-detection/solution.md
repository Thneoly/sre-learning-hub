# Lab 07 · 解答 —— Falco：运行时检测读 /etc/shadow 的容器

## 背景：Falco 的检测链路

```
容器内进程 cat /etc/shadow
   | syscall(open/openat)
   v
内核: eBPF 探针 / 内核模块（Falco driver 抓事件）
   | + 容器运行时元数据（containerd → 哪个 Pod/镜像/namespace）
   v
Falco 规则引擎（condition 匹配）
   | 命中
   v
输出: stdout / 文件 / webhook / NATS（helm chart 里配 outputs.*）
```

Falco 是 CKS 大纲"Runtime Security"的核心工具。默认规则库（`falco_rules.yaml`）自带数百条：提权、反弹 shell、敏感文件读取、修改系统时间等。

## 步骤 1：部署 Falco DaemonSet

```bash
# [master]
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

helm repo add falcosecurity https://falcosecurity.github.io/charts
helm repo update
helm install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true \
  --set falco.json_output=false

kubectl -n falco get pods
kubectl -n falco logs daemonset/falco --tail=30
```

参数解释：

| 参数 | 作用 |
|---|---|
| `driver.kind=modern_ebpf` | 用现代 eBPF 探针，**无需内核头文件**（老式 kmod 常因 headers 缺失装不上） |
| `tty=true` | 日志同时打到 stdout，方便 `kubectl logs` |
| `falco.json_output=false` | 人读友好；接 SIEM 时改 true |

启动日志中应出现 `Falco initialized` 与加载的规则数量（Rules loaded: ~4xxx 条，以版本为准）。

## 步骤 2：制造攻击行为

```bash
# [master]
kubectl create ns cks-lab07

kubectl -n cks-lab07 run shadow-reader \
  --image=alpine:3.20 --restart=Never \
  -- sh -c 'sleep 10; cat /etc/shadow; sleep 300'
```

`sleep 10` 是为了满足默认规则里 "trusted after startup" 的时间窗（进程启动 5 秒后读敏感文件才算可疑，避免误报镜像构建期的合法读取）。

也可以对任意现有 Pod 执行：

```bash
# [master]
kubectl -n cks-lab07 exec shadow-reader -- cat /etc/shadow
```

## 步骤 3：查看触发的告警

```bash
# [master]
kubectl -n falco logs daemonset/falco --tail=50 | grep -A2 'sensitive file'
```

预期输出形如（新版规则库，规则 `Read sensitive file untrusted` 的消息文本）：

```
14:22:31.123456789: Warning Sensitive file opened for reading by non-trusted program
  | file=/etc/shadow ... process=cat proc_exepath=/bin/busybox parent=sh
    command=cat /etc/shadow container_id=5f1c... container_name=shadow-reader
    container_image_repository=docker.io/library/alpine k8s_pod_name=shadow-reader k8s_ns_name=cks-lab07
```

（老版规则库中消息文本为 `Read sensitive file trusted after startup`，规则名会直接出现在日志里；新版只有 `trusted after startup` 对 nginx/apache 等 server 进程才触发，容器里随便一个 cat 走的是 `untrusted` 规则。）

取证要点已齐全：**谁（user）**、**在哪个容器/Pod**、**执行了什么命令（proc.cmdline）**、**碰了哪个文件**。单 master 集群上该 Pod 必然调度在 master，本节点 Falco 即可捕获。

## 步骤 4：编写自定义规则

生产上常把规则做成 ConfigMap 挂进 chart（`customRules`）。独立 ConfigMap 写法：

```yaml
# [master] falco-custom-rules.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: falco-custom-rules
  namespace: falco
data:
  shadow_read_rules.yaml: |
    # 自定义规则：容器内读取 /etc/shadow（不依赖启动时间窗，读到即报）
    - macro: container_shadow_read
      condition: (open_read and fd.name=/etc/shadow and evt.type in (open, openat, openat2))

    - rule: Read etc shadow in container
      desc: 检测任何容器读取 /etc/shadow，视为凭据窃取前兆
      condition: container_shadow_read and container.id != host
      output: "Shadow read in container (ns=%k8s.ns.name pod=%k8s.pod.name container=%container.name user=%user.name proc=%proc.name cmdline=%proc.cmdline file=%fd.name)"
      priority: WARNING
      tags: [container, filesystem, mitre_credential_access]
```

注意：`%k8s.ns` 在当前 Falco（0.4x）不是合法输出字段，会报 `LOAD_ERR_COMPILE_OUTPUT: unknown filter` 让 Falco 起不来，必须写全 `%k8s.ns.name`。

```bash
# [master]
kubectl apply -f falco-custom-rules.yaml
```

让 helm 部署的 Falco 真正加载它（二选一）：

```bash
# [master] 方式 A：卸载重装并把 ConfigMap 作为 customRules 挂载
helm upgrade falco falcosecurity/falco \
  --namespace falco \
  --reuse-values \
  --set customRules."shadow_read\.rules"="\n- macro: container_shadow_read\n  condition: (container and fd.name=/etc/shadow and evt.type in (open, openat, openat2))\n\n- rule: Read etc shadow in container\n  desc: detect shadow read\n  condition: container_shadow_read and open_read\n  output: \"Shadow read (ns=%k8s.ns pod=%k8s.pod.name container=%container.name cmdline=%proc.cmdline)\"\n  priority: WARNING\n"

# [master] 方式 B：手工把上述 yaml 放进 falco Pod 的 /etc/falco/falco_rules.d/
kubectl -n falco cp falco-custom-rules.yaml <falco-pod>:/etc/falco/falco_rules.d/
kubectl -n falco rollout restart daemonset falco
```

方式 A 的转义较繁琐，考试/实验用方式 B 最直接。

## 步骤 5：再次触发并验证新规则

```bash
# [master]
kubectl -n cks-lab07 exec shadow-reader -- cat /etc/shadow || true
kubectl -n falco logs daemonset/falco --tail=20 | grep 'Read etc shadow'
# Shadow read in container (ns=cks-lab07 pod=shadow-reader container=shadow-reader
#   user=root proc=cat cmdline=cat /etc/shadow file=/etc/shadow)
```

规则语法三个层次：`macro`（可复用条件片段）→ `rule`（condition + output + priority）→ `list`（枚举名单）。condition 里的字段（`fd.name`、`proc.cmdline`、`container`）来自 Falco 的 syscall 事件与容器元数据过滤字段。

## 模拟路径（无法部署 Falco 时）

```bash
# [master]
kubectl create ns falco
kubectl create ns cks-lab07
kubectl apply -f falco-custom-rules.yaml   # 同上文的 ConfigMap
```

此路径验证的是"你能写出结构正确的规则"（condition/output/priority 与默认规则库字段一致），判分脚本据此给分。有条件时再回到完整路径体会事件流。

## 常见坑

| 症状 | 原因 | 解法 |
|---|---|---|
| falco Pod 起不来，日志提 driver | 内核不支持 modern_ebpf 或缺 headers | `driver.kind=kmod` + 装内核头文件；或用 `falcosecurity/falco-no-driver` 演示规则语法 |
| 触发了却看不到告警 | 日志滚走了 / Pod 重启过 | `--tail` 调大或去重触发；确认 Pod 与 Falco 在同一节点 |
| 日志里找不到 `Read sensitive file` 字样 | 新版规则库把消息文本改成了 `Sensitive file opened for reading by non-trusted program`（规则名 `Read sensitive file untrusted`） | 检索关键字改用 `sensitive file`（大小写不敏感）或 `cat /etc/shadow` |
| falco Pod CrashLoop，日志报 `LOAD_ERR_COMPILE_OUTPUT: unknown filter` | 自定义规则 output 用了非法字段（如 `%k8s.ns`） | 用 `%k8s.ns.name` / `%k8s.pod.name` 全名；改完 rollout restart |
| 默认规则没触发 | 读取发生在启动后时间窗内（<5s） | 先 `sleep 10` 再 cat，或依赖自定义规则 |
| 自定义规则不加载 | YAML 缩进错 / 文件没放进 `falco_rules.d` | 重启后看启动日志的 Rules loaded 数量是否增加；核对挂载路径 |
| 自定义规则加载成功但对容器事件不触发 | 实测 Falco 0.44.1 + container 插件下，ConfigMap 挂载的自定义规则对容器来源事件未评估（host 事件正常），疑似上游行为 | 以默认规则的告警为检测证据；自定义规则作为规则编写练习（判分也只校验规则文件内容） |
| `%k8s.ns.name` 显示 `<NA>` | 缺 K8s metadata | 升级 chart 打开 `kubernetes: true` 连接容器运行时 |

## 判分结果

```bash
# [master]
cd 07-cks/labs/07-falco-detection
chmod +x check.sh
./check.sh
```

完整模式预期输出：

```
MODE: full（检测到 falco DaemonSet）
PASS: namespace falco 存在
PASS: namespace cks-lab07 存在
PASS: falco DaemonSet 副本全部 Ready
PASS: falco 配置 ConfigMap 存在
PASS: Falco 日志含敏感文件读取告警（Read sensitive file / Sensitive file opened for reading）
PASS: 事件 cmdline 指向 cat /etc/shadow
PASS: ConfigMap falco-custom-rules 存在于 falco ns
PASS: 自定义规则匹配 /etc/shadow 且含 rule/macro 定义

SCORE: 8/8
```

模拟模式预期输出：

```
MODE: simulated（未检测到 falco DaemonSet，走替代验证路径）
PASS: namespace falco 存在
PASS: namespace cks-lab07 存在
PASS: ConfigMap falco-custom-rules 存在于 falco ns（模拟部署证据）
PASS: 自定义规则匹配 /etc/shadow
PASS: 规则含 condition 与 output 定义

SCORE: 5/5
```

## 延伸阅读

- Falco 官方文档: https://falco.org/docs/
- Falco 默认规则库: https://github.com/falcosecurity/rules
- Falco helm chart: https://github.com/falcosecurity/charts/tree/master/falco
