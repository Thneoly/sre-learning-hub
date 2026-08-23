#!/usr/bin/env bash
# Lab 08 判分脚本：PriorityClass 与调度抢占
# 假设：
#   - 在 master 节点运行，kubectl 已配置；单节点集群（master 可调度）
#   - 已按 task.md 完成：ns lab08-preempt、priorityclass batch-low/critical-high、
#     deploy filler-low（requests 1000m/副本，已占满节点 CPU 账面）、
#     pod payment-gateway（高优先级，已触发抢占并 Running）
# 只读检查（对 payment-gateway 最多等待 90 秒等其抢占调度完成），不修改集群。
set -u

NS="lab08-preempt"
PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# CPU 数量归一化：API server 会把 1000m 规范化成 1，比较前统一折算成毫核
cpu_milli() {
  case "${1:-}" in
    *m) echo "${1%m}" ;;
    ""|null) echo "" ;;
    *) awk -v v="$1" 'BEGIN{printf "%d", v*1000}' ;;
  esac
}

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

# 2. 两个 PriorityClass 的 value
check "priorityclass batch-low 存在" "batch-low" \
  "$(kubectl get priorityclass batch-low -o jsonpath='{.metadata.name}' 2>/dev/null)"
check "batch-low value 为 100" "100" \
  "$(kubectl get priorityclass batch-low -o jsonpath='{.value}' 2>/dev/null)"
check "priorityclass critical-high 存在" "critical-high" \
  "$(kubectl get priorityclass critical-high -o jsonpath='{.metadata.name}' 2>/dev/null)"
check "critical-high value 为 1000000" "1000000" \
  "$(kubectl get priorityclass critical-high -o jsonpath='{.value}' 2>/dev/null)"

# 3. filler Deployment：低优先级 + 每副本 1000m CPU request
check "filler-low priorityClassName 为 batch-low" "batch-low" \
  "$(kubectl -n "$NS" get deploy filler-low \
     -o jsonpath='{.spec.template.spec.priorityClassName}' 2>/dev/null)"
check "filler-low 每副本 requests.cpu 为 1000m" "1000" \
  "$(cpu_milli "$(kubectl -n "$NS" get deploy filler-low \
     -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null)")"
rep=$(kubectl -n "$NS" get deploy filler-low -o jsonpath='{.spec.replicas}' 2>/dev/null)
if [ "${rep:-0}" -ge 2 ] 2>/dev/null; then
  ok "filler-low 期望副本数 >= 2（实际 ${rep}）"
else
  bad "filler-low 期望副本数 >= 2（实际 ${rep}，未按节点核数占满资源）"
fi

# 4. payment-gateway：等待最多 90 秒变成 Running（抢占需要一点时间）
phase=""
for _ in $(seq 1 18); do
  phase=$(kubectl -n "$NS" get pod payment-gateway -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$phase" = "Running" ] && break
  sleep 5
done
check "pod payment-gateway 为 Running（含抢占等待）" "Running" "${phase:-}"

check "payment-gateway priorityClassName 为 critical-high" "critical-high" \
  "$(kubectl -n "$NS" get pod payment-gateway -o jsonpath='{.spec.priorityClassName}' 2>/dev/null)"
check "payment-gateway requests.cpu 为 1000m" "1000" \
  "$(cpu_milli "$(kubectl -n "$NS" get pod payment-gateway \
     -o jsonpath='{.spec.containers[0].resources.requests.cpu}' 2>/dev/null)")"
prio=$(kubectl -n "$NS" get pod payment-gateway -o jsonpath='{.spec.priority}' 2>/dev/null)
if [ "${prio:-0}" -gt 100 ] 2>/dev/null; then
  ok "payment-gateway 的 spec.priority(${prio}) 高于 filler 的优先级"
else
  bad "payment-gateway 的 spec.priority 应大于 100（实际 ${prio}）"
fi

# 5. 抢占证据：filler 有副本起不来（ready < desired），且存在 Pending 的 filler Pod
ready=$(kubectl -n "$NS" get deploy filler-low -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
ready=${ready:-0}
if [ "$ready" -lt "$rep" ] 2>/dev/null; then
  ok "filler-low readyReplicas(${ready}) < 期望副本数(${rep})，低优先级被挤掉"
else
  bad "filler-low readyReplicas(${ready}) 不应等于期望副本数(${rep})——资源没有被占满或未发生抢占"
fi
phases=$(kubectl -n "$NS" get pods -l app=filler-low \
  -o jsonpath='{.items[*].status.phase}' 2>/dev/null)
case " $phases " in
  *" Pending "*) ok "存在 Pending 的 filler-low Pod（节点 CPU 账面已满）" ;;
  *) bad "未发现 Pending 的 filler-low Pod（phases: ${phases}）" ;;
esac

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
