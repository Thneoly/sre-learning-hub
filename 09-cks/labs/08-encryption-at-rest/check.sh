#!/usr/bin/env bash
# Lab 08 判分脚本 —— Secret 落盘加密全流程（只读，不修改集群）
# 运行位置：master 节点（kubeadm etcd 在本机；etcdctl 需已安装：apt-get install -y etcd-client）
# 前提：已按 task.md 完成实验（Secret encryption-configuration、apiserver flags、
#       ns cks-lab08、Secret credit-card）
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

MANIFEST=/etc/kubernetes/manifests/kube-apiserver.yaml
ENC_KEY='encryption-config.yaml'

# 1. kube-system 里的配置 Secret 存在且内容含 aescbc
expect_ok "Secret encryption-configuration 存在于 kube-system" \
  kubectl -n kube-system get secret encryption-configuration
expect_ok "Secret 内容解码后含 aescbc provider" \
  bash -c "kubectl -n kube-system get secret encryption-configuration -o go-template='{{index .data \"$ENC_KEY\"}}' | base64 -d | grep -q aescbc"
expect_ok "Secret 内容含 identity 兜底 provider" \
  bash -c "kubectl -n kube-system get secret encryption-configuration -o go-template='{{index .data \"$ENC_KEY\"}}' | base64 -d | grep -q identity"

# 2. apiserver manifest 已配置 provider 文件
expect_ok "apiserver manifest 含 --encryption-provider-config" \
  bash -c "grep -q 'encryption-provider-config' $MANIFEST"

# 3. apiserver 运行正常
expect_ok "kube-apiserver 静态 Pod 为 Running" \
  bash -c "kubectl -n kube-system get pods -l component=kube-apiserver -o jsonpath='{.items[0].status.phase}' | grep -qx Running"

# 4. 业务侧可用性：apiserver 能解密返回
expect_ok "namespace cks-lab08 与 Secret credit-card 存在" \
  bash -c "kubectl -n cks-lab08 get secret credit-card -o jsonpath='{.data.number}' | grep -q ."
expect_ok "apiserver 解密正常（读出明文卡号）" \
  bash -c "kubectl -n cks-lab08 get secret credit-card -o jsonpath='{.data.number}' | base64 -d | grep -q '4111111111111111'"

# 5. etcd 落盘为密文（只读查询，kubeadm 默认证书路径）
expect_ok "etcd 中该 key 为 aescbc 密文（k8s:enc:aescbc:v1:）" \
  bash -c "ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key get /registry/secrets/cks-lab08/credit-card | grep -aq 'k8s:enc:aescbc:v1:'"
# 注意：未加密时 Secret 对象在 etcd 里也是 base64 编码的（data.number 为 base64 值），
# 因此探测串用卡号的 base64 前缀 NDExMTExMTExMTExMTEx（base64("4111111111111111")）
expect_ok "etcd 原始值中找不到卡号数据（base64 形式）" \
  bash -c "! ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key get /registry/secrets/cks-lab08/credit-card | grep -aq 'NDExMTExMTExMTExMTEx'"

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
