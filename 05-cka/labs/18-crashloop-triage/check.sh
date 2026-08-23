#!/usr/bin/env bash
# Lab 18 · ImagePullBackOff/CrashLoopBackOff 排障 检查脚本
# 用法: chmod 755 check.sh && ./check.sh
# 前置假设:
#   - 在能以 admin kubeconfig 访问集群的节点上运行(练习环境即 master)
#   - 已按 task.md 完成修复: Deployment broken-app(cka-triage)以 nginx:1.27-alpine
#     默认入口运行, 2/2 Available
set -u

NS=cka-triage
PASS=0; FAIL=0; TOTAL=0
pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# 1. namespace 与 Deployment 存在
if kubectl get ns "$NS" >/dev/null 2>&1; then
  pass "namespace $NS 存在"
else
  fail "namespace $NS 不存在"
fi
if kubectl -n "$NS" get deploy broken-app >/dev/null 2>&1; then
  pass "Deployment broken-app 存在"
else
  fail "Deployment broken-app 不存在"
fi

# 2. 镜像已修正
IMG=$(kubectl -n "$NS" get deploy broken-app -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
if [ "$IMG" = "nginx:1.27-alpine" ]; then
  pass "镜像为 nginx:1.27-alpine"
else
  fail "镜像为 '$IMG'(应为 nginx:1.27-alpine)"
fi

# 3. command 覆盖已移除
CMD=$(kubectl -n "$NS" get deploy broken-app -o jsonpath='{.spec.template.spec.containers[0].command}' 2>/dev/null || true)
ARGS=$(kubectl -n "$NS" get deploy broken-app -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null || true)
if [ -z "$CMD" ] && [ -z "$ARGS" ]; then
  pass "command/args 覆盖已移除(使用镜像默认入口)"
else
  fail "仍存在 command/args 覆盖(command='$CMD' args='$ARGS')"
fi

# 4. replicas 2/2 Available
AVAIL=$(kubectl -n "$NS" get deploy broken-app -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
if [ "$AVAIL" = "2" ]; then
  pass "availableReplicas=2"
else
  fail "availableReplicas='$AVAIL'(应为 2)"
fi

# 5. 两个 Pod 均 Running
RUNNING=$(kubectl -n "$NS" get pods -l app=broken-app --no-headers 2>/dev/null | grep -c "Running" || true)
if [ "$RUNNING" = "2" ]; then
  pass "broken-app 的两个 Pod 均 Running"
else
  fail "Running Pod 数为 '$RUNNING'(应为 2)"
fi

# 6. 无重启风暴: 容器 restartCount 均 <= 2(修复后稳定运行)
MAXRC=$(kubectl -n "$NS" get pods -l app=broken-app -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null | tr ' ' '\n' | sort -n | tail -1)
if [ "${MAXRC:-99}" -le 2 ]; then
  pass "容器 restartCount 稳定(最大 ${MAXRC})"
else
  fail "容器仍在反复重启(max restartCount=${MAXRC})"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then exit 0; fi
exit 1
