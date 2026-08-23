# Lab 03 · 解答：Service 暴露（NodePort）

## 步骤 1：Deployment（3 副本 nginx）

```yaml
# [master] cat > front-web.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: front-web
  namespace: lab03-nodeport
  labels:
    app: front-web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: front-web
  template:
    metadata:
      labels:
        app: front-web
    spec:
      containers:
      - name: front-web
        image: nginx:1.27
        ports:
        - name: http
          containerPort: 80
EOF
kubectl create namespace lab03-nodeport
kubectl apply -f front-web.yaml
```

为什么：给 containerPort 起名 `http` 后，Service 的 `targetPort` 可以直接写名字（本 lab 按要求写数字 80），名字方式在容器改端口时无需改 Service，是生产推荐写法。

验证：

```text
# [master]
$ kubectl -n lab03-nodeport get pods -o wide
NAME                        READY   STATUS    RESTARTS   AGE   IP            NODE
front-web-6d4c9c7f5-2mz8v   1/1     Running   0          30s   10.244.0.15   master
front-web-6d4c9c7f5-8tq4k   1/1     Running   0          30s   10.244.0.16   master
front-web-6d4c9c7f5-dp9x2   1/1     Running   0          30s   10.244.0.14   master
```

## 步骤 2：Service（NodePort 30080）

```yaml
# [master] cat > front-web-svc.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: front-web-svc
  namespace: lab03-nodeport
spec:
  type: NodePort
  selector:
    app: front-web
  ports:
  - protocol: TCP
    port: 80
    targetPort: 80
    nodePort: 30080
EOF
kubectl apply -f front-web-svc.yaml
```

为什么：

- `type: NodePort` 会在 ClusterIP 的基础上，让每个节点在 `nodePort` 端口上把流量 NAT 到 Service；
- 不指定 `nodePort` 时 API Server 自动分配 30000-32767 的端口；指定固定值要求该端口未被占用，否则 Service 创建报错。

验证：

```text
# [master]
$ kubectl -n lab03-nodeport get svc front-web-svc
NAME            TYPE       CLUSTER-IP      PORT(S)        AGE
front-web-svc   NodePort   10.96.184.207   80:30080/TCP   10s

$ kubectl -n lab03-nodeport get endpoints front-web-svc
NAME            ENDPOINTS                                        AGE
front-web-svc   10.244.0.14:80,10.244.0.15:80,10.244.0.16:80    10s
```

三个 Pod IP 全部进了 Endpoints，说明 selector 匹配成功。Endpoints 对象由 EndpointSlice/Endpoints 控制器维护，`<none>` 即"选不到任何 Pod"。

## 步骤 3：集群外访问验证

```bash
# [master]
curl -s http://127.0.0.1:30080 | head -5
```

```html
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
...
```

再用节点 IP 从你的 Windows 工作站验证（练习集群 master IP 以实际为准）：

```bash
# [本地Windows]
curl http://172.30.30.21:30080
```

多次请求会轮流命中不同 Pod，可加 `-i` 观察响应；更直观的方式是给每个 Pod 写不同 index.html，本 lab 不要求。

流量路径：

```text
客户端 ──> 节点IP:30080 ──> kube-proxy(iptables/ipvs NAT) ──> ClusterIP:80 ──> Pod:80
              (任一节点)                                    (负载均衡到 Endpoints)
```

## 步骤 4：制造一次 Endpoints 为空（对比实验，做完即删）

```bash
# [master]
kubectl -n lab03-nodeport create svc clusterip wrong-svc --tcp=80:80 \
  --selector=app=front-webx
kubectl -n lab03-nodeport get endpoints wrong-svc    # ENDPOINTS 为 <none>
kubectl -n lab03-nodeport delete svc wrong-svc
```

结论：selector 是纯字符串精确匹配；Service 存在但 Endpoints 为空时，curl 会 hang/超时，因为 NAT 目标列表为空。

## 步骤 5：运行判分脚本

```bash
# [master]
cd 05-cka/labs/03-service-nodeport
chmod +x check.sh
./check.sh
```

通过结果：

```text
PASS: namespace lab03-nodeport 存在且 Active
PASS: deployment front-web 期望副本数为 3
PASS: deployment front-web readyReplicas 为 3
PASS: service front-web-svc 类型为 NodePort
PASS: service port 为 80
PASS: service targetPort 为 80
PASS: nodePort 为 30080
PASS: selector 匹配 app=front-web
PASS: endpoints 有 3 个后端 IP
PASS: curl http://<node_ip>:30080 返回 nginx 页面

SCORE: 10/10
```

## 考点回顾

- 四种 Service 类型：ClusterIP（默认）、NodePort、LoadBalancer（在 NodePort 之上叠加 LB）、ExternalName（DNS CNAME，无代理）。改类型用 `kubectl patch` 或 `kubectl expose` 直接指定。
- `kubectl expose deployment front-web --type=NodePort --port=80 --target-port=80 --name=front-web-svc` 是命令行等价写法，但固定 nodePort 必须改 YAML 或 patch。
- NodePort 的局限：任何节点可达但端口范围受限、无 TLS 卸载，生产上通常只作为 ingress controller / LB 的底层入口。
