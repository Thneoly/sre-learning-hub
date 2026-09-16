#!/usr/bin/env bash
# Lab 01 判分脚本 —— Trivy 镜像扫描与高危镜像阻断（只读，不修改集群）
# 运行位置：master 节点（kubectl 管理员权限；同时检查本机文件 /usr/local/bin/image-gate.sh）
# 前提：已按 task.md 完成全部步骤（namespace cks-lab01、ConfigMap image-gate-report、Pod web）
# 用法：chmod +x check.sh && ./check.sh
set -u

PASS=0
FAIL=0
TOTAL=0

pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $*"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $*"; }

# expect_ok "描述" 命令...：命令退出码 0 记 PASS
expect_ok() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then pass "$desc"; else fail "$desc"; fi
}

NS=cks-lab01

# 1. namespace 存在
expect_ok "namespace $NS 存在" kubectl get namespace "$NS"

# 2. 留档 ConfigMap 存在
expect_ok "ConfigMap image-gate-report 存在于 $NS" kubectl -n "$NS" get configmap image-gate-report

# 3. blocked 记录 = nginx:1.16
expect_ok "ConfigMap 记录 blocked=nginx:1.16" \
  bash -c "kubectl -n $NS get configmap image-gate-report -o jsonpath='{.data.blocked}' | grep -qx 'nginx:1.16'"

# 4. allowed 记录 = nginx:alpine 且 tool=trivy
expect_ok "ConfigMap 记录 allowed=nginx:alpine" \
  bash -c "kubectl -n $NS get configmap image-gate-report -o jsonpath='{.data.allowed}' | grep -qx 'nginx:alpine'"
expect_ok "ConfigMap 记录 tool=trivy" \
  bash -c "kubectl -n $NS get configmap image-gate-report -o jsonpath='{.data.tool}' | grep -qx 'trivy'"

# 5. 只有放行的镜像被部署
expect_ok "Pod web 为 Running 且镜像 nginx:alpine" \
  bash -c "kubectl -n $NS get pod web -o jsonpath='{.status.phase} {.spec.containers[0].image}' | grep -q 'Running nginx:alpine'"

# 6. 高危镜像没有进入集群（全集群无 nginx:1.16 的 Pod）
expect_ok "集群中不存在 nginx:1.16 的 Pod" \
  bash -c "! kubectl get pods -A -o jsonpath='{range .items[*]}{.spec.containers[*].image}{\"\\n\"}{end}' | grep -q 'nginx:1.16'"

# 7. 闸门脚本存在、可执行且调用 trivy
expect_ok "/usr/local/bin/image-gate.sh 存在、可执行且调用 trivy" \
  bash -c "test -x /usr/local/bin/image-gate.sh && grep -q trivy /usr/local/bin/image-gate.sh"

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
