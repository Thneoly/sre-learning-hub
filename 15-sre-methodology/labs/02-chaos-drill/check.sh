#!/usr/bin/env bash
# Lab 02 检查脚本：混沌演练方案与无责复盘的结构完整性 + 集群终态恢复
# 用法：chmod +x check.sh && ./check.sh
# 运行位置：任何已配置集群 kubeconfig 的机器（如 master 节点），
#           且本脚本需与本 lab 的 drill-plan.md、postmortem.md 位于同一目录。
# 假设：按 solution.md 部署了 ns chaos-demo、deploy/chaos-demo（带 /set 注入接口），
#       演练已结束并恢复（fail_rate=0）。
# 本脚本只做只读检查（文件读取、kubectl get/jsonpath 查询、Pod 内只读 HTTP GET
#   /metrics），不修改集群。
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN="${SCRIPT_DIR}/drill-plan.md"
PM="${SCRIPT_DIR}/postmortem.md"
NS="chaos-demo"

PASS=0; FAIL=0; TOTAL=0

report() { # $1 为上一命令退出码（0=通过，与 hub 其他 check.sh 一致）, $2 为用例描述
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

# ---------- 1. 演练方案存在且非空 ----------
[ -s "$PLAN" ]
report $? "drill-plan.md 存在且非空"

# ---------- 2~5. 方案关键章节：稳态假设 / 爆炸半径 / 观测点 / 中止条件 ----------
for sec in "稳态假设" "爆炸半径" "观测点" "中止条件"; do
  grep -q "$sec" "$PLAN" 2>/dev/null
  report $? "演练方案包含「${sec}」章节"
done

# ---------- 6. 复盘文件存在且内容有分量（>= 30 行） ----------
pm_lines=0
[ -f "$PM" ] && pm_lines="$(wc -l < "$PM" | tr -d ' ')"
[ "${pm_lines:-0}" -ge 30 ]
report $? "postmortem.md 存在且不少于 30 行（当前 ${pm_lines} 行）"

# ---------- 7~9. 复盘关键章节：时间线+影响 / 根因 / 行动项 ----------
grep -q "时间线" "$PM" 2>/dev/null && grep -q "影响" "$PM" 2>/dev/null
report $? "复盘包含「时间线」与「影响」章节"

grep -q "根因" "$PM" 2>/dev/null
report $? "复盘包含「根因」章节"

actions="$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[[ xX]\]' "$PM" 2>/dev/null || printf 0)"
[ "${actions:-0}" -ge 2 ]
report $? "复盘「行动项」用勾选格式列出且不少于 2 条（当前 ${actions} 条）"

# ---------- 10. 集群终态：deployment Ready ----------
ready="$(kubectl -n "$NS" get deploy chaos-demo -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
[ "${ready:-0}" -ge 1 ]
report $? "deployment/chaos-demo Ready 副本 >= 1（当前 ${ready:-0}）——稳态已恢复"

# ---------- 11. 注入已清除：demo_fail_rate == 0 ----------
metrics="$(kubectl -n "$NS" exec deploy/chaos-demo -- python3 -c \
  "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/metrics').read().decode())" 2>/dev/null)"
cleaned=0
if [ -n "${metrics:-}" ]; then
  echo "$metrics" | grep -Eq '^demo_fail_rate 0(\.0+)?$' && cleaned=1
fi
[ "${cleaned:-0}" -eq 1 ]
report $? "故障注入已清除（demo_fail_rate 为 0）"

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
