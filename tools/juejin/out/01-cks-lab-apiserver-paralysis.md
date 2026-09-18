---
title_juejin: 照着 CKS 教材做实验，把 apiserver 干瘫了 7 分钟
title_zhihu: 给静态 Pod 挂 Secret？kubelet 会当场处决你的 apiserver
description: 静态Pod不能挂Secret——从v1.34起这是准入阶段的硬性拒绝。本文还原一次照教材做CKS实验导致控制面瘫痪的全过程，含恢复步骤和版本演进。10秒自检命令附文内。
category_id: "6809637769959178254"
tags: "Kubernetes,安全"
---
# 照着 CKS 教材做实验，把 apiserver 干瘫了 7 分钟

> 单 master 集群里，kubelet 杀掉老 apiserver 容器的那一秒，你手里的 kubectl 就成了废铁。这不是虚构故事——是我照着某门流行的 CKS 备考课程的实验指导书，一步步做出来的。而且这个错误今天还躺在不少教程和 AI 生成的实验指导书里。

## 场景：一个看似合理的安全实验

CKS 考试有一个经典实验：给 etcd 里的 Secret 开启静态加密（Encryption at Rest）。步骤很清晰：

1. 生成一个加密密钥
2. 写一份 `EncryptionConfiguration`
3. 把配置挂载到 kube-apiserver 的静态 Pod 里
4. 重启 apiserver
5. 验证 etcd 里的数据已经变成密文

我的环境是 kubeadm 搭的 v1.35 单 master 集群——这个版本号后面会变得很重要。课程指导书第 3 步的写法看起来很"Kubernetes 味"：用 Secret 存配置，再用 Secret 卷挂进静态 Pod。毕竟"不要把敏感信息写死在文件里"是 Kubernetes 的第一课，对吧？

```yaml
# 课程指导书给的写法（有严重问题！）
volumes:
- name: enc-config
  secret:
    secretName: encryption-config    # ← 这行就是炸弹
containers:
- volumeMounts:
  - name: enc-config
    mountPath: /etc/kubernetes/enc
```

对照组来了：官方文档的 encrypt-data 任务页在这一步用的恰恰是 hostPath + `--encryption-provider-config` 参数，从头到尾没让你挂 Secret 卷——坑在课程和二手教程这一层，不在官方文档。而且这不只是 CKS 考生的坑：挂自定义准入配置、挂审计策略，任何动过 `/etc/kubernetes/manifests/` 的人都在同一个雷区里。

## 灾难发生

前两步很顺利（第 1 步先把配置打进一个 Secret，这步本身完全无害），真正扣扳机的是第 3 步——SSH 到控制面节点，编辑静态 Pod 的 manifest：

```bash
$ kubectl apply -f encryption-setup.yaml   # 内容就是把 encryption.yaml 打进去的 generic Secret
secret/encryption-config created
# 第 3 步的实际操作：编辑静态 Pod 的 manifest
$ vim /etc/kubernetes/manifests/kube-apiserver.yaml
# 在 volumes 里加上上面那段 secret 卷，:wq 保存
```

保存 manifest 的那一秒，kubelet 检测到文件变化，先杀掉老的 apiserver 容器——然后新的容器永远起不来。

```bash
$ kubectl get nodes
The connection to the server 192.168.1.10:6443 was refused - did you specify the right host or port?
# ↑ 直连 6443 是秒级 refused，连"超时"的待遇都没有
```

`crictl ps` 一看：老容器死了，新容器压根没被创建——拒绝发生在**容器创建之前**的准入阶段，kubelet 根本不会去尝试拉起它。`journalctl -u kubelet` 里的拒绝信息（凭记忆转述，非逐字原文）大意是：

```text
static pod kube-apiserver-master 引用了 secret "encryption-config"
拒绝创建：static pods may not reference API objects
```

**kubelet 硬性拒绝静态 Pod 引用 Secret。** 教材：我教的。kubelet：我拒收的。😅

## 为什么？

这不是 bug，是 Kubernetes 的设计约束——而且是从 v1.34 才开始变"硬"的约束。先看经典的循环依赖（kubelet 是并发拉起所有静态 Pod 的，没有 etcd→apiserver 的先后编排，apiserver 连不上 etcd 时自己重试等待）：

```text
静态 Pod 的启动发生在 apiserver 之前
    ↓
Secret 存在 etcd 里，而 etcd 只有 apiserver 能读写
    ↓
apiserver 的配置又来自静态 Pod
    ↓
鸡生蛋蛋生鸡 —— 循环依赖！
```

所以 kubelet 的规则是：**静态 Pod 不能引用任何需要 API server 才能解析的对象**（Secret、ConfigMap、ServiceAccount、PVC 都不行），不依赖 API 的本地卷（hostPath、emptyDir）都可以。

版本史是这件事最有信息量的部分：v1.33 及以前，kubelet 并不硬拒这种引用——apiserver 活着时甚至能挂载成功，失败也只是卡在 ContainerCreating、事件报 `MountVolume.SetUp failed`。上游一直把"能引用"定性为静态 Pod 绕过 API 准入与审计的缺陷（官方文档 "API server bypass risks" 一节讲的就是这个），于是 v1.34 引入 `PreventStaticPodAPIReferences` 门控（Beta 默认开启，1.37 起门控移除、不可关闭），改成在准入阶段直接拒绝。我的 v1.35 正好落在"硬拒"区间；在更老的集群上复现，你看到的是"卡住"而不是"被拒"。

**在静态 Pod 里，Kubernetes 教你的第一课就是错的——「不把敏感信息落盘」这条最佳实践，在这里会亲手杀死你的控制面。**

## 正确做法

修复其实就改三处：Secret 卷换成 hostPath、挂载点跟着改、再补一个命令行参数——apiserver 要的东西，得在它出生前就落到节点上，并且明确告诉它在哪。

```yaml
# 1. volumes：secret 卷换成 hostPath 目录
volumes:
- name: enc-config
  hostPath:
    path: /etc/kubernetes/enc
    type: DirectoryOrCreate
# 2. volumeMounts：挂载点跟着改
volumeMounts:
- name: enc-config
  mountPath: /etc/kubernetes/enc
  readOnly: true
# 3. command 追加参数（不加它，挂了也白挂——apiserver 根本不会去读）
command:
- kube-apiserver
- --encryption-provider-config=/etc/kubernetes/enc/encryption.yaml
```

先把加密配置写到节点本地的 `/etc/kubernetes/enc/encryption.yaml`，再让静态 Pod 挂载。第 5 步验证别只看 status，直接查 etcd 里的密文：`ETCDCTL_API=3 etcdctl get /registry/secrets/<ns>/<name> --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key | grep 'k8s:enc:aescbc'`——有输出才说明真的加密了。

## 恢复过程

如果已经踩坑（apiserver 起不来），恢复步骤：

```bash
# SSH 到 master 节点
# 1. 备份当前的坏 manifest
cp /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/broken.yaml
# 2. 删掉静态 Pod manifest（kubelet 会停止尝试创建）
rm /etc/kubernetes/manifests/kube-apiserver.yaml
sleep 10
# 3. 恢复 encryption.yaml——此刻 apiserver 已死，那个 Secret 卡在 etcd 里取不出来，
#    只能用生成密钥时留在本地的原始文件重写（或重新生成）
cat > /etc/kubernetes/enc/encryption.yaml <<'EOF'
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
- resources:
  - secrets
  providers:
  - aescbc:
      keys:
      - { name: key1, key: <生成密钥时本地留存的那把 base64> }
  - identity: {}   # 兜底：没有它，配错时存量数据就再也读不回来
EOF
# 4. 修 manifest：secret 卷换 hostPath，挂载点与 --encryption-provider-config 同步改
vim /tmp/broken.yaml
cp /tmp/broken.yaml /etc/kubernetes/manifests/kube-apiserver.yaml
# 5. 等 apiserver 重建（约 30-60 秒）
kubectl get nodes   # 恢复正常
```

从 apply 到 `get nodes` 恢复，整整 7 分钟：发现集群没了花 1 分钟，翻 kubelet 日志确认原因 3 分钟，改 manifest 等重建再 3 分钟——其中至少一半时间在怀疑人生。

## 教训

| 要点 | 说明 |
|---|---|
| **静态 Pod ≠ 普通 Pod** | 它们活在 apiserver 之前，不能引用任何 API 资源 |
| **"最佳实践"有适用范围** | "不要硬编码"是对的，但静态 Pod 例外 |
| **单 master 集群很脆弱** | apiserver 挂了 = 整个集群不可操作，连排查都变难 |
| **先备份再改 manifest** | `/etc/kubernetes/manifests/` 下的文件改坏了没有 undo |

顺便，把 manifests 目录当生产配置管理——改之前先 `cp` 一份，这是那 7 分钟教会我的第一件事。

**10 秒自检**：现在就到你的 master 节点跑一下 `grep -rn 'secret:' /etc/kubernetes/manifests/`——有输出，说明你正踩在这颗雷上。

## 这个坑有多常见？

我在给 77 个 Kubernetes 实验 lab 做真机测试时发现的——我们生成的实验指导书里也犯了一模一样的错误，**直到在真机上跑了一遍才发现**。

说句容易被喷的：AI 生成的 K8s 教程正在批量复制这类错误，没人在真机上跑一遍就敢发——包括我自己，直到被炸了一次。

这让我确信：**没有在真机上跑过的实验指导书，等于没有写过。**

预答三个迟早会上门的评论区质疑：官方文档本来就用 hostPath（坑在课程和二手教程层）；v1.34 之前是卡 ContainerCreating 而非硬拒（见上文版本史）；实验前给节点打个快照、备份 manifests 目录，成本远低于 7 分钟恢复。

---

上文那份完整的 EncryptionConfiguration 和恢复脚本，就放在我做真机测试的那个仓库里——[sre-learning-hub](https://github.com/Thneoly/sre-learning-hub) 的 CKS 模块（和本文同一套 kubeadm v1.35 环境，每个实验都真机验证过）。
