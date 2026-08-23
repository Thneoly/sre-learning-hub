#!/usr/bin/env bash
# Lab 20 · 综合恢复演练 检查脚本
# 用法: chmod 755 check.sh && ./check.sh
# 前置假设:
#   - 在 master 节点上运行(需要 systemctl 查询 kubelet + kubectl admin kubeconfig)
#   - 已按 task.md 完成三个故障的恢复:
#       A. CoreDNS Corefile 的 forward 行已改回 /etc/resolv.conf
#       B. kubelet 已启动, 节点 Ready
#       C. ClusterRoleBinding drill-monitor-pods 已重建
#   - 脚本只读: kubectl exec 仅执行 nslookup, systemctl 仅查询状态
set -u

NS=cka-drill
SAAS="system:serviceaccount:cka-drill:monitor"
PASS=0; FAIL=0; TOTAL=0
pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# 0. 演练资产在位
if kubectl get ns "$NS" >/dev/null 2>&1; then
  pass "namespace $NS 存在"
else
  fail "namespace $NS 不存在"
fi
DPHASE=$(kubectl -n "$NS" get pod dnsutils -o jsonpath='{.status.phase}' 2>/dev/null || true)
if [ "$DPHASE" = "Running" ]; then
  pass "dnsutils Pod 为 Running"
else
  fail "dnsutils Pod 状态为 '$DPHASE'(应为 Running)"
fi

# 1. 故障 A 已恢复: Corefile 的 forward 行正确
COREFILE=$(kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null || true)
if echo "$COREFILE" | grep -q 'forward \. /etc/resolv.conf'; then
  pass "Corefile 上游已恢复为 /etc/resolv.conf"
else
  fail "Corefile 上游仍不正确(应含 'forward . /etc/resolv.conf')"
fi
if echo "$COREFILE" | grep -q 'forward \. 127.0.0.1'; then
  fail "Corefile 仍残留坏上游 'forward . 127.0.0.1'"
else
  pass "Corefile 无坏上游残留"
fi

# 2. CoreDNS Pod Running
TOTAL_CP=$(kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l | tr -d ' ')
RUNNING_CP=$(kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || true)
if [ "${TOTAL_CP:-0}" -ge 1 ] && [ "$RUNNING_CP" = "$TOTAL_CP" ]; then
  pass "CoreDNS Pod($RUNNING_CP 个)全部 Running"
else
  fail "CoreDNS Pod 状态异常(total=$TOTAL_CP running=$RUNNING_CP)"
fi

# 3. 端到端 DNS 解析恢复: 解析 kubernetes.default 并核对 ClusterIP
KUBESVC_IP=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [ -n "$KUBESVC_IP" ]; then
  if kubectl -n "$NS" exec dnsutils -- nslookup kubernetes.default 2>/dev/null | grep -q "$KUBESVC_IP"; then
    pass "dnsutils 内 nslookup kubernetes.default 解析正确($KUBESVC_IP)"
  else
    fail "dnsutils 内解析 kubernetes.default 未返回 $KUBESVC_IP(DNS 链路未恢复?)"
  fi
else
  fail "无法读取 kubernetes Service 的 ClusterIP"
fi

# 4. 故障 B 已恢复: kubelet active
IS_ACTIVE=$(systemctl is-active kubelet 2>/dev/null || true)
if [ "$IS_ACTIVE" = "active" ]; then
  pass "kubelet 服务为 active"
else
  fail "kubelet 服务为 '$IS_ACTIVE'(应为 active)"
fi

# 5. 节点 Ready
NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
READY=$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$READY" = "True" ]; then
  pass "节点 $NODE 为 Ready"
else
  fail "节点 $NODE Ready='$READY'(应为 True)"
fi

# 6. 故障 C 已恢复: ClusterRoleBinding 重建且指向正确
if kubectl get clusterrolebinding drill-monitor-pods >/dev/null 2>&1; then
  pass "ClusterRoleBinding drill-monitor-pods 存在"
else
  fail "ClusterRoleBinding drill-monitor-pods 不存在"
fi
SUBJ_KIND=$(kubectl get clusterrolebinding drill-monitor-pods -o jsonpath='{.subjects[0].kind}' 2>/dev/null || true)
SUBJ_NAME=$(kubectl get clusterrolebinding drill-monitor-pods -o jsonpath='{.subjects[0].name}' 2>/dev/null || true)
ROLEREF=$(kubectl get clusterrolebinding drill-monitor-pods -o jsonpath='{.roleRef.name}' 2>/dev/null || true)
if [ "$SUBJ_KIND" = "ServiceAccount" ] && [ "$SUBJ_NAME" = "monitor" ] && [ "$ROLEREF" = "drill-pod-reader" ]; then
  pass "绑定关系正确(SA cka-drill/monitor -> drill-pod-reader)"
else
  fail "绑定关系不正确(kind=$SUBJ_KIND name=$SUBJ_NAME roleRef=$ROLEREF)"
fi

# 7. 授权恢复: can-i 为 yes
if [ "$(kubectl auth can-i get pods --as="$SAAS" 2>/dev/null)" = "yes" ]; then
  pass "monitor SA can-i get pods = yes(授权已恢复)"
else
  fail "monitor SA can-i get pods 应为 yes"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then exit 0; fi
exit 1
