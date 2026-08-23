#!/usr/bin/env bash
# Lab 12 · ServiceAccount Token 权限检查脚本
# 用法: chmod 755 check.sh && ./check.sh
# 前置假设:
#   - 在能以 admin kubeconfig 访问集群的节点上运行(练习环境即 master)
#   - 已按 task.md 完成任务: ns cka-sa / SA ci-bot / Role ci-deployer / RoleBinding ci-bot-deployer
set -u

NS=cka-sa
SAAS="system:serviceaccount:cka-sa:ci-bot"
PASS=0; FAIL=0; TOTAL=0
pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# 1. namespace 与 ServiceAccount 存在
if kubectl get ns "$NS" >/dev/null 2>&1; then
  pass "namespace $NS 存在"
else
  fail "namespace $NS 不存在"
fi
if kubectl -n "$NS" get serviceaccount ci-bot >/dev/null 2>&1; then
  pass "ServiceAccount ci-bot 存在于 $NS"
else
  fail "ServiceAccount ci-bot 不存在于 $NS"
fi

# 2. Role ci-deployer 存在且覆盖 deployments/pods/pods/log
if kubectl -n "$NS" get role ci-deployer >/dev/null 2>&1; then
  pass "Role ci-deployer 存在于 $NS"
else
  fail "Role ci-deployer 不存在于 $NS"
fi
ROLE_JSON=$(kubectl -n "$NS" get role ci-deployer -o json 2>/dev/null || echo '{}')
if echo "$ROLE_JSON" | grep -q '"deployments"' && echo "$ROLE_JSON" | grep -q '"pods/log"' \
   && echo "$ROLE_JSON" | grep -q '"apps"' && echo "$ROLE_JSON" | grep -q '"create"'; then
  pass "Role 规则覆盖 deployments(apps) 与 pods/pods/log"
else
  fail "Role 规则不完整(应含 apps/deployments、pods、pods/log 且有 create)"
fi

# 3. RoleBinding subject 为 ServiceAccount/ci-bot
if kubectl -n "$NS" get rolebinding ci-bot-deployer >/dev/null 2>&1; then
  pass "RoleBinding ci-bot-deployer 存在"
else
  fail "RoleBinding ci-bot-deployer 不存在"
fi
SUBJ_KIND=$(kubectl -n "$NS" get rolebinding ci-bot-deployer -o jsonpath='{.subjects[0].kind}' 2>/dev/null || true)
SUBJ_NAME=$(kubectl -n "$NS" get rolebinding ci-bot-deployer -o jsonpath='{.subjects[0].name}' 2>/dev/null || true)
SUBJ_NS=$(kubectl -n "$NS" get rolebinding ci-bot-deployer -o jsonpath='{.subjects[0].namespace}' 2>/dev/null || true)
ROLEREF=$(kubectl -n "$NS" get rolebinding ci-bot-deployer -o jsonpath='{.roleRef.name}' 2>/dev/null || true)
if [ "$SUBJ_KIND" = "ServiceAccount" ] && [ "$SUBJ_NAME" = "ci-bot" ] && [ "$SUBJ_NS" = "$NS" ] && [ "$ROLEREF" = "ci-deployer" ]; then
  pass "RoleBinding 将 SA cka-sa/ci-bot 绑定到 ci-deployer"
else
  fail "RoleBinding 绑定关系不对 (kind=$SUBJ_KIND name=$SUBJ_NAME ns=$SUBJ_NS roleRef=$ROLEREF)"
fi

# 4. can-i 验证: 授权范围内 yes
if [ "$(kubectl auth can-i create deployments.apps -n "$NS" --as="$SAAS" 2>/dev/null)" = "yes" ]; then
  pass "SA 可在 $NS 内 create deployments (can-i=yes)"
else
  fail "SA 应能在 $NS 内 create deployments (can-i 应为 yes)"
fi

# 5. can-i 验证: 集群级资源 no
if [ "$(kubectl auth can-i get nodes --as="$SAAS" 2>/dev/null)" = "no" ]; then
  pass "SA 不能 get nodes (最小权限)"
else
  fail "SA 不应能 get nodes (绑到集群级权限了?)"
fi

# 6. can-i 验证: 跨 namespace no
if [ "$(kubectl auth can-i get pods -n default --as="$SAAS" 2>/dev/null)" = "no" ]; then
  pass "SA 在 default 内不能 get pods (namespace 隔离)"
else
  fail "SA 在 default 内不应能 get pods"
fi

# 7. 真实 token 调用: 域内 get pods 成功
#    注意: kubeconfig 走客户端证书认证时 kubectl --token 不生效(证书优先于 token),
#    必须用 curl 只带 token 调用才能验证 SA 身份
TOKEN=$(kubectl create token ci-bot -n "$NS" 2>/dev/null || true)
APISERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
HTTP_PODS=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/namespaces/$NS/pods" 2>/dev/null || true)
if [ -n "$TOKEN" ] && [ "$HTTP_PODS" = "200" ]; then
  pass "token 身份可在 $NS 内 get pods (真实调用 HTTP $HTTP_PODS)"
else
  fail "token 身份应能在 $NS 内 get pods (HTTP=$HTTP_PODS, create token 或 RoleBinding 有问题)"
fi

# 8. 真实 token 调用: get nodes 被拒
HTTP_NODES=$(curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $TOKEN" \
  "$APISERVER/api/v1/nodes" 2>/dev/null || true)
if [ -n "$TOKEN" ] && [ "$HTTP_NODES" = "403" ]; then
  pass "token 身份 get nodes 被拒绝 (HTTP $HTTP_NODES)"
else
  fail "token 身份 get nodes 应返回 403 (实际 HTTP=$HTTP_NODES, 权限越界?)"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then exit 0; fi
exit 1
