#!/usr/bin/env bash
# Lab 02 检查脚本：OTel Operator 自动插桩
# 用法：chmod +x check.sh && ./check.sh
# 运行位置：任何已配置集群 kubeconfig 的机器（如 master 节点）。
# 假设：按 solution.md 安装了 cert-manager、opentelemetry-operator(v0.109.0)，
#       并在 namespace otel-lab 部署了 instrumentation/python-instr、deploy/jaeger、
#       deploy/otel-collector、deploy/python-demo（带 inject-python 注解，已运行）。
# 本脚本只做只读检查（kubectl get/jsonpath 查询），不修改集群。
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

ready() { # $1=namespace $2=deployment，Ready 副本 >= 1 返回 0
  local r
  r=$(kubectl -n "$1" get deploy "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "${r:-0}" -ge 1 ]
}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "错误：未找到 kubectl，请在有集群 kubeconfig 的机器上运行"
  exit 1
fi

# 1. cert-manager 已就绪
ready cert-manager cert-manager
report $? "cert-manager: deployment/cert-manager Ready"

# 2. OTel Operator 已就绪
ready opentelemetry-operator-system opentelemetry-operator-controller-manager
report $? "opentelemetry-operator: controller-manager Ready"

# 3. Instrumentation CR 存在
[ -n "$(kubectl -n "$NS" get instrumentation python-instr -o name 2>/dev/null)" ]
report $? "instrumentation/python-instr 存在"

# 4. Jaeger 后端就绪
ready "$NS" jaeger
report $? "deployment/jaeger Ready（OTLP 接收已开启）"

# 5. Collector 就绪
ready "$NS" otel-collector
report $? "deployment/otel-collector Ready"

# 6. 自动插桩注入生效（init 容器 + OTEL 环境变量）
# 注意：mutating webhook 只在 Pod CREATE 时注入，Deployment 对象不会带 init 容器，
#       因此这里检查的是运行中的 Pod。
demo_pod=$(kubectl -n "$NS" get pod -l app=python-demo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
inj_ok=0
if [ -n "$demo_pod" ]; then
  init_names=$(kubectl -n "$NS" get pod "$demo_pod" -o jsonpath='{.spec.initContainers[*].name}' 2>/dev/null)
  env_names=$(kubectl -n "$NS" get pod "$demo_pod" -o jsonpath='{.spec.containers[0].env[*].name}' 2>/dev/null)
  if echo "$init_names" | grep -q 'opentelemetry-auto-instrumentation-python' \
     && echo "$env_names" | grep -q 'OTEL_EXPORTER_OTLP_ENDPOINT' \
     && echo "$env_names" | grep -q 'PYTHONPATH'; then
    inj_ok=1
  fi
fi
report "$inj_ok" "python-demo Pod 已注入 init 容器与 OTEL_* 环境变量（pod=${demo_pod:-未找到}）"

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
