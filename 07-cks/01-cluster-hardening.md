# 01 · 集群加固：CIS 基准与控制面组件参数

> 模块：CKS 备考 ｜ 建议时长：3 小时 ｜ 关联认证：CKS-Cluster Setup / CKS-Cluster Hardening / CKA-集群管理

## 学习目标

- 能用 kube-bench 对 kubeadm 集群跑 CIS 基准检查并读懂 FAIL 项
- 能解释 kube-apiserver 每个安全相关 flag 的作用并正确修改 static Pod manifest
- 能把 kube-scheduler 与 kube-controller-manager 的监听收到 127.0.0.1
- 能加固 kubelet：关 anonymous、启用 Webhook 授权、关只读端口、protectKernelDefaults
- 能从端口和服务两个维度最小化节点攻击面

## 1. CIS Benchmark 与 kube-bench

CIS Kubernetes Benchmark 是 Center for Internet Security 发布的加固清单，按组件分节：1.x 控制面（apiserver/etcd/scheduler/controller-manager）、4.x 节点（kubelet）、5.x 策略。CKS 考试明确要求"用 CIS benchmark 审查 Kubernetes 组件的安全配置"。

kube-bench（aquasecurity 出品）把 CIS 清单变成自动检查：它读取节点上的进程参数、配置文件路径和文件权限，逐条给出 PASS/FAIL。注意它只能"体检"，修复仍要你手工改配置。

在 kubeadm 单 master 集群上以 Job 方式运行（镜像与挂载来自官方 job.yaml，单 master 环境需补 tolerations 才能调度到 control-plane 节点）：

```yaml
# [master] 保存为 /root/kube-bench-job.yaml 后 kubectl apply -f /root/kube-bench-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench
spec:
  template:
    metadata:
      labels:
        app: kube-bench
    spec:
      hostPID: true
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
      restartPolicy: Never
      containers:
        - name: kube-bench
          image: docker.io/aquasec/kube-bench:v0.15.6
          command: ["kube-bench", "run", "--targets", "control-plane"]
          volumeMounts:
            - mountPath: /var/lib/etcd
              name: var-lib-etcd
              readOnly: true
            - mountPath: /var/lib/kubelet
              name: var-lib-kubelet
              readOnly: true
            - mountPath: /etc/systemd
              name: etc-systemd
              readOnly: true
            - mountPath: /lib/systemd/
              name: lib-systemd
              readOnly: true
            - mountPath: /etc/kubernetes
              name: etc-kubernetes
              readOnly: true
            - mountPath: /usr/local/mount-from-host/bin
              name: usr-bin
              readOnly: true
            - mountPath: /etc/cni/net.d/
              name: etc-cni-netd
              readOnly: true
            - mountPath: /opt/cni/bin/
              name: opt-cni-bin
              readOnly: true
      volumes:
        - hostPath:
            path: /var/lib/etcd
          name: var-lib-etcd
        - hostPath:
            path: /var/lib/kubelet
          name: var-lib-kubelet
        - hostPath:
            path: /etc/systemd
          name: etc-systemd
        - hostPath:
            path: /lib/systemd
          name: lib-systemd
        - hostPath:
            path: /etc/kubernetes
          name: etc-kubernetes
        - hostPath:
            path: /usr/bin
          name: usr-bin
        - hostPath:
            path: /etc/cni/net.d/
          name: etc-cni-netd
        - hostPath:
            path: /opt/cni/bin
          name: opt-cni-bin
```

查看结果：

```bash
# [master]
kubectl wait --for=condition=complete job/kube-bench --timeout=300s
kubectl logs job/kube-bench | less
```

输出按 CIS 编号分组，每条形如：

```
1.2.1 Ensure that the --anonymous-auth argument is set to false (Automated)
```

把 FAIL 项复制出来，就是你的加固待办清单。扫描 worker 节点时把 `--targets` 换成 `node`，并把 Job 固定到对应节点（`nodeName: worker1`）。Docker 单机环境也可以直接：

```bash
# [任意节点]（装有 Docker 的 Ubuntu VM）
docker run --pid host --rm \
  -v /etc:/etc:ro -v /var:/var:ro \
  aquasec/kube-bench:v0.15.6 kube-bench run --targets node
```

## 2. kube-apiserver 安全参数逐个讲

kubeadm 部署下，kube-apiserver 是 static Pod，配置文件在 `/etc/kubernetes/manifests/kube-apiserver.yaml`。改参数 = 编辑该文件的 `command` 列表，kubelet 检测到变化后自动重建容器。

**改前必备动作：**

```bash
# [master]
cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/kube-apiserver.yaml.bak
```

核心参数表：

| flag | 推荐值 | 作用与原理 |
| --- | --- | --- |
| `--anonymous-auth` | `false` | 关闭匿名请求。默认 true 时未认证请求以 `system:anonymous` 身份进入授权阶段；关掉后必须持证书/token 才能到 API |
| `--authorization-mode` | `Node,RBAC` | Node 授权让 kubelet 能访问它需要的 Node/Pod 对象；RBAC 是主力授权。绝不能含 `AlwaysAllow` |
| `--enable-admission-plugins` | `NodeRestriction`（kubeadm 默认已加） | 限制 kubelet 只能改自己的 Node 对象和自己节点上的 Pod。多租户场景可加 `AlwaysPullImages` 强制每次拉镜像 |
| `--profiling` | `false` | 关闭 `/debug/pprof`，避免泄露运行时信息。所有控制面组件都建议关 |
| `--tls-min-version` | `VersionTLS12` | 拒绝 TLS 1.0/1.1。可选 `VersionTLS13`，但要先确认所有客户端支持 |
| `--tls-cipher-suites` | 见下 | 限制弱套件。一旦指定即覆盖默认列表，漏写常用套件会导致客户端连不上 |
| `--service-account-lookup` | `true` | 删除 SA 时连带吊销其 token（默认 true，显式写出便于审计） |
| `--audit-policy-file` 等 | 见 05 篇 | 审计日志，属 Monitoring 域 |

实践中往 `command` 里追加的行（YAML 列表项）：

```yaml
# [master] /etc/kubernetes/manifests/kube-apiserver.yaml 中 spec.containers[0].command 追加
    - --anonymous-auth=false
    - --profiling=false
    - --tls-min-version=VersionTLS12
    - --tls-cipher-suites=TLS_AES_128_GCM_SHA256,TLS_AES_256_GCM_SHA384,TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
```

> 历史上的 `--insecure-port=0`（8080 明文端口）已在 Kubernetes 1.24 移除，新版本无需再配；老教材里出现时不要照抄进 manifest，未知 flag 会让 apiserver 起不来。

保存文件后 kubelet 自动重启 apiserver（约 30~60 秒）。验证参数已生效：

```bash
# [master]
ps -ef | grep [k]ube-apiserver | tr ' ' '\n' | grep -E 'anonymous-auth|tls-min|profiling'
kubectl get --raw='/readyz?verbose' | tail -3
```

验证 TLS 效果：

```bash
# [master] TLS1.1 应握手失败，TLS1.2 应成功
openssl s_client -connect 127.0.0.1:6443 -tls1_1 </dev/null 2>&1 | grep -E 'protocol|alert'
openssl s_client -connect 127.0.0.1:6443 -tls1_2 </dev/null 2>&1 | grep 'Protocol  :'
```

验证 anonymous 已关：

```bash
# [任意节点] 无凭证访问应被拒（MASTER_IP 换成 master 节点实际 IP）
MASTER_IP=172.30.30.21
curl -k https://$MASTER_IP:6443/version
# 预期: 401 Unauthorized（开启 anonymous 时会返回版本信息）
```

进阶项：`--kubelet-certificate-authority` 让 apiserver 校验 kubelet 的 serving 证书。kubeadm 默认 kubelet serving 证书是自签的，直接加这个 flag 会把 `kubectl logs/exec` 打挂，必须先给 kubelet 签发集群 CA 签名的 serving 证书。考试中除非题目明确要求，别主动碰它。

## 3. scheduler 与 controller-manager 只绑 127.0.0.1

这两个组件的 metrics/healthz 只应服务于本机健康检查，不需要对外监听：

```
外部 ──✗──> 10259 kube-scheduler      （只允许 127.0.0.1 访问）
外部 ──✗──> 10257 kube-controller-manager
kubelet(本机) ──✓──> 127.0.0.1:10259/healthz   （liveness probe）
```

老版本用 `--address=127.0.0.1` 加 `--port=0`，但非安全端口相关 flag 已在新版移除；当前做法（也是新版 CIS 检查项）是把安全端口的绑定地址收紧：

```yaml
# [master] /etc/kubernetes/manifests/kube-scheduler.yaml 中 command 追加
    - --bind-address=127.0.0.1
    - --profiling=false
```

```yaml
# [master] /etc/kubernetes/manifests/kube-controller-manager.yaml 中 command 追加
    - --bind-address=127.0.0.1
    - --profiling=false
    - --use-service-account-credentials=true
```

注意 flag 名是 `--use-service-account-credentials`（常被误写成 controllers），默认已是 true，它让每个 controller 用独立 SA 凭证运行，配合 RBAC 实现 controller 级最小权限。

验证：

```bash
# [master]
ss -tlnp | grep -E '10257|10259'
# 预期: 127.0.0.1:10257 与 127.0.0.1:10259，而不是 0.0.0.0 或节点 IP
```

## 4. kubelet 加固

kubelet 配置文件在 `/var/lib/kubelet/config.yaml`（kubeadm 集群）。安全相关字段：

```yaml
# [master 或 worker1] /var/lib/kubelet/config.yaml 的安全相关片段
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false            # 拒绝匿名访问 10250
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt   # 客户端证书认证（apiserver 持 CA 签发的客户端证书）
  webhook:
    enabled: true             # 用 TokenReview 校验 bearer token
authorization:
  mode: Webhook               # 每个 API 请求发 SubjectAccessReview 给 apiserver 判权
readOnlyPort: 0               # 关闭 10255 只读端口（无认证的 /pods /metrics）
protectKernelDefaults: true   # 内核参数与 kubelet 期望不一致时拒绝启动
```

三个认证/授权概念的关系：

```
访问 kubelet 10250 的三种身份
  ├─ 客户端证书（apiserver 的 kubelet-client.crt） ──> x509 认证
  ├─ ServiceAccount token（Pod 里 kubelet 已不直接用，但 webhook 认证支持） ──> TokenReview
  └─ 匿名（anonymous.enabled=false 后直接 401）

authorization.mode=Webhook: 认证通过后，kubelet 仍要问 apiserver
  "user X 能否在节点 Y 上做 pods/log？" (SubjectAccessReview)
  旧值 AlwaysAllow 等于认证完就放行，绝不能出现
```

修改后重启并验证：

```bash
# [master 或 worker1]
sudo systemctl restart kubelet
sudo systemctl status kubelet --no-pager | head -5

# 10255 应不再监听
sudo ss -tlnp | grep 10255 || echo "OK: read-only port closed"

# 匿名访问 10250 应 401
curl -sk https://localhost:10250/pods
# 预期: Unauthorized

# 通过 apiserver 代理访问正常（带集群凭证）
kubectl get --raw "/api/v1/nodes/$(hostname | tr 'A-Z' 'a-z')/proxy/healthz"
# 预期: ok
```

### protectKernelDefaults 的典型报错

开启后 kubelet 启动时会比对内核参数，常见报错：

```
Failed to start Kubelet: kernel parameter vm.overcommit_memory value mismatch -
expected 1, got 0
```

修复方式是把 kubelet 期望的值固化到宿主机 sysctl：

```bash
# [master 或 worker1]
echo 'vm.overcommit_memory = 1' | sudo tee /etc/sysctl.d/99-kubelet.conf
sudo sysctl --system
sudo systemctl restart kubelet
```

报错信息会写明是哪个参数不一致，照着改即可；不要为了绕过报错把 protectKernelDefaults 改回 false。

## 5. 最小化节点（Minimize footprint）

原则：节点上每多一个监听端口、一个软件包、一个特权进程，就多一条攻击路径。三个抓手：

**端口面**——control-plane 节点只应见到这些监听：

| 端口 | 组件 | 说明 |
| --- | --- | --- |
| 6443 | kube-apiserver | 唯一对外必需 |
| 2379/2380 | etcd | 只应本机/集群内可达 |
| 10250 | kubelet | 节点必需，但必须认证 |
| 10257/10259 | controller-manager/scheduler | 已收 127.0.0.1 |
| 179/8472 | Calico（BGP/VXLAN） | CNI 依赖 |

```bash
# [master 或 worker1]
sudo ss -tlnp | awk '{print $4, $6}' | sort -u
```

**服务面**——关掉与 K8s 无关的服务，节点只留 sshd、containerd、kubelet（control-plane 再加 etcd 与 static Pod 的能力）：

```bash
# [任意节点] 示例：列出并停用无关服务
systemctl list-units --type=service --state=running
sudo systemctl disable --now snapd 2>/dev/null || true
```

**软件面**——不装 GUI、编译器、调试工具上生产节点；用 `apt purge` 移除明确不用的包。kubeadm 默认给 control-plane 打了 `node-role.kubernetes.io/control-plane:NoSchedule` taint，别为了"省机器"去掉它，业务 Pod 不该和 etcd 混部。云环境还要注意节点 metadata endpoint（169.254.169.254）不要暴露给 Pod（NetworkPolicy 限制或云厂商的 IMDSv2）。

## 实战演练：一次完整的体检—修复—复测

环境：Ubuntu 22.04 上的 kubeadm 单 master 集群（Calico）。

```bash
# [master] 1. 备份所有要动的文件
sudo cp /etc/kubernetes/manifests/kube-apiserver.yaml /root/bak-apiserver.yaml
sudo cp /etc/kubernetes/manifests/kube-scheduler.yaml /root/bak-scheduler.yaml
sudo cp /etc/kubernetes/manifests/kube-controller-manager.yaml /root/bak-cm.yaml
sudo cp /var/lib/kubelet/config.yaml /root/bak-kubelet.yaml

# [master] 2. 跑基线，记录 FAIL 数
kubectl apply -f /root/kube-bench-job.yaml
kubectl wait --for=condition=complete job/kube-bench --timeout=300s
kubectl logs job/kube-bench | grep -c FAIL

# [master] 3. 按第 2、3 节修改三个 static Pod manifest，按第 4 节修改 kubelet 配置

# [master] 4. 等待组件回来并验证
sleep 60
kubectl get pods -n kube-system | grep -E 'apiserver|scheduler|controller-manager'
# 预期: 三个 static Pod 均 Running（可能完成一次重启）

# [master] 5. 端到端验证
kubectl auth can-i '*' '*' --as=system:anonymous
# 预期: no（anonymous 已关时部分版本直接报 Unauthorized，同样算通过）
sudo ss -tlnp | grep -E '10255|10257|10259' || echo "OK: 10255 closed, 10257/10259 on loopback"

# [master] 6. 复测基线
kubectl delete job kube-bench && kubectl apply -f /root/kube-bench-job.yaml
kubectl wait --for=condition=complete job/kube-bench --timeout=300s
kubectl logs job/kube-bench | grep -c FAIL
# 预期: FAIL 数明显下降（文件权限类 FAIL 还需 chmod 600 /etc/kubernetes/pki/* 等）
```

回滚预案：任一组件起不来时，`cp /root/bak-*.yaml` 恢复对应文件即可，kubelet 会自动重建 static Pod。

## 常见坑

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| apiserver 反复重启，kubectl 全挂 | manifest 里写了不存在/已废弃的 flag，或 YAML 缩进错误 | 恢复备份 manifest；用 `crictl ps -a` + `crictl logs <container>` 看退出原因 |
| 改完 `--tls-cipher-suites` 后部分客户端连不上 | 套件列表覆盖默认值，漏了客户端实际使用的套件 | 至少保留 ECDHE_RSA 系（kubeadm 默认 RSA 服务端证书）；逐个加回验证 |
| kubelet 起不来并报 kernel parameter mismatch | `protectKernelDefaults: true` 生效，宿主机 sysctl 与期望不符 | 按报错把参数写入 /etc/sysctl.d/ 并 `sysctl --system` |
| kube-bench Job 一直 Pending | 单 master 集群有 control-plane taint，Job 没有 toleration | 加 `node-role.kubernetes.io/control-plane:NoSchedule` 的 toleration |
| 关掉 anonymous 后某监控 agent 失联 | 它匿名访问 10250 拿指标 | 给 agent 配合法证书或改走 apiserver 的 metrics-server 路径 |
| `ss` 里仍看到 10255 | kubelet 未重启或配置文件不是 kubelet 实际读取的那份 | `systemctl restart kubelet`；确认 `/var/lib/kubelet/config.yaml` 是 `--config` 指向的文件 |

## 自测

1. `--anonymous-auth=false` 与 `--authorization-mode=Node,RBAC` 分别挡住哪类风险？只关 anonymous 不设授权模式，攻击者还能得逞吗？

<details><summary>答案</summary>

anonymous 关闭挡"无凭证者到达 API"；authorization-mode 挡"已认证但越权"。若保留 `AlwaysAllow`（或不设），任何通过认证的身份（包括被窃取的低权限 SA token）都能做任意操作——认证与授权缺一不可，Kubernetes 默认 `authorization-mode=AlwaysAllow` 正是因此必须显式改为 Node,RBAC。
</details>

2. 为什么 scheduler/controller-manager 绑 127.0.0.1 是安全的，而 apiserver 绝不能这样绑？

<details><summary>答案</summary>

scheduler 与 controller-manager 只需被本机 kubelet 的 liveness probe 和本机管理员访问；它们与 apiserver 通信是主动外连。apiserver 是所有客户端（kubectl、kubelet、控制台）的入口，绑 127.0.0.1 会把集群整个锁死。
</details>

3. `readOnlyPort: 0` 关掉的 10255 有多危险？它和 10250 的本质区别是什么？

<details><summary>答案</summary>

10255 是完全无认证的只读端口，能拿到 Pod 列表、镜像、环境变量来源等敏感信息，等同于信息泄露。10250 是带认证的 HTTPS 端口，安全性取决于 `authentication.anonymous.enabled=false` 与 `authorization.mode=Webhook` 是否配置。
</details>

4. `protectKernelDefaults: true` 开启后 kubelet 反而起不来了，这算加固失败吗？应该怎么做？

<details><summary>答案</summary>

不算失败，这正是该参数的价值：它把"内核参数被改弱"暴露出来。正确动作是按报错把期望值写入 /etc/sysctl.d/ 持久化并重启 kubelet，而不是回退该选项。
</details>

5. kube-bench 报告里 1.1.x 类（文件权限）FAIL 很多，你如何一次性把 pki 目录收紧且不破坏组件？

<details><summary>答案</summary>

`chmod 600 /etc/kubernetes/pki/*.crt /etc/kubernetes/pki/*.key && chmod 700 /etc/kubernetes/pki`（配置文件 644、私钥 600）。组件以 root 运行 static Pod，权限收紧不影响读取；改完观察组件仍 Running 再收下一批。
</details>

## 延伸阅读

- kube-bench 官方仓库：<https://github.com/aquasecurity/kube-bench>
- CIS Kubernetes Benchmark（官方购买/下载页）：<https://www.cisecurity.org/benchmark/kubernetes>
- kube-apiserver 参数参考：<https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/>
- Kubelet 认证/授权：<https://kubernetes.io/docs/reference/access-authn-authz/kubelet-authn-authz/>
- PKI 证书与要求：<https://kubernetes.io/docs/setup/best-practices/certificates/>
