#!/usr/bin/env bash
# Lab 06 判分脚本 —— Audit Policy 配置与日志验证（只读，不修改集群）
# 运行位置：master 节点（kubeadm 静态 Pod 集群，apiserver manifest 在本机）
# 前提：已按 task.md 完成实验（policy 文件、apiserver flags、ns cks-lab06、
#       Secret db-password 已创建、Pod victim 已创建并删除）
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

POLICY=/etc/kubernetes/audit-policy.yaml
MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml
LOG=/var/log/kubernetes/audit.log

# 1. policy 文件存在且结构正确
expect_ok "policy 文件 $POLICY 存在" test -f "$POLICY"
expect_ok "policy apiVersion=audit.k8s.io/v1 且 kind=Policy" \
  bash -c "grep -q 'audit.k8s.io/v1' $POLICY && grep -q 'kind: Policy' $POLICY"
expect_ok "policy 全局 omitStages RequestReceived" \
  bash -c "grep -A3 'omitStages' $POLICY | grep -q RequestReceived"
expect_ok "policy 含 secrets 的 Metadata 规则" \
  bash -c "grep -A4 'level: Metadata' $POLICY | grep -q secrets"
expect_ok "policy 含 pods 的 RequestResponse 规则" \
  bash -c "grep -A5 'level: RequestResponse' $POLICY | grep -q pods"

# 2. apiserver manifest 已加 flags
expect_ok "apiserver manifest 含 --audit-policy-file" \
  bash -c "grep -q 'audit-policy-file' $MANIFEST"
expect_ok "apiserver manifest 含 --audit-log-path" \
  bash -c "grep -q 'audit-log-path' $MANIFEST"

# 3. apiserver 恢复运行
expect_ok "kube-apiserver 静态 Pod 为 Running" \
  bash -c "kubectl -n kube-system get pods -l component=kube-apiserver -o jsonpath='{.items[0].status.phase}' | grep -qx Running"

# 4. 日志文件存在、非空且为合法 JSON lines
expect_ok "audit log $LOG 存在且非空" \
  bash -c "test -s $LOG"
expect_ok "audit log 首行为合法 JSON 且含 auditID" \
  bash -c "head -1 $LOG | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if \"auditID\" in d else 1)'"

# 5. 事件可检索
expect_ok "日志含 Secret db-password 的 create 记录" \
  bash -c "grep 'db-password' $LOG | grep -q '\"verb\":\"create\"'"
expect_ok "日志含 Pod victim 的 create/delete 记录" \
  bash -c "grep '\"name\":\"victim\"' $LOG | grep -qE '\"verb\":\"(create|delete)\"'"
expect_ok "Pod create 记录带 requestObject（RequestResponse 生效）" \
  bash -c "grep '\"name\":\"victim\"' $LOG | grep '\"verb\":\"create\"' | grep -q requestObject"
expect_ok "system:kube-proxy 的 endpoints watch 未入日志" \
  bash -c "! grep '\"username\":\"system:kube-proxy\"' $LOG | grep -q '\"resource\":\"endpoints\"'"

# 6. 实验 namespace 存在
expect_ok "namespace cks-lab06 存在" kubectl get namespace cks-lab06

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
