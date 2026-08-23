#!/usr/bin/env bash
# Lab 07 判分脚本：默认 StorageClass 与延迟绑定
# 假设：
#   - 在 master 节点运行，kubectl 已配置；集群原有 local-path SC（scripts/setup 安装）
#   - 已按 task.md 完成：ns lab07-default-sc、sc manual-local（设为唯一默认）、
#     pv pv-fast-001、pvc pvc-fast（不写 SC，最终 Bound 到 pv-fast-001）、
#     pod cache-node（挂载 pvc-fast）
# 只读检查，不修改集群。
set -u

NS="lab07-default-sc"
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

# 2. SC 存在、provisioner 与绑定模式正确
check "sc manual-local 存在" "manual-local" \
  "$(kubectl get sc manual-local -o jsonpath='{.metadata.name}' 2>/dev/null)"
check "sc provisioner 为 kubernetes.io/no-provisioner" "kubernetes.io/no-provisioner" \
  "$(kubectl get sc manual-local -o jsonpath='{.provisioner}' 2>/dev/null)"
check "sc volumeBindingMode 为 WaitForFirstConsumer" "WaitForFirstConsumer" \
  "$(kubectl get sc manual-local -o jsonpath='{.volumeBindingMode}' 2>/dev/null)"

# 3. manual-local 是默认 SC
check "sc manual-local 带默认注解 true" "true" \
  "$(kubectl get sc manual-local \
     -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null)"

# 4. 全集群恰好只有一个默认 SC，且是 manual-local
defaults=""
for scn in $(kubectl get sc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
  ann=$(kubectl get sc "$scn" \
    -o jsonpath='{.metadata.annotations.storageclass\.kubernetes\.io/is-default-class}' 2>/dev/null)
  if [ "$ann" = "true" ]; then
    defaults="${defaults}${scn} "
  fi
done
check "集群默认 SC 唯一且为 manual-local" "manual-local " "$defaults"

# 5. PV 存在、归属 manual-local、容量 5Gi、Bound
check "pv pv-fast-001 存在" "pv-fast-001" \
  "$(kubectl get pv pv-fast-001 -o jsonpath='{.metadata.name}' 2>/dev/null)"
check "pv 的 storageClassName 为 manual-local" "manual-local" \
  "$(kubectl get pv pv-fast-001 -o jsonpath='{.spec.storageClassName}' 2>/dev/null)"
check "pv 容量为 5Gi" "5Gi" \
  "$(kubectl get pv pv-fast-001 -o jsonpath='{.spec.capacity.storage}' 2>/dev/null)"
check "pv 状态为 Bound（WFFC 已完成绑定）" "Bound" \
  "$(kubectl get pv pv-fast-001 -o jsonpath='{.status.phase}' 2>/dev/null)"

# 6. PVC 解析到默认 SC 并完成绑定
check "pvc pvc-fast 存在" "pvc-fast" \
  "$(kubectl -n "$NS" get pvc pvc-fast -o jsonpath='{.metadata.name}' 2>/dev/null)"
check "pvc 的 storageClassName 解析为 manual-local" "manual-local" \
  "$(kubectl -n "$NS" get pvc pvc-fast -o jsonpath='{.spec.storageClassName}' 2>/dev/null)"
check "pvc 状态为 Bound" "Bound" \
  "$(kubectl -n "$NS" get pvc pvc-fast -o jsonpath='{.status.phase}' 2>/dev/null)"
check "pvc 绑定到 pv-fast-001" "pv-fast-001" \
  "$(kubectl -n "$NS" get pvc pvc-fast -o jsonpath='{.spec.volumeName}' 2>/dev/null)"
check "pvc 请求容量为 2Gi" "2Gi" \
  "$(kubectl -n "$NS" get pvc pvc-fast -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)"

# 7. Pod Running 且挂载该 PVC
check "pod cache-node 为 Running" "Running" \
  "$(kubectl -n "$NS" get pod cache-node -o jsonpath='{.status.phase}' 2>/dev/null)"
check "pod 引用的卷是 pvc pvc-fast" "pvc-fast" \
  "$(kubectl -n "$NS" get pod cache-node \
     -o jsonpath='{.spec.volumes[0].persistentVolumeClaim.claimName}' 2>/dev/null)"

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
