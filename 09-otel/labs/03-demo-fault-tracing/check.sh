#!/usr/bin/env bash
# Lab 03 检查脚本：Astronomy Shop 故障注入与根因定位（环境 + 故障状态检查）
# 用法：chmod +x check.sh && ./check.sh
# 运行位置：任何已配置集群 kubeconfig 的机器（如 master 节点）。
# 时机：在"故障注入之后、恢复之前"运行（第 5 项检查 VALKEY_ADDR/REDIS_ADDR 指向 missing 主机）。
#       做完恢复步骤后再跑，第 5 项会 FAIL，属预期。
# 假设：按 solution.md 用 helm 以 release 名 astro 安装 demo 到 namespace astro-demo。
# 本脚本只做只读检查（kubectl get/jsonpath 查询），不修改集群。
set -u

NS=astro-demo
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

# 2. 业务 Deployment 数量足够（精简子集至少 8 个）且全部 Ready
deploys=$(kubectl -n "$NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{","}{.status.readyReplicas}{","}{.spec.replicas}{"\n"}{end}' 2>/dev/null)
dep_cnt=$(echo "$deploys" | grep -c . )
not_ready=$(echo "$deploys" | awk -F, '$2 != $3 {print $1}')
[ "${dep_cnt:-0}" -ge 8 ] && [ -z "$not_ready" ]
report $? "demo 子集 >= 8 个 Deployment 且全部 Ready（当前 ${dep_cnt:-0} 个，未就绪: ${not_ready:-无}）"

# 3. frontend 与 loadgenerator 就绪（保证有流量产生 trace）
front=$(echo "$deploys" | awk -F, '$1 ~ /frontend/ && $2 == $3 {print $1}' | head -1)
loadgen=$(echo "$deploys" | awk -F, '$1 ~ /load/ && $2 == $3 {print $1}' | head -1)
[ -n "$front" ] && [ -n "$loadgen" ]
report $? "frontend 与 loadgenerator Deployment 就绪（$front / $loadgen）"

# 4. Jaeger 后端存在（有 jaeger Service 才能看 trace）
jaeger_cnt=$(kubectl -n "$NS" get svc -o name 2>/dev/null | grep -c jaeger)
[ "${jaeger_cnt:-0}" -ge 1 ]
report $? "Jaeger Service 存在（可用于 trace 查看）"

# 5. 故障已注入：cart Deployment 的 VALKEY_ADDR/REDIS_ADDR 指向 missing 主机
cart_deploy=$(kubectl -n "$NS" get deploy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -m1 'cart')
fault_ok=0
if [ -n "${cart_deploy:-}" ]; then
  addr=$(kubectl -n "$NS" get deploy "$cart_deploy" -o jsonpath='{range .spec.template.spec.containers[*]}{range .env[*]}{.name}={.value}{"\n"}{end}{end}' 2>/dev/null | grep -E '^(VALKEY|REDIS)_ADDR=' | head -1)
  echo "$addr" | grep -q 'missing' && fault_ok=1
fi
report "$fault_ok" "故障已注入：${cart_deploy:-<未找到cart>} 的缓存地址指向 missing 主机（当前: ${addr:-未设置}）"

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
