---
title_juejin: '重写靠注解、灰度靠注解：Ingress 注解地狱怎么来的'
title_zhihu: 'Ingress 最成功的失败是注解：从薄标准、方言地狱到 Gateway API'
description: 'Ingress只标准化host/path/TLS，重写灰度超时全靠私有注解，nginx与traefik各写各的。Gateway API三层模型、跨ns授权、weight灰度切流、双栈迁移，一篇讲透。'
category_id: "6809637769959178254"
tags: "后端,架构"
column_id: "7686346277555683378"
---

# Ingress 注解地狱：不是大家用坏了，是标准本来就薄

> 从 Ingress 到 Gateway API｜K8s 深入理解

接手老集群的人多半见过那种 Ingress：metadata 里挂着五六个 `nginx.ingress.kubernetes.io/` 开头的注解，path 里埋着正则，旁边还蹲着一条 canary Ingress。问一句"能不能换 traefik"，答案永远是：不敢动。

这不是用坏了。是当年那版标准只画了三条线，剩下的路全是各家控制器自己修的。判断先放这儿：**Ingress 最成功的失败是注解**——标准输给了现实，生态却因此赢了十年。

## 一、标准为什么薄：只标准化了三件事

Ingress 是 2015 年随 K8s 1.1 进入主线的 API【从业者判断】。它的 spec 到今天也就覆盖三件事：按 host/path 路由到同 namespace 的 Service、TLS 终止、backend 指向谁。翻遍标准字段，找不到重写、灰度、超时、重试、header 匹配。

这不是遗漏，是设计。Ingress 的哲学与 Service 一脉相承：**API 对象只声明想要什么，干活的永远是独立部署的控制器**。标准只定义最小公约数，差异化下放给实现；下放的接口就是注解。

连"这条 Ingress 归哪个控制器管"，最早都靠 `kubernetes.io/ingress.class` 注解解决，1.18 才转正成字段——归属尚且如此，何况能力。十年下来，Ingress 的真实能力表长这样：

| 能力 | 标准字段 | 实际怎么实现 |
| --- | --- | --- |
| host/path 路由 | 有 | — |
| TLS 终止 | 有 | — |
| 路径重写 | 无 | nginx 的 rewrite-target 注解 |
| 灰度/金丝雀 | 无 | canary-weight 注解 + 独立 canary Ingress |
| 超时/重试/限流 | 无 | 各家私有注解 |

【从业者判断】"各家"=nginx、traefik、istio 等，注解名与语义互不相同，没有两家兼容。

**薄标准是 2015 年最聪明的决定，账单十年后才寄到。**

## 二、方言的真实代价：迁移等于重写

看一个最小的重写需求：`/app` 前缀转发时剥掉。ingress-nginx 的写法（前置：ingress-nginx 与 echo-v1 已就绪）：

```yaml
# kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: echo-rewrite
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2
spec:
  ingressClassName: nginx
  rules:
  - host: rewrite.local
    http:
      paths:
      - path: /app(/|$)(.*)
        pathType: ImplementationSpecific
        backend:
          service: {name: echo-v1, port: {number: 80}}
EOF
```

请求 `/app/foo`，后端收到的已是 `/foo`——剥前缀全靠那条私有注解加正则捕获组。这段配置钉着两颗钉子。

第一颗：`rewrite-target` 是 ingress-nginx 的注解，不是 Ingress 的字段，`$2` 这个捕获组编号只有 nginx 的实现认识。

第二颗：path 含正则元字符，`pathType` 必须写 `ImplementationSpecific`（或额外加 `use-regex: "true"` 注解）——名字很诚实，这块行为标准不管。traefik 对同一个 path 的解释是字符串前缀加自家 Rule 语法，跟 nginx 的 POSIX 正则不是一回事：同一段配置迁过去，转发行为会变。

所以方言的真实代价不是"写法丑"，而是**每条注解都把入口配置钉死在一个控制器上**。迁移不是全局替换前缀，是逐条重写、逐条回归——行为漂移不是 bug，是注解机制的设计后果。

## 三、Gateway API 解法一：把一个对象拆给两种角色

Ingress 的第二个结构性缺陷与注解无关但同样致命：入口的地址、证书、路由规则捏在同一个对象里。平台要管 IP 和证书，应用要改路由，两边被迫共享一个对象的读写权。

Gateway API 的解法不是加字段，是拆对象，拆成三层：

```text
GatewayClass（集群级，平台团队）——这类入口由哪个控制器实现
Gateway（ns 级，平台团队）——listeners 端口/证书、allowedRoutes 放行范围
HTTPRoute（ns 级，应用团队）——hostnames + matches + backendRefs
# HTTPRoute ──parentRefs──▶ Gateway ──gatewayClassName──▶ GatewayClass
```

角色分离落在三个机制上。

其一，RBAC 分家：平台持有 GatewayClass/Gateway 的权限，管 IP、证书、全局策略；应用建 HTTPRoute 只管路由，互相看不见对方对象。

其二，跨 namespace 默认拒绝。路由要挂到别的 ns 的 Gateway，需要那个 Gateway 的 `allowedRoutes` 放行；HTTPRoute 要引用别的 ns 的 Service 当后端，需要对方 ns 里建一条 `ReferenceGrant`。两个方向都是"对象能建，效果要被显式批准"。

其三，双向 status。parentRefs 上有 Accepted/ResolvedRefs 条件，接没接纳一眼可见（前置：Gateway lab-gw 与路由已建好，模板在仓库 04 模块第 6 篇）：

```bash
kubectl get httproute echo-route -o jsonpath='{.status.parents[0].conditions}' | head -c 300; echo
# type=Accepted status=True —— Gateway 已接纳，回执写在 status 里
```

Ingress 是"创建了但不通只能翻日志"，**Gateway API 把验收回执写进了对象本身**。

## 四、Gateway API 解法二：方言变语法

Gateway API 建成 CRD，好处直接：常用能力做成正经字段，带类型、带校验、跨实现行为一致。最典型的是灰度——Ingress 体系要 canary 注解加一条独立 canary Ingress；Gateway API 里同一条 rule 放两个 backendRefs，各带 weight（缺省 1，0 表示不接新流量但留在池里）：

```yaml
# kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: echo-split
spec:
  parentRefs:
  - name: lab-gw
  hostnames: ["gw.local"]
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: echo-v1
      port: 80
      weight: 90
    - name: echo-v2
      port: 80
      weight: 10
EOF
```

```bash
# 裸金属：Envoy 的 Service 默认 LoadBalancer，先改 NodePort（云上跳过）
kubectl -n default patch svc -l gateway.envoyproxy.io/owning-gateway-name=lab-gw -p '{"spec":{"type":"NodePort"}}'
GW_PORT=$(kubectl -n default get svc -l gateway.envoyproxy.io/owning-gateway-name=lab-gw -o jsonpath='{.items[0].spec.ports[?(@.port==80)].nodePort}')
NODEIP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
for i in $(seq 1 40); do curl -s -H 'Host: gw.local' "http://$NODEIP:$GW_PORT/"; done | sort | uniq -c
# 36 hello-from-v1
#  4 hello-from-v2

kubectl patch httproute echo-split --type=json \
  -p='[{"op":"replace","path":"/spec/rules/0/backendRefs/0/weight","value":0}]'
# v1 weight=0：不接新流量但规则还在——回切就是把数字改回去，一次 API 调用
```

同样的收编还发生在别处：header 匹配进了 matches，超时重试进了规范，协议有 GRPCRoute/TLSRoute/TCPRoute/UDPRoute 统一建模，连 pathType 的模糊语义都被收紧——path type 是枚举，不再有 ImplementationSpecific。

**灰度从"一条私有注解"变成"两个 weight 数字"**，这才是可移植的真正含义。

## 五、生态与双栈：格局已定，双轨为常

Gateway API 的核心对象 Gateway/GatewayClass/HTTPRoute 已是 v1（GA），Envoy Gateway、NGINX Gateway Fabric、Istio、Traefik、Cilium 均已实现；Ingress 这边存量巨大，且所有控制器都支持。生态之战已经打完，剩下的是你自己集群里的节奏问题。

选型可以很干脆：存量维护与考试（CKA）以 Ingress 为准，新项目、多团队共享平台优先 Gateway API；同一集群两者可并存，各占各的端口和 IP。

【从业者判断】"等实现跟上再说"已经不成立——现用的控制器大概率已支持，剩下的只是什么时候开始用。

【从业者判断】落地不必立项"大迁移"：新域名直接走 HTTPRoute，老域名按变更节奏逐条搬、搬一条删一条注解；再按注解依赖分级，零注解先搬，正则加 canary 最后搬。

**这不是一个迁移项目，是一段以年为单位的双轨期。**

## 症状速查：先存这张表

| 症状 | 根因 | 第一动作 |
| --- | --- | --- |
| Ingress 建了但 ADDRESS 为空 | 没装控制器，或 ingressClassName 不匹配 | kubectl get ingressclass 核对 |
| HTTPRoute 建了不生效 | parentRefs 指错，或被 allowedRoutes 拒 | 看 status.parents.conditions |
| Gateway 一直无地址 | GatewayClass 没人认领 | kubectl get gatewayclass -o wide |

## 一分钟版本

> **背这段（约一分钟）**
>
> Ingress 只标准化了 host/path 路由、TLS、backend 三件事，重写、灰度、超时全下放成私有注解——能力够用，但每条注解都把配置钉死在单一控制器上，迁移等于重写。
>
> Gateway API 用三层对象拆角色：平台管 GatewayClass/Gateway，应用管 HTTPRoute，跨 ns 靠 allowedRoutes/ReferenceGrant 显式授权、默认拒绝，接纳状态写进 status。
>
> backendRefs 的 weight 是规范字段，90/10 灰度、weight=0 秒级回切是标准行为。核心对象 v1 GA；存量走 Ingress、新项目走 Gateway API，双栈并存是常态。

## 现在就能做的事

三档任选：

- 零门槛档：数一数你生产 Ingress 上的注解条数，超过 3 条的每条问一句"换控制器时它怎么办"——数完就知道被钉得多深。
- 动手档：把第二节的 rewrite Ingress 与第四节的 90/10 切流各跑一遍，再 patch weight=0 感受一次秒级回切。
- 迁移档：给存量 Ingress 按注解依赖分级，列一张双轨时间表，零注解的本周就能搬。

一句话收束：**Ingress 最成功的失败是注解**。标准化输给了现实，但正是注解的自由度让每个控制器长出自己的生态，Ingress 才活成事实标准。

Gateway API 的聪明在于不没收扩展，只把最常用的部分收编成字段，再把扩展点标准化（policy attachment）——下一个十年，入口配置终于可以说"换实现不改 YAML"。

评论区聊两件事：一，你见过注解最多的 Ingress 有几条、都干嘛用的；二，你们生产上 Gateway API 了吗，卡在哪一步。我先押个注：注解超过 10 条的，评论区一定有。

K8s 深入理解系列从 Pod、Service 一路讲到入口与网关，都在专栏合集里。这一篇整理自我在维护的学习仓库，Ingress 与 Gateway API 章节带着从安装、注解对照到权重切流的完整实战演练——GitHub 搜 sre-learning-hub，觉得有用点个 star 不迷路。
