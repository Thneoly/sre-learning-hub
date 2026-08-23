#!/usr/bin/env bash
# Lab 01 检查脚本：Loki+Promtail+Grafana 日志管道 + LogQL 查询结果
# 用法：chmod +x check.sh && ./check.sh
# 运行位置：任何已配置集群 kubeconfig 的机器（如 master 节点）。
# 假设：按 solution.md 部署——
#   - namespace logging-lab：deploy/loki、deploy/grafana、ds/promtail、svc/loki、
#     cm/loki-config、cm/promtail-config、cm/grafana-datasources
#   - namespace default：deploy/logger
#   - 4 个查询结果已保存在脚本同目录的 results/q1.txt ~ q4.txt
# 本脚本只做只读检查（kubectl get/jsonpath 查询与本地文件读取），不修改集群。
set -u

NS=logging-lab
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RESULTS="$SCRIPT_DIR/results"

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

# ---------- 一、基础设施状态 ----------

# 1. namespace 存在
[ -n "$(kubectl get ns "$NS" -o name 2>/dev/null)" ]
report $? "namespace $NS 存在"

# 2. Loki Deployment Ready
ready=$(kubectl -n "$NS" get deploy loki -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${ready:-0}" -ge 1 ]
report $? "deployment/loki Ready 副本 >= 1（当前 ${ready:-0}）"

# 3. Promtail DaemonSet 全部 Ready
desired=$(kubectl -n "$NS" get ds promtail -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null)
pready=$(kubectl -n "$NS" get ds promtail -o jsonpath='{.status.numberReady}' 2>/dev/null)
[ "${desired:-0}" -ge 1 ] && [ "${pready:-0}" -eq "${desired:-0}" ]
report $? "daemonset/promtail 全部 Ready（${pready:-0}/${desired:-0}）"

# 4. Grafana Deployment Ready
gready=$(kubectl -n "$NS" get deploy grafana -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${gready:-0}" -ge 1 ]
report $? "deployment/grafana Ready 副本 >= 1（当前 ${gready:-0}）"

# 5. Loki Service 暴露 3100
kubectl -n "$NS" get svc loki -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | grep -qx 3100
report $? "svc/loki 暴露 3100 端口"

# ---------- 二、配置正确性 ----------

# 6. Loki 配置：TSDB v13 schema + filesystem 存储
loki_cfg=$(kubectl -n "$NS" get cm loki-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null)
echo "$loki_cfg" | grep -q 'schema_config:' && echo "$loki_cfg" | grep -q 'tsdb' && echo "$loki_cfg" | grep -q 'filesystem'
report $? "cm/loki-config 含 schema_config/tsdb/filesystem 存储（tsdb v13）"

# 7. Promtail 配置：K8s 发现 + Loki push 地址 + CRI 解析
prom_cfg=$(kubectl -n "$NS" get cm promtail-config -o jsonpath='{.data.config\.yaml}' 2>/dev/null)
echo "$prom_cfg" | grep -q 'kubernetes_sd_configs:' && echo "$prom_cfg" | grep -q 'loki/api/v1/push' && echo "$prom_cfg" | grep -q 'cri:'
report $? "cm/promtail-config 含 K8s 发现、Loki push 地址与 cri 解析"

# 8. Grafana 数据源已预置 Loki
graf_ds=$(kubectl -n "$NS" get cm grafana-datasources -o jsonpath='{.data.loki\.yaml}' 2>/dev/null)
echo "$graf_ds" | grep -q 'type: loki'
report $? "cm/grafana-datasources 预置了 Loki 数据源"

# ---------- 三、日志源 ----------

# 9. logger 应用 Ready
lready=$(kubectl -n default get deploy logger -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "${lready:-0}" -ge 1 ]
report $? "default/deployment logger Ready 副本 >= 1（当前 ${lready:-0}）"

# ---------- 四、LogQL 查询结果文件 ----------

# 10. q1：流选择器（结果含 logger 的 tick 行）
if [ -s "$RESULTS/q1.txt" ] && grep -q 'tick' "$RESULTS/q1.txt"; then
  report 1 "q1 流选择器查询成功（q1.txt 含 tick 日志）"
else
  report 0 "q1 流选择器查询成功（q1.txt 含 tick 日志）"
fi

# 11. q2：解析过滤 + line_format（格式化后的 tick 行）
if [ -s "$RESULTS/q2.txt" ] && grep -q 'tick' "$RESULTS/q2.txt" && grep -q 'success' "$RESULTS/q2.txt"; then
  report 1 "q2 解析过滤查询成功（q2.txt 含 line_format 后的 tick 行）"
else
  report 0 "q2 解析过滤查询成功（q2.txt 含 line_format 后的 tick 行）"
fi

# 12. q3：按 level 聚合计数（info 与 error 都有计数）
if [ -s "$RESULTS/q3.txt" ] && grep -q '"level"' "$RESULTS/q3.txt" && grep -q '"info"' "$RESULTS/q3.txt" && grep -q '"error"' "$RESULTS/q3.txt"; then
  report 1 "q3 度量聚合查询成功（q3.txt 含 info/error 计数）"
else
  report 0 "q3 度量聚合查询成功（q3.txt 含 info/error 计数）"
fi

# 13. q4：按节点速率（含 node_name 指标序列）
if [ -s "$RESULTS/q4.txt" ] && grep -q 'node_name' "$RESULTS/q4.txt"; then
  report 1 "q4 按节点速率查询成功（q4.txt 含 node_name 序列）"
else
  report 0 "q4 按节点速率查询成功（q4.txt 含 node_name 序列）"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
