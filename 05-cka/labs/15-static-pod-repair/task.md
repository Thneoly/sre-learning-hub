# Lab 15 · 静态 Pod 修复
> 难度：★★ ｜ 考点：CKA-排错（static Pod / kubelet manifest 目录） ｜ 前置：kubeadm 集群已就绪 ｜ 预计 25 分钟
> 运行位置：需要 ssh 到 **master 节点**（练习环境为单节点集群，static Pod 目录 `/etc/kubernetes/manifests` 在 master 上；若为多节点，本 lab 的操作节点就是部署了该 static Pod 的节点）

## 场景

一位同事想把一台 nginx 静态 Pod 从节点上"临时挪走备份"，于是：

- 把 `/etc/kubernetes/manifests/static-web.yaml` 移到了 `/tmp/static-web-broken.yaml`；
- 顺手把 Pod 名改成了 `Static-Web`，image 改成了 `NGINX:1.27-Alpine`。

结果：Pod 消失了。而且就算把文件放回去，kubelet 也一直拒绝这个 manifest。你需要**修好这份 manifest 并把它放回原位**，最终让静态 Pod 重新 Running。

## 任务清单

1. 故障现场还原（若 `/tmp/static-web-broken.yaml` 不存在，用下面的内容创建）：

```yaml
# [master] 写入 /tmp/static-web-broken.yaml
apiVersion: v1
kind: Pod
metadata:
  name: Static-Web
spec:
  containers:
  - name: web
    image: NGINX:1.27-Alpine
```

2. 在 master 上检查 kubelet 的 staticPodPath（`/var/lib/kubelet/config.yaml` 里的 `staticPodPath` 字段，kubeadm 默认 `/etc/kubernetes/manifests`），确认 manifest 该放回哪里。
3. 找出这份 manifest 里的**两处**非法字段并修复（提示：都是大小写问题——但 Pod 命名规范和 Docker image 命名规范是两个不同的规范）。image 修成小写的 `nginx:1.27-alpine`。
4. 把修好的 manifest 放回 `/etc/kubernetes/manifests/static-web.yaml`。
5. 验证：`kubectl get pods` 里出现 `static-web-<节点名>` 且为 `Running`；用 `-o yaml` 查看 `ownerReferences`，确认它由 kubelet（Node）管理——这是静态 Pod 的身份证明。

## 验收标准

- `/etc/kubernetes/manifests/static-web.yaml` 存在，name 为 `static-web`，image 为 `nginx:1.27-alpine`。
- `kubectl get pod static-web-<node>` 为 `Running`。
- `ownerReferences.kind` 为 `Node`。
- `/tmp/static-web-broken.yaml` 里的坏文件不得再留在 manifests 目录（kubelet 不会读 /tmp，无需删除，但别把坏文件直接拷回去）。

## 提示（卡住再看）

<details><summary>提示 1：Pod name 的合法字符集</summary>

DNS 子域名规则：小写字母数字与 `-`，不允许下划线和大写。`Static-Web` 非法，kubelet 在 manifest 校验阶段直接丢弃，`journalctl -u kubelet` 里能看到 `failed to add api object` / `name must consist of lower case` 类报错。

</details>

<details><summary>提示 2：image 大写为什么拉不动</summary>

Docker registry 的 image 名与 tag 只允许 `[a-z0-9._-]`。`NGINX:1.27-Alpine` 会报 `invalid reference format`，Pod 卡在 `ImagePullBackOff` 或直接创建失败。改成 `nginx:1.27-alpine` 即可。

</details>

<details><summary>提示 3：静态 Pod 的名字为什么带节点后缀</summary>

kubelet 读取 manifest 后，以 `metadata.name + "-" + <nodeName>` 创建 Pod（如 `static-web-cka-node1`），并由 kubelet 直接向 API Server 注册（不经 scheduler 调度）。同一份 manifest 放到不同节点，会各生成一个 Pod——这就是 static Pod 天然"每节点一个"的机制。

</details>
