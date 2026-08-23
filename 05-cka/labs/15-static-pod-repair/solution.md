# Lab 15 · 解答：静态 Pod 修复

## 机制回顾

```
kubelet ──> 监视 staticPodPath(/etc/kubernetes/manifests, 每 20s 扫描)
              │ 文件出现/修改/删除
              ▼
        直接在本节点创建/重建/删除容器(不经过 scheduler)
              │ 并向 API Server 注册 mirror pod: <name>-<nodeName>
              ▼
        kubectl 能看到 static-web-cka-node1, ownerReferences.kind=Node
```

推论：改静态 Pod 的唯一正确方式是**改 manifest 文件**；`kubectl delete` 一个静态 Pod，kubelet 会在几秒内把它原样拉回来（考试常考：删不掉的 Pod 先想想是不是静态 Pod）。

## 第 1 步：确认 staticPodPath

```bash
# [master]
grep staticPodPath /var/lib/kubelet/config.yaml
```

预期输出：

```
staticPodPath: /etc/kubernetes/manifests
```

kubeadm 集群的 kubelet 配置在 `/var/lib/kubelet/config.yaml`，由 kubelet 从 ConfigMap 拉取；control plane 组件（apiserver/etcd/scheduler/controller-manager）本身也都是这个目录里的静态 Pod。

## 第 2 步：定位坏 manifest 的两处非法字段

```bash
# [master]
cat /tmp/static-web-broken.yaml
```

两处错误：

1. `name: Static-Web` —— Pod 名必须满足 DNS 子域名规范（小写字母数字与 `-`），大写非法。kubelet 扫描到这种 manifest 会拒绝创建，看日志：

```bash
# [master]
sudo journalctl -u kubelet --since "10 min ago" --no-pager | grep -iE "static|invalid|failed"
```

典型行：`error validating ... metadata.name: Invalid value: "Static-Web": a lowercase RFC 1123 subdomain must consist of ...`。

2. `image: NGINX:1.27-Alpine` —— registry 引用只允许小写，运行时会报 `invalid reference format` / `ImagePullBackOff`。

## 第 3 步：修复并放回

```bash
# [master]
sudo tee /etc/kubernetes/manifests/static-web.yaml >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: static-web
spec:
  containers:
  - name: web
    image: nginx:1.27-alpine
EOF
```

注意目录权限：`/etc/kubernetes/manifests` 归 root，写文件要 `sudo`；写完不需要 restart kubelet，下一次扫描周期（最长 20 秒）就会生效。

## 第 4 步：验证

```bash
# [master]
kubectl get pods
```

预期（节点名拼接在后面）：

```
NAME                     READY   STATUS    RESTARTS   AGE
static-web-cka-node1     1/1     Running   0          30s
```

确认身份与镜像：

```bash
# [master]
kubectl get pod static-web-cka-node1 -o jsonpath='{.metadata.ownerReferences[0].kind}{"\n"}{.spec.containers[0].image}{"\n"}'
# Node
# nginx:1.27-alpine
```

## 第 5 步：顺手验证"删不掉"特性（加深理解）

```bash
# [master]
kubectl delete pod static-web-cka-node1 --wait=false
sleep 5
kubectl get pod static-web-cka-node1
```

预期：删除后几秒内 Pod 重新出现（AGE 归零）。想真正下线，必须移走 manifest 文件本身。

## 常见错误回顾

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| Pod 名大写/下划线，Pod 不出现 | manifest 校验失败被 kubelet 丢弃 | journalctl 看 kubelet 报错，改 RFC1123 小写名 |
| Pod 卡在 ImagePullBackOff | image 大写或 tag 拼错 | 改成小写 `nginx:1.27-alpine` |
| `kubectl delete` 后 Pod 复活 | 静态 Pod 由 kubelet 兜底重建 | 移走 `/etc/kubernetes/manifests/` 下的 manifest |
| 改了文件没生效 | 改错目录（不是 staticPodPath） | 核对 `/var/lib/kubelet/config.yaml` 的 staticPodPath |
| 把带 namespace 的期望放 manifest | 静态 Pod 总是注册到其 manifest 所隐含的 namespace（默认 default） | 需要别的 namespace 用 DaemonSet |

## 延伸阅读

- https://kubernetes.io/docs/tasks/configure-pod-container/static-pod/

## check.sh 运行结果

```bash
# [master]
chmod 755 check.sh && ./check.sh
```

预期：

```
PASS: manifest /etc/kubernetes/manifests/static-web.yaml 存在
PASS: manifest 中 Pod name 为 static-web(小写合法)
PASS: manifest 中 image 为 nginx:1.27-alpine(小写合法)
PASS: 静态 Pod static-web-cka-node1 为 Running
PASS: 运行中 Pod 的 image 为 nginx:1.27-alpine
PASS: ownerReferences.kind=Node(确为 kubelet 管理的静态 Pod)

SCORE: 6/6
```
