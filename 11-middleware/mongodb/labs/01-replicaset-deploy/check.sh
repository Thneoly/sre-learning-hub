#!/usr/bin/env bash
# Lab 01 判分脚本：MongoDB 副本集部署 + 故障转移 + 断连追平
# 环境假设：
#   - 本机已装 Docker，且按 task.md 完成 lab：
#       容器 mongo-rs1/mongo-rs2/mongo-rs3，镜像 mongo:7.0，副本集名 rs0
#       演练过 rs.stepDown：mongo-rs1 已让位为 SECONDARY 且未抢回
#       app.orders 最终三节点各 120 条文档
#   - 只做只读检查(rs.status / countDocuments / docker inspect)，不修改任何数据
# 用法：
#   chmod +x check.sh && ./check.sh
#   可用环境变量覆盖：RS1 / RS2 / RS3
set -u

RS1="${RS1:-mongo-rs1}"
RS2="${RS2:-mongo-rs2}"
RS3="${RS3:-mongo-rs3}"

PASS_CNT=0
TOTAL=0

# ---- helpers（内嵌，不依赖仓库其他文件）----
m_eval() { # m_eval <容器> <js表达式> —— 直连该容器内的 mongod 执行
  docker exec "$1" mongosh --quiet \
    "mongodb://localhost:27017/?directConnection=true" --eval "$2" 2>/dev/null
}
check_eq() { # check_eq <描述> <期望> <实际>
  TOTAL=$((TOTAL + 1))
  if [ "$2" = "$3" ]; then
    echo "PASS: $1"
    PASS_CNT=$((PASS_CNT + 1))
  else
    echo "FAIL: $1 (expected='$2' actual='$3')"
  fi
}
count_orders() { # count_orders <容器>
  m_eval "$1" 'db.getSiblingDB("app").orders.countDocuments({})'
}

echo "== Lab 01 检查开始 =="

# 1/2/3 容器在跑
check_eq "容器 $RS1 运行中" \
  "running" "$(docker inspect -f '{{.State.Status}}' "$RS1" 2>/dev/null)"

check_eq "容器 $RS2 运行中" \
  "running" "$(docker inspect -f '{{.State.Status}}' "$RS2" 2>/dev/null)"

check_eq "容器 $RS3 运行中" \
  "running" "$(docker inspect -f '{{.State.Status}}' "$RS3" 2>/dev/null)"

# 4 副本集名
check_eq "副本集名为 rs0" \
  "rs0" "$(m_eval "$RS1" 'rs.status().set')"

# 成员状态表：每行 "主机:端口 stateStr"
MEMBERS="$(m_eval "$RS1" \
  'rs.status().members.forEach(function(m){print(m.name+" "+m.stateStr)})')"

# 5/6 副本集拓扑：恰好 1 个 PRIMARY；mongo-rs1 已让位为 SECONDARY
PRIMARY_CNT="$(printf '%s\n' "$MEMBERS" | awk '$2=="PRIMARY"' | wc -l | tr -d '[:space:]')"
check_eq "有且仅有 1 个 PRIMARY" "1" "${PRIMARY_CNT:-0}"

R1_STATE="$(printf '%s\n' "$MEMBERS" | awk -v h="$RS1" '$1 ~ "^"h":" {print $2}')"
check_eq "$RS1 已让位为 SECONDARY(演练过故障转移)" \
  "SECONDARY" "${R1_STATE:-<rs.status 中未找到该成员>}"

# 7 三个成员均健康(非 DOWN/STARTUP 等)
HEALTHY_CNT="$(printf '%s\n' "$MEMBERS" | awk '$2=="PRIMARY"||$2=="SECONDARY"' | wc -l | tr -d '[:space:]')"
check_eq "三个成员均为 PRIMARY/SECONDARY" "3" "${HEALTHY_CNT:-0}"

# 8 PRIMARY 上的行数（PRIMARY_HOST 从 rs.status 推导）
PRIMARY_HOST="$(printf '%s\n' "$MEMBERS" | awk '$2=="PRIMARY"{print $1}' | cut -d: -f1)"
check_eq "PRIMARY 上 app.orders 文档数=120" \
  "120" "$(count_orders "${PRIMARY_HOST:-$RS2}")"

# 9/10 其余两台也追平到 120（无论谁是主，两台都直连数一遍）
check_eq "$RS2 上 app.orders 文档数=120" "120" "$(count_orders "$RS2")"

check_eq "$RS3 上 app.orders 文档数=120" "120" "$(count_orders "$RS3")"

echo "== 结果 =="
echo "SCORE: ${PASS_CNT}/${TOTAL}"

[ "$PASS_CNT" -eq "$TOTAL" ] && exit 0
exit 1
