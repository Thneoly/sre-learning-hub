#!/usr/bin/env bash
# Lab 01 判分脚本：MySQL 主从复制 + binlog 恢复
# 环境假设：
#   - 本机已装 Docker，且按 task.md 完成 lab：
#       容器名 mysql-m(主) / mysql-s(从)，MySQL 8.0，root 密码 root123
#       业务表 shop.orders 最终主从各 6 行(id 1~6)，误删的 id 4、5 已恢复
#   - 只做只读检查(SELECT / SHOW / docker inspect)，不修改任何数据
# 用法：
#   chmod +x check.sh && ./check.sh
#   可用环境变量覆盖：MYSQL_M / MYSQL_S / ROOT_PW
set -u

MYSQL_M="${MYSQL_M:-mysql-m}"
MYSQL_S="${MYSQL_S:-mysql-s}"
ROOT_PW="${ROOT_PW:-root123}"

PASS_CNT=0
TOTAL=0

# ---- helpers（内嵌，不依赖仓库其他文件）----
q_master() {
  docker exec "$MYSQL_M" mysql -uroot -p"$ROOT_PW" -N -B -e "$1" 2>/dev/null
}
q_replica() {
  docker exec "$MYSQL_S" mysql -uroot -p"$ROOT_PW" -N -B -e "$1" 2>/dev/null
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

echo "== Lab 01 检查开始 =="

# 1/2 容器在跑
check_eq "主库容器 $MYSQL_M 运行中" \
  "running" "$(docker inspect -f '{{.State.Status}}' "$MYSQL_M" 2>/dev/null)"

check_eq "从库容器 $MYSQL_S 运行中" \
  "running" "$(docker inspect -f '{{.State.Status}}' "$MYSQL_S" 2>/dev/null)"

# 3/4/5 复制线程状态（SHOW REPLICA STATUS 逐字段抽取，去掉空白）
RS="$(docker exec "$MYSQL_S" mysql -uroot -p"$ROOT_PW" -e 'SHOW REPLICA STATUS\G' 2>/dev/null)"

IO_RUN="$(printf '%s\n' "$RS" | awk -F': ' '/Replica_IO_Running:/{print $2}' | tr -d '[:space:]')"
check_eq "Replica_IO_Running=Yes" "Yes" "${IO_RUN:-<无输出,复制未配置或容器异常>}"

SQL_RUN="$(printf '%s\n' "$RS" | awk -F': ' '/Replica_SQL_Running:/{print $2}' | tr -d '[:space:]')"
check_eq "Replica_SQL_Running=Yes" "Yes" "${SQL_RUN:-<无输出,复制未配置或容器异常>}"

# Seconds_Behind_Source 在 8.0.22 前叫 Seconds_Behind_Master，两者都兼容
SB="$(printf '%s\n' "$RS" | awk -F': ' '/Seconds_Behind_(Source|Master):/{print $2}' | tr -d '[:space:]')"
check_eq "复制延迟 Seconds_Behind_Source=0" "0" "${SB:-<NULL,IO 线程断开>}"

# 6/7 行数
check_eq "主库 shop.orders 行数=6" \
  "6" "$(q_master 'SELECT COUNT(*) FROM shop.orders;')"

check_eq "从库 shop.orders 行数=6" \
  "6" "$(q_replica 'SELECT COUNT(*) FROM shop.orders;')"

# 8/9 误删行已恢复
check_eq "主库误删行(id 4,5)已恢复" \
  "2" "$(q_master 'SELECT COUNT(*) FROM shop.orders WHERE id IN (4,5);')"

check_eq "从库误删行(id 4,5)已恢复" \
  "2" "$(q_replica 'SELECT COUNT(*) FROM shop.orders WHERE id IN (4,5);')"

# 10 主从 checksum 一致（空值视为失败）
CS_M="$(q_master 'CHECKSUM TABLE shop.orders;' | awk '{print $2}')"
CS_S="$(q_replica 'CHECKSUM TABLE shop.orders;' | awk '{print $2}')"
if [ -n "${CS_M:-}" ] && [ "$CS_M" = "${CS_S:-}" ]; then
  CS_STATE="ok"
else
  CS_STATE="mismatch_or_empty(master='${CS_M:-}' replica='${CS_S:-}')"
fi
check_eq "主从 CHECKSUM TABLE 一致" "ok" "$CS_STATE"

echo "== 结果 =="
echo "SCORE: ${PASS_CNT}/${TOTAL}"

[ "$PASS_CNT" -eq "$TOTAL" ] && exit 0
exit 1
