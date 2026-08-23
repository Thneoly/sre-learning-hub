#!/usr/bin/env bash
# Lab 17 · 集群内 DNS 排查 检查脚本
# 用法: chmod 755 check.sh && ./check.sh
# 前置假设:
#   - 在能以 admin kubeconfig 访问集群的节点上运行(练习环境即 master)
#   - 已按 task.md 完成: ns cka-dns / Pod dnsutils / Deployment web + Service web-svc
#   - 脚本只读: kubectl exec 中仅执行 nslookup(只读查询)
set -u

NS=cka-dns
PASS=0; FAIL=0; TOTAL=0
pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# 1. namespace 与 dnsutils Pod 存在且 Running
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

# 2. web Deployment 1/1
WAVAIL=$(kubectl -n "$NS" get deploy web -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
if [ "${WAVAIL:-x}" = "1" ]; then
  pass "web Deployment availableReplicas=1"
else
  fail "web Deployment availableReplicas='$WAVAIL'(应为 1)"
fi

# 3. Service web-svc 有 ClusterIP
WEBIP=$(kubectl -n "$NS" get svc web-svc -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [ -n "$WEBIP" ] && [ "$WEBIP" != "None" ]; then
  pass "Service web-svc 有 ClusterIP($WEBIP)"
else
  fail "Service web-svc 缺少 ClusterIP"
fi

# 4. dnsutils 内解析系统 Service kubernetes
KUBESVC_IP=$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
if [ -n "$KUBESVC_IP" ]; then
  if kubectl -n "$NS" exec dnsutils -- nslookup kubernetes.default.svc.cluster.local 2>/dev/null | grep -q "$KUBESVC_IP"; then
    pass "nslookup kubernetes.default.svc.cluster.local 返回正确 ClusterIP($KUBESVC_IP)"
  else
    fail "nslookup kubernetes.default 未返回 $KUBESVC_IP(DNS 链路异常?)"
  fi
else
  fail "无法读取 kubernetes Service 的 ClusterIP"
fi

# 5. dnsutils 内解析业务 Service web-svc(FQDN)
if [ -n "$WEBIP" ]; then
  if kubectl -n "$NS" exec dnsutils -- nslookup web-svc.cka-dns.svc.cluster.local 2>/dev/null | grep -q "$WEBIP"; then
    pass "nslookup web-svc.cka-dns.svc.cluster.local 返回正确 ClusterIP($WEBIP)"
  else
    fail "nslookup web-svc FQDN 未返回 $WEBIP(检查 Service 名/CoreDNS)"
  fi
else
  fail "web-svc FQDN 解析检查跳过(无 ClusterIP)"
fi

# 6. Pod 级解析: <ip 换横线>.cka-dns.pod.cluster.local
PODIP=$(kubectl -n "$NS" get pod -l app=web -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)
if [ -n "$PODIP" ]; then
  POD_DNS=$(echo "$PODIP" | tr '.' '-')
  if kubectl -n "$NS" exec dnsutils -- nslookup "${POD_DNS}.${NS}.pod.cluster.local" 2>/dev/null | grep -q "$PODIP"; then
    pass "Pod 级解析 ${POD_DNS}.${NS}.pod.cluster.local 返回 Pod IP"
  else
    fail "Pod 级解析未返回 Pod IP($PODIP)"
  fi
else
  fail "无法读取 web Pod 的 IP(检查 Deployment 的 label)"
fi

# 7. CoreDNS 健康
TOTAL_CP=$(kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l | tr -d ' ')
RUNNING_CP=$(kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || true)
if [ "${TOTAL_CP:-0}" -ge 1 ] && [ "$RUNNING_CP" = "$TOTAL_CP" ]; then
  pass "CoreDNS Pod($RUNNING_CP 个)全部 Running"
else
  fail "CoreDNS Pod 状态异常(total=$TOTAL_CP running=$RUNNING_CP)"
fi

# 8. resolv.conf 的 search 域正确
if kubectl -n "$NS" exec dnsutils -- cat /etc/resolv.conf 2>/dev/null | grep -q "cka-dns.svc.cluster.local"; then
  pass "dnsutils 的 /etc/resolv.conf search 域包含 cka-dns.svc.cluster.local"
else
  fail "dnsutils 的 /etc/resolv.conf 缺少本 namespace 的 search 域"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then exit 0; fi
exit 1
