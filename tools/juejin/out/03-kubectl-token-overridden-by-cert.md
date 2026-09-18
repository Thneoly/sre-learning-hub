---
title_juejin: kubectl 传个假 token 也能 get nodes？你的权限测试一直在测个寂寞
title_zhihu: 客户端证书优先于BearerToken——你的K8s权限测试可能在测空气
description: 当kubeconfig里有admin证书时，--token参数会被静默忽略——你以为在测SA权限实际测的是admin。三个弯路+curl裸测+五种正确验证方式。30秒自检命令附文内。
category_id: "6809637769959178254"
tags: "Kubernetes,安全"
---
# kubectl 传个假 token 也能 get nodes？你的权限测试一直在测个寂寞

> 给 77 个 Kubernetes 实验做真机测试踩到的第三个"照文档写必挂"的坑（前两个：《把 apiserver 干瘫了 7 分钟》《tcp_tw_reuse=2 配了个寂寞》，在我主页）。**它会让你的安全测试完全失效，且毫无察觉。**
>
> 先说清楚：**这不是 Kubernetes 的漏洞，API Server 行为完全正确**——是 kubeconfig 里的客户端证书在替你认证，token 只是被忽略了。仅当 kubeconfig 含 `client-certificate` 时发生（exec / 云插件无此坑）。

## 假 token，真节点

```bash
$ kubectl --token=this-is-not-a-real-token-at-all get nodes
NAME              STATUS   ROLES           AGE   VERSION
control-plane-1   Ready    control-plane   30d   v1.35.0
```

瞎编的 token 列出了全部节点——**你的权限测试一直在测个寂寞**。回头看教科书级"正确"的实验。

## 场景：看似无懈可击

CKA/CKS 备考经典题：验证 SA 的 RBAC 权限：

```bash
# 1. 只有 pod 读权限的 SA
kubectl create serviceaccount pod-reader
kubectl create role pod-reader --verb=get,list --resource=pods
kubectl create rolebinding pod-reader --serviceaccount=default:pod-reader --role=pod-reader

# 2. 拿 SA token（kubectl ≥ 1.24；默认 1 小时过期，--duration 可调）
TOKEN=$(kubectl create token pod-reader)

# 3. 验证权限
kubectl --token=$TOKEN get pods      # 应该成功
kubectl --token=$TOKEN get nodes     # 应该 Forbidden
```

合理对吧？但在**已用 admin.conf 认证的终端**上：SA 居然能列出所有节点，RBAC 白配了。

## 追查：三个弯路

先怀疑 RoleBinding 绑错 namespace——重建，还是能；再怀疑 token 拿错——重取，还是能；直到 curl 裸测拿到 403：**问题不在集群，在我的终端里躺着一张 admin 证书。**

## 真相大白：curl 裸测

```bash
# master 节点；单 master kubeadm 示例，HA/云托管请替换 endpoint
TOKEN=$(kubectl create token pod-reader)   # 默认 1 小时过期
API="https://$(kubectl get endpoints kubernetes -o jsonpath='{.subsets[0].addresses[0].ip}'):6443"

# 只带 token、不带证书——真正的测试
curl -sk -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" "$API/api/v1/nodes"
# 403    ← 这才是正确的结果
```

注意：裸 `curl -sk` 收到 403 只打 JSON 错误体、退出码还是 0，没法断言，`-w '%{http_code}'` 才能判 200/403；token 必须是真实 SA token，garbage 会 401。

## 根因：客户端证书优先于 Bearer Token

kubectl 不会二选一——**证书在 TLS 握手里，token 在 HTTP 头里，同时上线，裁决在服务端。**为什么 `--token` 能盖掉 auth-provider 的 token（同一字段位，历史 bug #44476 修过）却盖不掉证书？证书在另一层。

同时指定 `--token` 和含证书的 kubeconfig 时，认证链如下（当前的**实现顺序** requestheader → x509 → token，非文档化契约，官方只承诺"第一个成功者生效"）：

```text
请求到达 API Server
    ↓
认证器逐个尝试：
  1. 客户端证书（x509）   ← admin.conf 里命中，身份 = kubernetes-admin（组：system:masters）
  2. Bearer Token 链       ← SA / OIDC / webhook / token file，你的 --token 在这里，被跳过
    ↓
认证通过身份 = kubernetes-admin（不是你的 SA）
    ↓
RBAC：system:masters 组被 cluster-admin ClusterRoleBinding 授权，什么都能看
```

（省略实际最先尝试的 requestheader 认证器）

**证书一旦命中，Bearer Token 直接被忽略**——真 token、假 token，都是 admin 在查。**有证书的连接里，token 是摆设。**

## 正确的验证方式

| 方法 | 命令 | 原理 / 边界 |
|---|---|---|
| **curl + Bearer only** | 上面那条 curl | 只带 token，输出直接断言 200/403 |
| **空 KUBECONFIG** | `KUBECONFIG=/dev/null kubectl --server=$API --insecure-skip-tls-verify=true --token=$TOKEN get nodes` | 不加 TLS 参数会死在证书校验；insecure 仅测试用，生产用 `--certificate-authority` |
| **专用 kubeconfig** | `kubectl config set-credentials sa --token=$TOKEN` + set-cluster/set-context | SA 专用最小配置，可进 CI |
| **auth whoami**（v1.28+） | `kubectl --token=$TOKEN auth whoami` | 直接回答"我是谁" |
| **auth can-i --as** | `kubectl auth can-i get nodes --as=system:serviceaccount:default:pod-reader` | 需 impersonate 权限；只答 RBAC 层面，projected token 可能有偏差 |

## 为什么很危险

1. 脚本用 SA token 验证最小权限，测试通过；
2. 但脚本跑在有 admin 证书的环境里——**你测的一直是 admin 的权限，不是 SA 的**；
3. 上线当晚 Pod 起不来，Event 里一排 `Forbidden`——SA 根本没有它需要的权限，而你的测试只测过 admin。

等于拿老板的工卡测实习生的门禁。

## 核心认知

```text
API Server 认证不是"多因素叠加"，是"逐个尝试，第一个命中的生效"
    ↓
有证书的连接里，token 是摆设
```

CKS 考试就爱在这儿挖坑——认证链优先级是安全审计的基本功。

> **如果你的测试只有"能做"没有"不能做"，等于没测。**

## 教训

| 要点 | 说明 |
|---|---|
| **`--token` 不是"切换身份"** | 只是往认证链加了个候选者 |
| **证书优先于 token** | 当前实现顺序（requestheader → x509 → token），非文档化契约 |
| **测权限用 curl 或 `--as`** | 别在有 admin 证书的环境用 `--token` |
| **要验证"拒绝"** | "能做"和"不能做"都要有断言 |

## 花 30 秒自测

在 master 上跑 `kubectl --token=garbage12345 get nodes`——返回了节点列表？你的权限测试一直在测个寂寞，回去把脚本换成 curl 或 `--as`。记住：**有证书的连接里，token 是摆设。**

说句会被喷的：`--token` 被证书静默覆盖、连个 warning 都不给，我认为这是 kubectl 的设计缺陷，不是读文档不细。同意的点赞，不同意来说服我。

---

> 📚 出自我的开源学习中心 [sre-learning-hub](https://github.com/Thneoly/sre-learning-hub)：RBAC 实验里有完整的 SA 权限验证三步法（curl 断言 200/403），全部真机跑过。在线阅读版：[thneoly.github.io/sre-learning-hub](https://thneoly.github.io/sre-learning-hub)
>
> 参考：[官方 Authentication 文档](https://kubernetes.io/docs/reference/access-authn-authz/authentication/)；https://arthurchiao.art/blog/cracking-k8s-authn/ ；kubernetes#44476；Stack Overflow #60083889
