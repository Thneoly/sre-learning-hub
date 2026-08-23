#!/usr/bin/env bash
# Lab 02 判分脚本 —— Pod Security Admission 三级模式（只读，不修改集群）
# 运行位置：master 节点（kubectl 管理员权限）
# 前提：已按 task.md 完成实验（三个 cks-lab02-* namespace、Pod good/bad 等）
# 用法：chmod +x check.sh && ./check.sh
set -u

PASS=0
FAIL=0
TOTAL=0

pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $*"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# expect_ok "描述" 命令...：退出码 0 记 PASS
expect_ok() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}
# expect_fail "描述" 命令...：退出码非 0 记 PASS（用于"资源应不存在"）
expect_fail() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else pass "$desc"; fi
}

E=cks-lab02-enforce
A=cks-lab02-audit
W=cks-lab02-warn

# 1~3. 三个 namespace 的 PSA 标签（label 值只能是标准名；版本是独立的 <mode>-version 标签）
expect_ok "ns $E 标签 enforce=restricted" \
  bash -c "kubectl get ns $E -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' | grep -qx restricted"
expect_ok "ns $A 标签 audit=restricted" \
  bash -c "kubectl get ns $A -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/audit}' | grep -qx restricted"
expect_ok "ns $W 标签 warn=restricted" \
  bash -c "kubectl get ns $W -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/warn}' | grep -qx restricted"

# 4. enforce ns 里违规 Pod 被拒绝（从未创建）
expect_fail "enforce ns 中违规 Pod bad 不存在（被 admission 拒绝）" \
  kubectl -n "$E" get pod bad

# 5. audit / warn ns 里违规 Pod 允许运行
expect_ok "audit ns 中 Pod bad 为 Running" \
  bash -c "kubectl -n $A get pod bad -o jsonpath='{.status.phase}' | grep -qx 'Running'"
expect_ok "warn ns 中 Pod bad 为 Running" \
  bash -c "kubectl -n $W get pod bad -o jsonpath='{.status.phase}' | grep -qx 'Running'"

# 6. enforce ns 里合规 Pod good 在跑，且满足 restricted 关键字段
expect_ok "enforce ns 中 Pod good 为 Running" \
  bash -c "kubectl -n $E get pod good -o jsonpath='{.status.phase}' | grep -qx 'Running'"
expect_ok "good 容器 runAsNonRoot=true" \
  bash -c "kubectl -n $E get pod good -o jsonpath='{.spec.containers[0].securityContext.runAsNonRoot}' | grep -qx 'true'"
expect_ok "good 容器 allowPrivilegeEscalation=false" \
  bash -c "kubectl -n $E get pod good -o jsonpath='{.spec.containers[0].securityContext.allowPrivilegeEscalation}' | grep -qx 'false'"
expect_ok "good 容器 capabilities.drop 含 ALL" \
  bash -c "kubectl -n $E get pod good -o jsonpath='{.spec.containers[0].securityContext.capabilities.drop[0]}' | grep -qx 'ALL'"
expect_ok "good 容器 seccompProfile=RuntimeDefault" \
  bash -c "kubectl -n $E get pod good -o jsonpath='{.spec.containers[0].securityContext.seccompProfile.type}' | grep -qx 'RuntimeDefault'"

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
