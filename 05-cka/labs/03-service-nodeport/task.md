# Lab 03 · Service 暴露：NodePort

> 难度：★☆☆ ｜ 考点：CKA-网络（Service/Endpoint） ｜ 前置：lab 01 ｜ 预计 20~30 分钟

## 场景

测试环境里跑着一个静态站点 `front-web`，需要让集群外（你笔记本的浏览器、办公网的同事）直接访问。运维规范要求：

- Deployment `front-web`：3 副本，镜像 `nginx:1.27`，containerPort 80（name `http`）；
- Service `front-web-svc` 类型 `NodePort`：port 80 → targetPort 80，nodePort 固定 `30080`；
- 绑定到固定 nodePort 是因为防火墙只放行了 30080。

同时团队怀疑之前有个 Service "选不到 Pod"，要求你在完成暴露后顺便展示 Endpoint 关联关系作为验收证据。

## 任务清单

1. 创建 namespace `lab03-nodeport`。
2. 创建 Deployment `front-web`（labels/pod labels `app=front-web`，副本 3，容器名 `front-web`）。
3. 创建 Service `front-web-svc`：
   - `type: NodePort`
   - selector 匹配 `app=front-web`
   - `port: 80`、`targetPort: 80`、`nodePort: 30080`、protocol TCP
4. 验证：
   - `kubectl get endpoints front-web-svc` 有 3 个地址；
   - 在任意节点 `curl http://<节点IP>:30080` 返回 nginx 默认页；
   - 用一个错误的 selector（例如 `app=front-webx`）创建临时 Service，对比其 Endpoints 为 `<none>`，看懂后删除（此步不判分）。

## 验收标准

- `kubectl -n lab03-nodeport get svc front-web-svc`：TYPE `NodePort`，PORT(S) `80:30080/TCP`
- `kubectl -n lab03-nodeport get endpoints front-web-svc`：ENDPOINTS 列出 3 个 Pod IP:80
- 节点上 `curl -s http://127.0.0.1:30080` 返回 nginx 欢迎页 HTML

运行判分脚本：

```bash
# [master]
cd 05-cka/labs/03-service-nodeport
chmod +x check.sh
./check.sh
```

## 提示（卡住再看）

<details><summary>提示 1：targetPort 与 port 的区别</summary>

`port` 是 Service 自己的端口（集群内访问 `svc:80`）；`targetPort` 是后端 Pod 的 containerPort；`nodePort` 是每个节点上 kube-proxy/iptables(Calico 环境通常为 iptables/ipvs 模式的 kube-proxy) 监听的外部端口，默认合法范围 30000-32767。
</details>

<details><summary>提示 2：Endpoints 为空怎么排查</summary>

Service 的 selector 与 Pod labels 是"纯字符串精确匹配"，多一个空格或大小写不同都选不中。`kubectl -n lab03-nodeport get endpoints` 显示 `<none>` 时，用 `kubectl describe svc` 里的 `Selector` 和 `kubectl get pod --show-labels` 对比。
</details>
