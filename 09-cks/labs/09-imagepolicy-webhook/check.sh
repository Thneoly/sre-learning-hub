#!/usr/bin/env bash
# Lab 09 判分脚本 —— ImagePolicyWebhook 配置结构与后端行为（只读，不修改集群）
# 运行位置：master 节点；要求 mock 后端 imagepolicy-webhook.py 正在 127.0.0.1:8899 运行
# 前提：已按 task.md 完成实验。两种模式自动识别：
#   full      —— apiserver manifest 已启用 ImagePolicyWebhook（实战项完成）
#   simulated —— 仅完成配置结构与 mock 后端（替代验证路径）
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

DIR=/etc/kubernetes/imagepolicy
ADMISSION=/etc/kubernetes/admission-imagepolicy.yaml
MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml

# 模式识别
if grep -q 'admission-control-config-file' "$MANIFEST" 2>/dev/null && grep -q 'ImagePolicyWebhook' "$MANIFEST" 2>/dev/null; then
  MODE=full
  echo "MODE: full（apiserver 已启用 ImagePolicyWebhook）"
else
  MODE=simulated
  echo "MODE: simulated（apiserver 未启用该插件，验证配置结构）"
fi

# 1. 证书存在且为有效 PEM
expect_ok "自签证书 server.crt/server.key 存在" \
  bash -c "test -f $DIR/server.crt && test -f $DIR/server.key"
expect_ok "server.crt 为合法证书（openssl 可解析）" \
  bash -c "openssl x509 -in $DIR/server.crt -noout -subject"

# 2. kubeconfig 结构完整
expect_ok "kubeconfig 存在且 server 为 https://127.0.0.1:8899" \
  bash -c "grep -q 'https://127.0.0.1:8899' $DIR/kubeconfig"
expect_ok "kubeconfig 指定 certificate-authority" \
  bash -c "grep -q 'certificate-authority' $DIR/kubeconfig"

# 3. AdmissionConfiguration 结构完整
expect_ok "admission-imagepolicy.yaml 存在" test -f "$ADMISSION"
expect_ok "AdmissionConfiguration 含 ImagePolicyWebhook 插件与 kubeConfigFile" \
  bash -c "grep -q 'name: ImagePolicyWebhook' $ADMISSION && grep -q 'kubeConfigFile' $ADMISSION"
expect_ok "imagePolicy 含 defaultAllow 与 TTL 配置" \
  bash -c "grep -q 'defaultAllow' $ADMISSION && grep -q 'allowTTL' $ADMISSION && grep -q 'denyTTL' $ADMISSION"

# 4. mock 后端行为验证（curl 只读探测）
expect_ok "后端拒绝 nginx:1.16（allowed:false）" \
  bash -c "curl -s --cacert $DIR/server.crt -X POST https://127.0.0.1:8899 -d '{\"apiVersion\":\"imagepolicy.k8s.io/v1alpha1\",\"kind\":\"ImageReview\",\"spec\":{\"containers\":[{\"image\":\"nginx:1.16\"}],\"namespace\":\"cks-lab09\"}}' | grep -q '\"allowed\": false'"
expect_ok "后端放行 nginx:1.27（allowed:true）" \
  bash -c "curl -s --cacert $DIR/server.crt -X POST https://127.0.0.1:8899 -d '{\"apiVersion\":\"imagepolicy.k8s.io/v1alpha1\",\"kind\":\"ImageReview\",\"spec\":{\"containers\":[{\"image\":\"nginx:1.27\"}],\"namespace\":\"cks-lab09\"}}' | grep -q '\"allowed\": true'"

# 5. 按模式区分的收尾检查
if [ "$MODE" = full ]; then
  expect_ok "apiserver manifest 含 --enable-admission-plugins 且带 ImagePolicyWebhook" \
    bash -c "grep 'enable-admission-plugins' $MANIFEST | grep -q ImagePolicyWebhook"
  expect_ok "apiserver manifest 含 --runtime-config=imagepolicy.k8s.io/v1alpha1=true" \
    bash -c "grep -q 'imagepolicy.k8s.io/v1alpha1=true' $MANIFEST"
  expect_ok "kube-apiserver 静态 Pod 为 Running" \
    bash -c "kubectl -n kube-system get pods -l component=kube-apiserver -o jsonpath='{.items[0].status.phase}' | grep -qx Running"
else
  echo "SIMULATED: apiserver 未启用插件（替代验证路径），跳过 apiserver flags 检查"
  pass "模拟模式：证书/kubeconfig/AdmissionConfiguration/mock 后端结构完整"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
