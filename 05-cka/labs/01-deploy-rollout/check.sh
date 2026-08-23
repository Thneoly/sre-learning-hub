#!/usr/bin/env bash
# Lab 01 判分脚本：Deployment 滚动发布与回滚
# 假设：
#   - 在能访问集群的机器上运行（master 节点），kubectl 已配置好 kubeconfig
#   - 已按 task.md 完成任务：ns lab01-rollout、deploy web-app、
#     升级到 1.29 后回滚、最终 6 副本、镜像 nginx:1.27
# 只读检查，不修改集群。
set -u

NS="lab01-rollout"
PASS=0
FAIL=0

ok()  { echo "PASS: $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# check "描述" "期望值" "实际值"
check() {
  if [ "$2" = "$3" ]; then
    ok "$1"
  else
    bad "$1 (期望 [$2] 实际 [$3])"
  fi
}

jq_() { kubectl -n "$NS" "$@"; }

# 1. namespace 存在且 Active
phase=$(kubectl get ns "$NS" -o jsonpath='{.status.phase}' 2>/dev/null)
check "namespace ${NS} 存在且 Active" "Active" "$phase"

# 2. Deployment 存在
name=$(jq_ get deploy web-app -o jsonpath='{.metadata.name}' 2>/dev/null)
check "deployment web-app 存在" "web-app" "$name"

# 3. 容器镜像已回滚到 nginx:1.27
img=$(jq_ get deploy web-app -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
check "镜像为 nginx:1.27（已回滚）" "nginx:1.27" "$img"

# 4. 期望副本数为 6
rep=$(jq_ get deploy web-app -o jsonpath='{.spec.replicas}' 2>/dev/null)
check "spec.replicas 为 6" "6" "$rep"

# 5. 6 个副本全部 Ready
ready=$(jq_ get deploy web-app -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
ready=${ready:-0}
check "readyReplicas 为 6" "6" "$ready"

# 6. 完成过 升级+回滚，当前 revision 应 >= 3
rev=$(jq_ get deploy web-app \
  -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null)
rev=${rev:-0}
if [ "$rev" -ge 3 ] 2>/dev/null; then
  ok "revision >= 3（经历过升级与回滚，当前 $rev）"
else
  bad "revision >= 3（当前 $rev，似乎没有完成升级+回滚）"
fi

# 7. rollout 处于完成状态（Available 副本 = 期望副本）
avail=$(jq_ get deploy web-app -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
avail=${avail:-0}
check "availableReplicas 为 6（rollout 已收敛）" "6" "$avail"

TOTAL=$((PASS + FAIL))
echo
echo "SCORE: $PASS/$TOTAL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
