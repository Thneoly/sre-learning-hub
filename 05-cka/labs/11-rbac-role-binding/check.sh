#!/usr/bin/env bash
# Lab 11 · RBAC Role/RoleBinding 检查脚本
# 用法: chmod 755 check.sh && ./check.sh
# 前置假设:
#   - 在能以 admin kubeconfig 访问集群的节点上运行(练习环境即 master)
#   - 已按 task.md 完成任务: namespace cka-rbac / Role pod-reader / RoleBinding dev-user-pod-reader
set -u

NS=cka-rbac
PASS=0; FAIL=0; TOTAL=0
pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# 1. namespace 存在
if kubectl get ns "$NS" >/dev/null 2>&1; then
  pass "namespace $NS 存在"
else
  fail "namespace $NS 不存在"
fi

# 2. Role pod-reader 存在
if kubectl -n "$NS" get role pod-reader >/dev/null 2>&1; then
  pass "Role pod-reader 存在于 $NS"
else
  fail "Role pod-reader 不存在于 $NS"
fi

# 3. Role 规则覆盖 pods(get/list/watch) 与 pods/log(get)
RULES_RES=$(kubectl -n "$NS" get role pod-reader -o jsonpath='{.rules[*].resources}' 2>/dev/null || true)
RULES_VERBS=$(kubectl -n "$NS" get role pod-reader -o jsonpath='{.rules[*].verbs}' 2>/dev/null || true)
if echo "$RULES_RES" | grep -q "pods/log" && echo "$RULES_RES" | grep -qw "pods" \
   && echo "$RULES_VERBS" | grep -qw "get" \
   && echo "$RULES_VERBS" | grep -qw "list" \
   && echo "$RULES_VERBS" | grep -qw "watch"; then
  pass "Role 规则覆盖 pods(get/list/watch) 与 pods/log"
else
  fail "Role 规则不完整 (resources=$RULES_RES verbs=$RULES_VERBS)"
fi

# 4. RoleBinding 存在
if kubectl -n "$NS" get rolebinding dev-user-pod-reader >/dev/null 2>&1; then
  pass "RoleBinding dev-user-pod-reader 存在"
else
  fail "RoleBinding dev-user-pod-reader 不存在"
fi

# 5. RoleBinding 的 subject 与 roleRef 正确
SUBJ_KIND=$(kubectl -n "$NS" get rolebinding dev-user-pod-reader -o jsonpath='{.subjects[0].kind}' 2>/dev/null || true)
SUBJ_NAME=$(kubectl -n "$NS" get rolebinding dev-user-pod-reader -o jsonpath='{.subjects[0].name}' 2>/dev/null || true)
ROLEREF=$(kubectl -n "$NS" get rolebinding dev-user-pod-reader -o jsonpath='{.roleRef.name}' 2>/dev/null || true)
if [ "$SUBJ_KIND" = "User" ] && [ "$SUBJ_NAME" = "dev-user" ] && [ "$ROLEREF" = "pod-reader" ]; then
  pass "RoleBinding 将 User dev-user 绑定到 Role pod-reader"
else
  fail "RoleBinding 绑定关系不对 (kind=$SUBJ_KIND name=$SUBJ_NAME roleRef=$ROLEREF)"
fi

# 6. 授权生效: dev-user 可以 get pods
if [ "$(kubectl auth can-i get pods -n "$NS" --as=dev-user 2>/dev/null)" = "yes" ]; then
  pass "dev-user 在 $NS 内可以 get pods (can-i=yes)"
else
  fail "dev-user 在 $NS 内应能 get pods (can-i 应为 yes)"
fi

# 7. 最小权限: dev-user 不能 create pods
if [ "$(kubectl auth can-i create pods -n "$NS" --as=dev-user 2>/dev/null)" = "no" ]; then
  pass "dev-user 在 $NS 内不能 create pods (最小权限)"
else
  fail "dev-user 在 $NS 内不应能 create pods (权限给多了)"
fi

# 8. namespace 隔离: dev-user 在 default 内无权限
if [ "$(kubectl auth can-i get pods -n default --as=dev-user 2>/dev/null)" = "no" ]; then
  pass "dev-user 在 default 内不能 get pods (namespace 隔离)"
else
  fail "dev-user 在 default 内不应能 get pods (Role 越界了?)"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then exit 0; fi
exit 1
