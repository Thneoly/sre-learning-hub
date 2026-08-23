#!/usr/bin/env bash
# Lab 06 判分脚本：静态 PV/PVC 手工绑定
# 假设：
#   - 在 master 节点运行，kubectl 已配置；单节点集群，Pod 调度在 master，
#     节点本地路径 /mnt/lab06/data 可直接查看
#   - 已按 task.md 完成：ns lab06-static-pv、pv pv-data-001、pvc data-claim、
#     pod file-server（挂载 PVC）
# 只读检查（kubectl exec 只做 ls/cat 只读命令），不修改集群。
set -u

NS="lab06-static-pv"
PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

check() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1 (期望 [$2] 实际 [$3])"
  fi
}

# 1. namespace 存在且 Active
check "namespace ${NS} 存在且 Active" "Active" \
  "$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)"

# 2. PV 存在，容量 1Gi
check "pv pv-data-001 存在" "pv-data-001" \
  "$(kubectl get pv pv-data-001 -o jsonpath='{.metadata.name}' 2>/dev/null)"
check "pv 容量为 1Gi" "1Gi" \
  "$(kubectl get pv pv-data-001 -o jsonpath='{.spec.capacity.storage}' 2>/dev/null)"

# 3. PV 状态 Bound，claimRef 指向 lab06-static-pv/data-claim
check "pv 状态为 Bound" "Bound" \
  "$(kubectl get pv pv-data-001 -o jsonpath='{.status.phase}' 2>/dev/null)"
check "pv claimRef 为 ${NS}/data-claim" "${NS}/data-claim" \
  "$(kubectl get pv pv-data-001 -o jsonpath='{.spec.claimRef.namespace}/{.spec.claimRef.name}' 2>/dev/null)"

# 4. 回收策略 Retain
check "pv 回收策略为 Retain" "Retain" \
  "$(kubectl get pv pv-data-001 -o jsonpath='{.spec.persistentVolumeReclaimPolicy}' 2>/dev/null)"

# 5. PVC 存在、Bound、绑定到 pv-data-001、绕开默认 SC
check "pvc data-claim 存在" "data-claim" \
  "$(kubectl -n "$NS" get pvc data-claim -o jsonpath='{.metadata.name}' 2>/dev/null)"
check "pvc 状态为 Bound" "Bound" \
  "$(kubectl -n "$NS" get pvc data-claim -o jsonpath='{.status.phase}' 2>/dev/null)"
check "pvc 绑定到 pv-data-001" "pv-data-001" \
  "$(kubectl -n "$NS" get pvc data-claim -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
check "pvc storageClassName 为空（静态绑定）" "" \
  "$(kubectl -n "$NS" get pvc data-claim -o jsonpath='{.spec.storageClassName}' 2>/dev/null)"
check "pvc 请求容量为 1Gi" "1Gi" \
  "$(kubectl -n "$NS" get pvc data-claim -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)"

# 6. Pod Running 且挂载了该 PVC
check "pod file-server 为 Running" "Running" \
  "$(kubectl -n "$NS" get pod file-server -o jsonpath='{.status.phase}' 2>/dev/null)"
claim=$(kubectl -n "$NS" get pod file-server \
  -o jsonpath='{.spec.volumes[0].persistentVolumeClaim.claimName}' 2>/dev/null)
check "pod 引用的卷是 pvc data-claim" "data-claim" "$claim"

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
