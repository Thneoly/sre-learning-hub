#!/usr/bin/env bash
# Lab 19 · 资源压力诊断 检查脚本
# 用法: chmod 755 check.sh && ./check.sh
# 前置假设:
#   - 在能以 admin kubeconfig 访问集群的节点上运行(练习环境即 master)
#   - 已按 task.md 完成: ns cka-res / Deployment big-batch requests 已改为
#     cpu=100m,memory=128Mi 且 Pod Running / /tmp/lab19-answers.txt 已生成
set -u

NS=cka-res
ANS=/tmp/lab19-answers.txt
PASS=0; FAIL=0; TOTAL=0
pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# 把 CPU 量纲统一换算成 millicores: "4"->4000, "4000m"->4000, "0.5"->500
to_milli() {
  echo "$1" | awk '{
    v=$0
    if (v ~ /m$/) { sub(/m$/,"",v); printf "%d", v }
    else { printf "%d", v*1000 }
  }'
}

# 1. namespace 与 Deployment 存在
if kubectl get ns "$NS" >/dev/null 2>&1; then
  pass "namespace $NS 存在"
else
  fail "namespace $NS 不存在"
fi
if kubectl -n "$NS" get deploy big-batch >/dev/null 2>&1; then
  pass "Deployment big-batch 存在"
else
  fail "Deployment big-batch 不存在"
fi

# 2. requests 已改小(CPU <= 500m 且内存 <= 256Mi)
REQ_CPU=$(kubectl -n "$NS" get deploy big-batch -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' 2>/dev/null || true)
REQ_MEM=$(kubectl -n "$NS" get deploy big-batch -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}' 2>/dev/null || true)
REQ_CPU_M=$(to_milli "${REQ_CPU:-0}")
REQ_MEM_MI=$(echo "${REQ_MEM:-0}" | awk '{
  v=$0
  if (v ~ /Mi$/) { sub(/Mi$/,"",v); printf "%d", v }
  else if (v ~ /Gi$/) { sub(/Gi$/,"",v); printf "%d", v*1024 }
  else if (v ~ /Ki$/) { sub(/Ki$/,"",v); printf "%d", v/1024 }
  else { printf "%d", v/1048576 }
}')
if [ "${REQ_CPU_M:-0}" -ge 1 ] && [ "${REQ_CPU_M:-0}" -le 500 ] \
   && [ "${REQ_MEM_MI:-0}" -ge 1 ] && [ "${REQ_MEM_MI:-0}" -le 256 ]; then
  pass "requests 已改小(cpu=${REQ_CPU}, memory=${REQ_MEM})"
else
  fail "requests 不符合要求(cpu='${REQ_CPU}' 应为 1m~500m; memory='${REQ_MEM}' 应为 1Mi~256Mi)"
fi

# 3. Pod Running
PODPHASE=$(kubectl -n "$NS" get pod -l app=big-batch -o jsonpath='{.items[0].status.phase}' 2>/dev/null || true)
if [ "$PODPHASE" = "Running" ]; then
  pass "big-batch 的 Pod 为 Running"
else
  fail "big-batch 的 Pod 状态为 '$PODPHASE'(应为 Running)"
fi

# 4. answers 文件存在
if [ -f "$ANS" ]; then
  pass "answers 文件 $ANS 存在"
else
  fail "answers 文件 $ANS 不存在"
fi

# 5. ALLOCATABLE_CPU 与集群实际一致(millicores 数值相等)
if [ -f "$ANS" ]; then
  ANS_CPU=$(grep -E '^ALLOCATABLE_CPU=' "$ANS" | head -1 | cut -d= -f2 | tr -d '[:space:]')
  REAL_CPU=$(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}' 2>/dev/null || true)
  ANS_M=$(to_milli "${ANS_CPU:-x}")
  REAL_M=$(to_milli "${REAL_CPU:-y}")
  if [ "$ANS_M" = "$REAL_M" ] && [ -n "$ANS_M" ]; then
    pass "ALLOCATABLE_CPU=$ANS_CPU 与实际($REAL_CPU)一致"
  else
    fail "ALLOCATABLE_CPU='$ANS_CPU' 与实际 '$REAL_CPU' 不一致(数值换算后 $ANS_M vs $REAL_M millicores)"
  fi
else
  fail "ALLOCATABLE_CPU 检查跳过(文件不存在)"
fi

# 6. answers 含原因归纳行
if [ -f "$ANS" ]; then
  REASON=$(grep -E '^PENDING_REASON=' "$ANS" | head -1 | cut -d= -f2)
  if [ -n "$REASON" ]; then
    pass "PENDING_REASON 已填写(${REASON})"
  else
    fail "answers 缺少 PENDING_REASON= 行"
  fi
else
  fail "PENDING_REASON 检查跳过(文件不存在)"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then exit 0; fi
exit 1
