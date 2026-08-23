# Lab 06 · 解答：静态 PV 与 PVC 手工绑定

## 步骤 1：namespace 与 PV

```bash
# [master]
kubectl create namespace lab06-static-pv
```

```yaml
# [master] cat > pv-data-001.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-data-001
spec:
  capacity:
    storage: 1Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  hostPath:
    path: /mnt/lab06/data
    type: DirectoryOrCreate
EOF
kubectl apply -f pv-data-001.yaml
```

为什么：

- PV 是集群级资源（没有 namespace），生命周期独立于 Pod/PVC；
- `storageClassName: ""` 空字符串是关键：它让这个 PV 只与同样声明空 SC 的 PVC 匹配，把默认 SC 的动态供给挡在门外；
- `Retain` 保证 PVC 删除后数据仍保留在节点上，回收前 PV 处于 `Released`，需管理员手工清理才能复用。

验证：

```text
# [master]
$ kubectl get pv pv-data-001
NAME         CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS      CLAIM   STORAGECLASS   AGE
pv-data-001  1Gi        RWO            Retain           Available           ""             5s
```

## 步骤 2：PVC

```yaml
# [master] cat > data-claim.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-claim
  namespace: lab06-static-pv
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: ""
EOF
kubectl apply -f data-claim.yaml
```

注意 kind 必须写全称 `PersistentVolumeClaim`——考场上写成 `PersistentClaim` 会直接报 `no matches for kind "PersistentClaim"`，报错信息要读得出来。

绑定验证（PVC 创建后数秒内完成）：

```text
# [master]
$ kubectl -n lab06-static-pv get pvc data-claim
NAME         STATUS   VOLUME       CAPACITY   ACCESS MODES   STORAGECLASS   AGE
data-claim   Bound    pv-data-001  1Gi        RWO            ""             8s

$ kubectl get pv pv-data-001
NAME         CAPACITY   ACCESS MODES   RECLAIM POLICY   STATUS   CLAIM                          STORAGECLASS   AGE
pv-data-001  1Gi        RWO            Retain           Bound    lab06-static-pv/data-claim     ""             30s
```

绑定由 controller-manager 里的 PV controller 完成：PVC 的 request(1Gi) ≤ PV capacity(1Gi)，accessModes 交集 RWO，SC 同为 `""`，三项全中即 `Bound`。

## 步骤 3：Pod 挂载 PVC

```yaml
# [master] cat > file-server.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: file-server
  namespace: lab06-static-pv
spec:
  containers:
  - name: file-server
    image: nginx:1.27
    volumeMounts:
    - name: data-vol
      mountPath: /usr/share/nginx/html
  volumes:
  - name: data-vol
    persistentVolumeClaim:
      claimName: data-claim
EOF
kubectl apply -f file-server.yaml
kubectl -n lab06-static-pv get pod file-server
```

## 步骤 4：证明数据落在 PV 上

```bash
# [master]
kubectl -n lab06-static-pv exec file-server -- \
  sh -c 'echo "hello from pv-data-001" > /usr/share/nginx/html/index.html'

kubectl -n lab06-static-pv exec file-server -- cat /usr/share/nginx/html/index.html
# hello from pv-data-001

ls /mnt/lab06/data
cat /mnt/lab06/data/index.html
# hello from pv-data-001
```

Pod 容器里写入的文件出现在节点 `/mnt/lab06/data`，hostPath 后端生效。

删除重建 Pod 再看一次（可选但推荐）：

```bash
# [master]
kubectl -n lab06-static-pv delete pod file-server --wait=false
kubectl apply -f file-server.yaml
kubectl -n lab06-static-pv exec file-server -- cat /usr/share/nginx/html/index.html
# 依旧是 hello from pv-data-001  -> 数据生命周期独立于 Pod
```

## 步骤 5：运行判分脚本

```bash
# [master]
cd 05-cka/labs/06-pvc-static-binding
chmod +x check.sh
./check.sh
```

通过结果：

```text
PASS: namespace lab06-static-pv 存在且 Active
PASS: pv pv-data-001 存在
PASS: pv 容量为 1Gi
PASS: pv 状态为 Bound
PASS: pv claimRef 为 lab06-static-pv/data-claim
PASS: pv 回收策略为 Retain
PASS: pvc data-claim 存在
PASS: pvc 状态为 Bound
PASS: pvc 绑定到 pv-data-001
PASS: pvc storageClassName 为空（静态绑定）
PASS: pvc 请求容量为 1Gi
PASS: pod file-server 为 Running
PASS: pod 引用的卷是 pvc data-claim

SCORE: 13/13
```

## 常见坑速查

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| PVC 一直 Pending | accessModes 不一致 / SC 名不一致 / 容量超了 | `kubectl describe pvc` 看 Events 的 "no persistent volumes available" |
| PVC 意外走了 local-path 动态供给 | 没写 `storageClassName: ""` | 删掉 PVC 重写（PVC 的 SC 字段不可原地改） |
| Pod ContainerCreating 卡住 | hostPath type=Directory 但目录不存在 | 先建目录，或改 DirectoryOrCreate |
| 删 PVC 后 PV 一直 Released | Retain 策略的保护行为 | `kubectl edit pv` 清掉 claimRef 并保留/清理数据后回 Available |

## 考点回顾

- 静态供给 vs 动态供给：前者管理员建 PV 等绑定，后者 PVC 触发 provisioner 造 PV；`storageClassName: ""` 是切换到静态的开关。
- PVC 是 namespace 级对象，PV 是集群级；一个 PV 同一时刻只能被一个 PVC 绑定（RWO 下进一步限制节点）。
- Retain / Delete / Recycle 三种回收策略，Recycle 已废弃，考试主要考前两种。
