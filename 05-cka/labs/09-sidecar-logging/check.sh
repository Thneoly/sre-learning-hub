#!/usr/bin/env bash
# Lab 09 判分脚本：Sidecar 日志代理
# 假设：
#   - 在 master 节点运行，kubectl 已配置
#   - 已按 task.md 完成：ns lab09-sidecar、deploy ticket-app（容器 ticket-app 与
#     log-shipper，共享 emptyDir ticket-logs，日志路径 /var/log/ticket/events.log）
# 只读检查（kubectl logs/exec 只读），不修改集群。
set -u

NS="lab09-sidecar"
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

# 2. Deployment 存在且 1 副本就绪
check "deployment ticket-app 期望副本数为 1" "1" \
  "$(kubectl -n "$NS" get deploy ticket-app -o jsonpath='{.spec.replicas}' 2>/dev/null)"
ready=$(kubectl -n "$NS" get deploy ticket-app -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
check "deployment ticket-app readyReplicas 为 1" "1" "${ready:-0}"

# 3. 两个容器，名字正确（jsonpath 按定义顺序输出）
names=$(kubectl -n "$NS" get deploy ticket-app \
  -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null)
check "容器为 ticket-app 与 log-shipper" "ticket-app log-shipper" "$names"

# 4. Pod Running 且两个容器都 ready
POD=$(kubectl -n "$NS" get pod -l app=ticket-app -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$POD" ]; then
  echo "FAIL: 找不到 app=ticket-app 的 Pod"
  FAIL=$((FAIL + 1))
  TOTAL=$((PASS + FAIL)); echo; echo "SCORE: $PASS/$TOTAL"; exit 1
fi
check "pod ${POD} 为 Running" "Running" \
  "$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)"
readyc=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.status.containerStatuses[*].ready}' 2>/dev/null)
check "两个容器均 ready" "true true" "$readyc"

# 5. 共享卷是 emptyDir 且名为 ticket-logs
vol=$(kubectl -n "$NS" get deploy ticket-app \
  -o jsonpath='{.spec.template.spec.volumes[0].name}' 2>/dev/null)
check "卷名为 ticket-logs" "ticket-logs" "$vol"
ed=$(kubectl -n "$NS" get deploy ticket-app \
  -o jsonpath='{.spec.template.spec.volumes[0].emptyDir}' 2>/dev/null)
if [ -n "$ed" ]; then
  ok "卷类型为 emptyDir"
else
  bad "卷 ticket-logs 不是 emptyDir"
fi

# 6. 主容器确实在写日志文件（exec 只读 tail）
fcontent=$(kubectl -n "$NS" exec "$POD" -c ticket-app -- \
  tail -n 2 /var/log/ticket/events.log 2>/dev/null)
case "$fcontent" in
  *TICKET*) ok "ticket-app 在写 /var/log/ticket/events.log（含 TICKET 行）" ;;
  *) bad "日志文件中没有 TICKET 行（tail 输出: $(echo "$fcontent" | head -c 80))" ;;
esac

# 7. sidecar stdout 有 TICKET；8. 主容器 stdout 没有 TICKET
slog=$(kubectl -n "$NS" logs "$POD" -c log-shipper --tail=5 2>/dev/null)
case "$slog" in
  *TICKET*) ok "kubectl logs -c log-shipper 输出 TICKET 日志" ;;
  *) bad "log-shipper 的 stdout 未见 TICKET（输出: $(echo "$slog" | head -c 80))" ;;
esac
mlog=$(kubectl -n "$NS" logs "$POD" -c ticket-app --tail=50 2>/dev/null)
case "$mlog" in
  *TICKET*) bad "ticket-app 的 stdout 不应出现 TICKET（日志应只走文件）" ;;
  *) ok "ticket-app 的 stdout 无 TICKET 输出（职责已移交 sidecar）" ;;
esac

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
