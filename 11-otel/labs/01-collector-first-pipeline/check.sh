#!/usr/bin/env bash
# Lab 01 检查脚本：最小 Collector 管道（OTLP 进、文件出）
# 用法：chmod +x check.sh && ./check.sh
# 运行位置：任何已配置集群 kubeconfig 的机器（如 master 节点）。
# 假设：按 solution.md 在 namespace otel-lab 部署了 deployment/otel-collector、
#       svc/otel-collector、cm/otel-collector-config、job/telemetrygen。
# 本脚本只做只读检查（kubectl get/exec/logs 查询），不修改集群。
set -u

NS=otel-lab
PASS=0; FAIL=0; TOTAL=0

report() { # $1=1 表示通过, $2 为用例描述
  TOTAL=$((TOTAL+1))
  if [ "$1" -eq 1 ]; then
    PASS=$((PASS+1)); echo "PASS: $2"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $2"
  fi
}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "错误：未找到 kubectl，请在有集群 kubeconfig 的机器上运行"
  exit 1
fi

# 1. namespace 存在
[ -n "$(kubectl get ns "$NS" -o name 2>/dev/null)" ]
report $? "namespace $NS 存在"

# 2. Collector Deployment Ready
ready=$(kubectl -n "$NS" get deploy otel-collector -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${ready:-0}" -ge 1 ]
report $? "deployment/otel-collector Ready 副本 >= 1（当前 ${ready:-0}）"

# 3. Service 暴露 OTLP gRPC 端口
kubectl -n "$NS" get svc otel-collector -o jsonpath='{range .spec.ports[*]}{.port}{"\n"}{end}' 2>/dev/null | grep -qx 4317
report $? "svc/otel-collector 暴露 4317 端口（OTLP gRPC）"

# 4. 配置中包含 file exporter 与两条 pipeline
cfg=$(kubectl -n "$NS" get cm otel-collector-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null)
echo "$cfg" | grep -Eq '^[[:space:]]*file:[[:space:]]*$'
has_file=$?
echo "$cfg" | grep -q 'traces:'
has_trace=$?
echo "$cfg" | grep -q 'metrics:'
has_metric=$?
[ "$has_file" -eq 0 ] && [ "$has_trace" -eq 0 ] && [ "$has_metric" -eq 0 ]
report $? "collector 配置含 file exporter 及 traces/metrics 两条 pipeline"

# 5. telemetrygen Job 成功完成
succ=$(kubectl -n "$NS" get job telemetrygen -o jsonpath='{.status.succeeded}' 2>/dev/null)
[ "${succ:-0}" -ge 1 ]
report $? "job/telemetrygen 成功完成（succeeded=${succ:-0}）"

# 6. 数据确实到达（文件或日志中含 telemetrygen）
data_ok=0
if kubectl -n "$NS" exec deploy/otel-collector -- cat /var/lib/otelcol/telemetry.json 2>/dev/null | grep -q telemetrygen; then
  data_ok=1
fi
if [ "$data_ok" -eq 0 ]; then
  kubectl -n "$NS" logs deploy/otel-collector --tail=5000 2>/dev/null | grep -q telemetrygen && data_ok=1
fi
report "$data_ok" "collector 已收到 telemetrygen 数据（产出文件或日志含 service.name=telemetrygen）"

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
