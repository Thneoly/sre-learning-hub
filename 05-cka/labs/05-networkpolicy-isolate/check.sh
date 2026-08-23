#!/usr/bin/env bash
# Lab 05 判分脚本：NetworkPolicy 微隔离
# 假设：
#   - 在 master 节点运行，kubectl 已配置；CNI 为 Calico（支持 NetworkPolicy）
#   - 已按 task.md 完成：ns lab05-netpol / lab05-other、4 个 Pod、
#     svc billing-api、networkpolicy default-deny-ingress 与 allow-report-to-billing
# 只读检查（kubectl exec 只执行只读的 wget），不修改集群。
set -u

NS="lab05-netpol"
NS2="lab05-other"
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

# 1. 两个 namespace 存在
check "namespace ${NS} 存在且 Active" "Active" \
  "$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)"
check "namespace ${NS2} 存在且 Active" "Active" \
  "$(kubectl get ns "$NS2" -o jsonpath='{.status.phase}' 2>/dev/null)"

# 2. 三个关键 Pod 都在 Running
for p in billing-api report-job audit-tool; do
  st=$(kubectl -n "$NS" get pod "$p" -o jsonpath='{.status.phase}' 2>/dev/null)
  check "pod ${p} 为 Running" "Running" "$st"
done
st2=$(kubectl -n "$NS2" get pod ops-client -o jsonpath='{.status.phase}' 2>/dev/null)
check "pod ops-client 为 Running（lab05-other）" "Running" "$st2"

# 3. default-deny-ingress：选中所有 Pod、仅 Ingress、无放行规则
ml=$(kubectl -n "$NS" get networkpolicy default-deny-ingress \
  -o jsonpath='{.spec.podSelector.matchLabels.app}' 2>/dev/null)
check "default-deny-ingress 不限定 Pod（空 selector）" "" "$ml"
types=$(kubectl -n "$NS" get networkpolicy default-deny-ingress \
  -o jsonpath='{.spec.policyTypes[*]}' 2>/dev/null)
check "default-deny-ingress policyTypes 为 Ingress" "Ingress" "$types"
ing=$(kubectl -n "$NS" get networkpolicy default-deny-ingress \
  -o jsonpath='{.spec.ingress}' 2>/dev/null)
check "default-deny-ingress 无 ingress 放行规则" "" "$ing"

# 4. allow-report-to-billing：选中 billing-api
sel=$(kubectl -n "$NS" get networkpolicy allow-report-to-billing \
  -o jsonpath='{.spec.podSelector.matchLabels.app}' 2>/dev/null)
check "allow-report-to-billing 选中 app=billing-api" "billing-api" "$sel"

# 5. 放行来源：仅同 ns 的 app=report-job
frm=$(kubectl -n "$NS" get networkpolicy allow-report-to-billing \
  -o jsonpath='{.spec.ingress[0].from[0].podSelector.matchLabels.app}' 2>/dev/null)
check "入站来源限定 app=report-job" "report-job" "$frm"

# 6. 放行端口：TCP/80
port=$(kubectl -n "$NS" get networkpolicy allow-report-to-billing \
  -o jsonpath='{.spec.ingress[0].ports[0].port}' 2>/dev/null)
check "放行端口为 80" "80" "$port"
proto=$(kubectl -n "$NS" get networkpolicy allow-report-to-billing \
  -o jsonpath='{.spec.ingress[0].ports[0].protocol}' 2>/dev/null)
check "放行协议为 TCP" "TCP" "$proto"

# 7. 连通性验证（wget 成功=rc 0，被隔离=超时非零）
probe() { # $1=ns $2=pod $3=url ；返回 wget 退出码
  kubectl -n "$1" exec "$2" -- wget -q -T 5 -O- "$3" >/dev/null 2>&1
  echo $?
}

rc=$(probe "$NS" report-job "http://billing-api")
if [ "$rc" -eq 0 ]; then
  ok "report-job -> billing-api:80 放行"
else
  bad "report-job -> billing-api:80 应放行但失败（rc=$rc）"
fi

rc=$(probe "$NS" audit-tool "http://billing-api")
if [ "$rc" -ne 0 ]; then
  ok "audit-tool -> billing-api:80 被拒绝"
else
  bad "audit-tool -> billing-api:80 应被拒绝但放行了"
fi

rc=$(probe "$NS2" ops-client "http://billing-api.${NS}.svc.cluster.local")
if [ "$rc" -ne 0 ]; then
  ok "ops-client（其他 ns） -> billing-api:80 被拒绝"
else
  bad "ops-client（其他 ns） -> billing-api:80 应被拒绝但放行了"
fi

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
