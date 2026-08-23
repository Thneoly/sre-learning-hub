#!/usr/bin/env bash
# Lab 14 · kubeadm 升级演练(cordon/drain/plan) 检查脚本
# 用法: chmod 755 check.sh && ./check.sh
# 前置假设:
#   - 在 master 节点上运行(kubectl admin kubeconfig 可用)
#   - 已按 task.md 完成: Deployment lab14-nginx 恢复 2/2、节点已 uncordon、
#     /tmp/lab14-plan.txt 与 /tmp/lab14-answers.txt 已生成
#   - 本脚本只读, 不执行任何变更(不真正升级集群)
set -u

PLAN=/tmp/lab14-plan.txt
ANSWERS=/tmp/lab14-answers.txt
PASS=0; FAIL=0; TOTAL=0
pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$NODE" ]; then
  echo "FAIL: 无法获取节点名(kubectl 不可用或集群异常)"
  echo "SCORE: 0/9"
  exit 1
fi

# 1. 节点 Ready
READY=$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$READY" = "True" ]; then
  pass "节点 $NODE 为 Ready"
else
  fail "节点 $NODE 状态为 '$READY'(应为 True)"
fi

# 2. 节点已 uncordon(可调度)
UNSCHED=$(kubectl get node "$NODE" -o jsonpath='{.spec.unschedulable}' 2>/dev/null || true)
if [ -z "$UNSCHED" ] || [ "$UNSCHED" = "false" ]; then
  pass "节点 $NODE 已解除 cordon(可调度)"
else
  fail "节点 $NODE 仍处于 SchedulingDisabled(忘记 uncordon?)"
fi

# 3. Deployment 恢复 2/2
if kubectl get deploy lab14-nginx >/dev/null 2>&1; then
  pass "Deployment lab14-nginx 存在"
else
  fail "Deployment lab14-nginx 不存在"
fi
AVAIL=$(kubectl get deploy lab14-nginx -o jsonpath='{.status.availableReplicas}' 2>/dev/null || true)
if [ "$AVAIL" = "2" ]; then
  pass "lab14-nginx availableReplicas=2"
else
  fail "lab14-nginx availableReplicas='$AVAIL'(应为 2)"
fi

# 4. Pod 全部 Running
RUNNING=$(kubectl get pods -l app=lab14-nginx --no-headers 2>/dev/null | grep -c "Running" || true)
if [ "$RUNNING" = "2" ]; then
  pass "lab14-nginx 两个 Pod 均 Running"
else
  fail "lab14-nginx Running Pod 数为 '$RUNNING'(应为 2)"
fi

# 5. plan 存档存在且含关键行
if [ -f "$PLAN" ]; then
  if grep -q "kubeadm upgrade apply" "$PLAN" 2>/dev/null; then
    pass "plan 存档存在且包含 'kubeadm upgrade apply' 提示行"
  else
    fail "plan 存档内容不含 'kubeadm upgrade apply'(确认存的是完整 plan 输出)"
  fi
else
  fail "plan 存档 $PLAN 不存在"
fi

# 6. answers 文件格式正确且 CURRENT 与 kubelet 版本一致
if [ -f "$ANSWERS" ]; then
  CURRENT=$(grep -E '^CURRENT=' "$ANSWERS" | head -1 | cut -d= -f2 | tr -d '[:space:]')
  TARGET=$(grep -E '^TARGET=' "$ANSWERS" | head -1 | cut -d= -f2 | tr -d '[:space:]')
  MANUAL=$(grep -E '^MANUAL=' "$ANSWERS" | head -1)
  KUBELET_VER=$(kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || true)
  if [ -n "$CURRENT" ] && [ "$CURRENT" = "$KUBELET_VER" ]; then
    pass "answers 的 CURRENT=$CURRENT 与 kubelet 版本一致"
  else
    fail "answers 的 CURRENT='$CURRENT' 与 kubelet 版本 '$KUBELET_VER' 不一致"
  fi
  if [ -n "$TARGET" ] && grep -q "$TARGET" "$PLAN" 2>/dev/null; then
    pass "answers 的 TARGET=$TARGET 出现在 plan 输出中"
  else
    fail "answers 的 TARGET='$TARGET' 未出现在 plan 输出中"
  fi
  if [ -n "$MANUAL" ]; then
    pass "answers 包含 MANUAL= 组件说明行"
  else
    fail "answers 缺少 MANUAL= 行"
  fi
else
  fail "answers 文件 $ANSWERS 不存在"
  fail "answers 的 TARGET 检查跳过(文件不存在)"
  fail "answers 的 MANUAL 检查跳过(文件不存在)"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then exit 0; fi
exit 1
