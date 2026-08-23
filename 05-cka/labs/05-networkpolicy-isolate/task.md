# Lab 05 · NetworkPolicy 命名空间内微隔离

> 难度：★★★ ｜ 考点：CKA-网络（NetworkPolicy） ｜ 前置：lab 03 ｜ 预计 30~45 分钟

## 场景

计费系统部署在 `lab05-netpol` namespace：

- `billing-api`（app=billing-api）：计费核心服务，nginx:1.27，端口 80，内含敏感数据；
- `report-job`（app=report-job）：报表任务，busybox 常驻，需要对账单接口发起 HTTP 请求；
- `audit-tool`（app=audit-tool）：审计工具，busybox 常驻，**不应**访问计费服务。

另外，外部还有一个 `lab05-other` namespace，里面跑着 `ops-client`（app=ops-client，busybox 常驻）。

安全要求（零信任风格）：

1. `lab05-netpol` 内默认禁止一切入站流量（default-deny）；
2. 只允许 `report-job` 访问 `billing-api` 的 TCP 80 端口；
3. `audit-tool` 和 `lab05-other` 里的 `ops-client` 都必须访问不通。

CNI 为 Calico（kubeadm 练习集群默认），支持标准 NetworkPolicy。

## 任务清单

1. 创建 namespace `lab05-netpol` 和 `lab05-other`，并按上述规格创建 4 个 Pod（billing-api 用 nginx:1.27 并暴露 containerPort 80；busybox Pod 用 `sleep 3600` 保活，建议 `kubectl run` 创建）。
2. 为 `billing-api` 创建 ClusterIP Service `billing-api`（port 80 → 80）。
3. 创建策略 `default-deny-ingress`：namespace 内所有 Pod 的入站流量全部拒绝（policyTypes 只含 Ingress，无 ingress 规则）。
4. 创建策略 `allow-report-to-billing`：只允许 podSelector `app=report-job` 的入站访问 `app=billing-api` 的 TCP 80。
5. 验证三组连通性：report-job 通、audit-tool 不通、ops-client 不通。

## 验收标准

- `kubectl -n lab05-netpol get networkpolicy` 显示两条策略，AGE 正常
- `kubectl -n lab05-netpol exec report-job -- wget -q -T 3 -O- http://billing-api` 返回 nginx 页面
- 同样方式在 `audit-tool`、以及 `lab05-other` 的 `ops-client`（目标用 FQDN `billing-api.lab05-netpol.svc.cluster.local`）上执行，均超时失败（命令非零退出）
- 注意：策略叠加规则是"并集放行"，default-deny 不会抵消 allow 策略

运行判分脚本：

```bash
# [master]
cd 05-cka/labs/05-networkpolicy-isolate
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：default-deny 的写法</summary>

NetworkPolicy 是"白名单"模型：Pod 一旦被任意一条 Ingress 策略选中，就只放行策略里写明的流量。空 `podSelector: {}` 表示选中 namespace 内全部 Pod；不带 `ingress` 字段表示什么都不放行。
</details>

<details><summary>提示 2：跨 namespace 的流量怎么界定</summary>

`from.podSelector` 只匹配**同 namespace** 的 Pod；要匹配其他 namespace 需要 `namespaceSelector`（或两者组合）。本 lab 的 allow 规则只需 podSelector；而 ops-client 属于其他 namespace，天然不会被该规则放行——想清楚这一点就理解了 from 的语义。
</details>

<details><summary>提示 3：busybox 里用什么测 HTTP</summary>

busybox 自带 `wget`：`wget -q -T 3 -O- http://目标`。`-T 3` 是 3 秒超时，被 NetworkPolicy 拒绝的连接不会立刻 RST，而是"吊住"，超时返回非零正是被墙的表现。
</details>
