#!/usr/bin/env bash
# Lab 01 检查脚本：SLO recording rules 与燃烧率告警
# 用法：chmod +x check.sh && ./check.sh
# 运行位置：任何已配置集群 kubeconfig 的机器（如 master 节点），
#           且本脚本需与本 lab 的 slo-rules.yaml 位于同一目录。
# 假设：
#   - 监控栈为 scripts/setup/install-prom-stack.sh 安装的 kube-prometheus-stack
#     （namespace monitoring，release 名 prom，Prometheus UI NodePort 30900）；
#   - 按 solution.md 部署了 ns slo-demo、deploy/slo-demo、svc/slo-demo、
#     ServiceMonitor/slo-demo、prometheusrule/slo-demo-slo。
# 本脚本只做只读检查（kubectl get/jsonpath 查询、Prometheus 只读 API、
#   本地文件读取），不修改集群。临时文件只写 /tmp。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULES_FILE="${SCRIPT_DIR}/slo-rules.yaml"
PROM_NS="monitoring"

PASS=0; FAIL=0; TOTAL=0

report() { # $1 为上一命令退出码（0=通过）, $2 为用例描述
  TOTAL=$((TOTAL+1))
  if [ "$1" -eq 0 ]; then
    PASS=$((PASS+1)); echo "PASS: $2"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $2"
  fi
}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "错误：未找到 kubectl，请在有集群 kubeconfig 的机器上运行"
  exit 1
fi

# ---------- 1. 规则文件存在且语法校验通过（promtool / python3-yaml / 结构检查三级回退） ----------
syntax_ok=0
if [ -s "$RULES_FILE" ]; then
  # 提取 spec.groups 段（去掉 2 空格缩进）成为 promtool 可校验的纯规则文件
  sed -n '/^  groups:/,$p' "$RULES_FILE" | sed 's/^  //' > /tmp/slo-lab-rules.extract.yml 2>/dev/null
  if command -v promtool >/dev/null 2>&1 && [ -s /tmp/slo-lab-rules.extract.yml ]; then
    promtool check rules /tmp/slo-lab-rules.extract.yml >/dev/null 2>&1 && syntax_ok=1
  elif python3 -c "import yaml" >/dev/null 2>&1; then
    if python3 - "$RULES_FILE" >/dev/null 2>&1 <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
assert doc["apiVersion"] == "monitoring.coreos.com/v1"
assert doc["kind"] == "PrometheusRule"
groups = doc["spec"]["groups"]
assert isinstance(groups, list) and groups
for g in groups:
    assert g.get("name")
    rules = g.get("rules")
    assert isinstance(rules, list) and rules
    for r in rules:
        assert r.get("record") or r.get("alert")
        assert r.get("expr")
        if "alert" in r:
            assert r.get("labels") or r.get("annotations")
PY
    then syntax_ok=1; fi
  else
    grep -q '^kind: PrometheusRule' "$RULES_FILE" \
      && grep -q '^  groups:' "$RULES_FILE" \
      && grep -q 'record:' "$RULES_FILE" \
      && grep -q 'alert:' "$RULES_FILE" \
      && syntax_ok=1
  fi
fi
[ "$syntax_ok" -eq 1 ]
report $? "slo-rules.yaml 存在且规则语法校验通过（promtool 优先，无则等效校验）"

# ---------- 2. PrometheusRule 对象存在 ----------
cr_json="$(kubectl -n "$PROM_NS" get prometheusrule slo-demo-slo -o json 2>/dev/null)"
[ -n "$cr_json" ]
report $? "monitoring 命名空间存在 prometheusrule/slo-demo-slo"

# ---------- 3. CR 中包含可用性 recording rule ----------
echo "$cr_json" | grep -q 'slo:slo_demo_availability:ratio_rate5m'
report $? "recording rule 含 slo:slo_demo_availability:ratio_rate5m"

# ---------- 4. CR 中包含燃烧率告警 ----------
echo "$cr_json" | grep -q 'SloDemoAvailabilityFastBurn' \
  && echo "$cr_json" | grep -q 'SloDemoAvailabilitySlowBurn'
report $? "告警规则含 SloDemoAvailabilityFastBurn 与 SloDemoAvailabilitySlowBurn"

# ---------- 5~8. 示例服务部署形态 ----------
[ -n "$(kubectl get ns slo-demo -o name 2>/dev/null)" ]
report $? "namespace slo-demo 存在"

ready="$(kubectl -n slo-demo get deploy slo-demo -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ "${ready:-0}" -ge 1 ]
report $? "deployment/slo-demo Ready 副本 >= 1（当前 ${ready:-0}）"

kubectl -n slo-demo get svc slo-demo -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | grep -qx 8000
report $? "svc/slo-demo 暴露 8000 端口"

sm="$(kubectl -n slo-demo get servicemonitor slo-demo -o jsonpath='{.metadata.labels.release}' 2>/dev/null)"
[ "$sm" = "prom" ]
report $? "servicemonitor/slo-demo 存在且带 release=prom label"

# ---------- 9~10. 通过 Prometheus 只读 API 验证 ----------
api_get() { # $1 = API path（含 query string）；输出 JSON，失败返回空
  local out pod ip
  pod="$(kubectl -n "$PROM_NS" get pod -l app.kubernetes.io/name=prometheus \
         -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"
  if [ -n "$pod" ]; then
    out="$(kubectl -n "$PROM_NS" exec "$pod" -c prometheus -- \
           curl -s "http://127.0.0.1:9090$1" 2>/dev/null)"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
    out="$(kubectl -n "$PROM_NS" exec "$pod" -c prometheus -- \
           wget -q -O- "http://127.0.0.1:9090$1" 2>/dev/null)"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  fi
  ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)"
  [ -n "$ip" ] || ip="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[0].address}' 2>/dev/null)"
  if [ -n "$ip" ]; then
    out="$(curl -s "http://${ip}:30900$1" 2>/dev/null)"
    if [ -n "$out" ]; then printf '%s' "$out"; return 0; fi
  fi
  return 1
}

rules_api="$(api_get "/api/v1/rules")"
loaded=0
if [ -n "${rules_api:-}" ]; then
  echo "$rules_api" | grep -q 'slo-demo\.recording' \
    && echo "$rules_api" | grep -q 'slo-demo\.alerts' \
    && echo "$rules_api" | grep -q '"health":"ok"' \
    && loaded=1
fi
[ "$loaded" -eq 1 ]
report $? "Prometheus 已加载 slo-demo.recording / slo-demo.alerts 规则组且 health=ok"

query_api="$(api_get "/api/v1/query?query=sum(demo_http_requests_total)")"
scraped=0
if [ -n "${query_api:-}" ]; then
  echo "$query_api" | grep -q '"value"' && scraped=1
fi
[ "$scraped" -eq 1 ]
report $? "demo_http_requests_total 指标已被 Prometheus 采集（查询有结果向量）"

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
