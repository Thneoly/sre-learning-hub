#!/usr/bin/env bash
# Lab 05 判分脚本 —— RuntimeClass 对象与 Pod 引用（只读，不修改集群）
# 运行位置：master 节点（kubectl 管理员权限；如节点装有 gvisor runtime，额外验证 Pod Running）
# 前提：已按 task.md 完成实验（RuntimeClass gvisor、ns cks-lab05、Pod sandbox-web）
#       未安装 gVisor 的模拟环境同样可判分（Pod 只需存在且 spec 正确）
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

NS=cks-lab05
POD=sandbox-web

# 1. namespace 存在
expect_ok "namespace $NS 存在" kubectl get namespace "$NS"

# 2. RuntimeClass 对象存在且 handler=gvisor
expect_ok "RuntimeClass gvisor 存在" kubectl get runtimeclass gvisor
expect_ok "RuntimeClass handler 为 gvisor" \
  bash -c "kubectl get runtimeclass gvisor -o jsonpath='{.handler}' | grep -qx gvisor"

# 3. Pod 存在且 spec.runtimeClassName=gvisor
expect_ok "Pod $POD 存在于 $NS" kubectl -n "$NS" get pod "$POD"
expect_ok "Pod spec.runtimeClassName 为 gvisor" \
  bash -c "kubectl -n $NS get pod $POD -o jsonpath='{.spec.runtimeClassName}' | grep -qx gvisor"

# 4. 运行状态检查：
#    - 节点已注册 gvisor runtime（containerd 配置中出现 runtimes.gvisor）→ 要求 Pod Running
#    - 未注册（模拟环境）→ 只要求 Pod 对象存在（上面第 3 项已覆盖），输出 SIMULATED 说明
if grep -q 'runtimes.gvisor' /etc/containerd/config.toml 2>/dev/null; then
  expect_ok "节点已注册 gvisor runtime，Pod 应为 Running" \
    bash -c "kubectl -n $NS get pod $POD -o jsonpath='{.status.phase}' | grep -qx Running"
  expect_ok "沙箱生效：容器内 dmesg 输出含 gVisor" \
    bash -c "kubectl -n $NS exec $POD -- dmesg 2>/dev/null | head -1 | grep -q gVisor"
else
  echo "SIMULATED: 节点未注册 gvisor runtime，跳过 Running/dmesg 检查（模拟环境按 spec 判分）"
  pass "模拟环境：RuntimeClass 与 Pod spec 引用完整"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
