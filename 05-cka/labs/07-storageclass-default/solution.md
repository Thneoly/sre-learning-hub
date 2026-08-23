# Lab 07 · 解答：默认 StorageClass 与延迟绑定

## 步骤 1：namespace 与新 StorageClass

```bash
# [master]
kubectl create namespace lab07-default-sc
```

```yaml
# [master] cat > manual-local.yaml <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: manual-local
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Retain
EOF
kubectl apply -f manual-local.yaml
```

为什么：

- `kubernetes.io/no-provisioner` 是保留名，表示"该 SC 永不动态供给"，PVC 只能绑同 SC 名下现成的 PV；
- `WaitForFirstConsumer`（WFFC）：PVC 创建后先不绑定，等第一个消费者 Pod 调度后再按 Pod 所在节点选 PV——本地盘场景必备；
- 默认注解直接写进 YAML，省一步 patch。

## 步骤 2：摘掉 local-path 的默认标记，保证唯一默认

```bash
# [master]
kubectl annotate sc local-path storageclass.kubernetes.io/is-default-class- 2>/dev/null
kubectl get sc
```

预期：

```text
NAME            PROVISIONER                    RECLAIMPOLICY   VOLUMEBINDINGMODE      ALLOWVOLUMEEXPANSION   AGE
local-path      rancher.io/local-path          Delete          Immediate              true                  3d
manual-local    kubernetes.io/no-provisioner   Retain          WaitForFirstConsumer   false                 10s   (default)
```

为什么必须唯一：存在多个默认 SC 时，不写 SC 的 PVC 会被 API Server 拒绝（`storageclass.storage.k8s.io "..." not found` 之类的报错或绑定异常），这是考试爱考的细节。老注解 `storageclass.beta.kubernetes.io/is-default-class` 在 v1.22+ 移除，不用管。

## 步骤 3：预置 PV

```yaml
# [master] cat > pv-fast-001.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolume
metadata:
  name: pv-fast-001
spec:
  capacity:
    storage: 5Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: manual-local
  hostPath:
    path: /mnt/lab07/fast
    type: DirectoryOrCreate
EOF
kubectl apply -f pv-fast-001.yaml
kubectl get pv pv-fast-001   # STATUS: Available
```

## 步骤 4：不写 SC 的 PVC，观察"卡住"

```yaml
# [master] cat > pvc-fast.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pvc-fast
  namespace: lab07-default-sc
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 2Gi
EOF
kubectl apply -f pvc-fast.yaml
kubectl -n lab07-default-sc get pvc pvc-fast
```

```text
NAME       STATUS    VOLUME   CAPACITY   ACCESS MODES   STORAGECLASS    AGE
pvc-fast   Pending                                      manual-local    5s
```

为什么 Pending：StorageClass 默认值已在准入时注入（`spec.storageClassName=manual-local`，可用 `kubectl -n lab07-default-sc get pvc pvc-fast -o yaml` 验证），但因为 WFFC，controller 在等第一个消费者。注意与 lab 06 的 Pending 区分：那次是没建 PV，这次是故意延迟。

```bash
# [master]
kubectl -n lab07-default-sc describe pvc pvc-fast | tail -4
# Events:
#   Type    Reason                Age                  From                         Message
#   ----    ------                ----                 ----                         -------
#   Normal  WaitForFirstConsumer  ...  persistentvolume-controller  waiting for first consumer to be created before binding
```

## 步骤 5：Pod 出现，绑定完成

```yaml
# [master] cat > cache-node.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: cache-node
  namespace: lab07-default-sc
spec:
  containers:
  - name: cache-node
    image: nginx:1.27
    volumeMounts:
    - name: fast-vol
      mountPath: /usr/share/nginx/html
  volumes:
  - name: fast-vol
    persistentVolumeClaim:
      claimName: pvc-fast
EOF
kubectl apply -f cache-node.yaml
sleep 5
kubectl -n lab07-default-sc get pvc pvc-fast
kubectl -n lab07-default-sc get pod cache-node
```

预期：

```text
NAME       STATUS   VOLUME       CAPACITY   ACCESS MODES   STORAGECLASS    AGE
pvc-fast   Bound    pv-fast-001  5Gi        RWO            manual-local    2m

NAME         READY   STATUS    RESTARTS   AGE
cache-node   1/1     Running   0          20s
```

绑定瞬间发生：调度器把 Pod 放到节点后，才触发 PV controller 在 `manual-local` 名下挑 PV——5Gi(Available) ≥ 2Gi(request)、RWO 匹配，于是 `pvc-fast → pv-fast-001`。注意 PVC 显示的 CAPACITY 是 PV 的 5Gi 而不是请求的 2Gi（绑定后以 PV 为准）。

写入验证（可选）：

```bash
# [master]
kubectl -n lab07-default-sc exec cache-node -- \
  sh -c 'echo cache > /usr/share/nginx/html/index.html'
cat /mnt/lab07/fast/index.html   # 节点上可见
```

## 步骤 6：运行判分脚本

```bash
# [master]
cd 05-cka/labs/07-storageclass-default
chmod +x check.sh
./check.sh
```

通过结果：

```text
PASS: namespace lab07-default-sc 存在且 Active
PASS: sc manual-local 存在
PASS: sc provisioner 为 kubernetes.io/no-provisioner
PASS: sc volumeBindingMode 为 WaitForFirstConsumer
PASS: sc manual-local 带默认注解 true
PASS: 集群默认 SC 唯一且为 manual-local
PASS: pv pv-fast-001 存在
PASS: pv 的 storageClassName 为 manual-local
PASS: pv 容量为 5Gi
PASS: pv 状态为 Bound（WFFC 已完成绑定）
PASS: pvc pvc-fast 存在
PASS: pvc 的 storageClassName 解析为 manual-local
PASS: pvc 状态为 Bound
PASS: pvc 绑定到 pv-fast-001
PASS: pvc 请求容量为 2Gi
PASS: pod cache-node 为 Running
PASS: pod 引用的卷是 pvc pvc-fast

SCORE: 17/17
```

## 常见坑速查

| 症状 | 原因 | 解法 |
| --- | --- | --- |
| 不写 SC 的 PVC 报错/绑定怪异 | 集群里有多个默认 SC | `kubectl get sc` 检查，只留一个默认 |
| WFFC 的 PVC 永远 Pending | 只建了 PVC 没建消费者 Pod | 建 Pod 挂载它；或排障时临时改 Immediate |
| PVC 请求 2Gi 却没绑上 5Gi 的 PV | PV 的 storageClassName 与 SC 名不一致 | 改 PV 的 `storageClassName` 字段使其等于 SC 名 |
| 想改 PVC 的 SC / 容量 | 都是 immutable 字段 | 删 PVC 重建（确认数据与 Retain 策略） |

## 考点回顾

- 默认 SC 的作用点在**准入阶段**：不写 SC 的 PVC 会被自动填上默认 SC 名，之后再走绑定流程。
- `Immediate` vs `WaitForFirstConsumer`：前者创建即绑定（拓扑风险），后者消费者调度后绑定（本地卷正确姿势）。local-path 官方默认就是 WFFC，可用 `kubectl get sc local-path -o jsonpath='{.volumeBindingMode}'` 对照。
- SC 的 `reclaimPolicy` 决定其动态供给出的 PV 的回收策略；静态 PV 的回收策略以 PV 自己的字段为准。
