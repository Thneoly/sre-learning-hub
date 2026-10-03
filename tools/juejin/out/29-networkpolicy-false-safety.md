---
title_juejin: '你写的 NetworkPolicy 可能一条都没生效'
title_zhihu: '装了 NetworkPolicy 不等于有隔离，K8s 的出厂设置是全通'
description: 'K8s 默认全通、NP 白名单并集语义、flannel 静默失效、selector 交集陷阱、default-deny 分层放行、连通性验证矩阵——讲透 NetworkPolicy 的假安全感。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686472562230312970"
---
# 你写的 NetworkPolicy 可能一条都没生效：K8s 出厂就是全通的

> 先说结论：**装了 NetworkPolicy 不等于有隔离**。K8s 出厂没有 deny-all，没被策略选中的 Pod 一律全通；策略 apply 成功也不算数——CNI 不认就静默失效，selector 写错就整张白名单白做。隔离是设计与验证出来的状态，不是 apply 完自动获得的。

## 一、出厂设置：全通，而且是设计如此

K8s 对 Pod 网络只提三条要求：每 Pod 一个独立 IP、Pod 间 NAT-free 互通、节点可达所有 Pod。推论：任意两个 Pod，无论在哪个节点、哪个 namespace，IP 层直接可达。

而 NetworkPolicy 的默认姿态是「没有策略 = 不设防」：

- 集群默认没有策略，所有流量全通——K8s 出厂不带 deny-all
- 没有任何策略选中某 Pod 时，该 Pod 流量完全不受限

构造典型案例：渗透测试对一个业务 Pod 拿到 RCE，接着扫 Pod CIDR、nc 试端口——payment、redis、metrics 全在同一个平面上等着。「打穿一个 Pod」和「拿到半个集群」之间，只隔攻击者的耐心。

**打穿一个 Pod，等于递出整个 Pod 网段。** namespace 在网络层不是边界，只是个名字。

## 二、白名单语义：选中即翻转，叠加只放大

语义是「带方向的选择器＋放行列表」，三条规则读透：

1. 没有任何策略选中某 Pod → 不受任何隔离
2. 被任意一条策略的 podSelector 选中、且策略在 policyTypes 声明了该方向 → 该方向立即翻转为默认全拒，只放行明确允许的
3. 多条策略对同一 Pod 求并集——「允许的并集」之外全拒

第三条是无数事故的源头：**NetworkPolicy 是加法不是减法**。旧策略放开了 8080，新策略只放指定来源的 5432，并集是「两样都开」；想只留 5432，只能回去改掉旧策略。

另一个细节：同样是 `podSelector: {}`，写在 spec 级是「作用于 namespace 内所有 Pod」，即默认拒绝的标准写法；写在 ingress.from 里是「允许同 namespace 内所有 Pod 作为来源」。前者是作用域，后者是放行对象——位置即语义。

## 三、静默失效：apiserver 收文件，CNI 才施工

最贵的错觉：策略 apply 成功、kubectl get 查得到，于是认定隔离已生效。

但 NetworkPolicy 的落地者是 CNI——不是 kube-proxy，也不是 apiserver：apiserver 只收对象，规则由 CNI 编译到数据面，Calico 编译成 iptables 链＋ipset（或 eBPF）逐包匹配。

而 flannel 没有实现 NetworkPolicy。写了、apply 成功、没有任何报错——也不生效。这是排障第一怀疑点【从业者判断】。

```bash
# [worker1] 眼见为实：Calico 把策略编译成的 iptables 链
sudo iptables-save | grep -E 'cali-.*fw|cali-.*policy' | head
# flannel 集群上输出为空——策略从未变成数据面规则
```

CNI 选型因此有了硬约束：只要「通」，flannel 够用但要放弃 NetworkPolicy；要策略与性能，calico；要 L7 策略与 eBPF 可观测，cilium【从业者判断】。

**NetworkPolicy 的合同方是 CNI**——收了文件，不等于有人施工。

## 四、selector 错配：选错即全白做

策略「存在」且「被执行」，还不等于「如你所愿」。两类高频错配：

错配一：与/或写反。同一个 to 条目里 namespaceSelector 与 podSelector 同时出现是**与**关系；拆成两个并列条目就变成**或**。这条放 DNS 的规则一旦拆开，放行的就是整个 kube-system＋所有带 kube-dns 标签的 Pod：

```yaml
egress:
- to:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: kube-system
    podSelector:              # 同条目 = 交集
      matchLabels:
        k8s-app: kube-dns
```

顺带：kubernetes.io/metadata.name 是 K8s 给 namespace 自动打的标签，跨 ns 圈目标用它，别自己发明【从业者判断】。

错配二：策略根本没选中目标 Pod——matchLabels 与实际标签对不上，策略不命中，方向连「翻转为白名单」都不发生；没有其他策略兜底时 Pod 维持全通。

```bash
kubectl describe networkpolicy -n payment
# 看 podSelector 是否命中你以为命中的 Pod
```

**错配的杀伤力是双向欺骗：该拦的没拦，你却以为拦了。**

## 五、default-deny 的正确姿势：先全禁，再按需开

正确顺序和直觉相反：先把整个 namespace 关死，再一层层开。

```text
L0  default-deny-all       全 ns：Ingress+Egress 全禁（兜底，最先上）
L1  allow-dns              放开到 kube-system CoreDNS 的 53/UDP+TCP
L2  allow-same-ns          同 namespace 指定端口互通
L3  allow-cross-ns         跨 ns 白名单（frontend -> payment:8080）
L4  allow-egress-internet  按需放外网（IP 段/CIDR）
```

L0 的 YAML 每行都是语义：

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: payment
spec:
  podSelector: {}           # 选中 namespace 内所有 Pod
  policyTypes:
    - Ingress
    - Egress
```

apply 的瞬间整个 namespace 断网，连 DNS 都不通——这是特性不是 bug。

L1 必须立刻跟上：CoreDNS 在 kube-system，几乎每套 egress 白名单都要放 53，UDP 和 TCP 都得放——deny-all 后「连 Service 名都解析不了」，十有八九是这层没配【从业者判断】。

```bash
kubectl get networkpolicy default-deny-all -n payment -o jsonpath='{.spec.policyTypes}'
# 预期输出: [Ingress Egress]——少一个方向就不是全禁
```

【从业者判断】反方意见很正当：deny-all 一上，漏放的业务当场断，谁来背？但不上 deny-all 的团队，是在赌「全通现状里没有一条多余的连通」；上了再逐层放，赌的只是「漏放的业务立刻喊疼」。前者错了没人知道，后者当场知道——隔离这件事，错误暴露越早越便宜。

## 六、验证：临时测试 Pod＋连通性矩阵

**没亲眼看到过一次「拦」，策略就还停在纸面。**造两个临时测试 Pod，跑一张矩阵：

```bash
# [master] 一个测试 Pod 在业务 ns 内，一个在「外部」ns
kubectl run np-test --image=busybox:1.36 -n payment --restart=Never -- sleep 3600
kubectl run np-outside --image=busybox:1.36 -n default --restart=Never -- sleep 3600

# 用例 1：同 ns 白名单内 → 应能通（payment-api 存在时）
kubectl exec np-test -n payment -- nc -zv -w3 payment-api 8080 2>&1 | tail -1

# 用例 2：跨 ns 未白名单 → 应超时
kubectl exec np-outside -n default -- nc -zv -w3 payment-api.payment.svc.cluster.local 8080 2>&1 | tail -1
# 预期: 超时（open ... timed out）
```

| 用例 | 来源 → 目标 | 预期 | 验证的是 |
|---|---|---|---|
| 1 | payment 内 → payment-api:8080 | 通 | 放行规则正确 |
| 2 | default → payment-api:8080 | 超时 | deny-all 兜底生效 |
| 3 | 任意 Pod → Service 域名 | 能解析 | L1 的 DNS 放行 |

用例 2 的预期是**超时**：被策略丢弃的包表现为超时；看到解析失败或连接拒绝，先怀疑 DNS 没放、策略没命中【从业者判断】。另一个高频疑点：明明配了却两边不通——隔离是双向的，只给目标写 ingress、来源的 egress 还锁着，照样不通。

## 七、和安全合规审计的关系：要证据，不要文件

CKS 考纲里微服务漏洞最小化这一域占 20%，考法很说明问题：给一个「危险现状」——无 PSA、无 NetworkPolicy、default SA 带大权限——让你逐层修好并当场验证。考试都要求演示，审计只会更严。

【从业者判断】审计里「我们有 NetworkPolicy」这句话的含金量，取决于你能同时拿出三样东西：CNI 支持性的证明、default-deny 覆盖清单、按用例跑通的连通性矩阵。只有一堆 YAML，审计意义上等于没有。

边界声明：NetworkPolicy 工作在 L3/L4，只回答「谁可以连谁」。它不管加密——放行的流量是明文，跨节点 overlay 封装后照样明文；它不管内容——放行 8080 就是放行 8080 上的一切协议。

**网络分段过关，不等于传输安全过关**，加密与身份靠 mTLS 补位，生产环境常两者叠加。

## 教训

1. **默认全通是出厂设置**——不主动设防就是全通
2. **NP 是加法**：并集只放大放行面，收紧只能改旧策略
3. **执行者是 CNI**：flannel 写了静默失效，先确认 CNI 再写策略
4. **selector 决定生死**：与/或写反、标签不命中，都是该拦的没拦
5. **deny-all 先上、DNS 先放**；没跑过连通性矩阵的隔离，等于没有隔离

## 现在就做：60 秒自检

```bash
# 1. 你的 CNI 是谁？只有 flannel → 现有 NetworkPolicy 全是装饰品
kubectl get pods -n kube-system | grep -E 'calico|cilium|flannel'

# 2. 多少 namespace 一条策略都没有（= 默认全通）
kubectl get ns --no-headers | wc -l
kubectl get networkpolicy -A --no-headers | awk '{print $1}' | sort -u | wc -l
# 两个数字一减，就是「裸奔」namespace 数的下限（粗筛）
```

留个话头：你上一次亲眼看到 NetworkPolicy 拦下一条连接，是什么时候？答不上来的，今晚就把第 1 步跑了，评论区报个数。

本文的分层模板与验证矩阵出自我的真机实验仓库——GitHub 搜 sre-learning-hub，CKS 模块的 network-segmentation 实验有可判分版本。
