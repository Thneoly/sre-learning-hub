#!/usr/bin/env bash
# Lab 02 判分脚本：HPA 基于 CPU 的自动扩缩容
# 假设：
#   - 在 master 节点运行，kubectl 已配置；集群已有 metrics-server（scripts/setup 安装）
#   - 已按 task.md 完成：ns lab02-autoscale、deploy api-front（带 cpu request）、
#     svc api-front、hpa api-front（2~6 副本、CPU 50%）
# 只读检查，不修改集群。
set -u

NS="lab02-autoscale"
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
phase=$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
check "namespace ${NS} 存在且 Active" "Active" "$phase"

# 2. Deployment 存在
name=$(kubectl -n "$NS" get deploy api-front -o jsonpath='{.metadata.name}' 2>/dev/null)
check "deployment api-front 存在" "api-front" "$name"

# 3. 容器带 cpu request = 100m
cpu=$(kubectl -n "$NS" get deploy api-front \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)
check "容器 resources.requests.cpu 为 100m" "100m" "$cpu"

# 4. 容器带 memory request = 128Mi
mem=$(kubectl -n "$NS" get deploy api-front \
  -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null)
check "容器 resources.requests.memory 为 128Mi" "128Mi" "$mem"

# 5. Service 存在且 port 80
svcport=$(kubectl -n "$NS" get svc api-front \
  -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
check "service api-front 存在且 port 80" "80" "$svcport"

# 6. HPA 存在，目标是 deployment/api-front
ref=$(kubectl -n "$NS" get hpa api-front \
  -o jsonpath='{.spec.scaleTargetRef.name}' 2>/dev/null)
check "hpa api-front 存在且 scaleTargetRef 指向 api-front" "api-front" "$ref"

kind=$(kubectl -n "$NS" get hpa api-front \
  -o jsonpath='{.spec.scaleTargetRef.kind}' 2>/dev/null)
check "scaleTargetRef.kind 为 Deployment" "Deployment" "$kind"

# 7. minReplicas = 2
min=$(kubectl -n "$NS" get hpa api-front -o jsonpath='{.spec.minReplicas}' 2>/dev/null)
check "minReplicas 为 2" "2" "$min"

# 8. maxReplicas = 6
max=$(kubectl -n "$NS" get hpa api-front -o jsonpath='{.spec.maxReplicas}' 2>/dev/null)
check "maxReplicas 为 6" "6" "$max"

# 9. CPU 目标 averageUtilization = 50
tgt=$(kubectl -n "$NS" get hpa api-front \
  -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)
check "CPU target averageUtilization 为 50" "50" "$tgt"

# 10. 指标来源是 Resource/_cpu
res=$(kubectl -n "$NS" get hpa api-front \
  -o jsonpath='{.spec.metrics[0].resource.name}' 2>/dev/null)
check "指标资源名为 cpu" "cpu" "$res"

# 11. HPA 能拿到指标（ScalingActive 为 True，说明 metrics-server 正常联动）
cond=$(kubectl -n "$NS" get hpa api-front \
  -o jsonpath='{.status.conditions[?(@.type=="ScalingActive")].status}' 2>/dev/null)
check "HPA ScalingActive 条件为 True（metrics-server 正常）" "True" "$cond"

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
