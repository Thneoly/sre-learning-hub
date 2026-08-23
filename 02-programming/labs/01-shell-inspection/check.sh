#!/usr/bin/env bash
# [任意节点] Lab 01 判分脚本
# 运行前提:
#   - Ubuntu 22.04/24.04，bash 4+，awk/grep/systemctl/df 可用，装有 ssh 客户端
#   - 本机 systemd-journald 处于 active（Ubuntu 默认如此）
#   - 22 端口无论是否监听都不影响判分（不可达主机 fixture 用 nosuchuser@127.0.0.1 模拟）
# 说明: 只在本机运行学习者的 batch-inspect.sh 并检查输出格式与退出码，不改集群
# 用法: chmod +x check.sh && ./check.sh   （或 bash check.sh）
set -u

LAB_DIR=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$LAB_DIR/batch-inspect.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAILN=0
TOTAL=0
pass() { TOTAL=$((TOTAL+1)); PASS=$((PASS+1)); printf 'PASS: %s\n' "$1"; }
fail() { TOTAL=$((TOTAL+1)); FAILN=$((FAILN+1)); printf 'FAIL: %s\n' "$1"; }

# ---- 生成 fixture 主机列表（与 task.md 自测用例一致） ----
cat > "$TMP/hosts_ok.txt" <<'EOF'
# 正常 fixture：本机 + journald 服务
localhost systemd-journald
localhost
EOF

cat > "$TMP/hosts_fail.txt" <<'EOF'
nosuchuser@127.0.0.1 sshd
EOF

# T1: 脚本存在且 bash 语法正确
if [ -f "$SCRIPT" ]; then
  if bash -n "$SCRIPT" 2>"$TMP/syntax.err"; then
    pass "batch-inspect.sh 存在且 bash -n 语法检查通过"
  else
    fail "batch-inspect.sh 存在但语法错误: $(head -n1 "$TMP/syntax.err")"
  fi
else
  fail "batch-inspect.sh 不存在于 lab 目录"
fi

# T2: -h 打印用法并退出 0
bash "$SCRIPT" -h >"$TMP/help.out" 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ] && grep -q -- "-w" "$TMP/help.out"; then
  pass "-h 输出包含 -w 的用法说明且退出码为 0"
else
  fail "-h 应退出 0 且用法说明包含 -w (实际退出码 $rc)"
fi

# T3: 缺少 -f 时非 0 退出
bash "$SCRIPT" >/dev/null 2>&1
rc=$?
if [ "$rc" -ne 0 ]; then
  pass "缺少 -f 参数时以非 0 退出 (rc=$rc)"
else
  fail "缺少 -f 参数时应以非 0 退出，实际为 0"
fi

# T4: 正常 fixture 退出码 0
bash "$SCRIPT" -f "$TMP/hosts_ok.txt" >"$TMP/ok.out" 2>/dev/null
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "hosts_ok fixture 全部 OK，退出码 0"
else
  fail "hosts_ok fixture 应退出 0，实际 $rc"
fi

# T5: RESULT 行格式（含服务状态）
if grep -Eq '^RESULT host=localhost cpu=[0-9]+ mem=[0-9]+ disk_max=[0-9]+ services=systemd-journald:active status=OK$' "$TMP/ok.out"; then
  pass "RESULT 行格式正确且 journald 为 active、status=OK"
else
  fail "RESULT 行格式不符（应有: RESULT host=localhost cpu=<int> mem=<int> disk_max=<int> services=systemd-journald:active status=OK）"
fi

# T6: SUMMARY 行格式与计数
if grep -q '^SUMMARY total=2 ok=2 warn=0 fail=0$' "$TMP/ok.out"; then
  pass "SUMMARY 行为 total=2 ok=2 warn=0 fail=0"
else
  fail "SUMMARY 行应精确为 'SUMMARY total=2 ok=2 warn=0 fail=0'"
fi

# T7: 低阈值触发 WARN，退出码 1
bash "$SCRIPT" -f "$TMP/hosts_ok.txt" -w cpu=1 -w mem=1 -w disk=1 >"$TMP/warn.out" 2>/dev/null
rc=$?
if [ "$rc" -eq 1 ] \
   && grep -q 'status=WARN' "$TMP/warn.out" \
   && grep -q '^SUMMARY total=2 ok=0 warn=2' "$TMP/warn.out"; then
  pass "低阈值 (-w cpu=1 -w mem=1 -w disk=1) 触发 WARN，退出码 1，warn=2"
else
  fail "低阈值运行应退出 1 且两台均 WARN (实际退出码 $rc)"
fi

# T8: 不可达主机触发 FAIL，退出码 2
bash "$SCRIPT" -f "$TMP/hosts_fail.txt" >"$TMP/fail.out" 2>/dev/null
rc=$?
if [ "$rc" -eq 2 ] \
   && grep -q '^RESULT host=nosuchuser@127.0.0.1 .*status=FAIL$' "$TMP/fail.out" \
   && grep -q '^SUMMARY total=1 ok=0 warn=0 fail=1$' "$TMP/fail.out"; then
  pass "不可达主机判 FAIL，退出码 2，SUMMARY fail=1"
else
  fail "不可达主机应退出 2 且 RESULT status=FAIL (实际退出码 $rc)"
fi

echo "----------------------------------------"
echo "SCORE: $PASS/$TOTAL"
[ "$PASS" -eq "$TOTAL" ] && exit 0
exit 1
