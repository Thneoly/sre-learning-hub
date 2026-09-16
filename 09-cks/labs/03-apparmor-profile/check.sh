#!/usr/bin/env bash
# Lab 03 判分脚本 —— AppArmor profile 加载与 Pod 引用（只读，不修改集群）
# 运行位置：master 节点（本实验 Pod 调度在 master，profile 在本机）
# 前提：已按 task.md 完成实验（/etc/apparmor.d/docker-nginx-cks、Pod nginx-apparmor）
# 用法：sudo ./check.sh   ——读 /sys/kernel/security/apparmor/profiles 需要 root；
#       root 下 kubectl 自动回退 /etc/kubernetes/admin.conf，普通用户的 ~/.kube/config 也可用
set -u

# kubectl 兜底：root 读 /etc/kubernetes/admin.conf，普通用户用 ~/.kube/config
if [ -z "${KUBECONFIG:-}" ]; then
  if [ -r "$HOME/.kube/config" ]; then
    export KUBECONFIG="$HOME/.kube/config"
  else
    export KUBECONFIG=/etc/kubernetes/admin.conf
  fi
fi

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

NS=cks-lab03
POD=nginx-apparmor
PROFILE=docker-nginx-cks

# 1. namespace 存在
expect_ok "namespace $NS 存在" kubectl get namespace "$NS"

# 2. profile 文件存在且包含 deny /etc/shadow 与日志白名单
expect_ok "profile 文件 /etc/apparmor.d/$PROFILE 存在" test -f "/etc/apparmor.d/$PROFILE"
expect_ok "profile 显式 deny /etc/shadow" \
  bash -c "grep -q 'deny /etc/shadow' /etc/apparmor.d/$PROFILE"
expect_ok "profile 允许写 /var/log/nginx/**" \
  bash -c "grep -q '/var/log/nginx/\*\* rw' /etc/apparmor.d/$PROFILE"

# 3. profile 已加载且 enforce（读内核 apparmor profile 列表需要 root，见头部用法说明）
expect_ok "profile $PROFILE 已加载为 enforce 模式" \
  bash -c "grep -q '^$PROFILE (enforce)' /sys/kernel/security/apparmor/profiles"

# 4. Pod Running 且 annotation 引用 localhost profile
expect_ok "Pod $POD 为 Running" \
  bash -c "kubectl -n $NS get pod $POD -o jsonpath='{.status.phase}' | grep -qx Running"
expect_ok "annotation 引用 localhost/$PROFILE" \
  bash -c "kubectl -n $NS get pod $POD -o jsonpath='{.metadata.annotations.container\.apparmor\.security\.beta\.kubernetes\.io/nginx}' | grep -qx 'localhost/$PROFILE'"

# 5. 运行期验证：写 /tmp 被拒、读 shadow 被拒、nginx 仍正常响应
expect_fail "Pod 内 touch /tmp/pwned 被拒（Permission denied）" \
  kubectl -n "$NS" exec "$POD" -c nginx -- touch /tmp/pwned
expect_fail "Pod 内 cat /etc/shadow 被拒（Permission denied）" \
  kubectl -n "$NS" exec "$POD" -c nginx -- cat /etc/shadow
expect_ok "Pod 内 nginx 正常响应 200" \
  bash -c "kubectl -n $NS exec $POD -c nginx -- curl -s -o /dev/null -w '%{http_code}' localhost | grep -qx 200"

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
