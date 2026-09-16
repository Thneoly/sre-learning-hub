#!/usr/bin/env bash
# Lab 01 判分脚本 —— HDFS 伪分布式集群状态与数据验证（只读，不修改集群）
# 运行位置：任意装 docker 的 Ubuntu VM（[任意节点]，docker-ce 即可）
# 前提：已按 task.md 完成任务 1~6 —— 容器 hdfs-lab 正在运行、/labs/big.bin 与
#       /labs/small 已上传、safemode 已 leave。任务 7（清理）必须在跑完本脚本之后做。
# 全部检查通过 docker exec 只读查询完成，不写 HDFS、不重启进程。
# 用法：chmod +x check.sh && ./check.sh
set -u

PASS=0
FAIL=0
TOTAL=0

pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); echo "PASS: $*"; }
fail() { TOTAL=$((TOTAL+1)); FAIL=$((FAIL+1)); echo "FAIL: $*"; }

C=hdfs-lab

# 1. 容器 Running（后续检查全部依赖它，失败则提前收尾）
if docker ps --format '{{.Names}}' | grep -qx "$C"; then
  pass "容器 $C 处于 Running"
else
  fail "容器 $C 未运行（docker ps 看不到；先 docker start $C 或按 solution 重做）"
  echo
  echo "SCORE: $PASS/$TOTAL"
  exit 1
fi

# 2. NN / DN 进程存在（jps 不在镜像里时回退到 ps，两者都只读）
# 注意：docker exec 找不到命令时，"executable file not found" 报错走 stdout，
# 不能只判 OUT 是否为空——必须先用 command -v 确认 jps 真的存在再取它的输出。
if docker exec "$C" bash -c 'command -v jps' >/dev/null 2>&1; then
  OUT="$(docker exec "$C" jps 2>/dev/null || true)"
else
  OUT=""
fi
if [ -z "$OUT" ]; then
  OUT="$(docker exec "$C" ps -ef 2>/dev/null || true)"
fi
if echo "$OUT" | grep -q 'NameNode'; then
  pass "NameNode 进程已启动"
else
  fail "NameNode 进程未启动（容器内 jps / ps -ef 看不到）"
fi
if echo "$OUT" | grep -q 'DataNode'; then
  pass "DataNode 进程已启动"
else
  fail "DataNode 进程未启动（容器内 jps / ps -ef 看不到）"
fi

# 3. dfsadmin -report：有一个 Live datanode
if docker exec "$C" hdfs dfsadmin -report 2>/dev/null | grep -q 'Live datanodes (1)'; then
  pass "dfsadmin -report 显示 Live datanodes (1)"
else
  fail "dfsadmin -report 未显示 Live datanodes (1)（DN 未注册？见 task 提示 4）"
fi

# 4. 200MB 大文件已上传
if docker exec "$C" hdfs dfs -test -e /labs/big.bin 2>/dev/null; then
  pass "/labs/big.bin 存在于 HDFS"
else
  fail "/labs/big.bin 不存在于 HDFS（hdfs dfs -test -e 失败）"
fi

# 5. fsck：200MB 默认 128MB 块大小 → 恰好 2 块
if docker exec "$C" hdfs fsck /labs/big.bin 2>/dev/null | grep -Eq 'Total blocks \(validated\):[[:space:]]*2([^0-9]|$)'; then
  pass "fsck /labs/big.bin 的 Total blocks (validated) 为 2"
else
  fail "fsck /labs/big.bin 的 Total blocks (validated) 不为 2（块大小被改过？）"
fi

# 6. fsck：小文件目录统计 500 个对象
if docker exec "$C" hdfs fsck /labs/small 2>/dev/null | grep -Eq 'Total files:[[:space:]]*500([^0-9]|$)'; then
  pass "fsck /labs/small 的 Total files 为 500"
else
  fail "fsck /labs/small 的 Total files 不为 500"
fi

# 7. safemode 已退出（最终态可写）
if docker exec "$C" hdfs dfsadmin -safemode get 2>/dev/null | grep -q 'Safe mode is OFF'; then
  pass "safemode 已退出（Safe mode is OFF）"
else
  fail "safemode 未退出（hdfs dfsadmin -safemode get 非 OFF）"
fi

echo
echo "SCORE: $PASS/$TOTAL"
if [ "$FAIL" -eq 0 ]; then
  exit 0
else
  exit 1
fi
