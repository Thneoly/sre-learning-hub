# Lab 02 · Solution：混沌演练与无责复盘

按 task.md 顺序逐步讲解。所有命令在 master 上、lab 目录 `~/labs/02-chaos-drill/` 内执行。路线 A（应用层注入）为主线，路线 B（`scripts/faults` 的 DNS 故障）在末尾单独一节。

## Step 0 · 部署脚手架

```bash
# [master]
cd ~/labs/02-chaos-drill
kubectl apply -f app.yaml
kubectl -n chaos-demo rollout status deploy/chaos-demo --timeout=180s
# 预期：deployment "chaos-demo" successfully rolled out

kubectl -n chaos-demo get pods
# NAME                          READY   STATUS    RESTARTS   AGE
# chaos-demo-6c9d8b7f4-2vj9k    1/1     Running   0          1m
# chaos-demo-6c9d8b7f4-8qz4t    1/1     Running   0          1m
# load-gen-7b6f5c9d4-p1r2s      1/1     Running   0          1m
```

**为什么独立命名空间**：这是爆炸半径的第一道围栏——后续所有注入手段（`/set`、路线 B 的 `fault-dns`）都被限制在专属命名空间里，出问题也烧不到 `kube-system` 和 `monitoring`。

## Step 1 · 先写 drill-plan.md（演练前！）

**做什么**：在动手注入之前把方案写完。这是混沌工程与"瞎搞"的分界线。

**为什么**：Netflix 的 Principles of Chaos 第一条就是"先定义稳态"——如果你无法用数字说出"系统现在是好的"，你就无法证明故障造成了影响，也无法证明你恢复了它。方案先行还有一个工程价值：中止条件必须在头脑冷静时写好，故障进行中人是不会做风险决策的好状态的。

可直接套用的 `drill-plan.md`（执行日志留空待回填）：

```markdown
# [master] 保存为 ~/labs/02-chaos-drill/drill-plan.md
# Chaos Drill Plan · chaos-demo 错误率注入（路线 A）

## 演练目标
验证假设：当 chaos-demo 出现 10% 的 5xx 错误率时，我们能通过 Prometheus
指标与告警在 5 分钟内发现（MTTD <= 5min），且恢复操作可在 2 分钟内完成。

## 稳态假设
- 5 分钟错误率为 0：
  sum(rate(demo_http_requests_total{code=~"5.."}[5m]))
  / clamp_min(sum(rate(demo_http_requests_total[5m])), 1e-10) == 0
- 注入开关处于关闭状态：demo_fail_rate == 0
- Pod 全部就绪：kubectl -n chaos-demo get deploy chaos-demo 的 READY 为 2/2

## 爆炸半径
- 受影响范围：仅 chaos-demo 命名空间内的 chaos-demo 服务与其使用方 load-gen
- 不受影响：kube-system、monitoring、default 命名空间；集群组件（apiserver/
  etcd/CoreDNS/Calico）；节点本身
- 注入面：应用进程内 /set 接口，不触碰内核、CNI、kubelet
- 演练窗口：低峰时段，总时长不超过 20 分钟
- 强度阶梯：0.05 -> 0.1，观察 3 分钟无异常再加档

## 观测点
| 观测点 | 命令/查询 | 预期 |
|---|---|---|
| 业务错误率 | Prometheus UI: sum(rate(demo_http_requests_total{code=~"5.."}[5m]))/clamp_min(sum(rate(demo_http_requests_total[5m])),1e-10) | 注入后约 1 分钟内升到 ~0.1 |
| 注入状态 | demo_fail_rate 指标 | 0 -> 0.1 -> 0 |
| 告警 | curl http://<NODE_IP>:30900/api/v1/alerts | 若配置了燃烧率告警（lab 01），5 分钟内 firing |
| 资源 | kubectl -n chaos-demo get pods | Pod 始终 Running（进程活着，只是返回 5xx） |

## 中止条件（满足任一立即回滚）
1. chaos-demo 之外任何命名空间出现异常（Pod 重启、apiserver 延迟飙升）
2. master 组件健康异常：kubectl get --raw /readyz 返回非 ok
3. 注入超过 15 分钟仍未完成观测目标
4. 出现方案未预期的连锁反应（如节点 OOM、网络抖动）

回滚动作：/set?fail_rate=0&latency_ms=0（预计 < 1 分钟生效）

## 执行步骤
1. [ ] 采集稳态基线（错误率、demo_fail_rate、Pod 状态）并记录时间戳
2. [ ] 注入 fail_rate=0.05，观察 2 分钟
3. [ ] 加档到 fail_rate=0.1，按观测点逐条记录
4. [ ] 记录 MTTD（注入 -> 错误率指标可见 / 告警 firing）
5. [ ] 触发回滚，记录恢复时间
6. [ ] 验证稳态回归

## 恢复步骤
kubectl -n chaos-demo exec deploy/chaos-demo -- python3 -c \
  "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8000/set?fail_rate=0&latency_ms=0').read().decode())"
随后复查稳态假设三条款全部成立。

## 执行日志（演练时回填）
| 时间 | 动作/观测 | 结果 |
|---|---|---|
| （待演练时逐行填写） | | |
```

注意"中止条件"里第 2 条对应的检查命令：

```bash
# [master] 随时可查；返回 ok 才继续演练
kubectl get --raw /readyz
# ok
```

## Step 2 · 建立稳态基线

**做什么**：把稳态假设的三条款各测一遍，记下时间戳。

```bash
# [master]
date '+%F %T'
# 2026-08-22 10:12:03（示例，记入执行日志）

kubectl -n chaos-demo get deploy chaos-demo
# NAME         READY   UP-TO-DATE   AVAILABLE   AGE
# chaos-demo   2/2     2            2           8m

NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
curl -sG "http://${NODE_IP}:30900/api/v1/query" \
  --data-urlencode 'query=sum(rate(demo_http_requests_total{code=~"5.."}[5m]))/clamp_min(sum(rate(demo_http_requests_total[5m])),1e-10)' \
  | python3 -m json.tool | grep -A3 '"result"'
# 预期："result": [] 或值为 0 —— 错误率为 0，稳态成立
```

`result` 为空数组是正常的：注入前 `demo_http_requests_total{code="500"}` 这个序列还不存在（计数器从未出现过 500），`sum(rate(...))` 返回空向量。这本身就是一个值得记进日志的观察：**零错误时错误率序列不存在**，看板要考虑空向量的显示。

## Step 3 · 注入（强度阶梯）

**做什么**：先 5%，观察 2 分钟，再升到 10%。

```bash
# [master] 第一档：5%
date '+%F %T'
kubectl -n chaos-demo exec deploy/chaos-demo -- python3 -c \
  "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8000/set?fail_rate=0.05&latency_ms=0').read().decode())"
# {"fail_rate": 0.05, "latency_ms": 0}

# 2 分钟后第二档：10%
date '+%F %T'
kubectl -n chaos-demo exec deploy/chaos-demo -- python3 -c \
  "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8000/set?fail_rate=0.1&latency_ms=0').read().decode())"
# {"fail_rate": 0.1, "latency_ms": 0}
```

**为什么要阶梯**：爆炸半径控制不只是"影响哪些资源"，也是"影响多深"。第一档是给系统（和你自己）留的观察期——如果 5% 就触发了意外的连锁反应，你在 10% 之前就能停下来。

## Step 4 · 观测并回填执行日志

**做什么**：按观测点表逐条记录。示例日志（你的时间戳与数值会不同）：

| 时间 | 动作/观测 | 结果 |
|---|---|---|
| 10:12:03 | 采集稳态基线 | READY 2/2；错误率空向量；`demo_fail_rate` 0 |
| 10:13:40 | 注入 fail_rate=0.05 | 返回 `{"fail_rate": 0.05, ...}` |
| 10:14:10 | 查错误率（1m 窗口） | ~0.052，指标可见，**MTTD ≈ 30s** |
| 10:15:45 | 加档 fail_rate=0.1 | 返回 `{"fail_rate": 0.1, ...}` |
| 10:16:20 | 查 `demo_fail_rate` | 0.1（注入状态与预期一致） |
| 10:16:30 | 查 5m 错误率 | ~0.08（新旧数据混合，符合预期） |
| 10:17:00 | 查 /api/v1/alerts | 未配置燃烧率告警——**无人会被通知**（本演练的关键发现） |
| 10:18:00 | 触发回滚 | 见 Step 5 |

核心命令回顾：

```bash
# [master] 业务错误率（1m 窗口，反应最快）
curl -sG "http://${NODE_IP}:30900/api/v1/query" \
  --data-urlencode 'query=sum(rate(demo_http_requests_total{code=~"5.."}[1m]))/clamp_min(sum(rate(demo_http_requests_total[1m])),1e-10)'

# [master] 注入状态
curl -sG "http://${NODE_IP}:30900/api/v1/query" --data-urlencode 'query=demo_fail_rate'

# [master] 告警状态
curl -s "http://${NODE_IP}:30900/api/v1/alerts" | python3 -m json.tool | grep -E '"alertname"|"state"' | head
```

**这个演练最有价值的输出**：如果只做了路线 A 而没配任何错误率告警，你会发现"10% 错误率、持续 5 分钟、无任何通知"——这正是开场场景里那次事故的复刻。把它写进 postmortem 的根因分析。

## Step 5 · 回滚与验证稳态回归

```bash
# [master]
date '+%F %T'
kubectl -n chaos-demo exec deploy/chaos-demo -- python3 -c \
  "import urllib.request as u; print(u.urlopen('http://127.0.0.1:8000/set?fail_rate=0&latency_ms=0').read().decode())"
# {"fail_rate": 0.0, "latency_ms": 0}

kubectl get --raw /readyz
# ok   <- 中止条件 2 未触发，集群无恙

kubectl -n chaos-demo get pods
# 3 个 Pod 全部 Running —— 资源层面从未受影响

curl -sG "http://${NODE_IP}:30900/api/v1/query" --data-urlencode 'query=demo_fail_rate' | grep demo_fail_rate
# "value": ["<ts>", "0"]   <- 注入已清除
```

错误率指标会随窗口滑动在几分钟内回到 0（1m 窗口约 1 分钟，5m 窗口约 5 分钟），这也是要记录的"恢复时间"——注意区分**配置恢复**（fail_rate=0，立即）与**可观测恢复**（比率归零，随窗口滞后）。

## Step 6 · 写 postmortem.md（无责模板）

**做什么**：按模板复盘。可直接套用的示例（改成你的真实数据）：

```markdown
# [master] 保存为 ~/labs/02-chaos-drill/postmortem.md
# Postmortem · chaos-demo 错误率注入演练复盘（无责 / blameless）

> 日期：2026-08-22 ｜ 作者：<你的名字> ｜ 状态：行动项跟踪中
> 性质：计划内混沌演练（非生产事故），本文按事故复盘标准撰写以演练流程本身。

## 摘要
本次演练在 chaos-demo 命名空间注入 10% 的 5xx 错误率，持续约 4 分钟。
服务进程与集群组件全程未受影响；确认指标层 30 秒内可见故障（MTTD 良好），
但当前没有覆盖该服务错误率的告警，故障期间不会产生任何通知（MTTD 依赖人盯）。

## 影响
- 受影响对象：chaos-demo 服务返回 5xx 的比例升至 ~10%，使用方 load-gen 收到错误响应
- 未受影响：集群组件、其他命名空间、节点资源（Pod 无重启，readyz 全程 ok）
- 预算影响：按 lab 01 的 99.9% 可用性 SLO 折算，4 分钟的 10% 错误率
  消耗约 0.024% 的 30 天 error budget（4min x 10% / 43200min，远未超支）

## 时间线（事实与时刻，不写责任人）
- 10:12:03 稳态基线采集完成：READY 2/2，错误率 0
- 10:13:40 注入 fail_rate=0.05
- 10:14:10 错误率指标（1m 窗口）读数 ~0.052，故障可观测
- 10:15:45 加档至 fail_rate=0.1
- 10:17:00 检查 /api/v1/alerts：无任何告警覆盖此故障
- 10:18:00 触发回滚，/set fail_rate=0
- 10:18:05 demo_fail_rate 确认为 0；1m 错误率约 1 分钟后归零

## 根因分析
1. 为什么故障不会触发通知：该服务未配置错误率/燃烧率告警——
   监控覆盖在"有指标、无告警"状态，错误率的发现完全依赖人工巡检。
2. 为什么流程上没人发现缺口：上线检查清单只检查"指标已采集"，
   不检查"关键 SLI 有告警兜底"。
3. 为什么演练能发现：稳态假设被显式声明后，"谁/什么在守护这个稳态"
   成为必答题，缺口自然暴露。

## 做对了什么 / 运气成分
- 做对了：先方案后注入；强度阶梯（5% -> 10%）；爆炸半径全程收窄在单命名空间
- 运气成分：注入接口本身无鉴权（/set 任何能访问服务的人都能调用），
  演练环境无所谓，但同类设计若带入生产会成为风险点

## 行动项
- [ ] AI-001 为 chaos-demo 配置可用性燃烧率告警（参照 lab 01 的
      SloDemoAvailabilityFastBurn 模板）——负责人：自己 / 截止：本周内
- [ ] AI-002 在服务上线检查清单中加入"关键 SLI 必须有告警"一栏——
      负责人：平台组 / 截止：两周内
- [ ] AI-003 评估为 /set 类注入接口增加开关（环境变量或 NetworkPolicy 限制）——
      负责人：自己 / 截止：下个迭代

## 经验教训
- "有指标"不等于"有监控"；监控的闭环以告警/通知为终点
- MTTD 要靠演练度量，不能靠信心
- 中止条件写在方案里，比写在事故里便宜得多
```

**为什么时间线不写人名**：无责复盘的前提是"对事不对人"。写"某人执行了 X"会让后续参与者隐瞒信息；写"10:13:40 注入 fail_rate=0.05"保留全部信息量，且根因分析自然导向系统与流程。

## 路线 B（可选）：集群层 DNS 故障

用 `scripts/faults/break-dns-config.sh` 演练"Pod 级 DNS 配置损坏"场景。爆炸半径同样是自带的：脚本只建 `fault-dns` 命名空间的演示 deployment 并给它注入错误 `dnsConfig`，其他命名空间不受影响。

```bash
# [master] 需要 scripts/ 仓库在本机；先采集稳态
kubectl -n fault-dns get pods 2>/dev/null || echo "fault-dns 尚不存在（正常，脚本会创建）"

# 注入
sudo bash scripts/faults/break-dns-config.sh

# 观测点：只有 fault-dns 命名空间解析失败，CoreDNS 本身无恙
kubectl -n fault-dns exec deploy/fault-dns-client -- nslookup kubernetes.default
# 预期：connection timed out; no servers could be reached

# 对照观测点：其他命名空间正常
kubectl run -it --rm dns-probe --image=busybox:1.36 --restart=Never -- nslookup kubernetes.default
# 预期：正常解析到 10.96.0.1（这证明故障是 Pod 级 dnsConfig，而非 CoreDNS 宕机）

# 恢复
sudo bash scripts/faults/break-dns-config.sh --restore
```

走路线 B 时，postmortem 的根因会完全不同（"为什么一个 namespace 级的 DNS 配置错误没有任何告警覆盖"），正好对照学习：**同一套演练流程，换个故障面就能复用**——这正是把稳态/爆炸半径/观测点/中止条件写成固定章节的意义。

## Step 7 · 运行检查脚本

```bash
# [master]
cd ~/labs/02-chaos-drill
chmod +x check.sh
./check.sh
```

通过时的输出（11 项）：

```
PASS: drill-plan.md 存在且非空
PASS: 演练方案包含「稳态假设」章节
PASS: 演练方案包含「爆炸半径」章节
PASS: 演练方案包含「观测点」章节
PASS: 演练方案包含「中止条件」章节
PASS: postmortem.md 存在且不少于 30 行（当前 48 行）
PASS: 复盘包含「时间线」与「影响」章节
PASS: 复盘包含「根因」章节
PASS: 复盘「行动项」用勾选格式列出且不少于 2 条（当前 3 条）
PASS: deployment/chaos-demo Ready 副本 >= 1（当前 2）——稳态已恢复
PASS: 故障注入已清除（demo_fail_rate 为 0）

SCORE: 11/11
```

## 收尾

```bash
# [master] 彻底清理演练环境（check 通过之后才做）
kubectl delete -f app.yaml
# 路线 B 的残留（如果跑过）：
sudo bash scripts/faults/break-dns-config.sh --restore
kubectl delete ns fault-dns --ignore-not-found
```

保留 `drill-plan.md` 与 `postmortem.md`——下一次演练的模板就从这两份文件改起，这是演练能沉淀为组织资产的唯一方式。
