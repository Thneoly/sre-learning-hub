#!/usr/bin/env bash
# Lab 15 · 静态 Pod 修复 检查脚本
# 用法: chmod 755 check.sh && ./check.sh
# 前置假设:
#   - 在 master 节点上运行(需要读 /etc/kubernetes/manifests 与 kubectl)
#   - 已按 task.md 完成任务: manifest 修复并放回, static-web-<node> Running
set -u

MANIFEST=/etc/kubernetes/manifests/static-web.yaml
PASS=0; FAIL=0; TOTAL=0
pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$NODE" ]; then
  echo "FAIL: 无法获取节点名(kubectl 不可用或集群异常)"
  echo "SCORE: 0/6"
  exit 1
fi
POD="static-web-${NODE}"

# 1. manifest 文件在位
if [ -f "$MANIFEST" ]; then
  pass "manifest $MANIFEST 存在"
else
  fail "manifest $MANIFEST 不存在"
fi

# 2. manifest 中 name 小写合法
NAME_IN_FILE=$(grep -E '^\s*name:\s*' "$MANIFEST" 2>/dev/null | head -1 | awk '{print $2}')
if [ "$NAME_IN_FILE" = "static-web" ]; then
  pass "manifest 中 Pod name 为 static-web(小写合法)"
else
  fail "manifest 中 name='$NAME_IN_FILE'(应为 static-web)"
fi

# 3. manifest 中 image 小写合法
IMAGE_IN_FILE=$(grep -E '^\s*image:\s*' "$MANIFEST" 2>/dev/null | head -1 | awk '{print $2}')
if [ "$IMAGE_IN_FILE" = "nginx:1.27-alpine" ]; then
  pass "manifest 中 image 为 nginx:1.27-alpine(小写合法)"
else
  fail "manifest 中 image='$IMAGE_IN_FILE'(应为 nginx:1.27-alpine)"
fi

# 4. 静态 Pod 已创建且 Running
if kubectl get pod "$POD" >/dev/null 2>&1; then
  PHASE=$(kubectl get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  if [ "$PHASE" = "Running" ]; then
    pass "静态 Pod $POD 为 Running"
  else
    fail "静态 Pod $POD 状态为 '$PHASE'(应为 Running)"
  fi
else
  fail "静态 Pod $POD 不存在(manifest 未被 kubelet 接受?)"
fi

# 5. 运行中的 Pod image 正确
RUN_IMAGE=$(kubectl get pod "$POD" -o jsonpath='{.spec.containers[0].image}' 2>/dev/null || true)
if [ "$RUN_IMAGE" = "nginx:1.27-alpine" ]; then
  pass "运行中 Pod 的 image 为 nginx:1.27-alpine"
else
  fail "运行中 Pod 的 image='$RUN_IMAGE'(应为 nginx:1.27-alpine)"
fi

# 6. ownerReferences 证明是静态 Pod
OWNER_KIND=$(kubectl get pod "$POD" -o jsonpath='{.metadata.ownerReferences[0].kind}' 2>/dev/null || true)
if [ "$OWNER_KIND" = "Node" ]; then
  pass "ownerReferences.kind=Node(确为 kubelet 管理的静态 Pod)"
else
  fail "ownerReferences.kind='$OWNER_KIND'(应为 Node)"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then exit 0; fi
exit 1
