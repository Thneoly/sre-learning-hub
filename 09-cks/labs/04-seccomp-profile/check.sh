#!/usr/bin/env bash
# Lab 04 判分脚本 —— Seccomp RuntimeDefault 与自定义 profile（只读，不修改集群）
# 运行位置：master 节点（Pod 调度在 master，自定义 profile 位于本机 kubelet 目录）
# 前提：已按 task.md 完成实验（ns cks-lab04、Pod seccomp-default / seccomp-block-chmod、
#       /var/lib/kubelet/seccomp/profiles/block-chmod.json）
# 用法：sudo ./check.sh   ——/var/lib/kubelet 目录 0700 仅 root 可读，普通用户跑会连挂 4 项；
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

NS=cks-lab04
PROFILE=/var/lib/kubelet/seccomp/profiles/block-chmod.json

# 1. namespace 存在
expect_ok "namespace $NS 存在" kubectl get namespace "$NS"

# 2. 自定义 profile 文件存在且内容正确
expect_ok "profile 文件 $PROFILE 存在" test -f "$PROFILE"
expect_ok "profile 默认动作 SCMP_ACT_ALLOW" \
  bash -c "grep -q 'SCMP_ACT_ALLOW' $PROFILE"
expect_ok "profile 将 chmod/fchmod/fchmodat 设为 SCMP_ACT_ERRNO" \
  bash -c "grep -q 'chmod' $PROFILE && grep -q 'SCMP_ACT_ERRNO' $PROFILE"
expect_ok "profile 是合法 JSON" \
  bash -c "python3 -m json.tool $PROFILE >/dev/null"

# 3. Pod seccomp-default：Running + RuntimeDefault
expect_ok "Pod seccomp-default 为 Running" \
  bash -c "kubectl -n $NS get pod seccomp-default -o jsonpath='{.status.phase}' | grep -qx Running"
expect_ok "seccomp-default 引用 RuntimeDefault" \
  bash -c "kubectl -n $NS get pod seccomp-default -o jsonpath='{.spec.containers[0].securityContext.seccompProfile.type}' | grep -qx RuntimeDefault"

# 4. Pod seccomp-block-chmod：Running + Localhost/profiles/block-chmod.json
expect_ok "Pod seccomp-block-chmod 为 Running" \
  bash -c "kubectl -n $NS get pod seccomp-block-chmod -o jsonpath='{.status.phase}' | grep -qx Running"
expect_ok "seccomp-block-chmod 引用 Localhost profile" \
  bash -c "kubectl -n $NS get pod seccomp-block-chmod -o jsonpath='{.spec.containers[0].securityContext.seccompProfile.type} {.spec.containers[0].securityContext.seccompProfile.localhostProfile}' | grep -qx 'Localhost profiles/block-chmod.json'"

# 5. 行为验证：限制 Pod 内 chmod 失败（EPERM），对照组成功
expect_fail "限制 Pod 内 chmod 被拒（Operation not permitted）" \
  kubectl -n "$NS" exec seccomp-block-chmod -- chmod 400 /tmp/f
expect_ok "对照 Pod 内 chmod 成功（RuntimeDefault 不拦 chmod）" \
  bash -c "kubectl -n $NS exec seccomp-default -- sh -c 'touch /tmp/f && chmod 400 /tmp/f'"

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
