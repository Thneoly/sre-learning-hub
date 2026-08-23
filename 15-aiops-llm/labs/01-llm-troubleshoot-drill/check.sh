#!/usr/bin/env bash
# Lab 01 检查脚本：LLM 辅助排障演练（report.md 结构完整性 + 集群恢复检查）
# 用法：chmod +x check.sh && ./check.sh
# 运行位置：任何已配置集群 kubeconfig 的机器（如 master 节点），且本 lab 目录
#           （含 report.md 与 kb/）在同一目录；跨机器拷贝时整个目录一起拷。
# 环境假设：
#   - 本目录下有学员完成的 report.md（七个必需章节）
#   - 本目录 kb/ 下有至少一条知识条目
#   - kubectl 可用；三个候选故障命名空间 fault-imagepull/fault-dns/fault-ep
#     不存在，或其中 Pod 全部 Running/Completed（即故障已恢复）
# 本脚本只做只读检查（读文件 + kubectl get），不修改集群。
# 可用环境变量覆盖路径：REPORT=... KB_DIR=... ./check.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORT="${REPORT:-${SCRIPT_DIR}/report.md}"
KB_DIR="${KB_DIR:-${SCRIPT_DIR}/kb}"

PASS=0; FAIL=0; TOTAL=0

report() { # $1 为上一命令退出码（0=通过）, $2 为用例描述
  TOTAL=$((TOTAL+1))
  if [ "$1" -eq 0 ]; then
    PASS=$((PASS+1)); echo "PASS: $2"
  else
    FAIL=$((FAIL+1)); echo "FAIL: $2"
  fi
}

# 统计某章节标题之后、下一个 ## 标题之前的非空行数
section_body_lines() { # $1=文件, $2=章节关键词
  [ -f "$1" ] || { echo 0; return; }
  awk -v kw="$2" '
    /^## / && index($0, kw) {f=1; next}
    /^## / {f=0}
    f && NF {n++}
    END {print n+0}
  ' "$1"
}

# 章节标题是否存在
has_section() { # $1=文件, $2=章节关键词
  [ -f "$1" ] && grep -q "^## .*$2" "$1"
}

# ---- 1. report.md 存在 ----
[ -f "$REPORT" ]
report $? "report.md 存在（路径：${REPORT}）"

# ---- 2. 七个必需章节齐全 ----
MISSING=""
for kw in "现象记录" "提问过程" "AI 建议" "验证证据" "根因分析" "修复与恢复验证" "复盘与知识沉淀"; do
  has_section "$REPORT" "$kw" || MISSING="${MISSING} ${kw}"
done
[ -z "$MISSING" ]
report $? "七个必需章节齐全${MISSING:+（缺少:${MISSING} ）}"

# ---- 3. 现象记录有实质内容 ----
N=$(section_body_lines "$REPORT" "现象记录")
[ "$N" -ge 2 ]
report $? "「现象记录」有实质内容（非空行 ${N} 行，需 >=2）"

# ---- 4. 提问过程足够完整 ----
N=$(section_body_lines "$REPORT" "提问过程")
[ "$N" -ge 5 ]
report $? "「提问过程」记录了实际提问（非空行 ${N} 行，需 >=5）"

# ---- 5. AI 建议有实质内容 ----
N=$(section_body_lines "$REPORT" "AI 建议")
[ "$N" -ge 3 ]
report $? "「AI 建议」记录了模型输出（非空行 ${N} 行，需 >=3）"

# ---- 6. 验证证据包含真实执行的命令 ----
EVIDENCE=$( [ -f "$REPORT" ] && sed -n '/^## .*验证证据/,/^## /p' "$REPORT" || true )
echo "$EVIDENCE" | grep -Eq 'kubectl|journalctl|systemctl|crictl|nslookup|dig|curl|wget|ss |cat '
report $? "「验证证据」包含至少一条真实命令（kubectl/journalctl/crictl/nslookup 等）"

# ---- 7. 根因分析有实质内容 ----
N=$(section_body_lines "$REPORT" "根因分析")
[ "$N" -ge 2 ]
report $? "「根因分析」有实质内容（非空行 ${N} 行，需 >=2）"

# ---- 8. 修复与恢复验证包含恢复动作与结果 ----
FIXSECTION=$( [ -f "$REPORT" ] && sed -n '/^## .*修复与恢复验证/,/^## /p' "$REPORT" || true )
N=$(section_body_lines "$REPORT" "修复与恢复验证")
echo "$FIXSECTION" | grep -Eq 'kubectl|rollout|set image|systemctl restart|patch|apply'
report $? "「修复与恢复验证」包含修复命令与验证（非空行 ${N} 行）"

# ---- 9. 集群无残留故障 ----
if command -v kubectl >/dev/null 2>&1; then
  BAD=0; DETAIL=""
  for NS in fault-imagepull fault-dns fault-ep; do
    if kubectl get ns "$NS" >/dev/null 2>&1; then
      BADPODS=$(kubectl -n "$NS" get pods --no-headers 2>/dev/null | grep -Ev 'Running|Completed' || true)
      if [ -n "$BADPODS" ]; then
        BAD=1; DETAIL="${DETAIL} ${NS}"
      fi
    fi
  done
  [ "$BAD" -eq 0 ]
  report $? "集群无残留故障（非 Running Pod 检查${DETAIL:+，异常命名空间:${DETAIL}}）"
else
  report 1 "集群无残留故障（未找到 kubectl，无法检查）"
fi

# ---- 10. 知识条目存在且被 report.md 引用 ----
KBCOUNT=$( [ -d "$KB_DIR" ] && ls "$KB_DIR"/*.md 2>/dev/null | wc -l || echo 0 )
if [ "${KBCOUNT:-0}" -ge 1 ] && [ -f "$REPORT" ] && grep -q 'kb/' "$REPORT"; then
  report 0 "kb/ 下有 ${KBCOUNT} 条知识条目且被 report.md 引用"
else
  report 1 "kb/ 下有 ${KBCOUNT:-0} 条知识条目且被 report.md 引用（需要条目 >=1 且 report 中出现 kb/ 路径）"
fi

echo
echo "SCORE: ${PASS}/${TOTAL}"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
