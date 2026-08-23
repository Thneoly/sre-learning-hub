#!/usr/bin/env bash
# Lab 16 · kubelet 排错 检查脚本
# 用法: chmod 755 check.sh && ./check.sh
# 前置假设:
#   - 在 master 节点上运行(需要 systemctl 查询 kubelet 状态 + kubectl)
#   - 已按 task.md 完成故障恢复: kubelet 已启动, 节点 Ready
#   - 脚本只读: systemctl is-active 与 kubectl get 均为只读查询
set -u

PASS=0; FAIL=0; TOTAL=0
pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $1"; }

NODE=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$NODE" ]; then
  echo "FAIL: 无法获取节点名(kubectl 不可用)"
  echo "SCORE: 0/5"
  exit 1
fi

# 1. kubelet 服务 active
IS_ACTIVE=$(systemctl is-active kubelet 2>/dev/null || true)
if [ "$IS_ACTIVE" = "active" ]; then
  pass "kubelet 服务为 active"
else
  fail "kubelet 服务为 '$IS_ACTIVE'(应为 active)"
fi

# 2. kubelet 未被 mask(能被正常 start)
IS_ENABLED=$(systemctl is-enabled kubelet 2>/dev/null || true)
if [ "$IS_ENABLED" != "masked" ]; then
  pass "kubelet 未被 mask"
else
  fail "kubelet 处于 masked 状态, 无法正常启动"
fi

# 3. 节点 Ready
READY=$(kubectl get node "$NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
if [ "$READY" = "True" ]; then
  pass "节点 $NODE 为 Ready"
else
  fail "节点 $NODE Ready='$READY'(应为 True)"
fi

# 4. kube-system 的核心 Pod 正常(static Pod 由 kubelet 管理, kubelet 恢复后应 Running)
BAD_CP=$(kubectl -n kube-system get pods --no-headers 2>/dev/null | grep -vcE "Running|Completed" || true)
if [ "${BAD_CP:-1}" = "0" ]; then
  pass "kube-system 所有 Pod 均 Running"
else
  fail "kube-system 存在非 Running 的 Pod(数量=$BAD_CP)"
fi

# 5. 业务 Pod 恢复: 存在至少一个非 kube-system 的 Running Pod(lab16-check 或既有业务)
RUNNING=$(kubectl get pods -A --no-headers 2>/dev/null \
  | awk '$1 != "kube-system" && $1 != "kube-public" && $1 != "kube-node-lease" {print $4}' \
  | grep -c "^Running$" || true)
if [ "${RUNNING:-0}" -ge 1 ]; then
  pass "业务 namespace 至少 1 个 Pod Running(调度能力已恢复)"
else
  fail "业务 namespace 没有 Running 的 Pod(节点可能仍未真正恢复)"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then exit 0; fi
exit 1
