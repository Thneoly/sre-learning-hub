#!/usr/bin/env bash
# Lab 02 判分脚本（ArgoCD GitOps 终态检查）
# 运行环境：kubeadm 练习集群的 master 节点（Ubuntu 22.04/24.04，kubectl 可用）
# 假设：已完成 task.md 的任务（终态：argocd 已安装、Application demo-app 存在、demo/demo 的 nginx replicas=3）
# 用法：chmod +x check.sh && ./check.sh
# 说明：只读检查（kubectl get/jsonpath 查询比对），不修改集群任何状态
set -u

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

check() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc"
  fi
}

command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl 未安装或不在 PATH"; exit 1; }

APP="demo-app"
NS_APP="argocd"

# 1. argocd 命名空间存在
check "argocd 命名空间存在" \
  bash -c '[ "$(kubectl get ns argocd -o jsonpath="{.status.phase}" 2>/dev/null)" = "Active" ]'

# 2. argocd-server Deployment 可用（Available）
check "argocd-server Deployment 处于 Available" \
  bash -c '[ "$(kubectl -n argocd get deploy argocd-server -o jsonpath="{.status.conditions[?(@.type==\"Available\")].status}" 2>/dev/null)" = "True" ]'

# 3. Application demo-app 存在于 argocd 命名空间
check "Application demo-app 存在" \
  bash -c '[ "$(kubectl -n argocd get application.argoproj.io demo-app -o jsonpath="{.metadata.name}" 2>/dev/null)" = "demo-app" ]'

# 4. 健康状态为 Healthy
check "Application 健康状态为 Healthy" \
  bash -c '[ "$(kubectl -n argocd get application.argoproj.io demo-app -o jsonpath="{.status.health.status}" 2>/dev/null)" = "Healthy" ]'

# 5. 同步状态为 Synced
check "Application 同步状态为 Synced" \
  bash -c '[ "$(kubectl -n argocd get application.argoproj.io demo-app -o jsonpath="{.status.sync.status}" 2>/dev/null)" = "Synced" ]'

# 6. source 指向 demo-app.git 仓库
check "source.repoURL 指向 demo-app.git" \
  bash -c 'kubectl -n argocd get application.argoproj.io demo-app -o jsonpath="{.spec.source.repoURL}" 2>/dev/null | grep -q "demo-app.git"'

# 7. syncPolicy.automated.selfHeal 为 true
check "syncPolicy 开启 selfHeal" \
  bash -c '[ "$(kubectl -n argocd get application.argoproj.io demo-app -o jsonpath="{.spec.syncPolicy.automated.selfHeal}" 2>/dev/null)" = "true" ]'

# 8. syncPolicy.automated.prune 为 true
check "syncPolicy 开启 prune" \
  bash -c '[ "$(kubectl -n argocd get application.argoproj.io demo-app -o jsonpath="{.spec.syncPolicy.automated.prune}" 2>/dev/null)" = "true" ]'

# 9. 目标命名空间为 demo
check "destination.namespace 为 demo" \
  bash -c '[ "$(kubectl -n argocd get application.argoproj.io demo-app -o jsonpath="{.spec.destination.namespace}" 2>/dev/null)" = "demo" ]'

# 10. demo 命名空间的 nginx Deployment 期望副本数为 3
check "demo/nginx Deployment 期望 replicas 为 3" \
  bash -c '[ "$(kubectl -n demo get deploy nginx -o jsonpath="{.spec.replicas}" 2>/dev/null)" = "3" ]'

# 11. demo 命名空间的 nginx Deployment 就绪副本数为 3
check "demo/nginx Deployment readyReplicas 为 3" \
  bash -c '[ "$(kubectl -n demo get deploy nginx -o jsonpath="{.status.readyReplicas}" 2>/dev/null)" = "3" ]'

# 12. demo 命名空间存在 nginx Service
check "demo 命名空间存在 nginx Service" \
  bash -c 'kubectl -n demo get svc nginx -o name 2>/dev/null | grep -q "service/nginx"'

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
