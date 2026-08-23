#!/usr/bin/env bash
# Lab 07 判分脚本 —— Falco 运行时检测（只读，不修改集群）
# 运行位置：master 节点（kubectl 管理员权限）
# 前提：已按 task.md 完成实验。两种模式自动识别：
#   A. 完整模式：helm 部署了 falco DaemonSet（要求已触发 Read sensitive file 事件，
#      自定义规则 ConfigMap falco-custom-rules 存在于 falco ns）
#   B. 模拟模式：无法部署 Falco（替代验证方式），要求手工创建了
#      ns falco、ns cks-lab07、ConfigMap falco-custom-rules（含规则文本）
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

# 模式识别：falco ns 里有没有 DaemonSet
if kubectl -n falco get daemonset falco >/dev/null 2>&1; then
  MODE=full
  echo "MODE: full（检测到 falco DaemonSet）"
else
  MODE=simulated
  echo "MODE: simulated（未检测到 falco DaemonSet，走替代验证路径）"
fi

# 公共检查：两个 namespace + 自定义规则 ConfigMap
expect_ok "namespace falco 存在" kubectl get namespace falco
expect_ok "namespace cks-lab07 存在" kubectl get namespace cks-lab07

if [ "$MODE" = full ]; then
  # 1. DaemonSet 就绪
  expect_ok "falco DaemonSet 副本全部 Ready" \
    bash -c "kubectl -n falco get ds falco -o jsonpath='{.status.desiredNumberScheduled} {.status.numberReady}' | awk '\$1==\$2 && \$1>0'"

  # 2. falco 配置 ConfigMap 存在（helm 生成）
  expect_ok "falco 配置 ConfigMap 存在" \
    bash -c "kubectl -n falco get configmap | grep -q falco"

  # 3. 默认规则被触发：日志含敏感文件读取告警且涉及 /etc/shadow
  #    注意规则库版本差异：老版规则名直接出现在消息里（Read sensitive file trusted after startup），
  #    2024+ 规则库中容器读敏感文件走 rule "Read sensitive file untrusted"，
  #    日志消息文本为 "Sensitive file opened for reading by non-trusted program"，两者都匹配。
  expect_ok "Falco 日志含敏感文件读取告警（Read sensitive file / Sensitive file opened for reading）" \
    bash -c "kubectl -n falco logs daemonset/falco --all-containers 2>/dev/null | grep -qE 'Read sensitive file|Sensitive file opened for reading'"
  expect_ok "事件 cmdline 指向 cat /etc/shadow" \
    bash -c "kubectl -n falco logs daemonset/falco --all-containers 2>/dev/null | grep -E 'Read sensitive file|Sensitive file opened for reading' | grep -q 'cat /etc/shadow'"

  # 4. 自定义规则 ConfigMap 内容正确
  expect_ok "ConfigMap falco-custom-rules 存在于 falco ns" \
    kubectl -n falco get configmap falco-custom-rules
  expect_ok "自定义规则匹配 /etc/shadow 且含 rule/macro 定义" \
    bash -c "kubectl -n falco get configmap falco-custom-rules -o yaml | grep -q '/etc/shadow' && kubectl -n falco get configmap falco-custom-rules -o yaml | grep -qE '^- (rule|macro):|rule: |macro: '"
else
  # 模拟模式：以"规则配置证据"替代运行时事件验证
  expect_ok "ConfigMap falco-custom-rules 存在于 falco ns（模拟部署证据）" \
    kubectl -n falco get configmap falco-custom-rules
  expect_ok "自定义规则匹配 /etc/shadow" \
    bash -c "kubectl -n falco get configmap falco-custom-rules -o yaml | grep -q '/etc/shadow'"
  expect_ok "规则含 condition 与 output 定义" \
    bash -c "kubectl -n falco get configmap falco-custom-rules -o yaml | grep -q 'condition:' && kubectl -n falco get configmap falco-custom-rules -o yaml | grep -q 'output:'"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
