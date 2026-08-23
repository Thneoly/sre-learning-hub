#!/usr/bin/env bash
# Lab 13 · etcd 快照与模拟恢复 检查脚本
# 用法: chmod 755 check.sh && sudo ./check.sh
# 前置假设:
#   - 在 master 节点上运行(etcd 数据/证书所在节点, kubeadm 集群)
#   - 已按 task.md 完成任务: 快照 /var/lib/etcd-snapshot/lab13.db, 恢复目录 /tmp/lab13-restore
#   - 脚本只做只读检查(读取文件/目录属性), 不修改集群
set -u

SNAP=/var/lib/etcd-snapshot/lab13.db
RESTORE_DIR=/tmp/lab13-restore
PASS=0; FAIL=0; TOTAL=0
pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# 0. 这是 master 吗(有 etcd 证书目录)
if [ -d /etc/kubernetes/pki/etcd ]; then
  pass "当前节点是 master(存在 /etc/kubernetes/pki/etcd)"
else
  fail "未找到 /etc/kubernetes/pki/etcd, 请在 master 上运行本脚本"
fi

# 1. 快照文件存在
if [ -f "$SNAP" ]; then
  pass "快照文件 $SNAP 存在"
else
  fail "快照文件 $SNAP 不存在"
fi

# 2. 快照大小大于 0(至少 1MB 才像一个真实集群快照)
if [ -f "$SNAP" ]; then
  SIZE=$(stat -c%s "$SNAP" 2>/dev/null || echo 0)
  if [ "$SIZE" -gt 1048576 ]; then
    pass "快照大小 ${SIZE} 字节(>1MB, 非空文件)"
  else
    fail "快照大小仅 ${SIZE} 字节, 不像有效的集群快照"
  fi
else
  fail "快照大小检查跳过(文件不存在)"
fi

# 3. snapshot status 可解析(需要 etcdctl; 没装则该项 FAIL 并提示)
if command -v etcdctl >/dev/null 2>&1; then
  if ETCDCTL_API=3 etcdctl snapshot status "$SNAP" --write-out=json >/dev/null 2>&1; then
    pass "etcdctl snapshot status 可正常解析快照"
  else
    fail "etcdctl snapshot status 解析失败(快照可能损坏)"
  fi
else
  fail "未安装 etcdctl, 无法校验快照(apt-get install -y etcd-client)"
fi

# 4. 模拟恢复产物存在
if [ -f "$RESTORE_DIR/member/snap/db" ]; then
  pass "恢复产物 $RESTORE_DIR/member/snap/db 存在"
else
  fail "恢复产物 $RESTORE_DIR/member/snap/db 不存在(未执行 snapshot restore?)"
fi

# 5. 恢复产物非空
if [ -f "$RESTORE_DIR/member/snap/db" ]; then
  RSIZE=$(stat -c%s "$RESTORE_DIR/member/snap/db" 2>/dev/null || echo 0)
  if [ "$RSIZE" -gt 0 ]; then
    pass "恢复的 member/snap/db 大小 ${RSIZE} 字节(>0)"
  else
    fail "恢复的 member/snap/db 为空文件"
  fi
else
  fail "恢复产物大小检查跳过(文件不存在)"
fi

# 6. 现有集群未受影响(kubectl 仍可用; sudo 环境下读不到用户 kubeconfig, 显式指定)
KC="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
if command -v kubectl >/dev/null 2>&1 && kubectl --kubeconfig "$KC" get nodes >/dev/null 2>&1; then
  pass "集群 API 正常(演练未破坏现有 etcd)"
else
  fail "kubectl --kubeconfig $KC get nodes 失败(当前环境 kubectl 不可用或集群异常)"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then exit 0; fi
exit 1
