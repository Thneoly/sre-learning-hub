# Lab 05 · 解答：NetworkPolicy 命名空间内微隔离

## 步骤 1：搭建环境（两个 namespace、四个 Pod、一个 Service）

```bash
# [master]
kubectl create namespace lab05-netpol
kubectl create namespace lab05-other

kubectl -n lab05-netpol run billing-api --image=nginx:1.27 --port=80 \
  --labels=app=billing-api
kubectl -n lab05-netpol run report-job --image=busybox:1.36 \
  --labels=app=report-job -- sleep 3600
kubectl -n lab05-netpol run audit-tool --image=busybox:1.36 \
  --labels=app=audit-tool -- sleep 3600
kubectl -n lab05-other  run ops-client --image=busybox:1.36 \
  --labels=app=ops-client -- sleep 3600

kubectl -n lab05-netpol expose pod billing-api --port=80 --target-port=80 \
  --name=billing-api
kubectl -n lab05-netpol get pods,svc
```

等全部 Running 后，先确认"未加策略前全通"（这是对照组）：

```bash
# [master]
kubectl -n lab05-netpol exec audit-tool -- wget -q -T 3 -O- http://billing-api | head -3
kubectl -n lab05-other exec ops-client -- \
  wget -q -T 3 -O- http://billing-api.lab05-netpol.svc.cluster.local | head -3
```

两者此时都能拿到 nginx 页面——Kubernetes 默认不隔离任何流量。

## 步骤 2：default-deny-ingress

```yaml
# [master] cat > default-deny.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: lab05-netpol
spec:
  podSelector: {}
  policyTypes:
  - Ingress
EOF
kubectl apply -f default-deny.yaml
```

为什么：

- `podSelector: {}` 空 map = 选中 namespace 内所有 Pod；
- `policyTypes: [Ingress]` 且不写 `ingress` 字段 = "入站白名单为空"，全部拒绝；
- 出站（Egress）不受影响，report-job 依旧能发起请求（只是对端不回）。

此刻验证，三条链路全部超时（连 report-job 也通不了）：

```bash
# [master]
kubectl -n lab05-netpol exec report-job -- wget -q -T 3 -O- http://billing-api
# wget: download timed out   （命令退出码非 0）
```

## 步骤 3：allow-report-to-billing

```yaml
# [master] cat > allow-report.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-report-to-billing
  namespace: lab05-netpol
spec:
  podSelector:
    matchLabels:
      app: billing-api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: report-job
    ports:
    - protocol: TCP
      port: 80
EOF
kubectl apply -f allow-report.yaml
```

为什么：

- 顶层 `podSelector` 决定策略作用在谁身上（受保护方 = billing-api）；
- `ingress.from` 决定谁能来（访问方 = report-job）；`from.podSelector` 无 namespaceSelector 修饰时只匹配**本 namespace** 的 Pod；
- `ports` 收窄到 TCP/80。

策略叠加语义（考试重点）：

```text
某 Pod 的实际入站效果 = 所有选中它的策略放行规则的【并集】
  billing-api 同时被 default-deny(空集) 和 allow(80/report-job) 选中
  并集 = {report-job -> tcp/80}，其余全部拒绝
```

## 步骤 4：验证三组连通性

```bash
# [master]
# 1) 应当通
kubectl -n lab05-netpol exec report-job -- wget -q -T 5 -O- http://billing-api | head -3
```

```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
```

```bash
# [master]
# 2) 应当不通（同 ns 但不在白名单）
kubectl -n lab05-netpol exec audit-tool -- wget -q -T 5 -O- http://billing-api
# wget: download timed out

# 3) 应当不通（跨 ns，from.podSelector 天然不匹配其他 ns）
kubectl -n lab05-other exec ops-client -- \
  wget -q -T 5 -O- http://billing-api.lab05-netpol.svc.cluster.local
# wget: download timed out
```

注意"拒绝"的表现形式：Calico 默认 DROP 而非 REJECT，客户端表现为超时挂起而不是 immediate connection refused。

## 步骤 5：运行判分脚本

```bash
# [master]
cd 05-cka/labs/05-networkpolicy-isolate
chmod +x check.sh
./check.sh
```

通过结果：

```text
PASS: namespace lab05-netpol 存在且 Active
PASS: namespace lab05-other 存在且 Active
PASS: pod billing-api 为 Running
PASS: pod report-job 为 Running
PASS: pod audit-tool 为 Running
PASS: pod ops-client 为 Running（lab05-other）
PASS: default-deny-ingress 不限定 Pod（空 selector）
PASS: default-deny-ingress policyTypes 为 Ingress
PASS: default-deny-ingress 无 ingress 放行规则
PASS: allow-report-to-billing 选中 app=billing-api
PASS: 入站来源限定 app=report-job
PASS: 放行端口为 80
PASS: 放行协议为 TCP
PASS: report-job -> billing-api:80 放行
PASS: audit-tool -> billing-api:80 被拒绝
PASS: ops-client（其他 ns） -> billing-api:80 被拒绝

SCORE: 16/16
```

## 常见坑速查

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 策略生效后"连 kubelet 探针都挂" | default-deny 连 probe 流量也拒了 | 给 probe 端口补 allow 或让 probe 走 localhost |
| 加了 allow 依旧不通 | from 写成 namespaceSelector（匹配整个 ns）或标签拼错 | `describe netpol` 逐字段核对 |
| 想放行"所有 namespace 的某标签 Pod" | from 是 AND 语义列表 | 一个 from 元素里同时写 podSelector + namespaceSelector（同元素为 AND，多元素为 OR） |
| flannel 环境策略不生效 | flannel 不支持 NetworkPolicy | 换 Calico/Cilium；考试环境已保证支持 |

## 考点回顾

- NetworkPolicy 三要素：作用对象（podSelector）、方向（policyTypes: Ingress/Egress）、白名单（ingress/egress 规则）。
- 未被任何策略选中的 Pod = 完全不隔离；被任意一条选中 = 只放行并集。
- DNS 也是出站流量：如果做了 Egress default-deny，别忘放行 `kube-dns` 的 UDP/TCP 53，否则业务连 Service 域名都解析不了。
