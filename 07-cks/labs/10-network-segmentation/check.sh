#!/usr/bin/env bash
# Lab 10 判分脚本 —— Namespace 间网络分段（只读；exec 查询不修改任何对象）
# 运行位置：master 节点（kubectl 管理员权限；CNI 为 Calico）
# 前提：已按 task.md 完成实验（三个 cks-lab10-* ns、backend/db Pod+Service、fe-client、
#       各 ns 的 default-deny-all / allow-dns / 入站放行策略）
# 用法：chmod +x check.sh && ./check.sh
set -u

PASS=0
FAIL=0
TOTAL=0

pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $*"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $*"; }

expect_ok() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
expect_fail() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}

FE=cks-lab10-frontend
BE=cks-lab10-backend
DB=cks-lab10-db

# 1. 基础对象存在
expect_ok "namespace $FE 存在" kubectl get namespace "$FE"
expect_ok "namespace $BE 存在" kubectl get namespace "$BE"
expect_ok "namespace $DB 存在" kubectl get namespace "$DB"
expect_ok "Pod fe-client 为 Running" \
  bash -c "kubectl -n $FE get pod fe-client -o jsonpath='{.status.phase}' | grep -qx Running"
expect_ok "Pod backend 为 Running 且 Service 存在" \
  bash -c "kubectl -n $BE get pod backend -o jsonpath='{.status.phase}' | grep -qx Running && kubectl -n $BE get svc backend"
expect_ok "Pod db 为 Running 且 Service 存在" \
  bash -c "kubectl -n $DB get pod db -o jsonpath='{.status.phase}' | grep -qx Running && kubectl -n $DB get svc db"

# 2. default-deny-all：三个 ns 都要 Ingress+Egress 双向收口
for NS in "$FE" "$BE" "$DB"; do
  expect_ok "$NS 有 default-deny-all（Ingress+Egress）" \
    bash -c "kubectl -n $NS get networkpolicy default-deny-all -o jsonpath='{.spec.policyTypes}' | grep -q 'Ingress' && kubectl -n $NS get networkpolicy default-deny-all -o jsonpath='{.spec.policyTypes}' | grep -q 'Egress'"
done

# 3. allow-dns：三个 ns 都放行 kube-dns 53
for NS in "$FE" "$BE" "$DB"; do
  expect_ok "$NS 有 allow-dns（53 端口出站到 kube-dns）" \
    bash -c "kubectl -n $NS get networkpolicy allow-dns -o yaml | grep -q 'kube-system' && kubectl -n $NS get networkpolicy allow-dns -o yaml | grep -q '53'"
done

# 4. 按需放行策略存在且端口正确
expect_ok "backend ns 有 allow-frontend-to-backend（TCP 80）" \
  bash -c "kubectl -n $BE get networkpolicy allow-frontend-to-backend -o yaml | grep -q '$FE' && kubectl -n $BE get networkpolicy allow-frontend-to-backend -o yaml | grep -q 'port: 80'"
expect_ok "db ns 有 allow-backend-to-db（TCP 80）" \
  bash -c "kubectl -n $DB get networkpolicy allow-backend-to-db -o yaml | grep -q '$BE' && kubectl -n $DB get networkpolicy allow-backend-to-db -o yaml | grep -q 'port: 80'"

# 5. 连通性矩阵（exec 只读探测；被拒表现为超时/非零退出）
expect_ok "frontend -> backend:80 放行" \
  bash -c "kubectl -n $FE exec fe-client -- wget -q -T 5 -O /dev/null http://backend.$BE.svc.cluster.local"
expect_ok "backend -> db:80 放行" \
  bash -c "kubectl -n $BE exec backend -- curl -s -m 5 -o /dev/null http://db.$DB.svc.cluster.local"
expect_fail "frontend -> db:80 被拒（超时）" \
  bash -c "kubectl -n $FE exec fe-client -- wget -q -T 5 -O /dev/null http://db.$DB.svc.cluster.local"
expect_fail "frontend -> 外网 1.1.1.1:80 被拒（超时）" \
  bash -c "kubectl -n $FE exec fe-client -- wget -q -T 5 -O /dev/null http://1.1.1.1"

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
